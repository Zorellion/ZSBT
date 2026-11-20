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

-- Era dots tick at DIFFERENT intervals (Bane 2s vs the 3s pack), which is
-- what makes cadence disambiguation work at all. interval is the seconds
-- between ticks; entries sharing school AND interval can't be split by
-- cadence — wounds matching both stay generic rather than misname.
mod.dotCadenceDisambig = true

-- The spellbook IS the baseline: the knowledge pane lists only module
-- rows whose spell exists in the current book, so it shows the level-
-- appropriate kit and grows as new spells/ranks are learned.
mod.bookScopedKnowledge = true

mod.dots = {
	{ names = { "Corruption" },          school = 32, interval = 3 },
	-- Forever uses the Cataclysm curse names: Bane of Agony (980),
	-- Bane of Doom — keep the classic aliases for name-primary match.
	-- Forever uses the Cataclysm curse names (verified from the live
	-- spellbook dump): lead with them so the knowledge pane shows the
	-- names this client actually uses; classic names stay as match aliases.
	{ names = { "Bane of Agony", "Curse of Agony" }, school = 32, interval = 2 },
	{ names = { "Bane of Doom", "Curse of Doom" },   school = 32, interval = 60 },
	{ names = { "Siphon Life" },         school = 32, interval = 3 },
	{ names = { "Immolate" },            school = 4,  interval = 3 },
	-- Later-era additions: harmless if Forever lacks them (name match
	-- only fires on a real cast), correct if a custom build has them.
	{ names = { "Unstable Affliction" }, school = 32, interval = 3 },
	{ names = { "Seed of Corruption" },  school = 32 },
	{ names = { "Haunt" },               school = 32, interval = 3 },
}

mod.channels = {
	-- interval is the era tick period: the disambiguation picker phase-
	-- locks channel ticks to it, so DoT ticks landing mid-channel keep
	-- their own names instead of being eaten by the channel.
	{ names = { "Drain Life" },   duration = 6.0,  tickMin = 0.5, school = 32, interval = 1 },
	{ names = { "Drain Soul" },   duration = 16.0, tickMin = 0.5, school = 32, interval = 1 },
	{ names = { "Drain Mana" },   duration = 6.0,  tickMin = 0.5, school = 32, interval = 1 },
	-- Era Rain of Fire is channeled: 4 waves over ~8s. tickMin is kept
	-- proportional so foreign fire ticks can't ride a wide window.
	{ names = { "Rain of Fire" }, duration = 9.0,  tickMin = 1.2, school = 4,  interval = 2 },
	{ names = { "Hellfire" },     duration = 16.0, tickMin = 0.5, school = 4,  interval = 1 },
}

-- Denied outright: spells that parse as periodic or sit in the
-- pending-cast window but never deal enemy damage, so a wound can
-- never honestly wear their name. Health Funnel drains the CASTER's
-- health to heal the pet — its tooltip parses as periodic, so the
-- spellbook-derived dot fallback seeded it and let it name enemy
-- wounds (observed: a second-mob tick displaying "Health Funnel",
-- another claiming "Fear" via the pending-cast stamp). Absence from
-- the tables is not enough; exclusion survives every derivation path.
-- NEVER list a dot/channel name here — exclusion wins over those.
-- Wand Shoot arrives as a sid-bearing spell wound (5019 pending cast,
-- not isAuto) but produces RANGE_DAMAGE lines. Declaring it ranged
-- lets pairing reach for the ranged line first instead of letting
-- nearby DoT ticks steal it (or the bolt stealing a tick line).
mod.ranged = { "Shoot" }
mod.rangedIds = { 5019 }

mod.exclude = {
	"Health Funnel",
	"Life Tap",
	"Fear",
	"Howl of Terror",
	"Banish",
	"Curse of Weakness",
	"Curse of Tongues",
	"Curse of Shadow",
	"Curse of Elements",
	"Curse of Exhaustion",
	"Amplify Curse",
	"Shadow Ward",
	"Demon Armor",
	"Unending Breath",
	"Detect Invisibility",
	"Eye of Kilrogg",
	"Enslave Demon",
	"Fel Domination",
	"Ritual of Summoning",
	"Summon Imp",
	"Summon Voidwalker",
	"Summon Succubus",
	"Summon Felhunter",
	"Summon Felguard",
}

-- Era wand "Shoot" damage can carry almost any school (shadow/fire/
-- frost/nature/arcane/holy wands all exist) and a wand is not a spell —
-- the spellbook-derived mask union can't see it, so leaving mod.schools
-- nil would still let the derived fallback veto real wand hits as
-- FOREIGN_SCHOOL. schoolsAny declares: this class can produce any
-- school; foreign suppression falls to the group gate (source
-- ownership) instead of a school whitelist.
mod.schoolsAny = true

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

-- Era minions are REAL pets with real UNIT_SPELLCAST_SUCCEEDED casts —
-- imp Firebolt (Forever sid 7799) and Fire Shield (2947) claim their own
-- hits through _petCasts records, verified from a live Forever log. The
-- retail module's imp-fire signature route exists because Retail's wild
-- imps are recordless guardians; on era, routing unclaimed school-4
-- wounds to the pet scroll is a misroute: era Immolate is a real fire
-- DoT and its ticks are indistinguishable-from-recordless-bolt wounds.
-- Correctness-first: no school-4 wound enters the pet scroll without a
-- cast record; the ambiguous remainder stays generic outgoing instead
-- of wearing a pet frame it can't prove.
function mod.petSchoolHit(school, helpers)
	return false
end

function mod.petSchoolHitRecent(self, school, lastPlayerSpellId, helpers)
	return false
end

-- A pending pet cast record already outranks dot picks in the
-- disambiguation picker (proven > inferred), so the old blanket school-4
-- veto is gone: Immolate ticks name whenever no bolt is actually in
-- flight, and contested wounds fall to the pet path or generic.

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
			startedAt = t,
			lastTickAt = 0,
			spellId = spellId,
			tickMin = ch.tickMin or 0.12,
			school = ch.school,
			interval = ch.interval,
		}
	end
end

mod.toggles = {
	namePetMelee = true,
}

ZSBT.ClassDB.Register("WARLOCK", mod)
return mod
