local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod._stub = true  -- registered placeholder; no attribution data yet

mod.dots = {

}

ZSBT.ClassDB.Register("DEMONHUNTER", mod)
return mod
