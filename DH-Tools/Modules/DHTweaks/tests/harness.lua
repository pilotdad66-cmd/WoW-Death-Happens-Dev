-- DH-Tweaks test harness.
-- Loads the ACTUAL Modules\DHTweaks\Core.lua and GuildInvite.lua against a
-- mocked WoW API (same pattern as the other modules' tests\harness.lua).
-- Covers: module registration (default on), the Guild Invite menu entry's
-- gating (CanGuildInvite, module toggle, own name, NPCs, already-guilded,
-- other faction), name/realm resolution, the click -> invite call, the
-- global-API fallbacks, error isolation, and /dhtweaks debug.
-- Does NOT cover how Blizzard's real menu hands contextData to the
-- generator - that part only an in-game test can confirm.

local PASS, FAIL = 0, 0
local function check(name, cond, detail)
    if cond then PASS = PASS + 1 else
        FAIL = FAIL + 1
        print("  FAIL: " .. name .. (detail and (" -- " .. detail) or ""))
    end
end

local BASE = "C:\\AIProjects-NOSYNC\\WoW\\src\\DH-Tools\\Modules\\DHTweaks\\"

--------------------------------------------------------------------------
-- Mock WoW API
--------------------------------------------------------------------------
local registered, chat = {}, {}
local moduleOn = true
_G.DHTools = {
    RegisterModule = function(key, def) registered[key] = def end,
    IsModuleEnabled = function() return moduleOn end,
}
_G.DHToolsDB = {}
_G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = m end }
_G.SlashCmdList = {}

local generators = {}
_G.Menu = { ModifyMenu = function(tag, fn) generators[tag] = fn end }

local canInvite, invited = true, {}
_G.C_GuildInfo = {
    CanGuildInvite = function() return canInvite end,
    Invite = function(n) invited[#invited + 1] = n end,
}

local units = {}
_G.UnitIsPlayer = function(u) return units[u] and units[u].player or false end
_G.UnitIsUnit = function(a, b) return a == b end
_G.UnitName = function(u)
    if u == "player" then return "Me", nil end
    local d = units[u]
    if d then return d.name, d.realm end
end
_G.UnitFactionGroup = function(u) return (u == "player") and "Alliance" or (units[u] and units[u].faction) end
_G.GetGuildInfo = function(u) return units[u] and units[u].guild or nil end
_G.GetNormalizedRealmName = function() return "Realm" end

local function load(file)
    local chunk, err = loadfile(BASE .. file)
    assert(chunk, err)
    chunk()
end
load("Core.lua")
load("GuildInvite.lua")

-- Opens the menu for `tag` with `ctx`; returns the list of buttons added.
local function open(tag, ctx)
    local buttons = {}
    local root = { CreateButton = function(_, text, cb) buttons[#buttons + 1] = { text = text, cb = cb } end }
    generators[tag](nil, root, ctx)
    return buttons
end
local function reset() canInvite, invited, moduleOn, units, chat = true, {}, true, {}, {} ; _G.DHToolsDB = {}; DHTweaks.db = nil; DHTweaks.InitDB() end
reset()

--------------------------------------------------------------------------
print("== Registration ==")
local d = registered.tweaks
check("module registered under key 'tweaks'", d ~= nil)
check("module default is ON", d and d.default == true)
check("module display name is DH-Tweaks", d and d.name == "DH-Tweaks")
for _, tag in ipairs({ "MENU_UNIT_FRIEND", "MENU_UNIT_PLAYER", "MENU_UNIT_TARGET", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER" }) do
    check("a menu hook is registered for " .. tag, type(generators[tag]) == "function")
end
d.OnEnable()
check("OnEnable creates DHToolsDB.tweaks", type(DHToolsDB.tweaks) == "table")

--------------------------------------------------------------------------
print("== Chat names (MENU_UNIT_FRIEND) ==")
reset()
local b = open("MENU_UNIT_FRIEND", { name = "Alice" })
check("entry shown for a chat name when CanGuildInvite is true", #b == 1 and b[1].text == "Guild Invite")
b[1].cb()
check("clicking invites exactly that name", #invited == 1 and invited[1] == "Alice")

reset(); canInvite = false
check("no entry when CanGuildInvite is false", #open("MENU_UNIT_FRIEND", { name = "Alice" }) == 0)

reset(); moduleOn = false
check("no entry when the DH-Tweaks toggle is off", #open("MENU_UNIT_FRIEND", { name = "Alice" }) == 0)

reset()
check("no entry for your own name", #open("MENU_UNIT_FRIEND", { name = "Me" }) == 0)
check("no entry for an empty name", #open("MENU_UNIT_FRIEND", { name = "" }) == 0)
check("no entry for missing contextData", #open("MENU_UNIT_FRIEND", nil) == 0)

b = open("MENU_UNIT_FRIEND", { name = "Alice", server = "Realm" }); b[1].cb()
check("same-realm server is not appended", invited[#invited] == "Alice")
b = open("MENU_UNIT_FRIEND", { name = "Alice", server = "Other" }); b[1].cb()
check("a different realm is appended as Name-Realm", invited[#invited] == "Alice-Other")

--------------------------------------------------------------------------
print("== Unit-frame menus ==")
reset()
units.target = { player = true, faction = "Alliance", name = "Bob" }
b = open("MENU_UNIT_TARGET", { unit = "target" })
check("entry shown for a same-faction, unguilded player unit", #b == 1)
b[1].cb()
check("clicking invites the unit's name", invited[1] == "Bob")

units.target = { player = true, faction = "Alliance", name = "Bob", realm = "Other" }
b = open("MENU_UNIT_PLAYER", { unit = "target" }); b[1].cb()
check("a unit on another realm invites as Name-Realm", invited[#invited] == "Bob-Other")

units.target = { player = false, name = "Boar" }
check("no entry for an NPC", #open("MENU_UNIT_TARGET", { unit = "target" }) == 0)
units.target = { player = true, faction = "Alliance", name = "Bob", guild = "Some Guild" }
check("no entry for a player already in a guild", #open("MENU_UNIT_PARTY", { unit = "target" }) == 0)
units.target = { player = true, faction = "Horde", name = "Bob" }
check("no entry for the other faction", #open("MENU_UNIT_RAID_PLAYER", { unit = "target" }) == 0)
units.player = { player = true, faction = "Alliance", name = "Me" }
check("no entry for yourself", #open("MENU_UNIT_PLAYER", { unit = "player" }) == 0)

--------------------------------------------------------------------------
print("== API fallbacks, error isolation, debug ==")
reset()
local savedC = _G.C_GuildInfo
_G.C_GuildInfo = nil
local oldInvited = {}
_G.CanGuildInvite = function() return true end
_G.GuildInvite = function(n) oldInvited[#oldInvited + 1] = n end
b = open("MENU_UNIT_FRIEND", { name = "Carol" })
check("falls back to the global CanGuildInvite when C_GuildInfo is absent", #b == 1)
b[1].cb()
check("falls back to the global GuildInvite", oldInvited[1] == "Carol")
_G.CanGuildInvite, _G.GuildInvite = nil, nil
check("no entry (and no error) if no invite API exists at all", #open("MENU_UNIT_FRIEND", { name = "Carol" }) == 0)
_G.C_GuildInfo = savedC

reset()
local realIsPlayer = _G.UnitIsPlayer
_G.UnitIsPlayer = function() error("boom") end
units.target = { player = true, faction = "Alliance", name = "Bob" }
local ok = pcall(function() generators["MENU_UNIT_TARGET"](nil, { CreateButton = function() end }, { unit = "target" }) end)
check("an error inside the tweak never escapes into Blizzard's menu", ok == true)
local sawErr = false
for _, m in ipairs(chat) do if m:find("Guild Invite menu error", 1, true) then sawErr = true end end
check("the error is reported in chat instead", sawErr)
_G.UnitIsPlayer = realIsPlayer

reset()
open("MENU_UNIT_FRIEND", { name = "Dave" })
check("debug output is silent by default", #chat == 0)
SlashCmdList["DHTWEAKS"]("debug")
check("/dhtweaks debug turns debug on", DHToolsDB.tweaks.debug == true)
chat = {}
open("MENU_UNIT_FRIEND", { name = "Dave" })
local sawCtx = false
for _, m in ipairs(chat) do if m:find("MENU_UNIT_FRIEND", 1, true) and m:find("name=Dave", 1, true) then sawCtx = true end end
check("debug output names the tag and the contextData fields", sawCtx)
SlashCmdList["DHTWEAKS"]("debug")
check("/dhtweaks debug toggles it back off", DHToolsDB.tweaks.debug == false)

--------------------------------------------------------------------------
print("== No modern menu API ==")
_G.Menu = nil
DHTweaks.guildInviteUnavailable = nil
load("GuildInvite.lua")
check("load without Menu.ModifyMenu does not error and flags the tweak unavailable", DHTweaks.guildInviteUnavailable == true)

print(("DH-Tweaks: %d passed, %d failed"):format(PASS, FAIL))
os.exit(FAIL == 0 and 0 or 1)
