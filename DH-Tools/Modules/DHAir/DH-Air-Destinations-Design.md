# DH-Air Destinations - technical design doc
drafted: 2026-08-03 (planning only, no code written yet - see STATUS.md for
build status). Historical reference once code and design diverge, same
status as DH-Air-v2-Design.md - the code is ground truth once this ships.

## 1. Feature summary

Two related additions to the existing shared queue:

1. **Self-service destination picker.** Anyone in the queue can pick where
   they want to end up (an Alliance flight point or a dungeon summoning
   stone) from a guild-curated list, same self-service idiom as joining/
   leaving the queue - no permission needed to set your own choice.
2. **Guild-officer-editable destination list.** The list of choices itself
   is guild-wide, synced state, editable only by a guild officer (rank-based,
   the extension point HANDOFF.md flagged as deferred to "v2.2" back in the
   v2.0 design). Everyone else sees it read-only.

Net effect for Warlocks: open the Board, see who's queued AND where they
want to go, and (if they're online) reach out to coordinate the summon
directly - a "Whisper" quick action next to their row.

This does NOT change how summoning itself works (Warlocks still summon to
their own current location, per Ritual of Summoning's actual game mechanics)
- destination is informational/coordination data, not a targeting system.

## 2. Data model (Core.lua + new Destinations.lua)

**New file `Destinations.lua`** holds `DHAir.DEFAULT_DESTINATIONS`, an
ordered array of `{ id, label, category }` (`category` = `"flightpoint"` or
`"summonstone"`), e.g.:

```lua
DHAir.DEFAULT_DESTINATIONS = {
    { id = "stormwind",   label = "Stormwind City",       category = "flightpoint" },
    { id = "ironforge",   label = "Ironforge",             category = "flightpoint" },
    { id = "darnassus",   label = "Darnassus",             category = "flightpoint" },
    -- ... every other Alliance-reachable flight point (zone hubs, neutral
    -- goblin towns usable by Alliance, etc.)
    { id = "deadmines",   label = "The Deadmines",         category = "summonstone" },
    { id = "wailingcaverns", label = "Wailing Caverns",    category = "summonstone" },
    -- ... one entry per instance with a summoning stone
}
```

**UPDATE 2026-08-03:** Loopi wants the list pre-populated rather than
shipped empty, so real content now lives in `Destinations.lua`
(33 flight points, 22 dungeon summoning stones). The flight points were
cross-checked against a current Classic Era Alliance flight-point table
(gamingcy.com's WoW Classic Flight Paths guide, cross-referenced with
vanilla-wow-archive's Flight_path wiki page) - see that chat response for
source links. The summoning-stone entries were NOT sourced the same way -
they're compiled from general Classic Era dungeon knowledge and should get
an in-game/wiki sanity pass (especially the four separate Scarlet Monastery
wing entries) before being trusted as complete. `Destinations.lua` exists
as a standalone data file now but isn't wired up yet - Core.lua doesn't
seed `db.destinations` from it, and `DH-Air.toc` doesn't load it - that
wiring is still M1 work (§8). Officers can correct/extend anything in it
once the editor (M4) exists; nothing in the file is authoritative.

**Core.lua defaults additions:**
```lua
destinations = {},              -- seeded from DEFAULT_DESTINATIONS on first load only
officerRankThreshold = 4,       -- guild rankIndex <= this counts as "officer"; guild-leader-editable
```
`CopyDefaults` only fills *missing keys*, so seeding `destinations` needs an
explicit one-time check in the `ADDON_LOADED` handler (mirrors the existing
`queuedAt` sanity-fix already there):
```lua
if #DHAir.db.destinations == 0 then
    for _, d in ipairs(DHAir.DEFAULT_DESTINATIONS or {}) do
        table.insert(DHAir.db.destinations, { id = d.id, label = d.label, category = d.category })
    end
end
```

**Queue entry** (`Queue.lua`'s `QueueAdd`) gains one field:
`destination = nil` - an `id` string referencing `db.destinations`, or nil
("undecided"). Set later via a new `DHAir:SetMyDestination(destId)`, not at
join time - keeps `QueueAdd`'s signature unchanged and matches how role
registration already works independently of queue-join.

**UPDATE 2026-08-03 (post-M2):** a second, unrelated piece of local state
was added - `db.warlockDestination`, a Warlock's own "which destination am
I servicing right now" operating flag. This is deliberately **not synced**
(no default entry, no `SETDEST`-style broadcast) - it's not guild-wide
state like `db.destinations`, and not a queued player's own choice like
`entry.destination`; it's purely local operating context for whichever
Warlock is running auto-summon on their own client, set via
`DHAir:SetWarlockDestination(destId)` / `/dhair warlockdest`. See the new
§5a and the M2.5 entry in §8.

## 2a. Auto-summon destination matching (added 2026-08-03, post-M2)

Once players can choose a destination, auto-summon needs to only pull
players headed to wherever the summoning Warlock actually is - otherwise
"Start auto-summon" would happily drag someone to the wrong flight point.

- `Summon.lua`'s `QueueNextAvailable(sharing)` now requires
  `self.db.warlockDestination` to be set at all (returns `nil` immediately
  if not - auto-summon simply can't run blind), and filters candidates to
  `entry.destination == self.db.warlockDestination` alongside the existing
  claim/`summoned`/`guildOnly` checks.
- `ManualSummon` is **not** affected - it targets whoever you explicitly
  pick, bypassing `QueueNextAvailable` entirely, same as it always has.
- New `DHAir:RequestStartAutoSummon()` / `RequestResumeAutoSummon()` wrap
  the old direct `db.active`/`db.paused` flips from `Commands.lua` and
  `Board.lua`'s auto-summon button - both refuse (printing a hint pointing
  at `/dhair warlockdest`) and return `false` if `warlockDestination` isn't
  set, so there's one choke point instead of duplicating the check at each
  call site.
- **Product bug found and fixed while testing this:** `SetMyDestination`
  and the `SETDEST` sync receiver didn't re-trigger `TrySummonNext()` after
  applying a change. In real play this meant an already-running Warlock's
  auto-summon loop wouldn't notice a player who sets their destination
  *after* joining - it'd sit idle until some unrelated event (roster
  change, bag update, etc.) happened to re-trigger it. Fixed by adding the
  same re-trigger pattern `SelfJoinQueue`/`RELEASE`/`SUMMONED`/
  `Sync_MergeEntries` already use after any state change that could newly
  satisfy the idle picker.

**Guild roster cache** (`Core.lua`'s `UpdateGuildRosterCache`) gains
`rankIndex`, mirroring DH-Bavin's `Core.lua` pattern exactly (`GetGuildRosterInfo`
already returns it as the 3rd value; DH-Air's own cache just wasn't
capturing it before now since nothing needed it).

## 3. Permission model (extends Core.lua's single entry point, per HANDOFF.md)

```lua
-- Fails CLOSED (false) if unverifiable - same reasoning as DH-Bavin's
-- IsGuildLeader: this gates a write action, unlike IsGuildMember's
-- deliberately fail-open check for a lower-stakes purpose.
function DHAir:IsGuildOfficer(name)
    if not name then return false end
    local entry = self.guildRoster[self:NormalizeName(name)]
    return entry ~= nil and entry.rankIndex ~= nil
        and entry.rankIndex <= (self.db.officerRankThreshold or 4)
end

function DHAir:HasPermission(action)
    if action == "remove_any" or action == "clear_all" or action == "set_phrase" or action == "invite" then
        return self:UnitHasAuthority(UnitName("player"))
    elseif action == "edit_destinations" then
        return self:IsGuildOfficer(UnitName("player"))
    elseif action == "set_officer_threshold" then
        -- rank 0 (Guild Master) only - officers must not be able to widen
        -- their own gate by lowering the threshold.
        local entry = self.guildRoster[self:NormalizeName(UnitName("player"))]
        return entry ~= nil and entry.rankIndex == 0
    end
    return false
end
```
Same call-site pattern as every existing permission-gated action - no
parallel system, per HANDOFF.md's explicit instruction.

**2026-08-03 - testing override already live:** `Core.lua`'s
`UnitHasAuthority` now has a hardcoded full-permission bypass for
`Loopidot` (both the local check and the receive-side verification other
clients run on an incoming broadcast), same "bypass both sides" idiom as
DH-Bavin's `TESTING_ALLOW_ANYONE_TO_MANAGE`. It only covers actions gated
through `UnitHasAuthority` (`remove_any`/`clear_all`/`set_phrase`/`invite`)
- once `IsGuildOfficer` above is actually implemented (M3), it needs the
same override added, since `edit_destinations`/`set_officer_threshold`
don't route through `UnitHasAuthority`. Remove before real permission
enforcement is treated as verified.

**UX note on the threshold:** a bare rank-index number is not officer-
friendly (Loopi would have to know Blizzard numbers ranks top-down from 0).
Recommend the Config field be a dropdown populated from
`GuildControlGetRankName(i)` for `i = 0..GuildControlGetNumRanks()-1` so
Loopi picks a rank *by its actual guild-configured name* ("Officer") and
the addon stores the resulting index - same spirit as `Config.lua`'s
existing settings, better usability than DH-Bavin's hardcoded rank-0-only
check.

## 4. Sync protocol (extends Sync.lua)

Two independent concerns, kept as separate message types:

| Message | Payload | Sent by | Verified how |
|---|---|---|---|
| `SETDEST` | `Name\|destId` (destId `""` clears it) | self, on choosing a destination | receiver requires `Name == sender` (self-service only, like `ADD`) - one player cannot set another's destination remotely |
| `DESTLIST` | chunked, `i/total\|id:category:label,...` | officer, after any add/remove/rename/reset | receiver checks `HasPermission("edit_destinations")`-equivalent against the SENDER (`UnitHasAuthority(sender)` interim / `IsGuildOfficer(sender)` in M3), never trusting the message itself - a fresh claim of new state |
| `DESTSYNCDATA` | chunked, same encoding as `DESTLIST` | whoever answers a `SYNCREQ` | **not gated at all** - reflects state the responder already holds (which itself passed the `DESTLIST` gate when THEY received it), not a fresh claim - same reasoning DH-Bavin documents for its own RECIPIENT/EDITORS resync. Added mid-M2 after realizing a single shared message type would force the SYNCREQ responder (not necessarily an officer) through the same gate as a live edit |

`DESTLIST` reuses the existing chunking helper pattern from
`EncodeQueue`/`DecodeQueueChunk`/`Sync_SendState` (full-replace, not a diff -
matches DH-Bavin's own "send the whole small set" idiom for its
recipient/editors list, and destination lists are small enough - tens of
entries - that incremental ADD/REMOVE messages aren't worth the complexity).

**Late-joiner sync - DONE as described, with one correction:** the queue's
own `SYNCDATA` encoding was extended exactly as planned
(`Name:status:role:elapsed` -> `Name:status:role:elapsed:destId`,
bootstrap-only on brand-new entries, same rule role already followed) so a
late joiner learns everyone's already-chosen destination through the
ordinary queue resync. But the *list itself* is sent via `DESTSYNCDATA`, a
separate ungated message - NOT `DESTLIST` as originally written here - for
the reason explained in §4's message table and §8's M2 changelog entry.

## 5. UI changes

### Board.lua (shared queue view)
- New `COL_DEST_WIDTH` column between name and wait-time, following the
  same right-to-left fixed-column anchoring `CreateRow`/`sortWaitBtn`
  already use. Frame's default/min width grows to fit (480 -> ~580,
  `ApplyResizeBounds` min bumped accordingly).
- **Your own row:** destination cell becomes a dropdown
  (`UIDropDownMenu`, standard Blizzard template) listing `db.destinations`
  grouped by category, defaulting to "(pick a destination)". Selecting
  calls `DHAir:SetMyDestination(destId)` -> updates the local queue entry
  and `Sync_Send("SETDEST", ...)`.
- **Everyone else's row:** plain text showing their chosen destination's
  label, or "-" if unset.
- **New "Whisper" quick action:** shown next to Summon/Invite for any
  non-self row that's currently online (reuses the existing `isOffline`
  branch already in `RenderRow`) - calls Blizzard's `ChatFrame_SendTell`
  to open a whisper addressed to that player, so a Warlock near a given
  destination can message "on my way" without leaving the Board.
- **New "Destination" sort header**, alongside the existing Name/Waiting
  ones, extending `SortedQueue`'s tiered sort (own row first, then
  role-tier, then everyone else) with a `dest` `sortKey` - lets a Warlock
  group the queue by where people are headed at a glance, which is the
  actual "see who wants to go where" ask.

### 5a. Board auto-summon button (added 2026-08-03, post-M2)

`Board_Refresh` now checks `self.db.warlockDestination` before rendering
the existing Stop/Start auto-summon toggle: if unset, the button is
**disabled** (`SetEnabled(false)`) with its text replaced by
"Pick a destination (/dhair warlockdest)"; once set, it behaves exactly as
before. Loopi explicitly delegated the choice between graying out the
button vs. printing a chat warning - gray-out was picked for the Board
(a button has somewhere to show state), with a chat-message fallback kept
for the slash-command path (`/dhair start`/`resume`), which has no button
to disable. `RequestStartAutoSummon`/`RequestResumeAutoSummon` (§2a) are
the single choke point both paths call through, so the gate can't drift
out of sync between the two UIs.

`Commands.lua` gained a new `/dhair warlockdest [<name>|clear]` subcommand
(show current / set via `FindDestinationByQuery` substring match / clear
with `clear`|`none`) - the interim way to set `warlockDestination` before
any dedicated Board UI exists for it. No dropdown/picker widget has been
built for this yet and shouldn't be, without Loopi asking for it
specifically - the slash command is intentionally the whole interim
solution.

### New destinations editor (officer-only)
A small dedicated window (own file, `DestinationEditor.lua`, same
"rendering layer only" split Board.lua uses against Queue.lua) or a new tab
folded into `Config.lua` - open question, see §7. Either way:
- Scrollable list of current `db.destinations` (label + category + a
  per-row remove "X").
- "Add destination" row (label text box + category dropdown + Add button)
  at the bottom.
- "Reset to built-in list" button.
- All of the above **hidden/disabled** unless
  `DHAir:HasPermission("edit_destinations")` - same
  `SetShown(HasPermission(...))` idiom `Board.lua`'s `clearAllBtn` already
  uses. Non-officers can still open the window to *view* the list read-only.
- Accessible via `/dhair destinations` and a button on the Board.

### Config.lua
- New "Guild officer rank" field (dropdown, populated from
  `GuildControlGetRankName`, see §3) - gated to `HasPermission("set_officer_threshold")`
  (Guild Master only).

### Commands.lua
- `/dhair destinations` - open the editor (or print the list if the UI
  file fails to load, matching the existing `Config_Open` fallback pattern).
- `/dhair dest <name>` - self-service set-by-partial-label-match, for
  players who never open the Board (mirrors `/dhair join`/`leave`).
- `/dhair officerrank <N>` - Guild-Master-only fallback for setting the
  threshold from chat instead of Config (mirrors `/dhair phrase`'s pattern
  of a slash-command alternative to the UI control).

## 6. File plan

| File | Status | Change |
|---|---|---|
| `Destinations.lua` | **done (M1)** | `DEFAULT_DESTINATIONS` static table, 33 flightpoint + 19 summonstone entries |
| `DestinationEditor.lua` | **done (M4)** | new file - standalone officer-gated list editor window (Loopi's call on §7 item 3), registered in `DH-Air.toc` |
| `Core.lua` | **done (M1+M2+M3)** | `destinations` default + seed; `edit_destinations` now real `IsGuildOfficer` (replaced the M2 interim leader/assist gate); `rankIndex`-aware roster cache; `officerRankThreshold` (default 3, Loopi's call); `set_officer_threshold` (rank 0 only); Loopidot override extended to cover both |
| `Queue.lua` | **done (M1+M2+M5)** | `destination` field, `GetDestination`, `ApplyDestination`, `SetMyDestination` (now broadcasts + re-triggers `TrySummonNext`), `SetDestinationList`, `ResetDestinationsToDefault`, `GetWarlockDestination`/`SetWarlockDestination` (M2.5); `SortedQueue` gained a `"dest"` sortKey (M5) |
| `Sync.lua` | **done (M2+M3)** | `SETDEST`, `DESTLIST` (gated), `DESTSYNCDATA` (ungated) messages; `SYNCDATA` queue encoding extended with a trailing `destId` field; `SETDEST` receiver re-triggers `TrySummonNext` (M2.5); `DESTLIST` receiver now verifies sender via real `IsGuildOfficer`, not the M2 interim `UnitHasAuthority` (M3) |
| `Summon.lua` | **done (M2.5)** | `QueueNextAvailable` requires + filters on `db.warlockDestination`; `RequestStartAutoSummon`/`RequestResumeAutoSummon` |
| `Board.lua` | **done (M2.5+M5)** | auto-summon button gray-out (M2.5); destination column (own-row dropdown via a shared `UIDropDownMenuTemplate` generator, others read-only text), "Whisper" quick action (`ChatFrame_SendTell`, shown for any online non-self row), "Destination" sort header, a "Destinations" footer button opening the M4 editor, default/min width grown 480/420 -> 580/520 (M5) |
| `Config.lua` | **done (M3)** | Guild-Master-only officer-rank dropdown, populated from `GuildControlGetRankName` |
| `Commands.lua` | **done (M2.5+M3+M4)** | `warlockdest`, `officerrank` (M3), `destinations` (open editor, chat-list fallback), `dest <name>` (self-service partial-match) subcommands |
| `DH-Air.toc` | **done** | registered `DestinationEditor.lua` |

## 7. Open questions for Loopi

1. ~~Seed data accuracy~~ **RESOLVED 2026-08-03:** pre-populate. Real
   content now lives in `Destinations.lua` (see §2's update note) - flight
   points are sourced, summoning stones still want an in-game/wiki sanity
   pass before M1 wires the file in.
2. ~~Officer threshold default~~ **RESOLVED 2026-08-03:** Loopi chose
   `rankIndex <= 3` (not the design doc's original `<= 4` guess, and not
   the fail-closed-empty alternative). Shipped as the `officerRankThreshold`
   default in Core.lua; Guild Master can still change it via Config or
   `/dhair officerrank <N>`.
3. ~~Editor UI placement~~ **RESOLVED 2026-08-03:** Loopi chose a
   standalone window (`DestinationEditor.lua`, matching Board's precedent)
   over a Config.lua tab. Built in M4.
4. ~~"Coordinate" scope~~ **RESOLVED (M5 build, 2026-08-03):** shipped as a
   plain `ChatFrame_SendTell` - opens a whisper addressed to the player, no
   prefilled text. Simplest option that satisfies the stated ask ("reach
   out ... directly"); revisit if Loopi wants templated text later.
5. **Locking** - can a player change destination after being claimed/mid-
   summon, or should it lock once a Warlock has claimed them? Still open -
   M5 shipped with NO lock (SetMyDestination has no claim-state check), so
   a player can currently change destination at any time, including
   mid-summon. Flagging as a real open question rather than deciding
   silently: revisit if this causes confusion in practice.
6. Should `SelfLeaveQueue`/`QueueReset` clear `destination` too (yes,
   trivially, since the whole entry is removed) - just confirming no
   separate "remember my last destination across sessions" ask exists.

## 8. Build sequence (checkpoints, mirrors v2.0's milestone structure)

1. ~~M1~~ **DONE 2026-08-03** - data model + self-service picker, local
   only. `Destinations.lua` wired into `Core.lua` (one-time seed from
   `DEFAULT_DESTINATIONS`, copied not aliased) and `DH-Air.toc`.
   `Queue.lua` gained `GetDestination`/`SetMyDestination` (self-only,
   requires already being queued, refuses unknown ids, `nil`/`""` clears).
   19 new assertions in `harness.lua`'s "Destinations (self-service
   picker)" section (seeding, lookup, set/clear/overwrite, refusal of
   unknown ids, isolation from other players' entries). Full suite: 212 +
   104 = 316 assertions, 0 failures. Still no sync (M2) - a destination set
   locally doesn't propagate to other clients yet, and Board.lua doesn't
   show it yet either (M5).
2. ~~M2~~ **DONE 2026-08-03** - sync. `SETDEST` (self-service, receiver
   requires `Name == sender`, no exceptions) and two SEPARATE full-list
   messages rather than the one originally sketched in §4: `DESTLIST`
   (broadcast, gated the same interim way as `edit_destinations` - a fresh
   claim of new state) and `DESTSYNCDATA` (whispered SYNCREQ reply,
   deliberately ungated - discovered mid-implementation that reusing
   `DESTLIST` for the late-joiner resync would have required the RESPONDER
   to be an officer, which breaks "any client can answer a late joiner's
   handshake" - same problem DH-Bavin's own Sync.lua already solved and
   documented for its RECIPIENT/EDITORS resync, see its header comment).
   `Core.lua` gained an interim `edit_destinations` permission case
   (leader/assist, same call site pattern as `set_phrase`'s own
   leader-to-officer transition plan - swaps to `IsGuildOfficer` in M3).
   `Queue.lua` gained `SetDestinationList`/`ResetDestinationsToDefault`
   (officer-gated, no editor UI yet - same "API before UI" precedent as
   DH-Bavin's `SetRecipient`/`SetEditors`). 9 new local assertions +
   3 new multi-client sections (SETDEST propagation/non-remote-settable,
   DESTLIST authority gating, late-joiner picks up the edited list). Full
   suite: 221 + 124 = 345 assertions, 0 failures.
3. ~~M2.5~~ **DONE 2026-08-03** - auto-summon destination matching (not
   part of the original 5-milestone plan; added when Loopi asked that
   auto-summon only pull players sharing the summoning Warlock's own
   destination). `db.warlockDestination` (new, local/unsynced operating
   state), `Summon.lua`'s `QueueNextAvailable` gained the mandatory filter,
   `RequestStartAutoSummon`/`RequestResumeAutoSummon` centralize the
   "refuse until a destination is picked" gate for both `Commands.lua` and
   `Board.lua`'s auto-summon button (Board grays the button out with a
   pointer to the new `/dhair warlockdest` command; the slash-command path
   prints the same hint as a chat message, since it has no button to
   disable - Loopi's explicit call on which UX to use where). Found and
   fixed a real product gap while testing: `SetMyDestination`/the `SETDEST`
   receiver never re-triggered `TrySummonNext`, so a live auto-summon loop
   wouldn't notice a newly-declared destination without an unrelated
   event nudging it. Also found and fixed a genuine race in the shared-
   queue test harness (not the product): a stale, not-yet-answered login
   `SYNCREQ` sitting unflushed across multiple `NewClient()` calls could
   have its reply processed *after* a deliberate officer edit, and since
   `DESTSYNCDATA` is (by design, see §4) an ungated full-replace, that
   stale reply could clobber the fresher edit - order-dependent on Lua's
   `pairs()` iteration, so it surfaced as a flaky failure. Fixed by
   flushing each client's own login handshake before testing edit-then-
   resync behavior in that test section; the underlying ungated-overwrite
   design itself is unchanged (same accepted trade-off `SYNCDATA` already
   carries) and is noted here as a known limitation rather than solved
   with versioning/timestamps, which felt like more machinery than this
   milestone called for. Full suite: 221 + 125 = 346 assertions, 0
   failures.
4. ~~M3~~ **DONE 2026-08-03** - officer permission model. `Core.lua` gained
   `rankIndex` capture in `UpdateGuildRosterCache`, real `IsGuildOfficer`
   (fails closed, carries the same Loopidot testing bypass as
   `UnitHasAuthority`), and `officerRankThreshold` (default 3 - Loopi's
   explicit call, see §7 item 2 - not the design doc's original `<= 4`
   guess). `HasPermission`'s `edit_destinations` case now calls
   `IsGuildOfficer` instead of the M2 interim `UnitHasAuthority` (leader/
   assist); new `set_officer_threshold` action is gated to rankIndex 0
   (Guild Master) only, deliberately not via `IsGuildOfficer` itself (an
   officer must not be able to widen their own gate). `Sync.lua`'s
   `DESTLIST` receiver now verifies the sender via `IsGuildOfficer` too,
   replacing its own `UnitHasAuthority` call. `Config.lua` gained a
   Guild-Master-only "Guild officer rank" dropdown (populated from
   `GuildControlGetRankName`/`GuildControlGetNumRanks`, hidden entirely -
   not just disabled - for anyone else). `Commands.lua` gained
   `/dhair officerrank [<N>]` (show current / Guild-Master-only set,
   mirrors `/dhair phrase`'s UI-alternative pattern). Updated 9 pre-existing
   assertions across both harnesses that previously granted
   `edit_destinations` via raid leader/assistant status (the old M2 interim
   gate) to instead grant it via guild rank, since that's now the actual
   real gate; added 13 new assertions covering the officer-rank boundary,
   `set_officer_threshold`'s rank-0-only gate, and the Loopidot override's
   coverage of `IsGuildOfficer`. Full suite: 237 + 125 = 362 assertions,
   0 failures. Still no editor UI (M4) or Board display (M5).
5. ~~M4~~ **DONE 2026-08-03** - destinations editor UI. New
   `DestinationEditor.lua` (standalone window, Loopi's call on §7 item 3):
   scrollable list of `db.destinations` (label, category tag, per-row
   remove "X"), an Add row (label edit box + flightpoint/summonstone
   category dropdown + Add button), and a "Reset to built-in list" button -
   all hidden entirely (not disabled) for non-officers via
   `HasPermission("edit_destinations")`, same `SetShown` idiom Board.lua's
   `clearAllBtn` uses; everyone else can still open the window and view the
   list read-only. New entries get an auto-generated id (slugified label,
   disambiguated with a numeric suffix on collision) - this file never
   assumes permission itself, every mutation still routes through Queue.lua's
   already-gated `SetDestinationList`/`ResetDestinationsToDefault`.
   Registered in `DH-Air.toc`. `Commands.lua` gained `/dhair destinations`
   (opens the editor, falls back to printing the list in chat if the UI
   file failed to load) and `/dhair dest <name>` (self-service partial-
   match against the list, mirrors `/dhair join`/`leave`).
6. ~~M5~~ **DONE 2026-08-03** - Board UI. New `COL_DEST_WIDTH` (110px)
   destination column and `COL_WHISPER_WIDTH` (56px) Whisper-action column
   in `Board.lua`, both following the existing right-to-left
   column-anchoring idiom `CreateRow` already used. Your own row gets a
   clickable button that opens ONE shared `UIDropDownMenuTemplate`
   generator (`frame.destDropdown`, toggled via `ToggleDropDownMenu`
   anchored to whichever row's button was clicked) rather than an
   oversized dropdown template embedded per pooled row - that template is
   taller than this Board's 22px rows. Everyone else's row shows a
   plain read-only label ("-" if undecided). New "Whisper" quick action
   next to Summon/Invite, shown for any online non-self row (reuses the
   existing `isOffline` check), calling `ChatFrame_SendTell` with no
   prefilled text (§7 item 4, resolved). New "Destination" sort header,
   backed by a new `"dest"` `sortKey` in `Queue.lua`'s `SortedQueue`
   (undecided sorts as `""`, same tiering rule as the existing name/wait
   keys - reorders within a tier only). New "Destinations" footer button
   opens the M4 editor. Frame default/min width grew 480/420 -> 580/520 to
   fit the new columns. Test coverage: 3 new assertions in `harness.lua`
   for the `"dest"` sortKey (tiering preserved, undecided sorts first
   ascending) - `SortedQueue` is a pure function so this is fully covered;
   Board.lua's actual rendering is not (see below). Full suite: 240 + 125 =
   365 assertions, 0 failures.

Board.lua/Config.lua/DestinationEditor.lua remain outside automated test
coverage (UI-template-heavy, same as the rest of that group) - "believed
correct, unconfirmed" until reviewed manually or tested in-game, same
standing note as every other Board/Config change in this project. This is
especially true for M5's dropdown/Whisper/column layout, which has never
been seen rendered in the actual game client.
