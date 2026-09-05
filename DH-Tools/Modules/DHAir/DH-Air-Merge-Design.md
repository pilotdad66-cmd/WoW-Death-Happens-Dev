# DH-Air-into-DH-Tools Merge Design
created: 2026-08-20 (Chris confirmed all open decisions this session)

## Background

DH-Air shipped as a standalone addon through **v2.2.1** (publish\DH-Air-v2.2.1.zip,
commit bdc3fc2) - the FINAL STANDALONE RELEASE, retested in-game 0 errors,
harness 564/564. That release is done and is not touched by this doc.

2026-08-20: Chris reversed the 2026-07-17 "DH-Air stays standalone" call
(see ROADMAP.md's Distribution strategy) - DH-Air is archived in its
current form and its functionality merged into DH-Tools as a module,
following the DH-Quests precedent: own subfolder, own namespace, own
top-level SavedVariables, own slash command, so it keeps
standalone-optionality (could be pulled back out later with minimal
surgery) even though it's ending up integrated for the same
passive-adoption reason DH-Bavin and Mob Marker did.

This doc records the confirmed architecture. It does not itself perform
the migration - that's the follow-up task once this is written.

## Confirmed decisions

### 1. SavedVariables - DHAirDB stays its own top-level table, NO data migration
DHAirDB stays exactly as-is: its own account-wide `## SavedVariables:
DHAirDB` entry, declared in DH-Tools.toc alongside
DHToolsDB/DHQuestsDB/DHToolsAccountDB/DHBavinDB. Same precedent as
DH-Bavin (a fully-integrated module keeping its own top-level table).

**Correction surfaced during this design conversation:** keeping the
variable name does NOT preserve any player's existing standalone-DH-Air
data. WoW keys a SavedVariables file to the addon's own folder/.toc, not
to the variable name inside it - DH-Air's current DHAirDB lives in a file
tied to the standalone DH-Air addon. Once DH-Air's code loads from inside
DH-Tools' folder instead, DH-Tools.toc's own `DHAirDB` declaration points
at a different (empty) file. There is no cross-file read available to an
addon at load time, so nothing short of custom migration code could
change this.

**Decision: accept a fresh start.** No migration code. Every player -
including Chris's own account - gets an empty DHAirDB the first time they
run the merged DH-Tools, same as any other first install. Queue
membership, roster registrations, and the officer destination list reset
and get rebuilt; the author-admin flag re-derives itself automatically at
every login regardless (see decision 4) so that specifically is not
affected either way.

### 2. Keep the `_G.DHAir` global, minimal adapter surgery
DH-Air's code keeps exposing itself as `_G.DHAir`, same as it does
standalone today (DH-Quests does the same thing with its own `DHQuests`
global - this is the established "standalone-optionality" idiom, not a
DH-Tools-nested `DHTools.Air.*` namespace).

Consequence for Minimap.lua's existing "DH-Air" adapter submenu: almost
none of it changes, since it already calls into `_G.DHAir` as if DH-Air
were an external addon. Concretely:
- Delete the "not installed" disabled row and its `IsAddOnInstalled("DH-Air")`
  / GetAddOnInfo detection - `_G.DHAir` is now always present once the
  module's files load (RegisterModule pattern, same as every other
  module).
- Config.lua's Tools-page PLACEHOLDER_MODULES status row for DH-Air is
  replaced with a real `DHTools.RegisterModule("air", {...})` checkbox
  entry, same as Mob Marker/Bavin/Quests.
- Everything else in the submenu (Open Board/Config, Set Destination,
  Destination Config gate via `DHAir:HasPermission("edit_destinations")`,
  the action-word quick toggles) is untouched - it already calls the
  same `_G.DHAir` API surface it will after the merge.

### 3. Board/Config/DestinationEditor stay standalone windows
Board.lua, Config.lua, and DestinationEditor.lua keep their own
standalone window chrome, opened from the DH-Tools minimap menu the way
they already are (`Board_Toggle` etc.) - same pattern as Quests' and
Bavin's own bigger windows. No change to this shape.

### 4. Admin override - reuse DHToolsAccountDB.isAuthorAccount
Confirmed (this was the one item STATUS.md flagged as needing explicit
sign-off, given it's a full local admin bypass).

- DH-Air's own `DHAir:IsAuthorAccount()` / `CheckAuthorAccount()`
  PLAYER_LOGIN section is deleted. DH-Tools' own PLAYER_LOGIN handler
  already sets `DHToolsAccountDB.isAuthorAccount` from the same
  hardcoded author-name set (Loopi, Loopidot), and since
  SavedVariables (not PerCharacter) is shared account-wide, it covers
  every alt exactly like DH-Air's own copy did.
- `HasPermission(action)` in DH-Air's Core.lua is rewired to read
  `DHToolsAccountDB.isAuthorAccount` instead of its own
  `DHAirDB.isAuthorAccount`.
- **The existing local-only/never-remote rule is preserved unchanged:**
  this flag stays wired into `HasPermission(action)` only. It is NOT
  added to `UnitHasAuthority(name)`/`IsGuildOfficer(name)`, which
  Sync.lua still calls receive-side with a remote message's claimed
  sender name and must keep verifying only against the real guild
  roster - same reasoning DH-Air's PROFILE.md already documents for its
  own copy, and the same separation DH-Tools' Bavin integration follows
  (`CanManageRecipient()`/`CanEditListLocal()` vs. `CanEditList(name)`).

- DH-Air's dedicated "Account-wide author-admin override" test-harness
  section is removed from Modules\DHAir\tests\ (its scenarios - PLAYER_LOGIN
  as Loopi, flag surviving an alt switch - are already covered by
  DH-Tools' own harness coverage of `DHToolsAccountDB`).
- **Implementation-time check:** grep DH-Air's Core.lua/Queue.lua/etc.
  for any other direct reads of `DHAirDB.isAuthorAccount` (e.g. a UI
  string showing admin status) and repoint those too - `HasPermission`
  is the known call site but shouldn't be assumed to be the only one
  until checked.
- The older, separate "Loopidot"-hardcoded-name mechanism
  (`UnitHasAuthority`/`IsGuildOfficer` in DH-Air's Core.lua) is untouched
  by this decision - it's a different mechanism, already tracked
  separately in ROADMAP.md's pre-public-release removal checklist.

### 5. Tests move to Modules\DHAir\tests\
No build-script changes needed - `build-test-zip.ps1` and
`build-release-zip.ps1` already strip any folder literally named
`tests` at any depth (fixed 2026-07-27 for DH-Quests' own nested
tests\ folder).

### 6. One changelog, not two
DH-Air stops being its own release with its own version number and its
own DH-Air-Description.md. A short "DH-Air" section gets folded into
DH-Tools-Description.md's changelog going forward instead. Historical
DH-Air-Description.md stays in git history at its old path; not carried
forward as a live file.

### 7. Archive: git tag + full literal source zip
Before any files move:
- Tag the current commit (e.g. `dh-air-standalone-final`) - exact git
  revert point, same idea as the DH-Quests-retirement precedent (its old
  src\DH-Quests\ scaffold was retired 2026-07-18). Note: DH-Quests'
  leftover Design.md at that old path was itself moved into
  Modules\DHQuests\ on 2026-08-20 (this session, prompted by Chris
  noticing the inconsistency) - so DH-Air's own docs moving fully into
  Modules\DHAir\ (this doc included) is now the consistent pattern across
  every module, not an exception.
- **Also make one full literal zip of src\DH-Air\ as-is** - everything,
  including tests\, every `*-Design.md`, any `.ps1`, Libs\, the works -
  saved outside git (a location under ROOT, not publish\ or test-builds\,
  since neither of those is meant to hold a full source tree) as a
  tool-independent snapshot. Confirmed as wanted in addition to the git
  tag, not instead of it.
- `publish\DH-Air-v2.2.1.zip` stays where it is too. Worth remembering
  it is a **runtime-only** build (release script strips tests\,
  `*-Design.md`, `.ps1`, and any `.lua` the .toc doesn't reference per
  ROADMAP.md's packaging rules) - it's the last standalone-installable
  build, not a complete source snapshot; the new literal zip above is
  what covers that.

## Migration sequence (next task, once this doc is written)

1. Tag current commit (`dh-air-standalone-final`) and make the full
   literal src\DH-Air\ zip per decision 7.
2. Copy src\DH-Air\ into src\DH-Tools\Modules\DHAir\ (this doc moves
   with it, to sit alongside DHBavin-Design.md/DHDanger-Design.md's
   convention of a per-module Design.md under Modules\<Name>\).
3. Add the DHAirDB SavedVariables declaration and DH-Air's Libs\ /
   source file entries to DH-Tools.toc.
4. Wrap DH-Air's OnEvent/hotkey dispatch behind
   `DHTools.IsModuleEnabled("air")`, same retrofit pattern used for
   Bavin/Quests (2026-08-03 audit).
5. Wire `DHTools.RegisterModule("air", {...})`.
6. Apply decision 4's admin-override rewire (delete DH-Air's own
   CheckAuthorAccount PLAYER_LOGIN section, repoint HasPermission).
7. Replace the Tools-page PLACEHOLDER_MODULES status row and the
   Minimap.lua "not installed" adapter branch per decision 2.
8. Move tests to Modules\DHAir\tests\; remove/merge the author-override
   test section per decision 4.
9. Fold a DH-Air section into DH-Tools-Description.md per decision 6.
10. Run the full harness (DH-Tools' own + all module suites).
11. Stop for an in-game pass before any release - per README's TESTING
    rule, only Chris can confirm a change works in-game.

## Residual risks / things to watch during migration

- DHAirDB is fresh for everyone post-merge (decision 1) - guildmates
  will need to re-register as Summoner/Clicker and officers will need to
  re-enter Board destinations after upgrading. Worth a line in the
  DH-Tools changelog so it isn't a surprise.
- Two admin-override mechanisms currently exist in DH-Air's Core.lua
  (the newer DHAirDB.isAuthorAccount one being retired here, and the
  older Loopidot-hardcoded-name one, which is untouched by this merge
  and stays tracked separately in ROADMAP.md's public-release checklist)
  - don't conflate the two during the decision-4 rewire.
- Once merged, a guildmate update means updating all of DH-Tools, not
  just DH-Air - a bigger ask per update than today (carried over from
  DH-Air's STATUS.md open questions; not a blocking issue, just a
  distribution-cost tradeoff Chris already accepted with this decision).
