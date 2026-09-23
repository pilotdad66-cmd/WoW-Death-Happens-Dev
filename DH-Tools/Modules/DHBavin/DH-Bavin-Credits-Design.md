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
status: PROPOSED - scoped with Chris 2026-08-31, test strategy added
2026-09-03, three more discussion topics added 2026-09-22 - all
pending his + Bavin's sign-off. No code written yet
(README §14, ARCHITECTURE FIRST).

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
  - Untested edge case, to confirm during CM2 implementation: what
    `GetPlayerMain` returns for a name GRM has no record of at all
    (not just "no alts" - genuinely unknown to GRM). Every name tried
    this session was already GRM-known, so this path is unverified.
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

**Multiplier: 0.7 credits per point, Bavin-configurable.** A numeric
field on the officer-gated config page, same idiom as an item-points
override - not hardcoded.

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
  management" and "Full audit trail" sections). Still pending: the
  actual Discord-name -> main -> alts mapping file itself, which Chris
  will add to `intake\` before testing starts - CM2's exact resolution
  logic stays provisional until it's in hand.
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

All prior decisions (2026-08-31, 2026-09-03, 2026-09-22) are settled;
CM1/CM2 are ready to start once the Discord-name -> main -> alts
mapping file is in hand and Bavin's formal sign-off on the plan as a
whole is reconfirmed (last confirmed pending 2026-09-14).

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

## Milestone plan (draft)

- **CM1 - Data model, permission plumbing & isolation walls.** The
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
  before any milestone that touches mail.
- **CM2 - Historical seed & ongoing alt-linking.** Parser for the
  Reputation report format above (one-time: points/tier/prestige/
  lifetime + the go-live alt-to-main snapshot), plus the live
  `GRM.GetPlayerMain()`-based resolver for alts created after go-live
  (contract verified this session - see Decisions), with the
  manual-override table as a fallback.
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
- **CM9 - Cutover.** Only after CM1-CM8 are proven and Bavin signs
  off. Empty both test lists, make Bavin the live credit processor,
  remove the TEST ONLY config section, flip the master toggle
  default. Wipe the test ledger. Bavin retires the
  Excel/Discord process at this point and not before. Plan a
  low-volume first live mail session rather than a full ~100-mail
  batch (see Residual risk in Test strategy).

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
