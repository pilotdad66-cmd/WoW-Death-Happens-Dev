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

local fpCache, fpSeedRef, fpAltRef
function ns.CreditsSync_Fingerprint()
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
    fpCache = ("%08x"):format(h)
    fpSeedRef, fpAltRef = ns.CreditsSeedData, ns.CreditsAltRoster
    return fpCache
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
    }, "|")
end

-- Returns a record table, or nil if the text isn't a sane record.
local function DecodeRecord(text)
    local f = Split(text, "|")
    if #f < 11 or #f > 12 then return nil end
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
    return {
        discordName = discordName,
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
local function QueueItem(q) return "Q:" .. Esc(q.name) .. "|" .. (q.present and "1" or "0") .. "|" .. Num(q.ts) end

--------------------------------------------------------------------------
-- Local mutation -> stamp + push
--------------------------------------------------------------------------
-- Called by Credits.lua's Link/Unlink/SetAsNewMain AFTER they mutate the
-- ledger. discordNames = accounts whose record changed; queueChanges = list of
-- { name, present } review-queue adds (true) / removes (false). Stamps
-- everything, and if no officer peer is online marks it dirty so it is
-- re-stamped (share time, not edit time) and pushed at the next contact.
function ns.CreditsSync_Changed(discordNames, queueChanges)
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
            local q = { name = qc.name, present = qc.present and true or false, ts = NextStamp() }
            q.dirty = (#peers == 0) or nil
            db.rqStamps[qc.name:lower()] = q
            items[#items + 1] = QueueItem(q)
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
    for _, peer in ipairs(peers) do SendRequest(peer) end
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

local function ApplyRecord(rec)
    local db = ns.creditsDb
    local existing = db.ledger[rec.discordName]
    Observe(rec.syncedAt)
    if existing then
        local a, b = rec.syncedAt or 0, existing.syncedAt or 0
        if a < b then return false end
        if a == b and EncodeRecord(rec) <= EncodeRecord(existing) then return false end
    end
    db.ledger[rec.discordName] = rec
    return true
end

local function ApplyQueue(name, present, ts)
    local db = ns.creditsDb
    Observe(ts)
    local key = name:lower()
    local cur = db.rqStamps[key]
    if cur then
        local a, b = ts, cur.ts or 0
        if a < b then return false end
        if a == b and (present and 1 or 0) <= (cur.present and 1 or 0) then return false end
    end
    db.rqStamps[key] = { name = name, present = present, ts = ts }
    if present then
        ns.Credits_AddToReviewQueue(name)
    else
        ns.Credits_RemoveFromReviewQueue(name)
    end
    return true
end

local function WarnMismatch(senderShort, theirFp)
    if warnedMismatch[senderShort] then return end
    warnedMismatch[senderShort] = true
    ns.CreditsPrint(("Ledger sync with %s skipped: their seed data differs from yours (%s vs %s). Both officers need the same DH-Tools version."):format(
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
    for i = 2, #items do
        local kind, body = items[i]:match("^(%a):(.*)$")
        if kind == "R" then
            local rec = DecodeRecord(body)
            if rec and ApplyRecord(rec) then changedRecords = changedRecords + 1 end
        elseif kind == "Q" then
            local n, st, ts = body:match("^(.-)|([01])|(%d+)$")
            if n then
                local name = Unesc(n)
                if name ~= "" and ApplyQueue(name, st == "1", tonumber(ts)) then changedQueue = changedQueue + 1 end
            end
        end
    end
    if changedRecords > 0 then ns.Credits_RebuildToonIndex() end
    if changedRecords > 0 or changedQueue > 0 then
        if ns.CreditsConfig_Refresh then ns.CreditsConfig_Refresh() end
    end
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
