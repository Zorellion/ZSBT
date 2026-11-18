------------------------------------------------------------------------
-- Zore's Combat Text - Outgoing Detection (player + pet as sources)
--
-- Attribution model (probe-verified on Forever):
--   COMBAT_LOG_MESSAGE palette lines prove a player/pet-source event
--   happened (the ZCT filter only passes those sources) but carry no
--   amount. UNIT_COMBAT on enemy units carries the secret amount,
--   school, and crit flag but no source.
--
-- Pairing: every plausible UNIT_COMBAT hit is buffered as a candidate;
-- ~0.18s later a matching unconsumed palette line is claimed and the
-- candidate is emitted with its raw secret amount. Candidates that find
-- no line are dropped (damage done by OTHER players on the same mobs
-- produces UNIT_COMBAT but no palette line — the filter excludes them).
--
-- Heals are special: UNIT_COMBAT("player"|"pet","HEAL") cannot distinguish
-- self-cast heals from heals received. A heal-kind line => outgoing;
-- no line => incoming heal fallback (someone else healed us).
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
ZSBT.ZCT = ZSBT.ZCT or {}
local ZCT = ZSBT.ZCT

ZCT = ZCT or {}
ZCT.Outgoing = ZCT.Outgoing or {}
local Out = ZCT.Outgoing

Out._enabled = false
Out._pending = Out._pending or 0
-- Pipeline counters for /zct status (cheap increments, no allocation).
Out.stats = Out.stats or { uc = 0, dup = 0, cap = 0, cand = 0, paired = 0, dropped = 0, gated = 0 }

------------------------------------------------------------------------
-- Contention-adaptive strictness.
-- Foreign UNIT_COMBAT (another player swinging at the same nameplate)
-- is invisible until pairing time — but it announces itself as
-- candidates that find NO palette line. Track the decayed drop ratio:
-- high contention => the pairing is ambiguous => demand the same proof
-- _Gate requires in group strict mode. Solo baseline runs ~1% drops;
-- a stranger on your target pushes it past the threshold and back down
-- when they leave. No context detection needed — the data decides.
------------------------------------------------------------------------
local CONTENTION_WINDOW = 10.0  -- seconds of decayed history
local CONTENTION_ON = 0.50      -- enter strict above this drop ratio
local CONTENTION_OFF = 0.30     -- exit below (hysteresis)

Out._cCand = 0      -- decayed candidate count
Out._cDrop = 0      -- decayed no-line count (enemy-side only)
Out._cAt = nil
Out._contended = false

local function contentionDecay(self)
    local t = GetTime()
    local at = self._cAt or t
    local dt = t - at
    if dt > 0 then
        local keep = math.max(0, 1 - dt / CONTENTION_WINDOW)
        self._cCand = self._cCand * keep
        self._cDrop = self._cDrop * keep
        self._cAt = t
    end
end

function Out:_NoteCandidate()
    contentionDecay(self)
    self._cCand = self._cCand + 1
end

function Out:_NoteDrop()
    contentionDecay(self)
    self._cDrop = self._cDrop + 1
end

function Out:_Contended()
    contentionDecay(self)
    if self._cCand < 3 then return self._contended end  -- too little data
    local ratio = self._cDrop / self._cCand
    if self._contended then
        if ratio < CONTENTION_OFF then self._contended = false end
    elseif ratio > CONTENTION_ON then
        self._contended = true
        if ZCT.Dbg and ZCT.Dbg:Enabled("outgoing") then
            ZCT.Dbg:Info("outgoing", "contention %.0f%% -> strict pairing",
                ratio * 100)
        end
    end
    return self._contended
end

local PAIR_WINDOW = 0.55   -- line must be within this of the UNIT_COMBAT
local STRICT_PAIR_WINDOW = 0.10 -- strict mode: line+UC are same-event (~1 frame)
local CAND_TTL = 0.45      -- candidate waits this long for its palette line
local CAST_TTL = 1.5       -- pending cast usable for spellId for this long
local DOT_TTL = 45.0       -- casts kept this long for periodic aura proof
local MAX_PENDING = 1024   -- cap in-flight pair timers (raid-scale bursts)

------------------------------------------------------------------------
-- Unit classification. "targettarget" is deliberately EXCLUDED from the
-- enemy set: it is the mob's target — usually the player or pet — so its
-- WOUND events are incoming damage, not outgoing candidates.
------------------------------------------------------------------------
local ENEMY_EXACT = {
    target = true, softenemy = true, focus = true, mouseover = true,
}
local function isEnemyUnit(unit)
    if type(unit) ~= "string" then return false end
    if ENEMY_EXACT[unit] then return true end
    return unit:match("^nameplate%d+$") ~= nil
        or unit:match("^arena%d+$") ~= nil
        or unit:match("^boss%d+$") ~= nil
end

-- One mob is often visible through several tokens at once (nameplate1,
-- target, softenemy, focus, mouseover, boss1), and UNIT_COMBAT fires for
-- EACH of them for the same hit. Collapse to one canonical token:
--   * nameplateN is canonical when the mob has a nameplate
--   * any other token is dropped if the mob has a nameplate (its
--     nameplate token reports the hit)
--   * with no nameplate, the highest-priority alias wins: an alias is
--     dropped if a higher-priority token refers to the same unit
local ALIAS_PRIORITY = { "target", "focus", "softenemy", "mouseover" }

-- UnitIsUnit returns a SECRET boolean in instances — never boolean-test
-- it. GUIDs are identifiers, not secret values, so compare those; the
-- whole thing stays pcall'd in case a client secrets GUIDs too.
local function sameUnit(a, b)
    local ok, res = pcall(function()
        local ga, gb = UnitGUID(a), UnitGUID(b)
        return ga ~= nil and ga == gb
    end)
    return ok and res == true
end

local function hasNameplate(unit)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return false end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    return ok and plate ~= nil
end

local function isDuplicateToken(unit)
    if unit:match("^nameplate%d+$") then return false end
    if hasNameplate(unit) then return true end
    for _, alias in ipairs(ALIAS_PRIORITY) do
        if alias == unit then return false end
        if sameUnit(unit, alias) then return true end
    end
    return false
end

local function isAllyUnit(unit)
    if type(unit) ~= "string" then return false end
    return unit == "player" or unit == "pet"
        or unit:match("^party%d+$") ~= nil
        or unit:match("^raid%d+$") ~= nil
end

-- Heal targets that mean "healing received": player, pet, and
-- targettarget when it resolves to either (it's the mob's target —
-- usually us). Returns "player"|"pet"|nil.
local function selfHealUnit(unit)
    if unit == "player" or unit == "pet" then return unit end
    if unit == "targettarget" then
        -- UnitIsUnit is secret in instances; sameUnit uses GUIDs.
        if sameUnit(unit, "player") then return "player" end
        if sameUnit(unit, "pet") then return "pet" end
    end
    return nil
end

------------------------------------------------------------------------
-- Pending casts (UNIT_SPELLCAST_SUCCEEDED) — spellId is a safe number,
-- stored for icon/name resolution in later phases.
------------------------------------------------------------------------
Out._casts = Out._casts or {}

function Out:HandleSpellCast(unit, castGUID, spellId)
    if not self._enabled then return end
    if unit ~= "player" and unit ~= "pet" then return end
    if not ZCT.IsSafeNumber(spellId) then return end
    local casts = self._casts
    local now = GetTime()
    -- Retain casts for DOT_TTL: attributeCast still only credits hits
    -- within CAST_TTL, but periodic proof needs the longer memory.
    while #casts > 0 and now - casts[1].at > DOT_TTL do
        table.remove(casts, 1)
    end
    if #casts >= 32 then table.remove(casts, 1) end
    casts[#casts + 1] = {
        spellId = spellId,
        pet = (unit == "pet"),
        at = now,
    }
end

------------------------------------------------------------------------
-- Utility lines (LogLines -> here): the filter's destination part means
-- the event happened TO us/our pet — enemy interrupt, purge, steal,
-- aura break — except PARTY_KILL, which is our kill credit. The line
-- carries no amount/unit (KString text is never read), so the scroll
-- text is the kind label, upgraded to a spell name when exactly one
-- distinct recent cast could have caused it (self-cleanse, pet break).
------------------------------------------------------------------------
local UTILITY_DIR = { kill = "out" }   -- kill credit is ours; rest hit us

-- Only these line kinds can be caused by the player's own cast: the
-- filter's destination part means the event happened TO us/our pet, so
-- for enemy actions (interrupt, purge, steal, aura break, extra attack)
-- the real spell belongs to the enemy and naming it from OUR casts is
-- always a guess. Cleanse is the exception — you cleanse your own
-- debuff. Everything else shows its kind label.
local UTILITY_NAMEABLE = { cleanse = true }

function Out:HandleUtilityLine(kind, r, g, b)
    if not self._enabled then return end
    -- Interrupts never scroll: the Notifications interrupt alerts own
    -- them (both directions). The log line can't tell "you interrupted"
    -- from "you were interrupted" anyway — one color, no unit info.
    if kind == "interrupt" then return end

    -- Same distinct-cast window as attributeCast, minus the kind gate:
    -- exactly one candidate names the event; anything else stays generic.
    local spellId, pet
    if UTILITY_NAMEABLE[kind] then
        local casts = self._casts
        local now = GetTime()
        local ids = nil
        for i = #casts, 1, -1 do
            local k = casts[i]
            if now - k.at > CAST_TTL then break end
            if k.at <= now and ZCT.IsSafeNumber(k.spellId) then
                ids = ids or {}
                local found = false
                for _, e in ipairs(ids) do
                    if e.id == k.spellId then found = true break end
                end
                if not found then
                    ids[#ids + 1] = { id = k.spellId, pet = k.pet == true }
                end
            end
        end
        if ids and #ids == 1 then
            spellId, pet = ids[1].id, ids[1].pet
        end
    end

    ZCT.Normalize:Emit("utility", {
        direction = UTILITY_DIR[kind] or "in",
        lineKind = kind,
        spellId = spellId,
        pet = pet == true,
        rgb = (ZCT.IsSafeNumber(r) and ZCT.IsSafeNumber(g)
            and ZCT.IsSafeNumber(b)) and { r, g, b } or nil,
    })
end

-- Attribution: a hit is credited to a spell only when it is provable.
--   * line kind is a direct spell hit or heal (melee, ticks, shields are
--     never cast-driven at hit time)
--   * the distinct spellIds cast within CAST_TTL before the hit resolve
--     to exactly ONE — a single cast, repeats of one spell, or (when the
--     hit's school is known) exactly one candidate whose learned school
--     matches while every other candidate's school is known-different
--   * the hit's school agrees with the school learned for that spell;
--     a mismatch (proc / other source) rejects and re-learns
-- Anything else returns nil, and nil-spell hits are never merged.
local ATTRIB_KINDS = { direct = true, heal = true }
local spellSchool = {}

-- Returns spellId, isPet (the matched cast's caster) or nil.
local function attributeCast(c, kind)
    if not ATTRIB_KINDS[kind] then return nil end
    local casts = Out._casts
    local ids = nil   -- distinct {id, pet} casts inside the window
    for i = #casts, 1, -1 do
        local k = casts[i]
        if c.at - k.at > CAST_TTL then break end
        if k.at <= c.at and ZCT.IsSafeNumber(k.spellId) then
            ids = ids or {}
            local found = false
            for _, e in ipairs(ids) do
                if e.id == k.spellId then found = true break end
            end
            if not found then
                ids[#ids + 1] = { id = k.spellId, pet = k.pet == true }
            end
        end
    end
    if not ids or #ids == 0 then return nil end

    local id, pet
    if #ids == 1 then
        id, pet = ids[1].id, ids[1].pet
    elseif c.school then
        -- Weaved casts: disambiguate by school. Exactly one candidate may
        -- match; every other candidate must have a KNOWN different school
        -- (an unknown school could be the match, so it stays ambiguous).
        local match, ambiguous = nil, false
        for _, e in ipairs(ids) do
            local known = spellSchool[e.id]
            if known == nil then ambiguous = true break end
            if known == c.school then
                if match then ambiguous = true break end
                match = e
            end
        end
        if ambiguous or not match then return nil end
        id, pet = match.id, match.pet
    else
        return nil
    end

    if c.school then
        local known = spellSchool[id]
        if known == nil then
            spellSchool[id] = c.school
        elseif known ~= c.school then
            spellSchool[id] = nil
            return nil
        end
    end
    return id, pet
end

------------------------------------------------------------------------
-- Periodic proof (strict mode): a tick/hot hit can't be cast-attributed
-- at hit time, but the debuff it came from is still on the mob. Scan the
-- victim's harmful auras for a spellId we (or the pet) cast within
-- DOT_TTL — a match proves the tick is ours.
-- Returns true/false, or nil when the check can't run (no UnitAura,
-- secret spellIds) — callers treat nil as "can't disprove".
------------------------------------------------------------------------
local function provePeriodic(c)
    if not (UnitAura and type(c.unit) == "string") then return nil end
    local casts = Out._casts
    local now = c.at
    -- spellId -> pet, from casts inside DOT_TTL.
    local ids = {}
    for i = #casts, 1, -1 do
        local k = casts[i]
        if now - k.at > DOT_TTL then break end
        if k.at <= now and ZCT.IsSafeNumber(k.spellId) then
            ids[k.spellId] = k.pet == true
        end
    end
    if not next(ids) then return false end
    for i = 1, 40 do
        local ok, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14 =
            pcall(UnitAura, c.unit, i, "HARMFUL")
        if not ok or a1 == nil then break end
        -- spellId sits late in the return list; scan the tail args for a
        -- safe number that matches a recent cast (coincidence-proof).
        for _, v in ipairs({ a9, a10, a11, a12, a13, a14 }) do
            if ZCT.IsSafeNumber(v) and ids[v] ~= nil then
                return true, ids[v] == true
            end
        end
    end
    return false
end

------------------------------------------------------------------------
-- Strict-mode gate (Context:Strict()): a palette line proves an event
-- was ours, but in a group the UNIT_COMBAT candidate claiming it may be
-- a foreign swing. Decide.lua's policy table sets the proof level per
-- kind family — unattributed kinds are dropped rather than risk showing
-- someone else's amount. The consumed line is ours either way; nothing
-- wrong is ever displayed, we just show less.
------------------------------------------------------------------------
local GATE_KINDS = { direct = "spells", heal = "spells",
    tick = "dots", hot = "dots",
    directMiss = "misses", tickMiss = "misses", meleeMiss = "misses",
    rangedMiss = "misses", shieldMiss = "misses" }

-- Strict determination shared by _Gate and _MatchLines: profile toggle,
-- legacy ZCTDB key, group/content context, or measured contention.
function Out:_Strict()
    local ctx = ZCT.Context
    local db = ZCT.GetDB and ZCT:GetDB() or nil
    -- strictOutgoingAlways lives in the ZSBT profile (ZSBTDB), so it
    -- follows DB profile swaps; ZCTDB is per-character only.
    local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
    return (g and g.strictOutgoingAlways == true)
        or (db and db.strictAlways == true)
        or (ctx and ctx.Strict and ctx:Strict()) or self:_Contended()
end

function Out:_Gate(c, kind)
    if not self:_Strict() then return true end
    local db = ZCT.GetDB and ZCT:GetDB() or nil
    local pol = (db and db.groupPolicy) or {}
    local family = GATE_KINDS[kind] or "auto"
    local mode = pol[family] or ({ spells = "strict", dots = "auto",
        misses = "allow", auto = "block" })[family]
    if mode == "allow" or mode == "off" then return true end
    if family == "auto" then return false end  -- "block"/default
    if family == "spells" then
        if mode ~= "strict" then return true end
        return attributeCast(c, kind) ~= nil
    end
    -- dots: "auto" tries aura proof, "block" refuses outright.
    if mode == "block" then return false end
    local ok = provePeriodic(c)
    if ok == nil then return true end  -- unverifiable: don't nuke coverage
    return ok == true
end

------------------------------------------------------------------------
-- Overheal suppression (incoming heals only)
-- ZSBT-style: HP at max before AND after the heal => pure overheal.
-- Needs SAFE UnitHealth values — in instances they are secret, nothing
-- reaches the ring, and the check fails open (heal still displays).
------------------------------------------------------------------------
Out._hp = {}
local HP_KEEP = 5.0
local HP_MAX_READINGS = 16
local HP_PRE_EPS = 0.10   -- readings older than this count as "before"

function Out:NoteHealth(unit)
    if unit ~= "player" and unit ~= "pet" then return end
    local hp = UnitHealth and UnitHealth(unit)
    local max = UnitHealthMax and UnitHealthMax(unit)
    if not (ZCT.IsSafeNumber(hp) and ZCT.IsSafeNumber(max) and max > 0) then
        return
    end
    local ring = self._hp[unit]
    if not ring then ring = {}; self._hp[unit] = ring end
    local t = GetTime()
    while #ring > 0 and t - ring[1].at > HP_KEEP do table.remove(ring, 1) end
    if #ring >= HP_MAX_READINGS then table.remove(ring, 1) end
    ring[#ring + 1] = { at = t, hp = hp, max = max }
end

-- True when HP was already at max before tHit and still is now — the
-- heal changed nothing. False whenever data is missing.
function Out:_WasFullHeal(unit, tHit)
    local ring = unit and self._hp[unit]
    if not ring then return false end
    local pre
    for i = #ring, 1, -1 do
        if ring[i].at <= tHit - HP_PRE_EPS then pre = ring[i]; break end
    end
    local post = ring[#ring]
    if not pre or not post then return false end
    return pre.hp >= pre.max and post.hp >= post.max
end

function Out:_HideOverheal()
    local db = ZCT.GetDB and ZCT:GetDB() or nil
    return not db or db.hideOverheal ~= false
end

------------------------------------------------------------------------
-- UNIT_COMBAT -> candidate buffer
------------------------------------------------------------------------
local UC_CLASS = {
    WOUND = "damage",
    HEAL  = "heal",
    DODGE = "miss", MISS = "miss", PARRY = "miss", BLOCK = "miss",
    RESIST = "miss", ABSORB = "miss", EVADE = "miss", IMMUNE = "miss",
    REFLECT = "miss", DEFLECT = "miss",
}

local LINE_SETS = {
    damage = ZCT.DAMAGE_LINE_KINDS,
    heal   = ZCT.HEAL_LINE_KINDS,
    miss   = ZCT.MISS_LINE_KINDS,
}

function Out:HandleUnitCombat(unit, action, descriptor, amount, school)
    if not self._enabled then return end
    local cls = UC_CLASS[action]
    if not cls then return end
    self.stats.uc = self.stats.uc + 1
    self.stats.lastUcAt = GetTime()

    local enemy, ally = isEnemyUnit(unit), isAllyUnit(unit)
    if cls == "heal" then
        -- Heals are only ours when they land on someone we could heal.
        -- Nameplate/arena/boss tokens are always hostile (mob self-heals
        -- and other players' healing would just steal our heal lines),
        -- but target/focus/mouseover can be FRIENDLY — check hostility.
        if not ally then
            local hostile = unit:match("^nameplate%d+$") ~= nil
                or unit:match("^arena%d+$") ~= nil
                or unit:match("^boss%d+$") ~= nil
                or unit == "softenemy"
            if not hostile and enemy then
                local okA, can = pcall(UnitCanAttack, "player", unit)
                hostile = okA and can == true
            end
            if hostile then return end
        end
    else
        -- damage/miss candidates only on enemy-ish units; player/pet/ally
        -- victims are Incoming's territory.
        if not enemy then return end
    end

    if enemy and isDuplicateToken(unit) then
        self.stats.dup = self.stats.dup + 1
        if ZCT.Dbg and ZCT.Dbg:GetLevel("outgoing") >= 5 then
            ZCT.Dbg:Verb("outgoing", "skip duplicate token %s %s", unit, cls)
        end
        return
    end

    if ZCT.IsSafeNumber(amount) and amount == 0 then return end

    local crit = false
    if type(descriptor) == "string" then
        local u = descriptor:upper()
        crit = u:find("CRIT", 1, true) ~= nil
    end

    local cand = {
        cls = cls,
        unit = unit,
        amount = amount,   -- raw: may be secret, never inspected
        school = ZCT.IsSafeNumber(school) and school or nil,
        crit = crit,
        action = action,
        flagText = (type(descriptor) == "string" and descriptor ~= "")
            and descriptor or nil,
        pet = (unit == "pet"),
        at = GetTime(),
    }

    -- Purge finished candidates, then buffer this one. Matching runs
    -- both ways (see _MatchLines): palette lines claim their nearest
    -- candidate and candidates claim their nearest line, so a foreign
    -- hit can only steal a line by being closer in time to it than our
    -- own UNIT_COMBAT — not merely by arriving first.
    local cands = self._cands
    local w = 1
    for i = 1, #cands do
        local c = cands[i]
        if not c.done then cands[w] = c; w = w + 1 end
    end
    for i = w, #cands do cands[i] = nil end
    self._pending = #cands

    if #cands >= MAX_PENDING then
        self.stats.cap = self.stats.cap + 1
        return
    end
    cand.done = false
    cands[#cands + 1] = cand
    self._pending = #cands
    self.stats.cand = self.stats.cand + 1
    if enemy then self:_NoteCandidate() end
    C_Timer.After(CAND_TTL, function()
        self:_Expire(cand)
    end)
    self:_MatchLines()
end

------------------------------------------------------------------------
-- Deferred pairing: closest-timestamp matching between UNIT_COMBAT
-- candidates and palette lines. Each line kind maps to exactly one
-- candidate class (the sets are disjoint), so a line only ever
-- competes for candidates of its own class.
------------------------------------------------------------------------
local CLS_FOR_KIND = {}
for cls, set in pairs(LINE_SETS) do
    for kind in pairs(set) do CLS_FOR_KIND[kind] = cls end
end

Out._cands = Out._cands or {}

-- Emit a proven pair. The caller has already consumed the line and
-- marked the candidate done.
function Out:_EmitPaired(c, kind)
    self.stats.paired = self.stats.paired + 1
    Out._starved = 0
    -- pet = SOURCE is the pet, and only when provable (attributed to
    -- a pet cast). c.pet would mean "target is the pet" — wrong here.
    local spellId, byPet = attributeCast(c, kind)
    -- Direction: a heal landing on player/pet (incl. targettarget
    -- resolving to either) is healing RECEIVED — Drain Life's leech,
    -- self-heals, received heals -> incoming, even when our own
    -- cast produced the palette line. Heals on other allies stay
    -- outgoing. Damage/miss are always outgoing.
    local selfUnit = c.cls == "heal" and selfHealUnit(c.unit) or nil
    local dir = selfUnit and "in" or "out"
    -- Incoming heal that changed nothing (HP already at max) is a
    -- pure overheal — suppress when health data is readable.
    local overheal = c.cls == "heal" and dir == "in"
        and self:_HideOverheal() and self:_WasFullHeal(selfUnit, c.at)
    if overheal then
        if ZCT.Dbg and ZCT.Dbg:Enabled("overheal") then
            ZCT.Dbg:Trace("overheal", "suppress heal unit=%s", tostring(c.unit))
        end
        return
    end
    -- Palette line proves player/pet source involvement.
    ZCT.Normalize:Emit(c.cls, {
        direction = dir,
        amount = c.amount,
        school = c.school,
        crit = c.crit,
        periodic = (kind == "tick" or kind == "hot"),
        lineKind = kind,
        spellId = spellId,
        -- Incoming heals: pet = the healed target. Outgoing: pet =
        -- proven cast source. Never c.pet ("target is pet" is only
        -- meaningful for incoming).
        pet = (dir == "in") and (selfUnit == "pet") or (byPet == true),
        action = c.action,
        flagText = c.flagText,
        unit = c.unit,
    })
    if ZCT.Dbg and ZCT.Dbg:Enabled("outgoing") then
        -- pet= is proven cast attribution only; casterMode re-routes
        -- unattributed melee later in Decide, so show that too.
        local db = ZCT.GetDB and ZCT:GetDB() or nil
        local cm = db and db.casterMode == true and spellId == nil
            and (kind == "melee" or kind == "meleeMiss")
        ZCT.Dbg:Trace("outgoing", "pair %s unit=%s kind=%s crit=%s spell=%s pet=%s cm=%s",
            c.cls, tostring(c.unit), tostring(kind), tostring(c.crit),
            tostring(spellId), tostring(byPet == true), tostring(cm == true))
    end
end

-- Match every unconsumed palette line to its nearest pending candidate.
-- Runs on both sides of the pairing: when a line is recorded (LogLines)
-- and when a candidate is buffered (HandleUnitCombat), so ordering
-- between COMBAT_LOG_MESSAGE and UNIT_COMBAT doesn't matter — a pair
-- forms as soon as both halves exist.
function Out:_MatchLines()
    local lines = ZCT.LogLines
    local lineBuf = lines and lines._lines
    local cands = self._cands
    if not lineBuf or #cands == 0 then return end
    -- In strict mode a legit pair is the SAME combat event seen twice
    -- (UNIT_COMBAT + its palette line, ~1 frame apart). A foreign
    -- candidate claiming the line always has a real time gap — so
    -- tighten the window: only near-simultaneous candidates may pair.
    local strict = self:_Strict()
    local window = strict and STRICT_PAIR_WINDOW or PAIR_WINDOW
    -- Active-candidate count per class: lines whose class has no
    -- pending candidates skip the inner scan entirely (the common
    -- case in raid-scale foreign-candidate floods).
    local byCls = { damage = 0, heal = 0, miss = 0 }
    for ci = 1, #cands do
        local c = cands[ci]
        if not c.done and byCls[c.cls] ~= nil then
            byCls[c.cls] = byCls[c.cls] + 1
        end
    end
    for li = 1, #lineBuf do
        local line = lineBuf[li]
        if not line.consumed then
            local cls = CLS_FOR_KIND[line.kind]
            if cls and byCls[cls] > 0 then
                -- Candidates eligible for this line, nearest in time
                -- first (ties -> earliest hit).
                local pool = nil
                -- _cands is append-ordered by c.at (non-decreasing), so
                -- once a candidate is past the window no later one can
                -- match — break instead of scanning the whole buffer.
                local lineAt = line.at
                for ci = 1, #cands do
                    local c = cands[ci]
                    if c.at - lineAt > window then break end
                    if not c.done and c.cls == cls then
                        local dt = math.abs(c.at - lineAt)
                        if dt <= window then
                            pool = pool or {}
                            pool[#pool + 1] = { c = c, dt = dt }
                        end
                    end
                end
                if pool then
                    table.sort(pool, function(a, b)
                        if a.dt ~= b.dt then return a.dt < b.dt end
                        return a.c.at < b.c.at
                    end)
                    -- Strict mode: a candidate that can't prove the hit
                    -- is ours releases the line to the next-nearest
                    -- candidate — show less, never wrong.
                    for _, e in ipairs(pool) do
                        local c = e.c
                        if self:_Gate(c, line.kind) then
                            c.done = true
                            line.consumed = true
                            self:_EmitPaired(c, line.kind)
                            break
                        end
                        c.done = true
                        self.stats.gated = (self.stats.gated or 0) + 1
                        if ZCT.Dbg and ZCT.Dbg:Enabled("outgoing") then
                            ZCT.Dbg:Trace("outgoing", "gate %s unit=%s kind=%s (strict)",
                                c.cls, tostring(c.unit), tostring(line.kind))
                        end
                    end
                end
            end
        end
    end
end
Out.MatchLines = Out._MatchLines

-- Candidate TTL expired with no line: foreign damage/miss, or the
-- filter is inactive. Heal candidates on self/pet fall back to
-- incoming (another player healed us).
function Out:_Expire(c)
    if c.done then return end
    c.done = true
    self.stats.dropped = self.stats.dropped + 1
    if isEnemyUnit(c.unit) then self:_NoteDrop() end
    local lines = ZCT.LogLines
    if c.cls == "heal" and selfHealUnit(c.unit) then
        local su = selfHealUnit(c.unit)
        if self:_HideOverheal() and self:_WasFullHeal(su, c.at) then
            if ZCT.Dbg and ZCT.Dbg:Enabled("overheal") then
                ZCT.Dbg:Trace("overheal", "suppress heal unit=%s", tostring(c.unit))
            end
        else
        ZCT.Normalize:Emit("heal", {
            direction = "in",
            amount = c.amount,
            school = c.school,
            crit = c.crit,
            pet = (su == "pet"),
            action = c.action,
            unit = c.unit,
        })
        end
    end
    -- All other unmatched candidates: someone else's damage/miss, or the
    -- filter is inactive. Traced so "no outgoing text" is diagnosable.
    local buffered = lines and lines.Count and lines:Count() or 0
    if ZCT.Dbg and ZCT.Dbg:Enabled("outgoing") then
        ZCT.Dbg:Trace("outgoing", "drop %s unit=%s: no unclaimed line (buffered=%s)",
            c.cls, tostring(c.unit), tostring(buffered))
    end
    -- Only enemy damage/miss candidates imply lines SHOULD exist;
    -- heal candidates on allies (followers' HoTs etc.) never do.
    if c.cls ~= "heal" and lines and lines.SignalSeen then
        Out:_CheckFeed(lines:SignalSeen())
    end
end

-- Feed health: enemy hits arriving while NO classified combat-log line
-- has been seen recently means COMBAT_LOG_MESSAGE has stopped (filtered
-- events got switched off). Re-enable it and say so once a minute, with
-- the filter state, instead of silently showing no outgoing text.
Out._starved = 0
Out._lastFeedWarn = nil
Out._lastSignalAt = nil
function Out:_CheckFeed(signalSeen)
    local now = GetTime()
    if signalSeen then
        self._starved = 0
        self._lastSignalAt = now
        return
    end
    -- Only count starvation while the feed was recently alive: lines
    -- stop when YOU stop fighting even though the feed is healthy
    -- (followers/others keep generating candidates with no lines).
    -- A real mid-combat feed death freezes _lastSignalAt and warns fast.
    if not self._lastSignalAt or now - self._lastSignalAt > 20 then
        self._starved = 0
        return
    end
    self._starved = self._starved + 1
    if self._starved < 4 then return end
    self._starved = 0
    if C_CombatLog and C_CombatLog.SetFilteredEventsEnabled then
        pcall(C_CombatLog.SetFilteredEventsEnabled, true)
    end
    local t = GetTime()
    if self._lastFeedWarn and t - self._lastFeedWarn < 60 then return end
    self._lastFeedWarn = t
    local f = ZCT.CombatLogFilter
    local trusted = f and f.Verify and f:Verify()
    local msg = ("|cffdd5555[ZCT]|r Outgoing text paused: no combat-log lines "
        .. "are arriving (ZCT filter active=%s%s). Re-enabled the feed.")
        :format(tostring(trusted == true),
            (not trusted and f and f._reason) and (": " .. f._reason) or "")
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end
end

function Out:Enable()
    if self._enabled then return end
    self._enabled = true
end

function Out:Disable()
    self._enabled = false
end
