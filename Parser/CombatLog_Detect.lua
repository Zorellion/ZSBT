------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - Parser Coordinator (WoW 12.0)
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.Parser = ZSBT.Parser or {}
ZSBT.Parser.CombatLog = ZSBT.Parser.CombatLog or {}
local CombatLog = ZSBT.Parser.CombatLog

CombatLog._enabled = CombatLog._enabled or false

local function wireCollectorToEngine()
	local collector = ZSBT.Parser and ZSBT.Parser.EventCollector
	local engine = ZSBT.Parser and ZSBT.Parser.PulseEngine
	if collector and engine and collector.setSink then
		collector:setSink(function(eventType, payload)
			engine:collect(eventType, payload)
		end)
	end
end

function CombatLog:Enable()
	if self._enabled then return end
	self._enabled = true

	wireCollectorToEngine()

	local engine = ZSBT.Parser and ZSBT.Parser.PulseEngine
	if engine and engine.Enable then
		engine:Enable()
	end

	local collector = ZSBT.Parser and ZSBT.Parser.EventCollector
	if collector and collector.Enable then
		collector:Enable()
	end
end

function CombatLog:Disable()
	if not self._enabled then return end
	self._enabled = false

	local collector = ZSBT.Parser and ZSBT.Parser.EventCollector
	if collector and collector.Disable then
		collector:Disable()
	end

	local engine = ZSBT.Parser and ZSBT.Parser.PulseEngine
	if engine and engine.Disable then
		engine:Disable()
	end
end
