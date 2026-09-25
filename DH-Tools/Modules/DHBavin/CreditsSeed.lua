-- DH-Tools: Modules\DHBavin\CreditsSeed.lua
-- CM2 (see this folder's DH-Bavin-Credits-Design.md "Milestone plan") -
-- historical seed import: one-time, officer-triggered, converts Step
-- 0's reconciled seed-dataset.csv (shipped as SeedData.lua's
-- ns.CreditsSeedData table - see that file's own header) into starting
-- ledger entries.
--
-- CREDITS SEED AT 0, NOT DERIVED FROM lifetimePoints (2026-09-25,
-- Chris): only lifetimePoints/tier/prestige/points come from the
-- historical data. Every member's spendable credits balance starts at
-- 0 on go-live regardless of lifetime reputation - credits are earned
-- going forward under the new system, not retroactively granted for
-- past donations already reflected in points/tier.
--
-- TIER MATH LIVES HERE, NOT INLINE IN THE IMPORTER: CM4's live
-- crediting logic (every future mail-processed donation) needs the
-- exact same lifetimePoints -> tier/prestige/points-in-tier
-- calculation this one-time import uses, so it's one shared function
-- with one home, not duplicated.

local DHTools = DHTools
DHTools.Bavin = DHTools.Bavin or {}
local ns = DHTools.Bavin

--------------------------------------------------------------------------
-- Tier math (design doc's "## Tiers" section, resolved 2026-08-31)
--------------------------------------------------------------------------
local TIER_ORDER = { "Neutral", "Friendly", "Honored", "Revered", "Exalted" }
local TIER_CAPS = {
    Neutral  = 3000,
    Friendly = 6000,
    Honored  = 12000,
    Revered  = 21000,
    Exalted  = 50000, -- loops as Prestige I, II, ... uncapped (Chris confirmed)
}
ns.CreditsTierOrder = TIER_ORDER
ns.CreditsTierCaps = TIER_CAPS

-- lifetimePoints (a running, never-decreasing total) -> tier, prestige,
-- points (the member's current position within that tier/prestige lap).
-- Crossing a tier's cap resets points to 0 and advances to the next
-- tier (design doc: "same rule Chris originally described"); Exalted
-- has no next tier to advance into, so it instead loops in its own
-- 50,000-point laps, each lap bumping prestige by 1 (design doc's
-- "Prestige" section, parsing correction confirmed 2026-08-31).
function ns.Credits_TierStateForLifetime(lifetimePoints)
    local remaining = math.max(0, tonumber(lifetimePoints) or 0)
    for i = 1, #TIER_ORDER - 1 do
        local tierName = TIER_ORDER[i]
        local cap = TIER_CAPS[tierName]
        if remaining < cap then
            return tierName, 0, remaining
        end
        remaining = remaining - cap
    end
    local exaltedCap = TIER_CAPS.Exalted
    local prestige = math.floor(remaining / exaltedCap)
    local points = remaining % exaltedCap
    return "Exalted", prestige, points
end

--------------------------------------------------------------------------
-- Seed import (officer-gated, idempotent - safe to re-run; each run
-- fully overwrites the ledger ROW for every name in SeedData.lua, but
-- never touches ledger rows for names NOT in that table, e.g. anything
-- CM4 has already live-credited by the time this runs again)
--------------------------------------------------------------------------
-- LOCAL ONLY for CM2, same as Credits_ResetTestData (Credits.lua) - the
-- officer-only ledger sync wire format is CM3's job (design doc: "TBD
-- there"), so this doesn't guess at one. Each officer who needs a
-- populated local ledger for CM2/CM4 testing runs this on their own
-- client; the real historical seed happens once, for real, at go-live,
-- from whichever officer's client runs it last before cutover.
-- SeedData.lua ships mainName -> { lifetimePoints, latestDonation }
-- (2026-09-25: latestDonation added so the Roster tab can show/sort a
-- "Last Donation" column - Chris's ask - without a second lookup
-- table). `lastDonationDate` is an addition to the design doc's
-- original ledger shape (`{ mainName, points, credits, tier, prestige,
-- lifetimePoints, lastUpdated }`) - it's Step 0's historical snapshot
-- date, not something CM4's live crediting updates going forward (no
-- live "date of last credited donation" tracking exists yet); read it
-- as "as of the last Step 0 pass," same caveat as lifetimePoints.
function ns.CreditsSeed_Import()
    if not ns.CanManageCreditsConfigLocal() then return false end
    if not ns.CreditsSeedData then
        ns.CreditsPrint("SeedData.lua isn't loaded - nothing to import.")
        return false
    end
    if not ns.creditsDb then return false end

    local now = time()
    local count = 0
    for mainName, entry in pairs(ns.CreditsSeedData) do
        -- entry is normally a table ({ lifetimePoints, latestDonation }
        -- per SeedData.lua's current header) - the number branch is
        -- just a defensive fallback (indexing a plain number with `.`
        -- errors in Lua, so this can't just do entry.lifetimePoints or
        -- entry), not real back-compat with any file this addon ships.
        local lifetimePoints, latestDonation = 0, ""
        if type(entry) == "table" then
            lifetimePoints = entry.lifetimePoints or 0
            latestDonation = entry.latestDonation or ""
        elseif type(entry) == "number" then
            lifetimePoints = entry
        end
        local tier, prestige, points = ns.Credits_TierStateForLifetime(lifetimePoints)
        ns.creditsDb.ledger[mainName] = {
            mainName = mainName,
            points = points,
            credits = 0, -- seeded at 0 for everyone at go-live (Chris, 2026-09-25)
            tier = tier,
            prestige = prestige,
            lifetimePoints = tonumber(lifetimePoints) or 0,
            lastDonationDate = latestDonation,
            lastUpdated = now,
        }
        count = count + 1
    end
    ns.CreditsPrint(("Seeded %d mains from historical data (SeedData.lua)."):format(count))
    return true, count
end

--------------------------------------------------------------------------
-- "Set as New Main" (2026-09-25 round 4, Chris, Conflicts tab concern
-- #6: "In addition to 'link' there needs to be a 'set as new main'
-- option too"). Promotes a Conflicts-tab name straight to being its own
-- main, seeded with the real lifetime total it already earned before
-- Step 0 could place it - Chris: "the lifetime total will be whatever
-- that character has as their total... they had to show up in the
-- contributions data in order to make the conflicts list in the first
-- place." rawGoldAmount is Step 0's own raw-gold figure for this row
-- (ReviewQueue.lua, sourced from step0-reconcile.ps1's
-- $conflictGold/$unresolvedGold), converted with the same
-- 10-points-per-gold convention seed-dataset.csv itself uses
-- (totalPoints = totalGoldAmount * 10).
--
-- Two effects, same shape as a manual Link except mainName == altName:
-- (1) an altOverride pointing the name at itself via the existing
-- Credits_SetAltOverride (Credits.lua) - without this, a later live
-- donation from this same name could get silently attributed to
-- whichever main GRM believes claims it (Credits_ResolveMain checks
-- GRM before falling back to self), undoing this decision; (2) a
-- ledger row via the same tier math CreditsSeed_Import uses above, so
-- it shows up correctly on the Roster tab immediately rather than
-- waiting for a reseed. Officer-gated the same way as everything else
-- in this file (via Credits_SetAltOverride's own gate).
function ns.Credits_SetAsNewMain(altName, rawGoldAmount, latestDonation)
    if not altName or altName == "" then return false end
    if not ns.creditsDb then return false end

    local mainName = ns.NormalizeName(altName)
    if not ns.Credits_SetAltOverride(mainName, mainName) then return false end

    local lifetimePoints = (tonumber(rawGoldAmount) or 0) * 10
    local tier, prestige, points = ns.Credits_TierStateForLifetime(lifetimePoints)
    ns.creditsDb.ledger[mainName] = {
        mainName = mainName,
        points = points,
        credits = 0, -- same go-live convention as CreditsSeed_Import above: credits start at 0, only lifetimePoints/tier/prestige come from history
        tier = tier,
        prestige = prestige,
        lifetimePoints = lifetimePoints,
        lastDonationDate = latestDonation or "",
        lastUpdated = time(),
    }
    return true
end
