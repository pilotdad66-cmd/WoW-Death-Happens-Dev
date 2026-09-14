-- DH-Air shared-queue test harness.
-- Unlike tests/harness.lua (one simulated client), this harness runs
-- MULTIPLE independent DHAir instances - each with its own addon table,
-- exactly as separate players' game clients would - and wires up a mock
-- "network" so that addon messages sent by one are actually delivered to
-- the others. This is the only way to meaningfully test the claim/race/
-- sync protocol in Sync.lua without an actual WoW server.
--
-- Message delivery is MANUAL (queued, flushed via FlushNetwork()) rather
-- than immediate, specifically so tests can construct true simultaneous
-- races (both clients broadcast before either sees the other's message)
-- and confirm the outcome is identical regardless of delivery order.

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
-- Shared "world" state and identity-aware mocks
--------------------------------------------------------------------------

local clients = {}          -- name -> { DHAir = table }
local currentClientName = nil
local groupRoster = {}      -- shared raid roster (names)
local inRaid, inGroup, inGuild = true, true, false
local shardCounts = {}      -- name -> count
local castShouldFail = {}   -- name -> bool
local currentTargets = {}   -- name -> targeted unit's name
local castLog = {}          -- { {who=, spell=} }
local chatLog = {}          -- { {msg=, channel=, from=} }
local timers = {}           -- name -> list of { fn=, cancelled= }
local pendingNetwork = {}   -- { {prefix=, text=, channel=, target=, sender=} }
local gameTime = 1000
local wallClock = 1000 -- k-0033: real wall-clock seconds, independent of gameTime -
                        -- production code now uses time() (not GetTime()) for anything
                        -- that must survive a relog, e.g. Roster.lua's lastSeen

-- Runs fn() as if the given client's own game client were executing it
-- (controls identity-dependent mocks like UnitName("player")).
local function As(name, fn)
    local prev = currentClientName
    currentClientName = name
    local ok, err = pcall(fn)
    currentClientName = prev
    if not ok then error(err, 0) end
end

_G.GetTime = function() return gameTime end
_G.time = function() return wallClock end

_G.DEFAULT_CHAT_FRAME = { AddMessage = function() end }

_G.CreateFrame = function(frameType, name)
    local f = {}
    local events, scripts = {}, {}
    function f:RegisterEvent(e) events[e] = true end
    function f:UnregisterEvent(e) events[e] = nil end
    function f:SetScript(script, fn) scripts[script] = fn end
    function f:GetScript(script) return scripts[script] end
    function f:Fire(event, ...)
        if scripts.OnEvent then scripts.OnEvent(f, event, ...) end
    end
    return f
end

_G.C_Timer = {
    NewTimer = function(seconds, fn)
        local owner = currentClientName
        timers[owner] = timers[owner] or {}
        local handle = { cancelled = false, fn = fn }
        function handle:Cancel() self.cancelled = true end
        table.insert(timers[owner], handle)
        return handle
    end
}

local function FireNextTimerFor(name)
    local list = timers[name]
    if not list then return false end
    for i = 1, #list do
        if not list[i].cancelled then
            local h = table.remove(list, i)
            As(name, function() h.fn() end)
            return true
        end
    end
    return false
end

_G.IsInRaid = function() return inRaid end
_G.IsInGroup = function() return inGroup or inRaid end
_G.IsInGuild = function() return inGuild end

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

-- Raid leader/assist status is a real, server-verified fact every client
-- agrees on - unlike claims, there's exactly one shared source of truth.
local raidLeader = nil       -- name, or nil
local raidAssistants = {}    -- [name] = true
_G.UnitIsGroupLeader = function(unit)
    local name = _G.UnitName(unit)
    return name ~= nil and name == raidLeader
end
_G.UnitIsGroupAssistant = function(unit)
    local name = _G.UnitName(unit)
    return name ~= nil and raidAssistants[name] == true
end

local guildRosterNames = {} -- shared guild roster: plain "Name" strings (implies online, no rank) or {name=,online=,rankIndex=} tables
_G.GetNumGuildMembers = function() return #guildRosterNames end
_G.GetGuildRosterInfo = function(i)
    local entry = guildRosterNames[i]
    if not entry then return nil end
    if type(entry) == "string" then
        return entry, nil, nil, nil, nil, nil, nil, nil, true
    end
    -- 3rd return value is rankIndex (M3) - see Core.lua's UpdateGuildRosterCache.
    return entry.name, nil, entry.rankIndex, nil, nil, nil, nil, nil, (entry.online ~= false)
end
_G.GuildRoster = function() end
_G.C_GuildInfo = { GuildRoster = function() end }
_G.GetNumGroupMembers = function() return #groupRoster end

_G.UnitName = function(unit)
    if unit == "player" then return currentClientName end
    if unit == "target" then return currentTargets[currentClientName] end
    local idx = tonumber(unit:match("^party(%d+)$") or unit:match("^raid(%d+)$"))
    if idx then return groupRoster[idx] end
    return nil
end

_G.TargetUnit = function(unit)
    local idx = tonumber(unit:match("^party(%d+)$") or unit:match("^raid(%d+)$"))
    currentTargets[currentClientName] = (idx and groupRoster[idx]) or nil
end

_G.UnitExists = function(unit)
    if unit == "target" then return currentTargets[currentClientName] ~= nil end
    return false
end

_G.CastSpellByName = function(spell)
    if castShouldFail[currentClientName] then
        error("mock cast failure for " .. tostring(currentClientName))
    end
    table.insert(castLog, { who = currentClientName, spell = spell })
end

_G.GetSpellInfo = function(spellID) return spellID end

_G.SendChatMessage = function(msg, channel, language, target)
    table.insert(chatLog, { msg = msg, channel = channel, from = currentClientName, target = target })
end

local promoteAssistantLog = {}
local promoteLeaderLog = {}

_G.C_PartyInfo = {
    InviteUnit = function() end,
    PromoteToAssistant = function(name)
        table.insert(promoteAssistantLog, { by = currentClientName, target = name })
        if currentClientName == raidLeader then
            raidAssistants[name] = true
        end
    end,
    PromoteToLeader = function(name)
        table.insert(promoteLeaderLog, { by = currentClientName, target = name })
        if currentClientName == raidLeader then
            raidLeader = name
        end
    end,
}

_G.InCombatLockdown = function() return false end
_G.InviteUnit = function() end
_G.GetBuildInfo = function() return "1.15.7", "12345", "Jan 1 2026", 11507 end

-- Every simulated client reads this as its own DHAir.VERSION (Core.lua's
-- k-0014 metadata read) - matches Sync.lua's MIN_QUEUE_VERSION so the many
-- pre-existing ADD-propagation sections below keep passing unmodified.
-- The MIN_QUEUE_VERSION section further down overrides individual test
-- clients' .VERSION directly to simulate an old build.
_G.GetAddOnMetadata = function(name, field)
    if field == "Version" then return "2.1.6" end
    return nil
end

_G.GetItemCount = function(itemID)
    if itemID == 6265 then return shardCounts[currentClientName] or 10 end
    return 0
end

_G.SlashCmdList = {}

-- Mock addon messaging: queues messages instead of delivering immediately,
-- so tests control exactly when delivery happens (needed to construct true
-- simultaneous-claim races).
_G.C_ChatInfo = {
    RegisterAddonMessagePrefix = function() end,
    SendAddonMessage = function(prefix, text, channel, target)
        table.insert(pendingNetwork, {
            prefix = prefix, text = text, channel = channel,
            target = target, sender = currentClientName,
        })
    end,
}

local function FlushNetwork()
    local rounds = 0
    while #pendingNetwork > 0 do
        rounds = rounds + 1
        if rounds > 20 then error("FlushNetwork: too many rounds - possible message loop") end
        local batch = pendingNetwork
        pendingNetwork = {}
        for _, msg in ipairs(batch) do
            local function deliverTo(recipientName)
                if recipientName == msg.sender then return end
                local c = clients[recipientName]
                if not c then return end
                As(recipientName, function()
                    c.DHAir.frame:Fire("CHAT_MSG_ADDON", msg.prefix, msg.text, msg.channel, msg.sender)
                end)
            end
            if msg.channel == "WHISPER" and msg.target then
                deliverTo(msg.target)
            else
                for name in pairs(clients) do deliverTo(name) end
            end
        end
    end
end

--------------------------------------------------------------------------
-- DH-Tools mock (2026-08-20 DH-Air merge) - see tests\harness.lua's own
-- copy of this mock for the full rationale. One shared mock is enough
-- for every simulated client below - each client's Core.lua re-registers
-- the same "air" module def into it, which is harmless.
--------------------------------------------------------------------------

do
    local registeredModules = {}
    -- Forced on regardless of Core.lua's own registered `default` - see
    -- tests\harness.lua's copy of this comment (2026-08-31: default
    -- flipped to false suite-wide, air included).
    local moduleEnabled = { air = true }
    _G.DHTools = {
        Print = function() end,
        IsAuthorAccount = function() return false end,
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
end

--------------------------------------------------------------------------
-- Client bootstrap
--------------------------------------------------------------------------

-- 2026-08-20 DH-Air merge: files now live under DH-Tools' own Modules\
-- folder and load as part of the "DH-Tools" addon - see tests\harness.lua
-- for why ADDON_NAME changed to match.
local ADDON_ROOT = "C:\\AIProjects-NOSYNC\\WoW\\src\\DH-Tools\\Modules\\DHAir\\"
local ADDON_NAME = "DH-Tools"
local FILES = { "Core.lua", "Destinations.lua", "Queue.lua", "Roster.lua", "Invite.lua", "Sync.lua", "Leadership.lua", "Summon.lua", "Commands.lua" }

local function NewClient(name)
    local DHAir = {}
    for _, filename in ipairs(FILES) do
        local chunk, err = loadfile(ADDON_ROOT .. filename)
        if not chunk then error("Failed to load " .. filename .. ": " .. tostring(err)) end
        chunk(ADDON_NAME, DHAir)
    end
    clients[name] = { DHAir = DHAir }

    -- DHAirDB is a real WoW SavedVariables global. In the actual game each
    -- player has their own client process, so this is naturally isolated;
    -- in this single-process test harness we must force a fresh table per
    -- simulated client or they'd all silently share one saved-variables
    -- table (exactly the kind of bug this harness exists to catch).
    _G.DHAirDB = nil

    As(name, function()
        DHAir.frame:Fire("ADDON_LOADED", ADDON_NAME)
        DHAir.frame:Fire("PLAYER_LOGIN")
    end)

    -- 2026-08-03: TrySummonNext now requires a matching warlockDestination
    -- before it'll pick anyone (see Summon.lua's QueueNextAvailable).
    -- Default every simulated client to a fixed, always-seeded destination
    -- so the many sections written before this feature existed keep
    -- exercising the SAME claim/retry/timeout mechanics they always did.
    -- Sections that specifically test the destination feature itself
    -- (SETDEST/DESTLIST/late-joiner) don't rely on this default either way.
    DHAir.db.warlockDestination = "stormwind"

    return DHAir
end

-- Test-only helper: tags `name`'s queue entry (on the client identified by
-- clientName's own local copy) with the shared default test destination,
-- then re-triggers TrySummonNext - mirrors SetMyDestination's real
-- production behavior, but for a plain queued name that isn't a simulated
-- DH-Air client itself (no SETDEST sender to speak of). Runs inside As()
-- so UnitName("player")-dependent logic (claims, etc.) resolves against
-- the right client. Must be called separately for EVERY client whose
-- local copy of the entry needs to qualify (destination isn't something
-- the bare ADD/whisper path propagates - see Sync.lua's header comment on
-- why SETDEST is self-service only).
local function TagDest(clientName, name, destId)
    As(clientName, function()
        local client = clients[clientName].DHAir
        client:ApplyDestination(name, destId or "stormwind")
        client:TrySummonNext()
    end)
end

local function ResetWorld()
    clients = {}
    currentClientName = nil
    groupRoster = {}
    inRaid, inGroup, inGuild = true, true, false
    guildRosterNames = {}
    raidLeader = nil
    raidAssistants = {}
    promoteAssistantLog = {}
    promoteLeaderLog = {}
    shardCounts = {}
    castShouldFail = {}
    currentTargets = {}
    castLog = {}
    chatLog = {}
    timers = {}
    pendingNetwork = {}
    gameTime = 1000
    wallClock = 1000
    _G.DHAirDB = nil
end

local function CastCountFor(name)
    local n = 0
    for _, c in ipairs(castLog) do
        if c.who == name then n = n + 1 end
    end
    return n
end

--------------------------------------------------------------------------
-- Section 1: Basic ADD propagation between two Warlocks
--------------------------------------------------------------------------
print("== Shared queue: ADD propagation ==")
ResetWorld()
local Alice = NewClient("Alice")
local Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10

-- "air" (the default code phrase) rather than "inv" since 2026-08-05:
-- plain invite requests no longer queue anyone, only the code phrase does.
As("Alice", function() Alice:HandleWhisper("air", "Carol") end)
check("Alice has Carol queued locally", Alice:QueueNext() ~= nil and Alice:QueueNext().name == "Carol")
check("Bob does NOT have Carol yet (not flushed)", Bob:QueueNext() == nil)

FlushNetwork()
check("After flush, Bob also has Carol queued", Bob:QueueNext() ~= nil and Bob:QueueNext().name == "Carol")

--------------------------------------------------------------------------
-- Section 2: Sequential claim prevents a double-summon
--------------------------------------------------------------------------
print("== Shared queue: sequential claim prevents double-summon ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob", "Dave" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Alice", function() Alice:HandleWhisper("air", "Dave") end)
FlushNetwork()
check("Both have Dave queued", Alice:QueueNext().name == "Dave" and Bob:QueueNext().name == "Dave")
As("Alice", function() Alice:ApplyDestination("Dave", "stormwind") end)
As("Bob", function() Bob:ApplyDestination("Dave", "stormwind") end)

As("Alice", function() Alice:TrySummonNext() end)
check("Alice enters claiming state", Alice.summonState == "claiming")
FlushNetwork() -- delivers Alice's CLAIM to Bob

As("Bob", function() Bob:TrySummonNext() end)
check("Bob sees Dave as claimed and does nothing", Bob.summonState == "idle")
check("Bob has not cast anything", CastCountFor("Bob") == 0)

FireNextTimerFor("Alice") -- Alice's claim grace period elapses uncontested
-- 2026-08-04 (one-click auto-summon redesign): resolving the claim reaches
-- "ready", not a cast - TargetUnit/CastSpellByName can't be called outside
-- a real click (see Summon.lua's BeginCast). ConfirmSummon simulates it.
check("Alice reaches ready, awaiting a confirm click", Alice.summonState == "ready")
As("Alice", function() Alice:ConfirmSummon() end)
check("Alice proceeds to cast", UnitName(Alice.pendingCastUnit) == "Dave")
Alice.pendingCastUnit = nil -- simulate the button's PreClick consuming it
check("Only Alice cast, never Bob", CastCountFor("Bob") == 0)

--------------------------------------------------------------------------
-- Section 3: True simultaneous claim race - deterministic, order-independent
--------------------------------------------------------------------------
print("== Shared queue: simultaneous claim race resolves deterministically ==")

local function RunRaceTest(nameA, nameB, deliverAFirst)
    ResetWorld()
    local A = NewClient(nameA)
    local B = NewClient(nameB)
    groupRoster = { nameA, nameB, "Erin" }
    shardCounts[nameA], shardCounts[nameB] = 10, 10

    -- Pause both while seeding the queue directly (bypassing whispers/ADD
    -- broadcasts entirely) so QueueAdd's own auto-trigger can't fire early
    -- and leak one side's claim to the other before the race is set up.
    As(nameA, function() A.db.paused = true end)
    As(nameB, function() B.db.paused = true end)
    As(nameA, function() A:QueueAdd("Erin"); A:ApplyDestination("Erin", "stormwind") end)
    As(nameB, function() B:QueueAdd("Erin"); B:ApplyDestination("Erin", "stormwind") end)
    As(nameA, function() A.db.paused = false end)
    As(nameB, function() B.db.paused = false end)

    -- Both decide to claim Erin before either has seen the other's claim.
    As(nameA, function() A:TrySummonNext() end)
    As(nameB, function() B:TrySummonNext() end)
    check("Both entered claiming state before any delivery (" .. nameA .. "/" .. nameB .. ")",
        A.summonState == "claiming" and B.summonState == "claiming")

    if not deliverAFirst then
        -- Reverse delivery order within the flush to prove order doesn't matter.
        local reordered = {}
        for i = #pendingNetwork, 1, -1 do table.insert(reordered, pendingNetwork[i]) end
        pendingNetwork = reordered
    end

    FlushNetwork()

    local expectedWinner = (nameA < nameB) and nameA or nameB
    local expectedLoser = (expectedWinner == nameA) and nameB or nameA

    check("Loser (" .. expectedLoser .. ") backs off immediately on message delivery",
        clients[expectedLoser].DHAir.summonState == "idle")
    check("Winner (" .. expectedWinner .. ") is still claiming, awaiting its own grace timer",
        clients[expectedWinner].DHAir.summonState == "claiming")

    FireNextTimerFor(expectedWinner)
    check("Winner (" .. expectedWinner .. ") reaches ready, awaiting a confirm click",
        clients[expectedWinner].DHAir.summonState == "ready")
    As(expectedWinner, function() clients[expectedWinner].DHAir:ConfirmSummon() end)
    check("Winner (" .. expectedWinner .. ") casts", UnitName(clients[expectedWinner].DHAir.pendingCastUnit) == "Erin")
    clients[expectedWinner].DHAir.pendingCastUnit = nil -- simulate the button's PreClick consuming it
    check("Loser (" .. expectedLoser .. ") never casts", CastCountFor(expectedLoser) == 0)
end

RunRaceTest("Alice", "Bob", true)   -- Alice < Bob; deliver in send order
RunRaceTest("Alice", "Bob", false)  -- Alice < Bob; deliver in REVERSE order - same winner expected
RunRaceTest("Amy", "Zack", true)    -- Amy < Zack; confirms winner is name-based, not a fixed slot

--------------------------------------------------------------------------
-- Section 4: Stale claim self-heals (claimant vanished mid-cast)
--------------------------------------------------------------------------
print("== Shared queue: stale claim self-heals ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob", "Frank" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Alice", function() Alice:HandleWhisper("air", "Frank") end)
FlushNetwork()
As("Alice", function() Alice:ApplyDestination("Frank", "stormwind") end)
As("Bob", function() Bob:ApplyDestination("Frank", "stormwind") end)

As("Alice", function() Alice:TrySummonNext() end)
FlushNetwork() -- Bob now sees Frank as claimed by Alice
check("Frank is claimed (fresh) - Bob sees him as unavailable", (function()
    As("Bob", function() end) -- no-op, just to keep As-pattern consistent
    return Bob:QueueNextAvailable(true) == nil
end)())

-- Alice "disconnects" without ever resolving (no timer fire, no release).
-- Simulate real time passing well beyond the claim TTL.
gameTime = gameTime + 200

As("Bob", function() Bob:TrySummonNext() end)
check("Bob now treats the stale claim as expired and claims Frank himself",
    Bob.summonState == "claiming" and Bob.currentSummon == "Frank")

--------------------------------------------------------------------------
-- Section 5: SUMMONED broadcast marks done everywhere and clears the claim
--------------------------------------------------------------------------
print("== Shared queue: SUMMONED propagates and prevents re-queueing ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob", "Grace" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Alice", function() Alice:HandleWhisper("air", "Grace") end)
FlushNetwork()
As("Alice", function() Alice:ApplyDestination("Grace", "stormwind") end)
As("Bob", function() Bob:ApplyDestination("Grace", "stormwind") end)
As("Alice", function() Alice:TrySummonNext() end)
FireNextTimerFor("Alice") -- uncontested, resolves claim, reaches "ready"
check("Alice reaches ready, awaiting a confirm click", Alice.summonState == "ready")
As("Alice", function() Alice:ConfirmSummon() end)
check("Alice is casting", Alice.summonState == "casting")

As("Alice", function()
    Alice:OnSpellcastEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "guid", "Ritual of Summoning")
end)
check("Alice is now waiting for the timeout", Alice.summonState == "waiting")

FireNextTimerFor("Alice") -- the completion timeout elapses
FlushNetwork() -- delivers the SUMMONED broadcast

local function EntryFor(client, name)
    for _, e in ipairs(client.db.queue) do
        if client:NormalizeName(e.name) == name then return e end
    end
end

check("Grace is marked summoned for Alice", EntryFor(Alice, "Grace").summoned == true)
check("Grace is ALSO marked summoned for Bob", EntryFor(Bob, "Grace").summoned == true)
check("Bob's claim on Grace (if any) is cleared", Bob:GetClaim("Grace") == nil)

-- 2026-08-07 (@kb:air-requeue-always, design D4/D9). This used to assert
-- that Bob REFUSES the re-queue. He no longer does: a blocked join is a
-- worse failure than an accidental re-summon, and the db.history table
-- that enforced it was never cleared at login, so the block was permanent.
As("Bob", function() Bob:HandleWhisper("air", "Grace") end)
check("Bob re-queues a previously-summoned player on request",
    Bob:QueueNext() ~= nil and Bob:NormalizeName(Bob:QueueNext().name) == "Grace")
check("...reusing the existing row, not appending a duplicate",
    #Bob.db.queue == 1)

-- The FRESHNESS GUARD: Alice still holds the old snapshot saying Grace is
-- summoned. Merging it must NOT silently undo the re-join Bob just made.
FlushNetwork()
As("Bob", function() Bob:Sync_MergeEntries({
    { name = "Grace", summoned = true, elapsed = 600 },
}) end)
check("A stale 'summoned' snapshot does not re-flag a fresh re-queue",
    EntryFor(Bob, "Grace").summoned == false)

-- ...but a snapshot at least as new as ours is still honored, or the
-- protocol's one hard guarantee (never double-summon) would be lost.
As("Bob", function() Bob:Sync_MergeEntries({
    { name = "Grace", summoned = true, elapsed = 0 },
}) end)
check("A current 'summoned' snapshot is still applied",
    EntryFor(Bob, "Grace").summoned == true)

--------------------------------------------------------------------------
-- Section 6: RELEASE after giving up lets the other Warlock take over
--------------------------------------------------------------------------
print("== Shared queue: giving up releases the claim for others ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob", "Henry" }
shardCounts.Alice, shardCounts.Bob = 10, 10
-- 2026-08-06 (k-0010): castShouldFail/CastSpellByName no longer drive this -
-- BeginCast doesn't call CastSpellByName itself anymore (see Summon.lua).
-- Alice's repeated failures are now simulated via the async
-- UNIT_SPELLCAST_FAILED event instead (the same event the real client
-- fires for an actually-failed cast), right after each ConfirmSummon.

As("Alice", function() Alice:HandleWhisper("air", "Henry") end)
FlushNetwork()
As("Alice", function() Alice:ApplyDestination("Henry", "stormwind") end)
As("Bob", function() Bob:ApplyDestination("Henry", "stormwind") end)
As("Alice", function() Alice:TrySummonNext() end)
FireNextTimerFor("Alice") -- resolves claim, reaches "ready"
check("Alice reaches ready before her first attempt", Alice.summonState == "ready")
As("Alice", function() Alice:ConfirmSummon() end) -- attempt #1: resolves target, reaches "casting"
As("Alice", function()
    Alice:OnSpellcastEvent("UNIT_SPELLCAST_FAILED", "player", "guid1", "Ritual of Summoning")
end) -- simulates the game reporting attempt #1 failed
check("Alice's first cast attempt failed", Alice.db.paused == false or Alice.failCount > 0)

-- Drain Alice's retry timers until she gives up (MAX_CONSECUTIVE_FAILURES).
-- 2026-08-04: each retry also lands on "ready" pending a confirm click (see
-- Summon.lua's HandleSummonFailure) - alternate firing the retry timer,
-- confirming, and failing again (see 2026-08-06 comment above) until she
-- gives up.
for i = 1, 10 do
    if Alice.db.paused then break end
    if Alice.summonState == "ready" then
        As("Alice", function() Alice:ConfirmSummon() end)
        As("Alice", function()
            Alice:OnSpellcastEvent("UNIT_SPELLCAST_FAILED", "player", "guid-retry", "Ritual of Summoning")
        end)
    else
        FireNextTimerFor("Alice")
    end
end
check("Alice eventually pauses after repeated failures", Alice.db.paused == true)

FlushNetwork() -- delivers Alice's RELEASE for Henry, which lets Bob's queued retries claim it

check("Henry is no longer claimed by Alice", (function()
    local claim = Bob:GetClaim("Henry")
    return claim == nil or claim.by ~= "Alice"
end)())

As("Bob", function() Bob:TrySummonNext() end)
FireNextTimerFor("Bob")
check("Bob reaches ready for Henry", Bob.summonState == "ready")
As("Bob", function() Bob:ConfirmSummon() end)
check("Bob successfully takes over - cast target resolved to Henry", UnitName(Bob.pendingCastUnit) == "Henry")
Bob.pendingCastUnit = nil -- simulate the button's PreClick consuming it

--------------------------------------------------------------------------
-- Section 7: Shared RESET clears everyone's queue
--------------------------------------------------------------------------
print("== Shared queue: RESET propagates to all Warlocks ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Alice", function() Alice:HandleWhisper("air", "Ivan") end)
FlushNetwork()
check("Bob has Ivan queued before reset", Bob:QueueNext() ~= nil)

As("Alice", function()
    Alice:QueueReset()
    Alice:Sync_BroadcastReset()
end)
FlushNetwork()
check("Bob's queue is empty after the shared reset", #Bob.db.queue == 0)

--------------------------------------------------------------------------
-- Section 8: Late joiner catches up via SYNCREQ / SYNCDATA
--------------------------------------------------------------------------
print("== Shared queue: late joiner syncs existing state ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Alice", function()
    Alice:HandleWhisper("air", "Jack")
    Alice:QueueAdd("Kelly")
    Alice:QueueMarkSummoned("Kelly") -- pretend Kelly was already summoned earlier
end)
FlushNetwork() -- Bob picks up Jack via the normal ADD path (Kelly was added directly, not via whisper, so no broadcast for her - that's fine, SYNCDATA will carry her)

table.insert(groupRoster, "Carl") -- the late joiner is also in the raid
local Carl = NewClient("Carl") -- fires PLAYER_LOGIN -> Sync_Init -> HELLO + SYNCREQ
FlushNetwork() -- delivers Carl's SYNCREQ to Alice & Bob, and their SYNCDATA replies back to Carl

check("Carl learned about Jack (waiting)",
    Carl:QueueNext() ~= nil)
local jackEntry, kellyEntry
for _, e in ipairs(Carl.db.queue) do
    if Carl:NormalizeName(e.name) == "Jack" then jackEntry = e end
    if Carl:NormalizeName(e.name) == "Kelly" then kellyEntry = e end
end
check("Carl has Jack as waiting", jackEntry ~= nil and jackEntry.summoned == false)
check("Carl has Kelly as already-summoned (from the state sync)", kellyEntry ~= nil and kellyEntry.summoned == true)
-- db.history removed 2026-08-07 (@kb:air-requeue-always) - the summoned
-- FLAG on the entry itself is now the only record, and it no longer blocks
-- a re-queue, it just tells the Warlock what already happened.
check("db.history is gone on a freshly synced client", Carl.db.history == nil)

--------------------------------------------------------------------------
-- Section 9: Chunked SYNCDATA reassembles correctly for a large queue
--------------------------------------------------------------------------
print("== Shared queue: chunked sync reassembles a large queue ==")
ResetWorld()
Alice = NewClient("Alice")
groupRoster = { "Alice" }
shardCounts.Alice = 10

As("Alice", function()
    for i = 1, 40 do
        Alice:QueueAdd("Player" .. i)
    end
end)
check("Alice's queue really is large enough to require chunking",
    #table.concat((function()
        local parts = {}
        for _, e in ipairs(Alice.db.queue) do table.insert(parts, e.name .. ":0") end
        return parts
    end)(), ",") > 200)

table.insert(groupRoster, "Dana")
local Dana = NewClient("Dana")
FlushNetwork()

check("Dana received the full 40-player queue", #Dana.db.queue == 40)
local allPresent = true
for i = 1, 40 do
    local found = false
    for _, e in ipairs(Dana.db.queue) do
        if Dana:NormalizeName(e.name) == "Player" .. i then found = true break end
    end
    if not found then allPresent = false end
end
check("All 40 players present after chunked reassembly", allPresent)

--------------------------------------------------------------------------
-- Section 10: Sharing OFF behaves exactly like solo mode (no network chatter)
--------------------------------------------------------------------------
print("== Shared queue: sharing off means no claim delay, no network traffic ==")
ResetWorld()
Alice = NewClient("Alice")
groupRoster = { "Alice", "Liam" }
shardCounts.Alice = 10
As("Alice", function() Alice.db.shareQueue = false end)
pendingNetwork = {} -- discard the HELLO/SYNCREQ sent during login before sharing was turned off

As("Alice", function()
    Alice:HandleWhisper("air", "Liam") -- own internal auto-trigger fires here, finds nothing yet (no destination)
    Alice:ApplyDestination("Liam", "stormwind")
    Alice:TrySummonNext() -- re-trigger now that Liam actually qualifies
end)
check("No network messages were queued while sharing is off", #pendingNetwork == 0)
-- 2026-08-04: sharing off only skips the claim-grace timer/network chatter -
-- TrySummonNext is still not a real click, so it still lands on "ready"
-- pending a confirm (see StartSummonAttempt/BeginCast's pendingClickDriven
-- gate). Confirm here to simulate that one required click.
check("Alice went straight to 'ready', skipping 'claiming' entirely", Alice.summonState == "ready")
As("Alice", function() Alice:ConfirmSummon() end)
check("Cast target resolved on confirm, no claiming interim state", Alice.pendingCastUnit ~= nil)
check("Alice is now casting", Alice.summonState == "casting")
Alice.pendingCastUnit = nil -- simulate the button's PreClick consuming it

--------------------------------------------------------------------------
-- Section 11: guildOnly is a personal filter layered on top of the shared queue
--------------------------------------------------------------------------
print("== Shared queue: guildOnly filters independently per Warlock ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob", "Outsider" }
shardCounts.Alice, shardCounts.Bob = 10, 10
inGuild = true
guildRosterNames = { "Alice", "Bob" } -- Outsider is NOT a guild member

As("Alice", function() Alice.db.guildOnly = true; Alice:UpdateGuildRosterCache() end)
As("Bob", function() Bob.db.guildOnly = false; Bob:UpdateGuildRosterCache() end)

-- Bob (no restriction) invites/queues the non-guild Outsider and it syncs to Alice too.
As("Bob", function() Bob.db.paused = true end) -- prevent Bob's own auto-trigger from casting before we're ready
As("Bob", function() Bob:QueueAdd("Outsider") end)
FlushNetwork()
As("Alice", function() Alice:ApplyDestination("Outsider", "stormwind") end)
As("Bob", function() Bob:ApplyDestination("Outsider", "stormwind") end)
check("Outsider syncs into Alice's queue too (shared queue doesn't pre-filter)",
    (function()
        for _, e in ipairs(Alice.db.queue) do
            if Alice:NormalizeName(e.name) == "Outsider" then return true end
        end
        return false
    end)())

-- Alice, despite having Outsider in her queue, must never claim/cast on them.
As("Alice", function() Alice:TrySummonNext() end)
check("Alice (guildOnly) does not claim the non-guild Outsider",
    Alice.summonState == "idle" and CastCountFor("Alice") == 0)

-- Bob (unrestricted) can still take Outsider himself.
As("Bob", function() Bob.db.paused = false end)
As("Bob", function() Bob:TrySummonNext() end)
FireNextTimerFor("Bob")
check("Bob reaches ready for Outsider", Bob.summonState == "ready")
As("Bob", function() Bob:ConfirmSummon() end)
check("Bob (unrestricted) successfully claims and resolves a cast target on Outsider",
    UnitName(Bob.pendingCastUnit) == "Outsider")
Bob.pendingCastUnit = nil -- simulate the button's PreClick consuming it

--------------------------------------------------------------------------
-- Section 12: GUILD channel fallback (no raid, no party, still syncs)
--------------------------------------------------------------------------
print("== GUILD channel: syncing with no raid or party at all ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = {}       -- nobody is grouped
inRaid, inGroup = false, false
inGuild = true         -- but both are in the same guild
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Alice", function()
    check("Sync_Channel falls back to GUILD with no raid/party", Alice:Sync_Channel() == "GUILD")
    check("Sync_IsActive is true via GUILD alone", Alice:Sync_IsActive() == true)
end)

As("Alice", function() Alice:QueueAdd("Erin") end)
FlushNetwork()
check("Queue entry propagates over GUILD with no group at all",
    Bob:QueueNext() ~= nil and Bob:QueueNext().name == "Erin")

-- Also confirm it correctly reports inactive when NOT in a guild either.
inGuild = false
As("Alice", function()
    check("Sync_Channel is nil with no raid, no party, no guild", Alice:Sync_Channel() == nil)
end)

--------------------------------------------------------------------------
-- Section 13: REGISTER/UNREGISTER propagate across clients
--------------------------------------------------------------------------
print("== Roster: REGISTER/UNREGISTER propagate across clients ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Alice", function() Alice:SetRole("summoner", true) end)
check("Alice knows her own registration before any flush", Alice:IsRegistered("summoner", "Alice") == true)
check("Bob does NOT know yet (not flushed)", Bob:IsRegistered("summoner", "Alice") == false)

FlushNetwork()
check("Bob learns Alice is a registered summoner after flush", Bob:IsRegistered("summoner", "Alice") == true)
check("Bob's summoner count reflects it", Bob:CountRegistered("summoner") == 1)
check("Bob sees Alice as active (auto-summon on by default)", Bob:IsSummonerActive("Alice") == true)

As("Alice", function()
    Alice.db.paused = true
    Alice:SetRole("summoner", false) -- re-toggle to force a fresh REGISTER broadcast with the new state
    Alice:SetRole("summoner", true)
end)
FlushNetwork()
check("Bob sees Alice's paused state reflected", Bob:IsSummonerActive("Alice") == false)

As("Alice", function() Alice:SetRole("summoner", false) end)
FlushNetwork()
check("Bob sees the unregistration too", Bob:IsRegistered("summoner", "Alice") == false)
check("Bob's summoner count drops back to 0", Bob:CountRegistered("summoner") == 0)

-- Registering while already queued elsewhere re-stamps that entry for
-- EVERYONE, not just the registrant's own client.
As("Bob", function() Bob:HandleWhisper("air", "Felicity") end)
FlushNetwork()
check("Alice sees Felicity queued with no role yet", Alice:QueueNext().role == nil)
-- Simulate Felicity's OWN client joining and registering (the realistic path).
groupRoster = { "Alice", "Bob", "Felicity" }
local Felicity = NewClient("Felicity")
shardCounts.Felicity = 10
FlushNetwork() -- Felicity's SYNCREQ/HELLO exchange
As("Felicity", function() Felicity:SetRole("clicker", true) end)
FlushNetwork()
check("Alice's copy of Felicity's queue entry is re-stamped with her role",
    (function()
        for _, e in ipairs(Alice.db.queue) do
            if Alice:NormalizeName(e.name) == "Felicity" then return e.role == "clicker" end
        end
        return false
    end)())

--------------------------------------------------------------------------
-- Section 14: late joiner's SYNCDATA includes role and wait time
--------------------------------------------------------------------------
print("== Late joiner sync includes role and wait time ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Alice", function() Alice:HandleWhisper("air", "Gareth") end)
FlushNetwork() -- Bob learns about Gareth too, so both have a consistent view

groupRoster = { "Alice", "Bob", "Gareth" }
local Gareth = NewClient("Gareth")
shardCounts.Gareth = 10
FlushNetwork() -- Gareth's own HELLO/SYNCREQ round catches him up

As("Gareth", function() Gareth:SetRole("clicker", true) end)
FlushNetwork() -- propagates to BOTH Alice and Bob consistently, before Harold ever asks

gameTime = gameTime + 47 -- let some wait time accumulate before the late joiner arrives

table.insert(groupRoster, "Harold")
local Harold = NewClient("Harold")
FlushNetwork()

local gEntry = nil
for _, e in ipairs(Harold.db.queue) do
    if Harold:NormalizeName(e.name) == "Gareth" then gEntry = e end
end
check("Late joiner learns Gareth's role via SYNCDATA", gEntry ~= nil and gEntry.role == "clicker")
check("Late joiner's computed wait time is approximately correct (within a couple seconds)",
    gEntry ~= nil and math.abs((gameTime - gEntry.queuedAt) - 47) <= 2)

--------------------------------------------------------------------------
-- Section 15: REMOVE - self-removal always works, removing others requires
-- the SENDER to be leader/assist, verified by the RECEIVER independently
--------------------------------------------------------------------------
print("== REMOVE: self always works, others require verified sender authority ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Bob", function() Bob:HandleWhisper("air", "Ivy") end)
FlushNetwork()
check("Both have Ivy queued", Alice:QueueNext() ~= nil and Bob:QueueNext() ~= nil)

-- Bob (a regular member, not leader/assist) tries to remove Ivy.
raidLeader = nil
As("Bob", function() Bob:RequestRemove("Ivy") end)
FlushNetwork()
check("Bob's own copy still has Ivy (RequestRemove refused locally, never even sent)",
    Bob:QueueNext() ~= nil and Bob:QueueNext().name == "Ivy")
check("Alice's copy still has Ivy too - nothing was ever broadcast",
    Alice:QueueNext() ~= nil and Alice:QueueNext().name == "Ivy")

-- Now make Bob the raid leader and try again.
raidLeader = "Bob"
As("Bob", function()
    check("Bob now has remove_any permission", Bob:HasPermission("remove_any") == true)
    Bob:RequestRemove("Ivy")
end)
check("Bob's own copy no longer has Ivy", Bob:QueueNext() == nil)
FlushNetwork()
check("Alice's copy ALSO no longer has Ivy - Alice independently verified Bob is leader",
    Alice:QueueNext() == nil)

-- Self-removal never needs any of this.
raidLeader = nil
As("Alice", function() Alice:HandleWhisper("air", "Jasper") end)
FlushNetwork()
groupRoster = { "Alice", "Bob", "Jasper" }
local Jasper = NewClient("Jasper")
shardCounts.Jasper = 10
FlushNetwork()
As("Jasper", function() Jasper:RequestRemove("Jasper") end)
FlushNetwork()
check("Jasper removed himself with no leader at all", Alice:QueueNext() == nil and Bob:QueueNext() == nil)

--------------------------------------------------------------------------
-- Section 16: CLEARALL requires verified leader/assist, propagates to everyone
--------------------------------------------------------------------------
print("== CLEARALL: requires verified authority, clears for everyone ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Alice", function() Alice:HandleWhisper("air", "Karl") end)
FlushNetwork()

-- Bob is a regular member: his CLEARALL should be refused locally, nothing sent.
raidLeader = "Alice"
As("Bob", function()
    check("Bob lacks clear_all permission", Bob:HasPermission("clear_all") == false)
    check("RequestClearAll refuses for Bob", Bob:RequestClearAll() == false)
end)
FlushNetwork()
check("Karl is still queued for both", Alice:QueueNext() ~= nil and Bob:QueueNext() ~= nil)

-- Alice IS the leader: her CLEARALL should work and propagate.
As("Alice", function()
    check("Alice has clear_all permission", Alice:HasPermission("clear_all") == true)
    Alice:RequestClearAll()
end)
FlushNetwork()
check("Bob's queue is cleared too, not just Alice's", #Bob.db.queue == 0)

-- An assistant (not the leader) should also be able to clear.
raidLeader = "Alice"
raidAssistants = { Bob = true }
As("Alice", function() Alice:HandleWhisper("air", "Liam") end)
FlushNetwork()
As("Bob", function()
    check("Bob (assistant, not leader) also has clear_all permission", Bob:HasPermission("clear_all") == true)
    Bob:RequestClearAll()
end)
FlushNetwork()
check("Assistant's clear propagated to Alice too", #Alice.db.queue == 0)

--------------------------------------------------------------------------
-- Section 16a2: a peer who missed a CLEARALL broadcast (offline at the
-- time) doesn't resurrect the queue for everyone else on our next login,
-- and gets healed back to empty itself (2026-08-15, @kb:air-queue-clear-epoch)
--------------------------------------------------------------------------
print("== Stale peer (missed CLEARALL) doesn't resurrect the queue; gets healed ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10
raidLeader = "Alice"

As("Alice", function() Alice:HandleWhisper("air", "Moira") end)
FlushNetwork()
check("Both have Moira queued before the clear",
    Alice:QueueNext() ~= nil and Bob:QueueNext() ~= nil)

-- Bob "goes offline" right before Alice clears - he never receives the
-- CLEARALL broadcast and keeps his stale copy of Moira.
local bobWrapper = clients["Bob"]
clients["Bob"] = nil

gameTime, wallClock = gameTime + 10, wallClock + 10
As("Alice", function() Alice:RequestClearAll() end)
FlushNetwork()
check("Alice's own queue is cleared", #Alice.db.queue == 0)

-- Time passes while Bob is still offline, holding Moira from before the clear.
gameTime, wallClock = gameTime + 600, wallClock + 600

-- Bob reconnects, still with his stale queue. Alice (not Bob) is the one
-- who asks for a resync here - mirrors the real report: the client with
-- the CORRECT state logs in / re-syncs and hears back from a stale peer.
clients["Bob"] = bobWrapper
As("Alice", function() Alice:Sync_Send("SYNCREQ") end)
FlushNetwork()

check("Alice's queue was NOT resurrected by Bob's stale copy", #Alice.db.queue == 0,
    "Alice.db.queue has " .. #Alice.db.queue .. " entries")
check("Bob's own stale queue got healed back to empty", #Bob.db.queue == 0,
    "Bob.db.queue has " .. #Bob.db.queue .. " entries")

-- Guard shouldn't be overly broad - a genuinely fresh entry after the heal
-- still syncs normally both ways.
As("Alice", function() Alice:HandleWhisper("air", "Nadia") end)
FlushNetwork()
check("Fresh entry after the heal still syncs normally to Bob",
    Bob:QueueNext() ~= nil and Bob:QueueNext().name == "Nadia")

--------------------------------------------------------------------------
-- Section 16b: CLEARROSTER requires verified leader/assist, propagates
-- to everyone, and now also clears the queue (2026-08-18, was
-- deliberately queue-untouched from 2026-08-13 until the D5
-- auto-joined-row orphan edge case prompted Chris to fold the two
-- together)
--------------------------------------------------------------------------
print("== CLEARROSTER: requires verified authority, clears for everyone, queue too ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Alice", function() Alice:HandleWhisper("air", "Karl") end)
As("Bob", function() Bob:SetRole("summoner", true) end)
As("Alice", function() Alice:SetRole("clicker", true) end)
FlushNetwork()
check("Both clients see both registrations", Alice:CountRegistered("summoner") == 1
    and Alice:CountRegistered("clicker") == 1
    and Bob:CountRegistered("summoner") == 1
    and Bob:CountRegistered("clicker") == 1)

-- Bob is a regular member: his CLEARROSTER should be refused locally,
-- nothing sent.
raidLeader = "Alice"
As("Bob", function()
    check("Bob lacks clear_roster permission", Bob:HasPermission("clear_roster") == false)
    check("RequestClearRoster refuses for Bob", Bob:RequestClearRoster() == false)
end)
FlushNetwork()
check("Registrations are untouched", Alice:CountRegistered("summoner") == 1 and Bob:CountRegistered("summoner") == 1)

-- Alice IS the leader: her CLEARROSTER should work and propagate.
-- 2026-08-18 (Chris-reported): CLEARROSTER now ALSO wipes the queue on
-- every client, not just registrations - fixes the orphaned D5
-- auto-joined queue row a roster-only clear used to leave behind. Karl
-- should be gone from the queue on both clients too.
As("Alice", function()
    check("Alice has clear_roster permission", Alice:HasPermission("clear_roster") == true)
    Alice:RequestClearRoster()
end)
FlushNetwork()
check("Bob's roster is cleared too, not just Alice's",
    Bob:CountRegistered("summoner") == 0 and Bob:CountRegistered("clicker") == 0)
check("Alice's own roster is cleared", Alice:CountRegistered("summoner") == 0 and Alice:CountRegistered("clicker") == 0)
check("Karl is no longer queued on either client - CLEARROSTER now clears the queue too",
    Alice:QueueNext() == nil and Bob:QueueNext() == nil)

--------------------------------------------------------------------------
-- Section 17: ManualSummon respects existing claims across clients
--------------------------------------------------------------------------
print("== ManualSummon respects claims from other Warlocks ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob", "Mabel" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Bob", function() Bob.db.active = false end) -- prevent Bob's own auto-loop from claiming Mabel first
As("Bob", function() Bob:HandleWhisper("air", "Mabel") end)
FlushNetwork()

-- Alice manually claims and starts summoning Mabel. 2026-08-04 (Loopi-
-- reported bug - TargetUnit/CastSpellByName are hardware-event-gated
-- protected functions, silently blocked once a C_Timer hop breaks the
-- click's call chain): ManualSummon is now fully synchronous - no more
-- claim-grace wait before casting, see Summon.lua's StartSummonAttempt
-- `immediate` parameter - so Alice goes straight to "casting" (and has
-- already cast) by the time ManualSummon returns, rather than sitting in
-- "claiming" awaiting a timer.
As("Alice", function() Alice:ManualSummon("Mabel") end)
check("Alice proceeds directly to casting on Mabel (synchronous click-to-cast)",
    Alice.summonState == "casting")
check("Alice's cast target resolved immediately, no grace-period wait needed",
    UnitName(Alice.pendingCastUnit) == "Mabel")
FlushNetwork() -- Bob learns about Alice's claim

-- Bob tries to manually summon the SAME player - should be refused.
As("Bob", function()
    check("Bob's manual summon of an already-claimed player is refused",
        Bob:ManualSummon("Mabel") == false)
end)
check("Bob never entered a summon state", Bob.summonState == "idle")
check("Bob never cast at all", CastCountFor("Bob") == 0)

--------------------------------------------------------------------------
-- Section 18: Auto-promote across real clients, including idempotent re-sweep
--------------------------------------------------------------------------
print("== Auto-promote: cross-client, and safe to re-sweep ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10
inGuild = true
guildRosterNames = { "Alice", "Bob" }
raidLeader = "Alice"

As("Bob", function() Bob:SetRole("summoner", true) end)
FlushNetwork() -- Alice learns Bob is a registered summoner

As("Alice", function() Alice:UpdateGuildRosterCache() ; Alice:AutoPromoteSweep() end)
check("Alice (leader) promotes Bob to assistant", raidAssistants["Bob"] == true)
check("Exactly one promote call was made", #promoteAssistantLog == 1)

-- Re-running the sweep must NOT re-promote an already-promoted member.
As("Alice", function() Alice:AutoPromoteSweep() end)
check("Re-sweeping is a safe no-op once already promoted", #promoteAssistantLog == 1)

-- Bob (not leader) can never promote anyone, even if he tries.
promoteAssistantLog = {}
As("Bob", function() Bob:AutoPromoteSweep() end)
check("Non-leader's sweep does nothing (Bob isn't the raid leader)", #promoteAssistantLog == 0)

--------------------------------------------------------------------------
-- Section 19: Leader-succession rescue handoff across real clients
--------------------------------------------------------------------------
print("== Rescue handoff: real cross-client succession ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Bob", function() Bob:SetRole("summoner", true) end)
FlushNetwork()

-- Blizzard's auto-succession (simulated) lands leadership on Alice, who is
-- NOT herself a registered summoner - she should hand it straight to Bob.
raidLeader = "Alice"
As("Alice", function() Alice:OnPartyLeaderChanged() end)
check("Alice (non-summoner, new leader) hands lead to Bob", raidLeader == "Bob")
check("The handoff call was attributed to Alice", promoteLeaderLog[1].by == "Alice")

-- Conservative case: if the new leader IS herself a registered summoner,
-- no automatic handoff - don't override what might be a deliberate choice.
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Alice", function() Alice:SetRole("summoner", true) end)
As("Bob", function() Bob:SetRole("summoner", true) end)
FlushNetwork()

raidLeader = "Alice"
As("Alice", function() Alice:OnPartyLeaderChanged() end)
check("Alice is both leader and a registered summoner: no handoff occurs", raidLeader == "Alice")
check("No promote-to-leader call was made", #promoteLeaderLog == 0)

--------------------------------------------------------------------------
-- Section 20: SETPHRASE requires verified authority, propagates to everyone
--------------------------------------------------------------------------
print("== SETPHRASE: requires verified authority, propagates the new phrase ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10

-- Bob is a regular member: his attempt should be refused locally, nothing sent.
raidLeader = "Alice"
As("Bob", function()
    check("Bob lacks set_phrase permission", Bob:HasPermission("set_phrase") == false)
    check("RequestSetPhrase refuses for Bob", Bob:RequestSetPhrase("newphrase") == false)
end)
FlushNetwork()
check("Alice's phrase is untouched by Bob's refused attempt", Alice.db.codePhrase == "air")
check("Bob's own phrase is untouched too", Bob.db.codePhrase == "air")

-- Alice IS the leader: her change should work and propagate to Bob.
As("Alice", function()
    check("Alice has set_phrase permission", Alice:HasPermission("set_phrase") == true)
    Alice:RequestSetPhrase("newphrase")
end)
FlushNetwork()
check("Alice's own phrase updated", Alice.db.codePhrase == "newphrase")
check("Bob's phrase updated too, not just Alice's", Bob.db.codePhrase == "newphrase")

-- Confirm the new phrase actually works end-to-end for Bob after sync.
As("Bob", function() Bob:HandlePublicChat("newphrase", "Nadia") end)
check("Bob accepts the newly-synced phrase from raid chat", Bob:QueueNext() ~= nil
    and Bob:QueueNext().name == "Nadia")

-- An assistant (not the leader) should also be able to set the phrase.
raidLeader = "Alice"
raidAssistants = { Bob = true }
As("Bob", function()
    check("Bob (assistant, not leader) also has set_phrase permission", Bob:HasPermission("set_phrase") == true)
    Bob:RequestSetPhrase("assistantphrase")
end)
FlushNetwork()
check("Assistant's phrase change propagated to Alice too", Alice.db.codePhrase == "assistantphrase")

--------------------------------------------------------------------------
-- Section 21: SETDEST - self-service, propagates, never settable remotely
--------------------------------------------------------------------------
print("== SETDEST: self-service destination choice propagates, never remote ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10

As("Alice", function() Alice:SelfJoinQueue() end)
FlushNetwork()
check("Bob sees Alice queued", Bob:QueueNext() ~= nil and Bob:QueueNext().name == "Alice")

As("Alice", function()
    check("Alice sets her own destination", Alice:SetMyDestination("stormwind") == true)
end)
FlushNetwork()
check("Alice's own copy reflects it", Alice:QueueNext().destination == "stormwind")
check("Bob's copy of Alice's entry reflects it too", Bob:QueueNext().destination == "stormwind")

-- Bob cannot set Alice's destination for her - not even via the raw wire
-- message, since the receiver only applies SETDEST if Name == sender.
As("Bob", function()
    Bob:Sync_Send("SETDEST", "Alice|ironforge")
end)
FlushNetwork()
check("Alice's destination is untouched by Bob's attempt on her behalf",
    Alice:QueueNext().destination == "stormwind")
check("Bob's own copy of Alice's entry is untouched too",
    Bob:QueueNext().destination == "stormwind")

-- Clearing propagates too.
As("Alice", function()
    check("Alice clears her destination", Alice:SetMyDestination("") == true)
end)
FlushNetwork()
check("Alice's destination is nil again", Alice:QueueNext().destination == nil)
check("Bob's copy is cleared too", Bob:QueueNext().destination == nil)

--------------------------------------------------------------------------
-- Section 22: DESTLIST - requires verified authority, propagates to everyone
--------------------------------------------------------------------------
print("== DESTLIST: requires verified authority, propagates the new list ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10
inGuild = true

local officerList = { { id = "customspot", label = "Custom Spot", category = "flightpoint" } }

-- M3: edit_destinations is gated by real guild-officer RANK now, not raid
-- leader/assist status (that was the M2 interim gate) - see IsGuildOfficer,
-- Core.lua. Bob is a regular guild member (rank 6, past the threshold):
-- refused locally, nothing sent, Alice untouched.
guildRosterNames = { { name = "Alice", rankIndex = 1 }, { name = "Bob", rankIndex = 6 } }
As("Alice", function() Alice.db.officerRankThreshold = 3; Alice:UpdateGuildRosterCache() end)
As("Bob", function() Bob.db.officerRankThreshold = 3; Bob:UpdateGuildRosterCache() end)

As("Bob", function()
    check("Bob lacks edit_destinations permission", Bob:HasPermission("edit_destinations") == false)
    check("SetDestinationList refuses for Bob", Bob:SetDestinationList(officerList) == false)
end)
FlushNetwork()
check("Alice's destinations list is untouched by Bob's refused attempt",
    #Alice.db.destinations == #Alice.DEFAULT_DESTINATIONS)
check("Bob's own list is untouched too", #Bob.db.destinations == #Bob.DEFAULT_DESTINATIONS)

-- Alice IS a guild officer (rank 1, within the threshold): her change works
-- and propagates to Bob - verified by BOB's own roster knowledge of
-- Alice's rank, never a self-asserted claim baked into the message.
As("Alice", function()
    check("Alice has edit_destinations permission", Alice:HasPermission("edit_destinations") == true)
    Alice:SetDestinationList(officerList)
end)
FlushNetwork()
check("Alice's own list updated", #Alice.db.destinations == 1 and Alice.db.destinations[1].id == "customspot")
check("Bob's list updated too, not just Alice's", #Bob.db.destinations == 1
    and Bob.db.destinations[1].id == "customspot")
check("The synced label/category round-tripped correctly",
    Bob.db.destinations[1].label == "Custom Spot" and Bob.db.destinations[1].category == "flightpoint")
check("A freshly-added destination defaults to enabled on both sides",
    Alice.db.destinations[1].enabled ~= false and Bob.db.destinations[1].enabled ~= false)

-- Enable/disable (2026-08-03, DestinationEditor.lua's toggle) shares the
-- same edit_destinations gate and DESTLIST broadcast as a full list
-- replace - Alice (still an officer) disables it, and the flag itself
-- (not just label/category) propagates to Bob.
As("Alice", function()
    check("Alice can disable her own list's destination", Alice:SetDestinationEnabled("customspot", false) == true)
end)
FlushNetwork()
check("Alice's copy is disabled", Alice.db.destinations[1].enabled == false)
check("Bob's copy picked up the disabled flag too, not just label/category",
    Bob.db.destinations[1].enabled == false)

-- Another guild officer (Bob promoted to rank 2, still within the
-- threshold) can also broadcast a new list - raid assistant status plays
-- no role in this decision anymore.
guildRosterNames = { { name = "Alice", rankIndex = 1 }, { name = "Bob", rankIndex = 2 } }
As("Alice", function() Alice:UpdateGuildRosterCache() end)
As("Bob", function() Bob:UpdateGuildRosterCache() end)
As("Bob", function()
    Bob:ResetDestinationsToDefault()
end)
FlushNetwork()
check("Officer Bob's reset-to-default propagated to Alice too",
    #Alice.db.destinations == #Alice.DEFAULT_DESTINATIONS)

--------------------------------------------------------------------------
-- Section 23: Late joiner picks up the CURRENT (edited) destinations list
--------------------------------------------------------------------------
print("== Late joiner syncs the officer's current destinations list ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10
inGuild = true

-- Settle each client's own login HELLO/SYNCREQ handshake BEFORE the
-- officer edit below. Without this, Alice's and Bob's still-unanswered
-- login SYNCREQs get flushed together with the edit broadcast further
-- down, and a reply-to-that-stale-SYNCREQ can carry pre-edit destinations
-- content that arrives (and, being ungated DESTSYNCDATA, blindly
-- overwrites) AFTER the edit was already applied locally - a genuine
-- stale-resync-clobbers-fresh-edit race, not just test noise. In real
-- play this handshake settles almost instantly on login, well before an
-- officer edit happens moments later, so this flush just reproduces that
-- ordering.
FlushNetwork()

-- M3: Alice needs HER OWN roster cache to recognize herself as an officer
-- (checked locally before she'll even attempt the broadcast), AND Bob (the
-- DESTLIST receiver) needs Alice recognized as an officer in HIS OWN
-- roster cache too (verified independently, never trusting the message) -
-- raid leader status no longer matters for either side of this.
guildRosterNames = { { name = "Alice", rankIndex = 1 }, { name = "Bob", rankIndex = 6 } }
As("Bob", function() Bob:UpdateGuildRosterCache() end)
As("Alice", function() Alice:UpdateGuildRosterCache() end)
As("Alice", function()
    Alice:SetDestinationList({ { id = "onlyspot", label = "The Only Spot", category = "summonstone" } })
    Alice:QueueAdd("Eve")
    Alice:SelfJoinQueue()
    Alice:SetMyDestination("onlyspot")
end)
FlushNetwork() -- Eve is just a plain queued name here, not a DH-Air client, same idiom as Jack/Kelly earlier

table.insert(groupRoster, "Carl")
local Carl = NewClient("Carl")
FlushNetwork()

check("Carl picked up the officer's edited destinations list (not the built-in defaults)",
    #Carl.db.destinations == 1 and Carl.db.destinations[1].id == "onlyspot")
check("Carl still got the queue itself via the normal SYNCDATA path", Carl:QueueNext() ~= nil)
local aliceViaCarl
for _, e in ipairs(Carl.db.queue) do
    if Carl:NormalizeName(e.name) == "Alice" then aliceViaCarl = e end
end
check("Carl also learned Alice's already-chosen destination via ordinary queue sync (not just the list)",
    aliceViaCarl ~= nil and aliceViaCarl.destination == "onlyspot")

--------------------------------------------------------------------------
-- Section 25: SETDESTFOR - a leader/assist sets SOMEONE ELSE's destination
-- (M3, QueueFeedback design D3). The cross-client counterpart to
-- harness.lua's own section: this one is about the wire message, the
-- receive-side authority check, and the whisper NOT being duplicated.
--------------------------------------------------------------------------
print("== SETDESTFOR: leader/assist sets another player's destination ==")
ResetWorld()
Alice = NewClient("Alice")
Bob = NewClient("Bob")
groupRoster = { "Alice", "Bob" }
shardCounts.Alice, shardCounts.Bob = 10, 10
raidLeader = "Alice"

-- Riley is a plain guildmate with no addon at all - the entire reason M3
-- exists. She whispers the code phrase and never touches a UI again.
As("Alice", function() Alice:HandleWhisper("air", "Riley") end)
FlushNetwork()
check("Both Warlocks see Riley queued",
    Alice:QueueNext() ~= nil and Bob:QueueNext() ~= nil)

local whispersBefore = #chatLog
As("Alice", function()
    check("The raid leader can set Riley's destination for her",
        Alice:RequestSetDestinationFor("Riley", "ironforge") == true)
end)
FlushNetwork()
check("Alice's own copy has it", Alice:QueueNext().destination == "ironforge")
check("Bob's copy converged via SETDESTFOR", Bob:QueueNext().destination == "ironforge")

-- The whisper must come from the SETTER only. If every receiving client
-- also whispered, a raid with N DH-Air users would spam the poor requester
-- N times for one action.
local rileyWhispers, rileyWhisperFrom = 0, nil
for i = whispersBefore + 1, #chatLog do
    if chatLog[i].channel == "WHISPER" and chatLog[i].target == "Riley" then
        rileyWhispers = rileyWhispers + 1
        rileyWhisperFrom = chatLog[i].from
    end
end
check("Riley is whispered exactly once across the whole raid", rileyWhispers == 1,
    "got " .. rileyWhispers)
check("...and it came from the Warlock who set it", rileyWhisperFrom == "Alice")

-- Receive-side authority, same idiom as REMOVE/CLEARALL/SETPHRASE: Bob is
-- neither leader nor assist, so even a hand-crafted wire message is dropped
-- by everyone who receives it.
As("Bob", function() Bob:Sync_Send("SETDESTFOR", "Riley|stormwind") end)
FlushNetwork()
check("An unauthorized SETDESTFOR is ignored by the receiver",
    Alice:QueueNext().destination == "ironforge")

raidAssistants["Bob"] = true
As("Bob", function() Bob:RequestSetDestinationFor("Riley", "stormwind") end)
FlushNetwork()
check("Once Bob is an assistant, the same action is accepted",
    Alice:QueueNext().destination == "stormwind")

-- SETDEST must NOT have been widened as a side effect: it is still strictly
-- self-only, so a leader cannot use it to set someone else's destination.
As("Alice", function() Alice:Sync_Send("SETDEST", "Riley|ironforge") end)
FlushNetwork()
check("SETDEST stays self-only even for the raid leader",
    Bob:QueueNext().destination == "stormwind")

--------------------------------------------------------------------------
-- Section 26: SYNCREQ on real group-membership change (M4, finding F4)
--
-- The bug: SYNCREQ was only ever sent at PLAYER_LOGIN, but Sync_Channel
-- prefers RAID > PARTY > GUILD, so a requester who isn't in the raid yet
-- never hears the ADD that queued them. The constraint: GROUP_ROSTER_UPDATE
-- fires constantly during a raid and every SYNCREQ makes each peer answer
-- with a whispered multi-chunk state dump, so this must fire on CHANGE only.
--------------------------------------------------------------------------
print("== SYNCREQ fires on membership change, not on every roster update ==")
ResetWorld()
inGuild = true -- so GUILD remains a valid channel once we're ungrouped
Alice = NewClient("Alice")
groupRoster = { "Alice" }

local function CountPendingSyncreq()
    local n = 0
    for _, m in ipairs(pendingNetwork) do
        if m.text == "SYNCREQ" then n = n + 1 end
    end
    return n
end

-- NewClient ran Sync_Init, which seeded the baseline; drop whatever login
-- traffic that produced so we're only measuring roster-update behavior.
pendingNetwork = {}

As("Alice", function() Alice.frame:Fire("GROUP_ROSTER_UPDATE") end)
check("A roster update with no membership change sends no SYNCREQ",
    CountPendingSyncreq() == 0)

As("Alice", function() Alice.frame:Fire("GROUP_ROSTER_UPDATE") end)
As("Alice", function() Alice.frame:Fire("GROUP_ROSTER_UPDATE") end)
check("...and still none after several more (this is the flood the old code would have caused)",
    CountPendingSyncreq() == 0)

-- Raid -> party is a real change: the channel we broadcast and listen on
-- just moved out from under us.
inRaid = false
As("Alice", function() Alice.frame:Fire("GROUP_ROSTER_UPDATE") end)
check("Leaving the raid for a party sends exactly one SYNCREQ",
    CountPendingSyncreq() == 1)

pendingNetwork = {}
As("Alice", function() Alice.frame:Fire("GROUP_ROSTER_UPDATE") end)
check("The next update at the same membership sends none",
    CountPendingSyncreq() == 0)

inGroup = false
As("Alice", function() Alice.frame:Fire("GROUP_ROSTER_UPDATE") end)
check("Dropping to solo (falling back to GUILD) sends one SYNCREQ",
    CountPendingSyncreq() == 1)

pendingNetwork = {}
inRaid, inGroup = true, true
As("Alice", function() Alice.frame:Fire("GROUP_ROSTER_UPDATE") end)
check("Joining a raid sends one SYNCREQ - the case the requester actually needs",
    CountPendingSyncreq() == 1)

-- With sharing off nothing goes out at all, but the baseline still tracks,
-- so re-enabling it can't make a long-stale state look like a fresh change.
pendingNetwork = {}
Alice.db.shareQueue = false
inRaid, inGroup = false, false
As("Alice", function() Alice.frame:Fire("GROUP_ROSTER_UPDATE") end)
check("Sharing disabled means no SYNCREQ even across a real change",
    CountPendingSyncreq() == 0)
check("...but the membership baseline still moved", Alice.lastGroupState == "solo")

Alice.db.shareQueue = true
As("Alice", function() Alice.frame:Fire("GROUP_ROSTER_UPDATE") end)
check("Re-enabling sharing does not replay a stale change",
    CountPendingSyncreq() == 0)

--------------------------------------------------------------------------
-- Section: MIN_QUEUE_VERSION gate (2026-08-15) - an old client's ADD
-- broadcasts get silently dropped by up-to-date peers; everything else
-- (roster registration, HELLO, claims) still works fine from an old build.
--------------------------------------------------------------------------
print("== MIN_QUEUE_VERSION gate ==")
ResetWorld()
local Old = NewClient("Old")     -- simulates a client that never updated
local New1 = NewClient("New1")
local New2 = NewClient("New2")
groupRoster = { "Old", "New1", "New2" }
shardCounts.Old, shardCounts.New1, shardCounts.New2 = 10, 10, 10

-- Discard the login handshake BEFORE downgrading Old's version - it
-- already went out carrying the mocked "2.1.6" DHAir.VERSION, and
-- overwriting the field now wouldn't retroactively change that queued
-- message text.
pendingNetwork = {}
Old.VERSION = "2.1.5" -- below Sync.lua's MIN_QUEUE_VERSION (2.1.6)

-- Fresh HELLOs from everyone now that Old's version has been downgraded,
-- so each peer's tracked version matches this test's intent.
As("Old", function() Old:Sync_SendHello() end)
As("New1", function() New1:Sync_SendHello() end)
As("New2", function() New2:Sync_SendHello() end)
FlushNetwork()

As("Old", function() Old:QueueAdd("Mallory") end)
As("Old", function() Old:Sync_BroadcastAdd("Mallory") end)
FlushNetwork()
check("An up-to-date peer drops an ADD broadcast from a below-floor client",
    New1:QueueWaitingCount() == 0)
check("...on every up-to-date peer, not just one",
    New2:QueueWaitingCount() == 0)
check("The old client still has it locally (only the RECEIVE side is gated)",
    Old:QueueWaitingCount() == 1)

As("New1", function() New1:QueueAdd("Nancy") end)
As("New1", function() New1:Sync_BroadcastAdd("Nancy") end)
FlushNetwork()
check("An ADD from an up-to-date client still propagates normally",
    New2:QueueWaitingCount() == 1 and New2.db.queue[1].name == "Nancy")

-- Old's roster registration and presence are untouched by the gate - only
-- its ADD broadcasts are dropped.
As("Old", function() Old:SetRole("clicker", true) end)
FlushNetwork()
check("An old client's ROLE REGISTRATION still reaches peers fine",
    New1:IsRegistered("clicker", "Old") == true)

-- Fail-open for a never-seen sender (no HELLO on file yet - Chris's call,
-- 2026-08-15): simulate this by resetting the world without ever flushing
-- the login HELLO before the ADD arrives.
ResetWorld()
local Fresh = NewClient("Fresh")
local Watcher = NewClient("Watcher")
groupRoster = { "Fresh", "Watcher" }
shardCounts.Fresh, shardCounts.Watcher = 10, 10
pendingNetwork = {} -- drop the login HELLO/SYNCREQ traffic itself

As("Fresh", function() Fresh:QueueAdd("Oswin") end)
As("Fresh", function() Fresh:Sync_BroadcastAdd("Oswin") end)
FlushNetwork()
check("An ADD from a never-seen (version-unknown) sender is allowed through (fail-open)",
    Watcher:QueueWaitingCount() == 1 and Watcher.db.queue[1].name == "Oswin")

--------------------------------------------------------------------------
print("")
print(string.format("RESULTS: %d passed, %d failed", PASS, FAIL))
if FAIL > 0 then
    print("Failures:")
    for _, f in ipairs(failures) do print("  - " .. f) end
    os.exit(1)
else
    print("All shared-queue tests passed.")
    os.exit(0)
end
