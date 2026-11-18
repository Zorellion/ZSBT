local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {

		{ names = { "Garrote" }, ids = { 703 }, school = 1 },

	{ names = { "Rupture" }, ids = { 1943 }, school = 1 },
	{ names = { "Deadly Poison" }, ids = { 2818 }, school = 1 },
	{ names = { "Wound Poison" }, ids = { 8679 }, school = 1 },
	{ names = { "Crippling Poison" }, ids = { 3409 }, school = 1 },
}

ZSBT.ClassDB.Register("ROGUE", mod)
return mod
