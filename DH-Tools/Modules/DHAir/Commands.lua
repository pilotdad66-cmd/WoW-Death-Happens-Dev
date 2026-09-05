-- DH-Air Commands.lua
-- /dhair start | stop | pause | resume | reset | queue | invite on|off | config | help

local ADDON_NAME, DHAir = ...

local function PrintHelp()
    DHAir:Print("Commands:")
    DHAir:Print("  /dhair start   - enable auto-summon")
    DHAir:Print("  /dhair stop    - disable auto-summon (auto-invite keeps working)")
    DHAir:Print("  /dhair pause   - pause auto-summon")
    DHAir:Print("  /dhair resume  - resume auto-summon")
    DHAir:Print("  /dhair abort   - force-reset a stuck summon (e.g. \"already summoning, please wait\")")
    DHAir:Print("  /dhair reset   - clear the summon queue and session (shared with other DH-Air Warlocks)")
    DHAir:Print("  /dhair queue   - list the current summon queue")
    DHAir:Print("  /dhair shards  - show your current Soul Shard count")
    DHAir:Print("  /dhair share on|off - toggle sharing the queue with other DH-Air Warlocks")
    DHAir:Print("  /dhair peers   - list other DH-Air Warlocks seen recently")
    DHAir:Print("  /dhair sync    - re-request the shared queue from other DH-Air Warlocks")
    DHAir:Print("  /dhair invite on|off - toggle auto-invite")
    DHAir:Print("  /dhair guildonly on|off - only auto-invite/summon guild members")
    DHAir:Print("  /dhair join    - add yourself to the summon queue")
    DHAir:Print("  /dhair leave   - remove yourself from the summon queue")
    DHAir:Print("  /dhair remove <name> - remove someone else (raid leader/assist only)")
    DHAir:Print("  /dhair clearall - clear the entire queue (raid leader/assist only)")
    DHAir:Print("  /dhair clearroster - clear every Summoner/Clicker registration (raid leader/assist only)")
    DHAir:Print("  /dhair summoner on|off - register/unregister as a Summoner")
    DHAir:Print("  /dhair clicker on|off - register/unregister as a Clicker")
    DHAir:Print("  /dhair board   - open the Air Service Board")
    DHAir:Print("  /dhair autopromote on|off - auto-promote registered Summoners to assistant")
    DHAir:Print("  /dhair autopromote guildonly on|off - ...but only guild members")
    DHAir:Print("  /dhair phrase [<word>] - show or set the /raid chat code phrase (leader/assist)")
    DHAir:Print("  /dhair warlockdest [<name>|clear] - show/set/clear the destination auto-summon matches against")
    DHAir:Print("  /dhair officerrank [<N>] - show, or set (Guild Master only), the officer rank threshold")
    DHAir:Print("  /dhair destinations - open the destinations list editor (officer-only edits, everyone can view)")
    DHAir:Print("  /dhair dest <name> - set your own destination by partial name match")
    DHAir:Print("  /dhair destfor <player> <name>|clear - set someone else's destination (leader/assist)")
    DHAir:Print("  /dhair config  - open the configuration window")
end

SLASH_DHAIR1 = "/dhair"
SlashCmdList["DHAIR"] = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")

    if cmd == "start" then
        if DHAir:RequestStartAutoSummon() then
            DHAir:Print("Auto-summon started.")
            if DHAir.Minimap_UpdateIcon then DHAir.Minimap_UpdateIcon() end
        end

    elseif cmd == "stop" then
        DHAir.db.active = false
        DHAir:Print("Auto-summon stopped. Auto-invite is still active.")
        if DHAir.Minimap_UpdateIcon then DHAir.Minimap_UpdateIcon() end

    elseif cmd == "pause" then
        DHAir.db.paused = true
        DHAir.pausedForShards = false -- this is an explicit manual pause; don't let restocking auto-resume it
        DHAir:Print("Auto-summon paused.")

    elseif cmd == "resume" then
        if DHAir:RequestResumeAutoSummon() then
            DHAir:Print("Auto-summon resumed.")
        end

    elseif cmd == "abort" then
        DHAir:AbortSummon()

    elseif cmd == "warlockdest" then
        if rest == "" then
            local current = DHAir:GetWarlockDestination()
            local d = current and DHAir:GetDestination(current)
            DHAir:Print("Your current destination: " .. (d and d.label or "(none set)"))
        elseif rest == "clear" or rest == "none" then
            DHAir:SetWarlockDestination(nil)
            DHAir:Print("Destination cleared - auto-summon has nothing to match until you pick one again.")
        else
            local match = DHAir:FindDestinationByQuery(rest)
            if not match then
                DHAir:Print("No single matching destination for '" .. rest
                    .. "' - try a more specific name (a destinations browser/editor is planned, not built yet).")
            else
                DHAir:SetWarlockDestination(match.id)
                DHAir:Print("Destination set to " .. match.label .. ".")
            end
        end

    elseif cmd == "reset" then
        local sharing = DHAir.Sync_IsActive and DHAir:Sync_IsActive()
        DHAir:QueueReset()
        if sharing then
            DHAir:Print("Resetting the shared Air Service queue for the whole raid.")
            DHAir:Sync_BroadcastReset()
        end

    elseif cmd == "queue" or cmd == "list" then
        DHAir:QueueList()

    elseif cmd == "shards" then
        local count = DHAir.GetShardCount and DHAir.GetShardCount()
        if count then
            DHAir:Print("Soul Shards: " .. count .. " (minimum to keep summoning: "
                .. (DHAir.db.minShards or 2) .. ")")
        else
            DHAir:Print("Could not determine Soul Shard count.")
        end

    elseif cmd == "share" then
        if rest == "on" then
            DHAir.db.shareQueue = true
            DHAir:Print("Queue sharing enabled. Requesting the current shared queue...")
            if DHAir.Sync_Init then DHAir:Sync_Init() end
        elseif rest == "off" then
            DHAir.db.shareQueue = false
            DHAir:Print("Queue sharing disabled - your queue is now private to you.")
        else
            DHAir:Print("Usage: /dhair share on|off")
        end

    elseif cmd == "peers" then
        if DHAir.PrintPeers then DHAir:PrintPeers() end

    elseif cmd == "sync" then
        if DHAir.Sync_IsActive and DHAir:Sync_IsActive() then
            DHAir:Print("Requesting the current shared queue from other DH-Air Warlocks...")
            DHAir:Sync_Send("SYNCREQ")
        else
            DHAir:Print("Queue sharing is off or you're not in a group.")
        end

    elseif cmd == "board" then
        if DHAir.Board_Toggle then
            DHAir:Board_Toggle()
        end

    elseif cmd == "autopromote" then
        local subcmd, subrest = rest:match("^(%S*)%s*(.-)$")
        if subcmd == "guildonly" then
            if subrest == "on" then
                DHAir.db.autoPromoteGuildOnly = true
                DHAir:Print("Auto-promote will only apply to guild members.")
            elseif subrest == "off" then
                DHAir.db.autoPromoteGuildOnly = false
                DHAir:Print("Auto-promote will apply to any registered Summoner, guild or not.")
            else
                DHAir:Print("Usage: /dhair autopromote guildonly on|off")
            end
        elseif subcmd == "on" then
            DHAir.db.autoPromote = true
            DHAir:Print("Auto-promote enabled - registered Summoners will be made assistant automatically.")
            if DHAir.AutoPromoteSweep then DHAir:AutoPromoteSweep() end
        elseif subcmd == "off" then
            DHAir.db.autoPromote = false
            DHAir:Print("Auto-promote disabled.")
        else
            DHAir:Print("Usage: /dhair autopromote on|off, or /dhair autopromote guildonly on|off")
        end

    elseif cmd == "phrase" then
        if rest == "" then
            DHAir:Print("Current /raid code phrase: \"" .. (DHAir.db.codePhrase or "") .. "\"")
        else
            if DHAir:RequestSetPhrase(rest) then
                DHAir:Print("Code phrase set to \"" .. rest .. "\".")
            end
        end

    elseif cmd == "officerrank" then
        -- Guild-Master-only fallback for the Config officer-rank dropdown
        -- (M3, DH-Air-Destinations-Design.md §5) - same slash-command-
        -- alternative-to-a-UI-control precedent /dhair phrase already set.
        if rest == "" then
            DHAir:Print("Current officer rank threshold: " .. (DHAir.db.officerRankThreshold or 3)
                .. " (guild rankIndex <= this counts as an officer)")
        else
            if DHAir:RequestSetOfficerThreshold(rest) then
                DHAir:Print("Officer rank threshold set to " .. DHAir.db.officerRankThreshold .. ".")
            end
        end

    elseif cmd == "destinations" then
        -- M4: opens the officer-gated editor window; falls back to
        -- printing the list in chat if the UI file somehow failed to
        -- load, same guarded-call idiom /dhair board already uses for
        -- DHAir.Board_Toggle.
        if DHAir.DestinationEditor_Toggle then
            DHAir:DestinationEditor_Toggle()
        else
            if #DHAir.db.destinations == 0 then
                DHAir:Print("No destinations configured.")
            else
                DHAir:Print("Guild destinations:")
                for _, d in ipairs(DHAir.db.destinations) do
                    local disabledTag = (d.enabled == false) and " |cffff0000[disabled]|r" or ""
                    DHAir:Print("  " .. d.label .. " (" .. d.category .. ")" .. disabledTag)
                end
            end
        end

    elseif cmd == "dest" then
        -- Self-service, text-entry alternative to the Board's dropdown
        -- (M5) - mirrors /dhair join|leave's self-service idiom.
        if rest == "" then
            DHAir:Print("Usage: /dhair dest <name> (partial match against the destinations list)")
        else
            local match = DHAir:FindDestinationByQuery(rest)
            if not match then
                DHAir:Print("No single destination matches \"" .. rest .. "\" - be more specific, "
                    .. "or use /dhair destinations to see the full list.")
            elseif DHAir:SetMyDestination(match.id) then
                DHAir:Print("Destination set to " .. match.label .. ".")
            else
                DHAir:Print("You need to be in the summon queue first (/dhair join).")
            end
        end

    elseif cmd == "destfor" then
        -- M3 (QueueFeedback D3), leader/assist only - the slash-command
        -- twin of clicking another row's destination cell on the Board, for
        -- when the Warlock is mid-raid with the Board closed. Sibling of
        -- "dest" above; the permission check and the whisper to the
        -- affected player both live in RequestSetDestinationFor, so this is
        -- purely argument parsing.
        local who, query = rest:match("^(%S+)%s+(.+)$")
        if not who then
            DHAir:Print("Usage: /dhair destfor <player> <destination> (leader/assist)")
        else
            -- Commands.lua lower-cases the whole line, so recover the queue
            -- entry's real capitalization before doing anything with it -
            -- see FindQueuedName in Queue.lua.
            local realName = DHAir:FindQueuedName(who)
            if not realName then
                DHAir:Print("\"" .. who .. "\" isn't in the summon queue.")
            elseif query == "clear" then
                DHAir:RequestSetDestinationFor(realName, "")
            else
                local match = DHAir:FindDestinationByQuery(query)
                if not match then
                    DHAir:Print("No single destination matches \"" .. query .. "\" - be more specific, "
                        .. "or use /dhair destinations to see the full list.")
                else
                    DHAir:RequestSetDestinationFor(realName, match.id)
                end
            end
        end

    elseif cmd == "config" or cmd == "options" then
        DHAir:Config_Open()

    elseif cmd == "invite" then
        -- 2026-08-15: controls invAutoInvite specifically (the INV whisper
        -- trigger) - see Invite.lua. The code phrase's own toggle
        -- (phraseAutoInvite) has no slash command yet, Config-only.
        if rest == "on" then
            DHAir.db.invAutoInvite = true
            DHAir:Print("Auto-invite enabled.")
        elseif rest == "off" then
            -- D2a (2026-08-17, Loopi - DH-Tools-WorldBuffRequest-Design.md):
            -- can't disable while World Buff Mode is forcing it on.
            if DHAir.db.worldBuffMode then
                DHAir:Print("Can't disable INV auto-invite while World Buff Mode is on.")
            else
                DHAir.db.invAutoInvite = false
                DHAir:Print("Auto-invite disabled.")
            end
        else
            DHAir:Print("Usage: /dhair invite on|off")
        end

    elseif cmd == "guildonly" then
        if rest == "on" then
            DHAir.db.guildOnly = true
            DHAir:Print("Guild members only: ON. Non-guild whispers/queue entries will be ignored.")
            if DHAir.RequestGuildRoster then DHAir:RequestGuildRoster() end
        elseif rest == "off" then
            DHAir.db.guildOnly = false
            DHAir:Print("Guild members only: OFF.")
        else
            DHAir:Print("Usage: /dhair guildonly on|off")
        end

    elseif cmd == "join" then
        if DHAir:SelfJoinQueue() then
            DHAir:Print("You've joined the summon queue.")
        else
            DHAir:Print("You're already in the queue (or already summoned this session).")
        end

    elseif cmd == "leave" then
        if DHAir:SelfLeaveQueue() then
            DHAir:Print("You've left the summon queue.")
        else
            DHAir:Print("You weren't in the queue.")
        end

    elseif cmd == "remove" then
        if rest == "" then
            DHAir:Print("Usage: /dhair remove <name>")
        else
            DHAir:RequestRemove(rest)
        end

    elseif cmd == "clearall" then
        if DHAir:RequestClearAll() then
            DHAir:Print("Queue cleared for everyone.")
        end

    elseif cmd == "clearroster" then
        if DHAir:RequestClearRoster() then
            DHAir:Print("Ready roster (Summoners/Clickers) cleared for everyone.")
        end

    elseif cmd == "summoner" then
        if rest == "on" then
            DHAir:SetRole("summoner", true)
            DHAir:Print("Registered as a Summoner.")
        elseif rest == "off" then
            DHAir:SetRole("summoner", false)
            DHAir:Print("Unregistered as a Summoner.")
        else
            DHAir:Print("Usage: /dhair summoner on|off")
        end

    elseif cmd == "clicker" then
        if rest == "on" then
            DHAir:SetRole("clicker", true)
            DHAir:Print("Registered as a Clicker.")
        elseif rest == "off" then
            DHAir:SetRole("clicker", false)
            DHAir:Print("Unregistered as a Clicker.")
        else
            DHAir:Print("Usage: /dhair clicker on|off")
        end

    else
        PrintHelp()
    end
end
