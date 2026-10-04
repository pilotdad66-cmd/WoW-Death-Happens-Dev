-- DH-Tools: Modules\DHBavin\Credits.lua
-- CM1 (see this folder's DH-Bavin-Credits-Design.md "Milestone plan"):
-- Data model, permission plumbing & isolation walls for the Credit &
-- Reputation System. No mail-processing code yet (CM4/CM5) - this file
-- only builds the four walls the design doc requires land here first:
--   Wall 1 - separate SavedVariables file (DHBavinCreditsDB), isolated
--            from DHBavinDB so a credit-system bug can't touch v1.0
--            state, and the whole feature is removable by deleting this
--            file (+ its .toc lines).
--   Wall 2 - two independent test lists (creditTestReceivers,
--            creditTestSenders), distinct from the live `recipient`
--            field (DHBavinDB) - this file never reads or writes that.
--   Wall 3 - master toggle, defaults OFF. Ships inert.
--   Wall 4 - both mail hooks (still no-ops here) install only for a
--            listed test character, checked BEFORE installation, not
--            inside the handler. Armed lazily at PLAYER_LOGIN.
--
-- Own addon-message prefix (DHBavinCreditsV2 as of 2026-09-28, bumped
-- from V1 - see the PREFIX comment further down for why), deliberately
-- NOT sharing Sync.lua's DHBavinV4 (2026-09-24, Chris) - keeps this
-- feature's wire format fully isolated from the live v1.0 donation
-- flow, matching Wall 1's "removable by deleting one file" goal.
-- Carries Wall 2/3 config (toggle, test lists, Credit/Rep and Rep/Gold
-- ratios) - NOT the officer list any more (2026-09-28, Chris: that's
-- now DH-Bavin's single shared officer-roles list, see Core.lua's
-- IsOfficerName) and NOT the ledger itself (that's CM3's job; wire
-- format TBD there per the design doc's own "work out the exact wire
-- format" note).
--
-- Credits vs. Reputation points: NOT the same number (2026-09-24,
-- Chris) - points are the tier-tracked reputation total, credits are a
-- separate spendable balance. 2026-09-28 (Chris): the single "credits
-- per point" MULTIPLIER is now THREE independent, officer-editable
-- ratios instead - Credit/Rep, Credit/Gold (DH-Store's own
-- creditGoldRatio, unchanged location), and a new Rep/Gold ratio that
-- isn't consumed by anything yet (Rep points come from the static
-- ItemPoints.lua baseline, not a calculation) but Chris wants it
-- configurable anyway. The three do NOT have to reconcile with each
-- other - Chris's explicit call. Each ratio is stored/edited as an X/Y
-- pair ("X Credits = Y Rep Points", etc.), not a single decimal, so the
-- UI can show the whole-number relationship Chris actually thinks in
-- rather than a multiplier like 0.01. This file's config just carries
-- Credit/Rep and Rep/Gold; CM4's crediting logic (not yet built) is
-- what would actually apply Credit/Rep.

local DHTools = DHTools
DHTools.Bavin = DHTools.Bavin or {}
local ns = DHTools.Bavin

function ns.CreditsPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Bavin Credits:|r " .. msg)
end

-- 2026-09-28 (Chris): "100 rep = 1 credit" as a whole-number ratio pair
-- (x Credits = y Rep) instead of the old single 0.01 multiplier.
local DEFAULT_CREDITS_PER_REP = { x = 1, y = 100 }
-- NOT USED by any formula yet (see header comment) - a starting default
-- only, picked to match the "100 rep = ..." figure Chris has used
-- elsewhere. Officers can set it to anything; nothing currently reads it.
local DEFAULT_REP_PER_GOLD = { x = 100, y = 1 }

--------------------------------------------------------------------------
-- Wall 1: SavedVariables
--------------------------------------------------------------------------
function ns.InitCreditsDB()
    if type(DHBavinCreditsDB) ~= "table" then
        DHBavinCreditsDB = {}
    end
    ns.creditsDb = DHBavinCreditsDB

    -- Ledger (Identity model v2, 2026-09-25): keyed by discordName -
    -- { discordName, mainToon, alts = {...}, points, credits, tier,
    -- prestige, lifetimePoints, lifetimeCredits, lastDonationDate,
    -- lastUpdated }. points = progress inside the CURRENT tier/prestige
    -- lap (resets on tier-up); lifetimePoints never resets. credits =
    -- spendable balance (goes down on a charge); lifetimeCredits =
    -- total ever earned, only ever goes up (2026-09-29, Loopi) - use
    -- ns.Credits_AdjustCredits to change either so that stays true. Empty
    -- until CM2 seeds it from Step 0's validated seed-dataset.csv.
    -- Superseded the original mainName-keyed shape (no altOverrides
    -- table any more - an alt is a direct member of its account's
    -- `alts` list, not a separate override pointing at a name).
    if type(ns.creditsDb.ledger) ~= "table" then
        ns.creditsDb.ledger = {}
    end
    -- lifetimeCredits migration (2026-09-29): records saved before the
    -- field existed get it from their current balance - the only earned
    -- total that can be known for them (credits seeded at 0 at go-live
    -- and nothing has been spent yet). Also enforces the invariant
    -- lifetimeCredits >= credits for any record found violating it.
    for _, rec in pairs(ns.creditsDb.ledger) do
        if type(rec) == "table" then
            local bal = tonumber(rec.credits) or 0
            local life = tonumber(rec.lifetimeCredits)
            if not life or life < bal then rec.lifetimeCredits = bal end
            -- Discord-name migration (2026-09-29): records saved before the
            -- `discord` field existed had the Discord name == the ledger key
            -- (seeded as the main's name), so that is the starting tag.
            if rec.discord == nil then rec.discord = rec.discordName or "" end
        end
    end
    -- toonIndex: bare-toon-name(lower) -> discordName, rebuilt whenever
    -- ledger membership changes (seed import, link, unlink, set-as-new-
    -- main) so Credits_ResolveMain doesn't scan the whole ledger on
    -- every call. Never hand-edited or persisted meaningfully across a
    -- version change - always safe to rebuild from the ledger.
    if type(ns.creditsDb.toonIndex) ~= "table" then
        ns.creditsDb.toonIndex = {}
    end
    -- Dynamic Review Queue additions (2026-09-25, Loopi: "When an alt
    -- is removed - it should go back into the review queue"): entries
    -- added at runtime by Credits_UnlinkAlt, on top of the static,
    -- GENERATED ns.CreditsReviewQueue (Step 0's own unresolved list).
    -- Same shape as a ReviewQueue.lua row ({ name, issue,
    -- latestDonation, rawGoldAmount, details }), issue = "removed_alt".
    if type(ns.creditsDb.dynamicReviewQueue) ~= "table" then
        ns.creditsDb.dynamicReviewQueue = {}
    end
    -- Per-transaction audit log (who, item, delta, processedBy, when) - CM4+.
    if type(ns.creditsDb.transactionLog) ~= "table" then
        ns.creditsDb.transactionLog = {}
    end
    -- CM4 (CreditsDonations.lua). pendingCredits[senderLower] = { entry, ... }:
    -- computed donation entries for a sender who resolves to no account yet
    -- (held, never dropped); entries are applied automatically on the mail
    -- recipient's client once the sender resolves. pendingReleased[id] =
    -- { ts } is the replicated "released" tombstone so a late copy of a
    -- released entry can't resurrect it. ledgerTombstones[discordName] =
    -- { ts } marks an account deleted by a merge (CM3 sync carries it).
    if type(ns.creditsDb.pendingCredits) ~= "table" then
        ns.creditsDb.pendingCredits = {}
    end
    if type(ns.creditsDb.pendingReleased) ~= "table" then
        ns.creditsDb.pendingReleased = {}
    end
    if type(ns.creditsDb.ledgerTombstones) ~= "table" then
        ns.creditsDb.ledgerTombstones = {}
    end

    -- Wall 3: master toggle, OFF by default. Ships inert.
    if ns.creditsDb.masterToggle == nil then
        ns.creditsDb.masterToggle = false
    end
    -- Wall 2: the two independent test lists. Distinct from `recipient`
    -- (DHBavinDB, the live v1.0 donation flow) - this file never reads
    -- or writes that field.
    if type(ns.creditsDb.creditTestReceivers) ~= "table" then
        ns.creditsDb.creditTestReceivers = {}
    end
    if type(ns.creditsDb.creditTestSenders) ~= "table" then
        ns.creditsDb.creditTestSenders = {}
    end
    -- 2026-09-28 (Chris): no more Distribution Officers list here - see
    -- this file's header comment. ns.creditsDb.officers (if present from
    -- an earlier test build) is simply left alone and unread; harmless.
    -- Credit/Rep and Rep/Gold ratios, each an {x=, y=} pair
    -- ("x Credits = y Rep Points" / "x Rep = y Gold"), officer-editable,
    -- independent of each other and of DH-Store's own creditGoldRatio.
    if type(ns.creditsDb.creditsPerRep) ~= "table" or type(ns.creditsDb.creditsPerRep.x) ~= "number" then
        ns.creditsDb.creditsPerRep = { x = DEFAULT_CREDITS_PER_REP.x, y = DEFAULT_CREDITS_PER_REP.y }
    end
    if type(ns.creditsDb.repPerGold) ~= "table" or type(ns.creditsDb.repPerGold.x) ~= "number" then
        ns.creditsDb.repPerGold = { x = DEFAULT_REP_PER_GOLD.x, y = DEFAULT_REP_PER_GOLD.y }
    end
    -- Version stamp for the config broadcast below - same "strictly
    -- newer wins" idiom Core.lua's k-0019 fix uses for recipient/editors.
    if type(ns.creditsDb.configUpdatedAt) ~= "number" then
        ns.creditsDb.configUpdatedAt = 0
    end
    -- 2026-10-04 (Loopi): the two ratios have their OWN version stamp and
    -- message (RATESET) now, gated tighter than the rest of the config.
    -- First run after this change seeds it from configUpdatedAt so an
    -- existing install's rates keep their age.
    if type(ns.creditsDb.ratesUpdatedAt) ~= "number" then
        ns.creditsDb.ratesUpdatedAt = ns.creditsDb.configUpdatedAt or 0
    end
end

--------------------------------------------------------------------------
-- Permission model
--------------------------------------------------------------------------
-- 2026-09-28 (Chris): Distribution Officers is no longer a Credits-owned
-- list - see this file's header comment. "Officer" status for Credits
-- config purposes now comes straight from DH-Bavin's shared officer-
-- roles list (Core.lua's IsOfficerName), which also grants Bavin
-- donation-editing and Store listing management.

-- LOCAL-only: whether the local player may manage Wall 2/3 config
-- (master toggle, test lists, ratios) - any shared-list officer, or the
-- author account. Same LOCAL-only safety split as Core.lua's
-- CanEditListLocal (see that function's comment) - a function that also
-- verifies a REMOTE sender must stay pure name-based; see
-- IsAuthorizedConfigSender below for that side.
function ns.CanManageCreditsConfigLocal()
    if not ns.IsInTargetGuild() then return false end
    if DHTools.IsAuthorAccount and DHTools.IsAuthorAccount() then return true end
    return ns.IsOfficerName(UnitName("player"))
end

-- 2026-10-04 (Loopi): during CM4 testing the master toggle and both Wall 2
-- test lists are the AUTHOR ACCOUNT ONLY - not any shared-list officer.
-- Bavin's live script/Excel process must not be reachable by an officer
-- adding him to a list mid-test. Everything else stays on
-- CanManageCreditsConfigLocal; the RATES have their own gate
-- (CanManageCreditsRatesLocal) and their own message, so a rate change no
-- longer carries a copy of the toggle/lists (that gap is closed
-- 2026-10-04). LOCAL-only, like that function. Remaining gap: receivers
-- can't identify the author remotely, so CFGSET itself is accepted from
-- any officer; only the UI/slash edit path is author-only. Relax this
-- (back to CanManageCreditsConfigLocal) at the CM9 cutover.
function ns.CanManageCreditsTestConfigLocal()
    if not ns.IsInTargetGuild() then return false end
    return (DHTools.IsAuthorAccount and DHTools.IsAuthorAccount()) and true or false
end

-- RECEIVE-SIDE check for an incoming CFGSET/CREDITSYNCDATA: the sender
-- must be either the guild leader or a currently-known shared-list
-- officer. Never trusts a self-asserted claim in the message itself -
-- same idiom Sync.lua's receive-side verification uses.
local function IsAuthorizedConfigSender(senderShort)
    if ns.IsGuildLeader(senderShort) then return true end
    return ns.IsOfficerName(senderShort)
end
-- CM3 (CreditsSync.lua) verifies ledger-sync senders with the same check.
ns.Credits_IsAuthorizedSender = IsAuthorizedConfigSender

-- 2026-10-04 (Loopi): the Credit/Rep and Rep/Gold RATES are editable by
-- ONLY: the author (every one of the author's characters), the guild
-- leader, and the donation recipient - not any shared-list officer.
-- IsRatesSetterName is the name-based check usable on a REMOTE sender
-- (RATESET receive side) and on the local player's own name. A receiving
-- client can't see the sender's account-wide author flag, so "author, all
-- characters" is approximated by name: Loopi/Loopidot directly, or any
-- character this client's ledger/GRM resolves to the main "Loopi".
local RATES_AUTHOR_NAMES = { loopi = true, loopidot = true }
local RATES_AUTHOR_MAIN = "loopi"

local function IsRatesSetterName(name)
    if not name or name == "" then return false end
    if ns.IsGuildLeader(name) then return true end -- includes Loopidot
    if ns.db and ns.db.recipient and ns.NormalizeName(ns.db.recipient) == ns.NormalizeName(name) then
        return true
    end
    local bare = ns.NormalizeName(name):lower()
    if RATES_AUTHOR_NAMES[bare] then return true end
    if ns.Credits_ResolveMain then
        local main = ns.Credits_ResolveMain(name)
        if main and ns.NormalizeName(main):lower() == RATES_AUTHOR_MAIN then return true end
    end
    return false
end
ns.Credits_IsRatesSetterName = IsRatesSetterName

-- LOCAL-only gate for editing the rates (UI + slash): author account (all
-- of the author's alts, via DHTools.IsAuthorAccount), guild leader, or
-- the recipient.
function ns.CanManageCreditsRatesLocal()
    if not ns.IsInTargetGuild() then return false end
    if DHTools.IsAuthorAccount and DHTools.IsAuthorAccount() then return true end
    return IsRatesSetterName(UnitName("player"))
end

--------------------------------------------------------------------------
-- Alt resolution (CM2, ongoing - see DH-Bavin-Credits-Design.md's "Data
-- model" section for the algorithm this implements verbatim)
--------------------------------------------------------------------------
-- Identity model v2 (2026-09-25, designed with Loopi - see
-- DH-Bavin-Credits-Design.md's "Identity model v2" section). Ledger is
-- keyed by discordName (stable, editable, seeded = the main toon's name
-- at seed time - see CreditsSeed.lua); each account record carries
-- `mainToon` (the currently-flagged main, editable - a main-swap is now
-- a field edit, not a ledger-key migration) and `alts` (an array of
-- toon names belonging to that account). toonIndex maps every known
-- bare toon name (main or alt, lower-cased) to its account's
-- discordName, so resolution is a single table lookup instead of a
-- ledger scan.
--------------------------------------------------------------------------

-- The one place a ledger record's credit numbers should change (used by
-- the future mail-processing flows and CM3 sync receive). A positive
-- delta is an EARN: raises the balance and lifetimeCredits together. A
-- negative delta is a SPEND/charge: lowers the balance only, never below
-- 0 here (callers block an unaffordable charge first), and never touches
-- lifetimeCredits. Returns the new balance, or nil for a bad record.
function ns.Credits_AdjustCredits(rec, delta)
    if type(rec) ~= "table" then return nil end
    delta = tonumber(delta) or 0
    local bal = tonumber(rec.credits) or 0
    local life = tonumber(rec.lifetimeCredits) or bal
    if delta > 0 then
        life = life + delta
    end
    -- Stored to four decimals (display is two) - see CreditsDonations Round4.
    bal = math.floor(math.max(0, bal + delta) * 10000 + 0.5) / 10000
    life = math.floor(life * 10000 + 0.5) / 10000
    rec.credits = bal
    rec.lifetimeCredits = math.max(life, bal)
    return bal
end

-- Rebuilds toonIndex from the ledger's current mainToon/alts fields.
-- Called after any bulk change (seed import); Link/Unlink/SetAsNewMain
-- below keep it in sync incrementally instead of paying for a full
-- rebuild on every single edit.
function ns.Credits_RebuildToonIndex()
    local index = {}
    if ns.creditsDb and ns.creditsDb.ledger then
        for discordName, rec in pairs(ns.creditsDb.ledger) do
            if rec.mainToon and rec.mainToon ~= "" then
                index[rec.mainToon:lower()] = discordName
            end
            for _, altName in ipairs(rec.alts or {}) do
                index[altName:lower()] = discordName
            end
        end
    end
    ns.creditsDb.toonIndex = index
    return index
end

-- character name (bare or realm-qualified) -> that person's CURRENT
-- mainToon name (always returned bare, no "-Realm" suffix - matches how
-- the ledger and SeedData.lua key their entries; SkullRock is the
-- guild's only realm, so a realm suffix on the key would only add
-- noise). Contract is UNCHANGED from v1 (toon name in, toon name out) -
-- every existing caller (tooltips, mail crediting, priority lists)
-- needs no changes. Tries, in order: (1) toonIndex - our own account
-- data, which Loopi confirmed stays authoritative for future donations
-- even where GRM disagrees ("GRM remains authoritative" was about never
-- writing INTO GRM's own database, not about resolution order), (2)
-- GRM.GetPlayerMain wrapped in pcall (GRM may not be loaded, or may not
-- have learned this character yet - confirmed 2026-09-25 via GRM-Probe
-- that an unknown name returns nil rather than erroring), (3)
-- self-fallback - a character with no linked alts is trivially its own
-- main.
function ns.Credits_ResolveMain(characterName)
    if not characterName or characterName == "" then return nil end
    local bareName = ns.NormalizeName(characterName)

    if ns.creditsDb and ns.creditsDb.toonIndex then
        local discordName = ns.creditsDb.toonIndex[bareName:lower()]
        if discordName then
            local rec = ns.creditsDb.ledger[discordName]
            if rec and rec.mainToon and rec.mainToon ~= "" then
                return rec.mainToon
            end
        end
    end

    if GRM and GRM.GetPlayerMain then
        local realmQualified = bareName .. "-" .. GetRealmName()
        local ok, main = pcall(GRM.GetPlayerMain, realmQualified)
        if ok and type(main) == "string" and main ~= "" then
            return main:match("^([^%-]+)") or main
        end
    end

    return bareName
end

-- Removes altBare from whichever account currently claims it, if any.
-- Internal helper shared by Link (moving an alt) and Unlink (releasing
-- one) - does NOT touch the Review Queue; callers decide whether a
-- reopen is appropriate. No permission gate here - both public callers
-- gate themselves.
local function RemoveAltFromAnyAccount(altBare)
    if not ns.creditsDb or not ns.creditsDb.ledger then return false end
    local key = altBare:lower()
    for _, rec in pairs(ns.creditsDb.ledger) do
        if rec.alts then
            for i, a in ipairs(rec.alts) do
                if a:lower() == key then
                    table.remove(rec.alts, i)
                    if ns.creditsDb.toonIndex then ns.creditsDb.toonIndex[key] = nil end
                    return true, rec.discordName
                end
            end
        end
    end
    return false
end

-- Links altName to the account whose CURRENT main toon is
-- mainToonName. LOCAL ONLY for now, same as Credits_ResetTestData below
-- - the officer-only ledger sync wire format is still CM3's job (design
-- doc: "TBD there"), so this doesn't guess at one. Each Designated
-- Officer who links an alt does so on their own client until that sync
-- exists; officers coordinate verbally during the test phase, same as
-- the reset utility. Gated the same as the rest of this file's local
-- config writes (CanManageCreditsConfigLocal), not the stricter
-- CanManageCreditsOfficers - resolving alt-identity is Designated
-- Officer work, not guild-leader-only (design doc's Access tiers).
-- Refuses if mainToonName doesn't resolve to any known account -
-- Credits_SetAsNewMain (CreditsSeed.lua) is the path for making a
-- brand-new account, this function only ever attaches to an existing
-- one. Clears any pending Review Queue entry for altName, since
-- linking it resolves whatever put it there.
function ns.Credits_LinkAlt(altName, mainToonName)
    if not ns.CanManageCreditsConfigLocal() then return false end
    if not altName or altName == "" or not mainToonName or mainToonName == "" then return false end
    local altBare = ns.NormalizeName(altName)
    local mainBare = ns.NormalizeName(mainToonName)

    if not ns.creditsDb.toonIndex then ns.Credits_RebuildToonIndex() end
    local discordName = ns.creditsDb.toonIndex[mainBare:lower()]
    if not discordName then return false end
    local rec = ns.creditsDb.ledger[discordName]
    if not rec then return false end
    -- Can't link a name to itself, and can't link a name that's
    -- currently the TARGET account's own main toon (that would need a
    -- main-reassignment, not a link).
    if altBare:lower() == mainBare:lower() then return false end

    local _, previousAccount = RemoveAltFromAnyAccount(altBare)
    rec.alts = rec.alts or {}
    table.insert(rec.alts, altBare)
    ns.creditsDb.toonIndex[altBare:lower()] = discordName
    ns.Credits_RemoveFromReviewQueue(altBare)
    -- CM3: the target account (and the one the alt moved away from) changed,
    -- and the name left the Review Queue.
    if ns.CreditsSync_Changed then
        ns.CreditsSync_Changed({ discordName, previousAccount }, { { name = altBare, present = false } })
    end
    -- CM4: a link may be exactly what a held donation was waiting for.
    if ns.Credits_ReleasePending then ns.Credits_ReleasePending() end
    return true
end

-- Officer-initiated removal: takes altName out of its account AND
-- reopens it in the Review Queue so it can be re-linked to the correct
-- main rather than just vanishing (2026-09-25, Loopi: "When an alt is
-- removed - it should go back into the review queue"). Works whether
-- the association came from a manual Link or from Step 0's historical
-- import - Loopi confirmed both should be fixable this way; GRM's own
-- database is never touched either way ("GRM remains authoritative" is
-- about not writing into GRM, not about what our own records can fix).
function ns.Credits_UnlinkAlt(altName)
    if not ns.CanManageCreditsConfigLocal() then return false end
    if not altName or altName == "" then return false end
    local altBare = ns.NormalizeName(altName)
    local removed, previousAccount = RemoveAltFromAnyAccount(altBare)
    if not removed then return false end
    ns.Credits_AddToReviewQueue(altBare)
    if ns.CreditsSync_Changed then
        ns.CreditsSync_Changed({ previousAccount }, { { name = altBare, present = true } })
    end
    return true
end

-- Officer-initiated main swap (Roster tab right-click "Promote to Main",
-- 2026-09-29): the named ALT becomes the account's main toon and the old
-- main takes its slot in the alt list, so the account ALWAYS has a main.
-- The ledger key (discordName) and every number on the record - points,
-- credits, lifetime totals, history - are untouched; per Identity model v2
-- a main-swap is only a field edit. Returns true, newMain on success.
function ns.Credits_PromoteToMain(altName)
    if not ns.CanManageCreditsConfigLocal() then return false end
    if not altName or altName == "" or not ns.creditsDb then return false end
    if not ns.creditsDb.toonIndex then ns.Credits_RebuildToonIndex() end
    local key = ns.NormalizeName(altName):lower()
    local discordName = ns.creditsDb.toonIndex[key]
    local rec = discordName and ns.creditsDb.ledger[discordName]
    if not rec then return false end
    if rec.mainToon and rec.mainToon:lower() == key then return false end -- already the main
    local idx
    for i, a in ipairs(rec.alts or {}) do
        if a:lower() == key then idx = i break end
    end
    if not idx then return false end
    local newMain = rec.alts[idx]
    local oldMain = rec.mainToon
    if oldMain and oldMain ~= "" then
        rec.alts[idx] = oldMain -- old main takes the promoted alt's slot
    else
        table.remove(rec.alts, idx)
    end
    rec.mainToon = newMain
    ns.Credits_RebuildToonIndex()
    if ns.CreditsSync_Changed then
        ns.CreditsSync_Changed({ discordName }, nil)
    end
    return true, newMain
end

--------------------------------------------------------------------------
-- Discord name / Main / Alt (2026-09-29, Loopi). An account has ONE Discord
-- name (rec.discord - editable; the ledger key rec.discordName stays an
-- internal, never-renamed account id), exactly one main toon (always a real
-- character, never empty) and any number of alts. A name in the roster is
-- therefore one of: Discord only (rec.discord names no character on the
-- account), Main, Alt, Discord & Main, or Discord & Alt - derived by
-- comparing rec.discord with the toon list, nothing extra is stored.
-- rec.discord == "" means "no Discord name on file".
--------------------------------------------------------------------------
function ns.Credits_GetDiscord(rec)
    if type(rec) ~= "table" then return "" end
    if rec.discord == nil then return rec.discordName or "" end
    return rec.discord
end

-- Does `name` carry the account's Discord tag?
function ns.Credits_IsDiscordName(rec, name)
    local d = ns.Credits_GetDiscord(rec)
    return d ~= "" and type(name) == "string" and d:lower() == name:lower()
end

-- Canonical spelling + role ("main"/"alt") + alt index of `name` on `rec`.
local function ToonInRecord(rec, name)
    local key = name:lower()
    if rec.mainToon and rec.mainToon:lower() == key then return rec.mainToon, "main" end
    for i, a in ipairs(rec.alts or {}) do
        if a:lower() == key then return a, "alt", i end
    end
    return nil
end

-- The account's Discord name IF it is a Discord-only entry (names no
-- character on the account), else nil. Such a name is always a former alt
-- that "Discord Only" turned into a bare tag, so when it is displaced or
-- cleared it must not just vanish (2026-10-04, Loopi: Avrony, a real alt,
-- disappeared completely when another Discord name was set) - it goes to
-- the Review Queue like any other unlinked character.
local function DiscordOnlyName(rec)
    local d = ns.Credits_GetDiscord(rec)
    if d == "" then return nil end
    if ToonInRecord(rec, d) then return nil end
    return d
end

-- "Add as Discord": tags one of the account's characters as the Discord
-- name. There is only ever one, so any previous tag (on another character,
-- or a Discord-only name) is replaced. A displaced Discord-only name is
-- sent to the Review Queue; returns true, displacedName in that case.
function ns.Credits_SetDiscord(name)
    if not ns.CanManageCreditsConfigLocal() then return false end
    if not name or name == "" or not ns.creditsDb then return false end
    if not ns.creditsDb.toonIndex then ns.Credits_RebuildToonIndex() end
    local bare = ns.NormalizeName(name)
    local key = ns.creditsDb.toonIndex[bare:lower()]
    local rec = key and ns.creditsDb.ledger[key]
    if not rec then return false end
    local canon = ToonInRecord(rec, bare)
    if not canon then return false end
    if ns.Credits_IsDiscordName(rec, canon) then return false end
    local displaced = DiscordOnlyName(rec)
    rec.discord = canon
    local rqChanges
    if displaced then
        ns.Credits_AddToReviewQueue(displaced)
        rqChanges = { { name = displaced, present = true } }
    end
    if ns.CreditsSync_Changed then ns.CreditsSync_Changed({ key }, rqChanges) end
    return true, displaced
end

-- "Remove as Discord": clears the account's Discord name. Takes the ledger
-- key (not a character name) so it also works on a Discord-only entry,
-- which is not a character and so is not in toonIndex. A cleared
-- Discord-only name is NOT lost: it is sent to the Review Queue (returns
-- true, clearedName in that case), so no confirmation click is needed.
function ns.Credits_ClearDiscord(accountKey)
    if not ns.CanManageCreditsConfigLocal() then return false end
    local rec = ns.creditsDb and accountKey and ns.creditsDb.ledger[accountKey]
    if not rec then return false end
    if ns.Credits_GetDiscord(rec) == "" then return false end
    local displaced = DiscordOnlyName(rec)
    rec.discord = ""
    local rqChanges
    if displaced then
        ns.Credits_AddToReviewQueue(displaced)
        rqChanges = { { name = displaced, present = true } }
    end
    if ns.CreditsSync_Changed then ns.CreditsSync_Changed({ accountKey }, rqChanges) end
    return true, displaced
end

-- "Discord Only": the name is a Discord name, not a character. Removes it
-- from the account's alts (NOT sent to the Review Queue now - it is still
-- the account's Discord tag) and tags it as the account's Discord name.
-- If that tag is later replaced or cleared (Credits_SetDiscord /
-- Credits_ClearDiscord), the name goes to the Review Queue then.
-- Refused for the main: an account must always have a real main toon.
function ns.Credits_MakeDiscordOnly(name)
    if not ns.CanManageCreditsConfigLocal() then return false end
    if not name or name == "" or not ns.creditsDb then return false end
    if not ns.creditsDb.toonIndex then ns.Credits_RebuildToonIndex() end
    local bare = ns.NormalizeName(name)
    local key = ns.creditsDb.toonIndex[bare:lower()]
    local rec = key and ns.creditsDb.ledger[key]
    if not rec then return false end
    local canon, role, idx = ToonInRecord(rec, bare)
    if role ~= "alt" then return false end
    table.remove(rec.alts, idx)
    rec.discord = canon
    ns.creditsDb.toonIndex[canon:lower()] = nil
    if ns.CreditsSync_Changed then ns.CreditsSync_Changed({ key }, nil) end
    return true
end

-- Read-only lookup for UI (Review Queue tab) - which account's mainToon
-- currently claims altName as an ALT (never returns a name for its own
-- account's main toon - that's not what "linked as an alt" means here).
function ns.Credits_GetAltMain(altName)
    if not ns.creditsDb or not ns.creditsDb.toonIndex then return nil end
    if not altName or altName == "" then return nil end
    local key = ns.NormalizeName(altName):lower()
    local discordName = ns.creditsDb.toonIndex[key]
    if not discordName then return nil end
    local rec = ns.creditsDb.ledger[discordName]
    if not rec then return nil end
    if rec.mainToon and rec.mainToon:lower() == key then return nil end
    return rec.mainToon
end

--------------------------------------------------------------------------
-- Dynamic Review Queue (2026-09-25) - runtime additions layered on top
-- of the static, GENERATED ns.CreditsReviewQueue (ReviewQueue.lua, Step
-- 0's own unresolved-donor list). Only Credits_UnlinkAlt adds to this
-- today. Same row shape as a ReviewQueue.lua entry; rawGoldAmount is
-- always 0 here since per-alt gold isn't tracked at runtime (only Step
-- 0's offline contribution_data.csv has that breakdown) - "Set as New
-- Main" on a reopened entry seeds a 0 lifetime total until the next
-- real Step 0 pass recomputes it.
--------------------------------------------------------------------------
-- issue defaults to "removed_alt" (the only caller until CM4); CM4 adds
-- "unresolved_donor" for a sender whose donation is being held. details is
-- optional and replaces the default text.
function ns.Credits_AddToReviewQueue(altName, issue, details, latestOverride)
    if not ns.creditsDb then return end
    ns.creditsDb.dynamicReviewQueue = ns.creditsDb.dynamicReviewQueue or {}
    -- Keep whatever donation info we already know for this name (2026-09-29,
    -- Loopi: an unlinked alt came back "no date"). Prefer an existing runtime
    -- entry, else the shipped Step 0 row for the same name, else the
    -- per-character ToonDonations.lua table (alts that already resolved).
    local key = altName:lower()
    local latest, rawGold
    for _, rec in ipairs(ns.creditsDb.dynamicReviewQueue) do
        if (rec.name or ""):lower() == key then
            latest, rawGold = rec.latestDonation, rec.rawGoldAmount
            break
        end
    end
    if latest == nil then
        for _, rec in ipairs(ns.CreditsReviewQueue or {}) do
            if (rec.name or ""):lower() == key then
                latest, rawGold = rec.latestDonation, rec.rawGoldAmount
                break
            end
        end
    end
    if latest == nil then
        -- Last resort: the shipped per-character table (ToonDonations.lua)
        -- covers every alt that already resolved to a main.
        local td = ns.CreditsToonDonations and ns.CreditsToonDonations[key]
        if td then latest, rawGold = td[1], td[2] end
    end
    ns.Credits_RemoveFromReviewQueue(altName) -- no duplicate entries
    table.insert(ns.creditsDb.dynamicReviewQueue, {
        name = altName,
        issue = issue or "removed_alt",
        latestDonation = latestOverride or latest or "",
        rawGoldAmount = tonumber(rawGold) or 0,
        details = details or ((issue == "unresolved_donor")
            and "held donation - waiting for an officer to link this name"
            or "removed from an account by an officer - no historical gold figure available at runtime"),
    })
end

function ns.Credits_RemoveFromReviewQueue(altName)
    if not ns.creditsDb or not ns.creditsDb.dynamicReviewQueue then return end
    local key = altName:lower()
    for i, rec in ipairs(ns.creditsDb.dynamicReviewQueue) do
        if rec.name:lower() == key then
            table.remove(ns.creditsDb.dynamicReviewQueue, i)
            return
        end
    end
end

-- Merged Review Queue source (2026-09-25): the tab's data is the
-- static, GENERATED ns.CreditsReviewQueue (Step 0's own unresolved
-- list, ReviewQueue.lua) plus ns.creditsDb.dynamicReviewQueue (names
-- Credits_UnlinkAlt sent back here at runtime), deduped by lowercased
-- name with the dynamic entry winning - it reflects this client's
-- live state, the static list only as of Step 0's last run. One shared
-- function so CreditsConfig.lua's tab isn't the only place that knows
-- how to combine the two lists.
function ns.Credits_ReviewQueueRows()
    local rows, seen = {}, {}
    if ns.creditsDb and ns.creditsDb.dynamicReviewQueue then
        for _, rec in ipairs(ns.creditsDb.dynamicReviewQueue) do
            local key = (rec.name or ""):lower()
            if key ~= "" and not seen[key] then
                seen[key] = true
                table.insert(rows, rec)
            end
        end
    end
    if ns.CreditsReviewQueue then
        for _, rec in ipairs(ns.CreditsReviewQueue) do
            local key = (rec.name or ""):lower()
            if key ~= "" and not seen[key] then
                seen[key] = true
                table.insert(rows, rec)
            end
        end
    end
    return rows
end

--------------------------------------------------------------------------
-- Officers / config: local set + broadcast
--------------------------------------------------------------------------
local function ListContains(list, name)
    local norm = ns.NormalizeName(name)
    for _, n in ipairs(list) do
        if ns.NormalizeName(n) == norm then return true end
    end
    return false
end

local function AddToList(list, name)
    if not name or name == "" then return false end
    if ListContains(list, name) then return false end
    table.insert(list, name)
    return true
end

local function RemoveFromList(list, name)
    local norm = ns.NormalizeName(name)
    for i, n in ipairs(list) do
        if ns.NormalizeName(n) == norm then
            table.remove(list, i)
            return true
        end
    end
    return false
end

-- Every setter below: check permission, mutate ns.creditsDb, bump the
-- version stamp, broadcast. Returns true/false so callers (slash
-- commands today, a config UI later) can show a refusal.
-- 2026-09-28 (Chris): SetCreditsOfficers removed - the officer list is
-- DH-Bavin's shared one now (Core.lua's ns.SetEditors), not this file's.

function ns.SetCreditsMasterToggle(enabled)
    if not ns.CanManageCreditsTestConfigLocal() then return false end
    ns.creditsDb.masterToggle = enabled and true or false
    ns.creditsDb.configUpdatedAt = time()
    ns.Credits_BroadcastConfig()
    return true
end

function ns.AddCreditTestReceiver(name)
    if not ns.CanManageCreditsTestConfigLocal() then return false end
    if not AddToList(ns.creditsDb.creditTestReceivers, name) then return false end
    ns.creditsDb.configUpdatedAt = time()
    ns.Credits_BroadcastConfig()
    return true
end

function ns.RemoveCreditTestReceiver(name)
    if not ns.CanManageCreditsTestConfigLocal() then return false end
    if not RemoveFromList(ns.creditsDb.creditTestReceivers, name) then return false end
    ns.creditsDb.configUpdatedAt = time()
    ns.Credits_BroadcastConfig()
    return true
end

function ns.AddCreditTestSender(name)
    if not ns.CanManageCreditsTestConfigLocal() then return false end
    if not AddToList(ns.creditsDb.creditTestSenders, name) then return false end
    ns.creditsDb.configUpdatedAt = time()
    ns.Credits_BroadcastConfig()
    return true
end

function ns.RemoveCreditTestSender(name)
    if not ns.CanManageCreditsTestConfigLocal() then return false end
    if not RemoveFromList(ns.creditsDb.creditTestSenders, name) then return false end
    ns.creditsDb.configUpdatedAt = time()
    ns.Credits_BroadcastConfig()
    return true
end

-- 2026-09-28 (Chris): the old single SetCreditsMultiplier(value) is now
-- two ratio setters, each taking an X/Y pair ("x Credits = y Rep
-- Points" / "x Rep = y Gold") instead of one decimal. Both positive
-- integers/numbers, no requirement that they reconcile with each other
-- or with DH-Store's own creditGoldRatio - Chris's explicit call.
-- 2026-10-04 (Loopi): both ratio setters are gated by
-- CanManageCreditsRatesLocal (author / guild leader / recipient) and
-- broadcast ONLY the rates (RATESET, own ratesUpdatedAt) - never the
-- master toggle or test lists, which stay author-only in CFGSET.
function ns.SetCreditsPerRep(x, y)
    if not ns.CanManageCreditsRatesLocal() then return false end
    local nx, ny = tonumber(x), tonumber(y)
    if not nx or nx <= 0 or not ny or ny <= 0 then return false end
    ns.creditsDb.creditsPerRep = { x = nx, y = ny }
    ns.creditsDb.ratesUpdatedAt = math.max(time(), (ns.creditsDb.ratesUpdatedAt or 0) + 1)
    ns.Credits_BroadcastRates()
    return true
end

function ns.SetRepPerGold(x, y)
    if not ns.CanManageCreditsRatesLocal() then return false end
    local nx, ny = tonumber(x), tonumber(y)
    if not nx or nx <= 0 or not ny or ny <= 0 then return false end
    ns.creditsDb.repPerGold = { x = nx, y = ny }
    ns.creditsDb.ratesUpdatedAt = math.max(time(), (ns.creditsDb.ratesUpdatedAt or 0) + 1)
    ns.Credits_BroadcastRates()
    return true
end

--------------------------------------------------------------------------
-- Sync: own prefix (DHBavinCreditsV2 as of 2026-09-28), isolated from
-- Sync.lua's DHBavinV4
--------------------------------------------------------------------------
-- PROTOCOL (guild-only, no RAID/PARTY fallback - same as Sync.lua):
--   CFGSET|toggle(0/1)|receiversCSV|sendersCSV|crX|crY|rgX|rgY|updatedAt
--       - full-replace broadcast of everything this file owns (Wall 2/3
--         config: toggle, test lists, Credit/Rep ratio crX/crY,
--         Rep/Gold ratio rgX/rgY), sent by the setters above AFTER
--         their own permission gate has already passed. Applied by a
--         receiver only if updatedAt is strictly newer than its own AND
--         the sender is guild-leader-or-officer verified (see
--         IsAuthorizedConfigSender above) - last-writer-wins, same
--         idiom as Core.lua's k-0019 fix. 2026-09-28 (Chris): dropped
--         officersCSV (officer list is DH-Bavin's shared EDITORS
--         broadcast now) and replaced the single multiplier field with
--         the two ratio pairs - non-additive shape change, hence the
--         V1->V2 prefix bump below.
--   CREDITSYNCREQ             - "send me current config"
--                                (unconditional - same GATING philosophy
--                                as Sync.lua's SYNCREQ)
--   CREDITSYNCDATA|<same payload as CFGSET>
--                             - WHISPERed reply to CREDITSYNCREQ
--   RATESET|crX|crY|rgX|rgY|ratesUpdatedAt   (2026-10-04, additive)
--                             - the two ratios only, own timestamp. The
--                               crX..rgY fields inside CFGSET are now
--                               ignored by receivers. Accepted only from
--                               the author / guild leader / recipient.
--                               Also WHISPERed in reply to CREDITSYNCREQ
--                               by clients whose player may set rates.
--
-- STANDING RULE (mirrors Sync.lua's k-0009 comment): bump this suffix
-- any time this wire format changes non-additively - a receiver on the
-- wrong prefix version simply never gets these messages, never
-- misparses them.
local PREFIX = "DHBavinCreditsV2"

local function AddonSendMessage(text, channel, target)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, text, channel, target)
    elseif SendAddonMessage then
        SendAddonMessage(PREFIX, text, channel, target)
    end
end

-- Shared with CreditsSync.lua (CM3), which loads after this file.
ns.Credits_SendAddon = AddonSendMessage

local function RegisterPrefix()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    elseif RegisterAddonMessagePrefix then
        pcall(RegisterAddonMessagePrefix, PREFIX)
    end
end

local function SyncChannel()
    if IsInGuild and IsInGuild() then return "GUILD" end
    return nil
end

local function SplitCSV(s)
    local t = {}
    if s and s ~= "" then
        for name in s:gmatch("[^,]+") do table.insert(t, name) end
    end
    return t
end

local function EncodeConfig()
    return table.concat({
        ns.creditsDb.masterToggle and "1" or "0",
        table.concat(ns.creditsDb.creditTestReceivers, ","),
        table.concat(ns.creditsDb.creditTestSenders, ","),
        tostring(ns.creditsDb.creditsPerRep.x),
        tostring(ns.creditsDb.creditsPerRep.y),
        tostring(ns.creditsDb.repPerGold.x),
        tostring(ns.creditsDb.repPerGold.y),
        tostring(ns.creditsDb.configUpdatedAt),
    }, "|")
end

-- Anchored pattern, same discipline as Sync.lua's PTSSET decode (see its
-- k-0009 comment) - a shape change here must bump PREFIX, never just
-- silently add a field and hope an old client's anchored match degrades
-- gracefully (it wouldn't: it would just fail to match at all, which is
-- actually the SAFE failure mode this pattern is chosen for).
local function ApplyIncomingConfig(payload, senderShort)
    if not IsAuthorizedConfigSender(senderShort) then return end
    local toggleFlag, receiversCSV, sendersCSV, crXStr, crYStr, rgXStr, rgYStr, updatedAtStr =
        payload:match("^([01])|(.-)|(.-)|([%d%.]+)|([%d%.]+)|([%d%.]+)|([%d%.]+)|(%d+)$")
    if not toggleFlag then return end
    local updatedAt = tonumber(updatedAtStr) or 0
    if updatedAt <= (ns.creditsDb.configUpdatedAt or 0) then return end
    ns.creditsDb.masterToggle = (toggleFlag == "1")
    ns.creditsDb.creditTestReceivers = SplitCSV(receiversCSV)
    ns.creditsDb.creditTestSenders = SplitCSV(sendersCSV)
    -- 2026-10-04 (Loopi): the rate fields (crX..rgY) are still on the wire
    -- for shape compatibility but are IGNORED here - rates travel only in
    -- RATESET, which has its own, tighter sender check.
    ns.creditsDb.configUpdatedAt = updatedAt
    ns.Credits_EvaluateArming() -- config just changed - re-check Wall 4
    -- Live-refresh CreditsConfig.lua's window if an officer has it open
    -- and someone else's change just landed - guarded, since that file
    -- loads after this one and the window may never have been opened.
    if ns.CreditsConfig_Refresh then ns.CreditsConfig_Refresh() end
end

function ns.Credits_BroadcastConfig()
    local channel = SyncChannel()
    if not channel then return end
    AddonSendMessage("CFGSET|" .. EncodeConfig(), channel)
end

-- RATESET|crX|crY|rgX|rgY|ratesUpdatedAt (2026-10-04, Loopi). Additive
-- message type on the same prefix. Accepted ONLY from the author (all
-- characters), the guild leader or the donation recipient - checked on
-- the sender name, never on a claim inside the message. A relay by an
-- officer who is not one of those is deliberately rejected, so only the
-- authorised setters' own clients ever seed rates (see the
-- CREDITSYNCREQ reply below).
local function EncodeRates()
    return table.concat({
        tostring(ns.creditsDb.creditsPerRep.x),
        tostring(ns.creditsDb.creditsPerRep.y),
        tostring(ns.creditsDb.repPerGold.x),
        tostring(ns.creditsDb.repPerGold.y),
        tostring(ns.creditsDb.ratesUpdatedAt or 0),
    }, "|")
end

local function ApplyIncomingRates(payload, senderShort)
    if not IsRatesSetterName(senderShort) then return end
    local crXStr, crYStr, rgXStr, rgYStr, updatedAtStr =
        payload:match("^([%d%.]+)|([%d%.]+)|([%d%.]+)|([%d%.]+)|(%d+)$")
    if not crXStr then return end
    local updatedAt = tonumber(updatedAtStr) or 0
    if updatedAt <= (ns.creditsDb.ratesUpdatedAt or 0) then return end
    local crX, crY, rgX, rgY = tonumber(crXStr), tonumber(crYStr), tonumber(rgXStr), tonumber(rgYStr)
    if not crX or crX <= 0 or not crY or crY <= 0 or not rgX or rgX <= 0 or not rgY or rgY <= 0 then return end
    ns.creditsDb.creditsPerRep = { x = crX, y = crY }
    ns.creditsDb.repPerGold = { x = rgX, y = rgY }
    ns.creditsDb.ratesUpdatedAt = updatedAt
    if ns.CreditsConfig_Refresh then ns.CreditsConfig_Refresh() end
end

function ns.Credits_BroadcastRates()
    local channel = SyncChannel()
    if not channel then return end
    AddonSendMessage("RATESET|" .. EncodeRates(), channel)
end

-- Called from this file's own PLAYER_LOGIN handler below - unconditional,
-- same GATING philosophy as Sync.lua's own SYNCREQ (fires regardless of
-- the local player's role; the receive side is what's permission-gated).
function ns.Credits_Init()
    RegisterPrefix()
    local channel = SyncChannel()
    if channel then
        AddonSendMessage("CREDITSYNCREQ", channel)
    end
end

-- Registered from this file's own CHAT_MSG_ADDON handler (Credits.lua
-- listens independently rather than piggybacking on Core.lua's frame -
-- keeps Wall 1's "removable by deleting one file" property literal).
function ns.Credits_OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX then return end
    if not ns.creditsDb then return end
    local myName = UnitName("player")
    local senderShort = ns.NormalizeName(sender)
    if senderShort == myName then return end -- ignore our own echo

    local msgType, rest = message:match("^([^|]+)|?(.*)$")
    if msgType == "CFGSET" then
        ApplyIncomingConfig(rest, senderShort)
    elseif msgType == "CREDITSYNCREQ" then
        -- Reply only if we actually have something worth sending - avoids
        -- two fresh installs whispering empty config back and forth.
        if (ns.creditsDb.configUpdatedAt or 0) > 0 then
            AddonSendMessage("CREDITSYNCDATA|" .. EncodeConfig(), "WHISPER", sender)
        end
        -- Rates: only a client whose own player may set them replies (the
        -- receiver rejects RATESET from anyone else anyway).
        if (ns.creditsDb.ratesUpdatedAt or 0) > 0 and IsRatesSetterName(myName) then
            AddonSendMessage("RATESET|" .. EncodeRates(), "WHISPER", sender)
        end
    elseif msgType == "CREDITSYNCDATA" then
        ApplyIncomingConfig(rest, senderShort)
    elseif msgType == "RATESET" then
        ApplyIncomingRates(rest, senderShort)
    elseif msgType == "LSYNCREQ" or msgType == "LSYNCDATA" then
        -- CM3 officer ledger sync (CreditsSync.lua). Additive message types
        -- on this same prefix; guarded because the file loads after this one.
        if ns.CreditsSync_OnMessage then
            ns.CreditsSync_OnMessage(msgType, rest, sender, senderShort)
        end
    end
end

--------------------------------------------------------------------------
-- Wall 4: lazy arming check + no-op hook stubs
--------------------------------------------------------------------------
-- Evaluated at PLAYER_LOGIN (character name isn't reliably known at
-- addon load - same reasoning as Sync.lua's Sync_Init timing) AND again
-- whenever config changes (ApplyIncomingConfig above). Two independent
-- conditions must BOTH be true: masterToggle ON AND this character on
-- the list for that specific hook. Removing a name disarms the checked
-- flag immediately, but un-hooking a live SendMailFrame/inbox hook isn't
-- reliable in this API - a full disarm needs /reload (design doc states
-- this plainly; not attempting to work around it).
ns.creditsArmedInbox = false
ns.creditsArmedOutgoing = false

local function NameOnList(list, name)
    local norm = ns.NormalizeName(name)
    for _, n in ipairs(list or {}) do
        if ns.NormalizeName(n) == norm then return true end
    end
    return false
end

-- Two hook-installation sites (design doc: Wall 4). The outgoing one is
-- still a no-op until CM5.
-- CM4: the real inbox hook lives in CreditsInbox.lua and is created ONLY
-- from here (Wall 4) - a character that isn't on creditTestReceivers with
-- the master toggle on never runs a line of it.
local function InstallInboxHook()
    if ns.CreditsInbox_Install then
        ns.CreditsInbox_Install()
        ns.CreditsPrint("[TEST] Inbox credit hook armed for " .. UnitName("player") .. ".")
    else
        ns.CreditsPrint("[TEST] Inbox credit hook NOT installed - CreditsInbox.lua isn't loaded.")
    end
end

local function InstallOutgoingHook()
    ns.CreditsPrint("[TEST] Outgoing credit hook armed for " .. UnitName("player") .. " (no-op until CM5).")
end

function ns.Credits_EvaluateArming()
    if not ns.creditsDb then return end
    local myName = UnitName("player")
    if not ns.creditsDb.masterToggle then
        ns.creditsArmedInbox = false
        ns.creditsArmedOutgoing = false
        return
    end
    if NameOnList(ns.creditsDb.creditTestReceivers, myName) and not ns.creditsArmedInbox then
        ns.creditsArmedInbox = true
        InstallInboxHook()
    end
    if NameOnList(ns.creditsDb.creditTestSenders, myName) and not ns.creditsArmedOutgoing then
        ns.creditsArmedOutgoing = true
        InstallOutgoingHook()
    end
end

--------------------------------------------------------------------------
-- Mid-testing reset utility
--------------------------------------------------------------------------
-- Wipes the test-scoped credit data (ledger, alt-override table,
-- transaction log) back to empty - callable at any point during CM2-CM8
-- testing, distinct from CM9's cutover flip and Step 9.5's full reseed.
-- LOCAL only for CM1: each Distribution Officer/Bavin runs this on their
-- own client. No broadcast yet - CM3 hasn't defined the ledger sync wire
-- format this would need to ride, so this deliberately doesn't guess at
-- one; officers coordinate a reset verbally during the test phase.
function ns.Credits_ResetTestData()
    if not ns.CanManageCreditsConfigLocal() then return false end
    ns.creditsDb.ledger = {}
    ns.creditsDb.toonIndex = {}
    ns.creditsDb.dynamicReviewQueue = {}
    ns.creditsDb.transactionLog = {}
    ns.creditsDb.rqStamps = {}    -- CM3 review-queue sync stamps (local reset, like the rest)
    ns.creditsDb.lastSyncAt = 0
    -- CM4: held (pending) credits and the merge/release tombstones are test
    -- data too.
    ns.creditsDb.pendingCredits = {}
    ns.creditsDb.pendingReleased = {}
    ns.creditsDb.ledgerTombstones = {}
    ns.CreditsPrint("Test credit data wiped (ledger, toon index, dynamic review queue, held credits, transaction log).")
    return true
end

--------------------------------------------------------------------------
-- Event wiring
--------------------------------------------------------------------------
-- Own frame, independent of Core.lua's (see file header: Wall 1 means
-- this whole feature is removable by deleting this one file).
ns.creditsFrame = CreateFrame("Frame")
ns.creditsFrame:RegisterEvent("PLAYER_LOGIN")
ns.creditsFrame:RegisterEvent("CHAT_MSG_ADDON")
ns.creditsFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
ns.creditsFrame:SetScript("OnEvent", function(_, event, ...)
    if not DHTools.IsModuleEnabled("bavin") then return end
    if event == "PLAYER_LOGIN" then
        ns.InitCreditsDB()
        ns.Credits_Init()
        ns.Credits_EvaluateArming()
        if ns.CreditsSync_OnLogin then ns.CreditsSync_OnLogin() end
        -- CM4: release held donations whose sender resolves by now. Delayed
        -- so the guild roster (used to resolve guild members) has loaded.
        if ns.Credits_ReleasePending and C_Timer and C_Timer.After then
            C_Timer.After(12, function() ns.Credits_ReleasePending() end)
        end
    elseif event == "CHAT_MSG_ADDON" then
        ns.Credits_OnAddonMessage(...)
    elseif event == "GUILD_ROSTER_UPDATE" then
        if ns.CreditsSync_OnRosterUpdate then ns.CreditsSync_OnRosterUpdate() end
        -- Cheap no-op unless this is the recipient with something held.
        if ns.Credits_ReleasePending then ns.Credits_ReleasePending() end
    end
end)

--------------------------------------------------------------------------
-- Slash command surface (dispatched from Core.lua's /dhb, "credits" cmd)
--------------------------------------------------------------------------
-- 2026-09-25 update: the real UI now exists - CreditsConfig.lua's
-- standalone "Bavin Rep & Credit Config" window, opened via a button in
-- DH-Tools\Config.lua's existing Bavin officer section (Chris: the
-- existing page "should basically remain the same" - just add an open
-- button, don't rebuild it inline). These slash commands are NOT
-- removed - they're a useful scriptable/diagnostic fallback - but the
-- window is now the primary interface for everyday use.
local function ShowCreditsStatus()
    if not ns.creditsDb then
        ns.CreditsPrint("Not initialized yet.")
        return
    end
    ns.CreditsPrint("Master toggle: " .. (ns.creditsDb.masterToggle and "|cff33ff33ON|r" or "|cffff3333OFF|r"))
    ns.CreditsPrint("Credit/Rep ratio: " .. ns.creditsDb.creditsPerRep.x .. " Credits = " .. ns.creditsDb.creditsPerRep.y .. " Rep Points")
    ns.CreditsPrint("Rep/Gold ratio: " .. ns.creditsDb.repPerGold.x .. " Rep = " .. ns.creditsDb.repPerGold.y .. " Gold (*not used currently)")
    ns.CreditsPrint("Officers: shared list, managed on the Officer Settings page")
    ns.CreditsPrint("Test receivers (inbox hook): " .. (#ns.creditsDb.creditTestReceivers > 0 and table.concat(ns.creditsDb.creditTestReceivers, ", ") or "none"))
    ns.CreditsPrint("Test senders (outgoing hook): " .. (#ns.creditsDb.creditTestSenders > 0 and table.concat(ns.creditsDb.creditTestSenders, ", ") or "none"))
    ns.CreditsPrint("This character armed: inbox=" .. tostring(ns.creditsArmedInbox) .. " outgoing=" .. tostring(ns.creditsArmedOutgoing))
end

-- rest is everything after "credits " in "/dhb credits <rest>".
function ns.Credits_HandleSlash(rest)
    rest = rest or ""
    local sub, arg1, arg2 = rest:match("^(%S*)%s*(%S*)%s*(.-)$")
    sub = (sub or ""):lower()

    if sub == "" or sub == "status" then
        ShowCreditsStatus()
    elseif sub == "window" or sub == "config" then
        if ns.CreditsConfig_Toggle then
            ns.CreditsConfig_Toggle()
        else
            ns.CreditsPrint("CreditsConfig.lua isn't loaded.")
        end
    elseif sub == "log" or sub == "audit" then
        -- 2026-10-04: opens the config window straight on the Audit Log tab.
        if ns.CreditsConfig_Open and ns.CreditsConfig_SelectTab then
            ns.CreditsConfig_Open()
            ns.CreditsConfig_SelectTab("audit")
        else
            ns.CreditsPrint("CreditsConfig.lua isn't loaded.")
        end
    elseif sub == "toggle" then
        if arg1 ~= "on" and arg1 ~= "off" then
            ns.CreditsPrint("Usage: /dhb credits toggle on|off")
        elseif ns.SetCreditsMasterToggle(arg1 == "on") then
            ns.CreditsPrint("Master toggle set to " .. arg1:upper() .. ".")
        else
            ns.CreditsPrint("Refused - Distribution Officer only.")
        end
    elseif sub == "creditsperrep" then
        local x, y = arg1, arg2
        if x == "" or y == "" then
            ns.CreditsPrint("Usage: /dhb credits creditsperrep <X> <Y>  (means X Credits = Y Rep Points). Current: " ..
                ns.creditsDb.creditsPerRep.x .. " Credits = " .. ns.creditsDb.creditsPerRep.y .. " Rep Points.")
        elseif ns.SetCreditsPerRep(x, y) then
            ns.CreditsPrint("Credit/Rep ratio set to " .. x .. " Credits = " .. y .. " Rep Points.")
        else
            ns.CreditsPrint("Refused - both must be positive numbers, or you're not the author, guild leader or donation recipient.")
        end
    elseif sub == "reppergold" then
        local x, y = arg1, arg2
        if x == "" or y == "" then
            ns.CreditsPrint("Usage: /dhb credits reppergold <X> <Y>  (means X Rep = Y Gold; not used by anything yet). Current: " ..
                ns.creditsDb.repPerGold.x .. " Rep = " .. ns.creditsDb.repPerGold.y .. " Gold.")
        elseif ns.SetRepPerGold(x, y) then
            ns.CreditsPrint("Rep/Gold ratio set to " .. x .. " Rep = " .. y .. " Gold (not used by anything yet).")
        else
            ns.CreditsPrint("Refused - both must be positive numbers, or you're not the author, guild leader or donation recipient.")
        end
    elseif sub == "reset" then
        if arg1 ~= "confirm" then
            ns.CreditsPrint("This wipes ALL test credit data (ledger, alt overrides, transaction log). Run '/dhb credits reset confirm' to proceed.")
        elseif ns.Credits_ResetTestData() then
            -- ns.Credits_ResetTestData already prints confirmation.
        else
            ns.CreditsPrint("Refused - Distribution Officer only.")
        end

    -- 2026-09-28 (Chris): "/dhb credits officer add|remove" removed -
    -- the officer list is DH-Bavin's shared one now, managed on the
    -- Officer Settings page (there is no slash command for it).

    elseif sub == "receiver" then
        if arg1 == "add" and arg2 ~= "" then
            if ns.AddCreditTestReceiver(arg2) then
                ns.CreditsPrint("Added " .. arg2 .. " to creditTestReceivers (inbox hook).")
            else
                ns.CreditsPrint("Refused, or already on the list - Distribution Officer only.")
            end
        elseif arg1 == "remove" and arg2 ~= "" then
            if ns.RemoveCreditTestReceiver(arg2) then
                ns.CreditsPrint("Removed " .. arg2 .. " from creditTestReceivers. Full disarm needs /reload on that character.")
            else
                ns.CreditsPrint("Refused, or not on the list - Distribution Officer only.")
            end
        else
            ns.CreditsPrint("Usage: /dhb credits receiver add|remove <name>")
        end
    elseif sub == "sender" then
        if arg1 == "add" and arg2 ~= "" then
            if ns.AddCreditTestSender(arg2) then
                ns.CreditsPrint("Added " .. arg2 .. " to creditTestSenders (outgoing hook).")
            else
                ns.CreditsPrint("Refused, or already on the list - Distribution Officer only.")
            end
        elseif arg1 == "remove" and arg2 ~= "" then
            if ns.RemoveCreditTestSender(arg2) then
                ns.CreditsPrint("Removed " .. arg2 .. " from creditTestSenders. Full disarm needs /reload on that character.")
            else
                ns.CreditsPrint("Refused, or not on the list - Distribution Officer only.")
            end
        else
            ns.CreditsPrint("Usage: /dhb credits sender add|remove <name>")
        end
    else
        ns.CreditsPrint("Unknown: /dhb credits " .. rest)
        ns.CreditsPrint("Commands: window (opens the config UI), status, toggle on|off, multiplier <n>, officer add|remove <name>, receiver add|remove <name>, sender add|remove <name>, reset confirm")
    end
end
