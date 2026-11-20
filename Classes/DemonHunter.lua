-- Classes/DemonHunter.lua — Demon Hunter-specific combat attribution
--
-- No pets, no guardians: the module is dots + channels + cast budgets.
-- Signature school is chaos (127) — Eye Beam, Chaos Strike, Annihilation,
-- The Hunt all land on it. Fire covers Immolation Aura/Sigil of Flame/
-- Fiery Brand; physical covers Blade Dance, Fel Rush, Throw Glaive.

local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

-- Periodic damage (name-primary; ids are fallback fast path).
mod.dots = {
	{ names = { "Sigil of Flame" },  ids = { 204596, 204598 },  school = 4 },
	{ names = { "Fiery Brand" },     ids = { 204021 },          school = 4 },
	-- Immolation Aura's aura ticks arrive periodic under the buff name.
	{ names = { "Immolation Aura" }, ids = { 258920, 427343 },  school = 4 },
	-- The Hunt leaves a mark that ticks before the detonation.
	{ names = { "The Hunt" },        ids = { 258860, 323996 },  school = 127 },
}

-- Channeled/ground volleys: individual hits carry no cast record, so the
-- cast seeds a window and same-school hits inside it claim the name.
mod.channels = {
	{ names = { "Eye Beam" },       ids = { 198013 }, duration = 3.0, tickMin = 0.12, school = 127 },
	{ names = { "Fel Devastation" }, ids = { 212084 }, duration = 2.0, tickMin = 0.12, school = 4 },
	{ names = { "Fel Barrage" },    ids = { 258925 }, duration = 3.0, tickMin = 0.12 },
	{ names = { "Glaive Tempest" }, ids = { 370965 }, duration = 3.0, tickMin = 0.25 },
}

-- Zero-enemy-damage casts: a wound can never honestly wear these names —
-- not via dot pools, channels, pending-cast stamps, or the make-it-work
-- recency claim. NEVER list a dot/channel name.
mod.exclude = {
	"Vengeful Retreat",
	"Disrupt",
	"Consume Magic",
	"Reverse Magic",
	"Spectral Sight",
	"Torment",
	"Imprison",
	"Darkness",
	"Blur",
	"Netherwalk",
	"Sigil of Misery",
	"Sigil of Silence",
	"Sigil of Chains",
	"Fodder to the Flame",
}

-- Per-cast-instance naming budget: AoE/splash casts may name several
-- hits; unlisted casts stay at the default of 1.
mod.castBudget = {
	[185123] = 4,   -- Throw Glaive (ricochet, 2-3 targets)
	[188499] = 8,   -- Blade Dance
	[210152] = 8,   -- Death Sweep (meta-upgraded Blade Dance)
	[179057] = 8,   -- Chaos Nova (AoE)
	[258920] = 8,   -- Immolation Aura (initial nova is AoE)
	[195072] = 4,   -- Fel Rush (pass-through damage)
	[191427] = 8,   -- Metamorphosis (Havoc leap landing AoE)
	[258860] = 8,   -- The Hunt (dash hits everything on the path)
	[306830] = 8,   -- Elysian Decree (AoE sigil)
	[247454] = 8,   -- Spirit Bomb (AoE)
	[228477] = 4,   -- Soul Cleave (frontal cleave)
	[198013] = 12,  -- Eye Beam (fallback; the channel usually catches it)
	[212084] = 8,   -- Fel Devastation (fallback; channel usually catches)
	[201467] = 4,   -- Fury of the Illidari
	[210153] = 8,   -- Death Sweep (alternate id)
	[201428] = 8,   -- Fury of the Illidari (alternate)
}

-- Provable damage schools: 1 physical (melee, Blade Dance, glaives),
-- 4 fire (Immolation/Sigil/Fiery Brand/Fel Devastation), 8 nature
-- (procs/trinkets), 32 shadow (procs, The Hunt variants), 36 shadowflame,
-- 127 chaos (Eye Beam, Chaos Strike, Annihilation, Fel Barrage).
mod.schools = { [1] = true, [4] = true, [8] = true, [32] = true,
	[36] = true, [127] = true }

ZSBT.ClassDB.Register("DEMONHUNTER", mod)
return mod
