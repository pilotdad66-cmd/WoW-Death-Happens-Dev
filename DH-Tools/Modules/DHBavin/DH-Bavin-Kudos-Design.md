# DH-Bavin Kudos - design PROPOSAL (2026-10-07, Loopi + Claude)

STATUS: proposal, revised 2026-10-07 17:42 with Loopi's answers (section 0).
Nothing is built. Remaining open questions are at the end.

## 0. Loopi's answers (2026-10-07 17:41) - these override anything below
- "Community" in the raw data IS Kudos, worth 30 Rep each (not 10).
- Kudos earn Rep only - never Credits.
- Rep landing when Bavin is online is fine.
- Daily limit resets at SERVER midnight (not a rolling 24 h).
- Build order: after the archived-donor carryover, before CM6 - agreed.
- Bavin REVIEWS the Kudos log and hits Accept. Before acceptance a Kudos can be
  edited or removed; once accepted it is locked. (Replaces the
  lifetimeDeductions idea - Rep never goes down, see section 7.)
- No separate Kudos toggle: Kudos is simply part of Bavin Points. Once live,
  the Bavin Points module toggle goes away, or needs a multi-step process to
  disable (a later DH-Tools Core change, not part of the Kudos build).
Second round (2026-10-07 17:47):
- Monthly cap raised to 1800 Rep per receiver (60 Kudos, roughly 2 a day).
- Pair cooldown also resets at server midnight (one Kudos per pair per day).
- NO hiding during testing - Kudos is visible to every Bavin Points user from
  the first build that carries it (section 8).
- Pending Kudos can be edited/removed by Designated Officers and above.
- A short reason is required.
Third round (2026-10-07 17:49):
- Every Kudos posts a guild chat line (yes). The addon feed (section 6) stays as
  well - it is what lets anyone see recent Kudos history later.
- Bavin may Accept a Kudos that breaks a rule ("he is the one that creates them
  in the first place"), but the addon warns him what rule it breaks and asks
  for confirmation; the result row is marked as an override.
- Pending Kudos review = a filter on the existing Audit Log tab, not a new tab.

## 1. What and why
Kudos = a public shout-out from one guild member to another for help given.
The receiver earns a little Reputation (Rep). Today this happens in Discord and
Bavin's script turns it into Rep offline. It was missing from the Bavin
Points / Credits design. Kudos becomes part of the Credits system (not a new
DH-Tools module) and lands BEFORE the live rollout of earning/credits.

Loopi's decisions (2026-10-07):
- Anyone in the guild can give. Only guild members can receive - in game the
  target is the CHARACTER (main or alt); it resolves to that player's account.
- Value starts at 10 Rep per Kudos, a configurable ratio in the officer
  settings next to the Rep/Gold ratio.
- Authoritative data: officers only (strong lean, assumed below).
- Recent Kudos history viewable by anyone.
- No self-Kudos, including your own alts.
- Per-giver daily limit (2/day), per-pair cooldown (1 day), monthly Kudos-Rep
  cap per receiver (1000) - all configurable in officer settings.
- No pattern flagging - public visibility is the deterrent.
- Officer-editable log: add / edit / remove Kudos points for any give/receive.

## 2. Finding in the raw data: "Community" looks like today's Kudos
credits-contribution-data-2026-10-06.csv has a "Community" category: 3,633
rows, 19,320 gold-equivalent (= 193,200 Rep), 1,614 distinct receivers, about
537 units a month. Amounts are almost all multiples of 3.0 gold (3.0 x2,602,
6.0 x484, 9.0 x212 ...) and arrive in batches on the days Bavin runs his
script. That pattern fits "one Kudos = 3 gold = 30 Rep".
If confirmed by Bavin:
- Historical Kudos are ALREADY inside everyone's seeded lifetime Rep - nothing
  to import, but Step 0 should label them Kudos so history and new in-game
  Kudos share one category.
- Today's value is 30 Rep, not 10.
- Cap calibration: at 30 Rep each, 17 person-months in the history exceed 1000
  Rep (top receiver-month: 110 units = 3,300 Rep, 2026-08). At 10 Rep each, 1000 Rep =
  100 Kudos/month, which only that one month would have exceeded.
- "From" in that file is the RECEIVER; givers were never recorded, so history
  cannot seed any giver-side limit.

## 3. The flow
1. GIVE. Right-click a player (chat name, party/raid frame, target frame) >
   "Give Kudos", or `/dhk <name> <reason>`, or the Kudos window. A small dialog:
   receiver (pre-filled), reason (required, 3-80 chars), Send.
2. GIVER PRE-CHECK (convenience only, not authority). The giver's client refuses
   and says why if: receiver not in the guild roster; receiver is the giver or
   one of the giver's own characters (shipped AltRoster + GRM + local name);
   giver already used today's limit; same pair inside the cooldown (both from
   the giver's own local history). A refused Kudos sends nothing.
3. SEND, three things at once:
   - a normal guild chat line, readable without the addon:
     `[Kudos] Loopi -> Thorm: thanks for the summon`
   - addon message on GUILD: `KUDOS|id|receiver|ts|reason`. The giver is the
     server-stamped sender, never a field in the payload.
   - the Kudos goes into the giver's local OUTBOX until an officer confirms it
     (`KUDOSACK|id`, whisper). Re-sent at login and when an officer comes online,
     so a Kudos given while no officer is on is not lost.
4. CAPTURE (every online officer + the Donation Recipient). Verify the sender
   is a guild member, store a `kudos` row in the replicated audit log (dedupe by
   id - rows already replicate to every officer, CM7 step 2b), send the ACK.
   Officers ignore a giver's Kudos beyond (daily limit + 3) per day, so a
   modified client cannot flood the log.
5. ACCEPT = APPLY (Bavin, on the Donation Recipient's armed client only - see
   sections 5 and 7). Until Bavin accepts, a Kudos is PENDING: officers can edit
   its points or remove it. Bavin's review list shows each pending Kudos with the
   rule checks already run (self/alt against the live ledger, giver daily limit,
   pair cooldown, receiver monthly cap) and what accepting would grant (full,
   partial because of the cap, or nothing + reason). On Accept, in time order:
   Rep added, tier/prestige recomputed, account synced, and an immutable
   `kudosresult` row written (id `kres-<kudosId>`: accepted / rejected + reason,
   Rep granted, the rule values used, accepted by). From then on the Kudos is
   LOCKED. Credits are never touched. Rows are never modified after writing.
6. NOTIFY. The receiver's own client heard the GUILD broadcast and shows
   "You received Kudos from Loopi: <reason>" at once. The Rep shows on their
   balance once CM6 (member push) exists; until then, in the feed.

## 4. Identity and limits
- Limits count by ACCOUNT, not character: the giver is resolved to their
  account at apply time (unknown giver = GRM main, else the character itself).
  Otherwise ten alts would mean twenty Kudos a day.
- Receiver = any guild character, resolved to its account. A guild member with
  no account yet gets one auto-created, exactly like a first donation
  (reuse CreditsDon_ResolveAccount). Discord-only accounts cannot be targeted
  in game; an officer can add Kudos to them via the log (section 7).
- Self-Kudos = giver account == receiver account. Rejected.
- Known gap, accepted: alts that are linked nowhere (not in our data, not in
  GRM) count as separate givers. The monthly cap and the public feed bound it.

Officer settings (new rows on the Officer Settings page, beside Rep/Gold):
| Setting | Default | Meaning |
|---|---|---|
| Kudos value | 30 Rep = 1 Kudos | ratio row, same widget as Rep/Gold |
| Giver daily limit | 2 | per giver account, per server day (resets at server midnight) |
| Pair cooldown | 1 per server day | giver account -> same receiver account, resets at server midnight |
| Monthly cap | 1800 Rep | Kudos Rep per receiver account per calendar month (server time) = 60 Kudos at 30 Rep |
"Server day": WoW gives epoch time (GetServerTime) and the realm clock
(GetGameTime) separately; the day boundary is derived from the realm clock so
every client and officer agrees where midnight is. Must be verified in game.
Same gate as the rates (author / guild leader / Donation Recipient), its own
message `KUDOSSET|...|updatedAt` like RATESET. A change applies to Kudos
applied after it; each `kudosresult` row stores the values it used.

## 5. Why one client applies the Rep (the important architecture point)
CM3 ledger sync is per-record last-writer-wins, with max() on the lifetime
fields. If two officers each added a Kudos to the same account at the same
moment, both would write lifetime 100 -> 110 and one Kudos would vanish. That is
safe today only because donations have a single writer (the recipient's armed
client). Kudos keeps that rule: every officer CAPTURES, only the Donation
Recipient's client APPLIES - the same pattern as held donations and
Credits_ReleasePending.
Cost: Rep lands when the recipient (Bavin) is next online. The Kudos itself is
public and logged immediately.
If CM5 moves balances to "events, balance derived" (already the plan for
spends), Kudos rows convert for free and any officer could apply.

## 6. Public history (answer: yes, without touching sync or the log)
- A separate, display-only FEED, kept by every client: the last 50 Kudos heard
  on GUILD (giver, receiver, reason, time). It never feeds the ledger or the
  officer log, so it cannot break either.
- A client that was offline asks ONE online officer for the recent list
  (`KFEEDREQ` / chunked `KFEEDDATA`, public fields only) - only when the Kudos
  window is opened, never at login, so ~1000 logins do not hit officers.
- An officer removal broadcasts `KFEEDDEL|id` so feeds drop that entry.
- The Kudos window: minimap quick-actions entry "Kudos" and `/dhk` with no
  arguments - recent feed, a Give button, "you have N Kudos left today".
- DECIDED 2026-10-07 17:54 (Loopi): the minimap LEFT-CLICK menu also gets
  "Give Kudos", opening the give dialog directly. The receiver field is a
  type-ahead drop-down of guild characters (from the guild roster cache), so
  only an in-guild, correctly spelled name can be picked. Same picker style as
  the existing Roster "Merge into..." type-to-filter suggestions. The
  right-click "Give Kudos" pre-fills that field.

## 7. Officer-editable log
- The existing Audit Log tab gets a Kudos kind filter. Right-click a Kudos row:
  Edit points / Remove (note required). Toolbar: "Add Kudos..." (giver,
  receiver, points, note) - bypasses the limits, e.g. for Discord stragglers
  during the switch-over.
- All of it is append-only: a `kudosadjust` row {refId, newRep, officer, note}.
  The original row is never changed (keeps CM7 row replication simple). The
  effective Rep of a Kudos = its latest adjustment.
- REVISED 2026-10-07 (Loopi): edits and removals are allowed ONLY while the
  Kudos is pending (not yet accepted by Bavin). A Kudos with a `kudosresult`
  row is locked: the edit/remove menu items are greyed out, and every client
  ignores a `kudosadjust` whose refId already has a result (closes the race
  where an edit and Bavin's Accept cross in the post). Because Rep is only ever
  ADDED, once, at acceptance, lifetime Rep never goes down and the CM3 max()
  rule is untouched - the lifetimeDeductions idea is dropped.
- Bavin's review: a "Pending Kudos" filter on the existing Audit Log tab
  (decided) with Accept per row, Reject per row (note required), and
  "Accept all clean" (accepts only rows whose checks all pass; rows that would
  be rejected or capped stay for him to decide). Accepting a rule-breaking row
  is allowed (decided): a confirmation popup names the broken rule(s) first,
  and the `kudosresult` row carries override = true plus the rules overridden.
  An override grants the full Kudos value (it also bypasses the monthly cap).
- At ~18 Kudos a day guild-wide (history: ~537 a month), this is a short daily
  review, not a backlog.
- Who may edit pending Kudos: Designated Officers and above (decided). Accepting /
  rejecting: the Donation Recipient only (it is the single applier).

## 8. Testing and isolation
- REVISED 2026-10-07 (Loopi): NO separate Kudos toggle and NO hiding during
  testing - giving, the guild line and the feed work for every Bavin Points
  user from the first build that carries Kudos. Only the APPLY side stays
  behind the existing Credits walls (Bavin's Accept runs on the armed Donation
  Recipient client, into the test ledger). Consequences to keep in mind:
  - Kudos given before go-live land in the test ledger and are wiped by
    "Start from scratch" at the reseed, like all other test data. Whether to
    carry pending/accepted test-phase Kudos into the live seed is a decision
    for the reseed design (RESEED-RUNBOOK section 5), not built in.
  - While Discord Kudos still count, members may think the in-game ones do
    too. The release note / guild announcement should say which one counts
    until cutover.
- Later, separate DH-Tools Core change (Loopi): once live, the Bavin Points
  module toggle is removed, or disabling it needs a multi-step confirmation.
  Not part of the Kudos build; it needs its own design (what happens to a
  member who already has Bavin off at that point).
- The live Discord Kudos process stays untouched until cutover (CM9). At
  cutover Bavin stops counting Discord Kudos.
- Harness: limits (daily, pair, server-midnight boundary), self/alt rejection,
  account-level counting, cap with partial grant, month rollover, dedupe by id,
  outbox re-send + ACK, pending edit/remove, lock after accept (late adjust
  ignored), Accept-all-clean, Rep-only (credits unchanged), feed independent of
  the log.

## 9. Rep category "Kudos"
- Every Kudos row carries category "Kudos", so Bavin's per-category weekly
  top-3 and the export tool (Transaction Items / Donation History, 16-column
  layout) show it like any other category.
- CONFIRMED (Loopi 2026-10-07): "Community" is Kudos. Step 0 relabels it
  Kudos (in `_step0-reconcile.ps1`'s output and the contribution history the
  export tool ships), so history and in-game Kudos share one category. The
  historical Rep is already in the seed - nothing extra to import.

## 10. Right-click menu
"Give Kudos" goes on the player unit menus (chat name, party, raid, target) via
Blizzard's Menu.ModifyMenu (MENU_UNIT_PLAYER, _PARTY, _RAID_PLAYER, _TARGET,
_FRIEND). Other Classic clients (TBC Anniversary 2.5.x) expose both that API
and the old UnitPopupMenus table; confirm on Classic Era 1.15.x with a quick
in-game `/dump Menu and Menu.ModifyMenu` before building, fall back to a
post-open hook if absent. Never edit the old menu tables directly (taint).
The button only opens our dialog - nothing protected. In-world 3D character
right-click cannot be hooked; targeting first gives the target-frame menu.

## 11. Files and messages (proposal)
- New `CreditsKudos.lua` (logic, frame-free, harness-drivable) and
  `KudosUI.lua` (dialog, feed window, menu entries, /dhk).
- Prefix stays `DHBavinCreditsV2` (additive messages; older clients ignore
  them): KUDOS, KUDOSACK, KUDOSSET, KFEEDREQ, KFEEDDATA, KFEEDDEL. Log rows
  `kudos`, `kudosresult`, `kudosadjust` ride the existing LSYNCDATA log items.
- Reason text is free prose on the wire: escape it (k-0024).

## 12. Proposed build order
K1 settings + data model + logic + harness -> K2 give flow (dialog, /dhk,
guild line, outbox/ACK, officer capture) -> K3 apply + limits + category +
receiver notice -> K4 feed window + right-click menu -> K5 pending review
(edit/remove, Accept, Accept all clean, lock) + Step 0 Community->Kudos relabel
+ export tool category.
Placement (AGREED 2026-10-07): after the archived-donor carryover, before CM6,
so CM6's member push carries Kudos Rep from day one.

## 13. Answered 2026-10-07 (see section 0)
Community = Kudos at 30 Rep; Rep only; Rep landing when Bavin is on is fine;
server-midnight reset; build order; Bavin accept/lock instead of
lifetimeDeductions; no separate Kudos toggle.

## 14. Still open (design otherwise complete as of 2026-10-07 17:49)
1. Reason length: going with 3-80 characters unless Loopi says otherwise.
2. Carry test-phase Kudos into the live seed at the reseed, or let them wipe?
   (Decide inside the reseed-merge design, RESEED-RUNBOOK section 5.)
3. Before building: in-game `/dump Menu and Menu.ModifyMenu` check (section 10)
   and the server-midnight clock check (section 4).
NEXT TOPIC (Loopi): once the Kudos design is finished, ask Loopi about
"Officer Reviews" (his item 8 of 2026-10-07 17:41).

## 15. Officer Reviews window - PROPOSAL (Loopi raised 2026-10-07 17:54)
Three things now need regular officer review: unknown roster names, pending
Kudos, and items people ask about that have no Bavin Points data. Proposal:
one "Officer Reviews" window with three tabs - Roster, Kudos, Items.
- Its own window, not another tab in the Bavin Rep & Credit Config window:
  Config is settings, Reviews is daily work. Opened from the minimap left-click
  menu ("Officer Reviews (N)", N = total pending, shown to officers only), a
  button in the Config window, and a slash command. Each tab shows its count.
- Roster tab = today's Review Queue tab, MOVED here (one place, not two).
- Kudos tab = pending Kudos with Accept / Reject / Accept all clean / edit.
  This would REPLACE the "Audit Log filter" decided at 17:49; the Audit Log
  keeps a Kudos kind filter for history only. Needs Loopi's OK.
- Items tab (new). Sources: (a) a guild-chat "? [item]" lookup whose answer is
  "no data" (not the BoP/quest "cannot be traded" case); (b) a donated item with
  no Bavin Points entry (CM4 already detects these as "unpriced"). Capture:
  everyone sees the guild-chat query, so each officer's client classifies it
  itself - no new message from whichever member answered. Replicated among
  officers like the Review Queue (per-item add/remove stamps). Row: item,
  times asked / donated, first and last seen, last asker. Actions: Add to Bavin
  Points (opens the Points Editor pre-filled) and Dismiss (stays dismissed).
  Known gap: a query asked while no officer is online is not logged; items
  asked about often will be caught next time.
- Permissions: Roster = Designated Officers and above (as today); Kudos = edit
  by Designated Officers and above, Accept/Reject by the Donation Recipient
  only; Items = add by whoever can edit Bavin Points today, dismiss by officers.

### 15b. Revised 2026-10-07 18:02 with Loopi's answers (overrides 15 above)
- KEEP Roster <-> Review Queue one click apart (Loopi). So NOT a separate
  window: the existing Bavin Rep & Credit Config window gains the new tabs -
  Roster | Review Queue | Kudos | Items | Audit Log | Settings. Everything stays
  one click apart. The minimap "Officer Reviews (N)" entry opens that window on
  the first tab that has something waiting; tabs show their counts.
- Kudos are logged, sorted, filtered and exported in the Audit Log exactly like
  item and gold donations (kind "Kudos", category "Kudos"). The Kudos tab is
  only the pending list Bavin accepts from.
- Items tab: item + source (lookup / unpriced donation) + first seen. No
  asker, no counts. Long-term aim: a Lua with every item in the game.
- Dismiss = CREATE the entry anyway at 0 gold / 0 Rep with best guesses (name,
  itemID from the link, category guessed from the item's class/subclass, a
  default "? " answer text), so the item exists and shows 0 rather than
  "no data". Any entry, even 0, removes it from the Items tab.
- In-game item edits (Points Editor and Items tab, stored as
  DHBavinDB.itemPointsOverrides on every client) go into the export tool as
  their own CSV and their own workbook sheet ("Item Edits"), and the item
  rebuild (_build-itempoints.ps1) applies them on top of the raw Items CSV so a
  reseed keeps them. Today the export tool does not read them at all - gap.
- Points Editor is OUT OF DATE (checked 2026-10-07): it edits name, itemID,
  points and the "? " answer text (`detail`) only. Missing: gold value
  (`goldValue`, also the DH-Store price source) and `category`, both added to
  ItemPoints.lua after the editor was written. The override record and its sync
  carry only points/itemId/detail, so adding the two fields touches the editor
  UI, ns.SetItemPoints, the override record, the ITEM sync message and the
  export. The raw sheet also has stack size, level, and a source phrase
  ("crafted by an @Alchemist") that only live inside the detail text.
Open:
1. Reimport conflict: when the new raw Items CSV and an in-game edit disagree,
   which wins? (proposal: the in-game edit, until Bavin copies it into his sheet
   - the export's Item Edits sheet is his list to copy from)
2. The answer text repeats points and gold ("X: 800 pts to Bavin; 80g crafted
   by..."). Edit points and the text goes stale. Build the text from points +
   gold + an editable source phrase instead of free text?
3. Points Editor update (goldValue + category, + whatever 2 decides): its own
   small milestone, ideally before the Items tab, since Add/Dismiss open it.

### 15c. Revised 2026-10-07 18:11 with Loopi's answers
- "Items tab" = the review queue for items. Plan confirmed.
- At go-live the Bavin Rep & Credit Config window moves to its own higher-level
  button (Loopi). Testing-only parts go away then: master toggle, test
  receiver/sender lists. Parts that stay: Roster, Review Queue, Kudos, Items,
  Audit Log (Bavin's permanent record: weekly categories, export, Kudos
  history) and a smaller Settings tab (Designated Officers, rates, Kudos
  limits). "Start from scratch" stays author-only for post-live reseeds.
- Points Editor update comes FIRST (before the Items tab).
- Item text and points (Loopi): items default to 10 points per gold, but points
  may be edited away from the ratio (Bavin raises points to encourage farming;
  gold stays). Editor proposal: entering gold fills points at the ratio until
  points are typed by hand; the "? " answer text is BUILT by the addon from
  name + points + gold + an editable source phrase ("crafted by an @Alchemist");
  Bavin can still hand-edit the text, which then stops auto-updating until
  "Reset to automatic".
- Reseed conflicts (Loopi asked for a conflicts window): conflicts are only
  knowable when the reseed scripts run on the PC, so the review happens there,
  not in game. Three-way check per item / roster name: BASE = what the
  current build shipped, RAW = the new raw data, GAME = the in-game edit. Only
  "both changed and disagree" is a conflict; a one-sided change applies
  silently. The scripts write intake\review\reseed-conflicts.csv (+ a sheet in
  a workbook Bavin can open) with a Choice column pre-filled (proposal: GAME),
  and the build will not finish while a row has no choice. Covers items and
  roster now; held donations / credits later (post-live rebase, RESEED-RUNBOOK
  section 4).
Open: should the item default ratio be the existing officer Rep/Gold setting
(the one gold donations already use), or a separate items-only number?

### 15d. Points Editor answer text (Loopi 2026-10-07 18:29)
- Gold filled in -> points auto-fill at the CURRENT officer Rep/Gold setting
  (same one gold donations use); points may then be hand-edited.
- Category = a drop-down. It drives the default source phrase.
- Bavin's sheet already has the category -> phrase table (checked 2026-10-07,
  items-2026-10-06.csv side columns): Alchemy "crafted by an @Alchemist",
  Blacksmithing "crafted by a @Blacksmith", Cooking "from a @Cook", Enchanting
  "crafted by an @Enchanter", Engineering "crafted by an @Engineer", First Aid
  "from @First Aid", Fishing "from a @Fisher", Herbalism "from an @Herbalist",
  Leatherworking "crafted by a @Leatherworker", Mining "from a @Miner",
  Skinning "from a @Skinner", Tailoring "from a @Tailor". Categories without a
  phrase (Gear, Misc., Vendor, Quest, Meat, Cloth) use "(est. AH value)".
- Text pattern seen in the data: "<name>: <pts> pts to Bavin; <gold>[ ea or
  <stack gold> for x<stack>] <phrase>". The "ea or ... for xN" part needs the
  sheet's Stack value, which ItemPoints.lua does not carry yet.
  DECIDED 2026-10-07 18:41 (Loopi): add `stackSize` to the item schema
  (ItemPoints.lua, override record, ITEM sync, export) and carry it in the NEXT
  item import. Sources: the raw sheet's Stack column (filled for 1,618 of 7,784
  rows: 20 x218, 5 x125, 10 x75; 0 and 1 mean "no stack text" -> stored blank);
  in game, GetItemInfo's max-stack return fills it for new/Items-tab entries when
  the item is cached. Blank if neither knows - Bavin fills it in. Blank, 0 or 1
  = no "ea or ... for xN" part in the built text.
- Gold display: "1.5g", "75s", "n/a" for 0 gold - match the sheet's style.
