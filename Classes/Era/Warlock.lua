-- Classes/Era/Warlock.lua — Warlock attribution for the Forever client
-- (Camelot, project 18). Loaded ONLY on Forever via the ClassDB gate —
-- mod.client = "era" makes this file inert on Retail.
--
-- Name-primary by design: Forever spellIds are unverified and era pets
-- use RANKED spells (a different id per rank), so no table below carries
-- ids — the engine resolves each combat-log id to its localized name and
-- matches `names` instead. The spellbook layer (ZSBT.Spellbook) and the
-- learned-school table fill in live data the seed doesn't declare.
-- Schools are the stable classic values: shadow 32, fire 4, melee 1.
-- VERIFY against the first real Forever combat log — custom clients can
-- rename or re-school spells.

local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}
mod.client = "era"

mod.dots = {
	{ names = { "Corruption" },          school = 32 },
	{ names = { "Curse of Agony" },      school = 32 },
	{ names = { "Curse of Doom" },       school = 32 },
	{ names = { "Siphon Life" },         school = 32 },
	{ names = { "Immolate" },            school = 4 },
	-- Later-era additions: harmless if Forever lacks them (name match
	-- only fires on a real cast), correct if a custom build has them.
	{ names = { "Unstable Affliction" }, school = 32 },
	{ names = { "Seed of Corruption" },  school = 32 },
	{ names = { "Haunt" },               school = 32 },
}

mod.channels = {
	{ names = { "Drain Life" },   duration = 6.0,  tickMin = 0.5, school = 32 },
	{ names = { "Drain Soul" },   duration = 16.0, tickMin = 0.5, school = 32 },
	{ names = { "Drain Mana" },   duration = 6.0,  tickMin = 0.5, school = 32 },
	-- Era Rain of Fire is channeled: 4 waves over ~8s. tickMin is kept
	-- proportional so foreign fire ticks can't ride a wide window.
	{ names = { "Rain of Fire" }, duration = 9.0,  tickMin = 1.2, school = 4 },
	{ names = { "Hellfire" },     duration = 16.0, tickMin = 0.5, school = 4 },
	-- Health Funnel deliberately absent: it drains the CASTER's health,
	-- not a target's — nothing here for it to honestly name.
}

-- No mod.schools whitelist: era wand "Shoot" damage can carry almost any
-- school (shadow/fire/frost/nature/arcane/holy wands all exist), so the
-- provable-player-school set is effectively the whole school space and a
-- foreign-school veto would eat real wand hits. Foreign suppression is
-- left to the group gate, which works off source ownership instead.

-- Union of every school an era warlock minion can produce: imp Firebolt
-- (4), succubus Lash of Pain / felhunter shadow (32), melee (1), 36 for
-- shadowfire composites. Holy/frost/arcane/nature on a pet-routed hit is
-- provably foreign. NOT family-scoped — same reasoning as Retail.
local PET_SCHOOLS = { [1] = true, [4] = true, [32] = true, [36] = true }

function mod.petSchoolAllowed(school, helpers)
	if not (helpers and helpers.safeNumber and helpers.safeNumber(school)) then
		return nil
	end
	return PET_SCHOOLS[school] == true
end

local function isImpPet(helpers)
	local fam = helpers and helpers.family and helpers.family() or nil
	return fam ~= nil and fam == "imp"
end

local function hasFireBit(school)
	return math.floor(school / 4) % 2 == 1
end

function mod.dotGuard(entry, school, helpers)
	if helpers and helpers.safeNumber and helpers.safeNumber(school)
		and school == 4 and isImpPet(helpers) then
		return false
	end
	return nil
end

-- Imp Firebolt signature, same as Retail: fire-bit hits belong to the
-- imp ONLY while an imp is actually out.
function mod.petSchoolHit(school, helpers)
	if helpers and helpers.safeNumber and helpers.safeNumber(school)
		and hasFireBit(school) and isImpPet(helpers) then
		return true
	end
	return false
end

-- Era player casts whose damage carries the fire bit — a fire hit near
-- one of these is the player's, never the imp's. (Era Shadowburn is
-- shadow, but custom builds may re-school it — harmless either way since
-- the fire-bit check runs first.)
local WARLOCK_FIRE_PLAYER_SPELLS = {
	["Immolate"] = true,
	["Searing Pain"] = true,
	["Soul Fire"] = true,
	["Rain of Fire"] = true,
	["Hellfire"] = true,
	["Conflagrate"] = true,
	["Incinerate"] = true,
	["Chaos Bolt"] = true,
	["Shadowburn"] = true,
	["Firebolt"] = true,
}

function mod.petSchoolHitRecent(self, school, lastPlayerSpellId, helpers)
	if not (helpers and helpers.safeNumber and helpers.safeNumber(school)) then
		return false
	end
	if not hasFireBit(school) then return false end
	if not isImpPet(helpers) then return false end
	if type(lastPlayerSpellId) ~= "number" then return false end
	local sn = helpers.cleanName and helpers.cleanName(lastPlayerSpellId) or nil
	if sn == nil then
		local e = ZSBT.ClassDB.DotEntry and ZSBT.ClassDB.DotEntry(lastPlayerSpellId)
		if e and e.school == 32 then
			return true
		end
		return false
	end
	if WARLOCK_FIRE_PLAYER_SPELLS[sn] then return false end
	return true
end

-- Era warlocks still don't meaningfully melee: school-1 hits are demon
-- swings or foreign traffic. Wand "Shoot" is unaffected (not physical,
-- not a swing). profile.classModule.allowAutoAttack overrides.
function mod.vetoAuto(helpers)
	local cm = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.classModule
	if cm and cm.allowAutoAttack == true then return false end
	return true
end

function mod.petPhysicalHit(school, helpers)
	return helpers and helpers.safeNumber and helpers.safeNumber(school)
		and school == 1
end

-- No guardian tables: era Summon Infernal / Ritual of Doom produce
-- ENSLAVED demons, which arrive as real pet units — their casts record
-- and claim through _petCasts like any other minion. If a Forever log
-- shows them as unverifiable guardians instead, seed GUARDIAN_SPELLS +
-- guardianSummons from that log (Retail Warlock.lua has the pattern).
function mod.onCast(self, spellId, spellName, t)
	local ch = ZSBT.ClassDB.ChannelMatch(spellId)
	if ch then
		self._channel = {
			untilAt = t + (ch.duration or 6.0),
			lastTickAt = 0,
			spellId = spellId,
			tickMin = ch.tickMin or 0.12,
			school = ch.school,
		}
	end
end

mod.toggles = {
	namePetMelee = true,
}

ZSBT.ClassDB.Register("WARLOCK", mod)
return mod
