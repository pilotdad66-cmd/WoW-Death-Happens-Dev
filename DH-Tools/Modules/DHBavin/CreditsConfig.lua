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
-- Roster tab (CM2, 2026-09-25) - read-only view of the seeded ledger
-- plus the officer-gated "Seed from Historical Data" trigger
-- (ns.CreditsSeed_Import, CreditsSeed.lua). Same two-click confirm
-- idiom as Settings tab's Reset Test Data button - seeding overwrites
-- any existing ledger row for every name in SeedData.lua, so it's not
-- a no-consequence click. Conflicts/Audit Log stay placeholders (CM2's
-- alt-identity UI, CM7) - this tab is read-only, no per-row editing.
--------------------------------------------------------------------------
local function BuildRosterTab(content)
    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Roster")

    local hint = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Every main's seeded reputation/credit standing. Rank is always by Lifetime Points, regardless of the active sort. Click a column title (Name/Lifetime/Last Donation) to sort by it - click again to flip direction. Click a name marked [+] to show its alts. Seeding is Designated Officer/author only; re-running it overwrites the row for any name in the historical data (SeedData.lua) without touching rows for names outside that dataset.")

    -- Seed button - two-click confirm, mirrors Settings tab's Reset Test Data.
    local seedBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    seedBtn:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", -2, -12)
    seedBtn:SetSize(180, 22)
    seedBtn:SetText("Seed from Historical Data")

    local seedStatus = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    seedStatus:SetPoint("LEFT", seedBtn, "RIGHT", 8, 0)

    local seedArmed = false
    local seedArmedTimer
    local function DisarmSeed()
        seedArmed = false
        seedBtn:SetText("Seed from Historical Data")
        seedStatus:SetText("")
    end
    seedBtn:SetScript("OnClick", function()
        if not seedArmed then
            seedArmed = true
            seedBtn:SetText("Click again to confirm")
            seedStatus:SetText("|cffffcc00Overwrites matching ledger rows|r")
            if seedArmedTimer then seedArmedTimer:Cancel() end
            seedArmedTimer = C_Timer.NewTimer(6, DisarmSeed)
            return
        end
        if seedArmedTimer then seedArmedTimer:Cancel() end
        DisarmSeed()
        if not ns.CreditsSeed_Import then
            seedStatus:SetText("|cffff3333CreditsSeed.lua not loaded|r")
            return
        end
        local ok, count = ns.CreditsSeed_Import()
        if ok then
            seedStatus:SetText(("|cff33ff99Seeded %d.|r"):format(count or 0))
            C_Timer.After(3, function() seedStatus:SetText("") end)
            ns.CreditsConfig_Refresh()
        else
            seedStatus:SetText("|cffff3333Refused|r")
        end
    end)

    -- Sorting lives on the column headers themselves (2026-09-25, Chris:
    -- "activated by clicking on the column title, not by a separate
    -- box"). No page controls - the tab's outer ScrollFrame already
    -- handles a tall list (2026-09-25, Chris: "just one scrollable
    -- list"), so the row pool below simply grows to fit.
    local sortState = { key = "mainName", ascending = true }
    local expanded = {}   -- mainName -> true when its alts are shown

    -- Column header line - fixed x-offsets matching each row's
    -- FontStrings below, sized to fit the window's default ~480px
    -- frame width (no monospace font, so alignment is offset-based,
    -- not padded text). Name/Lifetime/Last Donation are clickable
    -- Buttons (sortable); Rank/Tier/Points/Credits are plain
    -- FontStrings (Tier/Points aren't sortable - both derive from
    -- Lifetime, so sorting by Lifetime already orders them; Rank is
    -- deliberately never sortable - it's always lifetime-based
    -- regardless of the active sort, see RankMap() below). Tier folds
    -- Prestige into its own text ("Exalted P1") instead of a separate
    -- column, and Points shows "current/cap" for the main's tier
    -- (2026-09-25, Chris). Lifetime widened 2026-09-25 (Chris: header
    -- text was clipping against the Last Donation column).
    local headerRow = CreateFrame("Frame", nil, content)
    headerRow:SetPoint("TOPLEFT", seedBtn, "BOTTOMLEFT", -2, -14)
    headerRow:SetSize(1, 16)

    local function PlainHeader(text, xOffset)
        local fs = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", xOffset, 0)
        fs:SetText(text)
    end

    -- Sortable header: a borderless Button (not UIPanelButtonTemplate -
    -- this needs to look like a column title, not a button) with a
    -- HIGHLIGHT texture for hover feedback and a label this file's
    -- Refresh() rewrites with a v/^ arrow when that column is the
    -- active sort.
    local function SortableHeader(text, xOffset, width, sortKey)
        local btn = CreateFrame("Button", nil, headerRow)
        btn:SetPoint("LEFT", xOffset, 0)
        btn:SetSize(width, 16)
        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetAllPoints()
        label:SetJustifyH("LEFT")
        btn.label = label
        btn.baseText = text
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.15)
        return btn
    end

    PlainHeader("Rank", 0)
    local nameHeader = SortableHeader("Name", 30, 76, "mainName")
    PlainHeader("Tier", 110)
    PlainHeader("Points", 190)
    local lifetimeHeader = SortableHeader("Lifetime", 270, 60, "lifetimePoints")
    local lastDonationHeader = SortableHeader("Last Donation", 334, 86, "lastDonationDate")
    PlainHeader("Credits", 424)

    -- Row pool grows on demand (EnsureRowCount) instead of a fixed
    -- page size - each display entry is either a main (full row, with
    -- a clickable Name for expand/collapse when it has alts) or an alt
    -- sub-row (indented Name only, other cells blank). Rows are never
    -- destroyed, only hidden, so the TOPLEFT->BOTTOMLEFT anchor chain
    -- built at creation time stays valid across refreshes.
    local rows = {}
    local Refresh   -- forward-declared: row click handlers call it

    local function EnsureRowCount(n)
        for i = #rows + 1, n do
            local prevAnchor = rows[i - 1] or headerRow
            local row = CreateFrame("Frame", nil, content)
            row:SetSize(1, 16)
            if i == 1 then
                row:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, -4)
            else
                row:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, -2)
            end

            local nameBtn = CreateFrame("Button", nil, row)
            nameBtn:SetPoint("LEFT", 30, 0)
            nameBtn:SetSize(76, 16)
            local nameLabel = nameBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            nameLabel:SetAllPoints()
            nameLabel:SetJustifyH("LEFT")
            nameBtn.label = nameLabel
            local nameHl = nameBtn:CreateTexture(nil, "HIGHLIGHT")
            nameHl:SetAllPoints()
            nameHl:SetColorTexture(1, 1, 1, 0.15)
            nameBtn:SetScript("OnClick", function()
                if row.isExpandable and row.currentMain then
                    expanded[row.currentMain] = not expanded[row.currentMain]
                    if Refresh then Refresh() end
                end
            end)
            row.nameBtn = nameBtn

            local function Cell(xOffset, width)
                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetPoint("LEFT", xOffset, 0)
                fs:SetWidth(width)
                fs:SetJustifyH("LEFT")
                return fs
            end
            row.rank = Cell(0, 26)
            row.tier = Cell(110, 76)
            row.points = Cell(190, 76)
            row.lifetime = Cell(270, 60)
            row.lastDonation = Cell(334, 86)
            row.credits = Cell(424, 32)
            row:Hide()
            rows[i] = row
        end
    end

    local function GetBottomAnchor()
        for i = #rows, 1, -1 do
            if rows[i]:IsShown() then return rows[i] end
        end
        return headerRow
    end

    local function SortedLedger()
        local list = {}
        if ns.creditsDb and ns.creditsDb.ledger then
            for _, rec in pairs(ns.creditsDb.ledger) do
                table.insert(list, rec)
            end
        end
        table.sort(list, function(a, b)
            local av, bv
            if sortState.key == "lifetimePoints" then
                av, bv = a.lifetimePoints or 0, b.lifetimePoints or 0
            elseif sortState.key == "lastDonationDate" then
                av, bv = a.lastDonationDate or "", b.lastDonationDate or ""
            else
                av, bv = (a.mainName or ""):lower(), (b.mainName or ""):lower()
            end
            if av ~= bv then
                if sortState.ascending then return av < bv else return av > bv end
            end
            return (a.mainName or "") < (b.mainName or "")
        end)
        return list
    end

    -- Rank is always by Lifetime Points descending, regardless of the
    -- column currently driving the sort (2026-09-25, Chris: "based on
    -- lifetime points total regardless of sort order"). Computed fresh
    -- each Refresh() rather than reusing SortedLedger()'s order, which
    -- can be sorted by Name or Last Donation instead.
    local function RankMap()
        local list = {}
        if ns.creditsDb and ns.creditsDb.ledger then
            for _, rec in pairs(ns.creditsDb.ledger) do
                table.insert(list, rec)
            end
        end
        table.sort(list, function(a, b)
            local av, bv = a.lifetimePoints or 0, b.lifetimePoints or 0
            if av ~= bv then return av > bv end
            return (a.mainName or "") < (b.mainName or "")
        end)
        local ranks = {}
        for i, rec in ipairs(list) do
            ranks[rec.mainName] = i
        end
        return ranks
    end

    -- Interleaves each main with its alt sub-rows (only when expanded)
    -- into a single flat list the row pool renders in order.
    local function BuildDisplayList()
        local mains = SortedLedger()
        local display = {}
        for _, rec in ipairs(mains) do
            local alts = ns.CreditsAltRoster and ns.CreditsAltRoster[rec.mainName]
            local hasAlts = alts ~= nil and #alts > 0
            table.insert(display, { kind = "main", rec = rec, hasAlts = hasAlts })
            if hasAlts and expanded[rec.mainName] then
                for _, altName in ipairs(alts) do
                    table.insert(display, { kind = "alt", name = altName })
                end
            end
        end
        return display, #mains
    end

    Refresh = function()
        local function HeaderText(btn, key)
            if sortState.key == key then
                btn.label:SetText(btn.baseText .. (sortState.ascending and " v" or " ^"))
            else
                btn.label:SetText(btn.baseText)
            end
        end
        HeaderText(nameHeader, "mainName")
        HeaderText(lifetimeHeader, "lifetimePoints")
        HeaderText(lastDonationHeader, "lastDonationDate")

        if not ns.creditsDb then
            for _, row in ipairs(rows) do row:Hide() end
            return
        end

        local display = BuildDisplayList()
        local ranks = RankMap()
        EnsureRowCount(#display)
        for i, row in ipairs(rows) do
            local entry = display[i]
            if not entry then
                row:Hide()
            else
                row:Show()
                if entry.kind == "main" then
                    local rec = entry.rec
                    row.isExpandable = entry.hasAlts
                    row.currentMain = rec.mainName
                    row.rank:SetText(tostring(ranks[rec.mainName] or "?"))
                    local marker = entry.hasAlts and (expanded[rec.mainName] and "[-] " or "[+] ") or "      "
                    row.nameBtn.label:SetText(marker .. (rec.mainName or "?"))
                    row.nameBtn:EnableMouse(entry.hasAlts)
                    local tierText = rec.tier or "?"
                    if (rec.prestige or 0) > 0 then
                        tierText = tierText .. " P" .. tostring(rec.prestige)
                    end
                    row.tier:SetText(tierText)
                    local cap = ns.CreditsTierCaps and ns.CreditsTierCaps[rec.tier]
                    local curPts = math.floor((rec.points or 0) + 0.5)
                    if cap then
                        row.points:SetText(("%d/%d"):format(curPts, cap))
                    else
                        row.points:SetText(tostring(curPts))
                    end
                    row.lifetime:SetText(tostring(math.floor((rec.lifetimePoints or 0) + 0.5)))
                    row.lastDonation:SetText((rec.lastDonationDate and rec.lastDonationDate ~= "") and rec.lastDonationDate or "-")
                    row.credits:SetText(tostring(rec.credits or 0))
                else
                    row.isExpandable = false
                    row.currentMain = nil
                    row.rank:SetText("")
                    row.nameBtn.label:SetText("      - " .. (entry.name or "?"))
                    row.nameBtn:EnableMouse(false)
                    row.tier:SetText("")
                    row.points:SetText("")
                    row.lifetime:SetText("")
                    row.lastDonation:SetText("")
                    row.credits:SetText("")
                end
            end
        end

        local bottom = GetBottomAnchor()
        local top, bot = content:GetTop(), bottom:GetBottom()
        if top and bot then
            content:SetHeight(math.max(200, top - bot + 20))
        end
    end

    local function SetSort(key, defaultAscending)
        if sortState.key == key then
            sortState.ascending = not sortState.ascending
        else
            sortState.key = key
            sortState.ascending = defaultAscending
        end
        Refresh()
    end
    nameHeader:SetScript("OnClick", function() SetSort("mainName", true) end)
    lifetimeHeader:SetScript("OnClick", function() SetSort("lifetimePoints", false) end)
    lastDonationHeader:SetScript("OnClick", function() SetSort("lastDonationDate", false) end)

    return Refresh
end

--------------------------------------------------------------------------
-- Conflicts tab (CM2, 2026-09-25) - Step 0's unresolved/ambiguous donor
-- names (ReviewQueue.lua, GENERATED from review-queue.csv), sortable by
-- Name and by Latest Donation date (Chris, 2026-09-25 - asked for this
-- on "the unresolved donators list"), filterable by typed substring,
-- with a per-row manual-link control that writes straight to the live
-- altOverrides table (ns.Credits_SetAltOverride/RemoveAltOverride,
-- Credits.lua). This list itself is static reference data - linking a
-- row doesn't remove it here, it just shows the row as resolved; the
-- list only shrinks on the next Step 0 + import-review-queue.ps1 pass.
--------------------------------------------------------------------------
local function BuildConflictsTab(content)
    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Conflicts")

    local hint = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Donor names Step 0 couldn't map to a main, as of its last run (see review-queue.csv). Linking or setting as a new main here is Designated Officer/author only and takes effect immediately for live crediting - it doesn't shrink this list, which only refreshes on the next Step 0 pass. \"New Main\" seeds the row's real historical lifetime total (raw gold x10, same convention as everywhere else).")

    local filterLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterLabel:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", -2, -12)
    filterLabel:SetText("Filter:")

    local filterEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    filterEdit:SetSize(140, 20)
    filterEdit:SetPoint("LEFT", filterLabel, "RIGHT", 8, -2)
    filterEdit:SetAutoFocus(false)
    filterEdit:SetMaxLetters(24)
    filterEdit:SetScript("OnEscapePressed", filterEdit.ClearFocus)

    local sortState = { key = "name", ascending = true }

    local sortNameBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    sortNameBtn:SetPoint("TOPLEFT", filterLabel, "BOTTOMLEFT", 2, -12)
    sortNameBtn:SetSize(100, 20)

    local sortDateBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    sortDateBtn:SetPoint("LEFT", sortNameBtn, "RIGHT", 6, 0)
    sortDateBtn:SetSize(150, 20)

    -- Pagination REINSTATED (2026-09-25 round 4, Chris: "Reinstall
    -- pagination for Conflicts - maybe 100 per page to try that
    -- first"), reversing the round-3 "just one scrollable list" change.
    -- An unbounded row pool tried to build all ~1121 rows (~18 UI
    -- objects each, ~20,000 objects) in one execution tick and tripped
    -- WoW's "script ran too long" watchdog (in-game crash trace at
    -- CreditsConfig.lua:924; root-caused against Roster's own
    -- ~652-row/~8-object pool, which works fine). Capping the live row
    -- pool to one page's worth keeps EnsureRowCount's per-refresh
    -- object count small regardless of how large the full filtered
    -- list is.
    local CONFLICTS_ROWS_PER_PAGE = 100
    local pageState = { page = 1 }

    local prevPageBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    prevPageBtn:SetPoint("TOPLEFT", sortNameBtn, "BOTTOMLEFT", 2, -10)
    prevPageBtn:SetSize(60, 20)
    prevPageBtn:SetText("< Prev")

    local pageLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageLabel:SetPoint("LEFT", prevPageBtn, "RIGHT", 8, 0)

    local nextPageBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    nextPageBtn:SetPoint("LEFT", pageLabel, "RIGHT", 8, 0)
    nextPageBtn:SetSize(60, 20)
    nextPageBtn:SetText("Next >")

    -- Row pool still grows on demand (EnsureRowCount), but the caller
    -- below never hands it more than CONFLICTS_ROWS_PER_PAGE records,
    -- so the pool itself never grows past 100 rows regardless of list
    -- size. Rows are never destroyed, only hidden, so the anchor chain
    -- built at creation time stays valid across refreshes and page
    -- changes.
    local rows = {}
    local function EnsureRowCount(n)
        for i = #rows + 1, n do
            local prevAnchor = rows[i - 1] or prevPageBtn
            local row = CreateFrame("Frame", nil, content)
            -- 34 -> 40 (2026-09-25 round 4): room for row.info's larger
            -- font below (concern #5: "character names row is too
            -- small, hard to read") without overlapping the next row -
            -- the row-to-row anchor gap isn't driven by rendered text
            -- height, only by this declared SetHeight.
            row:SetHeight(40)
            if i == 1 then
                row:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", -2, -24)
            else
                row:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, -6)
            end
            -- BUG FIX (2026-09-25, Chris: "no actual data in any row"): this
            -- row frame previously only got SetSize(1, 34) - a literal
            -- 1px-wide frame - with no RIGHT anchor of its own, so
            -- row.info's own TOPLEFT+RIGHT anchors below (relative to THIS
            -- row, not content) resolved to a negative-width region and
            -- rendered nothing. Anchoring row's own RIGHT to content gives
            -- it real width, same as every other stretched element in this
            -- file (hint, etc.) - row.info's RIGHT anchor below now has
            -- something real to stretch against.
            row:SetPoint("RIGHT", -16, 0)

            -- GameFontHighlightSmall -> GameFontHighlight (2026-09-25
            -- round 4, Chris concern #5: "character names row is too
            -- small (hard to read)").
            row.info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.info:SetPoint("TOPLEFT", 0, 0)
            row.info:SetPoint("RIGHT", 0, 0)
            row.info:SetJustifyH("LEFT")

            row.linkedText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.linkedText:SetPoint("TOPLEFT", row.info, "BOTTOMLEFT", 0, -4)

            row.unlinkBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.unlinkBtn:SetSize(60, 18)
            row.unlinkBtn:SetPoint("LEFT", row.linkedText, "RIGHT", 8, 0)
            row.unlinkBtn:SetText("Unlink")

            row.linkArrow = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.linkArrow:SetPoint("TOPLEFT", row.info, "BOTTOMLEFT", 0, -4)
            row.linkArrow:SetText("Link to:")

            row.linkEdit = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
            row.linkEdit:SetSize(120, 18)
            row.linkEdit:SetPoint("LEFT", row.linkArrow, "RIGHT", 6, -2)
            row.linkEdit:SetAutoFocus(false)
            row.linkEdit:SetMaxLetters(24)
            row.linkEdit:SetScript("OnEscapePressed", row.linkEdit.ClearFocus)

            row.linkBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.linkBtn:SetSize(50, 18)
            row.linkBtn:SetPoint("LEFT", row.linkEdit, "RIGHT", 6, 0)
            row.linkBtn:SetText("Link")

            -- "Set as New Main" (2026-09-25 round 4, Chris concern #6:
            -- "In addition to 'link' there needs to be a 'set as new
            -- main' option too"). Only meaningful alongside Link in the
            -- unlinked state - promotes this name straight to being its
            -- own main (ns.Credits_SetAsNewMain, CreditsSeed.lua),
            -- seeded with the real lifetime total it already earned
            -- (rec.rawGoldAmount, Step 0's own figure for this row).
            row.setMainBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.setMainBtn:SetSize(80, 18)
            row.setMainBtn:SetPoint("LEFT", row.linkBtn, "RIGHT", 6, 0)
            row.setMainBtn:SetText("New Main")

            row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.status:SetPoint("LEFT", row.setMainBtn, "RIGHT", 6, 0)

            row:Hide()
            rows[i] = row
        end
    end

    local function GetBottomAnchor()
        for i = #rows, 1, -1 do
            if rows[i]:IsShown() then return rows[i] end
        end
        return prevPageBtn
    end

    local function FilteredSortedRows()
        local typed = (filterEdit:GetText() or ""):lower()
        local list = {}
        local source = ns.CreditsReviewQueue or {}
        for _, rec in ipairs(source) do
            if typed == "" or (rec.name or ""):lower():find(typed, 1, true) then
                table.insert(list, rec)
            end
        end
        table.sort(list, function(a, b)
            if sortState.key == "latestDonation" then
                local av, bv = a.latestDonation or "", b.latestDonation or ""
                if av ~= bv then
                    if sortState.ascending then return av < bv else return av > bv end
                end
                return (a.name or "") < (b.name or "")
            else
                local an, bn = (a.name or ""):lower(), (b.name or ""):lower()
                if an ~= bn then
                    if sortState.ascending then return an < bn else return an > bn end
                end
                return false
            end
        end)
        return list
    end

    local function Refresh()
        sortNameBtn:SetText(sortState.key == "name" and (sortState.ascending and "Name v" or "Name ^") or "Name")
        sortDateBtn:SetText(sortState.key == "latestDonation" and (sortState.ascending and "Latest Donation v" or "Latest Donation ^") or "Latest Donation")

        local canManage = ns.CanManageCreditsConfigLocal and ns.CanManageCreditsConfigLocal() or false
        local list = FilteredSortedRows()

        -- Pagination (2026-09-25 round 4) - see the CONFLICTS_ROWS_PER_PAGE
        -- comment above for why. Page is clamped rather than reset on
        -- every refresh so sorting/relinking doesn't bounce the officer
        -- back to page 1; filtering DOES reset it (see filterEdit's
        -- OnTextChanged below), since a filter change usually shrinks
        -- the list enough that the current page number stops meaning
        -- the same thing.
        local totalPages = math.max(1, math.ceil(#list / CONFLICTS_ROWS_PER_PAGE))
        if pageState.page > totalPages then pageState.page = totalPages end
        if pageState.page < 1 then pageState.page = 1 end

        local pageStart = (pageState.page - 1) * CONFLICTS_ROWS_PER_PAGE
        local pageList = {}
        for i = 1, math.min(CONFLICTS_ROWS_PER_PAGE, #list - pageStart) do
            pageList[i] = list[pageStart + i]
        end

        pageLabel:SetText(("Page %d/%d (%d total)"):format(pageState.page, totalPages, #list))
        if pageState.page <= 1 then prevPageBtn:Disable() else prevPageBtn:Enable() end
        if pageState.page >= totalPages then nextPageBtn:Disable() else nextPageBtn:Enable() end

        EnsureRowCount(#pageList)

        for i, row in ipairs(rows) do
            local rec = pageList[i]
            if not rec then
                row:Hide()
            else
                row:Show()
                local tag = rec.issue == "identity_conflict" and "|cffffcc00conflict|r" or "|cff999999unmapped|r"
                local dateText = (rec.latestDonation and rec.latestDonation ~= "") and rec.latestDonation or "no date"
                row.info:SetText(("%s  (%s, last donation %s)"):format(rec.name or "?", tag, dateText))

                local linkedMain = ns.Credits_GetAltOverride and ns.Credits_GetAltOverride(rec.name) or nil
                if linkedMain then
                    row.linkedText:SetText("|cff33ff99-> " .. linkedMain .. "|r")
                    row.linkedText:Show()
                    row.unlinkBtn:Show()
                    if canManage then row.unlinkBtn:Enable() else row.unlinkBtn:Disable() end
                    row.linkArrow:Hide()
                    row.linkEdit:Hide()
                    row.linkBtn:Hide()
                    row.setMainBtn:Hide()
                    row.status:Hide()
                    row.unlinkBtn:SetScript("OnClick", function()
                        if ns.Credits_RemoveAltOverride(rec.name) then
                            ns.CreditsConfig_Refresh()
                        end
                    end)
                else
                    row.linkedText:Hide()
                    row.unlinkBtn:Hide()
                    row.linkArrow:Show()
                    row.linkEdit:Show()
                    row.linkBtn:Show()
                    row.setMainBtn:Show()
                    row.status:Show()
                    if canManage then row.linkEdit:Enable() else row.linkEdit:Disable() end
                    if canManage then row.linkBtn:Enable() else row.linkBtn:Disable() end
                    if canManage then row.setMainBtn:Enable() else row.setMainBtn:Disable() end
                    row.linkBtn:SetScript("OnClick", function()
                        local typedMain = row.linkEdit:GetText()
                        row.linkEdit:ClearFocus()
                        if typedMain == "" then return end
                        if ns.Credits_SetAltOverride(rec.name, typedMain) then
                            row.linkEdit:SetText("")
                            ns.CreditsConfig_Refresh()
                        else
                            row.status:SetText("|cffff3333Refused|r")
                            C_Timer.After(2, function() row.status:SetText("") end)
                        end
                    end)
                    row.setMainBtn:SetScript("OnClick", function()
                        if ns.Credits_SetAsNewMain(rec.name, rec.rawGoldAmount, rec.latestDonation) then
                            ns.CreditsConfig_Refresh()
                        else
                            row.status:SetText("|cffff3333Refused|r")
                            C_Timer.After(2, function() row.status:SetText("") end)
                        end
                    end)
                end
            end
        end

        local bottom = GetBottomAnchor()
        local top, bot = content:GetTop(), bottom:GetBottom()
        if top and bot then
            content:SetHeight(math.max(200, top - bot + 20))
        end
    end

    filterEdit:SetScript("OnTextChanged", function()
        pageState.page = 1
        Refresh()
    end)
    sortNameBtn:SetScript("OnClick", function()
        if sortState.key == "name" then
            sortState.ascending = not sortState.ascending
        else
            sortState.key = "name"
            sortState.ascending = true
        end
        Refresh()
    end)
    sortDateBtn:SetScript("OnClick", function()
        if sortState.key == "latestDonation" then
            sortState.ascending = not sortState.ascending
        else
            sortState.key = "latestDonation"
            sortState.ascending = false -- most recent donation first by default
        end
        Refresh()
    end)
    prevPageBtn:SetScript("OnClick", function()
        pageState.page = pageState.page - 1
        Refresh()
    end)
    nextPageBtn:SetScript("OnClick", function()
        pageState.page = pageState.page + 1
        Refresh()
    end)

    return Refresh
end

--------------------------------------------------------------------------
-- Placeholder tab - Audit Log owns no real data yet (CM7). The shell
-- exists now so that milestone fills in a tab rather than
-- re-architecting the window later.
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
    -- Generous fixed pre-first-refresh estimate (title/hint/seed button +
    -- sort/page controls + a full 20-row page) - trimmed to the real
    -- content height on every refresh, same as Settings tab.
    rosterContent:SetSize(1, 550)
    tabs.roster.refresh = BuildRosterTab(rosterContent)
    tabs.roster.content = rosterContent

    local conflictsContent = CreateFrame("Frame", nil, scrollFrame)
    conflictsContent:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, 0)
    -- Generous fixed pre-first-refresh estimate (title/hint/filter/sort/
    -- page controls + a full 15-row page, each row 2 lines) - trimmed to
    -- the real content height on every refresh, same as the other tabs.
    conflictsContent:SetSize(1, 650)
    tabs.conflicts.refresh = BuildConflictsTab(conflictsContent)
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
    -- Generalized (was hardcoded to "settings" only, from before Roster
    -- had a real refresh closure) - every tab's builder returns its own
    -- refresh closure the same way BuildSettingsTab does, so whichever
    -- tab is active gets it called here.
    local activeTab = tabs[activeTabKey]
    if activeTab and activeTab.refresh then
        activeTab.refresh()
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
