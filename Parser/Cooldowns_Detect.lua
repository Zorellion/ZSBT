------------------------------------------------------------------------
-- ZSBT - Cooldowns Detection
--
-- Midnight 12.0 Limitations:
--   - Charge-based spells: recharge data is SECRET when charges > 0.
--     We can only track reliably when ALL charges are spent (0 remaining).
--   - Simple cooldown spells: OnCooldownDone works via CooldownFrame.
--
-- Strategy:
--   - CooldownFrame with OnCooldownDone for in-combat detection
--   - SPELL_UPDATE_COOLDOWN for resync (do not infer READY from dur==0)
--   - For charge spells: only apply CD frame when charges hit 0
--
-- Debug: /zsbt cddebug 4
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.Parser = ZSBT.Parser or {}
ZSBT.Parser.Cooldowns = ZSBT.Parser.Cooldowns or {}
local Cooldowns = ZSBT.Parser.Cooldowns
local Addon     = ZSBT.Addon

Cooldowns._enabled = false
Cooldowns._frame   = nil
Cooldowns._state   = {}
Cooldowns._cdFrames = {}

-- Many spells report the Global Cooldown as a spell cooldown.
-- We only want to treat "real" cooldowns as state transitions.
local MIN_REAL_CD_SEC = 1.7

local CHARGE_RECHARGE_OVERRIDE_SEC = {
	[871] = 90, -- Shield Wall
}

local function SafeCancelTimer(t)
	if not t then return end
	if type(t) == "table" and type(t.Cancel) == "function" then
		pcall(function() t:Cancel() end)
	end
end

local function SafeToString(v)
	local ok, s = pcall(tostring, v)
	if ok and type(s) == "string" then
		return s
	end
	return "<secret>"
end

local function SafeField(tbl, key)
	if type(tbl) ~= "table" then return nil, "no_table" end
	local ok, val = pcall(function() return tbl[key] end)
	if not ok then return nil, "secret" end
	return val, nil
end

local function SafeGetLegacySpellCooldown(spellId)
	if type(GetSpellCooldown) ~= "function" then return nil, nil end
	local ok, start, dur, enabled, modRate = pcall(GetSpellCooldown, spellId)
	if not ok then return nil, "error" end
	return { startTime = start, duration = dur, isEnabled = enabled, modRate = modRate }, nil
end

local function SafeGetBaseCooldownSec(spellId)
	-- Prefer C_Spell base cooldown when available (returns ms).
	if C_Spell and type(C_Spell.GetSpellBaseCooldown) == "function" then
		local ok, ms = pcall(C_Spell.GetSpellBaseCooldown, spellId)
		if ok and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(ms) and ms and ms > 0 then
			return (ms / 1000.0)
		end
	end
	-- Legacy fallback (may return ms in some clients; normalize best-effort).
	if type(GetSpellBaseCooldown) == "function" then
		local ok, a, b = pcall(GetSpellBaseCooldown, spellId)
		if ok then
			local ms = a
			if type(ms) ~= "number" and type(b) == "number" then
				ms = b
			end
			if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(ms) and ms and ms > 0 then
				-- Most clients report ms here.
				return (ms / 1000.0)
			end
		end
	end
	return nil
end

local function CdDebug(msg)
    if not Addon then return end
	local db = (Addon and Addon.db) or ZSBT.db
	local level = db and db.profile and db.profile.diagnostics
		and db.profile.diagnostics.cooldownsDebugLevel or 0
	level = tonumber(level) or 0
	if level and level >= 1 then
		pcall(function()
			Addon:Print("|cFF00CCFF[CD]|r " .. SafeToString(msg))
		end)
	end
end

local function CdDbg(requiredLevel, msg)
	if not Addon then return end
	local db = (Addon and Addon.db) or ZSBT.db
	local level = db and db.profile and db.profile.diagnostics
		and db.profile.diagnostics.cooldownsDebugLevel or 0
	level = tonumber(level) or 0
	if level and level >= requiredLevel then
		pcall(function()
			Addon:Print("|cFF00CCFF[CD]|r " .. SafeToString(msg))
		end)
	end
end

------------------------------------------------------------------------
-- Read charges (silent)
------------------------------------------------------------------------
local function ReadCharges(spellId)
    if C_Spell and C_Spell.GetSpellCharges then
        local info = C_Spell.GetSpellCharges(spellId)
        if info then
            local cur = info.currentCharges
            local max = info.maxCharges
            if ZSBT.IsSafeNumber(cur) and ZSBT.IsSafeNumber(max) and max > 0 then
                return cur, max
            end
        end
    end
    return nil, nil
end

local function ReadChargesInfo(spellId)
	if not (C_Spell and C_Spell.GetSpellCharges) then return nil end
	local info = C_Spell.GetSpellCharges(spellId)
	if not info then return nil end
	local cur, curErr = SafeField(info, "currentCharges")
	local max, maxErr = SafeField(info, "maxCharges")
	local start, startErr = SafeField(info, "cooldownStartTime")
	local dur, durErr = SafeField(info, "cooldownDuration")
	if curErr == "secret" or maxErr == "secret" or startErr == "secret" or durErr == "secret" then
		-- Caller should treat missing fields as secret/unreadable.
	end
	return {
		cur = cur,
		max = max,
		start = start,
		dur = dur,
		curErr = curErr,
		maxErr = maxErr,
		startErr = startErr,
		durErr = durErr,
	}
end

local function IsChargeSpell(spellId)
	local ch = ReadChargesInfo(spellId)
	if not ch then return false end
	if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(ch.max) and ch.max and ch.max > 1 then
		return true
	end
	-- Midnight 12.0: charge fields can be secret; treat that as a charge spell.
	if ch.maxErr == "secret" or ch.curErr == "secret" or ch.startErr == "secret" or ch.durErr == "secret" then
		return true
	end
	return false
end

------------------------------------------------------------------------
-- Fire "ready" notification (debounce: 1s)
------------------------------------------------------------------------
local function FireReady(spellId, method)
    local state = Cooldowns._state[spellId]
    if state and state.lastFiredAt and (GetTime() - state.lastFiredAt) < 1.0 then
        return
    end

	-- Charge spells are disabled (Midnight 12.0 limitation).
	-- Ensure READY events never emit notifications or triggers for multi-charge spells.
	if IsChargeSpell(spellId) == true then
		CdDbg(3, "FireReady suppressed for charge spellId=" .. tostring(spellId) .. " method=" .. tostring(method))
		if state then
			SafeCancelTimer(state.readyTimer)
			state.readyTimer = nil
			state.readyAt = nil
			state.isOnCD = false
			state.seenStart = false
		end
		return
	end

    if state then state.lastFiredAt = GetTime() end
	if state then
		SafeCancelTimer(state.readyTimer)
		state.readyTimer = nil
		state.readyAt = nil
	end

    local spellName = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId)
        or (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellId))
        or ("Spell #" .. spellId)

	CdDbg(1, spellName .. " -> READY! (" .. method .. ")")
	if state then
		state.waitingCharge = false
		state.waitingFull = false
		if state.isChargeSpell == true then
			state.chargeCount = 1
		end
	end

    local decide = ZSBT.Core and ZSBT.Core.Cooldowns
    if decide and decide.OnCooldownReady then
        decide:OnCooldownReady({
            spellId   = spellId,
            spellName = spellName,
            timestamp = GetTime(),
        })
    end
end

local function ScheduleReadyTimer(spellId, startTime, duration, source)
    local state = Cooldowns._state[spellId]
    if not state then return end
    if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(startTime) and ZSBT.IsSafeNumber(duration)) then return end
    if not startTime or startTime <= 0 then return end
    if not duration or duration <= 0 then return end

    local readyAt = startTime + duration
    local delay = readyAt - GetTime()
    if not (delay and delay > 0) then return end

    -- If we already have a ready timer running, never allow updates to move READY later.
    -- Only reschedule when the new computed readyAt is meaningfully earlier.
    if state.readyTimer and state.readyAt then
        -- Later or essentially the same: keep existing timer.
        if readyAt >= (state.readyAt - 0.25) then
            return
        end
    end

    SafeCancelTimer(state.readyTimer)
    state.readyAt = readyAt
    CdDbg(3, "ScheduleReadyTimer spellId=" .. tostring(spellId) .. " start=" .. tostring(startTime) .. " dur=" .. tostring(duration)
        .. " readyAt=" .. string.format("%.3f", readyAt) .. " delay=" .. string.format("%.3f", delay) .. " src=" .. tostring(source))
	state.readyTimer = C_Timer and C_Timer.NewTimer and C_Timer.NewTimer(delay, function()
		if not Cooldowns._enabled then return end
		local st = Cooldowns._state[spellId]
		if not st or st.isOnCD ~= true or st.seenStart ~= true then return end

		-- BASE_CD fallback: treat timer expiry as ready.
		if source == "BASE_CD" then
			st.isOnCD = false
			st.seenStart = false
			CdDbg(2, "BASE_CD timer expired; firing READY spellId=" .. tostring(spellId))
			FireReady(spellId, "BASE_CD")
			return
		end

		-- CHARGE timers are scheduled from recharge info when readable.
		-- Treat timer expiry as charge regained; cooldown confirmation may be secret.
		if source == "CHARGE" then
			st.isOnCD = false
			st.seenStart = false
			CdDbg(2, "CHARGE timer expired; firing READY spellId=" .. tostring(spellId))
			FireReady(spellId, "CHARGE")
			return
		end

		-- Confirm ready to avoid zone/load blips.
		local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(spellId)
		local dur = info and info.duration
		local start = info and info.startTime
		if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(dur) and ZSBT.IsSafeNumber(start) and dur == 0 and start == 0 then
			st.isOnCD = false
			st.seenStart = false
			FireReady(spellId, tostring(source or "TIMER"))
			return
		end

		CdDbg(2, "Timer expired but cooldown not confirmed ready for spellId=" .. tostring(spellId)
			.. " dur=" .. tostring(dur) .. " start=" .. tostring(start) .. " src=" .. tostring(source))
	end) or nil

	CdDbg(2, "Scheduled READY in " .. string.format("%.2f", delay) .. "s via " .. tostring(source) .. " for spellId=" .. tostring(spellId))
end

local function SafeGetSpellCooldown(spellId)
    if not (C_Spell and C_Spell.GetSpellCooldown) then return nil, "no_api" end
    local ok, info = pcall(C_Spell.GetSpellCooldown, spellId)
    if not ok then
        return nil, "error"
    end
    return info, nil
end

local ApplyCooldownToFrame

local function ConfirmCooldownStart(spellId, source, attempt)
    attempt = tonumber(attempt) or 1
    local state = Cooldowns._state[spellId]
    if not (Cooldowns._enabled and state and state.seenStart == true and state.isOnCD == true) then return end

    if attempt == 1 then
        CdDbg(2, "ConfirmCooldownStart ENTER spellId=" .. tostring(spellId) .. " src=" .. tostring(source))
    end
	CdDbg(2, "ConfirmCooldownStart attempt=" .. tostring(attempt) .. " spellId=" .. tostring(spellId) .. " src=" .. tostring(source))

    local info, err = SafeGetSpellCooldown(spellId)
    if err == "error" then
        CdDbg(1, "GetSpellCooldown ERROR spellId=" .. tostring(spellId) .. " src=" .. tostring(source) .. " attempt=" .. tostring(attempt))
        return
    end
    if err == "no_api" then
        CdDbg(2, "C_Spell.GetSpellCooldown unavailable; using legacy only. spellId=" .. tostring(spellId) .. " src=" .. tostring(source) .. " attempt=" .. tostring(attempt))
        info = {}
    end
    if info == nil then
        info = {}
    end
	CdDbg(2, "ConfirmCooldownStart post-C_Spell spellId=" .. tostring(spellId) .. " err=" .. tostring(err) .. " infoType=" .. tostring(type(info)))

    local start, startErr = SafeField(info, "startTime")
    local dur, durErr = SafeField(info, "duration")
    local isOnGCD = select(1, SafeField(info, "isOnGCD"))
    local isEnabled = select(1, SafeField(info, "isEnabled"))
    local cModRate = select(1, SafeField(info, "modRate"))
	CdDbg(2, "ConfirmCooldownStart fields spellId=" .. tostring(spellId)
		.. " start=" .. SafeToString(start) .. (startErr and ("(" .. startErr .. ")") or "")
		.. " dur=" .. SafeToString(dur) .. (durErr and ("(" .. durErr .. ")") or "")
		.. " isOnGCD=" .. SafeToString(isOnGCD)
		.. " enabled=" .. SafeToString(isEnabled))

    -- Legacy fallback (some spells return more reliable values here)
    local legacy, lerr = SafeGetLegacySpellCooldown(spellId)
    local lStart = legacy and legacy.startTime
    local lDur = legacy and legacy.duration
    local lEnabled = legacy and legacy.isEnabled
	CdDbg(2, "ConfirmCooldownStart legacy spellId=" .. tostring(spellId)
		.. " lerr=" .. SafeToString(lerr)
		.. " L.start=" .. SafeToString(lStart)
		.. " L.dur=" .. SafeToString(lDur)
		.. " L.enabled=" .. SafeToString(lEnabled))

    CdDbg(4, "ConfirmCooldownStart spellId=" .. tostring(spellId)
        .. " C.start=" .. SafeToString(start) .. (startErr and ("(" .. startErr .. ")") or "")
        .. " C.dur=" .. SafeToString(dur) .. (durErr and ("(" .. durErr .. ")") or "")
        .. " C.enabled=" .. SafeToString(isEnabled)
        .. " C.isOnGCD=" .. SafeToString(isOnGCD)
        .. " C.modRate=" .. SafeToString(cModRate)
        .. " L.start=" .. SafeToString(lStart) .. (lerr and ("(" .. lerr .. ")") or "")
        .. " L.dur=" .. SafeToString(lDur)
        .. " L.enabled=" .. SafeToString(lEnabled)
        .. " src=" .. tostring(source) .. " attempt=" .. tostring(attempt))

    -- Always show the first-attempt snapshot at level 2 so we can diagnose combat issues quickly.
    if attempt == 1 then
        CdDbg(2, "ConfirmCooldownStart(1) spellId=" .. tostring(spellId)
            .. " C.start=" .. SafeToString(start) .. (startErr and ("(" .. startErr .. ")") or "")
            .. " C.dur=" .. SafeToString(dur) .. (durErr and ("(" .. durErr .. ")") or "")
            .. " C.isOnGCD=" .. SafeToString(isOnGCD)
            .. " L.start=" .. SafeToString(lStart) .. (lerr and ("(" .. lerr .. ")") or "")
            .. " L.dur=" .. SafeToString(lDur)
            .. " src=" .. tostring(source))
    end

    if isOnGCD == true then
        return
    end

    -- Prefer C_Spell values if safe, else fallback to legacy values.
    local useStart, useDur = start, dur
    if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(useStart) and ZSBT.IsSafeNumber(useDur)) then
        useStart, useDur = lStart, lDur
    end

    if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(useStart) and ZSBT.IsSafeNumber(useDur)
        and useStart and useStart > 0 and useDur and useDur > MIN_REAL_CD_SEC then
        ScheduleReadyTimer(spellId, useStart, useDur, source)
        EnsureTrackedInitialized(spellId)
        local applied = ApplyCooldownToFrame and ApplyCooldownToFrame(spellId)
        CdDbg(3, "ConfirmCooldownStart appliedFrame=" .. tostring(applied) .. " spellId=" .. tostring(spellId) .. " src=" .. tostring(source))
        return
    end

    	-- Charge-aware: if the spell uses charges and we are currently at 0 charges, try to schedule
	-- based on the charge recharge timer (when readable) for the next charge (0->1).
	if state and state.isChargeSpell == true and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(state.chargeCount) and state.chargeCount == 0 then
		local ch = ReadChargesInfo(spellId)
		if ch then
			-- Update cached values when readable.
			if ZSBT.IsSafeNumber(ch.cur) then state.lastCharges = ch.cur end
			if ZSBT.IsSafeNumber(ch.max) then state.maxCharges = ch.max end
			if ZSBT.IsSafeNumber(ch.start) and ZSBT.IsSafeNumber(ch.dur) and ch.start and ch.dur and ch.dur > MIN_REAL_CD_SEC then
				CdDbg(2, "ConfirmCooldownStart charge schedule spellId=" .. tostring(spellId)
					.. " start=" .. SafeToString(ch.start) .. " dur=" .. SafeToString(ch.dur))
				ScheduleReadyTimer(spellId, ch.start, ch.dur, "CHARGE")
				return
			end
		end
		local ovr = CHARGE_RECHARGE_OVERRIDE_SEC[spellId]
		if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(ovr) and ovr and ovr > MIN_REAL_CD_SEC and state.castTime then
			CdDbg(2, "ConfirmCooldownStart charge override schedule spellId=" .. tostring(spellId) .. " sec=" .. tostring(ovr))
			ScheduleReadyTimer(spellId, state.castTime, ovr, "CHARGE_OVR")
			return
		end
		CdDbg(2, "ConfirmCooldownStart charge recharge secret; waiting for 0->1 event spellId=" .. tostring(spellId))
		return
	end

    -- Combat fallback: cooldown start/duration may be secret. If this cooldown was cast-initiated,
    -- schedule readiness based on base cooldown and our observed castTime.
	if source == "CAST" and attempt == 1 then
		local ct = state and state.castTime
		-- For charge spells, only approximate when we're at 0 charges (i.e. waiting for 0->1).
		if state and state.isChargeSpell == true then
			if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(state.chargeCount) and state.chargeCount == 0) then
				return
			end
			-- Never use base cooldown as a fallback for charge spells; it can be wrong (e.g., Shield Wall).
			CdDbg(2, "ConfirmCooldownStart skipping BASE_CD for charge spellId=" .. tostring(spellId))
			return
		end
		local baseSec = SafeGetBaseCooldownSec(spellId)
		if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(ct) and ct and baseSec and baseSec > MIN_REAL_CD_SEC then
			-- Schedule from castTime; use startTime=castTime for the timer.
			CdDbg(2, "ConfirmCooldownStart baseCD fallback spellId=" .. tostring(spellId)
				.. " castTime=" .. string.format("%.3f", ct) .. " baseSec=" .. string.format("%.3f", baseSec))
			ScheduleReadyTimer(spellId, ct, baseSec, "BASE_CD")
			local applied = ApplyCooldownToFrame and ApplyCooldownToFrame(spellId)
			CdDbg(3, "ConfirmCooldownStart baseCD appliedFrame=" .. tostring(applied) .. " spellId=" .. tostring(spellId))
			state.waitingCharge = true
			return
		else
			CdDbg(2, "ConfirmCooldownStart baseCD unavailable spellId=" .. tostring(spellId) .. " baseSec=" .. SafeToString(baseSec))
		end
	end

    -- Retry a few times; in-combat cooldown data can arrive slightly later.
    if attempt < 6 then
        local delay = 0.20 * attempt
        C_Timer.After(delay, function()
            ConfirmCooldownStart(spellId, source, attempt + 1)
        end)
    else
        CdDbg(2, "ConfirmCooldownStart gave up spellId=" .. tostring(spellId) .. " src=" .. tostring(source))
    end
end

------------------------------------------------------------------------
-- Apply cooldown to the hidden CooldownFrame.
------------------------------------------------------------------------
ApplyCooldownToFrame = function(spellId)
    local cd = Cooldowns._cdFrames[spellId]
    if not cd then return false end

    if C_Spell and C_Spell.GetSpellCooldown then
        local ok, info = pcall(C_Spell.GetSpellCooldown, spellId)
        if not ok then
            CdDbg(1, "ApplyCooldownToFrame GetSpellCooldown ERROR spellId=" .. tostring(spellId))
            return false
        end
        local start = info and info.startTime
        local dur = info and info.duration
        local modRate = info and info.modRate

        if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(start) and ZSBT.IsSafeNumber(dur) and start and dur then
            if ZSBT.IsSafeNumber(modRate) and modRate then
                cd:SetCooldown(start, dur, modRate)
            else
                cd:SetCooldown(start, dur)
            end
            CdDbg(3, "Applied CD to frame for spellId=" .. tostring(spellId) .. " start=" .. tostring(start) .. " dur=" .. tostring(dur))
            return true
        end

        if cd.Clear then
            cd:Clear()
        end
    end

    return false
end

------------------------------------------------------------------------
-- Create a hidden CooldownFrame for a tracked spell.
------------------------------------------------------------------------
local function CreateCDFrame(spellId)
    if Cooldowns._cdFrames[spellId] then return end

    local parent = CreateFrame("Frame", nil, UIParent)
    parent:SetSize(1, 1)
    parent:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -100, -100)

    local cd = CreateFrame("Cooldown", nil, parent, "CooldownFrameTemplate")
    cd:SetAllPoints(parent)
    cd:SetHideCountdownNumbers(true)

    cd:SetScript("OnCooldownDone", function()
        if not Cooldowns._enabled then return end
        local state = Cooldowns._state[spellId]
        if not state or not state.isOnCD or state.seenStart ~= true then return end
        CdDbg(2, "OnCooldownDone spellId=" .. tostring(spellId) .. " isOnCD=" .. tostring(state.isOnCD) .. " seenStart=" .. tostring(state.seenStart))

        SafeCancelTimer(state.readyTimer)
        state.readyTimer = nil
        state.readyAt = nil

        state.isOnCD = false
        state.seenStart = false
        FireReady(spellId, "OnCooldownDone")

        -- Re-apply if still recharging (charge-based: 0->1, check for 1->2)
        C_Timer.After(0.2, function()
            if not Cooldowns._enabled then return end
            local st = Cooldowns._state[spellId]
            if not st then return end

            -- Check if spell is still on CD (another charge recharging)
            local applied = ApplyCooldownToFrame(spellId)
            if applied then
                st.isOnCD = true
                CdDbg(2, "Re-applied CD — tracking next charge for spellId=" .. tostring(spellId))
            end
        end)
    end)

    Cooldowns._cdFrames[spellId] = cd
end

local function EnsureTrackedInitialized(spellId)
    if not spellId then return end
    if not Cooldowns._cdFrames[spellId] then
        CreateCDFrame(spellId)
    end
    if not Cooldowns._state[spellId] then
        Cooldowns._state[spellId] = { isOnCD = false, lastFiredAt = 0, seenStart = false, readyAt = nil, readyTimer = nil }
    end
end

local function GetCooldownReadyTriggerWatch()
	local tdb = ZSBT.db and ZSBT.db.char and ZSBT.db.char.triggers
	if not tdb or tdb.enabled ~= true then return nil end
	local items = tdb.items
	if type(items) ~= "table" then return nil end
	local watch
	for _, trig in ipairs(items) do
		if type(trig) == "table" and trig.enabled ~= false and trig.eventType == "COOLDOWN_READY" then
			local sid = trig.spellId
			if type(sid) == "number" and sid > 0 then
				watch = watch or {}
				watch[sid] = true
			end
		end
	end
	return watch
end

local function IsSpellWatched(spellId, tracked, trigWatch)
	if not spellId then return false end
	if type(tracked) == "table" and (tracked[spellId] or tracked[tostring(spellId)]) then
		return true
	end
	if type(trigWatch) == "table" and trigWatch[spellId] then
		return true
	end
	return false
end

------------------------------------------------------------------------
-- Cast Detection
------------------------------------------------------------------------
local function OnSpellcastSucceeded(_, event, unit, _, spellId)
    if unit ~= "player" then return end
    if not Cooldowns._enabled then return end
    if not spellId then return end

    local cdb = ZSBT.db and ZSBT.db.char and ZSBT.db.char.cooldowns
    local tracked = cdb and cdb.tracked
	local trigWatch = GetCooldownReadyTriggerWatch()
	if not IsSpellWatched(spellId, tracked, trigWatch) then return end
    EnsureTrackedInitialized(spellId)

    local name = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or tostring(spellId)
    local inCombat = (UnitAffectingCombat and UnitAffectingCombat("player")) == true
    CdDbg(2, "Cast: " .. tostring(name) .. " (ID:" .. tostring(spellId) .. ") inCombat=" .. tostring(inCombat))

	-- Charge spells are disabled (Midnight 12.0 limitation).
	if IsChargeSpell(spellId) == true then
		CdDbg(2, "Charge spell cooldown tracking disabled; ignoring spellId=" .. tostring(spellId))
		local st = Cooldowns._state[spellId]
		if st then
			SafeCancelTimer(st.readyTimer)
			st.readyTimer = nil
			st.readyAt = nil
			st.isOnCD = false
			st.seenStart = false
		end
		return
	end

    local state = Cooldowns._state[spellId] or {}
	state.castTime = GetTime()

	state.isOnCD = true
	state.seenStart = true
    Cooldowns._state[spellId] = state
    SafeCancelTimer(state.readyTimer)
    state.readyTimer = nil
    state.readyAt = nil

    -- Cast-based only: confirm cooldown start after cast (with retries) and schedule READY.
    C_Timer.After(0.15, function()
        if not Cooldowns._enabled then return end
        ConfirmCooldownStart(spellId, "CAST", 1)
    end)
end

------------------------------------------------------------------------
-- SPELL_UPDATE events: out-of-combat fallback
------------------------------------------------------------------------
local function OnSpellUpdate(source)
    if not Cooldowns._enabled then return end
    local cdb = ZSBT.db and ZSBT.db.char and ZSBT.db.char.cooldowns
    local tracked = cdb and cdb.tracked
	local trigWatch = GetCooldownReadyTriggerWatch()
	if type(tracked) ~= "table" and type(trigWatch) ~= "table" then return end

	local seen = {}
	if type(tracked) == "table" then
		for idKey, _ in pairs(tracked) do
			local spellId = tonumber(idKey)
			if spellId then
				seen[spellId] = true
				EnsureTrackedInitialized(spellId)
				local state = Cooldowns._state[spellId]

			-- Charge spells are disabled (Midnight 12.0 limitation).
			if IsChargeSpell(spellId) == true then
				if state then
					SafeCancelTimer(state.readyTimer)
					state.readyTimer = nil
					state.readyAt = nil
					state.isOnCD = false
					state.seenStart = false
				end
			else
				if C_Spell and C_Spell.GetSpellCooldown and state then
					local info, err = SafeGetSpellCooldown(spellId)
					if err == "error" then
						CdDbg(1, "OnSpellUpdate GetSpellCooldown ERROR spellId=" .. tostring(spellId) .. " src=" .. tostring(source))
						return
					end
					local dur = info and info.duration
					local start = info and info.startTime
					local isOnGCD = info and info.isOnGCD
					if state.isOnCD == true and state.seenStart == true then
						CdDbg(5, "OnSpellUpdate spellId=" .. tostring(spellId) .. " start=" .. tostring(start) .. " dur=" .. tostring(dur)
							.. " isOnGCD=" .. tostring(isOnGCD) .. " src=" .. tostring(source))
					end

					-- Cast-based only: never infer start from SPELL_UPDATE*.
					-- However, if we already observed a cast-based start, keep timers in sync.
					if state.isOnCD == true and state.seenStart == true and isOnGCD ~= true then
						if ZSBT.IsSafeNumber(dur) and ZSBT.IsSafeNumber(start) and dur and dur > MIN_REAL_CD_SEC and start and start > 0 then
							ScheduleReadyTimer(spellId, start, dur, source)
						end
					end
				end
			end
			end
		end
	end
	if type(trigWatch) == "table" then
		for spellId, _ in pairs(trigWatch) do
			if type(spellId) == "number" and seen[spellId] ~= true then
				EnsureTrackedInitialized(spellId)
				local state = Cooldowns._state[spellId]

				if IsChargeSpell(spellId) == true then
					if state then
						SafeCancelTimer(state.readyTimer)
						state.readyTimer = nil
						state.readyAt = nil
						state.isOnCD = false
						state.seenStart = false
					end
				else
					if C_Spell and C_Spell.GetSpellCooldown and state then
						local info, err = SafeGetSpellCooldown(spellId)
						if err == "error" then
							CdDbg(1, "OnSpellUpdate GetSpellCooldown ERROR spellId=" .. tostring(spellId) .. " src=" .. tostring(source))
							return
						end
						local dur = info and info.duration
						local start = info and info.startTime
						local isOnGCD = info and info.isOnGCD
						if state.isOnCD == true and state.seenStart == true then
							CdDbg(5, "OnSpellUpdate spellId=" .. tostring(spellId) .. " start=" .. tostring(start) .. " dur=" .. tostring(dur)
								.. " isOnGCD=" .. tostring(isOnGCD) .. " src=" .. tostring(source))
						end

						if state.isOnCD == true and state.seenStart == true and isOnGCD ~= true then
							if ZSBT.IsSafeNumber(dur) and ZSBT.IsSafeNumber(start) and dur and dur > MIN_REAL_CD_SEC and start and start > 0 then
								ScheduleReadyTimer(spellId, start, dur, source)
							end
						end
					end
				end
			end
		end
	end
end

local function ResyncCooldowns(source)
	if not Cooldowns._enabled then return end
	if not (C_Timer and C_Timer.After) then return end

	C_Timer.After(0.25, function()
		if not Cooldowns._enabled then return end

		local cdb = ZSBT.db and ZSBT.db.char and ZSBT.db.char.cooldowns
		local tracked = cdb and cdb.tracked
		local trigWatch = GetCooldownReadyTriggerWatch()
		if type(tracked) ~= "table" and type(trigWatch) ~= "table" then return end

		local function considerSpell(spellId)
			if type(spellId) ~= "number" then return end
			EnsureTrackedInitialized(spellId)
			local state = Cooldowns._state[spellId]
			if not state then return end

			-- Charge spells are disabled (Midnight 12.0 limitation).
			if IsChargeSpell(spellId) == true then
				SafeCancelTimer(state.readyTimer)
				state.readyTimer = nil
				state.readyAt = nil
				state.isOnCD = false
				state.seenStart = false
				return
			end

			if not (C_Spell and C_Spell.GetSpellCooldown) then return end
			local info, err = SafeGetSpellCooldown(spellId)
			if err == "error" then
				CdDbg(1, "ResyncCooldowns GetSpellCooldown ERROR spellId=" .. tostring(spellId) .. " src=" .. tostring(source))
				return
			end
			local dur = info and info.duration
			local start = info and info.startTime
			local isOnGCD = info and info.isOnGCD

			if isOnGCD == true then return end
			if ZSBT.IsSafeNumber(dur) and ZSBT.IsSafeNumber(start) and dur and dur > MIN_REAL_CD_SEC and start and start > 0 then
				state.isOnCD = true
				state.seenStart = true
				ScheduleReadyTimer(spellId, start, dur, source)
			end
		end

		if type(tracked) == "table" then
			for idKey, _ in pairs(tracked) do
				local sid = tonumber(idKey)
				if sid then considerSpell(sid) end
			end
		end
		if type(trigWatch) == "table" then
			for sid, _ in pairs(trigWatch) do
				considerSpell(sid)
			end
		end

		-- Also keep timers in sync for spells already marked on-cooldown.
		OnSpellUpdate(source)
	end)
end

------------------------------------------------------------------------
-- Enable / Disable
------------------------------------------------------------------------
function Cooldowns:Enable()
    if self._enabled then return end

    if not self._frame then
        self._frame = CreateFrame("Frame")
        self._frame:SetScript("OnEvent", function(_, event, ...)
            if event == "UNIT_SPELLCAST_SUCCEEDED" then
                OnSpellcastSucceeded(nil, event, ...)
            elseif event == "SPELL_UPDATE_CHARGES" then
                C_Timer.After(0.15, function()
                    if Cooldowns._enabled then OnSpellUpdate("CHARGES") end
                end)
            elseif event == "SPELL_UPDATE_COOLDOWN" then
                OnSpellUpdate("CD_EVENT")
			elseif event == "PLAYER_ENTERING_WORLD" then
				ResyncCooldowns("ENTERING_WORLD")
			elseif event == "PLAYER_REGEN_ENABLED" then
				ResyncCooldowns("REGEN_ENABLED")
			elseif event == "PLAYER_REGEN_DISABLED" then
				ResyncCooldowns("REGEN_DISABLED")
            end
        end)
    end

    self._frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    self._frame:RegisterEvent("SPELL_UPDATE_CHARGES")
    self._frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
	self._frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	self._frame:RegisterEvent("PLAYER_REGEN_ENABLED")
	self._frame:RegisterEvent("PLAYER_REGEN_DISABLED")

    self._state = {}
    self._enabled = true

    local cdb = ZSBT.db and ZSBT.db.char and ZSBT.db.char.cooldowns
    local tracked = cdb and cdb.tracked
	local trigWatch = GetCooldownReadyTriggerWatch()
	local names = {}
	local added = {}
	if type(tracked) == "table" then
		for idKey, _ in pairs(tracked) do
			local sid = tonumber(idKey)
			if sid then
				added[sid] = true
				local n = ZSBT.CleanSpellName and ZSBT.CleanSpellName(sid) or tostring(sid)
				names[#names + 1] = n
				CreateCDFrame(sid)
				self._state[sid] = { isOnCD = false, lastFiredAt = 0, seenStart = false, readyAt = nil, readyTimer = nil }
			end
		end
	end
	if type(trigWatch) == "table" then
		for sid, _ in pairs(trigWatch) do
			if type(sid) == "number" and added[sid] ~= true then
				local n = ZSBT.CleanSpellName and ZSBT.CleanSpellName(sid) or tostring(sid)
				names[#names + 1] = n
				CreateCDFrame(sid)
				self._state[sid] = { isOnCD = false, lastFiredAt = 0, seenStart = false, readyAt = nil, readyTimer = nil }
			end
		end
	end
	if #names > 0 then
		CdDebug("Enabled. Tracking: " .. table.concat(names, ", "))
	end
	ResyncCooldowns("ENABLE")
end

function Cooldowns:Disable()
    if not self._enabled then return end
    if self._frame then
        self._frame:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        self._frame:UnregisterEvent("SPELL_UPDATE_CHARGES")
        self._frame:UnregisterEvent("SPELL_UPDATE_COOLDOWN")
		self._frame:UnregisterEvent("PLAYER_ENTERING_WORLD")
		self._frame:UnregisterEvent("PLAYER_REGEN_ENABLED")
		self._frame:UnregisterEvent("PLAYER_REGEN_DISABLED")
    end
    for _, cd in pairs(self._cdFrames) do
        cd:SetCooldown(0, 0)
    end
	for _, state in pairs(self._state) do
		if type(state) == "table" then
			SafeCancelTimer(state.readyTimer)
		end
	end
    self._state = {}
    self._enabled = false
    CdDebug("Disabled.")
end
