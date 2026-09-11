-- DH-Danger :: Curation.lua
-- GENERATED FILE - DO NOT HAND-EDIT.
-- Source: claude\DH-Danger\curation\DH-Danger-Curation.csv
-- Regenerate: powershell -ExecutionPolicy Bypass -File claude\DH-Danger\import-curation.ps1
-- Generated: 2026-09-10 22:04
--
-- HUMAN JUDGEMENT ONLY. Facts live in DangerData.lua, which is
-- regenerated from the import files and the in-game dump. Keeping
-- them apart means re-importing source data cannot destroy curation,
-- and re-curating cannot corrupt facts. Runtime merges this OVER
-- DangerData.
--
-- Absent field = not yet judged. That is NOT the same as false:
-- yells=false means 'confirmed silent, nameplate range is the
-- ceiling'; absent means nobody has checked. Never collapse the two.

local _, ns = ...

ns.Curation = ns.Curation or {}
ns.Curation.generated = "2026-09-10 22:04"

-- [npcID or name] = { name, zone|zones, level, type, creatureType, surprise,
--             severity, yells, stealth, roams, soloable, include, why }
-- Key is the npcID (number) once known, or the mob's name (string) for
-- rows awaiting one (2026-08-16) - iterate with pairs(), never assume the
-- key is numeric. A name-keyed entry can drive the zone-entry warning
-- (zone-text match only) but NOT the live-alert GUID match, since a GUID
-- resolves to an npcID, never to a name - see Core.lua's NpcID().
-- zone is a plain string; a mob that roams across a border carries
-- zones (an array) instead, merged from one CSV row per zone -
-- consumers must read e.zones or {e.zone}, never e.zone alone.
-- type mirrors UnitClassification(): normal|elite|rare|rareelite.
-- include=false means EXCLUDED (2026-09-11, Chris): Core.lua's
-- ns.CategoriesFor returns no categories at all for the entry, so it
-- never live-alerts and never appears in a zone-entry report - a soft
-- delete that keeps the row's data intact. include=true or absent
-- behaves exactly as it did before this flag was wired up.
-- creatureType mostly mirrors UnitCreatureType() (e.g. Humanoid); absent
-- means unknown. Hydra/Silithid/Slime are a deliberate exception (Loopi,
-- 2026-08-13) - the live API lumps them under Beast/uncategorized, which
-- tells a player nothing, so these three carry their own label instead.
-- level is an integer, or -1 for '??'/skull mobs - see DangerList.lua's
-- schema comment on why -1 must be branched on, never compared.
ns.Curation.npcs = {
	[61]={name="Thuros Lightfingers",zone="Elwynn Forest",level=11,type="rare",creatureType="Humanoid"},  -- Thuros Lightfingers
	[79]={name="Narg the Taskmaster",zone="Elwynn Forest",level=10,type="rare",creatureType="Humanoid"},  -- Narg the Taskmaster
	[99]={name="Morgaine the Sly",zone="Elwynn Forest",level=10,type="rare",creatureType="Humanoid"},  -- Morgaine the Sly
	[100]={name="Gruff Swiftbite",zone="Elwynn Forest",level=12,type="rare",creatureType="Humanoid"},  -- Gruff Swiftbite
	[193]={name="Blue Dragonspawn",zone="Azshara",level=51,type="elite",creatureType="Dragonkin"},  -- Blue Dragonspawn
	[314]={name="Eliza",zone="Duskwood",level=31,type="elite",creatureType="Undead"},  -- Eliza
	[334]={name="Gath'Ilzogg",zone="Redridge Mountains",level=26,type="elite",creatureType="Humanoid"},  -- Gath'Ilzogg
	[335]={name="Singe",zone="Redridge Mountains",level=24,type="elite",creatureType="Dragonkin"},  -- Singe
	[397]={name="Morganth",zone="Redridge Mountains",level=27,type="elite",creatureType="Humanoid"},  -- Morganth
	[412]={name="Stitches",zone="Duskwood",level=35,type="elite",creatureType="Undead",roams=true},  -- Stitches
	[436]={name="Blackrock Shadowcaster",zone="Redridge Mountains",level=23,type="elite",creatureType="Humanoid"},  -- Blackrock Shadowcaster
	[448]={name="Hogger",zone="Elwynn Forest",level=11,type="elite",creatureType="Humanoid"},  -- Hogger
	[462]={name="Vultros",zone="Westfall",level=26,type="rare",creatureType="Beast"},  -- Vultros
	[471]={name="Mother Fang",zone="Elwynn Forest",level=10,type="rare",creatureType="Beast"},  -- Mother Fang
	[472]={name="Fedfennel",zone="Elwynn Forest",level=12,type="rare",creatureType="Humanoid"},  -- Fedfennel
	[486]={name="Tharil'zun",zone="Redridge Mountains",level=24,type="elite",creatureType="Humanoid"},  -- Tharil'zun
	[503]={name="Lord Malathrom",zone="Duskwood",level=31,type="rare",creatureType="Undead"},  -- Lord Malathrom
	[506]={name="Sergeant Brashclaw",zone="Westfall",level=18,type="rare",creatureType="Humanoid"},  -- Sergeant Brashclaw
	[507]={name="Fenros",zone="Duskwood",level=32,type="rare",creatureType="Humanoid"},  -- Fenros
	[519]={name="Slark",zone="Westfall",level=15,type="rare",creatureType="Humanoid"},  -- Slark
	[520]={name="Brack",zone="Westfall",level=19,type="rare",creatureType="Humanoid"},  -- Brack
	[521]={name="Lupos",zone="Duskwood",level=23,type="rare",creatureType="Beast"},  -- Lupos
	[522]={name="Mor'Ladim",zone="Duskwood",level=35,type="elite",creatureType="Undead",roams=true},  -- Mor'Ladim
	[534]={name="Nefaru",zone="Duskwood",level=37,type="rare",creatureType="Humanoid"},  -- Nefaru
	[572]={name="Leprithus",zone="Westfall",level=19,type="rare",creatureType="Undead"},  -- Leprithus
	[573]={name="Foe Reaper 4000",zone="Westfall",level=20,type="rare",creatureType="Mechanical"},  -- Foe Reaper 4000
	[574]={name="Naraxis",zone="Duskwood",level=27,type="rare",creatureType="Beast"},  -- Naraxis
	[584]={name="Kazon",zone="Redridge Mountains",level=27,type="rare",creatureType="Humanoid"},  -- Kazon
	[594]={name="Defias Henchman",zone="Westfall",level=16,type="elite",creatureType="Humanoid"},  -- Defias Henchman
	[596]={name="Brainwashed Noble",zone="Westfall",level=18,type="rareelite",creatureType="Humanoid"},  -- Brainwashed Noble
	[599]={name="Marisa du'Paige",zone="Westfall",level=18,type="rareelite",creatureType="Humanoid"},  -- Marisa du'Paige
	[603]={name="Grimtooth",zone="Alterac Valley",level=59,type="rare",creatureType="Humanoid"},  -- Grimtooth
	[616]={name="Chatter",zone="Redridge Mountains",level=23,type="rare",creatureType="Beast"},  -- Chatter
	[619]={name="Defias Conjurer",zone="Westfall",level=16,type="elite",creatureType="Humanoid"},  -- Defias Conjurer
	[639]={name="Edwin VanCleef",zone="The Deadmines",level=21,type="rareelite",creatureType="Humanoid"},  -- Edwin VanCleef
	[679]={name="Mosh'Ogg Shaman",zone="Stranglethorn Vale",level=44,type="elite",creatureType="Humanoid"},  -- Mosh'Ogg Shaman
	[680]={name="Mosh'Ogg Lord",zone="Stranglethorn Vale",level=45,type="elite",creatureType="Humanoid"},  -- Mosh'Ogg Lord
	[709]={name="Mosh'Ogg Warmonger",zone="Stranglethorn Vale",level=42,type="elite",creatureType="Humanoid"},  -- Mosh'Ogg Warmonger
	[723]={name="Mosh'Ogg Butcher",zone="Stranglethorn Vale",level=44,type="rareelite",creatureType="Humanoid"},  -- Mosh'Ogg Butcher
	[728]={name="Bhag'thera",zone="Stranglethorn Vale",level=40,type="elite",creatureType="Beast"},  -- Bhag'thera
	[730]={name="Tethis",zone="Stranglethorn Vale",level=43,type="elite",creatureType="Beast"},  -- Tethis
	[731]={name="King Bangalash",zone="Stranglethorn Vale",level=43,type="elite",creatureType="Beast"},  -- King Bangalash
	[763]={name="Lost One Chieftain",zone="Swamp of Sorrows",level=39,type="rare",creatureType="Humanoid"},  -- Lost One Chieftain
	[771]={name="Commander Felstrom",zone="Duskwood",level=32,type="rare",creatureType="Undead"},  -- Commander Felstrom
	[813]={name="Colonel Kurzen",zone="Stranglethorn Vale",level=40,type="elite",creatureType="Humanoid"},  -- Colonel Kurzen
	[818]={name="Mai'Zoth",zone="Stranglethorn Vale",level=47,type="elite",creatureType="Humanoid"},  -- Mai'Zoth
	[873]={name="Saltscale Oracle",zone="Stranglethorn Vale",level=37,type="elite",creatureType="Humanoid"},  -- Saltscale Oracle
	[875]={name="Saltscale Tide Lord",zone="Stranglethorn Vale",level=37,type="elite",creatureType="Humanoid"},  -- Saltscale Tide Lord
	[877]={name="Saltscale Forager",zone="Stranglethorn Vale",level=36,type="elite",creatureType="Humanoid"},  -- Saltscale Forager
	[947]={name="Rohh the Silent",zone="Redridge Mountains",level=26,type="rare",creatureType="Humanoid"},  -- Rohh the Silent
	[1037]={name="Dragonmaw Battlemaster",zone="Wetlands",level=30,type="rare",creatureType="Humanoid"},  -- Dragonmaw Battlemaster
	[1047]={name="Red Scalebane",zone="Wetlands",level=60,type="elite",creatureType="Dragonkin",include=false},  -- Red Scalebane
	[1048]={name="Scalebane Lieutenant",zone="Wetlands",level=61,type="elite",creatureType="Dragonkin",include=false},  -- Scalebane Lieutenant
	[1050]={name="Scalebane Royal Guard",zone="Wetlands",level=62,type="elite",creatureType="Dragonkin",include=false},  -- Scalebane Royal Guard
	[1051]={name="Dark Iron Dwarf",zone="Wetlands",level=28,type="elite",creatureType="Humanoid"},  -- Dark Iron Dwarf
	[1052]={name="Dark Iron Saboteur",zones={"Wetlands","Arathi Highlands"},level=29,type="elite",creatureType="Humanoid"},  -- Dark Iron Saboteur
	[1053]={name="Dark Iron Tunneler",zone="Wetlands",level=30,type="elite",creatureType="Humanoid"},  -- Dark Iron Tunneler
	[1054]={name="Dark Iron Demolitionist",zone="Wetlands",level=31,type="elite",creatureType="Humanoid"},  -- Dark Iron Demolitionist
	[1060]={name="Mogh the Undying",zone="Stranglethorn Vale",level=44,type="elite",creatureType="Humanoid"},  -- Mogh the Undying
	[1061]={name="Gan'zulah",zone="Stranglethorn Vale",level=41,type="rare",creatureType="Humanoid"},  -- Gan'zulah
	[1063]={name="Jade",zone="Swamp of Sorrows",level=47,type="rareelite",creatureType="Dragonkin"},  -- Jade
	[1106]={name="Lost One Cook",zone="Swamp of Sorrows",level=37,type="rare",creatureType="Humanoid"},  -- Lost One Cook
	[1112]={name="Leech Widow",zone="Wetlands",level=24,type="rare",creatureType="Beast"},  -- Leech Widow
	[1119]={name="Hammerspine",zone="Dun Morogh",level=12,type="rare",creatureType="Humanoid"},  -- Hammerspine
	[1130]={name="Bjarn",zone="Dun Morogh",level=12,type="rare",creatureType="Beast"},  -- Bjarn
	[1132]={name="Timber",zone="Dun Morogh",level=10,type="rare",creatureType="Beast"},  -- Timber
	[1137]={name="Edan the Howler",zone="Dun Morogh",level=9,type="rare",creatureType="Humanoid"},  -- Edan the Howler
	[1140]={name="Razormaw Matriarch",zone="Wetlands",level=30,type="rare",creatureType="Beast"},  -- Razormaw Matriarch
	[1178]={name="Mo'grosh Ogre",zone="Loch Modan",level=19,type="elite",creatureType="Humanoid"},  -- Mo'grosh Ogre
	[1179]={name="Mo'grosh Enforcer",zone="Loch Modan",level=19,type="elite",creatureType="Humanoid"},  -- Mo'grosh Enforcer
	[1180]={name="Mo'grosh Brute",zone="Loch Modan",level=20,type="elite",creatureType="Humanoid"},  -- Mo'grosh Brute
	[1181]={name="Mo'grosh Shaman",zone="Loch Modan",level=19,type="elite",creatureType="Humanoid"},  -- Mo'grosh Shaman
	[1183]={name="Mo'grosh Mystic",zone="Loch Modan",level=20,type="elite",creatureType="Humanoid"},  -- Mo'grosh Mystic
	[1200]={name="Morbent Fel",zone="Duskwood",level=32,type="elite",creatureType="Undead"},  -- Morbent Fel
	[1210]={name="Chok'Sul",zone="Loch Modan",level=22,type="elite",creatureType="Humanoid"},  -- Chok'Sul
	[1225]={name="Ol'Sooty",zone="Loch Modan",level=20,type="elite",creatureType="Beast"},  -- Ol'Sooty
	[1260]={name="Great Father Arctikus",zone="Dun Morogh",level=11,type="rare",creatureType="Humanoid"},  -- Great Father Arctikus
	[1271]={name="Old Icebeard",zone="Dun Morogh",level=11,type="elite",creatureType="Humanoid"},  -- Old Icebeard
	[1364]={name="Balgaras the Foul",zone="Wetlands",level=34,type="elite",creatureType="Humanoid"},  -- Balgaras the Foul
	[1388]={name="Vagash",zone="Dun Morogh",level=11,type="elite",creatureType="Humanoid"},  -- Vagash
	[1398]={name="Boss Galgosh",zone="Loch Modan",level=22,type="rare",creatureType="Humanoid"},  -- Boss Galgosh
	[1399]={name="Magosh",zone="Loch Modan",level=21,type="rare",creatureType="Humanoid"},  -- Magosh
	[1424]={name="Master Digger",zone="Westfall",level=15,type="rare",creatureType="Humanoid"},  -- Master Digger
	[1425]={name="Grizlak",zone="Loch Modan",level=15,type="rare",creatureType="Humanoid"},  -- Grizlak
	[1492]={name="Gorlash",zone="Stranglethorn Vale",level=47,type="elite",creatureType="Giant"},  -- Gorlash
	[1493]={name="Mok'rash",zone="Stranglethorn Vale",level=50,type="elite",creatureType="Giant"},  -- Mok'rash
	[1494]={name="Negolash",zone="Stranglethorn Vale",level=52,type="elite",creatureType="Giant"},  -- Negolash
	[1552]={name="Scale Belly",zone="Stranglethorn Vale",level=45,type="rare",creatureType="Beast"},  -- Scale Belly
	[1559]={name="King Mukla",zone="Stranglethorn Vale",level=51,type="elite",creatureType="Beast"},  -- King Mukla
	[1720]={name="Bruegal Ironknuckle",zone="The Stockade",level=26,type="rareelite",creatureType="Humanoid"},  -- Bruegal Ironknuckle
	[1788]={name="Skeletal Warlord",zone="Western Plaguelands",level=57,type="elite",creatureType="Undead"},  -- Skeletal Warlord
	[1805]={name="Flesh Golem",zone="Western Plaguelands",level=57,type="elite",creatureType="Undead"},  -- Flesh Golem
	[1827]={name="Scarlet Sentinel",zone="Western Plaguelands",level=56,type="elite",creatureType="Humanoid"},  -- Scarlet Sentinel
	[1834]={name="Scarlet Paladin",zone="Western Plaguelands",level=56,type="elite",creatureType="Humanoid"},  -- Scarlet Paladin
	[1837]={name="Scarlet Judge",zone="Western Plaguelands",level=60,type="rare",creatureType="Humanoid"},  -- Scarlet Judge
	[1838]={name="Scarlet Interrogator",zone="Western Plaguelands",level=62,type="rareelite",creatureType="Humanoid"},  -- Scarlet Interrogator
	[1839]={name="Scarlet High Clerist",zone="Western Plaguelands",level=63,type="rareelite",creatureType="Humanoid"},  -- Scarlet High Clerist
	[1841]={name="Scarlet Executioner",zone="Western Plaguelands",level=60,type="rareelite",creatureType="Humanoid"},  -- Scarlet Executioner
	[1843]={name="Foreman Jerris",zone="Western Plaguelands",level=63,type="rareelite",creatureType="Humanoid"},  -- Foreman Jerris
	[1844]={name="Foreman Marcrid",zone="Western Plaguelands",level=58,type="rare",creatureType="Humanoid"},  -- Foreman Marcrid
	[1846]={name="High Protector Lorik",zone="Western Plaguelands",level=61,type="elite",creatureType="Humanoid"},  -- High Protector Lorik
	[1847]={name="Foulmane",zone="Western Plaguelands",level=52,type="rare",creatureType="Undead"},  -- Foulmane
	[1848]={name="Lord Maldazzar",zone="Western Plaguelands",level=56,type="rare",creatureType="Humanoid"},  -- Lord Maldazzar
	[1850]={name="Putridius",zone="Western Plaguelands",level=58,type="rareelite",creatureType="Undead"},  -- Putridius
	[1851]={name="The Husk",zone="Western Plaguelands",level=62,type="rare",creatureType="Elemental"},  -- The Husk
	[1852]={name="Araj the Summoner",zone="Western Plaguelands",level=61,type="elite",creatureType="Undead"},  -- Araj the Summoner
	[1885]={name="Scarlet Smith",zone="Western Plaguelands",level=60,type="rare",creatureType="Humanoid"},  -- Scarlet Smith
	[2090]={name="Ma'ruk Wyrmscale",zone="Wetlands",level=23,type="rare",creatureType="Humanoid"},  -- Ma'ruk Wyrmscale
	[2091]={name="Chieftain Nek'rosh",zone="Wetlands",level=32,type="elite",creatureType="Humanoid"},  -- Chieftain Nek'rosh
	[2106]={name="Apothecary Berard",zone="Silverpine Forest",level=16,type="elite",creatureType="Humanoid"},  -- Apothecary Berard
	[2108]={name="Garneg Charskull",zone="Wetlands",level=29,type="rare",creatureType="Humanoid"},  -- Garneg Charskull
	[2166]={name="Oakenscowl",zone="Teldrassil",level=9,type="elite",creatureType="Elemental"},  -- Oakenscowl
	[2175]={name="Shadowclaw",zone="Darkshore",level=13,type="rare",creatureType="Beast",surprise="stealth",severity=3,stealth=true,roams=true,soloable=false,why="Roaming elite panther in a starter zone. Low-level players have no stealth detection and no escape."},  -- Shadowclaw
	[2184]={name="Lady Moongazer",zone="Darkshore",level=17,type="rare",creatureType="Undead"},  -- Lady Moongazer
	[2186]={name="Carnivous the Breaker",zone="Darkshore",level=16,type="rare",creatureType="Humanoid"},  -- Carnivous the Breaker
	[2191]={name="Licillin",zone="Darkshore",level=14,type="rare",creatureType="Demon"},  -- Licillin
	[2192]={name="Firecaller Radison",zone="Darkshore",level=19,type="rare",creatureType="Humanoid"},  -- Firecaller Radison
	[2215]={name="High Executor Darthalia",zone="Hillsbrad Foothills",level=60,type="elite",creatureType="Humanoid"},  -- High Executor Darthalia
	[2226]={name="Karos Razok",zone="Silverpine Forest",level=55,type="elite",creatureType="Humanoid"},  -- Karos Razok
	[2254]={name="Crushridge Mauler",zone="Alterac Mountains",level=37,type="elite",creatureType="Humanoid"},  -- Crushridge Mauler
	[2257]={name="Mug'thol",zone="Alterac Mountains",level=43,type="elite",creatureType="Humanoid"},  -- Mug'thol
	[2258]={name="Stone Fury",zone="Alterac Mountains",level=37,type="rare",creatureType="Elemental"},  -- Stone Fury
	[2287]={name="Crushridge Warmonger",zone="Alterac Mountains",level=40,type="elite",creatureType="Humanoid"},  -- Crushridge Warmonger
	[2416]={name="Crushridge Plunderer",zone="Alterac Mountains",level=37,type="elite",creatureType="Humanoid"},  -- Crushridge Plunderer
	[2417]={name="Grel'borg the Miser",zone="Alterac Mountains",level=39,type="elite",creatureType="Humanoid"},  -- Grel'borg the Miser
	[2420]={name="Targ",zone="Alterac Mountains",level=41,type="elite",creatureType="Humanoid"},  -- Targ
	[2421]={name="Muckrake",zone="Alterac Mountains",level=40,type="elite",creatureType="Humanoid"},  -- Muckrake
	[2422]={name="Glommus",zone="Alterac Mountains",level=39,type="elite",creatureType="Humanoid"},  -- Glommus
	[2433]={name="Helcular's Remains",zone="Hillsbrad Foothills",level=44,type="elite",creatureType="Undead"},  -- Helcular's Remains
	[2447]={name="Narillasanz",zones={"Alterac Mountains","Hillsbrad Foothills"},level=44,type="rareelite",creatureType="Dragonkin"},  -- Narillasanz
	[2452]={name="Skhowl",zone="Alterac Mountains",level=36,type="rare",creatureType="Humanoid"},  -- Skhowl
	[2453]={name="Lo'Grosh",zone="Alterac Mountains",level=39,type="rare",creatureType="Humanoid"},  -- Lo'Grosh
	[2476]={name="Large Loch Crocolisk",zone="Loch Modan",level=22,type="rare",creatureType="Beast"},  -- Large Loch Crocolisk
	[2477]={name="Gradok",zone="Loch Modan",level=21,type="elite",creatureType="Humanoid",roams=true},  -- Gradok
	[2478]={name="Haren Swifthoof",zone="Loch Modan",level=21,type="elite",creatureType="Humanoid",roams=true},  -- Haren Swifthoof
	[2541]={name="Lord Sakrasis",zone="Stranglethorn Vale",level=45,type="rare",creatureType="Humanoid"},  -- Lord Sakrasis
	[2558]={name="Witherbark Berserker",zone="Arathi Highlands",level=37,type="elite",creatureType="Humanoid"},  -- Witherbark Berserker
	[2570]={name="Boulderfist Shaman",zone="Arathi Highlands",level=39,type="elite",creatureType="Humanoid"},  -- Boulderfist Shaman
	[2571]={name="Boulderfist Lord",zone="Arathi Highlands",level=40,type="elite",creatureType="Humanoid"},  -- Boulderfist Lord
	[2588]={name="Syndicate Prowler",zone="Arathi Highlands",level=37,type="elite",creatureType="Humanoid"},  -- Syndicate Prowler
	[2590]={name="Syndicate Conjuror",zone="Arathi Highlands",level=36,type="elite",creatureType="Humanoid"},  -- Syndicate Conjuror
	[2591]={name="Syndicate Magus",zone="Arathi Highlands",level=38,type="elite",creatureType="Humanoid"},  -- Syndicate Magus
	[2597]={name="Lord Falconcrest",zone="Arathi Highlands",level=40,type="elite",creatureType="Humanoid"},  -- Lord Falconcrest
	[2598]={name="Darbel Montrose",zone="Arathi Highlands",level=39,type="rareelite",creatureType="Humanoid"},  -- Darbel Montrose
	[2599]={name="Otto",zone="Arathi Highlands",level=38,type="elite",creatureType="Humanoid"},  -- Otto
	[2600]={name="Singer",zone="Arathi Highlands",level=34,type="rare",creatureType="Humanoid"},  -- Singer
	[2601]={name="Foulbelly",zone="Arathi Highlands",level=42,type="rareelite",creatureType="Humanoid"},  -- Foulbelly
	[2602]={name="Ruul Onestone",zone="Arathi Highlands",level=39,type="rareelite",creatureType="Humanoid"},  -- Ruul Onestone
	[2603]={name="Kovork",zone="Arathi Highlands",level=37,type="rare",creatureType="Humanoid"},  -- Kovork
	[2604]={name="Molok the Crusher",zone="Arathi Highlands",level=39,type="rare",creatureType="Humanoid"},  -- Molok the Crusher
	[2605]={name="Zalas Witherbark",zone="Arathi Highlands",level=40,type="rare",creatureType="Humanoid"},  -- Zalas Witherbark
	[2606]={name="Nimar the Slayer",zone="Arathi Highlands",level=37,type="rare",creatureType="Humanoid"},  -- Nimar the Slayer
	[2609]={name="Geomancer Flintdagger",zone="Arathi Highlands",level=40,type="rare",creatureType="Humanoid"},  -- Geomancer Flintdagger
	[2635]={name="Elder Saltwater Crocolisk",zone="Stranglethorn Vale",level=38,type="elite",creatureType="Beast"},  -- Elder Saltwater Crocolisk
	[2642]={name="Vilebranch Shadowcaster",zone="The Hinterlands",level=48,type="elite",creatureType="Humanoid"},  -- Vilebranch Shadowcaster
	[2643]={name="Vilebranch Berserker",zone="The Hinterlands",level=48,type="elite",creatureType="Humanoid"},  -- Vilebranch Berserker
	[2644]={name="Vilebranch Hideskinner",zone="The Hinterlands",level=49,type="elite",creatureType="Humanoid"},  -- Vilebranch Hideskinner
	[2645]={name="Vilebranch Shadow Hunter",zone="The Hinterlands",level=49,type="elite",creatureType="Humanoid"},  -- Vilebranch Shadow Hunter
	[2647]={name="Vilebranch Soul Eater",zone="The Hinterlands",level=50,type="elite",creatureType="Humanoid"},  -- Vilebranch Soul Eater
	[2681]={name="Vilebranch Raiding Wolf",zone="The Hinterlands",level=51,type="elite",creatureType="Beast"},  -- Vilebranch Raiding Wolf
	[2707]={name="Shadra",zone="The Hinterlands",level=55,type="elite",creatureType="Beast"},  -- Shadra
	[2714]={name="Forsaken Courier",zones={"Hillsbrad Foothills","Arathi Highlands"},level=35,type="normal",creatureType="Humanoid",roams=true},  -- Forsaken Courier
	[2721]={name="Forsaken Bodyguard",zones={"Hillsbrad Foothills","Arathi Highlands"},level=35,type="normal",creatureType="Humanoid",roams=true},  -- Forsaken Bodyguard
	[2726]={name="Scorched Guardian",zone="Badlands",level=45,type="elite",creatureType="Dragonkin"},  -- Scorched Guardian
	[2744]={name="Shadowforge Commander",zone="Badlands",level=40,type="rare",creatureType="Humanoid"},  -- Shadowforge Commander
	[2745]={name="Ambassador Infernus",zone="Badlands",level=42,type="elite",creatureType="Elemental"},  -- Ambassador Infernus
	[2749]={name="Siege Golem",zone="Badlands",level=40,type="rareelite",creatureType="Elemental"},  -- Siege Golem
	[2751]={name="War Golem",zone="Badlands",level=36,type="rare",creatureType="Elemental"},  -- War Golem
	[2752]={name="Rumbler",zone="Badlands",level=45,type="rare",creatureType="Elemental"},  -- Rumbler
	[2753]={name="Barnabus",zone="Badlands",level=39,type="rare",creatureType="Beast"},  -- Barnabus
	[2754]={name="Anathemus",zone="Badlands",level=45,type="rareelite",creatureType="Giant"},  -- Anathemus
	[2757]={name="Blacklash",zone="Badlands",level=50,type="elite",creatureType="Dragonkin"},  -- Blacklash
	[2759]={name="Hematus",zone="Badlands",level=50,type="elite",creatureType="Dragonkin"},  -- Hematus
	[2763]={name="Thenan",zone="Arathi Highlands",level=42,type="elite",creatureType="Giant"},  -- Thenan
	[2773]={name="Or'Kalar",zone="Arathi Highlands",level=40,type="elite",creatureType="Humanoid"},  -- Or'Kalar
	[2779]={name="Prince Nazjak",zone="Arathi Highlands",level=41,type="rare",creatureType="Humanoid"},  -- Prince Nazjak
	[2783]={name="Marez Cowl",zone="Arathi Highlands",level=40,type="elite",creatureType="Humanoid"},  -- Marez Cowl
	[2850]={name="Broken Tooth",zone="Badlands",level=37,type="rare",creatureType="Beast"},  -- Broken Tooth
	[2858]={name="Gringer",zone="Stranglethorn Vale",level=55,type="elite",creatureType="Humanoid"},  -- Gringer
	[2861]={name="Gorrik",zone="Badlands",level=55,type="elite",creatureType="Humanoid"},  -- Gorrik
	[2931]={name="Zaricotl",zone="Badlands",level=55,type="rareelite",creatureType="Beast"},  -- Zaricotl
	[2937]={name="Dagun the Ravenous",zone="Dustwallow Marsh",level=43,type="elite",creatureType="Humanoid"},  -- Dagun the Ravenous
	[2995]={name="Tal",zone="Thunder Bluff",level=55,type="elite",creatureType="Humanoid"},  -- Tal
	[3056]={name="Ghost Howl",zone="Mulgore",level=12,type="rare",creatureType="Beast"},  -- Ghost Howl
	[3068]={name="Mazzranache",zone="Mulgore",level=9,type="rare",creatureType="Beast"},  -- Mazzranache
	[3270]={name="Elder Mystic Razorsnout",zone="The Barrens",level=15,type="rareelite",creatureType="Humanoid"},  -- Elder Mystic Razorsnout
	[3295]={name="Sludge Beast",zone="The Barrens",level=19,type="rare",creatureType="Slime"},  -- Sludge Beast
	[3310]={name="Doras",zone="Orgrimmar",level=55,type="elite",creatureType="Humanoid"},  -- Doras
	[3338]={name="Sergra Darkthorn",zone="The Barrens",level=60,type="elite",creatureType="Humanoid"},  -- Sergra Darkthorn
	[3398]={name="Gesharahan",zone="The Barrens",level=20,type="rareelite",creatureType="Hydra"},  -- Gesharahan
	[3470]={name="Rathorian",zone="The Barrens",level=15,type="rare",creatureType="Demon"},  -- Rathorian
	[3535]={name="Blackmoss the Fetid",zone="Teldrassil",level=13,type="rare",creatureType="Elemental"},  -- Blackmoss the Fetid
	[3581]={name="Sewer Beast",zone="Stormwind City",level=50,type="rare",creatureType="Beast"},  -- Sewer Beast
	[3586]={name="Miner Johnson",zone="The Deadmines",level=19,type="rareelite",creatureType="Humanoid"},  -- Miner Johnson
	[3615]={name="Devrak",zone="The Barrens",level=55,type="elite",creatureType="Humanoid"},  -- Devrak
	[3630]={name="Deviate Coiler",zone="The Barrens",level=16,type="elite",creatureType="Beast"},  -- Deviate Coiler
	[3632]={name="Deviate Creeper",zone="The Barrens",level=16,type="elite",creatureType="Beast"},  -- Deviate Creeper
	[3634]={name="Deviate Stalker",zone="The Barrens",level=17,type="elite",creatureType="Beast"},  -- Deviate Stalker
	[3638]={name="Devouring Ectoplasm",zone="The Barrens",level=17,type="elite",creatureType="Slime"},  -- Devouring Ectoplasm
	[3652]={name="Trigore the Lasher",zone="The Barrens",level=19,type="rareelite",creatureType="Hydra"},  -- Trigore the Lasher
	[3655]={name="Mad Magglish",zone="The Barrens",level=18,type="elite",creatureType="Humanoid"},  -- Mad Magglish
	[3672]={name="Boahn",zone="The Barrens",level=20,type="rareelite",creatureType="Humanoid"},  -- Boahn
	[3735]={name="Apothecary Falthis",zone="Ashenvale",level=22,type="rare",creatureType="Humanoid"},  -- Apothecary Falthis
	[3773]={name="Akkrilus",zone="Ashenvale",level=26,type="rare",creatureType="Demon"},  -- Akkrilus
	[3792]={name="Terrowulf Packlord",zone="Ashenvale",level=32,type="rare",creatureType="Humanoid"},  -- Terrowulf Packlord
	[3872]={name="Deathsworn Captain",zone="Shadowfang Keep",level=25,type="rareelite",creatureType="Undead"},  -- Deathsworn Captain
	[3984]={name="Nancy Vishas",zone="Alterac Mountains",level=33,type="elite",creatureType="Humanoid"},  -- Nancy Vishas
	[3985]={name="Grandpa Vishas",zone="Alterac Mountains",level=34,type="elite",creatureType="Humanoid"},  -- Grandpa Vishas
	[4015]={name="Pridewing Patriarch",zone="Stonetalon Mountains",level=25,type="rare",creatureType="Beast"},  -- Pridewing Patriarch
	[4030]={name="Vengeful Ancient",zone="Stonetalon Mountains",level=30,type="rare",creatureType="Elemental"},  -- Vengeful Ancient
	[4064]={name="Blackrock Scout",zone="Redridge Mountains",level=21,type="elite",creatureType="Humanoid"},  -- Blackrock Scout
	[4132]={name="Silithid Ravager",zone="Thousand Needles",level=37,type="rare",creatureType="Silithid"},  -- Silithid Ravager
	[4281]={name="Scarlet Scout",zone="Tirisfal Glades",level=30,type="elite",creatureType="Humanoid"},  -- Scarlet Scout
	[4282]={name="Scarlet Magician",zone="Tirisfal Glades",level=30,type="elite",creatureType="Humanoid"},  -- Scarlet Magician
	[4284]={name="Scarlet Augur",zone="Tirisfal Glades",level=31,type="elite",creatureType="Humanoid"},  -- Scarlet Augur
	[4285]={name="Scarlet Disciple",zone="Tirisfal Glades",level=31,type="elite",creatureType="Humanoid"},  -- Scarlet Disciple
	[4339]={name="Brimgore",zone="Dustwallow Marsh",level=45,type="rareelite",creatureType="Dragonkin"},  -- Brimgore
	[4366]={name="Strashaz Serpent Guard",zone="Dustwallow Marsh",level=61,type="elite",creatureType="Humanoid"},  -- Strashaz Serpent Guard
	[4371]={name="Strashaz Siren",zone="Dustwallow Marsh",level=60,type="elite",creatureType="Humanoid"},  -- Strashaz Siren
	[4374]={name="Strashaz Hydra",zone="Dustwallow Marsh",level=61,type="elite",creatureType="Hydra"},  -- Strashaz Hydra
	[4380]={name="Darkmist Widow",zone="Dustwallow Marsh",level=40,type="rare",creatureType="Beast"},  -- Darkmist Widow
	[4425]={name="Blind Hunter",zone="Razorfen Kraul",level=32,type="rareelite",creatureType="Beast"},  -- Blind Hunter
	[4438]={name="Razorfen Spearhide",zone="Razorfen Kraul",level=29,type="rareelite",creatureType="Humanoid"},  -- Razorfen Spearhide
	[4499]={name="Rok'Alim the Pounder",zone="Thousand Needles",level=30,type="elite",creatureType="Elemental"},  -- Rok'Alim the Pounder
	[4686]={name="Deepstrider Giant",zone="Desolace",level=39,type="elite",creatureType="Giant"},  -- Deepstrider Giant
	[4687]={name="Deepstrider Searcher",zone="Desolace",level=40,type="elite",creatureType="Giant"},  -- Deepstrider Searcher
	[4802]={name="Blackfathom Tide Priestess",zone="Ashenvale",level=21,type="elite",creatureType="Humanoid"},  -- Blackfathom Tide Priestess
	[4803]={name="Blackfathom Oracle",zone="Ashenvale",level=22,type="elite",creatureType="Humanoid"},  -- Blackfathom Oracle
	[4842]={name="Earthcaller Halmgar",zone="Razorfen Kraul",level=32,type="rareelite",creatureType="Humanoid"},  -- Earthcaller Halmgar
	[4846]={name="Shadowforge Digger",zone="Badlands",level=36,type="elite",creatureType="Humanoid"},  -- Shadowforge Digger
	[5158]={name="Hammerhead Shark",zone="Wetlands",level=32,type="elite",creatureType="Beast"},  -- Hammerhead Shark
	[5185]={name="Hammerhead Shark",zone="Hillsbrad Foothills",level=32,type="elite",creatureType="Beast"},  -- Hammerhead Shark
	[5312]={name="Lethlas",zone="Feralas",level=62,type="elite",creatureType="Dragonkin"},  -- Lethlas
	[5314]={name="Phantim",zone="Ashenvale",level=62,type="elite",creatureType="Dragonkin"},  -- Phantim
	[5317]={name="Jademir Oracle",zone="Feralas",level=61,type="elite",creatureType="Dragonkin"},  -- Jademir Oracle
	[5319]={name="Jademir Tree Warder",zone="Feralas",level=60,type="elite",creatureType="Dragonkin"},  -- Jademir Tree Warder
	[5320]={name="Jademir Boughguard",zone="Feralas",level=62,type="elite",creatureType="Dragonkin"},  -- Jademir Boughguard
	[5343]={name="Lady Szallah",zone="Feralas",level=46,type="rare",creatureType="Humanoid"},  -- Lady Szallah
	[5345]={name="Diamond Head",zone="Feralas",level=46,type="rare",creatureType="Humanoid"},  -- Diamond Head
	[5346]={name="Bloodroar the Stalker",zone="Feralas",level=49,type="rare",creatureType="Humanoid"},  -- Bloodroar the Stalker
	[5347]={name="Antilus the Soarer",zone="Feralas",level=49,type="rare",creatureType="Beast"},  -- Antilus the Soarer
	[5349]={name="Arash-ethis",zone="Feralas",level=49,type="rare",creatureType="Beast"},  -- Arash-ethis
	[5350]={name="Qirot",zone="Feralas",level=47,type="rare",creatureType="Silithid"},  -- Qirot
	[5352]={name="Old Grizzlegut",zone="Feralas",level=43,type="rare",creatureType="Beast"},  -- Old Grizzlegut
	[5356]={name="Snarler",zone="Feralas",level=42,type="rare",creatureType="Beast"},  -- Snarler
	[5357]={name="Land Walker",zone="Feralas",level=49,type="elite",creatureType="Giant"},  -- Land Walker
	[5358]={name="Cliff Giant",zone="Feralas",level=50,type="elite",creatureType="Giant"},  -- Cliff Giant
	[5360]={name="Deep Strider",zone="Feralas",level=49,type="elite",creatureType="Giant"},  -- Deep Strider
	[5399]={name="Veyzhak the Cannibal",zone="Swamp of Sorrows",level=48,type="rareelite",creatureType="Humanoid"},  -- Veyzhak the Cannibal
	[5400]={name="Zekkis",zone="Swamp of Sorrows",level=48,type="rareelite",creatureType="Undead"},  -- Zekkis
	[5402]={name="Khan Hratha",zone="Desolace",level=42,type="elite",creatureType="Humanoid"},  -- Khan Hratha
	[5434]={name="Coral Shark",zone="Dustwallow Marsh",level=47,type="elite",creatureType="Beast"},  -- Coral Shark
	[5435]={name="Sand Shark",zones={"Durotar","The Barrens","Tirisfal Glades"},level=13,type="elite",creatureType="Beast"},  -- Sand Shark
	[5469]={name="Dune Smasher",zone="Tanaris",level=49,type="elite",creatureType="Giant"},  -- Dune Smasher
	[5718]={name="Rothos",zone="The Hinterlands",level=62,type="elite",creatureType="Dragonkin"},  -- Rothos
	[5760]={name="Lord Azrethoc",zone="Desolace",level=40,type="elite",creatureType="Demon"},  -- Lord Azrethoc
	[5780]={name="Cloned Ectoplasm",zone="The Barrens",level=17,type="elite",creatureType="Slime"},  -- Cloned Ectoplasm
	[5786]={name="Snagglespear",zone="Mulgore",level=9,type="rare",creatureType="Humanoid"},  -- Snagglespear
	[5807]={name="The Rake",zone="Mulgore",level=10,type="rare",creatureType="Beast"},  -- The Rake
	[5823]={name="Death Flayer",zone="Durotar",level=11,type="rare",creatureType="Beast"},  -- Death Flayer
	[5828]={name="Humar the Pridelord",zone="The Barrens",level=23,type="rareelite",creatureType="Beast"},  -- Humar the Pridelord
	[5829]={name="Snort the Heckler",zone="The Barrens",level=17,type="rare",creatureType="Beast"},  -- Snort the Heckler
	[5830]={name="Sister Rathtalon",zone="The Barrens",level=19,type="rareelite",creatureType="Humanoid"},  -- Sister Rathtalon
	[5832]={name="Thunderstomp",zone="The Barrens",level=24,type="rare",creatureType="Beast"},  -- Thunderstomp
	[5833]={name="Margol the Rager",zone="Searing Gorge",level=48,type="elite",creatureType="Beast"},  -- Margol the Rager
	[5834]={name="Azzere the Skyblade",zone="The Barrens",level=25,type="rare",creatureType="Beast"},  -- Azzere the Skyblade
	[5835]={name="Foreman Grills",zone="The Barrens",level=19,type="rare",creatureType="Humanoid"},  -- Foreman Grills
	[5836]={name="Engineer Whirleygig",zone="The Barrens",level=19,type="rare",creatureType="Humanoid"},  -- Engineer Whirleygig
	[5837]={name="Stonearm",zone="The Barrens",level=15,type="rare",creatureType="Humanoid"},  -- Stonearm
	[5838]={name="Brokespear",zone="The Barrens",level=17,type="rare",creatureType="Humanoid"},  -- Brokespear
	[5841]={name="Rocklance",zone="The Barrens",level=17,type="rareelite",creatureType="Humanoid"},  -- Rocklance
	[5842]={name="Takk the Leaper",zone="The Barrens",level=19,type="rareelite",creatureType="Beast"},  -- Takk the Leaper
	[5859]={name="Hagg Taurenbane",zone="The Barrens",level=26,type="rareelite",creatureType="Humanoid"},  -- Hagg Taurenbane
	[5861]={name="Twilight Fire Guard",zone="Searing Gorge",level=49,type="elite",creatureType="Humanoid"},  -- Twilight Fire Guard
	[5862]={name="Twilight Geomancer",zone="Searing Gorge",level=50,type="elite",creatureType="Humanoid"},  -- Twilight Geomancer
	[5865]={name="Dishu",zone="The Barrens",level=13,type="rare",creatureType="Beast"},  -- Dishu
	[5912]={name="Deviate Faerie Dragon",zone="Wailing Caverns",level=20,type="rareelite",creatureType="Dragonkin"},  -- Deviate Faerie Dragon
	[5928]={name="Sorrow Wing",zone="Stonetalon Mountains",level=27,type="rareelite",creatureType="Beast"},  -- Sorrow Wing
	[5930]={name="Sister Riven",zone="Stonetalon Mountains",level=28,type="rareelite",creatureType="Humanoid"},  -- Sister Riven
	[5931]={name="Foreman Rigger",zone="Stonetalon Mountains",level=24,type="rareelite",creatureType="Humanoid"},  -- Foreman Rigger
	[5932]={name="Taskmaster Whipfang",zone="Stonetalon Mountains",level=22,type="rareelite",creatureType="Humanoid"},  -- Taskmaster Whipfang
	[5933]={name="Achellios the Banished",zone="Thousand Needles",level=31,type="rare",creatureType="Humanoid"},  -- Achellios the Banished
	[5934]={name="Heartrazor",zone="Thousand Needles",level=32,type="rareelite",creatureType="Beast"},  -- Heartrazor
	[5935]={name="Ironeye the Invincible",zone="Thousand Needles",level=37,type="rareelite",creatureType="Beast"},  -- Ironeye the Invincible
	[5937]={name="Vile Sting",zone="Thousand Needles",level=35,type="rareelite",creatureType="Beast"},  -- Vile Sting
	[6118]={name="Varo'then's Ghost",zone="Azshara",level=48,type="rare",creatureType="Undead"},  -- Varo'then's Ghost
	[6129]={name="Draconic Magelord",zone="Azshara",level=54,type="elite",creatureType="Dragonkin"},  -- Draconic Magelord
	[6131]={name="Draconic Mageweaver",zone="Azshara",level=52,type="elite",creatureType="Dragonkin"},  -- Draconic Mageweaver
	[6132]={name="Razorfen Servitor",zone="The Barrens",level=24,type="elite",creatureType="Humanoid"},  -- Razorfen Servitor
	[6140]={name="Hetaera",zone="Azshara",level=55,type="elite",creatureType="Hydra"},  -- Hetaera
	[6144]={name="Son of Arkkoroc",zone="Azshara",level=55,type="elite",creatureType="Giant"},  -- Son of Arkkoroc
	[6146]={name="Cliff Breaker",zone="Azshara",level=62,type="elite",creatureType="Giant"},  -- Cliff Breaker
	[6147]={name="Cliff Thunderer",zone="Azshara",level=62,type="elite",creatureType="Giant"},  -- Cliff Thunderer
	[6148]={name="Cliff Walker",zone="Azshara",level=62,type="elite",creatureType="Giant"},  -- Cliff Walker
	[6228]={name="Dark Iron Ambassador",zone="Gnomeregan",level=33,type="rareelite",creatureType="Humanoid"},  -- Dark Iron Ambassador
	[6239]={name="Cyclonian",zone="Alterac Mountains",level=40,type="elite",creatureType="Elemental"},  -- Cyclonian
	[6488]={name="Fallen Champion",zone="Scarlet Monastery",level=33,type="rareelite",creatureType="Undead"},  -- Fallen Champion
	[6489]={name="Ironspine",zone="Scarlet Monastery",level=33,type="rareelite",creatureType="Undead"},  -- Ironspine
	[6490]={name="Azshir the Sleepless",zone="Scarlet Monastery",level=33,type="rareelite",creatureType="Undead"},  -- Azshir the Sleepless
	[6498]={name="Devilsaur",zone="Un'Goro Crater",level=55,type="elite",creatureType="Beast"},  -- Devilsaur
	[6499]={name="Ironhide Devilsaur",zone="Un'Goro Crater",level=56,type="elite",creatureType="Beast"},  -- Ironhide Devilsaur
	[6500]={name="Tyrant Devilsaur",zone="Un'Goro Crater",level=55,type="elite",creatureType="Beast"},  -- Tyrant Devilsaur
	[6501]={name="Stegodon",zone="Un'Goro Crater",level=53,type="elite",creatureType="Beast"},  -- Stegodon
	[6523]={name="Dark Iron Rifleman",zone="Wetlands",level=28,type="elite",creatureType="Humanoid"},  -- Dark Iron Rifleman
	[6549]={name="Demon of the Orb",zone="Dustwallow Marsh",level=40,type="elite",creatureType="Demon"},  -- Demon of the Orb
	[6581]={name="Ravasaur Matriarch",zone="Un'Goro Crater",level=50,type="rare",creatureType="Beast"},  -- Ravasaur Matriarch
	[6582]={name="Clutchmother Zavas",zone="Un'Goro Crater",level=54,type="rare",creatureType="Silithid"},  -- Clutchmother Zavas
	[6583]={name="Gruff",zone="Un'Goro Crater",level=57,type="rareelite",creatureType="Beast"},  -- Gruff
	[6584]={name="King Mosh",zone="Un'Goro Crater",level=60,type="rareelite",creatureType="Beast"},  -- King Mosh
	[6585]={name="Uhk'loc",zone="Un'Goro Crater",level=52,type="rare",creatureType="Beast"},  -- Uhk'loc
	[6646]={name="Monnos the Elder",zone="Azshara",level=53,type="rareelite",creatureType="Giant"},  -- Monnos the Elder
	[6647]={name="Magister Hawkhelm",zone="Azshara",level=52,type="rare",creatureType="Humanoid"},  -- Magister Hawkhelm
	[6648]={name="Antilos",zone="Azshara",level=51,type="rare",creatureType="Beast"},  -- Antilos
	[6649]={name="Lady Sesspira",zone="Azshara",level=51,type="rare",creatureType="Humanoid"},  -- Lady Sesspira
	[6650]={name="General Fangferror",zone="Azshara",level=52,type="rare",creatureType="Humanoid"},  -- General Fangferror
	[6651]={name="Gatekeeper Rageroar",zone="Azshara",level=51,type="rare",creatureType="Humanoid"},  -- Gatekeeper Rageroar
	[6652]={name="Master Feardred",zone="Azshara",level=57,type="rare",creatureType="Demon"},  -- Master Feardred
	[6669]={name="The Threshwackonator 4100",zone="Darkshore",level=20,type="elite",creatureType="Mechanical"},  -- The Threshwackonator 4100
	[6733]={name="Stonevault Basher",zone="Badlands",level=40,type="elite",creatureType="Humanoid"},  -- Stonevault Basher
	[7015]={name="Flagglemurk the Cruel",zone="Darkshore",level=16,type="rare",creatureType="Humanoid"},  -- Flagglemurk the Cruel
	[7016]={name="Lady Vespira",zone="Darkshore",level=22,type="rare",creatureType="Humanoid"},  -- Lady Vespira
	[7017]={name="Lord Sinslayer",zone="Darkshore",level=15,type="rare",creatureType="Humanoid"},  -- Lord Sinslayer
	[7040]={name="Black Dragonspawn",zone="Burning Steppes",level=53,type="elite",creatureType="Dragonkin"},  -- Black Dragonspawn
	[7041]={name="Black Wyrmkin",zone="Burning Steppes",level=54,type="elite",creatureType="Dragonkin"},  -- Black Wyrmkin
	[7042]={name="Flamescale Dragonspawn",zone="Burning Steppes",level=57,type="elite",creatureType="Dragonkin"},  -- Flamescale Dragonspawn
	[7043]={name="Flamescale Wyrmkin",zone="Burning Steppes",level=58,type="elite",creatureType="Dragonkin"},  -- Flamescale Wyrmkin
	[7044]={name="Black Drake",zone="Burning Steppes",level=52,type="elite",creatureType="Dragonkin"},  -- Black Drake
	[7053]={name="Klaven Mortwake",zone="Westfall",level=23,type="elite",creatureType="Humanoid"},  -- Klaven Mortwake
	[7057]={name="Digmaster Shovelphlange",zone="Badlands",level=38,type="rareelite",creatureType="Humanoid"},  -- Digmaster Shovelphlange
	[7070]={name="Condemned Cleric",zone="Hillsbrad Foothills",level=60,type="elite",creatureType="Undead"},  -- Condemned Cleric
	[7071]={name="Cursed Paladin",zone="Hillsbrad Foothills",level=58,type="elite",creatureType="Undead"},  -- Cursed Paladin
	[7072]={name="Cursed Justicar",zone="Hillsbrad Foothills",level=60,type="elite",creatureType="Undead"},  -- Cursed Justicar
	[7104]={name="Dessecus",zone="Felwood",level=56,type="rareelite",creatureType="Elemental"},  -- Dessecus
	[7135]={name="Infernal Bodyguard",zone="Felwood",level=54,type="elite",creatureType="Demon"},  -- Infernal Bodyguard
	[7136]={name="Infernal Sentry",zone="Felwood",level=53,type="elite",creatureType="Demon"},  -- Infernal Sentry
	[7137]={name="Immolatus",zone="Felwood",level=56,type="rareelite",creatureType="Demon"},  -- Immolatus
	[7170]={name="Thragomm",zone="Loch Modan",level=21,type="elite",creatureType="Humanoid",roams=true},  -- Thragomm
	[7233]={name="Taskmaster Fizzule",zone="The Barrens",level=30,type="elite",creatureType="Humanoid"},  -- Taskmaster Fizzule
	[7428]={name="Frostmaul Giant",zone="Winterspring",level=60,type="elite",creatureType="Giant"},  -- Frostmaul Giant
	[7429]={name="Frostmaul Preserver",zone="Winterspring",level=60,type="elite",creatureType="Giant"},  -- Frostmaul Preserver
	[7435]={name="Cobalt Wyrmkin",zone="Winterspring",level=56,type="elite",creatureType="Dragonkin"},  -- Cobalt Wyrmkin
	[7436]={name="Cobalt Scalebane",zone="Winterspring",level=57,type="elite",creatureType="Dragonkin"},  -- Cobalt Scalebane
	[7437]={name="Cobalt Mageweaver",zone="Winterspring",level=58,type="elite",creatureType="Dragonkin"},  -- Cobalt Mageweaver
	[7461]={name="Hederine Initiate",zone="Winterspring",level=60,type="elite",creatureType="Demon"},  -- Hederine Initiate
	[7462]={name="Hederine Manastalker",zone="Winterspring",level=60,type="elite",creatureType="Demon"},  -- Hederine Manastalker
	[7463]={name="Hederine Slayer",zone="Winterspring",level=60,type="elite",creatureType="Demon"},  -- Hederine Slayer
	[7664]={name="Razelikh the Defiler",zone="Blasted Lands",level=60,type="elite",creatureType="Demon"},  -- Razelikh the Defiler
	[7665]={name="Grol the Destroyer",zone="Blasted Lands",level=58,type="elite",creatureType="Demon"},  -- Grol the Destroyer
	[7666]={name="Archmage Allistarj",zone="Blasted Lands",level=58,type="elite",creatureType="Demon"},  -- Archmage Allistarj
	[7667]={name="Lady Sevine",zone="Blasted Lands",level=59,type="elite",creatureType="Demon"},  -- Lady Sevine
	[7728]={name="Kirith the Damned",zone="Blasted Lands",level=55,type="elite",creatureType="Demon"},  -- Kirith the Damned
	[7846]={name="Teremus the Devourer",zone="Blasted Lands",level=63,type="elite",creatureType="Dragonkin"},  -- Teremus the Devourer
	[7872]={name="Death's Head Cultist",zones={"The Barrens","Thousand Needles"},level=34,type="elite",creatureType="Humanoid"},  -- Death's Head Cultist
	[7875]={name="Hadoken Swiftstrider",zone="Feralas",level=57,type="elite",creatureType="Humanoid"},  -- Hadoken Swiftstrider
	[7895]={name="Ambassador Bloodrage",zone="The Barrens",level=36,type="rareelite",creatureType="Undead"},  -- Ambassador Bloodrage
	[7977]={name="Gammerita",zone="The Hinterlands",level=48,type="elite",creatureType="Beast"},  -- Gammerita
	[7995]={name="Vile Priestess Hexx",zone="The Hinterlands",level=51,type="elite",creatureType="Humanoid"},  -- Vile Priestess Hexx
	[7996]={name="Qiaga the Keeper",zone="The Hinterlands",level=50,type="elite",creatureType="Humanoid"},  -- Qiaga the Keeper
	[8075]={name="Edana Hatetalon",zone="Feralas",level=50,type="elite",creatureType="Humanoid"},  -- Edana Hatetalon
	[8199]={name="Warleader Krazzilak",zone="Tanaris",level=45,type="rareelite",creatureType="Humanoid"},  -- Warleader Krazzilak
	[8200]={name="Jin'Zallah the Sandbringer",zone="Tanaris",level=46,type="rareelite",creatureType="Humanoid"},  -- Jin'Zallah the Sandbringer
	[8201]={name="Omgorn the Lost",zone="Tanaris",level=50,type="rare",creatureType="Humanoid"},  -- Omgorn the Lost
	[8202]={name="Cyclok the Mad",zone="Tanaris",level=48,type="rare",creatureType="Humanoid"},  -- Cyclok the Mad
	[8203]={name="Kregg Keelhaul",zone="Tanaris",level=47,type="rare",creatureType="Humanoid"},  -- Kregg Keelhaul
	[8204]={name="Soriid the Devourer",zone="Tanaris",level=51,type="rare",creatureType="Silithid"},  -- Soriid the Devourer
	[8205]={name="Haarka the Ravenous",zone="Tanaris",level=50,type="rare",creatureType="Silithid"},  -- Haarka the Ravenous
	[8207]={name="Greater Firebird",zone="Tanaris",level=46,type="rare",creatureType="Beast"},  -- Greater Firebird
	[8208]={name="Murderous Blisterpaw",zone="Tanaris",level=44,type="rare",creatureType="Beast"},  -- Murderous Blisterpaw
	[8210]={name="Razortalon",zone="The Hinterlands",level=44,type="rare",creatureType="Humanoid"},  -- Razortalon
	[8211]={name="Old Cliff Jumper",zone="The Hinterlands",level=42,type="rare",creatureType="Beast"},  -- Old Cliff Jumper
	[8212]={name="The Reak",zone="The Hinterlands",level=50,type="rare",creatureType="Slime"},  -- The Reak
	[8213]={name="Ironback",zone="The Hinterlands",level=51,type="rare",creatureType="Beast"},  -- Ironback
	[8215]={name="Grimungous",zone="The Hinterlands",level=50,type="rareelite",creatureType="Giant"},  -- Grimungous
	[8216]={name="Retherokk the Berserker",zone="The Hinterlands",level=48,type="rare",creatureType="Humanoid"},  -- Retherokk the Berserker
	[8217]={name="Mith'rethis the Enchanter",zone="The Hinterlands",level=52,type="rareelite",creatureType="Humanoid"},  -- Mith'rethis the Enchanter
	[8218]={name="Witherheart the Stalker",zone="The Hinterlands",level=45,type="rare",creatureType="Humanoid"},  -- Witherheart the Stalker
	[8219]={name="Zul'arek Hatefowler",zone="The Hinterlands",level=43,type="rare",creatureType="Humanoid"},  -- Zul'arek Hatefowler
	[8277]={name="Rekk'tilac",zone="Searing Gorge",level=49,type="rare",creatureType="Beast"},  -- Rekk'tilac
	[8278]={name="Smoldar",zone="Searing Gorge",level=53,type="rare",creatureType="Elemental"},  -- Smoldar
	[8279]={name="Faulty War Golem",zone="Searing Gorge",level=46,type="rare",creatureType="Elemental"},  -- Faulty War Golem
	[8280]={name="Shleipnarr",zone="Searing Gorge",level=47,type="rare",creatureType="Demon"},  -- Shleipnarr
	[8281]={name="Scald",zone="Searing Gorge",level=49,type="rare",creatureType="Elemental"},  -- Scald
	[8282]={name="Highlord Mastrogonde",zone="Searing Gorge",level=51,type="rareelite",creatureType="Humanoid"},  -- Highlord Mastrogonde
	[8283]={name="Slave Master Blackheart",zone="Searing Gorge",level=50,type="rare",creatureType="Humanoid"},  -- Slave Master Blackheart
	[8296]={name="Mojo the Twisted",zone="Blasted Lands",level=48,type="rare",creatureType="Humanoid"},  -- Mojo the Twisted
	[8297]={name="Magronos the Unyielding",zone="Blasted Lands",level=57,type="rare",creatureType="Humanoid"},  -- Magronos the Unyielding
	[8298]={name="Akubar the Seer",zone="Blasted Lands",level=54,type="rare",creatureType="Humanoid"},  -- Akubar the Seer
	[8299]={name="Spiteflayer",zone="Blasted Lands",level=60,type="rare",creatureType="Beast"},  -- Spiteflayer
	[8300]={name="Ravage",zone="Blasted Lands",level=51,type="rare",creatureType="Beast"},  -- Ravage
	[8301]={name="Clack the Reaver",zone="Blasted Lands",level=53,type="rare",creatureType="Beast"},  -- Clack the Reaver
	[8302]={name="Deatheye",zone="Blasted Lands",level=49,type="rare",creatureType="Beast"},  -- Deatheye
	[8303]={name="Grunter",zone="Blasted Lands",level=50,type="rare",creatureType="Beast"},  -- Grunter
	[8304]={name="Dreadscorn",zone="Blasted Lands",level=57,type="rare",creatureType="Humanoid"},  -- Dreadscorn
	[8400]={name="Obsidion",zone="Searing Gorge",level=52,type="elite",creatureType="Elemental"},  -- Obsidion
	[8447]={name="Clunk",zone="Searing Gorge",level=48,type="elite",creatureType="Mechanical"},  -- Clunk
	[8503]={name="Gibblewilt",zone="Dun Morogh",level=11,type="rare",creatureType="Humanoid"},  -- Gibblewilt
	[8504]={name="Dark Iron Sentry",zone="Searing Gorge",level=48,type="elite",creatureType="Humanoid"},  -- Dark Iron Sentry
	[8610]={name="Kroum",zone="Azshara",level=55,type="elite",creatureType="Humanoid"},  -- Kroum
	[8636]={name="Morta'gya the Keeper",zone="The Hinterlands",level=50,type="elite",creatureType="Humanoid"},  -- Morta'gya the Keeper
	[8660]={name="The Evalcharr",zone="Azshara",level=48,type="rare",creatureType="Beast"},  -- The Evalcharr
	[8716]={name="Dreadlord",zone="Blasted Lands",level=62,type="elite",creatureType="Demon"},  -- Dreadlord
	[8717]={name="Felguard Elite",zone="Blasted Lands",level=61,type="elite",creatureType="Demon"},  -- Felguard Elite
	[8718]={name="Manahound",zone="Blasted Lands",level=60,type="elite",creatureType="Demon"},  -- Manahound
	[8923]={name="Panzor the Invincible",zone="Blackrock Depths",level=57,type="rareelite",creatureType="Elemental"},  -- Panzor the Invincible
	[8924]={name="The Behemoth",zone="Blackrock Depths",level=50,type="rareelite",creatureType="Humanoid"},  -- The Behemoth
	[8976]={name="Hematos",zone="Burning Steppes",level=60,type="rareelite",creatureType="Dragonkin"},  -- Hematos
	[8978]={name="Thauris Balgarr",zone="Burning Steppes",level=57,type="rare",creatureType="Humanoid"},  -- Thauris Balgarr
	[8979]={name="Gruklash",zone="Burning Steppes",level=59,type="rare",creatureType="Humanoid"},  -- Gruklash
	[8981]={name="Malfunctioning Reaver",zone="Burning Steppes",level=56,type="rare",creatureType="Elemental"},  -- Malfunctioning Reaver
	[9024]={name="Pyromancer Loregrain",zone="Blackrock Depths",level=52,type="rareelite",creatureType="Humanoid"},  -- Pyromancer Loregrain
	[9025]={name="Lord Roccor",zone="Blackrock Depths",level=51,type="rareelite",creatureType="Elemental"},  -- Lord Roccor
	[9041]={name="Warder Stilgiss",zone="Blackrock Depths",level=56,type="rareelite",creatureType="Humanoid"},  -- Warder Stilgiss
	[9042]={name="Verek",zone="Blackrock Depths",level=55,type="rareelite",creatureType="Demon"},  -- Verek
	[9046]={name="Scarshield Quartermaster",zone="Stranglethorn Vale",level=55,type="rareelite",creatureType="Humanoid"},  -- Scarshield Quartermaster
	[9217]={name="Spirestone Lord Magus",zone="Blackrock Spire",level=58,type="rareelite",creatureType="Humanoid"},  -- Spirestone Lord Magus
	[9218]={name="Spirestone Battle Lord",zone="Blackrock Spire",level=58,type="rareelite",creatureType="Humanoid"},  -- Spirestone Battle Lord
	[9219]={name="Spirestone Butcher",zone="Blackrock Spire",level=57,type="rareelite",creatureType="Humanoid"},  -- Spirestone Butcher
	[9376]={name="Blazerunner",zone="Un'Goro Crater",level=56,type="elite",creatureType="Elemental"},  -- Blazerunner
	[9447]={name="Scarlet Warder",zone="Eastern Plaguelands",level=54,type="elite",creatureType="Humanoid"},  -- Scarlet Warder
	[9448]={name="Scarlet Praetorian",zone="Eastern Plaguelands",level=57,type="elite",creatureType="Humanoid"},  -- Scarlet Praetorian
	[9449]={name="Scarlet Cleric",zone="Eastern Plaguelands",level=55,type="elite",creatureType="Humanoid"},  -- Scarlet Cleric
	[9450]={name="Scarlet Curate",zone="Eastern Plaguelands",level=56,type="elite",creatureType="Humanoid"},  -- Scarlet Curate
	[9451]={name="Scarlet Archmage",zone="Eastern Plaguelands",level=57,type="elite",creatureType="Humanoid"},  -- Scarlet Archmage
	[9452]={name="Scarlet Enchanter",zone="Eastern Plaguelands",level=55,type="elite",creatureType="Humanoid"},  -- Scarlet Enchanter
	[9461]={name="Frenzied Black Drake",zone="Burning Steppes",level=54,type="elite",creatureType="Dragonkin"},  -- Frenzied Black Drake
	[9516]={name="Lord Banehollow",zone="Felwood",level=59,type="elite",creatureType="Demon"},  -- Lord Banehollow
	[9520]={name="Grark Lorkrub",zone="Burning Steppes",level=56,type="elite",creatureType="Humanoid"},  -- Grark Lorkrub
	[9596]={name="Bannok Grimaxe",zone="Blackrock Spire",level=59,type="rareelite",creatureType="Humanoid"},  -- Bannok Grimaxe
	[9602]={name="Hahk'Zor",zone="Burning Steppes",level=57,type="rare",creatureType="Humanoid"},  -- Hahk'Zor
	[9604]={name="Gorgon'och",zone="Burning Steppes",level=55,type="rare",creatureType="Humanoid"},  -- Gorgon'och
	[9718]={name="Ghok Bashguud",zone="Blackrock Spire",level=59,type="rareelite",creatureType="Humanoid"},  -- Ghok Bashguud
	[9736]={name="Quartermaster Zigris",zone="Blackrock Spire",level=59,type="rareelite",creatureType="Humanoid"},  -- Quartermaster Zigris
	[10077]={name="Deathmaw",zone="Burning Steppes",level=59,type="rare",creatureType="Beast"},  -- Deathmaw
	[10078]={name="Terrorspark",zone="Burning Steppes",level=55,type="rare",creatureType="Demon"},  -- Terrorspark
	[10080]={name="Sandarr Dunereaver",zone="Zul'Farrak",level=45,type="rareelite",creatureType="Humanoid"},  -- Sandarr Dunereaver
	[10081]={name="Dustwraith",zone="Zul'Farrak",level=45,type="rareelite",creatureType="Humanoid"},  -- Dustwraith
	[10082]={name="Zerillis",zone="Zul'Farrak",level=45,type="rareelite",creatureType="Humanoid"},  -- Zerillis
	[10119]={name="Volchan",zones={"Redridge Mountains","Burning Steppes"},level=60,type="rareelite",creatureType="Giant"},  -- Volchan
	[10196]={name="General Colbatann",zone="Winterspring",level=56,type="rareelite",creatureType="Dragonkin"},  -- General Colbatann
	[10197]={name="Mezzir the Howler",zone="Winterspring",level=55,type="rare",creatureType="Humanoid"},  -- Mezzir the Howler
	[10198]={name="Kashoch the Reaver",zone="Winterspring",level=60,type="rareelite",creatureType="Giant"},  -- Kashoch the Reaver
	[10199]={name="Grizzle Snowpaw",zone="Winterspring",level=59,type="rare",creatureType="Humanoid"},  -- Grizzle Snowpaw
	[10200]={name="Rak'shiri",zone="Winterspring",level=59,type="rare",creatureType="Beast"},  -- Rak'shiri
	[10201]={name="Lady Hederine",zone="Winterspring",level=61,type="rareelite",creatureType="Demon"},  -- Lady Hederine
	[10202]={name="Azurous",zone="Winterspring",level=59,type="rareelite",creatureType="Dragonkin"},  -- Azurous
	[10204]={name="Misha",zones={"Feralas","Desolace","Stonetalon Mountains"},level=62,type="elite",creatureType="Beast"},  -- Misha
	[10263]={name="Burning Felguard",zone="Blackrock Spire",level=56,type="rareelite",creatureType="Demon"},  -- Burning Felguard
	[10321]={name="Emberstrife",zone="Dustwallow Marsh",level=61,type="elite",creatureType="Dragonkin"},  -- Emberstrife
	[10358]={name="Fellicent's Shade",zone="Tirisfal Glades",level=12,type="rare",creatureType="Undead"},  -- Fellicent's Shade
	[10359]={name="Sri'skulk",zone="Tirisfal Glades",level=13,type="rare",creatureType="Beast"},  -- Sri'skulk
	[10376]={name="Crystal Fang",zone="Blackrock Spire",level=60,type="rareelite",creatureType="Beast"},  -- Crystal Fang
	[10393]={name="Skul",zone="Stratholme",level=58,type="rareelite",creatureType="Undead"},  -- Skul
	[10509]={name="Jed Runewatcher",zone="Blackrock Spire",level=59,type="rareelite",creatureType="Humanoid"},  -- Jed Runewatcher
	[10559]={name="Lady Vespia",zone="Ashenvale",level=22,type="rare",creatureType="Humanoid"},  -- Lady Vespia
	[10584]={name="Urok Doomhowl",zone="Blackrock Spire",level=60,type="rareelite",creatureType="Humanoid"},  -- Urok Doomhowl
	[10639]={name="Rorgish Jowl",zone="Ashenvale",level=25,type="rare",creatureType="Humanoid"},  -- Rorgish Jowl
	[10640]={name="Oakpaw",zone="Ashenvale",level=27,type="rare",creatureType="Humanoid"},  -- Oakpaw
	[10641]={name="Branch Snapper",zone="Ashenvale",level=26,type="rare",creatureType="Elemental"},  -- Branch Snapper
	[10642]={name="Eck'alom",zone="Ashenvale",level=27,type="rare",creatureType="Elemental"},  -- Eck'alom
	[10643]={name="Mugglefin",zone="Ashenvale",level=23,type="rare",creatureType="Humanoid"},  -- Mugglefin
	[10644]={name="Mist Howler",zone="Ashenvale",level=22,type="rare",creatureType="Beast"},  -- Mist Howler
	[10647]={name="Prince Raze",zone="Ashenvale",level=32,type="rare",creatureType="Demon"},  -- Prince Raze
	[10662]={name="Spellmaw",zone="Winterspring",level=56,type="elite",creatureType="Dragonkin"},  -- Spellmaw
	[10663]={name="Manaclaw",zone="Winterspring",level=58,type="elite",creatureType="Dragonkin"},  -- Manaclaw
	[10664]={name="Scryer",zone="Winterspring",level=60,type="elite",creatureType="Dragonkin"},  -- Scryer
	[10737]={name="Shy-Rotam",zone="Winterspring",level=60,type="elite",creatureType="Beast"},  -- Shy-Rotam
	[10738]={name="High Chief Winterfall",zone="Winterspring",level=59,type="elite",creatureType="Humanoid"},  -- High Chief Winterfall
	[10741]={name="Sian-Rotam",zone="Winterspring",level=60,type="elite",creatureType="Beast"},  -- Sian-Rotam
	[10802]={name="Hitah'ya the Keeper",zone="The Hinterlands",level=51,type="elite",creatureType="Humanoid"},  -- Hitah'ya the Keeper
	[10806]={name="Ursius",zone="Winterspring",level=56,type="elite",creatureType="Beast"},  -- Ursius
	[10807]={name="Brumeran",zone="Winterspring",level=58,type="elite",creatureType="Beast"},  -- Brumeran
	[10808]={name="Timmy the Cruel",zone="Stratholme",level=58,type="rareelite",creatureType="Undead"},  -- Timmy the Cruel
	[10809]={name="Stonespine",zone="Stratholme",level=60,type="rareelite",creatureType="Undead"},  -- Stonespine
	[10821]={name="Hed'mush the Rotting",zone="Eastern Plaguelands",level=57,type="rare",creatureType="Undead"},  -- Hed'mush the Rotting
	[10822]={name="Warlord Thresh'jin",zone="Eastern Plaguelands",level=58,type="rare",creatureType="Humanoid"},  -- Warlord Thresh'jin
	[10823]={name="Zul'Brin Warpbranch",zone="Eastern Plaguelands",level=60,type="rare",creatureType="Humanoid"},  -- Zul'Brin Warpbranch
	[10825]={name="Gish the Unmoving",zone="Eastern Plaguelands",level=57,type="rare",creatureType="Undead"},  -- Gish the Unmoving
	[10826]={name="Lord Darkscythe",zone="Eastern Plaguelands",level=57,type="rare",creatureType="Undead"},  -- Lord Darkscythe
	[10827]={name="Deathspeaker Selendre",zone="Eastern Plaguelands",level=56,type="rare",creatureType="Humanoid"},  -- Deathspeaker Selendre
	[10828]={name="High General Abbendis",zone="Eastern Plaguelands",level=59,type="rareelite",creatureType="Humanoid"},  -- High General Abbendis
	[10939]={name="Marduk the Black",zone="Eastern Plaguelands",level=58,type="elite",creatureType="Undead"},  -- Marduk the Black
	[10946]={name="Horgus the Ravager",zone="Eastern Plaguelands",level=60,type="elite",creatureType="Undead"},  -- Horgus the Ravager
	[10992]={name="Enraged Panther",zone="Thousand Needles",level=30,type="elite",creatureType="Beast"},  -- Enraged Panther
	[10996]={name="Fallen Hero",zones={"Western Plaguelands","Tirisfal Glades","Eastern Plaguelands"},level=60,type="elite",creatureType="Undead"},  -- Fallen Hero
	[11022]={name="Alexi Barov",zone="Tirisfal Glades",level=60,type="elite",creatureType="Humanoid"},  -- Alexi Barov
	[11141]={name="Spirit of Trey Lightforge",zone="Felwood",level=53,type="elite",creatureType="Undead"},  -- Spirit of Trey Lightforge
	[11355]={name="Gurubashi Warrior",zone="Stranglethorn Vale",level=55,type="elite",creatureType="Humanoid"},  -- Gurubashi Warrior
	[11443]={name="Gordok Ogre-Mage",zone="Feralas",level=53,type="elite",creatureType="Humanoid"},  -- Gordok Ogre-Mage
	[11447]={name="Mushgog",zone="Feralas",level=60,type="rareelite",creatureType="Elemental"},  -- Mushgog
	[11497]={name="The Razza",zone="Feralas",level=60,type="rareelite",creatureType="Beast"},  -- The Razza
	[11498]={name="Skarr the Unbreakable",zone="Feralas",level=58,type="rareelite",creatureType="Humanoid"},  -- Skarr the Unbreakable
	[11688]={name="Cursed Centaur",zone="Desolace",level=43,type="rare",creatureType="Humanoid"},  -- Cursed Centaur
	[11698]={name="Hive'Ashi Stinger",zone="Silithus",level=58,type="elite",creatureType="Silithid"},  -- Hive'Ashi Stinger
	[11724]={name="Hive'Ashi Swarmer",zone="Silithus",level=58,type="elite",creatureType="Silithid"},  -- Hive'Ashi Swarmer
	[11726]={name="Hive'Zora Tunneler",zone="Silithus",level=59,type="elite",creatureType="Silithid"},  -- Hive'Zora Tunneler
	[11730]={name="Hive'Regal Ambusher",zone="Silithus",level=60,type="elite",creatureType="Silithid"},  -- Hive'Regal Ambusher
	[11733]={name="Hive'Regal Slavemaker",zone="Silithus",level=60,type="elite",creatureType="Silithid"},  -- Hive'Regal Slavemaker
	[11734]={name="Hive'Regal Hive Lord",zone="Silithus",level=61,type="elite",creatureType="Silithid"},  -- Hive'Regal Hive Lord
	[11777]={name="Shadowshard Rumbler",zone="Desolace",level=41,type="elite",creatureType="Elemental"},  -- Shadowshard Rumbler
	[11781]={name="Ambershard Crusher",zone="Desolace",level=41,type="elite",creatureType="Elemental"},  -- Ambershard Crusher
	[11782]={name="Ambershard Destroyer",zone="Desolace",level=43,type="elite",creatureType="Elemental"},  -- Ambershard Destroyer
	[11786]={name="Ambereye Reaver",zone="Desolace",level=42,type="elite",creatureType="Beast"},  -- Ambereye Reaver
	[11878]={name="Nathanos Blightcaller",zone="Eastern Plaguelands",level=62,type="elite",creatureType="Humanoid"},  -- Nathanos Blightcaller
	[11896]={name="Borelgore",zone="Eastern Plaguelands",level=61,type="elite",creatureType="Beast"},  -- Borelgore
	[11897]={name="Duskwing",zone="Eastern Plaguelands",level=60,type="elite",creatureType="Beast"},  -- Duskwing
	[11898]={name="Crusader Lord Valdelmar",zone="Eastern Plaguelands",level=60,type="elite",creatureType="Humanoid"},  -- Crusader Lord Valdelmar
	[11900]={name="Brakkar",zone="Felwood",level=55,type="elite",creatureType="Humanoid"},  -- Brakkar
	[11901]={name="Andruk",zone="Ashenvale",level=55,type="elite",creatureType="Humanoid"},  -- Andruk
	[11921]={name="Besseleth",zone="Stonetalon Mountains",level=21,type="elite",creatureType="Beast"},  -- Besseleth
	[12037]={name="Ursol'lok",zone="Ashenvale",level=32,type="rare",creatureType="Beast"},  -- Ursol'lok
	[12123]={name="Reef Shark",zones={"Westfall","Darkshore","Silverpine Forest"},level=22,type="elite",creatureType="Beast"},  -- Reef Shark
	[12125]={name="Mammoth Shark",zones={"Durotar","Azshara"},level=56,type="elite",creatureType="Beast"},  -- Mammoth Shark
	[12128]={name="Crimson Elite",zone="Western Plaguelands",level=60,type="elite",creatureType="Humanoid"},  -- Crimson Elite
	[12237]={name="Meshlok the Harvester",zone="Maraudon",level=48,type="rareelite",creatureType="Elemental"},  -- Meshlok the Harvester
	[12262]={name="Ziggurat Protector",zone="Eastern Plaguelands",level=58,type="elite",creatureType="Undead"},  -- Ziggurat Protector
	[12337]={name="Crimson Courier",zone="Eastern Plaguelands",level=60,type="elite",creatureType="Humanoid"},  -- Crimson Courier
	[12339]={name="Demetria",zone="Eastern Plaguelands",level=61,type="elite",creatureType="Humanoid"},  -- Demetria
	[12396]={name="Doomguard Commander",zone="Blasted Lands",level=61,type="elite",creatureType="Demon"},  -- Doomguard Commander
	[12432]={name="Old Vicejaw",zone="Silverpine Forest",level=14,type="rare",creatureType="Beast"},  -- Old Vicejaw
	[12474]={name="Emeraldon Boughguard",zone="Ashenvale",level=62,type="elite",creatureType="Dragonkin"},  -- Emeraldon Boughguard
	[12475]={name="Emeraldon Tree Warder",zones={"Ashenvale","Orgrimmar"},level=60,type="elite",creatureType="Dragonkin"},  -- Emeraldon Tree Warder
	[12476]={name="Emeraldon Oracle",zones={"Ashenvale","Orgrimmar"},level=61,type="elite",creatureType="Dragonkin"},  -- Emeraldon Oracle
	[12477]={name="Verdantine Boughguard",zone="The Hinterlands",level=62,type="elite",creatureType="Dragonkin"},  -- Verdantine Boughguard
	[12496]={name="Dreamtracker",zone="The Hinterlands",level=62,type="elite",creatureType="Dragonkin"},  -- Dreamtracker
	[12497]={name="Dreamroarer",zone="Feralas",level=62,type="elite",creatureType="Dragonkin"},  -- Dreamroarer
	[12498]={name="Dreamstalker",zone="Ashenvale",level=62,type="elite",creatureType="Dragonkin"},  -- Dreamstalker
	[12579]={name="Bloodfury Ripper",zone="Stonetalon Mountains",level=26,type="elite",creatureType="Humanoid"},  -- Bloodfury Ripper
	[12740]={name="Faustron",zone="Moonglade",level=55,type="elite",creatureType="Humanoid"},  -- Faustron
	[12800]={name="Chimaerok",zone="Feralas",level=61,type="elite",creatureType="Beast"},  -- Chimaerok
	[12801]={name="Arcane Chimaerok",zone="Feralas",level=62,type="elite",creatureType="Beast"},  -- Arcane Chimaerok
	[12802]={name="Chimaerok Devourer",zone="Feralas",level=62,type="elite",creatureType="Beast"},  -- Chimaerok Devourer
	[12803]={name="Lord Lakmaeran",zone="Feralas",level=62,type="elite",creatureType="Beast"},  -- Lord Lakmaeran
	[12864]={name="Warsong Outrider",zone="Ashenvale",level=30,type="normal",creatureType="Humanoid",roams=true},  -- Warsong Outrider
	[12865]={name="Ambassador Malcin",zone="The Barrens",level=36,type="elite",creatureType="Undead"},  -- Ambassador Malcin
	[12899]={name="Axtroz",zone="Wetlands",level=62,type="elite",creatureType="Dragonkin",include=false},  -- Axtroz
	[12900]={name="Somnus",zone="Swamp of Sorrows",level=62,type="elite",creatureType="Dragonkin"},  -- Somnus
	[13082]={name="Milton Beats",zone="Hillsbrad Foothills",level=33,type="elite",creatureType="Humanoid"},  -- Milton Beats
	[13177]={name="Vahgruk",zone="Burning Steppes",level=55,type="elite",creatureType="Humanoid"},  -- Vahgruk
	[13219]={name="Jekyll Flandring",zone="Alterac Mountains",level=58,type="elite",creatureType="Humanoid"},  -- Jekyll Flandring
	[13718]={name="The Nameless Prophet",zone="Desolace",level=41,type="elite",creatureType="Humanoid"},  -- The Nameless Prophet
	[13839]={name="Royal Dreadguard",zone="Undercity",level=60,type="elite",creatureType="Humanoid"},  -- Royal Dreadguard
	[13840]={name="Warmaster Laggrond",zone="Alterac Mountains",level=61,type="elite",creatureType="Humanoid"},  -- Warmaster Laggrond
	[14221]={name="Gravis Slipknot",zone="Alterac Mountains",level=36,type="rare",creatureType="Humanoid"},  -- Gravis Slipknot
	[14222]={name="Araga",zone="Alterac Mountains",level=35,type="rare",creatureType="Beast"},  -- Araga
	[14225]={name="Prince Kellen",zone="Desolace",level=33,type="rare",creatureType="Demon"},  -- Prince Kellen
	[14226]={name="Kaskk",zone="Desolace",level=40,type="rare",creatureType="Demon"},  -- Kaskk
	[14227]={name="Hissperak",zone="Desolace",level=37,type="rare",creatureType="Beast"},  -- Hissperak
	[14228]={name="Giggler",zone="Desolace",level=35,type="rare",creatureType="Beast"},  -- Giggler
	[14229]={name="Accursed Slitherblade",zone="Desolace",level=38,type="rare",creatureType="Humanoid"},  -- Accursed Slitherblade
	[14230]={name="Burgle Eye",zone="Dustwallow Marsh",level=38,type="rare",creatureType="Humanoid"},  -- Burgle Eye
	[14231]={name="Drogoth the Roamer",zone="Dustwallow Marsh",level=37,type="rare",creatureType="Elemental"},  -- Drogoth the Roamer
	[14232]={name="Dart",zone="Dustwallow Marsh",level=38,type="rare",creatureType="Beast"},  -- Dart
	[14233]={name="Ripscale",zone="Dustwallow Marsh",level=39,type="rare",creatureType="Beast"},  -- Ripscale
	[14234]={name="Hayoc",zone="Dustwallow Marsh",level=43,type="rare",creatureType="Beast"},  -- Hayoc
	[14235]={name="The Rot",zone="Dustwallow Marsh",level=44,type="rare",creatureType="Slime"},  -- The Rot
	[14236]={name="Lord Angler",zone="Dustwallow Marsh",level=48,type="rare",creatureType="Humanoid"},  -- Lord Angler
	[14237]={name="Oozeworm",zone="Dustwallow Marsh",level=42,type="rare",creatureType="Beast"},  -- Oozeworm
	[14266]={name="Shanda the Spinner",zone="Loch Modan",level=25,type="rare",creatureType="Beast"},  -- Shanda the Spinner
	[14267]={name="Emogg the Crusher",zone="Loch Modan",level=19,type="rareelite",creatureType="Humanoid"},  -- Emogg the Crusher
	[14268]={name="Lord Condar",zone="Loch Modan",level=16,type="rare",creatureType="Beast"},  -- Lord Condar
	[14269]={name="Seeker Aqualon",zone="Redridge Mountains",level=21,type="rare",creatureType="Elemental"},  -- Seeker Aqualon
	[14270]={name="Squiddic",zone="Redridge Mountains",level=19,type="rare",creatureType="Humanoid"},  -- Squiddic
	[14271]={name="Ribchaser",zone="Redridge Mountains",level=17,type="rare",creatureType="Humanoid"},  -- Ribchaser
	[14272]={name="Snarlflare",zone="Redridge Mountains",level=18,type="rare",creatureType="Dragonkin"},  -- Snarlflare
	[14273]={name="Boulderheart",zone="Redridge Mountains",level=25,type="rare",creatureType="Giant"},  -- Boulderheart
	[14276]={name="Scargil",zone="Hillsbrad Foothills",level=30,type="rare",creatureType="Humanoid"},  -- Scargil
	[14277]={name="Lady Zephris",zone="Hillsbrad Foothills",level=33,type="rare",creatureType="Humanoid"},  -- Lady Zephris
	[14278]={name="Ro'Bark",zone="Hillsbrad Foothills",level=28,type="rare",creatureType="Humanoid"},  -- Ro'Bark
	[14279]={name="Creepthess",zone="Hillsbrad Foothills",level=24,type="rare",creatureType="Beast"},  -- Creepthess
	[14280]={name="Big Samras",zone="Hillsbrad Foothills",level=27,type="rare",creatureType="Beast"},  -- Big Samras
	[14281]={name="Jimmy the Bleeder",zone="Alterac Mountains",level=23,type="rare",creatureType="Humanoid"},  -- Jimmy the Bleeder
	[14339]={name="Death Howl",zone="Felwood",level=49,type="rare",creatureType="Beast"},  -- Death Howl
	[14340]={name="Alshirr Banebreath",zone="Felwood",level=54,type="rare",creatureType="Demon"},  -- Alshirr Banebreath
	[14342]={name="Ragepaw",zone="Felwood",level=51,type="rare",creatureType="Humanoid"},  -- Ragepaw
	[14344]={name="Mongress",zone="Felwood",level=50,type="rare",creatureType="Beast"},  -- Mongress
	[14345]={name="The Ongar",zone="Felwood",level=51,type="rare",creatureType="Slime"},  -- The Ongar
	[14357]={name="Lake Thresher",zone="Redridge Mountains",level=25,type="elite",creatureType="Beast"},  -- Lake Thresher
	[14377]={name="Scout Tharr",zone="Orgrimmar",level=60,type="elite",creatureType="Humanoid"},  -- Scout Tharr
	[14388]={name="Rogue Black Drake",zone="Burning Steppes",level=52,type="elite",creatureType="Dragonkin"},  -- Rogue Black Drake
	[14392]={name="Overlord Runthak",zone="Orgrimmar",level=60,type="elite",creatureType="Humanoid"},  -- Overlord Runthak
	[14424]={name="Mirelow",zone="Wetlands",level=25,type="rare",creatureType="Elemental"},  -- Mirelow
	[14425]={name="Gnawbone",zone="Wetlands",level=25,type="rare",creatureType="Humanoid"},  -- Gnawbone
	[14426]={name="Harb Foulmountain",zone="Thousand Needles",level=27,type="rare",creatureType="Humanoid"},  -- Harb Foulmountain
	[14427]={name="Gibblesnik",zone="Thousand Needles",level=28,type="rare",creatureType="Humanoid"},  -- Gibblesnik
	[14428]={name="Uruson",zone="Teldrassil",level=8,type="rare",creatureType="Humanoid"},  -- Uruson
	[14429]={name="Grimmaw",zone="Teldrassil",level=11,type="rare",creatureType="Humanoid"},  -- Grimmaw
	[14430]={name="Duskstalker",zone="Teldrassil",level=9,type="rare",creatureType="Beast"},  -- Duskstalker
	[14431]={name="Fury Shelda",zone="Teldrassil",level=8,type="rare",creatureType="Humanoid"},  -- Fury Shelda
	[14432]={name="Threggil",zone="Teldrassil",level=6,type="rare",creatureType="Demon"},  -- Threggil
	[14433]={name="Sludginn",zone="Wetlands",level=30,type="rare",creatureType="Slime"},  -- Sludginn
	[14445]={name="Lord Captain Wyrmak",zone="Swamp of Sorrows",level=45,type="rareelite",creatureType="Dragonkin"},  -- Lord Captain Wyrmak
	[14446]={name="Fingat",zone="Swamp of Sorrows",level=43,type="rare",creatureType="Humanoid"},  -- Fingat
	[14447]={name="Gilmorian",zone="Swamp of Sorrows",level=44,type="rare",creatureType="Humanoid"},  -- Gilmorian
	[14448]={name="Molt Thorn",zone="Swamp of Sorrows",level=42,type="rare",creatureType="Elemental"},  -- Molt Thorn
	[14454]={name="The Windreaver",zone="Silithus",level=60,type="elite",creatureType="Elemental"},  -- The Windreaver
	[14457]={name="Princess Tempestria",zone="Winterspring",level=60,type="elite",creatureType="Elemental"},  -- Princess Tempestria
	[14461]={name="Baron Charr",zone="Un'Goro Crater",level=58,type="elite",creatureType="Elemental"},  -- Baron Charr
	[14464]={name="Avalanchion",zone="Azshara",level=58,type="elite",creatureType="Elemental"},  -- Avalanchion
	[14471]={name="Setis",zone="Silithus",level=62,type="rareelite",creatureType="Humanoid"},  -- Setis
	[14472]={name="Gretheer",zone="Silithus",level=58,type="rare",creatureType="Beast"},  -- Gretheer
	[14473]={name="Lapress",zone="Silithus",level=60,type="rareelite",creatureType="Silithid"},  -- Lapress
	[14474]={name="Zora",zone="Silithus",level=59,type="rareelite",creatureType="Silithid"},  -- Zora
	[14475]={name="Rex Ashil",zone="Silithus",level=57,type="rareelite",creatureType="Silithid"},  -- Rex Ashil
	[14476]={name="Krellack",zone="Silithus",level=56,type="rare",creatureType="Beast"},  -- Krellack
	[14477]={name="Grubthor",zone="Silithus",level=58,type="rare",creatureType="Beast"},  -- Grubthor
	[14478]={name="Huricanian",zone="Silithus",level=58,type="rare",creatureType="Elemental"},  -- Huricanian
	[14479]={name="Twilight Lord Everun",zone="Silithus",level=60,type="rare",creatureType="Humanoid"},  -- Twilight Lord Everun
	[14487]={name="Gluggle",zone="Stranglethorn Vale",level=37,type="rare",creatureType="Humanoid"},  -- Gluggle
	[14488]={name="Roloch",zone="Stranglethorn Vale",level=38,type="rare",creatureType="Humanoid"},  -- Roloch
	[14490]={name="Rippa",zone="Stranglethorn Vale",level=44,type="rare",creatureType="Beast"},  -- Rippa
	[14491]={name="Kurmokk",zone="Stranglethorn Vale",level=42,type="rare",creatureType="Beast"},  -- Kurmokk
	[14492]={name="Verifonix",zone="Stranglethorn Vale",level=42,type="rare",creatureType="Humanoid"},  -- Verifonix
	[14503]={name="The Cleaner",zone="Eastern Plaguelands",level=63,type="elite",creatureType="Demon"},  -- The Cleaner
	[14621]={name="Overseer Maltorius",zone="Searing Gorge",level=50,type="elite",creatureType="Humanoid"},  -- Overseer Maltorius
	[15126]={name="Rutherford Twing",zone="Arathi Highlands",level=55,type="elite",creatureType="Humanoid"},  -- Rutherford Twing
	[15195]={name="Wickerman Guardian",zone="Tirisfal Glades",level=60,type="elite",creatureType="Undead"},  -- Wickerman Guardian
	[15196]={name="Deathclasp",zone="Silithus",level=59,type="elite",creatureType="Beast"},  -- Deathclasp
	[15206]={name="The Duke of Cynders",zone="Silithus",level=62,type="elite",creatureType="Humanoid"},  -- The Duke of Cynders
	[15207]={name="The Duke of Fathoms",zone="Silithus",level=62,type="elite",creatureType="Hydra"},  -- The Duke of Fathoms
	[15208]={name="The Duke of Shards",zone="Silithus",level=62,type="elite",creatureType="Giant"},  -- The Duke of Shards
	[15209]={name="Crimson Templar",zone="Silithus",level=60,type="elite",creatureType="Elemental"},  -- Crimson Templar
	[15211]={name="Azure Templar",zone="Silithus",level=60,type="elite",creatureType="Elemental"},  -- Azure Templar
	[15212]={name="Hoary Templar",zone="Silithus",level=60,type="elite",creatureType="Elemental"},  -- Hoary Templar
	[15215]={name="Mistress Natalia Mar'alith",zone="Silithus",level=62,type="elite",creatureType="Humanoid"},  -- Mistress Natalia Mar'alith
	[15220]={name="The Duke of Zephyrs",zone="Silithus",level=62,type="elite",creatureType="Beast"},  -- The Duke of Zephyrs
	[15307]={name="Earthen Templar",zone="Silithus",level=60,type="elite",creatureType="Elemental"},  -- Earthen Templar
	[15308]={name="Twilight Prophet",zone="Silithus",level=60,type="elite",creatureType="Humanoid"},  -- Twilight Prophet
	[15449]={name="Hive'Zora Abomination",zone="Silithus",level=60,type="elite",creatureType="Silithid"},  -- Hive'Zora Abomination
	[15541]={name="Twilight Marauder Morna",zone="Silithus",level=60,type="elite",creatureType="Humanoid"},  -- Twilight Marauder Morna
	[15552]={name="Doctor Weavil",zones={"Dustwallow Marsh","Winterspring"},level=63,type="elite",creatureType="Humanoid"},  -- Doctor Weavil
	[15554]={name="Number Two",zone="Winterspring",level=61,type="elite",creatureType="Beast"},  -- Number Two
	[15591]={name="Minion of Weavil",zone="Dustwallow Marsh",level=61,type="elite",creatureType="Humanoid"},  -- Minion of Weavil
	[15612]={name="Krug Skullsplit",zone="Silithus",level=60,type="elite",creatureType="Humanoid"},  -- Krug Skullsplit
	[15620]={name="Hive'Regal Hunter-Killer",zone="Silithus",level=60,type="elite",creatureType="Silithid"},  -- Hive'Regal Hunter-Killer
	[15623]={name="Xandivious",zone="Winterspring",level=62,type="elite",creatureType="Demon"},  -- Xandivious
	[16072]={name="Tidelord Rrurgaz",zone="Dustwallow Marsh",level=62,type="elite",creatureType="Humanoid"},  -- Tidelord Rrurgaz
	[16184]={name="Nerubian Overseer",zone="Eastern Plaguelands",level=60,type="elite",creatureType="Undead"},  -- Nerubian Overseer
	[210549]={name="Defias Scout",zone="Westfall",level=15,type="elite",creatureType="Humanoid"},  -- Defias Scout
	[221264]={name="Dreamharvester",zone="Ashenvale",level=41,type="elite",creatureType="Mechanical"},  -- Dreamharvester
}
