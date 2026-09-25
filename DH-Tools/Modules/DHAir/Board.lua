-- DH-Air Board.lua
-- The Air Service Board: a resizable window showing the shared queue, role
-- registration, and per-row actions. This is the primary interface for
-- anyone running DH-Air - Warlocks, Clickers, or plain members - not a
-- Warlock-only tool. Opened via /dhair board (minimap left-click switches
-- over to this in a later milestone).
--
-- This file is a RENDERING LAYER ONLY. All the actual logic it displays -
-- sort order, permissions, claims, roster counts - already exists and is
-- tested in Queue.lua/Roster.lua/Sync.lua/Core.lua. Board.lua just reads
-- that state and draws it; it never contains its own business logic, so
-- the only genuinely new risk surface here is layout/rendering itself.

local ADDON_NAME, DHAir = ...

local ROW_HEIGHT = 22
local REFRESH_INTERVAL = 1 -- seconds; throttles the live wait-time ticker

-- Column widths/gaps shared between CreateRow (data rows) and the header
-- buttons, so the header always lines up with its column no matter how the
-- window is resized - both are built from these same numbers, right-to-left,
-- rather than the header using independent left-anchored guesses.
local COL_ROLE_WIDTH = 64
local COL_DEST_WIDTH = 110  -- M5: destination column, between name and wait-time
local COL_WAIT_WIDTH = 64
local COL_WHISPER_WIDTH = 56 -- M5: "Whisper" quick action, next to Summon/Invite
local COL_ACTION_WIDTH = 70
local COL_REMOVE_WIDTH = 20
local COL_GAP = 8
local COL_TIGHT_GAP = 4

-- 2026-08-17 (Loopi): resize used to hand 100% of any extra window width to
-- the Name column and none to Destination. Fix splits it, but Name still
-- shouldn't grow past what a real character name could ever need (12-char
-- cap in-game; 15 here as a small buffer) - past that point all further
-- extra goes to Destination instead. See Board_Refresh's column-width calc.
local NAME_COL_MAX_CHARS = 15
-- Distance from a row's own LEFT edge to nameText's LEFT edge - see
-- CreateRow: roleTag sits 4px in, is COL_ROLE_WIDTH wide, then nameText
-- starts 4px past that. Named here (not just inline in CreateRow) so
-- Board_Refresh's column-width calc can't drift out of sync with it.
local NAME_LEFT_FIXED = 4 + COL_ROLE_WIDTH + 4
-- CreateBoardFrame's frame:SetSize width - what the column-growth calc
-- below measures "extra" resize width against.
local DEFAULT_FRAME_WIDTH = 580

local frame
local rowPool = {}       -- reusable row frames, grown as needed, never destroyed
local sortKey, sortDir = "wait", "desc"
local lastRefresh = 0
local currentDestWidth = COL_DEST_WIDTH -- recomputed every Board_Refresh, read by RenderRow

--------------------------------------------------------------------------
-- Combat-lockdown guard
--------------------------------------------------------------------------
-- 2026-08-06 (Loopi-reported crash): "Action[SetPoint] failed because
-- [Cannot anchor protected frames to regions]" the first time the Board
-- was opened. Root cause: k-0010's SecureActionButtonTemplate conversion
-- (confirmSummonBtn below, row.actionBtn in CreateRow/RenderRow) makes
-- Blizzard treat SetPoint/SetSize/Show/Hide/SetScript on those specific
-- buttons as restricted WHILE InCombatLockdown() is true - fine any other
-- time, but CreateBoardFrame's one-time frame build (called from
-- Board_Open) and every live Board_Refresh tick both touch those buttons
-- unconditionally, with no combat awareness at all. Since this is a
-- Hardcore leveling guild, "still combat-flagged right after a fight"
-- when someone opens the board for a summon is an entirely ordinary
-- moment, not an edge case.
--
-- FIX: never let CreateBoardFrame or Board_Refresh run while
-- InCombatLockdown() - skip the cycle (or defer the very first build)
-- and automatically retry via PLAYER_REGEN_ENABLED the instant combat
-- ends, exactly once, rather than patching every individual SetPoint/
-- Show/Hide/SetScript call site with its own guard. Declared up here
-- (rather than near Board_Open/Board_Refresh below) purely so it's in
-- scope as an upvalue for both - Lua locals aren't hoisted the way
-- global functions are.
local combatCatchupQueue = {}
local combatWaiter

local function QueueCombatCatchup(fn)
    table.insert(combatCatchupQueue, fn)
    if combatWaiter then return end
    combatWaiter = CreateFrame("Frame")
    combatWaiter:RegisterEvent("PLAYER_REGEN_ENABLED")
    combatWaiter:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        combatWaiter = nil
        local queued = combatCatchupQueue
        combatCatchupQueue = {}
        for _, queuedFn in ipairs(queued) do
            queuedFn()
        end
    end)
end

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------

local function FormatWaitTime(seconds)
    seconds = math.max(0, math.floor(seconds))
    return math.floor(seconds / 60) .. "m " .. (seconds % 60) .. "s"
end

-- Returns every queue entry that currently has a live (non-stale) claim on
-- it, i.e. someone is actively working on summoning them right now. Claims
-- are already broadcast/synced, so this reflects ALL Warlocks, not just
-- whichever one happens to be running the local client.
local function GetActiveSummons()
    local active = {}
    for _, entry in ipairs(DHAir.db.queue) do
        if not entry.summoned then
            local claim = DHAir.GetClaim and DHAir:GetClaim(entry.name)
            if claim and not DHAir:IsClaimStale(claim) then
                table.insert(active, { entry = entry, claim = claim })
            end
        end
    end
    return active
end

-- Determines what the row's action button/text should be for this entry.
-- Returns (mode, clickable) where mode is "summon" | "invite" | "notinraid".
local function GetRowAction(entry)
    local unit = DHAir.FindGroupUnitByName and DHAir.FindGroupUnitByName(entry.name)
    if unit then
        return "summon", true
    end
    if DHAir:HasPermission("invite") then
        return "invite", true
    end
    return "notinraid", false
end

--------------------------------------------------------------------------
-- Row pool
--------------------------------------------------------------------------

local function CreateRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(1, 1, 1, 0.03) -- faint stripe, alternated on refresh

    row.roleTag = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.roleTag:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.roleTag:SetWidth(COL_ROLE_WIDTH)
    row.roleTag:SetJustifyH("LEFT")

    row.removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.removeBtn:SetSize(COL_REMOVE_WIDTH, 18)
    row.removeBtn:SetText("X")
    row.removeBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)

    -- 2026-08-06 (k-0010, then reverted same day per brief-001): this
    -- button was briefly made a SecureActionButtonTemplate so it could
    -- dispatch a protected cast directly. Confirmed (clean diagnostic
    -- build, no Lua error either way) that doing so silently broke this
    -- row's OWN sibling text - nameText/waitText/destText never rendered,
    -- even though the exact same SetText calls work fine everywhere else
    -- in this file. Root mechanism still isn't fully understood (doesn't
    -- match the documented combat-only/position-size-visibility-only
    -- restriction on protected regions - see Object security on Warcraft
    -- Wiki), so rather than build around a poorly-understood restriction,
    -- this button is plain again, permanently. It no longer casts
    -- anything itself - see RenderRow's "summon" mode below, which now
    -- calls ManualSummon(name, false) to arm the Board's ONE remaining
    -- (and proven reliable, since it's static/never rebuilt) secure
    -- widget, confirmSummonBtn, instead.
    row.actionBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.actionBtn:SetSize(COL_ACTION_WIDTH, 18)
    row.actionBtn:SetPoint("RIGHT", row.removeBtn, "LEFT", -COL_TIGHT_GAP, 0)

    row.actionText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.actionText:SetPoint("RIGHT", row.removeBtn, "LEFT", -COL_TIGHT_GAP, 0)
    row.actionText:SetWidth(COL_ACTION_WIDTH)
    row.actionText:SetJustifyH("CENTER")

    -- M5: "Whisper" quick action - anchored off actionBtn (not actionText),
    -- same "two overlapping widgets share one anchor point" trick already
    -- used for actionBtn/actionText themselves, since actionBtn's position
    -- doesn't move depending on which of the two is currently shown.
    row.whisperBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.whisperBtn:SetSize(COL_WHISPER_WIDTH, 18)
    row.whisperBtn:SetPoint("RIGHT", row.actionBtn, "LEFT", -COL_TIGHT_GAP, 0)
    row.whisperBtn:SetText("Whisper")

    row.waitText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.waitText:SetPoint("RIGHT", row.whisperBtn, "LEFT", -COL_GAP, 0)
    row.waitText:SetWidth(COL_WAIT_WIDTH)
    row.waitText:SetJustifyH("RIGHT")

    -- Destination column - a plain read-only label for EVERY row,
    -- including your own. 2026-08-04 (Loopi-reported): this used to be a
    -- clickable UIPanelButtonTemplate button on your own row, opening a
    -- shared dropdown menu (frame.destDropdown) directly from the row -
    -- but that template's default font is larger than GameFontHighlightSmall
    -- (what every other row's plain label uses), so your own row looked
    -- oversized/out of place next to everyone else's. Picking/changing
    -- your own destination now happens through the "Set/Change
    -- Destination" footer button instead (see CreateBoardFrame/
    -- Board_Refresh) - frame.destDropdown itself is unchanged, just
    -- opened from a different place.
    row.destText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.destText:SetPoint("RIGHT", row.waitText, "LEFT", -COL_GAP, 0)
    row.destText:SetWidth(COL_DEST_WIDTH)
    row.destText:SetJustifyH("LEFT")
    -- Truncate long destination labels (engine auto-ellipsis) instead of
    -- letting them overflow past this column into the wait-time column
    -- next to it - same fix already used for DestinationEditor.lua's
    -- labelText/categoryText.
    row.destText:SetWordWrap(false)

    -- M3 (QueueFeedback D3): invisible click region exactly covering the
    -- destination cell, letting a leader/assist set ANY row's destination.
    -- Deliberately a bare Button with no template and no artwork rather
    -- than the UIPanelButtonTemplate this column used to have: that
    -- template's font is larger than the GameFontHighlightSmall every
    -- other cell uses, which is exactly why the per-row button was pulled
    -- out on 2026-08-04 (see the comment above). The cell keeps rendering
    -- as a plain label at the right size; the clickability is invisible,
    -- with the affordance carried by the label's own text/color in
    -- RenderRow and by a tooltip on hover.
    -- Not a secure frame and never needs to be - ApplyDestination and the
    -- SETDESTFOR broadcast are ordinary API, unlike the summon cast, so
    -- k-0018's "isolate secure frames from the Board" rule doesn't apply.
    row.destBtn = CreateFrame("Button", nil, row)
    row.destBtn:SetAllPoints(row.destText)
    row.destBtn:SetScript("OnEnter", function(selfBtn)
        if not selfBtn.tooltipName then return end
        GameTooltip:SetOwner(selfBtn, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Set destination for " .. selfBtn.tooltipName)
        GameTooltip:AddLine("They don't need the addon - they'll get a whisper.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    row.destBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.destBtn:Hide()

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.nameText:SetPoint("LEFT", row.roleTag, "RIGHT", 4, 0)
    row.nameText:SetPoint("RIGHT", row.destText, "LEFT", -8, 0)
    row.nameText:SetJustifyH("LEFT")

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

--------------------------------------------------------------------------
-- Row rendering
--------------------------------------------------------------------------

local function RenderRow(row, entry, index)
    local myName = UnitName("player")
    local isSelf = DHAir:NormalizeName(entry.name) == DHAir:NormalizeName(myName)
    local shortName = DHAir:NormalizeName(entry.name)
    local onlineStatus = DHAir:IsGuildMemberOnline(entry.name) -- true/false/nil(unknown)
    local isOffline = (onlineStatus == false)

    row.bg:SetColorTexture(1, 1, 1, (index % 2 == 0) and 0.03 or 0.0)
    -- 2026-08-04 (one-click auto-summon redesign): gold tint overrides the
    -- normal zebra stripe on whichever row auto-summon has picked and
    -- claimed but not yet cast on (summonState == "ready") - makes it
    -- obvious at a glance which row the footer's "Confirm Summon" button
    -- refers to, without needing to hunt for it.
    if DHAir.summonState == "ready" and DHAir.pendingEntry
        and DHAir:NormalizeName(entry.name) == DHAir:NormalizeName(DHAir.pendingEntry.name) then
        row.bg:SetColorTexture(1, 0.82, 0, 0.18)
    end

    if entry.role == "summoner" then
        row.roleTag:SetText("|cff8888ffSummoner|r")
    elseif entry.role == "clicker" then
        row.roleTag:SetText("|cffffcc66Clicker|r")
    else
        row.roleTag:SetText("")
    end

    local nameDisplay = shortName .. (isSelf and " (you)" or "")
    if isOffline then
        row.nameText:SetText("|cff888888" .. nameDisplay .. "|r")
    else
        row.nameText:SetText(nameDisplay)
    end

    local waitSeconds = GetTime() - (entry.queuedAt or GetTime())
    row.waitText:SetText(FormatWaitTime(waitSeconds))

    -- Destination cell (DH-Air-Destinations-Design.md §5) - plain
    -- read-only label for every row, "-" if undecided. See CreateRow's
    -- comment: picking/changing YOUR OWN destination is now done via the
    -- footer's Set/Change Destination button, not a per-row control.
    -- M3 (QueueFeedback D3): a leader/assist can set any OTHER row's
    -- destination by clicking its cell. Own row is deliberately excluded
    -- even for a leader - the footer's Set/Change Destination button
    -- already owns that job, and two live controls for the same value on
    -- the same screen is how they drift apart. Permission is re-read every
    -- refresh rather than cached, since gaining/losing assist mid-raid is
    -- routine.
    -- 2026-08-17: width now recomputed every refresh (Board_Refresh), not a
    -- fixed COL_DEST_WIDTH - see that function's column-growth calc. destBtn
    -- (below) tracks destText via SetAllPoints, so it needs no width of its
    -- own.
    row.destText:SetWidth(currentDestWidth)

    local canSetForThis = (not isSelf) and DHAir:HasPermission("set_dest_any")
    local d = entry.destination and DHAir:GetDestination(entry.destination)
    if d then
        row.destText:SetText(d.label)
    elseif canSetForThis and not entry.note then
        -- Undecided AND settable: the placeholder does double duty as the
        -- affordance, since the click region itself is invisible. A bare
        -- "-" gave no hint anything was clickable. Coloured DH-Air purple
        -- to read as an action rather than as data.
        row.destText:SetText("|cff9482c9(set)|r")
    elseif entry.note then
        -- 2026-08-07 (design D1/D2): free text the requester typed after the
        -- code phrase ("air to SM"). Shown in grey and quoted so it reads as
        -- an unconfirmed REQUEST, visibly different from a real destination
        -- that's actually been set - most requesters have no addon, so this
        -- is the only place their intent is ever visible. Local-only (D6):
        -- an entry that arrived over sync never has one.
        row.destText:SetText("|cff888888\"" .. entry.note .. "\"|r")
    else
        row.destText:SetText("-")
    end
    row.destText:Show()

    -- Wire (or unwire) the invisible click region over that cell. The
    -- shared dropdown is retargeted through frame.destTarget rather than
    -- by building a second menu - see CreateBoardFrame's DestPick.
    if canSetForThis then
        row.destBtn.tooltipName = shortName
        row.destBtn:SetScript("OnClick", function(selfBtn)
            if frame and frame.destDropdown then
                frame.destTarget = entry.name
                ToggleDropDownMenu(1, nil, frame.destDropdown, selfBtn, 0, 0)
            end
        end)
        row.destBtn:Show()
    else
        row.destBtn.tooltipName = nil
        row.destBtn:Hide()
    end

    -- Action button/text - hidden for your own row (you don't summon/invite yourself).
    row.actionBtn:Hide()
    row.actionText:Hide()
    row.whisperBtn:Hide()
    row.removeBtn:Show()

    if isSelf then
        row.removeBtn:SetScript("OnClick", function() DHAir:SelfLeaveQueue() ; DHAir:Board_Refresh() end)
    else
        local mode, clickable = GetRowAction(entry)

        if isOffline then
            row.actionText:SetText("offline")
            row.actionText:Show()
        elseif mode == "summon" then
            row.actionBtn:SetText("Pick")
            row.actionBtn:Show()
            -- 2026-08-06 (k-0010, reverted same day per brief-001): plain
            -- OnClick again - this button is no longer secure (see
            -- CreateRow's comment). Clicking it just ARMS the pick via
            -- ManualSummon(name, false) - false so BeginCast lands on
            -- "ready" instead of trying to cast directly - which shows
            -- "Confirm Summon: <name>" on the Board's footer button (the
            -- one remaining secure widget) for the actual cast. Same
            -- one-more-click flow auto-summon already uses; "Pick" is
            -- named accordingly so it doesn't read as an instant summon.
            row.actionBtn:SetScript("OnClick", function()
                if DHAir.ManualSummon then DHAir:ManualSummon(entry.name, false) end
                DHAir:Board_Refresh()
            end)
        elseif mode == "invite" and clickable then
            row.actionBtn:SetText("Invite")
            row.actionBtn:Show()
            -- Plain OnClick, not a protected action - InviteUnit/
            -- C_PartyInfo.InviteUnit aren't restricted the way
            -- TargetUnit/CastSpellByName are.
            row.actionBtn:SetScript("OnClick", function()
                if C_PartyInfo and C_PartyInfo.InviteUnit then
                    C_PartyInfo.InviteUnit(entry.name)
                else
                    InviteUnit(entry.name)
                end
            end)
        else
            row.actionText:SetText("not in raid")
            row.actionText:Show()
        end

        -- M5: "Whisper" quick action - any non-self row that's currently
        -- online (reuses the isOffline check above - unknown status,
        -- like an online row, still gets the button; only a CONFIRMED
        -- offline status hides it).
        if not isOffline then
            row.whisperBtn:Show()
            row.whisperBtn:SetScript("OnClick", function()
                if ChatFrame_SendTell then
                    ChatFrame_SendTell(entry.name)
                end
            end)
        end

        row.removeBtn:SetScript("OnClick", function()
            DHAir:RequestRemove(entry.name)
            DHAir:Board_Refresh()
        end)
        -- Only leader/assist (or self, handled above) can remove someone else.
        if not DHAir:HasPermission("remove_any") then
            row.removeBtn:Hide()
        end
    end

    row:Show()
end

--------------------------------------------------------------------------
-- Full refresh
--------------------------------------------------------------------------

local function UpdateSortHeaderText()
    if not frame then return end
    frame.sortNameBtn:SetText("Name")
    frame.sortDestBtn:SetText("Destination")
    frame.sortWaitBtn:SetText("Waiting")
end

function DHAir:Board_Refresh()
    if not frame or not frame:IsShown() then return end
    -- 2026-08-06: see the "Combat-lockdown guard" section below Board_Open
    -- for why - this function touches confirmSummonBtn and every visible
    -- row's actionBtn (both SecureActionButtonTemplate since k-0010) via
    -- SetPoint/SetWidth/Show/Hide/SetScript, all of which Blizzard blocks
    -- while InCombatLockdown(). Skip the whole cycle and catch up the
    -- instant combat ends rather than crash mid-refresh.
    if InCombatLockdown() then
        QueueCombatCatchup(function() DHAir:Board_Refresh() end)
        return
    end

    frame.statSummoners:SetText("Summoners ready: " .. self:CountRegistered("summoner"))
    frame.statClickers:SetText("Clickers ready: " .. self:CountRegistered("clicker"))
    -- Waiting count, NOT #db.queue: summoned entries stay in db.queue
    -- flagged summoned=true, so the raw length only ever grows and the
    -- counter disagreed with the rows below it (which SortedQueue already
    -- filters). Reported in-game 2026-08-07.
    frame.statQueue:SetText("In queue: " .. self:QueueWaitingCount())

    -- "Currently summoning" section - reflects ALL active claims, from any
    -- Warlock, not just this client's own summon state.
    local active = GetActiveSummons()
    if #active > 0 then
        local lines = {}
        for _, a in ipairs(active) do
            table.insert(lines, self:NormalizeName(a.entry.name) .. " |cff888888(by "
                .. self:NormalizeName(a.claim.by) .. ")|r")
        end
        frame.summoningText:SetText(table.concat(lines, "\n"))
        frame.summoningText:Show()
    else
        frame.summoningText:Hide()
    end

    -- Role/join button states.
    local myName = UnitName("player")
    local myEntry = nil
    for _, e in ipairs(self.db.queue) do
        if self:NormalizeName(e.name) == self:NormalizeName(myName) and not e.summoned then
            myEntry = e
            break
        end
    end
    local inQueue = myEntry ~= nil
    frame.joinBtn:SetText(inQueue and "Leave queue" or "Join queue")

    -- Set/Change Destination footer button (2026-08-04, moved off the own
    -- row - see CreateRow/RenderRow) - only meaningful while queued, since
    -- only a queue entry carries a destination field.
    frame.setDestBtn:SetShown(inQueue)
    if inQueue then
        local mine = myEntry.destination and self:GetDestination(myEntry.destination)
        frame.setDestBtn:SetText(mine and ("Change Destination: " .. mine.label) or "Set Destination")
        -- Re-measure every refresh, same idiom autoSummonBtn already uses -
        -- anchored by BOTTOMLEFT (see creation), so growing/shrinking width
        -- extends rightward from its own row's fixed left edge.
        frame.setDestBtn:SetWidth(frame.setDestBtn:GetFontString():GetStringWidth() + 24)
    end

    -- Abort Summon (2026-08-04, Loopi-requested) - only shown while this
    -- client's own summon state machine isn't idle, i.e. there's actually
    -- something to abort (see Summon.lua's AbortSummon).
    frame.abortBtn:SetShown(DHAir.summonState ~= "idle")

    -- Confirm Summon (2026-08-04, one-click auto-summon redesign) - only
    -- shown while auto-summon has picked and claimed someone but hasn't
    -- cast yet (see Summon.lua's BeginCast/ConfirmSummon). Label carries
    -- the target's name so there's no ambiguity about who a click summons.
    if DHAir.summonState == "ready" and DHAir.pendingEntry then
        frame.confirmSummonBtn:SetText("Confirm Summon: " .. self:NormalizeName(DHAir.pendingEntry.name))
        frame.confirmSummonBtn:SetWidth(frame.confirmSummonBtn:GetFontString():GetStringWidth() + 24)
        frame.confirmSummonBtn:Show()
    else
        frame.confirmSummonBtn:Hide()
    end

    frame.summonerCheck:SetChecked(self:IsRegistered("summoner", myName))
    frame.clickerCheck:SetChecked(self:IsRegistered("clicker", myName))
    -- 2026-08-17 (Loopi): dropped the "warlockDestination already picked"
    -- half of this gate - Loopi hit it reading as "I'm a summoner AND have
    -- an operating destination", which meant the button silently never
    -- appeared for a summoner who hadn't picked one yet, no matter how the
    -- queue looked. Gate is just the roster registration now; clicking
    -- with no destination chosen falls through to whatever
    -- RequestStartAutoSummon already does for that case (Summon.lua), same
    -- as it always has. Broadcast to Guild and World Buff Mode share this
    -- same gate (2026-08-17, Loopi) - all are summoner-only controls now.
    local autoSummonReady = self:IsRegistered("summoner", myName)
    local autoSummonLabel = (self.db.active and not self.db.paused)

    -- Auto Summons toggle, under Broadcast to Guild. Re-measured every
    -- refresh (both real labels render wider than the button's placeholder
    -- width), anchored by its RIGHT edge (see creation), so it grows/
    -- shrinks leftward instead of into the frame edge.
    frame.autoSummonBtn2:SetShown(autoSummonReady)
    if autoSummonReady then
        frame.autoSummonBtn2:SetText(autoSummonLabel and "Stop Auto Summons" or "Start Auto Summons")
        frame.autoSummonBtn2:SetWidth(frame.autoSummonBtn2:GetFontString():GetStringWidth() + 24)
    end

    -- Broadcast to Guild (2026-08-17, Loopi) - now gated to summoner
    -- registration, same as everything else on this row.
    frame.broadcastBtn:SetShown(autoSummonReady)

    -- World Buff Mode (2026-08-17, Loopi - relocated next to "I'm a
    -- summoner") - same gate as above. Local per-character setting, read
    -- by Invite.lua's whisper handler - see db.worldBuffMode in Core.lua's
    -- defaults.
    frame.worldBuffCheck:SetShown(autoSummonReady)
    frame.worldBuffCheck:SetChecked(self.db.worldBuffMode and true or false)

    -- Summon counters (2026-09-25, Chris) - same summoner-only gate as
    -- everything else on this row.
    frame.summonCountText:SetShown(autoSummonReady)
    frame.resetSessionBtn:SetShown(autoSummonReady)
    if autoSummonReady then
        frame.summonCountText:SetText(("Summoned: %d session / %d lifetime")
            :format(self.db.summonCountSession or 0, self.db.summonCountLifetime or 0))
    end

    frame.clearAllBtn:SetShown(self:HasPermission("clear_all"))
    frame.clearRosterBtn:SetShown(self:HasPermission("clear_roster"))

    UpdateSortHeaderText()

    -- Row list.
    local ordered = self:SortedQueue(sortKey, sortDir)
    local content = frame.scrollContent
    local contentW = math.max(1, frame.scrollFrame:GetWidth() - 24)
    content:SetWidth(contentW)

    -- 2026-08-17 (Loopi-reported): resizing the Board used to hand 100% of
    -- any extra width to the Name column (its width was never set
    -- explicitly - it just filled whatever space was left between roleTag
    -- and destText) and 0% to Destination (fixed at COL_DEST_WIDTH always).
    -- Fix: split any width beyond DEFAULT_FRAME_WIDTH between the two,
    -- Name capped at NAME_COL_MAX_CHARS worth of pixels (real names are
    -- max 12 chars - no point growing Name past that) - once Name hits
    -- that cap, all further extra goes to Destination instead. Below
    -- DEFAULT_FRAME_WIDTH (including the frame's minimum size), this
    -- reduces to `extra = 0`, i.e. exactly today's behavior.
    --
    -- `insetConst` (frame width minus content width) is measured live
    -- rather than hand-derived from the anchor chain between them, so this
    -- can't drift out of sync if that chain's own offsets ever change.
    -- `frame.destColRightInset` is the same fixed distance (scrollFrame's
    -- RIGHT edge to destText's RIGHT edge) sortDestBtn already positions
    -- itself with - stored on frame at creation so both stay derived from
    -- one place.
    local insetConst = frame:GetWidth() - contentW
    local baseContentW = math.max(1, DEFAULT_FRAME_WIDTH - insetConst)
    local fixedRightWidth = (frame.destColRightInset or (24 + COL_DEST_WIDTH)) - 24
    local forColumns = math.max(0, contentW - NAME_LEFT_FIXED - fixedRightWidth)
    local baseForColumns = math.max(0, baseContentW - NAME_LEFT_FIXED - fixedRightWidth)
    local baseNameWidth = math.max(0, baseForColumns - COL_DEST_WIDTH)
    local extra = math.max(0, forColumns - baseForColumns)
    local nameCap = frame.nameColMaxWidth or COL_DEST_WIDTH
    local nameGrowth = math.min(extra / 2, math.max(0, nameCap - baseNameWidth))
    currentDestWidth = math.max(COL_DEST_WIDTH, COL_DEST_WIDTH + (extra - nameGrowth))
    frame.sortDestBtn:SetWidth(currentDestWidth)

    for i, entry in ipairs(ordered) do
        local row = AcquireRow(content, i)
        RenderRow(row, entry, i)
    end
    HideRowsFrom(#ordered + 1)
    content:SetHeight(math.max(1, #ordered * ROW_HEIGHT))
end

--------------------------------------------------------------------------
-- Frame construction (built once, first time the Board is opened)
--------------------------------------------------------------------------

local function ApplyResizeBounds(f, minW, minH, maxW, maxH)
    if f.SetResizeBounds then
        pcall(f.SetResizeBounds, f, minW, minH, maxW, maxH)
    else
        pcall(f.SetMinResize, f, minW, minH)
        pcall(f.SetMaxResize, f, maxW, maxH)
    end
end

-- Anchor-family isolation for the Board's one secure widget (2026-08-05,
-- brief-002 follow-up). The 1.15 client propagates protected status
-- through ANCHORS, not just parents ("control restrictions on protected
-- frames are also applied to their parents and any frames they are
-- anchored to"). Every previous variant still anchored the secure widget
-- to abortBtn (or frame), pulling the whole window into a restricted
-- anchor family - which explains BOTH bugs: Bug A (anchoring a protected
-- frame to an insecurely-positioned region errors outright, timing at
-- login being noise) and Bug B (the restricted family's regions silently
-- refuse layout when driven from non-hardware code like the OnUpdate
-- ticker, until a real click's hardware-event exemption lets it commit -
-- hence "one click fixes everything permanently").
--
-- So the secure overlays (confirmSummonSecure, and since the abort
-- /stopcasting fix, abortSecure) are anchored ONLY to UIParent (securely
-- positioned, always a legal anchor target), overlaying their cosmetic
-- buttons via absolute offsets computed from abortBtn's on-screen rect.
-- Recomputed on window show / drag stop / resize stop - never from the
-- refresh ticker.
local function PositionSecureOverlays()
    if not frame or InCombatLockdown() then return end
    local ab = frame.abortBtn
    local right, top, bottom = ab:GetRight(), ab:GetTop(), ab:GetBottom()
    if not right or not bottom then
        -- Rect not resolved yet (first layout pass after creation) -
        -- retry next frame. UIParent-only anchoring stays legal from a
        -- timer out of combat; only the anchor TARGET ever mattered.
        C_Timer.After(0, PositionSecureOverlays)
        return
    end
    local confirm = frame.confirmSummonSecure
    if confirm then
        local s = ab:GetEffectiveScale() / confirm:GetEffectiveScale()
        confirm:ClearAllPoints()
        confirm:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", right * s, (bottom - 4) * s)
    end
    local abort = frame.abortSecure
    if abort then
        local s = ab:GetEffectiveScale() / abort:GetEffectiveScale()
        abort:ClearAllPoints()
        abort:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", right * s, top * s)
    end
end

-- Shared by both Auto Summons buttons (the original next to "I'm a
-- summoner", and the 2026-08-17 second copy under Broadcast to Guild) so
-- the toggle logic itself lives in exactly one place.
local function ToggleAutoSummon()
    if DHAir.db.active and not DHAir.db.paused then
        DHAir.db.paused = true
        DHAir:Print("Auto-summon paused.")
    elseif DHAir:RequestStartAutoSummon() then
        DHAir:Print("Auto-summon started.")
    end
    DHAir:Board_Refresh()
end

local function CreateBoardFrame()
    frame = CreateFrame("Frame", "DHAirBoardFrame", UIParent, "BasicFrameTemplateWithInset")
    -- M5: default/min width grew to fit the new destination column + Whisper
    -- button (480 -> 580 default, 420 -> 520 min) - see DH-Air-Destinations-Design.md §5.
    frame:SetSize(DEFAULT_FRAME_WIDTH, 420)
    frame:SetPoint("CENTER")
    frame:SetResizable(true)
    -- Min height 300 -> 330 (2026-08-17): the footer gained a second row
    -- (Set/Change Destination moved to its own line - see setDestBtn's
    -- creation below), so the minimum needs 30 more px of headroom than
    -- before to avoid the two footer rows crowding the row list.
    ApplyResizeBounds(frame, 520, 330, 1000, 700)
    if frame.TitleText then
        frame.TitleText:SetText("DH-Air - Air Service Board")
    end

    -- Cap for the Name column's growth on resize (2026-08-17) - measured off
    -- nameText's own font (GameFontHighlight, see CreateRow) using a wide
    -- worst-case character repeated NAME_COL_MAX_CHARS times, rather than a
    -- guessed pixel number, so it stays right if the font ever changes.
    -- Read by Board_Refresh's column-growth calc. Hidden, never shown.
    local nameMeasure = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameMeasure:Hide()
    nameMeasure:SetText(("M"):rep(NAME_COL_MAX_CHARS))
    frame.nameColMaxWidth = nameMeasure:GetStringWidth()
    tinsert(UISpecialFrames, "DHAirBoardFrame")

    -- Toplevel raising, opaque background, and title-bar-only dragging -
    -- see Core.lua's InitStandaloneWindow for why.
    local dragRegion = DHAir:InitStandaloneWindow(frame)
    -- Keep the UIParent-anchored secure click-catchers tracking the window
    -- (see PositionSecureOverlays above). Drag stop / show / hide are all
    -- hardware-event or out-of-combat contexts; in-combat cases queue.
    local function SetOverlaysShown(shown)
        local confirm, abort = frame.confirmSummonSecure, frame.abortSecure
        if confirm then confirm:SetShown(shown) end
        if abort then abort:SetShown(shown) end
    end
    dragRegion:HookScript("OnDragStop", PositionSecureOverlays)
    frame:HookScript("OnShow", function()
        if InCombatLockdown() then
            QueueCombatCatchup(function()
                if frame:IsShown() then SetOverlaysShown(true); PositionSecureOverlays() end
            end)
            return
        end
        SetOverlaysShown(true)
        PositionSecureOverlays()
    end)
    frame:HookScript("OnHide", function()
        if InCombatLockdown() then
            QueueCombatCatchup(function()
                if not frame:IsShown() then SetOverlaysShown(false) end
            end)
            return
        end
        SetOverlaysShown(false)
    end)

    -- Resize grip (bottom-right corner drag handle).
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        DHAir:Board_Refresh()
        PositionSecureOverlays() -- resize moves abortBtn's corner
    end)

    -- Stat row.
    frame.statSummoners = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.statSummoners:SetPoint("TOPLEFT", 12, -30)

    frame.statClickers = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.statClickers:SetPoint("LEFT", frame.statSummoners, "RIGHT", 20, 0)

    frame.statQueue = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.statQueue:SetPoint("LEFT", frame.statClickers, "RIGHT", 20, 0)

    -- Broadcast to Guild (2026-08-16, Loopi) - sends db.guildInstructions
    -- (Config.lua's Messages page, XXXX substituted for the first code
    -- phrase) to guild chat. Same row as the stats, top-right corner.
    -- 2026-08-17 (Loopi): gated to summoner registration, same as Auto
    -- Summons/World Buff Mode - see Board_Refresh.
    frame.broadcastBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.broadcastBtn:SetSize(140, 22)
    frame.broadcastBtn:SetPoint("TOPRIGHT", -16, -28)
    frame.broadcastBtn:SetText("Broadcast to Guild")
    frame.broadcastBtn:SetScript("OnClick", function()
        if DHAir.BroadcastGuildInstructions then DHAir:BroadcastGuildInstructions() end
    end)

    -- Auto Summons toggle (2026-08-17, Loopi; repositioned 2026-08-18,
    -- Loopi-reported overlap with Abort Summon) - same row as Broadcast to
    -- Guild, immediately to its left, rather than stacked underneath it
    -- (that slot now belongs to Abort Summon - see below). Same
    -- db.active/db.paused state and gate as everything else on this row
    -- (see Board_Refresh). ToggleAutoSummon is shared with the click
    -- handler below so the toggle logic itself isn't duplicated.
    frame.autoSummonBtn2 = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.autoSummonBtn2:SetSize(140, 22)
    frame.autoSummonBtn2:SetPoint("RIGHT", frame.broadcastBtn, "LEFT", -8, 0)
    frame.autoSummonBtn2:SetScript("OnClick", function() ToggleAutoSummon() end)

    -- Action bar - a single container with an EXPLICIT height, so everything
    -- below it anchors to ITS bottom rather than guessing which sub-element
    -- (the join button vs. the two stacked role checkboxes) happens to be
    -- taller. Avoids the checkboxes silently overlapping whatever comes next.
    local actionBar = CreateFrame("Frame", nil, frame)
    actionBar:SetPoint("TOPLEFT", frame.statSummoners, "BOTTOMLEFT", 0, -10)
    actionBar:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
    actionBar:SetHeight(52)

    frame.joinBtn = CreateFrame("Button", nil, actionBar, "UIPanelButtonTemplate")
    frame.joinBtn:SetSize(100, 22)
    frame.joinBtn:SetPoint("TOPLEFT", actionBar, "TOPLEFT", 0, 0)
    frame.joinBtn:SetScript("OnClick", function()
        local myName = UnitName("player")
        local inQueue = false
        for _, e in ipairs(DHAir.db.queue) do
            if DHAir:NormalizeName(e.name) == DHAir:NormalizeName(myName) and not e.summoned then
                inQueue = true
                break
            end
        end
        if inQueue then
            -- 2026-08-18 (Loopi): Leave Queue means "I'm done" - if you're
            -- a registered Summoner/Clicker, this also unregisters that
            -- role (SetRole's own D5 logic then leaves the queue for us)
            -- and turns off World Buff Mode, which only makes sense while
            -- summoning. A regular queued player is unaffected - falls
            -- straight through to the plain SelfLeaveQueue below.
            if DHAir:IsRegistered("summoner", myName) then
                DHAir:SetRole("summoner", false)
            end
            if DHAir:IsRegistered("clicker", myName) then
                DHAir:SetRole("clicker", false)
            end
            if DHAir.db.worldBuffMode then
                DHAir.db.worldBuffMode = false
                if DHAir.Sync_BroadcastWBM then DHAir:Sync_BroadcastWBM(false) end
            end
            DHAir:SelfLeaveQueue()
        else
            DHAir:SelfJoinQueue()
        end
        DHAir:Board_Refresh()
    end)

    local roleGroup = CreateFrame("Frame", nil, actionBar)
    roleGroup:SetPoint("TOPLEFT", frame.joinBtn, "TOPRIGHT", 16, 0)
    roleGroup:SetSize(280, 52)

    frame.summonerCheck = CreateFrame("CheckButton", "DHAirBoardSummonerCheck", roleGroup, "UICheckButtonTemplate")
    frame.summonerCheck:SetPoint("TOPLEFT", roleGroup, "TOPLEFT", 0, 0)
    local summonerLabel = _G[frame.summonerCheck:GetName() .. "Text"]
    summonerLabel:SetText("I'm a summoner")
    frame.summonerCheck:SetScript("OnClick", function(self)
        DHAir:SetRole("summoner", self:GetChecked() and true or false)
        DHAir:Board_Refresh()
    end)

    -- World Buff Mode (2026-08-17, Loopi - relocated here from next to
    -- Broadcast to Guild; the standalone Start/Stop Auto Summons button
    -- that used to live in this spot was removed the same session, since
    -- Loopi only wants the copy under Broadcast to Guild). Gated to
    -- summoner registration in Board_Refresh, same as Broadcast to Guild
    -- and the Auto Summons button. Local per-character setting
    -- (db.worldBuffMode, Core.lua defaults) - Invite.lua's whisper handler
    -- reads it to auto-set a whisper-code-word joiner's destination to
    -- Booty Bay. As of 2026-08-17 (DH-Tools-WorldBuffRequest-Design.md D1)
    -- this IS synced (Sync_BroadcastWBM) so other clients - including
    -- DH-Tools' "Request World Buff Summons" - can tell who's available.
    -- Anchored to the CHECKBOX'S TEXT LABEL like every other checkbox here -
    -- the checkbox's own clickable square is much narrower than its label,
    -- so anchoring to the control alone put this checkbox underneath the words.
    frame.worldBuffCheck = CreateFrame("CheckButton", "DHAirBoardWorldBuffCheck", roleGroup, "UICheckButtonTemplate")
    frame.worldBuffCheck:SetPoint("LEFT", summonerLabel, "RIGHT", 10, 0)
    local worldBuffLabel = _G[frame.worldBuffCheck:GetName() .. "Text"]
    worldBuffLabel:SetText("World Buff Mode")
    frame.worldBuffCheck:SetScript("OnClick", function(selfBtn)
        local on = selfBtn:GetChecked() and true or false
        DHAir.db.worldBuffMode = on
        if on then
            -- D2 (2026-08-17, Loopi - DH-Tools-WorldBuffRequest-Design.md;
            -- extended 2026-08-18, Loopi-reported): force-enable BOTH
            -- auto-invite triggers (INV and the code phrase - Config.lua
            -- locks both checkboxes on while WBM is active, not just INV
            -- as before) and set the Warlock's own destination to Booty
            -- Bay TWO ways: db.warlockDestination (what QueueNextAvailable
            -- actually matches auto-summon against) and, via
            -- SetMyDestination, this Warlock's own queue-entry destination
            -- field (what the Board actually DISPLAYS - the Set/Change
            -- Destination button and your own row - see Queue.lua's
            -- ApplyDestination). The two fields are independent; setting
            -- only the first left the Board looking like nothing happened
            -- even though auto-summon matching was already working.
            DHAir.db.invAutoInvite = true
            DHAir.db.phraseAutoInvite = true
            DHAir:SetWarlockDestination("bootybay")
            DHAir:SetMyDestination("bootybay")
        end
        if DHAir.Sync_BroadcastWBM then
            DHAir:Sync_BroadcastWBM(on)
        end
        DHAir:Board_Refresh()
    end)

    -- Summon counters + session reset (2026-09-25, Chris: "number of
    -- characters summoned this session and lifetime"; up here to the
    -- right of World Buff Mode per his preference - there's ~190px of
    -- room left in this row at the default window width). Gated to the
    -- same autoSummonReady (summoner-only) flag as World Buff Mode/
    -- Broadcast to Guild/Auto Summons in Board_Refresh below. Anchored to
    -- worldBuffLabel (the checkbox's TEXT), same reasoning as
    -- worldBuffCheck's own anchor comment above.
    frame.summonCountText = roleGroup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.summonCountText:SetPoint("LEFT", worldBuffLabel, "RIGHT", 16, 0)
    frame.summonCountText:SetJustifyH("LEFT")

    -- Single click, not a two-click confirm like Bavin's officer/shared-
    -- data resets - this is a purely local, unsynced personal counter
    -- (never touches anyone else's data), so the stakes don't call for
    -- the extra friction.
    frame.resetSessionBtn = CreateFrame("Button", nil, roleGroup, "UIPanelButtonTemplate")
    frame.resetSessionBtn:SetSize(70, 18)
    frame.resetSessionBtn:SetPoint("LEFT", frame.summonCountText, "RIGHT", 8, 0)
    frame.resetSessionBtn:SetText("Reset")
    frame.resetSessionBtn:SetScript("OnClick", function()
        if DHAir.ResetSummonCountSession then DHAir:ResetSummonCountSession() end
    end)

    frame.clickerCheck = CreateFrame("CheckButton", "DHAirBoardClickerCheck", roleGroup, "UICheckButtonTemplate")
    frame.clickerCheck:SetPoint("TOPLEFT", frame.summonerCheck, "BOTTOMLEFT", 0, -2)
    _G[frame.clickerCheck:GetName() .. "Text"]:SetText("I'm a clicker")
    frame.clickerCheck:SetScript("OnClick", function(self)
        DHAir:SetRole("clicker", self:GetChecked() and true or false)
        DHAir:Board_Refresh()
    end)

    -- Currently-summoning indicator - anchored to actionBar's BOTTOM, not to
    -- any specific button inside it, so it's always correctly positioned
    -- below whichever sub-element ends up tallest.
    frame.summoningText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.summoningText:SetPoint("TOPLEFT", actionBar, "BOTTOMLEFT", 0, -8)
    frame.summoningText:SetPoint("RIGHT", -16, 0)
    frame.summoningText:SetJustifyH("LEFT")
    frame.summoningText:SetTextColor(1, 0.82, 0)

    -- Scrollable row list. Created BEFORE the column headers, because the
    -- headers below anchor to scrollFrame's own live geometry rather than
    -- using independent fixed offsets - that's what keeps them lined up
    -- with the actual row columns as the window is resized.
    frame.scrollFrame = CreateFrame("ScrollFrame", "DHAirBoardScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPLEFT", frame.summoningText, "BOTTOMLEFT", 0, -32)
    -- Bottom inset 40 -> 70 (2026-08-17): the footer grew a second row
    -- (Set Destination moved to its own line, below Config/Clear
    -- Roster/Clear Queue - see setDestBtn's creation) and needs the extra
    -- 30px so the row list doesn't run underneath it.
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", -30, 70)

    frame.scrollContent = CreateFrame("Frame", nil, frame.scrollFrame)
    frame.scrollContent:SetSize(1, 1)
    frame.scrollFrame:SetScrollChild(frame.scrollContent)

    -- Sortable column headers - anchored to scrollFrame's edges using the
    -- SAME column widths/gaps as CreateRow, so "Name" and "Waiting" always
    -- sit directly above their actual data column, at any window width.
    frame.sortNameBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.sortNameBtn:SetSize(90, 18)
    frame.sortNameBtn:SetPoint("BOTTOMLEFT", frame.scrollFrame, "TOPLEFT", 8 + COL_ROLE_WIDTH, 4)
    frame.sortNameBtn:SetScript("OnClick", function()
        sortDir = (sortKey == "name") and (sortDir == "asc" and "desc" or "asc") or "asc"
        sortKey = "name"
        DHAir:Board_Refresh()
    end)
    -- 2026-08-03 (Loopi-reported): UIPanelButtonTemplate centers its label
    -- by default, so "Name" rendered ~35px right of nameText's actual left
    -- edge even though the BUTTON's own anchor already lined up with it -
    -- re-anchor the button's fontstring to the button's own LEFT edge and
    -- left-justify it, matching nameText:SetJustifyH("LEFT") below.
    local sortNameFS = frame.sortNameBtn:GetFontString()
    sortNameFS:ClearAllPoints()
    sortNameFS:SetPoint("LEFT", frame.sortNameBtn, "LEFT", 0, 0)
    sortNameFS:SetJustifyH("LEFT")

    -- The scrollbar/content inset (24) plus every column that sits to the
    -- right of the wait-time column (remove button, whisper button, action
    -- button, gaps) - matches exactly what Board_Refresh uses to size
    -- scrollContent, and what CreateRow uses to position waitText, so this
    -- can't drift out of sync with either of them. M5 inserted the
    -- whisper button between actionBtn and waitText, so its width/gap are
    -- now part of this inset too.
    local waitColRightInset = 24 + 2 + COL_REMOVE_WIDTH + COL_TIGHT_GAP + COL_ACTION_WIDTH
        + COL_TIGHT_GAP + COL_WHISPER_WIDTH + COL_GAP

    -- 2026-08-03 (Loopi-reported): was a fixed 90px wide, same as every
    -- other header button, even though its actual data column
    -- (waitText) is only COL_WAIT_WIDTH (64) wide. Since this button is
    -- anchored by its RIGHT edge to line up with waitText's right edge,
    -- the extra ~26px of unwarranted width hung off its LEFT side,
    -- overlapping into the Destination column's own header - that's the
    -- "no space between Destination and Waiting" symptom. Sizing this to
    -- the real column width removes the overlap and reproduces the same
    -- COL_GAP the data rows already have between destText and waitText.
    -- 2026-08-16 (Loopi, in-game): the button's own background rendered
    -- offset too far left of its "Waiting" label - since this button is
    -- anchored by its RIGHT edge (unchanged below) and the label matches
    -- that same right edge, shrinking the button's WIDTH pulls its LEFT
    -- edge in without moving the label or anything anchored off this
    -- button's right side (waitColRightInset/destColRightInset are both
    -- independent of this SetSize). ~1 capital W narrower; unconfirmed
    -- exact amount, flag it if still off.
    local SORT_WAIT_BTN_TRIM = 14
    frame.sortWaitBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.sortWaitBtn:SetSize(COL_WAIT_WIDTH - SORT_WAIT_BTN_TRIM, 18)
    frame.sortWaitBtn:SetPoint("BOTTOMRIGHT", frame.scrollFrame, "TOPRIGHT", -waitColRightInset, 4)
    frame.sortWaitBtn:SetScript("OnClick", function()
        sortDir = (sortKey == "wait") and (sortDir == "asc" and "desc" or "asc") or "desc"
        sortKey = "wait"
        DHAir:Board_Refresh()
    end)
    -- waitText itself is right-justified (see CreateRow) - match the
    -- header's text to the same edge instead of UIPanelButtonTemplate's
    -- default centering, so "Waiting" sits directly above the numbers.
    local sortWaitFS = frame.sortWaitBtn:GetFontString()
    sortWaitFS:ClearAllPoints()
    sortWaitFS:SetPoint("RIGHT", frame.sortWaitBtn, "RIGHT", 0, 0)
    sortWaitFS:SetJustifyH("RIGHT")

    -- M5: "Destination" sort header - sits directly left of "Waiting",
    -- same column-width-derived inset trick, extended past waitColRightInset
    -- by the wait column's own width plus one more gap (destText/destBtn
    -- sit immediately left of waitText in CreateRow).
    local destColRightInset = waitColRightInset + COL_WAIT_WIDTH + COL_GAP
    -- Stored on frame (2026-08-17) so Board_Refresh's column-growth calc can
    -- derive the same fixed right-side width this button's position already
    -- depends on, without duplicating the arithmetic above.
    frame.destColRightInset = destColRightInset

    -- 2026-08-03 (Loopi-reported): same root cause as sortWaitBtn above -
    -- fixed 90px instead of the real COL_DEST_WIDTH (110), and centered
    -- text instead of matching destText's own LEFT justify.
    -- 2026-08-17: SetSize's width is just the header button's INITIAL size -
    -- Board_Refresh re-measures it every refresh now, same as destText's
    -- own width, so the two never drift apart. Position (below) stays a
    -- fixed offset from scrollFrame's RIGHT edge either way.
    frame.sortDestBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.sortDestBtn:SetSize(COL_DEST_WIDTH, 18)
    frame.sortDestBtn:SetPoint("BOTTOMRIGHT", frame.scrollFrame, "TOPRIGHT", -destColRightInset, 4)
    frame.sortDestBtn:SetScript("OnClick", function()
        sortDir = (sortKey == "dest") and (sortDir == "asc" and "desc" or "asc") or "asc"
        sortKey = "dest"
        DHAir:Board_Refresh()
    end)
    -- destText itself is left-justified (see CreateRow) - match it.
    local sortDestFS = frame.sortDestBtn:GetFontString()
    sortDestFS:ClearAllPoints()
    sortDestFS:SetPoint("LEFT", frame.sortDestBtn, "LEFT", 0, 0)
    sortDestFS:SetJustifyH("LEFT")

    -- Shared dropdown-menu generator for the destination picker, opened
    -- from the footer's Set/Change Destination button (see Board_Refresh/
    -- setDestBtn below) - ONE menu frame, opened via ToggleDropDownMenu
    -- anchored to whatever triggered it, rather than an oversized
    -- UIDropDownMenuTemplate frame embedded in every pooled row.
    -- 2026-08-04 (Loopi-reported, two bugs):
    -- 1) Picking a destination left the parent level (Eastern Kingdoms/
    --    Kalimdor, or Flight Points/Dungeon Stones) still open instead of
    --    closing the whole menu - per Blizzard's own UIDropDownMenu docs,
    --    selecting an item inside a sub-menu only auto-closes THAT level
    --    by default, not its parent(s); every leaf entry below now calls
    --    CloseDropDownMenus() explicitly after picking.
    -- 2) Flight points weren't showing at all (continent submenu opened
    --    empty, or did nothing) - this used to be 3 menu levels deep
    --    (Flight Points -> Eastern Kingdoms/Kalimdor -> actual flight
    --    points), while Dungeon Stones was always only 2 levels and never
    --    had this problem. Flattened Flight Points down to 2 levels to
    --    match: Eastern Kingdoms and Kalimdor are now their own top-level
    --    arrow entries, each opening its destination list directly -
    --    still grouped by continent as Loopi asked for, just without the
    --    extra hop that was breaking.
    -- M3 (QueueFeedback D3): the SAME menu now serves two jobs, chosen by
    -- frame.destTarget - nil means "my own row" (footer button, unchanged
    -- self-service behavior), a name means "that player's row" (a
    -- leader/assist clicking their destination cell). Retargeting one menu
    -- beats building a second copy: the continent/category structure below
    -- is the fiddly part and had two real bugs of its own on 2026-08-04, so
    -- there should only ever be one of it.
    -- Cleared back to nil after every pick, so a later footer click can
    -- never inherit a stale target and silently set the wrong player's
    -- destination. The footer button clears it on the way in as well -
    -- belt and braces, because that particular mistake would be both
    -- invisible and wrong.
    local function DestPick(destId)
        local target = frame and frame.destTarget
        if target then
            DHAir:RequestSetDestinationFor(target, destId)
        else
            DHAir:SetMyDestination(destId)
        end
        if frame then frame.destTarget = nil end
        CloseDropDownMenus()
        DHAir:Board_Refresh()
    end

    frame.destDropdown = CreateFrame("Frame", "DHAirBoardDestDropdown", frame, "UIDropDownMenuTemplate")
    frame.destDropdown:Hide()
    UIDropDownMenu_Initialize(frame.destDropdown, function(selfFrame, level)
        level = level or 1

        if level == 1 then
            local clearInfo = UIDropDownMenu_CreateInfo()
            clearInfo.text = "(pick a destination)"
            clearInfo.value = ""
            clearInfo.func = function() DestPick("") end
            UIDropDownMenu_AddButton(clearInfo, level)

            local fpEkInfo = UIDropDownMenu_CreateInfo()
            fpEkInfo.text = "Flight Points - Eastern Kingdoms"
            fpEkInfo.notCheckable = true
            fpEkInfo.hasArrow = true
            fpEkInfo.value = "fp_ek"
            UIDropDownMenu_AddButton(fpEkInfo, level)

            local fpKalInfo = UIDropDownMenu_CreateInfo()
            fpKalInfo.text = "Flight Points - Kalimdor"
            fpKalInfo.notCheckable = true
            fpKalInfo.hasArrow = true
            fpKalInfo.value = "fp_kalimdor"
            UIDropDownMenu_AddButton(fpKalInfo, level)

            local ssInfo = UIDropDownMenu_CreateInfo()
            ssInfo.text = "Dungeon Stones"
            ssInfo.notCheckable = true
            ssInfo.hasArrow = true
            ssInfo.value = "summonstones"
            UIDropDownMenu_AddButton(ssInfo, level)

        elseif level == 2 and UIDROPDOWNMENU_MENU_VALUE == "summonstones" then
            for _, d in ipairs(DHAir.db.destinations) do
                -- Disabled destinations stay in the list (see Queue.lua's
                -- SetDestinationEnabled) but aren't offered for a NEW pick -
                -- same rule ApplyDestination itself enforces server-side,
                -- this is just keeping the menu from offering something
                -- it'd refuse.
                if d.category == "summonstone" and d.enabled ~= false then
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = d.label
                    info.value = d.id
                    info.func = function() DestPick(d.id) end
                    UIDropDownMenu_AddButton(info, level)
                end
            end

        elseif level == 2 and (UIDROPDOWNMENU_MENU_VALUE == "fp_ek" or UIDROPDOWNMENU_MENU_VALUE == "fp_kalimdor") then
            local continent = (UIDROPDOWNMENU_MENU_VALUE == "fp_ek") and "Eastern Kingdoms" or "Kalimdor"
            for _, d in ipairs(DHAir.db.destinations) do
                if d.category == "flightpoint" and d.continent == continent and d.enabled ~= false then
                    local info = UIDropDownMenu_CreateInfo()
                    info.text = d.label
                    info.value = d.id
                    info.func = function() DestPick(d.id) end
                    UIDropDownMenu_AddButton(info, level)
                end
            end
        end
    end)

    -- Footer, bottom row, centered horizontally on the window (2026-08-17,
    -- Loopi - was chained rightward off the BOTTOMRIGHT corner before).
    -- All three buttons share the same fixed 140px width and 8px gap, so
    -- the row's true center falls exactly on the MIDDLE button (Clear
    -- Roster) - anchoring just that one to the frame's centered BOTTOM
    -- point, then chaining Clear Queue off its LEFT and Config off its
    -- RIGHT, centers the whole group and keeps it centered on resize with
    -- no separate container frame needed. Clear Roster is created first
    -- so the other two can anchor off it.
    -- 2026-08-18 (Loopi): renamed from "Clear Roster" - now the hard-clear
    -- (unregisters everyone AND fully wipes the queue, see Roster.lua's
    -- RequestClearRoster) that fixes the orphaned-queue-row edge case a
    -- roster-only clear used to leave behind. "Clear Queue" below is the
    -- softer, Summoner/Clicker-preserving action now.
    frame.clearRosterBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.clearRosterBtn:SetSize(140, 22)
    frame.clearRosterBtn:SetPoint("BOTTOM", frame, "BOTTOM", 0, 40)
    frame.clearRosterBtn:SetText("Clear Roster/Queue")
    frame.clearRosterBtn:SetScript("OnClick", function()
        if DHAir:RequestClearRoster() then
            DHAir:Print("Roster and queue cleared for everyone.")
        end
        DHAir:Board_Refresh()
    end)

    frame.configBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.configBtn:SetSize(140, 22)
    frame.configBtn:SetPoint("LEFT", frame.clearRosterBtn, "RIGHT", 8, 0)
    frame.configBtn:SetText("Config")
    frame.configBtn:SetScript("OnClick", function()
        if DHAir.Config_Open then
            DHAir:Config_Open()
        end
    end)

    -- 2026-08-18 (Loopi): the softer of the two clear actions now - only
    -- drops the "waiting for a summon" rows, leaving registered
    -- Summoners/Clickers (and their own queue rows) untouched, so a
    -- routine reset doesn't boot the working crew off the Board. Use
    -- "Clear Roster/Queue" for the full wipe, including role registration
    -- - a Summoner/Clicker who logs off or swaps characters without
    -- toggling their role off first still stays counted as "ready" until
    -- the 45-minute TTL quietly ages them out either way.
    frame.clearAllBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.clearAllBtn:SetSize(140, 22)
    frame.clearAllBtn:SetPoint("RIGHT", frame.clearRosterBtn, "LEFT", -8, 0)
    frame.clearAllBtn:SetText("Clear Queue")
    frame.clearAllBtn:SetScript("OnClick", function()
        if DHAir:RequestClearAll() then
            DHAir:Print("Waiting queue cleared for everyone (Summoners/Clickers unaffected).")
        end
        DHAir:Board_Refresh()
    end)

    -- Set/Change Destination (2026-08-04, moved here from a per-row button
    -- on your own queue row - see CreateRow/RenderRow). 2026-08-15: was
    -- chained off Clear Queue's left edge. 2026-08-17 (Loopi): pulled onto
    -- its own row below the Config/Clear Roster/Clear Queue row, centered
    -- horizontally on the frame (was left-justified for one session) -
    -- its width (re-measured every refresh, see Board_Refresh, same idiom
    -- autoSummonBtn already uses) now grows symmetrically from its
    -- centered anchor instead of rightward from a fixed left edge, so it
    -- stays centered as its label text changes too. Only shown while
    -- queued - Board_Refresh toggles it.
    frame.setDestBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.setDestBtn:SetSize(140, 22)
    frame.setDestBtn:SetPoint("BOTTOM", frame, "BOTTOM", 0, 10)
    frame.setDestBtn:SetText("Set Destination")
    frame.setDestBtn:SetScript("OnClick", function()
        if frame.destDropdown then
            -- Always retarget to self before opening from the footer - the
            -- same menu also serves per-row "set it for them" clicks (M3),
            -- and inheriting a leftover target here would silently change
            -- someone else's destination while the button said "Change
            -- Destination" about your own.
            frame.destTarget = nil
            ToggleDropDownMenu(1, nil, frame.destDropdown, frame.setDestBtn, 0, 0)
        end
    end)

    -- Abort Summon (2026-08-04, Loopi-requested) - force-resets a stuck
    -- summon (see Summon.lua's AbortSummon) without needing a UI reload.
    -- Only shown while there's actually something to abort - Board_Refresh
    -- toggles it based on DHAir.summonState. Repositioned 2026-08-18
    -- (Loopi-reported): now directly under Broadcast to Guild - the slot
    -- Auto Summons used to occupy before it moved beside Broadcast to
    -- Guild (see above) - instead of actionBar's TOPRIGHT, which put it
    -- on the same row as (and overlapping) Auto Summons.
    frame.abortBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.abortBtn:SetSize(110, 22)
    frame.abortBtn:SetPoint("TOPRIGHT", frame.broadcastBtn, "BOTTOMRIGHT", 0, -8)
    frame.abortBtn:SetText("Abort Summon")
    frame.abortBtn:Hide()
    frame.abortBtn:SetScript("OnClick", function()
        -- Fallback only - real clicks land on abortSecure (below), which
        -- covers this button. Kept so state still resets if the overlay
        -- is ever mispositioned.
        DHAir:AbortSummon()
        DHAir:Board_Refresh()
    end)

    -- 2026-08-05: the abort click must ALSO run through a secure dispatch -
    -- /stopcasting (SpellStopCasting) is protected, same class of problem
    -- as k-0010's cast, so the plain OnClick above resets the state
    -- machine and prints, but the in-flight Ritual cast kept right on
    -- going. Same k-0018 pattern as confirmSummonSecure: bare invisible
    -- SecureActionButtonTemplate, parented AND anchored only to UIParent
    -- (overlaid on abortBtn by PositionSecureOverlays - NEVER anchor it
    -- to abortBtn/frame, that recreates the restricted anchor family),
    -- "HIGH" strata, shown/hidden with the window. PreClick arms
    -- "/stopcasting" ONLY when a summon is actually in flight - an idle
    -- click stays disarmed so it can't cancel an unrelated cast (your
    -- own hearthstone, etc.), it just prints "Nothing to abort".
    frame.abortSecure = CreateFrame("Button", nil, UIParent, "SecureActionButtonTemplate")
    frame.abortSecure:SetSize(110, 22)
    frame.abortSecure:SetFrameStrata("HIGH")
    frame.abortSecure:Hide() -- shown by the window's OnShow hook
    if GetCVarBool and GetCVarBool("ActionButtonUseKeyDown") then
        frame.abortSecure:RegisterForClicks("AnyDown")
    else
        frame.abortSecure:RegisterForClicks("AnyUp")
    end
    frame.abortSecure:SetScript("PreClick", function(self)
        -- Decide BEFORE AbortSummon resets the state machine - that's
        -- how we know whether a cast might actually be in flight.
        if DHAir.summonState ~= "idle" then
            self:SetAttribute("type", "macro")
            self:SetAttribute("macrotext", "/stopcasting")
        else
            self:SetAttribute("type", nil)
        end
        DHAir:AbortSummon()
    end)
    frame.abortSecure:SetScript("PostClick", function()
        DHAir:Board_Refresh()
    end)

    -- Confirm Summon (2026-08-04, one-click auto-summon redesign) - the
    -- ONE control that actually casts on whoever auto-summon's FIFO
    -- picker chose. WoW's UI security model doesn't let an addon cast a
    -- spell/target a unit without a real click happening at that exact
    -- moment (see Summon.lua's BeginCast comment) - so auto-summon now
    -- auto-PICKS the next eligible person (still respecting destination
    -- matching, claims, everything TrySummonNext already did) and waits
    -- here for one click per summon, instead of trying and silently
    -- failing to cast on its own. Anchored below abortBtn in the same
    -- corner (both can be visible together - "ready" is itself a
    -- non-idle state, so you can Abort a pick you don't want instead of
    -- confirming it). Gold text so it stands out against the rest of the
    -- action bar - this is the button auto-summon exists to make you not
    -- have to hunt for. Text/width re-measured every refresh, same idiom
    -- autoSummonBtn/setDestBtn already use.
    -- 2026-08-06 (k-0010, then reworked same day per brief-001 follow-up
    -- #3): originally this ONE widget was itself SecureActionButtonTemplate,
    -- with Board_Refresh calling SetText/SetWidth/Show/Hide on it every
    -- refresh. Confirmed (three isolated diagnostic builds) that ANY
    -- SecureActionButtonTemplate widget silently breaks other text/state
    -- on the window as soon as something OUTSIDE a real click (the
    -- automatic once-a-second refresh ticker, specifically) touches its
    -- Show/Hide/SetWidth/SetPoint - no Lua error, doesn't require combat,
    -- doesn't match the documented combat-only restriction (Object
    -- security, Warcraft Wiki lists positioning/sizing/visibility as the
    -- restricted operations, which lines up exactly with what Board_Refresh
    -- was doing here every tick). Reparenting didn't help; only removing
    -- the template did.
    --
    -- Now split in two: frame.confirmSummonBtn (below) is a PLAIN button -
    -- all the dynamic stuff (label text, width, show/hide by state) still
    -- lives here exactly as before, freely updated every refresh. The
    -- actual protected click-target is frame.confirmSummonSecure - and as
    -- of 2026-08-05 it is FULLY anchor-family-isolated from the window:
    -- parented to UIParent and anchored ONLY to UIParent (never to frame/
    -- abortBtn - that anchor was what poisoned the window, see
    -- PositionSecureOverlays' comment near the top of this file). It has
    -- no visual skin (invisible), is sized generously, sits on a higher
    -- strata ("HIGH" vs the window's default MEDIUM, so SetToplevel
    -- click-raising can't lift the window above it), and is overlaid on
    -- the cosmetic button's corner by PositionSecureOverlays on window
    -- show / drag stop / resize stop. Shown/hidden in lockstep with the
    -- window via the OnShow/OnHide hooks up top. An idle click when
    -- there's nothing to confirm is harmless - ConfirmSummon() already
    -- refuses gracefully ("Nothing is waiting to be confirmed").
    frame.confirmSummonBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.confirmSummonBtn:SetSize(150, 22)
    frame.confirmSummonBtn:SetPoint("TOPRIGHT", frame.abortBtn, "BOTTOMRIGHT", 0, -4)
    frame.confirmSummonBtn:GetFontString():SetTextColor(1, 0.82, 0)
    frame.confirmSummonBtn:Hide()

    -- The real, protected click-target - see the comment above. Bare
    -- SecureActionButtonTemplate only (no button-skin template), so it
    -- has no texture/label of its own - purely a click-catcher. Sized
    -- wider than confirmSummonBtn will ever need (covers up to a long
    -- "Confirm Summon: Name-Realm" label) since, unlike the cosmetic
    -- button, this one's width is fixed forever after this one creation
    -- call.
    frame.confirmSummonSecure = CreateFrame("Button", nil, UIParent, "SecureActionButtonTemplate")
    frame.confirmSummonSecure:SetSize(220, 22)
    frame.confirmSummonSecure:SetFrameStrata("HIGH")
    frame.confirmSummonSecure:Hide() -- shown by the window's OnShow hook
    -- 2026-08-05: the 1.15 client inherited Wrath 3.4.1's secure-button
    -- change - the secure dispatch only executes for the click PHASE
    -- (down vs up) matching the ActionButtonUseKeyDown cvar. Unregistered
    -- buttons only respond to LeftButtonUp, and the cvar defaults to
    -- key-down, so PreClick ran (state machine advanced) but the macro
    -- never dispatched: the click looked completely dead. Register
    -- exactly the ONE matching phase (never both - that would run
    -- PreClick twice per physical click, and the second pass would
    -- disarm/re-run ConfirmSummon).
    if GetCVarBool and GetCVarBool("ActionButtonUseKeyDown") then
        frame.confirmSummonSecure:RegisterForClicks("AnyDown")
    else
        frame.confirmSummonSecure:RegisterForClicks("AnyUp")
    end
    frame.confirmSummonSecure:SetScript("PreClick", function(self)
        self:SetAttribute("type", nil)
        DHAir:ConfirmSummon()
        local unit = DHAir.pendingCastUnit
        DHAir.pendingCastUnit = nil
        if unit then
            self:SetAttribute("type", "macro")
            self:SetAttribute("macrotext", DHAir:BuildCastMacro(unit))
        end
    end)
    -- PostClick (after the secure dispatch, not PreClick/before it) so
    -- the refresh reflects the post-cast state (summonState is already
    -- "casting" by then, same as the original OnClick's timing intent).
    frame.confirmSummonSecure:SetScript("PostClick", function()
        DHAir:Board_Refresh()
    end)
    -- First-ever open: the window is created already-shown, so the OnShow
    -- hook won't fire this time - sync the click-catchers directly. The
    -- window's rects may not have resolved yet this same frame;
    -- PositionSecureOverlays retries next frame on its own.
    SetOverlaysShown(true)
    PositionSecureOverlays()

    -- Throttled live ticker: keeps wait times counting up and catches any
    -- state changes without needing every mutation point in the addon to
    -- remember to call Board_Refresh() itself.
    frame:SetScript("OnUpdate", function(self, elapsed)
        lastRefresh = lastRefresh + elapsed
        if lastRefresh >= REFRESH_INTERVAL then
            lastRefresh = 0
            DHAir:Board_Refresh()
        end
    end)
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

function DHAir:Board_Open()
    if not frame then
        if InCombatLockdown() then
            DHAir:Print("The Air Service board can't be built while in combat - it will open automatically the instant combat ends.")
            QueueCombatCatchup(function() DHAir:Board_Open() end)
            return
        end
        CreateBoardFrame()
    end
    frame:Show()
    lastRefresh = REFRESH_INTERVAL -- force an immediate refresh on open
end

function DHAir:Board_Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        self:Board_Open()
    end
end
