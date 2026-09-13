-- DH-Tools: Modules\DHBavin\ChatLookup.lua
-- Guild-chat item lookup ("? " + an item link -> a guild-chat reply with
-- Bavin's info on that item). The TRIGGER DETECTION, link extraction, and
-- claim-race machinery all live in DH-Tools' own Core.lua on purpose -
-- see this folder's DH-Bavin-ChatLookup-Design.md for why (the "nobody
-- has Bavin enabled" fallback has to be postable by a client that ISN'T
-- running this file). This file only answers the one question Core.lua
-- asks it: TryClassifyLookup(link) -> a fully-formed reply string, or nil
-- if this client can't answer (the item isn't cached locally yet, etc.) -
-- Core.lua treats nil exactly like "Bavin module not enabled" and falls
-- through to its own "nobody's home" fallback race. TEMPORARY note: the
-- kill-switch check itself (Bavin.db.chatLookupEnabled) lives in Core.lua,
-- BEFORE this function is ever called - see that file's comment and this
-- module's Config.lua checkbox, both to be removed together (design
-- doc's CL4) once this feature is confirmed working in-game.
--
-- REPLY PRIORITY (identical outcome on every client, so who happens to
-- answer never changes what gets said):
--   1. Not tradable - Quest item or Bind on Pickup. Overrides any
--      ItemPoints entry (a price is moot if the item can't change hands).
--   2. Has data - an ItemPoints.lua entry (or a live override) with a
--      non-nil `detail` line (ns.GetItemPoints already resolves override
--      vs. baseline - see Core.lua's own comment on that function).
--   3. No data - known or unknown item, but no detail text on file.
-- All three lead with the clickable item link (Chris's explicit call,
-- 2026-09-13), then the message text.
--
-- 2026-09-13 (Loopi): classID 12 = Quest item, bindType 1 = Bind on
-- Pickup, read via GetItemInfo's 12th/14th return values. UNVERIFIED on
-- this client (Interface 11509) - same category of risk as every other
-- Blizzard-API assumption this module already flags in PROFILE.md's
-- Known risks; needs an in-game check per the design doc before being
-- fully trusted. If either field proves unreliable here, the fallback is
-- a hidden-tooltip text scan for "Quest Item" / "Binds when picked up"
-- instead - not implemented yet, only worth adding if testing shows the
-- direct fields don't hold up.

local DHTools = DHTools
local ns = DHTools.Bavin

local ITEM_CLASS_QUEST = 12
local BIND_ON_PICKUP = 1

-- Returns a fully-formed guild-chat reply (item link already prepended),
-- or nil if this client has nothing to say - either because the item
-- isn't cached yet (GetItemInfo cache miss; no retry here, this is
-- best-effort client-local coordination, not worth delaying the whole
-- claim race for) or, in principle, any other reason a future change
-- might add. nil is NOT an error - Core.lua's caller treats it exactly
-- like "no eligible answer from this client" and moves on.
function ns.TryClassifyLookup(link)
    if not link then return nil end

    local itemName, _, _, _, _, _, _, _, _, _, _, itemClassID, _, bindType = GetItemInfo(link)
    if not itemName then
        return nil
    end

    if itemClassID == ITEM_CLASS_QUEST or bindType == BIND_ON_PICKUP then
        -- 2026-09-13 (Loopi): wording changed at Chris's request - was
        -- "is not tradable and has no value other than using it or
        -- vendoring it."
        return link .. " cannot be traded. Use it, Vendor it, or DE it."
    end

    -- 2026-09-13 (Loopi): pcall safety net - a hidden Lua error here
    -- would otherwise look exactly like "nothing happened" (WoW's
    -- Lua-error display is off by default). Confirmed 2026-09-13: the
    -- silent-failure reports during testing were actually a GetItemInfo
    -- cache miss on OTHER clients, for items THEY had never cached
    -- before - not a GetItemPoints error - see Core.lua's pending-retry
    -- section; this pcall stays in as ordinary defensive coding.
    local ok, entry = pcall(ns.GetItemPoints, itemName)
    if not ok then
        ns.Print("|cffff3333[lookup debug] GetItemPoints errored:|r " .. tostring(entry))
        return nil
    end

    if entry and entry.detail then
        return link .. " " .. entry.detail
    end

    return link .. " Bavin has no data for " .. itemName .. ". Please message him to let him know."
end
