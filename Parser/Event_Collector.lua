------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - Event Collector (retired stub)
--
-- The legacy UNIT_COMBAT / COMBAT_TEXT_UPDATE / UNIT_HEALTH collector is
-- retired: the embedded ZCT combat core (ZCT/Core/*) owns combat
-- attribution and feeds Parser.Outgoing/Incoming via
-- ZCT/Core/Bridge.lua.
--
-- This module survives only as the shared secret-amount pipe registry
-- plus the few timestamp/name fields that Core.lua, Outgoing_Probe and
-- Pulse_Engine still read. Nothing registers events here anymore.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.Parser = ZSBT.Parser or {}
ZSBT.Parser.EventCollector = ZSBT.Parser.EventCollector or {}
local Collector = ZSBT.Parser.EventCollector

Collector._enabled = Collector._enabled or false
Collector._rawPipe = Collector._rawPipe or {}
Collector._rawPipeCount = Collector._rawPipeCount or 0
Collector._lastOutgoingCombatAt = Collector._lastOutgoingCombatAt or nil
Collector._lastOutgoingCombatTargetName = Collector._lastOutgoingCombatTargetName or nil
Collector._lastPlayerSpellId = Collector._lastPlayerSpellId or nil
Collector._lastPlayerSpellAt = Collector._lastPlayerSpellAt or nil
Collector._lastPlayerSpellName = Collector._lastPlayerSpellName or nil
Collector._lastEnemySpellId = Collector._lastEnemySpellId or nil
Collector._lastEnemySpellAt = Collector._lastEnemySpellAt or nil
Collector._lastOutgoingChatSpellId = Collector._lastOutgoingChatSpellId or nil

return Collector
