# DH-Macros - Design (skeleton, 2026-08-21)

## Concept
Generates ready-to-use macros for players - covers common Hardcore-
relevant needs (examples to refine with Chris: focus/target-of-target,
dismount, release-corpse confirmation, food/drink, flask/buff
reminders, class-specific rotations). Ships as a DH-Tools module.

## Open design questions (resolve before Milestone 1 - README section 14)
1. **Creation mechanism** - write the macro directly into the player's
   macro book via CreateMacro (general vs. per-character macro slots
   both cap at 18 in this client; combat/protected-call behavior needs
   verifying), or only ever show generated text for the player to
   paste into the Blizzard macro UI themselves, or offer both?
2. **Macro catalog** - which macros ship v1, and are they fixed
   templates or do any take player input (e.g. a name/target)?
3. **Standalone-optionality** - does this stay a plain DHToolsDB.macros
   sub-table (current default, see Core.lua), or does it need its own
   top-level SavedVariables table like DHQuests/DHBavin/DHDanger/DHAir,
   e.g. to save custom/edited macros per character?
4. **UI** - a config page (like Mob Marker/Quests/Bavin), a standalone
   window (like DH-Air/DH-Quests' Board.lua), or something simpler?
5. **Slash command** - name TBD (mm/dhq/dhb/dhair are taken).

## Status
Scaffolded 2026-08-21: folder structure and a minimal Core.lua module
registration stub only (src\DH-Tools\Modules\DHMacros\Core.lua,
DHTools.RegisterModule("macros", ...)). No generation logic yet. See
claude\DH-Macros\STATUS.md.
