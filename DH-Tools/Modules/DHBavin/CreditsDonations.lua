-- CM4 (see DH-Bavin-Credits-Design.md "CM4 as designed"): the donation
-- LOGIC behind incoming-mail crediting - valuation, who gets credited,
-- applying a credit, held credits and account merge. Deliberately free of
-- any frame or mail API so the headless harness can drive all of it; the
-- inbox hook, checkboxes and diff-based take confirmation that call into
-- this live in CreditsInbox.lua (installed only on Wall 4's armed
-- receiver). Nothing here runs unless something calls it.
--
-- A "donation" (what CreditsInbox hands to ns.CreditsDon_Credit) is
--   { sender = "Name", receiver = "Name"?, copper = N?,
--     items = { { itemID = , name = , count = }, ... } }
-- and an "entry" (what valuation produces, what the transaction log and the
-- held-credits store keep) is
--   { id, ts, sender, receiver, items = { {itemID,name,count,rep,category,
--     unpriced}, ... }, gold = <fractional gold>, rep, credits,
--     creditsPerRep = {x,y}, repPerGold = {x,y} }       (rates actually used)
-- plus, once applied to an account, account / tierBefore / prestigeBefore /
-- tierAfter / prestigeAfter (and released = true for a held entry that was
-- applied later).

local DHTools = DHTools
DHTools.Bavin = DHTools.Bavin or {}
local ns = DHTools.Bavin

--------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------
local function Now()
    return (GetServerTime and GetServerTime()) or time()
end

local idCounter = 0
local function NewId()
    idCounter = idCounter + 1
    return ("%x-%x-%x"):format(Now(), idCounter, math.random(0, 65535))
end

-- 1234.5 -> "1,234.50": rep and credits are DISPLAYED with exactly two
-- decimals everywhere (2026-10-04, Loopi) while stored values keep four
-- (Round4 below).
local function Fmt(n)
    n = tonumber(n) or 0
    local s = ("%.2f"):format(n)
    local sign, int, frac = s:match("^(%-?)(%d+)%.(%d+)$")
    if not int then return s end
    local out = int:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    out = out:gsub("^,", "")
    return sign .. out .. "." .. frac
end
ns.CreditsDon_Fmt = Fmt

-- Whole number with thousands separators (tier caps).
local function Fmt0(n)
    local s = tostring(math.floor((tonumber(n) or 0) + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- Stored values are rounded to four decimal places (kills float noise such
-- as 0.2 x 6 = 1.2000000000000002 and keeps every officer's copy identical).
local function Round4(n)
    return math.floor((tonumber(n) or 0) * 10000 + 0.5) / 10000
end
ns.CreditsDon_Round4 = Round4

local function DateString(ts)
    if date then return date("%Y-%m-%d", ts) end
    return ""
end

local function ProgressText(tier, prestige, points)
    local cap = ns.CreditsTierCaps and ns.CreditsTierCaps[tier] or 0
    local label = tier .. ((prestige or 0) > 0 and (" P" .. prestige) or "")
    return ("%s %s/%s"):format(label, Fmt0(points), Fmt0(cap)) -- tier points are whole numbers
end

-- Chat output for the donation flow (kept in one place so tests can read it).
local function Say(msg)
    if ns.CreditsPrint then ns.CreditsPrint(msg) end
end

--------------------------------------------------------------------------
-- Valuation (spec step 4)
--------------------------------------------------------------------------
-- Items use the SAME override-aware lookup the tooltip uses
-- (ns.GetItemPoints), x stack count; an item with no entry at all is
-- unpriced = 0 rep (and is named in the chat output). Gold: copper/10000,
-- fractional, x repPerGold (x Rep = y Gold). Credits = rep x creditsPerRep
-- (x Credits = y Rep) for items and gold alike. The rates are ALWAYS the
-- officer-configured Settings values from creditsDb - never a constant here.
-- Decimal math throughout; rounding is display only.
function ns.CreditsDon_Value(donation)
    local db = ns.creditsDb
    local cpr = (db and db.creditsPerRep) or { x = 1, y = 100 }
    local rpg = (db and db.repPerGold) or { x = 100, y = 1 }
    local entry = {
        id = NewId(),
        ts = Now(),
        sender = donation.sender,
        receiver = donation.receiver or (UnitName and UnitName("player")) or "",
        items = {},
        gold = (tonumber(donation.copper) or 0) / 10000,
        rep = 0,
        credits = 0,
        creditsPerRep = { x = cpr.x, y = cpr.y },
        repPerGold = { x = rpg.x, y = rpg.y },
    }
    local rep = 0
    -- Same item twice (two slots) collapses into one line.
    local byKey, order = {}, {}
    for _, it in ipairs(donation.items or {}) do
        local key = tostring(it.itemID or "") .. "|" .. tostring(it.name or "")
        local line = byKey[key]
        if not line then
            line = { itemID = it.itemID, name = it.name or ("item:" .. tostring(it.itemID)), count = 0 }
            byKey[key] = line
            order[#order + 1] = line
        end
        line.count = line.count + (tonumber(it.count) or 1)
    end
    for _, line in ipairs(order) do
        local info = ns.GetItemPoints and ns.GetItemPoints(line.name)
        if info and info.points ~= nil then
            line.rep = Round4((tonumber(info.points) or 0) * line.count)
            local base = ns.ITEM_POINTS and ns.ITEM_POINTS[line.name]
            line.category = (base and base.category) or "Uncategorized"
        else
            line.rep = 0
            line.unpriced = true
            line.category = "Uncategorized"
        end
        rep = rep + line.rep
        entry.items[#entry.items + 1] = line
    end
    if entry.gold > 0 then
        rep = rep + entry.gold * rpg.x / rpg.y
    end
    entry.rep = Round4(rep)
    entry.credits = Round4(entry.rep * cpr.x / cpr.y)
    return entry
end

--------------------------------------------------------------------------
-- Who gets credited (spec step 6)
--------------------------------------------------------------------------
-- A separate helper rather than a change to Credits_ResolveMain (which
-- never returns nil). Returns the account record, or nil if the sender
-- isn't resolvable (not on any account and not in the guild). Mutates the
-- ledger (link / create) and stamps CM3 sync for what it touched; the
-- touched account keys come back as the 2nd result so the caller can sync
-- once after crediting.
local function UniqueKey(base)
    local ledger = ns.creditsDb.ledger
    if not ledger[base] then return base end
    local n = 2
    while ledger[base .. "#" .. n] do n = n + 1 end
    return base .. "#" .. n
end

local function NewAccount(mainBare)
    local key = UniqueKey(mainBare)
    local rec = {
        discordName = key,
        discord = mainBare,
        mainToon = mainBare,
        alts = {},
        points = 0,
        credits = 0,
        lifetimeCredits = 0,
        tier = "Neutral",
        prestige = 0,
        lifetimePoints = 0,
        lastDonationDate = "",
        lastUpdated = time(),
    }
    ns.creditsDb.ledger[key] = rec
    ns.creditsDb.toonIndex[mainBare:lower()] = key
    return rec
end

local function AddAlt(rec, altBare)
    rec.alts = rec.alts or {}
    for _, a in ipairs(rec.alts) do
        if a:lower() == altBare:lower() then return end
    end
    table.insert(rec.alts, altBare)
    ns.creditsDb.toonIndex[altBare:lower()] = rec.discordName
end

local function GrmMain(bare)
    if not (GRM and GRM.GetPlayerMain) then return nil end
    local realm = GetRealmName and GetRealmName() or ""
    local ok, main = pcall(GRM.GetPlayerMain, bare .. "-" .. realm)
    if ok and type(main) == "string" and main ~= "" then
        return ns.NormalizeName(main:match("^([^%-]+)") or main)
    end
    return nil
end

function ns.CreditsDon_ResolveAccount(senderName)
    local db = ns.creditsDb
    if not db or not senderName or senderName == "" then return nil end
    local bare = ns.NormalizeName(senderName)
    if not db.toonIndex then ns.Credits_RebuildToonIndex() end

    -- 1. Our own data first - this is also what makes a remade character
    -- with the same name land on its old account with all its history.
    local existingKey = db.toonIndex[bare:lower()]
    if existingKey and db.ledger[existingKey] then
        return db.ledger[existingKey], { existingKey }
    end

    -- 2. Not on any account: only guild members are placed automatically.
    if not ns.IsGuildMember(bare) then return nil end

    -- Everything below changes the ledger (3rd result = true).
    local main = GrmMain(bare)
    if main and main:lower() ~= bare:lower() then
        local mainKey = db.toonIndex[main:lower()]
        local mainRec = mainKey and db.ledger[mainKey]
        if mainRec then
            AddAlt(mainRec, bare) -- GRM's main already has an account
            return mainRec, { mainRec.discordName }, true
        end
        local rec = NewAccount(main) -- GRM's main has none yet
        AddAlt(rec, bare)
        return rec, { rec.discordName }, true
    end
    local rec = NewAccount(bare) -- GRM nil, or the sender is its own main
    return rec, { rec.discordName }, true
end

local function InDynamicQueue(name)
    local key = name:lower()
    for _, q in ipairs(ns.creditsDb.dynamicReviewQueue or {}) do
        if (q.name or ""):lower() == key then return true end
    end
    return false
end

--------------------------------------------------------------------------
-- Applying a credit (spec step 5)
--------------------------------------------------------------------------
-- Mutates the account and returns a log entry (the valuation entry plus the
-- account and before/after tier). Does not sync or print.
local function ApplyToAccount(rec, entry)
    local tierBefore, prestigeBefore = rec.tier, rec.prestige or 0
    rec.lifetimePoints = Round4((tonumber(rec.lifetimePoints) or 0) + entry.rep)
    rec.tier, rec.prestige, rec.points = ns.Credits_TierStateForLifetime(rec.lifetimePoints)
    rec.points = Round4(rec.points)
    ns.Credits_AdjustCredits(rec, entry.credits)
    local day = DateString(entry.ts)
    if day ~= "" and day > (rec.lastDonationDate or "") then rec.lastDonationDate = day end
    rec.lastUpdated = time()
    local logged = {}
    for k, v in pairs(entry) do logged[k] = v end
    logged.account = rec.discordName
    logged.tierBefore, logged.prestigeBefore = tierBefore, prestigeBefore
    logged.tierAfter, logged.prestigeAfter = rec.tier, rec.prestige
    return logged
end

local function Announce(rec, entry, logged)
    local who = entry.sender
    if rec.mainToon and rec.mainToon:lower() ~= entry.sender:lower() then
        who = who .. " (" .. rec.mainToon .. ")"
    end
    Say(("%s: +%s rep, +%s credits (%s)%s"):format(
        who, Fmt(entry.rep), Fmt(entry.credits),
        ProgressText(rec.tier, rec.prestige, rec.points),
        logged.released and " [released from pending]" or ""))
    if logged.tierAfter ~= logged.tierBefore or logged.prestigeAfter ~= logged.prestigeBefore then
        if logged.prestigeAfter ~= logged.prestigeBefore then
            Say(("|cffffd100PRESTIGE UP:|r %s reached Exalted Prestige %d"):format(rec.mainToon or entry.sender, logged.prestigeAfter))
        else
            Say(("|cffffd100TIER UP:|r %s is now %s"):format(rec.mainToon or entry.sender, logged.tierAfter))
        end
    end
end

-- Every audit-log row is also pushed live to the online officers (CM7:
-- the log is replicated to every officer, every row - CreditsSync.lua).
local function LogEntry(logged)
    table.insert(ns.creditsDb.transactionLog, logged)
    if ns.CreditsSync_LogAdded then ns.CreditsSync_LogAdded(logged) end
end

local function SyncChanged(keys, queueChanges, extra)
    if ns.CreditsSync_Changed then ns.CreditsSync_Changed(keys, queueChanges, extra) end
end

--------------------------------------------------------------------------
-- Archived-donor carryover (2026-10-07, Loopi; RESEED-RUNBOOK section 3)
--------------------------------------------------------------------------
-- A name in curated\archived-donors.csv was dropped from the Review Queue and
-- its old gold never counted toward any account. When such a name donates
-- again and the donation lands on an account, its old history
-- (ns.CreditsArchivedDonors[name] = { latestDonation, rawGold, points },
-- generated by Step 0) is added ONCE to that account's lifetime rep, with 0
-- credits. "Once" = a log row with the fixed id "carry-<lowername>": log rows
-- replicate by id, so another officer, a relink or a release of more held
-- donations never applies it twice. "Start from scratch" clears the log, so
-- the carryover can apply again after a reset (the history is static data).
-- NOTE for CM7 proper: purging old log rows would also forget these ids.
local function ArchivedDonorFor(sender)
    if not sender or sender == "" or not ns.CreditsArchivedDonors then return nil end
    return ns.CreditsArchivedDonors[ns.NormalizeName(sender):lower()]
end

local function CarryoverId(sender)
    return "carry-" .. ns.NormalizeName(sender):lower()
end

local function HasLogId(id)
    for _, e in ipairs(ns.creditsDb.transactionLog or {}) do
        if type(e) == "table" and e.id == id then return true end
    end
    return false
end

-- Review Queue text for a held archived donor ("" for anyone else).
local function ArchivedNote(sender)
    local arch = ArchivedDonorFor(sender)
    if not arch or (tonumber(arch[3]) or 0) <= 0 then return "" end
    local last = (arch[1] and arch[1] ~= "") and (", last " .. arch[1]) or ""
    return (" - previously donated %s gold (%s rep)%s - carried over when linked"):format(
        Fmt0(arch[2]), Fmt0(arch[3]), last)
end

-- Adds the carryover to `rec` if `entry.sender` is an archived donor that has
-- not had it yet. Logs, replicates the log row and says so in chat. The
-- caller syncs the account record (SyncChanged) as it already does for the
-- donation itself. Returns the log row, or nil if nothing was applied.
local function ApplyCarryover(rec, entry)
    local arch = ArchivedDonorFor(entry.sender)
    local points = arch and tonumber(arch[3]) or 0
    if points <= 0 then return nil end
    local id = CarryoverId(entry.sender)
    if HasLogId(id) then return nil end

    local tierBefore, prestigeBefore = rec.tier, rec.prestige or 0
    rec.lifetimePoints = Round4((tonumber(rec.lifetimePoints) or 0) + points)
    rec.tier, rec.prestige, rec.points = ns.Credits_TierStateForLifetime(rec.lifetimePoints)
    rec.points = Round4(rec.points)
    rec.lastUpdated = time()
    local logged = {
        id = id,
        ts = entry.ts or Now(),
        kind = "carryover",
        account = rec.discordName,
        sender = entry.sender,
        what = ("Earlier donations carried over (%s gold%s)"):format(
            Fmt0(arch[2]), (arch[1] and arch[1] ~= "") and (", last " .. arch[1]) or ""),
        rep = points,
        credits = 0,
        officer = UnitName and UnitName("player") or "",
        tierBefore = tierBefore, prestigeBefore = prestigeBefore,
        tierAfter = rec.tier, prestigeAfter = rec.prestige,
    }
    LogEntry(logged)
    Say(("%s: +%s rep carried over from earlier donations (0 credits)."):format(entry.sender, Fmt(points)))
    if rec.prestige ~= prestigeBefore then
        Say(("|cffffd100PRESTIGE UP:|r %s reached Exalted Prestige %d"):format(rec.mainToon or entry.sender, rec.prestige))
    elseif rec.tier ~= tierBefore then
        Say(("|cffffd100TIER UP:|r %s is now %s"):format(rec.mainToon or entry.sender, rec.tier))
    end
    return logged
end

--------------------------------------------------------------------------
-- Held credits (spec step 7)
--------------------------------------------------------------------------
local function Hold(entry)
    local db = ns.creditsDb
    local key = entry.sender:lower()
    db.pendingCredits[key] = db.pendingCredits[key] or {}
    table.insert(db.pendingCredits[key], entry)
    local held = 0
    local heldCredits = 0
    for _, e in ipairs(db.pendingCredits[key]) do
        held = held + e.rep
        heldCredits = heldCredits + e.credits
    end
    local day = DateString(entry.ts)
    ns.Credits_AddToReviewQueue(entry.sender, "unresolved_donor",
        ("held donation - %s rep / %s credits waiting for an officer to link this name"):format(Fmt(held), Fmt(heldCredits))
            .. ArchivedNote(entry.sender),
        day ~= "" and day or nil)
    SyncChanged(nil, { { name = entry.sender, present = true, issue = "unresolved_donor" } },
        { pendingAdded = { entry } })
    Say(("Held %s rep / %s credits for %s until an officer links them (Review Queue)."):format(
        Fmt(held), Fmt(heldCredits), entry.sender))
end

-- Totals held for a name, for the Review Queue row. (0, 0) if none.
function ns.CreditsDon_HeldTotals(name)
    local list = ns.creditsDb and ns.creditsDb.pendingCredits and ns.creditsDb.pendingCredits[(name or ""):lower()]
    local rep, credits, n = 0, 0, 0
    for _, e in ipairs(list or {}) do
        rep = rep + e.rep
        credits = credits + e.credits
        n = n + 1
    end
    return rep, credits, n
end

--------------------------------------------------------------------------
-- The entry point CreditsInbox calls once per credited mail
--------------------------------------------------------------------------
-- Returns a result table { status = "credited" | "held" | "zero" |
-- "disabled", entry =, account = } (tests and the caller can ignore it).
function ns.CreditsDon_Credit(donation)
    if not ns.creditsDb or not donation or not donation.sender then
        return { status = "disabled" }
    end
    local entry = ns.CreditsDon_Value(donation)

    local unpriced = {}
    for _, line in ipairs(entry.items) do
        if line.unpriced then unpriced[#unpriced + 1] = line.name end
    end
    if #unpriced > 0 then
        Say(("%s sent %d item(s) with no Bavin Points entry (credited 0 rep): %s"):format(
            entry.sender, #unpriced, table.concat(unpriced, ", ")))
    end

    -- Nothing worth crediting (only unpriced items): no account is created
    -- or touched for it.
    if entry.rep <= 0 and entry.credits <= 0 then
        return { status = "zero", entry = entry }
    end

    local wasQueued = InDynamicQueue(entry.sender)
    local rec, touched, mutated = ns.CreditsDon_ResolveAccount(entry.sender)
    if not rec then
        Hold(entry)
        return { status = "held", entry = entry }
    end
    ApplyCarryover(rec, entry) -- archived donor's old history, once (before the donation row)
    local logged = ApplyToAccount(rec, entry)
    LogEntry(logged)
    Announce(rec, entry, logged)
    local keys = {}
    for _, k in ipairs(touched or {}) do keys[#keys + 1] = k end
    local queueChanges
    if wasQueued or mutated then
        -- The name now belongs to an account, so it leaves the Review Queue.
        ns.Credits_RemoveFromReviewQueue(entry.sender)
        queueChanges = { { name = entry.sender, present = false } }
    end
    SyncChanged(keys, queueChanges)
    return { status = "credited", entry = entry, account = rec, logged = logged }
end

--------------------------------------------------------------------------
-- Releasing held credits (spec step 7)
--------------------------------------------------------------------------
-- Runs ONLY on the mail recipient's armed client (there is exactly one
-- recipient; officers merely hold a replicated copy). Called after a local
-- link / new-main, after a link arrives through CM3 sync, at login and on a
-- guild roster update. For every held sender that now resolves to an
-- account (including a guild member who has since appeared in the roster),
-- each entry is applied with its ORIGINAL timestamp, logged "released from
-- pending", removed, and a tombstone replicated so officers drop their
-- copy. Returns how many entries were released.
function ns.Credits_ReleasePending()
    local db = ns.creditsDb
    if not db or not ns.creditsArmedInbox then return 0 end
    if not db.pendingCredits or next(db.pendingCredits) == nil then return 0 end

    local senders = {}
    for senderLower in pairs(db.pendingCredits) do senders[#senders + 1] = senderLower end
    table.sort(senders)

    local released = 0
    for _, senderLower in ipairs(senders) do
        local list = db.pendingCredits[senderLower]
        local sender = list and list[1] and list[1].sender
        if sender then
            local rec, touched = ns.CreditsDon_ResolveAccount(sender)
            if rec then
                local keys, ids = {}, {}
                for _, k in ipairs(touched or {}) do keys[#keys + 1] = k end
                for _, entry in ipairs(list) do
                    ApplyCarryover(rec, entry) -- no-op after the first held entry
                    local logged = ApplyToAccount(rec, entry)
                    logged.released = true
                    logged.releasedAt = Now()
                    LogEntry(logged)
                    Announce(rec, entry, logged)
                    ids[#ids + 1] = entry.id
                    released = released + 1
                end
                db.pendingCredits[senderLower] = nil
                ns.Credits_RemoveFromReviewQueue(sender)
                SyncChanged(keys, { { name = sender, present = false } }, { pendingReleased = ids })
            end
        end
    end
    if released > 0 and ns.CreditsConfig_Refresh then ns.CreditsConfig_Refresh() end
    return released
end

--------------------------------------------------------------------------
-- Account merge (spec step 8)
--------------------------------------------------------------------------
-- For an auto-created account that turns out to be someone's alt: moves the
-- source's main + alts into the target, adds lifetimePoints / credits /
-- lifetimeCredits, keeps the later lastDonationDate, re-tags the source's
-- transaction-log entries to the target, deletes the source (with a CM3
-- tombstone), logs a merge entry, and recomputes tier/prestige from the
-- summed lifetime. Officer-gated like the other account edits. Returns
-- true, or false plus a reason.
function ns.Credits_MergeAccounts(sourceKey, targetKey)
    if not ns.CanManageCreditsConfigLocal() then return false, "not an officer" end
    local db = ns.creditsDb
    if not db or not sourceKey or not targetKey then return false, "missing account" end
    if sourceKey == targetKey then return false, "same account" end
    local source, target = db.ledger[sourceKey], db.ledger[targetKey]
    if not source or not target then return false, "unknown account" end

    local moved = {}
    local function Take(name)
        if not name or name == "" then return end
        if target.mainToon and target.mainToon:lower() == name:lower() then return end
        for _, a in ipairs(target.alts or {}) do
            if a:lower() == name:lower() then return end
        end
        target.alts = target.alts or {}
        table.insert(target.alts, name)
        moved[#moved + 1] = name
    end
    Take(source.mainToon)
    for _, a in ipairs(source.alts or {}) do Take(a) end

    local rep = tonumber(source.lifetimePoints) or 0
    local credits = tonumber(source.credits) or 0
    local lifeCredits = tonumber(source.lifetimeCredits) or credits
    local tierBefore, prestigeBefore = target.tier, target.prestige or 0
    target.lifetimePoints = Round4((tonumber(target.lifetimePoints) or 0) + rep)
    target.tier, target.prestige, target.points = ns.Credits_TierStateForLifetime(target.lifetimePoints)
    target.points = Round4(target.points)
    target.credits = Round4((tonumber(target.credits) or 0) + credits)
    target.lifetimeCredits = Round4((tonumber(target.lifetimeCredits) or 0) + lifeCredits)
    if target.lifetimeCredits < target.credits then target.lifetimeCredits = target.credits end
    if (source.lastDonationDate or "") > (target.lastDonationDate or "") then
        target.lastDonationDate = source.lastDonationDate
    end
    target.lastUpdated = time()

    for _, e in ipairs(db.transactionLog) do
        if e.account == sourceKey then e.account = targetKey end
    end
    LogEntry({
        id = NewId(),
        ts = Now(),
        kind = "merge",
        account = targetKey,
        source = sourceKey,
        sourceMain = source.mainToon,
        moved = moved,
        rep = rep,
        credits = credits,
        officer = UnitName and UnitName("player") or "",
        tierBefore = tierBefore, prestigeBefore = prestigeBefore,
        tierAfter = target.tier, prestigeAfter = target.prestige,
    })

    db.ledger[sourceKey] = nil
    ns.Credits_RebuildToonIndex()
    SyncChanged({ targetKey }, nil, { deleted = { sourceKey } })
    Say(("Merged %s into %s: +%s rep, +%s credits (%s)."):format(
        source.mainToon or sourceKey, target.mainToon or targetKey, Fmt(rep), Fmt(credits),
        ProgressText(target.tier, target.prestige, target.points)))
    if ns.CreditsConfig_Refresh then ns.CreditsConfig_Refresh() end
    return true
end

