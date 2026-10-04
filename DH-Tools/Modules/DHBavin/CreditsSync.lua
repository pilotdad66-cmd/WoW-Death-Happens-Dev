-- CM3 (see DH-Bavin-Credits-Design.md "Milestone plan" and "Sync protocol
-- additions"): officer-set ledger sync. Agreed design, 2026-09-29 (Loopi):
--   * Rides the EXISTING credits prefix (Credits.lua's DHBavinCreditsV2) with
--     two NEW, additive message types. A client without this file falls
--     through Credits_OnAddonMessage's if/elseif chain and ignores them, so
--     no prefix bump is needed.
--   * The historical seed is NEVER replicated. Every officer runs the same
--     seed from the shipped SeedData.lua/AltRoster.lua; a short fingerprint
--     of those two tables rides every exchange and a mismatch stops the
--     sync (with one warning), because applying deltas onto a different
--     base could corrupt alt lists. Only records changed AFTER the seed
--     carry a syncedAt stamp and are ever sent.
--   * Changes are per-record last-writer-wins on syncedAt (a strictly
--     increasing per-client stamp; equal stamps tie-break on the encoded
--     string so every client converges). The review queue rides the same
--     way as per-name add/remove stamps.
--   * Whispered to ONLINE officers only (never GUILD). The receiver
--     verifies the sender against ITS OWN officer list + guild roster
--     (never anything claimed in the message) and only applies if the
--     receiver is itself an officer.
--   * Not synced here: config (Credits.lua's CFGSET already does it),
--     Credits_ResetTestData and CreditsSeed_Import (both deliberately
--     local), and credit/point TRANSACTIONS (CM4-CM6 - a per-record
--     replace is right for alt/identity edits but will need real deltas
--     once donations change most records every day).
--
-- WIRE (prefix DHBavinCreditsV2, WHISPER):
--   LSYNCREQ|<fp>|<since>            - "send me everything stamped after
--                                       <since>". Answered with LSYNCDATA,
--                                       and reciprocated once per peer per
--                                       session so offline edits flow both ways.
--   LSYNCDATA|<id>|<i>/<n>|<chunk>   - chunked payload (exact substrings,
--                                       reassembled by plain concat, same
--                                       idea as Sync.lua's ChunkEncoded).
--                                       Payload = ";"-joined items:
--                                         F:<fp>
--                                         R:<record>
--                                         Q:<name>|<1 add / 0 remove>|<stamp>
--                                         T:<audit-log row> W:<from>|<to>
--                                         G:<day>|<n>|<h>   (2026-10-04, CM7:
--                                         audit log replication - see the
--                                         "Audit-log replication" section)
--   <record> = discordName|mainToon|alts(csv)|points|credits|tier|prestige|
--              lifetimePoints|lastDonationDate|lastUpdated|syncedAt|
--              lifetimeCredits            (lifetimeCredits LAST/optional)
--   Strings are %-escaped for  % | ; , ~  so no field can break a delimiter.

local DHTools = DHTools
DHTools.Bavin = DHTools.Bavin or {}
local ns = DHTools.Bavin

local MAX_CHUNK_CHARS = 200
local MAX_TOTAL_CHUNKS = 400        -- refuse absurd reassembly sizes
local BUFFER_TTL = 90               -- seconds an incomplete transmission is kept
local SINCE_SLACK = 120             -- request slightly further back than lastSyncAt
local LOGIN_DELAY = 8               -- let the guild roster populate first

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------
local function Esc(s)
    return (tostring(s or ""):gsub("[%%|;,~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

local function Unesc(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function Num(x)
    return tostring(tonumber(x) or 0)
end

local function Split(s, sep)
    local out, start = {}, 1
    while true do
        local i = s:find(sep, start, true)
        if not i then
            out[#out + 1] = s:sub(start)
            break
        end
        out[#out + 1] = s:sub(start, i - 1)
        start = i + #sep
    end
    return out
end

local function Later(delay, fn)
    if delay > 0 and C_Timer and C_Timer.After then
        C_Timer.After(delay, fn)
    else
        fn()
    end
end

local function EnsureDb()
    local db = ns.creditsDb
    if not db then return nil end
    if type(db.rqStamps) ~= "table" then db.rqStamps = {} end
    -- CM4 additions (CreditsDonations.lua); InitCreditsDB creates them too.
    if type(db.ledgerTombstones) ~= "table" then db.ledgerTombstones = {} end
    if type(db.pendingCredits) ~= "table" then db.pendingCredits = {} end
    if type(db.pendingReleased) ~= "table" then db.pendingReleased = {} end
    return db
end

-- Strictly increasing per-client stamp, never behind anything already seen,
-- so two edits inside one second still order correctly on every peer.
local lastStamp = 0
local function NextStamp()
    local db = ns.creditsDb
    if lastStamp == 0 and db then
        for _, rec in pairs(db.ledger or {}) do
            if (rec.syncedAt or 0) > lastStamp then lastStamp = rec.syncedAt end
        end
        for _, q in pairs(db.rqStamps or {}) do
            if (q.ts or 0) > lastStamp then lastStamp = q.ts end
        end
        for _, t in pairs(db.ledgerTombstones or {}) do
            if (t.ts or 0) > lastStamp then lastStamp = t.ts end
        end
        for _, t in pairs(db.pendingReleased or {}) do
            if (t.ts or 0) > lastStamp then lastStamp = t.ts end
        end
        for _, list in pairs(db.pendingCredits or {}) do
            for _, e in ipairs(list) do
                if (e.syncedAt or 0) > lastStamp then lastStamp = e.syncedAt end
            end
        end
    end
    local s = time()
    if s <= lastStamp then s = lastStamp + 1 end
    lastStamp = s
    return s
end

local function Observe(stamp)
    if stamp and stamp > lastStamp then lastStamp = stamp end
end

--------------------------------------------------------------------------
-- Seed fingerprint (SeedData + AltRoster). Cached per table identity.
--------------------------------------------------------------------------
local function Hash(h, s)
    for i = 1, #s do
        h = (h * 31 + s:byte(i)) % 2147483629
    end
    return h
end

-- 2026-10-04: the "start from scratch" reset number (creditsDb.dataEpoch) is
-- mixed in once it is > 0, so a client that has not had the reset (or an old
-- build that does not know the mechanism) never matches and can never push
-- its old data back in. At epoch 0 the value is exactly the seed hash, so
-- builds that never saw a reset keep interoperating. The seed part is
-- cached; the epoch part is cheap and computed on every call.
local fpCache, fpSeedRef, fpAltRef
local function SeedHash()
    if fpCache and fpSeedRef == ns.CreditsSeedData and fpAltRef == ns.CreditsAltRoster then
        return fpCache
    end
    local h = 7
    local keys = {}
    for k in pairs(ns.CreditsSeedData or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local e = ns.CreditsSeedData[k]
        local lp = (type(e) == "table") and e.lifetimePoints or e
        h = Hash(h, k .. ":" .. tostring(math.floor((tonumber(lp) or 0) * 100 + 0.5)) .. ";")
    end
    keys = {}
    for k in pairs(ns.CreditsAltRoster or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        h = Hash(h, k .. "=" .. table.concat(ns.CreditsAltRoster[k] or {}, ",") .. ";")
    end
    fpCache = h
    fpSeedRef, fpAltRef = ns.CreditsSeedData, ns.CreditsAltRoster
    return fpCache
end

function ns.CreditsSync_Fingerprint()
    local h = SeedHash()
    local epoch = ns.creditsDb and ns.creditsDb.dataEpoch or 0
    if epoch > 0 then h = Hash(h, "E:" .. tostring(epoch)) end
    return ("%08x"):format(h)
end

--------------------------------------------------------------------------
-- Record encode / decode
--------------------------------------------------------------------------
local function EncodeRecord(rec)
    local alts = {}
    for i, a in ipairs(rec.alts or {}) do alts[i] = Esc(a) end
    return table.concat({
        Esc(rec.discordName), Esc(rec.mainToon), table.concat(alts, ","),
        Num(rec.points), Num(rec.credits), Esc(rec.tier), Num(rec.prestige),
        Num(rec.lifetimePoints), Esc(rec.lastDonationDate), Num(rec.lastUpdated),
        Num(rec.syncedAt), Num(rec.lifetimeCredits),
        -- Field 13 (2026-09-29): the account's Discord name. "d"-prefixed so
        -- an empty name ("no Discord on file") still survives Split.
        "d" .. Esc(ns.Credits_GetDiscord and ns.Credits_GetDiscord(rec) or rec.discordName),
    }, "|")
end

-- Returns a record table, or nil if the text isn't a sane record.
local function DecodeRecord(text)
    local f = Split(text, "|")
    if #f < 11 or #f > 13 then return nil end
    local discordName = Unesc(f[1])
    if discordName == "" or #discordName > 64 then return nil end
    local tier = Unesc(f[6])
    if not (ns.CreditsTierCaps and ns.CreditsTierCaps[tier]) then return nil end
    local alts = {}
    if f[3] ~= "" then
        for _, a in ipairs(Split(f[3], ",")) do
            local name = Unesc(a)
            if name ~= "" then alts[#alts + 1] = name end
        end
    end
    if #alts > 60 then return nil end
    local points, credits, prestige = tonumber(f[4]), tonumber(f[5]), tonumber(f[7])
    local lifetimePoints, lastUpdated, syncedAt = tonumber(f[8]), tonumber(f[10]), tonumber(f[11])
    if not (points and credits and prestige and lifetimePoints and lastUpdated and syncedAt) then return nil end
    if points < 0 or credits < 0 or prestige < 0 or lifetimePoints < 0 then return nil end
    local lifetimeCredits = tonumber(f[12])
    if not lifetimeCredits or lifetimeCredits < credits then lifetimeCredits = credits end
    -- Field 13 = Discord name ("d" + escaped name). Senders on the older
    -- 12-field format have no such field: the tag defaults to the ledger key.
    local discord = discordName
    if f[13] and f[13]:sub(1, 1) == "d" then
        discord = Unesc(f[13]:sub(2))
        if #discord > 64 then return nil end
    end
    return {
        discordName = discordName,
        discord = discord,
        mainToon = Unesc(f[2]),
        alts = alts,
        points = points,
        credits = credits,
        tier = tier,
        prestige = prestige,
        lifetimePoints = lifetimePoints,
        lastDonationDate = Unesc(f[9]),
        lastUpdated = lastUpdated,
        syncedAt = syncedAt,
        lifetimeCredits = lifetimeCredits,
    }
end

ns.CreditsSync_EncodeRecord = EncodeRecord
ns.CreditsSync_DecodeRecord = DecodeRecord

--------------------------------------------------------------------------
-- Held-donation (pending credit) entries - CM4 spec step 7
--------------------------------------------------------------------------
-- P:<id>|<sender>|<ts>|<receiver>|<gold>|<rep>|<credits>|<crx>|<cry>|
--   <rgx>|<rgy>|<syncedAt>|<items>       items = "~"-joined, each
--   itemID,name,count,rep,category (the Esc'd text never contains , ~ | ;).
-- An entry never changes once created, so there is no last-writer-wins:
-- it is stored if its id is unknown and not tombstoned, and an X: item
-- (the release tombstone) removes it.
local function EncodePending(e)
    local items = {}
    for i, it in ipairs(e.items or {}) do
        items[i] = table.concat({
            Esc(it.itemID), Esc(it.name), Num(it.count), Num(it.rep), Esc(it.category or "Uncategorized"),
        }, ",")
    end
    local cpr, rpg = e.creditsPerRep or {}, e.repPerGold or {}
    return table.concat({
        Esc(e.id), Esc(e.sender), Num(e.ts), Esc(e.receiver), Num(e.gold), Num(e.rep), Num(e.credits),
        Num(cpr.x), Num(cpr.y), Num(rpg.x), Num(rpg.y), Num(e.syncedAt),
        table.concat(items, "~"),
    }, "|")
end

local function DecodePending(text)
    local f = Split(text, "|")
    if #f ~= 13 then return nil end
    local id, sender = Unesc(f[1]), Unesc(f[2])
    if not id:match("^[%w%-]+$") or #id > 40 then return nil end
    if sender == "" or #sender > 64 then return nil end
    local ts, gold, rep, credits = tonumber(f[3]), tonumber(f[5]), tonumber(f[6]), tonumber(f[7])
    local crx, cry, rgx, rgy, syncedAt = tonumber(f[8]), tonumber(f[9]), tonumber(f[10]), tonumber(f[11]), tonumber(f[12])
    if not (ts and gold and rep and credits and crx and cry and rgx and rgy and syncedAt) then return nil end
    if gold < 0 or rep < 0 or credits < 0 or crx < 0 or cry <= 0 or rgx < 0 or rgy <= 0 then return nil end
    local items = {}
    if f[13] ~= "" then
        for _, part in ipairs(Split(f[13], "~")) do
            local p = Split(part, ",")
            if #p ~= 5 then return nil end
            local count, irep = tonumber(p[3]), tonumber(p[4])
            if not count or not irep or count < 0 or irep < 0 then return nil end
            items[#items + 1] = {
                itemID = tonumber(Unesc(p[1])) or Unesc(p[1]),
                name = Unesc(p[2]), count = count, rep = irep, category = Unesc(p[5]),
            }
        end
    end
    if #items > 100 then return nil end
    return {
        id = id, sender = sender, ts = ts, receiver = Unesc(f[4]),
        gold = gold, rep = rep, credits = credits, items = items,
        creditsPerRep = { x = crx, y = cry }, repPerGold = { x = rgx, y = rgy },
        syncedAt = syncedAt,
    }
end

ns.CreditsSync_EncodePending = EncodePending
ns.CreditsSync_DecodePending = DecodePending

--------------------------------------------------------------------------
-- Peers and transport
--------------------------------------------------------------------------
local function MyName()
    return ns.NormalizeName(UnitName("player"))
end

local function ReceiverReady()
    return ns.creditsDb ~= nil and ns.IsInTargetGuild() and ns.CanManageCreditsConfigLocal()
end

-- Online officers (shared officer list or guild leader) other than me, taken
-- from the local guild-roster cache. Whispering an offline name only earns an
-- error line, so offline officers are skipped and catch up via LSYNCREQ later.
local function PeerList()
    local peers = {}
    local me = MyName()
    for name, entry in pairs(ns.guildRoster or {}) do
        if entry.online and name ~= me and (ns.IsGuildLeader(name) or ns.IsOfficerName(name)) then
            peers[#peers + 1] = name
        end
    end
    table.sort(peers)
    return peers
end

local function SenderAllowed(senderShort)
    return ns.IsGuildMember(senderShort) and ns.Credits_IsAuthorizedSender(senderShort)
end

local function ChunkEncoded(encoded)
    local chunks, remaining = {}, encoded
    while #remaining > 0 do
        if #remaining <= MAX_CHUNK_CHARS then
            chunks[#chunks + 1] = remaining
            remaining = ""
        else
            local window = remaining:sub(1, MAX_CHUNK_CHARS)
            local sepPos = window:find(";[^;]*$")
            local cutAt = sepPos or MAX_CHUNK_CHARS
            chunks[#chunks + 1] = remaining:sub(1, cutAt)
            remaining = remaining:sub(cutAt + 1)
        end
    end
    return chunks
end

local sendCounter = 0
local function SendItems(peer, items)
    if #items == 0 then return end
    sendCounter = sendCounter + 1
    local id = ("%x%x"):format(time() % 65536, sendCounter % 65536)
    local chunks = ChunkEncoded("F:" .. ns.CreditsSync_Fingerprint() .. ";" .. table.concat(items, ";"))
    local total = #chunks
    for i, chunk in ipairs(chunks) do
        local delay = (i > 3) and (i - 3) * 0.1 or 0
        Later(delay, function()
            ns.Credits_SendAddon("LSYNCDATA|" .. id .. "|" .. i .. "/" .. total .. "|" .. chunk, "WHISPER", peer)
        end)
    end
end

local function RecordItem(rec) return "R:" .. EncodeRecord(rec) end
-- Q:<name>|<1 add / 0 remove>|<stamp>|<issue>   (issue = the Review Queue
-- row type for an add; CM4 added it - "removed_alt" is the old implicit one)
local function QueueItem(q)
    return "Q:" .. Esc(q.name) .. "|" .. (q.present and "1" or "0") .. "|" .. Num(q.ts) .. "|" .. Esc(q.issue or "removed_alt")
end
-- D:<discordName>|<stamp>   account deleted by a merge (tombstone)
local function TombItem(name, t) return "D:" .. Esc(name) .. "|" .. Num(t.ts) end
-- P:<held entry> (see EncodePending) / X:<id>|<stamp>  (released tombstone)
local function PendingItem(e) return "P:" .. EncodePending(e) end
local function ReleasedItem(id, t) return "X:" .. Esc(id) .. "|" .. Num(t.ts) end

--------------------------------------------------------------------------
-- Audit-log replication (CM7 step 2b, 2026-10-04, Loopi: "1. Every officer.
-- 2. Every row.")
--
-- transactionLog rows (donations, released holds, merges - and CM5's spends
-- later) are IMMUTABLE events with a unique id, so replication is a plain
-- union by id: no stamps, no last-writer-wins. The only mutation a row ever
-- gets is a merge re-tagging its `account`, and that is DERIVED from the
-- merge rows themselves (RewriteMergedAccounts), so replicas converge.
--   T:<row>              one row, sent live to online officers when it is
--                        written, and again by reconciliation.
--   W:<from>|<to>        day window (UTC day numbers) a digest covers.
--   G:<day>|<n>|<h>      per-day digest: row count and sum of id hashes.
-- Reconciliation (why digests and not a "since" time): a row created while
-- an officer was offline can be missed by a since-based catch-up for good if
-- that officer happened to sync with someone else later. So when an officer
-- asks for a sync it also sends its digest; the peer compares day by day,
-- sends its rows for every day that differs plus its own digest, and the
-- first side answers the same way until both match (a round cap per peer
-- guards against a row that can never be applied looping forever). Rows older
-- than LOG_WINDOW_DAYS are not reconciled (the planned 6-8 week purge keeps
-- the log inside it).
-- Row wire format: key=value fields joined by '|' (keys sorted); value =
-- s<str> | n<num> | b1/b0 | a<elem,elem> (elem = scalar or m<k=v~k=v>) |
-- m<k=v~k=v>. Strings are Esc'd, so no value contains | ; , ~ unescaped.
--------------------------------------------------------------------------
local LOG_WINDOW_DAYS = 90
local MAX_RECON_ROUNDS = 6
local MAX_LOG_ROWS = 50000
local reconRounds = {}     -- peer -> reconciliation replies sent since they last asked

local function IsKeyName(k) return type(k) == "string" and k:match("^[%a_][%w_]*$") ~= nil end

local function EncScalar(v)
    local t = type(v)
    if t == "string" then return "s" .. Esc(v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return nil end
        return "n" .. tostring(v)
    end
    if t == "boolean" then return v and "b1" or "b0" end
    return nil
end

local function EncMap(t)
    local keys = {}
    for k in pairs(t) do if IsKeyName(k) then keys[#keys + 1] = k end end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local s = EncScalar(t[k])
        if s then parts[#parts + 1] = k .. "=" .. s end
    end
    return "m" .. table.concat(parts, "~")
end

local function EncValue(v)
    if type(v) ~= "table" then return EncScalar(v) end
    if next(v) == nil or v[1] ~= nil then
        local parts = {}
        for _, e in ipairs(v) do
            local s
            if type(e) == "table" then s = EncMap(e) else s = EncScalar(e) end
            if s then parts[#parts + 1] = s end
        end
        return "a" .. table.concat(parts, ",")
    end
    return EncMap(v)
end

local function EncodeLogRow(row)
    local keys = {}
    for k in pairs(row) do if IsKeyName(k) then keys[#keys + 1] = k end end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local s = EncValue(row[k])
        if s then parts[#parts + 1] = k .. "=" .. s end
    end
    return table.concat(parts, "|")
end

local function DecScalar(s)
    local tag, body = s:sub(1, 1), s:sub(2)
    if tag == "s" then return true, Unesc(body) end
    if tag == "n" then
        local n = tonumber(body)
        if n == nil or n ~= n or n == math.huge or n == -math.huge then return false end
        return true, n
    end
    if tag == "b" then
        if body == "1" then return true, true end
        if body == "0" then return true, false end
    end
    return false
end

local function DecMap(s)
    local t = {}
    if s == "" then return t end
    for _, f in ipairs(Split(s, "~")) do
        local k, v = f:match("^([%a_][%w_]*)=(.*)$")
        if k then
            local ok, val = DecScalar(v)
            if ok then t[k] = val end
        end
    end
    return t
end

local function DecValue(s)
    local tag = s:sub(1, 1)
    if tag == "a" then
        local t, body = {}, s:sub(2)
        if body ~= "" then
            for _, e in ipairs(Split(body, ",")) do
                if e:sub(1, 1) == "m" then
                    t[#t + 1] = DecMap(e:sub(2))
                else
                    local ok, val = DecScalar(e)
                    if ok then t[#t + 1] = val end
                end
            end
        end
        return true, t
    end
    if tag == "m" then return true, DecMap(s:sub(2)) end
    return DecScalar(s)
end

local function DecodeLogRow(body)
    local row = {}
    for _, f in ipairs(Split(body, "|")) do
        local k, v = f:match("^([%a_][%w_]*)=(.*)$")
        if k then
            local ok, val = DecValue(v)
            if ok then row[k] = val end
        end
    end
    if type(row.id) ~= "string" or row.id == "" or #row.id > 80 then return nil end
    if type(row.ts) ~= "number" or row.ts <= 0 then return nil end
    return row
end

ns.CreditsSync_EncodeLogRow = EncodeLogRow
ns.CreditsSync_DecodeLogRow = DecodeLogRow

local function DayOf(ts) return math.floor((tonumber(ts) or 0) / 86400) end

-- day -> { n = rows, h = sum of id hashes (order independent) }
local function LogDigest(db)
    local d = {}
    for _, e in ipairs(db.transactionLog or {}) do
        if type(e) == "table" and type(e.id) == "string" and tonumber(e.ts) then
            local day = DayOf(e.ts)
            local x = d[day]
            if not x then
                x = { n = 0, h = 0 }
                d[day] = x
            end
            x.n = x.n + 1
            x.h = (x.h + Hash(7, e.id)) % 2147483629
        end
    end
    return d
end
ns.CreditsSync_LogDigest = function() return LogDigest(ns.creditsDb or {}) end

local function DigestItems(db)
    local today = DayOf(time())
    local from, to = today - LOG_WINDOW_DAYS, today + 1
    local items = { "W:" .. from .. "|" .. to }
    local d = LogDigest(db)
    local days = {}
    for day in pairs(d) do
        if day >= from and day <= to then days[#days + 1] = day end
    end
    table.sort(days)
    for _, day in ipairs(days) do
        items[#items + 1] = ("G:%d|%d|%d"):format(day, d[day].n, d[day].h)
    end
    return items
end

-- Re-tag the account on rows that predate a merge: for every merge row (oldest
-- first) rows with account == its source and ts <= the merge's become the
-- target. Exactly what Credits_MergeAccounts does on the officer who merged,
-- so it is a no-op there and brings replicas (and rows that arrive after the
-- merge row did) to the same state.
local function RewriteMergedAccounts(db)
    local log = db.transactionLog
    local merges = {}
    for _, e in ipairs(log) do
        if e.kind == "merge" and type(e.source) == "string" and type(e.account) == "string" then merges[#merges + 1] = e end
    end
    if #merges == 0 then return end
    table.sort(merges, function(a, b)
        if a.ts ~= b.ts then return a.ts < b.ts end
        return tostring(a.id) < tostring(b.id)
    end)
    for _, m in ipairs(merges) do
        for _, e in ipairs(log) do
            if e ~= m and e.account == m.source and (tonumber(e.ts) or 0) <= m.ts then e.account = m.account end
        end
    end
end

-- Live push of a freshly written row. With nobody online it is simply
-- skipped: reconciliation delivers it when an officer next appears.
function ns.CreditsSync_LogAdded(row)
    local db = EnsureDb()
    if not db or type(row) ~= "table" then return end
    local peers = PeerList()
    if #peers == 0 then return end
    local items = { "T:" .. EncodeLogRow(row) }
    for _, peer in ipairs(peers) do SendItems(peer, items) end
end

-- Compare a peer's digest with ours; send our rows for every day that differs
-- plus our own digest so they can do the same.
local function ReconcileLog(peer, from, to, theirs)
    local db = EnsureDb()
    if not db then return end
    local today = DayOf(time())
    if from < today - 120 then from = today - 120 end
    if to > today + 2 then to = today + 2 end
    if to < from then return end
    local mine = LogDigest(db)
    local diffDays, mismatch = {}, false
    for day = from, to do
        local m, t = mine[day], theirs[day]
        if (m and (not t or t.n ~= m.n or t.h ~= m.h)) or (t and not m) then
            mismatch = true
            if m then diffDays[day] = true end
        end
    end
    if not mismatch then return end
    if (reconRounds[peer] or 0) >= MAX_RECON_ROUNDS then return end
    reconRounds[peer] = (reconRounds[peer] or 0) + 1
    local items = {}
    for _, e in ipairs(db.transactionLog) do
        if type(e) == "table" and type(e.id) == "string" and tonumber(e.ts) and diffDays[DayOf(e.ts)] then
            items[#items + 1] = "T:" .. EncodeLogRow(e)
        end
    end
    for _, it in ipairs(DigestItems(db)) do items[#items + 1] = it end
    SendItems(peer, items)
end

--------------------------------------------------------------------------
-- Local mutation -> stamp + push
--------------------------------------------------------------------------
-- Called by Credits.lua's Link/Unlink/SetAsNewMain AFTER they mutate the
-- ledger. discordNames = accounts whose record changed; queueChanges = list of
-- { name, present } review-queue adds (true) / removes (false). Stamps
-- everything, and if no officer peer is online marks it dirty so it is
-- re-stamped (share time, not edit time) and pushed at the next contact.
-- CM4: `extra` (optional) carries the things that aren't a plain record or
-- queue edit: extra.deleted = { discordName, ... } (accounts removed by a
-- merge -> tombstone), extra.pendingAdded = { entry, ... } (held donations),
-- extra.pendingReleased = { id, ... } (held donations that were applied).
function ns.CreditsSync_Changed(discordNames, queueChanges, extra)
    local db = EnsureDb()
    if not db then return end
    local peers = PeerList()
    local items, seen = {}, {}
    for _, disc in ipairs(discordNames or {}) do
        local rec = disc and db.ledger[disc]
        if rec and not seen[disc] then
            seen[disc] = true
            rec.syncedAt = NextStamp()
            rec.dirty = (#peers == 0) or nil
            items[#items + 1] = RecordItem(rec)
        end
    end
    for _, qc in ipairs(queueChanges or {}) do
        if qc.name and qc.name ~= "" then
            local q = { name = qc.name, present = qc.present and true or false, ts = NextStamp(), issue = qc.issue }
            q.dirty = (#peers == 0) or nil
            db.rqStamps[qc.name:lower()] = q
            items[#items + 1] = QueueItem(q)
        end
    end
    if extra then
        for _, name in ipairs(extra.deleted or {}) do
            local t = { ts = NextStamp(), dirty = (#peers == 0) or nil }
            db.ledgerTombstones[name] = t
            items[#items + 1] = TombItem(name, t)
        end
        for _, e in ipairs(extra.pendingAdded or {}) do
            e.syncedAt = NextStamp()
            e.dirty = (#peers == 0) or nil
            items[#items + 1] = PendingItem(e)
        end
        for _, id in ipairs(extra.pendingReleased or {}) do
            local t = { ts = NextStamp(), dirty = (#peers == 0) or nil }
            db.pendingReleased[id] = t
            items[#items + 1] = ReleasedItem(id, t)
        end
    end
    for _, peer in ipairs(peers) do
        SendItems(peer, items)
    end
end

-- Items changed after `since`, for answering a request.
local function CollectSince(since)
    local db = EnsureDb()
    local items = {}
    if not db then return items end
    for _, rec in pairs(db.ledger) do
        if (rec.syncedAt or 0) > since and not rec.dirty then items[#items + 1] = RecordItem(rec) end
    end
    for _, q in pairs(db.rqStamps) do
        if (q.ts or 0) > since and not q.dirty then items[#items + 1] = QueueItem(q) end
    end
    for name, t in pairs(db.ledgerTombstones) do
        if (t.ts or 0) > since and not t.dirty then items[#items + 1] = TombItem(name, t) end
    end
    for _, list in pairs(db.pendingCredits) do
        for _, e in ipairs(list) do
            if (e.syncedAt or 0) > since and not e.dirty then items[#items + 1] = PendingItem(e) end
        end
    end
    for id, t in pairs(db.pendingReleased) do
        if (t.ts or 0) > since and not t.dirty then items[#items + 1] = ReleasedItem(id, t) end
    end
    table.sort(items)
    return items
end

-- Re-stamp everything edited while no officer was reachable, then return the
-- items so they can be pushed now that someone is.
local function FlushDirty()
    local db = EnsureDb()
    local items = {}
    if not db then return items end
    for _, rec in pairs(db.ledger) do
        if rec.dirty then
            rec.syncedAt = NextStamp()
            rec.dirty = nil
            items[#items + 1] = RecordItem(rec)
        end
    end
    for _, q in pairs(db.rqStamps) do
        if q.dirty then
            q.ts = NextStamp()
            q.dirty = nil
            items[#items + 1] = QueueItem(q)
        end
    end
    for name, t in pairs(db.ledgerTombstones) do
        if t.dirty then
            t.ts = NextStamp()
            t.dirty = nil
            items[#items + 1] = TombItem(name, t)
        end
    end
    for _, list in pairs(db.pendingCredits) do
        for _, e in ipairs(list) do
            if e.dirty then
                e.syncedAt = NextStamp()
                e.dirty = nil
                items[#items + 1] = PendingItem(e)
            end
        end
    end
    for id, t in pairs(db.pendingReleased) do
        if t.dirty then
            t.ts = NextStamp()
            t.dirty = nil
            items[#items + 1] = ReleasedItem(id, t)
        end
    end
    return items
end

--------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------
local requestedFrom = {}   -- peer -> true once we asked them this session/appearance
local knownOnline = nil    -- peer set seen at the last roster update

local function SendRequest(peer)
    local db = EnsureDb()
    if not db then return end
    requestedFrom[peer] = true
    local since = math.max(0, (db.lastSyncAt or 0) - SINCE_SLACK)
    ns.Credits_SendAddon("LSYNCREQ|" .. ns.CreditsSync_Fingerprint() .. "|" .. since, "WHISPER", peer)
end

local function RequestFromPeers(peers)
    local db = EnsureDb()
    if not db or #peers == 0 then return end
    for _, peer in ipairs(peers) do
        SendRequest(peer)
        -- Audit-log reconciliation: our digest; the peer answers with the
        -- rows we lack (see "Audit-log replication").
        reconRounds[peer] = 0
        SendItems(peer, DigestItems(db))
    end
    db.lastSyncAt = time()
    local dirtyItems = FlushDirty()
    if #dirtyItems > 0 then
        for _, peer in ipairs(peers) do SendItems(peer, dirtyItems) end
    end
end

-- ~8s after login (guild roster populated by then): ask every online officer.
function ns.CreditsSync_OnLogin()
    if not ReceiverReady() then return end
    Later(LOGIN_DELAY, function()
        if not ReceiverReady() then return end
        local peers = PeerList()
        knownOnline = {}
        for _, p in ipairs(peers) do knownOnline[p] = true end
        RequestFromPeers(peers)
    end)
end

-- An officer who comes online later (or relogs) gets asked for what they
-- have; one who went offline is forgotten so a relog is treated as new.
function ns.CreditsSync_OnRosterUpdate()
    if knownOnline == nil then return end   -- login pass hasn't run yet
    Later(1, function()
        if not ReceiverReady() then return end
        local peers = PeerList()
        local nowOnline, fresh = {}, {}
        for _, p in ipairs(peers) do
            nowOnline[p] = true
            if not knownOnline[p] and not requestedFrom[p] then fresh[#fresh + 1] = p end
        end
        for p in pairs(knownOnline) do
            if not nowOnline[p] then requestedFrom[p] = nil end
        end
        knownOnline = nowOnline
        RequestFromPeers(fresh)
    end)
end

--------------------------------------------------------------------------
-- Receive
--------------------------------------------------------------------------
local buffers = {}      -- senderShort.."|"..id -> { total, chunks, got, born }
local warnedMismatch = {}

local function PruneBuffers()
    local now = time()
    for k, b in pairs(buffers) do
        if now - b.born > BUFFER_TTL then buffers[k] = nil end
    end
end

-- CM4 (spec step 9): lifetimePoints and lifetimeCredits only ever rise, so
-- a record that wins last-writer-wins on syncedAt still must not LOWER them
-- (an officer who edited a link before a donation reached them would
-- otherwise erase that donation's points), and a record that loses on
-- stamp but carries higher lifetime values still raises ours. tier/
-- prestige/points always derive from lifetimePoints, so they are
-- recomputed when it rises. The credits BALANCE stays plain last-writer-
-- wins (it can go down when spent). Returns true if `target` changed.
local function RaiseLifetime(target, source)
    local changed = false
    local lp = tonumber(source.lifetimePoints) or 0
    if lp > (tonumber(target.lifetimePoints) or 0) then
        target.lifetimePoints = lp
        target.tier, target.prestige, target.points = ns.Credits_TierStateForLifetime(lp)
        changed = true
    end
    local lc = tonumber(source.lifetimeCredits) or 0
    if lc > (tonumber(target.lifetimeCredits) or 0) then
        target.lifetimeCredits = lc
        changed = true
    end
    return changed
end

local function ApplyRecord(rec)
    local db = ns.creditsDb
    Observe(rec.syncedAt)
    -- A merge deleted this account: an equal-or-older copy must not bring
    -- it back (a newer one is a genuine re-creation and is allowed).
    local tomb = db.ledgerTombstones[rec.discordName]
    if tomb and (tomb.ts or 0) >= (rec.syncedAt or 0) then return false end
    local existing = db.ledger[rec.discordName]
    if existing then
        local a, b = rec.syncedAt or 0, existing.syncedAt or 0
        local incomingWins = true
        if a < b then incomingWins = false end
        if a == b and EncodeRecord(rec) <= EncodeRecord(existing) then incomingWins = false end
        if not incomingWins then
            return RaiseLifetime(existing, rec)
        end
        RaiseLifetime(rec, existing)
    end
    db.ledger[rec.discordName] = rec
    return true
end

local function ApplyTombstone(name, ts)
    local db = ns.creditsDb
    Observe(ts)
    local cur = db.ledgerTombstones[name]
    if cur and (cur.ts or 0) >= ts then return false end
    db.ledgerTombstones[name] = { ts = ts }
    local existing = db.ledger[name]
    if existing and (existing.syncedAt or 0) <= ts then
        db.ledger[name] = nil
    end
    return true
end

local function ApplyPending(e)
    local db = ns.creditsDb
    Observe(e.syncedAt)
    if db.pendingReleased[e.id] then return false end -- already released
    local key = e.sender:lower()
    local list = db.pendingCredits[key]
    if list then
        for _, have in ipairs(list) do
            if have.id == e.id then return false end
        end
    end
    db.pendingCredits[key] = list or {}
    table.insert(db.pendingCredits[key], e)
    return true
end

local function ApplyReleased(id, ts)
    local db = ns.creditsDb
    Observe(ts)
    local cur = db.pendingReleased[id]
    if cur and (cur.ts or 0) >= ts then return false end
    db.pendingReleased[id] = { ts = ts }
    for key, list in pairs(db.pendingCredits) do
        for i, e in ipairs(list) do
            if e.id == id then
                table.remove(list, i)
                break
            end
        end
        if #list == 0 then db.pendingCredits[key] = nil end
    end
    return true
end

local function ApplyQueue(name, present, ts, issue)
    local db = ns.creditsDb
    Observe(ts)
    local key = name:lower()
    local cur = db.rqStamps[key]
    if cur then
        local a, b = ts, cur.ts or 0
        if a < b then return false end
        if a == b and (present and 1 or 0) <= (cur.present and 1 or 0) then return false end
    end
    db.rqStamps[key] = { name = name, present = present, ts = ts, issue = issue }
    if present then
        ns.Credits_AddToReviewQueue(name, issue)
    else
        ns.Credits_RemoveFromReviewQueue(name)
    end
    return true
end

local function WarnMismatch(senderShort, theirFp)
    if warnedMismatch[senderShort] then return end
    warnedMismatch[senderShort] = true
    ns.CreditsPrint(("Ledger sync with %s skipped: their seed data differs from yours, or one of you has not had the latest \"start from scratch\" reset (%s vs %s). Both officers need the same DH-Tools version; a reset reaches an officer when the author / guild leader / recipient is online."):format(
        senderShort, theirFp, ns.CreditsSync_Fingerprint()))
end

local function ApplyPayload(payload, senderShort)
    local items = Split(payload, ";")
    local fp = (items[1] or ""):match("^F:(%x+)$")
    if not fp then return end
    if fp ~= ns.CreditsSync_Fingerprint() then
        WarnMismatch(senderShort, fp)
        return
    end
    local changedRecords, changedQueue = 0, 0
    -- Audit-log rows (T), digest window (W) and per-day digests (G).
    local addedLog, winFrom, winTo, theirDays = 0, nil, nil, {}
    local haveIds
    for i = 2, #items do
        local kind, body = items[i]:match("^(%a):(.*)$")
        if kind == "T" then
            local row = DecodeLogRow(body)
            if row then
                local db = ns.creditsDb
                if not haveIds then
                    haveIds = {}
                    for _, e in ipairs(db.transactionLog) do
                        if type(e) == "table" and e.id then haveIds[e.id] = true end
                    end
                end
                if not haveIds[row.id] and #db.transactionLog < MAX_LOG_ROWS then
                    haveIds[row.id] = true
                    table.insert(db.transactionLog, row)
                    addedLog = addedLog + 1
                end
            end
        elseif kind == "W" then
            local a, b = body:match("^(%-?%d+)|(%-?%d+)$")
            if a then winFrom, winTo = tonumber(a), tonumber(b) end
        elseif kind == "G" then
            local d, n, h = body:match("^(%-?%d+)|(%d+)|(%d+)$")
            if d then theirDays[tonumber(d)] = { n = tonumber(n), h = tonumber(h) } end
        elseif kind == "R" then
            local rec = DecodeRecord(body)
            if rec and ApplyRecord(rec) then changedRecords = changedRecords + 1 end
        elseif kind == "Q" then
            -- Q:<name>|<1/0>|<stamp>[|<issue>]  (issue absent from older senders)
            local n, st, ts, issue = body:match("^(.-)|([01])|(%d+)|?(.*)$")
            if n then
                local name = Unesc(n)
                issue = (issue and issue ~= "") and Unesc(issue) or nil
                if name ~= "" and ApplyQueue(name, st == "1", tonumber(ts), issue) then changedQueue = changedQueue + 1 end
            end
        elseif kind == "D" then
            local n, ts = body:match("^(.-)|(%d+)$")
            if n then
                local name = Unesc(n)
                if name ~= "" and ApplyTombstone(name, tonumber(ts)) then changedRecords = changedRecords + 1 end
            end
        elseif kind == "P" then
            local e = DecodePending(body)
            if e and ApplyPending(e) then changedQueue = changedQueue + 1 end
        elseif kind == "X" then
            local id, ts = body:match("^(.-)|(%d+)$")
            if id then
                id = Unesc(id)
                if id ~= "" and ApplyReleased(id, tonumber(ts)) then changedQueue = changedQueue + 1 end
            end
        end
    end
    if changedRecords > 0 then ns.Credits_RebuildToonIndex() end
    if addedLog > 0 then RewriteMergedAccounts(ns.creditsDb) end
    if winFrom then ReconcileLog(senderShort, winFrom, winTo, theirDays) end
    if changedRecords > 0 or changedQueue > 0 or addedLog > 0 then
        if ns.CreditsConfig_Refresh then ns.CreditsConfig_Refresh() end
    end
    -- CM4: a link/new account that just arrived may be what a held donation
    -- was waiting for (a no-op anywhere but the armed mail recipient).
    if changedRecords > 0 and ns.Credits_ReleasePending then ns.Credits_ReleasePending() end
end

-- Dispatched from Credits.lua's Credits_OnAddonMessage (own echo already dropped).
function ns.CreditsSync_OnMessage(msgType, rest, sender, senderShort)
    if not ReceiverReady() then return end
    if not SenderAllowed(senderShort) then return end
    EnsureDb()

    if msgType == "LSYNCREQ" then
        local fp, sinceStr = rest:match("^(%x+)|(%d+)$")
        if not fp then return end
        if fp ~= ns.CreditsSync_Fingerprint() then
            WarnMismatch(senderShort, fp)
            return
        end
        reconRounds[senderShort] = 0   -- a fresh ask resets the log-reconciliation cap
        SendItems(senderShort, CollectSince(tonumber(sinceStr) or 0))
        -- Reciprocate once so edits THIS client made while the requester was
        -- away flow back too. No loop: SendRequest marks requestedFrom.
        if not requestedFrom[senderShort] then SendRequest(senderShort) end

    elseif msgType == "LSYNCDATA" then
        local id, i, n, chunk = rest:match("^(%x+)|(%d+)/(%d+)|(.*)$")
        i, n = tonumber(i), tonumber(n)
        if not id or not i or not n or n < 1 or n > MAX_TOTAL_CHUNKS or i < 1 or i > n then return end
        PruneBuffers()
        local key = senderShort .. "|" .. id
        local buf = buffers[key]
        if not buf or buf.total ~= n then
            buf = { total = n, chunks = {}, got = 0, born = time() }
            buffers[key] = buf
        end
        if not buf.chunks[i] then
            buf.chunks[i] = chunk
            buf.got = buf.got + 1
        end
        if buf.got == buf.total then
            buffers[key] = nil
            ApplyPayload(table.concat(buf.chunks, "", 1, buf.total), senderShort)
        end
    end
end

-- Test/reset hook: forget session-only bookkeeping (not persisted data).
function ns.CreditsSync_ResetSession()
    requestedFrom, knownOnline, buffers, warnedMismatch = {}, nil, {}, {}
    lastStamp = 0
end
