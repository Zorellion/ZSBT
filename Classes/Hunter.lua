local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {

		{ names = { "Serpent Sting" }, ids = { 1978 }, school = 8 },

	{ names = { "Viper Sting" }, ids = { 3034 }, school = 8 },
	{ names = { "Immolation Trap" }, ids = { 13795 }, school = 8 },
	{ names = { "Explosive Trap" }, ids = { 13813 }, school = 8 },
}

-- Pet signature: hunter pet melee damage is physical (school 1).
function mod.petSchoolHit(school, helpers)
	if helpers and helpers.safeNumber and helpers.safeNumber(school) then
		if school == 1 then return true end
	end
	return false
end

function mod.petSchoolHitRecent(self, school, lastPlayerSpellId, helpers)
	return mod.petSchoolHit(school, helpers)
end

ZSBT.ClassDB.Register("HUNTER", mod)
return mod
