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
4. **Tier-discount formula** - what discount each reputation tier
   (Neutral/Friendly/Honored/Revered/Exalted/Prestige) actually gets
   off the credit price. Not discussed yet.
5. **RESOLVED 2026-09-28 (Chris) - Credit-price vs point-value
   relationship.** Layered, not either/or: a store item's price
   defaults to ItemPoints.lua's existing value, then can be overridden
   manually per-listing (Store-specific), then the tier discount (#4
   above) is applied on top at display/purchase time. Same pricing
   chain CM5's outgoing-mail checkout now uses (see
   DH-Bavin-Credits-Design.md's CM5 scope update) - Store doesn't need
   its own separate pricing data model, just an optional per-item
   override on top of what Bavin already maintains.
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

## Status
Scaffolded 2026-09-28: folder structure and design docs only
(claude\DH-Store\PROFILE.md, claude\DH-Store\STATUS.md, this file). No
code yet - Core.lua's module-dependency mechanism (question 1 above)
has to be resolved before DH-Store can even be registered as a module.
See claude\DH-Store\STATUS.md for current task.
