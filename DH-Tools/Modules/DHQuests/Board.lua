-- DH-Tools: Modules\DHQuests\Board.lua
-- Milestone 5 (DH-Quests-Design.md): the display window - guild member <->
-- shared quest list. Mirrors DH-Air's Board.lua (own frame, row pool,
-- sortable headers, throttled ticker) but simplified: no live countdown,
-- no queue-mutation actions besides Invite.
--
-- One row per (peer, questID) share, built fresh from Sync.lua's ns.peers
-- table every refresh - this file is a RENDERING LAYER ONLY, same rule as
-- DH-Air's Board.lua: sort order, category detection, and the peer store
-- itself already exist in Scan.lua/Sync.lua/Core.lua; this just reads that
-- state and draws it.
--
-- Character level comes from Core.lua's ns.guildRoster cache (extended
-- this milestone to also capture GetGuildRosterInfo's level field), NOT
-- from the sync protocol - quest level is the only "level"
-- DH-Quests-Design.md's wire format transmits, and a peer's character
-- level is already available locally and authoritatively from the guild
-- roster, so there was no need to add a new protocol field for it.
--
-- Uses DHTools.InitStandaloneWindow for window chrome (toplevel/opaque bg/
-- title-bar drag) rather than duplicating that ~15-line helper - DHQuests
-- already depends on a handful of DHTools entry points (Print,
-- RegisterModule, SetModuleEnabled/IsModuleEnabled, Config_Open; see
-- Core.lua's file header), and this is the same kind of shared utility
-- call, not new coupling in kind. If DHQuests is ever spun off as a
-- standalone addon, this call needs to be replaced with a copy of that
-- helper (the same thing DH-Tools itself did when it copied it from
-- DH-Air rather than depending on DH-Air being installed).

DHQuests = DHQuests or {}
local ns = DHQuests

local ROW_HEIGHT = 22
local REFRESH_INTERVAL = 2 -- seconds; throttles the live ticker (new peer data streams in via CHAT_MSG_ADDON at any time)

-- Column widths, built right-to-left in CreateRow (Invite button anchors to
-- the row's own RIGHT edge, everything else chains off of it) - same idiom
-- as DH-Air's Board.lua, so header buttons below can line up with these
-- exact same numbers instead of guessing independent offsets.
local COL_PLAYER_WIDTH = 110
local COL_LEVEL_WIDTH = 36
local COL_CATEGORY_WIDTH = 70
local COL_QLEVEL_WIDTH = 50
local COL_INVITE_WIDTH = 60
local COL_GAP = 8

local frame
local rowPool = {}
local sortKey, sortDir = "player", "asc"
-- 2026-08-15 (Loopi): quests the local player also has ("common") sort to
-- the top of the list by default - read live from frame.commonFirstCheck
-- each refresh, same ephemeral (not SavedVariables-backed) pattern as
-- onlineCheck/commonOnly below; defaults checked on frame creation.
local commonFirst = true
local lastRefresh = 0

--------------------------------------------------------------------------
-- Data assembly
--------------------------------------------------------------------------

-- Flattens ns.peers[sender][questID] into a plain array of row records,
-- applying the online-only filter and the search box's substring filter
-- (matches sender name OR quest title - covers DH-Quests-Design.md's
-- "filter/sort by player or quest" for the filter half).
-- commonOnly + localSet (2026-08-14, Loopi - "Only Show Quests in
-- Common"): localSet is the same LocalQuestIDSet() the highlight/Invite
-- logic already computes, passed in rather than recomputed here so
-- there's one call per refresh, not two.
local function BuildRows(onlineOnly, searchText, commonOnly, localSet)
    local rows = {}
    local search = (searchText or ""):lower()
    for sender, quests in pairs(ns.peers) do
        for questID, q in pairs(quests) do
            if not onlineOnly or q.status == "online" then
                if not commonOnly or (localSet and localSet[questID]) then
                if search == "" or sender:lower():find(search, 1, true)
                    or (q.title or ""):lower():find(search, 1, true) then
                    local roster = ns.guildRoster and ns.guildRoster[sender]
                    table.insert(rows, {
                        sender = sender,
                        questID = questID,
                        title = q.title or "?",
                        category = q.category or "",
                        level = q.level,
                        status = q.status,
                        charLevel = roster and roster.level,
                        isCommon = localSet and localSet[questID] == true,
                    })
                end
                end
            end
        end
    end
    return rows
end

local function CompareRows(a, b)
    -- 2026-08-15 (Loopi): common quests sort to the top as a primary key,
    -- ahead of whatever column the player has sorted by - that sort still
    -- applies WITHIN each group (common quests among themselves, then
    -- everything else among itself), it just no longer governs common vs.
    -- not. Toggled off via commonFirstCheck, this block is skipped and
    -- behavior is identical to before this feature existed.
    if commonFirst and a.isCommon ~= b.isCommon then
        return a.isCommon
    end

    local av, bv
    if sortKey == "quest" then
        av, bv = a.title:lower(), b.title:lower()
    elseif sortKey == "charlevel" then
        av, bv = a.charLevel or -1, b.charLevel or -1
    elseif sortKey == "questlevel" then
        av, bv = a.level or -1, b.level or -1
    else -- "player"
        av, bv = a.sender:lower(), b.sender:lower()
    end

    if av == bv then
        -- Stable tie-break so equal-key rows don't jitter between refreshes.
        if a.sender ~= b.sender then return a.sender:lower() < b.sender:lower() end
        return a.questID < b.questID
    end
    if sortDir == "asc" then return av < bv else return av > bv end
end

-- Fresh every refresh (cheap - one pass over the local quest log), NOT
-- filtered by the local player's own share toggles: this highlights
-- "you and this guildmate both have questID X" for YOUR benefit, and that
-- should work regardless of whether you've opted to broadcast that
-- category yourself - the sharing toggles only gate outbound traffic
-- (DH-Quests-Design.md's M4 note), never what you can see locally.
local function LocalQuestIDSet()
    local set = {}
    if ns.ScanQuestLog then
        for questID in pairs(ns.ScanQuestLog()) do
            set[questID] = true
        end
    end
    return set
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
    row.bg:SetColorTexture(1, 1, 1, 0.03) -- faint alternating stripe

    -- Drawn on a higher BACKGROUND sub-layer so it sits on top of the
    -- stripe above rather than being overwritten by it.
    -- 2026-08-04 (Loopi-reported: too subtle) - alpha raised 0.12 -> 0.3
    -- and the quest title itself now also switches to a bright green
    -- (see RenderRow) when highlighted, so a shared-in-common quest reads
    -- clearly at a glance instead of needing a close look at the row tint.
    row.highlightBg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.highlightBg:SetAllPoints()
    row.highlightBg:SetColorTexture(0.2, 0.8, 0.3, 0.3)
    row.highlightBg:Hide()

    row.inviteBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.inviteBtn:SetSize(COL_INVITE_WIDTH, 18)
    row.inviteBtn:SetText("Invite")
    row.inviteBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.inviteBtn:Hide()

    row.qlevelText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.qlevelText:SetPoint("RIGHT", row.inviteBtn, "LEFT", -COL_GAP, 0)
    row.qlevelText:SetWidth(COL_QLEVEL_WIDTH)
    row.qlevelText:SetJustifyH("CENTER")

    row.categoryText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.categoryText:SetPoint("RIGHT", row.qlevelText, "LEFT", -COL_GAP, 0)
    row.categoryText:SetWidth(COL_CATEGORY_WIDTH)
    row.categoryText:SetJustifyH("CENTER")

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.nameText:SetWidth(COL_PLAYER_WIDTH)
    row.nameText:SetJustifyH("LEFT")

    row.levelText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.levelText:SetPoint("LEFT", row.nameText, "RIGHT", 4, 0)
    row.levelText:SetWidth(COL_LEVEL_WIDTH)
    row.levelText:SetJustifyH("CENTER")

    -- Quest title fills whatever's left between the level column and the
    -- category column - the only flexible-width piece of the row, same
    -- role DH-Air's Board.lua gives nameText between roleTag and waitText.
    row.questText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.questText:SetPoint("LEFT", row.levelText, "RIGHT", 8, 0)
    row.questText:SetPoint("RIGHT", row.categoryText, "LEFT", -8, 0)
    row.questText:SetJustifyH("LEFT")

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

local function RenderRow(row, data, index, localSet)
    row.bg:SetColorTexture(1, 1, 1, (index % 2 == 0) and 0.03 or 0.0)

    local isOffline = (data.status == "offline")
    if isOffline then
        row.nameText:SetText("|cff888888" .. data.sender .. "|r")
    else
        row.nameText:SetText(data.sender)
    end

    row.levelText:SetText(data.charLevel and tostring(data.charLevel) or "?")
    row.questText:SetText(data.title)
    row.categoryText:SetText(data.category)
    row.qlevelText:SetText(data.level and tostring(data.level) or "?")

    -- Highlight = the local player currently has this same questID active.
    -- Invite is further restricted to online peers only - offline players
    -- can't be invited, so the button would just fail silently/error.
    -- 2026-08-04 (Loopi-reported: too subtle) - the quest title itself now
    -- also turns bright green when highlighted, on top of the row tint
    -- (see CreateRow) - rows are pooled/reused, so the non-highlighted
    -- branch must explicitly reset the color back to white or a
    -- previously-highlighted row would stay green forever.
    local highlighted = localSet[data.questID] == true
    row.highlightBg:SetShown(highlighted)
    if highlighted then
        row.questText:SetTextColor(0.4, 1, 0.4)
    else
        row.questText:SetTextColor(1, 1, 1)
    end
    if highlighted and not isOffline then
        row.inviteBtn:Show()
        row.inviteBtn:SetScript("OnClick", function()
            if C_PartyInfo and C_PartyInfo.InviteUnit then
                C_PartyInfo.InviteUnit(data.sender)
            else
                InviteUnit(data.sender)
            end
        end)
    else
        row.inviteBtn:Hide()
    end

    row:Show()
end

--------------------------------------------------------------------------
-- Full refresh
--------------------------------------------------------------------------

local function UpdateSortHeaderText()
    if not frame then return end
    frame.sortPlayerBtn:SetText(sortKey == "player" and ("Player " .. (sortDir == "asc" and "^" or "v")) or "Player")
    frame.sortQuestBtn:SetText(sortKey == "quest" and ("Quest " .. (sortDir == "asc" and "^" or "v")) or "Quest")
    frame.sortCharLvlBtn:SetText(sortKey == "charlevel" and ("Lvl " .. (sortDir == "asc" and "^" or "v")) or "Lvl")
    frame.sortQuestLvlBtn:SetText(sortKey == "questlevel" and ("Q.Lvl " .. (sortDir == "asc" and "^" or "v")) or "Q.Lvl")
end

function ns.Board_Refresh()
    if not frame or not frame:IsShown() then return end

    local onlineOnly = frame.onlineCheck:GetChecked() and true or false
    local commonOnly = frame.commonCheck:GetChecked() and true or false
    commonFirst = frame.commonFirstCheck:GetChecked() and true or false
    local searchText = frame.searchEdit:GetText() or ""
    -- Computed before BuildRows now (2026-08-14) so commonOnly can filter
    -- on it too, not just the post-hoc highlight/Invite-button pass below.
    local localSet = LocalQuestIDSet()
    local rows = BuildRows(onlineOnly, searchText, commonOnly, localSet)
    table.sort(rows, CompareRows)

    local senders = {}
    for _, r in ipairs(rows) do senders[r.sender] = true end
    local senderCount = 0
    for _ in pairs(senders) do senderCount = senderCount + 1 end
    frame.statText:SetText(("%d shared quest(s) from %d guildmate(s)"):format(#rows, senderCount))

    UpdateSortHeaderText()

    local content = frame.scrollContent
    content:SetWidth(math.max(1, frame.scrollFrame:GetWidth() - 24))
    for i, data in ipairs(rows) do
        local row = AcquireRow(content, i)
        RenderRow(row, data, i, localSet)
    end
    HideRowsFrom(#rows + 1)
    content:SetHeight(math.max(1, #rows * ROW_HEIGHT))
end

--------------------------------------------------------------------------
-- Frame construction (built once, first time the window is opened)
--------------------------------------------------------------------------

local function ApplyResizeBounds(f, minW, minH, maxW, maxH)
    if f.SetResizeBounds then
        pcall(f.SetResizeBounds, f, minW, minH, maxW, maxH)
    else
        pcall(f.SetMinResize, f, minW, minH)
        pcall(f.SetMaxResize, f, maxW, maxH)
    end
end

local function CreateBoardFrame()
    frame = CreateFrame("Frame", "DHQuestsBoardFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(560, 420)
    frame:SetPoint("CENTER")
    frame:SetResizable(true)
    ApplyResizeBounds(frame, 480, 300, 900, 700)
    if frame.TitleText then
        frame.TitleText:SetText("DH-Quests")
    end
    tinsert(UISpecialFrames, "DHQuestsBoardFrame")

    DHTools.InitStandaloneWindow(frame)

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        ns.Board_Refresh()
    end)

    -- Filter bar: search box (matches player or quest, per
    -- DH-Quests-Design.md's "filter ... by player or quest") + online-only
    -- checkbox.
    local searchLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    searchLabel:SetPoint("TOPLEFT", 12, -30)
    searchLabel:SetText("Search:")

    frame.searchEdit = CreateFrame("EditBox", "DHQuestsBoardSearchEdit", frame, "InputBoxTemplate")
    frame.searchEdit:SetSize(160, 20)
    frame.searchEdit:SetAutoFocus(false)
    frame.searchEdit:SetPoint("LEFT", searchLabel, "RIGHT", 8, -2)
    frame.searchEdit:SetScript("OnEscapePressed", frame.searchEdit.ClearFocus)
    frame.searchEdit:SetScript("OnEnterPressed", frame.searchEdit.ClearFocus)
    frame.searchEdit:SetScript("OnTextChanged", function() ns.Board_Refresh() end)

    frame.onlineCheck = CreateFrame("CheckButton", "DHQuestsBoardOnlineCheck", frame, "UICheckButtonTemplate")
    frame.onlineCheck:SetPoint("LEFT", frame.searchEdit, "RIGHT", 12, 2)
    _G[frame.onlineCheck:GetName() .. "Text"]:SetText("Online only")
    frame.onlineCheck:SetScript("OnClick", function() ns.Board_Refresh() end)

    -- "Only Show Quests in Common" (2026-08-14, Loopi) - quests where the
    -- LOCAL player also currently has the quest (same set BuildRows'
    -- commonOnly filter and the row highlight/Invite button both use).
    -- Its own row rather than crowding onto the search-bar row - "Search:
    -- [edit] Online only" plus this label's full length would clip
    -- against the frame at the window's 480px min width.
    frame.commonCheck = CreateFrame("CheckButton", "DHQuestsBoardCommonCheck", frame, "UICheckButtonTemplate")
    frame.commonCheck:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", -4, -4)
    _G[frame.commonCheck:GetName() .. "Text"]:SetText("Only Show Quests in Common")
    frame.commonCheck:SetScript("OnClick", function() ns.Board_Refresh() end)

    -- "Show Quests in Common First" (2026-08-15, Loopi) - sorts common
    -- quests to the top instead of hiding the rest (that's what the
    -- checkbox above does). Ephemeral like its sibling checkboxes above,
    -- not SavedVariables-backed - defaults checked so "at the top by
    -- default" holds every time the Board is first opened this session.
    frame.commonFirstCheck = CreateFrame("CheckButton", "DHQuestsBoardCommonFirstCheck", frame, "UICheckButtonTemplate")
    frame.commonFirstCheck:SetPoint("TOPLEFT", frame.commonCheck, "BOTTOMLEFT", 0, -4)
    _G[frame.commonFirstCheck:GetName() .. "Text"]:SetText("Show Quests in Common First")
    frame.commonFirstCheck:SetChecked(true)
    frame.commonFirstCheck:SetScript("OnClick", function() ns.Board_Refresh() end)

    frame.statText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.statText:SetPoint("TOPLEFT", frame.commonFirstCheck, "BOTTOMLEFT", 4, -8)

    -- Scrollable row list. Created before the sort-header buttons because
    -- those anchor to scrollFrame's own live geometry (same reason DH-Air's
    -- Board.lua does this) so they stay lined up with the actual columns
    -- as the window resizes.
    frame.scrollFrame = CreateFrame("ScrollFrame", "DHQuestsBoardScrollFrame", frame, "UIPanelScrollFrameTemplate")
    frame.scrollFrame:SetPoint("TOPLEFT", frame.statText, "BOTTOMLEFT", 0, -28)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", -30, 12)

    frame.scrollContent = CreateFrame("Frame", nil, frame.scrollFrame)
    frame.scrollContent:SetSize(1, 1)
    frame.scrollFrame:SetScrollChild(frame.scrollContent)

    -- Sortable column headers - built from the SAME column-width constants
    -- as CreateRow, so each header sits above its actual data column at
    -- any window width. Category has no header (not a sortable field per
    -- DH-Quests-Design.md's M5 scope), same as DH-Air's Board.lua leaving
    -- its roleTag column headerless.
    frame.sortPlayerBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.sortPlayerBtn:SetSize(COL_PLAYER_WIDTH, 18)
    frame.sortPlayerBtn:SetPoint("BOTTOMLEFT", frame.scrollFrame, "TOPLEFT", 4, 4)
    frame.sortPlayerBtn:SetScript("OnClick", function()
        sortDir = (sortKey == "player") and (sortDir == "asc" and "desc" or "asc") or "asc"
        sortKey = "player"
        ns.Board_Refresh()
    end)

    frame.sortCharLvlBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.sortCharLvlBtn:SetSize(COL_LEVEL_WIDTH + 10, 18)
    frame.sortCharLvlBtn:SetPoint("LEFT", frame.sortPlayerBtn, "RIGHT", 4, 0)
    frame.sortCharLvlBtn:SetScript("OnClick", function()
        sortDir = (sortKey == "charlevel") and (sortDir == "asc" and "desc" or "asc") or "desc"
        sortKey = "charlevel"
        ns.Board_Refresh()
    end)

    frame.sortQuestBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.sortQuestBtn:SetSize(90, 18)
    frame.sortQuestBtn:SetPoint("LEFT", frame.sortCharLvlBtn, "RIGHT", 12, 0)
    frame.sortQuestBtn:SetScript("OnClick", function()
        sortDir = (sortKey == "quest") and (sortDir == "asc" and "desc" or "asc") or "asc"
        sortKey = "quest"
        ns.Board_Refresh()
    end)

    -- Right-anchored: scrollbar/content inset (24) plus every column to the
    -- right of Quest Level (Invite button + its gap) - matches exactly
    -- what Board_Refresh uses for scrollContent's width and what CreateRow
    -- uses to position qlevelText, so this can't drift out of sync with
    -- either (same idiom as DH-Air's Board.lua waitColRightInset).
    local qlevelRightInset = 24 + 2 + COL_INVITE_WIDTH + COL_GAP

    frame.sortQuestLvlBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.sortQuestLvlBtn:SetSize(COL_QLEVEL_WIDTH + 20, 18)
    frame.sortQuestLvlBtn:SetPoint("BOTTOMRIGHT", frame.scrollFrame, "TOPRIGHT", -qlevelRightInset, 4)
    frame.sortQuestLvlBtn:SetScript("OnClick", function()
        sortDir = (sortKey == "questlevel") and (sortDir == "asc" and "desc" or "asc") or "desc"
        sortKey = "questlevel"
        ns.Board_Refresh()
    end)

    -- Throttled live ticker: catches newly-arrived peer data (streams in
    -- via CHAT_MSG_ADDON at any time) without requiring every mutation
    -- point elsewhere to remember to call Board_Refresh itself - same
    -- idiom as DH-Air's Board.lua.
    frame:SetScript("OnUpdate", function(self, elapsed)
        lastRefresh = lastRefresh + elapsed
        if lastRefresh >= REFRESH_INTERVAL then
            lastRefresh = 0
            ns.Board_Refresh()
        end
    end)
end

--------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------

function ns.Board_Open()
    if not frame then
        CreateBoardFrame()
    end
    frame:Show()
    lastRefresh = REFRESH_INTERVAL -- force an immediate refresh on open
    ns.Board_Refresh()
end

function ns.Board_Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        ns.Board_Open()
    end
end
