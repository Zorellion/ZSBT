local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {
	{ names = { "Moonfire" }, ids = { 8921, 164812 } },
	{ names = { "Rake" }, ids = { 1822 }, school = 1 },
	-- Rip's own cast is single-target; multi-mob anchors come only from
	-- applicator casts (Primal Wrath), not an aoe flag here.
	{ names = { "Rip" }, ids = { 1079 }, school = 1 },
	-- aoe: the cast itself debuffs everything in range, so the cast time
	-- is a valid multi-mob application anchor (Thrash, Sunfire, Starfall,
	-- Lunar Beam). Single-target-cast dots must NOT carry this flag.
	{ names = { "Thrash" }, ids = { 77758, 106832 }, school = 1, aoe = true },
	{ names = { "Dreadful Wound" }, ids = { 441809 }, school = 1 },
	{ names = { "Feral Frenzy" }, ids = { 274837 }, school = 1 },
	{ names = { "Frantic Frenzy" }, ids = { 1243807 }, school = 1 },
	{ names = { "Mastery: Razor Claws" }, ids = { 77493 }, school = 1 },
	{ names = { "Sunfire" }, ids = { 93402 }, school = 8, aoe = true },
	{ names = { "Starfall" }, ids = { 191037 }, school = 72, aoe = true },
	{ names = { "Stellar Flare" }, ids = { 202347 }, school = 72 },
	{ names = { "Adaptive Swarm" }, ids = { 391889 }, school = 8 },
	{ names = { "Lunar Beam" }, ids = { 204066 }, school = 64, aoe = true },
	{ names = { "Infected Wounds" }, ids = { 1261052 } },
}

-- AoE casts: one cast wounds every mob in range, so a single cast
-- instance may legitimately name many hits (shared sid@castAt budget —
-- the target's own claim counts too). The combat log's one-line-per-hit
-- direct lines do the real self-limiting; the budget is the backstop.
mod.castBudget = {
	[106785] = 8,   -- Swipe (Cat)
	[213764] = 8,   -- Swipe (Bear talent id)
	[213771] = 8,   -- Swipe (Bear cast id — book pairs 213764 -> 213771)
	[77758]  = 8,   -- Thrash (Cat: AoE direct + bleed)
	[106832] = 8,   -- Thrash (Bear)
	[285381] = 8,   -- Primal Wrath (AoE finisher + Rip)
	[202028] = 8,   -- Brutal Slash (feral AoE talent)
	[93402]  = 8,   -- Sunfire (AoE application, balance)
	[400254] = 8,   -- Raze (guardian AoE Maul replacement)
	[22568]  = 4,   -- Ferocious Bite (Rampant Ferocity splash hits nearby)
	[6807]   = 2,   -- Maul (strikes up to 2 targets)
	[8921]   = 2,   -- Moonfire (Twin Moonfire hits a second mob)
}

-- Casts whose applied-effect id differs from the cast id, or that apply
-- dots without being dots themselves. Entries: { sid = N, aoe = bool }.
-- aoe = true means the cast puts the dot on EVERY enemy in range
-- (earns the multi-mob anchor); no flag means the cast target only
-- (per-target records, no multi-mob anchor).
mod.dotApplicators = {
	[285381] = { { sid = 1079, aoe = true } },    -- Primal Wrath -> Rip
	[191034] = { { sid = 191037, aoe = true } },  -- Starfall cast -> tick
	[325888] = { { sid = 391889 } },              -- Adaptive Swarm -> swarm
	[441583] = { { sid = 441809 } },              -- Ravage -> Dreadful Wound
	[441591] = { { sid = 441809 } },              -- Ravage (cast id)
}

-- Feral runs multiple same-school bleeds at once (Rip+Rake+Thrash all
-- school 1); the cadence scorer must disambiguate or stay generic.
mod.dotCadenceDisambig = true

-- Heal-over-time spells. The collector seeds a record on cast and claims
-- friendly-unit HEALs only when the unit verifiably carries the player's
-- aura, so intervals here are cadence hints, not correctness anchors.
mod.hots = {
	{ names = { "Rejuvenation" }, ids = { 774, 155777 }, interval = 3, duration = 15 },
	{ names = { "Regrowth" }, ids = { 8936 }, interval = 2, duration = 12 },
	{ names = { "Wild Growth" }, ids = { 48438 }, interval = 1, duration = 7 },
	{ names = { "Lifebloom" }, ids = { 33763 }, interval = 1, duration = 10 },
	{ names = { "Cenarion Ward" }, ids = { 102351 }, interval = 2, duration = 8 },
	{ names = { "Tranquility" }, ids = { 740 }, interval = 1, duration = 8 },
	{ names = { "Efflorescence" }, ids = { 1232285, 145205, 81269 }, interval = 2, duration = 30 },
	{ names = { "Adaptive Swarm" }, ids = { 391891 }, interval = 2, duration = 12 },
}

ZSBT.ClassDB.Register("DRUID", mod)
return mod
