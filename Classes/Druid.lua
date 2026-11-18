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

ZSBT.ClassDB.Register("DRUID", mod)
return mod
