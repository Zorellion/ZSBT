-- Classes/Warlock.lua — Warlock-specific combat attribution
--
-- DoTs (name-primary; ids are fallback fast path):
--   Corruption / Agony / Unstable Affliction / Seed of Corruption / Haunt = shadow (32)
--   Immolate = fire (4)
-- Channel: Drain Life (channeled, emits each tick)
-- Pet rules: Imp fire hits are pet damage, never player DoTs; felhunter/
-- voidwalker/succubus shadow bites stay out of the recent-cast window.

local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {
	{ names = { "Corruption" },             ids = { 172 },     school = 32 },
	{ names = { "Agony" },                  ids = { 980 },     school = 32 },
	{ names = { "Unstable Affliction" },    ids = { 30108 },  school = 32 },
	{ names = { "Seed of Corruption" },     ids = { 27243 },  school = 32 },
	{ names = { "Haunt" },                  ids = { 48181 },  school = 32 },
	{ names = { "Immolate" },               ids = { 348 },    school = 4 },
}

mod.channels = {
	{ names = { "Drain Life" }, ids = { 234153 }, duration = 6.0, tickMin = 0.12 },
	{ names = { "Drain Soul" }, ids = { 1120, 198590 }, duration = 5.0, tickMin = 0.12 },
}

local function isImpPet(helpers)
	local fam = helpers and helpers.family and helpers.family() or nil
	return fam ~= nil and fam == "imp"
end

-- Imp fire hits are pet damage — never attribute them to player DoTs.
function mod.dotGuard(entry, school, helpers)
	if helpers and helpers.safeNumber and helpers.safeNumber(school)
		and school == 4 and isImpPet(helpers) then
		return false
	end
	return nil
end

-- Pet signature: Imp damage is fire (school 4).
function mod.petSchoolHit(school, helpers)
	if helpers and helpers.safeNumber and helpers.safeNumber(school)
		and school == 4 then
		return true
	end
	return false
end

-- Recent-cast variant: fire hits near a recent DoT/nuke cast still belong
-- to the Imp (prevents pet fire from being claimed as player damage).
function mod.petSchoolHitRecent(self, school, lastPlayerSpellId, helpers)
	if not (helpers and helpers.safeNumber and helpers.safeNumber(school)) then
		return false
	end
	if school ~= 4 then return false end
	if type(lastPlayerSpellId) ~= "number" then return false end
	-- Recent cast was a known warlock dot or Shadow Bolt -> keep fire as pet.
	local e = ZSBT.ClassDB.DotEntry and ZSBT.ClassDB.DotEntry(lastPlayerSpellId)
	if e and e.school == 32 then
		return true
	end
	local sn = helpers.cleanName and helpers.cleanName(lastPlayerSpellId) or nil
	if sn == "Shadow Bolt" then return true end
	return false
end

-- Channel seeding (Drain Life / Drain Soul).
function mod.onCast(self, spellId, spellName, t)
	local ch = ZSBT.ClassDB.ChannelMatch(spellId)
	if not ch then return end
	self._channel = {
		untilAt = t + (ch.duration or 6.0),
		lastTickAt = 0,
		spellId = spellId,
		tickMin = ch.tickMin or 0.12,
	}
end

ZSBT.ClassDB.Register("WARLOCK", mod)
return mod
