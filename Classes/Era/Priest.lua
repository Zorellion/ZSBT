-- Classes/Era/Priest.lua — Priest attribution for the Forever client
-- (Camelot, project 18). Loaded ONLY on Forever via the ClassDB gate —
-- mod.client = "era" makes this file inert on Retail.
--
-- Name-primary like the other Era modules: Camelot spellIds are ranked,
-- so `names` carry the match load. Facts are anchored to the live
-- spellbook dump (level-3 book: Smite 585 school 2, Shoot 5019,
-- Attack 6603, PW:Fortitude 1243, Lesser Heal 2050 — link Attack -> Shoot).
-- Dot/channel intervals below are era-canonical and Camelot-UNVERIFIED:
-- a wrong interval fails to phase-lock and the tick stays generic —
-- honest, never misnamed.
--
-- Priest has no next-swing mechanic; melee auto-attacks get their
-- provenance from PLAYER_SWING (AUDSWING) like every other class.
local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}
mod.client = "era"

mod.dotCadenceDisambig = true

-- The spellbook IS the baseline: the knowledge pane lists only module
-- rows whose spell exists in the current book, so it shows the level-
-- appropriate kit and grows as new spells/ranks are learned.
mod.bookScopedKnowledge = true

-- Camelot re-schools freely (warrior's Thunder Clap is physical there)
-- and wand shots carry the equipped wand's element, which no book mask
-- can describe — same reasoning as warlock/warrior.
mod.schoolsAny = true

-- Wand Shoot is the priest's ranged auto. The wounds carry the wand's
-- element and produce ranged lines, so PreferRangedLine +
-- _wandSchool learning need the sid declared — the Shoot spell school
-- reads 0x1 regardless of element, facts can't prove it. 5019 is the
-- unranked action id from the live book.
mod.ranged = { "Shoot" }
mod.rangedIds = { 5019 }

mod.dots = {
	-- SW:Pain lands at level 4 — the first real damage dot in the book.
	-- school/interval are era-canonical (shadow 0x20, 3s ticks).
	{ names = { "Shadow Word: Pain" },   school = 32, interval = 3 },
	-- Camelot tracks Cataclysm-era naming elsewhere (warlock Banes);
	-- Vampiric Touch is the Cata replacement cast — alias rows are
	-- harmless on a client that lacks the name.
	{ names = { "Vampiric Touch" },      school = 32, interval = 3 },
	-- Undead racial: era DP heals the caster for damage dealt, so the
	-- co-timed heal line is the client's own proof (splits it from
	-- SW:Pain, which shares school+interval).
	{ names = { "Devouring Plague" },    school = 32, interval = 3, drains = true },
	-- Holy Fire's trailing DoT shares the cast's name — claiming it is
	-- always correct. Era dot portion; interval flagged unverified.
	{ names = { "Holy Fire" },           school = 4,  interval = 2 },
}

mod.channels = {
	-- Era Mind Flay (lvl 20, shadow): 3s channel, ~1s ticks.
	{ names = { "Mind Flay" },   duration = 3.0, tickMin = 0.5, school = 32, interval = 1 },
	-- Night-elf racial channel (arcane 0x40). Harmless where the name
	-- doesn't exist.
	{ names = { "Starshards" },  duration = 6.0, tickMin = 0.5, school = 64, interval = 1 },
}

-- Self-target HoTs: the collector seeds a record on cast and claims
-- friendly-unit HEALs only while the aura verifies, so interval is a
-- cadence hint. Era Renew: 15s, 3s ticks.
mod.hots = {
	{ names = { "Renew" }, interval = 3, duration = 15 },
}

-- Denied outright: buffs/heals/utility that never deal enemy damage —
-- without exclusion a pending buff cast's record can lend its name to
-- a coincident enemy wound (the PW:Fortitude-cast-then-swing shape;
-- same defect class as warlock's "Fear"/"Health Funnel" misnames).
-- Proc racials (Shadowguard, Touch of Weakness) deal their damage
-- reactively — the proc wound can't claim the buff cast's record, so
-- the cast name stays denied. NEVER list a dot/channel name here.
mod.exclude = {
	"Power Word: Fortitude",
	"Power Word: Shield",
	"Lesser Heal", "Heal", "Flash Heal", "Greater Heal",
	"Prayer of Healing",
	"Desperate Prayer",
	"Resurrection",
	"Inner Fire",
	"Fade",
	"Psychic Scream",
	"Shackle Undead",
	"Mind Soothe",
	"Mind Vision",
	"Mind Control",
	"Cure Disease",
	"Abolish Disease",
	"Dispel Magic",
	"Fear Ward",
	"Levitate",
	"Shadowguard",
	"Hex of Weakness",
	"Touch of Weakness",
	"Elune's Grace",
	"Feedback",
	"Rapid Regeneration",
}

ZSBT.ClassDB.Register("PRIEST", mod)
return mod
