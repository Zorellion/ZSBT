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
    interrupt  = { 1.00, 0.45, 0.10 }, -- orange-red
    purge      = { 0.30, 0.85, 1.00 }, -- cyan
    cleanse    = { 0.40, 0.95, 0.80 }, -- teal
    steal      = { 0.60, 0.80, 1.00 }, -- light blue
    dispelFailed = { 0.55, 0.72, 0.82 }, -- steel
    broke      = { 1.00, 0.35, 0.35 }, -- red
    kill       = { 1.00, 1.00, 1.00 }, -- white
    extra      = { 0.15, 0.85, 0.85 }, -- aqua
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
    -- Utility events: kept in the filter so interrupts,
    -- dispels, steals, breaks and kills stay visible but color-coded.
    SPELL_INTERRUPT        = "interrupt",
    SPELL_DISPEL            = "purge",
    SPELL_DISPEL_BUFF       = "purge",
    SPELL_DISPEL_DEBUFF     = "cleanse",
    SPELL_STOLEN            = "steal",
    SPELL_STOLEN_BUFF       = "steal",
    SPELL_STOLEN_DEBUFF     = "steal",
    SPELL_DISPEL_FAILED     = "dispelFailed",
    SPELL_AURA_BROKEN       = "broke",
    SPELL_AURA_BROKEN_SPELL = "broke",
    SPELL_AURA_BROKEN_BUFF  = "broke",
    SPELL_AURA_BROKEN_DEBUFF = "broke",
    SPELL_AURA_BROKEN_SPELL_BUFF = "broke",
    SPELL_AURA_BROKEN_SPELL_DEBUFF = "broke",
    PARTY_KILL              = "kill",
    SPELL_EXTRA_ATTACKS     = "extra",
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

-- Explicit whitelist for the filter's eventList: only the
-- combat events we color. Everything else — aura applications, fades,
-- refreshes, energy/rage gains, summons, etc. — is excluded so the
-- combat log shows only actionable combat text.
local FILTER_EVENTS = {}
for event in pairs(EVENT_KINDS) do
    FILTER_EVENTS[event] = true
end

local COLOR_TOLERANCE = 0.02
local LINE_KEEP_SEC = 2.5
local LINE_MAX = 96
local VETO_WINDOW = 0.30

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
    ZB:FileLog(("LIN kind=%s rgb=%.2f,%.2f,%.2f"):format(tostring(kind), r, g, b))
    -- Only damage kinds feed the veto buffer; heal/miss/utility lines are
    -- classified for completeness but would just crowd the ring.
    if not DAMAGE_KINDS[kind] then return end
    local lines = ZB._lines
    while #lines > 0 and t - lines[1].at > LINE_KEEP_SEC do
        table.remove(lines, 1)
    end
    if #lines >= LINE_MAX then
        table.remove(lines, 1)
    end
    lines[#lines + 1] = { at = t, kind = kind, consumed = false }
end

-- Consume the nearest unconsumed damage-kind line within `window` of tHit.
-- `kinds` optionally restricts which line kinds may match (kind-aware
-- pairing keeps melee candidates from stealing spell lines and vice versa).
local function takeDamageLine(tHit, window, kinds)
    local best, bestDt
    for i = 1, #ZB._lines do
        local l = ZB._lines[i]
        local kindOk = DAMAGE_KINDS[l.kind] and (kinds == nil or kinds[l.kind] == true)
        if kindOk and not l.consumed then
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

-- Non-consuming look at buffered lines: class modules use this for
-- swing-evidence decisions (e.g. hunter distinguishes its ranged
-- auto-shot from pet melee by which line kind is present) without
-- burning the line an actual claimant still needs.
function ZB:PeekDamageLine(tHit, window, kinds)
    if type(tHit) ~= "number" then return nil end
    for i = 1, #ZB._lines do
        local l = ZB._lines[i]
        if DAMAGE_KINDS[l.kind] and not l.consumed
            and (kinds == nil or kinds[l.kind] == true)
            and math.abs(l.at - tHit) <= window then
            return l.kind
        end
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

-- Utility kinds are cosmetic (color-coded log lines only); the veto never
-- pairs them, so they are excluded from palette verification. This keeps
-- filters written before these kinds existed verifying as trusted.
local COSMETIC_KINDS = {
    interrupt = true, purge = true, cleanse = true, steal = true,
    dispelFailed = true, broke = true, kill = true, extra = true,
}

local function paletteMatches(ec)
    if type(ec) ~= "table" then return false end
    for event, kind in pairs(EVENT_KINDS) do
        if not COSMETIC_KINDS[kind]
            and not colorMatches(ec[event], KIND_COLORS[kind]) then
            return false
        end
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

-- True only when the ownership veto can actually decide: filter
-- trusted AND watchdogs have not disabled it. Upstream gates use this
-- to route otherwise-dropped candidates through emit() so deferred
-- line pairing can prove them. A quiet feed is NOT a broken feed —
-- out-of-combat lulls produce no lines by definition, and the wound
-- that ends the lull produces the very line that proves it. Gating on
-- feedDead here killed openers at intake: the feed could never warm
-- because the hit that would wake it died first.
function ZB:VetoActive()
    return ZB._trusted == true and not ZB._vetoDisabled
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

local function showMissingPopup()
    if ZB._missingPopupShown == true then return end
    if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then return end
    ZB._missingPopupShown = true
    StaticPopupDialogs["ZSBT_ZBT_FILTER_MISSING"] = {
        text = ("|cffdd5555ZSBT|r needs one UI reload to finish setup.\n\n"
            .. "The '%s' combat log filter has not been created yet. It is written when the "
            .. "UI reloads or you log out, and enables shared-target damage attribution.\n\n"
            .. "Reload now?")
            :format(FILTER_NAME),
        button1 = "Reload UI",
        button2 = "Later",
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        OnAccept = function()
            if ReloadUI then ReloadUI() end
        end,
        OnCancel = function() end,
    }
    StaticPopup_Show("ZSBT_ZBT_FILTER_MISSING")
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
            showMissingPopup()
        end
    end
    return ZB._trusted
end

function ZB:Tick()
    local nowT = GetTime and GetTime() or 0
    -- ucdrop heartbeat: proves the tracer was alive during quiet windows,
    -- so "no events" can be told apart from "log dead".
    if ZSBT._ucDropTrace == true then
        ZB:FileLog("HB")
    end
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

    -- Single source part: sourceFlags = you+pet, eventList = explicit
    -- whitelist of colored combat events only. No dest part: incoming
    -- lines must never enter the veto buffer.
    local mineFlag = COMBATLOG_FILTER_MINE
    local petFlag = COMBATLOG_FILTER_MY_PET
    if type(mineFlag) == "number" and type(petFlag) == "number" then
        local evList = {}
        for ev in pairs(FILTER_EVENTS) do evList[ev] = true end
        filter.filters = {
            {
                sourceFlags = { [mineFlag] = true, [petFlag] = true },
                eventList = evList,
            },
        }
    end
    filter.settings.hideDebuffs = false
    filter.quickButtonDisplay = { solo = true, party = true, raid = true }

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
local RETRY_WINDOW = 0.90

ZB._pending = ZB._pending or {}
ZB._flushAt = ZB._flushAt or 0


local function vetoDisabledNow()
    if ZB._vetoDisabled then return true end
    -- Cold start: no line has ever been classified this session. The
    -- veto has nothing to pair against — deferred candidates would all
    -- die at flush, which is why openers go silent until the feed warms.
    -- Emit immediately until the first line arrives, same as untrusted.
    -- A quiet-but-seen feed is different: queue and let the wound's own
    -- line prove it when it lands, instead of emitting unproven (which
    -- would pass party/follower hits on the shared target too).
    if (ZB._lastLineAt or 0) <= 0 then return true end
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

-- Line kinds a candidate should claim first. Physical hits (school 1,
-- including bows) pair with melee/ranged lines; everything else prefers
-- spell damage kinds. Returns nil for "any damage kind" (fallback pass
-- still runs, so this only reorders, never restricts).
local MELEE_KINDS = { melee = true, ranged = true }

-- Kinds an auto-attack candidate may claim. Class modules may narrow
-- this (hunter: ranged only — the player's shots produce RANGE_DAMAGE
-- lines while pet melee produces SWING_DAMAGE, so freeing melee lines
-- lets pet swings claim them instead).
local function autoLineKinds()
	local cdb = ZSBT.ClassDB
	if cdb and cdb.AutoLineKinds then
		local k = cdb.AutoLineKinds()
		if k then return k end
	end
	return MELEE_KINDS
end

-- Kinds a non-auto candidate may claim. melee lines come only from
-- SWING_DAMAGE — real auto-swings — so a wound that is not an auto can
-- never legitimately own one (a school-4 wound claimed a leftover
-- melee line and displayed it as "Frailty"). ranged is different:
-- RANGE_DAMAGE covers Auto Shot, thrown AND wand Shoot, which arrive
-- as sid-bearing spell wounds (5019 pending cast) — not isAuto — so
-- excluding ranged left every wand hit unpairable (noline rescue).
-- But ranged is also a theft vector: an ordinary spell wound claiming
-- the nearest line would steal a wand bolt's ranged line (observed:
-- sid=980 claiming kind=ranged while the bolt claimed tick). Ordered
-- preference: each payload tries its own kind first, ranged last.
local NONAUTO_KINDS = { direct = true, tick = true, shield = true, ranged = true }
local NONAUTO_NO_RANGED = { direct = true, tick = true, shield = true }
local NONAUTO_NO_TICK = { direct = true, shield = true }
local TICK_KIND = { tick = true }
local RANGED_KIND = { ranged = true }

-- Ordered kind sets for a non-auto candidate: pass 1 is the wound's
-- expected line kind, later passes widen toward the leftovers. A
-- periodic tick wants tick lines and can NEVER own a ranged line;
-- a module-declared ranged spell (wand Shoot) wants ranged first and
-- can NEVER own a periodic tick line. Spell wounds without an identity
-- hint take spell kinds and reach for ranged only as the final resort.
local function kindPreference(payload)
    local sid = payload and payload.spellId or nil
    local periodic = payload and payload.isPeriodic == true
    local cdb = ZSBT.ClassDB
    if not periodic and type(sid) == "number"
        and cdb and cdb.DotEntry and cdb.DotEntry(sid) ~= nil then
        -- A wound stamped with a dot sid via any path (pending cast,
        -- matchbox, off-target) is periodic evidence-wise even when
        -- the payload flag was not set.
        periodic = true
    end
    if periodic then
        return TICK_KIND, NONAUTO_NO_RANGED, nil
    end
    if type(sid) == "number" and cdb and cdb.PreferRangedLine
        and cdb.PreferRangedLine(sid) == true then
        return RANGED_KIND, NONAUTO_NO_TICK, nil
    end
    return NONAUTO_NO_RANGED, RANGED_KIND, nil
end

-- Kinds a queued/offered candidate may claim, from its own evidence.
-- Autos and swing-proven wounds own melee/ranged lines; pet-route
-- wounds own whatever line the pet produced (melee pet -> melee line,
-- caster pet -> direct) so they get the full set; everything else is
-- a spell wound and melee stays off-limits (auto-line theft).
-- Returns up to three kind sets, tried in order; a nil first set means
-- "any kind" on the first pass.
local function candidateKinds(payload)
    if payload and (payload.isAuto == true or payload._swingProven == true) then
        return autoLineKinds(), nil, nil
    end
    if payload and payload._petRoute == true then
        return nil, nil, nil
    end
    return kindPreference(payload)
end

local function takeCandidateLine(tHit, window, payload)
    local a, b, c = candidateKinds(payload)
    local kind = takeDamageLine(tHit, window, a)
    if not kind and b then kind = takeDamageLine(tHit, window, b) end
    if not kind and c then kind = takeDamageLine(tHit, window, c) end
    return kind
end

-- Provenance tier for line claiming. Tier 1 = sid-bearing (the hit
-- consumed a real cast/pet record or a class-resolved identity — all
-- school-gated, overwhelmingly ours). Tier 2 = unattributed generic;
-- foreign bleed lives here. sid nil-checks are secret-safe (existence,
-- not value comparison).
local function candidateTier(payload)
    if payload and (payload.spellId ~= nil or payload.petSpellId ~= nil
        or payload._swingProven == true) then
        return 1
    end
    return 2
end
local function deliverOutgoing(payload)
    local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
    if ec and ec._sink then
        -- Deferred delivery only happens after a palette line confirmed
        -- ownership: teach the spell's school (FCT Trust equivalent), but
        -- only when the sid came from a consumed cast record — recency
        -- stamps are guesses and must not learn from a stolen line.
        local learnSid = payload and (payload.spellId or payload.petSpellId)
        local learnTrust = payload and (
            (payload.spellId ~= nil and payload._sidLearn == true)
            or (payload.spellId == nil and payload.petSpellId ~= nil and payload._petSidLearn == true))
        if type(learnSid) == "number" and ec.LearnConfirmedSchool then
            ec:LearnConfirmedSchool(learnSid, payload.schoolMask, learnTrust == true)
        end
        local ev = "OUTGOING_DAMAGE_COMBAT"
        if payload and payload._petRoute == true then
            -- Same guards as emit()'s swap: a real player spellId or a
            -- pet-foreign school strips the route — the deferred path
            -- can deliver a payload whose pet guess predates a later
            -- pending-cast claim (Conflagrate named on pet scroll).
            local petSchoolForeign = ZSBT.ClassDB and ZSBT.ClassDB.PetSchoolAllowed
                and ZSBT.ClassDB.PetSchoolAllowed(payload.schoolMask) == false
            if payload.spellId ~= nil or petSchoolForeign then
                payload._petRoute = nil
                ZB:FileLog(("PET_ROUTE_STRIP sid=%s school=%s"):format(
                    tostring(payload.spellId), tostring(payload.schoolMask)))
            else
                ev = "PET_DAMAGE_COMBAT"
            end
        end
        ZB:AuditDamageEvent(ev, payload)
        ec._sink(ev, payload)
    end
end

-- Secret-safe tostring for audit fields. Midnight KStrings (names, ids)
-- hard-error on tostring() — a bare tostring here previously killed
-- emit()/deliverOutgoing outright when targetName was secret.
local function audSafe(v)
    if v == nil then return "nil" end
    if ZSBT.IsSecret and ZSBT.IsSecret(v) then return "<sec>" end
    local ok, s = pcall(tostring, v)
    if ok and type(s) == "string" then return s end
    return "<err>"
end

local function auditQueued(payload)
    if ZSBT._auditTrace ~= true then return end
    ZB:Audit(("AUDQ sid=%s school=%s crit=%s"):format(
        audSafe(payload and payload.spellId), audSafe(payload and payload.schoolMask),
        tostring(payload and payload.isCrit == true)))
end

local function flushPending()
    ZB._flushAt = 0
    local pend = ZB._pending
    ZB._pending = {}
    if ZSBT._auditTrace == true then
        ZB:Audit(("AUDFLP n=%d"):format(#pend))
    end
    -- Swing-proven candidates get one retry at a wider window: on slow
    -- chat feeds their melee line can lag past the first flush.
    local requeue = nil
    -- Provenance-tiered claiming: sid-bearing candidates (real cast/pet
    -- record or class-resolved identity) claim lines before unattributed
    -- generics, so a foreign generic can no longer take the line a proven
    -- hit needed merely because it queued first. FIFO within each tier.
    for pass = 1, 2 do
        for i = 1, #pend do
            local p = pend[i]
            if p and candidateTier(p.payload) == pass then
                -- Never-seen feed counts as untrusted: a candidate that
                -- queued before we knew the feed was cold must not wait
                -- for a line that cannot exist.
                if ZB._vetoDisabled or not ZB._trusted or (ZB._lastLineAt or 0) <= 0 then
                    deliverOutgoing(p.payload)
                else
                    local kind
                    -- Retried generics keep the tight window — a lingering
                    -- unattributed wound must not reach a leftover line as
                    -- far out as a proven hit can.
                    local window = (p._retried and pass == 1) and RETRY_WINDOW or DEFER_WINDOW
                    kind = takeCandidateLine(p.t, window, p.payload)
                    if kind then
                        ZB._allows = ZB._allows + 1
                        ZB:Audit(("AUDCLAIM tier=%d sid=%s kind=%s"):format(
                            pass,
                            audSafe(p.payload and (p.payload.spellId or p.payload.petSpellId)),
                            tostring(kind)))
                        ZB:FileLog(("ALLOW kind=%s sid=%s"):format(tostring(kind), tostring(p.payload and p.payload.spellId)))
                        deliverOutgoing(p.payload)
                    elseif p.payload and p._retried ~= true then
                        -- Every candidate gets one retry: feed lines
                        -- routinely land after the first flush (~0.2s) in
                        -- grouped content, and a candidate whose line is
                        -- still in transit dies without ever meeting it.
                        -- Retail has no PLAYER_SWING so autos can never be
                        -- swing-proven — without this, first-hit autos were
                        -- flushed dead before their melee line arrived.
                        -- A foreign wound produces no MINE lines anyway, so
                        -- retrying it just delays its drop one cycle.
                        p._retried = true
                        requeue = requeue or {}
                        requeue[#requeue + 1] = p
                    elseif p.payload and p.payload.isAuto == true and p.payload.spellId == nil then
                        -- Rescue: a module that restricts auto kinds
                        -- (hunter: ranged only) can flag pet melee isAuto
                        -- when the hit outran its SWING_DAMAGE line. A
                        -- waiting melee line proves a pet swung — claim
                        -- it as pet damage instead of dropping the hit.
                        local cdb = ZSBT.ClassDB
                        local mk = (cdb and cdb.AutoLineKinds and cdb.AutoLineKinds() ~= nil)
                            and takeDamageLine(p.t, DEFER_WINDOW, { melee = true }) or nil
                        if mk then
                            local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
                            p.payload.isAuto = nil
                            p.payload._petRoute = true
                            if ec and cdb.ResolvePetMelee then
                                p.payload.petSpellId = cdb.ResolvePetMelee(ec)
                            end
                            ZB._allows = ZB._allows + 1
                            ZB:Audit(("AUDCLAIM tier=%d sid=%s kind=%s rescue=pet"):format(
                                pass, audSafe(p.payload.petSpellId), tostring(mk)))
                            deliverOutgoing(p.payload)
                        else
                            ZB._drops = ZB._drops + 1
                            ZB:FileLog(("DROP sid=%s"):format(tostring(p.payload and p.payload.spellId)))
                            local dp = p.payload or {}
                            ZB:Audit(("AUDROP ht=%.3f tier=%d sid=%s school=%s crit=%s src=%s%s"):format(
                                tonumber(p.t) or 0, pass, audSafe(dp.spellId), audSafe(dp.schoolMask),
                                tostring(dp.isCrit == true),
                                tostring(dp._foreignSchool == true and "fschool-" or ""),
                                tostring(dp._petRoute == true and "pet" or (dp.isAuto == true and "auto" or (dp.spellId ~= nil and "spell" or "generic")))))
                            -- Deferred off-whitelist drops are expected
                            -- foreign traffic — counting them toward feed
                            -- distrust would flip the veto permissive in
                            -- exactly the grouped fights they appear in.
                            if not dp._foreignSchool then sustainedRejection() end
                        end
                    elseif pass == 1 and p._retried == true and p.payload and p.payload.spellId ~= nil
                        and ZSBT.ClassDB and ZSBT.ClassDB.IsForever and ZSBT.ClassDB.IsForever() then
                        -- Forever's feed is structurally incomplete: some
                        -- player damage (Judgement, seal procs) produces no
                        -- SPELL_DAMAGE/RANGE_DAMAGE at all, so no classified
                        -- line can exist. A consumed cast record is already
                        -- provenance — after the retry confirms no line is
                        -- coming, dropping it only hides a proven own hit.
                        -- Retail keeps the strict line requirement; its
                        -- feed is complete.
                        ZB._allows = ZB._allows + 1
                        ZB:Audit(("AUDCLAIM tier=1 sid=%s kind=noline"):format(
                            audSafe(p.payload.spellId)))
                        ZB:FileLog(("ALLOW_NOLINE sid=%s"):format(tostring(p.payload.spellId)))
                        deliverOutgoing(p.payload)
                    else
                        ZB._drops = ZB._drops + 1
                        ZB:FileLog(("DROP sid=%s"):format(tostring(p.payload and p.payload.spellId)))
                        local dp = p.payload or {}
                        ZB:Audit(("AUDROP ht=%.3f tier=%d sid=%s school=%s crit=%s src=%s%s"):format(
                            tonumber(p.t) or 0, pass, audSafe(dp.spellId), audSafe(dp.schoolMask),
                            tostring(dp.isCrit == true),
                            tostring(dp._foreignSchool == true and "fschool-" or ""),
                            tostring(dp._petRoute == true and "pet" or (dp.isAuto == true and "auto" or (dp.spellId ~= nil and "spell" or "generic")))))
                        -- Deferred off-whitelist drops are expected foreign
                        -- traffic; they must not count toward feed distrust.
                        if not dp._foreignSchool then sustainedRejection() end
                    end
                end
            end
        end
    end
    -- Retry pass for swing-proven candidates whose line lagged the
    -- first flush: one more cycle at RETRY_WINDOW before dropping.
    if requeue and #requeue > 0 then
        for i = 1, #requeue do
            ZB._pending[#ZB._pending + 1] = requeue[i]
        end
        ZB:FileLog(("REQUEUE n=%d"):format(#requeue))
        if C_Timer and C_Timer.After then
            local tNow = GetTime and GetTime() or 0
            ZB._flushAt = tNow + DEFER_SEC
            C_Timer.After(DEFER_SEC, flushPending)
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

-- Attribution audit sink for /zsbt audit sessions: one record per damage
-- event ZSBT attributes (and per veto rejection), written to a separate
-- SavedVariables ring (prof.auditLog) so it can be diffed line-by-line
-- against the /combatlog filter output after a session.
function ZB:Audit(msg)
    if ZSBT._auditTrace ~= true then return end
    local prof = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics
    if type(prof) ~= "table" then return end
    local log = prof.auditLog
    if type(log) ~= "table" then
        log = {}
        prof.auditLog = log
    end
    local t = GetTime and GetTime() or 0
    log[#log + 1] = ("%.3f %s"):format(t, tostring(msg))
    if #log > 8000 then
        table.remove(log, 1)
    end
end

-- Formats one attributed combat event for the audit ring. Called from
-- Event_Collector.emit (untrusted/non-veto path) AND deliverOutgoing
-- (deferred-veto path, which bypasses emit entirely).
function ZB:AuditDamageEvent(eventType, payload)
    if ZSBT._auditTrace ~= true then return end
    local p = payload or {}
    -- Monotonic correlation id: unlike rawPipeId (a bounded registry that
    -- recycles), this never repeats within a session, so a rendered line
    -- can be paired to THIS decision exactly — not a neighbor's same pid.
    if p.traceId == nil then
        ZB._traceSeq = (ZB._traceSeq or 0) + 1
        p.traceId = ZB._traceSeq
    end
    local sid = p.spellId
    local src = "generic"
    if eventType == "PET_DAMAGE_COMBAT" or eventType == "PET_HEAL_LOG"
        or eventType == "PET_INCOMING_DAMAGE_COMBAT" or p._petRoute == true then
        src = "pet"
        if sid == nil then sid = p.petSpellId end
    elseif p.isAuto == true then
        src = "auto"
    elseif sid ~= nil then
        src = "spell"
    end
    local name = nil
    if sid ~= nil and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) and ZSBT.CleanSpellName then
        local okN, n = pcall(ZSBT.CleanSpellName, sid)
        if okN and type(n) == "string" and n ~= "" then name = n end
    end
    local amt = p.amount
    local amtStr
    if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(amt) then
        amtStr = tostring(amt)
    elseif type(p.amountText) == "string"
        and (not ZSBT.IsSafeString or ZSBT.IsSafeString(p.amountText))
        and p.amountText ~= "" then
        amtStr = p.amountText
    else
        amtStr = "secret"
    end
    ZB:Audit(("AUD ht=%.3f %s sid=%s name=%s school=%s crit=%s amt=%s src=%s tgt=%s pid=%s tid=%s"):format(
        tonumber(p.timestamp) or 0, eventType, audSafe(sid), audSafe(name),
        audSafe(p.schoolMask), tostring(p.isCrit == true), amtStr, src,
        audSafe(p.targetName), audSafe(p.rawPipeId), audSafe(p.traceId)))
end

-- Returns true when the caller should emit immediately; false when the
-- module took ownership (queued for deferred veto, or vetoed).
function ZB:OfferOutgoing(payload)
    if not ZB._trusted or ZB._vetoDisabled then return true end
    local tHit = payload and payload.timestamp
    if type(tHit) ~= "number" then return true end
    if vetoDisabledNow() then return true end

    -- Strict toggle (Class page / quick bar): unattributed candidates get
    -- no line claim and no display while the filter is trusted. This is
    -- the correctness-first trade — foreign bleed dies entirely, but own
    -- hits that earned no identity go quiet too. Not a veto rejection:
    -- it must not feed sustainedRejection.
    if candidateTier(payload) == 2 then
        local prof = ZSBT.db and ZSBT.db.profile
        local strictProof = ZSBT.Core and ZSBT.Core.IsRequireProofEnabled
            and ZSBT.Core:IsRequireProofEnabled() == true
        if strictProof or (prof and type(prof.classModule) == "table" and prof.classModule.hideUnattributed == true) then
            ZB:Audit(("AUDSUPP ht=%.3f school=%s crit=%s src=%s"):format(
                tonumber(tHit) or 0, audSafe(payload.schoolMask), tostring(payload.isCrit == true),
                tostring(payload._petRoute == true and "pet" or "generic")))
            return false
        end
    end

    -- Fast path: the line is already buffered (CLM arrived first).
    -- Restricted to tier-1 (sid-bearing) candidates — an unattributed
    -- generic must defer into the sorted batch so it cannot grab a line
    -- a proven candidate arriving moments later will need.
    -- An auto-attack claim may ONLY be confirmed by a melee/ranged line —
    -- it must not steal a spell line (pet spells produce lines constantly).
    if candidateTier(payload) == 1 then
        local fastKind = takeCandidateLine(tHit, VETO_WINDOW, payload)
        if fastKind then
            ZB._allows = ZB._allows + 1
            payload._vetoConfirmed = true
            ZB:Audit(("AUDCLAIM tier=1 sid=%s kind=%s fast=1"):format(
                audSafe(payload.spellId or payload.petSpellId), tostring(fastKind)))
            ZB:FileLog(("ALLOW_FAST kind=%s sid=%s"):format(tostring(fastKind), tostring(payload.spellId)))
            return true
        end
    end

    ZB._pending[#ZB._pending + 1] = { payload = payload, t = tHit }
    if #ZB._pending > 200 then
        -- Evict the oldest unattributed candidate first; a proven
        -- (sid-bearing) candidate must never lose its slot to a generic.
        local dropIdx = 1
        for i = 1, #ZB._pending do
            if candidateTier(ZB._pending[i].payload) == 2 then dropIdx = i; break end
        end
        local evicted = ZB._pending[dropIdx]
        table.remove(ZB._pending, dropIdx)
        ZB:Audit(("AUDPENDOVERFLOW tier=%d sid=%s"):format(
            candidateTier(evicted and evicted.payload),
            audSafe(evicted and evicted.payload and evicted.payload.spellId)))
    end
    auditQueued(payload)
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
