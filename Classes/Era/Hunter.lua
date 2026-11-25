-- Classes/Era/Hunter.lua — Hunter attribution for the Forever client
-- (Camelot, project 18). Loaded ONLY on Forever via the ClassDB gate —
-- mod.client = "era" makes this file inert on Retail.
--
-- Name-primary by design: Forever spellIds are RANKED (a different id per
-- rank), so no table below carries ids where a name match suffices — the
-- engine resolves each combat-log id to its localized name and matches
-- `names`. Facts below are derived from Camelot's own logs and FCT's
-- client-derived SpellCatalog — NOT classic-era databases; Camelot
-- re-schools and adds Forever-only spells freely (Sniper Shot, Strider
-- Kick, Summon Hawk, Forever Lacerate ranks).
--
-- Verified against Forever combat logs (2026-11):
--   SPELL_DAMAGE "Raptor Strike" 0x1 (sid 2973 — empowered swing reports
--     under the strike's own sid; same empty-report frame as HS)
--   SPELL_CAST_SUCCESS "Auto Shot" 0x1 (sid 75 — a real cast here)
--   SWING_DAMAGE — melee autos real
local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}
mod.client = "era"

mod.dotCadenceDisambig = true

-- The spellbook IS the baseline: the knowledge pane lists only module
-- rows whose spell exists in the current book, so it shows the level-
-- appropriate kit and grows as new spells/ranks are learned.
mod.bookScopedKnowledge = true

mod.dots = {
	-- Serpent Sting: nature on Camelot per FCT's catalog (3s ticks,
	-- 15s) — classic school holds here. travels = its first tick lags
	-- the shot flight.
	{ names = { "Serpent Sting" },                    school = 8, interval = 3 },
	-- Black Arrow (survival, high level): shadow, 2s ticks, 30s.
	{ names = { "Black Arrow" },                      school = 32, interval = 2 },
	-- Lacerate (incl. Forever rank 1299332): physical bleed, 3s, 21s.
	{ names = { "Lacerate" },                         school = 1, interval = 3 },
	-- Immolation Trap dot: fire ticks after trigger (classic 3s/15s;
	-- Camelot cadence unverified — flag provisional).
	{ names = { "Immolation Trap Effect", "Immolation Trap" },
	                                                    school = 4, interval = 3 },
	-- Volley: 1s arcane ticks while channeled (travels, area) —
	-- declared as a dot so its ticks bind the channel record.
	{ names = { "Volley" },                           school = 64, interval = 1 },
}

-- Raptor Strike is the hunter's next-swing strike (FCT replacesSwing;
-- tape-verified pattern at sid 2973 — the queue emits an empty report
-- at the press instant, the real hit lands on the melee swing).
mod.nextSwing = {
	[2973] = true, [14260] = true, [14261] = true, [14262] = true,
	[14263] = true, [14264] = true, [14265] = true, [14266] = true,
}

mod.ranged = { "Auto Shot", "Shoot", "Shoot Bow", "Shoot Gun", "Shoot Crossbow", "Throw" }
mod.rangedIds = { 75, 5019, 2764, 2480, 7918, 7919 }

-- Denied outright: casts that never deal enemy damage on Camelot —
-- aspects/tracks/marks/pet utility are mechanical excludes; the sb-
-- listed Camelot customs (Read Leyline, Walk on Air) are non-damage
-- utility. Traps that deal damage on trigger (Immolation, Explosive,
-- Frost) are NOT here — only Freezing (CC) and Snake? no: Snake Trap
-- spawns adds (summon, not player damage) — excluded.
mod.exclude = {
	"Track Beasts", "Track Humanoids", "Track Hidden", "Track Undead",
	"Track Dragonkin", "Track Giants", "Track Elementals", "Track Demons",
	"Aspect of the Monkey", "Aspect of the Hawk", "Aspect of the Cheetah",
	"Aspect of the Pack", "Aspect of the Wild", "Aspect of the Beast",
	"Hunter's Mark", "Mend Pet", "Call Pet", "Dismiss Pet", "Feed Pet",
	"Revive Pet", "Tame Beast", "Beast Training", "Eyes of the Beast",
	"Beast Lore", "Scare Beast", "Eagle Eye", "Flare", "Feign Death",
	"Freezing Trap", "Frost Trap", "Snake Trap", "Scorpid Sting",
	"Viper Sting", "Distracting Shot", "Tranquilizing Shot",
	-- Camelot custom non-damage (sb-listed casts)
	"Read Leyline", "Walk on Air", "Elemental Insight", "Wind Blessed",
}

-- Multi-target casts: Multi-Shot caps at 3 (FCT spellFacts).
mod.castBudget = {
	[2643] = 3, -- Multi-Shot
}

-- Hunters fight across phys + arcane (Arcane Shot) + nature (Serpent)
-- + fire (Immolation) + shadow (Black Arrow) + weapon procs — no
-- useful foreign-school line exists for this class.
mod.schoolsAny = true

-- Pet melee is real damage — existing engine routes name it.
mod.toggles = {
	namePetMelee = true,
}

ZSBT.ClassDB.Register("HUNTER", mod)
return mod
