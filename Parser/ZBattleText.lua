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
-- read). Two filter encodings are supported: v1 colours each
-- damage/heal/miss event KIND via eventColoring; v2 colours each
-- line by SOURCE class via unitColoring (lineColorPriority=1) and
-- adds a foreign-source part whose lines prove "a non-self event
-- happened" — negative evidence used to veto borrowed claims.
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

-- Kinds that prove an outgoing heal happened: "heal" lines are
-- SPELL_HEAL (direct heals), "hot" lines are SPELL_PERIODIC_HEAL. The
-- filter is source-restricted to MINE+MY_PET, so a classified heal line
-- near a UNIT_COMBAT heal event is provably ours — the same ownership
-- guarantee the damage veto relies on, no aura reads needed.
local HEAL_LINE_KINDS = {
    heal = true, hot = true,
}
local HEAL_LINE_MAX = 24

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
ZB._healLines = ZB._healLines or {}

------------------------------------------------------------------------
-- v2 signal: lineColorPriority=1 colors each line by SOURCE class via
-- colors.unitColoring instead of event kind — real provenance data the
-- kind palette cannot express. A second filter part covers non-self
-- sources so co-attacker hits arrive as foreign-classed lines: a wound
-- matching one is provably NOT ours (the first negative evidence the
-- feed has ever carried). Highlighting doubles each class colour for
-- heal events, so dim = damage, bright = heal.
--
-- v2 own-class lines map back to legacy kind names so the claim path is
-- unchanged: mine-damage -> "direct", pet-damage -> "melee" (a MY_PET
-- line proves pet-ness, stronger than the old swing-kind guess),
-- heal lines -> "heal". Tick/ranged collapse into "direct" — candidate
-- kind sets are widened in source mode (ZB._srcMode) to match.
-- Palette channels stay <=0.66 so highlighted variants never collide
-- with another class or any v1 kind colour (dual classify fallback).
------------------------------------------------------------------------
local SRC_CLASSES = {
    mine       = { 0.50, 0.50, 0.50 },
    pet        = { 0.20, 0.55, 0.25 },
    friendly   = { 0.15, 0.40, 0.62 },
    hostileP   = { 0.62, 0.20, 0.05 },
    hostileU   = { 0.62, 0.55, 0.05 },
    neutral    = { 0.55, 0.30, 0.60 },
    unknown    = { 0.35, 0.55, 0.55 },
}
-- class name -> combat-log filter mask global (resolved at install)
local SRC_MASK_GLOBAL = {
    mine = "COMBATLOG_FILTER_MINE", pet = "COMBATLOG_FILTER_MY_PET",
    friendly = "COMBATLOG_FILTER_FRIENDLY_UNITS",
    hostileP = "COMBATLOG_FILTER_HOSTILE_PLAYERS",
    hostileU = "COMBATLOG_FILTER_HOSTILE_UNITS",
    neutral = "COMBATLOG_FILTER_NEUTRAL_UNITS",
    unknown = "COMBATLOG_FILTER_UNKNOWN_UNITS",
}
-- Sources the foreign filter part listens for: everyone who is not us.
local FOREIGN_CLASSES = {
    friendly = true, hostileP = true, hostileU = true,
    neutral = true, unknown = true,
}
-- Highlight doubles the colour for these events => dim=damage, bright=heal.
local HEAL_EVENTS = {
    SPELL_HEAL = true, SPELL_BUILDING_HEAL = true, SPELL_PERIODIC_HEAL = true,
}
-- Damage events only for the foreign part (no heals — we only veto
-- damage wounds; foreign heal lines would just be noise).
local FOREIGN_EVENTS = {}
for event, kind in pairs(EVENT_KINDS) do
    if DAMAGE_KINDS[kind] then FOREIGN_EVENTS[event] = true end
end

-- rgb -> {class, heal} lookup for v2 lines (built once; colours const).
local SRC_LOOKUP = {}
for cls, rgb in pairs(SRC_CLASSES) do
    SRC_LOOKUP[#SRC_LOOKUP + 1] = { r = rgb[1], g = rgb[2], b = rgb[3], cls = cls, heal = false }
    SRC_LOOKUP[#SRC_LOOKUP + 1] = {
        r = math.min(rgb[1] * 1.5, 1), g = math.min(rgb[2] * 1.5, 1),
        b = math.min(rgb[3] * 1.5, 1), cls = cls, heal = true,
    }
end

local function classifySource(r, g, b)
    for i = 1, #SRC_LOOKUP do
        local e = SRC_LOOKUP[i]
        if math.abs(r - e.r) <= COLOR_TOLERANCE
            and math.abs(g - e.g) <= COLOR_TOLERANCE
            and math.abs(b - e.b) <= COLOR_TOLERANCE then
            return e.cls, e.heal
        end
    end
    return nil
end

-- v2 own-class -> legacy kind so existing claim kinds keep working.
local function ownClassToKind(cls, heal)
    if heal then return "heal" end
    if cls == "pet" then return "melee" end
    return "direct"
end

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

ZB._foreignLines = ZB._foreignLines or {}
local FOREIGN_LINE_MAX = 64
local FOREIGN_WINDOW = 0.35
-- Cadence-guessed (_swingGuessed) noline candidates keep a foreign check
-- but at this tighter radius: a foreign wound's own line arrives
-- same-frame (~10ms measured on Retail), so 0.12s still vetoes it while
-- coincidental foreign lines kill far fewer genuine own hits.
local NOLINE_FOREIGN_WINDOW = 0.12
-- Max cast-record slot ordinal a noline rescue may carry: wounds that
-- drained a shared budget past this are theft-suspect (foreign hits
-- interleaved in the volley). Single-target casts are always slot 1.
local NOLINE_MAX_ORD = 3

local function recordForeignLine(t, cls, heal, r, g, b)
    local fl = ZB._foreignLines
    while #fl > 0 and t - fl[1].at > LINE_KEEP_SEC do
        table.remove(fl, 1)
    end
    if #fl >= FOREIGN_LINE_MAX then
        table.remove(fl, 1)
    end
    fl[#fl + 1] = { at = t, cls = cls, heal = heal, consumed = false }
    ZB._lastForeignLineAt = t
    ZB:FileLog(("FLIN cls=%s heal=%s rgb=%.2f,%.2f,%.2f"):format(
        tostring(cls), tostring(heal), r, g, b))
    if ZSBT._auditTrace == true then
        ZB:Audit(("FLIN cls=%s heal=%s"):format(tostring(cls), tostring(heal)))
    end
end

-- Consume the nearest unconsumed foreign-source line within `window` of
-- tHit: proof a non-self source produced a combat event at that instant.
-- Used at flush when no own line claimed the wound — turns "unproven"
-- into "provably foreign".
local function takeForeignLine(tHit, window)
    local best, bestDt
    for i = 1, #ZB._foreignLines do
        local l = ZB._foreignLines[i]
        if not l.consumed then
            local dt = math.abs(l.at - tHit)
            if dt <= window and (bestDt == nil or dt < bestDt) then
                best, bestDt = i, dt
            end
        end
    end
    if best then
        ZB._foreignLines[best].consumed = true
        return ZB._foreignLines[best].cls
    end
    return nil
end

function ZB:PeekForeignLine(tHit, window)
    if type(tHit) ~= "number" then return nil end
    for i = 1, #ZB._foreignLines do
        local l = ZB._foreignLines[i]
        if math.abs(l.at - tHit) <= window then
            return l.cls
        end
    end
    return nil
end

local function recordLine(r, g, b)
    if not (isSafeChannel(r) and isSafeChannel(g) and isSafeChannel(b)) then
        return
    end
    local t0 = GetTime and GetTime() or 0
    -- v2 first: source-classed colours. A foreign class never feeds the
    -- claim buffers — it is negative evidence only.
    local cls, heal = classifySource(r, g, b)
    if cls then
        if FOREIGN_CLASSES[cls] then
            recordForeignLine(t0, cls, heal, r, g, b)
            return
        end
        ZB._srcLinesSeen = (ZB._srcLinesSeen or 0) + 1
        ZB._srcMode = true
        ZB:FileLog(("LINv2 cls=%s heal=%s rgb=%.2f,%.2f,%.2f"):format(
            tostring(cls), tostring(heal), r, g, b))
        local kind = ownClassToKind(cls, heal)
        if HEAL_LINE_KINDS[kind] then
            local hl = ZB._healLines
            while #hl > 0 and t0 - hl[1].at > LINE_KEEP_SEC do
                table.remove(hl, 1)
            end
            if #hl >= HEAL_LINE_MAX then
                table.remove(hl, 1)
            end
            hl[#hl + 1] = { at = t0, kind = kind, consumed = false }
            if ZB._healLineHook then
                ZB._healLineHook(t0, kind)
            end
            return
        end
        local lines = ZB._lines
        while #lines > 0 and t0 - lines[1].at > LINE_KEEP_SEC do
            table.remove(lines, 1)
        end
        if #lines >= LINE_MAX then
            table.remove(lines, 1)
        end
        lines[#lines + 1] = { at = t0, kind = kind, consumed = false }
        ZB._lastLineAt = t0
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
    if HEAL_LINE_KINDS[kind] then
        -- Heal lines get their own small ring: follower/NPC heals can be
        -- spammy and must not evict damage lines the veto still needs.
        local hl = ZB._healLines
        while #hl > 0 and t - hl[1].at > LINE_KEEP_SEC do
            table.remove(hl, 1)
        end
        if #hl >= HEAL_LINE_MAX then
            table.remove(hl, 1)
        end
        hl[#hl + 1] = { at = t, kind = kind, consumed = false }
        if ZB._healLineHook then
            ZB._healLineHook(t, kind)
        end
        return
    end
    -- Only damage kinds feed the veto buffer; miss/utility lines are
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

-- Consume the nearest unconsumed heal-kind line within `window` of tHit.
local function takeHealLine(tHit, window, kinds)
    local best, bestDt
    for i = 1, #ZB._healLines do
        local l = ZB._healLines[i]
        if HEAL_LINE_KINDS[l.kind] and not l.consumed
            and (kinds == nil or kinds[l.kind] == true) then
            local dt = math.abs(l.at - tHit)
            if dt <= window and (bestDt == nil or dt < bestDt) then
                best, bestDt = i, dt
            end
        end
    end
    if best then
        ZB._healLines[best].consumed = true
        return ZB._healLines[best].kind
    end
    return nil
end

-- Consume the nearest unconsumed heal/hot line within `window` of tHit.
-- "hot" proves a SPELL_PERIODIC_HEAL of ours fired; "heal" a direct
-- SPELL_HEAL. Callers pass kinds to restrict (e.g. { hot = true }).
function ZB:TakeHealLine(tHit, window, kinds)
    if type(tHit) ~= "number" then return nil end
    return takeHealLine(tHit, window, kinds)
end

-- Non-consuming variant: returns the NEAREST matching line's kind and
-- timestamp so the caller can branch on kind and only consume on a
-- successful claim (peek-then-take — a failed name must not burn the
-- line for the real event still in flight).
function ZB:PeekHealLine(tHit, window, kinds)
    if type(tHit) ~= "number" then return nil end
    local best, bestDt
    for i = 1, #ZB._healLines do
        local l = ZB._healLines[i]
        if HEAL_LINE_KINDS[l.kind] and not l.consumed
            and (kinds == nil or kinds[l.kind] == true) then
            local dt = math.abs(l.at - tHit)
            if dt <= window and (bestDt == nil or dt < bestDt) then
                best, bestDt = i, dt
            end
        end
    end
    if best then
        local l = ZB._healLines[best]
        return l.kind, l.at
    end
    return nil
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
        return ZB._lines[best].kind, best
    end
    return nil
end

-- Distance to the nearest foreign DAMAGE line — evidence a non-self
-- source produced a hit at tHit. Heal lines are ignored: a friendly
-- heal painting near a wound says nothing about who dealt it. Consumed
-- lines still count — the foreign event happened whether or not
-- another wound already spent that proof.
local function nearestForeignDamageDt(tHit)
    local best
    for i = 1, #ZB._foreignLines do
        local l = ZB._foreignLines[i]
        if l.heal ~= true then
            local dt = math.abs(l.at - tHit)
            if best == nil or dt < best then best = dt end
        end
    end
    return best
end

-- Stolen-line arbitration: an own event paints its own-source line at
-- ~0ms offset from its wound, while a foreign hit paints a foreign
-- line at ITS instant. A wound whose claimed own line sits FARTHER
-- than a foreign damage line is almost certainly that foreign event
-- borrowing a nearby own line (observed in a two-warlock raid: half
-- the claimed Fel Firebolts had a foreign line strictly nearer). The
-- caller must release the claimed line so its real owner can pair.
local function foreignDamageNearer(tHit, lineIdx)
    local l = lineIdx and ZB._lines[lineIdx] or nil
    if l == nil then return false end
    local fdt = nearestForeignDamageDt(tHit)
    return fdt ~= nil and fdt < math.abs(l.at - tHit)
end

-- Non-consuming look at buffered lines: class modules use this for
-- swing-evidence decisions (e.g. hunter distinguishes its ranged
-- auto-shot from pet melee by which line kind is present) without
-- burning the line an actual claimant still needs. includeConsumed
-- also accepts lines already claimed — a consumed MINE line is still
-- proof our own feed reported damage near the hit (used by the
-- contested feed, where a claimed-then-evicted line would otherwise
-- let the next own wound masquerade as a second attacker).
function ZB:PeekDamageLine(tHit, window, kinds, includeConsumed)
    if type(tHit) ~= "number" then return nil end
    for i = 1, #ZB._lines do
        local l = ZB._lines[i]
        if DAMAGE_KINDS[l.kind] and (includeConsumed or not l.consumed)
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

local function v2PaletteMatches(colors)
    if type(colors) ~= "table" or type(colors.unitColoring) ~= "table" then
        return false
    end
    local uc = colors.unitColoring
    for cls, maskName in pairs(SRC_MASK_GLOBAL) do
        local mask = _G[maskName]
        if type(mask) ~= "number" then return false end
        if not colorMatches(uc[mask], SRC_CLASSES[cls]) then return false end
    end
    return true
end

-- v2 structure: part 1 must be exactly MINE+PET sources; every further
-- part may only add foreign-class sources (never another self part).
local function v2SourcesOK(f)
    local mineFlag = COMBATLOG_FILTER_MINE
    local petFlag = COMBATLOG_FILTER_MY_PET
    if type(f.filters) ~= "table" or #f.filters < 2 then return false end
    local p1 = f.filters[1]
    if type(p1) ~= "table" or type(p1.sourceFlags) ~= "table" then return false end
    local n = 0
    for flag, on in pairs(p1.sourceFlags) do
        if on then
            if flag ~= mineFlag and flag ~= petFlag then return false end
            n = n + 1
        end
    end
    if n ~= 2 or p1.sourceFlags[mineFlag] ~= true or p1.sourceFlags[petFlag] ~= true then
        return false
    end
    local sawForeign = false
    for i = 2, #f.filters do
        local sf = f.filters[i] and f.filters[i].sourceFlags
        if type(sf) ~= "table" then return false end
        local any = false
        for flag, on in pairs(sf) do
            if on then
                any = true
                local isForeign = false
                for cls in pairs(FOREIGN_CLASSES) do
                    if flag == _G[SRC_MASK_GLOBAL[cls]] then isForeign = true break end
                end
                if not isForeign then return false end
            end
        end
        if any then sawForeign = true end
    end
    return sawForeign
end

local function sourcesRestricted(f)
    if f and f.zbtver == 2 then
        return v2SourcesOK(f)
    end
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
    if f.zbtver == 2 then
        if settings.lineColorPriority ~= 1 then
            return false, "v2 source coloring off"
        end
        if settings.lineHighlighting ~= true then
            return false, "v2 heal highlighting off"
        end
        if not v2PaletteMatches(f.colors) then
            return false, "v2 unitColoring palette changed"
        end
        if not v2SourcesOK(f) then
            return false, "v2 source parts changed"
        end
        ZB._srcMode = true
        return true, nil
    end
    ZB._srcMode = false
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
    local _perf = ZSBT.Perf
    local _pt0 = _perf and _perf.on and _perf.t()
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
    if _pt0 then _perf:done("zb.verify", _pt0) end
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
    filter.settings.lineColorPriority = 1
    filter.settings.lineHighlighting = true
    filter.zbtver = 2

    filter.colors = filter.colors or {}
    filter.colors.eventColoring = filter.colors.eventColoring or {}
    for event, kind in pairs(EVENT_KINDS) do
        local c = KIND_COLORS[kind]
        filter.colors.eventColoring[event] = { r = c[1], g = c[2], b = c[3], a = 1 }
    end
    -- Source-class palette: the line colour carries WHO produced the
    -- event. Highlighting marks heal lines (dim = damage, bright = heal).
    filter.colors.unitColoring = filter.colors.unitColoring or {}
    for cls, maskName in pairs(SRC_MASK_GLOBAL) do
        local mask = _G[maskName]
        local c = SRC_CLASSES[cls]
        if type(mask) == "number" and c then
            filter.colors.unitColoring[mask] = { r = c[1], g = c[2], b = c[3], a = 1 }
        end
    end
    local hl = {}
    for ev in pairs(HEAL_EVENTS) do hl[ev] = true end
    filter.colors.highlightedEvents = hl

    -- Part 1: own sources (you + pet/guardians), full damage+heal event
    -- whitelist. Part 2: every other source class, damage events only —
    -- their lines arrive foreign-coloured and feed the veto buffer as
    -- negative evidence. No dest part: incoming stays out.
    local mineFlag = COMBATLOG_FILTER_MINE
    local petFlag = COMBATLOG_FILTER_MY_PET
    if type(mineFlag) == "number" and type(petFlag) == "number" then
        local ownList = {}
        for ev, kind in pairs(EVENT_KINDS) do
            if DAMAGE_KINDS[kind] or HEAL_LINE_KINDS[kind] then ownList[ev] = true end
        end
        local foreignFlags = {}
        for cls in pairs(FOREIGN_CLASSES) do
            local mask = _G[SRC_MASK_GLOBAL[cls]]
            if type(mask) == "number" then foreignFlags[mask] = true end
        end
        local foreignList = {}
        for ev in pairs(FOREIGN_EVENTS) do foreignList[ev] = true end
        filter.filters = {
            {
                sourceFlags = { [mineFlag] = true, [petFlag] = true },
                eventList = ownList,
            },
            {
                sourceFlags = foreignFlags,
                eventList = foreignList,
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
-- Queue flush cadence: how long an emit waits for its combat-log line
-- before the flush pass decides. Profile-tunable (Outgoing damage
-- slider); lower feels snappier but gives lagging lines less time to
-- arrive, so more candidates die unproven in dense fights.
local function deferSec()
    local d = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.outgoing
        and ZSBT.db.profile.outgoing.damage and ZSBT.db.profile.outgoing.damage.linePairDelay
    if type(d) ~= "number" or d ~= d then return DEFER_SEC end
    if d < 0.05 then return 0.05 end
    if d > 0.50 then return 0.50 end
    return d
end
local RETRY_WINDOW = 0.90

-- TESTING flag (outgoing.damage.provenNoLine): lets a cast/swing-proven
-- candidate emit after its retry confirms no proof line is coming —
-- the same noline rescue Forever uses, opened on Retail for raid
-- windows where the own-line feed delivers a small fraction of real
-- own events. Provenance is still required: unnamed generics are
-- unaffected. Foreign wounds that stole a cast record can emit too —
-- that is the accepted cost of the flag.
local function provenNoLineEnabled()
    local prof = ZSBT.db and ZSBT.db.profile
    local d = prof and prof.outgoing and prof.outgoing.damage
    return d ~= nil and d.provenNoLine == true
end

ZB._pending = ZB._pending or {}
ZB._flushAt = ZB._flushAt or 0


-- Cold-feed own evidence: no own line has ever classified, so the veto
-- has nothing to pair against — but a cold bypass may only open while
-- the player could plausibly produce a wound. A wound on our target
-- while we are a passive observer (out of combat, no recent cast, no
-- auto-attack, pet idle) is foreign by construction; auto-allowing it
-- showed a co-attacker's hits in our scroll. Target wounds cannot serve
-- as evidence here — UNIT_COMBAT has no source, so a co-attacker's hits
-- stamp them too (self-fulfilling).
local function coldFeedOwnEvidence()
    local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
    local tC = GetTime and GetTime() or 0
    if ec and type(ec._lastPlayerSpellAt) == "number"
        and (tC - ec._lastPlayerSpellAt) <= 2.5 then
        return true
    end
    if IsCurrentSpell then
        local okAA, resAA = pcall(IsCurrentSpell, 6603)
        if okAA and resAA == true then return true end
    end
    if UnitAffectingCombat then
        local okP, inC = pcall(UnitAffectingCombat, "player")
        if okP and inC == true then return true end
        local okPet, inPC = pcall(UnitAffectingCombat, "pet")
        if okPet and inPC == true then return true end
    end
    return false
end

local function vetoDisabledNow()
    if ZB._vetoDisabled then return true end
    -- Cold start: no line has ever been classified this session. The
    -- veto has nothing to pair against — deferred candidates would all
    -- die at flush, which is why openers go silent until the feed warms.
    -- Emit immediately until the first line arrives, same as untrusted.
    -- A quiet-but-seen feed is different: queue and let the wound's own
    -- line prove it when it lands, instead of emitting unproven (which
    -- would pass party/follower hits on the shared target too). The
    -- bypass is additionally gated on own combat evidence: with none,
    -- no wound can be ours and candidates must queue and die at flush.
    if (ZB._lastLineAt or 0) <= 0 then return coldFeedOwnEvidence() end
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
    -- v2 source mode: lines carry source class, not event kind. Only
    -- "direct" (MINE damage), "melee" (MY_PET damage) and "heal" exist.
    -- Own hits claim direct; pet claims claim pet lines only — a pet
    -- emit requires MY_PET proof, never a borrowed own line.
    if ZB._srcMode == true then
        if payload and (payload.isAuto == true or payload._swingProven == true
            or payload._swingGuessed == true) then
            return { direct = true }, nil, nil
        end
        if payload and payload._petRoute == true then
            -- MY_PET covers pets AND guardians (0x3111 includes
            -- TYPE_GUARDIAN): every legit pet hit — controlled pet or
            -- guardian, melee or caster — produces a melee-kind line.
            -- Fallback set for non-srcMode-style claims; under srcMode
            -- takeCandidateLine claims the NEAREST own line across
            -- melee+direct and the winning kind decides the scroll —
            -- a direct win proves the wound was a mislabeled own event,
            -- a melee win proves real pet/guardian damage.
            return { melee = true }, nil, nil
        end
        return { direct = true }, nil, nil
    end
    if payload and (payload.isAuto == true or payload._swingProven == true
        or payload._swingGuessed == true) then
        return autoLineKinds(), nil, nil
    end
    if payload and payload._petRoute == true then
        -- A melee-guess pet (ResolvePetMelee, no cast record) may only
        -- own melee/ranged lines: letting "pet Auto Attack" claim
        -- direct/tick lines let foreign physical hits borrow any nearby
        -- line — observed: warrior swing on a shared dummy emitted as
        -- pet:6603 on a kind=direct claim. Cast/resolve pets keep the
        -- full set (a caster pet's hit produces direct lines).
        if payload.petEvidence == "melee" then
            return MELEE_KINDS, nil, nil
        end
        return nil, nil, nil
    end
    return kindPreference(payload)
end

-- Pet noline provenance (FCT petOut/PetAttacking model): hard evidence
-- (a consumed pet cast/melee record) rescues on its own; guess-evidence
-- needs a live pet verifiably engaged and an uncontested timeline — a
-- co-attacker's melee wound routed pet is the false positive this gate
-- exists to stop. UnitIsUnit is secret-gated in combat on Midnight: a
-- readable false (pet not on this target) vetoes, unreadable falls back
-- to UnitExists + the contested gate.
local function petNolineProven(payload, ecF, tHit)
	local pe = payload and payload.petEvidence
	if pe == "cast" or pe == "melee" or pe == "mline" then return true end
	local okE, petExists = pcall(UnitExists, "pet")
	if not (okE and petExists == true) then return false end
	if UnitIsUnit then
		local okT, same = pcall(UnitIsUnit, "pettarget", "target")
		if okT then
			local okB, isSame = pcall(function() return same == true end)
			if okB and isSame == false then return false end
		end
	end
	local contested = ecF and type(ecF._autoContestUntil) == "number"
		and ecF._autoContestUntil > (tonumber(tHit) or 0)
	return not contested
end

local function takeCandidateLine(tHit, window, payload)
    if ZB._srcMode == true and payload and payload._petRoute == true then
        -- The kind of the NEAREST own line decides the scroll: a MY_PET
        -- line proves a pet/guardian hit; a MINE line proves the wound
        -- was actually an own event the pet name got guessed onto (AoE
        -- splash past its cast budget). Distance is the honest arbiter —
        -- the real event's own line sits ~0ms from its wound while a
        -- coincident line of the other class is further away.
        local kindM, idxM = takeDamageLine(tHit, window, { melee = true })
        -- Hard-evidence pet routes (real pet cast/melee/resolved record)
        -- can never legitimately claim a MINE direct line — their own
        -- cls=pet line exists on feeds that carry it, so a coincident
        -- direct line belongs to an own wound. Letting them race stole
        -- player lines and stripped real pet hits to generic (observed:
        -- 16 PET_ROUTE_DIRECT strips/session on retail hunter).
        local pe = payload.petEvidence
        if pe == "cast" or pe == "melee" or pe == "resolve"
            or pe == "mline" then
            return kindM, idxM
        end
        local kindD, idxD = takeDamageLine(tHit, window, { direct = true })
        if kindM and kindD then
            local dm = math.abs(ZB._lines[idxM].at - tHit)
            local dd = math.abs(ZB._lines[idxD].at - tHit)
            if dd < dm then
                ZB._lines[idxM].consumed = false
                return kindD, idxD
            end
            ZB._lines[idxD].consumed = false
        end
        if kindM then return kindM, idxM end
        return kindD, idxD
    end
    local a, b, c = candidateKinds(payload)
    local kind, idx = takeDamageLine(tHit, window, a)
    if not kind and b then kind, idx = takeDamageLine(tHit, window, b) end
    if not kind and c then kind, idx = takeDamageLine(tHit, window, c) end
    return kind, idx
end

-- Provenance tier for line claiming. Tier 1 = sid-bearing (the hit
-- consumed a real cast/pet record or a class-resolved identity — all
-- school-gated, overwhelmingly ours). Tier 2 = unattributed generic;
-- foreign bleed lives here. sid nil-checks are secret-safe (existence,
-- not value comparison).
local function candidateTier(payload)
    if payload and (payload.spellId ~= nil or payload.petSpellId ~= nil
        or payload._swingProven == true or payload._swingGuessed == true) then
        return 1
    end
    return 2
end

-- Evidence rank for flush claiming order (fit-ranked allocation):
-- when lines are scarcer than candidates, the strongest evidence
-- claims first instead of FIFO. Own cast/swing provenance first,
-- then pet claims backed by a real cast/melee event, then pet
-- school+window guesses, generics last.
local function claimOrder(payload)
    if not payload then return 4 end
    if payload.spellId ~= nil or payload._swingProven == true
        or payload._swingGuessed == true then
        return 1
    end
    if payload._petRoute == true or payload.petSpellId ~= nil then
        local pe = payload.petEvidence
        if pe == "cast" or pe == "melee" or pe == "mline" then
            return 2
        end
        return 3
    end
    return 4
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
        -- Deferred deliveries bypass emit() and its SHOW record — log the
        -- same shape here so every display-bound payload leaves a line.
        local ts = payload and tonumber(payload.timestamp)
        -- Same cadence anchor as emit(): an emitted school-1 sid=nil own
        -- hit is a confirmed auto, and noline-rescued autos re-anchor the
        -- horizon they were predicted from.
        if ts and ev == "OUTGOING_DAMAGE_COMBAT"
            and payload.spellId == nil and payload.schoolMask == 1
            and payload._petRoute ~= true and ec.NoteSwingAnchor then
            ec:NoteSwingAnchor(ts)
        end
        if ts then
            ZB:FileLog(("SHOW %s sid=%s psid=%s pev=%s ht=%.3f dly=%.2f via=def"):format(
                ev, tostring(payload.spellId), tostring(payload.petSpellId),
                tostring(payload.petEvidence), ts,
                (GetTime and GetTime() or ts) - ts))
        end
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
    -- Fit-ranked claiming (evidence order, not FIFO): own cast/swing
    -- provenance claims first, then pet hard evidence (cast/melee),
    -- then pet school+window guesses, generics last — scarce lines go
    -- to the candidates most likely to own them.
    for pass = 1, 4 do
        for i = 1, #pend do
            local p = pend[i]
            if p and claimOrder(p.payload) == pass then
                -- Never-seen feed counts as untrusted ONLY while we are
                -- plausibly producing wounds: own cast/auto-attack/combat
                -- evidence means the feed is genuinely dead rather than
                -- simply quiet because we are not fighting. Foreign
                -- wounds on our target cannot stand in for this —
                -- UNIT_COMBAT carries no source, so a co-attacker's
                -- stream would certify itself (observed: foreign melee
                -- shown as ours while we were not even fighting).
                local cold = (ZB._lastLineAt or 0) <= 0
                local coldOK = cold and coldFeedOwnEvidence() or false
                if ZB._vetoDisabled or not ZB._trusted or (cold and coldOK) then
                    deliverOutgoing(p.payload)
                elseif cold then
                    ZB:Audit(("AUDROP ht=%.3f tier=%d sid=%s school=%s crit=%s src=%s why=cold"):format(
                        tonumber(p.t) or 0, pass,
                        audSafe(p.payload and (p.payload.spellId or p.payload.petSpellId)),
                        audSafe(p.payload and p.payload.schoolMask),
                        tostring(p.payload and p.payload.isCrit == true),
                        tostring(p.payload and p.payload._petRoute == true and "pet" or (p.payload and p.payload.isAuto == true and "auto" or (p.payload and p.payload.spellId ~= nil and "spell" or "generic")))))
                else
                    local kind
                    -- Retried generics keep the tight window — a lingering
                    -- unattributed wound must not reach a leftover line as
                    -- far out as a proven hit can.
                    local window = (p._retried and pass == 1) and RETRY_WINDOW or DEFER_WINDOW
                    -- Deferred off-whitelist wound under recent contention:
                    -- a claimed MINE line only proves our feed fired near
                    -- t, never that THIS wound was ours. Foreign-school
                    -- hits can never be proven while a second attacker is
                    -- armed — force the drop instead of borrowing a line.
                    local ecF = ZSBT.Parser and ZSBT.Parser.EventCollector
                    local fsSeq = p.payload and p.payload._fschoolSeq
                    local fsBlocked = p.payload and p.payload._foreignSchool == true
                        and ecF ~= nil and (
                            (type(ecF._autoContestUntil) == "number"
                                and ecF._autoContestUntil > (tonumber(p.t) or 0))
                            -- Foreign stream grew after this wound queued:
                            -- later off-whitelist hits prove a second
                            -- attacker was already active at p.t.
                            or (type(ecF._fschoolCount) == "number"
                                and type(fsSeq) == "number"
                                and ecF._fschoolCount > fsSeq))
                    -- Late-swing hold (FCT port): on a swing-capable
                    -- client the per-swing report may follow its wound
                    -- by up to 0.35s — a queued wound's swing can arrive
                    -- between emit and this flush. SwingCovers accepts
                    -- the retroactive window, so re-test and upgrade the
                    -- stamp before tier/rescue checks below.
                    if p.payload and p.payload.spellId == nil
                        and p.payload._swingProven ~= true
                        and p.payload.schoolMask == 1
                        and p.payload._petRoute ~= true
                        and not (ZSBT.ClassDB and ZSBT.ClassDB.VetoAuto
                            and ZSBT.ClassDB.VetoAuto())
                        and ecF and ecF._swingSupported == true
                        and ecF.SwingCovers
                        and ecF:SwingCovers(tonumber(p.t) or 0) then
                        p.payload._swingProven = true
                    end
                    -- Noline rescue eligibility: a proven candidate that
                    -- survives to its post-retry flush with no own line may
                    -- emit on cast/swing provenance alone (provenNoLine
                    -- flag; always-on for Forever's sparse feed). It must
                    -- also skip the fline gate below — in raid a foreign
                    -- line is always in-window, which made the rescue
                    -- unreachable exactly where it is needed.
                    -- Budget-ordinal theft gate: a wound that took a LATE
                    -- slot of a shared cast record (AoE budget) cannot
                    -- rescue — the record was most plausibly drained by
                    -- foreign hits interleaved in our volley. Early
                    -- slots stay rescuable: our own hit wave claims
                    -- first. Verified in raid: every noline leak wore a
                    -- stolen 8-budget record's name.
                    local ordBlocked = p.payload and type(p.payload._claimOrd) == "number"
                        and p.payload._claimOrd > NOLINE_MAX_ORD
                    local nolineProven = pass == 1 and p._retried == true
                        and not fsBlocked and not ordBlocked and p.payload
                        and (p.payload.spellId ~= nil
                            or p.payload._swingProven == true
                            or p.payload._swingGuessed == true)
                        and (provenNoLineEnabled()
                            or (ZSBT.ClassDB and ZSBT.ClassDB.IsForever
                                and ZSBT.ClassDB.IsForever()))
                    -- Cadence-guessed wounds keep a foreign-line check at
                    -- the narrowed radius instead of skipping the gate:
                    -- their provenance is a rhythm guess, not a recorded
                    -- client event, so a same-frame foreign line still
                    -- vetoes. SpellId/real-swing provenance skips entirely.
                    local nolineGuessed = nolineProven
                        and p.payload and p.payload._swingGuessed == true
                    -- Pet-route wounds: Forever's feed carries no MY_PET
                    -- lines at all, so a pet hit can never satisfy the line
                    -- requirement. Treat the route like a cadence guess —
                    -- the narrowed same-frame foreign check still vetoes a
                    -- co-attacker's hit, then the pet noline rescue below
                    -- emits on route provenance alone.
                    local petNoline = p.payload and p.payload._petRoute == true
                        and not fsBlocked
                        and (provenNoLineEnabled()
                            or (ZSBT.ClassDB and ZSBT.ClassDB.IsForever
                                and ZSBT.ClassDB.IsForever()))
                    local lidx
                    kind = nil
                    if not fsBlocked then kind, lidx = takeCandidateLine(p.t, window, p.payload) end
                    if kind and foreignDamageNearer(tonumber(p.t) or 0, lidx) then
                        -- Borrowed line: this wound's real line was the
                        -- foreign one at its instant — release the own
                        -- line so a queued own candidate can claim it,
                        -- then drop with the usual foreign proof.
                        ZB._lines[lidx].consumed = false
                        kind = nil
                        takeForeignLine(tonumber(p.t) or 0, FOREIGN_WINDOW)
                        ZB._drops = ZB._drops + 1
                        ZB:FileLog(("DROP fnear sid=%s school=%s ht=%.3f"):format(tostring(p.payload and p.payload.spellId), tostring(p.payload and p.payload.schoolMask), tonumber(p.t) or 0))
                        ZB:Audit(("AUDROP ht=%.3f tier=%d sid=%s school=%s crit=%s src=fnear"):format(
                            tonumber(p.t) or 0, pass,
                            audSafe(p.payload and (p.payload.spellId or p.payload.petSpellId)),
                            audSafe(p.payload and p.payload.schoolMask),
                            tostring(p.payload and p.payload.isCrit == true)))
                    elseif kind then
                        if ZB._srcMode == true and kind == "direct"
                            and p.payload and p.payload._petRoute == true then
                            -- The nearest own line was MINE — this was
                            -- an own event the pet guess mislabeled (AoE
                            -- splash past its cast budget). Strip the
                            -- route and name; it emits as ordinary
                            -- outgoing damage instead of a named pet hit.
                            p.payload._petRoute = nil
                            p.payload.petSpellId = nil
                            p.payload.petEvidence = nil
                            p.payload._petSidLearn = nil
                            ZB:FileLog(("PET_ROUTE_DIRECT ht=%.3f"):format(
                                tonumber(p.t) or 0))
                        end
                        ZB._allows = ZB._allows + 1
                        ZB:Audit(("AUDCLAIM tier=%d sid=%s kind=%s"):format(
                            pass,
                            audSafe(p.payload and (p.payload.spellId or p.payload.petSpellId)),
                            tostring(kind)))
                        ZB:FileLog(("ALLOW kind=%s sid=%s"):format(tostring(kind), tostring(p.payload and p.payload.spellId)))
                        deliverOutgoing(p.payload)
                    elseif (not nolineProven or nolineGuessed)
                        and (claimOrder(p.payload) > 1 or p._retried == true)
                        and takeForeignLine(tonumber(p.t) or 0,
                            ((nolineGuessed or petNoline) and NOLINE_FOREIGN_WINDOW) or FOREIGN_WINDOW) ~= nil then
                        -- Negative evidence: a foreign-source line landed
                        -- within the wound's window and no own line
                        -- claimed it — this hit belongs to a co-attacker.
                        -- Drop now instead of burning the retry on a
                        -- wound that can never be proven ours.
                        ZB._drops = ZB._drops + 1
                        ZB:FileLog(("DROP fline sid=%s school=%s ht=%.3f"):format(tostring(p.payload and p.payload.spellId), tostring(p.payload and p.payload.schoolMask), tonumber(p.t) or 0))
                        ZB:Audit(("AUDROP ht=%.3f tier=%d sid=%s school=%s crit=%s src=fline"):format(
                            tonumber(p.t) or 0, pass,
                            audSafe(p.payload and (p.payload.spellId or p.payload.petSpellId)),
                            audSafe(p.payload and p.payload.schoolMask),
                            tostring(p.payload and p.payload.isCrit == true)))
                    elseif p.payload and p._retried ~= true then
                        -- Every candidate retries while its line could
                        -- still be in transit: feed lines routinely land
                        -- after the first flush (~0.2s) in grouped
                        -- content. Own-proven (cast/swing) candidates get
                        -- a second cycle — an in-flight nuke's line lags
                        -- its hit by up to ~0.35s and the cast evidence
                        -- already outweighs a coincident foreign line;
                        -- unproven candidates get one (a foreign wound
                        -- produces no MINE lines, retrying it only delays
                        -- its drop).
                        local maxRetries = claimOrder(p.payload) == 1 and 2 or 1
                        p._retries = (p._retries or 0) + 1
                        if p._retries >= maxRetries then p._retried = true end
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
                            p.payload.petEvidence = "mline"
                            if ec and cdb.ResolvePetMelee then
                                p.payload.petSpellId = cdb.ResolvePetMelee(ec)
                            end
                            ZB._allows = ZB._allows + 1
                            ZB:Audit(("AUDCLAIM tier=%d sid=%s kind=%s rescue=pet"):format(
                                pass, audSafe(p.payload.petSpellId), tostring(mk)))
                            deliverOutgoing(p.payload)
                        elseif provenNoLineEnabled()
                            or (ZSBT.ClassDB and ZSBT.ClassDB.IsForever
                                and ZSBT.ClassDB.IsForever()) then
                            -- Forever's feed is incomplete — a proven auto
                            -- whose melee line was stolen by a spell claim
                            -- must still display (same noline rescue as
                            -- sid-bearing hits below). Retail joins via the
                            -- provenNoLine testing flag.
                            ZB._allows = ZB._allows + 1
                            ZB:Audit(("AUDCLAIM tier=%d sid=%s kind=noline auto=1"):format(
                                pass, audSafe(p.payload.spellId)))
                            deliverOutgoing(p.payload)
                        else
                            ZB._drops = ZB._drops + 1
                            ZB:FileLog(("DROP sid=%s school=%s ht=%.3f"):format(tostring(p.payload and p.payload.spellId), tostring(p.payload and p.payload.schoolMask), tonumber(p.t) or 0))
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
                    elseif petNoline and p._retried == true
                        and petNolineProven(p.payload, ecF, tonumber(p.t) or 0) then
                        -- Forever pet rescue: the retry confirmed no MY_PET
                        -- line is coming (none can exist on this feed) and
                        -- the narrowed foreign gate found no same-frame
                        -- co-attacker line — emit on route provenance.
                        ZB._allows = ZB._allows + 1
                        ZB:Audit(("AUDCLAIM tier=%d sid=%s kind=noline pet=1"):format(
                            pass, audSafe(p.payload and p.payload.petSpellId)))
                        ZB:FileLog(("ALLOW_NOLINE pet=1 psid=%s pev=%s"):format(
                            tostring(p.payload and p.payload.petSpellId),
                            tostring(p.payload and p.payload.petEvidence)))
                        deliverOutgoing(p.payload)
                    elseif nolineProven then
                        -- Forever's feed is structurally incomplete: some
                        -- player damage (Judgement, seal procs) produces no
                        -- SPELL_DAMAGE/RANGE_DAMAGE at all, so no classified
                        -- line can exist. A consumed cast record is already
                        -- provenance — after the retry confirms no line is
                        -- coming, dropping it only hides a proven own hit.
                        -- Retail keeps the strict line requirement unless
                        -- the provenNoLine testing flag opens this rescue:
                        -- raid line delivery can starve far below the real
                        -- own-event rate, the same shape as Forever's feed.
                        ZB._allows = ZB._allows + 1
                        ZB:Audit(("AUDCLAIM tier=1 sid=%s kind=noline"):format(
                            audSafe(p.payload.spellId)))
                        ZB:FileLog(("ALLOW_NOLINE sid=%s swg=%s ord=%s"):format(
                            tostring(p.payload.spellId),
                            tostring(p.payload._swingGuessed == true),
                            tostring(p.payload._claimOrd)))
                        deliverOutgoing(p.payload)
                    else
                        ZB._drops = ZB._drops + 1
                        ZB:FileLog(("DROP sid=%s school=%s ht=%.3f"):format(tostring(p.payload and p.payload.spellId), tostring(p.payload and p.payload.schoolMask), tonumber(p.t) or 0))
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
            ZB._flushAt = tNow + deferSec()
            C_Timer.After(deferSec(), function()
            local _perf = ZSBT.Perf
            local _pt0 = _perf and _perf.on and _perf.t()
            flushPending()
            if _pt0 then _perf:done("zb.flush", _pt0) end
        end)
        end
    end
end

-- Trace sink for /zsbt ucdrop sessions: appends to a SavedVariables
-- ring buffer (ZSBTDB -> WTF/.../SavedVariables/ZSBTDB.lua) so decisions can be
-- read post-session without chat copy/paste (chat blocks secret values).
-- Shared cap for both diagnostic rings (audit + ucdrop). A raid boss's
-- 10-minute trace needs ~80k lines at raid wound density; the profile
-- key (/zsbt auditmax) lets a tester buy that depth without bloating
-- everyone's SavedVariables.
local function ringMax()
    local d = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics
    local n = d and tonumber(d.auditLogMax)
    if type(n) ~= "number" or n ~= n or n < 1000 then return 8000 end
    if n > 200000 then return 200000 end
    return math.floor(n)
end

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
    local line = ("%.3f %s"):format(t, tostring(msg))
    -- A secret string in any field poisons the whole formatted line; a
    -- tainted ring entry hard-errors any consumer that matches on it.
    if ZSBT.IsSafeString and not ZSBT.IsSafeString(line) then
        line = ("%.3f AUDSEC <audit line contained a secret value>"):format(t)
    end
    log[#log + 1] = line
    local cap = ringMax()
    if #log > cap then
        -- Block trim: table.remove(1) shifts the whole array per call —
        -- prohibitive at raid-boss cap sizes. One pass per overflow
        -- instead of one per line.
        local cut = math.floor(cap * 0.10) + 1
        for i = cut + 1, #log do log[i - cut] = log[i] end
        for i = #log - cut + 1, #log do log[i] = nil end
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
    local line = ("%.3f %s"):format(t, tostring(msg))
    -- A secret string in any field poisons the whole formatted line; a
    -- tainted ring entry hard-errors any consumer that matches on it.
    if ZSBT.IsSafeString and not ZSBT.IsSafeString(line) then
        line = ("%.3f AUDSEC <audit line contained a secret value>"):format(t)
    end
    log[#log + 1] = line
    local cap = ringMax()
    if #log > cap then
        -- Same block trim as FileLog: per-line table.remove(1) shifts
        -- the whole array — prohibitive at raid-boss cap sizes.
        local cut = math.floor(cap * 0.10) + 1
        for i = cut + 1, #log do log[i - cut] = log[i] end
        for i = #log - cut + 1, #log do log[i] = nil end
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
    -- Binding identity for learner evidence: which attribution source owns
    -- this claim. dot:/cast: split on the periodic flag; pet and generic
    -- get their own lanes so fidelity is scored per binding, not per spell.
    local bind = "generic"
    if src == "pet" then
        bind = "pet:" .. audSafe(sid)
    elseif src == "auto" then
        bind = "auto"
    elseif sid ~= nil then
        -- Channel claims get their own lane: a live channel claiming
        -- tick-rate wounds is *expected* physics, while a direct cast
        -- claiming them would be an honesty violation.
        if p.channelClaim == true then
            bind = "chan:" .. audSafe(sid)
        elseif p.procClaim == true then
            bind = "proc:" .. audSafe(sid)
        else
            bind = (p.isPeriodic == true) and ("dot:" .. audSafe(sid)) or ("cast:" .. audSafe(sid))
        end
    end
    ZB:Audit(("AUD ht=%.3f %s sid=%s name=%s school=%s crit=%s amt=%s src=%s bind=%s pe=%s tgt=%s pid=%s tid=%s"):format(
        tonumber(p.timestamp) or 0, eventType, audSafe(sid), audSafe(name),
        audSafe(p.schoolMask), tostring(p.isCrit == true), amtStr, src, bind,
        audSafe(p.petEvidence), audSafe(p.targetName), audSafe(p.rawPipeId), audSafe(p.traceId)))
end

-- TESTING flag (outgoing.damage.arbitrateGenerics): under v2 source mode
-- an unattributed candidate may queue for line arbitration instead of
-- dying at the contested gate. Foreign wounds still lose at flush —
-- fline veto, or the fnear stolen-line release — while own wounds get a
-- chance to claim their own line. v1 has no foreign evidence to arbitrate
-- against, so the flag does nothing without _srcMode.
local function arbitrateGenericsEnabled()
    if ZB._srcMode ~= true then return false end
    local prof = ZSBT.db and ZSBT.db.profile
    local d = prof and prof.outgoing and prof.outgoing.damage
    return d == nil or d.arbitrateGenerics ~= false
end

-- Returns true when the caller should emit immediately; false when the
-- module took ownership (queued for deferred veto, or vetoed).
function ZB:OfferOutgoing(payload)
    if not ZB._trusted or ZB._vetoDisabled then return true end
    local tHit = payload and payload.timestamp
    if type(tHit) ~= "number" then return true end
    if vetoDisabledNow() then return true end

    if candidateTier(payload) == 2 then
        -- Contested target: the collector detected impossible hit
        -- cadence (a second attacker on our target). Unattributed
        -- candidates from EVERY emit path — off-target nameplates,
        -- school-mismatch splits, physical bypass — are refused here so
        -- none can queue and steal a filtered line. Tier-1 (sid-bearing)
        -- candidates are unaffected. Not a veto rejection.
        local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
        local tNow = GetTime and GetTime() or 0
        local gateLive = (ec and type(ec._autoContestUntil) == "number" and tNow < ec._autoContestUntil) or false
        local why = gateLive and "contested" or nil
        if not gateLive and IsInInstance and ZB._srcMode ~= true then
            -- In instances another attacker is guaranteed: unattributed
            -- candidates from any path can never be proven ours. v2 source
            -- mode is exempt — foreign lines veto co-attacker wounds at
            -- flush, so generics may queue for arbitration.
            local okI, inInst = pcall(IsInInstance)
            if okI and inInst == true then
                gateLive = true
                why = "instance"
            end
        end
        if gateLive then
            if arbitrateGenericsEnabled() then
                -- TESTING: the candidate queues for arbitration anyway;
                -- AUDPASS marks suppressions that now reach the queue so
                -- the audit can measure how many generics arbitration
                -- recovers versus vetoes.
                ZB:Audit(("AUDPASS ht=%.3f school=%s crit=%s src=%s why=%s"):format(
                    tonumber(tHit) or 0, audSafe(payload.schoolMask), tostring(payload.isCrit == true),
                    tostring(payload._petRoute == true and "pet" or "generic"), why))
            else
                ZB:Audit(("AUDSUPP ht=%.3f school=%s crit=%s src=%s why=%s"):format(
                    tonumber(tHit) or 0, audSafe(payload.schoolMask), tostring(payload.isCrit == true),
                    tostring(payload._petRoute == true and "pet" or "generic"), why))
                return false
            end
        end
    end

    -- Fast path: the line is already buffered (CLM arrived first).
    -- Restricted to rank 1-2 evidence (own cast/swing, pet cast/melee) —
    -- school+window pet guesses and unattributed generics must defer
    -- into the sorted batch so they cannot grab a line a proven
    -- candidate arriving moments later will need.
    -- An auto-attack claim may ONLY be confirmed by a melee/ranged line —
    -- it must not steal a spell line (pet spells produce lines constantly).
    if candidateTier(payload) == 1 and claimOrder(payload) <= 2 then
        local fastKind, fastIdx = takeCandidateLine(tHit, VETO_WINDOW, payload)
        if fastKind and foreignDamageNearer(tHit, fastIdx) then
            -- Borrowed line: a foreign damage line sits strictly nearer
            -- this wound than the own line it grabbed. Release the line
            -- and let the deferred pass re-judge — if the hit is really
            -- ours, its own line lands by flush at ~0ms and nothing
            -- foreign can sit strictly nearer than that.
            ZB._lines[fastIdx].consumed = false
            fastKind = nil
            ZB:Audit(("AUDREL ht=%.3f tier=1 sid=%s src=fnear"):format(
                tonumber(tHit) or 0, audSafe(payload.spellId or payload.petSpellId)))
        end
        if fastKind then
            if ZB._srcMode == true and fastKind == "direct"
                and payload._petRoute == true then
                -- Same nearest-line rule as the deferred flush: a MINE
                -- line winning means the pet guess mislabeled an own
                -- event — strip to generic outgoing, not named pet.
                payload._petRoute = nil
                payload.petSpellId = nil
                payload.petEvidence = nil
                payload._petSidLearn = nil
                ZB:FileLog(("PET_ROUTE_DIRECT ht=%.3f fast=1"):format(
                    tonumber(tHit) or 0))
            end
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
        ZB._flushAt = tNow + deferSec()
        C_Timer.After(deferSec(), function()
            local _perf = ZSBT.Perf
            local _pt0 = _perf and _perf.on and _perf.t()
            flushPending()
            if _pt0 then _perf:done("zb.flush", _pt0) end
        end)
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
    ZB._frame = (ZSBT.Perf and ZSBT.Perf.frame or CreateFrame)("ZB")
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
            -- Probe: is the KString actually readable? If safe, spell names
            -- in tick lines are a non-secret attribution channel. First 5
            -- events + every 500th after — the FileLog ring evicts early
            -- records in long sessions.
            -- Probe: is the KString actually readable? If safe, spell names
            -- in tick lines are a non-secret attribution channel. Persisted
            -- to profile (survives logout) + rings — the audit ring on
            -- Forever proved FileLog gating alone can hide results.
            local pn = (ZB._clmsgProbeN or 0) + 1
            ZB._clmsgProbeN = pn
            local profP = ZSBT.db and ZSBT.db.profile
            if profP and pn <= 5 then
                local safe = ZSBT.IsSafeString and ZSBT.IsSafeString(a1) or false
                local sample = (safe and type(a1) == "string") and a1:sub(1, 60) or "?"
                profP._clmsgProbe = ("n=%d type=%s safe=%s txt=%s")
                    :format(pn, type(a1), tostring(safe), tostring(sample))
                profP._clmsgProbeN = pn
            end
            local tN = GetTime and GetTime() or 0
            if pn <= 5 or (tN - (ZB._clmsgProbeT or 0)) > 60 then
                ZB._clmsgProbeT = tN
                local safe = ZSBT.IsSafeString and ZSBT.IsSafeString(a1) or false
                local sample = (safe and type(a1) == "string") and a1:sub(1, 60) or "?"
                ZB:FileLog(("CLMSG_PROBE n=%d type=%s safe=%s txt=%s")
                    :format(pn, type(a1), tostring(safe), tostring(sample)))
                ZB:Audit(("CLMSG_PROBE n=%d type=%s safe=%s txt=%s")
                    :format(pn, type(a1), tostring(safe), tostring(sample)))
            end
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
    C_Timer.NewTicker(1, function()
        local _perf = ZSBT.Perf
        local _pt0 = _perf and _perf.on and _perf.t()
        ZB:Tick()
        if _pt0 then _perf:done("zb.tick", _pt0) end
    end)
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
