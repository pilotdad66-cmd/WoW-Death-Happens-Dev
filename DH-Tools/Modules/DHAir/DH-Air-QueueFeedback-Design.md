# DH-Air Queue Feedback & Assisted Destinations - Design
created: 2026-08-07
status: BUILT, NOT IN-GAME TESTED. Decisions below are Chris's (2026-08-07
        chat). M1+M2 built 2026-08-07 (commit d80b4c1); M3+M4 built
        2026-08-08 (commits 03bdb61, 9b78f5b). M5's harness half is done -
        487 assertions, 0 failures, M3/M4 mutation-checked - but the
        in-game half is entirely outstanding: see claude\TEST-PLAN.md
        section A11 for the checklist, and note that NOTHING here has run
        in a live WoW client yet.

## Origin
The 2026-08-07 raid pass (v2.1.3, 30+ summons) produced one piece of real
negative feedback: a "significant delay" between a guildmate whispering
AIR and that character appearing in the summon queue. Chris's hypothesis
was raid-invite-acceptance lag. Investigation found that is NOT the cause -
`QueueAdd` runs synchronously inside the whisper handler and nothing in
the addon waits on raid membership.

IMPORTANT CONTEXT for anyone reading this later: at that raid, almost
nobody except the Warlock had DH-Air installed. Requesters are plain
guildmates typing chat messages, with no addon and no UI. Every design
decision below follows from that.

## Findings (code as of v2.1.4)

### F1 - Exact-match-only triggers silently drop real requests (PRIMARY)
`Invite.lua:60` requires the trimmed, lower-cased whisper to EQUAL
`db.codePhrase` exactly. "air pls", "air to SM", "AIR!", "air?" match
neither the phrase nor any INVITE_PATTERNS entry, so they produce no
invite, no queue entry, and no reply of any kind. The requester waits,
gets nothing, eventually re-whispers a bare "air" and lands instantly.
From the Warlock's side that is an unexplained multi-minute gap. With
no addon on the requester's end there is nothing anywhere telling them
the syntax is strict.

### F2 - "inv" invites but deliberately does not queue
The 2026-08-05 explicit-join rule (Invite.lua:44-53) means "inv" /
"invite me" auto-invites only. Anyone who whispered "inv" first and
"air" later reproduces the reported symptom exactly. This is working as
designed; noted so it isn't re-diagnosed as a bug.

### F3 - There is no such thing as a "session"
`queue` and `history` are plain keys in `DHAirDB` (Core.lua:44-45),
account-wide SavedVariables written to disk at logout. Nothing clears
them at login. The only reset paths are Config.lua's "Reset Queue /
Session" button, the Board's Clear All (RequestClearAll), and a synced
RESET/CLEARALL. So `QueueAdd`'s "already summoned this session, don't
re-queue" guard (Queue.lua:26) really means "summoned at any point since
someone last clicked Reset" - across logouts, weeks, and every alt on the
account. A raider summoned three weeks ago is permanently and SILENTLY
barred (QueueAdd returns false with no Print at all).
Compounding it: `db.queue` also persists and never drops summoned
entries, and `Sync_SendState` re-encodes the whole accumulated table into
200-char chunks for every late joiner's handshake, which also re-seeds
their `history`.

### F4 - No resync when a client joins a group/raid
`Sync_Channel` (Sync.lua:126) prefers RAID > PARTY > GUILD, so once the
Warlock is in a raid every ADD/CLAIM/SUMMONED goes to RAID only. A
DH-Air-running requester is by definition not in the raid when they
whisper, so they never hear the ADD that queued them. On joining,
GROUP_ROSTER_UPDATE -> `Sync_OnRosterChanged` sends only HELLO (throttled
300s), and HELLO's receiver does nothing. SYNCREQ is sent ONLY from
`Sync_Init` at PLAYER_LOGIN (Core.lua:499). Result: they stay missing
from their own Board until they /reload or type `/dhair sync`.
Did not affect the 2026-08-07 raid (nobody else had the addon) but it
blocks any future world where requesters run DH-Air.

### F5 / F6 - Ruled out
Board refresh is a 1s ticker (Board.lua:17) - not "significant".
`Board_Refresh` freezes under InCombatLockdown (Board.lua:364), but it
returns at the `frame:IsShown()` check first, so a closed window costs
nothing, and Chris confirmed a Warlock in combat isn't watching the Board
anyway. No action.

## Decisions (Chris, 2026-08-07)

- **D1 Channels**: add `CHAT_MSG_PARTY` and `CHAT_MSG_PARTY_LEADER`
  alongside the existing WHISPER / RAID / RAID_LEADER registrations
  (Core.lua:351-354). Guild chat stays deaf - too broad.
- **D2 Matching**: PREFIX match in whispers, EXACT match in public
  channels. "air to SM" whispered queues them and captures "to SM" as a
  free-text note; raid/party chat still needs the bare phrase so that a
  Warlock typing "air service is up, whisper me" cannot queue themselves.
- **D3 Assisted destinations**: a Warlock must be able to set ANY queued
  player's destination, gated to raid leader / assist, and doing so
  whispers the affected player a plain chat confirmation. This is the
  whole answer to "how does a requester with no addon pick a
  destination" - they don't; they say where they want to go in chat and
  the Warlock sets it.
- **D4 Re-queue**: always allowed. Drop the "already summoned" block
  entirely. Chris's framing: "in an ideal world the queue will never be
  reset because people will always be in it."
- **D5**: design first, build next session.
- **D6 The note never goes on the wire.** `note` stays LOCAL to whichever
  client received the whisper. Syncing it would make it DH-Air's first
  free-prose wire field, carrying exactly the k-0024 escaping hazard
  DH-Bavin hit with its tooltip wording. It isn't needed remotely: the
  Warlock who received the whisper is the one who reads the note and
  sets the destination, and the destination itself already syncs.
- **D7 Prune summoned entries at login.** In the same ADDON_LOADED block
  that already migrates `queuedAt`. At login ONLY, never mid-session -
  a summoned entry stays visible for the rest of the play session it
  happened in.
- **D8 No PREFIX bump for SETDESTFOR.** It is purely additive and Chris
  is enforcing that everyone updates. Note for whoever builds it: the
  version that has to be universal is the one CARRYING SetDestFor (2.2.x
  or whatever it lands in), not 2.1.4 - a client on 2.1.4 ignores the
  message and its Board will silently disagree about destinations.
- **D9 An accidental re-summon beats a blocked join.** Chris's explicit
  call (2026-08-07) on the one thing D4 gives up. Nothing in the code
  should ever refuse a queue join to protect a Warlock from wasting a
  shard - the failure mode that actually hurt the guild was silent
  exclusion, and a wasted shard is cheap and visible by comparison.
  Standing rule for anyone tempted to add a guard back: make it
  INFORM the Warlock, never REFUSE the requester.

## Implementation plan

### M1 - Trigger matching and channels (F1, D1, D2)
- Register CHAT_MSG_PARTY / CHAT_MSG_PARTY_LEADER; route both to
  `HandleRaidChat` (rename it - it is no longer raid-specific).
- `HandleWhisper`: replace the `trimmed == phrase` equality with a prefix
  test (`phrase` followed by end-of-string or whitespace), capturing the
  remainder as `note`.
- Public channels keep the exact-equality test unchanged.
- Store `note` on the queue entry; display it on the Board row so the
  Warlock can see the requested destination before setting it.
- `note` is LOCAL-ONLY (D6). Do NOT add it to EncodeQueue /
  DecodeQueueChunk - a synced free-prose field is the k-0024 trap.

### M2 - Always-allow re-queue (F3, D4)
- Remove the `db.history[short]` guard in `QueueAdd`.
- The duplicate scan immediately above it also matches SUMMONED entries,
  so removing the history check alone is not enough: an existing summoned
  entry must be RESET in place (clear `summoned`, refresh `queuedAt`,
  clear `destination`/`note`) rather than refused.
- `Sync_MergeEntries` treats `summoned` as sticky - it only ever upgrades
  waiting -> summoned. A stale snapshot from another Warlock would
  silently re-flag a freshly re-queued player. Needs a freshness guard:
  ignore a remote `summoned` whose implied queue time is older than the
  local entry's `queuedAt`.
- Decide what `history` is still for once the block is gone. It is
  written by QueueMarkSummoned and Sync_MergeEntries and read nowhere
  else afterward; likely deletable outright.
- Prune summoned entries at login (D7) so `db.queue` and every SYNCDATA
  payload stop growing without bound. Same ADDON_LOADED block that
  already migrates `queuedAt`, before Sync_Init can answer anyone.

### M3 - SETDESTFOR (D3)
- New sync message `SETDESTFOR|Name|destId`, verified receive-side with
  `UnitHasAuthority(sender)` - the same gate REMOVE / CLEARALL /
  SETPHRASE already use, never self-asserted. `SETDEST` stays self-only
  and untouched.
- Purely additive to the wire: the receive handler's if/elseif chain has
  no else, so a v2.1.4 client ignores the unknown type harmlessly.
  Therefore **no PREFIX bump** (still DHAirQueueV2), per D8.
- New `HasPermission("set_dest_any")` action rather than calling
  UnitHasAuthority directly at the UI site, matching the existing
  permission-model idiom.
- Board: destination control on any row, enabled only when the local
  player passes that gate. Reuse the existing dropdown generator.
- On success, whisper the affected player: their destination, who set
  it, and how to correct it. This is the ONLY feedback a non-addon
  requester ever receives, so wording matters.

### M4 - Resync on group join (F4)
- `Sync_OnRosterChanged`: send SYNCREQ when our own group/raid membership
  actually CHANGES (track the previous IsInRaid/IsInGroup state), not on
  every GROUP_ROSTER_UPDATE - that event fires constantly in a raid and
  would flood every peer with whispered SYNCDATA dumps.

### M5 - Verification
- Extend both harnesses; they currently cover QueueAdd/history and the
  SETDEST self-only rule, so those sections will go red and must be
  updated deliberately, not deleted.
- In-game: TEST-PLAN.md Part A additions for prefix matching, party-chat
  trigger, re-queue after summon, and an assisted destination set from a
  second account.

## Risks / open questions
- ~~Note escaping (k-0024 precedent)~~ RESOLVED by D6 - the note is
  local-only, so there is no wire-format hazard. The risk only returns
  if a later milestone decides other Warlocks need to see it; if that
  ever happens, escape it against "|", ":" and "," and bump the PREFIX,
  exactly as DH-Bavin's tooltip wording required.
- Prefix matching widens what counts as a request. "airhead" would match
  a bare-prefix test; the phrase must be followed by end-of-string or
  whitespace.
- ~~Double-summon exposure~~ ACCEPTED by D9 - D4 removes the only
  protection against a Warlock accidentally re-summoning someone
  summoned earlier, and that trade is deliberate. Mitigation is
  advisory only: the `summoned` flag still marks the old entry, so the
  Board should annotate a re-queued repeat ("summoned 12m ago") so the
  Warlock can notice. It must never gate the join.
- ~~Pruning scope~~ RESOLVED by D7 - kept for the current play session,
  dropped at the next login. It is still a data-loss operation on
  account-wide SavedVariables, so it must run AFTER the `queuedAt`
  migration and BEFORE Sync_Init, and must never touch waiting entries.
- Unrelated but adjacent: the queue never being reset means `db.queue`
  is now long-lived shared state. The k-0019 guild-name gap (DH-Air
  checks only `IsInGuild()`) matters more under that assumption.
