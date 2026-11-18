local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {

}

-- Pet signature: Water Elemental frost damage (school 16).
function mod.petSchoolHit(school, helpers)
	if helpers and helpers.safeNumber and helpers.safeNumber(school) then
		if school == 16 then
			local fam = helpers.family and helpers.family() or nil
			if fam and fam:find("water", 1, true) and fam:find("elemental", 1, true) then return true end
		end
	end
	return false
end

function mod.petSchoolHitRecent(self, school, lastPlayerSpellId, helpers)
	return mod.petSchoolHit(school, helpers)
end

ZSBT.ClassDB.Register("MAGE", mod)
return mod
