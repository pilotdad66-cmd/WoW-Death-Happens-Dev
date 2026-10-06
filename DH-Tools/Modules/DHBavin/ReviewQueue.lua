-- DH-Tools: Modules\DHBavin\ReviewQueue.lua
-- GENERATED FILE - DO NOT HAND-EDIT.
-- Source: claude\DH-Bavin\intake\generated\review-queue.csv (intake\_step0-reconcile.ps1)
-- Regenerate: powershell -ExecutionPolicy Bypass -File claude\DH-Bavin\import-review-queue.ps1
-- Generated: 2026-10-06 16:17
--
-- Static reference data for CreditsConfig.lua's Conflicts tab - names
-- Step 0 could not map to a main (issue='no_identity_mapping') or
-- mapped ambiguously (issue='identity_conflict'), as of Step 0's last
-- run. Officers resolve a row via the Conflicts tab's link control
-- (ns.Credits_SetAltOverride), which writes to the LIVE altOverrides
-- table - this file itself only refreshes on the next Step 0 + reimport.

local DHTools = DHTools
DHTools.Bavin = DHTools.Bavin or {}
local ns = DHTools.Bavin

ns.CreditsReviewQueue = {
    { name = "thormhammer", issue = "identity_conflict", latestDonation = "2026-07-26", rawGoldAmount = 175.06, details = "claimed by: Thorm / Thormhammer; raw gold in contribution_data.csv: 175.06" },
    { name = "clubbinz", issue = "no_identity_mapping", latestDonation = "2026-09-21", rawGoldAmount = 561.22, details = "not found in contributors.csv; raw gold: 561.22" },
    { name = "dragonkeeper", issue = "no_identity_mapping", latestDonation = "2026-10-01", rawGoldAmount = 426.82, details = "not found in contributors.csv; raw gold: 426.82" },
    { name = "carielad", issue = "no_identity_mapping", latestDonation = "2026-03-31", rawGoldAmount = 227.43, details = "not found in contributors.csv; raw gold: 227.43" },
    { name = "kilherbalism", issue = "no_identity_mapping", latestDonation = "2025-07-11", rawGoldAmount = 219.85, details = "not found in contributors.csv; raw gold: 219.85" },
    { name = "rjay", issue = "no_identity_mapping", latestDonation = "2026-09-29", rawGoldAmount = 137.63, details = "not found in contributors.csv; raw gold: 137.63" },
    { name = "gratefulfree", issue = "no_identity_mapping", latestDonation = "2026-09-17", rawGoldAmount = 99.98, details = "not found in contributors.csv; raw gold: 99.98" },
    { name = "frostednutz", issue = "no_identity_mapping", latestDonation = "2025-06-14", rawGoldAmount = 96.56, details = "not found in contributors.csv; raw gold: 96.56" },
    { name = "leonidaz", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 14.3, details = "not found in contributors.csv; raw gold: 14.30" },
    { name = "severoau", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 13.04, details = "not found in contributors.csv; raw gold: 13.04" },
    { name = "laoise", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 8.35, details = "not found in contributors.csv; raw gold: 8.35" },
    { name = "gabyyx", issue = "no_identity_mapping", latestDonation = "2026-09-26", rawGoldAmount = 7.53, details = "not found in contributors.csv; raw gold: 7.53" },
    { name = "idbopthat", issue = "no_identity_mapping", latestDonation = "2026-09-27", rawGoldAmount = 6, details = "not found in contributors.csv; raw gold: 6.00" },
    { name = "cazzez", issue = "no_identity_mapping", latestDonation = "2026-09-25", rawGoldAmount = 6, details = "not found in contributors.csv; raw gold: 6.00" },
    { name = "crazydazy", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 6, details = "not found in contributors.csv; raw gold: 6.00" },
    { name = "bambamrubble", issue = "no_identity_mapping", latestDonation = "2026-10-01", rawGoldAmount = 5.38, details = "not found in contributors.csv; raw gold: 5.38" },
    { name = "sandrabelle", issue = "no_identity_mapping", latestDonation = "2026-09-29", rawGoldAmount = 4.55, details = "not found in contributors.csv; raw gold: 4.55" },
    { name = "hunnttrreess", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 4.28, details = "not found in contributors.csv; raw gold: 4.28" },
    { name = "nedda", issue = "no_identity_mapping", latestDonation = "2026-10-03", rawGoldAmount = 4.22, details = "not found in contributors.csv; raw gold: 4.22" },
    { name = "salomie", issue = "no_identity_mapping", latestDonation = "2026-09-23", rawGoldAmount = 4, details = "not found in contributors.csv; raw gold: 4.00" },
    { name = "odadin", issue = "no_identity_mapping", latestDonation = "2026-09-29", rawGoldAmount = 3.96, details = "not found in contributors.csv; raw gold: 3.96" },
    { name = "belowzerø", issue = "no_identity_mapping", latestDonation = "2026-10-03", rawGoldAmount = 3.91, details = "not found in contributors.csv; raw gold: 3.91" },
    { name = "unknøwn", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3.82, details = "not found in contributors.csv; raw gold: 3.82" },
    { name = "petitegazzlm", issue = "no_identity_mapping", latestDonation = "2026-09-29", rawGoldAmount = 3.35, details = "not found in contributors.csv; raw gold: 3.35" },
    { name = "deathbløw", issue = "no_identity_mapping", latestDonation = "2026-10-03", rawGoldAmount = 3.35, details = "not found in contributors.csv; raw gold: 3.35" },
    { name = "snowcraft", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3.3, details = "not found in contributors.csv; raw gold: 3.30" },
    { name = "kadoe", issue = "no_identity_mapping", latestDonation = "2026-09-27", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "radelbanche", issue = "no_identity_mapping", latestDonation = "2026-09-29", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "nymphador", issue = "no_identity_mapping", latestDonation = "2026-09-27", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "kleptokid", issue = "no_identity_mapping", latestDonation = "2026-09-27", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "rustyspell", issue = "no_identity_mapping", latestDonation = "2026-09-27", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "enoon", issue = "no_identity_mapping", latestDonation = "2026-09-27", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "rustyforge", issue = "no_identity_mapping", latestDonation = "2026-09-27", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "voshiv", issue = "no_identity_mapping", latestDonation = "2026-09-27", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "shalidor", issue = "no_identity_mapping", latestDonation = "2026-09-27", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "jiabaoyu", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "lyzy", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "garadeth", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "lodine", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "sumothree", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "miaon", issue = "no_identity_mapping", latestDonation = "2026-09-23", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "rissen", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "zele", issue = "no_identity_mapping", latestDonation = "2026-10-03", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "lataris", issue = "no_identity_mapping", latestDonation = "2026-10-03", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "wynterwynd", issue = "no_identity_mapping", latestDonation = "2026-10-01", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "weecheetie", issue = "no_identity_mapping", latestDonation = "2026-09-30", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "arcknight", issue = "no_identity_mapping", latestDonation = "2026-09-29", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "voth", issue = "no_identity_mapping", latestDonation = "2026-10-01", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "kitchen", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "butterscotch", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "alarus", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "tumby", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "toton", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "targetaquired", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "pirugan", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "starlight", issue = "no_identity_mapping", latestDonation = "2026-09-23", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "gylmonika", issue = "no_identity_mapping", latestDonation = "2026-09-24", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "milkiemaker", issue = "no_identity_mapping", latestDonation = "2026-09-25", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "ashildur", issue = "no_identity_mapping", latestDonation = "2026-09-25", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "magaldo", issue = "no_identity_mapping", latestDonation = "2026-09-25", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "minifroi", issue = "no_identity_mapping", latestDonation = "2026-09-25", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "hairrydotter", issue = "no_identity_mapping", latestDonation = "2026-09-23", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "glacior", issue = "no_identity_mapping", latestDonation = "2026-09-22", rawGoldAmount = 3, details = "not found in contributors.csv; raw gold: 3.00" },
    { name = "tátsuya", issue = "no_identity_mapping", latestDonation = "2026-10-03", rawGoldAmount = 2.23, details = "not found in contributors.csv; raw gold: 2.23" },
    { name = "jadiax", issue = "no_identity_mapping", latestDonation = "2026-09-23", rawGoldAmount = 1.34, details = "not found in contributors.csv; raw gold: 1.34" },
    { name = "veneratebank", issue = "no_identity_mapping", latestDonation = "2026-10-03", rawGoldAmount = 1.27, details = "not found in contributors.csv; raw gold: 1.27" },
    { name = "bailourr", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 0.91, details = "not found in contributors.csv; raw gold: 0.91" },
    { name = "darksanta", issue = "no_identity_mapping", latestDonation = "2026-09-23", rawGoldAmount = 0.82, details = "not found in contributors.csv; raw gold: 0.82" },
    { name = "lvlsixtywarr", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 0.77, details = "not found in contributors.csv; raw gold: 0.77" },
    { name = "vanquished", issue = "no_identity_mapping", latestDonation = "2026-10-03", rawGoldAmount = 0.36, details = "not found in contributors.csv; raw gold: 0.36" },
    { name = "crayator", issue = "no_identity_mapping", latestDonation = "2026-10-04", rawGoldAmount = 0.12, details = "not found in contributors.csv; raw gold: 0.12" },
    { name = "synolade", issue = "no_identity_mapping", latestDonation = "2026-10-01", rawGoldAmount = 0, details = "not found in contributors.csv; raw gold: 0.00" },
    { name = "seriousblac", issue = "no_identity_mapping", latestDonation = "2026-10-01", rawGoldAmount = 0, details = "not found in contributors.csv; raw gold: 0.00" },
}
