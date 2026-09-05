-- DH-Air test harness.
-- Loads the ACTUAL addon Lua files (Core, Queue, Invite, Summon, Commands)
-- against a mocked WoW API so the real logic can be exercised outside the game.
-- Minimap.lua and Config.lua are UI-template heavy and are not loaded here;
-- they're covered by manual/in-game review instead.

local PASS, FAIL = 0, 0
local failures = {}

local function check(name, cond, detail)
    if cond then
        PASS = PASS + 1
        -- print("  PASS: " .. name)
    else
        FAIL = FAIL + 1
        table.insert(failures, name .. (detail and (" -- " .. detail) or ""))
        print("  FAIL: " .. name .. (detail and (" -- " .. detail) or ""))
    end
end

--------------------------------------------------------------------------
-- Mock WoW API
--------------------------------------------------------------------------

local chatLog = {}        -- { {msg=, channel=} }
local printLog = {}       -- addon Print() output
local invitedPlayers = {} -- name -> count
local currentTarget = nil
local castLog = {}        -- list of spell names cast
local castShouldFail = false
local groupRoster = {}    -- ordered list of names
local inRaid = false
local inGroup = false
local inGuild = false
local timers = {}         -- pending C_Timer callbacks, in creation order
local gameTime = 1000
local wallClock = 1000 -- k-0033: real wall-clock seconds, independent of gameTime -
                        -- production code now uses time() (not GetTime()) for anything
                        -- that must survive a relog, e.g. Roster.lua's lastSeen

_G.GetTime = function() return gameTime end
_G.time = function() return wallClock end

_G.DEFAULT_CHAT_FRAME = {
    AddMessage = function(self, msg) table.insert(printLog, msg) end
}

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

_G.C_Timer = {
    NewTimer = function(seconds, fn)
        local handle = { cancelled = false, fn = fn, seconds = seconds }
        function handle:Cancel() self.cancelled = true end
        table.insert(timers, handle)
        return handle
    end
}

-- Fires the oldest still-pending (not cancelled) timer, simulating time passing.
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

_G.IsInRaid = function() return inRaid end
_G.IsInGroup = function() return inGroup or inRaid end
_G.IsInGuild = function() return inGuild end

local isLeader, isAssistant = false, false
_G.UnitIsGroupLeader = function(unit) if unit == "player" then return isLeader end return false end
_G.UnitIsGroupAssistant = function(unit) if unit == "player" then return isAssistant end return false end

local guildRosterNames = {} -- test-controllable list: plain "Name" strings (implies online, no rank) or {name=,online=,rankIndex=} tables
_G.GetNumGuildMembers = function() return #guildRosterNames end
_G.GetGuildRosterInfo = function(i)
    local entry = guildRosterNames[i]
    if not entry then return nil end
    if type(entry) == "string" then
        return entry, nil, nil, nil, nil, nil, nil, nil, true
    end
    -- 3rd return value is rankIndex (M3) - real GetGuildRosterInfo returns
    -- it there too; UpdateGuildRosterCache (Core.lua) captures it.
    return entry.name, nil, entry.rankIndex, nil, nil, nil, nil, nil, (entry.online ~= false)
end
_G.GuildRoster = function() end
_G.C_GuildInfo = { GuildRoster = function() end }
_G.GetNumGroupMembers = function() return #groupRoster end

-- Controllable player identity - defaults to "TestChar" like before.
-- Made a variable (rather than the old hardcoded literal) so the new
-- 2026-08-05 account-wide author-admin override can be exercised
-- end-to-end: simulating PLAYER_LOGIN as an actual author character name
-- requires UnitName("player") to actually reflect it.
local currentPlayerName = "TestChar"
_G.UnitName = function(unit)
    if unit == "player" then return currentPlayerName end
    local idx = tonumber(unit:match("^party(%d+)$") or unit:match("^raid(%d+)$"))
    if idx then return groupRoster[idx] end
    if unit == "target" then return currentTarget end
    return nil
end

-- Booty Bay world-buff-mode test mock (2026-09-05): maps a unit token
-- (e.g. "party1") to the "zone name" C_Map.GetMapInfo should report for
-- it. A unit with no entry here correctly exercises the production code's
-- fail-open path - same as real Classic's C_Map behavior being UNVERIFIED
-- for a remote unit (see Invite.lua's header comment on this feature).
local unitZoneMock = {}
_G.C_Map = {
    GetBestMapForUnit = function(unit) return unitZoneMock[unit] end,
    GetMapInfo = function(mapID) return mapID and { name = mapID } or nil end,
}

_G.TargetUnit = function(unit)
    local idx = tonumber(unit:match("^party(%d+)$") or unit:match("^raid(%d+)$"))
    if idx and groupRoster[idx] then
        currentTarget = groupRoster[idx]
    else
        currentTarget = nil
    end
end

_G.UnitExists = function(unit)
    if unit == "target" then return currentTarget ~= nil end
    return false
end

_G.CastSpellByName = function(name)
    if castShouldFail then
        error("mock cast failure")
    end
    table.insert(castLog, name)
end

_G.GetSpellInfo = function(spellID)
    return spellID -- in tests we pass the spell name directly as "spellID"
end

_G.SendChatMessage = function(msg, channel, language, target)
    table.insert(chatLog, { msg = msg, channel = channel, target = target })
end

local promoteAssistantLog = {}
local promoteLeaderLog = {}

_G.C_PartyInfo = {
    InviteUnit = function(name)
        invitedPlayers[name] = (invitedPlayers[name] or 0) + 1
    end,
    PromoteToAssistant = function(name)
        table.insert(promoteAssistantLog, name)
    end,
    PromoteToLeader = function(name)
        table.insert(promoteLeaderLog, name)
    end,
}

_G.InCombatLockdown = function() return false end

_G.InviteUnit = function(name)
    invitedPlayers[name] = (invitedPlayers[name] or 0) + 1
end

_G.GetBuildInfo = function() return "1.15.7", "12345", "Jan 1 2026", 11507 end

local shardCount = 10 -- test-controllable Soul Shard count
_G.GetItemCount = function(itemID)
    if itemID == 6265 then return shardCount end
    return 0
end

-- Minimal slash command table so Commands.lua can register without error.
_G.SlashCmdList = {}

--------------------------------------------------------------------------
-- DH-Tools mock (2026-08-20 DH-Air merge) - Core.lua now runs as a
-- DH-Tools module and calls DHTools.IsModuleEnabled/IsAuthorAccount/
-- RegisterModule. DH-Tools' own Core.lua is NOT loaded here (same
-- reasoning DHBavin/DHQuests' own harnesses give); this is a minimal
-- re-implementation of its module registry, mirroring DHBavin's
-- tests\harness.lua mock exactly.
--------------------------------------------------------------------------

local registeredModules = {}
-- Forced on regardless of Core.lua's own registered `default` - this
-- harness tests DH-Air's OWN functionality, which needs to run
-- independent of whatever DH-Tools ships the module enabled/disabled
-- by default (2026-08-31: default flipped to false suite-wide, air
-- included - see Core.lua's RegisterModule comment). Without this,
-- every IsModuleEnabled("air") gate in Core.lua reads false and most
-- of the suite silently no-ops.
local moduleEnabled = { air = true }
-- Controllable mock for DHTools.IsAuthorAccount - real Core.lua derives
-- this from DHToolsAccountDB.isAuthorAccount, set once at DH-Tools' own
-- PLAYER_LOGIN. No current DH-Air test flips this (the dedicated
-- author-override scenarios moved with the mechanism - see Core.lua's
-- "Author account admin" comment and DH-Air-Merge-Design.md decision 4)
-- but it's here so HasPermission's `DHTools.IsAuthorAccount and
-- DHTools.IsAuthorAccount()` check has something real to call.
local authorAccountFlag = false
_G.DHTools = {
    Print = function(msg) table.insert(printLog, msg) end,
    IsAuthorAccount = function() return authorAccountFlag end,
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
}

--------------------------------------------------------------------------
-- Load the real addon files
--------------------------------------------------------------------------

-- 2026-08-20 DH-Air merge: files now live under DH-Tools' own Modules\
-- folder and load as part of the "DH-Tools" addon, not a standalone
-- "DH-Air" one - ADDON_NAME here matches what a real ADDON_LOADED event
-- now carries (see Core.lua's own comment on this).
local ADDON_ROOT = "C:\\AIProjects\\WoW\\src\\DH-Tools\\Modules\\DHAir\\"
local ADDON_NAME = "DH-Tools"
local DHAir = {}

local FILES = { "Core.lua", "Destinations.lua", "Queue.lua", "Roster.lua", "Invite.lua", "Leadership.lua", "Summon.lua", "Commands.lua" }

for _, filename in ipairs(FILES) do
    local chunk, err = loadfile(ADDON_ROOT .. filename)
    if not chunk then
        error("Failed to load " .. filename .. ": " .. tostring(err))
    end
    chunk(ADDON_NAME, DHAir)
end

-- Provide a stub Config_Open since Config.lua isn't loaded in this harness.
DHAir.Config_Open = function(self) table.insert(printLog, "[stub] Config opened") end
DHAir.Minimap_UpdateIcon = nil -- guarded with `if` in Commands.lua

-- Simulate ADDON_LOADED + PLAYER_LOGIN to initialize DHAir.db (mirrors real startup).
DHAir.frame:Fire("ADDON_LOADED", ADDON_NAME)
DHAir.frame:Fire("PLAYER_LOGIN")

--------------------------------------------------------------------------
-- Test helpers
--------------------------------------------------------------------------

-- db.history was removed 2026-08-07 (@kb:air-requeue-always). "Was X
-- summoned?" now reads the flag on X's own queue entry, which is the only
-- record left - and, unlike history, one that no longer blocks a re-queue.
-- Returns nil when X isn't in the queue at all.
local function summonedFlag(name)
    for _, e in ipairs(DHAir.db.queue) do
        if DHAir:NormalizeName(e.name) == name then return e.summoned end
    end
    return nil
end

local function resetState()
    DHAir:QueueReset()
    chatLog, printLog, invitedPlayers, castLog, timers = {}, {}, {}, {}, {}
    currentTarget = nil
    castShouldFail = false
    groupRoster = {}
    inRaid, inGroup, inGuild = false, false, false
    unitZoneMock = {}
    shardCount = 10
    currentPlayerName = "TestChar"
    _G.DHAirDB.isAuthorAccount = nil
    guildRosterNames = {}
    DHAir.guildRoster = {}
    DHAir.db.active = true
    DHAir.db.paused = false
    DHAir.db.autoInvite = true
    DHAir.db.summonTimeout = 4 -- 2026-08-08: stuck-summon fallback only, was 30
    DHAir.db.minShards = 2
    DHAir.db.guildOnly = false
    DHAir.summonState = "idle"
    DHAir.currentSummon = nil
    DHAir.pendingCastUnit = nil
    DHAir.pendingOverrideName = nil
    DHAir.pendingOverrideAt = nil
    DHAir.failCount = 0
    DHAir.pausedForShards = false
    DHAir.db.roster = { summoners = {}, clickers = {} }
    isLeader, isAssistant = false, false
    promoteAssistantLog, promoteLeaderLog = {}, {}
    DHAir.db.autoPromote = true
    DHAir.db.autoPromoteGuildOnly = true
    -- 2026-08-03: TrySummonNext now requires a matching warlockDestination
    -- before it'll pick anyone (see Summon.lua's QueueNextAvailable).
    -- Default every test to a fixed, always-seeded destination so the many
    -- sections written before this feature existed keep exercising the
    -- SAME claim/retry/timeout mechanics they always did, rather than
    -- silently no-op'ing. Sections that specifically test the destination
    -- feature itself override this locally as needed.
    DHAir.db.warlockDestination = "stormwind"
end

-- Test-only helper: queues `name` (or tags an already-queued `name`) with
-- the shared default test destination above, so it's eligible for
-- TrySummonNext under the new mandatory destination match. Most of this
-- suite predates that feature and isn't testing it - this just keeps
-- existing scenarios working without every one of them having to
-- individually think about destinations.
local function QueueAddWithDest(name, destId)
    DHAir:QueueAdd(name) -- its own internal auto-trigger fires here and finds nothing yet (no destination set)
    DHAir:ApplyDestination(name, destId or "stormwind")
    DHAir:TrySummonNext() -- re-trigger now that the entry actually qualifies (mirrors SetMyDestination's own real-path fix)
end

local function countChannel(channel)
    local n = 0
    for _, entry in ipairs(chatLog) do
        if entry.channel == channel then n = n + 1 end
    end
    return n
end

--------------------------------------------------------------------------
-- Section 1: Core initialization
--------------------------------------------------------------------------
print("== Core initialization ==")
check("DHAirDB was created", type(_G.DHAirDB) == "table")
check("db.messages.raid exists with default text",
    DHAir.db.messages.raid.text == DHAir.DEFAULT_MESSAGE)
check("db.messages.guild defaults to disabled", DHAir.db.messages.guild.enabled == false)
check("db.messages.whisper defaults to enabled", DHAir.db.messages.whisper.enabled == true)
check("db.active defaults true", DHAir.db.active == true)
-- 2026-08-08: 30 -> 4. No longer "how long a summon takes" (the ritual
-- channel decides that now) - just the stuck-summon fallback.
check("db.summonTimeout defaults to 4", DHAir.db.summonTimeout == 4)
check("The fallback default sits inside the exported slider range",
    DHAir.db.summonTimeout >= DHAir.SUMMON_FALLBACK_MIN
    and DHAir.db.summonTimeout <= DHAir.SUMMON_FALLBACK_MAX)

-- Migration (2026-08-08): CopyDefaults only fills MISSING keys, so an
-- existing install would otherwise keep the old 30s value forever and
-- still feel like the addon that lost Chris most of a raid.
_G.DHAirDB.summonTimeout = 30 -- an existing install on the old default
DHAir.frame:Fire("ADDON_LOADED", ADDON_NAME)
check("An existing install's old 30s value is migrated down", DHAir.db.summonTimeout == 4)

_G.DHAirDB.summonTimeout = 90 -- someone who had dragged the old slider to max
DHAir.frame:Fire("ADDON_LOADED", ADDON_NAME)
check("Any value above the new ceiling is migrated down", DHAir.db.summonTimeout == 4)

_G.DHAirDB.summonTimeout = 6 -- a deliberate choice inside the new range
DHAir.frame:Fire("ADDON_LOADED", ADDON_NAME)
check("A deliberate in-range setting is left alone", DHAir.db.summonTimeout == 6)

_G.DHAirDB.summonTimeout = "thirty" -- corrupt/hand-edited SavedVariables
DHAir.frame:Fire("ADDON_LOADED", ADDON_NAME)
check("A non-numeric saved value is repaired, not carried into a C_Timer",
    DHAir.db.summonTimeout == 4)
check("db.minShards defaults to 2", DHAir.db.minShards == 2)
check("db.guildOnly defaults to true", DHAir.db.guildOnly == true)
check("db.destinations was seeded from DEFAULT_DESTINATIONS",
    #DHAir.db.destinations == #DHAir.DEFAULT_DESTINATIONS and #DHAir.db.destinations > 0)
check("Seeded destinations are copies, not the same tables as the defaults",
    DHAir.db.destinations[1] ~= DHAir.DEFAULT_DESTINATIONS[1])

--------------------------------------------------------------------------
-- Section 2: Queue logic
--------------------------------------------------------------------------
print("== Queue logic ==")
resetState()
DHAir.db.active = false -- isolate queue tests from the summon loop auto-triggering

check("QueueAdd Alice succeeds", DHAir:QueueAdd("Alice") == true)
check("Queue length is 1", #DHAir.db.queue == 1)
check("QueueAdd Alice again fails (dup)", DHAir:QueueAdd("Alice") == false)
check("Queue length still 1 after dup add", #DHAir.db.queue == 1)

DHAir:QueueAdd("Bob")
check("Queue length is 2 after Bob", #DHAir.db.queue == 2)
check("QueueNext returns Alice (FIFO order)", DHAir:QueueNext().name == "Alice")

check("QueueWaitingCount is 2 with nobody summoned", DHAir:QueueWaitingCount() == 2)

DHAir:QueueMarkSummoned("Alice")
check("Alice marked summoned", DHAir.db.queue[1].summoned == true)
check("QueueNext now returns Bob", DHAir:QueueNext().name == "Bob")
-- Board's "In queue:" counter (2026-08-07 raid report): summoned entries
-- stay in db.queue, so the waiting count must drop even though the raw
-- table length doesn't.
check("QueueWaitingCount drops to 1 after Alice is summoned", DHAir:QueueWaitingCount() == 1)
check("...while #db.queue still counts her", #DHAir.db.queue == 2)
DHAir:QueueMarkSummoned("Bob")
check("QueueWaitingCount is 0 once everyone is summoned", DHAir:QueueWaitingCount() == 0)
-- 2026-08-07 (@kb:air-requeue-always, design D4/D9). This block previously
-- asserted the OPPOSITE - that re-adding a summoned player fails - via
-- db.history. That table was account-wide SavedVariables nothing ever
-- cleared, so "already summoned this session" barred people permanently
-- and silently. An accidental re-summon is now the accepted trade.
check("Re-adding summoned Alice now SUCCEEDS (re-queue, D9)", DHAir:QueueAdd("Alice") == true)
check("...reusing her row rather than adding a second", #DHAir.db.queue == 2)
check("...clearing the summoned flag", DHAir.db.queue[1].summoned == false)
check("...so she counts as waiting again", DHAir:QueueWaitingCount() == 1)
check("...with a fresh queuedAt", DHAir.db.queue[1].queuedAt == gameTime)
check("db.history is gone entirely", DHAir.db.history == nil)

-- The old destination is where they went LAST time; silently reusing it
-- could auto-summon them somewhere they never asked for.
DHAir.db.queue[1].destination = "ironforge"
DHAir:QueueMarkSummoned("Alice")
DHAir:QueueAdd("Alice")
check("Re-queue clears the stale destination", DHAir.db.queue[1].destination == nil)

-- Someone still WAITING is a genuine duplicate and is still refused.
check("Re-adding a waiting player still fails (real dup)", DHAir:QueueAdd("Alice") == false)

-- note is local-only free text (design D6), stored on the entry.
DHAir:QueueAdd("Noted", "to SM")
check("QueueAdd stores the note on the entry",
    DHAir.db.queue[#DHAir.db.queue].note == "to SM")
check("A plain QueueAdd leaves note nil", DHAir.db.queue[2].note == nil)

DHAir:QueueReset()
check("Queue empty after reset", #DHAir.db.queue == 0)

-- Realm-suffix normalization
DHAir:QueueAdd("Charlie-Realm1")
check("Realm-suffixed name still matched by normalized dup check",
    DHAir:QueueAdd("Charlie-Realm1") == false)

--------------------------------------------------------------------------
-- Section 3: Invite / whisper pattern matching
--------------------------------------------------------------------------
print("== Invite / whisper matching ==")
resetState()
DHAir.db.active = false

-- 2026-08-15 (Chris, Config rework): invAutoInvite is a single unified
-- toggle - checked means invite AND queue-join together. This reverses
-- the 2026-08-05 decision (queue-joining used to be explicit-only, INV
-- never queued) on Chris's explicit call, discussed and confirmed.
DHAir:HandleWhisper("inv", "Dave")
check("'inv' triggers an invite", invitedPlayers["Dave"] == 1)
check("'inv' now also queues the player (invAutoInvite default true)",
    DHAir:QueueNext() ~= nil and DHAir:QueueNext().name == "Dave")

DHAir.db.invAutoInvite = false
DHAir:HandleWhisper("inv", "Grace")
check("invAutoInvite=false suppresses INV's invite entirely", invitedPlayers["Grace"] == nil)
check("...and its queue-join too (only Dave is queued)", #DHAir.db.queue == 1)
DHAir.db.invAutoInvite = true

resetState()
DHAir.db.active = false

DHAir:HandleWhisper("air", "Hope")
check("Whispered code phrase queues the sender",
    DHAir:QueueNext() ~= nil and DHAir:QueueNext().name == "Hope")
check("Whispered code phrase also auto-invites", invitedPlayers["Hope"] == 1)

DHAir:HandleWhisper("hey what's up", "Erin")
check("Casual whisper does NOT trigger invite", invitedPlayers["Erin"] == nil)

-- 2026-08-07 (@kb:air-prefix-trigger, design D2): whispers now PREFIX-match
-- the code phrase and keep the rest as a local-only note. The old exact-only
-- rule silently dropped "air pls" / "air to SM" - no invite, no queue entry,
-- no reply - which was the real cause of the delay reported after the raid.
-- Hope (above) is already at position 1, so these land at 2, 3 and 4.
DHAir:HandleWhisper("air to SM", "Tess")
local tess = DHAir.db.queue[2]
check("Trailing text no longer blocks the trigger", tess ~= nil and tess.name == "Tess")
check("...and is captured as a note", tess ~= nil and tess.note == "to SM")
check("...and still auto-invites", invitedPlayers["Tess"] == 1)

DHAir:HandleWhisper("AIR To SM", "Uma")
check("Note preserves the requester's own capitalization",
    DHAir.db.queue[3] ~= nil and DHAir.db.queue[3].note == "To SM")

DHAir:HandleWhisper("air", "Vic")
check("A bare phrase leaves the note nil",
    DHAir.db.queue[4] ~= nil and DHAir.db.queue[4].note == nil)

-- The phrase must be followed by whitespace or end-of-string, or a bare
-- prefix test would swallow unrelated words.
local beforeAirhead = #DHAir.db.queue
DHAir:HandleWhisper("airhead", "Wes")
check("'airhead' does NOT match the phrase 'air'", #DHAir.db.queue == beforeAirhead)
DHAir:HandleWhisper("fresh air please", "Xander")
check("A phrase in the MIDDLE does not match either", #DHAir.db.queue == beforeAirhead)

DHAir:HandleWhisper("INV", "Frank")
check("Matching is case-insensitive", invitedPlayers["Frank"] == 1)

-- recentInvites (the debounce table) is a module-local in Invite.lua, not
-- part of db, so it isn't touched by the resetState() calls above - Dave's
-- entry from the very first whisper in this section is still within the
-- window. invitedPlayers WAS just cleared by resetState(), so a blocked
-- debounce means Dave's entry here stays nil, not 1.
DHAir:HandleWhisper("inv", "Dave")
check("Debounce prevents duplicate invite within cooldown window", invitedPlayers["Dave"] == nil)

DHAir.db.phraseAutoInvite = false
local beforePhraseOff = #DHAir.db.queue
DHAir:HandleWhisper("air", "Ivy")
check("phraseAutoInvite=false suppresses the code phrase entirely (no invite, no queue)",
    invitedPlayers["Ivy"] == nil and #DHAir.db.queue == beforePhraseOff)
DHAir.db.phraseAutoInvite = true

-- Multiple, comma-separated phrases (2026-08-15, Chris's Config rework).
resetState()
DHAir.db.active = false
DHAir.db.codePhrase = "air, tp"
DHAir:HandleWhisper("tp", "Jonah")
check("A second comma-separated phrase also matches",
    DHAir:QueueNext() ~= nil and DHAir:QueueNext().name == "Jonah")
DHAir:HandleWhisper("AIR", "Karla")
check("...and the first phrase still matches too, case-insensitively",
    DHAir.db.queue[2] ~= nil and DHAir.db.queue[2].name == "Karla")
check("GetCodePhrases splits/trims correctly",
    #DHAir:GetCodePhrases() == 2 and DHAir:GetCodePhrases()[1] == "air" and DHAir:GetCodePhrases()[2] == "tp")
DHAir.db.codePhrase = "air"

--------------------------------------------------------------------------
-- Section 3b: Guild members only
--------------------------------------------------------------------------
print("== Guild members only ==")
resetState()
DHAir.db.active = false

-- Not in a guild at all: guildOnly should fail OPEN rather than block everyone.
DHAir.db.guildOnly = true
inGuild = false
DHAir:HandleWhisper("inv", "Nobody")
check("guildOnly with no guild at all fails open (still invites)", invitedPlayers["Nobody"] == 1)

-- In a guild, but roster cache not loaded yet: also fail open.
resetState()
DHAir.db.active = false
DHAir.db.guildOnly = true
inGuild = true
guildRosterNames = {} -- empty/unloaded roster
DHAir:UpdateGuildRosterCache()
DHAir:HandleWhisper("inv", "Early")
check("guildOnly with an empty/unloaded roster fails open", invitedPlayers["Early"] == 1)

-- In a guild, roster loaded, whisperer is NOT a member: should be ignored entirely.
resetState()
DHAir.db.active = false
DHAir.db.guildOnly = true
inGuild = true
guildRosterNames = { "Loopi", "Guildmate" }
DHAir:UpdateGuildRosterCache()
DHAir:HandleWhisper("inv", "Outsider")
check("guildOnly blocks a non-guild whisperer's invite", invitedPlayers["Outsider"] == nil)
DHAir:HandleWhisper("air", "Outsider")
check("guildOnly blocks a non-guild whisperer's queue add", DHAir:QueueNext() == nil)

-- Same setup, whisperer IS a member: should work normally. Queue joins
-- go via the code phrase now, so test both whisper flavors here.
DHAir:HandleWhisper("inv", "Guildmate")
check("guildOnly allows a real guildmate's invite", invitedPlayers["Guildmate"] == 1)
DHAir:HandleWhisper("air", "Guildmate")
check("guildOnly allows a real guildmate's queue add",
    DHAir:QueueNext() ~= nil and DHAir:QueueNext().name == "Guildmate")

-- A non-guild player already in the queue (e.g. added before guildOnly was
-- turned on) should simply be skipped by auto-summon, not summoned.
resetState()
DHAir.db.guildOnly = false
groupRoster = { "Guildmate", "Outsider2" }
inGroup = true
DHAir:QueueAdd("Outsider2")
DHAir:QueueAdd("Guildmate")
DHAir:ApplyDestination("Outsider2", "stormwind")
DHAir:ApplyDestination("Guildmate", "stormwind")
DHAir.db.guildOnly = true
inGuild = true
guildRosterNames = { "Loopi", "Guildmate" }
DHAir:UpdateGuildRosterCache()
DHAir.db.active = true
local nextUp = DHAir:QueueNextAvailable(false)
check("Non-guild entry is skipped once guildOnly is turned on", nextUp ~= nil and nextUp.name == "Guildmate")

-- World Buff Mode - "already in Booty Bay" exclusion (2026-09-05, Deves
-- via Chris). World Buff Mode off: unchanged immediate-queue behavior.
resetState()
DHAir.db.worldBuffMode = false
DHAir:HandleWhisper("inv", "Nadia")
check("World Buff Mode off: whisper still queues immediately",
    DHAir:QueueNext() ~= nil and DHAir:QueueNext().name == "Nadia")

-- World Buff Mode on, requester never joins the group: after the timeout
-- elapses, the pending check fails OPEN and queues them anyway rather
-- than leaving them stuck forever.
resetState()
DHAir.db.worldBuffMode = true
DHAir:HandleWhisper("inv", "Oscar")
check("World Buff Mode on: not queued yet (awaiting the zone check)", DHAir:QueueNext() == nil)
gameTime = gameTime + 31 -- production code times this via GetTime(), not time()
fireNextTimer() -- the sweep's own C_Timer.NewTimer callback
check("...times out unresolved and queues anyway (fail-open, D9)",
    DHAir:QueueNext() ~= nil and DHAir:QueueNext().name == "Oscar")

-- World Buff Mode on, requester accepts and lands somewhere that is NOT
-- Booty Bay (including plain Stranglethorn Vale) - queued normally.
resetState()
DHAir.db.worldBuffMode = true
DHAir:HandleWhisper("inv", "Priya")
groupRoster = { "Priya" }
inGroup = true
unitZoneMock["party1"] = "Stranglethorn Vale"
fireNextTimer()
check("In STV but not Booty Bay specifically: still queued",
    DHAir:QueueNext() ~= nil and DHAir:QueueNext().name == "Priya")

-- World Buff Mode on, requester accepts and IS in Booty Bay - the queue
-- join is skipped entirely (no summon needed).
resetState()
DHAir.db.worldBuffMode = true
DHAir:HandleWhisper("inv", "Quinn")
groupRoster = { "Quinn" }
inGroup = true
unitZoneMock["party1"] = "Booty Bay"
fireNextTimer()
check("Already in Booty Bay: never added to the queue", DHAir:QueueNext() == nil)

-- Online status tracking (for the Board's offline-dimming feature).
resetState()
inGuild = true
guildRosterNames = { "Loopi", { name = "Offliner", online = false }, { name = "Onliner", online = true } }
DHAir:UpdateGuildRosterCache()
check("Online guild member reports online", DHAir:IsGuildMemberOnline("Onliner") == true)
check("Offline guild member reports offline", DHAir:IsGuildMemberOnline("Offliner") == false)
check("Unknown/non-guild name reports nil (unknown, not offline)", DHAir:IsGuildMemberOnline("NeverHeardOfThem") == nil)

--------------------------------------------------------------------------
-- Section 3b: Roster registration (also auto-joins/leaves the queue for
-- Summoners/Clickers as of D5, 2026-08-17 - see DH-Tools-WorldBuffRequest-
-- Design.md)
--------------------------------------------------------------------------
print("== Roster registration ==")
resetState()
DHAir.db.active = false

check("Not registered as summoner by default", DHAir:IsRegistered("summoner", "TestChar") == false)
check("Summoner count starts at 0", DHAir:CountRegistered("summoner") == 0)

DHAir:SetRole("summoner", true)
check("Registering as summoner records it", DHAir:IsRegistered("summoner", "TestChar") == true)
check("Summoner count is now 1", DHAir:CountRegistered("summoner") == 1)
-- D5 (2026-08-17, DH-Tools-WorldBuffRequest-Design.md): registering now
-- DOES add a real queue entry, purely for Board visibility - this section
-- title says "no queue side effects", which stopped being fully true here.
check("Registering also adds a queue entry (D5)", DHAir:QueueNext() ~= nil
    and DHAir:QueueNext().name == "TestChar" and DHAir:QueueNext().role == "summoner")
check("EffectiveRole reflects the registration", DHAir:EffectiveRole("TestChar") == "summoner")

DHAir:SetRole("summoner", false)
check("Unregistering clears it", DHAir:IsRegistered("summoner", "TestChar") == false)
check("Summoner count back to 0", DHAir:CountRegistered("summoner") == 0)
check("Unregistering also removes the queue entry (D5)", DHAir:QueueNext() == nil)

-- Summoner takes precedence over clicker if both are registered.
DHAir:SetRole("clicker", true)
check("EffectiveRole is clicker when only clicker is set", DHAir:EffectiveRole("TestChar") == "clicker")
DHAir:SetRole("summoner", true)
check("EffectiveRole becomes summoner once both are set (summoner wins)", DHAir:EffectiveRole("TestChar") == "summoner")

-- Registering after already being queued re-stamps the existing entry
-- (rather than creating a duplicate), matching the decoupled role/queue design.
resetState()
DHAir.db.active = false
DHAir:QueueAdd("TestChar")
check("Queued entry starts with no role", DHAir:QueueNext().role == nil)
DHAir:SetRole("clicker", true)
check("Existing queue entry is re-stamped with the new role", DHAir:QueueNext().role == "clicker")
check("Still only one queue entry (no duplicate)", #DHAir.db.queue == 1)

-- A brand new QueueAdd should pick up an ALREADY-registered role immediately.
resetState()
DHAir.db.active = false
DHAir:SetRole("summoner", true)
DHAir:QueueAdd("TestChar")
check("New queue entry inherits an existing registration", DHAir:QueueNext().role == "summoner")

-- k-0033 regression (2026-08-13): lastSeen must track WALL-CLOCK time()
-- so staleness survives a relog. GetTime() resets to a small number every
-- time the client launches - if staleness were still keyed on GetTime(),
-- an entry registered last session would produce a NEGATIVE "age" this
-- session (always < TTL), so it could never go stale. Chris found exactly
-- this live via /run: a Warlock's lastSeen read 1853905 while the current
-- session's GetTime() was only 162776. gameTime is deliberately pinned to
-- a tiny value below to prove staleness now depends only on wallClock.
resetState()
gameTime = 50 -- as if GetTime() just reset low after a relog
-- 2026-08-18 (Chris): TTL bumped 300s -> 2700s (45 min) - offsets below
-- updated to stay on the correct side of the new threshold.
DHAir.db.roster.summoners["oldtimer"] = { lastSeen = wallClock - 2800, active = false } -- 2800s > 2700s TTL
check("An entry past the TTL in wall-clock time is stale, even with a tiny GetTime()",
    DHAir:IsRegistered("summoner", "oldtimer") == false)
check("CountRegistered agrees", DHAir:CountRegistered("summoner") == 0)

DHAir.db.roster.summoners["recent"] = { lastSeen = wallClock - 100, active = false } -- 100s < 2700s TTL
check("An entry within the TTL in wall-clock time still counts, even with a tiny GetTime()",
    DHAir:IsRegistered("summoner", "recent") == true)
check("CountRegistered agrees", DHAir:CountRegistered("summoner") == 1)

--------------------------------------------------------------------------
-- Section 3c: SortedQueue tiering (self, Summoners, Clickers, online,
-- offline - 2026-08-17, Chris)
--------------------------------------------------------------------------
print("== SortedQueue tiering ==")
resetState()
DHAir.db.active = false
inGuild = true

-- Build a queue: one online regular, one offline regular, one clicker,
-- one summoner, plus "me". Guild roster drives the online/offline split.
DHAir:QueueAdd("OnlineReg")
DHAir:QueueAdd("OfflineReg")
DHAir:QueueAdd("ClickerGuy")
DHAir:QueueAdd("SummonerGal")
DHAir:QueueAdd("TestChar") -- "me"

guildRosterNames = {
    { name = "OnlineReg", online = true },
    { name = "OfflineReg", online = false },
    "ClickerGuy", "SummonerGal", "TestChar",
}
DHAir:UpdateGuildRosterCache()

-- Register roles AFTER queueing, relying on the re-stamp behavior.
DHAir:SetRole("summoner", false) -- make sure "me" has no role for this test
local function setEntryRole(name, role)
    for _, e in ipairs(DHAir.db.queue) do
        if e.name == name then e.role = role end
    end
end
setEntryRole("ClickerGuy", "clicker")
setEntryRole("SummonerGal", "summoner")

local ordered = DHAir:SortedQueue("wait", "desc")
check("My own entry is always first", ordered[1].name == "TestChar")
check("Summoner tier is next", ordered[2].name == "SummonerGal")
check("Clicker tier is next", ordered[3].name == "ClickerGuy")
check("Online regular precedes offline regular",
    ordered[4].name == "OnlineReg" and ordered[5].name == "OfflineReg")
check("All 5 entries accounted for", #ordered == 5)

-- Sorting by name should reorder WITHIN tiers only, never across them.
local orderedByName = DHAir:SortedQueue("name", "asc")
check("Self still first even when sorting by name", orderedByName[1].name == "TestChar")
check("Summoner/Clicker/online/offline tier ORDER is unaffected by sortKey",
    orderedByName[2].name == "SummonerGal" and orderedByName[3].name == "ClickerGuy"
    and orderedByName[4].name == "OnlineReg" and orderedByName[5].name == "OfflineReg")

-- Sorting by destination (M5, DH-Air-Destinations-Design.md §5) - same
-- tiering rule applies: reorders WITHIN each tier only. Undecided
-- (nil destination) sorts as "" - first ascending.
local function setEntryDest(name, destId)
    for _, e in ipairs(DHAir.db.queue) do
        if e.name == name then e.destination = destId end
    end
end
setEntryDest("OnlineReg", "ironforge")  -- "Ironforge (Dun Morogh)"
setEntryDest("OfflineReg", nil)         -- undecided

local orderedByDest = DHAir:SortedQueue("dest", "asc")
check("Tier order still holds when sorting by destination",
    orderedByDest[1].name == "TestChar" and orderedByDest[2].name == "SummonerGal"
    and orderedByDest[3].name == "ClickerGuy")
check("Within a single-member tier, destination sort is moot - both still present",
    orderedByDest[4] ~= nil and orderedByDest[5] ~= nil)

--------------------------------------------------------------------------
-- Section 3c-2: World Buff Mode online-tier boost (2026-08-17, Chris) -
-- while db.worldBuffMode is on, Booty-Bay-bound entries in the ONLINE
-- regular tier float above the rest of that tier, outranking sortKey
-- (here: wait time) rather than just breaking ties on it. Summoner/
-- Clicker/offline tiers are untouched by this.
--------------------------------------------------------------------------
print("== World Buff Mode queue ordering ==")
resetState()
DHAir.db.active = false
inGuild = true

DHAir:QueueAdd("LongWaitBooty")   -- online, destination bootybay, queued first (longest wait)
DHAir:QueueAdd("ShortWaitPlain")  -- online, no destination, queued after (shorter wait)
DHAir:QueueAdd("OfflineBooty")    -- offline, destination bootybay - must NOT jump the online tier

guildRosterNames = {
    { name = "LongWaitBooty", online = true },
    { name = "ShortWaitPlain", online = true },
    { name = "OfflineBooty", online = false },
}
DHAir:UpdateGuildRosterCache()
setEntryDest("LongWaitBooty", "bootybay")
setEntryDest("OfflineBooty", "bootybay")

DHAir.db.worldBuffMode = false
local plainOrder = DHAir:SortedQueue("wait", "desc")
check("World Buff Mode off: plain wait-time order, longest wait first",
    plainOrder[1].name == "LongWaitBooty" and plainOrder[2].name == "ShortWaitPlain"
    and plainOrder[3].name == "OfflineBooty")

DHAir.db.worldBuffMode = true
local buffOrder = DHAir:SortedQueue("wait", "desc")
check("World Buff Mode on: Booty Bay outranks wait time WITHIN the online tier",
    buffOrder[1].name == "LongWaitBooty" and buffOrder[2].name == "ShortWaitPlain")
check("World Buff Mode on: offline Booty-Bay entry still stays in the offline tier, doesn't jump online",
    buffOrder[3].name == "OfflineBooty")

-- Reverse the wait-time order so a real "outranks" check is meaningful
-- (not just coincidentally already on top): LongWaitPlain queues first
-- (longest wait) with no destination, ShortWaitBooty queues after
-- (shorter wait) but headed to Booty Bay - it should still win.
resetState()
DHAir.db.active = false
inGuild = true
DHAir:QueueAdd("LongWaitPlain")
DHAir:QueueAdd("ShortWaitBooty")
guildRosterNames = {
    { name = "LongWaitPlain", online = true },
    { name = "ShortWaitBooty", online = true },
}
DHAir:UpdateGuildRosterCache()
setEntryDest("ShortWaitBooty", "bootybay")
DHAir.db.worldBuffMode = true
local outrankOrder = DHAir:SortedQueue("wait", "desc")
check("World Buff Mode: shorter-wait Booty Bay entry still beats a longer-wait non-Booty entry",
    outrankOrder[1].name == "ShortWaitBooty" and outrankOrder[2].name == "LongWaitPlain")
DHAir.db.worldBuffMode = false

--------------------------------------------------------------------------
-- Section 3d: Self-service queue actions
--------------------------------------------------------------------------
print("== Self-service join/leave ==")
resetState()
DHAir.db.active = false

check("SelfJoinQueue adds the local player", DHAir:SelfJoinQueue() == true)
check("Player is now in the queue", DHAir:QueueNext() ~= nil and DHAir:QueueNext().name == "TestChar")
check("Joining again fails (already queued)", DHAir:SelfJoinQueue() == false)

check("SelfLeaveQueue removes the local player", DHAir:SelfLeaveQueue() == true)
check("Queue is empty again", DHAir:QueueNext() == nil)
check("Leaving again fails (not in queue)", DHAir:SelfLeaveQueue() == false)

--------------------------------------------------------------------------
-- Section 3d-bis: Destinations (M1 - local data model + self-service picker)
--------------------------------------------------------------------------
print("== Destinations (self-service picker) ==")
resetState()
DHAir.db.active = false

check("GetDestination finds a known built-in entry",
    DHAir:GetDestination("stormwind") ~= nil and DHAir:GetDestination("stormwind").category == "flightpoint")
check("GetDestination returns nil for an unknown id", DHAir:GetDestination("not-a-real-place") == nil)
check("GetDestination returns nil for a nil id", DHAir:GetDestination(nil) == nil)

check("SetMyDestination fails if you're not queued yet", DHAir:SetMyDestination("stormwind") == false)

DHAir:SelfJoinQueue()
check("New queue entry starts with no destination", DHAir:QueueNext().destination == nil)

check("SetMyDestination accepts a known flight point", DHAir:SetMyDestination("stormwind") == true)
check("The queue entry now reflects it", DHAir:QueueNext().destination == "stormwind")

check("SetMyDestination refuses an unknown id", DHAir:SetMyDestination("narnia") == false)
check("Refused change did not disturb the existing destination", DHAir:QueueNext().destination == "stormwind")

-- 2026-08-03: was "deadmines", but that's now disabled by default (see
-- Destinations.lua) so SetMyDestination correctly refuses it - switched to
-- "wailingcaverns", a summonstone entry that's still enabled by default.
check("SetMyDestination accepts a summonstone id too", DHAir:SetMyDestination("wailingcaverns") == true)
check("Switching destinations overwrites the previous one", DHAir:QueueNext().destination == "wailingcaverns")

check("SetMyDestination('') clears it back to undecided", DHAir:SetMyDestination("") == true)
check("Destination is nil again", DHAir:QueueNext().destination == nil)

DHAir:SetMyDestination("ironforge")
check("SetMyDestination(nil) also clears it", DHAir:SetMyDestination(nil) == true)
check("Destination is nil after a nil clear too", DHAir:QueueNext().destination == nil)

-- Setting your destination must never affect anyone else's entry.
resetState()
DHAir.db.active = false
groupRoster = { "TestChar", "Riley" }
inGroup = true
DHAir:QueueAdd("Riley")
DHAir:SelfJoinQueue()
DHAir:SetMyDestination("gadgetzan")
local rileyEntry, myEntry
for _, e in ipairs(DHAir.db.queue) do
    if e.name == "Riley" then rileyEntry = e end
    if e.name == "TestChar" then myEntry = e end
end
check("Your destination only touches your own entry", myEntry.destination == "gadgetzan")
check("Someone else's entry is untouched", rileyEntry.destination == nil)

-- Disabled destinations (2026-08-03, DestinationEditor.lua's enable/
-- disable toggle) are hidden from NEW selection (FindDestinationByQuery,
-- ApplyDestination/SetMyDestination/SetWarlockDestination) but
-- GetDestination still resolves them fine - it's a selection-time filter,
-- not a data-hiding one, so an already-chosen destination still displays.
resetState()
DHAir.db.active = false
for _, d in ipairs(DHAir.db.destinations) do
    if d.id == "wailingcaverns" then d.enabled = false end
end
check("GetDestination still resolves a disabled destination (for display)",
    DHAir:GetDestination("wailingcaverns") ~= nil)
check("FindDestinationByQuery skips a disabled destination",
    DHAir:FindDestinationByQuery("wailing") == nil)
DHAir:SelfJoinQueue()
check("SetMyDestination refuses a disabled destination",
    DHAir:SetMyDestination("wailingcaverns") == false)
check("...and doesn't disturb the (still-undecided) entry", DHAir:QueueNext().destination == nil)
check("SetWarlockDestination also refuses a disabled destination",
    DHAir:SetWarlockDestination("wailingcaverns") == false)
for _, d in ipairs(DHAir.db.destinations) do
    if d.id == "wailingcaverns" then d.enabled = true end -- restore for later sections
end

--------------------------------------------------------------------------
-- Section 3d-2: Assisted destinations (M3, QueueFeedback design D3)
--
-- A Warlock setting SOMEONE ELSE's destination, because the requester
-- almost certainly has no addon and cannot pick one themselves. The whisper
-- assertions matter as much as the permission ones: that plain-chat whisper
-- is the only feedback a non-addon requester ever receives.
--------------------------------------------------------------------------
print("== Assisted destinations (set someone else's) ==")

-- Most recent plain-chat whisper sent to `name`, or nil. Reads chatLog as
-- an upvalue, which resetState() reassigns - that's fine and intentional,
-- the closure always sees the current table.
local function lastWhisperTo(name)
    for i = #chatLog, 1, -1 do
        if chatLog[i].channel == "WHISPER" and chatLog[i].target == name then
            return chatLog[i].msg
        end
    end
    return nil
end

resetState()
DHAir.db.active = false
groupRoster = { "TestChar", "Riley" }
inGroup = true
DHAir:QueueAdd("Riley")

isLeader, isAssistant = false, false
check("Regular member cannot set someone else's destination",
    DHAir:RequestSetDestinationFor("Riley", "ironforge") == false)
check("Riley's destination is untouched by the refusal",
    DHAir:QueueNext().destination == nil)
check("The refusal explains itself in chat",
    printLog[#printLog] ~= nil and printLog[#printLog]:find("raid leader or an assistant") ~= nil)
check("A refused set sends the affected player nothing at all",
    lastWhisperTo("Riley") == nil)

isAssistant = true
check("An assistant CAN set someone else's destination",
    DHAir:RequestSetDestinationFor("Riley", "ironforge") == true)
check("Riley's entry now carries it", DHAir:QueueNext().destination == "ironforge")

-- The whisper is the whole point of M3 - design D3 calls out that it must
-- say what the destination is, who set it, and how to correct it.
local whisper = lastWhisperTo("Riley")
check("The affected player is whispered in plain chat", whisper ~= nil)
check("...naming the destination", whisper ~= nil and whisper:find("Ironforge") ~= nil)
check("...naming who set it", whisper ~= nil and whisper:find("TestChar") ~= nil)
check("...and telling them how to correct it",
    whisper ~= nil and whisper:lower():find("whisper me") ~= nil)

-- Clearing is the same path, with its own wording.
check("An assistant can clear someone else's destination",
    DHAir:RequestSetDestinationFor("Riley", "") == true)
check("Riley is undecided again", DHAir:QueueNext().destination == nil)
check("The clear whispers them too",
    (lastWhisperTo("Riley") or ""):find("cleared") ~= nil)

-- Refusals that aren't about permission.
isLeader, isAssistant = true, false
check("Refuses a player who isn't queued at all",
    DHAir:RequestSetDestinationFor("Nobody", "ironforge") == false)
check("Refuses an unknown destination id",
    DHAir:RequestSetDestinationFor("Riley", "narnia") == false)
for _, d in ipairs(DHAir.db.destinations) do
    if d.id == "wailingcaverns" then d.enabled = false end
end
check("Refuses a disabled destination, same as the self-service path",
    DHAir:RequestSetDestinationFor("Riley", "wailingcaverns") == false)
for _, d in ipairs(DHAir.db.destinations) do
    if d.id == "wailingcaverns" then d.enabled = true end
end

-- Your OWN name is not "someone else": it routes to SetMyDestination, so it
-- needs no permission and must never whisper you about yourself.
resetState()
DHAir.db.active = false
groupRoster = { "TestChar", "Riley" }
inGroup = true
isLeader, isAssistant = false, false
DHAir:SelfJoinQueue()
check("Setting your OWN destination through this path needs no permission",
    DHAir:RequestSetDestinationFor("TestChar", "stormwind") == true)
check("...and applied", DHAir:QueueNext().destination == "stormwind")
check("...and does not whisper you about yourself", lastWhisperTo("TestChar") == nil)

-- FindQueuedName exists purely because Commands.lua lower-cases the whole
-- slash line before parsing it.
resetState()
DHAir.db.active = false
DHAir:QueueAdd("Riley")
check("FindQueuedName recovers the stored capitalization", DHAir:FindQueuedName("riley") == "Riley")
check("FindQueuedName tolerates a realm suffix", DHAir:FindQueuedName("riley-Whitemane") == "Riley")
check("FindQueuedName returns nil for someone not queued", DHAir:FindQueuedName("ghost") == nil)
check("FindQueuedName returns nil for an empty query", DHAir:FindQueuedName("") == nil)

-- /dhair destfor - the slash-command twin of clicking the Board cell.
resetState()
DHAir.db.active = false
groupRoster = { "TestChar", "Riley" }
inGroup = true
DHAir:QueueAdd("Riley")
isLeader, isAssistant = false, true
SlashCmdList["DHAIR"]("destfor riley ironforge")
check("/dhair destfor sets a queued player's destination by partial match",
    DHAir:QueueNext().destination == "ironforge")
check("/dhair destfor whispered them", lastWhisperTo("Riley") ~= nil)

SlashCmdList["DHAIR"]("destfor riley clear")
check("/dhair destfor <player> clear clears it", DHAir:QueueNext().destination == nil)

SlashCmdList["DHAIR"]("destfor ghost ironforge")
check("/dhair destfor rejects someone who isn't queued",
    printLog[#printLog]:find("isn't in the summon queue") ~= nil)

SlashCmdList["DHAIR"]("destfor riley zzzznotaplace")
check("/dhair destfor rejects an unmatched destination",
    printLog[#printLog]:find("No single destination matches") ~= nil)

SlashCmdList["DHAIR"]("destfor riley")
check("/dhair destfor with no destination prints usage",
    printLog[#printLog]:find("Usage: /dhair destfor") ~= nil)

--------------------------------------------------------------------------
-- Section 3e: Permission-gated remove / clear
--------------------------------------------------------------------------
print("== Permission-gated remove / clear ==")
resetState()
DHAir.db.active = false
groupRoster = { "TestChar" }
inGroup = true

-- Removing YOURSELF never needs permission.
DHAir:QueueAdd("TestChar")
isLeader, isAssistant = false, false
check("Removing your own name needs no permission", DHAir:RequestRemove("TestChar") == true)
check("You're actually gone from the queue", DHAir:QueueNext() == nil)

-- Removing SOMEONE ELSE requires leader/assist.
DHAir:QueueAdd("Otherguy")
isLeader, isAssistant = false, false
check("Regular member cannot remove someone else", DHAir:RequestRemove("Otherguy") == false)
check("Otherguy is still in the queue", DHAir:QueueNext() ~= nil and DHAir:QueueNext().name == "Otherguy")

isAssistant = true
check("An assistant CAN remove someone else", DHAir:RequestRemove("Otherguy") == true)
check("Otherguy is now gone", DHAir:QueueNext() == nil)

isLeader, isAssistant = true, false
DHAir:QueueAdd("Thirdguy")
check("The leader CAN remove someone else too", DHAir:RequestRemove("Thirdguy") == true)

-- Clear-all: same gating.
isLeader, isAssistant = false, false
DHAir:QueueAdd("Fourthguy")
check("Regular member cannot clear the whole queue", DHAir:RequestClearAll() == false)
check("Queue still has an entry", #DHAir.db.queue == 1)

isLeader = true
check("Leader CAN clear the whole queue", DHAir:RequestClearAll() == true)
check("Queue is now empty", #DHAir.db.queue == 0)

-- Clear-roster: same gating, but a SEPARATE action from Clear-all - proves
-- clearing the queue does NOT touch registrations and vice versa
-- (2026-08-13, the whole reason this action exists - see Roster.lua).
DHAir:SetRole("summoner", true)
DHAir.db.roster.summoners["otherguy"] = { lastSeen = time(), active = false }
DHAir.db.roster.clickers["thirdguy"] = { lastSeen = time(), active = false }
check("Roster has 2 summoners and 1 clicker before clearing",
    DHAir:CountRegistered("summoner") == 2 and DHAir:CountRegistered("clicker") == 1)

isLeader, isAssistant = false, false
check("Regular member cannot clear the roster", DHAir:RequestClearRoster() == false)
check("Roster is untouched", DHAir:CountRegistered("summoner") == 2)

isLeader = true
check("Leader CAN clear the roster", DHAir:RequestClearRoster() == true)
check("Summoner roster is now empty", DHAir:CountRegistered("summoner") == 0)
check("Clicker roster is now empty", DHAir:CountRegistered("clicker") == 0)
-- 2026-08-18 (Chris-reported): RequestClearRoster now ALSO fully wipes
-- db.queue (via QueueReset) - previously it only touched the roster
-- tables, which left TestChar's D5 auto-joined entry behind as an
-- orphan (stale role="summoner" tag, no live registration behind it).
-- That was flagged as a known-but-unconfirmed edge case and Chris asked
-- for the hard clear to take care of it instead.
check("Clearing the roster also clears the D5 auto-joined queue entry (no more orphan)",
    DHAir:QueueNext() == nil)

-- Nobody's grouped at all yet: anyone can act (UnitHasAuthority's "not
-- IsInGroup()" exception), matching the invite-permission carve-out.
resetState()
DHAir.db.active = false
groupRoster = {}
inGroup = false
DHAir:QueueAdd("Solo")
isLeader, isAssistant = false, false
check("With no group at all, anyone can remove others too", DHAir:RequestRemove("Solo") == true)

--------------------------------------------------------------------------
-- Section 3f: Raid-chat code phrase (HandlePublicChat) + event wiring
--------------------------------------------------------------------------
print("== Raid-chat code phrase matching ==")
resetState()
DHAir.db.active = false
DHAir.db.codePhrase = "air"
groupRoster = { "TestChar" }
inGroup = true

DHAir:HandlePublicChat("air", "Mia")
check("Exact phrase queues the sender", DHAir:QueueNext() ~= nil and DHAir:QueueNext().name == "Mia")

DHAir:HandlePublicChat("AIR", "Nate")
check("Matching is case-insensitive", DHAir.db.queue[2] ~= nil and DHAir.db.queue[2].name == "Nate")

DHAir:HandlePublicChat("  air  ", "Omar")
check("Leading/trailing whitespace is trimmed", DHAir.db.queue[3] ~= nil and DHAir.db.queue[3].name == "Omar")

DHAir:HandlePublicChat("need air support", "Priya")
check("Substring match does NOT trigger (exact match only)", #DHAir.db.queue == 3)

-- 2026-08-07 (design D2): public channels deliberately did NOT get the
-- whisper's prefix matching. A Warlock typing "air service is up, whisper
-- me" in raid chat must not silently queue themselves.
DHAir:HandlePublicChat("air service is up, whisper me", "Loopi")
check("Trailing text does NOT trigger in public chat (unlike a whisper)",
    #DHAir.db.queue == 3)

DHAir.db.codePhrase = ""
DHAir:HandlePublicChat("air", "Quinn")
check("Empty code phrase disables the trigger entirely", #DHAir.db.queue == 3)
DHAir.db.codePhrase = "air"

-- Guild-only gating mirrors HandleWhisper's (fail open with no guild / empty roster).
resetState()
DHAir.db.active = false
DHAir.db.codePhrase = "air"
groupRoster = { "TestChar" }
inGroup = true
DHAir.db.guildOnly = true
inGuild = true
guildRosterNames = { "Loopi", "Guildmate" }
DHAir:UpdateGuildRosterCache()
DHAir:HandlePublicChat("air", "Outsider")
check("guildOnly blocks a non-guild speaker's raid-chat join", DHAir:QueueNext() == nil)
DHAir:HandlePublicChat("air", "Guildmate")
check("guildOnly allows a real guildmate's raid-chat join", DHAir:QueueNext() ~= nil
    and DHAir:QueueNext().name == "Guildmate")

-- Event-level check: confirm CHAT_MSG_RAID/CHAT_MSG_RAID_LEADER are actually
-- registered and dispatched to HandlePublicChat (not just callable directly -
-- this is the wiring Core.lua's OnEvent needs for the feature to work at all
-- in a live client).
resetState()
DHAir.db.active = false
DHAir.db.codePhrase = "air"
DHAir.db.guildOnly = false
groupRoster = { "TestChar" }
inGroup = true

DHAir.frame:Fire("CHAT_MSG_RAID", "air", "Riley")
check("CHAT_MSG_RAID event is wired to HandlePublicChat", DHAir:QueueNext() ~= nil
    and DHAir:QueueNext().name == "Riley")

DHAir.frame:Fire("CHAT_MSG_RAID_LEADER", "air", "Sasha")
check("CHAT_MSG_RAID_LEADER event is also wired to HandlePublicChat", DHAir.db.queue[2] ~= nil
    and DHAir.db.queue[2].name == "Sasha")

-- Party added 2026-08-07 (design D1) - a 5-man forming before the raid
-- exists previously had no code-phrase route in at all.
DHAir.frame:Fire("CHAT_MSG_PARTY", "air", "Tariq")
check("CHAT_MSG_PARTY is wired to HandlePublicChat", DHAir.db.queue[3] ~= nil
    and DHAir.db.queue[3].name == "Tariq")

DHAir.frame:Fire("CHAT_MSG_PARTY_LEADER", "air", "Yuki")
check("CHAT_MSG_PARTY_LEADER is wired too", DHAir.db.queue[4] ~= nil
    and DHAir.db.queue[4].name == "Yuki")

-- Guild chat is deliberately NOT registered (too broad a trigger surface).
DHAir.frame:Fire("CHAT_MSG_GUILD", "air", "Zane")
check("CHAT_MSG_GUILD is deliberately NOT a trigger", #DHAir.db.queue == 4)

--------------------------------------------------------------------------
-- Section 3g: Permission-gated code phrase change (RequestSetPhrase)
--------------------------------------------------------------------------
print("== Permission-gated code phrase change ==")
resetState()
DHAir.db.active = false
groupRoster = { "TestChar" }
inGroup = true

isLeader, isAssistant = false, false
check("Regular member cannot set the code phrase", DHAir:RequestSetPhrase("newphrase") == false)
check("Code phrase unchanged after refusal", DHAir.db.codePhrase == "air")

isAssistant = true
check("An assistant CAN set the code phrase", DHAir:RequestSetPhrase("newphrase") == true)
check("Code phrase updated", DHAir.db.codePhrase == "newphrase")

isLeader, isAssistant = true, false
check("The leader CAN set the code phrase too", DHAir:RequestSetPhrase("otherphrase") == true)
check("Code phrase updated again", DHAir.db.codePhrase == "otherphrase")

isLeader, isAssistant = false, false
check("Empty phrase is rejected regardless of permission", DHAir:RequestSetPhrase("") == false)
check("Code phrase unchanged after empty-string rejection", DHAir.db.codePhrase == "otherphrase")

-- Nobody's grouped at all yet: anyone can act (same carve-out as remove/clear).
resetState()
DHAir.db.active = false
groupRoster = {}
inGroup = false
isLeader, isAssistant = false, false
check("With no group at all, anyone can set the code phrase", DHAir:RequestSetPhrase("soloPhrase") == true)

--------------------------------------------------------------------------
-- Section 3h: Destinations list management (M3 - real guild-officer rank gate)
--------------------------------------------------------------------------
print("== Destinations list management (real officer-rank gate) ==")
resetState()
DHAir.db.active = false
groupRoster = { "TestChar" }
inGroup = true
inGuild = true
DHAir.db.officerRankThreshold = 3

guildRosterNames = { { name = "TestChar", rankIndex = 5 } } -- below the officer threshold
DHAir:UpdateGuildRosterCache()
check("A guild member ranked below the threshold lacks edit_destinations",
    DHAir:HasPermission("edit_destinations") == false)
check("SetDestinationList refuses for a non-officer",
    DHAir:SetDestinationList({ { id = "x", label = "X", category = "flightpoint" } }) == false)
check("db.destinations is untouched by the refused attempt",
    #DHAir.db.destinations == #DHAir.DEFAULT_DESTINATIONS)

guildRosterNames = { { name = "TestChar", rankIndex = 3 } } -- exactly at the threshold
DHAir:UpdateGuildRosterCache()
check("Rank exactly at the threshold counts as an officer (boundary)",
    DHAir:HasPermission("edit_destinations") == true)
local customList = { { id = "custom1", label = "Custom Place", category = "flightpoint" } }
check("SetDestinationList succeeds for an officer", DHAir:SetDestinationList(customList) == true)
check("db.destinations now reflects the custom list", #DHAir.db.destinations == 1
    and DHAir.db.destinations[1].id == "custom1")

guildRosterNames = { { name = "TestChar", rankIndex = 0 } } -- Guild Master, well within threshold
DHAir:UpdateGuildRosterCache()
check("ResetDestinationsToDefault succeeds for the Guild Master", DHAir:ResetDestinationsToDefault() == true)
check("db.destinations is back to the full built-in list",
    #DHAir.db.destinations == #DHAir.DEFAULT_DESTINATIONS)

guildRosterNames = { { name = "TestChar", rankIndex = 4 } } -- one past the threshold
DHAir:UpdateGuildRosterCache()
check("ResetDestinationsToDefault refuses just past the threshold afterward",
    DHAir:ResetDestinationsToDefault() == false)

-- The actual M2 -> M3 behavior change: raid leader/assistant status ALONE
-- no longer grants edit_destinations - only a real guild-officer rank does.
guildRosterNames = {}
DHAir:UpdateGuildRosterCache()
isLeader, isAssistant = true, false
check("Raid leader with no guild-officer rank no longer has edit_destinations (M3 tightened this)",
    DHAir:HasPermission("edit_destinations") == false)
isAssistant, isLeader = true, false
check("Raid assistant with no guild-officer rank no longer has edit_destinations either",
    DHAir:HasPermission("edit_destinations") == false)
isLeader, isAssistant = false, false

-- Not in the guild roster at all (or roster not loaded) fails CLOSED, unlike
-- IsGuildMember's deliberate fail-open - this gates a write action.
check("Not being in the guild roster at all fails closed for IsGuildOfficer",
    DHAir:IsGuildOfficer("TestChar") == false)
check("A nil name fails closed too", DHAir:IsGuildOfficer(nil) == false)

--------------------------------------------------------------------------
-- Section 3h-bis: SetDestinationEnabled (same officer-rank gate as
-- SetDestinationList/ResetDestinationsToDefault - see Queue.lua)
--------------------------------------------------------------------------
print("== Enable/disable a destination (real officer-rank gate) ==")
resetState()
groupRoster = { "TestChar" }
inGroup = true
inGuild = true
DHAir.db.officerRankThreshold = 3

guildRosterNames = { { name = "TestChar", rankIndex = 5 } } -- below the officer threshold
DHAir:UpdateGuildRosterCache()
check("A non-officer cannot disable a destination",
    DHAir:SetDestinationEnabled("stormwind", false) == false)
check("stormwind is still enabled after the refused attempt",
    DHAir:GetDestination("stormwind").enabled ~= false)

guildRosterNames = { { name = "TestChar", rankIndex = 3 } } -- exactly at the threshold
DHAir:UpdateGuildRosterCache()
check("An officer CAN disable a destination", DHAir:SetDestinationEnabled("stormwind", false) == true)
check("stormwind is now disabled", DHAir:GetDestination("stormwind").enabled == false)
check("A disabled destination is refused by FindDestinationByQuery",
    DHAir:FindDestinationByQuery("stormwind") == nil)

check("An officer CAN re-enable it", DHAir:SetDestinationEnabled("stormwind", true) == true)
check("stormwind is enabled again", DHAir:GetDestination("stormwind").enabled ~= false)

check("SetDestinationEnabled refuses an unknown id", DHAir:SetDestinationEnabled("narnia", false) == false)

--------------------------------------------------------------------------
-- Section 3i: set_officer_threshold (Guild Master, rank 0, only)
--------------------------------------------------------------------------
print("== Officer rank threshold (Guild Master only) ==")
resetState()
inGuild = true
DHAir.db.officerRankThreshold = 3

guildRosterNames = { { name = "TestChar", rankIndex = 3 } } -- an officer, but not rank 0
DHAir:UpdateGuildRosterCache()
check("An officer who isn't rank 0 lacks set_officer_threshold permission",
    DHAir:HasPermission("set_officer_threshold") == false)
check("...and RequestSetOfficerThreshold refuses accordingly",
    DHAir:RequestSetOfficerThreshold(5) == false)
check("Threshold unchanged after refusal", DHAir.db.officerRankThreshold == 3)

guildRosterNames = { { name = "TestChar", rankIndex = 0 } } -- Guild Master
DHAir:UpdateGuildRosterCache()
check("The Guild Master (rank 0) has set_officer_threshold permission",
    DHAir:HasPermission("set_officer_threshold") == true)
check("...and RequestSetOfficerThreshold succeeds", DHAir:RequestSetOfficerThreshold(5) == true)
check("Threshold updated", DHAir.db.officerRankThreshold == 5)
check("A non-numeric value is rejected", DHAir:RequestSetOfficerThreshold("not-a-number") == false)
check("Threshold unchanged after invalid input", DHAir.db.officerRankThreshold == 5)
check("A negative rank index is rejected too", DHAir:RequestSetOfficerThreshold(-1) == false)
check("Threshold still unchanged", DHAir.db.officerRankThreshold == 5)

--------------------------------------------------------------------------
-- Section 3j: Loopidot testing override covers the new officer checks too
--------------------------------------------------------------------------
-- Verifies the specific gap the override comment in Core.lua calls out:
-- IsGuildOfficer doesn't route through UnitHasAuthority, so it needs its
-- own copy of the bypass. This is exactly the check Sync.lua's DESTLIST
-- receiver runs against an incoming message's sender name.
print("== Loopidot override (guild-officer actions) ==")
resetState()
inGuild = true
guildRosterNames = {} -- Loopidot isn't even in the mocked roster
DHAir:UpdateGuildRosterCache()
check("Loopidot bypasses IsGuildOfficer with no roster entry at all",
    DHAir:IsGuildOfficer("Loopidot") == true)
check("The bypass is name-scoped - a regular unlisted member still fails closed",
    DHAir:IsGuildOfficer("SomeRandomMember") == false)

-- Section 3k (Account-wide author-admin override) removed 2026-08-20 -
-- DH-Air merge retired DH-Air's own DHAirDB.isAuthorAccount copy in favor
-- of DHTools.IsAuthorAccount() (DH-Tools' own mechanism). NOTE: as of this
-- merge, DH-Tools' own Core.lua has NO headless harness at all (see
-- DH-Tools\STATUS.md's open questions), so these scenarios (PLAYER_LOGIN
-- sets the flag, it survives an alt switch, it never leaks into
-- remote-sender verification) currently have NO automated coverage
-- anywhere, not just moved elsewhere - see DH-Air-Merge-Design.md
-- decision 4's residual risk note.

--------------------------------------------------------------------------
-- Section 4: Summon state machine (happy path)
--------------------------------------------------------------------------
print("== Summon state machine: happy path ==")
resetState()
groupRoster = { "Henry", "Ivy" }
inGroup = true
DHAir.db.active = true
DHAir.db.messages.raid.enabled = true
DHAir.db.messages.party.enabled = true
DHAir.db.messages.say.enabled = true

QueueAddWithDest("Henry")
QueueAddWithDest("Ivy")

-- 2026-08-04 (one-click auto-summon redesign): TrySummonNext auto-picks
-- and claims Henry, but stops at "ready" instead of casting immediately -
-- TargetUnit/CastSpellByName can't be called outside a real player click
-- (see Summon.lua's BeginCast) - ConfirmSummon simulates that click, the
-- Board's "Confirm Summon" button in real play.
check("Auto-pick claims Henry but doesn't cast yet (protected-function gate)",
    DHAir.summonState == "ready" and DHAir.pendingEntry and DHAir.pendingEntry.name == "Henry")
check("No target set yet - nothing casts without a real click", currentTarget == nil)
check("Confirming the pick (simulated click) succeeds", DHAir:ConfirmSummon() == true)

-- 2026-08-06 (k-0010): BeginCast no longer calls TargetUnit/CastSpellByName
-- itself (see Summon.lua) - it stashes pendingCastUnit for the real
-- SecureActionButtonTemplate button's PreClick to arm, which this headless
-- harness can't simulate (that's Board.lua UI code, same exclusion
-- category as the rest of that file). Verify the RESOLVED target and the
-- macro that WOULD be armed instead.
check("TrySummonNext resolves Henry as the click's cast target", UnitName(DHAir.pendingCastUnit) == "Henry")
check("The macro the button would arm targets+casts on Henry correctly",
    DHAir:BuildCastMacro(DHAir.pendingCastUnit) == "/target Henry\n/cast Ritual of Summoning")
check("State is 'casting' right after resolving (not yet confirmed)", DHAir.summonState == "casting")
check("No announcement sent yet - waiting for game to confirm the cast", #chatLog == 0)
DHAir.pendingCastUnit = nil -- simulate the button's PreClick consuming it

-- Simulate the game confirming the cast actually started.
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid1", "Ritual of Summoning")
check("State moves to 'waiting' only after confirmed success", DHAir.summonState == "waiting")
check("Party announcement sent (in group, not raid)", countChannel("PARTY") == 1)
check("Raid announcement NOT sent (not in raid)", countChannel("RAID") == 0)
check("Say announcement sent", countChannel("SAY") == 1)
check("Whisper sent to the target (enabled by default)", countChannel("WHISPER") == 1)
for _, entry in ipairs(chatLog) do
    if entry.channel ~= "WHISPER" then
        check("Announcement mentions Henry by name (channel " .. entry.channel .. ")",
            entry.msg:find("Henry", 1, true) ~= nil)
    else
        check("Whisper is targeted at Henry specifically", entry.target == "Henry")
    end
end

-- Simulate the timeout elapsing (nobody clicked in time).
local fired = fireNextTimer()
check("Timeout timer fired", fired == true)
check("Henry marked summoned after timeout", summonedFlag("Henry") == true)
check("Auto-pick claims Ivy but doesn't cast yet (protected-function gate)",
    DHAir.summonState == "ready" and DHAir.pendingEntry and DHAir.pendingEntry.name == "Ivy")
check("Confirming Ivy's pick succeeds", DHAir:ConfirmSummon() == true)
check("Queue advanced to Ivy as the resolved cast target", UnitName(DHAir.pendingCastUnit) == "Ivy")
check("The second macro targets+casts on Ivy correctly",
    DHAir:BuildCastMacro(DHAir.pendingCastUnit) == "/target Ivy\n/cast Ritual of Summoning")
check("Ivy's state is 'casting' pending confirmation", DHAir.summonState == "casting")
DHAir.pendingCastUnit = nil -- simulate the button's PreClick consuming it

DHAir:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid2", "Ritual of Summoning")
check("Ivy's state moves to 'waiting' after confirmation", DHAir.summonState == "waiting")

fireNextTimer()
check("Ivy marked summoned after her timeout", summonedFlag("Ivy") == true)
check("Queue is now idle (no one left)", DHAir.summonState == "idle")
check("Both queue entries marked summoned",
    DHAir.db.queue[1].summoned and DHAir.db.queue[2].summoned)

--------------------------------------------------------------------------
-- Section 4b: Manual summon
--------------------------------------------------------------------------
print("== Manual summon ==")
resetState()
groupRoster = { "Zeb", "Yvonne" }
inGroup = true
DHAir.db.active = false -- isolate from the auto-loop; only manual clicks should act
DHAir:QueueAdd("Zeb")
DHAir:QueueAdd("Yvonne")

check("Manual summon of a queued, not-yet-summoned player succeeds", DHAir:ManualSummon("Yvonne") == true)
check("It bypasses FIFO order - Yvonne was second in queue", UnitName(DHAir.pendingCastUnit) == "Yvonne")
check("State machine is now casting", DHAir.summonState == "casting")

-- 2026-08-08 (@kb:manual-override-two-click): this used to be a flat
-- refusal ("You're already summoning someone - please wait"). It's now a
-- warning on the FIRST click and honoured on the second - gate slightly,
-- never prohibit.
check("Switching targets mid-cast warns instead of acting (1st click)",
    DHAir:ManualSummon("Zeb") == false)
check("Still targeting Yvonne after the warning", UnitName(DHAir.pendingCastUnit) == "Yvonne")
check("The warning names both players and says the first stays queued",
    printLog[#printLog]:find("Yvonne", 1, true) ~= nil
    and printLog[#printLog]:find("Zeb", 1, true) ~= nil
    and printLog[#printLog]:find("STAYS in the queue", 1, true) ~= nil)

DHAir.pendingCastUnit = nil -- simulate the button's PreClick consuming it
check("A second click on the same player goes through", DHAir:ManualSummon("Zeb") == true)
check("Now targeting Zeb", UnitName(DHAir.pendingCastUnit) == "Zeb")
check("Yvonne is NOT marked summoned - she stays in the queue (Chris's rule: "
    .. "rather summon someone twice than not at all)", summonedFlag("Yvonne") ~= true)
check("Yvonne is still a waiting queue entry", DHAir:QueueWaitingCount() == 2)
-- The one pending timer belongs to Zeb's NEW cast, not Yvonne's displaced
-- one - firing it must not resolve anything against Yvonne.
check("The displaced summon left no timer of its own",
    DHAir.currentSummon == "Zeb" and DHAir.castWatchdogHandle ~= nil)
fireNextTimer()
check("Firing it still doesn't mark Yvonne summoned", summonedFlag("Yvonne") ~= true)
DHAir.pendingCastUnit = nil

-- The arming is per-player: it must not let a click on a DIFFERENT row
-- inherit someone else's confirmation.
resetState()
groupRoster = { "Abe", "Bea", "Cyd" }
inGroup = true
DHAir.db.active = false
DHAir:QueueAdd("Abe")
DHAir:QueueAdd("Bea")
DHAir:QueueAdd("Cyd")
DHAir:ManualSummon("Abe")
DHAir.pendingCastUnit = nil
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", "Ritual of Summoning")
check("Abe's ritual is in flight", DHAir.summonState == "waiting")
check("First click on Bea warns", DHAir:ManualSummon("Bea") == false)
check("A click on Cyd doesn't inherit Bea's arming", DHAir:ManualSummon("Cyd") == false)
check("Still on Abe after two different first-clicks", DHAir.currentSummon == "Abe")
check("Cyd's own second click goes through", DHAir:ManualSummon("Cyd") == true)
DHAir.pendingCastUnit = nil

resetState()
groupRoster = {}
inGroup = false
DHAir.db.active = false
check("Manual summon of someone not in the queue fails cleanly", DHAir:ManualSummon("Nobody") == false)
check("No cast target was set", DHAir.pendingCastUnit == nil)

-- Auto-summon being off/paused doesn't block a deliberate manual click.
resetState()
groupRoster = { "Walt" }
inGroup = true
DHAir.db.active = false
DHAir.db.paused = true
DHAir:QueueAdd("Walt")
check("Manual summon works even while auto-summon is paused", DHAir:ManualSummon("Walt") == true)

--------------------------------------------------------------------------
-- Section 4c: Auto-promote (ShouldAutoPromote / AutoPromoteSweep)
--------------------------------------------------------------------------
print("== Auto-promote to assistant ==")
resetState()
groupRoster = { "TestChar", "Summ1", "Regular1" }
inRaid = true
inGuild = true
guildRosterNames = { "TestChar", "Summ1" } -- Regular1 is NOT a guild member

DHAir.db.roster.summoners["Summ1"] = { lastSeen = time(), active = true }
DHAir:UpdateGuildRosterCache()

check("A registered, guild-member summoner should be promoted", DHAir:ShouldAutoPromote("Summ1") == true)
check("A non-summoner should not be promoted", DHAir:ShouldAutoPromote("Regular1") == false)

DHAir.db.roster.summoners["Regular1"] = { lastSeen = time(), active = true }
check("A summoner who ISN'T a guild member is skipped when guildOnly is on",
    DHAir:ShouldAutoPromote("Regular1") == false)

DHAir.db.autoPromoteGuildOnly = false
check("...but not once guildOnly is turned off", DHAir:ShouldAutoPromote("Regular1") == true)
DHAir.db.autoPromoteGuildOnly = true

DHAir.db.autoPromote = false
check("Auto-promote entirely off means nobody qualifies", DHAir:ShouldAutoPromote("Summ1") == false)
DHAir.db.autoPromote = true

-- AutoPromoteSweep: only runs anything if I'M actually the leader.
isLeader = false
DHAir:AutoPromoteSweep()
check("Sweep does nothing if I'm not the leader", #promoteAssistantLog == 0)

isLeader = true
DHAir:AutoPromoteSweep()
check("Sweep promotes the qualifying guild summoner", #promoteAssistantLog == 1 and promoteAssistantLog[1] == "Summ1")
-- Note: "already-promoted members are skipped on re-sweep" specifically
-- requires knowing another player's OWN assistant status, which this
-- single-client harness's mocks can't represent (UnitIsGroupLeader/
-- Assistant only answer for "player"). That guarantee is verified in the
-- multi-client harness instead, where it's actually meaningful to test.

--------------------------------------------------------------------------
-- Section 4d: PickBestSummonerForLead
--------------------------------------------------------------------------
print("== PickBestSummonerForLead ranking ==")
resetState()
groupRoster = { "First", "Second", "Third" }
inRaid = true

DHAir.db.roster.summoners["First"] = { lastSeen = time(), active = false }
DHAir.db.roster.summoners["Second"] = { lastSeen = time(), active = true }
DHAir.db.roster.summoners["Third"] = { lastSeen = time(), active = false }

check("Active summoner wins over earlier-joined-but-inactive ones",
    DHAir:PickBestSummonerForLead() == "Second")

DHAir.db.roster.summoners["Second"] = nil -- no longer registered
check("Falls back to earliest join order among remaining (equally inactive) candidates",
    DHAir:PickBestSummonerForLead() == "First")

DHAir.db.roster.summoners = {}
check("No candidates at all returns nil", DHAir:PickBestSummonerForLead() == nil)

--------------------------------------------------------------------------
-- Section 4e: OnPartyLeaderChanged (conservative rescue handoff)
--------------------------------------------------------------------------
print("== Leader-succession rescue handoff ==")
resetState()
groupRoster = { "TestChar", "GoodSummoner" }
inRaid = true
DHAir.db.roster.summoners["GoodSummoner"] = { lastSeen = time(), active = true }

-- Not leader at all: does nothing.
isLeader = false
DHAir:OnPartyLeaderChanged()
check("Not leader: no handoff attempted", #promoteLeaderLog == 0)

-- I AM leader, and I'm not myself a registered summoner: hand off.
isLeader = true
DHAir:OnPartyLeaderChanged()
check("I'm leader but not a summoner: hands off to the best candidate",
    #promoteLeaderLog == 1 and promoteLeaderLog[1] == "GoodSummoner")

-- I AM leader AND I'm a registered summoner myself: deliberately conservative,
-- don't second-guess what might have been an intentional human choice.
resetState()
groupRoster = { "TestChar", "GoodSummoner" }
inRaid = true
isLeader = true
DHAir.db.roster.summoners["TestChar"] = { lastSeen = time(), active = true }
DHAir.db.roster.summoners["GoodSummoner"] = { lastSeen = time(), active = true }
DHAir:OnPartyLeaderChanged()
check("I'm leader AND a registered summoner: no handoff (avoid overriding a deliberate choice)",
    #promoteLeaderLog == 0)

--------------------------------------------------------------------------
-- Section 5: Summon state machine - pause / stop
--------------------------------------------------------------------------
print("== Summon state machine: pause / stop ==")
resetState()
DHAir.db.paused = true -- pause BEFORE the player is queued/available, so QueueAdd can't auto-trigger
QueueAddWithDest("Jack")
groupRoster = { "Jack" }
inGroup = true
DHAir:TrySummonNext()
check("Paused: no cast target resolved", DHAir.pendingCastUnit == nil)
check("Paused: nothing targeted", currentTarget == nil)

DHAir.db.paused = false
DHAir.db.active = false
DHAir:TrySummonNext()
check("Stopped (active=false): no cast target resolved", DHAir.pendingCastUnit == nil)

DHAir.db.active = true
DHAir:TrySummonNext()
check("Resumed + active: auto-pick reaches ready, awaiting a confirm click",
    DHAir.summonState == "ready")
DHAir:ConfirmSummon()
check("Resumed + active: cast target now resolved", DHAir.pendingCastUnit ~= nil)
DHAir.pendingCastUnit = nil -- simulate the button's PreClick consuming it

--------------------------------------------------------------------------
-- Section 6: Summon state machine - player not yet in roster
--------------------------------------------------------------------------
print("== Summon state machine: queued player not yet in group ==")
resetState()
inGroup = true
groupRoster = {}
QueueAddWithDest("Karen")
DHAir:TrySummonNext()
check("No cast target resolved when target not found in roster", DHAir.pendingCastUnit == nil)
check("State remains idle, will retry on GROUP_ROSTER_UPDATE", DHAir.summonState == "idle")

groupRoster = { "Karen" }
DHAir.frame:Fire("GROUP_ROSTER_UPDATE")
check("GROUP_ROSTER_UPDATE triggers a retry, reaching ready once Karen is in roster",
    DHAir.summonState == "ready" and DHAir.pendingEntry and DHAir.pendingEntry.name == "Karen")
DHAir:ConfirmSummon()
check("Confirming resolves a cast target", DHAir.pendingCastUnit ~= nil)
check("Karen is now the resolved target", UnitName(DHAir.pendingCastUnit) == "Karen")
DHAir.pendingCastUnit = nil -- simulate the button's PreClick consuming it

--------------------------------------------------------------------------
-- Section 7: Cast failure handling (no shard / spell error)
--------------------------------------------------------------------------
print("== Summon state machine: cast failure recovery ==")
resetState()
QueueAddWithDest("Leo")
groupRoster = { "Leo" }
inGroup = true
DHAir:TrySummonNext()
check("Auto-pick reaches ready (a real cast attempt can't happen before a confirm click)",
    DHAir.summonState == "ready")
DHAir:ConfirmSummon()
check("Confirming reaches 'casting', target resolved for the button's macro to arm",
    DHAir.summonState == "casting" and UnitName(DHAir.pendingCastUnit) == "Leo")
DHAir.pendingCastUnit = nil -- simulate the button's PreClick consuming it
-- 2026-08-06 (k-0010): the actual cast now happens via the real client's
-- secure macro dispatch, entirely outside what this harness can drive -
-- the failure surface left to test here is the ASYNC one instead: the
-- game reporting the ritual failed (the same event Blizzard fires for a
-- real failed cast - no shard, interrupted, etc.), which
-- HandleSummonFailure already handles identically regardless of how the
-- cast was initiated.
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_FAILED", "player", "guid-fail", "Ritual of Summoning")
check("Failed cast leaves state idle (not stuck in casting/waiting)", DHAir.summonState == "idle")
check("Leo NOT marked summoned after a failed cast", summonedFlag("Leo") ~= true)
check("Leo still present at head of queue for retry", DHAir:QueueNext() and DHAir:QueueNext().name == "Leo")

--------------------------------------------------------------------------
-- Section 7b: Soul Shard threshold gating
--------------------------------------------------------------------------
print("== Soul Shard threshold gating ==")

-- Below threshold: should pause immediately, no target, no cast, no chat.
resetState()
shardCount = 1 -- below the default minShards=2
groupRoster = { "Tara" }
inGroup = true
QueueAddWithDest("Tara")
DHAir:TrySummonNext()
check("Below shard threshold: no cast attempted", #castLog == 0)
check("Below shard threshold: no target acquired", currentTarget == nil)
check("Below shard threshold: no chat announcement sent", #chatLog == 0)
check("Below shard threshold: auto-summon paused", DHAir.db.paused == true)
check("Below shard threshold: pausedForShards flag set", DHAir.pausedForShards == true)
check("Tara NOT falsely marked as summoned", summonedFlag("Tara") ~= true)
check("Tara still at head of queue for later retry", DHAir:QueueNext() and DHAir:QueueNext().name == "Tara")

-- Exactly at threshold: should proceed normally (>= minShards, not <).
resetState()
shardCount = 2
groupRoster = { "Uma" }
inGroup = true
QueueAddWithDest("Uma")
check("At exactly minShards: auto-pick reaches ready", DHAir.summonState == "ready")
DHAir:ConfirmSummon()
check("At exactly minShards: cast target is resolved", DHAir.pendingCastUnit ~= nil)
check("At exactly minShards: not paused", DHAir.db.paused == false)
DHAir.pendingCastUnit = nil -- simulate the button's PreClick consuming it

-- Custom threshold: raising minShards to 3 should now block a count of 2.
resetState()
DHAir.db.minShards = 3
shardCount = 2
groupRoster = { "Vince" }
inGroup = true
QueueAddWithDest("Vince")
DHAir:TrySummonNext()
check("Custom minShards=3 blocks a count of 2", DHAir.db.paused == true and DHAir.pendingCastUnit == nil)

-- Auto-resume via BAG_UPDATE once restocked above threshold.
resetState()
shardCount = 0
groupRoster = { "Wendy" }
inGroup = true
QueueAddWithDest("Wendy")
DHAir:TrySummonNext()
check("Pre-restock: paused for shards", DHAir.db.paused == true and DHAir.pausedForShards == true)

shardCount = 1 -- restocked, but still below default minShards=2
DHAir.frame:Fire("BAG_UPDATE")
check("Restock below threshold: still paused (1 < 2)", DHAir.db.paused == true)

shardCount = 2 -- now at threshold
DHAir.frame:Fire("BAG_UPDATE")
check("Restock at threshold: auto-resumes", DHAir.db.paused == false)
check("Restock at threshold: pausedForShards cleared", DHAir.pausedForShards == false)
check("Restock at threshold: auto-pick reaches ready for Wendy", DHAir.summonState == "ready")
DHAir:ConfirmSummon()
check("Restock at threshold: cast target now resolved for Wendy", DHAir.pendingCastUnit ~= nil)
DHAir.pendingCastUnit = nil -- simulate the button's PreClick consuming it

-- A manual /dhair pause must NEVER be auto-resumed by BAG_UPDATE.
resetState()
_G.SlashCmdList["DHAIR"]("pause") -- pause BEFORE queueing, so QueueAdd can't auto-trigger a cast
shardCount = 5
groupRoster = { "Xena" }
inGroup = true
DHAir:QueueAdd("Xena")
DHAir.frame:Fire("BAG_UPDATE")
check("Manual pause is not disturbed by BAG_UPDATE", DHAir.db.paused == true)
check("Manual pause: no cast target was ever resolved", DHAir.pendingCastUnit == nil)

-- If GetItemCount is unavailable/errors, fail OPEN (don't block the whole
-- addon over a missing/renamed API) rather than stalling forever.
resetState()
groupRoster = { "Yusuf" }
inGroup = true
local realGetItemCount = _G.GetItemCount
_G.GetItemCount = nil -- simulate the API being unavailable
QueueAddWithDest("Yusuf")
check("Missing GetItemCount API: fails open, reaches ready", DHAir.summonState == "ready")
DHAir:ConfirmSummon()
check("Missing GetItemCount API: fails open, cast target still resolved", DHAir.pendingCastUnit ~= nil)
DHAir.pendingCastUnit = nil -- simulate the button's PreClick consuming it
_G.GetItemCount = realGetItemCount

--------------------------------------------------------------------------
-- Section 8: Raid vs group channel routing
--------------------------------------------------------------------------
print("== Channel routing: raid vs group ==")
resetState()
groupRoster = { "Mona" }
inRaid = true
inGroup = false
DHAir.db.messages.raid.enabled = true
DHAir.db.messages.party.enabled = true
QueueAddWithDest("Mona")
DHAir:TrySummonNext()
DHAir:ConfirmSummon() -- 2026-08-04: auto-pick reaches "ready", needs a simulated click to actually cast
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", "Ritual of Summoning")
check("In raid: RAID message sent", countChannel("RAID") == 1)
check("In raid: PARTY message NOT sent (avoids invalid/duplicate chat type)", countChannel("PARTY") == 0)

--------------------------------------------------------------------------
-- Section 9: Guild channel toggle + custom message templating
--------------------------------------------------------------------------
print("== Guild channel + custom message templating ==")
resetState()
groupRoster = { "Nina" }
inGroup = true
inGuild = true
DHAir.db.messages.guild.enabled = true
DHAir.db.messages.guild.text = "Air Service: summoning {target} now, {target}!"
QueueAddWithDest("Nina")
DHAir:TrySummonNext()
DHAir:ConfirmSummon() -- 2026-08-04: auto-pick reaches "ready", needs a simulated click to actually cast
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", "Ritual of Summoning")
check("Guild message sent when enabled and in a guild", countChannel("GUILD") == 1)
for _, entry in ipairs(chatLog) do
    if entry.channel == "GUILD" then
        check("{target} substituted (all occurrences)", entry.msg == "Air Service: summoning Nina now, Nina!")
    end
end

resetState()
groupRoster = { "Oscar" }
inGroup = true
inGuild = true
DHAir.db.messages.guild.enabled = false
DHAir:QueueAdd("Oscar")
DHAir:TrySummonNext()
DHAir:ConfirmSummon() -- 2026-08-04: auto-pick reaches "ready", needs a simulated click to actually cast
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", "Ritual of Summoning")
check("Guild message NOT sent when toggle is off", countChannel("GUILD") == 0)

--------------------------------------------------------------------------
-- Section 9b: Whisper-to-target toggle + realm-qualified targeting
--------------------------------------------------------------------------
print("== Whisper to target ==")
resetState()
groupRoster = { "Patricia" }
inGroup = true
DHAir.db.messages.whisper.text = "Hi {target}, stand by for your summon!"
QueueAddWithDest("Patricia")
DHAir:TrySummonNext()
DHAir:ConfirmSummon() -- 2026-08-04: auto-pick reaches "ready", needs a simulated click to actually cast
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", "Ritual of Summoning")
check("Whisper sent when enabled (default)", countChannel("WHISPER") == 1)
for _, entry in ipairs(chatLog) do
    if entry.channel == "WHISPER" then
        check("Whisper text uses the custom template", entry.msg == "Hi Patricia, stand by for your summon!")
        check("Whisper target is Patricia", entry.target == "Patricia")
    end
end

resetState()
groupRoster = { "Quentin" }
inGroup = true
DHAir.db.messages.whisper.enabled = false
QueueAddWithDest("Quentin")
DHAir:TrySummonNext()
DHAir:ConfirmSummon() -- 2026-08-04: auto-pick reaches "ready", needs a simulated click to actually cast
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", "Ritual of Summoning")
check("Whisper NOT sent when toggle is off", countChannel("WHISPER") == 0)

-- A realm-suffixed name should still whisper the FULL name (needed for the
-- whisper to actually reach the right player), even though chat announcements
-- display the short form.
resetState()
groupRoster = { "Rex-TestRealm" }
inGroup = true
QueueAddWithDest("Rex-TestRealm")
DHAir:TrySummonNext()
DHAir:ConfirmSummon() -- 2026-08-04: auto-pick reaches "ready", needs a simulated click to actually cast
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", "Ritual of Summoning")
for _, entry in ipairs(chatLog) do
    if entry.channel == "WHISPER" then
        check("Whisper target keeps the realm suffix", entry.target == "Rex-TestRealm")
        check("Whisper message text uses the SHORT name for readability",
            entry.msg:find("Rex-TestRealm", 1, true) == nil and entry.msg:find("Rex", 1, true) ~= nil)
    end
end

--------------------------------------------------------------------------
-- Section 9c: Repeated failure safety (no infinite retry / chat spam)
--------------------------------------------------------------------------
print("== Repeated cast failure does not spam chat / loop forever ==")
resetState()
castShouldFail = true -- e.g. the Warlock is out of Soul Shards for this whole run
QueueAddWithDest("Ryan")
groupRoster = { "Ryan" }
inGroup = true
DHAir:TrySummonNext() -- auto-pick reaches "ready" - see the 2026-08-04 comment below
check("Auto-pick reaches ready before any attempt", DHAir.summonState == "ready")

-- 2026-08-04: since even a scheduled RETRY can't call a protected function
-- without its own click (see Summon.lua's HandleSummonFailure explicitly
-- clearing pendingClickDriven before every retry), each attempt -
-- including retries - now needs its own simulated ConfirmSummon click.
-- Alternates confirm-click / fire-retry-timer up to the failure cap; must
-- terminate well before 10 iterations either way.
for i = 1, 10 do
    if DHAir.summonState == "ready" then
        DHAir:ConfirmSummon()
    elseif not fireNextTimer() then
        break
    end
    if DHAir.db.paused then break end
end

check("Cast attempts are capped, not unbounded", #castLog <= 4,
    "castLog had " .. #castLog .. " entries")
check("No successful-cast announcements were ever sent (every attempt failed)",
    #chatLog == 0, "chatLog had " .. #chatLog .. " entries")
check("Auto-summon pauses itself after repeated failures on the same target",
    DHAir.db.paused == true)
check("Ryan is not falsely marked as summoned", summonedFlag("Ryan") ~= true)
check("No retry timers left pending once paused", #timers == 0)

--------------------------------------------------------------------------
-- Section 9c: Async UNIT_SPELLCAST_FAILED retry/pause path (e.g. interrupted
-- or out of range - the cast call itself succeeds but the ritual fails async)
--------------------------------------------------------------------------
print("== Async spellcast-failed events also retry-then-pause correctly ==")
resetState()
groupRoster = { "Sam" }
inGroup = true
QueueAddWithDest("Sam") -- auto-pick reaches "ready" first - see the 2026-08-04 comment below
check("Auto-pick reaches ready for Sam", DHAir.summonState == "ready")
DHAir:ConfirmSummon()
check("Sam's cast is pending confirmation (state='casting')", DHAir.summonState == "casting")

-- 2026-08-04: same as the section above - a scheduled retry can't call a
-- protected function without its own click, so it lands on "ready"
-- instead of "casting" directly; alternates confirming and firing the
-- FAILED event/retry timer up to the failure cap.
for i = 1, 10 do
    if DHAir.summonState == "ready" then
        DHAir:ConfirmSummon()
    elseif DHAir.summonState == "casting" or DHAir.summonState == "waiting" then
        DHAir:OnSpellcastEvent("UNIT_SPELLCAST_FAILED", "player", "guid", "Ritual of Summoning")
        fireNextTimer() -- let the scheduled retry fire, re-attempting BeginCast (lands on "ready")
    else
        break
    end
    if DHAir.db.paused then break end
end

check("Async failures also cap out and pause rather than looping forever",
    DHAir.db.paused == true)
check("Sam is not falsely marked as summoned", summonedFlag("Sam") ~= true)
check("No announcement was ever sent (the ritual never actually succeeded)", #chatLog == 0)

--------------------------------------------------------------------------
-- Section 9d: Channel-driven advance (2026-08-08, Chris's 2nd raid test)
-- Ritual of Summoning CHANNELS; the channel ending is the real end-of-
-- summon signal. The addon used to sit in "waiting" for a fixed
-- db.summonTimeout (30s default) instead, blocking every further summon -
-- see Summon.lua @kb:channel-driven-advance.
--------------------------------------------------------------------------
print("== Channel end advances the queue immediately (no fixed wait) ==")
resetState()
groupRoster = { "Tara", "Umar" }
inGroup = true
DHAir.db.active = true
QueueAddWithDest("Tara")
QueueAddWithDest("Umar")

check("Auto-pick reaches ready for Tara", DHAir.summonState == "ready")
DHAir:ConfirmSummon()
DHAir.pendingCastUnit = nil -- simulate the secure button's PreClick consuming it
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid1", "Ritual of Summoning")
check("SUCCEEDED (channel start) parks in 'waiting'", DHAir.summonState == "waiting")
check("A fallback timer is armed at that point", #timers > 0)

-- The channel actually starting proves channel events work on this client,
-- so the fallback must stand down - if it fired mid-ritual it would arm the
-- next player and confirming them would cancel the ritual in progress.
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_CHANNEL_START", "player", "guid1", "Ritual of Summoning")
check("CHANNEL_START cancels the fallback timer", fireNextTimer() == false)
check("Still 'waiting' - the ritual isn't over yet", DHAir.summonState == "waiting")
check("Tara NOT marked summoned mid-channel", summonedFlag("Tara") ~= true)

-- Channel ends = summon accepted. This is the moment the Warlock is free.
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "guid1", "Ritual of Summoning")
check("Tara marked summoned the moment the channel ends", summonedFlag("Tara") == true)
check("Umar is armed immediately - no 30s dead time",
    DHAir.summonState == "ready" and DHAir.pendingEntry and DHAir.pendingEntry.name == "Umar")

DHAir:ConfirmSummon()
DHAir.pendingCastUnit = nil
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid2", "Ritual of Summoning")
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_CHANNEL_START", "player", "guid2", "Ritual of Summoning")
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "guid2", "Ritual of Summoning")
check("Second summon completes the same way", summonedFlag("Umar") == true)
check("Queue is idle once everyone's been summoned", DHAir.summonState == "idle")
check("No stray timers left pending across both summons", fireNextTimer() == false)

-- k-0036 (2026-08-15, Chris's in-game test): on the real client
-- CHANNEL_START fires BEFORE SUCCEEDED, not simultaneously as assumed
-- above - summonState is still "casting" when it arrives. Must not arm a
-- fallback that could fire mid-ritual.
resetState()
groupRoster = { "Nadia" }
inGroup = true
DHAir.db.active = true
QueueAddWithDest("Nadia")
DHAir:ConfirmSummon()
DHAir.pendingCastUnit = nil
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_CHANNEL_START", "player", "guid5", "Ritual of Summoning")
check("CHANNEL_START while still 'casting' does not error or advance",
    DHAir.summonState == "casting")
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid5", "Ritual of Summoning")
check("SUCCEEDED still parks in 'waiting'", DHAir.summonState == "waiting")
check("No fallback timer armed - CHANNEL_START was already seen", fireNextTimer() == false)
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "guid5", "Ritual of Summoning")
check("CHANNEL_STOP alone finishes the summon", summonedFlag("Nadia") == true)
check("State returns to idle, no stray timer needed", DHAir.summonState == "idle")

-- A channel ending while we're NOT in a summon must not touch the queue
-- (the Warlock channelling Drain Life, Health Funnel, etc).
resetState()
groupRoster = { "Vera" }
inGroup = true
DHAir.db.active = false
QueueAddWithDest("Vera")
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "guid3", "Drain Life")
check("An unrelated channel ending doesn't mark anyone summoned",
    summonedFlag("Vera") ~= true)

-- The fallback still works when channel events never arrive at all.
resetState()
groupRoster = { "Wes" }
inGroup = true
DHAir.db.active = true
QueueAddWithDest("Wes")
DHAir:ConfirmSummon()
DHAir.pendingCastUnit = nil
DHAir:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid4", "Ritual of Summoning")
check("Fallback timer fires when no channel event ever arrives", fireNextTimer() == true)
check("Wes still gets marked summoned via the fallback", summonedFlag("Wes") == true)
check("State returns to idle after the fallback", DHAir.summonState == "idle")

--------------------------------------------------------------------------
-- Section 10: Slash commands
--------------------------------------------------------------------------
print("== Slash commands ==")
resetState()
groupRoster = { "Pete" }
inGroup = true

_G.SlashCmdList["DHAIR"]("stop")
check("/dhair stop sets active=false", DHAir.db.active == false)

_G.SlashCmdList["DHAIR"]("start")
check("/dhair start sets active=true", DHAir.db.active == true)
check("/dhair start clears paused", DHAir.db.paused == false)

_G.SlashCmdList["DHAIR"]("pause")
check("/dhair pause sets paused=true", DHAir.db.paused == true)

_G.SlashCmdList["DHAIR"]("resume")
check("/dhair resume clears paused", DHAir.db.paused == false)

DHAir:QueueAdd("Quinn")
_G.SlashCmdList["DHAIR"]("reset")
check("/dhair reset clears the queue", #DHAir.db.queue == 0)

_G.SlashCmdList["DHAIR"]("invite off")
check("/dhair invite off disables INV auto-invite", DHAir.db.invAutoInvite == false)
_G.SlashCmdList["DHAIR"]("invite on")
check("/dhair invite on re-enables INV auto-invite", DHAir.db.invAutoInvite == true)

_G.SlashCmdList["DHAIR"]("guildonly on")
check("/dhair guildonly on enables guildOnly", DHAir.db.guildOnly == true)
_G.SlashCmdList["DHAIR"]("guildonly off")
check("/dhair guildonly off disables guildOnly", DHAir.db.guildOnly == false)

_G.SlashCmdList["DHAIR"]("config")
check("/dhair config calls Config_Open", printLog[#printLog] == "[stub] Config opened")

--------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------
print("")
print(string.format("RESULTS: %d passed, %d failed", PASS, FAIL))
if FAIL > 0 then
    print("Failures:")
    for _, f in ipairs(failures) do print("  - " .. f) end
    os.exit(1)
else
    print("All tests passed.")
    os.exit(0)
end
