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
    end
}

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
-- LAST_RELEASE_VERSION hardcoded "2.0.8" in Core.lua)
--------------------------------------------------------------------------

playerName = "TestChar"

-- "hasShownUpdateMessage" is a Core.lua-internal local that latches true
-- forever after firing once (by design - "shows once per session") and
-- isn't exposed for tests to reset, so this scenario must run FIRST,
-- exactly once, before anything else in this group.
local printCountBefore = #printLog
ns.frame:Fire("CHAT_MSG_ADDON", "DHToolsVer", "2.0.9", "GUILD", "Someone-Realm")
check("a peer announcing a newer version prints an update notice",
    #printLog == printCountBefore + 1 and printLog[#printLog]:find("newer version", 1, true) ~= nil)

ns.frame:Fire("CHAT_MSG_ADDON", "DHToolsVer", "2.0.9", "GUILD", "Someone-Realm")
check("a second identical newer-version announce does not re-print (shows once per session)",
    #printLog == printCountBefore + 1)

outboxLog = {}
ns.frame:Fire("CHAT_MSG_ADDON", "DHToolsVer", "2.0.0", "GUILD", "Stale-Realm")
check("a peer on an older version gets a direct WHISPER reply with our version",
    #outboxLog == 1 and outboxLog[1].channel == "WHISPER"
    and outboxLog[1].target == "Stale-Realm" and outboxLog[1].text == "2.0.8")

outboxLog, printLog = {}, {}
ns.frame:Fire("CHAT_MSG_ADDON", "DHToolsVer", "2.0.8", "GUILD", "SameVersion-Realm")
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
local FALLBACK_TEXT = "Nobody online has the DH-Bavin module enabled. Please install DH-Tools and enable the DH-Bavin module."

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
