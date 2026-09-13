-- DH-Tools: Core.lua
-- Master addon - lets a guild member activate/deactivate individual
-- modules from one addon. See claude\DH-Tools\PROFILE.md for the module
-- registration contract and claude\DH-Tools\DH-Tools-Design.md for the
-- full design/milestone plan.

local ADDON_NAME = ...

DHTools = DHTools or {}
local ns = DHTools
ns.ADDON_NAME = ADDON_NAME
-- 2026-08-06 (Loopi): was a hardcoded "1.0" literal that never got
-- touched during the v1.1.2 release - build-release-zip.ps1's -Version
-- param only names the output zip file, it does NOT write the .toc's own
-- "## Version:" line (that gets edited by hand), and nothing here ever
-- read that line back, so the About page kept showing "1.0" through
-- multiple real releases. Fixed at the root instead of just updating the
-- literal (which would only recreate the same drift at the next
-- release): read the version from the .toc's own metadata, same
-- dual-path C_AddOns/legacy-global idiom already used elsewhere in this
-- codebase (e.g. IsAddOnInstalled's GetAddOnInfo fallback) - now there's
-- exactly one place to edit at release time (the .toc line) and this
-- always reflects it.
ns.VERSION = (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version"))
    or (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
    or "unknown"

-- === Module registry ===
-- Each module file calls DHTools.RegisterModule(key, def) at load time.
-- def = {
--   name = "Display Name",       -- shown in /dht list and the Tools config page
--   desc = "One short line.",    -- optional: shown under the module's row in
--                                -- the Tools config page (Config.lua) - keep
--                                -- it to a single line, small print
--   default = true/false,        -- state on a fresh install (no saved value yet)
--   OnEnable = function() end,   -- optional: called on enable (incl. at login if already on)
--   OnDisable = function() end,  -- optional: called on disable
-- }
-- Saved enable state lives in DHToolsDB.modules[key]. Module-specific data
-- goes in the module's own DHToolsDB.<key> sub-table - Core.lua never
-- touches those.
ns.modules = {}
ns.moduleOrder = {}

function ns.RegisterModule(key, def)
    if ns.modules[key] then
        error("DH-Tools: module '" .. key .. "' already registered")
    end
    ns.modules[key] = def
    table.insert(ns.moduleOrder, key)
end

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99DH-Tools:|r " .. msg)
end

function ns.InitDB()
    if type(DHToolsDB) ~= "table" then
        DHToolsDB = {}
    end
    if type(DHToolsDB.modules) ~= "table" then
        DHToolsDB.modules = {}
    end
    if type(DHToolsDB.minimap) ~= "table" then
        DHToolsDB.minimap = { hide = false }
    end
    ns.db = DHToolsDB
end

-- === Author account admin (2026-08-05) ===
-- PUBLIC-RELEASE TOGGLE: set AUTHOR_OVERRIDE_ENABLED to false (or delete
-- this whole section, its call site in the PLAYER_LOGIN handler below,
-- and the `## SavedVariables: DHToolsAccountDB` line in DH-Tools.toc)
-- before distributing DH-Tools to a guild you're not personally a
-- member of - see claude\ROADMAP.md's Publishing workflow section.
--
-- WHY THIS EXISTS: the addon API deliberately has no way to ask "is
-- this character on the same account as character X" for anyone but
-- the CURRENT account (C_AccountInfo.IsGUIDRelatedToLocalAccount only
-- answers for the account actually running the check) - Blizzard walls
-- this off for privacy, so per-module admin overrides have always been
-- scoped to one hardcoded character name (FULL_PERMISSION_OVERRIDE_NAME
-- in DH-Bavin's Core.lua, same idiom in DH-Air's). That's fine for
-- REMOTE verification (another client checking who sent a network
-- message - there's no alternative), but means Loopi had to log into
-- one specific character to get admin access locally, on every alt.
--
-- FIX: SavedVariables (not SavedVariablesPerCharacter) ARE inherently
-- account-scoped by the client itself - one file per WoW account,
-- shared automatically by every character logged into it (DHBavinDB
-- already relies on exactly this for recipient/editors - see its own
-- 2026-07-29 fix). This reuses that existing mechanism instead of
-- trying to re-derive account identity: the first time ANY character in
-- AUTHOR_CHARACTER_NAMES logs in, the ACCOUNT (via DHToolsAccountDB)
-- gets flagged, not just that one character - every other character on
-- the same account, including alts created afterward, then gets full
-- local admin automatically, with zero further maintenance.
--
-- SCOPE: LOCAL ONLY - this decides what THIS client is allowed to do
-- (ns.IsAuthorAccount(), called from each module's own local-only
-- permission entry points). It cannot help verify an INCOMING network
-- message's sender, since a receiving client has no access to the
-- sender's account-wide SavedVariables - that side still goes through
-- each module's own FULL_PERMISSION_OVERRIDE_NAME-style character-name
-- check, unchanged. See claude\knowledge\ for the full writeup.
local AUTHOR_OVERRIDE_ENABLED = true
local AUTHOR_CHARACTER_NAMES = { Loopi = true, Loopidot = true }

-- True if THIS account has ever logged into a character in
-- AUTHOR_CHARACTER_NAMES (see CheckAuthorAccount below). Modules call
-- this from their own LOCAL-only permission entry points - never from a
-- function that also verifies a remote sender's name (that would let
-- the author's own account wrongly trust an arbitrary incoming message
-- just because the RECEIVER happens to be the author - see the
-- knowledge base entry for why this distinction matters).
function ns.IsAuthorAccount()
    return AUTHOR_OVERRIDE_ENABLED and type(DHToolsAccountDB) == "table"
        and DHToolsAccountDB.isAuthorAccount == true
end

-- Called once per login/reload (PLAYER_LOGIN, below). Cheap no-op for
-- everyone except the handful of names in AUTHOR_CHARACTER_NAMES.
local function CheckAuthorAccount()
    if not AUTHOR_OVERRIDE_ENABLED then return end
    if not AUTHOR_CHARACTER_NAMES[UnitName("player")] then return end
    if type(DHToolsAccountDB) ~= "table" then
        DHToolsAccountDB = {}
    end
    DHToolsAccountDB.isAuthorAccount = true
end

-- === Update notification (2026-08-24) ===
-- Peer-broadcast "a newer version exists" check, same guild-addon-message
-- pattern the module Sync.lua files already use (RegisterAddonMessagePrefix
-- + CHAT_MSG_ADDON), but intentionally lives here in Core.lua rather than
-- a module - it's about the whole addon's own version, not gated behind
-- any module toggle.
--
-- WHY A SEPARATE LAST_RELEASE_VERSION CONSTANT, NOT ns.VERSION: ns.VERSION
-- (above) reads the .toc's live "## Version:" metadata, which reflects
-- whatever's currently on disk - including a version bumped ahead of an
-- actual CurseForge/GitHub upload (e.g. to preview the About page before
-- publishing) or a locally-built test zip that happens to carry that same
-- bumped-but-unpublished number. Broadcasting THAT could tell a guildmate
-- to go download a version that doesn't exist anywhere yet. Chris's
-- explicit call (2026-08-24): this must only ever trigger off a version
-- that's actually been published. LAST_RELEASE_VERSION below is therefore
-- a separate literal, updated ONLY by hand as an explicit step of actually
-- running build-release-zip.ps1 (bump this alongside the .toc's own
-- Version line and the changelog) - build-test-zip.ps1 never touches
-- Core.lua at all, so a test build always announces whatever the last
-- REAL release was, never a number nobody can download.
local LAST_RELEASE_VERSION = "2.0.5"

local VER_PREFIX = "DHToolsVer"
-- In-memory only, never persisted - Chris's call: the "update available"
-- message shows once per session, and a UI reload or fresh login (which
-- both re-run this whole file) should reset that, which a plain local
-- automatically does without any extra code.
local hasShownUpdateMessage = false

local function VersionSend(text, channel, target)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(VER_PREFIX, text, channel, target)
    elseif SendAddonMessage then
        SendAddonMessage(VER_PREFIX, text, channel, target)
    end
end

local function VersionRegisterPrefix()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, VER_PREFIX)
    elseif RegisterAddonMessagePrefix then
        pcall(RegisterAddonMessagePrefix, VER_PREFIX)
    end
end

-- "X.Y.Z" -> three numbers, or nil if the string doesn't match that shape.
-- A malformed/garbage payload (or a friendly-fire prefix collision) should
-- never error or misfire a comparison - just get silently ignored.
local function ParseVersion(str)
    if type(str) ~= "string" then return nil end
    local major, minor, patch = str:match("^(%d+)%.(%d+)%.(%d+)$")
    if not major then return nil end
    return tonumber(major), tonumber(minor), tonumber(patch)
end

-- True if `other` is a strictly newer version than `mine`. Numeric
-- per-segment compare (2.10.0 > 2.9.0), not a string compare. Returns
-- false (never errors) if either side fails to parse.
local function IsNewerVersion(mine, other)
    local myMaj, myMin, myPatch = ParseVersion(mine)
    local oMaj, oMin, oPatch = ParseVersion(other)
    if not myMaj or not oMaj then return false end
    if oMaj ~= myMaj then return oMaj > myMaj end
    if oMin ~= myMin then return oMin > myMin end
    return oPatch > myPatch
end

-- Registered from the Boot section's CHAT_MSG_ADDON handler below.
local function VersionCheck_OnMessage(prefix, message, _channel, sender)
    if prefix ~= VER_PREFIX then return end
    local senderShort = sender and sender:match("^([^-]+)") or sender
    if senderShort == UnitName("player") then return end -- ignore our own echo

    if not hasShownUpdateMessage and IsNewerVersion(LAST_RELEASE_VERSION, message) then
        -- The peer's announced version is newer than ours - tell the player.
        hasShownUpdateMessage = true
        ns.Print(("A newer version (v%s) is available on CurseForge and GitHub."):format(message))
    elseif IsNewerVersion(message, LAST_RELEASE_VERSION) then
        -- The peer is the one on an older version. Reply directly (WHISPER,
        -- not GUILD) so they find out even if they logged in long before we
        -- did and never heard our own broadcast - no periodic re-broadcast
        -- needed, just one message in whichever direction is stale.
        VersionSend(LAST_RELEASE_VERSION, "WHISPER", sender)
    end
    -- Equal versions: neither branch fires, nothing to do.
end

-- Called once per login/reload (PLAYER_LOGIN, below), after a short random
-- delay so a raid-wide reset/relog doesn't produce a login-storm of
-- simultaneous guild-channel broadcasts.
local function VersionCheck_Announce()
    VersionRegisterPrefix()
    if IsInGuild and IsInGuild() then
        VersionSend(LAST_RELEASE_VERSION, "GUILD")
    end
end

-- === Guild-chat item lookup (2026-09-13) ===
-- Lets any guild member ask "what's this worth to Bavin" just by posting
-- "?" followed by an item link in guild chat - see
-- Modules\DHBavin\DH-Bavin-ChatLookup-Design.md for the full design. The
-- TRIGGER WATCHER lives here in Core, not behind the Bavin module's own
-- on/off gate, on purpose: the "nobody online has Bavin enabled"
-- fallback message can only be true and postable if the code noticing
-- the silence isn't itself the thing that would be missing. Only the
-- actual item-data lookup (ns.Bavin.TryClassifyLookup) requires the
-- Bavin module to be enabled - Core just detects the trigger, extracts
-- links, and runs the same claim-race machinery for either outcome.
--
-- PROTOCOL: one new addon-message type, "CLAIM|key", broadcast to GUILD
-- on its own prefix once a client decides to answer (whether with real
-- data or the fallback text) - the client that broadcasts it also posts
-- the actual human-readable reply straight to guild chat itself in the
-- same breath. `key` is built from {sender, a hash of the raw message,
-- link index} so two different questions (or the same question asked
-- twice) never collide, without needing any delimiter that could appear
-- inside the raw chat text itself (which, once an item link's color/
-- hyperlink escapes are in it, definitely contains "|").
--
-- CLAIM RACE: every client that reaches a decision for a given key waits
-- a random delay before broadcasting, standing down immediately if it
-- hears someone else's CLAIM for that key first - this IS the tie-break
-- (Chris's call: random, not deterministic). Real answers get first
-- crack (a short delay window); the "nobody's home" fallback is
-- deliberately given a LATER window so it only wins when no real answer
-- showed up in time. Total budget end-to-end is ~2 seconds (Chris's
-- number) - guild addon messages already round-trip in a small fraction
-- of that under normal conditions (same channel DH-Bavin's own SYNCREQ/
-- SYNCDATA relies on), so this is a comfortable multiple of real
-- latency, not a tight budget. An occasional duplicate reply from
-- near-simultaneous timers is accepted (Chris's call) rather than
-- engineered away entirely.
local LOOKUP_PREFIX = "DHToolsLookupV1"

-- Standard chat item-hyperlink shape: |cAARRGGBB|Hitem:...|h[Name]|h|r
local ITEM_LINK_PATTERN = "|c%x%x%x%x%x%x%x%x|Hitem:.-|h%[.-%]|h|r"

local ANSWER_DELAY_MIN, ANSWER_DELAY_MAX = 0.1, 1.2     -- real-data replies
local FALLBACK_DELAY_MIN, FALLBACK_DELAY_MAX = 1.5, 2.0 -- "nobody's running Bavin"
local LINK_STAGGER = 0.4 -- per link index, so one client winning 2+ of a
                          -- message's up-to-3 links doesn't fire multiple
                          -- SendChatMessage calls back-to-back (WoW's own
                          -- chat throttle can silently drop rapid sends)
local CHAT_MAX_LEN = 255 -- guild chat's own hard cap

local FALLBACK_TEXT = "Nobody online has the DH-Bavin module enabled. Please install DH-Tools and enable the DH-Bavin module."

-- key -> true once a CLAIM for it has been heard (including our own, the
-- instant we broadcast it) - in-memory only, cleared by relog/reload same
-- as everything else in this file. Not pruned; a session's worth of keys
-- is a few hundred bytes at most, not worth the complexity of expiring
-- entries for a table this short-lived.
local lookupClaims = {}

-- 2026-09-13 (Loopi): cache-miss retry for an item NONE of this client's
-- data has ever cached before - typically an item only a guildmate, not
-- you, has linked/seen. GetItemInfo's cache-miss behavior is to kick off
-- an async fetch and return nil immediately; the ANSWER delay (0.1-1.2s)
-- often isn't enough time for that FIRST-EVER fetch to complete, so a
-- client gave up and stayed completely silent - confirmed 2026-09-13
-- testing: replies worked for items Chris had already seen locally, went
-- silent (no debug text either) for items only guildmates had linked.
-- Fix: keep an itemID -> {list of {key, link}} table of "still waiting
-- on real data" lookups; GET_ITEM_INFO_RECEIVED (registered in the Boot
-- section) fires once the fetch actually completes, giving one more shot
-- at TryClassifyLookup before giving up for good. RETRY_TIMEOUT is
-- Chris's explicit call: 5 seconds is comfortably longer than a normal
-- round trip without leaving a listener effectively registered forever
-- for a bogus/never-resolving item ID.
local pendingLookups = {}
local RETRY_TIMEOUT = 5.0

-- The item ID is embedded directly in the hyperlink itself
-- (|Hitem:ITEMID:...|h[Name]|h|r) - no need to wait on GetItemInfo just
-- to know which item a GET_ITEM_INFO_RECEIVED event is even about.
local function ExtractItemID(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end

-- Drops one specific pending entry (matched by key, since several
-- different chat questions can reference the same item ID) once it's
-- been resolved one way or another - either GET_ITEM_INFO_RECEIVED
-- already gave it a shot, or RETRY_TIMEOUT expired without one ever
-- firing.
local function RemovePendingLookup(itemID, key)
    local list = pendingLookups[itemID]
    if not list then return end
    for i, entry in ipairs(list) do
        if entry.key == key then
            table.remove(list, i)
            break
        end
    end
    if #list == 0 then
        pendingLookups[itemID] = nil
    end
end

-- Called from ScheduleAnswerAttempt below when TryClassifyLookup still
-- returned nil at fire time - a genuine cache miss, not an error (errors
-- are already reported and treated as "give up", never retried). No-ops
-- silently if the link doesn't parse to an item ID (shouldn't happen,
-- given ITEM_LINK_PATTERN already matched it to get here).
local function RegisterPendingRetry(key, link)
    local itemID = ExtractItemID(link)
    if not itemID then return end
    pendingLookups[itemID] = pendingLookups[itemID] or {}
    table.insert(pendingLookups[itemID], { key = key, link = link })
    C_Timer.After(RETRY_TIMEOUT, function()
        RemovePendingLookup(itemID, key)
    end)
end

-- Deterministic DJB2-style hash so every client that received the exact
-- same CHAT_MSG_GUILD text computes the exact same key component, with
-- no delimiter collision risk against the raw (hyperlink-laden) message
-- text itself - this is coordination, not cryptography, same "good
-- enough for guild-social-trust" standard as the rest of this addon
-- suite's sync protocols.
local function SimpleHash(str)
    local hash = 5381
    for i = 1, #str do
        hash = (hash * 33 + str:byte(i)) % 4294967296
    end
    return hash
end

local function LookupSend(text)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(LOOKUP_PREFIX, text, "GUILD")
    elseif SendAddonMessage then
        SendAddonMessage(LOOKUP_PREFIX, text, "GUILD")
    end
end

local function LookupRegisterPrefix()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, LOOKUP_PREFIX)
    elseif RegisterAddonMessagePrefix then
        pcall(RegisterAddonMessagePrefix, LOOKUP_PREFIX)
    end
end

-- Never drops the link itself - truncates the trailing text (with an
-- ellipsis) if the two together would exceed guild chat's 255-char cap.
-- Long item names plus a verbose spreadsheet detail line can occasionally
-- get close to this.
local function TruncateReply(text)
    if #text <= CHAT_MAX_LEN then return text end
    local budget = CHAT_MAX_LEN - 3
    if budget < 1 then return text:sub(1, CHAT_MAX_LEN) end
    return text:sub(1, budget) .. "..."
end

local function LookupOnMessage(prefix, message, _channel, _sender)
    if prefix ~= LOOKUP_PREFIX then return end
    local msgType, key = message:match("^(%u+)|(.*)$")
    if msgType == "CLAIM" and key then
        lookupClaims[key] = true
    end
end

-- Registered from the Boot section's GET_ITEM_INFO_RECEIVED handler
-- below. `success == false` means the fetch failed outright (e.g. a
-- bogus item ID) - nothing to retry against, so those are ignored.
local function LookupOnItemInfoReceived(itemID, success)
    if not success then return end
    local list = pendingLookups[itemID]
    if not list then return end
    pendingLookups[itemID] = nil
    for _, entry in ipairs(list) do
        if not lookupClaims[entry.key] and ns.Bavin and ns.Bavin.TryClassifyLookup then
            local ok, result = pcall(ns.Bavin.TryClassifyLookup, entry.link)
            if ok and result then
                lookupClaims[entry.key] = true
                LookupSend("CLAIM|" .. entry.key)
                SendChatMessage(TruncateReply(result), "GUILD")
            elseif not ok then
                ns.Print("|cffff3333[lookup debug] TryClassifyLookup errored (retry):|r " .. tostring(result))
            end
        end
    end
end

-- Schedules this client's attempt to answer `key`. Stands down (does
-- nothing) if any client's CLAIM for this key - including one heard
-- while waiting - arrives first. Winning means: broadcast the CLAIM (so
-- every other waiting client stands down too), then post `replyText` to
-- guild chat, in that order.
local function ScheduleLookupAttempt(key, delayMin, delayMax, replyText)
    local delay = delayMin + math.random() * (delayMax - delayMin)
    C_Timer.After(delay, function()
        if lookupClaims[key] then return end
        lookupClaims[key] = true
        LookupSend("CLAIM|" .. key)
        SendChatMessage(TruncateReply(replyText), "GUILD")
    end)
end

-- 2026-09-13 (Loopi) BUGFIX: classification used to be evaluated eagerly,
-- the instant the trigger message arrived (t=0), with only the resulting
-- STRING (or the decision to fall back) carried into the delayed timer.
-- An item just linked in chat is very often a genuine GetItemInfo cache
-- miss at that exact instant - the same gap Tooltip.lua's own
-- OnTooltipSetItem has to retry around (see that file's header comment) -
-- so evaluating at t=0 meant giving up on a real answer before the
-- server round-trip had any real chance to complete, which is exactly
-- what Chris hit testing solo: TryClassifyLookup(link) returned nil every
-- time because GetItemInfo hadn't resolved yet, so this client fell
-- straight through to the fallback path despite Bavin being enabled.
-- Fix: defer the actual GetItemInfo/GetItemPoints call into the timer
-- callback itself, so it runs at FIRE time (after the random ANSWER
-- delay has elapsed) instead of at trigger time - giving the item up to
-- ~1.2 real seconds to finish caching first, which resolves it in
-- practice for items this client has already cached before (its own
-- bags/quests/etc.). Still not enough on its own for an item NONE of
-- this client's data has ever cached (typically something only a
-- guildmate has seen) - a genuine nil result here (not an error) now
-- registers a bounded GET_ITEM_INFO_RECEIVED retry instead of giving up
-- outright; see the pending-retry section above lookupClaims for the
-- full story.
local function ScheduleAnswerAttempt(key, delayMin, delayMax, link)
    local delay = delayMin + math.random() * (delayMax - delayMin)
    C_Timer.After(delay, function()
        if lookupClaims[key] then return end
        local reply
        local hadError = false
        if ns.Bavin and ns.Bavin.TryClassifyLookup then
            -- pcall so a hidden Lua error (WoW's Lua-error display is
            -- off by default) surfaces here instead of vanishing.
            local ok, result = pcall(ns.Bavin.TryClassifyLookup, link)
            if ok then
                reply = result
            else
                hadError = true
                ns.Print("|cffff3333[lookup debug] TryClassifyLookup errored:|r " .. tostring(result))
            end
        end
        if reply then
            lookupClaims[key] = true
            LookupSend("CLAIM|" .. key)
            SendChatMessage(TruncateReply(reply), "GUILD")
        elseif not hadError then
            -- Genuine cache miss, not an error - register for a real
            -- shot once GET_ITEM_INFO_RECEIVED actually fires instead of
            -- giving up here. Does NOT fall through to the fallback text
            -- itself (that message specifically means "nobody has Bavin
            -- enabled," which isn't true here) - only a client without
            -- Bavin enabled runs the fallback race at all.
            RegisterPendingRetry(key, link)
        end
    end)
end

local function LookupHandleTrigger(key, link, linkIndex)
    if lookupClaims[key] then return end
    local offset = (linkIndex - 1) * LINK_STAGGER
    local bavinEnabled = ns.IsModuleEnabled("bavin")

    if bavinEnabled and ns.Bavin and ns.Bavin.TryClassifyLookup then
        ScheduleAnswerAttempt(key, ANSWER_DELAY_MIN + offset, ANSWER_DELAY_MAX + offset, link)
        return
    end

    ScheduleLookupAttempt(key, FALLBACK_DELAY_MIN + offset, FALLBACK_DELAY_MAX + offset,
        link .. " " .. FALLBACK_TEXT)
end

-- Guild-scoped like the rest of DH-Bavin's own permission model (k-0019:
-- an off-guild alt must never act on Death Happens' own Bavin data, or
-- announce anything into some OTHER guild's chat about it). Refuses to
-- run at all if DH-Bavin's Core.lua somehow isn't loaded.
local function LookupIsInTargetGuild()
    return ns.Bavin and ns.Bavin.IsInTargetGuild and ns.Bavin.IsInTargetGuild()
end

local function LookupTrigger_OnChatMsgGuild(message, sender)
    if type(message) ~= "string" or message:sub(1, 1) ~= "?" then return end
    if not LookupIsInTargetGuild() then return end

    local senderShort = (ns.Bavin and ns.Bavin.NormalizeName and ns.Bavin.NormalizeName(sender)) or sender
    local hash = SimpleHash(message)
    local linkIndex = 0
    for link in message:gmatch(ITEM_LINK_PATTERN) do
        linkIndex = linkIndex + 1
        if linkIndex > 3 then break end
        local key = (senderShort or "?") .. ":" .. linkIndex .. ":" .. hash
        LookupHandleTrigger(key, link, linkIndex)
    end
end

-- Sets up a top-level DH-Tools window with the properties every one of them
-- needs: proper click-to-raise behavior, a guaranteed-opaque background
-- (rather than relying entirely on the template's own backdrop), and
-- dragging scoped to a title-bar-height strip only (registering drag on the
-- whole frame breaks addons like MoveAny that add their own drag handling
-- on top of whatever a frame already exposes). Ported from DH-Air's
-- Core.lua (DHAir:InitStandaloneWindow) - same rationale applies here.
-- Every DH-Tools window should call this once, right after creating its frame.
function ns.InitStandaloneWindow(targetFrame, rightInset)
    targetFrame:SetToplevel(true)

    local bg = targetFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.9)

    targetFrame:SetMovable(true)
    targetFrame:EnableMouse(true)

    local dragRegion = CreateFrame("Frame", nil, targetFrame)
    dragRegion:SetPoint("TOPLEFT", 0, 0)
    dragRegion:SetPoint("TOPRIGHT", -(rightInset or 28), 0) -- leaves room for a close button
    dragRegion:SetHeight(24)
    dragRegion:EnableMouse(true)
    dragRegion:RegisterForDrag("LeftButton")
    dragRegion:SetScript("OnDragStart", function() targetFrame:StartMoving() end)
    dragRegion:SetScript("OnDragStop", function() targetFrame:StopMovingOrSizing() end)
    return dragRegion
end

-- Returns true/false for whether `key` is currently enabled: saved state
-- if one exists, else the module's own default.
function ns.IsModuleEnabled(key)
    local saved = ns.db.modules[key]
    if saved ~= nil then return saved end
    local def = ns.modules[key]
    return def ~= nil and def.default or false
end

function ns.SetModuleEnabled(key, enabled)
    local def = ns.modules[key]
    if not def then
        ns.Print("Unknown module: '" .. tostring(key) .. "'. Type /dht list.")
        return
    end
    local wasEnabled = ns.IsModuleEnabled(key)
    ns.db.modules[key] = enabled
    if enabled and not wasEnabled then
        if def.OnEnable then def.OnEnable() end
        ns.Print(def.name .. " enabled.")
    elseif not enabled and wasEnabled then
        if def.OnDisable then def.OnDisable() end
        ns.Print(def.name .. " disabled.")
    end
end

local function ActivateEnabledModules()
    for _, key in ipairs(ns.moduleOrder) do
        if ns.IsModuleEnabled(key) then
            local def = ns.modules[key]
            if def.OnEnable then def.OnEnable() end
        end
    end
end

local function ListModules()
    ns.Print(("Modules (v%s):"):format(ns.VERSION))
    for _, key in ipairs(ns.moduleOrder) do
        local def = ns.modules[key]
        local state = ns.IsModuleEnabled(key) and "|cff33ff99on|r" or "|cffff3333off|r"
        ns.Print(("  %s - %s (%s)"):format(key, def.name, state))
    end
end

-- === Boot ===
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("CHAT_MSG_GUILD") -- guild-chat item lookup trigger, see above
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED") -- guild-chat lookup cache-miss retry, see above
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local arg1 = ...
        if arg1 == ADDON_NAME then
            ns.InitDB()
        end
    elseif event == "PLAYER_LOGIN" then
        CheckAuthorAccount()
        ActivateEnabledModules()
        if ns.Minimap_Init then
            ns.Minimap_Init()
        end
        ns.Print(("loaded (v%s). Type /dht help for commands."):format(ns.VERSION))
        C_Timer.After(math.random(5, 20), VersionCheck_Announce)
        LookupRegisterPrefix()
    elseif event == "CHAT_MSG_ADDON" then
        VersionCheck_OnMessage(...)
        LookupOnMessage(...)
    elseif event == "CHAT_MSG_GUILD" then
        LookupTrigger_OnChatMsgGuild(...)
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        LookupOnItemInfoReceived(...)
    end
end)

-- === Slash commands ===
SLASH_DHTOOLS1 = "/dht"
SLASH_DHTOOLS2 = "/dhtools"

SlashCmdList["DHTOOLS"] = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "list" or cmd == "" then
        ListModules()
    elseif cmd == "on" then
        ns.SetModuleEnabled(rest, true)
    elseif cmd == "off" then
        ns.SetModuleEnabled(rest, false)
    elseif cmd == "config" or cmd == "options" then
        if ns.Config_Open then
            ns:Config_Open("Tools")
        else
            ns.Print("Config UI didn't load correctly.")
        end
    elseif cmd == "help" then
        ns.Print(("Commands (v%s):"):format(ns.VERSION))
        ns.Print("  /dht list          - show modules and their on/off state")
        ns.Print("  /dht on <module>   - enable a module")
        ns.Print("  /dht off <module>  - disable a module")
        ns.Print("  /dht config        - open the config window")
        ns.Print("  /dht help          - show this list")
        ns.Print("Each module keeps its own slash commands too (e.g. /mm for Mob Marker).")
    else
        ns.Print("Unknown command: '" .. cmd .. "'. Type /dht help.")
    end
end
