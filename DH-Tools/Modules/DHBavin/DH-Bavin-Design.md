# DH-Bavin v1.0 - Design & Milestone Plan
created: 2026-07-28

Every guild member mails spare items to the same collector character (today,
Bavin). This module lets that collector (or anyone the guild leader
delegates) publish a priority want-list, highlights matching items in
every guildmate's own bags, and adds a one-click mailbox helper that
attaches a matching item and addresses the mail to whoever the guild
leader has currently designated as the collector. This doc is the working
plan; STATUS.md tracks which milestone is actually in progress. Once code
and this doc diverge, the code is ground truth (same convention as
DH-Air-v2-Design.md and DH-Quests-Design.md).

## Naming note
The module is named DH-Bavin for recognition (Bavin is who this solves a
problem for today), but the *recipient* is a configurable role, not a
hardcoded character - see "Recipient designation" below. If the collector
role ever passes to someone else, the module name stays DH-Bavin; only
its config changes.

## Decisions made 2026-07-28

**Packaging: DH-Tools module, integrated (not standalone-optional).**
Ships as a DH-Tools module from the start - config page + minimap entry
via DH-Tools' framework, same visible pattern as Mob Marker and Quests.
Unlike DH-Quests, there is no stated intent to spin this off as its own
addon later, so it does not need DH-Quests' "standalone-optionality"
scaffolding. It still gets its own subfolder and namespace
(src\DH-Tools\Modules\DHBavin\) purely for code organization, since it has
enough moving parts (sync protocol, bag hook, mailbox hook, config page)
to warrant separate files the way DHQuests' does.

**Open decision for Loopi: SavedVariables placement.** Two options:
(a) DHToolsDB.bavin sub-table, per DH-Tools' normal module contract
(Mob Marker's pattern), or (b) its own top-level DHBavinDB table, per
DH-Quests' pattern (chosen there for standalone-optionality, which
doesn't apply here). Recommendation: (a), since there's no spinoff
intent - but flagging as open rather than assuming, per README's
system-maintenance rule. Default to (a) unless corrected before M1.

**Command:** `/dhb`, matching `/mm` and `/dhq` convention.

## Recipient designation (guild leader only)

Only one character at a time is "the collector" - the mailbox helper
addresses mail to this character. The guild leader sets it from the
Bavin config page (a dropdown built from the local guild roster cache,
same roster cache pattern DH-Air/DH-Quests already build from
GetGuildRosterInfo, online or offline members both selectable).

Broadcast on change: `RECIPIENT|charName`. A receiving client only
accepts this if the sender is verified, against the RECEIVER's OWN
guild roster cache, to hold rankIndex 0 (Guild Master) at the moment
of receipt - never self-asserted. This is the same idiom DH-Air's
Sync.lua already uses for raid-leader/assist verification (see its
HasPermission checks) applied to guild rank instead of raid rank.

The current recipient is part of the SYNCREQ/SYNCDATA handshake payload
(like DH-Quests' peer state), so a player who logs in after the setting
was last changed - even if the guild leader is offline right now - still
learns the current recipient from whoever answers the handshake.

If no recipient has ever been set, the module is inert: no highlighting,
no mailbox helper, and the config page tells the guild leader it needs
configuring.

## Editor delegation (guild leader only)

The current recipient can always edit their own priority list. The
guild leader can additionally name other guild members as editors -
this is additive, not a replacement of the recipient's own edit rights.

Broadcast on change: `EDITORS|name1,name2,...` (full replace list, same
"send the whole small set" simplicity as other short lists in this
codebase). Same guild-leader-verification rule as RECIPIENT above.
Editor set is also part of the SYNCREQ/SYNCDATA handshake.

The Bavin config page's editor picker is a multi-select built from the
same guild roster cache as the recipient dropdown (again, online or
offline members both selectable, since roster data persists for offline
members).

## Priority list data model

**REVISED 2026-08-04** (original text below the line, kept for history).
A set of entries, keyed by item **NAME**, not itemID:
`{ name, itemId (metadata), itemLink (cached for display only), addedBy,
addedAt }`. This changed after Bavin Points shipped the same day
(ItemPoints.lua, ~7000 entries keyed by name - see
knowledge\k-0005-item-name-vs-itemid-lookups.md): keying the priority
list by itemID would reintroduce the exact bug k-0005 already fixed
elsewhere - one itemID can cover many differently-valued "of the X"
random-suffix variants, which an itemID key can't distinguish - and
Loopi asked for consistency with the tooltip/points system anyway. The
primary add path is now a type-to-filter search (PriorityEditor.lua,
`/dhb priority`) over the same ns.ITEM_POINTS baseline Bavin Points
already searches - structurally a near-direct port of
PointsEditor.lua's own search UI, just with an Add/Remove toggle per row
instead of an editable points field. Shift-click-linking an item
(`/dhb additem`) remains as a fallback for the rare item not in that
~7000-entry baseline, resolving the name via `GetItemInfo(link)`.

Broadcasts on change: `ITEM|name|itemId|itemLink` and `ITEMGONE|name`,
gated the same way as RECIPIENT/EDITORS - sender must be, per the
RECEIVER's own synced copy of recipient+editors, currently authorized to
edit. Like DH-Air's own permission model, this is guild-social-trust
security (a modified client could still forge a message) not
cryptographic proof - stated plainly here rather than assumed solved,
same spirit as DH-Air's own documented limitation.

---
**Original 2026-07-28 text (superseded by the above):** A set of
entries, keyed by itemID (the only reliable match key):
`{ itemID, itemLink (cached for display only), addedBy, addedAt }`.
Editors add entries either by shift-click-linking an item into an edit
box (standard addon idiom) or, while their own bags are open, an
"add to Bavin's list" button on a matching bag slot - both paths resolve
to itemID immediately, itemLink is stored only so the editor UI can show
icon/name/quality without a live tooltip query. Broadcasts on change:
`ITEM|itemID:itemLink` and `ITEMGONE|itemID`.

## Guild sync protocol (Milestone 2)

Direct port of DH-Air's Sync.lua / DH-Quests' Sync.lua pattern rather
than a fresh design: prefix registration (`DHBavinV1`), delta broadcasts
(RECIPIENT/EDITORS/ITEM/ITEMGONE) to GUILD, a SYNCREQ/SYNCDATA handshake
on login for late joiners carrying full state (recipient, editors,
entire priority list), and manual chunking at the same ~200-char budget
DH-Air/DH-Quests use - revisit only if in-game testing shows throttling
problems, per existing precedent.

**Priority list SYNCDATA is now timestamp-gated (2026-08-05, k-0012,
prefix bumped to `DHBavinV2`).** Real guild testing surfaced a serious
gap: the SYNCREQ/SYNCDATA handshake trusted whoever answered first,
unconditionally - recipient/editors AND the entire priority list all got
wholesale-replaced by the first reply, even one from a stale or
completely empty peer. Fixed for the priority list specifically (not
recipient/editors, which stay as before - see file header's GATING
note): SYNCDATA's payload gained a 4th field, `priorityListUpdatedAt`
(wall-clock `time()`, positioned before the items list so old V1
clients - which parsed only 3 fields - would misparse it, hence the
prefix bump), and a client only replaces its own list if the incoming
value is STRICTLY newer than its own. Each side bumps its own stamp on
every local edit (AddItem/RemoveItem) and every accepted live
ITEM/ITEMGONE delta from someone else, so it always reflects how fresh
that client's list genuinely is.

## In-bag highlighting (Milestone 5)

**Built 2026-08-04** in `Modules\DHBavin\BagMail.lua`. Matching is by
item NAME, not itemID (see "Priority list data model" above) - a bag
slot's link resolves to a name via `GetItemInfo(link)`, same approach
Tooltip.lua already uses for Bavin Points. Every client with a recipient
configured (guild-wide informational feature, not recipient/editor-
gated - see BagMail.lua's header for why) hooks Blizzard's own
`ContainerFrame_Update` (`hooksecurefunc`, so a problem here can't break
Blizzard's own bag rendering) and draws a gold border overlay on any
slot whose resolved name is on the priority list. This is a Blizzard-
frame hook, not a standalone window (bag frames can't be replaced), so
the exact hook point/behavior against this client's Classic Era bag
button templates (Interface 11509) is **NOT yet verified** - flagged as
a real risk, same category as DH-Quests' GetQuestLogTitle field-order
surprise in M1. If nothing highlights at all in testing, `ContainerFrame_Update`
not existing/firing as expected on this client is the first suspect.

## Mailbox helper (Milestone 5)

**Built 2026-08-04** in `Modules\DHBavin\BagMail.lua`. Only active while
Blizzard's SendMailFrame is open (MAIL_SHOW/MAIL_CLOSED events) and a
recipient is configured:
- A "Fill Recipient" button (anchored next to SendMailNameEditBox) sets
  the To field to the configured collector's name - a button, not silent
  auto-fill, so it never overwrites something the player already typed.
- Any bag slot matching the priority list gets a small mail-icon overlay
  button (separate from the plain highlight border above, which stays
  click-through/decorative-only so normal bag interaction is never at
  risk) that picks the item up (`PickupContainerItem`) and clicks the
  first open `SendMailAttachmentN` button (found via `GetSendMailItem(i)`
  returning nil, `N` up to `ATTACHMENTS_MAX_SEND`, defaulting to 12 if
  that global isn't defined on this client). Bulk-mailing addons (e.g.
  Postal) already automate this exact action, so it's precedented, but
  the precise call sequence and exact frame names against this client's
  SendMailAttachment buttons are **NOT yet verified** in-game - flagged
  as a risk, same spirit as the bag-hook risk above. Fails with a clear
  chat message (not a silent no-op or a Lua error) if `SendMailAttachmentN`
  doesn't exist as expected.

## Milestones

**M1 - Data model & permission plumbing.** Guild-roster-verified
guild-leader check (rankIndex 0, read from the same roster-cache pattern
DH-Air/DH-Quests already build). RECIPIENT/EDITORS local storage and
broadcast (no priority list yet). Bavin config page stub: recipient
dropdown + editor multi-select, guild-leader-only, read-only view for
everyone else.

**M2 - Guild sync protocol.** Port Sync.lua pattern (prefix `DHBavinV1`).
ITEM/ITEMGONE deltas, SYNCREQ/SYNCDATA handshake carrying recipient,
editors, and the full priority list.

**M3 - Local store & event wiring.** Priority-list cache (already lived
in Sync.lua since M2, nothing further needed there). Recipient/editor
authorization re-verification built 2026-08-04: CanEditList now calls a
new IsGuildMember check (fails closed, same philosophy as IsGuildLeader)
so a departed editor/recipient loses edit rights the instant
GUILD_ROSTER_UPDATE reflects their departure, never just whenever
someone happens to re-set the list. A companion
PruneDepartedRecipientEditors also drops their name from
ns.db.editors/clears ns.db.recipient for display accuracy (guarded
against firing on an empty/not-yet-loaded roster cache) - NOT yet
in-game verified, flagged as a real risk in STATUS.md (a partially-
loaded roster could still cause a false removal; only "fully empty"
is guarded against). Guild-leader-change re-verification was already
correct before this session (IsGuildLeader/CanManageRecipient were
always live lookups, never cached).

**M4 - Settings UI.** Guild-leader controls (recipient dropdown, editor
multi-select) live on the Bavin config page (`/dhb config`), same as
always. The priority-list editor itself shipped 2026-08-04 as its own
standalone window instead (PriorityEditor.lua, `/dhb priority`) -
matches the precedent Bavin Points/PointsEditor.lua set the same day
rather than the config-page-tab this doc originally called for. Same
CanEditList gating (recipient or any current editor) as originally
planned; item-link input is now a fallback (`/dhb additem`) behind a
type-to-filter name search as the primary path - see "Priority list
data model" above.

**M5 - Bag highlighting & mailbox helper.** Built 2026-08-04
(`Modules\DHBavin\BagMail.lua`) - see both sections above for what
shipped. Isolated into its own milestone given the unverified-API risk
of both pieces - mirrors how DH-Quests isolated Board.lua into its own
milestone as the newest/least-proven piece. Code-complete; NOT yet
in-game tested (this is the single highest-risk untested piece of
DH-Bavin so far, same category as DH-Tools' original minimap dropdown
menu failure before k-0003/k-0004).

**M6 - Test & package.** Headless Lua harness built 2026-08-04
(`Modules\DHBavin\tests\harness.lua` + `run-tests.ps1`, mirroring
DH-Quests' own tests\ pattern exactly) - loads the real Core.lua/
Sync.lua/ItemPoints.lua against a mocked WoW API (PointsEditor/
PriorityEditor/BagMail/Tooltip excluded, same "UI-hook-heavy" exclusion
DH-Quests makes for its own Board.lua). 63 checks, all passing:
guild-leader/guild-membership permission grants AND refusals in both
directions (local gate + receive-side "never trust a self-asserted
sender" verification, modeled on DH-Air's own leader/assist tests),
the 2026-08-04 CanEditList/PruneDepartedRecipientEditors fix (including
its empty-roster safety guard), name-keyed AddItem/RemoveItem, and a
deliberately-forced multi-chunk SYNCDATA round-trip (5 editors + 3
realistic colored item links, verified to need >1 chunk, reassembles
byte-for-byte including embedded "|" characters) - the exact sub-case
STATUS.md had flagged as never actually exercised past a single chunk.
`build-test-zip.ps1 -Module DH-Tools` already strips any folder named
`tests` at any depth (fixed 2026-07-27 for DH-Quests' own nested tests\,
confirmed to cover this one too - no packaging change needed).
**This harness proves the LOGIC is correct; it does NOT replace the
required in-game test pass** with Loopi before any milestone is called
fully done, per README's testing rule - different guarantee (real
client, real roster, real second player).

## Deferred to a later version (not in this plan)
- Auto-filling the mail body/subject.
- A "claimed" state so two guildmates don't both mail the same rare item
  redundantly (nice-to-have, not core to v1).
- Any UI for the recipient to mark an item "received" and remove it from
  the list automatically (v1 requires manual list edits).
