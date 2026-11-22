local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {
	{ names = { "Moonfire" }, ids = { 8921, 164812 } },
	{ names = { "Rake" }, ids = { 1822 }, school = 1 },
	{ names = { "Rip" }, ids = { 1079 }, school = 1 },
	{ names = { "Thrash" }, ids = { 106832 }, school = 1 },
	{ names = { "Sunfire" }, ids = { 93402 }, school = 8 },
	{ names = { "Infected Wounds" }, ids = { 1261052 } },
}

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
