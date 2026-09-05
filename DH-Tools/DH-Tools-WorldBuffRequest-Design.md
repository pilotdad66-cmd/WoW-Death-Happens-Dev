# DH-Tools World Buff Summons Request - Design
created: 2026-08-17
status: M1/M2/M3 BUILT 2026-08-17, NOT IN-GAME TESTED (M4). Built
        unattended - Chris AFK, said "continue through the milestones
        unless you encounter a real roadblock." Harness 386+178=564/564,
        0 failures. See DH-Air\STATUS.md and DH-Tools\STATUS.md for the
        session write-ups, including one bug found/fixed via the test
        suite (SetRole's auto-leave-queue side effect) and one known,
        accepted edge case flagged for Chris to confirm (ClearRoster
        doesn't clean up a D5 auto-joined queue orphan).

## Origin
Chris wants a "Request World Buff Summons" option as the 2nd item on
DH-Tools' minimap left-click quick-actions menu (`BuildQuickMenu()`,
Minimap.lua), so a player can request a world-buff-destined raid invite
from an available Warlock without manually whispering anyone or knowing
a code phrase. The design below covers everything that touches: DH-Air's
existing whisper-invite mechanism, World Buff Mode (added earlier the
same day), the sync protocol, auto-summon targeting, and the Board's
queue display.

## Confirmed technical findings (code as of 2026-08-17, v2.1.7)

### F1 - INV whisper already does the whole job, when WBM is on
`HandleWhisper` (Invite.lua) already runs QueueAdd + Sync_BroadcastAdd +
`ApplyWorldBuffModeDestination` for both the "inv" trigger and the code-
phrase trigger. `ApplyWorldBuffModeDestination` already sets the
whisperer's destination to Booty Bay whenever the receiving Summoner has
`db.worldBuffMode` on. This existed before this design conversation
(built earlier 2026-08-17, same session). No new whisper-HANDLING code
is needed on the receiving end - only the pieces below.

### F2 - World Buff Mode state is not synced
`db.worldBuffMode` is set only locally from the Board checkbox's
`OnClick` (Board.lua:839) and never broadcast. No other client -
including a requester who isn't in the Summoner's raid/party - can
currently see who has it active. This is the actual blocker for "who do
I whisper," and the reason DH-Tools can't just pick any registered
Summoner today.

### F3 - Auto-summon matches against the WARLOCK'S OWN destination
`QueueNextAvailable` (Summon.lua, 2026-08-03 addition) requires the
Summoner's own destination to be set and only matches queue entries
sharing it; with no destination set, auto-summon "finds nothing to do."
So World Buff Mode must set the SUMMONER'S OWN destination to Booty Bay
too, not just the requester's - otherwise WBM-flagged requesters would
never get auto-summoned, only manually summoned.

### F4 - ManualSummon requires a real db.queue entry
`ManualSummon` (Summon.lua:439) looks the target up by name in
`db.queue` and refuses ("isn't in the queue") if absent. A display-only
/virtual row for registered Summoners/Clickers would NOT be clickable to
summon without extra special-casing - making them summonable means
giving them a real queue entry, not a cosmetic overlay.

### F5 - SortedQueue hides any entry with entry.summoned = true
Confirmed in Queue.lua: `SortedQueue` only includes entries where `not
entry.summoned`. A Summoner/Clicker's row would vanish the same way a
normal player's does once summoned, unless specifically exempted.

## Decisions (Chris, 2026-08-17)

### World Buff Mode changes (DH-Air)
- **D1 - WBM gets synced.** Toggling `db.worldBuffMode` self-broadcasts a
  new field over the existing sync channel, reusing SETDEST's pattern
  (self-only claim, ungated, no new permission tier - just an additional
  piece of state a client asserts about itself). Any online client can
  then see who currently has WBM active without needing to share a
  raid/party with them.
- **D2 - Turning WBM on also:**
  (a) force-enables `db.invAutoInvite`, and while WBM is checked that
      checkbox is locked on (greyed out) - can't drift out of sync with
      WBM and silently stop working.
  (b) sets the Summoner's OWN destination to Booty Bay (required by F3).
  (c) keeps existing behavior: sets the WHISPERER's destination to Booty
      Bay too (F1, already built).
- Turning WBM off unlocks `invAutoInvite` (leaves it checked, just
  independently toggleable again) and does not change anyone's
  destination retroactively.

### DH-Tools menu option
- **D3 - Targeting.** DH-Tools tracks the most recently/first-heard WBM-
  on broadcast per online, registered Summoner (D1). "Request World Buff
  Summons" whispers "inv" directly to whichever qualifying Summoner was
  heard from FIRST (earliest still-active WBM-on signal wins ties). No
  separate self-join step is needed - the existing whisper handling (F1)
  already does invite + queue + destination-set in one shot.
- **D4 - No-target fallback.** If DH-Tools currently has no qualifying
  Summoner cached (nobody broadcasting WBM-on, or the signal is stale),
  the menu item is disabled/greyed out with a tooltip explaining why
  ("No Warlock currently accepting world buff requests"), same pattern
  already used for "Open Summons Board" when DH-Air isn't installed.
- Staleness: a WBM-on signal needs a TTL so a Summoner who logged off
  without unchecking WBM doesn't stay listed as a target forever.
  PROPOSED (not yet confirmed): reuse the existing peer/claim TTL idiom
  (~120s, refreshed by a periodic re-broadcast) rather than inventing a
  new number - flag for Chris to confirm or override during build.

### Summoner/Clicker queue visibility (DH-Air)
- **D5 - Auto-join on registration.** Checking "I'm a summoner" or "I'm
  a clicker" auto-adds a real `db.queue` entry for that person (reusing
  the existing self-join mechanics), which sorts to the top for free via
  this session's existing role-tiering in `SortedQueue`. Unchecking the
  role removes their queue entry (mirrors registration state exactly).
- **D6 - Excluded from auto-summon.** `QueueNextAvailable` (Summon.lua)
  must skip any entry with `role == "summoner"` or `role == "clicker"` -
  they are never auto-picked, only manually summoned by clicking their
  row (F4 confirms manual summon needs a real entry, which D5 provides).
- **D7 - Always visible.** `SortedQueue`'s "hide if entry.summoned" rule
  (F5) must not apply to `role == "summoner"`/`"clicker"` entries - they
  stay listed regardless of summoned state, "so we can all see who is
  doing the work."
- **D8 - Re-summonable immediately.** Right after a Summoner/Clicker is
  manually summoned, reset their `entry.summoned` flag back to false so
  they remain available to summon again on demand, rather than needing a
  separate reset action.

## Resolved during build (2026-08-17)
- **WBM TTL: 300s**, matching Roster.lua's `ROSTER_TTL_SECONDS` exactly
  rather than the originally-proposed ~120s claim-staleness number - WBM
  re-broadcasts piggyback on the same throttled `Roster_Reannounce`/HELLO
  cadence as registration reannounce, so it made sense to share the same
  staleness tolerance rather than invent a second number.
- **Wire format: a brand new `WBM` message type**, not piggybacked on
  REGISTER - self-only/ungated, payload is just `"1"`/`"0"` (no name
  needed, sender comes from the trusted addon-message channel itself,
  same as HELLO). Kept fully separate from REGISTER's own migration-
  sensitive payload shape to avoid any wire-format risk to that message.
- **D3 tiebreak wording settled as "first one heard from"** (earliest
  still-active WBM-on signal), tracked via a `firstSeen` timestamp
  distinct from the re-broadcast-refreshed `lastSeen`, so periodic
  heartbeats don't reset a Summoner's place in line.
- Known orphan edge case surfaced by the test suite (ClearRoster/D5) -
  see the status header above and DH-Air\STATUS.md for detail. Chosen
  resolution: leave ClearRoster untouched (preserves the deliberate
  2026-08-13 roster/queue separation) rather than reach into `db.queue`
  from a bulk leader action; flagged for Chris to confirm or override.

## Suggested implementation milestones
- M1: DH-Air - WBM sync broadcast (D1), WBM-on side effects (D2). DONE.
- M2: DH-Air - Summoner/Clicker auto-queue-join, auto-summon exclusion,
  always-visible + re-summonable display rules (D5-D8). DONE.
- M3: DH-Tools - target tracking (cache of heard WBM-on Summoners) and
  the new left-click menu item + fallback disabled state (D3-D4). DONE.
- M4: In-game test pass (per project rule, only Chris can confirm this
  works live) - covers a full walkthrough of the numbered flow Chris
  described (Summoner sets up -> requester whispers or uses the DH-Tools
  option -> gets invited/queued/destination-set -> gets summoned ->
  removed from queue; Summoner/Clicker rows stay visible throughout).
  NOT STARTED - needs Chris, and needs its own explicit test-zip rebuild
  ask (README §12) covering both DH-Air and DH-Tools.
