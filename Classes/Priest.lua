local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {

		{ names = { "Shadow Word: Pain" }, ids = { 589 }, school = 32 },

	{ names = { "Vampiric Touch" }, ids = { 34914 }, school = 32 },
	{ names = { "Devouring Plague" }, ids = { 34946 }, school = 32 },
}

ZSBT.ClassDB.Register("PRIEST", mod)
return mod
