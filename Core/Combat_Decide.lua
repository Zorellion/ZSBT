------------------------------------------------------------------------
-- ZSBT - Combat Decision Layer (Skeleton)
-- Responsibility: accept normalized combat events and decide emission.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.Core = ZSBT.Core or {}
ZSBT.Core.Combat = ZSBT.Core.Combat or {}
local Combat = ZSBT.Core.Combat
local Addon  = ZSBT.Addon

function Combat:Enable()
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Combat:Enable()")
    end
end

function Combat:Disable()
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Combat:Disable()")
    end
end

-- Contract for Parser -> Core handoff (not used yet)
function Combat:OnCombatEvent(event)
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(3, "Combat:OnCombatEvent() (stub)")
    end
end
