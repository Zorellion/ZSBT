local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {
	{ names = { "Moonfire" }, ids = { 8921, 164812 } },
	{ names = { "Rake" }, ids = { 1822 }, school = 1 },
	-- aoe: Primal Wrath debuffs every enemy in range, so the spell-level
	-- apply anchor is a valid phase reference for any nameplate.
	{ names = { "Rip" }, ids = { 1079 }, school = 1, aoe = true },
	-- Thrash cast debuffs everything nearby — same AoE apply model.
	{ names = { "Thrash" }, ids = { 77758, 106832 }, school = 1, aoe = true },
	{ names = { "Dreadful Wound" }, ids = { 441809 }, school = 1 },
	{ names = { "Feral Frenzy" }, ids = { 274837 }, school = 1 },
	{ names = { "Frantic Frenzy" }, ids = { 1243807 }, school = 1 },
	{ names = { "Mastery: Razor Claws" }, ids = { 77493 }, school = 1 },
	{ names = { "Sunfire" }, ids = { 93402 }, school = 8 },
	{ names = { "Infected Wounds" }, ids = { 1261052 } },
}

-- Casts that debuff every enemy in range but are not dots themselves:
-- they seed the applied dot's application anchors so ticks can name.
mod.dotApplicators = {
	[285381] = { 1079 }, -- Primal Wrath -> Rip
}

-- Feral runs multiple same-school bleeds at once (Rip+Rake+Thrash all
-- school 1); the cadence scorer must disambiguate or stay generic.
mod.dotCadenceDisambig = true

-- Heal-over-time spells. The collector seeds a record on cast and claims
-- friendly-unit HEALs only when the unit verifiably carries the player's
-- aura, so intervals here are cadence hints, not correctness anchors.
mod.hots = {
	{ names = { "Rejuvenation" }, ids = { 774 }, interval = 3, duration = 15 },
	{ names = { "Regrowth" }, ids = { 8936 }, interval = 2, duration = 12 },
	{ names = { "Wild Growth" }, ids = { 48438 }, interval = 1, duration = 7 },
	{ names = { "Lifebloom" }, ids = { 33763 }, interval = 1, duration = 10 },
	{ names = { "Cenarion Ward" }, ids = { 102351 }, interval = 2, duration = 8 },
	{ names = { "Tranquility" }, ids = { 740 }, interval = 1, duration = 8 },
}

ZSBT.ClassDB.Register("DRUID", mod)
return mod
