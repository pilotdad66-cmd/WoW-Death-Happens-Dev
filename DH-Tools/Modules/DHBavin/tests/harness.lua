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
-- WoW's date() is os.date (CM4's lastDonationDate stamp uses it).
_G.date = os.date

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
local FILES = { "Core.lua", "Sync.lua", "ItemPoints.lua", "ToonDonations.lua", "ArchivedDonors.lua", "Credits.lua", "CreditsSeed.lua", "CreditsSync.lua", "CreditsMember.lua", "CreditsDonations.lua", "CreditsInbox.lua", "CreditsLog.lua" }

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
        -- CM6 member-side balance cache (CreditsMember.lua)
        ns.creditsDb.memberBal = {}
        -- CM4 (CreditsDonations.lua / CreditsSync.lua additions)
        ns.creditsDb.pendingCredits = {}
        ns.creditsDb.pendingReleased = {}
        ns.creditsDb.ledgerTombstones = {}
        ns.creditsDb.creditsPerRep = { x = 1, y = 100 }
        ns.creditsDb.repPerGold = { x = 100, y = 1 }
    end
    ns.creditsArmedInbox = false
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

ns.Sync_OnAddonMessage("DHBavinV5", "RECIPIENT|Someone", "GUILD", "Grunt1")
check("A RECIPIENT message from a rank>3 non-Bavin/Loopidot sender is ignored",
    ns.db.recipient == nil)

ns.Sync_OnAddonMessage("DHBavinV5", "RECIPIENT|Someone", "GUILD", "RealLeader")
check("A RECIPIENT message from a rank-0 leader who isn't Bavin/Loopidot is ALSO ignored now",
    ns.db.recipient == nil)

ns.Sync_OnAddonMessage("DHBavinV5", "RECIPIENT|Someone", "GUILD", "Bavin")
check("A RECIPIENT message from the sender name 'Bavin' is accepted (name-based, not rank-based)",
    ns.db.recipient == "Someone")

ns.db.recipient = nil
ns.Sync_OnAddonMessage("DHBavinV5", "EDITORS|Officer1", "GUILD", "Officer1")
check("An EDITORS message from a rank<=3 sender who isn't guild leader/recipient/Loopidot is now ignored (2026-09-28)",
    #ns.db.editors == 0)

ns.Sync_OnAddonMessage("DHBavinV5", "EDITORS|Officer1", "GUILD", "RealLeader")
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

ns.Sync_OnAddonMessage("DHBavinV5", "ITEM|Some Item|999|somelink", "GUILD", "Bavin")
check("ITEM from an authorized sender is applied", ns.priorityList["Some Item"] ~= nil)
check("addedBy reflects the verified sender", ns.priorityList["Some Item"].addedBy == "Bavin")

ns.Sync_OnAddonMessage("DHBavinV5", "ITEM|Forged Item|1|link", "GUILD", "BadActor")
check("ITEM from an unauthorized sender is ignored", ns.priorityList["Forged Item"] == nil)

ns.Sync_OnAddonMessage("DHBavinV5", "ITEMGONE|Some Item", "GUILD", "Bavin")
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

ns.Sync_OnAddonMessage("DHBavinV5", "SYNCREQ", "GUILD", "Requester")
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
    ns.Sync_OnAddonMessage("DHBavinV5", entry.text, "WHISPER", "PeerB")
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
ns.Sync_OnAddonMessage("DHBavinV5", "SYNCDATA|1/1|Bavin||1|999|Fresh Item|1|link", "WHISPER", "PeerB")
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
ns.Sync_OnAddonMessage("DHBavinV5", "SYNCDATA|1/1|Bavin||0|50|Stale Peer Item|2|link2", "WHISPER", "PeerB")
check("An OLDER incoming snapshot does not touch the local list",
    ns.priorityList["My Current Item"] ~= nil and ns.priorityList["Stale Peer Item"] == nil)
check("Local priorityListUpdatedAt is unchanged after rejecting an older snapshot",
    ns.db.priorityListUpdatedAt == 100)

ns.Sync_OnAddonMessage("DHBavinV5", "SYNCDATA|1/1|Bavin||0|100|Equal Timestamp Item|3|link3", "WHISPER", "PeerB")
check("An EQUAL-timestamp incoming snapshot is also rejected (strictly newer required, not >=)",
    ns.priorityList["My Current Item"] ~= nil and ns.priorityList["Equal Timestamp Item"] == nil)

ns.Sync_OnAddonMessage("DHBavinV5", "SYNCDATA|1/1|Bavin||0|150|Fresh Peer Item|4|link4", "WHISPER", "PeerB")
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
ns.Sync_OnAddonMessage("DHBavinV5", "SYNCDATA|1/1|SomeoneElse||1000|1|Ignored Item|9|link9", "WHISPER", "PeerB")
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

ns.Sync_OnAddonMessage("DHBavinV5", "SYNCDATA|1/1|StalePeerRecipient|StalePeerEditor|50|0|", "WHISPER", "PeerB")
check("An OLDER incoming recipient/editors snapshot does not touch local state",
    ns.db.recipient == "Bavin" and #ns.db.editors == 1 and ns.db.editors[1] == "OriginalEditor")
check("Local recipientEditorsUpdatedAt is unchanged after rejecting an older snapshot",
    ns.db.recipientEditorsUpdatedAt == 100)

ns.Sync_OnAddonMessage("DHBavinV5", "SYNCDATA|1/1|EqualPeerRecipient|EqualPeerEditor|100|0|", "WHISPER", "PeerB")
check("An EQUAL-timestamp incoming snapshot is also rejected (strictly newer required, not >=)",
    ns.db.recipient == "Bavin")

ns.Sync_OnAddonMessage("DHBavinV5", "SYNCDATA|1/1|FreshPeerRecipient|FreshPeerEditor1,FreshPeerEditor2|150|0|", "WHISPER", "PeerB")
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
ns.Sync_OnAddonMessage("DHBavinV5", "PTSSET|Test Baseline Item|1|777|" .. (currentVersion - 100) .. "||||||", "GUILD", "OtherEditor")
check("An older incoming edit is ignored (last-writer-wins)",
    ns.GetItemPoints("Test Baseline Item").points == 50)

wallClock = wallClock + 10
ns.Sync_OnAddonMessage("DHBavinV5", "PTSSET|Test Baseline Item|75|777|" .. wallClock .. "||||||", "GUILD", "OtherEditor")
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
ns.Sync_OnAddonMessage("DHBavinV5", "PTSSYNCREQ|1500", "GUILD", "Requester")
local ptsData = outboxOfType("PTSSYNCDATA")
check("PTSSYNCREQ triggers a PTSSYNCDATA reply", #ptsData > 0)

ns.db.itemPointsOverrides = {}
for _, entry in ipairs(ptsData) do
    ns.Sync_OnAddonMessage("DHBavinV5", entry.text, "WHISPER", "PeerC")
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
ns.Sync_OnAddonMessage("DHBavinV5", "PTSSYNCREQ|0", "GUILD", "Requester")
local nastyData = outboxOfType("PTSSYNCDATA")
check("PTSSYNCREQ replied with wording-bearing entries", #nastyData > 0)

ns.db.itemPointsOverrides = {}
for _, entry in ipairs(nastyData) do
    ns.Sync_OnAddonMessage("DHBavinV5", entry.text, "WHISPER", "PeerD")
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
ns.Sync_OnAddonMessage("DHBavinV5", ptsSet[1].text, "GUILD", "OtherEditor")
check("PTSSET wording survives the round trip intact",
    ns.db.itemPointsOverrides["Wire Test Item"]
    and ns.db.itemPointsOverrides["Wire Test Item"].detail == nastyDetail)

--------------------------------------------------------------------------
-- Section 10b: Points Editor update (2026-10-07, Loopi) - item fields
-- (goldValue / category / stackSize / phrase), the BUILT item text, the
-- items-only ratio and the V5 wire format.
--------------------------------------------------------------------------
print("== Points Editor: item text builder, fields, V5 wire ==")

-- FormatItemGold: the sheet's style
check("FormatItemGold 24 -> 24g", ns.FormatItemGold(24) == "24g")
check("FormatItemGold 50.34 -> 50g (whole above 10g)", ns.FormatItemGold(50.34) == "50g")
check("FormatItemGold 1.6 -> 1.6g", ns.FormatItemGold(1.6) == "1.6g")
check("FormatItemGold 8 -> 8g (no trailing .0)", ns.FormatItemGold(8) == "8g")
check("FormatItemGold 0.35 -> 35s", ns.FormatItemGold(0.35) == "35s")
check("FormatItemGold 0 / nil -> n/a", ns.FormatItemGold(0) == "n/a" and ns.FormatItemGold(nil) == "n/a")

-- BuildItemDetail
check("Build: plain category phrase",
    ns.BuildItemDetail("Foo", 240, 24, nil, "Alchemy") == "Foo: 240 pts to Bavin; 24g crafted by an @Alchemist")
check("Build: stack part",
    ns.BuildItemDetail("Foo", 48, 4.8, 5, "Alchemy") == "Foo: 48 pts to Bavin; 4.8g ea or 24g for x5 crafted by an @Alchemist")
check("Build: category with no phrase uses (est. AH value)",
    ns.BuildItemDetail("Foo", 10, 1, nil, "Cloth") == "Foo: 10 pts to Bavin; 1g (est. AH value)")
check("Build: own phrase wins",
    ns.BuildItemDetail("Foo", 10, 1, nil, "Cloth", "in #market") == "Foo: 10 pts to Bavin; 1g in #market")
check("Build: stack of 1 is no stack",
    ns.BuildItemDetail("Foo", 10, 1, 1, "Cloth") == "Foo: 10 pts to Bavin; 1g (est. AH value)")
check("Build: no gold -> n/a",
    ns.BuildItemDetail("Foo", 10, nil, nil, nil) == "Foo: 10 pts to Bavin; n/a (est. AH value)")

-- ParseItemDetail
do
    local st, ph = ns.ParseItemDetail("Foo: 48 pts to Bavin; 4.8g ea or 24g for x5 crafted by an @Alchemist")
    check("Parse: stack + phrase recovered", st == 5 and ph == "crafted by an @Alchemist")
    st, ph = ns.ParseItemDetail("Foo: 10 pts to Bavin; 1g in #market")
    check("Parse: phrase only", st == nil and ph == "in #market")
    st, ph = ns.ParseItemDetail("Foo: 10 pts to Bavin; n/a (est. AH value)")
    check("Parse: n/a price", st == nil and ph == "(est. AH value)")
    check("Parse: non-pattern text -> nil", ns.ParseItemDetail("Some hand-written note") == nil and ns.ParseItemDetail(nil) == nil)
end

-- Items-only ratio
resetState()
inGuild = true
guildRosterEntries = { { name = "Bavin", rankIndex = 3 }, { name = "OtherEditor", rankIndex = 5 } }
ns.UpdateGuildRosterCache()
ns.db.recipient = "Bavin"
ns.db.editors = { "OtherEditor" }
currentPlayerName = "Bavin"
check("Items-only ratio defaults to 10 points per gold", ns.GetItemPointsPerGold() == 10)
ns.db.itemPointsPerGold = 12
check("Items-only ratio honours the per-client override", ns.GetItemPointsPerGold() == 12)
ns.db.itemPointsPerGold = nil
check("Items-only ratio is independent of the donation Rep/Gold setting",
    (function() ns.db.credits = ns.db.credits or {}; ns.db.credits.repPerGold = 77; return ns.GetItemPointsPerGold() == 10 end)())

-- Fields: baseline, ResolveItemFields, auto vs hand-edited
ns.ITEM_POINTS["PE Stack Item"] = { points = 48, itemId = 9001, goldValue = 4.8, category = "Alchemy",
    detail = "PE Stack Item: 48 pts to Bavin; 4.8g ea or 24g for x5 crafted by an @Alchemist" }
ns.ITEM_POINTS["PE Market Item"] = { points = 10, itemId = 9002, goldValue = 1, category = "Cloth",
    detail = "PE Market Item: 10 pts to Bavin; 1g in #market" }
ns.ITEM_POINTS["PE Odd Item"] = { points = 10, itemId = 9003, goldValue = 1, category = "Cloth",
    detail = "PE Odd Item: totally custom shipped text" }
do
    local f = ns.ResolveItemFields("PE Stack Item")
    check("Resolve: baseline stack recovered from text, auto true (text matches builder)",
        f and f.stackSize == 5 and f.auto == true and f.phrase == nil and f.category == "Alchemy" and f.goldValue == 4.8)
    f = ns.ResolveItemFields("PE Market Item")
    check("Resolve: baseline custom phrase recovered, auto true", f and f.phrase == "in #market" and f.auto == true)
    f = ns.ResolveItemFields("PE Odd Item")
    check("Resolve: shipped text not in the builder's pattern -> hand-edited (auto false)", f and f.auto == false)
    check("Resolve: unknown name -> nil", ns.ResolveItemFields("No Such Item Anywhere") == nil)
end

-- Auto override: no stored text, text follows the points
wallClock = wallClock + 10
check("SetItemPoints (auto) succeeds",
    ns.SetItemPoints("PE Stack Item", 60, 9001, nil, { goldValue = 6, category = "Alchemy", stackSize = 5, auto = true }) == true)
do
    local o = ns.db.itemPointsOverrides["PE Stack Item"]
    check("Auto override stores no text", o and o.detail == nil and o.auto == true and o.goldValue == 6)
    local info = ns.GetItemPoints("PE Stack Item")
    check("Auto override's text is built from the new fields",
        info.detail == "PE Stack Item: 60 pts to Bavin; 6g ea or 30g for x5 crafted by an @Alchemist")
    check("GetItemGoldValue honours the override", ns.GetItemGoldValue("PE Stack Item") == 6)
    check("GetItemGoldValue falls back to baseline", ns.GetItemGoldValue("PE Market Item") == 1)
end

-- Older override (no new fields) falls back to the baseline's fields
ns.ApplyItemPointsLocal("PE Market Item", 20, 9002, wallClock + 1, nil, { auto = true })
check("Override without fields inherits baseline gold/category for the built text",
    ns.GetItemPoints("PE Market Item").detail == "PE Market Item: 20 pts to Bavin; 1g (est. AH value)")

-- Hand-edited: text stored verbatim
wallClock = wallClock + 10
ns.SetItemPoints("PE Odd Item", 33, 9003, "My own words; keep them", { goldValue = 3.3, category = "Cloth", auto = false })
check("Hand-edited text is kept verbatim",
    ns.GetItemPoints("PE Odd Item").detail == "My own words; keep them" and ns.ResolveItemFields("PE Odd Item").auto == false)

-- Revert tombstone ignores extras
wallClock = wallClock + 10
ns.SetItemPoints("PE Odd Item", nil, nil, nil, { goldValue = 9, auto = true })
check("Revert tombstone keeps no extras",
    (function() local o = ns.db.itemPointsOverrides["PE Odd Item"]; return o and o.points == nil and o.goldValue == nil and o.auto == nil end)())
check("Reverted item shows the baseline again", ns.GetItemPoints("PE Odd Item").isOverride == false)

-- Wire: automatic edit sends no text and rebuilds identically on the far side
do
    resetState()
    inGuild = true
    guildRosterEntries = { { name = "Bavin", rankIndex = 3 }, { name = "OtherEditor", rankIndex = 5 } }
    ns.UpdateGuildRosterCache()
    ns.db.recipient = "Bavin"
    ns.db.editors = { "OtherEditor" }
    currentPlayerName = "Bavin"
    outboxLog = {}
    wallClock = wallClock + 10
    ns.SetItemPoints("PE Stack Item", 60, 9001, nil, { goldValue = 6, category = "Alchemy", stackSize = 5, auto = true })
    local msgs = outboxOfType("PTSSET")
    check("V5: automatic edit broadcast as one PTSSET", #msgs == 1)
    local txt = msgs[1] and msgs[1].text or ""
    check("V5: automatic edit carries no text field", txt:match("|1|$") ~= nil)
    check("V5: message is short", #txt < 120)
    local expected = ns.GetItemPoints("PE Stack Item").detail
    ns.db.itemPointsOverrides = {}
    ns.Sync_OnAddonMessage("DHBavinV5", txt, "GUILD", "OtherEditor")
    local o = ns.db.itemPointsOverrides["PE Stack Item"]
    check("V5: receiver gets every field",
        o and o.points == 60 and o.goldValue == 6 and o.category == "Alchemy" and o.stackSize == 5 and o.auto == true)
    check("V5: receiver builds the same text", ns.GetItemPoints("PE Stack Item").detail == expected)
end

-- Wire: hand-edited text + hostile phrase/category survive PTSSET and PTSSYNCDATA
do
    resetState()
    inGuild = true
    guildRosterEntries = { { name = "Bavin", rankIndex = 3 }, { name = "OtherEditor", rankIndex = 5 } }
    ns.UpdateGuildRosterCache()
    ns.db.recipient = "Bavin"
    ns.db.editors = { "OtherEditor" }
    currentPlayerName = "Bavin"
    local nasty = "Pipe | semi ; back \\ and \\p"
    wallClock = wallClock + 10
    ns.SetItemPoints("PE Hand Item", 5, 9100, nasty, { goldValue = 0.5, category = "Misc.", stackSize = 20, phrase = "phr|ase;x", auto = false })
    wallClock = wallClock + 10
    ns.SetItemPoints("PE Auto Item", 7, 9101, nil, { goldValue = 0.7, category = "Cooking", auto = true })
    outboxLog = {}
    ns.Sync_OnAddonMessage("DHBavinV5", "PTSSYNCREQ|0", "GUILD", "Requester")
    local data = outboxOfType("PTSSYNCDATA")
    check("V5: sync reply produced", #data > 0)
    ns.db.itemPointsOverrides = {}
    for _, e in ipairs(data) do ns.Sync_OnAddonMessage("DHBavinV5", e.text, "WHISPER", "PeerE") end
    local h = ns.db.itemPointsOverrides["PE Hand Item"]
    check("V5 sync: hand-edited text byte-exact", h and h.detail == nasty and h.auto == false)
    check("V5 sync: hostile phrase byte-exact", h and h.phrase == "phr|ase;x")
    check("V5 sync: category / stack / gold intact", h and h.category == "Misc." and h.stackSize == 20 and h.goldValue == 0.5)
    local a = ns.db.itemPointsOverrides["PE Auto Item"]
    check("V5 sync: the next entry is unharmed", a and a.points == 7 and a.auto == true and a.detail == nil and a.category == "Cooking")

    -- direct encode/decode of a tombstone
    local enc = ns.Sync_EncodeItemEntry("Gone Item", nil, nil, 123, nil, nil)
    local dec = ns.Sync_DecodeItemEntry(enc)
    check("V5: tombstone round trip", dec and dec.name == "Gone Item" and dec.points == nil and dec.editedAt == 123 and dec.extra.auto == nil)
    check("V5: malformed entry -> nil", ns.Sync_DecodeItemEntry("junk") == nil)

    -- size guard: an over-long entry is saved locally but not sent
    outboxLog = {}
    wallClock = wallClock + 10
    local long = string.rep("x", 300)
    check("Size guard: SetItemPoints still succeeds locally",
        ns.SetItemPoints("PE Long Item", 1, 9200, long, { auto = false }) == true)
    check("Size guard: nothing was broadcast", #outboxOfType("PTSSET") == 0)
    check("Size guard: the edit is saved locally", ns.db.itemPointsOverrides["PE Long Item"] and ns.db.itemPointsOverrides["PE Long Item"].detail == long)
end

-- Does the builder reproduce the SHIPPED item texts? (information + a loose floor)
do
    local total, same, shown = 0, 0, 0
    for name, base in pairs(ns.ITEM_POINTS) do
        if base.detail and base.category and base.points then
            total = total + 1
            local st, ph = ns.ParseItemDetail(base.detail)
            local useP = (ph and ph ~= "" and ph ~= ns.DefaultItemPhrase(base.category)) and ph or nil
            local built = ns.BuildItemDetail(name, base.points, base.goldValue, st, base.category, useP)
            if built == base.detail then
                same = same + 1
            elseif shown < 12 then
                shown = shown + 1
                print("   builder mismatch: " .. base.detail .. "   <>   " .. built)
            end
        end
    end
    print(("   builder reproduces %d of %d shipped item texts (%.1f%%)"):format(same, total, total > 0 and same * 100 / total or 0))
    check("Builder reproduces most shipped item texts", total > 0 and same / total >= 0.9)
end

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

-- 2026-10-04 (Loopi): master toggle + both Wall 2 test lists are
-- AUTHOR-ONLY during CM4 testing (ns.CanManageCreditsTestConfigLocal).
inGuild = true
authorAccountFlag = false
ns.db.editors = { "PlainMember" }
currentPlayerName = "PlainMember"
check("Shared-list officer can manage rates but NOT the test gate",
    ns.CanManageCreditsConfigLocal() == true and ns.CanManageCreditsTestConfigLocal() == false)
check("Officer cannot flip the master toggle", ns.SetCreditsMasterToggle(true) == false)
check("Officer cannot add a test receiver", ns.AddCreditTestReceiver("Bavin") == false)
check("Officer cannot add a test sender", ns.AddCreditTestSender("Bavin") == false)
check("Officer cannot remove a test receiver", ns.RemoveCreditTestReceiver("Bavin") == false)
check("Officer cannot remove a test sender", ns.RemoveCreditTestSender("Bavin") == false)
authorAccountFlag = true
check("Author account passes the test gate", ns.CanManageCreditsTestConfigLocal() == true)
check("Author can flip the master toggle", ns.SetCreditsMasterToggle(true) == true)
check("Author can add a test receiver", ns.AddCreditTestReceiver("LoopiBav") == true)
ns.SetCreditsMasterToggle(false)
ns.RemoveCreditTestReceiver("LoopiBav")
inGuild = false
check("Author override does not bypass the guild gate on the test gate", ns.CanManageCreditsTestConfigLocal() == false)
authorAccountFlag = false
ns.db.editors = {}

--------------------------------------------------------------------------
-- 2026-10-04 (Loopi): the two RATES are author (all characters) / guild
-- leader / donation recipient only, travel in their own RATESET message
-- with their own timestamp, and are no longer applied from CFGSET.
print("== Credits: rates gate + RATESET ==")
do
    local PFX = "DHBavinCreditsV2"
    local function deliver(from, text) ns.Credits_OnAddonMessage(PFX, text, "GUILD", from) end
    local function sentType(t)
        for _, e in ipairs(outboxLog) do
            if e.text:sub(1, #t + 1) == t .. "|" then return e end
        end
    end
    resetState()
    inGuild = true
    guildRosterEntries = {
        { name = "GLeader", rankIndex = 0 }, { name = "PlainMember", rankIndex = 5 },
        { name = "Officer1", rankIndex = 3 }, { name = "Bavin", rankIndex = 4 },
    }
    ns.UpdateGuildRosterCache()
    ns.db.editors = { "Officer1" }
    ns.db.recipient = "Bavin"
    authorAccountFlag = false
    check("Rates: ratesUpdatedAt is initialised", type(ns.creditsDb.ratesUpdatedAt) == "number")
    local before = { x = ns.creditsDb.creditsPerRep.x, y = ns.creditsDb.creditsPerRep.y }

    currentPlayerName = "Officer1"
    check("Rates: a shared-list officer can open the config but NOT edit rates",
        ns.CanManageCreditsConfigLocal() == true and ns.CanManageCreditsRatesLocal() == false)
    check("Rates: officer Set Credits/Rep refused", ns.SetCreditsPerRep(2, 100) == false)
    check("Rates: officer Set Rep/Gold refused", ns.SetRepPerGold(2, 1) == false)
    check("Rates: refused set leaves the rates alone",
        ns.creditsDb.creditsPerRep.x == before.x and ns.creditsDb.creditsPerRep.y == before.y)
    currentPlayerName = "PlainMember"
    check("Rates: a plain member is refused", ns.CanManageCreditsRatesLocal() == false)

    currentPlayerName = "Bavin"
    outboxLog = {}
    check("Rates: the donation recipient can edit", ns.CanManageCreditsRatesLocal() == true)
    check("Rates: recipient Set Credits/Rep works", ns.SetCreditsPerRep(2, 100) == true
        and ns.creditsDb.creditsPerRep.x == 2 and ns.creditsDb.creditsPerRep.y == 100)
    check("Rates: a set broadcasts RATESET (and not the whole CFGSET)",
        sentType("RATESET") ~= nil and sentType("CFGSET") == nil)
    check("Rates: RATESET carries the rates and the new stamp",
        sentType("RATESET").text:match("^RATESET|2|100|[%d%.]+|[%d%.]+|%d+$") ~= nil and ns.creditsDb.ratesUpdatedAt > 0)
    currentPlayerName = "GLeader"
    check("Rates: the guild leader can edit", ns.CanManageCreditsRatesLocal() == true and ns.SetRepPerGold(50, 1) == true)
    currentPlayerName = "PlainMember"
    authorAccountFlag = true
    check("Rates: the author account (any character) can edit", ns.CanManageCreditsRatesLocal() == true)
    authorAccountFlag = false
    inGuild = false
    check("Rates: not in the guild -> refused", ns.CanManageCreditsRatesLocal() == false)
    inGuild = true

    -- Receive side (local player: PlainMember).
    currentPlayerName = "PlainMember"
    ns.creditsDb.creditsPerRep = { x = 1, y = 100 }
    ns.creditsDb.repPerGold = { x = 100, y = 1 }
    ns.creditsDb.ratesUpdatedAt = 1000
    deliver("Officer1", "RATESET|9|900|9|9|2000")
    check("Rates (receive): a plain officer's RATESET is ignored",
        ns.creditsDb.creditsPerRep.x == 1 and ns.creditsDb.ratesUpdatedAt == 1000)
    deliver("PlainMember2", "RATESET|9|900|9|9|2000")
    check("Rates (receive): an unknown sender's RATESET is ignored", ns.creditsDb.creditsPerRep.x == 1)
    deliver("Bavin", "RATESET|3|200|40|2|2000")
    check("Rates (receive): the recipient's RATESET is applied",
        ns.creditsDb.creditsPerRep.x == 3 and ns.creditsDb.creditsPerRep.y == 200
        and ns.creditsDb.repPerGold.x == 40 and ns.creditsDb.repPerGold.y == 2 and ns.creditsDb.ratesUpdatedAt == 2000)
    deliver("GLeader", "RATESET|4|300|41|3|1500")
    check("Rates (receive): an older stamp loses (last-writer-wins)", ns.creditsDb.creditsPerRep.x == 3)
    deliver("GLeader", "RATESET|4|300|41|3|3000")
    check("Rates (receive): the guild leader's newer RATESET is applied", ns.creditsDb.creditsPerRep.x == 4 and ns.creditsDb.ratesUpdatedAt == 3000)
    deliver("Loopi", "RATESET|5|400|42|4|4000")
    check("Rates (receive): an author character's RATESET is applied", ns.creditsDb.creditsPerRep.x == 5)
    deliver("Bavin", "RATESET|0|400|42|4|5000")
    check("Rates (receive): a zero rate is rejected", ns.creditsDb.creditsPerRep.x == 5 and ns.creditsDb.ratesUpdatedAt == 4000)
    deliver("Bavin", "RATESET|junk")
    check("Rates (receive): a malformed RATESET is rejected", ns.creditsDb.ratesUpdatedAt == 4000)

    -- A CFGSET from an officer still applies the toggle but no longer touches the rates.
    deliver("Officer1", "CFGSET|1|Officer1|Officer1|7|700|8|8|4000000000")
    check("Rates (receive): CFGSET is applied for the toggle/lists...",
        ns.creditsDb.masterToggle == true and ns.creditsDb.configUpdatedAt == 4000000000)
    check("Rates (receive): ...but its rate fields are ignored",
        ns.creditsDb.creditsPerRep.x == 5 and ns.creditsDb.repPerGold.x == 42 and ns.creditsDb.ratesUpdatedAt == 4000)
    ns.creditsDb.masterToggle = false
    ns.creditsDb.configUpdatedAt = 0

    -- Sync request: only a rates-setter's client answers with rates.
    outboxLog = {}
    deliver("Officer1", "CREDITSYNCREQ")
    check("Rates (sync): a plain member's client does not answer with rates", sentType("RATESET") == nil)
    currentPlayerName = "Bavin"
    outboxLog = {}
    deliver("Officer1", "CREDITSYNCREQ")
    check("Rates (sync): the recipient's client whispers RATESET back",
        sentType("RATESET") ~= nil and sentType("RATESET").target == "Officer1")
    currentPlayerName = "PlainMember"
    ns.creditsDb.creditsPerRep = { x = 1, y = 100 }
    ns.creditsDb.repPerGold = { x = 100, y = 1 }
    ns.creditsDb.ratesUpdatedAt = 0
end

--------------------------------------------------------------------------
-- 2026-10-04 (Loopi): "Start from scratch" - the coordinated reset. Only the
-- author account starts it; DATAEPOCH is accepted only from setter-class
-- names and only when newer; offline officers catch up via login / sync
-- replies; the epoch is folded into the ledger-sync fingerprint.
print("== Credits: start from scratch (DATAEPOCH) ==")
do
    local PFX = "DHBavinCreditsV2"
    local function deliver(from, text) ns.Credits_OnAddonMessage(PFX, text, "GUILD", from) end
    local function sentType(t)
        for _, e in ipairs(outboxLog) do
            if e.text:sub(1, #t + 1) == t .. "|" then return e end
        end
    end
    local function printed(sub)
        for _, m in ipairs(printLog) do
            if tostring(m):find(sub, 1, true) then return true end
        end
        return false
    end
    local function stray()
        ns.creditsDb.ledger["Stray"] = { discordName = "Stray", mainToon = "Stray", alts = {}, points = 0, credits = 5, lifetimePoints = 10 }
        ns.creditsDb.transactionLog = { { id = "old1", ts = 1, kind = "merge", account = "Stray" } }
        ns.creditsDb.pendingCredits = { somebody = { { id = "p1" } } }
    end
    resetState()
    inGuild = true
    guildRosterEntries = {
        { name = "GLeader", rankIndex = 0 }, { name = "PlainMember", rankIndex = 5 },
        { name = "Officer1", rankIndex = 3 }, { name = "Bavin", rankIndex = 4 },
    }
    ns.UpdateGuildRosterCache()
    ns.db.editors = { "Officer1" }
    ns.db.recipient = "Bavin"
    ns.CreditsSeedData = { MainOne = { lifetimePoints = 1500, latestDonation = "2026-09-01" } }
    ns.CreditsAltRoster = { MainOne = { "AltOne" } }
    authorAccountFlag = false
    check("Epoch: dataEpoch starts at 0", (ns.creditsDb.dataEpoch or 0) == 0)
    local baseFp = ns.CreditsSync_Fingerprint()

    -- Start refused for a non-author.
    currentPlayerName = "Officer1"
    stray()
    outboxLog = {}
    check("Epoch: a shared-list officer cannot start from scratch", ns.Credits_StartOver() == false)
    check("Epoch: a refused start leaves the data alone and sends nothing",
        ns.creditsDb.ledger["Stray"] ~= nil and #ns.creditsDb.transactionLog == 1 and sentType("DATAEPOCH") == nil)
    currentPlayerName = "Bavin"
    check("Epoch: the recipient cannot start from scratch either", ns.Credits_StartOver() == false)

    -- Start by the author account.
    authorAccountFlag = true
    currentPlayerName = "Loopi"
    ns.creditsDb.masterToggle = true
    ns.creditsDb.creditsPerRep = { x = 3, y = 7 }
    outboxLog, printLog = {}, {}
    check("Epoch: the author can start from scratch", ns.Credits_StartOver() == true)
    local epoch1 = ns.creditsDb.dataEpoch
    check("Epoch: the epoch is raised", epoch1 > 0)
    check("Epoch: the ledger was wiped and reseeded",
        ns.creditsDb.ledger["Stray"] == nil and ns.creditsDb.ledger["MainOne"] ~= nil)
    check("Epoch: audit log, held credits wiped", #ns.creditsDb.transactionLog == 0 and next(ns.creditsDb.pendingCredits) == nil)
    check("Epoch: config is preserved (toggle, rates)",
        ns.creditsDb.masterToggle == true and ns.creditsDb.creditsPerRep.x == 3 and ns.creditsDb.creditsPerRep.y == 7)
    local ann = sentType("DATAEPOCH")
    check("Epoch: DATAEPOCH is announced on the guild channel with the epoch",
        ann ~= nil and ann.channel == "GUILD" and ann.text == "DATAEPOCH|" .. epoch1)
    check("Epoch: the starter gets a chat confirmation", printed("Started from scratch"))
    local fpAfter = ns.CreditsSync_Fingerprint()
    check("Epoch: the sync fingerprint changed once the epoch is > 0", fpAfter ~= baseFp)
    ns.creditsDb.dataEpoch = 0
    check("Epoch: at epoch 0 the fingerprint is exactly the seed hash", ns.CreditsSync_Fingerprint() == baseFp)
    ns.creditsDb.dataEpoch = epoch1
    check("Epoch: a second start gets a strictly newer epoch",
        ns.Credits_StartOver() == true and ns.creditsDb.dataEpoch == epoch1 + 1)
    authorAccountFlag = false

    -- Receive side: officer (can reseed).
    ns.creditsDb.dataEpoch = 0
    currentPlayerName = "Officer1"
    stray()
    printLog = {}
    deliver("PlainMember", "DATAEPOCH|1800000001")
    check("Epoch (receive): a plain member's DATAEPOCH is ignored",
        ns.creditsDb.ledger["Stray"] ~= nil and ns.creditsDb.dataEpoch == 0)
    deliver("Officer1x", "DATAEPOCH|1800000001")
    check("Epoch (receive): an unknown sender's DATAEPOCH is ignored", ns.creditsDb.ledger["Stray"] ~= nil)
    deliver("Bavin", "DATAEPOCH|abc")
    deliver("Bavin", "DATAEPOCH|")
    check("Epoch (receive): a malformed DATAEPOCH is ignored", ns.creditsDb.ledger["Stray"] ~= nil and ns.creditsDb.dataEpoch == 0)
    deliver("Bavin", "DATAEPOCH|1800000001")
    check("Epoch (receive): the recipient's DATAEPOCH wipes + reseeds an officer",
        ns.creditsDb.dataEpoch == 1800000001 and ns.creditsDb.ledger["Stray"] == nil
        and ns.creditsDb.ledger["MainOne"] ~= nil and #ns.creditsDb.transactionLog == 0)
    check("Epoch (receive): the receiver is told", printed("started the credit data from scratch"))
    stray()
    deliver("Bavin", "DATAEPOCH|1800000001")
    deliver("GLeader", "DATAEPOCH|1700000005")
    check("Epoch (receive): the same or an older epoch is ignored", ns.creditsDb.ledger["Stray"] ~= nil)
    deliver("GLeader", "DATAEPOCH|1800000009")
    check("Epoch (receive): the guild leader's newer epoch is applied",
        ns.creditsDb.dataEpoch == 1800000009 and ns.creditsDb.ledger["Stray"] == nil)
    stray()
    deliver("Loopi", "DATAEPOCH|1800000010")
    check("Epoch (receive): an author character's newer epoch is applied", ns.creditsDb.dataEpoch == 1800000010 and ns.creditsDb.ledger["Stray"] == nil)

    -- A non-officer client wipes but cannot reseed.
    currentPlayerName = "PlainMember"
    ns.creditsDb.dataEpoch = 0
    stray()
    deliver("Bavin", "DATAEPOCH|1800000001")
    check("Epoch (receive): a non-officer is wiped and adopts the epoch, but is not reseeded",
        ns.creditsDb.dataEpoch == 1800000001 and next(ns.creditsDb.ledger) == nil)

    -- Offline-officer catch-up: setter clients answer CREDITSYNCREQ and announce at login.
    currentPlayerName = "Bavin"
    ns.creditsDb.dataEpoch = 1800000001
    outboxLog = {}
    deliver("Officer1", "CREDITSYNCREQ")
    local reply = sentType("DATAEPOCH")
    check("Epoch (catch-up): the recipient's client whispers DATAEPOCH to a requester",
        reply ~= nil and reply.channel == "WHISPER" and reply.target == "Officer1" and reply.text == "DATAEPOCH|1800000001")
    outboxLog = {}
    ns.Credits_Init()
    local loginAnn = sentType("DATAEPOCH")
    check("Epoch (catch-up): a setter client announces the epoch on the guild channel at login",
        loginAnn ~= nil and loginAnn.channel == "GUILD")
    currentPlayerName = "Officer1"
    outboxLog = {}
    deliver("PlainMember", "CREDITSYNCREQ")
    ns.Credits_Init()
    check("Epoch (catch-up): a plain officer's client does not relay or announce it", sentType("DATAEPOCH") == nil)
    currentPlayerName = "Bavin"
    ns.creditsDb.dataEpoch = 0
    outboxLog = {}
    deliver("Officer1", "CREDITSYNCREQ")
    ns.Credits_Init()
    check("Epoch (catch-up): with no reset ever done, nothing is announced", sentType("DATAEPOCH") == nil)

    -- Isolation: a client that has not had the reset can't exchange ledger data.
    ns.creditsDb.dataEpoch = 1800000001
    local newFp = ns.CreditsSync_Fingerprint()
    check("Epoch (isolation): a client on the reset fingerprints differently from one that is not", newFp ~= baseFp)
    currentPlayerName = "Officer1"
    ns.creditsDb.ledger["Edited"] = { discordName = "Edited", mainToon = "Edited", alts = {}, points = 0, credits = 1,
        lifetimePoints = 1, syncedAt = 1800000100 }
    outboxLog, printLog = {}, {}
    deliver("GLeader", "LSYNCREQ|" .. newFp .. "|0")
    check("Epoch (isolation, control): a peer on the same epoch gets a data reply", sentType("LSYNCDATA") ~= nil)
    outboxLog, printLog = {}, {}
    deliver("GLeader", "LSYNCREQ|" .. baseFp .. "|0")
    check("Epoch (isolation): an un-reset peer's LSYNCREQ gets no data and a mismatch warning",
        sentType("LSYNCDATA") == nil and printed("Ledger sync with GLeader skipped"))
    ns.creditsDb.dataEpoch = 0
    ns.creditsDb.masterToggle = false
    ns.creditsDb.creditsPerRep = { x = 1, y = 100 }
end

--------------------------------------------------------------------------
-- 2026-10-04 (Loopi: "1. Every officer. 2. Every row."): the audit log is
-- replicated between officers - immutable rows, union by id, per-day digest
-- reconciliation, merge re-tagging derived from the merge rows.
print("== Credits: audit log replication (CM7) ==")
do
    local PFX = "DHBavinCreditsV2"
    local function deliver(from, text) ns.Credits_OnAddonMessage(PFX, text, "WHISPER", from) end
    local function payloadsTo(target)
        local order, byId = {}, {}
        for _, e in ipairs(outboxLog) do
            if e.target == target and e.channel == "WHISPER" then
                local id, i, n, chunk = e.text:match("^LSYNCDATA|(%x+)|(%d+)/(%d+)|(.*)$")
                if id then
                    if not byId[id] then byId[id] = {}; order[#order + 1] = id end
                    byId[id][tonumber(i)] = chunk
                end
            end
        end
        local out = {}
        for _, id in ipairs(order) do out[#out + 1] = table.concat(byId[id]) end
        return out
    end
    local function allTo(target) return table.concat(payloadsTo(target), "\n") end
    local function setup()
        resetState()
        inGuild = true
        guildRosterEntries = {
            { name = "GLeader", rankIndex = 0 }, { name = "Officer1", rankIndex = 3 },
            { name = "Officer2", rankIndex = 3 }, { name = "Member1", rankIndex = 5 },
        }
        ns.UpdateGuildRosterCache()
        currentPlayerName = "Officer1"
        ns.db.editors = { "Officer1", "Officer2" }
        ns.CreditsSeedData = { MainA = { lifetimePoints = 100 }, MainB = { lifetimePoints = 200 } }
        ns.CreditsAltRoster = {}
        ns.CreditsSeed_Import()
        outboxLog, printLog = {}, {}
    end
    local function fp() return ns.CreditsSync_Fingerprint() end
    local enc, dec = ns.CreditsSync_EncodeLogRow, ns.CreditsSync_DecodeLogRow
    local unpackFn = table.unpack or unpack
    local wrapCounter = 0xa000
    local function wrap(...)
        wrapCounter = wrapCounter + 1
        return ("LSYNCDATA|%x|1/1|F:"):format(wrapCounter) .. fp() .. ";" .. table.concat({ ... }, ";")
    end
    local DAY = 86400
    local now = time()
    local today = math.floor(now / DAY)
    local function don(id, ts, account)
        return { id = id, ts = ts, sender = "We|ird;Don,or%~", receiver = "Bavin", account = account,
            items = { { itemID = 123, name = "Silk|Cloth; x", count = 20, rep = 5.5, category = "Cloth", unpriced = false },
                      { itemID = 9, name = "Odd", count = 1, rep = 0, category = "Uncategorized", unpriced = true } },
            gold = 12.5, rep = 5.5, credits = 0.055, creditsPerRep = { x = 1, y = 100 }, repPerGold = { x = 100, y = 1 },
            tierBefore = "Neutral", prestigeBefore = 0, tierAfter = "Friendly", prestigeAfter = 0, released = true }
    end
    local function merge(id, ts, target, source)
        return { id = id, ts = ts, kind = "merge", account = target, source = source, sourceMain = source,
            moved = { source }, rep = 1, credits = 0, officer = "Officer1" }
    end
    local function logById(id)
        for _, e in ipairs(ns.creditsDb.transactionLog) do if e.id == id then return e end end
    end

    -- ---- row codec --------------------------------------------------------
    local r = don("id-1", 1700000000, "Main|A")
    local e1 = enc(r)
    check("Log row: encoded form has no raw ';' (item delimiter)", not e1:find(";", 1, true))
    local d1 = dec(e1)
    check("Log row: scalars round-trip (hostile characters included)",
        d1 and d1.id == "id-1" and d1.ts == 1700000000 and d1.sender == r.sender and d1.account == "Main|A"
        and d1.gold == 12.5 and d1.rep == 5.5 and d1.released == true and d1.tierAfter == "Friendly")
    check("Log row: nested item lines round-trip",
        d1 and #d1.items == 2 and d1.items[1].name == "Silk|Cloth; x" and d1.items[1].count == 20
        and d1.items[1].rep == 5.5 and d1.items[1].unpriced == false and d1.items[2].unpriced == true and d1.items[2].itemID == 9)
    check("Log row: nested rate tables round-trip",
        d1 and d1.creditsPerRep.x == 1 and d1.creditsPerRep.y == 100 and d1.repPerGold.x == 100)
    local m1 = dec(enc({ id = "m-1", ts = 5, kind = "merge", moved = { "A,lt", "B|lt" }, account = "T" }))
    check("Log row: a list of strings round-trips", m1 and #m1.moved == 2 and m1.moved[1] == "A,lt" and m1.moved[2] == "B|lt")
    local m2 = dec(enc({ id = "m-2", ts = 5, moved = {} }))
    check("Log row: an empty list stays an empty table", m2 and type(m2.moved) == "table" and #m2.moved == 0)
    check("Log row: a row without an id is rejected", dec("ts=n5") == nil)
    check("Log row: a row without a timestamp is rejected", dec("id=sx") == nil)
    check("Log row: a non-numeric / zero timestamp is rejected", dec("id=sx|ts=sabc") == nil and dec("id=sx|ts=n0") == nil)
    local tol = dec("id=sx|ts=n5|junk|zz=q9|a=n1")
    check("Log row: junk fields are ignored, the rest decodes", tol and tol.id == "x" and tol.ts == 5 and tol.a == 1)

    -- ---- live push ----------------------------------------------------------
    setup()
    ns.CreditsSync_LogAdded(don("L1", now, "MainA"))
    local pushed = allTo("Officer2")
    check("Live push: a new row is whispered to an online officer",
        pushed:match("^F:" .. fp() .. ";T:") ~= nil and pushed:find("id=sL1", 1, true) ~= nil)
    check("Live push: nothing goes to a non-officer", #payloadsTo("Member1") == 0)
    local anyGuild = false
    for _, ev in ipairs(outboxLog) do if ev.channel == "GUILD" then anyGuild = true end end
    check("Live push: never on the GUILD channel", not anyGuild)
    setup()
    check("Merge wiring: merging accounts succeeds", ns.Credits_MergeAccounts("MainB", "MainA") == true)
    check("Merge wiring: the merge row is pushed live", allTo("Officer2"):find("kind=smerge", 1, true) ~= nil)
    setup()
    guildRosterEntries[3].online = false
    ns.UpdateGuildRosterCache()
    outboxLog = {}
    ns.CreditsSync_LogAdded(don("L2", now, "MainA"))
    check("Live push: with no officer online nothing is sent (reconciliation covers it later)", #payloadsTo("Officer2") == 0)

    -- ---- receive: union by id ----------------------------------------------
    setup()
    deliver("Officer2", wrap("T:" .. enc(don("R1", now - DAY, "MainA"))))
    check("Receive: a row from an officer is added", #ns.creditsDb.transactionLog == 1 and logById("R1") ~= nil)
    check("Receive: the row's nested data survived", logById("R1").items[1].name == "Silk|Cloth; x")
    deliver("Officer2", wrap("T:" .. enc(don("R1", now - DAY, "MainA"))))
    check("Receive: a row with a known id is not added twice", #ns.creditsDb.transactionLog == 1)
    deliver("Member1", wrap("T:" .. enc(don("R2", now - DAY, "MainA"))))
    check("Receive: a row from a non-officer is ignored", logById("R2") == nil)
    deliver("Officer2", "LSYNCDATA|b002|1/1|F:deadbeef;T:" .. enc(don("R3", now - DAY, "MainA")))
    check("Receive: a row under a mismatching fingerprint is ignored", logById("R3") == nil)
    deliver("Officer2", wrap("T:garbage", "T:", "T:id=sR4", "T:id=sR5|ts=n9"))
    check("Receive: malformed rows are ignored without error", logById("R4") == nil and logById("R5") ~= nil and #ns.creditsDb.transactionLog == 2)

    -- ---- merge re-tagging on a replica -----------------------------------------
    setup()
    deliver("Officer2", wrap("T:" .. enc(merge("M1", now - 100, "MainA", "SrcX"))))
    deliver("Officer2", wrap("T:" .. enc(don("D1", now - 200, "SrcX")), "T:" .. enc(don("D2", now, "SrcX"))))
    check("Merge: an older row that arrives AFTER the merge row is re-tagged to the target", logById("D1").account == "MainA")
    check("Merge: a row newer than the merge keeps its account", logById("D2").account == "SrcX")
    check("Merge: the merge row keeps its target", logById("M1").account == "MainA")
    deliver("Officer2", wrap("T:" .. enc(merge("M2", now - 50, "MainB", "MainA"))))
    check("Merge: a chained merge carries earlier rows through (D1 -> MainA -> MainB)", logById("D1").account == "MainB")
    check("Merge: ...and re-tags the earlier merge row, as the merging client does", logById("M1").account == "MainB")
    check("Merge: ...but still not a newer row of the original source", logById("D2").account == "SrcX")

    -- ---- digests / reconciliation -----------------------------------------------
    local function theirs(rows, extra)
        local saved = ns.creditsDb.transactionLog
        ns.creditsDb.transactionLog = rows
        local dg = ns.CreditsSync_LogDigest()
        ns.creditsDb.transactionLog = saved
        local items = { "W:" .. (today - 90) .. "|" .. (today + 1) }
        local days = {}
        for day in pairs(dg) do days[#days + 1] = day end
        table.sort(days)
        for _, day in ipairs(days) do items[#items + 1] = ("G:%d|%d|%d"):format(day, dg[day].n, dg[day].h) end
        for _, x in ipairs(extra or {}) do items[#items + 1] = x end
        return wrap(unpackFn(items))
    end
    local rowA = don("A", now - 3 * DAY, "MainA")
    local rowB = don("B", now - 1 * DAY, "MainA")
    setup()
    ns.creditsDb.transactionLog = { rowA, rowB }
    deliver("Officer2", theirs({ rowA, rowB }))
    check("Digest: identical logs -> no reply", #payloadsTo("Officer2") == 0)
    deliver("Officer2", theirs({ rowA }))
    local reply = allTo("Officer2")
    check("Digest: the peer lacks a row -> we send the rows of the differing day only",
        reply:find("id=sB", 1, true) ~= nil and reply:find("id=sA", 1, true) == nil)
    check("Digest: ...plus our own window and digest so they can answer", reply:find(";W:", 1, true) ~= nil and reply:find(";G:", 1, true) ~= nil)
    outboxLog = {}
    local extraDay = ("G:%d|2|777"):format(today - 5)
    deliver("Officer2", theirs({ rowA, rowB }, { extraDay }))
    reply = allTo("Officer2")
    check("Digest: the peer has a day we lack -> we send only our digest (they will send the rows)",
        reply ~= "" and reply:find(";T:", 1, true) == nil and reply:find(";G:", 1, true) ~= nil)
    outboxLog = {}
    deliver("Officer2", theirs({}))
    reply = allTo("Officer2")
    check("Digest: an empty peer gets every row we hold", reply:find("id=sA", 1, true) ~= nil and reply:find("id=sB", 1, true) ~= nil)
    -- A peer that sends us rows we lack, in the same payload as its digest.
    setup()
    ns.creditsDb.transactionLog = { rowA }
    deliver("Officer2", theirs({ rowA, rowB }, { "T:" .. enc(rowB) }))
    check("Digest: rows in the same payload are applied before the comparison, so no reply is needed",
        logById("B") ~= nil and #payloadsTo("Officer2") == 0)
    -- Round cap: a mismatch that never resolves cannot loop forever.
    setup()
    ns.creditsDb.transactionLog = { rowA }
    deliver("Officer2", "LSYNCREQ|" .. fp() .. "|0")   -- (the cap is per peer and persists across setup())
    outboxLog = {}
    for _ = 1, 10 do deliver("Officer2", theirs({ rowA }, { extraDay })) end
    check("Digest: replies per peer are capped", #payloadsTo("Officer2") == 6)
    deliver("Officer2", "LSYNCREQ|" .. fp() .. "|0")
    outboxLog = {}
    deliver("Officer2", theirs({ rowA }, { extraDay }))
    check("Digest: a fresh LSYNCREQ from the peer resets the cap", #payloadsTo("Officer2") == 1)

    -- Our side of the conversation: login/appearance sends our digest.
    setup()
    ns.creditsDb.transactionLog = { rowA, don("OLD", now - 200 * DAY, "MainA") }
    outboxLog = {}
    ns.CreditsSync_OnLogin()
    local sent = allTo("Officer2")
    check("Login: our digest goes to an online officer with the window",
        sent:find(";W:" .. (today - 90) .. "|" .. (today + 1), 1, true) ~= nil)
    check("Login: ...with this day's row counted", sent:find(("G:%d|1|"):format(today - 3), 1, true) ~= nil)
    check("Login: ...and a row older than the window is not part of the digest", sent:find(("G:%d|"):format(today - 200), 1, true) == nil)

    -- Two clients converge: client X's log delivered to client Y as T rows.
    setup()
    local X = { don("X1", now - 2 * DAY, "MainA"), don("X2", now - 2 * DAY, "MainB"), merge("XM", now - DAY, "MainA", "MainB") }
    local items = {}
    for _, row in ipairs(X) do items[#items + 1] = "T:" .. enc(row) end
    deliver("Officer2", wrap(unpackFn(items)))
    local dY = ns.CreditsSync_LogDigest()
    ns.creditsDb.transactionLog = X
    local dX = ns.CreditsSync_LogDigest()
    local same = true
    for day, v in pairs(dX) do if not dY[day] or dY[day].n ~= v.n or dY[day].h ~= v.h then same = false end end
    check("Two clients: digests match once the rows have been exchanged", same)
end

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
-- CM4: donation logic (CreditsDonations.lua) - valuation, who is credited,
-- tier crossings, held credits + release, merge
--------------------------------------------------------------------------
local cm4 = {}
cm4.origItemPoints = ns.ITEM_POINTS
function cm4.said(sub)
    for _, l in ipairs(printLog) do
        if tostring(l):find(sub, 1, true) then return true end
    end
    return false
end
function cm4.setup()
    resetState()
    ns.ITEM_POINTS = {
        ["Test Sword"] = { points = 50, itemId = 1, category = "Weapon" },
        ["Test Herb"] = { points = 2, itemId = 2 },
    }
    inGuild = true
    guildRosterEntries = {
        { name = "GLeader", rankIndex = 0 },
        { name = "Officer1", rankIndex = 3 },
        { name = "Officer2", rankIndex = 3 },
        { name = "Donor1", rankIndex = 5 },
        { name = "Donor2", rankIndex = 5 },
        { name = "NewMember", rankIndex = 5 },
    }
    ns.UpdateGuildRosterCache()
    currentPlayerName = "Officer1"
    ns.db.editors = { "Officer1", "Officer2" }
    ns.CreditsSeedData = { MainA = { lifetimePoints = 2900 }, MainB = { lifetimePoints = 100 } }
    ns.CreditsAltRoster = { MainA = { "AltA1" } }
    ns.CreditsSeed_Import()
    ns.creditsArmedInbox = true
    _G.GRM = nil
    outboxLog, printLog = {}, {}
end
function cm4.sword(n) return { itemID = 1, name = "Test Sword", count = n or 1 } end
_G.GetRealmName = function() return "SkullRock" end

print("== Credits: CM4 valuation ==")
do
    cm4.setup()
    local e = ns.CreditsDon_Value({ sender = "X", items = { cm4.sword(2) } })
    check("Valuation: 2 x 50-point item = 100 rep", e.rep == 100)
    check("Valuation: Credit/Rep 1/100 turns 100 rep into 1 credit", e.credits == 1)
    check("Valuation: category comes from the item data", e.items[1].category == "Weapon")
    check("Valuation: the entry records the sender, a unique id and a timestamp",
        e.sender == "X" and type(e.id) == "string" and e.id ~= "" and type(e.ts) == "number")

    ns.db.itemPointsOverrides["Test Sword"] = { points = 80 }
    e = ns.CreditsDon_Value({ sender = "X", items = { cm4.sword(2) } })
    check("Valuation: a live override (tooltip's lookup) beats the baseline", e.rep == 160)
    check("Valuation: an override with no category keeps the baseline category", e.items[1].category == "Weapon")
    ns.db.itemPointsOverrides = {}

    e = ns.CreditsDon_Value({ sender = "X", items = { cm4.sword(1), cm4.sword(2) } })
    check("Valuation: the same item in two slots collapses into one line",
        #e.items == 1 and e.items[1].count == 3 and e.rep == 150)

    e = ns.CreditsDon_Value({ sender = "X", items = { { itemID = 9, name = "Mystery", count = 4 }, { itemID = 2, name = "Test Herb", count = 5 } } })
    check("Valuation: an unpriced item is worth 0 and flagged, priced ones still count",
        e.rep == 10 and e.items[1].unpriced == true and e.items[1].rep == 0)
    check("Valuation: an item without a category is Uncategorized", e.items[2].category == "Uncategorized")

    e = ns.CreditsDon_Value({ sender = "X", copper = 25000 })
    check("Valuation: 2.5 gold at 100 rep per gold = 250 rep", e.rep == 250 and e.gold == 2.5)
    check("Valuation: gold turns into credits too (2.5)", e.credits == 2.5)
    e = ns.CreditsDon_Value({ sender = "X", copper = 1234 })
    check("Valuation: fractional gold keeps its decimals (0.1234 gold = 12.34 rep)", math.abs(e.rep - 12.34) < 1e-9)

    ns.creditsDb.creditsPerRep = { x = 3, y = 200 }
    ns.creditsDb.repPerGold = { x = 7, y = 2 }
    e = ns.CreditsDon_Value({ sender = "X", copper = 20000, items = { cm4.sword(1) } })
    check("Valuation: Rep/Gold uses the officer's X/Y (7 Rep = 2 Gold: 2 gold = 7 rep)", math.abs(e.rep - (50 + 7)) < 1e-9)
    check("Valuation: Credit/Rep uses the officer's X/Y (3 Credits = 200 Rep)", math.abs(e.credits - 57 * 3 / 200) < 1e-9)
    check("Valuation: the entry records the rates it used",
        e.creditsPerRep.x == 3 and e.creditsPerRep.y == 200 and e.repPerGold.x == 7 and e.repPerGold.y == 2)
end

print("== Credits: CM4 crediting + tier/prestige crossings ==")
do
    cm4.setup()
    local rec = ns.creditsDb.ledger["MainA"]
    local res = ns.CreditsDon_Credit({ sender = "AltA1", items = { cm4.sword(3) } })
    check("Credit: a known alt is credited to its account", res.status == "credited" and res.account == rec)
    check("Credit: lifetimePoints rises by the rep (2900 + 150)", rec.lifetimePoints == 3050)
    check("Credit: crossing the Neutral cap moves to Friendly with the carry-over",
        rec.tier == "Friendly" and rec.prestige == 0 and rec.points == 50)
    check("Credit: credits and lifetimeCredits both rise by 1.5", rec.credits == 1.5 and rec.lifetimeCredits == 1.5)
    check("Credit: exactly one transaction-log entry per mail", #ns.creditsDb.transactionLog == 1)
    local log = ns.creditsDb.transactionLog[1]
    check("Credit: the log entry names the account, sender, receiver and totals",
        log.account == "MainA" and log.sender == "AltA1" and log.receiver == "Officer1" and log.rep == 150 and log.credits == 1.5)
    check("Credit: the log entry has tier before -> after",
        log.tierBefore == "Neutral" and log.tierAfter == "Friendly")
    check("Credit: the log entry lists items with itemID, name, count, rep and category",
        log.items[1].itemID == 1 and log.items[1].name == "Test Sword" and log.items[1].count == 3
        and log.items[1].rep == 150 and log.items[1].category == "Weapon")
    check("Credit: the log entry records the rates used", log.creditsPerRep.x == 1 and log.creditsPerRep.y == 100)
    check("Credit: one chat line per mail with rep, credits and progress",
        cm4.said("AltA1 (MainA): +150.00 rep, +1.50 credits (Friendly 50/6,000)"))
    check("Storage: valuation rounds to four decimals (0.2 x 6 = 1.2, no float noise)",
        (function()
            local v = ns.CreditsDon_Value({ sender = "X", items = {} })
            return ns.CreditsDon_Round4(0.2 * 6) == 1.2 and ns.CreditsDon_Round4(1/3) == 0.3333
                and ns.CreditsDon_Fmt(1234.5) == "1,234.50" and ns.CreditsDon_Fmt(0.09) == "0.09" and v.rep == 0
        end)())
    check("Credit: a tier-up line is printed", cm4.said("TIER UP") and cm4.said("Friendly"))
    check("Credit: lastDonationDate is stamped", rec.lastDonationDate ~= "" and rec.syncedAt ~= nil)

    -- Gold alone can cross a tier.
    cm4.setup()
    rec = ns.creditsDb.ledger["MainA"]
    ns.CreditsDon_Credit({ sender = "MainA", copper = 50000 }) -- 5 gold = 500 rep
    check("Credit: gold rep counts toward lifetimePoints and crosses the tier (2900 + 500)",
        rec.lifetimePoints == 3400 and rec.tier == "Friendly" and rec.points == 400)
    check("Credit: the log entry for gold has the gold amount and no items",
        ns.creditsDb.transactionLog[1].gold == 5 and #ns.creditsDb.transactionLog[1].items == 0)

    -- Exalted prestige loop.
    cm4.setup()
    rec = ns.creditsDb.ledger["MainA"]
    rec.lifetimePoints = 3000 + 6000 + 12000 + 21000 + 49950
    rec.tier, rec.prestige, rec.points = ns.Credits_TierStateForLifetime(rec.lifetimePoints)
    check("Prestige setup: Exalted at 49,950/50,000", rec.tier == "Exalted" and rec.prestige == 0 and rec.points == 49950)
    ns.CreditsDon_Credit({ sender = "MainA", items = { cm4.sword(2) } }) -- +100
    check("Credit: crossing the Exalted lap bumps prestige and keeps the carry-over",
        rec.tier == "Exalted" and rec.prestige == 1 and rec.points == 50)
    check("Credit: a prestige-up line is printed", cm4.said("PRESTIGE UP"))

    -- Several tiers in one big donation.
    cm4.setup()
    rec = ns.creditsDb.ledger["MainB"] -- 100 lifetime
    ns.CreditsDon_Credit({ sender = "MainB", copper = 2000000 }) -- 200 gold = 20,000 rep
    check("Credit: one donation can cross more than one tier (100 + 20,000 -> Honored)",
        rec.tier == "Honored" and rec.lifetimePoints == 20100 and rec.points == 20100 - 3000 - 6000)

    -- Only-unpriced mail: nothing credited, nothing created, one chat line.
    cm4.setup()
    local before = ns.creditsDb.ledger["MainA"].lifetimePoints
    res = ns.CreditsDon_Credit({ sender = "NewMember", items = { { itemID = 9, name = "Mystery", count = 1 } } })
    check("Unpriced only: status zero, no account created for the sender",
        res.status == "zero" and ns.creditsDb.ledger["NewMember"] == nil and #ns.creditsDb.transactionLog == 0)
    check("Unpriced only: the item is named in a chat line", cm4.said("Mystery") and cm4.said("no Bavin Points entry"))
    check("Unpriced only: other accounts untouched", ns.creditsDb.ledger["MainA"].lifetimePoints == before)
end

print("== Credits: CM4 who gets credited ==")
do
    -- Auto-create: guild member with no account and no GRM -> own main.
    cm4.setup()
    local res = ns.CreditsDon_Credit({ sender = "NewMember", items = { cm4.sword(1) } })
    local acct = ns.creditsDb.ledger["NewMember"]
    check("Resolve: a guild member with no account gets one (own main)",
        res.status == "credited" and acct and acct.mainToon == "NewMember" and acct.discord == "NewMember"
        and acct.lifetimePoints == 50 and #acct.alts == 0)
    check("Resolve: toonIndex knows the new account", ns.creditsDb.toonIndex["newmember"] == "NewMember")
    check("Resolve: the new account is synced (stamped)", acct.syncedAt ~= nil)

    -- Same-name remake / second donation lands on the same account.
    ns.CreditsDon_Credit({ sender = "NewMember", items = { cm4.sword(1) } })
    check("Resolve: a later donation from the same name goes to the same account (history kept)",
        acct.lifetimePoints == 100 and #ns.creditsDb.transactionLog == 2)
    ns.CreditsDon_Credit({ sender = "newmember-SkullRock", items = { cm4.sword(1) } })
    check("Resolve: a realm-qualified / differently-cased sender name resolves too", acct.lifetimePoints == 150)

    -- GRM: main already has an account -> sender linked as an alt.
    cm4.setup()
    _G.GRM = { GetPlayerMain = function(n) if n == "Donor1-SkullRock" then return "MainA-SkullRock" end end }
    res = ns.CreditsDon_Credit({ sender = "Donor1", items = { cm4.sword(1) } })
    local a = ns.creditsDb.ledger["MainA"]
    local linked = false
    for _, alt in ipairs(a.alts) do if alt == "Donor1" then linked = true end end
    check("Resolve (GRM): sender linked as an alt of GRM's main and credited there",
        res.status == "credited" and linked and a.lifetimePoints == 2950 and ns.creditsDb.toonIndex["donor1"] == "MainA")
    check("Resolve (GRM): no separate account was created for the alt", ns.creditsDb.ledger["Donor1"] == nil)

    -- GRM: main has NO account yet -> account created for the main, sender is its alt.
    cm4.setup()
    _G.GRM = { GetPlayerMain = function(n) if n == "Donor2-SkullRock" then return "BrandNewMain" end end }
    res = ns.CreditsDon_Credit({ sender = "Donor2", items = { cm4.sword(2) } })
    local nm = ns.creditsDb.ledger["BrandNewMain"]
    check("Resolve (GRM): an account is created for GRM's main (discord = main name), sender as its alt",
        res.status == "credited" and nm and nm.mainToon == "BrandNewMain" and nm.discord == "BrandNewMain"
        and nm.alts[1] == "Donor2" and nm.lifetimePoints == 100)
    check("Resolve (GRM): both names resolve to the new account",
        ns.creditsDb.toonIndex["brandnewmain"] == "BrandNewMain" and ns.creditsDb.toonIndex["donor2"] == "BrandNewMain")

    -- GRM names the sender itself -> own main.
    cm4.setup()
    _G.GRM = { GetPlayerMain = function(n) return "Donor1" end }
    ns.CreditsDon_Credit({ sender = "Donor1", items = { cm4.sword(1) } })
    check("Resolve (GRM): GRM naming the sender itself makes it its own main",
        ns.creditsDb.ledger["Donor1"] and ns.creditsDb.ledger["Donor1"].mainToon == "Donor1")
    -- GRM errors are survivable.
    cm4.setup()
    _G.GRM = { GetPlayerMain = function() error("boom") end }
    res = ns.CreditsDon_Credit({ sender = "Donor1", items = { cm4.sword(1) } })
    check("Resolve (GRM): a GRM error falls back to own main", res.status == "credited" and ns.creditsDb.ledger["Donor1"] ~= nil)
    _G.GRM = nil

    -- A sender who is not in the guild is held, not credited to anyone.
    cm4.setup()
    local ledgerCount = 0
    for _ in pairs(ns.creditsDb.ledger) do ledgerCount = ledgerCount + 1 end
    res = ns.CreditsDon_Credit({ sender = "Rando", items = { cm4.sword(2) } })
    local after = 0
    for _ in pairs(ns.creditsDb.ledger) do after = after + 1 end
    check("Resolve: a non-guild, unknown sender is held", res.status == "held")
    check("Resolve: holding creates no account and no log entry", after == ledgerCount and #ns.creditsDb.transactionLog == 0)
    check("Resolve: the held entry is stored under the sender", #ns.creditsDb.pendingCredits["rando"] == 1
        and ns.creditsDb.pendingCredits["rando"][1].rep == 100)
    local q = ns.creditsDb.dynamicReviewQueue[1]
    check("Resolve: the sender enters the Review Queue as unresolved_donor",
        q and q.name == "Rando" and q.issue == "unresolved_donor")
    check("Resolve: the Review Queue row says what is held", q and q.details:find("100", 1, true) ~= nil)
    check("Resolve: a 'Held' chat line is printed", cm4.said("Held 100.00 rep / 1.00 credits for Rando"))
    local hr, hc, hn = ns.CreditsDon_HeldTotals("Rando")
    check("HeldTotals reports rep/credits/count (case-insensitive)", hr == 100 and hc == 1 and hn == 1
        and select(1, ns.CreditsDon_HeldTotals("rANDO")) == 100)
    ns.CreditsDon_Credit({ sender = "Rando", copper = 10000 })
    hr, hc, hn = ns.CreditsDon_HeldTotals("Rando")
    check("A second donation from the same held sender adds to the held totals", hr == 200 and hn == 2)
    local queued = 0
    for _, row in ipairs(ns.creditsDb.dynamicReviewQueue) do if row.name == "Rando" then queued = queued + 1 end end
    check("...and the Review Queue still has one row for them", queued == 1)
end

print("== Credits: CM4 held credits release ==")
do
    -- Local link releases (recipient's armed client), original timestamp kept.
    cm4.setup()
    wallClock = 1700000100
    ns.CreditsDon_Credit({ sender = "Rando", items = { cm4.sword(2) } })
    ns.CreditsDon_Credit({ sender = "Rando", copper = 10000 })
    local origTs = ns.creditsDb.pendingCredits["rando"][1].ts
    wallClock = 1700009999
    local rec = ns.creditsDb.ledger["MainA"]
    local lifeBefore = rec.lifetimePoints
    printLog = {}
    check("Release: linking the held name succeeds", ns.Credits_LinkAlt("Rando", "MainA") == true)
    check("Release: both held entries were applied (100 + 100 rep)", rec.lifetimePoints == lifeBefore + 200)
    check("Release: nothing is held for the name any more", ns.creditsDb.pendingCredits["rando"] == nil)
    check("Release: the Review Queue row is gone", #ns.creditsDb.dynamicReviewQueue == 0)
    local logs = ns.creditsDb.transactionLog
    check("Release: each released entry is logged as released from pending, to the right account",
        #logs == 2 and logs[1].released == true and logs[1].account == "MainA" and logs[2].released == true)
    check("Release: the log keeps the ORIGINAL timestamp", logs[1].ts == origTs and logs[1].releasedAt >= origTs)
    check("Release: the chat line says it was released", cm4.said("released from pending"))
    check("Release: tombstones were recorded for the released ids",
        ns.creditsDb.pendingReleased[logs[1].id] ~= nil and ns.creditsDb.pendingReleased[logs[2].id] ~= nil)
    wallClock = 1700000000

    -- Not the recipient's client: link does NOT release.
    cm4.setup()
    ns.CreditsDon_Credit({ sender = "Rando", items = { cm4.sword(2) } })
    ns.creditsArmedInbox = false
    rec = ns.creditsDb.ledger["MainA"]
    lifeBefore = rec.lifetimePoints
    ns.Credits_LinkAlt("Rando", "MainA")
    check("Release: an unarmed client never releases (only the mail recipient does)",
        rec.lifetimePoints == lifeBefore and ns.creditsDb.pendingCredits["rando"] ~= nil)
    ns.creditsArmedInbox = true
    check("Release: ReleasePending on the armed client then applies it", ns.Credits_ReleasePending() == 1 and rec.lifetimePoints == lifeBefore + 100)

    -- New main releases onto the new account.
    cm4.setup()
    ns.CreditsDon_Credit({ sender = "Rando", items = { cm4.sword(4) } })
    check("Release: Set as New Main succeeds", ns.Credits_SetAsNewMain("Rando", 0, "") == true)
    local rnd = ns.creditsDb.ledger["Rando"]
    check("Release: the new main account receives the held rep", rnd and rnd.lifetimePoints == 200 and rnd.credits == 2)
    check("Release: held store is empty", next(ns.creditsDb.pendingCredits) == nil)

    -- Login / roster: a held sender who has since joined the guild resolves.
    cm4.setup()
    ns.CreditsDon_Credit({ sender = "Latecomer", items = { cm4.sword(2) } })
    check("Release (roster): still held while not in the guild", ns.Credits_ReleasePending() == 0)
    guildRosterEntries[#guildRosterEntries + 1] = { name = "Latecomer", rankIndex = 5 }
    ns.UpdateGuildRosterCache()
    check("Release (roster): once in the guild roster, the next release pass creates the account and applies",
        ns.Credits_ReleasePending() == 1 and ns.creditsDb.ledger["Latecomer"] and ns.creditsDb.ledger["Latecomer"].lifetimePoints == 100)

    -- Reset wipes held credits and tombstones.
    cm4.setup()
    ns.CreditsDon_Credit({ sender = "Rando", items = { cm4.sword(1) } })
    ns.creditsDb.pendingReleased["x"] = { ts = 1 }
    ns.creditsDb.ledgerTombstones["Y"] = { ts = 1 }
    check("Reset: Credits_ResetTestData succeeds", ns.Credits_ResetTestData() == true)
    check("Reset: held credits and tombstones are wiped",
        next(ns.creditsDb.pendingCredits) == nil and next(ns.creditsDb.pendingReleased) == nil
        and next(ns.creditsDb.ledgerTombstones) == nil)
end

print("== Credits: archived-donor carryover ==")
do
    local origArchived = ns.CreditsArchivedDonors
    local function carryRows(account)
        local out = {}
        for _, e in ipairs(ns.creditsDb.transactionLog) do
            if e.kind == "carryover" and (account == nil or e.account == account) then out[#out + 1] = e end
        end
        return out
    end
    local function setupArchived()
        cm4.setup()
        ns.CreditsArchivedDonors = {
            archiveman = { "2026-03-31", 561, 5612 },
            donor1 = { "2026-01-01", 10, 100 },
            nopoints = { "2026-01-01", 0, 0 },
        }
    end

    -- Held, then linked: the Review Queue row shows the history, linking carries it over once.
    setupArchived()
    ns.CreditsDon_Credit({ sender = "ArchiveMan", items = { cm4.sword(2) } }) -- 100 rep, not in guild: held
    local q = ns.creditsDb.dynamicReviewQueue[1]
    check("Carryover: the held row says what was previously donated",
        q and q.details:find("previously donated 561 gold (5,612 rep), last 2026-03-31", 1, true) ~= nil)
    check("Carryover: ...but its rawGoldAmount stays 0 (New Main must not count the history twice)",
        q and q.rawGoldAmount == 0)
    local B = ns.creditsDb.ledger["MainB"]
    local lifeBefore, creditsBefore = B.lifetimePoints, B.credits
    printLog = {}
    check("Carryover: linking the held name succeeds", ns.Credits_LinkAlt("ArchiveMan", "MainB") == true)
    check("Carryover: the old history (5,612) plus the held donation (100) are on the account",
        B.lifetimePoints == lifeBefore + 5612 + 100)
    check("Carryover: the carryover adds 0 credits (only the donation's 1 credit)", B.credits == creditsBefore + 1)
    local rows = carryRows("MainB")
    check("Carryover: exactly one carryover row, fixed id, 0 credits",
        #rows == 1 and rows[1].id == "carry-archiveman" and rows[1].credits == 0 and rows[1].rep == 5612
        and rows[1].sender == "ArchiveMan")
    check("Carryover: the carryover row comes before the released donation row",
        ns.creditsDb.transactionLog[1].kind == "carryover" and ns.creditsDb.transactionLog[2].released == true)
    check("Carryover: tier before/after recorded (Neutral -> Friendly)",
        rows[1].tierBefore == "Neutral" and rows[1].tierAfter == "Friendly")
    check("Carryover: a chat line and a tier-up line are printed",
        cm4.said("carried over from earlier donations") and cm4.said("TIER UP"))

    -- A second donation from the same name does not repeat it.
    local logCount = #ns.creditsDb.transactionLog
    lifeBefore = B.lifetimePoints
    ns.CreditsDon_Credit({ sender = "ArchiveMan", items = { cm4.sword(2) } })
    check("Carryover: a second donation adds only its own rep", B.lifetimePoints == lifeBefore + 100)
    check("Carryover: ...and no second carryover row", #carryRows() == 1 and #ns.creditsDb.transactionLog == logCount + 1)

    -- Audit Log display row.
    local dr = ns.CreditsLog_Row(rows[1])
    check("Carryover: the Audit Log labels the row 'Carryover'", dr.kind == "carryover" and dr.kindLabel == "Carryover")
    check("Carryover: ...and shows its rep with 0 credits", dr.rep == 5612 and dr.credits == 0)

    -- Direct credit (guild member, no account yet): carryover first, then the donation.
    setupArchived()
    local res = ns.CreditsDon_Credit({ sender = "Donor1", items = { cm4.sword(1) } })
    local d1 = res.account
    check("Carryover: a direct-credit archived donor gets 100 + 50 rep and only the donation's credits",
        res.status == "credited" and d1.lifetimePoints == 150 and d1.credits == 0.5)
    check("Carryover: ...with one carryover row on that account", #carryRows(d1.discordName) == 1)

    -- Non-archived sender and a zero-value donation are unaffected.
    setupArchived()
    res = ns.CreditsDon_Credit({ sender = "Donor2", items = { cm4.sword(1) } })
    check("Carryover: a non-archived sender gets no carryover", res.account.lifetimePoints == 50 and #carryRows() == 0)
    res = ns.CreditsDon_Credit({ sender = "Donor1", items = { { itemID = 9, name = "Mystery", count = 1 } } })
    check("Carryover: a donation worth nothing (only unpriced items) triggers no carryover",
        res.status == "zero" and #carryRows() == 0)
    ns.CreditsDon_Credit({ sender = "NoPoints", items = { cm4.sword(1) } }) -- not in guild, not archived with points
    check("Carryover: an archived entry with 0 points is ignored", #carryRows() == 0)

    -- A replicated carryover row (another officer applied it) blocks a second application.
    setupArchived()
    table.insert(ns.creditsDb.transactionLog, { id = "carry-donor1", ts = 1, kind = "carryover", account = "Donor1", rep = 100, credits = 0 })
    res = ns.CreditsDon_Credit({ sender = "Donor1", items = { cm4.sword(1) } })
    check("Carryover: a log row with the same id (replicated) prevents a repeat", res.account.lifetimePoints == 50)

    -- "Start from scratch" clears the log, so the carryover can apply again.
    setupArchived()
    ns.CreditsDon_Credit({ sender = "Donor1", items = { cm4.sword(1) } })
    check("Carryover: reset setup - applied once", #carryRows() == 1)
    check("Carryover: Credits_ResetTestData succeeds", ns.Credits_ResetTestData() == true)
    res = ns.CreditsDon_Credit({ sender = "Donor1", items = { cm4.sword(1) } })
    check("Carryover: after a reset the history applies again to the rebuilt account",
        res.account.lifetimePoints == 150 and #carryRows() == 1)

    ns.CreditsArchivedDonors = origArchived
    check("Carryover: the shipped ArchivedDonors table loads (real data present)", (function()
        local n = 0
        for _ in pairs(ns.CreditsArchivedDonors or {}) do n = n + 1 end
        return n > 1000
    end)())
end

print("== Credits: CM4 account merge ==")
do
    cm4.setup()
    local A, B = ns.creditsDb.ledger["MainA"], ns.creditsDb.ledger["MainB"]
    A.alts = { "AltA1" }
    A.credits, A.lifetimeCredits, A.lastDonationDate = 5, 8, "2026-09-01"
    B.credits, B.lifetimeCredits, B.lastDonationDate = 2, 2, "2026-10-01"
    ns.Credits_RebuildToonIndex()
    ns.CreditsDon_Credit({ sender = "AltA1", items = { cm4.sword(1) } }) -- a log entry on A
    local lifeA, lifeB = A.lifetimePoints, B.lifetimePoints
    local credA, credB = A.credits, B.credits
    check("Merge: refused for a non-officer", (function()
        currentPlayerName = "Donor1"
        local ok = ns.Credits_MergeAccounts("MainA", "MainB")
        currentPlayerName = "Officer1"
        return ok == false and ns.creditsDb.ledger["MainA"] ~= nil
    end)())
    check("Merge: an account cannot merge into itself", ns.Credits_MergeAccounts("MainA", "MainA") == false)
    check("Merge: an unknown account is refused", ns.Credits_MergeAccounts("Nope", "MainB") == false)
    outboxLog = {}
    local ok = ns.Credits_MergeAccounts("MainA", "MainB")
    check("Merge: succeeds for an officer", ok == true)
    check("Merge: the source account is deleted", ns.creditsDb.ledger["MainA"] == nil)
    check("Merge: the target gets the source's main and alts",
        (function()
            local have = {}
            for _, n in ipairs(B.alts) do have[n] = true end
            return have["MainA"] and have["AltA1"]
        end)())
    check("Merge: toonIndex points every moved name at the target",
        ns.creditsDb.toonIndex["maina"] == "MainB" and ns.creditsDb.toonIndex["alta1"] == "MainB"
        and ns.creditsDb.toonIndex["mainb"] == "MainB")
    check("Merge: lifetimePoints, credits and lifetimeCredits are summed",
        B.lifetimePoints == lifeA + lifeB and B.credits == credA + credB and B.lifetimeCredits == 8 + 0.5 + 2)
    check("Merge: tier/prestige/points recompute from the summed lifetime",
        (function()
            local t, p, pts = ns.Credits_TierStateForLifetime(B.lifetimePoints)
            return B.tier == t and B.prestige == p and B.points == pts and t == "Friendly"
        end)())
    check("Merge: the later lastDonationDate wins", B.lastDonationDate == "2026-10-01" or B.lastDonationDate > "2026-09-01")
    local retagged = false
    for _, e in ipairs(ns.creditsDb.transactionLog) do
        if e.sender == "AltA1" and e.account == "MainB" then retagged = true end
    end
    check("Merge: the source's log entries are re-tagged to the target", retagged)
    local last = ns.creditsDb.transactionLog[#ns.creditsDb.transactionLog]
    check("Merge: a merge entry is logged", last.kind == "merge" and last.source == "MainA" and last.account == "MainB")
    check("Merge: a tombstone is recorded for the deleted account", ns.creditsDb.ledgerTombstones["MainA"] ~= nil)
    check("Merge: a later donation from the moved alt credits the target",
        (function()
            local r = ns.CreditsDon_Credit({ sender = "AltA1", items = { cm4.sword(1) } })
            return r.account == B
        end)())
end

print("== Credits: CM4 sync (max-merge, merge tombstones, held-credit replication) ==")
do
    local PFX = "DHBavinCreditsV2"
    local function deliver(from, text) ns.Credits_OnAddonMessage(PFX, text, "WHISPER", from) end
    local function payloadTo(target)
        local parts = {}
        for _, e in ipairs(outboxLog) do
            if e.target == target and e.channel == "WHISPER" then
                local id, i, n, chunk = e.text:match("^LSYNCDATA|(%x+)|(%d+)/(%d+)|(.*)$")
                if id then parts[tonumber(i)] = chunk end
            end
        end
        return table.concat(parts)
    end
    local function msgFor(...)
        return "LSYNCDATA|abc1|1/1|F:" .. ns.CreditsSync_Fingerprint() .. ";" .. table.concat({ ... }, ";")
    end
    local function recText(rec) return "R:" .. ns.CreditsSync_EncodeRecord(rec) end
    local function rec(over)
        local r = { discordName = "MainA", mainToon = "MainA", alts = {}, points = 0, credits = 0, tier = "Neutral",
            prestige = 0, lifetimePoints = 0, lastDonationDate = "", lastUpdated = 5, syncedAt = 1000, lifetimeCredits = 0 }
        for k, v in pairs(over or {}) do r[k] = v end
        return r
    end

    -- max() for lifetime fields.
    cm4.setup()
    ns.creditsDb.ledger["MainA"] = rec({ lifetimePoints = 5000, tier = "Friendly", points = 2000, credits = 10, lifetimeCredits = 50, syncedAt = 1000 })
    deliver("Officer2", msgFor(recText(rec({ lifetimePoints = 4000, tier = "Friendly", points = 1000, credits = 3, lifetimeCredits = 20, syncedAt = 2000, alts = { "NewAlt" } }))))
    local r = ns.creditsDb.ledger["MainA"]
    check("Max-merge: a newer record still applies (alts/credits balance are last-writer-wins)",
        r.alts[1] == "NewAlt" and r.credits == 3 and r.syncedAt == 2000)
    check("Max-merge: but it cannot LOWER lifetimePoints or lifetimeCredits", r.lifetimePoints == 5000 and r.lifetimeCredits == 50)
    check("Max-merge: tier/points follow the kept lifetimePoints", r.tier == "Friendly" and r.points == 2000)
    -- an older record with HIGHER lifetime raises ours
    deliver("Officer2", msgFor(recText(rec({ lifetimePoints = 9500, tier = "Honored", points = 500, credits = 30, lifetimeCredits = 70, syncedAt = 1500 }))))
    r = ns.creditsDb.ledger["MainA"]
    check("Max-merge: a stale record with higher lifetime values raises ours without touching the rest",
        r.lifetimePoints == 9500 and r.lifetimeCredits == 70 and r.syncedAt == 2000 and r.credits == 3 and r.alts[1] == "NewAlt")
    check("Max-merge: tier recomputed from the raised lifetime (9,500 = Honored 500)", r.tier == "Honored" and r.points == 500)

    -- merge tombstone
    cm4.setup()
    ns.creditsDb.ledger["Gone"] = rec({ discordName = "Gone", mainToon = "Gone", syncedAt = 1000 })
    ns.Credits_RebuildToonIndex()
    deliver("Officer2", msgFor("D:Gone|2000"))
    check("Tombstone: a D item deletes the account", ns.creditsDb.ledger["Gone"] == nil and ns.creditsDb.toonIndex["gone"] == nil)
    check("Tombstone: it is remembered", ns.creditsDb.ledgerTombstones["Gone"].ts == 2000)
    deliver("Officer2", msgFor(recText(rec({ discordName = "Gone", mainToon = "Gone", syncedAt = 1500 }))))
    check("Tombstone: an older copy of the deleted account does not resurrect it", ns.creditsDb.ledger["Gone"] == nil)
    deliver("Officer2", msgFor(recText(rec({ discordName = "Gone", mainToon = "Gone", syncedAt = 2000 }))))
    check("Tombstone: an equal-stamp copy does not resurrect it either", ns.creditsDb.ledger["Gone"] == nil)
    deliver("Officer2", msgFor(recText(rec({ discordName = "Gone", mainToon = "Gone", syncedAt = 3000 }))))
    check("Tombstone: a genuinely newer record (re-created account) is accepted", ns.creditsDb.ledger["Gone"] ~= nil)
    deliver("Officer2", msgFor("D:Gone|1000"))
    check("Tombstone: an older tombstone does not delete the re-created account", ns.creditsDb.ledger["Gone"] ~= nil)

    -- Merge replicates: payload carries D + target record.
    cm4.setup()
    outboxLog = {}
    ns.Credits_MergeAccounts("MainA", "MainB")
    local pay = payloadTo("Officer2")
    check("Merge sync: the payload carries the tombstone for the deleted source", pay:find("D:MainA|", 1, true) ~= nil)
    check("Merge sync: ...and the merged target record", pay:find("R:MainB|", 1, true) ~= nil)

    -- held-entry codec + replication
    cm4.setup()
    local e = { id = "ab-1-2", sender = "We|ird;Na,me", ts = 1700000123, receiver = "Rec;v", gold = 2.5, rep = 350.25, credits = 3.5025,
        items = { { itemID = 1, name = "Sw,or~d|x", count = 2, rep = 100, category = "Wea;pon" }, { itemID = 5, name = "Herb", count = 1, rep = 2, category = "Uncategorized" } },
        creditsPerRep = { x = 1, y = 100 }, repPerGold = { x = 100, y = 1 }, syncedAt = 4242 }
    local enc = ns.CreditsSync_EncodePending(e)
    check("Pending codec: no raw ';' in the encoded entry", not enc:find(";", 1, true))
    local d = ns.CreditsSync_DecodePending(enc)
    check("Pending codec: round-trips sender/receiver/numbers with hostile characters",
        d and d.sender == e.sender and d.receiver == e.receiver and d.gold == 2.5 and d.rep == 350.25 and d.syncedAt == 4242
        and d.creditsPerRep.y == 100 and d.repPerGold.x == 100)
    check("Pending codec: round-trips items", d and #d.items == 2 and d.items[1].name == "Sw,or~d|x" and d.items[1].count == 2
        and d.items[1].category == "Wea;pon" and d.items[2].itemID == 5)
    check("Pending codec: rejects too few fields", ns.CreditsSync_DecodePending("a|b|c") == nil)
    check("Pending codec: rejects a negative rep", ns.CreditsSync_DecodePending((enc:gsub("|350.25|", "|-1|"))) == nil)

    cm4.setup()
    outboxLog = {}
    ns.CreditsDon_Credit({ sender = "Rando", items = { cm4.sword(2) } })
    pay = payloadTo("Officer2")
    check("Held sync: the payload carries the held entry", pay:find("P:", 1, true) ~= nil)
    check("Held sync: ...and the Review Queue add with its issue type", pay:find("Q:Rando|1|", 1, true) ~= nil and pay:find("|unresolved_donor", 1, true) ~= nil)
    local heldId = ns.creditsDb.pendingCredits["rando"][1].id
    outboxLog = {}
    ns.Credits_LinkAlt("Rando", "MainA")
    pay = payloadTo("Officer2")
    check("Release sync: the payload carries the released tombstone", pay:find("X:" .. heldId:gsub("%-", "%%-"), 1) ~= nil)
    check("Release sync: ...and the updated account", pay:find("R:MainA|", 1, true) ~= nil)

    -- officer (non-recipient) receives held entry, then the release.
    cm4.setup()
    ns.creditsArmedInbox = false
    local pe = { id = "zz-1-1", sender = "Rando", ts = 1700000123, receiver = "Bavin", gold = 0, rep = 100, credits = 1,
        items = { { itemID = 1, name = "Test Sword", count = 2, rep = 100, category = "Weapon" } },
        creditsPerRep = { x = 1, y = 100 }, repPerGold = { x = 100, y = 1 }, syncedAt = 3000 }
    local pText = "P:" .. ns.CreditsSync_EncodePending(pe)
    deliver("Officer2", msgFor(pText, "Q:Rando|1|3000|unresolved_donor"))
    check("Held sync (receive): an officer stores the entry", ns.creditsDb.pendingCredits["rando"] and #ns.creditsDb.pendingCredits["rando"] == 1)
    check("Held sync (receive): the Review Queue row arrives with its issue",
        ns.creditsDb.dynamicReviewQueue[1] and ns.creditsDb.dynamicReviewQueue[1].issue == "unresolved_donor")
    local hr = ns.CreditsDon_HeldTotals("Rando")
    check("Held sync (receive): held totals visible to the officer", hr == 100)
    deliver("Officer2", msgFor(pText))
    check("Held sync (receive): the same entry twice is stored once", #ns.creditsDb.pendingCredits["rando"] == 1)
    check("Held sync (receive): an unarmed officer never applies it to the ledger",
        ns.creditsDb.ledger["MainA"].lifetimePoints == 2900)
    deliver("Officer2", msgFor("X:zz-1-1|4000", "Q:Rando|0|4000|removed_alt"))
    check("Release sync (receive): the tombstone removes the officer's copy", ns.creditsDb.pendingCredits["rando"] == nil)
    deliver("Officer2", msgFor(pText))
    check("Release sync (receive): a late copy of a released entry is ignored", ns.creditsDb.pendingCredits["rando"] == nil)

    -- A link arriving by sync releases on the armed recipient.
    cm4.setup()
    ns.CreditsDon_Credit({ sender = "Rando", items = { cm4.sword(2) } })
    local life0 = ns.creditsDb.ledger["MainA"].lifetimePoints
    local linked = rec({ alts = { "AltA1", "Rando" }, lifetimePoints = life0, tier = "Neutral", points = life0, syncedAt = 5000 })
    deliver("Officer2", msgFor(recText(linked), "Q:Rando|0|5000|removed_alt"))
    check("Release (sync link): the recipient releases when a link for the held sender arrives",
        ns.creditsDb.pendingCredits["rando"] == nil and ns.creditsDb.ledger["MainA"].lifetimePoints == life0 + 100)
end

--------------------------------------------------------------------------
-- CM4: inbox hook (CreditsInbox.lua) - checkbox defaults, diff-based
-- crediting of what was actually taken, Wall 4 install gating
--------------------------------------------------------------------------
print("== Credits: CM4 inbox hook ==")
do
    local inbox, mailCounter = {}, 0
    local mockNow, timers = 1000, {}
    local savedGetTime = _G.GetTime
    _G.GetTime = function() return mockNow end
    _G.C_Timer = { After = function(d, fn) timers[#timers + 1] = { at = mockNow + d, fn = fn } end }
    local function advance(dt)
        mockNow = mockNow + dt
        local due, rest = {}, {}
        for _, t in ipairs(timers) do
            if t.at <= mockNow then due[#due + 1] = t else rest[#rest + 1] = t end
        end
        timers = rest
        for _, t in ipairs(due) do t.fn() end
    end

    -- Mock of the Classic Era mail API, shaped exactly like the 2026-10-04 probe found it.
    _G.GetInboxNumItems = function() return #inbox, #inbox end
    _G.GetInboxHeaderInfo = function(i)
        local m = inbox[i]
        if not m then return end
        local n = 0
        for _ in pairs(m.items) do n = n + 1 end
        return nil, nil, m.sender, m.subject, m.money, m.cod, m.daysLeft, (n > 0) and n or nil,
            false, m.returned, false, true, m.gm
    end
    _G.GetInboxItem = function(i, j)
        local m = inbox[i]
        local it = m and m.items[j]
        if not it then return nil end
        return it.name, it.itemID, "tex", it.count, 1, true
    end
    local function mail(sender, subject, items, money, extra)
        mailCounter = mailCounter + 1
        local m = { sender = sender, subject = subject or "Hi", items = items or {}, money = money or 0, cod = 0,
            daysLeft = 20 - mailCounter * 0.0013, returned = false, gm = false }
        for k, v in pairs(extra or {}) do m[k] = v end
        inbox[#inbox + 1] = m
        return m
    end
    local function item(id, name, count) return { itemID = id, name = name, count = count or 1 } end
    local function fresh()
        cm4.setup()
        ns.CreditsInbox_ResetForTests()
        inbox, timers = {}, {}
        mockNow = 1000
        ns.CreditsInbox_OnMailShow()
    end
    local function update() ns.CreditsInbox_OnInboxUpdate() end
    -- What the client does for a single-item take: hook (after the call, before
    -- the inbox changes), then the slot disappears, then MAIL_INBOX_UPDATE.
    local function takeItem(i, j)
        ns.CreditsInbox_OnTake("item", i, j)
        inbox[i].items[j] = nil
    end
    local function logCount() return #ns.creditsDb.transactionLog end

    -- ---- default checkbox state ------------------------------------------
    fresh()
    mail("MainA", "Donation", { item(1, "Test Sword", 2) })                    -- 1 player
    mail("Auction House", "Auction successful", {}, 50000)                      -- 2 non-player
    mail("MainA", "Returned", { item(1, "Test Sword", 1) }, 0, { returned = true }) -- 3 returned
    mail("MainA", "GM", { item(1, "Test Sword", 1) }, 0, { gm = true })         -- 4 GM
    mail("MainA", "Pay me", { item(1, "Test Sword", 1) }, 0, { cod = 5000 })    -- 5 COD
    mail(nil, "Mystery", { item(1, "Test Sword", 1) })                          -- 6 no sender
    check("Checkbox default: a player sender's mail is CHECKED", ns.CreditsInbox_IsChecked(1) == true)
    check("Checkbox default: Auction House (space in sender) is UNCHECKED", ns.CreditsInbox_IsChecked(2) == false)
    check("Checkbox default: returned mail is UNCHECKED", ns.CreditsInbox_IsChecked(3) == false)
    check("Checkbox default: GM mail is UNCHECKED", ns.CreditsInbox_IsChecked(4) == false)
    check("Checkbox default: COD mail is UNCHECKED", ns.CreditsInbox_IsChecked(5) == false)
    check("Checkbox default: a mail with no sender is UNCHECKED", ns.CreditsInbox_IsChecked(6) == false)
    check("Checkbox: COD can never be checked", ns.CreditsInbox_SetChecked(5, true) == false and ns.CreditsInbox_IsChecked(5) == false)

    -- ---- sticky in-mail checkbox -------------------------------------------
    mail("MainB", "Second donation", { item(1, "Test Sword", 1) })              -- 7 normal
    mail("MainC", "Third donation", { item(1, "Test Sword", 1) })               -- 8 normal
    ns.CreditsInbox_SetChecked(1, false)
    check("Sticky: unchecking one normal mail clears the remembered setting",
        ns.CreditsInbox_GetSticky() == false and ns.CreditsInbox_IsChecked(1) == false)
    check("Sticky: the next normal mail inherits the unchecked setting",
        ns.CreditsInbox_IsChecked(7) == false and ns.CreditsInbox_IsChecked(8) == false)
    check("Sticky: special mail is still shown unchecked and re-tickable without touching the setting",
        ns.CreditsInbox_SetChecked(2, true) == true and ns.CreditsInbox_IsChecked(2) == true
        and ns.CreditsInbox_GetSticky() == false and ns.CreditsInbox_IsChecked(3) == false)
    ns.CreditsInbox_SetChecked(1, true)
    check("Sticky: re-checking a normal mail carries to the next normal mail",
        ns.CreditsInbox_IsChecked(7) == true and ns.CreditsInbox_IsChecked(8) == true)
    ns.CreditsInbox_SetChecked(3, true)  -- returned mail ticked
    check("Sticky: unchecking a special mail never changes the remembered setting",
        (ns.CreditsInbox_SetChecked(3, false) == true) and ns.CreditsInbox_GetSticky() == true
        and ns.CreditsInbox_IsChecked(7) == true)
    ns.CreditsInbox_SetChecked(1, false)
    ns.CreditsInbox_OnMailShow()
    check("Sticky: opening the mailbox again resets the setting to CHECKED and clears special overrides",
        ns.CreditsInbox_GetSticky() == true and ns.CreditsInbox_IsChecked(7) == true
        and ns.CreditsInbox_IsChecked(2) == false)
    -- an unopened take (Open-All style) follows the remembered setting
    fresh()
    mail("MainA", "Donation", { item(1, "Test Sword", 2) })
    mail("MainB", "Other", { item(1, "Test Sword", 1) })
    ns.CreditsInbox_SetChecked(2, false)
    takeItem(1, 1)
    update()
    advance(3)
    check("Sticky: a take from a mail that was never opened uses the remembered (unchecked) setting",
        logCount() == 0)
    ns.CreditsInbox_SetChecked(2, true)
    mail("MainA", "Later", { item(1, "Test Sword", 1) })
    takeItem(3, 1)
    update()
    advance(3)
    check("Sticky: ...and the checked setting credits it", logCount() == 1)
    fresh()
    mail("MainA", "Donation", { item(1, "Test Sword", 2) })

    -- ---- one entry per mail, however slowly the items are taken ------------
    fresh()
    mail("MainA", "Big donation", { item(1, "Test Sword", 1), item(1, "Test Sword", 2), item(2, "Test Herb", 5) })
    mail("MainB", "Other", { item(1, "Test Sword", 1) })
    _G.InboxFrame = { openMailID = 1 }
    ns.CreditsInbox_RefreshOpenMail()
    takeItem(1, 1)
    update()
    advance(30)
    check("One entry per mail: a slow first take is NOT credited while the mail is open", logCount() == 0)
    takeItem(1, 2)
    update()
    advance(30)
    check("One entry per mail: nor the second slow take", logCount() == 0)
    _G.InboxFrame.openMailID = 2           -- the player opens a different mail
    ns.CreditsInbox_RefreshOpenMail()
    check("One entry per mail: opening another mail credits the first as ONE entry",
        logCount() == 1 and #ns.creditsDb.transactionLog[1].items == 1 and ns.creditsDb.transactionLog[1].rep == 150)
    fresh()
    mail("MainA", "Big donation", { item(1, "Test Sword", 1), item(2, "Test Herb", 5) })
    _G.InboxFrame = { openMailID = 1 }
    ns.CreditsInbox_RefreshOpenMail()
    takeItem(1, 1)
    update()
    advance(30)
    _G.InboxFrame.openMailID = nil         -- the player closes the open mail
    ns.CreditsInbox_RefreshOpenMail()
    check("One entry per mail: closing the open mail credits it", logCount() == 1)
    fresh()
    mail("MainA", "Two things", { item(1, "Test Sword", 1), item(2, "Test Herb", 5) })
    _G.InboxFrame = { openMailID = 1 }
    ns.CreditsInbox_RefreshOpenMail()
    takeItem(1, 1)
    update()
    advance(10)
    takeItem(1, 2)                          -- slowly takes the last item: mail is emptied
    update()
    advance(3)
    check("One entry per mail: emptying the open mail credits it once (both items)",
        logCount() == 1 and #ns.creditsDb.transactionLog[1].items == 2)
    _G.InboxFrame = nil
    fresh()

    -- ---- one item taken, confirmed by the next update ----------------------
    fresh()
    mail("MainA", "Donation", { item(1, "Test Sword", 2), item(2, "Test Herb", 5) })
    takeItem(1, 1)
    check("Take: nothing is credited before the inbox confirms", logCount() == 0)
    update()
    advance(3)
    check("Take: confirmed by the update, credited as one entry (2 swords = 100 rep)",
        logCount() == 1 and ns.creditsDb.transactionLog[1].rep == 100 and ns.creditsDb.ledger["MainA"].lifetimePoints == 3000)
    check("Take: only the item taken was credited (the herb still in the mail is not)",
        #ns.creditsDb.transactionLog[1].items == 1)
    -- taking it again (the slot is empty now) credits nothing
    ns.CreditsInbox_OnTake("item", 1, 1)
    update()
    advance(3)
    check("Take: re-taking an already-emptied slot credits nothing", logCount() == 1)

    -- ---- bags full: slot unchanged => nothing credited; retry credits once ----
    fresh()
    mail("MainA", "Donation", { item(1, "Test Sword", 2) })
    ns.CreditsInbox_OnTake("item", 1, 1)         -- hook fires, but bags are full: slot stays
    update()
    check("Bags full: the slot is still there so nothing is credited", logCount() == 0)
    ns.CreditsInbox_OnMailFailed(1)              -- MAIL_FAILED(itemID)
    update()
    advance(3)
    check("Bags full: nothing credited after MAIL_FAILED either", logCount() == 0)
    takeItem(1, 1)                               -- player makes room and retries
    update()
    advance(3)
    check("Bags full: the successful retry is credited exactly once", logCount() == 1 and ns.creditsDb.transactionLog[1].rep == 100)

    -- retry WITHOUT a MAIL_FAILED in between must not double count
    fresh()
    mail("MainA", "Donation", { item(1, "Test Sword", 2) })
    ns.CreditsInbox_OnTake("item", 1, 1)
    update()
    mockNow = mockNow + 1
    takeItem(1, 1)                               -- second attempt replaces the first pending action
    update()
    advance(3)
    check("Retry: two attempts on the same slot still credit once", logCount() == 1 and ns.creditsDb.transactionLog[1].rep == 100)

    -- ---- AutoLootMailItem: many slots + money, one log entry --------------------
    fresh()
    mail("MainA", "Everything", { item(1, "Test Sword", 2), item(2, "Test Herb", 5), item(1, "Test Sword", 1) }, 20000)
    local printedBefore = #printLog
    ns.CreditsInbox_OnTake("all", 1)
    for slot = 1, 3 do
        inbox[1].items[slot] = nil
        advance(0.15)
        update()
    end
    inbox[1].money = 0
    advance(0.15)
    update()
    check("Auto-loot: nothing is credited until the take settles", logCount() == 0)
    table.remove(inbox, 1) -- the emptied mail is removed and indexes shift
    advance(0.2)
    update()
    advance(3)
    check("Auto-loot: ONE log entry for the whole mail", logCount() == 1)
    local le = ns.creditsDb.transactionLog[1]
    check("Auto-loot: items merged (3 swords, 5 herbs), gold 2, total rep 360",
        #le.items == 2 and le.gold == 2 and le.rep == 360)
    local lines = 0
    for i = printedBefore + 1, #printLog do
        if tostring(printLog[i]):find("MainA: +360.00 rep", 1, true) then lines = lines + 1 end
    end
    check("Auto-loot: ONE credited chat line for the mail", lines == 1)

    -- ---- mail identified by key, not index ---------------------------------------
    fresh()
    mail("Donor1", "First", { item(1, "Test Sword", 1) })   -- 1
    mail("MainA", "Second", { item(1, "Test Sword", 2) })   -- 2
    takeItem(2, 1)
    table.remove(inbox, 1)                                  -- another mail disappears first: MainA's is now index 1
    update()
    advance(3)
    check("Index shift: credit lands on the mail's own sender, found by key not index",
        logCount() == 1 and ns.creditsDb.transactionLog[1].sender == "MainA" and ns.creditsDb.transactionLog[1].rep == 100)

    -- ---- two mails with the same sender+subject stay distinct (daysLeft tiebreak) -
    fresh()
    mail("MainA", "Donation", { item(1, "Test Sword", 1) })
    mail("MainA", "Donation", { item(1, "Test Sword", 4) })
    takeItem(2, 1)
    update()
    advance(3)
    check("Duplicate subjects: only the mail actually taken is credited (4 swords = 200 rep)",
        logCount() == 1 and ns.creditsDb.transactionLog[1].rep == 200)

    -- ---- unchecked mail: taken, never credited --------------------------------------
    fresh()
    mail("Auction House", "Auction successful", {}, 50000)
    ns.CreditsInbox_OnTake("money", 1)
    inbox[1].money = 0
    update()
    advance(3)
    check("Unchecked: gold taken from an unchecked mail credits nothing", logCount() == 0 and next(ns.creditsDb.pendingCredits) == nil)
    fresh()
    mail("Auction House", "Auction successful", {}, 50000)
    ns.CreditsInbox_SetChecked(1, true)
    ns.CreditsInbox_OnTake("money", 1)
    inbox[1].money = 0
    update()
    advance(3)
    check("Unchecked: once the officer ticks it, the take IS credited (held - not a guild member)",
        next(ns.creditsDb.pendingCredits) ~= nil and ns.creditsDb.pendingCredits["auction house"] ~= nil)

    -- ---- COD: never credited, one chat line --------------------------------------------
    fresh()
    mail("MainA", "Pay me", { item(1, "Test Sword", 1) }, 0, { cod = 5000 })
    printLog = {}
    ns.CreditsInbox_OnTake("item", 1, 1)
    ns.CreditsInbox_OnTake("all", 1)
    inbox[1].items[1] = nil
    update()
    advance(3)
    local codLines = 0
    for _, l in ipairs(printLog) do if tostring(l):find("COD mail from MainA skipped", 1, true) then codLines = codLines + 1 end end
    check("COD: never credited even when taken", logCount() == 0)
    check("COD: exactly one skipped line per COD mail", codLines == 1)

    -- ---- gold-only mail via TakeInboxMoney ----------------------------------------------
    fresh()
    mail("MainA", "[5 Gold]", {}, 50000)
    ns.CreditsInbox_OnTake("money", 1)
    inbox[1].money = 0
    update()
    advance(3)
    check("Gold take: 5 gold credited as 500 rep", logCount() == 1 and ns.creditsDb.transactionLog[1].gold == 5
        and ns.creditsDb.transactionLog[1].rep == 500 and ns.creditsDb.transactionLog[1].category == nil)
    local gl = ns.creditsDb.transactionLog[1]
    check("Gold take: items empty, receiver recorded", #gl.items == 0 and gl.receiver == "Officer1")

    -- ---- several manual clicks on one mail = one entry ------------------------------------
    fresh()
    mail("MainA", "Bundle", { item(1, "Test Sword", 1), item(2, "Test Herb", 3), item(1, "Test Sword", 2) })
    takeItem(1, 1); advance(0.2); update()
    advance(1)
    takeItem(1, 2); advance(0.2); update()
    advance(1)
    takeItem(1, 3); advance(0.2); update()
    check("Clicks: still waiting inside the quiet window (nothing logged yet)", logCount() == 0)
    advance(3)
    check("Clicks: three separate clicks on one mail become ONE entry",
        logCount() == 1 and ns.creditsDb.transactionLog[1].rep == 50 + 6 + 100)

    -- ---- expiry ---------------------------------------------------------------------------
    fresh()
    mail("MainA", "Donation", { item(1, "Test Sword", 1) })
    ns.CreditsInbox_OnTake("item", 1, 1)   -- never confirmed
    advance(11)                            -- the expiry timer runs an update: slot still there, action expires
    inbox[1].items[1] = nil                -- taken some other way much later
    update()
    advance(3)
    check("Expiry: an unconfirmed take is dropped after ~10s and credits nothing later", logCount() == 0)

    -- ---- closing the mailbox / logging out flushes ------------------------------------------
    fresh()
    mail("MainA", "Donation", { item(1, "Test Sword", 2) })
    takeItem(1, 1)
    update()
    check("Close: still inside the quiet window", logCount() == 0)
    ns.CreditsInbox_FlushAll()
    check("Close: MAIL_CLOSED / logout flush credits immediately", logCount() == 1)
    fresh()
    mail("MainA", "Donation", { item(1, "Test Sword", 2) })
    takeItem(1, 1)
    update()
    ns.CreditsInbox_OnMailShow()
    check("Reopen: a new mailbox visit flushes what was confirmed before it", logCount() == 1)

    -- ---- unconfirmed takes when the mailbox closes (2026-10-04, Loopi) ---------------------
    fresh()
    mail("MainA", "Donation", { item(1, "Test Sword", 2) })
    ns.CreditsInbox_OnTake("item", 1, 1)       -- hook ran, the inbox update never arrived
    advance(0.1)
    ns.CreditsInbox_OnMailClosed()
    check("Close warning: an unconfirmed take at close prints a chat warning naming sender and item",
        cm4.said("mailbox closed before the take from MainA") and cm4.said("Test Sword x2"))
    check("Close warning: ...and credits nothing (never confirmed)", logCount() == 0)
    fresh()
    mail("MainA", "Donation", { item(1, "Test Sword", 2) })
    takeItem(1, 1)
    update()
    ns.CreditsInbox_OnMailClosed()
    check("Close warning: a confirmed take closes quietly and is credited",
        not cm4.said("mailbox closed before") and logCount() == 1)
    fresh()
    mail("MainA", "Donation", { item(1, "Test Sword", 2) })
    ns.CreditsInbox_OnTake("item", 1, 1)
    advance(11)                                -- long past the 10s expiry: treated as a failed take
    ns.CreditsInbox_OnMailClosed()
    check("Close warning: an old unconfirmed take (failed) does not warn", not cm4.said("mailbox closed before"))

    -- ---- Wall 4: the hook is only ever installed by an armed receiver ------------------------
    ns.CreditsInbox_ResetForTests()
    cm4.setup()
    ns.creditsArmedInbox = false
    local hooks = {}
    _G.hooksecurefunc = function(name, fn) hooks[name] = fn end
    _G.TakeInboxItem = function() end
    _G.TakeInboxMoney = function() end
    _G.AutoLootMailItem = function() end
    ns.creditsDb.masterToggle = false
    ns.creditsDb.creditTestReceivers = { "Officer1" }
    ns.Credits_EvaluateArming()
    check("Wall 4: master toggle OFF installs nothing", next(hooks) == nil and ns.creditsInboxFrame == nil)
    ns.creditsDb.masterToggle = true
    ns.creditsDb.creditTestReceivers = { "SomeoneElse" }
    ns.Credits_EvaluateArming()
    check("Wall 4: toggle ON but this character not on the receiver list installs nothing",
        next(hooks) == nil and ns.creditsInboxFrame == nil and ns.creditsArmedInbox == false)
    ns.creditsDb.creditTestReceivers = { "Officer1" }
    ns.Credits_EvaluateArming()
    check("Wall 4: toggle ON + on the receiver list installs the three take hooks",
        hooks.TakeInboxItem and hooks.TakeInboxMoney and hooks.AutoLootMailItem and ns.creditsArmedInbox == true)
    check("Wall 4: the event frame exists and listens for the mail events",
        ns.creditsInboxFrame and ns.creditsInboxFrame:IsEventRegistered("MAIL_INBOX_UPDATE")
        and ns.creditsInboxFrame:IsEventRegistered("MAIL_SHOW") and ns.creditsInboxFrame:IsEventRegistered("MAIL_CLOSED")
        and ns.creditsInboxFrame:IsEventRegistered("MAIL_FAILED"))
    -- end to end through the installed hook + event frame
    inbox, timers = {}, {}
    ns.creditsInboxFrame:Fire("MAIL_SHOW")
    mail("MainA", "Donation", { item(1, "Test Sword", 2) })
    hooks.TakeInboxItem(1, 1)
    inbox[1].items[1] = nil
    ns.creditsInboxFrame:Fire("MAIL_INBOX_UPDATE")
    ns.creditsInboxFrame:Fire("MAIL_CLOSED")
    check("Wall 4: end to end - the installed hook + events credit a real take", logCount() == 1)
    ns.creditsInboxFrame:Fire("MAIL_FAILED", 1) -- must not error with nothing pending
    -- a second EvaluateArming does not double-install
    local before = hooks.TakeInboxItem
    ns.Credits_EvaluateArming()
    check("Wall 4: arming twice does not reinstall", hooks.TakeInboxItem == before)

    -- cleanup
    _G.hooksecurefunc, _G.TakeInboxItem, _G.TakeInboxMoney, _G.AutoLootMailItem = nil, nil, nil, nil
    _G.GetInboxNumItems, _G.GetInboxHeaderInfo, _G.GetInboxItem = nil, nil, nil
    _G.C_Timer = nil
    _G.GetTime = savedGetTime
    ns.CreditsInbox_ResetForTests()
    ns.ITEM_POINTS = cm4.origItemPoints
    _G.GRM = nil
end

--------------------------------------------------------------------------
-- CM7 Audit Log tab logic (CreditsLog.lua)
--------------------------------------------------------------------------
print("== Credits: Audit Log rows / filters / sorting / export ==")
do
    resetState()
    ns.creditsDb.ledger = {
        MainA = { discordName = "MainA", mainToon = "MainA", alts = { "AltA1" } },
        MainB = { discordName = "MainB", mainToon = "MainB", alts = {} },
    }
    local DAY = 86400
    local base = 1760000000
    ns.creditsDb.transactionLog = {
        { id = "d1", ts = base, sender = "AltA1", receiver = "Bavin", account = "MainA", gold = 2.5, rep = 250, credits = 2.5,
          items = { { itemID = 1, name = "Test Sword", count = 3, rep = 150, category = "Weapon" }, { itemID = 9, name = "Odd Thing", count = 1, rep = 0, unpriced = true } },
          creditsPerRep = { x = 1, y = 100 }, repPerGold = { x = 100, y = 1 },
          tierBefore = "Neutral", prestigeBefore = 0, tierAfter = "Friendly", prestigeAfter = 0 },
        { id = "d2", ts = base + 2 * DAY, sender = "MainB", receiver = "Officer1", account = "MainB", rep = 40, credits = 0.4,
          items = { { itemID = 5, name = "Herb", count = 1, rep = 40, category = "Herb" } },
          tierBefore = "Neutral", prestigeBefore = 0, tierAfter = "Neutral", prestigeAfter = 0 },
        { id = "d3", ts = base + 5 * DAY, sender = "Rando", receiver = "Bavin", account = "MainA", rep = 100, credits = 1, released = true,
          items = { { itemID = 1, name = "Test Sword", count = 2, rep = 100, category = "Weapon" } },
          tierBefore = "Friendly", prestigeBefore = 0, tierAfter = "Friendly", prestigeAfter = 0 },
        { id = "m1", ts = base + 9 * DAY, kind = "merge", account = "MainA", source = "MainC", sourceMain = "MainC", moved = { "MainC", "AltC" },
          rep = 500, credits = 5, officer = "Officer1", tierBefore = "Friendly", prestigeBefore = 0, tierAfter = "Honored", prestigeAfter = 0 },
        "garbage",
    }
    local rows = ns.CreditsLog_Rows()
    check("Log: junk entries are skipped, the rest become rows", #rows == 4)
    local byId = {}
    for _, r in ipairs(rows) do byId[r.id] = r end
    check("Log: a donation row names the character and its account's main", byId.d1.who == "AltA1 (MainA)" and byId.d1.kind == "donation")
    check("Log: a main donating shows just the name", byId.d2.who == "MainB")
    check("Log: what = gold first, then items with counts", byId.d1.what == "2.50 gold, Test Sword x3, Odd Thing")
    check("Log: processed-by comes from the receiving officer", byId.d1.by == "Bavin" and byId.d2.by == "Officer1")
    check("Log: a held donation applied later is kind 'released'", byId.d3.kind == "released" and byId.d3.kindLabel == "Released")
    check("Log: merge rows describe what was merged and by whom",
        byId.m1.kind == "merge" and byId.m1.what == "Merged in MainC [MainC, AltC]" and byId.m1.by == "Officer1" and byId.m1.who == "MainA")
    check("Log: tier-up flag is set only when the tier changed", byId.d1.tierUp == true and byId.d2.tierUp == false and byId.m1.tierUp == true)
    check("Log: tier text shows the tier reached", byId.d1.tier == "Friendly" and byId.m1.tier == "Honored")

    check("Filter: no filter returns everything", #ns.CreditsLog_Filter(rows, {}) == 4)
    check("Filter: by kind", #ns.CreditsLog_Filter(rows, { kind = "merge" }) == 1 and #ns.CreditsLog_Filter(rows, { kind = "released" }) == 1)
    check("Filter: by processed-by is case-insensitive", #ns.CreditsLog_Filter(rows, { by = "bavin" }) == 2)
    check("Filter: since a timestamp drops older rows", #ns.CreditsLog_Filter(rows, { since = base + 3 * DAY }) == 2)
    check("Filter: tier-ups only", #ns.CreditsLog_Filter(rows, { tierUpOnly = true }) == 2)
    check("Filter: text matches a character name", #ns.CreditsLog_Filter(rows, { text = "alta1" }) == 1)
    check("Filter: text matches an item name", #ns.CreditsLog_Filter(rows, { text = "sword" }) == 2)
    check("Filter: text matches the account (MainA rows incl. the merge)", #ns.CreditsLog_Filter(rows, { text = "maina" }) == 3)
    check("Filters combine (AND)", #ns.CreditsLog_Filter(rows, { text = "sword", by = "Bavin", kind = "released" }) == 1)

    local sorted = ns.CreditsLog_Sort(ns.CreditsLog_Filter(rows, {}), "date", false)
    check("Sort: date descending puts the newest first", sorted[1].id == "m1" and sorted[4].id == "d1")
    ns.CreditsLog_Sort(sorted, "date", true)
    check("Sort: date ascending puts the oldest first", sorted[1].id == "d1" and sorted[4].id == "m1")
    ns.CreditsLog_Sort(sorted, "rep", false)
    check("Sort: rep descending is numeric, not text", sorted[1].id == "m1" and sorted[2].id == "d1" and sorted[4].id == "d2")
    ns.CreditsLog_Sort(sorted, "tier", false)
    check("Sort: tier orders by tier rank", sorted[1].id == "m1" and sorted[4].id == "d2")
    ns.CreditsLog_Sort(sorted, "by", true)
    check("Sort: by name ties fall back to newest first", sorted[1].by == "Bavin" and sorted[1].id == "d3" and sorted[2].id == "d1")
    ns.CreditsLog_Sort(sorted, "who", true)
    check("Sort: who is alphabetical", sorted[1].who == "AltA1 (MainA)")

    local names = ns.CreditsLog_Distinct(rows, "by")
    check("Distinct: processed-by names, unique and sorted", #names == 2 and names[1] == "Bavin" and names[2] == "Officer1")
    local kinds = ns.CreditsLog_KindsPresent(rows)
    check("Kinds present: fixed order, only what occurs", #kinds == 3 and kinds[1] == "donation" and kinds[2] == "released" and kinds[3] == "merge")

    local tip = ns.CreditsLog_TooltipLines(byId.d1)
    local flat = {}
    for _, l in ipairs(tip) do flat[#flat + 1] = tostring(l[1]) .. "|" .. tostring(l[2] or "") end
    local blob = table.concat(flat, "\n")
    check("Tooltip: lists each item with its rep and category", blob:find("Test Sword x3|150.00 rep (Weapon)", 1, true) ~= nil)
    check("Tooltip: flags an unpriced item", blob:find("Odd Thing x1|unpriced", 1, true) ~= nil)
    check("Tooltip: shows totals, rates used, tier change and who processed it",
        blob:find("Total rep|250.00", 1, true) and blob:find("Rates used|1 Credits = 100 Rep", 1, true)
        and blob:find("Tier|Neutral -> Friendly", 1, true) and blob:find("Processed by|Bavin", 1, true))
    local mtip = {}
    for _, l in ipairs(ns.CreditsLog_TooltipLines(byId.m1)) do mtip[#mtip + 1] = tostring(l[1]) .. "|" .. tostring(l[2] or "") end
    check("Tooltip: a merge lists the characters moved", table.concat(mtip, "\n"):find("Characters moved|MainC, AltC", 1, true) ~= nil)

    -- A future spend row (CM5) is shown, not hidden.
    ns.creditsDb.transactionLog[#ns.creditsDb.transactionLog + 1] =
        { id = "s1", ts = base + 10 * DAY, kind = "spend", account = "MainB", what = "Sword x1 for 3.00 credits", rep = 0, credits = -3, processedBy = "Officer1" }
    local all = ns.CreditsLog_Rows()
    local spend
    for _, r in ipairs(all) do if r.id == "s1" then spend = r end end
    check("Unknown kinds (CM5 spend) still appear with their own label", spend and spend.kindLabel == "Spend" and spend.credits == -3 and spend.by == "Officer1")

    local csv = ns.CreditsLog_ExportText(ns.CreditsLog_Sort(ns.CreditsLog_Filter(rows, { kind = "donation" }), "date", true))
    local lines = {}
    for line in (csv .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    check("Export: header plus one line per filtered row", #lines == 3 and lines[1]:find("^Date,Kind,Account,Who,What,Rep,Credits,Tier,Processed by$"))
    check("Export: fields with commas are quoted, numbers keep four decimals",
        lines[2]:find('"2.50 gold, Test Sword x3, Odd Thing"', 1, true) and lines[2]:find(",250.0000,2.5000,", 1, true))
end

--------------------------------------------------------------------------
-- Post the unclaimed Review Queue names to /guild (2026-10-06, Loopi):
-- author / guild leader / donation recipient only, no cooldown, names
-- only, split under the chat cap, paced with C_Timer.
--------------------------------------------------------------------------
print("== Credits: Review Queue guild post ==")
do
    resetState()
    inGuild = true
    guildRosterEntries = {
        { name = "GLeader", rankIndex = 0 }, { name = "PlainMember", rankIndex = 5 },
        { name = "Officer1", rankIndex = 3 }, { name = "Bavin", rankIndex = 4 },
    }
    ns.UpdateGuildRosterCache()
    ns.db.editors = { "Officer1" }
    ns.db.recipient = "Bavin"
    authorAccountFlag = false

    local savedStatic, savedDyn, savedIndex = ns.CreditsReviewQueue, ns.creditsDb.dynamicReviewQueue, ns.creditsDb.toonIndex
    local savedSend, savedTimer = _G.SendChatMessage, _G.C_Timer
    local sent, timers = {}, {}
    _G.SendChatMessage = function(text, chan) sent[#sent + 1] = { text = text, chan = chan } end
    _G.C_Timer = { After = function(d, fn) timers[#timers + 1] = { delay = d, fn = fn } end }
    local function runTimers() local t = timers; timers = {}; for _, x in ipairs(t) do x.fn() end end

    -- Unclaimed list: static + dynamic rows, minus names an account already owns.
    ns.CreditsReviewQueue = { { name = "zed" }, { name = "alpha" }, { name = "linked" }, { name = "BETA" } }
    ns.creditsDb.dynamicReviewQueue = { { name = "beta" }, { name = "carol" } }
    ns.creditsDb.toonIndex = { linked = "Someone" }
    local names = ns.Credits_UnclaimedQueueNames()
    check("QueuePost: unclaimed list is sorted, capitalised, de-duplicated and skips linked names (Alpha, Beta, Carol, Zed)",
        #names == 4 and names[1] == "Alpha" and names[2]:lower() == "beta" and names[3] == "Carol" and names[4] == "Zed")

    -- Packing.
    check("QueuePost: no names -> no messages", #ns.Credits_BuildQueuePosts({}) == 0)
    local one = ns.Credits_BuildQueuePosts({ "Solo" })
    check("QueuePost: one name -> one message with a (1/1) header",
        #one == 1 and one[1] == "DH Bavin - unclaimed donor names (1/1): Solo")
    local many = {}
    for i = 1, 150 do many[i] = ("Name%03d%s"):format(i, ("x"):rep(i % 5)) end
    local posts = ns.Credits_BuildQueuePosts(many)
    local allFit, joined = true, {}
    for i, p in ipairs(posts) do
        if #p > 255 then allFit = false end
        if not p:find("^DH Bavin %- unclaimed donor names %(" .. i .. "/" .. #posts .. "%): ") then allFit = false end
        joined[#joined + 1] = p:match("%): (.*)$")
    end
    check("QueuePost: 150 names split into several messages, each under the 255-char chat cap with (i/N) headers",
        #posts > 1 and allFit)
    check("QueuePost: every name appears exactly once, in order",
        table.concat(joined, ", ") == table.concat(many, ", "))

    -- Permission gate.
    local function tryPost(player)
        sent, timers = {}, {}
        currentPlayerName = player
        return ns.Credits_PostReviewQueueToGuild()
    end
    check("QueuePost: a plain member is refused and sends nothing", tryPost("PlainMember") == false and #sent == 0)
    check("QueuePost: a shared-list officer is refused", tryPost("Officer1") == false and #sent == 0)
    local ok, nMsgs, nNames = tryPost("Bavin")
    check("QueuePost: the donation recipient can post", ok == true and nNames == 4 and nMsgs == 1)
    check("QueuePost: it goes to GUILD chat, names only",
        #sent == 1 and sent[1].chan == "GUILD" and sent[1].text == "DH Bavin - unclaimed donor names (1/1): Alpha, Beta, Carol, Zed")
    check("QueuePost: the guild leader can post", tryPost("GLeader") == true)
    authorAccountFlag = true
    check("QueuePost: the author account (any character) can post", tryPost("PlainMember") == true)
    authorAccountFlag = false
    inGuild = false
    check("QueuePost: not in the guild -> refused", tryPost("Bavin") == false and #sent == 0)
    inGuild = true
    check("QueuePost: no cooldown - posting twice in a row both go out",
        tryPost("Bavin") == true and tryPost("Bavin") == true and #sent == 1)

    -- Multi-message pacing.
    local queue = {}
    for i = 1, 150 do queue[i] = { name = ("donor%03dxx"):format(i) } end
    ns.CreditsReviewQueue = queue
    ns.creditsDb.dynamicReviewQueue = {}
    local ok2, n2 = tryPost("Bavin")
    check("QueuePost: a long list sends the first message at once and paces the rest",
        ok2 == true and n2 > 1 and #sent == 1 and #timers == n2 - 1)
    check("QueuePost: later messages are spaced apart", timers[1].delay > 0 and (#timers < 2 or timers[2].delay > timers[1].delay))
    runTimers()
    check("QueuePost: after the timers fire every message has gone to GUILD", #sent == n2 and sent[#sent].chan == "GUILD")

    -- Empty list.
    ns.CreditsReviewQueue = { { name = "linked" } }
    local okE, whyE = tryPost("Bavin")
    check("QueuePost: nothing unclaimed -> refuses with 'empty', sends nothing", okE == false and whyE == "empty" and #sent == 0)

    -- Slash command: preview first, send only on confirm.
    ns.CreditsReviewQueue = { { name = "alpha" }, { name = "beta" } }
    sent, timers = {}, {}
    currentPlayerName = "Bavin"
    ns.Credits_HandleSlash("queuepost")
    check("QueuePost slash: without 'confirm' it only previews", #sent == 0)
    ns.Credits_HandleSlash("queuepost confirm")
    check("QueuePost slash: 'confirm' sends", #sent == 1 and sent[1].text:find("Alpha, Beta", 1, true) ~= nil)
    sent = {}
    currentPlayerName = "PlainMember"
    ns.Credits_HandleSlash("queuepost confirm")
    check("QueuePost slash: a non-authorised player is refused", #sent == 0)

    ns.CreditsReviewQueue, ns.creditsDb.dynamicReviewQueue, ns.creditsDb.toonIndex = savedStatic, savedDyn, savedIndex
    _G.SendChatMessage, _G.C_Timer = savedSend, savedTimer
end

--------------------------------------------------------------------------
-- Roster "Add name..." (2026-10-06, Loopi): new main / alt of an account /
-- Discord name for an account. Duplicates refused, non-guild names allowed,
-- gated to author / guild leader / mail recipient.
--------------------------------------------------------------------------
print("== Credits: Roster Add name ==")
do
    cm4.setup()
    authorAccountFlag = false
    ns.db.recipient = nil
    local savedStatic = ns.CreditsReviewQueue
    local ledger = ns.creditsDb.ledger
    local neutralTier = (ns.Credits_TierStateForLifetime(0))

    -- Gate: a plain officer is NOT enough.
    currentPlayerName = "Officer1"
    local ok, why = ns.Credits_AddRosterName("main", "Fresh")
    check("AddName: a plain officer is refused (gate is author / guild leader / recipient)",
        ok == false and why == "permission" and ledger["Fresh"] == nil)
    check("AddName: CanAddRosterNames is false for a plain officer", ns.Credits_CanAddRosterNamesLocal() == false)

    -- Guild leader, recipient and author account are each allowed.
    currentPlayerName = "GLeader"
    check("AddName: the guild leader may add names", ns.Credits_CanAddRosterNamesLocal() == true)
    currentPlayerName = "Donor1"
    ns.db.recipient = "Donor1"
    check("AddName: the mail recipient may add names", ns.Credits_CanAddRosterNamesLocal() == true)
    ns.db.recipient = nil
    check("AddName: ...and Donor1 stops being allowed when no longer the recipient", ns.Credits_CanAddRosterNamesLocal() == false)
    currentPlayerName = "Donor2"
    authorAccountFlag = true
    check("AddName: the author account may add names (any character)", ns.Credits_CanAddRosterNamesLocal() == true)
    authorAccountFlag = false

    currentPlayerName = "GLeader"

    -- New main (non-guild name is fine).
    ok, why = ns.Credits_AddRosterName("main", "  Fresh  ")
    local fresh = ledger["Fresh"]
    check("AddName main: succeeds for a name that is not in the guild and returns the account key", ok == true and why == "Fresh")
    check("AddName main: a new empty account (0 lifetime, 0 credits, base tier, Discord = the main)",
        fresh and fresh.mainToon == "Fresh" and fresh.discord == "Fresh" and (fresh.alts and #fresh.alts == 0)
        and fresh.lifetimePoints == 0 and fresh.credits == 0 and fresh.lifetimeCredits == 0 and fresh.tier == neutralTier)
    check("AddName main: the name resolves to the new account", ns.Credits_ResolveMain("fresh") == "Fresh"
        and ns.creditsDb.toonIndex["fresh"] == "Fresh")
    check("AddName main: the new account is stamped for officer sync", fresh and type(fresh.syncedAt) == "number")

    -- Duplicates are refused everywhere, case-insensitively, never moved.
    check("AddName dup: the same main again (any case)", select(2, ns.Credits_AddRosterName("main", "FRESH")) == "exists")
    check("AddName dup: with a realm suffix", select(2, ns.Credits_AddRosterName("main", "Fresh-SkullRock")) == "exists")
    check("AddName dup: an existing main from the seed", select(2, ns.Credits_AddRosterName("main", "maina")) == "exists")
    check("AddName dup: an existing alt as a new main", select(2, ns.Credits_AddRosterName("main", "AltA1")) == "exists")
    check("AddName dup: an existing alt as an alt of another account",
        select(2, ns.Credits_AddRosterName("alt", "AltA1", "MainB")) == "exists" and ledger["MainB"].alts[1] == nil)
    check("AddName dup: an existing main as an alt", select(2, ns.Credits_AddRosterName("alt", "MainB", "MainA")) == "exists")
    check("AddName dup: an account's Discord name can't be added as a character",
        select(2, ns.Credits_AddRosterName("main", "Fresh")) == "exists")

    -- Bad names.
    check("AddName name: empty", select(2, ns.Credits_AddRosterName("main", "   ")) == "name")
    check("AddName name: a character name with a space", select(2, ns.Credits_AddRosterName("main", "Two Words")) == "name")
    check("AddName name: a control character", select(2, ns.Credits_AddRosterName("discord", "bad\nname", "MainA")) == "name")
    check("AddName name: over 32 characters", select(2, ns.Credits_AddRosterName("main", ("x"):rep(33))) == "name")
    check("AddName kind: an unknown kind", select(2, ns.Credits_AddRosterName("bogus", "Zzz")) == "kind")

    -- Alt of an account: the account can be named by any name on it.
    ok, why = ns.Credits_AddRosterName("alt", "NewAlt", "MainA")
    check("AddName alt: attaches to the named account and returns its key", ok == true and why == "MainA")
    check("AddName alt: the alt is on the account and resolves to its main",
        ledger["MainA"].alts[#ledger["MainA"].alts] == "NewAlt" and ns.Credits_ResolveMain("newalt") == "MainA")
    check("AddName alt: the changed account is stamped for sync", type(ledger["MainA"].syncedAt) == "number")
    check("AddName alt: the account can be named by one of its ALTS and by any case of the key",
        select(1, ns.Credits_AddRosterName("alt", "SecondAlt", "AltA1")) == true
        and select(1, ns.Credits_AddRosterName("alt", "ThirdAlt", "maina")) == true
        and ns.Credits_ResolveMain("SecondAlt") == "MainA" and ns.Credits_ResolveMain("ThirdAlt") == "MainA")
    ok, why = ns.Credits_AddRosterName("alt", "Orphan", "NoSuchAccount")
    check("AddName alt: an unknown account is refused and nothing is added", ok == false and why == "noaccount"
        and ns.creditsDb.toonIndex["orphan"] == nil)
    ok, why = ns.Credits_AddRosterName("alt", "Orphan", "")
    check("AddName alt: a blank account is refused", ok == false and why == "noaccount")

    -- Discord name.
    ok, why = ns.Credits_AddRosterName("discord", "some.discord_name", "MainB")
    check("AddName discord: sets the account's Discord name", ok == true and why == "MainB"
        and ledger["MainB"].discord == "some.discord_name")
    check("AddName discord: a Discord name is not a character (no toon resolves from it)",
        ns.creditsDb.toonIndex["some.discord_name"] == nil)
    check("AddName discord dup: the same Discord name again, any case",
        select(2, ns.Credits_AddRosterName("discord", "SOME.discord_NAME", "MainA")) == "exists")
    check("AddName discord dup: a character name already on the roster",
        select(2, ns.Credits_AddRosterName("discord", "AltA1", "MainB")) == "exists")
    local ok2, key2, displaced = ns.Credits_AddRosterName("discord", "other_tag", "MainB")
    check("AddName discord: replacing a Discord-only name sends the old one to the Review Queue",
        ok2 == true and displaced == "some.discord_name" and ledger["MainB"].discord == "other_tag")
    local inQueue = false
    for _, row in ipairs(ns.creditsDb.dynamicReviewQueue) do
        if row.name == "some.discord_name" then inQueue = true end
    end
    check("AddName discord: ...and it is in the dynamic Review Queue", inQueue)

    -- A name waiting in the Review Queue: a new main keeps its Step 0 history
    -- and leaves the queue; an alt just leaves the queue.
    ns.CreditsReviewQueue = { { name = "Queued", rawGoldAmount = 150, latestDonation = "2026-09-01" } }
    ns.Credits_AddToReviewQueue("QueuedAlt")
    ok = ns.Credits_AddRosterName("main", "Queued")
    local q = ledger["Queued"]
    check("AddName main from the queue: keeps the raw-data history (150 gold = 1500 points) and last donation",
        ok == true and q and q.lifetimePoints == 1500 and q.lastDonationDate == "2026-09-01")
    check("AddName main from the queue: tier follows the history",
        q and q.tier == (ns.Credits_TierStateForLifetime(1500)))
    ok = ns.Credits_AddRosterName("alt", "QueuedAlt", "MainA")
    local stillQueued = false
    for _, row in ipairs(ns.creditsDb.dynamicReviewQueue) do
        if row.name == "QueuedAlt" then stillQueued = true end
    end
    check("AddName alt from the queue: the queue row is cleared", ok == true and not stillQueued)
    ns.CreditsReviewQueue = savedStatic

    -- A held donation waits for exactly this kind of name.
    cm4.setup()
    currentPlayerName = "GLeader"
    ns.CreditsDon_Credit({ sender = "Rando", items = { cm4.sword(2) } })
    local mainA = ns.creditsDb.ledger["MainA"]
    local lifeBefore = mainA.lifetimePoints
    check("AddName release: the donation is held while Rando is unknown", ns.creditsDb.pendingCredits["rando"] ~= nil)
    ok = ns.Credits_AddRosterName("alt", "Rando", "MainA")
    check("AddName release: adding Rando as an alt applies the held donation to that account",
        ok == true and mainA.lifetimePoints == lifeBefore + 100 and ns.creditsDb.pendingCredits["rando"] == nil)
    ns.CreditsDon_Credit({ sender = "Loner", items = { cm4.sword(4) } })
    ok = ns.Credits_AddRosterName("main", "Loner")
    check("AddName release: adding Loner as a new main releases onto the new account",
        ok == true and ns.creditsDb.ledger["Loner"] and ns.creditsDb.ledger["Loner"].lifetimePoints == 200
        and ns.creditsDb.pendingCredits["loner"] == nil)
end

--------------------------------------------------------------------------
-- Credits: CM6 member balance pull/push (CreditsMember.lua)
--------------------------------------------------------------------------
print("== Credits: CM6 member balance ==")
do
    local PFX = "DHBavinCreditsV2"
    local function deliver(from, text, channel)
        ns.Credits_OnAddonMessage(PFX, text, channel or "WHISPER", from)
    end
    local function sentTo(target, msgType)
        local out = {}
        for _, e in ipairs(outboxLog) do
            if e.target == target and e.channel == "WHISPER" and e.text:match("^" .. msgType .. "|") then
                out[#out + 1] = e.text
            end
        end
        return out
    end
    local function setup()
        resetState()
        wallClock = wallClock + 1000      -- clears every cooldown from earlier sections
        inGuild = true
        guildRosterEntries = {
            { name = "GLeader", rankIndex = 0 },
            { name = "Officer1", rankIndex = 3 },
            { name = "Officer2", rankIndex = 3 },
            { name = "Member1", rankIndex = 5 },
            { name = "Member2", rankIndex = 5 },
        }
        ns.UpdateGuildRosterCache()
        currentPlayerName = "Officer1"
        ns.db.editors = { "Officer1", "Officer2" }
        ns.CreditsSeedData = { MainA = { lifetimePoints = 100 }, MainB = { lifetimePoints = 200 } }
        ns.CreditsAltRoster = { MainA = { "AltA1" } }
        ns.CreditsSeed_Import()
        outboxLog, printLog = {}, {}
    end
    local function bal(o)
        o = o or {}
        return table.concat({ "BALDATA", "1", o.epoch or 0, o.sentAt or wallClock, o.discord or "Disc", o.main or "MainA",
            o.points or 10, o.credits or 5, o.tier or "Friendly", o.prestige or 0, o.lp or 3010, o.lc or 9,
            o.ldd or "2026-09-20", o.lu or 123 }, "|")
    end

    -- ---- officer answers a pull ------------------------------------------------
    setup()
    check("Link Member1 as an alt of MainA (officer edit)", ns.Credits_LinkAlt("Member1", "MainA") == true)
    outboxLog = {}
    deliver("Member1", "MYBALREQ|1")
    local answers = sentTo("Member1", "BALDATA")
    check("An officer answers a member's pull with BALDATA", #answers == 1)
    check("The answer fits the 255-byte addon message limit", answers[1] and #PFX + #answers[1] <= 255)
    check("The answer carries the account's lifetime points", answers[1] and answers[1]:find("|100|", 1, true) ~= nil)
    check("The answer names the account's main", answers[1] and answers[1]:find("|MainA|", 1, true) ~= nil)
    local firstAnswer = answers[1]
    outboxLog = {}
    deliver("Member1", "MYBALREQ|1")
    check("A repeat request inside the cooldown is not answered", #sentTo("Member1", "BALDATA") == 0)
    wallClock = wallClock + 61
    deliver("Member1", "MYBALREQ|1")
    check("...but is answered once the cooldown has passed", #sentTo("Member1", "BALDATA") == 1)

    setup()
    deliver("Officer2", "MYBALREQ|1")
    local none = sentTo("Officer2", "BALNONE")
    check("A requester with no account gets BALNONE, never someone else's data",
        #none == 1 and #sentTo("Officer2", "BALDATA") == 0)
    outboxLog = {}
    deliver("Stranger", "MYBALREQ|1")
    check("A requester outside the guild gets no answer", #outboxLog == 0)
    deliver("Member1", "MYBALREQ|1", "GUILD")
    check("A request that did not arrive as a whisper is ignored", #outboxLog == 0)
    ns.creditsDb.ledger = {}
    deliver("Member2", "MYBALREQ|1")
    check("An officer with an empty ledger stays silent (cannot claim 'no account')", #outboxLog == 0)
    setup()
    currentPlayerName = "Member1"
    deliver("Member2", "MYBALREQ|1")
    check("A non-officer never answers a pull", #outboxLog == 0)

    -- ---- member accepts a reply -----------------------------------------------
    setup()
    currentPlayerName = "Member1"
    check("Before any reply: no account record", ns.CreditsMember_GetCachedRecord() == nil and ns.CreditsMember_Status() == nil)
    deliver("Officer2", bal())
    local rec = ns.CreditsMember_GetCachedRecord()
    check("A reply from an officer is cached and shows as the local account",
        rec and rec.fromCache == true and rec.credits == 5 and rec.points == 10 and rec.lifetimePoints == 3010
        and rec.tier == "Friendly")
    check("Status reports cached", ns.CreditsMember_Status() == "cached")
    check("The guild leader may also answer", (function()
        setup(); currentPlayerName = "Member1"; deliver("GLeader", bal()); return ns.CreditsMember_GetCachedRecord() ~= nil end)())

    setup()
    currentPlayerName = "Member1"
    deliver("Member2", bal())
    check("A reply from a non-officer member is rejected", ns.CreditsMember_GetCachedRecord() == nil)
    deliver("Stranger", bal())
    check("A reply from outside the guild is rejected", ns.CreditsMember_GetCachedRecord() == nil)
    deliver("Officer2", bal(), "GUILD")
    check("A reply that did not arrive as a whisper is rejected", ns.CreditsMember_GetCachedRecord() == nil)
    ns.db.editors = { "Officer1" }
    deliver("Officer2", bal())
    check("The sender is judged against OUR officer list, not the message", ns.CreditsMember_GetCachedRecord() == nil)
    ns.db.editors = { "Officer1", "Officer2" }
    deliver("Officer2", bal({ tier = "Godlike" }))
    check("An unknown tier is rejected", ns.CreditsMember_GetCachedRecord() == nil)
    deliver("Officer2", bal({ credits = -5 }))
    check("A negative balance is rejected", ns.CreditsMember_GetCachedRecord() == nil)
    deliver("Officer2", bal({ points = "abc" }))
    check("A non-numeric balance is rejected", ns.CreditsMember_GetCachedRecord() == nil)
    deliver("Officer2", (bal():gsub("|Disc|", "|Disc|extra|")))
    check("A reply with the wrong field count is rejected", ns.CreditsMember_GetCachedRecord() == nil)
    deliver("Officer2", (bal():gsub("^BALDATA|1|", "BALDATA|9|")))
    check("An unknown protocol version is rejected", ns.CreditsMember_GetCachedRecord() == nil)

    -- ---- merge rules -------------------------------------------------------------
    setup()
    currentPlayerName = "Member1"
    deliver("Officer2", bal({ lp = 3010, credits = 5, lu = 100 }))
    deliver("Officer2", bal({ lp = 2000, credits = 99, lu = 200 }))
    check("Lower lifetime points (a stale officer) never replaces a newer balance", ns.CreditsMember_GetCachedRecord().credits == 5)
    deliver("Officer2", bal({ lp = 3500, credits = 7, lu = 300 }))
    check("Higher lifetime points replaces", ns.CreditsMember_GetCachedRecord().credits == 7)
    deliver("Officer2", bal({ lp = 3500, credits = 2, lu = 400 }))
    check("Equal lifetime points + newer lastUpdated replaces (credits spent)", ns.CreditsMember_GetCachedRecord().credits == 2)
    deliver("Officer2", bal({ lp = 3500, credits = 50, lu = 350 }))
    check("Equal lifetime points + older lastUpdated is ignored", ns.CreditsMember_GetCachedRecord().credits == 2)
    deliver("Officer2", bal({ epoch = 1, lp = 10, credits = 0, lu = 10 }))
    check("A higher data epoch (reset) replaces even with lower lifetime points",
        ns.CreditsMember_GetCachedRecord().credits == 0 and ns.CreditsMember_GetCachedRecord().lifetimePoints == 10)
    deliver("Officer2", bal({ epoch = 0, lp = 9999, credits = 77, lu = 9999 }))
    check("A lower data epoch is rejected", ns.CreditsMember_GetCachedRecord().credits == 0)
    deliver("Officer2", "BALNONE|1|" .. wallClock)
    check("BALNONE never wipes a real balance", ns.CreditsMember_GetCachedRecord() ~= nil)

    setup()
    currentPlayerName = "Member1"
    deliver("Officer2", "BALNONE|0|" .. wallClock)
    check("BALNONE with no cache is remembered as 'none'",
        ns.CreditsMember_Status() == "none" and ns.CreditsMember_GetCachedRecord() == nil)
    deliver("Officer2", bal())
    check("...and real data replaces it", ns.CreditsMember_Status() == "cached")
    deliver("Officer2", "BALNONE|0|" .. wallClock)
    check("...and a later BALNONE does not undo it", ns.CreditsMember_Status() == "cached")

    setup()
    currentPlayerName = "Officer1"
    deliver("Officer2", bal())
    check("An officer ignores balance replies (they hold the ledger)", next(ns.creditsDb.memberBal) == nil)

    -- ---- cache is per character ---------------------------------------------------
    setup()
    currentPlayerName = "Member1"
    deliver("Officer2", bal())
    currentPlayerName = "Member2"
    check("Another character does not see Member1's cached balance", ns.CreditsMember_GetCachedRecord() == nil)

    -- ---- encode ------------------------------------------------------------------
    setup()
    local longRec = { discordName = "X", discord = string.rep("|", 60), mainToon = "MainA", points = 1, credits = 2,
        tier = "Friendly", prestige = 0, lifetimePoints = 3, lifetimeCredits = 4, lastDonationDate = "2026-10-01", lastUpdated = 5 }
    local encMsg = ns.CreditsMember_EncodeBal(longRec, 0, wallClock)
    check("An over-long Discord name is dropped so the message still fits", encMsg and #PFX + #encMsg <= 255)

    -- ---- officer push ---------------------------------------------------------------
    setup()
    ns.Credits_LinkAlt("Member1", "MainA")      -- officer edit -> push (timers run instantly in the harness)
    check("An officer edit pushes the new balance to the account's online alt",
        #sentTo("Member1", "BALDATA") >= 1)
    check("...but never to other officers (they hold the ledger) or the guild leader",
        #sentTo("Officer2", "BALDATA") == 0 and #sentTo("GLeader", "BALDATA") == 0)
    check("...and never over the GUILD channel", (function()
        for _, e in ipairs(outboxLog) do if e.channel == "GUILD" and e.text:match("^BAL") then return false end end
        return true end)())
    outboxLog = {}
    ns.CreditsMember_Flush()
    check("Nothing is pushed twice (pending is cleared after a flush)", #outboxLog == 0)

    setup()
    guildRosterEntries[4].online = false
    ns.UpdateGuildRosterCache()
    ns.Credits_LinkAlt("Member1", "MainA")
    check("An offline member is skipped (they pull at next login)", #sentTo("Member1", "BALDATA") == 0)

    setup()
    currentPlayerName = "Member1"
    ns.CreditsMember_NoteChanged({ "MainA" })
    ns.CreditsMember_Flush()
    check("A non-officer never pushes", #outboxLog == 0)

    -- ---- Refresh button ----------------------------------------------------------------
    setup()
    currentPlayerName = "Member1"
    local ok1, msg1 = ns.CreditsMember_Refresh()
    check("Refresh asks officers", ok1 == true and msg1 ~= nil)
    local asked = 0
    for _, e in ipairs(outboxLog) do
        if e.text == "MYBALREQ|1" and e.channel == "WHISPER" then asked = asked + 1 end
    end
    check("...at most 2 of them", asked == 2)
    outboxLog = {}
    local ok2 = ns.CreditsMember_Refresh()
    check("A second Refresh inside 5 minutes is refused and sends nothing", ok2 == false and #outboxLog == 0)
    wallClock = wallClock + 301
    check("...allowed again after the cooldown", ns.CreditsMember_Refresh() == true)

    setup()
    currentPlayerName = "Officer1"
    check("Officers are told there is nothing to refresh", ns.CreditsMember_Refresh() == false)

    setup()
    currentPlayerName = "Member1"
    for _, e in ipairs(guildRosterEntries) do if e.rankIndex ~= 5 then e.online = false end end
    ns.UpdateGuildRosterCache()
    wallClock = wallClock + 301
    local ok3, msg3 = ns.CreditsMember_Refresh()
    check("With no officer online, Refresh says so and does not start the cooldown",
        ok3 == false and msg3:find("No officer", 1, true) ~= nil)
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
