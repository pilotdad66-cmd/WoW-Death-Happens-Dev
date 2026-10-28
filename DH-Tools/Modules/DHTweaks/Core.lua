-- DH-Tools: Modules\DHTweaks\Core.lua
-- "DH-Tweaks" module - a home for small quality-of-life changes to the
-- default UI (right-click menu entries, and similar). Scaffolded
-- 2026-10-28 (Loopi) - registration only, NO tweak is implemented yet.
-- First planned tweak: a "Guild Invite" entry on the right-click player
-- menu, shown only when CanGuildInvite() is true. See
-- DH-Tweaks-Design.md (same folder) for the plan and its open
-- verification items - README section 14 (ARCHITECTURE FIRST) applies to
-- each tweak's behavior before it is built.
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

DHTools.RegisterModule("tweaks", {
    name = "DH-Tweaks",
    desc = "Small quality-of-life tweaks to the default UI, such as extra right-click menu options.",
    default = true,
    OnEnable = OnEnable,
})
