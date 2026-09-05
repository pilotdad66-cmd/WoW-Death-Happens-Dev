# DH-Tools - Design & Milestone Plan
created: 2026-07-17

## Vision
One master addon a guild member installs instead of several. It exposes a
module registry: each feature module registers itself with DH-Tools at
load time, DH-Tools tracks which modules are on/off per character, and
provides a shared /dht command for listing and toggling them. Individual
modules keep their own slash commands and UI - DH-Tools does not proxy
their functionality, only their enable state.

Per claude\ROADMAP.md, whether a given feature ships as a DH-Tools module
or a standalone addon is a per-module decision, not an all-or-nothing
migration. 2026-07-17 decision: HCMobMarker becomes DH-Tools' first module
("Mob Marker") instead of being revived as a standalone DH-MobMarker
addon - it was dormant and unbuilt, so there's no live audience relying on
it as a separate addon, and it's a small, self-contained feature that
suits a module well. DH-Air is NOT being folded in, and this is now final
(2026-07-17, Loopi): it stays a separate, standalone addon. Its row on the
Tools page is a status indicator, not a real toggle - checked/active if
DH-Air is detected as installed (IsAddOnInstalled in Config.lua), greyed
out with an install-it-separately note if not.

## Module framework
See claude\DH-Tools\PROFILE.md for the registration contract
(DHTools.RegisterModule) and SavedVariables layout. Key design choices:
- Modules gate their own event handlers on DHTools.IsModuleEnabled(key)
  rather than DH-Tools dynamically registering/unregistering their frames'
  events. Simpler, keeps each module file self-contained, and the
  per-event check cost (a table lookup) is negligible at normal WoW event
  frequencies.
- One SavedVariablesPerCharacter table, DHToolsDB, shared by Core.lua and
  every module. Core.lua owns DHToolsDB.modules (enable state); each
  module owns its own DHToolsDB.<key> sub-table for its data.

## Milestones
1. DONE (2026-07-17) - Core.lua: module registry, DHToolsDB init,
   IsModuleEnabled/SetModuleEnabled, /dht list|on|off|help.
2. DONE (2026-07-17) - Modules\MobMarker.lua: ported HCMobMarker.lua's
   marking logic (mouseover auto-mark, Ctrl+click hotkey, /mm commands)
   from src\HCMobMarker-v2.0.zip, gated on the module framework.
3. DONE (2026-07-17, revised) - Config.lua: Tools / Mob Marker / About
   nav+pages. Loopi asked for the original Options.lua's two pages
   (Target Icons, hotkey Settings) to become ONE scrollable "Mob Marker"
   page instead - icons on top, settings below, one click away instead of
   two. "Tools" (the module on/off checklist, originally its own later
   milestone) got built at the same time since it's one of the three
   pages. `/dht config` opens to Tools; `/mm config` opens to Mob Marker.
4. DONE (2026-07-17) - Minimap.lua: LibDataBroker/LibDBIcon button (not
   in the original plan - added because Loopi wanted the target icon list
   reachable in one click from the minimap). Click shows a hand-rolled
   choice list (NOT UIDropDownMenu/EasyMenu - see the file's own comments
   on why), currently "DH-Tools" (-> Config Tools page) and "Target
   Icons" (-> Config Mob Marker page).
5. NEXT - In-game test pass: confirm load, the config window's layout
   (pixel values are an unverified best-effort port/estimate - see
   claude\DH-Tools\STATUS.md), persistence across /reload, and that
   disabling "mobmarker" actually stops both the mouseover watcher and the
   hotkey hook.
6. Package: confirm claude\build-test-zip.ps1 -Module DH-Tools works
   unmodified; first publish\ release once M5 is done.

## Deferred / open questions
- DH-Air bundled-vs-standalone: DECIDED 2026-07-17 - stays standalone (see
  above). No longer open.
- Whether future modules (DH-Layers, DH-Quests) join DH-Tools or ship
  standalone: decide per-module when each is revived/built, per
  ROADMAP.md's stated policy.
- No headless test suite for DH-Tools yet; revisit once the module count
  or complexity grows (DH-Air's tests\run-tests.ps1 pattern is the
  precedent to follow if/when it's worth the investment).
