-- LOGIC behind the Audit Log tab (CM7, processor view): turns the raw
-- ns.creditsDb.transactionLog entries into display rows, filters and sorts
-- them, builds the hover-tooltip lines and the export text. Deliberately
-- free of any frame so the headless harness can drive all of it; the tab
-- itself (filters, header buttons, paged rows, export box) lives in
-- CreditsConfig.lua. Nothing here runs unless something calls it.
--
-- A raw log entry is one of
--   donation  { id, ts, sender, receiver, account, items = {{itemID,name,count,
--               rep,category,unpriced}}, gold, rep, credits,
--               creditsPerRep = {x,y}, repPerGold = {x,y},
--               tierBefore/prestigeBefore/tierAfter/prestigeAfter, released? }
--   merge     { id, ts, kind = "merge", account (target), source, sourceMain,
--               moved = {names}, rep, credits, officer, tier/prestige before+after }
--   carryover { id = "carry-<lowername>", ts, kind = "carryover", account, sender, what,
--               rep (old history added), credits = 0, officer, tier/prestige before+after }
--   (CM5 will add kind = "spend" rows - see Unknown kinds below.)
--
-- A display row (ns.CreditsLog_Rows) is
--   { id, ts, kind ("donation"|"released"|"merge"|other), kindLabel, who, account,
--     what, rep, credits, tier (text), tierRank, tierUp, by, search, raw }

local DHTools = DHTools
DHTools.Bavin = DHTools.Bavin or {}
local ns = DHTools.Bavin

local TIER_RANK = { Neutral = 1, Friendly = 2, Honored = 3, Revered = 4, Exalted = 5 }

local KIND_LABELS = {
    donation = "Donation",
    released = "Released",
    merge = "Merge",
    carryover = "Carryover",
    spend = "Spend",
}
local KIND_ORDER = { "donation", "released", "merge", "carryover", "spend" }
ns.CreditsLog_KindLabels = KIND_LABELS

local function FormatDate(ts)
    local fn = date or (os and os.date)
    if fn and ts and ts > 0 then return fn("%y-%m-%d %H:%M", ts) end
    return ""
end
ns.CreditsLog_FormatDate = FormatDate

local function Num2(n)
    if ns.CreditsDon_Fmt then return ns.CreditsDon_Fmt(n) end
    return ("%.2f"):format(tonumber(n) or 0)
end

local function TierText(tier, prestige)
    if not tier or tier == "" then return "" end
    prestige = tonumber(prestige) or 0
    if prestige > 0 then return tier .. " P" .. prestige end
    return tier
end

local function TierRank(tier, prestige)
    return (TIER_RANK[tier] or 0) + (tonumber(prestige) or 0) * 10
end

-- The account's CURRENT main toon, if the ledger still has the account.
local function MainOf(accountKey)
    local rec = accountKey and ns.creditsDb and ns.creditsDb.ledger and ns.creditsDb.ledger[accountKey]
    return rec and rec.mainToon or nil
end

local function ItemsSummary(items, gold)
    local parts = {}
    if gold and gold > 0 then parts[#parts + 1] = Num2(gold) .. " gold" end
    for _, it in ipairs(items or {}) do
        local label = it.name or ("item " .. tostring(it.itemID or "?"))
        if (tonumber(it.count) or 1) > 1 then label = label .. " x" .. it.count end
        parts[#parts + 1] = label
    end
    return table.concat(parts, ", ")
end

-- Normalise one raw entry into a display row.
function ns.CreditsLog_Row(e)
    local row = { raw = e, id = e.id, ts = tonumber(e.ts) or 0 }
    local account = e.account
    local main = MainOf(account) or account or ""
    if e.kind == "merge" then
        row.kind = "merge"
        row.who = main
        local moved = (e.moved and #e.moved > 0) and (" [" .. table.concat(e.moved, ", ") .. "]") or ""
        row.what = "Merged in " .. (e.sourceMain or e.source or "?") .. moved
        row.by = e.officer or ""
    elseif e.kind and e.kind ~= "donation" then
        -- Unknown kind (CM5 "spend" rows etc.): show it rather than hide it.
        row.kind = tostring(e.kind)
        row.who = main
        row.what = e.what or ItemsSummary(e.items, e.gold)
        row.by = e.processedBy or e.officer or e.receiver or ""
    else
        row.kind = e.released and "released" or "donation"
        local sender = e.sender or "?"
        row.who = (main ~= "" and main:lower() ~= sender:lower()) and (sender .. " (" .. main .. ")") or sender
        row.what = ItemsSummary(e.items, e.gold)
        row.by = e.receiver or ""
    end
    row.account = account or ""
    row.kindLabel = KIND_LABELS[row.kind] or row.kind
    row.rep = tonumber(e.rep) or 0
    row.credits = tonumber(e.credits) or 0
    row.tier = TierText(e.tierAfter, e.prestigeAfter)
    row.tierRank = TierRank(e.tierAfter, e.prestigeAfter)
    row.tierUp = (e.tierBefore ~= nil and (e.tierAfter ~= e.tierBefore
        or (tonumber(e.prestigeAfter) or 0) ~= (tonumber(e.prestigeBefore) or 0))) and true or false
    row.search = (row.who .. " " .. row.account .. " " .. row.kindLabel .. " " .. row.what .. " " .. row.by
        .. " " .. (e.sender or "")):lower()
    return row
end

-- Every log entry as a display row (unsorted).
function ns.CreditsLog_Rows()
    local out = {}
    local log = ns.creditsDb and ns.creditsDb.transactionLog
    if not log then return out end
    for _, e in ipairs(log) do
        if type(e) == "table" then out[#out + 1] = ns.CreditsLog_Row(e) end
    end
    return out
end

-- f = { kind = "donation"|"released"|"merge"|..., by = "Name", since = <ts>,
--       text = "substring", tierUpOnly = bool }   (every field optional)
function ns.CreditsLog_Filter(rows, f)
    f = f or {}
    local needle = (f.text or ""):lower()
    local byKey = f.by and f.by ~= "" and f.by:lower() or nil
    local out = {}
    for _, r in ipairs(rows) do
        local ok = true
        if f.kind and f.kind ~= "" and r.kind ~= f.kind then ok = false end
        if ok and byKey and (r.by or ""):lower() ~= byKey then ok = false end
        if ok and f.since and r.ts < f.since then ok = false end
        if ok and f.tierUpOnly and not r.tierUp then ok = false end
        if ok and needle ~= "" and not r.search:find(needle, 1, true) then ok = false end
        if ok then out[#out + 1] = r end
    end
    return out
end

local SORT_FIELDS = {
    date = function(r) return r.ts end,
    kind = function(r) return r.kindLabel:lower() end,
    who = function(r) return r.who:lower() end,
    what = function(r) return r.what:lower() end,
    rep = function(r) return r.rep end,
    credits = function(r) return r.credits end,
    tier = function(r) return r.tierRank end,
    by = function(r) return (r.by or ""):lower() end,
}

-- Sorts IN PLACE and returns the list. Ties fall back to newest-first then
-- id, so the order never flickers between refreshes.
function ns.CreditsLog_Sort(rows, key, ascending)
    local get = SORT_FIELDS[key] or SORT_FIELDS.date
    table.sort(rows, function(a, b)
        local av, bv = get(a), get(b)
        if av ~= bv then
            if ascending then return av < bv else return av > bv end
        end
        if a.ts ~= b.ts then return a.ts > b.ts end
        return tostring(a.id or "") < tostring(b.id or "")
    end)
    return rows
end

-- Distinct, sorted "processed by" names present in the rows.
function ns.CreditsLog_Distinct(rows, field)
    local seen, out = {}, {}
    for _, r in ipairs(rows) do
        local v = r[field]
        if v and v ~= "" and not seen[v:lower()] then
            seen[v:lower()] = true
            out[#out + 1] = v
        end
    end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
end

-- The kinds that actually occur in the rows, in a fixed order (cycle list).
function ns.CreditsLog_KindsPresent(rows)
    local seen = {}
    for _, r in ipairs(rows) do seen[r.kind] = true end
    local out = {}
    for _, k in ipairs(KIND_ORDER) do
        if seen[k] then out[#out + 1] = k; seen[k] = nil end
    end
    for k in pairs(seen) do out[#out + 1] = k end -- any unknown kind, after the known ones
    return out
end

-- Hover tooltip: an array of { left, right? } lines; the first is the title.
function ns.CreditsLog_TooltipLines(row)
    local e = row.raw or {}
    local L = {}
    local function add(a, b) L[#L + 1] = { a, b } end
    add(row.kindLabel .. "  " .. FormatDate(row.ts))
    add("Account", row.who)
    if row.kind == "merge" then
        add("Merged in", (e.sourceMain or e.source or "?"))
        if e.moved and #e.moved > 0 then add("Characters moved", table.concat(e.moved, ", ")) end
        add("Rep moved", Num2(row.rep))
        add("Credits moved", Num2(row.credits))
    else
        if e.gold and e.gold > 0 then add("Gold", Num2(e.gold) .. " g") end
        for _, it in ipairs(e.items or {}) do
            local label = (it.name or ("item " .. tostring(it.itemID or "?"))) .. " x" .. (it.count or 1)
            local right
            if it.unpriced then
                right = "unpriced"
            else
                right = Num2(it.rep) .. " rep" .. ((it.category and it.category ~= "") and (" (" .. it.category .. ")") or "")
            end
            add(label, right)
        end
        add("Total rep", Num2(row.rep))
        add("Total credits", Num2(row.credits))
        if e.creditsPerRep and e.creditsPerRep.x then
            add("Rates used", ("%s Credits = %s Rep; %s Rep = %s Gold"):format(
                tostring(e.creditsPerRep.x), tostring(e.creditsPerRep.y),
                tostring(e.repPerGold and e.repPerGold.x or "?"), tostring(e.repPerGold and e.repPerGold.y or "?")))
        end
        if e.released then add("Note", "held donation, released on link") end
    end
    if e.tierBefore then
        local before = TierText(e.tierBefore, e.prestigeBefore)
        local after = TierText(e.tierAfter, e.prestigeAfter)
        add("Tier", before == after and after or (before .. " -> " .. after))
    end
    if row.by and row.by ~= "" then add(row.kind == "merge" and "Done by" or "Processed by", row.by) end
    return L
end

local function CsvField(v)
    v = tostring(v == nil and "" or v)
    if v:find('[",\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
    return v
end

-- CSV (header + one line per row, in the order given) for the export box.
function ns.CreditsLog_ExportText(rows)
    local lines = { "Date,Kind,Account,Who,What,Rep,Credits,Tier,Processed by" }
    for _, r in ipairs(rows) do
        lines[#lines + 1] = table.concat({
            CsvField(FormatDate(r.ts)), CsvField(r.kindLabel), CsvField(r.account), CsvField(r.who),
            CsvField(r.what), CsvField(("%.4f"):format(r.rep)), CsvField(("%.4f"):format(r.credits)),
            CsvField(r.tier), CsvField(r.by),
        }, ",")
    end
    return table.concat(lines, "\n")
end
