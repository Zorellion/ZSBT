-- Classes/DemonHunter.lua — Demon Hunter-specific combat attribution
--
-- No pets, no guardians: the module is dots + channels + cast budgets.
-- Signature school is chaos (127) — Eye Beam, Chaos Strike, Annihilation,
-- The Hunt all land on it. Fire covers Immolation Aura/Sigil of Flame/
-- Fiery Brand; physical covers Blade Dance, Fel Rush, Throw Glaive.

local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

-- Opt into the cadence-disambiguation pool: Vengeance runs up to five
-- fire dots at once, and channels (Fel Devastation) share their school.
-- Most-recent-dot matching stole channel ticks; the scored race gives
-- each wound to whichever periodic source's beat it actually lands on.
mod.dotCadenceDisambig = true

-- Periodic damage (name-primary; ids are fallback fast path).
mod.dots = {
	-- aoe=true: one application covers every mob in range (ground sigil /
	-- self-aura pulse), so the spell-level apply anchor is valid for
	-- off-target nameplate wounds — single-target dots still need a
	-- per-mob application record.
	{ names = { "Sigil of Flame" },  ids = { 204596, 204598 },  school = 4, aoe = true },
	{ names = { "Fiery Brand" },     ids = { 204021 },          school = 4 },
	-- Immolation Aura's aura ticks arrive periodic under the buff name.
	{ names = { "Immolation Aura" }, ids = { 258920, 427343 },  school = 4, aoe = true },
	-- The Hunt leaves a mark that ticks before the detonation.
	{ names = { "The Hunt" },        ids = { 258860, 323996 },  school = 127 },
	-- NOT a dot: sid 227255 "Frailty" appears in combat logs only as
	-- SPELL_HEAL (a ~1s self-heal — the debuff's leech component); it
	-- never deals damage. An entry here seeded a permanent school-4
	-- anchor (Frailty's debuff is always up on the target) that claimed
	-- every fire wound as "Frailty" — 24 steals/session across Fiery
	-- Brand, Immolation Aura, Sigil, Fel Devastation, Meteor Shower.

	-- Devourer (void spec) ------------------------------------------------
	-- NOT a dot: "Set Fire to the Pain" is a SELF-stagger defensive —
	-- 5% of damage taken becomes a fire DoT on the PLAYER (debuff sid
	-- 453286, self-only), never an enemy dot. Same false-premise class
	-- as Frailty: the name sounds offensive, the mechanic is defensive.
}

-- Facts for sids the spellbook can't see (all "Not In Spellbook" flags —
-- triggered damage lands under sids the book never lists, so their
-- schools go blind in combat without a pin). Wowhead-verified:
-- Catastrophe's debuff is Shadowflame on Vengeance / Cosmic on Havoc &
-- Devourer; Meteor Shower carries the same per-spec split.
mod.spellFacts = {
	[1256667] = { damages = true, school = 36 },  -- Catastrophe debuff (Vengeance, Shadowflame)
	[1256676] = { damages = true, school = 106 }, -- Catastrophe debuff (Havoc/Devourer, Cosmic)
	[1264128] = { damages = true, school = 36 },  -- Meteor Shower (Fire/Shadow)
	[1264129] = { damages = true, school = 106 }, -- Meteor Shower (Cosmic)
	[1264130] = { damages = true, school = 36 },  -- Meteor Shower (Fire/Shadow)
}

-- Channeled/ground volleys: individual hits carry no cast record, so the
-- cast seeds a window and same-school hits inside it claim the name.
mod.channels = {
	{ names = { "Eye Beam" },       ids = { 198013 }, duration = 3.0, tickMin = 0.12, interval = 0.12, school = 127 },
	{ names = { "Fel Devastation" }, ids = { 212084 }, duration = 2.0, tickMin = 0.12, interval = 0.2, school = 4 },
	{ names = { "Fel Barrage" },    ids = { 258925 }, duration = 3.0, tickMin = 0.12, interval = 0.25 },
	{ names = { "Glaive Tempest" }, ids = { 370965 }, duration = 3.0, tickMin = 0.25, interval = 0.33 },

	-- Devourer (void spec) ------------------------------------------------
	-- Void Ray: the void channel — book-derived channel with a very
	-- fast stream (iv=0.1). School 127 covers the void composite 106
	-- bitwise (106 & 127 = 106).
	{ names = { "Void Ray" },       ids = { 473728 }, duration = 3.0, tickMin = 0.08, interval = 0.1, school = 127 },
}

-- Zero-enemy-damage casts: a wound can never honestly wear these names —
-- not via dot pools, channels, pending-cast stamps, or the make-it-work
-- recency claim. NEVER list a dot/channel name.
mod.exclude = {
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
	-- Hidden debuff applicator: the engine fires SPELLCAST_SUCCEEDED for
	-- sid 227255 ~1s (Frailty application) but it never produces a logged
	-- cast or damage row (SPELL_HEAL only). Its constant record stream
	-- was being claimed by every school-4 wound — "Frailty" on Fiery
	-- Brand/Sigil/Fel Dev/Immolation hits, ~20 steals/session.
	"Frailty",
	-- Devourer (void spec) ------------------------------------------------
	"Shift",             -- void mobility; emitted school=nil
	"Void Metamorphosis",-- transform only; log-verified zero wounds
}

-- Per-cast-instance naming budget: AoE/splash casts may name several
-- hits; unlisted casts stay at the default of 1.
mod.castBudget = {
	[185123] = 4,   -- Throw Glaive (Havoc cast; ricochet, 2-3 targets)
	[204157] = 4,   -- Throw Glaive (Vengeance cast; verified SB)
	[189110] = 8,   -- Infernal Strike (landing AoE, fire)
	[198793] = 8,   -- Vengeful Retreat (vault AoE, physical; verified SB)
	[390163] = 8,   -- Sigil of Spite (AoE sigil, chaos; verified SB)
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

	-- Devourer (void spec) — provisional budgets from the first
	-- session's emit counts; tighten against AUDCLAIM tallies.
	[1226019] = 6,  -- Reap (signature spender; observed bursts)
	[1245412] = 4,  -- Voidblade
	[1234195] = 8,  -- Void Nova (AoE)
	[473662]  = 4,  -- Consume
	[1226033] = 4,  -- Eradicate (execute)
	[1225826] = 4,  -- Eradicate (damage variant sid)
	[1221167] = 8,  -- Collapsing Star (AoE)
	[473728]  = 12, -- Void Ray (fallback; the channel usually catches it)
	[1245483] = 4,  -- Pierce the Veil
	[1250088] = 4,  -- Midnight
	[1245414] = 4,  -- Voidblade (variant sid)
	[1245453] = 4,  -- Cull
}

-- Provable damage schools: 1 physical (melee, Blade Dance, glaives),
-- 4 fire (Immolation/Sigil/Fiery Brand/Fel Devastation/Felblade/
-- Infernal Strike/Spirit Bomb), 8 nature (procs/trinkets), 32 shadow
-- (procs, The Hunt variants), 36 shadowflame, 124/127 chaos — the book
-- reports chaos spells under both masks (Chaos Nova, Sigil of Spite).
mod.schools = { [1] = true, [4] = true, [8] = true, [32] = true,
	[36] = true, [64] = true, [106] = true, [124] = true, [127] = true }

ZSBT.ClassDB.Register("DEMONHUNTER", mod)
return mod
