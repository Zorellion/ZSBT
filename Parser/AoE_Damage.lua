-- AoE damage tracker.
--
-- UNIT_HEALTH deltas are only tracked for "target"/"mouseover"/"player" in
-- Event_Collector, so damage your spells deal to *other* nameplated mobs
-- (Consecration, Blizzard, Rain of Fire, cleave-style multi-target hits)
-- never produces a number. This module watches nameplate units and emits
-- AOE_HEALTH_DAMAGE for each observed health drop. Pulse_Engine attributes
-- the hit to a recent player cast or a tracked periodic effect before it
-- becomes scroll text — unattributed drops are dropped there, not here.
--
-- Hard limits honoured here:
--   * secret values are never compared or used in arithmetic; unsafe
--     UnitHealth/UnitHealthMax reads simply skip the event
--   * nameplate tokens are reused for different units — baselines reset on
--     GUID change and on NAME_PLATE_UNIT_REMOVED
--   * plates that are also "target"/"mouseover" are skipped so hits are not
--     double-counted with the existing target path

local ADDON_NAME, ZSBT = ...

local AoE = {}
ZSBT.AoEDamage = AoE

AoE._enabled = false
AoE._frame = nil
AoE._lastHealth = {}
AoE._lastGuid = {}
AoE._verbose = false
AoE._stats = { events = 0, dedup = 0, notAttackable = 0, secret = 0, noBaseline = 0, nonDamage = 0, clamped = 0, emitted = 0, ucEvents = 0, ucEmitted = 0, ucHeal = 0 }
AoE._dbgLastModPrint = 0

local function dbgPrint(msg)
	local Addon = ZSBT and ZSBT.Addon
	if Addon and Addon.Print then
		Addon:Print(msg)
	end
end

local function now()
	return (GetTime and GetTime()) or 0
end

local function emit(eventType, payload)
	local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
	if ec and ec._sink then
		ec._sink(eventType, payload)
	end
end

local function safeUnitName(unit)
	if not UnitName then return nil end
	local ok, name = pcall(UnitName, unit)
	if ok and ZSBT.IsSafeString and ZSBT.IsSafeString(name) and name ~= "" then
		return name
	end
	return nil
end

local function unitIsToken(unit, token)
	if not UnitIsUnit then return false end
	local ok, res = pcall(UnitIsUnit, unit, token)
	return ok and res == true
end

-- Called by Event_Collector:handleUnitHealth for nameplateN units only.
function AoE:HandleUnitHealth(unit)
	if self._enabled ~= true then return end
	if type(unit) ~= "string" or not unit:match("^nameplate%d+$") then return end
	self._stats.events = self._stats.events + 1

	-- Dedup: the target/mouseover paths already emit for these units.
	if unitIsToken(unit, "target") or unitIsToken(unit, "mouseover") then
		self._stats.dedup = self._stats.dedup + 1
		return
	end

	-- Only hostile, attackable units — friendly nameplates (party players,
	-- NPCs) can show health changes we must not claim.
	if UnitCanAttack then
		local okA, canAttack = pcall(UnitCanAttack, "player", unit)
		if not (okA and canAttack == true) then
			self._stats.notAttackable = self._stats.notAttackable + 1
			return
		end
	end

	local health = UnitHealth and UnitHealth(unit) or nil
	local healthMax = UnitHealthMax and UnitHealthMax(unit) or nil
	if not ZSBT.IsSafeNumber(health) or not ZSBT.IsSafeNumber(healthMax) then
		-- Secret or unavailable: drop cached baseline so a stale number
		-- never survives into a later readable delta.
		self._stats.secret = self._stats.secret + 1
		self._lastHealth[unit] = nil
		return
	end

	local guid = nil
	if UnitGUID then
		local ok, g = pcall(UnitGUID, unit)
		if ok and type(g) == "string" then
			guid = g
		end
	end

	local lastGuid = self._lastGuid[unit]
	if guid ~= nil and lastGuid ~= nil and guid ~= lastGuid then
		self._lastGuid[unit] = guid
		self._lastHealth[unit] = health
		return
	end
	if guid ~= nil and lastGuid == nil then
		self._lastGuid[unit] = guid
	end

	local oldHealth = self._lastHealth[unit]
	self._lastHealth[unit] = health
	if not ZSBT.IsSafeNumber(oldHealth) then
		self._stats.noBaseline = self._stats.noBaseline + 1
		return
	end

	local delta = oldHealth - health
	if delta <= 0 then
		self._stats.nonDamage = self._stats.nonDamage + 1
		return
	end

	-- Same plausibility clamp as the target path: scripted resets/regen on
	-- some units produce absurd deltas unrelated to spells.
	local maxN = healthMax
	if ZSBT.IsSafeNumber(maxN) and maxN > 0 and delta > 50000 and (delta / maxN) >= 0.05 then
		self._stats.clamped = self._stats.clamped + 1
		return
	end

	self._stats.emitted = self._stats.emitted + 1
	if self._verbose then
		local t = now()
		if t - self._dbgLastModPrint >= 0.1 then
			self._dbgLastModPrint = t
			dbgPrint(("AODEBUG emit unit=%s amt=%s tgt=%s"):format(
				tostring(unit), tostring(math.floor(delta + 0.5)), tostring(safeUnitName(unit))))
		end
	end

	emit("AOE_HEALTH_DAMAGE", {
		timestamp = now(),
		unit = unit,
		amount = delta,
		amountText = tostring(math.floor(delta + 0.5)),
		targetName = safeUnitName(unit),
		health = health,
		healthMax = healthMax,
	})
end

-- Called by Event_Collector:handleUnitCombat for nameplateN units that are
-- NOT the player's target/mouseover. UNIT_COMBAT fires per victim with the
-- damage action, so multi-target hits (Consecration, Blizzard, cleaves)
-- arrive once per mob. The amount may be secret — it always travels through
-- the collector's rawPipe so downstream display paths stay taint-safe.
function AoE:HandleUnitCombat(unit, action, descriptor, amount, school)
	if self._enabled ~= true then return end
	if type(unit) ~= "string" or not unit:match("^nameplate%d+$") then return end
	if amount == nil then return end
	self._stats.ucEvents = self._stats.ucEvents + 1

	if unitIsToken(unit, "target") or unitIsToken(unit, "mouseover") then
		self._stats.dedup = self._stats.dedup + 1
		return
	end

	if UnitCanAttack then
		local okA, canAttack = pcall(UnitCanAttack, "player", unit)
		if not (okA and canAttack == true) then
			self._stats.notAttackable = self._stats.notAttackable + 1
			return
		end
	end

	local actionStr = ZSBT.IsSafeString and ZSBT.IsSafeString(action) and action or nil
	if actionStr == "HEAL" then
		self._stats.ucHeal = self._stats.ucHeal + 1
		return
	end
	-- WOUND (or nil action on clients that omit it) carries damage amounts.
	if actionStr ~= nil and actionStr ~= "WOUND" then
		return
	end

	local isCrit = false
	if type(descriptor) == "string" and descriptor:upper():find("CRIT", 1, true) then
		isCrit = true
	end

	local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
	if not (ec and ec._rawPipe) then return end
	local pipeId = ec._rawPipeCount + 1
	ec._rawPipeCount = pipeId
	ec._rawPipe[pipeId] = amount

	self._stats.ucEmitted = self._stats.ucEmitted + 1
	if self._verbose then
		local t = now()
		if t - self._dbgLastModPrint >= 0.1 then
			self._dbgLastModPrint = t
			local amt = ZSBT.IsSafeNumber(amount) and tostring(math.floor(amount + 0.5)) or "<secret>"
			dbgPrint(("AODEBUG uc unit=%s action=%s amt=%s tgt=%s"):format(
				tostring(unit), tostring(actionStr), amt, tostring(safeUnitName(unit))))
		end
	end

	emit("AOE_UNIT_COMBAT", {
		timestamp = now(),
		unit = unit,
		rawPipeId = pipeId,
		isCrit = isCrit,
		schoolMask = ZSBT.IsSafeNumber(school) and school or nil,
		targetName = safeUnitName(unit),
	})
end

function AoE:Enable()
	if self._enabled then return end
	self._enabled = true
	if not self._frame then
		self._frame = CreateFrame("Frame")
		self._frame:SetScript("OnEvent", function(_, event, unit)
			if event == "NAME_PLATE_UNIT_REMOVED" and type(unit) == "string" then
				self._lastHealth[unit] = nil
				self._lastGuid[unit] = nil
			end
		end)
		self._frame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
	end
end

function AoE:Disable()
	self._enabled = false
	if self._frame then
		self._frame:UnregisterAllEvents()
	end
	wipe(self._lastHealth)
	wipe(self._lastGuid)
end

return AoE
