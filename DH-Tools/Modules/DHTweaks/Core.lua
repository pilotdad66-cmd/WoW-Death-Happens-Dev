-- DH-Tools: Modules\DHTweaks\Core.lua
-- "DH-Tweaks" module - a home for small quality-of-life changes to the
-- default UI (right-click menu entries, and similar). Scaffolded
-- 2026-10-28 (Loopi); this file is the registry only - each tweak lives in
-- its own file, listed in the .toc. Tweaks so far: GuildInvite.lua (a
-- "Guild Invite" right-click menu entry). See DH-Tweaks-Design.md (same
-- folder) - README section 14 (ARCHITECTURE FIRST) applies to each
-- tweak's behavior before it is built.
--
-- Follows the DH-Tools module contract (claude\DH-Tools\PROFILE.md
-- "Module framework contract"): own DHToolsDB.tweaks sub-table,
-- registered here via DHTools.RegisterModule. Default ON (Loopi,
-- 2026-10-28): every tweak is invisible unless it applies to the player.
--
-- HOOK NOTE for every future tweak in this module: a hooksecurefunc or a
-- menu-modify callback cannot be removed once installed, so a tweak must
-- install its hook once and check ns.IsEnabled() INSIDE the hook, rather
-- than relying on OnDisable to remove anything.

DHTweaks = DHTweaks or {}
local ns = DHTweaks

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99DH-Tweaks:|r " .. msg)
end

function ns.InitDB()
    DHToolsDB.tweaks = DHToolsDB.tweaks or {}
    ns.db = DHToolsDB.tweaks
end

-- True while the module's DH-Tools toggle is on. Tweak hooks call this
-- every time they fire (see HOOK NOTE above).
function ns.IsEnabled()
    return DHTools ~= nil and DHTools.IsModuleEnabled("tweaks")
end

local function OnEnable()
    ns.InitDB()
end

-- Debug output for tweak development (toggled by /dhtweaks debug, saved
-- per character). Silent unless on.
SLASH_DHTWEAKS1 = "/dhtweaks"
SlashCmdList["DHTWEAKS"] = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)")
    if cmd == "debug" then
        if not ns.db then ns.InitDB() end
        ns.db.debug = not ns.db.debug
        ns.Print("Debug output " .. (ns.db.debug and "on" or "off") .. ".")
    else
        ns.Print("Commands: /dhtweaks debug - print what each tweak sees when a menu opens.")
    end
end

DHTools.RegisterModule("tweaks", {
    name = "DH-Tweaks",
    desc = "Small quality-of-life tweaks to the default UI, such as extra right-click menu options.",
    default = true,
    OnEnable = OnEnable,
})
