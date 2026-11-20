-- Classes/Warrior.lua — Warrior-specific combat attribution
--
-- Warrior is the pure-physical baseline: no permanent pet, no guardian
-- summons, nearly every hit school-1. That means:
--
--   * Physical periodic ticks CANNOT be school-matched — a school-1 WOUND
--     is indistinguishable from a melee swing. Rend survives because it
--     ships a dedicated amount-pattern classifier (onPhysicalWound,
--     ported verbatim from Event_Collector's inline state machine).
--     Deep Wounds / Thunderous Roar bleeds have no equivalent and stay
--     generic — honest floor, same as guardian physical on other
--     classes.
--   * No guardian windows at all. Ravager is PLAYER-sourced on the
--     verified client (throw + ticks under the player GUID), so its
--     cast budget can name what the claim window reaches; ticks
--     beyond it stay generic physical.
--   * mod.toggles stays empty: there is no pet melee to name and no
--     guardian spellbook to resolve, so the Class page shows no
--     class toggles.
--
-- Thunderous Roar is deliberately NOT in mod.dots: cast id == damage
-- id, and a dots entry would seed it as periodic, which can misroute
-- its own direct hit (the Blood Boil lesson on DK).

local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {
	{ names = { "Rend" },         ids = { 772 },    school = 1 },
	{ names = { "Thunder Clap" }, ids = { 6343 },   school = 1 }, -- bleed rider, physical
	{ names = { "Deep Wounds" },  ids = { 262111 }, school = 1 }, -- mastery proc, never cast directly
}

-- Channeled: Bladestorm ticks every ~1s for the channel duration. Auto
-- attacks are suppressed while channeling, so the window can't eat a
-- player swing. Ravager is NOT here: its damage comes from the weapon
-- NPC (guardian physical), not a player channel.
mod.channels = {
	{ names = { "Bladestorm" }, ids = { 227847 }, duration = 6.0, tickMin = 0.6 },
	-- Ravager: player-sourced ticks (156287) every ~1-2s for ~12s —
	-- effectively a channel the weapon runs for you. Cast 228920 opens
	-- the window; tick lines claim inside it. Autos (melee lines) are
	-- safe: the channel claims tick-kind lines only.
	-- Ravager is NOT here: it fires with no SPELL_CAST_SUCCESS on this
	-- client (verified on the prot log), so a channel window would never
	-- open. Its ticks are caught by the debuff-gated classifier below.
}

-- Per-cast-instance naming budget: AoE/multi-hit casts may name several
-- hits; single-target stays at 1. Ids are best-known pre-Midnight —
-- verify against a real warrior combat log; wrong ids simply never
-- match (safe under-naming). Manual teaching fills any drift.
mod.castBudget = {
	[1680]   = 12, -- Whirlwind cast id (log-verified: emits double cast records)
	[199658] = 10, -- Whirlwind second cast id (log-verified; dmg ids 199658/199850/411547)
	[845]    = 6,  -- Cleave (frontal cleave)
	[6343]   = 10, -- Thunder Clap (AoE direct; bleed is unnameable)
	[435222] = 10, -- Thunder Blast (Mountain Thane TC replacement, log-verified)
	[46968]  = 10, -- Shockwave (cone AoE)
	[6572]   = 10, -- Revenge (frontal AoE, log-verified)
	[385952] = 5,  -- Shield Charge cast id (damage id 385954, drift log-verified)
	[118000] = 10, -- Dragon Roar
	[397364] = 10, -- Thunderous Roar (direct AoE; bleed is unnameable)
	[52174]  = 10, -- Heroic Leap (landing AoE)
	[227847] = 8,  -- Bladestorm (fallback; channel usually catches it)
	[184367] = 6,  -- Rampage (multi-strike; verify damage ids in log)
	[315720] = 6,  -- Onslaught (multi-strike Fury; verify)
	[385059] = 8,  -- Odyn's Fury (multi-component; verify)
	[376079] = 8,  -- Spear of Bastion (if still in kit; verify)
	-- Ravager button cast id (user-verified 1235113). The throw damage
	-- (228920) pairs via this budget; periodic ticks (156287) under the
	-- Ravaged debuff are claimed by ravagerWound — which also covers the
	-- Whirling Blade proc variant that produces no cast record at all.
	[1235113] = 8,
}

-- No pet spells to match, no pet physical damage — warrior has no
-- permanent or controllable pet.
function mod.petSchoolHit(school, helpers)
	return false
end

function mod.petSchoolHitRecent(self, school, lastPlayerSpellId, helpers)
	return false
end

function mod.petPhysicalHit(school, helpers)
	return false
end

-- The module supports no class toggles: nothing to name for pets or
-- guardians. ClassDB.SupportsToggle() hides every toggle on the page.
mod.toggles = {}

-- Cast seeding: Rend cast starts tick tracking; Bladestorm opens the
-- channel window.
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
	local ch = ZSBT.ClassDB.ChannelMatch(spellId)
	if ch then
		self._channel = {
			untilAt = t + (ch.duration or 2.0),
			lastTickAt = 0,
			spellId = spellId,
			tickMin = ch.tickMin or 0.12,
		}
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
			local lastDotAt = self._lastDotEmitAt or 0
			if self._lastDotEmitSpellId == (self._rendSpellId or 772)
				and (t - lastDotAt) >= 0 and (t - lastDotAt) < 0.35 then
				return
			end
			self._lastDotEmitAt = t
			self._lastDotEmitSpellId = self._rendSpellId or 772
			local tName = safeUnitName("target")
			local pipeId = self._rawPipeCount + 1
			self._rawPipeCount = pipeId
			self._rawPipe[pipeId] = amount
			emit("OUTGOING_DAMAGE_COMBAT", {
				timestamp = t,
				rawPipeId = pipeId,
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

-- Ravager tick classifier. Ravager produces NO cast record client-side
-- (prot log-verified: 228920 throw + "Ravaged" debuff 1299405 appear
-- with no SPELL_CAST_SUCCESS), so cast pairing, budgets, and channel
-- windows all miss it. The Ravaged debuff is visible on the target —
-- gate on it: ticks are a stable ~2.0s school-1 cadence, so a wound
-- landing 1.8-2.4s after the last named tick while the debuff is up
-- claims the Ravager name (156287). The first tick has no anchor and
-- stays generic; Devastator/Phalanx procs colliding on cadence can
-- steal a single name — bounded, and better than the all-generic floor.
local RAVAGER_DEBUFF = 1299405
local RAVAGER_TICK_SID = 156287

local function ravAudit(msg)
	local ZB = ZSBT.ZBattleText
	if ZB and ZB.Audit then
		ZB:Audit(msg)
	end
end

local function ravagerWound(self, ctx)
	local t = ctx.t
	local amount = ctx.amount
	local isCrit = ctx.isCrit
	local actionStr = ctx.actionStr
	local cachedHasTargetDebuffSpellId = ctx.hasTargetDebuff
	local safeUnitName = ctx.safeUnitName
	local emit = ctx.emit
	local IsSafeNumber = ZSBT.IsSafeNumber

	if actionStr ~= "WOUND" then return end
	local ravDebuff = cachedHasTargetDebuffSpellId(RAVAGER_DEBUFF)
	if ravDebuff ~= true then
		if self._ravTickAt ~= nil then
			self._ravTickAt = nil
			ravAudit("RAVWIN close")
		end
		return
	end
	local last = self._ravTickAt
	if type(last) ~= "number" then
		-- No anchor yet: mark the debuff window so the NEXT hit at tick
		-- cadence can claim. First tick stays generic by design.
		self._ravTickAt = t
		ravAudit("RAVWIN open")
		return
	end
	local dt = t - last
	if dt < 1.8 then return end
	if dt > 2.4 then
		-- Anchor expired without a claim inside a live debuff window.
		-- Re-anchor so the next in-cadence hit can claim — without this
		-- the classifier went permanently dead after one overshoot.
		self._ravTickAt = t
		ravAudit(("RAV reanchor dt=%.2f"):format(dt))
		return
	end
	self._ravTickAt = t
	ravAudit(("RAV claim dt=%.2f"):format(dt))
	local pipeId = self._rawPipeCount + 1
	self._rawPipeCount = pipeId
	self._rawPipe[pipeId] = amount
	local tName = safeUnitName("target")
	emit("OUTGOING_DAMAGE_COMBAT", {
		timestamp = t,
		rawPipeId = pipeId,
		amount = amount,
		amountText = (IsSafeNumber(amount) and tostring(amount)) or nil,
		spellId = RAVAGER_TICK_SID,
		amountSource = "UNIT_COMBAT_DOT",
		targetName = tName,
		isCrit = isCrit,
		isPeriodic = true,
		schoolMask = 1,
	})
	self._lastOutgoingCombatAt = t
	self._lastOutgoingCombatTargetName = tName
end

-- onPhysicalWound entry: run the Ravager check BEFORE the Rend block —
-- the Rend classifier early-returns when no Rend cast exists, which is
-- always true for prot/fury, and would starve the Ravager check.
local physicalWoundInner = mod.onPhysicalWound
function mod.onPhysicalWound(self, ctx)
	ravagerWound(self, ctx)
	return physicalWoundInner(self, ctx)
end

ZSBT.ClassDB.Register("WARRIOR", mod)
return mod
