-- DH-Air Sync.lua
-- Lets any DH-Air installation - Warlocks, Clickers, or plain members -
-- share one guild-wide summon queue and role roster over addon messages.
--
-- PROTOCOL (all messages are "TYPE|payload", sent via C_ChatInfo.SendAddonMessage
-- to RAID if in a raid, else PARTY if grouped, else GUILD so registration and
-- queueing work even before any raid exists; nothing is sent if db.shareQueue
-- is off):
--
--   HELLO|version             - "I'm here running DH-Air" (presence/heartbeat). version
--                               (2026-08-15) is the sender's DHAir.VERSION, purely additive -
--                               an old client's HELLO carries no payload and the receive
--                               handler already ignores unknown rest text, so this needed no
--                               PREFIX bump. Informational only (PrintPeers) since the
--                               2026-09-15 removal of the MIN_QUEUE_VERSION floor - see the
--                               removal note near that constant's former home below.
--   ADD|Name|Role              - a player was queued locally; peers should add them too.
--                               Role (2026-09-17, "summoner"/"clicker"/"") rides along from
--                               the sender instead of each receiver re-deriving it from its
--                               own local roster - that local re-derivation could silently
--                               come out nil on one client while correct on another, which
--                               was dropping the D5 summoner/clicker protection on just that
--                               client's copy of the entry. A missing "|" (pre-fix sender) is
--                               still accepted; the whole payload is then treated as Name.
--                               Used to be dropped receive-side below a MIN_QUEUE_VERSION
--                               floor; that floor compared DHAir.VERSION, which the
--                               2026-08-20 DH-Air-into-DH-Tools merge repointed at DH-Tools'
--                               OWN version numbering (restarted at 2.0.0) - so the floor
--                               (2.1.6, DH-Air's old standalone line) could never be met
--                               again and silently dropped every ADD broadcast raid-wide
--                               since the merge. Removed 2026-09-15 (Loopi/Chris) - see the
--                               former MIN_QUEUE_VERSION constant's removal note below.
--   CLAIM|Name|ClaimerName    - claimer is about to attempt summoning Name
--   RELEASE|Name              - the current claimer is giving up on Name; it's free again
--   SUMMONED|Name             - Name has been fully summoned (or timed out); mark done everywhere
--   RESET                     - clear the shared queue/session for everyone
--   REMOVE|Name               - remove Name from the queue (self always allowed;
--                               removing someone else requires the SENDER to be
--                               raid leader/assist, verified by the RECEIVER
--                               against their own roster - never self-asserted)
--   CLEARALL                  - clear the whole queue (sender must be leader/assist,
--                               verified the same way as REMOVE). Also sent, whispered,
--                               as a one-off self-heal push (2026-08-15, @kb:air-queue-
--                               clear-epoch) when Sync_MergeEntries notices a SYNCDATA
--                               reply carrying entries that predate our own last clear -
--                               see that function in this file.
--   CLEARROSTER               - clear every player's Summoner/Clicker registration
--                               (sender must be leader/assist, verified the same way
--                               as REMOVE/CLEARALL). Purely additive to the wire, same
--                               shape as SETDESTFOR: no PREFIX bump needed since the
--                               if/elseif chain below has no else branch, so a client
--                               on an older build just drops the unknown type.
--   SETPHRASE|newPhrase       - change the /raid chat code phrase (sender must be
--                               leader/assist for now, guild-officer-gated in 2.2 -
--                               verified the same way as REMOVE/CLEARALL)
--   REGISTER|role|Name        - Name is now volunteering as "summoner" or "clicker"
--   UNREGISTER|role|Name      - Name is no longer volunteering as that role
--   SYNCREQ                   - "I just joined/reloaded, please send me the current state"
--   SYNCDATA|i/total|data     - chunked full-state reply to a SYNCREQ (addon-whispered directly
--                               back to the requester, not broadcast, to cut down on raid traffic)
--   SETDEST|Name|destId       - Name (self only) picked/cleared their own queue destination;
--                               destId "" clears it. Self-service, no permission needed - the
--                               RECEIVER only applies it if Name == sender (see REMOVE's own
--                               "self always allowed" idiom - this is narrower still, since
--                               unlike REMOVE there's no leader/assist path to do it for someone
--                               else at all)
--   SETDESTFOR|Name|destId    - a raid leader/assist set SOMEONE ELSE's destination for them
--                               (M3, QueueFeedback design D3 - most requesters have no addon,
--                               so a Warlock sets it on their behalf). Sender authority is
--                               verified by the RECEIVER with UnitHasAuthority(sender), the same
--                               gate REMOVE/CLEARALL/SETPHRASE use - never self-asserted. This is
--                               the deliberate counterpart to SETDEST above: SETDEST stays
--                               strictly self-only and is NOT widened, so each message keeps one
--                               unambiguous meaning and neither handler has to guess which case
--                               it's looking at. Purely ADDITIVE to the wire (design D8): the
--                               if/elseif chain below has no else branch, so a client on 2.1.4 or
--                               earlier drops the unknown type harmlessly - hence no PREFIX bump.
--                               The cost of that choice is that an un-updated client's Board
--                               silently disagrees about destinations, so the release CARRYING
--                               this is the one everyone has to be on.
--   DESTLIST|i/total|data     - chunked, BROADCAST replacement of the whole destinations list -
--                               sender must be a guild officer (Core.lua's IsGuildOfficer / M3,
--                               DH-Air-Destinations-Design.md §3 - replaced the M2 interim
--                               leader/assist gate), verified by the RECEIVER the same way as
--                               REMOVE/CLEARALL/SETPHRASE. This is a fresh, unverified CLAIM of
--                               new state and is gated accordingly.
--   DESTSYNCDATA|i/total|data - chunked, WHISPERED reply to SYNCREQ carrying the responder's
--                               current destinations list, sent alongside the queue's own
--                               SYNCDATA. Deliberately NOT gated by sender authority - same
--                               reasoning DH-Bavin's own Sync.lua documents for its RECIPIENT/
--                               EDITORS resync: this just reflects state the responder already
--                               holds (which passed the DESTLIST gate whenever THEY received it),
--                               not a fresh claim of new authority, so any client can legitimately
--                               answer a late joiner's handshake with it - exactly like the
--                               existing queue SYNCDATA already works.
--
-- CONSISTENCY MODEL: this is a lightweight, eventually-consistent gossip
-- protocol, not a strict distributed lock. Two safety nets keep it correct
-- even if messages are dropped, arrive out of order, or a Warlock disconnects
-- mid-claim:
--   1. Claim ties (two Warlocks claim the same player within the same
--      instant) are broken deterministically by comparing claimer names -
--      every client that sees both claims picks the same winner, with no
--      extra messages needed.
--   2. Claims expire on their own (CLAIM_TTL) if never resolved via
--      SUMMONED or RELEASE, so a disconnect can't permanently lock a player
--      out of the queue for everyone else.
-- The one thing this protocol guarantees above all else is the thing that
-- actually matters here: two Warlocks should not both spend a Soul Shard
-- summoning the same player. Minor raciness in queue ORDER across clients
-- is a cosmetic non-issue by comparison.

local ADDON_NAME, DHAir = ...

-- 2026-08-05: this version suffix is the ONLY thing standing between two
-- differently-versioned clients and silent data corruption. WoW addon
-- messages are received ONLY by clients that registered the exact same
-- prefix (C_ChatInfo.RegisterAddonMessagePrefix, below) - two clients on
-- different prefixes simply never hear each other at all, which is the
-- failure mode we want (no sync) instead of the one we just had (corrupted
-- sync). Tonight's incident: `continent` was added to the destinations data
-- model but NOT to this file's wire format (EncodeDestinations/
-- DecodeDestinationsChunk) - every DESTLIST/DESTSYNCDATA round-trip kept
-- silently dropping it (and, in one case, an old-format payload no longer
-- matching the fixed decode pattern at all, wiping the receiver's list to
-- empty) with zero warning, and it recurred on every reload because
-- whichever client answered the sync handshake was still on the old
-- format. See knowledge\k-0009 for the full writeup.
-- STANDING RULE: bump this suffix (V1 -> V2 -> ...) any time a change to
-- this file's wire format (message shape, field count/order, or meaning)
-- is not purely additive/backward-compatible. Bumped V1 -> V2 now for the
-- continent fix above. DH-Bavin's and DH-Quests' Sync.lua carry the exact
-- same PREFIX pattern and the exact same rule - see those files.
local PREFIX = "DHAirQueueV2"
local MAX_CHUNK_CHARS = 200
local CLAIM_TTL_SECONDS = 120     -- how long an unresolved claim is honored before being treated as stale
local HELLO_INTERVAL_SECONDS = 300 -- re-announce presence at most this often

-- REMOVED 2026-09-15 (Loopi/Chris): MIN_QUEUE_VERSION (a floor on
-- DHAir.VERSION below which a peer's ADD broadcasts were silently
-- dropped receive-side - added 2026-08-15 to guard against an old
-- STANDALONE DH-Air client's long-fixed auto-queue bug) and its
-- ParseVersionSegments/VersionAtLeast helpers lived here. The
-- 2026-08-20 DH-Air-into-DH-Tools merge repointed DHAir.VERSION
-- (Core.lua) at DH-Tools' own addon metadata, whose version numbering
-- restarted at 2.0.0 - so the floor (2.1.6, from DH-Air's retired
-- standalone line) could never be satisfied again by any real client,
-- and every ADD broadcast has been silently dropped raid-wide ever
-- since the merge. Found via Loopi's in-raid report (a non-Warlock
-- queue member saw their own role registration sync fine - REGISTER/
-- UNREGISTER were never gated - but never saw anyone ELSE's queue
-- joins appear). No replacement floor is needed: the bug this guarded
-- against can't recur now that DH-Air only ships inside DH-Tools, with
-- no standalone build left to be "old".

DHAir.claims = {}       -- normalizedName -> { by = "ClaimerName", receivedAt = GetTime() }
DHAir.peers = {}        -- name -> { lastSeen = GetTime(), version = "x.y.z" or nil (unknown until their HELLO arrives) }
-- normalizedName -> { firstSeen = GetTime(), lastSeen = GetTime() } for
-- registered Summoners currently broadcasting World Buff Mode active (see
-- Sync_BroadcastWBM/GetAvailableWorldBuffSummoner below,
-- DH-Tools-WorldBuffRequest-Design.md D1/D3).
DHAir.peerWBM = {}
-- Matches Roster.lua's ROSTER_TTL_SECONDS by design - same staleness
-- tolerance as registration entries, refreshed by the same Roster_Reannounce
-- cadence.
local WBM_TTL_SECONDS = 2700 -- 45 min (Loopi 2026-08-18 - was 5 min, see Roster.lua's ROSTER_TTL_SECONDS)
DHAir.syncBuffers = {}  -- sender -> { total = n, chunks = {} } for reassembling SYNCDATA
DHAir.destListBuffers = {}     -- same shape, for reassembling gated DESTLIST broadcasts
DHAir.destSyncDataBuffers = {} -- same shape, for reassembling ungated DESTSYNCDATA replies
DHAir.lastHelloSent = 0

--------------------------------------------------------------------------
-- Low-level send/receive
--------------------------------------------------------------------------

local function AddonSendMessage(text, channel, target)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, text, channel, target)
    elseif SendAddonMessage then
        SendAddonMessage(PREFIX, text, channel, target)
    end
end

local function RegisterPrefix()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    elseif RegisterAddonMessagePrefix then
        pcall(RegisterAddonMessagePrefix, PREFIX)
    end
end

-- Returns the broadcast channel to use, or nil if sharing isn't possible
-- right now (feature turned off). Prefers the tightest channel available -
-- RAID/PARTY are lower-latency and less noisy than guild-wide GUILD chat -
-- but falls back to GUILD so registration and queueing work even before any
-- raid exists.
function DHAir:Sync_Channel()
    if not self.db or not self.db.shareQueue then return nil end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    if IsInGuild() then return "GUILD" end
    return nil
end

function DHAir:Sync_IsActive()
    return self:Sync_Channel() ~= nil
end

-- Broadcasts a message to the whole raid/party.
function DHAir:Sync_Send(msgType, payload)
    local channel = self:Sync_Channel()
    if not channel then return end
    local text = payload and (msgType .. "|" .. payload) or msgType
    AddonSendMessage(text, channel)
end

-- Sends a message directly to one player (used for SYNCDATA replies, to
-- avoid broadcasting a potentially large state dump to the whole raid).
function DHAir:Sync_SendTo(msgType, payload, targetName)
    if not self.db or not self.db.shareQueue then return end
    local text = payload and (msgType .. "|" .. payload) or msgType
    AddonSendMessage(text, "WHISPER", targetName)
end

-- Our OWN group membership, collapsed to the only three values that change
-- what sync can reach us: solo (GUILD channel), party, raid. M4 compares
-- this against the previous value to tell a real membership change from the
-- constant background churn of GROUP_ROSTER_UPDATE.
local function GroupState()
    if IsInRaid() then return "raid" end
    if IsInGroup() then return "party" end
    return "solo"
end

function DHAir:Sync_Init()
    RegisterPrefix()
    -- Seed the M4 baseline BEFORE any GROUP_ROSTER_UPDATE can be handled,
    -- so login itself doesn't read as a membership change and fire a second
    -- SYNCREQ on top of the one below.
    self.lastGroupState = GroupState()
    if self:Sync_IsActive() then
        self:Sync_SendHello()
        self:Sync_Send("SYNCREQ")
    end
end

-- Called on GROUP_ROSTER_UPDATE - re-announce presence (throttled) so
-- Warlocks who join later still discover each other, and (M4) ask for a
-- full state resync when OUR OWN membership actually changed.
--
-- @kb:air-syncreq-on-membership-change
-- M4 / finding F4: SYNCREQ used to be sent only from Sync_Init at
-- PLAYER_LOGIN. But Sync_Channel prefers RAID > PARTY > GUILD, so the
-- moment the Warlock is in a raid, every ADD/CLAIM/SUMMONED goes to RAID
-- only - and a requester is by definition NOT in the raid at the time they
-- whisper. They'd never hear the ADD that queued them, and stayed missing
-- from their own Board until a /reload or a manual `/dhair sync`.
--
-- The reason this asks on CHANGE rather than on every GROUP_ROSTER_UPDATE:
-- that event fires constantly during a raid (every join, leave, promotion,
-- zone change, and more), and each SYNCREQ makes every peer answer with a
-- whispered multi-chunk SYNCDATA dump of the entire queue. Firing per event
-- would turn one raid into a broadcast storm. Membership state only changes
-- when we genuinely move between solo/party/raid - which is exactly, and
-- only, when the channel we're listening on changed underneath us.
function DHAir:Sync_OnRosterChanged()
    local state = GroupState()
    local changed = (state ~= self.lastGroupState)
    -- Recorded even when sharing is off, so toggling shareQueue back on
    -- can't make a long-stale baseline look like a fresh change.
    self.lastGroupState = state

    if not self:Sync_IsActive() then return end

    if changed then
        self:Sync_Send("SYNCREQ")
    end

    local now = GetTime()
    if now - (self.lastHelloSent or 0) < HELLO_INTERVAL_SECONDS then return end
    self:Sync_SendHello()
end

function DHAir:Sync_SendHello()
    self.lastHelloSent = GetTime()
    -- Version travels as HELLO's payload (additive - an old client already
    -- ignores HELLO's rest entirely, see the receive handler on the old
    -- build). Informational only (PrintPeers) since the 2026-09-15
    -- removal of the MIN_QUEUE_VERSION gate - see that removal's note
    -- earlier in this file.
    self:Sync_Send("HELLO", self.VERSION)
    if self.Roster_Reannounce then
        self:Roster_Reannounce()
    end
end

-- World Buff Mode presence (DH-Tools-WorldBuffRequest-Design.md D1) - lets
-- any online client see which registered Summoners currently have World
-- Buff Mode active, without needing to share a raid/party with them.
-- Self-only, ungated, same idiom as SETDEST - the sender's identity comes
-- from the trusted addon-message channel itself, so the payload doesn't
-- need to embed a name (same as HELLO). Sent once immediately on every
-- on/off toggle (Board.lua); re-sent periodically while active by
-- Roster_Reannounce's throttled cadence.
function DHAir:Sync_BroadcastWBM(active)
    self:Sync_Send("WBM", active and "1" or "0")
end

-- Returns the normalized name of the online, registered Summoner whose
-- World Buff Mode signal has been active LONGEST (still within
-- WBM_TTL_SECONDS), or nil if none currently qualify. "Longest active"
-- (D3) - first-come-first-served among currently-active signals, so a
-- Summoner who's been available longer wins ties over one who just
-- turned it on.
function DHAir:GetAvailableWorldBuffSummoner()
    local best, bestFirstSeen = nil, math.huge
    local now = GetTime()
    for name, entry in pairs(self.peerWBM) do
        if (now - entry.lastSeen) < WBM_TTL_SECONDS and self:IsRegistered("summoner", name) then
            if entry.firstSeen < bestFirstSeen then
                best, bestFirstSeen = name, entry.firstSeen
            end
        end
    end
    return best
end

--------------------------------------------------------------------------
-- Claims
--------------------------------------------------------------------------

function DHAir:IsClaimStale(claim)
    if not claim then return true end
    return (GetTime() - claim.receivedAt) > CLAIM_TTL_SECONDS
end

-- Stores/refreshes a claim, applying the deterministic tie-break: if a
-- different claimer is already recorded and still fresh, only the
-- alphabetically-earlier name wins (every client applies the same rule,
-- so all clients converge on the same winner independent of message order).
function DHAir:StoreClaim(name, claimerName)
    self.claims = self.claims or {}
    local key = self:NormalizeName(name)
    local existing = self.claims[key]

    if existing and existing.by ~= claimerName and not self:IsClaimStale(existing) then
        if claimerName < existing.by then
            self.claims[key] = { by = claimerName, receivedAt = GetTime() }
        end
        -- else: existing claimer already wins the tie-break; keep it.
    else
        self.claims[key] = { by = claimerName, receivedAt = GetTime() }
    end
end

function DHAir:ClearClaim(name)
    if not self.claims then return end
    self.claims[self:NormalizeName(name)] = nil
end

function DHAir:GetClaim(name)
    if not self.claims then return nil end
    return self.claims[self:NormalizeName(name)]
end

-- Releases OUR claim (if we hold it) and tells everyone else it's free.
function DHAir:ReleaseClaim(name)
    if not name then return end
    self:ClearClaim(name)
    if self:Sync_IsActive() then
        self:Sync_Send("RELEASE", name)
    end
end

--------------------------------------------------------------------------
-- Outgoing state-change broadcasts (called from Queue.lua / Summon.lua)
--------------------------------------------------------------------------

function DHAir:Sync_BroadcastAdd(name)
    if self:Sync_IsActive() then
        -- 2026-09-17 (Loopi): role now rides along in the ADD payload
        -- (Option 1 fix for the queue-visibility desync bug) instead of
        -- being locally re-derived by every receiver - see the ADD
        -- receive handler below.
        local role = (self.EffectiveRole and self:EffectiveRole(name)) or ""
        self:Sync_Send("ADD", name .. "|" .. role)
    end
end

function DHAir:Sync_BroadcastSummoned(name)
    if self:Sync_IsActive() then
        self:Sync_Send("SUMMONED", name)
    end
end

function DHAir:Sync_BroadcastReset()
    if self:Sync_IsActive() then
        self:Sync_Send("RESET")
    end
end

--------------------------------------------------------------------------
-- Full-state sync (for late joiners / reloads)
--------------------------------------------------------------------------

local function RoleCode(role)
    if role == "summoner" then return "s" end
    if role == "clicker" then return "c" end
    return ""
end

local function RoleFromCode(code)
    if code == "s" then return "summoner" end
    if code == "c" then return "clicker" end
    return nil
end

-- Encodes the local queue as "Name:status:role:elapsed:destId,..." - elapsed
-- is seconds since queued, transmitted rather than an absolute timestamp
-- since GetTime() isn't comparable across clients (same reasoning as claim
-- TTLs). destId (M2) is our own generated slug (no ":" or "," ever) or
-- empty if unset - trailing field, so an older/newer client mismatch would
-- still parse everything before it correctly.
local function EncodeQueue(queue)
    local parts = {}
    local now = GetTime()
    for _, entry in ipairs(queue) do
        local elapsed = math.max(0, math.floor(now - (entry.queuedAt or now)))
        table.insert(parts, entry.name .. ":" .. (entry.summoned and "1" or "0")
            .. ":" .. RoleCode(entry.role) .. ":" .. elapsed .. ":" .. (entry.destination or ""))
    end
    return table.concat(parts, ",")
end

local function DecodeQueueChunk(data)
    local entries = {}
    for pair in data:gmatch("[^,]+") do
        local name, status, roleCode, elapsed, destId = pair:match("^(.-):(%d):([a-z]*):(%d+):(.*)$")
        if name then
            table.insert(entries, {
                name = name,
                summoned = (status == "1"),
                role = RoleFromCode(roleCode),
                elapsed = tonumber(elapsed) or 0,
                destination = (destId ~= "" and destId) or nil,
            })
        end
    end
    return entries
end

-- Splits an already-comma-joined encoded string into chunks of at most
-- maxChars, always cutting at a comma boundary so no individual record is
-- ever split across two chunks. Shared by the queue's own SYNCDATA and (M2)
-- the destinations list's DESTLIST/DESTSYNCDATA - same chunking rules,
-- different payloads.
local function ChunkEncoded(encoded, maxChars)
    local chunks = {}
    local remaining = encoded
    while #remaining > 0 do
        if #remaining <= maxChars then
            table.insert(chunks, remaining)
            remaining = ""
        else
            local cut = remaining:sub(1, maxChars)
            local lastComma = cut:find(",[^,]*$")
            if not lastComma then lastComma = maxChars end
            table.insert(chunks, remaining:sub(1, lastComma - 1))
            remaining = remaining:sub(lastComma + 1)
        end
    end
    return chunks
end

-- Encodes db.destinations as "id:category:enabled:continent:label,..." -
-- id/category never contain ":" or "," (both are our own generated slugs),
-- enabled is always exactly "0" or "1", continent is "Eastern Kingdoms" |
-- "Kalimdor" | "" (summonstones have none), and none of the current labels
-- contain ":" or "," either (see Destinations.lua's header note if that
-- ever changes - officer-entered labels via the editor, M4, will need
-- sanitizing against this before it's a real concern). label stays the
-- LAST field specifically because it's the only free-form one - the
-- pattern below captures everything after the fourth ":" as label,
-- however it uses that. enabled (2026-08-03, DestinationEditor.lua's
-- enable/disable toggle) placed BEFORE label for that same reason, not
-- trailing like destId is on the queue's own EncodeQueue.
-- 2026-08-05 (Loopi-reported bug, real data loss): `continent` was added
-- to the destinations DATA MODEL (Destinations.lua) but never added to
-- THIS wire format - every DESTLIST broadcast (fires on any officer edit,
-- including a plain add/remove/toggle through DestinationEditor.lua) and
-- every DESTSYNCDATA login/reload handshake reply (fires automatically,
-- answered by ANY online DH-Air client, not just the officer's own) did a
-- full unconditional `self.db.destinations = DecodeDestinationsChunk(...)`
-- replace using this format - silently stripping continent off EVERY
-- destination on EVERY receiving client, every time, including the
-- responder's own reload. This is almost certainly what caused both the
-- original "None configured" report and freshly-added destinations
-- vanishing again after a reload (a still-online peer, or the responder's
-- own next reload, replays the old field-dropping format right back).
-- Fixed by carrying continent over the wire too - the local, non-networked
-- CopyDestinations bug (DestinationEditor.lua) fixed earlier tonight was
-- real but was never the dominant cause; this was.
local function EncodeDestinations(list)
    local parts = {}
    for _, d in ipairs(list) do
        local enabledFlag = (d.enabled == false) and "0" or "1"
        table.insert(parts, d.id .. ":" .. (d.category or "") .. ":" .. enabledFlag .. ":" .. (d.continent or "") .. ":" .. (d.label or ""))
    end
    return table.concat(parts, ",")
end

local function DecodeDestinationsChunk(data)
    local entries = {}
    for pair in data:gmatch("[^,]+") do
        local id, category, enabledFlag, continent, label = pair:match("^(.-):(.-):(.-):(.-):(.*)$")
        if id and id ~= "" then
            -- Anything other than a literal "0" decodes as enabled - true
            -- default, matching GetDestination/ApplyDestination's own
            -- `enabled ~= false` convention, and tolerant of a stray/older
            -- payload that's missing the field entirely. Empty string
            -- decodes continent back to nil (summonstones, or an older
            -- peer still on the pre-continent wire format).
            table.insert(entries, {
                id = id,
                category = category,
                enabled = (enabledFlag ~= "0"),
                continent = (continent ~= "" and continent or nil),
                label = label,
            })
        end
    end
    return entries
end

function DHAir:Sync_SendState(targetName)
    local encoded = EncodeQueue(self.db.queue)
    if encoded ~= "" then
        local chunks = ChunkEncoded(encoded, MAX_CHUNK_CHARS)
        local total = #chunks
        for i, chunk in ipairs(chunks) do
            self:Sync_SendTo("SYNCDATA", i .. "/" .. total .. "|" .. chunk, targetName)
        end
    end

    -- Also send our current destinations list so a late joiner converges
    -- to the officer's actual current list, not just Destinations.lua's
    -- built-in defaults. Separate message type (DESTSYNCDATA, not
    -- DESTLIST) and deliberately ungated - see this file's header comment.
    self:Sync_SendDestinationsTo(targetName)
end

-- Whispered, ungated resync reply - see header comment on DESTSYNCDATA.
function DHAir:Sync_SendDestinationsTo(targetName)
    local encoded = EncodeDestinations(self.db.destinations)
    if encoded == "" then return end
    local chunks = ChunkEncoded(encoded, MAX_CHUNK_CHARS)
    local total = #chunks
    for i, chunk in ipairs(chunks) do
        self:Sync_SendTo("DESTSYNCDATA", i .. "/" .. total .. "|" .. chunk, targetName)
    end
end

-- Broadcast, gated (real guild-officer rank check, M3 - see IsGuildOfficer
-- in Core.lua) - called after an officer edit changes db.destinations
-- wholesale. See this
-- file's header comment on DESTLIST vs. DESTSYNCDATA.
function DHAir:Sync_BroadcastDestinations()
    if not self:Sync_IsActive() then return end
    local encoded = EncodeDestinations(self.db.destinations)
    if encoded == "" then return end
    local chunks = ChunkEncoded(encoded, MAX_CHUNK_CHARS)
    local total = #chunks
    for i, chunk in ipairs(chunks) do
        self:Sync_Send("DESTLIST", i .. "/" .. total .. "|" .. chunk)
    end
end

-- Slack for @kb:air-queue-clear-epoch's staleness comparison, seconds -
-- absorbs ordinary message/encode latency between "remote encoded this
-- entry's elapsed" and "we're comparing it here", same idea as the 0.5s
-- slack below but a little more generous since this crosses a whole
-- SYNCDATA round-trip rather than one message.
local QUEUE_CLEAR_SLACK_SECONDS = 2

-- Merges received entries into our local queue/history. "Summoned" is
-- sticky - it only ever upgrades a local waiting entry to summoned, never
-- the reverse, since avoiding a double-summon is the whole point. Role and
-- wait time are only used to BOOTSTRAP a brand-new entry we didn't already
-- know about - if we already have this entry locally, its role stays under
-- the authority of Roster.lua's REGISTER/UNREGISTER tracking instead, since
-- that's fresher than a potentially-stale SYNCDATA snapshot.
--
-- @kb:air-queue-clear-epoch (2026-08-15, Loopi): a "not found" remote entry
-- used to be inserted unconditionally. That meant a peer who simply missed
-- one CLEARALL broadcast (offline at the time) would silently hand their
-- whole stale queue right back to us the next time we logged in and sent
-- SYNCREQ - db.queueClearedAt (Core.lua) is the fix: reject any remote
-- entry whose IMPLIED WALL-CLOCK queue time predates our own last clear.
-- elapsed is a duration, not a clock reading, so `time() - elapsed` is
-- safe to compare across clients even though raw GetTime() isn't (see
-- EncodeQueue's own comment on that).
--
-- Loopi also asked this cut both ways: don't just protect our own queue,
-- push the fix back to whoever sent the stale data, once, so THEIR client
-- self-heals too instead of quietly resurrecting the same stale queue for
-- the next person who asks them. Sync_SendTo("CLEARALL", nil, sender)
-- reuses the exact same wire message and receive-side authority check
-- every other CLEARALL goes through (self:UnitHasAuthority(sender)) - if
-- we're not verified leader/assist from THEIR roster's point of view, the
-- push is a safe, silent no-op, same as any other unprivileged CLEARALL.
function DHAir:Sync_MergeEntries(entries, sender)
    local clearedAt = self.db.queueClearedAt or 0
    local sawStale = false

    for _, remote in ipairs(entries) do
        local impliedWallQueuedAt = time() - (remote.elapsed or 0)

        if impliedWallQueuedAt < clearedAt - QUEUE_CLEAR_SLACK_SECONDS then
            sawStale = true
        else
            local key = self:NormalizeName(remote.name)
            local found = nil
            for _, local_ in ipairs(self.db.queue) do
                if self:NormalizeName(local_.name) == key then
                    found = local_
                    break
                end
            end

            local remoteQueuedAt = GetTime() - (remote.elapsed or 0)

            if not found then
                table.insert(self.db.queue, {
                    name = remote.name,
                    summoned = remote.summoned,
                    role = remote.role,
                    queuedAt = remoteQueuedAt,
                    destination = remote.destination,
                    -- note is deliberately absent: it's local-only (D6) and
                    -- never travels on the wire, so a merged entry has none.
                })
            elseif remote.summoned and not found.summoned then
                -- FRESHNESS GUARD (2026-08-07, @kb:air-requeue-always).
                -- "summoned" is otherwise sticky - it only ever upgrades
                -- waiting -> summoned, because not double-summoning someone
                -- is the protocol's one hard guarantee. But now that
                -- QueueAdd re-queues a previously-summoned player in place,
                -- a peer still holding the OLD snapshot would otherwise
                -- silently re-flag that fresh entry as already summoned,
                -- undoing the re-join with no message anywhere. So only
                -- accept the remote "summoned" when the remote entry is at
                -- least as new as ours; if ours was queued more recently,
                -- it's a re-join the peer hasn't heard about yet and their
                -- snapshot is stale. Half-second slack absorbs ordinary
                -- message latency, which would otherwise make a
                -- simultaneous ADD/SUMMONED pair look like a re-join.
                if remoteQueuedAt >= (found.queuedAt or 0) - 0.5 then
                    found.summoned = true
                end
            end
        end
    end

    if sawStale and sender then
        self:Sync_SendTo("CLEARALL", nil, sender)
    end

    if self.TrySummonNext then
        self:TrySummonNext()
    end
end

--------------------------------------------------------------------------
-- Incoming message handling
--------------------------------------------------------------------------

function DHAir:Sync_OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX then return end

    local myName = UnitName("player")
    local senderShort = self:NormalizeName(sender)
    if senderShort == myName then return end -- ignore any echo of our own messages

    local peerEntry = self.peers[senderShort]
    if not peerEntry then
        peerEntry = {}
        self.peers[senderShort] = peerEntry
    end
    peerEntry.lastSeen = GetTime()

    local msgType, rest = message:match("^([^|]+)|?(.*)$")
    if not msgType then return end

    if msgType == "HELLO" then
        -- Presence already recorded above. rest (added 2026-08-15) is the
        -- sender's DHAir.VERSION, if they're on a build new enough to send
        -- one - an old client's HELLO has no payload, so rest is just "".
        if rest ~= "" then
            peerEntry.version = rest
        end

    elseif msgType == "WBM" then
        -- Self-only presence signal (DH-Tools-WorldBuffRequest-Design.md
        -- D1) - sender is trusted implicitly via senderShort, same as
        -- HELLO. "1" starts/refreshes tracking (keeping the original
        -- firstSeen so re-broadcasts don't reset the D3 first-come
        -- ordering); "0" (or anything else) clears it immediately.
        if rest == "1" then
            local existing = self.peerWBM[senderShort]
            self.peerWBM[senderShort] = {
                firstSeen = (existing and existing.firstSeen) or GetTime(),
                lastSeen = GetTime(),
            }
        else
            self.peerWBM[senderShort] = nil
        end

    elseif msgType == "ADD" then
        -- 2026-09-17 (Loopi): payload is now "Name|Role" (Option 1 fix) -
        -- role rides along from the sender instead of being re-derived
        -- from this client's own (possibly incomplete) local roster,
        -- which was letting a queue entry silently lose its D5
        -- summoner/clicker protection on some clients. role may be ""
        -- (sender has no role) and the "|" is omitted entirely by a
        -- pre-fix sender, hence the fallback below.
        local name, role = rest:match("^(.-)|(.*)$")
        if not name then name = rest end
        if role == "" then role = nil end
        if name ~= "" then
            -- 2026-09-15: the MIN_QUEUE_VERSION floor that used to gate
            -- this receive-side (see this file's header comment and the
            -- removal note near where the constant used to live) is gone -
            -- every ADD broadcast is applied unconditionally now.
            self:QueueAdd(name, nil, role) -- QueueAdd itself doesn't re-broadcast, so no echo loop
        end

    elseif msgType == "CLAIM" then
        local name, claimer = rest:match("^(.-)|(.+)$")
        if name and claimer then
            self:StoreClaim(name, claimer)
            -- If we were mid-claim OR already sitting "ready" (picked and
            -- claimed, awaiting a Confirm click) on the same player and
            -- just lost it - either the deterministic tie-break during
            -- negotiation, or our own claim went stale and someone else
            -- picked it up while we sat unconfirmed - back off immediately
            -- rather than leaving a dead pick on screen. 2026-08-18
            -- (Loopi-reported): the "ready" half of this used to be
            -- missing entirely - see AbandonPendingPick's comment
            -- (Summon.lua) for the full story.
            local claim = self:GetClaim(name)
            if claim and claim.by ~= myName and self.AbandonPendingPick then
                self:AbandonPendingPick(name, "timed out and was picked up by " .. self:NormalizeName(claimer))
            end
        end

    elseif msgType == "RELEASE" then
        local name = rest
        if name ~= "" then
            self:ClearClaim(name)
            self:TrySummonNext()
        end

    elseif msgType == "SUMMONED" then
        local name = rest
        if name ~= "" then
            self:ClearClaim(name)
            self:QueueMarkSummoned(name)
            self:TrySummonNext()
        end

    elseif msgType == "RESET" then
        self:QueueReset()

    elseif msgType == "REMOVE" then
        local name = rest
        if name ~= "" then
            local isSelfRemoval = self:NormalizeName(name) == senderShort
            if isSelfRemoval or self:UnitHasAuthority(sender) then
                if self:QueueRemove(name) then
                    -- 2026-08-18 (Loopi-reported): removal used to only
                    -- touch the shared queue LIST, leaving a claim (and,
                    -- if we held it ourselves, a live pick) on a player
                    -- who was no longer even in the queue - see
                    -- AbandonPendingPick's comment (Summon.lua).
                    if self.ClearClaim then self:ClearClaim(name) end
                    if self.AbandonPendingPick then
                        self:AbandonPendingPick(name, "was removed from the queue")
                    end
                end
            end
            -- else: sender isn't leader/assist and isn't removing themselves -
            -- silently ignored rather than trusting a self-asserted claim.
        end

    elseif msgType == "CLEARALL" then
        -- 2026-08-18 (Loopi): "Clear Queue" is now the softer, filtered
        -- clear - see Queue.lua's QueueResetNonRoster/RequestClearAll.
        if self:UnitHasAuthority(sender) then
            self:QueueResetNonRoster()
        end

    elseif msgType == "CLEARROSTER" then
        -- 2026-08-18 (Loopi): "Clear Roster/Queue" now also fully wipes
        -- the queue (not just role registrations) - see Roster.lua's
        -- RequestClearRoster for why.
        if self:UnitHasAuthority(sender) then
            self:ClearRoster()
            self:QueueReset()
        end

    elseif msgType == "SETDEST" then
        local name, destId = rest:match("^(.-)|(.*)$")
        if name then
            -- Self-service only - no leader/assist path lets you set
            -- someone else's destination remotely, unlike REMOVE.
            if self:NormalizeName(name) == senderShort then
                self:ApplyDestination(name, destId)
                -- Same reasoning as SetMyDestination's own TrySummonNext
                -- call: OUR OWN auto-summon loop might be idle, waiting on
                -- exactly this player to declare a destination.
                if self.TrySummonNext then
                    self:TrySummonNext()
                end
            end
        end

    elseif msgType == "SETDESTFOR" then
        -- M3 (QueueFeedback D3): a leader/assist setting SOMEONE ELSE's
        -- destination. Verified receive-side against OUR OWN view of the
        -- raid roster, exactly like REMOVE/CLEARALL/SETPHRASE - the
        -- message's claimed sender authority is never trusted. Note the
        -- inverted shape versus SETDEST directly above: there we require
        -- name == sender and no permission; here we require permission and
        -- deliberately do NOT require name ~= sender (a leader correcting
        -- their own entry through this path is harmless and still passes
        -- the authority check).
        local name, destId = rest:match("^(.-)|(.*)$")
        if name and name ~= "" and self:UnitHasAuthority(sender) then
            self:ApplyDestination(name, destId)
            -- No whisper from here: the SETTER already sent the affected
            -- player one plain-chat whisper (Queue.lua's
            -- RequestSetDestinationFor). If every receiving client also
            -- whispered, a raid with N Warlocks running DH-Air would spam
            -- that player N times for one action.
            if self.TrySummonNext then
                self:TrySummonNext()
            end
        end

    elseif msgType == "SETPHRASE" then
        local newPhrase = rest
        if newPhrase ~= "" and self:UnitHasAuthority(sender) then
            self.db.codePhrase = newPhrase
        end

    elseif msgType == "REGISTER" or msgType == "UNREGISTER" then
        if self.Roster_OnMessage then
            self:Roster_OnMessage(msgType, rest)
        end

    elseif msgType == "SYNCREQ" then
        self:Sync_SendState(sender)

    elseif msgType == "SYNCDATA" then
        local header, data = rest:match("^(%d+/%d+)|(.*)$")
        if not header then return end
        local i, total = header:match("^(%d+)/(%d+)$")
        i, total = tonumber(i), tonumber(total)
        if not i or not total then return end

        self.syncBuffers[sender] = self.syncBuffers[sender] or { total = total, chunks = {} }
        local buf = self.syncBuffers[sender]
        buf.chunks[i] = data

        local received = 0
        for _ in pairs(buf.chunks) do received = received + 1 end
        if received >= buf.total then
            local fullData = table.concat(buf.chunks, ",")
            self.syncBuffers[sender] = nil
            self:Sync_MergeEntries(DecodeQueueChunk(fullData), sender)
        end

    elseif msgType == "DESTLIST" then
        -- Gated broadcast - a fresh claim of new state, verified against
        -- the RECEIVER's own roster once fully reassembled, same idiom as
        -- REMOVE/CLEARALL/SETPHRASE. See this file's header comment for
        -- why this is a separate, gated message from DESTSYNCDATA below.
        -- M3 (2026-08-03): swapped from the interim UnitHasAuthority
        -- (leader/assist) gate to the real guild-officer rank check,
        -- IsGuildOfficer - see Core.lua and DH-Air-Destinations-Design.md §3.
        local header, data = rest:match("^(%d+/%d+)|(.*)$")
        if not header then return end
        local i, total = header:match("^(%d+)/(%d+)$")
        i, total = tonumber(i), tonumber(total)
        if not i or not total then return end

        self.destListBuffers[sender] = self.destListBuffers[sender] or { total = total, chunks = {} }
        local buf = self.destListBuffers[sender]
        buf.chunks[i] = data

        local received = 0
        for _ in pairs(buf.chunks) do received = received + 1 end
        if received >= buf.total then
            local fullData = table.concat(buf.chunks, ",")
            self.destListBuffers[sender] = nil
            if self:IsGuildOfficer(sender) then
                self.db.destinations = DecodeDestinationsChunk(fullData)
            end
            -- else: sender isn't verified as a guild officer - silently
            -- ignored, never trusting a self-asserted claim.
        end

    elseif msgType == "DESTSYNCDATA" then
        -- Ungated resync reply - see this file's header comment for why.
        local header, data = rest:match("^(%d+/%d+)|(.*)$")
        if not header then return end
        local i, total = header:match("^(%d+)/(%d+)$")
        i, total = tonumber(i), tonumber(total)
        if not i or not total then return end

        self.destSyncDataBuffers[sender] = self.destSyncDataBuffers[sender] or { total = total, chunks = {} }
        local buf = self.destSyncDataBuffers[sender]
        buf.chunks[i] = data

        local received = 0
        for _ in pairs(buf.chunks) do received = received + 1 end
        if received >= buf.total then
            local fullData = table.concat(buf.chunks, ",")
            self.destSyncDataBuffers[sender] = nil
            self.db.destinations = DecodeDestinationsChunk(fullData)
        end
    end
end

--------------------------------------------------------------------------
-- Visibility helpers
--------------------------------------------------------------------------

function DHAir:PrintPeers()
    local now = GetTime()
    local any = false
    self:Print("Other DH-Air Warlocks seen in the last 5 minutes:")
    for name, peer in pairs(self.peers) do
        if now - peer.lastSeen < HELLO_INTERVAL_SECONDS then
            -- 2026-09-15: no longer flags anyone "OUTDATED" - that used to
            -- mean "below MIN_QUEUE_VERSION, can't add to the shared
            -- queue", a floor removed this session (see this file's
            -- header comment). Version is purely informational now.
            local versionNote = peer.version and (" (v" .. peer.version .. ")") or " (version unknown)"
            self:Print("  - " .. name .. versionNote)
            any = true
        end
    end
    if not any then
        self:Print("  (none)")
    end
end
