-- DH-Tools: Modules\DHBavin\ReviewQueue.lua
-- GENERATED FILE - DO NOT HAND-EDIT.
-- Source: claude\DH-Bavin\intake\generated\review-queue.csv (intake\_step0-reconcile.ps1)
-- Regenerate: powershell -ExecutionPolicy Bypass -File claude\DH-Bavin\import-review-queue.ps1
-- Generated: 2026-09-28 21:33
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
}
