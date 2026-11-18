local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {

		{ names = { "Frost Fever" }, ids = { 55095 }, school = 16 },

	{ names = { "Blood Plague" }, ids = { 55078 }, school = 32 },
}

local GHOUL_SUMMONS = { [46584] = true, [46585] = true, [42650] = true }

-- Pet signature: ghoul physical damage (school 1).
function mod.petSchoolHit(school, helpers)
	if helpers and helpers.safeNumber and helpers.safeNumber(school) then
		if school == 1 then
			local fam = helpers.family and helpers.family() or nil
			if fam and fam:find("ghoul", 1, true) then return true end
		end
	end
	return false
end

function mod.petSchoolHitRecent(self, school, lastPlayerSpellId, helpers)
	return mod.petSchoolHit(school, helpers)
end

-- Ghoul summon cast tracking (Death and Decay ghoul / Raise Dead ghoul).
function mod.onCast(self, spellId, spellName, t)
	if type(spellId) == "number" and GHOUL_SUMMONS[spellId] then
		self._dkGhoulSummonAt = t
	end
end

-- Unattributed physical hit after a recent ghoul summon -> guardian pet damage.
-- Ported verbatim from Event_Collector's inline DK guardian block.
function mod.onGuardianWound(self, ctx)
	local t = ctx.t
	local amount = ctx.amount
	local isCrit = ctx.isCrit
	local school = ctx.school
	local restrict = ctx.restrict
	local members = ctx.members
	local dl = ctx.dl
	local emit = ctx.emit
	local safeUnitName = ctx.safeUnitName
	local petSchoolHit = ctx.petSchoolHit
	local dedupWindow = ctx.dedupWindow
	local ECPrint = ctx.ecPrint
	local dbgSafe = ctx.dbgSafe
	local IsSafeNumber = ZSBT.IsSafeNumber

	if not (IsSafeNumber(school) and school == 1) then return false end
	local summonedAt = self._dkGhoulSummonAt
	if type(summonedAt) ~= "number" then return false end
	local ageSummon = t - summonedAt
	if not (ageSummon >= 0 and ageSummon <= 45.0) then return false end
	if not (IsSafeNumber(amount) and amount > 0 and amount <= 3000) then return false end
	local ageCast = nil
	if type(self._lastPlayerSpellAt) == "number" then
		ageCast = t - self._lastPlayerSpellAt
	end
	-- Avoid grabbing the immediate landing of a just-cast physical ability.
	if type(ageCast) == "number" and ageCast >= 0 and ageCast <= 0.15 then
		return false
	end
	-- Group-aware gate for guardian pets.
	if restrict == true and members and members > 1 then
		if not petSchoolHit(school) then
			if dl >= 4 then
				ECPrint(("PET_GUARDIAN_GROUP_SUPPRESS restrict=%s members=%s amt=%s")
					:format(dbgSafe(restrict), dbgSafe(members), dbgSafe(amount)))
			end
			return true
		end
	end
	-- Dedup against the main pet fallback and chat pet lines.
	local lastPetFb = self._lastPetFallbackAt or 0
	local lastPetChat = self._lastPetChatAt or 0
	if (t - lastPetFb) >= 0 and (t - lastPetFb) < dedupWindow then
		return true
	end
	if (t - lastPetChat) >= 0 and (t - lastPetChat) < dedupWindow then
		return true
	end
	self._lastPetFallbackAt = t
	local pipeId = self._rawPipeCount + 1
	if self._rawPipe and self._rawPipe[pipeId] ~= nil then
		local i = pipeId
		while self._rawPipe[i] ~= nil do
			i = i + 1
		end
		pipeId = i
	end
	self._rawPipeCount = pipeId
	self._rawPipe[pipeId] = amount
	if dl >= 4 then
		ECPrint(("PET_GUARDIAN_EMIT class=DK token=%s rawPipeId=%s amt=%s school=%s")
			:format(dbgSafe(self._castToken), dbgSafe(pipeId), dbgSafe(amount), dbgSafe(school)))
	end
	emit("PET_DAMAGE_COMBAT", {
		timestamp = t,
		rawPipeId = pipeId,
		amount = amount,
		amountText = tostring(amount),
		isCrit = isCrit,
		petBucket = nil,
		schoolMask = 1,
		targetName = safeUnitName("target"),
	})
	return true
end

ZSBT.ClassDB.Register("DEATHKNIGHT", mod)
return mod
