-- DH-Air Roster.lua
-- Guild-wide registration: who's volunteering as a Summoner or a Clicker.
--
-- IMPORTANT: registering a role is a PURE DECLARATION. It never touches the
-- summon queue - joining the queue is always a separate, explicit action
-- (see Queue.lua / Board.lua). A parked player who's already at the meeting
-- spot can register without ever requesting a summon.
--
-- Broadcast over whatever channel Sync.lua currently picks (RAID > PARTY >
-- GUILD), so registration works even before a raid exists.
--
-- Summoner registrations also carry an "active" flag (auto-summon currently
-- running, vs. off/paused) - needed so the leader-succession rescue handoff
-- in Leadership.lua can rank candidates by who's actually working right
-- now, not just who's registered. This is necessarily a bit stale (only
-- refreshed when a Summoner toggles their role, or on the periodic HELLO
-- cadence) since we don't want a dedicated live-update broadcast for
-- something this infrequently needed - see Leadership.lua for how that
-- staleness is treated (a soft preference, not a hard requirement).

local ADDON_NAME, DHAir = ...

local ROSTER_TTL_SECONDS = 2700 -- entries older than this are treated as stale/offline (45 min, Loopi 2026-08-18 - was 5 min)

-- k-0033 (2026-08-13, found via Loopi's /run dump): lastSeen MUST use
-- time() (real wall-clock epoch), never GetTime() (seconds since the
-- CLIENT was launched, resets every relog). A registration stamped with
-- GetTime() in one session compared against a smaller GetTime() in a
-- later session produces a huge NEGATIVE "age", which is always less
-- than ROSTER_TTL_SECONDS - so the entry can never go stale, no matter
-- how long it's actually been. Confirmed live: a Warlock's lastSeen read
-- 1853905 while the current session's GetTime() was only 162776.

local function RosterTable(role)
    if role == "summoner" then return "summoners" end
    if role == "clicker" then return "clickers" end
    return nil
end

--------------------------------------------------------------------------
-- Queries
--------------------------------------------------------------------------

function DHAir:IsRegistered(role, name)
    if not self.db then return false end
    local tblName = RosterTable(role)
    local tbl = tblName and self.db.roster[tblName]
    if not tbl then return false end
    local entry = tbl[self:NormalizeName(name)]
    if not entry then return false end
    return (time() - entry.lastSeen) < ROSTER_TTL_SECONDS
end

function DHAir:CountRegistered(role)
    if not self.db then return 0 end
    local tblName = RosterTable(role)
    local tbl = tblName and self.db.roster[tblName]
    if not tbl then return 0 end
    local now = time()
    local n = 0
    for _, entry in pairs(tbl) do
        if (now - entry.lastSeen) < ROSTER_TTL_SECONDS then
            n = n + 1
        end
    end
    return n
end

-- Best-known guess at whether a registered Summoner currently has
-- auto-summon actively running. Necessarily approximate for anyone other
-- than yourself - see the module comment above.
function DHAir:IsSummonerActive(name)
    if not self:IsRegistered("summoner", name) then return false end
    local entry = self.db.roster.summoners[self:NormalizeName(name)]
    return entry ~= nil and entry.active == true
end

-- Recomputes the role that should be SHOWN for a player from current roster
-- state (summoner takes precedence over clicker if both are true). Single
-- source of truth used to (re)stamp queue entries whenever a registration
-- changes, so priority-tier sorting always reflects the current roster.
function DHAir:EffectiveRole(name)
    if self:IsRegistered("summoner", name) then return "summoner" end
    if self:IsRegistered("clicker", name) then return "clicker" end
    return nil
end

--------------------------------------------------------------------------
-- Recording (local writes, no broadcast - see SetRole for the public API)
--------------------------------------------------------------------------

-- Re-stamps a queue entry's .role field from current roster truth, if that
-- player happens to be in the queue right now.
function DHAir:RefreshQueueEntryRole(name)
    if not self.db then return end
    local key = self:NormalizeName(name)
    for _, entry in ipairs(self.db.queue) do
        if self:NormalizeName(entry.name) == key then
            entry.role = self:EffectiveRole(name)
        end
    end
end

function DHAir:RecordRegistration(role, name, active)
    local tblName = RosterTable(role)
    if not tblName or not self.db then return end
    self.db.roster[tblName][self:NormalizeName(name)] = { lastSeen = time(), active = active == true }
    self:RefreshQueueEntryRole(name)
end

function DHAir:RecordUnregistration(role, name)
    local tblName = RosterTable(role)
    if not tblName or not self.db then return end
    self.db.roster[tblName][self:NormalizeName(name)] = nil
    self:RefreshQueueEntryRole(name)
end

-- Wipes EVERY current role registration (Summoners and Clickers alike).
-- LOCAL ONLY - no broadcast, no permission check. See RequestClearRoster
-- below for the public, gated, broadcasting entry point. Split the same
-- way Queue.lua splits QueueReset from RequestClearAll, so Sync.lua's
-- receive-side CLEARROSTER handler can call this directly after its own
-- authority check without running HasPermission a second time.
function DHAir:ClearRoster()
    if not self.db then return end
    self.db.roster.summoners = {}
    self.db.roster.clickers = {}
end

-- Requests clearing every player's role registration. Raid leader/assist
-- only - same permission tier as Queue.lua's RequestClearAll
-- ("clear_roster", see Core.lua's HasPermission).
--
-- WHY THIS EXISTS (Loopi, 2026-08-13): registering a role is a durable
-- declaration with no auto-expiry tied to being online (see this file's
-- header comment) - by design, so a Summoner who briefly disconnects
-- doesn't drop off the roster mid-raid. The cost is that a player who
-- logs off or swaps to an alt WITHOUT toggling their role off first stays
-- counted as "ready" until ROSTER_TTL_SECONDS (45 min) quietly ages them
-- out - a passive safety net, not something a leader can trigger on
-- demand.
--
-- 2026-08-18 (Loopi): now the "Clear Roster/Queue" hard-clear button -
-- unregisters everyone AND fully wipes the queue (QueueReset), since a
-- Summoner/Clicker's D5 auto-joined queue row can't outlive their own
-- roster registration without going orphaned (the exact edge case Loopi
-- flagged after testing). The softer "Clear Queue" button
-- (RequestClearAll) leaves roster/queued Summoners/Clickers alone now -
-- see QueueResetNonRoster.
function DHAir:RequestClearRoster()
    if not self:HasPermission("clear_roster") then
        self:Print("Only the raid leader or an assistant can clear the ready roster.")
        return false
    end

    self:ClearRoster()
    self:QueueReset()
    if self.Sync_IsActive and self:Sync_IsActive() then
        self:Sync_Send("CLEARROSTER")
    end
    return true
end

--------------------------------------------------------------------------
-- Public API (local player toggling their own role)
--------------------------------------------------------------------------

function DHAir:SetRole(role, enabled)
    local myName = UnitName("player")
    local active = (role == "summoner") and (self.db.active and not self.db.paused) or false
    -- Captured BEFORE RecordUnregistration below, so the D5 auto-leave
    -- logic further down only fires on a REAL true->false transition, not
    -- a defensive/no-op "make sure this is off" call on a role that was
    -- never registered in the first place (which must never evict an
    -- unrelated, already-queued entry for this same player).
    local wasRegistered = self:IsRegistered(role, myName)

    if enabled then
        self:RecordRegistration(role, myName, active)
    else
        self:RecordUnregistration(role, myName)
    end

    if self.Sync_IsActive and self:Sync_IsActive() then
        if enabled then
            self:Sync_Send("REGISTER", role .. "|" .. myName .. "|" .. (active and "1" or "0"))
        else
            self:Sync_Send("UNREGISTER", role .. "|" .. myName)
        end
    end

    -- D5 (2026-08-17, Loopi - DH-Tools-WorldBuffRequest-Design.md):
    -- registering also puts a real queue entry on the Board (reusing the
    -- ordinary self-join path - see Summon.lua's D6 exclusion and
    -- QueueMarkSummoned's D8 reset for why this is safe), so everyone can
    -- see who's doing the work. Unregistering removes it again, mirroring
    -- registration state exactly.
    if enabled then
        self:SelfJoinQueue()
    elseif wasRegistered and not self:IsRegistered("summoner", myName) and not self:IsRegistered("clicker", myName) then
        -- Edge case: someone registered as BOTH roles unchecking just one
        -- must not remove their queue row while the other registration is
        -- still active. wasRegistered guards a defensive/no-op unregister
        -- call from evicting an unrelated, already-queued entry.
        self:SelfLeaveQueue()
    end
end

-- Re-broadcasts the player's own current registrations, including a fresh
-- active/paused snapshot. Piggybacks on the existing HELLO cadence in
-- Sync.lua so both staleness AND the active flag refresh periodically
-- without needing a separate timer.
function DHAir:Roster_Reannounce()
    if not (self.Sync_IsActive and self:Sync_IsActive()) then return end
    local myName = UnitName("player")
    local myKey = self:NormalizeName(myName)
    -- 2026-08-18 (Loopi-reported): was gated on IsRegistered (a FRESHNESS
    -- check), which meant a registration that had already gone stale -
    -- even while you were still online with the role still checked -
    -- could never refresh itself again, since the very check meant to let
    -- you back in also blocked the only thing that could restore
    -- freshness. Gate on the entry's mere EXISTENCE instead (still
    -- registered, whether or not currently fresh) - RecordUnregistration
    -- is what actually clears an entry, so this can't resurrect someone
    -- who genuinely unregistered or logged off (their own client, and
    -- therefore this function, simply isn't running for them any more).
    if self.db.roster.summoners[myKey] then
        local active = self.db.active and not self.db.paused
        self.db.roster.summoners[myKey] = { lastSeen = time(), active = active }
        self:Sync_Send("REGISTER", "summoner|" .. myName .. "|" .. (active and "1" or "0"))
    end
    -- WBM re-broadcast (2026-08-17, DH-Tools-WorldBuffRequest-Design.md D1)
    -- - same throttled cadence as the REGISTER reannounce above, so a
    -- Summoner's World Buff Mode signal stays fresh for as long as they're
    -- actually online, without a separate timer.
    if self.db.worldBuffMode and self.Sync_BroadcastWBM then
        self:Sync_BroadcastWBM(true)
    end

    if self.db.roster.clickers[myKey] then
        self:Sync_Send("REGISTER", "clicker|" .. myName .. "|0")
    end
end

--------------------------------------------------------------------------
-- Incoming message handling (called from Sync.lua's dispatcher)
--------------------------------------------------------------------------

function DHAir:Roster_OnMessage(msgType, rest)
    if msgType == "UNREGISTER" then
        local role, name = rest:match("^(.-)|(.+)$")
        if not role or not name then return end
        if role ~= "summoner" and role ~= "clicker" then return end
        self:RecordUnregistration(role, name)
        return
    end

    if msgType == "REGISTER" then
        local role, name, activeFlag = rest:match("^(.-)|(.-)|(.*)$")
        if not role or not name then return end
        if role ~= "summoner" and role ~= "clicker" then return end
        self:RecordRegistration(role, name, activeFlag == "1")
    end
end
