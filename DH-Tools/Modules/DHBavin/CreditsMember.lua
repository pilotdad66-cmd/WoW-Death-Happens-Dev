-- CM6 step 1 (see DH-Bavin-Credits-Design.md, member push/pull): every guild
-- member can see their OWN reputation and credits in "View my Account" and
-- the Store, even though only officers hold the ledger (CM3).
-- Agreed design, 2026-10-09 (Loopi):
--   * Balance only in this step. The last-50 history rows are step 2.
--   * Any online officer may answer a pull. If that ever becomes a problem,
--     the trusted set is limited in ONE place: OfficerMayAnswer() below.
--   * The Account window shows the note "Module in Testing. Data may be old."
--   * Rides the EXISTING credits prefix (DHBavinCreditsV2) with three NEW,
--     additive message types; older clients ignore them (no prefix bump).
--
-- WIRE (prefix DHBavinCreditsV2, WHISPER only):
--   MYBALREQ|1                   member -> up to 2 random online officers:
--                                "what is MY balance?" (login pull, or the
--                                Refresh button).
--   BALDATA|1|<epoch>|<sentAt>|<discord>|<main>|<points>|<credits>|<tier>|
--     <prestige>|<lifetimePoints>|<lifetimeCredits>|<lastDonationDate>|
--     <lastUpdated>              officer -> member, in answer to MYBALREQ, or
--                                pushed when an officer's edit/donation changes
--                                the account (batched at MAIL_CLOSED, with a
--                                quiet-timer fallback).
--   BALNONE|<epoch>|<sentAt>     "no account on file for you (yet)".
--   Strings are %-escaped for  % | ; , ~  like CreditsSync.lua.
--
-- TRUST:
--   * The officer looks the account up by the WHISPER SENDER's own name
--     (via the toon index), never by anything the message claims, so a member
--     can only ever be told about their own account.
--   * The member accepts a reply only from a guild member that its OWN
--     officer list (ns.db.editors, replicated guild-wide) or the guild leader
--     vouches for - same check the ledger sync uses.
--   * Officers never accept these replies: they hold the ledger itself.
--   * Merge: a higher dataEpoch ("Start from scratch" number) replaces; a
--     lower one is rejected. Same epoch: lifetime points only ever rise, so
--     higher wins; equal lifetime points -> newer lastUpdated wins.

local DHTools = DHTools
DHTools.Bavin = DHTools.Bavin or {}
local ns = DHTools.Bavin

local PROTO = "1"
local LOGIN_DELAY = 14          -- after CreditsSync's 8s, so the roster is populated
local RETRY_EVERY = 120         -- login pull: try again if no officer answered
local MAX_ATTEMPTS = 5
local MANUAL_COOLDOWN = 300     -- Refresh button
local ANSWER_COOLDOWN = 60      -- per requester, officer side
local PUSH_QUIET = 45           -- seconds after the last change before pushing
local MAX_PUSH_SENDS = 40       -- per flush
local MAX_ASK = 2               -- officers asked per pull
-- The 255-byte addon-message limit counts the prefix too ("DHBavinCreditsV2" = 16).
local MAX_MSG = 255 - #"DHBavinCreditsV2"

--------------------------------------------------------------------------
-- Helpers (local copies of the CreditsSync.lua ones - that file's are local)
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

local function Db()
    return ns.creditsDb
end

local function MyShort()
    return ns.NormalizeName(UnitName("player"))
end

local function IsOfficerLocal()
    return ns.creditsDb ~= nil and ns.IsInTargetGuild() and ns.CanManageCreditsConfigLocal()
end

local function LedgerHasData()
    local db = Db()
    return db ~= nil and type(db.ledger) == "table" and next(db.ledger) ~= nil
end

local function LedgerRecordForName(name)
    local db = Db()
    if not db or type(db.toonIndex) ~= "table" or type(db.ledger) ~= "table" then return nil end
    local key = db.toonIndex[(name or ""):lower()]
    local rec = key and db.ledger[key]
    if rec then return rec, key end
    return nil
end

-- THE single place that decides which officers may answer a pull. Today:
-- any online officer (or the guild leader) who holds ledger data. To limit
-- the trusted set later, tighten this one function.
local function OfficerMayAnswer()
    return IsOfficerLocal() and LedgerHasData()
end

-- Online officers / guild leader other than me, from the guild-roster cache.
local function OnlineOfficers()
    local out, me = {}, MyShort()
    for name, entry in pairs(ns.guildRoster or {}) do
        if entry.online and name ~= me and (ns.IsGuildLeader(name) or ns.IsOfficerName(name)) then
            out[#out + 1] = name
        end
    end
    table.sort(out)
    return out
end

--------------------------------------------------------------------------
-- Member-side cache: creditsDb.memberBal[lower(character name)]
--------------------------------------------------------------------------
-- Per CHARACTER (not per WoW account) so two characters that belong to
-- different Discord accounts can never show each other's balance.
local function Store()
    local db = Db()
    if not db then return nil end
    if type(db.memberBal) ~= "table" then db.memberBal = {} end
    return db.memberBal
end

local function MyEntry()
    local s = Store()
    if not s then return nil end
    return s[MyShort():lower()]
end

-- "cached" | "none" | nil, plus the entry.
function ns.CreditsMember_Status()
    local e = MyEntry()
    if not e then return nil end
    if e.none then return "none", e end
    return "cached", e
end

-- A pseudo ledger record built from the cache, shaped like a ledger record so
-- Account.lua / the Store can use it unchanged. mainToon/alts are left out on
-- purpose: Account.lua then falls back to the shipped alt roster.
function ns.CreditsMember_GetCachedRecord()
    local e = MyEntry()
    if not e or e.none then return nil end
    return {
        discordName = e.discordName, discord = e.discord,
        points = e.points, credits = e.credits, tier = e.tier, prestige = e.prestige,
        lifetimePoints = e.lifetimePoints, lifetimeCredits = e.lifetimeCredits,
        lastDonationDate = e.lastDonationDate, lastUpdated = e.lastUpdated,
        fromCache = true, receivedAt = e.receivedAt, source = e.source,
    }, e.discordName
end

local function NotifyUi()
    if ns.Account_Refresh then pcall(ns.Account_Refresh) end
    local store = DHTools.Store
    if store and store.UpdateBalances then pcall(store.UpdateBalances) end
end

--------------------------------------------------------------------------
-- Encode (officer side)
--------------------------------------------------------------------------
local function EncodeBal(rec, epoch, sentAt)
    local discord = ns.Credits_GetDiscord and ns.Credits_GetDiscord(rec) or rec.discordName
    local function build(d)
        return table.concat({
            "BALDATA", PROTO, Num(epoch), Num(sentAt), Esc(d), Esc(rec.mainToon),
            Num(rec.points), Num(rec.credits), Esc(rec.tier), Num(rec.prestige),
            Num(rec.lifetimePoints), Num(rec.lifetimeCredits or rec.credits),
            Esc(rec.lastDonationDate), Num(rec.lastUpdated),
        }, "|")
    end
    local msg = build(discord)
    if #msg > MAX_MSG then msg = build("") end   -- the Discord name is the only long field
    if #msg > MAX_MSG then return nil end
    return msg
end

ns.CreditsMember_EncodeBal = EncodeBal

--------------------------------------------------------------------------
-- Officer side: answer a pull
--------------------------------------------------------------------------
local lastAnswer = {}

local function AnswerRequest(sender, senderShort)
    if not OfficerMayAnswer() then return end
    if not ns.IsGuildMember(senderShort) then return end
    local now = time()
    local last = lastAnswer[senderShort]
    if last and now - last < ANSWER_COOLDOWN then return end
    lastAnswer[senderShort] = now
    local epoch = Db().dataEpoch or 0
    local rec = LedgerRecordForName(senderShort)   -- by SENDER name only
    local msg = rec and EncodeBal(rec, epoch, now) or ("BALNONE|" .. Num(epoch) .. "|" .. Num(now))
    if msg then ns.Credits_SendAddon(msg, "WHISPER", sender) end
end

--------------------------------------------------------------------------
-- Member side: accept a reply
--------------------------------------------------------------------------
local replied = false   -- got a valid answer this session -> stop login retries

local function SaneNum(x, maxv)
    return x ~= nil and x >= 0 and x <= (maxv or 1e9)
end

local function DecodeBalData(rest)
    local f = Split(rest, "|")
    if #f ~= 13 or f[1] ~= PROTO then return nil end
    local epoch, sentAt = tonumber(f[2]), tonumber(f[3])
    local points, credits, prestige = tonumber(f[6]), tonumber(f[7]), tonumber(f[9])
    local lifetimePoints, lifetimeCredits, lastUpdated = tonumber(f[10]), tonumber(f[11]), tonumber(f[13])
    if not (epoch and sentAt and points and credits and prestige and lifetimePoints and lifetimeCredits and lastUpdated) then
        return nil
    end
    if not (SaneNum(epoch, 1e6) and SaneNum(points) and SaneNum(credits) and SaneNum(prestige, 1000)
        and SaneNum(lifetimePoints) and SaneNum(lifetimeCredits) and SaneNum(lastUpdated, 4e9)) then
        return nil
    end
    local tier = Unesc(f[8])
    if not (ns.CreditsTierCaps and ns.CreditsTierCaps[tier]) then return nil end
    local discord, main = Unesc(f[4]), Unesc(f[5])
    if #discord > 64 or #main > 64 then return nil end
    if lifetimeCredits < credits then lifetimeCredits = credits end
    return {
        epoch = epoch, sentAt = sentAt, discord = discord, discordName = discord ~= "" and discord or main,
        mainToon = main, points = points, credits = credits, tier = tier, prestige = prestige,
        lifetimePoints = lifetimePoints, lifetimeCredits = lifetimeCredits,
        lastDonationDate = Unesc(f[12]), lastUpdated = lastUpdated,
    }
end

-- Is `new` at least as good as what we hold?
local function Newer(new, old)
    if not old or old.none then return true end
    if new.epoch ~= (old.epoch or 0) then return new.epoch > (old.epoch or 0) end
    if new.lifetimePoints ~= old.lifetimePoints then return new.lifetimePoints > old.lifetimePoints end
    return new.lastUpdated >= (old.lastUpdated or 0)
end

local function AcceptReply(msgType, rest, senderShort)
    if IsOfficerLocal() then return end                         -- officers hold the ledger itself
    if not ns.IsGuildMember(senderShort) then return end
    if not ns.Credits_IsAuthorizedSender(senderShort) then return end   -- officer / guild leader only
    local store = Store()
    if not store then return end
    local key = MyShort():lower()
    local old = store[key]

    if msgType == "BALDATA" then
        local new = DecodeBalData(rest)
        if not new then return end
        replied = true
        if not Newer(new, old) then return end
        new.receivedAt = time()
        new.source = senderShort
        store[key] = new
    else -- BALNONE
        local f = Split(rest, "|")
        local epoch = tonumber(f[1])
        if not epoch or not SaneNum(epoch, 1e6) then return end
        replied = true
        -- Never let "no account" wipe a real balance of the same or a newer epoch.
        if old and not old.none and (old.epoch or 0) >= epoch then return end
        if old and old.none and (old.epoch or 0) > epoch then return end
        store[key] = { none = true, epoch = epoch, receivedAt = time(), source = senderShort }
    end
    NotifyUi()
end

--------------------------------------------------------------------------
-- Member side: ask
--------------------------------------------------------------------------
local function AskOfficers()
    local peers = OnlineOfficers()
    -- Fisher-Yates so the load spreads over whoever is online.
    for i = #peers, 2, -1 do
        local j = math.random(i)
        peers[i], peers[j] = peers[j], peers[i]
    end
    local asked = 0
    for i = 1, math.min(MAX_ASK, #peers) do
        ns.Credits_SendAddon("MYBALREQ|" .. PROTO, "WHISPER", peers[i])
        asked = asked + 1
    end
    return asked
end

local attempts = 0
local function LoginPull()
    if replied or attempts >= MAX_ATTEMPTS then return end
    attempts = attempts + 1
    if ns.creditsDb and ns.IsInTargetGuild() and not IsOfficerLocal() then
        AskOfficers()
    end
    if attempts < MAX_ATTEMPTS then Later(RETRY_EVERY, LoginPull) end
end

local lastManual = nil
-- Refresh button. Returns ok, message for the caller to print.
function ns.CreditsMember_Refresh()
    if not (ns.creditsDb and ns.IsInTargetGuild()) then
        return false, "You need to be in Death Happens to refresh."
    end
    if IsOfficerLocal() then
        return false, "Officers read the ledger directly - nothing to refresh."
    end
    local now = time()
    if lastManual and now - lastManual < MANUAL_COOLDOWN then
        return false, ("Please wait %d more seconds before refreshing again."):format(MANUAL_COOLDOWN - (now - lastManual))
    end
    if AskOfficers() == 0 then
        return false, "No officer is online right now - try again later."
    end
    lastManual = now
    return true, "Asked an officer for your latest balance. It will update here when they answer."
end

--------------------------------------------------------------------------
-- Officer side: push after a change
--------------------------------------------------------------------------
local pending, pushGen = {}, 0

local function Flush()
    local db = Db()
    local names = pending
    pending = {}
    if not db or type(db.ledger) ~= "table" then return end
    local epoch, now, me = db.dataEpoch or 0, time(), MyShort()
    -- lowercase -> roster entry, so a differently-cased toon name still matches
    local online = {}
    for name, entry in pairs(ns.guildRoster or {}) do
        if entry.online then online[name:lower()] = name end
    end
    local sends, seenTarget = {}, {}
    for disc in pairs(names) do
        local rec = db.ledger[disc]
        local msg = rec and EncodeBal(rec, epoch, now)
        if msg then
            local toons = { rec.mainToon }
            for _, a in ipairs(rec.alts or {}) do toons[#toons + 1] = a end
            for _, t in ipairs(toons) do
                local short = t and t ~= "" and online[ns.NormalizeName(t):lower()]
                -- Officers already hold the ledger; skip them and me.
                if short and short ~= me and not seenTarget[short]
                    and not ns.IsGuildLeader(short) and not ns.IsOfficerName(short) then
                    seenTarget[short] = true
                    sends[#sends + 1] = { short, msg }
                end
            end
        end
    end
    for i, s in ipairs(sends) do
        if i > MAX_PUSH_SENDS then break end
        Later((i - 1) * 0.2, function() ns.Credits_SendAddon(s[2], "WHISPER", s[1]) end)
    end
end

ns.CreditsMember_Flush = Flush

-- Called by CreditsSync_Changed with the ledger keys that changed locally.
function ns.CreditsMember_NoteChanged(discordNames)
    if not IsOfficerLocal() then return end
    local any = false
    for _, disc in ipairs(discordNames or {}) do
        if disc then pending[disc] = true; any = true end
    end
    if not any then return end
    pushGen = pushGen + 1
    local gen = pushGen
    Later(PUSH_QUIET, function()
        if gen == pushGen and next(pending) then Flush() end
    end)
end

--------------------------------------------------------------------------
-- Dispatch (from Credits.lua's Credits_OnAddonMessage)
--------------------------------------------------------------------------
function ns.CreditsMember_OnMessage(msgType, rest, sender, senderShort, channel)
    if channel ~= "WHISPER" then return end
    if not ns.creditsDb then return end
    if msgType == "MYBALREQ" then
        AnswerRequest(sender, senderShort)
    elseif msgType == "BALDATA" or msgType == "BALNONE" then
        AcceptReply(msgType, rest, senderShort)
    end
end

--------------------------------------------------------------------------
-- Events: login pull + flush at mailbox close
--------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("MAIL_CLOSED")
ev:SetScript("OnEvent", function(_, event)
    if DHTools.IsModuleEnabled and not DHTools.IsModuleEnabled("bavin") then return end
    if event == "PLAYER_LOGIN" then
        Later(LOGIN_DELAY, LoginPull)
    elseif event == "MAIL_CLOSED" then
        pushGen = pushGen + 1          -- cancel the quiet timer; flush now
        if next(pending) then Flush() end
    end
end)
