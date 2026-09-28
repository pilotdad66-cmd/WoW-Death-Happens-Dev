# DH-Store - Design (skeleton, 2026-09-28)

## Concept
A guild-only, buyout-only item store, modeled visually on the in-game
Auction House's Browse pane but functionally simpler (no bids, no
listing duration, no undercutting). Bavin or a designated Store officer
lists items at a gold price and a Bavin Credits price; the credit price
is discounted by the buyer's own reputation tier (see
DH-Bavin-Credits-Design.md's Points/tier system, which this module
reads but does not own). "Buying" cannot move gold or items
automatically - no WoW addon can - so it generates a mail to the Store
officer with (buyer, item, price) for manual fulfillment: item
delivery via mail, and payment either gold (CoD) or a Credits
deduction the addon still applies automatically the same way the
existing outgoing credit-debit flow does today.

Full context and everything already decided (packaging, dependency
model, fresh-install defaults, access points) is in
claude\DH-Store\PROFILE.md - not repeated here.

## Open design questions (resolve before Milestone 1 - README section 14)
1. **BUILT 2026-09-28 (Chris sign-off same day) - Core.lua inter-
   module dependency mechanism.** `RegisterModule`'s `def` now takes
   an optional `requires = "otherKey"` (single key). Cascade logic
   lives centrally in `SetModuleEnabled` (Core.lua) - enabling a
   dependent auto-enables its requirement first (recursive, so a
   chain would work even though nothing uses one yet); disabling a
   requirement auto-disables every enabled module that requires it.
   Both `/dht on|off` and the Tools config page route through this one
   function, so the cascade applies uniformly everywhere. Boot-time
   self-heal in `ActivateEnabledModules` forces a dependent off (and
   skips its `OnEnable`) if its saved "on" flag doesn't match an
   actually-enabled requirement (stale SavedVariables, an old
   profile). Tools page: a gated checkbox greys out with
   `(requires DH-Bavin)` (Chris's wording choice, 2026-09-28),
   re-evaluated live via a new `UpdateDependentGating()` called from
   `panel.Refresh()` and after every row's own click - no close/reopen
   needed to see a cascade reflected. See claude\DH-Tools\PROFILE.md's
   Module framework contract for the full `def` shape. Covered by 8
   new harness.lua checks (Group A2); full suite 52/52, syntax-clean.
   Not yet in-game tested - nothing exercises this path live until
   DH-Store's own module file registers with `requires = "bavin"`.
   This was a separate blocker from the Credits-system sequencing
   question (#9, resolved) - it gated Store's very existence as a
   toggleable module, not just its checkout feature.
2. **Catalog sync wire format** - mirrors DH-Bavin's priority-list
   ITEM/ITEMGONE broadcast + SYNCREQ/SYNCDATA pattern, but needs its
   own message prefix/payload shape (item, quantity, gold price, base
   credit price - NOT per-tier prices, those are computed client-side)
   and its own permission gate (who can add/edit/remove store listings
   - presumably the same recipient/editor-style guild-roster-verified
   model DH-Bavin already uses, but not yet decided for Store
   specifically).
3. **RESOLVED 2026-09-28 (Chris) - Purchase/claim flow.** No
   client-side claim-broadcast - races are rare enough at this guild's
   scale (hundreds of items, infrequent buys) to tolerate. The Store
   officer resolves any double-claim manually, FIFO, using a precise
   timestamp/sequence the addon embeds in the generated mail itself
   (WoW's own mail metadata isn't granular enough for this). No DH-Air-
   style claim/self-heal machinery needed.
4. **RESOLVED 2026-09-28 (Chris) - Tier-discount formula. Prestige
   rate corrected same day: +5%/75% cap -> +10%/80% cap.** Neutral 0%
   (assumed default - not explicitly stated, flag if wrong), Friendly
   10%, Honored 20%, Revered 30%, Exalted 40%, then +10% per Prestige
   level past Exalted, capped at 80% (reached at Prestige 4:
   40+10x4=80, further prestige stays at 80%). **CONFIRMED 2026-09-28
   (Chris) - applies to both** the gold price and the credit price at
   launch - see DH-Bavin-Credits-Design.md's 2026-09-28 Open Questions
   resolution. Chris flagged this could change to gold-only in the
   future, so the discount scope must be an officer-configurable
   setting (per-currency on/off), not hardcoded. Consequence: Store's
   gold-price column is tier-personalized per
   viewer too, same as the credit column - there's no single "the gold
   price" to show, both are computed per-buyer at display time. CM5's
   officer-side checkout needs the same computed discounted gold
   figure to actually set as the CoD amount when sending (WoW's
   SendMail API takes an exact copper CoD value, not something a
   discount can be applied to after the officer sends) - see
   DH-Bavin-Credits-Design.md's CM5 scope update.
5. **RESOLVED 2026-09-28 (Chris), CORRECTING the same-day gap noted
   below - Credit-price vs point-value relationship.** The direction
   is reversed from the first pass: GOLD is the sourced base, not
   credits. The raw data `_build-itempoints.ps1` builds `ItemPoints.lua`
   from already has a gold value per item - just not currently carried
   through into `ItemPoints.lua`'s output - so the import script (and/or
   `ItemPoints.lua`'s shape) needs updating to surface it. The chain is
   now: **gold price** = that raw-data gold value (or a manual
   per-listing override); **credit price** = gold price x a new
   configurable credit/gold ratio (officer config, alongside the
   existing 0.60 credit/point earning multiplier - see
   DH-Bavin-Credits-Design.md's 2026-09-28 Open Questions); then the
   tier discount (#4) applies to both. Credit price is NOT derived
   from ItemPoints.lua's points value directly, as first assumed - the
   points value only ever fed the *earning* side of Credits, never
   pricing. (Original gap note, now resolved: gold DOES have a data
   source, it just wasn't wired through yet.) The new credit/gold
   ratio's starting value (RESOLVED 2026-09-28, Chris): use the same
   ratio as the existing Reputation Points/Gold relationship - Chris's
   recollection is 10 rep points per gold, but needs verifying against
   the actual raw data/points formula before it's wired in as the
   default - see DH-Bavin-Credits-Design.md's 2026-09-28 Open
   Questions resolution.
6. **RESOLVED 2026-09-28 (Chris) - Officer role, full 5-tier
   hierarchy.** Supersedes DH-Bavin-Credits-Design.md's older
   2026-09-25 "Access tiers" (4 tiers) - see that doc's superseding
   note. Each tier grants everything every tier below it grants; tier
   membership is tracked independently per tier (a member can hold any
   combination; removal from one tier never removes any other) -
   Claude agrees this is sound and matches the existing recipient/
   editors precedent (Access tiers section: "two different lists,
   never conflated in code or UI").
   1. **Hidden author override** - Loopi + all Loopi's alts, full
      access. Reuses the existing `IsAuthorAccount()`/
      `AUTHOR_OVERRIDE_ENABLED` mechanism (k-0007) rather than a new
      one. Never documented outside this PC - already satisfied by the
      existing infrastructure, since `claude\` never gets pushed to
      either GitHub repo (only `src\` does, via the collab-dev
      subtree). Same removal-before-offering-to-another-guild
      checklist as today (ROADMAP.md's "Author-account admin
      override" section) applies to DH-Store too.
   2. **Guild Leader** - full access, keyed dynamically to in-game
      guild rank 0 (rank index 0 = Guild Master; numbers increase as
      rank decreases - confirmed by this doc's own existing "any
      rank<=3 officer" convention for editors). **RESOLVED 2026-09-28
      (Chris) - whether Bavin specifically holds rank 0 is moot and
      doesn't need verifying.** The rank-0 check works automatically
      for whichever character is currently logged in with that rank
      (Bavin is only one of several alts belonging to the guild
      leader, a real person) - this tier stays purely rank-keyed as
      designed. Donation Recipient (tier 3, below) is a separate,
      independently-configured assignment and does not depend on this.
   3. **Donation Recipient** - the existing DH-Bavin `recipient` role,
      renamed for clarity now that Store Officer exists as a separate
      thing. Configurable by tier 1 or 2, same as today
      (`CanSetRecipientName`).
   4. **Store Officer(s)** - NEW, Store-specific. Configurable by tier 1,
      2, or 3. Plural - gets the GUI for adding/removing store
      listings and manually overriding prices. Open sub-question
      resolved for now: when a member requests a purchase, ONE
      designated PRIMARY Store Officer receives all of Store's purchase-
      request mail (not every Store Officer) - who's primary is itself
      configurable, not hardcoded.
   5. **RESOLVED 2026-09-28 (Chris) - Designated Distribution
      Officer(s)** - configurable by tier 1, 2, or 3. Sends the
      fulfillment mail, collects CoD and/or deducts Credits (CM5's
      engine). Confirmed: this is exactly the existing "Designated
      Officer" role from the Access tiers section above, simply
      renamed now that "Store Officer" has its own distinct name - no
      permission changes, not a new/narrower tier.
7. **Shared scroll-list widget** - new src\DH-Tools\Widgets\ folder,
   native HybridScrollFrame-based (matches the real Auction House's own
   chrome; explicitly not AceGUI - see STATUS.md's Last session). Built first
   against DH-Store, Bavin's Roster/Conflicts tabs backported later
   only if it proves out. Not yet started.
8. **RESOLVED 2026-09-28 (Chris) - UI layout specifics.** Full
   filtering, matching the real Auction House: a search bar plus
   category and quality dropdowns, even at guild-catalog scale
   (hundreds, not thousands, of items). Not yet specced further
   (exact dropdown values, layout).
9. **RESOLVED 2026-09-28 (Chris) - Build sequencing relative to the
   Credits CM plan.** Store's actual checkout is just CM5's
   outgoing-mail debit engine, used the same way regardless of whether
   the item came from the store, an in-game request, or a Discord
   post - the store is "more of a shopping tool than anything else...
   a catalog of available items." So DH-Store's catalog/browsing UI
   and the officer's item-listing UI can be designed and built almost
   any time, independent of DH-Bavin's CM3/CM5 sequencing - only the
   live debit-on-purchase step needs CM5 to actually exist first. (#1
   above, Core.lua's dependency mechanism, is the one real blocker on
   Store being toggleable at all.) The audit trail's optional `origin`
   tag (see DH-Bavin-Credits-Design.md's Data model update) lets a
   Store-originated purchase be distinguished from any other, cheaply,
   if that ever proves useful.
10. **RESOLVED 2026-09-28 (Chris) - Prominent discount display.** The
    viewer's current tier discount % shows as an always-visible
    badge/pill next to the gold/Credits balance readout (e.g. "Honored:
    20% off"), plus a richer hover tooltip on that same area with tier
    name, points, next-tier target, and lifetime points - not one or
    the other, both.
11. **RESOLVED 2026-09-28 (Chris) - Price-column real estate.** Chris
    agreed 4 full columns (gold, tier gold, credits, tier credits) is
    too many, but wants the "full price" still visible alongside the
    "tier price" - it's an instant, on-every-row reminder of the
    payoff for donating items and earning guild reputation, not just
    a number to look up. Resolved as **2 price columns, not 4** (Gold,
    Credits): each cell shows the pre-discount base price struck
    through beside the tier-discounted price, e.g. `~~50g~~ 30g`. This
    keeps both numbers on every row (stronger reminder than hiding the
    base price in a details panel) while still fitting in 2 columns.
    Pairs with #10's global discount-% badge near the balance readout:
    the badge explains *why* the price differs, the struck-through
    column reinforces it row by row. Superseded a prior list-only-
    shows-final-total / base-price-in-details-panel-only proposal.
12. **RESOLVED 2026-09-28 (Chris) - Stack pricing/purchase
    granularity.** Whole lot only, matching the real Auction House - no
    partial-stack buys. Simplifies the pricing math (no per-unit
    figures needed as buyer-facing numbers, just a stack-total per
    listing) and the UI (no quantity picker).
    **New requirement surfaced by this same answer: multiple
    simultaneous listings of the same item.** A seller can post several
    stacks of different sizes of the same item at once (e.g. a 5-stack
    and a 20-stack of Netherweave Cloth both live at the same time) -
    this rules out an item-ID-keyed catalog (one entry per item, like
    Bavin's priority want-list). #2's catalog sync wire format needs a
    per-listing ID (not itemId) as the catalog's actual key, with
    itemId as just a field on each listing - multiple listings can
    share an itemId.

## Status
Scaffolded 2026-09-28: folder structure and design docs. Core.lua's
module-dependency mechanism (question 1) is now BUILT and harness-
tested (52/52) as of 2026-09-28, in Core.lua/Config.lua - DH-Store's
own module code (Modules\DHStore\Core.lua, registering with
`requires = "bavin"`) does not exist yet. See claude\DH-Store\STATUS.md
for current task.
