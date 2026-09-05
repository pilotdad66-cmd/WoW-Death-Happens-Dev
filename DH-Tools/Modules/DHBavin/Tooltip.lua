-- DH-Tools: Modules\DHBavin\Tooltip.lua
-- Adds a "Bavin Points: N pts each" line to any item tooltip whose exact display
-- name appears in ItemPoints.lua's ns.ITEM_POINTS table (or has a live
-- in-game override on top of it - see Core.lua's "Item points" section)
-- - see ItemPoints.lua's header for why the lookup is by name, not
-- itemID (random-suffix rare items share one base itemID but price
-- differently per suffix). Read-only informational display, no
-- permission gate - this doesn't reveal anything guildmates can't
-- already see in the source spreadsheet (or, for a live edit, in the
-- Points Editor itself - PointsEditor.lua).
--
-- Uses ns.GetItemPoints(name), NOT ns.ITEM_POINTS[name] directly, so a
-- Points Editor override is reflected here immediately instead of only
-- after the next addon release ships a regenerated ItemPoints.lua.
--
-- Hooked via GameTooltip:HookScript("OnTooltipSetItem", ...) - the
-- standard, low-risk tooltip-extension idiom (unlike Bavin's still-
-- unbuilt M5 bag-highlight hook, which has real unverified API risk -
-- see PROFILE.md's Known risks). Per Blizzard's own API contract,
-- OnTooltipSetItem fires for every item-setting method on the tooltip -
-- SetBagItem, SetInventoryItem, SetHyperlink (chat item links, both
-- hover and the persistent ItemRefTooltip a click opens), SetAction
-- (action bar items), SetMerchantItem, SetLootItem, and more - because
-- it hooks the shared GameTooltip object itself, not any one caller.
-- Also hooks ItemRefTooltip directly (belt-and-suspenders for the
-- clicked-link case, a separate frame object from GameTooltip).
--
-- 2026-08-08 (Loopi): confirmed working for bags; requested for chat
-- links and action bars specifically. Mechanically this ONE hook should
-- already cover both per the contract above - added below is a real gap
-- it doesn't close on its own: an item whose info the client hasn't
-- cached yet (GetItemInfo/tooltip:GetItem() returns nil until a server
-- round-trip completes) shows a blank/partial tooltip on first hover,
-- same caching gap DHDangerLootDump.lua already had to handle for a
-- different reason. Bag/merchant items are usually already cached
-- because you're carrying or looking at them; an item someone else
-- linked in chat, or one you haven't picked up in a while, may not be.
-- See TryAddLine/the GET_ITEM_INFO_RECEIVED watcher below.
--
-- 2026-08-08 (Loopi, in-game result #1): chat links confirmed working;
-- action bar hover confirmed NOT working. So OnTooltipSetItem does not
-- actually fire for SetAction in this client, contrary to the
-- documented contract above - added hooksecurefunc(GameTooltip,
-- "SetAction", ...) as a second path, independent of whether
-- OnTooltipSetItem fires for it.
--
-- 2026-08-08 (Loopi, in-game result #2): STILL not working after that.
-- Real cause, on reflection: the SetAction hook was still calling
-- tooltip:GetItem() to identify the item, same as the bag/hyperlink
-- path - but GetItem() reads from the tooltip's internal ITEM-tooltip
-- state, which SetAction's own C-side implementation apparently never
-- populates for an action-slot item the way SetBagItem/SetHyperlink do
-- (it visually SHOWS item info without wiring through the same shared
-- state GetItem() reads). No amount of retrying fixes that - it isn't
-- delayed, it's simply never set. So the action-bar path now identifies
-- the item a completely different way: GetActionInfo(slot) for the
-- itemID directly from the action-bar API, then GetItemInfo(itemID) for
-- the name, bypassing tooltip:GetItem() entirely for this path. See
-- OnSetAction/pendingItem below - a parallel retry mechanism to
-- TryAddLine/pending, keyed by itemID instead of by re-reading the
-- tooltip, since GetItemInfo(itemID) can still return nil once (cache
-- miss) even though tooltip:GetItem() never will for this path.

local DHTools = DHTools
DHTools.Bavin = DHTools.Bavin or {}
local ns = DHTools.Bavin

-- 2026-08-19 (Loopi): the 2026-08-06 richer detail-line trial and its
-- 4-band quality-color scheme are both reverted - tooltip line is now
-- fixed format "Bavin Points: <N> pts each". Pre-revert version (detail
-- line + 4-band quality coloring + red/grey cases) is tagged in git as
-- archive/dhbavin-tooltip-pre-white-format-2026-08-19 if either is ever
-- wanted back - no need to re-derive it from scratch. Color was then
-- simplified again same day to just two states: red for <=0 points,
-- white for everything else (points missing/non-numeric also render
-- white - no grey "unknown" case this time, unlike the archived
-- version's PointsColor).
local function FormatPoints(points)
    if points == math.floor(points) then
        return string.format("%d", points)
    end
    return string.format("%.2f", points)
end

-- RED_FONT_COLOR is the game's own standard red, read defensively
-- (k-0023: a missing global is a runtime nil no syntax check catches)
-- with the stock 1.0/0.125/0.125 as the fallback.
local FALLBACK_RED = { 1.00, 0.13, 0.13 }
local function PointsColor(points)
    if type(points) == "number" and points <= 0 then
        local c = RED_FONT_COLOR
        if c and c.r then
            return c.r, c.g, c.b
        end
        return FALLBACK_RED[1], FALLBACK_RED[2], FALLBACK_RED[3]
    end
    return 1, 1, 1
end

-- Tooltips that already got our line added for the CURRENT build, keyed
-- by tooltip object - guards against a double-add when both resolution
-- paths below ever fire for the same single hover. Reset on
-- OnTooltipCleared (fired by ClearLines, which every Set* call makes
-- before repopulating - see the reset hook below), so a fresh hover
-- always gets a fresh chance to add the line even when re-hovering the
-- exact same item.
local added = {}

-- 1 or -1 point is singular ("1 pt each"); everything else, including 0
-- and non-integer values, is plural ("pts").
local function PointsUnit(points)
    if points == 1 or points == -1 then
        return "pt"
    end
    return "pts"
end

-- Shared by both resolution paths once a name is known. Returns true
-- (always - by this point the item IS resolved, priced or not).
local function AddPointsLine(tooltip, name)
    local entry = ns.GetItemPoints(name)
    if entry then
        local r, g, b = PointsColor(entry.points)
        tooltip:AddLine("Bavin Points: " .. FormatPoints(entry.points) .. " " ..
            PointsUnit(entry.points) .. " each", r, g, b)
        tooltip:Show()
    end
    added[tooltip] = true
    return true
end

-- ---------------------------------------------------------------
-- Path 1: bags, chat links, merchant, etc - anything that actually
-- populates the tooltip's item-tooltip state, so tooltip:GetItem()
-- resolves (maybe not on the first call - see the cache-miss note in
-- the header comment).
-- ---------------------------------------------------------------

-- Returns true once the tooltip's item is actually resolved (whether or
-- not it turned out to be a priced item) - false means "not resolved
-- yet, try again later", the signal the retry watcher below acts on.
local function TryAddLine(tooltip)
    if added[tooltip] then return true end
    if not ns.GetItemPoints then return true end -- Core.lua failed to load; nothing to retry for
    local name = tooltip:GetItem()
    if not name then return false end
    return AddPointsLine(tooltip, name)
end

-- Tooltips currently waiting on item info that hasn't arrived yet, keyed
-- by tooltip object (GameTooltip and ItemRefTooltip can be pending
-- independently - e.g. a pinned ItemRefTooltip window while hovering a
-- different item elsewhere).
local pending = {}

local function OnTooltipSetItem(tooltip)
    if TryAddLine(tooltip) then
        pending[tooltip] = nil
    else
        pending[tooltip] = true
    end
end

GameTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
if ItemRefTooltip then
    ItemRefTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
end

-- ---------------------------------------------------------------
-- Path 2: action bar slots - tooltip:GetItem() never resolves here (see
-- header comment), so identify the item via the action-bar API instead:
-- GetActionInfo(slot) for the itemID, GetItemInfo(itemID) for the name.
-- ---------------------------------------------------------------

-- Tooltips waiting on GetItemInfo(itemID) for an action-bar item, keyed
-- by tooltip object -> {id = itemID, slot = slot} (slot is carried
-- along so a late resolution in the watcher below can still stamp
-- addedSlot correctly - see addedSlot's own comment).
local pendingItem = {}

-- brief-003 root cause, confirmed 2026-08-19 via the debug prints added
-- earlier this session: `added[tooltip]` was already true BEFORE
-- OnSetAction even ran, on every hover, silently short-circuiting this
-- whole path. Path 1 (OnTooltipSetItem) never actually populates for
-- action-slot items in the first place (tooltip:GetItem() doesn't
-- resolve for them - see header comment), so `added[tooltip]` was never
-- a real double-add risk here - it was simply the wrong state to gate
-- on, and once anything set it true it stayed true (OnTooltipCleared
-- doesn't fire reliably between action-bar hover transitions the way it
-- does for SetBagItem/SetHyperlink). Fix: track the last-resolved SLOT
-- per tooltip instead of a bare boolean - re-hovering the SAME slot is
-- still a harmless no-op, but a DIFFERENT slot always gets evaluated
-- fresh regardless of whether OnTooltipCleared fires.
local addedSlot = {}

local function OnSetAction(tooltip, slot)
    if not ns.GetItemPoints or not slot then return end
    if addedSlot[tooltip] == slot then return end
    local actionType, id = GetActionInfo(slot)
    if actionType ~= "item" or not id then
        addedSlot[tooltip] = slot -- not an item action - resolved, nothing to add
        return
    end
    local name = GetItemInfo(id)
    if name then
        AddPointsLine(tooltip, name)
        addedSlot[tooltip] = slot
    else
        pendingItem[tooltip] = { id = id, slot = slot } -- cache miss - retry once GET_ITEM_INFO_RECEIVED fires
    end
end

if GameTooltip.SetAction then
    hooksecurefunc(GameTooltip, "SetAction", OnSetAction)
end

-- Retries every still-open pending tooltip (either path) whenever ANY
-- item's info arrives (cheap - this event doesn't fire often), stopping
-- once a given tooltip resolves or is no longer shown. Does not
-- explicitly request the item's data itself; the original
-- SetHyperlink/SetAction/etc. call already triggers that as a side
-- effect, same as it does for the client's normal (non-addon) tooltip
-- display.
local infoWatcher = CreateFrame("Frame")
infoWatcher:RegisterEvent("GET_ITEM_INFO_RECEIVED")
infoWatcher:SetScript("OnEvent", function()
    for tooltip in pairs(pending) do
        if not tooltip:IsShown() then
            pending[tooltip] = nil
        elseif TryAddLine(tooltip) then
            pending[tooltip] = nil
        end
    end
    for tooltip, info in pairs(pendingItem) do
        if not tooltip:IsShown() then
            pendingItem[tooltip] = nil
        else
            local name = GetItemInfo(info.id)
            if name then
                AddPointsLine(tooltip, name)
                addedSlot[tooltip] = info.slot
                pendingItem[tooltip] = nil
            end
        end
    end
end)

-- ---------------------------------------------------------------
-- Path 3: chat-link mouseover preview (2026-08-24, Loopi) - stock
-- Blizzard chat only shows an item's tooltip on CLICK (opens
-- ItemRefTooltip); hovering alone shows nothing at all, confirmed
-- against a client with every other addon disabled. This adds the same
-- "preview on hover" convenience third-party tooltip addons provide,
-- gated behind ns.db.mouseoverChatTooltips (default true - Config.lua's
-- Bavin page). Hooked via HookScript on each chat frame's own
-- OnHyperlinkEnter/OnHyperlinkLeave - these are PER-FRAME SCRIPT
-- HANDLERS, not global ChatFrame_OnHyperlinkEnter functions (there is
-- no such global - confirmed against a working reference addon's
-- source; only the CLICK path, ChatFrame_OnHyperlinkShow, is a real
-- hookable global). Once GameTooltip:SetHyperlink runs, it fires the
-- exact same OnTooltipSetItem hook Path 1 above already installs, so
-- the Bavin Points line appears with no separate logic needed here -
-- this only has to make GameTooltip show up on hover at all.
-- ---------------------------------------------------------------

local function OnChatHyperlinkEnter(frame, link)
    if not (ns.db and ns.db.mouseoverChatTooltips) then return end
    if not link then return end
    GameTooltip:SetOwner(frame, "ANCHOR_CURSOR")
    local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, link)
    if not ok then
        GameTooltip:Hide()
    end
end

local function OnChatHyperlinkLeave()
    if not (ns.db and ns.db.mouseoverChatTooltips) then return end
    GameTooltip:Hide()
end

for i = 1, NUM_CHAT_WINDOWS do
    local chatFrame = _G["ChatFrame" .. i]
    if chatFrame then
        chatFrame:HookScript("OnHyperlinkEnter", OnChatHyperlinkEnter)
        chatFrame:HookScript("OnHyperlinkLeave", OnChatHyperlinkLeave)
    end
end

-- Resets the double-add guards once per hover, before any Set* call.
-- addedSlot is included for completeness/symmetry with the others, even
-- though Path 2 (OnSetAction) no longer depends on this firing
-- reliably - see addedSlot's own comment above.
--
-- 2026-08-24 (k-0044): this was hooked on GameTooltip only - never on
-- ItemRefTooltip, a separate frame object (see Path 1's header
-- comment). OnTooltipSetItem was hooked on BOTH tooltips, but only
-- GameTooltip's clears ever reset added[tooltip], so
-- added[ItemRefTooltip] latched true after the FIRST clicked chat link
-- of a session and silently blocked the Bavin Points line on every
-- click after that, for the rest of the session, regardless of item -
-- exactly the "works once, then never again" symptom Loopi reproduced
-- live. Fixed by hooking the same reset function on both tooltips,
-- matching the existing `if ItemRefTooltip then` guard used for the
-- OnTooltipSetItem hook above.
local function OnTooltipClearedGuards(tooltip)
    added[tooltip] = nil
    pending[tooltip] = nil
    pendingItem[tooltip] = nil
    addedSlot[tooltip] = nil
end

GameTooltip:HookScript("OnTooltipCleared", OnTooltipClearedGuards)
if ItemRefTooltip then
    ItemRefTooltip:HookScript("OnTooltipCleared", OnTooltipClearedGuards)
end
