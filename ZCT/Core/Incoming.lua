------------------------------------------------------------------------
-- Zore's Combat Text - Incoming Detection (player + pet as victims)
-- Sources (all probe-verified on Forever):
--   COMBAT_TEXT_UPDATE(typeToken) + C_CombatText.GetCurrentEventInfo()
--     -> self damage/heal/miss text; payload slots are ALL secret on
--        Forever, so amount passes through raw, never inspected.
--   UNIT_COMBAT("player"|"pet", action, descriptor, amount, school)
--     -> corroborating feed; action WOUND/HEAL/DODGE/MISS/..., descriptor
--        may contain "CRITICAL", amount secret, school safe bitmask.
-- Dedup (trace-verified): every hit on the player arrives as CT first and
-- UNIT_COMBAT("player") ~0.23s later, with jitter past any tight window.
-- UNIT_COMBAT is authoritative (it has school + crit). CT is a FALLBACK:
-- it waits CT_FALLBACK_DELAY and only emits if no UNIT_COMBAT of the same
-- class arrived around it.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
ZSBT.ZCT = ZSBT.ZCT or {}
local ZCT = ZSBT.ZCT

ZCT = ZCT or {}
ZCT.Incoming = ZCT.Incoming or {}
local Incoming = ZCT.Incoming

Incoming._enabled = false

local CT_FALLBACK_DELAY = 0.6   -- wait this long for UNIT_COMBAT
local CT_LEAD = 0.3             -- UNIT_COMBAT this far BEFORE CT also counts
local UNIT_DEDUP_WINDOW = 0.15

-- Last COMBAT_TEXT_UPDATE time per coarse class. CT is PLAYER-only
-- self text, so it only ever dedups against UNIT_COMBAT("player").
Incoming._lastCt = {}
-- Last UNIT_COMBAT("player") emit time per class (symmetric dedup vs CT).
-- Pet hits are never in CT, so they must not stamp or consult this.
Incoming._lastUcClass = {}

local function trace(fmt, ...)
    if ZCT.Dbg and ZCT.Dbg:Enabled("incoming") then
        ZCT.Dbg:Trace("incoming", fmt, ...)
    end
end
-- Last UNIT_COMBAT emit signature+time (double-delivery guard).
Incoming._lastUcSig = nil
Incoming._lastUcAt = 0

------------------------------------------------------------------------
-- COMBAT_TEXT_UPDATE type tokens -> class
------------------------------------------------------------------------
local CT_DAMAGE = {
    DAMAGE = true, SPELL_DAMAGE = true,
    PERIODIC_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true,
    DAMAGE_SHIELD = true, SPELL_DAMAGE_SHIELD = true,
}
local CT_HEAL = {
    HEAL = true, SPELL_HEAL = true,
    PERIODIC_HEAL = true, SPELL_PERIODIC_HEAL = true,
}
local CT_MISS = {
    MISS = true, DODGE = true, PARRY = true, BLOCK = true,
    RESIST = true, ABSORB = true, EVADE = true, IMMUNE = true,
    REFLECT = true, DEFLECT = true,
    SPELL_MISS = true, SPELL_MISSED = true,
    SPELL_PERIODIC_MISS = true, SPELL_PERIODIC_MISSED = true,
    SWING_MISS = true, SWING_MISSED = true,
    RANGE_MISS = true, RANGE_MISSED = true,
}

local function ctClass(token)
    if type(token) ~= "string" then return nil end
    if CT_DAMAGE[token] then return "damage" end
    if CT_HEAL[token] then return "heal" end
    if CT_MISS[token] then return "miss" end
    -- Fallback: substring match for *_CRIT / PERIODIC variants not listed.
    local u = token:upper()
    if u:find("DAMAGE", 1, true) then return "damage" end
    if u:find("HEAL", 1, true) then return "heal" end
    if u:find("MISS") or u:find("DODGE") or u:find("PARRY")
        or u:find("BLOCK") or u:find("RESIST") or u:find("ABSORB")
        or u:find("EVADE") or u:find("IMMUNE") or u:find("REFLECT")
        or u:find("DEFLECT") then
        return "miss"
    end
    return nil
end

local function isCritToken(token)
    return type(token) == "string" and token:upper():find("CRIT", 1, true) ~= nil
end
local function isPeriodicToken(token)
    return type(token) == "string" and token:upper():find("PERIODIC", 1, true) ~= nil
end

-- Pick the amount out of GetCurrentEventInfo returns. All values may be
-- secret; type() still works on secrets. Prefer the first numeric slot;
-- fall back to first non-nil (rare string payloads still render raw).
local function pickAmount(a, b, c, d)
    for _, v in ipairs({ a, b, c, d }) do
        if type(v) == "number" then return v end
    end
    return a -- may be nil or a secret string; SetText handles raw
end

function Incoming:HandleCombatText(token)
    if not self._enabled then return end
    local class = ctClass(token)
    if not class then return end
    -- CT heal tokens can't distinguish self-heals from received heals;
    -- the UNIT_COMBAT+line pairing in Outgoing owns all heal display.
    if class == "heal" then return end

    local now = GetTime()
    local amount
    if C_CombatText and C_CombatText.GetCurrentEventInfo then
        local ok, a, b, c, d = pcall(C_CombatText.GetCurrentEventInfo)
        if ok then amount = pickAmount(a, b, c, d) end
    elseif GetCurrentCombatTextEventInfo then
        local ok, a, b, c, d = pcall(GetCurrentCombatTextEventInfo)
        if ok then amount = pickAmount(a, b, c, d) end
    end

    -- Zero amounts are absorb/immune residue, not real hits — drop them
    -- when readable (secret zeros can't be compared and pass through).
    if ZCT.IsSafeNumber(amount) and amount <= 0 then return end

    -- Payload must be read NOW (GetCurrentEventInfo is only valid inside
    -- this event); the raw value is held, never inspected.
    local crit, periodic = isCritToken(token), isPeriodicToken(token)
    C_Timer.After(CT_FALLBACK_DELAY, function()
        local ucAt = self._lastUcClass[class]
        if ucAt and ucAt >= now - CT_LEAD then
            trace("CT %s skip: UC covered it (%.3fs)", token, ucAt - now)
            return
        end
        ZCT.Normalize:Emit(class, {
            direction = "in",
            amount = amount,
            amountIsSecret = type(amount) ~= "nil" and not ZCT.IsSafeNumber(amount),
            crit = crit,
            periodic = periodic,
            miss = (class == "miss"),
            action = token,
            unit = "player",
        })
        trace("CT %s emit (no UC) crit=%s periodic=%s", token,
            tostring(crit), tostring(periodic))
    end)
end

------------------------------------------------------------------------
-- UNIT_COMBAT corroboration / fallback
------------------------------------------------------------------------
local UC_CLASS = {
    WOUND = "damage",
    HEAL = "heal",
    DODGE = "miss", MISS = "miss", PARRY = "miss", BLOCK = "miss",
    RESIST = "miss", ABSORB = "miss", EVADE = "miss", IMMUNE = "miss",
    REFLECT = "miss", DEFLECT = "miss",
}

function Incoming:HandleUnitCombat(unit, action, descriptor, amount, school)
    if not self._enabled then return end
    if unit ~= "player" and unit ~= "pet" then return end
    local class = UC_CLASS[action]
    if not class then return end
    -- Heals on player/pet are ambiguous (self-cast vs received) — Outgoing
    -- owns them: palette line => outgoing, no line => incoming fallback.
    if class == "heal" then return end
    -- Absorbed hits arrive as WOUND with "ABSORB" in the descriptor (this
    -- client fires no separate UC ABSORB action). Reclassify as miss so
    -- the amount — 0 on full absorbs — never displays as damage; the
    -- absorb text/miss-type filters own it instead.
    if class == "damage" and type(descriptor) == "string"
        and descriptor:upper():find("ABSORB", 1, true) then
        class = "miss"
        action = "ABSORB"
    end
    if ZCT.IsSafeNumber(amount) and amount == 0 then return end

    local now = GetTime()

    -- Double-delivery guard: same unit+action within the window = dup.
    local sig = unit .. "|" .. action
    if sig == self._lastUcSig and (now - self._lastUcAt) <= UNIT_DEDUP_WINDOW then
        trace("UC %s %s skip: double delivery %.3fs", unit, action, now - self._lastUcAt)
        return
    end
    self._lastUcSig = sig
    self._lastUcAt = now

    -- Authoritative for the player: stamp so the pending CT copy of this
    -- hit stands down (CT never carries pet hits).
    if unit == "player" then
        self._lastUcClass[class] = now
    end

    local crit = false
    if type(descriptor) == "string" then
        local u = descriptor:upper()
        crit = u:find("CRIT", 1, true) ~= nil
    end

    ZCT.Normalize:Emit(class, {
        direction = "in",
        amount = amount,
        amountIsSecret = type(amount) ~= "nil" and not ZCT.IsSafeNumber(amount),
        crit = crit,
        school = ZCT.IsSafeNumber(school) and school or nil,
        pet = (unit == "pet"),
        action = action,
        unit = unit,
        flagText = (type(descriptor) == "string" and descriptor ~= "")
            and descriptor or nil,
    })

    if ZCT.Dbg and ZCT.Dbg:Enabled("incoming") then
        ZCT.Dbg:Trace("incoming", "UC %s %s crit=%s school=%s amt=%s",
            unit, action, tostring(crit), tostring(school),
            ZCT.IsSafeNumber(amount) and tostring(amount) or "<secret>")
    end
end

function Incoming:Enable()
    if self._enabled then return end
    self._enabled = true
end

function Incoming:Disable()
    self._enabled = false
end
