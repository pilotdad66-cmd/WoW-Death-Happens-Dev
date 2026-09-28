# DH-Store - Design (skeleton, 2026-09-28)

## Concept
A guild-only, buyout-only item store, modeled visually on the in-game
Auction House's Browse pane but functionally simpler (no bids, no
listing duration, no undercutting). Bavin or a designated AH officer
lists items at a gold price and a Bavin Credits price; the credit price
is discounted by the buyer's own reputation tier (see
DH-Bavin-Credits-Design.md's Points/tier system, which this module
reads but does not own). "Buying" cannot move gold or items
automatically - no WoW addon can - so it generates a mail to the AH
officer with (buyer, item, price) for manual fulfillment: item
delivery via mail, and payment either gold (CoD) or a Credits
deduction the addon still applies automatically the same way the
existing outgoing credit-debit flow does today.

Full context and everything already decided (packaging, dependency
model, fresh-install defaults, access points) is in
claude\DH-Store\PROFILE.md - not repeated here.

## Open design questions (resolve before Milestone 1 - README section 14)
1. **Core.lua inter-module dependency mechanism** - RegisterModule's
   `def` has no concept of one module requiring another today (only
   name/desc/default/OnEnable/OnDisable). Needs a real design: how
   Store declares its dependency on Bavin, how checking Store cascades
   to auto-check Bavin, how unchecking Bavin cascades to auto-uncheck
   Store, and how the Tools config page greys out/disables a
   dependent module's checkbox when its dependency is off. This
   blocks everything else - Store can't be registered as a DH-Tools
   module at all until this exists. This is a separate blocker from
   the Credits-system sequencing question below (#9) - it gates
   Store's very existence as a toggleable module, not just its
   checkout feature.
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
   scale (hundreds of items, infrequent buys) to tolerate. The AH
   officer resolves any double-claim manually, FIFO, using a precise
   timestamp/sequence the addon embeds in the generated mail itself
   (WoW's own mail metadata isn't granular enough for this). No DH-Air-
   style claim/self-heal machinery needed.
4. **RESOLVED 2026-09-28 (Chris) - Tier-discount formula. Prestige
   rate corrected same day: +5%/75% cap -> +10%/80% cap.** Neutral 0%
   (assumed default - not explicitly stated, flag if wrong), Friendly
   10%, Honored 20%, Revered 30%, Exalted 40%, then +10% per Prestige
   level past Exalted, capped at 80% (reached at Prestige 4:
   40+10x4=80, further prestige stays at 80%). Applies to **both** the
   gold price and the credit price, though this is now itself one of
   the questions routed to Bavin for confirmation - see
   DH-Bavin-Credits-Design.md's 2026-09-28 Open Questions addition.
   Consequence: Store's gold-price column is tier-personalized per
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
   source, it just wasn't wired through yet.)
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
   2. **Guild Leader** - full access, keyed to in-game guild rank 0
      (rank index 0 = Guild Master; numbers increase as rank
      decreases - confirmed by this doc's own existing "any rank<=3
      officer" convention for editors). Chris believes this is Bavin
      but is not certain ("I think") - needs verifying against the
      real roster, not assumed.
   3. **Donation Recipient** - the existing DH-Bavin `recipient` role,
      renamed for clarity now that AH Officer exists as a separate
      thing. Configurable by tier 1 or 2, same as today
      (`CanSetRecipientName`).
   4. **AH Officer(s)** - NEW, Store-specific. Configurable by tier 1,
      2, or 3. Plural - gets the GUI for adding/removing store
      listings and manually overriding prices. Open sub-question
      resolved for now: when a member requests a purchase, ONE
      designated PRIMARY AH Officer receives all of Store's purchase-
      request mail (not every AH Officer) - who's primary is itself
      configurable, not hardcoded.
   5. **Designated Distribution Officer(s)** - configurable by tier 1,
      2, or 3. Sends the fulfillment mail, collects CoD and/or deducts
      Credits (CM5's engine). Very likely this is exactly the existing
      "Designated Officer" role from the Access tiers section above,
      just renamed now that "AH Officer" needs its own distinct name -
      not yet confirmed with Chris; if it's meant to be narrower than
      the existing Designated Officer (e.g. can send/charge but not
      view the full ledger or edit alt-links), that's a genuinely new,
      more limited tier rather than a rename.
7. **Shared scroll-list widget** - new src\DH-Tools\Widgets\ folder,
   native HybridScrollFrame-based (matches the real AH's own chrome;
   explicitly not AceGUI - see STATUS.md's Last session). Built first
   against DH-Store, Bavin's Roster/Conflicts tabs backported later
   only if it proves out. Not yet started.
8. **UI layout specifics** - filter/search bar, category/quality
   dropdowns, whether they're needed at guild-catalog scale (hundreds,
   not thousands, of items) - sketched in conversation, not specced.
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
10. **Prominent discount display** (Chris, 2026-09-28) - the viewer's
    current tier discount % needs to show prominently near the
    lower-left gold/Credits balance readout, not just be silently
    baked into each row's price. Not yet laid out.
11. **Price-column real estate - open, Claude's take offered, not
    decided.** Chris asked whether 4 full columns (gold, tier gold,
    credits, tier credits) fit in the list. Claude's read: probably
    not comfortably at readable width in a single row, especially
    once stacks (#12) are factored in - and it's largely redundant
    with #10 (if the discount is already shown once, prominently,
    repeating base-vs-discounted as 4 separate list columns adds
    little). Recommends following the real AH's own precedent
    instead: the list itself shows only the final payable total(s)
    per row (2 columns - gold, credits - both already tier-adjusted),
    while the full breakdown (base price, discount applied, per-unit
    vs. stack-total) lives in a details panel for the currently-
    selected row, same as the real AH's list-shows-buyout /
    detail-panel-shows-per-item split. Chris to confirm or redirect.
12. **Stack pricing - open, new.** Some listings will be stacks (e.g.
    20x Netherweave Cloth), needing both a per-unit price and a
    stack-total price, times up to 2 currencies (gold/credits) x 2
    states (base/discounted) - up to 8 numbers per listing if shown in
    full. Whether the store lets a buyer purchase part of a stack or
    always the whole listed lot (matching how the real AH sells a
    listing as one indivisible lot) is undecided - affects both the
    pricing math and whether "per-unit" needs to be buyer-facing at
    all or is purely informational.

## Status
Scaffolded 2026-09-28: folder structure and design docs only
(claude\DH-Store\PROFILE.md, claude\DH-Store\STATUS.md, this file). No
code yet - Core.lua's module-dependency mechanism (question 1 above)
has to be resolved before DH-Store can even be registered as a module.
See claude\DH-Store\STATUS.md for current task.
