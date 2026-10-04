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
    -- 2026-09-28 (Chris, reposted officer-role list): Store Officers
    -- are their OWN separate list again, decoupled from DH-Bavin's
    -- Distribution Officers list - reverses the same-day merge this
    -- comment used to describe. See IsStoreOfficerName/SetStoreOfficers
    -- below.
    if type(ns.db.officers) ~= "table" then
        ns.db.officers = {}
    end
    if type(ns.db.catalog) ~= "table" then
        ns.db.catalog = {}
    end
    ns.db.officersUpdatedAt = ns.db.officersUpdatedAt or 0
    ns.db.catalogUpdatedAt = ns.db.catalogUpdatedAt or 0
    -- creditGoldRatio: UPDATED AGAIN 2026-09-28 (Chris, item 4/5) - was
    -- a single decimal ("credits per gold"), now an {x=,y=} pair
    -- meaning "X Credits = Y Gold", same shape and reasoning as
    -- DHBavin\Credits.lua's creditsPerRep/repPerGold (that file's own
    -- header comment has the full writeup - Chris: 3 independent
    -- ratios, not required to reconcile with each other). Default 1
    -- Credit = 1 Gold carries over unchanged in the new shape. Type-
    -- checked (not just nil-checked) so a stale pre-conversion decimal
    -- left in an existing SavedVariables file is replaced with the
    -- table default rather than crashing ComputePrices below.
    -- NOT YET SYNCED to the rest of the guild (this module has no wire
    -- message for it - Sync.lua never broadcasts ns.db.creditGoldRatio
    -- today, decimal or table); an officer's change here is local to
    -- their own client until that's built. Pre-existing gap, not
    -- introduced by this change - noted for whoever wires up the
    -- Currency/Conversion UI's Credit/Gold row.
    if type(ns.db.creditGoldRatio) ~= "table" or type(ns.db.creditGoldRatio.x) ~= "number" then
        ns.db.creditGoldRatio = { x = 1, y = 1 }
    end
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

-- Tier 4 (2026-09-28, Chris, reposted officer-role list): back to its
-- own local Store Officer roster (ns.db.officers) - the same-day merge
-- into DH-Bavin's shared list this comment used to describe is
-- reversed. Store Officer and Distribution Officer are two separate
-- rosters; DH-Bavin's IsOfficerName now means "Distribution Officer"
-- only (see that file's own comment).
function ns.IsStoreOfficerName(name)
    if not name or type(ns.db.officers) ~= "table" then return false end
    local norm = NormalizeName(name)
    for _, officerName in ipairs(ns.db.officers) do
        if NormalizeName(officerName) == norm then
            return true
        end
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

-- 2026-09-28 (Chris, reposted officer-role list): Store Officer(s) are
-- "configurable via type down box by 1, 2 or 3" - author, guild leader,
-- or donation recipient. Governs BOTH adding/removing Store Officers
-- (SetStoreOfficers below) and naming the Primary Store Officer
-- (SetPrimaryOfficer, Sync.lua) - Store Officers themselves cannot do
-- either (question #6.4's tier-4 exclusion carries over unchanged).
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

-- Replaces the Store Officer roster wholesale (same shape as DH-Bavin's
-- ns.SetEditors) - gated by CanManageStoreOfficersLocal (tiers 1-3
-- only, question #6.4's tier-4 exclusion). Broadcasts to the guild via
-- Sync.lua so every client's copy stays in sync (last-writer-wins on
-- ns.db.officersUpdatedAt, same pattern as primaryOfficer).
function ns.SetStoreOfficers(list)
    if not ns.CanManageStoreOfficersLocal() then return false end
    ns.db.officers = list
    ns.db.officersUpdatedAt = time()
    ns.Sync_BroadcastOfficers()
    return true
end

-- Sets the Credit/Gold ratio ("X Credits = Y Gold" - see InitDB's
-- comment). Gated the same as listing management (CanManageListingsLocal
-- - any shared-list officer, guild leader, donation recipient, or the
-- author account), matching DHBavin\Credits.lua's SetCreditsPerRep/
-- SetRepPerGold gate (CanManageCreditsConfigLocal) for the other two
-- ratios - a config value any tier-1-4 person can tune, not restricted
-- to whoever manages the officer list itself. LOCAL ONLY for now - see
-- InitDB's "NOT YET SYNCED" note; this does not broadcast to the guild.
function ns.SetCreditGoldRatio(x, y)
    if not ns.CanManageListingsLocal() then return false end
    local nx, ny = tonumber(x), tonumber(y)
    if not nx or nx <= 0 or not ny or ny <= 0 then return false end
    ns.db.creditGoldRatio = { x = nx, y = ny }
    return true
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
-- viewer. creditBase/creditFinal stay nil only if ns.db.creditGoldRatio
-- is somehow missing entirely - InitDB always gives it a default, so in
-- practice this is always populated (see InitDB's comment).
function ns.ComputePrices(listing)
    local goldBase = listing.goldPrice or 0
    local pct = ns.GetLocalDiscountPercent()
    local goldFinal = ns.db.discountAppliesToGold
        and math.floor(goldBase * (100 - pct) / 100) or goldBase

    local creditBase, creditFinal
    local ratio = ns.db.creditGoldRatio
    if ratio and ratio.y and ratio.y ~= 0 then
        -- ratio means "X Credits = Y Gold", so credits = gold * (X/Y).
        creditBase = math.floor(goldBase * (ratio.x / ratio.y))
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

-- Credits are shown as a plain "xx.xx credits" figure (2026-09-29, Loopi),
-- never as the gold equivalent. ComputePrices keeps credit prices in the
-- same 10000-per-unit integer scale as gold copper (goldCopper x ratio),
-- so 1 credit = 10000 of those units.
function ns.FormatCredits(units)
    return string.format("%.2f credits", math.max(0, units or 0) / 10000)
end

-- Bare "xx.xx" for a real credits BALANCE (rec.credits is already in
-- credits, not in the 10000-scale).
function ns.FormatCreditBalance(credits)
    return string.format("%.2f", tonumber(credits) or 0)
end

-- (classID, subClassID) for a listing, from GetItemInfoInstant so it
-- works for items the client has never cached. nil,nil if unresolvable.
function ns.GetListingClass(listing)
    if not GetItemInfoInstant or not listing then return nil, nil end
    local ref = listing.itemLink or listing.itemId
    if not ref then return nil, nil end
    local ok, _, _, _, _, _, classID, subClassID = pcall(GetItemInfoInstant, ref)
    if not ok then return nil, nil end
    return classID, subClassID
end

--------------------------------------------------------------------------
-- Category tree (2026-09-29, Loopi): a fixed, Auction-House-ordered list
-- of the ten top-level categories the guild wants - Weapon, Armor,
-- Container, Consumable, Trade Goods, Projectile, Quiver, Recipe, Reagent,
-- Miscellaneous - instead of dumping whatever GetAuctionItemClasses
-- happens to contain (which also carried obsolete classes). Names and
-- sub-category names still come from the client so they match the real
-- AH's wording. Selection uses numeric IDs (see GetFilteredSortedListings).
--   noSubs      - top-level only, no sub-category rows
--   dropSubs    - lowercase substrings; a sub-category whose client name
--                 contains one is left out. Matched by NAME (not by
--                 subClassID) so a wrong ID can never hide a real category.
-- A class left with fewer than two sub-categories shows none (a lone
-- "Reagent" row under "Reagent" is just noise).
--------------------------------------------------------------------------
ns.CATEGORY_TREE = {
    { classID = 2,  fallback = "Weapon",        dropSubs = { "obsolete", "exotic", "miscellaneous" } },
    { classID = 4,  fallback = "Armor",         dropSubs = { "cosmetic" } },
    { classID = 1,  fallback = "Container",     dropSubs = { "engineering" } },
    { classID = 0,  fallback = "Consumable",    noSubs = true },
    { classID = 7,  fallback = "Trade Goods",   noSubs = true },
    { classID = 6,  fallback = "Projectile" },
    { classID = 11, fallback = "Quiver" },
    { classID = 9,  fallback = "Recipe" },
    { classID = 5,  fallback = "Reagent" },
    { classID = 15, fallback = "Miscellaneous" },
}

-- Returns { {classID=, name=, subs={ {id=, name=}, ... }}, ... } in tree
-- order. Never throws; missing client APIs just yield fallback names and
-- no sub-categories.
function ns.BuildCategoryList()
    local out = {}
    for _, def in ipairs(ns.CATEGORY_TREE) do
        local name = GetItemClassInfo and GetItemClassInfo(def.classID)
        if not name or name == "" then name = def.fallback end
        local subs = {}
        if not def.noSubs and GetItemSubClassInfo then
            for subId = 0, 20 do
                local sname = GetItemSubClassInfo(def.classID, subId)
                if sname and sname ~= "" then
                    local drop = false
                    local lower = sname:lower()
                    for _, frag in ipairs(def.dropSubs or {}) do
                        if lower:find(frag, 1, true) then drop = true; break end
                    end
                    if not drop then subs[#subs + 1] = { id = subId, name = sname } end
                end
            end
            if #subs < 2 then subs = {} end
        end
        out[#out + 1] = { classID = def.classID, name = name, subs = subs }
    end
    return out
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
        prices.creditFinal and ns.FormatCredits(prices.creditFinal) or "n/a",
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
-- question #8's expanded resolution (2026-09-28, Chris): mimic the real
-- in-game Auction House's left-frame class/subclass browser - NOT
-- DH-Bavin's own donation-ranking categories, a completely different
-- taxonomy. nil className = All Categories.
-- 2026-09-29 (Loopi): selection is by numeric item classID/subClassID
-- (GetItemInfoInstant), not by the localized class/subclass NAME strings
-- the old code compared. The names GetAuctionItemSubClasses returns do not
-- always equal GetItemInfo's itemSubType (Classic reports cooked food as
-- Consumable/"Consumable", raw meat as Trade Goods/"Meat"), which hid
-- those listings from every sub-category while "All" still showed them.
local categoryClassID = nil
local categorySubID = nil
local expandedClassIndex = nil -- which class row is showing its subclasses (accordion - one at a time, v1)

local QUALITY_NAMES = { [0] = "Poor", [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary" }

-- Sorted array snapshot of ns.catalog, filtered by searchText/
-- qualityFilter/categoryClassID/categorySubID. Quality comes from GetItemInfo
-- (client item cache; none of it is on the wire - question #2 keeps the
-- payload to itemId/itemLink/quantity/gold), so an uncached item just shows
-- unfiltered by quality. Class/subclass come from GetItemInfoInstant (see
-- ns.GetListingClass), which needs no cache.
local function GetFilteredSortedListings()
    local list = {}
    local needle = searchText:lower()
    -- Real catalog plus the local-only test listings (never in ns.catalog,
    -- so they can never be encoded onto the wire by Sync.lua).
    local all = {}
    for _, l in pairs(ns.catalog) do all[#all + 1] = l end
    for _, l in pairs(ns.testListings or {}) do all[#all + 1] = l end
    for _, l in ipairs(all) do
        local name, _, itemQuality = l.itemLink and GetItemInfo(l.itemLink)
        name = name or l.itemLink or ("item " .. tostring(l.itemId or "?"))
        local matchesSearch = needle == "" or name:lower():find(needle, 1, true) ~= nil
        local matchesQuality = qualityFilter == nil or itemQuality == qualityFilter
        local matchesClass, matchesSubclass = true, true
        if categoryClassID ~= nil then
            -- GetItemInfoInstant needs no item-cache round trip, so the
            -- class filter works even for items never seen this session.
            local classID, subClassID = ns.GetListingClass(l)
            matchesClass = classID == categoryClassID
            matchesSubclass = categorySubID == nil or subClassID == categorySubID
        end
        if matchesSearch and matchesQuality and matchesClass and matchesSubclass then
            table.insert(list, l)
        end
    end
    table.sort(list, function(a, b) return (a.listedAt or 0) > (b.listedAt or 0) end)
    return list
end

-- Listing-row column geometry, shared with the column headers in
-- CreateStoreFrame - keep in sync. x positions are measured from the
-- row's left edge: icon 4..28, name from COL_X_NAME, then gold, credits.
local COL_NAME_W, COL_GOLD_W, COL_CREDIT_W = 160, 110, 100
local COL_X_NAME = 34
local COL_X_GOLD = COL_X_NAME + COL_NAME_W + 4
local COL_X_CREDIT = COL_X_GOLD + COL_GOLD_W + 4

local function CreateListingRow(row)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(24, 24)
    row.icon:SetPoint("LEFT", 4, 0)

    row.nameText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.nameText:SetWidth(COL_NAME_W)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    -- Price cells. Each column has a "final" line (goldText/creditText)
    -- and, only when the viewer's tier discount changes the number, a
    -- grey "was" line above it with a drawn strike line (see
    -- PlaceStruckCell). All are placed by absolute x from the row's left
    -- edge (same x the column headers use) so a cell can shift up/down
    -- without dragging the next column with it.
    local function PriceCell(width)
        local final = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        final:SetWidth(width)
        final:SetJustifyH("LEFT")
        final:SetWordWrap(false)
        local was = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        was:SetJustifyH("LEFT")
        was:Hide()
        local strike = row:CreateTexture(nil, "OVERLAY")
        strike:SetColorTexture(0.65, 0.65, 0.65, 0.95)
        strike:SetHeight(1)
        strike:Hide()
        return final, was, strike
    end
    row.goldText, row.goldWas, row.goldStrike = PriceCell(COL_GOLD_W)
    row.creditText, row.creditWas, row.creditStrike = PriceCell(COL_CREDIT_W)

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

    -- Item tooltip on hover (row.listing is set each UpdateListingRow).
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        local l = self.listing
        if not l or not l.itemLink then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(l.itemLink)
        if l.isTest then
            GameTooltip:AddLine("TEST LISTING - local only, not shared", 1, 0.5, 0)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- question #11: base price struck through above the tier-discounted
-- price - only when a discount actually changes the number; otherwise
-- just the plain price (no point striking a price through itself).
--
-- 2026-09-29 (Loopi, in-game): the old strikethrough appended U+0336
-- (combining long stroke) after every character, and WoW's font has no
-- glyph for it - every character was followed by a small box. The strike
-- is now a 1px texture laid across a separate grey "was" line instead;
-- no special characters at all.
local ROW_H_HALF = 7 -- px the two lines sit above/below the row centre
local function PlaceStruckCell(final, was, strike, x, baseText, finalText, struck)
    final:ClearAllPoints()
    if struck then
        final:SetPoint("LEFT", final:GetParent(), "LEFT", x, -ROW_H_HALF)
        was:ClearAllPoints()
        was:SetPoint("LEFT", was:GetParent(), "LEFT", x, ROW_H_HALF)
        was:SetText(baseText)
        was:Show()
        strike:ClearAllPoints()
        strike:SetPoint("LEFT", was, "LEFT", 0, 0)
        strike:SetWidth(math.max(1, was:GetStringWidth()))
        strike:Show()
    else
        final:SetPoint("LEFT", final:GetParent(), "LEFT", x, 0)
        was:Hide()
        strike:Hide()
    end
    final:SetText(finalText)
end

local function UpdateListingRow(row, listing, dataIndex)
    row.listing = listing
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
    PlaceStruckCell(row.goldText, row.goldWas, row.goldStrike, COL_X_GOLD,
        ns.FormatMoney(prices.goldBase), ns.FormatMoney(prices.goldFinal),
        ns.db.discountAppliesToGold and prices.discountPercent > 0 and prices.goldBase ~= prices.goldFinal)
    if prices.creditFinal then
        PlaceStruckCell(row.creditText, row.creditWas, row.creditStrike, COL_X_CREDIT,
            ns.FormatCredits(prices.creditBase), ns.FormatCredits(prices.creditFinal),
            ns.db.discountAppliesToCredits and prices.discountPercent > 0 and prices.creditBase ~= prices.creditFinal)
    else
        PlaceStruckCell(row.creditText, row.creditWas, row.creditStrike, COL_X_CREDIT, "", "|cff888888-|r", false)
    end

    local isOfficer = ns.CanManageListingsLocal()
    row.soldBtn:SetShown(isOfficer)
    row.unpendBtn:SetShown(isOfficer and listing.pendingBy ~= nil)
    row.soldBtn:SetPoint("RIGHT", row.buyBtn, "LEFT", -4, 0)
    if isOfficer and listing.pendingBy then
        row.unpendBtn:SetPoint("RIGHT", row.soldBtn, "LEFT", -4, 0)
    end

    -- Test listings (listing.isTest) are handled purely locally: no wire
    -- message, no mail. "Sold" doubles as remove for real listings too.
    row.soldBtn:SetScript("OnClick", function()
        if listing.isTest then
            ns.testListings[listing.listingId] = nil
        else
            ns.MarkListingSold(listing.listingId)
        end
        if frame and frame:IsShown() then ns.Store_Refresh() end
    end)
    row.unpendBtn:SetScript("OnClick", function()
        if listing.isTest then
            listing.pendingBy = nil
        else
            ns.UnpendListing(listing.listingId)
        end
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
        if listing.isTest then
            listing.pendingBy = UnitName("player")
            ns.Print("TEST listing: purchase simulated locally - nothing was sent.")
        elseif ns.MarkListingPending(listing.listingId) then
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
    -- badge is a Button with a .text FontString (a bare FontString cannot
    -- take SetScript, which is what left the window half-built/blank).
    badge.text:SetText(label .. ": " .. pct .. "% off")
    badge:SetWidth(math.max(60, badge.text:GetStringWidth() + 6))
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

--------------------------------------------------------------------------
-- Category panel (question #3, expanded 2026-09-28, Chris): a left-side
-- class/subclass browser mimicking the real in-game Auction House's
-- left AH frame - NOT DH-Bavin's own donation/points categories, a
-- completely different taxonomy (see GetFilteredSortedListings' own
-- comment above). Sourced live from GetAuctionItemClasses()/
-- GetAuctionItemSubClasses(classIndex) - the same Blizzard API the
-- real AH's browse tree uses - rather than a hardcoded list, so it
-- always matches whatever this client's item class table contains.
-- Accordion style: only one class's subclasses are visible at a time
-- (v1 - a ~400px column doesn't have room for everything expanded at
-- once). Wrapped in UIPanelScrollFrameTemplate since a fully expanded
-- class's subclass list plus every other collapsed class row can
-- exceed that space (same "why a scrollframe" reasoning as
-- PriorityEditor.lua's own list).
--------------------------------------------------------------------------

local CATEGORY_ROW_HEIGHT = 18
local CATEGORY_PANEL_WIDTH = 150

local categoryButtons = {} -- flat list of {btn, kind="all"|"class"|"subclass", className, subclassName, classIndex}
local categoryPanelContent

local function RelayoutCategoryPanel()
    local y = -2
    for _, entry in ipairs(categoryButtons) do
        local btn = entry.btn
        if entry.kind == "subclass" and entry.classIndex ~= expandedClassIndex then
            btn:Hide()
        else
            btn:Show()
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", categoryPanelContent, "TOPLEFT", 0, y)
            btn:SetPoint("TOPRIGHT", categoryPanelContent, "TOPRIGHT", 0, y)
            y = y - CATEGORY_ROW_HEIGHT
        end

        local selected
        if entry.kind == "all" then
            selected = categoryClassID == nil
        elseif entry.kind == "class" then
            selected = categoryClassID == entry.classID and categorySubID == nil
        else
            selected = categoryClassID == entry.classID and categorySubID == entry.subID
        end
        btn.text:SetTextColor(selected and 1 or 0.9, selected and 0.82 or 0.9, selected and 0 or 0.9)
    end
    categoryPanelContent:SetHeight(math.max(1, -y))
end

local function SelectCategory(classID, subID)
    categoryClassID = classID
    categorySubID = subID
    RelayoutCategoryPanel()
    ns.Store_Refresh()
end

local function CreateCategoryButton(parent, indent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(CATEGORY_ROW_HEIGHT)
    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.1)
    btn:SetHighlightTexture(highlight)
    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", indent, 0)
    fs:SetPoint("RIGHT", -2, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    btn.text = fs
    return btn
end

local function BuildCategoryPanel(parent)
    local panel = CreateFrame("Frame", "DHStoreCategoryPanel", parent)
    panel:SetWidth(CATEGORY_PANEL_WIDTH)

    local scrollFrame = CreateFrame("ScrollFrame", "DHStoreCategoryScroll", panel, (DHTools and DHTools.SCROLL_TEMPLATE) or "UIPanelScrollFrameTemplate")
    if DHTools and DHTools.SkinScrollBar then DHTools.SkinScrollBar(scrollFrame) end
    scrollFrame:SetPoint("TOPLEFT", 0, 0)
    scrollFrame:SetPoint("BOTTOMRIGHT", -22, 0)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(CATEGORY_PANEL_WIDTH - 22, 1)
    scrollFrame:SetScrollChild(content)
    categoryPanelContent = content

    -- Scroll bar only when the list actually overflows (2026-09-29,
    -- Loopi): scrollBarHideable makes Blizzard's OnScrollRangeChanged
    -- hide the bar and its arrow buttons whenever the vertical range is
    -- zero and show them again when it isn't, so expanding a class with
    -- many sub-categories brings the bar back on the fly. The hook below
    -- gives the 22px the bar occupied back to the list while it's hidden.
    -- Only re-anchors when the state flips, so it can't feed back into
    -- another range-changed event.
    scrollFrame.scrollBarHideable = 1
    local barShown = true
    scrollFrame:HookScript("OnScrollRangeChanged", function(self, _, yrange)
        local need = math.floor(yrange or 0) > 0
        -- Explicit show/hide as well, so it doesn't rely on the client's
        -- scrollBarHideable support alone (the arrow buttons are children
        -- of the bar and follow it).
        local bar = _G["DHStoreCategoryScrollScrollBar"]
        if bar then bar:SetShown(need) end
        if need == barShown then return end
        barShown = need
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", 0, 0)
        self:SetPoint("BOTTOMRIGHT", need and -22 or 0, 0)
        content:SetWidth(CATEGORY_PANEL_WIDTH - (need and 22 or 0))
    end)

    categoryButtons = {}

    local allBtn = CreateCategoryButton(content, 4)
    allBtn.text:SetText("All Categories")
    allBtn:SetScript("OnClick", function()
        expandedClassIndex = nil
        SelectCategory(nil, nil)
    end)
    tinsert(categoryButtons, { btn = allBtn, kind = "all" })

    -- Fixed AH-order tree (ns.BuildCategoryList) - see the CATEGORY_TREE
    -- comment for which top-level classes and sub-categories are shown.
    for classIndex, classEntry in ipairs(ns.BuildCategoryList()) do
        local classID = classEntry.classID
        local classBtn = CreateCategoryButton(content, 4)
        classBtn.text:SetText(classEntry.name)
        classBtn:SetScript("OnClick", function()
            if expandedClassIndex == classIndex then
                expandedClassIndex = nil
                SelectCategory(nil, nil)
            else
                expandedClassIndex = classIndex
                SelectCategory(classID, nil)
            end
        end)
        tinsert(categoryButtons, { btn = classBtn, kind = "class", classID = classID, classIndex = classIndex })

        for _, sub in ipairs(classEntry.subs) do
            local subBtn = CreateCategoryButton(content, 16)
            subBtn.text:SetText(sub.name)
            subBtn:SetScript("OnClick", function()
                SelectCategory(classID, sub.id)
            end)
            tinsert(categoryButtons, { btn = subBtn, kind = "subclass", classID = classID, subID = sub.id, classIndex = classIndex })
        end
    end

    return panel
end

--------------------------------------------------------------------------
-- Window layout (2026-09-29, Chris: "build out the basic structure
-- completely"). Left: AH-style category browser. Right, top to bottom:
-- search + quality filter; the officer-only Add Listing strip (drag an
-- item onto the slot); column headers; the scrolling listing table.
-- Bottom bar: the viewer's gold, Store Credits and tier-discount badge
-- (question #10's "lower-left balance readout"), plus a listing count.
--------------------------------------------------------------------------

local FRAME_W, FRAME_H = 860, 520
local RIGHT_X = 190 -- everything right of the category panel starts here

local function FormatGoldInput(x)
    local s = string.format("%.2f", x)
    if s:find("%.") then
        s = s:gsub("0+$", "")
        s = s:gsub("%.$", "")
    end
    return s
end

local function UpdateBalances()
    if not frame or not frame.goldText then return end
    frame.goldText:SetText("Gold: |cffffffff" .. ns.FormatMoney(GetMoney and GetMoney() or 0) .. "|r")
    local rec = DHTools.Bavin and DHTools.Bavin.GetLocalAccountRecord and DHTools.Bavin.GetLocalAccountRecord()
    if rec and rec.credits ~= nil then
        frame.creditsText:SetText("Store Credits: |cffffffff" .. ns.FormatCreditBalance(rec.credits) .. "|r")
    else
        frame.creditsText:SetText("Store Credits: |cff888888not synced yet|r")
    end
    UpdateDiscountBadge(frame.discountBadge)
end

-- Officer-only "Add Listing" strip. Drag an item from your bags onto the
-- slot (or click the slot while holding an item); the gold price is
-- pre-filled from ItemPoints.lua x quantity when the item is known there
-- and can be overwritten by hand (the manual override question #5 keeps).
local function BuildAddListingStrip(parent)
    local strip = CreateFrame("Frame", nil, parent)
    strip:SetHeight(58)

    local label = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 4, -2)
    label:SetText("Add listing - drag an item from your bags onto the slot:")

    strip.status = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    strip.status:SetPoint("LEFT", label, "RIGHT", 10, 0)

    local slot = CreateFrame("Button", "DHStoreAddSlot", strip)
    slot:SetSize(32, 32)
    slot:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)
    local slotBg = slot:CreateTexture(nil, "BACKGROUND")
    slotBg:SetAllPoints()
    slotBg:SetColorTexture(0.15, 0.15, 0.15, 0.9)
    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetPoint("TOPLEFT", 2, -2)
    slot.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    slot.icon:Hide()
    slot.plus = slot:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    slot.plus:SetPoint("CENTER")
    slot.plus:SetText("+")
    local slotHl = slot:CreateTexture(nil, "HIGHLIGHT")
    slotHl:SetAllPoints()
    slotHl:SetColorTexture(1, 1, 1, 0.15)

    strip.itemName = strip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    strip.itemName:SetPoint("LEFT", slot, "RIGHT", 8, 0)
    strip.itemName:SetWidth(190)
    strip.itemName:SetJustifyH("LEFT")
    strip.itemName:SetWordWrap(false)
    strip.itemName:SetText("|cff888888(no item chosen)|r")

    local qtyLabel = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    qtyLabel:SetPoint("LEFT", strip.itemName, "RIGHT", 8, 0)
    qtyLabel:SetText("Qty")
    strip.qtyEdit = CreateFrame("EditBox", "DHStoreAddQtyEdit", strip, "InputBoxTemplate")
    strip.qtyEdit:SetSize(40, 20)
    strip.qtyEdit:SetPoint("LEFT", qtyLabel, "RIGHT", 8, 0)
    strip.qtyEdit:SetAutoFocus(false)
    strip.qtyEdit:SetNumeric(true)
    strip.qtyEdit:SetMaxLetters(4)
    strip.qtyEdit:SetText("1")
    strip.qtyEdit:SetScript("OnEscapePressed", strip.qtyEdit.ClearFocus)

    local goldLabel = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    goldLabel:SetPoint("LEFT", strip.qtyEdit, "RIGHT", 12, 0)
    goldLabel:SetText("Gold")
    strip.goldEdit = CreateFrame("EditBox", "DHStoreAddGoldEdit", strip, "InputBoxTemplate")
    strip.goldEdit:SetSize(72, 20)
    strip.goldEdit:SetPoint("LEFT", goldLabel, "RIGHT", 8, 0)
    strip.goldEdit:SetAutoFocus(false)
    strip.goldEdit:SetMaxLetters(10)
    strip.goldEdit:SetScript("OnEscapePressed", strip.goldEdit.ClearFocus)

    strip.addBtn = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
    strip.addBtn:SetSize(92, 22)
    strip.addBtn:SetPoint("LEFT", strip.goldEdit, "RIGHT", 10, 0)
    strip.addBtn:SetText("Add Listing")

    local function SetStatus(text, ok)
        strip.status:SetText((ok and "|cff33ff99" or "|cffff3333") .. text .. "|r")
        C_Timer.After(4, function() strip.status:SetText("") end)
    end

    -- Pre-fill the gold box from ItemPoints.lua unless the officer has
    -- typed their own number (goldManual).
    function strip.AutoFillGold()
        if strip.goldManual or not strip.itemLink then return end
        local name = GetItemInfo(strip.itemLink)
        local unit = name and DHTools.Bavin.GetItemGoldValue and DHTools.Bavin.GetItemGoldValue(name)
        local qty = tonumber(strip.qtyEdit:GetText()) or 1
        strip.goldEdit:SetText(unit and FormatGoldInput(unit * qty) or "")
    end
    strip.goldEdit:SetScript("OnTextChanged", function(_, userInput)
        if userInput then strip.goldManual = true end
    end)
    strip.qtyEdit:SetScript("OnTextChanged", function(_, userInput)
        if userInput then strip.AutoFillGold() end
    end)

    function strip.SetItem(itemId, itemLink)
        strip.itemId, strip.itemLink = itemId, itemLink
        local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(itemLink or itemId)
        slot.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
        slot.icon:Show()
        slot.plus:Hide()
        strip.itemName:SetText(itemLink or ("item " .. tostring(itemId)))
        strip.goldManual = false
        strip.AutoFillGold()
    end

    function strip.Reset()
        strip.itemId, strip.itemLink, strip.goldManual = nil, nil, false
        slot.icon:Hide()
        slot.plus:Show()
        strip.itemName:SetText("|cff888888(no item chosen)|r")
        strip.qtyEdit:SetText("1")
        strip.goldEdit:SetText("")
    end

    local function TakeCursorItem()
        local kind, itemId, itemLink = GetCursorInfo()
        if kind ~= "item" then return end
        ClearCursor()
        strip.SetItem(itemId, itemLink)
    end
    slot:SetScript("OnReceiveDrag", TakeCursorItem)
    slot:SetScript("OnClick", TakeCursorItem)
    slot:SetScript("OnEnter", function(self)
        if strip.itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(strip.itemLink)
            GameTooltip:Show()
        end
    end)
    slot:SetScript("OnLeave", function() GameTooltip:Hide() end)

    strip.addBtn:SetScript("OnClick", function()
        if not ns.CanManageListingsLocal() then
            SetStatus("Refused - Store Officers only.", false)
            return
        end
        if not strip.itemLink then
            SetStatus("Drag an item onto the slot first.", false)
            return
        end
        local qty = math.floor(tonumber(strip.qtyEdit:GetText()) or 0)
        if qty < 1 then
            SetStatus("Enter a quantity of 1 or more.", false)
            return
        end
        local gold = tonumber(strip.goldEdit:GetText())
        if not gold or gold <= 0 then
            SetStatus("No price on file - enter a gold price.", false)
            return
        end
        local copper = math.floor(gold * 10000 + 0.5)
        local listingId = ns.AddOrEditListing(nil, strip.itemId, strip.itemLink, qty, copper)
        ns.Print("Listed: " .. strip.itemLink .. " x" .. qty .. " for " .. ns.FormatMoney(copper)
            .. " (ID " .. listingId .. ")")
        strip.Reset()
        SetStatus("Listed!", true)
        ns.Store_Refresh()
    end)

    return strip
end

local function CreateStoreFrame()
    local f = CreateFrame("Frame", "DHStoreFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER")
    if f.TitleText then f.TitleText:SetText("DH-Store") end
    tinsert(UISpecialFrames, "DHStoreFrame")
    DHTools.InitStandaloneWindow(f)
    frame = f

    -- Resizable like every other DH-Tools window (2026-09-29): bottom-right
    -- grip, same SetResizeBounds / SetMinResize+SetMaxResize fallback as
    -- Account.lua and Config.lua. Minimum is the designed size (the fixed-
    -- width row columns need it); everything else is corner-anchored, so
    -- the listing area and its row pool follow the new size on their own.
    f:SetResizable(true)
    if f.SetResizeBounds then
        pcall(f.SetResizeBounds, f, FRAME_W, 400, 1300, 900)
    else
        pcall(f.SetMinResize, f, FRAME_W, 400)
        pcall(f.SetMaxResize, f, 1300, 900)
    end
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing() end)

    -- Left column: AH-style category browser (question #3).
    f.categoryPanel = BuildCategoryPanel(f)
    f.categoryPanel:SetPoint("TOPLEFT", 12, -32)
    f.categoryPanel:SetPoint("BOTTOMLEFT", 12, 50)
    RelayoutCategoryPanel()

    -- Search + quality filter.
    f.searchEdit = CreateFrame("EditBox", "DHStoreSearchEdit", f, "InputBoxTemplate")
    f.searchEdit:SetSize(180, 20)
    f.searchEdit:SetPoint("TOPLEFT", RIGHT_X + 4, -34)
    f.searchEdit:SetAutoFocus(false)
    f.searchEdit:SetScript("OnEscapePressed", f.searchEdit.ClearFocus)
    f.searchEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.searchEdit:SetScript("OnTextChanged", function(self)
        searchText = (self:GetText() or ""):match("^%s*(.-)%s*$")
        ns.Store_Refresh()
    end)
    local searchHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchHint:SetPoint("LEFT", f.searchEdit, "LEFT", 6, 0)
    searchHint:SetText("Search items...")
    f.searchEdit:HookScript("OnEditFocusGained", function() searchHint:Hide() end)
    f.searchEdit:HookScript("OnEditFocusLost", function(self)
        if (self:GetText() or "") == "" then searchHint:Show() end
    end)

    f.qualityDropdown = CreateFrame("Frame", "DHStoreQualityDropdown", f, "UIDropDownMenuTemplate")
    f.qualityDropdown:SetPoint("LEFT", f.searchEdit, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(f.qualityDropdown, 100)
    UIDropDownMenu_Initialize(f.qualityDropdown, function(_, level)
        local function Pick(q)
            qualityFilter = q
            UIDropDownMenu_SetText(f.qualityDropdown, q and QUALITY_NAMES[q] or "All qualities")
            CloseDropDownMenus()
            ns.Store_Refresh()
        end
        local allInfo = UIDropDownMenu_CreateInfo()
        allInfo.text = "All qualities"
        allInfo.func = function() Pick(nil) end
        UIDropDownMenu_AddButton(allInfo, level)
        for q = 0, 5 do
            local info = UIDropDownMenu_CreateInfo()
            info.text = QUALITY_NAMES[q]
            info.func = function() Pick(q) end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetText(f.qualityDropdown, "All qualities")

    -- Officer-only Add Listing strip (shown/hidden by ns.Store_Reflow).
    f.addStrip = BuildAddListingStrip(f)
    f.addStrip:SetPoint("TOPLEFT", f.searchEdit, "BOTTOMLEFT", -4, -6)
    f.addStrip:SetPoint("RIGHT", f, "RIGHT", -16, 0)

    -- Column headers, aligned with CreateListingRow's columns.
    f.header = CreateFrame("Frame", nil, f)
    f.header:SetHeight(16)
    local function HeaderText(text, x)
        local fs = f.header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", x, 0)
        fs:SetText(text)
        return fs
    end
    HeaderText("Item", COL_X_NAME)
    HeaderText("Gold", COL_X_GOLD)
    HeaderText("Store Credits", COL_X_CREDIT)
    local headerLine = f.header:CreateTexture(nil, "ARTWORK")
    headerLine:SetColorTexture(1, 1, 1, 0.15)
    headerLine:SetHeight(1)
    headerLine:SetPoint("BOTTOMLEFT", 0, 0)
    headerLine:SetPoint("BOTTOMRIGHT", 0, 0)

    f.scrollList = DHTools.Widgets.CreateScrollList(f, {
        rowHeight = 30,
        rightInset = 24,
        createRow = CreateListingRow,
        updateRow = UpdateListingRow,
        emptyText = "No listings yet.",
    })
    f.scrollList.frame:SetPoint("TOPLEFT", f.header, "BOTTOMLEFT", 0, -2)
    f.scrollList.frame:SetPoint("BOTTOMRIGHT", -30, 50)

    -- Bottom bar: balances + discount badge (lower-left, question #10),
    -- listing count (lower-right).
    local bar = f:CreateTexture(nil, "ARTWORK")
    bar:SetColorTexture(1, 1, 1, 0.15)
    bar:SetHeight(1)
    bar:SetPoint("BOTTOMLEFT", 12, 40)
    bar:SetPoint("BOTTOMRIGHT", -12, 40)

    f.goldText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.goldText:SetPoint("BOTTOMLEFT", 16, 16)
    f.creditsText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.creditsText:SetPoint("LEFT", f.goldText, "RIGHT", 28, 0)

    -- The badge is a Button (not a bare FontString) because a FontString
    -- can't take OnEnter/OnLeave - the tooltip needs a mouse-enabled frame.
    f.discountBadge = CreateFrame("Button", nil, f)
    f.discountBadge:SetSize(220, 18)
    f.discountBadge:SetPoint("LEFT", f.creditsText, "RIGHT", 28, 0)
    f.discountBadge.text = f.discountBadge:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.discountBadge.text:SetPoint("LEFT")

    f.countText = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.countText:SetPoint("BOTTOMRIGHT", -16, 18)

    f:RegisterEvent("PLAYER_MONEY")
    f:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    f:SetScript("OnEvent", function(self, event)
        if not self:IsShown() then return end
        if event == "PLAYER_MONEY" then
            UpdateBalances()
        elseif event == "GET_ITEM_INFO_RECEIVED" then
            self.scrollList:Refresh()
            if self.addStrip:IsShown() then self.addStrip.AutoFillGold() end
        end
    end)

    f:SetScript("OnShow", function() ns.Store_Refresh() end)
    -- CreateFrame returns a SHOWN frame; start hidden so the first
    -- Store_Toggle opens it instead of hiding it (same first-click bug
    -- fixed in Account.lua 2026-09-29).
    f:Hide()
end

-- Officers see the Add Listing strip; everyone else gets the header/list
-- moved up into its space.
function ns.Store_Reflow()
    if not frame or not frame.addStrip then return end
    local isOfficer = ns.CanManageListingsLocal() and true or false
    frame.addStrip:SetShown(isOfficer)
    frame.header:ClearAllPoints()
    if isOfficer then
        frame.header:SetPoint("TOPLEFT", frame.addStrip, "BOTTOMLEFT", 0, -4)
    else
        frame.header:SetPoint("TOPLEFT", frame.searchEdit, "BOTTOMLEFT", -4, -8)
    end
    frame.header:SetPoint("RIGHT", frame, "RIGHT", -30, 0)
end

-- Re-renders balances/badge and re-filters/re-sorts the catalog into the
-- scroll list. Call after any local mutation or an incoming Sync.lua
-- delta that should be visible immediately.
function ns.Store_Refresh()
    if not frame or not frame:IsShown() or not frame.scrollList then return end
    ns.Store_Reflow()
    UpdateBalances()
    local listings = GetFilteredSortedListings()
    frame.scrollList:SetData(listings)
    frame.countText:SetText(#listings .. (#listings == 1 and " listing" or " listings"))
end

function ns.Store_Toggle()
    if not frame then
        -- Build under pcall: a half-built window used to be left behind
        -- on any construction error (it then opened blank every time).
        -- On failure, hide the wreck, forget it, and say what broke so
        -- the next open retries from scratch.
        local ok, err = pcall(CreateStoreFrame)
        if not ok then
            if frame then frame:Hide() end
            frame = nil
            ns.Print("|cffff3333Couldn't build the Store window:|r " .. tostring(err))
            return
        end
    end
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
    ns.Print("  /dhs list <shift-click item> <qty> [gold] - officer: add/edit a listing (gold auto-sourced from ItemPoints.lua; give a decimal like 5.5 to override)")
    ns.Print("  /dhs testitem | cleartest  - officer: add/remove a local-only sample listing (not shared)")
    ns.Print("  /dhs sold <listingId>      - officer: mark a listing sold")
    ns.Print("  /dhs unpend <listingId>    - officer: revert a pending listing to available")
    ns.Print("  /dhs officers <name1,name2,...> - tier 1-3: set the Store Officer roster")
    ns.Print("  /dhs primary <name>        - tier 1-3: set the Primary Store Officer")
    ns.Print("  /dhs on|off                - enable/disable this module")
end

-- 2026-09-28 (Chris): "no point in building a manual entry system we
-- won't use" - ItemPoints.lua now carries a real per-unit goldValue
-- (question #5's import-pipeline fix, same day), so this pulls the
-- whole-lot price from there automatically. The trailing gold argument
-- is now OPTIONAL, kept only as the manual override question #5's own
-- design text still allows ("or a manual per-listing override") - for
-- an item ItemPoints.lua has no gold price for, or a one-off exception.
local function HandleListCommand(rest)
    if not ns.CanManageListingsLocal() then
        ns.Print("Refused - you must be a Store Officer or higher.")
        return
    end
    local link, tail = rest:match("^(.-|h|r)%s+(.*)$")
    if not link then
        ns.Print("Usage: /dhs list <shift-click an item link> <quantity> [gold price override, e.g. 5.5]")
        return
    end
    local qtyStr, goldStr = tail:match("^(%S+)%s*(%S*)$")
    local quantity = tonumber(qtyStr)
    if not quantity then
        ns.Print("Usage: /dhs list <shift-click an item link> <quantity> [gold price override, e.g. 5.5]")
        return
    end

    local itemName = GetItemInfo(link)
    local goldAmount = tonumber(goldStr) -- manual override, if given
    local sourcedFromItemPoints = false
    if not goldAmount then
        local unitGold = itemName and DHTools.Bavin.GetItemGoldValue(itemName)
        if unitGold then
            goldAmount = unitGold * quantity
            sourcedFromItemPoints = true
        end
    end
    if not goldAmount then
        ns.Print("No ItemPoints.lua gold price found for '" .. (itemName or link)
            .. "' - give one explicitly: /dhs list <link> <quantity> <gold price>")
        return
    end

    local itemId = tonumber(link:match("item:(%d+)"))
    local goldCopper = math.floor(goldAmount * 10000 + 0.5)
    local listingId = ns.AddOrEditListing(nil, itemId, link, quantity, goldCopper)
    ns.Print("Listed: " .. link .. " x" .. quantity .. " for " .. ns.FormatMoney(goldCopper)
        .. (sourcedFromItemPoints and " (from ItemPoints.lua)" or " (manual price)") .. " (ID " .. listingId .. ")")
    ns.Store_Refresh()
end

--------------------------------------------------------------------------
-- TEST ITEM (remove this block, the ns.testListings reads in
-- GetFilteredSortedListings/UpdateListingRow, and the testitem/cleartest
-- slash branches when no longer needed).
-- Local-only sample listing so the empty store's layout can be checked
-- in-game. Lives in ns.testListings, NEVER ns.catalog, so Sync.lua can
-- never encode/broadcast it; not persisted (gone on /reload).
--------------------------------------------------------------------------
ns.testListings = {}

function ns.AddTestListing()
    local id = "TEST-" .. tostring(time())
    ns.testListings[id] = {
        listingId = id,
        itemId = 6948,
        itemLink = "|cffffffff|Hitem:6948::::::::::::::|h[Hearthstone]|h|r",
        quantity = 1,
        goldPrice = 50000, -- 5g, copper
        listedBy = UnitName("player"),
        listedAt = time(),
        isTest = true,
    }
    return id
end

function ns.ClearTestListings()
    ns.testListings = {}
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
    elseif cmd == "testitem" then
        if not ns.CanManageListingsLocal() then
            ns.Print("Refused - you must be a Store Officer or higher.")
        else
            ns.AddTestListing()
            ns.Print("Added a local-only TEST listing (Hearthstone, 5g). /dhs cleartest removes it.")
            ns.Store_Refresh()
        end
    elseif cmd == "cleartest" then
        if not ns.CanManageListingsLocal() then
            ns.Print("Refused - you must be a Store Officer or higher.")
        else
            ns.ClearTestListings()
            ns.Print("Cleared local TEST listings.")
            ns.Store_Refresh()
        end
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
            ns.Print("Refused - you must be the guild leader or the donation recipient.")
        elseif rest == "" then
            local list = ns.db.officers or {}
            if #list == 0 then
                ns.Print("No Store Officers set.")
            else
                ns.Print("Current Store Officers: " .. table.concat(list, ", "))
            end
        else
            local names = {}
            for name in rest:gmatch("[^,]+") do
                name = name:match("^%s*(.-)%s*$")
                if name ~= "" then tinsert(names, name) end
            end
            ns.SetStoreOfficers(names)
            ns.Print("Store Officers set to: " .. (#names > 0 and table.concat(names, ", ") or "|cffff3333none|r"))
        end
    elseif cmd == "primary" then
        if not ns.CanManageStoreOfficersLocal() then
            ns.Print("Refused - you must be the guild leader or the donation recipient.")
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
