# DH-Tools

**Version 2.0.7** | Author: **Loopi** | For: *Death Happens* Hardcore guild

---

## Summary

DH-Tools is the Death Happens guild's all-in-one utility addon: instead of
installing a separate addon for every guild tool, enable or disable each
one individually from a single config window.

- **Module Toggle Framework** — the Tools page (`/dht config`) lists every
  available module with a one-line description and an on/off checkbox.
  Turn on only what you need; more modules will be added here over time.
- **Mob Marker** — automatically marks specific mobs with a raid-target
  icon on mouseover, plus a configurable Ctrl+click hotkey to mark/unmark
  whatever's under your cursor on demand. Fully customizable icon
  assignments per mob and hotkey modifier/mouse button, via `/mm config`.
- **Shared Quests** — see which group and elite quests your online
  guildmates currently have, so you can find people to group up with.
  Broadcasts your own quest log over guild addon messages (Individual,
  Group, Elite, and Class categories, each independently toggleable, and
  entirely opt-in), and shows everyone else's in a sortable, filterable
  window (`/dhq`) — filter to online-only, sort by player, quest, or
  character level, and invite a matching player straight from the row.
- **Bavin Points** — shows a donation-priority points value in item
  tooltips for ~7,000 items, editable live by the recipient/editors
  (`/dhb points`). Post `?` followed by an item link in guild chat and
  an online guildmate's client automatically replies with Bavin's info
  on it — exactly one reply per item, fully automatic. Recipient/editor
  access is automatically revoked the moment someone leaves the guild.
- **DH-Air** — Warlock/guild summon-coordination: a shared summon
  queue, auto-invite on whisper or a raid-chat code phrase, and
  auto-summon in queue order. Bundled directly into DH-Tools since
  v2.0.0 (previously a separate DH-Air addon) — enable or disable it
  from the Tools page like any other module.
- **Macros** — generate ready-to-use macros straight into your macro
  book (general or character-specific) from a Class → Spec picker, or
  copy the text yourself to paste in manually. Confirms before
  overwriting an existing macro. `/dhm` opens the picker.
- **DH-Air Submenu** — quick access to DH-Air's Board and Config
  windows, its destination picker (grouped by Flight Points/continent and
  Dungeon Stones, plus an officer-gated Destination Config shortcut), and
  one-click toggles for Join Queue, Am Summoner, Am Clicker, Auto Invite,
  and Auto Summons, color-coded green/red for current state — all without
  leaving the minimap menu.
- **Minimap Button** — left-click opens DH-Tools' own Config window
  directly; right-click opens the full menu (Mob Marker, Quests, Bavin
  Points, DH-Danger, DH-Air, Macros, Settings, About), with expandable
  submenus for anything with more than one option.

DH-Tools does **not** replace any of its modules' individual settings or
judgment calls — it's a shared shell that lets you pick which guild tools
you actually want running, all managed from one place.

---

## Changelog

### 2.0.7
- **Fixed: guild-chat item lookup could get multiple replies from
  different guildmates for one item.** This showed up mainly on items
  nobody's client had seen before - the retry that waits for that data
  to load was missing the same random delay the normal reply already
  uses to avoid collisions. Still exactly one reply per item.

### 2.0.6
- **New: guild-chat item lookup for Bavin Points.** Post `?` followed by
  an item link in guild chat, and whichever online guildmate's client
  answers first replies automatically with Bavin's info on it — a
  points/detail line if it's on file, a "no data" note if not, or a
  "cannot be traded" note for Bind on Pickup or Quest items. Exactly one
  reply per item, no click required from the responder; if nobody online
  has DH-Bavin enabled, you'll instead get a note asking you to install
  it.
- **Bavin Points data refreshed** from an updated spreadsheet - 7,015
  items now have a points value on file (6,931 of them also matched to
  a specific item ID).

### 2.0.5
- **DH-Danger: rows can now be excluded from detection without deleting
  them.** A handful of curated entries (the Wetlands dragonkin rares,
  and a duplicate Rogue Black Drake row) are now marked excluded rather
  than removed, so the underlying data stays on record but the addon
  treats them as if they don't exist.
- **DH-Danger: separate Gray and Green filters for the zone-entry
  message.** The old "ignore gray mobs when zoning in" option is now
  two independent checkboxes - "Exclude Gray / Green Threats from the
  Zone In Message" - so you can hide either color on its own. Gray
  stays on by default; Green defaults off.
- **DH-Danger: the zone-entry header now shows both counts.** It now
  reads "N Curated Threats, M Shown" - N is everything curated for the
  zone regardless of your filters, M is how many are actually listed
  below it.
- **DH-Danger: new configurable Repeat Alert Delay.** A slider (0-300s,
  30s steps) controls how soon the same mob type can alert again,
  independent of the existing per-creature cooldown - useful when
  several mobs sharing a name (e.g. a roaming pack) were alerting back
  to back. Set it to 0 to get the old behavior back.
- **DH-Air: reverted the Booty Bay World Buff Mode summon-skip.** The
  recent change meant to skip queuing a summon for someone already in
  Booty Bay never actually worked in practice, so whispering for a
  summon now always invites and queues, same as before that change was
  introduced.

### 2.0.4
- **DH-Air: World Buff Mode no longer re-queues a summon for someone
  already in Booty Bay.** With World Buff Mode on, a whisper- or
  code-phrase-triggered invite still happens immediately, but the
  summon-queue join is now held just long enough to check whether the
  requester already landed in Booty Bay - if so, they're invited but
  skipped from the summon queue entirely, since no summon is needed.
  Anyone anywhere else (including Stranglethorn Vale generally) is
  queued exactly as before.

### 2.0.3
- **Modules now start switched off on a fresh install.** A new install
  begins with only Mob Marker and Bavin Points enabled - Quests,
  DH-Danger, DH-Air and Macros are opt-in from the Tools page
  (`/dht config`). **If you already have DH-Tools, nothing changes:**
  your own on/off choices are left exactly as you set them.
- **DH-Danger: "ignore gray mobs when zoning in" now defaults on** for
  new installs, so the zone-entry warning is quieter out of the box.
  `/dhdanger zone` still lists everything regardless of the setting.
- **Minimap menu popup rebuilt.** The mouseover popup is now its own
  small frame instead of borrowing the game's tooltip, fixing the
  shrinking font and the popup occasionally appearing in odd places.
  The menu also sits slightly closer to the minimap.

### 2.0.2
- **New: version-mismatch notice.** On login, if a guildmate nearby is
  running a different DH-Tools version than you, you'll get a one-time
  chat message saying so (pointing you to CurseForge/GitHub if you're
  the one behind) - makes it easier to notice you're due for an update
  without having to check manually.
- **"Bavin Wants" renamed to "Bavin Points"** in the minimap menu, to
  match the feature's name everywhere else in the addon.
- DH-Danger's curated dataset: added Teremus the Devourer (Blasted
  Lands, elite Dragonkin).

### 2.0.1
- **New: Macros module.** Generate ready-to-use macros directly into
  your macro book (general or character-specific) from a Class → Spec
  picker, or just copy the text yourself (`/dhm`). Confirms before
  overwriting an existing macro. Starter catalog covers a handful of
  class-general and per-spec macros, growing over time.
- **Fixed: clicking a chat-linked item's Bavin Points tooltip only
  worked once per session.** After the first clicked link, every later
  click (on any item) silently showed no Points line until you
  relogged. Now works every time.
- **New: "show item tooltips on chat-link mouseover" option** (Bavin
  Config) for anyone who'd rather preview an item on hover instead of
  clicking every link.
- **Fixed:** DH-Danger's Alert Settings section was clipping the first
  character or two of its text.
- About page now credits Deves (Major DH-Air Contributor) and bug
  testers Yuri and Cyndrith.

### 2.0.0
- **Major: DH-Air is now a bundled module ("Air Service"), not a separate
  addon.** Warlock/guild summon-coordination — the shared summon queue,
  auto-invite on whisper or raid-chat code phrase, and auto-summon in
  queue order — is built directly into DH-Tools. Enable or disable it
  from the Tools page like Mob Marker, Quests, or Bavin. If you already
  had DH-Air installed separately, you can remove it — everything it did
  is here now, under a fresh, empty save (accounts don't carry over
  automatically between the old standalone addon and this bundled
  version; you'll need to re-register as a Summoner/Clicker and any
  officer will need to re-set the destination list).
- The minimap's DH-Air submenu, Board, Config, and Destination Config
  windows all work exactly as before — same buttons, same shortcuts.
- **Fixed:** the minimap's "Auto Invite On/Off" quick-toggle had been
  silently doing nothing since a 2026-08-15 DH-Air update split that
  setting into two - it's now wired to the right one.
- DH-Air's account-wide admin-override mechanism was consolidated into
  DH-Tools' own (no functional change for ordinary members).
- **Fixed:** a handful of items showed "-2146826273" in place of the
  normal Bavin Points detail line in tooltips - a broken formula in the
  source spreadsheet, not an addon bug. Refreshed points database also
  adds a few previously-missing items and corrects a couple of point
  values.
- This is a MAJOR version bump (not 1.4.0) because of the merge's scope -
  everyone should update together.

### 1.3.0
- **New: "Request World Buff Summons" on the minimap left-click menu**
  (2nd item). Works together with DH-Air's new World Buff Mode - one
  click whispers whichever available Summoner has been running World
  Buff Mode longest, and you'll be invited, queued, and headed to Booty
  Bay automatically. Greyed out with an explanation if DH-Air isn't
  installed or nobody's currently available.
- **Not yet tested in a live raid** - needs DH-Air v2.2.0 or later.

### 1.2.2
- **New: minimap left-click quick-actions menu.** Left-clicking the
  minimap button now opens a flat 5-item menu instead of jumping
  straight to Config: Clear All Marker Icons, Show Zone Dangers, Show
  Shared Quests, Open Summons Board, and DH-Tools Settings. Right-click
  is unchanged.
- **Shared Quests: new "Show Quests in Common First" option** on the
  Board — sorts quests you also have to the top of the list, separate
  from the existing "Only Show Quests in Common" filter (that one hides
  non-common rows; this one just reorders).
- **DH-Danger's curated dangerous-mob dataset expanded from 342 to 640
  entries** — now covers every rare and rare elite guild-wide, plus
  elites and roaming dangers in the level 1–20 zones, all keyed by
  their real in-game ID.

### 1.2.1
- **New: DH-Danger zone-entry warning.** Entering a zone now lists any
  curated dangerous rares/rare elites there in chat, with names
  color-coded by the standard level-difficulty scale (red/orange/
  yellow/green/gray) relative to your own character level - same
  color logic as mob nameplates, gray threshold adjusted for your level
  bracket. On by default per character; toggle with `/dhdanger zonewarn
  on|off`, or check any zone on demand with `/dhdanger zone`.
- Curated dataset refreshed (342 entries), plus a new Creature Type
  field used by the warning above.
- DH-Danger is still early - not yet a toggleable module on the Tools
  page - so this is a first look at it in the wild. Report anything odd.

### 1.2.0

> **Everyone needs this version.** Bavin's guild sync protocol changed in a
> way that isn't backwards-compatible: a 1.2.0 client and a 1.1.4 client
> exchange **no** Bavin data at all — no recipient, no editors, no points,
> no want-list. Nothing breaks and no errors appear, they simply stop
> hearing each other, so the whole guild should update together.

- **Fixed: a Lua error every time Mob Marker tried to mark something in a
  raid.** The raid-group permission check called two functions that don't
  exist in Classic Era, so it failed on every attempt. Party groups and
  solo play were never affected, which is why it went unnoticed.
- **Bavin Points tooltips are now color-coded by value**, on the game's own
  item-quality scale: white up to 1 point, green up to 10, blue up to 100,
  purple above that. **Zero or negative points show red.** An item with no
  usable points value shows grey, so "we don't have a number for this"
  can't be misread as "this is worth almost nothing".
- **The Points Editor can now edit an item's wording**, not just its point
  value and itemID — useful where the imported text is awkward or wrong.
  The add-new-item form takes wording too.
- **DH-Danger appears as "coming soon"** in the Config window, the Tools
  page, and the minimap menu. There's nothing to configure yet; it's
  there so you can see what's being worked on.

### 1.1.4
- **"Bavin Wants" mail button repositioned again**, this time anchored to
  the mailbox's own Cancel button so it reliably sits directly beneath
  the Send Mail/Cancel buttons at the bottom-right, regardless of screen
  resolution or UI scale.
- **Tools page row spacing increased** (checkbox rows were crowding the
  description text below them).

### 1.1.3
- **"Bavin Wants" mail button moved.** It now sits at the bottom-right of
  the mailbox window instead of above it - the old spot could blend into
  the game world behind it and was easy to miss, especially with certain
  other mail addons installed.
- **Fixed: the About page (`/dht config` → About) was stuck showing
  "Addon Version: 1.0"** no matter what actually shipped. It now always
  shows the real installed version.

### 1.1.2
- **Bavin Points editor: itemID is now editable per item**, so a wrong
  itemID from the original import can be corrected directly (`/dhb
  points` - search a name, edit the itemID box, Save).
- **Bavin Points editor: new "Add a new item" form** to add an item
  outright (name, itemID, points) instead of only being able to edit an
  item that was already in the shipped list.
- **Bavin recipient/editor permissions tightened.** Only Bavin and Loopi
  can set who the current mail recipient is; only guild officers (rank 3
  or higher) and Loopi can set who else can edit the priority list and
  points.
- **Mail window button renamed "Bavin Wants"**, now fills the recipient's
  full name (with realm) and also auto-attaches every bag item on the
  priority list to the open mail in one click, not just the recipient
  field.
- **Bavin Points editor: fixed the itemID/points column headers not
  lining up with the values below them**, and added an explicit Save
  button so it's clear how to commit an edit.

### 1.1.1
- **New: Bavin Points.** Item tooltips show a "Bavin Points" donation-
  priority value for ~7,000 items. The recipient/editors can override any
  item's value live (`/dhb points`), and it updates in tooltips
  immediately for everyone.
- **New: Priority list rebuilt around a searchable editor.** `/dhb priority`
  opens a type-to-filter Add/Remove window (same style as the Points
  editor) instead of the old shift-click-a-link-only workflow. The list is
  now keyed by item name instead of item ID, matching Bavin Points and
  avoiding a mismatch on items that have several differently-valued
  random-suffix versions sharing one ID.
- **New: bag highlighting and a mailbox helper.** Any bag item on the
  priority list gets a gold border, guild-wide, for everyone (informational
  only, not tied to edit permission). While the mailbox is open, a "Fill
  Recipient" button fills in the current recipient's name, and matching
  items get a small mail icon you can click to attach them directly. **This
  is the newest, least-tested part of this release** - the bag-highlight
  and mailbox hooks haven't been through a full in-game pass yet on every
  setup. If bag highlighting or the mailbox button doesn't appear, please
  report it rather than assume it's just you.
- **Fixed: departed-member access.** A recipient or editor who leaves the
  guild now automatically loses list-edit access the moment the roster
  updates, instead of only on the next time the list happens to be
  re-saved.
- **Fixed: the priority list could be lost on relog.** It used to live in
  memory only, rebuilt each login purely from other online guildmates'
  broadcasts - if nobody else happened to be online, it came back empty.
  It's now saved locally like everything else.
- **Fixed: the DH-Air submenu's "Set Destination" → Flight Points menu**
  never opened (nested one level deeper than it should have been) -
  matches the fix in DH-Air 2.1.1; update both together.

### 1.1 (first published release, beta)
- **Module Toggle Framework** — Tools page (`/dht config`) lists every
  module with a one-line description and an on/off checkbox; Mob Marker,
  Shared Quests, and Bavin Wants all correctly stop responding to events
  when turned off (not just their own slash commands).
- **Mob Marker** — auto-marks specific mobs with a raid-target icon on
  mouseover or nameplate sighting, plus a configurable Ctrl+click hotkey.
- **Shared Quests** — opt-in guild quest-sharing and lookup window.
- **Bavin Wants** — guild-wide want-list, viewable by everyone, editable
  by the guild leader or a designated editor (with a testing override
  currently enabled — see in-game notes).
- **Minimap menu** — real expandable-submenu dropdown (left-click: Config,
  right-click: full menu) covering every module above plus a DH-Air
  shortcut submenu.
- **DH-Air integration** — status indicator on the Tools page, plus the
  minimap's DH-Air submenu described above, for the separately-installed
  DH-Air addon.

This is the first CurseForge release and is tagged **beta** — the module
framework, Bavin Wants, and the minimap menu have not yet been verified
against a live multi-user guild session (see in-game notes / report issues
to Loopi).
