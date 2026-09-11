-- DHDanger headless harness.
-- Run from ROOT:  lua src\DH-Tools\Modules\DHDanger\tests\harness.lua
--
-- WHY: this is a safety tool, and its two characteristic failures are
-- both SILENT. It can fail to warn (nothing happens, which looks exactly
-- like "no danger nearby"), or it can warn constantly (which gets it
-- muted, and then it fails to warn). Neither shows up in a syntax check,
-- and neither is obvious in-game until it has already cost something.
--
-- Covered: npcID derivation from both event paths, the list gate, the
-- repeat-alert cooldown, the nameplate prerequisite, and the friendly /
-- dead / player-unit exclusions.

---------------------------------------------------------------------
-- Minimal WoW API stubs
---------------------------------------------------------------------
local now = 1000
local cvars = { nameplateShowEnemies = "1" }
local units = {}
local chat = {}
local sounds = 0
local frame

function GetTime() return now end
function GetCVar(k) return cvars[k] end
function CreateFrame()
	local fr = { events = {} }
	fr.SetScript = function(s, k, fn) s[k] = fn end
	fr.RegisterEvent = function(s, e) s.events[e] = true end
	frame = fr
	return fr
end
function PlaySound() sounds = sounds + 1 end
SOUNDKIT = { RAID_WARNING = 8959 }
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = m end }
SlashCmdList = {}

-- Sync.lua stubs. guildMember/groupType are test-controlled; sentAddonMsgs
-- captures every C_ChatInfo.SendAddonMessage call so a test can assert on
-- what ns.BroadcastSighting actually sent (or that it sent nothing).
local guildMember = true
local groupType -- nil | "party" | "raid"
function IsInGuild() return guildMember end
function IsInGroup() return groupType ~= nil end
function IsInRaid() return groupType == "raid" end

local sentAddonMsgs = {}
C_ChatInfo = {
	SendAddonMessage = function(prefix, text, channel)
		sentAddonMsgs[#sentAddonMsgs + 1] = { prefix = prefix, text = text, channel = channel }
	end,
	RegisterAddonMessagePrefix = function() end,
}

function UnitExists(u) return units[u] ~= nil end
function UnitGUID(u)  return units[u] and units[u].guid end
function UnitName(u)  return units[u] and units[u].name end
function UnitIsPlayer(u) return units[u] and units[u].player or false end
function UnitIsDead(u)   return units[u] and units[u].dead or false end
function UnitCanAttack(_, u) return units[u] and not units[u].friendly and not units[u].player end

-- WoW's UnitPosition returns Y, X, Z, instanceID - deliberately
-- swapped order, matching the real API this stubs.
posX, posY = 0, 0
function UnitPosition(u) if u == "player" then return posY, posX, 0, 1 end end

-- Loot stubs, test-controlled via the `lootSlots` array (see reset()).
local lootSlots = {}
function GetNumLootItems() return #lootSlots end
function LootSlotHasItem(i) return lootSlots[i] ~= nil end
function GetLootSourceInfo(i) return lootSlots[i] and lootSlots[i].guid end

-- Zone and level are test-controlled: the zone-entry warning is entirely
-- a function of the pair, so both have to move independently.
zoneName = "Elwynn Forest"
function GetRealZoneText() return zoneName end
function GetSubZoneText() return "Northshire Abbey" end
playerLevel = 20
function UnitLevel(u) if u == "player" then return playerLevel end end
function date() return "2026-08-08 12:00" end

function strsplit(sep, s, limit)
	local out, pos = {}, 1
	while true do
		if limit and #out == limit - 1 then out[#out + 1] = s:sub(pos) break end
		local a, b = s:find(sep, pos, true)
		if not a then out[#out + 1] = s:sub(pos) break end
		out[#out + 1] = s:sub(pos, a - 1)
		pos = b + 1
	end
	return table.unpack(out)
end

local cle = {}
function CombatLogGetCurrentEventInfo() return table.unpack(cle, 1, 8) end

-- Minimal DHTools mock - the same shape DHQuests' and DHBavin's harnesses
-- use, so a change to Core.lua's module contract breaks all three
-- together rather than silently diverging in one.
local moduleEnabled = true
DHTools = {
	modules = {},
	RegisterModule = function(key, def) DHTools.modules[key] = def end,
	IsModuleEnabled = function() return moduleEnabled end,
}

---------------------------------------------------------------------
local passed, failed = 0, 0
local function check(label, got, want)
	if got == want then passed = passed + 1
	else
		failed = failed + 1
		print(string.format("  FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
	end
end

local ns
local function Fire(event, ...) frame.OnEvent(frame, event, ...) end

local function alertCount()
	local n = 0
	for _, m in ipairs(chat) do if m:find("DANGER:", 1, true) then n = n + 1 end end
	return n
end

local function reset()
	now, sounds, chat = 1000, 0, {}
	posX, posY = 0, 0
	zoneName, playerLevel = "Elwynn Forest", 20
	cvars.nameplateShowEnemies = "1"
	moduleEnabled = true
	lootSlots = {}
	guildMember, groupType = true, "raid"
	sentAddonMsgs = {}
	DHToolsDB = nil
	-- 2026-08-08: the manual list moved to the account-wide
	-- DHToolsAccountDB.danger.manualList, and sighting history joined it
	-- at .sightings (Chris - both survive a DH-Tools update and are
	-- separate from the curated data set). Cleared here same as DHToolsDB
	-- so tests don't leak entries into each other - only the persistence
	-- tests deliberately preserve it across a reset, the same pattern
	-- test 21 already uses for DHToolsDB.
	DHToolsAccountDB = nil
	DHTools.modules = {}
	units = {
		player     = { guid = "Player-1-0001", name = "Loopi", player = true },
		nameplate1 = { guid = "Creature-0-0-0-0-448-0001",  name = "Hogger" },
		nameplate2 = { guid = "Creature-0-0-0-0-299-0002",  name = "Kobold Vermin" },
		friendly   = { guid = "Creature-0-0-0-0-197-0003",  name = "Stormwind Guard", friendly = true },
		corpse     = { guid = "Creature-0-0-0-0-448-0004",  name = "Hogger", dead = true },
		mouseover  = nil,
		target     = nil,
	}
	dofile("src/DH-Tools/Modules/DHDanger/Core.lua")
	dofile("src/DH-Tools/Modules/DHDanger/Sync.lua")
	ns = DHTools.Danger
	Fire("PLAYER_LOGIN")
end

print("== DHDanger harness ==")

-- 1. A mob NOT on the list must never alert. This is the whole filter.
reset()
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("unlisted mob is silent", alertCount(), 0)

-- 2. A mob on the list alerts, with sound.
reset()
ns.acctDB.manualList[448] = "Hogger"
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("listed mob alerts", alertCount(), 1)
check("sound played", sounds, 1)

-- 3. Nameplate flicker must not machine-gun the alert. Plates are added
--    and removed constantly as the camera turns. Isolated from the
--    2026-09-10 per-npcID repeatDelay (repeatDelay=0) so this keeps
--    testing only the fixed 20s per-GUID anti-flicker cooldown on its
--    own - see the repeatDelay tests (4b-4d) for the new gate, which at
--    its 120s default would otherwise also suppress this test's
--    25-seconds-later re-alert (same npcID as the first).
reset()
ns.db.repeatDelay = 0
ns.acctDB.manualList[448] = "Hogger"
for i = 1, 10 do Fire("NAME_PLATE_UNIT_ADDED", "nameplate1") end
check("cooldown suppresses repeats", alertCount(), 1)
now = now + 25
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("alerts again after the cooldown", alertCount(), 2)

-- 4. Two DIFFERENT mobs of the same type: with the repeat-alert delay
--    OFF (2026-09-10, Chris - see repeatDelay tests below for the
--    default-ON behavior), the cooldown is per GUID only, so each still
--    gets its own warning - two Hoggers is worse news than one.
reset()
ns.db.repeatDelay = 0
ns.acctDB.manualList[448] = "Hogger"
units.nameplate3 = { guid = "Creature-0-0-0-0-448-0009", name = "Hogger" }
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
Fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
check("repeatDelay=0: per-GUID cooldown only, not per-npcID", alertCount(), 2)

-- 4b. Repeat-alert delay (2026-09-10, Chris - roaming packs of several
--     same-named mobs were re-alerting too close together). Default is
--     120s and applies across DIFFERENT guids sharing the same npcID -
--     the opposite of test 4 above, which is what turning it off (0)
--     is for.
reset()
check("default repeatDelay is 120s", ns.db.repeatDelay, 120)
ns.acctDB.manualList[448] = "Hogger"
units.nameplate3 = { guid = "Creature-0-0-0-0-448-0009", name = "Hogger" }
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("first pack member alerts", alertCount(), 1)
Fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
check("second pack member (same npcID, different guid) suppressed within the default 120s", alertCount(), 1)
now = now + 121
Fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
check("alerts again once the repeat-alert delay elapses", alertCount(), 2)

-- 4c. A DIFFERENT npcID is never held back by another mob's repeatDelay -
--     only same-type repeats are throttled.
reset()
ns.acctDB.manualList[448] = "Hogger"
ns.acctDB.manualList[299] = "Kobold Vermin"
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1") -- Hogger, npc 448
Fire("NAME_PLATE_UNIT_ADDED", "nameplate2") -- Kobold Vermin, npc 299
check("a different mob type alerts independently of another type's repeatDelay", alertCount(), 2)

-- 4d. repeatDelay is configurable and snaps to the console command's own
--     clamp/rounding (Config.lua's slider does the same 30s snapping).
reset()
ns.acctDB.manualList[448] = "Hogger"
units.nameplate3 = { guid = "Creature-0-0-0-0-448-0009", name = "Hogger" }
SlashCmdList["DHDANGER"]("repeatdelay 45") -- 45 is nearer 60 than 30 -> snaps to 60
check("repeatdelay snaps 45 -> 60 (nearest 30s step)", ns.db.repeatDelay, 60)
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
Fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
check("suppressed within the newly configured 60s window", alertCount(), 1)
now = now + 61
Fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
check("alerts again after the configured window", alertCount(), 2)
SlashCmdList["DHDANGER"]("repeatdelay 400") -- clamps to 300 (5 min max)
check("repeatdelay clamps to the 300s (5 min) ceiling", ns.db.repeatDelay, 300)
SlashCmdList["DHDANGER"]("repeatdelay -10") -- clamps to 0 (off)
check("repeatdelay clamps to 0 (off) floor", ns.db.repeatDelay, 0)

-- 5. k-0025: the yell path derives the npcID from arg12's GUID, with no
--    curated "yells" flag anywhere.
reset()
ns.acctDB.manualList[448] = "Hogger"
-- args 3-11 are language/channel/flags/lineID padding; the GUID is arg12.
Fire("CHAT_MSG_MONSTER_YELL", "Rrrrr!", "Hogger", nil, nil, nil, nil, nil, nil, nil, nil, nil, "Creature-0-0-0-0-448-0007")
check("yell alerts", alertCount(), 1)
check("yell labelled as long-range", chat[#chat]:find("(yell)", 1, true) ~= nil, true)

-- 6. k-0022: with nameplates off the proximity path is dead, but yells
--    must still work - they are a chat event, not a nameplate one.
reset()
ns.acctDB.manualList[448] = "Hogger"
cvars.nameplateShowEnemies = "0"
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("no proximity alert without nameplates", alertCount(), 0)
Fire("CHAT_MSG_MONSTER_YELL", "Rrrrr!", "Hogger", nil, nil, nil, nil, nil, nil, nil, nil, nil, "Creature-0-0-0-0-448-0007")
check("yells still work without nameplates", alertCount(), 1)

-- 7. Friendly, dead, and player units are not danger.
reset()
ns.acctDB.manualList[197] = "Stormwind Guard"
ns.acctDB.manualList[448] = "Hogger"
Fire("NAME_PLATE_UNIT_ADDED", "friendly")
Fire("NAME_PLATE_UNIT_ADDED", "corpse")
check("friendly and dead units ignored", alertCount(), 0)

-- 8. A disabled module is silent.
reset()
ns.acctDB.manualList[448] = "Hogger"
moduleEnabled = false
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("disabled module is silent", alertCount(), 0)

-- 9. /dhdanger add reads the current target, and remove undoes it.
reset()
units.target = { guid = "Creature-0-0-0-0-299-0011", name = "Kobold Vermin" }
SlashCmdList["DHDANGER"]("add")
check("add put it on the list", ns.acctDB.manualList[299], "Kobold Vermin")
check("count is 1", ns.Count(), 1)
Fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
check("the added mob now alerts", alertCount(), 1)
SlashCmdList["DHDANGER"]("remove")
check("remove took it off", ns.acctDB.manualList[299], nil)

-- 10. Removing by npcID works without a target - you can clean up a list
--     entry for something that isn't in front of you.
reset()
ns.acctDB.manualList[448] = "Hogger"
units.target = nil
SlashCmdList["DHDANGER"]("remove 448")
check("removed by id", ns.acctDB.manualList[448], nil)

-- 11. add with no target must say so rather than erroring or silently
--     doing nothing.
reset()
units.target = nil
chat = {}
SlashCmdList["DHDANGER"]("add")
check("no-target message", table.concat(chat, "\n"):find("no target", 1, true) ~= nil, true)
check("nothing added", ns.Count(), 0)

-- 12a. Debug mode reports near-zero movement as a clean reading (stood
--      still after the alert) and does NOT nag about closing distance.
reset()
ns.acctDB.manualList[448] = "Hogger"
SlashCmdList["DHDANGER"]("debug on")
chat = {}
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
now = now + 6
cle = { 0, "SWING_DAMAGE", false, units.nameplate1.guid, "Hogger", 0, 0, units.player.guid }
Fire("COMBAT_LOG_EVENT_UNFILTERED")
local report = table.concat(chat, "\n")
check("reports moved 0yd", report:find("moved 0yd", 1, true) ~= nil, true)
check("no closing-distance warning when still", report:find("closing distance", 1, true) == nil, true)

-- 12b. Real movement is reported and flagged as an unclean reading - this
--      is exactly what Chris's own 10s/7s readings needed and didn't have.
reset()
ns.acctDB.manualList[448] = "Hogger"
SlashCmdList["DHDANGER"]("debug on")
chat = {}
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
posX, posY = 30, 40   -- 50 yards travelled (3-4-5 triangle)
now = now + 6
cle = { 0, "SWING_DAMAGE", false, units.nameplate1.guid, "Hogger", 0, 0, units.player.guid }
Fire("COMBAT_LOG_EVENT_UNFILTERED")
report = table.concat(chat, "\n")
check("reports the 50yd walked", report:find("moved 50yd", 1, true) ~= nil, true)
check("flags it as an unclean reading", report:find("closing distance", 1, true) ~= nil, true)

-- 13. Mouseover alerts, and works with NO nameplate ever having appeared -
--     it's a genuinely independent channel, not a nameplate shortcut.
reset()
ns.acctDB.manualList[448] = "Hogger"
units.mouseover = { guid = "Creature-0-0-0-0-448-0010", name = "Hogger" }
Fire("UPDATE_MOUSEOVER_UNIT")
check("mouseover alerts", alertCount(), 1)
check("mouseover labelled correctly", chat[#chat]:find("(mouseover)", 1, true) ~= nil, true)

-- 14. Mouseover works even with nameplates OFF - it doesn't depend on
--     that CVar at all, unlike NAME_PLATE_UNIT_ADDED.
reset()
ns.acctDB.manualList[448] = "Hogger"
cvars.nameplateShowEnemies = "0"
units.mouseover = { guid = "Creature-0-0-0-0-448-0010", name = "Hogger" }
Fire("UPDATE_MOUSEOVER_UNIT")
check("mouseover works without nameplates", alertCount(), 1)

-- 15. Mousing over a corpse or a friendly must not alert - LiveHostileNpc
--     applies the same dead/friendly filter nameplates get, not a looser
--     one just because it's a different event.
reset()
ns.acctDB.manualList[448] = "Hogger"
ns.acctDB.manualList[197] = "Stormwind Guard"
units.mouseover = { guid = "Creature-0-0-0-0-448-0004", name = "Hogger", dead = true }
Fire("UPDATE_MOUSEOVER_UNIT")
check("mousing over a corpse is silent", alertCount(), 0)
units.mouseover = { guid = "Creature-0-0-0-0-197-0003", name = "Stormwind Guard", friendly = true }
Fire("UPDATE_MOUSEOVER_UNIT")
check("mousing over a friendly is silent", alertCount(), 0)

-- 16. Targeting a listed mob alerts (click or Tab, doesn't matter here -
--     the event doesn't distinguish).
reset()
ns.acctDB.manualList[448] = "Hogger"
units.target = { guid = "Creature-0-0-0-0-448-0011", name = "Hogger" }
Fire("PLAYER_TARGET_CHANGED")
check("targeting alerts", alertCount(), 1)
check("target labelled correctly", chat[#chat]:find("(target)", 1, true) ~= nil, true)

-- 17. Monster EMOTE alerts the same way YELL does - same GUID-in-arg12
--     mechanism, different event name.
reset()
ns.acctDB.manualList[448] = "Hogger"
Fire("CHAT_MSG_MONSTER_EMOTE", "growls.", "Hogger", nil, nil, nil, nil, nil, nil, nil, nil, nil, "Creature-0-0-0-0-448-0007")
check("emote alerts", alertCount(), 1)
check("emote labelled correctly", chat[#chat]:find("(emote)", 1, true) ~= nil, true)

-- 18. Looting a DEAD listed mob must NOT print a DANGER banner - the
--     threat is already over - but MUST record a sighting. This is the
--     one deliberate asymmetry: loot is the only trigger that doesn't
--     call ns.Alert().
reset()
ns.acctDB.manualList[448] = "Hogger"
lootSlots = { { guid = "Creature-0-0-0-0-448-0012" } }
Fire("LOOT_OPENED")
check("looting a danger-list kill does not alert", alertCount(), 0)
check("but does record a sighting", ns.acctDB.sightings[448] ~= nil, true)
check("sighting has the right name", ns.acctDB.sightings[448].name, "Hogger")
check("sighting has a zone", ns.acctDB.sightings[448].spots[1].zone, "Elwynn Forest")
-- Loot is the tightest source there is - you are standing on the corpse.
check("loot records the best accuracy", ns.acctDB.sightings[448].spots[1].acc, 5)
check("loot records its source", ns.acctDB.sightings[448].spots[1].src, "loot")

-- 19. Looting something NOT on the list records nothing - the sightings
--     table should only ever hold mobs actually on the danger list.
reset()
lootSlots = { { guid = "Creature-0-0-0-0-9999-0013" } }
Fire("LOOT_OPENED")
local sightingCount = 0
for _ in pairs(ns.acctDB.sightings) do sightingCount = sightingCount + 1 end
check("unlisted loot records nothing", sightingCount, 0)

-- 20. A live alert (any channel) also records a sighting, with position -
--     this is the data a future zone-entry fallback would consume.
reset()
ns.acctDB.manualList[448] = "Hogger"
posX, posY = 12, 34
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("nameplate alert records a sighting", ns.acctDB.sightings[448] ~= nil, true)
-- Positions are snapped to a GRID-yard cell (round to nearest), so 12,34
-- lands in cell 20,40. The raw coordinate is deliberately NOT kept - two
-- players' histories have to merge, and only snapped cells merge cleanly.
check("sighting captured position, snapped to its cell", ns.acctDB.sightings[448].spots[1].x, 20)
check("sighting captured position, y", ns.acctDB.sightings[448].spots[1].y, 40)
check("nameplate accuracy recorded", ns.acctDB.sightings[448].spots[1].acc, 41)

-- 20b. HISTORY, not last-known-position (2026-08-08). The old store held
--      one record per npcID and overwrote it on every detection, so a mob
--      seen in ten places remembered one. Same cell twice must merge into
--      a single spot with a hit count; a different cell must add a spot.
reset()
ns.acctDB.manualList[448] = "Hogger"
posX, posY = 12, 34
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
now = now + 120        -- clear the 20s per-GUID alert cooldown
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("same cell does not add a second spot", #ns.acctDB.sightings[448].spots, 1)
check("same cell increments the hit count", ns.acctDB.sightings[448].spots[1].n, 2)
posX, posY = 500, 500
now = now + 120
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("a genuinely different cell adds a spot", #ns.acctDB.sightings[448].spots, 2)
check("the first spot is still there", ns.acctDB.sightings[448].spots[1].n, 2)

-- 20c. Accuracy is the BEST ever achieved at a cell, not the latest. A
--      yell heard from a spot a nameplate already confirmed must not
--      widen that spot back out to 300 yards.
reset()
ns.acctDB.manualList[448] = "Hogger"
posX, posY = 12, 34
Fire("CHAT_MSG_MONSTER_YELL", "You there!", "Hogger", nil, nil, nil, nil, nil, nil, nil, nil, nil, "Creature-0-0-0-0-448-0007")
check("yell records a 300yd accuracy", ns.acctDB.sightings[448].spots[1].acc, 300)
now = now + 120
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("a tighter source improves the spot", ns.acctDB.sightings[448].spots[1].acc, 41)
check("and takes the source with it", ns.acctDB.sightings[448].spots[1].src, "nameplate")
now = now + 120
Fire("CHAT_MSG_MONSTER_YELL", "You there!", "Hogger", nil, nil, nil, nil, nil, nil, nil, nil, nil, "Creature-0-0-0-0-448-0007")
check("a vaguer source does NOT widen it back out", ns.acctDB.sightings[448].spots[1].acc, 41)

-- 20d. No position (instance/BG - PlayerPos returns nil) must record the
--      observation without inventing a spot: a coordinate-less spot would
--      be indistinguishable from a real one to every future consumer.
reset()
ns.acctDB.manualList[448] = "Hogger"
posX, posY = nil, nil
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("no-position sighting still records the mob", ns.acctDB.sightings[448] ~= nil, true)
check("but creates no spot", #ns.acctDB.sightings[448].spots, 0)
check("and is counted", ns.acctDB.sightings[448].noPos, 1)

-- 20e. Spots per mob are bounded - SavedVariables is rewritten in full on
--      every logout, so an unbounded history is a real performance bug
--      waiting on a long-lived character.
reset()
ns.acctDB.manualList[448] = "Hogger"
for i = 1, 40 do
	posX, posY = i * 100, 0
	now = now + 120
	Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
end
check("spots per mob are capped", #ns.acctDB.sightings[448].spots <= 25, true)

-- 20f. Sightings are account-wide (2026-08-08, Chris): where a mob lives
--      is a fact about the world, identical for every character, and a
--      fresh alt - the character most likely to die to a surprise - used
--      to start with none of it.
reset()
ns.acctDB.manualList[448] = "Hogger"
posX, posY = 12, 34
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
local savedAcctS = DHToolsAccountDB
DHToolsDB = nil                 -- a different character: per-character DB gone
dofile("src/DH-Tools/Modules/DHDanger/Core.lua")
DHToolsAccountDB = savedAcctS
ns = DHTools.Danger
Fire("PLAYER_LOGIN")
check("sightings survive onto another character", ns.acctDB.sightings[448] ~= nil, true)
check("with their spots intact", #ns.acctDB.sightings[448].spots, 1)

-- ---------------------------------------------------------------
-- Zone-entry warning (2026-08-08). The half of DH-Danger that k-0026
-- cannot touch: it never looks at a rendered mob, so camera facing is
-- irrelevant and it works for a solo player with nobody to relay to.
-- ---------------------------------------------------------------
-- Curation.lua writes to the ADDON-wide namespace, which dofile() cannot
-- supply (no varargs), so ns.addonNS is nil in here. A small hand-built
-- fake is better than loading the real 332 rows anyway: the real file is
-- regenerated by a script and its contents would silently rewrite these
-- expectations out from under the tests.
local function fakeCuration()
	ns.addonNS = { Curation = { npcs = {
		[1] = { name = "Nefaru",    zone = "Duskwood", level = 37, type = "rare", roams = true, creatureType = "Humanoid" },
		[2] = { name = "Lupos",     zone = "Duskwood", level = 23, type = "rare" },
		[3] = { name = "Naraxis",   zone = "Duskwood", level = 10, type = "rare" },
		[4] = { name = "Mor'Ladim", zone = "Duskwood", level = -1, type = "rareelite" },
		[5] = { name = "Vultros",   zone = "Westfall", level = 19, type = "rare" },
		[6] = { name = "Nowhere",                      level = 20, type = "rare" },  -- no zone
		[7] = { name = "Skullface", zone = "Tanaris",  level = -1, type = "rare"  },
		-- A border-roamer: one entry, many zones. Mirrors the real
		-- Volchan and Narillasanz rows.
		[8] = { name = "Volchan", zones = { "Redridge Mountains", "Burning Steppes" },
		        level = 60, type = "rareelite" },
	} } }
end
local function zoneWarnings()
	local n = 0
	for _, m in ipairs(chat) do
		if m:find("Curated Threats", 1, true) then n = n + 1 end
	end
	return n
end

-- 20g. Level filtering. Default settings are alertOn="below",
--      belowLevels=3, so at level 20 the floor is 17. Level 10 is out;
--      37 and 23 are in; the level -1 ("??") rare elite is in because
--      alwaysAlertFor.rareelite defaults ON.
reset()
fakeCuration()
local t = ns.ZoneThreats("Duskwood", 20)
check("zone threats filtered by level", #t, 3)
check("worst threat sorts first (?? outranks everything)", t[1].id, 4)
check("then the highest real level", t[2].id, 1)
check("a mob below the floor is excluded", t[3].id, 2)

-- 20h. A mob with no zone is indexed nowhere - it must not leak into
--      some other zone's list. 36 of the real 332 rows have no zone.
reset()
fakeCuration()
check("Westfall is unaffected by Duskwood's entries", #ns.ZoneThreats("Westfall", 20), 1)
check("a zoneless mob appears in no zone", #ns.ZoneThreats("", 20), 0)

-- 20i. level -1 must be BRANCHED on, never compared. Under "at or above
--      my level" at level 60, a compared -1 would drop out; it must not.
reset()
fakeCuration()
ns.db.settings.alertOn = "atOrAbove"
check("?? mobs survive the strictest level rule", #ns.ZoneThreats("Tanaris", 60), 1)
ns.db.settings.alertOn = "any"
check("'any' ignores level entirely", #ns.ZoneThreats("Duskwood", 20), 4)

-- 20j. Category switches actually drive it - this is the first real
--      consumer of the alert-policy settings added earlier the same day.
reset()
fakeCuration()
-- Both switches per category: alwaysAlertFor is checked first, then
-- alertFor. Turning off only the "always" half leaves the ordinary
-- filtered path still enabled - that asymmetry is the whole point of the
-- tri-state, so the test has to close both doors to reach zero. Nefaru
-- (id 1) also carries roams=true (2026-08-19 fix), so it now matches
-- BOTH "rare" and "pack" - pack has to be turned off too or Nefaru alone
-- keeps the count above zero via its independent pack gate.
ns.db.settings.alertFor.rare = false
ns.db.settings.alertFor.rareelite = false
ns.db.settings.alertFor.pack = false
ns.db.settings.alwaysAlertFor.rareelite = false
check("turning every category off removes every mob", #ns.ZoneThreats("Duskwood", 20), 0)
-- Re-arming only the "always" half must bring back ALL three rares -
-- including the level 10 one the level rule would otherwise exclude.
ns.db.settings.alwaysAlertFor.rare = true
check("alwaysAlertFor overrides both the category switch and the level", #ns.ZoneThreats("Duskwood", 20), 3)

-- 20k. Entering a dangerous zone warns once, and does not re-warn until
--      the zone actually changes - ZONE_CHANGED_NEW_AREA fires more often
--      than the zone changes.
reset()
fakeCuration()
zoneName, playerLevel = "Duskwood", 20
Fire("ZONE_CHANGED_NEW_AREA")
check("entering a dangerous zone warns", zoneWarnings(), 1)
Fire("ZONE_CHANGED_NEW_AREA")
check("re-firing in the same zone does not re-warn", zoneWarnings(), 1)
zoneName = "Westfall"
Fire("ZONE_CHANGED_NEW_AREA")
check("a genuinely new zone warns again", zoneWarnings(), 2)

-- 20l. The warning is off-able, and an UNCATALOGUED zone stays SILENT on
--      entry. Saying "nothing here" for a zone nobody has curated would
--      be a k-0022 lie - silence must never read as safe. /dhdanger zone
--      is the verbose path that says so out loud.
reset()
fakeCuration()
zoneName = "Silithus"
Fire("ZONE_CHANGED_NEW_AREA")
check("an uncatalogued zone warns nothing on entry", zoneWarnings(), 0)
ns.ZoneReport("Silithus", 20, true)
check("but asking says it is uncatalogued, not safe",
	chat[#chat]:find("not in the curated set", 1, true) ~= nil, true)

reset()
fakeCuration()
zoneName = "Duskwood"
ns.db.zoneWarn = false
Fire("ZONE_CHANGED_NEW_AREA")
check("zoneWarn off suppresses the warning", zoneWarnings(), 0)

-- 20n. A border-roamer is indexed in EVERY zone it roams, from a single
--      entry carrying `zones`. Before 2026-08-08 such a mob held one
--      comma-joined zone string that GetRealZoneText() could never equal,
--      so it warned in NO zone at all - silently, which is the worst way
--      for a danger warning to fail.
reset()
fakeCuration()
check("border-roamer warns in the first zone", #ns.ZoneThreats("Redridge Mountains", 60), 1)
check("and in the second", #ns.ZoneThreats("Burning Steppes", 60), 1)
check("both are the same mob", ns.ZoneThreats("Burning Steppes", 60)[1].id, 8)

-- 20o. The warning names EVERY curated danger on its own row, highest level first. This
--      is deliberately independent of the character-level filter: zone
--      entry is an orientation warning, not a fight recommendation.
reset()
fakeCuration()
-- This section tests independence from the ALERT-level filter, a
-- different setting from zoneWarnHideGray (default true as of
-- 2026-08-31, which would otherwise strip Naraxis, a gray-level
-- fixture entry, defeating the point of this check) - force it off
-- explicitly so this test keeps covering what it's named for.
ns.db.zoneWarnHideGray = false
zoneName, playerLevel = "Duskwood", 20
Fire("ZONE_CHANGED_NEW_AREA")
local function chatRow(name)
	for i, m in ipairs(chat) do
		if m:find(name, 1, true) then return i, m end
	end
end
local morLadimRow, morLadim = chatRow("Mor'Ladim")
local nefaruRow, nefaru = chatRow("Nefaru")
local luposRow, lupos = chatRow("Lupos")
local naraxisRow, naraxis = chatRow("Naraxis")
check("the warning names every danger", morLadimRow ~= nil and nefaruRow ~= nil
	and luposRow ~= nil and naraxisRow ~= nil, true)
check("each danger gets its own formatted row", nefaru:find("Nefaru", 1, true) ~= nil
	and nefaru:find("37", 1, true) ~= nil
	and nefaru:find("Rare", 1, true) ~= nil
	and nefaru:find("Roaming", 1, true) ~= nil
	and nefaru:find("Humanoid", 1, true) ~= nil, true)
check("optional fields are omitted when absent", lupos:find("Roaming", 1, true) == nil
	and lupos:find("Humanoid", 1, true) == nil, true)
check("the warning ignores the level filter", naraxisRow ~= nil, true)
check("the warning is highest level first", morLadimRow < nefaruRow
	and nefaruRow < luposRow and luposRow < naraxisRow, true)

-- 20p. Curated names beat the player's own manual-list label; the label
--      is only the fallback for mobs the curated set doesn't know.
reset()
fakeCuration()
ns.acctDB.manualList[1] = "whatever I typed"
check("curated name wins", ns.ThreatName(1, ns.addonNS.Curation.npcs[1]), "Nefaru")
check("manual label is the fallback", ns.ThreatName(1, nil), "whatever I typed")
check("npcID is the last resort", ns.ThreatName(999, nil), "npc 999")

-- 20m. No curated data at all (Curation.lua missing from the .toc, k-0002)
--      must degrade quietly, not error.
reset()
check("no curated data yields no threats", #ns.ZoneThreats("Duskwood", 20), 0)
zoneName = "Duskwood"
Fire("ZONE_CHANGED_NEW_AREA")
check("and warns nothing rather than erroring", zoneWarnings(), 0)

-- 21. The list survives a reload - it lives in account-wide SavedVariables
--     (DHToolsAccountDB, 2026-08-08 - see InitDB's migration note), and a
--     test list you have to rebuild every login is not usable.
reset()
ns.acctDB.manualList[448] = "Hogger"
local savedAcct = DHToolsAccountDB
dofile("src/DH-Tools/Modules/DHDanger/Core.lua")
DHToolsAccountDB = savedAcct
ns = DHTools.Danger
Fire("PLAYER_LOGIN")
check("list persisted across reload", ns.acctDB.manualList[448], "Hogger")

-- 22. Alert-policy settings defaults (2026-08-08, Chris's config-page
--     choices). Consumed by both the zone-entry warning and, since
--     2026-08-18, the curated half of ns.IsDangerous (see tests 26-29).
--     This just locks in the agreed defaults so a future change to
--     InitDB can't silently drift from what Chris actually asked for.
reset()
check("default zoneWarn is on", ns.db.zoneWarn, true)
check("default zoneWarnHideGray is on (2026-08-31, Chris)", ns.db.zoneWarnHideGray, true)
check("default alertOn is 'below'", ns.db.settings.alertOn, "below")
check("default belowLevels is 3", ns.db.settings.belowLevels, 3)
for _, cat in ipairs(ns.ALERT_CATEGORIES) do
	check("default alertFor." .. cat.key .. " is on", ns.db.settings.alertFor[cat.key], true)
end
check("default alwaysAlertFor.elite is off", ns.db.settings.alwaysAlertFor.elite, false)
check("default alwaysAlertFor.rare is off", ns.db.settings.alwaysAlertFor.rare, false)
check("default alwaysAlertFor.rareelite is on", ns.db.settings.alwaysAlertFor.rareelite, true)
check("default alwaysAlertFor.guard is on", ns.db.settings.alwaysAlertFor.guard, true)
check("default alwaysAlertFor.pack is off", ns.db.settings.alwaysAlertFor.pack, false)

-- 23. Settings survive a reload same as the test list does - a preference
--     you have to reset every login is not a saved preference.
reset()
ns.db.settings.alertOn = "any"
ns.db.settings.belowLevels = 7
ns.db.settings.alertFor.guard = false
ns.db.settings.alwaysAlertFor.elite = true
local savedSettings = DHToolsDB
dofile("src/DH-Tools/Modules/DHDanger/Core.lua")
DHToolsDB = savedSettings
ns = DHTools.Danger
Fire("PLAYER_LOGIN")
check("alertOn persisted", ns.db.settings.alertOn, "any")
check("belowLevels persisted", ns.db.settings.belowLevels, 7)
check("alertFor edit persisted", ns.db.settings.alertFor.guard, false)
check("alwaysAlertFor edit persisted", ns.db.settings.alwaysAlertFor.elite, true)

-- 24. NO migration (2026-08-08, Chris - explicit reversal of an earlier
--     same-day decision): an old per-character db.testList, however
--     populated, must NOT appear on the new account-wide list. It starts
--     blank once the module is ready for general use; whatever alpha
--     testing produced under the old name stays exactly where it is,
--     untouched and unread.
reset()
DHToolsDB = { danger = { testList = { [448] = "Hogger", [299] = "Kobold Vermin" } } }
DHToolsAccountDB = nil
Fire("PLAYER_LOGIN")
check("old per-char entry NOT migrated (448)", ns.acctDB.manualList[448], nil)
check("old per-char entry NOT migrated (299)", ns.acctDB.manualList[299], nil)
check("old location left untouched, not cleared", DHToolsDB.danger.testList[448], "Hogger")

-- 25. ns.LevelColor - WoW's standard mob-level difficulty color scheme
--     (2026-08-13, Chris), relative to the PLAYER's own level, not the
--     mob's absolute level.
reset()
check("skull (-1) is always red, regardless of player level", ns.LevelColor(-1, 60), "ffff1a1a")
check("+5 is red", ns.LevelColor(25, 20), "ffff1a1a")
check("+10 is still red", ns.LevelColor(30, 20), "ffff1a1a")
check("+4 is orange", ns.LevelColor(24, 20), "ffff8040")
check("+3 is orange", ns.LevelColor(23, 20), "ffff8040")
check("+2 is yellow", ns.LevelColor(22, 20), "ffffff00")
check("+1 is yellow", ns.LevelColor(21, 20), "ffffff00")
check("even is yellow", ns.LevelColor(20, 20), "ffffff00")
check("-1 is yellow", ns.LevelColor(19, 20), "ffffff00")
check("-2 is yellow", ns.LevelColor(18, 20), "ffffff00")
check("-3 is green", ns.LevelColor(17, 20), "ff40bf40")
-- Gray threshold depends on the PLAYER's own level bracket, not the mob's.
check("player 1-9: gray starts 5 below (green at -4)", ns.LevelColor(5, 9), "ff40bf40")
check("player 1-9: gray at -5", ns.LevelColor(4, 9), "ffbfbfbf")
check("player 10-19: green at -5", ns.LevelColor(10, 15), "ff40bf40")
check("player 10-19: gray at -6", ns.LevelColor(9, 15), "ffbfbfbf")
check("player 20-29: green at -6", ns.LevelColor(19, 25), "ff40bf40")
check("player 20-29: gray at -7", ns.LevelColor(18, 25), "ffbfbfbf")
check("player 30-39: green at -7", ns.LevelColor(28, 35), "ff40bf40")
check("player 30-39: gray at -8", ns.LevelColor(27, 35), "ffbfbfbf")
check("player 40-60: green at -8", ns.LevelColor(52, 60), "ff40bf40")
check("player 40-60: gray at -9", ns.LevelColor(51, 60), "ffbfbfbf")
check("player 40-60: still gray far below (-20)", ns.LevelColor(40, 60), "ffbfbfbf")
check("missing mob level falls back to yellow", ns.LevelColor(nil, 20), "ffffff00")
check("missing player level falls back to yellow", ns.LevelColor(20, nil), "ffffff00")

-- 26-29. Curated list feeds live alerts too (2026-08-18, Chris - "all
--        features should be able to incorporate the curated list from
--        now on"), OR'd with the manual list via ns.IsDangerous. The
--        curated fixture below mirrors the actual report: Mor'Ladim,
--        npcID 522, curated level 35, category "elite" - reported as
--        silent on a level 30 character with belowLevels=3 and "elite"
--        checked under normal Alert. ns.addonNS is set directly here
--        (rather than via Curation.lua, which this harness never loads)
--        because Curated() reads it lazily, never cached - see Core.lua.
local function withCuratedMorLadim(catType)
	ns.addonNS = { Curation = { npcs = {
		[522] = { name = "Mor'Ladim", zone = "Duskwood", level = 35, type = catType or "elite" },
	} } }
	units.nameplate1 = { guid = "Creature-0-0-0-0-522-0001", name = "Mor'Ladim" }
end

-- 26. alwaysAlertFor bypasses the level filter entirely, same rule the
--     zone-entry warning already uses.
reset()
ns.db.settings.alwaysAlertFor.rareelite = true
withCuratedMorLadim("rareelite")
playerLevel = 10 -- far below curated level 35; alwaysAlertFor must still fire
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("curated always-alert category fires regardless of level", alertCount(), 1)

-- 27. The reported bug itself: a normal (not "always") alert category
--     still fires once the mob's curated level clears the belowLevels
--     floor - level 35 on a level 30 player with belowLevels=3 (30-3=27,
--     and 35 >= 27).
reset()
ns.db.settings.belowLevels = 3
withCuratedMorLadim("elite")
playerLevel = 30
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("curated mob above the level floor alerts", alertCount(), 1)

-- 28. Same mob, but curated well below the floor - must stay silent.
reset()
ns.db.settings.belowLevels = 3
withCuratedMorLadim("elite")
ns.addonNS.Curation.npcs[522].level = 20
playerLevel = 30
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("curated mob below the level floor stays silent", alertCount(), 0)

-- 29. Category unchecked under normal Alert - silent even though the
--     level would otherwise pass.
reset()
ns.db.settings.alertFor.elite = false
withCuratedMorLadim("elite")
playerLevel = 30
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("curated mob silent when its category is unchecked", alertCount(), 0)

-- 30-34. The 2026-08-19 report: a roaming type="normal" mob (Forsaken
--        Courier/Bodyguard, npc 2714/2721, curated level 35, roams=true)
--        had no matching ALERT_CATEGORIES key at all and could never
--        warn, "Roaming Packs" checkbox or not. Fixed via
--        ns.CategoriesFor returning a list so `pack` (from `roams`) and
--        the type-derived category are independent, OR'd gates.
local function withCuratedForsaken(opts)
	opts = opts or {}
	ns.addonNS = { Curation = { npcs = {
		[2714] = { name = "Forsaken Courier", zone = "Arathi Highlands",
			level = opts.level or 35, type = opts.type or "normal", roams = true },
	} } }
	units.nameplate1 = { guid = "Creature-0-0-0-0-2714-0001", name = "Forsaken Courier" }
end

-- 30. Roaming normal mob alerts once "Roaming Packs" is checked (default
--     on) and the level floor passes (35 >= 30-3) - the reported bug,
--     fixed. Same level setup as test 27.
reset()
ns.db.settings.belowLevels = 3
withCuratedForsaken()
playerLevel = 30
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("roaming normal mob alerts when Roaming Packs is on", alertCount(), 1)

-- 31. Same mob, "Roaming Packs" unchecked - silent, same idiom as any
--     other category (test 29).
reset()
ns.db.settings.alertFor.pack = false
ns.db.settings.belowLevels = 3
withCuratedForsaken()
playerLevel = 30
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("roaming normal mob silent when Roaming Packs is off", alertCount(), 0)

-- 32. "Roaming Packs" checked, but the level filter still applies (Chris,
--     2026-08-19) - a roams=true mob curated well below the floor stays
--     silent, same as test 28's non-roaming case.
reset()
ns.db.settings.belowLevels = 3
withCuratedForsaken({ level = 10 }) -- below 30-3=27
playerLevel = 30
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("roaming mob still respects the level filter", alertCount(), 0)

-- 33. A mob can match TWO categories at once (elite AND pack). Its type
--     category is unchecked, but Roaming Packs is checked - must still
--     alert, proving the two gates are independent ORs, not one
--     replacing the other.
reset()
ns.db.settings.alertFor.elite = false
ns.db.settings.belowLevels = 3
withCuratedForsaken({ type = "elite" })
playerLevel = 30
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("pack category alerts independently even with elite unchecked", alertCount(), 1)

-- 34. alwaysAlertFor.pack bypasses the level filter for a roaming mob,
--     same rule test 26 already proves for other categories.
reset()
ns.db.settings.alwaysAlertFor.pack = true
withCuratedForsaken({ level = 10 }) -- below any reasonable floor at playerLevel 30
playerLevel = 30
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("always-alert Roaming Packs bypasses the level filter", alertCount(), 1)

---------------------------------------------------------------------
-- Peer-relay broadcast (k-0026/k-0030, Sync.lua)
---------------------------------------------------------------------

-- 35. ParseSightMessage: a well-formed payload decodes every field.
reset()
do
	local npcID, guid, cx, cy, zone, source =
		ns.ParseSightMessage("448|Creature-0-0-0-0-448-9999|20|-40|Elwynn Forest|nameplate")
	check("parse npcID", npcID, 448)
	check("parse guid", guid, "Creature-0-0-0-0-448-9999")
	check("parse cellX", cx, 20)
	check("parse cellY", cy, -40)
	check("parse zone", zone, "Elwynn Forest")
	check("parse source", source, "nameplate")
end

-- 36. ParseSightMessage: a missing field (no zone/source here) must fail
--     closed, not partially decode.
reset()
check("parse rejects a short payload", ns.ParseSightMessage("448|Creature-0-0-0-0-448-9999|20|-40"), nil)

-- 37. ShouldRelayAlert: same zone, in range, on the danger list -> fires.
reset()
ns.acctDB.manualList[448] = "Hogger"
check("relay decision: in zone and in range", ns.ShouldRelayAlert(448, 0, 0, "Elwynn Forest", "nameplate", "Elwynn Forest", 10, 10), true)

-- 38. ShouldRelayAlert: different zone -> coordinates aren't comparable,
--     must refuse regardless of distance.
reset()
ns.acctDB.manualList[448] = "Hogger"
check("relay decision: zone mismatch refuses", ns.ShouldRelayAlert(448, 0, 0, "Duskwood", "nameplate", "Elwynn Forest", 0, 0), false)

-- 39. ShouldRelayAlert: same zone but far outside the source's own
--     accuracy radius -> refuses.
reset()
ns.acctDB.manualList[448] = "Hogger"
check("relay decision: out of range refuses", ns.ShouldRelayAlert(448, 0, 0, "Elwynn Forest", "nameplate", "Elwynn Forest", 500, 500), false)

-- 40. ShouldRelayAlert: an npcID the receiver doesn't consider dangerous
--     (not on their manual list, no curated data loaded) -> refuses,
--     proving a relay never bypasses the RECEIVER's own settings.
reset()
check("relay decision: not dangerous to receiver refuses", ns.ShouldRelayAlert(999, 0, 0, "Elwynn Forest", "nameplate", "Elwynn Forest", 0, 0), false)

-- 41. A direct nameplate alert broadcasts to both GUILD and RAID (reset()
--     defaults to in-guild + in-raid) with the DHDangerV1 prefix.
reset()
ns.acctDB.manualList[448] = "Hogger"
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("nameplate alert broadcasts to 2 channels", #sentAddonMsgs, 2)
check("broadcast uses DHDangerV1 prefix", sentAddonMsgs[1] and sentAddonMsgs[1].prefix, "DHDangerV1")
check("broadcast is a SIGHT message", sentAddonMsgs[1] and sentAddonMsgs[1].text:match("^SIGHT|") ~= nil, true)

-- 42. A yell alert does NOT broadcast - not camera-gated by k-0026, so
--     relaying it adds nothing (see Core.lua's ns.Alert broadcast guard).
reset()
ns.acctDB.manualList[448] = "Hogger"
Fire("CHAT_MSG_MONSTER_YELL", "Rrrrr!", "Hogger", nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, "Creature-0-0-0-0-448-0005")
check("yell alert does not broadcast", #sentAddonMsgs, 0)

-- 43. shareSync off stops sending, even though the alert itself still
--     fires locally.
reset()
ns.acctDB.manualList[448] = "Hogger"
ns.db.shareSync = false
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("alert still fires locally with sharing off", alertCount(), 1)
check("nothing broadcasts with sharing off", #sentAddonMsgs, 0)

-- 44. Not in a guild or group -> nobody to tell, nothing sent.
reset()
ns.acctDB.manualList[448] = "Hogger"
guildMember, groupType = false, nil
Fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
check("nothing broadcasts with nobody around", #sentAddonMsgs, 0)

-- 45. End-to-end: a valid SIGHT from someone else, same zone and in
--     range, fires a local alert labeled "relayed" - never confused with
--     something this client actually saw itself.
reset()
ns.acctDB.manualList[448] = "Hogger"
posX, posY = 0, 0
Fire("CHAT_MSG_ADDON", "DHDangerV1", "SIGHT|448|Creature-0-0-0-0-448-9999|0|0|Elwynn Forest|nameplate", "GUILD", "Someone")
check("relayed sighting alerts", alertCount(), 1)
check("relayed alert is labeled relayed", chat[#chat]:find("(relayed)", 1, true) ~= nil, true)

-- 46. End-to-end: reported zone differs from the receiver's own -> no
--     alert, coordinates from another zone are meaningless here.
reset()
ns.acctDB.manualList[448] = "Hogger"
zoneName = "Duskwood"
posX, posY = 0, 0
Fire("CHAT_MSG_ADDON", "DHDangerV1", "SIGHT|448|Creature-0-0-0-0-448-9999|0|0|Elwynn Forest|nameplate", "GUILD", "Someone")
check("cross-zone sighting does not alert", alertCount(), 0)

-- 47. End-to-end: same zone, but the receiver is far from the reported
--     cell -> no alert.
reset()
ns.acctDB.manualList[448] = "Hogger"
posX, posY = 2000, 2000
Fire("CHAT_MSG_ADDON", "DHDangerV1", "SIGHT|448|Creature-0-0-0-0-448-9999|0|0|Elwynn Forest|nameplate", "GUILD", "Someone")
check("out-of-range sighting does not alert", alertCount(), 0)

-- 48. End-to-end: our own broadcast echoing back (sender == our own
--     name) must never re-trigger an alert.
reset()
ns.acctDB.manualList[448] = "Hogger"
posX, posY = 0, 0
Fire("CHAT_MSG_ADDON", "DHDangerV1", "SIGHT|448|Creature-0-0-0-0-448-9999|0|0|Elwynn Forest|nameplate", "GUILD", "Loopi")
check("self-echo does not alert", alertCount(), 0)

-- 49. End-to-end: a message on any other prefix is not DH-Danger's
--     traffic at all and must be ignored outright.
reset()
ns.acctDB.manualList[448] = "Hogger"
posX, posY = 0, 0
Fire("CHAT_MSG_ADDON", "SomeOtherAddon", "SIGHT|448|Creature-0-0-0-0-448-9999|0|0|Elwynn Forest|nameplate", "GUILD", "Someone")
check("wrong prefix is ignored", alertCount(), 0)

-- 50. Receiving is independent of the shareSync (send) toggle - turning
--     off your own broadcasts must not also deafen you to others'.
reset()
ns.acctDB.manualList[448] = "Hogger"
ns.db.shareSync = false
posX, posY = 0, 0
Fire("CHAT_MSG_ADDON", "DHDangerV1", "SIGHT|448|Creature-0-0-0-0-448-9999|0|0|Elwynn Forest|nameplate", "GUILD", "Someone")
check("receiving still works with sharing off", alertCount(), 1)

---------------------------------------------------------------------
-- 51-53. Curated-row exclusion (include=false, 2026-09-11, Chris -
--        "excluded rows") and the zone-entry header's total-vs-shown
--        split. A dedicated fixture (Redwater Shore, npcIDs 901-904) so
--        these don't disturb any of fakeCuration()'s existing Duskwood-
--        based category/level assertions above.
---------------------------------------------------------------------
local function fakeExcludeCuration()
	ns.addonNS = { Curation = { npcs = {
		-- Same type/level as 902 on purpose: proves exclusion is what
		-- differs, not some other field.
		[901] = { name = "Testmob Rare",     zone = "Redwater Shore", level = 20, type = "rare" },
		[902] = { name = "Testmob Excluded", zone = "Redwater Shore", level = 20, type = "rare", include = false },
		-- Green/gray at player level 20 (GrayBelow(20) = 7): diff -6 is
		-- green, diff -10 is gray - see Core.lua's ns.LevelColor.
		[903] = { name = "Testmob Green", zone = "Redwater Shore", level = 14, type = "rare" },
		[904] = { name = "Testmob Gray",  zone = "Redwater Shore", level = 10, type = "rare" },
	} } }
end

reset()
fakeExcludeCuration()
local excludedEntry = ns.addonNS.Curation.npcs[902]
check("CategoriesFor returns no categories for an excluded row", #ns.CategoriesFor(excludedEntry), 0)
check("EntryWarns is false for an excluded row even though type/level would otherwise qualify",
	ns.EntryWarns(excludedEntry, 20, true), false)
check("an excluded row never appears in ZoneThreats", (function()
	for _, t in ipairs(ns.ZoneThreats("Redwater Shore", 20, true)) do
		if t.id == 902 then return true end
	end
	return false
end)(), false)
check("IsDangerous is false for an excluded npcID with no manual-list entry", ns.IsDangerous(902), false)
ns.acctDB.manualList[902] = "hand-added anyway"
check("a manual /dhdanger add still overrides curation exclusion (independent sources, unchanged design)",
	ns.IsDangerous(902), true)

-- 52. The zone-entry header's total is every npcID ZoneIndex assigned to
--     the zone - unaffected by include=false OR either hide-color option.
--     "Shown" is whatever actually survives every filter. Redwater Shore
--     has 4 indexed entries (901-904) in every scenario below.
reset()
fakeExcludeCuration()
ns.ZoneReport("Redwater Shore", 20, false, false, false)
check("header total is all 4 indexed entries, hideGray/hideGreen both off",
	chat[1]:find("4 Curated Threats, 3 Shown", 1, true) ~= nil, true)
-- 3 shown: 901 (yellow), 903 (green, visible), 904 (gray, visible) -
-- 902 never counts, exclusion isn't a color and isn't touched by either
-- checkbox.

reset()
fakeExcludeCuration()
ns.ZoneReport("Redwater Shore", 20, false, true, false)
check("hideGray alone drops only the gray one - total still 4",
	chat[1]:find("4 Curated Threats, 2 Shown", 1, true) ~= nil, true)

reset()
fakeExcludeCuration()
ns.ZoneReport("Redwater Shore", 20, false, false, true)
check("hideGreen alone drops only the green one - total still 4",
	chat[1]:find("4 Curated Threats, 2 Shown", 1, true) ~= nil, true)

reset()
fakeExcludeCuration()
ns.ZoneReport("Redwater Shore", 20, false, true, true)
check("both hide flags together drop gray AND green - total still 4",
	chat[1]:find("4 Curated Threats, 1 Shown", 1, true) ~= nil, true)

-- 53. Defaults locked in (2026-09-11, Chris): Hide Gray still defaults
--     ON (2026-08-31, unchanged); the new Hide Green defaults OFF.
reset()
check("default zoneWarnHideGray is still on", ns.db.zoneWarnHideGray, true)
check("default zoneWarnHideGreen is off", ns.db.zoneWarnHideGreen, false)

---------------------------------------------------------------------
print(string.format("== %d passed, %d failed ==", passed, failed))
os.exit(failed == 0 and 0 or 1)
