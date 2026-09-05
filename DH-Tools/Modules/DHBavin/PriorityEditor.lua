-- DH-Bavin PriorityEditor.lua
-- Milestone 4's real settings UI for the priority list (see this
-- folder's DH-Bavin-Design.md, revised 2026-08-04 - the original doc
-- specified a free-text item-link input; Loopi asked instead for a
-- type-to-filter search matching Bavin Points, so this file is built as
-- a near-direct structural port of PointsEditor.lua: same window chrome,
-- same row-pool/search pattern, same MAX_RESULTS cap, sourced from the
-- SAME ns.ITEM_POINTS baseline (ItemPoints.lua's ~7000 name-keyed
-- entries) rather than a second item database - virtually everything a
-- guild would want on a donation priority list already has a Bavin
-- Points entry, since both features cover the same domain. Opened via
-- /dhb priority (Core.lua's slash dispatch calls
-- ns.PriorityEditor_Toggle).
--
-- GATING: same as PointsEditor.lua - refuses outright (never creates/
-- shows the frame) if CanEditList fails. Closing is always allowed.
--
-- ADD/REMOVE, NOT EDIT: each row has one toggle button instead of
-- PointsEditor's points-edit-box + Revert pair, since there's nothing to
-- edit here - an item is either on the priority list or it isn't.
-- ns.priorityList stays keyed by item NAME (see Sync.lua's priorityList
-- comment for the 2026-08-04 name-vs-itemID rationale, ported from
-- knowledge\k-0005's original itemID-collision lesson).
--
-- itemId for a newly-added entry comes straight from ns.ITEM_POINTS
-- (already resolved at Bavin Points intake time - see ItemPoints.lua's
-- header). itemLink is best-effort only: GetItemInfo(itemId) returns a
-- real colored link if this client already has that item cached, nil
-- otherwise - nil is fine, it's display convenience only (per Design
-- doc), never required for AddItem/RemoveItem to work.

local DHTools = DHTools
local ns = DHTools.Bavin

local ROW_HEIGHT = 20
local MAX_RESULTS = 25

local frame
local rowPool = {}
local searchText = ""

--------------------------------------------------------------------------
-- Matching
--------------------------------------------------------------------------

-- Identical approach to PointsEditor.lua's BuildMatches - see that
-- file's comment for why a full per-keystroke table scan is fine here
-- (cheap table scan + string.find, not frame creation).
local function BuildMatches(typed)
    local matches = {}
    if typed == "" or not ns.ITEM_POINTS then return matches end
    local needle = typed:lower()
    for name in pairs(ns.ITEM_POINTS) do
        if name:lower():find(needle, 1, true) then
            table.insert(matches, name)
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

    row.toggleBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.toggleBtn:SetSize(60, 18)
    row.toggleBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)

    row.itemIdText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.itemIdText:SetPoint("RIGHT", row.toggleBtn, "LEFT", -10, 0)
    row.itemIdText:SetWidth(50)
    row.itemIdText:SetJustifyH("RIGHT")
    row.itemIdText:SetWordWrap(false)

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.nameText:SetPoint("RIGHT", row.itemIdText, "LEFT", -10, 0)
    row.nameText:SetJustifyH("LEFT")
    -- Truncate rather than wrap - rows are fixed-height, same reasoning
    -- as PointsEditor's nameText (window is resizable, so widening it
    -- reveals the full name if truncated).
    row.nameText:SetWordWrap(false)

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

    local baseline = ns.ITEM_POINTS[name]
    local onList = ns.priorityList and ns.priorityList[name] ~= nil

    row.nameText:SetText(name)
    if onList then
        row.nameText:SetTextColor(1, 0.82, 0) -- flags it's already on the list, at a glance
    else
        row.nameText:SetTextColor(1, 1, 1)
    end

    row.itemIdText:SetText((baseline and baseline.itemId) and tostring(baseline.itemId) or "\226\128\148")

    if onList then
        row.toggleBtn:SetText("Remove")
    else
        row.toggleBtn:SetText("Add")
    end
    row.toggleBtn:SetScript("OnClick", function()
        if onList then
            if ns.RemoveItem(name) then
                ns.PriorityEditor_Refresh()
            else
                ns.Print("Refused - you must be the recipient or an editor.")
            end
        else
            local itemId = baseline and baseline.itemId or nil
            -- Best-effort only - see file header. GetItemInfo with a
            -- nil itemId is harmless (just returns nil straight back).
            local itemLink = itemId and select(2, GetItemInfo(itemId)) or nil
            if ns.AddItem(name, itemId, itemLink) then
                ns.PriorityEditor_Refresh()
            else
                ns.Print("Refused - you must be the recipient or an editor.")
            end
        end
    end)

    row:Show()
end

--------------------------------------------------------------------------
-- Frame construction (built once, first time the editor is opened)
--------------------------------------------------------------------------

local function CreateEditorFrame()
    frame = CreateFrame("Frame", "DHBavinPriorityEditorFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(440, 460)
    frame:SetPoint("CENTER")
    if frame.TitleText then
        frame.TitleText:SetText("Bavin - Priority List Editor")
    end
    tinsert(UISpecialFrames, "DHBavinPriorityEditorFrame")

    DHTools.InitStandaloneWindow(frame)

    frame:SetResizable(true)
    if frame.SetMinResize then frame:SetMinResize(360, 320) end
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
            ns.PriorityEditor_Refresh()
        end
    end)

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.hint:SetPoint("TOPLEFT", 12, -32)
    frame.hint:SetPoint("RIGHT", -12, 0)
    frame.hint:SetJustifyH("LEFT")
    frame.hint:SetWordWrap(true)
    frame.hint:SetText("Search an item name below to add or remove it from the priority list. Changes push live to everyone online, and sync to anyone who logs in later.")

    frame.searchEdit = CreateFrame("EditBox", "DHBavinPriorityEditorSearch", frame, "InputBoxTemplate")
    frame.searchEdit:SetSize(200, 20)
    frame.searchEdit:SetPoint("TOPLEFT", frame.hint, "BOTTOMLEFT", 6, -10)
    frame.searchEdit:SetAutoFocus(false)
    frame.searchEdit:SetMaxLetters(64)
    frame.searchEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    frame.searchEdit:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    frame.searchEdit:SetScript("OnTextChanged", function(self)
        searchText = (self:GetText() or ""):match("^%s*(.-)%s*$")
        ns.PriorityEditor_Refresh()
    end)

    frame.resultsHint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.resultsHint:SetPoint("TOPLEFT", frame.searchEdit, "BOTTOMLEFT", -6, -10)
    frame.resultsHint:SetPoint("RIGHT", -12, 0)
    frame.resultsHint:SetJustifyH("LEFT")

    frame.colHeaders = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.colHeaders:SetPoint("TOPLEFT", frame.resultsHint, "BOTTOMLEFT", 6, -8)
    frame.colHeaders:SetPoint("RIGHT", -12, 0)
    frame.colHeaders:SetJustifyH("RIGHT")
    frame.colHeaders:SetText("itemID")

    frame.scrollFrame = CreateFrame("ScrollFrame", "DHBavinPriorityEditorScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPLEFT", frame.colHeaders, "BOTTOMLEFT", 0, -6)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", -30, 12)

    frame.scrollContent = CreateFrame("Frame", nil, frame.scrollFrame)
    frame.scrollContent:SetSize(1, 1)
    frame.scrollFrame:SetScrollChild(frame.scrollContent)
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

function ns.PriorityEditor_Refresh()
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
-- recipient or a designated editor - same gating as PointsEditor.lua.
function ns.PriorityEditor_Open()
    if not ns.CanEditListLocal() then
        ns.Print("Only the recipient or a designated editor can open the Priority List editor.")
        return
    end
    if not frame then
        CreateEditorFrame()
    end
    frame:Show()
    ns.PriorityEditor_Refresh()
end

-- Closing is always allowed regardless of permission - only opening is
-- gated (see PriorityEditor_Open).
function ns.PriorityEditor_Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
        return
    end
    ns.PriorityEditor_Open()
end
