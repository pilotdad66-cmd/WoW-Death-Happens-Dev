# DH-Air v2.0 — Technical Design

Captures everything decided during brainstorming, as a concrete spec to build
against. This is a living document for the build phase, not a CurseForge-facing
doc — `DH-Air-Description.md` gets updated per-milestone as features actually ship.

---

## 1. Architecture recap

Two layers:

- **Guild directory (new)** — who's queued, who's registered as Summoner/Clicker,
  wait times. Broadcast over `GUILD` channel when not grouped, `RAID`/`PARTY`
  when grouped (prefer the tighter channel when both are possible — lower
  latency, less traffic). Works before any raid exists.
- **Raid claim engine (existing, ~unchanged)** — the v1 claim/tie-break/cast
  pipeline. Still inherently raid-scoped, since Ritual of Summoning requires it.
  v2 just changes *where its queue entries come from* (the directory, not a
  Warlock's local whisper list).

---

## 2. SavedVariables schema additions (`DHAirDB`)

```lua
db.roster = {
  summoners = {}, -- [normalizedName] = { lastSeen =  }
  clickers  = {}, -- same shape
}

-- Existing db.queue entries gain two fields:
db.queue[i] = {
  name           = "PlayerName",
  summoned       = false,
  role           = nil,  -- nil | "summoner" | "clicker" -- drives priority tier
  queuedElapsed  = 0,     -- seconds since queued, AS OF LAST SYNC RECEIPT
  -- queuedAt is NOT saved - it's derived locally as GetTime() - queuedElapsed
  -- the moment an entry is created or updated from a network message, then
  -- wait time for display is always (GetTime() - queuedAt) from then on.
  -- Same "transmit elapsed, not absolute time" pattern as the v1 claim TTL.
}

db.codePhrase  = "air"  -- configurable; who can change it is permission-gated (see §4)
db.autoPromote = true   -- promote registered Summoners to assistant automatically
db.autoPromoteGuildOnly = true -- scope auto-promote to guild members (matches guildOnly default)
```

`CopyDefaults` already handles additive schema changes for existing installs —
no migration code needed.

---

## 3. Message protocol additions (`Sync.lua`)

**Channel selection** (replaces the current RAID-or-PARTY-or-nothing logic):
```
IsInRaid() -> "RAID"
IsInGroup() -> "PARTY"
else -> "GUILD" -- NEW: works with no group at all
```

**New message types**, same `TYPE|payload` convention as v1:

| Message | Payload | Sent by | Verified how |
|---|---|---|---|
| `REGISTER` | `role\|Name` | anyone, on role checkbox | none needed (self-declarative) |
| `UNREGISTER` | `role\|Name` | anyone, on role uncheck | none needed |
| `REMOVE` | `Name` | self, or leader/assist | receiver checks `HasPermission` unless `Name == sender` |
| `CLEARALL` | *(none)* | leader/assist only | receiver checks `HasPermission("clear_all")` |
| `SETPHRASE` | `newPhrase` | leader (2.0/2.1), officer (2.2) | receiver checks `HasPermission("set_phrase")` |

Existing `ADD` / `CLAIM` / `RELEASE` / `SUMMONED` / `RESET` / `SYNCREQ` /
`SYNCDATA` carry over unchanged in *mechanism*; `SYNCDATA`'s per-entry encoding
extends from `Name:0/1` to `Name:0/1:role:elapsed` to carry the new fields to
late joiners.

**Trust model, reaffirmed:** every permission-gated message is verified by the
*receiver*, against the receiver's own local knowledge (`UnitIsGroupLeader`,
`UnitIsGroupAssistant`, guild roster membership) — never by trusting a claim
embedded in the message itself. This was already the plan for `REMOVE`/`CLEARALL`;
`SETPHRASE` and auto-promote reuse the identical check.

---

## 4. Permission model

Single entry point, extensible for 2.2's guild-officer ranks without touching
call sites:

```lua
function DHAir:HasPermission(action)
    if action == "remove_any" or action == "clear_all" or action == "set_phrase" then
        return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
        -- 2.2: extend with a guild-rank check here, same function, same call sites
    elseif action == "invite" then
        return (not IsInGroup()) or UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
    end
    return false
end
```

---

## 5. Queue ordering (pure function, no UI dependency)
```
tier 1: your own row, if you're in the queue (always rank 0)
tier 2: role ~= nil (Summoner or Clicker), sorted by active sort column
tier 3: everyone else, sorted by active sort column
```

Sort columns: `name` (locale compare) and `wait` (the live-computed
`GetTime() - queuedAt` value, not the rounded display string — ties in the
display never produce ties in the actual sort).

---

## 6. Invite/Summon button logic (per queue row)
```
if entry is in my raid/party -> "Summon" (always shown; enabled if I'm a registered Summoner)
else -> "Invite" if HasPermission("invite"), else plain status text "not in raid"
```

---

## 7. Auto-promote & leader succession

Triggers:
- `PARTY_LEADER_CHANGED` → am I leader now? If so, sweep the *entire* current
  roster once (catches anyone who should've been promoted before I became
  leader).
- `GROUP_ROSTER_UPDATE` → if I'm already leader, check new arrivals only.

Promotion criteria (both must hold): registered Summoner, AND
(`not db.autoPromoteGuildOnly` OR `IsGuildMember(name)`).

**Rescue handoff** (best-effort, not guaranteed — only works if Blizzard's
auto-succession happens to land on a DH-Air client): on becoming leader, if I'm
not an intended Summoner-in-charge, pick the best candidate and
`PromoteToLeader()` them:
```
rank candidates by:
1. actively running auto-summon (active=true, paused=false) - highest priority
2. raid join order this session (lower raid roster index = earlier join)
```

No persistence across raid instances — "join order" resets every time the raid
re-forms, matching how Air Service sessions naturally end (raid disbands once
everyone's summoned).

---

## 8. File plan

| File | Status | Change |
|---|---|---|
| `Roster.lua` | **new** | Registration broadcast/receive, staleness pruning, role state |
| `Board.lua` | **new** | The window: resizable, sortable, action bar, per-row buttons |
| `Sync.lua` | extended | GUILD channel, new message types, `SYNCDATA` payload extended |
| `Queue.lua` | extended | `role` + `queuedElapsed` fields, tiered sort function |
| `Summon.lua` | extended | Manual summon entry point (reuses existing claim pipeline) |
| `Core.lua` | extended | New defaults, `HasPermission`, `PARTY_LEADER_CHANGED` handling |
| `Commands.lua` | extended | New slash commands (`/dhair phrase`, etc.) |
| `Minimap.lua` | changed | Left-click opens Board instead of toggling auto-summon |

---

## 9. Build sequence (checkpoints)

1. Data model + Roster/registration layer — headlessly testable
2. Self-service queue actions + permission model — headlessly testable
3. Board UI — **needs your in-game verification**, same as the minimap fixes
4. Manual summon + auto-promote/succession
5. Raid-chat code phrase + minimap left-click repurposing

---

## 10. Open items carried forward, not yet needed

- 2.2 guild-officer-rank permissions (deferred by design)
- Non-guild-member-in-queue offline detection gap (accepted as rare, deferred)
