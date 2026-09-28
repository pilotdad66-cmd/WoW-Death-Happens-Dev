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

    local scrollFrame = CreateFrame("Frame", frameName, parent, "HybridScrollFrameTemplate")
    scrollFrame.data = {}
    scrollFrame.buttonHeight = rowHeight -- HybridScrollFrame_GetOffset divides by this

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
            local row = CreateFrame("Button", frameName .. "Row" .. index, scrollFrame)
            row:SetHeight(rowHeight)
            row:SetPoint("LEFT", scrollFrame, "LEFT", 0, 0)
            row:SetPoint("RIGHT", scrollFrame, "RIGHT", -rightInset, 0)
            if index == 1 then
                row:SetPoint("TOP", scrollFrame, "TOP", 0, 0)
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

    scrollFrame:SetScript("OnSizeChanged", function()
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
        if scrollFrame.scrollBar then scrollFrame.scrollBar:SetValue(0) end
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
