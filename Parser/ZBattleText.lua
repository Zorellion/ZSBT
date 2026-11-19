------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - ZBattleText combat-log signal
--
-- Writes a "ZBattleText" filter into Blizzard_CombatLog_Filters at
-- PLAYER_LOGOUT (mid-session application can taint the secure
-- combat-log processor) and verifies it at login. The filter is
-- source-restricted to MINE + MY_PET, so every COMBAT_LOG_MESSAGE line
-- that arrives is provably the player's (or pet's) combat event.
--
-- Lines carry only RGB + timing (text is a sealed KString, never
-- read). The palette written into the filter's eventColoring gives
-- each damage/heal/miss event kind a distinct colour; we classify
-- lines by matching that palette back.
--
-- UNIT_COMBAT remains the source of truth for amounts/targets/spells.
-- This module only answers one question for ambiguous outgoing emits:
-- "did a line proving this hit was mine arrive nearby?" No line -> the
-- hit belongs to someone else sharing the target -> veto the emit.
-- When the filter is absent/untrusted the veto never engages and
-- behaviour is identical to before.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.ZBattleText = ZSBT.ZBattleText or {}
local ZB = ZSBT.ZBattleText

ZB._trusted = false
ZB._verified = false
ZB._reason = nil
ZB._vetoDisabled = false
ZB._vetoWarned = false
ZB._lastLineAt = 0
ZB._allows = 0
ZB._drops = 0

local FILTER_NAME = "ZBattleText"

------------------------------------------------------------------------
-- Palette: one distinct RGB per combat-log event kind. Written into the
-- filter's eventColoring and matched back with a tolerance.
------------------------------------------------------------------------
local KIND_COLORS = {
    direct     = { 0.95, 0.55, 0.15 },  -- orange
    tick       = { 0.65, 0.45, 1.00 },  -- violet
    melee      = { 0.90, 0.90, 0.90 },  -- light grey
    ranged     = { 0.80, 0.60, 0.40 },  -- tan
    directMiss = { 0.60, 0.65, 0.80 },  -- blue-grey
    tickMiss   = { 0.65, 0.55, 0.80 },  -- muted violet
    meleeMiss  = { 0.60, 0.60, 0.60 },  -- grey
    rangedMiss = { 0.65, 0.60, 0.50 },  -- brown-grey
    heal       = { 0.40, 1.00, 0.50 },  -- green
    hot        = { 0.50, 0.85, 0.60 },  -- light green
    shield     = { 1.00, 0.60, 0.25 }, -- amber
    shieldMiss = { 0.72, 0.58, 0.45 }, -- dull amber
}

local EVENT_KINDS = {
    SPELL_DAMAGE           = "direct",
    SPELL_LEECH            = "direct",
    SPELL_DRAIN            = "direct",
    SPELL_BUILDING_DAMAGE  = "direct",
    SPELL_PERIODIC_DAMAGE  = "tick",
    SPELL_PERIODIC_LEECH   = "tick",
    SPELL_PERIODIC_DRAIN   = "tick",
    SWING_DAMAGE           = "melee",
    RANGE_DAMAGE           = "ranged",
    DAMAGE_SHIELD          = "shield",
    DAMAGE_SPLIT           = "direct",
    ENVIRONMENTAL_DAMAGE   = "direct",
    SPELL_HEAL             = "heal",
    SPELL_BUILDING_HEAL    = "heal",
    SPELL_PERIODIC_HEAL    = "hot",
    SPELL_MISSED           = "directMiss",
    SPELL_PERIODIC_MISSED  = "tickMiss",
    SWING_MISSED           = "meleeMiss",
    RANGE_MISSED           = "rangedMiss",
    DAMAGE_SHIELD_MISSED   = "shieldMiss",
}

local MISS_TYPES = {
    "ABSORB", "BLOCK", "DEFLECT", "DODGE", "EVADE", "IMMUNE",
    "MISS", "PARRY", "REFLECT", "RESIST",
}
for _, prefix in ipairs({ "SPELL", "SPELL_PERIODIC", "SWING", "RANGE", "DAMAGE_SHIELD" }) do
    local kind = EVENT_KINDS[prefix .. "_MISSED"]
    if kind then
        for _, miss in ipairs(MISS_TYPES) do
            EVENT_KINDS[prefix .. "_MISSED_" .. miss] = kind
        end
    end
end

-- Kinds that prove an outgoing damage hit happened: a classified line of
-- these near a UNIT_COMBAT WOUND means the hit was ours.
local DAMAGE_KINDS = {
    direct = true, tick = true, melee = true, ranged = true, shield = true,
}

local COLOR_TOLERANCE = 0.02
local LINE_KEEP_SEC = 2.5
local LINE_MAX = 96
local VETO_WINDOW = 0.30
local FEED_DEAD_SEC = 8.0

ZB._lines = ZB._lines or {}

------------------------------------------------------------------------
-- Combat-log line buffer (COMBAT_LOG_MESSAGE -> RGB classify)
------------------------------------------------------------------------
local function isSafeChannel(v)
    return type(v) == "number" and (not ZSBT.IsSafeNumber or ZSBT.IsSafeNumber(v))
end

local function classifyColor(r, g, b)
    for kind, rgb in pairs(KIND_COLORS) do
        if math.abs(r - rgb[1]) <= COLOR_TOLERANCE
            and math.abs(g - rgb[2]) <= COLOR_TOLERANCE
            and math.abs(b - rgb[3]) <= COLOR_TOLERANCE then
            return kind
        end
    end
    return nil
end

local function recordLine(r, g, b)
    if not (isSafeChannel(r) and isSafeChannel(g) and isSafeChannel(b)) then
        return
    end
    local kind = classifyColor(r, g, b)
    if not kind then
        -- Unclassified colour: possibly minion/pet damage under a palette
        -- colour we do not emit. Log throttled so its RGB can be identified.
        local t0 = GetTime and GetTime() or 0
        if t0 - (ZB._lastOddLineAt or 0) >= 0.10 then
            ZB._lastOddLineAt = t0
            ZB:FileLog(("ODD rgb=%.2f,%.2f,%.2f"):format(r, g, b))
        end
        return
    end

    local t = GetTime and GetTime() or 0
    ZB._lastLineAt = t
    local lines = ZB._lines
    while #lines > 0 and t - lines[1].at > LINE_KEEP_SEC do
        table.remove(lines, 1)
    end
    if #lines >= LINE_MAX then
        table.remove(lines, 1)
    end
    lines[#lines + 1] = { at = t, kind = kind, consumed = false }
    ZB:FileLog(("LIN kind=%s rgb=%.2f,%.2f,%.2f"):format(tostring(kind), r, g, b))
end

-- Consume the nearest unconsumed damage-kind line within `window` of tHit.
local function takeDamageLine(tHit, window)
    local best, bestDt
    for i = 1, #ZB._lines do
        local l = ZB._lines[i]
        if DAMAGE_KINDS[l.kind] and not l.consumed then
            local dt = math.abs(l.at - tHit)
            if dt <= window and (bestDt == nil or dt < bestDt) then
                best, bestDt = i, dt
            end
        end
    end
    if best then
        ZB._lines[best].consumed = true
        return ZB._lines[best].kind
    end
    return nil
end

------------------------------------------------------------------------
-- Filter verification
------------------------------------------------------------------------
local function copyValue(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = copyValue(val) end
    return out
end

local function colorMatches(got, want)
    return type(got) == "table" and type(want) == "table"
        and math.abs((got.r or -1) - want[1]) <= 0.03
        and math.abs((got.g or -1) - want[2]) <= 0.03
        and math.abs((got.b or -1) - want[3]) <= 0.03
end

local function paletteMatches(ec)
    if type(ec) ~= "table" then return false end
    for event, kind in pairs(EVENT_KINDS) do
        if not colorMatches(ec[event], KIND_COLORS[kind]) then return false end
    end
    return true
end

local function sourcesRestricted(f)
    local mineFlag = COMBATLOG_FILTER_MINE
    local petFlag = COMBATLOG_FILTER_MY_PET
    if type(mineFlag) ~= "number" or type(petFlag) ~= "number" then return false end
    if type(f.filters) ~= "table" or #f.filters == 0 then return false end
    local sawSource = false
    for _, part in ipairs(f.filters) do
        if type(part) ~= "table" then return false end
        local sf, df = part.sourceFlags, part.destFlags
        local srcOk = type(sf) == "table"
            and sf[mineFlag] == true and sf[petFlag] == true
        local dstOk = type(df) == "table"
            and df[mineFlag] == true and df[petFlag] == true
        if srcOk then
            for flag, on in pairs(sf) do
                if on and flag ~= mineFlag and flag ~= petFlag then srcOk = false break end
            end
        end
        if dstOk then
            for flag, on in pairs(df) do
                if on and flag ~= mineFlag and flag ~= petFlag then dstOk = false break end
            end
        end
        if srcOk and not dstOk then
            if df ~= nil then
                for _, on in pairs(df) do
                    if on then srcOk = false break end
                end
            end
        elseif dstOk and not srcOk then
            if sf ~= nil then
                for _, on in pairs(sf) do
                    if on then dstOk = false break end
                end
            end
        else
            return false
        end
        if srcOk then sawSource = true end
    end
    return sawSource
end

local function findOurIndex()
    local saved = _G.Blizzard_CombatLog_Filters
    if type(saved) ~= "table" or type(saved.filters) ~= "table" then return nil end
    for i, f in ipairs(saved.filters) do
        if type(f) == "table" and f.name == FILTER_NAME then return i end
    end
    return nil
end

function ZB:IsReady()
    local saved = _G.Blizzard_CombatLog_Filters
    if type(saved) ~= "table" or type(saved.filters) ~= "table" then
        return false, "no combat-log filter data"
    end
    local cur = saved.currentFilter
    local f = type(cur) == "number" and saved.filters[cur] or nil
    if type(f) ~= "table" then return false, "no current filter" end
    if f.name ~= FILTER_NAME then
        return false, ("current filter is '%s', not '%s'"):format(tostring(f.name), FILTER_NAME)
    end
    local applied = _G.Blizzard_CombatLog_CurrentSettings
    if type(applied) == "table" and type(applied.name) == "string"
        and applied.name ~= f.name then
        return false, ("applied filter is '%s', not '%s'"):format(applied.name, FILTER_NAME)
    end
    local settings = f.settings
    if type(settings) ~= "table" or settings.lineColoring ~= true then
        return false, "line coloring off"
    end
    local colors = f.colors
    if type(colors) ~= "table" or not paletteMatches(colors.eventColoring) then
        return false, "palette changed"
    end
    if not sourcesRestricted(f) then return false, "sources not restricted to you+pet" end
    return true, nil
end

function ZB:IsTrusted()
    return ZB._trusted == true
end

-- True while no classified line has arrived recently. Transient by
-- design: out-of-combat gaps produce no lines, so a stale feed must not
-- latch the veto off for the session — it re-engages as soon as lines
-- resume. _lastLineAt == 0 (nothing seen yet) is NOT stale: early
-- candidates simply defer and pair once the feed starts.
local function feedDead()
    local last = ZB._lastLineAt or 0
    if last <= 0 then return false end
    local tNow = GetTime and GetTime() or 0
    return tNow - last > FEED_DEAD_SEC
end

-- True only when the ownership veto can actually decide: filter
-- trusted AND watchdogs have not disabled it. Upstream gates may use this
-- to route otherwise-dropped candidates through emit() so the
-- deferred line pairing can prove them.
function ZB:VetoActive()
    if ZB._trusted ~= true or ZB._vetoDisabled then return false end
    return not feedDead()
end

local function say(msg)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end
end

local function showLostPopup(why)
    if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then return end
    StaticPopupDialogs["ZSBT_ZBT_FILTER_LOST"] = {
        text = ("|cffdd5555ZSBT|r outgoing combat text is off.\n\n"
            .. "The '%s' combat log filter is no longer selected (%s).\n\n"
            .. "Click the %s button at the top of the combat log to turn it back on.")
            :format(FILTER_NAME, tostring(why), FILTER_NAME),
        button1 = "Open Combat Log",
        button2 = "Later",
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        OnAccept = function()
            local cl = _G.COMBATLOG
            if type(cl) == "table" or type(cl) == "userdata" then
                if cl.Show then cl:Show() end
                if cl.SetAlpha then cl:SetAlpha(1) end
            end
        end,
        OnCancel = function() end,
    }
    StaticPopup_Show("ZSBT_ZBT_FILTER_LOST")
end

function ZB:Verify()
    ZB._verified = true
    local ok, why = ZB:IsReady()
    local was = ZB._trusted
    ZB._trusted = ok
    ZB._reason = why
    local nowT = GetTime and GetTime() or 0
    if ok then
        ZB._lastWarnAt = nil
        if was == false then
            say(("|cff66aaff[ZSBT]|r The '%s' combat log filter is active again — outgoing text restored.")
                :format(FILTER_NAME))
        end
    elseif was ~= false or (nowT - (ZB._lastWarnAt or 0)) >= 30 then
        local saved = _G.Blizzard_CombatLog_Filters
        local exists = false
        if type(saved) == "table" and type(saved.filters) == "table" then
            for _, f in ipairs(saved.filters) do
                if type(f) == "table" and f.name == FILTER_NAME then exists = true end
            end
        end
        ZB._lastWarnAt = nowT
        if exists then
            local whyText = tostring(why)
            say(("|cffdd5555[ZSBT]|r Outgoing text needs the '%s' combat log filter (%s). "
                .. "Click the %s button at the top of the combat log.")
                :format(FILTER_NAME, whyText, FILTER_NAME))
            showLostPopup(whyText)
        else
            say(("|cffdd5555[ZSBT]|r The '%s' combat log filter is installed when you log "
                .. "out. Log out and back in to enable outgoing text.")
                :format(FILTER_NAME))
        end
    end
    return ZB._trusted
end

function ZB:Tick()
    local nowT = GetTime and GetTime() or 0
    if nowT - (ZB._tickAt or 0) < 1 then return end
    ZB._tickAt = nowT
    if not findOurIndex() then return end
    local saved = _G.Blizzard_CombatLog_Filters
    if tonumber(saved.currentFilter) == findOurIndex() then
        ZB:Verify()
        return
    end
    ZB:Verify()
end

------------------------------------------------------------------------
-- Filter install (PLAYER_LOGOUT only — secure processor rule)
------------------------------------------------------------------------
function ZB:InstallAtLogout()
    local saved = _G.Blizzard_CombatLog_Filters
    if type(saved) ~= "table" or type(saved.filters) ~= "table" then return false end
    -- Clients without combat-log source flags (older classic) can never
    -- satisfy sourcesRestricted; do not install a filter that would only
    -- produce warnings.
    if type(COMBATLOG_FILTER_MINE) ~= "number" or type(COMBATLOG_FILTER_MY_PET) ~= "number" then
        return false
    end

    local current = saved.currentFilter
    local template = (type(current) == "number" and saved.filters[current]) or saved.filters[1]
    if type(template) ~= "table" then return false end

    local filter = copyValue(template)
    filter.name = FILTER_NAME
    filter.quickButtonName = FILTER_NAME
    filter.hasQuickButton = true
    filter.tooltip = FILTER_NAME

    filter.settings = filter.settings or {}
    filter.settings.lineColoring = true
    filter.settings.lineColorPriority = 3
    filter.settings.lineHighlighting = false

    filter.colors = filter.colors or {}
    filter.colors.eventColoring = filter.colors.eventColoring or {}
    for event, kind in pairs(EVENT_KINDS) do
        local c = KIND_COLORS[kind]
        filter.colors.eventColoring[event] = { r = c[1], g = c[2], b = c[3], a = 1 }
    end
    filter.colors.highlightedEvents = filter.colors.highlightedEvents or {}

    -- Single source part: sourceFlags = you+pet, eventList = union of the
    -- template's event lists (nil = all events). No dest part: incoming
    -- lines must never enter the veto buffer.
    local mineFlag = COMBATLOG_FILTER_MINE
    local petFlag = COMBATLOG_FILTER_MY_PET
    if type(mineFlag) == "number" and type(petFlag) == "number" then
        local srcEvents
        if type(filter.filters) == "table" then
            for _, p in ipairs(filter.filters) do
                if type(p) == "table" and type(p.eventList) == "table" then
                    srcEvents = srcEvents or {}
                    for ev, on in pairs(p.eventList) do
                        if on then srcEvents[ev] = true end
                    end
                end
            end
        end
        filter.filters = {
            {
                sourceFlags = { [mineFlag] = true, [petFlag] = true },
                eventList = srcEvents,
            },
        }
    end

    local index
    for i, f in ipairs(saved.filters) do
        if type(f) == "table" and f.name == FILTER_NAME then
            index = i
            break
        end
    end
    index = index or (#saved.filters + 1)
    saved.filters[index] = filter
    saved.currentFilter = index
    return true
end

function ZB:RebuildNow()
    local saved = _G.Blizzard_CombatLog_Filters
    if type(saved) ~= "table" or type(saved.filters) ~= "table" then
        return false, "no combat-log filter data"
    end
    local removed = 0
    for i = #saved.filters, 1, -1 do
        local f = saved.filters[i]
        if type(f) == "table" and f.name == FILTER_NAME then
            table.remove(saved.filters, i)
            removed = removed + 1
        end
    end
    local cur = tonumber(saved.currentFilter) or 1
    saved.currentFilter = math.max(1, math.min(cur, math.max(1, #saved.filters)))
    local ok = ZB:InstallAtLogout()
    return ok == true, removed
end

------------------------------------------------------------------------
-- Combat-log window feed guard (Blizzard disables filtered events when
-- the log window hides)
------------------------------------------------------------------------
local function keepFeedOn()
    if C_CombatLog and C_CombatLog.SetFilteredEventsEnabled then
        pcall(C_CombatLog.SetFilteredEventsEnabled, true)
    end
end

function ZB:HookCombatLogWindow()
    if ZB._hookedLog then return true end
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    local loaded = isLoaded and isLoaded("Blizzard_CombatLog")
    local cl = _G.COMBATLOG or _G.ChatFrame2
    if not loaded or type(cl) ~= "table" or not cl.HookScript then return false end
    cl:HookScript("OnHide", keepFeedOn)
    if type(_G.Blizzard_CombatLog_QuickButton_OnClick) == "function" then
        hooksecurefunc("Blizzard_CombatLog_QuickButton_OnClick", function()
            ZB:Verify()
        end)
    end
    ZB._hookedLog = true
    return true
end

------------------------------------------------------------------------
-- Veto API used by Event_Collector.emit for OUTGOING_DAMAGE_COMBAT.
--
-- COMBAT_LOG_MESSAGE and UNIT_COMBAT for the same hit can arrive in
-- either order, so a synchronous check would drop our own hits whenever
-- the line lands a frame late. OfferOutgoing therefore defers the emit
-- ~0.20s when the filter is trusted: by flush time the line is in the
-- buffer regardless of arrival order. Untrusted => returns true
-- immediately and emit() behaves exactly as before.
------------------------------------------------------------------------
local DEFER_SEC = 0.20
local DEFER_WINDOW = 0.45

ZB._pending = ZB._pending or {}
ZB._flushAt = ZB._flushAt or 0


local function vetoDisabledNow()
    if ZB._vetoDisabled then return true end
    -- Feed presumed dead: fall back to heuristics rather than eating
    -- every outgoing number. No latch — combat lulls are normal.
    if feedDead() then return true end
    return false
end

local function sustainedRejection()
    if ZB._drops >= 50 and ZB._allows == 0 and not ZB._vetoDisabled then
        ZB._vetoDisabled = true
        if not ZB._vetoWarned then
            ZB._vetoWarned = true
            say(("|cffdd5555[ZSBT]|r '%s' pairing rejected everything — veto disabled for this session.")
                :format(FILTER_NAME))
        end
        return true
    end
    return false
end

local function deliverOutgoing(payload)
    local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
    if ec and ec._sink then
        ec._sink("OUTGOING_DAMAGE_COMBAT", payload)
    end
end

local function flushPending()
    ZB._flushAt = 0
    local pend = ZB._pending
    ZB._pending = {}
    for i = 1, #pend do
        local p = pend[i]
        if ZB._vetoDisabled or not ZB._trusted then
            deliverOutgoing(p.payload)
        else
            local kind = takeDamageLine(p.t, DEFER_WINDOW)
            if kind then
                ZB._allows = ZB._allows + 1
                ZB:FileLog(("ALLOW kind=%s sid=%s"):format(tostring(kind), tostring(p.payload and p.payload.spellId)))
                deliverOutgoing(p.payload)
            else
                ZB._drops = ZB._drops + 1
                ZB:FileLog(("DROP sid=%s"):format(tostring(p.payload and p.payload.spellId)))
                sustainedRejection()
            end
        end
    end
end

-- Trace sink for /zsbt ucdrop sessions: appends to a SavedVariables
-- ring buffer (ZSBTDB -> WTF/.../SavedVariables/ZSBTDB.lua) so decisions can be
-- read post-session without chat copy/paste (chat blocks secret values).
function ZB:FileLog(msg)
    if ZSBT._ucDropTrace ~= true then return end
    local prof = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics
    if type(prof) ~= "table" then return end
    local log = prof.ucdropLog
    if type(log) ~= "table" then
        log = {}
        prof.ucdropLog = log
    end
    local t = GetTime and GetTime() or 0
    log[#log + 1] = ("%.3f %s"):format(t, tostring(msg))
    if #log > 4000 then
        table.remove(log, 1)
    end
end

-- Returns true when the caller should emit immediately; false when the
-- module took ownership (queued for deferred veto, or vetoed).
function ZB:OfferOutgoing(payload)
    if not ZB._trusted or ZB._vetoDisabled then return true end
    local tHit = payload and payload.timestamp
    if type(tHit) ~= "number" then return true end
    if vetoDisabledNow() then return true end

    -- Fast path: the line is already buffered (CLM arrived first).
    local fastKind = takeDamageLine(tHit, VETO_WINDOW)
    if fastKind then
        ZB._allows = ZB._allows + 1
        ZB:FileLog(("ALLOW_FAST kind=%s sid=%s"):format(tostring(fastKind), tostring(payload and payload.spellId)))
        return true
    end

    ZB._pending[#ZB._pending + 1] = { payload = payload, t = tHit }
    if #ZB._pending > 200 then
        table.remove(ZB._pending, 1)
    end
    local tNow = GetTime and GetTime() or 0
    if ZB._flushAt <= tNow and C_Timer and C_Timer.After then
        ZB._flushAt = tNow + DEFER_SEC
        C_Timer.After(DEFER_SEC, flushPending)
    end
    return false
end
function ZB:Status()
    return {
        trusted = ZB._trusted,
        reason = ZB._reason,
        verified = ZB._verified,
        vetoDisabled = ZB._vetoDisabled,
        allows = ZB._allows,
        drops = ZB._drops,
        bufferedLines = #ZB._lines,
        pending = #ZB._pending,
    }
end

------------------------------------------------------------------------
-- Frame wiring
------------------------------------------------------------------------
if not ZB._frame then
    ZB._frame = CreateFrame("Frame")
    ZB._frame:RegisterEvent("PLAYER_LOGOUT")
    ZB._frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    pcall(ZB._frame.RegisterEvent, ZB._frame, "COMBAT_LOG_APPLY_FILTER_SETTINGS")
    ZB._frame:RegisterEvent("ADDON_LOADED")
    ZB._frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    ZB._frame:RegisterEvent("COMBAT_LOG_MESSAGE")
    ZB._frame:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
        if event == "COMBAT_LOG_MESSAGE" then
            -- args: text(KString, never read), r, g, b, order
            recordLine(a2, a3, a4)
        elseif event == "PLAYER_REGEN_DISABLED" then
            ZB:HookCombatLogWindow()
            keepFeedOn()
        elseif event == "ADDON_LOADED" then
            if a1 == "Blizzard_CombatLog" or a1 == ADDON_NAME then
                ZB:HookCombatLogWindow()
            end
        elseif event == "PLAYER_LOGOUT" then
            ZB:InstallAtLogout()
        elseif event == "PLAYER_ENTERING_WORLD" then
            ZB:HookCombatLogWindow()
            keepFeedOn()
            ZB:Verify()
        elseif event == "COMBAT_LOG_APPLY_FILTER_SETTINGS" then
            if C_Timer and C_Timer.After then
                C_Timer.After(0.5, function() ZB:Verify() end)
            end
        end
    end)
end

if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(1, function() ZB:Tick() end)
end

-- Login status line so the signal state is visible without /zsbt filter.
if C_Timer and C_Timer.After then
    C_Timer.After(3, function()
        local ok, why = ZB:IsReady()
        if ok then
            say(("|cff66aaff[ZSBT]|r '%s' combat log filter active — shared-target attribution protected.")
                :format(FILTER_NAME))
        else
            say(("|cff888888[ZSBT]|r '%s' filter not active yet (%s). Written on logout; outgoing attribution uses heuristics until then.")
                :format(FILTER_NAME, tostring(why)))
        end
    end)
end
return ZB
