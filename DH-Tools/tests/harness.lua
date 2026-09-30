-- DH-Tools test harness (Core.lua).
-- Loads the ACTUAL DH-Tools\Core.lua against a mocked WoW API, same
-- pattern as DHAir/DHQuests/DHBavin's own tests\harness.lua files.
-- Covers: the module registry (RegisterModule/IsModuleEnabled/
-- SetModuleEnabled/ActivateEnabledModules), ADDON_LOADED's DHToolsDB
-- init gating, the Loopi author-account admin override (DHToolsAccountDB
-- flag path + 2026-09-14 GRM-based alt-resolution fallback), the peer
-- version-check broadcast, and the 2026-09-13/14 guild-chat item-lookup
-- BID/CLAIM protocol - the last of these was previously flagged (DH-Bavin
-- STATUS.md) as untested logic running live in the guild.
--
-- Config.lua/Minimap.lua are NOT loaded here (same UI-template exclusion
-- every other module's harness makes) - this only loads Core.lua.

local PASS, FAIL = 0, 0
local failures = {}

local function check(name, cond, detail)
    if cond then
        PASS = PASS + 1
    else
        FAIL = FAIL + 1
        table.insert(failures, name .. (detail and (" -- " .. detail) or ""))
        print("  FAIL: " .. name .. (detail and (" -- " .. detail) or ""))
    end
end

--------------------------------------------------------------------------
-- Mock WoW API
--------------------------------------------------------------------------

local gameTime = 1000
_G.GetTime = function() return gameTime end

local printLog = {}
_G.DEFAULT_CHAT_FRAME = {
    AddMessage = function(self, msg) table.insert(printLog, msg) end
}

-- Virtual-clock timer queue (C_Timer.After only - Core.lua never calls
-- NewTimer). Deadline-ordered, not FIFO: Core.lua schedules a short
-- BID_WINDOW (0.4s) finalize timer AFTER a much longer BID_FORGET (6.0s)
-- cleanup timer within the same call (RecordBid, then BidToAnswer) - a
-- naive FIFO-fires-oldest mock would fire the 6s cleanup first and wipe
-- bestBidSeen before the 0.4s finalize ever checks it. advanceTime(dt)
-- instead fires everything whose deadline the new gameTime has reached,
-- soonest-deadline-first.
local timers = {} -- { deadline = , fn = }
_G.C_Timer = {
    After = function(seconds, fn)
        table.insert(timers, { deadline = gameTime + (seconds or 0), fn = fn })
    end,
    -- PLAYER_LOGIN starts a periodic officer-access re-check (2026-09-29);
    -- the mock never fires it - tests call ns.RefreshOfficerAccess directly.
    NewTicker = function(seconds, fn) return { Cancel = function() end } end,
}

-- WoW globals the officer-gate code uses that bare Lua lacks (2026-09-29).
local wallClock = 1700000000
_G.time = function() return wallClock end
_G.date = os.date
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end

-- Guild roster mock: list of { name=, rank= }.
local rosterEntries = {}
local rosterRequests = 0
_G.GetNumGuildMembers = function() return #rosterEntries end
_G.GetGuildRosterInfo = function(i)
    local e = rosterEntries[i]
    if not e then return nil end
    return e.name, "Rank", e.rank
end
_G.C_GuildInfo = { GuildRoster = function() rosterRequests = rosterRequests + 1 end }

local function advanceTime(dt)
    gameTime = gameTime + (dt or 0)
    while true do
        local bestIdx, bestDeadline
        for i, t in ipairs(timers) do
            if t.deadline <= gameTime and (not bestDeadline or t.deadline < bestDeadline) then
                bestIdx, bestDeadline = i, t.deadline
            end
        end
        if not bestIdx then break end
        local t = table.remove(timers, bestIdx)
        t.fn()
    end
end

_G.CreateFrame = function(frameType, name, parentFrame, template)
    local f = {}
    local events, scripts = {}, {}
    f._name = name
    function f:RegisterEvent(e) events[e] = true end
    function f:UnregisterEvent(e) events[e] = nil end
    function f:IsEventRegistered(e) return events[e] end
    function f:SetScript(script, fn) scripts[script] = fn end
    function f:GetScript(script) return scripts[script] end
    function f:Fire(event, ...)
        if scripts.OnEvent then scripts.OnEvent(f, event, ...) end
    end
    -- Stubs for ns.InitStandaloneWindow's call chain (not exercised by
    -- any test here, but must not error if ever touched indirectly).
    function f:SetToplevel() end
    function f:SetMovable() end
    function f:EnableMouse() end
    function f:SetPoint() end
    function f:SetHeight() end
    function f:RegisterForDrag() end
    function f:CreateTexture() return { SetAllPoints = function() end, SetColorTexture = function() end } end
    return f
end

_G.SlashCmdList = {}

local playerName = "TestChar"
_G.UnitName = function(unit) return unit == "player" and playerName or nil end

local realmName = "SkullRock"
_G.GetRealmName = function() return realmName end

local inGuild = false
_G.IsInGuild = function() return inGuild end

-- Soft dependency - nil by default (GRM not installed), same as a real
-- client without the GRM addon. Tests that exercise the GRM-resolution
-- path in ns.IsAuthorAccount() set this to a table before calling it.
_G.GRM = nil

-- Deliberately NOT mocked (GetAddOnMetadata/C_AddOns left absent) so
-- ns.VERSION's own "unknown" fallback path gets exercised for free - see
-- the check() for it below.

local outboxLog = {} -- addon messages "sent" - { prefix=, text=, channel=, target= }
_G.C_ChatInfo = {
    SendAddonMessage = function(prefix, text, channel, target)
        table.insert(outboxLog, { prefix = prefix, text = text, channel = channel, target = target })
    end,
    RegisterAddonMessagePrefix = function(prefix) end,
}

local chatLog = {} -- real chat sends (the lookup protocol's actual reply) - { text=, channel= }
_G.SendChatMessage = function(text, channel)
    table.insert(chatLog, { text = text, channel = channel })
end

--------------------------------------------------------------------------
-- Load the real DH-Tools\Core.lua
--------------------------------------------------------------------------

local ADDON_NAME = "DH-Tools" -- matches DH-Tools.toc's actual folder/addon name
local coreChunk, coreErr = loadfile("C:\\AIProjects-NOSYNC\\WoW\\src\\DH-Tools\\Core.lua")
if not coreChunk then
    error("Failed to load Core.lua: " .. tostring(coreErr))
end
coreChunk(ADDON_NAME)

local ns = _G.DHTools

check("ns.VERSION falls back to 'unknown' when the metadata API is absent",
    ns.VERSION == "unknown")

-- ADDON_LOADED gating: must ignore every OTHER addon's own ADDON_LOADED
-- fire and only initialize DHToolsDB on DH-Tools' own.
DHToolsDB = nil
ns.frame:Fire("ADDON_LOADED", "SomeOtherAddon")
check("ADDON_LOADED for a different addon does not initialize DHToolsDB", DHToolsDB == nil)
ns.frame:Fire("ADDON_LOADED", ADDON_NAME)
check("ADDON_LOADED for DH-Tools itself initializes DHToolsDB",
    type(DHToolsDB) == "table" and type(DHToolsDB.modules) == "table")

-- Fixture modules registered ONCE (RegisterModule errors on a duplicate
-- key) - tests toggle their enabled state and inspect these counters
-- instead of re-registering.
local widgetEnableCount, widgetDisableCount = 0, 0
ns.RegisterModule("widget", {
    name = "Widget (test fixture)", default = false,
    OnEnable = function() widgetEnableCount = widgetEnableCount + 1 end,
    OnDisable = function() widgetDisableCount = widgetDisableCount + 1 end,
})

local gizmoEnableCount = 0
ns.RegisterModule("gizmo", {
    name = "Gizmo (test fixture)", default = true,
    OnEnable = function() gizmoEnableCount = gizmoEnableCount + 1 end,
})

-- Stands in for the real DH-Bavin module (not loaded here) purely so
-- ns.IsModuleEnabled("bavin") has something registered to check against
-- in the guild-chat lookup tests below.
ns.RegisterModule("bavin", { name = "Bavin (test fixture)", default = false })

local dupOk = pcall(ns.RegisterModule, "widget", { name = "dup" })
check("RegisterModule errors on a duplicate key instead of silently overwriting", dupOk == false)

--------------------------------------------------------------------------
-- Group A: module registry
--------------------------------------------------------------------------

check("IsModuleEnabled defaults to a fresh module's declared default (false)",
    ns.IsModuleEnabled("widget") == false)
check("IsModuleEnabled defaults to a fresh module's declared default (true)",
    ns.IsModuleEnabled("gizmo") == true)

ns.SetModuleEnabled("widget", true)
check("SetModuleEnabled(true) flips IsModuleEnabled", ns.IsModuleEnabled("widget") == true)
check("SetModuleEnabled(true) on an off->on transition fires OnEnable once", widgetEnableCount == 1)

ns.SetModuleEnabled("widget", true)
check("SetModuleEnabled(true) again (already on) does not re-fire OnEnable", widgetEnableCount == 1)

ns.SetModuleEnabled("widget", false)
check("SetModuleEnabled(false) flips IsModuleEnabled back off", ns.IsModuleEnabled("widget") == false)
check("SetModuleEnabled(false) on an on->off transition fires OnDisable once", widgetDisableCount == 1)

local unknownCountBefore = #printLog
ns.SetModuleEnabled("not-a-real-module", true)
check("SetModuleEnabled on an unknown key prints an error instead of erroring",
    #printLog == unknownCountBefore + 1 and printLog[#printLog]:find("Unknown module", 1, true) ~= nil)

--------------------------------------------------------------------------
-- Group A2: `requires` dependency cascade (2026-09-28, DH-Store module-
-- dependency mechanism) - both directions, plus boot-time self-heal.
-- depBase/depChild are dedicated fixtures (not gizmo/widget/bavin above)
-- so these tests don't disturb Group B's own PLAYER_LOGIN assertions.
--------------------------------------------------------------------------

local depBaseEnableCount, depBaseDisableCount = 0, 0
ns.RegisterModule("depBase", {
    name = "Dep Base (test fixture)", default = false,
    OnEnable = function() depBaseEnableCount = depBaseEnableCount + 1 end,
    OnDisable = function() depBaseDisableCount = depBaseDisableCount + 1 end,
})

local depChildEnableCount, depChildDisableCount = 0, 0
ns.RegisterModule("depChild", {
    name = "Dep Child (test fixture)", default = false, requires = "depBase",
    OnEnable = function() depChildEnableCount = depChildEnableCount + 1 end,
    OnDisable = function() depChildDisableCount = depChildDisableCount + 1 end,
})

check("a module with an unmet dependency starts disabled like any other default-false module",
    ns.IsModuleEnabled("depChild") == false)

-- Cascade UP: enabling the dependent auto-enables its unmet requirement first.
ns.SetModuleEnabled("depChild", true)
check("enabling a dependent module also enables its unmet requirement",
    ns.IsModuleEnabled("depBase") == true and ns.IsModuleEnabled("depChild") == true)
check("the cascaded requirement's OnEnable actually fired", depBaseEnableCount == 1)
check("the requested dependent's own OnEnable also fired", depChildEnableCount == 1)

-- Cascade DOWN: disabling the requirement auto-disables the dependent.
ns.SetModuleEnabled("depBase", false)
check("disabling a requirement also disables everything that depends on it",
    ns.IsModuleEnabled("depBase") == false and ns.IsModuleEnabled("depChild") == false)
check("the cascaded dependent's OnDisable actually fired", depChildDisableCount == 1)
check("the requirement's own OnDisable also fired", depBaseDisableCount == 1)

-- Enabling the requirement directly (not via a dependent) does NOT
-- auto-enable anything that depends on it - cascade only runs the
-- direction each toggle actually needs.
ns.SetModuleEnabled("depBase", true)
check("enabling a requirement on its own does not auto-enable its dependents",
    ns.IsModuleEnabled("depBase") == true and ns.IsModuleEnabled("depChild") == false)
ns.SetModuleEnabled("depBase", false) -- reset

-- Boot self-heal: a dependent saved as "on" with its requirement OFF
-- (hand-edited SavedVariables, or a profile predating this `requires`
-- relationship) must not run its OnEnable, and gets corrected in the DB
-- rather than trusted.
ns.db.modules.depBase = false
ns.db.modules.depChild = true
depChildEnableCount = 0
playerName = "TestChar"
ns.frame:Fire("PLAYER_LOGIN")
check("boot self-heal forces a dependent's stale 'on' flag off when its requirement is off",
    ns.IsModuleEnabled("depChild") == false)
check("boot self-heal does not run the dependent's OnEnable when self-healing it off",
    depChildEnableCount == 0)

-- Clean slate so later groups (esp. Group B's own PLAYER_LOGIN checks)
-- aren't affected by these fixtures.
ns.db.modules.depBase = false
ns.db.modules.depChild = false

--------------------------------------------------------------------------
-- Group B: PLAYER_LOGIN boot sequence (ActivateEnabledModules, CheckAuthorAccount)
--------------------------------------------------------------------------

local gizmoCountBeforeLogin = gizmoEnableCount
playerName = "RandomAlt"
DHToolsAccountDB = nil
ns.frame:Fire("PLAYER_LOGIN")
check("PLAYER_LOGIN's ActivateEnabledModules fires OnEnable for a default-on module",
    gizmoEnableCount == gizmoCountBeforeLogin + 1)
check("PLAYER_LOGIN's CheckAuthorAccount is a no-op for a non-author character name",
    DHToolsAccountDB == nil)
check("IsAuthorAccount is false with no DB flag, no GRM", ns.IsAuthorAccount() == false)

playerName = "Loopi"
DHToolsAccountDB = nil
ns.frame:Fire("PLAYER_LOGIN")
check("PLAYER_LOGIN's CheckAuthorAccount flags the account when Loopi logs in",
    type(DHToolsAccountDB) == "table" and DHToolsAccountDB.isAuthorAccount == true)
check("IsAuthorAccount reads the DHToolsAccountDB flag once set", ns.IsAuthorAccount() == true)

-- The flag is account-wide SavedVariables, not per-character - a
-- DIFFERENT character logging in afterward (on the same account, same
-- DHToolsAccountDB) should still read admin without needing GRM at all.
playerName = "LoopiAlt"
check("IsAuthorAccount stays true for another character once the account is flagged",
    ns.IsAuthorAccount() == true)

--------------------------------------------------------------------------
-- Group C: IsAuthorAccount's GRM-based alt-resolution fallback
--------------------------------------------------------------------------

-- Fresh account (no DHToolsAccountDB flag) - this is the case GRM
-- resolution exists for: an alt that's never had Loopi/Loopidot log in
-- on ITS account, but GRM can still prove it's one of Loopi's own alts.
DHToolsAccountDB = nil
playerName = "SomeLoopiAlt"
realmName = "SkullRock"

_G.GRM = nil
check("IsAuthorAccount false with no DB flag and GRM not installed", ns.IsAuthorAccount() == false)

_G.GRM = { GetPlayerMain = function(charRealm) return "Loopi-SkullRock" end }
check("IsAuthorAccount true via GRM resolving an alt to main character Loopi",
    ns.IsAuthorAccount() == true)

_G.GRM = { GetPlayerMain = function(charRealm) return "Someoneelse-SkullRock" end }
check("IsAuthorAccount false when GRM resolves to an unrelated main",
    ns.IsAuthorAccount() == false)

_G.GRM = { GetPlayerMain = function(charRealm) error("GRM internal error") end }
check("IsAuthorAccount survives a GRM call that errors (pcall-wrapped)",
    ns.IsAuthorAccount() == false)

_G.GRM = {} -- installed but doesn't expose GetPlayerMain (older version)
check("IsAuthorAccount false when GRM is present but lacks GetPlayerMain",
    ns.IsAuthorAccount() == false)

_G.GRM = nil
DHToolsAccountDB = nil
playerName = "TestChar"

--------------------------------------------------------------------------
-- Group D: peer version-check broadcast (VER_PREFIX = "DHToolsVer",
-- LAST_RELEASE_VERSION hardcoded "2.1.4" in Core.lua - bump these fixture
-- values in lockstep whenever that literal changes, same as everywhere
-- else this constant appears; drifting out of sync is exactly what broke
-- all four checks in this group on 2026-09-25, when v2.1.1 shipped and
-- LAST_RELEASE_VERSION was bumped but these fixtures weren't)
--------------------------------------------------------------------------

playerName = "TestChar"

-- "hasShownUpdateMessage" is a Core.lua-internal local that latches true
-- forever after firing once (by design - "shows once per session") and
-- isn't exposed for tests to reset, so this scenario must run FIRST,
-- exactly once, before anything else in this group.
local printCountBefore = #printLog
ns.frame:Fire("CHAT_MSG_ADDON", "DHToolsVer", "2.1.5", "GUILD", "Someone-Realm")
check("a peer announcing a newer version prints an update notice",
    #printLog == printCountBefore + 1 and printLog[#printLog]:find("newer version", 1, true) ~= nil)

ns.frame:Fire("CHAT_MSG_ADDON", "DHToolsVer", "2.1.5", "GUILD", "Someone-Realm")
check("a second identical newer-version announce does not re-print (shows once per session)",
    #printLog == printCountBefore + 1)

outboxLog = {}
ns.frame:Fire("CHAT_MSG_ADDON", "DHToolsVer", "2.0.0", "GUILD", "Stale-Realm")
check("a peer on an older version gets a direct WHISPER reply with our version",
    #outboxLog == 1 and outboxLog[1].channel == "WHISPER"
    and outboxLog[1].target == "Stale-Realm" and outboxLog[1].text == "2.1.4")

outboxLog, printLog = {}, {}
ns.frame:Fire("CHAT_MSG_ADDON", "DHToolsVer", "2.1.4", "GUILD", "SameVersion-Realm")
check("a peer on the exact same version triggers neither a print nor a reply",
    #outboxLog == 0 and #printLog == 0)

outboxLog, printLog = {}, {}
ns.frame:Fire("CHAT_MSG_ADDON", "DHToolsVer", "2.0.0", "GUILD", "TestChar-SkullRock")
check("our own echoed broadcast (sender == our own name) is ignored",
    #outboxLog == 0 and #printLog == 0)

outboxLog, printLog = {}, {}
ns.frame:Fire("CHAT_MSG_ADDON", "DHToolsVer", "not-a-version", "GUILD", "Garbage-Realm")
check("a malformed version payload is silently ignored, not an error",
    #outboxLog == 0 and #printLog == 0)

outboxLog = {}
ns.frame:Fire("CHAT_MSG_ADDON", "SomeOtherAddonPrefix", "2.0.0", "GUILD", "Other-Realm")
check("a CHAT_MSG_ADDON on an unrelated prefix is ignored by the version checker",
    #outboxLog == 0)

--------------------------------------------------------------------------
-- Group E: guild-chat item lookup (LOOKUP_PREFIX = "DHToolsLookupV1")
--------------------------------------------------------------------------

local ITEM_LINK = "|cffffffff|Hitem:12345:0:0:0:0:0:0:0|h[Test Item]|h|r"
local ITEM_LINK2 = "|cffffffff|Hitem:67890:0:0:0:0:0:0:0|h[Second Item]|h|r"
local FALLBACK_TEXT = "Nobody online has the Bavin Points module enabled. Please install DH-Tools and enable the Bavin Points module."

local classifyResult -- what ns.Bavin.TryClassifyLookup returns this test
ns.Bavin = {
    IsInTargetGuild = function() return true end,
    NormalizeName = function(sender) return sender:match("^([^%-]+)") or sender end,
    TryClassifyLookup = function(link) return classifyResult end,
}

local function resetLookupState()
    outboxLog, chatLog, timers = {}, {}, {}
    classifyResult = nil
end

-- E1: full success path - sole bidder wins after BID_WINDOW.
resetLookupState()
classifyResult = "Test Item is worth 5g (Bavin)"
ns.SetModuleEnabled("bavin", true)

ns.frame:Fire("CHAT_MSG_GUILD", "?" .. ITEM_LINK, "Asker-SkullRock")
check("a '?'+item-link guild message with Bavin enabled schedules a classify attempt, no immediate send",
    #outboxLog == 0 and #chatLog == 0 and #timers >= 1)

advanceTime(1) -- fires the classify-defer timer -> BidToAnswer -> broadcasts BID, schedules BID_FORGET + BID_WINDOW
check("classifying successfully broadcasts a BID before the reply is sent",
    #outboxLog == 1 and outboxLog[1].prefix == "DHToolsLookupV1"
    and outboxLog[1].text:match("^BID|") ~= nil and #chatLog == 0)

local bidKey = outboxLog[1].text:match("^BID|(.+)|[^|]+$")

advanceTime(1) -- fires BID_WINDOW's finalize (0.4s) - sole bidder, so it wins and claims
check("the sole bidder wins after BID_WINDOW and posts the real reply to guild chat",
    #chatLog == 1 and chatLog[1].channel == "GUILD" and chatLog[1].text == classifyResult
    and #outboxLog == 2 and outboxLog[2].text == "CLAIM|" .. bidKey)

-- E2: a CLAIM for our own bid's key arriving before OUR bid finalizes
-- makes us stand down (never post, never send our own CLAIM) - tests the
-- "someone else's bid was lower" branch of the BID_WINDOW finalize check.
resetLookupState()
classifyResult = "Second item value"
ns.frame:Fire("CHAT_MSG_GUILD", "?" .. ITEM_LINK2, "Asker2-SkullRock")
advanceTime(1) -- fires classify-defer -> broadcasts our own BID for key2
local key2 = outboxLog[1].text:match("^BID|(.+)|[^|]+$")

ns.frame:Fire("CHAT_MSG_ADDON", "DHToolsLookupV1", "CLAIM|" .. key2, "GUILD", "OtherClaimer-Realm")
advanceTime(1) -- fires our BID_WINDOW finalize - should see lookupClaims[key2] already true and stand down
check("hearing another client's CLAIM before our own BID_WINDOW finalizes makes us stand down",
    #chatLog == 0 and #outboxLog == 1) -- only our original BID, no CLAIM/reply of our own

-- (one BID_FORGET cleanup timer from the win above is still legitimately
-- pending here - only asserting no NEW timer gets scheduled, not that
-- the queue is empty.)
local outboxCountAfterStandDown, timerCountAfterStandDown = #outboxLog, #timers
ns.frame:Fire("CHAT_MSG_GUILD", "?" .. ITEM_LINK2, "Asker2-SkullRock")
check("re-asking an already-claimed question triggers no new bid at all",
    #outboxLog == outboxCountAfterStandDown and #timers == timerCountAfterStandDown)

-- E3: Bavin disabled -> fallback text path (no classify attempt at all).
resetLookupState()
ns.SetModuleEnabled("bavin", false)

ns.frame:Fire("CHAT_MSG_GUILD", "?" .. ITEM_LINK, "FallbackAsker-SkullRock")
advanceTime(1)
advanceTime(1)
check("with Bavin disabled, the fallback text is bid and eventually posted",
    #chatLog == 1 and chatLog[1].text:find(FALLBACK_TEXT, 1, true) ~= nil)

ns.SetModuleEnabled("bavin", true)

-- E4: guard checks - not a "?" message, off-target-guild, oversized reply.
resetLookupState()
ns.frame:Fire("CHAT_MSG_GUILD", "just chatting, no question here", "Chatter-SkullRock")
check("a guild message not starting with '?' triggers nothing", #timers == 0 and #outboxLog == 0)

resetLookupState()
local savedIsInTargetGuild = ns.Bavin.IsInTargetGuild
ns.Bavin.IsInTargetGuild = function() return false end
ns.frame:Fire("CHAT_MSG_GUILD", "?" .. ITEM_LINK, "OffGuildAsker-SkullRock")
check("a '?'+item-link message is ignored entirely when not in the target guild",
    #timers == 0 and #outboxLog == 0)
ns.Bavin.IsInTargetGuild = savedIsInTargetGuild

resetLookupState()
classifyResult = ("x"):rep(300) -- longer than guild chat's 255-char cap
ns.frame:Fire("CHAT_MSG_GUILD", "?" .. ITEM_LINK, "LongReplyAsker-SkullRock")
advanceTime(1)
advanceTime(1)
check("a reply longer than 255 chars is truncated to the cap with a trailing ellipsis",
    #chatLog == 1 and #chatLog[1].text == 255 and chatLog[1].text:sub(-3) == "...")

-- E5: cache-miss retry via GET_ITEM_INFO_RECEIVED.
resetLookupState()
classifyResult = nil -- first attempt: genuine cache miss, not an error
ns.frame:Fire("CHAT_MSG_GUILD", "?" .. ITEM_LINK, "RetryAsker-SkullRock")
advanceTime(1) -- fires the classify-defer timer; TryClassifyLookup returns nil -> registers a pending retry
check("a cache-miss classify attempt registers a retry instead of bidding the fallback text",
    #outboxLog == 0 and #chatLog == 0)

classifyResult = "Resolved on retry"
ns.frame:Fire("GET_ITEM_INFO_RECEIVED", 12345, true)
check("GET_ITEM_INFO_RECEIVED re-attempts classification and bids once it succeeds",
    #outboxLog == 1 and outboxLog[1].text:match("^BID|") ~= nil)

advanceTime(1)
check("the retried classification's reply is posted once BID_WINDOW elapses",
    #chatLog == 1 and chatLog[1].text == "Resolved on retry")

--------------------------------------------------------------------------
-- Group F: shared Officer Settings gate (2026-09-29, Loopi) - the rank
-- number is account-wide + guild-synced, officer ROLES grant access
-- regardless of rank, and the button follows roster/role changes.
--------------------------------------------------------------------------
do
    local RANK_PREFIX = "DHToolsRankV1"
    local function sendRank(text, sender)
        ns.frame:Fire("CHAT_MSG_ADDON", RANK_PREFIX, text, "GUILD", sender)
    end
    local function lastOut() return outboxLog[#outboxLog] end

    -- Fresh, non-author client: a Lieutenant (guild rank 4) on a new account.
    DHToolsAccountDB = {}
    DHBavinDB, DHStoreDB = nil, nil
    _G.GRM = nil
    inGuild = true
    playerName = "Lieutenant"
    rosterEntries = {
        { name = "Lieutenant-SkullRock", rank = 4 },
        { name = "GM-SkullRock", rank = 0 },
        { name = "Recruit-SkullRock", rank = 6 },
        { name = "Loopi-SkullRock", rank = 2 },
        { name = "Sergeant-SkullRock", rank = 5 },
    }
    ns.UpdateRosterRankCache()
    outboxLog = {}

    -- ADDON_LOADED now creates the account DB for everybody (not just the author).
    local savedAcct = DHToolsAccountDB
    DHToolsAccountDB = nil
    ns.frame:Fire("ADDON_LOADED", ADDON_NAME)
    check("ADDON_LOADED creates DHToolsAccountDB for every player", type(DHToolsAccountDB) == "table")
    DHToolsAccountDB = savedAcct

    -- Default gate: 0-3, so a rank-4 Lieutenant does NOT see the button.
    check("default shared gate is 3", ns.GetOfficerMaxRank() == 3 and ns.GetOfficerRankStamp() == 0)
    check("rank 4 is outside the default gate", ns.IsOfficerLocal() == false)
    check("rank 4 cannot change the gate", ns.CanSetOfficerRankLocal() == false)
    local ok, reason = ns.SetOfficerMaxRank(5)
    check("a non-leader is refused when setting the gate", ok == false and reason == "permission")
    check("...and nothing was broadcast or stored", #outboxLog == 0 and ns.GetOfficerMaxRank() == 3)

    -- The guild leader sets it: stored account-wide, stamped, broadcast.
    playerName = "GM"
    check("the guild leader may change the gate", ns.CanSetOfficerRankLocal() == true)
    ok, reason = ns.SetOfficerMaxRank(10)
    check("an out-of-range gate value is refused", ok == false and reason == "range")
    ok, reason = ns.SetOfficerMaxRank("x")
    check("a non-numeric gate value is refused", ok == false and reason == "range")
    ok = ns.SetOfficerMaxRank(5)
    local gmStamp = ns.GetOfficerRankStamp()
    check("the leader's set succeeds and is stored account-wide",
        ok == true and ns.GetOfficerMaxRank() == 5 and DHToolsAccountDB.officerVisibleMaxRank == 5 and gmStamp >= wallClock)
    check("...and is broadcast to the guild as RANK|n|stamp on the DH-Tools rank prefix",
        lastOut() and lastOut().prefix == RANK_PREFIX and lastOut().channel == "GUILD"
        and lastOut().text == "RANK|5|" .. gmStamp)

    -- Lieutenant's own client receives it live from the leader.
    playerName = "Lieutenant"
    DHToolsAccountDB = {}
    check("before the message arrives the Lieutenant still has the default", ns.IsOfficerLocal() == false)
    sendRank("RANK|5|" .. gmStamp, "GM-SkullRock")
    check("a live RANK from the guild leader is applied", ns.GetOfficerMaxRank() == 5 and ns.GetOfficerRankStamp() == gmStamp)
    check("...and rank 4 now passes the gate", ns.IsOfficerLocal() == true)

    -- Authorization + validation on receive.
    sendRank("RANK|0|" .. (gmStamp + 10), "Recruit-SkullRock")
    check("a live RANK from a non-leader is ignored", ns.GetOfficerMaxRank() == 5)
    sendRank("RANK|0|" .. (gmStamp + 10), "Stranger-SkullRock")
    check("a live RANK from someone not in the guild is ignored", ns.GetOfficerMaxRank() == 5)
    sendRank("RANK|1|" .. (gmStamp - 1), "GM-SkullRock")
    check("an older stamp never overwrites a newer value", ns.GetOfficerMaxRank() == 5)
    sendRank("RANK|12|" .. (gmStamp + 10), "GM-SkullRock")
    check("an out-of-range value from the leader is refused", ns.GetOfficerMaxRank() == 5)
    sendRank("RANK|garbage", "GM-SkullRock")
    check("a malformed message is ignored without error", ns.GetOfficerMaxRank() == 5)
    sendRank("RANK|2|" .. (gmStamp + 20), "Loopi-SkullRock")
    check("the author character's live RANK is accepted (name-based, like the Bavin/Store syncs)",
        ns.GetOfficerMaxRank() == 2 and ns.GetOfficerRankStamp() == gmStamp + 20)
    check("...so rank 4 loses access again when the leader tightens the gate", ns.IsOfficerLocal() == false)

    -- Relay / catch-up replies (RANKR): any known guild member, newer stamp, sane time.
    sendRank("RANKR|4|" .. (gmStamp + 30), "Recruit-SkullRock")
    check("a relayed RANKR with a newer stamp is accepted from any guild member",
        ns.GetOfficerMaxRank() == 4 and ns.IsOfficerLocal() == true)
    sendRank("RANKR|0|" .. (wallClock + 5000), "Recruit-SkullRock")
    check("a relayed RANKR stamped far in the future is refused", ns.GetOfficerMaxRank() == 4)
    sendRank("RANKR|0|" .. (gmStamp + 31), "Stranger-SkullRock")
    check("a relayed RANKR from a non-guild-member is refused", ns.GetOfficerMaxRank() == 4)

    -- Catch-up: answering somebody else's RANKREQ.
    local mine = ns.GetOfficerRankStamp()
    outboxLog = {}
    sendRank("RANKREQ|" .. mine, "Recruit-SkullRock")
    advanceTime(6)
    check("no reply when the requester already has our stamp", #outboxLog == 0)
    sendRank("RANKREQ|0", "Recruit-SkullRock")
    advanceTime(6)
    check("a client holding a newer value replies with RANKR to the guild",
        #outboxLog == 1 and outboxLog[1].text == "RANKR|4|" .. mine and outboxLog[1].channel == "GUILD")
    outboxLog = {}
    sendRank("RANKREQ|0", "Recruit-SkullRock")
    sendRank("RANKR|4|" .. mine, "Sergeant-SkullRock")
    advanceTime(6)
    check("a pending reply is suppressed once someone else already answered", #outboxLog == 0)
    DHToolsAccountDB = {}
    outboxLog = {}
    sendRank("RANKREQ|0", "Recruit-SkullRock")
    advanceTime(6)
    check("a client with nothing stored never replies", #outboxLog == 0)

    -- Login request goes out once, carrying our stamp.
    outboxLog = {}
    ns.RankSync_Request()
    check("RankSync_Request sends RANKREQ with our stamp",
        #outboxLog == 1 and outboxLog[1].text == "RANKREQ|0" and outboxLog[1].prefix == RANK_PREFIX)

    -- Officer ROLES grant access regardless of guild rank.
    DHToolsAccountDB = {}
    DHBavinDB, DHStoreDB = nil, nil
    playerName = "Recruit" -- rank 6, far outside any gate
    check("no roles, rank 6: no access", ns.HasOfficerRole("Recruit") == false and ns.IsOfficerLocal() == false)
    DHBavinDB = { recipient = "Recruit", editors = {} }
    check("Donation Recipient grants access regardless of rank", ns.HasOfficerRole("Recruit") == true and ns.IsOfficerLocal() == true)
    DHBavinDB = { editors = { "Someone", "Recruit-SkullRock" } }
    check("Distribution Officer grants access (realm suffix tolerated)", ns.IsOfficerLocal() == true)
    DHBavinDB = nil
    DHStoreDB = { primaryOfficer = "recruit" }
    check("Primary Store Officer grants access (case-insensitive)", ns.IsOfficerLocal() == true)
    DHStoreDB = { officers = { "RECRUIT" } }
    check("Store Officer grants access", ns.IsOfficerLocal() == true)
    DHStoreDB = { officers = { "Sergeant" }, primaryOfficer = "Sergeant" }
    check("someone else's role does not grant this player access", ns.IsOfficerLocal() == false)
    DHStoreDB = "not a table"
    check("a malformed role table is ignored without error", ns.HasOfficerRole("Recruit") == false)
    DHStoreDB = nil
    check("HasOfficerRole(nil) is false", ns.HasOfficerRole(nil) == false)

    -- The button follows changes: callback fires once per real change.
    local changes, lastState = 0, nil
    ns.OnOfficerAccessChanged = function(state) changes = changes + 1; lastState = state end
    ns.RefreshOfficerAccess(true)
    check("RefreshOfficerAccess(force) always notifies", changes == 1 and lastState == false)
    ns.RefreshOfficerAccess()
    check("...and an unchanged state does not notify again", changes == 1)
    DHBavinDB = { editors = { "Recruit" } }
    ns.RefreshOfficerAccess()
    check("being assigned a role notifies with true", changes == 2 and lastState == true)
    DHBavinDB = nil
    ns.RefreshOfficerAccess()
    check("losing the role notifies with false", changes == 3 and lastState == false)
    ns.OnOfficerAccessChanged = nil

    -- The roster arriving late flips the answer (the "roster not loaded" bug).
    rosterEntries = {}
    ns.UpdateRosterRankCache()
    playerName = "GM"
    DHToolsAccountDB = {}
    check("roster not loaded yet: no rank-based access", ns.IsOfficerLocal() == false)
    rosterEntries = { { name = "GM-SkullRock", rank = 0 } }
    ns.frame:Fire("GUILD_ROSTER_UPDATE")
    check("GUILD_ROSTER_UPDATE refreshes the rank cache so the gate passes", ns.IsOfficerLocal() == true)

    -- DH-Tools asks for the roster itself.
    local before = rosterRequests
    ns.RequestGuildRoster()
    check("RequestGuildRoster asks the client for the roster when in a guild", rosterRequests == before + 1)
    inGuild = false
    ns.RequestGuildRoster()
    check("...and does nothing when not in a guild", rosterRequests == before + 1)
    inGuild = true

    -- /dht rank status readout runs cleanly.
    local printsBefore = #printLog
    SlashCmdList["DHTOOLS"]("rank")
    check("/dht rank prints the gate and the player's access",
        #printLog == printsBefore + 2 and printLog[printsBefore + 1]:find("Officer Settings gate", 1, true) ~= nil)

    -- Leave the shared fixtures clean for anything after this group.
    DHToolsAccountDB, DHBavinDB, DHStoreDB = nil, nil, nil
    rosterEntries = {}
    ns.UpdateRosterRankCache()
    outboxLog = {}
end

--------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------

print(("DH-Tools Core.lua: %d passed, %d failed"):format(PASS, FAIL))
if FAIL > 0 then
    print("Failures:")
    for _, f in ipairs(failures) do
        print("  - " .. f)
    end
    os.exit(1)
end
os.exit(0)
