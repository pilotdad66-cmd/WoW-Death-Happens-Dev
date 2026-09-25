-- DH-Tools: Modules\DHBavin\Credits.lua
-- CM1 (see this folder's DH-Bavin-Credits-Design.md "Milestone plan"):
-- Data model, permission plumbing & isolation walls for the Credit &
-- Reputation System. No mail-processing code yet (CM4/CM5) - this file
-- only builds the four walls the design doc requires land here first:
--   Wall 1 - separate SavedVariables file (DHBavinCreditsDB), isolated
--            from DHBavinDB so a credit-system bug can't touch v1.0
--            state, and the whole feature is removable by deleting this
--            file (+ its .toc lines).
--   Wall 2 - two independent test lists (creditTestReceivers,
--            creditTestSenders), distinct from the live `recipient`
--            field (DHBavinDB) - this file never reads or writes that.
--   Wall 3 - master toggle, defaults OFF. Ships inert.
--   Wall 4 - both mail hooks (still no-ops here) install only for a
--            listed test character, checked BEFORE installation, not
--            inside the handler. Armed lazily at PLAYER_LOGIN.
--
-- Own addon-message prefix (DHBavinCreditsV1), deliberately NOT sharing
-- Sync.lua's DHBavinV4 (2026-09-24, Chris) - keeps this feature's wire
-- format fully isolated from the live v1.0 donation flow, matching Wall
-- 1's "removable by deleting one file" goal. Carries only the
-- Designated Officers list + Wall 2/3 config (toggle, test lists,
-- multiplier) - NOT the ledger itself (that's CM3's job; wire format
-- TBD there per the design doc's own "work out the exact wire format"
-- note).
--
-- Credits vs. Reputation points: NOT the same number (2026-09-24,
-- Chris) - points are the tier-tracked reputation total, credits are a
-- separate spendable balance earned at creditMultiplier credits-per-
-- point (default 0.60, officer-configurable - see DH-Bavin-Credits-
-- Design.md's "Multiplier" decision, value corrected 2026-09-24 from
-- the doc's original 0.7 draft). This file's config just carries the
-- multiplier; CM4's crediting logic is what actually applies it.

local DHTools = DHTools
DHTools.Bavin = DHTools.Bavin or {}
local ns = DHTools.Bavin

function ns.CreditsPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99DH-Bavin Credits:|r " .. msg)
end

local DEFAULT_MULTIPLIER = 0.60 -- credits per reputation point (2026-09-24, Chris)

--------------------------------------------------------------------------
-- Wall 1: SavedVariables
--------------------------------------------------------------------------
function ns.InitCreditsDB()
    if type(DHBavinCreditsDB) ~= "table" then
        DHBavinCreditsDB = {}
    end
    ns.creditsDb = DHBavinCreditsDB

    -- Ledger: mainName -> { points, credits, tier, prestige,
    -- lifetimePoints, lastUpdated } - empty until CM2 seeds it from
    -- Step 0's validated seed-dataset.csv.
    if type(ns.creditsDb.ledger) ~= "table" then
        ns.creditsDb.ledger = {}
    end
    -- Manual alt-link overrides, fallback for GRM.GetPlayerMain() - CM2.
    if type(ns.creditsDb.altOverrides) ~= "table" then
        ns.creditsDb.altOverrides = {}
    end
    -- Per-transaction audit log (who, item, delta, processedBy, when) - CM4+.
    if type(ns.creditsDb.transactionLog) ~= "table" then
        ns.creditsDb.transactionLog = {}
    end

    -- Wall 3: master toggle, OFF by default. Ships inert.
    if ns.creditsDb.masterToggle == nil then
        ns.creditsDb.masterToggle = false
    end
    -- Wall 2: the two independent test lists. Distinct from `recipient`
    -- (DHBavinDB, the live v1.0 donation flow) - this file never reads
    -- or writes that field.
    if type(ns.creditsDb.creditTestReceivers) ~= "table" then
        ns.creditsDb.creditTestReceivers = {}
    end
    if type(ns.creditsDb.creditTestSenders) ~= "table" then
        ns.creditsDb.creditTestSenders = {}
    end
    -- Designated Officers - guild-leader-settable (CanManageCreditsOfficers
    -- below), separate from DHBavinDB's priority-list editors.
    if type(ns.creditsDb.officers) ~= "table" then
        ns.creditsDb.officers = {}
    end
    -- Credits-per-point multiplier, officer-configurable.
    if type(ns.creditsDb.multiplier) ~= "number" then
        ns.creditsDb.multiplier = DEFAULT_MULTIPLIER
    end
    -- Version stamp for the officers/config broadcast below - same
    -- "strictly newer wins" idiom Core.lua's k-0019 fix uses for
    -- recipient/editors.
    if type(ns.creditsDb.configUpdatedAt) ~= "number" then
        ns.creditsDb.configUpdatedAt = 0
    end
end

--------------------------------------------------------------------------
-- Permission model
--------------------------------------------------------------------------
-- Designated Officers list itself: guild-leader-settable only (same
-- tier as Core.lua's CanManageRecipient, not CanManageEditors' rank<=3)
-- - per design doc's "Officer role" section: "guild-leader-settable,
-- guild-roster-verified on receipt... IsAuthorAccount() override
-- applies same as everywhere else."
function ns.CanManageCreditsOfficers()
    if not ns.IsInTargetGuild() then return false end
    if DHTools.IsAuthorAccount and DHTools.IsAuthorAccount() then return true end
    return ns.IsGuildLeader(UnitName("player"))
end

-- Whether `name` is a currently known Designated Officer, verified
-- against THIS client's own synced copy of ns.creditsDb.officers -
-- never a self-asserted claim. Same fail-closed philosophy as
-- ns.IsGuildLeader/ns.CanEditList (Core.lua).
function ns.IsCreditsOfficer(name)
    if not name or not ns.creditsDb then return false end
    local norm = ns.NormalizeName(name)
    for _, officer in ipairs(ns.creditsDb.officers) do
        if ns.NormalizeName(officer) == norm then return true end
    end
    return false
end

-- LOCAL-only: whether the local player may manage Wall 2/3 config
-- (master toggle, test lists, multiplier) - any Designated Officer, or
-- the author account. Same LOCAL-only safety split as Core.lua's
-- CanEditListLocal (see that function's comment) - a function that also
-- verifies a REMOTE sender must stay pure name-based; see
-- IsAuthorizedConfigSender below for that side.
function ns.CanManageCreditsConfigLocal()
    if not ns.IsInTargetGuild() then return false end
    if DHTools.IsAuthorAccount and DHTools.IsAuthorAccount() then return true end
    return ns.IsCreditsOfficer(UnitName("player"))
end

-- RECEIVE-SIDE check for an incoming CFGSET/CREDITSYNCDATA: the sender
-- must be either the guild leader (who can always touch officers/config,
-- same as CanManageCreditsOfficers above) or a currently-known
-- Designated Officer. Never trusts a self-asserted claim in the message
-- itself - same idiom Sync.lua's receive-side verification uses.
local function IsAuthorizedConfigSender(senderShort)
    if ns.IsGuildLeader(senderShort) then return true end
    return ns.IsCreditsOfficer(senderShort)
end

-- BOOTSTRAP NOTE: a brand-new client (empty officers list, configUpdatedAt
-- 0) can only learn the officers list from a reply the GUILD LEADER sent
-- - IsGuildLeader resolves independently via the roster cache (rank 0),
-- but IsCreditsOfficer can only check against THIS client's own, not-yet-
-- populated officers list, so a non-leader officer's reply to a fresh
-- client is correctly rejected rather than trusted blind. Fails closed,
-- not a bug: during the test phase this just means the guild leader's
-- own client should be online when a fresh test alt first logs in. Worth
-- revisiting if that turns out to matter in practice.

--------------------------------------------------------------------------
-- Alt resolution (CM2, ongoing - see DH-Bavin-Credits-Design.md's "Data
-- model" section for the algorithm this implements verbatim)
--------------------------------------------------------------------------
-- character name (bare or realm-qualified) -> that person's mainName
-- (always returned bare, no "-Realm" suffix - matches how the ledger and
-- SeedData.lua key their entries; SkullRock is the guild's only realm,
-- so a realm suffix on the key would only add noise). Tries, in order:
-- (1) the manual-override table (ns.creditsDb.altOverrides, set via
-- Credits_SetAltOverride below - CM2's historical import doesn't write
-- to this table itself, only the ledger; this is for CM2's future
-- manual-link UI and any case GRM can't resolve), (2) GRM.GetPlayerMain
-- wrapped in pcall (GRM may not be loaded, or may not have learned this
-- character yet - confirmed 2026-09-25 via GRM-Probe that an unknown
-- name returns nil rather than erroring), (3) self-fallback - a
-- character with no linked alts is trivially its own main.
function ns.Credits_ResolveMain(characterName)
    if not characterName or characterName == "" then return nil end
    local bareName = ns.NormalizeName(characterName)

    -- altOverrides is keyed lower-cased (see Credits_SetAltOverride) -
    -- review-queue.csv's names (the Conflicts tab's link source) are
    -- stored lowercase from Step 0's reconciliation, but a live
    -- character name off GRM/mail is properly cased, so the lookup key
    -- itself must fold case even though NormalizeName above doesn't.
    if ns.creditsDb and ns.creditsDb.altOverrides then
        local override = ns.creditsDb.altOverrides[bareName:lower()]
        if override and override ~= "" then
            return override
        end
    end

    if GRM and GRM.GetPlayerMain then
        local realmQualified = bareName .. "-" .. GetRealmName()
        local ok, main = pcall(GRM.GetPlayerMain, realmQualified)
        if ok and type(main) == "string" and main ~= "" then
            return main:match("^([^%-]+)") or main
        end
    end

    return bareName
end

-- Manual alt-link overrides: LOCAL ONLY for now, same as
-- Credits_ResetTestData below - the officer-only ledger/alt-override
-- sync wire format is still CM3's job (design doc: "TBD there"), so
-- this doesn't guess at one. Each Designated Officer who adds/edits a
-- manual override does so on their own client until that sync exists;
-- officers coordinate verbally during the test phase, same as the reset
-- utility. Gated the same as the rest of this file's local config
-- writes (CanManageCreditsConfigLocal), not the stricter
-- CanManageCreditsOfficers - resolving alt-identity conflicts is
-- Designated Officer work, not guild-leader-only (design doc's Access
-- tiers: "Designated Officer... resolves alt/identity conflicts").
-- Key is lower-cased bare name (see Credits_ResolveMain's comment on
-- why) - the VALUE (mainName) keeps whatever casing the caller passed,
-- since that needs to match the ledger's own key exactly (SeedData.lua/
-- the ledger are properly-cased).
function ns.Credits_SetAltOverride(altName, mainName)
    if not ns.CanManageCreditsConfigLocal() then return false end
    if not altName or altName == "" or not mainName or mainName == "" then return false end
    ns.creditsDb.altOverrides[ns.NormalizeName(altName):lower()] = ns.NormalizeName(mainName)
    return true
end

function ns.Credits_RemoveAltOverride(altName)
    if not ns.CanManageCreditsConfigLocal() then return false end
    if not altName or altName == "" then return false end
    local key = ns.NormalizeName(altName):lower()
    if ns.creditsDb.altOverrides[key] == nil then return false end
    ns.creditsDb.altOverrides[key] = nil
    return true
end

-- Read-only lookup for UI (Conflicts tab) - whether `altName` already
-- has a manual override, and what it points to.
function ns.Credits_GetAltOverride(altName)
    if not ns.creditsDb or not ns.creditsDb.altOverrides then return nil end
    if not altName or altName == "" then return nil end
    return ns.creditsDb.altOverrides[ns.NormalizeName(altName):lower()]
end

--------------------------------------------------------------------------
-- Officers / config: local set + broadcast
--------------------------------------------------------------------------
local function ListContains(list, name)
    local norm = ns.NormalizeName(name)
    for _, n in ipairs(list) do
        if ns.NormalizeName(n) == norm then return true end
    end
    return false
end

local function AddToList(list, name)
    if not name or name == "" then return false end
    if ListContains(list, name) then return false end
    table.insert(list, name)
    return true
end

local function RemoveFromList(list, name)
    local norm = ns.NormalizeName(name)
    for i, n in ipairs(list) do
        if ns.NormalizeName(n) == norm then
            table.remove(list, i)
            return true
        end
    end
    return false
end

-- Every setter below: check permission, mutate ns.creditsDb, bump the
-- version stamp, broadcast. Returns true/false so callers (slash
-- commands today, a config UI later) can show a refusal.
function ns.SetCreditsOfficers(list)
    if not ns.CanManageCreditsOfficers() then return false end
    ns.creditsDb.officers = list
    ns.creditsDb.configUpdatedAt = time()
    ns.Credits_BroadcastConfig()
    return true
end

function ns.SetCreditsMasterToggle(enabled)
    if not ns.CanManageCreditsConfigLocal() then return false end
    ns.creditsDb.masterToggle = enabled and true or false
    ns.creditsDb.configUpdatedAt = time()
    ns.Credits_BroadcastConfig()
    return true
end

function ns.AddCreditTestReceiver(name)
    if not ns.CanManageCreditsConfigLocal() then return false end
    if not AddToList(ns.creditsDb.creditTestReceivers, name) then return false end
    ns.creditsDb.configUpdatedAt = time()
    ns.Credits_BroadcastConfig()
    return true
end

function ns.RemoveCreditTestReceiver(name)
    if not ns.CanManageCreditsConfigLocal() then return false end
    if not RemoveFromList(ns.creditsDb.creditTestReceivers, name) then return false end
    ns.creditsDb.configUpdatedAt = time()
    ns.Credits_BroadcastConfig()
    return true
end

function ns.AddCreditTestSender(name)
    if not ns.CanManageCreditsConfigLocal() then return false end
    if not AddToList(ns.creditsDb.creditTestSenders, name) then return false end
    ns.creditsDb.configUpdatedAt = time()
    ns.Credits_BroadcastConfig()
    return true
end

function ns.RemoveCreditTestSender(name)
    if not ns.CanManageCreditsConfigLocal() then return false end
    if not RemoveFromList(ns.creditsDb.creditTestSenders, name) then return false end
    ns.creditsDb.configUpdatedAt = time()
    ns.Credits_BroadcastConfig()
    return true
end

function ns.SetCreditsMultiplier(value)
    if not ns.CanManageCreditsConfigLocal() then return false end
    local num = tonumber(value)
    if not num or num <= 0 then return false end
    ns.creditsDb.multiplier = num
    ns.creditsDb.configUpdatedAt = time()
    ns.Credits_BroadcastConfig()
    return true
end

--------------------------------------------------------------------------
-- Sync: own prefix (DHBavinCreditsV1), isolated from Sync.lua's DHBavinV4
--------------------------------------------------------------------------
-- PROTOCOL (guild-only, no RAID/PARTY fallback - same as Sync.lua):
--   CFGSET|officersCSV|toggle(0/1)|receiversCSV|sendersCSV|multiplier|updatedAt
--       - full-replace broadcast of everything this file owns (officers
--         + Wall 2/3 config), sent by the setters above AFTER their own
--         permission gate has already passed. Applied by a receiver
--         only if updatedAt is strictly newer than its own AND the
--         sender is guild-leader-or-officer verified (see
--         IsAuthorizedConfigSender above) - last-writer-wins, same
--         idiom as Core.lua's k-0019 fix.
--   CREDITSYNCREQ             - "send me current officers/config"
--                                (unconditional - same GATING philosophy
--                                as Sync.lua's SYNCREQ)
--   CREDITSYNCDATA|<same payload as CFGSET>
--                             - WHISPERed reply to CREDITSYNCREQ
--
-- STANDING RULE (mirrors Sync.lua's k-0009 comment): bump this suffix
-- any time this wire format changes non-additively - a receiver on the
-- wrong prefix version simply never gets these messages, never
-- misparses them.
local PREFIX = "DHBavinCreditsV1"

local function AddonSendMessage(text, channel, target)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, text, channel, target)
    elseif SendAddonMessage then
        SendAddonMessage(PREFIX, text, channel, target)
    end
end

local function RegisterPrefix()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    elseif RegisterAddonMessagePrefix then
        pcall(RegisterAddonMessagePrefix, PREFIX)
    end
end

local function SyncChannel()
    if IsInGuild and IsInGuild() then return "GUILD" end
    return nil
end

local function SplitCSV(s)
    local t = {}
    if s and s ~= "" then
        for name in s:gmatch("[^,]+") do table.insert(t, name) end
    end
    return t
end

local function EncodeConfig()
    return table.concat({
        table.concat(ns.creditsDb.officers, ","),
        ns.creditsDb.masterToggle and "1" or "0",
        table.concat(ns.creditsDb.creditTestReceivers, ","),
        table.concat(ns.creditsDb.creditTestSenders, ","),
        tostring(ns.creditsDb.multiplier),
        tostring(ns.creditsDb.configUpdatedAt),
    }, "|")
end

-- Anchored pattern, same discipline as Sync.lua's PTSSET decode (see its
-- k-0009 comment) - a shape change here must bump PREFIX, never just
-- silently add a field and hope an old client's anchored match degrades
-- gracefully (it wouldn't: it would just fail to match at all, which is
-- actually the SAFE failure mode this pattern is chosen for).
local function ApplyIncomingConfig(payload, senderShort)
    if not IsAuthorizedConfigSender(senderShort) then return end
    local officersCSV, toggleFlag, receiversCSV, sendersCSV, multStr, updatedAtStr =
        payload:match("^(.-)|([01])|(.-)|(.-)|([%d%.]+)|(%d+)$")
    if not officersCSV then return end
    local updatedAt = tonumber(updatedAtStr) or 0
    if updatedAt <= (ns.creditsDb.configUpdatedAt or 0) then return end
    ns.creditsDb.officers = SplitCSV(officersCSV)
    ns.creditsDb.masterToggle = (toggleFlag == "1")
    ns.creditsDb.creditTestReceivers = SplitCSV(receiversCSV)
    ns.creditsDb.creditTestSenders = SplitCSV(sendersCSV)
    ns.creditsDb.multiplier = tonumber(multStr) or DEFAULT_MULTIPLIER
    ns.creditsDb.configUpdatedAt = updatedAt
    ns.Credits_EvaluateArming() -- config just changed - re-check Wall 4
    -- Live-refresh CreditsConfig.lua's window if an officer has it open
    -- and someone else's change just landed - guarded, since that file
    -- loads after this one and the window may never have been opened.
    if ns.CreditsConfig_Refresh then ns.CreditsConfig_Refresh() end
end

function ns.Credits_BroadcastConfig()
    local channel = SyncChannel()
    if not channel then return end
    AddonSendMessage("CFGSET|" .. EncodeConfig(), channel)
end

-- Called from this file's own PLAYER_LOGIN handler below - unconditional,
-- same GATING philosophy as Sync.lua's own SYNCREQ (fires regardless of
-- the local player's role; the receive side is what's permission-gated).
function ns.Credits_Init()
    RegisterPrefix()
    local channel = SyncChannel()
    if channel then
        AddonSendMessage("CREDITSYNCREQ", channel)
    end
end

-- Registered from this file's own CHAT_MSG_ADDON handler (Credits.lua
-- listens independently rather than piggybacking on Core.lua's frame -
-- keeps Wall 1's "removable by deleting one file" property literal).
function ns.Credits_OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX then return end
    if not ns.creditsDb then return end
    local myName = UnitName("player")
    local senderShort = ns.NormalizeName(sender)
    if senderShort == myName then return end -- ignore our own echo

    local msgType, rest = message:match("^([^|]+)|?(.*)$")
    if msgType == "CFGSET" then
        ApplyIncomingConfig(rest, senderShort)
    elseif msgType == "CREDITSYNCREQ" then
        -- Reply only if we actually have something worth sending - avoids
        -- two fresh installs whispering empty config back and forth.
        if (ns.creditsDb.configUpdatedAt or 0) > 0 then
            AddonSendMessage("CREDITSYNCDATA|" .. EncodeConfig(), "WHISPER", sender)
        end
    elseif msgType == "CREDITSYNCDATA" then
        ApplyIncomingConfig(rest, senderShort)
    end
end

--------------------------------------------------------------------------
-- Wall 4: lazy arming check + no-op hook stubs
--------------------------------------------------------------------------
-- Evaluated at PLAYER_LOGIN (character name isn't reliably known at
-- addon load - same reasoning as Sync.lua's Sync_Init timing) AND again
-- whenever config changes (ApplyIncomingConfig above). Two independent
-- conditions must BOTH be true: masterToggle ON AND this character on
-- the list for that specific hook. Removing a name disarms the checked
-- flag immediately, but un-hooking a live SendMailFrame/inbox hook isn't
-- reliable in this API - a full disarm needs /reload (design doc states
-- this plainly; not attempting to work around it).
ns.creditsArmedInbox = false
ns.creditsArmedOutgoing = false

local function NameOnList(list, name)
    local norm = ns.NormalizeName(name)
    for _, n in ipairs(list or {}) do
        if ns.NormalizeName(n) == norm then return true end
    end
    return false
end

-- CM4/CM5 own the real hook bodies. Deliberately no-ops for now (design
-- doc: "two no-op hook-installation sites... so both gates can be
-- verified before any mail code exists behind them").
local function InstallInboxHook()
    ns.CreditsPrint("[TEST] Inbox credit hook armed for " .. UnitName("player") .. " (no-op until CM4).")
end

local function InstallOutgoingHook()
    ns.CreditsPrint("[TEST] Outgoing credit hook armed for " .. UnitName("player") .. " (no-op until CM5).")
end

function ns.Credits_EvaluateArming()
    if not ns.creditsDb then return end
    local myName = UnitName("player")
    if not ns.creditsDb.masterToggle then
        ns.creditsArmedInbox = false
        ns.creditsArmedOutgoing = false
        return
    end
    if NameOnList(ns.creditsDb.creditTestReceivers, myName) and not ns.creditsArmedInbox then
        ns.creditsArmedInbox = true
        InstallInboxHook()
    end
    if NameOnList(ns.creditsDb.creditTestSenders, myName) and not ns.creditsArmedOutgoing then
        ns.creditsArmedOutgoing = true
        InstallOutgoingHook()
    end
end

--------------------------------------------------------------------------
-- Mid-testing reset utility
--------------------------------------------------------------------------
-- Wipes the test-scoped credit data (ledger, alt-override table,
-- transaction log) back to empty - callable at any point during CM2-CM8
-- testing, distinct from CM9's cutover flip and Step 9.5's full reseed.
-- LOCAL only for CM1: each Designated Officer/Bavin runs this on their
-- own client. No broadcast yet - CM3 hasn't defined the ledger sync wire
-- format this would need to ride, so this deliberately doesn't guess at
-- one; officers coordinate a reset verbally during the test phase.
function ns.Credits_ResetTestData()
    if not ns.CanManageCreditsConfigLocal() then return false end
    ns.creditsDb.ledger = {}
    ns.creditsDb.altOverrides = {}
    ns.creditsDb.transactionLog = {}
    ns.CreditsPrint("Test credit data wiped (ledger, alt overrides, transaction log).")
    return true
end

--------------------------------------------------------------------------
-- Event wiring
--------------------------------------------------------------------------
-- Own frame, independent of Core.lua's (see file header: Wall 1 means
-- this whole feature is removable by deleting this one file).
ns.creditsFrame = CreateFrame("Frame")
ns.creditsFrame:RegisterEvent("PLAYER_LOGIN")
ns.creditsFrame:RegisterEvent("CHAT_MSG_ADDON")
ns.creditsFrame:SetScript("OnEvent", function(_, event, ...)
    if not DHTools.IsModuleEnabled("bavin") then return end
    if event == "PLAYER_LOGIN" then
        ns.InitCreditsDB()
        ns.Credits_Init()
        ns.Credits_EvaluateArming()
    elseif event == "CHAT_MSG_ADDON" then
        ns.Credits_OnAddonMessage(...)
    end
end)

--------------------------------------------------------------------------
-- Slash command surface (dispatched from Core.lua's /dhb, "credits" cmd)
--------------------------------------------------------------------------
-- 2026-09-25 update: the real UI now exists - CreditsConfig.lua's
-- standalone "Bavin Rep & Credit Config" window, opened via a button in
-- DH-Tools\Config.lua's existing Bavin officer section (Chris: the
-- existing page "should basically remain the same" - just add an open
-- button, don't rebuild it inline). These slash commands are NOT
-- removed - they're a useful scriptable/diagnostic fallback - but the
-- window is now the primary interface for everyday use.
local function ShowCreditsStatus()
    if not ns.creditsDb then
        ns.CreditsPrint("Not initialized yet.")
        return
    end
    ns.CreditsPrint("Master toggle: " .. (ns.creditsDb.masterToggle and "|cff33ff33ON|r" or "|cffff3333OFF|r"))
    ns.CreditsPrint("Multiplier: " .. ns.creditsDb.multiplier .. " credits per point")
    ns.CreditsPrint("Officers: " .. (#ns.creditsDb.officers > 0 and table.concat(ns.creditsDb.officers, ", ") or "none"))
    ns.CreditsPrint("Test receivers (inbox hook): " .. (#ns.creditsDb.creditTestReceivers > 0 and table.concat(ns.creditsDb.creditTestReceivers, ", ") or "none"))
    ns.CreditsPrint("Test senders (outgoing hook): " .. (#ns.creditsDb.creditTestSenders > 0 and table.concat(ns.creditsDb.creditTestSenders, ", ") or "none"))
    ns.CreditsPrint("This character armed: inbox=" .. tostring(ns.creditsArmedInbox) .. " outgoing=" .. tostring(ns.creditsArmedOutgoing))
end

-- rest is everything after "credits " in "/dhb credits <rest>".
function ns.Credits_HandleSlash(rest)
    rest = rest or ""
    local sub, arg1, arg2 = rest:match("^(%S*)%s*(%S*)%s*(.-)$")
    sub = (sub or ""):lower()

    if sub == "" or sub == "status" then
        ShowCreditsStatus()
    elseif sub == "window" or sub == "config" then
        if ns.CreditsConfig_Toggle then
            ns.CreditsConfig_Toggle()
        else
            ns.CreditsPrint("CreditsConfig.lua isn't loaded.")
        end
    elseif sub == "toggle" then
        if arg1 ~= "on" and arg1 ~= "off" then
            ns.CreditsPrint("Usage: /dhb credits toggle on|off")
        elseif ns.SetCreditsMasterToggle(arg1 == "on") then
            ns.CreditsPrint("Master toggle set to " .. arg1:upper() .. ".")
        else
            ns.CreditsPrint("Refused - Designated Officer or author account only.")
        end
    elseif sub == "multiplier" then
        if arg1 == "" then
            ns.CreditsPrint("Usage: /dhb credits multiplier <positive number>")
        elseif ns.SetCreditsMultiplier(arg1) then
            ns.CreditsPrint("Multiplier set to " .. arg1 .. " credits per point.")
        else
            ns.CreditsPrint("Refused - not a positive number, or you're not a Designated Officer/author account.")
        end
    elseif sub == "reset" then
        if arg1 ~= "confirm" then
            ns.CreditsPrint("This wipes ALL test credit data (ledger, alt overrides, transaction log). Run '/dhb credits reset confirm' to proceed.")
        elseif ns.Credits_ResetTestData() then
            -- ns.Credits_ResetTestData already prints confirmation.
        else
            ns.CreditsPrint("Refused - Designated Officer or author account only.")
        end

    elseif sub == "officer" then
        if arg1 == "add" and arg2 ~= "" then
            local list = {}
            for _, n in ipairs(ns.creditsDb.officers) do table.insert(list, n) end
            if ListContains(list, arg2) then
                ns.CreditsPrint(arg2 .. " is already a Designated Officer.")
            elseif not ns.CanManageCreditsOfficers() then
                ns.CreditsPrint("Refused - guild leader or author account only.")
            else
                table.insert(list, arg2)
                ns.SetCreditsOfficers(list)
                ns.CreditsPrint("Added " .. arg2 .. " as a Designated Officer.")
            end
        elseif arg1 == "remove" and arg2 ~= "" then
            local list = {}
            local found = false
            for _, n in ipairs(ns.creditsDb.officers) do
                if ns.NormalizeName(n) ~= ns.NormalizeName(arg2) then
                    table.insert(list, n)
                else
                    found = true
                end
            end
            if not found then
                ns.CreditsPrint(arg2 .. " isn't a Designated Officer.")
            elseif not ns.CanManageCreditsOfficers() then
                ns.CreditsPrint("Refused - guild leader or author account only.")
            else
                ns.SetCreditsOfficers(list)
                ns.CreditsPrint("Removed " .. arg2 .. " as a Designated Officer.")
            end
        else
            ns.CreditsPrint("Usage: /dhb credits officer add|remove <name>")
        end

    elseif sub == "receiver" then
        if arg1 == "add" and arg2 ~= "" then
            if ns.AddCreditTestReceiver(arg2) then
                ns.CreditsPrint("Added " .. arg2 .. " to creditTestReceivers (inbox hook).")
            else
                ns.CreditsPrint("Refused, or already on the list - Designated Officer/author account only.")
            end
        elseif arg1 == "remove" and arg2 ~= "" then
            if ns.RemoveCreditTestReceiver(arg2) then
                ns.CreditsPrint("Removed " .. arg2 .. " from creditTestReceivers. Full disarm needs /reload on that character.")
            else
                ns.CreditsPrint("Refused, or not on the list - Designated Officer/author account only.")
            end
        else
            ns.CreditsPrint("Usage: /dhb credits receiver add|remove <name>")
        end
    elseif sub == "sender" then
        if arg1 == "add" and arg2 ~= "" then
            if ns.AddCreditTestSender(arg2) then
                ns.CreditsPrint("Added " .. arg2 .. " to creditTestSenders (outgoing hook).")
            else
                ns.CreditsPrint("Refused, or already on the list - Designated Officer/author account only.")
            end
        elseif arg1 == "remove" and arg2 ~= "" then
            if ns.RemoveCreditTestSender(arg2) then
                ns.CreditsPrint("Removed " .. arg2 .. " from creditTestSenders. Full disarm needs /reload on that character.")
            else
                ns.CreditsPrint("Refused, or not on the list - Designated Officer/author account only.")
            end
        else
            ns.CreditsPrint("Usage: /dhb credits sender add|remove <name>")
        end
    else
        ns.CreditsPrint("Unknown: /dhb credits " .. rest)
        ns.CreditsPrint("Commands: window (opens the config UI), status, toggle on|off, multiplier <n>, officer add|remove <name>, receiver add|remove <name>, sender add|remove <name>, reset confirm")
    end
end
