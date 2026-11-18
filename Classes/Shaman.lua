local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {

		{ names = { "Flame Shock" }, ids = { 8050 }, school = 4 },

	{ names = { "Crash Lightning" }, ids = { 187874 }, school = 8 },
}

-- Pet signature: Fire Elemental (fire 4) and Storm/Lightning Elemental
-- / Earth elemental (nature 8) damage.
function mod.petSchoolHit(school, helpers)
	if helpers and helpers.safeNumber and helpers.safeNumber(school) then
		local fam = helpers.family and helpers.family() or nil
		if school == 4 and fam ~= nil and (fam:find("fire", 1, true) and fam:find("elemental", 1, true)) then return true end
		if school == 8 and fam ~= nil and (((fam:find("storm", 1, true) or fam:find("earth", 1, true) or fam:find("lightning", 1, true)) and fam:find("elemental", 1, true))) then return true end
	end
	return false
end

function mod.petSchoolHitRecent(self, school, lastPlayerSpellId, helpers)
	return mod.petSchoolHit(school, helpers)
end

ZSBT.ClassDB.Register("SHAMAN", mod)
return mod
