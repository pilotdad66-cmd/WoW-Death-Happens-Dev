-- DH-Tools: Modules\MobMarker.lua
-- "Mob Marker" module - auto-marks specific mobs with a raid target icon
-- on mouseover, plus a Ctrl+click hotkey to mark/unmark whatever's under
-- the cursor. Ported 2026-07-17 from src\HCMobMarker-v2.0.zip's
-- HCMobMarker.lua (that zip is now reference-only, nothing loads it).
-- The config window (Target Icons + hotkey Settings, combined into one
-- scrollable page) lives in Config.lua, opened via /mm config or the
-- minimap button's "Target Icons" choice - see claude\DH-Tools\PROFILE.md.

local DHTools = DHTools
DHTools.MobMarker = DHTools.MobMarker or {}
local ns = DHTools.MobMarker
local Print = DHTools.Print

-- Icon name/number aliases
ns.ICON_NAMES = {
    ["star"] = 1, ["circle"] = 2, ["diamond"] = 3, ["purple"] = 3,
    ["triangle"] = 4, ["moon"] = 5, ["square"] = 6,
    ["cross"] = 7, ["x"] = 7, ["skull"] = 8,
}
ns.ICON_LABELS = {
    [1] = "Star", [2] = "Circle", [3] = "Diamond", [4] = "Triangle",
    [5] = "Moon", [6] = "Square", [7] = "Cross", [8] = "Skull",
}
ns.ICON_PATH = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"

-- Full 8-icon priority order used for row/dropdown display and hotkey
-- marking: Skull, Cross, Triangle, Diamond, Square, Circle, Moon, Star.
ns.ICON_PRIORITY_ORDER = { 8, 7, 4, 3, 6, 2, 5, 1 }

-- 6-icon priority order used for /mm add auto-assign (never Moon or Star).
local AUTO_ICON_ORDER = { 8, 7, 4, 3, 6, 2 }

-- ns.db is DHToolsDB.mobmarker (this module's own sub-table - see
-- claude\DH-Tools\PROFILE.md's module framework contract). Replaces the
-- old standalone HCMobMarkerDB.
function ns.InitDB()
    DHTools.InitDB()
    local db = DHTools.db
    if type(db.mobmarker) ~= "table" then
        db.mobmarker = {}
    end
    ns.db = db.mobmarker
    if type(ns.db.mobs) ~= "table" then
        ns.db.mobs = {}
    end
    if type(ns.db.hotkey) ~= "table" then
        ns.db.hotkey = { modifier = "CTRL", button = "LeftButton" }
    end
    -- 2026-07-29: governs the auto-mark list (Target Icons), not the
    -- hotkey click-to-mark. Off by default - tracked mobs get marked as
    -- soon as their nameplate appears (NAME_PLATE_UNIT_ADDED), no
    -- mouseover needed. On reverts to the original mouseover-only
    -- behavior. See the marking-logic comment below for why mouseover
    -- stays active either way.
    if ns.db.requireMouseover == nil then
        ns.db.requireMouseover = false
    end
end

function ns.ParseIcon(input)
    if not input then return nil end
    input = tostring(input):lower()
    local n = tonumber(input)
    if n and n >= 1 and n <= 8 then return n end
    return ns.ICON_NAMES[input]
end

-- Returns the first icon in `order` not currently used by any mob, or nil.
function ns.PickIconFromOrder(order)
    local used = {}
    for _, icon in pairs(ns.db.mobs) do
        used[icon] = true
    end
    for _, icon in ipairs(order) do
        if not used[icon] then
            return icon
        end
    end
    return nil
end

function ns.PickAutoIcon()
    return ns.PickIconFromOrder(AUTO_ICON_ORDER)
end

-- Assigns `icon` to `name`, bumping whichever other mob currently holds that
-- icon to a random unused one. Returns true on success, or false, "full" if
-- this would be a brand-new 9th mob and all 8 icon slots are already taken.
function ns.AssignMobIcon(name, icon)
    local mobs = ns.db.mobs
    local isNewMob = mobs[name] == nil

    if isNewMob then
        local count = 0
        for _ in pairs(mobs) do count = count + 1 end
        if count >= 8 then
            return false, "full"
        end
    end

    for otherName, otherIcon in pairs(mobs) do
        if otherName ~= name and otherIcon == icon then
            local used = { [icon] = true }
            for n2, i2 in pairs(mobs) do
                if n2 ~= otherName and n2 ~= name then
                    used[i2] = true
                end
            end
            local free = {}
            for i = 1, 8 do
                if not used[i] then
                    table.insert(free, i)
                end
            end
            if #free > 0 then
                mobs[otherName] = free[math.random(#free)]
            end
            break
        end
    end

    mobs[name] = icon
    return true
end

-- Marks `name` via the hotkey: next unused icon in full priority order
-- (skull..star). If the list is already full (8/8), Skull is stolen from
-- whoever currently has it -- that mob is evicted from the list entirely
-- to make room, since there's nowhere left to bump it to.
function ns.HotkeyMark(name)
    ns.InitDB()
    local mobs = ns.db.mobs

    if mobs[name] then
        -- Already tracked: hotkey click on it now acts like /mm remove.
        mobs[name] = nil
        SetRaidTarget("mouseover", 0)
        Print(("Removed '%s' from the list."):format(name))
        return
    end

    local count = 0
    for _ in pairs(mobs) do count = count + 1 end

    local icon
    if count < 8 then
        icon = ns.PickIconFromOrder(ns.ICON_PRIORITY_ORDER)
    end

    if not icon then
        icon = 8
        for otherName, otherIcon in pairs(mobs) do
            if otherIcon == 8 then
                mobs[otherName] = nil
                break
            end
        end
    end

    mobs[name] = icon
    SetRaidTarget("mouseover", icon)
    Print(("Marked '%s' with %s."):format(name, ns.ICON_LABELS[icon]))
end

local function ShowHelp()
    Print("Mob Marker commands:")
    Print("  /mm add [icon] [mob name]  - icon and name are both optional (mouseover a mob to grab its name; skip the icon to auto-pick one)")
    Print("  /mm remove [mob name]      - mouseover a mob and omit the name to remove whatever's under your cursor")
    Print("  /mm list                   - show the current list")
    Print("  /mm clear                  - wipe the list")
    Print("  /mm config                 - open the settings window (Target Icons + hotkey settings)")
    Print("  /mm on | off | toggle      - enable/disable the Mob Marker module (same as /dht on|off mobmarker)")
    Print("  /mm help                   - show this list")
    Print("Icons: 1 star, 2 circle, 3 diamond, 4 triangle, 5 moon, 6 square, 7 cross, 8 skull (names work too)")
    Print("Auto-pick order when no icon is given: skull, cross, triangle, diamond, square, circle (never moon or star)")
    Print("Hotkey: hold the configured modifier (default Ctrl) and click a mob to mark it with the next unused icon -- configurable under /mm config, in the Mob Marker page's Settings section.")
    Print("By default, tracked mobs get marked as soon as they're in view (nameplate visible), no mouseover needed -- turn on 'Require Mouseover' under /mm config to go back to mouseover-only marking.")
end

-- === Group mark authority ===
-- Raid target icons are shared, group-wide state - visible to (and, per
-- Blizzard's own permission rule, settable by) the whole party/raid. Any
-- party member can set marks in a plain party; only the raid leader/
-- assistant can in a real raid. Mob Marker's tracked-mob list
-- (ns.db.mobs) is per-character and built independently by each player,
-- so two grouped players with different local mappings for the same mob
-- used to fight over the icon every time either one's trigger fired
-- (mouseover, nameplate, hotkey) - see
-- claude\knowledge\k-0006-mobmarker-group-icon-conflict.md. Fix
-- (2026-08-04): while grouped, only the party leader (party) or raid
-- leader/assistant (raid) actually pushes SetRaidTarget; everyone else's
-- list still tracks locally (still useful once solo again) but stays
-- read-only against the shared icon. Checked live, not cached, so a
-- leader change or promotion takes effect on the very next trigger with
-- no extra event plumbing needed.
function ns.HasMarkAuthority()
    if not IsInGroup() then
        return true
    end
    -- @kb:mobmarker-raid-authority-api
    -- IsRaidLeader()/IsRaidOfficer() are the OLD (pre-4.x) globals and do
    -- NOT exist in Classic Era 1.15 - calling them threw "attempt to call
    -- a nil value" on every nameplate/mouseover trigger while in a raid
    -- (2026-08-06). UnitIsGroupLeader/UnitIsGroupAssistant are the
    -- current, present-in-Classic-Era replacements and work for both
    -- party and raid.
    if IsInRaid() then
        return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
    end
    return UnitIsGroupLeader("player")
end

-- === Core marking logic ===
-- Gated on DHTools.IsModuleEnabled("mobmarker") rather than its own
-- separate on/off flag - see claude\DH-Tools\PROFILE.md.
--
-- Two independent triggers keep a tracked mob (ns.db.mobs) marked:
--  1. Mouseover (UPDATE_MOUSEOVER_UNIT) - always active regardless of the
--     requireMouseover setting. Works even without a nameplate up, since
--     the "mouseover" unit is set by hovering the unit's 3D model
--     directly, not by nameplate visibility.
--  2. Field of view (NAME_PLATE_UNIT_ADDED) - active whenever
--     ns.db.requireMouseover is false (the default, 2026-07-29). Marks a
--     tracked mob the moment its nameplate appears, no mouseover needed.
--     Note this is bounded by the client's own nameplate visibility: Classic
--     Era only shows enemy nameplates in combat unless the player has
--     turned on "Enemy Nameplates: Always" under Interface > Names - the
--     addon can't override that, so a mob with no nameplate up (not in
--     combat, feature off) still needs a mouseover to get caught. Setting
--     requireMouseover to true disables this trigger entirely, restoring
--     the original mouseover-only behavior.
local function TryMarkUnit(unit)
    if not ns.db then return end
    if not UnitExists(unit) then return end
    if UnitIsPlayer(unit) then return end
    if UnitIsDead(unit) then return end

    local name = UnitName(unit)
    if not name then return end

    local icon = ns.db.mobs[name]
    if icon and GetRaidTargetIndex(unit) ~= icon then
        SetRaidTarget(unit, icon)
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
frame:SetScript("OnEvent", function(self, event, unit)
    if not DHTools.IsModuleEnabled("mobmarker") then return end
    if not ns.HasMarkAuthority() then return end
    if event == "UPDATE_MOUSEOVER_UNIT" then
        TryMarkUnit("mouseover")
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        if ns.db and not ns.db.requireMouseover then
            TryMarkUnit(unit)
        end
    end
end)

-- === Hotkey click-to-mark ===
local function IsConfiguredModifierDown()
    local mod = ns.db.hotkey.modifier
    if mod == "CTRL" then
        return IsControlKeyDown()
    elseif mod == "ALT" then
        return IsAltKeyDown()
    elseif mod == "SHIFT" then
        return IsShiftKeyDown()
    else
        return true -- "NONE" -- no modifier required
    end
end

WorldFrame:HookScript("OnMouseDown", function(self, mouseButton)
    if not DHTools.IsModuleEnabled("mobmarker") then return end
    if not ns.db then return end
    local hk = ns.db.hotkey
    if not hk or mouseButton ~= hk.button then return end
    if not IsConfiguredModifierDown() then return end
    if not UnitExists("mouseover") or UnitIsPlayer("mouseover") or UnitIsDead("mouseover") then return end
    if not ns.HasMarkAuthority() then
        Print("Only the group leader (or raid leader/assist) can hotkey-mark while grouped.")
        return
    end

    ns.HotkeyMark(UnitName("mouseover"))
end)

-- Wipes the tracked mob->icon list (DHToolsDB.mobmarker.mobs) - same
-- effect as opening Config, deleting every Target Icons slot, and hitting
-- Update (2026-08-15, Loopi: this is what "Clear All Marker Icons" should
-- do). Factored out so /mm clear and the minimap quick-actions menu share
-- one implementation. Note: if the Mob Marker Config page is open on this
-- page RIGHT NOW with unsaved edits, its working copy doesn't auto-refresh
-- from this - closing/reopening Config (or switching pages and back)
-- resyncs it, same as any other external change to ns.db.mobs.
function ns.ClearAll()
    ns.db.mobs = {}
    Print("Cleared the mob list.")
end

-- === Slash commands ===
SLASH_DHMOBMARKER1 = "/mm"
SLASH_DHMOBMARKER2 = "/hcmark"

SlashCmdList["DHMOBMARKER"] = function(msg)
    ns.InitDB()
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "add" then
        local icon, name

        if rest == "" then
            icon = nil
            name = ""
        else
            local firstToken, remainder = rest:match("^(%S+)%s*(.-)$")
            local parsedIcon = ns.ParseIcon(firstToken)
            if parsedIcon then
                icon = parsedIcon
                name = remainder
            else
                icon = nil
                name = rest
            end
        end

        if name == "" then
            if UnitExists("mouseover") and not UnitIsPlayer("mouseover") then
                name = UnitName("mouseover")
            else
                Print("No mob name given, and nothing valid is under your mouse. Either mouse over the mob first, or type its name.")
                return
            end
        end

        if not icon then
            icon = ns.PickAutoIcon()
            if not icon then
                Print("All six auto-assign icons (skull, cross, triangle, diamond, square, circle) are already in use. Remove one, or specify moon/star manually: /mm add moon " .. name)
                return
            end
        end

        local ok, reason = ns.AssignMobIcon(name, icon)
        if not ok then
            if reason == "full" then
                Print("Your list is full (8/8). Remove a mob before adding another.")
            end
            return
        end
        Print(("Now marking '%s' with %s."):format(name, ns.ICON_LABELS[icon]))

    elseif cmd == "remove" or cmd == "del" or cmd == "delete" then
        local name = rest
        if name == "" and UnitExists("mouseover") then
            name = UnitName("mouseover")
        end
        if name == "" or not ns.db.mobs[name] then
            Print("Usage: /mm remove <mob name> (or mouseover the mob and just type /mm remove)")
            return
        end
        ns.db.mobs[name] = nil
        Print(("Removed '%s' from the list."):format(name))

    elseif cmd == "list" then
        local count = 0
        for name, icon in pairs(ns.db.mobs) do
            count = count + 1
            Print(("%s -> %s"):format(name, ns.ICON_LABELS[icon]))
        end
        if count == 0 then
            Print("List is empty. Add mobs with /mm add [icon] [mob name].")
        end

    elseif cmd == "clear" then
        ns.ClearAll()

    elseif cmd == "config" or cmd == "options" then
        DHTools:Config_Open("MobMarker")

    elseif cmd == "on" then
        DHTools.SetModuleEnabled("mobmarker", true)

    elseif cmd == "off" then
        DHTools.SetModuleEnabled("mobmarker", false)

    elseif cmd == "toggle" then
        DHTools.SetModuleEnabled("mobmarker", not DHTools.IsModuleEnabled("mobmarker"))

    elseif cmd == "help" or cmd == "" then
        ShowHelp()

    else
        Print("Unknown command: '" .. cmd .. "'")
        ShowHelp()
    end
end

-- === Register with DH-Tools ===
DHTools.RegisterModule("mobmarker", {
    name = "Mob Marker",
    desc = "Auto-marks tracked mobs with a raid icon on sight (or on mouseover only, if configured); Ctrl+click hotkey to mark/unmark instantly.",
    default = true,
    OnEnable = ns.InitDB,
})
