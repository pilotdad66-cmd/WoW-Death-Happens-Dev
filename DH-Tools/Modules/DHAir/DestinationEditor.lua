-- DH-Air DestinationEditor.lua
-- Officer-gated editor for the guild-wide destinations list (M4, see
-- DH-Air-Destinations-Design.md §5/§7 item 3 - Loopi chose a standalone
-- window over a Config.lua tab, 2026-08-03).
--
-- Same "rendering layer only" split Board.lua uses against Queue.lua: all
-- the actual mutation happens through Queue.lua's SetDestinationList/
-- ResetDestinationsToDefault (already built and tested in M2/M3), which
-- re-check HasPermission("edit_destinations") themselves - this file never
-- assumes permission locally, it just hides/shows controls based on it and
-- lets the real gate in Core.lua/Queue.lua have the final word. Everyone
-- can open this window and view the list read-only; only a guild officer
-- sees the Add/Remove/Reset controls.

local ADDON_NAME, DHAir = ...

local ROW_HEIGHT = 20
local CATEGORY_LABELS = { flightpoint = "Flight Point", summonstone = "Summoning Stone" }

-- 2026-08-05 (Loopi-reported): the Add row used to offer a flat
-- "Flight Point" / "Summoning Stone" choice - category alone, no continent.
-- Every add through this editor therefore left the new entry's `continent`
-- field nil, so it silently never showed up in Board.lua/Minimap.lua's
-- continent-grouped destination pickers (same field those rely on - see
-- Destinations.lua). Split into three explicit choices so a new flight
-- point is tagged with its continent at creation time, matching those
-- pickers' own "Flight Points - <continent>" split exactly. Each choice
-- carries the (category, continent) pair to apply on Add.
local ADD_CHOICES = {
    { key = "flightpoint_ek",       label = "Flight Point - Eastern Kingdoms", category = "flightpoint", continent = "Eastern Kingdoms" },
    { key = "flightpoint_kalimdor", label = "Flight Point - Kalimdor",         category = "flightpoint", continent = "Kalimdor" },
    { key = "summonstone",          label = "Summoning Stone",                 category = "summonstone", continent = nil },
}
local ADD_CHOICE_BY_KEY = {}
for _, c in ipairs(ADD_CHOICES) do
    ADD_CHOICE_BY_KEY[c.key] = c
end

local frame
local rowPool = {}
local selectedChoiceKey = ADD_CHOICES[1].key

-- Two-step removal state (module-level, not per-row, so arming one row's
-- confirmation clears any other row's stale "Confirm" state on the next
-- refresh - see RenderRow). Only one destination can be pending removal at
-- a time. pendingRemoveTimer auto-reverts to "X" after a few seconds if
-- never confirmed, so a stray click days later can't suddenly delete
-- something.
local pendingRemoveId = nil
local pendingRemoveTimer = nil

local function ClearPendingRemove()
    pendingRemoveId = nil
    if pendingRemoveTimer then
        pendingRemoveTimer:Cancel()
        pendingRemoveTimer = nil
    end
end

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

-- Builds a plain-field copy of db.destinations (never hands out the live
-- table itself) so callers can freely insert/remove before calling
-- SetDestinationList - the same "copy, don't alias" precedent Core.lua's
-- ADDON_LOADED seed and Queue.lua's ResetDestinationsToDefault both use.
-- 2026-08-05 (bug fix, found while wiring the continent-aware Add choices
-- above): this was dropping `continent` on every copy, so ANY edit through
-- this window (add, remove, or the enable/disable checkbox) silently wiped
-- continent off EVERY existing flightpoint entry, not just whichever one
-- was being edited - the whole list would fall out of Board.lua/Minimap.lua's
-- continent grouping until the next login's migration (Core.lua) happened
-- to patch it back up. This is almost certainly what caused the original
-- "None configured" report. Now carries `continent` through, same as
-- ResetDestinationsToDefault already does.
local function CopyDestinations()
    local list = {}
    for _, d in ipairs(DHAir.db.destinations) do
        table.insert(list, { id = d.id, label = d.label, category = d.category, continent = d.continent, enabled = d.enabled ~= false })
    end
    return list
end

-- Turns a label into an id-safe slug ("Iron Forge!" -> "ironforge"),
-- falling back to a generic base if the label has no alphanumerics at all,
-- then disambiguates against the given list by appending a numeric suffix.
-- Only used for brand-new entries added through this editor - existing ids
-- (from Destinations.lua or a prior officer edit) are never touched.
local function GenerateUniqueId(list, label)
    local base = label:lower():gsub("[^%w]+", "")
    if base == "" then base = "dest" end
    local function idExists(candidate)
        for _, d in ipairs(list) do
            if d.id == candidate then return true end
        end
        return false
    end
    local id, suffix = base, 1
    while idExists(id) do
        suffix = suffix + 1
        id = base .. suffix
    end
    return id
end

--------------------------------------------------------------------------
-- Row pool (list of current destinations)
--------------------------------------------------------------------------

local function CreateRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, 0.03)

    -- Removal is 2-step: first click arms a "Confirm" state (see RenderRow
    -- and the module-level pendingRemoveId/pendingRemoveTimer above),
    -- second click actually deletes. Sized to fit "Confirm" as well as "X".
    row.removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.removeBtn:SetSize(58, 18)
    row.removeBtn:SetText("X")
    row.removeBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)

    -- Enable/disable checkbox - unrelated to removal. A disabled
    -- destination stays in the list (and keeps showing for anyone who
    -- already picked it - see Queue.lua's ApplyDestination/GetDestination)
    -- but is hidden from new-selection UI (Board's dropdown, /dhair dest).
    row.enableCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.enableCheck:SetSize(20, 20)
    row.enableCheck:SetPoint("RIGHT", row.removeBtn, "LEFT", -6, 0)

    row.categoryText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.categoryText:SetPoint("RIGHT", row.enableCheck, "LEFT", -10, 0)
    row.categoryText:SetWidth(100)
    row.categoryText:SetJustifyH("RIGHT")
    row.categoryText:SetWordWrap(false)

    row.labelText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.labelText:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.labelText:SetPoint("RIGHT", row.categoryText, "LEFT", -8, 0)
    row.labelText:SetJustifyH("LEFT")
    -- Truncate long labels (engine auto-ellipsis) instead of wrapping to a
    -- second line - rows are fixed-height (ROW_HEIGHT), so a wrapped label
    -- used to spill down into the row below it and overlap the next
    -- destination. The frame is now resizable (see CreateEditorFrame) so a
    -- truncated label can still be seen in full by widening the window.
    row.labelText:SetWordWrap(false)

    return row
end

local function AcquireRow(parent, index)
    if not rowPool[index] then
        rowPool[index] = CreateRow(parent, index)
    end
    return rowPool[index]
end

local function HideRowsFrom(startIndex)
    for i = startIndex, #rowPool do
        rowPool[i]:Hide()
    end
end

local function RenderRow(row, dest, index, canEdit)
    row.bg:SetColorTexture(1, 1, 1, (index % 2 == 0) and 0.03 or 0.0)

    local enabled = dest.enabled ~= false
    row.labelText:SetText(dest.label)
    -- Dim (but don't hide) a disabled destination's text for EVERYONE,
    -- including read-only viewers - it's still informational even if only
    -- an officer can act on it.
    if enabled then
        row.labelText:SetTextColor(1, 1, 1)
    else
        row.labelText:SetTextColor(0.5, 0.5, 0.5)
    end
    row.categoryText:SetText(CATEGORY_LABELS[dest.category] or dest.category or "")

    -- Enable/disable toggle - officer-only, same SetShown(canEdit) idiom
    -- the remove button already used before this addition.
    row.enableCheck:SetShown(canEdit)
    row.enableCheck:SetChecked(enabled)
    row.enableCheck:SetScript("OnClick", function(self)
        local want = self:GetChecked() and true or false
        if not DHAir:SetDestinationEnabled(dest.id, want) then
            DHAir:Print("Only a guild officer can edit the destinations list.")
            self:SetChecked(not want) -- revert the click, nothing actually changed
            return
        end
        DHAir:DestinationEditor_Refresh()
    end)

    -- Removal: first click arms a "Confirm" state on THIS destination
    -- (clearing any other row's pending confirm), second click while still
    -- armed actually deletes. pendingRemoveTimer auto-reverts after a few
    -- seconds so an old, forgotten "Confirm" can't be clicked by accident
    -- much later.
    row.removeBtn:SetShown(canEdit)
    local isPending = (pendingRemoveId == dest.id)
    row.removeBtn:SetText(isPending and "Confirm" or "X")
    row.removeBtn:SetScript("OnClick", function()
        if pendingRemoveId == dest.id then
            ClearPendingRemove()
            local list = CopyDestinations()
            for i = #list, 1, -1 do
                if list[i].id == dest.id then table.remove(list, i) end
            end
            if DHAir:SetDestinationList(list) then
                DHAir:DestinationEditor_Refresh()
            else
                DHAir:Print("Only a guild officer can edit the destinations list.")
            end
        else
            pendingRemoveId = dest.id
            if pendingRemoveTimer then pendingRemoveTimer:Cancel() end
            pendingRemoveTimer = C_Timer.NewTimer(4, function()
                pendingRemoveId = nil
                pendingRemoveTimer = nil
                DHAir:DestinationEditor_Refresh()
            end)
            DHAir:DestinationEditor_Refresh()
        end
    end)

    row:Show()
end

--------------------------------------------------------------------------
-- Frame construction (built once, first time the editor is opened)
--------------------------------------------------------------------------

local function CreateEditorFrame()
    frame = CreateFrame("Frame", "DHAirDestinationEditorFrame", UIParent, "BasicFrameTemplateWithInset")
    -- 2026-08-04: widened 360 -> 400 to give the Add row (label + category
    -- dropdown + Add button, now all on one row - see addBtn below) enough
    -- room without cramming at the default size.
    -- 2026-08-05: widened again, 400 -> 460, for the category dropdown's
    -- longer continent-specific choices (see ADD_CHOICES) - addBtn is
    -- anchored off the frame's own right edge, so the extra frame width
    -- lands entirely as breathing room between the wider dropdown and the
    -- button rather than requiring either to move.
    frame:SetSize(460, 440)
    frame:SetPoint("CENTER")
    if frame.TitleText then
        frame.TitleText:SetText("DH-Air - Destinations")
    end
    tinsert(UISpecialFrames, "DHAirDestinationEditorFrame")

    -- Toplevel raising, opaque background, and title-bar-only dragging -
    -- see Core.lua's InitStandaloneWindow for why (same fix Board.lua and
    -- Config.lua already rely on).
    DHAir:InitStandaloneWindow(frame)

    -- Resizable: lets a long destination label be given more horizontal
    -- room instead of relying only on truncation (see CreateRow), and lets
    -- the window shrink when the list is short.
    frame:SetResizable(true)
    if frame.SetMinResize then frame:SetMinResize(320, 280) end
    if frame.SetMaxResize then frame:SetMaxResize(700, 800) end

    frame.resizeBtn = CreateFrame("Button", nil, frame)
    frame.resizeBtn:SetSize(16, 16)
    frame.resizeBtn:SetPoint("BOTTOMRIGHT", -4, 4)
    frame.resizeBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    frame.resizeBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    frame.resizeBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    frame.resizeBtn:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    frame.resizeBtn:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

    -- Re-flow row width (label truncation point) and scroll content size
    -- live as the frame is resized.
    frame:SetScript("OnSizeChanged", function()
        if frame:IsShown() then
            DHAir:DestinationEditor_Refresh()
        end
    end)

    -- A row armed for removal ("Confirm") shouldn't stay armed across a
    -- close/reopen - HookScript rather than SetScript so this doesn't
    -- clobber any OnHide behavior the template itself relies on.
    frame:HookScript("OnHide", ClearPendingRemove)

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.hint:SetPoint("TOPLEFT", 12, -32)
    frame.hint:SetPoint("RIGHT", -12, 0)
    frame.hint:SetJustifyH("LEFT")
    frame.hint:SetWordWrap(true)

    -- Scrollable list of current destinations.
    frame.scrollFrame = CreateFrame("ScrollFrame", "DHAirDestEditorScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPLEFT", frame.hint, "BOTTOMLEFT", 0, -8)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", -30, 118)

    frame.scrollContent = CreateFrame("Frame", nil, frame.scrollFrame)
    frame.scrollContent:SetSize(1, 1)
    frame.scrollFrame:SetScrollChild(frame.scrollContent)

    -- Officer-only footer: add-new row + reset button. Hidden entirely
    -- (not just disabled) for non-officers, same SetShown(HasPermission(...))
    -- idiom Board.lua's clearAllBtn already uses.
    frame.addLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.addLabel:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 84)
    frame.addLabel:SetText("Add a destination:")

    frame.labelEdit = CreateFrame("EditBox", "DHAirDestEditorLabelEdit", frame, "InputBoxTemplate")
    frame.labelEdit:SetSize(140, 20)
    frame.labelEdit:SetPoint("TOPLEFT", frame.addLabel, "BOTTOMLEFT", 6, -6)
    frame.labelEdit:SetAutoFocus(false)
    frame.labelEdit:SetMaxLetters(64)
    frame.labelEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    frame.labelEdit:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

    frame.categoryDropdown = CreateFrame("Frame", "DHAirDestEditorCategoryDropdown", frame, "UIDropDownMenuTemplate")
    frame.categoryDropdown:SetPoint("LEFT", frame.labelEdit, "RIGHT", 4, -2)
    -- 2026-08-05: widened 80 -> 150 for the longer continent-specific
    -- labels (see ADD_CHOICES/frame width comment above).
    UIDropDownMenu_SetWidth(frame.categoryDropdown, 150)

    local function CategoryOnClick(self)
        selectedChoiceKey = self.value
        UIDropDownMenu_SetSelectedValue(frame.categoryDropdown, self.value)
        UIDropDownMenu_SetText(frame.categoryDropdown, ADD_CHOICE_BY_KEY[self.value].label)
    end

    UIDropDownMenu_Initialize(frame.categoryDropdown, function(selfFrame, level)
        for _, choice in ipairs(ADD_CHOICES) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = choice.label
            info.value = choice.key
            info.func = CategoryOnClick
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetSelectedValue(frame.categoryDropdown, selectedChoiceKey)
    UIDropDownMenu_SetText(frame.categoryDropdown, ADD_CHOICE_BY_KEY[selectedChoiceKey].label)

    -- 2026-08-04 (Loopi-reported): this used to sit directly below
    -- labelEdit, which put it right on top of resetBtn (both anchored
    -- near the frame's bottom-left, ~12-24px up) - overlapping buttons.
    -- Moved to sit on the SAME row as labelEdit/categoryDropdown instead
    -- (to their right, anchored off the frame's own bottom-right corner
    -- so it can never drift into resetBtn's row below), per Loopi's ask.
    frame.addBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.addBtn:SetSize(70, 22)
    frame.addBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 57)
    frame.addBtn:SetText("Add")
    frame.addBtn:SetScript("OnClick", function()
        local label = (frame.labelEdit:GetText() or ""):match("^%s*(.-)%s*$")
        if label == "" then
            DHAir:Print("Enter a destination name before adding.")
            return
        end
        local choice = ADD_CHOICE_BY_KEY[selectedChoiceKey]
        local list = CopyDestinations()
        local newId = GenerateUniqueId(list, label)
        table.insert(list, { id = newId, label = label, category = choice.category, continent = choice.continent, enabled = true })
        if DHAir:SetDestinationList(list) then
            frame.labelEdit:SetText("")
            DHAir:DestinationEditor_Refresh()
        else
            DHAir:Print("Only a guild officer can edit the destinations list.")
        end
    end)

    frame.resetBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.resetBtn:SetSize(160, 22)
    frame.resetBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 12)
    frame.resetBtn:SetText("Reset to built-in list")
    frame.resetBtn:SetScript("OnClick", function()
        if DHAir:ResetDestinationsToDefault() then
            DHAir:Print("Destinations list reset to the built-in defaults.")
            DHAir:DestinationEditor_Refresh()
        else
            DHAir:Print("Only a guild officer can reset the destinations list.")
        end
    end)
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

function DHAir:DestinationEditor_Refresh()
    if not frame or not frame:IsShown() then return end

    local canEdit = self:HasPermission("edit_destinations")
    frame.hint:SetText(canEdit
        and "Add, remove, or reset the guild-wide destinations list below. Everyone sees your changes."
        or "Viewing the guild-wide destinations list (read-only - only a guild officer can edit it).")

    frame.addLabel:SetShown(canEdit)
    frame.labelEdit:SetShown(canEdit)
    frame.categoryDropdown:SetShown(canEdit)
    frame.addBtn:SetShown(canEdit)
    frame.resetBtn:SetShown(canEdit)

    -- Grow the scroll area to fill the space the footer would have used
    -- when it's hidden, so read-only viewers aren't left staring at a
    -- short list with a big empty gap below it.
    frame.scrollFrame:ClearAllPoints()
    frame.scrollFrame:SetPoint("TOPLEFT", frame.hint, "BOTTOMLEFT", 0, -8)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", -30, canEdit and 118 or 12)

    local content = frame.scrollContent
    content:SetWidth(math.max(1, frame.scrollFrame:GetWidth() - 24))

    for i, dest in ipairs(self.db.destinations) do
        local row = AcquireRow(content, i)
        RenderRow(row, dest, i, canEdit)
    end
    HideRowsFrom(#self.db.destinations + 1)
    content:SetHeight(math.max(1, #self.db.destinations * ROW_HEIGHT))
end

function DHAir:DestinationEditor_Open()
    if not frame then
        CreateEditorFrame()
    end
    frame:Show()
    self:DestinationEditor_Refresh()
end

function DHAir:DestinationEditor_Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        self:DestinationEditor_Open()
    end
end
