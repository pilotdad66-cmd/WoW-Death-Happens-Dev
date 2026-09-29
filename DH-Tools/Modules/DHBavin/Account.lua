-- DH-Tools: Modules\DHBavin\Account.lua
-- "View my Account" window (2026-09-29): every character on the player's
-- account that we know about (main + alts), with level, class and guild
-- rank, plus Reputation and Store Credits from the local Bavin ledger.
--
-- Where the data comes from (all best-effort, nothing is invented):
--   * Character list: the local Credits ledger record (mainToon/alts)
--     when this client has one, else the shipped static AltRoster.lua,
--     else just the logged-in character - PLUS every character this
--     WoW account has logged into with DH-Tools (DHToolsAccountDB.characters,
--     recorded below), since those are provably the same account.
--   * Level/class/rank for guild members: live from the guild roster.
--   * Level/class for characters outside the guild: only if we've seen
--     them log in (the record above); otherwise shown as "?".
--   * Reputation / Store Credits: the ledger record if this client has
--     one. The ledger is not yet synced guild-wide (CM3), so most
--     members' clients show "not synced yet" - by design for now.

local DHTools = DHTools
DHTools.Bavin = DHTools.Bavin or {}
local ns = DHTools.Bavin

local TARGET_GUILD = "Death Happens"
local FRAME_W, FRAME_H = 520, 480
local ROW_H = 20
local COL_NAME_W, COL_LVL_W, COL_CLASS_W = 130, 34, 90

local frame

--------------------------------------------------------------------------
-- Account-wide record of characters this WoW account has logged into
--------------------------------------------------------------------------
local function CharStore()
    if type(DHToolsAccountDB) ~= "table" then DHToolsAccountDB = {} end
    if type(DHToolsAccountDB.characters) ~= "table" then DHToolsAccountDB.characters = {} end
    return DHToolsAccountDB.characters
end

function ns.Account_RecordCurrentCharacter()
    local name = UnitName and UnitName("player")
    if not name or name == "" then return end
    local realm = GetRealmName and GetRealmName() or ""
    local className, classFile = UnitClass("player")
    local guildName, rankName
    if IsInGuild and IsInGuild() and GetGuildInfo then
        guildName, rankName = GetGuildInfo("player")
    end
    CharStore()[name .. "-" .. realm] = {
        name = name,
        realm = realm,
        className = className,
        classFile = classFile,
        level = UnitLevel("player"),
        guild = guildName or false,
        rankName = rankName or false,
        seen = time(),
    }
end

--------------------------------------------------------------------------
-- Data assembly
--------------------------------------------------------------------------

-- The ledger record for the local player's account, or nil when this
-- client has none (not seeded / not synced). Second return is the
-- ledger key (discordName). Nil-safe on every step - the Store window's
-- bottom bar calls this too.
function ns.GetLocalAccountRecord()
    local db = ns.creditsDb
    if not db or type(db.toonIndex) ~= "table" or type(db.ledger) ~= "table" then return nil end
    local me = UnitName and UnitName("player")
    if not me then return nil end
    local key = db.toonIndex[me:lower()]
    local rec = key and db.ledger[key]
    if rec then return rec, key end
    return nil
end

local function IsBadName(n)
    -- Some shipped roster names carry mojibake (U+FFFD) from the CSV
    -- import; never show those.
    return type(n) ~= "string" or n == "" or n:find("\239\191\189", 1, true) ~= nil
end

-- { {name=, isMain=}, ... } main first, then alts alphabetical, then any
-- recorded same-account characters not already listed. Also returns the
-- source label ("ledger" | "roster" | "self").
local function ResolveAccountToons()
    local me = UnitName("player") or "?"
    local lme = me:lower()
    local main, alts, source

    local rec = ns.GetLocalAccountRecord()
    if rec and rec.mainToon and rec.mainToon ~= "" then
        main, alts, source = rec.mainToon, rec.alts or {}, "ledger"
    else
        for mainName, list in pairs(ns.CreditsAltRoster or {}) do
            local hit = mainName:lower() == lme
            if not hit then
                for _, a in ipairs(list) do
                    if a:lower() == lme then hit = true break end
                end
            end
            if hit then main, alts, source = mainName, list, "roster" break end
        end
    end
    if not main then main, alts, source = me, {}, "self" end

    local out, seen = {}, {}
    local function add(name, isMain)
        if IsBadName(name) then return end
        local k = name:lower()
        if seen[k] then return end
        seen[k] = true
        out[#out + 1] = { name = name, isMain = isMain or false }
    end
    add(main, true)
    local sortedAlts = {}
    for _, a in ipairs(alts) do sortedAlts[#sortedAlts + 1] = a end
    table.sort(sortedAlts, function(a, b) return a:lower() < b:lower() end)
    for _, a in ipairs(sortedAlts) do add(a, false) end

    local realm = GetRealmName and GetRealmName() or ""
    local extras = {}
    for _, r in pairs(CharStore()) do
        if r.realm == realm then extras[#extras + 1] = r.name end
    end
    table.sort(extras, function(a, b) return a:lower() < b:lower() end)
    for _, n in ipairs(extras) do add(n, false) end
    add(me, false)

    return out, source, main
end

-- lower(name) -> {name, rankName, rankIndex, level, className, classFile, online}
-- Second return is whether we actually have Death Happens' roster.
local function ReadGuildRoster()
    local map = {}
    if not (ns.IsInTargetGuild and ns.IsInTargetGuild()) then return map, false end
    local n = GetNumGuildMembers and GetNumGuildMembers() or 0
    for i = 1, n do
        local name, rankName, rankIndex, level, className, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
        if name then
            local bare = ns.NormalizeName(name)
            map[bare:lower()] = {
                name = bare, rankName = rankName, rankIndex = rankIndex, level = level,
                className = className, classFile = classFile, online = online == true,
            }
        end
    end
    return map, n > 0
end

local function FindRecorded(name)
    local realm = GetRealmName and GetRealmName() or ""
    local r = CharStore()[name .. "-" .. realm]
    if r then return r end
    local l = name:lower()
    for _, rec in pairs(CharStore()) do
        if rec.realm == realm and rec.name:lower() == l then return rec end
    end
    return nil
end

-- Builds the scroll-list dataset plus summary info.
local function BuildAccountData()
    local toons, source, main = ResolveAccountToons()
    local roster, haveRoster = ReadGuildRoster()

    local guildRows, otherRows = {}, {}
    for _, t in ipairs(toons) do
        local g = roster[t.name:lower()]
        local rec = FindRecorded(t.name)
        if g then
            guildRows[#guildRows + 1] = {
                kind = "char", name = g.name, isMain = t.isMain, level = g.level,
                className = g.className, classFile = g.classFile,
                status = g.rankName or "", online = g.online,
            }
        elseif not haveRoster and rec and rec.guild == TARGET_GUILD then
            -- No live roster on this character (it's in another guild, or
            -- the roster hasn't loaded yet): fall back to what we
            -- recorded the last time it was logged in.
            guildRows[#guildRows + 1] = {
                kind = "char", name = rec.name, isMain = t.isMain, level = rec.level,
                className = rec.className, classFile = rec.classFile,
                status = (rec.rankName or "") ~= "" and rec.rankName or "(last seen)",
                stale = true,
            }
        else
            otherRows[#otherRows + 1] = {
                kind = "char", name = t.name, isMain = t.isMain,
                level = rec and rec.level or nil,
                className = rec and rec.className or nil,
                classFile = rec and rec.classFile or nil,
                status = (rec and rec.guild) and "Other guild" or (rec and "No guild" or "Not seen yet"),
            }
        end
    end

    local data = {}
    data[#data + 1] = { kind = "header", text = TARGET_GUILD .. " (" .. #guildRows .. ")" }
    if #guildRows == 0 then
        data[#data + 1] = { kind = "note", text = "No characters found in the guild roster yet." }
    end
    for _, r in ipairs(guildRows) do data[#data + 1] = r end
    if #otherRows > 0 then
        data[#data + 1] = { kind = "header", text = "On this server, not in " .. TARGET_GUILD .. " (" .. #otherRows .. ")" }
        for _, r in ipairs(otherRows) do data[#data + 1] = r end
    end
    return data, main, source
end

--------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------
local function ClassColored(text, classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if not c then return text end
    return string.format("|cff%02x%02x%02x%s|r", (c.r or 1) * 255, (c.g or 1) * 255, (c.b or 1) * 255, text)
end

local function CreateRow(row)
    row.headerText = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    row.headerText:SetPoint("LEFT", 4, 0)
    row.headerText:SetPoint("RIGHT", -4, 0)
    row.headerText:SetJustifyH("LEFT")

    row.nameText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.nameText:SetPoint("LEFT", 8, 0)
    row.nameText:SetWidth(COL_NAME_W)
    row.nameText:SetJustifyH("LEFT")
    row.nameText:SetWordWrap(false)

    row.lvlText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.lvlText:SetPoint("LEFT", row.nameText, "RIGHT", 4, 0)
    row.lvlText:SetWidth(COL_LVL_W)
    row.lvlText:SetJustifyH("CENTER")

    row.classText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.classText:SetPoint("LEFT", row.lvlText, "RIGHT", 4, 0)
    row.classText:SetWidth(COL_CLASS_W)
    row.classText:SetJustifyH("LEFT")
    row.classText:SetWordWrap(false)

    row.statusText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.statusText:SetPoint("LEFT", row.classText, "RIGHT", 4, 0)
    row.statusText:SetPoint("RIGHT", -4, 0)
    row.statusText:SetJustifyH("LEFT")
    row.statusText:SetWordWrap(false)
end

local function UpdateRow(row, d)
    local isChar = d.kind == "char"
    row.headerText:SetShown(not isChar)
    row.nameText:SetShown(isChar)
    row.lvlText:SetShown(isChar)
    row.classText:SetShown(isChar)
    row.statusText:SetShown(isChar)
    if not isChar then
        if d.kind == "note" then
            row.headerText:SetText("|cff888888" .. d.text .. "|r")
        else
            row.headerText:SetText(d.text)
        end
        return
    end
    local nm = ClassColored(d.name, d.classFile)
    if d.isMain then nm = nm .. " |cffffd100(Main)|r" end
    row.nameText:SetText(nm)
    row.lvlText:SetText(d.level and tostring(d.level) or "|cff888888?|r")
    row.classText:SetText(d.className and ClassColored(d.className, d.classFile) or "|cff888888?|r")
    local status = d.status or ""
    if d.online then status = status .. "  |cff40ff40*|r" end
    if d.stale then status = "|cff888888" .. status .. "|r" end
    row.statusText:SetText(status)
end

-- Whole number with thousands separators (BreakUpLargeNumbers is a client
-- global; plain tostring keeps the headless harness working).
local function Num(n)
    n = math.floor((tonumber(n) or 0) + 0.5)
    return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

local function Fs(parent, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    return fs
end

local function CreateAccountFrame()
    local f = CreateFrame("Frame", "DHBavinAccountFrame", UIParent, "BasicFrameTemplateWithInset")
    frame = f
    f:SetSize(FRAME_W, FRAME_H)
    f:SetPoint("CENTER")
    if f.TitleText then f.TitleText:SetText("My Account") end
    tinsert(UISpecialFrames, "DHBavinAccountFrame")
    DHTools.InitStandaloneWindow(f)

    -- Resizable like every other DH-Tools window: bottom-right grip, same
    -- SetResizeBounds / SetMinResize+SetMaxResize fallback as Config.lua.
    -- The character list is anchored to the frame's corners, so it (and its
    -- row pool) follows the new size on its own.
    f:SetResizable(true)
    if f.SetResizeBounds then
        pcall(f.SetResizeBounds, f, 480, 360, 800, 800)
    else
        pcall(f.SetMinResize, f, 480, 360)
        pcall(f.SetMaxResize, f, 800, 800)
    end
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing() end)

    f.mainText = Fs(f, "GameFontNormalLarge")
    f.mainText:SetPoint("TOPLEFT", 16, -36)
    f.mainText:SetPoint("RIGHT", -16, 0)

    f.repText = Fs(f)
    f.repText:SetPoint("TOPLEFT", f.mainText, "BOTTOMLEFT", 0, -10)
    f.repText:SetPoint("RIGHT", -16, 0)

    f.repDetail = Fs(f, "GameFontHighlightSmall")
    f.repDetail:SetPoint("TOPLEFT", f.repText, "BOTTOMLEFT", 0, -3)
    f.repDetail:SetPoint("RIGHT", -16, 0)

    f.creditsText = Fs(f)
    f.creditsText:SetPoint("TOPLEFT", f.repDetail, "BOTTOMLEFT", 0, -8)
    f.creditsText:SetPoint("RIGHT", -16, 0)

    f.noteText = Fs(f, "GameFontDisableSmall")
    f.noteText:SetPoint("TOPLEFT", f.creditsText, "BOTTOMLEFT", 0, -6)
    f.noteText:SetPoint("RIGHT", -16, 0)
    f.noteText:SetWordWrap(true)

    -- Column headers
    f.colHeader = CreateFrame("Frame", nil, f)
    f.colHeader:SetHeight(16)
    f.colHeader:SetPoint("TOPLEFT", f.noteText, "BOTTOMLEFT", 0, -10)
    f.colHeader:SetPoint("RIGHT", f, "RIGHT", -34, 0)
    local function Col(text, anchorTo, x, w, justify)
        local fs = Fs(f.colHeader, "GameFontNormalSmall")
        if anchorTo then fs:SetPoint("LEFT", anchorTo, "RIGHT", 4, 0) else fs:SetPoint("LEFT", x, 0) end
        if w then fs:SetWidth(w) end
        fs:SetJustifyH(justify or "LEFT")
        fs:SetText(text)
        return fs
    end
    local hName = Col("Character", nil, 8, COL_NAME_W)
    local hLvl = Col("Lv", hName, nil, COL_LVL_W, "CENTER")
    local hClass = Col("Class", hLvl, nil, COL_CLASS_W)
    Col("Guild Rank", hClass, nil, 120)

    f.list = DHTools.Widgets.CreateScrollList(f, {
        rowHeight = ROW_H,
        rightInset = 24,
        createRow = CreateRow,
        updateRow = UpdateRow,
        emptyText = "No characters found.",
    })
    f.list.frame:SetPoint("TOPLEFT", f.colHeader, "BOTTOMLEFT", -4, -2)
    f.list.frame:SetPoint("BOTTOMRIGHT", -30, 34)

    f.footer = Fs(f, "GameFontDisableSmall")
    f.footer:SetPoint("BOTTOMLEFT", 16, 12)
    f.footer:SetPoint("RIGHT", -26, 0) -- clear of the resize grip
    f.footer:SetWordWrap(true)
    f.footer:SetText("Level and class for characters outside the guild appear once you've logged into them with DH-Tools. Green * = online.")

    f:SetScript("OnShow", function()
        ns.Account_RecordCurrentCharacter()
        if ns.RequestGuildRoster then ns.RequestGuildRoster() end
        ns.Account_Refresh()
    end)
    return f
end

function ns.Account_Refresh()
    if not frame or not frame:IsShown() then return end
    local data, main = BuildAccountData()
    frame.mainText:SetText("Main: " .. (main or "?"))

    local rec = ns.GetLocalAccountRecord()
    if rec then
        local tier = rec.tier or "?"
        local prestige = tonumber(rec.prestige) or 0
        frame.repText:SetText("Reputation: |cffffd100" .. tostring(tier) .. (prestige > 0 and (" P" .. prestige) or "") .. "|r")
        -- rec.points is progress inside the CURRENT tier (resets on tier-up /
        -- prestige); rec.lifetimePoints never resets. Label them so the two
        -- different numbers don't read as a discrepancy.
        local cap = ns.CreditsTierCaps and ns.CreditsTierCaps[rec.tier]
        local curPts = math.floor((tonumber(rec.points) or 0) + 0.5)
        -- "Tier Points: xxx/yyy" already shows how far to the next tier (yyy is
        -- the tier's cap; at Exalted it is the prestige lap size), so there is
        -- no separate "to next tier" number.
        local tierPts = Num(curPts) .. (cap and ("/" .. Num(cap)) or "")
        frame.repDetail:SetText("Tier Points: |cffffd100" .. tierPts .. "|r"
            .. "   Total Points: |cffffd100" .. Num(rec.lifetimePoints) .. "|r")
        -- lifetimeCredits only ever goes up (credits can be spent, this can't);
        -- records saved before the field existed fall back to the balance.
        local lifeCredits = tonumber(rec.lifetimeCredits) or tonumber(rec.credits) or 0
        frame.creditsText:SetText("Credits Balance: |cffffd100" .. Num(rec.credits) .. "|r"
            .. "   Lifetime Credits: |cffffd100" .. Num(lifeCredits) .. "|r")
        frame.noteText:SetText("")
    else
        frame.repText:SetText("Reputation: |cff888888not synced yet|r")
        frame.repDetail:SetText("")
        frame.creditsText:SetText("Credits Balance: |cff888888not synced yet|r")
        frame.noteText:SetText("Reputation and Store Credits come from the guild ledger, which isn't shared to your client yet. They'll show here once it is.")
    end
    frame.list:SetData(data)
end

function ns.Account_Toggle()
    if DHTools.IsModuleEnabled and not DHTools.IsModuleEnabled("bavin") then
        print("|cff33ff99DH-Tools:|r Bavin Points is disabled - enable it in DH-Tools Settings to view your account.")
        return
    end
    if not frame then
        local ok, err = pcall(CreateAccountFrame)
        if not ok then
            if frame then frame:Hide() end
            frame = nil
            print("|cffff3333DH-Tools: could not build the account window: " .. tostring(err) .. "|r")
            return
        end
    end
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

--------------------------------------------------------------------------
-- Events: keep the account-wide character record fresh
--------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("PLAYER_GUILD_UPDATE")
ev:RegisterEvent("GUILD_ROSTER_UPDATE")
ev:SetScript("OnEvent", function(_, event)
    if DHTools.IsModuleEnabled and not DHTools.IsModuleEnabled("bavin") then return end
    if event == "GUILD_ROSTER_UPDATE" then
        if frame and frame:IsShown() then ns.Account_Refresh() end
        return
    end
    ns.Account_RecordCurrentCharacter()
end)
