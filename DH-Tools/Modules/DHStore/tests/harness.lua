-- DH-Store window-logic test harness (2026-09-29).
-- Loads the ACTUAL DHStore\Core.lua against a permissive mock WoW API and
-- drives the category browser + price formatting. Run from anywhere:
--   lua src\DH-Tools\Modules\DHStore\tests\harness.lua
-- (path resolved relative to this file, so the cwd doesn't matter).
-- Covers LOGIC only (category tree, class/subclass filtering, credit and
-- price text); real rendering is still verified in-game.

local PASS, FAIL = 0, 0
local function check(name, cond, detail)
    if cond then PASS = PASS + 1
    else FAIL = FAIL + 1; print("  FAIL: " .. name .. (detail and (" -- " .. tostring(detail)) or "")) end
end

local here = (arg and arg[0] or "harness.lua"):gsub("[^/\\]*$", "")
local CORE = here .. "..\\Core.lua"

--------------------------------------------------------------------------
-- Permissive frame stub: unknown methods are no-ops, text/scripts recorded.
--------------------------------------------------------------------------
local allStubs = {}
local newStub
local METHODS = {
    SetText = function(self, t) self._text = t end,
    GetText = function(self) return self._text or "" end,
    SetScript = function(self, n, fn) self._scripts[n] = fn end,
    HookScript = function(self, n, fn) self._scripts[n] = self._scripts[n] or fn end,
    GetScript = function(self, n) return self._scripts[n] end,
    CreateFontString = function() return newStub() end,
    CreateTexture = function() return newStub() end,
    GetFontString = function() return newStub() end,
    GetParent = function(self) return self._parent or newStub() end,
    GetStringWidth = function() return 40 end,
    GetWidth = function() return 100 end,
    GetHeight = function() return 20 end,
    IsShown = function(self) return self._shown end,
    Show = function(self) self._shown = true end,
    Hide = function(self) self._shown = false end,
    SetShown = function(self, s) self._shown = s and true or false end,
    SetPoint = function(self, ...) self._points = self._points or {}; self._points[#self._points + 1] = { ... } end,
    ClearAllPoints = function(self) self._points = {} end,
}
function newStub(parent)
    local o = { _scripts = {}, _shown = true, _parent = parent }
    setmetatable(o, { __index = function(t, k)
        if k == "TitleText" or k == "Inset" or k == "Bg" then
            local child = newStub(t); rawset(t, k, child); return child
        end
        if METHODS[k] then return METHODS[k] end
        if type(k) == "string" and k:match("^[A-Z]") then return function() end end
        return nil
    end })
    allStubs[#allStubs + 1] = o
    return o
end

_G.CreateFrame = function(_, _, parent) local s = newStub(parent); s._shown = true; return s end
_G.UIParent = newStub()
_G.UISpecialFrames = {}
_G.tinsert = table.insert
_G.SlashCmdList = {}
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) print("  [chat] " .. tostring(m)) end }
_G.time = function() return 1700000000 end
_G.date = os.date
_G.UnitName = function() return "Tester" end
_G.GetMoney = function() return 123456 end
_G.GameTooltip = newStub()
_G.ITEM_QUALITY_COLORS = {}
_G.UIDropDownMenu_SetWidth = function() end
_G.UIDropDownMenu_Initialize = function() end
_G.UIDropDownMenu_SetText = function() end
_G.UIDropDownMenu_CreateInfo = function() return {} end
_G.UIDropDownMenu_AddButton = function() end
_G.CloseDropDownMenus = function() end

-- Classic-Era-like item class data.
local CLASS = { [0] = "Consumable", [1] = "Container", [2] = "Weapon", [4] = "Armor", [5] = "Reagent",
    [6] = "Projectile", [7] = "Trade Goods", [9] = "Recipe", [11] = "Quiver", [15] = "Miscellaneous" }
local SUBS = {
    [2] = { [0] = "One-Handed Axes", "Two-Handed Axes", "Bows", "Guns", "One-Handed Maces", "Two-Handed Maces",
        "Polearms", "One-Handed Swords", "Two-Handed Swords", "Obsolete", "Staves", "One-Handed Exotics",
        "Two-Handed Exotics", "Fist Weapons", "Miscellaneous", "Daggers", "Thrown", "Spears", "Crossbows", "Wands", "Fishing Poles" },
    [4] = { [0] = "Miscellaneous", "Cloth", "Leather", "Mail", "Plate", "Cosmetic", "Shields" },
    [1] = { [0] = "Bag", "Soul Bag", "Herb Bag", "Enchanting Bag", "Engineering Bag" },
    [0] = { [0] = "Consumable" },
    [7] = { [0] = "Trade Goods", [8] = "Meat" },
    [5] = { [0] = "Reagent" },
    [6] = { [2] = "Arrow", [3] = "Bullet" },
    [11] = { [2] = "Quiver", [3] = "Ammo Pouch" },
    [9] = { [0] = "Book", "Leatherworking", "Tailoring" },
    [15] = { [0] = "Junk", "Reagent", "Companion Pets", "Holiday", "Other" },
}
_G.GetItemClassInfo = function(id) return CLASS[id] end
_G.GetItemSubClassInfo = function(c, s) return SUBS[c] and SUBS[c][s] or nil end

-- id -> { name, quality, classID, subClassID }
local ITEMS = {
    [101] = { "Iron Sword", 2, 2, 7 }, [102] = { "Ancient Blade", 2, 2, 9 }, [103] = { "Cloth Robe", 2, 4, 1 },
    [104] = { "Fancy Hat", 2, 4, 5 }, [105] = { "Engi Bag", 2, 1, 4 }, [106] = { "Linen Bag", 1, 1, 0 },
    [107] = { "Roasted Boar", 1, 0, 0 }, [108] = { "Tough Boar Meat", 1, 7, 8 }, [109] = { "Copper Ore", 1, 7, 0 },
}
local function idOf(ref) return tonumber(tostring(ref):match("item:(%d+)") or ref) end
_G.GetItemInfo = function(ref)
    local it = ITEMS[idOf(ref)]
    if not it then return nil end
    return it[1], "link", it[2], 1, 1, "typeName", "subTypeName", 1, "", "Interface\\Icons\\X"
end
_G.GetItemInfoInstant = function(ref)
    local it = ITEMS[idOf(ref)]
    if not it then return nil end
    return idOf(ref), "t", "s", "", "icon", it[3], it[4]
end

-- DHTools mock
local lastData
_G.DHTools = {
    Bavin = { GetItemGoldValue = function() return nil end, GetLocalAccountRecord = function() return { credits = 12.5 } end },
    Widgets = { CreateScrollList = function(_, opts)
        _G.__listOpts = opts
        local list = { frame = newStub() }
        function list:SetData(d) lastData = d end
        function list:Refresh() end
        return list
    end },
    InitStandaloneWindow = function() end,
    IsModuleEnabled = function() return true end,
    RegisterModule = function() end,
    SetModuleEnabled = function() end,
}

local ok, err = pcall(dofile, CORE)
check("Core.lua loads", ok, err)
if not ok then print(err); os.exit(1) end
local ns = DHTools.Store

--------------------------------------------------------------------------
print("== credit / price text ==")
check("50000 units -> 5.00 credits", ns.FormatCredits(50000) == "5.00 credits", ns.FormatCredits(50000))
check("12500 units -> 1.25 credits", ns.FormatCredits(12500) == "1.25 credits")
check("0 / nil -> 0.00 credits", ns.FormatCredits(0) == "0.00 credits" and ns.FormatCredits(nil) == "0.00 credits")
check("balance formats to 2 places", ns.FormatCreditBalance(12.5) == "12.50" and ns.FormatCreditBalance(nil) == "0.00")
check("credit text is a plain decimal, not g/s/c",
    not ns.FormatCredits(123456):find("%dg") and not ns.FormatCredits(123456):find("%ds"))
check("no combining-mark bytes in price text",
    not ns.FormatMoney(123456):find("\204") and not ns.FormatCredits(123456):find("\204"))

--------------------------------------------------------------------------
print("== category tree ==")
local cats = ns.BuildCategoryList()
local names = {}
for _, c in ipairs(cats) do names[#names + 1] = c.name end
check("ten top-level categories in AH order",
    table.concat(names, ",") == "Weapon,Armor,Container,Consumable,Trade Goods,Projectile,Quiver,Recipe,Reagent,Miscellaneous",
    table.concat(names, ","))
local function subNames(c) local t = {}; for _, s in ipairs(c.subs) do t[#t + 1] = s.name end; return table.concat(t, "|") end
local byName = {}
for _, c in ipairs(cats) do byName[c.name] = c end
local wsubs = subNames(byName["Weapon"])
check("Weapon: no Obsolete / Exotic / Miscellaneous",
    not wsubs:find("Obsolete") and not wsubs:find("Exotic") and not wsubs:find("Miscellaneous"), wsubs)
check("Weapon keeps real weapon types", wsubs:find("One%-Handed Swords") and wsubs:find("Daggers") and wsubs:find("Fishing Poles"))
check("Armor: no Cosmetic, keeps Cloth/Plate/Shields/Miscellaneous",
    not subNames(byName["Armor"]):find("Cosmetic") and subNames(byName["Armor"]):find("Plate")
    and subNames(byName["Armor"]):find("Shields") and subNames(byName["Armor"]):find("Miscellaneous"))
check("Container: no Engineering Bag, keeps Bag/Soul/Herb/Enchanting",
    not subNames(byName["Container"]):find("Engineering") and subNames(byName["Container"]):find("Soul Bag"))
check("Consumable has no sub-categories", #byName["Consumable"].subs == 0)
check("Trade Goods has no sub-categories", #byName["Trade Goods"].subs == 0)
check("Reagent (single sub) shows none", #byName["Reagent"].subs == 0)
check("Projectile keeps Arrow/Bullet", #byName["Projectile"].subs == 2)

--------------------------------------------------------------------------
print("== filtering by class / subclass ==")
DHStoreDB = nil
ns.InitDB()
for id = 101, 109 do
    ns.catalog["L" .. id] = { listingId = "L" .. id, itemId = id, itemLink = "|Hitem:" .. id .. "::|h[x]|h",
        quantity = 1, goldPrice = 10000, listedAt = id }
end

-- Build the window so the category buttons exist; drive them via OnClick.
ns.CanManageListingsLocal = function() return false end
ns.Store_Toggle()
ns.Store_Refresh() -- the stub's Show() doesn't fire OnShow, so refresh explicitly
local function button(text)
    for _, s in ipairs(allStubs) do
        if s._scripts.OnClick and s.text and s.text._text == text then return s end
    end
end
local function shownIds()
    local ids = {}
    for _, l in ipairs(lastData or {}) do ids[#ids + 1] = l.itemId end
    table.sort(ids)
    return table.concat(ids, ",")
end
check("window built and All Categories lists everything", shownIds() == "101,102,103,104,105,106,107,108,109", shownIds())

local b = button("Consumable"); check("Consumable button exists", b ~= nil)
if b then b._scripts.OnClick(); check("Consumable shows cooked food only", shownIds() == "107", shownIds()) end
b = button("Trade Goods")
if b then b._scripts.OnClick(); check("Trade Goods shows meat AND ore (no subcats needed)", shownIds() == "108,109", shownIds()) end
b = button("Weapon")
if b then b._scripts.OnClick(); check("Weapon shows swords incl. obsolete when no subcat picked", shownIds() == "101,102", shownIds()) end
b = button("One-Handed Swords")
if b then b._scripts.OnClick(); check("One-Handed Swords subcat filters by subclass id", shownIds() == "101", shownIds()) end
b = button("Container")
if b then b._scripts.OnClick(); check("Container shows both bags", shownIds() == "105,106", shownIds()) end
b = button("Bag")
if b then b._scripts.OnClick(); check("Bag subcat shows only the plain bag", shownIds() == "106", shownIds()) end
b = button("All Categories")
if b then b._scripts.OnClick(); check("All Categories restores everything", #(lastData or {}) == 9, #(lastData or {})) end

--------------------------------------------------------------------------
print("== category list scroll bar appears only when needed ==")
local sf
for _, s in ipairs(allStubs) do if s.scrollBarHideable then sf = s end end
check("category scroll frame is scrollBarHideable", sf ~= nil)
if sf then
    local bar = newStub(); _G["DHStoreCategoryScrollScrollBar"] = bar
    local hook = sf._scripts.OnScrollRangeChanged
    check("range-changed hook installed", type(hook) == "function")
    if hook then
        hook(sf, 0, 0)
        check("fits: bar hidden", bar._shown == false)
        local last = sf._points[#sf._points]
        check("fits: list reclaims the bar's 22px (right inset 0)", last[1] == "BOTTOMRIGHT" and last[2] == 0, last and last[2])
        hook(sf, 0, 120)
        last = sf._points[#sf._points]
        check("overflows: bar shown and 22px inset restored", bar._shown == true and last[2] == -22, last and last[2])
        local n = #sf._points
        hook(sf, 0, 140)
        check("still overflowing: no re-anchor (no feedback loop)", #sf._points == n)
    end
end

--------------------------------------------------------------------------
print("== listing row price cells ==")
local opts = __listOpts
check("scroll list opts captured", opts and opts.createRow and opts.updateRow)
if opts then
    local listing = ns.catalog["L101"]
    listing.goldPrice = 100000 -- 10g
    local row = newStub()
    opts.createRow(row)

    ns.GetLocalDiscountPercent = function() return 0 end
    opts.updateRow(row, listing, 1)
    check("no discount: plain gold price, no 'was' line", row.goldText._text == "10g 0s 0c" and row.goldWas._shown == false,
        tostring(row.goldText._text))
    check("no discount: credits shown as 10.00 credits (1:1 ratio)", row.creditText._text == "10.00 credits", tostring(row.creditText._text))
    check("no discount: strike hidden", row.goldStrike._shown == false and row.creditStrike._shown == false)

    ns.GetLocalDiscountPercent = function() return 20 end
    opts.updateRow(row, listing, 1)
    check("20% discount: gold final 8g, was 10g", row.goldText._text == "8g 0s 0c" and row.goldWas._text == "10g 0s 0c",
        tostring(row.goldText._text) .. " / " .. tostring(row.goldWas._text))
    check("20% discount: credits final 8.00, was 10.00",
        row.creditText._text == "8.00 credits" and row.creditWas._text == "10.00 credits",
        tostring(row.creditText._text) .. " / " .. tostring(row.creditWas._text))
    check("20% discount: 'was' lines and strike lines shown",
        row.goldWas._shown and row.creditWas._shown and row.goldStrike._shown and row.creditStrike._shown)
    check("row text carries no combining marks",
        not (row.goldWas._text .. row.goldText._text .. row.creditWas._text .. row.creditText._text):find("\204"))
end

print(string.format("\nDH-Store harness: %d passed, %d failed", PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
