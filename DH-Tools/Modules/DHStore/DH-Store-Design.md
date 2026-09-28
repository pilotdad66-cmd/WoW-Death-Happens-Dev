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
   blocks everything else - Store can't be registered at all until
   this exists.
2. **Catalog sync wire format** - mirrors DH-Bavin's priority-list
   ITEM/ITEMGONE broadcast + SYNCREQ/SYNCDATA pattern, but needs its
   own message prefix/payload shape (item, quantity, gold price, base
   credit price - NOT per-tier prices, those are computed client-side)
   and its own permission gate (who can add/edit/remove store listings
   - presumably the same recipient/editor-style guild-roster-verified
   model DH-Bavin already uses, but not yet decided for Store
   specifically).
3. **Purchase/claim flow** - exact message(s) for a buy action: does a
   client broadcast a claim/decrement the instant "Buy" is clicked (so
   other online clients see it disappear immediately), or does the
   addon only generate the mail and rely on the officer to manually
   decrement stock afterward? Chris's call (2026-09-28): races are
   rare enough at this guild's scale to tolerate, resolved by the
   officer FIFO via a precise timestamp/sequence the addon embeds in
   the mail itself (not WoW's own mail metadata, which isn't granular
   enough). Still need to decide whether the addon also does the fast
   client-side broadcast-claim as a first line of defense, or skips it
   entirely and leans on the officer resolution alone.
4. **Tier-discount formula** - what discount each reputation tier
   (Neutral/Friendly/Honored/Revered/Exalted/Prestige) actually gets
   off the credit price. Not discussed yet.
5. **Credit-price vs point-value relationship** - does a store item's
   credit price come from the existing ItemPoints.lua lookup (like the
   outgoing credit-debit mail flow already uses), or is it a
   store-specific price Bavin/the officer sets independently per
   listing? Not discussed yet - affects whether Store needs its own
   catalog-authoring data at all or just prices on top of data Bavin
   already maintains.
6. **Officer role** - is "AH officer" the same role as DH-Bavin's
   existing mail recipient/Designated Officer roles, or a new,
   separate permission list? Not discussed yet.
7. **Shared scroll-list widget** - new src\DH-Tools\Widgets\ folder,
   native HybridScrollFrame-based (matches the real AH's own chrome;
   explicitly not AceGUI - see STATUS.md's Last session). Built first
   against DH-Store, Bavin's Roster/Conflicts tabs backported later
   only if it proves out. Not yet started.
8. **UI layout specifics** - filter/search bar, category/quality
   dropdowns, whether they're needed at guild-catalog scale (hundreds,
   not thousands, of items) - sketched in conversation, not specced.

## Status
Scaffolded 2026-09-28: folder structure and design docs only
(claude\DH-Store\PROFILE.md, claude\DH-Store\STATUS.md, this file). No
code yet - Core.lua's module-dependency mechanism (question 1 above)
has to be resolved before DH-Store can even be registered as a module.
See claude\DH-Store\STATUS.md for current task.
