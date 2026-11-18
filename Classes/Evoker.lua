local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {

}

ZSBT.ClassDB.Register("EVOKER", mod)
return mod
