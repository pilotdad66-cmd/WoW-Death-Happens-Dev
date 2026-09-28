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

-- 2026-09-28 (Chris): DH-Layers removed entirely - Blizzard doesn't
-- expose the API calls this would have needed. See claude\archive\
-- DH-Layers\ for the retired PROFILE.md/STATUS.md (it never had any
-- runtime code to begin with - see ROADMAP.md's own "Shelved" row).
--
-- DH-Danger was here until 2026-08-07, DH-Air until 2026-08-20's merge
-- into DH-Tools as a real module (RegisterModule("air") - see
-- DH-Air-Merge-Design.md decision 2). Both now have real runtime code
-- and render from the live module registry above like any other
-- module - having either in both places would list it twice.
local PLACEHOLDER_MODULES = {}

local function CreateToolsPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    -- 2026-09-28: scrollable now, same pattern as every other populated
    -- page (Mob Marker/Bavin/Danger/Store/About) - this is the FIRST
    -- page shown on open, and its row count only grows as modules are
    -- added (7 real modules already), so it's both the most likely
    -- source of Chris's "rows appear outside the bottom of the window"
    -- report and the one most likely to overflow again later.
    local scrollFrame = CreateFrame("ScrollFrame", "DHToolsToolsScroll", panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -8, 8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 480) -- width set in Refresh; generous fixed estimate
    scrollFrame:SetScrollChild(content)

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Modules")

    local hint = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
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
    -- Rows whose module declares `requires` (2026-09-28, DH-Store
    -- dependency mechanism) - key -> { check, requiresKey, normalColor }.
    -- Tracked separately from `checks` (every real-module row) so
    -- UpdateDependentGating below only touches the ones that need it.
    local dependentRows = {}

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

        local check = CreateFrame("CheckButton", "DHToolsToolsCheck" .. rowNum, content, "UICheckButtonTemplate")
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

        local desc = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
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
            -- A click here can cascade OTHER rows too (enabling a
            -- dependent auto-enables its requirement; disabling a
            -- requirement auto-disables its dependents - see Core.lua's
            -- SetModuleEnabled) - Refresh syncs every checkbox and re-
            -- gates dependent rows immediately, not just this one.
            panel.Refresh()
        end)
        checks[key] = check
        if def.requires then
            local checkText = _G[check:GetName() .. "Text"]
            local r, g, b = checkText:GetTextColor()
            dependentRows[key] = { check = check, requiresKey = def.requires, normalColor = { r, g, b } }
        end
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

    -- 2026-09-28 (DH-Store dependency mechanism): re-evaluated live, not
    -- baked in once at row-creation time like AddRow's own static
    -- `comingSoon` grey - a dependent row has to react the instant its
    -- requirement's OWN checkbox is clicked on this same page, without a
    -- close/reopen. Tag wording ("requires <Name>") is Chris's call
    -- (2026-09-28).
    local function UpdateDependentGating()
        for key, row in pairs(dependentRows) do
            local def = DHTools.modules[key]
            local reqDef = DHTools.modules[row.requiresKey]
            local checkText = _G[row.check:GetName() .. "Text"]
            if DHTools.IsModuleEnabled(row.requiresKey) then
                checkText:SetText(def.name)
                checkText:SetTextColor(unpack(row.normalColor))
                row.check:Enable()
            else
                checkText:SetText(def.name .. "  |cff888888(requires " ..
                    (reqDef and reqDef.name or row.requiresKey) .. ")|r")
                checkText:SetTextColor(0.5, 0.5, 0.5)
                row.check:SetChecked(false)
                row.check:Disable()
            end
        end
    end

    panel.Refresh = function()
        -- -24 (not -4) to leave room for the scrollbar, same reasoning as
        -- every other scrollable page here.
        content:SetWidth(math.max(1, scrollFrame:GetWidth() - 24))

        for key, check in pairs(checks) do
            check:SetChecked(DHTools.IsModuleEnabled(key))
        end
        UpdateDependentGating()
    end
    panel.Refresh() -- correct greyed/enabled state on first paint, not just after the first click

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

    -- 2026-09-28 (Chris): Clear All and Update share one row instead of
    -- stacking - saves a row of vertical space; the "not saved yet" note
    -- moves above both buttons since it applies to either one.
    local saveNote = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    saveNote:SetPoint("TOPLEFT", secTitle1, "BOTTOMLEFT", 8, rowsBottom - 14)
    saveNote:SetTextColor(1, 0.65, 0.1)
    saveNote:SetText("Changes to the icon list are not saved until you click Update.")

    local clearAllBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    clearAllBtn:SetSize(100, 22)
    clearAllBtn:SetPoint("TOPLEFT", saveNote, "BOTTOMLEFT", 0, -10)
    clearAllBtn:SetText("Clear All")
    clearAllBtn:SetScript("OnClick", function()
        for i = 1, MM_ROW_COUNT do
            mmWorking[i].name = ""
            mmRows[i].edit:SetText("")
        end
    end)

    local updateBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    updateBtn:SetSize(100, 22)
    updateBtn:SetPoint("LEFT", clearAllBtn, "RIGHT", 10, 0)
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
    content:SetSize(1, 120) -- width set in Refresh; only one user setting
                             -- lives on this page now (2026-09-28) - the
                             -- recipient/editor/Credits officer section
                             -- moved to the new Officer Settings page.
    scrollFrame:SetScrollChild(content)

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Bavin")

    local hint = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("The recipient is the guild's current mail collector; the mailbox helper and bag highlighting (a later milestone) will target whoever is set here. Recipient/editor management and the Credit & Reputation System have moved to the Officer Settings page.")

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

    panel.Refresh = function()
        -- -24 (not -4) to leave room for the scrollbar - same reasoning
        -- as Mob Marker's page (see its Refresh comment above).
        content:SetWidth(math.max(1, scrollFrame:GetWidth() - 24))

        Bavin.InitDB()
        mouseoverCheck:SetChecked(Bavin.db and Bavin.db.mouseoverChatTooltips)
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
    -- 2026-09-28 (Chris): was anchored off zoneHideGrayCheck (a RIGHT-side
    -- checkbox whose own x depends on the "Exclude" label's rendered text
    -- width) instead of the left-column baseline - every section from
    -- here down inherited that unpredictable rightward drift. Anchored
    -- to zoneWarnCheck instead (same row, true left-column x); its
    -- BOTTOMLEFT y is identical either way since zoneHideGrayCheck sits
    -- on zoneWarnCheck's own row, not below it.
    local shareDivider = content:CreateTexture(nil, "ARTWORK")
    shareDivider:SetColorTexture(1, 1, 1, 0.15)
    shareDivider:SetHeight(1)
    shareDivider:SetPoint("TOPLEFT", zoneWarnCheck, "BOTTOMLEFT", 0, -18)
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

    -- 2026-09-28 (Chris): one row instead of three stacked - saves two
    -- row-heights of vertical space. Each option after the first anchors
    -- off the PREVIOUS option's own text (not its checkbox frame, which
    -- is a fixed ~24px regardless of label length) so labels of
    -- different widths ("Any Level" vs "My Level or Above") don't
    -- overlap. firstAlertOnCheck is kept separately (not just the loop's
    -- final value) so belowSlider below can anchor at the row's LEFT
    -- edge, matching its original indent under the row rather than
    -- trailing off the rightmost (3rd) option.
    local alertOnChecks = {}
    local belowSlider -- forward-declared: radio handler below shows/hides it
    local firstAlertOnCheck
    local prevAlertOnText
    for i, opt in ipairs(DANGER_ALERT_ON_OPTIONS) do
        local check = CreateFrame("CheckButton", "DHToolsDangerAlertOn" .. opt.value, content, "UICheckButtonTemplate")
        local checkText = _G[check:GetName() .. "Text"]
        if i == 1 then
            check:SetPoint("TOPLEFT", alertOnLabel, "BOTTOMLEFT", -4, -6)
            firstAlertOnCheck = check
        else
            check:SetPoint("LEFT", prevAlertOnText, "RIGHT", 16, 0)
        end
        checkText:SetText(opt.label)
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
        prevAlertOnText = checkText
    end

    -- Anchored under the row's LEFT edge (firstAlertOnCheck), indented to
    -- read as belonging to the row above rather than the window's left
    -- margin (Loopi, 2026-08-14 - same indent amount, now relative to
    -- the row's start instead of trailing the 3rd option specifically
    -- now that all three sit on one row, 2026-09-28). Low/High/value
    -- text sized down to GameFontHighlightSmall for the same reason - a
    -- smaller, tighter control looks like it's part of the row above it.
    belowSlider = CreateFrame("Slider", "DHToolsDangerBelowSlider", content, "OptionsSliderTemplate")
    belowSlider:SetPoint("TOPLEFT", firstAlertOnCheck, "BOTTOMLEFT", 24, -6)
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

    -- 2026-09-28 (Chris): folded onto the SAME row as "Always*" instead
    -- of its own row below - "*Ignore Level Filters" in a dimmer gray
    -- right next to the header it's annotating, one row of vertical
    -- space saved.
    local alwaysNote = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    alwaysNote:SetPoint("LEFT", alwaysHeader, "RIGHT", 4, 0)
    alwaysNote:SetText("*Ignore Level Filters")

    local alertForChecks, alwaysChecks = {}, {}
    local prevCatRow = categoriesTitle
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

    -- 2026-09-28 (Chris): two separate rows instead of one FontString with
    -- an embedded "\n" - a single string's two lines can't be
    -- independently justified (the shorter "General" label left its own
    -- number sitting well left of "Character-specific"'s number, reading
    -- as unaligned) and there was no controllable gap between them. Two
    -- rows fixes both: each is its own left-justified line, with a real
    -- anchor gap in between.
    local slotsGlobalText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    slotsGlobalText:SetPoint("TOPLEFT", openBtn, "BOTTOMLEFT", 0, -14)
    slotsGlobalText:SetJustifyH("LEFT")

    local slotsPerCharText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    slotsPerCharText:SetPoint("TOPLEFT", slotsGlobalText, "BOTTOMLEFT", 0, -8)
    slotsPerCharText:SetJustifyH("LEFT")

    panel.Refresh = function()
        local numGlobal, numPerChar = GetNumMacros()
        local maxGlobal = MAX_ACCOUNT_MACROS or 18
        local maxPerChar = MAX_CHARACTER_MACROS or 18
        slotsGlobalText:SetText(("General macro slots: %d/%d used"):format(numGlobal, maxGlobal))
        slotsPerCharText:SetText(("Character-specific macro slots: %d/%d used"):format(numPerChar, maxPerChar))
    end

    return panel
end

-- Store page - officer roster/primary officer and pricing config
-- (question #9's own Config.lua-additions scope: catalog browsing lives
-- in DH-Store's own window, DHStoreFrame via /dhs - this page is just
-- the officer-facing settings DHStore\Core.lua's slash commands also
-- expose, for anyone who'd rather use the Tools window).
--
-- 2026-09-28 (Chris), full rework:
-- - Scrollable now, same scrollFrame+content pattern as Mob
--   Marker/Bavin/Danger above - rows were spilling past the window's
--   bottom edge, the one populated page here that didn't already guard
--   against that.
-- - Primary Officer moved first (with its own explanation - it's the
--   one that matters most, receiving every purchase mail); Store
--   Officers follows, also explained.
-- - Store Officers rebuilt as an add-one-at-a-time list with
--   type-to-filter roster suggestions and a removable current-officers
--   list - mirrors Bavin's own Editors section 1:1 (Chris's explicit
--   ask: "the way editors does in the Bavin config"), replacing the old
--   raw comma-separated text box that had no autocomplete at all.
--   Primary Officer gets the same suggestion pool.
-- - The credit-price explanation now sits directly below the ratio box
--   it explains (was below both discount checkboxes, reading as if it
--   explained THEM instead).
-- - The two discount checkboxes are one row now: "Apply Rep Tier Cost
--   Reduction to [ ] Gold Price and/or [ ] Credits Price."
-- - A brief description up top stands in for a user-facing settings
--   section - everything below is still officer-only, and there isn't
--   an ordinary-member setting to show yet.
local STORE_SUGGEST_ROWS = 2

local function CreateStorePanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local scrollFrame = CreateFrame("ScrollFrame", "DHToolsStoreScroll", panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -8, 8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 120) -- width set in Refresh; officer setup moved to
                             -- the Officer Settings page (2026-09-28) -
                             -- nothing here yet for an ordinary member.
    scrollFrame:SetScrollChild(content)

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Store")

    local hint = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Guild-only buyout store - officers list items at a gold price, priced in Bavin Credits too at a configurable ratio with a rep-tier discount. Browse and buy with /dhs. Officer setup (primary/store officers, credit ratio, rep-tier discount) has moved to the Officer Settings page.")

    panel.Refresh = function()
        -- -24 (not -4) to leave room for the scrollbar, same reasoning as
        -- every other scrollable page here.
        content:SetWidth(math.max(1, scrollFrame:GetWidth() - 24))
    end

    return panel
end

--------------------------------------------------------------------------
-- Officer Settings page (2026-09-28, Chris) - one consolidated page for
-- every module's officer-gated settings, instead of scattering them
-- across each module's own page. Its OWN nav button (built in the nav
-- loop below) only shows for accounts that pass DHTools.IsOfficerLocal()
-- (see Core.lua's new shared rank-gate) - everyone else never even sees
-- the button, same "hide entirely, don't just disable" idea the rest of
-- DH-Tools' permission model already uses. The individual widgets below
-- are otherwise UNCHANGED from their old homes on Bavin's/Store's own
-- pages and still gate through each MODULE's own existing permission
-- check (Bavin.CanManageRecipient/CanManageEditors,
-- Store.CanManageStoreOfficersLocal) - moving them here only changes
-- WHERE the controls live, not who is allowed to use them once visible.
--------------------------------------------------------------------------

local function CreateOfficerSettingsPanel(parent)
    local Bavin = DHTools.Bavin
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local scrollFrame = CreateFrame("ScrollFrame", "DHToolsOfficerScroll", panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -8, 8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 1300) -- width set in Refresh; generous fixed estimate
                              -- for Bavin's + Store's combined officer
                              -- sections plus the new rank-threshold
                              -- control up top - pad rather than trim,
                              -- same approach every other scrollable page
                              -- here already uses.
    scrollFrame:SetScrollChild(content)

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Officer Settings")

    local hint = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Every officer-gated setting across all modules, in one place. This button is only visible to guild ranks 0 through the threshold below, plus the author account (always, regardless of rank).")

    --------------------------------------------------------------------
    -- Who can see this button at all (2026-09-28, Chris) - DH-Tools-wide,
    -- not per-module. See Core.lua's DHTools.IsOfficerLocal/IsOfficerName.
    --------------------------------------------------------------------
    local rankLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rankLabel:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -16)
    rankLabel:SetText("Show this Officer Settings button to guild rank 0 through:")

    local rankEdit = CreateFrame("EditBox", "DHToolsOfficerRankEdit", content, "InputBoxTemplate")
    rankEdit:SetSize(40, 20)
    rankEdit:SetPoint("LEFT", rankLabel, "RIGHT", 10, -2)
    rankEdit:SetAutoFocus(false)
    rankEdit:SetNumeric(true)
    rankEdit:SetMaxLetters(1)
    rankEdit:SetScript("OnEscapePressed", rankEdit.ClearFocus)

    local rankBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    rankBtn:SetSize(60, 20)
    rankBtn:SetPoint("LEFT", rankEdit, "RIGHT", 6, 0)
    rankBtn:SetText("Set")

    local rankStatus = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rankStatus:SetPoint("LEFT", rankBtn, "RIGHT", 8, 0)

    local rankDesc = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    rankDesc:SetPoint("TOPLEFT", rankLabel, "BOTTOMLEFT", 0, -6)
    rankDesc:SetPoint("RIGHT", -16, 0)
    rankDesc:SetJustifyH("LEFT")
    rankDesc:SetWordWrap(true)
    rankDesc:SetText("Guild rank number, where 0 = Guild Master and higher numbers are lower ranks (default 3). Takes effect next time this window opens. The author account can always see this button regardless of rank.")

    rankBtn:SetScript("OnClick", function()
        local rank = tonumber(rankEdit:GetText())
        if not rank or rank < 0 or rank > 9 then
            rankStatus:SetText("|cffff3333Enter 0-9|r")
            return
        end
        DHTools.db.officerVisibleMaxRank = rank
        rankEdit:ClearFocus()
        rankStatus:SetText("|cff33ff99Set!|r")
        C_Timer.After(2, function() rankStatus:SetText("") end)
    end)
    rankEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus(); rankBtn:Click() end)

    local topDivider = content:CreateTexture(nil, "ARTWORK")
    topDivider:SetColorTexture(1, 1, 1, 0.15)
    topDivider:SetHeight(1)
    topDivider:SetPoint("TOPLEFT", rankDesc, "BOTTOMLEFT", -4, -14)
    topDivider:SetPoint("RIGHT", -16, 0)

    --------------------------------------------------------------------
    -- Bavin (moved from Bavin's own Config page, 2026-09-28 - see that
    -- page for the one user setting it kept)
    --------------------------------------------------------------------
    local bavinHeading = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    bavinHeading:SetPoint("TOPLEFT", topDivider, "BOTTOMLEFT", 4, -14)
    bavinHeading:SetText("Bavin")

    local lockedNote = content:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    lockedNote:SetPoint("TOPLEFT", bavinHeading, "BOTTOMLEFT", 0, -8)
    lockedNote:SetPoint("RIGHT", -16, 0)
    lockedNote:SetJustifyH("LEFT")
    lockedNote:SetWordWrap(true)

    local BAVIN_SUGGEST_ROWS = 2

    local function BuildBavinSuggestPool(anchor)
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

    local function PopulateBavinSuggestions(buttons, typed, onPick)
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

    local recipientSuggestButtons = BuildBavinSuggestPool(rosterHint)

    local function UpdateRecipientSuggestions(typed)
        PopulateBavinSuggestions(recipientSuggestButtons, typed, function(name)
            recipientEdit:SetText(name)
            recipientEdit:ClearFocus()
            PopulateBavinSuggestions(recipientSuggestButtons, "", function() end)
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

    --------------------------------------------------------------------
    -- Editors (additive, guild-leader-only) - add-by-name with the same
    -- capped suggestion pool, then a small removable list.
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

    local editorSuggestButtons = BuildBavinSuggestPool(editorAddLabel)

    local function UpdateEditorSuggestions(typed)
        PopulateBavinSuggestions(editorSuggestButtons, typed, function(name)
            editorAddEdit:SetText(name)
            editorAddEdit:ClearFocus()
            PopulateBavinSuggestions(editorSuggestButtons, "", function() end)
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

    --------------------------------------------------------------------
    -- Credit & Reputation System - a button to open Bavin's own separate
    -- Rep & Credit Config window. Deliberately NOT nested inside the
    -- recipient/editors gate above - Designated Officers (Credits.lua's
    -- own officer list) aren't necessarily the same people as Bavin's
    -- recipient/editors, so this button gets its own independent
    -- Enable/Disable check in Refresh below.
    --------------------------------------------------------------------
    local creditsTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    creditsTitle:SetText("Credit & Reputation System (in development):")

    local creditsOpenBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    creditsOpenBtn:SetSize(200, 22)
    creditsOpenBtn:SetPoint("TOPLEFT", creditsTitle, "BOTTOMLEFT", 4, -8)
    creditsOpenBtn:SetText("Open Bavin Rep & Credit Config")
    creditsOpenBtn:SetScript("OnClick", function()
        if Bavin.CreditsConfig_Toggle then
            Bavin.CreditsConfig_Toggle()
        end
    end)

    local creditsLockedNote = content:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    creditsLockedNote:SetPoint("LEFT", creditsOpenBtn, "RIGHT", 10, 0)
    creditsLockedNote:SetText("|cffff3333Designated Officer/guild leader/author only.|r")
    creditsLockedNote:Hide()

    RebuildCurrentEditorRows = function()
        local canManage = Bavin.CanManageEditors()
        local editors = (Bavin.db and Bavin.db.editors) or {}
        local lastShown -- last VISIBLE row this pass, or nil if the list is empty
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
                lastShown = row
            end
        end

        creditsTitle:ClearAllPoints()
        if lastShown then
            creditsTitle:SetPoint("TOPLEFT", lastShown, "BOTTOMLEFT", -4, -16)
        else
            creditsTitle:SetPoint("TOPLEFT", currentEditorsTitle, "BOTTOMLEFT", 0, -16)
        end
    end

    --------------------------------------------------------------------
    -- Store (moved from Store's own Config page, 2026-09-28 - see that
    -- page for its brief description)
    --------------------------------------------------------------------
    local storeHeading = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    storeHeading:SetPoint("TOPLEFT", creditsOpenBtn, "BOTTOMLEFT", -4, -20)
    storeHeading:SetText("Store")

    local STORE_SUGGEST_ROWS = 2

    local function BuildStoreSuggestPool(anchor)
        local buttons = {}
        local prevAnchor = anchor
        for i = 1, STORE_SUGGEST_ROWS do
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

    local function PopulateStoreSuggestions(buttons, typed, onPick)
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
    -- Primary Officer - the one who receives every purchase-request mail
    --------------------------------------------------------------------
    local primaryLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    primaryLabel:SetPoint("TOPLEFT", storeHeading, "BOTTOMLEFT", 0, -14)
    primaryLabel:SetText("Primary Officer:")

    local primaryEdit = CreateFrame("EditBox", "DHToolsStorePrimaryEdit", content, "InputBoxTemplate")
    primaryEdit:SetSize(140, 20)
    primaryEdit:SetPoint("LEFT", primaryLabel, "RIGHT", 10, -2)
    primaryEdit:SetAutoFocus(false)
    primaryEdit:SetMaxLetters(24)
    primaryEdit:SetScript("OnEscapePressed", primaryEdit.ClearFocus)

    local primaryBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    primaryBtn:SetSize(60, 20)
    primaryBtn:SetPoint("LEFT", primaryEdit, "RIGHT", 6, 0)
    primaryBtn:SetText("Set")

    local primaryStatus = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    primaryStatus:SetPoint("LEFT", primaryBtn, "RIGHT", 8, 0)

    local primaryDesc = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    primaryDesc:SetPoint("TOPLEFT", primaryLabel, "BOTTOMLEFT", 0, -6)
    primaryDesc:SetPoint("RIGHT", -16, 0)
    primaryDesc:SetJustifyH("LEFT")
    primaryDesc:SetWordWrap(true)
    primaryDesc:SetText("Receives all store purchase request mails.")

    local primarySuggestButtons = BuildStoreSuggestPool(primaryDesc)

    local function UpdatePrimarySuggestions(typed)
        PopulateStoreSuggestions(primarySuggestButtons, typed, function(name)
            primaryEdit:SetText(name)
            primaryEdit:ClearFocus()
            PopulateStoreSuggestions(primarySuggestButtons, "", function() end)
        end)
    end
    primaryEdit:SetScript("OnTextChanged", function(self)
        UpdatePrimarySuggestions(self:GetText())
    end)

    local function TrySetPrimary()
        local typed = primaryEdit:GetText()
        primaryEdit:ClearFocus()
        UpdatePrimarySuggestions("")
        if not DHTools.Store.CanManageStoreOfficersLocal() then
            DHTools.Store.Print("Refused - guild leader, donation recipient, or author account only.")
            return
        end
        DHTools.Store.SetPrimaryOfficer(typed)
        primaryStatus:SetText("|cff33ff99Set!|r")
        C_Timer.After(2, function() primaryStatus:SetText("") end)
        panel.Refresh()
    end
    primaryBtn:SetScript("OnClick", TrySetPrimary)
    primaryEdit:SetScript("OnEnterPressed", TrySetPrimary)

    --------------------------------------------------------------------
    -- Store Officers - add-by-name with the same capped suggestion pool
    -- and a removable current-officer list, mirroring Bavin's Editors
    -- section above.
    --------------------------------------------------------------------
    local officersTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    officersTitle:SetPoint("TOPLEFT", primarySuggestButtons[STORE_SUGGEST_ROWS], "BOTTOMLEFT", -4, -14)
    officersTitle:SetText("Store Officers:")

    local officersDesc = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    officersDesc:SetPoint("TOPLEFT", officersTitle, "BOTTOMLEFT", 4, -4)
    officersDesc:SetPoint("RIGHT", -16, 0)
    officersDesc:SetJustifyH("LEFT")
    officersDesc:SetWordWrap(true)
    officersDesc:SetText("Can manage listings and these settings, in addition to the Primary Officer.")

    local officerAddLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    officerAddLabel:SetPoint("TOPLEFT", officersDesc, "BOTTOMLEFT", -4, -8)
    officerAddLabel:SetText("Add officer:")

    local officerAddEdit = CreateFrame("EditBox", "DHToolsStoreOfficerAddEdit", content, "InputBoxTemplate")
    officerAddEdit:SetSize(140, 20)
    officerAddEdit:SetPoint("LEFT", officerAddLabel, "RIGHT", 10, -2)
    officerAddEdit:SetAutoFocus(false)
    officerAddEdit:SetMaxLetters(24)
    officerAddEdit:SetScript("OnEscapePressed", officerAddEdit.ClearFocus)

    local officerAddBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    officerAddBtn:SetSize(60, 20)
    officerAddBtn:SetPoint("LEFT", officerAddEdit, "RIGHT", 6, 0)
    officerAddBtn:SetText("Add")

    local officerAddStatus = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    officerAddStatus:SetPoint("LEFT", officerAddBtn, "RIGHT", 8, 0)

    local officerSuggestButtons = BuildStoreSuggestPool(officerAddLabel)

    local function UpdateOfficerSuggestions(typed)
        PopulateStoreSuggestions(officerSuggestButtons, typed, function(name)
            officerAddEdit:SetText(name)
            officerAddEdit:ClearFocus()
            PopulateStoreSuggestions(officerSuggestButtons, "", function() end)
        end)
    end
    officerAddEdit:SetScript("OnTextChanged", function(self)
        UpdateOfficerSuggestions(self:GetText())
    end)

    -- Forward-declared: TryAddOfficer (defined next) needs to refresh the
    -- current-officers list below, which isn't built yet at this point.
    local RebuildCurrentOfficerRows

    local function TryAddOfficer()
        local typed = officerAddEdit:GetText()
        officerAddEdit:ClearFocus()
        UpdateOfficerSuggestions("")
        if typed == "" then return end
        if not DHTools.Store.CanManageStoreOfficersLocal() then
            officerAddStatus:SetText("|cffff3333Refused (officers only)|r")
            return
        end
        local current = {}
        local db = DHTools.Store.db
        if db then
            for _, n in ipairs(db.officers) do
                if n == typed then
                    officerAddStatus:SetText("|cffff3333Already an officer|r")
                    return
                end
                table.insert(current, n)
            end
        end
        table.insert(current, typed)
        DHTools.Store.SetStoreOfficers(current)
        officerAddEdit:SetText("")
        officerAddStatus:SetText("|cff33ff99Added!|r")
        C_Timer.After(2, function() officerAddStatus:SetText("") end)
        if RebuildCurrentOfficerRows then RebuildCurrentOfficerRows() end
    end
    officerAddBtn:SetScript("OnClick", TryAddOfficer)
    officerAddEdit:SetScript("OnEnterPressed", TryAddOfficer)

    local currentOfficersTitle = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    currentOfficersTitle:SetPoint("TOPLEFT", officerSuggestButtons[STORE_SUGGEST_ROWS], "BOTTOMLEFT", -4, -10)
    currentOfficersTitle:SetText("Current officers:")

    local STORE_CURRENT_OFFICER_ROWS = 6
    local currentOfficerRows = {}
    local prevOfficerAnchor = currentOfficersTitle
    for i = 1, STORE_CURRENT_OFFICER_ROWS do
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(300, 18)
        if i == 1 then
            row:SetPoint("TOPLEFT", prevOfficerAnchor, "BOTTOMLEFT", 4, -6)
        else
            row:SetPoint("TOPLEFT", prevOfficerAnchor, "BOTTOMLEFT", 0, -2)
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
        currentOfficerRows[i] = row
        prevOfficerAnchor = row
    end

    --------------------------------------------------------------------
    -- Credit ratio + rep-tier discount - dynamically re-anchored below
    -- whatever the officer list actually shows (see RebuildCurrentOfficerRows).
    --------------------------------------------------------------------
    local ratioLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ratioLabel:SetText("Credits per Gold:")

    local ratioEdit = CreateFrame("EditBox", "DHToolsStoreRatioEdit", content, "InputBoxTemplate")
    ratioEdit:SetSize(60, 20)
    ratioEdit:SetPoint("LEFT", ratioLabel, "RIGHT", 10, -2)
    ratioEdit:SetAutoFocus(false)
    ratioEdit:SetScript("OnEscapePressed", ratioEdit.ClearFocus)

    local ratioBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    ratioBtn:SetSize(60, 20)
    ratioBtn:SetPoint("LEFT", ratioEdit, "RIGHT", 6, 0)
    ratioBtn:SetText("Set")
    ratioBtn:SetScript("OnClick", function()
        if not DHTools.Store.CanManageStoreOfficersLocal() then
            DHTools.Store.Print("Refused - guild leader, donation recipient, or author account only.")
            return
        end
        local ratio = tonumber(ratioEdit:GetText())
        if not ratio then
            DHTools.Store.Print("Enter a number, e.g. 10.")
            return
        end
        DHTools.Store.db.creditGoldRatio = ratio
        panel.Refresh()
    end)

    local ratioDesc = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ratioDesc:SetPoint("TOPLEFT", ratioLabel, "BOTTOMLEFT", 0, -6)
    ratioDesc:SetPoint("RIGHT", -16, 0)
    ratioDesc:SetJustifyH("LEFT")
    ratioDesc:SetWordWrap(true)
    ratioDesc:SetText("Credits price = gold price x this ratio, then the buyer's own tier discount.")

    local discountLabel1 = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    discountLabel1:SetPoint("TOPLEFT", ratioDesc, "BOTTOMLEFT", 0, -12)
    discountLabel1:SetText("Apply Rep Tier Cost Reduction to")

    local goldCheck = CreateFrame("CheckButton", "DHToolsStoreGoldDiscountCheck", content, "UICheckButtonTemplate")
    goldCheck:SetPoint("LEFT", discountLabel1, "RIGHT", 2, 0)
    _G[goldCheck:GetName() .. "Text"]:SetText("Gold Price")
    goldCheck:SetScript("OnClick", function(self)
        if not DHTools.Store.CanManageStoreOfficersLocal() then
            self:SetChecked(DHTools.Store.db.discountAppliesToGold)
            DHTools.Store.Print("Refused - guild leader, donation recipient, or author account only.")
            return
        end
        DHTools.Store.db.discountAppliesToGold = self:GetChecked() and true or false
    end)

    local discountLabel2 = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    discountLabel2:SetPoint("LEFT", _G[goldCheck:GetName() .. "Text"], "RIGHT", 2, 0)
    discountLabel2:SetText("and/or")

    local creditCheck = CreateFrame("CheckButton", "DHToolsStoreCreditDiscountCheck", content, "UICheckButtonTemplate")
    creditCheck:SetPoint("LEFT", discountLabel2, "RIGHT", 2, 0)
    _G[creditCheck:GetName() .. "Text"]:SetText("Credits Price")
    creditCheck:SetScript("OnClick", function(self)
        if not DHTools.Store.CanManageStoreOfficersLocal() then
            self:SetChecked(DHTools.Store.db.discountAppliesToCredits)
            DHTools.Store.Print("Refused - guild leader, donation recipient, or author account only.")
            return
        end
        DHTools.Store.db.discountAppliesToCredits = self:GetChecked() and true or false
    end)

    local storeStatus = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    storeStatus:SetPoint("TOPLEFT", discountLabel1, "BOTTOMLEFT", 0, -16)
    storeStatus:SetPoint("RIGHT", -16, 0)
    storeStatus:SetJustifyH("LEFT")
    storeStatus:SetWordWrap(true)

    RebuildCurrentOfficerRows = function()
        local canManage = DHTools.Store.CanManageStoreOfficersLocal()
        local officers = (DHTools.Store.db and DHTools.Store.db.officers) or {}
        local lastShown -- last VISIBLE row this pass, or nil if the list is empty
        for i, row in ipairs(currentOfficerRows) do
            local name = officers[i]
            if not name then
                row:Hide()
            else
                row:Show()
                row.text:SetText(name)
                row.removeBtn:SetScript("OnClick", function()
                    local list = {}
                    for _, n in ipairs(officers) do
                        if n ~= name then table.insert(list, n) end
                    end
                    DHTools.Store.SetStoreOfficers(list)
                    RebuildCurrentOfficerRows()
                end)
                if canManage then
                    row.removeBtn:Enable()
                else
                    row.removeBtn:Disable()
                end
                lastShown = row
            end
        end

        ratioLabel:ClearAllPoints()
        if lastShown then
            ratioLabel:SetPoint("TOPLEFT", lastShown, "BOTTOMLEFT", -4, -16)
        else
            ratioLabel:SetPoint("TOPLEFT", currentOfficersTitle, "BOTTOMLEFT", 0, -16)
        end
    end

    panel.Refresh = function()
        -- -24 (not -4) to leave room for the scrollbar, same reasoning as
        -- every other scrollable page here.
        content:SetWidth(math.max(1, scrollFrame:GetWidth() - 24))

        rankEdit:SetText(tostring((DHTools.db and DHTools.db.officerVisibleMaxRank) or 3))

        --------------------------------------------------------------
        -- Bavin section
        --------------------------------------------------------------
        Bavin.InitDB()
        local canManageRecipient = Bavin.CanManageRecipient()
        local canManageEditors = Bavin.CanManageEditors()
        lockedNote:SetShown(not (canManageRecipient and canManageEditors))
        if not canManageRecipient and not canManageEditors then
            lockedNote:SetText("|cffff3333You can't manage the recipient (Bavin only) or editors (officers only) - read-only.|r")
        elseif not canManageRecipient then
            lockedNote:SetText("|cffff3333You can't change the recipient (Bavin only).|r")
        elseif not canManageEditors then
            lockedNote:SetText("|cffff3333You can't manage editors (officers only).|r")
        end

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

        local canOpenCredits = (Bavin.CanManageCreditsConfigLocal and Bavin.CanManageCreditsConfigLocal())
            or (Bavin.CanManageCreditsOfficers and Bavin.CanManageCreditsOfficers())
        if canOpenCredits then
            creditsOpenBtn:Enable()
            creditsLockedNote:Hide()
        else
            creditsOpenBtn:Disable()
            creditsLockedNote:Show()
        end

        --------------------------------------------------------------
        -- Store section
        --------------------------------------------------------------
        local db = DHTools.Store.db
        if not db then
            storeStatus:SetText("Store module isn't enabled yet - turn it on from the Tools page.")
            return
        end

        local canManageStore = DHTools.Store.CanManageStoreOfficersLocal()

        primaryEdit:SetText(db.primaryOfficer or "")
        UpdatePrimarySuggestions("")
        primaryEdit:EnableMouse(canManageStore)
        if not canManageStore then primaryEdit:ClearFocus() end
        primaryEdit:SetTextColor(canManageStore and 1 or 0.5, canManageStore and 1 or 0.5, canManageStore and 1 or 0.5)
        if canManageStore then primaryBtn:Enable() else primaryBtn:Disable() end

        officerAddEdit:SetText("")
        UpdateOfficerSuggestions("")
        officerAddEdit:EnableMouse(canManageStore)
        if not canManageStore then officerAddEdit:ClearFocus() end
        officerAddEdit:SetTextColor(canManageStore and 1 or 0.5, canManageStore and 1 or 0.5, canManageStore and 1 or 0.5)
        if canManageStore then officerAddBtn:Enable() else officerAddBtn:Disable() end

        RebuildCurrentOfficerRows()

        ratioEdit:SetText(db.creditGoldRatio and tostring(db.creditGoldRatio) or "")
        ratioEdit:EnableMouse(canManageStore)
        if not canManageStore then ratioEdit:ClearFocus() end
        ratioEdit:SetTextColor(canManageStore and 1 or 0.5, canManageStore and 1 or 0.5, canManageStore and 1 or 0.5)
        if canManageStore then ratioBtn:Enable() else ratioBtn:Disable() end

        goldCheck:SetChecked(db.discountAppliesToGold)
        creditCheck:SetChecked(db.discountAppliesToCredits)

        storeStatus:SetText((db.creditGoldRatio and "" or "Credits per Gold isn't set yet - the store's Credits column shows \"-\" until it is. ")
            .. (canManageStore and "" or "You can't manage Store officer settings (guild leader, donation recipient, or author account only) - read-only."))
    end

    return panel
end

--------------------------------------------------------------------------
-- About page
--------------------------------------------------------------------------

-- 2026-09-28 (Chris): each real module's own top-level slash command,
-- in the same order as the Tools page's module list (Air Service has no
-- Config page of its own, so it isn't in that list - appended last
-- here instead). Static, not derived from ns.moduleOrder/ns.modules -
-- this is documentation text for a person reading the About page, and
-- every module here already has a stable, long-lived slash command of
-- its own (see each module's own SLASH_* registration).
local ABOUT_MODULE_COMMANDS = {
    { cmd = "/dht", label = "DH-Tools (this window: /dht config)" },
    { cmd = "/mm", label = "Mob Marker" },
    { cmd = "/dhq", label = "Quests" },
    { cmd = "/dhb", label = "Bavin" },
    { cmd = "/dhdanger", label = "Danger" },
    { cmd = "/dhm", label = "Macros" },
    { cmd = "/dhs", label = "Store" },
    { cmd = "/dhair", label = "Air Service" },
}

local function CreateAboutPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    -- 2026-09-28: scrollable now, same pattern as every other populated
    -- page (Mob Marker/Bavin/Danger/Store above) - the new module
    -- slash-command list (see below) pushed this page close enough to a
    -- fixed window's height that it's cheap insurance against the same
    -- overflow-past-the-bottom bug Chris reported.
    local scrollFrame = CreateFrame("ScrollFrame", "DHToolsAboutScroll", panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -8, 8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 480) -- width set in Refresh; generous fixed estimate
    scrollFrame:SetScrollChild(content)

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("About DH-Tools")

    local body = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
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
    local credits = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    credits:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, 0) -- y set in Refresh, once body's actual height is known
    credits:SetPoint("RIGHT", -16, 0)
    credits:SetJustifyH("LEFT")
    credits:SetJustifyV("TOP")
    credits:SetWordWrap(true)
    credits:SetText("Major DH-Air Contributor: Deves\nBug Testers: Yuri, Cyndrith")

    local bodyBottom = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bodyBottom:SetPoint("TOPLEFT", credits, "BOTTOMLEFT", 0, -16)
    bodyBottom:SetPoint("RIGHT", -16, 0)
    bodyBottom:SetJustifyH("LEFT")
    bodyBottom:SetJustifyV("TOP")
    bodyBottom:SetWordWrap(true)

    -- 2026-09-28 (Chris): the Mob Marker/HC Mob Marker origin paragraph
    -- is gone - this is a good spot to list each module's own top-level
    -- slash command instead (ABOUT_MODULE_COMMANDS above), replacing the
    -- old single "/dht list" callout with the full set.
    local commandLines = {}
    for _, m in ipairs(ABOUT_MODULE_COMMANDS) do
        table.insert(commandLines, "|cffffff00" .. m.cmd .. "|r - " .. m.label)
    end
    bodyBottom:SetText(
        "The Death Happens guild's master addon - lets you activate or "
        .. "deactivate individual modules from one addon.\n\n"
        .. "Slash commands:\n"
        .. table.concat(commandLines, "\n")
        .. "\n\nCopyright (c) 2026 Loopi. All rights reserved.")

    panel.Refresh = function()
        -- -24 (not -4) to leave room for the scrollbar, same reasoning as
        -- every other scrollable page here.
        content:SetWidth(math.max(1, scrollFrame:GetWidth() - 24))

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
        SafeCreatePage("Store", CreateStorePanel)
        local isOfficer = DHTools.IsOfficerLocal and DHTools.IsOfficerLocal()
        if isOfficer then
            SafeCreatePage("OfficerSettings", CreateOfficerSettingsPanel)
        end
        SafeCreatePage("About", CreateAboutPanel)

        -- Danger/Macros/Store sit before About deliberately: About is
        -- the trailing "everything else" entry, and a new module
        -- belongs with the other modules above it. Store sits directly
        -- after Bavin specifically (2026-09-28, Chris) - the two are
        -- associated (Store hard-depends on Bavin for its Credits
        -- pricing/permission model), so they read better adjacent
        -- rather than with Danger/Macros between them. Officer Settings
        -- sits just above About (2026-09-28, Chris item 7) and its nav
        -- button only exists at all for accounts DHTools.IsOfficerLocal()
        -- approves - hidden entirely, not merely disabled, for everyone
        -- else, matching the rest of DH-Tools' permission model.
        local pageNames = { "Tools", "MobMarker", "Quests", "Bavin", "Store", "Danger", "Macros" }
        if isOfficer then
            table.insert(pageNames, "OfficerSettings")
        end
        table.insert(pageNames, "About")
        local pageLabels = { Tools = "Tools", MobMarker = "Mob Marker", Quests = "Quests", Bavin = "Bavin", Danger = "Danger", Macros = "Macros", Store = "Store", OfficerSettings = "Officer Settings", About = "About" }
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
