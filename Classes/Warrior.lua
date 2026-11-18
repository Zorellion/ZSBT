-- Classes/Warrior.lua — Warrior-specific combat attribution
--
-- DoTs: Rend (physical ticks, no spellId on UNIT_COMBAT), Thunder Clap.
-- Rend gets a dedicated tick classifier (onPhysicalWound) ported verbatim
-- from Event_Collector's inline state machine.

local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {
	{ names = { "Rend" },           ids = { 772 },  school = 1 },
	{ names = { "Thunder Clap" },   ids = { 6343 }, school = 1 },
}

-- Cast seeding: Rend cast starts tick tracking.
local function isRendSpell(spellId)
	local e = ZSBT.ClassDB.DotEntry and ZSBT.ClassDB.DotEntry(spellId)
	return e ~= nil and e._canon == "Rend"
end

function mod.onCast(self, spellId, spellName, t)
	if isRendSpell(spellId) then
		self._rendSpellId = spellId
		self._rendLastCastAt = t
		self._rendNextTickAt = t + 3.0
		self._rendInitialHitAmt = nil
		self._rendTickState = nil
	end
end

-- Matched-physical seeding: a physical WOUND correlated to a Rend cast
-- also (re)seeds the tick clock with the observed amount.
function mod.onMatchedPhysical(self, spellId, t, amount)
	if isRendSpell(spellId) then
		self._rendSpellId = spellId
		self._rendLastCastAt = t
		self._rendNextTickAt = t + 3.0
		self._rendInitialHitAmt = amount
		self._rendTickState = nil
	end
end

-- Rend tick classifier. Emits periodic Rend ticks; EC continues to the
-- generic physical path afterwards (same as the old inline block).
function mod.onPhysicalWound(self, ctx)
	local t = ctx.t
	local amount = ctx.amount
	local isCrit = ctx.isCrit
	local actionStr = ctx.actionStr
	local cachedHasTargetDebuffSpellId = ctx.hasTargetDebuff
	local isPlayerAutoAttackActive = ctx.autoAttackActive
	local OutDbgLevel = ctx.outDbgLevel
	local ECPrint = ctx.ecPrint
	local dbgSafe = ctx.dbgSafe
	local safeUnitName = ctx.safeUnitName
	local emit = ctx.emit
	local IsSafeNumber = ZSBT.IsSafeNumber

	local rAt = self._rendLastCastAt
	if type(rAt) ~= "number" then return end
	local ageCast = t - rAt
	if not (ageCast >= 0 and ageCast <= 24.0 and actionStr == "WOUND"
		and IsSafeNumber(amount) and amount > 0) then return end

	local dl = OutDbgLevel()
	local debuffOk = cachedHasTargetDebuffSpellId(self._rendSpellId or 772)
	local nextTickAt = self._rendNextTickAt
	local isNearExpected = false
	local dtNext = nil
	if type(nextTickAt) == "number" then
		dtNext = t - nextTickAt
		if dtNext >= -0.20 and dtNext <= 0.90 then
			isNearExpected = true
		end
	end
	if debuffOk ~= true and ageCast <= 0.25 and not self._rendInitialHitAmt then
		if IsSafeNumber(amount) and amount > 0 then
			self._rendInitialHitAmt = amount
		end
	end
	local allowRendAttrib = true
	if debuffOk ~= true then
		if isPlayerAutoAttackActive() then
			if dl >= 5 then
				ECPrint(("REND_DEBUFF_MISS aa=1 ageCast=%.3f amt=%s"):format(ageCast, dbgSafe(amount)))
			end
			allowRendAttrib = false
		end
		if allowRendAttrib and dl >= 5 then
			ECPrint(("REND_DEBUFF_MISS aa=0 ageCast=%.3f amt=%s"):format(ageCast, dbgSafe(amount)))
		end
	end
	if allowRendAttrib ~= true then return end

	local st = self._rendTickState
	if type(st) ~= "table" then
		st = { amt = nil, lastAt = 0, streak = 0, lastEmitAt = 0 }
		self._rendTickState = st
	end
	if dl >= 5 then
		ECPrint(("REND_CLASS ageCast=%.3f amt=%s next=%s near=%s debuffOk=%s aa=%s cand=%s streak=%s lastAt=%s")
			:format(ageCast, dbgSafe(amount), dbgSafe(nextTickAt), dbgSafe(isNearExpected), dbgSafe(debuffOk), dbgSafe(isPlayerAutoAttackActive()), dbgSafe(st.amt), dbgSafe(st.streak), dbgSafe(st.lastAt)))
	end
	local seededAlready = (type(st.lastAt) == "number" and st.lastAt > 0)
	local inFirstTickWindow = false
	if debuffOk == true then
		inFirstTickWindow = (ageCast >= 1.6 and ageCast <= 7.0)
	end
	local canSeed = (not seededAlready) and ((isNearExpected == true and (not dtNext or dtNext >= -0.20)) or inFirstTickWindow == true)
	if canSeed and IsSafeNumber(self._rendInitialHitAmt) and self._rendInitialHitAmt > 0 then
		if not (amount <= (self._rendInitialHitAmt * 0.25)) then
			canSeed = false
		end
	end
	if canSeed then
		st.amt = amount
		st.streak = 1
		st.lastAt = t
	end
	local dt = t - (st.lastAt or 0)
	local isSame = false
	if IsSafeNumber(st.amt) and st.amt > 0 then
		local diff = math.abs(amount - st.amt)
		local tol = math.max(10, st.amt * 0.18)
		if diff <= tol then isSame = true end
	end
	local tickLike = (dt >= 1.4 and dt <= 5.8)
	local clusteredRepeat = (isSame == true and dt >= 0.08 and dt <= 0.40)
	local allowTickStateUpdate = tickLike or clusteredRepeat
	if dl >= 5 then
		ECPrint(("REND_CLASS2 dt=%.3f tickLike=%s isSame=%s allowState=%s cand=%s streak=%s")
			:format(dt, dbgSafe(tickLike), dbgSafe(isSame), dbgSafe(allowTickStateUpdate), dbgSafe(st.amt), dbgSafe(st.streak)))
	end
	if allowTickStateUpdate then
		if isSame then
			st.streak = (st.streak or 0) + 1
		else
			if not (debuffOk ~= true and (st.streak or 0) >= 2) then
				st.amt = amount
				st.streak = 1
			end
		end
		st.lastAt = t
		if debuffOk ~= true and isSame == true and (st.streak or 0) >= 2 then
			if dt >= 2.2 and dt <= 3.8 then
				self._rendNextTickAt = t + 3.0
			end
		end
	end
	local firstTickLike = false
	if debuffOk == true then
		firstTickLike = (ageCast >= 1.8 and ageCast <= 6.5)
	elseif isNearExpected == true then
		firstTickLike = true
	end
	local canEmit = false
	if debuffOk == true then
		canEmit = (st.streak or 0) >= 2 or firstTickLike == true
	else
		local streakOk = (st.streak or 0) >= 2
		local spacingOk = (dt >= 2.2 and dt <= 3.8)
		canEmit = streakOk and (isNearExpected == true or spacingOk == true)
	end
	if dl >= 5 then
		ECPrint(("REND_DECIDE canEmit=%s streak=%s near=%s firstTickLike=%s")
			:format(dbgSafe(canEmit), dbgSafe(st.streak), dbgSafe(isNearExpected), dbgSafe(firstTickLike)))
	end
	if canEmit then
		local dtEmit = t - (st.lastEmitAt or 0)
		if dtEmit < 0 or dtEmit > 0.80 then
			st.lastEmitAt = t
			local tName = safeUnitName("target")
			emit("OUTGOING_DAMAGE_COMBAT", {
				timestamp = t,
				amount = amount,
				amountText = (IsSafeNumber(amount) and tostring(amount)) or nil,
				spellId = self._rendSpellId or 772,
				amountSource = "UNIT_COMBAT_DOT",
				targetName = tName,
				isCrit = isCrit,
				isPeriodic = true,
				schoolMask = 1,
			})
			local dl2 = OutDbgLevel()
			if dl2 >= 5 then
				ECPrint(("REND_EMIT ageCast=%.3f amt=%s cand=%s streak=%s near=%s debuffOk=%s")
					:format(ageCast, dbgSafe(amount), dbgSafe(st.amt), dbgSafe(st.streak), dbgSafe(isNearExpected), dbgSafe(debuffOk)))
			end
			self._rendNextTickAt = t + 3.0
			self._lastOutgoingCombatAt = t
			self._lastOutgoingCombatTargetName = tName
		end
	end
end

ZSBT.ClassDB.Register("WARRIOR", mod)
return mod
