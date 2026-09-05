-- DH-Tools: Modules\DHBavin\Sync.lua
-- Milestone 2 (see this folder's DH-Bavin-Design.md): full guild sync
-- protocol for recipient/editors/priority-list. Ports DH-Quests' own
-- Sync.lua pattern almost directly (prefix registration, delta
-- broadcasts, a SYNCREQ/SYNCDATA full-state handshake for late joiners,
-- manual chunking) - see that file for the precedent this mirrors.
-- Replaces Core.lua's Milestone 1 minimal broadcast-only RECIPIENT/
-- EDITORS path (Core.lua's SetRecipient/SetEditors now call into this
-- file's Sync_BroadcastRecipient/Sync_BroadcastEditors instead of
-- talking to C_ChatInfo directly).
--
-- PROTOCOL (all messages are "TYPE|payload", sent via
-- C_ChatInfo.SendAddonMessage to GUILD unless noted; nothing is sent if
-- the player isn't in a guild):
--
--   RECIPIENT|charName      - sender (must be guild leader, verified by
--                             the RECEIVER's own roster cache) is setting
--                             the current recipient; empty charName means
--                             "cleared"
--   EDITORS|n1,n2,...       - sender (must be guild leader) is replacing
--                             the full editor list (comma-joined; an
--                             empty string means "no editors")
--   ITEM|name|itemId|itemLink
--                           - sender (must currently be the recipient or
--                             an editor, verified by the receiver's own
--                             synced copy of recipient/editors) added or
--                             updated this priority-list entry. Keyed by
--                             item NAME, not itemID (2026-08-04 revision -
--                             see this file's priorityList comment below
--                             for why, and knowledge\k-0005 for the
--                             precedent this follows). itemId is
--                             optional metadata (may be empty); itemLink
--                             is optional display metadata and, being
--                             the last field, may itself contain "|".
--   ITEMGONE|name           - sender (same authorization) removed this
--                             entry, by name
--   PTSSET|name|points|itemId|editedAt|detail
--                           - sender (must currently be the recipient or
--                             an editor, same verification as ITEM) is
--                             setting a live Bavin Points override for
--                             `name`, or reverting it back to
--                             ItemPoints.lua's shipped baseline if
--                             `points` is empty (itemId then ignored -
--                             see Core.lua's RevertItemPoints). Applied
--                             only if `editedAt` is newer than whatever
--                             the receiver already has recorded for this
--                             name - last-writer-wins per name, same
--                             idiom DH-Air's SETDEST uses (see Core.lua's
--                             ApplyItemPointsLocal). `detail` is the
--                             editable tooltip wording (2026-08-06, may
--                             be empty) and is ESCAPED - it's the one
--                             field on this wire that can legitimately
--                             contain "|" or ";", see EscapeDetail.
--   PTSSYNCREQ|myVersion    - "send me any Bavin Points overrides edited
--                             after myVersion" (unconditional - see
--                             GATING below). myVersion is the requester's
--                             own ns.GetItemPointsVersion() (0 if it has
--                             none yet) - NOT the same thing as SYNCREQ's
--                             full-state request, and deliberately a
--                             separate message: the points table is far
--                             too large to ever send in full over this
--                             channel (see ItemPoints.lua's header), so
--                             this only ever asks for/answers with
--                             deltas.
--   PTSSYNCDATA|i/total|chunk
--                           - chunked reply to a PTSSYNCREQ, WHISPERed
--                             directly back like SYNCDATA. Reassembled
--                             chunks decode to ";"-joined
--                             "name|points|itemId|editedAt|detail"
--                             entries - safe to use both "|" and ";" as
--                             delimiters here (unlike SYNCDATA's
--                             itemLink-based payload) since plain item
--                             display names never contain either
--                             character; only itemLINKS (full of
--                             color-code/hyperlink escapes) do - and
--                             `detail`, which is free prose and is
--                             therefore escaped rather than sent raw
--                             (see EscapeDetail).
--   SYNCREQ                 - "I just joined/reloaded, please send me
--                             your current state" (unconditional - see
--                             GATING below)
--   SYNCDATA|i/total|chunk  - chunked full-state reply to a SYNCREQ,
--                             WHISPERed directly back to the requester
--                             (not broadcast). Reassembled chunks decode
--                             to "recipient|editors|items", where items
--                             is semicolon-joined "name|itemId|itemLink"
--                             entries. recipient/editors can never
--                             contain "|" (character names can't), and
--                             item display names never contain "|" or
--                             ";" either (same assumption PTSSYNCDATA's
--                             entries already rely on) - only itemLink
--                             strings do (color codes/hyperlink escapes),
--                             which is why itemLink is always the LAST
--                             field in any entry that carries one.
--
-- GATING: SYNCREQ and PTSSYNCREQ are both unconditional once in a guild
-- (neither reveals anything about the requester beyond, for PTSSYNCREQ,
-- a version number). A SYNCDATA/PTSSYNCDATA reply is answered by ANY
-- client, not just the recipient/editors/guild leader - it's relaying
-- already-established state, not asserting new authority, so it isn't
-- re-gated by IsGuildLeader/CanEditList on receipt (same "answering is
-- never gated" idiom DH-Quests' own SYNCREQ handling uses) - this is
-- also required by the Design doc: a late joiner must learn the current
-- recipient "even if the guild leader is offline right now... from
-- whoever answers the handshake." Only actual STATE CHANGES
-- (RECIPIENT/EDITORS/ITEM/ITEMGONE/PTSSET) are re-verified against the
-- receiver's own local state before being applied - never a
-- self-asserted claim in the message itself. This is guild-social-trust
-- security, not cryptographic (same accepted limitation as DH-Air's own
-- permission model - stated plainly there and in PROFILE.md).

local DHTools = DHTools
local ns = DHTools.Bavin

-- STANDING RULE (2026-08-05, see knowledge\k-0009): bump this suffix
-- (V1 -> V2 -> ...) any time a change to this file's wire format (message
-- shape, field count/order, or meaning) is not purely additive/backward-
-- compatible. WoW addon messages are only received by clients registered
-- on the exact same prefix, so a bump cleanly partitions old/new clients
-- instead of letting one silently corrupt the other's data with a
-- mismatched decode - which is exactly what happened to DH-Air's
-- destinations sync tonight (continent field added to the data model but
-- not this kind of file's wire format). DH-Air's and DH-Quests' Sync.lua
-- carry the identical PREFIX pattern and the identical rule.
-- 2026-08-05: bumped V1 -> V2 - SYNCDATA gained a 4th field
-- (priorityListUpdatedAt) ahead of the items list, a non-additive shape
-- change (old V1 clients would misparse it), and the field itself is
-- part of a real behavior fix - see k-0012. Every DH-Tools user needs
-- this build before Bavin sync (recipient/editors/points/priority list -
-- all of it, since they share one PREFIX) works between their clients
-- again; V1 and V2 clients simply won't exchange any Bavin messages
-- until everyone's updated, same tradeoff k-0009 already accepted.
-- 2026-08-06: bumped V2 -> V3 - SYNCDATA gained a 5th field
-- (recipientEditorsUpdatedAt) ahead of priorityListUpdatedAt, same kind
-- of non-additive shape change and the same reason: recipient/editors
-- had NO version stamp at all before this, so a SYNCDATA reply from
-- whoever answered first always blindly overwrote local state - even a
-- freshly-set, genuinely newer local recipient/editors list could be
-- clobbered by a stale peer's answer. See k-0019.
-- 2026-08-06 (later): bumped V3 -> V4 - PTSSET and PTSSYNCDATA's entries
-- both gained a 5th field, `detail` (the editable tooltip wording). A V3
-- client's anchored 4-field pattern simply fails to match a 5-field
-- entry, so it would silently DROP every points edit rather than
-- misparse one - quieter than V2's failure mode but still a total
-- exchange break, which is exactly what the standing rule above exists
-- to partition cleanly.
local PREFIX = "DHBavinV4"
-- Assumes no single "name|itemId|itemLink" entry ever exceeds this length
-- once chunked into a SYNCDATA reply - real item hyperlinks run roughly
-- 60-160 characters, item names are short, comfortably under this. See
-- ChunkEncoded's comment (ported from DH-Quests, including its
-- 2026-07-27 off-by-one fix) for what happens if that assumption is ever
-- violated.
local MAX_CHUNK_CHARS = 200

-- ns.priorityList[name] = { name=, itemId=, itemLink=, addedBy=, addedAt= }.
-- Keyed by item NAME, not itemID (2026-08-04 revision to the original
-- Design doc, which had called itemID "the only reliable match key"
-- before Bavin Points existed) - Loopi flagged that this should match
-- Bavin Points/Tooltip.lua for consistency, and it also avoids
-- reintroducing the exact bug knowledge\k-0005 already fixed for
-- ItemPoints.lua: one itemID can cover many differently-valued "of the
-- X" random-suffix variants, which an itemID key can't distinguish.
-- itemId is kept as metadata (from ns.ITEM_POINTS when added via the
-- PriorityEditor search, or parsed straight from a shift-clicked link
-- via /dhb additem) - not the lookup key. Milestone 3 formally owns
-- "local store & event wiring" for this, but the sync protocol needs
-- somewhere to decode incoming ITEM/SYNCDATA entries into now - same
-- precedent as DH-Quests' Sync.lua populating ns.peers well ahead of
-- that module's own M5 display layer. addedBy/addedAt are LOCAL
-- bookkeeping only (itemLink is cached "so the editor UI can show icon/
-- name/quality without a live tooltip query", per Design doc) - they
-- are NOT part of the wire payload, so a receiving client's copy of
-- addedBy/addedAt reflects ITS OWN receipt, not necessarily the
-- original adder's.
--
-- 2026-08-05: this used to be the ONLY place ns.priorityList was ever
-- initialized, and it was pure runtime state with no SavedVariables
-- backing at all. Core.lua's InitDB() (which runs slightly later, at
-- OnEnable/PLAYER_LOGIN - see that function's own comment) now takes
-- over and repoints ns.priorityList at the persistent ns.db.priorityList
-- table instead. This line stays only as a defensive fallback so nothing
-- errors on a nil ns.priorityList in the brief window between file load
-- and InitDB() actually running.
ns.priorityList = ns.priorityList or {}
ns.syncBuffers = ns.syncBuffers or {} -- sender -> { total = n, chunks = {} }
ns.ptsSyncBuffers = ns.ptsSyncBuffers or {} -- separate reassembly buffers for PTSSYNCDATA

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

-- Guild-only by design, same as DH-Quests (no RAID/PARTY fallback).
function ns.Sync_Channel()
    if IsInGuild and IsInGuild() then return "GUILD" end
    return nil
end

function ns.Sync_IsActive()
    return ns.Sync_Channel() ~= nil
end

function ns.Sync_Send(msgType, payload)
    local channel = ns.Sync_Channel()
    if not channel then return end
    local text = payload and (msgType .. "|" .. payload) or msgType
    AddonSendMessage(text, channel)
end

function ns.Sync_SendTo(msgType, payload, targetName)
    local text = payload and (msgType .. "|" .. payload) or msgType
    AddonSendMessage(text, "WHISPER", targetName)
end

-- Called from Core.lua on PLAYER_LOGIN. Registers the prefix and asks
-- the guild for current state - SYNCREQ is unconditional (see GATING
-- above), so this fires regardless of the local player's own role.
function ns.Sync_Init()
    RegisterPrefix()
    if ns.Sync_IsActive() then
        ns.Sync_Send("SYNCREQ")
        -- Separate from SYNCREQ above - PTSSYNCREQ only ever asks for/
        -- answers with deltas newer than a version, never the full Bavin
        -- Points table (see this file's header PROTOCOL note).
        local version = ns.GetItemPointsVersion and ns.GetItemPointsVersion() or 0
        ns.Sync_Send("PTSSYNCREQ", tostring(version))
    end
end

--------------------------------------------------------------------------
-- Outbound: RECIPIENT / EDITORS delta broadcasts
--------------------------------------------------------------------------
-- Called from Core.lua's SetRecipient/SetEditors AFTER the guild-leader
-- gate has already passed and local state is already updated - these
-- just announce the change.

function ns.Sync_BroadcastRecipient(name)
    ns.Sync_Send("RECIPIENT", name or "")
end

function ns.Sync_BroadcastEditors(list)
    ns.Sync_Send("EDITORS", table.concat(list or {}, ","))
end

--------------------------------------------------------------------------
-- Priority list: public API + delta broadcasts
--------------------------------------------------------------------------
-- Public entry points a future Milestone 4 editor UI (and today's /dhb
-- additem/removeitem test aid in Core.lua) call directly - gated by
-- CanEditList locally before touching anything, mirroring SetRecipient/
-- SetEditors's own "check first, then mutate, then broadcast" shape.

function ns.AddItem(name, itemId, itemLink)
    if not name or name == "" then return false end
    if not ns.CanEditListLocal() then return false end
    ns.priorityList[name] = {
        name = name,
        itemId = itemId,
        itemLink = itemLink,
        addedBy = UnitName("player"),
        addedAt = GetTime(),
    }
    -- k-0012: stamp the LIST's own version (wall-clock time(), comparable
    -- across logins - not GetTime()) any time it changes locally, so a
    -- later SYNCDATA reply can tell whether OUR list or the replying
    -- peer's is actually newer instead of blindly trusting whoever
    -- answers first.
    ns.db.priorityListUpdatedAt = time()
    ns.Sync_BroadcastItem(name, itemId, itemLink)
    return true
end

function ns.RemoveItem(name)
    if not name or name == "" then return false end
    if not ns.CanEditListLocal() then return false end
    ns.priorityList[name] = nil
    ns.db.priorityListUpdatedAt = time() -- see AddItem's k-0012 comment
    ns.Sync_BroadcastItemGone(name)
    return true
end

function ns.Sync_BroadcastItem(name, itemId, itemLink)
    ns.Sync_Send("ITEM", name .. "|" .. (itemId and tostring(itemId) or "") .. "|" .. (itemLink or ""))
end

function ns.Sync_BroadcastItemGone(name)
    ns.Sync_Send("ITEMGONE", name)
end

--------------------------------------------------------------------------
-- Item points: delta broadcast + version catch-up
--------------------------------------------------------------------------
-- DETAIL ESCAPING (2026-08-06). Every other field on this wire is a
-- character name, an item display name, or a number - none of which can
-- contain "|" or ";", which is exactly why this file was free to use
-- both as delimiters (see the header). `detail` breaks that assumption
-- outright: it's free spreadsheet prose, and the stock wording is
-- literally "<name>: <points> pts to Bavin; <price/source>" - a
-- SEMICOLON in the middle of nearly every entry. Left raw, one detail
-- string would shatter a PTSSYNCDATA payload into bogus extra entries.
--
-- So detail (and only detail) is escaped on the way out and unescaped on
-- the way in: backslash doubles, "|" -> "\p", ";" -> "\s". Unescaping is
-- a SINGLE pass over "\<char>" pairs rather than three sequential gsubs,
-- because sequential replacement would corrupt a literal backslash
-- followed by p or s (an escaped "\\" would be un-escaped first and its
-- trailing "p" then read as a pipe marker).
local function EscapeDetail(s)
    if not s or s == "" then return "" end
    s = s:gsub("\\", "\\\\")
    s = s:gsub("|", "\\p")
    s = s:gsub(";", "\\s")
    return s
end

local function UnescapeDetail(s)
    if not s or s == "" then return nil end
    s = s:gsub("\\(.)", function(c)
        if c == "p" then return "|" end
        if c == "s" then return ";" end
        return c -- covers "\\\\" -> "\\", and passes anything unexpected through
    end)
    return s
end

-- Called from Core.lua's SetItemPoints AFTER the CanEditList gate has
-- already passed and local state is already updated - this just
-- announces the change. points/itemId nil means "reverted to baseline".
-- detail (tooltip wording, may be nil) is escaped and goes LAST.
function ns.Sync_BroadcastItemPoints(name, points, itemId, editedAt, detail)
    local payload = (name or "") .. "|" .. (points ~= nil and tostring(points) or "")
        .. "|" .. (itemId ~= nil and tostring(itemId) or "") .. "|" .. tostring(editedAt)
        .. "|" .. EscapeDetail(detail)
    ns.Sync_Send("PTSSET", payload)
end

-- Encodes every local override with editedAt > sinceVersion as
-- ";"-joined "name|points|itemId|editedAt|detail" entries. Item display
-- names and numbers can't contain "|" or ";", so they go raw; detail CAN
-- and is escaped (see EscapeDetail above), which is what keeps both
-- delimiters usable here at all.
local function EncodeItemPointsSince(sinceVersion)
    local parts = {}
    for name, o in pairs(ns.db.itemPointsOverrides or {}) do
        if (o.editedAt or 0) > sinceVersion then
            table.insert(parts, name .. "|" .. (o.points ~= nil and tostring(o.points) or "")
                .. "|" .. (o.itemId ~= nil and tostring(o.itemId) or "") .. "|" .. tostring(o.editedAt)
                .. "|" .. EscapeDetail(o.detail))
        end
    end
    return table.concat(parts, ";")
end

-- Splits a reassembled points-delta string back into
-- { {name=, points=, itemId=, editedAt=, detail=}, ... }.
local function DecodeItemPointsEntries(data)
    local entries = {}
    for entry in data:gmatch("[^;]+") do
        local name, pointsStr, itemIdStr, editedAtStr, detailStr =
            entry:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
        if name and name ~= "" then
            table.insert(entries, {
                name = name,
                points = (pointsStr ~= "" and tonumber(pointsStr)) or nil,
                itemId = (itemIdStr ~= "" and tonumber(itemIdStr)) or nil,
                editedAt = tonumber(editedAtStr) or 0,
                detail = UnescapeDetail(detailStr),
            })
        end
    end
    return entries
end

--------------------------------------------------------------------------
-- Full-state encode/decode (for SYNCREQ/SYNCDATA)
--------------------------------------------------------------------------

local function EncodeItems()
    local parts = {}
    for name, entry in pairs(ns.priorityList) do
        table.insert(parts, name .. "|" .. (entry.itemId and tostring(entry.itemId) or "") .. "|" .. (entry.itemLink or ""))
    end
    return table.concat(parts, ";")
end

-- Splits a reassembled items-string back into
-- { {name=, itemId=, itemLink=}, ... }. itemLink is always the last
-- field of an entry (see file header) since it's the only piece that can
-- contain "|"; name/itemId never do.
local function DecodeItemEntries(data)
    local entries = {}
    for entry in data:gmatch("[^;]+") do
        local name, itemIdStr, itemLink = entry:match("^([^|]*)|([^|]*)|(.*)$")
        if name and name ~= "" then
            table.insert(entries, {
                name = name,
                itemId = (itemIdStr ~= "" and tonumber(itemIdStr)) or nil,
                itemLink = itemLink,
            })
        end
    end
    return entries
end

-- Splits an already-encoded string into <=MAX_CHUNK_CHARS pieces,
-- preferring to cut right after a ";" entry boundary where one exists in
-- the window (purely cosmetic - keeps individual item entries whole
-- within a chunk for readability/debugging).
--
-- 2026-07-29 rewrite: the original version (ported verbatim from
-- DH-Quests' ChunkEncoded) DROPPED the separator character at each cut
-- point and relied on the receiver blindly re-inserting a ";" between
-- every chunk on reassembly (table.concat(chunks, ";")). That's only
-- correct if EVERY cut in the original string really was a ";" - true
-- for DH-Quests, where the whole encoded payload is nothing but
-- ";"-joined entries. DH-Bavin's payload is NOT that: it's
-- "recipient|editorsCSV|itemsList", and only the last part uses ";" -
-- the recipient/editors header has none. Any chunk boundary landing in
-- that header (guaranteed for most payloads, since the header comes
-- first) took the "no separator found" branch, which did a bare hard
-- cut - and reassembly still inserted a fabricated ";" there anyway,
-- corrupting the recipient|editors|items split on the receiving end.
-- Fixed by never dropping a character in the first place: each chunk is
-- an exact substring, so reassembly is a plain concat with no separator
-- and is correct regardless of where any cut lands.
local function ChunkEncoded(encoded)
    local chunks = {}
    local remaining = encoded
    while #remaining > 0 do
        if #remaining <= MAX_CHUNK_CHARS then
            table.insert(chunks, remaining)
            remaining = ""
        else
            local window = remaining:sub(1, MAX_CHUNK_CHARS)
            local sepPos = window:find(";[^;]*$")
            local cutAt = sepPos or MAX_CHUNK_CHARS
            table.insert(chunks, remaining:sub(1, cutAt))
            remaining = remaining:sub(cutAt + 1)
        end
    end
    return chunks
end

-- Replies to a SYNCREQ from `targetName` with our current full state
-- (recipient, editors, priority list), chunked and whispered directly
-- back to avoid flooding guild chat. Answered unconditionally - see the
-- file header's GATING note on why this isn't restricted to the
-- recipient/editors/guild leader.
function ns.Sync_SendState(targetName)
    local recipient = (ns.db and ns.db.recipient) or ""
    local editors = table.concat((ns.db and ns.db.editors) or {}, ",")
    local recipientEditorsUpdatedAt = (ns.db and ns.db.recipientEditorsUpdatedAt) or 0
    local priorityListUpdatedAt = (ns.db and ns.db.priorityListUpdatedAt) or 0
    local items = EncodeItems()
    -- recipient/editors/recipientEditorsUpdatedAt/priorityListUpdatedAt
    -- can never contain "|" (character names/CSV can't, a number
    -- can't), so using it as the separator here - distinct from items'
    -- own ";" separator - is safe. Both *UpdatedAt fields (k-0012,
    -- k-0019) sit right before items, the one field that DOES contain
    -- "|", so it's never ambiguous which digits belong to which field.
    -- See file header for why this ordering matters.
    local payload = recipient .. "|" .. editors .. "|" .. recipientEditorsUpdatedAt
        .. "|" .. priorityListUpdatedAt .. "|" .. items

    local chunks = ChunkEncoded(payload)
    local total = #chunks
    for i, chunk in ipairs(chunks) do
        ns.Sync_SendTo("SYNCDATA", i .. "/" .. total .. "|" .. chunk, targetName)
    end
end

-- Replies to a PTSSYNCREQ from `targetName` with only the Bavin Points
-- overrides this client knows about that are newer than the requester's
-- own version - never the whole table (see ItemPoints.lua's header for
-- why the full ~7000-entry baseline can never go over this channel).
-- Answered unconditionally, like Sync_SendState above - see file
-- header's GATING note. No-ops if there's nothing newer to offer.
function ns.Sync_SendItemPointsState(targetName, sinceVersion)
    local encoded = EncodeItemPointsSince(sinceVersion or 0)
    if encoded == "" then return end
    local chunks = ChunkEncoded(encoded)
    local total = #chunks
    for i, chunk in ipairs(chunks) do
        ns.Sync_SendTo("PTSSYNCDATA", i .. "/" .. total .. "|" .. chunk, targetName)
    end
end

--------------------------------------------------------------------------
-- Incoming message handling
--------------------------------------------------------------------------

-- Registered from Core.lua's CHAT_MSG_ADDON handler.
function ns.Sync_OnAddonMessage(prefix, message, _channel, sender)
    if prefix ~= PREFIX then return end
    if not ns.db then return end

    local myName = UnitName("player")
    local senderShort = ns.NormalizeName(sender)
    if senderShort == myName then return end -- ignore our own echo

    local msgType, rest = message:match("^([^|]+)|?(.*)$")
    if not msgType then return end

    -- 2026-08-05 (Loopi): RECIPIENT and EDITORS are now separately
    -- gated (see Core.lua's Permission model section) - RECIPIENT trusts
    -- only Bavin/Loopidot by name, EDITORS trusts rank<=3 officers or
    -- Loopidot. No more TESTING_ALLOW_ANYONE_TO_MANAGE bypass (removed).

    if msgType == "RECIPIENT" then
        if not ns.CanSetRecipientName(senderShort) then return end
        ns.db.recipient = (rest ~= "" and rest) or nil
        ns.db.recipientEditorsUpdatedAt = time() -- k-0019: a verified live change

    elseif msgType == "EDITORS" then
        if not ns.CanSetEditorsName(senderShort) then return end
        local list = {}
        if rest ~= "" then
            for name in rest:gmatch("[^,]+") do
                table.insert(list, name)
            end
        end
        ns.db.editors = list
        ns.db.recipientEditorsUpdatedAt = time() -- k-0019: a verified live change

    elseif msgType == "ITEM" then
        if not ns.CanEditList(senderShort) then return end
        local name, itemIdStr, itemLink = rest:match("^([^|]*)|([^|]*)|(.*)$")
        if name and name ~= "" then
            ns.priorityList[name] = {
                name = name,
                itemId = (itemIdStr ~= "" and tonumber(itemIdStr)) or nil,
                itemLink = itemLink,
                addedBy = senderShort,
                addedAt = GetTime(),
            }
            -- k-0012: a verified live edit from someone else is just as
            -- much a real change to OUR list as a local one - keep our
            -- own version stamp current so a later SYNCDATA exchange
            -- doesn't think our list is older than it actually is.
            ns.db.priorityListUpdatedAt = time()
        end

    elseif msgType == "ITEMGONE" then
        if not ns.CanEditList(senderShort) then return end
        if rest ~= "" then
            ns.priorityList[rest] = nil
            ns.db.priorityListUpdatedAt = time() -- see ITEM branch above
        end

    elseif msgType == "PTSSET" then
        if not ns.CanEditList(senderShort) then return end
        local name, pointsStr, itemIdStr, editedAtStr, detailStr =
            rest:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
        if name and name ~= "" then
            local points = (pointsStr ~= "" and tonumber(pointsStr)) or nil
            local itemId = (itemIdStr ~= "" and tonumber(itemIdStr)) or nil
            local editedAt = tonumber(editedAtStr) or 0
            ns.ApplyItemPointsLocal(name, points, itemId, editedAt, UnescapeDetail(detailStr))
        end

    elseif msgType == "PTSSYNCREQ" then
        ns.Sync_SendItemPointsState(sender, tonumber(rest) or 0)

    elseif msgType == "PTSSYNCDATA" then
        local header, data = rest:match("^(%d+/%d+)|(.*)$")
        if not header then return end
        local i, total = header:match("^(%d+)/(%d+)$")
        i, total = tonumber(i), tonumber(total)
        if not i or not total then return end

        ns.ptsSyncBuffers[sender] = ns.ptsSyncBuffers[sender] or { total = total, chunks = {} }
        local buf = ns.ptsSyncBuffers[sender]
        buf.chunks[i] = data

        local received = 0
        for _ in pairs(buf.chunks) do received = received + 1 end
        if received >= buf.total then
            -- Plain concat, no inserted separator - same reasoning as
            -- the SYNCDATA branch above (see ChunkEncoded's comment).
            local fullData = table.concat(buf.chunks)
            ns.ptsSyncBuffers[sender] = nil

            for _, entry in ipairs(DecodeItemPointsEntries(fullData)) do
                ns.ApplyItemPointsLocal(entry.name, entry.points, entry.itemId, entry.editedAt, entry.detail)
            end
        end

    elseif msgType == "SYNCREQ" then
        ns.Sync_SendState(sender)

    elseif msgType == "SYNCDATA" then
        local header, data = rest:match("^(%d+/%d+)|(.*)$")
        if not header then return end
        local i, total = header:match("^(%d+)/(%d+)$")
        i, total = tonumber(i), tonumber(total)
        if not i or not total then return end

        ns.syncBuffers[sender] = ns.syncBuffers[sender] or { total = total, chunks = {} }
        local buf = ns.syncBuffers[sender]
        buf.chunks[i] = data

        local received = 0
        for _ in pairs(buf.chunks) do received = received + 1 end
        if received >= buf.total then
            -- Plain concat, no inserted separator - each chunk is an
            -- exact substring (see ChunkEncoded's 2026-07-29 comment),
            -- so this is the exact original payload regardless of where
            -- any cut landed.
            local fullData = table.concat(buf.chunks)
            ns.syncBuffers[sender] = nil

            local recipient, editorsStr, recipientEditorsUpdatedAtStr, updatedAtStr, itemsEncoded =
                fullData:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
            if recipient then
                -- k-0019 (2026-08-06): recipient/editors used to be
                -- replaced UNCONDITIONALLY here - relayed state, not a
                -- fresh claim, so not re-gated by IsGuildLeader (see file
                -- header's GATING note), but also with zero regard for
                -- which side's copy was actually current. Same class of
                -- bug k-0012 already fixed for the priority list below:
                -- whoever answered first won, even with a stale or
                -- empty recipient/editors pair - exactly what let an
                -- off-guild character's spurious local prune (k-0019,
                -- Core.lua) get "corrected" by a lucky sync reply instead
                -- of the wipe being visible and investigated. Now only a
                -- STRICTLY newer incoming stamp is allowed to replace
                -- ours - otherwise this reply's recipient/editors are
                -- silently ignored (items are still handled independently
                -- below, same as before).
                local incomingRecipientEditorsUpdatedAt = tonumber(recipientEditorsUpdatedAtStr) or 0
                local localRecipientEditorsUpdatedAt = ns.db.recipientEditorsUpdatedAt or 0
                if incomingRecipientEditorsUpdatedAt > localRecipientEditorsUpdatedAt then
                    ns.db.recipient = (recipient ~= "" and recipient) or nil
                    local list = {}
                    if editorsStr ~= "" then
                        for name in editorsStr:gmatch("[^,]+") do
                            table.insert(list, name)
                        end
                    end
                    ns.db.editors = list
                    ns.db.recipientEditorsUpdatedAt = incomingRecipientEditorsUpdatedAt
                end
                -- k-0012 (2026-08-05): the priority list has its OWN
                -- separate version stamp/gate from recipient/editors'
                -- above (k-0019 added that gate later; this comment
                -- predates it). Before k-0012, ANY online peer's reply - even one
                -- with a stale or completely empty list (an old test
                -- client, someone who'd never added anything, etc.) -
                -- silently wiped out a genuinely newer local list on
                -- every login, since this whole snapshot-replace path
                -- trusts whoever answers first with zero regard for
                -- which side's data is actually current. Now each side's
                -- list carries its own version stamp (priorityListUpdatedAt,
                -- wall-clock time() so it's comparable across logins -
                -- bumped on every local edit AND every accepted live
                -- ITEM/ITEMGONE delta, see AddItem/RemoveItem and the
                -- ITEM/ITEMGONE branches above) and only a STRICTLY
                -- newer incoming snapshot is allowed to replace ours -
                -- otherwise this reply is trusted for recipient/editors
                -- only and the items portion is silently ignored, same
                -- as if this client just didn't answer at all.
                local incomingUpdatedAt = tonumber(updatedAtStr) or 0
                local localUpdatedAt = ns.db.priorityListUpdatedAt or 0
                if incomingUpdatedAt > localUpdatedAt then
                    -- Never reassign the table itself: it's the same
                    -- object as ns.db.priorityList since Core.lua's
                    -- InitDB(), and a reassignment here would silently
                    -- detach it from SavedVariables - clear in place.
                    for name in pairs(ns.priorityList) do
                        ns.priorityList[name] = nil
                    end
                    for _, entry in ipairs(DecodeItemEntries(itemsEncoded)) do
                        ns.priorityList[entry.name] = {
                            name = entry.name,
                            itemId = entry.itemId,
                            itemLink = entry.itemLink,
                            addedBy = nil,
                            addedAt = GetTime(),
                        }
                    end
                    ns.db.priorityListUpdatedAt = incomingUpdatedAt
                end
            end
        end
    end
end
