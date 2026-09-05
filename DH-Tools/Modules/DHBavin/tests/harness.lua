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

local ADDON_ROOT = "C:\\AIProjects\\WoW\\src\\DH-Tools\\Modules\\DHBavin\\"
local FILES = { "Core.lua", "Sync.lua", "ItemPoints.lua" }

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
-- CanManageEditors: any rank<=3 officer, or "Loopidot".
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
check("A rank-0 guild leader who isn't rank<=3-or-Loopidot... actually IS rank<=3, so CAN manage editors",
    ns.CanManageEditors() == true)

-- An officer (rank<=3, not Bavin/Loopidot) can manage editors but not
-- the recipient - the two gates are independent.
currentPlayerName = "Officer1"
check("A rank<=3 officer cannot manage the recipient", ns.CanManageRecipient() == false)
check("...but CAN manage editors", ns.CanManageEditors() == true)
check("SetEditors succeeds for a rank<=3 officer",
    ns.SetEditors({ "Officer1" }) == true and #ns.db.editors == 1)

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
check("Bavin cannot manage editors just by being Bavin (not rank<=3, not Loopidot)",
    ns.CanManageEditors() == false)

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
-- (CanSetRecipientName: Bavin/Loopidot by name; CanSetEditorsName:
-- rank<=3 or Loopidot) - a rank-0 guild leader who isn't Bavin/Loopidot
-- can no longer set the recipient remotely either, same tightening as
-- the local gate in Section 2.
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
ns.Sync_OnAddonMessage("DHBavinV4", "EDITORS|Officer1", "GUILD", "Grunt1")
check("An EDITORS message from a rank>3 sender is ignored", #ns.db.editors == 0)

ns.Sync_OnAddonMessage("DHBavinV4", "EDITORS|Officer1", "GUILD", "Officer1")
check("An EDITORS message from a verified rank<=3 sender is accepted",
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
