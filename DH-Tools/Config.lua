-- DH-Tools: Config.lua
-- /dht config window: left-hand page list (Tools, Mob Marker, Quests,
-- Bavin, Danger, About) + right content pane. Mirrors DH-Air's Config.lua
-- nav pattern. "Danger" is a placeholder page - DH-Danger has no runtime
-- code yet (2026-08-06); see CreateDangerPanel.
--
-- 2026-07-17 decision (Loopi): instead of Mob Marker's original two separate
-- pages (Target Icons, Options/hotkey settings - see the ported source in
-- src\HCMobMarker-v2.0.zip's Options.lua), this combines them into ONE
-- scrollable "Mob Marker" page - icons on top, settings below - so the
-- target icon list is reachable in one click instead of two. "Tools" is the
-- new top-level page (module on/off checklist). Layout pixel values below
-- are a best-effort port, unverified in-game - see claude\DH-Tools\STATUS.md.

local ADDON_NAME = ...
local DHTools = DHTools

local frame
local navButtons = {}

--------------------------------------------------------------------------
-- Tools page - master module on/off checklist
--------------------------------------------------------------------------

-- IsAddOnInstalled (GetAddOnInfo-based "is it in the AddOns folder at
-- all" check) was removed 2026-08-20 - its only caller was DH-Air's old
-- placeholder status row, retired by the merge (see PLACEHOLDER_MODULES
-- below). checkInstalled-style entries are still supported for any future
-- placeholder that needs the same pattern.

-- DH-Layers has no checkInstalled - there's no code or addon for it to
-- detect at all yet, so it stays a plain "coming soon" placeholder. No
-- DHTools.RegisterModule entry. Move an entry out of this list entirely
-- if it ever DOES become a real DH-Tools module.
local PLACEHOLDER_MODULES = {
    {
        label = "DH-Layers",
        desc = "Shows your current WoW layer in a minimap-corner box.",
    },
    -- DH-Danger was here until 2026-08-07, DH-Air until 2026-08-20's merge
    -- into DH-Tools as a real module (RegisterModule("air") - see
    -- DH-Air-Merge-Design.md decision 2). Both now have real runtime code
    -- and render from the live module registry above like any other
    -- module - having either in both places would list it twice.
}

local function CreateToolsPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Modules")

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Turn individual DH-Tools modules on or off. Each module keeps its own slash commands and settings regardless of this switch. Greyed-out rows aren't built yet.")

    -- Built once - moduleOrder is final by the time this page is first
    -- opened (all modules register at file-load time, long before any
    -- slash command can run), and PLACEHOLDER_MODULES is a static list.
    --
    -- Every row anchors to the SAME fixed baseline (hint), not to the
    -- previous row's description - each at its own absolute Y offset
    -- computed from rowNum. (Bug fixed 2026-07-17: anchoring row N to row
    -- N-1's description, which is itself offset +22 from its checkbox to
    -- sit under the label, made every row inherit the accumulated +22 x
    -- drift from all rows before it - row 2 sat 22px right of row 1, row 3
    -- 44px right, etc. Same fixed-baseline fix DH-Air's Messages panel
    -- already uses for its channel rows, for the same reason.)
    -- 56 = enough vertical room for a checkbox (~32px tall for
    -- UICheckButtonTemplate) + the 2px gap before its description + a
    -- single line of GameFontDisableSmall text (~14px) + a few px of
    -- breathing room before the next row starts. 36 (the previous value)
    -- wasn't enough - row N's checkbox started before row N-1's
    -- description had finished, so it crowded/overlapped that text.
    local ROW_BLOCK_HEIGHT = 56 -- vertical space per row: checkbox + its description line
    local checks = {}
    local rowNum = 0

    -- Adds one row (checkbox + a small description line below it).
    -- comingSoon greys out and disables the checkbox; tag controls the
    -- "(...)" label suffix shown in that greyed state - defaults to
    -- "coming soon" but pass tag=false to suppress it entirely (e.g.
    -- DH-Air already exists and is actively developed, just not installed
    -- on this client - "coming soon" would be misleading there) or a
    -- custom string for something else.
    -- Returns the checkbox so callers can wire it up further.
    local function AddRow(labelText, descText, comingSoon, tag)
        rowNum = rowNum + 1
        local yOffset = -14 - (rowNum - 1) * ROW_BLOCK_HEIGHT

        local check = CreateFrame("CheckButton", "DHToolsToolsCheck" .. rowNum, panel, "UICheckButtonTemplate")
        check:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, yOffset)
        local checkText = _G[check:GetName() .. "Text"]

        if comingSoon then
            if tag == false then
                checkText:SetText(labelText)
            else
                checkText:SetText(labelText .. "  |cff888888(" .. (tag or "coming soon") .. ")|r")
            end
            checkText:SetTextColor(0.5, 0.5, 0.5)
            check:SetChecked(false)
            check:Disable()
        else
            checkText:SetText(labelText)
        end

        local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        desc:SetPoint("TOPLEFT", check, "BOTTOMLEFT", 22, -2)
        desc:SetPoint("RIGHT", -16, 0)
        desc:SetJustifyH("LEFT")
        desc:SetText(descText or "")

        return check
    end

    for _, key in ipairs(DHTools.moduleOrder) do
        local def = DHTools.modules[key]
        local check = AddRow(def.name, def.desc, false)
        check:SetScript("OnClick", function(self)
            DHTools.SetModuleEnabled(key, self:GetChecked() and true or false)
        end)
        checks[key] = check
    end

    for _, ph in ipairs(PLACEHOLDER_MODULES) do
        local installed = ph.checkInstalled and ph.checkInstalled()
        if installed then
            local check = AddRow(ph.label, ph.installedDesc or ph.desc, false)
            check:SetChecked(true)
            -- Status indicator, not a real toggle - there's nothing in
            -- DH-Tools to enable/disable for a separate addon. Revert any
            -- click back to checked rather than leaving it in a confusing
            -- half-toggled state (same "reassert truth" idiom DH-Air's
            -- Board.lua uses for its own authoritative checkboxes).
            check:SetScript("OnClick", function(self) self:SetChecked(true) end)
        else
            AddRow(ph.label, ph.desc, true, ph.tag)
        end
    end

    panel.Refresh = function()
        for key, check in pairs(checks) do
            check:SetChecked(DHTools.IsModuleEnabled(key))
        end
    end

    return panel
end

--------------------------------------------------------------------------
-- Mob Marker page - Target Icons (top) + Settings (bottom), one scrollable
-- page. Target-icon editing ported from src\HCMobMarker-v2.0.zip's
-- Options.lua ("targets" page): edit-then-commit via an Update button, a
-- working[] copy separate from the saved DB until you click it. Settings
-- (hotkey) ported from that same file's "options" page: writes live, no
-- Update needed - preserved as-is, just relocated below the icon list.
--------------------------------------------------------------------------

local MM_ROW_COUNT = 8
local MM_ROW_HEIGHT = 30
local mmRows = {}    -- UI widgets per target-icon row, indexed 1-8
local mmWorking = {} -- mmWorking[i] = { name = "", icon = N } (edit-session copy)

local MODIFIER_OPTIONS = {
    { label = "None", value = "NONE" },
    { label = "Ctrl", value = "CTRL" },
    { label = "Alt", value = "ALT" },
    { label = "Shift", value = "SHIFT" },
}
local BUTTON_OPTIONS = {
    { label = "Left Click", value = "LeftButton" },
    { label = "Right Click", value = "RightButton" },
    { label = "Middle Click", value = "MiddleButton" },
}

local function MM_GetUsedIconsExcluding(excludeRow1, excludeRow2)
    local used = {}
    for i = 1, MM_ROW_COUNT do
        if i ~= excludeRow1 and i ~= excludeRow2 then
            used[mmWorking[i].icon] = true
        end
    end
    return used
end

local function MM_PickRandomUnused(excluding)
    local pool = {}
    for i = 1, MM_ROW_COUNT do
        if not excluding[i] then
            table.insert(pool, i)
        end
    end
    if #pool == 0 then return nil end
    return pool[math.random(#pool)]
end

local function MM_RefreshRowVisual(i)
    local MM = DHTools.MobMarker
    local row, w = mmRows[i], mmWorking[i]
    row.icon:SetTexture(MM.ICON_PATH .. w.icon)
    UIDropDownMenu_SetSelectedValue(row.dropdown, w.icon)
    UIDropDownMenu_SetText(row.dropdown, MM.ICON_LABELS[w.icon])
    if row.edit:GetText() ~= w.name then
        row.edit:SetText(w.name)
    end
end

-- Assigns newIcon to row i. Every row -- blank or not -- always holds a
-- unique icon, so if another row already has newIcon, that row is bumped to
-- a random unused one, regardless of whether it currently has a mob name.
local function MM_SetRowIcon(i, newIcon)
    for j = 1, MM_ROW_COUNT do
        if j ~= i and mmWorking[j].icon == newIcon then
            local used = MM_GetUsedIconsExcluding(i, j)
            used[newIcon] = true
            local pick = MM_PickRandomUnused(used)
            if pick then
                mmWorking[j].icon = pick
                MM_RefreshRowVisual(j)
            end
            break
        end
    end
    mmWorking[i].icon = newIcon
    MM_RefreshRowVisual(i)
end

local function CreateMobMarkerPanel(parent)
    local MM = DHTools.MobMarker

    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local scrollFrame = CreateFrame("ScrollFrame", "DHToolsMobMarkerScroll", panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -8, 8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 640) -- width set in Refresh; height is a generous fixed
                             -- estimate for this page's fixed content - pad
                             -- rather than trim if it's off, see STATUS.md.
    scrollFrame:SetScrollChild(content)

    -- === Target Icons section ===
    local secTitle1 = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    secTitle1:SetPoint("TOPLEFT", 8, -8)
    secTitle1:SetText("Target Icons")

    local colMob = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    colMob:SetPoint("TOPLEFT", secTitle1, "BOTTOMLEFT", 26, -10)
    colMob:SetText("Mob Name")

    local colIcon = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    colIcon:SetPoint("TOPLEFT", secTitle1, "BOTTOMLEFT", 226, -10)
    colIcon:SetText("Icon")

    for i = 1, MM_ROW_COUNT do
        local y = -26 - (i - 1) * MM_ROW_HEIGHT
        local row = {}

        row.icon = content:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("TOPLEFT", secTitle1, "BOTTOMLEFT", 8, y)

        local edit = CreateFrame("EditBox", "DHToolsMMRow" .. i .. "Edit", content, "InputBoxTemplate")
        edit:SetSize(160, 20)
        edit:SetPoint("LEFT", row.icon, "RIGHT", 14, 0)
        edit:SetAutoFocus(false)
        edit:SetMaxLetters(100)
        edit:SetScript("OnEscapePressed", edit.ClearFocus)
        edit:SetScript("OnEnterPressed", edit.ClearFocus)
        edit:SetScript("OnTextChanged", function(self)
            mmWorking[i].name = self:GetText()
        end)
        row.edit = edit

        local dropdown = CreateFrame("Frame", "DHToolsMMRow" .. i .. "Dropdown", content, "UIDropDownMenuTemplate")
        dropdown:SetPoint("LEFT", edit, "RIGHT", 6, -2)
        UIDropDownMenu_SetWidth(dropdown, 90)
        UIDropDownMenu_Initialize(dropdown, function(self, level)
            for _, iconNum in ipairs(MM.ICON_PRIORITY_ORDER) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = MM.ICON_LABELS[iconNum]
                info.icon = MM.ICON_PATH .. iconNum
                info.value = iconNum
                info.func = function() MM_SetRowIcon(i, iconNum) end
                UIDropDownMenu_AddButton(info)
            end
        end)
        row.dropdown = dropdown

        local delBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        delBtn:SetSize(60, 20)
        delBtn:SetText("Delete")
        -- 2026-07-17 bug fix: this was 26 (a stray leftover from some other
        -- offset in this file), pushing the button ~24px further right than
        -- the original HCMobMarker Options.lua's row (which used 2) - just
        -- enough to clip past the scrollframe's visible width so the right
        -- edge (and the final "e") got cut off. Restored to a tight gap.
        delBtn:SetPoint("LEFT", dropdown, "RIGHT", 4, 2)
        delBtn:SetScript("OnClick", function()
            mmWorking[i].name = ""
            edit:SetText("")
        end)
        row.delBtn = delBtn

        mmRows[i] = row
    end

    local rowsBottom = -26 - (MM_ROW_COUNT - 1) * MM_ROW_HEIGHT - 24 -- bottom edge of row 8

    local clearAllBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    clearAllBtn:SetSize(100, 22)
    clearAllBtn:SetPoint("TOPLEFT", secTitle1, "BOTTOMLEFT", 8, rowsBottom - 14)
    clearAllBtn:SetText("Clear All")
    clearAllBtn:SetScript("OnClick", function()
        for i = 1, MM_ROW_COUNT do
            mmWorking[i].name = ""
            mmRows[i].edit:SetText("")
        end
    end)

    local saveNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    saveNote:SetPoint("TOPLEFT", clearAllBtn, "BOTTOMLEFT", 0, -10)
    saveNote:SetTextColor(1, 0.65, 0.1)
    saveNote:SetText("Changes to the icon list are not saved until you click Update.")

    local updateBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    updateBtn:SetSize(100, 22)
    updateBtn:SetPoint("TOPLEFT", saveNote, "BOTTOMLEFT", 0, -10)
    updateBtn:SetText("Update")

    local statusText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("LEFT", updateBtn, "RIGHT", 12, 0)

    updateBtn:SetScript("OnClick", function()
        local newMobs = {}
        for i = 1, MM_ROW_COUNT do
            local w = mmWorking[i]
            if w.name ~= "" then
                newMobs[w.name] = w.icon
            end
        end
        MM.db.mobs = newMobs
        statusText:SetText("|cff33ff99Saved!|r")
        C_Timer.After(2, function() statusText:SetText("") end)
    end)

    -- === Require Mouseover (2026-07-29) - governs the list above, not the
    -- hotkey below. Off by default: tracked mobs mark on sight (nameplate
    -- visible), no mouseover needed. Writes live, no Update click needed,
    -- same as the hotkey dropdowns below.
    local requireMouseoverCheck = CreateFrame("CheckButton", "DHToolsMMRequireMouseoverCheck", content, "UICheckButtonTemplate")
    requireMouseoverCheck:SetSize(24, 24)
    requireMouseoverCheck:SetPoint("TOPLEFT", updateBtn, "BOTTOMLEFT", -4, -14)

    local requireMouseoverLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    requireMouseoverLabel:SetPoint("LEFT", requireMouseoverCheck, "RIGHT", 2, 0)
    requireMouseoverLabel:SetText("Require mouseover to mark")

    local requireMouseoverHint = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    requireMouseoverHint:SetPoint("TOPLEFT", requireMouseoverCheck, "BOTTOMLEFT", 4, -4)
    requireMouseoverHint:SetPoint("RIGHT", content, "RIGHT", -16, 0)
    requireMouseoverHint:SetJustifyH("LEFT")
    requireMouseoverHint:SetWordWrap(true)
    requireMouseoverHint:SetText("Off (default): tracked mobs above get marked as soon as their nameplate is visible, no mouseover needed (requires enemy nameplates enabled in Interface > Names). On: only marks while you're actually mousing over the mob, like before.")

    requireMouseoverCheck:SetScript("OnClick", function(self)
        MM.db.requireMouseover = self:GetChecked() and true or false
    end)

    -- === Settings section (hotkey marking) ===
    local divider = content:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.15)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", requireMouseoverHint, "BOTTOMLEFT", -8, -18)
    divider:SetPoint("RIGHT", content, "RIGHT", -8, 0)

    local secTitle2 = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    secTitle2:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 8, -14)
    secTitle2:SetText("Hotkey Marking")

    local desc = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", secTitle2, "BOTTOMLEFT", 0, -8)
    desc:SetPoint("RIGHT", content, "RIGHT", -16, 0)
    desc:SetJustifyH("LEFT")
    desc:SetWordWrap(true)
    desc:SetText("Hold the modifier below and click a mob to instantly mark it with the next unused icon. If all 8 icons are already in use, it takes over Skull (evicting whoever currently has it).")

    local modLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    modLabel:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -22)
    modLabel:SetText("Modifier:")

    local modDropdown = CreateFrame("Frame", "DHToolsMMModDropdown", content, "UIDropDownMenuTemplate")
    modDropdown:SetPoint("LEFT", modLabel, "RIGHT", 0, -2)
    UIDropDownMenu_SetWidth(modDropdown, 100)

    local btnLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btnLabel:SetPoint("LEFT", modDropdown, "RIGHT", 30, 2)
    btnLabel:SetText("Mouse Button:")

    local btnDropdown = CreateFrame("Frame", "DHToolsMMBtnDropdown", content, "UIDropDownMenuTemplate")
    btnDropdown:SetPoint("LEFT", btnLabel, "RIGHT", 0, -2)
    UIDropDownMenu_SetWidth(btnDropdown, 100)

    local function RefreshHotkeyDropdowns()
        MM.InitDB()
        local hk = MM.db.hotkey
        for _, opt in ipairs(MODIFIER_OPTIONS) do
            if opt.value == hk.modifier then UIDropDownMenu_SetText(modDropdown, opt.label) end
        end
        for _, opt in ipairs(BUTTON_OPTIONS) do
            if opt.value == hk.button then UIDropDownMenu_SetText(btnDropdown, opt.label) end
        end
    end

    UIDropDownMenu_Initialize(modDropdown, function()
        for _, opt in ipairs(MODIFIER_OPTIONS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.label
            info.value = opt.value
            info.func = function()
                MM.db.hotkey.modifier = opt.value
                UIDropDownMenu_SetText(modDropdown, opt.label)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    UIDropDownMenu_Initialize(btnDropdown, function()
        for _, opt in ipairs(BUTTON_OPTIONS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt.label
            info.value = opt.value
            info.func = function()
                MM.db.hotkey.button = opt.value
                UIDropDownMenu_SetText(btnDropdown, opt.label)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    local resetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    resetBtn:SetSize(140, 22)
    resetBtn:SetPoint("TOPLEFT", btnLabel, "BOTTOMLEFT", 0, -22)
    resetBtn:SetText("Reset to Default")
    resetBtn:SetScript("OnClick", function()
        MM.db.hotkey.modifier = "CTRL"
        MM.db.hotkey.button = "LeftButton"
        RefreshHotkeyDropdowns()
    end)

    local note = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", resetBtn, "BOTTOMLEFT", 0, -14)
    note:SetPoint("RIGHT", content, "RIGHT", -16, 0)
    note:SetJustifyH("LEFT")
    note:SetWordWrap(true)
    note:SetText("Changes here take effect immediately -- no need to click Update.")

    -- === Load / refresh ===
    panel.Refresh = function()
        -- -24 (not -4) to leave room for the scrollbar, matching the value
        -- Board.lua already uses for the same reason - otherwise the
        -- Settings section's right-anchored text (divider/desc/note) can
        -- run under the scrollbar.
        content:SetWidth(math.max(1, scrollFrame:GetWidth() - 24))

        MM.InitDB()
        for i = 1, MM_ROW_COUNT do
            mmWorking[i] = { name = "", icon = MM.ICON_PRIORITY_ORDER[i] }
        end
        for name, icon in pairs(MM.db.mobs) do
            for i = 1, MM_ROW_COUNT do
                if mmWorking[i].icon == icon and mmWorking[i].name == "" then
                    mmWorking[i].name = name
                    break
                end
            end
        end
        for i = 1, MM_ROW_COUNT do
            MM_RefreshRowVisual(i)
        end
        statusText:SetText("")
        requireMouseoverCheck:SetChecked(MM.db.requireMouseover)

        RefreshHotkeyDropdowns()
    end

    return panel
end

--------------------------------------------------------------------------
-- Quests page - Milestone 4 (DH-Quests-Design.md). Master share on/off +
-- one checkbox per category, controlling what THIS client broadcasts to
-- the guild. Writes live (no Update button needed - these are plain
-- booleans, not the kind of multi-field edit Mob Marker's Target Icons
-- section needs a commit step for). Per DH-Quests-Design.md's M4 note,
-- these only gate outbound sharing - they never hide what other
-- guildmates have already shared with you (Sync.lua's "receiving is
-- never gated" rule).
--------------------------------------------------------------------------

local QUESTS_CATEGORY_ORDER = { "Individual", "Group", "Elite", "Class" }
local QUESTS_CATEGORY_LABELS = {
    Individual = "Individual quests",
    Group = "Group quests",
    Elite = "Elite quests",
    Class = "Class quests",
}

local function CreateQuestsPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Quests")

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Controls what THIS character shares with the guild. Turning a category off only stops you sharing it - you'll still see other guildmates' shared quests either way.")

    local masterCheck = CreateFrame("CheckButton", "DHToolsQuestsMasterCheck", panel, "UICheckButtonTemplate")
    masterCheck:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -16)
    _G[masterCheck:GetName() .. "Text"]:SetText("Share my quests with the guild")
    masterCheck:SetScript("OnClick", function(self)
        DHQuests.db.settings.shareEnabled = self:GetChecked() and true or false
    end)

    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.15)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", masterCheck, "BOTTOMLEFT", 0, -14)
    divider:SetPoint("RIGHT", -16, 0)

    local catTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    catTitle:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -14)
    catTitle:SetText("Categories to share:")

    local catChecks = {}
    local prevAnchor = catTitle
    for i, cat in ipairs(QUESTS_CATEGORY_ORDER) do
        local check = CreateFrame("CheckButton", "DHToolsQuestsCat" .. cat .. "Check", panel, "UICheckButtonTemplate")
        if i == 1 then
            check:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", -4, -8)
        else
            check:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, -4)
        end
        _G[check:GetName() .. "Text"]:SetText(QUESTS_CATEGORY_LABELS[cat])
        check:SetScript("OnClick", function(self)
            DHQuests.db.settings.categories[cat] = self:GetChecked() and true or false
        end)
        catChecks[cat] = check
        prevAnchor = check
    end

    panel.Refresh = function()
        if DHQuests.InitDB then
            DHQuests.InitDB()
        end
        local settings = DHQuests.db and DHQuests.db.settings
        if not settings then return end
        masterCheck:SetChecked(settings.shareEnabled == true)
        for _, cat in ipairs(QUESTS_CATEGORY_ORDER) do
            catChecks[cat]:SetChecked(settings.categories[cat] == true)
        end
    end

    return panel
end

--------------------------------------------------------------------------
-- Bavin page - Milestone 1 stub (DH-Bavin-Design.md). Recipient edit box
-- and an add-by-name editor list, both guild-leader-only with type-to-
-- filter suggestions (not a UIDropDownMenu, not a full member list - see
-- the big comment inside CreateBavinPanel for why: this guild runs ~1000
-- members). Everyone else gets a read-only view. No priority-list editor
-- yet (M4) and no bag/mailbox UI yet (M5).
--------------------------------------------------------------------------

local function CreateBavinPanel(parent)
    local Bavin = DHTools.Bavin
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    -- Scrollable, like Mob Marker's page (CreateMobMarkerPanel above) -
    -- this page's content (recipient row, two 4-row suggestion pools, two
    -- dividers, and a 10-row current-editors list) adds up to roughly
    -- 700px, comfortably taller than the config window's default content
    -- area. 2026-07-29: the Remove buttons in the current-editors list
    -- were very likely already working but simply off-screen with no way
    -- to scroll to them - this fixes that regardless. Same session:
    -- suggestion pools shrunk from 8 to 4 rows each to cut the dead gap
    -- they reserved before the Editors section.
    local scrollFrame = CreateFrame("ScrollFrame", "DHToolsBavinScroll", panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -8, 8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 620) -- width set in Refresh; height is a generous
                             -- fixed estimate for this page's content -
                             -- pad rather than trim if it's off, same
                             -- approach Mob Marker's page already uses.
                             -- 2026-08-24: reduced from 820 after tightening
                             -- the officer section's gaps and dropping its
                             -- two internal dividers and half its reserved
                             -- suggestion-row space.
    scrollFrame:SetScrollChild(content)

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Bavin")

    local hint = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("The recipient is the guild's current mail collector; the mailbox helper and bag highlighting (a later milestone) will target whoever is set here. Only Bavin can change the recipient; officers (rank <= 3) can manage editors.")

    --------------------------------------------------------------------
    -- Everyone section - no permission gate, unlike everything below the
    -- divider that follows it.
    --------------------------------------------------------------------
    -- 2026-08-24: stock Blizzard chat only shows an item's tooltip on
    -- CLICK, not hover - see Tooltip.lua's "Path 3" comment. Plain
    -- per-account preference. k-0045 briefly split this onto its own
    -- standalone Config page (so a non-officer had a menu path to it
    -- without also seeing the officer-only controls below) - Loopi
    -- reversed that same day: back to one page, with a divider marking
    -- where "everyone" ends and "officer-only" begins instead.
    local mouseoverCheck = CreateFrame("CheckButton", "DHToolsBavinMouseoverCheck", content, "UICheckButtonTemplate")
    mouseoverCheck:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
    _G[mouseoverCheck:GetName() .. "Text"]:SetText("Show item tooltips on chat-link mouseover (not just click)")
    mouseoverCheck:SetScript("OnClick", function(self)
        Bavin.db.mouseoverChatTooltips = self:GetChecked() and true or false
    end)

    local everyoneDivider = content:CreateTexture(nil, "ARTWORK")
    everyoneDivider:SetColorTexture(1, 1, 1, 0.15)
    everyoneDivider:SetHeight(1)
    everyoneDivider:SetPoint("TOPLEFT", mouseoverCheck, "BOTTOMLEFT", -4, -10)
    everyoneDivider:SetPoint("RIGHT", -16, 0)

    --------------------------------------------------------------------
    -- Officer-only section below this point (recipient/editor
    -- management). 2026-08-24 (Loopi): removed the two dividers this
    -- section used to have internally (before Recipient, before Current
    -- Editors) and tightened every gap - already set off from the
    -- everyone section above by everyoneDivider, so it doesn't need its
    -- own internal separators too.
    --------------------------------------------------------------------
    -- 2026-08-05: recipient and editor management are separately scoped
    -- (see DHBavin\Core.lua's Permission model section) - this note now
    -- reflects whichever of the two the player lacks, instead of a single
    -- flat "not the guild leader" message that no longer matches either
    -- gate's real rule.
    local lockedNote = content:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    lockedNote:SetPoint("TOPLEFT", everyoneDivider, "BOTTOMLEFT", 4, -8)
    lockedNote:SetPoint("RIGHT", -16, 0)
    lockedNote:SetJustifyH("LEFT")
    lockedNote:SetWordWrap(true)

    -- Type-to-filter suggestion rows, NOT a UIDropDownMenu and NOT a full
    -- member list. 2026-07-28/29 history: a dynamically-repopulated
    -- UIDropDownMenu here caused a page-bleed bug, then a hard "script ran
    -- too long" crash; the next fix (listing every roster name as plain
    -- text) works for a small guild but this guild runs ~1000 members, so
    -- that's unusable too (and was almost certainly the REAL cause of the
    -- dropdown crash as well - building/positioning ~1000 real UI frames
    -- in one synchronous call blows WoW's script budget regardless of
    -- which widget you use). The fix that actually scales: filter on the
    -- Lua side (cheap even at 1000 entries) and only ever materialize a
    -- handful of real button frames, reused as the match set changes.
    -- Shared by both the recipient field and the "add editor" field below.
    -- 2026-07-29: capped at 4 (was 8) - the pool reserves this many rows
    -- of vertical space even when no suggestions are showing (which is
    -- most of the time), so 8 left a large dead gap before the Editors
    -- section and pushed Current Editors further down than it needed to
    -- be. 2026-08-24 (Loopi): cut again, 4 -> 2 - same reasoning, this
    -- reserved space was most of what Loopi meant by "empty space
    -- (blank rows)" in the officer section. 2 still shows the closest
    -- couple of matches, which covers the common case of a mostly-typed
    -- name.
    local BAVIN_SUGGEST_ROWS = 2

    local function BuildSuggestPool(anchor)
        local buttons = {}
        local prevAnchor = anchor
        for i = 1, BAVIN_SUGGEST_ROWS do
            local btn = CreateFrame("Button", nil, content)
            btn:SetSize(220, 16)
            if i == 1 then
                btn:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 4, -6)
            else
                btn:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, -2)
            end
            local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            text:SetAllPoints()
            text:SetJustifyH("LEFT")
            btn.text = text
            local hl = btn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.15)
            btn:Hide()
            buttons[i] = btn
            prevAnchor = btn
        end
        return buttons
    end

    -- Fills `buttons` with up to #buttons roster names matching `typed`
    -- (case-insensitive plain substring, no Lua pattern chars), hiding the
    -- rest. Stops as soon as enough matches are found rather than
    -- scanning the whole roster for display purposes. `onPick(name)` runs
    -- when a suggestion row is clicked.
    local function PopulateSuggestions(buttons, typed, onPick)
        typed = (typed or ""):lower()
        local shown = 0
        if typed ~= "" then
            for _, name in ipairs(Bavin.GetRosterNames()) do
                if shown >= #buttons then break end
                if name:lower():find(typed, 1, true) then
                    shown = shown + 1
                    local btn = buttons[shown]
                    btn.text:SetText(name)
                    btn:Show()
                    btn:SetScript("OnClick", function() onPick(name) end)
                end
            end
        end
        for i = shown + 1, #buttons do
            buttons[i]:Hide()
        end
    end

    --------------------------------------------------------------------
    -- Recipient (guild-leader-only)
    --------------------------------------------------------------------
    local recipientLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    recipientLabel:SetPoint("TOPLEFT", lockedNote, "BOTTOMLEFT", 0, -10)
    recipientLabel:SetText("Recipient:")

    local recipientEdit = CreateFrame("EditBox", "DHToolsBavinRecipientEdit", content, "InputBoxTemplate")
    recipientEdit:SetSize(140, 20)
    recipientEdit:SetPoint("LEFT", recipientLabel, "RIGHT", 10, -2)
    recipientEdit:SetAutoFocus(false)
    recipientEdit:SetMaxLetters(24)
    recipientEdit:SetScript("OnEscapePressed", recipientEdit.ClearFocus)

    local recipientSetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    recipientSetBtn:SetSize(60, 20)
    recipientSetBtn:SetText("Set")
    recipientSetBtn:SetPoint("LEFT", recipientEdit, "RIGHT", 6, 0)

    local recipientStatus = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    recipientStatus:SetPoint("LEFT", recipientSetBtn, "RIGHT", 8, 0)

    local rosterHint = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    rosterHint:SetPoint("TOPLEFT", recipientLabel, "BOTTOMLEFT", 0, -6)
    rosterHint:SetPoint("RIGHT", -16, 0)
    rosterHint:SetJustifyH("LEFT")
    rosterHint:SetWordWrap(true)

    local recipientSuggestButtons = BuildSuggestPool(rosterHint)

    local function UpdateRecipientSuggestions(typed)
        PopulateSuggestions(recipientSuggestButtons, typed, function(name)
            recipientEdit:SetText(name)
            recipientEdit:ClearFocus()
            PopulateSuggestions(recipientSuggestButtons, "", function() end)
        end)
    end
    recipientEdit:SetScript("OnTextChanged", function(self)
        UpdateRecipientSuggestions(self:GetText())
    end)

    local function TrySetRecipient()
        local typed = recipientEdit:GetText()
        recipientEdit:ClearFocus()
        UpdateRecipientSuggestions("")
        if typed == "" then return end
        if Bavin.SetRecipient(typed) then
            recipientStatus:SetText("|cff33ff99Set!|r")
            C_Timer.After(2, function() recipientStatus:SetText("") end)
        else
            recipientStatus:SetText("|cffff3333Refused (Bavin only)|r")
        end
    end
    recipientSetBtn:SetScript("OnClick", TrySetRecipient)
    recipientEdit:SetScript("OnEnterPressed", TrySetRecipient)

    -- 2026-08-24 (Loopi): the divider that used to sit here (before
    -- "Editors...") is gone - anchored directly off the recipient
    -- suggestion pool instead, at recipientLabel's own x (-4 cancels the
    -- pool's own +4 indent) so it lines up with "Recipient:" exactly.
    --------------------------------------------------------------------
    -- Editors (additive, guild-leader-only) - add-by-name with the same
    -- capped suggestion pool, then a small removable list. Unlike the
    -- recipient field, the "current editors" list below is sized to a
    -- realistic editor count (not the guild roster), since in practice
    -- it's a short additive list, not something that scales with guild
    -- size the way the roster itself does.
    --------------------------------------------------------------------
    local editorsTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    editorsTitle:SetPoint("TOPLEFT", recipientSuggestButtons[BAVIN_SUGGEST_ROWS], "BOTTOMLEFT", -4, -10)
    editorsTitle:SetText("Editors (in addition to the recipient):")

    local editorAddLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    editorAddLabel:SetPoint("TOPLEFT", editorsTitle, "BOTTOMLEFT", 0, -10)
    editorAddLabel:SetText("Add editor:")

    local editorAddEdit = CreateFrame("EditBox", "DHToolsBavinEditorAddEdit", content, "InputBoxTemplate")
    editorAddEdit:SetSize(140, 20)
    editorAddEdit:SetPoint("LEFT", editorAddLabel, "RIGHT", 10, -2)
    editorAddEdit:SetAutoFocus(false)
    editorAddEdit:SetMaxLetters(24)
    editorAddEdit:SetScript("OnEscapePressed", editorAddEdit.ClearFocus)

    local editorAddBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    editorAddBtn:SetSize(60, 20)
    editorAddBtn:SetText("Add")
    editorAddBtn:SetPoint("LEFT", editorAddEdit, "RIGHT", 6, 0)

    local editorAddStatus = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    editorAddStatus:SetPoint("LEFT", editorAddBtn, "RIGHT", 8, 0)

    -- 2026-08-24: anchored to editorAddLabel (x=16, same column as
    -- editorsTitle/recipientLabel), not editorAddEdit (the edit box,
    -- offset well to the right) - matches recipientSuggestButtons'
    -- anchor-to-label pattern above instead of drifting off the edit box.
    local editorSuggestButtons = BuildSuggestPool(editorAddLabel)

    local function UpdateEditorSuggestions(typed)
        PopulateSuggestions(editorSuggestButtons, typed, function(name)
            editorAddEdit:SetText(name)
            editorAddEdit:ClearFocus()
            PopulateSuggestions(editorSuggestButtons, "", function() end)
        end)
    end
    editorAddEdit:SetScript("OnTextChanged", function(self)
        UpdateEditorSuggestions(self:GetText())
    end)

    -- Forward-declared: TryAddEditor (defined next) needs to refresh the
    -- current-editors list below, which isn't built yet at this point.
    local RebuildCurrentEditorRows

    local function TryAddEditor()
        local typed = editorAddEdit:GetText()
        editorAddEdit:ClearFocus()
        UpdateEditorSuggestions("")
        if typed == "" then return end
        local current = {}
        if Bavin.db then
            for _, n in ipairs(Bavin.db.editors) do
                if n == typed then
                    editorAddStatus:SetText("|cffff3333Already an editor|r")
                    return
                end
                table.insert(current, n)
            end
        end
        table.insert(current, typed)
        if Bavin.SetEditors(current) then
            editorAddEdit:SetText("")
            editorAddStatus:SetText("|cff33ff99Added!|r")
            C_Timer.After(2, function() editorAddStatus:SetText("") end)
            if RebuildCurrentEditorRows then RebuildCurrentEditorRows() end
        else
            editorAddStatus:SetText("|cffff3333Refused (officers only)|r")
        end
    end
    editorAddBtn:SetScript("OnClick", TryAddEditor)
    editorAddEdit:SetScript("OnEnterPressed", TryAddEditor)

    -- 2026-08-24 (Loopi): the divider that used to sit here is gone -
    -- anchored directly off the editor suggestion pool instead, same
    -- -4-cancels-+4 trick used for editorsTitle above, so "Current
    -- editors:" lines up at the same x as "Recipient:" and "Editors
    -- (in addition to the recipient):" exactly as Loopi asked.
    local currentEditorsTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    currentEditorsTitle:SetPoint("TOPLEFT", editorSuggestButtons[BAVIN_SUGGEST_ROWS], "BOTTOMLEFT", -4, -10)
    currentEditorsTitle:SetText("Current editors:")

    local BAVIN_CURRENT_EDITOR_ROWS = 10
    local currentEditorRows = {}
    local prevEditorAnchor = currentEditorsTitle
    for i = 1, BAVIN_CURRENT_EDITOR_ROWS do
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(300, 18)
        if i == 1 then
            row:SetPoint("TOPLEFT", prevEditorAnchor, "BOTTOMLEFT", 4, -6)
        else
            row:SetPoint("TOPLEFT", prevEditorAnchor, "BOTTOMLEFT", 0, -2)
        end
        local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("LEFT", 0, 0)
        row.text = text
        local removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        removeBtn:SetSize(60, 18)
        removeBtn:SetPoint("LEFT", text, "RIGHT", 10, 0)
        removeBtn:SetText("Remove")
        row.removeBtn = removeBtn
        row:Hide()
        currentEditorRows[i] = row
        prevEditorAnchor = row
    end

    RebuildCurrentEditorRows = function()
        -- 2026-08-05: removing an editor is editor-management, gated by
        -- CanManageEditors (rank<=3/Loopidot) - was wrongly using
        -- CanManageRecipient (Bavin/Loopidot) before the two gates split.
        local canManage = Bavin.CanManageEditors()
        local editors = (Bavin.db and Bavin.db.editors) or {}
        for i, row in ipairs(currentEditorRows) do
            local name = editors[i]
            if not name then
                row:Hide()
            else
                row:Show()
                row.text:SetText(name)
                row.removeBtn:SetScript("OnClick", function()
                    local list = {}
                    for _, n in ipairs(editors) do
                        if n ~= name then table.insert(list, n) end
                    end
                    if Bavin.SetEditors(list) then
                        RebuildCurrentEditorRows()
                    end
                end)
                if canManage then
                    row.removeBtn:Enable()
                else
                    row.removeBtn:Disable()
                end
            end
        end
    end

    panel.Refresh = function()
        -- -24 (not -4) to leave room for the scrollbar - same reasoning
        -- as Mob Marker's page (see its Refresh comment above).
        content:SetWidth(math.max(1, scrollFrame:GetWidth() - 24))

        Bavin.InitDB()
        mouseoverCheck:SetChecked(Bavin.db and Bavin.db.mouseoverChatTooltips)
        -- 2026-08-05: recipient and editor management are separately
        -- scoped now (CanManageRecipient: Bavin/Loopidot by name only;
        -- CanManageEditors: rank<=3 officers or Loopidot) - each
        -- section below is enabled/disabled against its own gate instead
        -- of one shared "canManage" boolean.
        local canManageRecipient = Bavin.CanManageRecipient()
        local canManageEditors = Bavin.CanManageEditors()
        -- Shown whenever EITHER section is locked (not just when both
        -- are), so a rank<=3 officer who can manage editors but not the
        -- recipient still sees why the recipient controls are disabled.
        lockedNote:SetShown(not (canManageRecipient and canManageEditors))
        if not canManageRecipient and not canManageEditors then
            lockedNote:SetText("|cffff3333You can't manage the recipient (Bavin only) or editors (officers only) - read-only.|r")
        elseif not canManageRecipient then
            lockedNote:SetText("|cffff3333You can't change the recipient (Bavin only).|r")
        elseif not canManageEditors then
            lockedNote:SetText("|cffff3333You can't manage editors (officers rank<=3 only).|r")
        end

        -- Just a count, not the roster itself - see the BuildSuggestPool
        -- comment above for why (some guilds run ~1000 members).
        local memberCount = #Bavin.GetRosterNames()
        if memberCount == 0 then
            rosterHint:SetText("Guild roster hasn't loaded yet.")
        else
            rosterHint:SetText(memberCount .. " guild member(s) loaded - type part of a name below for matches.")
        end

        recipientEdit:SetText(Bavin.db and Bavin.db.recipient or "")
        UpdateRecipientSuggestions("")
        if canManageRecipient then
            recipientEdit:Enable()
            recipientSetBtn:Enable()
        else
            recipientEdit:Disable()
            recipientSetBtn:Disable()
        end

        editorAddEdit:SetText("")
        UpdateEditorSuggestions("")
        if canManageEditors then
            editorAddEdit:Enable()
            editorAddBtn:Enable()
        else
            editorAddEdit:Disable()
            editorAddBtn:Disable()
        end

        RebuildCurrentEditorRows()
    end

    return panel
end

--------------------------------------------------------------------------
-- Danger page (2026-08-18: live alerts now use the curated list too)
--------------------------------------------------------------------------
-- DH-Danger has real detection and alert code (Modules\DHDanger\Core.lua).
-- The per-classification and level settings below now gate BOTH the
-- zone-entry warning and the curated half of live proximity alerts
-- (ns.IsDangerous) - a manually-added (/dhdanger add) mob still always
-- alerts unconditionally, unaffected by these settings.
--
-- The one thing this page MUST surface is the nameplate CVar: with enemy
-- nameplates off the module detects nothing while appearing to work
-- (k-0022), and a config page that stayed silent about that would be
-- part of the trap rather than a warning about it.

-- Alert On radio options - value must match Core.lua's
-- settings.alertOn vocabulary ("any" | "below" | "atOrAbove").
local DANGER_ALERT_ON_OPTIONS = {
    { value = "any",       label = "Any Level" },
    { value = "atOrAbove", label = "My Level or Above" },
    { value = "below",     label = "X Levels Below Me" },
}

local function CreateDangerPanel(parent)
    local Danger = DHTools.Danger
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    -- Scrollable (2026-08-08) - the settings sections below pushed this
    -- page well past a fixed frame's visible height. Same
    -- scrollFrame+content+generous-fixed-height pattern as the Bavin and
    -- Mob Marker pages - pad rather than trim if the estimate is off.
    local scrollFrame = CreateFrame("ScrollFrame", "DHToolsDangerScroll", panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -8, 8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    -- 780 -> 860 (2026-09-10): the new Repeat Alert Delay slider/caveat
    -- added ~70px between the level-below slider and Alert Categories.
    content:SetSize(1, 860)
    scrollFrame:SetScrollChild(content)

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("DH-Danger")

    local body = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
    body:SetPoint("RIGHT", -16, 0)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetWordWrap(true)
    body:SetText("Warns you when a dangerous mob is nearby, using enemy "
        .. "nameplates for close range and monster yells for long range.\n\n"
        .. "This build uses a curated threat list. If you see something that "
        .. "doesn't belong, or you know of something that should be here but "
        .. "isn't, please contact Loopi either in game or through the discord "
        .. "#development chat.\n\n"
        .. "You can still add personal entries on top of the curated list:\n"
        .. "|cffffff00/dhdanger add|r - add whatever you're targeting\n"
        .. "|cffffff00/dhdanger remove|r - take it off again\n"
        .. "|cffffff00/dhdanger list|r - see what's on it\n"
        .. "|cffffff00/dhdanger sound on|off|r, |cffffff00/dhdanger debug on|off|r")

    local warn = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    warn:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -20)
    warn:SetPoint("RIGHT", -16, 0)
    warn:SetJustifyH("LEFT")
    warn:SetWordWrap(true)

    --------------------------------------------------------------------
    -- Zone Entry Alerts (2026-08-14, Loopi) - db.zoneWarn already existed
    -- (per-character, previously only reachable via `/dhdanger zonewarn
    -- on|off`); this just surfaces it as a checkbox. zoneWarnHideGray is
    -- new: hides gray-level curated threats from the AUTOMATIC zone-entry
    -- line specifically. `/dhdanger zone` (the manual, verbose command)
    -- always shows everything regardless of this setting (Loopi) - see
    -- Core.lua's ZoneReport hideGray param.
    --------------------------------------------------------------------
    local zoneDivider = content:CreateTexture(nil, "ARTWORK")
    zoneDivider:SetColorTexture(1, 1, 1, 0.15)
    zoneDivider:SetHeight(1)
    zoneDivider:SetPoint("TOPLEFT", warn, "BOTTOMLEFT", 0, -18)
    zoneDivider:SetPoint("RIGHT", -16, 0)

    local zoneTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    zoneTitle:SetPoint("TOPLEFT", zoneDivider, "BOTTOMLEFT", 0, -14)
    zoneTitle:SetText("Zone Entry Alerts")

    local zoneWarnCheck = CreateFrame("CheckButton", "DHToolsDangerZoneWarnCheck", content, "UICheckButtonTemplate")
    zoneWarnCheck:SetPoint("TOPLEFT", zoneTitle, "BOTTOMLEFT", -4, -8)
    _G[zoneWarnCheck:GetName() .. "Text"]:SetText("Alert when entering a dangerous zone")

    -- Exclude Gray / Green from the zone-entry message (2026-09-11,
    -- Loopi - Hide Gray already existed as its own checkbox; Hide Green
    -- is new and independent, not a replacement). One compact line:
    -- "Exclude [x]Gray / [x]Green Threats from the Zone In Message",
    -- with the words Gray/Green colored to match ns.LevelColor's own
    -- difficulty-color scheme (DIFFICULTY_COLOR.gray/.green in Core.lua)
    -- so the checkbox label matches what the zone report actually shows.
    -- `/dhdanger zone` (verbose) always ignores both, same as before.
    local excludeLabel = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    excludeLabel:SetPoint("TOPLEFT", zoneWarnCheck, "BOTTOMLEFT", 20, -8)
    excludeLabel:SetText("Exclude")

    local zoneHideGrayCheck = CreateFrame("CheckButton", "DHToolsDangerZoneHideGrayCheck", content, "UICheckButtonTemplate")
    zoneHideGrayCheck:SetPoint("LEFT", excludeLabel, "RIGHT", 2, 0)
    _G[zoneHideGrayCheck:GetName() .. "Text"]:SetText("|cffbfbfbfGray|r /")

    local zoneHideGreenCheck = CreateFrame("CheckButton", "DHToolsDangerZoneHideGreenCheck", content, "UICheckButtonTemplate")
    zoneHideGreenCheck:SetPoint("LEFT", _G[zoneHideGrayCheck:GetName() .. "Text"], "RIGHT", 2, 0)
    _G[zoneHideGreenCheck:GetName() .. "Text"]:SetText("|cff40bf40Green|r Threats from the Zone In Message")

    -- Only meaningful when zoneWarn is on - disabled (and greyed) rather
    -- than hidden, so their existence isn't a surprise once zoneWarn is
    -- turned back on. NOTE: the Gray/Green words above are colored with
    -- embedded |cAARRGGBB codes, which win over SetFontObject's color -
    -- so "disabling" still leaves those two words showing their bright
    -- colors even though the checkbox itself is greyed/unclickable. A
    -- cosmetic gap, not a functional one - Enable/Disable still gates
    -- whether the checkbox can be clicked.
    local function UpdateZoneExcludeCheckboxesEnabled()
        local grayText = _G[zoneHideGrayCheck:GetName() .. "Text"]
        local greenText = _G[zoneHideGreenCheck:GetName() .. "Text"]
        if zoneWarnCheck:GetChecked() then
            zoneHideGrayCheck:Enable()
            zoneHideGreenCheck:Enable()
            excludeLabel:SetFontObject("GameFontHighlight")
            grayText:SetFontObject("GameFontHighlight")
            greenText:SetFontObject("GameFontHighlight")
        else
            zoneHideGrayCheck:Disable()
            zoneHideGreenCheck:Disable()
            excludeLabel:SetFontObject("GameFontDisable")
            grayText:SetFontObject("GameFontDisable")
            greenText:SetFontObject("GameFontDisable")
        end
    end

    zoneWarnCheck:SetScript("OnClick", function(self)
        Danger.db.zoneWarn = self:GetChecked() and true or false
        UpdateZoneExcludeCheckboxesEnabled()
    end)
    zoneHideGrayCheck:SetScript("OnClick", function(self)
        Danger.db.zoneWarnHideGray = self:GetChecked() and true or false
    end)
    zoneHideGreenCheck:SetScript("OnClick", function(self)
        Danger.db.zoneWarnHideGreen = self:GetChecked() and true or false
    end)

    --------------------------------------------------------------------
    -- Guild/Group Sharing (2026-08-20, Loopi - k-0026/k-0030 peer-relay
    -- design, Sync.lua). Broadcasts YOUR OWN nameplate/mouseover/target
    -- detections to guild + party/raid so a guildmate whose camera isn't
    -- on the mob still gets warned. Gates SENDING only - unchecking this
    -- never stops you from hearing about someone else's sighting.
    -- Default ON (Loopi).
    --------------------------------------------------------------------
    local shareDivider = content:CreateTexture(nil, "ARTWORK")
    shareDivider:SetColorTexture(1, 1, 1, 0.15)
    shareDivider:SetHeight(1)
    shareDivider:SetPoint("TOPLEFT", zoneHideGrayCheck, "BOTTOMLEFT", -20, -18)
    shareDivider:SetPoint("RIGHT", -16, 0)

    local shareTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    shareTitle:SetPoint("TOPLEFT", shareDivider, "BOTTOMLEFT", 0, -14)
    shareTitle:SetText("Guild/Group Sharing")

    local shareSyncCheck = CreateFrame("CheckButton", "DHToolsDangerShareSyncCheck", content, "UICheckButtonTemplate")
    shareSyncCheck:SetPoint("TOPLEFT", shareTitle, "BOTTOMLEFT", -4, -8)
    _G[shareSyncCheck:GetName() .. "Text"]:SetText("Share my sightings with guild/group")

    shareSyncCheck:SetScript("OnClick", function(self)
        Danger.db.shareSync = self:GetChecked() and true or false
    end)

    --------------------------------------------------------------------
    -- Alert Settings (2026-08-08, Loopi - "start adding the choices we
    -- discussed"). Write to DHToolsDB.danger.settings and, since
    -- 2026-08-18, are read live by ns.EntryWarns/ns.IsDangerous for both
    -- the zone-entry warning and curated live proximity alerts (this
    -- comment used to say PREVIEW ONLY / not read yet - stale as of that
    -- wiring, corrected 2026-08-20).
    --------------------------------------------------------------------
    local settingsDivider = content:CreateTexture(nil, "ARTWORK")
    settingsDivider:SetColorTexture(1, 1, 1, 0.15)
    settingsDivider:SetHeight(1)
    settingsDivider:SetPoint("TOPLEFT", shareSyncCheck, "BOTTOMLEFT", 4, -18)
    settingsDivider:SetPoint("RIGHT", -16, 0)

    local settingsTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    settingsTitle:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -14)
    settingsTitle:SetText("Alert Settings")

    local settingsCaveat = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    settingsCaveat:SetPoint("TOPLEFT", settingsTitle, "BOTTOMLEFT", 0, -4)
    settingsCaveat:SetPoint("RIGHT", -16, 0)
    settingsCaveat:SetJustifyH("LEFT")
    settingsCaveat:SetWordWrap(true)
    settingsCaveat:SetText("These choices drive both the zone-entry warning and live proximity alerts "
        .. "(nameplate/mouseover/target/yell/emote and relayed guildmate sightings) against the curated list.")

    -- === Alert On (radio: any / below / at-or-above) ===
    local alertOnLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    alertOnLabel:SetPoint("TOPLEFT", settingsCaveat, "BOTTOMLEFT", 0, -14)
    alertOnLabel:SetText("Alert On:")

    local alertOnChecks = {}
    local belowSlider -- forward-declared: radio handler below shows/hides it
    local prevAlertOnAnchor = alertOnLabel
    for i, opt in ipairs(DANGER_ALERT_ON_OPTIONS) do
        local check = CreateFrame("CheckButton", "DHToolsDangerAlertOn" .. opt.value, content, "UICheckButtonTemplate")
        if i == 1 then
            check:SetPoint("TOPLEFT", prevAlertOnAnchor, "BOTTOMLEFT", -4, -6)
        else
            check:SetPoint("TOPLEFT", prevAlertOnAnchor, "BOTTOMLEFT", 0, -4)
        end
        _G[check:GetName() .. "Text"]:SetText(opt.label)
        check:SetScript("OnClick", function(self)
            if not self:GetChecked() then
                -- Radio group, not an independent toggle - clicking the
                -- already-selected option back off would leave alertOn
                -- pointing at nothing. Reassert it checked, like the
                -- DH-Air-status-row idiom elsewhere in this file.
                self:SetChecked(true)
                return
            end
            Danger.db.settings.alertOn = opt.value
            for _, c in pairs(alertOnChecks) do
                if c ~= self then c:SetChecked(false) end
            end
            if belowSlider then
                belowSlider:SetShown(opt.value == "below")
            end
        end)
        alertOnChecks[opt.value] = check
        prevAlertOnAnchor = check
    end

    -- Anchored tight under "X Levels Below Me" specifically (now the last
    -- radio option, see DANGER_ALERT_ON_OPTIONS reorder above) rather
    -- than a generic -20 gap, so it reads as belonging to that checkbox
    -- (Loopi, 2026-08-14). Low/High/value text sized down to
    -- GameFontHighlightSmall for the same reason - a smaller, tighter
    -- control looks like it's part of the checkbox above it.
    belowSlider = CreateFrame("Slider", "DHToolsDangerBelowSlider", content, "OptionsSliderTemplate")
    belowSlider:SetPoint("TOPLEFT", prevAlertOnAnchor, "BOTTOMLEFT", 24, -6)
    belowSlider:SetWidth(160)
    belowSlider:SetMinMaxValues(1, 20)
    belowSlider:SetValueStep(1)
    if belowSlider.SetObeyStepOnDrag then belowSlider:SetObeyStepOnDrag(true) end
    local belowSliderLow = _G[belowSlider:GetName() .. "Low"]
    local belowSliderHigh = _G[belowSlider:GetName() .. "High"]
    belowSliderLow:SetFontObject("GameFontHighlightSmall")
    belowSliderHigh:SetFontObject("GameFontHighlightSmall")
    belowSliderLow:SetText("1")
    belowSliderHigh:SetText("20")
    local belowSliderText = _G[belowSlider:GetName() .. "Text"]
    belowSliderText:SetFontObject("GameFontHighlightSmall")
    belowSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        Danger.db.settings.belowLevels = value
        belowSliderText:SetText(value .. (value == 1 and " level below" or " levels below"))
    end)

    --------------------------------------------------------------------
    -- Repeat Alert Delay (2026-09-10, Loopi): alerts were firing too
    -- close together, most visibly with roaming packs made of several
    -- same-named mobs - each is a different GUID, so the fixed 20s
    -- per-GUID anti-flicker cooldown (Core.lua's COOLDOWN local, not
    -- exposed here) does nothing to space THOSE apart. This is the
    -- separate, configurable, per-npcID cooldown on top of that one -
    -- see Core.lua's ns.Alert. Applies to every curated category
    -- (Loopi's explicit call, 2026-09-10), not conditional on the Alert
    -- On radio above, so it's NOT tied to belowSlider's show/hide.
    --------------------------------------------------------------------
    local function FormatRepeatDelay(secs)
        if secs <= 0 then return "Off (every instance alerts on its own)" end
        local m, s = math.floor(secs / 60), secs % 60
        if m == 0 then return s .. "s" end
        if s == 0 then return m .. (m == 1 and " min" or " min") end
        return string.format("%dm %ds", m, s)
    end

    local repeatDelayLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    repeatDelayLabel:SetPoint("TOPLEFT", belowSlider, "BOTTOMLEFT", -24, -16)
    repeatDelayLabel:SetText("Repeat Alert Delay:")

    local repeatDelaySlider = CreateFrame("Slider", "DHToolsDangerRepeatDelaySlider", content, "OptionsSliderTemplate")
    repeatDelaySlider:SetPoint("TOPLEFT", repeatDelayLabel, "BOTTOMLEFT", 4, -14)
    repeatDelaySlider:SetWidth(160)
    repeatDelaySlider:SetMinMaxValues(0, 300)
    repeatDelaySlider:SetValueStep(30)
    if repeatDelaySlider.SetObeyStepOnDrag then repeatDelaySlider:SetObeyStepOnDrag(true) end
    local repeatDelaySliderLow = _G[repeatDelaySlider:GetName() .. "Low"]
    local repeatDelaySliderHigh = _G[repeatDelaySlider:GetName() .. "High"]
    repeatDelaySliderLow:SetFontObject("GameFontHighlightSmall")
    repeatDelaySliderHigh:SetFontObject("GameFontHighlightSmall")
    repeatDelaySliderLow:SetText("Off")
    repeatDelaySliderHigh:SetText("5m")
    local repeatDelaySliderText = _G[repeatDelaySlider:GetName() .. "Text"]
    repeatDelaySliderText:SetFontObject("GameFontHighlightSmall")
    repeatDelaySlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value / 30 + 0.5) * 30
        Danger.db.repeatDelay = value
        repeatDelaySliderText:SetText(FormatRepeatDelay(value))
    end)

    local repeatDelayCaveat = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    repeatDelayCaveat:SetPoint("TOPLEFT", repeatDelaySlider, "BOTTOMLEFT", -4, -6)
    repeatDelayCaveat:SetPoint("RIGHT", -16, 0)
    repeatDelayCaveat:SetJustifyH("LEFT")
    repeatDelayCaveat:SetWordWrap(true)
    repeatDelayCaveat:SetText("Minimum time before the same mob TYPE can alert again, even from a "
        .. "different instance of it (e.g. another mob in the same roaming pack). Separate from - and "
        .. "on top of - the fixed 20s anti-flicker cooldown for re-detecting the exact same mob.")

    --------------------------------------------------------------------
    -- Alert Categories (combined 2026-08-14, Loopi - was two separate
    -- 5-row sections, "Alert For" and "Always Alert For"; now one 5-row
    -- table with a checkbox column for each).
    --------------------------------------------------------------------
    local ALERT_COL_X, ALWAYS_COL_X = 150, 280

    local categoriesDivider = content:CreateTexture(nil, "ARTWORK")
    categoriesDivider:SetColorTexture(1, 1, 1, 0.15)
    categoriesDivider:SetHeight(1)
    categoriesDivider:SetPoint("TOPLEFT", repeatDelayCaveat, "BOTTOMLEFT", 0, -14)
    categoriesDivider:SetPoint("RIGHT", -16, 0)

    local categoriesTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    categoriesTitle:SetPoint("TOPLEFT", categoriesDivider, "BOTTOMLEFT", 0, -14)
    categoriesTitle:SetText("Alert Categories:")

    local alertForHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    alertForHeader:SetPoint("LEFT", categoriesTitle, "LEFT", ALERT_COL_X, 0)
    alertForHeader:SetText("Alert For")

    local alwaysHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    alwaysHeader:SetPoint("LEFT", categoriesTitle, "LEFT", ALWAYS_COL_X, 0)
    alwaysHeader:SetText("Always*")

    local alwaysCaption = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    alwaysCaption:SetPoint("TOPLEFT", categoriesTitle, "BOTTOMLEFT", 0, -4)
    alwaysCaption:SetPoint("RIGHT", -16, 0)
    alwaysCaption:SetJustifyH("LEFT")
    alwaysCaption:SetWordWrap(true)
    alwaysCaption:SetText("* Always Alert fires regardless of the level filter above.")

    local alertForChecks, alwaysChecks = {}, {}
    local prevCatRow = alwaysCaption
    for i, cat in ipairs(Danger.ALERT_CATEGORIES) do
        local rowLabel = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        rowLabel:SetPoint("TOPLEFT", prevCatRow, "BOTTOMLEFT", 0, i == 1 and -10 or -6)
        rowLabel:SetText(cat.label)

        local alertForCheck = CreateFrame("CheckButton", "DHToolsDangerAlertFor" .. cat.key, content, "UICheckButtonTemplate")
        alertForCheck:SetPoint("LEFT", rowLabel, "LEFT", ALERT_COL_X, 0)
        _G[alertForCheck:GetName() .. "Text"]:SetText("")
        alertForCheck:SetScript("OnClick", function(self)
            Danger.db.settings.alertFor[cat.key] = self:GetChecked() and true or false
        end)
        alertForChecks[cat.key] = alertForCheck

        local alwaysCheck = CreateFrame("CheckButton", "DHToolsDangerAlwaysAlertFor" .. cat.key, content, "UICheckButtonTemplate")
        alwaysCheck:SetPoint("LEFT", rowLabel, "LEFT", ALWAYS_COL_X, 0)
        _G[alwaysCheck:GetName() .. "Text"]:SetText("")
        alwaysCheck:SetScript("OnClick", function(self)
            Danger.db.settings.alwaysAlertFor[cat.key] = self:GetChecked() and true or false
        end)
        alwaysChecks[cat.key] = alwaysCheck

        prevCatRow = rowLabel
    end

    -- Re-read on every show: the player can toggle nameplates with V at
    -- any time, so a value cached at page-build time would go stale and
    -- reassure them wrongly.
    panel:SetScript("OnShow", function()
        if GetCVar("nameplateShowEnemies") == "1" then
            warn:SetText("Enemy nameplates are ON - close-range detection is working.")
            warn:SetTextColor(0.2, 1, 0.2)
        else
            warn:SetText("Enemy nameplates are OFF (press V). Until you turn them "
                .. "on, only mobs that YELL can be detected - everything else is "
                .. "invisible to this module.")
            warn:SetTextColor(1, 0.3, 0.3)
        end
    end)

    panel.Refresh = function()
        -- -24 (not -4) to leave room for the scrollbar, same reasoning as
        -- the Bavin/Mob Marker pages.
        content:SetWidth(math.max(1, scrollFrame:GetWidth() - 24))

        if Danger.InitDB then Danger.InitDB() end

        if Danger.db then
            zoneWarnCheck:SetChecked(Danger.db.zoneWarn ~= false)
            zoneHideGrayCheck:SetChecked(Danger.db.zoneWarnHideGray == true)
            zoneHideGreenCheck:SetChecked(Danger.db.zoneWarnHideGreen == true)
            UpdateZoneExcludeCheckboxesEnabled()
            shareSyncCheck:SetChecked(Danger.db.shareSync ~= false)
            local repeatDelay = Danger.db.repeatDelay or 120
            repeatDelaySlider:SetValue(repeatDelay)
            repeatDelaySliderText:SetText(FormatRepeatDelay(repeatDelay))
        end

        local s = Danger.db and Danger.db.settings
        if not s then return end

        for _, opt in ipairs(DANGER_ALERT_ON_OPTIONS) do
            alertOnChecks[opt.value]:SetChecked(s.alertOn == opt.value)
        end
        belowSlider:SetValue(s.belowLevels or 3)
        belowSliderText:SetText((s.belowLevels or 3) .. ((s.belowLevels or 3) == 1 and " level below" or " levels below"))
        belowSlider:SetShown(s.alertOn == "below")

        for _, cat in ipairs(Danger.ALERT_CATEGORIES) do
            alertForChecks[cat.key]:SetChecked(s.alertFor[cat.key] == true)
            alwaysChecks[cat.key]:SetChecked(s.alwaysAlertFor[cat.key] == true)
        end
    end

    return panel
end

--------------------------------------------------------------------------
-- Macros page (2026-08-21, Loopi) - the Board (DHMacros.Board_Toggle)
-- does the actual picking/creating; this page is just an entry point
-- plus a live macro-slot readout, since there's nothing else to
-- configure yet.
--------------------------------------------------------------------------

local function CreateMacrosPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Macros")

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Generates ready-to-use macros from the DH-Tools macro library - pick a class, spec, and macro on the Board, then create it directly or copy the text to paste in yourself.")

    local openBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    openBtn:SetSize(140, 22)
    openBtn:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -14)
    openBtn:SetText("Open Macro Board")
    openBtn:SetScript("OnClick", function()
        if DHMacros and DHMacros.Board_Toggle then
            DHMacros.Board_Toggle()
        end
    end)

    local slotsText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    slotsText:SetPoint("TOPLEFT", openBtn, "BOTTOMLEFT", 0, -14)

    panel.Refresh = function()
        local numGlobal, numPerChar = GetNumMacros()
        local maxGlobal = MAX_ACCOUNT_MACROS or 18
        local maxPerChar = MAX_CHARACTER_MACROS or 18
        slotsText:SetText(("General macro slots: %d/%d used\nCharacter-specific macro slots: %d/%d used")
            :format(numGlobal, maxGlobal, numPerChar, maxPerChar))
    end

    return panel
end

--------------------------------------------------------------------------
-- About page
--------------------------------------------------------------------------

local function CreateAboutPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("About DH-Tools")

    local body = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
    body:SetPoint("RIGHT", -16, 0)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetWordWrap(true)

    -- 2026-08-24 (Loopi): credits line - same GameFontHighlight size as
    -- `body`/`bodyBottom` (Loopi tried GameFontHighlightSmall first, two
    -- sizes down, then asked to match the surrounding text instead while
    -- keeping the extra vertical gap around it). Still a separate
    -- FontString even at matching size, purely so the gap above/below it
    -- can be wider than the tighter within-body-paragraph spacing.
    local credits = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    credits:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, 0) -- y set in Refresh, once body's actual height is known
    credits:SetPoint("RIGHT", -16, 0)
    credits:SetJustifyH("LEFT")
    credits:SetJustifyV("TOP")
    credits:SetWordWrap(true)
    credits:SetText("Major DH-Air Contributor: Deves\nBug Testers: Yuri, Cyndrith")

    local bodyBottom = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bodyBottom:SetPoint("TOPLEFT", credits, "BOTTOMLEFT", 0, -16)
    bodyBottom:SetPoint("RIGHT", -16, 0)
    bodyBottom:SetJustifyH("LEFT")
    bodyBottom:SetJustifyV("TOP")
    bodyBottom:SetWordWrap(true)
    bodyBottom:SetText(
        "The Death Happens guild's master addon - lets you activate or "
        .. "deactivate individual modules from one addon. Type /dht list "
        .. "to see what's installed.\n\n"
        .. "Mob Marker's auto-mark/hotkey/target-icon-list functionality "
        .. "was originally its own addon, HC Mob Marker, also by Loopi - "
        .. "merged directly into DH-Tools as its first module.\n\n"
        .. "Copyright (c) 2026 Loopi. All rights reserved.")

    panel.Refresh = function()
        local gameVersion = GetBuildInfo()
        body:SetText("Addon Version: " .. DHTools.VERSION .. "\n"
            .. "Game Version: " .. tostring(gameVersion) .. "\n\n"
            .. "Author: Loopi")
        -- credits' y-anchor depends on body's actual rendered height,
        -- which SetText above just changed (VERSION/gameVersion length
        -- varies) - re-anchor every refresh rather than assuming a fixed
        -- gap, same reasoning FontString height-dependent layouts
        -- elsewhere in this file use.
        credits:ClearAllPoints()
        credits:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -10)
        credits:SetPoint("RIGHT", -16, 0)
    end

    return panel
end

--------------------------------------------------------------------------
-- Frame / navigation
--------------------------------------------------------------------------

-- WoW added SetResizeBounds as a replacement for the older separate
-- SetMinResize/SetMaxResize calls at different points across client
-- versions - try the new one first, fall back to the old pair. Same
-- helper as DH-Air's Board.lua (the one other DH-Tools/DH-Air window
-- that's resizable).
local function ApplyResizeBounds(f, minW, minH, maxW, maxH)
    if f.SetResizeBounds then
        pcall(f.SetResizeBounds, f, minW, minH, maxW, maxH)
    else
        pcall(f.SetMinResize, f, minW, minH)
        pcall(f.SetMaxResize, f, maxW, maxH)
    end
end

local function SelectPage(key)
    for k, b in pairs(navButtons) do
        if k == key then
            b:LockHighlight()
        else
            b:UnlockHighlight()
        end
    end
    -- Hide every non-matching page FIRST, in its own pass, so a Lua error
    -- inside one page's Refresh() (2026-07-28 bug: Bavin's page threw and
    -- aborted this loop midway, leaving Tools still shown underneath it)
    -- can never leave a previous page un-hidden. The Show+Refresh pass is
    -- wrapped in pcall for the same reason - a broken Refresh should never
    -- break page switching for every other page.
    for k, p in pairs(frame.pages) do
        if k ~= key then
            p:Hide()
        end
    end
    local selected = frame.pages[key]
    if selected then
        selected:Show()
        if selected.Refresh then
            local ok, err = pcall(selected.Refresh)
            if not ok then
                DHTools.Print("Config page '" .. key .. "' failed to refresh: " .. tostring(err))
            end
        end
    end
end

-- pageKey: "Tools" | "MobMarker" | "About" (nil defaults to "Tools" on first
-- creation, or leaves whatever page was already showing on later calls).
function DHTools:Config_Open(pageKey)
    if not frame then
        frame = CreateFrame("Frame", "DHToolsConfigFrame", UIParent, "BasicFrameTemplateWithInset")
        frame:SetSize(640, 520)
        frame:SetPoint("CENTER")
        DHTools.InitStandaloneWindow(frame)
        if frame.TitleText then
            frame.TitleText:SetText("DH-Tools Configuration")
        end
        tinsert(UISpecialFrames, "DHToolsConfigFrame")

        -- Resizable by dragging the bottom-right corner grip, like DH-Air's
        -- Board window. Min width is the same as the default (640) rather
        -- than smaller - the Mob Marker page's Target Icons row layout is a
        -- fixed pixel width and doesn't reflow, so letting the window get
        -- narrower than that would just reintroduce clipping on that row.
        -- Height can shrink further since Mob Marker's page scrolls.
        frame:SetResizable(true)
        ApplyResizeBounds(frame, 640, 400, 900, 750)

        local grip = CreateFrame("Button", nil, frame)
        grip:SetSize(16, 16)
        grip:SetPoint("BOTTOMRIGHT", -4, 4)
        grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
        grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
        grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
        grip:SetScript("OnMouseUp", function()
            frame:StopMovingOrSizing()
            -- Mob Marker's content width tracks the scrollframe's width
            -- (set in its own Refresh) - re-run whichever page is showing
            -- so a resize takes effect immediately instead of only on the
            -- next page switch.
            for _, p in pairs(frame.pages) do
                if p:IsShown() and p.Refresh then
                    p.Refresh()
                end
            end
        end)

        local nav = CreateFrame("Frame", nil, frame)
        nav:SetPoint("TOPLEFT", 12, -32)
        nav:SetPoint("BOTTOMLEFT", 12, 12)
        nav:SetWidth(130)

        local navBg = nav:CreateTexture(nil, "BACKGROUND")
        navBg:SetAllPoints()
        navBg:SetColorTexture(0, 0, 0, 0.25)

        local content = CreateFrame("Frame", nil, frame)
        content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 10, 0)
        content:SetPoint("BOTTOMRIGHT", -12, 12)

        -- Built one at a time via pcall, not a single table constructor -
        -- 2026-07-28 bug: Bavin's page had a construction-time error, and
        -- because all five used to be built as fields of one table
        -- literal, that ONE error aborted Config_Open entirely before
        -- frame.pages was ever assigned, nav buttons were ever created, or
        -- frame:Show() ever ran - "completely broken" (every page, not
        -- just Bavin). Building each page independently means a single
        -- broken page can only cost that one page - the rest of the
        -- window still opens and works.
        frame.pages = {}
        local function SafeCreatePage(key, createFn)
            local ok, result = pcall(createFn, content)
            if ok then
                frame.pages[key] = result
            else
                DHTools.Print("Config page '" .. key .. "' failed to build: " .. tostring(result))
            end
        end
        SafeCreatePage("Tools", CreateToolsPanel)
        SafeCreatePage("MobMarker", CreateMobMarkerPanel)
        SafeCreatePage("Quests", CreateQuestsPanel)
        SafeCreatePage("Bavin", CreateBavinPanel)
        SafeCreatePage("Danger", CreateDangerPanel)
        SafeCreatePage("Macros", CreateMacrosPanel)
        SafeCreatePage("About", CreateAboutPanel)

        -- Danger/Macros sit before About deliberately: About is the
        -- trailing "everything else" entry, and a new module belongs
        -- with the other modules above it.
        local pageNames = { "Tools", "MobMarker", "Quests", "Bavin", "Danger", "Macros", "About" }
        local pageLabels = { Tools = "Tools", MobMarker = "Mob Marker", Quests = "Quests", Bavin = "Bavin", Danger = "Danger", Macros = "Macros", About = "About" }
        local prevBtn
        for _, name in ipairs(pageNames) do
            local btn = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
            btn:SetSize(112, 24)
            if prevBtn then
                btn:SetPoint("TOPLEFT", prevBtn, "BOTTOMLEFT", 0, -4)
            else
                btn:SetPoint("TOPLEFT", 8, -8)
            end
            btn:SetText(pageLabels[name])
            btn:SetScript("OnClick", function() SelectPage(name) end)
            navButtons[name] = btn
            prevBtn = btn
        end

        SelectPage(pageKey or "Tools")
        frame:Show()
        return
    end

    frame:Show()
    if pageKey then
        SelectPage(pageKey)
    else
        for k, p in pairs(frame.pages) do
            if p:IsShown() and p.Refresh then
                p.Refresh()
            end
        end
    end
end
