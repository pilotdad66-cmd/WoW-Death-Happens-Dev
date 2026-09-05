-- DH-Tools: Modules\DHMacros\MacroLibrary.lua
-- GENERATED FILE - DO NOT HAND-EDIT.
-- Source: claude\DH-Macros\curation\DH-Macros-Library.csv
-- Regenerate: powershell -ExecutionPolicy Bypass -File claude\DH-Macros\import-macros.ps1
-- Generated: 2026-08-23 11:36
--
-- Macro catalog for the Macros module's Board (Class -> Spec -> Macro
-- cascading picker). Edit the CSV, not this file - see that file's
-- header for the column contract, or claude\DH-Macros\import-macros.ps1
-- for the validation rules and Lua-emission format.
--
-- Each class entry: { key, label, specs (ordered list of spec names,
-- nil for General), macros = { [specNameOrFalse] = { entry, ... } } }.
-- A macro filed under `false` (no spec) is class-general - Board.lua
-- shows it no matter which spec is picked, same as when Spec is left
-- at 'Any Spec' (which shows every macro for the class together).

DHMacros = DHMacros or {}
local ns = DHMacros

ns.Library = {
    {
        key = "General", label = "General", specs = nil,
        macros = {
            [false] = {
                { name = "Get The F Out", macroName = "GTFO", icon = "INV_Misc_QuestionMark",
                  body = "/run local i = InviteUnit or C_PartyInfo.InviteUnit i(\"aaa\");C_Timer.After(1,function() LeaveParty() end)",
                  desc = "Macro to leave a group in a dungeon when you are the last one left or alone." },
                { name = "Light of Elune", macroName = "LoE", icon = "INV_Misc_QuestionMark",
                  body = "#showtooltip Light of Elune\n/stopcasting\n/use Light of Elune\n/use Hearthstone",
                  desc = "Macro to use in an emergency. Consumes your Light of Elune and hearths you home. Do NOT test this macro as it will use up your one time LoE item!" },
                { name = "Carrot on a Stick", macroName = "CStick", icon = "INV_Misc_QuestionMark",
                  body = "#showtooltip Your Mount Here\n/equipslot [nomounted] 14 Carrot on a Stick\n/equipslot [mounted] 14 Your Trinket Here\n/dismount [mounted]\n/stand\n/use Your Mount Here",
                  desc = "Macro mounts you and equips Carrot on a Stick, or dismounts you and equips your other trinket back (e.g. Nifty Stopwatch) in that slot. You must edit the mount name and the trinket name to match whatever you are using." },
            },
        },
    },
    {
        key = "WARRIOR", label = "Warrior", specs = { "Arms", "Fury", "Protection" },
        macros = {
            [false] = {
                { name = "1H/2H Swap", macroName = "1H/2H Swap", icon = "INV_Misc_QuestionMark",
                  body = "#showtooltip\n/equip [noequipped:Shields] Exact 1H Weapon Name\n/equip [noequipped:Shields] Exact Shield Name\n/equip [equipped:Shields] Exact 2H Weapon Name",
                  desc = "Swaps your 2H weapon with a 1H weapon and a Shield, useful when you need a burst of extra defense. You must edit the names of the shield and the weapons to match whatever you are using." },
            },
        },
    },
    {
        key = "PALADIN", label = "Paladin", specs = { "Holy", "Protection", "Retribution" },
        macros = {
            [false] = {
                { name = "1H/2H Swap", macroName = "1H/2H Swap", icon = "INV_Misc_QuestionMark",
                  body = "#showtooltip\n/equip [noequipped:Shields] Exact 1H Weapon Name\n/equip [noequipped:Shields] Exact Shield Name\n/equip [equipped:Shields] Exact 2H Weapon Name",
                  desc = "Swaps your 2H weapon with a 1H weapon and a Shield, useful when you need a burst of extra defense. You must edit the names of the shield and the weapons to match whatever you are using." },
            },
        },
    },
    {
        key = "HUNTER", label = "Hunter", specs = { "Beast Mastery", "Marksmanship", "Survival" },
        macros = {
            [false] = {
                { name = "Explosive Trap in Combat", macroName = "ETrap", icon = "INV_Misc_QuestionMark",
                  body = "#showtooltip Explosive Trap\n/stopattack\n/petstay [combat, @pettarget, harm]\n/petpassive [combat, @pettarget, harm]\n/cast [combat] Feign Death\n/cast Explosive Trap\n/petfollow [nocombat]\n/petdefensive [nocombat]\n/script UIErrorsFrame:Clear()",
                  desc = "Macro to lay down an explosive trap while in combat. First click (in combat): pet goes Stay+Passive and you Feign Death. Second click (once you're actually out of combat): the trap is laid and your pet returns to Follow+Defensive." },
                { name = "Freezing Trap in Combat", macroName = "FTrap", icon = "INV_Misc_QuestionMark",
                  body = "#showtooltip Freezing Trap\n/stopattack\n/petstay [combat, @pettarget, harm]\n/petpassive [combat, @pettarget, harm]\n/cast [combat] Feign Death\n/cast Freezing Trap\n/petfollow [nocombat]\n/petdefensive [nocombat]\n/script UIErrorsFrame:Clear()",
                  desc = "Macro to lay down a freezing trap while in combat. First click (in combat): pet goes Stay+Passive and you Feign Death. Second click (once you're actually out of combat): the trap is laid and your pet returns to Follow+Defensive." },
                { name = "Frost Trap in Combat", macroName = "FstTrap", icon = "INV_Misc_QuestionMark",
                  body = "#showtooltip Frost Trap\n/stopattack\n/petstay [combat, @pettarget, harm]\n/petpassive [combat, @pettarget, harm]\n/cast [combat] Feign Death\n/cast Frost Trap\n/petfollow [nocombat]\n/petdefensive [nocombat]\n/script UIErrorsFrame:Clear()",
                  desc = "Macro to lay down a frost trap while in combat. First click (in combat): pet goes Stay+Passive and you Feign Death. Second click (once you're actually out of combat): the trap is laid and your pet returns to Follow+Defensive." },
            },
        },
    },
    {
        key = "WARLOCK", label = "Warlock", specs = { "Affliction", "Demonology", "Destruction" },
        macros = {
            [false] = {
                { name = "Summon", macroName = "Summon", icon = "INV_Misc_QuestionMark",
                  body = "#showtooltip\n/cast Ritual of Summoning\n/say Summoning %t now. click!\n/run local t,c=\"target\",IsInRaid() and \"RAID\" or \"PARTY\" if UnitIsPlayer(t) then SendChatMessage(\"Summoning \"..UnitName(t)..\" now. click!\",c) end",
                  desc = "Macro to cast summon and broadcast for clicks." },
            },
        },
    },
}
