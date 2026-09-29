-- DH-Tools: Modules\DHBavin\ReviewQueue.lua
-- GENERATED FILE - DO NOT HAND-EDIT.
-- Source: claude\DH-Bavin\intake\generated\review-queue.csv (intake\_step0-reconcile.ps1)
-- Regenerate: powershell -ExecutionPolicy Bypass -File claude\DH-Bavin\import-review-queue.ps1
-- Generated: 2026-09-29 18:32
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
    { name = "dragonkeeper", issue = "no_identity_mapping", latestDonation = "2026-09-19", rawGoldAmount = 380.18, details = "not found in contributors.csv; raw gold: 380.18" },
    { name = "carielad", issue = "no_identity_mapping", latestDonation = "2026-03-31", rawGoldAmount = 227.43, details = "not found in contributors.csv; raw gold: 227.43" },
    { name = "kilherbalism", issue = "no_identity_mapping", latestDonation = "2025-07-11", rawGoldAmount = 219.85, details = "not found in contributors.csv; raw gold: 219.85" },
    { name = "rjay", issue = "no_identity_mapping", latestDonation = "2026-09-21", rawGoldAmount = 124.04, details = "not found in contributors.csv; raw gold: 124.04" },
    { name = "gratefulfree", issue = "no_identity_mapping", latestDonation = "2026-09-17", rawGoldAmount = 99.98, details = "not found in contributors.csv; raw gold: 99.98" },
    { name = "frostednutz", issue = "no_identity_mapping", latestDonation = "2025-06-14", rawGoldAmount = 96.56, details = "not found in contributors.csv; raw gold: 96.56" },
}
