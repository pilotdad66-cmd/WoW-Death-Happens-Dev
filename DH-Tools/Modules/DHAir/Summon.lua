-- DH-Air Summon.lua
-- Works through the queue: (if sharing) claim the next free player, target,
-- cast Ritual of Summoning, announce, wait for completion/timeout, then
-- advance to the next player.

local ADDON_NAME, DHAir = ...

local SUMMON_SPELL = "Ritual of Summoning"
local SOUL_SHARD_ITEM_ID = 6265
local CLAIM_GRACE_SECONDS = 0.5 -- window to detect a competing claim before actually casting

-- "ready" (2026-08-04 addition) - a target is picked and claimed, but
-- hasn't actually been cast on yet because nothing that got us here was a
-- real click (see BeginCast's pendingClickDriven check below) - waits for
-- DHAir:ConfirmSummon(), the Board's "Confirm Summon" button.
DHAir.summonState = "idle" -- "idle" | "claiming" | "ready" | "casting" | "waiting"
DHAir.currentSummon = nil
DHAir.pendingEntry = nil
DHAir.timeoutHandle = nil
DHAir.claimHandle = nil
DHAir.castWatchdogHandle = nil
DHAir.failCount = 0
DHAir.pausedForShards = false -- true only when THIS addon auto-paused for low shards
-- 2026-08-04 addition (Loopi-requested one-click auto-summon redesign) -
-- true only while the CURRENT call chain into BeginCast() originated
-- synchronously from a real player click (ManualSummon, or ConfirmSummon
-- itself) - see BeginCast's own comment for why this matters. Sticky
-- across a failure retry's C_Timer hop on purpose - see
-- HandleSummonFailure, which explicitly clears it back to false before
-- retrying, since a timer callback is never click-driven regardless of
-- how the original attempt started.
DHAir.pendingClickDriven = false
-- 2026-08-06 (Loopi-reported, still blocked after the 2026-08-04
-- synchronous-call fix): the unit token BeginCast() resolved and wants
-- cast on, stashed here instead of being acted on directly - see
-- BeginCast's own 2026-08-06 comment and BuildCastMacro below for why.
-- Consumed (and cleared back to nil) by whichever SecureActionButtonTemplate
-- button's PreClick reads it immediately after calling ManualSummon/
-- ConfirmSummon (Board.lua).
DHAir.pendingCastUnit = nil
-- 2026-08-08 (@kb:manual-override-two-click): the target name a manual
-- pick is currently "armed" to override an in-flight ritual for, and when
-- that arming happened. Cleared as soon as any pick actually goes through.
DHAir.pendingOverrideName = nil
DHAir.pendingOverrideAt = nil

-- After this many consecutive failures to cast/complete on the SAME target,
-- auto-summon pauses itself with a clear message instead of retrying forever
-- (protects against silently hammering CastSpellByName / spamming chat if
-- e.g. the Warlock is out of range or the target is invalid).
local MAX_CONSECUTIVE_FAILURES = 3
local RETRY_DELAY_SECONDS = 3

-- How long the "click again to override" arming lasts before it lapses
-- back to a fresh warning - see ManualSummon's @kb:manual-override-two-click.
-- Long enough not to feel like a race, short enough that a stray click
-- minutes later can't silently cancel a ritual.
local OVERRIDE_CONFIRM_SECONDS = 8

-- 2026-08-04 (Loopi-reported bug, first pass): TargetUnit/CastSpellByName
-- are hardware-event-gated protected functions - WoW silently blocks them
-- (no catchable Lua error, just a client-side "reserved for the Blizzard
-- UI" message) unless the call happens synchronously inside the exact
-- click handler that a real mouse click triggered, with no C_Timer/event
-- hop in between (see Secure Execution and Tainting on Warcraft Wiki).
-- The claim-grace timer (see StartSummonAttempt) used to delay BeginCast()
-- by CLAIM_GRACE_SECONDS, breaking that chain - fixed by making
-- ManualSummon/ConfirmSummon call BeginCast() synchronously (immediate=true).
--
-- 2026-08-06 (Loopi-reported, k-0010): that synchronous-call fix turned
-- out to be NECESSARY but not SUFFICIENT - Loopi confirmed (clean repro:
-- fresh /reload, straight to the Board, nothing else touched first) the
-- exact same block still happens on a genuinely synchronous, real-click
-- call. Root cause, corrected: TargetUnit/CastSpellByName cannot be
-- called directly from ANY plain Lua function - hardware-event-driven or
-- not - only from a SecureActionButtonTemplate button's own
-- attribute-driven click dispatch (the "type"/"macrotext" attributes,
-- executed by Blizzard's C code, not by calling the Lua functions
-- ourselves). See k-0010 for the full writeup. BeginCast() below no
-- longer calls either function - it resolves and stashes the target unit
-- (pendingCastUnit, top of file) instead; Board.lua's Summon/Confirm
-- Summon buttons are now SecureActionButtonTemplate buttons whose
-- PreClick calls ManualSummon/ConfirmSummon (reaching this point
-- synchronously, same as before) and then sets its OWN macrotext
-- attribute from pendingCastUnit via BuildCastMacro - the secure click
-- dispatch that follows PreClick is what actually targets+casts.
--
-- This watchdog is still the safety net for the remaining silent-failure
-- modes (e.g. SetAttribute itself being blocked by combat lockdown): if
-- nothing (success or failure) resolves a "casting" state within this
-- window, treat it as a failure so HandleSummonFailure's existing
-- retry/pause machinery can recover it automatically.
local CAST_WATCHDOG_SECONDS = 6

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

-- Finds a party/raid unit token matching a queued player's name.
local function FindGroupUnitByName(name)
    local short = name:match("^([^%-]+)") or name

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            local uName = UnitName(unit)
            if uName == name or uName == short then
                return unit
            end
        end
    elseif IsInGroup() then
        for i = 1, GetNumGroupMembers() do
            local unit = "party" .. i
            local uName = UnitName(unit)
            if uName == name or uName == short then
                return unit
            end
        end
    end
    return nil
end
DHAir.FindGroupUnitByName = FindGroupUnitByName

-- Returns how many Soul Shards the player is carrying, or nil if the count
-- couldn't be determined (in which case callers should fail open rather
-- than blocking the queue over a missing/renamed API).
local function GetShardCount()
    local ok, count = pcall(GetItemCount, SOUL_SHARD_ITEM_ID)
    if ok and type(count) == "number" then
        return count
    end
    return nil
end
DHAir.GetShardCount = GetShardCount

-- Returns the next queue entry that isn't summoned AND (when sharing) isn't
-- freshly claimed by someone else AND (when guildOnly is on) is actually in
-- the player's guild AND (2026-08-03 addition) shares the WARLOCK's own
-- chosen destination (db.warlockDestination, see Queue.lua's
-- SetWarlockDestination). This is the one place that makes the shared
-- queue actually avoid double-summoning: everyone skips whatever the
-- current, non-stale claim winner is working on.
--
-- If no destination is chosen yet, this returns nil unconditionally -
-- there's nothing safe to match against, so auto-summon simply finds
-- nothing to do (see RequestStartAutoSummon/RequestResumeAutoSummon for
-- the friendlier "refuse to even start" version of this same gate, and
-- Board.lua for the "gray out the button" UI treatment). Note this does
-- NOT affect ManualSummon, which looks up its target directly rather than
-- through this function - a deliberate manual click is unfiltered by
-- destination, same as it's already unfiltered by guildOnly.
function DHAir:QueueNextAvailable(sharing)
    if not self.db.warlockDestination then return nil end

    local myName = UnitName("player")
    for _, entry in ipairs(self.db.queue) do
        -- D6 (2026-08-17, Loopi - DH-Tools-WorldBuffRequest-Design.md):
        -- Summoners/Clickers now get a real queue entry (D5) purely so
        -- they're visible on the Board - auto-summon must never pick them
        -- up on its own. They're still summonable, just manually only
        -- (ManualSummon looks up its target directly, unfiltered by this).
        if not entry.summoned and entry.destination == self.db.warlockDestination
            and entry.role ~= "summoner" and entry.role ~= "clicker"
            and not (self.db.guildOnly and not self:IsGuildMember(entry.name)) then
            if not sharing then
                return entry
            end
            local claim = self:GetClaim(entry.name)
            if not claim or claim.by == myName or self:IsClaimStale(claim) then
                return entry
            end
        end
    end
    return nil
end

-- Substitutes {target} in a message template with the player's name.
function DHAir:BuildMessage(template, targetName)
    template = template or self.DEFAULT_MESSAGE
    return (template:gsub("{target}", targetName))
end

-- Sends the configured message to each enabled channel that currently applies.
-- targetName is used for the {target} placeholder text (short/display form);
-- whisperTarget is who SendChatMessage actually whispers (falls back to
-- targetName), so cross-realm names with a "-Realm" suffix still resolve
-- correctly even though the displayed message uses the short name.
function DHAir:Announce(targetName, whisperTarget)
    local msgs = self.db.messages

    if msgs.raid.enabled and IsInRaid() then
        SendChatMessage(self:BuildMessage(msgs.raid.text, targetName), "RAID")
    end

    if msgs.party.enabled and IsInGroup() and not IsInRaid() then
        SendChatMessage(self:BuildMessage(msgs.party.text, targetName), "PARTY")
    end

    if msgs.guild.enabled and IsInGuild() then
        SendChatMessage(self:BuildMessage(msgs.guild.text, targetName), "GUILD")
    end

    if msgs.say.enabled then
        SendChatMessage(self:BuildMessage(msgs.say.text, targetName), "SAY")
    end

    if msgs.whisper.enabled then
        SendChatMessage(self:BuildMessage(msgs.whisper.text, targetName), "WHISPER", nil, whisperTarget or targetName)
    end
end

function DHAir:CancelTimeout()
    if self.timeoutHandle then
        self.timeoutHandle:Cancel()
        self.timeoutHandle = nil
    end
end

function DHAir:CancelClaimTimer()
    if self.claimHandle then
        self.claimHandle:Cancel()
        self.claimHandle = nil
    end
end

function DHAir:CancelCastWatchdog()
    if self.castWatchdogHandle then
        self.castWatchdogHandle:Cancel()
        self.castWatchdogHandle = nil
    end
end

--------------------------------------------------------------------------
-- Core loop
--------------------------------------------------------------------------

-- Marks a finished summon done (queue flag, claim release, shared-queue
-- broadcast) and moves on. Single exit point for a summon that got as far
-- as an actual ritual, shared by the channel-ended path and the fallback
-- timeout path (see OnSpellcastEvent) so those two can't drift apart.
-- Safe with a nil entry - the advance still happens.
function DHAir:FinishSummon(entry)
    if entry then
        self:QueueMarkSummoned(entry.name)
        if self.ClearClaim then self:ClearClaim(entry.name) end
        if self.Sync_BroadcastSummoned then self:Sync_BroadcastSummoned(entry.name) end
    end
    self:AdvanceQueue()
end

-- Called after a summon finishes successfully or times out (i.e. NOT a
-- cast failure) to move on to the next player in the queue.
function DHAir:AdvanceQueue()
    self:CancelTimeout()
    self:CancelClaimTimer()
    self:CancelCastWatchdog()
    self.summonState = "idle"
    self.currentSummon = nil
    self.pendingEntry = nil
    self.failCount = 0
    self:TrySummonNext()
end

-- Abandons a picked-but-not-yet-cast claim on `name`, if that's actually
-- what we're holding right now. Only "claiming" (mid-negotiation) and
-- "ready" (picked, awaiting a Confirm Summon click) are safe to cancel
-- this way - a "casting"/"waiting" ritual already in flight can't be
-- interrupted remotely, since /stopcasting is a protected action that
-- requires a real click (see Board.lua's Abort Summon secure overlay);
-- that case is left to resolve on its own.
--
-- 2026-08-18 (Loopi-reported, two related bugs):
-- 1. A "ready" claim that sat unconfirmed past CLAIM_TTL_SECONDS and got
--    picked up by another Warlock left the original Warlock's Confirm
--    Summon button pointing at someone no longer theirs - only the brief
--    "claiming" negotiation window used to get cancelled (see the CLAIM
--    handler in Sync.lua).
-- 2. Removing someone from the queue (the Board row's X button) only
--    ever touched the shared queue LIST - a Warlock who'd already
--    claimed (or reached "ready" on) the removed player kept the claim
--    and could still summon them (see Sync.lua's REMOVE handler and
--    Queue.lua's RequestRemove).
-- Both call this same idiom now rather than duplicating the cancel logic.
function DHAir:AbandonPendingPick(name, reason)
    if not (self.summonState == "claiming" or self.summonState == "ready") then return false end
    if not self.currentSummon then return false end
    if self:NormalizeName(self.currentSummon) ~= self:NormalizeName(name) then return false end

    if self.claimHandle then
        self.claimHandle:Cancel()
        self.claimHandle = nil
    end
    self.summonState = "idle"
    self.currentSummon = nil
    self.pendingEntry = nil
    if reason then
        self:Print(self:NormalizeName(name) .. " " .. reason .. " - your pick was cleared.")
    end
    self:TrySummonNext()
    return true
end

-- Called whenever the ritual fails to start or is interrupted. Retries the
-- SAME target (a few times, with a short delay) rather than skipping them,
-- since these are usually transient (out of range, briefly out of combat
-- restriction, etc). After too many consecutive failures it stops itself
-- with a clear message instead of retrying forever, and - if sharing - lets
-- go of its claim so another Warlock can pick the target up.
function DHAir:HandleSummonFailure(reason)
    self:CancelTimeout()
    self:CancelCastWatchdog()
    self.summonState = "idle"
    self.failCount = (self.failCount or 0) + 1

    local rawName = self.currentSummon
    local name = rawName and self:NormalizeName(rawName) or "target"

    if self.failCount >= MAX_CONSECUTIVE_FAILURES then
        self.db.paused = true
        self:Print("Auto-summon paused after " .. self.failCount .. " failed attempts to summon "
            .. name .. " (" .. reason .. "). Check your range/target, then /dhair resume.")
        if rawName and self.ReleaseClaim then
            self:ReleaseClaim(rawName) -- let another Warlock take over, since we're giving up
        end
        self.currentSummon = nil
        self.pendingEntry = nil
        self.failCount = 0
        return
    end

    self:Print(reason .. " for " .. name .. " (attempt " .. self.failCount .. "/"
        .. MAX_CONSECUTIVE_FAILURES .. "). Retrying in " .. RETRY_DELAY_SECONDS .. "s...")

    -- Still holding the claim during these quick retries - no need to
    -- release/re-claim over a few-second hiccup.
    -- 2026-08-04: explicitly clears pendingClickDriven before retrying,
    -- even if the ORIGINAL attempt was a real click (ManualSummon) - this
    -- retry itself fires from a C_Timer, which is never click-driven, so
    -- BeginCast would otherwise wrongly try (and silently fail) a
    -- protected call again. It'll land in "ready" instead, offering a
    -- Confirm Summon click - more honest than a doomed silent retry.
    C_Timer.NewTimer(RETRY_DELAY_SECONDS, function()
        DHAir.summonState = "idle"
        DHAir.pendingClickDriven = false
        DHAir:BeginCast()
    end)
end

-- Begins the claim/cast pipeline for a SPECIFIC entry, already selected by
-- the caller (either the FIFO auto-picker or an explicit manual summon).
-- Shared so both paths get identical shard-checking and claim behavior -
-- a manually-clicked target is just as protected from double-summoning as
-- an automatically-picked one.
--
-- `immediate` (2026-08-04 addition, Loopi-reported bug): whether the
-- CALLER is itself a real, synchronous player click - true for
-- ManualSummon (the Board's per-row "Summon" button), false for the
-- FIFO auto-picker (TrySummonNext, driven by GROUP_ROSTER_UPDATE/timers,
-- never a click). This only controls whether the claim-grace timer below
-- is skipped; it does NOT by itself decide whether BeginCast() actually
-- casts - see BeginCast's own pendingClickDriven check for that (single
-- choke point every path funnels through, including this one).
function DHAir:StartSummonAttempt(entry, immediate)
    local minShards = self.db.minShards or 2
    local shardCount = GetShardCount()
    if shardCount ~= nil and shardCount < minShards then
        self.db.paused = true
        self.pausedForShards = true
        self:Print("Auto-summon paused: only " .. shardCount .. " Soul Shard"
            .. (shardCount == 1 and "" or "s") .. " left (need at least " .. minShards
            .. "). Restock Soul Shards - I'll resume automatically, or use /dhair resume.")
        return false
    end

    self.currentSummon = entry.name
    self.pendingEntry = entry
    self.pendingClickDriven = immediate and true or false

    local sharing = self.Sync_IsActive and self:Sync_IsActive()
    if sharing then
        local myName = UnitName("player")
        self:StoreClaim(entry.name, myName)
        self:Sync_Send("CLAIM", entry.name .. "|" .. myName)
        self.summonState = "claiming"
        if immediate then
            -- No competing-claim wait for a real click - see BeginCast's
            -- comment and the STATUS.md trade-off note this replaced.
            self:BeginCast()
        else
            self.claimHandle = C_Timer.NewTimer(CLAIM_GRACE_SECONDS, function()
                DHAir:ResolveClaimAndCast()
            end)
        end
    else
        self:BeginCast()
    end
    return true
end

-- Attempts to start the next summon in the queue, if conditions allow.
-- Safe to call repeatedly (e.g. from GROUP_ROSTER_UPDATE) - it no-ops
-- unless the addon is active, not paused, and idle. Also effectively a
-- no-op with no destination chosen, since QueueNextAvailable itself
-- refuses to match anything in that case - see RequestStartAutoSummon
-- below for the friendlier, proactive version of that same gate.
function DHAir:TrySummonNext()
    if not self.db then return end
    if not self.db.active then return end
    if self.db.paused then return end
    if self.summonState ~= "idle" then return end

    local sharing = self.Sync_IsActive and self:Sync_IsActive()
    local entry = self:QueueNextAvailable(sharing)
    if not entry then return end

    self:StartSummonAttempt(entry)
end

--------------------------------------------------------------------------
-- Gated start/resume (2026-08-03 addition) - single choke point for
-- turning auto-summon on, used by both Commands.lua's /dhair start|resume
-- and Board.lua's auto-summon button, so the "you need a destination
-- first" rule can't be bypassed by one caller and not the other. Refuses
-- with a clear chat message rather than flipping db.active/paused on and
-- then silently doing nothing (which would leave the Board's button
-- claiming "Stop auto-summon" while nothing is actually happening).
--------------------------------------------------------------------------

function DHAir:RequestStartAutoSummon()
    if not self.db.warlockDestination then
        self:Print("Pick your destination first (/dhair warlockdest <name>, or the Board) - "
            .. "auto-summon needs to know which queued players to match before it can start.")
        return false
    end
    self.db.active = true
    self.db.paused = false
    self.pausedForShards = false
    self.failCount = 0
    self:TrySummonNext()
    return true
end

function DHAir:RequestResumeAutoSummon()
    if not self.db.warlockDestination then
        self:Print("Pick your destination first (/dhair warlockdest <name>, or the Board) - "
            .. "auto-summon needs to know which queued players to match before it can resume.")
        return false
    end
    self.db.paused = false
    self.pausedForShards = false
    self.failCount = 0
    self:TrySummonNext()
    return true
end

-- Manually summons a SPECIFIC player, bypassing FIFO selection (e.g. a
-- Board click). Still goes through the exact same claim pipeline, so two
-- Warlocks can't double-summon a manually-picked target either - and it's
-- independent of the active/paused auto-summon toggle, since a deliberate
-- manual click should work even if auto-summon itself is off.
--
-- 2026-08-06 (k-0010 follow-up, brief-001): `immediate` defaults to true
-- (old callers/behavior unchanged) but Board.lua's row "Pick" button now
-- explicitly passes false. Reason: that button went back to being a
-- PLAIN button (not SecureActionButtonTemplate) after confirming the
-- template itself was silently breaking sibling row text with no Lua
-- error, no combat, and no anchoring-timing pattern - the row is simply
-- not a safe place for a second secure click-target. Passing false here
-- means BeginCast always lands on "ready" (arms the Board's one proven
-- SecureActionButtonTemplate widget, confirmSummonBtn) instead of trying
-- to cast directly - same one-more-click flow auto-summon already uses,
-- just reachable from a manual per-row pick too now.
--
-- 2026-08-04: "ready" (auto-summon has picked and claimed someone,
-- awaiting a ConfirmSummon click - see BeginCast) does NOT block a manual
-- click on a DIFFERENT row - that's a deliberate override, same as it
-- always could override FIFO order. If the manual pick differs from
-- whoever was "ready", release that stale claim first so it doesn't
-- linger until it naturally expires.
--
-- 2026-08-08: nothing refuses a manual pick outright any more, including
-- the genuinely in-flight states - see @kb:manual-override-two-click
-- below for the two-click warning that replaced the old flat refusal.
function DHAir:ManualSummon(name, immediate)
    if immediate == nil then immediate = true end
    if not self.db then return false end

    local key = self:NormalizeName(name)
    local entry = nil
    for _, e in ipairs(self.db.queue) do
        if self:NormalizeName(e.name) == key and not e.summoned then
            entry = e
            break
        end
    end
    if not entry then
        self:Print(self:NormalizeName(name) .. " isn't in the queue.")
        return false
    end

    if self.Sync_IsActive and self:Sync_IsActive() then
        local claim = self:GetClaim(entry.name)
        if claim and claim.by ~= UnitName("player") and not self:IsClaimStale(claim) then
            self:Print(self:NormalizeName(entry.name) .. " is already being summoned by "
                .. self:NormalizeName(claim.by) .. ".")
            return false
        end
    end

    -- @kb:manual-override-two-click
    -- 2026-08-08 (Loopi): a Warlock watching their own screen already
    -- knows when a ritual finished - the addon's job is showing WHO is
    -- ready, not deciding WHEN the Warlock is ("the advantage is that the
    -- warlocks do not have to hunt through raid frames"). So a manual pick
    -- is no longer refused outright; the old blanket "You're already
    -- summoning someone - please wait" is gone.
    -- The one concession, for a Warlock who ISN'T watching closely: while a
    -- ritual is genuinely in flight, switching targets takes two clicks,
    -- the first of which only explains what the second will do. Loopi's
    -- framing: gate slightly, never prohibit.
    local inFlight = (self.summonState == "casting" or self.summonState == "waiting")
    if inFlight then
        local prev = self.currentSummon
        local now = GetTime()
        if self.pendingOverrideName ~= key or not self.pendingOverrideAt
            or (now - self.pendingOverrideAt) > OVERRIDE_CONFIRM_SECONDS then
            self.pendingOverrideName = key
            self.pendingOverrideAt = now
            self:Print(self:NormalizeName(prev or "Someone") .. "'s summon is still in progress. "
                .. "Click again to switch to " .. self:NormalizeName(entry.name)
                .. " - that cancels the ritual in progress, and "
                .. self:NormalizeName(prev or "they") .. " STAYS in the queue.")
            return false
        end

        -- Second click - honour it. The displaced player is deliberately
        -- NOT marked summoned (Loopi: "I would rather summon someone twice
        -- than not summon them at all") - only a completed ritual does
        -- that, so they stay on the Board as still waiting. Release the
        -- claim so another Warlock can pick them up, and cancel our timers
        -- so the old summon's fallback can't fire against the new target.
        self:CancelTimeout()
        self:CancelCastWatchdog()
        if prev and self.ReleaseClaim then self:ReleaseClaim(prev) end
    end
    self.pendingOverrideName = nil
    self.pendingOverrideAt = nil

    if self.summonState == "ready" and self.currentSummon and key ~= self:NormalizeName(self.currentSummon) then
        if self.ReleaseClaim then self:ReleaseClaim(self.currentSummon) end
    end

    self.summonState = "idle" -- StartSummonAttempt expects a clean slate
    return self:StartSummonAttempt(entry, immediate)
end

-- The Board's "Confirm Summon" button - the ONE place, besides
-- ManualSummon, that's allowed to actually cast (see BeginCast's
-- pendingClickDriven check). Only valid while summonState == "ready"
-- (auto-summon already picked and claimed someone, but couldn't cast
-- itself - see TrySummonNext/BeginCast).
function DHAir:ConfirmSummon()
    if self.summonState ~= "ready" then
        self:Print("Nothing is waiting to be confirmed.")
        return false
    end
    self.pendingClickDriven = true -- this click IS the hardware event
    self:BeginCast()
    return true
end

-- Fires after the claim grace window elapses. If we still hold the
-- deterministic tie-break for this player, proceed to actually target and
-- cast; otherwise back off and let TrySummonNext pick a different target.
function DHAir:ResolveClaimAndCast()
    self.claimHandle = nil
    if self.summonState ~= "claiming" then return end -- already handled (e.g. lost the race earlier)

    local name = self.currentSummon
    local claim = self:GetClaim(name)
    local myName = UnitName("player")

    if not claim or claim.by ~= myName then
        self.summonState = "idle"
        self.currentSummon = nil
        self.pendingEntry = nil
        self:TrySummonNext()
        return
    end

    self:BeginCast()
end

-- Targets and casts on self.pendingEntry. Assumes currentSummon/pendingEntry
-- are already set by the caller (TrySummonNext, ResolveClaimAndCast, or a
-- failure retry timer).
--
-- 2026-08-04 (Loopi-requested one-click auto-summon redesign): the single
-- choke point for the pendingClickDriven gate. TargetUnit/CastSpellByName
-- can only succeed when called synchronously inside a real player click,
-- with zero C_Timer/event hops in between (see Warcraft Wiki's Secure
-- Execution and Tainting, and Blizzard's own 2006 statement: addons can
-- still cast spells "with user interaction," just can't "use logic to
-- intelligently pick spells or targets"). ManualSummon and ConfirmSummon
-- both set pendingClickDriven=true immediately before calling this, since
-- they ARE that user interaction; every other path into BeginCast
-- (TrySummonNext's auto-pick, by way of ResolveClaimAndCast or the
-- non-sharing branch of StartSummonAttempt, and the failure-retry timer)
-- leaves it false. When false, this stops BEFORE touching TargetUnit at
-- all and surfaces a one-click confirmation instead (the Board's "Confirm
-- Summon" button) rather than silently attempting - and failing - a
-- protected call.
function DHAir:BeginCast()
    local entry = self.pendingEntry
    if not entry then
        self.summonState = "idle"
        return
    end

    -- Reachability check happens BEFORE the click-driven gate below, so
    -- auto-summon doesn't falsely offer "Confirm Summon" for someone who
    -- isn't even in the group/raid yet - that's not a protected action,
    -- just a lookup, so it's fine to do automatically either way.
    local unit = FindGroupUnitByName(entry.name)
    if not unit then
        -- Player queued (e.g. via whisper) but not yet showing in the
        -- group roster. GROUP_ROSTER_UPDATE will retry this shortly.
        if self.ReleaseClaim then
            self:ReleaseClaim(entry.name)
        end
        self.summonState = "idle"
        self.currentSummon = nil
        self.pendingEntry = nil
        return
    end

    if not self.pendingClickDriven then
        self.summonState = "ready"
        self:Print("Ready to summon " .. self:NormalizeName(entry.name)
            .. " - click \"Confirm Summon\" on the Board to proceed.")
        if self.Board_Refresh then self:Board_Refresh() end
        return
    end

    -- 2026-08-06 (k-0010): does NOT call TargetUnit/CastSpellByName here
    -- anymore - see this file's header comment above CAST_WATCHDOG_SECONDS
    -- for why. Stash the resolved unit for the calling
    -- SecureActionButtonTemplate button's PreClick to pick up immediately
    -- (ManualSummon/ConfirmSummon both return right after this, having
    -- been called synchronously from that PreClick).
    self.pendingCastUnit = unit
    self.summonState = "casting"
    self.channelSeenForCast = false

    -- Safety net: SetAttribute (the PreClick side) can itself be blocked
    -- by combat lockdown, and even a successful secure cast can silently
    -- fail asynchronously (out of range, no shard, invalid target) via
    -- UNIT_SPELLCAST_FAILED with nothing raised here. If neither SUCCEEDED
    -- nor FAILED/INTERRUPTED resolves this within CAST_WATCHDOG_SECONDS,
    -- treat it as a failure so the normal retry/pause machinery takes over
    -- instead of leaving "casting" stuck forever (the original "already
    -- summoning, please wait" lockup this watchdog was added to prevent).
    self:CancelCastWatchdog()
    self.castWatchdogHandle = C_Timer.NewTimer(CAST_WATCHDOG_SECONDS, function()
        if DHAir.summonState == "casting" then
            DHAir:HandleSummonFailure("No response from the game client (the cast may have "
                .. "been silently blocked - see /dhair abort if this keeps happening)")
        end
    end)
end

-- 2026-08-06 (k-0010): builds the macro text a SecureActionButtonTemplate
-- button's PreClick should set as soon as DHAir.pendingCastUnit has been
-- resolved by a ManualSummon/ConfirmSummon call earlier in that SAME
-- PreClick - shared by Board.lua's row Summon button and footer Confirm
-- Summon button so the actual "/target .../cast ..." string only exists
-- in one place. UnitName(unit), not the queue entry's own stored name,
-- since that's exactly what the old direct TargetUnit(unit) call would
-- have targeted - same resolution, just expressed as macro text instead
-- of a direct protected-function call.
function DHAir:BuildCastMacro(unit)
    return "/target " .. UnitName(unit) .. "\n/cast " .. SUMMON_SPELL
end

-- Called on BAG_UPDATE. Only takes action if THIS addon paused things for
-- low shards (never touches a manual /dhair pause) - once restocked above
-- the threshold, resumes automatically so the Warlock doesn't have to
-- remember to type /dhair resume mid-run.
function DHAir:OnBagUpdate()
    if not self.db then return end
    if not self.db.paused or not self.pausedForShards then return end

    local minShards = self.db.minShards or 2
    local shardCount = GetShardCount()
    if shardCount ~= nil and shardCount >= minShards then
        self.db.paused = false
        self.pausedForShards = false
        self:Print("Soul Shards restocked (" .. shardCount .. "). Resuming auto-summon.")
        self:TrySummonNext()
    end
end

--------------------------------------------------------------------------
-- Spellcast event handling
--------------------------------------------------------------------------

-- Called from Core.lua's dispatcher for UNIT_SPELLCAST_* events.
function DHAir:OnSpellcastEvent(event, unit, ...)
    if unit ~= "player" then return end

    local spellName
    local castGUID, spellID = ...
    if spellID then
        spellName = GetSpellInfo(spellID)
    end

    if self.summonState ~= "casting" and self.summonState ~= "waiting" then return end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if spellName == SUMMON_SPELL and self.summonState == "casting" then
            self:CancelCastWatchdog()
            self.failCount = 0 -- the ritual actually started fine; forget past retries

            local entry = self.pendingEntry
            local rawName = self.currentSummon or (entry and entry.name)
            local shortName = self:NormalizeName(rawName or "target")

            self:Announce(shortName, rawName)
            self:Print("Summoning " .. shortName .. "...")

            -- @kb:channel-driven-advance
            -- 2026-08-08 (Loopi, 2nd raid test - one Warlock, 40+ summons):
            -- the old code parked here in "waiting" for a FIXED
            -- db.summonTimeout (default THIRTY SECONDS) with nothing able
            -- to end it early - ManualSummon refused every click ("You're
            -- already summoning someone - please wait") and TrySummonNext
            -- no-opped because the state wasn't idle. Loopi could summon
            -- three more players MANUALLY in the time DH-Air took to
            -- release one, which made the addon slower than not using it.
            --
            -- The real end-of-summon signal is the CHANNEL: Ritual of
            -- Summoning channels after this event (SUCCEEDED fires at
            -- channel START for a channeled spell), and the channel ends
            -- when the summon is actually accepted. So we now wait for
            -- UNIT_SPELLCAST_CHANNEL_STOP and advance the moment it
            -- arrives, instead of guessing with a timer.
            --
            -- The timer below survives only as a fallback for the case
            -- where channel events never arrive at all (so we can't get
            -- stuck in "waiting" forever). UNIT_SPELLCAST_CHANNEL_START
            -- CANCELS it - once we know we're channeling, CHANNEL_STOP is
            -- guaranteed to fire eventually (completion OR interruption),
            -- and a fallback firing mid-ritual would be actively harmful:
            -- it would arm the next player, and confirming them would
            -- cancel the ritual still in progress.
            --
            -- Its default is 4s, not 30 (Loopi, same day): if channel
            -- events turn out not to fire in Classic Era at all, he wants
            -- the addon erring toward being ready too early rather than
            -- ever reproducing the 30-second lockout. Arming early costs
            -- one ignorable prompt - he just doesn't click Confirm until
            -- his current ritual is finished.
            self.summonState = "waiting"
            -- k-0036 (2026-08-15, Loopi's in-game test): if CHANNEL_START
            -- already arrived (it fires BEFORE SUCCEEDED on this client -
            -- see the CHANNEL_START branch below - not simultaneously as
            -- k-0031 assumed), we already know a channel is in progress.
            -- Don't arm a fallback that could fire mid-ritual; trust
            -- CHANNEL_STOP alone to finish it.
            if not self.channelSeenForCast then
                self.timeoutHandle = C_Timer.NewTimer(self.db.summonTimeout or 4, function()
                    DHAir:Print(shortName .. ": no channel detected, moving on - "
                        .. "click Abort Summon if that ritual is still going.")
                    DHAir:FinishSummon(entry)
                end)
            end
        end
    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        -- We're confirmed channeling the ritual - the fallback timer is no
        -- longer needed (and must not fire mid-ritual; see above).
        --
        -- k-0036 (2026-08-15): track that we saw CHANNEL_START independent of
        -- summonState - on this client it fires BEFORE SUCCEEDED (state
        -- is still "casting" here, not "waiting" yet), so a state=="waiting"
        -- guard alone never catches it. SUCCEEDED (above) checks this flag
        -- before arming the fallback timer.
        if spellName == SUMMON_SPELL or spellName == nil then
            self.channelSeenForCast = true
            if self.summonState == "waiting" then
                self:CancelTimeout()
            end
        end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        -- The ritual channel ended - the summon was accepted (or the
        -- ritual broke). Either way this Warlock is free NOW, which is the
        -- entire point of the 2026-08-08 change. A broken ritual is
        -- recoverable: the player can simply re-queue (they're never
        -- refused - see the QueueFeedback re-queue work).
        if self.summonState == "waiting" and (spellName == SUMMON_SPELL or spellName == nil) then
            self:Print(self:NormalizeName(self.currentSummon or "Summon")
                .. " done - ready for the next one.")
            self:FinishSummon(self.pendingEntry)
        end
    elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
        -- Only bail out early if we're still in the casting stage (the ritual
        -- itself failed/was interrupted before completing).
        if self.summonState == "casting" and (spellName == SUMMON_SPELL or spellName == nil) then
            local reason = (event == "UNIT_SPELLCAST_FAILED") and "Summon ritual failed" or "Summon ritual was interrupted"
            self:HandleSummonFailure(reason)
        end
    end
end

--------------------------------------------------------------------------
-- Manual abort/reset (2026-08-04 addition, Loopi-requested)
--------------------------------------------------------------------------

-- Force-resets the summon state machine back to "idle" regardless of what
-- it currently is, releasing any claim this client is holding and
-- cancelling every in-flight timer (timeout/claim-grace/cast-watchdog).
-- The CAST_WATCHDOG_SECONDS safety net (see BeginCast) should now recover
-- a stuck "casting" state on its own within a few seconds, but this is the
-- explicit, immediate escape hatch Loopi asked for - /dhair abort, or the
-- Board's "Abort Summon" button (shown only while summonState ~= "idle" -
-- see Board.lua) - for whenever someone doesn't want to wait, or a future
-- stuck state the watchdog doesn't happen to cover.
function DHAir:AbortSummon()
    local wasIdle = (self.summonState == "idle")
    local rawName = self.currentSummon

    self:CancelTimeout()
    self:CancelClaimTimer()
    self:CancelCastWatchdog()

    if rawName and self.ReleaseClaim then
        self:ReleaseClaim(rawName)
    end

    self.summonState = "idle"
    self.currentSummon = nil
    self.pendingEntry = nil
    self.pendingClickDriven = false
    self.pendingCastUnit = nil
    self.pendingOverrideName = nil
    self.pendingOverrideAt = nil
    self.failCount = 0

    if wasIdle then
        self:Print("Nothing to abort - not currently summoning anyone.")
    else
        self:Print("Summon aborted" .. (rawName and (" for " .. self:NormalizeName(rawName)) or "")
            .. ". You can try again.")
    end
    return true
end
