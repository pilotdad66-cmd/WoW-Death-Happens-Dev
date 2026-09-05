-- DH-Tools: Modules\DHBavin\BagMail.lua
-- Milestone 5 (see this folder's DH-Bavin-Design.md): in-bag highlighting
-- + mailbox helper. Both features are Blizzard-frame hooks (bag frames
-- and buttons can't be replaced with a standalone window), and BOTH are
-- explicitly flagged in the Design doc as unverified-API risk against
-- this client's Classic Era build (Interface 11509) - same category as
-- DH-Quests' M1 GetQuestLogTitle field-order surprise and DH-Tools'
-- original UIDropDownMenu/EasyMenu failure (k-0003/k-0004). NOTHING in
-- this file has been in-game tested. Loopi asked to keep building
-- without waiting for the next test pass (2026-08-04) - this is written
-- against well-precedented Classic-era addon idioms (the same
-- ContainerFrame_Update hook and SendMailAttachmentN button-click
-- pattern real bag/mail addons like Postal have used for years, per the
-- Design doc's own "precedented but unverified" framing), with defensive
-- nil-checks and clear chat error messages everywhere a wrong assumption
-- about this specific client's frame names would otherwise throw a
-- silent or confusing failure.
--
-- Priority list matching is by item NAME (see Sync.lua's priorityList
-- comment for the 2026-08-04 rationale) - a bag slot's link is resolved
-- to a name via GetItemInfo(link), same approach Tooltip.lua already
-- uses successfully for Bavin Points, before checking ns.priorityList.
--
-- SCOPE: highlighting is a guild-wide informational feature, not
-- recipient/editor-gated - every guild member's client already holds a
-- full ns.priorityList (ITEM/ITEMGONE broadcasts and SYNCDATA are
-- applied to EVERY receiving client, not just the recipient/editors -
-- CanEditList only gates who's allowed to SEND a change, see Sync.lua),
-- and per Design doc "every client with a recipient configured" should
-- see highlights so anyone can spot something worth donating. The
-- mailbox helper is the same: available to anyone, not just the
-- recipient (obviously - the RECIPIENT is who mail gets addressed TO,
-- everyone ELSE is who's sending mail).

local DHTools = DHTools
local ns = DHTools.Bavin

--------------------------------------------------------------------------
-- API fallbacks (Classic Era has been mid-migration to the C_Container
-- namespace across various patches - same defensive dual-path idiom
-- already used elsewhere in this codebase, e.g. IsAddOnInstalled's
-- C_AddOns/GetAddOnInfo fallback, Sync.lua's C_ChatInfo/SendAddonMessage
-- fallback)
--------------------------------------------------------------------------

local function GetBagSlotLink(bagID, slotID)
    if C_Container and C_Container.GetContainerItemLink then
        return C_Container.GetContainerItemLink(bagID, slotID)
    elseif GetContainerItemLink then
        return GetContainerItemLink(bagID, slotID)
    end
    return nil
end

local function GetBagNumSlots(bagID)
    if C_Container and C_Container.GetContainerNumSlots then
        return C_Container.GetContainerNumSlots(bagID)
    elseif GetContainerNumSlots then
        return GetContainerNumSlots(bagID)
    end
    return 0
end

local function DoPickupContainerItem(bagID, slotID)
    if C_Container and C_Container.PickupContainerItem then
        C_Container.PickupContainerItem(bagID, slotID)
    elseif PickupContainerItem then
        PickupContainerItem(bagID, slotID)
    end
end

-- Resolves a bag slot straight to a priority-list match (or nil): link ->
-- name (GetItemInfo) -> ns.priorityList lookup. Returns the matched name,
-- or nil if the slot is empty, unresolved, or not on the list.
local function MatchedPriorityName(bagID, slotID)
    if not ns.priorityList or next(ns.priorityList) == nil then return nil end
    local link = GetBagSlotLink(bagID, slotID)
    if not link then return nil end
    local name = GetItemInfo(link)
    if not name then return nil end
    if ns.priorityList[name] then return name end
    return nil
end

--------------------------------------------------------------------------
-- In-bag highlighting
--------------------------------------------------------------------------
-- Hooks the classic (non-combined-bags) ContainerFrame_Update, called by
-- Blizzard's own bag UI every time a container frame's buttons are
-- (re)populated - the standard hook point real Classic bag addons use
-- for exactly this kind of overlay. hooksecurefunc, not a raw override,
-- so this can never break Blizzard's own bag rendering even if something
-- here goes wrong (a hooksecurefunc failure is isolated by WoW's own
-- pcall-like protection around secure hooks).
--
-- NOT YET VERIFIED against Interface 11509: whether this event/function
-- still exists unchanged (Blizzard has, in some patches/versions,
-- introduced combined-bag frames using a different update path) - if
-- highlights never appear at all in testing, this hook point not firing
-- is the first thing to check (see STATUS.md).

local highlightOverlays = {} -- itemButton -> texture, built lazily per button

local function GetOrCreateOverlay(itemButton)
    local overlay = highlightOverlays[itemButton]
    if overlay then return overlay end
    overlay = itemButton:CreateTexture(nil, "OVERLAY")
    overlay:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    overlay:SetBlendMode("ADD")
    overlay:SetPoint("CENTER", itemButton, "CENTER", 0, 0)
    overlay:SetSize(itemButton:GetWidth() * 1.4, itemButton:GetHeight() * 1.4)
    overlay:SetVertexColor(1, 0.82, 0) -- gold, matches PointsEditor/PriorityEditor's "on the list" tint
    overlay:Hide()
    highlightOverlays[itemButton] = overlay
    return overlay
end

local function UpdateContainerFrame(frame)
    if not frame or not frame.GetID then return end
    if not DHTools.IsModuleEnabled("bavin") then return end
    if not ns.db or not ns.db.recipient then return end -- inert until a recipient is set, per Design doc

    local bagID = frame:GetID()
    local name = frame:GetName()
    if not name then return end

    local numSlots = frame.size or GetBagNumSlots(bagID)
    for slotID = 1, (numSlots or 0) do
        local itemButton = _G[name .. "Item" .. slotID]
        if itemButton then
            local matched = MatchedPriorityName(bagID, itemButton:GetID() or slotID)
            local overlay = GetOrCreateOverlay(itemButton)
            if matched then
                overlay:Show()
            else
                overlay:Hide()
            end
        end
    end
end

if ContainerFrame_Update then
    hooksecurefunc("ContainerFrame_Update", UpdateContainerFrame)
end

--------------------------------------------------------------------------
-- Mailbox helper
--------------------------------------------------------------------------
-- Only active while Blizzard's own SendMailFrame is open (MAIL_SHOW/
-- MAIL_CLOSED), per Design doc. Two pieces:
--  1. "Fill Recipient" button - sets the To field, never auto-fills
--     silently (per Design doc, so it never overwrites something the
--     player already typed).
--  2. A small attach-shortcut button layered on any matching bag slot's
--     highlight overlay (only shown while mail is open) - picks the item
--     up and clicks the first open SendMailAttachment slot.
--
-- NOT YET VERIFIED against Interface 11509: SendMailNameEditBox and
-- SendMailAttachment1..N are long-standing Blizzard global frame names
-- from the classic Mail.xml templates and ATTACHMENTS_MAX_SEND is a
-- long-standing Blizzard constant (=12), all high-confidence but never
-- confirmed against this specific client build. GetSendMailItem(i) is
-- used to find the first EMPTY attachment slot. If "Fill Recipient"
-- works but attach-clicking silently does nothing, SendMailAttachmentN's
-- exact naming is the first thing to check (see STATUS.md).

local mailIsOpen = false

local function FindOpenAttachmentSlot()
    local maxAttach = ATTACHMENTS_MAX_SEND or 12
    for i = 1, maxAttach do
        if not GetSendMailItem(i) then
            return i
        end
    end
    return nil
end

-- 2026-08-05 (Loopi): the guild's recipient roster is realm-less by
-- design (Core.lua's NormalizeName strips everything after "-", and the
-- Config page's roster picker feeds names from that same cache) - fine
-- for same-realm guild chat/whispers, but SendMailNameEditBox needs the
-- realm suffix to reliably address "Bavin" rather than risk ambiguity,
-- hence appending it explicitly below rather than trusting
-- ns.db.recipient alone. Hardcoded rather than GetRealmName() (the
-- LOCAL player's own realm) since a connected-realm player logging in
-- from a different individual realm than the guild's home realm would
-- otherwise get the wrong suffix - this addon serves one specific guild
-- on one specific realm.
local RECIPIENT_REALM = "SkullRock"

-- 2026-08-05 (Loopi): "Bavin Wants" now also auto-attaches every bag item
-- on the priority list, not just the recipient - scans ALL bags directly
-- (bagID 0 = backpack, 1..NUM_BAG_SLOTS = the four bag slots), not just
-- whatever ContainerFrame happens to be open on screen, since
-- GetContainerItemLink/GetContainerNumSlots read bag contents regardless
-- of whether the bag frame UI is showing - unlike the per-item attach
-- overlay buttons above, this doesn't need bags open at all. Reuses
-- MatchedPriorityName/FindOpenAttachmentSlot/DoPickupContainerItem
-- exactly as the per-item overlay does (same PickupContainerItem+Click
-- pattern, called from this button's own OnClick, i.e. still a real
-- hardware click driving every pickup/attach - same security model).
-- Returns (attachedCount, ranOutOfSlots) so the caller can report both
-- how many it grabbed and whether it stopped early because the mail's
-- 12 attachment slots filled up before every matching item did.
local function AttachAllWantedItems()
    if not ns.priorityList or next(ns.priorityList) == nil then
        return 0, false
    end
    local attached = 0
    local ranOutOfSlots = false
    for bagID = 0, (NUM_BAG_SLOTS or 4) do
        local numSlots = GetBagNumSlots(bagID)
        for slotID = 1, (numSlots or 0) do
            if MatchedPriorityName(bagID, slotID) then
                local slotIndex = FindOpenAttachmentSlot()
                if not slotIndex then
                    ranOutOfSlots = true
                    break
                end
                local attachBtn = _G["SendMailAttachment" .. slotIndex]
                if attachBtn then
                    DoPickupContainerItem(bagID, slotID)
                    attachBtn:Click()
                    attached = attached + 1
                end
            end
        end
        if ranOutOfSlots then break end
    end
    return attached, ranOutOfSlots
end

local fillRecipientBtn

local function CreateFillRecipientButton()
    if fillRecipientBtn then return fillRecipientBtn end
    if not SendMailFrame then return nil end
    local btn = CreateFrame("Button", "DHBavinFillRecipientButton", SendMailFrame, "UIPanelButtonTemplate")
    btn:SetSize(110, 20)
    btn:SetText("Bavin Wants")
    -- 2026-08-05 (Loopi): was anchored to SendMailNameEditBox's RIGHT
    -- edge (8px gap) - Loopi reported it overlapping other mail-frame UI.
    -- Moved above the frame's own top edge instead, on the reasoning
    -- that nothing Blizzard (or a mail addon) draws outside the frame's
    -- own bounds, so it could never overlap anything else.
    -- 2026-08-05 (Loopi, later same day): in-game testing (with Postal
    -- both installed and disabled) found the button WAS present and
    -- functional up there in both cases, but it blended into the
    -- game-world background behind it and was easy to miss - a
    -- readability problem, not the frame-hook failure this was
    -- originally flagged as risking. Moved outside the frame's
    -- BOTTOMRIGHT corner (0, -4) next, which fixed the blend-in but
    -- reintroduced the ORIGINAL "too low" complaint - anchoring outside
    -- the frame at all (top or bottom) puts it over the 3D world, and
    -- "below the frame" reads as noticeably lower than "above" it
    -- despite both being small pixel offsets.
    -- 2026-08-05 (Loopi, still later): reported "about 2 inches too
    -- low" again after that move. Fix: stop anchoring OUTSIDE the frame
    -- entirely - anchor INSIDE the frame's own BOTTOMRIGHT corner
    -- instead, overlapping the frame's opaque parchment texture rather
    -- than the game world. That corner is empty in the default
    -- SendMailFrame layout (Send Mail/Cancel buttons sit more toward
    -- bottom-center), so this shouldn't collide with Blizzard's own
    -- buttons - but ask Loopi to confirm in-game, same as every other
    -- placement guess in this file.
    -- 2026-08-05 (Loopi, still later): still "way too low" (1.5-2
    -- inches) even anchored INSIDE the frame's bottom-right corner -
    -- the frame's own bottom edge just sits low on screen, so any
    -- bottom-corner anchor reads as low regardless of inside/outside.
    -- Moved to the frame's TOPRIGHT corner instead, still INSIDE the
    -- frame (keeps the parchment-texture-not-game-world fix), offset
    -- left/down from the corner to clear the standard ~32px close
    -- button that sits right at TOPRIGHT on Blizzard frames.
    -- 2026-08-05 (Loopi, still later): TOPRIGHT placement covered the
    -- postage-cost text instead. Loopi gave an explicit target this
    -- time rather than another blind guess: bottom-right, underneath
    -- the Send Mail/Cancel buttons - i.e. back outside the frame's
    -- BOTTOMRIGHT corner (like the earlier "too low" attempt), but
    -- lower still so it clears the button row instead of sitting flush
    -- against the frame edge. This deliberately reintroduces the
    -- game-world-blend-in risk from that earlier attempt - Loopi is
    -- choosing this tradeoff explicitly, so don't "fix" the blend-in by
    -- moving it again without asking first.
    -- 2026-08-05 (Loopi, still later): -30 was "even further away" -
    -- WRONG DIRECTION from what "move up 2+ inches" would suggest if
    -- pixel offsets mapped linearly to Loopi's on-screen inches, which
    -- they evidently don't at this UI scale (small offset changes here
    -- have swung between "2 inches too low" and "way too low" in
    -- earlier attempts too). Pulled all the way in to sit flush against
    -- the frame's bottom edge (-2, as close as possible without
    -- clipping into the frame texture) rather than guessing another mid
    -- -range offset. Asked Loopi for a screenshot to stop guessing
    -- blind if this still isn't right.
    -- 2026-08-05 (Loopi, still later): screenshot showed the ACTUAL
    -- root cause of every "too low"/"too far" mismatch above - the
    -- button was ~170-190px below the visible parchment border, in the
    -- game-world background, even at offset -2. SendMailFrame's real
    -- SetPoint bounds extend well past its visible art (common Blizzard
    -- template padding), so anchoring to SendMailFrame's own corners was
    -- never going to land visually where it looked like it should,
    -- regardless of the offset - explains why every prior offset guess
    -- read as wildly wrong in inconsistent directions. Fix: anchor to
    -- the actual Cancel button (SendMailCancelButton) instead of the
    -- frame itself - directly under it and right-aligned with it, which
    -- is exactly "bottom right, underneath Send/Cancel" as originally
    -- requested, and immune to the frame's invisible padding since it's
    -- anchored to a real visible button. Falls back to the old
    -- SendMailFrame-corner anchor if SendMailCancelButton doesn't exist
    -- on this client (defensive, per this file's own nil-check idiom).
    if SendMailCancelButton then
        btn:SetPoint("TOPRIGHT", SendMailCancelButton, "BOTTOMRIGHT", 0, -6)
    else
        btn:SetPoint("TOPRIGHT", SendMailFrame, "BOTTOMRIGHT", 0, -2)
    end
    btn:SetScript("OnClick", function()
        if not ns.db or not ns.db.recipient then
            ns.Print("No recipient configured yet.")
            return
        end
        if SendMailNameEditBox then
            local recipientName = ns.db.recipient
            if not recipientName:find("-", 1, true) then
                recipientName = recipientName .. "-" .. RECIPIENT_REALM
            end
            SendMailNameEditBox:SetText(recipientName)
        end
        -- 2026-08-05 (Loopi): also grab every bag item on the priority
        -- list, not just the recipient - see AttachAllWantedItems above.
        local attached, ranOutOfSlots = AttachAllWantedItems()
        if attached > 0 then
            ns.Print("Attached " .. attached .. " item(s) from the Bavin Wants list."
                .. (ranOutOfSlots and " Ran out of open attachment slots - some matches were left in your bags." or ""))
        elseif ranOutOfSlots then
            ns.Print("No open attachment slots - nothing was attached.")
        end
    end)
    fillRecipientBtn = btn
    return btn
end

-- Attach-shortcut overlay buttons (separate from the plain highlight
-- texture above, which stays purely decorative/click-through so normal
-- bag interaction is never at risk from this file). Only meaningfully
-- clickable while mail is open; created lazily alongside the highlight
-- overlay so both share the same itemButton bookkeeping.
local attachOverlays = {} -- itemButton -> button

local function GetOrCreateAttachButton(itemButton)
    local btn = attachOverlays[itemButton]
    if btn then return btn end
    btn = CreateFrame("Button", nil, itemButton)
    btn:SetSize(14, 14)
    btn:SetPoint("BOTTOMRIGHT", itemButton, "BOTTOMRIGHT", -1, 1)
    btn:SetNormalTexture("Interface\\Icons\\INV_Letter_15")
    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    btn:Hide()
    btn:SetScript("OnClick", function()
        local bagID = itemButton:GetParent() and itemButton:GetParent():GetID()
        local slotID = itemButton:GetID()
        if not bagID or not slotID then return end
        local slotIndex = FindOpenAttachmentSlot()
        if not slotIndex then
            ns.Print("No open attachment slots on this mail.")
            return
        end
        local attachBtn = _G["SendMailAttachment" .. slotIndex]
        if not attachBtn then
            ns.Print("Couldn't find the mail attachment slot - this client's mail frame may differ from what DH-Bavin expects. See claude\\DH-Bavin\\STATUS.md.")
            return
        end
        DoPickupContainerItem(bagID, slotID)
        attachBtn:Click()
    end)
    attachOverlays[itemButton] = btn
    return btn
end

-- Extends UpdateContainerFrame's per-slot pass with the attach button's
-- visibility - kept as a second hooksecurefunc rather than folded into
-- the first so bag highlighting (the lower-risk half of M5) keeps
-- working in isolation even if this half has a problem.
local function UpdateMailAttachOverlays(frame)
    if not frame or not frame.GetID then return end
    if not mailIsOpen then
        -- Hide any stale buttons from the last time mail was open -
        -- cheap no-op in the common case (mail closed, nothing to hide).
        for _, btn in pairs(attachOverlays) do btn:Hide() end
        return
    end
    if not DHTools.IsModuleEnabled("bavin") then return end
    if not ns.db or not ns.db.recipient then return end

    local bagID = frame:GetID()
    local name = frame:GetName()
    if not name then return end

    local numSlots = frame.size or GetBagNumSlots(bagID)
    for slotID = 1, (numSlots or 0) do
        local itemButton = _G[name .. "Item" .. slotID]
        if itemButton then
            local matched = MatchedPriorityName(bagID, itemButton:GetID() or slotID)
            local attachBtn = GetOrCreateAttachButton(itemButton)
            if matched then
                attachBtn:Show()
            else
                attachBtn:Hide()
            end
        end
    end
end

if ContainerFrame_Update then
    hooksecurefunc("ContainerFrame_Update", UpdateMailAttachOverlays)
end

local mailFrame = CreateFrame("Frame")
mailFrame:RegisterEvent("MAIL_SHOW")
mailFrame:RegisterEvent("MAIL_CLOSED")
mailFrame:SetScript("OnEvent", function(_, event)
    if not DHTools.IsModuleEnabled("bavin") then return end
    if event == "MAIL_SHOW" then
        mailIsOpen = true
        if ns.db and ns.db.recipient then
            CreateFillRecipientButton()
            if fillRecipientBtn then fillRecipientBtn:Show() end
        end
        -- Force an immediate refresh of any already-open bag frames so
        -- attach overlays appear right away rather than waiting for the
        -- next incidental ContainerFrame_Update call.
        for i = 1, NUM_CONTAINER_FRAMES or 13 do
            local frame = _G["ContainerFrame" .. i]
            if frame and frame:IsShown() then
                UpdateMailAttachOverlays(frame)
            end
        end
    elseif event == "MAIL_CLOSED" then
        mailIsOpen = false
        if fillRecipientBtn then fillRecipientBtn:Hide() end
        for _, btn in pairs(attachOverlays) do btn:Hide() end
    end
end)
