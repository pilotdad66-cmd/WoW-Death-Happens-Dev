# DH-Quests v1.0 - Design & Milestone Plan
created: 2026-07-17

Lets Death Happens guild members see who currently has which group/elite
(and other) quests, so people can find others to group up with. This doc
is the working plan; STATUS.md tracks which milestone is actually in
progress. Once code and this doc diverge, the code is ground truth (same
convention as DH-Air-v2-Design.md).

## Decisions made 2026-07-17

**Privacy:** not a concern by design. The addon is opt-in by nature
(guildmates choose to install it), plus a master on/off toggle and
per-category share toggles give explicit control over what a player
broadcasts. No further privacy gating needed.

**Quest categories a player can choose to share:**
- Individual - no questTag (a normal solo quest)
- Group - questTag == "Group"
- Elite - questTag == "Elite"
- Class - **no native API tag exists for this** (Classic Era's
  GetQuestLogTitle only returns Elite/Dungeon/PVP/Raid/Group/Heroic/nil -
  confirmed via Warcraft Wiki 2026-07-17). Detecting "class quest" will
  need a maintained questID allowlist rather than a live API read. Resolve
  this - build the list or drop the category from v1 - as part of
  Milestone 1; don't block the rest of the plan on it.

**Sync approach:** guild addon-message broadcast, reusing DH-Air's
Sync.lua protocol pattern rather than designing from scratch:
- `C_ChatInfo.RegisterAddonMessagePrefix` on load (easy to miss - DH-Air's
  Sync.lua already does this correctly, copy that pattern).
- Delta messages on QUEST_ACCEPTED/QUEST_REMOVED/QUEST_LOG_UPDATE (ticker-
  debounced), broadcast to GUILD.
- A SYNCREQ/SYNCDATA handshake (fired on PLAYER_ENTERING_WORLD) so players
  who log in after others already have quests queued still get the full
  picture, chunked the same way DH-Air's SYNCDATA is.
- Manual chunking (~200 char payloads, same as DH-Air's MAX_CHUNK_CHARS)
  instead of ChatThrottleLib for v1 - DH-Air has run fine without it at
  raid scale; revisit only if in-game testing shows throttling problems.
- Outbound payloads respect the sender's own category toggles - an opted-
  out category is never broadcast, not just hidden client-side.

**UI:** a standalone display window for v1, modeled on DH-Air's Board.lua
(own frame, not a Blizzard UI hook). GuildFrame/GRM-style integration is a
real option (precedent: GuildRosterManager hooks the roster's build
function) but is more fragile against Blizzard's frame templates and is
explicitly deferred to a later version per Loopi, 2026-07-17.

## Decisions made 2026-07-18

**Packaging: DH-Tools module, standalone-optionality preserved.** Ships as
a DH-Tools module for v1 - config page + minimap entry via DH-Tools' own
framework, same pattern as Mob Marker (see DH-Tools\PROFILE.md) - rather
than its own standalone addon. Loopi wants the option to spin DH-Quests
off as a standalone addon later if it proves popular, so this is a
packaging choice, not a redesign: core logic (category detection, sync
protocol, peer store, display window) lives in its own subfolder under a
DH-Quests namespace, and DH-Tools only calls into it - never the reverse.
The DH-Tools config page and minimap-menu entry are a thin adapter only.
DHQuestsDB stays its own top-level SavedVariables table rather than a
DHToolsDB.<key> sub-table (a deliberate exception to DH-Tools' normal
module contract), and `/dhq` is registered by DH-Quests' own code, not
DH-Tools' command router. Net effect: extracting this later should mean
building a standalone Config.lua/Minimap.lua/.toc around the existing
core, not restructuring it. Milestone 1 should fold src\DH-Quests\ into
src\DH-Tools\ (own subfolder, loaded via DH-Tools.toc) instead of keeping
the current standalone .toc scaffold.

**Command:** `/dhq`, matching Mob Marker's `/mm` convention - replaces the
`/dhquests` placeholder used earlier in this doc.

**Display window additions (Milestone 5 scope, detailed there):**
online-only filter, sort by character level, sort by quest level, and an
invite button on any row sharing a quest with the local player.

## Milestones

**M1 - Data model & category detection**
Local quest-log scanner (GetNumQuestLogEntries/GetQuestLogTitle loop) that
classifies each active quest into Individual/Group/Elite/(Class if
resolved). SavedVariables schema: per-user settings (master share on/off,
per-category toggles) + local cache table. Resolve the Class-quest
detection question here.

**M2 - Guild sync protocol**
Port DH-Air's Sync.lua pattern: prefix registration, delta broadcast
messages, SYNCREQ/SYNCDATA full-state handshake, chunking. Category
toggles gate what gets broadcast.

**M3 - Local store & event wiring**
Peer table (name -> questID -> {title, category, level, suggestedGroup,
status, lastUpdated}). Register QUEST_ACCEPTED, QUEST_REMOVED,
QUEST_LOG_UPDATE (debounced), PLAYER_ENTERING_WORLD (fire SYNCREQ),
CHAT_MSG_ADDON (decode/dispatch), GUILD_ROSTER_UPDATE (prune
offline/departed peers).

**M4 - Settings UI**
No standalone Config.lua. Add a "Quests" page to DH-Tools' existing
Config.lua (same pattern as Mob Marker's page): master on/off + four
category checkboxes controlling what this client shares. Toggles only
affect outbound sharing, not what's displayed from others. Reachable via
`/dhq config` in addition to DH-Tools' own Tools page.

**M5 - Display window**
Standalone list window (mirrors Board.lua, own frame): guild member <->
shared quests. Features:
- Filter/sort by player or quest (original scope).
- Online-only filter: toggle to show only currently-online guildmates.
- Sort by character level.
- Sort by quest level.
- Highlight rows where the local player shares the same questID as
  someone else (the core payoff feature).
- Invite button on any highlighted row - sends a group invite to that
  player directly from the window. Needs in-game confirmation that
  Classic Era's invite API (C_PartyInfo.InviteUnit/InviteToGroup) works
  guild-wide by character name; DH-Air hasn't exercised this API before.
Open via `/dhq` (formerly planned as `/dhquests`, changed 2026-07-18 to
match Mob Marker's `/mm` convention). No dedicated minimap button - add an
entry to DH-Tools' existing Minimap.lua choice-list (same as its Mob
Marker / DH-Tools entries) instead of vendoring a second
LibDataBroker/LibDBIcon instance.

**M6 - Test & package**
Headless Lua harness (mirrors tests/harness.lua): category classification,
payload chunk/encode/decode round-trip, SYNCREQ/SYNCDATA reassembly,
share-toggle gating. Confirm build-test-zip.ps1 -Module DH-Tools stages
the folded-in DH-Quests subfolder correctly (no separate DH-Quests zip
workflow now that it's a DH-Tools module). In-game test pass with Loopi
before calling any milestone done, per README's testing rule.

## Deferred to a later version (not in this plan)
GuildFrame or GRM (Guild Roster Manager) integration - explore once the
standalone window is working and proven useful.
