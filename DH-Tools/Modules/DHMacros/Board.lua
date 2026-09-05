-- DH-Tools: Modules\DHMacros\Board.lua
-- Macro Board - cascading Class -> Spec -> Macro picker (MacroLibrary.lua
-- is the data source) with a description/text preview and a Create
-- Macro / Select Macro Text / Clear Choices / Config footer. Standalone
-- window via DHTools.InitStandaloneWindow, same as DH-Tools' own
-- Config.lua window.
--
-- "Any Spec" (the default, Loopi 2026-08-21) shows every macro for the
-- selected class - spec-general (filed under `false` in
-- MacroLibrary.lua) and every real spec's macros together. Picking an
-- actual spec narrows the list to that spec's macros PLUS the class's
-- spec-general ones (spec-general macros always show, regardless of
-- which spec - or none - is picked).
--
-- Layout is a best-effort estimate, unverified in-game - same caveat
-- Config.lua's Mob Marker/Bavin/Danger pages carry.

local DHMacros = DHMacros
local ns = DHMacros

local ANY_SPEC = "Any Spec"

local frame
local classDropdown, specDropdown, macroDropdown
local descText, bodyEdit, charCheck
local createBtn, selectBtn

local selectedClass -- current entry from ns.Library
local selectedSpec  -- a spec name string, or nil for "Any Spec"
local selectedEntry -- the chosen macro table (name/macroName/icon/body/desc), or nil

local SelectClass -- forward-declared: ClearChoices (defined first) calls it

local function GetVisibleMacros()
    if not selectedClass then return {} end
    local out = {}
    local function addAll(list)
        if not list then return end
        for _, m in ipairs(list) do table.insert(out, m) end
    end
    addAll(selectedClass.macros[false])
    if selectedClass.specs then
        if selectedSpec then
            addAll(selectedClass.macros[selectedSpec])
        else
            for _, spec in ipairs(selectedClass.specs) do
                addAll(selectedClass.macros[spec])
            end
        end
    end
    return out
end

local function ClassHasSpecMacros(class)
    if not class.specs then return false end
    for _, spec in ipairs(class.specs) do
        local list = class.macros[spec]
        if list and #list > 0 then return true end
    end
    return false
end

local function ClearMacroOnly()
    selectedEntry = nil
    UIDropDownMenu_SetText(macroDropdown, "")
    descText:SetText("")
    bodyEdit:SetText("")
    createBtn:Disable()
    selectBtn:Disable()
end

local function SelectMacro(m)
    selectedEntry = m
    UIDropDownMenu_SetText(macroDropdown, m.name)
    descText:SetText(m.desc or "")
    bodyEdit:SetText(m.body or "")
    createBtn:Enable()
    selectBtn:Enable()
end

local function SelectSpec(spec)
    selectedSpec = spec
    UIDropDownMenu_SetText(specDropdown, spec or ANY_SPEC)
    ClearMacroOnly()
end

SelectClass = function(class)
    selectedClass = class
    selectedSpec = nil
    UIDropDownMenu_SetText(classDropdown, class.label)
    UIDropDownMenu_SetText(specDropdown, ANY_SPEC)
    if ClassHasSpecMacros(class) then
        UIDropDownMenu_EnableDropDown(specDropdown)
    else
        UIDropDownMenu_DisableDropDown(specDropdown)
    end
    ClearMacroOnly()
end

local function ClearChoices()
    SelectClass(ns.Library[1]) -- ns.Library[1] is "General"
end

local function BuildFrame()
    frame = CreateFrame("Frame", "DHToolsMacrosBoardFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(480, 400)
    frame:SetPoint("CENTER")
    DHTools.InitStandaloneWindow(frame)
    if frame.TitleText then frame.TitleText:SetText("DH-Tools: Macros") end
    tinsert(UISpecialFrames, "DHToolsMacrosBoardFrame")

    -- Resizable (Loopi 2026-08-21). SetResizeBounds is the modern combined
    -- call; SetMinResize/SetMaxResize is the older pair some Classic Era
    -- API versions still expect - try the new one first, fall back rather
    -- than assume either exists (same defensive pattern Core.lua's
    -- GetSlotLimits uses for MAX_ACCOUNT_MACROS/MAX_CHARACTER_MACROS).
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(420, 360, 900, 700)
    else
        frame:SetMinResize(420, 360)
        frame:SetMaxResize(900, 700)
    end

    local resizeBtn = CreateFrame("Button", nil, frame)
    resizeBtn:SetSize(16, 16)
    resizeBtn:SetPoint("BOTTOMRIGHT", -4, 4)
    resizeBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeBtn:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    resizeBtn:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

    local classLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    classLabel:SetPoint("TOPLEFT", 16, -32)
    classLabel:SetText("Class:")

    classDropdown = CreateFrame("Frame", "DHToolsMacrosClassDropdown", frame, "UIDropDownMenuTemplate")
    classDropdown:SetPoint("LEFT", classLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(classDropdown, 150)

    local specLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    specLabel:SetPoint("TOPLEFT", classLabel, "BOTTOMLEFT", 0, -28)
    specLabel:SetText("Spec:")

    specDropdown = CreateFrame("Frame", "DHToolsMacrosSpecDropdown", frame, "UIDropDownMenuTemplate")
    specDropdown:SetPoint("LEFT", specLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(specDropdown, 150)

    local macroLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    macroLabel:SetPoint("TOPLEFT", specLabel, "BOTTOMLEFT", 0, -28)
    macroLabel:SetText("Macro:")

    macroDropdown = CreateFrame("Frame", "DHToolsMacrosMacroDropdown", frame, "UIDropDownMenuTemplate")
    macroDropdown:SetPoint("LEFT", macroLabel, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(macroDropdown, 230)

    local divider = frame:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.15)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", macroLabel, "BOTTOMLEFT", 0, -30)
    divider:SetPoint("RIGHT", -16, 0)

    descText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    descText:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -10)
    descText:SetPoint("RIGHT", -16, 0)
    descText:SetJustifyH("LEFT")
    descText:SetWordWrap(true)
    descText:SetHeight(32)

    -- Footer's checkbox row is built here, ahead of the rest of the
    -- footer below, purely so the macro text box (next) can anchor its
    -- bottom edge to it - visual order still puts it under the button
    -- row since that's what its own SetPoint offset says, code order
    -- just has to satisfy "the frame you anchor to must already exist".
    charCheck = CreateFrame("CheckButton", "DHToolsMacrosCharCheck", frame, "UICheckButtonTemplate")
    charCheck:SetPoint("BOTTOMLEFT", 16, 24)
    _G[charCheck:GetName() .. "Text"]:SetText("Character-Specific")

    -- Macro text box: a plain textured-background frame (matches the
    -- InitStandaloneWindow bg idiom in Core.lua) holding a multi-line,
    -- non-scrolling EditBox - macro bodies are capped at 255 characters
    -- so a handful of wrapped lines always fits without a scrollframe.
    -- Bottom edge anchors to the checkbox row instead of a fixed height,
    -- so this box (the one thing worth enlarging) grows/shrinks with the
    -- window - see BuildFrame's resize-grip section below.
    local textBg = CreateFrame("Frame", nil, frame)
    textBg:SetPoint("TOPLEFT", descText, "BOTTOMLEFT", 0, -8)
    textBg:SetPoint("RIGHT", -16, 0)
    textBg:SetPoint("BOTTOMLEFT", charCheck, "TOPLEFT", 0, 8)
    local textBgTex = textBg:CreateTexture(nil, "BACKGROUND")
    textBgTex:SetAllPoints()
    textBgTex:SetColorTexture(0, 0, 0, 0.6)

    bodyEdit = CreateFrame("EditBox", "DHToolsMacrosBodyEdit", textBg)
    bodyEdit:SetMultiLine(true)
    bodyEdit:SetFontObject("ChatFontNormal")
    bodyEdit:SetPoint("TOPLEFT", 6, -6)
    bodyEdit:SetPoint("BOTTOMRIGHT", -6, 6)
    bodyEdit:SetAutoFocus(false)
    bodyEdit:SetMaxLetters(255)
    bodyEdit:SetScript("OnEscapePressed", bodyEdit.ClearFocus)

    -- Footer is two rows: buttons on top, then the Character-Specific
    -- checkbox on its own row below (Loopi 2026-08-21) - it used to share
    -- createBtn's row, anchored off the checkbox's own right edge, which
    -- put createBtn on top of the "Character-Specific" label text (the
    -- checkbox widget itself is narrow, but its label extends well past
    -- it).
    createBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    createBtn:SetSize(100, 22)
    createBtn:SetPoint("BOTTOMLEFT", 16, 48)
    createBtn:SetText("Create Macro")
    createBtn:SetScript("OnClick", function()
        ns.RequestCreateMacro(selectedEntry, charCheck:GetChecked() and true or false)
    end)

    selectBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    selectBtn:SetSize(120, 22)
    selectBtn:SetPoint("LEFT", createBtn, "RIGHT", 6, 0)
    selectBtn:SetText("Select Macro Text")
    selectBtn:SetScript("OnClick", function()
        bodyEdit:SetFocus()
        bodyEdit:HighlightText()
    end)

    local clearBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clearBtn:SetSize(100, 22)
    clearBtn:SetPoint("LEFT", selectBtn, "RIGHT", 6, 0)
    clearBtn:SetText("Clear Choices")
    clearBtn:SetScript("OnClick", ClearChoices)

    local configBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    configBtn:SetSize(70, 22)
    configBtn:SetPoint("LEFT", clearBtn, "RIGHT", 6, 0)
    configBtn:SetText("Config")
    configBtn:SetScript("OnClick", function() ns.Config_Open() end)

    local copyNote = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    copyNote:SetPoint("BOTTOMLEFT", 16, 6)
    copyNote:SetPoint("RIGHT", -16, 0)
    copyNote:SetJustifyH("LEFT")
    copyNote:SetText("\"Select Macro Text\" highlights the box above - you still need to press Ctrl+C yourself to copy it.")

    UIDropDownMenu_Initialize(classDropdown, function()
        for _, class in ipairs(ns.Library) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = class.label
            info.func = function() SelectClass(class) end
            UIDropDownMenu_AddButton(info)
        end
    end)

    UIDropDownMenu_Initialize(specDropdown, function()
        if not (selectedClass and selectedClass.specs) then return end
        local anyInfo = UIDropDownMenu_CreateInfo()
        anyInfo.text = ANY_SPEC
        anyInfo.func = function() SelectSpec(nil) end
        UIDropDownMenu_AddButton(anyInfo)
        for _, spec in ipairs(selectedClass.specs) do
            local list = selectedClass.macros[spec]
            if list and #list > 0 then
                local info = UIDropDownMenu_CreateInfo()
                info.text = spec
                info.func = function() SelectSpec(spec) end
                UIDropDownMenu_AddButton(info)
            end
        end
    end)

    UIDropDownMenu_Initialize(macroDropdown, function()
        for _, m in ipairs(GetVisibleMacros()) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = m.name
            info.func = function() SelectMacro(m) end
            UIDropDownMenu_AddButton(info)
        end
    end)

    ClearChoices()
end

function ns.Board_Toggle()
    -- Check IsShown only on a frame that already existed - a freshly
    -- CreateFrame'd frame defaults to shown (BuildFrame never calls
    -- Hide), so testing IsShown() right after creating it hid the
    -- window on the very first call instead of opening it (k-0040).
    -- Same pattern DHQuests' Board_Toggle/Board_Open and DH-Bavin's
    -- PointsEditor_Toggle/PriorityEditor_Toggle already use.
    if frame and frame:IsShown() then
        frame:Hide()
        return
    end
    if not frame then
        BuildFrame()
    end
    frame:Show()
end
