------------------------------------------------------------------------
-- Zore's Combat Text - Init / Bootstrap
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
ZSBT.ZCT = ZSBT.ZCT or {}
local ZCT = ZSBT.ZCT

ZCT = ZCT or {}

------------------------------------------------------------------------
-- Defaults (merged into ZCTDB.profile)
------------------------------------------------------------------------
ZCT.DEFAULTS = {
    profile = {
        enabled = true,
        combatOnly = false,
        suppressBlizzardFCT = true,    -- hide Blizzard text, keep feed
        hideMinimap = false,           -- show the LibDBIcon minimap button
        probe = {
            enabled = true,            -- empirical arg recording (dev)
        },
        debug = {
            -- channel -> level, see Core/Debug.lua
            probe = 0, lines = 0, filter = 0, incoming = 0,
            outgoing = 0, correlate = 0, display = 0, config = 0,
        },
        masterFont = {
            face = nil,                -- nil = game default font
            size = 18,
            outline = "None",          -- None/Thin/Thick/Monochrome
            alpha = 1.0,
        },
        scrollAreas = {
            Outgoing = {
                xOffset = 250, yOffset = -10,
                width = 100, height = 300,
                alignment = "Center", direction = "Up",
                animation = "Straight", animSpeed = 1.0,
            },
            Incoming = {
                xOffset = -250, yOffset = -10,
                width = 100, height = 300,
                alignment = "Center", direction = "Up",
                animation = "Straight", animSpeed = 1.0,
            },
            Notifications = {
                xOffset = 0, yOffset = -200,
                width = 340, height = 200,
                alignment = "Center", direction = "Up",
                animation = "Straight", animSpeed = 1.0,
            },
        },
        categories = {},               -- populated Phase 2+
        showIcons = true,              -- spell icons on attributed hits
        hideOverheal = true,           -- suppress incoming heals at full HP
        casterMode = false,            -- unattributed melee => pet outgoing
        groupPolicy = {                -- used only when Context:Strict()
            spells = "strict",         -- direct/heal need cast attribution
            dots   = "auto",           -- tick/hot need aura proof (auto)
            misses = "allow",          -- miss lines are self-proving (ours only)
            auto   = "block",          -- unattributed melee/ranged/miss
        },
        crit = {
            damage = {
                useColor = true,       -- crits use crit color over school
                color = { 1.00, 1.00, 0.20 },
                scale = 1.35,          -- font size multiplier
                style = "Normal",      -- Normal / Pow / Sticky
                area = nil,            -- nil = same area as the category
            },
            heal = {
                useColor = true,
                color = { 1.00, 1.00, 0.20 },
                scale = 1.35,
                style = "Normal",
                area = nil,
            },
        },
        -- Alerts > Notifications (Core/Notify.lua). Flags mirror the
        -- category registry defaults; routing/templates/per-type style
        -- are created lazily by the module and config UI.
        notifications = {
            enterCombat = true, leaveCombat = true,
            interrupts = true, caststops = false, auras = true,
            power = false, procs = false,
            playerXP = true, honor = true, reputation = true,
            companionXP = true,
            lootItems = true, lootMoney = true, lootCurrency = true,
            tradeskillUps = true, tradeskillLearned = true,
            externalAddons = true,
        },
        -- Loot alert filtering + money display (ported from ZSBT).
        loot = {
            showCreated = false,         -- "You create" loot lines
            alwaysShowQuestItems = true, -- bypass quality/name filters
            qualityExclusions = {},      -- [itemQuality] = true
            itemExclusions = {},         -- [itemName] = true
            itemsAllowed = {},           -- [itemName] = true (whitelist)
        },
        notificationsMoneyFormat = {
            lootMoney = "text",          -- text | icons
        },
        -- Aura data is class-scoped: db.auraByClass[classFile] =
        -- {auraRules, auraTrack, auraGlobal}, created lazily by
        -- Core/Auras.lua. Legacy top-level keys migrate into the
        -- current class's bucket on first access.
        spam = {
            enabled = true,            -- merge provably-same-spell hits
            mergeWindow = 0.6,
            mergeShowCount = true,
        },
    },
}

------------------------------------------------------------------------
-- Settings: per-character DB + preset library
--
-- ZCTDB.char["realm-name"] = the character's live settings (same shape
-- as DEFAULTS.profile). ZCTDB.presets[name] = account-level custom
-- preset snapshots. Built-in presets are override fragments merged over
-- DEFAULTS at apply time. ZCT:GetDB() stays the single funnel.
------------------------------------------------------------------------
ZCTDB = ZCTDB or nil
-- NOTE: ZSBTDB is nil while addon files load (SavedVariables populate
-- after file load, before PLAYER_LOGIN). The ZSBTDB.ZCT bind therefore
-- happens in OnLogin() below, not here.

local function copyValue(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = copyValue(val) end
    return out
end

local function deepMerge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            deepMerge(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = copyValue(v)
        end
    end
end

local function charKey()
    if ZCT._charKey then return ZCT._charKey end
    local name = UnitName and UnitName("player") or nil
    -- Don't cache until the name is real — a pre-login GetDB() must not
    -- pin settings to a junk "unknown" bucket.
    if type(name) ~= "string" or name == "" then return "unknown" end
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
        or (GetRealmName and GetRealmName()) or "local"
    ZCT._charKey = realm .. "-" .. name
    return ZCT._charKey
end

local function charDB()
    if type(ZCTDB) ~= "table" then ZCTDB = {} end
    if type(ZCTDB.char) ~= "table" then ZCTDB.char = {} end
    local key = charKey()
    if type(ZCTDB.char[key]) ~= "table" then ZCTDB.char[key] = {} end
    return ZCTDB.char[key]
end

-- Crit settings used to be one flat table per direction; they are now
-- split into damage/heal buckets. Saved flat keys survive deepMerge as
-- siblings of the new buckets — fold them into BOTH buckets (they
-- applied to every crit before) and drop the flat copies.
local CRIT_FLAT_KEYS = { "useColor", "color", "scale", "style", "area",
    "fontOverride", "font", "soundEnabled", "sound", "soundFile" }
local function migrateCrits(db)
    for _, ck in ipairs({ "crit", "critIn" }) do
        local c = db[ck]
        if type(c) == "table" then
            local hasFlat = false
            for _, k in ipairs(CRIT_FLAT_KEYS) do
                if c[k] ~= nil then hasFlat = true break end
            end
            if hasFlat then
                for _, k in ipairs(CRIT_FLAT_KEYS) do
                    local v = c[k]
                    if v ~= nil then
                        for _, b in ipairs({ "damage", "heal" }) do
                            if type(c[b]) ~= "table" then c[b] = {} end
                            c[b][k] = copyValue(v)
                        end
                    end
                    c[k] = nil
                end
            end
        end
    end
end

function ZCT:GetDB()
    if type(ZCTDB) ~= "table" then ZCTDB = {} end
    -- One-time migration: legacy account-wide ZCTDB.profile becomes this
    -- character's settings. Existing keys win over nothing (char table
    -- starts empty); the old key is dropped so SV stays clean.
    if type(ZCTDB.profile) == "table" then
        local dst = charDB()
        for k, v in pairs(ZCTDB.profile) do
            if dst[k] == nil then dst[k] = v end
        end
        ZCTDB.profile = nil
    end
    local db = charDB()
    deepMerge(db, ZCT.DEFAULTS.profile)
    -- Self-heal non-numeric masterFont values (bad saved data)
    local mf = db.masterFont
    if type(mf) == "table" then
        if tonumber(mf.size) == nil then mf.size = 18 end
        if tonumber(mf.alpha) == nil then mf.alpha = 1.0 end
    end
    migrateCrits(db)
    return db
end

-- One-time layout migration: v0 defaults had Incoming right / Outgoing
-- left; the user prefers Incoming left / Outgoing right. deepMerge never
-- overwrites saved values, so fix the saved offsets once.
local function migrateLayout(db)
    local sa = db.scrollAreas
    if not sa then return end
    if sa.Incoming and sa.Incoming.xOffset == 250
        and sa.Outgoing and sa.Outgoing.xOffset == -250 then
        sa.Incoming.xOffset = -250
        sa.Outgoing.xOffset = 250
    end
end

------------------------------------------------------------------------
-- Preset library
--
-- Built-ins are override fragments deep-merged over DEFAULTS.profile at
-- apply time (always reflect current defaults). Custom presets are full
-- snapshots stored in ZCTDB.presets — account-level, copyable to any
-- character.
------------------------------------------------------------------------
local BUILTIN_PRESETS = {
    Default = {},
    ["Melee DPS"] = {
        masterFont = { size = 18 },
        scrollAreas = {
            Incoming = { xOffset = -230, yOffset = -10, width = 120,
                height = 280 },
            Outgoing = { xOffset = 230, yOffset = -10, width = 120,
                height = 280 },
        },
        notifications = { interrupts = true, caststops = true,
            procs = false },
        spam = { mergeWindow = 0.4 },
    },
    ["Caster DPS"] = {
        masterFont = { size = 20 },
        scrollAreas = {
            Incoming = { xOffset = -260, yOffset = -10, width = 140,
                height = 340 },
            Outgoing = { xOffset = 260, yOffset = -10, width = 160,
                height = 380 },
        },
        notifications = { interrupts = true, auras = true },
        spam = { mergeWindow = 0.8 },
    },
    Healer = {
        masterFont = { size = 18 },
        scrollAreas = {
            Incoming = { xOffset = -280, yOffset = -60, width = 180,
                height = 420 },
            Outgoing = { xOffset = 280, yOffset = -10, width = 110,
                height = 240 },
        },
        notifications = { interrupts = true, caststops = true,
            playerXP = false },
        spam = { mergeWindow = 0.7 },
    },
    PvP = {
        masterFont = { size = 16 },
        scrollAreas = {
            Incoming = { xOffset = -190, yOffset = -10, width = 120,
                height = 260 },
            Outgoing = { xOffset = 190, yOffset = -10, width = 120,
                height = 260 },
            Notifications = { xOffset = 0, yOffset = -160, width = 300,
                height = 160 },
        },
        notifications = { interrupts = true, caststops = true,
            auras = true, procs = true },
        spam = { mergeWindow = 0.3 },
    },
}

local function presetTable(name)
    if BUILTIN_PRESETS[name] ~= nil then
        local out = copyValue(ZCT.DEFAULTS.profile)
        deepMerge(out, BUILTIN_PRESETS[name])
        return out
    end
    if type(ZCTDB) == "table" and type(ZCTDB.presets) == "table" then
        local snap = ZCTDB.presets[name]
        if type(snap) == "table" then return copyValue(snap) end
    end
    return nil
end

local function presetNames()
    local names, seen = {}, {}
    for name in pairs(BUILTIN_PRESETS) do
        names[#names + 1] = name
        seen[name] = true
    end
    if type(ZCTDB) == "table" and type(ZCTDB.presets) == "table" then
        for name in pairs(ZCTDB.presets) do
            if not seen[name] then names[#names + 1] = name end
        end
    end
    table.sort(names)
    return names
end

function ZCT:PresetNames() return presetNames() end
function ZCT:PresetIsBuiltin(name) return BUILTIN_PRESETS[name] ~= nil end

function ZCT:SavePreset(name)
    if type(name) ~= "string" or name:match("^%s*$") then return false end
    if BUILTIN_PRESETS[name] ~= nil then return false end -- no clobber
    if type(ZCTDB) ~= "table" then ZCTDB = {} end
    ZCTDB.presets = type(ZCTDB.presets) == "table" and ZCTDB.presets or {}
    ZCTDB.presets[name] = copyValue(ZCT:GetDB())
    return true
end

function ZCT:DeletePreset(name)
    if BUILTIN_PRESETS[name] ~= nil then return false end
    if type(ZCTDB) ~= "table" or type(ZCTDB.presets) ~= "table" then
        return false
    end
    if ZCTDB.presets[name] == nil then return false end
    ZCTDB.presets[name] = nil
    return true
end

function ZCT:ApplyPreset(name)
    local p = presetTable(name)
    if not p then return false end
    local db = charDB()
    for k in pairs(db) do db[k] = nil end
    deepMerge(db, p)
    migrateCrits(db)
    migrateLayout(db)
    if ZCT.Display and ZCT.Display.SyncAreas then ZCT.Display:SyncAreas() end
    if ZCT.Config and ZCT.Config.RefreshAll then ZCT.Config:RefreshAll() end
    return true
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------
local function printUsage()
    print("|cff66aaffZCT|r - Zore's Combat Text " .. ZCT.VERSION)
    print("  /zct            - toggle config")
    print("  /zct status     - status")
    print("  /zct debug      - debug window")
    print("  /zct reload     - reload UI")
end

local function cmdStatus()
    local db = ZCT:GetDB()
    local f = ZCT.CombatLogFilter
    local sources, total = 0, 0
    if ZCT.Probe and ZCT.Probe.Summary then
        sources, total = ZCT.Probe:Summary()
    end
    local lines = ZCT.LogLines and ZCT.LogLines:Count() or 0
    print(("|cff66aaffZCT|r v%s enabled=%s filterTrusted=%s probe=%s/%d sources %d events, %d lines buffered")
        :format(ZCT.VERSION, tostring(db.enabled),
            tostring(f and f:IsPairingTrusted()),
            tostring(ZCT.Probe and ZCT.Probe._enabled), sources, total, lines))
    local now = GetTime()
    local function ago(t) return t and ("%.0fs ago"):format(now - t) or "never" end
    if f then
        local ok, why = f:IsReady()
        print(("|cff66aaffZCT|r filter: active=%s%s logWindowHooked=%s feedRestores=%d")
            :format(tostring(ok), why and (" (" .. why .. ")") or "",
                tostring(f._hookedLog == true), f.feedRestores or 0))
    end
    local L = ZCT.LogLines
    if L then
        print(("|cff66aaffZCT|r log lines: received=%d classified=%d last=%s")
            :format(L.total or 0, L.classified or 0, ago(L.lastAt)))
    end
    local O = ZCT.Outgoing
    if ZCT.Context then
        print(("|cff66aaffZCT|r context: %s (strict=%s)")
            :format(ZCT.Context:Kind(), tostring(ZCT.Context:Strict())))
    end
    if O and O.stats then
        local s = O.stats
        print(("|cff66aaffZCT|r outgoing: enabled=%s unitCombat=%d dupSkipped=%d capped=%d "
            .. "candidates=%d paired=%d dropped=%d gated=%d pending=%d lastUnitCombat=%s")
            :format(tostring(O._enabled), s.uc, s.dup, s.cap, s.cand, s.paired,
                s.dropped, s.gated or 0, O._pending or 0, ago(s.lastUcAt)))
    end
end

ZCT.PrintStatus = cmdStatus

SLASH_ZCT1 = "/zct"
SlashCmdList.ZCT = function(msg)
    msg = (msg or ""):trim():lower()
    if msg == "" then
        if ZCT.Config then ZCT.Config:Toggle() end
    elseif msg == "status" then
        cmdStatus()
    elseif msg == "debug" then
        if ZCT.Config and ZCT.Config.OpenPage then
            ZCT.Config:OpenPage("debug")
        end
    elseif msg == "probe on" then
        if ZCT.Probe then ZCT.Probe:Enable() end
        print("|cff66aaffZCT|r probe enabled")
    elseif msg == "probe off" then
        if ZCT.Probe then ZCT.Probe:Disable() end
        print("|cff66aaffZCT|r probe disabled")
    elseif msg == "probe clear" then
        if ZCT.Probe then ZCT.Probe._records = {} end
        print("|cff66aaffZCT|r probe records cleared")
    elseif msg:sub(1, 10) == "probe dump" then
        local filter = msg:sub(12):trim()
        if filter == "" then filter = nil end
        if ZCT.Probe then ZCT.Probe:Dump(filter) end
    elseif msg:sub(1, 6) == "debug " then
        -- /zct debug <channel> <level>
        local ch, lvl = msg:match("^debug%s+(%w+)%s+(%d+)$")
        if ch and ZCT.Dbg and ZCT.Dbg.SetLevel then
            if ZCT.Dbg:SetLevel(ch, tonumber(lvl)) then
                print(("|cff66aaffZCT|r debug.%s = %s"):format(ch, lvl))
            else
                print(("|cff66aaffZCT|r unknown channel '%s'"):format(ch))
            end
        else
            print("|cff66aaffZCT|r usage: /zct debug <channel> <0-5>")
        end
    elseif msg == "config" or msg == "options" then
        if ZCT.Config then ZCT.Config:Toggle() end
    elseif msg == "fct" or msg == "fct toggle" then
        local db = ZCT:GetDB()
        db.suppressBlizzardFCT = not (db.suppressBlizzardFCT ~= false)
        if ZCT.FCT then ZCT.FCT:Apply() end
        print(("|cff66aaffZCT|r Blizzard FCT suppression = %s")
            :format(tostring(db.suppressBlizzardFCT)))
    elseif msg == "fct status" then
        local on = ZCT.FCT and ZCT.FCT:IsSuppressed()
        print(("|cff66aaffZCT|r Blizzard FCT suppression = %s (master feed cvars stay on)")
            :format(tostring(on)))
    elseif msg == "auras reset" then
        local db = ZCT:GetDB()
        db.auraTrack = nil -- legacy unscoped key, if any
        if type(db.auraByClass) == "table" then
            for _, b in pairs(db.auraByClass) do
                if type(b) == "table" then b.auraTrack = {} end
            end
        end
        print("|cff66aaffZCT|r aura trackability verdicts cleared")
    elseif msg == "presets" then
        local names = ZCT:PresetNames()
        print("|cff66aaffZCT|r presets: " .. table.concat(names, ", "))
    elseif msg:sub(1, 7) == "preset " then
        local name = msg:sub(8):trim()
        if name ~= "" and ZCT:ApplyPreset(name) then
            print(("|cff66aaffZCT|r preset '%s' applied to %s")
                :format(name, charKey()))
        else
            print(("|cff66aaffZCT|r unknown preset '%s'"):format(name))
        end
    elseif msg:sub(1, 12) == "savepreset " then
        local name = msg:sub(13):trim()
        if ZCT:SavePreset(name) then
            print(("|cff66aaffZCT|r settings saved as preset '%s'")
                :format(name))
        else
            print("|cff66aaffZCT|r could not save preset "
                .. "(empty name or builtin name)")
        end
    elseif msg == "reload" then
        ReloadUI()
    else
        printUsage()
    end
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
local function OnLogin()
    -- Bind persistence now that SavedVariables are live: ZCT settings
    -- live at ZSBTDB.ZCT (sibling of AceDB's profile/char/global keys,
    -- which AceDB leaves untouched). No separate SavedVariables entry.
    if type(ZSBTDB) == "table" then
        if ZSBTDB.ZCT == nil then ZSBTDB.ZCT = {} end
        ZCTDB = ZSBTDB.ZCT
    end

    local db = ZCT:GetDB()
    migrateLayout(db)

    -- Apply debug levels from saved DB.
    if ZCT.Dbg and db.debug then
        for ch, lvl in pairs(db.debug) do
            ZCT.Dbg:SetLevel(ch, lvl)
        end
    end

    -- Probe first: empirical arg recording before any feature routing.
    if ZCT.Probe and db.probe and db.probe.enabled ~= false then
        ZCT.Probe:Enable()
        ZCT.Probe:WatchDefaults()
    end

    -- Filter lifecycle (logout write / login verify) + collector events.
    if ZCT.Collector then ZCT.Collector:Enable() end

    -- Content context (automated strictness input for Outgoing pairing).
    if ZCT.Context then ZCT.Context:Enable() end

    -- Event pipeline: Normalize -> Decide -> Display.
    if ZCT.Normalize and ZCT.Decide then
        ZCT.Normalize:AddSink(function(evt) ZCT.Decide:Handle(evt) end)
    end

    -- ZSBT feature bridge: CombatEvents -> existing parser/display pipeline.
    if ZCT.Normalize and ZCT.Bridge then
        ZCT.Normalize:AddSink(function(evt) ZCT.Bridge:Handle(evt) end)
    end
    if ZCT.Incoming then ZCT.Incoming:Enable() end
    if ZCT.Outgoing then ZCT.Outgoing:Enable() end
    if ZCT.Notify then ZCT.Notify:Enable() end
    if ZCT.Interrupts then ZCT.Interrupts:Enable() end
    if ZCT.Loot then ZCT.Loot:Enable() end
    if ZCT.Auras then ZCT.Auras:Enable() end
    if ZCT.Display then ZCT.Display:Enable() end
    if ZCT.Minimap then ZCT.Minimap:Init() end
    if ZCT.ResourceCounter then
        ZCT.ResourceCounter:Enable()
        ZCT.ResourceCounter:Refresh()
    end

    -- One-time default flip: suppressBlizzardFCT shipped false in v0 DBs;
    -- the feature is now implemented so the intended default is true.
    if db.suppressBlizzardFCT == false and not db._fctDefaultV1 then
        db.suppressBlizzardFCT = true
        db._fctDefaultV1 = true
    end

    -- Blizzard FCT suppression (keeps the COMBAT_TEXT_UPDATE feed alive).
    if ZCT.FCT then ZCT.FCT:Apply() end

    -- Filter verify needs saved vars settled; PEW already fired by the
    -- time ADDON_LOADED/PLAYER_LOGIN run for most cases, so verify now too.
    if ZCT.CombatLogFilter then ZCT.CombatLogFilter:Verify() end

    -- Make filtered combat-log events fire (display unaffected).
    if C_CombatLog and C_CombatLog.SetFilteredEventsEnabled then
        pcall(C_CombatLog.SetFilteredEventsEnabled, true)
    end

    if ZCT.Dbg and ZCT.Dbg:Enabled("config") then
        ZCT.Dbg:Info("config", "ZCT loaded v%s", ZCT.VERSION)
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        OnLogin()
    end
end)

print(("|cff66aaffZSBT|r combat core (ZCT) loaded v%s — /zct status"):format(ZCT.VERSION))
