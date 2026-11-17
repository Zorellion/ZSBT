------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - ZCT -> ZSBT Bridge
--
-- Normalize sink that translates ZCT CombatEvents into the payload
-- contract consumed by ZSBT's downstream feature pipeline:
--   direction="out", pet=false -> Parser.Outgoing:ProcessEvent
--   direction="in",  pet=false -> Parser.Incoming:ProcessEvent
--   direction="out", pet=true, damage -> PulseEngine PET_DAMAGE_COMBAT
--   direction="out", pet=true, heal   -> PulseEngine PET_HEAL_LOG
--   direction="in",  pet=true, damage -> PulseEngine PET_INCOMING_DAMAGE_COMBAT
--
-- Secret amounts ride the shared rawPipe registry
-- (Parser.EventCollector._rawPipe) exactly like the legacy collector did.
-- kind="utility" events are ignored here; ZSBT's own interrupt/aura/
-- notification systems own those surfaces.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.ZCT = ZSBT.ZCT or {}
local Bridge = {}
ZSBT.ZCT.Bridge = Bridge

------------------------------------------------------------------------
-- Miss subtype -> display word (covers UNIT_COMBAT tokens like DODGE,
-- ABSORB and COMBAT_TEXT_UPDATE tokens like SPELL_MISS / SWING_DODGED).
------------------------------------------------------------------------
local MISS_WORDS = {
    DODGE = "Dodge", MISS = "Miss", PARRY = "Parry", BLOCK = "Block",
    RESIST = "Resist", ABSORB = "Absorb", EVADE = "Evade",
    IMMUNE = "Immune", REFLECT = "Reflect", DEFLECT = "Deflect",
}

------------------------------------------------------------------------
-- UNIT_COMBAT arg3 (flagText) -> display word. Whitelist only: arg3 is
-- documented as the crit/glance indicator but can also carry spell
-- names, so unknown strings are dropped rather than displayed.
-- CRITICAL is excluded — crits have their own styling pipeline.
------------------------------------------------------------------------
local FLAG_WORDS = {
    CRUSHING = "Crushing",
    GLANCING = "Glancing",
}

local function flagWord(flagText)
    if not ZSBT.IsSafeString(flagText) or flagText == "" then return nil end
    return FLAG_WORDS[flagText:upper()]
end

local function missWord(action)
    if type(action) ~= "string" then return "Miss" end
    local u = action:upper():gsub("MISSED$", "MISS")
    for k, word in pairs(MISS_WORDS) do
        local n = #k
        if u == k or (u:sub(-n) == k and u:sub(-n - 1, -n - 1) == "_") then
            return word
        end
    end
    return "Miss"
end

------------------------------------------------------------------------
-- Line kinds that carry no spellId and behave like auto-attacks for
-- ZSBT's auto-attack display modes (Hide / Show Only Crits).
------------------------------------------------------------------------
local MELEE_LINE_KINDS = {
    melee = true, meleeMiss = true, ranged = true, rangedMiss = true,
    shield = true, shieldMiss = true,
}

local function safeUnitName(unit)
    if type(unit) ~= "string" or unit == "" then return nil end
    local ok, value = pcall(UnitName, unit)
    if not ok or type(value) ~= "string" then return nil end
    if ZSBT.IsSafeString and ZSBT.IsSafeString(value) then
        if value == "" then return nil end
        return value
    end
    return value -- secret name: pass through, display sinks accept it
end

------------------------------------------------------------------------
-- Allocate a slot in the shared raw-pipe registry for a secret amount.
-- Returns nil when the registry is unavailable (amount then just rides
-- evt.amount raw, which the probes also accept as a tainted fallback).
------------------------------------------------------------------------
local function allocRawPipe(amount)
    local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
    if not (ec and ec._rawPipe) then return nil end
    local pipeId = (ec._rawPipeCount or 0) + 1
    ec._rawPipeCount = pipeId
    ec._rawPipe[pipeId] = amount
    return pipeId
end

local function petConf()
    return ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.pets or nil
end

-- Caster mode (ZCT parity): melee swings carry no spellId and UNIT_COMBAT
-- can't say who swung, so on a caster with a pet out those "melee" hits
-- are almost always the pet's. Opt-in because it misattributes real
-- player melee when enabled. Only damage reroutes — ZCT folds outgoing
-- pet misses back into the regular miss category, and ZSBT has no pet
-- miss surface anyway.
local function isCasterModePet(evt, spellId, kind)
    local conf = petConf()
    if not (conf and conf.casterMode == true) then return false end
    if evt.direction ~= "out" then return false end
    if kind ~= "damage" then return false end
    if spellId ~= nil then return false end
    if evt.lineKind ~= "melee" and evt.lineKind ~= "meleeMiss" then return false end
    return UnitExists ~= nil and UnitExists("pet") == true
end

-- The legacy collector wiped its rawPipe registry on a timer from inside
-- its event handlers; with the collector retired nothing else does it.
-- Unconsumed slots only linger from gated/dropped events, but keep the
-- table bounded anyway.
local RAW_PIPE_WIPE_INTERVAL = 60
Bridge._rawPipeLastWipe = Bridge._rawPipeLastWipe or 0

local function maybeWipeRawPipe()
    local t = GetTime and GetTime() or 0
    if (t - Bridge._rawPipeLastWipe) < RAW_PIPE_WIPE_INTERVAL then return end
    Bridge._rawPipeLastWipe = t
    local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
    if ec and ec._rawPipe then
        for k in pairs(ec._rawPipe) do ec._rawPipe[k] = nil end
        ec._rawPipeCount = 0
    end
end

------------------------------------------------------------------------
-- Pet outgoing damage -> PulseEngine merge path (preserves "Pet 123 (xN)"
-- aggregation, thresholds, colors). Secret amounts pass through raw.
------------------------------------------------------------------------
local function emitPetDamage(evt, amount)
    local eng = ZSBT.Parser and ZSBT.Parser.PulseEngine
    if not (eng and eng._enabled and eng.collect) then return end
    eng:collect("PET_DAMAGE_COMBAT", {
        timestamp = evt.at,
        amount = amount,
        isCrit = evt.crit == true,
        schoolMask = evt.school,
        petBucket = nil,
    })
end

-- Pet outgoing heal -> PET_HEAL_LOG (safe numbers only, same as legacy).
local function emitPetHeal(evt, amount)
    local conf = petConf()
    if not (conf and conf.showHealing == true) then return end
    if not ZSBT.IsSafeNumber(amount) then return end -- legacy skipped secrets
    local eng = ZSBT.Parser and ZSBT.Parser.PulseEngine
    if not (eng and eng._enabled and eng.collect) then return end
    eng:collect("PET_HEAL_LOG", {
        timestamp = evt.at,
        amount = amount,
        isCrit = evt.crit == true,
        spellId = ZSBT.IsSafeNumber(evt.spellId) and evt.spellId or nil,
    })
end

-- Damage landing ON the pet -> PET_INCOMING_DAMAGE_COMBAT. That branch
-- only reads the rawPipe registry, so a pipe is required even for safe
-- numbers.
local function emitPetIncomingDamage(evt, amount)
    local conf = petConf()
    if not (conf and conf.showIncomingDamage == true) then return end
    local pipeId = allocRawPipe(amount)
    if not pipeId then return end
    local eng = ZSBT.Parser and ZSBT.Parser.PulseEngine
    if not (eng and eng._enabled and eng.collect) then return end
    eng:collect("PET_INCOMING_DAMAGE_COMBAT", {
        timestamp = evt.at,
        rawPipeId = pipeId,
        isCrit = evt.crit == true,
        schoolMask = evt.school,
    })
end

------------------------------------------------------------------------
-- Debug: mirrors the probes' Dbg4 gating (outgoing channel, level >= 4).
-- Only provably-safe fields are printed.
------------------------------------------------------------------------
local function dbgBridge(fmt, ...)
    local lvl = ZSBT.GetDebugLevel and ZSBT:GetDebugLevel("outgoing") or 0
    if lvl < 4 then return end
    if ZSBT.Addon and ZSBT.Addon.Print then
        ZSBT.Addon:Print(("[ZCTBRIDGE] " .. fmt):format(...))
    end
end

------------------------------------------------------------------------
-- Normalize sink entry point. evt is pooled and released after sinks
-- return, so every needed field is copied into `info` synchronously.
------------------------------------------------------------------------
function Bridge:Handle(evt)
    if type(evt) ~= "table" then return end
    maybeWipeRawPipe()
    local kind = evt.kind
    local dir = evt.direction
    if dir ~= "in" and dir ~= "out" then return end

    -- Kill-credit utility lines feed the UT kill announcer chain. The
    -- combat-log line carries no victim name; Core resolves it from the
    -- last seen target, same as the other credit channels. All other
    -- utility kinds stay display-only inside ZCT and are dropped here.
    --
    -- Kill lines replay on login AND on combat-log refilter (window
    -- focus/tab switches re-emit recent entries), so _sawOutgoing alone
    -- can't tell a replay from a real kill -- it stays true all session.
    -- Gate on RECENT outgoing combat instead: a real credit lands right
    -- after the killing blow; a replay arrives with stale combat state.
    -- Same 1.5s window the UNIT_HEALTH inference path uses in Core.lua.
    if kind == "utility" then
        if dir == "out" and evt.lineKind == "kill" then
            local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
            local lastAt = ec and ec._lastOutgoingCombatAt
            local age = lastAt and ((GetTime and GetTime() or 0) - lastAt) or nil
            if Bridge._sawOutgoing and age and age <= 1.5 then
                dbgBridge("utility kill credit")
                local core = ZSBT.Core
                if core and core.NoteKillCredit then
                    core:NoteKillCredit(nil, "zct")
                end
            else
                dbgBridge("utility kill credit dropped (stale replay)")
            end
        end
        return
    end

    if kind ~= "damage" and kind ~= "heal" and kind ~= "miss" then return end

    dbgBridge("kind=%s dir=%s pet=%s line=%s action=%s spellId=%s crit=%s per=%s unit=%s",
        tostring(kind), tostring(dir), tostring(evt.pet),
        tostring(evt.lineKind), tostring(evt.action),
        tostring(ZSBT.IsSafeNumber(evt.spellId) and evt.spellId or nil),
        tostring(evt.crit), tostring(evt.periodic), tostring(evt.unit))

    -- Keep the damage-meter fallback suppressed while real events flow.
    -- The legacy collector noted a signal per combat event inside the
    -- pulse engine; the bridge bypasses that path, so note it here. The
    -- meter then only reconstructs ticks during genuine detection gaps.
    local eng = ZSBT.Parser and ZSBT.Parser.PulseEngine
    if eng and eng._enabled then
        if dir == "out" and eng._noteOutgoingSignal then
            eng:_noteOutgoingSignal(evt.at or GetTime())
        elseif dir == "in" and eng._noteIncomingSignal then
            eng:_noteIncomingSignal(evt.at or GetTime())
        end
    end
    if dir == "out" then Bridge._sawOutgoing = true end

    local amount = evt.amount
    local hasAmount = amount ~= nil
    local amountSafe = hasAmount and ZSBT.IsSafeNumber(amount) == true

    -- spellId must be a proven-safe number: ZCT gates its attribution
    -- through IsSafeNumber already, but a secret slipping through would
    -- make the ~= nil confidence check below throw. Belt and braces.
    local spellId = ZSBT.IsSafeNumber(evt.spellId) and evt.spellId or nil

    -- Pet-routed events bypass the player probes entirely. Caster mode
    -- folds unattributed melee into the same pet path.
    if evt.pet == true or isCasterModePet(evt, spellId, kind) then
        if dir == "out" and kind == "damage" then
            emitPetDamage(evt, amount)
        elseif dir == "out" and kind == "heal" then
            emitPetHeal(evt, amount)
        elseif dir == "in" and kind == "damage" then
            emitPetIncomingDamage(evt, amount)
        end
        -- pet misses and incoming pet heals have no legacy surface; drop.
        return
    end

    local amountText = nil
    local dispAmount = nil
    local missType = nil
    if kind == "miss" then
        amountText = missWord(evt.action)
        missType = ZSBT.NormalizeMissSubtype
            and ZSBT.NormalizeMissSubtype(evt.action) or nil
    elseif amountSafe then
        dispAmount = amount
        amountText = tostring(math.floor(amount + 0.5))
    end

    -- Secret amounts ride rawPipe; info.amount also carries the raw
    -- secret (legal: stored/passed only, never operated on).
    local rawPipeId = nil
    if hasAmount and not amountSafe then
        rawPipeId = allocRawPipe(amount)
    end

    local isAuto = (spellId == nil)
        and MELEE_LINE_KINDS[evt.lineKind] == true

    local targetName = (dir == "out") and safeUnitName(evt.unit) or nil

    -- Keep the kill-inference fields the legacy collector maintained:
    -- Core.lua reads these to confirm recent outgoing damage on the
    -- cleared target before firing the "unit died" notification.
    if dir == "out" then
        local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
        if ec then
            ec._lastOutgoingCombatAt = evt.at or GetTime()
            if ZSBT.IsSafeString(targetName) and targetName ~= "" then
                ec._lastOutgoingCombatTargetName = targetName
            end
        end
    end

    local info = {
        kind = kind,
        amount = amountSafe and dispAmount or (hasAmount and amount or nil),
        amountText = amountText,
        rawPipeId = rawPipeId,
        spellId = evt.spellId,
        spellName = nil, -- downstream resolves via ZSBT.CleanSpellName(spellId)
        schoolMask = evt.school,
        isCrit = evt.crit == true,
        isPeriodic = evt.periodic == true,
        isAuto = isAuto,
        missType = missType,
        flagText = flagWord(evt.flagText),
        timestamp = evt.at,
        -- Incoming events must keep targetName nil so Incoming:ProcessEvent
        -- defaults it to the player name (a nameplate token would fail its
        -- player-name check and drop the event).
        targetName = targetName,
        confidence = spellId ~= nil and "HIGH" or "MEDIUM",
        amountSource = "ZCT",
    }

    if dir == "out" then
        local out = ZSBT.Parser and ZSBT.Parser.Outgoing
        if out and out.ProcessEvent then out:ProcessEvent(info) end
    else
        local inc = ZSBT.Parser and ZSBT.Parser.Incoming
        if inc and inc.ProcessEvent then inc:ProcessEvent(info) end
    end
end

return Bridge
