-- DH-Air Invite.lua
-- Detects whispered invite requests and the /raid chat code phrase, and
-- auto-invites/queues the requester in both cases.

local ADDON_NAME, DHAir = ...

-- Phrases that trigger an auto-invite. Matched against the whole,
-- trimmed, lower-cased whisper text (not a substring match), so that
-- normal conversation whispers aren't accidentally treated as requests.
local INVITE_PATTERNS = {
    "^inv$", "^invite$",
    "^inv me$", "^invite me$",
    "^inv please$", "^invite please$",
    "^plz inv$", "^pls inv$", "^inv plz$", "^inv pls$",
    "^can i get an? inv$", "^can i get an? invite$",
    "^can i have an? inv$", "^can i have an? invite$",
    "^need inv$", "^need an? invite$",
    "^inv for air$", "^inv for the air service$",
}

local recentInvites = {}
local INVITE_DEBOUNCE_SECONDS = 20

-- Splits db.codePhrase (2026-08-15: now allowed to hold multiple phrases,
-- comma-separated - Loopi's Config rework) into a trimmed, non-empty list.
-- Matching itself still lower-cases each phrase at compare time (both here
-- via MatchAnyPhrasePrefix/HandlePublicChat), so "INV"/"Air"/"AIR" etc all
-- keep matching regardless of how the phrase or the message is cased.
function DHAir:GetCodePhrases()
    local phrases = {}
    local raw = self.db and self.db.codePhrase or ""
    for piece in (raw .. ","):gmatch("(.-),") do
        local trimmed = piece:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            table.insert(phrases, trimmed)
        end
    end
    return phrases
end

-- Board's "Broadcast to Guild" button (2026-08-16, Loopi). db.guildInstructions
-- is freeform text (Config.lua's Messages page) that keeps a literal "XXXX"
-- placeholder in storage - substituted here with the first code phrase, so
-- changing the phrase doesn't require re-editing this message too.
function DHAir:GetGuildInstructionsText()
    local template = (self.db and self.db.guildInstructions) or self.DEFAULT_GUILD_INSTRUCTIONS or ""
    local phrase = self:GetCodePhrases()[1] or "the code phrase"
    return (template:gsub("XXXX", phrase))
end

function DHAir:BroadcastGuildInstructions()
    if not IsInGuild() then
        self:Print("You're not in a guild.")
        return
    end
    local msg = self:GetGuildInstructionsText()
    if not msg or msg == "" then
        self:Print("Guild Instructions is empty - set one on the Messages page first.")
        return
    end
    SendChatMessage(msg, "GUILD")
end

-- Matches the code phrase at the START of a trigger message and returns
-- (matched, note), where note is whatever free text the requester typed
-- after it ("air to SM" -> "to SM") or nil.
--
-- 2026-08-07 (@kb:air-prefix-trigger): the old rule was exact equality, so
-- "air pls", "air to SM", "AIR!" matched nothing at all - no invite, no
-- queue entry, and no reply of any kind - and the requester (who almost
-- never has DH-Air installed) just waited. That silent drop was the real
-- cause of the "significant delay" reported after the 2026-08-07 raid.
--
-- The phrase must be followed by end-of-string or WHITESPACE: a bare
-- prefix test would also match "airhead". The note is sliced out of the
-- ORIGINAL message rather than the lower-cased copy so it keeps the
-- requester's own capitalization when the Board shows it; lower-casing
-- never changes a string's length, so the offsets still line up.
--
-- WHISPERS ONLY. Public channels keep exact matching (see
-- HandlePublicChat) - a Warlock typing "air service is up, whisper me"
-- in raid chat must not queue themselves.
local function MatchPhrasePrefix(msg, phrase)
    if not phrase or phrase == "" then return false, nil end

    local trimmed = msg:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local lowerPhrase = phrase:lower()
    if trimmed == lowerPhrase then return true, nil end

    local plen = #lowerPhrase
    if trimmed:sub(1, plen) ~= lowerPhrase then return false, nil end
    if not trimmed:sub(plen + 1, plen + 1):match("%s") then return false, nil end

    local original = msg:gsub("^%s+", ""):gsub("%s+$", "")
    local note = original:sub(plen + 1):gsub("^%s+", ""):gsub("%s+$", "")
    if note == "" then note = nil end
    return true, note
end

-- 2026-08-15: db.codePhrase can now hold several phrases, comma-separated
-- (Loopi's Config rework). Tries each of `phrases` (a list, see
-- GetCodePhrases above) in order and returns the first match - same
-- (matched, note) shape as MatchPhrasePrefix itself.
local function MatchAnyPhrasePrefix(msg, phrases)
    for _, phrase in ipairs(phrases) do
        local matched, note = MatchPhrasePrefix(msg, phrase)
        if matched then return true, note end
    end
    return false, nil
end

local function MatchesInvitePattern(msg)
    msg = msg:lower()
    msg = msg:gsub("^%s+", ""):gsub("%s+$", "")
    for _, pattern in ipairs(INVITE_PATTERNS) do
        if msg:match(pattern) then
            return true
        end
    end
    return false
end

local function DoInvite(name)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(name)
    else
        InviteUnit(name)
    end
end

-- Debounced invite, shared by both trigger mechanisms below so whispering
-- "inv" and the code phrase in quick succession doesn't double-invite.
local function DebouncedInvite(self, sender)
    local now = GetTime()
    if not (recentInvites[sender] and (now - recentInvites[sender]) < INVITE_DEBOUNCE_SECONDS) then
        recentInvites[sender] = now
        DoInvite(sender)
        self:Print("Auto-invited " .. self:NormalizeName(sender) .. ".")
    end
end

-- Called from Core.lua's CHAT_MSG_WHISPER handler.
--
-- 2026-08-15 (Loopi, Config rework): db.invAutoInvite and
-- db.phraseAutoInvite are each an independent, unified on/off for their
-- own trigger - checked means "do the invite AND the queue-join together",
-- unchecked means "do neither". This is a deliberate reversal of the
-- 2026-08-05 decision below for INV specifically (Loopi's explicit call,
-- discussed and confirmed - previously INV never queued, on purpose, to
-- stop ordinary group-invite whispers silently landing people in the
-- summon queue). The code phrase's own behavior (always did both) is
-- unchanged - phraseAutoInvite just makes it possible to turn off now.
function DHAir:HandleWhisper(msg, sender)
    if not self.db then return end
    if not sender or sender == "" then return end

    local isQueueJoin, note = MatchAnyPhrasePrefix(msg, self:GetCodePhrases())
    local isInviteRequest = MatchesInvitePattern(msg)
    if not isQueueJoin and not isInviteRequest then return end

    if self.db.guildOnly and not self:IsGuildMember(sender) then
        return -- "guild members only" is on and this whisperer isn't a guildmate
    end

    if isInviteRequest and self.db.invAutoInvite then
        DebouncedInvite(self, sender)
        -- `note` is LOCAL to this client and deliberately never synced
        -- (QueueFeedback design D6); an INV request never had one anyway.
        self:FinishAirServiceQueueJoin(sender, nil)
    end

    if isQueueJoin and self.db.phraseAutoInvite then
        DebouncedInvite(self, sender)
        self:FinishAirServiceQueueJoin(sender, note)
    end
end

-- The three steps HandleWhisper always runs once a trigger fires: add to
-- the queue, broadcast the add to synced clients, and (if World Buff Mode
-- is on) tag the destination as Booty Bay. Unconditional - no zone check.
--
-- 2026-09-05/2026-09-10 history: this briefly held the queue-join open
-- pending a per-unit Booty-Bay zone check (Deves' "already in Booty Bay
-- doesn't need a summon" request via Loopi), skipping the queue on an
-- exact "Booty Bay" match and queueing normally otherwise. Reverted
-- 2026-09-10 (Loopi): in practice it never skipped anyone - whispering
-- always still invited and queued - because
-- C_Map.GetBestMapForUnit/GetMapInfo could not resolve "Booty Bay" as
-- distinct from "Stranglethorn Vale" for a remote party/raid unit (the
-- UNVERIFIED risk this shipped with, see STATUS.md). Loopi also
-- confirmed the guild does not want STV excluded either, so rather than
-- chase subzone detection, the exclusion is gone: whisper -> invite +
-- immediate queue join, regardless of zone.
function DHAir:FinishAirServiceQueueJoin(name, note)
    if self:QueueAdd(name, note) then
        if self.Sync_BroadcastAdd then
            self:Sync_BroadcastAdd(name)
        end
        self:ApplyWorldBuffModeDestination(name)
    end
end

-- World Buff Mode (2026-08-17, Loopi): while the local summoner has the
-- Board's "World Buff Mode" checkbox on, anyone THEY whisper-invite (either
-- trigger above - code phrase or "inv") gets Booty Bay set as their
-- destination automatically. Reuses RequestSetDestinationFor as-is,
-- including its leader/assist gate (Loopi's explicit call, 2026-08-17: a
-- non-leader/assist summoner mostly can't invite someone into an existing
-- raid/party anyway, so the gate rarely costs anything in practice) and its
-- whisper-the-requester feedback - the requester almost never has the
-- addon, so that whisper is the only place they'd ever learn their
-- destination was set at all.
function DHAir:ApplyWorldBuffModeDestination(sender)
    if not (self.db and self.db.worldBuffMode) then return end
    self:RequestSetDestinationFor(sender, "bootybay")
end

-- Called from Core.lua for CHAT_MSG_RAID / CHAT_MSG_RAID_LEADER /
-- CHAT_MSG_PARTY / CHAT_MSG_PARTY_LEADER. Anyone in those channels typing
-- the configured code phrase gets themselves added to the queue. Party was
-- added 2026-08-07 (QueueFeedback design D1) - a 5-man forming before the
-- raid exists had no way in short of whispering.
--
-- EXACT match here, unlike HandleWhisper's prefix match above, and that
-- asymmetry is deliberate (design D2): these are PUBLIC channels, so a
-- prefix rule would mean a Warlock typing "air service is up, whisper me"
-- in raid chat silently queues themselves. A whisper is unambiguously
-- addressed at the Air Service; a raid-chat line is not.
--
-- This fires for the sender's OWN messages too (WoW echoes your own chat
-- back to your own client), so the exact same code path handles "I typed
-- the phrase myself" and "I saw someone else type it" identically - no
-- need to special-case self vs. others.
--
-- 2026-08-15: gated on db.phraseAutoInvite, same unified toggle
-- HandleWhisper's code-phrase branch uses - it's the same mechanism
-- ("the code phrase"), just reached from a different channel, so one
-- checkbox controls both rather than needing a second for public chat.
function DHAir:HandlePublicChat(msg, sender)
    if not self.db then return end
    if not sender or sender == "" then return end
    if not self.db.phraseAutoInvite then return end

    local trimmed = msg:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local matched = false
    for _, phrase in ipairs(self:GetCodePhrases()) do
        if trimmed == phrase:lower() then
            matched = true
            break
        end
    end
    if not matched then return end

    if self.db.guildOnly and not self:IsGuildMember(sender) then
        return -- "guild members only" is on and this player isn't a guildmate
    end

    if self:QueueAdd(sender) then
        if self.Sync_BroadcastAdd then
            self:Sync_BroadcastAdd(sender)
        end
    end
end
