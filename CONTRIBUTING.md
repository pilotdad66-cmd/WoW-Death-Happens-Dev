# Contributing to DH-Tools

Thanks for offering to help build DH-Tools. This doc assumes you know
your way around GitHub already (branches, commits, pull requests) - it's
about how *this* project specifically wants to work, and a short list of
places in the code where a small, well-meaning change can go wrong in a
way that isn't obvious from reading it. Please read the second half even
if you skim the first.

## What's in this repo

This repo holds the addon source (`DH-Tools/`) and its per-module design
docs (`*-Design.md`, one per module, explaining why a feature works the
way it does) - no project-management files, no history beyond the code
itself. That's deliberate, not an oversight - don't read anything into
what's absent.

`DH-Tools/Modules/` is where almost everything lives: each guild feature
(Air Service, Bavin, Danger, Quests, Macros, Mob Marker) is its own
subfolder there. If you're fixing or adding to one feature, you should
only need to touch its own subfolder plus, occasionally, `Core.lua` or
`Sync.lua` if the change is protocol-level (see below - that's the part
to be careful with).

## Workflow

1. **Branch, don't push to `main` directly.** One branch per change,
   named however makes sense to you. This isn't currently enforced by
   GitHub on this repo (it's a private repo on the free plan, which
   doesn't support that) - it's enforced by us agreeing to do it this
   way. Treat it as a hard rule anyway.
2. **Test your own change yourself first**, the simple way: copy (or
   symlink) your edited module folder straight into your own WoW
   `AddOns` folder and play with it. You don't need any of our build
   scripts for this - those are for building distributable zips, not
   for your own iteration, and they aren't part of what you can see in
   this repo anyway.
3. **Open a PR against `main`** when you think it's ready. Say in the
   description what you changed, why, and how you tested it. If your
   change touches anything in the "ask first" list below, say so
   explicitly, even if you think you've handled it correctly.
4. **Review takes real time - minutes to days, not instant.** Loopi (and
   an AI assistant that reviews code and can run this project's test
   suites) will read the diff, check it against how the surrounding code
   already works, and run whatever automated tests cover the module you
   touched. For anything touching multiplayer sync, Loopi still has to
   test it live in-game before it merges, no matter how it looks on
   paper - that's not a reflection on your code, it's the same bar his
   own changes have to clear.
5. **Say what you're working on** (in Discord, or wherever the guild
   already coordinates) before you start on a specific module, so you
   don't end up redoing work that collides with something already in
   progress.

## Please ask first before touching these

These aren't style preferences - each one is a specific way a small,
reasonable-looking change has previously caused (or could cause) a
guildmate to get bad information or a silent failure in an actual
Hardcore run. None of this means "don't work on these features" - it
means open a conversation before you write the code, not after.

**1. The wire message formats in any `Sync.lua`.**
Air, Bavin, Danger, and Quests all talk to each other's game clients over
addon messages shaped like `TYPE|payload` (you'll see them listed at the
top of each `Sync.lua`). Adding a brand new message type is usually
fine. Changing an *existing* message's shape, field order, or meaning
is the single most dangerous kind of change in this codebase: it doesn't
crash or error, it silently produces wrong or corrupted data on every
client that receives it, and everyone has different code running until
they all update. There's a real incident behind this rule (`PREFIX`'s
version suffix exists because of it). If your change needs to alter an
existing message's format, stop and talk to Chris before writing code -
it needs a coordinated version bump, not just a code change.

**2. Anything checking who's "allowed" to do something.**
Actions like clearing the shared queue, resetting the roster, or setting
someone else's destination are only permitted after the *receiving*
client independently checks the sender's actual raid-leader/assistant or
guild-officer status - never by trusting a flag the sender's own message
claims about itself. If you're touching one of these, keep it that way;
don't simplify it into trusting what the message says about its sender.

**3. DH-Air's claim/queue consistency logic.**
The queue is deliberately a loose, "eventually consistent" system, not a
strict lock - minor reordering across different clients is treated as a
cosmetic non-issue. The one thing it guarantees on purpose is that two
Warlocks never both spend a Soul Shard summoning the same person. If
you're refactoring the claim/expiry/tie-break logic, know that tradeoff
first - "cleaning it up" without it in mind is how that guarantee
quietly breaks.

**4. DH-Air's leader auto-promotion.**
This only ever runs from the current raid leader's own game client - not
a design choice, a hard constraint of the WoW API. It's also
deliberately conservative: it only acts on Blizzard's blind, random
leader reassignment (e.g. the old leader disconnected), and never
overrides a leadership change a human just made on purpose. Don't make
it "more proactive" - that's exactly the failure mode it's designed to
avoid.

**5. DH-Danger's core judgment calls.**
DH-Danger exists because, in Hardcore, a missed warning is permanent and
a false alarm is mild annoyance - that asymmetry is why it's built the
way it is. Two rules follow directly from it: never let it guess or
infer a value it doesn't actually have (an unknown mob level stays
unknown - it never gets estimated to fill a gap), and it must warn
loudly if the player doesn't have nameplates enabled, since detection
silently doesn't work at all without them. An addon that looks like it's
protecting someone while actually doing nothing is worse than one that
admits it can't help.

**6. DH-Bavin's ledger visibility.**
The points/credits ledger is deliberately replicated only among the
collector and designated officers, not broadcast guild-wide - regular
members only ever see their own balance. This is intentional privacy
design, not something to "simplify" into a shared broadcast.

**7. Hardcoded guild/character/realm names.**
If your change needs to hardcode a specific guild, character, or realm
name (not a general constant), say so plainly in your PR description.
There's a tracking file for this on our side that isn't part of what you
can see here, so we need to know about it explicitly rather than finding
it in the diff.

## Questions

If anything here is unclear, or you're not sure whether a change you
want to make falls into one of the categories above, ask before you
start rather than after you've written the code - it's a much shorter
conversation that way.
