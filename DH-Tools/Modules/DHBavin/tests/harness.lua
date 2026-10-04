-- DH-Bavin test harness (Milestone 6).
-- Loads the ACTUAL DHBavin module files (Core, Sync, ItemPoints) against
-- a mocked WoW API, mirroring DH-Quests' own tests\harness.lua pattern
-- (which itself mirrors DH-Air's). PointsEditor.lua, PriorityEditor.lua,
-- BagMail.lua, and Tooltip.lua are NOT loaded here - all four are
-- UI/Blizzard-frame-hook heavy (CreateFrame chrome, GameTooltip hooks,
-- ContainerFrame_Update/SendMailFrame hooks), same exclusion category as
-- DH-Quests' own Board.lua and DH-Air's Minimap.lua/Config.lua - covered
-- by manual/in-game review instead, never by this harness.
--
-- DH-Tools' own Core.lua is ALSO not loaded - re-implements a minimal
-- DHTools mock instead (RegisterModule/SetModuleEnabled/IsModuleEnabled/
-- Print/InitDB), same reasoning DH-Quests' harness gives.
--
-- Deliberately exercises real risk areas flagged as still-unverified in
-- claude\DH-Bavin\STATUS.md wherever the risk is pure LOGIC (not
-- WoW-client-specific rendering): the 2026-08-04 guild-membership
-- re-verification fix, the multi-chunk SYNCDATA reassembly path (never
-- actually forced past one chunk in real testing yet), and every
-- permission gate's grant/refusal in BOTH directions (send-side local
-- gate AND receive-side "never trust a self-asserted sender" check).
-- This proves the LOGIC is correct - it does NOT replace the still-
-- required real in-game test pass (different guarantee: real client,
-- real roster, real second player) per README's testing rule.

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

local printLog = {}
_G.DEFAULT_CHAT_FRAME = {
    AddMessage = function(self, msg) table.insert(printLog, msg) end
}

-- Real-client "time()" (wall-clock seconds) is a plain WoW-exposed global,
-- unlike bare Lua's os.time() - Core.lua's SetItemPoints/RevertItemPoints
-- call time() directly for editedAt. Fixed, controllable value (not
-- os.time()) so tests are reproducible and can advance it deliberately.
local wallClock = 1700000000
_G.time = function() return wallClock end
-- GetTime() (session-uptime seconds) is separate from time() above -
-- Sync.lua's AddItem/RemoveItem use GetTime() for addedBy/addedAt local
-- bookkeeping (see Sync.lua's priorityList comment: NOT part of the wire
-- payload). A fixed value is enough; nothing here depends on it advancing.
_G.GetTime = function() return 5000 end

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
    return f
end

_G.SlashCmdList = {}

local currentPlayerName = "TestChar"
_G.UnitName = function(unit)
    if unit == "player" then return currentPlayerName end
    return nil
end

local inGuild = false
_G.IsInGuild = function() return inGuild end
_G.GuildRoster = function() end
_G.C_GuildInfo = { GuildRoster = function() end }

-- k-0019 (2026-08-06): the guild NAME the current test character is in -
-- defaults to the real target guild ("Death Happens", matching Core.lua's
-- hardcoded TARGET_GUILD_NAME) so every existing test below that sets
-- `inGuild = true` keeps passing unmodified. Tests that specifically
-- exercise the off-guild/wrong-guild case set this to something else
-- (or leave inGuild = false entirely for "no guild at all").
local currentGuildName = "Death Happens"
_G.GetGuildInfo = function(unit)
    if unit ~= "player" then return nil end
    return currentGuildName
end

-- guildRosterEntries: ordered list of { name=, rankIndex=, online= }.
local guildRosterEntries = {}
_G.GetNumGuildMembers = function() return #guildRosterEntries end
_G.GetGuildRosterInfo = function(i)
    local e = guildRosterEntries[i]
    if not e then return nil end
    -- Matches Core.lua's assumed positions: name, rank, rankIndex, level,
    -- class, zone, note, officernote, isOnline (rankIndex=3rd, online=9th).
    return e.name, "Rank", e.rankIndex or 5, 60, "Warrior", "Zone", "", "", (e.online ~= false)
end

-- outboxLog: every outbound addon message this client "sent", captured
-- instead of actually transmitted - { prefix=, text=, channel=, target= }.
local outboxLog = {}
_G.C_ChatInfo = {
    SendAddonMessage = function(prefix, text, channel, target)
        table.insert(outboxLog, { prefix = prefix, text = text, channel = channel, target = target })
    end,
    RegisterAddonMessagePrefix = function(prefix) end,
}

_G.GetItemInfo = function(linkOrId) return nil end -- not exercised directly (see header)

-- Minimal re-implementation of DH-Tools' own module registry, same
-- pattern/reasoning as DH-Quests' harness.
local registeredModules = {}
local moduleEnabled = {}
-- Controllable mock for the 2026-08-05 account-wide author-admin override
-- (DHTools.IsAuthorAccount) - real Core.lua derives this from
-- DHToolsAccountDB.isAuthorAccount, set once at PLAYER_LOGIN for the
-- handful of hardcoded author character names. Tests flip this flag
-- directly rather than simulating the SavedVariables/PLAYER_LOGIN path,
-- since that plumbing lives in DH-Tools' own Core.lua (not loaded here -
-- see header) and is exercised separately.
local authorAccountFlag = false
_G.DHTools = {
    Print = function(msg) table.insert(printLog, msg) end,
    InitDB = function() end, -- module enable/disable state, unrelated to DHBavinDB
    IsAuthorAccount = function() return authorAccountFlag end,
    db = {},
    RegisterModule = function(key, def)
        registeredModules[key] = def
    end,
    SetModuleEnabled = function(key, enabled)
        local def = registeredModules[key]
        local wasEnabled = moduleEnabled[key]
        if wasEnabled == nil and def then wasEnabled = def.default end
        moduleEnabled[key] = enabled
        if enabled and not wasEnabled and def and def.OnEnable then
            def.OnEnable()
        elseif not enabled and wasEnabled and def and def.OnDisable then
            def.OnDisable()
        end
    end,
    IsModuleEnabled = function(key)
        if moduleEnabled[key] == nil then
            local def = registeredModules[key]
            return def ~= nil and def.default or false
        end
        return moduleEnabled[key]
    end,
    Config_Open = nil,
}

--------------------------------------------------------------------------
-- Load the real DHBavin files (PointsEditor/PriorityEditor/BagMail/
-- Tooltip excluded - see header)
--------------------------------------------------------------------------

local ADDON_ROOT = "C:\\AIProjects-NOSYNC\\WoW\\src\\DH-Tools\\Modules\\DHBavin\\"
local FILES = { "Core.lua", "Sync.lua", "ItemPoints.lua", "ToonDonations.lua", "Credits.lua", "CreditsSeed.lua", "CreditsSync.lua" }

for _, filename in ipairs(FILES) do
    local chunk, err = loadfile(ADDON_ROOT .. filename)
    if not chunk then
        error("Failed to load " .. filename .. ": " .. tostring(err))
    end
    chunk()
end

local ns = _G.DHTools.Bavin

-- Real bootstrapping (DH-Tools' own Core.lua) unconditionally fires
-- OnEnable for every enabled-by-default module, same as DH-Quests'
-- harness does for its own module.
if registeredModules["bavin"] and registeredModules["bavin"].OnEnable then
    moduleEnabled["bavin"] = true
    registeredModules["bavin"].OnEnable()
end

-- Simulate PLAYER_LOGIN (Sync_Init, RequestGuildRoster).
ns.frame:Fire("PLAYER_LOGIN")
-- Credits.lua owns its own frame (ns.creditsFrame, separate from
-- ns.frame - see that file's Wall 1 header) - PLAYER_LOGIN there is
-- what calls InitCreditsDB(), so ns.creditsDb doesn't exist until this
-- fires too.
ns.creditsFrame:Fire("PLAYER_LOGIN")

--------------------------------------------------------------------------
-- Test helpers
--------------------------------------------------------------------------

local function resetState()
    outboxLog, printLog = {}, {}
    inGuild = false
    currentGuildName = "Death Happens" -- k-0019
    guildRosterEntries = {}
    currentPlayerName = "TestChar"
    ns.guildRoster = {}
    -- 2026-08-05: clear IN PLACE, never reassign - ns.priorityList is now
    -- the SAME table object as ns.db.priorityList (DHBavinDB.priorityList,
    -- see Core.lua's InitDB()), and `ns.priorityList = {}` would silently
    -- detach the alias, defeating the persistence check in the new
    -- "Priority list persistence" section below and making the rest of
    -- this harness quietly stop testing the real by-reference behavior.
    for name in pairs(ns.priorityList) do
        ns.priorityList[name] = nil
    end
    ns.syncBuffers = {}
    ns.ptsSyncBuffers = {}
    ns.db.recipient = nil
    ns.db.editors = {}
    ns.db.itemPointsOverrides = {}
    -- k-0012: reset the list's version stamp too, so each test section
    -- starts from a genuinely "empty, no history" client instead of
    -- silently carrying over whatever time() value an earlier section's
    -- AddItem/RemoveItem/ITEM/ITEMGONE calls left behind - that stale
    -- carryover would otherwise make an incoming SYNCDATA's timestamp
    -- collide with (rather than exceed) the local one in later sections.
    ns.db.priorityListUpdatedAt = 0
    -- k-0019: same reasoning as priorityListUpdatedAt's reset above -
    -- start each section from a genuinely "no history" client.
    ns.db.recipientEditorsUpdatedAt = 0
    authorAccountFlag = false
    -- Credits system (Identity model v2) - reset IN PLACE, same reasoning
    -- as ns.priorityList above: ns.creditsDb IS DHBavinCreditsDB, and
    -- nothing else holds a separate reference to it, but reassigning the
    -- field tables themselves (rather than DHBavinCreditsDB) keeps this
    -- symmetric with every other reset here and avoids depending on
    -- InitCreditsDB's own "only if missing" guards to do the clearing.
    if ns.creditsDb then
        ns.creditsDb.ledger = {}
        ns.creditsDb.toonIndex = {}
        ns.creditsDb.dynamicReviewQueue = {}
        ns.creditsDb.transactionLog = {}
        -- 2026-09-28: officers field removed - Credits no longer keeps
        -- its own officer list (see "Credits: permission gates" below).
        ns.creditsDb.masterToggle = false
        ns.creditsDb.creditTestReceivers = {}
        ns.creditsDb.creditTestSenders = {}
        ns.creditsDb.configUpdatedAt = 0
        -- CM3 sync bookkeeping (CreditsSync.lua)
        ns.creditsDb.rqStamps = {}
        ns.creditsDb.lastSyncAt = nil
    end
    if ns.CreditsSync_ResetSession then ns.CreditsSync_ResetSession() end
    ns.CreditsSeedData = nil
    ns.CreditsAltRoster = nil
    ns.CreditsReviewQueue = nil
end

local function outboxOfType(msgType)
    local matches = {}
    for _, entry in ipairs(outboxLog) do
        if entry.text == msgType or entry.text:match("^" .. msgType .. "|") then
            table.insert(matches, entry)
        end
    end
    return matches
end

--------------------------------------------------------------------------
-- Section 1: Guild roster cache - IsGuildLeader / IsGuildMember
--------------------------------------------------------------------------
print("== IsGuildLeader / IsGuildMember ==")
resetState()
inGuild = true
guildRosterEntries = {
    { name = "GLeader", rankIndex = 0 },
    { name = "Editor1", rankIndex = 3 },
}
ns.UpdateGuildRosterCache()

check("Rank 0 member is the guild leader", ns.IsGuildLeader("GLeader") == true)
check("Non-rank-0 member is not the guild leader", ns.IsGuildLeader("Editor1") == false)
check("Loopidot override grants leader status even when NOT in the roster at all",
    ns.IsGuildLeader("Loopidot") == true)
check("Known member (any rank) counts as a guild member", ns.IsGuildMember("Editor1") == true)
check("Unknown name does not count as a guild member", ns.IsGuildMember("RandomStranger") == false)
check("Leader also counts as a guild member", ns.IsGuildMember("GLeader") == true)

--------------------------------------------------------------------------
-- Section 2: CanManageRecipient / CanManageEditors / SetRecipient /
-- SetEditors gating
--------------------------------------------------------------------------
-- 2026-08-05 (Loopi): TESTING_ALLOW_ANYONE_TO_MANAGE is gone - recipient
-- and editor management are now separately scoped, real enforcement, no
-- bypass. CanManageRecipient: only the name "Bavin" or "Loopidot".
-- CanManageEditors (2026-09-28, Chris - shared officer-roles list):
-- guild leader, the current recipient, or "Loopidot" - no more rank<=3
-- threshold (see Core.lua's CanSetEditorsName comment).
print("== CanManageRecipient / CanManageEditors / SetRecipient / SetEditors ==")
resetState()
inGuild = true
guildRosterEntries = {
    { name = "GLeader", rankIndex = 0 },
    { name = "Officer1", rankIndex = 3 },
    { name = "Grunt1", rankIndex = 5 },
}
ns.UpdateGuildRosterCache()

-- A rank-0 guild leader is NOT automatically a recipient manager - only
-- the literal names Bavin/Loopidot are (this is the key behavior change
-- from the old IsGuildLeader-based gate).
currentPlayerName = "GLeader"
check("A rank-0 guild leader who isn't Bavin/Loopidot cannot manage the recipient",
    ns.CanManageRecipient() == false)
check("...and SetRecipient is refused for them", ns.SetRecipient("Bavin") == false)
check("Refused SetRecipient does not change local state", ns.db.recipient == nil)
check("Refused SetRecipient sends nothing", #outboxOfType("RECIPIENT") == 0)
check("A guild leader CAN manage editors/officers even though they can't manage the recipient",
    ns.CanManageEditors() == true)

-- An officer (rank<=3, not guild leader/recipient/Loopidot) can no
-- longer manage editors either as of 2026-09-28 - only guild leader,
-- recipient, or Loopidot may.
currentPlayerName = "Officer1"
check("A rank<=3 officer who isn't guild leader/recipient/Loopidot cannot manage the recipient",
    ns.CanManageRecipient() == false)
check("...and can no longer manage editors/officers either (2026-09-28 tightening)",
    ns.CanManageEditors() == false)
check("SetEditors is refused for a rank<=3 officer who isn't guild leader/recipient",
    ns.SetEditors({ "Officer1" }) == false)

-- A regular member (rank>3, not Bavin/Loopidot) can manage neither.
currentPlayerName = "Grunt1"
check("A rank>3 member cannot manage the recipient", ns.CanManageRecipient() == false)
check("A rank>3 member cannot manage editors", ns.CanManageEditors() == false)
check("SetEditors is refused for a rank>3 member", ns.SetEditors({ "Grunt1" }) == false)

-- Bavin (any rank, even not a guild member at all) can manage the
-- recipient specifically, by name.
currentPlayerName = "Bavin" -- deliberately NOT in guildRosterEntries above
check("Bavin (unverified guild membership - name-based check only) can manage the recipient",
    ns.CanManageRecipient() == true)
check("Bavin's SetRecipient succeeds", ns.SetRecipient("Bavin") == true)
check("Recipient was actually stored", ns.db.recipient == "Bavin")
check("A RECIPIENT broadcast was sent", #outboxOfType("RECIPIENT") == 1)
check("Bavin can now manage editors/officers too, having just become the recipient (2026-09-28)",
    ns.CanManageEditors() == true)

-- Loopidot (FULL_PERMISSION_OVERRIDE_NAME) can manage both, regardless
-- of rank or roster membership at all.
currentPlayerName = "Loopidot"
check("Loopidot can manage the recipient even when not in the roster",
    ns.CanManageRecipient() == true)
check("Loopidot can manage editors even when not in the roster",
    ns.CanManageEditors() == true)

--------------------------------------------------------------------------
-- Section 2b: Author account admin override (account-wide, local-only)
--------------------------------------------------------------------------
-- DHTools.IsAuthorAccount() is the 2026-08-05 account-wide replacement
-- for the old per-character "Loopidot" override, letting Loopi manage
-- from ANY alt once one author character has logged in once (see
-- DH-Tools\Core.lua). Proves CanManageRecipient/CanManageEditors/
-- CanEditListLocal all honor it under the real permission model, and -
-- critically - that it does NOT leak into the receive-side verification
-- functions (CanEditList/CanSetRecipientName/CanSetEditorsName called
-- with a remote sender name), since those must keep trusting only the
-- guild roster/name allowlist, never a local SavedVariables flag nobody
-- but this client can see.
print("== Author account admin override ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "GLeader", rankIndex = 0 }, { name = "Bavin", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
ns.db.editors = {}
currentPlayerName = "RandomAlt" -- not Bavin/Loopidot, not rank<=3, not an editor

authorAccountFlag = false
check("Flag off: an unrelated alt's CanManageRecipient is false", ns.CanManageRecipient() == false)
check("Flag off: an unrelated alt's CanManageEditors is false", ns.CanManageEditors() == false)
check("Flag off: an unrelated alt's CanEditListLocal is false", ns.CanEditListLocal() == false)

authorAccountFlag = true
check("Flag on: the SAME unrelated alt's CanManageRecipient is now true",
    ns.CanManageRecipient() == true)
check("Flag on: the SAME unrelated alt's CanManageEditors is now true",
    ns.CanManageEditors() == true)
check("Flag on: the SAME unrelated alt's CanEditListLocal is now true",
    ns.CanEditListLocal() == true)
check("Flag on: SetRecipient actually succeeds for this alt", ns.SetRecipient("GLeader") == true)

check("The flag does NOT leak into receive-side CanEditList for a remote sender name",
    ns.CanEditList("SomeRandomRemoteSender") == false)
check("The flag does NOT leak into receive-side CanSetRecipientName for a remote sender name",
    ns.CanSetRecipientName("SomeRandomRemoteSender") == false)
check("The flag does NOT leak into receive-side CanSetEditorsName for a remote sender name",
    ns.CanSetEditorsName("SomeRandomRemoteSender") == false)

authorAccountFlag = false

--------------------------------------------------------------------------
-- Section 2c: off-guild / wrong-guild character - k-0019
--------------------------------------------------------------------------
-- Root-cause fix for the bug Chris hit in real testing: logging into a
-- character that's in SOME guild, just not Death Happens, used to build
-- ns.guildRoster from that OTHER guild's member list, making every real
-- Death Happens recipient/editor name look like it "left the guild" and
-- triggering a real wipe of account-wide DHBavinDB. ns.IsInTargetGuild()
-- now gates roster-building, pruning, AND every local edit permission -
-- including the author-account override, per Chris's explicit
-- instruction that off-guild characters must not be able to edit or
-- change anything, even his own.
print("== Off-guild / wrong-guild character (k-0019) ==")

resetState()
-- Not in a guild at all.
inGuild = false
check("IsInTargetGuild is false with no guild at all", ns.IsInTargetGuild() == false)

resetState()
-- In A guild, just not Death Happens - the exact scenario Chris hit.
inGuild = true
currentGuildName = "Some Other Guild"
guildRosterEntries = { { name = "GLeader", rankIndex = 0 }, { name = "Bavin", rankIndex = 3 } }
check("IsInTargetGuild is false when in a DIFFERENT guild", ns.IsInTargetGuild() == false)

ns.UpdateGuildRosterCache()
check("UpdateGuildRosterCache builds NOTHING from a non-Death-Happens guild's roster",
    next(ns.guildRoster) == nil)

-- Seed valid recipient/editors as if they'd synced in earlier while on a
-- real Death Happens character (still sharing this same account-wide
-- DHBavinDB), then force the exact failure mode: a non-empty roster
-- cache (so the OLD empty-roster guard alone would NOT have caught this)
-- built from a different guild.
ns.db.recipient = "Bavin"
ns.db.editors = { "Ed1" }
ns.guildRoster = { GLeader = { rankIndex = 0 }, Bavin = { rankIndex = 3 } } -- simulate a stale/foreign cache directly
ns.frame:Fire("GUILD_ROSTER_UPDATE")
check("PruneDepartedRecipientEditors does NOT run off the target guild - recipient survives",
    ns.db.recipient == "Bavin")
check("...editors survive too", #ns.db.editors == 1 and ns.db.editors[1] == "Ed1")
check("No prune message was printed (the function returned before doing anything)", #printLog == 0)

-- No local edit authority at all off-guild, for anyone - including
-- names that would normally always qualify.
currentPlayerName = "Bavin"
check("Bavin (normally always the recipient manager) cannot manage the recipient off-guild",
    ns.CanManageRecipient() == false)
currentPlayerName = "Loopidot"
check("Loopidot (normally a full override) cannot manage the recipient off-guild",
    ns.CanManageRecipient() == false)
check("...or the editors list off-guild", ns.CanManageEditors() == false)

-- Chris's explicit requirement: the account-wide author override must
-- NOT bypass this either.
authorAccountFlag = true
check("Author-account override does NOT grant CanManageRecipient off-guild",
    ns.CanManageRecipient() == false)
check("Author-account override does NOT grant CanManageEditors off-guild",
    ns.CanManageEditors() == false)
check("Author-account override does NOT grant CanEditListLocal off-guild",
    ns.CanEditListLocal() == false)
authorAccountFlag = false

-- Confirms the fix actually restores normal function back in the real
-- guild - not a permanent lockout, just gated on being in it.
currentGuildName = "Death Happens"
ns.UpdateGuildRosterCache()
check("IsInTargetGuild is true again back in Death Happens", ns.IsInTargetGuild() == true)
currentPlayerName = "Bavin"
check("Bavin can manage the recipient again once back in Death Happens",
    ns.CanManageRecipient() == true)

--------------------------------------------------------------------------
-- Section 3: Receive-side verification - never trust a self-asserted sender
--------------------------------------------------------------------------
-- 2026-08-05: RECIPIENT and EDITORS are now separately gated
-- (CanSetRecipientName: Bavin/Loopidot by name; CanSetEditorsName, as of
-- 2026-09-28: guild leader/recipient/Loopidot, no more rank<=3) - a
-- rank-0 guild leader who isn't Bavin/Loopidot can no longer set the
-- recipient remotely either, same tightening as the local gate in
-- Section 2.
print("== Receive-side RECIPIENT/EDITORS verification ==")
resetState()
inGuild = true
guildRosterEntries = {
    { name = "RealLeader", rankIndex = 0 },
    { name = "Officer1", rankIndex = 3 },
    { name = "Grunt1", rankIndex = 4 },
}
ns.UpdateGuildRosterCache()

ns.Sync_OnAddonMessage("DHBavinV4", "RECIPIENT|Someone", "GUILD", "Grunt1")
check("A RECIPIENT message from a rank>3 non-Bavin/Loopidot sender is ignored",
    ns.db.recipient == nil)

ns.Sync_OnAddonMessage("DHBavinV4", "RECIPIENT|Someone", "GUILD", "RealLeader")
check("A RECIPIENT message from a rank-0 leader who isn't Bavin/Loopidot is ALSO ignored now",
    ns.db.recipient == nil)

ns.Sync_OnAddonMessage("DHBavinV4", "RECIPIENT|Someone", "GUILD", "Bavin")
check("A RECIPIENT message from the sender name 'Bavin' is accepted (name-based, not rank-based)",
    ns.db.recipient == "Someone")

ns.db.recipient = nil
ns.Sync_OnAddonMessage("DHBavinV4", "EDITORS|Officer1", "GUILD", "Officer1")
check("An EDITORS message from a rank<=3 sender who isn't guild leader/recipient/Loopidot is now ignored (2026-09-28)",
    #ns.db.editors == 0)

ns.Sync_OnAddonMessage("DHBavinV4", "EDITORS|Officer1", "GUILD", "RealLeader")
check("An EDITORS message from a verified guild leader is accepted",
    #ns.db.editors == 1 and ns.db.editors[1] == "Officer1")

--------------------------------------------------------------------------
-- Section 4: CanEditList - grants + the 2026-08-04 guild-membership fix
--------------------------------------------------------------------------
print("== CanEditList (recipient/editor grants + guild-membership requirement) ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "Bavin", rankIndex = 3 }, { name = "Ed1", rankIndex = 5 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
ns.db.editors = { "Ed1" }

check("The recipient can edit the list", ns.CanEditList("Bavin") == true)
check("A named editor can edit the list", ns.CanEditList("Ed1") == true)
check("An unrelated guild member cannot", ns.CanEditList("RandomStranger") == false)

-- Ed1 leaves the guild (removed from the roster) - CanEditList must
-- revoke access immediately, even though ns.db.editors STILL literally
-- contains "Ed1" (the separate cosmetic pruning step is Section 6,
-- tested independently - this proves authorization doesn't depend on it).
guildRosterEntries = { { name = "Bavin", rankIndex = 3 } }
ns.UpdateGuildRosterCache() -- deliberately NOT firing GUILD_ROSTER_UPDATE (no prune) here
check("ns.db.editors still literally contains the departed name (prune hasn't run)",
    ns.db.editors[1] == "Ed1")
check("But CanEditList already refuses them the instant the roster reflects their departure",
    ns.CanEditList("Ed1") == false)

--------------------------------------------------------------------------
-- Section 5: PruneDepartedRecipientEditors (via GUILD_ROSTER_UPDATE)
--------------------------------------------------------------------------
print("== PruneDepartedRecipientEditors ==")
resetState()
inGuild = true
guildRosterEntries = {
    { name = "Bavin", rankIndex = 3 }, { name = "Ed1", rankIndex = 5 }, { name = "Ed2", rankIndex = 5 },
}
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
ns.db.editors = { "Ed1", "Ed2" }

-- Ed1 leaves; fire the real event (UpdateGuildRosterCache + Prune both run).
guildRosterEntries = { { name = "Bavin", rankIndex = 3 }, { name = "Ed2", rankIndex = 5 } }
ns.frame:Fire("GUILD_ROSTER_UPDATE")
check("Departed editor (Ed1) is dropped from ns.db.editors", #ns.db.editors == 1 and ns.db.editors[1] == "Ed2")
check("Remaining editor (Ed2) is kept", ns.CanEditList("Ed2") == true)
check("Recipient (Bavin, still present) is untouched", ns.db.recipient == "Bavin")
check("A departure was logged to chat", #printLog > 0)

-- Now the recipient leaves too.
printLog = {}
guildRosterEntries = { { name = "Ed2", rankIndex = 5 } }
ns.frame:Fire("GUILD_ROSTER_UPDATE")
check("Departed recipient is cleared", ns.db.recipient == nil)

-- Safety guard: an empty roster cache must NOT be treated as "everyone
-- left" - this is the flagged risk in STATUS.md (partial-load isn't
-- covered, but a fully empty one must be safe).
resetState()
inGuild = true
guildRosterEntries = { { name = "Bavin", rankIndex = 3 }, { name = "Ed1", rankIndex = 5 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
ns.db.editors = { "Ed1" }
guildRosterEntries = {} -- simulates a transient/not-yet-loaded roster
ns.guildRoster = {} -- would happen after UpdateGuildRosterCache() rebuilds from the empty list
ns.frame:Fire("GUILD_ROSTER_UPDATE")
check("Empty-roster guard: a valid recipient survives a transient empty update",
    ns.db.recipient == "Bavin")
check("Empty-roster guard: valid editors survive too", #ns.db.editors == 1 and ns.db.editors[1] == "Ed1")

--------------------------------------------------------------------------
-- Section 6: Priority list AddItem/RemoveItem (name-keyed) + gating
--------------------------------------------------------------------------
print("== AddItem / RemoveItem (name-keyed priority list) ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "Bavin", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
currentPlayerName = "Bavin"

local testLink = "|cffffffff|Hitem:12345::::::::60:::::|h[Test Item]|h|r"
check("Authorized AddItem succeeds", ns.AddItem("Test Item", 12345, testLink) == true)
check("Entry is keyed by NAME, not itemID", ns.priorityList["Test Item"] ~= nil)
check("itemId stored as metadata", ns.priorityList["Test Item"].itemId == 12345)
check("itemLink stored for display", ns.priorityList["Test Item"].itemLink == testLink)
local itemMsgs = outboxOfType("ITEM")
check("An ITEM broadcast was sent", #itemMsgs == 1)
check("Wire format is name|itemId|itemLink", itemMsgs[1] and itemMsgs[1].text == "ITEM|Test Item|12345|" .. testLink)

check("Authorized RemoveItem succeeds", ns.RemoveItem("Test Item") == true)
check("Entry actually removed", ns.priorityList["Test Item"] == nil)
check("An ITEMGONE|name broadcast was sent", outboxOfType("ITEMGONE")[1].text == "ITEMGONE|Test Item")

currentPlayerName = "NotAnEditor"
check("Unauthorized AddItem is refused", ns.AddItem("Sneaky Item", 999, nil) == false)
check("Refused add doesn't create an entry", ns.priorityList["Sneaky Item"] == nil)

--------------------------------------------------------------------------
-- Section 7: Receive-side ITEM/ITEMGONE gating
--------------------------------------------------------------------------
print("== Receive-side ITEM/ITEMGONE verification ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "Bavin", rankIndex = 3 }, { name = "BadActor", rankIndex = 5 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"

ns.Sync_OnAddonMessage("DHBavinV4", "ITEM|Some Item|999|somelink", "GUILD", "Bavin")
check("ITEM from an authorized sender is applied", ns.priorityList["Some Item"] ~= nil)
check("addedBy reflects the verified sender", ns.priorityList["Some Item"].addedBy == "Bavin")

ns.Sync_OnAddonMessage("DHBavinV4", "ITEM|Forged Item|1|link", "GUILD", "BadActor")
check("ITEM from an unauthorized sender is ignored", ns.priorityList["Forged Item"] == nil)

ns.Sync_OnAddonMessage("DHBavinV4", "ITEMGONE|Some Item", "GUILD", "Bavin")
check("ITEMGONE from an authorized sender is applied", ns.priorityList["Some Item"] == nil)

--------------------------------------------------------------------------
-- Section 8: Multi-chunk SYNCDATA reassembly - the one sub-case flagged
-- in STATUS.md as never actually forced past a single chunk in real
-- testing. Deliberately padded (5 editors + 3 items with realistic
-- colored links) to exceed MAX_CHUNK_CHARS=200 and force a genuine
-- multi-chunk round trip, including "|" characters embedded mid-payload
-- (itemLink color codes) - the exact corruption risk the 2026-07-29
-- ChunkEncoded fix (see knowledge base) addressed.
--------------------------------------------------------------------------
print("== Multi-chunk SYNCDATA reassembly (recipient/editors/items, embedded '|') ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "Bavin", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
ns.db.editors = {
    "EditorNumberOne", "EditorNumberTwo", "EditorNumberThree", "EditorNumberFour", "EditorNumberFive",
}

local function fakeLink(id, name)
    return "|cffa335ee|Hitem:" .. id .. "::::::::60:::::|h[" .. name .. "]|h|r"
end
-- Mutate in place, don't reassign the whole table (see resetState()'s
-- 2026-08-05 comment - ns.priorityList must stay the SAME object as
-- ns.db.priorityList).
ns.priorityList["Long Priority Item Number One"] = {
    name = "Long Priority Item Number One", itemId = 10001,
    itemLink = fakeLink(10001, "Long Priority Item Number One"),
}
ns.priorityList["Long Priority Item Number Two"] = {
    name = "Long Priority Item Number Two", itemId = 10002,
    itemLink = fakeLink(10002, "Long Priority Item Number Two"),
}
ns.priorityList["Long Priority Item Number Three"] = {
    name = "Long Priority Item Number Three", itemId = 10003,
    itemLink = fakeLink(10003, "Long Priority Item Number Three"),
}
-- k-0012: these three entries were written directly (not via AddItem),
-- so nothing bumped the version stamp automatically - set it explicitly
-- to something clearly non-zero so the captured SYNCDATA payload below
-- encodes a real timestamp the post-reset receiver (which starts at 0,
-- see resetState()) will treat as newer and accept.
ns.db.priorityListUpdatedAt = 1234567890
-- k-0019: same reasoning, but for recipient/editors above (also written
-- directly, not via SetRecipient/SetEditors) - without this, the
-- captured SYNCDATA payload's recipientEditorsUpdatedAt stays at the
-- post-resetState() default of 0, and the reassembly test below (a
-- fresh resetState(), also starting at 0) would then reject it as
-- "not strictly newer" and leave recipient/editors unset.
ns.db.recipientEditorsUpdatedAt = 1234567890

ns.Sync_OnAddonMessage("DHBavinV4", "SYNCREQ", "GUILD", "Requester")
local syncData = outboxOfType("SYNCDATA")
check("SYNCREQ triggers at least one SYNCDATA reply", #syncData > 0)
check("Payload genuinely required MORE than one chunk (real stress test, not a single-message shortcut)",
    #syncData > 1)
check("SYNCDATA is WHISPERed back, not broadcast", syncData[1] and syncData[1].channel == "WHISPER")

-- Feed the captured chunks back as if from a different peer, to test
-- decode/reassembly on a clean slate - same trick DH-Quests' own harness
-- uses for its own comma-in-title stress test.
resetState()
for _, entry in ipairs(syncData) do
    ns.Sync_OnAddonMessage("DHBavinV4", entry.text, "WHISPER", "PeerB")
end

check("Recipient reassembled correctly across chunks", ns.db.recipient == "Bavin")
check("All 5 editors reassembled correctly in order",
    #ns.db.editors == 5 and ns.db.editors[1] == "EditorNumberOne" and ns.db.editors[5] == "EditorNumberFive")
check("All 3 priority items reassembled",
    ns.priorityList["Long Priority Item Number One"] ~= nil
    and ns.priorityList["Long Priority Item Number Two"] ~= nil
    and ns.priorityList["Long Priority Item Number Three"] ~= nil)
check("itemId survived reassembly", ns.priorityList["Long Priority Item Number Two"].itemId == 10002)
check("itemLink's embedded '|' color-code characters survived intact (not corrupted at a chunk boundary)",
    ns.priorityList["Long Priority Item Number Three"].itemLink == fakeLink(10003, "Long Priority Item Number Three"))
check("priorityListUpdatedAt (k-0012's field) reassembled correctly across chunks too",
    ns.db.priorityListUpdatedAt == 1234567890)
check("recipientEditorsUpdatedAt (k-0019's new field) reassembled correctly across chunks too",
    ns.db.recipientEditorsUpdatedAt == 1234567890)

--------------------------------------------------------------------------
-- Section 8b: Priority list persistence (2026-08-05)
--------------------------------------------------------------------------
-- ns.priorityList used to be PURE runtime state, rebuilt from scratch
-- every login with no SavedVariables backing at all - see Core.lua's
-- InitDB() comment. Proves the fix: ns.priorityList really is the same
-- table object as DHBavinDB.priorityList (so it's written to disk on
-- logout automatically, no addon code required), and that a full
-- SYNCDATA reply clears stale local entries first rather than merging
-- forever (matters far more now that the list persists across logins -
-- see Sync.lua's 2026-08-05 comment on that clear).
print("== Priority list persistence ==")
resetState()
check("ns.priorityList IS DHBavinDB.priorityList - not a copy (this is what makes it durable)",
    ns.priorityList == _G.DHBavinDB.priorityList)

inGuild = true
guildRosterEntries = { { name = "Bavin", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
currentPlayerName = "Bavin"
ns.AddItem("Persisted Item", 55555, "somelink")
check("AddItem's mutation is visible directly through DHBavinDB.priorityList, with zero extra code",
    _G.DHBavinDB.priorityList["Persisted Item"] ~= nil
    and _G.DHBavinDB.priorityList["Persisted Item"].itemId == 55555)

-- Simulate "logout and back in" - re-run InitDB() as PLAYER_LOGIN would,
-- exactly like a real client reloading DHBavinDB from disk and handing
-- it back to the addon on the next login. The item must still be there.
ns.InitDB()
check("The item is still present after a simulated re-login (InitDB() re-run)",
    ns.priorityList["Persisted Item"] ~= nil)
check("...and the alias still holds after re-init", ns.priorityList == _G.DHBavinDB.priorityList)

-- A stale entry that ISN'T part of an incoming full SYNCDATA snapshot
-- must be dropped, not merged forever - the new 2026-08-05 clear-first
-- behavior in Sync.lua's SYNCDATA branch.
resetState()
inGuild = true
guildRosterEntries = { { name = "Bavin", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
ns.priorityList["Stale Item From Before I Went Offline"] = { name = "Stale Item From Before I Went Offline" }
ns.db.recipient = "Bavin"
-- k-0012/k-0019: raw message now needs BOTH the recipientEditorsUpdatedAt
-- and priorityListUpdatedAt fields between editorsStr and the items list
-- - any value greater than the post-resetState() local default of 0 is
-- accepted here for either.
ns.Sync_OnAddonMessage("DHBavinV4", "SYNCDATA|1/1|Bavin||1|999|Fresh Item|1|link", "WHISPER", "PeerB")
check("The stale local-only entry is gone after a full SYNCDATA replace",
    ns.priorityList["Stale Item From Before I Went Offline"] == nil)
check("The fresh entry from the SYNCDATA payload is present",
    ns.priorityList["Fresh Item"] ~= nil)

--------------------------------------------------------------------------
-- Section 8c: Priority list SYNCDATA replacement is timestamp-gated
-- (k-0012) - this is the actual bug Loopi hit in real guild testing:
-- ANY online peer answering a login SYNCREQ - even with a stale or
-- completely empty list - unconditionally overwrote a genuinely newer
-- local list. Now only a STRICTLY newer incoming priorityListUpdatedAt
-- may replace it; anything older or equal is silently ignored (same as
-- if that peer hadn't answered at all).
--------------------------------------------------------------------------
print("== Priority list SYNCDATA timestamp gating (k-0012) ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "Bavin", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
ns.priorityList["My Current Item"] = { name = "My Current Item", itemId = 1, itemLink = "link1" }
ns.db.priorityListUpdatedAt = 100

-- recipientEditorsUpdatedAt field left at "0" (== local default after
-- resetState()) in these three - deliberately not newer, so recipient/
-- editors are untouched and these checks stay focused purely on the
-- priority-list gate.
ns.Sync_OnAddonMessage("DHBavinV4", "SYNCDATA|1/1|Bavin||0|50|Stale Peer Item|2|link2", "WHISPER", "PeerB")
check("An OLDER incoming snapshot does not touch the local list",
    ns.priorityList["My Current Item"] ~= nil and ns.priorityList["Stale Peer Item"] == nil)
check("Local priorityListUpdatedAt is unchanged after rejecting an older snapshot",
    ns.db.priorityListUpdatedAt == 100)

ns.Sync_OnAddonMessage("DHBavinV4", "SYNCDATA|1/1|Bavin||0|100|Equal Timestamp Item|3|link3", "WHISPER", "PeerB")
check("An EQUAL-timestamp incoming snapshot is also rejected (strictly newer required, not >=)",
    ns.priorityList["My Current Item"] ~= nil and ns.priorityList["Equal Timestamp Item"] == nil)

ns.Sync_OnAddonMessage("DHBavinV4", "SYNCDATA|1/1|Bavin||0|150|Fresh Peer Item|4|link4", "WHISPER", "PeerB")
check("A genuinely NEWER incoming snapshot replaces the local list",
    ns.priorityList["My Current Item"] == nil and ns.priorityList["Fresh Peer Item"] ~= nil)
check("Local priorityListUpdatedAt is updated to match the accepted snapshot",
    ns.db.priorityListUpdatedAt == 150)

-- Recipient/editors and priority list now have their OWN INDEPENDENT
-- timestamp gates (k-0012 for items, k-0019 for recipient/editors) - a
-- message can carry a genuinely newer recipientEditorsUpdatedAt while
-- its priorityListUpdatedAt is older (or vice versa), and each half is
-- judged on its own merits.
resetState()
inGuild = true
guildRosterEntries = { { name = "Bavin", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
ns.priorityList["Keep Me"] = { name = "Keep Me" }
ns.db.priorityListUpdatedAt = 999999
ns.Sync_OnAddonMessage("DHBavinV4", "SYNCDATA|1/1|SomeoneElse||1000|1|Ignored Item|9|link9", "WHISPER", "PeerB")
check("Recipient updates because THIS message's recipientEditorsUpdatedAt (1000) beats local (0)",
    ns.db.recipient == "SomeoneElse")
check("...but the local priority list itself is untouched (its own gate rejected the older items)",
    ns.priorityList["Keep Me"] ~= nil)

--------------------------------------------------------------------------
-- Section 8d: RECIPIENT/EDITORS SYNCDATA replacement is timestamp-gated
-- (k-0019) - mirrors k-0012's own gating test above, but for recipient/
-- editors: this is the actual bug Chris hit testing on an off-guild
-- character (recipient/editors got wiped locally, and a stale/empty
-- SYNCDATA reply could otherwise "restore" them or clobber a genuinely
-- newer local change with zero regard for which side was current).
--------------------------------------------------------------------------
print("== RECIPIENT/EDITORS SYNCDATA timestamp gating (k-0019) ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "Bavin", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
ns.db.editors = { "OriginalEditor" }
ns.db.recipientEditorsUpdatedAt = 100

ns.Sync_OnAddonMessage("DHBavinV4", "SYNCDATA|1/1|StalePeerRecipient|StalePeerEditor|50|0|", "WHISPER", "PeerB")
check("An OLDER incoming recipient/editors snapshot does not touch local state",
    ns.db.recipient == "Bavin" and #ns.db.editors == 1 and ns.db.editors[1] == "OriginalEditor")
check("Local recipientEditorsUpdatedAt is unchanged after rejecting an older snapshot",
    ns.db.recipientEditorsUpdatedAt == 100)

ns.Sync_OnAddonMessage("DHBavinV4", "SYNCDATA|1/1|EqualPeerRecipient|EqualPeerEditor|100|0|", "WHISPER", "PeerB")
check("An EQUAL-timestamp incoming snapshot is also rejected (strictly newer required, not >=)",
    ns.db.recipient == "Bavin")

ns.Sync_OnAddonMessage("DHBavinV4", "SYNCDATA|1/1|FreshPeerRecipient|FreshPeerEditor1,FreshPeerEditor2|150|0|", "WHISPER", "PeerB")
check("A genuinely NEWER incoming snapshot replaces local recipient/editors",
    ns.db.recipient == "FreshPeerRecipient" and #ns.db.editors == 2 and ns.db.editors[2] == "FreshPeerEditor2")
check("Local recipientEditorsUpdatedAt is updated to match the accepted snapshot",
    ns.db.recipientEditorsUpdatedAt == 150)

--------------------------------------------------------------------------
-- Section 9: Bavin Points overrides - SetItemPoints/PTSSET/last-writer-
-- wins/revert-to-baseline/PTSSYNCREQ delta-only catch-up
--------------------------------------------------------------------------
print("== Bavin Points overrides (PTSSET / PTSSYNCREQ / last-writer-wins) ==")
resetState()
inGuild = true
-- Two distinct authorized identities are needed here: the local player
-- (who sets the initial override) and a DIFFERENT remote sender for the
-- "incoming" messages below - using the same name for both would trip
-- Sync.lua's own echo-suppression ("ignore our own echo") and silently
-- no-op every incoming message, which would look identical to a
-- last-writer-wins rejection. Both must be authorized (CanEditList).
guildRosterEntries = { { name = "Bavin", rankIndex = 3 }, { name = "OtherEditor", rankIndex = 5 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
ns.db.editors = { "OtherEditor" }
currentPlayerName = "Bavin"
ns.ITEM_POINTS["Test Baseline Item"] = { points = 5, itemId = 777 } -- synthetic, isolated from real data

check("SetItemPoints succeeds when authorized", ns.SetItemPoints("Test Baseline Item", 50, 777) == true)
local info = ns.GetItemPoints("Test Baseline Item")
check("Live override takes priority over baseline", info and info.points == 50 and info.isOverride == true)
check("A PTSSET broadcast was sent", #outboxOfType("PTSSET") == 1)

-- Last-writer-wins: an incoming PTSSET with an OLDER editedAt must be ignored.
local currentVersion = ns.GetItemPointsVersion()
ns.Sync_OnAddonMessage("DHBavinV4", "PTSSET|Test Baseline Item|1|777|" .. (currentVersion - 100) .. "|", "GUILD", "OtherEditor")
check("An older incoming edit is ignored (last-writer-wins)",
    ns.GetItemPoints("Test Baseline Item").points == 50)

wallClock = wallClock + 10
ns.Sync_OnAddonMessage("DHBavinV4", "PTSSET|Test Baseline Item|75|777|" .. wallClock .. "|", "GUILD", "OtherEditor")
check("A genuinely newer incoming edit is applied",
    ns.GetItemPoints("Test Baseline Item").points == 75)

wallClock = wallClock + 10 -- must strictly advance, or last-writer-wins rejects the revert as not-newer
check("RevertItemPoints falls back to the shipped baseline", ns.RevertItemPoints("Test Baseline Item") == true)
check("Baseline value (5) shows again after revert",
    ns.GetItemPoints("Test Baseline Item").points == 5 and ns.GetItemPoints("Test Baseline Item").isOverride == false)

-- PTSSYNCREQ/PTSSYNCDATA: only entries newer than the requester's
-- version should come back, never the whole table.
ns.db.itemPointsOverrides = {}
ns.ApplyItemPointsLocal("Old Edit Item", 10, 1, 1000)
ns.ApplyItemPointsLocal("New Edit Item", 20, 2, 2000)
outboxLog = {}
ns.Sync_OnAddonMessage("DHBavinV4", "PTSSYNCREQ|1500", "GUILD", "Requester")
local ptsData = outboxOfType("PTSSYNCDATA")
check("PTSSYNCREQ triggers a PTSSYNCDATA reply", #ptsData > 0)

ns.db.itemPointsOverrides = {}
for _, entry in ipairs(ptsData) do
    ns.Sync_OnAddonMessage("DHBavinV4", entry.text, "WHISPER", "PeerC")
end
check("Only the entry newer than the requested version (2000 > 1500) came through",
    ns.db.itemPointsOverrides["New Edit Item"] ~= nil and ns.db.itemPointsOverrides["Old Edit Item"] == nil)

--------------------------------------------------------------------------
-- Section 10: editable tooltip wording (`detail`) - 2026-08-06
--------------------------------------------------------------------------
-- The wording is the ONLY field on this wire that can legitimately
-- contain "|" or ";", and the stock spreadsheet phrasing
-- ("<name>: <points> pts to Bavin; <source>") contains a semicolon in
-- nearly every entry - which is precisely the delimiter PTSSYNCDATA uses
-- to separate whole entries. Unescaped, one such string would shatter a
-- sync payload into bogus extra entries, so these checks push the nastiest
-- realistic strings through the full encode/decode round trip rather than
-- just asserting the field is stored.
print("== Tooltip wording (detail) round-trip + delimiter escaping ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "Bavin", rankIndex = 3 }, { name = "OtherEditor", rankIndex = 5 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
ns.db.editors = { "OtherEditor" }
currentPlayerName = "Bavin"

ns.ITEM_POINTS["Detail Test Item"] = { points = 5, itemId = 888, detail = "Detail Test Item: 5 pts to Bavin; (est. AH value)" }

check("Baseline detail is returned when there's no override",
    ns.GetItemPoints("Detail Test Item").detail == "Detail Test Item: 5 pts to Bavin; (est. AH value)")

check("SetItemPoints accepts a detail string",
    ns.SetItemPoints("Detail Test Item", 12, 888, "Reworded; still has a semicolon") == true)
check("An override's own detail is returned in preference to the baseline's",
    ns.GetItemPoints("Detail Test Item").detail == "Reworded; still has a semicolon")

-- An override with NO wording of its own must NOT inherit the baseline's,
-- whose embedded point number would now be wrong (see Core.lua's
-- GetItemPoints comment).
wallClock = wallClock + 10
check("SetItemPoints with no detail clears it", ns.SetItemPoints("Detail Test Item", 30, 888, "") == true)
check("An override without its own wording does not fall back to the baseline's",
    ns.GetItemPoints("Detail Test Item").detail == nil)

-- Full delta round trip through PTSSYNCREQ/PTSSYNCDATA with both
-- delimiters AND a literal backslash present in the wording.
local nastyDetail = "Pipe | semi ; backslash \\ and \\p \\s literals"
ns.db.itemPointsOverrides = {}
ns.ApplyItemPointsLocal("Nasty Detail Item", 42, 123, 5000, nastyDetail)
ns.ApplyItemPointsLocal("Second Item", 7, 124, 5001, "Second Item: 7 pts to Bavin; vendor trash")
outboxLog = {}
ns.Sync_OnAddonMessage("DHBavinV4", "PTSSYNCREQ|0", "GUILD", "Requester")
local nastyData = outboxOfType("PTSSYNCDATA")
check("PTSSYNCREQ replied with wording-bearing entries", #nastyData > 0)

ns.db.itemPointsOverrides = {}
for _, entry in ipairs(nastyData) do
    ns.Sync_OnAddonMessage("DHBavinV4", entry.text, "WHISPER", "PeerD")
end
check("Both entries survived a payload whose wording contains the entry delimiter",
    ns.db.itemPointsOverrides["Nasty Detail Item"] ~= nil and ns.db.itemPointsOverrides["Second Item"] ~= nil)
check("Wording with pipes, semicolons and backslashes round-trips byte-for-byte",
    ns.db.itemPointsOverrides["Nasty Detail Item"].detail == nastyDetail)
check("A semicolon in one entry's wording did not leak into the next entry",
    ns.db.itemPointsOverrides["Second Item"].detail == "Second Item: 7 pts to Bavin; vendor trash")
check("Points and itemId are unharmed alongside an escaped wording field",
    ns.db.itemPointsOverrides["Nasty Detail Item"].points == 42
    and ns.db.itemPointsOverrides["Nasty Detail Item"].itemId == 123)

-- Single-message (PTSSET) path, same hostile string.
resetState()
inGuild = true
guildRosterEntries = { { name = "Bavin", rankIndex = 3 }, { name = "OtherEditor", rankIndex = 5 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
ns.db.editors = { "OtherEditor" }
currentPlayerName = "Bavin"
ns.SetItemPoints("Wire Test Item", 9, 55, nastyDetail)
local ptsSet = outboxOfType("PTSSET")
check("A PTSSET carrying wording was broadcast", #ptsSet == 1)
ns.db.itemPointsOverrides = {}
ns.Sync_OnAddonMessage("DHBavinV4", ptsSet[1].text, "GUILD", "OtherEditor")
check("PTSSET wording survives the round trip intact",
    ns.db.itemPointsOverrides["Wire Test Item"]
    and ns.db.itemPointsOverrides["Wire Test Item"].detail == nastyDetail)

--------------------------------------------------------------------------
-- Credits (CM1/CM2, Identity model v2, 2026-09-25) - new coverage,
-- flagged as a gap in claude\DH-Bavin\STATUS.md ("harness currently has
-- no Credits/CreditsSeed/CreditsConfig coverage"). CreditsConfig.lua
-- itself stays excluded (UI-template heavy, same exclusion category as
-- everything else in the header comment) - this covers the pure-logic
-- layer underneath it: permission gates, tier-cap arithmetic, seed
-- import, and the Link/Unlink/Review Queue mechanics.
--------------------------------------------------------------------------
print("== Credits: tier-cap arithmetic ==")
resetState()
do
    local tier, prestige, points = ns.Credits_TierStateForLifetime(0)
    check("0 lifetime points is Neutral, prestige 0, 0 points", tier == "Neutral" and prestige == 0 and points == 0)
end
do
    local tier, _, points = ns.Credits_TierStateForLifetime(2999)
    check("Just under Neutral's cap stays Neutral", tier == "Neutral" and points == 2999)
end
do
    local tier, _, points = ns.Credits_TierStateForLifetime(3000)
    check("Exactly at Neutral's cap rolls into Friendly at 0", tier == "Friendly" and points == 0)
end
do
    local tier, prestige, points = ns.Credits_TierStateForLifetime(3000 + 6000 + 12000 + 21000)
    check("Sum of Neutral..Revered caps lands exactly on Exalted at 0",
        tier == "Exalted" and prestige == 0 and points == 0)
end
do
    local exaltedStart = 3000 + 6000 + 12000 + 21000
    local tier, prestige, points = ns.Credits_TierStateForLifetime(exaltedStart + 50000)
    check("One full Exalted lap (50000) bumps prestige to 1, resets points to 0",
        tier == "Exalted" and prestige == 1 and points == 0)
end
do
    local exaltedStart = 3000 + 6000 + 12000 + 21000
    local tier, prestige, points = ns.Credits_TierStateForLifetime(exaltedStart + 50000 * 3 + 12345)
    check("Exalted keeps looping uncapped - prestige 3, remainder as points",
        tier == "Exalted" and prestige == 3 and points == 12345)
end
do
    local tier, _, points = ns.Credits_TierStateForLifetime(-500)
    check("Negative input clamps to 0, not an error", tier == "Neutral" and points == 0)
end

--------------------------------------------------------------------------
print("== Credits: permission gates ==")
-- 2026-09-28 (Chris, item 5): Credits no longer keeps its own officer
-- list/gate - ns.CanManageCreditsConfigLocal() now just checks
-- membership in DH-Bavin's shared officer list (ns.db.editors, via
-- ns.IsOfficerName). ns.CanManageCreditsOfficers/SetCreditsOfficers are
-- gone; managing WHO is on that list is Core.lua's
-- ns.CanSetEditorsName/ns.SetEditors, already covered above.
resetState()
check("Refused when not in the guild at all", ns.CanManageCreditsConfigLocal() == false)

inGuild = true
guildRosterEntries = {
    { name = "GLeader", rankIndex = 0 },
    { name = "PlainMember", rankIndex = 5 },
}
ns.UpdateGuildRosterCache()
currentPlayerName = "PlainMember"
check("In guild but neither a shared-list officer nor author is still refused",
    ns.CanManageCreditsConfigLocal() == false)

currentPlayerName = "GLeader"
check("Being guild leader alone does not grant config access (not on the shared officer list)",
    ns.CanManageCreditsConfigLocal() == false)

ns.db.editors = { "PlainMember" }
currentPlayerName = "PlainMember"
check("A name on the shared officer list can manage local Credits config",
    ns.CanManageCreditsConfigLocal() == true)

ns.db.editors = {}
authorAccountFlag = true
check("Author-account override grants config access even with an empty shared officer list",
    ns.CanManageCreditsConfigLocal() == true)

inGuild = false
check("Author override does not bypass the guild-membership gate", ns.CanManageCreditsConfigLocal() == false)

--------------------------------------------------------------------------
print("== Credits: CreditsSeed_Import ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "Officer1", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
currentPlayerName = "Officer1"
ns.db.editors = { "Officer1" }

check("Import refuses with no SeedData.lua loaded", ns.CreditsSeed_Import() == false)

ns.CreditsSeedData = {
    MainOne = { lifetimePoints = 1500, latestDonation = "2026-09-01" },
    MainTwo = { lifetimePoints = 3200, latestDonation = "2026-08-15" },
}
ns.CreditsAltRoster = { MainOne = { "AltOne", "AltTwo" } }

local ok, count = ns.CreditsSeed_Import()
check("Import succeeds and reports 2 seeded mains", ok == true and count == 2)
local seedRec = ns.creditsDb.ledger["MainOne"]
check("Seeded row is keyed by discordName == mainToon at seed time",
    seedRec and seedRec.discordName == "MainOne" and seedRec.mainToon == "MainOne")
check("Seeded row copies AltRoster's alt list",
    seedRec and #seedRec.alts == 2 and seedRec.alts[1] == "AltOne" and seedRec.alts[2] == "AltTwo")
check("Credits always seed at 0 regardless of lifetime points (go-live rule)", seedRec and seedRec.credits == 0)
check("lifetimeCredits seeds at 0 too (nothing earned yet at go-live)", seedRec and seedRec.lifetimeCredits == 0)
local expTier, expPrestige, expPoints = ns.Credits_TierStateForLifetime(1500)
check("Seeded tier/prestige/points match Credits_TierStateForLifetime exactly",
    seedRec.tier == expTier and seedRec.prestige == expPrestige and seedRec.points == expPoints)
check("A main with no AltRoster entry seeds an empty (not nil) alts list",
    ns.creditsDb.ledger["MainTwo"] and type(ns.creditsDb.ledger["MainTwo"].alts) == "table"
    and #ns.creditsDb.ledger["MainTwo"].alts == 0)
check("toonIndex is rebuilt so both a main and its alt resolve",
    ns.creditsDb.toonIndex["mainone"] == "MainOne" and ns.creditsDb.toonIndex["altone"] == "MainOne")

--------------------------------------------------------------------------
print("== Credits: Link/Unlink alt resolution and Review Queue ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "Officer1", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
currentPlayerName = "Officer1"
ns.db.editors = { "Officer1" }
ns.CreditsSeedData = { MainA = { lifetimePoints = 100 }, MainB = { lifetimePoints = 200 } }
ns.CreditsSeed_Import()

check("A name with no account resolves to itself (self-fallback)",
    ns.Credits_ResolveMain("NobodyKnown") == "NobodyKnown")
check("A seeded main resolves to itself", ns.Credits_ResolveMain("MainA") == "MainA")

check("Linking without permission is refused", (function()
    local prior = ns.db.editors
    ns.db.editors = {}
    local result = ns.Credits_LinkAlt("SomeAlt", "MainA")
    ns.db.editors = prior
    return result
end)() == false)

check("Cannot link an alt to an unknown main toon name", ns.Credits_LinkAlt("SomeAlt", "NoSuchMain") == false)
check("Cannot link a name to itself", ns.Credits_LinkAlt("MainA", "MainA") == false)

check("Linking a fresh alt to MainA succeeds", ns.Credits_LinkAlt("SideKick", "MainA") == true)
check("The linked alt now resolves to MainA's current mainToon", ns.Credits_ResolveMain("SideKick") == "MainA")
check("Credits_GetAltMain reports the owning main for a linked alt", ns.Credits_GetAltMain("SideKick") == "MainA")
check("Credits_GetAltMain returns nil for an account's own main toon (not \"linked to itself\")",
    ns.Credits_GetAltMain("MainA") == nil)

check("Re-linking the same alt to MainB moves it (no duplicate ownership)",
    ns.Credits_LinkAlt("SideKick", "MainB") == true)
check("SideKick now resolves to MainB, not MainA", ns.Credits_ResolveMain("SideKick") == "MainB")
check("MainA's alts array no longer contains SideKick", (function()
    for _, a in ipairs(ns.creditsDb.ledger["MainA"].alts) do
        if a == "SideKick" then return false end
    end
    return true
end)())

check("Unlinking SideKick releases it from MainB", ns.Credits_UnlinkAlt("SideKick") == true)
check("After unlink, SideKick resolves back to itself", ns.Credits_ResolveMain("SideKick") == "SideKick")
check("Unlinking a name that belongs to no account is refused (nothing to remove)",
    ns.Credits_UnlinkAlt("SideKick") == false)

local rq = ns.Credits_ReviewQueueRows()
local reopened = false
for _, r in ipairs(rq) do
    if r.name == "SideKick" and r.issue == "removed_alt" then reopened = true end
end
check("Unlinking reopens the name in the (dynamic) Review Queue as removed_alt", reopened)

check("Re-linking a reopened name clears it back out of the Review Queue",
    ns.Credits_LinkAlt("SideKick", "MainA") == true)
rq = ns.Credits_ReviewQueueRows()
local stillQueued = false
for _, r in ipairs(rq) do
    if r.name == "SideKick" then stillQueued = true end
end
check("SideKick no longer appears in the Review Queue once re-linked", not stillQueued)

--------------------------------------------------------------------------
print("== Credits: Review Queue static+dynamic merge ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "Officer1", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
currentPlayerName = "Officer1"
ns.db.editors = { "Officer1" }

ns.CreditsReviewQueue = {
    { name = "StaticOnly", issue = "no_identity_mapping", latestDonation = "2026-07-01", rawGoldAmount = 40 },
    { name = "Overlap", issue = "identity_conflict", latestDonation = "2026-07-15", rawGoldAmount = 10 },
}
ns.Credits_AddToReviewQueue("DynamicOnly")
ns.Credits_AddToReviewQueue("Overlap") -- same name as a static row

local rows = ns.Credits_ReviewQueueRows()
local byName = {}
for _, r in ipairs(rows) do byName[r.name] = r end

check("Static-only row is present", byName["StaticOnly"] ~= nil)
check("Dynamic-only row is present", byName["DynamicOnly"] ~= nil)
check("A name in both lists appears exactly once", #rows == 3)
check("On overlap, the dynamic (runtime) row wins over the static one", byName["Overlap"].issue == "removed_alt")

ns.Credits_RemoveFromReviewQueue("DynamicOnly")
rows = ns.Credits_ReviewQueueRows()
byName = {}
for _, r in ipairs(rows) do byName[r.name] = r end
check("Removing a dynamic row drops it from the merged view", byName["DynamicOnly"] == nil)
check("Removing one dynamic row leaves the others untouched", #rows == 2)

--------------------------------------------------------------------------
print("== Credits: Credits_SetAsNewMain ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "Officer1", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
currentPlayerName = "Officer1"
ns.db.editors = { "Officer1" }
ns.CreditsSeedData = { ExistingMain = { lifetimePoints = 500 } }
ns.CreditsSeed_Import()
ns.Credits_AddToReviewQueue("NewGuy")

check("Cannot promote a name that already resolves to an existing account",
    ns.Credits_SetAsNewMain("ExistingMain", 100, "2026-09-20") == false)

check("Promoting a fresh Review Queue name to its own account succeeds",
    ns.Credits_SetAsNewMain("NewGuy", 250, "2026-09-20") == true)
local newRec = ns.creditsDb.ledger["NewGuy"]
check("New account is its own discordName/mainToon with no alts",
    newRec and newRec.discordName == "NewGuy" and newRec.mainToon == "NewGuy" and #newRec.alts == 0)
check("Lifetime total is rawGoldAmount * 10, the same convention as seed-dataset.csv",
    newRec and newRec.lifetimePoints == 2500)
check("Credits seed at 0 here too, same go-live rule as CreditsSeed_Import", newRec and newRec.credits == 0)
check("The new account resolves via Credits_ResolveMain", ns.Credits_ResolveMain("NewGuy") == "NewGuy")

rows = ns.Credits_ReviewQueueRows()
local stillThere = false
for _, r in ipairs(rows) do
    if r.name == "NewGuy" then stillThere = true end
end
check("Promoting a name removes it from the Review Queue", not stillThere)

check("Cannot promote the same name twice now that it resolves to its own account",
    ns.Credits_SetAsNewMain("NewGuy", 999, "2026-09-21") == false)

check("Promotion without permission is refused", (function()
    local prior = ns.db.editors
    ns.db.editors = {}
    local result = ns.Credits_SetAsNewMain("AnotherGuy", 50, "")
    ns.db.editors = prior
    return result
end)() == false)

--------------------------------------------------------------------------
print("== Credits: lifetimeCredits ==")
check("Set-as-New-Main rows carry lifetimeCredits = 0 too",
    ns.creditsDb.ledger["NewGuy"] and ns.creditsDb.ledger["NewGuy"].lifetimeCredits == 0)
do
    local rec = { credits = 0, lifetimeCredits = 0 }
    ns.Credits_AdjustCredits(rec, 100)
    check("An earn raises balance and lifetimeCredits together", rec.credits == 100 and rec.lifetimeCredits == 100)
    ns.Credits_AdjustCredits(rec, -40)
    check("A charge lowers the balance but never lifetimeCredits", rec.credits == 60 and rec.lifetimeCredits == 100)
    ns.Credits_AdjustCredits(rec, 25)
    check("A later earn adds to both again", rec.credits == 85 and rec.lifetimeCredits == 125)
    ns.Credits_AdjustCredits(rec, -1000)
    check("An over-charge floors the balance at 0 and leaves lifetimeCredits alone",
        rec.credits == 0 and rec.lifetimeCredits == 125)
    local legacy = { credits = 30 } -- record saved before the field existed
    ns.Credits_AdjustCredits(legacy, -10)
    check("A legacy record (no lifetimeCredits) never ends up with lifetime < balance",
        legacy.credits == 20 and legacy.lifetimeCredits >= legacy.credits)
    check("A non-table record is refused", ns.Credits_AdjustCredits(nil, 5) == nil)
end
do
    -- InitCreditsDB migration: old record gets lifetimeCredits from its balance;
    -- a record violating lifetime >= balance is repaired; a good one is untouched.
    DHBavinCreditsDB = ns.creditsDb
    ns.creditsDb.ledger["LegacyAcct"] = { discordName = "LegacyAcct", mainToon = "LegacyAcct", alts = {}, credits = 50 }
    ns.creditsDb.ledger["BadAcct"] = { discordName = "BadAcct", mainToon = "BadAcct", alts = {}, credits = 80, lifetimeCredits = 10 }
    ns.creditsDb.ledger["GoodAcct"] = { discordName = "GoodAcct", mainToon = "GoodAcct", alts = {}, credits = 20, lifetimeCredits = 500 }
    ns.InitCreditsDB()
    check("Migration: legacy record gets lifetimeCredits = its balance", ns.creditsDb.ledger["LegacyAcct"].lifetimeCredits == 50)
    check("Migration: lifetimeCredits below balance is repaired up to the balance", ns.creditsDb.ledger["BadAcct"].lifetimeCredits == 80)
    check("Migration: a valid lifetimeCredits is left alone", ns.creditsDb.ledger["GoodAcct"].lifetimeCredits == 500)
    ns.creditsDb.ledger["LegacyAcct"], ns.creditsDb.ledger["BadAcct"], ns.creditsDb.ledger["GoodAcct"] = nil, nil, nil
end

--------------------------------------------------------------------------
print("== Credits: Credits_ResetTestData ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "Officer1", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
currentPlayerName = "Officer1"
ns.db.editors = { "Officer1" }
ns.CreditsSeedData = { MainA = { lifetimePoints = 100 } }
ns.CreditsSeed_Import()
ns.Credits_AddToReviewQueue("Whoever")

check("Reset without permission is refused and leaves data intact", (function()
    local prior = ns.db.editors
    ns.db.editors = {}
    local result = ns.Credits_ResetTestData()
    ns.db.editors = prior
    return result == false and ns.creditsDb.ledger["MainA"] ~= nil
end)())

check("Reset with permission wipes ledger, toonIndex, dynamic Review Queue, transaction log",
    ns.Credits_ResetTestData() == true
    and next(ns.creditsDb.ledger) == nil
    and next(ns.creditsDb.toonIndex) == nil
    and next(ns.creditsDb.dynamicReviewQueue) == nil
    and next(ns.creditsDb.transactionLog) == nil)
check("A name resolves back to self-fallback after reset", ns.Credits_ResolveMain("MainA") == "MainA")

--------------------------------------------------------------------------
-- Credits: unlinked alt keeps its known donation info in the Review Queue
--------------------------------------------------------------------------
print("== Credits: Unlink keeps donation date ==")
do
    resetState()
    inGuild = true
    guildRosterEntries = { { name = "Officer1", rankIndex = 3 } }
    ns.UpdateGuildRosterCache()
    currentPlayerName = "Officer1"
    ns.db.editors = { "Officer1" }
    ns.CreditsSeedData = { MainA = { lifetimePoints = 100 } }
    ns.CreditsAltRoster = { MainA = { "StaticAlt", "PlainAlt" } }
    ns.CreditsReviewQueue = {
        { name = "StaticAlt", issue = "no_identity_mapping", latestDonation = "2026-09-19", rawGoldAmount = 380.18 },
    }
    ns.CreditsSeed_Import()

    local function dynamicRow(name)
        for _, r in ipairs(ns.creditsDb.dynamicReviewQueue) do
            if r.name == name then return r end
        end
    end

    ns.Credits_UnlinkAlt("StaticAlt")
    local row = dynamicRow("StaticAlt")
    check("Unlinking a name Step 0 knew keeps its last donation date", row and row.latestDonation == "2026-09-19")
    check("...and its raw gold figure", row and row.rawGoldAmount == 380.18)
    check("...and is tagged removed_alt", row and row.issue == "removed_alt")

    ns.Credits_UnlinkAlt("PlainAlt")
    row = dynamicRow("PlainAlt")
    check("A name with no shipped data still unlinks with an empty date", row and row.latestDonation == "" and row.rawGoldAmount == 0)

    ns.Credits_LinkAlt("StaticAlt", "MainA")
    ns.Credits_UnlinkAlt("StaticAlt")
    row = dynamicRow("StaticAlt")
    check("Link then Unlink again still shows the date", row and row.latestDonation == "2026-09-19")

    -- ToonDonations.lua fallback: a resolved alt with no Review Queue row.
    ns.CreditsToonDonations = { toonalt = { "2026-05-05", 42.5 } }
    ns.Credits_LinkAlt("ToonAlt", "MainA")
    ns.Credits_UnlinkAlt("ToonAlt")
    row = dynamicRow("ToonAlt")
    check("Unlinking a resolved alt takes its date from ToonDonations", row and row.latestDonation == "2026-05-05")
    check("...and its raw gold from ToonDonations", row and row.rawGoldAmount == 42.5)
    ns.CreditsToonDonations = nil
    loadfile(ADDON_ROOT .. "ToonDonations.lua")() -- reload the real shipped table
    check("The shipped ToonDonations table loads (real data present)", (function()
        local n = 0
        for _ in pairs(ns.CreditsToonDonations or {}) do n = n + 1 end
        return n > 500
    end)())
    ns.CreditsToonDonations = nil
    ns.CreditsReviewQueue = nil
end

--------------------------------------------------------------------------
-- Credits: Credits_PromoteToMain (Roster right-click menu)
--------------------------------------------------------------------------
print("== Credits: Credits_PromoteToMain ==")
do
    resetState()
    inGuild = true
    guildRosterEntries = {
        { name = "Officer1", rankIndex = 3 },
        { name = "Officer2", rankIndex = 3 },
        { name = "Member1", rankIndex = 5 },
    }
    ns.UpdateGuildRosterCache()
    currentPlayerName = "Officer1"
    ns.db.editors = { "Officer1", "Officer2" }
    ns.CreditsSeedData = { MainA = { lifetimePoints = 4321 } }
    ns.CreditsAltRoster = { MainA = { "AltA1", "AltA2" } }
    ns.CreditsSeed_Import()
    local rec = ns.creditsDb.ledger["MainA"]
    rec.credits, rec.lifetimeCredits = 40, 90
    outboxLog = {}

    local ok, newMain = ns.Credits_PromoteToMain("AltA1")
    check("Promoting an alt succeeds and reports the new main", ok == true and newMain == "AltA1")
    check("The alt is now the account's main toon", rec.mainToon == "AltA1")
    local hasOld, hasNew = false, false
    for _, a in ipairs(rec.alts) do
        if a == "MainA" then hasOld = true end
        if a == "AltA1" then hasNew = true end
    end
    check("The old main became an alt of the same account", hasOld)
    check("The promoted toon is no longer listed as an alt", not hasNew)
    check("The account keeps the same number of alts", #rec.alts == 2)
    check("The ledger key (discordName) is unchanged", ns.creditsDb.ledger["MainA"] == rec and ns.creditsDb.ledger["AltA1"] == nil)
    check("Points and credit history are untouched",
        rec.lifetimePoints == 4321 and rec.credits == 40 and rec.lifetimeCredits == 90)
    check("Every toon still resolves to the same account",
        ns.creditsDb.toonIndex["maina"] == "MainA" and ns.creditsDb.toonIndex["alta1"] == "MainA"
        and ns.creditsDb.toonIndex["alta2"] == "MainA")
    check("Promote is announced to online officers as a record change",
        (function()
            local sent = ""
            for _, e in ipairs(outboxLog) do
                if e.target == "Officer2" then sent = sent .. e.text end
            end
            return sent:find("R:MainA|AltA1|", 1, true) ~= nil
        end)())

    check("Promoting the current main is refused", ns.Credits_PromoteToMain("AltA1") == false)
    check("Promoting an unknown name is refused", ns.Credits_PromoteToMain("Nobody") == false)
    check("Promoting the previous main back works and restores it",
        ns.Credits_PromoteToMain("MainA") == true and rec.mainToon == "MainA")

    currentPlayerName = "Member1"
    check("A non-officer cannot promote", ns.Credits_PromoteToMain("AltA2") == false and rec.mainToon == "MainA")
end

--------------------------------------------------------------------------
-- Credits: CM3 officer ledger sync (CreditsSync.lua)
--------------------------------------------------------------------------
print("== Credits: CM3 ledger sync ==")
do
    local PFX = "DHBavinCreditsV2"
    local function deliver(from, text)
        ns.Credits_OnAddonMessage(PFX, text, "WHISPER", from)
    end
    -- All LSYNCDATA messages sent to `target`, as { id, i, n, chunk } in send order.
    local function dataTo(target)
        local out = {}
        for _, e in ipairs(outboxLog) do
            if e.target == target and e.channel == "WHISPER" then
                local id, i, n, chunk = e.text:match("^LSYNCDATA|(%x+)|(%d+)/(%d+)|(.*)$")
                if id then out[#out + 1] = { id = id, i = tonumber(i), n = tonumber(n), chunk = chunk, text = e.text } end
            end
        end
        return out
    end
    local function payloadOf(msgs)
        local parts = {}
        for _, m in ipairs(msgs) do parts[m.i] = m.chunk end
        return table.concat(parts)
    end
    local function reqsTo(target)
        local out = {}
        for _, e in ipairs(outboxLog) do
            if e.target == target and e.text:match("^LSYNCREQ|") then out[#out + 1] = e end
        end
        return out
    end
    local function setup()
        resetState()
        inGuild = true
        guildRosterEntries = {
            { name = "GLeader", rankIndex = 0 },
            { name = "Officer1", rankIndex = 3 },
            { name = "Officer2", rankIndex = 3 },
            { name = "Member1", rankIndex = 5 },
        }
        ns.UpdateGuildRosterCache()
        currentPlayerName = "Officer1"
        ns.db.editors = { "Officer1", "Officer2" }
        ns.CreditsSeedData = { MainA = { lifetimePoints = 100 }, MainB = { lifetimePoints = 200 } }
        ns.CreditsAltRoster = { MainA = { "AltA1" } }
        ns.CreditsSeed_Import()
        outboxLog, printLog = {}, {}
    end

    -- ---- record codec ----------------------------------------------------
    local nasty = {
        discordName = "We|ird;Na,me%~", mainToon = "Ma;in", alts = { "A,lt", "B|lt", "C%lt" },
        points = 10, credits = 5, tier = "Friendly", prestige = 0, lifetimePoints = 3010,
        lastDonationDate = "2026-09-20", lastUpdated = 123, syncedAt = 456, lifetimeCredits = 9,
    }
    local enc = ns.CreditsSync_EncodeRecord(nasty)
    check("Encoded record contains no raw ';' (item delimiter)", not enc:find(";", 1, true))
    local _, pipes = enc:gsub("|", "")
    check("Encoded record has exactly 12 field separators despite hostile characters", pipes == 12)
    local dec = ns.CreditsSync_DecodeRecord(enc)
    check("Record round-trips discordName/mainToon", dec and dec.discordName == nasty.discordName and dec.mainToon == nasty.mainToon)
    check("Record round-trips alts with delimiters in the names",
        dec and #dec.alts == 3 and dec.alts[1] == "A,lt" and dec.alts[2] == "B|lt" and dec.alts[3] == "C%lt")
    check("Record round-trips numbers incl. lifetimeCredits and syncedAt",
        dec and dec.points == 10 and dec.credits == 5 and dec.lifetimePoints == 3010
        and dec.lifetimeCredits == 9 and dec.syncedAt == 456 and dec.lastUpdated == 123)

    check("Decode rejects an unknown tier", ns.CreditsSync_DecodeRecord(enc:gsub("Friendly", "Godlike")) == nil)
    check("Decode rejects too few fields", ns.CreditsSync_DecodeRecord("a|b|c") == nil)
    check("Decode rejects a negative balance", ns.CreditsSync_DecodeRecord((enc:gsub("|5|Friendly", "|-5|Friendly"))) == nil)
    local legacy = enc:gsub("|9|d[^|]*$", "")   -- neither lifetimeCredits nor the Discord field
    local legacyDec = ns.CreditsSync_DecodeRecord(legacy)
    check("A record without the trailing lifetimeCredits decodes with lifetimeCredits = credits",
        legacyDec and legacyDec.lifetimeCredits == 5)

    -- ---- fingerprint ---------------------------------------------------
    setup()
    local fp1 = ns.CreditsSync_Fingerprint()
    check("Fingerprint is an 8-hex string", fp1:match("^%x%x%x%x%x%x%x%x$") ~= nil)
    check("Fingerprint is stable across calls", ns.CreditsSync_Fingerprint() == fp1)
    ns.CreditsSeedData = { MainA = { lifetimePoints = 100 }, MainB = { lifetimePoints = 201 } }
    check("Fingerprint changes when the seed data changes", ns.CreditsSync_Fingerprint() ~= fp1)
    ns.CreditsSeedData = { MainA = { lifetimePoints = 100 }, MainB = { lifetimePoints = 200 } }
    check("Fingerprint returns when the seed data is restored", ns.CreditsSync_Fingerprint() == fp1)
    ns.CreditsAltRoster = { MainA = { "AltA1", "AltA2" } }
    check("Fingerprint changes when the alt roster changes", ns.CreditsSync_Fingerprint() ~= fp1)

    -- ---- outbound: a local change is whispered to online officers only --
    setup()
    check("Seed records carry no syncedAt (seed is never replicated)", ns.creditsDb.ledger["MainA"].syncedAt == nil)
    check("LinkAlt succeeds", ns.Credits_LinkAlt("NewAlt", "MainA") == true)
    local toOfficer2 = dataTo("Officer2")
    check("Change was whispered to the online officer", #toOfficer2 >= 1)
    check("Nothing sent to a non-officer member", #dataTo("Member1") == 0)
    check("The online guild leader (an authorized sender) is also a peer", #dataTo("GLeader") >= 1)
    local anyGuild = false
    for _, e in ipairs(outboxLog) do if e.channel == "GUILD" then anyGuild = true end end
    check("Ledger sync never uses the GUILD channel", not anyGuild)
    local payload = payloadOf(toOfficer2)
    check("Payload leads with the seed fingerprint", payload:match("^F:" .. ns.CreditsSync_Fingerprint() .. ";") ~= nil)
    check("Payload carries the changed record", payload:find("R:MainA|", 1, true) ~= nil and payload:find("NewAlt", 1, true) ~= nil)
    check("Payload does not carry the untouched seed record", payload:find("R:MainB|", 1, true) == nil)
    check("Changed record got a syncedAt stamp", ns.creditsDb.ledger["MainA"].syncedAt and ns.creditsDb.ledger["MainA"].syncedAt > 0)
    check("Record sent live is not left dirty", ns.creditsDb.ledger["MainA"].dirty == nil)
    check("Payload carries the review-queue removal stamp", payload:find("Q:NewAlt|0|", 1, true) ~= nil)
    for _, m in ipairs(toOfficer2) do
        check("Every chunk fits the 255-byte addon message limit", #PFX + #m.text <= 255)
    end

    -- ---- multi-chunk, out-of-order reassembly --------------------------------
    setup()
    for k = 1, 30 do ns.Credits_LinkAlt("Bulkalt" .. k, "MainA") end
    outboxLog = {}
    ns.Credits_LinkAlt("Bulkalt31", "MainA")
    local msgs = dataTo("Officer2")
    check("A big account produces a multi-chunk transmission", #msgs > 1)
    local snapshotAlts = #ns.creditsDb.ledger["MainA"].alts
    -- Roll the local record back to a stale stamp with no alts, then deliver reversed.
    ns.creditsDb.ledger["MainA"].alts = {}
    ns.creditsDb.ledger["MainA"].syncedAt = 1
    ns.Credits_RebuildToonIndex()
    for k = #msgs, 1, -1 do deliver("Officer2", msgs[k].text) end
    check("Out-of-order chunks reassemble and the newer record is applied",
        #ns.creditsDb.ledger["MainA"].alts == snapshotAlts)
    check("toonIndex is rebuilt after an applied record", ns.creditsDb.toonIndex["bulkalt31"] == "MainA")

    -- ---- last-writer-wins -------------------------------------------------
    setup()
    local base = { discordName = "MainA", mainToon = "MainA", alts = { "Fresh" }, points = 100, credits = 0,
        tier = "Neutral", prestige = 0, lifetimePoints = 100, lastDonationDate = "", lastUpdated = 5,
        syncedAt = 1000, lifetimeCredits = 0 }
    local function msgFor(rec)
        return "LSYNCDATA|abc1|1/1|F:" .. ns.CreditsSync_Fingerprint() .. ";R:" .. ns.CreditsSync_EncodeRecord(rec)
    end
    deliver("Officer2", msgFor(base))
    check("Newer syncedAt over an unsynced seed record is applied", ns.creditsDb.ledger["MainA"].alts[1] == "Fresh")
    local older = { discordName = "MainA", mainToon = "MainA", alts = { "Older" }, points = 100, credits = 0,
        tier = "Neutral", prestige = 0, lifetimePoints = 100, lastDonationDate = "", lastUpdated = 5,
        syncedAt = 900, lifetimeCredits = 0 }
    deliver("Officer2", msgFor(older))
    check("A stale record (lower syncedAt) is ignored", ns.creditsDb.ledger["MainA"].alts[1] == "Fresh")
    local tieHi = { discordName = "MainA", mainToon = "MainA", alts = { "Zzz" }, points = 100, credits = 0,
        tier = "Neutral", prestige = 0, lifetimePoints = 100, lastDonationDate = "", lastUpdated = 5,
        syncedAt = 1000, lifetimeCredits = 0 }
    local tieLo = { discordName = "MainA", mainToon = "MainA", alts = { "Aaa" }, points = 100, credits = 0,
        tier = "Neutral", prestige = 0, lifetimePoints = 100, lastDonationDate = "", lastUpdated = 5,
        syncedAt = 1000, lifetimeCredits = 0 }
    deliver("Officer2", msgFor(tieLo))
    check("Equal stamps: the lexically lower encoding does not displace the current record",
        ns.creditsDb.ledger["MainA"].alts[1] == "Fresh")
    deliver("Officer2", msgFor(tieHi))
    local afterHi = ns.creditsDb.ledger["MainA"].alts[1]
    deliver("Officer2", msgFor(tieLo))
    check("Tie-break is order-independent (both orders converge on the same record)",
        ns.creditsDb.ledger["MainA"].alts[1] == afterHi and afterHi == "Zzz")
    local rollback = ns.creditsDb.ledger["MainA"].syncedAt
    check("Applying a received record keeps the sender's syncedAt (no re-stamp)", rollback == 1000)
    check("A received record is not marked dirty (no echo loop)", ns.creditsDb.ledger["MainA"].dirty == nil)
    check("Receiving never triggers an outbound send by itself", #outboxOfType("LSYNCDATA") == 0)

    -- A brand-new account arrives whole.
    local brandNew = { discordName = "NewAcct", mainToon = "NewAcct", alts = {}, points = 0, credits = 0,
        tier = "Neutral", prestige = 0, lifetimePoints = 0, lastDonationDate = "", lastUpdated = 5,
        syncedAt = 2000, lifetimeCredits = 0 }
    deliver("Officer2", msgFor(brandNew))
    check("A new account record is created", ns.creditsDb.ledger["NewAcct"] ~= nil and ns.creditsDb.toonIndex["newacct"] == "NewAcct")

    -- ---- sender / receiver verification ------------------------------------
    setup()
    deliver("Member1", msgFor(base))
    check("A non-officer guild member cannot write the ledger", ns.creditsDb.ledger["MainA"].syncedAt == nil)
    deliver("Stranger", msgFor(base))
    check("A sender outside the guild is rejected", ns.creditsDb.ledger["MainA"].syncedAt == nil)
    ns.db.editors = { "Officer1" } -- Officer2 no longer an officer on THIS client
    deliver("Officer2", msgFor(base))
    check("Sender is judged against the receiver's OWN officer list (not the message)", ns.creditsDb.ledger["MainA"].syncedAt == nil)
    ns.db.editors = { "Officer1", "Officer2" }
    deliver("GLeader", msgFor(base))
    check("The guild leader is an authorized sender", ns.creditsDb.ledger["MainA"].syncedAt == 1000)
    setup()
    currentPlayerName = "Member1"
    deliver("Officer2", msgFor(base))
    check("A receiver who is not an officer applies nothing", ns.creditsDb.ledger["MainA"].syncedAt == nil)
    deliver("Officer2", "LSYNCREQ|" .. ns.CreditsSync_Fingerprint() .. "|0")
    check("A receiver who is not an officer answers nothing", #outboxLog == 0)

    -- ---- fingerprint mismatch --------------------------------------------------
    setup()
    local badFp = "LSYNCDATA|abc2|1/1|F:deadbeef;R:" .. ns.CreditsSync_EncodeRecord(base)
    deliver("Officer2", badFp)
    check("A seed-fingerprint mismatch applies nothing", ns.creditsDb.ledger["MainA"].syncedAt == nil)
    local warns = 0
    for _, l in ipairs(printLog) do if tostring(l):find("seed data differs", 1, true) then warns = warns + 1 end end
    check("A mismatch prints one warning", warns == 1)
    deliver("Officer2", badFp)
    deliver("Officer2", "LSYNCREQ|deadbeef|0")
    warns = 0
    for _, l in ipairs(printLog) do if tostring(l):find("seed data differs", 1, true) then warns = warns + 1 end end
    check("Repeated mismatches from the same peer do not spam", warns == 1)
    check("A mismatched request is not answered", #dataTo("Officer2") == 0)

    -- ---- hostile / malformed input never errors -----------------------------
    setup()
    local fpNow = ns.CreditsSync_Fingerprint()
    local junk = {
        "LSYNCDATA", "LSYNCDATA|", "LSYNCDATA|zz|1/1|x", "LSYNCDATA|ab|0/0|x", "LSYNCDATA|ab|5/1|x",
        "LSYNCDATA|ab|1/999999|x", "LSYNCDATA|ab|1/1|F:" .. fpNow .. ";R:", "LSYNCDATA|ab|1/1|F:" .. fpNow .. ";R:a|b",
        "LSYNCDATA|ab|1/1|F:" .. fpNow .. ";Q:|1|5", "LSYNCDATA|ab|1/1|F:" .. fpNow .. ";Q:x|9|abc",
        "LSYNCDATA|ab|1/1|;;;;", "LSYNCREQ", "LSYNCREQ|nothex|abc", "LSYNCREQ||",
    }
    local allOk = true
    for _, j in ipairs(junk) do
        local ok = pcall(deliver, "Officer2", j)
        if not ok then allOk = false end
    end
    check("Malformed LSYNC messages are ignored without raising errors", allOk)
    check("Malformed messages changed nothing", ns.creditsDb.ledger["MainA"].syncedAt == nil and next(ns.creditsDb.rqStamps) == nil)

    -- ---- answering a request ---------------------------------------------------
    setup()
    ns.Credits_LinkAlt("NewAlt", "MainA")
    outboxLog = {}
    deliver("Officer2", "LSYNCREQ|" .. ns.CreditsSync_Fingerprint() .. "|0")
    local ans = dataTo("Officer2")
    check("A request is answered with LSYNCDATA", #ans >= 1)
    local ap = payloadOf(ans)
    check("The answer carries post-seed records only", ap:find("R:MainA|", 1, true) and not ap:find("R:MainB|", 1, true))
    check("The requester is asked back once (reciprocal)", #reqsTo("Officer2") == 1)
    outboxLog = {}
    deliver("Officer2", "LSYNCREQ|" .. ns.CreditsSync_Fingerprint() .. "|0")
    check("A second request from the same peer does not trigger another reciprocal", #reqsTo("Officer2") == 0)
    outboxLog = {}
    deliver("Officer2", "LSYNCREQ|" .. ns.CreditsSync_Fingerprint() .. "|" .. (ns.creditsDb.ledger["MainA"].syncedAt + 1000))
    check("A request newer than everything we have gets no data", #dataTo("Officer2") == 0)

    -- ---- offline edit -> dirty -> flushed (re-stamped) on next contact ----------
    setup()
    guildRosterEntries[3].online = false -- Officer2 offline
    guildRosterEntries[1].online = false -- ...and the guild leader (also a peer)
    ns.UpdateGuildRosterCache()
    ns.Credits_LinkAlt("OfflineAlt", "MainA")
    check("With no officer online the edit is sent nowhere", #outboxLog == 0)
    check("...and the record is marked dirty", ns.creditsDb.ledger["MainA"].dirty == true)
    local oldStamp = ns.creditsDb.ledger["MainA"].syncedAt
    check("...and the dirty edit is NOT served to a request yet",
        (function() deliver("Officer2", "LSYNCREQ|" .. ns.CreditsSync_Fingerprint() .. "|0") return #dataTo("Officer2") end)() == 0)
    wallClock = wallClock + 3600
    guildRosterEntries[3].online = true
    guildRosterEntries[1].online = true
    ns.UpdateGuildRosterCache()
    outboxLog = {}
    ns.CreditsSync_OnLogin()
    check("Login asks each online officer for what we missed", #reqsTo("Officer2") == 1)
    local flushed = payloadOf(dataTo("Officer2"))
    check("Dirty edits are pushed at contact", flushed:find("OfflineAlt", 1, true) ~= nil)
    check("...re-stamped at share time, not edit time", ns.creditsDb.ledger["MainA"].syncedAt > oldStamp)
    check("...and no longer dirty", ns.creditsDb.ledger["MainA"].dirty == nil)
    check("lastSyncAt is recorded for the next 'since'", ns.creditsDb.lastSyncAt == wallClock)

    -- ---- new officer coming online is asked once ---------------------------------
    setup()
    guildRosterEntries[3].online = false
    ns.UpdateGuildRosterCache()
    ns.CreditsSync_OnLogin()
    check("No online officer at login means no request", #reqsTo("Officer2") == 0)
    guildRosterEntries[3].online = true
    ns.UpdateGuildRosterCache()
    ns.CreditsSync_OnRosterUpdate()
    check("An officer who logs in later is asked", #reqsTo("Officer2") == 1)
    ns.CreditsSync_OnRosterUpdate()
    check("...but only once while they stay online", #reqsTo("Officer2") == 1)
    guildRosterEntries[3].online = false
    ns.UpdateGuildRosterCache()
    ns.CreditsSync_OnRosterUpdate()
    guildRosterEntries[3].online = true
    ns.UpdateGuildRosterCache()
    ns.CreditsSync_OnRosterUpdate()
    check("...and asked again after a relog", #reqsTo("Officer2") == 2)

    -- ---- review queue rides along ----------------------------------------------------
    setup()
    ns.Credits_LinkAlt("QAlt", "MainA")
    ns.Credits_UnlinkAlt("QAlt")
    local queued = false
    for _, r in ipairs(ns.creditsDb.dynamicReviewQueue) do if r.name == "QAlt" then queued = true end end
    check("Unlink reopened the name in the queue locally", queued)
    check("Unlink sent a queue-add stamp", payloadOf(dataTo("Officer2")):find("Q:QAlt|1|", 1, true) ~= nil)
    local ts = ns.creditsDb.rqStamps["qalt"].ts
    local function qmsg(present, stamp)
        return "LSYNCDATA|abc3|1/1|F:" .. ns.CreditsSync_Fingerprint() .. ";Q:QAlt|" .. present .. "|" .. stamp
    end
    deliver("Officer2", qmsg(0, ts - 1))
    queued = false
    for _, r in ipairs(ns.creditsDb.dynamicReviewQueue) do if r.name == "QAlt" then queued = true end end
    check("A stale queue-remove is ignored", queued)
    deliver("Officer2", qmsg(0, ts + 5))
    queued = false
    for _, r in ipairs(ns.creditsDb.dynamicReviewQueue) do if r.name == "QAlt" then queued = true end end
    check("A newer queue-remove clears the name", not queued)
    deliver("Officer2", qmsg(1, ts + 9))
    queued = false
    for _, r in ipairs(ns.creditsDb.dynamicReviewQueue) do if r.name == "QAlt" then queued = true end end
    check("A still-newer queue-add reopens it", queued)

    -- ---- SetAsNewMain syncs the new account and clears the queue ------------------------
    setup()
    ns.Credits_AddToReviewQueue("Newbie")
    outboxLog = {}
    check("SetAsNewMain succeeds", ns.Credits_SetAsNewMain("Newbie", 0, "2026-09-20") == true)
    local nm = payloadOf(dataTo("Officer2"))
    check("The new account is whispered to officers", nm:find("R:Newbie|", 1, true) ~= nil)
    check("...with the queue removal", nm:find("Q:Newbie|0|", 1, true) ~= nil)

    -- ---- stamps strictly increase within one second --------------------------------------
    setup()
    ns.Credits_LinkAlt("S1", "MainA")
    local s1 = ns.creditsDb.ledger["MainA"].syncedAt
    ns.Credits_LinkAlt("S2", "MainA")
    check("Two edits in the same clock second still get increasing stamps", ns.creditsDb.ledger["MainA"].syncedAt > s1)
end

--------------------------------------------------------------------------
print("== Credits: Discord name / Main / Alt ==")
resetState()
inGuild = true
guildRosterEntries = { { name = "Officer1", rankIndex = 3 } }
ns.UpdateGuildRosterCache()
currentPlayerName = "Officer1"
ns.db.editors = { "Officer1" }
ns.CreditsSeedData = { Cranky = { lifetimePoints = 100 }, Other = { lifetimePoints = 50 } }
ns.CreditsAltRoster = { Cranky = { "Oldncranky", "Sidecar" } }
ns.CreditsSeed_Import()
do
    local rec = ns.creditsDb.ledger["Cranky"]
    check("Seeded account starts with the Discord tag on the main (Discord & Main)",
        rec.discord == "Cranky" and ns.Credits_IsDiscordName(rec, "Cranky"))
    check("Credits_GetDiscord falls back to the ledger key for a pre-migration record",
        ns.Credits_GetDiscord({ discordName = "Old" }) == "Old")
    check("A record with discord = \"\" reports no Discord name", ns.Credits_GetDiscord({ discordName = "X", discord = "" }) == "")

    -- Discord Only is refused on the main (an account must have a real main).
    check("Discord Only is refused on the main toon", ns.Credits_MakeDiscordOnly("Cranky") == false)
    check("...and the account is unchanged", rec.mainToon == "Cranky" and #rec.alts == 2)
    check("Discord Only is refused on a name that is on no account", ns.Credits_MakeDiscordOnly("Nobody") == false)

    -- The Cranky scenario: real main is the alt Oldncranky.
    check("Promote Oldncranky to main", ns.Credits_PromoteToMain("Oldncranky") == true)
    check("Cranky (old main) is now an alt and still carries the Discord tag",
        rec.mainToon == "Oldncranky" and ns.Credits_IsDiscordName(rec, "Cranky"))
    check("Discord Only turns the Cranky alt into a Discord-only name", ns.Credits_MakeDiscordOnly("Cranky") == true)
    check("...it left the alts list", (function()
        for _, a in ipairs(rec.alts) do if a == "Cranky" then return false end end
        return true
    end)())
    check("...it kept the Discord tag and the main is unchanged",
        rec.discord == "Cranky" and rec.mainToon == "Oldncranky")
    check("...it is no longer a resolvable character", ns.creditsDb.toonIndex["cranky"] == nil)
    local queued = false
    for _, r in ipairs(ns.Credits_ReviewQueueRows()) do if r.name == "Cranky" then queued = true end end
    check("...and it did NOT go to the Review Queue", not queued)
    check("Oldncranky still resolves to itself as the main", ns.Credits_ResolveMain("Sidecar") == "Oldncranky")

    -- Only one Discord name: Add as Discord moves the tag and drops the old one.
    check("Add as Discord on Sidecar succeeds", ns.Credits_SetDiscord("Sidecar") == true)
    check("There is only one Discord name - the Discord-only name was replaced", rec.discord == "Sidecar")
    check("Add as Discord on the name that already has it is a no-op", ns.Credits_SetDiscord("Sidecar") == false)
    check("Add as Discord refuses a name that is not on any account", ns.Credits_SetDiscord("Nobody") == false)
    check("Add as Discord moves it to the main", ns.Credits_SetDiscord("Oldncranky") == true and rec.discord == "Oldncranky")

    -- Remove as Discord leaves it not set; the main is untouched.
    check("Remove as Discord clears the tag", ns.Credits_ClearDiscord("Cranky") == true and rec.discord == "")
    check("...the main and alts are untouched", rec.mainToon == "Oldncranky" and #rec.alts == 1)
    check("Removing again is a no-op", ns.Credits_ClearDiscord("Cranky") == false)
    check("Remove refuses an unknown account", ns.Credits_ClearDiscord("NoSuchAccount") == false)

    -- Permission gate.
    local prior = ns.db.editors
    ns.db.editors = {}
    check("Set/Clear/DiscordOnly all require officer permission",
        ns.Credits_SetDiscord("Sidecar") == false and ns.Credits_ClearDiscord("Cranky") == false
        and ns.Credits_MakeDiscordOnly("Sidecar") == false)
    ns.db.editors = prior

    -- Sync wire format: round trip incl. empty and Discord-only names.
    rec.discord = "Cranky"
    local back = ns.CreditsSync_DecodeRecord(ns.CreditsSync_EncodeRecord(rec))
    check("Wire round trip keeps a Discord-only name", back and back.discord == "Cranky")
    rec.discord = ""
    back = ns.CreditsSync_DecodeRecord(ns.CreditsSync_EncodeRecord(rec))
    check("Wire round trip keeps an empty (not set) Discord name", back and back.discord == "")
    local enc = ns.CreditsSync_EncodeRecord(rec)
    local legacy = enc:gsub("|d[^|]*$", "")   -- a 12-field record from an older build
    back = ns.CreditsSync_DecodeRecord(legacy)
    check("A 12-field record from an older build decodes, defaulting Discord to the ledger key",
        back and back.discord == back.discordName)
end

-- Displaced / cleared Discord-only names go to the Review Queue (2026-10-04,
-- Loopi: Avrony, a real alt set to Discord Only, vanished completely when
-- Loopi was later set as the Discord name).
do
    resetState()
    inGuild = true
    guildRosterEntries = { { name = "Officer1", rankIndex = 3 } }
    ns.UpdateGuildRosterCache()
    currentPlayerName = "Officer1"
    ns.db.editors = { "Officer1" }
    ns.CreditsSeedData = { Loopi = { lifetimePoints = 10 } }
    ns.CreditsAltRoster = { Loopi = { "Avrony", "Second" } }
    ns.CreditsSeed_Import()
    local rec = ns.creditsDb.ledger["Loopi"]
    local function inQueue(name)
        for _, r in ipairs(ns.Credits_ReviewQueueRows()) do if r.name == name then return true end end
        return false
    end

    check("Avrony: Discord Only on the alt", ns.Credits_MakeDiscordOnly("Avrony") == true and rec.discord == "Avrony")
    check("Avrony: not queued while it is still the Discord tag", not inQueue("Avrony"))
    local ok, displaced = ns.Credits_SetDiscord("Loopi")
    check("Avrony: Add as Discord succeeds and reports the displaced Discord-only name",
        ok == true and displaced == "Avrony" and rec.discord == "Loopi")
    check("Avrony: the displaced Discord-only name is now in the Review Queue", inQueue("Avrony"))
    check("Avrony: it did not come back as an alt of the account", ns.creditsDb.toonIndex["avrony"] == nil)

    -- Remove as Discord on a Discord-only name also queues it (no data loss).
    check("Second: Discord Only on the other alt", ns.Credits_MakeDiscordOnly("Second") == true and rec.discord == "Second")
    local ok2, cleared = ns.Credits_ClearDiscord("Loopi")
    check("Second: Remove as Discord succeeds and reports the cleared Discord-only name",
        ok2 == true and cleared == "Second" and rec.discord == "")
    check("Second: the cleared Discord-only name is in the Review Queue", inQueue("Second"))

    -- Replacing/clearing a tag on a REAL character queues nothing.
    local ok3, d3 = ns.Credits_SetDiscord("Loopi")
    check("Setting the tag when none is set reports no displaced name", ok3 == true and d3 == nil)
    local ok4, c4 = ns.Credits_ClearDiscord("Loopi")
    check("Clearing the tag on a real character reports no cleared Discord-only name", ok4 == true and c4 == nil)
    check("...and the main is never queued", not inQueue("Loopi"))
end

-- Migration: a record saved before the field existed.
do
    resetState()
    DHBavinCreditsDB = { ledger = { Legacy = { discordName = "Legacy", mainToon = "Legacy", alts = {}, credits = 0 } } }
    ns.InitCreditsDB()
    check("InitCreditsDB gives pre-existing records discord = ledger key", ns.creditsDb.ledger["Legacy"].discord == "Legacy")
end

--------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------
print("")
print(("RESULTS: %d passed, %d failed"):format(PASS, FAIL))
if FAIL > 0 then
    print("Failures:")
    for _, f in ipairs(failures) do
        print("  - " .. f)
    end
    os.exit(1)
else
    os.exit(0)
end
