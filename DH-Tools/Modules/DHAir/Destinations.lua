-- DH-Air Destinations.lua
-- Static reference data only - no logic. DHAir.DEFAULT_DESTINATIONS seeds
-- db.destinations the first time it's empty (see Core.lua). Officers can
-- add/remove/rename entries afterward through the destinations editor
-- (DH-Air-Destinations-Design.md) - this file is just the starting point,
-- not an enforced or exhaustive list.
--
-- category = "flightpoint" | "summonstone"
-- continent = "Eastern Kingdoms" | "Kalimdor" (flightpoint entries only,
-- 2026-08-03 addition - see below) - summonstone entries have no
-- continent field; the destination pickers (DH-Air Board.lua, DH-Tools
-- Minimap.lua) only split Dungeon Stones by category, not further.
--
-- SOURCING NOTE: the flightpoint entries were cross-checked against a
-- current (2026) Classic Era Alliance flight-point table sourced from
-- gamingcy.com's WoW Classic Flight Paths guide, plus vanilla-wow-archive's
-- Flight_path wiki page for general mechanics confirmation - see the chat
-- response that introduced this file for the source links. Darnassus
-- itself (as opposed to the Rut'theran Village landing below it) was added
-- from general knowledge, not the cited table - worth a quick in-game
-- confirmation. The summonstone entries were NOT freshly source-checked
-- the same way; they're compiled from general Classic Era dungeon
-- knowledge and should get an in-game/wiki sanity pass (particularly which
-- Scarlet Monastery wings have distinct stones, and whether every
-- Horde-territory instance listed is actually reachable/summonable) before
-- being trusted as complete. Loopi/officers can freely correct any of this
-- through the editor once it exists - nothing here is authoritative.
--
-- 2026-08-03: Loopi asked to drop The Stockade (correctly excluded already
-- - it's inside Stormwind with no external meeting stone, matching the
-- header note above) and collapse Scarlet Monastery's four wings into one
-- entry, since a Warlock summons to one spot outside regardless of which
-- wing someone's headed into. Now 33 flightpoint + 19 summonstone entries.
--
-- 2026-08-03 (later same day): added `continent` to every flightpoint
-- entry (Eastern Kingdoms / Kalimdor) so the destination pickers can group
-- Flight Points by continent - Loopi asked for this after finding the flat
-- 33+19-entry list too long to scan in one column. Moonglade (a neutral
-- sanctuary, reachable from both continents) is tagged Kalimdor simply
-- because that's the block it was already listed under here - not a
-- geography claim.
--
-- 2026-08-03 (later still): Loopi reversed course on The Stockade - back
-- in, but DISABLED by default (enabled = false), along with Ragefire
-- Chasm and The Deadmines (same treatment, all three easily reached
-- without a summon). `enabled` on a DEFAULT_DESTINATIONS entry now means
-- something - previously every entry here seeded as enabled regardless
-- of any `enabled` field, since Core.lua's seed loop hardcoded
-- `enabled = true`; that loop now respects `d.enabled` (defaulting true
-- when absent), and a one-time Core.lua migration retrofits the same
-- three onto any client whose destinations list had already seeded
-- before this change. Now 33 flightpoint + 20 summonstone entries.

local ADDON_NAME, DHAir = ...

DHAir.DEFAULT_DESTINATIONS = {
    -- Eastern Kingdoms flight points
    { id = "stormwind",       label = "Stormwind City (Elwynn Forest)",         category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "ironforge",       label = "Ironforge (Dun Morogh)",                 category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "darkshire",       label = "Darkshire (Duskwood)",                   category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "sentinelhill",    label = "Sentinel Hill (Westfall)",               category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "lakeshire",       label = "Lakeshire (Redridge Mountains)",         category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "thelsamar",       label = "Thelsamar (Loch Modan)",                 category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "menethilharbor",  label = "Menethil Harbor (Wetlands)",             category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "southshore",      label = "Southshore (Hillsbrad Foothills)",       category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "refugepoint",     label = "Refuge Point (Arathi Highlands)",        category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "aeriepeak",       label = "Aerie Peak (Hinterlands)",               category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "chillwindcamp",   label = "Chillwind Camp (Western Plaguelands)",   category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "lightshopechapel",label = "Light's Hope Chapel (Eastern Plaguelands)", category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "morgansvigil",    label = "Morgan's Vigil (Burning Steppes)",       category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "nethergardekeep", label = "Nethergarde Keep (Blasted Lands)",       category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "thoriumpoint",    label = "Thorium Point (Searing Gorge)",          category = "flightpoint", continent = "Eastern Kingdoms" },
    { id = "bootybay",        label = "Booty Bay (Stranglethorn Vale)",         category = "flightpoint", continent = "Eastern Kingdoms" },
}

for _, d in ipairs({
    -- Kalimdor flight points
    { id = "darnassus",       label = "Darnassus (Teldrassil)",                 category = "flightpoint", continent = "Kalimdor" },
    { id = "ruttheranvillage",label = "Rut'theran Village (Teldrassil)",        category = "flightpoint", continent = "Kalimdor" },
    { id = "astranaar",       label = "Astranaar (Ashenvale)",                  category = "flightpoint", continent = "Kalimdor" },
    { id = "talrendispoint",  label = "Talrendis Point (Azshara)",              category = "flightpoint", continent = "Kalimdor" },
    { id = "auberdine",       label = "Auberdine (Darkshore)",                  category = "flightpoint", continent = "Kalimdor" },
    { id = "nijelspoint",     label = "Nijel's Point (Desolace)",               category = "flightpoint", continent = "Kalimdor" },
    { id = "theramore",       label = "Theramore Isle (Dustwallow Marsh)",      category = "flightpoint", continent = "Kalimdor" },
    { id = "talonbranchglade",label = "Talonbranch Glade (Felwood)",            category = "flightpoint", continent = "Kalimdor" },
    { id = "feathermoon",     label = "Feathermoon Stronghold (Feralas)",       category = "flightpoint", continent = "Kalimdor" },
    { id = "thalanaar",       label = "Thalanaar (Feralas)",                    category = "flightpoint", continent = "Kalimdor" },
    { id = "moonglade",       label = "Moonglade",                             category = "flightpoint", continent = "Kalimdor" },
    { id = "cenarionhold",    label = "Cenarion Hold (Silithus)",               category = "flightpoint", continent = "Kalimdor" },
    { id = "stonetalonpeak",  label = "Stonetalon Peak (Stonetalon Mountains)", category = "flightpoint", continent = "Kalimdor" },
    { id = "gadgetzan",       label = "Gadgetzan (Tanaris)",                    category = "flightpoint", continent = "Kalimdor" },
    { id = "everlook",        label = "Everlook (Winterspring)",                category = "flightpoint", continent = "Kalimdor" },
    { id = "ratchet",         label = "Ratchet (The Barrens)",                  category = "flightpoint", continent = "Kalimdor" },
    { id = "marshalsrefuge",  label = "Marshal's Refuge (Un'Goro Crater)",      category = "flightpoint", continent = "Kalimdor" },
}) do
    table.insert(DHAir.DEFAULT_DESTINATIONS, d)
end

for _, d in ipairs({
    -- Dungeon summoning stones (levelling dungeons, 1-60; raid entrances
    -- excluded). See file header note: compiled from general knowledge,
    -- not freshly source-verified like the flight points above.
    -- 2026-08-03 (later same day): The Stockade is back, per Loopi - it
    -- WAS correctly dropped earlier the same day for having no external
    -- meeting stone (it's a jail inside Stormwind City itself, entered
    -- through a normal door), but Loopi wants it kept as a selectable
    -- option anyway, just not offered by default. Ragefire Chasm and The
    -- Deadmines get the same disabled-by-default treatment (both are also
    -- inside/at the edge of a capital-adjacent zone most groups can reach
    -- without a summon) - `enabled = false` here, respected by both
    -- Core.lua's seed loop (fresh installs) and its one-time migration
    -- (installs whose destinations list was already seeded before this
    -- change).
    { id = "thestockade",     label = "The Stockade (Stormwind City)",         category = "summonstone", enabled = false },
    { id = "ragefirechasm",   label = "Ragefire Chasm (Orgrimmar)",             category = "summonstone", enabled = false },
    { id = "deadmines",       label = "The Deadmines (Westfall)",               category = "summonstone", enabled = false },
    { id = "wailingcaverns",  label = "Wailing Caverns (The Barrens)",          category = "summonstone" },
    { id = "shadowfangkeep",  label = "Shadowfang Keep (Silverpine Forest)",    category = "summonstone" },
    { id = "blackfathomdeeps",label = "Blackfathom Deeps (Darkshore)",          category = "summonstone" },
    { id = "gnomeregan",      label = "Gnomeregan (Dun Morogh)",                category = "summonstone" },
    { id = "razorfenkraul",   label = "Razorfen Kraul (The Barrens)",           category = "summonstone" },
    { id = "scarletmonastery",label = "Scarlet Monastery (Tirisfal Glades)",    category = "summonstone" },
    { id = "razorfendowns",   label = "Razorfen Downs (The Barrens)",           category = "summonstone" },
    { id = "uldaman",         label = "Uldaman (Badlands)",                     category = "summonstone" },
    { id = "zulfarrak",       label = "Zul'Farrak (Tanaris)",                   category = "summonstone" },
    { id = "maraudon",        label = "Maraudon (Desolace)",                    category = "summonstone" },
    { id = "sunkentemple",    label = "Temple of Atal'Hakkar (Swamp of Sorrows)", category = "summonstone" },
    { id = "blackrockdepths", label = "Blackrock Depths (Searing Gorge)",       category = "summonstone" },
    { id = "lowerblackrockspire", label = "Lower Blackrock Spire (Burning Steppes)", category = "summonstone" },
    { id = "upperblackrockspire", label = "Upper Blackrock Spire (Burning Steppes)", category = "summonstone" },
    { id = "diremaul",        label = "Dire Maul (Feralas)",                    category = "summonstone" },
    { id = "scholomance",     label = "Scholomance (Western Plaguelands)",      category = "summonstone" },
    { id = "stratholme",      label = "Stratholme (Eastern Plaguelands)",       category = "summonstone" },
}) do
    table.insert(DHAir.DEFAULT_DESTINATIONS, d)
end
