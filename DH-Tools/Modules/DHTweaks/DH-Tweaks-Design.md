# DH-Tweaks - design notes
created: 2026-10-28 (Loopi)

## Purpose
A small DH-Tools module that collects quality-of-life changes to the
default UI. Core.lua is the registry; each tweak lives in its own file.
Each tweak is designed with Loopi before it is built (README section 14).

## Decisions so far (2026-10-28, Loopi)
- Module key `tweaks`, display name "DH-Tweaks" (matches DH-Air / DH-Store
  naming), slash command `/dhtweaks` (debug output only for now).
- Default ON. `default = true` applies to anyone with no saved toggle for
  this key, which includes EXISTING members after they update, not only
  fresh installs (Core.lua's IsModuleEnabled falls back to the default).
  Fine here because each tweak is invisible unless it applies to the
  player; revisit if a future tweak is visible to everyone.
- Own SavedVariables sub-table `DHToolsDB.tweaks` (per character, like
  Macros); no standalone-optionality.
- One .toc line per file; new files are not shipped until listed in the .toc.
- Hooks can't be removed: install once, check `DHTweaks.IsEnabled()` inside.

## Tweak 1: Guild Invite on the right-click menu (GuildInvite.lua, built)
Right-click a player's name in chat, or a player/target/party/raid unit,
and choose "Guild Invite". Anyone Veteran or better in Death Happens can.

Checked in-game 2026-10-28 (Loopi):
- The stock Classic Era menu has NO guild invite entry.
- `Menu and Menu.ModifyMenu` is present, so the tagged-menu API is used
  (no taint of Blizzard's own menus). No legacy UnitPopup fallback is
  written; if a client ever lacks Menu.ModifyMenu the tweak just does
  nothing (`ns.guildInviteUnavailable`).

As built:
- Hooks MENU_UNIT_FRIEND (chat names), _PLAYER, _TARGET, _PARTY and
  _RAID_PLAYER. Friends-list and guild-roster menus are deliberately left
  out (roster people are already guildmates). The tag names are
  "MENU_UNIT_" + the old UnitPopup `which` value; FRIEND for chat names
  is the one least confirmed - if an entry is missing in a menu, run
  `/dhtweaks debug` and open that menu: it prints the tag and the
  contextData fields.
- Entry shown only when `CanGuildInvite()` is true (guild rank
  permission decides; no hard-coded rank). Falls back to the global
  CanGuildInvite/GuildInvite if C_GuildInfo lacks them.
- Click calls `C_GuildInfo.Invite(name)` (or `GuildInvite`) immediately -
  no confirm popup; the game prints its own invite/error messages.
- Hidden for: your own name, non-players, the other faction, and a unit
  that is visibly already in a guild. Chat names have no unit, so they
  always show.
- Name gets `-Realm` only when the realm differs from your own.
- Every menu callback runs under pcall so a bug here can never stop
  Blizzard's menu opening; the error is printed to chat instead.
- NO guild-name check (reverses the earlier plan to follow
  `ns.IsInTargetGuild()`): CanGuildInvite already means "you can invite
  to the guild you are in", so nothing needs hard-coding and nothing goes
  in HARDCODED.md.
- Tests: tests\run-tests.ps1 (mocked API, 35 checks). It cannot cover how
  the real client hands contextData to the generator - in-game only.

## Open questions
- Per-tweak toggles on a Config page once there are two or more tweaks.
- Friends-list menu: add MENU_UNIT_FRIEND_OFFLINE-style tags? (Offline
  players cannot be invited, so probably never.)
