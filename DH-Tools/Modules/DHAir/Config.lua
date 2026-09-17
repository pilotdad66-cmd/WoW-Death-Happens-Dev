-- DH-Air Config.lua
-- /dhair config window: left-hand page list (Options, Messages, About) + right content pane.

local ADDON_NAME, DHAir = ...

local frame
local navButtons = {}

--------------------------------------------------------------------------
-- Options page
--------------------------------------------------------------------------

-- 2026-08-15 (Loopi): complete rework - two sections, a thin divider
-- between them. Member Options (top) is everything any player benefits
-- from setting for themselves; Officer/Leader Options (bottom) is the
-- guild-wide, permission-gated stuff (raid code phrase(s), officer rank).
-- Dropped from the old single-list layout, per Loopi's explicit item list
-- for this rework: the Pause/Resume Auto-Summon button (still reachable
-- via /dhair pause and /dhair resume). The "Guild members only" checkbox
-- was dropped too but Loopi asked for it back (2026-08-15) - now first
-- item in Officer/Leader Options as "Summon Guild Members Only".
local function CreateOptionsPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    --------------------------------------------------------------------
    -- Member Options
    --------------------------------------------------------------------
    local memberTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    memberTitle:SetPoint("TOPLEFT", 16, -16)
    memberTitle:SetText("Member Options")

    -- 2026-08-15: invAutoInvite is now a single unified on/off for BOTH
    -- the invite and the queue-join INV can do (Loopi's explicit call,
    -- reversing the 2026-08-05 "INV never queues" decision - see
    -- Invite.lua's HandleWhisper for the full history).
    local invCheck = CreateFrame("CheckButton", "DHAirInvCheck", panel, "UICheckButtonTemplate")
    invCheck:SetPoint("TOPLEFT", memberTitle, "BOTTOMLEFT", 0, -12)
    _G[invCheck:GetName() .. "Text"]:SetText("Enable INV Auto-Invite")
    invCheck:SetScript("OnClick", function(self)
        -- D2a (2026-08-17, Loopi - DH-Tools-WorldBuffRequest-Design.md):
        -- force-locked on while World Buff Mode is active - can't drift out
        -- of sync and silently stop WBM from working. Refresh() below also
        -- disables the control visually while WBM is on.
        if DHAir.db.worldBuffMode then
            self:SetChecked(true)
            return
        end
        DHAir.db.invAutoInvite = self:GetChecked() and true or false
    end)

    -- Same unified shape as above, for the code phrase mechanism instead
    -- (whisper prefix-match AND raid/party chat exact-match both gate on
    -- this - see Invite.lua). The phrase(s) themselves are edited in the
    -- Officer/Leader section below; this is read-only, indented display.
    local phraseCheck = CreateFrame("CheckButton", "DHAirPhraseCheck", panel, "UICheckButtonTemplate")
    phraseCheck:SetPoint("TOPLEFT", invCheck, "BOTTOMLEFT", 0, -8)
    _G[phraseCheck:GetName() .. "Text"]:SetText("Enable Code Phrase Auto-Invite")
    phraseCheck:SetScript("OnClick", function(self)
        -- D2a extended (2026-08-18, Loopi-reported) - same force-lock as
        -- invCheck above: World Buff Mode now requires BOTH auto-invite
        -- triggers on, not just INV.
        if DHAir.db.worldBuffMode then
            self:SetChecked(true)
            return
        end
        DHAir.db.phraseAutoInvite = self:GetChecked() and true or false
    end)

    local phraseListText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    phraseListText:SetPoint("TOPLEFT", phraseCheck, "BOTTOMLEFT", 24, -2)
    phraseListText:SetJustifyH("LEFT")

    local minimapCheck = CreateFrame("CheckButton", "DHAirMinimapCheck", panel, "UICheckButtonTemplate")
    minimapCheck:SetPoint("TOPLEFT", phraseListText, "BOTTOMLEFT", -24, -8)
    _G[minimapCheck:GetName() .. "Text"]:SetText("Show Minimap Button")
    minimapCheck:SetScript("OnClick", function(self)
        local show = self:GetChecked() and true or false
        DHAir.db.minimap.hide = not show
        local LDBIcon = LibStub("LibDBIcon-1.0", true)
        if LDBIcon then
            if show then
                LDBIcon:Show("DHAir")
            else
                LDBIcon:Hide("DHAir")
            end
        end
    end)

    local slider = CreateFrame("Slider", "DHAirTimeoutSlider", panel, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", minimapCheck, "BOTTOMLEFT", 4, -16)
    -- 2026-08-08: was 10-90 in steps of 5, back when this was genuinely
    -- "how long a summon takes". It's now only the stuck-summon fallback
    -- (Summon.lua @kb:channel-driven-advance) and the whole range lives
    -- in Core.lua so this slider and the ADDON_LOADED migration can't
    -- disagree.
    local fbMin = DHAir.SUMMON_FALLBACK_MIN or 3
    local fbMax = DHAir.SUMMON_FALLBACK_MAX or 15
    slider:SetMinMaxValues(fbMin, fbMax)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider:SetWidth(220)
    _G[slider:GetName() .. "Low"]:SetText(tostring(fbMin))
    _G[slider:GetName() .. "High"]:SetText(tostring(fbMax))
    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        DHAir.db.summonTimeout = value
        _G[self:GetName() .. "Text"]:SetText("Stuck Summons Fallback: " .. value .. "s")
    end)

    local shardSlider = CreateFrame("Slider", "DHAirMinShardsSlider", panel, "OptionsSliderTemplate")
    shardSlider:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -20)
    shardSlider:SetMinMaxValues(0, 6)
    shardSlider:SetValueStep(1)
    shardSlider:SetObeyStepOnDrag(true)
    shardSlider:SetWidth(220)
    _G[shardSlider:GetName() .. "Low"]:SetText("0")
    _G[shardSlider:GetName() .. "High"]:SetText("6")
    shardSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        DHAir.db.minShards = value
        _G[self:GetName() .. "Text"]:SetText("Pause Below This Many Shards: " .. value)
    end)

    -- Button row (2026-08-16 fix): a 2x2 grid, left-anchored off
    -- shardSlider, reading Reset Queue / Print Queue on row 1 and Reset
    -- Roster / Open Board on row 2 (same L-to-R order Loopi specified,
    -- just wrapped). The original single right-to-left row (chained off
    -- Open Board at the panel's right edge) could run wider than the
    -- content pane once all four labels were dynamically sized to fit -
    -- that pushed Reset Queue (and everything anchored below it: the
    -- divider and the whole Officer/Leader section) off the LEFT edge of
    -- the window. A 2-per-row grid can't outgrow the content pane at any
    -- reasonable window width, resizable or not. Reset Queue / Reset
    -- Roster still go through the same gated, broadcasting
    -- RequestClearAll/RequestClearRoster the Board's own Clear
    -- Queue/Clear Roster buttons use (2026-08-15 decision - the OLD
    -- Config "Reset Queue / Session" button called QueueReset() directly,
    -- LOCAL ONLY with no broadcast, which would have desynced this client
    -- from everyone else exactly like k-0035's bug).
    local resetQueueBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetQueueBtn:SetPoint("TOPLEFT", shardSlider, "BOTTOMLEFT", 4, -16)
    resetQueueBtn:SetText("Reset Queue")
    resetQueueBtn:SetScript("OnClick", function()
        if DHAir:RequestClearAll() then
            DHAir:Print("Queue cleared for everyone.")
        end
    end)

    local printQueueBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    printQueueBtn:SetPoint("LEFT", resetQueueBtn, "RIGHT", 8, 0)
    printQueueBtn:SetText("Print Queue")
    printQueueBtn:SetScript("OnClick", function() DHAir:QueueList() end)

    local resetRosterBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetRosterBtn:SetPoint("TOPLEFT", resetQueueBtn, "BOTTOMLEFT", 0, -8)
    resetRosterBtn:SetText("Reset Roster")
    resetRosterBtn:SetScript("OnClick", function()
        if DHAir:RequestClearRoster() then
            DHAir:Print("Ready roster (Summoners/Clickers) cleared for everyone.")
        end
    end)

    local openBoardBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    openBoardBtn:SetPoint("LEFT", resetRosterBtn, "RIGHT", 8, 0)
    openBoardBtn:SetText("Open Board")
    openBoardBtn:SetScript("OnClick", function()
        if DHAir.Board_Toggle then DHAir:Board_Toggle() end
    end)

    for _, btn in ipairs({ resetQueueBtn, printQueueBtn, resetRosterBtn, openBoardBtn }) do
        btn:SetHeight(22)
        btn:SetWidth(btn:GetFontString():GetStringWidth() + 24)
    end

    --------------------------------------------------------------------
    -- Divider
    --------------------------------------------------------------------
    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", resetRosterBtn, "BOTTOMLEFT", -4, -10)
    divider:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    divider:SetHeight(1)
    divider:SetColorTexture(1, 1, 1, 0.15)

    --------------------------------------------------------------------
    -- Officer/Leader Options
    --------------------------------------------------------------------
    local officerTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    officerTitle:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 4, -10)
    officerTitle:SetText("Officer/Leader Options")

    local guildOnlyCheck = CreateFrame("CheckButton", "DHAirGuildOnlyCheck", panel, "UICheckButtonTemplate")
    guildOnlyCheck:SetPoint("TOPLEFT", officerTitle, "BOTTOMLEFT", 0, -12)
    _G[guildOnlyCheck:GetName() .. "Text"]:SetText("Summon Guild Members Only")
    guildOnlyCheck:SetScript("OnClick", function(self)
        DHAir.db.guildOnly = self:GetChecked() and true or false
        if DHAir.db.guildOnly and DHAir.RequestGuildRoster then
            DHAir:RequestGuildRoster()
        end
    end)

    local phraseLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    phraseLabel:SetPoint("TOPLEFT", guildOnlyCheck, "BOTTOMLEFT", 0, -12)
    phraseLabel:SetText("Raid Code Phrase(s) (leader/assist only, separate multiple with a comma):")
    phraseLabel:SetWidth(320)
    phraseLabel:SetJustifyH("LEFT")

    local phraseEdit = CreateFrame("EditBox", "DHAirPhraseEdit", panel, "InputBoxTemplate")
    phraseEdit:SetSize(220, 20)
    phraseEdit:SetPoint("TOPLEFT", phraseLabel, "BOTTOMLEFT", 6, -12)
    phraseEdit:SetAutoFocus(false)
    phraseEdit:SetMaxLetters(128)

    -- 2026-08-16 (Loopi): explicit Save button instead of silently
    -- committing on focus loss - saveBtn is forward-declared so the
    -- phraseEdit scripts below (defined first) can reference it; only
    -- CommitPhrase() below actually calls RequestSetPhrase now.
    --
    -- 2026-08-16 in-game fix: this used to compute "dirty" by comparing
    -- phraseEdit's text to DHAir.db.codePhrase - which meant the FIRST
    -- Refresh() (box starts empty, db.codePhrase is already set) read as
    -- "dirty" and skipped populating the box, leaving it blank in-game.
    -- Now uses an explicit flag driven by EditBox:OnTextChanged's own
    -- isUserInput arg (false for a programmatic SetText, true for actual
    -- typing) - same fix applied to the Messages page's fields.
    local saveBtn
    local phraseDirty = false
    local function RefreshSaveState()
        if saveBtn then saveBtn:SetEnabled(phraseDirty) end
    end
    local function CommitPhrase()
        if not phraseDirty then return end
        local newPhrase = phraseEdit:GetText()
        if not DHAir:RequestSetPhrase(newPhrase) then
            phraseEdit:SetText(DHAir.db.codePhrase or "") -- revert: no permission, or empty phrase
        end
        phraseDirty = false
        RefreshSaveState()
    end

    phraseEdit:SetScript("OnEnterPressed", function(self)
        CommitPhrase()
        self:ClearFocus()
    end)
    phraseEdit:SetScript("OnEscapePressed", function(self)
        self:SetText(DHAir.db.codePhrase or "") -- programmatic -> clears dirty via OnTextChanged below
        self:ClearFocus()
    end)
    phraseEdit:SetScript("OnTextChanged", function(self, isUserInput)
        phraseDirty = isUserInput and true or false
        RefreshSaveState()
    end)

    saveBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    saveBtn:SetSize(60, 22)
    saveBtn:SetPoint("LEFT", phraseEdit, "RIGHT", 8, 0)
    saveBtn:SetText("Save")
    saveBtn:SetScript("OnClick", CommitPhrase)
    saveBtn:Disable()

    -- Guild officer rank threshold (M3, DH-Air-Destinations-Design.md §3/§7):
    -- Guild-Master-only (HasPermission "set_officer_threshold"), same
    -- SetShown(HasPermission(...)) idiom Board.lua's clearAllBtn already
    -- uses for its own officer-gated control - hidden entirely for anyone
    -- who isn't rank 0, rather than shown-but-disabled, since a regular
    -- member fiddling with a control they can't use isn't useful UI.
    local officerLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    officerLabel:SetPoint("TOPLEFT", phraseEdit, "BOTTOMLEFT", -6, -10)
    officerLabel:SetText("Guild officer rank (Guild Master only):")

    local officerDropdown = CreateFrame("Frame", "DHAirOfficerRankDropdown", panel, "UIDropDownMenuTemplate")
    officerDropdown:SetPoint("TOPLEFT", officerLabel, "BOTTOMLEFT", -16, -4)
    UIDropDownMenu_SetWidth(officerDropdown, 160)

    local function OfficerRank_OnClick(self)
        if not DHAir:HasPermission("set_officer_threshold") then
            DHAir:Print("Only the Guild Master can change the officer rank threshold.")
            return
        end
        DHAir.db.officerRankThreshold = self.value
        UIDropDownMenu_SetSelectedValue(officerDropdown, self.value)
        UIDropDownMenu_SetText(officerDropdown, self:GetText())
    end

    UIDropDownMenu_Initialize(officerDropdown, function(selfFrame, level)
        local numRanks = GuildControlGetNumRanks and GuildControlGetNumRanks() or 0
        for i = 0, numRanks - 1 do
            -- GuildControlGetRankName is 1-indexed (index 1 = Guild Master),
            -- while GetGuildRosterInfo's rankIndex (what IsGuildOfficer
            -- compares against) is 0-indexed - hence the +1 here.
            local rankName = (GuildControlGetRankName and GuildControlGetRankName(i + 1)) or ("Rank " .. i)
            local info = UIDropDownMenu_CreateInfo()
            info.text = rankName .. " (rank " .. i .. ")"
            info.value = i
            info.func = OfficerRank_OnClick
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    panel.Refresh = function()
        invCheck:SetChecked(DHAir.db.invAutoInvite)
        -- D2a: visually greyed out while World Buff Mode forces it on.
        invCheck:SetEnabled(not DHAir.db.worldBuffMode)
        phraseCheck:SetChecked(DHAir.db.phraseAutoInvite)
        -- D2a extended (2026-08-18): greyed out while WBM forces it on,
        -- same as invCheck above.
        phraseCheck:SetEnabled(not DHAir.db.worldBuffMode)
        phraseListText:SetText("Phrase(s): " .. (DHAir.db.codePhrase or ""))
        minimapCheck:SetChecked(not DHAir.db.minimap.hide)
        guildOnlyCheck:SetChecked(DHAir.db.guildOnly)
        -- Don't stomp an in-progress unsaved edit (e.g. the page was
        -- switched away and back) - only resync the box when it matches
        -- what's already saved.
        if not phraseDirty then
            phraseEdit:SetText(DHAir.db.codePhrase or "")
        end
        RefreshSaveState()
        slider:SetValue(DHAir.db.summonTimeout)
        _G[slider:GetName() .. "Text"]:SetText("Stuck Summons Fallback: " .. DHAir.db.summonTimeout .. "s")
        shardSlider:SetValue(DHAir.db.minShards)
        _G[shardSlider:GetName() .. "Text"]:SetText("Pause Below This Many Shards: " .. DHAir.db.minShards)

        local canSetThreshold = DHAir:HasPermission("set_officer_threshold")
        officerLabel:SetShown(canSetThreshold)
        officerDropdown:SetShown(canSetThreshold)
        if canSetThreshold then
            local current = DHAir.db.officerRankThreshold or 3
            local rankName = (GuildControlGetRankName and GuildControlGetRankName(current + 1))
                or ("Rank " .. current)
            UIDropDownMenu_SetSelectedValue(officerDropdown, current)
            UIDropDownMenu_SetText(officerDropdown, rankName .. " (rank " .. current .. ")")
        end
    end

    return panel
end

--------------------------------------------------------------------------
-- Messages page (customizable /raid, /group, /guild, /say announcements)
--------------------------------------------------------------------------

local CHANNELS = {
    { key = "raid",    label = "Raid Chat" },
    { key = "party",   label = "Group Chat" },
    { key = "guild",   label = "Guild Chat" },
    { key = "say",     label = "/Say" },
    { key = "whisper", label = "Whisper to Target" },
}

-- 2026-08-16 (Loopi, in-game): 48/-22 was too tight - the checkbox
-- (UICheckButtonTemplate's default clickable region is taller than its
-- visible label text) was overlapping the edit box directly below it.
-- Bumped both back up; ROW_HEIGHT still leaner than the pre-rework 56.
local ROW_HEIGHT = 54 -- fixed vertical spacing per row, measured from checkbox top to checkbox top

-- Every row anchors to the SAME fixed baseline (not to the previous row's
-- edit box), each at its own absolute Y offset. This keeps every checkbox
-- and edit box perfectly left-aligned regardless of how any other row is
-- sized - no drift accumulates from row to row.
-- 2026-08-16 (Loopi): text fields on this whole page now commit through
-- one page-level Save Changes button instead of each one auto-committing
-- on focus-lost - onFieldChanged(key, isUserInput) reports dirty state up
-- to CreateMessagesPanel. isUserInput is EditBox:OnTextChanged's own 2nd
-- argument (false for a programmatic SetText, true for actual typing) -
-- using it means Refresh()/Restore Defaults' own SetText calls never
-- falsely mark a field dirty, no separate bookkeeping needed for that.
local function CreateChannelRow(parent, baseline, channelKey, channelLabel, rowIndex, onFieldChanged)
    local yOffset = -(rowIndex - 1) * ROW_HEIGHT

    local checkName = "DHAirMsgCheck_" .. channelKey
    local check = CreateFrame("CheckButton", checkName, parent, "UICheckButtonTemplate")
    check:SetPoint("TOPLEFT", baseline, "BOTTOMLEFT", 0, yOffset)
    _G[checkName .. "Text"]:SetText("Announce in " .. channelLabel)

    local editName = "DHAirMsgEdit_" .. channelKey
    local edit = CreateFrame("EditBox", editName, parent, "InputBoxTemplate")
    edit:SetSize(330, 20)
    edit:SetPoint("TOPLEFT", baseline, "BOTTOMLEFT", 6, yOffset - 28)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(255)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEscapePressed", function(self)
        self:SetText(DHAir.db.messages[channelKey].text) -- programmatic -> clears dirty via OnTextChanged below
        self:ClearFocus()
    end)
    edit:SetScript("OnTextChanged", function(self, isUserInput)
        if onFieldChanged then onFieldChanged(channelKey, isUserInput) end
    end)

    check:SetScript("OnClick", function(self)
        DHAir.db.messages[channelKey].enabled = self:GetChecked() and true or false
    end)

    return check, edit
end

local function CreateMessagesPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Messages")

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("Use {target} anywhere in a message - it will be replaced with the player's name. "
        .. "\"Whisper to Target\" sends privately to the player being summoned instead of a chat channel.")
    hint:SetWordWrap(true)

    -- Forward-declared (saveBtn/giEdit created further down) - same trick
    -- Options page's code-phrase Save button already uses.
    local rows = {}
    local saveBtn, giEdit
    local textDirty = {} -- key -> bool; CHANNELS' keys plus "__guildInstructions"

    local function AnyFieldDirty()
        for _, v in pairs(textDirty) do
            if v then return true end
        end
        return false
    end
    local function RefreshSaveState()
        if saveBtn then saveBtn:SetEnabled(AnyFieldDirty()) end
    end
    local function OnFieldChanged(key, isUserInput)
        textDirty[key] = isUserInput and true or false
        RefreshSaveState()
    end

    for i, info in ipairs(CHANNELS) do
        local check, edit = CreateChannelRow(panel, hint, info.key, info.label, i, OnFieldChanged)
        rows[info.key] = { check = check, edit = edit }
    end

    local lastRowBottom = -((#CHANNELS - 1) * ROW_HEIGHT) - 28 - 20 -- bottom of the last edit box, plus gap

    -- Guild Instructions (2026-08-16, Loopi): a separate, static "come join
    -- us" broadcast, sent ONLY manually from Board's "Broadcast to Guild"
    -- button - deliberately no enabled checkbox here, unlike the channel
    -- rows above, since nothing ever fires it automatically. Multi-line +
    -- word-wrapped (ScrollFrame + multiline EditBox, not a plain
    -- InputBoxTemplate like the single-line fields above): 3 visible rows,
    -- scrolls for more. XXXX is a literal placeholder kept in the stored
    -- text itself; BroadcastGuildInstructions (Invite.lua) substitutes it
    -- with GetCodePhrases()[1] at send time, so editing the code phrase
    -- doesn't require re-editing this message too.
    -- 2026-08-16 in-game fix: heading was anchored -6 (LEFT of the page's
    -- normal 16px margin, further left than everything else on the page)
    -- with no gap below the last channel row above it - moved to match the
    -- row content's own indent and given breathing room below that row.
    local giTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    giTitle:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 6, lastRowBottom - 10)
    giTitle:SetText("Guild Instructions")

    -- 2026-08-16 in-game fix #3: left edge was 6px right of every other
    -- box on this page - giTitle is already +6 from hint (matching the
    -- row content's own indent), and this added ANOTHER +6 on top of
    -- that (compounding to +12 total). 0 here now matches giTitle's own
    -- left edge exactly, same as the channel rows' edit boxes.
    local giScroll = CreateFrame("ScrollFrame", "DHAirGuildInstructionsScroll", panel, "UIPanelScrollFrameTemplate")
    giScroll:SetPoint("TOPLEFT", giTitle, "BOTTOMLEFT", 0, -8)
    giScroll:SetSize(310, 54) -- ~3 wrapped lines visible; scrolls for more (unconfirmed in-game)

    -- 2026-08-16 in-game fix #2: the InputBoxTemplate border hack didn't
    -- actually scale - Blizzard's border art is a fixed ~20px strip
    -- anchored to the frame's own TOPLEFT/TOPRIGHT (built for a
    -- single-line box), so it only ever decorated the first row and left
    -- the rest of this 3-row box completely unbordered ("purely
    -- cosmetic" - Loopi). Replaced with 4 real stretchable color-texture
    -- edges (same idiom as this page's own divider) sized to actually
    -- enclose the box, extended GI_TOP_PAD above giScroll's own frame so
    -- the text has breathing room from the top edge instead of sitting
    -- flush against it, closer to how the single-line boxes above look.
    local GI_ROW_HEIGHT = 18
    local GI_TOP_PAD = math.floor(GI_ROW_HEIGHT * 1.2 + 0.5) -- ~22px

    local giBg = panel:CreateTexture(nil, "BACKGROUND")
    giBg:SetPoint("TOPLEFT", giScroll, -4, 4 + GI_TOP_PAD)
    giBg:SetPoint("BOTTOMRIGHT", giScroll, 22, -4) -- extra room for the template's scrollbar
    giBg:SetColorTexture(0, 0, 0, 0.3)

    -- 2026-08-16 in-game fix #3: the 4 flat 1px lines above met at hard
    -- square corners. InputBoxTemplate's own border art can't be reused
    -- here (fix #2's comment above explains why - it's a fixed-height
    -- pill that doesn't stretch to a 3-row box). BackdropTemplate's
    -- edgeFile is the Blizzard-native way to get a genuinely rounded
    -- border that scales to any frame size, so it's a legitimate style
    -- match (rounded corners, thin light edge) even though the exact
    -- texture differs from the single-line boxes' pill asset.
    local giBorder = CreateFrame("Frame", "DHAirGuildInstructionsBorder", panel, "BackdropTemplate")
    giBorder:SetPoint("TOPLEFT", giBg, "TOPLEFT", 0, 0)
    giBorder:SetPoint("BOTTOMRIGHT", giBg, "BOTTOMRIGHT", 0, 0)
    giBorder:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
    })
    giBorder:SetBackdropBorderColor(0.8, 0.8, 0.8, 0.5)

    giEdit = CreateFrame("EditBox", "DHAirGuildInstructionsEdit", giScroll)
    giEdit:SetMultiLine(true)
    giEdit:SetFontObject(ChatFontNormal)
    giEdit:SetWidth(292)
    giEdit:SetHeight(120) -- generous scrollable height for up to 255 chars; giScroll's 54px is the visible window
    giEdit:SetAutoFocus(false)
    giEdit:SetMaxLetters(255)
    giEdit:SetScript("OnEscapePressed", function(self)
        self:SetText(DHAir.db.guildInstructions or "") -- programmatic -> clears dirty via OnTextChanged below
        self:ClearFocus()
    end)
    giEdit:SetScript("OnTextChanged", function(self, isUserInput)
        OnFieldChanged("__guildInstructions", isUserInput)
    end)
    giEdit:SetScript("OnCursorChanged", function(self, x, y, w, h)
        giScroll:SetVerticalScroll(math.min(giScroll:GetVerticalScrollRange(), math.max(0, -y - h)))
    end)
    giScroll:SetScrollChild(giEdit)
    giScroll:EnableMouseWheel(true)
    giScroll:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.min(math.max(cur - delta * 18, 0), self:GetVerticalScrollRange()))
    end)

    -- Destination Whisper (2026-09-17, Chris) - the whisper
    -- RequestSetDestinationFor (Queue.lua) sends when someone else's
    -- destination is set or cleared, covering both that manual Board path
    -- and World Buff Mode's automatic Booty Bay tag (same shared
    -- function - see Queue.lua's comment). Two single-line fields, no
    -- enable checkbox (unlike the channel rows above) - this whisper is
    -- the requester's only feedback, not an optional announcement.
    local destTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    destTitle:SetPoint("TOPLEFT", giScroll, "BOTTOMLEFT", 2, -16)
    destTitle:SetText("Destination Whisper")

    local destHint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    destHint:SetPoint("TOPLEFT", destTitle, "BOTTOMLEFT", -2, -4)
    destHint:SetPoint("RIGHT", -16, 0)
    destHint:SetJustifyH("LEFT")
    destHint:SetText("Sent to whoever's destination is set or cleared for them (Board, or World Buff "
        .. "Mode's automatic Booty Bay tag). Use {dest} for the destination name and {setter} for who set it.")
    destHint:SetWordWrap(true)

    local destSetLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    destSetLabel:SetPoint("TOPLEFT", destHint, "BOTTOMLEFT", 2, -8)
    destSetLabel:SetText("Destination Set")

    local destSetEdit = CreateFrame("EditBox", "DHAirDestSetMsgEdit", panel, "InputBoxTemplate")
    destSetEdit:SetSize(330, 20)
    destSetEdit:SetPoint("TOPLEFT", destSetLabel, "BOTTOMLEFT", 4, -6)
    destSetEdit:SetAutoFocus(false)
    destSetEdit:SetMaxLetters(255)
    destSetEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    destSetEdit:SetScript("OnEscapePressed", function(self)
        self:SetText(DHAir.db.destSetMessage) -- programmatic -> clears dirty via OnTextChanged below
        self:ClearFocus()
    end)
    destSetEdit:SetScript("OnTextChanged", function(self, isUserInput)
        OnFieldChanged("__destSetMessage", isUserInput)
    end)

    local destClearedLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    destClearedLabel:SetPoint("TOPLEFT", destSetEdit, "BOTTOMLEFT", -4, -14)
    destClearedLabel:SetText("Destination Cleared")

    local destClearedEdit = CreateFrame("EditBox", "DHAirDestClearedMsgEdit", panel, "InputBoxTemplate")
    destClearedEdit:SetSize(330, 20)
    destClearedEdit:SetPoint("TOPLEFT", destClearedLabel, "BOTTOMLEFT", 4, -6)
    destClearedEdit:SetAutoFocus(false)
    destClearedEdit:SetMaxLetters(255)
    destClearedEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    destClearedEdit:SetScript("OnEscapePressed", function(self)
        self:SetText(DHAir.db.destClearedMessage) -- programmatic -> clears dirty via OnTextChanged below
        self:ClearFocus()
    end)
    destClearedEdit:SetScript("OnTextChanged", function(self, isUserInput)
        OnFieldChanged("__destClearedMessage", isUserInput)
    end)

    saveBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    saveBtn:SetSize(130, 22)
    saveBtn:SetPoint("TOPLEFT", destClearedEdit, "BOTTOMLEFT", -4, -16)
    saveBtn:SetText("Save Changes")
    saveBtn:SetScript("OnClick", function()
        for _, info in ipairs(CHANNELS) do
            DHAir.db.messages[info.key].text = rows[info.key].edit:GetText()
        end
        DHAir.db.guildInstructions = giEdit:GetText()
        DHAir.db.destSetMessage = destSetEdit:GetText()
        DHAir.db.destClearedMessage = destClearedEdit:GetText()
        textDirty = {}
        RefreshSaveState()
    end)
    saveBtn:Disable()

    -- Restore Default Messages (2026-08-16: moved to the bottom, below
    -- Save Changes, per Loopi - it's a reset action, kept visually last
    -- and separate from the everyday Save Changes flow). Writes db AND
    -- widget text directly (bypassing panel.Refresh's dirty-guard below on
    -- purpose - restoring defaults should always win over an in-progress
    -- edit, unlike a routine page-revisit refresh).
    local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resetBtn:SetSize(180, 22)
    resetBtn:SetPoint("TOPLEFT", saveBtn, "BOTTOMLEFT", 0, -10)
    resetBtn:SetText("Restore Default Messages")
    resetBtn:SetScript("OnClick", function()
        for _, info in ipairs(CHANNELS) do
            local defaultText = (info.key == "guild")
                and "Now summoning {target} for the Air Service."
                or DHAir.DEFAULT_MESSAGE
            DHAir.db.messages[info.key].text = defaultText
        end
        DHAir.db.guildInstructions = DHAir.DEFAULT_GUILD_INSTRUCTIONS
        DHAir.db.destSetMessage = DHAir.DEFAULT_DEST_SET_MESSAGE
        DHAir.db.destClearedMessage = DHAir.DEFAULT_DEST_CLEARED_MESSAGE
        textDirty = {}
        panel.Refresh()
    end)

    panel.Refresh = function()
        for _, info in ipairs(CHANNELS) do
            local cfg = DHAir.db.messages[info.key]
            local row = rows[info.key]
            row.check:SetChecked(cfg.enabled)
            if not textDirty[info.key] then
                row.edit:SetText(cfg.text)
            end
        end
        if not textDirty["__guildInstructions"] then
            giEdit:SetText(DHAir.db.guildInstructions or "")
        end
        if not textDirty["__destSetMessage"] then
            destSetEdit:SetText(DHAir.db.destSetMessage or DHAir.DEFAULT_DEST_SET_MESSAGE)
        end
        if not textDirty["__destClearedMessage"] then
            destClearedEdit:SetText(DHAir.db.destClearedMessage or DHAir.DEFAULT_DEST_CLEARED_MESSAGE)
        end
        RefreshSaveState()
    end

    return panel
end

--------------------------------------------------------------------------
-- Sharing page (multi-Warlock shared queue)
--------------------------------------------------------------------------

local function CreateSharingPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Sharing")

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", -16, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("When enabled, other Warlocks running DH-Air in your raid/party share "
        .. "one summon queue with you, so nobody wastes a Soul Shard summoning the same "
        .. "player twice.")
    hint:SetWordWrap(true)

    local shareCheck = CreateFrame("CheckButton", "DHAirShareCheck", panel, "UICheckButtonTemplate")
    shareCheck:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", -4, -50)
    _G[shareCheck:GetName() .. "Text"]:SetText("Share summon queue with other DH-Air Warlocks")
    shareCheck:SetScript("OnClick", function(self)
        DHAir.db.shareQueue = self:GetChecked() and true or false
        if DHAir.db.shareQueue and DHAir.Sync_Init then
            DHAir:Sync_Init()
        end
    end)

    local status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", shareCheck, "BOTTOMLEFT", 4, -12)

    local peersBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    peersBtn:SetSize(180, 22)
    peersBtn:SetPoint("TOPLEFT", status, "BOTTOMLEFT", -4, -14)
    peersBtn:SetText("Print Active Peers to Chat")
    peersBtn:SetScript("OnClick", function()
        if DHAir.PrintPeers then DHAir:PrintPeers() end
    end)

    local syncBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    syncBtn:SetSize(180, 22)
    syncBtn:SetPoint("TOPLEFT", peersBtn, "BOTTOMLEFT", 0, -8)
    syncBtn:SetText("Re-sync Queue Now")
    syncBtn:SetScript("OnClick", function()
        if DHAir.Sync_IsActive and DHAir:Sync_IsActive() then
            DHAir:Print("Requesting the current shared queue from other DH-Air Warlocks...")
            DHAir:Sync_Send("SYNCREQ")
        else
            DHAir:Print("Queue sharing is off or you're not in a group.")
        end
    end)

    panel.Refresh = function()
        shareCheck:SetChecked(DHAir.db.shareQueue)
        local active = DHAir.Sync_IsActive and DHAir:Sync_IsActive()
        if not DHAir.db.shareQueue then
            status:SetText("|cffff0000Off|r - your queue is private to you.")
        elseif active then
            status:SetText("|cff00ff00Active|r - broadcasting to your "
                .. (IsInRaid() and "raid" or "party") .. ".")
        else
            status:SetText("|cffffff00On, but idle|r - not currently in a raid or party.")
        end
    end

    return panel
end

--------------------------------------------------------------------------
-- About page
--------------------------------------------------------------------------

local function CreateAboutPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("About DH-Air")

    local body = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -16)
    body:SetPoint("RIGHT", -16, 0)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")

    panel.Refresh = function()
        local gameVersion = GetBuildInfo()
        local text = "Addon Version: " .. DHAir.VERSION .. "\n"
            .. "Game Version: " .. tostring(gameVersion) .. "\n\n"
            .. "Author: Loopi\n"
            .. "Major Contributor: Deves\n\n"
            .. "Built for the Death Happens Hardcore guild Air Service, "
            .. "to help Warlocks auto-invite and summon players in an orderly queue.\n\n"
            .. "Copyright (c) 2026 Loopi. All rights reserved."
        body:SetText(text)
    end

    return panel
end

--------------------------------------------------------------------------
-- Frame / navigation
--------------------------------------------------------------------------

local function SelectPage(key)
    for k, b in pairs(navButtons) do
        if k == key then
            b:LockHighlight()
        else
            b:UnlockHighlight()
        end
    end
    for k, p in pairs(frame.pages) do
        if k == key then
            p:Show()
            if p.Refresh then p.Refresh() end
        else
            p:Hide()
        end
    end
end

function DHAir:Config_Open()
    if not frame then
        frame = CreateFrame("Frame", "DHAirConfigFrame", UIParent, "BasicFrameTemplateWithInset")
        frame:SetSize(520, 600)
        frame:SetPoint("CENTER")
        -- Toplevel raising, opaque background, and title-bar-only dragging -
        -- see Core.lua's InitStandaloneWindow for why (this is also what
        -- fixed the Board window's identical overlap/dragging bugs).
        DHAir:InitStandaloneWindow(frame)
        if frame.TitleText then
            frame.TitleText:SetText("DH-Air Configuration")
        end
        tinsert(UISpecialFrames, "DHAirConfigFrame")

        -- Resizable (2026-08-16, Loopi) - same SetResizeBounds/SetMinResize
        -- fallback and resize-grip idiom Board.lua and DestinationEditor.lua
        -- already use. Min width/height keep the nav pane + the Officer
        -- section's 320-wide phrase label from ever being squeezed to the
        -- point they'd overlap or clip again.
        frame:SetResizable(true)
        if frame.SetResizeBounds then
            pcall(frame.SetResizeBounds, frame, 480, 420, 900, 900)
        else
            pcall(frame.SetMinResize, frame, 480, 420)
            pcall(frame.SetMaxResize, frame, 900, 900)
        end

        local nav = CreateFrame("Frame", nil, frame)
        nav:SetPoint("TOPLEFT", 12, -32)
        nav:SetPoint("BOTTOMLEFT", 12, 12)
        nav:SetWidth(100)

        local navBg = nav:CreateTexture(nil, "BACKGROUND")
        navBg:SetAllPoints()
        navBg:SetColorTexture(0, 0, 0, 0.25)

        local content = CreateFrame("Frame", nil, frame)
        content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 10, 0)
        content:SetPoint("BOTTOMRIGHT", -12, 12)

        frame.pages = {
            Options = CreateOptionsPanel(content),
            Messages = CreateMessagesPanel(content),
            Sharing = CreateSharingPanel(content),
            About = CreateAboutPanel(content),
        }

        local function RefreshCurrentPage()
            for k, p in pairs(frame.pages) do
                if p:IsShown() and p.Refresh then
                    p.Refresh()
                end
            end
        end

        local pageNames = { "Options", "Messages", "Sharing", "About" }
        local prevBtn
        for _, name in ipairs(pageNames) do
            local btn = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
            btn:SetSize(84, 24)
            if prevBtn then
                btn:SetPoint("TOPLEFT", prevBtn, "BOTTOMLEFT", 0, -4)
            else
                btn:SetPoint("TOPLEFT", 8, -8)
            end
            btn:SetText(name)
            btn:SetScript("OnClick", function() SelectPage(name) end)
            navButtons[name] = btn
            prevBtn = btn
        end

        local resizeBtn = CreateFrame("Button", nil, frame)
        resizeBtn:SetSize(16, 16)
        resizeBtn:SetPoint("BOTTOMRIGHT", -4, 4)
        resizeBtn:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        resizeBtn:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
        resizeBtn:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
        resizeBtn:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
        resizeBtn:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)
        frame:SetScript("OnSizeChanged", function()
            if frame:IsShown() then RefreshCurrentPage() end
        end)

        SelectPage("Options")
    end

    frame:Show()
    -- Both windows use SetToplevel (InitStandaloneWindow), which only
    -- auto-raises a frame when the frame ITSELF is clicked. Opening Config
    -- from the Board's Config button means the click landed on Board, not
    -- Config, so that auto-raise never fires and Config could stay behind
    -- an already-open Board. Raise explicitly every time this is called.
    frame:Raise()
    for k, p in pairs(frame.pages) do
        if p:IsShown() and p.Refresh then
            p.Refresh()
        end
    end
end
