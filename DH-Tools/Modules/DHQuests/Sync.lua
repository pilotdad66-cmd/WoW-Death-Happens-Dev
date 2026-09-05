-- DH-Tools: Modules\DHQuests\Sync.lua
-- Guild-wide sync so every installed DH-Quests can see which guildmates
-- currently have which shared quests. Milestone 2 (see
-- claude\DH-Quests\DH-Quests-Design.md) - ports DH-Air's Sync.lua pattern
-- (src\DH-Air\Sync.lua): prefix registration, delta broadcasts, a
-- SYNCREQ/SYNCDATA full-state handshake for late joiners, manual chunking.
-- Key difference from DH-Air: this only ever broadcasts to GUILD (a
-- grouping tool for the whole guild, not a raid/party queue), and every
-- outbound payload is filtered through the sender's own category toggles
-- - an opted-out category is never broadcast, not just hidden on the
-- receiving end (see DH-Quests-Design.md's privacy note).
--
-- PROTOCOL (all messages are "TYPE|payload", sent via
-- C_ChatInfo.SendAddonMessage to GUILD; nothing is sent if the module is
-- disabled or the player isn't in a guild):
--
--   QUEST|questID:category:level:title  - sender now has this quest active
--                                          in a category they share
--   QUESTGONE|questID                   - sender no longer has this quest
--                                          (completed/abandoned/dropped)
--   SYNCREQ                             - "I just joined/reloaded, please
--                                          send me your current state"
--   SYNCDATA|i/total|entries            - chunked full-state reply to a
--                                          SYNCREQ, WHISPERed directly back
--                                          to the requester (not broadcast)
--
-- Full-state `entries` are semicolon-joined "questID:category:level:title"
-- records - semicolon (not comma) deliberately, since real quest titles
-- can contain commas ("The Manor, Ravenholdt", confirmed from Loopi's own
-- quest log) which would otherwise corrupt a naive split. Title is always
-- the LAST field in an entry, captured as "everything after the third
-- colon", so any stray colon inside a title can't break parsing either.
--
-- GATING: receiving/listening is never gated by the local player's own
-- share settings - a player who opted out of sharing their own quests
-- should still see everyone else's (DH-Quests-Design.md M4 note: "Toggles
-- only affect outbound sharing, not what's displayed from others").
-- SYNCREQ (asking others for their state) doesn't reveal anything about
-- the requester either, so it's also unconditional once in a guild.
-- Only the actual QUEST/QUESTGONE/SYNCDATA payloads - the things that
-- reveal what the sender has - are filtered by shareEnabled + the
-- specific category's toggle.

DHQuests = DHQuests or {}
local ns = DHQuests

-- STANDING RULE (2026-08-05, see knowledge\k-0009): bump this suffix
-- (V1 -> V2 -> ...) any time a change to this file's wire format (message
-- shape, field count/order, or meaning) is not purely additive/backward-
-- compatible. WoW addon messages are only received by clients registered
-- on the exact same prefix, so a bump cleanly partitions old/new clients
-- instead of letting one silently corrupt the other's data with a
-- mismatched decode - which is exactly what happened to DH-Air's
-- destinations sync tonight (continent field added to the data model but
-- not this kind of file's wire format). DH-Air's and DH-Bavin's Sync.lua
-- carry the identical PREFIX pattern and the identical rule.
local PREFIX = "DHQuestsV1"
-- Assumes no single "questID:category:level:title" entry ever exceeds
-- this length - safe for realistic quest titles (tested up to 200 chars
-- for entries in the 20-70 char range; see ChunkEncoded's comment for what
-- happens if that assumption is ever violated).
local MAX_CHUNK_CHARS = 200

-- 2026-08-04 (Loopi-reported bug): a guildmate with 11 shared quests was
-- only showing 10 on the Board for other viewers. An 11-quest full sync
-- easily spans 2-3 MAX_CHUNK_CHARS chunks, and this addon has always sent
-- chunked SYNCDATA with NO throttling library (see STATUS.md's own
-- previously-flagged, then-unconfirmed risk: "no ChatThrottleLib...
-- revisit if in-game testing shows throttling problems at guild scale") -
-- WoW's client silently drops addon messages sent in a tight back-to-back
-- burst with no pacing, which is exactly the historical reason
-- ChatThrottleLib exists as the community-standard workaround. Rather than
-- vendor that whole library for one send site, Sync_SendState now spaces
-- chunks CHUNK_SEND_DELAY_SECONDS apart via C_Timer instead of firing them
-- all in the same loop/frame.
local CHUNK_SEND_DELAY_SECONDS = 0.3

-- peers[senderName][questID] = { title=, category=, level=, suggestedGroup=,
-- status=, lastUpdated= } - the full Milestone 3 shape (DH-Quests-Design.md).
-- suggestedGroup is always nil (not exposed by this client's
-- GetQuestLogTitle - see Scan.lua); status ("online"/"offline") is stamped
-- from Core.lua's guild-roster cache and kept current via
-- ns.UpdateGuildRosterCache on GUILD_ROSTER_UPDATE (which also prunes
-- peers who have left the guild entirely). Still inspected via the
-- temporary /dhq peers command in Core.lua ahead of M5's real display
-- window.
ns.peers = ns.peers or {}
ns.syncBuffers = ns.syncBuffers or {} -- sender -> { total = n, chunks = {} }

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

-- Returns "GUILD" if broadcasting is even possible right now (player is in
-- a guild), or nil otherwise. Unlike DH-Air, there's no RAID/PARTY
-- fallback to prefer - this is guild-only by design.
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

-- Called from Core.lua on PLAYER_LOGIN once the module is enabled.
-- Registers the prefix and asks the guild for their current state -
-- SYNCREQ is unconditional (doesn't reveal anything about us), so this
-- fires even if the player has sharing turned off locally.
function ns.Sync_Init()
    RegisterPrefix()
    if ns.Sync_IsActive() then
        ns.Sync_Send("SYNCREQ")
    end
end

--------------------------------------------------------------------------
-- Outbound: whether we're allowed to share a given category right now
--------------------------------------------------------------------------

function ns.CategoryShared(category)
    if not ns.db or not ns.db.settings then return false end
    if not ns.db.settings.shareEnabled then return false end
    return ns.db.settings.categories[category] == true
end

--------------------------------------------------------------------------
-- Outbound: per-quest delta broadcasts
--------------------------------------------------------------------------

-- info = { title=, level=, category= } (ScanQuestLog's per-quest shape).
function ns.Sync_BroadcastQuest(questID, info)
    if not ns.CategoryShared(info.category) then return end
    if not ns.Sync_IsActive() then return end
    local payload = table.concat({ questID, info.category, info.level or 0 }, ":") .. ":" .. (info.title or "")
    ns.Sync_Send("QUEST", payload)
end

function ns.Sync_BroadcastQuestGone(questID)
    if not ns.Sync_IsActive() then return end
    ns.Sync_Send("QUESTGONE", tostring(questID))
end

--------------------------------------------------------------------------
-- Full-state encode/decode (for SYNCREQ/SYNCDATA)
--------------------------------------------------------------------------

-- scan = ScanQuestLog()'s return shape: { [questID] = {title=,level=,category=} }.
-- Only includes quests whose category is currently shared - an opted-out
-- category never leaves this client, not even in a full-state reply.
local function EncodeQuests(scan)
    local parts = {}
    for questID, info in pairs(scan) do
        if ns.CategoryShared(info.category) then
            table.insert(parts, table.concat({ questID, info.category, info.level or 0 }, ":")
                .. ":" .. (info.title or ""))
        end
    end
    return table.concat(parts, ";")
end

-- Splits chunked SYNCDATA back into { {questID=, category=, level=, title=}, ... }.
-- Each entry's title is captured as everything after the third colon, so a
-- colon inside a title can't corrupt the split (see file header).
local function DecodeQuestEntries(data)
    local entries = {}
    for entry in data:gmatch("[^;]+") do
        local questID, category, level, title = entry:match("^(%d+):(%a+):(%d+):(.*)$")
        if questID then
            table.insert(entries, {
                questID = tonumber(questID),
                category = category,
                level = tonumber(level),
                title = title,
            })
        end
    end
    return entries
end

-- Splits an already-encoded string into <=MAX_CHUNK_CHARS pieces, always
-- cutting at an entry boundary (";") rather than mid-entry where possible -
-- same idiom as DH-Air's Sync_SendState, just semicolon instead of comma.
--
-- Bug fixed 2026-07-27 (caught by a unit test before this ever ran
-- in-game): DH-Air's original version always did
-- `remaining:sub(1, lastSemi - 1)` / `remaining:sub(lastSemi + 1)` even
-- when no separator was found in the window, in which case lastSemi
-- fell back to MAX_CHUNK_CHARS - silently dropping the character at that
-- exact position every time a cut landed with no separator nearby. DH-Air
-- likely never hit this in practice (any 200-char window normally spans
-- several short queue entries, guaranteeing a comma), but quest titles are
-- long enough relative to MAX_CHUNK_CHARS that this needed a real fix, not
-- just inherited luck. If no separator exists in the window at all - a
-- single entry longer than MAX_CHUNK_CHARS on its own, which shouldn't
-- happen for realistic quest titles at this chunk size - the window is
-- taken as-is with no trimming; rejoining chunks with ";" would corrupt
-- that one oversized entry, a known/accepted limitation rather than
-- something worth solving for now.
local function ChunkEncoded(encoded)
    local chunks = {}
    local remaining = encoded
    while #remaining > 0 do
        if #remaining <= MAX_CHUNK_CHARS then
            table.insert(chunks, remaining)
            remaining = ""
        else
            local cut = remaining:sub(1, MAX_CHUNK_CHARS)
            local sepPos = cut:find(";[^;]*$")
            if sepPos then
                table.insert(chunks, remaining:sub(1, sepPos - 1))
                remaining = remaining:sub(sepPos + 1)
            else
                table.insert(chunks, cut)
                local nextStart = MAX_CHUNK_CHARS + 1
                -- An entry can end exactly at the window boundary, putting
                -- its separator immediately after rather than inside the
                -- window we just searched - skip it here too, or the next
                -- chunk starts with a stray leading ";" (harmless to
                -- decode, since a bare ";" never matches DecodeQuestEntries'
                -- gmatch, but pointless noise worth just not producing).
                if remaining:sub(nextStart, nextStart) == ";" then
                    nextStart = nextStart + 1
                end
                remaining = remaining:sub(nextStart)
            end
        end
    end
    return chunks
end

-- Replies to a SYNCREQ from `targetName` with our current shareable state,
-- chunked and whispered directly back (not broadcast) to avoid flooding
-- guild chat with what could be a large state dump.
function ns.Sync_SendState(targetName)
    local scan = ns.ScanQuestLog()
    local encoded = EncodeQuests(scan)
    if encoded == "" then return end -- nothing shareable right now

    local chunks = ChunkEncoded(encoded)
    local total = #chunks
    -- 2026-08-04: staggered, not a tight loop - see CHUNK_SEND_DELAY_SECONDS
    -- comment up top for why. The first chunk still goes out immediately
    -- (no reason to delay it), only the rest are spaced out afterward.
    for i, chunk in ipairs(chunks) do
        local text = i .. "/" .. total .. "|" .. chunk
        if i == 1 then
            ns.Sync_SendTo("SYNCDATA", text, targetName)
        else
            C_Timer.NewTimer((i - 1) * CHUNK_SEND_DELAY_SECONDS, function()
                ns.Sync_SendTo("SYNCDATA", text, targetName)
            end)
        end
    end
end

-- Stores one incoming quest record into peers[senderName]. Used for both
-- a single QUEST delta and each entry from a reassembled SYNCDATA.
local function StorePeerQuest(senderName, questID, category, level, title)
    ns.peers[senderName] = ns.peers[senderName] or {}
    -- status defaults to "offline" if the roster cache hasn't populated
    -- yet (fail closed, same idiom as DH-Air's HasPermission) - corrected
    -- on the next GUILD_ROSTER_UPDATE via ns.UpdateGuildRosterCache.
    local roster = ns.guildRoster and ns.guildRoster[senderName]
    ns.peers[senderName][questID] = {
        title = title,
        category = category,
        level = level,
        suggestedGroup = nil,
        status = (roster and roster.online) and "online" or "offline",
        lastUpdated = GetTime(),
    }
end

local function RemovePeerQuest(senderName, questID)
    if ns.peers[senderName] then
        ns.peers[senderName][questID] = nil
    end
end

--------------------------------------------------------------------------
-- Incoming message handling
--------------------------------------------------------------------------

-- Registered from Core.lua's CHAT_MSG_ADDON handler.
function ns.Sync_OnAddonMessage(prefix, message, _channel, sender)
    if prefix ~= PREFIX then return end

    local myName = UnitName("player")
    local senderShort = sender and sender:match("^([^-]+)") or sender
    if senderShort == myName then return end -- ignore our own echo

    local msgType, rest = message:match("^([^|]+)|?(.*)$")
    if not msgType then return end

    if msgType == "QUEST" then
        local questID, category, level, title = rest:match("^(%d+):(%a+):(%d+):(.*)$")
        if questID then
            StorePeerQuest(senderShort, tonumber(questID), category, tonumber(level), title)
        end

    elseif msgType == "QUESTGONE" then
        local questID = tonumber(rest)
        if questID then
            RemovePeerQuest(senderShort, questID)
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
            local fullData = table.concat(buf.chunks, ";")
            ns.syncBuffers[sender] = nil
            for _, entry in ipairs(DecodeQuestEntries(fullData)) do
                StorePeerQuest(senderShort, entry.questID, entry.category, entry.level, entry.title)
            end
        end
    end
end
