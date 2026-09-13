-- DH-Tools: Modules\DHBavin\Core.lua
-- "Bavin" module - lets the guild's designated mail collector (or
-- guild-leader-delegated editors) publish a priority want-list; matching
-- items get highlighted in every guildmate's bags plus a mailbox helper
-- to send them. See claude\DH-Bavin\PROFILE.md and this folder's
-- DH-Bavin-Design.md for the full concept and 6-milestone plan.
--
-- MILESTONE 1: guild-roster-verified guild-leader permission check
-- (rankIndex 0), RECIPIENT/EDITORS local storage, config page.
--
-- MILESTONE 2 (this file's networking bits moved OUT to Sync.lua): full
-- guild sync protocol - see Sync.lua's header for the wire format.
-- RECIPIENT/EDITORS sending now goes through Sync.lua's broadcast
-- functions instead of this file talking to C_ChatInfo directly, and
-- CHAT_MSG_ADDON/PLAYER_LOGIN below call into Sync.lua's entry points
-- (ns.Sync_OnAddonMessage/ns.Sync_Init) - same split DH-Quests' own
-- Core.lua/Sync.lua use. No bag hook or mailbox hook yet (M5).
--
-- Ships as a normal DH-Tools module (DHTools.RegisterModule), unlike
-- DH-Quests: no standalone-spinoff scaffolding. SavedVariables live in
-- their own top-level DHBavinDB (plain, account-wide - see ns.InitDB's
-- comment below for why this changed 2026-07-29 from the originally
-- decided DHToolsDB.bavin sub-table), see PROFILE.md.

local DHTools = DHTools
DHTools.Bavin = DHTools.Bavin or {}
local ns = DHTools.Bavin

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99DH-Bavin:|r " .. msg)
end

-- 2026-07-29: ns.db is DHBavinDB, its own top-level SavedVariables (see
-- DH-Tools.toc) - NOT DHToolsDB.bavin anymore, and deliberately plain
-- SavedVariables, not SavedVariablesPerCharacter. Recipient/editors are a
-- GUILD-wide setting, not a per-character preference the way Mob
-- Marker's icon list is - the old per-character scope (DHToolsDB.bavin)
-- meant switching characters, or logging a fresh alt, showed an empty
-- recipient/editor list even though it had just been set on another
-- character, with nothing to restore it short of some other guildmate
-- happening to be online to answer this client's SYNCREQ. This is
-- exactly the symptom Loopi hit 2026-07-29. DHBavinDB is shared by every
-- character on THIS WoW account, so that specific case no longer
-- depends on sync at all. Getting the guild leader's setting onto every
-- OTHER guildmate's own computer (a different account entirely) is
-- still, and can only be, the SYNCREQ/SYNCDATA handshake's job (see
-- Sync.lua) - that part remains unverified in real two-player testing,
-- see STATUS.md.
function ns.InitDB()
    DHTools.InitDB() -- still needed: module enable/disable state (per-
                      -- character, intentionally - see PROFILE.md) lives
                      -- in DHToolsDB.modules, unrelated to this DB.
    if type(DHBavinDB) ~= "table" then
        DHBavinDB = {}
    end
    ns.db = DHBavinDB
    if type(ns.db.editors) ~= "table" then
        ns.db.editors = {}
    end
    if type(ns.db.itemPointsOverrides) ~= "table" then
        ns.db.itemPointsOverrides = {}
    end
    -- 2026-08-24 (Loopi): chat-link mouseover tooltip preview, default
    -- ON - a per-account preference (this DB, not DHToolsDB), see
    -- Tooltip.lua's "Path 3" section. `== nil` (not `or true`) so an
    -- explicit false a player already saved stays false across logins.
    if ns.db.mouseoverChatTooltips == nil then
        ns.db.mouseoverChatTooltips = true
    end
    -- 2026-08-05: the priority want-list itself now persists too. Until
    -- now ns.priorityList (Sync.lua) was PURE runtime state - never
    -- written into DHBavinDB at all - rebuilt every login only from live
    -- ITEM/ITEMGONE broadcasts and a SYNCREQ/SYNCDATA round-trip with
    -- whoever else happened to be online. If nobody else was online (or
    -- the addon broke across an update), the list had no durable copy to
    -- fall back to. Fixed by pointing ns.priorityList AT
    -- ns.db.priorityList - the SAME table object, not a copy - so every
    -- existing AddItem/RemoveItem/SYNCDATA mutation site (all of which
    -- write through ns.priorityList[name] = ... in place, never
    -- reassign the whole table - verified before making this change)
    -- keeps working completely unmodified and just happens to now also
    -- be durable, exactly like itemPointsOverrides already was. See
    -- claude\knowledge\k-0008-bavin-priority-list-was-never-persisted.md.
    if type(ns.db.priorityList) ~= "table" then
        ns.db.priorityList = {}
    end
    ns.priorityList = ns.db.priorityList
    -- k-0012 (2026-08-05): the list's own version stamp (wall-clock
    -- time(), not GetTime() - must be comparable across logins/clients).
    -- Lets Sync.lua's SYNCDATA receipt tell whether an incoming snapshot
    -- is actually newer than ours before overwriting anything - see
    -- Sync.lua's PREFIX-bump comment and the SYNCDATA handler itself.
    if type(ns.db.priorityListUpdatedAt) ~= "number" then
        ns.db.priorityListUpdatedAt = 0
    end
    -- k-0019 (2026-08-06): same version-stamp idiom as
    -- priorityListUpdatedAt above, but for recipient/editors, which
    -- previously had NONE - Sync.lua's SYNCDATA handler blindly
    -- overwrote ns.db.recipient/ns.db.editors with whatever the first
    -- answering peer sent, with no way to tell a genuinely newer local
    -- change from a stale reply. Bumped by SetRecipient/SetEditors (this
    -- file), by PruneDepartedRecipientEditors below (a real local-roster-
    -- driven change), and by Sync.lua's own RECIPIENT/EDITORS live-
    -- broadcast receipt - see Sync.lua's SYNCDATA branch for the
    -- strictly-newer gate this enables.
    if type(ns.db.recipientEditorsUpdatedAt) ~= "number" then
        ns.db.recipientEditorsUpdatedAt = 0
    end
    -- One-time migration: carry forward anything already saved under the
    -- old per-character location so this character's own prior test data
    -- (recipient/editors set before this fix) isn't lost by the move.
    local oldDb = DHTools.db and DHTools.db.bavin
    if type(oldDb) == "table" then
        if ns.db.recipient == nil and oldDb.recipient then
            ns.db.recipient = oldDb.recipient
        end
        if #ns.db.editors == 0 and oldDb.editors and #oldDb.editors > 0 then
            ns.db.editors = oldDb.editors
        end
    end
    -- ns.db.recipient stays nil until the guild leader sets one - the
    -- module is inert (no highlighting/mailbox helper, once those land in
    -- M5) until then, per Design doc's "Recipient designation" section.
end

--------------------------------------------------------------------------
-- Guild roster cache (rankIndex-aware)
--------------------------------------------------------------------------
-- Mirrors DH-Air/DH-Quests' own Core.lua roster-cache pattern
-- (normalizedName -> {...}), extended with rankIndex - unlike either of
-- those modules, Bavin's permission model needs to know who's rank 0
-- (Guild Master). Rebuilt on GUILD_ROSTER_UPDATE.
ns.guildRoster = ns.guildRoster or {}

local function NormalizeName(name)
    return name and name:match("^([^-]+)") or name
end
ns.NormalizeName = NormalizeName

-- 2026-08-06 (k-0019): every check in this file used to assume "the
-- local character is in SOME guild" means "the local character is in
-- Death Happens" - IsInGuild()/GetGuildRosterInfo() say nothing about
-- WHICH guild, they just report whatever guild (if any) the current
-- character happens to belong to. A character on a DIFFERENT guild (or
-- Loopi's own author account on an alt not in Death Happens) would
-- build ns.guildRoster from that OTHER guild's member list, and every
-- real Death Happens recipient/editor name would then look like it
-- "isn't a guild member" - which is exactly what tripped
-- PruneDepartedRecipientEditors into wiping account-wide DHBavinDB from
-- an off-guild character. Every local-authority entry point in this
-- file now requires ns.IsInTargetGuild() first, INCLUDING the author-
-- account override (Loopi's own off-guild alts must not get admin
-- powers here either) - see claude\knowledge\k-0019 for the full
-- writeup. Deliberately hardcoded, not configurable - this addon is
-- built for one specific guild.
local TARGET_GUILD_NAME = "Death Happens"

function ns.IsInTargetGuild()
    if not IsInGuild or not IsInGuild() then return false end
    local guildName = GetGuildInfo and GetGuildInfo("player")
    return guildName == TARGET_GUILD_NAME
end

function ns.RequestGuildRoster()
    if not IsInGuild() then return end
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        pcall(C_GuildInfo.GuildRoster)
    elseif GuildRoster then
        pcall(GuildRoster)
    end
end

-- 2026-08-06 (k-0019): only ever populated from Death Happens' own
-- roster now - an off-guild (or wrong-guild) character's cache stays
-- empty, which makes IsGuildMember fail closed for everyone and (via
-- PruneDepartedRecipientEditors' existing "empty roster" guard) stops
-- that function from ever mistaking a foreign guild's roster for a mass
-- departure.
function ns.UpdateGuildRosterCache()
    for k in pairs(ns.guildRoster) do ns.guildRoster[k] = nil end
    if not ns.IsInTargetGuild() then return end

    local numMembers = GetNumGuildMembers and GetNumGuildMembers() or 0
    for i = 1, numMembers do
        local name, _, rankIndex, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if name then
            ns.guildRoster[NormalizeName(name)] = { online = (isOnline == true), rankIndex = rankIndex }
        end
    end
end

-- Sorted list of every known guild member's normalized name (online or
-- offline both included) - feeds the recipient dropdown and editor
-- picker, per Design doc's "online or offline both selectable" note.
function ns.GetRosterNames()
    local names = {}
    for name in pairs(ns.guildRoster) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

--------------------------------------------------------------------------
-- Permission model
--------------------------------------------------------------------------
-- 2026-08-05 (Loopi): TESTING_ALLOW_ANYONE_TO_MANAGE removed - it used to
-- bypass every guild-leader check below (both CanManageRecipient's local
-- gate AND Sync.lua's receive-side verification of incoming
-- RECIPIENT/EDITORS messages) so testing wasn't blocked on real guild
-- rank. That bypass is gone; the two gates below (CanManageRecipient,
-- CanManageEditors) are real enforcement now, not a test stand-in. If a
-- bypass is ever needed again for testing, add it back deliberately
-- rather than reintroducing a standing "anyone can manage" global.

-- Named full-permission override, mirroring DH-Air's own Core.lua
-- FULL_PERMISSION_OVERRIDE_NAME idiom - Loopidot always counts as fully
-- authorized for every Bavin permission gate, independent of actual
-- guild rank or roster membership. Meant to stick around (Loopi authors
-- as Loopi/plays Loopidot). Referenced directly by CanSetRecipientName/
-- CanSetEditorsName below (both name-based, so Sync.lua's RECEIVE-SIDE
-- verification of incoming RECIPIENT/EDITORS broadcasts honors it too,
-- never trusting a self-asserted claim in the message itself - same
-- idiom DH-Air's UnitHasAuthority/IsGuildOfficer use for their own
-- Loopidot override).
local FULL_PERMISSION_OVERRIDE_NAME = "Loopidot"

-- True only if `name` is verifiably rankIndex 0 (Guild Master) in THIS
-- client's own guild roster cache right now - never trusts a
-- self-asserted claim in a network message. Fails CLOSED (false) if the
-- roster hasn't loaded or the name isn't a known member: an unverifiable
-- admin action should be refused, not allowed through - unlike DH-Air's
-- IsGuildMember, which fails open for its own lower-stakes purpose.
function ns.IsGuildLeader(name)
    if not name then return false end
    if FULL_PERMISSION_OVERRIDE_NAME and NormalizeName(name) == FULL_PERMISSION_OVERRIDE_NAME then
        return true
    end
    local entry = ns.guildRoster[NormalizeName(name)]
    return entry ~= nil and entry.rankIndex == 0
end

-- 2026-08-05 (Loopi): recipient assignment is deliberately tighter than
-- "guild leader" - only Bavin (the character this whole module exists
-- to serve) or Loopidot may (re)designate who the recipient is, by name,
-- not by rank. Even a real rank-0 guild leader who isn't one of these
-- two is refused. Name-based (like IsGuildLeader above), so it doubles
-- as the RECEIVE-SIDE check Sync.lua uses to verify an incoming
-- RECIPIENT broadcast's claimed sender.
local RECIPIENT_MANAGER_NAMES = { Bavin = true, [FULL_PERMISSION_OVERRIDE_NAME] = true }

function ns.CanSetRecipientName(name)
    if not name then return false end
    return RECIPIENT_MANAGER_NAMES[NormalizeName(name)] == true
end

-- 2026-08-05 (Loopi): editor assignment is gated separately from the
-- recipient above - any officer (rankIndex <= 3) or Loopidot, verified
-- live against THIS client's own guild roster cache, never a
-- self-asserted claim. Fails CLOSED if the roster hasn't loaded or the
-- name is unknown, same philosophy as IsGuildLeader. Also the
-- RECEIVE-SIDE check Sync.lua uses to verify an incoming EDITORS
-- broadcast's claimed sender.
function ns.CanSetEditorsName(name)
    if not name then return false end
    if NormalizeName(name) == FULL_PERMISSION_OVERRIDE_NAME then return true end
    local entry = ns.guildRoster[NormalizeName(name)]
    return entry ~= nil and entry.rankIndex ~= nil and entry.rankIndex <= 3
end

-- Whether the LOCAL player can manage the recipient right now. 2026-08-05:
-- also true for the author's account regardless of which alt is logged
-- in (DHTools.IsAuthorAccount(), see DH-Tools\Core.lua) - LOCAL-only,
-- safe to check here since this function is never called to verify a
-- REMOTE sender (that's ns.CanSetRecipientName(senderShort) directly, in
-- Sync.lua - untouched, still name-based only).
function ns.CanManageRecipient()
    if not ns.IsInTargetGuild() then return false end
    if DHTools.IsAuthorAccount and DHTools.IsAuthorAccount() then return true end
    return ns.CanSetRecipientName(UnitName("player"))
end

-- Whether the LOCAL player can manage the editors list right now - same
-- author-account shortcut as CanManageRecipient above, same LOCAL-only
-- safety reasoning (Sync.lua's receive-side check calls
-- ns.CanSetEditorsName(senderShort) directly instead).
function ns.CanManageEditors()
    if not ns.IsInTargetGuild() then return false end
    if DHTools.IsAuthorAccount and DHTools.IsAuthorAccount() then return true end
    return ns.CanSetEditorsName(UnitName("player"))
end

-- LOCAL-only convenience wrapper around CanEditList(UnitName("player")),
-- for the same reason CanManageRecipient adds the author-account
-- shortcut above: CanEditList itself must stay a pure name-based check
-- (Sync.lua calls it directly with a REMOTE sender's name to verify
-- incoming ITEM/ITEMGONE/PTSSET messages - the author-account bypass
-- must never leak into that path). Every LOCAL call site that used to
-- call CanEditList(UnitName("player")) directly should use this instead
-- - see AddItem/RemoveItem (Sync.lua), SetItemPoints (this file),
-- PointsEditor_Open/PriorityEditor_Open.
function ns.CanEditListLocal()
    if not ns.IsInTargetGuild() then return false end
    if DHTools.IsAuthorAccount and DHTools.IsAuthorAccount() then return true end
    return ns.CanEditList(UnitName("player"))
end

-- True if `name` is a currently known guild member in THIS client's own
-- roster cache (online or offline both count - the cache holds both, per
-- Design doc). Milestone 3: "re-verify recipient/editor authorization on
-- GUILD_ROSTER_UPDATE... an editor leaves the guild... authorization is
-- always re-checked live against current roster, never cached
-- permanently" - CanEditList below calls this on every check, so a
-- departed member's name lingering in ns.db.editors/ns.db.recipient
-- (see PruneDepartedRecipientEditors further down for the separate,
-- cosmetic cleanup of those lists themselves) can no longer actually
-- edit anything the instant they leave. Fails CLOSED if the roster
-- hasn't loaded yet or the name is unknown - same philosophy as
-- IsGuildLeader above, for the same reason (an unverifiable claim should
-- be refused, not allowed through).
function ns.IsGuildMember(name)
    if not name then return false end
    return ns.guildRoster[NormalizeName(name)] ~= nil
end

-- Whether `name` currently has edit rights on the priority list: either
-- they're the recipient, or the guild leader has additively named them an
-- editor - AND they must currently still be a guild member (see
-- IsGuildMember above). The priority list itself didn't exist until M2 -
-- this was here from M1 so the config-page stub could show who has edit
-- rights, and M2/M3 reuse it unchanged except for the guild-membership
-- check added here for M3.
function ns.CanEditList(name)
    if not name or not ns.db then return false end
    local norm = NormalizeName(name)
    if not ns.IsGuildMember(norm) then return false end
    if ns.db.recipient and NormalizeName(ns.db.recipient) == norm then return true end
    for _, editor in ipairs(ns.db.editors) do
        if NormalizeName(editor) == norm then return true end
    end
    return false
end

--------------------------------------------------------------------------
-- Item points: local overrides layered on ItemPoints.lua's static baseline
--------------------------------------------------------------------------
-- ns.ITEM_POINTS (ItemPoints.lua) is the shipped, versioned baseline -
-- ~7000 entries, name-keyed, far too large to sync live (see that file's
-- header). ns.db.itemPointsOverrides holds live edits made through the
-- in-game editor (PointsEditor.lua) on top of that baseline, synced as
-- small deltas (Sync.lua's PTSSET/PTSSYNCREQ/PTSSYNCDATA) instead of the
-- whole table. Lookup order: override first, baseline second.
--
-- ns.db.itemPointsOverrides[name] = { points=, itemId=, editedBy=, editedAt= }
-- `points == nil` is a REVERT TOMBSTONE (see RevertItemPoints below) -
-- the entry stays in the table (rather than being deleted outright) so
-- its editedAt keeps counting toward this client's version and toward
-- last-writer-wins comparisons; GetItemPoints falls through to the
-- baseline for a tombstoned name. editedAt uses time() (real wall-clock
-- seconds), NOT GetTime()'s per-session uptime counter - deliberately,
-- since it has to be comparable across different clients/sessions for
-- the PTSSYNCREQ catch-up handshake and per-name conflict resolution
-- (same soft, social-trust versioning as the rest of this addon's sync -
-- not cryptographic, not immune to a wildly wrong system clock).

-- Returns { points=, itemId=, isOverride=, detail= } or nil if `name` is
-- unknown both locally-overridden and in the shipped baseline.
--
-- 2026-08-06 (Loopi): `detail` is ItemPoints.lua's spreadsheet-sourced
-- "<name>: <points> pts to Bavin; <price/source>" summary line (see that
-- file's header) - the text Tooltip.lua actually shows.
--
-- Which detail wins, and why:
--   * An override that carries its OWN detail  -> that text. As of
--     2026-08-06 (later) the Points Editor can edit the wording directly,
--     so an override can now say whatever the editor typed.
--   * An override with NO detail of its own    -> nil, NOT the baseline's.
--     An override changes the points value away from what the spreadsheet
--     says, so the baseline detail's embedded point number would read as
--     stale/wrong next to a different overridden value. Tooltip.lua falls
--     back to the plain "Bavin Points: N" line whenever detail is nil.
--   * No override at all                       -> the baseline's detail.
function ns.GetItemPoints(name)
    if not name then return nil end
    local overrides = ns.db and ns.db.itemPointsOverrides
    local o = overrides and overrides[name]
    if o and o.points ~= nil then
        return { points = o.points, itemId = o.itemId, isOverride = true, detail = o.detail }
    end
    local base = ns.ITEM_POINTS and ns.ITEM_POINTS[name]
    if base then
        return { points = base.points, itemId = base.itemId, isOverride = false, detail = base.detail }
    end
    return nil
end

-- The shipped baseline entry only, ignoring any live override - lets the
-- editor UI show what a "Revert" would restore.
function ns.GetBaselineItemPoints(name)
    return ns.ITEM_POINTS and ns.ITEM_POINTS[name]
end

-- Highest editedAt across every known local override (including revert
-- tombstones) - this client's "version" for the PTSSYNCREQ catch-up
-- handshake. 0 if it has none yet.
function ns.GetItemPointsVersion()
    local highest = 0
    local overrides = ns.db and ns.db.itemPointsOverrides
    if overrides then
        for _, o in pairs(overrides) do
            if (o.editedAt or 0) > highest then highest = o.editedAt end
        end
    end
    return highest
end

-- Applies a points change LOCALLY without any permission check or
-- broadcast - used both by SetItemPoints/RevertItemPoints below (after
-- THEY check permission) and by Sync.lua when applying an already-
-- verified incoming PTSSET (never re-broadcasts what it just received).
-- Only applies if `editedAt` is newer than whatever's already recorded
-- for this name - last-writer-wins per name, same idiom Board.lua's
-- destination handling and DH-Air's SETDEST use.
--
-- 2026-08-06: `detail` (the tooltip wording) is appended LAST rather than
-- slotted next to itemId so every existing 4-arg caller keeps working
-- unchanged - the same additive-argument discipline the wire format
-- itself can't use (see Sync.lua's PREFIX note on why PTSSET's new field
-- forced a V3 -> V4 bump). An empty string is normalized to nil so
-- "cleared the wording box" and "never had wording" are one state, not
-- two that render differently.
function ns.ApplyItemPointsLocal(name, points, itemId, editedAt, detail)
    ns.db.itemPointsOverrides = ns.db.itemPointsOverrides or {}
    local existing = ns.db.itemPointsOverrides[name]
    if existing and (existing.editedAt or 0) >= editedAt then return end
    if detail == "" then detail = nil end
    ns.db.itemPointsOverrides[name] = {
        points = points, itemId = itemId, detail = detail, editedAt = editedAt,
    }
end

-- Sets (or, if points is nil, reverts) a live override for `name`,
-- gated by CanEditList exactly like AddItem/RemoveItem. Broadcasts the
-- change so anyone online picks it up immediately.
function ns.SetItemPoints(name, points, itemId, detail)
    if not name or name == "" then return false end
    if not ns.CanEditListLocal() then return false end
    local editedAt = time()
    ns.ApplyItemPointsLocal(name, points, itemId, editedAt, detail)
    if ns.Sync_BroadcastItemPoints then
        ns.Sync_BroadcastItemPoints(name, points, itemId, editedAt, detail)
    end
    return true
end

-- Reverts `name` back to whatever ItemPoints.lua's shipped baseline says
-- (or to "unknown" if it's not in the baseline either) - a SetItemPoints
-- call with points/itemId both nil, same wire shape.
function ns.RevertItemPoints(name)
    return ns.SetItemPoints(name, nil, nil)
end

--------------------------------------------------------------------------
-- RECIPIENT / EDITORS: local set + broadcast
--------------------------------------------------------------------------
-- Sending/receiving now lives in Sync.lua (Milestone 2's full protocol) -
-- these just update local state (guild-leader-gated) and hand off to
-- Sync.lua's broadcast functions, same call-through pattern DH-Quests'
-- Core.lua uses for its own Sync_BroadcastQuest/Sync_BroadcastQuestGone.
-- Returns true/false so the config page can show a refusal instead of
-- silently no-opping.
function ns.SetRecipient(name)
    if not ns.CanManageRecipient() then return false end
    ns.db.recipient = name
    ns.db.recipientEditorsUpdatedAt = time() -- k-0019
    if ns.Sync_BroadcastRecipient then ns.Sync_BroadcastRecipient(name) end
    return true
end

-- Full-replace, officer-only (rankIndex <= 3, or Loopidot) - same
-- "send the whole small set" simplicity as the Design doc's other short
-- lists. 2026-08-05: gated by CanManageEditors, not CanManageRecipient -
-- the two are separately scoped now (see the Permission model section).
function ns.SetEditors(list)
    if not ns.CanManageEditors() then return false end
    ns.db.editors = list
    ns.db.recipientEditorsUpdatedAt = time() -- k-0019
    if ns.Sync_BroadcastEditors then ns.Sync_BroadcastEditors(list) end
    return true
end

-- Cosmetic housekeeping companion to CanEditList's live IsGuildMember
-- check above: that check already stops a departed member from actually
-- editing anything, but ns.db.recipient/ns.db.editors would otherwise
-- keep showing their name forever (config page, /dhb status). Drops any
-- editor no longer in ns.guildRoster, and clears the recipient the same
-- way if THEY'VE left. Purely local - not broadcast - because every
-- online guildmate's own client reaches the identical conclusion from
-- the same server-provided roster data on its own, same "trust your own
-- roster cache, not the network" idiom as IsGuildLeader/CanEditList.
--
-- SAFETY GUARD: skips entirely if ns.guildRoster is empty, OR if the
-- local character isn't actually in Death Happens (k-0019, 2026-08-06) -
-- ns.guildRoster is now only ever populated from Death Happens' own
-- roster (see UpdateGuildRosterCache), so this second check is belt-
-- and-suspenders against ever mistaking a DIFFERENT guild's non-empty
-- roster for a mass departure from THIS one. A transient/incomplete
-- GUILD_ROSTER_UPDATE (e.g. the very first one right after login/reload,
-- before the client has actually populated roster data) would otherwise
-- look exactly like "everyone left the guild" and wipe out a perfectly
-- valid recipient/editor list. NOT yet in-game verified that the empty-
-- roster guard is sufficient in every case (e.g. a roster that's loaded
-- PARTIALLY, with some real members missing, wouldn't trip that guard
-- but could still cause a false removal) - flagged in STATUS.md, watch
-- for this specifically during testing.
local function PruneDepartedRecipientEditors()
    if not ns.db then return end
    if not ns.IsInTargetGuild() then return end
    if next(ns.guildRoster) == nil then return end

    local changed = false

    if ns.db.recipient and not ns.IsGuildMember(ns.db.recipient) then
        ns.Print("Recipient '" .. ns.db.recipient .. "' is no longer in the guild - clearing. The guild leader needs to set a new one.")
        ns.db.recipient = nil
        changed = true
    end

    if ns.db.editors and #ns.db.editors > 0 then
        local kept = {}
        local removedAny = false
        for _, editor in ipairs(ns.db.editors) do
            if ns.IsGuildMember(editor) then
                table.insert(kept, editor)
            else
                removedAny = true
                ns.Print("Editor '" .. editor .. "' is no longer in the guild - removed from the editor list.")
            end
        end
        if removedAny then
            ns.db.editors = kept
            changed = true
        end
    end

    -- k-0019: a real prune is a genuine local state change - bump the
    -- version stamp so it wins a subsequent SYNCDATA exchange instead of
    -- looking older than a peer who never learned about the departure.
    if changed then
        ns.db.recipientEditorsUpdatedAt = time()
    end
end

--------------------------------------------------------------------------
-- Event wiring
--------------------------------------------------------------------------
ns.frame = CreateFrame("Frame")
ns.frame:RegisterEvent("PLAYER_LOGIN")
ns.frame:RegisterEvent("GUILD_ROSTER_UPDATE")
ns.frame:RegisterEvent("CHAT_MSG_ADDON")
-- 2026-08-03: gated on DHTools.IsModuleEnabled("bavin"), same contract
-- every other module follows (see claude\DH-Tools\PROFILE.md) - this was
-- previously the one module that never checked it at all, so disabling
-- Bavin in the Tools config page didn't actually stop anything (roster
-- caching, guild sync init, and incoming CHAT_MSG_ADDON traffic all kept
-- running). One check at the top of the shared handler covers all three
-- events, same "return immediately" style Mob Marker's event handler
-- uses.
ns.frame:SetScript("OnEvent", function(_, event, ...)
    if not DHTools.IsModuleEnabled("bavin") then return end
    if event == "PLAYER_LOGIN" then
        if ns.Sync_Init then ns.Sync_Init() end
        ns.RequestGuildRoster()
    elseif event == "GUILD_ROSTER_UPDATE" then
        ns.UpdateGuildRosterCache()
        PruneDepartedRecipientEditors()
    elseif event == "CHAT_MSG_ADDON" then
        if ns.Sync_OnAddonMessage then ns.Sync_OnAddonMessage(...) end
    end
end)

--------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------
local function ShowHelp()
    ns.Print("Commands:")
    ns.Print("  /dhb                  - show the current recipient/editors/item count")
    ns.Print("  /dhb config           - open the Bavin settings page")
    ns.Print("  /dhb items            - list the priority list's current items")
    ns.Print("  /dhb points           - open the Bavin Points editor (recipient/editor only; everyone else sees it read-only)")
    ns.Print("  /dhb priority         - open the Priority List editor: type an item name, list narrows as you type, click to add/remove (recipient/editor only)")
    ns.Print("  /dhb additem <link>   - fallback: shift-click an item after typing this to add it by name (recipient/editor only) - for the rare item not in the Bavin Points list, which /dhb priority searches")
    ns.Print("  /dhb removeitem <name> - remove an item from the priority list by exact name (recipient/editor only)")
    ns.Print("  /dhb on               - enable the Bavin module")
    ns.Print("  /dhb off              - disable the Bavin module")
    ns.Print("  /dhb help             - show this list")
    ns.Print("Recipient/editors are set from the config page (guild leader only).")
end

local function ShowStatus()
    if not ns.db then
        ns.Print("Not initialized yet.")
        return
    end
    ns.Print("Recipient: " .. (ns.db.recipient or "|cffff3333not set|r"))
    if #ns.db.editors == 0 then
        ns.Print("Editors: none")
    else
        ns.Print("Editors: " .. table.concat(ns.db.editors, ", "))
    end
    local itemCount = 0
    if ns.priorityList then
        for _ in pairs(ns.priorityList) do itemCount = itemCount + 1 end
    end
    ns.Print("Priority list: " .. itemCount .. " item(s) - see /dhb items")
end

-- Plain-text listing, kept alongside the real PriorityEditor.lua UI
-- (Milestone 4) as a quick chat-only status check - same role /dhb
-- (ShowStatus) plays for recipient/editors.
local function ShowItems()
    if not ns.priorityList or next(ns.priorityList) == nil then
        ns.Print("Priority list is empty.")
        return
    end
    -- 2026-08-05 (Loopi): dropped the itemLink display - GetItemInfo-
    -- sourced links are best-effort (see PriorityEditor.lua's header),
    -- so some rows had one and some didn't depending on client item
    -- cache state, which read as inconsistent/buggy even when each row
    -- was individually correct. Bavin Points (ns.GetItemPoints, always
    -- available for any name that has a baseline entry or override -
    -- no client cache dependency) is a consistent per-row substitute.
    for name in pairs(ns.priorityList) do
        local pts = ns.GetItemPoints(name)
        if pts then
            ns.Print(name .. ": " .. pts.points .. " Bavin Points")
        else
            ns.Print(name)
        end
    end
end

SLASH_DHBAVIN1 = "/dhb"
SlashCmdList["DHBAVIN"] = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        ShowStatus()
    elseif cmd == "config" then
        if DHTools.Config_Open then
            DHTools:Config_Open("Bavin")
        else
            ns.Print("Config UI didn't load correctly.")
        end
    elseif cmd == "items" then
        ShowItems()
    elseif cmd == "points" then
        if ns.PointsEditor_Toggle then
            ns.PointsEditor_Toggle()
        else
            ns.Print("Points editor didn't load correctly.")
        end
    elseif cmd == "priority" then
        if ns.PriorityEditor_Toggle then
            ns.PriorityEditor_Toggle()
        else
            ns.Print("Priority List editor didn't load correctly.")
        end
    elseif cmd == "additem" then
        if not ns.AddItem then
            ns.Print("Priority-list sync didn't load correctly.")
            return
        end
        local itemID = rest:match("item:(%d+)")
        if not itemID then
            ns.Print("Usage: /dhb additem <shift-click an item link here> - or search by name with /dhb priority")
            return
        end
        -- Fallback path only - /dhb priority (PriorityEditor.lua) already
        -- knows the name+itemId for anything in the ~7000-entry Bavin
        -- Points baseline. This resolves the name from the link itself,
        -- for the rare item that isn't in that baseline. GetItemInfo can
        -- return nil if the item's data isn't cached client-side yet -
        -- rare for something the player just shift-clicked, but possible.
        local name = GetItemInfo(rest)
        if not name then
            ns.Print("Couldn't resolve that item's name yet - try again in a moment.")
            return
        end
        if ns.AddItem(name, tonumber(itemID), rest) then
            ns.Print("Added to the priority list: " .. rest)
        else
            ns.Print("Refused - you must be the recipient or an editor.")
        end
    elseif cmd == "removeitem" then
        if not ns.RemoveItem then
            ns.Print("Priority-list sync didn't load correctly.")
            return
        end
        if rest == "" then
            ns.Print("Usage: /dhb removeitem <exact item name> - or use /dhb priority to remove by search")
            return
        end
        if not ns.priorityList or not ns.priorityList[rest] then
            ns.Print("'" .. rest .. "' isn't on the priority list (name must match exactly - see /dhb items).")
            return
        end
        if ns.RemoveItem(rest) then
            ns.Print("Removed '" .. rest .. "' from the priority list.")
        else
            ns.Print("Refused - you must be the recipient or an editor.")
        end
    elseif cmd == "on" then
        DHTools.SetModuleEnabled("bavin", true)
    elseif cmd == "off" then
        DHTools.SetModuleEnabled("bavin", false)
    elseif cmd == "help" then
        ShowHelp()
    else
        ns.Print("Unknown command: '" .. cmd .. "'")
        ShowHelp()
    end
end

--------------------------------------------------------------------------
-- Register with DH-Tools
--------------------------------------------------------------------------
DHTools.RegisterModule("bavin", {
    name = "Bavin",
    desc = "Lets the guild's mail collector publish a priority want-list; highlights matching items in your bags and helps mail them in.",
    default = true,
    OnEnable = ns.InitDB,
})
