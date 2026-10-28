# DH-Tweaks - design notes
created: 2026-10-28 (Loopi)

## Purpose
A small DH-Tools module that collects quality-of-life changes to the
default UI. Scaffolded as registration only; each tweak is designed with
Loopi before it is built (README section 14).

## Decisions so far (2026-10-28, Loopi)
- Module key `tweaks`, display name "DH-Tweaks", slash command none yet.
- Default ON. `default = true` applies to anyone with no saved toggle for
  this key, which includes EXISTING members after they update, not only
  fresh installs (Core.lua's IsModuleEnabled falls back to the default).
  Fine here because each tweak is invisible unless it applies to the
  player; revisit if a future tweak is visible to everyone.
- Own SavedVariables sub-table `DHToolsDB.tweaks` (per character, like
  Macros); no standalone-optionality.
- One .toc line per file; new files are not shipped until listed in the .toc.

## Tweak 1 (planned, not built): Guild Invite on the right-click menu
Goal: right-click a player's name in chat (or a player unit) and choose
"Guild Invite". Anyone Veteran or better in Death Happens can invite.

Plan:
- Call `GuildInvite(name)` from the menu click (not a protected action).
- Show the entry only when `CanGuildInvite()` is true, so the guild's own
  rank permission decides who sees it. No hard-coded rank number.
- Hide it for the player's own name.
- Off-guild / wrong-guild characters: follow the `ns.IsInTargetGuild()`
  pattern (k-0019) rather than treating "in some guild" as "in DH".

Verify in-game BEFORE building (Loopi to check, or build a throwaway probe):
1. Does the stock Classic Era menu already offer a guild invite entry
   when the player has permission? If yes, nothing to build.
2. Which menu system this client (Interface 11509) uses - the newer
   Menu.ModifyMenu one or the older UnitPopup one - so the hook goes in
   the safe place. Detect at runtime; prefer the newer one if present
   (older UnitPopup table edits can taint).
3. Which menu types carry chat names vs target frames vs the guild
   roster, so the entry shows up in each.

## Open questions
- Per-tweak toggles on a Config page once there are two or more tweaks
  (not needed while there is only one).
- Whether `/dhu` is worth registering (nothing to run yet).
