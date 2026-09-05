-- DH-Tools: Modules\DHMacros\Core.lua
-- "Macros" module - generates ready-to-use macros for players (target/
-- focus, dismount, release corpse, and other Hardcore-relevant
-- one-liners; see DH-Macros-Design.md). Scaffolded 2026-08-21 - folder/
-- file structure only, no generation logic yet.
--
-- Open design question for Loopi before Milestone 1 (README section 14,
-- ARCHITECTURE FIRST): whether/how to write macros directly via the
-- client's CreateMacro API (general vs. per-character macro slots are
-- both capped at 18 in this client, and CreateMacro's in-combat/
-- protected-call behavior needs verifying) versus only ever showing text
-- for the player to paste into the macro UI themselves, or offering
-- both. See DH-Macros-Design.md.
--
-- Follows the DH-Tools module contract (claude\DH-Tools\PROFILE.md
-- "Module framework contract"): own DHToolsDB.macros sub-table (the
-- plain default - no standalone-optionality reason identified yet,
-- unlike DHQuests/DHBavin/DHDanger/DHAir's own top-level SavedVariables
-- tables), registered here via DHTools.RegisterModule.

DHMacros = DHMacros or {}
local ns = DHMacros

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99DH-Macros:|r " .. msg)
end

function ns.InitDB()
    DHToolsDB.macros = DHToolsDB.macros or {}
    ns.db = DHToolsDB.macros
end

local function OnEnable()
    ns.InitDB()
end

DHTools.RegisterModule("macros", {
    name = "Macros",
    desc = "Create ready-to-use macros from a curated library, or copy the text to paste in yourself.",
    default = false,
    OnEnable = OnEnable,
})

-- === Config / Board helpers (called from Minimap.lua and Board.lua's
-- own footer, same guarded-existence pattern DHQuests uses elsewhere) ===
function ns.Config_Open()
    if DHTools and DHTools.Config_Open then
        DHTools:Config_Open("Macros")
    end
end

-- === Create Macro (2026-08-21 design, Loopi) ===
-- entry: one MacroLibrary.lua macro table (name/macroName/icon/body/desc).
-- perChar: true = character-specific slot, false/nil = general (account-
-- wide) slot. Slot-availability is checked FIRST, before anything else -
-- Loopi's explicit ordering request - so a full macro book fails fast
-- with one clear message instead of after a name-collision prompt the
-- player would have to cancel out of.
--
-- MAX_ACCOUNT_MACROS/MAX_CHARACTER_MACROS are the client's own real
-- constants (used by Blizzard's own macro UI) - read live rather than
-- hardcoding 18/18 here, so this stays correct even if a future client
-- patch changes the slot counts. General macros occupy indices
-- 1..maxGlobal, character-specific occupy maxGlobal+1..maxGlobal+
-- maxPerChar right after (Blizzard's own Classic macro UI addon uses
-- this exact offset - self.macroBase = MAX_ACCOUNT_MACROS for the
-- character-specific tab). k-0039: collision detection scans directly
-- within the target scope's own index range rather than asking
-- GetMacroIndexByName to guess the scope of whatever it finds -
-- warcraft.wiki.gg notes it "seems to return the first matching index,
-- if there are duplicates", which is always the general one (lower
-- index range) once a same-named macro exists in both scopes, masking
-- a real character-specific collision.
local function GetSlotLimits()
    return MAX_ACCOUNT_MACROS or 18, MAX_CHARACTER_MACROS or 18
end

function ns.DoCreateMacro(entry, perChar)
    local ok, result = pcall(CreateMacro, entry.macroName, entry.icon, entry.body, perChar)
    if ok then
        ns.Print("Created '" .. entry.macroName .. "' (" .. (perChar and "character-specific" or "general") .. ").")
    else
        ns.Print("Couldn't create the macro: " .. tostring(result))
    end
end

StaticPopupDialogs["DHMACROS_CONFIRM_OVERWRITE"] = {
    text = "A macro named '%s' already exists. Overwrite it?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data)
        local ok, result = pcall(EditMacro, data.index, data.entry.macroName, data.entry.icon, data.entry.body)
        if ok then
            ns.Print("Updated '" .. data.entry.macroName .. "'.")
        else
            ns.Print("Couldn't update the macro: " .. tostring(result))
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function ns.RequestCreateMacro(entry, perChar)
    if not entry then return end
    if InCombatLockdown and InCombatLockdown() then
        ns.Print("Macros can't be created or edited while in combat.")
        return
    end

    local maxGlobal, maxPerChar = GetSlotLimits()
    local numGlobal, numPerChar = GetNumMacros()
    if perChar then
        if numPerChar >= maxPerChar then
            ns.Print("No free character-specific macro slots (" .. numPerChar .. "/" .. maxPerChar .. " used). Delete one in your macro book first.")
            return
        end
    else
        if numGlobal >= maxGlobal then
            ns.Print("No free general macro slots (" .. numGlobal .. "/" .. maxGlobal .. " used). Delete one in your macro book first.")
            return
        end
    end

    -- Scan only the scope we're about to create into (see the comment
    -- above GetSlotLimits for why GetMacroIndexByName alone isn't safe
    -- here - k-0039).
    local scopeBase = perChar and maxGlobal or 0
    local scopeCount = perChar and numPerChar or numGlobal
    local existingIndex
    for i = scopeBase + 1, scopeBase + scopeCount do
        if GetMacroInfo(i) == entry.macroName then
            existingIndex = i
            break
        end
    end

    if existingIndex then
        StaticPopup_Show("DHMACROS_CONFIRM_OVERWRITE", entry.macroName, nil, { entry = entry, index = existingIndex })
        return
    end

    ns.DoCreateMacro(entry, perChar)
end

-- === Slash command ===
SLASH_DHMACROS1 = "/dhm"
SlashCmdList["DHMACROS"] = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$"):lower()
    if msg == "config" then
        ns.Config_Open()
    else
        if ns.Board_Toggle then
            ns.Board_Toggle()
        end
    end
end
