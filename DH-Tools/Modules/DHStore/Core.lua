-- "Store" module - guild-only buyout store. Bavin or a Store Officer
-- lists items at a gold price; Bavin Credits price is computed per-
-- viewer (gold price x credit/gold ratio, then the viewer's own tier
-- discount - see DH-Store-Design.md questions #4/#5). Buying generates
-- a purchase-request mail to the Primary Store Officer for manual
-- fulfillment (CM5's debit engine, DH-Bavin's own scope - NOT built by
-- this file, see Sync.lua's header). Hard-dependent on DH-Bavin
-- (RegisterModule's `requires = "bavin"`, question #1) - this module's
-- own permission tiers and tier-discount lookups read DHTools.Bavin's
-- guild roster/Credits ledger directly (question #6). Full design in
-- this folder's DH-Store-Design.md; PROFILE.md has everything already
-- decided.
--
-- NOT YET IN-GAME TESTED - built 2026-09-28, in the same pass as
-- Sync.lua and Widgets\ScrollList.lua.

local DHTools = DHTools
DHTools.Store = DHTools.Store or {}
local ns = DHTools.Store

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99DH-Store:|r " .. msg)
end

--------------------------------------------------------------------------
-- SavedVariables
--------------------------------------------------------------------------
-- Own top-level DHStoreDB (plain SavedVariables, guild-wide, same
-- reasoning as DHBavinDB - see that file's 2026-07-29 comment: this is
-- shared state, not a per-character preference).
function ns.InitDB()
    if type(DHStoreDB) ~= "table" then
        DHStoreDB = {}
    end
    ns.db = DHStoreDB
    if type(ns.db.officers) ~= "table" then
        ns.db.officers = {}
    end
    if type(ns.db.catalog) ~= "table" then
        ns.db.catalog = {}
    end
    ns.db.officersUpdatedAt = ns.db.officersUpdatedAt or 0
    ns.db.catalogUpdatedAt = ns.db.catalogUpdatedAt or 0
    -- creditGoldRatio starts UNSET on purpose - question #5's starting
    -- value ("same ratio as Reputation Points/Gold, ~10 pts/gold per
    -- Chris's recollection") still needs verifying against the real
    -- data before it's safe to assume as a default. Until an officer
    -- sets this via the config page, the credits column shows "—"
    -- rather than a number nobody has confirmed.
    if ns.db.discountAppliesToGold == nil then ns.db.discountAppliesToGold = true end
    if ns.db.discountAppliesToCredits == nil then ns.db.discountAppliesToCredits = true end
    -- Repoint the runtime table at the persistent one, same pattern as
    -- DH-Bavin's ns.priorityList (Sync.lua) - never reassign ns.catalog
    -- again after this, mutate in place (see Sync.lua's own comment).
    ns.catalog = ns.db.catalog
end

--------------------------------------------------------------------------
-- Permission model (question #6's 5-tier hierarchy). Reuses DH-Bavin's
-- own guild roster cache/IsGuildLeader and Credits officer list rather
-- than duplicating them - safe because Store hard-depends on Bavin
-- being enabled (Core.lua's RegisterModule `requires = "bavin"`).
-- NAME-BASED throughout (never the local-only IsAuthorAccount() alone),
-- same split DH-Bavin's own CanEditList/CanSetRecipientName use - these
-- verify a REMOTE sender's claimed identity in Sync.lua, not just what
-- the local client is allowed to do.
--------------------------------------------------------------------------

-- Tier 1 shortcut, matching DH-Bavin's own FULL_PERMISSION_OVERRIDE_NAME
-- ("Loopidot") - same name, same reasoning (see that file's own
-- comment): a hardcoded character name is remote-sender-safe in a way
-- the local-only IsAuthorAccount() can never be.
local FULL_PERMISSION_OVERRIDE_NAME = "Loopidot"

local function NormalizeName(name)
    return DHTools.Bavin.NormalizeName(name)
end

local function IsAuthorOverrideName(name)
    return name ~= nil and NormalizeName(name) == FULL_PERMISSION_OVERRIDE_NAME
end

-- Tier 3: the existing DH-Bavin `recipient` role (question #6.3).
local function IsDonationRecipientName(name)
    if not name or not DHTools.Bavin.db then return false end
    local recipient = DHTools.Bavin.db.recipient
    return recipient ~= nil and NormalizeName(recipient) == NormalizeName(name)
end

-- Tier 4: Store's own officer list.
function ns.IsStoreOfficerName(name)
    if not name or not ns.db then return false end
    local norm = NormalizeName(name)
    for _, officer in ipairs(ns.db.officers) do
        if NormalizeName(officer) == norm then return true end
    end
    return false
end

-- Tiers 1-4: create/edit listings, mark sold, unpend.
function ns.CanManageListings(name)
    if not name then return false end
    if IsAuthorOverrideName(name) then return true end
    if DHTools.Bavin.IsGuildLeader(name) then return true end
    if IsDonationRecipientName(name) then return true end
    if ns.IsStoreOfficerName(name) then return true end
    return false
end

-- Tiers 1-3: manage the Store Officer roster + primary officer
-- (question #6.4: officers themselves cannot add other officers).
function ns.CanManageStoreOfficers(name)
    if not name then return false end
    if IsAuthorOverrideName(name) then return true end
    if DHTools.Bavin.IsGuildLeader(name) then return true end
    if IsDonationRecipientName(name) then return true end
    return false
end

-- LOCAL-only convenience wrappers - author-account shortcut via
-- DHTools.IsAuthorAccount(), safe here since never used to verify a
-- remote sender (Sync.lua calls the name-based functions above
-- directly), same split as DH-Bavin's CanManageRecipient/CanEditListLocal.
function ns.CanManageListingsLocal()
    if DHTools.IsAuthorAccount and DHTools.IsAuthorAccount() then return true end
    return ns.CanManageListings(UnitName("player"))
end

function ns.CanManageStoreOfficersLocal()
    if DHTools.IsAuthorAccount and DHTools.IsAuthorAccount() then return true end
    return ns.CanManageStoreOfficers(UnitName("player"))
end

--------------------------------------------------------------------------
-- Pricing (questions #4/#5): gold price is the officer-entered whole-
-- lot total (copper); credit price = gold price x the officer-
-- configured ratio; the tier discount applies to whichever currencies
-- are toggled on, per-viewer, at display time - never baked into the
-- wire payload (Sync.lua's own header note).
--------------------------------------------------------------------------

local TIER_DISCOUNT_PERCENT = { Neutral = 0, Friendly = 10, Honored = 20, Revered = 30, Exalted = 40 }

-- Reads the LOCAL player's tier/prestige from DH-Bavin's Credits ledger
-- (DHTools.Bavin.creditsDb.ledger, keyed by discordName via toonIndex -
-- see Credits.lua). Nil-safe throughout: CM3's guild-wide ledger sync
-- isn't built yet (Credits.lua's own header), so this data is only ever
-- as current as whatever this client's own local ledger happens to
-- hold - returns "no discount" rather than guessing when it's missing.
function ns.GetLocalTierState()
    local bavin = DHTools.Bavin
    if not bavin or not bavin.creditsDb or not bavin.creditsDb.toonIndex then
        return "Neutral", 0
    end
    local bare = (UnitName("player") or ""):lower()
    local discordName = bavin.creditsDb.toonIndex[bare]
    if not discordName then return "Neutral", 0 end
    local rec = bavin.creditsDb.ledger and bavin.creditsDb.ledger[discordName]
    if not rec then return "Neutral", 0 end
    return rec.tier or "Neutral", rec.prestige or 0
end

-- 0-80, per question #4's resolved formula (Prestige +10%/lap, capped).
function ns.GetLocalDiscountPercent()
    local tier, prestige = ns.GetLocalTierState()
    local pct = TIER_DISCOUNT_PERCENT[tier] or 0
    if tier == "Exalted" and prestige > 0 then
        pct = math.min(80, 40 + prestige * 10)
    end
    return pct
end

-- Returns { goldBase, goldFinal, creditBase (or nil), creditFinal (or
-- nil), discountPercent } for one listing, computed for the LOCAL
-- viewer. creditBase/creditFinal stay nil until an officer configures
-- ns.db.creditGoldRatio (see InitDB's comment).
function ns.ComputePrices(listing)
    local goldBase = listing.goldPrice or 0
    local pct = ns.GetLocalDiscountPercent()
    local goldFinal = ns.db.discountAppliesToGold
        and math.floor(goldBase * (100 - pct) / 100) or goldBase

    local creditBase, creditFinal
    local ratio = ns.db.creditGoldRatio
    if ratio then
        creditBase = math.floor(goldBase * ratio)
        creditFinal = ns.db.discountAppliesToCredits
            and math.floor(creditBase * (100 - pct) / 100) or creditBase
    end

    return {
        goldBase = goldBase, goldFinal = goldFinal,
        creditBase = creditBase, creditFinal = creditFinal,
        discountPercent = pct,
    }
end

-- Plain "Xg Ys Zc" copper formatter - GetCoinTextureString exists
-- client-side but renders inline coin ICONS, which don't fit a struck-
-- through price (question #11) cleanly; this keeps both the struck and
-- final price as plain text on one line.
function ns.FormatMoney(copper)
    copper = math.max(0, math.floor(copper or 0))
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local bronze = copper % 100
    if gold > 0 then
        return string.format("%dg %ds %dc", gold, silver, bronze)
    elseif silver > 0 then
        return string.format("%ds %dc", silver, bronze)
    else
        return string.format("%dc", bronze)
    end
end

--------------------------------------------------------------------------
-- Purchase-request mail (question #3's FIFO resolution mechanism).
-- Plain SendMail(recipient, subject, body) - no attachment, no CoD, so
-- (unlike BagMail.lua's item-attach helper, which drives Blizzard's own
-- SendMailFrame UI because attaching needs that) this can be called
-- directly without the mail UI being open. Actually sending still
-- requires the player be at a mailbox - WoW validates that server-side;
-- there's no reliable Lua-side success callback, so this can't confirm
-- delivery, only that the client attempted it.
--------------------------------------------------------------------------

function ns.SendPurchaseRequestMail(listing)
    local primary = ns.db.primaryOfficer
    if not primary or primary == "" then
        ns.Print("No Primary Store Officer is configured yet - ask an officer to set one.")
        return false
    end
    local prices = ns.ComputePrices(listing)
    local itemName = listing.itemLink or ("item " .. tostring(listing.itemId or "?"))
    local subject = "DH-Store purchase request"
    -- time() (wall-clock) is the precise/sortable FIFO signal an officer
    -- compares across multiple pending requests - see question #3's own
    -- note that WoW's mail UI doesn't expose send time precisely enough.
    local body = string.format(
        "%s wants to buy: %s x%d\nGold: %s   Credits: %s\nRequested: %s (t=%d)\nListing ID: %s",
        UnitName("player") or "?", itemName, listing.quantity or 1,
        ns.FormatMoney(prices.goldFinal),
        prices.creditFinal and tostring(prices.creditFinal) or "n/a",
        date("%Y-%m-%d %H:%M:%S"), time(), listing.listingId)
    if SendMail then
        SendMail(primary, subject, body)
    end
    return true
end

--------------------------------------------------------------------------
-- Main window (question #7's shared ScrollList widget; question #8's
-- search+quality filtering; question #10's discount badge+tooltip;
-- question #11's 2-column struck-through pricing).
--------------------------------------------------------------------------

local frame
local searchText = ""
local qualityFilter = nil -- nil = All

local QUALITY_NAMES = { [0] = "Poor", [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary" }

-- Sorted array snapshot of ns.catalog, filtered by searchText/qualityFilter.
-- Quality comes from GetItemInfo (client item cache) since it isn't on
-- the wire (question #2 keeps the wire payload to itemId/itemLink/
-- quantity/gold only) - falls back to showing the row unfiltered if the
-- cache hasn't resolved it yet, same "best-effort" posture DH-Bavin's
-- ShowItems took on itemLink (see that file's own 2026-08-05 comment).
local function GetFilteredSortedListings()
    local list = {}
    local needle = searchText:lower()
    for _, l in pairs(ns.catalog) do
        local name = (l.itemLink and GetItemInfo(l.itemLink)) or l.itemLink or ("item " .. tostring(l.itemId or "?"))
        local matchesSearch = needle == "" or name:lower():find(needle, 1, true) ~= nil
        local matchesQuality = true
        if qualityFilter ~= nil then
            local _, _, itemQuality = GetItemInfo(l.itemLink or "")
            matchesQuality = (itemQuality == qualityFilter)
        end
        if matchesSearch and matchesQuality then
            table.insert(list, l)
        end
    end
    table.sort(list, function(a, b) return (a.listedAt or 0) > (b.listedAt or 0) end)
    return list
end

local function CreateListingRow(row)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(24, 24)
    row.icon:SetPoint("LEFT", 4, 0)

    row.nameText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.nameText:SetWidth(220)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    row.goldText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.goldText:SetPoint("LEFT", row.nameText, "RIGHT", 4, 0)
    row.goldText:SetWidth(120)
    row.goldText:SetJustifyH("LEFT")

    row.creditText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.creditText:SetPoint("LEFT", row.goldText, "RIGHT", 4, 0)
    row.creditText:SetWidth(90)
    row.creditText:SetJustifyH("LEFT")

    row.buyBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.buyBtn:SetSize(64, 20)
    row.buyBtn:SetPoint("RIGHT", -4, 0)
    row.buyBtn:SetText("Buy")

    -- Officer-only actions, positioned left of Buy - visibility toggled
    -- per-row in UpdateListingRow based on CanManageListingsLocal().
    row.soldBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.soldBtn:SetSize(50, 20)
    row.soldBtn:SetPoint("RIGHT", row.buyBtn, "LEFT", -4, 0)
    row.soldBtn:SetText("Sold")

    row.unpendBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.unpendBtn:SetSize(64, 20)
    row.unpendBtn:SetPoint("RIGHT", row.soldBtn, "LEFT", -4, 0)
    row.unpendBtn:SetText("Unpend")
end

-- WoW's FontString has no native strikethrough style - this is the
-- standard plain-text trick (a combining "long stroke overlay" mark
-- after every byte). Only ever applied to ASCII price strings here
-- (digits/g/s/c/spaces), so a per-byte loop is safe without full UTF-8
-- awareness. NOT YET VERIFIED IN-GAME (font rendering of combining
-- marks can vary by client font).
local function StrikeText(s)
    local out = {}
    for i = 1, #s do
        out[#out + 1] = s:sub(i, i)
        out[#out + 1] = "\204\182" -- U+0336 COMBINING LONG STROKE OVERLAY, UTF-8
    end
    return table.concat(out)
end

-- question #11: base price struck through beside the tier-discounted
-- price, e.g. "~~50g~~ 30g" - only when a discount actually changes the
-- number; otherwise just the plain price (no point striking a price
-- through itself).
local function FormatPriceCell(base, final, applied)
    if not applied or base == final then
        return DHTools.Store.FormatMoney(final or base or 0)
    end
    return "|cff888888" .. StrikeText(DHTools.Store.FormatMoney(base)) .. "|r " .. DHTools.Store.FormatMoney(final)
end

local function UpdateListingRow(row, listing, dataIndex)
    local link = listing.itemLink
    local name, quality = link and GetItemInfo(link)
    local texture = link and select(10, GetItemInfo(link))
    row.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")

    local displayName = name or link or ("item " .. tostring(listing.itemId or "?"))
    if quality then
        local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
        if color then
            displayName = color.hex .. displayName .. "|r"
        end
    end
    row.nameText:SetText(displayName .. " x" .. tostring(listing.quantity or 1)
        .. (listing.pendingBy and "  |cffffcc00(pending)|r" or ""))

    local prices = ns.ComputePrices(listing)
    row.goldText:SetText(FormatPriceCell(prices.goldBase, prices.goldFinal, ns.db.discountAppliesToGold and prices.discountPercent > 0))
    if prices.creditFinal then
        row.creditText:SetText(FormatPriceCell(prices.creditBase, prices.creditFinal, ns.db.discountAppliesToCredits and prices.discountPercent > 0))
    else
        row.creditText:SetText("|cff888888-|r")
    end

    local isOfficer = ns.CanManageListingsLocal()
    row.soldBtn:SetShown(isOfficer)
    row.unpendBtn:SetShown(isOfficer and listing.pendingBy ~= nil)
    row.soldBtn:SetPoint("RIGHT", row.buyBtn, "LEFT", -4, 0)
    if isOfficer and listing.pendingBy then
        row.unpendBtn:SetPoint("RIGHT", row.soldBtn, "LEFT", -4, 0)
    end

    row.soldBtn:SetScript("OnClick", function()
        ns.MarkListingSold(listing.listingId)
        if frame and frame:IsShown() then ns.Store_Refresh() end
    end)
    row.unpendBtn:SetScript("OnClick", function()
        ns.UnpendListing(listing.listingId)
        if frame and frame:IsShown() then ns.Store_Refresh() end
    end)

    if listing.pendingBy then
        row.buyBtn:SetText("Pending")
        row.buyBtn:Disable()
    else
        row.buyBtn:SetText("Buy")
        row.buyBtn:Enable()
    end
    row.buyBtn:SetScript("OnClick", function()
        if ns.MarkListingPending(listing.listingId) then
            ns.SendPurchaseRequestMail(listing)
            ns.Print("Purchase request sent for " .. displayName .. " - visit a mailbox if it didn't send.")
        end
        if frame and frame:IsShown() then ns.Store_Refresh() end
    end)
end

-- question #10: viewer's tier discount as an always-visible badge next
-- to the price columns, plus a richer hover tooltip (tier, points,
-- next-tier target, lifetime points). Points/next-tier data comes from
-- the same local-only Bavin ledger read as GetLocalTierState - see that
-- function's own nil-safety note.
local function UpdateDiscountBadge(badge)
    local tier, prestige = ns.GetLocalTierState()
    local pct = ns.GetLocalDiscountPercent()
    local label = tier .. (prestige > 0 and (" P" .. prestige) or "")
    badge:SetText(label .. ": " .. pct .. "% off")
    badge:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:SetText("DH-Store discount", 1, 1, 1)
        GameTooltip:AddLine("Tier: " .. label, 1, 1, 1)
        local bavin = DHTools.Bavin
        local bare = (UnitName("player") or ""):lower()
        local discordName = bavin and bavin.creditsDb and bavin.creditsDb.toonIndex and bavin.creditsDb.toonIndex[bare]
        local rec = discordName and bavin.creditsDb.ledger[discordName]
        if rec then
            GameTooltip:AddLine("Points: " .. tostring(rec.points or 0), 0.8, 0.8, 0.8)
            GameTooltip:AddLine("Lifetime points: " .. tostring(rec.lifetimePoints or 0), 0.8, 0.8, 0.8)
        else
            GameTooltip:AddLine("No Credits ledger entry found locally yet.", 0.8, 0.8, 0.8)
        end
        GameTooltip:Show()
    end)
    badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function CreateStoreFrame()
    frame = CreateFrame("Frame", "DHStoreFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(560, 460)
    frame:SetPoint("CENTER")
    if frame.TitleText then frame.TitleText:SetText("DH-Store") end
    tinsert(UISpecialFrames, "DHStoreFrame")
    DHTools.InitStandaloneWindow(frame)

    frame.searchEdit = CreateFrame("EditBox", "DHStoreSearchEdit", frame, "InputBoxTemplate")
    frame.searchEdit:SetSize(160, 20)
    frame.searchEdit:SetPoint("TOPLEFT", 16, -32)
    frame.searchEdit:SetAutoFocus(false)
    frame.searchEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    frame.searchEdit:SetScript("OnTextChanged", function(self)
        searchText = (self:GetText() or ""):match("^%s*(.-)%s*$")
        ns.Store_Refresh()
    end)

    frame.qualityDropdown = CreateFrame("Frame", "DHStoreQualityDropdown", frame, "UIDropDownMenuTemplate")
    frame.qualityDropdown:SetPoint("LEFT", frame.searchEdit, "RIGHT", 4, -2)
    UIDropDownMenu_SetWidth(frame.qualityDropdown, 90)
    UIDropDownMenu_Initialize(frame.qualityDropdown, function(_, level)
        local function Pick(q)
            qualityFilter = q
            UIDropDownMenu_SetText(frame.qualityDropdown, q and QUALITY_NAMES[q] or "All qualities")
            CloseDropDownMenus()
            ns.Store_Refresh()
        end
        local allInfo = UIDropDownMenu_CreateInfo()
        allInfo.text = "All qualities"
        allInfo.func = function() Pick(nil) end
        UIDropDownMenu_AddButton(allInfo, level)
        for q, qname in pairs(QUALITY_NAMES) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = qname
            info.func = function() Pick(q) end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetText(frame.qualityDropdown, "All qualities")

    frame.discountBadge = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.discountBadge:SetPoint("TOPRIGHT", -32, -20)
    UpdateDiscountBadge(frame.discountBadge)

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.hint:SetPoint("TOPLEFT", frame.searchEdit, "BOTTOMLEFT", 0, -6)
    frame.hint:SetPoint("RIGHT", -16, 0)
    frame.hint:SetJustifyH("LEFT")
    frame.hint:SetWordWrap(true)
    frame.hint:SetText("Officers: manage listings with /dhs list|sold|unpend - see /dhs help.")

    frame.scrollList = DHTools.Widgets.CreateScrollList(frame, {
        rowHeight = 30,
        rightInset = 24,
        createRow = CreateListingRow,
        updateRow = UpdateListingRow,
        emptyText = "No listings yet.",
    })
    frame.scrollList.frame:SetPoint("TOPLEFT", frame.hint, "BOTTOMLEFT", -4, -8)
    frame.scrollList.frame:SetPoint("BOTTOMRIGHT", -30, 14)

    frame:SetScript("OnShow", ns.Store_Refresh)
end

-- Re-renders the badge and re-filters/re-sorts the catalog into the
-- scroll list. Call after any local mutation or an incoming Sync.lua
-- delta that should be visible immediately.
function ns.Store_Refresh()
    if not frame or not frame:IsShown() then return end
    UpdateDiscountBadge(frame.discountBadge)
    frame.scrollList:SetData(GetFilteredSortedListings())
end

function ns.Store_Toggle()
    if not frame then CreateStoreFrame() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end

--------------------------------------------------------------------------
-- Event wiring - same "gate on IsModuleEnabled, one shared handler"
-- shape as DH-Bavin's own Core.lua.
--------------------------------------------------------------------------
ns.frame = CreateFrame("Frame")
ns.frame:RegisterEvent("PLAYER_LOGIN")
ns.frame:RegisterEvent("CHAT_MSG_ADDON")
ns.frame:SetScript("OnEvent", function(_, event, ...)
    if not DHTools.IsModuleEnabled("store") then return end
    if event == "PLAYER_LOGIN" then
        if ns.Sync_Init then ns.Sync_Init() end
    elseif event == "CHAT_MSG_ADDON" then
        if ns.Sync_OnAddonMessage then ns.Sync_OnAddonMessage(...) end
    end
end)

--------------------------------------------------------------------------
-- Slash command - V1 officer listing management (question #6.4's "gets
-- the GUI for adding/removing store listings" satisfied here via a chat
-- command, same precedent as DH-Bavin's own /dhb additem/removeitem
-- fallback that predated its PriorityEditor.lua UI - a dedicated
-- add-listing form can follow later if the chat command proves
-- unwieldy in practice).
--------------------------------------------------------------------------

local function ShowHelp()
    ns.Print("Commands:")
    ns.Print("  /dhs                       - open the Store browse window")
    ns.Print("  /dhs list <shift-click item> <qty> <gold> - officer: add/edit a listing (gold as a decimal, e.g. 5.5)")
    ns.Print("  /dhs sold <listingId>      - officer: mark a listing sold")
    ns.Print("  /dhs unpend <listingId>    - officer: revert a pending listing to available")
    ns.Print("  /dhs officers <name1,name2,...> - tier 1-3: set the Store Officer roster")
    ns.Print("  /dhs primary <name>        - tier 1-3: set the Primary Store Officer")
    ns.Print("  /dhs on|off                - enable/disable this module")
end

local function HandleListCommand(rest)
    if not ns.CanManageListingsLocal() then
        ns.Print("Refused - you must be a Store Officer or higher.")
        return
    end
    local link, tail = rest:match("^(.-|h|r)%s+(.*)$")
    if not link then
        ns.Print("Usage: /dhs list <shift-click an item link> <quantity> <gold price, e.g. 5.5>")
        return
    end
    local qtyStr, goldStr = tail:match("^(%S+)%s+(%S+)$")
    local quantity, goldAmount = tonumber(qtyStr), tonumber(goldStr)
    if not quantity or not goldAmount then
        ns.Print("Usage: /dhs list <shift-click an item link> <quantity> <gold price, e.g. 5.5>")
        return
    end
    local itemId = tonumber(link:match("item:(%d+)"))
    local goldCopper = math.floor(goldAmount * 10000 + 0.5)
    local listingId = ns.AddOrEditListing(nil, itemId, link, quantity, goldCopper)
    ns.Print("Listed: " .. link .. " x" .. quantity .. " for " .. ns.FormatMoney(goldCopper) .. " (ID " .. listingId .. ")")
    ns.Store_Refresh()
end

SLASH_DHSTORE1 = "/dhs"
SlashCmdList["DHSTORE"] = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        ns.Store_Toggle()
    elseif cmd == "list" then
        HandleListCommand(rest)
    elseif cmd == "sold" then
        if not ns.CanManageListingsLocal() then
            ns.Print("Refused - you must be a Store Officer or higher.")
        elseif rest == "" or not ns.catalog[rest] then
            ns.Print("Usage: /dhs sold <listingId> - see the Store window for IDs.")
        else
            ns.MarkListingSold(rest)
            ns.Print("Marked sold: " .. rest)
            ns.Store_Refresh()
        end
    elseif cmd == "unpend" then
        if not ns.CanManageListingsLocal() then
            ns.Print("Refused - you must be a Store Officer or higher.")
        elseif rest == "" or not ns.catalog[rest] then
            ns.Print("Usage: /dhs unpend <listingId> - see the Store window for IDs.")
        else
            ns.UnpendListing(rest)
            ns.Print("Unpended: " .. rest)
            ns.Store_Refresh()
        end
    elseif cmd == "officers" then
        if not ns.CanManageStoreOfficersLocal() then
            ns.Print("Refused - you must be the guild leader, the donation recipient, or the author account.")
        elseif rest == "" then
            ns.Print("Current Store Officers: " .. table.concat(ns.db.officers, ", "))
        else
            local list = {}
            for name in rest:gmatch("[^,]+") do
                table.insert(list, (name:match("^%s*(.-)%s*$")))
            end
            ns.SetStoreOfficers(list)
            ns.Print("Store Officers set to: " .. table.concat(list, ", "))
        end
    elseif cmd == "primary" then
        if not ns.CanManageStoreOfficersLocal() then
            ns.Print("Refused - you must be the guild leader, the donation recipient, or the author account.")
        elseif rest == "" then
            ns.Print("Primary Store Officer: " .. (ns.db.primaryOfficer or "|cffff3333not set|r"))
        else
            ns.SetPrimaryOfficer(rest)
            ns.Print("Primary Store Officer set to: " .. rest)
        end
    elseif cmd == "on" then
        DHTools.SetModuleEnabled("store", true)
    elseif cmd == "off" then
        DHTools.SetModuleEnabled("store", false)
    elseif cmd == "help" then
        ShowHelp()
    else
        ns.Print("Unknown command: '" .. cmd .. "'")
        ShowHelp()
    end
end

--------------------------------------------------------------------------
-- Register with DH-Tools
--------------------------------------------------------------------------
DHTools.RegisterModule("store", {
    name = "Store",
    desc = "Guild buyout store - browse items a Store Officer has listed and buy with gold or Bavin Credits.",
    default = false,
    requires = "bavin",
    OnEnable = ns.InitDB,
})
