-- DH-Tools: Modules\DHQuests\Core.lua
-- "Quests" module - lets guild members see who currently has which group/
-- elite/class quests, so people can find others to group up with. Ships
-- as a DH-Tools module for v1, but per Loopi's 2026-07-18 decision (see
-- claude\DH-Quests\PROFILE.md/DH-Quests-Design.md) the core logic here is
-- kept deliberately self-contained - own DHQuests namespace, own
-- DHQuestsDB top-level SavedVariables (NOT a DHToolsDB.<key> sub-table),
-- own /dhq slash command - so this can be spun off as a standalone addon
-- later with minimal rework if it proves popular. DH-Tools only calls
-- into this module (RegisterModule below); nothing here reaches back into
-- DHTools' own tables except a handful of shared entry points any module
-- may use: DHTools.Print/RegisterModule/SetModuleEnabled/IsModuleEnabled,
-- plus (as of Milestone 4/5) Config_Open (to jump to the Quests settings
-- page) and InitStandaloneWindow (Board.lua's window chrome, reused rather
-- than duplicated - see that file's header for what re-porting it would
-- take if this module is ever spun off standalone).
--
-- Folded in 2026-07-18 from the old standalone src\DH-Quests\ scaffold
-- (DH-Quests.toc + stub Core.lua) - that .toc is retired, this is its
-- replacement. See DH-Quests-Design.md for the full 6-milestone plan;
-- this file covers Milestone 1 (data model, category detection, the
-- SavedVariables schema) plus just enough of a slash command to test the
-- scanner manually before M4/M5 build real UI for it.

DHQuests = DHQuests or {}
local ns = DHQuests

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99DH-Quests:|r " .. msg)
end

-- ns.db is DHQuestsDB directly - a standalone top-level SavedVariables
-- table, not nested under DHTools' own DB. See the file header above for
-- why this deviates from DH-Tools' usual per-module sub-table contract.
function ns.InitDB()
    if type(DHQuestsDB) ~= "table" then
        DHQuestsDB = {}
    end
    if type(DHQuestsDB.settings) ~= "table" then
        DHQuestsDB.settings = {}
    end
    if DHQuestsDB.settings.shareEnabled == nil then
        DHQuestsDB.settings.shareEnabled = true
    end
    if type(DHQuestsDB.settings.categories) ~= "table" then
        DHQuestsDB.settings.categories = {}
    end
    local cats = DHQuestsDB.settings.categories
    if cats[ns.CATEGORY_INDIVIDUAL] == nil then cats[ns.CATEGORY_INDIVIDUAL] = true end
    if cats[ns.CATEGORY_GROUP] == nil then cats[ns.CATEGORY_GROUP] = true end
    if cats[ns.CATEGORY_ELITE] == nil then cats[ns.CATEGORY_ELITE] = true end
    if cats[ns.CATEGORY_CLASS] == nil then cats[ns.CATEGORY_CLASS] = true end
    if type(DHQuestsDB.cache) ~= "table" then
        DHQuestsDB.cache = {}
    end
    -- One-time cleanup: earlier builds used /dhq debug to dump raw
    -- GetQuestLogTitle data into DHQuestsDB.debugRaw while diagnosing the
    -- category-detection bug (fixed 2026-07-18, see Scan.lua). That field
    -- was never part of the real schema - strip it if present.
    DHQuestsDB.debugRaw = nil
    ns.db = DHQuestsDB
end

local function ShowHelp()
    ns.Print("Commands:")
    ns.Print("  /dhq           - open the shared-quests window")
    ns.Print("  /dhq scan      - scan your quest log and print classified results")
    ns.Print("  /dhq peers     - print what's been received from guildmates so far (raw dump - see the window for the real view)")
    ns.Print("  /dhq on        - enable the Quests module")
    ns.Print("  /dhq off       - disable the Quests module")
    ns.Print("  /dhq config    - open the sharing settings page")
    ns.Print("  /dhq help      - show this list")
end

-- Raw debug dump of everything currently stored in ns.peers - predates
-- Board.lua's real display window (M5) and is kept around as a quick
-- unfiltered/unsorted sanity check.
local function PrintPeers()
    if next(ns.peers) == nil then
        ns.Print("No peer data received yet.")
        return
    end
    for sender, quests in pairs(ns.peers) do
        local count = 0
        for _ in pairs(quests) do count = count + 1 end
        ns.Print(("%s: %d shared quest(s)"):format(sender, count))
        for questID, q in pairs(quests) do
            ns.Print(("  [%s] lvl %s - %s (id %d)"):format(q.category, tostring(q.level), q.title, questID))
        end
    end
end

SLASH_DHQ1 = "/dhq"
SlashCmdList["DHQ"] = function(msg)
    msg = msg or ""
    local cmd = msg:match("^(%S*)"):lower()

    if cmd == "" then
        if ns.Board_Toggle then
            ns.Board_Toggle()
        else
            ns.Print("Display window didn't load correctly.")
        end
    elseif cmd == "scan" then
        ns.PrintScan()
    elseif cmd == "peers" then
        PrintPeers()
    elseif cmd == "on" then
        DHTools.SetModuleEnabled("quests", true)
    elseif cmd == "off" then
        DHTools.SetModuleEnabled("quests", false)
    elseif cmd == "toggle" then
        DHTools.SetModuleEnabled("quests", not DHTools.IsModuleEnabled("quests"))
    elseif cmd == "config" then
        if DHTools.Config_Open then
            DHTools:Config_Open("Quests")
        else
            ns.Print("Config UI didn't load correctly.")
        end
    elseif cmd == "help" then
        ShowHelp()
    else
        ns.Print("Unknown command: '" .. cmd .. "'")
        ShowHelp()
    end
end

-- === Guild roster cache (Milestone 3) ===
-- Mirrors DH-Air's own Core.lua pattern (DHAir.guildRoster) almost
-- exactly: a normalizedName -> { online = true|false } cache, rebuilt from
-- GetGuildRosterInfo whenever GUILD_ROSTER_UPDATE fires. Used to (1) prune
-- peers who are no longer guild members at all, and (2) stamp every
-- remaining peer quest entry's `status` field with that player's current
-- online/offline state, for M5's planned online-only filter.
ns.guildRoster = ns.guildRoster or {}

local function NormalizeName(name)
    return name and name:match("^([^-]+)") or name
end
ns.NormalizeName = NormalizeName

function ns.RequestGuildRoster()
    if not IsInGuild() then return end
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        pcall(C_GuildInfo.GuildRoster)
    elseif GuildRoster then
        pcall(GuildRoster)
    end
end

-- Rebuilds ns.guildRoster from whatever roster data the client currently
-- has. Peers no longer in the guild at all are dropped from ns.peers
-- entirely (their quest data is stale/irrelevant once they've left) - but
-- a peer who's simply offline right now is deliberately kept, just marked
-- `status = "offline"` on each of their stored quest entries, since M5's
-- display window wants an online-only *filter*, which only makes sense if
-- offline peer data survives to be filtered rather than being discarded
-- the moment someone logs off.
function ns.UpdateGuildRosterCache()
    for k in pairs(ns.guildRoster) do ns.guildRoster[k] = nil end
    if not IsInGuild() then return end

    local numMembers = GetNumGuildMembers and GetNumGuildMembers() or 0
    for i = 1, numMembers do
        -- Milestone 5: also capture character level (GetGuildRosterInfo's
        -- 4th return value) for Board.lua's "sort by character level" -
        -- pulled from the guild roster rather than added to the sync wire
        -- protocol, since it's already available locally and
        -- authoritatively for every guild member, online or not.
        local name, _, _, level, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        if name then
            ns.guildRoster[NormalizeName(name)] = { online = (isOnline == true), level = level }
        end
    end

    for sender, quests in pairs(ns.peers) do
        local rosterEntry = ns.guildRoster[sender]
        if not rosterEntry then
            ns.peers[sender] = nil
        else
            local status = rosterEntry.online and "online" or "offline"
            for _, q in pairs(quests) do
                q.status = status
            end
        end
    end
end

-- === Local quest-change detection (Milestone 3) ===
-- Replaces the temporary manual `/dhq broadcast` test aid (removed this
-- milestone) with automatic detection: QUEST_ACCEPTED/QUEST_REMOVED/
-- QUEST_LOG_UPDATE can all fire several times in a row for one user
-- action (e.g. turning in a quest fires QUEST_LOG_UPDATE repeatedly), so
-- rather than diffing on every single event, a burst within
-- QUEST_SCAN_DEBOUNCE_SECONDS collapses into one rescan.
local QUEST_SCAN_DEBOUNCE_SECONDS = 1
local pendingScanTimer = nil

-- Diffs a fresh scan against ns.db.cache (the last-broadcast snapshot),
-- broadcasts QUEST for anything new/changed and QUESTGONE for anything
-- that dropped out of the log, then replaces the cache with the fresh
-- scan. ns.db.cache persists in DHQuestsDB across logins (see InitDB), so
-- quests accepted/turned in while offline still get broadcast as changes
-- the next time this runs, and unchanged quests don't get re-broadcast
-- just because the client reloaded.
local function RescanAndBroadcast()
    pendingScanTimer = nil
    if not ns.db then return end -- module not enabled / InitDB hasn't run yet

    local fresh = ns.ScanQuestLog()
    local old = ns.db.cache or {}

    for questID, info in pairs(fresh) do
        local prev = old[questID]
        if not prev or prev.title ~= info.title or prev.level ~= info.level or prev.category ~= info.category then
            ns.Sync_BroadcastQuest(questID, info) -- no-ops internally if info.category isn't shared
        end
    end
    for questID, prev in pairs(old) do
        -- Only announce QUESTGONE for quests that were actually shared -
        -- otherwise dropping an unshared quest would leak that it ever
        -- existed to the guild via its bare questID.
        if not fresh[questID] and ns.CategoryShared(prev.category) then
            ns.Sync_BroadcastQuestGone(questID)
        end
    end

    ns.db.cache = fresh
end

-- Called from PLAYER_LOGIN and the three quest-log events below. Resets a
-- single pending timer rather than scanning immediately on every event.
function ns.QueueRescan()
    if not ns.db or not DHTools.IsModuleEnabled("quests") then return end
    if pendingScanTimer then
        pendingScanTimer:Cancel()
    end
    pendingScanTimer = C_Timer.NewTimer(QUEST_SCAN_DEBOUNCE_SECONDS, RescanAndBroadcast)
end

-- === Event wiring ===
-- Registers the addon message prefix and fires SYNCREQ once on login
-- (Sync_Init), requests the guild roster and rebuilds the roster cache
-- whenever it arrives (GUILD_ROSTER_UPDATE), dispatches incoming
-- CHAT_MSG_ADDON traffic (Sync_OnAddonMessage), and queues a debounced
-- rescan on login plus every quest-log change event.
ns.frame = CreateFrame("Frame")
ns.frame:RegisterEvent("PLAYER_LOGIN")
ns.frame:RegisterEvent("CHAT_MSG_ADDON")
ns.frame:RegisterEvent("GUILD_ROSTER_UPDATE")
ns.frame:RegisterEvent("QUEST_ACCEPTED")
ns.frame:RegisterEvent("QUEST_REMOVED")
ns.frame:RegisterEvent("QUEST_LOG_UPDATE")
-- 2026-08-03: added a top-level DHTools.IsModuleEnabled("quests") gate.
-- QueueRescan already checked this internally, so disabling Quests
-- already stopped YOUR OWN scanning/broadcasting - but incoming
-- CHAT_MSG_ADDON traffic (other guildmates' quest broadcasts) and
-- GUILD_ROSTER_UPDATE's cache rebuild ran unconditionally, so a
-- "disabled" client still received, stored, and cached other players'
-- quest data. One check up front closes that gap; QueueRescan's own
-- internal check is now redundant but harmless (defense in depth, same
-- as leaving it is cheaper than proving it's safe to remove).
ns.frame:SetScript("OnEvent", function(_, event, ...)
    if not DHTools.IsModuleEnabled("quests") then return end
    if event == "PLAYER_LOGIN" then
        if ns.Sync_Init then
            ns.Sync_Init()
        end
        ns.RequestGuildRoster()
        ns.QueueRescan()
    elseif event == "CHAT_MSG_ADDON" then
        if ns.Sync_OnAddonMessage then
            ns.Sync_OnAddonMessage(...)
        end
    elseif event == "GUILD_ROSTER_UPDATE" then
        ns.UpdateGuildRosterCache()
    elseif event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" or event == "QUEST_LOG_UPDATE" then
        ns.QueueRescan()
    end
end)

-- === Register with DH-Tools ===
DHTools.RegisterModule("quests", {
    name = "Quests",
    desc = "Shows which guild members have matching group/elite/class quests, so you can find people to group with.",
    default = false,
    OnEnable = ns.InitDB,
})
