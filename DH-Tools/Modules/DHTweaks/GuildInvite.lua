-- DH-Tools: Modules\DHTweaks\GuildInvite.lua
-- Tweak 1 (2026-10-28, Loopi): a "Guild Invite" entry on the right-click
-- player menu - names clicked in chat, player/target/party/raid frames.
-- Shown only when the player's guild rank allows inviting
-- (CanGuildInvite()), so the guild's own rank permission decides who sees
-- it; nothing here hard-codes a rank or a guild name (Veteran and above in
-- Death Happens). Design: DH-Tweaks-Design.md.
--
-- Uses Blizzard's tagged-menu API (Menu.ModifyMenu), confirmed present on
-- this client by Loopi 2026-10-28 (`Menu and Menu.ModifyMenu` -> modern).
-- That path does not taint Blizzard's own menus, unlike editing the old
-- UnitPopup tables. Hooks can't be removed, so each is registered once at
-- load and checks ns.IsEnabled() every time the menu opens (Core.lua's
-- HOOK NOTE).
--
-- The tags below are "MENU_UNIT_" .. the old UnitPopup `which` value.
-- FRIEND is what a name clicked in chat opens; the others are unit-frame
-- menus. If an entry is missing from one of these menus in-game, turn on
-- `/dhtweaks debug` and open that menu - it prints the tag and the
-- contextData fields, so the tag list can be corrected.

DHTweaks = DHTweaks or {}
local ns = DHTweaks

ns.GUILD_INVITE_MENU_TAGS = {
    "MENU_UNIT_FRIEND",     -- name clicked in chat (online)
    "MENU_UNIT_PLAYER",     -- another player's unit frame / nameplate
    "MENU_UNIT_TARGET",     -- target frame (any unit; filtered to players below)
    "MENU_UNIT_PARTY",      -- party member
    "MENU_UNIT_RAID_PLAYER",-- raid member
}

local function CanInvite()
    if C_GuildInfo and C_GuildInfo.CanGuildInvite then
        return C_GuildInfo.CanGuildInvite() and true or false
    end
    if CanGuildInvite then return CanGuildInvite() and true or false end
    return false
end

local function SendInvite(name)
    if C_GuildInfo and C_GuildInfo.Invite then
        C_GuildInfo.Invite(name)
    elseif GuildInvite then
        GuildInvite(name)
    end
end

-- Returns the name to invite (with "-Realm" only when it differs from the
-- player's own realm), or nil when no entry should be offered.
function ns.ResolveInviteTarget(contextData)
    if type(contextData) ~= "table" then return nil end
    local name, server = contextData.name, contextData.server
    local unit = contextData.unit
    if unit then
        if not UnitIsPlayer(unit) then return nil end
        if UnitIsUnit(unit, "player") then return nil end
        -- The other faction can't be guild-invited.
        local mine, theirs = UnitFactionGroup("player"), UnitFactionGroup(unit)
        if mine and theirs and mine ~= theirs then return nil end
        -- A visible unit already in a guild can't be invited either. (A
        -- unit we can't read guild info for just shows the entry.)
        if GetGuildInfo(unit) then return nil end
        name, server = UnitName(unit)
    end
    if type(name) ~= "string" or name == "" then return nil end
    if name == UnitName("player") then return nil end
    if type(server) == "string" and server ~= "" and server ~= GetNormalizedRealmName() then
        return name .. "-" .. server
    end
    return name
end

local function DebugContext(tag, contextData, canInvite, target)
    if not (ns.db and ns.db.debug) then return end
    local parts = {}
    if type(contextData) == "table" then
        for k, v in pairs(contextData) do
            if type(v) ~= "table" and type(v) ~= "function" and type(v) ~= "userdata" then
                parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
            end
        end
        table.sort(parts)
    end
    ns.Print(("menu %s | canInvite=%s | target=%s | %s"):format(
        tag, tostring(canInvite), tostring(target), table.concat(parts, " ")))
end

local function OnMenu(tag, rootDescription, contextData)
    if not ns.IsEnabled() then return end
    local canInvite = CanInvite()
    local target = canInvite and ns.ResolveInviteTarget(contextData) or nil
    DebugContext(tag, contextData, canInvite, target)
    if not target then return end
    rootDescription:CreateButton("Guild Invite", function() SendInvite(target) end)
end

if Menu and Menu.ModifyMenu then
    for _, tag in ipairs(ns.GUILD_INVITE_MENU_TAGS) do
        Menu.ModifyMenu(tag, function(owner, rootDescription, contextData)
            -- pcall: a bug here must never stop Blizzard's own menu opening.
            local ok, err = pcall(OnMenu, tag, rootDescription, contextData)
            if not ok then ns.Print("Guild Invite menu error (" .. tag .. "): " .. tostring(err)) end
        end)
    end
else
    ns.guildInviteUnavailable = true -- no modern menu API on this client
end
