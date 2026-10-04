-- CM4 (DH-Bavin-Credits-Design.md "CM4 as designed", steps 1-3): the
-- incoming-mail side of crediting - ONE "credit this mail" checkbox inside the
-- opened mail (sticky from mail to mail until the mailbox closes) and a
-- diff-based confirmation of what the player actually took, handed to
-- CreditsDonations.lua (ns.CreditsDon_Credit) once per mail.
--
-- WALL 4: nothing in this file runs until ns.CreditsInbox_Install() is
-- called, and the ONLY caller is Credits.lua's InstallInboxHook() - i.e. a
-- character on creditTestReceivers with the master toggle ON. Every other
-- character (including Bavin's, until the real-mail parallel run) never
-- hooks a mail function or creates a frame from here, so his existing
-- script + copy/paste-to-Excel process is untouched.
--
-- How a take becomes a credit (all of it verified by the 2026-10-04 probe,
-- see the design doc's "Step 0 findings"):
--   * hooksecurefunc on TakeInboxItem / TakeInboxMoney / AutoLootMailItem.
--     A hook runs AFTER the original call but BEFORE the inbox changes, so
--     the hook can read exactly what is about to be taken (itemID, count,
--     copper) from GetInboxItem / GetInboxHeaderInfo.
--   * That becomes a PENDING action keyed by (mail key, attachment slot |
--     "money"). The mail key is sender + subject + COD + daysLeft - never
--     the inbox index, because indexes shift when a mail auto-deletes.
--   * The take is confirmed by the next MAIL_INBOX_UPDATE in which that slot
--     is empty (or the mail's money is 0, or the mail is gone). A failed take
--     (bags full) leaves the slot untouched, so nothing is ever credited for
--     it; retries are safe because a pending action is keyed by its slot, so
--     a second attempt replaces the first instead of adding a second credit.
--     An unconfirmed action is dropped after ~10 seconds.
--   * Confirmed actions are gathered per mail and credited as ONE entry
--     after a short quiet period (or immediately on closing the mailbox / at
--     logout), so taking an 8-item mail one click at a time is still a single
--     transaction-log entry.

local DHTools = DHTools
DHTools.Bavin = DHTools.Bavin or {}
local ns = DHTools.Bavin

local EXPIRE = 10          -- seconds an unconfirmed take is remembered
local QUIET = 2.5          -- seconds without a new confirmed take before a mail is credited
                          -- (when it is emptied / gone / not the open mail)
local LONG = 120           -- fallback for a mail left open and partly taken
local CHECK_ANCHOR = "BOTTOMLEFT"   -- in-mail checkbox position on OpenMailFrame
-- Moved up about 2.5 attachment icons (~37 px each) into the mail body
-- (Loopi, 2026-10-04: there is no free space down by the buttons). Layout is
-- still unverified, and Postal changes the open-mail frame.
local CHECK_X, CHECK_Y = 24, 105
local MAX_ATTACH = ATTACHMENTS_MAX_RECEIVE or 16

local installed = false
local sticky = true        -- the remembered "credit this" setting, carried mail to mail
local checked = {}         -- mailKey -> boolean: per-mail override for SPECIAL mail only
local codWarned = {}       -- mailKey -> true once the COD chat line was shown
local pending = {}         -- unconfirmed take actions
local batches = {}         -- mailKey -> { sender, items, copper, lastAt }
local openCheck            -- the single CheckButton inside the opened mail

local function Safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok and ns.CreditsPrint then
        ns.CreditsPrint("|cffff3333inbox hook error:|r " .. tostring(err))
    end
end

local function Clock()
    return GetTime and GetTime() or 0
end

--------------------------------------------------------------------------
-- Mail identity and default checkbox state
--------------------------------------------------------------------------
local function Header(i)
    -- sender, subject, money, CODAmount, daysLeft, hasItem (= count left),
    -- wasRead, wasReturned, textCreated, canReply, isGM
    local _, _, sender, subject, money, cod, daysLeft, hasItem, _, returned, _, _, isGM = GetInboxHeaderInfo(i)
    return {
        sender = sender, subject = subject,
        money = tonumber(money) or 0, cod = tonumber(cod) or 0,
        daysLeft = tonumber(daysLeft) or 0, hasItem = hasItem,
        returned = returned and true or false, gm = isGM and true or false,
    }
end

local function KeyOf(h)
    return ("%s|%s|%.0f|%.4f"):format(h.sender or "", h.subject or "", h.cod, h.daysLeft)
end

local function ItemsLeft(h)
    if type(h.hasItem) == "number" then return h.hasItem end
    return h.hasItem and 1 or 0
end

-- SPECIAL mail: returned, GM, and non-player senders (Auction House /
-- Postmaster - detected by a space in the sender name or no sender at all).
-- These show UNCHECKED whatever the remembered setting is (the player can
-- re-tick one, which affects only that mail), and never change the
-- remembered setting. COD is special too, but locked off.
local function IsSpecial(h)
    if h.returned or h.gm then return true end
    local s = h.sender
    return (not s) or s == "" or s:find(" ", 1, true) ~= nil
end

-- The effective state for one mail: COD never; special mail its own
-- override (default off); everything else the remembered setting. A take of
-- a mail that is not the open one (Open-All style addons, Take All) uses the
-- same rule, so "unopened takes use the current remembered setting".
local function IsChecked(key, h)
    if h.cod > 0 then return false end
    if IsSpecial(h) then return checked[key] == true end
    return sticky
end

--------------------------------------------------------------------------
-- Pending actions and confirmation
--------------------------------------------------------------------------
local function DropPending(key, kind, slot)
    for i = #pending, 1, -1 do
        local a = pending[i]
        if a.key == key and a.kind == kind and a.slot == slot then table.remove(pending, i) end
    end
end

local function Remember(action)
    DropPending(action.key, action.kind, action.slot) -- a retry replaces, never adds
    action.expires = Clock() + EXPIRE
    pending[#pending + 1] = action
    if C_Timer and C_Timer.After then
        C_Timer.After(EXPIRE + 0.5, function() Safe(ns.CreditsInbox_OnInboxUpdate) end)
    end
end

-- kind: "item" (mail i, attachment j), "money" (mail i) or "all"
-- (AutoLootMailItem: every attachment, plus the money).
function ns.CreditsInbox_OnTake(kind, i, j)
    if not i then return end
    local h = Header(i)
    local key = KeyOf(h)
    if h.cod > 0 then
        if not codWarned[key] then
            codWarned[key] = true
            ns.CreditsPrint(("COD mail from %s skipped - COD mail is never credited."):format(h.sender or "?"))
        end
        return
    end
    if not IsChecked(key, h) then return end

    local function AddItem(slot)
        local name, itemID, _, count = GetInboxItem(i, slot)
        if not name and not itemID then return end
        if not name and GetItemInfo then name = GetItemInfo(itemID) end
        Remember({ key = key, kind = "item", slot = slot, sender = h.sender,
            itemID = itemID, name = name, count = tonumber(count) or 1 })
    end
    local function AddMoney()
        if h.money > 0 then
            Remember({ key = key, kind = "money", slot = "money", sender = h.sender, copper = h.money })
        end
    end

    if kind == "item" then
        if j then AddItem(j) end
    elseif kind == "money" then
        AddMoney()
    else
        for slot = 1, MAX_ATTACH do AddItem(slot) end
        AddMoney()
    end
end

local function AddToBatch(a)
    local b = batches[a.key]
    if not b then
        b = { sender = a.sender, items = {}, copper = 0 }
        batches[a.key] = b
    end
    if a.kind == "item" then
        b.items[#b.items + 1] = { itemID = a.itemID, name = a.name, count = a.count }
    else
        b.copper = b.copper + (a.copper or 0)
    end
    b.lastAt = Clock()
end

local function HasPending(key)
    for _, a in ipairs(pending) do
        if a.key == key then return true end
    end
    return false
end

local function Flush(key, force, minQuiet)
    local b = batches[key]
    if not b then return end
    if not force then
        if Clock() - (b.lastAt or 0) < (minQuiet or QUIET) - 0.01 then return end
        if HasPending(key) then return end
    end
    batches[key] = nil
    ns.CreditsDon_Credit({
        sender = b.sender,
        items = b.items,
        copper = b.copper,
        receiver = UnitName and UnitName("player") or nil,
    })
end

local function FlushAll()
    local keys = {}
    for key in pairs(batches) do keys[#keys + 1] = key end
    for _, key in ipairs(keys) do Flush(key, true) end
end
ns.CreditsInbox_FlushAll = FlushAll

local function ScheduleFlush(key, quiet)
    quiet = quiet or QUIET
    if C_Timer and C_Timer.After then
        C_Timer.After(quiet + 0.05, function() Safe(Flush, key, false, quiet) end)
    else
        Flush(key, true)
    end
end

-- The mail the player currently has open (nil if none): its key, or nil.
local function OpenKey()
    if OpenMailFrame and OpenMailFrame.IsShown and not OpenMailFrame:IsShown() then return nil end
    local idx = InboxFrame and InboxFrame.openMailID
    if not idx or not GetInboxNumItems or idx < 1 or idx > (GetInboxNumItems() or 0) then return nil end
    return KeyOf(Header(idx))
end

-- MAIL_INBOX_UPDATE: confirm what disappeared, drop what expired.
function ns.CreditsInbox_OnInboxUpdate()
    if #pending == 0 then return end
    local now = Clock()
    local byKey = {}
    local n = GetInboxNumItems and GetInboxNumItems() or 0
    for i = 1, n do
        local key = KeyOf(Header(i))
        if not byKey[key] then byKey[key] = i end
    end
    local keep, touched = {}, {}
    for _, a in ipairs(pending) do
        local idx = byKey[a.key]
        local confirmed = false
        if not idx then
            confirmed = true -- the mail is gone: everything it held was taken
        elseif a.kind == "item" then
            local name, itemID = GetInboxItem(idx, a.slot)
            confirmed = (name == nil and itemID == nil)
        else
            confirmed = Header(idx).money == 0
        end
        if confirmed then
            AddToBatch(a)
            touched[a.key] = true
        elseif now <= a.expires then
            keep[#keep + 1] = a
        end
    end
    pending = keep
    -- One chat line / log entry per MAIL (2026-10-04, Loopi): while the mail
    -- is still open and still holds something, keep gathering however slowly
    -- the player takes things. It is credited once the mail is emptied or
    -- gone, the player opens another mail or closes this one (see
    -- FlushLeftMail), or the mailbox closes. The long fallback only covers
    -- a window left open for minutes so a crash can't lose the credit.
    local openKey = OpenKey()
    for key in pairs(touched) do
        local idx = byKey[key]
        local emptied = (not idx) or (Header(idx).money == 0 and ItemsLeft(Header(idx)) == 0)
        if emptied or key ~= openKey then
            ScheduleFlush(key, QUIET)
        else
            ScheduleFlush(key, LONG)
        end
    end
end

function ns.CreditsInbox_OnMailFailed(itemID)
    for i = #pending, 1, -1 do
        local a = pending[i]
        if a.kind == "item" and (itemID == nil or a.itemID == itemID) then
            table.remove(pending, i)
            if itemID ~= nil then return end
        end
    end
end

function ns.CreditsInbox_OnMailShow()
    FlushAll()
    sticky = true -- every mailbox visit starts CHECKED
    checked, codWarned, pending, batches = {}, {}, {}, {}
end

--------------------------------------------------------------------------
-- Checkbox state for tests / UI
--------------------------------------------------------------------------
-- By inbox index. The effective state for that mail (false for COD).
function ns.CreditsInbox_IsChecked(i)
    if not GetInboxHeaderInfo or not i then return false end
    local h = Header(i)
    return IsChecked(KeyOf(h), h)
end

-- What clicking the in-mail checkbox does for mail i: COD is locked; special
-- mail records a per-mail override (the remembered setting is untouched); any
-- other mail changes the remembered setting that carries to the next mail.
function ns.CreditsInbox_SetChecked(i, value)
    local h = Header(i)
    if h.cod > 0 then return false end
    value = value and true or false
    if IsSpecial(h) then
        checked[KeyOf(h)] = value
    else
        sticky = value
    end
    return true
end

function ns.CreditsInbox_GetSticky() return sticky end

--------------------------------------------------------------------------
-- UI: ONE checkbox inside the opened mail (OpenMailFrame). Its state is the
-- remembered setting, so the player sees the whole mail before deciding and
-- the choice carries to the next mail until the mailbox closes.
--------------------------------------------------------------------------
local function BuildCheck()
    if openCheck or not OpenMailFrame then return end
    local cb = CreateFrame("CheckButton", "DHBavinOpenMailCheck", OpenMailFrame, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("BOTTOMLEFT", OpenMailFrame, CHECK_ANCHOR, CHECK_X, CHECK_Y)
    local label = cb:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    label:SetPoint("LEFT", cb, "RIGHT", 0, 1)
    label:SetText("Credit this mail (DH-Bavin)")
    cb.label = label
    -- Make the label part of the click target.
    if cb.SetHitRectInsets then cb:SetHitRectInsets(0, -150, 0, 0) end
    cb:SetScript("OnClick", function(self)
        local idx = self.mailIndex
        if idx and not self.locked then
            ns.CreditsInbox_SetChecked(idx, self:GetChecked())
        end
    end)
    cb:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("DH-Bavin credit", 1, 1, 1)
        if self.locked then
            GameTooltip:AddLine("COD mail is never credited.", 1, 0.3, 0.3, true)
        else
            GameTooltip:AddLine("Checked: what you take is credited to the donor's account. The setting carries to the next mail until you close the mailbox.", 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    openCheck = cb
end

local function RefreshCheckUI()
    local cb = openCheck
    if not cb then return end
    local idx = InboxFrame and InboxFrame.openMailID
    local n = GetInboxNumItems and GetInboxNumItems() or 0
    if not idx or idx < 1 or idx > n then
        cb.mailIndex = nil
        cb:Hide()
        return
    end
    local h = Header(idx)
    if h.money == 0 and ItemsLeft(h) == 0 then
        cb.mailIndex = nil -- nothing left in this mail to credit
        cb:Hide()
        return
    end
    cb.mailIndex = idx
    cb.locked = h.cod > 0
    cb:SetChecked(IsChecked(KeyOf(h), h))
    if cb.locked then cb:Disable() else cb:Enable() end
    cb:Show()
end

-- When the open mail changes (another mail opened, this one closed or gone)
-- the mail that was open is done: credit what was taken from it as ONE entry.
local lastOpenKey
local function RefreshCheck()
    local openKey = OpenKey()
    if lastOpenKey and lastOpenKey ~= openKey then
        Flush(lastOpenKey, false, 0) -- skipped while one of its takes is unconfirmed
    end
    lastOpenKey = openKey
    RefreshCheckUI()
end
ns.CreditsInbox_RefreshOpenMail = RefreshCheck

-- Test hook: forget all session state and allow Install to run again.
function ns.CreditsInbox_ResetForTests()
    installed = false
    sticky = true
    lastOpenKey = nil
    checked, codWarned, pending, batches = {}, {}, {}, {}
    ns.creditsInboxFrame = nil
end

--------------------------------------------------------------------------
-- Install (Wall 4 - called ONLY from Credits.lua's InstallInboxHook)
--------------------------------------------------------------------------
function ns.CreditsInbox_Install()
    if installed then return end
    installed = true

    if hooksecurefunc then
        if TakeInboxItem then
            hooksecurefunc("TakeInboxItem", function(i, j) Safe(ns.CreditsInbox_OnTake, "item", i, j) end)
        end
        if TakeInboxMoney then
            hooksecurefunc("TakeInboxMoney", function(i) Safe(ns.CreditsInbox_OnTake, "money", i) end)
        end
        if AutoLootMailItem then
            hooksecurefunc("AutoLootMailItem", function(i) Safe(ns.CreditsInbox_OnTake, "all", i) end)
        end
        if OpenMail_Update then
            hooksecurefunc("OpenMail_Update", function() Safe(RefreshCheck) end)
        end
        if InboxFrame_Update then
            hooksecurefunc("InboxFrame_Update", function() Safe(RefreshCheck) end)
        end
    end
    if OpenMailFrame and OpenMailFrame.HookScript then
        OpenMailFrame:HookScript("OnShow", function() Safe(RefreshCheck) end)
        OpenMailFrame:HookScript("OnHide", function() Safe(RefreshCheck) end)
    end

    local f = CreateFrame("Frame")
    f:RegisterEvent("MAIL_INBOX_UPDATE")
    f:RegisterEvent("MAIL_SHOW")
    f:RegisterEvent("MAIL_CLOSED")
    f:RegisterEvent("MAIL_FAILED")
    f:RegisterEvent("PLAYER_LOGOUT")
    f:SetScript("OnEvent", function(_, event, arg1)
        if event == "MAIL_INBOX_UPDATE" then
            Safe(ns.CreditsInbox_OnInboxUpdate)
            Safe(RefreshCheck)
        elseif event == "MAIL_SHOW" then
            Safe(ns.CreditsInbox_OnMailShow)
        elseif event == "MAIL_CLOSED" or event == "PLAYER_LOGOUT" then
            Safe(FlushAll)
        elseif event == "MAIL_FAILED" then
            Safe(ns.CreditsInbox_OnMailFailed, arg1)
        end
    end)
    ns.creditsInboxFrame = f

    Safe(BuildCheck)
    Safe(RefreshCheck)
end
