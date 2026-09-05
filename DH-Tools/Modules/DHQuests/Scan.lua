-- DH-Tools: Modules\DHQuests\Scan.lua
-- Local quest-log scanner and category classification. See
-- claude\DH-Quests\DH-Quests-Design.md Milestone 1.
--
-- Categories: Individual (no tag), Group (questTag == "Group"), Elite
-- (questTag == "Elite"), Class (questID found in ClassQuestIDs.lua's
-- allowlist - checked BEFORE the tag, since a class quest should read as
-- "Class" even if it also happens to carry a Group/Elite tag). Any other
-- native tag (PvP/Raid/Dungeon/Heroic/Legendary/Escort) falls back to
-- Individual for v1 - not covered by the original 4-category scope, and
-- rare enough in practice to defer rather than block M1 on.

DHQuests = DHQuests or {}
local ns = DHQuests

ns.CATEGORY_INDIVIDUAL = "Individual"
ns.CATEGORY_GROUP = "Group"
ns.CATEGORY_ELITE = "Elite"
ns.CATEGORY_CLASS = "Class"

-- Classifies a single quest log entry into one of the four category
-- constants above. `questTag` is whatever GetQuestLogTitle returned for
-- this entry (nil for a plain individual quest); `questID` is checked
-- against the Class allowlist first.
function ns.ClassifyQuest(questID, questTag)
    if questID and ns.CLASS_QUEST_IDS[questID] then
        return ns.CATEGORY_CLASS
    elseif questTag == "Group" then
        return ns.CATEGORY_GROUP
    elseif questTag == "Elite" then
        return ns.CATEGORY_ELITE
    else
        return ns.CATEGORY_INDIVIDUAL
    end
end

-- Scans the player's current quest log and returns a fresh table keyed by
-- questID: { [questID] = { title=, level=, category= } }. Skips header
-- rows. Does not touch ns.db.cache itself - callers decide when/whether
-- to replace the cache with a fresh scan (kept separate so M2's sync code
-- can diff old vs new without the scan function needing to know about
-- syncing).
--
-- Field order below was confirmed 2026-07-18 against a live Classic Era
-- quest log (via a temporary debug dump, since neither the originally
-- assumed order nor the commonly-documented retail/Wrath-era signature
-- matched this client): title, level, questTag, isHeader, isCollapsed,
-- isComplete, <unidentified, constant across every row observed - not
-- needed for classification>, questID. Two gotchas the original code got
-- wrong: isHeader/questID were at different positions than assumed, and
-- header rows return questID = 0 (a truthy value in Lua, not nil) rather
-- than nil, so a plain "questID" truthiness check isn't enough on its own
-- - must also exclude isHeader rows (or questID <= 0) explicitly.
--
-- suggestedGroup is NOT part of this signature on this client (no field
-- in the confirmed dump looked like a party-size number) - dropped from
-- the returned table for now. Revisit if M5's display window needs it;
-- may require a separate API call.
function ns.ScanQuestLog()
    local results = {}
    local numEntries = GetNumQuestLogEntries()
    for i = 1, numEntries do
        local title, level, questTag, isHeader, _, _, _, questID = GetQuestLogTitle(i)
        if not isHeader and questID and questID > 0 then
            results[questID] = {
                title = title,
                level = level,
                category = ns.ClassifyQuest(questID, questTag),
            }
        end
    end
    return results
end

-- Convenience for /dhq scan (manual M1 testing - no display window yet,
-- see M5): prints a scan's results to chat, grouped loosely by category.
function ns.PrintScan()
    local scan = ns.ScanQuestLog()
    local count = 0
    for _ in pairs(scan) do count = count + 1 end
    if count == 0 then
        ns.Print("No active quests found.")
        return
    end
    ns.Print(("%d active quest(s):"):format(count))
    for questID, info in pairs(scan) do
        ns.Print(("  [%s] %s (lvl %s) - %s"):format(
            tostring(questID), info.title, tostring(info.level), info.category))
    end
end
