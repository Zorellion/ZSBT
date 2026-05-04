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

local function FindActionSlotForSpell(spellId)
	if type(spellId) ~= "number" or spellId <= 0 then return nil end
	if type(GetActionInfo) ~= "function" then return nil end
	local hasGetMacroSpell = (type(GetMacroSpell) == "function")
	local hasFindButtons = (C_ActionBar and type(C_ActionBar.FindSpellActionButtons) == "function")
	-- Cache: spellId -> actionSlot (number) or false for not found
	Cooldowns._spellToActionSlot = Cooldowns._spellToActionSlot or {}
	local cached = Cooldowns._spellToActionSlot[spellId]
	if cached == false then return nil end
	if type(cached) == "number" then return cached end

	-- Prefer Blizzard-maintained lookup when available.
	if hasFindButtons then
		local okF, slots = pcall(C_ActionBar.FindSpellActionButtons, spellId)
		if okF and type(slots) == "table" then
			for i = 1, #slots do
				local slot = slots[i]
				if type(slot) == "number" and slot > 0 then
					local ok, atype, actionID = pcall(GetActionInfo, slot)
					if ok and atype == "spell" and actionID == spellId then
						Cooldowns._spellToActionSlot[spellId] = slot
						return slot
					end
				end
			end
		end
	end

	-- Scan typical action slot range. Use a wider range to cover extra/override bars.
	for slot = 1, 240 do
		local ok, atype, actionID = pcall(GetActionInfo, slot)
		if ok and atype == "spell" and actionID == spellId then
			Cooldowns._spellToActionSlot[spellId] = slot
			return slot
		elseif ok and atype == "macro" and hasGetMacroSpell and type(actionID) == "number" and actionID > 0 then
			local ok2, macroSpellId = pcall(GetMacroSpell, actionID)
			if ok2 and type(macroSpellId) == "number" and macroSpellId == spellId then
				Cooldowns._spellToActionSlot[spellId] = slot
				return slot
			end
		end
	end
	Cooldowns._spellToActionSlot[spellId] = false
	return nil
end

local function SafeGetActionCooldownForSpell(spellId)
	if type(GetActionCooldown) ~= "function" then return nil, "no_api" end
	local slot = FindActionSlotForSpell(spellId)
	if type(slot) ~= "number" then return nil, "no_slot" end
	local ok, start, dur, enabled, modRate = pcall(GetActionCooldown, slot)
	if not ok then return nil, "error" end
	-- Some clients return nil/secret in combat. Treat non-numeric as unreadable.
	if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(start) and ZSBT.IsSafeNumber(dur)) then
		return { startTime = start, duration = dur, isEnabled = enabled, modRate = modRate, _slot = slot }, "unreadable"
	end
	return { startTime = start, duration = dur, isEnabled = enabled, modRate = modRate, _slot = slot }, nil
end

local function DefaultButtonForActionSlot(slot)
	if type(slot) ~= "number" then return nil end
	local idx = nil
	local prefix = nil
	if slot >= 1 and slot <= 12 then
		prefix = "ActionButton"
		idx = slot
	elseif slot >= 13 and slot <= 24 then
		prefix = "MultiBarBottomLeftButton"
		idx = slot - 12
	elseif slot >= 25 and slot <= 36 then
		prefix = "MultiBarBottomRightButton"
		idx = slot - 24
	elseif slot >= 37 and slot <= 48 then
		prefix = "MultiBarRightButton"
		idx = slot - 36
	elseif slot >= 49 and slot <= 60 then
		prefix = "MultiBarLeftButton"
		idx = slot - 48
	end
	if not prefix or not idx then return nil end
	return _G[prefix .. tostring(idx)]
end

local function AnyButtonForActionSlot(slot)
	if type(slot) ~= "number" or slot <= 0 then return nil end
	Cooldowns._slotToButton = Cooldowns._slotToButton or {}
	local cached = Cooldowns._slotToButton[slot]
	if cached == false then return nil end
	if type(cached) == "table" then
		return cached
	end

	if type(EnumerateFrames) ~= "function" then
		Cooldowns._slotToButton[slot] = false
		return nil
	end
	if type(debugprofilestop) ~= "function" then
		Cooldowns._slotToButton[slot] = false
		return nil
	end

	local startMs = debugprofilestop()
	local f = EnumerateFrames()
	while f do
		-- Keep scan bounded to avoid hitching.
		if (debugprofilestop() - startMs) >= 5.0 then
			break
		end
		local okAttr, a = pcall(function()
			if f and f.GetAttribute then
				return f:GetAttribute("action")
			end
			return nil
		end)
		if okAttr and a == slot then
			Cooldowns._slotToButton[slot] = f
			return f
		end
		f = EnumerateFrames(f)
	end

	Cooldowns._slotToButton[slot] = false
	return nil
end

local function EnsureActionButtonHook(spellId)
	if type(spellId) ~= "number" or spellId <= 0 then return end
	Cooldowns._actionBtnHooks = Cooldowns._actionBtnHooks or {}
	if Cooldowns._actionBtnHooks[spellId] then return end
	local slot = FindActionSlotForSpell(spellId)
	if type(slot) ~= "number" then return end
	local btn = DefaultButtonForActionSlot(slot)
	if not btn then
		btn = AnyButtonForActionSlot(slot)
	end
	if not btn then return end
	local cds = {
		btn.cooldown,
		btn.chargeCooldown,
		btn.lossOfControlCooldown,
	}
	local hookedAny = false
	for i = 1, #cds do
		local cd = cds[i]
		if cd and type(cd.HookScript) == "function" then
			hookedAny = true
			pcall(function()
				cd:HookScript("OnCooldownDone", function()
					if not Cooldowns._enabled then return end
					local st = Cooldowns._state and Cooldowns._state[spellId]
					if not st or st.isOnCD ~= true or st.seenStart ~= true then return end
					st.isOnCD = false
					st.seenStart = false
					if Addon and Addon.Dbg then
						Addon:Dbg("cooldowns", 4, "ActionBtn OnCooldownDone spellId=" .. tostring(spellId) .. " slot=" .. tostring(slot))
					else
						local dbgLevel = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("cooldowns"))
							or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.cooldownsDebugLevel or 0)
						if dbgLevel and dbgLevel >= 4 and Addon and Addon.Print then
							Addon:Print("ActionBtn OnCooldownDone spellId=" .. tostring(spellId) .. " slot=" .. tostring(slot))
						end
					end
					FireReady(spellId, "ACTION_BTN")
				end)
			end)
		end
	end
	if not hookedAny then return end

	Cooldowns._actionBtnHooks[spellId] = { slot = slot, btn = btn, cds = cds }
	if Addon and Addon.Dbg then
		Addon:Dbg("cooldowns", 4, "ActionBtnHook spellId=" .. tostring(spellId) .. " slot=" .. tostring(slot) .. " btn=" .. tostring(btn and btn.GetName and btn:GetName()))
	else
		local dbgLevel = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("cooldowns"))
			or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.cooldownsDebugLevel or 0)
		if dbgLevel and dbgLevel >= 4 and Addon and Addon.Print then
			Addon:Print("ActionBtnHook spellId=" .. tostring(spellId) .. " slot=" .. tostring(slot) .. " btn=" .. tostring(btn and btn.GetName and btn:GetName()))
		end
	end
end

local function SafeCancelTimer(t)
	if not t then return end
	if type(t) == "table" and type(t.Cancel) == "function" then
		pcall(function() t:Cancel() end)
	end
end

local function SafeCancelTicker(t)
	if not t then return end
	if type(t) == "table" and type(t.Cancel) == "function" then
		pcall(function() t:Cancel() end)
	end
end

local CdDbg
local FireReady
local ScheduleReadyTimer

local function StartUsablePoll(spellId, source)
	if not Cooldowns._enabled then return end
	local st = Cooldowns._state and Cooldowns._state[spellId]
	if not st then return end
	if st._usablePollTicker then return end
	CdDbg(2, "StartUsablePoll spellId=" .. tostring(spellId) .. " src=" .. tostring(source))

	st._pollSawOnCd = false
	st._pollSawUnreadable = false
	st._pollStartedAt = (GetTime and GetTime()) or 0
	st._usablePollTicker = C_Timer.NewTicker(0.25, function()
		if not Cooldowns._enabled then
			SafeCancelTicker(st._usablePollTicker)
			st._usablePollTicker = nil
			return
		end
		local cur = Cooldowns._state and Cooldowns._state[spellId]
		if not cur or cur.isOnCD ~= true or cur.seenStart ~= true then
			SafeCancelTicker(st._usablePollTicker)
			st._usablePollTicker = nil
			return
		end

		local tNow = (GetTime and GetTime()) or 0
		local confirmedReady = false
		local sawAnySignal = false

		-- Prefer cooldown completion signals over IsUsableSpell, because IsUsableSpell
		-- can be false due to resource/stance even when the cooldown is finished.
		local pollAge = 0
		if st._pollStartedAt and type(st._pollStartedAt) == "number" and tNow then
			pollAge = tNow - st._pollStartedAt
		end
		local inCombatNow = (InCombatLockdown and InCombatLockdown()) or false
		local combatFlipAt = Cooldowns._combatFlipAt or 0
		local combatFlipAge = 999
		if type(combatFlipAt) == "number" and combatFlipAt > 0 then
			combatFlipAge = tNow - combatFlipAt
		end
		local allowIsActiveReady = (inCombatNow == true and combatFlipAge > 1.0)

		-- Spell cooldown (if readable)
		if C_Spell and type(C_Spell.GetSpellCooldown) == "function" then
			local okC, info = pcall(C_Spell.GetSpellCooldown, spellId)
			if okC and type(info) == "table" then
				local start = info.startTime
				local dur = info.duration
				local isActive = info.isActive
				-- Some builds expose isActive even when start/duration are secret.
				-- Treat isActive==false as readiness only when firmly in combat (regen transitions can glitch it).
				if isActive == false and allowIsActiveReady == true then
					sawAnySignal = true
					local contradicts = false
					if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(start) and ZSBT.IsSafeNumber(dur) and start and dur
						and start > 0 and dur > 0 then
						st._pollSawOnCd = true
						local okCmp, stillOnCd = pcall(function()
							return tNow < (start + dur - 0.05)
						end)
						if okCmp and stillOnCd == true then
							contradicts = true
						end
					end
					if contradicts ~= true then
						if (st._pollSawOnCd == true or st._pollSawUnreadable == true) and pollAge >= 1.0 then
							confirmedReady = true
						end
					end
				end
				if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(start) and ZSBT.IsSafeNumber(dur) and start and dur then
					sawAnySignal = true
					if start > 0 and dur > 0 then
						st._pollSawOnCd = true
						local okCmp, isReady = pcall(function()
							return tNow >= (start + dur - 0.05)
						end)
						if okCmp and isReady == true and st._pollSawOnCd == true then
							confirmedReady = true
						end
					end
				else
					-- Unreadable/secret values: treat as evidence the cooldown is active.
					if st._pollSawUnreadable ~= true then
						st._pollSawUnreadable = true
					end
				end
			end
		elseif type(GetSpellCooldown) == "function" then
			local okL, start, dur = pcall(GetSpellCooldown, spellId)
			if okL and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(start) and ZSBT.IsSafeNumber(dur) and start and dur then
				sawAnySignal = true
				if start > 0 and dur > 0 then
					st._pollSawOnCd = true
					local okCmp, isReady = pcall(function()
						return tNow >= (start + dur - 0.05)
					end)
					if okCmp and isReady == true and st._pollSawOnCd == true then
						confirmedReady = true
					end
				end
			else
				-- Unreadable/secret values: treat as evidence the cooldown is active.
				if st._pollSawUnreadable ~= true then
					st._pollSawUnreadable = true
				end
			end
		end

		-- Action cooldown (if the spell is on a bar/macro). This often remains authoritative.
		if confirmedReady ~= true then
			local aInfo, aErr
			if type(SafeGetActionCooldownForSpell) == "function" then
				aInfo, aErr = SafeGetActionCooldownForSpell(spellId)
				-- If the slot exists but cooldown is unreadable, drop the cached slot and retry next tick.
				if aErr == "unreadable" then
					if st._pollSawUnreadable ~= true then
						st._pollSawUnreadable = true
					end
					Cooldowns._spellToActionSlot = Cooldowns._spellToActionSlot or {}
					Cooldowns._spellToActionSlot[spellId] = nil
				end
			else
				aInfo, aErr = nil, "no_fn"
			end
			local aStart = aInfo and aInfo.startTime
			local aDur = aInfo and aInfo.duration
			if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(aStart) and ZSBT.IsSafeNumber(aDur) and aStart and aDur then
				sawAnySignal = true
				if aStart > 0 and aDur > 0 and tNow >= (aStart + aDur - 0.05) then
					confirmedReady = true
				end
			else
				-- Action cooldown unavailable/unreadable; keep polling.
				local dbgLevel = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("cooldowns"))
					or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.cooldownsDebugLevel or 0)
				if dbgLevel and dbgLevel >= 4 then
					cur._lastActionMissAt = cur._lastActionMissAt or 0
					if (tNow - cur._lastActionMissAt) >= 1.0 then
						cur._lastActionMissAt = tNow
						CdDbg(4, "UsablePoll actionCD miss spellId=" .. tostring(spellId)
							.. " err=" .. tostring(aErr)
							.. " slot=" .. tostring(aInfo and aInfo._slot))
					end
				end
			end
		end

		-- NOTE: Do not use the action button Cooldown widget as readiness signal.
		-- In some builds it can return secret/unstable values (especially around regen transitions).

		-- Secondary hint: usability. NOTE: IsUsableSpell does NOT indicate cooldown state;
		-- it only reflects resource/stance/etc. Do not use it to confirm readiness.
		if type(IsUsableSpell) == "function" then
			local okU, u1 = pcall(IsUsableSpell, spellId)
			if okU and u1 == true then
				sawAnySignal = true
			end
		end
		if sawAnySignal ~= true then
			-- Nothing readable yet; keep polling.
		end

		if confirmedReady == true then
			SafeCancelTicker(st._usablePollTicker)
			st._usablePollTicker = nil
			cur.isOnCD = false
			cur.seenStart = false
			pcall(function()
				if FireReady then
					CdDbg(2, "UsablePoll READY spellId=" .. tostring(spellId) .. " src=" .. tostring(source))
					FireReady(spellId, tostring(source or "USABLE_POLL"))
				end
			end)
		end
	end)
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
			Addon:Print(SafeToString(msg))
		end)
	end
end

CdDbg = function(requiredLevel, msg)
	if not Addon then return end
	-- Legacy cooldownsDebugLevel used 1..5 as increasing verbosity.
	-- Map to new severity/verbosity scale: 1-2=INFO(3), 3=DEBUG(4), 4-5=TRACE(5)
	local map = { [1] = 3, [2] = 3, [3] = 4, [4] = 5, [5] = 5 }
	local lvl = map[tonumber(requiredLevel) or 0] or 4
	if Addon.Dbg then
		Addon:Dbg("cooldowns", lvl, msg)
		return
	end
	local db = (Addon and Addon.db) or ZSBT.db
	local level = db and db.profile and db.profile.diagnostics
		and db.profile.diagnostics.cooldownsDebugLevel or 0
	level = tonumber(level) or 0
	if level and level >= requiredLevel then
		pcall(function()
			Addon:Print(SafeToString(msg))
		end)
	end
end

local function Stamp()
	local gt = (GetTime and GetTime()) or 0
	local ms = math.floor((gt - math.floor(gt)) * 1000 + 0.5)
	local st = (GetServerTime and GetServerTime()) or nil
	if type(st) == "number" then
		return (date("%H:%M:%S", st) .. "." .. string.format("%03d", ms) .. " gt=" .. string.format("%.3f", gt))
	end
	return ("gt=" .. string.format("%.3f", gt))
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
FireReady = function(spellId, method)
	if not spellId then return end
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
		SafeCancelTicker(state._dbgReadyTicker)
		state._dbgReadyTicker = nil
		SafeCancelTicker(state._usablePollTicker)
		state._usablePollTicker = nil
	end

    	local spellName = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId)
		or (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellId))
		or ("Spell #" .. spellId)

	local tNow = (GetTime and GetTime()) or 0
	local castAt = state and state.castTime
	local elapsed = (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(castAt) and castAt and castAt > 0) and (tNow - castAt) or nil

	CdDbg(1, "ts=" .. Stamp() .. " " .. spellName .. " -> READY! (" .. method .. ")")
	if elapsed ~= nil then
		CdDbg(1, "ts=" .. Stamp() .. " " .. spellName .. " READY elapsed=" .. string.format("%.3f", elapsed)
			.. "s method=" .. tostring(method)
			.. " castTs=" .. SafeToString(state and state.castStamp)
			.. " castGt=" .. SafeToString(state and state.castTime))
	end
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
	pcall(function()
		local LibStub = _G.LibStub
		if not LibStub or type(LibStub.GetLibrary) ~= "function" then return end
		local lcp = LibStub:GetLibrary("LibCombatPulse-1.0", true)
		if not (lcp and lcp.Emit) then return end
		lcp:Emit({
			kind = "cooldown_ready",
			eventType = "COOLDOWN_READY",
			direction = "outgoing",
			spellId = spellId,
			spellName = spellName,
			method = method,
			timestamp = GetTime(),
			confidence = "HIGH",
		})
	end)
end

ScheduleReadyTimer = function(spellId, startTime, duration, source)
    local state = Cooldowns._state[spellId]
    if not state then return end
    if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(startTime) and ZSBT.IsSafeNumber(duration)) then return end
    if not startTime or startTime <= 0 then return end
    if not duration or duration <= 0 then return end

    	local readyAt = startTime + duration
	local delay = readyAt - GetTime()
	if not (delay and delay > 0) then return end

	-- Detect a cooldown restart. If a new startTime is meaningfully later than what
	-- we previously scheduled, we must reschedule even if it would move READY later.
	-- Otherwise a stale timer from a prior cooldown cycle can fire early.
	local isRestart = false
	if state._schedStart and startTime and (startTime > (state._schedStart + 0.25)) then
		isRestart = true
	end

	-- If we already have a ready timer running, never allow updates to move READY later.
	-- Only reschedule when the new computed readyAt is meaningfully earlier.
	if state.readyTimer and state.readyAt and not isRestart then
		-- Later or essentially the same: keep existing timer.
		if readyAt >= (state.readyAt - 0.25) then
			return
		end
	end

    SafeCancelTimer(state.readyTimer)
	SafeCancelTicker(state._dbgReadyTicker)
	state._dbgReadyTicker = nil
    	state.readyAt = readyAt
	state.readySource = source
	state._schedStart = startTime
	state._schedDur = duration
	CdDbg(3, "ScheduleReadyTimer spellId=" .. tostring(spellId) .. " start=" .. tostring(startTime) .. " dur=" .. tostring(duration)
        .. " readyAt=" .. string.format("%.3f", readyAt) .. " delay=" .. string.format("%.3f", delay) .. " src=" .. tostring(source))

	-- Debug countdown ticker: prints remaining seconds until READY (cddebug>=4).
	local dbgLevel = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("cooldowns"))
		or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.cooldownsDebugLevel or 0)
	if dbgLevel and dbgLevel >= 4 and C_Timer and C_Timer.NewTicker then
		local ticker
		local lastTickAt
		ticker = C_Timer.NewTicker(1.0, function()
			if not Cooldowns._enabled then
				SafeCancelTicker(ticker)
				return
			end
			if dbgLevel >= 5 then
				local n = (GetTime and GetTime()) or 0
				if lastTickAt then
					CdDbg(5, "ts=" .. Stamp() .. " READY TICK dt=" .. string.format("%.3f", (n - lastTickAt)) .. "s spellId=" .. tostring(spellId))
				end
				lastTickAt = n
			end
			local st = Cooldowns._state[spellId]
			if not st or st.isOnCD ~= true or st.seenStart ~= true or not st.readyAt then
				SafeCancelTicker(ticker)
				return
			end
			local remain = (st.readyAt - ((GetTime and GetTime()) or 0))
			if remain < 0 then remain = 0 end
			CdDbg(4, "ts=" .. Stamp() .. " READY T-" .. tostring(math.floor(remain + 0.5)) .. "s spellId=" .. tostring(spellId) .. " src=" .. tostring(source))
			if remain <= 0.01 then
				SafeCancelTicker(ticker)
			end
		end)
		state._dbgReadyTicker = ticker
	end
	state.readyTimer = C_Timer and C_Timer.NewTimer and C_Timer.NewTimer(delay, function()
		if not Cooldowns._enabled then return end
		local st = Cooldowns._state[spellId]
		if not st or st.isOnCD ~= true or st.seenStart ~= true then return end
		local tNow = (GetTime and GetTime()) or 0
		if CdDbg then
			local rAt = st.readyAt
			if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(rAt) and rAt and rAt > 0 then
				CdDbg(3, "ts=" .. Stamp() .. " READY drift spellId=" .. tostring(spellId)
					.. " now=" .. string.format("%.3f", tNow)
					.. " readyAt=" .. string.format("%.3f", rAt)
					.. " driftSec=" .. string.format("%.3f", (tNow - rAt))
					.. " src=" .. tostring(source))
			end
		end

		-- BASE_CD fallback: treat timer expiry as ready.
		if source == "BASE_CD" then
			SafeCancelTicker(st._dbgReadyTicker)
			st._dbgReadyTicker = nil
			st.isOnCD = false
			st.seenStart = false
			CdDbg(2, "BASE_CD timer expired; firing READY spellId=" .. tostring(spellId))
			FireReady(spellId, "BASE_CD")
			return
		end

		-- CHARGE timers are scheduled from recharge info when readable.
		-- Treat timer expiry as charge regained; cooldown confirmation may be secret.
		if source == "CHARGE" then
			SafeCancelTicker(st._dbgReadyTicker)
			st._dbgReadyTicker = nil
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
			SafeCancelTicker(st._dbgReadyTicker)
			st._dbgReadyTicker = nil
			st.isOnCD = false
			st.seenStart = false
			FireReady(spellId, tostring(source or "TIMER"))
			return
		end

		CdDbg(2, "Timer expired but cooldown not confirmed ready for spellId=" .. tostring(spellId)
			.. " dur=" .. tostring(dur) .. " start=" .. tostring(start) .. " src=" .. tostring(source))
	end) or nil

	CdDbg(2, "Scheduled READY in " .. string.format("%.2f", delay) .. "s via " .. tostring(source) .. " for spellId=" .. tostring(spellId))
	-- Under-the-hood fallback: poll usability so READY can fire even if cast timestamps/events are delayed.
	if source == "BASE_CD" or source == "ACTION_CD" then
		EnsureActionButtonHook(spellId)
		StartUsablePoll(spellId, source)
	end

end

-- Polling fallback: under heavy combat load some clients can delay C_Timer callbacks.
-- Pulse_Engine can call this frequently to fire overdue READY events.
function Cooldowns:CheckReadyTimers(tNow)
	if not self._enabled then return end
	tNow = (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(tNow) and tNow) or (GetTime and GetTime()) or 0
	local stTbl = self._state
	if type(stTbl) ~= "table" then return end
	for sid, st in pairs(stTbl) do
		if type(sid) == "number" and type(st) == "table" then
			local readyAt = st.readyAt
			if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(readyAt) and readyAt > 0 then
				if st.isOnCD == true and st.seenStart == true and tNow >= readyAt then
					-- Avoid double-firing if we already fired very recently.
					local last = st.lastFiredAt
					if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(last) and (tNow - last) < 0.50) then
						st.isOnCD = false
						st.seenStart = false
						CdDbg(3, "READY drift spellId=" .. tostring(sid)
							.. " now=" .. string.format("%.3f", tNow)
							.. " readyAt=" .. string.format("%.3f", readyAt)
							.. " driftSec=" .. string.format("%.3f", (tNow - readyAt))
							.. " src=POLL")
						CdDbg(3, "Polling READY: firing spellId=" .. tostring(sid) .. " overdue=" .. string.format("%.3f", (tNow - readyAt)))
						FireReady(sid, "POLL")
					end
				end
			end
		end
	end
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
local EnsureTrackedInitialized

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

	-- Always try to anchor to action bar cooldown if present.
	-- This is the authoritative timing the player sees on the button swipe.
	local aInfo, aErr = SafeGetActionCooldownForSpell(spellId)
	local aStart = aInfo and aInfo.startTime
	local aDur = aInfo and aInfo.duration
	if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(aStart) and ZSBT.IsSafeNumber(aDur)
		and aStart and aStart > 0 and aDur and aDur > MIN_REAL_CD_SEC then
		local ct = state and state.castTime
		local delta = (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(ct) and ct and (ct - aStart)) or nil
		CdDbg(2, "ConfirmCooldownStart actionCD spellId=" .. tostring(spellId)
			.. " slot=" .. SafeToString(aInfo and aInfo._slot)
			.. " start=" .. SafeToString(aStart)
			.. " dur=" .. SafeToString(aDur)
			.. " castMinusAction=" .. SafeToString(delta)
			.. " err=" .. SafeToString(aErr)
			.. " attempt=" .. tostring(attempt))

		ScheduleReadyTimer(spellId, aStart, aDur, "ACTION_CD")
		EnsureTrackedInitialized(spellId)
		local applied = ApplyCooldownToFrame and ApplyCooldownToFrame(spellId, aStart, aDur, aInfo and aInfo.modRate, "ACTION_CD")
		CdDbg(3, "ConfirmCooldownStart actionCD appliedFrame=" .. tostring(applied) .. " spellId=" .. tostring(spellId))
		return
	elseif attempt == 1 then
		CdDbg(3, "ConfirmCooldownStart actionCD unavailable spellId=" .. tostring(spellId)
			.. " err=" .. SafeToString(aErr)
			.. " slot=" .. SafeToString(aInfo and aInfo._slot)
			.. " start=" .. SafeToString(aStart)
			.. " dur=" .. SafeToString(aDur))
	end

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
    local useStart, useDur, useModRate = start, dur, cModRate
    if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(useStart) and ZSBT.IsSafeNumber(useDur)) then
        useStart, useDur, useModRate = lStart, lDur, nil
    end

    if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(useStart) and ZSBT.IsSafeNumber(useDur)
        and useStart and useStart > 0 and useDur and useDur > MIN_REAL_CD_SEC then
        ScheduleReadyTimer(spellId, useStart, useDur, source)
        EnsureTrackedInitialized(spellId)
        local applied = ApplyCooldownToFrame and ApplyCooldownToFrame(spellId, useStart, useDur, useModRate, tostring(source or "SPELL_CD"))
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
			EnsureTrackedInitialized(spellId)
			local applied = ApplyCooldownToFrame and ApplyCooldownToFrame(spellId, ct, baseSec, nil, "BASE_CD")
			CdDbg(3, "ConfirmCooldownStart baseCD appliedFrame=" .. tostring(applied) .. " spellId=" .. tostring(spellId))
			state.waitingCharge = true
			-- IMPORTANT: Do not return here. In some clients the real cooldown start/duration
			-- becomes readable shortly after the cast. Allow the retry loop to continue so
			-- ScheduleReadyTimer can reschedule earlier (never later) to match the true cooldown.
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

--- Apply cooldown to the hidden CooldownFrame.
------------------------------------------------------------------------
ApplyCooldownToFrame = function(spellId, overrideStart, overrideDur, overrideModRate, overrideSource)
    local cd = Cooldowns._cdFrames[spellId]
    if not cd then return false end

    -- Allow caller-provided timing (e.g. action bar cooldown) so we can drive
    -- OnCooldownDone even when spell cooldown APIs are secret/unreadable.
    if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(overrideStart) and ZSBT.IsSafeNumber(overrideDur)
        and overrideStart and overrideStart > 0 and overrideDur and overrideDur > 0 then
        if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(overrideModRate) and overrideModRate then
            cd:SetCooldown(overrideStart, overrideDur, overrideModRate)
        else
            cd:SetCooldown(overrideStart, overrideDur)
        end
        CdDbg(3, "Applied OVERRIDE CD to frame for spellId=" .. tostring(spellId)
            .. " start=" .. tostring(overrideStart) .. " dur=" .. tostring(overrideDur)
            .. " src=" .. tostring(overrideSource))
        return true
    end

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
            local applied = ApplyCooldownToFrame and ApplyCooldownToFrame(spellId)
            if applied then
                st.isOnCD = true
                CdDbg(2, "Re-applied CD — tracking next charge for spellId=" .. tostring(spellId))
            end
        end)
    end)

    Cooldowns._cdFrames[spellId] = cd
end

EnsureTrackedInitialized = function(spellId)
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
    CdDbg(2, "ts=" .. Stamp() .. " Cast: " .. tostring(name) .. " (ID:" .. tostring(spellId) .. ") inCombat=" .. tostring(inCombat))

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
	state.castStamp = Stamp()

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
			elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "ACTIONBAR_UPDATE_COOLDOWN" or event == "SPELLS_CHANGED" or event == "UPDATE_MACROS" then
				-- Action bar layout can change; invalidate spell->slot cache for action cooldown fallback.
				Cooldowns._spellToActionSlot = nil
			elseif event == "PLAYER_ENTERING_WORLD" then
				ResyncCooldowns("ENTERING_WORLD")
			elseif event == "PLAYER_REGEN_ENABLED" then
				Cooldowns._playerInCombat = false
				Cooldowns._combatFlipAt = (GetTime and GetTime()) or 0
				ResyncCooldowns("REGEN_ENABLED")
			elseif event == "PLAYER_REGEN_DISABLED" then
				Cooldowns._playerInCombat = true
				Cooldowns._combatFlipAt = (GetTime and GetTime()) or 0
				ResyncCooldowns("REGEN_DISABLED")
            end
        end)
    end

    self._frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    self._frame:RegisterEvent("SPELL_UPDATE_CHARGES")
    self._frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
	pcall(function() self._frame:RegisterEvent("ACTIONBAR_SLOT_CHANGED") end)
	pcall(function() self._frame:RegisterEvent("ACTIONBAR_UPDATE_COOLDOWN") end)
	pcall(function() self._frame:RegisterEvent("SPELLS_CHANGED") end)
	pcall(function() self._frame:RegisterEvent("UPDATE_MACROS") end)
	self._frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	self._frame:RegisterEvent("PLAYER_REGEN_ENABLED")
	self._frame:RegisterEvent("PLAYER_REGEN_DISABLED")
	Cooldowns._playerInCombat = (InCombatLockdown and InCombatLockdown()) or false
	Cooldowns._combatFlipAt = (GetTime and GetTime()) or 0

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
