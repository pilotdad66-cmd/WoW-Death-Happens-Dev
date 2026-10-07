
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
-- names added through the footer form below).
--
-- 2026-10-07 (Loopi): UPDATED for the fields the sheet gained after this
-- editor was written. Each result is now THREE lines:
--   1. name | itemID | gold | points | Save | Revert
--   2. Category (drop-down) | Stack | Source phrase
--   3. the item text | "Auto" (reset to automatic)
-- The text is BUILT from points + gold + stack + category/phrase (Core.lua's
-- ns.BuildItemDetail) and follows the fields until it is edited by hand;
-- a hand-edited text is kept verbatim and stops following until "Auto" is
-- pressed. Typing a gold value fills the points at the items-only ratio
-- (ns.GetItemPointsPerGold, 10:1) until the points are typed by hand - for an
-- existing item only if its points are still on the ratio, so a deliberately
-- raised value is never overwritten. The "Add a new item" footer has the same
-- fields; a blank Stack is filled from GetItemInfo's max stack there (new
-- entries only - an existing item's text is never changed by merely opening it).

local DHTools = DHTools
local ns = DHTools.Bavin

local TOP_LINE_HEIGHT = 20
local FIELD_LINE_HEIGHT = 22
local TEXT_LINE_HEIGHT = 20
local ROW_HEIGHT = TOP_LINE_HEIGHT + FIELD_LINE_HEIGHT + TEXT_LINE_HEIGHT + 6
local DETAIL_INDENT = 8
local MAX_RESULTS = 25
local MAX_HAND_TEXT = 150 -- a hand-edited text goes over the wire verbatim (PTSSET limit)

-- Column geometry shared between each row's cells (CreateRow) and the
-- header labels (CreateEditorFrame) so the two can never silently drift
-- apart (2026-08-05 header-misalignment bug). Every offset here is reused
-- verbatim by both the rows and the headers.
local REVERT_WIDTH = 52
local REVERT_RIGHT_PAD = 2
local SAVE_WIDTH = 40
local SAVE_GAP = 8
local POINTS_WIDTH = 56
local POINTS_GAP = 8
local GOLD_WIDTH = 56
local GOLD_GAP = 8
local ITEMID_WIDTH = 50
local ITEMID_GAP = 10
local CONTENT_RIGHT_PAD = 24 -- must match scrollContent:SetWidth() below

local frame
local rowPool = {}
local searchText = ""

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

local function Trim(s)
    return ((s or ""):match("^%s*(.-)%s*$"))
end

-- 12.5 -> "12.5", 40 -> "40" (up to 4 decimals, trailing zeros cut)
local function NumText(n)
    if n == nil then return "" end
    local s = string.format("%.4f", n)
    s = s:gsub("0+$", "")
    s = s:gsub("%.$", "")
    return s
end

-- "" -> nil (blank), "12.5" -> 12.5, "abc" -> false (invalid)
local function ReadNumber(editBox)
    local text = Trim(editBox:GetText())
    if text == "" then return nil end
    local n = tonumber(text)
    if n == nil then return false end
    return n
end

local categoryMenuFrame

-- Drop-down of the item categories under the cursor (same vendored library +
-- EasyMenu idiom as CreditsConfig.lua's filter menus; looked up lazily so
-- load order doesn't matter). Falls back to cycling through the list if the
-- library is somehow missing.
local function OpenCategoryMenu(current, onPick)
    local list = ns.ITEM_CATEGORIES or {}
    local LibDropDown = LibStub and LibStub("LibUIDropDownMenuDHTools-4.0", true)
    if not LibDropDown then
        local idx = 0
        for i, c in ipairs(list) do if c == current then idx = i break end end
        onPick(list[(idx % #list) + 1])
        return
    end
    if not categoryMenuFrame then
        categoryMenuFrame = LibDropDown:Create_UIDropDownMenu("DHBavinPointsCategoryMenuFrame", UIParent)
    end
    local entries = { { text = "(no category)", checked = (current == nil), func = function() onPick(nil) end } }
    for _, c in ipairs(list) do
        entries[#entries + 1] = { text = c, checked = (c == current), func = function() onPick(c) end }
    end
    LibDropDown:EasyMenu(entries, categoryMenuFrame, "cursor", 0, 0, "MENU", 2)
end

-- Max stack from the client's item cache, or nil if the item isn't cached /
-- isn't stackable. GetItemInfo returns the stack count as its 8th value.
local function CachedMaxStack(itemId)
    if not itemId or not GetItemInfo then return nil end
    local ok, _, _, _, _, _, _, _, stackCount = pcall(GetItemInfo, itemId)
    if ok and type(stackCount) == "number" and stackCount > 1 then return stackCount end
    return nil
end

--------------------------------------------------------------------------
-- The field editor shared by the result rows and the "Add a new item" form
--------------------------------------------------------------------------
-- `ed` is a table of widgets the caller created: gold, points, catBtn, stack,
-- phrase, text, autoBtn, plus ed.getName() (the item name the text is built
-- for). WireEditor adds the behaviour and returns ed with:
--   ed.Load(fields)  fields = ns.ResolveItemFields(name)'s table, or nil to clear
--   ed.Read()        -> { points, extra, detail } or nil, "problem"
--   ed.Rebuild()     rebuilds the automatic text (no-op while hand-edited)
local function WireEditor(ed)
    local st = { category = nil, pointsTouched = false, textHand = false, phraseCustom = false, loading = false }
    ed.state = st

    local function CurrentPhrase()
        local p = Trim(ed.phrase:GetText())
        if p == "" or p == ns.DefaultItemPhrase(st.category) then return nil end
        return p
    end

    local function RefreshAutoButton()
        if st.textHand then ed.autoBtn:Enable() else ed.autoBtn:Disable() end
    end

    local function RefreshCategoryButton()
        ed.catBtn:SetText((st.category or "Category") .. " v")
    end

    local function Rebuild()
        if st.loading or st.textHand then return end
        local text = ns.BuildItemDetail(ed.getName(), tonumber(Trim(ed.points:GetText())) or 0,
            tonumber(Trim(ed.gold:GetText())), tonumber(Trim(ed.stack:GetText())), st.category, CurrentPhrase())
        ed.text:SetText(text)
        ed.text:SetCursorPosition(0)
    end
    ed.Rebuild = Rebuild

    ed.gold:SetScript("OnTextChanged", function(_, userInput)
        if st.loading or not userInput then return end
        if not st.pointsTouched then
            local g = tonumber(Trim(ed.gold:GetText()))
            ed.points:SetText(g and NumText(g * ns.GetItemPointsPerGold()) or "")
        end
        Rebuild()
    end)
    ed.points:SetScript("OnTextChanged", function(_, userInput)
        if st.loading or not userInput then return end
        st.pointsTouched = true
        Rebuild()
    end)
    ed.stack:SetScript("OnTextChanged", function(_, userInput)
        if st.loading or not userInput then return end
        Rebuild()
    end)
    ed.phrase:SetScript("OnTextChanged", function(_, userInput)
        if st.loading or not userInput then return end
        local p = Trim(ed.phrase:GetText())
        st.phraseCustom = (p ~= "" and p ~= ns.DefaultItemPhrase(st.category))
        Rebuild()
    end)
    ed.text:SetScript("OnTextChanged", function(_, userInput)
        if st.loading or not userInput then return end
        st.textHand = true
        RefreshAutoButton()
    end)
    ed.autoBtn:SetScript("OnClick", function()
        st.textHand = false
        RefreshAutoButton()
        Rebuild()
    end)
    ed.catBtn:SetScript("OnClick", function()
        OpenCategoryMenu(st.category, function(cat)
            st.category = cat
            if not st.phraseCustom then
                st.loading = true
                ed.phrase:SetText(ns.DefaultItemPhrase(cat))
                ed.phrase:SetCursorPosition(0)
                st.loading = false
            end
            RefreshCategoryButton()
            Rebuild()
        end)
    end)

    function ed.Load(fields)
        st.loading = true
        fields = fields or {}
        st.category = fields.category
        st.phraseCustom = fields.phrase ~= nil
        ed.gold:SetText(NumText(fields.goldValue))
        ed.points:SetText(NumText(fields.points))
        ed.stack:SetText(fields.stackSize and tostring(fields.stackSize) or "")
        ed.phrase:SetText(fields.phrase or ns.DefaultItemPhrase(fields.category))
        -- An existing item keeps autofill only while its points still sit on the
        -- gold ratio; a new entry (no points yet) always autofills.
        local g, p = tonumber(fields.goldValue), tonumber(fields.points)
        if p == nil then
            st.pointsTouched = false
        else
            st.pointsTouched = not (g and math.abs(p - g * ns.GetItemPointsPerGold()) < 0.005)
        end
        st.textHand = (fields.auto == false)
        st.loading = false
        RefreshCategoryButton()
        RefreshAutoButton()
        if st.textHand then
            ed.text:SetText(fields.detail or "")
        else
            Rebuild()
        end
        ed.gold:SetCursorPosition(0)
        ed.points:SetCursorPosition(0)
        ed.phrase:SetCursorPosition(0)
        ed.text:SetCursorPosition(0)
    end

    -- Validates and collects the fields. Returns nil, "message" on a problem.
    function ed.Read()
        local pointsText = Trim(ed.points:GetText())
        local points = tonumber(pointsText)
        if not points then
            return nil, "'" .. pointsText .. "' isn't a number - enter a points value."
        end
        local gold = ReadNumber(ed.gold)
        if gold == false then return nil, "Gold must be a number (e.g. 1.5 for 1g 50s)." end
        local stack = ReadNumber(ed.stack)
        if stack == false then return nil, "Stack must be a number." end
        if stack ~= nil and stack <= 1 then stack = nil end -- 0 / 1 mean "no stack text"
        local text = Trim(ed.text:GetText())
        if st.textHand and #text > MAX_HAND_TEXT then
            return nil, ("The hand-edited text is %d characters - the limit is %d (press Auto to rebuild it)."):format(#text, MAX_HAND_TEXT)
        end
        return {
            points = points,
            detail = st.textHand and text or nil,
            extra = {
                goldValue = gold,
                category = st.category,
                stackSize = stack,
                phrase = CurrentPhrase(),
                auto = not st.textHand,
            },
        }
    end

    RefreshCategoryButton()
    RefreshAutoButton()
    return ed
end

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

    -- Line 1 lives in a fixed-height strip pinned to the row's top so its
    -- horizontal geometry (and so the column headers) stay exactly as they
    -- were when a row was one line.
    row.topLine = CreateFrame("Frame", nil, row)
    row.topLine:SetHeight(TOP_LINE_HEIGHT)
    row.topLine:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.topLine:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)

    -- Only shown for rows currently carrying a live override (see
    -- RenderRow) - reverting is an explicit action, never implied by
    -- clearing the points field.
    row.revertBtn = CreateFrame("Button", nil, row.topLine, "UIPanelButtonTemplate")
    row.revertBtn:SetSize(REVERT_WIDTH, 18)
    row.revertBtn:SetText("Revert")
    row.revertBtn:SetPoint("RIGHT", row.topLine, "RIGHT", -REVERT_RIGHT_PAD, 0)

    -- Explicit Save, separate from the implicit "press Enter" commit (2026-08-05:
    -- nothing signaled Enter was required, so edits looked unsavable).
    row.saveBtn = CreateFrame("Button", nil, row.topLine, "UIPanelButtonTemplate")
    row.saveBtn:SetSize(SAVE_WIDTH, 18)
    row.saveBtn:SetText("Save")
    row.saveBtn:SetPoint("RIGHT", row.revertBtn, "LEFT", -SAVE_GAP, 0)

    -- Text mode, not SetNumeric(true): 0 and negative points are valid.
    row.pointsEdit = CreateFrame("EditBox", nil, row.topLine, "InputBoxTemplate")
    row.pointsEdit:SetSize(POINTS_WIDTH, 18)
    row.pointsEdit:SetPoint("RIGHT", row.saveBtn, "LEFT", -POINTS_GAP, 0)
    row.pointsEdit:SetAutoFocus(false)
    row.pointsEdit:SetMaxLetters(10)
    row.pointsEdit:SetJustifyH("RIGHT")

    -- Gold is a decimal (1.5 = 1g 50s), so text mode too.
    row.goldEdit = CreateFrame("EditBox", nil, row.topLine, "InputBoxTemplate")
    row.goldEdit:SetSize(GOLD_WIDTH, 18)
    row.goldEdit:SetPoint("RIGHT", row.pointsEdit, "LEFT", -GOLD_GAP, 0)
    row.goldEdit:SetAutoFocus(false)
    row.goldEdit:SetMaxLetters(10)
    row.goldEdit:SetJustifyH("RIGHT")

    -- Editable itemID (2026-08-06: the import got some wrong); numeric is
    -- fine here, and empty means "no itemID on file".
    row.itemIdEdit = CreateFrame("EditBox", nil, row.topLine, "InputBoxTemplate")
    row.itemIdEdit:SetSize(ITEMID_WIDTH, 18)
    row.itemIdEdit:SetPoint("RIGHT", row.goldEdit, "LEFT", -ITEMID_GAP, 0)
    row.itemIdEdit:SetAutoFocus(false)
    row.itemIdEdit:SetNumeric(true)
    row.itemIdEdit:SetMaxLetters(7)
    row.itemIdEdit:SetJustifyH("RIGHT")

    row.nameText = row.topLine:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.nameText:SetPoint("LEFT", row.topLine, "LEFT", 4, 0)
    row.nameText:SetPoint("RIGHT", row.itemIdEdit, "LEFT", -10, 0)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false) -- truncate; widen the window to read a long name

    -- Line 2: category drop-down, stack, source phrase.
    row.fieldLine = CreateFrame("Frame", nil, row)
    row.fieldLine:SetHeight(FIELD_LINE_HEIGHT)
    row.fieldLine:SetPoint("TOPLEFT", row, "TOPLEFT", DETAIL_INDENT, -(TOP_LINE_HEIGHT + 2))
    row.fieldLine:SetPoint("TOPRIGHT", row, "TOPRIGHT", -REVERT_RIGHT_PAD, -(TOP_LINE_HEIGHT + 2))

    row.catBtn = CreateFrame("Button", nil, row.fieldLine, "UIPanelButtonTemplate")
    row.catBtn:SetSize(130, 18)
    row.catBtn:SetPoint("LEFT", row.fieldLine, "LEFT", 0, 0)

    row.stackLabel = row.fieldLine:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.stackLabel:SetPoint("LEFT", row.catBtn, "RIGHT", 10, 0)
    row.stackLabel:SetText("stack")
    row.stackEdit = CreateFrame("EditBox", nil, row.fieldLine, "InputBoxTemplate")
    row.stackEdit:SetSize(36, 18)
    row.stackEdit:SetPoint("LEFT", row.stackLabel, "RIGHT", 8, 0)
    row.stackEdit:SetAutoFocus(false)
    row.stackEdit:SetNumeric(true)
    row.stackEdit:SetMaxLetters(4)
    row.stackEdit:SetJustifyH("RIGHT")

    row.phraseLabel = row.fieldLine:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.phraseLabel:SetPoint("LEFT", row.stackEdit, "RIGHT", 10, 0)
    row.phraseLabel:SetText("source")
    row.phraseEdit = CreateFrame("EditBox", nil, row.fieldLine, "InputBoxTemplate")
    row.phraseEdit:SetHeight(18)
    row.phraseEdit:SetPoint("LEFT", row.phraseLabel, "RIGHT", 8, 0)
    row.phraseEdit:SetPoint("RIGHT", row.fieldLine, "RIGHT", 0, 0)
    row.phraseEdit:SetAutoFocus(false)
    row.phraseEdit:SetMaxLetters(60)
    row.phraseEdit:SetJustifyH("LEFT")

    -- Line 3: the item text (what the tooltip / "? " answer shows) + Auto.
    row.textLine = CreateFrame("Frame", nil, row)
    row.textLine:SetHeight(TEXT_LINE_HEIGHT)
    row.textLine:SetPoint("TOPLEFT", row, "TOPLEFT", DETAIL_INDENT, -(TOP_LINE_HEIGHT + FIELD_LINE_HEIGHT + 4))
    row.textLine:SetPoint("TOPRIGHT", row, "TOPRIGHT", -REVERT_RIGHT_PAD, -(TOP_LINE_HEIGHT + FIELD_LINE_HEIGHT + 4))

    row.autoBtn = CreateFrame("Button", nil, row.textLine, "UIPanelButtonTemplate")
    row.autoBtn:SetSize(REVERT_WIDTH, 18)
    row.autoBtn:SetText("Auto")
    row.autoBtn:SetPoint("RIGHT", row.textLine, "RIGHT", 0, 0)

    row.textEdit = CreateFrame("EditBox", nil, row.textLine, "InputBoxTemplate")
    row.textEdit:SetHeight(18)
    row.textEdit:SetPoint("LEFT", row.textLine, "LEFT", 4, 0)
    row.textEdit:SetPoint("RIGHT", row.autoBtn, "LEFT", -8, 0)
    row.textEdit:SetAutoFocus(false)
    row.textEdit:SetMaxLetters(200)
    row.textEdit:SetJustifyH("LEFT")

    row.ed = WireEditor({
        gold = row.goldEdit, points = row.pointsEdit, catBtn = row.catBtn, stack = row.stackEdit,
        phrase = row.phraseEdit, text = row.textEdit, autoBtn = row.autoBtn,
        getName = function() return row.itemName or "?" end,
    })

    -- One commit path for Enter in any box and the Save button (single place to
    -- keep in sync; a success message either way).
    local boxes = { row.pointsEdit, row.goldEdit, row.itemIdEdit, row.stackEdit, row.phraseEdit, row.textEdit }
    local function Commit()
        for _, box in ipairs(boxes) do box:ClearFocus() end
        local name = row.itemName
        if not name then return end
        if Trim(row.pointsEdit:GetText()) == "" then
            return -- explicit no-op - use Revert to actually clear an override
        end
        local fields, problem = row.ed.Read()
        if not fields then
            ns.Print(problem .. " Nothing saved.")
            ns.PointsEditor_Refresh() -- restores the fields to their last real values
            return
        end
        local itemIdText = Trim(row.itemIdEdit:GetText())
        local itemId = itemIdText ~= "" and tonumber(itemIdText) or nil
        if ns.SetItemPoints(name, fields.points, itemId, fields.detail, fields.extra) then
            ns.Print(name .. " set to " .. NumText(fields.points) .. " points"
                .. (itemId and (", itemID " .. itemId) or "") .. ".")
        else
            ns.Print("Refused - you must be the recipient or an editor.")
        end
        ns.PointsEditor_Refresh()
    end

    for _, box in ipairs(boxes) do
        box:SetScript("OnEnterPressed", Commit)
        box:SetScript("OnEscapePressed", function(self)
            self:ClearFocus()
            ns.PointsEditor_Refresh()
        end)
    end
    row.saveBtn:SetScript("OnClick", Commit)
    row.revertBtn:SetScript("OnClick", function()
        if row.itemName then ns.RevertItemPoints(row.itemName) end
        ns.PointsEditor_Refresh()
    end)

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
    row.itemName = name

    local info = ns.ResolveItemFields(name)

    row.nameText:SetText(name)
    if info and info.isOverride then
        row.nameText:SetTextColor(1, 0.82, 0) -- flags a live edit at a glance
    else
        row.nameText:SetTextColor(1, 1, 1)
    end

    row.itemIdEdit:SetText((info and info.itemId) and tostring(info.itemId) or "")
    row.itemIdEdit:SetCursorPosition(0)

    -- Gold, points, category, stack, source phrase and the text all come from
    -- the merged view (Core.lua's ResolveItemFields): an override's own value,
    -- else the baseline's, with stack/phrase recovered from the shipped text.
    row.ed.Load(info)

    row.revertBtn:SetShown(info ~= nil and info.isOverride)
    row:Show()
end

--------------------------------------------------------------------------
-- Frame construction (built once, first time the editor is opened)
--------------------------------------------------------------------------

local function CreateEditorFrame()
    frame = CreateFrame("Frame", "DHBavinPointsEditorFrame", UIParent, "BasicFrameTemplateWithInset")
    -- 2026-10-07: 520x560 -> 640x660. Rows are three lines now (see
    -- ROW_HEIGHT) and the footer form carries the same fields.
    frame:SetSize(640, 660)
    frame:SetPoint("CENTER")
    if frame.TitleText then
        frame.TitleText:SetText("Bavin - Points Editor")
    end
    tinsert(UISpecialFrames, "DHBavinPointsEditorFrame")

    -- Toplevel raising, opaque background, title-bar-only dragging - see
    -- DH-Tools Core.lua's InitStandaloneWindow. Dot-call, not colon: it's
    -- a plain shared function hung off the DHTools table.
    DHTools.InitStandaloneWindow(frame)

    frame:SetResizable(true)
    if frame.SetMinResize then frame:SetMinResize(560, 520) end
    if frame.SetMaxResize then frame:SetMaxResize(900, 900) end

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
    frame.hint:SetText(("Search an item name below to view or edit it. Line 1: itemID, gold value and points (typing gold fills points at %s per gold until you type points yourself). Line 2: category, stack size and the source phrase. Line 3: the text shown on the item - it is built from the fields above and follows them until you edit it by hand; press Auto to go back to the built text. Press Enter or Save to commit - saved changes push live to everyone online and sync to anyone who logs in later. The form at the bottom adds a brand-new item. Note: edits are overwritten whenever a new addon version ships a regenerated list from the spreadsheet."):format(NumText(ns.GetItemPointsPerGold())))

    frame.searchEdit = CreateFrame("EditBox", "DHBavinPointsEditorSearch", frame, "InputBoxTemplate")
    frame.searchEdit:SetSize(200, 20)
    frame.searchEdit:SetPoint("TOPLEFT", frame.hint, "BOTTOMLEFT", 6, -10)
    frame.searchEdit:SetAutoFocus(false)
    frame.searchEdit:SetMaxLetters(64)
    frame.searchEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    frame.searchEdit:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    frame.searchEdit:SetScript("OnTextChanged", function(self)
        searchText = Trim(self:GetText())
        ns.PointsEditor_Refresh()
    end)

    frame.resultsHint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.resultsHint:SetPoint("TOPLEFT", frame.searchEdit, "BOTTOMLEFT", -6, -10)
    frame.resultsHint:SetPoint("RIGHT", -12, 0)
    frame.resultsHint:SetJustifyH("LEFT")

    -- Add-new-item footer form: a name that doesn't need to exist in
    -- ns.ITEM_POINTS' baseline, with the same fields as a result row. Built
    -- BEFORE scrollFrame so scrollFrame's bottom edge can anchor off it.
    -- Rows are stacked bottom-up: text line, field line, then the name line.
    frame.addSection = CreateFrame("Frame", nil, frame)
    frame.addSection:SetHeight(100)
    frame.addSection:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 10)
    frame.addSection:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 10)

    frame.addLabel = frame.addSection:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.addLabel:SetPoint("TOPLEFT", frame.addSection, "TOPLEFT", 0, 0)
    frame.addLabel:SetText("Add a new item (name, itemID, gold, points; then category, stack, source; the text builds itself):")

    -- Bottom line: the text + Auto.
    frame.addTextLine = CreateFrame("Frame", nil, frame.addSection)
    frame.addTextLine:SetHeight(TEXT_LINE_HEIGHT)
    frame.addTextLine:SetPoint("BOTTOMLEFT", frame.addSection, "BOTTOMLEFT", 0, 0)
    frame.addTextLine:SetPoint("BOTTOMRIGHT", frame.addSection, "BOTTOMRIGHT", 0, 0)

    frame.addAutoBtn = CreateFrame("Button", nil, frame.addTextLine, "UIPanelButtonTemplate")
    frame.addAutoBtn:SetSize(70, 20)
    frame.addAutoBtn:SetText("Auto")
    frame.addAutoBtn:SetPoint("RIGHT", frame.addTextLine, "RIGHT", 0, 0)

    frame.addTextEdit = CreateFrame("EditBox", nil, frame.addTextLine, "InputBoxTemplate")
    frame.addTextEdit:SetHeight(20)
    frame.addTextEdit:SetPoint("LEFT", frame.addTextLine, "LEFT", 4, 0)
    frame.addTextEdit:SetPoint("RIGHT", frame.addAutoBtn, "LEFT", -8, 0)
    frame.addTextEdit:SetAutoFocus(false)
    frame.addTextEdit:SetMaxLetters(200)
    frame.addTextEdit:SetJustifyH("LEFT")

    -- Middle line: category, stack, source phrase.
    frame.addFieldLine = CreateFrame("Frame", nil, frame.addSection)
    frame.addFieldLine:SetHeight(FIELD_LINE_HEIGHT)
    frame.addFieldLine:SetPoint("BOTTOMLEFT", frame.addTextLine, "TOPLEFT", 0, 2)
    frame.addFieldLine:SetPoint("BOTTOMRIGHT", frame.addTextLine, "TOPRIGHT", 0, 2)

    frame.addCatBtn = CreateFrame("Button", nil, frame.addFieldLine, "UIPanelButtonTemplate")
    frame.addCatBtn:SetSize(130, 20)
    frame.addCatBtn:SetPoint("LEFT", frame.addFieldLine, "LEFT", 0, 0)

    frame.addStackLabel = frame.addFieldLine:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.addStackLabel:SetPoint("LEFT", frame.addCatBtn, "RIGHT", 10, 0)
    frame.addStackLabel:SetText("stack")
    frame.addStackEdit = CreateFrame("EditBox", nil, frame.addFieldLine, "InputBoxTemplate")
    frame.addStackEdit:SetSize(36, 20)
    frame.addStackEdit:SetPoint("LEFT", frame.addStackLabel, "RIGHT", 8, 0)
    frame.addStackEdit:SetAutoFocus(false)
    frame.addStackEdit:SetNumeric(true)
    frame.addStackEdit:SetMaxLetters(4)
    frame.addStackEdit:SetJustifyH("RIGHT")

    frame.addPhraseLabel = frame.addFieldLine:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.addPhraseLabel:SetPoint("LEFT", frame.addStackEdit, "RIGHT", 10, 0)
    frame.addPhraseLabel:SetText("source")
    frame.addPhraseEdit = CreateFrame("EditBox", nil, frame.addFieldLine, "InputBoxTemplate")
    frame.addPhraseEdit:SetHeight(20)
    frame.addPhraseEdit:SetPoint("LEFT", frame.addPhraseLabel, "RIGHT", 8, 0)
    frame.addPhraseEdit:SetPoint("RIGHT", frame.addFieldLine, "RIGHT", 0, 0)
    frame.addPhraseEdit:SetAutoFocus(false)
    frame.addPhraseEdit:SetMaxLetters(60)
    frame.addPhraseEdit:SetJustifyH("LEFT")

    -- Top line: name, itemID, gold, points, Add. These chain to each other
    -- with plain RIGHT/LEFT anchors, so they share one 20px container.
    frame.addTopRow = CreateFrame("Frame", nil, frame.addSection)
    frame.addTopRow:SetHeight(20)
    frame.addTopRow:SetPoint("BOTTOMLEFT", frame.addFieldLine, "TOPLEFT", 0, 2)
    frame.addTopRow:SetPoint("BOTTOMRIGHT", frame.addFieldLine, "TOPRIGHT", 0, 2)

    frame.addBtn = CreateFrame("Button", nil, frame.addTopRow, "UIPanelButtonTemplate")
    frame.addBtn:SetSize(70, 20)
    frame.addBtn:SetText("Add Item")
    frame.addBtn:SetPoint("BOTTOMRIGHT", frame.addTopRow, "BOTTOMRIGHT", 0, 0)

    frame.addPointsEdit = CreateFrame("EditBox", nil, frame.addTopRow, "InputBoxTemplate")
    frame.addPointsEdit:SetSize(POINTS_WIDTH, 20)
    frame.addPointsEdit:SetPoint("RIGHT", frame.addBtn, "LEFT", -SAVE_GAP, 0)
    frame.addPointsEdit:SetAutoFocus(false)
    frame.addPointsEdit:SetMaxLetters(10)
    frame.addPointsEdit:SetJustifyH("RIGHT")

    frame.addGoldEdit = CreateFrame("EditBox", nil, frame.addTopRow, "InputBoxTemplate")
    frame.addGoldEdit:SetSize(GOLD_WIDTH, 20)
    frame.addGoldEdit:SetPoint("RIGHT", frame.addPointsEdit, "LEFT", -GOLD_GAP, 0)
    frame.addGoldEdit:SetAutoFocus(false)
    frame.addGoldEdit:SetMaxLetters(10)
    frame.addGoldEdit:SetJustifyH("RIGHT")

    frame.addItemIdEdit = CreateFrame("EditBox", nil, frame.addTopRow, "InputBoxTemplate")
    frame.addItemIdEdit:SetSize(ITEMID_WIDTH, 20)
    frame.addItemIdEdit:SetPoint("RIGHT", frame.addGoldEdit, "LEFT", -ITEMID_GAP, 0)
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

    frame.addEd = WireEditor({
        gold = frame.addGoldEdit, points = frame.addPointsEdit, catBtn = frame.addCatBtn,
        stack = frame.addStackEdit, phrase = frame.addPhraseEdit, text = frame.addTextEdit,
        autoBtn = frame.addAutoBtn,
        getName = function() return Trim(frame.addNameEdit:GetText()) end,
    })
    frame.addEd.Load(nil)

    -- The text names the item, so it follows the name box too; a blank Stack
    -- is filled from the client's item cache once a cached itemID is typed.
    frame.addNameEdit:SetScript("OnTextChanged", function(_, userInput)
        if userInput then frame.addEd.Rebuild() end
    end)
    frame.addItemIdEdit:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        if Trim(frame.addStackEdit:GetText()) == "" then
            local stack = CachedMaxStack(tonumber(Trim(self:GetText())))
            if stack then
                frame.addStackEdit:SetText(tostring(stack))
                frame.addEd.Rebuild()
            end
        end
    end)

    -- Shared by the Add button and Enter in any of the fields, same
    -- single-commit-path idiom the per-row Commit uses.
    local addBoxes = { frame.addNameEdit, frame.addItemIdEdit, frame.addGoldEdit, frame.addPointsEdit,
        frame.addStackEdit, frame.addPhraseEdit, frame.addTextEdit }
    local function CommitAddItem()
        for _, box in ipairs(addBoxes) do box:ClearFocus() end
        local name = Trim(frame.addNameEdit:GetText())
        if name == "" then
            ns.Print("Enter an item name before adding.")
            return
        end
        local fields, problem = frame.addEd.Read()
        if not fields then
            ns.Print(problem)
            return
        end
        local itemIdText = Trim(frame.addItemIdEdit:GetText())
        local itemId = itemIdText ~= "" and tonumber(itemIdText) or nil
        if ns.SetItemPoints(name, fields.points, itemId, fields.detail, fields.extra) then
            ns.Print(name .. " added at " .. NumText(fields.points) .. " points"
                .. (itemId and (", itemID " .. itemId) or "") .. ".")
            frame.addNameEdit:SetText("")
            frame.addItemIdEdit:SetText("")
            frame.addEd.Load(nil)
            frame.searchEdit:SetText(name) -- jump the search to show it immediately
        else
            ns.Print("Refused - you must be the recipient or an editor.")
        end
    end

    frame.addBtn:SetScript("OnClick", CommitAddItem)
    for _, box in ipairs(addBoxes) do
        box:SetScript("OnEnterPressed", CommitAddItem)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    end

    frame.scrollFrame = CreateFrame("ScrollFrame", "DHBavinPointsEditorScrollFrame", frame, (DHTools and DHTools.SCROLL_TEMPLATE) or "UIPanelScrollFrameTemplate")
    if DHTools and DHTools.SkinScrollBar then DHTools.SkinScrollBar(frame.scrollFrame) end
    frame.scrollFrame:SetPoint("TOPLEFT", frame.resultsHint, "BOTTOMLEFT", 0, -24)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame.addSection, "TOPRIGHT", -30, 10)

    frame.scrollContent = CreateFrame("Frame", nil, frame.scrollFrame)
    frame.scrollContent:SetSize(1, 1)
    frame.scrollFrame:SetScrollChild(frame.scrollContent)

    -- Column header labels, pinned to frame.scrollFrame's right edge
    -- using the exact same width/gap constants each row's cells use -
    -- anchored to scrollFrame itself (its edges never move while the list
    -- scrolls). The -24 mirrors scrollContent:SetWidth()'s reduction in
    -- PointsEditor_Refresh below.
    frame.pointsHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.pointsHeader:SetWidth(POINTS_WIDTH)
    frame.pointsHeader:SetJustifyH("RIGHT")
    frame.pointsHeader:SetText("points")
    frame.pointsHeader:SetPoint("BOTTOMRIGHT", frame.scrollFrame, "TOPRIGHT",
        -(CONTENT_RIGHT_PAD + REVERT_RIGHT_PAD + REVERT_WIDTH + SAVE_GAP + SAVE_WIDTH + POINTS_GAP), 4)

    frame.goldHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.goldHeader:SetWidth(GOLD_WIDTH)
    frame.goldHeader:SetJustifyH("RIGHT")
    frame.goldHeader:SetText("gold")
    frame.goldHeader:SetPoint("RIGHT", frame.pointsHeader, "LEFT", -GOLD_GAP, 0)

    frame.itemIdHeader = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.itemIdHeader:SetWidth(ITEMID_WIDTH)
    frame.itemIdHeader:SetJustifyH("RIGHT")
    frame.itemIdHeader:SetText("itemID")
    frame.itemIdHeader:SetPoint("RIGHT", frame.goldHeader, "LEFT", -ITEMID_GAP, 0)
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
