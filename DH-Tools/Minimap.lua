-- DH-Tools: Minimap.lua
-- Standard LibDataBroker-1.1 / LibDBIcon-1.0 minimap button.
--
-- 2026-08-03: switched from the hand-rolled flat choice-list (no submenus)
-- to a real dropdown menu, after studying how the Questie addon gets
-- reliable right-click menus with nested/expandable submenus. Questie
-- doesn't use the shared "LibUIDropDownMenu-4.0" - it embeds its OWN copy
-- under a private LibStub name (LibUIDropDownMenuQuestie-4.0) plus private
-- global frame names, specifically so its copy can never collide with a
-- different (possibly older/patched) copy some other addon has registered
-- under the same shared name via LibStub. DH-Air's old right-click menu
-- bug (clicks not registering / menu not appearing, never reproduced or
-- diagnosed - see DH-Air's Minimap.lua) is very plausibly exactly that
-- collision. DH-Tools now vendors the same fork, renamed for this addon:
-- Libs\LibUIDropDownMenu\LibUIDropDownMenu.lua, LibStub name
-- "LibUIDropDownMenuDHTools-4.0". See claude\knowledge\ for the write-up.
--
-- 2026-08-03: left and right click now do different things - left click
-- opens DH-Tools' own Config window directly (DHTools:Config_Open("Tools")),
-- right click opens the full menu with everything DH-Tools does reachable
-- from it - Mob Marker, Quests, DH-Air, Bavin Wants and DH-Danger are
-- expandable submenus (hasArrow/menuList, same pattern Questie uses),
-- Settings/About are flat entries straight to a Config page. DH-Danger's
-- submenu is a placeholder (2026-08-06): the module has no runtime code
-- yet, so it shows a disabled "coming soon" row plus a link to its
-- placeholder Config page. DH-Air is a separate
-- standalone addon (not a DH-Tools module - see ROADMAP.md), so its
-- submenu is a thin adapter into DH-Air's own _G.DHAir globals
-- (Board_Toggle/Config_Open/DestinationEditor_Open), guarded the same way
-- the Quests submenu guards against DHQuests being absent.

local ADDON_NAME = ...
local DHTools = DHTools

local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")
local LibDropDown = LibStub("LibUIDropDownMenuDHTools-4.0")

-- A generic wrench icon - DH-Tools isn't tied to any one module's theme.
local TOOLS_ICON = "Interface\\Icons\\INV_Misc_Wrench_01"

-- 2026-08-03 (submenu direction fix): ToggleDropDownMenu decides whether a
-- level-2 submenu opens to the right (default) or flips to the left purely
-- by checking listFrame:GetRight() > GetScreenWidth() AFTER the submenu is
-- sized to fit its own button text - so a submenu with short entries (like
-- DH-Air's "Open Board"/"Open Config") can legitimately fit onscreen while
-- a wider one (Mob Marker's "Configure Target Icons...") doesn't, and only
-- the wider one flips left. Since the minimap button sits near the screen
-- edge, that made Mob Marker/Quests open left but DH-Air open right -
-- same underlying menu, inconsistent look. Fix: give every submenu button
-- the same generous minWidth (a field UIDropDownMenu_AddButton already
-- reads: `width = max(GetButtonWidth(button), info.minWidth or 0)`) so all
-- three submenus render at least as wide as the widest one and trigger the
-- same flip consistently, regardless of each submenu's own text length.
local SUBMENU_MIN_WIDTH = 180

--------------------------------------------------------------------------
-- Menu construction
--------------------------------------------------------------------------

-- A zero-height separator entry, same shape LibEasyMenu-style menus use
-- (copied from how Questie's own QuestieMenu.lua builds its divider).
local DIVIDER = {
    hasArrow = false,
    dist = 0,
    isTitle = true,
    isUninteractable = true,
    notCheckable = true,
    iconOnly = true,
    isSeparator = true,
    icon = "Interface\\Common\\UI-TooltipDivider-Transparent",
    -- @kb:divider-icon-info - these MUST live under iconInfo, not flat on
    -- this table: UIDropDownMenu_AddButton calls
    -- UIDropDownMenu_SetIconImage(icon, info.icon, info.iconInfo), and that
    -- function indexes its third arg directly (info.tCoordLeft etc.) with
    -- no nil guard - a flat info.tCoordLeft here is invisible to it, so
    -- info.iconInfo stayed nil and every dropdown menu open crashed
    -- mid-build on this divider (attempt to index local 'info' (a nil
    -- value), LibUIDropDownMenu.lua:1537) - see
    -- claude\knowledge\k-0004-dropdown-divider-iconinfo-must-be-nested.md.
    iconInfo = {
        tCoordLeft = 0, tCoordRight = 1, tCoordTop = 0, tCoordBottom = 1,
        tSizeX = 0, tSizeY = 8,
        tFitDropDownSizeX = true,
    },
    text = "",
}

local function BuildMobMarkerSubmenu()
    return {
        { text = "Configure Target Icons...", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, func = function()
            DHTools:Config_Open("MobMarker")
        end },
        DIVIDER,
        { text = "Require Mouseover to Mark", notCheckable = false, isNotRadio = true, keepShownOnClick = true, minWidth = SUBMENU_MIN_WIDTH,
            checked = DHToolsDB and DHToolsDB.mobmarker and DHToolsDB.mobmarker.requireMouseover,
            func = function()
                if DHToolsDB and DHToolsDB.mobmarker then
                    DHToolsDB.mobmarker.requireMouseover = not DHToolsDB.mobmarker.requireMouseover
                end
            end },
    }
end

local function BuildQuestsSubmenu()
    return {
        { text = "Open Quest Board", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, func = function()
            if DHQuests and DHQuests.Board_Toggle then
                DHQuests.Board_Toggle()
            end
        end },
        DIVIDER,
        { text = "Configure Sharing...", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, func = function()
            DHTools:Config_Open("Quests")
        end },
    }
end

-- DH-Air merged into DH-Tools as a real module 2026-08-20 (see
-- DH-Air-Merge-Design.md decision 2) - this stays a thin adapter into its
-- globals (_G.DHAir, exposed by Modules\DHAir\Core.lua) rather than a
-- rewrite into DHTools.Air.* nested calls, same "own namespace" pattern
-- DH-Quests uses. DHAir is now always present once DH-Tools' files load
-- (RegisterModule doesn't gate file loading, only OnEvent behavior - see
-- Core.lua), so the old "not installed" fallback rows this submenu and
-- BuildDestinationSubmenu/BuildQuickMenu used to show are gone.
--
-- 2026-08-03 (expanded): added Set Destination (a nested submenu listing
-- DHAir.db.destinations, calling DHAir:SetWarlockDestination - same
-- destination auto-summon's QueueNextAvailable filters against, see
-- DH-Air's Queue.lua) plus quick toggles mirroring the equivalent /dhair
-- slash commands (join/leave, summoner on/off, clicker on/off, invite
-- on/off, start/stop). All five toggles (Join/Leave Queue, Register/
-- Unregister as Summoner, Register/Unregister as Clicker, Auto Invite
-- On/Off, Auto Summons On/Off) use the same ColorActionEntry pattern:
-- the label names the ACTION a click performs (opposite of current
-- state), colored green when the underlying feature is CURRENTLY on,
-- red when currently off - color always tracks current state even
-- though the label names the opposite action. (Briefly tried a pure
-- current-state label for Auto Invite/Auto Summons after Loopi flagged
-- the action-word version as reading backwards against the color; he
-- confirmed on reflection the action+state-color pattern is what he
-- wants everywhere, so all five are back to it.) Two restrictions
-- layered on top of DH-Air's own API (DH-Air
-- itself doesn't enforce either - these are DH-Tools UI guards only, per
-- Loopi's explicit request): Am Summoner is Warlock-only (only Warlocks
-- cast the Ritual of Summoning DH-Air automates), and Auto Summons stays
-- disabled until the player has registered as a Summoner - mirrors the
-- existing "you need a destination first" gate RequestStartAutoSummon
-- already enforces, just for the "you need to BE a Summoner first" half.
local COLOR_ON = "|cff00ff00"  -- green - feature is currently ON
local COLOR_OFF = "|cffff0000" -- red - feature is currently OFF

local function IsWarlock()
    local _, classFile = UnitClass("player")
    return classFile == "WARLOCK"
end

-- True if the local player currently has an entry in DH-Air's summon
-- queue (regardless of whether they've already been summoned this
-- session - matches SelfJoinQueue/QueueAdd's own "already queued" dedupe
-- check, which doesn't distinguish either).
local function IsSelfQueued()
    if not (DHAir and DHAir.db and DHAir.db.queue) then return false end
    local myKey = DHAir:NormalizeName(UnitName("player"))
    for _, entry in ipairs(DHAir.db.queue) do
        if DHAir:NormalizeName(entry.name) == myKey then
            return true
        end
    end
    return false
end

-- Label names the ACTION a click performs (opposite of current state),
-- e.g. "Join Queue" while not queued, "Leave Queue" once queued. Color
-- still tracks CURRENT state (green = on, red = off).
local function ColorActionEntry(isOn, actionWhenOff, actionWhenOn, onClick)
    return {
        text = isOn and actionWhenOn or actionWhenOff,
        notCheckable = true,
        minWidth = SUBMENU_MIN_WIDTH,
        colorCode = isOn and COLOR_ON or COLOR_OFF,
        func = onClick,
    }
end

-- Builds one flat, radio-checked pick list for a category (+ continent for
-- flightpoints), used by BuildDestinationSubmenu below.
local function BuildDestinationList(category, continent)
    local current = DHAir.db.warlockDestination
    local entries = {}
    for _, d in ipairs(DHAir.db.destinations or {}) do
        if d.category == category and (not continent or d.continent == continent) and d.enabled ~= false then
            table.insert(entries, {
                text = d.label, notCheckable = false, isNotRadio = true, minWidth = SUBMENU_MIN_WIDTH,
                checked = (current == d.id),
                func = function()
                    DHAir:SetWarlockDestination(d.id)
                end,
            })
        end
    end
    if #entries == 0 then
        table.insert(entries, { text = "None configured", notCheckable = true, disabled = true, minWidth = SUBMENU_MIN_WIDTH })
    end
    return entries
end

-- 2026-08-03: "Destination Config (Officers)" opens DestinationEditor.lua's
-- standalone window - that window itself is open to everyone (read-only
-- for non-officers, per its own header comment), but Loopi wants THIS
-- menu entry gated so only an officer even sees it as clickable here,
-- same "See List" (open) / "Officer Config" (gated) split Bavin Wants
-- uses. Calls the real DHAir:HasPermission("edit_destinations") check
-- (guild rank <= officerRankThreshold, default 3, OR the Loopidot
-- testing override baked into IsGuildOfficer) rather than re-approximating
-- a rank threshold locally - the same Loopidot bug already fixed once
-- this session for Bavin's Officer Config is not worth risking again here.
local function BuildDestinationConfigEntry()
    if DHAir and DHAir.HasPermission and DHAir:HasPermission("edit_destinations") then
        return { text = "Destination Config (Officers)", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH,
            func = function()
                if DHAir.DestinationEditor_Open then
                    DHAir:DestinationEditor_Open()
                end
            end }
    end
    return {
        text = "Destination Config (Officers)", notCheckable = true, disabled = true, minWidth = SUBMENU_MIN_WIDTH,
        tooltipTitle = "Destination Config (Officers)",
        tooltipText = "Only guild officers can open this.",
        tooltipWhileDisabled = true,
    }
end

-- 2026-08-03: was one flat 52-entry list (33 flightpoints + 19 summon
-- stones) - Loopi asked for it broken up: Flight Points vs Dungeon Stones
-- first, Flight Points further split by continent (Destinations.lua's new
-- `continent` field - see that file and Core.lua's migration comment for
-- existing installs). Originally nested "Flight Points" -> "Eastern
-- Kingdoms"/"Kalimdor" -> actual entries, three levels under Set
-- Destination (already level 3 under DH-Tools > DH-Air). 2026-08-05
-- (Loopi-reported): the deepest level (the actual destination list) never
-- opened - same root cause Board.lua hit and fixed 2026-08-04 (see that
-- file's comment), just never mirrored here. Flattened the same way:
-- Eastern Kingdoms/Kalimdor are now their own top-level "Flight Points -
-- <continent>" arrow entries (one level shallower), matching Board.lua's
-- structure and naming exactly.
local function BuildDestinationSubmenu()
    return {
        { text = "Flight Points - Eastern Kingdoms", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, hasArrow = true,
            menuList = BuildDestinationList("flightpoint", "Eastern Kingdoms") },
        { text = "Flight Points - Kalimdor", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, hasArrow = true,
            menuList = BuildDestinationList("flightpoint", "Kalimdor") },
        { text = "Dungeon Stones", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, hasArrow = true,
            menuList = BuildDestinationList("summonstone", nil) },
        DIVIDER,
        { text = "Clear Destination", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, func = function()
            DHAir:SetWarlockDestination(nil)
        end },
        DIVIDER,
        BuildDestinationConfigEntry(),
    }
end

local function BuildDHAirSubmenu()
    local myName = UnitName("player")
    local isSummoner = DHAir:IsRegistered("summoner", myName)
    local isClicker = DHAir:IsRegistered("clicker", myName)
    local queued = IsSelfQueued()
    -- 2026-08-20 (found during the merge): this was reading the OLD
    -- db.autoInvite field, which Core.lua's 2026-08-15 split retired in
    -- favor of invAutoInvite/phraseAutoInvite (db.autoInvite is nil'd out
    -- during that migration) - this toggle has been silently reading a
    -- dead field, always false, since that split shipped. invAutoInvite
    -- is the correct successor: Core.lua's own migration comment says it
    -- "carries the player's prior on/off choice forward to invAutoInvite
    -- specifically" - that's the same plain "auto-invite on any whisper"
    -- behavior this quick-toggle has always meant.
    local autoInviteOn = DHAir.db.invAutoInvite and true or false
    local autoSummonsOn = DHAir.db.active and true or false

    local entries = {
        { text = "Open Board", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, func = function()
            if DHAir.Board_Toggle then
                DHAir:Board_Toggle()
            end
        end },
        { text = "Open Config", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, func = function()
            if DHAir.Config_Open then
                DHAir:Config_Open()
            end
        end },
        { text = "Set Destination", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH,
            hasArrow = true, menuList = BuildDestinationSubmenu() },
        DIVIDER,
        ColorActionEntry(queued, "Join Queue", "Leave Queue", function()
            if queued then
                if DHAir:SelfLeaveQueue() then
                    DHAir:Print("You've left the summon queue.")
                end
            else
                if DHAir:SelfJoinQueue() then
                    DHAir:Print("You've joined the summon queue.")
                else
                    DHAir:Print("You're already in the queue (or already summoned this session).")
                end
            end
        end),
    }

    if IsWarlock() then
        table.insert(entries, ColorActionEntry(isSummoner, "Register as Summoner", "Unregister as Summoner", function()
            DHAir:SetRole("summoner", not isSummoner)
            DHAir:Print(isSummoner and "Unregistered as a Summoner." or "Registered as a Summoner.")
        end))
    else
        table.insert(entries, {
            text = "Am Summoner", notCheckable = true, disabled = true, minWidth = SUBMENU_MIN_WIDTH,
            tooltipTitle = "Am Summoner", tooltipText = "Only Warlocks can register as a Summoner.",
            tooltipWhileDisabled = true,
        })
    end

    table.insert(entries, ColorActionEntry(isClicker, "Register as Clicker", "Unregister as Clicker", function()
        DHAir:SetRole("clicker", not isClicker)
        DHAir:Print(isClicker and "Unregistered as a Clicker." or "Registered as a Clicker.")
    end))

    -- 2026-08-03 (reverted same day, per Loopi): back to action-word text
    -- (what a click WILL do) with color tracking current state - Loopi's
    -- earlier "backwards" complaint was specifically about the wording,
    -- not this pattern in general; on reflection he confirmed action-text
    -- + state-color is what he wants for every toggle here, matching
    -- Join/Leave Queue's original design.
    table.insert(entries, ColorActionEntry(autoInviteOn, "Auto Invite On", "Auto Invite Off", function()
        DHAir.db.invAutoInvite = not autoInviteOn
        DHAir:Print(autoInviteOn and "Auto-invite disabled." or "Auto-invite enabled.")
    end))

    if isSummoner then
        table.insert(entries, ColorActionEntry(autoSummonsOn, "Auto Summons On", "Auto Summons Off", function()
            if autoSummonsOn then
                DHAir.db.active = false
                DHAir:Print("Auto-summon stopped. Auto-invite is still active.")
            else
                if DHAir:RequestStartAutoSummon() then
                    DHAir:Print("Auto-summon started.")
                end
            end
            if DHAir.Minimap_UpdateIcon then
                DHAir.Minimap_UpdateIcon()
            end
        end))
    else
        table.insert(entries, {
            text = "Auto Summons", notCheckable = true, disabled = true, minWidth = SUBMENU_MIN_WIDTH,
            tooltipTitle = "Auto Summons", tooltipText = "Register as a Summoner first (Am Summoner above).",
            tooltipWhileDisabled = true,
        })
    end

    return entries
end

-- 2026-08-03: "Bavin Wants" expanded from a flat entry into a submenu -
-- See List (prints the current priority list to chat, same as /dhb items)
-- is open to everyone; Officer Config (opens the Bavin Config page) is
-- greyed out unless the player's OWN guild rank qualifies. Reuses
-- /dhb items' existing display logic via SlashCmdList["DHBAVIN"] rather
-- than duplicating it or exporting a new function off DHTools.Bavin -
-- there's no dedicated "view list" window yet (see DHBavin's
-- PROFILE.md/STATUS.md, M4 not built), just the slash command's chat
-- printout.
--
-- 2026-08-03 (fixed same day): originally a standalone rank<=3
-- approximation, independent of DH-Bavin's own real permission model -
-- Loopi caught that this meant Loopidot (hardcoded full access in
-- DH-Air, and in DH-Bavin's own permission model too) still saw Officer
-- Config greyed out here, because this menu's rank guess didn't know
-- about that override at all. Now calls DHTools.Bavin's real gates
-- directly instead of re-approximating.
--
-- 2026-08-05 (Loopi): DH-Bavin's recipient and editor management are now
-- separately scoped (CanManageRecipient: Bavin/Loopidot by name only;
-- CanManageEditors: rank<=3 officers or Loopidot) - checking only
-- CanManageRecipient here would wrongly hide "Officer Config" from a
-- rank<=3 officer who can still manage editors on that page. Shows the
-- entry if either gate passes; the page itself enables/disables each
-- section independently once opened.
local function IsBavinOfficer()
    local Bavin = DHTools.Bavin
    if not Bavin then return false end
    local canManageRecipient = Bavin.CanManageRecipient and Bavin.CanManageRecipient()
    local canManageEditors = Bavin.CanManageEditors and Bavin.CanManageEditors()
    return canManageRecipient == true or canManageEditors == true
end

-- 2026-08-24 (Loopi): "Settings" and "Officer Settings" both open the
-- SAME single Bavin Config page (Config.lua's CreateBavinPanel - the
-- chat-link mouseover-tooltip preference at the top, k-0042, then a
-- divider, then the officer-only recipient/editor controls below it,
-- k-0045). A same-day standalone-second-page split was tried and
-- reversed - back to one page - so both entries land on "Bavin";
-- "Settings" just gets there unconditionally (every player has equal
-- reason to want their own preferences) while "Officer Settings" keeps
-- its permission gate below.
local function BuildBavinSubmenu()
    -- 2026-09-14 (Loopi): "See List" (priority list) dropped - the
    -- priority want-list is dead code for now, and Loopi wants no
    -- player-visible trace of it. The /dhb items slash command itself
    -- still works (untouched, same revivability approach as everywhere
    -- else this session), just not linked from this menu anymore.
    local entries = {
        { text = "Settings", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, func = function()
            DHTools:Config_Open("Bavin")
        end },
    }
    if IsBavinOfficer() then
        table.insert(entries, { text = "Officer Settings", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, func = function()
            DHTools:Config_Open("Bavin")
        end })
    else
        table.insert(entries, {
            text = "Officer Settings", notCheckable = true, disabled = true, minWidth = SUBMENU_MIN_WIDTH,
            tooltipTitle = "Officer Settings",
            tooltipText = "Only the guild leader can open this.",
            tooltipWhileDisabled = true,
        })
    end
    return entries
end

-- DH-Danger (real module as of 2026-08-07 - was a "coming soon" label
-- until then). Still a v0.x test build: the alert sound is the only
-- setting worth a menu row, since the danger list itself is built in-game
-- with /dhdanger add rather than from a shipped database.
--
-- The nameplate row is a status line, not a toggle. Enemy nameplates are
-- a Blizzard UI setting the player owns, and silently flipping it for
-- them would be its own bug - but with them off this module detects
-- nothing while looking healthy (k-0022), so it says so where they will
-- see it.
local function BuildDangerSubmenu()
    local platesOn = GetCVar("nameplateShowEnemies") == "1"
    return {
        {
            text = platesOn and "Nameplates on - detection active"
                or "|cffff2020Nameplates OFF - press V|r",
            notCheckable = true, disabled = true, minWidth = SUBMENU_MIN_WIDTH,
            tooltipTitle = "Enemy nameplates",
            tooltipText = platesOn
                and "Close-range detection needs enemy nameplates, and they are on."
                or "With enemy nameplates off, only mobs that YELL can be detected. Press V to turn them on.",
            tooltipWhileDisabled = true,
        },
        DIVIDER,
        { text = "Alert Sound", notCheckable = false, isNotRadio = true, keepShownOnClick = true,
            minWidth = SUBMENU_MIN_WIDTH,
            checked = DHToolsDB and DHToolsDB.danger and DHToolsDB.danger.sound,
            func = function()
                if DHToolsDB and DHToolsDB.danger then
                    DHToolsDB.danger.sound = not DHToolsDB.danger.sound
                end
            end },
        { text = "Settings...", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, func = function()
            DHTools:Config_Open("Danger")
        end },
    }
end

-- Macros (2026-08-21, Loopi) - thin adapter into DHMacros' own globals
-- (_G.DHMacros, Modules\DHMacros\Core.lua/Board.lua), same "own
-- namespace" pattern DH-Quests/DH-Air use. Only two entries for now, per
-- Loopi's own spec - no toggles or status rows to show yet.
local function BuildMacrosSubmenu()
    return {
        { text = "Open Macro Board", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, func = function()
            if DHMacros and DHMacros.Board_Toggle then
                DHMacros.Board_Toggle()
            end
        end },
        DIVIDER,
        { text = "Macro Config", notCheckable = true, minWidth = SUBMENU_MIN_WIDTH, func = function()
            DHTools:Config_Open("Macros")
        end },
    }
end

-- 2026-08-15 (Loopi): left click now opens a flat quick-actions menu
-- instead of jumping straight to Config - the most common things Loopi
-- wants from a click, plus Settings so Config is still one click away on
-- either button. Right click keeps the full menu below.
--
-- "Request World Buff Summons" (2026-08-17, DH-Tools-WorldBuffRequest-
-- Design.md D3/D4) whispers "inv" to whichever online, registered
-- Summoner has had World Buff Mode active longest (DH-Air's
-- GetAvailableWorldBuffSummoner, synced via D1) - DH-Air's existing
-- whisper-invite handling (Invite.lua) then does the invite, queue-join,
-- AND Booty Bay destination-set all in one shot, no separate self-join
-- step needed. Disabled with a tooltip, same pattern as "Open Summons
-- Board" below, when no Summoner is currently known to be accepting
-- requests (D4) - the old "DH-Air isn't installed" case is gone since
-- the 2026-08-20 merge (DHAir is always present now, see
-- DH-Air-Merge-Design.md decision 2).
--
-- "Clear All Marker Icons" wipes the tracked mob->icon list
-- (DHTools.MobMarker.ClearAll, shared with /mm clear) - same effect as
-- opening Config, deleting every Target Icons slot, and hitting Update.
-- There's no Blizzard API to bulk-clear icons already placed on units in
-- the world (icons are per-unit, and you can only ever affect units you
-- can currently target/see) - this only stops FUTURE auto-marking.
--
-- "Show Zone Dangers" and "Show Shared Quests" are thin calls into
-- DHTools.Danger.ZoneReport (identical to /dhdanger zone) and
-- DHQuests.Board_Toggle - same guarded-existence pattern the right-click
-- submenus already use for cross-file/cross-addon calls.
--
-- "Open Summons Board" is DH-Air's own Board_Toggle, same call the
-- DH-Air submenu's "Open Board" entry already makes.
local function BuildQuickMenu()
    -- Computed fresh every time the menu opens, same as everything else
    -- here - a stale cached target would risk whispering someone who's
    -- gone offline or turned World Buff Mode off since the menu was last
    -- built.
    local wbmTarget = DHAir.GetAvailableWorldBuffSummoner and DHAir:GetAvailableWorldBuffSummoner() or nil

    return {
        { text = "Clear All Marker Icons", notCheckable = true, func = function()
            if DHTools.MobMarker and DHTools.MobMarker.ClearAll then
                DHTools.MobMarker.ClearAll()
            end
        end },
        (not wbmTarget)
            and { text = "Request World Buff Summons", notCheckable = true, disabled = true,
                tooltipTitle = "Request World Buff Summons",
                tooltipText = "No Warlock currently accepting world buff requests.",
                tooltipWhileDisabled = true }
            or { text = "Request World Buff Summons", notCheckable = true, func = function()
                SendChatMessage("inv", "WHISPER", nil, wbmTarget)
            end },
        { text = "Show Zone Dangers", notCheckable = true, func = function()
            if DHTools.Danger and DHTools.Danger.ZoneReport then
                DHTools.Danger.ZoneReport(nil, UnitLevel and UnitLevel("player") or nil, true)
            end
        end },
        { text = "Show Shared Quests", notCheckable = true, func = function()
            if DHQuests and DHQuests.Board_Toggle then
                DHQuests.Board_Toggle()
            end
        end },
        { text = "Open Summons Board", notCheckable = true, func = function()
            if DHAir.Board_Toggle then
                DHAir:Board_Toggle()
            end
        end },
        DIVIDER,
        { text = "DH-Tools Settings", notCheckable = true, func = function()
            DHTools:Config_Open("Tools")
        end },
    }
end

-- Rebuilt fresh every time the menu opens so checkbox states (e.g. Require
-- Mouseover) always reflect current DHToolsDB values - same approach
-- Questie's QuestieMenu:Show() uses (rebuilds via buildX() functions
-- rather than keeping one static table around).
local function BuildMenu()
    return {
        -- 2026-08-08 (Loopi): reordered top-to-bottom - Mob Marker,
        -- Quests, Bavin Points, DH-Danger, DH-Air, then the divider and
        -- Settings/About (unchanged below it). Top-level label renamed
        -- "Bavin Wants" -> "Bavin Points" 2026-08-24 (Loopi's call).
        { text = "Mob Marker", notCheckable = true, keepShownOnClick = true,
            hasArrow = true, menuList = BuildMobMarkerSubmenu() },
        { text = "Quests", notCheckable = true, keepShownOnClick = true,
            hasArrow = true, menuList = BuildQuestsSubmenu() },
        { text = "Bavin Points", notCheckable = true, keepShownOnClick = true,
            hasArrow = true, menuList = BuildBavinSubmenu() },
        { text = "DH-Danger", notCheckable = true, keepShownOnClick = true,
            hasArrow = true, menuList = BuildDangerSubmenu() },
        { text = "DH-Air", notCheckable = true, keepShownOnClick = true,
            hasArrow = true, menuList = BuildDHAirSubmenu() },
        { text = "Macros", notCheckable = true, keepShownOnClick = true,
            hasArrow = true, menuList = BuildMacrosSubmenu() },
        DIVIDER,
        { text = "DH-Tools Settings", notCheckable = true, func = function()
            DHTools:Config_Open("Tools")
        end },
        { text = "About", notCheckable = true, func = function()
            DHTools:Config_Open("About")
        end },
    }
end

--------------------------------------------------------------------------
-- Dropdown frame (created once, reused every open)
--------------------------------------------------------------------------

local dropdownFrame

-- Shared by both click buttons - builder is BuildQuickMenu (left) or
-- BuildMenu (right), each rebuilt fresh on open so checkbox/disabled
-- states stay current (see BuildMenu's own comment above).
local function ToggleMenu(builder)
    if LibDropDown:getOpen() then
        LibDropDown:CloseDropDownMenus()
        return
    end
    if not dropdownFrame then
        dropdownFrame = LibDropDown:Create_UIDropDownMenu("DHToolsMinimapMenuFrame", UIParent)
    end
    LibDropDown:EasyMenu(builder(), dropdownFrame, "cursor", -210, -15, "MENU", 2)
end

--------------------------------------------------------------------------
-- LibDataBroker button
--------------------------------------------------------------------------

-- 2026-08-25 (Loopi): two straight attempts at shrinking GameTooltip's
-- own line font for this hover popup had zero visible effect on the
-- box size - its size appears to be locked in well before any font
-- override we can apply gets a chance to matter, and fighting a shared,
-- pooled, heavily-templated Blizzard frame from the outside isn't a
-- fight worth continuing. This is a small frame DH-Tools owns outright
-- instead: we set the font and compute the size ourselves, so there's
-- no Blizzard-internal layout behavior left to fight.
local MINIMAP_TOOLTIP_TEXT = "DH-Tools\n \nLeft Click: Quick Actions\nRight Click: DH-Tools Menu"
local minimapTooltipFrame, minimapTooltipText

local function EnsureMinimapTooltipFrame()
    if minimapTooltipFrame then return end
    minimapTooltipFrame = CreateFrame("Frame", "DHToolsMinimapTooltip", UIParent, "BackdropTemplate")
    minimapTooltipFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    minimapTooltipFrame:SetBackdropColor(0, 0, 0, 1)
    minimapTooltipFrame:SetFrameStrata("TOOLTIP")
    minimapTooltipFrame:Hide()

    minimapTooltipText = minimapTooltipFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    minimapTooltipText:SetPoint("TOPLEFT", 8, -8)
    minimapTooltipText:SetJustifyH("LEFT")
    minimapTooltipText:SetText(MINIMAP_TOOLTIP_TEXT)
    minimapTooltipFrame:SetSize(minimapTooltipText:GetStringWidth() + 16, minimapTooltipText:GetStringHeight() + 16)
end

-- Same screen-quadrant anchor math LibDBIcon uses internally for the
-- default GameTooltip (its own getAnchors is a private local in
-- LibDBIcon-1.0.lua, not something we can call directly) so this popup
-- still opens away from the screen edge the same way the old one did,
-- regardless of where the minimap button itself has been dragged to.
local function MinimapTooltipAnchor(button)
    local x, y = button:GetCenter()
    if not x or not y then return "CENTER", button, "CENTER" end
    local hhalf = (x > UIParent:GetWidth() * 2 / 3) and "RIGHT" or (x < UIParent:GetWidth() / 3) and "LEFT" or ""
    local vhalf = (y > UIParent:GetHeight() / 2) and "TOP" or "BOTTOM"
    return vhalf .. hhalf, button, (vhalf == "TOP" and "BOTTOM" or "TOP") .. hhalf
end

local function ShowMinimapTooltip(button)
    EnsureMinimapTooltipFrame()
    minimapTooltipFrame:ClearAllPoints()
    minimapTooltipFrame:SetPoint(MinimapTooltipAnchor(button))
    minimapTooltipFrame:Show()
end

local function HideMinimapTooltip()
    if minimapTooltipFrame then
        minimapTooltipFrame:Hide()
    end
end

local dataObject = LDB:NewDataObject("DHTools", {
    type = "launcher",
    text = "DH-Tools",
    icon = TOOLS_ICON,
    -- 2026-08-03: split by button - left click used to open Config
    -- directly. 2026-08-15 (Loopi): left click now opens a flat 5-item
    -- quick-actions menu instead (BuildQuickMenu, above) - Clear All
    -- Marker Icons / Show Zone Dangers / Show Shared Quests / Open
    -- Summons Board / DH-Tools Settings. Right click keeps the full menu
    -- (Mob Marker/Quests/DH-Air/Bavin Wants/Settings/About).
    OnClick = function(_, button)
        if button == "LeftButton" then
            ToggleMenu(BuildQuickMenu)
        else
            ToggleMenu(BuildMenu)
        end
    end,
    -- LibDBIcon only builds the shared GameTooltip when OnTooltipShow is
    -- defined (see its onEnter) - OnEnter/OnLeave here is what routes it
    -- to our own frame instead. LibDBIcon's onLeave always calls
    -- GameTooltip:Hide() too, which is harmless since we never show it.
    OnEnter = function(self)
        ShowMinimapTooltip(self)
    end,
    OnLeave = function()
        HideMinimapTooltip()
    end,
})

function DHTools.Minimap_Init()
    LDBIcon:Register("DHTools", dataObject, DHTools.db.minimap)
end
