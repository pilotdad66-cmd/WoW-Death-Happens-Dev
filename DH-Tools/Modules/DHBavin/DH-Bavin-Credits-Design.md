# DH-Bavin Credit & Reputation System - Design & Milestone Plan
created: 2026-08-31
updated: 2026-08-31 (Reputation report sample parsed; tiers, prestige
grouping, lifetime total, own-balance UI, and GRM's role resolved with
Chris; GRM's alt-linking API verified in-game via the throwaway
GRM-Probe tool - see Decisions)
updated: 2026-09-03 (Test strategy resolved with Chris - four isolation
walls keeping the live donation flow untouched until cutover, folded
into CM1; two separate test lists gating the inbox and outgoing hooks
independently; audit trail expanded to three visibility tiers with
per-role retention; double-spend accepted with Chris's reasoning;
CM9 cutover milestone added. See "Test strategy" and "Audit trail".)
updated: 2026-09-22 (Chris raised three real-world gaps in a design
discussion, no code written: alt-identity needs an officer-visible
view/edit UI on top of GRM auto-resolution, plus a player-submitted-
but-officer-approved self-service path; the Reputation-report/Discord-
name identity mismatch folds into the same reconciliation queue; a new
full-ledger CSV/XLSX export requirement, to ship as a standalone
Windows executable Bavin/officers run themselves, not a script Chris
or Claude has to run; and a test/live data-reset + version-gating
discussion for CM9 cutover. See new sections below. Chris is still
waiting on an actual spreadsheet export from Bavin before CM2's
report-parser spec can be finalized - treat that section as
provisional until then.)
updated: 2026-09-22 (same session, follow-up after reviewing Bavin's
real intake files with Claude: confirmed identity is a three-level
Discord-name/main-character/alt-character hierarchy, not a two-level
one; confirmed the export tool's job is plain CSV/XLSX only, never
Discord-post formatting; clarified `Dhstorage`-style characters are
ordinary storage alts, no special handling; and corrected the
donation-growth estimate from the real ~73,500-row file, reopening
part of the 2026-09-03 no-backfill decision for the officer-side
store. See "Alt-identity management" and the new "Full audit trail &
weekly category reporting" section.)
updated: 2026-09-23 (Chris + Claude processed Bavin's contributors.csv
mapping file and calculated real point totals from the 73,500-row
contribution_data.csv transaction log, cross-checked against the
Discord report rather than trusting it as source data; resolved four
contributors.csv edge cases, found and excluded 194 non-donation
"Exile" sentinel rows, confirmed the report's points are ~10x the raw
Amount's gold value (open caveat: Bavin's manual per-item point bonus
mechanism, pending his confirmation), and found the real calculation
runs a small, consistent +0.86% aggregate above the Discord report -
consistent with rounding-down rather than a data problem. Evaluated
and did not adopt a client-side "self-storage" alternative
architecture. Finalized the milestone rollout/testing order with
Chris, including a new Step 0 (offline historical reconciliation), a
mid-testing "reset to zero" utility folded into CM1, and a Step 9.5
full reseed immediately before cutover. See "Historical data
reconciliation", "Self-storage / client-side computation", and the
revised "Milestone plan" below. Still no code written - Chris will
start with Step 0 in a new session.)
updated: 2026-09-24 (Step 0 completed and CM1 code-complete. Step 0:
Chris confirmed the point-bonus discrepancy is rounding in Bavin's
script and approved seeding with the calculated numbers; identity
resolution run in PowerShell (Python unavailable on this PC) over
contributors.csv + the 73,500-row contribution_data.csv, including a
compound-name explosion fix applied to both files; excluded Guild
Bank entirely and all "Exile" sentinel rows; produced 642 resolved
identity groups (1 in conflict: Thormhammer), seed-dataset.csv (651
mains with lifetime gold/point totals) and review-queue.csv (1
conflict + 1129 unmapped donor names) for officer triage. Validated
against the Discord report by reconstructing each person's true
lifetime total from their tier/prestige history (displayed points
reset to 0 at every tier crossing; the real total never resets) rather
than comparing to the raw displayed number - this was Chris's key
correction to an earlier, meaningless +660% mismatch. Tier-reconstructed
cross-check: 183 matched names, mean +0.79%/median +0.77% above the
Discord-implied total, within Chris's ~1.46% acceptability bar.
CM1: built Modules\DHBavin\Credits.lua - Wall 1-4 isolation (own
DHBavinCreditsDB SavedVariables, two independent test lists gating
inbox/outgoing mail hooks, a master toggle defaulting OFF, hooks
installed only for listed test characters and armed lazily at
PLAYER_LOGIN), its own addon-message prefix DHBavinCreditsV1 (kept
separate from DHBavinV4 per Chris's explicit approval), and an
officer-gated credit multiplier defaulting to 0.60 credits per
reputation point (corrected from this doc's earlier 0.7 figure -
credits and reputation points are tracked as two separate numbers,
never conflated). Config UI deliberately deferred: a full `/dhb
credits ...` slash-command surface (status/toggle/multiplier/officer/
receiver/sender/reset) stands in for the design's planned Config.lua
"TEST ONLY" panel for this pass, to avoid a large edit to the existing
shared Bavin config UI before Chris reviews the scope. Verified via
run-tests.ps1: syntax-clean across the whole addon, existing 129-check
harness unaffected. NOT yet in-game tested - no confirmation yet that
config sync, arming, or the slash commands behave correctly live. No
git commit made yet this session.)
updated: 2026-09-25 (Chris flagged that deferring the config UI risked
losing track of the real access requirements - good catch. Worked
through a four-tier access model (member/officer/mail-recipient/
leader+Loopi - see new "Access tiers" section below) and built the
real UI: Modules\DHBavin\CreditsConfig.lua, a standalone "Bavin Rep &
Credit Config" window opened via a new button in DH-Tools\Config.lua's
existing Bavin officer section (that page is otherwise unchanged, per
Chris's explicit instruction). Tabs across the top (Settings/Roster/
Conflicts/Audit Log) rather than an Excel-style editable grid - no
grid widget is vendored in this addon and a true inline-editable grid
would be a real UI subsystem to build from scratch; Chris accepted
this trade-off. Settings tab is fully wired to Credits.lua's existing
setters (master toggle, multiplier, both Wall 2 test lists, the
Designated Officers list); Roster/Conflicts/Audit Log are placeholder
tabs pending CM2/CM7's data. Credits.lua's `/dhb credits` slash
commands are kept as a diagnostic/scriptable fallback, not removed;
added `/dhb credits window` to open the new UI. Also clarified scope:
the mail recipient eventually being able to hand-edit the raw
reputation source data behind the tooltip is real future work, but
explicitly indefinitely deferred - the current plan is periodic
reimport of a fresh data file (Step 0's approach), not manual edits -
noted in "Access tiers" so it isn't lost, not because it's imminent.
Verified via run-tests.ps1: syntax-clean, 129-check harness unaffected.
NOT yet in-game tested.)
updated: 2026-09-25 (first in-game test pass of CreditsConfig.lua.
Chris reported 8 numbered items: Master Toggle and the two-click Reset
Test Data arm/disarm both confirmed working as designed, no changes
needed. The other 6 were real bugs, all fixed: (1)/(7) the Officers/
Test Receivers/Test Senders list sections, and separately Config.lua's
Bavin-page Editors list, were each anchored to a fixed pool-row slot
(e.g. row 8 of 8) that reserved its full height even when mostly
empty - `Hide()` doesn't collapse a frame's position in a WoW anchor
chain. Refactored `CreateNameListSection` so each section tracks its
last-visible row live and every downstream section/button re-anchors
to that position on every refresh, collapsing unused space. (2) window
opened behind the Config.lua window - fixed with
`SetFrameStrata("HIGH")`. (3) added resizability to
DHBavinCreditsConfigFrame (min 420x400/max 720x900 + grip) - the main
DH-Tools config window turned out to already be resizable. (4)
closing the window left rendered text on screen - root cause was the 4
tab-content frames never getting an explicit anchor or explicit
Hide(), only the active one being the ScrollFrame's scroll child;
fixed with an explicit SetPoint per tab content frame plus explicit
Show()/Hide() in `CreditsConfig_SelectTab`. (6) added plain-English
hint text under the Officers/Test Receivers/Test Senders section
titles. Rebuilt and retested; Chris confirmed the multiplier control
also works and called the fixes usable, while flagging the gap between
each section's add-box and its list is still larger than he'd like -
accepted as a known cosmetic issue, not blocking, not scheduled. All
committed this session (Credits.lua, CreditsConfig.lua, the .toc/
Core.lua/Config.lua edits, this doc, STATUS.md, and the Step 0 intake
deliverables) and pushed to collab-dev.)
updated: 2026-09-25 (CM2 prep: triaged review-queue.csv's 1129
"no_identity_mapping" donor names before starting CM2's seed step.
Built a throwaway GRM-Probe tool (`/dhbgrm run`, same precedent as the
original Step 0 probe) to run all 1129 through `GRM.GetPlayerMain()` -
result was 0 resolved, 1129/1129 nil (GRM has zero record of any of
them), which both confirmed Chris's "quit or never signed up" theory
and settled the previously-untested "name totally unknown to GRM"
edge case (see the GRM contract notes above) - deleted the probe tool
once read back. Then analyzed the 1129 for resemblance to known
names: 12 rows (9 distinct names) were special-character/diacritic
variants of a real character's name (e.g. "fragilé" for "Fragile") -
Chris confirmed these are safe to fold in (3 had two candidate known
names each, but both candidates resolved to the same main already, so
the ambiguity was moot). 93 rows looked like 1-character typos of a
known name, but Chris correctly rejected this as evidence - WoW name
squatting means "Krazzy" existing because "Krazy" was taken usually
means two different players, not a misspelling of the same one; that
bucket was discarded entirely, not folded in. 325 rows shared a 4+
character prefix with a known name (weak "naming convention" signal,
e.g. shared word-fragments like "dark-"/"frost-" more often than a
real family like "Loopi-") - left for manual eyeballing, not bulk
action. Added `alias-corrections.csv` (9 rows) and wired it into
step0-reconcile.ps1, merged straight into the alt-resolution table
right after contributors.csv loads (NOT modeled as a new "Aliases"
tier in the live data model - Chris's Discord->Main->Alts->Aliases
idea was narrowed to a Step 0-only historical-data concern, since the
live CM2 resolver only ever sees real, mail-validated character names
and can't hit this problem going forward). Re-ran Step 0: review-
queue.csv's unmapped count dropped 1129 -> 1120, seed-dataset.csv
grew 651 -> 652 mains, Discord cross-check barely moved (mean now
+0.82%, still within Chris's ~1.46% bar). Remaining 1120 unmapped
names (plus the 325 weak prefix-siblings) are Chris's call for CM2:
eyeball what's worth linking, then likely make the rest their own
mains at the Step 9.5 reseed rather than leaving them in permanent
limbo.)
status: STEP 0 COMPLETE (including a 2026-09-25 review-queue triage
pass - alias corrections applied, GRM-Probe run and retired), CM1
CODE-COMPLETE INCLUDING REAL UI, FIRST IN-GAME TEST PASS DONE - scoped
with Chris 2026-08-31, test strategy
added 2026-09-03, four more discussion topics added 2026-09-22,
contributors data processed and milestone plan finalized 2026-09-23,
Step 0 reconciliation validated and CM1 core (Credits.lua, own prefix,
0.60 multiplier) implemented 2026-09-24, four-tier access model agreed
and CreditsConfig.lua (the real tabbed UI, opened from Config.lua's
Bavin page) built 2026-09-25, first in-game test pass done same day -
6 layout/behavior bugs found and fixed (dynamic row anchoring, window
strata, resizability, tab close, section hints), 2 items confirmed
working with no changes. One known cosmetic issue remains (add-box-to-
list gap still larger than ideal in the three CreditsConfig.lua list
sections) - Chris said he can work with it, not scheduled. Committed
and pushed to collab-dev 2026-09-25. Syntax/harness-clean throughout.

## Concept

Bavin wants to formalize donation tracking into two numbers per guild
member, plus the ability for officers to spend one of them by mailing
items out:

- **Points** ("Reputation") - a running total earned from donations,
  split into tiers (Neutral/Friendly/Honored/Revered/Exalted, reusing
  WoW's own reputation-tier names and point spans - see Tiers below).
  Only ever goes up, except that it resets to 0 the moment a member
  crosses into a new tier (or, once already at Exalted, a new
  "Prestige" lap - see Tiers below). A separate **lifetime total**
  (never resets) is also tracked, for recognition purposes - see
  Decisions.
- **Credits** - a separate, spendable balance, also earned from
  donations but at a configurable multiple of points (not 1:1).
  Unlike points, credits do **not** reset on a tier or prestige
  change - only points reset; credits are a wholly separate running
  balance that only moves on a donation (up) or an officer's
  credit-charge mail (down).

This sits on top of what DH-Bavin already has, not next to it: the
per-item point values are the same `ItemPoints.lua` catalog the
priority-list tooltip and Points Editor already use ("a petri flask is
worth 500 Bavin Points" - that's an existing lookup, not a new one), and
this proposal reuses the module's existing conventions throughout -
guild-roster-verified permissions (never a self-asserted sender),
delta-broadcast + SYNCREQ/SYNCDATA sync, chunked ~200-char payloads,
and a milestone-plan doc that STATUS.md tracks progress against, code
as ground truth once they diverge.

Two mail-processing flows drive it:
1. **Incoming** - when Bavin pulls attached items into his own
   inventory, each item's point value credits the sender (points and,
   at the multiplier, credits). Not every incoming mail should count -
   a checkbox on each inbox message (default = last-selected) tells the
   addon whether to process that message.
2. **Outgoing** - when a Designated Officer mails items to a member,
   the total point value of the attachments debits that member's
   credit balance. The addon checks beforehand that they have enough
   credit and blocks the send if not. Same idea, checkbox on the
   outgoing mail window (default = last-selected), gates whether that
   send gets processed.

## Access tiers (resolved 2026-09-25 with Chris)

Four tiers, from the officer/leader UI discussion that produced
CreditsConfig.lua. Not a re-scope of what mail processing does above -
this is who can VIEW and EDIT what, across every UI this feature has or
will have.

1. **Regular member** - read-only, own points/credits/tier/prestige
   only. A separate window (CM6, minimap-launched quick-actions entry),
   not CreditsConfig.lua - a regular member never gets that window at
   all (see its `CreditsConfig_Open` gate).
2. **Designated Officer** - views everyone's data; edits alt/identity
   mappings to resolve conflicts (Thormhammer-style) and triage
   unmapped donor names. This is CM2's job (the officer-visible view/
   edit UI on top of GRM auto-resolution, from the 2026-09-22 update
   below) - CreditsConfig.lua's Roster and Conflicts tabs are
   placeholders until then. An officer can also manage everything on
   the Settings tab EXCEPT the officers list itself (master toggle,
   multiplier, both Wall 2 test lists - `CanManageCreditsConfigLocal`).
3. **Mail recipient (Bavin)** - eventually able to hand-edit the raw
   reputation source data that backs the tooltip lookup directly (not
   just resolve identity, actually change a point/credit number by
   hand). **Explicitly out of scope for now, and deliberately not on
   any milestone's plan** - the current design keeps that data
   accurate via periodic reimport of a fresh data file (Step 0's
   reconciliation approach, repeated), not manual edits. Written down
   here so the requirement isn't lost, not because it's coming soon;
   revisit only if Chris raises it again, same footing as the
   "self-storage" alternative below.
4. **Guild leader + Loopi (`IsAuthorAccount`)** - manages who holds the
   Designated Officer role (`CanManageCreditsOfficers`, built in
   Credits.lua CM1) and, unchanged and separate, the DH-Bavin recipient
   itself (`Bavin.CanManageRecipient` on the existing Config.lua page -
   this system's "mail recipient" and the credit system's "Designated
   Officers" are two different lists, never conflated in code or UI).

CreditsConfig.lua (CM1, 2026-09-25) is where tiers 2 and 4 actually
live today: a standalone "Bavin Rep & Credit Config" window, opened via
a button in Config.lua's existing Bavin officer section (that page is
otherwise unchanged - Chris was explicit the existing page should stay
as-is). Tabs across the top rather than an Excel-style editable grid -
DH-Tools vendors no AceGUI/grid widget, and a true inline-editable grid
would be real UI-subsystem work from scratch; Chris accepted plain
tabs + row lists + inline add/remove controls instead. Settings tab is
fully wired; Roster/Conflicts/Audit Log are placeholder tabs waiting on
CM2/CM7.

## Tiers (resolved 2026-08-31 from the Reputation report sample)

Point caps per tier, read directly off the sample data (every entry in
a given tier section shares the same cap):

| Tier | Cap |
|---|---|
| Neutral | 3,000 |
| Friendly | 6,000 |
| Honored | 12,000 |
| Revered | 21,000 |
| Exalted | 50,000 (loops - see Prestige below) |

Crossing a cap resets points to 0 and advances to the next tier, same
rule Chris originally described. These are WoW's own real reputation
tier point spans, reused here as a deliberate theme.

**Prestige - confirmed, with a parsing correction.** Exalted is the
top tier - there's nowhere higher to reset into, so once a member
fills the 50,000 Exalted bar they start another 0-50,000 lap inside
Exalted itself, labeled Prestige I, then Prestige II, and so on. **No
cap** - it runs indefinitely (Chris confirmed). Parsing correction: a
`[Tier[ - Prestige N]]` header line applies to *every* main/alt pair
that follows it, until the next header line - not just the single
entry immediately after it (confirmed: Blood sits under the same
"Exalted - Prestige I" header as Kilroth, several entries later, with
no per-person label of its own). The parser groups by last-seen-header,
not by proximity.

## Decisions made 2026-08-31 (Chris, this session)

**Identity: track by person, not by character.** A member's alts and
main all feed the same points/credit balance, keyed to whichever
character is their "main."

**Alt-linking source - two-part, and now verified end-to-end.** The
Reputation report gives an accurate main-to-alts snapshot, but only as
of go-live - it's the output of Bavin's Excel/Discord process, and
**that whole process is what this feature exists to retire**, so
there will be no further reports to reconcile against once DH-Bavin
goes live. That means:
- **CM2 (one-time seed):** parse the report once, at go-live, for
  the starting points/tier/prestige/lifetime numbers AND the
  alt-to-main snapshot as it exists that day.
- **Ongoing, post-launch - GRM, verified in-game 2026-08-31.** Using
  the throwaway GRM-Probe tool (built and run this session, now safe
  to delete), confirmed GRM's own public API resolves any character to
  their main correctly and reliably:
  - `GRM.GetPlayerMain(name)` - given ANY character name, returns
    their main's name (or their own name, if they already are the
    main). This is the one function DH-Bavin actually needs at
    runtime. Verified against Loopi and all 6 of her real alts
    (Loopidot, Loopidru, Loopishoot, Loopiblast, Lloopi, Loopipal) -
    every one resolved back to `Loopi-SkullRock` correctly.
  - **Names must be realm-qualified** (`CharName-RealmName`, realm
    spaces stripped, e.g. `Loopi-SkullRock`) - a bare name silently
    returns nothing useful. DH-Bavin needs to build this from
    whatever name it has (mail sender/recipient) plus
    `GetRealmName()` when no `-Realm` suffix is already present.
  - Supporting calls, useful for a "manage alt links" admin UI later:
    `GRM.IsMain(name)`, `GRM.GetListOfGuildMains()` (enumerate all
    mains), `GRM.GetSortedAltNamesWithDetails(mainName)` (a main's
    alts with level/class/join-date). **Avoid `GetAltNamesList`** -
    it came back empty even for Loopi despite her having 6 confirmed
    alts; `GetSortedAltNamesWithDetails` is the reliable one.
  - GRM's own data isn't instantly ready after login - some of its
    internal tables were still nil ~3 seconds after PLAYER_LOGIN in
    testing, but fine by ~20 seconds. DH-Bavin's own GRM calls should
    tolerate this (pcall, plus falling back to the manual-override
    table or simply "unresolved for now" rather than erroring) rather
    than assuming GRM is ready the instant DH-Bavin's own code runs.
  - **Edge case confirmed 2026-09-25 (GRM-Probe run #2, see the CM2
    prep changelog entry below):** for a name GRM has no record of at
    all (not just "no alts"), `GetPlayerMain` returns nil/empty rather
    than erroring - ran all 1129 of review-queue.csv's
    "no_identity_mapping" names through it and got 1129/1129 nil, 0
    resolved. CM2's live resolver can treat nil the same as "unknown,
    fall through to manual-override table or officer review queue" -
    no special-case handling needed for this path.
  - A manual add/edit table inside DH-Bavin's own config remains the
    fallback for anything GRM doesn't have, same as before.

**Officer role: new, separate "Designated Officers" list.** Not the
same as priority-list editors. Same permission idiom as everything
else in this module (guild-leader-settable, guild-roster-verified on
receipt, part of the SYNCREQ/SYNCDATA handshake, `IsAuthorAccount()`
override applies same as everywhere else) but its own broadcast message
and its own stored list.

**Ledger authority: officer-replicated, not guild-wide.** The full
ledger (every member's points/credits/tier) only replicates among
Bavin + Designated Officers - the same broadcast/SYNCREQ pattern
already used for recipient/editors/priority list, just addressed to a
much smaller set (a handful of clients, not ~1000). Regular members'
clients do **not** hold the full ledger.

**Balance visibility: cached locally, refreshed by push + pull - not
a live query.** A member's own client caches its own points/credits/
tier/prestige/lifetime total and shows that. It's refreshed two ways:
- **Targeted push, batched per mail session.** Bavin processes mail in
  batches (his own words: opens ~100 in a row). Rather than pushing an
  update after every single mail, the addon accumulates changes locally
  and flushes them once the mailbox closes (`MAIL_CLOSED`, confirmed by
  Chris as the right trigger - closing the mailbox window itself, not
  any individual mail) - one small message per *affected player*,
  addressed directly to them, not broadcast to the guild. Same batching
  applies to an officer's outgoing-mail session.
- **Pull on login.** Each character, once per login, sends one small
  request to any reachable officer/Bavin client asking for its own
  current numbers. This is the catch-all for anyone who was offline
  when a push went out, and it's also what seeds a fresh install.

This was chosen specifically over both "replicate the full ~1000-row
ledger to every client" (permanent guild-wide broadcast traffic on
every single transaction, forever, plus large full syncs on every
login) and "query live every time someone checks their own numbers"
(traffic scales with how often people look, not with how often their
balance actually changes). Steady-state cost here is close to zero:
nothing moves unless a balance actually changed, and then only to the
one player it changed for.

**Own-balance UI: a minimap quick-action window, plus wherever else
fits.** DH-Tools already has a left-click minimap quick-actions menu
(shipped v1.2.2) - this gets a new entry opening a window with the
player's own points/credits/tier/prestige/lifetime total. Chris was
fine with it also surfacing elsewhere in DH-Tools if a natural spot
comes up; the minimap entry is the one firm requirement.

**Lifetime total: yes.** A separate number that only ever goes up,
alongside the tier-resetting points counter - for recognition, not
gating anything.

**Multiplier: 0.60 credits per point, Bavin-configurable** (corrected
2026-09-24 from the 0.7 originally noted here - Chris set the actual
default; credits and reputation points are two separate tracked
numbers, never the same figure). A numeric field on the officer-gated
config page, same idiom as an item-points override - not hardcoded.
CM1 implements this as an officer-gated slash command
(`/dhb credits multiplier <n>`) pending the Config.lua UI panel.

**Reputation report: one-time paste-in seed, format now known.**
Bavin will paste in this text once, at go-live. Format (confirmed
from the 2026-08-31 sample):
```
<TierName>[ - Prestige N]
<MainName> — <currentPoints> / <tierCap>
<alt1>; <alt2>; <alt3>; ...;
<MainName2> — <currentPoints> / <tierCap>
<alt list>;
...
<NextTierName>
...
```
A tier/prestige header line, then repeating (main line, alt-list line)
pairs, all belonging to the last-seen header until a new one appears
(see Prestige correction above). The alt-list line is that main's full
character set (semicolon-separated, unlimited count). Per Chris:
deleted/permadeath'd characters stay in the list permanently, and a
character remade with the same name is treated as the same identity -
the parser needs no special handling for either, it's just a name
string.

**Audit trail: yes - three visibility tiers (confirmed 2026-09-03).**
Every point-earning and credit-spending event gets logged (who, what
item, points/credits delta, who processed it, when). Who sees what:
- **Credit processor (Bavin; LoopiBav during testing) - everything,
  forever.** No age cap, no pruning: Chris's explicit instruction is
  that the processor never deletes anything. The full log is already
  on this client as part of the officer replica.
- **Designated Officers - the full replica, plus a "what I sent"
  view.** That view is a local filter on `processedBy == self` over
  data they already hold, so it costs nothing extra. Officer-side
  retention is a **rolling 12 months**; rows older than that prune
  locally. The processor's copy is what makes this safe to prune.
- **Regular members - their own last 50 transactions.** Members
  deliberately don't hold the ledger, so their rows reach them the
  same way their balance does: appended to the existing targeted
  push at `MAIL_CLOSED`, capped locally at 50.

Cross-member leakage isn't possible by construction - a member's
client only ever receives rows addressed to it, so there is no
permission check to get wrong.

**No history backfill (the decision that keeps this cheap).** The
push carries only rows generated in that mail session - typically 1-3
per donor - not the member's whole history, and rows carry `itemId`
with the client resolving the name via `GetItemInfo` rather than
sending name strings. The login pull returns the balance only; it
does NOT backfill transaction history. So a member's history starts
accumulating from install, and someone who reinstalls or moves
machines loses their history but keeps a correct balance (balance is
authoritative from the officer replica). This is what keeps the
per-session payload inside the existing ~200-char chunk convention
instead of turning the login pull into a bulk transfer. Chris flagged
that the member-side view could be deferred if it risked overloading
the packets - with no backfill it doesn't, so it stays in CM6/CM7.

This log also functions as the safety net for the double-spend
question below - see Risks.

**Double-spend risk: accepted, not hard-locked.** Because the full
ledger only replicates among a small, fast-syncing officer set (not
the whole guild), the window for two officers to both approve a spend
against stale data is small. Rather than adding a live "confirm with
Bavin before every send" round-trip (which would need Bavin's client
reachable at the moment of every single outgoing mail - a real
availability problem), this proposal accepts the small residual risk
and leans on the audit trail: a resulting negative balance is visible
and traceable, and gets reconciled the same social way DH-Bavin's
permission model already works (guild-social-trust, not cryptographic
- stated plainly in the existing PROFILE.md, same spirit here).

**Confirmed 2026-09-03 with Chris's own reasoning, which is stronger
than the original framing:** a negative balance is *self-limiting*.
The worst case is that a member overspends, goes negative, and simply
can't buy anything else until they earn back past zero - the error
corrects itself with no intervention and no lost value to the guild.
The one case it doesn't cover is someone deliberately cashing out
their credits on the way out of the guild, and Chris's call is
explicitly not to guard against that: it's a social problem with a
social fix, and the hard guarantee would cost an availability
dependency on the processor's client for every single officer mail.
Decision closed - not revisiting unless the outgoing flow shows a
problem in practice.

## Open questions - still need Bavin's and/or Chris's input

The core 2026-08-31/2026-09-03 plan has no open items of its own - the
last one (mail-session push boundary) was confirmed 2026-08-31:
`MAIL_CLOSED` on Bavin's incoming side, per-send on the outgoing side.
**2026-09-22 additions, updated as they resolved:**
- ~~Whether the Reputation-report matches this doc's parser format~~ -
  resolved: real intake files reviewed with Chris (see "Alt-identity
  management" and "Full audit trail" sections).
- ~~The Discord-name -> main -> alts mapping file~~ - resolved:
  `contributors.csv` received and processed 2026-09-23 - see
  "Alt-identity management".
- ~~Discord-post generation vs. clean-data export~~ - resolved: the
  export tool produces plain CSV/XLSX only; Bavin's own downstream
  process still turns that into the actual Discord post, same as
  today.
- Export tool language/library choice (Go vs. C#) - see Data export.
- Export tool distribution point (GitHub release asset vs. something
  else) - see Data export.
- Version-floor gate: hard-block vs. warn-only when a client is below
  `MIN_CREDIT_VERSION` - see Test/live data reset & version gating.
- ~~Bounded in-game history window + export-as-archive~~ - confirmed
  2026-09-22 (see "Full audit trail & weekly category reporting").
  Exact window length (6-8 weeks proposed) still tunable in CM1.

**2026-09-23 additions:**
- **Bavin's manual per-item point-bonus mechanism** - whether
  `contribution_data.csv`'s Amount already reflects bonus points Bavin
  sometimes adds without changing an item's gold value. Chris is
  checking with Bavin directly; gates finalizing CM2's real-totals
  calculation - see "Historical data reconciliation".
- **Two unexplained outliers** - Sayagirl (+41.9%) and Xeriik (+33.1%)
  compute higher than their Discord-report number by more than the
  rest of the dataset, and in the wrong direction to be explained by
  the missing-bonus-points theory. Not investigated further; revisit
  if they turn out to matter once Bavin's answer is in.

All prior decisions (2026-08-31, 2026-09-03, 2026-09-22, 2026-09-23)
are settled; Step 0/CM1/CM2 are ready to start (Chris picking up with
Step 0 in a new session) once Bavin's point-bonus question is answered
and his formal sign-off on the plan as a whole is reconfirmed (last
confirmed pending 2026-09-14).

## Data model (proposal)

New per-person record (keyed by resolved main-character name), living
in the **separate credits SavedVariables file** (Wall 1 - see Test
strategy; superseded an earlier draft that put this in `DHBavinDB`
alongside the existing recipient/editors/priorityList fields, which
would have put live v1.0 state in reach of a credit-system bug),
replicated only among Bavin + Designated Officers per the Ledger
authority decision above:

```
{ mainName, points, credits, tier, prestige, lifetimePoints, lastUpdated }
```

`tier` is one of Neutral/Friendly/Honored/Revered/Exalted; `prestige`
is an integer (0 until Exalted is reached, then 1, 2, ... uncapped,
per Chris). `lifetimePoints` only ever increases, independent of
tier/prestige resets. Tier caps are constants
(3000/6000/12000/21000/50000), not per-record data.

Alt resolution algorithm (character name -> mainName): normalize the
name to `Name-Realm` (append the local realm via `GetRealmName()` if
no `-Realm` suffix is already present), then try, in order: (1) the
manual-override table in DHBavinDB, (2) `GRM.GetPlayerMain(name)`
wrapped in `pcall` (GRM may not be loaded, or its data may still be
initializing), (3) fall back to treating the name as its own main if
neither resolves anything (matches "a character with no linked alts is
trivially their own main"). The one-time Reputation-report import
(CM2) seeds the initial alt table; GRM covers everything after go-live.

A transaction-log entry (audit trail):

```
{ timestamp, direction (earn/spend), character, resolvedMain,
  itemId, pointsValue, creditDelta, processedBy }
```

`itemName` is deliberately NOT stored or transmitted - it's resolved
at display time from `itemId` via `GetItemInfo`, which keeps rows
small enough for the member-side push to fit the existing chunking
convention.

Retention differs by role (see Audit trail decision):
- **Credit processor** - uncapped, never pruned.
- **Designated Officers** - rolling 12 months, pruned locally.
- **Regular members** - own rows only, capped at the most recent 50.

Size note: the processor's uncapped log is the one table that grows
without bound. At a rough guess - a few hundred transactions a week
across the guild - that's on the order of a megabyte or two per year
of SavedVariables, which WoW handles but which is worth actually
measuring after the first few months rather than assuming. An
export-and-purge button stays available in CM7 as an escape hatch
even though the standing instruction is never to delete.

## Permission model addition

**Designated Officers** (`CanChargeCredit`, mirroring the existing
`CanManageRecipient`/`CanManageEditors`/`CanEditList` naming): settable
by the guild leader (or the author-account override), broadcast on
change the same way RECIPIENT/EDITORS are (`OFFICERS|name1,name2,...`,
receiver-verifies the sender is the guild leader against its own
roster cache), part of the SYNCREQ/SYNCDATA handshake. Being a
Designated Officer is what's checked before an outgoing credit-charge
mail is allowed to process - separate from, and not implied by, being
a priority-list editor.

## Sync protocol additions (proposal, to refine in CM3)

New message types over DH-Bavin's existing prefix/chunking convention:
- `OFFICERS|name1,name2,...` - guild-leader-gated, same shape as
  EDITORS.
- An officer-only ledger sync (full replica among Bavin + Designated
  Officers) - likely its own SYNCDATA-style handshake plus delta
  broadcasts on every processed mail, scoped to that small recipient
  set rather than GUILD-wide.
- A targeted push (`LEDGERPUSH|mainName|points|credits|tier|prestige|
  lifetimePoints`) addressed directly to the affected player - not a
  GUILD broadcast, since individual balances shouldn't go out to
  everyone.
- A login-time pull request/response for a player's own numbers.

Whether this needs a prefix version bump (the existing convention,
e.g. k-0012's `DHBavinV1` -> `V2` when SYNCDATA's payload shape
changed) depends on the exact wire format worked out in CM3 - noted
here so it isn't forgotten, not decided yet.

## Mail processing flows

**Incoming (Bavin).** Checkbox on each inbox message, default =
last-selected. When checked and Bavin pulls the attached item(s) into
his inventory, each item's point value (existing `ItemPoints.lua`
lookup) credits the sender's resolved main: points += value (tier/
prestige-crossing checked against the caps above), lifetimePoints +=
value (never resets), credits += value x multiplier (no reset),
transaction logged. Unchecked mail is untouched by the addon either
way - Bavin still takes the items, they just aren't counted.

**Outgoing (Designated Officer).** Checkbox on the SendMailFrame,
default = last-selected. Before send, the addon totals the attached
items' point values and checks that against the recipient's cached
credit balance (from the officer-replicated ledger); insufficient
credit blocks the send with a clear message, mirroring how BagMail.lua
already fails loudly rather than silently on its unverified frame
hooks. A successful send deducts credit and logs the transaction.

Both checkboxes are simple sticky UI state (remember the last value)
and don't need further design.

## Test strategy - isolating the live system (resolved 2026-09-03)

**The hard constraint, in Chris's words: the existing system cannot
break until a full cutover after testing is complete.** Bavin keeps
processing donation mail with the current Excel/Discord process for
the entire development and test period. Nothing below is allowed to
touch that. Four independent isolation walls, any one of which would
be sufficient on its own - all four together mean a bug has to defeat
every one of them before it can reach live data.

**Wall 1 - separate SavedVariables file.** All credit-system state
(ledger, alt-override table, transaction log, config) lives in its own
permanent variables file, NOT in `DHBavinDB` alongside the v1.0
recipient/editors/priorityList data. A wrong or corrupt credit write
cannot damage v1.0 state, and deleting the credit file is a complete
reset with zero effect on the shipped module. This also makes the
whole feature removable by deleting one file.

**Wall 2 - two separate test lists, distinct from the live config.**
Three keys, none of which is the existing `recipient` field:
- `recipient` - existing, live, Bavin. Owned by the old donation
  flow. The credit code never reads it, writes it, or keys off it.
- `creditTestReceivers` - characters allowed to install the INBOX
  hook (the credit-processor side). Starts as one dedicated test alt
  Chris is creating for this purpose (working name "LoopiBav"); can
  grow.
- `creditTestSenders` - characters allowed to install the OUTGOING
  `SendMailFrame` hook (the officer credit-charge side). Starts
  EMPTY; can grow.

**Two lists, not one**, because the two hooks live on different
clients and must be opted into independently. A Designated Officer
who is not on `creditTestSenders` gets no outgoing hook during the
test phase - role or not. This closes a gap in an earlier single-list
draft, which gated only the inbox hook and would therefore have armed
the outgoing hook for any real Designated Officer, Bavin included if
he holds that role.

**Bavin appears on neither list**, which is what makes "shadow mode"
unnecessary: an earlier proposal for per-entry active/shadow modes
was considered and dropped once he was ruled out entirely.

**Wall 3 - ships inert.** The credit code can ship in DH-Tools
releases during development. Master toggle defaults OFF, with an
explicit warning in the config UI not to enable it. A member who
updates DH-Tools gets the code and no behavior.

**Wall 4 - both mail hooks install only for listed test characters.**
The structural guarantee, and deliberately stronger than gating the
*processing*:
- NOT this: hook mail on every client, then check the list inside the
  handler and return early. One bad early-return and the addon is in
  Bavin's mail.
- THIS: check list membership FIRST, and install a hook only if this
  character is on the list for that specific hook -
  `creditTestReceivers` for the inbox hook, `creditTestSenders` for
  the outgoing `SendMailFrame` hook. On every other client -
  **Bavin's included** - that mail code path does not exist at all.
  There is nothing to misfire.

So during the whole test phase DH-Bavin on Bavin's client behaves
exactly as it does today, byte for byte, because the credit module
never reaches either hook-installation step. Reputation-point
crediting and credit earning are both downstream of the inbox hook, so
they inherit that gate together - no separate guard needed, and no way
for one to arm without the other.

**Two independent conditions** must both be true before a single mail
is touched: the master toggle is ON *and* this character is on the
list for that specific hook. Ships with the toggle OFF and both lists
empty, which is the inert default - a member who flips the toggle on
out of curiosity still gets nothing.

**Arming mechanics.**
- Arming is lazy and evaluated on `PLAYER_LOGIN`, not at addon load -
  the character name isn't reliably known that early.
- Adding a name arms it without a reload.
- Removing a name sets the module inert immediately, but fully
  clearing the installed hook requires a `/reload`. Un-hooking cleanly
  isn't reliable in this API, so the config section states this
  plainly rather than pretending removal is instant.

**Config UI - officer config section of the Bavin Points page**, not a
new window in DH-Tools. A temporary DH-Tools window was considered and
rejected: the Points config page is already officer-gated, it's where
the rest of the module's config lives, and a temporary window is a
frame we would have to build and then delete. The section holds the
master toggle plus add/remove rows for BOTH test lists (receivers and
senders, clearly labeled as separate), is headed as TEST ONLY with the
do-not-enable warning, and comes out whole at cutover.

**Cutover is a config change, not a migration.** Empty both test
lists, make Bavin the live credit processor, remove the TEST ONLY
section, flip the default. The live `recipient` field never moved, so
if the credit system has to be pulled after cutover the old flow is
still sitting there untouched.

**Deferred, doesn't block anything:** whether at cutover the processor
list collapses to a single field or stays a list with a "one entry in
production" rule. The list works for both.

**Test approach: extended soak, not a dual run.** Running the new
system alongside Bavin's existing one to compare outputs was
considered and rejected - it would require porting or reproducing
Bavin's own Excel/Discord logic to compare against, which is exactly
the thing this feature exists to retire. Instead: Chris drives the
test alt as receiver, sends outgoing test mail from listed sender
alts, and keeps cycling until there's enough confidence to cut over.
Other guild members will also mail the test alt - knowingly, with
junk and low-point items, so there is nothing to re-credit when the
test ledger is wiped at cutover. That means real sender names, real
alt-resolution cases, and real item variety ARE covered by the soak.

**Residual risk this strategy does NOT cover.** Two things, both
about scale rather than correctness:
- **Volume.** Bavin's real workload is ~100 mails opened in a row.
  The soak won't naturally reproduce that, so the `MAIL_CLOSED` batch
  flush and the push traffic it generates stay unproven at full size
  until go-live. Worth planning a deliberately low-volume first live
  session rather than a full batch.
- **Officer-side breadth.** The outgoing flow will be exercised by
  Chris's listed sender alts, not by the full Designated Officer set,
  so multi-officer concurrent use (and with it the real double-spend
  window) isn't meaningfully tested until cutover. Accepted - see the
  double-spend decision.

Tier/prestige math, the report parser, and the sync layer are all
testable headless and don't depend on either gap.

## Alt-identity management & Reputation-report reconciliation (raised 2026-09-22, Chris - no code yet)

Two real gaps in the 2026-08-31 alt-linking plan, surfaced by Chris in
a design discussion:

**Gap 1 - an out-of-guild alt has no GRM record at all.** GRM's
alt-linking data is built from the guild's own roster, so a character
that donates but has never been in Death Happens - a common case, per
Chris - is invisible to `GRM.GetPlayerMain()` no matter how long GRM
has been running. The existing fallback chain (manual override, then
GRM, then treat as its own main - see Data model) already handles this
mechanically, but it was designed as a quiet failure path, not a
workflow - nobody currently has a reason to notice an out-of-guild
donor got silently treated as their own separate identity instead of
being folded into their main's balance.

**Real complication, clarified 2026-09-22 against real intake data:
identity is three levels, not two.** The canonical "who gets credit"
identity is often a **Discord name**, not any in-game character name
at all - confirmed against Bavin's actual Discord post sample. The
real hierarchy is:

    Discord name -> main character name -> alt character names

and the Discord name is frequently (not always) also one of the
character names - which is exactly what made this look like a
hand-entry mistake before real data was in hand. It isn't one. GRM's
`GetPlayerMain()` only ever resolves the bottom link (alt character ->
main character); it has no concept of Discord identity, so it can
never supply the top link by itself. **Bavin is providing a separate
Discord-name -> main -> alts mapping file before testing starts**
(Chris will add it to `intake\` once received) - format and
completeness are unknown until then, so CM2's exact resolution logic
stays provisional (see Open questions).

**Resolved direction: canonical ledger identity keys on Discord name
when known, main-character name as fallback.** A person's ledger
record keys on whichever identity is most durable for them: their
Discord name if the mapping links one, otherwise the resolved main
character name. Both link levels need to be visible and editable in
one place, not just the alt-to-main level originally scoped:

- **View:** every resolved identity - Discord name (if linked), main
  character, and full alt list, however each link was made (GRM,
  manual override, or the mapping-file import) - listed and editable
  by a Designated Officer or Bavin at any time. This is the "see and
  edit the data" capability Chris asked for, on top of automatic GRM
  resolution, not instead of it.
- **Unresolved-donor list, sortable (Chris, 2026-09-25).** The
  officer-editable list of donors CM2's resolver couldn't place (the
  live counterpart of Step 0's `review-queue.csv`) shows each entry's
  **Latest Donation date** alongside the name, and is sortable by
  both name and date - not just a flat unsorted dump. Step 0's
  reconciliation script already computes this (`latestDonation`
  column added to `review-queue.csv` 2026-09-25, `yyyy-MM-dd`, max
  date per unresolved donor from `contribution_data.csv`), so CM2's
  seed step carries it straight into the live table rather than
  deriving it fresh. Going forward, a new unresolved live donation
  updates that entry's Latest Donation the same way.
- **Manual link, officer-added:** unchanged from the existing
  manual-override table in Data model, now covering both link levels
  (character->main, and main->Discord) - the fallback for anything GRM
  doesn't know (GRM can never supply the Discord level at all).
- **Self-service link, new:** a slash command (e.g. `/dhb linkalt
  <charname>`) lets a player register their own alt. It writes to a
  **separate pending-links table**, not the live manual-override
  table, and has zero effect on point/credit resolution until an
  officer approves it from the Alt-Link Manager. Rejected entries are
  simply dropped - the "not live until officer review" behavior Chris
  asked for.
- **Mapping-file import reconciliation:** once Bavin's file is in
  hand, CM2's parser seeds all three levels at once. Any row that
  doesn't cleanly resolve (an alt GRM has never heard of, a Discord
  name with no obvious character match) drops into the same review
  queue as a pending self-service link, tagged with its raw source
  text, for an officer to resolve once using their own knowledge of
  the guild.

**Storage alts are ordinary alts - no special handling.** Clarified
2026-09-22: `Dhstorage` (seen as a "From" donor in the raw CSV) is a
real member's own dedicated storage/bank alt - this game version has
no true guild bank, so members park low-level alts in a city to hold
items instead. It resolves through the same alt-linking as any other
character; nothing distinguishes it in the data model.

This extends CM2 (three-level parser + review-queue plumbing) and adds
a small UI surface to CM7 alongside the existing audit-trail views,
rather than opening a new milestone.

**Mapping file received and processed, 2026-09-23.** Bavin's
Discord-name -> main -> alts mapping file (`contributors.csv`, 2338
rows) arrived and was processed with Chris this session, resolving to
643 distinct identity groups. Four concrete decisions came out of
reviewing it against real data:

- **Direct contradictions** (a name claimed as its own identity in one
  row but listed as someone else's alt in another - the "Thormhammer"
  case) **go to the officer review queue** above, same as any other
  conflict CM2's resolver can't confidently settle itself.
- **Compound rows** (a single cell listing multiple names via `/` or
  parentheses) **get exploded and trusted** - each name becomes a
  linked alt of that row's main.
- **"Guild Bank" is excluded entirely, not treated as a person.** It's
  the largest single group in the file (53 characters) but is shared
  guild storage, not an individual donor - CM2's seed must never
  credit it.
- **contributors.csv seeds identity only, not point totals.** The
  Discord Reputation-report posts are confirmed partial, not the
  source of truth for actual point/credit values - see "Historical
  data reconciliation" below for where the real totals come from.

## Data export - new requirement (2026-09-22, Chris)

Chris wants the full ledger (and ideally the transaction log)
exportable to CSV/XLSX, with a constraint that shapes the whole
approach: **it has to run without him or Claude involved.** He
travels for work and is off-grid for weeks at a time; Bavin doesn't
use AI tools. An officer needs to be able to run this alone, any time,
on their own PC.

**Confirmed 2026-09-22: plain CSV/XLSX, not a formatted Discord
post.** Bavin doesn't use markdown. The tool's job stops at clean
tabular data - whatever script turns that into the actual Discord post
text (his today, possibly ours later if it's ever worth building) is
explicitly out of scope here.

**Why this can't be an in-addon feature alone.** WoW's addon sandbox
has no file-system write access beyond SavedVariables (which only the
game client itself writes, on logout) - an addon cannot produce a
.csv or .xlsx file directly. Bavin's existing in-game copy-box
(points tooltip data) still works as a quick manual fallback but
doesn't scale to "the whole ledger, unattended."

**Resolved direction: a standalone Windows executable, not a script.**
Chris was clear this must NOT be a PowerShell/Python script that
assumes Claude (or him) is there to run it or troubleshoot its
environment - Bavin needs something he double-clicks. Shape of the
tool, pending actual implementation:

- **What it reads:** the credits SavedVariables file directly (Wall
  1's separate file, not `DHBavinDB`) from whichever officer's own PC
  it's run on - Bavin and each Designated Officer already hold a full
  local replica of the ledger per the existing sync design, so the
  export tool never needs network access or a "connect to Bavin"
  step. SavedVariables Lua is a plain, non-executable table literal
  (no functions, no control flow) - safe to parse with a small
  hand-written table parser rather than needing an actual Lua runtime.
- **What it writes:** .csv and/or .xlsx, written next to itself or to
  a folder the officer picks once and the tool remembers (a tiny local
  config file beside the .exe) - no command-line arguments required
  for the common case.
- **Distribution shape:** compiled to a single self-contained binary
  so nothing else has to be installed on the officer's machine -
  candidates are Go (a small hand-rolled or off-the-shelf Lua-table
  parser, `excelize` for .xlsx output, trivially cross-compiles to a
  single static .exe) or C# published as a self-contained single-file
  executable. Not chosen yet - an implementation decision for whenever
  CM7 is actually built, not today.
- **Packaging gap to solve later:** this is not an addon file, so it
  doesn't belong in either the release or test-build zip workflows
  (ROADMAP's Packaging rules cover only .lua/.toc/Libs\ runtime
  files). It needs its own distribution point - most likely a
  standalone GitHub release asset Chris shares with Bavin/officers
  once, separate from the DH-Tools addon zip. Flagging now so it isn't
  assumed to "just ship inside the zip" later.

**Scope note:** this broadens what CM7 already sketched as an
"export-and-purge escape hatch" for the processor's uncapped log (see
Data model's Size note) into the general-purpose export Chris is
asking for here - one tool serves both needs rather than building two.

## Test/live data reset & version gating (raised 2026-09-22, Chris - no code yet)

**Data reset at cutover: already solved, no new work needed.** Chris
asked about naming the test-phase data store with a `-test` suffix and
renaming it at go-live. That's not needed and would add a real risk
(a rename step that has to be gotten right, on Bavin's own PC, without
Chris there) the existing design doesn't have: Wall 1 already keeps
ALL credit-system state in its own SavedVariables file, entirely
separate from `DHBavinDB`, and CM9's cutover plan already IS "wipe the
test ledger" - deleting/clearing that one file, not renaming anything.
Worth stating plainly so this doesn't get rebuilt: the suffix/rename
approach was implicitly considered and superseded by the separate-file
design back on 2026-09-03, for exactly the reason Chris raises now
(avoiding a fragile in-place migration).

**Mid-testing reset, new 2026-09-23 - a related but distinct need.**
Chris also wants the ability to wipe and reseed test data at any point
*during* testing, not just at cutover - useful for retrying after a
bad test run without waiting for CM9. This reuses the same
separate-file design (wipe/clear that one file) but is a standalone
utility built in CM1 alongside the rest of Wall 1, callable on demand
throughout CM2-CM8, and distinct from Step 9.5's full reseed (which
specifically refreshes the seed data from current reality right before
cutover) and from CM9's own cutover flip. See "Milestone plan" for
where each lands.

**Version gating - Chris's question: is it even possible, given the
game can't check for new releases?** Correct that a true "is this the
single most recent version Chris has published" check is impossible
from inside the addon sandbox - there's no outbound internet access to
ask. But this codebase already has two working precedents for the
version of the problem that's actually useful, both worth reusing
rather than re-solving:

- **DH-Air's `MIN_QUEUE_VERSION` floor gate (k-0034):** a hardcoded
  floor baked in at build time, checked against messages from OTHER
  clients' addons (not against the internet) - lets an up-to-date
  client refuse a known-old, known-buggy client's messages before they
  pollute shared data.
- **DH-Tools' `LAST_RELEASE_VERSION` peer-mismatch notification
  (k-0048):** clients compare versions with whatever peers they
  actually talk to and surface a "you're behind" nudge locally when a
  peer looks newer.

**Recommended shape for the credit system, same idiom:** a
`MIN_CREDIT_VERSION` floor on the officer-ledger sync protocol (CM3).
A receiving Bavin/Designated-Officer client rejects (doesn't merge) a
sync or transaction message tagged below that floor, rather than
silently accepting data from a stale peer into the shared replica.
This is a much stronger guarantee here than it could ever be for the
~1000-member guild-wide case DH-Air/DH-Tools use it for, precisely
because the officer/Bavin set is small - every one of them can
plausibly be asked to update within a day.

This protects the two actions Chris named - Bavin opening donation
mail, an officer sending a credit-charge mail - at the exact point
they'd actually do damage: writing to or merging into the SHARED
officer replica. It does NOT (and cannot) catch a client that simply
hasn't talked to a newer peer yet - that gap is structural, not a bug
to fix.

**Open decision for Chris/Bavin, not resolved here:** should a client
below the floor hard-block the mail-hook actions entirely (matching
DH-Air's queue gate), or just warn loudly and let the officer proceed
at their own risk? Leaning toward hard-block given real credit/point
values are at stake (higher cost of a silent bad merge than DH-Air's
queue-count UX), but this is exactly the kind of call README §14
reserves for Chris before any code gets written.

## Full audit trail & weekly category reporting - scope change (2026-09-22, Chris)

Chris corrected an earlier assumption: Bavin needs a **full donation
audit trail**, not just running balances. Confirmed against real data
why: Bavin already publishes a weekly (sometimes daily) top-3-per-
category leaderboard across all 17 item categories (see the Discord
post sample) - that can only be computed from row-level transactions
(date + category + amount per donation), never from a single
cumulative point counter. This reopens the 2026-09-03 "no history
backfill" decision, but only partly:

- **Unaffected:** the member-facing push (own balance + last 50 rows,
  no backfill) - members don't need category history, this was never
  about them.
- **Reopened:** the officer/processor-side store. It now needs to be a
  real per-transaction ledger (date, resolved identity, category,
  point amount, processedBy) from CM1 onward, not a balance table with
  an audit log bolted on as a safety net.

**Corrected growth estimate.** The Size note in Data model guessed "a
few hundred transactions a week." Real data says otherwise: 73,500
rows since 2026-02-01 is roughly **4,000 transactions a week** - about
10x the original guess. "Measure it after a few months" is no longer
an adequate plan for the uncapped processor log.

**Confirmed 2026-09-22 with Chris: bounded in-game window + export as
the real archive.** Rather than holding 1.5+ years of rows in
SavedVariables (a real login-lag risk at this volume - see this
session's file-size discussion), the addon keeps only a rolling window
in-game long enough to cover the weekly report plus buffer (something
like 6-8 weeks), while the all-time record lives in the exported
file(s) the Data export tool produces - the same role Bavin's own CSV
already plays today, just kept current by regular exports instead of
manual upkeep. All-time point/tier/prestige/lifetime totals stay as
running counters in-game regardless (those don't need row-level detail
to maintain) - only the row-level transaction detail rolls off after
export. Exact window length (6-8 weeks proposed) can be tuned in CM1.

**Category auto-tagging, confirmed available.** `DH Reputation - Items
(1).csv` (the existing item-points intake source) already has a
`Category` column using the exact same taxonomy as the donation log
(Alchemy, Cloth, Herbalism, Gear, Quest, Banking, etc.) - it's just not
imported into `ItemPoints.lua` yet (today's import only takes name/
points/detail). CM2's item-intake pipeline needs to start pulling that
column too, so CM4's incoming-mail crediting can tag each transaction's
category automatically from the same lookup that already prices the
item - no manual category entry needed anywhere.

**Data type note:** donation amounts in the real data are fractional
(0.5, 2.2, 33.0, ...) - points/credits fields need to be decimal, not
integer, throughout.

## Historical data reconciliation - contribution_data.csv analysis (2026-09-23, Chris + Claude)

With contributors.csv in hand for identity, Chris asked Claude to
calculate the real point totals from `contribution_data.csv` (the raw
73,500-row transaction log) rather than trusting the Discord
Reputation-report posts as source data - the report is confirmed
partial. Findings:

- **Tab-delimited, not comma** - `From, Date, Category, Amount`,
  2025-02-01 through 2026-09-21.
- **194 rows are a non-donation sentinel, not real transactions:**
  `Category="Exile"` with `Amount` exactly `-99999`. **Decision
  (Chris, confirmed): exclude these entirely** from all point/credit
  aggregation - CM2's importer must filter them out, not just ignore
  the negative amount.
- **The `Amount` column is a gold value, not points - confirmed a
  ×10 conversion.** Cross-checking 183 computed totals (contributors
  identity + contribution_data.csv, Exile rows excluded, ×10 applied)
  against the Discord report's posted numbers: 180/183 land within
  ±5%, matching the same ×10 relationship visible in `DH Reputation -
  Items (1).csv`'s own Val -> Reputation Value columns (e.g. Flask of
  the Titans: Val=80 -> 800 points). Chris independently confirmed
  this is the real system: points are usually 10x the gold value.
- **Open caveat, not yet resolved:** Bavin sometimes manually bumps a
  specific item's *point* value without changing its estimated gold
  value, to steer donations toward something the guild needs right
  now. Whether `contribution_data.csv`'s Amount already reflects those
  bonus points, or only the item's baseline gold value, is unconfirmed
  - **Chris is checking with Bavin directly.** CM2's real-totals
  calculation can't be finalized until this comes back; treat the ×10
  conversion as provisionally correct but not yet the final formula.
- **Direction check, run at Chris's request:** under the corrected
  (×10) calculation, 182 of 183 people compute HIGHER than their
  Discord-report number (median +0.79%, average +1.46%, aggregate
  +0.86%) - a small, consistently one-directional bias rather than
  random noise, consistent with rounding-down somewhere in Bavin's own
  report script. Supports Bavin's own hypothesis rather than pointing
  at a data problem on our end.
- **Unexplained, not investigated further:** two outliers - Sayagirl
  (+41.9%) and Xeriik (+33.1%) - move in the wrong direction to be
  explained by the missing-bonus-points theory (that theory would
  make the report number too LOW, not too high). Left open; revisit
  if they turn out to matter once Bavin's answer is in.

## Self-storage / client-side computation - design idea evaluated, not adopted (2026-09-23, Chris)

Chris proposed an alternative architecture: each member's own client
stores their full rep/donation history locally and only shares a
running total plus a rolling 7-week per-category summary with Bavin -
moving the compute/storage load from the "receive" side (Bavin's
client, today's design) to the "send" side (each donor's own client).
Asked for an honest efficiency/security/flexibility evaluation.

**Verdict: not adopted.** The efficiency case is real (less load on
Bavin/officer clients) but it regresses the trust model this whole
design leans on, specifically for the **spendable credits** half of
the system - a member's own client becomes an input to a number that
can be spent, which is a materially different risk than a member
merely seeing a locally-cached read-only balance (today's CM6 design).
It would also make the officer-side audit trail (weekly leaderboard,
category reporting - see "Full audit trail" above) dependent on every
donor's client being online and reporting honestly, rather than
authoritative on the processor side where it lives today. Chris
accepted this evaluation without pushback. A lower-risk variant - a
non-authoritative local personal-history mirror, additive to (not
replacing) the officer-side ledger - was suggested as a middle ground
but not scoped further; revisit only if Chris raises it again.

## Milestone plan (resolved with Chris 2026-09-23)

Testing plan, confirmed with Chris: he tests solo first, using a new
alt character standing in for Bavin (in the officer/Designated-
Officers tier for test purposes); once he's satisfied, Bavin joins
testing directly; only after both are satisfied do they jointly decide
whether to pull in more officers or go straight to CM9 cutover.

- **Step 0 - Historical reconciliation (offline, not addon code).
  DONE 2026-09-24.** Identity resolution (642 resolved main groups, 1
  conflict) and the real point-total calculation over
  contribution_data.csv, cross-checked against the Discord report via
  tier/prestige lifetime-total reconstruction (mean +0.79%/median
  +0.77%, within Chris's ~1.46% bar). Deliverables:
  `claude\DH-Bavin\intake\seed-dataset.csv` (651 mains) and
  `review-queue.csv` (1 conflict + 1129 unmapped names), ready for
  CM2's seed step.
- **CM1 - Data model, permission plumbing & isolation walls. CODE
  COMPLETE 2026-09-25 (including the real UI); first in-game test pass
  done same day - 6 layout/behavior bugs found and fixed, 2 items
  (Master Toggle, Reset Test Data arming) confirmed working as-is; one
  known cosmetic gap (add-box-to-list spacing in CreditsConfig.lua)
  accepted by Chris, not scheduled. Committed and pushed to
  collab-dev.**
  `Modules\DHBavin\Credits.lua` built with all four walls, its own
  `DHBavinCreditsV1` addon-message prefix (kept separate from
  `DHBavinV4`), and the officer-gated multiplier defaulting to 0.60
  credits/point. 2026-09-24 pass built a `/dhb credits ...`
  slash-command surface as a stand-in (status/toggle/multiplier/
  officer/receiver/sender/reset) rather than the config-page UI, to
  avoid a large edit to the shared Bavin Config.lua page before Chris
  reviewed scope. 2026-09-25: Chris reviewed it, flagged that
  deferring the UI risked losing track of the real access
  requirements, and settled a four-tier access model (see "Access
  tiers" above) - built `Modules\DHBavin\CreditsConfig.lua`, a
  standalone tabbed "Bavin Rep & Credit Config" window (Settings tab
  fully wired; Roster/Conflicts/Audit Log placeholders for CM2/CM7),
  opened via one new button on the EXISTING Config.lua Bavin page
  (otherwise left unchanged, per Chris). Slash commands stay as a
  diagnostic fallback. Verified via `run-tests.ps1` (syntax-clean,
  existing 129-check harness unaffected) but not yet exercised
  in-game. The
  new **separate** credits SavedVariables file (Wall 1) holding the
  ledger table, alt-override table, transaction log and credit config
  - explicitly NOT added to `DHBavinDB`, which keeps only its existing
  v1.0 recipient/editors/priorityList state. Designated Officers
  permission gate + broadcast. Master toggle defaulting OFF (Wall 3)
  and BOTH test lists - `creditTestReceivers` and `creditTestSenders`
  (Wall 2) - surfaced in the TEST ONLY section of the officer config
  on the Bavin Points page. The lazy `PLAYER_LOGIN` arming check that
  Wall 4 hangs off, with two no-op hook-installation sites (inbox and
  outgoing) so both gates can be verified before any mail code exists
  behind them. All four walls land here, in the first milestone,
  before any milestone that touches mail. **New this update: a
  "reset to zero" test utility** - wipes the test-scoped credits
  SavedVariables data (ledger, alt table, transaction log) back to
  empty, callable at any point during testing (not just at CM9
  cutover, which is a separate, already-solved wipe - see "Test/live
  data reset" above). Built here alongside the rest of Wall 1's
  scaffolding; not fully exercisable until CM2's seed step exists, but
  gets used constantly through CM2-CM8 as Chris/Bavin iterate.
- **CM2 - Historical seed & ongoing alt-linking.** One-time seed from
  Step 0's reconciled dataset (contributors.csv for identity,
  contribution_data.csv for real point/credit totals - superseding the
  original Reputation-report-only parser plan above), plus the live
  `GRM.GetPlayerMain()`-based resolver for alts created after go-live
  (contract verified this session - see Decisions), with the
  manual-override table as a fallback. Conflicts (Thormhammer-style
  contradictions) and unresolved rows route to the officer review
  queue per "Alt-identity management" above.
- **CM3 - Officer-set ledger sync.** Full replica among Bavin +
  Designated Officers; work out the exact wire format and whether it
  needs a prefix bump.
- **CM4 - Incoming mail processing.** Checkbox UI on the inbox, item
  pull-in hook, point/credit/lifetime crediting, tier/prestige-crossing
  logic.
- **CM5 - Outgoing mail processing.** Checkbox UI on SendMailFrame,
  pre-send credit check + block, deduction on send.
- **CM6 - Balance visibility + member transaction push.** Batched
  targeted push (flush on `MAIL_CLOSED`/per-send) + login-time pull;
  own-balance window opened from the minimap left-click quick-actions
  menu. The push payload also carries that session's new transaction
  rows for the affected member (`itemId`, not item name); the login
  pull returns balance ONLY and does not backfill history. Member-side
  local cap of 50 rows applied here.
- **CM7 - Audit trail UI, three views.** (a) Processor: full log,
  uncapped, plus an export-and-purge escape hatch. (b) Designated
  Officer: full replica plus a "what I sent" filter on
  `processedBy == self`, with 12-month local pruning. (c) Regular
  member: own last 50, in the same window as their balance.
- **CM8 - Test & package.** Extend the headless harness (permission
  gates, tier/prestige math, report-parser edge cases, ledger sync,
  the forced-multi-chunk case) the same way M6 did for v1; in-game
  test plan added to `claude\TEST-PLAN.md`. Add explicit harness cases
  for the Wall 4 gates themselves: a character on neither list must
  reach zero mail-hook code, and a character on `creditTestReceivers`
  but NOT `creditTestSenders` must get the inbox hook and no outgoing
  hook (and vice versa).
- **Step 9.5 - Full reseed.** Immediately before cutover: use the CM1
  reset tool to wipe test data, then re-run Step 0's reconciliation
  against then-current live data - both the identity mapping and the
  full contribution history will have moved on since the original
  reconciliation, so this refreshes CM2's seed from current reality
  rather than carrying a stale snapshot into cutover.
- **CM9 - Cutover.** Only after CM1-CM8 are proven and Bavin signs
  off. Empty both test lists, make Bavin the live credit processor,
  remove the TEST ONLY config section, flip the master toggle
  default. Bavin retires the Excel/Discord process at this point and
  not before. Plan a low-volume first live mail session rather than a
  full ~100-mail batch (see Residual risk in Test strategy).

## Risks flagged up front

- **Reputation-report parsing.** This is hand-maintained Excel text
  posted to Discord, not a machine-designed export - the sample
  already has accented/stylized alt names ("Artémìs", "Ëmy",
  "Ðalìnar"), inconsistent trailing spaces ("Fourthnipple " vs
  "Fourthnipple"), and at least one duplicate-looking alt entry
  ("Kilroth" appears both as the main's own name and again in its own
  alt list). The parser needs to tolerate this without silently
  mis-assigning an alt to the wrong main, group entries by last-seen
  header (not proximity - see Prestige correction), and should fail
  loudly (like BagMail.lua's own precedent) on a line it can't
  confidently parse rather than guessing.
- **GRM edge case - unknown-to-GRM names untested.** Everything
  verified this session was already GRM-known (Loopi + her alts, plus
  a control main). What `GetPlayerMain` does with a name GRM has never
  seen at all is still unconfirmed - worth a quick check during CM2
  rather than assuming.
- **Inbox mail checkbox - new UI territory.** BagMail.lua already
  proves out hooking `SendMailFrame` (outgoing side has precedent).
  Adding a checkbox to the *inbox* reading pane is new ground for this
  codebase - flag as unverified the same way M5's original hooks were.
  Mitigated by Wall 4: the hook only ever installs on a test
  recipient's client, so an unproven inbox hook cannot reach Bavin's
  live mail workflow during the test phase.
- **Test coverage gaps are scale, not correctness** - real senders and
  real item variety ARE covered by the soak (other members will mail
  the test alt knowingly, with junk items). What stays unproven until
  cutover is Bavin's ~100-mail batch volume and multi-officer
  concurrent outgoing use. See Residual risk in Test strategy.
- **Processor-side log grows without bound** - uncapped by explicit
  instruction. Worth measuring SavedVariables size after a few months
  rather than assuming; export-and-purge exists in CM7 as an escape
  hatch. See the Size note in Data model.
- **Residual double-spend window** - accepted per the decision above,
  mitigated by audit trail rather than a hard lock.
- **Reputation-import traffic spike.** A go-live reputation import
  plus everyone logging in to pull their new balance around the same
  time could bunch up login-pull traffic more than the steady state
  this design otherwise targets - worth watching in that first
  session, not necessarily worth designing around in advance.

- **Export tool is a new, non-addon artifact** (2026-09-22) - it has
  its own distribution and update problem entirely separate from the
  addon's own (see Data export); nobody has decided yet how Bavin/
  officers would learn a new build of the export tool exists if its
  parsing logic ever needs to change.
- **Alt-identity review queue could grow unattended** (2026-09-22) -
  if no officer clears the pending-links/reconciliation queue
  regularly, donations from queued (not-yet-approved) alts keep
  crediting the wrong identity in the meantime. Worth a simple
  visibility cue (e.g. a queue count) once CM7's UI is built, not
  necessarily solved now.

## Deferred / out of scope for this pass

- A public leaderboard or guild-wide balance visibility (current
  design keeps individual balances between the member, Bavin, and
  officers).
- A live, per-send "confirm with Bavin" lock for outgoing credit
  charges (see double-spend decision).
- Ongoing/recurring reputation-report re-import (this pass treats it
  as a one-time go-live seed only - the process that produces it is
  being retired by this feature, not kept alongside it).
