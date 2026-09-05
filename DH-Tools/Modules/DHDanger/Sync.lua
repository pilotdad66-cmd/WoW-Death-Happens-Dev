-- DH-Tools: Modules\DHDanger\Sync.lua
--
-- Peer-relay broadcast (k-0026, k-0030; design finalized 2026-08-20 with
-- Loopi). k-0026: NAME_PLATE_UNIT_ADDED/UPDATE_MOUSEOVER_UNIT/
-- PLAYER_TARGET_CHANGED all require the mob in the DETECTING player's own
-- camera view - a mob approaching from outside view gives that player
-- ZERO warning, not a short one. k-0030 (Unitscan Hardcore, studied not
-- copied - All Rights Reserved): the view-frustum gate is per-client, so
-- relaying one player's detection to nearby guildmates/groupmates is a
-- genuine second pair of eyes, not just a nice-to-have.
--
-- WIRE FORMAT (k-0009: the PREFIX itself is the version tag - bump the
-- suffix on any non-additive change to this shape, never add an
-- in-payload version field instead):
--
--   SIGHT|npcID|guid|cellX|cellY|zone|source
--
-- npcID/cellX/cellY are numbers (cellX/cellY are ns.Cell()-rounded yards,
-- the exact same grid ns.RecordSighting already uses for the sightings
-- history - nothing new invented here). guid is the ORIGINAL detecting
-- client's UnitGUID for the creature (WoW GUIDs identify one spawned
-- instance server-side, so it's the same string on every client) -
-- carried through so a relayed alert keys ns.Alert's cooldown table
-- exactly the same way a direct nameplate/mouseover/target alert already
-- does (per creature instance, not per npcID), rather than inventing a
-- second, coarser cooldown scheme. zone is GetRealZoneText() -
-- UnitPosition's x/y are only comparable within the SAME zone/map, so a
-- receiver in a different zone discards the message outright; there is
-- no mapID normalization here; unlike k-0030's Unitscan reference, no
-- layer field either - Classic Era has no reliable layer-detection API
-- (k-0001), so there is nothing to gate on, and an alert for a mob that
-- turns out to be on a different layer is an accepted false-positive
-- (same direction of error k-0037 already prefers for this module - warn
-- a little early/wrong beats staying silent). source is the ORIGINAL
-- detector's source ("nameplate"/"mouseover"/"target" only - see the
-- broadcast guard in Core.lua's ns.Alert) - used on receipt only to pick
-- the right SRC_ACCURACY radius; the receiver always labels what IT
-- experiences as "relayed" (its own SRC_ACCURACY entry), never the
-- original source name, so a relayed alert can never be mistaken for
-- something the receiving player actually saw themselves.
--
-- Sent to GUILD and PARTY/RAID (Loopi, STATUS.md) - whichever of those
-- the sender is actually in, no other reach. A receiver's OWN curated/
-- manual-list/category/level/mute settings still gate whether a relayed
-- sighting alerts THEM (ns.ShouldRelayAlert calls ns.IsDangerous) - a
-- relay never bypasses the receiving player's own settings just because
-- a guildmate saw it.
--
-- Only nameplate/mouseover/target detections are ever broadcast (hooked
-- from Core.lua's ns.Alert). Yell/emote already carry ~300yd and are not
-- camera-gated (k-0026 doesn't apply to them), so relaying them adds
-- little; loot is a dead mob, never a live threat. A relayed alert
-- re-enters ns.Alert with source="relayed", which is not one of the
-- three broadcast sources, so it can never itself trigger a second
-- broadcast - no separate loop guard needed.
--
-- "Share my sightings with guild/group" (DHToolsDB.danger.shareSync,
-- default ON) gates SENDING only - it never gates receiving. Turning it
-- off stops your own detections from going out; you still hear about
-- everyone else's.
--
-- No SYNCREQ/late-joiner handshake (unlike DH-Quests/DH-Bavin's Sync.lua
-- pattern, which this otherwise mirrors - prefix registration, a
-- TYPE|payload wire shape, dispatch from the module's own Core.lua
-- CHAT_MSG_ADDON handler) - there is no persistent state to catch up on
-- here, only live events, so Sync_Init just registers the prefix.

local DHTools = DHTools
local ns = DHTools.Danger

-- STANDING RULE (k-0009): bump this suffix any time a change to this
-- file's wire format (message shape, field count/order, or meaning) is
-- not purely additive/backward-compatible.
local PREFIX = "DHDangerV1"

local function AddonSendMessage(text, channel)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, text, channel)
    elseif SendAddonMessage then
        SendAddonMessage(PREFIX, text, channel)
    end
end

local function RegisterPrefix()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    elseif RegisterAddonMessagePrefix then
        pcall(RegisterAddonMessagePrefix, PREFIX)
    end
end

local function Channels()
    local chans = {}
    if IsInGuild and IsInGuild() then chans[#chans + 1] = "GUILD" end
    if IsInGroup and IsInGroup() then
        chans[#chans + 1] = (IsInRaid and IsInRaid()) and "RAID" or "PARTY"
    end
    return chans
end

-- Called from Core.lua's PLAYER_LOGIN handler.
function ns.Sync_Init()
    RegisterPrefix()
end

-- Called from Core.lua's ns.Alert, only for guid-bearing nameplate/
-- mouseover/target detections (see file header). Silently does nothing
-- if sharing is off, nobody's around to tell, or position/zone aren't
-- readable right now (instance/BG) - none of those are errors, they're
-- just nothing to broadcast.
function ns.BroadcastSighting(guid, npcID, source)
    if not (ns.db and ns.db.shareSync) then return end
    local chans = Channels()
    if #chans == 0 then return end

    local x, y = ns.PlayerPos()
    if not x then return end
    local zone = GetRealZoneText and GetRealZoneText() or nil
    if not zone or zone == "" then return end

    local msg = "SIGHT|" .. table.concat({
        npcID, guid, ns.Cell(x), ns.Cell(y), zone, source,
    }, "|")
    for _, ch in ipairs(chans) do
        AddonSendMessage(msg, ch)
    end
end

-- Pure parse, no game-state reads - testable headless. rest is
-- everything after "SIGHT|". Returns npcID, guid, cellX, cellY, zone,
-- source, or nil on any missing/malformed field.
function ns.ParseSightMessage(rest)
    local npcIDStr, guid, cxStr, cyStr, zone, source = strsplit("|", rest or "", 6)
    local npcID, cx, cy = tonumber(npcIDStr), tonumber(cxStr), tonumber(cyStr)
    if not (npcID and guid and guid ~= "" and cx and cy
        and zone and zone ~= "" and source and source ~= "") then
        return nil
    end
    return npcID, guid, cx, cy, zone, source
end

-- Pure decision, no game-state reads beyond what's passed in - testable
-- headless (same "decide vs act" split Core.lua's ns.EntryWarns/
-- ns.LevelRelevant already use). A relay only fires a local alert if:
-- the zone matches (UnitPosition coords are only comparable within one
-- zone/map - see file header), the npcID still clears the RECEIVING
-- player's own category/level/mute settings (never bypassed just
-- because a guildmate saw it), and the reported cell is within the
-- reporting source's own accuracy radius (plus one grid cell of
-- rounding slop) of where the receiver actually stands.
function ns.ShouldRelayAlert(npcID, cellX, cellY, zone, source, myZone, myX, myY)
    if not zone or zone ~= myZone then return false end
    if not ns.IsDangerous(npcID) then return false end
    if not myX or not myY then return false end
    local dist = ns.Dist(myX, myY, cellX, cellY)
    if not dist then return false end
    local radius = (ns.SRC_ACCURACY[source] or 300) + ns.GRID
    return dist <= radius
end

local function ShortSenderName(full)
    if not full then return nil end
    return full:match("^([^%-]+)") or full
end

-- Registered from Core.lua's CHAT_MSG_ADDON handler.
function ns.Sync_OnAddonMessage(prefix, message, _channel, sender)
    if prefix ~= PREFIX then return end
    if not ns.db then return end
    if ShortSenderName(sender) == UnitName("player") then return end -- ignore our own echo

    local msgType, rest = message:match("^([^|]+)|?(.*)$")
    if msgType ~= "SIGHT" then return end

    local npcID, guid, cx, cy, zone, source = ns.ParseSightMessage(rest)
    if not npcID then return end

    local myZone = GetRealZoneText and GetRealZoneText() or nil
    local myX, myY = ns.PlayerPos()
    if not ns.ShouldRelayAlert(npcID, cx, cy, zone, source, myZone, myX, myY) then return end

    local curated = ns.Curated and ns.Curated()
    local name = ns.ThreatName and ns.ThreatName(npcID, curated and curated[npcID])
    ns.Alert(guid, npcID, name, "relayed")
end
