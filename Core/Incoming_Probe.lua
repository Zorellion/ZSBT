------------------------------------------------------------------------
-- ZSBT - Incoming Probe / Replay Harness (UI/UX Validation)
--
-- Purpose:
--   - Capture *real* incoming events (from Parser.Incoming) into a ring buffer
--   - Derive a small capabilities report based on observed fields
--   - Replay captured events through Display routing to validate UI/UX
--
-- Non-goals:
--   - This is NOT the engine.
--   - No attribution, aggregation, throttling, or spam policy.
--   - No secret-value identity work.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.Core = ZSBT.Core or {}
ZSBT.Core.IncomingProbe = ZSBT.Core.IncomingProbe or {}
local Probe = ZSBT.Core.IncomingProbe
local Addon = ZSBT.Addon

-- Internal state
Probe._initialized = Probe._initialized or false
Probe._capturing = Probe._capturing or false
Probe._replaying = Probe._replaying or false
Probe._captureEnds = Probe._captureEnds or 0
Probe._ticker = Probe._ticker or nil

Probe._maxBuffer = Probe._maxBuffer or 200
Probe._buffer = Probe._buffer or {}
Probe._bufHead = Probe._bufHead or 0
Probe._bufCount = Probe._bufCount or 0

-- Observed field values during current capture window
Probe._seenSchoolMasks = Probe._seenSchoolMasks or {}
Probe._seenSchoolsList = Probe._seenSchoolsList or {}

-- Capability report is based on what we observe during capture.
-- Values:
--   nil  = unknown (not observed yet)
--   true = observed
--   false = observed unavailable/impossible in current source
Probe.cap = Probe.cap or {
    source = "UNIT_COMBAT",
    hasAmount = true, -- required
    hasFlagText = nil,
    hasSchool = nil,
    hasPeriodic = false -- UNIT_COMBAT does not provide reliable periodic classification
}

local function Now() return (GetTime and GetTime()) or 0 end

------------------------------------------------------------------------
-- Incoming Merge Buffer (readability)
-- Merges rapid incoming events into a single line.
-- Policy:
--   - Merge window: 0.20s
--   - Key: scroll area + kind + crit + safe schoolMask
--   - Numeric-safe: sum amounts and show "SUM xN" when N>1
--   - Secret/tainted: count-only "Hits xN" / "Heals xN"
------------------------------------------------------------------------
local INCOMING_MERGE_WINDOW = 0.20
local incomingMerge = {}

local function EmitToDisplay(area, text, color, meta)
	if Addon and Addon.Dbg then
		Addon:Dbg("incoming", 4, "EMIT", area, meta and meta.kind, meta and meta.targetName, meta and meta.spellId, text)
	end

    if ZSBT.DisplayText then
        ZSBT.DisplayText(area, text, color, meta)
    elseif ZSBT.Core and ZSBT.Core.Display and ZSBT.Core.Display.Emit then
        ZSBT.Core.Display:Emit(area, text, color, meta)
    end
end

local function FlushIncomingMerge(key)
    local e = incomingMerge[key]
    if not e then return end
    incomingMerge[key] = nil

    if e.timer then
        e.timer:Cancel()
        e.timer = nil
    end

    local text = e.text
    if e.count and e.count > 1 then
        if e.mode == "numeric" and type(e.sum) == "number" then
            local sumText
            if ZSBT.FormatDisplayAmount then
                sumText = ZSBT.FormatDisplayAmount(e.sum)
            else
                sumText = tostring(math.floor(e.sum + 0.5))
            end
            text = sumText .. " x" .. tostring(e.count)
        elseif e.mode == "secret" then
            text = ((e.kind == "heal") and "Heals" or "Hits") .. " x" .. tostring(e.count)
        elseif ZSBT.IsSafeString(text) then
            text = text .. " x" .. tostring(e.count)
        end
    end

    EmitToDisplay(e.area, text, e.color, e.meta)
end

local function PushIncomingMerge(key, area, kind, isCrit, schoolMask, mode, amount, rawText, color, meta)
    local existing = incomingMerge[key]
    if existing then
        existing.count = (existing.count or 0) + 1
        if existing.mode == "numeric" and mode == "numeric" and type(amount) == "number" then
            existing.sum = (existing.sum or 0) + amount
        end

        if existing.timer then existing.timer:Cancel() end
        existing.timer = C_Timer.NewTimer(INCOMING_MERGE_WINDOW, function()
            FlushIncomingMerge(key)
        end)
        return
    end

    local baseText
    if mode == "numeric" then
        local n = tonumber(amount) or 0
        if ZSBT.FormatDisplayAmount then
            baseText = ZSBT.FormatDisplayAmount(n) or tostring(math.floor(n + 0.5))
        else
            baseText = tostring(math.floor(n + 0.5))
        end
    else
        -- Secret/tainted values: show the raw value when available for single events;
        -- when merged, FlushIncomingMerge will fall back to "Hits xN" / "Heals xN".
        baseText = rawText or ((kind == "heal") and "Heals" or "Hits")
    end

    incomingMerge[key] = {
        area = area,
        kind = kind,
        isCrit = isCrit == true,
        schoolMask = schoolMask,
        mode = mode,
        sum = (mode == "numeric" and type(amount) == "number") and amount or nil,
        count = 1,
        text = baseText,
        color = color,
        meta = meta,
        timer = C_Timer.NewTimer(INCOMING_MERGE_WINDOW, function()
            FlushIncomingMerge(key)
        end),
    }
end

local function Debug(level, ...)
	if Addon and Addon.Dbg then
		Addon:Dbg("incoming", level, ...)
		return
	end
	if Addon and Addon.DebugPrint then Addon:DebugPrint(level, ...) end
end

local function PushEvent(evt)
    -- Ring buffer.
    Probe._bufHead = (Probe._bufHead % Probe._maxBuffer) + 1
    Probe._buffer[Probe._bufHead] = evt
    Probe._bufCount = math.min(Probe._bufCount + 1, Probe._maxBuffer)
end

local function SnapshotBuffer()
    -- Return events in chronological order.
    local out = {}
    if Probe._bufCount == 0 then return out end

    local start = Probe._bufHead - Probe._bufCount + 1
    for i = 0, Probe._bufCount - 1 do
        local idx = start + i
        while idx <= 0 do idx = idx + Probe._maxBuffer end
        while idx > Probe._maxBuffer do idx = idx - Probe._maxBuffer end
        out[#out + 1] = Probe._buffer[idx]
    end
    return out
end

local function SchoolColorFromMask(mask)
    -- Minimal school coloring for UX testing. Multi-school masks fall back.
    -- mask may be a tainted secret number; use IsSafeNumber before arithmetic.
    if not ZSBT.IsSafeNumber(mask) then return nil end

    local band = (bit and bit.band) or (bit32 and bit32.band)
    if type(band) ~= "function" then return nil end

    -- If multiple bits are set, skip coloring (engine can refine later).
    if mask > 0 and band(mask, mask - 1) ~= 0 then
        return nil
    end

    -- Use numeric school IDs exclusively — never compare strings.
    if mask == ZSBT.SCHOOL_PHYSICAL then return nil end
    if mask == ZSBT.SCHOOL_HOLY    then return {r = 1.00, g = 0.90, b = 0.50} end
    if mask == ZSBT.SCHOOL_FIRE    then return {r = 1.00, g = 0.35, b = 0.20} end
    if mask == ZSBT.SCHOOL_NATURE  then return {r = 0.30, g = 1.00, b = 0.30} end
    if mask == ZSBT.SCHOOL_FROST   then return {r = 0.50, g = 0.85, b = 1.00} end
    if mask == ZSBT.SCHOOL_SHADOW  then return {r = 0.65, g = 0.45, b = 1.00} end
    if mask == ZSBT.SCHOOL_ARCANE  then return {r = 0.60, g = 0.60, b = 1.00} end
    return nil
end

function Probe:Init()
    if self._initialized then return end
    self._initialized = true
    Debug(1, "Core.IncomingProbe:Init()")
end

function Probe:IsCapturing() return self._capturing == true end

function Probe:IsReplaying() return self._replaying == true end

function Probe:ResetCapture()
    self._buffer = {}
    self._bufHead = 0
    self._bufCount = 0

    self.cap.hasFlagText = nil
    self.cap.hasSchool = nil
    -- hasPeriodic remains false by design for UNIT_COMBAT.

    self._seenSchoolMasks = {}
    self._seenSchoolsList = {}
end

function Probe:StartCapture(seconds)
    self:Init()

    if self._capturing then return end
    self:StopReplay()

    seconds = tonumber(seconds) or 10
    if seconds < 1 then seconds = 1 end
    if seconds > 60 then seconds = 60 end

    self:ResetCapture()

    self._capturing = true
    self._captureEnds = Now() + seconds

    Debug(1, ("Core.IncomingProbe:StartCapture(%ss)"):format(seconds))
    if Addon and Addon.Print then
        Addon:Print(
            ("Incoming probe capture started (%ss). Go get hit / get healed."):format(
                seconds))
    end

    -- Auto-stop timer.
    C_Timer.After(seconds, function()
        if Probe and Probe._capturing then Probe:StopCapture(true) end
    end)
end

function Probe:StopCapture(auto)
    if not self._capturing then return end
    self._capturing = false
    self._captureEnds = 0

    Debug(1, "Core.IncomingProbe:StopCapture()")

    if Addon and Addon.Print then
        Addon:Print(("Incoming probe capture %s. Captured %d events."):format(
                        auto and "ended" or "stopped", self._bufCount))

        if self._seenSchoolsList and #self._seenSchoolsList > 0 then
            table.sort(self._seenSchoolsList)
            local maxShow = 12
            local parts = {}
            for i = 1, math.min(#self._seenSchoolsList, maxShow) do
                parts[#parts + 1] = tostring(self._seenSchoolsList[i])
            end
            local suffix = (#self._seenSchoolsList > maxShow) and
                               (" … +" ..
                                   tostring(#self._seenSchoolsList - maxShow)) or
                               ""
            Addon:Print(
                ("Incoming probe observed schoolMask values: %s%s"):format(
                    table.concat(parts, ", "), suffix))
        else
            Addon:Print("Incoming probe observed schoolMask values: (none)")
        end
    end
end

function Probe:Replay(speed)
    self:Init()
    if self._replaying then return end
    self:StopCapture(false)

    local events = SnapshotBuffer()
    if #events == 0 then
        if Addon and Addon.Print then
            Addon:Print(
                "Incoming probe has no captured events to replay. Capture first.")
        end
        return
    end

    speed = tonumber(speed) or 1.0
    if speed < 0.25 then speed = 0.25 end
    if speed > 4.0 then speed = 4.0 end

    self._replaying = true
    local i = 1

    Debug(1, ("Core.IncomingProbe:Replay(speed=%s) events=%d"):format(speed,
                                                                      #events))
    if Addon and Addon.Print then
        Addon:Print(
            ("Incoming probe replay started (%d events, speed x%.2f)."):format(
                #events, speed))
    end

    -- Replay at a fixed interval. We do not preserve original timing; UX test only.
    local interval = 0.20 / speed
    self._ticker = C_Timer.NewTicker(interval, function()
        if not Probe or not Probe._replaying then return end
        local evt = events[i]
        if evt then
            Probe:ProcessIncomingEvent(evt, true)
            i = i + 1
        end

        if i > #events then Probe:StopReplay(true) end
    end)
end

function Probe:StopReplay(auto)
    if not self._replaying then return end
    self._replaying = false

    if self._ticker then
        self._ticker:Cancel()
        self._ticker = nil
    end

    Debug(1, "Core.IncomingProbe:StopReplay()")
    if Addon and Addon.Print then
        Addon:Print(("Incoming probe replay %s."):format(
                        auto and "completed" or "stopped"))
    end
end

function Probe:GetCapabilityReport()
    local cap = self.cap or {}
    local function v(x)
        if x == nil then return "unknown" end
        return x and "yes" or "no"
    end

    return {
        source = cap.source or "?",
        hasFlagText = v(cap.hasFlagText),
        hasSchool = v(cap.hasSchool),
        hasPeriodic = v(cap.hasPeriodic),
        bufferCount = self._bufCount or 0,
        bufferMax = self._maxBuffer or 0,
        schoolMaskCount = (self._seenSchoolsList and #self._seenSchoolsList) or
            0
    }
end

function Probe:PrintCapabilityReport()
    local r = self:GetCapabilityReport()
    if Addon and Addon.Print then
        Addon:Print(
            ("Incoming Probe Capabilities: source=%s, flags=%s, school=%s, periodic=%s, buffer=%d/%d, schools=%d"):format(
                r.source, r.hasFlagText, r.hasSchool, r.hasPeriodic,
                r.bufferCount, r.bufferMax, r.schoolMaskCount or 0))
    end
end

-- Called by Parser.Incoming. This function must be safe: no identity ops.
-- evt = {
--   ts=number, kind="damage"|"heal", amount=number,
--   flagText=string|nil, schoolMask=number|nil
-- }
function Probe:OnIncomingDetected(evt)
    if not evt or type(evt) ~= "table" then return end

    -- Update capabilities only while capturing (keeps the report scoped to current test).
    if self._capturing then
        if self.cap.hasFlagText == nil and ZSBT.IsSafeString(evt.flagText) and
            evt.flagText ~= "" then self.cap.hasFlagText = true end
        if self.cap.hasSchool == nil and ZSBT.IsSafeNumber(evt.schoolMask) and
            evt.schoolMask > 0 then self.cap.hasSchool = true end

        if ZSBT.IsSafeNumber(evt.schoolMask) and evt.schoolMask > 0 then
            if not self._seenSchoolMasks[evt.schoolMask] then
                self._seenSchoolMasks[evt.schoolMask] = true
                self._seenSchoolsList[#self._seenSchoolsList + 1] =
                    evt.schoolMask
            end
        end

        PushEvent(evt)
    end

    -- Always emit to display when the addon is enabled — not just during capture.
    self:ProcessIncomingEvent(evt, false)
end

function Probe:ProcessIncomingEvent(evt, isReplay)
    if not ZSBT.db or not ZSBT.db.profile or not ZSBT.db.profile.incoming then
        return
    end

    local prof = ZSBT.db.profile.incoming

    local kind = evt.kind
    if kind ~= "damage" and kind ~= "heal" and kind ~= "miss" then return end

    -- Miss events bypass normal amount processing
    if kind == "miss" then
        if prof.damage and prof.damage.showMisses == false then
            return
        end
        local area = (prof.damage and prof.damage.scrollArea) or "Incoming"
        local missText = ZSBT.IsSafeString(evt.amountText) and evt.amountText or "Miss"
        local color = {r = 0.70, g = 0.70, b = 0.70}  -- Gray for misses
        local sid = evt.spellID or evt.spellId
        local meta = {
            probe = true,
            replay = isReplay == true,
            kind = kind,
            targetName = evt.targetName,
            spellId = sid,
        }
        if ZSBT.DisplayText then
            ZSBT.DisplayText(area, missText, color, meta)
        elseif ZSBT.Core and ZSBT.Core.Display and ZSBT.Core.Display.Emit then
            ZSBT.Core.Display:Emit(area, missText, color, meta)
        end
        return
    end

    local conf = (kind == "damage") and prof.damage or prof.healing
    if not conf or not conf.enabled then return end

    -- Resolve display amount using the safe helper.
    -- RAW PIPE: If this event came from COMBAT_TEXT_UPDATE, retrieve the
    -- untouched secret value directly for SetText(). This bypasses all
    -- intermediate Lua operations that would taint the value.
    local rawPipeValue = nil
    if evt.rawPipeId and ZSBT.Parser and ZSBT.Parser.EventCollector then
        local ec = ZSBT.Parser.EventCollector
        rawPipeValue = ec._rawPipe[evt.rawPipeId]
        ec._rawPipe[evt.rawPipeId] = nil  -- consume it
    end

    local displayText, isTainted = ZSBT.ResolveDisplayAmount(evt.amount, evt.amountText, kind)
    if type(displayText) == "nil" and rawPipeValue == nil then return end

    -- Apply thresholds: use raw pipe value if it's a clean number,
    -- otherwise use evt.amount. Skip entirely if both are tainted (dungeon).
    local thresholdAmt = nil
    if rawPipeValue ~= nil and ZSBT.IsSafeNumber(rawPipeValue) then
        thresholdAmt = rawPipeValue
    elseif not isTainted and ZSBT.IsSafeNumber(evt.amount) then
        thresholdAmt = evt.amount
    end

    if thresholdAmt then
        if thresholdAmt <= 0 then return end
        -- Per-category threshold (Incoming tab)
        local minT = tonumber(conf.minThreshold) or 0
        if minT > 0 and thresholdAmt < minT then return end
        -- Global spam control thresholds (Spam Control tab)
        local spam = ZSBT.db.profile.spamControl and ZSBT.db.profile.spamControl.throttling
        if spam then
            if kind == "damage" and spam.minDamage and spam.minDamage > 0 and thresholdAmt < spam.minDamage then return end
            if kind == "heal" and spam.minHealing and spam.minHealing > 0 and thresholdAmt < spam.minHealing then return end
        end
    end

    -- Instance/readability policy: if the value is a secret (tainted) raw pipe
    -- and we have no safe numeric amount to filter against AND no threshold to
    -- run secret-threshold evaluation, hide it to avoid unfilterable spam.
    if rawPipeValue ~= nil and not ZSBT.IsSafeNumber(rawPipeValue) and thresholdAmt == nil then
        local catMin = tonumber(conf.minThreshold) or 0
        local spam = ZSBT.db.profile.spamControl and ZSBT.db.profile.spamControl.throttling
        local globalMin = 0
        if spam then
            if kind == "damage" then globalMin = tonumber(spam.minDamage) or 0 end
            if kind == "heal" then globalMin = tonumber(spam.minHealing) or 0 end
        end
        local effectiveThreshold = math.max(catMin, globalMin)
        if effectiveThreshold <= 0 and evt.isCrit ~= true then
            return
        end
    end

    local function maybePlayCritSound(critConf, rawPipeValue, isTainted)
        if not (evt and evt.isCrit == true) then return end
        if type(critConf) ~= "table" then return end
        if critConf.soundEnabled ~= true then return end
        local soundKey = critConf.sound
        if type(soundKey) ~= "string" or soundKey == "" or soundKey == "None" then return end
        if not ZSBT.PlayLSMSound then return end

        local minAmt = tonumber(critConf.minSoundAmount) or 0
        local amt = nil
        if rawPipeValue ~= nil and ZSBT.IsSafeNumber(rawPipeValue) then
            amt = rawPipeValue
        elseif (not isTainted) and ZSBT.IsSafeNumber(evt.amount) then
            amt = evt.amount
        end

        if amt ~= nil then
            if amt < minAmt then return end
            ZSBT.PlayLSMSound(soundKey)
            return
        end

        local mode = tostring(critConf.instanceSoundMode or "Only when amount is known")
        if mode == "Any Crit" then
            ZSBT.PlayLSMSound(soundKey)
        end
    end

    local area = conf.scrollArea or "Incoming"
    local critRouted = false
    local incomingProf = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.incoming
    local baseCritConf = incomingProf and incomingProf.crits
    local kindOverrideCritConf = nil
    if incomingProf and evt.isCrit == true then
        if kind == "heal" and type(incomingProf.critHealing) == "table" and incomingProf.critHealing.enabled == true then
            kindOverrideCritConf = incomingProf.critHealing
        elseif kind ~= "heal" and type(incomingProf.critDamage) == "table" and incomingProf.critDamage.enabled == true then
            kindOverrideCritConf = incomingProf.critDamage
        end
    end
    local resolvedCritConf = kindOverrideCritConf or baseCritConf

    -- New incoming crit routing (Incoming tab)
    if evt.isCrit == true and resolvedCritConf and resolvedCritConf.enabled == true and ZSBT.IsSafeString(resolvedCritConf.scrollArea) and resolvedCritConf.scrollArea ~= "" then
        area = resolvedCritConf.scrollArea
        critRouted = true
    -- Legacy per-category crit routing (Damage/Healing)
    elseif evt.isCrit == true and conf.critScrollArea and ZSBT.IsSafeString(conf.critScrollArea) and conf.critScrollArea ~= "" then
        area = conf.critScrollArea
        critRouted = true
    end

    -- If we have a raw pipe value, use it directly for SetText.
    -- Use raw pipe value if available, otherwise processed text.
    -- Convert clean raw pipe numbers to strings so merge buffer can work.
    local text
    local mergeMode = nil
    local mergeAmount = nil
    local rawIsSecret = (rawPipeValue ~= nil and not ZSBT.IsSafeNumber(rawPipeValue))
    if rawPipeValue ~= nil then
        if ZSBT.IsSafeNumber(rawPipeValue) then
            if ZSBT.FormatDisplayAmount then
                text = ZSBT.FormatDisplayAmount(rawPipeValue)
            else
                text = tostring(math.floor(rawPipeValue + 0.5))
            end
            mergeMode = "numeric"
            mergeAmount = rawPipeValue
        else
            -- Secret/tainted raw pipe values: suppress for UX.
            -- (User preference: do not show placeholder words like 'Heals'.)
            if kind == "heal" then
                return
            end
            mergeMode = "secret"
        end
    else
        text = displayText
        if not isTainted and ZSBT.IsSafeNumber(evt.amount) then
            mergeMode = "numeric"
            mergeAmount = evt.amount
        else
            mergeMode = "secret"
        end
    end

    -- Optional flags — only for clean safe strings
    if kind == "damage" and prof.damage and prof.damage.showFlags and ZSBT.IsSafeString(evt.flagText) and evt.flagText ~= "" then
        if ZSBT.IsSafeString(text) then
            text = text .. " " .. evt.flagText
        end
    end

    -- Overheal display for self-heals
    if kind == "heal" and ZSBT.IsSafeString(text) then
        local conf = prof.healing
        if conf and conf.showOverheal and evt.overheal and ZSBT.IsSafeNumber(evt.overheal) and evt.overheal > 0 then
            local overText
            if ZSBT.FormatDisplayAmount then
                overText = ZSBT.FormatDisplayAmount(evt.overheal)
            else
                overText = tostring(math.floor(evt.overheal + 0.5))
            end
            text = text .. " |cFF808080(OH " .. overText .. ")|r"
        end
    end

    -- Color: use numeric school mask IDs (never string names).
    local color = nil

    if prof.useSchoolColors then
        if ZSBT.IsSafeNumber(evt.schoolMask) then
            color = SchoolColorFromMask(evt.schoolMask)
            if not color and kind == "damage" then
                -- Physical or unknown school damage: white/neutral
                color = {r = 1.00, g = 1.00, b = 1.00}
            end
        elseif kind == "damage" then
            color = {r = 1.00, g = 1.00, b = 1.00}
        end
    end

    -- Custom fallback color (only when school colors are disabled)
    if (prof.useSchoolColors ~= true) and (not color) then
        local chosen = nil
        if kind == "heal" then
            chosen = prof.customHealingColor
        else
            chosen = prof.customDamageColor
        end

        local function isValidColor(c)
            return (type(c) == "table") and (type(c.r) == "number") and (type(c.g) == "number") and (type(c.b) == "number")
        end
        local function isWhite(c)
            return c and c.r == 1 and c.g == 1 and c.b == 1
        end

        -- Primary: split colors
        if isValidColor(chosen) and not isWhite(chosen) then
            color = {r = chosen.r, g = chosen.g, b = chosen.b}
        else
            -- Legacy fallback: prior single customColor setting
            local legacy = prof.customColor
            if isValidColor(legacy) and not isWhite(legacy) then
                color = {r = legacy.r, g = legacy.g, b = legacy.b}
            end
        end
    end

    if not color then
        if kind == "heal" then
            color = {r = 0.20, g = 1.00, b = 0.20}
        else
            color = {r = 1.00, g = 0.25, b = 0.25}
        end
    end

    -- Crit color override
    if evt.isCrit then
        -- When crits are routed via Incoming Crits config, allow a custom crit color.
        if critRouted and resolvedCritConf and resolvedCritConf.enabled == true then
            local cc = resolvedCritConf.color
            if type(cc) == "table" and type(cc.r) == "number" and type(cc.g) == "number" and type(cc.b) == "number" then
                color = { r = cc.r, g = cc.g, b = cc.b }
            elseif kind == "heal" then
                color = {r = 0.20, g = 1.00, b = 0.40}
            else
                color = {r = 1.00, g = 0.25, b = 0.25}
            end
        elseif kind == "heal" then
            color = {r = 0.20, g = 1.00, b = 0.40}
        else
            color = {r = 1.00, g = 1.00, b = 0.00}
        end
    end

    local sid = evt.spellID or evt.spellId
    local playerName = (UnitName and UnitName("player")) or nil
    local meta = {
        probe = true,
        replay = isReplay == true,
        kind = kind,
        stream = "incoming",
        spellId = sid,
        targetName = (kind == "heal" and playerName) or evt.targetName,
        isCrit = evt.isCrit == true,
        school = evt.schoolMask,
    }

    maybePlayCritSound(resolvedCritConf, rawPipeValue, isTainted)

    if evt.isCrit and resolvedCritConf and resolvedCritConf.enabled == true then
        if resolvedCritConf.sticky ~= false then
            meta.stickyCrit = true
            meta.stickyScale = 1.12
            meta.stickyDurationMult = 1.25
        end
    end
    if critRouted then
        meta.critRouted = true
    end

    if kind == "heal" and meta.isCrit == true then
        meta.critAnim = "Area"
        meta.critScale = 1.2
    end

    if rawPipeValue ~= nil and not ZSBT.IsSafeNumber(rawPipeValue) then
        local catMin = tonumber(conf.minThreshold) or 0
        local spam = ZSBT.db.profile.spamControl and ZSBT.db.profile.spamControl.throttling
        local globalMin = 0
        if spam then
            if kind == "damage" then globalMin = tonumber(spam.minDamage) or 0 end
            if kind == "heal" then globalMin = tonumber(spam.minHealing) or 0 end
        end
        local effectiveThreshold = math.max(catMin, globalMin)
        if effectiveThreshold > 0 then
            meta.secretRawValue = rawPipeValue
            meta.filterThreshold = effectiveThreshold
        end
    end

    if prof.showSpellIcons then
        if sid then
            local tex = ZSBT.CleanSpellIcon(sid)
            if tex then meta.spellIcon = tex end
        end
        if not meta.spellIcon then
            if kind == "damage" then
                meta.spellIcon = 132223
            elseif kind == "heal" then
                meta.spellIcon = 135907
            end
        end
    end

    local mergeConf = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl and ZSBT.db.profile.spamControl.merging
    local mergeEnabled = mergeConf and mergeConf.enabled == true

    if mergeEnabled then
        local schoolKey = (ZSBT.IsSafeNumber(evt.schoolMask) and evt.schoolMask) or 0
        local key = tostring(area) .. ":" .. tostring(kind) .. ":" .. (evt.isCrit and "C" or "N") .. ":" .. tostring(schoolKey) .. ":" .. tostring(mergeMode)
        PushIncomingMerge(key, area, kind, evt.isCrit == true, schoolKey, mergeMode, mergeAmount, text, color, meta)
        return
    end

    EmitToDisplay(area, text, color, meta)
end
