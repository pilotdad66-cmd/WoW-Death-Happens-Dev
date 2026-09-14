-- DH-Air Core.lua
-- Addon initialization, saved variables, and central event dispatch.

local ADDON_NAME, DHAir = ...
_G.DHAir = DHAir

-- 2026-08-20 DH-Air merge: this file now loads as part of DH-Tools'
-- addon (see DH-Tools.toc), so ADDON_NAME/ADDON_LOADED events above
-- refer to "DH-Tools", not "DH-Air" - the ADDON_LOADED check below still
-- works unchanged since it compares against this same dynamic ADDON_NAME.
-- DHTools alias mirrors DHBavin/DHQuests' own Core.lua for
-- IsModuleEnabled/IsAuthorAccount access.
local DHTools = DHTools

-- k-0014 (same bug DH-Tools had): never hardcode the version here - it
-- drifted to "2.0" through multiple real releases. The .toc's
-- "## Version:" line is the single source of truth (the release
-- checklist already maintains it); read it from the addon metadata.
DHAir.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
    or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version"))
    or "?"

--------------------------------------------------------------------------
-- Defaults / Saved Variables
--------------------------------------------------------------------------

local DEFAULT_MESSAGE = "Please click to help summon {target}!"

-- Static /gc broadcast for Board's "Broadcast to Guild" button (2026-08-16,
-- Loopi) - distinct from db.messages.guild below, which is the per-target
-- announcement fired automatically while auto-summoning. XXXX is a literal
-- placeholder, substituted with GetCodePhrases()[1] at send time by
-- Invite.lua's BroadcastGuildInstructions - see Config.lua's Messages page.
local DEFAULT_GUILD_INSTRUCTIONS = "World Buffs Soon! Whisper XXXX to me for "
    .. "auto invite and summons. Grab the Flight Path while you're here."
DHAir.DEFAULT_GUILD_INSTRUCTIONS = DEFAULT_GUILD_INSTRUCTIONS

-- Bounds for db.summonTimeout (the stuck-summon fallback - see
-- @kb:channel-driven-advance). Exported so Config.lua's slider and the
-- ADDON_LOADED migration below can't disagree about the legal range.
-- The old range was 10-90s, back when this genuinely was "how long a
-- summon takes"; nothing in normal play should ever reach it now.
local SUMMON_FALLBACK_MIN, SUMMON_FALLBACK_MAX = 3, 15
DHAir.SUMMON_FALLBACK_MIN = SUMMON_FALLBACK_MIN
DHAir.SUMMON_FALLBACK_MAX = SUMMON_FALLBACK_MAX

local defaults = {
    active = true,          -- auto-summon on/off (auto-invite is independent of this)
    paused = false,         -- pause auto-summon without turning it fully off
    -- 2026-08-15 (Loopi, Config rework): split the old single `autoInvite`
    -- flag into one per trigger mechanism, each a unified on/off for BOTH
    -- the invite AND the queue-join it can now also do - see Invite.lua.
    -- Migrated from the old `autoInvite` below (ADDON_LOADED handler).
    invAutoInvite = true,    -- whisper "inv"/"invite"/etc: auto-invite AND auto-queue-join
    phraseAutoInvite = true, -- code phrase (whisper prefix or raid/party chat exact match): auto-invite AND auto-queue-join
    -- World Buff Mode (2026-08-17, Loopi): Board checkbox, local per-
    -- character, visible only while registered as a summoner. While on,
    -- Invite.lua's whisper handler auto-sets a whisper-triggered joiner's
    -- (code phrase or "inv") destination to Booty Bay. Never synced - only
    -- the summoner whose OWN client receives the whisper ever acts on it.
    worldBuffMode = false,
    -- 2026-08-08 (Loopi): was 30. This is NO LONGER how long a summon
    -- takes - the ritual channel ending releases it now (Summon.lua
    -- @kb:channel-driven-advance). It's only the fallback for a client
    -- where channel events never arrive at all, and Loopi's call is that
    -- a few seconds of over-eagerness beats any chance of the old 30s
    -- lockout coming back: arming the next player early costs one
    -- ignorable prompt, and he simply doesn't click Confirm until his
    -- current ritual is done.
    summonTimeout = 4,      -- seconds; stuck-summon fallback ONLY
    minShards = 2,          -- pause auto-summon if Soul Shards drop below this
    shareQueue = true,      -- share the summon queue with other DH-Air Warlocks in the raid/group
    guildOnly = true,       -- only auto-invite/auto-summon players in your guild
    minimap = {
        hide = false,
    },
    -- Per-channel announcement toggles and customizable message text.
    -- {target} is replaced with the player currently being summoned.
    messages = {
        raid    = { enabled = true,  text = DEFAULT_MESSAGE },
        party   = { enabled = true,  text = DEFAULT_MESSAGE },
        guild   = { enabled = false, text = "Now summoning {target} for the Air Service." },
        say     = { enabled = true,  text = DEFAULT_MESSAGE },
        whisper = { enabled = true,  text = "You're being summoned - please stand by!" },
    },
    -- Static /gc broadcast (Board's "Broadcast to Guild" button) - see
    -- DEFAULT_GUILD_INSTRUCTIONS above and Invite.lua's
    -- BroadcastGuildInstructions for the XXXX substitution.
    guildInstructions = DEFAULT_GUILD_INSTRUCTIONS,
    -- ordered list of { name, summoned, role, queuedAt, destination, note }
    -- `note` is local-only free text and never crosses the wire (D6).
    -- Summoned entries stay here flagged rather than being removed, and are
    -- pruned at login (D7) - see the ADDON_LOADED handler.
    queue = {},
    -- @kb:air-queue-clear-epoch (2026-08-15). Wall-clock time() (never
    -- GetTime() - same k-0033 reasoning) of the last time QueueReset() ran
    -- on THIS client, whether from our own Clear Queue or a received
    -- CLEARALL/RESET. Sync_MergeEntries in Sync.lua uses it to refuse any
    -- incoming queue entry that predates our own last clear, and to push a
    -- corrective CLEARALL back to whichever peer sent it - see that
    -- function's comment for why an additive-only merge let a peer who
    -- missed one CLEARALL broadcast resurrect the whole queue on our next
    -- login.
    queueClearedAt = 0,
    -- db.history REMOVED 2026-08-07 (@kb:air-requeue-always). It recorded
    -- "summoned this session", but nothing ever cleared it at login, so it
    -- permanently and silently barred people from re-queueing. Its only
    -- reader is gone; the ADDON_LOADED handler deletes any leftover copy.

    -- Destinations feature (M1, see DH-Air-Destinations-Design.md): guild-
    -- wide list of { id, label, category } a queued player can pick from.
    -- CopyDefaults only fills missing KEYS, not array contents, so an
    -- empty table here just means "seed it from DEFAULT_DESTINATIONS on
    -- first load" - see the ADDON_LOADED handler below. Never reset by
    -- CopyDefaults once populated, so officer edits (M4) persist normally.
    destinations = {},
    -- officerRankThreshold (M3, DH-Air-Destinations-Design.md Â§3/Â§7):
    -- guild rankIndex <= this counts as "officer" for IsGuildOfficer.
    -- Default 3 is Loopi's explicit call for Death Happens' actual rank
    -- ladder (2026-08-03), not the design doc's original rank<=4 guess -
    -- Guild Master (rank 0) can change it via Config or /dhair officerrank.
    officerRankThreshold = 3,
    -- db.warlockDestination (2026-08-03 addition, see design doc's
    -- "auto-summon destination matching" section) intentionally has NO
    -- entry here - it's local-only Warlock operating state (which
    -- destination auto-summon currently services), not a guild-wide
    -- setting, and defaults to nil (unset) simply by never being
    -- initialized. Set via SetWarlockDestination (Queue.lua), read via
    -- QueueNextAvailable's filter (Summon.lua).

    -- v2.0: guild-wide roster/registration (see Roster.lua)
    roster = {
        summoners = {},     -- [normalizedName] = { lastSeen = <local GetTime()> }
        clickers  = {},     -- same shape
    },
    codePhrase = "air",             -- /raid chat phrase that self-queues the sender
    autoPromote = true,             -- auto-promote registered Summoners to assistant
    autoPromoteGuildOnly = true,    -- ...but only guild members, by default
}

DHAir.DEFAULT_MESSAGE = DEFAULT_MESSAGE

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then
                dst[k] = {}
            end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

--------------------------------------------------------------------------
-- Utility
--------------------------------------------------------------------------

function DHAir:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff9482c9DH-Air|r: " .. tostring(msg))
end

--------------------------------------------------------------------------
-- Guild roster cache (for the "guild members only" option)
--------------------------------------------------------------------------

-- k-0019 (2026-09-14): IsInGuild()/GetGuildRosterInfo() only prove "in
-- SOME guild", not "in Death Happens" - DH-Bavin hit this for real
-- (claude\knowledge\k-0019-bavin-off-guild-roster-wipe.md). Same fix
-- here: gate roster-building on the guild's actual name, not just guild
-- membership. Deliberately hardcoded, not configurable - this addon is
-- built for one specific guild.
local TARGET_GUILD_NAME = "Death Happens"

function DHAir:IsInTargetGuild()
    if not IsInGuild or not IsInGuild() then return false end
    local guildName = GetGuildInfo and GetGuildInfo("player")
    return guildName == TARGET_GUILD_NAME
end

DHAir.guildRoster = {} -- normalizedName -> { online = true|false }

-- Asks the game to (re)fetch the guild roster. The actual data isn't
-- necessarily available until GUILD_ROSTER_UPDATE fires afterward.
function DHAir:RequestGuildRoster()
    if not self:IsInTargetGuild() then return end
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        pcall(C_GuildInfo.GuildRoster)
    elseif GuildRoster then
        pcall(GuildRoster)
    end
end

-- Rebuilds the local guild-membership cache (including online status) from
-- whatever roster data the client currently has (called on GUILD_ROSTER_UPDATE).
function DHAir:UpdateGuildRosterCache()
    for k in pairs(self.guildRoster) do
        self.guildRoster[k] = nil
    end

    if not self:IsInTargetGuild() then return end

    local numMembers = GetNumGuildMembers and GetNumGuildMembers() or 0
    for i = 1, numMembers do
        local name, _, rankIndex, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if name then
            self.guildRoster[self:NormalizeName(name)] = { online = (isOnline == true), rankIndex = rankIndex }
        end
    end
end

-- Returns true if name is a known member of the player's own guild. Fails
-- open (returns true) if the player isn't in a guild or the roster hasn't
-- loaded yet, since we'd rather occasionally allow a non-guildie through
-- than silently brick auto-invite for everyone because of a timing gap.
function DHAir:IsGuildMember(name)
    if not name then return false end
    if not IsInGuild() then return true end
    if next(self.guildRoster) == nil then return true end
    return self.guildRoster[self:NormalizeName(name)] ~= nil
end

-- Returns true/false if we have a definite answer, or nil if we can't tell
-- (not a guild member, or the roster hasn't loaded) - callers should treat
-- nil as "unknown", not as "offline", since we only have real signal for
-- guild members with a loaded roster.
function DHAir:IsGuildMemberOnline(name)
    if not name then return nil end
    local entry = self.guildRoster[self:NormalizeName(name)]
    if not entry then return nil end
    return entry.online
end

--------------------------------------------------------------------------
-- Permission model (v2.0)
--------------------------------------------------------------------------

-- Resolves `name` to a raid/party unit token and checks leader/assistant
-- status for THAT unit - not necessarily the local player. This is the one
-- function used both to decide what the local player can do, AND to verify
-- an incoming permission-gated broadcast against the receiver's OWN trusted
-- knowledge of the raid roster - never trusting a self-asserted claim baked
-- into the message itself.
-- TEMPORARY (Loopi, 2026-08-03): named full-permission override - bypasses
-- every UnitHasAuthority check unconditionally for this one character, both
-- the LOCAL check (via HasPermission -> UnitHasAuthority(self)) and the
-- RECEIVE-SIDE verification other clients run on an incoming broadcast (via
-- Sync.lua's direct UnitHasAuthority(sender) calls for REMOVE/CLEARALL/
-- SETPHRASE) - same "bypass both sides" idiom as DH-Bavin's
-- TESTING_ALLOW_ANYONE_TO_MANAGE, but scoped to one name instead of
-- everyone. Remove this override (or set FULL_PERMISSION_OVERRIDE_NAME to
-- nil) before treating real permission enforcement as verified. Covers
-- BOTH UnitHasAuthority-routed actions (remove_any/clear_all/set_phrase/
-- invite) via the check below, AND the M3 guild-officer-rank actions
-- (edit_destinations/set_officer_threshold) via the identical check baked
-- into IsGuildOfficer/HasPermission's set_officer_threshold branch, since
-- neither of those routes through UnitHasAuthority itself.
local FULL_PERMISSION_OVERRIDE_NAME = "Loopidot"

-- === Author account admin ===
-- 2026-08-20 DH-Air merge: this module's own account-wide admin-bypass
-- copy (AUTHOR_OVERRIDE_ENABLED/AUTHOR_CHARACTER_NAMES/CheckAuthorAccount/
-- DHAir:IsAuthorAccount, backed by DHAirDB.isAuthorAccount) is retired -
-- HasPermission (below) now calls DHTools.IsAuthorAccount() directly,
-- DH-Tools' own account-wide mechanism (see DH-Tools\Core.lua), same
-- Loopi/Loopidot name set, set once at DH-Tools' own PLAYER_LOGIN. Same
-- LOCAL-ONLY scope rule still applies - never add this to
-- UnitHasAuthority/IsGuildOfficer themselves, which Sync.lua still calls
-- with a REMOTE sender's name to verify incoming broadcasts
-- (REMOVE/CLEARALL/SETPHRASE/DESTLIST); those stay exactly as they are,
-- name-based only via FULL_PERMISSION_OVERRIDE_NAME above.

function DHAir:UnitHasAuthority(name)
    if FULL_PERMISSION_OVERRIDE_NAME and name
        and self:NormalizeName(name) == FULL_PERMISSION_OVERRIDE_NAME then
        return true
    end
    if not IsInGroup() then return true end -- nobody's grouped yet; anyone can act

    local myName = UnitName("player")
    local unit
    if self:NormalizeName(name) == self:NormalizeName(myName) then
        unit = "player"
    elseif self.FindGroupUnitByName then
        unit = self.FindGroupUnitByName(name)
    end
    if not unit then return false end -- can't verify - fail closed

    return (UnitIsGroupLeader(unit) == true) or (UnitIsGroupAssistant(unit) == true)
end

-- Real guild-officer-rank check (M3, DH-Air-Destinations-Design.md Â§3),
-- replacing the interim leader/assist gate `edit_destinations` used since
-- M2. Fails CLOSED (false) if unverifiable - same reasoning as
-- DH-Bavin's IsGuildLeader: this gates a write action, unlike
-- IsGuildMember's deliberately fail-open check for a lower-stakes purpose.
-- Carries the same Loopidot bypass UnitHasAuthority has, since this
-- doesn't route through that function.
function DHAir:IsGuildOfficer(name)
    if not name then return false end
    if FULL_PERMISSION_OVERRIDE_NAME
        and self:NormalizeName(name) == FULL_PERMISSION_OVERRIDE_NAME then
        return true
    end
    local entry = self.guildRoster[self:NormalizeName(name)]
    return entry ~= nil and entry.rankIndex ~= nil
        and entry.rankIndex <= (self.db.officerRankThreshold or 3)
end

--------------------------------------------------------------------------
-- Shared window utility
--------------------------------------------------------------------------

-- Sets up a top-level DH-Air window with the properties every one of them
-- needs: proper click-to-raise behavior (so two overlapping DH-Air windows
-- correctly stack based on which you last interacted with, rather than
-- staying stuck in creation order), a guaranteed-opaque background (rather
-- than relying entirely on the template's own backdrop, which may not fully
-- cover every pixel), and dragging scoped to a title-bar-height strip only.
--
-- On that last point: registering drag on an entire frame means clicking
-- ANYWHERE moves the window, and interacts badly with addons like MoveAny
-- that wrap whatever draggable region a frame already exposes with their
-- own click-to-pick-up/click-to-drop behavior - scoping it to a slim strip
-- at the top keeps that behavior confined to where it belongs.
--
-- Every DH-Air window should call this ONCE, right after creating its
-- frame, instead of setting these properties up by hand.
function DHAir:InitStandaloneWindow(targetFrame, rightInset)
    targetFrame:SetToplevel(true)

    local bg = targetFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.9)

    targetFrame:SetMovable(true)
    targetFrame:EnableMouse(true)

    local dragRegion = CreateFrame("Frame", nil, targetFrame)
    dragRegion:SetPoint("TOPLEFT", 0, 0)
    dragRegion:SetPoint("TOPRIGHT", -(rightInset or 28), 0) -- leaves room for a close button
    dragRegion:SetHeight(24)
    dragRegion:EnableMouse(true)
    dragRegion:RegisterForDrag("LeftButton")
    dragRegion:SetScript("OnDragStart", function() targetFrame:StartMoving() end)
    dragRegion:SetScript("OnDragStop", function() targetFrame:StopMovingOrSizing() end)
    return dragRegion
end

-- Single entry point for every permission-gated action, checked LOCALLY by
-- the receiver against trusted Blizzard data (never a self-asserted claim
-- in a network message). In 2.2 this is where guild-officer-rank checks get
-- added, without touching any of the call sites below.
function DHAir:HasPermission(action)
    if DHTools.IsAuthorAccount and DHTools.IsAuthorAccount() then return true end
    if action == "remove_any" or action == "clear_all" or action == "set_phrase"
        or action == "invite" or action == "set_dest_any" or action == "clear_roster" then
        -- set_dest_any (M3, QueueFeedback design D3): setting SOMEONE
        -- ELSE's destination. Same leader/assist gate as remove_any, and
        -- for the same reason - it's a write to another player's queue
        -- entry. Setting your OWN stays self-service and ungated
        -- (SetMyDestination), exactly like SelfJoinQueue/SelfLeaveQueue.
        -- Routed through a named action rather than calling
        -- UnitHasAuthority at the Board's call site, matching the existing
        -- permission-model idiom (Board never asks Blizzard directly).
        return self:UnitHasAuthority(UnitName("player"))
    elseif action == "edit_destinations" then
        -- M3 (DH-Air-Destinations-Design.md Â§3): real guild-officer rank
        -- check, replacing the interim leader/assist gate M2 shipped with.
        -- Inherits the Loopidot testing override via IsGuildOfficer itself.
        return self:IsGuildOfficer(UnitName("player"))
    elseif action == "set_officer_threshold" then
        -- Guild Master (rankIndex 0) only - officers must not be able to
        -- widen their own gate by lowering the threshold. Deliberately
        -- does NOT call IsGuildOfficer (that checks <= threshold, which
        -- would let an officer raise/lower the very setting that defines
        -- who's an officer). Loopidot's testing override is still honored
        -- here directly, same as every other permission-gated action.
        local myName = UnitName("player")
        if FULL_PERMISSION_OVERRIDE_NAME
            and self:NormalizeName(myName) == FULL_PERMISSION_OVERRIDE_NAME then
            return true
        end
        local entry = self.guildRoster[self:NormalizeName(myName)]
        return entry ~= nil and entry.rankIndex == 0
    end
    return false
end

-- Requests changing the officer rank threshold. Guild-Master-only (see
-- HasPermission "set_officer_threshold" above) - the /dhair officerrank
-- slash command's target, mirroring RequestSetPhrase's own
-- validate-then-gate-then-apply shape (Queue.lua).
function DHAir:RequestSetOfficerThreshold(rankIndex)
    rankIndex = tonumber(rankIndex)
    if not rankIndex or rankIndex < 0 then
        self:Print("Usage: /dhair officerrank <N> (a guild rank index, 0 = Guild Master)")
        return false
    end

    if not self:HasPermission("set_officer_threshold") then
        self:Print("Only the Guild Master can change the officer rank threshold.")
        return false
    end

    self.db.officerRankThreshold = rankIndex
    return true
end

--------------------------------------------------------------------------
-- Event Frame
--------------------------------------------------------------------------

DHAir.frame = CreateFrame("Frame")
DHAir.frame:RegisterEvent("ADDON_LOADED")
DHAir.frame:RegisterEvent("PLAYER_LOGIN")
DHAir.frame:RegisterEvent("CHAT_MSG_WHISPER")
DHAir.frame:RegisterEvent("CHAT_MSG_RAID")
DHAir.frame:RegisterEvent("CHAT_MSG_RAID_LEADER")
-- Party added 2026-08-07 (QueueFeedback design D1): a 5-man forming
-- before the raid exists previously had no code-phrase route in at all.
-- Guild chat is deliberately NOT registered - too broad a trigger surface.
DHAir.frame:RegisterEvent("CHAT_MSG_PARTY")
DHAir.frame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
DHAir.frame:RegisterEvent("GROUP_ROSTER_UPDATE")
DHAir.frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
DHAir.frame:RegisterEvent("UNIT_SPELLCAST_FAILED")
DHAir.frame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
DHAir.frame:RegisterEvent("UNIT_SPELLCAST_STOP")
-- 2026-08-08: Ritual of Summoning CHANNELS, and the channel ending is the
-- real "this summon is over" signal - see Summon.lua's
-- @kb:channel-driven-advance. Without these two the addon could only guess
-- with a 30s timer.
DHAir.frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
DHAir.frame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
DHAir.frame:RegisterEvent("BAG_UPDATE")
DHAir.frame:RegisterEvent("CHAT_MSG_ADDON")
DHAir.frame:RegisterEvent("GUILD_ROSTER_UPDATE")

function DHAir.OnEvent(event, ...)
    if event == "CHAT_MSG_WHISPER" then
        local msg, sender = ...
        if DHAir.HandleWhisper then
            DHAir:HandleWhisper(msg, sender)
        end
    elseif event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER"
        or event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER" then
        local msg, sender = ...
        if DHAir.HandlePublicChat then
            DHAir:HandlePublicChat(msg, sender)
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        if DHAir.TrySummonNext then
            DHAir:TrySummonNext()
        end
        if DHAir.Sync_OnRosterChanged then
            DHAir:Sync_OnRosterChanged()
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED"
        or event == "UNIT_SPELLCAST_FAILED"
        or event == "UNIT_SPELLCAST_INTERRUPTED"
        or event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_CHANNEL_START"
        or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        if DHAir.OnSpellcastEvent then
            DHAir:OnSpellcastEvent(event, ...)
        end
    elseif event == "BAG_UPDATE" then
        if DHAir.OnBagUpdate then
            DHAir:OnBagUpdate()
        end
    elseif event == "CHAT_MSG_ADDON" then
        if DHAir.Sync_OnAddonMessage then
            DHAir:Sync_OnAddonMessage(...)
        end
    elseif event == "GUILD_ROSTER_UPDATE" then
        DHAir:UpdateGuildRosterCache()
    end
end

DHAir.frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded == ADDON_NAME then
            DHAirDB = DHAirDB or {}
            CopyDefaults(defaults, DHAirDB)
            DHAir.db = DHAirDB

            -- GetTime() resets on a full client restart (but NOT on /reload),
            -- so a queuedAt saved from a previous session could be a huge,
            -- nonsensical number relative to the fresh clock. Reset any entry
            -- whose queuedAt is impossible (in the "future" relative to now).
            for _, entry in ipairs(DHAir.db.queue) do
                if not entry.queuedAt or entry.queuedAt > GetTime() then
                    entry.queuedAt = GetTime()
                end
            end

            -- Login-time prune (QueueFeedback design D7). db.queue is
            -- account-wide SavedVariables and QueueMarkSummoned only FLAGS
            -- entries, so without this the table - and every SYNCDATA
            -- payload built from it - grows forever across sessions. 30+
            -- summons a raid adds up fast.
            --
            -- At LOGIN only, never mid-session: a summoned entry stays
            -- visible for the rest of the play session it happened in, so
            -- the Board can still show who's already been handled. Runs
            -- AFTER the queuedAt migration above (it reads no timestamps,
            -- but ordering keeps the migration authoritative) and BEFORE
            -- PLAYER_LOGIN's Sync_Init, so we never answer a peer's
            -- SYNCREQ with entries we're about to drop.
            -- Only ever removes entries flagged summoned - anyone still
            -- WAITING survives a relog, which is the whole point of
            -- persisting the queue at all.
            local kept = {}
            for _, entry in ipairs(DHAir.db.queue) do
                if not entry.summoned then
                    table.insert(kept, entry)
                end
            end
            DHAir.db.queue = kept

            -- Reclaim the removed history table from any existing install
            -- (@kb:air-requeue-always) - CopyDefaults no longer recreates
            -- it, but an old DHAirDB on disk still carries one.
            DHAir.db.history = nil

            -- 2026-08-08 migration: summonTimeout stopped being "how long
            -- a summon takes" and became a stuck-state fallback only
            -- (@kb:channel-driven-advance), with the default dropping
            -- 30 -> 4. CopyDefaults only fills MISSING keys, so every
            -- existing install would otherwise keep its old 10-90s value
            -- and still feel like the addon that lost Loopi a raid's
            -- worth of summons. Anything above the new slider's ceiling
            -- is pulled down to the new default; a deliberate small
            -- setting inside the new range is left alone.
            if type(DHAir.db.summonTimeout) ~= "number"
                or DHAir.db.summonTimeout > SUMMON_FALLBACK_MAX then
                DHAir.db.summonTimeout = defaults.summonTimeout
            end

            -- 2026-08-15 migration: the old single `autoInvite` flag split
            -- into invAutoInvite/phraseAutoInvite (Invite.lua). Only runs
            -- for an install that still has the OLD field and hasn't been
            -- migrated yet (CopyDefaults already seeded the new fields to
            -- their defaults for every install, old and new, so we can't
            -- key off them being merely present). Carries the player's
            -- prior on/off choice forward to invAutoInvite specifically -
            -- phraseAutoInvite stays true, since the code phrase always
            -- unconditionally did both invite and queue-join before this
            -- change, so true is the faithful continuation, not a new
            -- default. autoInvite itself is deleted, same cleanup pattern
            -- as db.history (@kb:air-requeue-always).
            if DHAirDB.autoInvite ~= nil then
                DHAir.db.invAutoInvite = DHAirDB.autoInvite and true or false
                DHAirDB.autoInvite = nil
            end

            -- One-time seed of the destinations list from the built-in
            -- starter set (Destinations.lua) - only runs while the list is
            -- still empty, so it never overwrites officer edits (M4) made
            -- on a previous login. Copies plain fields rather than
            -- inserting DEFAULT_DESTINATIONS' own tables directly, so
            -- later per-entry edits can't accidentally mutate the shared
            -- defaults table.
            if #DHAir.db.destinations == 0 then
                for _, d in ipairs(DHAir.DEFAULT_DESTINATIONS or {}) do
                    -- 2026-08-03: was hardcoded `enabled = true` regardless
                    -- of DEFAULT_DESTINATIONS' own data - now respects
                    -- `d.enabled` (defaulting true when the field is
                    -- absent), since some starter entries (The Stockade,
                    -- Ragefire Chasm, The Deadmines) are meant to seed
                    -- disabled by default. See Destinations.lua.
                    table.insert(DHAir.db.destinations, { id = d.id, label = d.label, category = d.category, continent = d.continent, enabled = (d.enabled ~= false) })
                end
            else
                -- 2026-08-03 migration: `continent` was added to
                -- DEFAULT_DESTINATIONS' flightpoint entries AFTER the seed
                -- above already ran on any existing install (the seed only
                -- fires once, while the list is empty - see comment
                -- above), so an already-populated db.destinations would
                -- otherwise be stuck with no continent field forever,
                -- breaking the Board/Minimap destination pickers' new
                -- "Flight Points > continent" grouping. Backfills ONLY the
                -- continent field, matched by id, and ONLY where it's
                -- currently missing - never touches label/enabled, so
                -- officer edits (M4) to those survive untouched.
                local byId = {}
                for _, d in ipairs(DHAir.DEFAULT_DESTINATIONS or {}) do
                    byId[d.id] = d
                end
                for _, entry in ipairs(DHAir.db.destinations) do
                    if entry.category == "flightpoint" and not entry.continent then
                        local default = byId[entry.id]
                        if default and default.continent then
                            entry.continent = default.continent
                        end
                    end
                end
            end
        end

        -- 2026-08-03 one-time migration: Loopi wants The Stockade back as a
        -- selectable destination but disabled by default, and Ragefire
        -- Chasm/The Deadmines switched to disabled by default too (all three
        -- reachable without a summon). The seed loop above already handles
        -- fresh installs correctly via `d.enabled`, but any client whose
        -- destinations list was already populated before this change needs
        -- retrofitting here. Runs unconditionally (not nested in the
        -- if/else above) so it covers both cases; the version flag makes it
        -- a one-time-only pass so it never fights an officer who
        -- re-enables one of these three on purpose afterward.
        if not DHAir.db.migratedStockadeDefaults_20260803 then
            local existingIds = {}
            for _, entry in ipairs(DHAir.db.destinations) do
                existingIds[entry.id] = true
                if entry.id == "ragefirechasm" or entry.id == "deadmines" then
                    entry.enabled = false
                end
            end
            if not existingIds["thestockade"] then
                table.insert(DHAir.db.destinations, {
                    id = "thestockade",
                    label = "The Stockade (Stormwind City)",
                    category = "summonstone",
                    enabled = false,
                })
            end
            DHAir.db.migratedStockadeDefaults_20260803 = true
        end

        return
    end

    -- 2026-08-20 DH-Air merge: gated on DHTools.IsModuleEnabled("air"),
    -- same contract every other module follows (see
    -- claude\DH-Tools\PROFILE.md). ADDON_LOADED above is deliberately
    -- exempt - DHAirDB must always initialize/migrate regardless of
    -- toggle state - same "DB init always runs, behavior doesn't" split
    -- used for Bavin/Quests. Minimap_Init is gone (Loopi's call: DH-Air's
    -- own minimap icon was dropped, DH-Tools' existing minimap button +
    -- DH-Air submenu covers the same actions).
    if not DHTools.IsModuleEnabled("air") then return end

    if event == "PLAYER_LOGIN" then
        DHAir:Print("v" .. DHAir.VERSION .. " loaded. Type /dhair help for commands.")
        if DHAir.Sync_Init then
            DHAir:Sync_Init()
        end
        DHAir:RequestGuildRoster()
        return
    end

    DHAir.OnEvent(event, ...)
end)

--------------------------------------------------------------------------
-- Register with DH-Tools
--------------------------------------------------------------------------
-- No OnEnable/OnDisable: DH-Air's own ADDON_LOADED handler above already
-- initializes/migrates DHAirDB unconditionally (ungated, same as every
-- other module's DB init), and every other handler already checks
-- IsModuleEnabled("air") live - nothing extra to do on toggle. Defaults
-- to OFF on a fresh install (2026-08-31, Loopi) - only Mob Marker and
-- Bavin default on now; a guild member opts everything else in
-- themselves from the Tools page. Existing members' own saved toggle is
-- untouched either way.
DHTools.RegisterModule("air", {
    name = "DH-Air",
    desc = "Warlock/guild summon-coordination - queue, auto-invite, and auto-summon for World Buff runs and beyond.",
    default = false,
})
