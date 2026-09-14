# DH-Bavin Guild-Chat Item Lookup - Design & Milestone Plan
created: 2026-09-13
updated: 2026-09-13
status: SHIPPED - CL1-CL4 complete, Chris-confirmed working in-game,
kill switch removed. Releasing as DH-Tools v2.0.6.

## Concept

Any guild member can ask about an item's Bavin value just by posting it
in guild chat, instead of needing to check with Bavin or an editor
directly: post a message starting with `?` followed by an item link, and
some online client running DH-Bavin replies in guild chat with the
item's long-form info line. Exactly one reply per item asked about, from
whichever qualifying client answers first - fully automatic, no click
required from the responder.

This reuses data DH-Bavin already has (`ItemPoints.lua`'s `detail`
field, still generated from every release's spreadsheet even though
`Tooltip.lua` stopped displaying it 2026-08-19 - see Corrections below)
and extends the module's existing conventions: guild-roster-scoped
addon messages (same channel/idiom as Sync.lua's SYNCREQ/SYNCDATA), a
receiver-side race resolved by broadcast + short wait (same shape as
the permission-verification idiom elsewhere in the module, applied to a
new purpose), and fully client-local, best-effort behavior consistent
with DH-Bavin's guild-social-trust model.

## Correction (2026-09-13) - the long-form text was never lost

Initial framing of this feature wrongly assumed the pre-2026-08-19 rich
tooltip text was gone and would need to be re-derived or re-imported.
Checked `build-itempoints.ps1` and `ItemPoints.lua` directly: the
`detail` field (column P of the spreadsheet, format `"<name>: <points>
pts to Bavin; <price/source>"`) is still generated into every one of
the current ~7,008 entries. Only `Tooltip.lua`'s hover-tooltip display
stopped reading it; the data pipeline never touched it. This feature
reads `.detail` directly off the existing table - no spreadsheet
re-import needed to ship it, and no Lua data-layer change either.

## Trigger detection

- The **first character** of the guild chat message must be `?`,
  immediately followed (directly or via whitespace) by an item
  hyperlink. Anything else in the message before the `?` disqualifies
  it - "does anyone know? [Thorium Bar]" does NOT trigger. Text after
  the first link(s) is allowed and ignored.
- Guild chat (`CHAT_MSG_GUILD`) only - not officer chat.
- Up to the **first 3 item links** in a qualifying message each get
  their own independent trigger + response; a 4th+ link is ignored.
- No cooldown - repeated identical questions each get a fresh answer.
- Each of the up-to-3 links is treated as its own independent
  trigger/claim/response cycle (own claim broadcast, own timing, can
  have different winning responders) - not batched into one reply.

## Response priority (per triggered item link)

Evaluated identically by every client that sees the trigger, so the
outcome only depends on the item, not on who answers:

1. **Not tradable** - item's class is Quest, or its bind type is Bind
   on Pickup (checked via `GetItemInfo`'s classID/bindType, falling
   back to a hidden-tooltip line scan for "Quest Item" / "Binds when
   picked up" if those fields prove unreliable in this client - same
   caution as this module's other unverified-API notes; needs in-game
   confirmation like everything else here). Overrides any `ItemPoints`
   entry, since a value is moot if it can't be traded.
   Reply: `<item link> [item] is not tradable and has no value other
   than using it or vendoring it.`
2. **Has data** - item's exact name is a key in `ns.ITEM_POINTS` with a
   non-nil `detail`.
   Reply: `<item link> <detail text>` (the existing spreadsheet-sourced
   string, e.g. "47 Pound Grouper: 0 pts to Bavin; n/a from a
   @Fisher").
3. **No data** - name not found, or found with `detail = nil`.
   Reply: `<item link> Bavin has no data for [item]. Please message him
   to let him know.`

All three lead with the clickable item link for context, consistent
with Chris's "link first, then text" instruction - including the
no-data and not-tradable cases, which weren't explicitly specified;
flagging this assumption in case a bare text reply is preferred there
instead.

## "Nobody's watching" fallback - lives in DH-Tools Core, not gated by the module toggle

If no claim broadcast is heard within the wait window (see below), the
watching client posts:

`Nobody online has the DH-Bavin module enabled. Please install DH-Tools
and enable the DH-Bavin module.`

This can only be true and postable if the code watching guild chat for
the `?` trigger lives in **DH-Tools Core** (loaded for anyone with
DH-Tools installed, regardless of which modules they've toggled on) -
not inside the Bavin module's own `IsModuleEnabled("bavin")` gate. If
the watcher itself lived behind that gate, the message would be
self-contradicting (the poster would necessarily have Bavin enabled).
Core does the trigger detection, link parsing, and claim-timeout logic;
only the actual item lookup (`ns.ITEM_POINTS`, the not-tradable check)
requires the Bavin module to be enabled, so a Core-only client can
notice the silence and post the fallback without being able to answer
the question itself.

## Claim protocol (redesigned 2026-09-14 - bid-then-decide, not a race)

Two message types on DH-Tools' existing guild addon-message channel,
scoped per triggering chat line + link position so concurrent questions
about different items (or the same item asked twice) don't collide:

- **Key** = `{sender, raw chat message text, link index within it}` -
  deterministic and identical across every client that received the
  same `CHAT_MSG_GUILD` event, no clock sync or server-assigned ID
  needed.
- **Original design (shipped 2026-09-13, replaced 2026-09-14):** each
  eligible client waited a random delay then broadcast a claim if it
  hadn't already heard one; first claim heard won, ties broken randomly.
  Chris explicitly accepted the rare duplicate as the cost of keeping it
  simple - but in real guild use with several people online at once it
  wasn't rare, it was routine ("way too spammy", 2026-09-14), even after
  widening the random window once already. The problem was structural:
  a random-delay race can only ever make collisions less likely, never
  guarantee they don't happen, and it gets WORSE the more people are
  contending - a birthday-paradox problem that padding the window
  further doesn't escape.
- **Current design:** every eligible client that becomes ready to
  answer (real data, a cache-miss retry that resolved, or the fallback
  text) immediately broadcasts a **BID** carrying a random tiebreak
  value, and tracks every BID it hears for that key. A fixed
  **BID_WINDOW (0.4s)** later, each bidder checks whether its own
  tiebreak was the LOWEST of every bid it saw for that key - if so, it
  broadcasts **CLAIM** and posts the reply; otherwise it stands down.
  Every bidder compares the same final set of bids, so they all agree
  on the same winner without needing to have fired at exactly the same
  moment. This is deterministic, not probabilistic: the only thing that
  has to hold is BID_WINDOW being longer than real guild-chat
  addon-message propagation time (comfortably true - the same channel
  SYNCREQ/SYNCDATA and RECIPIENT/EDITORS sync round-trip on well under
  this), and that safety margin does NOT shrink as more people are
  online, unlike the old random-delay window.
- CLAIM still exists and still means "stand down forever" to anyone who
  hears it - it just no longer decides the winner, only tells a
  latecomer (e.g. a slow cache-miss retry) that this key is already
  settled so it shouldn't even bother bidding.
- **No priority order.** Still rejected (Chris, 2026-09-13) - the
  protocol already guarantees exactly one responder regardless of who it
  is; a priority tier would add complexity without fixing a real
  problem.
- **Mixed-version guilds:** an un-upgraded client only understands
  CLAIM, not BID - it still respects a CLAIM broadcast from an upgraded
  client (so it won't double-answer against one), but it still runs its
  OLD random-delay race internally and could in principle answer before
  an upgraded client's BID_WINDOW finalizes. Not fully solved short of
  everyone being on the same version - acceptable given how quickly a
  small guild converges on the latest CurseForge/GitHub release.
- Fully automatic end to end - the winning client posts to guild chat
  itself, no confirmation click from that player. This is new territory
  for the suite (every other DH-Bavin chat-adjacent action - the
  mailbox "Fill Recipient" button - requires an explicit click); noting
  it plainly since it's a real behavior change, per Chris's explicit
  instruction (#12) that no click should be required.

## Chat-send mechanics

- Guild chat lines cap at 255 characters. A `detail` string plus a full
  item link can approach that for items with long names; if a reply
  would overflow, truncate the trailing detail text (never the link)
  rather than dropping the reply.
- Up to 3 independent replies can fire from one trigger message (one
  per linked item). `SendChatMessage` calls fired back-to-back can be
  silently dropped by the client's own chat throttle, so stagger
  multiple sends from the same client by roughly half a second.

## Kill switch - added for testing, removed 2026-09-13 (CL4)

Added as a temporary Bavin Config checkbox (`chatLookupEnabled`,
default on) at Chris's request for the testing phase, tied explicitly
to CL4: remove it once the feature is confirmed working in-game. Chris
confirmed 2026-09-13 ("It all seems to work fine now") and approved
removal - the checkbox, its `Bavin.db.chatLookupEnabled`/Core.lua gate,
and the DHBavin `InitDB` default are all gone as of the 2.0.6 release.
No suite-wide or per-client disable exists anymore; disabling the
Bavin module itself is the only way to opt a client out.

## Unrelated item raised this session (not part of this feature)

Chris also wants **Quests** added to the fresh-install default-enabled
set (Bavin is already default-on per the 2026-09-03 DH-Tools v2.0.3
module-default flip; Quests currently is not). Tracking here so it
isn't lost, but it's a one-line Core.lua default-table change,
independent of everything above - can ship separately whenever
convenient rather than waiting on this design.

## Release checklist note

Chris asked to be reminded: before this feature (or any DH-Bavin
change) goes out in a public release, get a refreshed points
spreadsheet into `claude\DH-Bavin\intake\` and re-run
`build-itempoints.ps1` so `ItemPoints.lua` ships current before
packaging - not required to build/test THIS feature (current data is
already live and complete), but don't skip it at actual release time.

## Open questions

- Kill-switch checkbox - yes/no (see above).
- Confirm item-link-first formatting is wanted on the not-tradable and
  no-data replies too, not just the has-data case.
- BoP/Quest detection via `GetItemInfo` classID/bindType vs. a
  tooltip-text fallback needs an in-game check on this client
  (Interface 11509) before being trusted, same as every other
  Blizzard-frame-adjacent risk already flagged in DH-Bavin's PROFILE.md.

## Issues found during in-game testing (2026-09-13)

- **Wording change**: the not-tradable reply text was changed at Chris's
  request from "is not tradable and has no value other than using it or
  vendoring it." to "cannot be traded. Use it, Vendor it, or DE it."
- **Bug: eager classification (fixed)**. `TryClassifyLookup` was
  originally called synchronously the instant the trigger arrived
  (t=0), before any delay - a near-guaranteed `GetItemInfo` cache miss
  for a freshly-linked item, so the client fell straight through to the
  "nobody has Bavin enabled" fallback even with Bavin on. Fixed by
  deferring the actual classification call into the answer-delay timer
  callback itself (fires at 0.1-1.2s instead of t=0).
- **Bug: silent on items only a guildmate has seen (fixed)**. Even after
  the above fix, replies stayed completely silent for items the
  answering client itself had never cached before (typically something
  only the asker, not the answerer, had seen) - the 0.1-1.2s window
  isn't enough for the FIRST-EVER `GetItemInfo` fetch of an item to
  round-trip. Fixed with a bounded `GET_ITEM_INFO_RECEIVED` retry
  (Chris's approved approach, 2026-09-13): a genuine cache-miss (nil,
  not an error) at fire time registers the pending {key, link} against
  the item ID; if `GET_ITEM_INFO_RECEIVED` fires for that ID within 5
  seconds (Chris's explicit ceiling), the client gets one more shot at
  classifying and, if still unclaimed, answers. See Core.lua's own
  comments around `pendingLookups`/`RegisterPendingRetry` for the full
  mechanics.

## Milestone plan (draft, pending sign-off)

- **CL1** - DH-Tools Core: `CHAT_MSG_GUILD` watcher, trigger grammar,
  link extraction (up to 3), claim-key construction, claim
  broadcast/listen with the 2s window and random tie-break, fallback
  message post.
- **CL2** - DH-Bavin module: item classification (not-tradable / has
  data / no data), reply text construction and truncation, chat-send
  staggering for multi-link messages.
- **CL3** - Headless harness covering trigger grammar edge cases, claim
  key uniqueness, and reply-priority selection; in-game pass covering
  all three reply types, the fallback message, a multi-link message,
  and a deliberately provoked simultaneous-claim scenario. **Partial**:
  Chris's in-game testing (not-tradable, has-data, the cache-miss retry)
  confirmed working 2026-09-13; the headless harness itself was not
  built (only ad hoc `luac5.1` syntax checks).
- **CL4** - Remove the temporary kill switch (Config.lua checkbox +
  Core.lua/DHBavin Core.lua reads of `chatLookupEnabled`) once the
  feature is confirmed working in-game. **Done 2026-09-13**, per Chris's
  approval.
