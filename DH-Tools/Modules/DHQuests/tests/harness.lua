-- DH-Quests test harness (Milestone 6).
-- Loads the ACTUAL DHQuests module files (Core, ClassQuestIDs, Scan, Sync)
-- against a mocked WoW API, mirroring DH-Air's own tests\harness.lua
-- pattern. Board.lua is UI-template heavy and is NOT loaded here - same
-- exclusion DH-Air's own harness makes for its Minimap.lua/Config.lua;
-- covered by manual/in-game review instead.
--
-- DH-Tools' own Core.lua/Config.lua/Minimap.lua are ALSO not loaded - this
-- harness re-implements a minimal DHTools mock (RegisterModule/
-- SetModuleEnabled/IsModuleEnabled/Print) instead, deliberately, so this
-- suite tests DHQuests' own logic in isolation. That's also a direct
-- expression of the module's "standalone-optionality" architecture
-- decision (see claude\DH-Quests\PROFILE.md) - if DHQuests is ever spun
-- off standalone, this harness should need no changes beyond the mock.

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

local timers = {} -- pending C_Timer callbacks, in creation order
_G.C_Timer = {
    NewTimer = function(seconds, fn)
        local handle = { cancelled = false, fn = fn, seconds = seconds }
        function handle:Cancel() self.cancelled = true end
        table.insert(timers, handle)
        return handle
    end
}

-- Fires the oldest still-pending (not cancelled) timer, simulating time
-- passing - same idiom as DH-Air's harness.lua.
local function fireNextTimer()
    for i = 1, #timers do
        local h = timers[i]
        if not h.cancelled then
            table.remove(timers, i)
            h.fn()
            return true
        end
    end
    return false
end

-- Same CreateFrame mock as DH-Air's harness.lua (RegisterEvent/SetScript/
-- Fire) - Core.lua's ns.frame needs exactly this surface.
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

_G.UnitName = function(unit)
    if unit == "player" then return "TestChar" end
    return nil
end

local inGuild = false
_G.IsInGuild = function() return inGuild end
_G.GuildRoster = function() end
_G.C_GuildInfo = { GuildRoster = function() end }

-- k-0019 (2026-09-14): mirrors DH-Bavin's own harness mock (added
-- 2026-08-06 for its own k-0019 fix) - defaults to the real target guild
-- ("Death Happens", matching Core.lua's hardcoded TARGET_GUILD_NAME) so
-- every existing test that sets `inGuild = true` keeps passing
-- unmodified. A test exercising the off-guild/wrong-guild case sets this
-- to something else.
local currentGuildName = "Death Happens"
_G.GetGuildInfo = function(unit)
    if unit ~= "player" then return nil end
    return currentGuildName
end

-- guildRosterEntries: ordered list of { name=, level=, online= }.
local guildRosterEntries = {}
_G.GetNumGuildMembers = function() return #guildRosterEntries end
_G.GetGuildRosterInfo = function(i)
    local e = guildRosterEntries[i]
    if not e then return nil end
    -- Matches Core.lua's assumed positions: name, rank, rankIndex, level,
    -- class, zone, note, officernote, isOnline (level=4th, online=9th).
    return e.name, nil, nil, e.level, nil, nil, nil, nil, (e.online ~= false)
end

-- questLogEntries: ordered list of { title=, level=, questTag=, isHeader=, questID= }.
-- Matches Scan.lua's confirmed GetQuestLogTitle field order: title, level,
-- questTag, isHeader, isCollapsed, isComplete, <unused>, questID.
local questLogEntries = {}
_G.GetNumQuestLogEntries = function() return #questLogEntries end
_G.GetQuestLogTitle = function(i)
    local e = questLogEntries[i]
    if not e then return nil end
    return e.title, e.level, e.questTag, e.isHeader or false, false, false, 1, e.questID or 0
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

-- Minimal re-implementation of DH-Tools' own module registry
-- (RegisterModule/SetModuleEnabled/IsModuleEnabled), matching real
-- Core.lua's contract closely enough for DHQuests' own RegisterModule call
-- and DHTools.IsModuleEnabled("quests") checks to behave the same as they
-- would wired into the real DH-Tools addon. See file header for why the
-- real DH-Tools\Core.lua isn't loaded instead.
local registeredModules = {}
local moduleEnabled = {}
_G.DHTools = {
    Print = function(msg) table.insert(printLog, msg) end,
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
    Config_Open = nil, -- guarded with `if DHTools.Config_Open then` in Core.lua
}

--------------------------------------------------------------------------
-- Load the real DHQuests files (Board.lua excluded - see header)
--------------------------------------------------------------------------

local ADDON_ROOT = "C:\\AIProjects-NOSYNC\\WoW\\src\\DH-Tools\\Modules\\DHQuests\\"
local FILES = { "Core.lua", "ClassQuestIDs.lua", "Scan.lua", "Sync.lua" }

for _, filename in ipairs(FILES) do
    local chunk, err = loadfile(ADDON_ROOT .. filename)
    if not chunk then
        error("Failed to load " .. filename .. ": " .. tostring(err))
    end
    chunk()
end

local ns = _G.DHQuests

-- Real bootstrapping (DH-Tools' own Core.lua, PLAYER_LOGIN handler) calls
-- ActivateEnabledModules(), which unconditionally fires OnEnable for every
-- module that's enabled (by default or saved state) - NOT the same
-- transition-gated logic as a later runtime SetModuleEnabled(key, true)
-- toggle (which only fires OnEnable on an actual false->true change).
-- Mirrored directly here rather than via the mock's SetModuleEnabled, so
-- ns.db exists before PLAYER_LOGIN fires, same order as the real addon.
if registeredModules["quests"] and registeredModules["quests"].OnEnable then
    moduleEnabled["quests"] = true
    registeredModules["quests"].OnEnable()
end

-- Simulate PLAYER_LOGIN (Sync_Init, RequestGuildRoster, QueueRescan).
ns.frame:Fire("PLAYER_LOGIN")

--------------------------------------------------------------------------
-- Test helpers
--------------------------------------------------------------------------

local function resetState()
    outboxLog, printLog, timers = {}, {}, {}
    inGuild = false
    guildRosterEntries = {}
    questLogEntries = {}
    ns.peers = {}
    ns.syncBuffers = {}
    ns.guildRoster = {}
    DHQuestsDB.settings.shareEnabled = true
    DHQuestsDB.settings.categories[ns.CATEGORY_INDIVIDUAL] = true
    DHQuestsDB.settings.categories[ns.CATEGORY_GROUP] = true
    DHQuestsDB.settings.categories[ns.CATEGORY_ELITE] = true
    DHQuestsDB.settings.categories[ns.CATEGORY_CLASS] = true
    DHQuestsDB.cache = {}
end

-- Every outbound message sent to `msgType`, matched on the leading
-- "TYPE|" or bare "TYPE" text - used to assert what was/wasn't broadcast.
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
-- Section 1: Category classification (Scan.lua)
--------------------------------------------------------------------------
print("== Category classification ==")
resetState()

check("No tag, not a class quest -> Individual",
    ns.ClassifyQuest(999999, nil) == ns.CATEGORY_INDIVIDUAL)
check("Group tag -> Group", ns.ClassifyQuest(999998, "Group") == ns.CATEGORY_GROUP)
check("Elite tag -> Elite", ns.ClassifyQuest(999997, "Elite") == ns.CATEGORY_ELITE)
check("Unrecognized tag (e.g. Raid) falls back to Individual for v1",
    ns.ClassifyQuest(999996, "Raid") == ns.CATEGORY_INDIVIDUAL)

-- 1740 = "The Orb of Soran'ruk", a real Warlock class quest confirmed
-- in ClassQuestIDs.lua and verified against Loopi's actual quest log
-- (see claude\DH-Quests\STATUS.md's 2026-07-18 bug-fix entry).
check("Known class quest ID (1740) -> Class even with no tag",
    ns.ClassifyQuest(1740, nil) == ns.CATEGORY_CLASS)
check("Known class quest ID -> Class even overriding a Group tag (checked before questTag)",
    ns.ClassifyQuest(1740, "Group") == ns.CATEGORY_CLASS)
check("ClassQuestIDs.lua actually loaded a substantial table (not empty/stubbed)",
    (function() local n = 0 for _ in pairs(ns.CLASS_QUEST_IDS) do n = n + 1 end return n end)() > 800)

--------------------------------------------------------------------------
-- Section 2: Quest log scanning (Scan.lua)
--------------------------------------------------------------------------
print("== Quest log scanning ==")
resetState()
-- Synthetic questIDs use a 9000000+ range deliberately far outside any
-- real Classic Era quest ID, so they can't accidentally collide with a
-- real entry in the 879-quest ClassQuestIDs.lua allowlist. (100 and 3001 -
-- simpler-looking IDs originally used here - genuinely DID collide with
-- real class quests and made these checks fail; caught by actually
-- running this harness against real Lua, not by inspection.)
questLogEntries = {
    { title = "Zone Header", isHeader = true, questID = 0 },
    { title = "A Individual Quest", level = 10, questTag = nil, questID = 9000100 },
    { title = "A Group Quest", level = 15, questTag = "Group", questID = 9000101 },
    { title = "The Orb of Soran'ruk", level = 24, questTag = nil, questID = 1740 },
}
local scan = ns.ScanQuestLog()
local count = 0
for _ in pairs(scan) do count = count + 1 end
check("Header row and questID=0 are skipped", count == 3)
check("Individual quest classified correctly", scan[9000100] and scan[9000100].category == ns.CATEGORY_INDIVIDUAL)
check("Group quest classified correctly", scan[9000101] and scan[9000101].category == ns.CATEGORY_GROUP)
check("Class quest (via allowlist) classified correctly", scan[1740] and scan[1740].category == ns.CATEGORY_CLASS)
check("Quest level captured", scan[1740] and scan[1740].level == 24)
check("Quest title captured", scan[9000100] and scan[9000100].title == "A Individual Quest")

--------------------------------------------------------------------------
-- Section 3: Share-toggle gating (CategoryShared)
--------------------------------------------------------------------------
print("== Share-toggle gating ==")
resetState()

check("All categories shared by default", ns.CategoryShared(ns.CATEGORY_INDIVIDUAL)
    and ns.CategoryShared(ns.CATEGORY_GROUP) and ns.CategoryShared(ns.CATEGORY_ELITE)
    and ns.CategoryShared(ns.CATEGORY_CLASS))

DHQuestsDB.settings.shareEnabled = false
check("Master toggle off blocks every category", not ns.CategoryShared(ns.CATEGORY_INDIVIDUAL))
DHQuestsDB.settings.shareEnabled = true

DHQuestsDB.settings.categories[ns.CATEGORY_ELITE] = false
check("A single category toggle off only blocks that category",
    not ns.CategoryShared(ns.CATEGORY_ELITE) and ns.CategoryShared(ns.CATEGORY_GROUP))

--------------------------------------------------------------------------
-- Section 4: Broadcast gating (Sync_BroadcastQuest / Sync_BroadcastQuestGone)
--------------------------------------------------------------------------
print("== Broadcast gating ==")
resetState()

ns.Sync_BroadcastQuest(200, { title = "Not In Guild", level = 5, category = ns.CATEGORY_GROUP })
check("Not in a guild: nothing is sent at all", #outboxLog == 0)

inGuild = true
ns.Sync_BroadcastQuest(200, { title = "Shared Quest", level = 5, category = ns.CATEGORY_GROUP })
local sent = outboxOfType("QUEST")
check("In guild + category shared: a QUEST message is sent", #sent == 1)
check("Payload format is questID:category:level:title",
    sent[1] and sent[1].text == "QUEST|200:Group:5:Shared Quest")
check("QUEST is broadcast to GUILD", sent[1] and sent[1].channel == "GUILD")

outboxLog = {}
DHQuestsDB.settings.categories[ns.CATEGORY_GROUP] = false
ns.Sync_BroadcastQuest(201, { title = "Unshared Quest", level = 5, category = ns.CATEGORY_GROUP })
check("Category toggled off: nothing is sent for that category", #outboxOfType("QUEST") == 0)
DHQuestsDB.settings.categories[ns.CATEGORY_GROUP] = true

outboxLog = {}
ns.Sync_BroadcastQuestGone(200)
check("QUESTGONE sent while in guild", #outboxOfType("QUESTGONE") == 1)

--------------------------------------------------------------------------
-- Section 5: Chunk/encode/decode round-trip via SYNCREQ/SYNCDATA
--------------------------------------------------------------------------
print("== SYNCREQ/SYNCDATA round-trip ==")
resetState()
inGuild = true

-- Deliberately includes a comma in a title ("The Manor, Ravenholdt" was
-- the real-world case that exposed the chunking bug fixed in M2 - see
-- claude\DH-Quests\STATUS.md) and enough entries to likely span more than
-- one MAX_CHUNK_CHARS=200 chunk, to exercise reassembly, not just a
-- single-message shortcut.
questLogEntries = {
    { title = "The Manor, Ravenholdt", level = 44, questTag = "Elite", questID = 9003001 },
    { title = "A Fairly Long Quest Title About Collecting Boar Tusks", level = 12, questTag = nil, questID = 9003002 },
    { title = "Another Fairly Long Quest Title About Slaying Murlocs", level = 14, questTag = "Group", questID = 9003003 },
    { title = "Yet Another Long Title Concerning The Local Wildlife", level = 16, questTag = nil, questID = 9003004 },
    { title = "The Orb of Soran'ruk", level = 24, questTag = nil, questID = 1740 },
    { title = "An Unshared Elite Quest", level = 30, questTag = "Elite", questID = 9003005 },
}
DHQuestsDB.settings.categories[ns.CATEGORY_ELITE] = false -- 9003001 and 9003005 should NOT round-trip

-- Simulate a peer's SYNCREQ arriving - our client should reply with one or
-- more WHISPERed SYNCDATA chunks to them. 2026-08-04: chunks after the
-- first are now staggered via C_Timer (see Sync.lua's
-- CHUNK_SEND_DELAY_SECONDS comment - a Loopi-reported fix for guild-scale
-- addon-message throttling silently dropping chunks), so drain every
-- pending timer to collect the rest before asserting on the full set.
ns.Sync_OnAddonMessage("DHQuestsV1", "SYNCREQ", "GUILD", "Requester")
local syncData = outboxOfType("SYNCDATA")
check("SYNCREQ triggers at least one SYNCDATA reply", #syncData > 0)
check("SYNCDATA is WHISPERed back, not broadcast", syncData[1] and syncData[1].channel == "WHISPER")
check("SYNCDATA is addressed to the requester", syncData[1] and syncData[1].target == "Requester")
while fireNextTimer() do end
syncData = outboxOfType("SYNCDATA")

-- Now feed those exact captured chunks back through Sync_OnAddonMessage as
-- if THEY were sent by a different peer ("PeerB") - this is the receiving/
-- reassembly half of the round-trip.
for _, entry in ipairs(syncData) do
    ns.Sync_OnAddonMessage("DHQuestsV1", entry.text, "WHISPER", "PeerB")
end

local peerB = ns.peers["PeerB"]
check("Peer store now has an entry for PeerB", peerB ~= nil)
check("Shared Individual quest round-tripped correctly",
    peerB and peerB[9003002] and peerB[9003002].title == "A Fairly Long Quest Title About Collecting Boar Tusks"
    and peerB[9003002].category == ns.CATEGORY_INDIVIDUAL and peerB[9003002].level == 12)
check("Shared Group quest round-tripped correctly",
    peerB and peerB[9003003] and peerB[9003003].category == ns.CATEGORY_GROUP)
check("Elite quest (9003001) correctly excluded while Elite sharing is off",
    peerB and peerB[9003001] == nil)

-- Re-run with Elite shared, to confirm the comma-in-title case specifically
-- (isolated from the "should it be excluded" gating check above).
DHQuestsDB.settings.categories[ns.CATEGORY_ELITE] = true
outboxLog = {}
ns.Sync_OnAddonMessage("DHQuestsV1", "SYNCREQ", "GUILD", "Requester2")
while fireNextTimer() do end
local syncData2 = outboxOfType("SYNCDATA")
ns.peers["PeerC"] = nil
for _, entry in ipairs(syncData2) do
    ns.Sync_OnAddonMessage("DHQuestsV1", entry.text, "WHISPER", "PeerC")
end
local peerC = ns.peers["PeerC"]
check("Comma-in-title entry present once Elite is shared",
    peerC and peerC[9003001] ~= nil)
check("Comma-in-title text is exactly intact, not truncated/corrupted at the comma",
    peerC and peerC[9003001] and peerC[9003001].title == "The Manor, Ravenholdt")
check("Unshared category (Elite was off during the FIRST sync) correctly excluded that quest",
    peerB and peerB[9003005] == nil)

--------------------------------------------------------------------------
-- Section 6: QUEST/QUESTGONE deltas + own-echo suppression
--------------------------------------------------------------------------
print("== QUEST/QUESTGONE deltas ==")
resetState()
inGuild = true

ns.Sync_OnAddonMessage("DHQuestsV1", "QUEST|1234:Group:20:Test Quest", "GUILD", "PeerD")
check("Incoming QUEST delta is stored", ns.peers["PeerD"] and ns.peers["PeerD"][1234] ~= nil)
check("Stored title/category/level match the message",
    ns.peers["PeerD"][1234].title == "Test Quest" and ns.peers["PeerD"][1234].category == "Group"
    and ns.peers["PeerD"][1234].level == 20)
check("Status defaults to offline when the roster cache doesn't know this peer",
    ns.peers["PeerD"][1234].status == "offline")

ns.Sync_OnAddonMessage("DHQuestsV1", "QUESTGONE|1234", "GUILD", "PeerD")
check("QUESTGONE removes the entry", ns.peers["PeerD"][1234] == nil)

ns.Sync_OnAddonMessage("DHQuestsV1", "QUEST|999:Group:10:Echo", "GUILD", "TestChar")
check("Our own echo (sender == UnitName('player')) is ignored", ns.peers["TestChar"] == nil)

--------------------------------------------------------------------------
-- Section 7: Local quest-change detection & debounce (Milestone 3)
--------------------------------------------------------------------------
print("== Local quest-change detection & debounce ==")
resetState()
inGuild = true
DHQuestsDB.cache = {}

questLogEntries = { { title = "First Quest", level = 5, questTag = nil, questID = 4001 } }
ns.frame:Fire("QUEST_LOG_UPDATE")
check("A quest-log event schedules a pending rescan timer", #timers == 1)

fireNextTimer()
check("Firing the timer broadcasts the new quest",
    #outboxOfType("QUEST") == 1 and outboxOfType("QUEST")[1].text:find("4001", 1, true) ~= nil)
check("The cache now reflects the scanned state", DHQuestsDB.cache[4001] ~= nil)

-- Rapid-fire debounce: three quick changes should collapse into a single
-- broadcast reflecting only the FINAL state, not three separate broadcasts.
outboxLog = {}
questLogEntries = { { title = "First Quest", level = 5, questTag = nil, questID = 4001 },
    { title = "Second Quest", level = 6, questTag = nil, questID = 4002 } }
ns.frame:Fire("QUEST_LOG_UPDATE")
questLogEntries = { { title = "First Quest", level = 5, questTag = nil, questID = 4001 },
    { title = "Second Quest", level = 6, questTag = nil, questID = 4002 },
    { title = "Third Quest", level = 7, questTag = nil, questID = 4003 } }
ns.frame:Fire("QUEST_LOG_UPDATE")
ns.frame:Fire("QUEST_ACCEPTED")
fireNextTimer()
check("Only quest 4002's broadcast fires once despite two intermediate events (debounce collapsed them)",
    #outboxOfType("QUEST") == 2) -- 4002 (new) and 4003 (new); 4001 unchanged from the prior rescan

-- Turning in a quest (removed from the log) broadcasts QUESTGONE, since it
-- was previously shared.
outboxLog = {}
questLogEntries = { { title = "Second Quest", level = 6, questTag = nil, questID = 4002 },
    { title = "Third Quest", level = 7, questTag = nil, questID = 4003 } }
ns.frame:Fire("QUEST_LOG_UPDATE")
fireNextTimer()
check("Dropping a previously-shared quest sends QUESTGONE",
    #outboxOfType("QUESTGONE") == 1 and outboxOfType("QUESTGONE")[1].text == "QUESTGONE|4001")

-- Disabling the module should stop QueueRescan from scheduling anything.
outboxLog, timers = {}, {}
_G.DHTools.SetModuleEnabled("quests", false)
questLogEntries = {}
ns.frame:Fire("QUEST_LOG_UPDATE")
check("Disabled module: QueueRescan is a no-op (no timer scheduled)", #timers == 0)
_G.DHTools.SetModuleEnabled("quests", true)

--------------------------------------------------------------------------
-- Section 8: Guild roster cache - status stamping & pruning departed peers
--------------------------------------------------------------------------
print("== Guild roster cache ==")
resetState()
inGuild = true

ns.Sync_OnAddonMessage("DHQuestsV1", "QUEST|5001:Group:10:Alice Quest", "GUILD", "Alice")
ns.Sync_OnAddonMessage("DHQuestsV1", "QUEST|5002:Group:12:Bob Quest", "GUILD", "Bob")
check("Both peers present before any roster update", ns.peers["Alice"] and ns.peers["Bob"])

guildRosterEntries = { { name = "Alice", level = 30, online = true } } -- Bob no longer a member
ns.UpdateGuildRosterCache()
check("Departed peer (Bob) is pruned entirely", ns.peers["Bob"] == nil)
check("Remaining peer (Alice) is kept", ns.peers["Alice"] ~= nil)
check("Alice's quest entry is stamped online", ns.peers["Alice"][5001].status == "online")
check("ns.guildRoster captured Alice's character level", ns.guildRoster["Alice"].level == 30)

guildRosterEntries = { { name = "Alice", level = 30, online = false } }
ns.UpdateGuildRosterCache()
check("Alice going offline updates her existing quest entry's status",
    ns.peers["Alice"][5001].status == "offline")

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
