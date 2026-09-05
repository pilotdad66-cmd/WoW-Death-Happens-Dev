-- DH-Tools: Modules\DHDanger\Core.lua
-- "Danger" module - warns you when a mob that can catch you by surprise
-- is nearby.
--
-- SCOPE OF THIS FILE (v0.x, 2026-08-07)
-- Trigger and alert ONLY, against a list you build yourself in-game with
-- /dhdanger add. The shipped danger database (DangerData.lua, 543 NPCs,
-- and Curation.lua's judgement overlay) is NOT loaded yet and is not in
-- the .toc.
--
-- WHY, because it looks backwards: the milestone plan had M0 build the
-- dataset before M1 built detection, and several sessions went into 543
-- NPCs, a curation pipeline and a 133-row draft that no runtime code has
-- ever read. None of it is proven, because nothing consumes it. Loopi's
-- call, 2026-08-07: get the trigger and the alert right against any mob
-- at all, then decide which mobs deserve one. A list is easy to swap; a
-- detection model that doesn't warn you in time is the whole project.
--
-- This also absorbs Q2 (does a nameplate warn you early enough?). Rather
-- than a separate measurement addon, /dhdanger debug on times the gap
-- between the alert firing and the mob actually hitting you, so the
-- answer falls out of ordinary use. See claude\DH-Danger\STATUS.md.
--
-- DETECTION - all 5 of RareScanner's trigger events (2026-08-08), no
-- distance math anywhere (k-0021). Classic Era has no proximity API and
-- no distance-to-unit call, and the ways around that are protected
-- (k-0010). Do not go looking again.
--
-- Three require you to have already spotted the mob yourself - a
-- nameplate rendered, your cursor over its model, or it being your
-- target. All three are therefore subject to k-0026 (nameplates need
-- the mob in your camera's view, not just in range) to some degree:
--   * NAME_PLATE_UNIT_ADDED - ~20yd, CVar-raisable to ~41. Needs enemy
--     nameplates ON (k-0022, checked below) AND the mob rendered on
--     screen (k-0026).
--   * UPDATE_MOUSEOVER_UNIT - fires wherever your cursor sits over a
--     unit's model. Does NOT depend on the nameplate CVar at all, but
--     still needs the model rendered on screen - so it's a second way
--     into the same k-0026 limitation, not a way around it.
--   * PLAYER_TARGET_CHANGED - fires when you click or Tab-target
--     something. Same CVar-independence as mouseover. OPEN QUESTION,
--     not yet tested: whether Tab-targeting (TargetNearestEnemy) can
--     select something outside the camera's view the way clicking
--     obviously can't - if so this is a partial answer to k-0026, not
--     just a third instance of it. Don't assume either way; test it.
--
-- Two do NOT require the mob to be on screen at all:
--   * CHAT_MSG_MONSTER_YELL / CHAT_MSG_MONSTER_EMOTE - ~300yd, chat
--     events, so camera facing is irrelevant. Per k-0025 the message
--     carries the mob's GUID (arg12), so the npcID comes free - no
--     curated "does it yell" flag is needed or wanted. Per k-0026 this
--     is currently the ONLY channel that can warn about something
--     outside your view.
--   * LOOT_OPENED - fires when you open a loot window. The mob is
--     already dead, so this deliberately does NOT alert (see OnLootOpened
--     below) - it records a sighting instead, and is the most precisely
--     located source there is, since you are standing on the corpse.
--     That history (account-wide, clustered - see ns.RecordSighting) is
--     what a zone-entry fallback and a guild broadcast both need to
--     answer k-0026.

local DHTools = DHTools
DHTools.Danger = DHTools.Danger or {}
local ns = DHTools.Danger

-- The generated data files use the ADDON-wide namespace (local _, ns =
-- ...), not DHTools.Danger, so when they join the .toc they land here and
-- not on this module's own table. Captured now so the bridge exists and
-- is obvious; nil until those files are actually loaded.
local _, addonNS = ...
ns.addonNS = addonNS

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99DH-Danger:|r " .. msg)
end

-- Q3 (SavedVariables scope) RESOLVED for the manual list, 2026-08-08 -
-- see InitDB's account-wide-migration comment below. This stale note
-- used to describe the old per-character placement; left removed rather
-- than corrected in place so nobody re-reads it as still-open.
-- Alert-policy category keys used by settings.alertFor/alwaysAlertFor
-- below. Deliberately its own small taxonomy, not a reuse of either
-- existing schema: it mixes 3 keys from WoW's own UnitClassification()
-- (elite/rare/rareelite - see DH-Danger-Design.md's tri-state table) with
-- 2 from DangerList.lua's hand-curated `surprise` categories (guard,
-- pack/roamer) - because that's the exact 5-item list Loopi asked for on
-- the config page (2026-08-08), not because the two source vocabularies
-- were ever meant to merge. ORDER matches the order Loopi gave it in, and
-- CreateDangerPanel (Config.lua) renders rows in this same order.
ns.ALERT_CATEGORIES = {
    { key = "elite",     label = "Elites" },
    { key = "rare",      label = "Rares" },
    { key = "rareelite", label = "Rare Elites" },
    { key = "guard",     label = "Horde Guards" },
    { key = "pack",      label = "Roaming Packs" },
}

function ns.InitDB()
    if type(DHToolsDB) ~= "table" then DHToolsDB = {} end
    if type(DHToolsDB.danger) ~= "table" then DHToolsDB.danger = {} end
    local db = DHToolsDB.danger
    -- NOTE: db.sightings USED to live here (per-character). It moved to
    -- DHToolsAccountDB.danger.sightings on 2026-08-08 - see the account
    -- block below for why, and for why the old per-character table is
    -- deliberately left on disk untouched rather than migrated.
    if db.sound == nil then db.sound = true end
    if db.debug == nil then db.debug = false end
    -- Zone-entry warning (2026-08-08). Per-character on purpose: it is
    -- a preference for THIS character, unlike the manual list and the
    -- sighting history, which are facts about the account and world.
    if db.zoneWarn == nil then db.zoneWarn = true end
    -- Hides gray-level (per ns.LevelColor) curated threats from the
    -- automatic zone-entry warning specifically - `/dhdanger zone`
    -- (verbose) always shows everything regardless of this setting
    -- (Loopi, 2026-08-14). Per-character, same reasoning as zoneWarn.
    if db.zoneWarnHideGray == nil then db.zoneWarnHideGray = true end

    -- Peer-relay broadcast (k-0026/k-0030, design finalized 2026-08-20
    -- with Loopi - see Sync.lua). Gates SENDING your own detections
    -- only, never receiving. Per-character, same reasoning as zoneWarn -
    -- a preference for THIS character, not a fact about the account or
    -- world. Default ON (Loopi).
    if db.shareSync == nil then db.shareSync = true end

    -- Alert policy settings (2026-08-08, Loopi - "start adding the
    -- choices we discussed"). Category/level choices drive the
    -- zone-entry warning AND, since 2026-08-18, the curated half of live
    -- proximity alerts (ns.IsDangerous) - see that function for why.
    -- They still do NOT gate a manually-added (/dhdanger add) mob: the
    -- manual list has no classification/level data to filter on and
    -- always alerts unconditionally, same as before.
    if type(db.settings) ~= "table" then db.settings = {} end
    local s = db.settings
    -- alertOn: "any" | "below" | "atOrAbove". Default "below" per Loopi.
    if s.alertOn == nil then s.alertOn = "below" end
    -- Only meaningful when alertOn == "below" - how many levels below the
    -- player's own level still alerts. Default 3 per Loopi.
    if s.belowLevels == nil then s.belowLevels = 3 end
    if type(s.alertFor) ~= "table" then s.alertFor = {} end
    if type(s.alwaysAlertFor) ~= "table" then s.alwaysAlertFor = {} end
    for _, cat in ipairs(ns.ALERT_CATEGORIES) do
        if s.alertFor[cat.key] == nil then
            s.alertFor[cat.key] = true -- default: all ON, per Loopi
        end
        if s.alwaysAlertFor[cat.key] == nil then
            -- Default: only rareelite and guard ON, per Loopi ("Rare
            -- Elites and Horde Guards on, the others off").
            s.alwaysAlertFor[cat.key] = (cat.key == "rareelite" or cat.key == "guard")
        end
    end

    -- Account-wide manual danger list (2026-08-08, Loopi): "/dhdanger
    -- add/remove/list" stays, but its data becomes its OWN account-wide
    -- set that a new DH-Tools version never overwrites - separate from
    -- the curated list (DangerData.lua + Curation.lua), which DOES get
    -- replaced by every release, because it ships as addon source, not
    -- SavedVariables. Lives in DHToolsAccountDB (already declared
    -- account-wide in the .toc - previously used only for the
    -- author-account flag, see Core.lua's IsAuthorAccount) under its own
    -- `.danger` sub-table, the same "one shared table, module-keyed
    -- sub-tables" convention DHToolsDB already uses per-character.
    -- 2026-08-08 (Loopi): explicitly NO migration from the old
    -- per-character db.testList - this list starts blank once the
    -- module opens up beyond alpha testing (DH-Danger is an integrated
    -- DH-Tools module, not its own versioned release, so "blank at
    -- release" means "blank when Loopi and Loopi are ready for anyone
    -- to use it," not a literal version tag). Whatever's in the old
    -- alpha-era per-character slot is simply ignored from here on; not
    -- read, not copied, not cleared. An earlier version of this
    -- function did migrate it - removed same day, before it ever
    -- shipped to anyone else.
    if type(DHToolsAccountDB) ~= "table" then DHToolsAccountDB = {} end
    if type(DHToolsAccountDB.danger) ~= "table" then DHToolsAccountDB.danger = {} end
    local acct = DHToolsAccountDB.danger
    -- Named manualList, not testList: despite being built and exercised
    -- during alpha testing, this list is a permanent feature meant to
    -- carry into the release version too, not a development artefact to
    -- be renamed or dropped later - the name should say so from the
    -- start rather than implying otherwise.
    if type(acct.manualList) ~= "table" then acct.manualList = {} end

    -- Sighting history, moved here from per-character DHToolsDB.danger
    -- (2026-08-08, Loopi). Two reasons, and only the second is the one
    -- that actually forced it:
    --   1. Where a mob lives is a fact about the WORLD, identical for
    --      every character on the account. Whether it's dangerous to YOU
    --      is a level filter applied at read time. Those are separable,
    --      and storing them together threw the world half away.
    --   2. A fresh alt started with an empty table - and a fresh alt is
    --      exactly the character most likely to die to a surprise. The
    --      data was absent precisely when it mattered most.
    -- Same NO-MIGRATION rule as manualList above: the old per-character
    -- db.sightings is left exactly where it is, not read, not copied,
    -- not cleared. It holds one alpha session's worth of single-point
    -- records in a shape this store no longer uses (see ns.RecordSighting).
    if type(acct.sightings) ~= "table" then acct.sightings = {} end

    ns.db = db
    ns.acctDB = acct
    return db
end

local COOLDOWN = 20     -- seconds before the same mob may alert again

local lastAlert = {}    -- guid -> GetTime() of its last alert
local pending   = {}    -- guid -> {t=, x=, y=}, for the debug lead-time timer
local playerGUID

-- UnitPosition returns Y, X, Z, instanceID - note the order - and nil
-- inside instances/battlegrounds. Callers must tolerate nil rather than
-- defaulting to 0, which would silently report 0-yard movement and make
-- "you walked into it" indistinguishable from "it came to you".
local function PlayerPos()
    local y, x = UnitPosition("player")
    if not x or not y then return nil end
    return x, y
end
ns.PlayerPos = PlayerPos -- Sync.lua needs this for the receive-side distance check

-- Classic Era UnitPosition is in yards directly (not the 0-1 normalised
-- fraction some other APIs use) - plain Euclidean distance is correct.
local function Dist(x1, y1, x2, y2)
    if not (x1 and y1 and x2 and y2) then return nil end
    local dx, dy = x2 - x1, y2 - y1
    return math.sqrt(dx * dx + dy * dy)
end
ns.Dist = Dist -- Sync.lua needs this for the receive-side distance check

-- Same derivation the yell path uses, and the reason the danger list is
-- keyed by npcID rather than name: a GUID resolves to an ID, never to a
-- name, and names are neither unique nor localisation-stable.
local function NpcID(guid)
    if not guid then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
    return tonumber(id)
end

-- k-0022: NAME_PLATE_UNIT_ADDED never fires with enemy nameplates off, so
-- the module would look like it was working while detecting nothing. That
-- is the worst possible failure for a safety tool - it builds confidence
-- it hasn't earned - so it is reported loudly at login and re-checked on
-- CVAR_UPDATE, because the player can press V mid-session. Never force
-- the CVar: silently changing someone's UI settings is its own bug.
local function NameplatesOn()
    return GetCVar("nameplateShowEnemies") == "1"
end

local warnedNoPlates = false
local function CheckPrerequisite(announceWhenFine)
    if not NameplatesOn() then
        if not warnedNoPlates then
            warnedNoPlates = true
            ns.Print("|cffff2020enemy nameplates are OFF|r - press V. "
                .. "Until they are on, passive proximity detection is off - "
                .. "you'll still get alerts from yells/emotes and anything "
                .. "you mouseover or target yourself, just not from a mob "
                .. "simply walking near you.")
        end
    elseif warnedNoPlates then
        warnedNoPlates = false
        ns.Print("enemy nameplates are on again - proximity detection active.")
    elseif announceWhenFine then
        warnedNoPlates = false
    end
end

-- Dangerous if EITHER: it's on the account-wide manual list built with
-- /dhdanger add (the one data set a player builds by hand - see InitDB's
-- migration note for where this used to live), OR it's in the shipped
-- curated list and passes the same category/level gate the zone-entry
-- warning already uses (ns.EntryWarns) - two independent sources OR'd
-- together into one gate, not one replacing the other (2026-08-18,
-- Loopi: "all features should be able to incorporate the curated list
-- from now on").
--
-- Uses the curated entry's own `level` field, not a live UnitLevel() off
-- the triggering unit (2026-08-18, Loopi, after weighing it): curated
-- levels are recorded at the mob's HIGHEST seen level, so the only
-- failure mode is alerting a LITTLE EARLY for a lower-level spawn of the
-- same mob that wouldn't otherwise clear the level filter yet - never
-- staying silent for one that spawned higher than curated. That's the
-- right asymmetry for a safety tool, and it also means one code path
-- covers all five triggers uniformly - yell/emote hand ns.Alert a GUID
-- with no unit token, so a live level wouldn't even be available there.
function ns.IsDangerous(npcID)
    if not npcID or not ns.acctDB then return false end
    if ns.acctDB.manualList[npcID] then return true end
    local npcs = ns.Curated and ns.Curated()
    local entry = npcs and npcs[npcID]
    if not entry then return false end
    return ns.EntryWarns(entry, UnitLevel("player"))
end

-- Sighting history for every listed mob confirmed by ANY detection path
-- (all live triggers call this, plus OnLootOpened for the dead-mob case
-- that skips ns.Alert entirely). Account-wide as of 2026-08-08. Nothing
-- consumes it yet - it is the data a zone-entry fallback and a future
-- guild broadcast both need, and it is free to collect now rather than
-- backfilled from nothing later.
--
-- WHY CLUSTERS AND NOT A LIST OF RAW POINTS (2026-08-08, Loopi):
-- this table used to hold exactly ONE record per npcID, overwritten on
-- every detection. Three places called it "position history"; keyed and
-- overwritten that way it could never be one. An append-only raw list is
-- the obvious fix and the wrong one - a player standing still logs
-- near-identical points and crowds out genuinely different locations,
-- and two players' lists can't be merged without re-deduping anyway.
-- Rounding to a coarse cell and counting hits bounds growth, makes a
-- repeatedly-confirmed spawn point visibly different from a one-off, and
-- merges cleanly - which matters, because these records are meant to be
-- broadcast to guildmates (STATUS.md). k-0030: Unitscan Hardcore's
-- shipped location DB independently arrived at the same shape.
--
-- WHAT A SPOT ACTUALLY MEANS: PlayerPos() is where the PLAYER stood, not
-- where the mob was. `acc` is what makes that honest - a yell heard at
-- ~300yd and a corpse looted at 0yd are not the same claim, and before
-- this field they were stored identically and indistinguishably. Any
-- consumer MUST filter on `acc`: a zone-entry warning built from
-- 300-yard points would fire in the wrong half of the zone.
--
--   ns.acctDB.sightings[npcID] = {
--       name = "Stitches", last = "...", noPos = 0,
--       spots = { {x=,y=,zone=,subzone=,n=,acc=,src=,first=,last=}, ... },
--   }
local GRID      = 20    -- yards per cell; ~nameplate range, so two hits
                        -- in one cell mean "the same place"
local MAX_SPOTS = 25    -- per mob; least-confirmed + oldest dropped first

-- Approximate radius (yards) the mob was actually within, given the
-- channel that detected it. Ranges per k-0021 / k-0022 / k-0026.
local SRC_ACCURACY = {
    loot      = 5,      -- standing on the corpse
    mouseover = 40,
    target    = 40,
    nameplate = 41,     -- ~20 default, up to ~41 with the CVar raised
    yell      = 300,    -- chat event - carries no distance guarantee
    emote     = 300,
    relayed   = 50,     -- k-0026/k-0030: second-hand + cell-rounded, so
                        -- deliberately worse than any direct short-range
                        -- source it could have originated from
}

local function Cell(v) return math.floor(v / GRID + 0.5) * GRID end
-- Sync.lua's broadcast/receive gating reuses these exact three rather
-- than inventing a second coordinate/accuracy scheme.
ns.GRID = GRID
ns.SRC_ACCURACY = SRC_ACCURACY
ns.Cell = Cell

function ns.RecordSighting(npcID, name, source)
    if not npcID or not ns.acctDB then return end
    if type(ns.acctDB.sightings) ~= "table" then ns.acctDB.sightings = {} end

    local rec = ns.acctDB.sightings[npcID]
    if not rec then
        rec = { spots = {} }
        ns.acctDB.sightings[npcID] = rec
    end
    if type(rec.spots) ~= "table" then rec.spots = {} end
    if name then rec.name = name end

    local now = date and date("%Y-%m-%d %H:%M") or nil
    rec.last = now

    -- No position inside instances/BGs (see PlayerPos). Record that we
    -- saw it at all rather than dropping the observation silently, but
    -- never invent a spot for it - a spot with no coordinates would be
    -- indistinguishable from a real one to every future consumer.
    local x, y = PlayerPos()
    if not x or not y then
        rec.noPos = (rec.noPos or 0) + 1
        return
    end

    local cx, cy = Cell(x), Cell(y)
    local acc = SRC_ACCURACY[source or ""] or 300

    for _, sp in ipairs(rec.spots) do
        if sp.x == cx and sp.y == cy then
            sp.n    = (sp.n or 1) + 1
            sp.last = now
            -- Keep the BEST accuracy ever achieved at this cell, not the
            -- most recent: once a nameplate has confirmed a spot, a later
            -- yell heard from the same cell doesn't make it vaguer.
            if acc < (sp.acc or 300) then sp.acc, sp.src = acc, source end
            return
        end
    end

    if #rec.spots >= MAX_SPOTS then
        -- Evict the least useful: fewest confirmations, ties broken by
        -- oldest last-seen.
        local worst, wi
        for i, sp in ipairs(rec.spots) do
            if not worst
                or (sp.n or 1) < (worst.n or 1)
                or ((sp.n or 1) == (worst.n or 1) and (sp.last or "") < (worst.last or "")) then
                worst, wi = sp, i
            end
        end
        if wi then table.remove(rec.spots, wi) end
    end

    table.insert(rec.spots, {
        x = cx, y = cy,
        zone    = GetRealZoneText and GetRealZoneText() or nil,
        subzone = GetSubZoneText and GetSubZoneText() or nil,
        n = 1, acc = acc, src = source,
        first = now, last = now,
    })
end

-- source is one of "nameplate" (~20yd), "mouseover", "target", "yell" or
-- "emote" (~300yd, chat-based). Shown because they mean very different
-- things about how much room you have - see the file header for which
-- ones k-0026 limits and which don't.
function ns.Alert(guid, npcID, name, source)
    if not ns.IsDangerous(npcID) then return false end

    local now = GetTime()
    local key = guid or npcID
    if lastAlert[key] and (now - lastAlert[key]) < COOLDOWN then
        return false
    end
    lastAlert[key] = now
    -- source is passed through so the spot records how precisely it was
    -- actually located (SRC_ACCURACY) - a yell is not a nameplate.
    ns.RecordSighting(npcID, name, source)

    -- Peer-relay broadcast (k-0026/k-0030) - only the three camera-gated
    -- sources are ever relayed; yell/emote already carry ~300yd and
    -- aren't camera-gated, loot is a dead mob. A relayed alert re-enters
    -- here with source="relayed", which matches none of these three, so
    -- this can never itself trigger a second broadcast - no separate
    -- loop guard needed.
    if guid and ns.BroadcastSighting
        and (source == "nameplate" or source == "mouseover" or source == "target") then
        ns.BroadcastSighting(guid, npcID, source)
    end

    local label = name or ns.acctDB.manualList[npcID] or ("npc " .. tostring(npcID))
    ns.Print(string.format("|cffff2020DANGER:|r |cffffff00%s|r nearby (%s)", label, source))

    if ns.db.sound then
        -- Master channel so it is audible even with sound effects turned
        -- down. A warning you can't hear is not a warning.
        if SOUNDKIT and SOUNDKIT.RAID_WARNING then
            PlaySound(SOUNDKIT.RAID_WARNING, "Master")
        else
            PlaySound(8959, "Master")
        end
    end

    if ns.db.debug then
        local x, y = PlayerPos()
        pending[guid or ""] = { t = now, x = x, y = y }
        ns.Print(string.format("|cff888888[debug] %s via %s - stand still to measure real lead time|r", label, source))
    end
    return true
end

-- ---------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------
local f = CreateFrame("Frame")

-- Shared filter for any unit-TOKEN-based detection path (nameplate,
-- mouseover, target). All three can hand you a corpse - you can mouseover
-- or still have targeted something mid-loot - so the dead check applies
-- to all of them uniformly, not just nameplates.
local function LiveHostileNpc(unit)
    if not unit or not UnitExists(unit) then return nil end
    local guid = UnitGUID(unit)
    if not guid or UnitIsPlayer(unit) or not UnitCanAttack("player", unit) then return nil end
    if UnitIsDead(unit) then return nil end
    return guid, NpcID(guid), UnitName(unit)
end

local function OnNameplate(unit)
    local guid, npcID, name = LiveHostileNpc(unit)
    if guid then ns.Alert(guid, npcID, name, "nameplate") end
end

-- Independent of the nameplate CVar entirely - this fires off whatever
-- your cursor sits over in the 3D world, not off a rendered nameplate
-- widget. Still needs the model rendered on screen, so it's a second way
-- into k-0026's limitation, not a way around it.
local function OnMouseover()
    local guid, npcID, name = LiveHostileNpc("mouseover")
    if guid then ns.Alert(guid, npcID, name, "mouseover") end
end

-- Same CVar-independence as mouseover. Whether Tab-targeting can select
-- something outside the camera's view (unlike a mouse click) is an open
-- question - see the file header - so don't assume this one is limited
-- the same way until it's actually tested.
local function OnTargetChanged()
    local guid, npcID, name = LiveHostileNpc("target")
    if guid then ns.Alert(guid, npcID, name, "target") end
end

-- k-0025: arg12 of CHAT_MSG_MONSTER_YELL/EMOTE is the speaker's GUID, so
-- the npcID is free and no per-mob "yells" flag is needed. Per k-0026
-- this is the only channel that doesn't need the mob on screen at all.
local function OnMonsterChat(source, ...)
    local guid = select(12, ...)
    local name = select(2, ...)
    local npcID = NpcID(guid)
    if npcID then ns.Alert(guid, npcID, name, source) end
end

-- LOOT_OPENED - deliberately does NOT call ns.Alert(). Whatever's in the
-- loot window is already dead; a "DANGER" banner would be announcing a
-- threat that's already over, and that's the kind of alert that trains
-- people to ignore the addon. What it's good for instead: a confirmed,
-- precise sighting location, recorded the same way a live alert would be
-- - gathered for free from something players already do constantly.
local function OnLootOpened()
    local n = GetNumLootItems and GetNumLootItems() or 0
    for i = 1, n do
        if LootSlotHasItem(i) then
            local destGUID = GetLootSourceInfo(i)
            if destGUID then
                local kind, _, _, _, _, id = strsplit("-", destGUID)
                if kind == "Creature" then
                    local npcID = tonumber(id)
                    if ns.IsDangerous(npcID) then
                        local name = ns.acctDB.manualList[npcID]
                        -- "loot" is the most precise source there is:
                        -- you are standing on the corpse.
                        ns.RecordSighting(npcID, name, "loot")
                        if ns.db.debug then
                            ns.Print(string.format(
                                "|cff888888[debug] recorded a sighting of %s from loot (no alert - already dead)|r",
                                name or ("npc " .. npcID)))
                        end
                    end
                end
            end
        end
    end
end

-- Debug only: closes the loop on Q2 by timing alert -> first hit taken.
-- Reports how far the PLAYER moved in that window, because the raw
-- seconds are meaningless on their own - closing distance yourself
-- manufactures a short gap that says nothing about real warning time.
-- Stand still after the alert for a clean read; the "moved Xyd" figure
-- is there to catch it when you forget, or to size up how much of the
-- gap was you approaching versus it approaching.
local function OnCombatLog()
    if not (ns.db and ns.db.debug) then return end
    local _, sub, _, srcGUID, srcName, _, _, dstGUID = CombatLogGetCurrentEventInfo()
    if dstGUID ~= playerGUID or srcGUID == playerGUID then return end
    local p = pending[srcGUID or ""]
    if not p then return end
    pending[srcGUID] = nil

    local lead = GetTime() - p.t
    local x, y = PlayerPos()
    local moved = Dist(p.x, p.y, x, y)

    if moved then
        ns.Print(string.format(
            "|cff888888[debug] %s engaged %.1fs after the alert - you moved %.0fyd in that time|r",
            srcName or "?", lead, moved))
        if moved > 2 then
            ns.Print("|cff888888[debug] that's not a clean lead-time reading - you were closing distance. Stand still after the next alert.|r")
        end
    else
        ns.Print(string.format(
            "|cff888888[debug] %s engaged %.1fs after the alert (couldn't read your position - instance/BG?)|r",
            srcName or "?", lead))
    end
end

-- ---------------------------------------------------------------
-- Zone-entry warning (2026-08-08, Loopi)
-- ---------------------------------------------------------------
-- The other half of DH-Danger's job, and the half k-0026 cannot touch:
-- "you are about to walk into somewhere with curated dangers." Zone
-- entry deliberately ignores the character-level filter: knowing the
-- whole danger roster is more useful than hiding a lower-level threat.
-- It never looks at a rendered mob, so the camera gate simply
-- does not apply - which is why it, not the peer broadcast, is the
-- answer for a player with nobody else around.
--
-- Reads Curation.lua via the ADDON-wide namespace: the generated data
-- files do `local _, ns = ...`, so they land on ns.addonNS, never on
-- this module's table. Read LAZILY and never cached at load - Core.lua
-- loads BEFORE Curation.lua in the .toc, so the table is empty at this
-- point in the file and populated by the time anything calls in.
local function Curated()
    local a = ns.addonNS
    return a and a.Curation and a.Curation.npcs or nil
end
ns.Curated = Curated

-- zone name -> { npcID, ... }. Built once, but keyed on the table it was
-- built from so a late-arriving Curation.lua rebuilds instead of leaving
-- a nil cache that never retries - that shape is how this module keeps
-- earning knowledge entries (k-0002, k-0022).
local zoneIndex, zoneIndexSource
local function ZoneIndex()
    local npcs = Curated()
    if not npcs then return nil end
    if zoneIndex and zoneIndexSource == npcs then return zoneIndex end
    zoneIndex, zoneIndexSource = {}, npcs
    for npcID, e in pairs(npcs) do
        -- A mob that roams across a zone border carries `zones` (an
        -- array, one CSV row per zone); everything else carries `zone`
        -- (a string). Reading only `zone` would silently drop the
        -- border-roamers - which is the exact bug this shape exists to
        -- fix, since they previously held one comma-joined string that
        -- GetRealZoneText() could never match. Never shortcut this.
        local zs = e.zones or (e.zone and { e.zone })
        if zs then
            for _, zname in ipairs(zs) do
                local z = zoneIndex[zname]
                if not z then z = {} ; zoneIndex[zname] = z end
                z[#z + 1] = npcID
            end
        end
    end
    return zoneIndex
end
ns.ZoneIndex = ZoneIndex

-- level -1 means "??"/skull. DangerList.lua's schema is explicit that -1
-- must be BRANCHED on, never compared: `-1 >= playerLevel - 3` is false
-- for every player above level 2, which would silently make skull mobs
-- the safest things in the game.
function ns.LevelRelevant(mobLevel, playerLevel)
    if mobLevel == -1 then return true end
    if not mobLevel or not playerLevel then return true end
    local s = ns.db and ns.db.settings
    local mode = (s and s.alertOn) or "below"
    if mode == "any" then return true end
    if mode == "atOrAbove" then return mobLevel >= playerLevel end
    return mobLevel >= (playerLevel - ((s and s.belowLevels) or 3))
end

-- WoW's standard mob-level difficulty color scheme (mirrors Blizzard's
-- GetCreatureDifficultyColor / GetQuestGreenRange), used to color a
-- threat's name relative to the player's own level in the zone-entry
-- warning. mobLevel == -1 ("??") is branched on as the worst case, same
-- convention as ns.ZoneThreats' sort and ns.LevelRelevant above - never
-- compared numerically.
local DIFFICULTY_COLOR = {
    red    = "ffff1a1a", -- +5 and above
    orange = "ffff8040", -- +3, +4
    yellow = "ffffff00", -- -2 .. +2
    green  = "ff40bf40", -- -3 down to (not including) gray
    gray   = "ffbfbfbf", -- gray and below
}

-- Levels BELOW the player at which a mob turns gray, keyed on the
-- player's own level bracket (Loopi, 2026-08-13).
local function GrayBelow(playerLevel)
    if playerLevel <= 9 then return 5
    elseif playerLevel <= 19 then return 6
    elseif playerLevel <= 29 then return 7
    elseif playerLevel <= 39 then return 8
    else return 9 end -- 40-60
end

function ns.LevelColor(mobLevel, playerLevel)
    if mobLevel == -1 then return DIFFICULTY_COLOR.red end
    if not mobLevel or not playerLevel then return DIFFICULTY_COLOR.yellow end
    local diff = mobLevel - playerLevel
    if diff >= 5 then return DIFFICULTY_COLOR.red end
    if diff >= 3 then return DIFFICULTY_COLOR.orange end
    if diff >= -2 then return DIFFICULTY_COLOR.yellow end
    -- The gray threshold level itself IS gray (Loopi: "Mobs turn gray AT
    -- N levels below you") - so green is strictly above it, gray is at
    -- or beyond it. -diff == GrayBelow must fall through to gray.
    if -diff < GrayBelow(playerLevel) then return DIFFICULTY_COLOR.green end
    return DIFFICULTY_COLOR.gray
end

-- Curated `type` mirrors UnitClassification(); ns.ALERT_CATEGORIES is a
-- different, smaller taxonomy that mixes 3 classification keys with 2
-- surprise keys (see InitDB). `guard` comes from `surprise`, `pack` comes
-- from the curated `roams` flag (2026-08-19, Loopi - the reported bug: a
-- roaming `type="normal"` mob like the Forsaken Courier/Bodyguard had no
-- matching category at all and could never warn). An entry can carry
-- MORE THAN ONE category now - e.g. a roaming elite matches both `elite`
-- and `pack` - so this returns a list, not a single value. An empty list
-- means "no category" and the entry does not warn - deliberately, rather
-- than defaulting into a category the user didn't ask for.
function ns.CategoriesFor(entry)
    local cats = {}
    if not entry then return cats end
    if entry.surprise == "guard" then cats[#cats + 1] = "guard" end
    local t = entry.type
    if t == "rare" or t == "rareelite" or t == "elite" then cats[#cats + 1] = t end
    if entry.roams then cats[#cats + 1] = "pack" end
    return cats
end

-- The first real consumer of the alert-policy settings added on
-- 2026-08-08. alwaysAlertFor wins outright for ANY category the entry
-- matches; otherwise the entry warns if AT LEAST ONE of its categories is
-- enabled AND the level is relevant (2026-08-19, Loopi: checking
-- "Roaming Packs" should alert a roams=true mob "regardless of category"
-- - i.e. regardless of whatever its `type` is or isn't - but the level
-- filter still applies the same as every other category, per Loopi).
function ns.EntryWarns(entry, playerLevel, ignoreLevel)
    local cats = ns.CategoriesFor(entry)
    if #cats == 0 then return false end
    local s = ns.db and ns.db.settings
    local anyEnabled = false
    for _, cat in ipairs(cats) do
        if s and s.alwaysAlertFor and s.alwaysAlertFor[cat] then return true end
        if not (s and s.alertFor and s.alertFor[cat] == false) then
            anyEnabled = true
        end
    end
    if not anyEnabled then return false end
    return ignoreLevel or ns.LevelRelevant(entry.level, playerLevel)
end

-- Returns an array of { id=npcID, e=curatedEntry }, worst first.
function ns.ZoneThreats(zone, playerLevel, ignoreLevel)
    local out = {}
    local idx, npcs = ZoneIndex(), Curated()
    if not idx or not npcs or not zone then return out end
    for _, npcID in ipairs(idx[zone] or {}) do
        local e = npcs[npcID]
        if ns.EntryWarns(e, playerLevel, ignoreLevel) then out[#out + 1] = { id = npcID, e = e } end
    end
    table.sort(out, function(a, b)
        -- -1 ("??") sorts as the worst thing present, not as level -1.
        local la = (a.e.level == -1) and 999 or (a.e.level or 0)
        local lb = (b.e.level == -1) and 999 or (b.e.level or 0)
        if la ~= lb then return la > lb end
        return a.id < b.id
    end)
    return out
end

-- Curated name first (Curation.lua carries `name` as DATA as of
-- 2026-08-08 - it used to be a trailing Lua comment only), then the
-- player's own manual-list label, then the bare npcID. The manual list
-- comes second on purpose: it holds whatever the player typed, which is
-- right for their own entries but shouldn't override curated naming.
local function ThreatName(npcID, entry)
    return (entry and entry.name)
        or (ns.acctDB and ns.acctDB.manualList and ns.acctDB.manualList[npcID])
        or ("npc " .. tostring(npcID))
end
ns.ThreatName = ThreatName

local function ThreatCategory(entry)
    local labels = { rare = "Rare", elite = "Elite", rareelite = "Rare Elite" }
    return labels[entry and entry.type] or "Unknown"
end

local function ThreatCreatureType(entry)
    return entry and entry.creatureType
end

local lastZoneWarned

function ns.ZoneReport(zone, playerLevel, verbose, hideGray)
    local idx = ZoneIndex()
    if not idx then
        if verbose then
            ns.Print("no curated data loaded - Curation.lua is missing from the .toc or failed to load (k-0002).")
        end
        return
    end
    zone = zone or (GetRealZoneText and GetRealZoneText()) or ""
    if zone == "" then return end

    if not idx[zone] then
        -- This distinction matters more than the warning itself. The
        -- curated set is Rare/Rare Elite only and 296 of 332 rows carry
        -- a zone, so most of the world is simply not catalogued yet.
        -- Saying nothing here would let silence read as "safe".
        if verbose then
            ns.Print(string.format("%s is |cffffff00not in the curated set|r - that means NOT CATALOGUED, not safe.", zone))
        end
        return
    end

    -- Zone entry is an orientation warning, not a recommendation of what
    -- the player can safely fight. Show every enabled curated danger -
    -- except gray-level ones when hideGray is set (2026-08-14, Loopi):
    -- ONLY the automatic zone-entry warning passes hideGray=true;
    -- `/dhdanger zone` (verbose) always leaves it unset so the manual
    -- check still shows everything, on purpose.
    local threats = ns.ZoneThreats(zone, playerLevel, true)
    if hideGray then
        local filtered = {}
        for _, t in ipairs(threats) do
            if ns.LevelColor(t.e.level, playerLevel) ~= DIFFICULTY_COLOR.gray then
                filtered[#filtered + 1] = t
            end
        end
        threats = filtered
    end
    if #threats == 0 then
        if verbose then
            ns.Print(string.format("%s: nothing in the curated set warns at level %s with your current settings.",
                zone, tostring(playerLevel)))
        end
        return
    end

    ns.Print(string.format(
        "|cffff2020%s:|r %d curated danger(s)", zone, #threats))
    for _, t in ipairs(threats) do
        local creatureType = ThreatCreatureType(t.e)
        local roaming = t.e.roams and "  Roaming" or ""
        ns.Print(string.format("  |c%s%s|r  %s  %s",
            ns.LevelColor(t.e.level, playerLevel),
            ThreatName(t.id, t.e),
            t.e.level == -1 and "??" or tostring(t.e.level),
            ThreatCategory(t.e)) .. roaming .. (creatureType and ("  " .. creatureType) or ""))
    end
end

local function OnZoneChanged()
    if not ns.db or ns.db.zoneWarn == false then return end
    local zone = (GetRealZoneText and GetRealZoneText()) or ""
    if zone == "" or zone == lastZoneWarned then return end
    lastZoneWarned = zone
    ns.ZoneReport(zone, UnitLevel and UnitLevel("player") or nil, false, ns.db.zoneWarnHideGray == true)
end

f:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        playerGUID = UnitGUID("player")
        ns.InitDB()
        CheckPrerequisite(true)
        if ns.Sync_Init then ns.Sync_Init() end
        return
    end

    if not DHTools.IsModuleEnabled or not DHTools.IsModuleEnabled("danger") then return end

    if event == "NAME_PLATE_UNIT_ADDED" then
        if NameplatesOn() then OnNameplate((...)) end
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        OnMouseover()
    elseif event == "PLAYER_TARGET_CHANGED" then
        OnTargetChanged()
    elseif event == "CHAT_MSG_MONSTER_YELL" then
        OnMonsterChat("yell", ...)
    elseif event == "CHAT_MSG_MONSTER_EMOTE" then
        OnMonsterChat("emote", ...)
    elseif event == "LOOT_OPENED" then
        OnLootOpened()
    elseif event == "CHAT_MSG_ADDON" then
        if ns.Sync_OnAddonMessage then ns.Sync_OnAddonMessage(...) end
    elseif event == "CVAR_UPDATE" then
        CheckPrerequisite(false)
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLog()
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        -- Both, deliberately: ZONE_CHANGED_NEW_AREA never fires for the
        -- zone you log out and back in inside, which is most logins.
        -- OnZoneChanged de-dupes on the zone name, so the overlap costs
        -- nothing.
        OnZoneChanged()
    end
end)

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("CHAT_MSG_MONSTER_YELL")
f:RegisterEvent("CHAT_MSG_MONSTER_EMOTE")
f:RegisterEvent("LOOT_OPENED")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("CVAR_UPDATE")
f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
ns.frame = f

-- ---------------------------------------------------------------
-- Slash commands (v0.x - the whole point is building the list live)
-- ---------------------------------------------------------------
function ns.AddTarget()
    local guid = UnitGUID("target")
    if not guid then ns.Print("no target. Target something first.") return end
    local npcID = NpcID(guid)
    if not npcID then ns.Print("that target isn't an NPC.") return end
    local name = UnitName("target") or ("npc " .. npcID)
    ns.acctDB.manualList[npcID] = name
    ns.Print(string.format("added |cffffff00%s|r (npc %d). %d on the list.",
        name, npcID, ns.Count()))
end

function ns.RemoveTarget(arg)
    local npcID = tonumber(arg)
    if not npcID then
        local guid = UnitGUID("target")
        npcID = NpcID(guid)
    end
    if not npcID then ns.Print("target an NPC, or give an npcID.") return end
    local had = ns.acctDB.manualList[npcID]
    if not had then ns.Print(string.format("npc %d isn't on the list.", npcID)) return end
    ns.acctDB.manualList[npcID] = nil
    lastAlert = {}
    ns.Print(string.format("removed |cffffff00%s|r (npc %d). %d left.", had, npcID, ns.Count()))
end

function ns.Count()
    local n = 0
    if ns.acctDB then for _ in pairs(ns.acctDB.manualList) do n = n + 1 end end
    return n
end

local function Toggle(field, arg, label)
    if arg == "on" then ns.db[field] = true
    elseif arg == "off" then ns.db[field] = false
    else ns.db[field] = not ns.db[field] end
    ns.Print(string.format("%s %s.", label, ns.db[field] and "ON" or "OFF"))
end

SLASH_DHDANGER1 = "/dhdanger"
SlashCmdList["DHDANGER"] = function(msg)
    ns.InitDB()
    local cmd, arg = strsplit(" ", (msg or ""):lower(), 2)

    if cmd == "add" then
        ns.AddTarget()
    elseif cmd == "remove" or cmd == "rem" or cmd == "del" then
        ns.RemoveTarget(arg)
    elseif cmd == "list" then
        local n = ns.Count()
        ns.Print(string.format("%d mob(s) on the danger list:", n))
        for npcID, name in pairs(ns.acctDB.manualList) do
            ns.Print(string.format("  %s |cff888888(npc %d)|r", name, npcID))
        end
        if n == 0 then ns.Print("  (empty - target something and /dhdanger add)") end
    elseif cmd == "clear" then
        ns.acctDB.manualList = {}
        lastAlert = {}
        ns.Print("danger list cleared (account-wide - this clears it for every character).")
    elseif cmd == "sightings" then
        local mobs, spots = 0, 0
        for npcID, rec in pairs(ns.acctDB.sightings) do
            mobs = mobs + 1
            local list = type(rec.spots) == "table" and rec.spots or {}
            spots = spots + #list
            -- Lead with the best-located spot: most confirmations, ties
            -- broken by tighter accuracy. That's the one worth acting on,
            -- and showing `acc` keeps a 300-yard yell from reading like a
            -- pinpoint - the whole reason the field exists.
            local best
            for _, sp in ipairs(list) do
                if not best
                    or (sp.n or 1) > (best.n or 1)
                    or ((sp.n or 1) == (best.n or 1) and (sp.acc or 300) < (best.acc or 300)) then
                    best = sp
                end
            end
            ns.Print(string.format("  %s |cff888888(npc %d)|r - %s, %d spot(s)%s%s",
                rec.name or ("npc " .. npcID), npcID,
                (best and ((best.subzone and best.subzone ~= "" and best.subzone) or best.zone)) or "?",
                #list,
                best and string.format(" |cff888888[best: seen %dx, +/-%dyd via %s]|r",
                    best.n or 1, best.acc or 300, best.src or "?") or "",
                (rec.noPos and rec.noPos > 0)
                    and string.format(" |cff888888(%d with no position - instance/BG)|r", rec.noPos)
                    or ""))
        end
        ns.Print(string.format("%d mob(s), %d location(s) - account-wide, shared by every character. Not used by any warning yet.", mobs, spots))
        if mobs == 0 then ns.Print("  (none yet - alerts and looted danger-list kills both record one)") end
    elseif cmd == "zone" then
        -- verbose=true: says something in every branch, including "this
        -- zone isn't catalogued", which the passive on-entry warning
        -- deliberately stays quiet about.
        ns.ZoneReport(nil, UnitLevel and UnitLevel("player") or nil, true)
    elseif cmd == "zonewarn" then
        Toggle("zoneWarn", arg, "zone-entry warning")
    elseif cmd == "sound" then
        Toggle("sound", arg, "alert sound")
    elseif cmd == "debug" then
        Toggle("debug", arg, "debug lead-time timing")
    else
        ns.Print("DH-Danger commands:")
        ns.Print("  /dhdanger add            - add your current target")
        ns.Print("  /dhdanger remove [id]    - remove target, or an npcID")
        ns.Print("  /dhdanger list | clear")
        ns.Print("  /dhdanger sightings      - every location each listed mob has been seen at (account-wide)")
        ns.Print("  /dhdanger zone           - what the curated set says about the zone you're in")
        ns.Print("  /dhdanger zonewarn on|off- list curated dangers when entering a zone")
        ns.Print("  /dhdanger sound on|off   - alert sound")
        ns.Print("  /dhdanger debug on|off   - time the gap from alert to first hit")
        ns.Print("Detection: nameplate, mouseover, target, yell, emote all alert; loot only records a sighting.")
        local curated = ns.Curated()
        local n = 0
        if curated then for _ in pairs(curated) do n = n + 1 end end
        ns.Print(string.format("curated data: %s |cff888888(feeds zone warnings and live alerts, OR'd with your manual list)|r",
            curated and (n .. " mobs loaded") or "|cffff2020NOT LOADED|r"))
        ns.Print(string.format("nameplates: %s | list: %d | module: %s",
            NameplatesOn() and "|cff00ff00on|r" or "|cffff2020OFF - press V|r",
            ns.Count(),
            (DHTools.IsModuleEnabled and DHTools.IsModuleEnabled("danger"))
                and "|cff00ff00enabled|r" or "|cffff2020disabled|r"))
    end
end

-- ---------------------------------------------------------------
-- Register with DH-Tools
-- ---------------------------------------------------------------
-- 2026-08-18 (Loopi): had been default = true - the alpha warning and
-- default-off came from the curated list being unproven; by 2026-08-18
-- Loopi considered the 640-entry curated set "an excellent job of
-- curating it" and wanted every feature, live alerts included, built on
-- it (see ns.IsDangerous).
-- 2026-08-31 (Chris): reverted to default = false as part of a suite-
-- wide change - only Mob Marker and Bavin default on now; every other
-- module (including this one) is opt-in from the Tools page. Existing
-- members' own saved toggle is untouched either way.
DHTools.RegisterModule("danger", {
    name = "Danger",
    desc = "Warns you when a dangerous mob is nearby - the curated list plus your own /dhdanger add list.",
    default = false,
    OnEnable = ns.InitDB,
})
