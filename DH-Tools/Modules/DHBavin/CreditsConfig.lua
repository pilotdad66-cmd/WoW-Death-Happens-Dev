-- DH-Bavin CreditsConfig.lua
-- Officer/leader-facing config window for the Credit & Reputation
-- System (see this folder's DH-Bavin-Credits-Design.md). Opened via the
-- "Open Bavin Rep & Credit Config" button in DH-Tools\Config.lua's
-- existing Bavin officer section, or "/dhb credits window" as a
-- shortcut (2026-09-25, Chris: the existing config page "should
-- basically remain the same" - just add an open button for this new
-- separate window, don't rebuild it inline).
--
-- TABS, NOT A SPREADSHEET GRID: Chris asked whether an Excel-style
-- tabs-across-the-top layout with an editable grid underneath was the
-- right call for the officer/leader UI. DH-Tools vendors no AceGUI or
-- any grid widget (see Libs\), and every existing config page in this
-- addon is hand-built Blizzard frames - a true inline-editable grid
-- would be a real UI subsystem to build from scratch (frame pooling,
-- per-cell edit boxes, tab/arrow-key focus handling). Landed on: tabs
-- across the top (matches the addon's existing feel), each tab a
-- scrollable row LIST, edits via inline add/remove controls or a short
-- confirm step rather than click-to-edit grid cells. Chris accepted
-- this approach 2026-09-25.
--
-- FOUR ACCESS TIERS (2026-09-25 design discussion with Chris - see
-- DH-Bavin-Credits-Design.md's "Access tiers" section for the full
-- writeup):
--   1. Regular member - read-only, own balance. A SEPARATE window
--      (CM6, minimap-launched), not this one - this window never opens
--      for a player who is neither a Designated Officer nor guild
--      leader/author (see CreditsConfig_Open's gate below).
--   2. Designated Officer - views everyone, resolves alt/identity
--      conflicts. CM2's job - the Roster/Conflicts tabs below are
--      placeholders until that milestone lands.
--   3. Mail recipient (Bavin) - eventually able to hand-edit the raw
--      reputation source data backing the tooltip. Deliberately NOT
--      built here - the plan is periodic reimport of a fresh data file
--      (see Step 0), not manual edits, so this is indefinitely
--      deferred. Noted so it isn't forgotten, not because it's coming
--      soon.
--   4. Guild leader + Loopi (IsAuthorAccount) - manages who holds the
--      Designated Officer role (ns.CanManageCreditsOfficers, built in
--      Credits.lua) and, unchanged on the existing Config.lua page,
--      the DH-Bavin recipient (Bavin.CanManageRecipient).
--
-- Tiers 2 and 4's Settings tab below is what CM1 actually builds today:
-- master toggle, multiplier, both Wall 2 test lists, and the
-- Designated Officers list itself (that last one further gated to tier
-- 4 within this same tab - see BuildSettingsTab's returned refresh
-- closure). Roster/Conflicts/Audit Log tabs are placeholders (CM2/CM7
-- own that data).
--
-- GATING: same refuse-outright-on-open philosophy as PointsEditor.lua/
-- PriorityEditor.lua - if the caller can neither manage credits config
-- locally (any Designated Officer, or the author account) nor manage
-- the officers list (guild leader, or the author account), the window
-- never opens. Closing is always allowed.

local DHTools = DHTools
local ns = DHTools.Bavin

local frame
local tabs = {}
local activeTabKey = "settings"

--------------------------------------------------------------------------
-- Shared roster-suggestion pool - ported from DH-Tools\Config.lua's
-- BuildSuggestPool/PopulateSuggestions (same ~1000-member-guild lesson
-- learned there: filter on the Lua side, cheap even at guild scale,
-- and only ever materialize a couple of real button frames, not one
-- per roster member). Reused across all three name-entry fields below
-- (officers, test receivers, test senders) via CreateNameListSection.
--------------------------------------------------------------------------
local SUGGEST_ROWS = 3

local function BuildSuggestPool(parent, anchor)
    local buttons = {}
    local prevAnchor = anchor
    for i = 1, SUGGEST_ROWS do
        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(220, 16)
        if i == 1 then
            btn:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 4, -4)
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

local function PopulateSuggestions(buttons, typed, onPick)
    typed = (typed or ""):lower()
    local shown = 0
    if typed ~= "" and ns.GetRosterNames then
        for _, name in ipairs(ns.GetRosterNames()) do
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

--------------------------------------------------------------------------
-- Add-by-name / removable-list section factory
--------------------------------------------------------------------------
-- Officers, test receivers, and test senders are three structurally
-- identical sections (title + one-line hint + add-by-name field +
-- suggestion pool + a small removable list) that differ only in which
-- list/setter they drive and which permission gates them - factored
-- into one builder instead of three near-duplicate blocks.
--
-- FULLY DYNAMIC POSITIONING (2026-09-25, Chris: "the rows should be
-- dynamic and expand only as the list grows" - the whole window had a
-- fixed 8-row gap reserved after every list regardless of how many
-- entries it actually held, since Hide()ing an empty row doesn't
-- collapse its anchor chain). `topAnchorFn` is a FUNCTION, not a static
-- frame - called fresh every Refresh so this section moves up/down to
-- sit right after whatever the PREVIOUS section's current bottom
-- actually is. `sec.GetBottomAnchor()` is this section's own live
-- bottom (its last visible row, or its "Current:" label if the list is
-- empty) for the NEXT section to chain off the same way. Sections must
-- Refresh() in top-to-bottom order (see BuildSettingsTab) so each one
-- repositions against an already-updated predecessor.
local function CreateNameListSection(parent, topAnchorFn, opts)
    local sec = {}

    sec.title = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sec.title:SetText(opts.title)

    -- Plain-language explanation (2026-09-25, Chris: "no real
    -- explanation") - the title alone ("Test Receivers (inbox hook)")
    -- wasn't enough context for what adding a name here actually does.
    sec.hint = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sec.hint:SetPoint("TOPLEFT", sec.title, "BOTTOMLEFT", 0, -4)
    sec.hint:SetPoint("RIGHT", -16, 0)
    sec.hint:SetJustifyH("LEFT")
    sec.hint:SetWordWrap(true)
    sec.hint:SetText(opts.hint or "")

    sec.addLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sec.addLabel:SetPoint("TOPLEFT", sec.hint, "BOTTOMLEFT", 0, -8)
    sec.addLabel:SetText("Add:")

    sec.addEdit = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    sec.addEdit:SetSize(140, 20)
    sec.addEdit:SetPoint("LEFT", sec.addLabel, "RIGHT", 8, -2)
    sec.addEdit:SetAutoFocus(false)
    sec.addEdit:SetMaxLetters(24)
    sec.addEdit:SetScript("OnEscapePressed", sec.addEdit.ClearFocus)

    sec.addBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    sec.addBtn:SetSize(50, 20)
    sec.addBtn:SetText("Add")
    sec.addBtn:SetPoint("LEFT", sec.addEdit, "RIGHT", 6, 0)

    sec.status = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sec.status:SetPoint("LEFT", sec.addBtn, "RIGHT", 8, 0)

    sec.lockedNote = parent:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    sec.lockedNote:SetPoint("LEFT", sec.title, "RIGHT", 10, 0)
    sec.lockedNote:SetText(opts.lockedText or "|cffff3333Read-only.|r")
    sec.lockedNote:Hide()

    sec.suggestButtons = BuildSuggestPool(parent, sec.addLabel)

    local function UpdateSuggestions(typed)
        PopulateSuggestions(sec.suggestButtons, typed, function(name)
            sec.addEdit:SetText(name)
            sec.addEdit:ClearFocus()
            PopulateSuggestions(sec.suggestButtons, "", function() end)
        end)
    end
    sec.addEdit:SetScript("OnTextChanged", function(self) UpdateSuggestions(self:GetText()) end)

    local function TryAdd()
        local typed = sec.addEdit:GetText()
        sec.addEdit:ClearFocus()
        UpdateSuggestions("")
        if typed == "" then return end
        if opts.addFn(typed) then
            sec.addEdit:SetText("")
            sec.status:SetText("|cff33ff99Added!|r")
            C_Timer.After(2, function() sec.status:SetText("") end)
            -- Full window refresh, not just sec.Refresh() - a list-length
            -- change here must cascade to reposition every section below
            -- this one too (see file header).
            ns.CreditsConfig_Refresh()
        else
            sec.status:SetText("|cffff3333Refused|r")
        end
    end
    sec.addBtn:SetScript("OnClick", TryAdd)
    sec.addEdit:SetScript("OnEnterPressed", TryAdd)

    sec.listTitle = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sec.listTitle:SetPoint("TOPLEFT", sec.suggestButtons[SUGGEST_ROWS], "BOTTOMLEFT", -8, -10)
    sec.listTitle:SetText("Current:")

    sec.rows = {}
    local prevRowAnchor = sec.listTitle
    for i = 1, opts.rowCount do
        local row = CreateFrame("Frame", nil, parent)
        row:SetSize(300, 18)
        if i == 1 then
            row:SetPoint("TOPLEFT", prevRowAnchor, "BOTTOMLEFT", 8, -4)
        else
            row:SetPoint("TOPLEFT", prevRowAnchor, "BOTTOMLEFT", 0, -2)
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
        sec.rows[i] = row
        prevRowAnchor = row
    end

    -- Live, not computed once (that was the bug) - walks backward from
    -- the row pool's end to find the last actually-visible row.
    function sec.GetBottomAnchor()
        for i = #sec.rows, 1, -1 do
            if sec.rows[i]:IsShown() then return sec.rows[i] end
        end
        return sec.listTitle
    end

    sec.Refresh = function()
        sec.title:ClearAllPoints()
        sec.title:SetPoint("TOPLEFT", topAnchorFn(), "BOTTOMLEFT", 0, -16)

        local canManage = opts.canManageFn()
        local list = opts.getList()
        sec.lockedNote:SetShown(not canManage)
        if canManage then
            sec.addEdit:Enable()
            sec.addBtn:Enable()
        else
            sec.addEdit:Disable()
            sec.addBtn:Disable()
        end
        for i, row in ipairs(sec.rows) do
            local name = list[i]
            if not name then
                row:Hide()
            else
                row:Show()
                row.text:SetText(name)
                row.removeBtn:SetScript("OnClick", function()
                    if opts.removeFn(name) then ns.CreditsConfig_Refresh() end
                end)
                if canManage then
                    row.removeBtn:Enable()
                else
                    row.removeBtn:Disable()
                end
            end
        end
    end

    return sec
end

--------------------------------------------------------------------------
-- Settings tab - CM1's actual deliverable. Wires directly to the
-- setters Credits.lua already built and permission-checks internally
-- (SetCreditsMasterToggle, SetCreditsMultiplier, AddCreditTestReceiver/
-- RemoveCreditTestReceiver, AddCreditTestSender/RemoveCreditTestSender,
-- SetCreditsOfficers) - this file adds no new permission logic of its
-- own, only UI on top of what's already gated. Returns a refresh
-- closure the outer frame calls on open/tab-switch/incoming sync.
--------------------------------------------------------------------------
local function BuildSettingsTab(content)
    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Settings")

    local hint = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Master toggle, credit multiplier, and both Wall 2 test lists are any Designated Officer. The Designated Officers list itself is guild leader/author only.")

    local statusText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
    statusText:SetPoint("RIGHT", -16, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetWordWrap(true)

    local toggleCheck = CreateFrame("CheckButton", "DHBavinCreditsToggleCheck", content, "UICheckButtonTemplate")
    toggleCheck:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", -2, -12)
    _G[toggleCheck:GetName() .. "Text"]:SetText("Master toggle (enables the test mail hooks - Wall 3)")
    toggleCheck:SetScript("OnClick", function(self)
        local wanted = self:GetChecked() and true or false
        if not ns.SetCreditsMasterToggle(wanted) then
            self:SetChecked(not wanted)
        end
        ns.CreditsConfig_Refresh()
    end)

    local multLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    multLabel:SetPoint("TOPLEFT", toggleCheck, "BOTTOMLEFT", 2, -16)
    multLabel:SetText("Multiplier (credits per point):")

    local multEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    multEdit:SetSize(60, 20)
    multEdit:SetPoint("LEFT", multLabel, "RIGHT", 8, -2)
    multEdit:SetAutoFocus(false)
    multEdit:SetMaxLetters(8)
    multEdit:SetScript("OnEscapePressed", multEdit.ClearFocus)

    local multBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    multBtn:SetSize(50, 20)
    multBtn:SetText("Set")
    multBtn:SetPoint("LEFT", multEdit, "RIGHT", 6, 0)

    local multStatus = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    multStatus:SetPoint("LEFT", multBtn, "RIGHT", 8, 0)

    local function TrySetMultiplier()
        local typed = multEdit:GetText()
        multEdit:ClearFocus()
        if ns.SetCreditsMultiplier(typed) then
            multStatus:SetText("|cff33ff99Set!|r")
            C_Timer.After(2, function() multStatus:SetText("") end)
            ns.CreditsConfig_Refresh()
        else
            multStatus:SetText("|cffff3333Refused|r")
        end
    end
    multBtn:SetScript("OnClick", TrySetMultiplier)
    multEdit:SetScript("OnEnterPressed", TrySetMultiplier)

    local officers = CreateNameListSection(content, function() return multLabel end, {
        title = "Designated Officers",
        hint = "Guild leader/author only can add or remove names here. Anyone listed gets full access to the rest of this Settings tab (toggle, multiplier, both test lists below).",
        getList = function() return (ns.creditsDb and ns.creditsDb.officers) or {} end,
        addFn = function(name)
            if not ns.CanManageCreditsOfficers() then return false end
            local norm = ns.NormalizeName(name)
            for _, n in ipairs(ns.creditsDb.officers) do
                if ns.NormalizeName(n) == norm then return false end -- already present
            end
            local list = {}
            for _, n in ipairs(ns.creditsDb.officers) do table.insert(list, n) end
            table.insert(list, name)
            return ns.SetCreditsOfficers(list)
        end,
        removeFn = function(name)
            if not ns.CanManageCreditsOfficers() then return false end
            local norm = ns.NormalizeName(name)
            local list = {}
            for _, n in ipairs(ns.creditsDb.officers) do
                if ns.NormalizeName(n) ~= norm then table.insert(list, n) end
            end
            return ns.SetCreditsOfficers(list)
        end,
        canManageFn = ns.CanManageCreditsOfficers,
        rowCount = 8,
        lockedText = "|cffff3333Guild leader/author only.|r",
    })

    local receivers = CreateNameListSection(content, officers.GetBottomAnchor, {
        title = "Test Receivers (inbox hook - Wall 2)",
        hint = "Characters listed here get the TEST inbox-mail credit hook turned on for them once logged in, but only while the master toggle above is ON. Isolated from the live donation flow - safe to experiment with.",
        getList = function() return (ns.creditsDb and ns.creditsDb.creditTestReceivers) or {} end,
        addFn = ns.AddCreditTestReceiver,
        removeFn = ns.RemoveCreditTestReceiver,
        canManageFn = ns.CanManageCreditsConfigLocal,
        rowCount = 8,
        lockedText = "|cffff3333Designated Officer/author only.|r",
    })

    local senders = CreateNameListSection(content, receivers.GetBottomAnchor, {
        title = "Test Senders (outgoing hook - Wall 2)",
        hint = "Characters listed here get the TEST outgoing-mail credit hook turned on for them once logged in, but only while the master toggle above is ON. Isolated from the live donation flow - safe to experiment with.",
        getList = function() return (ns.creditsDb and ns.creditsDb.creditTestSenders) or {} end,
        addFn = ns.AddCreditTestSender,
        removeFn = ns.RemoveCreditTestSender,
        canManageFn = ns.CanManageCreditsConfigLocal,
        rowCount = 8,
        lockedText = "|cffff3333Designated Officer/author only.|r",
    })

    -- Two-click confirm (mirrors the slash command's "reset confirm"
    -- arg) rather than a text-typed confirmation - lower-friction in a
    -- mouse-driven window, same safety property (can't fire by
    -- accident on a single misclick).
    local resetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    resetBtn:SetSize(170, 22)
    -- Position set dynamically each refresh (below), same reason as
    -- every section's title - senders' actual bottom moves as its list
    -- grows or shrinks.
    resetBtn:SetText("Reset Test Data")

    local resetStatus = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    resetStatus:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)

    local resetArmed = false
    local resetArmedTimer

    local function DisarmReset()
        resetArmed = false
        resetBtn:SetText("Reset Test Data")
        resetStatus:SetText("")
    end

    resetBtn:SetScript("OnClick", function()
        if not resetArmed then
            resetArmed = true
            resetBtn:SetText("Click again to confirm")
            resetStatus:SetText("|cffffcc00Wipes ledger/alt overrides/transaction log|r")
            if resetArmedTimer then resetArmedTimer:Cancel() end
            resetArmedTimer = C_Timer.NewTimer(6, DisarmReset)
            return
        end
        if resetArmedTimer then resetArmedTimer:Cancel() end
        DisarmReset()
        if ns.Credits_ResetTestData() then
            resetStatus:SetText("|cff33ff99Wiped.|r")
            C_Timer.After(2, function() resetStatus:SetText("") end)
        else
            resetStatus:SetText("|cffff3333Refused|r")
        end
    end)

    return function()
        if not ns.creditsDb then
            statusText:SetText("Not initialized yet.")
            return
        end
        statusText:SetText(("Master toggle: %s   |   This character armed: inbox=%s outgoing=%s"):format(
            ns.creditsDb.masterToggle and "|cff33ff33ON|r" or "|cffff3333OFF|r",
            tostring(ns.creditsArmedInbox), tostring(ns.creditsArmedOutgoing)))

        toggleCheck:SetChecked(ns.creditsDb.masterToggle)
        if not multEdit:HasFocus() then
            multEdit:SetText(tostring(ns.creditsDb.multiplier))
        end

        local canConfig = ns.CanManageCreditsConfigLocal()
        if canConfig then
            toggleCheck:Enable()
            multEdit:Enable()
            multBtn:Enable()
        else
            toggleCheck:Disable()
            multEdit:Disable()
            multBtn:Disable()
        end

        officers.Refresh()
        receivers.Refresh()
        senders.Refresh()

        resetBtn:ClearAllPoints()
        resetBtn:SetPoint("TOPLEFT", senders.GetBottomAnchor(), "BOTTOMLEFT", -8, -20)

        -- Shrink the scroll content to fit what's actually laid out
        -- (2026-09-25, Chris: "too much wasted space") - GetTop/GetBottom
        -- are nil until the frame has actually rendered once, hence the
        -- guard; falls back to leaving the generous fixed estimate alone.
        local top, bottom = content:GetTop(), resetStatus:GetBottom()
        if top and bottom then
            content:SetHeight(math.max(200, top - bottom + 20))
        end
    end
end

--------------------------------------------------------------------------
-- Placeholder tabs - Roster/Conflicts/Audit Log own no real data yet
-- (CM2/CM7). The shell exists now so those milestones fill in a tab
-- rather than re-architecting the window later.
--------------------------------------------------------------------------
local function BuildPlaceholderTab(content, titleText, message)
    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(titleText)

    local msg = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    msg:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    msg:SetPoint("RIGHT", -16, 0)
    msg:SetJustifyH("LEFT")
    msg:SetWordWrap(true)
    msg:SetText(message)
end

--------------------------------------------------------------------------
-- Frame construction (built once, first time the window is opened)
--------------------------------------------------------------------------
local TAB_DEFS = {
    { key = "settings",  label = "Settings" },
    { key = "roster",    label = "Roster" },
    { key = "conflicts", label = "Conflicts" },
    { key = "audit",     label = "Audit Log" },
}

local function CreateWindow()
    frame = CreateFrame("Frame", "DHBavinCreditsConfigFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(480, 620)
    frame:SetPoint("CENTER")
    if frame.TitleText then
        frame.TitleText:SetText("Bavin Rep & Credit Config")
    end
    tinsert(UISpecialFrames, "DHBavinCreditsConfigFrame")

    DHTools.InitStandaloneWindow(frame)

    -- 2026-09-25 (Chris: "should open on top of the bavin config, not
    -- below it") - DHToolsConfigFrame (Config.lua, where this window is
    -- opened FROM) is also toplevel at the default "MEDIUM" strata, so
    -- z-order between the two otherwise depends on click/raise history,
    -- not on which one is "supposed" to be on top. Bumping this one
    -- explicit strata higher makes it always win, independent of that
    -- history.
    frame:SetFrameStrata("HIGH")

    -- Resizable (2026-09-25, Chris) - same grip/bounds idiom as
    -- PriorityEditor.lua and DH-Tools\Config.lua's own window.
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        pcall(frame.SetResizeBounds, frame, 420, 400, 720, 900)
    else
        pcall(frame.SetMinResize, frame, 420, 400)
        pcall(frame.SetMaxResize, frame, 720, 900)
    end

    local resizeGrip = CreateFrame("Button", nil, frame)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetPoint("BOTTOMRIGHT", -4, 4)
    resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeGrip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    resizeGrip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

    frame:SetScript("OnSizeChanged", function()
        if frame:IsShown() then ns.CreditsConfig_Refresh() end
    end)

    -- Tab bar, plain UIPanelButtonTemplate buttons (see file header for
    -- why - no grid/tab widget is vendored). The active tab's button is
    -- Disable()'d rather than given a custom highlight texture - a
    -- grayed-out look reads as "you are here" well enough, and it's
    -- zero extra art/state to maintain.
    local tabBar = CreateFrame("Frame", nil, frame)
    tabBar:SetPoint("TOPLEFT", 8, -30)
    tabBar:SetPoint("TOPRIGHT", -8, -30)
    tabBar:SetHeight(24)

    local prevTabAnchor
    for _, def in ipairs(TAB_DEFS) do
        local btn = CreateFrame("Button", nil, tabBar, "UIPanelButtonTemplate")
        btn:SetSize(102, 22)
        if prevTabAnchor then
            btn:SetPoint("LEFT", prevTabAnchor, "RIGHT", 4, 0)
        else
            btn:SetPoint("LEFT", tabBar, "LEFT", 0, 0)
        end
        btn:SetText(def.label)
        btn:SetScript("OnClick", function() ns.CreditsConfig_SelectTab(def.key) end)
        tabs[def.key] = { button = btn }
        prevTabAnchor = btn
    end

    -- One ScrollFrame reused by whichever tab is active - each tab gets
    -- its own scroll CHILD frame, so switching tabs is just a
    -- SetScrollChild swap, not a rebuild.
    local scrollFrame = CreateFrame("ScrollFrame", "DHBavinCreditsConfigScroll", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 12)
    frame.scrollFrame = scrollFrame

    -- 2026-09-25 (Chris: "closing the window leaves a bunch of text
    -- behind"): each tab's content frame is its own sibling under
    -- scrollFrame, but SetScrollChild only ever manages ONE of them at a
    -- time - the other three never get an explicit anchor point (only
    -- the current scroll child is auto-positioned) and were never
    -- explicitly Hidden, so they could render unanchored/overlapping
    -- instead of cleanly disappearing. Fix: give every content frame its
    -- own real TOPLEFT anchor up front, and have CreditsConfig_SelectTab
    -- explicitly Show the active one and Hide the rest (below).
    local settingsContent = CreateFrame("Frame", nil, scrollFrame)
    settingsContent:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, 0)
    -- Generous fixed estimate (title/hint/status + toggle + multiplier +
    -- three 8-row name-list sections + reset button) - trimmed down to
    -- the real content height on every refresh now (see BuildSettingsTab's
    -- returned closure), this is just the pre-first-refresh fallback.
    settingsContent:SetSize(1, 900)
    tabs.settings.refresh = BuildSettingsTab(settingsContent)
    tabs.settings.content = settingsContent

    local rosterContent = CreateFrame("Frame", nil, scrollFrame)
    rosterContent:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, 0)
    rosterContent:SetSize(1, 140)
    BuildPlaceholderTab(rosterContent, "Roster", "Available once CM2 seeds the ledger from Step 0's reconciled data (seed-dataset.csv - 651 mains). Will list every member's points, credits, tier, and prestige.")
    tabs.roster.content = rosterContent

    local conflictsContent = CreateFrame("Frame", nil, scrollFrame)
    conflictsContent:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, 0)
    conflictsContent:SetSize(1, 140)
    BuildPlaceholderTab(conflictsContent, "Conflicts", "Available once CM2's alt-identity view/edit UI lands. Designated Officers will resolve identity conflicts here (currently: 1 conflict and 1129 unmapped donor names in review-queue.csv from Step 0).")
    tabs.conflicts.content = conflictsContent

    local auditContent = CreateFrame("Frame", nil, scrollFrame)
    auditContent:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, 0)
    auditContent:SetSize(1, 140)
    BuildPlaceholderTab(auditContent, "Audit Log", "Available once CM7 lands: full transaction log (Processor view), a \"what I sent\" filter for Designated Officers, and members' own last-50 view.")
    tabs.audit.content = auditContent

    ns.CreditsConfig_SelectTab("settings")
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------
function ns.CreditsConfig_SelectTab(key)
    if not frame or not tabs[key] then return end
    activeTabKey = key
    for k, t in pairs(tabs) do
        if k == key then
            t.button:Disable()
            if t.content then t.content:Show() end
        else
            t.button:Enable()
            -- Explicit Hide, not just "not the scroll child" - see the
            -- construction-time comment above these frames for why.
            if t.content then t.content:Hide() end
        end
    end
    frame.scrollFrame:SetScrollChild(tabs[key].content)
    frame.scrollFrame:SetVerticalScroll(0)
    ns.CreditsConfig_Refresh()
end

-- Safe to call whether or not the window has ever been opened - see
-- Credits.lua's ApplyIncomingConfig, which calls this unconditionally
-- (guarded there) whenever a synced config change lands, so an open
-- window reflects another officer's change without needing a manual
-- close/reopen.
function ns.CreditsConfig_Refresh()
    if not frame or not frame:IsShown() then return end
    local content = tabs[activeTabKey] and tabs[activeTabKey].content
    if content then
        content:SetWidth(math.max(1, frame.scrollFrame:GetWidth() - 24))
    end
    if activeTabKey == "settings" and tabs.settings.refresh then
        tabs.settings.refresh()
    end
end

-- Refuses outright (no frame created/shown) unless the caller can
-- either manage credits config locally (any Designated Officer, or the
-- author account) or manage the officers list (guild leader, or the
-- author account) - same gating philosophy as PointsEditor.lua/
-- PriorityEditor.lua's CanEditList checks.
function ns.CreditsConfig_Open()
    if not (ns.CanManageCreditsConfigLocal() or ns.CanManageCreditsOfficers()) then
        ns.Print("Only a Designated Officer, the guild leader, or the author account can open Bavin Rep & Credit Config.")
        return
    end
    if not frame then
        CreateWindow()
    end
    frame:Show()
    ns.CreditsConfig_SelectTab(activeTabKey)
end

-- Closing is always allowed regardless of permission - only opening is
-- gated (see CreditsConfig_Open).
function ns.CreditsConfig_Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
        return
    end
    ns.CreditsConfig_Open()
end
