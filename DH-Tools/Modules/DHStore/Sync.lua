-- DH-Store wire protocol (DHStoreV1). Mirrors DH-Bavin's own Sync.lua
-- pattern almost directly (prefix registration, delta broadcast + full-
-- state handshake, permission gates only on state-changing messages,
-- last-writer-wins via wall-clock time() version stamps, chunk+whisper
-- for SYNCDATA) - see DH-Store-Design.md question #2 for the full
-- resolved design this implements, and DH-Bavin\Sync.lua's own header
-- for the precedent this was studied from.
--
-- Own prefix, own namespace (DHTools.Store, matching DHBavin's own
-- DHTools.Bavin sub-namespace convention - NOT the plain DHTools table
-- Core.lua/Config.lua/Minimap.lua share) - fully isolated from Bavin's
-- DHBavinV4 channel even though Store hard-depends on Bavin being
-- enabled (RegisterModule's `requires = "bavin"`, see Core.lua).
--
-- CATALOG KEYED BY listingId, NOT itemId (2026-09-28, design question
-- #12): several simultaneous listings of the same item (different stack
-- sizes) are allowed, so itemId is just a field on each listing, never
-- the lookup key.
--
-- FIELD ORDER WITHIN AN ENTRY: itemLink must always be the LAST field
-- of any entry it appears in (same reasoning as DH-Bavin's own
-- EncodeItems/DecodeItemEntries) - a real item hyperlink is full of "|"
-- color-code characters, so anything after it in a "|"-split pattern
-- would be unparseable. It never contains ";" (existing codebase
-- assumption, same one DH-Bavin's own entries already rely on).
--
-- NOT YET IN-GAME TESTED - built 2026-09-28, no two real clients have
-- exchanged a message on this prefix yet.

local DHTools = DHTools
DHTools.Store = DHTools.Store or {}
local ns = DHTools.Store

local PREFIX = "DHStoreV1"
local MAX_CHUNK_CHARS = 200

-- ns.catalog[listingId] = { listingId=, itemId=, itemLink=, quantity=,
-- goldPrice= (copper, whole-lot total), listedBy=, listedAt=,
-- pendingBy= (nil or buyer name) }. Pure runtime state here, same
-- placeholder-then-repoint pattern as DH-Bavin's ns.priorityList -
-- Core.lua's InitDB() repoints this at the persistent ns.db.catalog
-- table once DHStoreDB loads.
ns.catalog = ns.catalog or {}
ns.syncBuffers = ns.syncBuffers or {} -- sender -> { total=, chunks={} }

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

-- Guild-only, same as DH-Bavin/DH-Quests - no RAID/PARTY fallback.
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

-- Called from Core.lua on PLAYER_LOGIN (after Bavin - the dependency -
-- has already activated, per Core.lua's `requires = "bavin"`).
function ns.Sync_Init()
    RegisterPrefix()
    if ns.Sync_IsActive() then
        ns.Sync_Send("STORESYNCREQ")
    end
end

-- Collision-safe listing ID: senderName:msTimestamp:random - no server
-- authority needed, same idiom DH-Tools\Core.lua's own guild-chat lookup
-- tiebreak already uses (design question #2's own resolution).
function ns.NewListingId()
    return (UnitName("player") or "?") .. ":" .. tostring(math.floor((GetTime() or 0) * 1000))
        .. ":" .. tostring(math.random(0, 999))
end

--------------------------------------------------------------------------
-- Primary officer: public API + broadcast
--------------------------------------------------------------------------
-- 2026-09-28 (Chris): the STOREOFFICERS message used to carry a whole
-- officer roster alongside primaryOfficer ("folded into ONE wire
-- message... primary-officer selection is just another field of that
-- same roster state"). The roster half is gone now - Store Officer
-- status comes from DH-Bavin's shared officer-roles list (its own
-- EDITORS broadcast already keeps that in sync guild-wide), so this
-- message now carries ONLY primaryOfficer. Kept the message name
-- (STOREOFFICERS) since Store was never in-game tested on the old
-- shape - nothing to stay compatible with.

function ns.Sync_BroadcastOfficers()
    local primary = (ns.db and ns.db.primaryOfficer) or ""
    ns.Sync_Send("STOREOFFICERS", primary)
end

-- Gated by ns.CanManageStoreOfficersLocal() (Core.lua) - mutates +
-- broadcasts once the gate has passed, same "check first, then mutate,
-- then broadcast" shape as DH-Bavin's SetRecipient/SetEditors.
function ns.SetPrimaryOfficer(name)
    ns.db.primaryOfficer = (name and name ~= "" and name) or nil
    ns.db.officersUpdatedAt = time()
    ns.Sync_BroadcastOfficers()
end

--------------------------------------------------------------------------
-- Listings: public API + delta broadcasts
--------------------------------------------------------------------------
-- Public entry points the officer listing UI (Core.lua) and the buyer's
-- Buy button call directly, gated by the caller BEFORE touching
-- anything (mirrors DH-Bavin's AddItem/RemoveItem shape).

-- itemId/itemLink/quantity/goldPrice describe the WHOLE LOT (question
-- #12: whole-lot-only purchases, so there is no per-unit price on the
-- wire at all). goldPrice is copper, the FINAL total for the stack,
-- resolved once here (manual entry today - see this file's header note
-- on ItemPoints.lua's gold value not being wired through yet) and never
-- recomputed by receivers. Returns the new listingId, or nil if refused.
function ns.AddOrEditListing(listingId, itemId, itemLink, quantity, goldPrice)
    listingId = listingId or ns.NewListingId()
    ns.catalog[listingId] = {
        listingId = listingId,
        itemId = itemId,
        itemLink = itemLink,
        quantity = quantity,
        goldPrice = goldPrice,
        listedBy = UnitName("player"),
        listedAt = time(),
        pendingBy = nil, -- a fresh/edited listing is never pending - see LISTING branch note below
    }
    ns.db.catalogUpdatedAt = time() -- k-0012-style version stamp, see DH-Bavin's own comment on this pattern
    ns.Sync_BroadcastListing(listingId)
    return listingId
end

function ns.Sync_BroadcastListing(listingId)
    local l = ns.catalog[listingId]
    if not l then return end
    ns.Sync_Send("LISTING", l.listingId .. "|" .. tostring(l.itemId or "")
        .. "|" .. tostring(l.quantity or 1) .. "|" .. tostring(l.goldPrice or 0)
        .. "|" .. (l.listedBy or "") .. "|" .. tostring(l.listedAt or 0)
        .. "|" .. (l.itemLink or ""))
end

-- Buyer's own client, unconditional/self-asserted (question #3's
-- resolved trust model - same tier as answering a sync request, not a
-- claim that needs verifying). Also fires the purchase-request mail via
-- Core.lua's ns.SendPurchaseRequestMail - kept as a separate call at the
-- UI layer (Core.lua's Buy button), not inlined here, so this function
-- stays pure wire/state and testable without WoW's mail API.
function ns.MarkListingPending(listingId, buyerName)
    local l = ns.catalog[listingId]
    if not l or l.pendingBy then return false end
    l.pendingBy = buyerName or UnitName("player")
    ns.db.catalogUpdatedAt = time()
    ns.Sync_Send("LISTINGPENDING", listingId .. "|" .. l.pendingBy)
    return true
end

-- Officer-gated (CanManageListingsLocal) at the call site. Permanently
-- removes the listing for everyone - the officer's own explicit "mark
-- as sold" action after reviewing the pending purchase-request mail.
function ns.MarkListingSold(listingId)
    if not ns.catalog[listingId] then return false end
    ns.catalog[listingId] = nil
    ns.db.catalogUpdatedAt = time()
    ns.Sync_Send("LISTINGSOLD", listingId)
    return true
end

-- Officer-gated, same as MarkListingSold. Escape hatch when a pending
-- claim doesn't pan out - reverts to available. No auto-timeout
-- (question #2's resolved answer) - stays pending until an officer
-- calls this or MarkListingSold.
function ns.UnpendListing(listingId)
    local l = ns.catalog[listingId]
    if not l or not l.pendingBy then return false end
    l.pendingBy = nil
    ns.db.catalogUpdatedAt = time()
    ns.Sync_Send("LISTINGUNPEND", listingId)
    return true
end

--------------------------------------------------------------------------
-- Full-state encode/decode (for STORESYNCREQ/STORESYNCDATA)
--------------------------------------------------------------------------
-- Entry shape: listingId|itemId|quantity|goldPrice|listedBy|listedAt|
-- pendingBy|itemLink - itemLink LAST (see file header). listingId/
-- listedBy/pendingBy are character names or the ID format from
-- NewListingId - none can contain "|" or ";".

local function EncodeListings()
    local parts = {}
    for listingId, l in pairs(ns.catalog) do
        table.insert(parts, listingId .. "|" .. tostring(l.itemId or "")
            .. "|" .. tostring(l.quantity or 1) .. "|" .. tostring(l.goldPrice or 0)
            .. "|" .. (l.listedBy or "") .. "|" .. tostring(l.listedAt or 0)
            .. "|" .. (l.pendingBy or "") .. "|" .. (l.itemLink or ""))
    end
    return table.concat(parts, ";")
end

local function DecodeListingEntries(data)
    local entries = {}
    for entry in data:gmatch("[^;]+") do
        local listingId, itemIdStr, qtyStr, goldStr, listedBy, listedAtStr, pendingBy, itemLink =
            entry:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
        if listingId and listingId ~= "" then
            table.insert(entries, {
                listingId = listingId,
                itemId = (itemIdStr ~= "" and tonumber(itemIdStr)) or nil,
                quantity = tonumber(qtyStr) or 1,
                goldPrice = tonumber(goldStr) or 0,
                listedBy = (listedBy ~= "" and listedBy) or nil,
                listedAt = tonumber(listedAtStr) or 0,
                pendingBy = (pendingBy ~= "" and pendingBy) or nil,
                itemLink = itemLink,
            })
        end
    end
    return entries
end

-- Splits an already-encoded string into <=MAX_CHUNK_CHARS pieces. Ported
-- verbatim from DH-Bavin's own ChunkEncoded (including its 2026-07-29
-- fix): each chunk is an EXACT substring, nothing dropped at a cut - the
-- receiver's plain table.concat(chunks) is therefore correct no matter
-- where a cut lands, unlike an earlier version of this idiom that
-- silently dropped ";" separators and assumed the whole payload was
-- ";"-joined (true for DH-Quests, NOT true for a header+entries payload
-- like this one - see DH-Bavin\Sync.lua's own comment for the full story).
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

-- Replies to a STORESYNCREQ from `targetName` with our current full
-- state (primary officer, catalog), chunked and whispered back.
-- Answered unconditionally - "relaying, not asserting", same GATING
-- idiom as DH-Bavin's Sync_SendState. 2026-09-28 (Chris): dropped
-- officers/officersUpdatedAt - Store Officer status now comes from
-- DH-Bavin's own shared list/sync, not this module's.
function ns.Sync_SendState(targetName)
    local primary = (ns.db and ns.db.primaryOfficer) or ""
    local officersUpdatedAt = (ns.db and ns.db.officersUpdatedAt) or 0
    local catalogUpdatedAt = (ns.db and ns.db.catalogUpdatedAt) or 0
    local entries = EncodeListings()

    -- primary/*UpdatedAt can't contain "|" (names/numbers never do);
    -- entries is the one field that does, so it goes last - same
    -- ordering reasoning as DH-Bavin's own SendState payload.
    local payload = primary .. "|" .. officersUpdatedAt
        .. "|" .. catalogUpdatedAt .. "|" .. entries

    local chunks = ChunkEncoded(payload)
    local total = #chunks
    for i, chunk in ipairs(chunks) do
        ns.Sync_SendTo("STORESYNCDATA", i .. "/" .. total .. "|" .. chunk, targetName)
    end
end

--------------------------------------------------------------------------
-- Incoming message handling
--------------------------------------------------------------------------
-- Registered from Core.lua's CHAT_MSG_ADDON handler, same split as
-- DH-Bavin's Core.lua/Sync.lua.

function ns.Sync_OnAddonMessage(prefix, message, _channel, sender)
    if prefix ~= PREFIX then return end
    if not ns.db then return end

    local myName = UnitName("player")
    local senderShort = DHTools.Bavin.NormalizeName(sender)
    if senderShort == myName then return end -- ignore our own echo

    local msgType, rest = message:match("^([^|]+)|?(.*)$")
    if not msgType then return end

    if msgType == "STOREOFFICERS" then
        -- 2026-09-28 (Chris): primaryOfficer only now - see
        -- Sync_BroadcastOfficers' comment.
        if not ns.CanManageStoreOfficers(senderShort) then return end
        local primary = rest
        ns.db.primaryOfficer = (primary ~= "" and primary) or nil
        ns.db.officersUpdatedAt = time()

    elseif msgType == "LISTING" then
        if not ns.CanManageListings(senderShort) then return end
        local listingId, itemIdStr, qtyStr, goldStr, listedBy, listedAtStr, itemLink =
            rest:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
        if listingId and listingId ~= "" then
            ns.catalog[listingId] = {
                listingId = listingId,
                itemId = (itemIdStr ~= "" and tonumber(itemIdStr)) or nil,
                quantity = tonumber(qtyStr) or 1,
                goldPrice = tonumber(goldStr) or 0,
                listedBy = (listedBy ~= "" and listedBy) or nil,
                listedAt = tonumber(listedAtStr) or 0,
                pendingBy = nil, -- see AddOrEditListing's own comment
                itemLink = itemLink,
            }
            ns.db.catalogUpdatedAt = time()
        end

    elseif msgType == "LISTINGPENDING" then
        -- Unconditional/self-asserted (question #3) - no permission gate.
        local listingId, buyerName = rest:match("^([^|]*)|(.*)$")
        local l = listingId and ns.catalog[listingId]
        if l and not l.pendingBy then
            l.pendingBy = (buyerName ~= "" and buyerName) or senderShort
            ns.db.catalogUpdatedAt = time()
        end

    elseif msgType == "LISTINGSOLD" then
        if not ns.CanManageListings(senderShort) then return end
        if rest ~= "" and ns.catalog[rest] then
            ns.catalog[rest] = nil
            ns.db.catalogUpdatedAt = time()
        end

    elseif msgType == "LISTINGUNPEND" then
        if not ns.CanManageListings(senderShort) then return end
        local l = rest ~= "" and ns.catalog[rest]
        if l then
            l.pendingBy = nil
            ns.db.catalogUpdatedAt = time()
        end

    elseif msgType == "STORESYNCREQ" then
        ns.Sync_SendState(sender)

    elseif msgType == "STORESYNCDATA" then
        ns.Sync_HandleSyncData(rest, sender)
    end
end

-- Reassembles a chunked STORESYNCDATA reply and, once complete, applies
-- it - primary and catalog each gated by their OWN version stamp
-- (last-writer-wins), same k-0012/k-0019 pattern as DH-Bavin's own
-- SYNCDATA branch: an incoming snapshot only replaces ours if it's
-- STRICTLY newer, otherwise it's silently ignored (not trusted just for
-- answering first). 2026-09-28 (Chris): dropped the officers field -
-- see Sync_SendState's comment.
function ns.Sync_HandleSyncData(rest, sender)
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
    if received < buf.total then return end

    -- Plain concat, no inserted separator - each chunk is an exact
    -- substring (ChunkEncoded's guarantee above).
    local fullData = table.concat(buf.chunks)
    ns.syncBuffers[sender] = nil

    local primary, officersUpdatedAtStr, catalogUpdatedAtStr, entriesEncoded =
        fullData:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
    if not primary then return end

    local incomingOfficersUpdatedAt = tonumber(officersUpdatedAtStr) or 0
    if incomingOfficersUpdatedAt > (ns.db.officersUpdatedAt or 0) then
        ns.db.primaryOfficer = (primary ~= "" and primary) or nil
        ns.db.officersUpdatedAt = incomingOfficersUpdatedAt
    end

    local incomingCatalogUpdatedAt = tonumber(catalogUpdatedAtStr) or 0
    if incomingCatalogUpdatedAt > (ns.db.catalogUpdatedAt or 0) then
        -- Never reassign the table itself - same object as ns.db.catalog
        -- since Core.lua's InitDB(), reassigning here would detach it
        -- from SavedVariables. Clear in place, same as DH-Bavin.
        for listingId in pairs(ns.catalog) do
            ns.catalog[listingId] = nil
        end
        for _, entry in ipairs(DecodeListingEntries(entriesEncoded)) do
            ns.catalog[entry.listingId] = entry
        end
        ns.db.catalogUpdatedAt = incomingCatalogUpdatedAt
    end
end
