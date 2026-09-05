-- DH-Bavin PointsEditor.lua
-- In-game editor for Bavin Points (see ItemPoints.lua's header for the
-- static ~7000-entry baseline, and Core.lua's "Item points" section for
-- the override/version plumbing this file drives). Opened via
-- /dhb points (Core.lua's slash dispatch calls ns.PointsEditor_Toggle).
--
-- GATING: unlike DestinationEditor.lua (DH-Air's own editor, the pattern
-- this file's window chrome is ported from), this window is NOT
-- viewable read-only by everyone - Loopi's original ask was "a totally
-- separate window, only available to Bavin and Loopidot for now", which
-- the finalized design answered by reusing CanEditList (recipient/
-- editors) rather than a separate Bavin+Loopidot-only gate. So
-- PointsEditor_Open refuses outright (never creates/shows the frame) if
-- CanEditList fails, instead of DestinationEditor's "show everyone, hide
-- only the edit controls" approach. Closing is always allowed regardless
-- of permission.
--
-- SEARCH, NOT A FULL LIST: ~7000 entries is far too many to list (see
-- Config.lua's BuildSuggestPool/PopulateSuggestions comment for the exact
-- same lesson learned the hard way on a ~1000-member roster picker) - so
-- this mirrors that type-to-filter pattern instead of DestinationEditor's
-- "render every row" approach. Matching is a plain case-insensitive
-- substring scan, capped to MAX_RESULTS materialized rows, over the
-- union of ns.ITEM_POINTS' keys (the shipped baseline) and
-- ns.db.itemPointsOverrides' keys (live edits, including brand-new
-- names added through the footer form below - see the 2026-08-06 note
-- above).
--
-- 2026-08-06: itemId is now editable (Loopi reported the import got some
-- itemIDs wrong and asked for a manual fix path), and a new "Add a new
-- item" footer form lets a name/itemID/points triple be added outright
-- via the same ns.SetItemPoints - it doesn't require the name to already
-- exist in ns.ITEM_POINTS' shipped baseline. BuildMatches was widened to
-- also scan ns.db.itemPointsOverrides so a brand-new (non-baseline) name
-- is actually findable afterward, not just save-able into the void.
-- Reverting a brand-new (non-baseline) name works as a delete for free -
-- GetItemPoints has nothing to fall back to, so the row just disappears
-- from search results once tombstoned, same as any other override.

local DHTools = DHTools
local ns = DHTools.Bavin

-- 2026-08-06 (Loopi): each result is now TWO lines, not one - line 1 is
-- the original name/itemID/points/Save/Revert row, line 2 is a
-- full-width box for the tooltip wording (ItemPoints.lua's `detail`).
--
-- Loopi asked for "another column", and this is deliberately a second
-- LINE instead: detail strings are full sentences ("<name>: <points> pts
-- to Bavin; crafted by an @Alchemist"), 60-100+ characters, and the
-- window is 440px wide by default with four cells already competing for
-- it. A real column would have left ~80px of visible text - unreadable
-- and unusable for editing. Spanning the width below the name keeps the
-- whole sentence in view. Easy to revisit if it feels wrong in-game.
local TOP_LINE_HEIGHT = 20
local DETAIL_LINE_HEIGHT = 20
local ROW_HEIGHT = TOP_LINE_HEIGHT + DETAIL_LINE_HEIGHT + 2
local DETAIL_INDENT = 8
local MAX_RESULTS = 25

-- Column geometry shared between each row's cells (CreateRow) and the
-- header labels (CreateEditorFrame) so the two can never silently drift
-- apart again - 2026-08-05 bug report: the old header was a single
-- hand-spaced "itemID   points" string anchored to the frame's own right
-- edge, which ignored the revert/save buttons, the scrollbar's -30
-- inset, and scrollContent's -24 width reduction, so it never actually
-- lined up with the columns below it. Every offset here is reused
-- verbatim by both the rows and the headers.
local REVERT_WIDTH = 52
local REVERT_RIGHT_PAD = 2
local SAVE_WIDTH = 40
local SAVE_GAP = 8
local POINTS_WIDTH = 44
local POINTS_GAP = 8
local ITEMID_WIDTH = 50
local ITEMID_GAP = 10
local CONTENT_RIGHT_PAD = 24 -- must match scrollContent:SetWidth() below

local frame
local rowPool = {}
local searchText = ""

--------------------------------------------------------------------------
-- Matching
--------------------------------------------------------------------------

-- Case-insensitive plain-substring scan over both the shipped baseline
-- and live overrides (see file header for why both are scanned).
-- Returns every match, sorted alphabetically - callers cap how many they
-- actually render. Full ~7000-key scan per keystroke is cheap in Lua
-- (this is a table scan + string.find, not frame creation - the
-- expensive part this file avoids is materializing UI rows, per the
-- header comment), so no early-break is needed here for performance.
local function BuildMatches(typed)
    local matches = {}
    if typed == "" then return matches end
    local needle = typed:lower()
    local seen = {}
    if ns.ITEM_POINTS then
        for name in pairs(ns.ITEM_POINTS) do
            if name:lower():find(needle, 1, true) then
                seen[name] = true
                table.insert(matches, name)
            end
        end
    end
    -- Brand-new names (added via the footer form) exist ONLY in the
    -- overrides table, never in the baseline - without this second scan
    -- they'd save fine but never be findable again. Tombstoned entries
    -- (points == nil, i.e. reverted/"deleted") are skipped, same as
    -- GetItemPoints itself would treat them as unknown for a non-
    -- baseline name.
    local overrides = ns.db and ns.db.itemPointsOverrides
    if overrides then
        for name, o in pairs(overrides) do
            if not seen[name] and o.points ~= nil and name:lower():find(needle, 1, true) then
                table.insert(matches, name)
            end
        end
    end
    table.sort(matches)
    return matches
end

--------------------------------------------------------------------------
-- Row pool (search results)
--------------------------------------------------------------------------

local function CreateRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, 0.03)

    -- Every line-1 cell below is parented to (and anchored inside) this
    -- fixed-height strip rather than to `row` directly. Before the
    -- 2026-08-06 two-line change they anchored to row's own RIGHT edge,
    -- which vertically centered them - fine when the row WAS one line,
    -- but it would have floated them into the middle of a 42px row now.
    -- Keeping them inside a 20px strip pinned to the row's top preserves
    -- their exact horizontal geometry (same anchors, same constants) and
    -- so keeps them lined up with the column headers, which are anchored
    -- to scrollFrame independently and know nothing about row height.
    row.topLine = CreateFrame("Frame", nil, row)
    row.topLine:SetHeight(TOP_LINE_HEIGHT)
    row.topLine:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.topLine:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)

    -- Only shown for rows currently carrying a live override (see
    -- RenderRow) - reverting is an explicit action, never implied by
    -- clearing the points field (that's a no-op, not a revert; see the
    -- OnEnterPressed handler below).
    row.revertBtn = CreateFrame("Button", nil, row.topLine, "UIPanelButtonTemplate")
    row.revertBtn:SetSize(REVERT_WIDTH, 18)
    row.revertBtn:SetText("Revert")
    row.revertBtn:SetPoint("RIGHT", row.topLine, "RIGHT", -REVERT_RIGHT_PAD, 0)

    -- Explicit Save action, separate from the implicit "press Enter in
    -- the points box" commit - 2026-08-05 bug report: nothing in the UI
    -- signaled Enter was required to commit, and clicking away from the
    -- box silently discarded the typed value with no feedback, which
    -- read as "there's no way to save." Both paths run CommitPoints
    -- (see RenderRow below).
    row.saveBtn = CreateFrame("Button", nil, row.topLine, "UIPanelButtonTemplate")
    row.saveBtn:SetSize(SAVE_WIDTH, 18)
    row.saveBtn:SetText("Save")
    row.saveBtn:SetPoint("RIGHT", row.revertBtn, "LEFT", -SAVE_GAP, 0)

    -- Text mode, not SetNumeric(true) - WoW's numeric EditBox mode
    -- disallows the leading "-" a negative point value needs (0 and
    -- negative points are valid - Loopi confirmed this during intake).
    -- Validated with tonumber() on submit instead.
    row.pointsEdit = CreateFrame("EditBox", nil, row.topLine, "InputBoxTemplate")
    row.pointsEdit:SetSize(POINTS_WIDTH, 18)
    row.pointsEdit:SetPoint("RIGHT", row.saveBtn, "LEFT", -POINTS_GAP, 0)
    row.pointsEdit:SetAutoFocus(false)
    row.pointsEdit:SetMaxLetters(8)
    row.pointsEdit:SetJustifyH("RIGHT")

    -- 2026-08-06: editable, not a read-only FontString - Loopi reported
    -- the import got some itemIDs wrong and asked for a manual fix path.
    -- Numeric mode is fine here (unlike pointsEdit, itemIDs are never
    -- negative), and empty is a valid input meaning "no itemID on file".
    row.itemIdEdit = CreateFrame("EditBox", nil, row.topLine, "InputBoxTemplate")
    row.itemIdEdit:SetSize(ITEMID_WIDTH, 18)
    row.itemIdEdit:SetPoint("RIGHT", row.pointsEdit, "LEFT", -ITEMID_GAP, 0)
    row.itemIdEdit:SetAutoFocus(false)
    row.itemIdEdit:SetNumeric(true)
    row.itemIdEdit:SetMaxLetters(7)
    row.itemIdEdit:SetJustifyH("RIGHT")

    row.nameText = row.topLine:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.nameText:SetPoint("LEFT", row.topLine, "LEFT", 4, 0)
    row.nameText:SetPoint("RIGHT", row.itemIdEdit, "LEFT", -10, 0)
    row.nameText:SetJustifyH("LEFT")
    -- Truncate rather than wrap - rows are fixed-height, same reasoning
    -- as DestinationEditor's labelText (the window is resizable, so a
    -- truncated name can still be read in full by widening it).
    row.nameText:SetWordWrap(false)

    -- Line 2: the tooltip wording (ItemPoints.lua's `detail` - the text
    -- Tooltip.lua actually prints on the item). Spans the full row width
    -- under the name; see the ROW_HEIGHT block at the top of this file
    -- for why this is a line rather than the column Loopi asked for.
    -- Indented slightly so the two lines read as one grouped record
    -- rather than two unrelated rows.
    row.detailEdit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    row.detailEdit:SetHeight(18)
    row.detailEdit:SetPoint("TOPLEFT", row, "TOPLEFT", DETAIL_INDENT + 4, -(TOP_LINE_HEIGHT + 2))
    row.detailEdit:SetPoint("TOPRIGHT", row, "TOPRIGHT", -REVERT_RIGHT_PAD, -(TOP_LINE_HEIGHT + 2))
    row.detailEdit:SetAutoFocus(false)
    -- Generous but bounded: the longest spreadsheet detail strings run
    -- ~100 chars, and the wire escaping (Sync.lua's EscapeDetail) can
    -- roughly double a string full of delimiters, so this keeps a single
    -- PTSSET comfortably inside the addon-message size limit.
    row.detailEdit:SetMaxLetters(180)
    row.detailEdit:SetJustifyH("LEFT")

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

local function RenderRow(row, name, index)
    row.bg:SetColorTexture(1, 1, 1, (index % 2 == 0) and 0.03 or 0.0)

    local info = ns.GetItemPoints(name)

    row.nameText:SetText(name)
    if info and info.isOverride then
        row.nameText:SetTextColor(1, 0.82, 0) -- flags a live edit at a glance
    else
        row.nameText:SetTextColor(1, 1, 1)
    end

    row.itemIdEdit:SetText((info and info.itemId) and tostring(info.itemId) or "")
    row.itemIdEdit:SetCursorPosition(0)

    row.pointsEdit:SetText((info and info.points ~= nil) and tostring(info.points) or "")
    row.pointsEdit:SetCursorPosition(0)

    -- Prefilled with the EFFECTIVE wording - an override's own text if it
    -- has one, otherwise the shipped baseline's - so editing starts from
    -- what's actually on the tooltip rather than an empty box. Note the
    -- consequence: saving a points change while this box still holds the
    -- baseline sentence carries that sentence (with its now-stale
    -- embedded point number) onto the override. That's visible and
    -- correctable right there in the box, which beats the alternative of
    -- hiding the current wording until the editor retypes it blind.
    row.detailEdit:SetText((info and info.detail) or "")
    row.detailEdit:SetCursorPosition(0)

    -- Shared by both EditBoxes' Enter key and the explicit Save button
    -- (see CreateRow's 2026-08-05 comment) so there's exactly one commit
    -- path to keep in sync, and a success message either way - there
    -- was previously no positive feedback at all on a successful save,
    -- only on refusal/invalid input, which fed the "did that even save?"
    -- confusion. 2026-08-06: itemID now comes from its own edit box
    -- (previously always carried forward unchanged) so a bad import can
    -- actually be corrected here.
    local function CommitPoints()
        local text = (row.pointsEdit:GetText() or ""):match("^%s*(.-)%s*$")
        local itemIdText = (row.itemIdEdit:GetText() or ""):match("^%s*(.-)%s*$")
        local detailText = (row.detailEdit:GetText() or ""):match("^%s*(.-)%s*$")
        row.pointsEdit:ClearFocus()
        row.itemIdEdit:ClearFocus()
        row.detailEdit:ClearFocus()
        if text == "" then
            return -- explicit no-op - use Revert to actually clear an override
        end
        local points = tonumber(text)
        if not points then
            ns.Print("'" .. text .. "' isn't a number - points edit not saved.")
            ns.PointsEditor_Refresh() -- restores the field to its last real value
            return
        end
        local itemId = itemIdText ~= "" and tonumber(itemIdText) or nil
        if ns.SetItemPoints(name, points, itemId, detailText) then
            ns.Print(name .. " set to " .. points .. " points"
                .. (itemId and (", itemID " .. itemId) or "") .. ".")
            ns.PointsEditor_Refresh()
        else
            ns.Print("Refused - you must be the recipient or an editor.")
            ns.PointsEditor_Refresh()
        end
    end

    row.pointsEdit:SetScript("OnEnterPressed", CommitPoints)
    row.pointsEdit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        ns.PointsEditor_Refresh()
    end)

    row.itemIdEdit:SetScript("OnEnterPressed", CommitPoints)
    row.itemIdEdit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        ns.PointsEditor_Refresh()
    end)

    row.detailEdit:SetScript("OnEnterPressed", CommitPoints)
    row.detailEdit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        ns.PointsEditor_Refresh()
    end)

    row.saveBtn:SetScript("OnClick", CommitPoints)

    row.revertBtn:SetShown(info ~= nil and info.isOverride)
    row.revertBtn:SetScript("OnClick", function()
        ns.RevertItemPoints(name)
        ns.PointsEditor_Refresh()
    end)

    row:Show()
end

--------------------------------------------------------------------------
-- Frame construction (built once, first time the editor is opened)
--------------------------------------------------------------------------

local function CreateEditorFrame()
    frame = CreateFrame("Frame", "DHBavinPointsEditorFrame", UIParent, "BasicFrameTemplateWithInset")
    -- 2026-08-06: +50 default height for the add-new-item footer form.
    -- 2026-08-06 (later): 440 -> 520 wide and 510 -> 560 tall - rows are
    -- two lines now (see ROW_HEIGHT), so the same list needs more
    -- vertical room, and the tooltip-wording box wants the extra width.
    frame:SetSize(520, 560)
    frame:SetPoint("CENTER")
    if frame.TitleText then
        frame.TitleText:SetText("Bavin - Points Editor")
    end
    tinsert(UISpecialFrames, "DHBavinPointsEditorFrame")

    -- Toplevel raising, opaque background, title-bar-only dragging - see
    -- DH-Tools Core.lua's InitStandaloneWindow. Dot-call, not colon: it's
    -- a plain shared function hung off the DHTools table, not a method
    -- on a "self" object the way DH-Air's own InitStandaloneWindow is.
    DHTools.InitStandaloneWindow(frame)

    frame:SetResizable(true)
    -- 2026-08-06: min height bumped 320->370 to keep room for the new
    -- add-new-item footer form without it colliding with the results list.
    -- 2026-08-06 (later): 370->400 for the footer's second (wording) row.
    if frame.SetMinResize then frame:SetMinResize(360, 400) end
    if frame.SetMaxResize then frame:SetMaxResize(700, 800) end

    frame.resizeBtn = CreateFrame("Button", nil, frame)
    frame.resizeBtn:SetSize(16, 16)
    frame.resizeBtn:SetPoint("BOTTOMRIGHT", -4, 4)
    frame.resizeBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    frame.resizeBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    frame.resizeBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    frame.resizeBtn:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    frame.resizeBtn:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

    frame:SetScript("OnSizeChanged", function()
        if frame:IsShown() then
            ns.PointsEditor_Refresh()
        end
    end)

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.hint:SetPoint("TOPLEFT", 12, -32)
    frame.hint:SetPoint("RIGHT", -12, 0)
    frame.hint:SetJustifyH("LEFT")
    frame.hint:SetWordWrap(true)
    frame.hint:SetText("Search an item name below to view or edit its Bavin Points, itemID, and the tooltip wording shown on the item (second line of each result). Press Enter or click Save to commit a change - saved changes push live to everyone online, and sync to anyone who logs in later. Use the form at the bottom to add a brand-new item. Note: edits are overwritten whenever a new addon version ships a regenerated list from the spreadsheet.")

    frame.searchEdit = CreateFrame("EditBox", "DHBavinPointsEditorSearch", frame, "InputBoxTemplate")
    frame.searchEdit:SetSize(200, 20)
    frame.searchEdit:SetPoint("TOPLEFT", frame.hint, "BOTTOMLEFT", 6, -10)
    frame.searchEdit:SetAutoFocus(false)
    frame.searchEdit:SetMaxLetters(64)
    frame.searchEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    frame.searchEdit:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    frame.searchEdit:SetScript("OnTextChanged", function(self)
        searchText = (self:GetText() or ""):match("^%s*(.-)%s*$")
        ns.PointsEditor_Refresh()
    end)

    frame.resultsHint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.resultsHint:SetPoint("TOPLEFT", frame.searchEdit, "BOTTOMLEFT", -6, -10)
    frame.resultsHint:SetPoint("RIGHT", -12, 0)
    frame.resultsHint:SetJustifyH("LEFT")

    -- Add-new-item footer form (2026-08-06) - a name/itemID/points triple
    -- that doesn't need to already exist in ns.ITEM_POINTS' baseline; see
    -- file header. Built BEFORE scrollFrame so scrollFrame's bottom edge
    -- can anchor off it and never overlap.
    -- 2026-08-06 (later): 40 -> 66 for the tooltip-wording line, which
    -- gets its own full-width row beneath the name/itemID/points row for
    -- the same reason the result rows do (see the ROW_HEIGHT block).
    frame.addSection = CreateFrame("Frame", nil, frame)
    frame.addSection:SetHeight(66)
    frame.addSection:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 10)
    frame.addSection:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 10)

    frame.addLabel = frame.addSection:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.addLabel:SetPoint("TOPLEFT", frame.addSection, "TOPLEFT", 0, 0)
    frame.addLabel:SetText("Add a new item (name, itemID, points; tooltip wording below):")

    -- Bottom row of the section: the wording box, full width.
    frame.addDetailEdit = CreateFrame("EditBox", nil, frame.addSection, "InputBoxTemplate")
    frame.addDetailEdit:SetHeight(20)
    frame.addDetailEdit:SetPoint("BOTTOMLEFT", frame.addSection, "BOTTOMLEFT", 4, 0)
    frame.addDetailEdit:SetPoint("BOTTOMRIGHT", frame.addSection, "BOTTOMRIGHT", 0, 0)
    frame.addDetailEdit:SetAutoFocus(false)
    frame.addDetailEdit:SetMaxLetters(180) -- see CreateRow's detailEdit
    frame.addDetailEdit:SetJustifyH("LEFT")

    -- The name/itemID/points/Add widgets chain to each other with plain
    -- RIGHT/LEFT anchors, which only line up if they all share one
    -- horizontal band - so they get their own 20px container rather than
    -- being anchored individually into a now-two-row section (mixing a
    -- LEFT anchor on the section with a RIGHT anchor on a sibling would
    -- give a frame two disagreeing vertical centers). Same container
    -- trick as CreateRow's row.topLine, and it keeps every anchor below
    -- character-for-character what it was before this change.
    frame.addTopRow = CreateFrame("Frame", nil, frame.addSection)
    frame.addTopRow:SetHeight(20)
    frame.addTopRow:SetPoint("BOTTOMLEFT", frame.addDetailEdit, "TOPLEFT", -4, 4)
    frame.addTopRow:SetPoint("BOTTOMRIGHT", frame.addDetailEdit, "TOPRIGHT", 0, 4)

    frame.addBtn = CreateFrame("Button", nil, frame.addTopRow, "UIPanelButtonTemplate")
    frame.addBtn:SetSize(70, 20)
    frame.addBtn:SetText("Add Item")
    frame.addBtn:SetPoint("BOTTOMRIGHT", frame.addTopRow, "BOTTOMRIGHT", 0, 0)

    frame.addPointsEdit = CreateFrame("EditBox", nil, frame.addTopRow, "InputBoxTemplate")
    frame.addPointsEdit:SetSize(POINTS_WIDTH, 20)
    frame.addPointsEdit:SetPoint("RIGHT", frame.addBtn, "LEFT", -SAVE_GAP, 0)
    frame.addPointsEdit:SetAutoFocus(false)
    frame.addPointsEdit:SetMaxLetters(8)
    frame.addPointsEdit:SetJustifyH("RIGHT")

    frame.addItemIdEdit = CreateFrame("EditBox", nil, frame.addTopRow, "InputBoxTemplate")
    frame.addItemIdEdit:SetSize(ITEMID_WIDTH, 20)
    frame.addItemIdEdit:SetPoint("RIGHT", frame.addPointsEdit, "LEFT", -POINTS_GAP, 0)
    frame.addItemIdEdit:SetAutoFocus(false)
    frame.addItemIdEdit:SetNumeric(true)
    frame.addItemIdEdit:SetMaxLetters(7)
    frame.addItemIdEdit:SetJustifyH("RIGHT")

    frame.addNameEdit = CreateFrame("EditBox", nil, frame.addTopRow, "InputBoxTemplate")
    frame.addNameEdit:SetPoint("LEFT", frame.addTopRow, "LEFT", 4, 0)
    frame.addNameEdit:SetPoint("RIGHT", frame.addItemIdEdit, "LEFT", -ITEMID_GAP, 0)
    frame.addNameEdit:SetHeight(20)
    frame.addNameEdit:SetAutoFocus(false)
    frame.addNameEdit:SetMaxLetters(120)

    -- Shared by the Add button and Enter in any of the three fields, same
    -- single-commit-path idiom CommitPoints (per-row) uses.
    local function CommitAddItem()
        local name = (frame.addNameEdit:GetText() or ""):match("^%s*(.-)%s*$")
        local pointsText = (frame.addPointsEdit:GetText() or ""):match("^%s*(.-)%s*$")
        local itemIdText = (frame.addItemIdEdit:GetText() or ""):match("^%s*(.-)%s*$")
        local detailText = (frame.addDetailEdit:GetText() or ""):match("^%s*(.-)%s*$")
        frame.addNameEdit:ClearFocus()
        frame.addPointsEdit:ClearFocus()
        frame.addItemIdEdit:ClearFocus()
        frame.addDetailEdit:ClearFocus()
        if name == "" then
            ns.Print("Enter an item name before adding.")
            return
        end
        local points = tonumber(pointsText)
        if not points then
            ns.Print("'" .. pointsText .. "' isn't a number - enter a points value.")
            return
        end
        local itemId = itemIdText ~= "" and tonumber(itemIdText) or nil
        if ns.SetItemPoints(name, points, itemId, detailText) then
            ns.Print(name .. " added at " .. points .. " points"
                .. (itemId and (", itemID " .. itemId) or "") .. ".")
            frame.addNameEdit:SetText("")
            frame.addPointsEdit:SetText("")
            frame.addItemIdEdit:SetText("")
            frame.addDetailEdit:SetText("")
            frame.searchEdit:SetText(name) -- jump the search to show it immediately
        else
            ns.Print("Refused - you must be the recipient or an editor.")
        end
    end

    frame.addBtn:SetScript("OnClick", CommitAddItem)
    frame.addNameEdit:SetScript("OnEnterPressed", CommitAddItem)
    frame.addPointsEdit:SetScript("OnEnterPressed", CommitAddItem)
    frame.addItemIdEdit:SetScript("OnEnterPressed", CommitAddItem)
    frame.addDetailEdit:SetScript("OnEnterPressed", CommitAddItem)
    frame.addNameEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame.addPointsEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame.addItemIdEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame.addDetailEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    frame.scrollFrame = CreateFrame("ScrollFrame", "DHBavinPointsEditorScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPLEFT", frame.resultsHint, "BOTTOMLEFT", 0, -24)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame.addSection, "TOPRIGHT", -30, 10)

    frame.scrollContent = CreateFrame("Frame", nil, frame.scrollFrame)
    frame.scrollContent:SetSize(1, 1)
    frame.scrollFrame:SetScrollChild(frame.scrollContent)

    -- Column header labels, pinned to frame.scrollFrame's right edge
    -- using the exact same width/gap constants each row's itemId/points
    -- cells use (see the block above CreateRow) - anchored to scrollFrame
    -- itself, not scrollContent, since scrollContent's on-screen top
    -- shifts while the list is scrolled but scrollFrame's own edges
    -- never move. The -24 mirrors scrollContent:SetWidth()'s reduction
    -- in PointsEditor_Refresh below, so this can't drift out of sync
    -- with the rows the way the old hand-spaced string did.
    frame.pointsHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.pointsHeader:SetWidth(POINTS_WIDTH)
    frame.pointsHeader:SetJustifyH("RIGHT")
    frame.pointsHeader:SetText("points")
    frame.pointsHeader:SetPoint("BOTTOMRIGHT", frame.scrollFrame, "TOPRIGHT",
        -(CONTENT_RIGHT_PAD + REVERT_RIGHT_PAD + REVERT_WIDTH + SAVE_GAP + SAVE_WIDTH + POINTS_GAP), 4)

    frame.itemIdHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.itemIdHeader:SetWidth(ITEMID_WIDTH)
    frame.itemIdHeader:SetJustifyH("RIGHT")
    frame.itemIdHeader:SetText("itemID")
    frame.itemIdHeader:SetPoint("RIGHT", frame.pointsHeader, "LEFT", -ITEMID_GAP, 0)
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

function ns.PointsEditor_Refresh()
    if not frame or not frame:IsShown() then return end

    local content = frame.scrollContent
    content:SetWidth(math.max(1, frame.scrollFrame:GetWidth() - 24))

    local matches = BuildMatches(searchText)
    local totalMatches = #matches
    local shown = math.min(totalMatches, MAX_RESULTS)

    for i = 1, shown do
        local row = AcquireRow(content, i)
        RenderRow(row, matches[i], i)
    end
    HideRowsFrom(shown + 1)
    content:SetHeight(math.max(1, shown * ROW_HEIGHT))

    if searchText == "" then
        frame.resultsHint:SetText("Type part of an item name to search.")
    elseif totalMatches == 0 then
        frame.resultsHint:SetText("No matching items.")
    elseif totalMatches > shown then
        frame.resultsHint:SetText(("Showing %d of %d matches - narrow your search to see the rest."):format(shown, totalMatches))
    else
        frame.resultsHint:SetText(totalMatches .. " matching item" .. (totalMatches == 1 and "" or "s") .. ".")
    end
end

-- Refuses outright (no frame created/shown) if the caller isn't the
-- recipient or a designated editor - see file header's GATING note for
-- why this differs from DestinationEditor's read-only-for-everyone
-- approach.
function ns.PointsEditor_Open()
    if not ns.CanEditListLocal() then
        ns.Print("Only the recipient or a designated editor can open the Points Editor.")
        return
    end
    if not frame then
        CreateEditorFrame()
    end
    frame:Show()
    ns.PointsEditor_Refresh()
end

-- Closing is always allowed regardless of permission - only opening is
-- gated (see PointsEditor_Open).
function ns.PointsEditor_Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
        return
    end
    ns.PointsEditor_Open()
end
