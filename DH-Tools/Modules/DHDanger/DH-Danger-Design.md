# DH-Danger - Design and Build Plan
created: 2026-08-06
rewritten: 2026-08-06 (the original commit bdca6fa landed with only the
last two sections - the body below was lost to a truncated chunked write,
not to a later edit. Reconstructed in full.)

## Mission
Warn a Hardcore player that something nearby can kill them, early enough
to act on it. One death is permanent, so the cost of a missed warning is
total and the cost of a false alarm is mild annoyance. That asymmetry
drives every design call in this document.

**DH-Danger's mission is the inverse of RareScanner's.** RareScanner
helps you *find* a rare so you can go kill it. DH-Danger helps you
*avoid* a mob so it doesn't kill you. Same detection plumbing, opposite
intent - which is why the feature table below skips so much of what
RareScanner spends its code on (maps, collection tracking, loot).

## Reference study: RareScanner
Studied 2026-08-06 from claude\DH-Danger\intake\RareScanner, then
**re-studied properly 2026-08-06 (later)** after the first pass got
several things wrong. All Rights Reserved: **studied for approach only,
no code copied**.

### Corrections to the first pass - read these before trusting old notes
- **It is NOT a Retail addon.** `RareScanner.toc` reads
  `## Interface: 11509`, `## Version: 1.15.9` - this is a **Classic Era
  build**. The whole codebase is therefore a valid reference for what
  the Classic Era API actually supports. The first pass called it Retail
  and discounted features on that basis; that reasoning was wrong.
- **It does not use `C_VignetteInfo`.** That string appears nowhere in
  the addon. The first pass saw `GetVignetteInfo` and assumed the
  Blizzard API; the actual symbol is a local helper,
  `GetVignetteInfoGUID` (RSButtonHandler.lua:48). "Vignette" is just
  RareScanner's internal vocabulary for "a thing worth alerting about",
  carried over from its Retail lineage. There is no minimap-blip
  scanning in this build.

### How it actually decides to alert (traced, not assumed)
Every alert in the addon funnels through one function,
`scanner_button:SimulateRareFound(npcID, objectGUID, name, x, y,
atlasName, trackingSystem)` (RareScanner.lua:420), which builds a
`vignetteInfo` table and calls `RSButtonHandler.AddAlert`. Grepping all
callers of `SimulateRareFound` / `AddAlert` / `DetectedNewVignette`
returns **only RSEventHandler.lua** (lines 54, 68, 222, 225, 251, 262,
272) plus the nav plugin. There is no other detection path.

So the complete trigger set is exactly five events
(RSEventHandler.lua:353-364):

| Event | Effective range |
|---|---|
| `NAME_PLATE_UNIT_ADDED` | nameplate range (~20yd, CVar-capped ~41yd) |
| `UPDATE_MOUSEOVER_UNIT` | wherever you can mouse over |
| `PLAYER_TARGET_CHANGED` | target range |
| `CHAT_MSG_MONSTER_YELL` | **very long - yells carry ~300yd+** |
| `CHAT_MSG_MONSTER_EMOTE` | long, same channel family |

**There is no distance math anywhere in the addon.** It never computes
yards, never compares positions to decide whether to warn. Detection is
purely "did one of those five events fire for an NPC ID in my list".

### Why it feels like it alerts far beyond 20 yards
Two separate reasons, neither of which is long-range live detection:
1. **`CHAT_MSG_MONSTER_YELL` is the long-range channel.** Monster yells
   broadcast far past nameplate range, which is why a rare "announces"
   itself from across a zone. This is the single most valuable
   mechanism to steal, and the first pass rated it "low priority, M5" -
   that was a mistake.
2. **The map pins are memory, not detection.** RareScanner ships a
   static coordinate DB and records what you've already found
   (`RSGeneralDB.GetAlreadyFoundEntity`). A pin on your map for a rare
   200 yards away is a *stored coordinate*, not a live sighting.

**Consequence for DH-Danger:** a mob that never yells and never emotes
cannot be detected at range by any technique in this addon. For those,
nameplate range is the ceiling, and Q2 stands.

### Author's own documentation (CurseForge "Alerts/Tracking systems",
### rev 34, 2025-11-04 - read 2026-08-06)
Retail-facing docs, but they name each tracker's expansion range, which
makes them authoritative about what Classic Era does and doesn't get.
Everything below is the author's statement, and it agrees with the code
trace above.

- **Vignettes are Pandaria+ only.** "vignettes were introduced to the
  game with the expansion Pandaria, and so far Blizzard hasn't
  implemented this system in older zones, so the addon won't be able to
  use this system in older areas." World-map vignettes are Shadowlands+.
  **Q1 is now closed by the author's own words, not just our grep.**
- **Nameplates are the designated pre-Pandaria tracker**, and the author
  concedes the exact weakness we identified: "Nameplates are more
  limited than vignettes because they have a maximum range to appear on
  your screen, so you will get alerts only from closer entities."
- **Chat tracker gives distant alerts** - the docs warn users they may
  get alerts from NPCs they can't reach. Confirms yells are the
  long-range channel.
- **"Target Unit" tracker is dead everywhere.** "Blizzard made some
  changes so this system doesn't work anymore in any version of the game
  (retail, classic or mists)." Its replacement is a macro the *player*
  spams manually. This is the same protected-function wall as k-0010:
  programmatic `TargetUnit()` needs a hardware event. Note this is a
  DIFFERENT tracker from "On target" (`PLAYER_TARGET_CHANGED` when the
  player targets something themselves), which still works.

#### NEW HARD REQUIREMENT: nameplates must be enabled by the player
The single most important line in the docs: "In order to see them you
have to enable them manually (by default pressing the key 'V'). **If you
don't have them enabled the addon won't be able to detect anything**
before Pandaria."

For DH-Danger this is a silent total-failure mode. A guildmate installs
the addon, never turns on nameplates, and it protects them from nothing
while appearing to work perfectly. In a Hardcore addon that is the worst
possible failure: false confidence.

Requirements this creates (M1, not optional):
- Check nameplate state at `PLAYER_LOGIN` and warn loudly if off. The
  relevant CVars are `nameplateShowEnemies` (and
  `nameplateShowFriends`); `nameplateMaxDistance` governs range.
- Re-check on `CVAR_UPDATE` - a player can turn them off mid-session by
  pressing V, and our warning must not be a one-time login message they
  scrolled past.
- Surface the state in the DH-Tools config page as a status row, the way
  the Tools page already reports DH-Air's presence.
- Do NOT silently force the CVar on. Changing a player's UI settings
  without asking is hostile; tell them and offer a one-click fix.

#### Rejected: programmatic target-scanning to beat nameplate range
Tempting fix for Q2 - loop nearby units and check them - but
`TargetUnit()` is protected (k-0010), and the addon author confirms
Blizzard killed this approach in all game versions. The only sanctioned
workaround is a player-spammed macro, which is backwards for a danger
warning: you cannot ask someone to spam a macro to discover that
something is about to kill them. **Do not spend time here.**

### Data model (traced)
Two flat tables keyed by npcID, in Tables\:
- `private.NPC_INFO = { [npcID] = { zoneID, displayID, season } }`
  (NpcInfoTables.lua). **Names are trailing Lua comments, not data.**
- `private.NPC_LOOT = { [npcID] = { itemID, itemID, ... } }`
  (NpcLootTables.lua), gated on `C_Seasons.GetActiveSeason()`.

Item *quality* is never stored - it is derived at runtime, and the
options panel keys off `Enum.ItemQuality.Rare` (= 3 = blue), confirmed
present in this Classic build (RSLootOptions.lua:31-41). That is the
right pattern: **store itemIDs, derive quality live.**

### Custom-NPC import format (RSCustomNpcs.lua:77)
Space-separated, five fields, `#` starts a comment line, `*` skips a
field:

    npcID mapCoords lootString displayID groupName

`mapCoords` is `mapID:XXXX-YYYY,XXXX-YYYY|mapID:...` where each coord
component must be exactly 4 digits with no decimal point. Chris has
access to an Alliance-danger import file in this format - **that is a
real data source for our allowlist**, and the parse rules above are
enough to write a converter.

## Feature-fit review (M0 sign-off table)
Verdicts are proposals for Chris to confirm, except where marked DECIDED.

| # | RareScanner feature | Verdict | Why |
|---|---|---|---|
| 1 | Nameplate detection (`NAME_PLATE_UNIT_ADDED`) | **Keep** | Primary source. Fires without player action - the only one that warns you about something you haven't already engaged. Lead-time risk: see Q2. |
| 2 | Mouseover / target detection | **Keep** | Free to add, same handler. Weak as a *warning* (you already found it) but a good safety net and useful for building the list. |
| 3 | Chat monster-yell / emote detection | **KEEP - PROMOTED TO M1** | Re-rated after tracing the code. This is the ONLY long-range detection RareScanner has: yells carry ~300yd+ vs. nameplates' ~20yd. It is the direct answer to Q2's lead-time problem for any mob that yells, and it is cheap - two events, no distance math. Was "low priority, M5" in the first pass; that was wrong. |
| 4 | Vignette / minimap-blip detection | **Skip** | Does not exist in this addon at all (no `C_VignetteInfo`). Nothing to port - not because the API is missing, but because RareScanner never used it here. |
| 5 | Dedup by GUID + per-NPC cooldown | **Keep** | Non-negotiable. Without it, one patrol re-alerts every time its nameplate recycles. |
| 6 | Global alert throttle | **Keep** | Same reason. Copy the *concept*, write our own. |
| 7 | Alert UI (banner + sound) | **Adapt** | Ours must read as a *warning*, not a discovery: red, loud, unmissable, auto-fading. RareScanner's is celebratory. Must also carry a **target button** (Chris, 2026-08-06) - see "Targeting the alerted mob"; that requirement drives the whole frame's construction because of the k-0018 anchor-family trap. |
| 8 | Static NPC database | **Adapt** | Becomes our curated allowlist. Correction: its data is **Classic Era NPC IDs, not Retail** - so it has real reuse value, both as an ID source and as a schema model (flat table keyed by npcID, names as comments). |
| 9 | User-added custom NPCs + text importer | **Keep - raised priority** | Cheap, and guildmates will know local killers we missed. Also the ingest path for Chris's Alliance-danger import file: the format is traced above, so we can write a converter rather than hand-typing IDs. M4. |
| 10 | Mute / ignore list | **Keep** | Escape hatch for false positives. Scope (per-char vs account) is Q3. |
| 11 | World-map / minimap POI overlays | **Skip** | That's a *find it* feature. Wrong mission, large surface area. |
| 12 | Loot tables (`NPC_LOOT`) | **KEEP - was wrongly skipped** | Chris's 2026-08-06 call: some elites drop blue-or-better gear and are worth killing, not just avoiding. RareScanner's `[npcID] = {itemID,...}` table is exactly the structure we need. See "Worth-killing flag" below. (Collection/achievement filters remain **Skip** - those really are rare-hunting.) |
| 13 | Zone-scoped data loading | **Adapt** | Worth it only if the allowlist grows past a few hundred entries. Defer to M6. |
| 14 | Localization framework (12 locales) | **Skip** | Guild addon, enUS only. Matches the other DH modules. |

## Decisions
- **2026-08-06 (Chris): "especially deadly" = curated allowlist**, not a
  runtime heuristic. DECIDED. Rationale: precision matters more than
  coverage here, because a warning that cries wolf gets muted, and a
  muted addon protects nobody. A heuristic also structurally cannot know
  the thing that actually kills Hardcore players - that a level-22
  caster's fear will drag you into three more packs. Level and elite
  flags don't encode that; a curated list does. Cost accepted: the list
  is manual to build and maintain, and is now the gating work for M1.
- **2026-08-06 (Chris): ships as an integrated DH-Tools module**, no
  standalone-optionality scaffolding.
- **2026-08-06 (Chris): the dataset should be as detailed as possible**,
  in anticipation of future features, even where nothing consumes a
  field yet. Schema is deliberately wider than M1 needs.

## What we alert on - and what we don't (Chris, 2026-08-06)
The scoping question that matters most. Chris: "We do not want to alert
on just any elite. There are many in the world that are always there and
players can expect to see them frequently. What I want to alert on is
only those rare spawns that can catch a player by surprise as well as
horde elite guards that get too close."

### The organising principle is SURPRISE, not lethality
A stationary elite you can see from 40 yards and walk around is not a
threat to an attentive player, however hard it hits. What kills Hardcore
characters is what they did not expect. Surprise decomposes into four
distinct sources, and they do not share a solution:

| Source of surprise | Example | What we need |
|---|---|---|
| Unpredictable **existence** | rare spawns - not always there | detect + identify as rare |
| Unpredictable **position** | Son of Arugal, Stitches | earliest possible warning |
| Unpredictable **visibility** | STV stealthed panthers | earliest possible warning |
| Unpredictable **proximity** | Horde guards | a tight distance threshold |

**The fourth is a different problem from the first three.** For a guard
you already know it exists and where it is - the danger is drifting into
aggro range. That is a distance question, not a detection question.

### Consequence: the two halves want OPPOSITE range behaviour
- Rares / roamers / stealth: maximise range. Warn as early as possible.
- Guards: a *tight* threshold. A guard alert from 300 yards inside
  Orgrimmar is pure noise - "there are guards in Orgrimmar" is not
  information.

So nameplate range being short, which reads as the module's biggest
weakness for category 1-3, is a **feature** for guards. Q2's measurement
now has two use cases pulling in opposite directions, and needs to
report both: how early does a nameplate fire, and does it fire before
guard aggro engages.

### DECIDED (Chris, 2026-08-06): broad data, filtered alerts
Do NOT solve the noise problem by deleting data. Keep static elites in
the database; control what a player actually hears about with a **user
configuration setting, including which levels to alert on.**

This gives a clean three-layer separation, and it is the architecture
the module should be built on:

1. **Data layer** - DangerList + the imported files. Broad. Everything
   we know about, static elites included. Never filters anything.
2. **Classification layer** - what KIND of danger is this. Derived from
   the game where possible (`UnitClassification` returns "rare" /
   "rareelite" / "elite" / "normal"; `UnitLevel` gives level), curated
   where the game can't tell us (roams, stealth, yells).
3. **Policy layer** - what does THIS player want to hear. Level
   threshold, per-category toggles, severity floor, mute list.

Note this does not reverse the allowlist decision. Curation still
decides what counts as dangerous; the level filter is a user-facing
*volume knob* over curated data, not a definition of danger.

### Planned config (M4, but designed for from M1)
- **Level threshold. DECIDED (Chris, 2026-08-06): relative to the
  character's own level** ("warn me about things N+ levels above me"),
  never absolute bands. The threshold must be recomputed against
  `UnitLevel("player")` at alert time, not cached at login - the player
  dings mid-session and the filter has to move with them.
- **Per-category toggles**: rares / roamers / stealth / guards / static
  elites. **Default: static elites OFF** - that default is the direct
  answer to Chris's complaint, and it means the broad database is safe
  to ship without being noisy.
- **Per-classification controls - MULTIPLE INDEPENDENT CHOICES (Chris,
  2026-08-06).** Not one "alert on rares" switch. One control per
  `UnitClassification()` value, each set independently.

  **CONFIRMED 2026-08-08 (Chris)**, staying within the curated allowlist
  - NOT a live `UnitClassification()` bypass. Chris confirmed explicitly:
  the plan is to grow the allowlist itself (see the curation build order
  below) rather than alert on any elite/rare/rareelite the client
  happens to detect, curated or not. That keeps the 2026-08-06 "curated
  allowlist, not a runtime heuristic" decision intact - "always alert"
  only changes how an ALREADY-CURATED entry's level threshold is
  evaluated, never whether an un-curated mob can alert at all.

  Curated **tri-state per classification**, which expresses Chris's
  requirement in one control per row rather than two:

  | Classification | Off | Filtered | Always |
  |---|---|---|---|
  | `worldboss` | | | default |
  | `rareelite` | | | default |
  | `rare` | | | default |
  | `elite` | | | default |
  | `normal` | | default | |

  - **Off** - never alert on this classification.
  - **Filtered** - alert, subject to the level threshold + severity
    modifier.
  - **Always** - alert regardless of level.

  **2026-08-08 (Chris): confirmed the Always set as "elites, rares, rare
  elites for now"** - `elite` moved from Filtered to Always default to
  match (was proposed as Filtered on 2026-08-06; superseded). `worldboss`
  stays Always by inheritance from `rareelite`/`rare` rather than a
  direct instruction - Chris didn't mention it, and it's vanishingly
  rare in leveling content, but nothing about "we can tweak later" says
  otherwise. `normal` stays Filtered, also unmentioned but the clear
  default-off case. The tri-state structuring itself is still MY
  proposal, not Chris's words verbatim - he specified independent
  choices per classification; collapsing "on/off" and "regardless of
  level" into one three-way control is an interpretation he has not
  explicitly blessed. Say if you'd rather have two separate checkboxes
  per row.

  **Enumerate the classification values from the live client rather than
  trusting this table** - `UnitClassification()` is documented as
  returning worldboss/rareelite/elite/rare/normal, with "trivial"
  appearing in some API references. Confirm in-game before hardcoding
  the list; an unhandled value should fall through to Filtered, never to
  silently-off.

  Cheap and reliable: classification comes straight from
  `UnitClassification()` on any unit token, so it needs no curation and
  can't drift out of date.

  Note these are NOT the severity bypass Chris rejected earlier, and the
  difference matters: that one was *automatic and invisible*, silently
  holing a filter the user believed was in force. These the user sets
  deliberately. An opt-in override is a feature; an implicit one is a
  safety hole.
- Severity floor, and a mute list for individual NPCs.

### Two traps in level filtering
- **`UnitLevel` returns -1 for "??" / skull mobs. DECIDED (Chris,
  2026-08-06): treat -1 as infinitely above the player - always alert,
  never filterable by the level threshold.** This must be an explicit
  branch BEFORE any numeric comparison; `-1 >= playerLevel + N` is false
  for every N, so a naive compare silently drops the single most
  dangerous class of mob in the game. Worth a dedicated test-harness
  case, since the bug is invisible in normal play (everything looks
  fine right up until nothing warns you about a skull).
- **A level filter can silence real killers.** A same-level stealthed
  panther kills level-30s; "only warn me about things 5+ levels above"
  would mute it. My first proposal was that severity-3 *bypass* the
  filter outright. **Chris rejected that and was right: "Sure Hogger is
  extra dangerous, but not to a lvl 20."** Nothing should be exempt from
  levelling out of relevance.

## Severity as a level MODIFIER (Chris, 2026-08-06) - DECIDED
Severity does not override the level threshold. It **widens** it. A
dangerous mob earns you more margin; it never earns permanent attention.

    effectiveThreshold = userThreshold - severityModifier
    alert if (mobLevel - playerLevel) >= effectiveThreshold

Proposed modifiers (tunable constants, not magic numbers - put them in
one table at the top of the policy file):

| Severity | Extra margin |
|---|---|
| 1 - caution | 0 levels |
| 2 - high | 3 levels |
| 3 - lethal | 6 levels |

**Why this is better than a bypass:** severity shifts the curve instead
of removing it. Everything still falls silent once you sufficiently
outlevel it, which is exactly the behaviour Chris asked for, and it
means severity can be generous without creating permanent noise.

Worked examples at userThreshold = +3 (verified by script, not by hand):

| Mob | Lvl | Sev | Player | Alerts? |
|---|---|---|---|---|
| Hogger | 11 | 3 | 11 | yes |
| Hogger | 11 | 3 | 14 | yes |
| Hogger | 11 | 3 | 17 | **no** |
| Hogger | 11 | 3 | 20 | **no** - Chris's exact case |
| Shadowmaw Panther | 41 | 3 | 41 | yes - the case a bypass was meant to fix |
| Shadowmaw Panther | 41 | 3 | 44 | yes |
| Shadowmaw Panther | 41 | 3 | 47 | no |
| Son of Arugal | 26 | 3 | 22 | yes |
| Son of Arugal | 26 | 3 | 32 | no |
| Kolkar Centaur | 14 | 2 | 14 | yes |
| Kolkar Centaur | 14 | 2 | 18 | no |
| Riverpaw Gnoll | 12 | 1 | 12 | no |
| skull / "??" | -1 | any | 60 | **yes - hard exception, see below** |

**The skull case stays a hard override, not a modifier.** `UnitLevel`
returning -1 is not a level, it's the absence of one, so it cannot
participate in arithmetic - it must be branched on first. That exception
survives because -1 means "unknowably far above you", which is the one
situation where levelling-out genuinely never applies.

**Severity and `surprise` stay independent mechanisms.** `surprise`
drives the on/off category toggles (do I want to hear about guards at
all?); severity tunes the level margin within whatever is enabled. No
interaction, no stacking - keep it that way unless there's a concrete
reason, because stacked multipliers become impossible to reason about.

**Still soft:** severity values themselves remain hand-assigned by
judgement (see PROVENANCE in DangerList.lua). That is now acceptable in
a way it wasn't as a bypass - a mis-set severity shifts a threshold by a
few levels rather than punching a permanent hole in the user's filter.
Worth revisiting if a rule for assigning it emerges.

### The two import files map onto this cleanly
- **Alliance Enemy PVP NPCs.txt** (123 entries, no loot) is the guards
  list. Its zone histogram is Horde capitals and Horde territory -
  Ashenvale 17, Tirisfal 13, Orgrimmar 11, Durotar 9, Undercity 9,
  Thunder Bluff 8, Mulgore 6. That is category 4, already sourced.
- **Alliance Enemy Elites.txt** (440 entries) is dominated by *static*
  endgame elites - Silithus 38, Stranglethorn 28, Eastern Plaguelands
  27, Hinterlands 24, Winterspring 21. DECIDED: mine it for loot and
  coordinates, keep the entries in the database, but they are not the
  alert list and default to off.

## Targeting the alerted mob (Chris, 2026-08-06) - WAS MISSING
Chris flagged this and he was right: it was nowhere in the design. An
alert that says "something dangerous is near" and gives you no way to
look at it is half a feature - especially once the worth-killing flag
exists, because deciding whether to fight something starts with
targeting it.

**This is the single riskiest UI item in the module, and we have already
paid for the lesson twice.** `TargetUnit()` is a protected function.

### What we already know (do NOT rediscover this)
- **k-0010**: `TargetUnit()` / `CastSpellByName()` called from a plain
  `OnClick` are *always* tainted, no matter how synchronous the call
  looks. DH-Air's Summon button hit this and was dead in the water until
  it was rewritten to route through a `SecureActionButtonTemplate`
  button with PreClick-armed macro attributes. Same wall applies here.
- **k-0018**: the 1.15 engine propagates protected status through
  **anchors, not parents**. Anchoring a secure widget to an ordinary
  frame drags the whole anchor family into a restricted state - DH-Air's
  Board window silently refused to lay out until a real click happened.
  Fix was to parent AND anchor the secure button only to `UIParent` with
  absolute offsets recomputed on show/drag/resize.
- **k-0018 also**: `RegisterForClicks` must match the
  `ActionButtonUseKeyDown` CVar - exactly one phase, never both - or
  PreClick fires and nothing actually happens.
- **RareScanner independently confirms the wall.** Its own "Target Unit"
  tracker is documented as broken in every game version, replaced by a
  macro the player clicks. Nobody has a clever way around this.

### ABSOLUTELY NO AUTOMATIC TARGETING (Chris, 2026-08-06) - DECIDED
The addon never changes the player's target on its own. Ever. The user
clicks to target, or nothing happens.

This is a hard product rule, and it happens to align perfectly with the
technical wall above rather than fighting it: automatic targeting is
*also* impossible (protected function, hardware event required). The
constraint that looked like the module's biggest obstacle turns out not
to conflict with the desired design at all. Nothing to work around.

It is also the right call on its own merits - silently retargeting a
Hardcore player mid-fight could kill them.

### The UI model: the alert window IS the button (Chris, 2026-08-06)
Chris: "a window pops up with the mob name and picture - you click on
that window to target the mob." Same model for us, minus the picture
(explicitly unnecessary for now - it's RareScanner's 3D `ModelView`,
pure cost for us).

So it is NOT "a banner containing a target button". The banner itself is
the secure button. That is simpler and it sidesteps the anchor-family
problem, because the secure frame is the root of its own hierarchy
rather than a widget anchored into someone else's.

### Working Classic Era reference - study this before writing M3
RareScanner does exactly this, in a Classic Era build, and it works
(RareScanner.lua:47-57):

    local scanner_button = CreateFrame("Button", RSConstants.RS_BUTTON_NAME,
        UIParent, "SecureActionButtonTemplate, BackdropTemplate")
    scanner_button:RegisterForClicks("AnyUp","AnyDown")
    scanner_button:SetAttribute("*type1", "macro")     -- left click = /target
    scanner_button:SetAttribute("*type2", "closebutton")  -- right click = dismiss
    scanner_button:SetScript("PostClick", ...)         -- non-secure follow-up

Points worth copying (approach, not code - All Rights Reserved):
- Parented directly to `UIParent`, exactly what k-0018 prescribes.
- `"SecureActionButtonTemplate, BackdropTemplate"` - both templates on
  one frame, so it can be a styled window AND a secure action button.
- Right-click to dismiss via a second attribute, rather than a separate
  close widget that would need its own anchoring.
- `PostClick` for the non-secure follow-up work, not `PreClick`.

### DISCREPANCY to resolve empirically at M3 - do not assume
k-0018 records, from DH-Air, that `RegisterForClicks` must match the
`ActionButtonUseKeyDown` CVar - **exactly one phase, never both** - or
PreClick runs and nothing casts. RareScanner registers **both**
(`"AnyUp","AnyDown"`) and works.

Possible explanation: k-0018's finding came from *casting a spell*
(`CastSpellByName` via secure attributes), whereas `/target` may be
subject to laxer rules. That is a hypothesis, not a fact. **Test it in
game before committing to either pattern** - and if RareScanner's
both-phases form works for targeting, record it in k-0018 as a scoped
exception rather than leaving two contradictory rules in the KB.

### Two limitations to design around, not discover
1. **Combat lockdown - a MINORITY case, corrected 2026-08-06.**
   Secure button attributes cannot be changed in combat, so an alert
   firing mid-fight can't re-arm the window and it would still hold the
   previous mob's name.

   An earlier draft of this section claimed in-combat was DH-Danger's
   *normal* case. **That was wrong, and Chris caught it:** "If we are
   close enough to be in combat with something in our dataset - the
   addon should have alerted long before that." Exactly right. The alert
   fires at nameplate range or on a yell, both of which precede aggro.
   Being in combat means the warning already fired or already failed -
   so treating in-combat as the normal path inverted the module's own
   success condition.

   The in-combat case is real but narrow. The one that matters:
   **you are already fighting mob A when dangerous mob B wanders into
   range.** That is a minority path, but it is also the single most
   lethal moment in Hardcore - engaged, at partial health, with a roamer
   inbound - so it must degrade well, not be dismissed.

   **Resolution (supersedes the earlier "explicit decision needed"):**
   split warning from targeting, because they have different combat
   requirements.
   - **The WARNING always shows**, in combat or out. It is plain text
     and needs no secure attributes, so combat lockdown cannot touch it.
     This is the part that matters mid-fight.
   - **Click-to-target degrades to warning-only in combat.** No stale
     targeting, ever.

   Two things make that degradation cheap rather than a compromise:
   - Alerts overwhelmingly fire out of combat, so the normal path arms
     the macrotext normally. The degraded path is the exception.
   - If you are in combat *with the dangerous mob itself*, you don't
     need a targeting button - it is already attacking you. The button
     is redundant in precisely the situation where it is unavailable.

   Net effect: combat lockdown is a much smaller problem than the
   earlier draft made it sound, and M3 is correspondingly less risky.
   Still needs `InCombatLockdown()` checks; no longer needs a difficult
   design decision.
2. **Targeting is by NAME, not GUID.** A macro can only do
   `/target <name>`, which picks the nearest match. For unique named
   rares (Son of Arugal, Stitches) that's exact. For generic names
   ("Riverpaw Gnoll") it may well target a different mob than the one
   that triggered the alert. Acceptable, because the alert list is
   dominated by uniquely-named mobs - but the button should probably be
   hidden for entries whose name isn't unique, rather than quietly
   targeting the wrong gnoll.

### Milestone
**M3**, with the alert UI - it is a UI affordance and shares the frame.
Do not defer it to a later milestone and bolt it on: the anchor-family
constraint shapes how the banner is built, so retrofitting means
rebuilding the banner.

## Worth-killing flag (Chris, 2026-08-06)
Some elites drop blue-or-better gear. Warning a player away from those
is actively bad advice - especially in Hardcore, where a blue weapon at
the right level measurably improves survival for the next ten levels.

This changes the module's output from a binary "danger" to a **risk/
reward judgement**: not "run away" but "this can kill you, and here is
what it's holding."

Design:
- Store `loot = { itemID, ... }` per entry. **Store itemIDs only, never
  a quality value** - quality is derived at runtime via `GetItemInfo`,
  matching RareScanner's approach (feature #12). A hardcoded "blue"
  flag would silently rot if an item were ever re-itemized.
- Derive the highest quality in the loot table and compare against
  `Enum.ItemQuality.Rare` (3). Confirmed available in Classic Era.
- **`GetItemInfo` returns nil for uncached items.** On a fresh login the
  client may not know an item yet, so a naive call returns nothing and
  the flag silently fails. Must handle the async path
  (`C_Item.RequestLoadItemDataByID` / `GET_ITEM_INFO_RECEIVED`) rather
  than assuming a synchronous answer. This is the main implementation
  trap in the feature.
- Alert presentation: a danger alert for a worth-killing mob should be
  visually distinct - the point is to inform the decision, not to
  suppress the warning. It is still dangerous; it is just *also*
  valuable.
- `soloable` is a separate axis from `lootValue` and both matter: a mob
  can drop a blue and still be unkillable solo. Do not collapse them.

Milestone: **M2.5**, after the alert pipeline exists but before the UI
is finalized, since it changes what the UI must express.

## Open technical questions
**Q1 - Is there a long-range proximity signal? RESOLVED twice over -
code-traced AND confirmed by the addon author's own documentation
("vignettes were introduced... with Pandaria... the addon won't be able
to use this system in older areas"). No in-game check needed.**
The question was malformed - it assumed RareScanner had a vignette
mechanism we needed to replicate. It does not; `C_VignetteInfo` appears
nowhere in the addon. The real answer to "how does it alert beyond
nameplate range" is **`CHAT_MSG_MONSTER_YELL`**, whose broadcast radius
is far larger than nameplate range. There is no proximity API involved
and no distance math anywhere in RareScanner.

Consequences:
- Long-range warning is available **only for mobs that yell or emote.**
  That set is small but includes some of the most dangerous named mobs.
- For silent mobs, nameplate range is a hard ceiling. No technique in
  the reference addon beats it.
- Therefore the allowlist needs a per-entry `yells` field so we know
  which entries can be warned about early and which cannot. Added to
  the schema.

**Q2 - Does nameplate range give enough warning lead time?**
STILL OPEN, and still the biggest risk - but now correctly scoped to
*silent* mobs only, since yellers are covered by Q1's answer.

Nameplate range in Classic Era is roughly 20 yards for hostile units,
raisable via the `nameplateMaxDistance` CVar (commonly capped ~41).
If a nameplate only appears at 20 yards, a patrolling elite may already
be in aggro range when we fire - a warning that arrives too late to act
on is worse than none, because it teaches players to ignore the addon.
**Must be measured in-game, not guessed.** Test: park at a known elite,
vary `nameplateMaxDistance`, and record at what distance the nameplate
event actually fires versus where aggro starts. M1 gate.

If the measurement comes back bad, the fallback is not a better
proximity API (there isn't one) but a **different warning model** for
silent mobs: warn on zone/subzone entry from stored coordinates, the
way RareScanner's map pins work - memory rather than detection.

**Q3 - DHDangerDB SavedVariables scope: per-character or account-wide?**
**RESOLVED for the user-added list, 2026-08-08 (Chris): account-wide.**
"/dhdanger add|remove|list" stays, but its data is now its own
account-wide set (DHToolsAccountDB.danger.manualList - renamed from
`testList` same day, per Chris: "we are testing it sure, but the list
is intended for the release version too") that a new DH-Tools release
never overwrites - separate from the curated list (DangerData.lua +
Curation.lua), which DOES get replaced by every release since it ships
as addon source, not SavedVariables. **NO migration** from the old
per-character location (DHToolsDB.danger.testList, where it lived
2026-08-07/08): a migration was built, then Chris explicitly reversed
that same day - the account-wide list starts blank once the module is
ready for general use, and whatever's in the old per-character slot
from alpha testing is left untouched, not read or copied. See Core.lua's
InitDB. Confirms the original proposal below almost exactly, minus the
migration piece. Still open: the mute list (doesn't exist yet - no M4
config page work has started) may want its own per-character override
later, on the same reasoning a level 60 doesn't fear what a level 12
does; revisit when that feature actually gets built rather than
deciding it now.

Original proposal, for reference: ship the allowlist as code (not
SavedVariables at all), and make only the mute + user-added entries
account-wide with a per-character override later if asked. M1 decision.

**Q4 - What is the alert's actual output?**
Banner + sound is assumed, but Hardcore players often run with sound
off. Consider screen-edge flash and/or a raid-warning-style center text.
Decide in M3 when the UI is built, informed by Q2's lead-time answer.

## Milestone plan

> **RESEQUENCED 2026-08-07 (Chris).** The order below was wrong, and it
> cost several sessions. M0 put "curate the danger list" *before* M1 built
> detection, so the project produced 543 NPCs, a curation pipeline and a
> 133-row draft that no runtime code had ever read - none of it provable,
> because nothing consumed it. Meanwhile the question that decides whether
> the module can work at all (does a nameplate warn you in time?) had
> never fired once.
>
> The corrected order: **get the trigger and the alert right against any
> mob at all, then decide which mobs deserve one.** A list is easy to
> swap; a detection model that doesn't warn in time is the whole project.
> M0's data work is not lost, just early - it sits on disk and gets wired
> in at M2 once detection is proven.
>
> Practical consequence: v0.x ships with NO danger data. You build a test
> list in-game with `/dhdanger add` on whatever you're targeting. v1 gets
> the real list.
>
> This also absorbs **Q2**. Rather than a separate measurement addon,
> `/dhdanger debug on` times alert -> first hit during ordinary play, so
> the lead-time answer falls out of using the real thing.

**M0 - Feature review + danger-mob list sourcing** (data done, DEFERRED)
Feature table signed off; DangerData.lua (543 NPCs) + Curation.lua (133
curated entries) built and on disk, but deliberately NOT in the .toc and
not read by any code yet. **No longer gates M1** - it is now wired in at
M2, after detection is proven.

**M1 - Trigger and alert** (v0.x - BUILT 2026-08-07, awaiting in-game test)
Modules\DHDanger\Core.lua, following the DHBavin integrated-module
contract (DHTools.Danger namespace, RegisterModule("danger"),
DHToolsDB.danger). All 5 of RareScanner's trigger events, mapped to
DH-Danger's mission rather than copied wholesale (2026-08-08):
NAME_PLATE_UNIT_ADDED, UPDATE_MOUSEOVER_UNIT and PLAYER_TARGET_CHANGED
all alert (GUID -> npcID, match the list, chat + sound); CHAT_MSG_MONSTER_
YELL and CHAT_MSG_MONSTER_EMOTE alert too and, per k-0025, need no curated
"does it yell" flag since the message carries the speaker's GUID; LOOT_
OPENED deliberately does NOT alert (the mob's already dead) but records a
sighting - see "Sightings" below. Per-GUID cooldown so nameplate flicker
can't machine-gun the alert. The k-0022 nameplate prerequisite check at
login, on CVAR_UPDATE, on the config page and in the minimap submenu.
`/dhdanger add|remove|list|sightings|clear|sound|debug`.

Built 2026-08-07, in-game tested same day, extended to all 5 triggers
2026-08-08: harness 40/40, syntax clean.

**Sightings (2026-08-08).** Every confirmed detection - any alert, or a
listed mob's corpse being looted - records last-known position/zone/time
in `ns.db.sightings`. Nothing reads this yet; it's seed data for the
zone-entry fallback k-0026 (below) may need, gathered for free from
things players already do (fighting, looting) rather than something to
backfill from nothing later.

**k-0026 (2026-08-07, in-game, UNRESOLVED) - the central finding so
far.** NAME_PLATE_UNIT_ADDED needs the mob rendered on screen, not just
in range - a mob approaching from outside the camera's view gives ZERO
warning, not a short one, until it's already in view. This breaks the
module's own running example (Stitches walking up behind you). Only the
two chat-based triggers (yell, emote) are unaffected, since they don't
require rendering anything. Mouseover and target-changed are CVar-
independent of nameplates but still need the model on screen, so they
don't escape this either - EXCEPT target-changed via Tab (not click) is
an open, untested question: TargetNearestEnemy may or may not respect
the camera's view frustum the way a mouse click obviously must. Worth
testing before assuming it's just a third instance of the same limit.
No decision made yet on how to handle this - see STATUS.md for the
options under consideration (ship as-is and document it, lean harder on
`yells` curation, or build the zone-entry fallback the sightings table
is seeding).

**M2 - Wire in the real data + alert pipeline**
Add DangerData.lua and Curation.lua to the .toc (note: they use the
ADDON-wide namespace, `local _, ns = ...`, not DHTools.Danger - Core.lua
already captures both, see ns.addonNS) and replace ns.IsDangerous's test
list with the DangerData+Curation merge behind the same one function.
Then the policy layer: per-classification controls, the character-relative
level threshold with its explicit UnitLevel == -1 branch, and severity as
a threshold modifier. This is the layer that decides *whether* to alert;
keeping it separate from *how* keeps both testable.

**M2.5 - Worth-killing flag**
Loot-derived risk/reward, per Chris 2026-08-06. Needs the async
`GetItemInfo` path handled properly. Slots here because it changes what
M3's UI has to express.

**M3 - Alert UI + target button**
The visible warning: banner, sound, fade. Resolves Q4. Danger-styled,
not discovery-styled. **Includes the secure target button** - see
"Targeting the alerted mob". This is the riskiest milestone in the
module: it involves a SecureActionButtonTemplate widget, which means
k-0010's taint wall and k-0018's anchor-family trap both apply. Read
both knowledge entries BEFORE writing any of this frame, and build the
banner around the secure button's constraints rather than adding it
afterwards.

**M4 - Config page + mute list**
DH-Tools config page: enable/disable, per-severity toggles, mute list,
user-added NPCs. Follows DH-Bavin's page conventions.

**M5 - Import converter**
Was "chat monster-emote detection", now moved into M1. Replaced with:
a converter for RareScanner-format custom-NPC import files (format
traced above), so Chris's Alliance-danger list and any future community
list can be ingested without hand-typing NPC IDs.

**M6 - Guild-wide sighting broadcast (k-0026/k-0030)** - design finalized
2026-08-20 with Chris, no longer stretch-only; building now.

Problem: k-0026 - nameplate/mouseover/target detection all require the
mob in the DETECTING player's own camera view, so a mob approaching from
outside view gives zero warning, not a short one. k-0030 (studied
Unitscan Hardcore, never copied - All Rights Reserved): the view-frustum
gate is per-client, so relaying one player's detection to nearby
guildmates/groupmates is a genuine second pair of eyes.

Trigger: only nameplate/mouseover/target detections are ever broadcast
(hooked directly from `ns.Alert`, guid-bearing sources only). Yell/emote
already carry ~300yd and aren't camera-gated, so relaying them adds
little; loot is a dead mob, never a live threat.

Wire format (Sync.lua, PREFIX `DHDangerV1`, k-0009's version-tag rule):
`SIGHT|npcID|guid|cellX|cellY|zone|source`. cellX/cellY reuse
`ns.RecordSighting`'s own `Cell()` rounding - no second coordinate scheme.
guid is the original detector's real UnitGUID (consistent across every
client for one spawned creature), carried through so a relayed alert
keys `ns.Alert`'s cooldown table exactly like a direct detection does -
per creature instance, not per npcID. zone is `GetRealZoneText()` -
UnitPosition's x/y are only comparable within one zone/map, so a
different-zone receiver discards the message outright; no mapID
normalization, no layer field (Classic Era has no reliable layer API -
k-0001 - so there's nothing to gate on; an alert for a mob that turns out
to be on a different layer is an accepted false positive, same asymmetry
k-0037 already prefers for this module). source is the ORIGINAL
detector's source, used on receipt only to pick the right
`SRC_ACCURACY` radius.

Sent to GUILD and PARTY/RAID, whichever the sender is actually in
(Chris). Gated by a new per-character checkbox, "Share my sightings with
guild/group" (`DHToolsDB.danger.shareSync`, default ON) - gates SENDING
only, never receiving; turning it off stops your own detections from
going out, you still hear everyone else's.

Receive side (`ns.ShouldRelayAlert`, pure/testable): the relayed npcID
must still clear the RECEIVING player's own curated/manual/category/
level/mute settings via `ns.IsDangerous` - a relay never bypasses the
receiver's own settings just because a guildmate saw it - and the
reported cell must be within the reporting source's own accuracy radius
(plus one grid cell of rounding slop) of where the receiver actually
stands. If it passes, the receiver calls `ns.Alert(guid, npcID, name,
"relayed")` - a new source label (own `SRC_ACCURACY` entry, ~50yd)
distinct from a directly-seen nameplate/mouseover/target alert, and also
what gets written to that receiver's own `ns.acctDB.sightings` (Chris:
relayed sightings should feed history too - it's the same "free to
collect" data the file's own header already argues for).

Explicitly out of v1: no late-arrival "park unmatched reports and
recheck as the player moves" logic (Unitscan has this via a 120s
`_recent_remote` table) - a relay either matches right now or it
doesn't. Revisit only if it turns out to matter in practice.

## Test strategy
Headless harness under Modules\DHDanger\tests\ from M2 onward (the
pipeline logic is pure and very testable - DH-Bavin's 63-check harness
is the model). Detection and UI need in-game confirmation from Chris;
per README §5, nothing is "done" without it. Q2's lead-time measurement
is an in-game task that cannot be simulated.

## DH-Tools integration
Ships as a DH-Tools module (2026-08-06 "integrated module" decision,
already in PROFILE.md) - own subfolder/namespace under
src\DH-Tools\Modules\DHDanger\, DH-Tools calls into it, never the
reverse (same contract as DHQuests/DHBavin). No standalone-optionality
scaffolding planned (no stated intent to spin this off, matching
DH-Bavin's reasoning) unless Chris says otherwise before M1.
SavedVariables scope (own DHDangerDB vs. DHToolsDB.danger sub-table) is
an M1 decision, not decided here - see Q3.

## Deploy / test / packaging
Follows DH-Tools' conventions - see DH-Tools\PROFILE.md and
claude\ROADMAP.md/README.md. No separate DH-Danger zip workflow.
