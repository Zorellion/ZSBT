------------------------------------------------------------------------
-- Zore's Combat Text - Combat-Log Line Buffer
-- COMBAT_LOG_MESSAGE delivers (text, r, g, b, order). The text is a
-- sealed KString and is NEVER read — only the line colour is used,
-- matched against the palette the "ZCT" filter wrote at logout.
--
-- A classified line is the attribution signal CLEU used to provide:
-- the filter only passes player+pet sources, so a damage-kind line near
-- a health delta proves the hit was yours.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
ZSBT.ZCT = ZSBT.ZCT or {}
local ZCT = ZSBT.ZCT

ZCT = ZCT or {}
ZCT.LogLines = ZCT.LogLines or {}
local Lines = ZCT.LogLines

local KIND_COLORS = ZCT.KIND_COLORS
local COLOR_TOLERANCE = 0.02
local LINE_KEEP_SEC = 2.5
local LINE_MAX = 96
local SIGNAL_WINDOW = 4.0

Lines._lines = Lines._lines or {}

local function isSafeChannel(v)
    return type(v) == "number" and (not ZCT.IsSafeNumber or ZCT.IsSafeNumber(v))
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

-- Record one COMBAT_LOG_MESSAGE line. Only palette-matching lines are
-- stored, so the buffer stays tiny when the signal isn't active.
Lines.total = Lines.total or 0       -- COMBAT_LOG_MESSAGE events received
Lines.classified = Lines.classified or 0
function Lines:RecordLine(r, g, b)
    self.total = self.total + 1
    self.lastAt = GetTime()
    if not (isSafeChannel(r) and isSafeChannel(g) and isSafeChannel(b)) then
        return
    end
    local kind = classifyColor(r, g, b)
    if not kind then
        -- Unmatched colour: a line we don't classify (or a palette drift).
        if ZCT.Dbg and ZCT.Dbg:Enabled("lines") then
            ZCT.Dbg:Trace("lines", "UNCLASSIFIED rgb=%.3f,%.3f,%.3f", r, g, b)
        end
        return
    end
    self.classified = self.classified + 1

    local t = GetTime()
    local lines = self._lines
    -- Lines are append-ordered by time; trim expired from the front.
    while #lines > 0 and t - lines[1].at > LINE_KEEP_SEC do
        table.remove(lines, 1)
    end
    if #lines >= LINE_MAX then
        table.remove(lines, 1)
    end
    lines[#lines + 1] = { at = t, kind = kind, consumed = false }

    -- Utility kinds aren't consumed by hit pairing; they become scroll
    -- events of their own (filter dest part = happened to you/pet).
    if ZCT.UTILITY_LINE_KINDS and ZCT.UTILITY_LINE_KINDS[kind]
        and ZCT.Outgoing
        and ZCT.Outgoing.HandleUtilityLine then
        ZCT.Outgoing:HandleUtilityLine(kind, r, g, b)
    end

    if ZCT.Dbg and ZCT.Dbg:Enabled("lines") then
        ZCT.Dbg:Trace("lines", "kind=%s rgb=%.3f,%.3f,%.3f", kind, r, g, b)
    end
end

-- Kind of the closest recorded line to tHit within window, or nil.
function Lines:ClosestKind(tHit, window)
    local best, bestDt
    for i = 1, #self._lines do
        local l = self._lines[i]
        local dt = math.abs(l.at - tHit)
        if dt <= window and (bestDt == nil or dt < bestDt) then
            best, bestDt = l.kind, dt
        end
    end
    return best
end

local DAMAGE_KINDS = ZCT.DAMAGE_LINE_KINDS
local HEAL_KINDS = ZCT.HEAL_LINE_KINDS
local MISS_KINDS = ZCT.MISS_LINE_KINDS

-- Generic: is there an unconsumed line of `kindSet` near tHit?
local function hasLineNear(tHit, window, kindSet, consume)
    local best, bestDt
    for i = 1, #self._lines do
        local l = self._lines[i]
        if kindSet[l.kind] and (consume or not l.consumed) then
            local dt = math.abs(l.at - tHit)
            if dt <= window and (bestDt == nil or dt < bestDt) then
                best, bestDt = i, dt
            end
        end
    end
    if best and consume then
        self._lines[best].consumed = true
        return true
    end
    return best ~= nil
end

-- Non-consuming checks.
function Lines:HasDamageLineNear(tHit, window)
    return hasLineNear(tHit, window, DAMAGE_KINDS, false)
end
function Lines:HasHealLineNear(tHit, window)
    return hasLineNear(tHit, window, HEAL_KINDS, false)
end
function Lines:HasMissLineNear(tHit, window)
    return hasLineNear(tHit, window, MISS_KINDS, false)
end

-- Consuming check: exactly one hit per line. In group content a raid
-- member's hit produces a health delta but NO palette line (the filter
-- only passes player+pet sources) — pairing hits to unconsumed lines
-- separates yours from theirs.
function Lines:TakeDamageLine(tHit, window)
    return hasLineNear(tHit, window, DAMAGE_KINDS, true) == true
end
function Lines:TakeHealLine(tHit, window)
    return hasLineNear(tHit, window, HEAL_KINDS, true) == true
end
function Lines:TakeMissLine(tHit, window)
    return hasLineNear(tHit, window, MISS_KINDS, true) == true
end

-- Consuming check restricted to a kind set; returns the consumed kind
-- (for periodic/direct styling) or nil.
function Lines:TakeClassifiedLine(tHit, window, kindSet)
    local best, bestDt
    for i = 1, #self._lines do
        local l = self._lines[i]
        if not l.consumed and kindSet[l.kind] then
            local dt = math.abs(l.at - tHit)
            if dt <= window and (bestDt == nil or dt < bestDt) then
                best, bestDt = i, dt
            end
        end
    end
    if best then
        self._lines[best].consumed = true
        return self._lines[best].kind, self._lines[best]
    end
    return nil
end

-- Kind of the line consumed by a hit, or nil (for periodic/direct styling).
function Lines:TakeAnyLine(tHit, window)
    local best, bestDt
    for i = 1, #self._lines do
        local l = self._lines[i]
        if not l.consumed then
            local dt = math.abs(l.at - tHit)
            if dt <= window and (bestDt == nil or dt < bestDt) then
                best, bestDt = i, dt
            end
        end
    end
    if best then
        self._lines[best].consumed = true
        return self._lines[best].kind
    end
    return nil
end

-- True when any palette line was seen recently — i.e. the filter is
-- installed and active, so line-based decisions are meaningful.
function Lines:SignalSeen()
    local t = GetTime()
    for i = #self._lines, 1, -1 do
        if t - self._lines[i].at <= SIGNAL_WINDOW then
            return true
        end
    end
    return false
end

-- Count of currently buffered UNCLAIMED lines (diagnostics). Trims
-- expired entries so a dead feed reads as 0; consumed lines don't count
-- — they can't be claimed again.
function Lines:Count()
    local lines, t = self._lines, GetTime()
    while #lines > 0 and t - lines[1].at > LINE_KEEP_SEC do
        table.remove(lines, 1)
    end
    local n = 0
    for i = 1, #lines do
        if not lines[i].consumed then n = n + 1 end
    end
    return n
end
