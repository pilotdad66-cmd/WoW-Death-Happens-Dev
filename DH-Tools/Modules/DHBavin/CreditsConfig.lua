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
--      for a player who is neither a Distribution Officer nor guild
--      leader/author (see CreditsConfig_Open's gate below).
--   2. Distribution Officer - views everyone, resolves alt/identity
--      conflicts. CM2's job - the Roster/Review Queue tabs below are
--      placeholders until that milestone lands.
--   3. Mail recipient (Bavin) - eventually able to hand-edit the raw
--      reputation source data backing the tooltip. Deliberately NOT
--      built here - the plan is periodic reimport of a fresh data file
--      (see Step 0), not manual edits, so this is indefinitely
--      deferred. Noted so it isn't forgotten, not because it's coming
--      soon.
--   4. Guild leader + Loopi (IsAuthorAccount) - manages who holds the
--      shared officer role (ns.CanSetEditorsName/ns.SetEditors,
--      Core.lua) via DH-Tools Config.lua's Officer Settings page, not
--      here (2026-09-28, Chris: officer roles combined into one list
--      across Bavin/Store/Credits and moved off this window - see
--      that section's own header comment). The DH-Bavin recipient
--      (Bavin.CanManageRecipient) stays on the Config.lua page too,
--      unchanged.
--
-- Tiers 2 and 4's Settings tab below is what CM1 actually builds today:
-- master toggle and both Wall 2 test lists (2026-09-28, Chris: officer
-- roles and the currency ratios removed from this tab entirely - see
-- BuildSettingsTab's own comment). Roster/Review Queue/Audit Log tabs
-- are placeholders (CM2/CM7 own that data).
--
-- GATING: same refuse-outright-on-open philosophy as PointsEditor.lua/
-- PriorityEditor.lua - if the caller cannot manage credits config
-- locally (any shared-list officer, or the author account) the window
-- never opens (2026-09-28: dropped the separate "manage the officers
-- list" branch of this check - that's the Officer Settings page's gate
-- now, not this window's). Closing is always allowed.

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
-- (SetCreditsMasterToggle, AddCreditTestReceiver/
-- RemoveCreditTestReceiver, AddCreditTestSender/RemoveCreditTestSender)
-- - this file adds no new permission logic of its own, only UI on top
-- of what's already gated. Returns a refresh closure the outer frame
-- calls on open/tab-switch/incoming sync.
--
-- 2026-09-28 (Chris, item 5): the Distribution Officers list and the
-- multiplier/ratio controls that used to live in this tab are REMOVED
-- - officer roles are now the shared list managed on DH-Tools
-- Config.lua's Officer Settings page (Core.lua's ns.SetEditors), and
-- the 3 currency ratios (Credit/Rep, Rep/Gold, Credit/Gold) moved to
-- that same page's new Currency/Conversion section. This tab is left
-- with just the master toggle and the two Wall 2 test lists.
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
    hint:SetText("Master toggle and both Wall 2 test lists are editable by the author account only during testing. Officer roles and the currency ratios now live on the Officer Settings page (DH-Tools Config), not here.")

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

    local receivers = CreateNameListSection(content, function() return toggleCheck end, {
        title = "Test Receivers (inbox hook - Wall 2)",
        hint = "Characters listed here get the TEST inbox-mail credit hook turned on for them once logged in, but only while the master toggle above is ON. Isolated from the live donation flow - safe to experiment with.",
        getList = function() return (ns.creditsDb and ns.creditsDb.creditTestReceivers) or {} end,
        addFn = ns.AddCreditTestReceiver,
        removeFn = ns.RemoveCreditTestReceiver,
        canManageFn = ns.CanManageCreditsTestConfigLocal,
        rowCount = 8,
        lockedText = "|cffff3333Author account only during testing.|r",
    })

    local senders = CreateNameListSection(content, receivers.GetBottomAnchor, {
        title = "Test Senders (outgoing hook - Wall 2)",
        hint = "Characters listed here get the TEST outgoing-mail credit hook turned on for them once logged in, but only while the master toggle above is ON. Isolated from the live donation flow - safe to experiment with.",
        getList = function() return (ns.creditsDb and ns.creditsDb.creditTestSenders) or {} end,
        addFn = ns.AddCreditTestSender,
        removeFn = ns.RemoveCreditTestSender,
        canManageFn = ns.CanManageCreditsTestConfigLocal,
        rowCount = 8,
        lockedText = "|cffff3333Author account only during testing.|r",
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

    -- "Start from scratch (all officers)" (2026-10-04, Loopi): the coordinated
    -- reset - wipes + reseeds this client AND announces it so every officer's
    -- client (including ones who log in later) does the same. Author account
    -- only to START; same two-click confirm idiom as above.
    local startBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    startBtn:SetSize(220, 22)
    startBtn:SetText("Start from scratch (all officers)")

    local startStatus = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    startStatus:SetPoint("TOPLEFT", startBtn, "BOTTOMLEFT", 2, -4)
    startStatus:SetPoint("RIGHT", content, "RIGHT", -16, 0)
    startStatus:SetJustifyH("LEFT")
    startStatus:SetWordWrap(true)

    local startArmed, startArmedTimer, startMsg = false, nil, nil

    local function StartInfoText()
        local epoch = ns.creditsDb and ns.creditsDb.dataEpoch or 0
        local last = (epoch > 0) and ("Last reset: " .. date("%Y-%m-%d %H:%M", epoch)) or "No reset has been done yet."
        return "|cffaaaaaa" .. last .. "  Wipes the ledger, review queue, held credits and audit log on every officer's client, then reseeds. Config is kept.|r"
    end

    local function DisarmStart()
        startArmed = false
        startBtn:SetText("Start from scratch (all officers)")
        startStatus:SetText(startMsg or StartInfoText())
    end

    startBtn:SetScript("OnClick", function()
        if not ns.CanManageCreditsTestConfigLocal() then return end
        if not startArmed then
            startArmed = true
            startMsg = nil
            startBtn:SetText("Click again to confirm")
            startStatus:SetText("|cffffcc00This wipes ALL credit data on EVERY officer's client and reseeds it.|r")
            if startArmedTimer then startArmedTimer:Cancel() end
            startArmedTimer = C_Timer.NewTimer(8, DisarmStart)
            return
        end
        if startArmedTimer then startArmedTimer:Cancel() end
        if ns.Credits_StartOver() then
            startMsg = "|cff33ff99Started from scratch - announced to online officers.|r"
        else
            startMsg = "|cffff3333Refused|r"
        end
        DisarmStart()
        C_Timer.After(4, function() startMsg = nil; if not startArmed then startStatus:SetText(StartInfoText()) end end)
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

        local canConfig = ns.CanManageCreditsTestConfigLocal()
        if canConfig then
            toggleCheck:Enable()
        else
            toggleCheck:Disable()
        end

        receivers.Refresh()
        senders.Refresh()

        resetBtn:ClearAllPoints()
        resetBtn:SetPoint("TOPLEFT", senders.GetBottomAnchor(), "BOTTOMLEFT", -8, -20)

        startBtn:ClearAllPoints()
        startBtn:SetPoint("TOPLEFT", resetBtn, "BOTTOMLEFT", 0, -16)
        if ns.CanManageCreditsTestConfigLocal() then
            startBtn:Enable()
        else
            startBtn:Disable()
        end
        if not startArmed and not startMsg then startStatus:SetText(StartInfoText()) end

        -- Shrink the scroll content to fit what's actually laid out
        -- (2026-09-25, Chris: "too much wasted space") - GetTop/GetBottom
        -- are nil until the frame has actually rendered once, hence the
        -- guard; falls back to leaving the generous fixed estimate alone.
        local top, bottom = content:GetTop(), startStatus:GetBottom()
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
    hint:SetText("Every main's seeded reputation/credit standing. Rank is always by Lifetime Points, regardless of the active sort. Click a column title (Name/Lifetime/Last Donation) to sort by it - click again to flip direction. Left-click a name marked [+] to show its alts; right-click any name for a menu (Show Account, Merge into... on a main - folds an account that was auto-created from a first donation into the account it really belongs to, a Discord submenu - Add as Discord / Remove as Discord / Discord Only - and on an alt also Unlink Alt / Promote to Main). Each name is tagged [Main], [Alt], [Discord], [Discord/Main] or [Discord/Alt]; an account has one Discord name and always a real main. Search finds any main, alt or Discord name across every page. \"Add name...\" (author, guild leader or mail recipient) puts a new main, an alt of an account or a Discord name on the Roster by hand - a name that is already on the Roster is refused; right-click a main for the \"Add alt...\" / \"Add Discord name...\" shortcuts. Seeding is Distribution Officer only; re-running it overwrites the row for any name in the historical data (SeedData.lua) without touching rows for names outside that dataset.")

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
    -- box"). The row pool below grows on demand, but only one page's
    -- worth of accounts is ever rendered (see the pagination block just
    -- below - the earlier "no page controls" approach timed out at ~1100
    -- accounts).
    local sortState = { key = "mainToon", ascending = true }
    local expanded = {}   -- discordName -> true when its alts are shown

    -- Pagination (2026-09-29, Loopi: "script ran too long" opening the
    -- Roster with the full ~1100-account seed loaded - the same failure
    -- the Review Queue hit on 2026-09-25 and fixed with 100/page). The
    -- unbounded row pool tried to build a frame + ~9 regions per account
    -- in one tick. Now only ROSTER_MAINS_PER_PAGE accounts are rendered
    -- at a time (plus their alt sub-rows when expanded, which are cheap
    -- and don't count toward the page size, so expanding never reshuffles
    -- which mains are on the page). Rank stays global - it is computed
    -- from the whole ledger, not the page.
    local ROSTER_MAINS_PER_PAGE = 100
    local pageState = { page = 1 }

    -- Search + "Add name..." row (2026-10-06, Loopi). The search matches any
    -- name on an account (main, alt, Discord name or account key) across ALL
    -- pages, not just the one on screen; an account that matched only through
    -- an alt / Discord name opens itself so the hit is visible. Typing
    -- resets to page 1. The script that reacts to typing is attached further
    -- down (it needs Refresh); the Add name button's click handler too.
    local filterState = { text = "" }

    local filterLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterLabel:SetPoint("TOPLEFT", seedBtn, "BOTTOMLEFT", 2, -12)
    filterLabel:SetText("Search:")

    local filterEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    filterEdit:SetSize(150, 20)
    filterEdit:SetPoint("LEFT", filterLabel, "RIGHT", 8, -2)
    filterEdit:SetAutoFocus(false)
    filterEdit:SetMaxLetters(32)
    filterEdit:SetScript("OnEscapePressed", filterEdit.ClearFocus)
    filterEdit:SetScript("OnEnterPressed", filterEdit.ClearFocus)

    local addBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    addBtn:SetPoint("LEFT", filterEdit, "RIGHT", 12, 2)
    addBtn:SetSize(110, 22)
    addBtn:SetText("Add name...")

    local prevPageBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    prevPageBtn:SetPoint("TOPLEFT", filterLabel, "BOTTOMLEFT", -2, -12)
    prevPageBtn:SetSize(60, 20)
    prevPageBtn:SetText("< Prev")

    local pageLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageLabel:SetPoint("LEFT", prevPageBtn, "RIGHT", 8, 0)

    local nextPageBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    nextPageBtn:SetPoint("LEFT", pageLabel, "RIGHT", 8, 0)
    nextPageBtn:SetSize(60, 20)
    nextPageBtn:SetText("Next >")

    -- Mirror of the pager above, placed under the LAST visible row
    -- (re-anchored on every Refresh, since the row count changes with
    -- expand/collapse) so changing pages doesn't mean scrolling back up
    -- (2026-09-29, Loopi).
    local botPrevBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    botPrevBtn:SetSize(60, 20)
    botPrevBtn:SetText("< Prev")

    local botPageLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    botPageLabel:SetPoint("LEFT", botPrevBtn, "RIGHT", 8, 0)

    local botNextBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    botNextBtn:SetPoint("LEFT", botPageLabel, "RIGHT", 8, 0)
    botNextBtn:SetSize(60, 20)
    botNextBtn:SetText("Next >")

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
    -- Column layout (2026-09-25, Chris: "why are these not dynamic like
    -- the Board?") - rebuilt right-to-left off the row's own RIGHT edge,
    -- the same technique DH-Air's Board.lua uses (see that file's own
    -- header comment: "the header always lines up with its column no
    -- matter how the window is resized - both are built from these same
    -- numbers, right-to-left"). Rank is fixed at the far left; Tier/
    -- Points/Lifetime/Last Donation/Credits are fixed-width, each
    -- anchored to the LEFT of the one before it; Name is the only column
    -- with NO explicit width at all - anchored on both sides (Rank's
    -- right, Tier's left), it just fills whatever room is left, growing
    -- or shrinking automatically as the window is resized. Unlike Board
    -- (which splits extra width between Name and Destination - see its
    -- Board_Refresh column-growth calc), Roster only has the one column
    -- that ever needs to grow, so no split/cap math is needed here - 100%
    -- of any extra space goes to Name for free, purely from the anchors.
    -- Requires rosterContent's own TOPRIGHT anchor (CreateWindow, below)
    -- so headerRow/each row's RIGHT edge actually tracks a resize.
    local COL_GAP = 8
    local RANK_WIDTH = 42 -- room for the sort arrow beside "Rank"
    local NAME_LEFT_GAP = 4
    local TIER_WIDTH, POINTS_WIDTH, LIFETIME_WIDTH, LASTDON_WIDTH, CREDITS_WIDTH = 76, 76, 80, 86, 84

    local headerRow = CreateFrame("Frame", nil, content)
    headerRow:SetPoint("TOPLEFT", prevPageBtn, "BOTTOMLEFT", 0, -10)
    headerRow:SetPoint("RIGHT", content, "RIGHT", -16, 0)
    headerRow:SetHeight(16)

    local function HeaderCell(text, width)
        local fs = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetWidth(width)
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        return fs
    end

    -- Sortable header: a borderless Button (not UIPanelButtonTemplate -
    -- this needs to look like a column title, not a button) with a
    -- HIGHLIGHT texture for hover feedback and a label this file's
    -- Refresh() rewrites with a v/^ arrow when that column is the
    -- active sort. `width` is nil for Name - it's sized entirely by its
    -- own two-sided anchor below, not by this function.
    local function SortableHeaderCell(text, width, sortKey)
        local btn = CreateFrame("Button", nil, headerRow)
        if width then
            btn:SetSize(width, 16)
        else
            btn:SetHeight(16)
        end
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

    -- Rank / Tier / Points / Credits sortable too (2026-09-29, Loopi).
    -- Tier and Points have no order of their own - both derive from
    -- lifetime points - so clicking either sorts by Rank (key "rank"),
    -- and the arrow shows on all three while that order is active.
    local rankHeader = SortableHeaderCell("Rank", RANK_WIDTH, "rank")
    rankHeader:SetPoint("LEFT", 0, 0)

    local creditsHeader = SortableHeaderCell("Credits", CREDITS_WIDTH, "credits")
    creditsHeader:SetPoint("RIGHT", headerRow, "RIGHT", 0, 0)

    local lastDonationHeader = SortableHeaderCell("Last Donation", LASTDON_WIDTH, "lastDonationDate")
    lastDonationHeader:SetPoint("RIGHT", creditsHeader, "LEFT", -COL_GAP, 0)

    local lifetimeHeader = SortableHeaderCell("Lifetime", LIFETIME_WIDTH, "lifetimePoints")
    lifetimeHeader:SetPoint("RIGHT", lastDonationHeader, "LEFT", -COL_GAP, 0)

    local pointsHeader = SortableHeaderCell("Points", POINTS_WIDTH, "rank")
    pointsHeader:SetPoint("RIGHT", lifetimeHeader, "LEFT", -COL_GAP, 0)

    local tierHeader = SortableHeaderCell("Tier", TIER_WIDTH, "rank")
    tierHeader:SetPoint("RIGHT", pointsHeader, "LEFT", -COL_GAP, 0)

    -- The stretch column - see the block comment above.
    local nameHeader = SortableHeaderCell("Name", nil, "mainToon")
    nameHeader:SetPoint("LEFT", rankHeader, "RIGHT", NAME_LEFT_GAP, 0)
    nameHeader:SetPoint("RIGHT", tierHeader, "LEFT", -COL_GAP, 0)

    -- Row pool grows on demand (EnsureRowCount) instead of a fixed
    -- page size - each display entry is either a main (full row, with
    -- a clickable Name for expand/collapse when it has alts) or an alt
    -- sub-row (indented Name only, other cells blank). Rows are never
    -- destroyed, only hidden, so the TOPLEFT->BOTTOMLEFT anchor chain
    -- built at creation time stays valid across refreshes.
    local rows = {}
    local Refresh   -- forward-declared: row click handlers call it

    ------------------------------------------------------------------
    -- Right-click context menu (2026-09-29, Loopi). Left-click keeps
    -- expanding/collapsing; right-click on a name opens a small menu:
    --   alt row:  Unlink Alt / Promote to Main / Show Account
    --   main row: Show Account
    -- Built on the same vendored dropdown library as the minimap button's
    -- menus (LibUIDropDownMenuDHTools-4.0 via Create_UIDropDownMenu +
    -- EasyMenu, opened at the cursor - see Minimap.lua and
    -- claude\knowledge\k-0003): a hand-rolled frame menu drew fine but its
    -- items were not clickable in-game (2026-09-29). Unlink/Promote are
    -- Distribution-Officer-only (greyed otherwise); Promote needs a second
    -- click to confirm because it changes which toon is the account's face.
    ------------------------------------------------------------------
    local LibDropDown = LibStub and LibStub("LibUIDropDownMenuDHTools-4.0", true)
    local menuFrame
    local pendingPromote   -- { name=, t= } after the first Promote click
    local PROMOTE_CONFIRM_SECS = 8

    local function HideMenu()
        if LibDropDown then LibDropDown:CloseDropDownMenus() end
    end

    local function ShowMenu(entries)
        if not LibDropDown then return end
        if not menuFrame then
            menuFrame = LibDropDown:Create_UIDropDownMenu("DHBavinRosterMenuFrame", UIParent)
        end
        LibDropDown:EasyMenu(entries, menuFrame, "cursor", 0, 0, "MENU", 2)
    end

    -- "Merge into..." (CM4 step 8, 2026-10-04). For an account that was
    -- auto-created on a first donation and turns out to be someone's alt:
    -- first popup asks which account to merge it INTO (type any of its
    -- names), second popup is the confirm click; ns.Credits_MergeAccounts
    -- does the work (officer-gated again there).
    local function ResolveAccountKey(typed)
        typed = (typed or ""):match("^%s*(.-)%s*$")
        if typed == "" or not ns.creditsDb then return nil end
        local key = ns.creditsDb.toonIndex and ns.creditsDb.toonIndex[ns.NormalizeName(typed):lower()]
        if key and ns.creditsDb.ledger[key] then return key end
        if ns.creditsDb.ledger[typed] then return typed end
        for k, rec in pairs(ns.creditsDb.ledger) do
            if (ns.Credits_GetDiscord(rec) or ""):lower() == typed:lower() then return k end
        end
        return nil
    end
    StaticPopupDialogs["DHBAVIN_MERGE_CONFIRM"] = {
        text = "Merge %s into %s?\n\nAll of its alts, reputation and credits move over and the account being merged is deleted. This cannot be undone.",
        button1 = "Merge",
        button2 = CANCEL or "Cancel",
        OnAccept = function(_, data)
            local ok, why = ns.Credits_MergeAccounts(data.source, data.target)
            if not ok then ns.CreditsPrint("Merge refused: " .. tostring(why)) end
        end,
        timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
    }
    -- Picker window (2026-10-04, Loopi): type a name, matching accounts (any
    -- main or alt, never the account being merged) list below like the
    -- Editors box in the Bavin settings; click one (or Enter on the first)
    -- to go on to the confirm popup.
    local MERGE_SUGGEST_ROWS = 8
    local mergePicker
    local function MergeSuggestions(typed, sourceKey)
        local t = (typed or ""):match("^%s*(.-)%s*$"):lower()
        if t == "" then return {} end
        local starts, contains = {}, {}
        local ledger = ns.creditsDb and ns.creditsDb.ledger or {}
        local function Consider(name, key, main)
            if not name or name == "" then return end
            local l = name:lower()
            local item = { name = name, key = key, main = main }
            if l:sub(1, #t) == t then starts[#starts + 1] = item
            elseif l:find(t, 1, true) then contains[#contains + 1] = item end
        end
        for key, rec in pairs(ledger) do
            if key ~= sourceKey then
                Consider(rec.mainToon, key, rec.mainToon)
                for _, a in ipairs(rec.alts or {}) do Consider(a, key, rec.mainToon) end
            end
        end
        local function ByName(a, b) return a.name:lower() < b.name:lower() end
        table.sort(starts, ByName)
        table.sort(contains, ByName)
        local out = {}
        for _, list in ipairs({ starts, contains }) do
            for _, item in ipairs(list) do
                if #out < MERGE_SUGGEST_ROWS then out[#out + 1] = item end
            end
        end
        return out
    end
    local function MergePick(picker, key)
        local ledger = ns.creditsDb and ns.creditsDb.ledger or {}
        local src = picker.sourceKey
        if not key then
            ns.CreditsPrint("No account found for that name.")
        elseif key == src then
            ns.CreditsPrint("That is the same account.")
        elseif ledger[src] and ledger[key] then
            picker:Hide()
            StaticPopup_Show("DHBAVIN_MERGE_CONFIRM", ledger[src].mainToon, ledger[key].mainToon,
                { source = src, target = key })
        end
    end
    local function RefreshMergePicker()
        local p = mergePicker
        if not p then return end
        local list = MergeSuggestions(p.edit:GetText(), p.sourceKey)
        p.suggestions = list
        for i, btn in ipairs(p.rows) do
            local item = list[i]
            if item then
                local text = item.name
                if item.name:lower() ~= (item.main or ""):lower() then
                    text = text .. "  |cff888888alt of " .. tostring(item.main) .. "|r"
                end
                btn.label:SetText(text)
                btn.key = item.key
                btn:Show()
            else
                btn.key = nil
                btn:Hide()
            end
        end
        p.empty:SetShown(#list == 0)
        p.empty:SetText((p.edit:GetText() or "") == "" and "Start typing a main or alt name." or "No matching account.")
    end
    local function ShowMergePicker(sourceName, sourceKey)
        if not mergePicker then
            local p = CreateFrame("Frame", "DHBavinMergePicker", UIParent, "BasicFrameTemplateWithInset")
            p:SetSize(330, 292)
            p:SetPoint("CENTER", 0, 80)
            p:SetFrameStrata("DIALOG")
            p:EnableMouse(true)
            if p.TitleText then p.TitleText:SetText("Merge into...") end
            if UISpecialFrames then table.insert(UISpecialFrames, "DHBavinMergePicker") end

            p.msg = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            p.msg:SetPoint("TOPLEFT", 16, -34)
            p.msg:SetPoint("RIGHT", -16, 0)
            p.msg:SetJustifyH("LEFT")
            p.msg:SetWordWrap(true)

            local eb = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
            eb:SetSize(270, 22)
            eb:SetPoint("TOPLEFT", p.msg, "BOTTOMLEFT", 6, -12)
            eb:SetAutoFocus(false)
            eb:SetMaxLetters(24)
            eb:SetScript("OnTextChanged", function() RefreshMergePicker() end)
            eb:SetScript("OnEscapePressed", function() p:Hide() end)
            eb:SetScript("OnEnterPressed", function(self)
                local first = p.suggestions and p.suggestions[1]
                MergePick(p, (first and first.key) or ResolveAccountKey(self:GetText()))
            end)
            p.edit = eb

            p.rows = {}
            for i = 1, MERGE_SUGGEST_ROWS do
                local btn = CreateFrame("Button", nil, p)
                btn:SetSize(290, 20)
                btn:SetPoint("TOPLEFT", eb, "BOTTOMLEFT", -6, -6 - (i - 1) * 20)
                local hl = btn:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(1, 1, 1, 0.15)
                btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                btn.label:SetPoint("LEFT", 6, 0)
                btn.label:SetJustifyH("LEFT")
                btn:SetScript("OnClick", function(self) MergePick(p, self.key) end)
                p.rows[i] = btn
            end
            p.empty = p:CreateFontString(nil, "OVERLAY", "GameFontDisable")
            p.empty:SetPoint("TOPLEFT", eb, "BOTTOMLEFT", 0, -10)
            mergePicker = p
        end
        local p = mergePicker
        p.sourceKey = sourceKey
        p.msg:SetText(("Merge %s into which account? Type the main or any alt name of the account that should keep everything."):format(sourceName or "?"))
        p.edit:SetText("")
        p:Show()
        p.edit:SetFocus()
        RefreshMergePicker()
    end
    ns.CreditsConfig_ShowMergePicker = ShowMergePicker

    -- "Discord" submenu (2026-09-29, Loopi): Add as Discord / Remove as
    -- Discord / Discord Only. An account has exactly one Discord name and
    -- always a real main, so: Add is greyed on the name that already has the
    -- tag, Remove is greyed on names that don't, and Discord Only (turn an
    -- ALT into a pure Discord name that is not a character) is greyed on the
    -- main and on entries that are already Discord-only. Removing or
    -- replacing a Discord-only name no longer deletes it (2026-10-04,
    -- Loopi): it goes to the Review Queue, so there is no confirm click.
    -- The "sent to the Review Queue" notice is a chat line only (the
    -- center-screen copy was removed 2026-10-04, Loopi).
    local function NotifyQueued(msg)
        ns.CreditsPrint(msg)
    end
    local function DiscordSubmenu(name, account, kind, canManage)
        local rec = ns.creditsDb and ns.creditsDb.ledger and ns.creditsDb.ledger[account]
        local tagged = rec and ns.Credits_IsDiscordName(rec, name) or false
        return {
            { text = "Add as Discord", notCheckable = true, disabled = not canManage or tagged or not rec,
              func = function()
                local ok, displaced = ns.Credits_SetDiscord(name)
                if ok then
                    ns.CreditsPrint(name .. " is now the Discord name for that account.")
                    if displaced then
                        NotifyQueued(displaced .. " was only a Discord name - it has been sent to the Review Queue.")
                    end
                    ns.CreditsConfig_Refresh()
                end
              end },
            { text = "Remove as Discord",
              notCheckable = true, disabled = not canManage or not tagged,
              func = function()
                local ok, cleared = ns.Credits_ClearDiscord(account)
                if ok then
                    if cleared then
                        NotifyQueued(cleared .. " was only a Discord name - it has been sent to the Review Queue.")
                    else
                        ns.CreditsPrint("Discord name removed from that account.")
                    end
                    ns.CreditsConfig_Refresh()
                end
              end },
            { text = "Discord Only", notCheckable = true, disabled = not canManage or kind ~= "alt",
              func = function()
                if ns.Credits_MakeDiscordOnly(name) then
                    ns.CreditsPrint(name .. " is now a Discord name only (not a character).")
                    ns.CreditsConfig_Refresh()
                end
              end },
        }
    end

    ------------------------------------------------------------------
    -- "Add name..." dialog (2026-10-06, Loopi). Puts a name on the Roster by
    -- hand: a new main (new account), an alt of an existing account, or a
    -- Discord name for an existing account. Duplicates are refused (the
    -- logic is ns.Credits_AddRosterName in Credits.lua - same gate as the
    -- rates: author / guild leader / mail recipient). The dialog stays open
    -- after a successful add so several names can go in one sitting; the
    -- account box keeps its text for the same reason.
    ------------------------------------------------------------------
    local ADD_SUGGEST_ROWS = 6
    local ADD_KINDS = { "main", "alt", "discord" }
    local ADD_KIND_TEXT = {
        main = "New main (creates a new account)",
        alt = "Alt of an existing account",
        discord = "Discord name for an existing account",
    }
    local addDialog

    local function AddDialogMessage(p, text, good)
        p.status:SetText(text or "")
        if good then p.status:SetTextColor(0.2, 1, 0.6) else p.status:SetTextColor(1, 0.3, 0.3) end
    end

    local function RefreshAddDialog()
        local p = addDialog
        if not p then return end
        for _, k in ipairs(ADD_KINDS) do p.kindChecks[k]:SetChecked(p.kind == k) end
        local needAccount = p.kind ~= "main"
        p.accountLabel:SetShown(needAccount)
        p.accountEdit:SetShown(needAccount)
        p.mainNote:SetShown(not needAccount)
        local list = needAccount and MergeSuggestions(p.accountEdit:GetText(), nil) or {}
        for i, btn in ipairs(p.rows) do
            local item = list[i]
            if item then
                local text = item.name
                if item.name:lower() ~= (item.main or ""):lower() then
                    text = text .. "  |cff888888alt of " .. tostring(item.main) .. "|r"
                end
                btn.label:SetText(text)
                btn.item = item
                btn:Show()
            else
                btn.item = nil
                btn:Hide()
            end
        end
        if p.kind == "alt" then
            p.nameLabel:SetText("New alt name:")
        elseif p.kind == "discord" then
            p.nameLabel:SetText("Discord name:")
        else
            p.nameLabel:SetText("New main name:")
        end
        if ns.Credits_CanAddRosterNamesLocal and ns.Credits_CanAddRosterNamesLocal() then
            p.addBtn:Enable()
        else
            p.addBtn:Disable()
            AddDialogMessage(p, "Only the author, guild leader or mail recipient can add names.")
        end
    end

    local function SubmitAddDialog()
        local p = addDialog
        if not p then return end
        local name = (p.nameEdit:GetText() or ""):match("^%s*(.-)%s*$")
        local account = (p.accountEdit:GetText() or ""):match("^%s*(.-)%s*$")
        if name == "" then
            AddDialogMessage(p, "Type the name to add.")
            return
        end
        if p.kind ~= "main" and account == "" then
            AddDialogMessage(p, "Type a name on the account it belongs to.")
            return
        end
        local ok, a, displaced = ns.Credits_AddRosterName(p.kind, name, account)
        if ok then
            local rec = ns.creditsDb and ns.creditsDb.ledger and ns.creditsDb.ledger[a]
            local owner = rec and rec.mainToon or "?"
            local bare = (p.kind == "discord") and name or ns.NormalizeName(name)
            local msg
            if p.kind == "main" then
                msg = ("%s added as a new main."):format(bare)
            elseif p.kind == "alt" then
                msg = ("%s added as an alt of %s."):format(bare, owner)
            else
                msg = ("%s is now the Discord name for %s."):format(bare, owner)
            end
            AddDialogMessage(p, msg, true)
            ns.CreditsPrint(msg)
            if displaced then
                NotifyQueued(displaced .. " was only a Discord name - it has been sent to the Review Queue.")
            end
            p.nameEdit:SetText("")
            p.nameEdit:SetFocus()
            ns.CreditsConfig_Refresh()
            return
        end
        local reason = a
        if reason == "permission" then
            AddDialogMessage(p, "Only the author, guild leader or mail recipient can add names.")
        elseif reason == "name" then
            if p.kind == "discord" then
                AddDialogMessage(p, "Not a valid name (1-32 characters, no control characters).")
            else
                AddDialogMessage(p, "Not a valid character name (no spaces, up to 32 characters).")
            end
        elseif reason == "exists" then
            local bare = (p.kind == "discord") and name or ns.NormalizeName(name)
            local rec, how = ns.Credits_FindRosterName(bare)
            local where = "on the Roster"
            if rec and how == "main" then
                where = "already a main"
            elseif rec and how == "alt" then
                where = "already an alt of " .. tostring(rec.mainToon)
            elseif rec and how == "discord" then
                where = "already the Discord name of " .. tostring(rec.mainToon)
            elseif rec and how == "account" then
                where = "already an account"
            end
            AddDialogMessage(p, ("%s is %s - not added."):format(bare, where))
        elseif reason == "noaccount" then
            AddDialogMessage(p, "No account has that name. Pick one from the list.")
        else
            AddDialogMessage(p, "Could not add that name (" .. tostring(reason) .. ").")
        end
    end

    local function ShowAddDialog(kind, accountName)
        if not addDialog then
            local p = CreateFrame("Frame", "DHBavinAddNameDialog", UIParent, "BasicFrameTemplateWithInset")
            p:SetSize(340, 392)
            p:SetPoint("CENTER", 0, 60)
            p:SetFrameStrata("DIALOG")
            p:EnableMouse(true)
            if p.TitleText then p.TitleText:SetText("Add name to Roster") end
            if UISpecialFrames then table.insert(UISpecialFrames, "DHBavinAddNameDialog") end
            p.kind = "alt"

            p.kindChecks = {}
            local prev
            for _, k in ipairs(ADD_KINDS) do
                local cb = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
                cb:SetSize(24, 24)
                if prev then
                    cb:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, 0)
                else
                    cb:SetPoint("TOPLEFT", 14, -30)
                end
                local fs = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
                fs:SetText(ADD_KIND_TEXT[k])
                cb:SetScript("OnClick", function()
                    p.kind = k
                    AddDialogMessage(p, "")
                    RefreshAddDialog()
                end)
                p.kindChecks[k] = cb
                prev = cb
            end

            p.nameLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            p.nameLabel:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 2, -10)

            local nameEdit = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
            nameEdit:SetSize(280, 22)
            nameEdit:SetPoint("TOPLEFT", p.nameLabel, "BOTTOMLEFT", 6, -4)
            nameEdit:SetAutoFocus(false)
            nameEdit:SetMaxLetters(32)
            nameEdit:SetScript("OnEscapePressed", function() p:Hide() end)
            nameEdit:SetScript("OnEnterPressed", function() SubmitAddDialog() end)
            p.nameEdit = nameEdit

            p.accountLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            p.accountLabel:SetPoint("TOPLEFT", nameEdit, "BOTTOMLEFT", -6, -10)
            p.accountLabel:SetText("Add it to the account that has this name:")

            p.mainNote = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            p.mainNote:SetPoint("TOPLEFT", nameEdit, "BOTTOMLEFT", -6, -10)
            p.mainNote:SetPoint("RIGHT", -16, 0)
            p.mainNote:SetJustifyH("LEFT")
            p.mainNote:SetWordWrap(true)
            p.mainNote:SetText("A new main starts a new account at 0 points and 0 credits. If the name is waiting in the Review Queue, its history from the raw data is kept and it leaves the queue.")

            local accountEdit = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
            accountEdit:SetSize(280, 22)
            accountEdit:SetPoint("TOPLEFT", p.accountLabel, "BOTTOMLEFT", 6, -4)
            accountEdit:SetAutoFocus(false)
            accountEdit:SetMaxLetters(32)
            accountEdit:SetScript("OnTextChanged", function() RefreshAddDialog() end)
            accountEdit:SetScript("OnEscapePressed", function() p:Hide() end)
            accountEdit:SetScript("OnEnterPressed", function(self)
                local first = p.rows[1] and p.rows[1].item
                if first and first.main then self:SetText(first.main) end
                p.nameEdit:SetFocus()
            end)
            p.accountEdit = accountEdit

            p.rows = {}
            for i = 1, ADD_SUGGEST_ROWS do
                local btn = CreateFrame("Button", nil, p)
                btn:SetSize(300, 20)
                btn:SetPoint("TOPLEFT", accountEdit, "BOTTOMLEFT", -6, -4 - (i - 1) * 20)
                local hl = btn:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(1, 1, 1, 0.15)
                btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                btn.label:SetPoint("LEFT", 6, 0)
                btn.label:SetJustifyH("LEFT")
                btn:SetScript("OnClick", function(self)
                    if self.item and self.item.main then
                        p.accountEdit:SetText(self.item.main)
                        p.nameEdit:SetFocus()
                    end
                end)
                p.rows[i] = btn
            end

            p.status = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            p.status:SetPoint("BOTTOMLEFT", 16, 46)
            p.status:SetPoint("RIGHT", -16, 0)
            p.status:SetJustifyH("LEFT")
            p.status:SetWordWrap(true)

            p.addBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
            p.addBtn:SetSize(100, 22)
            p.addBtn:SetPoint("BOTTOMLEFT", 16, 16)
            p.addBtn:SetText("Add")
            p.addBtn:SetScript("OnClick", function() SubmitAddDialog() end)

            local closeBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
            closeBtn:SetSize(100, 22)
            closeBtn:SetPoint("LEFT", p.addBtn, "RIGHT", 8, 0)
            closeBtn:SetText("Close")
            closeBtn:SetScript("OnClick", function() p:Hide() end)

            addDialog = p
        end
        local p = addDialog
        if kind == "main" or kind == "alt" or kind == "discord" then p.kind = kind end
        p.nameEdit:SetText("")
        p.accountEdit:SetText(accountName or "")
        AddDialogMessage(p, "")
        p:Show()
        RefreshAddDialog()
        p.nameEdit:SetFocus()
    end
    ns.CreditsConfig_ShowAddDialog = ShowAddDialog

    local OpenRowMenu
    OpenRowMenu = function(row)
        local canManage = ns.CanManageCreditsConfigLocal and ns.CanManageCreditsConfigLocal() or false
        local canAdd = ns.Credits_CanAddRosterNamesLocal and ns.Credits_CanAddRosterNamesLocal() or false
        if row.entryKind == "main" and row.currentAccount then
            local account = row.currentAccount
            pendingPromote = nil
            ShowMenu({
                { text = row.mainName or "Account", isTitle = true, notCheckable = true },
                { text = "Discord", notCheckable = true, hasArrow = true,
                  menuList = DiscordSubmenu(row.mainName, account, "main", canManage) },
                { text = "Add alt...", notCheckable = true, disabled = not canAdd, func = function()
                    ns.CreditsConfig_ShowAddDialog("alt", row.mainName)
                end },
                { text = "Add Discord name...", notCheckable = true, disabled = not canAdd, func = function()
                    ns.CreditsConfig_ShowAddDialog("discord", row.mainName)
                end },
                { text = "Merge into...", notCheckable = true, disabled = not canManage, func = function()
                    ns.CreditsConfig_ShowMergePicker(row.mainName, account)
                end },
                { text = "Show Account", notCheckable = true, func = function()
                    if ns.Account_ShowFor then ns.Account_ShowFor(account) end
                end },
            })
        elseif row.entryKind == "discord" and row.discordName and row.altAccount then
            local dname, account = row.discordName, row.altAccount
            pendingPromote = nil
            ShowMenu({
                { text = dname .. " (Discord only)", isTitle = true, notCheckable = true },
                { text = "Discord", notCheckable = true, hasArrow = true,
                  menuList = DiscordSubmenu(dname, account, "discord", canManage) },
                { text = "Show Account", notCheckable = true, func = function()
                    if ns.Account_ShowFor then ns.Account_ShowFor(account) end
                end },
            })
        elseif row.entryKind == "alt" and row.altName and row.altAccount then
            local altName, account = row.altName, row.altAccount
            local armed = pendingPromote and pendingPromote.name == altName
                and (GetTime() - pendingPromote.t) < PROMOTE_CONFIRM_SECS
            if not armed then pendingPromote = nil end
            ShowMenu({
                { text = altName, isTitle = true, notCheckable = true },
                { text = "Unlink Alt", notCheckable = true, disabled = not canManage, func = function()
                    pendingPromote = nil
                    if ns.Credits_UnlinkAlt(altName) then ns.CreditsConfig_Refresh() end
                end },
                { text = armed and "|cffffcc00Click again to confirm promote|r" or "Promote to Main",
                  notCheckable = true, disabled = not canManage, func = function()
                    if not armed then
                        -- First click: reopen the menu showing the confirm prompt.
                        pendingPromote = { name = altName, t = GetTime() }
                        C_Timer.After(0.05, function() OpenRowMenu(row) end)
                        return
                    end
                    pendingPromote = nil
                    local ok, newMain = ns.Credits_PromoteToMain(altName)
                    if ok then
                        ns.CreditsPrint(newMain .. " is now the main toon of that account.")
                        ns.CreditsConfig_Refresh()
                    end
                end },
                { text = "Discord", notCheckable = true, hasArrow = true,
                  menuList = DiscordSubmenu(altName, account, "alt", canManage) },
                { text = "Show Account", notCheckable = true, func = function()
                    pendingPromote = nil
                    if ns.Account_ShowFor then ns.Account_ShowFor(account) end
                end },
            })
        end
    end
    local function EnsureRowCount(n)
        for i = #rows + 1, n do
            local prevAnchor = rows[i - 1] or headerRow
            local row = CreateFrame("Frame", nil, content)
            row:SetHeight(16)
            row:SetPoint("RIGHT", content, "RIGHT", -16, 0)
            if i == 1 then
                row:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, -4)
            else
                row:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, -2)
            end

            -- Same right-to-left build as the header row above - see
            -- that block's comment. Rank first (fixed, far left), then
            -- Credits/Last Donation/Lifetime/Points/Tier chained off the
            -- row's own RIGHT edge, THEN Name last so it can anchor its
            -- own RIGHT to row.tier's LEFT (needs that cell to already
            -- exist).
            local function Cell(width)
                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetWidth(width)
                fs:SetJustifyH("LEFT")
                return fs
            end

            row.rank = Cell(RANK_WIDTH)
            row.rank:SetPoint("LEFT", 0, 0)

            row.credits = Cell(CREDITS_WIDTH)
            row.credits:SetPoint("RIGHT", row, "RIGHT", 0, 0)

            row.lastDonation = Cell(LASTDON_WIDTH)
            row.lastDonation:SetPoint("RIGHT", row.credits, "LEFT", -COL_GAP, 0)

            row.lifetime = Cell(LIFETIME_WIDTH)
            row.lifetime:SetPoint("RIGHT", row.lastDonation, "LEFT", -COL_GAP, 0)

            row.points = Cell(POINTS_WIDTH)
            row.points:SetPoint("RIGHT", row.lifetime, "LEFT", -COL_GAP, 0)

            row.tier = Cell(TIER_WIDTH)
            row.tier:SetPoint("RIGHT", row.points, "LEFT", -COL_GAP, 0)

            -- The stretch column, same trick as nameHeader above - no
            -- SetWidth/SetSize for width, just two anchors. This is what
            -- actually fixes the alt-name truncation Chris reported:
            -- it grows or shrinks with the window instead of sitting at
            -- a fixed number.
            local nameBtn = CreateFrame("Button", nil, row)
            nameBtn:SetHeight(16)
            nameBtn:SetPoint("LEFT", row.rank, "RIGHT", NAME_LEFT_GAP, 0)
            nameBtn:SetPoint("RIGHT", row.tier, "LEFT", -COL_GAP, 0)
            local nameLabel = nameBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            nameLabel:SetAllPoints()
            nameLabel:SetJustifyH("LEFT")
            nameBtn.label = nameLabel
            local nameHl = nameBtn:CreateTexture(nil, "HIGHLIGHT")
            nameHl:SetAllPoints()
            nameHl:SetColorTexture(1, 1, 1, 0.15)
            nameBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            nameBtn:SetScript("OnClick", function(_, button)
                if button == "RightButton" then
                    OpenRowMenu(row)
                elseif row.isExpandable and row.currentAccount then
                    HideMenu()
                    -- Toggle what is ON SCREEN (a search can auto-open an
                    -- account that was never explicitly expanded).
                    expanded[row.currentAccount] = not row.showAlts
                    if Refresh then Refresh() end
                end
            end)
            row.nameBtn = nameBtn

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
            elseif sortState.key == "rank" then
                -- Rank 1 = highest lifetime points, so "ascending" (rank 1
                -- first) is lifetime descending: compare the negatives.
                av, bv = -(a.lifetimePoints or 0), -(b.lifetimePoints or 0)
            elseif sortState.key == "credits" then
                av, bv = tonumber(a.credits) or 0, tonumber(b.credits) or 0
            elseif sortState.key == "lastDonationDate" then
                av, bv = a.lastDonationDate or "", b.lastDonationDate or ""
            else
                av, bv = (a.mainToon or ""):lower(), (b.mainToon or ""):lower()
            end
            if av ~= bv then
                if sortState.ascending then return av < bv else return av > bv end
            end
            return (a.mainToon or "") < (b.mainToon or "")
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
            return (a.mainToon or "") < (b.mainToon or "")
        end)
        local ranks = {}
        for i, rec in ipairs(list) do
            ranks[rec.discordName] = i
        end
        return ranks
    end

    -- The account's Discord name when it is NOT one of its characters
    -- (a "Discord only" entry), else nil.
    local function DiscordOnlyName(rec)
        local d = ns.Credits_GetDiscord(rec)
        if d == "" then return nil end
        local dl = d:lower()
        if rec.mainToon and rec.mainToon:lower() == dl then return nil end
        for _, a in ipairs(rec.alts or {}) do
            if a:lower() == dl then return nil end
        end
        return d
    end

    -- Role tag shown after a name: [Main] [Alt] [Discord] or the combined
    -- [Discord/Main] [Discord/Alt] when the character's name is also the
    -- account's Discord name.
    local function RoleTag(rec, name, role)
        local label
        if role == "discord" then
            label = "Discord"
        else
            local roleText = (role == "main") and "Main" or "Alt"
            label = ns.Credits_IsDiscordName(rec, name) and ("Discord/" .. roleText) or roleText
        end
        return " |cff8ea0c8[" .. label .. "]|r"
    end

    -- Interleaves each main with its alt sub-rows (only when expanded)
    -- into a single flat list the row pool renders in order.
    local function BuildDisplayList()
        local allMains = SortedLedger()
        -- Search filter (2026-10-06): applied BEFORE paging so it covers the
        -- whole roster. `autoOpen` = accounts that matched only through an
        -- alt / Discord name; they show their alts unless the user has
        -- explicitly collapsed them.
        local autoOpen
        local needle = filterState.text
        if needle ~= "" then
            local kept = {}
            autoOpen = {}
            for _, rec in ipairs(allMains) do
                local viaMain = (rec.mainToon or ""):lower():find(needle, 1, true) ~= nil
                local viaOther = false
                local d = ns.Credits_GetDiscord(rec)
                if d ~= "" and d:lower():find(needle, 1, true) then viaOther = true end
                if not viaOther then
                    for _, a in ipairs(rec.alts or {}) do
                        if a:lower():find(needle, 1, true) then viaOther = true break end
                    end
                end
                if viaMain or viaOther or (rec.discordName or ""):lower():find(needle, 1, true) then
                    kept[#kept + 1] = rec
                    if viaOther and not viaMain then autoOpen[rec.discordName] = true end
                end
            end
            allMains = kept
        end
        local totalPages = math.max(1, math.ceil(#allMains / ROSTER_MAINS_PER_PAGE))
        if pageState.page > totalPages then pageState.page = totalPages end
        if pageState.page < 1 then pageState.page = 1 end
        local pageStart = (pageState.page - 1) * ROSTER_MAINS_PER_PAGE
        local mains = {}
        for i = pageStart + 1, math.min(#allMains, pageStart + ROSTER_MAINS_PER_PAGE) do
            mains[#mains + 1] = allMains[i]
        end
        local display = {}
        for _, rec in ipairs(mains) do
            local alts = rec.alts
            local dOnly = DiscordOnlyName(rec)
            local hasAlts = (alts ~= nil and #alts > 0) or dOnly ~= nil
            local showAlts = expanded[rec.discordName]
            if showAlts == nil and autoOpen then showAlts = autoOpen[rec.discordName] end
            showAlts = (hasAlts and showAlts) and true or false
            table.insert(display, { kind = "main", rec = rec, hasAlts = hasAlts, discordOnly = dOnly, showAlts = showAlts })
            if showAlts then
                -- A Discord-only name (not a character) leads the sub-rows.
                if dOnly then
                    table.insert(display, { kind = "discord", name = dOnly, account = rec.discordName, rec = rec })
                end
                for _, altName in ipairs(alts or {}) do
                    table.insert(display, { kind = "alt", name = altName, account = rec.discordName, rec = rec })
                end
            end
        end
        return display, #allMains, totalPages
    end

    Refresh = function()
        local function HeaderText(btn, key)
            if sortState.key == key then
                btn.label:SetText(btn.baseText .. (sortState.ascending and " v" or " ^"))
            else
                btn.label:SetText(btn.baseText)
            end
        end
        HeaderText(nameHeader, "mainToon")
        HeaderText(rankHeader, "rank")
        HeaderText(tierHeader, "rank")
        HeaderText(pointsHeader, "rank")
        HeaderText(lifetimeHeader, "lifetimePoints")
        HeaderText(lastDonationHeader, "lastDonationDate")
        HeaderText(creditsHeader, "credits")

        if not ns.creditsDb then
            for _, row in ipairs(rows) do row:Hide() end
            return
        end

        local display, totalMains, totalPages = BuildDisplayList()
        pageLabel:SetText(("Page %d/%d (%d %s)"):format(pageState.page, totalPages, totalMains,
            filterState.text ~= "" and "matching" or "total"))
        if ns.Credits_CanAddRosterNamesLocal and ns.Credits_CanAddRosterNamesLocal() then
            addBtn:Enable()
        else
            addBtn:Disable()
        end
        if pageState.page <= 1 then prevPageBtn:Disable() else prevPageBtn:Enable() end
        if pageState.page >= totalPages then nextPageBtn:Disable() else nextPageBtn:Enable() end
        botPageLabel:SetText(pageLabel:GetText())
        if pageState.page <= 1 then botPrevBtn:Disable() else botPrevBtn:Enable() end
        if pageState.page >= totalPages then botNextBtn:Disable() else botNextBtn:Enable() end
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
                    row.showAlts = entry.showAlts
                    row.entryKind, row.altName, row.altAccount = "main", nil, nil
                    row.discordName = nil
                    row.mainName = rec.mainToon
                    row.currentAccount = rec.discordName
                    row.rank:SetText(tostring(ranks[rec.discordName] or "?"))
                    local marker = entry.hasAlts and (entry.showAlts and "[-] " or "[+] ") or "      "
                    row.nameBtn.label:SetText(marker .. (rec.mainToon or "?")
                        .. RoleTag(rec, rec.mainToon, "main")
                        .. (entry.discordOnly and (" |cff7289da(Discord: " .. entry.discordOnly .. ")|r") or ""))
                    row.nameBtn:EnableMouse(true) -- left = expand (if alts), right = menu
                    local tierText = rec.tier or "?"
                    if (rec.prestige or 0) > 0 then
                        tierText = tierText .. " P" .. tostring(rec.prestige)
                    end
                    row.tier:SetText(tierText)
                    local cap = ns.CreditsTierCaps and ns.CreditsTierCaps[rec.tier]
                    -- Lifetime and credits show two decimals (2026-10-04,
                    -- Loopi; stored values keep four); tier points stay whole.
                    local curPts = math.floor((tonumber(rec.points) or 0) + 0.5)
                    if cap then
                        row.points:SetText(("%d/%d"):format(curPts, cap))
                    else
                        row.points:SetText(tostring(curPts))
                    end
                    row.lifetime:SetText(("%.2f"):format(tonumber(rec.lifetimePoints) or 0))
                    row.lastDonation:SetText((rec.lastDonationDate and rec.lastDonationDate ~= "") and rec.lastDonationDate or "-")
                    row.credits:SetText(("%.2f"):format(tonumber(rec.credits) or 0))
                else
                    row.isExpandable = false
                    row.currentAccount = nil
                    local isDiscordRow = entry.kind == "discord"
                    if isDiscordRow then
                        row.entryKind, row.altName, row.altAccount = "discord", nil, entry.account
                        row.discordName = entry.name
                    else
                        row.entryKind, row.altName, row.altAccount = "alt", entry.name, entry.account
                        row.discordName = nil
                    end
                    row.mainName = nil
                    row.rank:SetText("")
                    row.nameBtn.label:SetText("      - " .. (entry.name or "?")
                        .. RoleTag(entry.rec, entry.name, isDiscordRow and "discord" or "alt"))
                    row.nameBtn:EnableMouse(true) -- right-click menu only
                    row.tier:SetText("")
                    row.points:SetText("")
                    row.lifetime:SetText("")
                    row.lastDonation:SetText("")
                    row.credits:SetText("")
                end
            end
        end

        local bottom = GetBottomAnchor()
        botPrevBtn:ClearAllPoints()
        botPrevBtn:SetPoint("TOPLEFT", bottom, "BOTTOMLEFT", -2, -10)
        local top, bot = content:GetTop(), bottom:GetBottom()
        if top and bot then
            -- +40: the bottom pager (10 gap + 20 tall) plus the usual margin.
            content:SetHeight(math.max(200, top - bot + 40))
        end
    end

    local function SetSort(key, defaultAscending)
        if sortState.key == key then
            sortState.ascending = not sortState.ascending
        else
            sortState.key = key
            sortState.ascending = defaultAscending
        end
        pageState.page = 1 -- a new order starts from the top
        Refresh()
    end
    -- Shared by the top and bottom pagers. Always returns to the top of the
    -- list so the new page starts at its first row, whichever pager was used.
    local function ChangePage(delta)
        pageState.page = pageState.page + delta
        Refresh()
        local sf = content:GetParent()
        if sf and sf.SetVerticalScroll then sf:SetVerticalScroll(0) end
    end
    prevPageBtn:SetScript("OnClick", function() ChangePage(-1) end)
    nextPageBtn:SetScript("OnClick", function() ChangePage(1) end)
    botPrevBtn:SetScript("OnClick", function() ChangePage(-1) end)
    botNextBtn:SetScript("OnClick", function() ChangePage(1) end)
    nameHeader:SetScript("OnClick", function() SetSort("mainToon", true) end)
    rankHeader:SetScript("OnClick", function() SetSort("rank", true) end)
    tierHeader:SetScript("OnClick", function() SetSort("rank", true) end)
    pointsHeader:SetScript("OnClick", function() SetSort("rank", true) end)
    creditsHeader:SetScript("OnClick", function() SetSort("credits", false) end)
    lifetimeHeader:SetScript("OnClick", function() SetSort("lifetimePoints", false) end)
    lastDonationHeader:SetScript("OnClick", function() SetSort("lastDonationDate", false) end)

    -- Search box + Add name button (2026-10-06, Loopi).
    filterEdit:SetScript("OnTextChanged", function(self)
        local t = (self:GetText() or ""):match("^%s*(.-)%s*$"):lower()
        if t == filterState.text then return end
        filterState.text = t
        pageState.page = 1
        Refresh()
    end)
    addBtn:SetScript("OnClick", function() ShowAddDialog() end)

    return Refresh
end

--------------------------------------------------------------------------
-- Review Queue tab (CM2, renamed from "Conflicts" 2026-09-25 - Chris:
-- "\"Conflicts\" ... is a terrible name ... it is not conflicts - only
-- unresolved data"). Combines Step 0's static unresolved/ambiguous
-- donor names (ReviewQueue.lua, GENERATED from review-queue.csv) with
-- any names Credits_UnlinkAlt has sent back here at runtime
-- (ns.creditsDb.dynamicReviewQueue - Loopi, 2026-09-25: "When an alt is
-- removed - it should go back into the review queue so it can be
-- re-associated with the correct main"), via Credits.lua's
-- ns.Credits_ReviewQueueRows(). Sortable by Name and by Latest Donation
-- date, filterable by typed substring, with a per-row manual-link
-- control that writes straight into the live ledger
-- (ns.Credits_LinkAlt/UnlinkAlt, Credits.lua - Identity model v2). The
-- static half of the source list doesn't shrink here - only the next
-- Step 0 + import-review-queue.ps1 pass changes it - but a row still
-- reflects its live resolved state (linked-as-alt, or promoted to its
-- own account) immediately.
--------------------------------------------------------------------------
local function BuildReviewQueueTab(content)
    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Review Queue")

    local hint = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Donor names that aren't tied to an account yet - either Step 0 couldn't map them as of its last run, or an officer removed them from an account's alt list. Linking or setting as a new main here is Distribution Officer only and takes effect immediately for live crediting. \"New Main\" seeds the row's real historical lifetime total (raw gold x10, same convention as everywhere else). A \"held donation\" row is someone who mailed a donation but isn't on any account or in the guild: their rep and credits are held and are applied automatically (on the mail recipient's client) as soon as you link them or make them a new main. An \"archived donor\" row is a name that also appears in the pre-reseed archive: the new donation is held until you press Confirm (it is them - their earlier history is carried over once) or Not them (a different person - nothing is carried over); linking or New Main also counts as confirming.")

    local filterLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterLabel:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", -2, -12)
    filterLabel:SetText("Filter:")

    local filterEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    filterEdit:SetSize(140, 20)
    filterEdit:SetPoint("LEFT", filterLabel, "RIGHT", 8, -2)
    filterEdit:SetAutoFocus(false)
    filterEdit:SetMaxLetters(24)
    filterEdit:SetScript("OnEscapePressed", filterEdit.ClearFocus)

    -- Names an officer has already dealt with (linked as an alt, or made
    -- their own main) are hidden by default so the list shows only real
    -- work; "Show resolved" brings them back - that's also where an
    -- officer goes to Unlink a wrong link (2026-09-29, Loopi). Session
    -- only; it always starts unchecked.
    local showResolved = false
    local resolvedCheck = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    resolvedCheck:SetSize(24, 24)
    resolvedCheck:SetPoint("LEFT", filterEdit, "RIGHT", 12, 2)
    resolvedCheck:SetChecked(false)
    local resolvedLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    resolvedLabel:SetPoint("LEFT", resolvedCheck, "RIGHT", 2, 0)
    resolvedLabel:SetText("Show resolved")

    -- 2026-10-06 (Loopi): post the unclaimed names to /guild so members can
    -- claim them. Only the author, guild leader and donation recipient see
    -- the button (Credits.lua's Credits_CanPostReviewQueueLocal); it asks
    -- first, since it speaks in guild chat.
    StaticPopupDialogs["DHBAVIN_QUEUEPOST_CONFIRM"] = {
        text = "Post %s unclaimed donor names to guild chat in %s message(s)?",
        button1 = "Post",
        button2 = CANCEL or "Cancel",
        OnAccept = function()
            local ok, a, b = ns.Credits_PostReviewQueueToGuild()
            if ok then
                ns.CreditsPrint(("Posted %d names to /guild in %d message(s)."):format(b, a))
            elseif a == "empty" then
                ns.CreditsPrint("Nothing to post - no unclaimed names in the Review Queue.")
            else
                ns.CreditsPrint("Refused - only the author, guild leader or donation recipient can post, from a Death Happens character.")
            end
        end,
        timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
    }
    local postBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    postBtn:SetSize(130, 20)
    postBtn:SetPoint("TOPRIGHT", content, "TOPRIGHT", -16, -16)
    postBtn:SetText("Post to guild chat")
    postBtn:SetScript("OnClick", function()
        local names = ns.Credits_UnclaimedQueueNames()
        if #names == 0 then
            ns.CreditsPrint("Nothing to post - no unclaimed names in the Review Queue.")
            return
        end
        StaticPopup_Show("DHBAVIN_QUEUEPOST_CONFIRM", tostring(#names), tostring(#ns.Credits_BuildQueuePosts(names)))
    end)
    postBtn:Hide()

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

    -- Type-ahead suggestions for the "Link to:" box (2026-09-25, Chris:
    -- narrow the field as you type instead of typing a full name blind).
    -- ONE shared popup, repositioned under whichever row's linkEdit
    -- currently has focus, rather than one per row (there can be dozens
    -- of rows on a page). Parented to the top-level `frame`, not this
    -- tab's scrolling content, so it draws above the row list and is
    -- never clipped by the ScrollFrame's own viewport.
    local SUGGEST_MAX = 8
    local suggestBox = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    suggestBox:SetFrameStrata("TOOLTIP")
    suggestBox:SetWidth(150)
    suggestBox:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    suggestBox:SetBackdropColor(0, 0, 0, 0.9)
    suggestBox:Hide()

    local suggestButtons = {}
    for i = 1, SUGGEST_MAX do
        local btn = CreateFrame("Button", nil, suggestBox)
        btn:SetHeight(16)
        btn:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 16)
        btn:SetPoint("RIGHT", -4, 0)
        local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetAllPoints()
        label:SetJustifyH("LEFT")
        btn.label = label
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.2)
        btn:Hide()
        suggestButtons[i] = btn
    end

    -- Candidates are every account's CURRENT mainToon (Identity model
    -- v2) - never an alt name, since this box's whole job is picking
    -- which MAIN to link to. Re-scanned on every keystroke rather than
    -- cached - the ledger is small enough (hundreds, not thousands of
    -- rows) that this isn't worth extra bookkeeping.
    local function MainToonCandidates(typed)
        local matches = {}
        if typed == "" or not ns.creditsDb or not ns.creditsDb.ledger then return matches end
        local needle = typed:lower()
        for _, rec in pairs(ns.creditsDb.ledger) do
            if rec.mainToon and rec.mainToon:lower():find(needle, 1, true) then
                table.insert(matches, rec.mainToon)
                if #matches >= SUGGEST_MAX then break end
            end
        end
        table.sort(matches)
        return matches
    end

    local function HideSuggestions()
        suggestBox:Hide()
    end

    local function UpdateSuggestions(editBox)
        local matches = MainToonCandidates(editBox:GetText() or "")
        if #matches == 0 then
            HideSuggestions()
            return
        end
        suggestBox:ClearAllPoints()
        suggestBox:SetPoint("TOPLEFT", editBox, "BOTTOMLEFT", 0, -2)
        suggestBox:SetHeight(8 + #matches * 16)
        for i, btn in ipairs(suggestButtons) do
            local name = matches[i]
            if name then
                btn.label:SetText(name)
                btn:SetScript("OnClick", function()
                    editBox:SetText(name)
                    editBox:ClearFocus()
                    HideSuggestions()
                end)
                btn:Show()
            else
                btn:Hide()
            end
        end
        suggestBox:Show()
    end

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
            row.linkEdit:SetScript("OnEscapePressed", function(self)
                HideSuggestions()
                self:ClearFocus()
            end)
            row.linkEdit:SetScript("OnTextChanged", function(self) UpdateSuggestions(self) end)
            row.linkEdit:SetScript("OnEditFocusGained", function(self) UpdateSuggestions(self) end)
            -- A click on a suggestion button is itself a focus-loss event
            -- for the edit box, which would otherwise hide the popup
            -- before the button's own OnClick runs. Deferring one frame
            -- lets that click land first.
            row.linkEdit:SetScript("OnEditFocusLost", function()
                C_Timer.After(0.15, HideSuggestions)
            end)

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

            -- Archived-donor rows (issue "archived_donor"): the donation is
            -- held until an officer says whether this is the same person as
            -- the archived (pre-reseed) donor. Confirm = yes, apply their
            -- earlier history; Not them = no, never carry it over. Both
            -- release the held donation.
            row.confirmBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.confirmBtn:SetSize(70, 18)
            row.confirmBtn:SetPoint("TOPLEFT", row.info, "BOTTOMLEFT", 0, -4)
            row.confirmBtn:SetText("Confirm")

            row.declineBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.declineBtn:SetSize(70, 18)
            row.declineBtn:SetText("Not them")

            row.archStatus = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.archStatus:SetPoint("LEFT", row.declineBtn, "RIGHT", 6, 0)

            row.confirmBtn:Hide()
            row.declineBtn:Hide()

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
        local hiddenResolved = 0
        local toonIndex = ns.creditsDb and ns.creditsDb.toonIndex or {}
        local source = (ns.Credits_ReviewQueueRows and ns.Credits_ReviewQueueRows()) or ns.CreditsReviewQueue or {}
        for _, rec in ipairs(source) do
            if typed == "" or (rec.name or ""):lower():find(typed, 1, true) then
                -- resolved = the name now belongs to an account (alt OR main)
                -- An archived-donor row is pending work even once the name is
                -- on an account (that is exactly when Confirm shows), so it is
                -- never hidden as "resolved".
                if not showResolved and rec.issue ~= "archived_donor" and toonIndex[(rec.name or ""):lower()] then
                    hiddenResolved = hiddenResolved + 1
                else
                    table.insert(list, rec)
                end
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
        return list, hiddenResolved
    end

    local function Refresh()
        sortNameBtn:SetText(sortState.key == "name" and (sortState.ascending and "Name v" or "Name ^") or "Name")
        sortDateBtn:SetText(sortState.key == "latestDonation" and (sortState.ascending and "Latest Donation v" or "Latest Donation ^") or "Latest Donation")

        local canManage = ns.CanManageCreditsConfigLocal and ns.CanManageCreditsConfigLocal() or false
        if ns.Credits_CanPostReviewQueueLocal and ns.Credits_CanPostReviewQueueLocal() then postBtn:Show() else postBtn:Hide() end
        local list, hiddenResolved = FilteredSortedRows()
        if showResolved then
            resolvedLabel:SetText("Show resolved")
        else
            resolvedLabel:SetText(("Show resolved (%d hidden)"):format(hiddenResolved))
        end

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
                local tag
                if rec.issue == "identity_conflict" then
                    tag = "|cffffcc00conflict|r"
                elseif rec.issue == "removed_alt" then
                    tag = "|cff66ccffremoved alt|r"
                elseif rec.issue == "unresolved_donor" then
                    -- CM4: a donation from this name is being HELD until an
                    -- officer links them (or makes them a new main).
                    tag = "|cffff9933held donation|r"
                elseif rec.issue == "archived_donor" then
                    -- Name matches a donor from before the reseed; their
                    -- donation is held until an officer confirms it is them.
                    tag = "|cffff66ccarchived donor|r"
                else
                    tag = "|cff999999unmapped|r"
                end
                local dateText = (rec.latestDonation and rec.latestDonation ~= "") and rec.latestDonation or "no date"
                local heldText = ""
                if (rec.issue == "unresolved_donor" or rec.issue == "archived_donor") and ns.CreditsDon_HeldTotals then
                    local heldRep, heldCredits = ns.CreditsDon_HeldTotals(rec.name)
                    heldText = (" - holding |cffffd100%s rep / %s credits|r"):format(
                        ns.CreditsDon_Fmt(heldRep), ns.CreditsDon_Fmt(heldCredits))
                end
                row.info:SetText(("%s  (%s, last donation %s)%s"):format(rec.name or "?", tag, dateText, heldText))

                -- Resolved either as an alt of another account
                -- (Credits_GetAltMain) or as its own account (a
                -- toonIndex hit that Credits_GetAltMain deliberately
                -- excludes - see Credits.lua). Only the alt case gets
                -- an Unlink button here; un-doing a "New Main" account
                -- is deferred to the future unified account editor.
                local linkedMain = ns.Credits_GetAltMain and ns.Credits_GetAltMain(rec.name) or nil
                local isOwnMain = false
                if not linkedMain and ns.creditsDb and ns.creditsDb.toonIndex then
                    isOwnMain = ns.creditsDb.toonIndex[(rec.name or ""):lower()] ~= nil
                end
                -- Archived-donor rows: reset the extra controls, then show
                -- Confirm / Not them (placeable) or Link / New Main plus
                -- Not them (not placeable yet - linking or New Main also
                -- settles it and releases the donation).
                row.confirmBtn:Hide()
                row.declineBtn:Hide()
                row.archStatus:SetText("")
                local isArchived = rec.issue == "archived_donor"
                local archPlaceable = isArchived and ns.CreditsDon_ArchivedPlaceable
                    and ns.CreditsDon_ArchivedPlaceable(rec.name) or false
                local function ArchResult(ok, reason)
                    if ok then
                        ns.CreditsConfig_Refresh()
                    else
                        row.archStatus:SetText("|cffff3333" .. tostring(reason or "Refused") .. "|r")
                        C_Timer.After(3, function() row.archStatus:SetText("") end)
                    end
                end
                if isArchived and archPlaceable then
                    row.linkedText:Hide()
                    row.unlinkBtn:Hide()
                    row.linkArrow:Hide()
                    row.linkEdit:Hide()
                    row.linkBtn:Hide()
                    row.setMainBtn:Hide()
                    row.status:Hide()
                    row.declineBtn:ClearAllPoints()
                    row.declineBtn:SetPoint("LEFT", row.confirmBtn, "RIGHT", 6, 0)
                    row.confirmBtn:Show()
                    row.declineBtn:Show()
                    if canManage then row.confirmBtn:Enable() else row.confirmBtn:Disable() end
                    if canManage then row.declineBtn:Enable() else row.declineBtn:Disable() end
                    row.confirmBtn:SetScript("OnClick", function()
                        ArchResult(ns.Credits_ConfirmArchived(rec.name))
                    end)
                    row.declineBtn:SetScript("OnClick", function()
                        ArchResult(ns.Credits_DeclineArchived(rec.name))
                    end)
                elseif linkedMain then
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
                        if ns.Credits_UnlinkAlt(rec.name) then
                            ns.CreditsConfig_Refresh()
                        end
                    end)
                elseif isOwnMain then
                    row.linkedText:SetText("|cff33ff99Own main|r")
                    row.linkedText:Show()
                    row.unlinkBtn:Hide()
                    row.linkArrow:Hide()
                    row.linkEdit:Hide()
                    row.linkBtn:Hide()
                    row.setMainBtn:Hide()
                    row.status:Hide()
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
                    if isArchived then
                        row.declineBtn:ClearAllPoints()
                        row.declineBtn:SetPoint("LEFT", row.setMainBtn, "RIGHT", 70, 0)
                        row.declineBtn:Show()
                        if canManage then row.declineBtn:Enable() else row.declineBtn:Disable() end
                        row.declineBtn:SetScript("OnClick", function()
                            ArchResult(ns.Credits_DeclineArchived(rec.name))
                        end)
                    end
                    row.linkBtn:SetScript("OnClick", function()
                        local typedMain = row.linkEdit:GetText()
                        row.linkEdit:ClearFocus()
                        HideSuggestions()
                        if typedMain == "" then return end
                        if ns.Credits_LinkAlt(rec.name, typedMain) then
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
    resolvedCheck:SetScript("OnClick", function(self)
        showResolved = self:GetChecked() and true or false
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
-- Audit Log tab (CM7, processor view - 2026-10-04, Loopi: "code the audit
-- log viewer next, with filters and sorting"). All the row/filter/sort/
-- tooltip/export LOGIC is in CreditsLog.lua (harness-tested); this is only
-- the widgets. It shows what THIS client's transaction log holds - on the
-- mail recipient's client that is every donation, held-donation release and
-- merge it processed; officers' copies come with a later replication step.
--------------------------------------------------------------------------
local AUDIT_ROWS_PER_PAGE = 25

local AUDIT_COLUMNS = {
    { key = "date",    label = "Date",    width = 92,  side = "left" },
    { key = "kind",    label = "Kind",    width = 60,  side = "left" },
    { key = "who",     label = "Who",     width = 150, side = "left" },
    { key = "what",    label = "What",    flex = true },
    { key = "rep",     label = "Rep",     width = 64,  side = "right", justify = "RIGHT" },
    { key = "credits", label = "Credits", width = 64,  side = "right", justify = "RIGHT" },
    { key = "tier",    label = "Tier",    width = 78,  side = "right" },
    { key = "by",      label = "By",      width = 72,  side = "right" },
}

-- Columns that read best newest/biggest first the first time they are clicked.
local AUDIT_DESC_FIRST = { date = true, rep = true, credits = true, tier = true }

local AUDIT_RANGES = {
    { label = "All time", days = nil },
    { label = "Last 7 days", days = 7 },
    { label = "Last 30 days", days = 30 },
    { label = "Last 90 days", days = 90 },
}

local AUDIT_KIND_COLORS = {
    released = "|cff66ccff", merge = "|cffffd100", spend = "|cffff9933",
}

-- Anchors one cell per column inside `parent` (left columns chain from the
-- left edge, right columns from the right edge, the flexible one fills the
-- gap) - `make(col)` creates the widget. Same layout for the header buttons
-- and for every row, so they always line up.
local function AuditPlaceCells(parent, make)
    local cells = {}
    local prevLeft, prevRight
    for _, col in ipairs(AUDIT_COLUMNS) do
        if col.side == "left" then
            local c = make(col)
            c:SetWidth(col.width)
            if prevLeft then c:SetPoint("TOPLEFT", prevLeft, "TOPRIGHT", 4, 0)
            else c:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0) end
            prevLeft = c
            cells[col.key] = c
        end
    end
    for i = #AUDIT_COLUMNS, 1, -1 do
        local col = AUDIT_COLUMNS[i]
        if col.side == "right" then
            local c = make(col)
            c:SetWidth(col.width)
            if prevRight then c:SetPoint("TOPRIGHT", prevRight, "TOPLEFT", -4, 0)
            else c:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0) end
            prevRight = c
            cells[col.key] = c
        end
    end
    for _, col in ipairs(AUDIT_COLUMNS) do
        if col.flex then
            local c = make(col)
            c:SetPoint("TOPLEFT", prevLeft, "TOPRIGHT", 4, 0)
            c:SetPoint("TOPRIGHT", prevRight, "TOPLEFT", -4, 0)
            cells[col.key] = c
        end
    end
    return cells
end

-- One shared copy/paste box for the export (WoW can't write files).
local auditExportFrame
local function ShowAuditExport(text)
    if not auditExportFrame then
        local f = CreateFrame("Frame", "DHBavinAuditExportFrame", UIParent, "BasicFrameTemplateWithInset")
        f:SetSize(640, 420)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        if f.TitleText then f.TitleText:SetText("Audit Log export") end
        tinsert(UISpecialFrames, "DHBavinAuditExportFrame")

        local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("TOPLEFT", 14, -32)
        hint:SetPoint("RIGHT", -14, 0)
        hint:SetJustifyH("LEFT")
        hint:SetText("The rows currently shown (filtered and sorted), as CSV. Everything is selected - press Ctrl+C, then paste into a text file or spreadsheet.")

        local sf = CreateFrame("ScrollFrame", "DHBavinAuditExportScroll", f, (DHTools and DHTools.SCROLL_TEMPLATE) or "UIPanelScrollFrameTemplate")
        if DHTools and DHTools.SkinScrollBar then DHTools.SkinScrollBar(sf) end
        sf:SetPoint("TOPLEFT", 14, -62)
        sf:SetPoint("BOTTOMRIGHT", -34, 14)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
        eb:SetMaxLetters(0)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        sf:SetScrollChild(eb)
        f.scroll, f.edit = sf, eb
        auditExportFrame = f
    end
    local f = auditExportFrame
    f:Show()
    f:Raise()
    f.edit:SetWidth(math.max(100, f.scroll:GetWidth() - 6))
    f.edit:SetText(text)
    local lines = 1
    for _ in text:gmatch("\n") do lines = lines + 1 end
    f.edit:SetHeight(math.max(f.scroll:GetHeight(), lines * 14 + 8))
    f.scroll:SetVerticalScroll(0)
    f.edit:SetFocus()
    f.edit:HighlightText()
end

local function BuildAuditTab(content)
    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Audit Log")

    local hint = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Every donation, held-donation release and account merge recorded by this character, newest first. Click a column title to sort, click it again to reverse. Hover a row for the item breakdown, the rates used and who processed it. This shows what THIS character recorded - officers' own copies come with a later update.")

    local filterLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterLabel:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", -2, -12)
    filterLabel:SetText("Filter:")

    local filterEdit = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    filterEdit:SetSize(150, 20)
    filterEdit:SetPoint("LEFT", filterLabel, "RIGHT", 8, -2)
    filterEdit:SetAutoFocus(false)
    filterEdit:SetMaxLetters(30)
    filterEdit:SetScript("OnEscapePressed", filterEdit.ClearFocus)

    -- Cycle buttons: one click moves to the next value (simplest widget that
    -- is robust across client versions; no dropdown frames to keep alive).
    local kindValue, byValue, rangeIdx = "", "", 1
    local tierUpOnly = false

    local kindBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    kindBtn:SetSize(120, 20)
    kindBtn:SetPoint("LEFT", filterEdit, "RIGHT", 10, 2)
    local rangeBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    rangeBtn:SetSize(130, 20)
    rangeBtn:SetPoint("LEFT", kindBtn, "RIGHT", 6, 0)
    local byBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    byBtn:SetSize(140, 20)
    byBtn:SetPoint("LEFT", rangeBtn, "RIGHT", 6, 0)

    local tierCheck = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    tierCheck:SetSize(24, 24)
    tierCheck:SetPoint("TOPLEFT", filterLabel, "BOTTOMLEFT", -2, -10)
    tierCheck:SetChecked(false)
    local tierLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tierLabel:SetPoint("LEFT", tierCheck, "RIGHT", 2, 0)
    tierLabel:SetText("Tier-ups only")

    local exportBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    exportBtn:SetSize(130, 20)
    exportBtn:SetPoint("LEFT", tierLabel, "RIGHT", 16, 0)
    exportBtn:SetText("Export shown rows")

    local prevPageBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    prevPageBtn:SetSize(60, 20)
    prevPageBtn:SetPoint("LEFT", exportBtn, "RIGHT", 20, 0)
    prevPageBtn:SetText("< Prev")
    local pageLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageLabel:SetPoint("LEFT", prevPageBtn, "RIGHT", 8, 0)
    local nextPageBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    nextPageBtn:SetSize(60, 20)
    nextPageBtn:SetPoint("LEFT", pageLabel, "RIGHT", 8, 0)
    nextPageBtn:SetText("Next >")

    local sortState = { key = "date", ascending = false }
    local pageState = { page = 1 }

    local header = CreateFrame("Frame", nil, content)
    header:SetHeight(22)
    header:SetPoint("TOPLEFT", tierCheck, "BOTTOMLEFT", 2, -10)
    header:SetPoint("RIGHT", content, "RIGHT", -16, 0)
    local headerBtns = AuditPlaceCells(header, function(col)
        local b = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
        b:SetHeight(20)
        b.sortKey = col.key
        b.baseLabel = col.label
        b:SetScript("OnClick", function()
            if sortState.key == col.key then
                sortState.ascending = not sortState.ascending
            else
                sortState.key = col.key
                sortState.ascending = not AUDIT_DESC_FIRST[col.key]
            end
            pageState.page = 1
            ns.CreditsConfig_Refresh()
        end)
        return b
    end)

    local emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    emptyText:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 6, -10)
    emptyText:Hide()

    local rows = {}
    local function EnsureRowCount(n)
        for i = #rows + 1, n do
            local row = CreateFrame("Button", nil, content)
            row:SetHeight(18)
            if i == 1 then row:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
            else row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, -2) end
            row:SetPoint("RIGHT", content, "RIGHT", -16, 0)
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.12)
            row.cells = AuditPlaceCells(row, function(col)
                local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetHeight(16)
                fs:SetWordWrap(false)
                fs:SetJustifyH(col.justify or "LEFT")
                return fs
            end)
            row:SetScript("OnEnter", function(self)
                if not self.logRow then return end
                local lines = ns.CreditsLog_TooltipLines(self.logRow)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                for li, l in ipairs(lines) do
                    if li == 1 then
                        GameTooltip:SetText(l[1], 1, 0.82, 0)
                    elseif l[2] and l[2] ~= "" then
                        GameTooltip:AddDoubleLine(l[1], l[2], 0.8, 0.8, 0.8, 1, 1, 1)
                    else
                        GameTooltip:AddLine(l[1], 1, 1, 1)
                    end
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row:Hide()
            rows[i] = row
        end
    end

    local function Now()
        return (GetServerTime and GetServerTime()) or time()
    end

    -- Cycles `current` through { "" , ...options } and returns the next value.
    local function NextOf(current, options)
        local idx = 0
        for i, v in ipairs(options) do if v == current then idx = i break end end
        return options[(idx % #options) + 1]
    end

    -- Drop-down list under the clicked filter button (2026-10-04, Loopi: the
    -- filter buttons "should be drop down lists", not rotate through the
    -- choices). Same vendored dropdown library + EasyMenu-at-the-cursor idiom
    -- as the Roster right-click menu (the proven path in this client); if the
    -- library is somehow missing it falls back to cycling.
    -- choices = { { value = , label = }, ... }; onPick(value) applies it.
    local LibDropDown = LibStub and LibStub("LibUIDropDownMenuDHTools-4.0", true)
    local choiceMenuFrame
    local function OpenChoiceMenu(choices, current, onPick)
        if not LibDropDown then
            local idx = 0
            for i, c in ipairs(choices) do if c.value == current then idx = i break end end
            onPick(choices[(idx % #choices) + 1].value)
            return
        end
        if not choiceMenuFrame then
            choiceMenuFrame = LibDropDown:Create_UIDropDownMenu("DHBavinAuditChoiceMenuFrame", UIParent)
        end
        local entries = {}
        for _, c in ipairs(choices) do
            entries[#entries + 1] = {
                text = c.label,
                checked = (c.value == current),
                func = function() onPick(c.value) end,
            }
        end
        LibDropDown:EasyMenu(entries, choiceMenuFrame, "cursor", 0, 0, "MENU", 2)
    end

    local lastShown = {} -- the filtered+sorted rows, for the export button

    local function Refresh()
        local all = ns.CreditsLog_Rows()
        local kindOptions = { "" }
        for _, k in ipairs(ns.CreditsLog_KindsPresent(all)) do kindOptions[#kindOptions + 1] = k end
        local byOptions = { "" }
        for _, n in ipairs(ns.CreditsLog_Distinct(all, "by")) do byOptions[#byOptions + 1] = n end
        -- A previously chosen value that no longer occurs falls back to "all".
        local function Known(v, opts) for _, o in ipairs(opts) do if o == v then return true end end return false end
        if not Known(kindValue, kindOptions) then kindValue = "" end
        if not Known(byValue, byOptions) then byValue = "" end

        kindBtn:SetText("Kind: " .. (kindValue == "" and "All" or (ns.CreditsLog_KindLabels[kindValue] or kindValue)) .. "  v")
        rangeBtn:SetText(AUDIT_RANGES[rangeIdx].label .. "  v")
        byBtn:SetText("By: " .. (byValue == "" and "Anyone" or byValue) .. "  v")
        kindBtn:SetScript("OnClick", function()
            local choices = { { value = "", label = "All kinds" } }
            for i = 2, #kindOptions do
                choices[#choices + 1] = { value = kindOptions[i], label = ns.CreditsLog_KindLabels[kindOptions[i]] or kindOptions[i] }
            end
            OpenChoiceMenu(choices, kindValue, function(v) kindValue = v; pageState.page = 1; ns.CreditsConfig_Refresh() end)
        end)
        byBtn:SetScript("OnClick", function()
            local choices = { { value = "", label = "Anyone" } }
            for i = 2, #byOptions do choices[#choices + 1] = { value = byOptions[i], label = byOptions[i] } end
            OpenChoiceMenu(choices, byValue, function(v) byValue = v; pageState.page = 1; ns.CreditsConfig_Refresh() end)
        end)

        local days = AUDIT_RANGES[rangeIdx].days
        local list = ns.CreditsLog_Filter(all, {
            kind = kindValue ~= "" and kindValue or nil,
            by = byValue ~= "" and byValue or nil,
            since = days and (Now() - days * 86400) or nil,
            text = filterEdit:GetText() or "",
            tierUpOnly = tierUpOnly,
        })
        ns.CreditsLog_Sort(list, sortState.key, sortState.ascending)
        lastShown = list

        for key, btn in pairs(headerBtns) do
            local arrow = ""
            if sortState.key == key then arrow = sortState.ascending and " v" or " ^" end
            btn:SetText(btn.baseLabel .. arrow)
        end

        local totalPages = math.max(1, math.ceil(#list / AUDIT_ROWS_PER_PAGE))
        if pageState.page > totalPages then pageState.page = totalPages end
        if pageState.page < 1 then pageState.page = 1 end
        local pageStart = (pageState.page - 1) * AUDIT_ROWS_PER_PAGE
        local shown = math.min(AUDIT_ROWS_PER_PAGE, #list - pageStart)
        pageLabel:SetText(("Page %d/%d  (%d of %d entries)"):format(pageState.page, totalPages, #list, #all))
        if pageState.page <= 1 then prevPageBtn:Disable() else prevPageBtn:Enable() end
        if pageState.page >= totalPages then nextPageBtn:Disable() else nextPageBtn:Enable() end
        if #list == 0 then exportBtn:Disable() else exportBtn:Enable() end

        EnsureRowCount(math.max(shown, 0))
        for i, row in ipairs(rows) do
            local r = (i <= shown) and list[pageStart + i] or nil
            if not r then
                row.logRow = nil
                row:Hide()
            else
                row.logRow = r
                local c = row.cells
                c.date:SetText(ns.CreditsLog_FormatDate(r.ts))
                c.kind:SetText((AUDIT_KIND_COLORS[r.kind] or "") .. r.kindLabel .. (AUDIT_KIND_COLORS[r.kind] and "|r" or ""))
                c.who:SetText(r.who)
                c.what:SetText(r.what)
                c.rep:SetText(ns.CreditsDon_Fmt(r.rep))
                c.credits:SetText(ns.CreditsDon_Fmt(r.credits))
                c.tier:SetText(r.tierUp and ("|cffffd100" .. r.tier .. " ^|r") or r.tier)
                c.by:SetText(r.by or "")
                row:Show()
            end
        end

        if #all == 0 then
            emptyText:SetText("Nothing recorded yet by this character.")
            emptyText:Show()
        elseif #list == 0 then
            emptyText:SetText("No entries match the current filters.")
            emptyText:Show()
        else
            emptyText:Hide()
        end

        local bottom = header
        for i = #rows, 1, -1 do
            if rows[i]:IsShown() then bottom = rows[i] break end
        end
        local top, bot = content:GetTop(), bottom:GetBottom()
        if top and bot then
            content:SetHeight(math.max(260, top - bot + 40))
        end
    end

    filterEdit:SetScript("OnTextChanged", function()
        pageState.page = 1
        ns.CreditsConfig_Refresh()
    end)
    rangeBtn:SetScript("OnClick", function()
        local choices = {}
        for i, r in ipairs(AUDIT_RANGES) do choices[#choices + 1] = { value = i, label = r.label } end
        OpenChoiceMenu(choices, rangeIdx, function(v) rangeIdx = v; pageState.page = 1; ns.CreditsConfig_Refresh() end)
    end)
    tierCheck:SetScript("OnClick", function(self)
        tierUpOnly = self:GetChecked() and true or false
        pageState.page = 1
        ns.CreditsConfig_Refresh()
    end)
    prevPageBtn:SetScript("OnClick", function() pageState.page = pageState.page - 1; ns.CreditsConfig_Refresh() end)
    nextPageBtn:SetScript("OnClick", function() pageState.page = pageState.page + 1; ns.CreditsConfig_Refresh() end)
    exportBtn:SetScript("OnClick", function()
        ShowAuditExport(ns.CreditsLog_ExportText(lastShown))
    end)

    return Refresh
end

--------------------------------------------------------------------------
-- Frame construction (built once, first time the window is opened)
--------------------------------------------------------------------------
local TAB_DEFS = {
    { key = "settings",    label = "Settings" },
    { key = "roster",      label = "Roster" },
    { key = "reviewQueue", label = "Review Queue" },
    { key = "audit",       label = "Audit Log" },
}

local function CreateWindow()
    frame = CreateFrame("Frame", "DHBavinCreditsConfigFrame", UIParent, "BasicFrameTemplateWithInset")
    -- Widened 480 -> 580 (2026-09-25) to match the Roster tab's Name
    -- column widening above, then 580 -> 800 (2026-10-04, Loopi: had to
    -- resize on every open to read the character names). The resize max
    -- below was raised to match (720 -> 1100) so 800 is still resizable.
    frame:SetSize(800, 620)
    frame:SetPoint("CENTER")
    if frame.TitleText then
        frame.TitleText:SetText("Bavin Rep & Credit Config")
    end
    tinsert(UISpecialFrames, "DHBavinCreditsConfigFrame")

    DHTools.InitStandaloneWindow(frame)

    -- 2026-10-04 (Loopi: this window "is still set to always on top - it
    -- blocks other windows"): the explicit SetFrameStrata("HIGH") that
    -- used to be here (2026-09-25, to open above the Bavin config) is
    -- GONE. Open-on-top is now handled for every DH window by
    -- InitStandaloneWindow's Raise() on each show (Core.lua) - NOT by a
    -- higher strata, which made this window float above everything,
    -- including windows opened after it. Do not re-add a strata here.

    -- Resizable (2026-09-25, Chris) - same grip/bounds idiom as
    -- PriorityEditor.lua and DH-Tools\Config.lua's own window.
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        pcall(frame.SetResizeBounds, frame, 420, 400, 1100, 900)
    else
        pcall(frame.SetMinResize, frame, 420, 400)
        pcall(frame.SetMaxResize, frame, 1100, 900)
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
    local scrollFrame = CreateFrame("ScrollFrame", "DHBavinCreditsConfigScroll", frame, (DHTools and DHTools.SCROLL_TEMPLATE) or "UIPanelScrollFrameTemplate")
    if DHTools and DHTools.SkinScrollBar then DHTools.SkinScrollBar(scrollFrame) end
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
    -- TOPRIGHT added too (2026-09-25) so this tab's width tracks the
    -- window instead of staying at whatever SetSize below happened to
    -- say - BuildRosterTab's Name column is anchored off this frame's
    -- real RIGHT edge and needs it to actually move when resized.
    rosterContent:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", 0, 0)
    -- Generous fixed pre-first-refresh estimate (title/hint/seed button +
    -- sort/page controls + a full 20-row page) - trimmed to the real
    -- content height on every refresh, same as Settings tab.
    rosterContent:SetSize(1, 550)
    tabs.roster.refresh = BuildRosterTab(rosterContent)
    tabs.roster.content = rosterContent

    local reviewQueueContent = CreateFrame("Frame", nil, scrollFrame)
    reviewQueueContent:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, 0)
    -- Generous fixed pre-first-refresh estimate (title/hint/filter/sort/
    -- page controls + a full 15-row page, each row 2 lines) - trimmed to
    -- the real content height on every refresh, same as the other tabs.
    reviewQueueContent:SetSize(1, 650)
    tabs.reviewQueue.refresh = BuildReviewQueueTab(reviewQueueContent)
    tabs.reviewQueue.content = reviewQueueContent

    local auditContent = CreateFrame("Frame", nil, scrollFrame)
    auditContent:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, 0)
    -- Generous fixed pre-first-refresh estimate (title/hint/two filter lines/
    -- header + a full 25-row page) - trimmed to the real height on refresh.
    auditContent:SetSize(1, 700)
    tabs.audit.refresh = BuildAuditTab(auditContent)
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
-- manage credits config locally (any shared-list officer, or the
-- author account) - same gating philosophy as PointsEditor.lua/
-- PriorityEditor.lua's CanEditList checks. (2026-09-28: dropped the
-- separate "manage the officers list" branch - that's gated on the
-- Officer Settings page now, not here.)
function ns.CreditsConfig_Open()
    if not ns.CanManageCreditsConfigLocal() then
        ns.Print("Only a shared-list officer can open Bavin Rep & Credit Config.")
        return
    end
    if not frame then
        CreateWindow()
    end
    frame:Show()
    -- Explicit raise (2026-10-04, Loopi: "did not open on top"): CreateFrame
    -- returns a SHOWN frame, so on the very first open Show() is a no-op and
    -- InitStandaloneWindow's OnShow->Raise() never fires. Raise here every
    -- time instead of relying on that hook (same root cause as the Account
    -- window's first-click bug).
    frame:Raise()
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
