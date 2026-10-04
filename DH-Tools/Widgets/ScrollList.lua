-- Generic reusable scroll-list widget. Built on Blizzard's stock
-- HybridScrollFrameTemplate (ships with the client - zero addon-local
-- XML needed, matching DH-Tools' existing 100%-programmatic convention).
-- HybridScrollFrame_CreateButtons (Blizzard's own row-pool helper) needs
-- an XML button template, so rows are hand-built in Lua instead and
-- wired into scrollFrame.buttons + a custom scrollFrame.update function.
-- See src\DH-Tools\Modules\DHStore\DH-Store-Design.md, question #7, for
-- the design this implements. First consumer: DH-Store. NOT YET
-- IN-GAME TESTED - built 2026-09-28, no module wires it up live yet.
--
-- Usage:
--   local list = DHTools.Widgets.CreateScrollList(parent, {
--       rowHeight = 32,
--       rightInset = 20,   -- optional, room for the scrollbar (default 20)
--       createRow = function(row, poolIndex) ... build row's children once ... end,
--       updateRow = function(row, dataItem, dataIndex) ... paint row for this data ... end,
--       emptyText = "Nothing here yet.", -- optional
--   })
--   list.frame            -- the scroll frame itself; anchor/size it like any Frame
--   list:SetData(dataArray)   -- new dataset, resets scroll to top
--   list:Refresh()            -- re-render the current dataset in place (row pool, no SetData)

DHTools = DHTools or {}
local ns = DHTools
ns.Widgets = ns.Widgets or {}

local DEFAULT_ROW_HEIGHT = 32
local nameCounter = 0

function ns.Widgets.CreateScrollList(parent, opts)
    assert(type(opts) == "table", "DH-Tools ScrollList: opts table required")
    assert(type(opts.createRow) == "function", "DH-Tools ScrollList: opts.createRow required")
    assert(type(opts.updateRow) == "function", "DH-Tools ScrollList: opts.updateRow required")

    local rowHeight = opts.rowHeight or DEFAULT_ROW_HEIGHT
    local rightInset = opts.rightInset or 20

    -- HybridScrollFrameTemplate's own OnLoad handler looks itself up via
    -- self:GetName() (for its ScrollBar child etc.), so unlike most of
    -- this codebase's anonymous frames, this one needs a real, unique
    -- global name.
    nameCounter = nameCounter + 1
    local frameName = "DHToolsScrollList" .. nameCounter

    -- MUST be a "ScrollFrame" (not "Frame"): the template's ScrollChild and
    -- SetVerticalScroll only exist on a real ScrollFrame. Created as a plain
    -- Frame, HybridScrollFrame_SetOffset died calling the missing
    -- SetVerticalScroll and HybridScrollFrame_Update found no scrollChild.
    local scrollFrame = CreateFrame("ScrollFrame", frameName, parent, "HybridScrollFrameTemplate")
    scrollFrame.data = {}
    scrollFrame.buttonHeight = rowHeight -- HybridScrollFrame_GetOffset divides by this
    scrollFrame.stepSize = rowHeight     -- mouse-wheel step

    -- Blizzard's code reads lowercase scrollChild/scrollBar; the template's
    -- own child key casing and the scrollbar are not guaranteed, so wire
    -- both explicitly.
    local scrollChild = scrollFrame.scrollChild or scrollFrame.ScrollChild
    if not scrollChild then
        scrollChild = CreateFrame("Frame", frameName .. "ScrollChild", scrollFrame)
    end
    scrollChild:SetSize(1, 1)
    scrollFrame:SetScrollChild(scrollChild)
    scrollFrame.scrollChild = scrollChild

    -- Blizzard's framed "Trim" variant when the client has it (probed in
    -- Core.lua), else the plain bar + our drawn track below.
    local barTemplate = ns.HYBRID_BAR_TEMPLATE or "HybridScrollBarTemplate"
    local scrollBar = CreateFrame("Slider", frameName .. "ScrollBar", scrollFrame, barTemplate)
    scrollBar:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", 0, -16)
    scrollBar:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT", 0, 16)
    scrollBar:SetMinMaxValues(0, 0)
    scrollBar:SetValue(0)
    scrollFrame.scrollBar = scrollBar
    -- Fallback only: draws our own bordered track when the Trim bar wasn't used.
    if ns.SkinScrollBar then ns.SkinScrollBar(scrollFrame, barTemplate == "HybridScrollBarTrimTemplate") end

    local emptyText
    if opts.emptyText then
        emptyText = scrollFrame:CreateFontString(nil, "ARTWORK", "GameFontDisable")
        emptyText:SetPoint("CENTER", scrollFrame, "CENTER", -(rightInset / 2), 0)
        emptyText:SetText(opts.emptyText)
        emptyText:Hide()
    end

    -- Row pool: one persistent Button per visible slot, repainted as the
    -- user scrolls rather than recreated (Blizzard's own hand-rolled
    -- alternative to HybridScrollFrame_CreateButtons).
    scrollFrame.buttons = {}

    local function EnsureButtons()
        local height = scrollFrame:GetHeight()
        if height <= 0 then return end
        local needed = math.floor(height / rowHeight) + 1 -- +1 for a partial row at the bottom
        while #scrollFrame.buttons < needed do
            local index = #scrollFrame.buttons + 1
            -- Rows live in the scroll child (Blizzard's layout), so the
            -- frame's sub-row vertical scroll shifts them correctly.
            local row = CreateFrame("Button", frameName .. "Row" .. index, scrollChild)
            row:SetHeight(rowHeight)
            row:SetPoint("LEFT", scrollChild, "LEFT", 0, 0)
            row:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
            if index == 1 then
                row:SetPoint("TOP", scrollChild, "TOP", 0, 0)
            else
                row:SetPoint("TOP", scrollFrame.buttons[index - 1], "BOTTOM", 0, 0)
            end
            opts.createRow(row, index)
            row:Hide()
            scrollFrame.buttons[index] = row
        end
    end

    scrollFrame.update = function()
        EnsureButtons()
        local dataList = scrollFrame.data
        local count = #dataList
        local offset = HybridScrollFrame_GetOffset(scrollFrame)
        for i, row in ipairs(scrollFrame.buttons) do
            local dataIndex = i + offset
            local item = dataList[dataIndex]
            if item then
                opts.updateRow(row, item, dataIndex)
                row:Show()
            else
                row:Hide()
            end
        end
        if emptyText then
            if count == 0 then emptyText:Show() else emptyText:Hide() end
        end
        HybridScrollFrame_Update(scrollFrame, count * rowHeight, scrollFrame:GetHeight())
    end

    scrollFrame:SetScript("OnSizeChanged", function(_, width)
        scrollChild:SetWidth(math.max(1, (width or scrollFrame:GetWidth()) - rightInset))
        EnsureButtons()
        scrollFrame.update()
    end)

    local list = { frame = scrollFrame }

    -- New dataset - resets scroll position to the top. Call this when the
    -- underlying data changes shape (a new filter/search result, a fresh
    -- catalog sync) rather than Refresh, so the user isn't left scrolled
    -- past the end of a shorter list.
    function list:SetData(dataArray)
        scrollFrame.data = dataArray or {}
        HybridScrollFrame_SetOffset(scrollFrame, 0)
        scrollBar:SetValue(0)
        scrollFrame.update()
    end

    -- Re-render the current dataset in place (e.g. a listing's own state
    -- changed - pending/sold - without the dataset itself changing).
    -- Scroll position is preserved.
    function list:Refresh()
        scrollFrame.update()
    end

    return list
end
