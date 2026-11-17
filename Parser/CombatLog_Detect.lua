------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - Parser Coordinator (WoW 12.0)
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.Parser = ZSBT.Parser or {}
ZSBT.Parser.CombatLog = ZSBT.Parser.CombatLog or {}
local CombatLog = ZSBT.Parser.CombatLog

CombatLog._enabled = CombatLog._enabled or false

-- The legacy Event_Collector -> PulseEngine combat-text path is retired:
-- ZSBT.ZCT (transplanted Zore's Combat Text core) owns combat attribution
-- and feeds Parser.Outgoing/Incoming.ProcessEvent via ZCT/Core/Bridge.lua.
-- The pulse engine stays enabled ONLY for the pet-merge and damage-meter
-- fallback sinks that the bridge still feeds (PET_* event types).
function CombatLog:Enable()
	if self._enabled then return end
	self._enabled = true

	local engine = ZSBT.Parser and ZSBT.Parser.PulseEngine
	if engine and engine.Enable then
		engine:Enable()
	end
end

function CombatLog:Disable()
	if not self._enabled then return end
	self._enabled = false

	local engine = ZSBT.Parser and ZSBT.Parser.PulseEngine
	if engine and engine.Disable then
		engine:Disable()
	end
end
