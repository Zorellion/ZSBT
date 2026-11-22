-- Classes/Shaman.lua — Shaman-specific combat attribution
--
-- DoTs (name-primary; ids are fallback fast path):
--   Voltaic Blaze = nature (8) — Stormbringer's Flame Shock replacement
--   Flame Shock = fire (4) — Farseer / non-Stormbringer path
-- Ground channel: Earthquake — instant ground AoE, ticks ~1s for ~6s;
--   same pattern as Warlock Rain of Fire (ticks carry no cast record).
-- Pets: Storm/Fire/Earth Elementals and Feral Spirit wolves. Elemental
-- damage overlaps the player's own schools, so pet claims stay
-- family-gated and recent-cast-vetoed — a bolt near your own Lightning
-- Bolt cast is never the elemental's.
-- Enhancement: NO vetoAuto — melee swings are real throughput there.

local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {
	-- Voltaic Blaze: impact reports nature (8) but the burn ticks report
	-- elemental-composite fire|nature (12) — dual-school declaration or
	-- every tick fails the school-fit gate and goes generic. The DoT
	-- also spreads to nearby enemies, so it gets the multi-mob anchor
	-- (aoe) letting off-target ticks claim too.
	{ names = { "Voltaic Blaze" }, ids = { 470057 },          school = { 8, 12 }, aoe = true },
	{ names = { "Flame Shock" },   ids = { 188389, 8050 },    school = 4 },
}

mod.channels = {
	-- Earthquake: instant ground AoE, ticks ~1s for ~6s (haste-scaled).
	-- Ticks carry no cast record — the cast seeds a claim window.
	{ names = { "Earthquake" }, ids = { 462620, 61882 }, duration = 6.5, tickMin = 0.6, school = 8 },
}

-- Zero-enemy-damage casts: a wound can never honestly wear these
-- names — not via dot pools, channels, pending-cast stamps, or the
-- make-it-work recency claim, and they must not suppress DoT
-- attribution as a "recent cast". NEVER list a dot/channel name.
mod.exclude = {
	"Stormkeeper",
	"Ascendance",
	"Astral Shift",
	"Spirit Walk",
	"Ghost Wolf",
	"Spiritwalker's Grace",
	"Capacitor Totem",
	"Earthgrab Totem",
	"Wind Rush Totem",
	"Hex",
	"Purge",
	"Greater Purge",
	"Wind Shear",
	"Earth Shield",
	"Lightning Shield",
	"Flametongue Weapon",
	"Frostbrand Weapon",
	"Earthliving Weapon",
	"Windfury Weapon",
	"Skyfury",
	"Heroism",
	"Bloodlust",
	"Reincarnation",
	"Ancestral Spirit",
	"Ancestral Guidance",
	"Nature's Swiftness",
	"Healing Stream Totem",
	"Healing Tide Totem",
	"Mana Spring Totem",
	"Mana Tide Totem",
	"Tremor Totem",
	"Poison Cleansing Totem",
	"Grounding Totem",
	"Stoneskin Totem",
	"Tranquil Air Totem",
	"Skyfury Totem",
	"Stone Bulwark Totem",
	"Counterstrike Totem",
	"Static Field Totem",
	"Totemic Recall",
	"Totemic Projection",
	"Earthen Wall Totem",
	"Doom Winds",
	"Feral Spirit",
	"Summon Fire Elemental",
	"Summon Storm Elemental",
	"Summon Earth Elemental",
	"Ancestral Wolf Affinity",
	"Cleanse Spirit",
	"Far Sight",
	"Water Walking",
	"Water Breathing",
	"Astral Recall",
	"Water Shield",
	"Tidal Waves",
	"Thunderstrike Ward",
	"Call of the Ancestors",
}

-- Per-cast-instance naming budget for the recency-stamp paths: how many
-- hits one cast may claim. Elemental's Mastery (Elemental Overload)
-- makes single casts land multiple times — one LB can produce a base
-- hit plus overloads, and Stormkeeper guarantees overloads on top.
-- AoE nukes claim several across a dummy group.
mod.castBudget = {
	[188196] = 4,    -- Lightning Bolt (base + Mastery overloads)
	[188443] = 10,   -- Chain Lightning (multi-target + overloads)
	[452201] = 10,   -- Tempest (Stormbringer AoE, replaces LB)
	[51505]  = 3,    -- Lava Burst (Ascendance overloads)
	[470057] = 2,    -- Voltaic Blaze (impact)
	[51490]  = 6,    -- Thunderstorm (AoE knockback)
	[375982] = 6,    -- Primordial Wave (AoE)
	[192222] = 8,    -- Liquid Magma Totem (eruption AoE)
	[197214] = 6,    -- Sundering (Enhancement line AoE)
	[187874] = 6,    -- Crash Lightning (frontal cleave)
	[117014] = 2,    -- Elemental Blast
	[196840] = 2,    -- Frost Shock
}

-- Provable damage schools (derived on Stormbringer Ele: 4, 8, 16, 72):
--   1 pet/player melee, 4 fire, 8 nature, 12 fire|nature (Elemental
--   Unity, elemental-composite hits), 16 frost (Frost Shock), 20
--   fire|frost, 24 nature|frost, 28 fire|frost|nature (Elemental Blast
--   can report wide composites), 72 nature|arcane = Astral (Ascendance-
--   linked damage). Shadow-bearing masks are deliberately excluded —
--   an unattributed shadow hit is provably foreign for this class.
mod.schools = { [1] = true, [4] = true, [8] = true, [12] = true,
	[16] = true, [20] = true, [24] = true, [28] = true, [72] = true }

-- Union of schools shaman pets can produce: elemental/nature spell
-- hits (4, 8, 12) and melee (1). A pet-routed hit outside this set is
-- provably foreign regardless of which pet is out.
local PET_SCHOOLS = { [1] = true, [4] = true, [8] = true, [12] = true }

function mod.petSchoolAllowed(school, helpers)
	if not (helpers and helpers.safeNumber and helpers.safeNumber(school)) then
		return nil
	end
	return PET_SCHOOLS[school] == true
end

-- Creature-family gates: only claim pet damage while the matching pet
-- type is actually out — otherwise player fire/nature strays would get
-- swallowed by the pet scroll.
local function petFamily(helpers)
	return helpers and helpers.family and helpers.family() or nil
end
local function isFireElem(fam)
	return fam ~= nil and fam:find("fire", 1, true) and fam:find("elemental", 1, true)
end
local function isStormElem(fam)
	return fam ~= nil and (fam:find("storm", 1, true) or fam:find("lightning", 1, true))
		and fam:find("elemental", 1, true)
end
local function isEarthElem(fam)
	return fam ~= nil and fam:find("earth", 1, true) and fam:find("elemental", 1, true)
end
local function isSpiritWolf(fam)
	return fam ~= nil and fam:find("spirit", 1, true)
end

-- Pet signature: fire hits while a Fire Elemental is out; nature hits
-- while a Storm/Earth Elemental or Spirit Wolf is out. Elemental spec
-- players produce the same schools constantly, so the family gate is
-- the only thing keeping player strays out of the pet scroll.
function mod.petSchoolHit(school, helpers)
	if not (helpers and helpers.safeNumber and helpers.safeNumber(school)) then
		return false
	end
	local fam = petFamily(helpers)
	if school == 4 or school == 12 then
		if isFireElem(fam) then return true end
	end
	if school == 8 or school == 12 then
		if isStormElem(fam) or isEarthElem(fam) or isSpiritWolf(fam) then return true end
	end
	return false
end

-- Player damage spells by school — when one of these was the most
-- recent cast, a same-school hit belongs to the player, not the pet.
-- (Fire: Lava Burst/Flame Shock/LMT/Primordial Wave. Nature: nearly the
-- whole Ele kit, which is why the veto matters.)
local SHAMAN_FIRE_SPELLS = {
	["Lava Burst"] = true,
	["Flame Shock"] = true,
	["Liquid Magma Totem"] = true,
	["Primordial Wave"] = true,
	["Fire Nova"] = true,
	["Lava Lash"] = true,
}
local SHAMAN_NATURE_SPELLS = {
	["Lightning Bolt"] = true,
	["Chain Lightning"] = true,
	["Earth Shock"] = true,
	["Elemental Blast"] = true,
	["Earthquake"] = true,
	["Tempest"] = true,
	["Voltaic Blaze"] = true,
	["Thunderstorm"] = true,
	["Crash Lightning"] = true,
	["Lightning Lasso"] = true,
	["Icefury"] = true,
	["Stormstrike"] = true,
	["Windstrike"] = true,
}

-- Recent-cast variant: claim the hit as pet ONLY when the recent cast
-- wasn't a player spell of the same school. Elemental summons start
-- hitting ~1-2s after their cast lands — between the player's own
-- casts — which is exactly the context this claim fires in.
function mod.petSchoolHitRecent(self, school, lastPlayerSpellId, helpers)
	if not (helpers and helpers.safeNumber and helpers.safeNumber(school)) then
		return false
	end
	local fam = petFamily(helpers)
	local sn = (type(lastPlayerSpellId) == "number")
		and helpers.cleanName and helpers.cleanName(lastPlayerSpellId) or nil
	if school == 4 or school == 12 then
		if not isFireElem(fam) then return false end
		if sn and SHAMAN_FIRE_SPELLS[sn] then return false end
		return true
	end
	if school == 8 or school == 12 then
		if not (isStormElem(fam) or isEarthElem(fam) or isSpiritWolf(fam)) then return false end
		if sn and SHAMAN_NATURE_SPELLS[sn] then return false end
		return true
	end
	return false
end

-- Physical pet melee (elemental autos, wolf bites). Consulted only by
-- the pet-fallback emit and gated to non-group content by the caller —
-- in groups foreign swings are indistinguishable from pet melee.
function mod.petPhysicalHit(school, helpers)
	return helpers and helpers.safeNumber and helpers.safeNumber(school)
		and school == 1
end

-- Name physical pet hits "Auto Attack" (6603) when the user opts in.
-- profile.classModule.namePetMelee (Class page toggle), default off.
function mod.resolvePetMelee(self, helpers)
	local cm = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.classModule
	if cm and cm.namePetMelee == true then return 6603 end
	return nil
end

-- Class-module UI toggles this module supports (Class page + quick bar).
mod.toggles = {
	namePetMelee = true,      -- MY_PET-proven melee named "Auto Attack"
}

-- Channel seeding (Earthquake ground-tick window).
function mod.onCast(self, spellId, spellName, t)
	local ch = ZSBT.ClassDB.ChannelMatch(spellId)
	if ch then
		self._channel = {
			untilAt = t + (ch.duration or 6.0),
			lastTickAt = 0,
			spellId = spellId,
			tickMin = ch.tickMin or 0.6,
			school = ch.school,
		}
	end
end

ZSBT.ClassDB.Register("SHAMAN", mod)
return mod
