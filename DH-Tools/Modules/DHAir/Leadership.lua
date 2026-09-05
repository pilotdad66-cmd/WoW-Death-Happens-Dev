-- DH-Air Leadership.lua
-- Auto-promotes registered Summoners to raid assistant (so they can invite
-- people themselves), and provides a best-effort "rescue" handoff if
-- Blizzard's own leader auto-succession (e.g. on disconnect) lands
-- leadership somewhere unexpected.
--
-- HARD CONSTRAINT, worth repeating here since it shapes everything below:
-- PromoteToAssistant/PromoteToLeader can only be called successfully by the
-- CURRENT raid leader - enforced server-side, not just a client-side check.
-- Every function here only does anything when THIS client's player happens
-- to currently be leader; it can never act on behalf of someone else's
-- client, no matter how the code is written. If the person who ends up
-- leader isn't running DH-Air at all, none of this can help - a human has
-- to promote/hand off manually, same as always.

local ADDON_NAME, DHAir = ...

local function CallPartyAPI(modernName, legacyName, ...)
    -- Not currently restricted on Classic Era, but Blizzard added a combat
    -- restriction on retail recently for these same calls - cheap to
    -- respect defensively rather than wait for that to reach Classic too.
    if InCombatLockdown and InCombatLockdown() then return end

    if C_PartyInfo and C_PartyInfo[modernName] then
        pcall(C_PartyInfo[modernName], ...)
    elseif _G[legacyName] then
        pcall(_G[legacyName], ...)
    end
end

local function DoPromoteToAssistant(name)
    CallPartyAPI("PromoteToAssistant", "PromoteToAssistant", name)
end

local function DoPromoteToLeader(name)
    CallPartyAPI("PromoteToLeader", "PromoteToLeader", name)
end

--------------------------------------------------------------------------
-- Auto-promote registered Summoners to assistant
--------------------------------------------------------------------------

-- Returns true if `name` should be auto-promoted right now: a registered
-- Summoner, not already leader/assistant, and (if the guild-only toggle is
-- on) actually a guild member.
function DHAir:ShouldAutoPromote(name)
    if not self.db.autoPromote then return false end
    if not self:IsRegistered("summoner", name) then return false end
    if self.db.autoPromoteGuildOnly and not self:IsGuildMember(name) then return false end
    if self:UnitHasAuthority(name) then return false end -- already leader/assistant
    return true
end

-- Promotes every qualifying registered Summoner in the current raid.
-- Safe to call repeatedly/on every roster change - already-promoted
-- members are cheap no-ops via ShouldAutoPromote's own check, so this
-- doubles as both "sweep the whole raid" (on becoming leader) and "check
-- new arrivals" (on every subsequent roster change) without needing two
-- separate code paths.
function DHAir:AutoPromoteSweep()
    if not self.db then return end
    if not (UnitIsGroupLeader("player") == true) then return end
    if not IsInRaid() then return end -- assistant rank only exists in raids, not parties

    for i = 1, GetNumGroupMembers() do
        local name = UnitName("raid" .. i)
        if name and self:ShouldAutoPromote(name) then
            DoPromoteToAssistant(name)
        end
    end
end

--------------------------------------------------------------------------
-- Rescue handoff (best-effort only - see the module comment above)
--------------------------------------------------------------------------

-- Picks the best Summoner currently in the raid to hand lead to: actively-
-- running auto-summon first, then earliest raid join order this session
-- (lower raid roster index). No persistence across raid instances - this
-- naturally resets every time a new raid forms.
--
-- Worth noting: raid roster index isn't a Blizzard-documented guarantee of
-- chronological join order, just a reasonable, commonly-used proxy for it -
-- treat this ranking as "a sensible tiebreak," not a precise guarantee.
function DHAir:PickBestSummonerForLead()
    local best, bestActive, bestIndex = nil, false, math.huge

    for i = 1, GetNumGroupMembers() do
        local name = UnitName("raid" .. i)
        if name and self:IsRegistered("summoner", name) then
            local isActive = self:IsSummonerActive(name)
            if not best
                or (isActive and not bestActive)
                or (isActive == bestActive and i < bestIndex)
            then
                best, bestActive, bestIndex = name, isActive, i
            end
        end
    end

    return best
end

-- Called whenever raid leadership changes. Only takes real action if THIS
-- client's player is the new leader.
function DHAir:OnPartyLeaderChanged()
    if not self.db then return end
    if not IsInRaid() then return end
    if not (UnitIsGroupLeader("player") == true) then return end

    -- Catch-up sweep first, regardless of what happens with leadership
    -- itself - covers anyone who should've been promoted before I became
    -- leader (e.g. the previous leader didn't have DH-Air, or had
    -- auto-promote off).
    self:AutoPromoteSweep()

    -- Deliberately conservative about the handoff itself: only consider it
    -- if I'm NOT already a registered Summoner myself. If a human just
    -- deliberately passed lead to their Summoner, that's very likely
    -- intentional, and second-guessing a real human decision isn't the
    -- goal here - this is specifically meant to catch Blizzard's BLIND
    -- auto-succession-on-disconnect, which has no awareness of Air Service
    -- at all, not to override a choice someone just made on purpose.
    local myName = UnitName("player")
    if self:IsRegistered("summoner", myName) then return end

    local best = self:PickBestSummonerForLead()
    if best and self:NormalizeName(best) ~= self:NormalizeName(myName) then
        self:Print("Handing raid lead to " .. self:NormalizeName(best) .. " (registered Summoner).")
        DoPromoteToLeader(best)
    end
end
