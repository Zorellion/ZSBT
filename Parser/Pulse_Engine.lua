local ADDON_NAME, ZSBT = ...

ZSBT.Parser = ZSBT.Parser or {}
ZSBT.Parser.PulseEngine = ZSBT.Parser.PulseEngine or {}
local Engine = ZSBT.Parser.PulseEngine

local StateManager = ZSBT.Parser.StateManager
local CorrelationLogic = ZSBT.Parser.CorrelationLogic

local Addon = ZSBT.Addon

local LibStub = _G.LibStub
local _LCP = nil
local function getLCP()
	if _LCP and _LCP.Emit then return _LCP end
	if not LibStub or type(LibStub.GetLibrary) ~= "function" then return nil end
	local lib = LibStub:GetLibrary("LibCombatPulse-1.0", true)
	if lib and lib.Emit then
		_LCP = lib
		return lib
	end
	return nil
end

Engine._enabled = Engine._enabled or false
Engine._pulseInterval = 0.020 -- 20ms target pulse (phase 1 requirement)
Engine._accumulator = Engine._accumulator or 0
Engine._bucket = Engine._bucket or {}
Engine._frame = Engine._frame or nil
Engine._maxBucketSize = Engine._maxBucketSize or 120
Engine._maxWorkPerPulse = Engine._maxWorkPerPulse or 80
Engine._qHead = Engine._qHead or 1
Engine._qTail = Engine._qTail or 0
Engine._qCount = Engine._qCount or 0
Engine._dbgLastHeartbeatAt = Engine._dbgLastHeartbeatAt or 0
Engine._dbgLastCollectAt = Engine._dbgLastCollectAt or 0

Engine._petMerge = Engine._petMerge or {
	active = false,
	sum = 0,
	count = 0,
	deadline = 0,
	prefix = nil,
	aggMode = nil,
	area = nil,
	isCrit = false,
	school = nil,
}

local function safeUnitName(unit)
	if not unit then return nil end

	local ok, value = pcall(UnitName, unit)
	if not ok then return nil end
	if type(value) ~= "string" then return nil end
	if ZSBT and ZSBT.IsSafeString and ZSBT.IsSafeString(value) then
		if value == "" then return nil end
		return value
	end
	return value
end

local function now()
	return (GetTime and GetTime()) or 0
end

local function isDamageMeterOutgoingEnabled()
	return ZSBT
		and ZSBT.db
		and ZSBT.db.profile
		and ZSBT.db.profile.general
		and ZSBT.db.profile.general.damageMeterOutgoingFallback == true
end

local function isDamageMeterIncomingEnabled()
	return ZSBT
		and ZSBT.db
		and ZSBT.db.profile
		and ZSBT.db.profile.general
		and ZSBT.db.profile.general.damageMeterIncomingFallback == true
end

local function canUseDamageMeter()
	return (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)
		and C_DamageMeter
		and C_DamageMeter.GetCombatSessionSourceFromType
		and Enum
		and Enum.DamageMeterType
		and Enum.DamageMeterType.DamageDone
end

local function canUseDamageMeterIncoming()
	return canUseDamageMeter()
		and Enum
		and Enum.DamageMeterType
		and Enum.DamageMeterType.DamageTaken
end

local function shouldPollDamageMeterOutgoing()
	if not isDamageMeterOutgoingEnabled() then return false end
	if not (ZSBT.Core and ZSBT.Core.ShouldRestrictOutgoingFallback and ZSBT.Core:ShouldRestrictOutgoingFallback()) then
		return false
	end
	if not canUseDamageMeter() then return false end
	if InCombatLockdown and (not InCombatLockdown()) then return false end
	return true
end

local function shouldPollDamageMeterIncoming()
	if not isDamageMeterIncomingEnabled() then return false end
	if not (ZSBT.Core and ZSBT.Core.ShouldRestrictOutgoingFallback and ZSBT.Core:ShouldRestrictOutgoingFallback()) then
		return false
	end
	if not canUseDamageMeterIncoming() then return false end
	if InCombatLockdown and (not InCombatLockdown()) then return false end
	return true
end

local function wipeTable(t)
	for k in pairs(t) do
		t[k] = nil
	end
end

local function Dbg5(prefix, msg)
	if Addon and Addon.Dbg then
		Addon:Dbg("diagnostics", 5, prefix, msg)
		return
	end
	local dbg = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("diagnostics"))
		or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.debugLevel or 0)
	if dbg >= 5 and ZSBT.Addon and ZSBT.Addon.Print then
		local function safeToString(v)
			if v == nil then return "" end
			if type(v) == "string" then
				if ZSBT and ZSBT.IsSafeString and ZSBT.IsSafeString(v) then
					return v
				end
				return "<secret>"
			end
			local ok, s = pcall(tostring, v)
			if ok and type(s) == "string" then
				if ZSBT and ZSBT.IsSafeString and ZSBT.IsSafeString(s) then
					return s
				end
				return "<secret>"
			end
			return "<secret>"
		end
		local p = safeToString(prefix)
		local m = safeToString(msg)
		if m ~= "" then
			ZSBT.Addon:Print(p .. " " .. m)
		else
			ZSBT.Addon:Print(p)
		end
	end
end

function Engine:_pollDamageMeterIncoming()
	local tNow = now()
	if not shouldPollDamageMeterIncoming() then
		return
	end
	if self:_shouldSuppressIncomingDamageMeterEmit(tNow) then
		return
	end

	-- Rate limit: damage taken is often bursty; avoid spamming reconstructed ticks.
	local lastEmit = self._dmgMeterIncomingLastEmitAt or 0
	local dtEmit = tNow - lastEmit
	if dtEmit >= 0 and dtEmit <= 0.20 then
		return
	end

	local playerGUID = UnitGUID and UnitGUID("player") or nil
	if type(playerGUID) ~= "string" then
		return
	end
	if ZSBT and ZSBT.IsSafeString and not ZSBT.IsSafeString(playerGUID) then
		return
	end

	local ok, sessionSource = pcall(C_DamageMeter.GetCombatSessionSourceFromType, 0, Enum.DamageMeterType.DamageTaken, playerGUID)
	if not ok or not sessionSource then
		return
	end

	local total = nil
	pcall(function()
		-- Retail 12.x has changed shapes a few times; try common fields safely.
		if type(sessionSource.totalAmount) ~= "nil" then
			total = sessionSource.totalAmount
		elseif type(sessionSource.total) ~= "nil" then
			total = sessionSource.total
		elseif type(sessionSource.totalDamage) ~= "nil" then
			total = sessionSource.totalDamage
		end
	end)

	local totalNum = nil
	if ZSBT and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(total) then
		totalNum = total
	else
		local n = tonumber(total)
		if ZSBT and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(n) then
			totalNum = n
		end
	end
	if not (ZSBT and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(totalNum)) then
		return
	end
	if totalNum <= 0 then
		return
	end

	self._dmgMeterIncomingLastTotal = self._dmgMeterIncomingLastTotal or 0
	local lastTotal = self._dmgMeterIncomingLastTotal
	if not (ZSBT and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(lastTotal)) then
		lastTotal = 0
		self._dmgMeterIncomingLastTotal = 0
	end
	local delta = totalNum - lastTotal
	if delta < 0 then
		delta = totalNum
	end
	if delta <= 0 then
		self._dmgMeterIncomingLastTotal = totalNum
		return
	end

	-- Suppress tiny deltas; they are usually rounding/periodic noise.
	if delta < 250 then
		self._dmgMeterIncomingLastTotal = totalNum
		return
	end

	self._dmgMeterIncomingLastTotal = totalNum
	self._dmgMeterIncomingLastEmitAt = tNow
	self:_noteIncomingSignal(tNow)

	self:collect("INCOMING_DAMAGE", {
		timestamp = tNow,
		unit = "player",
		amount = delta,
		amountText = tostring(math.floor(delta + 0.5)),
		isCrit = false,
		isSecret = false,
		school = nil,
		amountSource = "DAMAGE_METER_INCOMING",
	})
end

function Engine:_noteOutgoingSignal(tNow)
	self._lastOutgoingSignalAt = tNow or now()
end

function Engine:_shouldSuppressDamageMeterEmit(tNow)
	local last = self._lastOutgoingSignalAt or 0
	local dt = (tNow or now()) - last
	return dt >= 0 and dt <= 0.35
end

function Engine:_noteIncomingSignal(tNow)
	self._lastIncomingSignalAt = tNow or now()
end

function Engine:_shouldSuppressIncomingDamageMeterEmit(tNow)
	local last = self._lastIncomingSignalAt or 0
	local dt = (tNow or now()) - last
	return dt >= 0 and dt <= 0.35
end

function Engine:_pollDamageMeterOutgoing()
	local tNow = now()
	if not shouldPollDamageMeterOutgoing() then
		return
	end
	if self:_shouldSuppressDamageMeterEmit(tNow) then
		return
	end

	local lastPoll = self._dmgMeterOutgoingLastPollAt or 0
	local dtPoll = tNow - lastPoll
	if dtPoll >= 0 and dtPoll <= 0.15 then
		return
	end
	self._dmgMeterOutgoingLastPollAt = tNow

	local dbg = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("diagnostics"))
		or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
	local wantDbg = dbg >= 4
	local idsSeen = nil
	if wantDbg then
		idsSeen = {}
	end

	local playerGUID = UnitGUID and UnitGUID("player") or nil
	if type(playerGUID) ~= "string" then
		return
	end
	if ZSBT and ZSBT.IsSafeString and not ZSBT.IsSafeString(playerGUID) then
		return
	end
	local petGUID = UnitGUID and UnitGUID("pet") or nil
	local vehGUID = UnitGUID and UnitGUID("vehicle") or nil

	self._dmgMeterLastTotals = self._dmgMeterLastTotals or {}
	local seen = {}
	local sources = { playerGUID, petGUID, vehGUID }
	for i = 1, #sources do
		local srcGUID = sources[i]
		if type(srcGUID) == "string" and (not (ZSBT and ZSBT.IsSafeString) or ZSBT.IsSafeString(srcGUID)) and not seen[srcGUID] then
			seen[srcGUID] = true
			local ok, sessionSource = pcall(C_DamageMeter.GetCombatSessionSourceFromType, 0, Enum.DamageMeterType.DamageDone, srcGUID)
			if ok and sessionSource and type(sessionSource.combatSpells) == "table" then
				for _, damageSpell in ipairs(sessionSource.combatSpells) do
					pcall(function()
						local spellId = damageSpell.spellID
						local totalAmount = damageSpell.totalAmount
						if type(spellId) ~= "number" or totalAmount == nil then
							return
						end
						if idsSeen then
							idsSeen[#idsSeen + 1] = spellId
						end
						local totalNum = tonumber(totalAmount)
						if not totalNum or totalNum <= 0 then
							return
						end
						local key = tostring(srcGUID) .. ":" .. tostring(spellId)
						local lastTotal = self._dmgMeterLastTotals[key] or 0
						local delta = totalNum - lastTotal
						if delta < 0 then
							delta = totalNum
						end
						if delta > 0 then
							local isAuto = false
							if ZSBT and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(spellId) then
								isAuto = (spellId == 6603) or (spellId == 1)
							end
							self:collect("OUTGOING_DAMAGE_COMBAT", {
								timestamp = tNow,
								amount = delta,
								amountText = tostring(math.floor(delta + 0.5)),
								spellId = spellId,
								isAuto = isAuto,
								schoolMask = nil,
								targetName = nil,
								isCrit = false,
								isPeriodic = false,
								amountSource = "DAMAGE_METER",
							})
						end
						self._dmgMeterLastTotals[key] = totalNum
					end)
				end
			end
		end
	end

	if wantDbg and idsSeen then
		local lastAt = self._dmgMeterDbgLastAt or 0
		if (tNow - lastAt) >= 1.00 then
			self._dmgMeterDbgLastAt = tNow
			local has6603, has1 = false, false
			local maxShow = 12
			local out = {}
			for i = 1, math.min(#idsSeen, maxShow) do
				local sid = idsSeen[i]
				local sidText = "<secret>"
				if ZSBT and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
					sidText = tostring(sid)
					if sid == 6603 then has6603 = true end
					if sid == 1 then has1 = true end
				else
					local okS, s = pcall(tostring, sid)
					if okS and type(s) == "string" and ZSBT and ZSBT.IsSafeString and ZSBT.IsSafeString(s) then
						sidText = s
					end
				end
				out[#out + 1] = sidText
			end
			local suffix = (#idsSeen > maxShow) and (" … +" .. tostring(#idsSeen - maxShow)) or ""
			if Addon and Addon.Dbg then
				Addon:Dbg("diagnostics", 4, "DM spells=" .. table.concat(out, ",") .. suffix, "has6603=" .. tostring(has6603), "has1=" .. tostring(has1))
			elseif ZSBT.Addon and ZSBT.Addon.Print then
				ZSBT.Addon:Print("DM spells=" .. table.concat(out, ",") .. suffix .. " has6603=" .. tostring(has6603) .. " has1=" .. tostring(has1))
			end
		end
	end
end

function Engine:_ensureDamageMeterTicker()
	if self._dmgMeterTicker then
		return
	end
	if not C_Timer or not C_Timer.NewTicker then
		return
	end
	self._dmgMeterTicker = C_Timer.NewTicker(0.10, function()
		if Engine and Engine._enabled then
			local tok = ZSBT.Addon and ZSBT.Addon.PerfBegin and ZSBT.Addon:PerfBegin("PE.DmgMeter")
			Engine:_pollDamageMeterOutgoing()
			Engine:_pollDamageMeterIncoming()
			if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
		end
	end)
end

function Engine:_stopDamageMeterTicker()
	if self._dmgMeterTicker then
		self._dmgMeterTicker:Cancel()
		self._dmgMeterTicker = nil
	end
end

local function Dbg4(prefix, msg)
	if Addon and Addon.Dbg then
		Addon:Dbg("diagnostics", 4, prefix, msg)
		return
	end
	local dbg = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("diagnostics"))
		or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.debugLevel or 0)
	if dbg >= 4 and ZSBT.Addon and ZSBT.Addon.Print then
		local function safeToString(v)
			if v == nil then return "" end
			if type(v) == "string" then
				if ZSBT and ZSBT.IsSafeString and ZSBT.IsSafeString(v) then
					return v
				end
				return "<secret>"
			end
			local ok, s = pcall(tostring, v)
			if ok and type(s) == "string" then
				if ZSBT and ZSBT.IsSafeString and ZSBT.IsSafeString(s) then
					return s
				end
				return "<secret>"
			end
			return "<secret>"
		end
		local p = safeToString(prefix)
		local m = safeToString(msg)
		if m ~= "" then
			ZSBT.Addon:Print(p .. " " .. m)
		else
			ZSBT.Addon:Print(p)
		end
	end
end

local function resetPetMerge(self)
	local pm = self._petMerge
	pm.active = false
	pm.sum = 0
	pm.count = 0
	pm.deadline = 0
	pm.prefix = nil
	pm.aggMode = nil
	pm.area = nil
	pm.isCrit = false
	pm.school = nil
end

function Engine:_flushPetMerge(t)
	local pm = self._petMerge
	if not pm or pm.active ~= true then return end
	if not t then t = now() end
	if pm.deadline and pm.deadline > 0 and t < pm.deadline then return end

	local petConf = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.pets
	if not petConf or petConf.enabled ~= true then
		resetPetMerge(self)
		return
	end

	local rounded = math.floor((pm.sum or 0) + 0.5)
	if rounded <= 0 then
		resetPetMerge(self)
		return
	end

	local amountText = tostring(rounded)
	local prefix = pm.prefix or "Pet"
	local text = prefix .. " " .. amountText
	if (petConf.showCount ~= false) and (pm.count or 0) > 1 then
		text = text .. " (x" .. tostring(pm.count) .. ")"
	end

	local area = pm.area or petConf.scrollArea or "Outgoing"
	local color = {r = 1.00, g = 1.00, b = 1.00}
	local baseCol = petConf and petConf.outgoingDamageColor
	local critCol = petConf and petConf.outgoingCritColor
	if pm.isCrit and type(critCol) == "table" then
		color = { r = critCol.r or 1, g = critCol.g or 1, b = critCol.b or 0 }
	elseif (not pm.isCrit) and type(baseCol) == "table" then
		color = { r = baseCol.r or 1, g = baseCol.g or 1, b = baseCol.b or 1 }
	elseif pm.isCrit then
		color = {r = 1.00, g = 1.00, b = 0.00}
	end
	local meta = {
		kind = "pet",
		isCrit = pm.isCrit == true,
		school = pm.school,
	}

	if ZSBT.Core and ZSBT.Core.Display and ZSBT.Core.Display.Emit then
		ZSBT.Core.Display:Emit(area, text, color, meta)
	elseif ZSBT.DisplayText then
		ZSBT.DisplayText(area, text, color, meta)
	end

	resetPetMerge(self)
end

function Engine:ApplyConfig()
	local prof = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
	local pe = prof and prof.pulseEngine
	if not pe then return end
	if type(pe.maxBucketSize) == "number" and pe.maxBucketSize >= 20 and pe.maxBucketSize <= 1000 then
		self._maxBucketSize = math.floor(pe.maxBucketSize + 0.5)
	end
	if type(pe.maxWorkPerPulse) == "number" and pe.maxWorkPerPulse >= 10 and pe.maxWorkPerPulse <= 500 then
		self._maxWorkPerPulse = math.floor(pe.maxWorkPerPulse + 0.5)
	end
end

function Engine:collect(eventType, payload)
	if not self._enabled then return end
	if not eventType or not payload then return end

	local dbg = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("diagnostics"))
		or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.debugLevel or 0)
	if dbg >= 3 and dbg < 5 and Addon and Addon.Dbg then
		local tNow = now()
		if (tNow - (self._dbgLastCollectAt or 0)) >= 0.25 then
			-- Only sample interesting types to keep chat readable.
			if eventType == "UNIT_COMBAT" or eventType == "INCOMING_DAMAGE" or eventType == "INCOMING_HEAL_COMBAT" or eventType == "FALL_DAMAGE" or eventType == "COMBAT_TEXT_UPDATE" or eventType == "COMBAT_TEXT_DAMAGE" or eventType == "OUTGOING_DAMAGE_COMBAT" or eventType == "OUTGOING_HEAL_COMBAT" or eventType == "PET_DAMAGE_COMBAT" or eventType == "HEALTH_DAMAGE" or eventType == "HEALTH_HEAL" or eventType == "SPELLCAST_SUCCEEDED" or eventType == "UNIT_HEALTH" then
				self._dbgLastCollectAt = tNow
				Addon:Dbg("diagnostics", 3, "PE collect", tostring(eventType), "qCount=" .. tostring(self._qCount or 0))
			end
		end
	end

	local bucket = self._bucket
	local maxSize = self._maxBucketSize or 120

	-- Initialize indices if needed (handles reloads/hot swaps)
	if not self._qHead then self._qHead = 1 end
	if not self._qTail then self._qTail = 0 end
	if not self._qCount then self._qCount = 0 end

	-- If full, drop oldest by advancing head (O(1))
	if self._qCount >= maxSize then
		bucket[self._qHead] = nil
		self._qHead = self._qHead + 1
		if self._qHead > maxSize then self._qHead = 1 end
		self._qCount = self._qCount - 1
	end

	payload.eventType = eventType
	self._qTail = self._qTail + 1
	if self._qTail > maxSize then self._qTail = 1 end
	bucket[self._qTail] = payload
	self._qCount = self._qCount + 1
end

function Engine:_emitOutgoing(ev)
	if type(ev) == "table" and ev.direction == nil then
		ev.direction = "outgoing"
	end
	local lcp = getLCP()
	if lcp then
		pcall(function() lcp:Emit(ev) end)
	end
	-- During LibCombatPulse cutover, ZSBT consumes via an internal LCP forwarder.
	-- Keep the legacy direct-call path as a fallback until cutover is enabled.
	if not (ZSBT and ZSBT._lcpCutoverEnabled == true) then
		local parser = ZSBT.Parser and ZSBT.Parser.Outgoing
		if parser and parser.ProcessEvent then
			parser:ProcessEvent(ev)
		end
	end
end

function Engine:_emitIncoming(ev)
	if type(ev) == "table" and ev.direction == nil then
		ev.direction = "incoming"
	end
	local lcp = getLCP()
	if lcp then
		pcall(function() lcp:Emit(ev) end)
	end
	-- During LibCombatPulse cutover, ZSBT consumes via an internal LCP forwarder.
	-- Keep the legacy direct-call path as a fallback until cutover is enabled.
	if not (ZSBT and ZSBT._lcpCutoverEnabled == true) then
		local parser = ZSBT.Parser and ZSBT.Parser.Incoming
		if parser and parser.ProcessEvent then
			parser:ProcessEvent(ev)
		end
	end
end

function Engine:_isSameIncomingAmount(a, aText, b, bText)
	if ZSBT and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(a) and ZSBT.IsSafeNumber(b) then
		return a == b
	end
	if ZSBT and ZSBT.IsSafeString and ZSBT.IsSafeString(aText) and ZSBT.IsSafeString(bText) then
		return aText == bText
	end
	return false
end

function Engine:_shouldDedupIncoming(kind, amount, amountText, timestamp)
	if kind ~= "damage" and kind ~= "heal" then return false end
	local tNow = timestamp or now()
	local last = self._lastIncomingDedup
	if type(last) ~= "table" then return false end
	if last.kind ~= kind then return false end
	local dt = tNow - (last.at or 0)
	if dt < 0 or dt > 0.12 then return false end
	return self:_isSameIncomingAmount(amount, amountText, last.amount, last.amountText)
end

function Engine:_noteIncomingDedup(kind, amount, amountText, timestamp)
	self._lastIncomingDedup = {
		at = timestamp or now(),
		kind = kind,
		amount = amount,
		amountText = amountText,
	}
end

function Engine:_processSpellcast(sample)
	if not StateManager then return end
	if not sample then return end

	StateManager:createCastState(sample.spellId, sample.spellName, sample.unit, sample.timestamp, 0.50)
end

function Engine:_processHealthDamage(sample)
	if not sample or not CorrelationLogic or not StateManager then return end

	local activeCasts = StateManager:getActiveCasts()
	local bestCast, confidence, score = CorrelationLogic:findBestCast(activeCasts, sample)
	if bestCast and confidence ~= CorrelationLogic.CONFIDENCE.UNKNOWN then
		StateManager:markMatched(bestCast, sample)
	end

	local normalized = {
		eventType = sample.eventType,
		kind = "damage",
		amount = sample.amount,
		amountText = sample.amountText,
		spellName = bestCast and bestCast.spellName or nil,
		spellId = bestCast and bestCast.spellId or nil,
		targetName = sample.targetName,
		isCrit = sample.isCrit,
		timestamp = sample.timestamp,
		confidence = confidence or CorrelationLogic.CONFIDENCE.UNKNOWN,
		isPeriodic = sample.isPeriodic == true,
		isSecret = sample.isSecret,
	}

	if sample.unit == "player" then
		self:_emitIncoming(normalized)
	else
		local strictOutgoing = (ZSBT.Core and ZSBT.Core.IsStrictOutgoingCombatLogOnlyEnabled and ZSBT.Core:IsStrictOutgoingCombatLogOnlyEnabled()) or false
		if strictOutgoing == true then
			return
		end
		-- HEALTH_DAMAGE for non-player units (e.g. target/nameplates) has no source attribution.
		-- When instance-aware outgoing is enabled, only treat it as *player outgoing*
		-- when we can correlate it to a recent player cast. Otherwise, preserve legacy
		-- behavior (may be noisy in group content).
		local instanceAware = (ZSBT.Core and ZSBT.Core.IsInstanceAwareOutgoingEnabled and ZSBT.Core:IsInstanceAwareOutgoingEnabled()) or false
		if instanceAware == true then
			if not bestCast then
				return
			end
			if confidence ~= CorrelationLogic.CONFIDENCE.HIGH and confidence ~= CorrelationLogic.CONFIDENCE.MEDIUM then
				return
			end
		end
		if ZSBT.Core and ZSBT.Core.ShouldRestrictOutgoingFallback and ZSBT.Core:ShouldRestrictOutgoingFallback() then
			return
		end
		Dbg4("|cFFCC66FF[OUTDBG]|r", ("HEALTH_DAMAGE unit=%s amt=%s periodic=%s bestSpellId=%s conf=%s score=%s")
			:format(tostring(sample.unit), tostring(sample.amount), tostring(sample.isPeriodic == true), tostring(bestCast and bestCast.spellId), tostring(confidence), tostring(score)))
		self:_emitOutgoing(normalized)
	end
end

function Engine:_processHealthHeal(sample)
	if not sample or not CorrelationLogic or not StateManager then return end

	local activeCasts = StateManager:getActiveCasts()
	local bestCast, confidence, score = CorrelationLogic:findBestCast(activeCasts, sample)

	if bestCast and confidence ~= CorrelationLogic.CONFIDENCE.UNKNOWN then
		StateManager:markMatched(bestCast, sample)
	end

	local normalized = {
		eventType = sample.eventType,
		kind = "heal",
		amount = sample.amount,
		amountText = sample.amountText,
		spellName = bestCast and bestCast.spellName or nil,
		spellId = bestCast and bestCast.spellId or nil,
		targetName = sample.targetName,
		isCrit = sample.isCrit,
		timestamp = sample.timestamp,
		confidence = confidence or CorrelationLogic.CONFIDENCE.UNKNOWN,
		isSecret = sample.isSecret,
	}

	if sample.unit == "player" then
		self:_emitIncoming(normalized)
	elseif bestCast and confidence == CorrelationLogic.CONFIDENCE.HIGH then
		local strictOutgoing = (ZSBT.Core and ZSBT.Core.IsStrictOutgoingCombatLogOnlyEnabled and ZSBT.Core:IsStrictOutgoingCombatLogOnlyEnabled()) or false
		if strictOutgoing == true then
			return
		end
		if ZSBT.Core and ZSBT.Core.ShouldRestrictOutgoingFallback and ZSBT.Core:ShouldRestrictOutgoingFallback() then
			return
		end
		Dbg4("|cFFCC66FF[OUTDBG]|r", ("HEALTH_HEAL unit=%s amt=%s bestSpellId=%s conf=%s score=%s")
			:format(tostring(sample.unit), tostring(sample.amount), tostring(bestCast and bestCast.spellId), tostring(confidence), tostring(score)))
		-- Only attribute as outgoing heal if we have high confidence it
		-- came from one of the player's casts. Otherwise the target may
		-- just be healing themselves or receiving heals from others.
		self:_emitOutgoing(normalized)
	end
end

function Engine:_processHealthChangeSecret(sample)
	if not sample or not CorrelationLogic or not StateManager then return end

	sample.isSecret = true
	local activeCasts = StateManager:getActiveCasts()
	local bestCast, confidence = CorrelationLogic:findBestCast(activeCasts, sample)

	local normalized = {
		eventType = sample.eventType,
		kind = "damage",
		amount = nil,
		spellName = bestCast and bestCast.spellName or nil,
		spellId = bestCast and bestCast.spellId or nil,
		targetName = sample.targetName,
		isCrit = false,
		timestamp = sample.timestamp,
		confidence = confidence or CorrelationLogic.CONFIDENCE.UNKNOWN,
		isPeriodic = false,
		isSecret = true,
	}

	if sample.unit == "player" then
		self:_emitIncoming(normalized)
	else
		-- Secret health-delta events are even less trustworthy. When instance-aware outgoing
		-- is enabled, only emit as outgoing if we have at least MEDIUM confidence correlation
		-- to a recent player cast. Otherwise, preserve legacy behavior.
		local instanceAware = (ZSBT.Core and ZSBT.Core.IsInstanceAwareOutgoingEnabled and ZSBT.Core:IsInstanceAwareOutgoingEnabled()) or false
		if instanceAware == true then
			if not bestCast then
				return
			end
			if confidence ~= CorrelationLogic.CONFIDENCE.HIGH and confidence ~= CorrelationLogic.CONFIDENCE.MEDIUM then
				return
			end
		end
		if ZSBT.Core and ZSBT.Core.ShouldRestrictOutgoingFallback and ZSBT.Core:ShouldRestrictOutgoingFallback() then
			return
		end
		self:_emitOutgoing(normalized)
	end
end

function Engine:_processHealth(_)
	-- General health change marker retained for future multi-signal heuristics.
end

function Engine:flushBucket()
	local budgetMs = nil
	local tStart = nil
	do
		local d = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics
		local b = d and tonumber(d.pulseBudgetMs)
		if type(b) == "number" and b > 0 and type(debugprofilestop) == "function" then
			budgetMs = b
			tStart = debugprofilestop()
		end
	end
	local bucket = self._bucket
	local count = self._qCount or 0
	local dbg = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("diagnostics"))
		or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.debugLevel or 0)
	local function coerceProgressAmount(v)
		if v == nil then return nil end
		if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then
			return v
		end
		if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then
			local s = v:gsub(",", "")
			local n = tonumber(s)
			if n ~= nil then return n end
			local digits = s:match("(%d[%d,]*)")
			if digits then
				digits = digits:gsub(",", "")
				local n2 = tonumber(digits)
				if n2 ~= nil then return n2 end
			end
		end
		return nil
	end
	if dbg >= 3 and dbg < 5 and Addon and Addon.Dbg then
		local tNow = now()
		if (tNow - (self._dbgLastHeartbeatAt or 0)) >= 1.0 then
			self._dbgLastHeartbeatAt = tNow
			Addon:Dbg("diagnostics", 3, "PE heartbeat", "qCount=" .. tostring(count))
		end
	end
	-- Ensure pending pet merge flushes on time even if other events keep arriving.
	self:_flushPetMerge(now())
	-- Cooldown readiness fallback: fire overdue timers even if C_Timer callbacks are delayed.
	local cds = ZSBT.Parser and ZSBT.Parser.Cooldowns
	if cds and cds.CheckReadyTimers then
		local tNow = now()
		if (tNow - (self._lastCooldownPollAt or 0)) >= 0.10 then
			self._lastCooldownPollAt = tNow
			pcall(function() cds:CheckReadyTimers(tNow) end)
		end
	end
	if count <= 0 then
		return
	end

	local maxSize = self._maxBucketSize or 120
	local work = math.min(count, self._maxWorkPerPulse or 80)
	for _ = 1, work do
		if budgetMs and tStart then
			local elapsedMs = debugprofilestop() - tStart
			if elapsedMs >= budgetMs then
				return
			end
		end
		local idx = self._qHead
		local sample = bucket[idx]
		bucket[idx] = nil
		self._qHead = idx + 1
		if self._qHead > maxSize then self._qHead = 1 end
		self._qCount = (self._qCount or 1) - 1
		if sample then
			local et = sample.eventType
			local dbg = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("diagnostics"))
				or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.debugLevel or 0)
			if dbg >= 3 and dbg < 5 and Addon and Addon.Dbg then
				if et == "COMBAT_TEXT_DAMAGE" or et == "OUTGOING_DAMAGE_COMBAT" or et == "OUTGOING_HEAL_COMBAT" or et == "HEALTH_DAMAGE" or et == "HEALTH_HEAL" or et == "INCOMING_DAMAGE" or et == "FALL_DAMAGE" or et == "INCOMING_HEAL_COMBAT" then
					local function safeDbg(v)
						if v == nil then return "nil" end
						if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
						if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
						return "<secret>"
					end
					Addon:Dbg("diagnostics", 3, "PE",
						safeDbg(et),
						"unit=" .. safeDbg(sample.unit),
						"spellId=" .. safeDbg(sample.spellId),
						"rawPipeId=" .. safeDbg(sample.rawPipeId),
						"amt=" .. safeDbg(sample.amount),
						"amtText=" .. safeDbg(sample.amountText)
					)
				end
			end
			if et == "SPELLCAST_SUCCEEDED" then
				self:_processSpellcast(sample)
			elseif et == "HEALTH_DAMAGE" then
				self:_processHealthDamage(sample)
			elseif et == "HEALTH_HEAL" then
				self:_processHealthHeal(sample)
			elseif et == "HEALTH_CHANGE_SECRET" then
				self:_processHealthChangeSecret(sample)
			elseif et == "UNIT_HEALTH" then
				self:_processHealth(sample)
			elseif et == "INCOMING_DAMAGE" or et == "FALL_DAMAGE" then
				-- Incoming damage/heal is only for the player. If a collector bug or
				-- ambiguous UNIT_COMBAT feed tags a non-player unit (e.g. "target"),
				-- drop it here so it can never reach the Incoming pipeline.
				if not sample.unit or sample.unit == "player" then
					local kind = "damage"
					if not self:_shouldDedupIncoming(kind, sample.amount, sample.amountText, sample.timestamp) then
						self:_noteIncomingDedup(kind, sample.amount, sample.amountText, sample.timestamp)
						self:_emitIncoming({
						eventType = et,
						kind = "damage",
						amount = sample.amount,
						amountText = sample.amountText,
						spellName = (et == "FALL_DAMAGE") and "Fall" or nil,
						spellId = nil,
						targetName = safeUnitName and safeUnitName("player") or nil,
						isCrit = sample.isCrit or false,
						timestamp = sample.timestamp,
						confidence = (sample.isSecret and "LOW") or (CorrelationLogic and CorrelationLogic.CONFIDENCE and CorrelationLogic.CONFIDENCE.HIGH or "HIGH"),
						isPeriodic = false,
						isSecret = sample.isSecret,
						schoolMask = sample.school,
					})
					end
				end
			elseif et == "INCOMING_HEAL_COMBAT" then
				local kind = "heal"
				if not self:_shouldDedupIncoming(kind, sample.amount, sample.amountText, sample.timestamp) then
					self:_noteIncomingDedup(kind, sample.amount, sample.amountText, sample.timestamp)
					self:_emitIncoming({
					eventType = et,
					kind = "heal",
					amount = sample.amount,
					amountText = sample.amountText,
					spellName = nil,
					spellId = nil,
					targetName = safeUnitName and safeUnitName("player") or nil,
					isCrit = sample.isCrit or false,
					timestamp = sample.timestamp,
					confidence = (sample.isSecret and "LOW") or (CorrelationLogic and CorrelationLogic.CONFIDENCE and CorrelationLogic.CONFIDENCE.HIGH or "HIGH"),
					isPeriodic = false,
					isSecret = sample.isSecret,
					schoolMask = sample.school,
				})
				end
			elseif et == "COMBAT_TEXT_DAMAGE" then
				local kind = "damage"
				if not self:_shouldDedupIncoming(kind, sample.amount, sample.amountText, sample.timestamp) then
					self:_noteIncomingDedup(kind, sample.amount, sample.amountText, sample.timestamp)
					local amtText = sample.amountText
					local amtNum = nil
					if ZSBT and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(amtText) then
						amtNum = amtText
					else
						local n = tonumber(amtText)
						if ZSBT and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(n) then
							amtNum = n
						end
					end
					if not amtNum then
						return
					end
					self:_emitIncoming({
						eventType = et,
						kind = "damage",
						amount = nil,
						amountText = tostring(math.floor(amtNum + 0.5)),
						rawPipeId = sample.rawPipeId,
						spellName = nil,
						spellId = sample.spellId,
						targetName = sample.targetName,
						isCrit = sample.isCrit,
						timestamp = sample.timestamp,
						confidence = "HIGH",
						isPeriodic = false,
					})
				end
			elseif et == "COMBAT_TEXT_HEAL" then
				local kind = "heal"
				if not self:_shouldDedupIncoming(kind, sample.amount, sample.amountText, sample.timestamp) then
					self:_noteIncomingDedup(kind, sample.amount, sample.amountText, sample.timestamp)
					self:_emitIncoming({
						eventType = et,
						kind = "heal",
						amount = nil,
						amountText = sample.amountText,
						rawPipeId = sample.rawPipeId,
						spellName = nil,
						spellId = sample.spellId,
						targetName = sample.targetName,
						isCrit = sample.isCrit,
						overheal = sample.overheal,
						timestamp = sample.timestamp,
						confidence = "HIGH",
						isPeriodic = sample.isPeriodic == true,
					})
				end
			elseif et == "COMBAT_TEXT_MISS" then
				-- Dodge/Parry/Miss/Block etc.
				self:_emitIncoming({
					eventType = et,
					kind = "miss",
					amount = nil,
					missType = sample.missType,
					amountText = sample.missType or "Miss",
					spellName = nil,
					spellId = nil,
					targetName = sample.targetName,
					isCrit = false,
					timestamp = sample.timestamp,
					confidence = "HIGH",
					isPeriodic = false,
				})
			elseif et == "COMBAT_TEXT_ENVIRONMENTAL" then
				-- Environmental damage: drowning, lava, fatigue, etc.
				self:_emitIncoming({
					kind = "damage",
					amount = nil,
					amountText = nil,
					rawPipeId = sample.rawPipeId,
					spellName = "Environmental",
					spellId = nil,
					targetName = sample.targetName,
					isCrit = false,
					timestamp = sample.timestamp,
					confidence = "HIGH",
					isPeriodic = false,
				})
			elseif et == "COMBAT_TEXT_HONOR" then
				local text = "Honor"
				do
					local n = coerceProgressAmount(sample.amount)
					if not n then
						n = coerceProgressAmount(sample.amountText)
					end
					if not n and sample.rawPipeId then
						local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
						local val = ec and ec._rawPipe[sample.rawPipeId]
						n = coerceProgressAmount(val)
						if ec then ec._rawPipe[sample.rawPipeId] = nil end
					end
					if n then
						text = "+" .. tostring(math.floor(n + 0.5)) .. " Honor"
					end
				end
				if ZSBT.Core and ZSBT.Core.EmitNotification then
					ZSBT.Core._lastHonorNotifAt = GetTime()
					ZSBT.Core:EmitNotification(text, {r = 1.0, g = 0.5, b = 0.0}, "honor")
				end
			elseif et == "COMBAT_TEXT_XP" then
				local text = "XP"
				pcall(function()
					local xp = tostring(sample.amount or "")
					xp = xp:gsub(",", "")
					if xp ~= "" then
						text = "+" .. xp .. " XP"
					end
				end)
				if ZSBT.Core and ZSBT.Core.EmitNotification then
					ZSBT.Core._lastXPNotifAt = GetTime()
					ZSBT.Core:EmitNotification(text, {r = 0.6, g = 0.4, b = 1.0}, "playerXP")
				end
			elseif et == "COMBAT_TEXT_REP" then
				local text = "Reputation"
				local ok = false
				pcall(function()
					local rep = tostring(sample.amount or "")
					rep = rep:gsub(",", "")
					local faction = tostring(sample.name or "")
					if rep ~= "" and faction ~= "" then
						text = "+" .. rep .. " " .. faction
						ok = true
					end
				end)
				if ok and ZSBT.Core and ZSBT.Core.EmitNotification then
					local tNow = GetTime()
					local dedupWindow = 1.0
					local fallbackDelay = 0.25
					if C_Timer and type(C_Timer.After) == "function" then
						C_Timer.After(fallbackDelay, function()
							if not ZSBT.Core or not ZSBT.Core.EmitNotification then return end
							if (GetTime() - (ZSBT.Core._lastRepNotifAt or 0)) < dedupWindow then return end
							ZSBT.Core._lastRepNotifAt = GetTime()
							ZSBT.Core:EmitNotification(text, {r = 0.0, g = 0.8, b = 0.6}, "reputation")
						end)
					else
						if (tNow - (ZSBT.Core._lastRepNotifAt or 0)) >= dedupWindow then
							ZSBT.Core._lastRepNotifAt = tNow
							ZSBT.Core:EmitNotification(text, {r = 0.0, g = 0.8, b = 0.6}, "reputation")
						end
					end
				end
			elseif et == "COMBAT_TEXT_PROC" then
				-- Spell proc / reactive ability -> notification
				local spellName = sample.spellName or "Proc"
				if ZSBT.Core and ZSBT.Core.EmitNotification then
					ZSBT.Core:EmitNotification(spellName .. "!", {r = 1.0, g = 1.0, b = 0.0}, "procs")
				end
			elseif et == "SELF_HEAL_TEXT" then
				-- Legacy path kept for compatibility
				self:_emitIncoming({
					kind = "heal",
					amount = nil,
					amountText = sample.amountText,
					spellName = sample.spellName,
					spellId = nil,
					targetName = safeUnitName and safeUnitName("player") or nil,
					isCrit = sample.isCrit,
					timestamp = sample.timestamp,
					confidence = "HIGH",
					isPeriodic = false,
				})
			elseif et == "INCOMING_HEAL_TEXT" then
				self:_emitIncoming({
					kind = "heal",
					amount = nil,
					amountText = sample.amountText,
					spellName = nil,
					spellId = nil,
					targetName = sample.targetName,
					isCrit = sample.isCrit,
					timestamp = sample.timestamp,
					confidence = "HIGH",
					isPeriodic = sample.isPeriodic == true,
				})
			elseif et == "OUTGOING_DAMAGE_COMBAT" then
				-- OUTGOING_DAMAGE_COMBAT uses rawPipe values from EventCollector._rawPipe.
				-- Only the rawPipeId is safe to use here.
				local rawPipeId = sample.rawPipeId
				Dbg4("|cFFCC66FF[OUTDBG]|r", ("PATH OUTGOING_DAMAGE_COMBAT rawPipeId=%s spellId=%s target=%s")
					:format(tostring(sample.rawPipeId), tostring(sample.spellId), tostring(sample.targetName)))
				Dbg5("|cFFCC66FF[OUTDBG]|r", ("CORR OUTGOING_DAMAGE_COMBAT dbgChatId=%s src=%s rawPipeId=%s spellId=%s target=%s")
				:format(tostring(sample.dbgChatId), tostring(sample.amountSource), tostring(sample.rawPipeId), tostring(sample.spellId), tostring(sample.targetName)))
			do
				local dbg = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("diagnostics"))
					or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.debugLevel or 0)
				if dbg >= 5 then
					local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
					if ec and ec._dbgCorrOutgoingNote then
						pcall(function() ec:_dbgCorrOutgoingNote(sample) end)
					end
				end
			end
				self:_noteOutgoingSignal(sample.timestamp)

				-- Only allow trusted outgoing amounts. COMBAT_TEXT_UPDATE is ideal; when it is
				-- unavailable, we allow UNIT_COMBAT_BEST which is a merged/filtered signal from
				-- UNIT_COMBAT("target") that keeps only the largest hit within a short window.
				-- For physical (melee/ranged) hits we allow UNIT_COMBAT_PHYSICAL, because merging
				-- would collapse multi-swing / cleave behaviors.
				-- Suppress legacy/unknown source events (amountSource nil) to prevent
				-- Outgoing_Probe from applying LAST_CAST fallback.
				if sample.amountSource ~= "COMBAT_TEXT" and sample.amountSource ~= "UNIT_COMBAT_BEST" and sample.amountSource ~= "UNIT_COMBAT_PHYSICAL" and sample.amountSource ~= "UNIT_COMBAT_DOT" and sample.amountSource ~= "DAMAGE_METER" and sample.amountSource ~= "UNIT_COMBAT_AUTO_FALLBACK" and sample.amountSource ~= "COMBAT_LOG" then
					local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
					if rawPipeId and ec and ec._rawPipe then
						ec._rawPipe[rawPipeId] = nil
					end
					Dbg4("|cFFCC66FF[OUTDBG]|r", ("SUPPRESS OUTGOING_DAMAGE_COMBAT src=%s rawPipeId=%s spellId=%s")
						:format(tostring(sample.amountSource), tostring(rawPipeId), tostring(sample.spellId)))
					return
				end
				self:_emitOutgoing({
					eventType = et,
					kind = "damage",
					amount = sample.amount,
					amountText = sample.amountText,
					rawPipeId = sample.rawPipeId,
					spellName = nil,
					spellId = sample.spellId,
					dbgChatId = sample.dbgChatId,
					amountSource = sample.amountSource,
					isAuto = sample.isAuto == true,
					schoolMask = sample.schoolMask,
					targetName = sample.targetName,
					isCrit = sample.isCrit,
					wwCount = sample.wwCount,
					wwCritCount = sample.wwCritCount,
					timestamp = sample.timestamp,
					confidence = "HIGH",
					isPeriodic = sample.isPeriodic == true,
				})
			elseif et == "OUTGOING_HEAL_COMBAT" then
				self:_emitOutgoing({
					eventType = et,
					kind = "heal",
					amount = nil,
					amountText = nil,
					rawPipeId = sample.rawPipeId,
					spellName = nil,
					spellId = sample.spellId,
					amountSource = sample.amountSource,
					schoolMask = sample.schoolMask,
					targetName = sample.targetName,
					isCrit = sample.isCrit,
					timestamp = sample.timestamp,
					confidence = "HIGH",
					isPeriodic = false,
				})
			elseif et == "OUTGOING_MISS_COMBAT" then
				self:_emitOutgoing({
					eventType = et,
					kind = "miss",
					amount = nil,
					missType = sample.amountText,
					amountText = sample.amountText,
					rawPipeId = sample.rawPipeId,
					spellName = nil,
					spellId = sample.spellId,
					amountSource = sample.amountSource,
					schoolMask = sample.schoolMask,
					targetName = sample.targetName,
					isCrit = false,
					timestamp = sample.timestamp,
					confidence = "HIGH",
					isPeriodic = false,
				})
			elseif et == "PET_HEAL_LOG" then
				local petConf = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.pets
				if petConf and petConf.showHealing == true then
					local val = sample.amount
					if type(val) == "number" then
						local minT = tonumber(petConf.healMinThreshold) or 0
						if minT <= 0 or val >= minT then
							local rounded = math.floor(val + 0.5)
							if rounded > 0 then
								local text = "+" .. tostring(rounded)
								if sample.spellId and ZSBT.CleanSpellName then
									local nm = ZSBT.CleanSpellName(sample.spellId)
									if nm then
										text = text .. " " .. nm
									end
								end
								local prof = ZSBT.db and ZSBT.db.profile
								local area = petConf.healScrollArea or petConf.scrollArea or "Outgoing"
								if prof and prof.scrollAreas and type(area) == "string" then
									if prof.scrollAreas[area] == nil then
										area = "Outgoing"
									end
								end
								local color = {r = 0.60, g = 0.80, b = 0.60}
								local baseCol = petConf and petConf.incomingHealColor
								local critCol = petConf and petConf.incomingHealCritColor
								if sample.isCrit == true and type(critCol) == "table" then
									color = { r = critCol.r or 0.80, g = critCol.g or 1.00, b = critCol.b or 0.00 }
								elseif type(baseCol) == "table" then
									color = { r = baseCol.r or 0.60, g = baseCol.g or 0.80, b = baseCol.b or 0.60 }
								elseif sample.isCrit == true then
									color = {r = 0.80, g = 1.00, b = 0.00}
								end
								local meta = { kind = "pet_heal", isCrit = sample.isCrit == true }
								if ZSBT.Core and ZSBT.Core.Display and ZSBT.Core.Display.Emit then
									ZSBT.Core.Display:Emit(area, text, color, meta)
								elseif ZSBT.DisplayText then
									ZSBT.DisplayText(area, text, color, meta)
								end
							end
						end
					end
				else
					-- Default behavior: treat as normal Outgoing Healing.
					self:_emitOutgoing({
						kind = "heal",
						amount = sample.amount,
						amountText = sample.amountText,
						spellName = sample.spellName,
						spellId = sample.spellId,
						targetName = sample.targetName,
						isCrit = sample.isCrit,
						overheal = sample.overheal,
						timestamp = sample.timestamp,
						confidence = "HIGH",
						isPeriodic = sample.isPeriodic == true,
					})
				end
			elseif et == "PET_DAMAGE_COMBAT" then
				local rawPipeId = sample.rawPipeId
				local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
				local val = (rawPipeId and ec and ec._rawPipe and ec._rawPipe[rawPipeId]) or nil
				if rawPipeId and ec and ec._rawPipe then
					ec._rawPipe[rawPipeId] = nil
				end

				local petConf = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.pets
				if not (petConf and petConf.enabled) then
					Dbg4("|cFF66CCFF[PETDBG]|r", ("DRAIN pet rawPipeId=%s val=%s (pets disabled)")
						:format(tostring(rawPipeId), tostring(val)))
				else
					local text = nil
					local aggMode = petConf.aggregation or "Generic"
					local petName = nil
					if aggMode:find("Attempt") then
						local ok, name = pcall(UnitName, "pet")
						if ok and ZSBT.IsSafeString(name) and name ~= "" then
							petName = name
						end
					end
					local prefix
					if aggMode:find("Generic") then
						prefix = "Pet"
					elseif petName then
						prefix = petName
					else
						prefix = "Pet"
					end

					if val ~= nil then
						if ZSBT.IsSafeNumber(val) then
							local rounded = math.floor(val + 0.5)
							if rounded > 0 then
								local minT = tonumber(petConf.minThreshold) or 0
								if minT <= 0 or val >= minT then
									local mergeWin = tonumber(petConf.mergeWindowSec) or 0
									if mergeWin > 0 then
										local pm = self._petMerge
										if pm and pm.active == true then
											self:_flushPetMerge(now())
										end
										pm = self._petMerge
										pm.active = true
										pm.sum = (pm.sum or 0) + val
										pm.count = (pm.count or 0) + 1
										pm.deadline = now() + mergeWin
										pm.prefix = prefix
										pm.aggMode = aggMode
										local prof = ZSBT.db and ZSBT.db.profile
										local areaName = petConf.scrollArea or "Outgoing"
										if prof and prof.scrollAreas and type(areaName) == "string" then
											if prof.scrollAreas[areaName] == nil then
												areaName = "Outgoing"
											end
										end
										pm.area = areaName
										pm.isCrit = (pm.isCrit == true) or (sample.isCrit == true)
										pm.school = sample.schoolMask
										self:_flushPetMerge(now())
									else
										text = prefix .. " " .. tostring(rounded)
									end
								end
							end
						else
							-- Secret/tainted amount: never pass raw userdata through the UI.
							local okS, s = pcall(tostring, val)
							if okS and type(s) == "string" and s ~= "" then
								if aggMode:find("Generic") then
									text = "Pet " .. s
								elseif petName then
									text = petName .. " " .. s
								else
									text = "Pet " .. s
								end
							end
						end
					end

					Dbg4("|cFF66CCFF[PETDBG]|r", ("PET event rawPipeId=%s val=%s out=%s")
						:format(tostring(rawPipeId), tostring(val), tostring(text)))

					if text then
						local prof = ZSBT.db and ZSBT.db.profile
						local area = petConf.scrollArea or "Outgoing"
						if prof and prof.scrollAreas and type(area) == "string" then
							if prof.scrollAreas[area] == nil then
								area = "Outgoing"
							end
						end
						local color = {r = 0.60, g = 0.80, b = 0.60}
						local baseCol = petConf and petConf.outgoingDamageColor
						local critCol = petConf and petConf.outgoingCritColor
						if sample.isCrit and type(critCol) == "table" then
							color = { r = critCol.r or 1, g = critCol.g or 1, b = critCol.b or 0 }
						elseif type(baseCol) == "table" then
							color = { r = baseCol.r or 1, g = baseCol.g or 1, b = baseCol.b or 1 }
						elseif sample.isCrit then
							color = {r = 0.80, g = 1.00, b = 0.00}
						end
						local meta = { kind = "pet", isCrit = sample.isCrit == true, school = sample.schoolMask }
						if ZSBT.Core and ZSBT.Core.Display and ZSBT.Core.Display.Emit then
							ZSBT.Core.Display:Emit(area, text, color, meta)
						elseif ZSBT.DisplayText then
							ZSBT.DisplayText(area, text, color, meta)
						end
					end
				end
			elseif et == "PET_INCOMING_DAMAGE_COMBAT" then
				local rawPipeId = sample.rawPipeId
				local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
				local val = (rawPipeId and ec and ec._rawPipe and ec._rawPipe[rawPipeId]) or nil
				if rawPipeId and ec and ec._rawPipe then
					ec._rawPipe[rawPipeId] = nil
				end
				local petConf = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.pets
				if petConf and petConf.showIncomingDamage == true and val ~= nil then
					local minT = tonumber(petConf.incomingDamageMinThreshold) or 0
					if (minT <= 0) or (ZSBT.IsSafeNumber(val) and val >= minT) then
						local rounded = ZSBT.IsSafeNumber(val) and math.floor(val + 0.5) or nil
						local text = nil
						if rounded and rounded > 0 then
							text = "-" .. tostring(rounded)
						elseif not ZSBT.IsSafeNumber(val) then
							local okS, s = pcall(tostring, val)
							if okS and type(s) == "string" and s ~= "" then
								text = "-" .. s
							end
						end
						if text then
							local prof = ZSBT.db and ZSBT.db.profile
							local area = petConf.incomingDamageScrollArea or "Pet Incoming"
							if prof and prof.scrollAreas and type(area) == "string" then
								if prof.scrollAreas[area] == nil then
									area = "Incoming"
								end
							end
							local color = { r = 1.00, g = 0.30, b = 0.30 }
							local baseCol = petConf and petConf.incomingDamageColor
							local critCol = petConf and petConf.incomingDamageCritColor
							if sample.isCrit == true and type(critCol) == "table" then
								color = { r = critCol.r or 1.00, g = critCol.g or 0.80, b = critCol.b or 0.20 }
							elseif type(baseCol) == "table" then
								color = { r = baseCol.r or 1.00, g = baseCol.g or 0.30, b = baseCol.b or 0.30 }
							end
							local meta = { kind = "pet_in_damage", isCrit = sample.isCrit == true, school = sample.schoolMask }
							if ZSBT.Core and ZSBT.Core.Display and ZSBT.Core.Display.Emit then
								ZSBT.Core.Display:Emit(area, text, color, meta)
							elseif ZSBT.DisplayText then
								ZSBT.DisplayText(area, text, color, meta)
							end
						end
					end
				end
			end
		end
	end

	StateManager:expireStaleStates(now())
end

function Engine:_onUpdate(elapsed)
	self._accumulator = self._accumulator + (elapsed or 0)
	if self._accumulator < self._pulseInterval then
		return
	end

	-- Preserve overrun remainder rather than zeroing for stable pacing.
	self._accumulator = self._accumulator - self._pulseInterval
	local tok = ZSBT.Addon and ZSBT.Addon.PerfBegin and ZSBT.Addon:PerfBegin("PE.Flush")
	self:flushBucket()
	if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
end

function Engine:Enable()
	if self._enabled then return end
	if self.ApplyConfig then self:ApplyConfig() end

	if not self._frame then
		self._frame = CreateFrame("Frame")
	end

	self._frame:SetScript("OnUpdate", function(_, elapsed)
		Engine:_onUpdate(elapsed)
	end)
	self._enabled = true
	self:_ensureDamageMeterTicker()
end

function Engine:Disable()
	if not self._enabled then return end
	if self._frame then
		self._frame:SetScript("OnUpdate", nil)
	end
	self._enabled = false
	self:_stopDamageMeterTicker()
	self._accumulator = 0
	wipeTable(self._bucket)
	resetPetMerge(self)
	self._qHead = 1
	self._qTail = 0
	self._qCount = 0
	self._dmgMeterLastTotals = {}
	self._lastOutgoingSignalAt = 0
	if StateManager then
		StateManager:clear()
	end
end
