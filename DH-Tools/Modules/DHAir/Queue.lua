-- DH-Air Queue.lua
-- Manages the ordered summon queue and per-session summon history.

local ADDON_NAME, DHAir = ...

-- Strips a "-Realm" suffix for display / comparison purposes.
function DHAir:NormalizeName(name)
    if not name then return name end
    return name:match("^([^%-]+)") or name
end

-- Adds a player to the bottom of the queue. Returns true if added.
--
-- `note` is optional free text the requester typed after the code phrase
-- ("air to SM" -> "to SM"), captured by Invite.lua's whisper handler. It is
-- LOCAL to this client and never synced (QueueFeedback design D6).
--
-- 2026-08-07 (@kb:air-requeue-always): this used to refuse anyone in
-- `db.history`, described in the code as "already summoned this session".
-- There is no such thing as a session - db.history is account-wide
-- SavedVariables that nothing clears at login - so in practice it barred
-- people permanently, silently, for weeks. Per design D9, an accidental
-- re-summon is strictly better than a blocked join: a wasted shard is
-- cheap and visible, silent exclusion is neither. A guard here may INFORM
-- the Warlock; it must never refuse the requester.
-- roleOverride (2026-09-17, Option 1 fix): an explicit trailing arg, read
-- via `...` so a caller can distinguish "use MY authoritative role" (pass
-- it, even as nil/"") from "derive it locally" (omit it entirely - the
-- self-service call sites below, where local EffectiveRole derivation is
-- correct because it's about THIS client's own role). The Sync.lua ADD
-- receive handler always passes it (possibly nil), because deriving a
-- REMOTE player's role from this client's own local roster copy is
-- exactly the bug this fixes - it can silently come out nil here even
-- when the sender is genuinely registered.
function DHAir:QueueAdd(name, note, ...)
    if not name or name == "" then return false end
    local db = self.db
    local short = self:NormalizeName(name)
    local hasRoleOverride = select('#', ...) > 0
    local roleOverride = select(1, ...)

    for _, entry in ipairs(db.queue) do
        if self:NormalizeName(entry.name) == short then
            if not entry.summoned then
                return false -- already waiting - a genuine duplicate
            end

            -- Summoned earlier and asking again: reuse the existing entry
            -- rather than refusing (above) or inserting a second row for
            -- the same player. Destination is cleared deliberately - the
            -- old one is where they went LAST time, and silently reusing
            -- it would auto-summon them somewhere they didn't ask for.
            local waitedAgo = GetTime() - (entry.queuedAt or GetTime())
            entry.summoned = false
            entry.queuedAt = GetTime()
            entry.destination = nil
            entry.note = note
            if hasRoleOverride then
                entry.role = roleOverride
            else
                entry.role = (self.EffectiveRole and self:EffectiveRole(name)) or entry.role
            end
            self:Print(short .. " re-joined the summon queue (previously summoned "
                .. math.floor(waitedAgo / 60) .. "m ago).")
            if self.TrySummonNext then
                self:TrySummonNext()
            end
            return true
        end
    end

    table.insert(db.queue, {
        name = name,
        summoned = false,
        role = hasRoleOverride and roleOverride or (self.EffectiveRole and self:EffectiveRole(name) or nil),
        queuedAt = GetTime(),
        note = note,
    })
    -- QueueWaitingCount, not #db.queue: summoned entries stay in the table,
    -- so the raw length would announce a position far below where they
    -- actually are. Same bug class as the Board's "In queue" counter fixed
    -- 2026-08-07, flagged as a sibling in STATUS.md at the time.
    self:Print(short .. " added to the summon queue (position "
        .. self:QueueWaitingCount() .. ").")

    if self.TrySummonNext then
        self:TrySummonNext()
    end

    return true
end

-- Number of entries still WAITING (not yet summoned). db.queue keeps
-- summoned entries in place (QueueMarkSummoned only flags them, it never
-- removes), so #db.queue is the session total, not the waiting count -
-- anything user-facing that says "in queue" wants this instead.
function DHAir:QueueWaitingCount()
    local n = 0
    for _, entry in ipairs(self.db.queue) do
        if not entry.summoned then
            n = n + 1
        end
    end
    return n
end

-- Returns the first not-yet-summoned entry, or nil.
function DHAir:QueueNext()
    for _, entry in ipairs(self.db.queue) do
        if not entry.summoned then
            return entry
        end
    end
    return nil
end

--------------------------------------------------------------------------
-- Self-service (any DH-Air installation can join/leave, no permission needed)
--------------------------------------------------------------------------

-- Adds the local player to the queue. Same as being added by someone else's
-- whisper trigger, just self-initiated (e.g. from the Board's "Join queue"
-- button, or the /raid code phrase). Broadcasts so everyone else's queue
-- picks it up too.
function DHAir:SelfJoinQueue()
    local myName = UnitName("player")
    if self:QueueAdd(myName) then
        if self.Sync_BroadcastAdd then
            self:Sync_BroadcastAdd(myName)
        end
        return true
    end
    return false
end

-- Removes the local player from the queue. Always allowed - removing
-- yourself never needs permission, unlike removing someone else.
function DHAir:SelfLeaveQueue()
    local myName = UnitName("player")
    if self:QueueRemove(myName) then
        if self.Sync_IsActive and self:Sync_IsActive() then
            self:Sync_Send("REMOVE", myName)
        end
        return true
    end
    return false
end

--------------------------------------------------------------------------
-- Destinations (M1, see DH-Air-Destinations-Design.md) - local data model
-- only so far: no sync (M2) or officer-only editing (M3/M4) yet. Picking
-- your OWN destination is self-service, same idiom as SelfJoinQueue/
-- SelfLeaveQueue - no permission needed.
--------------------------------------------------------------------------

-- Looks up a destination entry ({ id, label, category }) by id, or nil if
-- unknown. `db.destinations` is small (tens of entries) so a linear scan
-- is plenty - no need for an id-keyed index.
function DHAir:GetDestination(destId)
    if not destId then return nil end
    for _, d in ipairs(self.db.destinations) do
        if d.id == destId then return d end
    end
    return nil
end

-- Shared implementation: sets (or clears, nil/"") `name`'s destination
-- within their existing queue entry, validating destId against
-- db.destinations. Callers are responsible for authorization - this
-- function itself doesn't check who's asking. SetMyDestination below
-- limits itself to the local player by construction; Sync.lua's SETDEST
-- receiver additionally verifies Name == sender before calling this for an
-- incoming broadcast, since one player must never be able to set another's
-- destination remotely.
function DHAir:ApplyDestination(name, destId)
    local short = self:NormalizeName(name)
    local entry = nil
    for _, e in ipairs(self.db.queue) do
        if self:NormalizeName(e.name) == short then
            entry = e
            break
        end
    end
    if not entry then return false end

    if destId == nil or destId == "" then
        entry.destination = nil
        return true
    end

    local dest = self:GetDestination(destId)
    if not dest or dest.enabled == false then
        -- Unknown id, or a real one an officer has since disabled - refuse
        -- rather than store a new selection the picker UI won't offer
        -- (Board's dropdown/`/dhair dest` both skip disabled entries).
        -- Doesn't touch an entry that already has this destination from
        -- before it was disabled - this function is only ever called to
        -- APPLY a (new) choice, never to silently re-validate an old one.
        return false
    end

    entry.destination = destId
    return true
end

-- Sets (or clears) the LOCAL PLAYER's own destination within their existing
-- queue entry. Requires the player to already be queued - destination is a
-- property of a queue entry, not something you can set in the abstract.
-- Self-service, no permission needed (same idiom as SelfJoinQueue/
-- SelfLeaveQueue) - broadcasts so other DH-Air installations' queues pick
-- it up too. Returns true/false so callers (Board.lua, later) can show a
-- refusal instead of failing silently.
--
-- Calls TrySummonNext() afterward (2026-08-03, same idiom SelfJoinQueue/
-- RELEASE/SUMMONED already follow) - a Warlock's auto-summon loop may
-- ALREADY be running and idle, having found nothing to match against
-- before this player picked a destination; without this, it wouldn't
-- notice the newly-eligible entry until some unrelated event (roster
-- change, bag update, etc.) happened to fire TrySummonNext again.
function DHAir:SetMyDestination(destId)
    local myName = UnitName("player")
    if not self:ApplyDestination(myName, destId) then
        return false
    end
    if self.Sync_IsActive and self:Sync_IsActive() then
        self:Sync_Send("SETDEST", myName .. "|" .. (destId or ""))
    end
    if self.TrySummonNext then
        self:TrySummonNext()
    end
    return true
end

-- Resolves a (possibly lower-cased) name to the exact name string stored on
-- its queue entry, or nil if nobody in the queue matches. Needed because
-- Commands.lua lower-cases the entire slash-command line before parsing it,
-- so "/dhair destfor loopi ..." can never match a stored "Loopi" under
-- NormalizeName's case-SENSITIVE comparison - every other consumer of a
-- name gets it from an event payload or the roster, already correctly
-- cased, which is why nothing needed this before.
function DHAir:FindQueuedName(query)
    if not query or query == "" then return nil end
    local q = self:NormalizeName(query):lower()
    for _, entry in ipairs(self.db.queue) do
        if self:NormalizeName(entry.name):lower() == q then
            return entry.name
        end
    end
    return nil
end

-- Sets (or clears, nil/"") ANOTHER player's destination - M3 of the
-- QueueFeedback design, and the whole answer to "how does a requester with
-- no addon pick a destination" (design D3). They don't: they say where they
-- want to go in chat, the Warlock reads it off the Board (the `note`
-- captured from "air to SM") and sets it for them here.
--
-- Leader/assist gated via HasPermission("set_dest_any"), not by calling
-- UnitHasAuthority directly - see Core.lua. Setting your OWN destination
-- is self-service and routes to SetMyDestination instead, so the SETDEST
-- wire message keeps its strict "self only" meaning and this function's
-- SETDESTFOR keeps its strict "someone else, authorized" meaning; nothing
-- has to disambiguate the two receive-side.
--
-- Whispers the affected player in PLAIN CHAT afterwards. That whisper is
-- the ONLY feedback a non-addon requester ever gets that anything happened
-- at all. Text comes from db.destSetMessage/db.destClearedMessage
-- (Core.lua defaults, editable on Config.lua's Messages page) via {dest}/
-- {setter} substitution - covers this function's own manual "set for
-- someone else" path AND World Buff Mode's automatic Booty Bay tag
-- (ApplyWorldBuffModeDestination in Invite.lua), since both call this same
-- function. It is sent by the SETTER only - the receive handler in
-- Sync.lua applies the change silently, or every DH-Air client in the
-- raid would whisper the same person at once.
function DHAir:RequestSetDestinationFor(name, destId)
    if not name or name == "" then return false end

    local myName = UnitName("player")
    if self:NormalizeName(name) == self:NormalizeName(myName) then
        return self:SetMyDestination(destId)
    end

    if not self:HasPermission("set_dest_any") then
        self:Print("Only the raid leader or an assistant can set someone else's destination.")
        return false
    end

    if not self:ApplyDestination(name, destId) then
        return false
    end

    if self.Sync_IsActive and self:Sync_IsActive() then
        self:Sync_Send("SETDESTFOR", name .. "|" .. (destId or ""))
    end

    local short = self:NormalizeName(name)
    local dest = destId and destId ~= "" and self:GetDestination(destId)
    local setterName = self:NormalizeName(myName)
    if dest then
        local template = (self.db and self.db.destSetMessage) or self.DEFAULT_DEST_SET_MESSAGE
        local msg = template:gsub("{dest}", dest.label):gsub("{setter}", setterName)
        SendChatMessage(msg, "WHISPER", nil, name)
        self:Print("Set " .. short .. "'s destination to " .. dest.label .. ".")
    else
        local template = (self.db and self.db.destClearedMessage) or self.DEFAULT_DEST_CLEARED_MESSAGE
        local msg = template:gsub("{setter}", setterName)
        SendChatMessage(msg, "WHISPER", nil, name)
        self:Print("Cleared " .. short .. "'s destination.")
    end

    -- Same reasoning as SetMyDestination's own call: our auto-summon loop
    -- may already be running and idle, having found nothing to match
    -- against until this entry finally got a destination.
    if self.TrySummonNext then
        self:TrySummonNext()
    end
    return true
end

--------------------------------------------------------------------------
-- Destinations list management (officer-gated) - see Core.lua's
-- HasPermission("edit_destinations"). No editor UI yet (M4) - these are
-- the plain functions that UI will eventually call, same "API before UI"
-- precedent DH-Bavin's Core.lua used for SetRecipient/SetEditors ahead of
-- its own config-page work.
--------------------------------------------------------------------------

-- Full replace of the destinations list. Broadcasts the new list to
-- everyone else so their Boards (M5) converge too.
function DHAir:SetDestinationList(list)
    if not self:HasPermission("edit_destinations") then
        return false
    end
    self.db.destinations = list
    if self.Sync_BroadcastDestinations then
        self:Sync_BroadcastDestinations()
    end
    return true
end

-- Convenience: discards any custom edits and repopulates from the built-in
-- starter list (Destinations.lua). Same permission gate as
-- SetDestinationList (this IS a full replace, just from a fixed source).
-- 2026-08-03: reset now mirrors DEFAULT_DESTINATIONS exactly - each entry's
-- own `enabled` field is respected (defaulting true when absent) instead of
-- being forced true, and `continent` is carried over too. Previously this
-- hardcoded enabled=true and dropped continent entirely, so a reset would
-- silently re-enable The Stockade/Ragefire Chasm/The Deadmines (meant to
-- stay off by default) and break the Board/Minimap "Flight Points >
-- continent" grouping until the next login's migration patched it back up.
-- "Reset to default" now means what it says: default is whatever
-- Destinations.lua currently defines, disabled entries included.
function DHAir:ResetDestinationsToDefault()
    local fresh = {}
    for _, d in ipairs(self.DEFAULT_DESTINATIONS or {}) do
        table.insert(fresh, {
            id = d.id,
            label = d.label,
            category = d.category,
            continent = d.continent,
            enabled = (d.enabled ~= false),
        })
    end
    return self:SetDestinationList(fresh)
end

-- Enables/disables a destination WITHOUT removing it from the list -
-- distinct from removal (DestinationEditor.lua's remove button), which
-- deletes the entry permanently. A disabled destination is hidden from
-- new-selection UI (Board's dropdown, FindDestinationByQuery below, and
-- ApplyDestination's own guard above) but keeps rendering normally
-- anywhere it's just being DISPLAYED - GetDestination doesn't filter by
-- enabled, so a queue entry that already picked it before it was disabled
-- (Board.lua's destText, SortedQueue's destLabel, the editor's own
-- read-only rows) keeps showing its real label instead of going blank.
-- Same officer gate as SetDestinationList; broadcasts the whole list since
-- Sync.lua doesn't have a narrower per-field message (DESTLIST is already
-- the one officer-edit broadcast, see EncodeDestinations/
-- DecodeDestinationsChunk for the enabled bit on the wire).
function DHAir:SetDestinationEnabled(destId, enabled)
    if not self:HasPermission("edit_destinations") then
        return false
    end
    local dest = self:GetDestination(destId)
    if not dest then
        return false
    end
    dest.enabled = enabled and true or false
    if self.Sync_BroadcastDestinations then
        self:Sync_BroadcastDestinations()
    end
    return true
end

-- Finds a destination by case-insensitive substring match against its
-- label (e.g. "iron" -> "Ironforge (Dun Morogh)"). Returns the single
-- match, or nil if there's no match OR more than one (ambiguous) -
-- callers should ask the player to be more specific rather than silently
-- guessing which one they meant. Used by slash commands as an interim
-- text-entry alternative ahead of a real dropdown picker (Board UI, M5).
function DHAir:FindDestinationByQuery(query)
    if not query or query == "" then return nil end
    local q = query:lower()
    local match, matchCount = nil, 0
    for _, d in ipairs(self.db.destinations) do
        if d.enabled ~= false and d.label:lower():find(q, 1, true) then
            match = d
            matchCount = matchCount + 1
        end
    end
    if matchCount == 1 then return match end
    return nil
end

--------------------------------------------------------------------------
-- Warlock's own operating destination (2026-08-03 addition) - which
-- destination auto-summon is currently servicing. DISTINCT from
-- SetMyDestination above, which sets YOUR OWN QUEUE ENTRY's destination if
-- you're queued as someone wanting a summon - a Warlock running
-- auto-summon isn't necessarily queued at all, and these two concepts can
-- differ (e.g. a Warlock who is ALSO queued for a summon elsewhere). Local
-- operating state only - never synced, unlike SETDEST/entry.destination,
-- since nobody else needs to know which destination YOU personally are
-- currently working. See Summon.lua's QueueNextAvailable for how this
-- filters auto-summon, and RequestStartAutoSummon/RequestResumeAutoSummon
-- for the "you must pick one before starting" gate.
--------------------------------------------------------------------------

function DHAir:GetWarlockDestination()
    return self.db.warlockDestination
end

-- Passing nil or "" clears it (auto-summon then has nothing to safely
-- match against - see QueueNextAvailable). Refuses an unrecognized OR
-- disabled destId (same "no new selection of a disabled destination" rule
-- ApplyDestination follows).
function DHAir:SetWarlockDestination(destId)
    if destId == nil or destId == "" then
        self.db.warlockDestination = nil
        return true
    end
    local dest = self:GetDestination(destId)
    if not dest or dest.enabled == false then
        return false
    end
    self.db.warlockDestination = destId
    return true
end

--------------------------------------------------------------------------
-- Permission-gated removal (see Core.lua's HasPermission/UnitHasAuthority)
--------------------------------------------------------------------------

-- Requests removing ANY player from the queue. Removing yourself is always
-- allowed; removing someone else requires raid leader/assist. Refuses
-- quietly (with a chat message) rather than attempting and failing, so the
-- UI can just call this without duplicating the permission check itself.
function DHAir:RequestRemove(name)
    local myName = UnitName("player")
    local isSelf = self:NormalizeName(name) == self:NormalizeName(myName)

    if not isSelf and not self:HasPermission("remove_any") then
        self:Print("Only the raid leader or an assistant can remove someone else from the queue.")
        return false
    end

    if not self:QueueRemove(name) then
        return false
    end

    -- 2026-08-18 (Loopi-reported): clear our OWN claim/pending pick on
    -- this name too, not just the queue row - covers removing someone
    -- we'd already picked ourselves (solo/non-shared mode never reaches
    -- Sync.lua's REMOVE receive-handler at all, and even while sharing,
    -- broadcasting REMOVE to others doesn't clear anything on OUR side).
    -- See AbandonPendingPick's comment (Summon.lua) for the full story.
    if self.ClearClaim then self:ClearClaim(name) end
    if self.AbandonPendingPick then self:AbandonPendingPick(name, "was removed from the queue") end

    if self.Sync_IsActive and self:Sync_IsActive() then
        self:Sync_Send("REMOVE", name)
    end
    return true
end

-- Requests clearing the waiting queue - everyone EXCEPT registered
-- Summoners/Clickers (see QueueResetNonRoster). Raid leader/assist only.
-- 2026-08-18 (Loopi): was a full wipe; use RequestClearRoster for that now.
function DHAir:RequestClearAll()
    if not self:HasPermission("clear_all") then
        self:Print("Only the raid leader or an assistant can clear the entire queue.")
        return false
    end

    self:QueueResetNonRoster()
    if self.Sync_IsActive and self:Sync_IsActive() then
        self:Sync_Send("CLEARALL")
    end
    return true
end

-- Requests changing the /raid chat code phrase. Leader/assist only for now
-- (see HasPermission - guild-officer-gated in 2.2, same call site).
function DHAir:RequestSetPhrase(newPhrase)
    if not newPhrase or newPhrase == "" then
        self:Print("Usage: /dhair phrase <word or phrase>")
        return false
    end

    if not self:HasPermission("set_phrase") then
        self:Print("Only the raid leader or an assistant can change the code phrase.")
        return false
    end

    self.db.codePhrase = newPhrase
    if self.Sync_IsActive and self:Sync_IsActive() then
        self:Sync_Send("SETPHRASE", newPhrase)
    end
    return true
end

-- Marks a queued player as summoned. The entry stays in db.queue flagged
-- rather than being removed, which is what lets the Board show what
-- happened this session and what lets QueueAdd re-queue them in place.
--
-- 2026-08-07: no longer writes db.history. That table's only reader was
-- QueueAdd's permanent re-queue block (see @kb:air-requeue-always); with
-- that gone it was a write-only table growing forever inside account-wide
-- SavedVariables, so it was removed entirely rather than left to rot.
function DHAir:QueueMarkSummoned(name)
    local db = self.db
    local short = self:NormalizeName(name)
    for _, entry in ipairs(db.queue) do
        if self:NormalizeName(entry.name) == short then
            entry.summoned = true
            -- D8 (2026-08-17, Loopi - DH-Tools-WorldBuffRequest-Design.md):
            -- Summoners/Clickers are never really "done" - reset right back
            -- so they stay available to summon again on demand, and so
            -- ManualSummon's "not e.summoned" lookup can still find them.
            if entry.role == "summoner" or entry.role == "clicker" then
                entry.summoned = false
            end
        end
    end
end

-- Clears only the "waiting for a summon" entries - Summoners/Clickers (and
-- their D5 auto-joined rows) are left untouched, so a routine reset
-- doesn't also boot the working crew off the Board. This is what "Clear
-- Queue" does now (2026-08-18, Loopi) - QueueReset below is reserved for
-- the harder "Clear Roster/Queue" action (Roster.lua's
-- RequestClearRoster), which still wants a true full wipe.
function DHAir:QueueResetNonRoster()
    local kept, removedNames = {}, {}
    for _, entry in ipairs(self.db.queue) do
        if entry.role == "summoner" or entry.role == "clicker" then
            table.insert(kept, entry)
        else
            table.insert(removedNames, entry.name)
        end
    end
    self.db.queue = kept
    -- Same clear-epoch stamp QueueReset uses (@kb:air-queue-clear-epoch) -
    -- a filtered clear should refuse resurrection just as much as a full
    -- one.
    self.db.queueClearedAt = time()

    -- Release claims and abandon a live pick ONLY for whoever was actually
    -- removed - a Summoner/Clicker's own claim (if they're mid-summon
    -- themselves) must survive this, unlike the full QueueReset below.
    for _, name in ipairs(removedNames) do
        if self.ClearClaim then self:ClearClaim(name) end
        if self.AbandonPendingPick then self:AbandonPendingPick(name) end
    end
end

-- Removes a player from the queue entirely.
function DHAir:QueueRemove(name)
    local db = self.db
    local short = self:NormalizeName(name)
    for i, entry in ipairs(db.queue) do
        if self:NormalizeName(entry.name) == short then
            table.remove(db.queue, i)
            return true
        end
    end
    return false
end

-- Clears the queue (fresh Air Service session).
function DHAir:QueueReset()
    self.db.queue = {}
    -- @kb:air-queue-clear-epoch - stamp every reset path (local trigger,
    -- received CLEARALL/RESET, or a healing CLEARALL pushed by a peer) so
    -- Sync.lua's Sync_MergeEntries can refuse to resurrect anything older
    -- than our own last clear. Wall-clock time(), never GetTime() (k-0033).
    self.db.queueClearedAt = time()
    if self.CancelTimeout then
        self:CancelTimeout()
    end
    self.summonState = "idle"
    self.currentSummon = nil
    self.pendingEntry = nil
    self.failCount = 0
    self.pausedForShards = false
    if self.claims then
        self.claims = {}
    end
    if self.syncBuffers then
        self.syncBuffers = {}
    end
    if self.destListBuffers then
        self.destListBuffers = {}
    end
    if self.destSyncDataBuffers then
        self.destSyncDataBuffers = {}
    end
    self:Print("Summon queue and session have been reset.")
end

-- Prints the current queue state to chat.
function DHAir:QueueList()
    local db = self.db
    -- QueueWaitingCount, not #db.queue - the sibling over-count flagged in
    -- STATUS.md alongside the Board counter fix (2026-08-07). With summoned
    -- entries persisting, #db.queue stays non-zero long after the last
    -- person waiting was summoned, so this claimed a queue that was empty.
    if self:QueueWaitingCount() == 0 then
        self:Print("Summon queue is empty.")
        return
    end
    self:Print("Current summon queue:")
    for i, entry in ipairs(db.queue) do
        local status = entry.summoned and "|cff00ff00(summoned)|r" or "|cffffff00(waiting)|r"
        self:Print(i .. ". " .. self:NormalizeName(entry.name) .. " " .. status)
    end
end

--------------------------------------------------------------------------
-- Display ordering (Board UI) - pure function, no side effects
--------------------------------------------------------------------------

-- Returns queue entries in Board display order:
--   1. the viewer's own entry (if queued), always first
--   2. Summoners (entry.role == "summoner"), sorted by sortKey/sortDir
--   3. Clickers (entry.role == "clicker"), sorted by sortKey/sortDir
--   4. everyone else: online members first, then offline (unknown/
--      not-a-guild-member counts as offline here - display-only, doesn't
--      affect anything permission-related). While the LOCAL viewer has
--      World Buff Mode on (db.worldBuffMode - per-character, not synced,
--      so this tier can look different on different Warlocks' screens),
--      the online half is further split Booty-Bay-destination-first,
--      ABOVE sortKey - everyone else in that tier still sorts by
--      sortKey/sortDir underneath that split. With World Buff Mode off,
--      the whole online half just sorts by sortKey/sortDir like the
--      offline half always does.
-- Sorting never reorders ACROSS tiers, only within each one - a Summoner
-- who just joined still outranks every regular member, but not a
-- Summoner who's been waiting longer than another Summoner.
function DHAir:SortedQueue(sortKey, sortDir)
    sortKey = sortKey or "wait"
    sortDir = sortDir or "desc"
    local myName = UnitName("player")
    local myKey = self:NormalizeName(myName)

    -- Resolves a queue entry's destId to its current label for sorting
    -- (M5, DH-Air-Destinations-Design.md §5) - undecided sorts as "" (an
    -- empty string), which naturally sorts first ascending / last
    -- descending, same as an unset name would under Lua's default string
    -- comparison. Looked up fresh each call rather than cached on the
    -- entry, since db.destinations can change (officer edits) independent
    -- of the queue itself.
    local function destLabel(entry)
        local d = entry.destination and self:GetDestination(entry.destination)
        return d and d.label or ""
    end

    local function compare(a, b)
        local c
        if sortKey == "name" then
            c = self:NormalizeName(a.name) < self:NormalizeName(b.name) and -1
                or (self:NormalizeName(a.name) > self:NormalizeName(b.name) and 1 or 0)
        elseif sortKey == "dest" then
            local aDest, bDest = destLabel(a), destLabel(b)
            c = aDest < bDest and -1 or (aDest > bDest and 1 or 0)
        else
            local aWait, bWait = GetTime() - (a.queuedAt or GetTime()), GetTime() - (b.queuedAt or GetTime())
            c = aWait < bWait and -1 or (aWait > bWait and 1 or 0)
        end
        if sortDir == "asc" then return c < 0 end
        return c > 0
    end

    local mine, summoners, clickers, regularOnline, regularOffline = nil, {}, {}, {}, {}
    for _, entry in ipairs(self.db.queue) do
        -- D7 (2026-08-17, Loopi - DH-Tools-WorldBuffRequest-Design.md):
        -- Summoner/Clicker rows stay visible regardless of summoned state -
        -- "so we can all see who is doing the work." QueueMarkSummoned's D8
        -- reset (above in this file) means entry.summoned should never
        -- actually stay true for these roles, but this is the belt-and-
        -- braces display-side guarantee in case a synced snapshot still
        -- carries a stale true momentarily.
        if not entry.summoned or entry.role == "summoner" or entry.role == "clicker" then
            if self:NormalizeName(entry.name) == myKey then
                mine = entry
            elseif entry.role == "summoner" then
                table.insert(summoners, entry)
            elseif entry.role == "clicker" then
                table.insert(clickers, entry)
            elseif self:IsGuildMemberOnline(entry.name) then
                table.insert(regularOnline, entry)
            else
                table.insert(regularOffline, entry)
            end
        end
    end

    table.sort(summoners, compare)
    table.sort(clickers, compare)
    table.sort(regularOffline, compare)

    if self.db.worldBuffMode then
        local booty, notBooty = {}, {}
        for _, entry in ipairs(regularOnline) do
            if entry.destination == "bootybay" then
                table.insert(booty, entry)
            else
                table.insert(notBooty, entry)
            end
        end
        table.sort(booty, compare)
        table.sort(notBooty, compare)
        regularOnline = {}
        for _, e in ipairs(booty) do table.insert(regularOnline, e) end
        for _, e in ipairs(notBooty) do table.insert(regularOnline, e) end
    else
        table.sort(regularOnline, compare)
    end

    local ordered = {}
    if mine then table.insert(ordered, mine) end
    for _, e in ipairs(summoners) do table.insert(ordered, e) end
    for _, e in ipairs(clickers) do table.insert(ordered, e) end
    for _, e in ipairs(regularOnline) do table.insert(ordered, e) end
    for _, e in ipairs(regularOffline) do table.insert(ordered, e) end
    return ordered
end
