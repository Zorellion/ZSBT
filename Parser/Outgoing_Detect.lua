local ADDON_NAME, ZSBT = ...

ZSBT.Parser = ZSBT.Parser or {}
ZSBT.Parser.Outgoing = ZSBT.Parser.Outgoing or {}
local Outgoing = ZSBT.Parser.Outgoing

------------------------------------------------------------------------
-- Outgoing parser now consumes normalized pulse-engine events.
-- ProcessEvent() is intentionally kept as the compatibility boundary for
-- Core.OutgoingProbe and existing call sites.
------------------------------------------------------------------------
function Outgoing:ProcessEvent(info)
	if not info or type(info) ~= "table" then return end
	if not self._enabled then return end

	local db = ZSBT.db and ZSBT.db.profile
	if not db or not db.outgoing then return end

	local kind = info.kind
	if kind ~= "damage" and kind ~= "heal" and kind ~= "miss" then return end

	if kind == "damage" then
		if not (db.outgoing.damage and db.outgoing.damage.enabled) then return end
		if info.isAuto then
			local mode = db.outgoing.damage.autoAttackMode or "Show All"
			if mode == "Hide" then return end
			if mode == "Show Only Crits" and not info.isCrit then return end
		end
		if not db.outgoing.damage.showTargets then
			info.targetName = nil
		end
	elseif kind == "heal" then
		if not (db.outgoing.healing and db.outgoing.healing.enabled) then return end
	end
	-- "miss" always passes through (dodge/parry/block are important feedback)

	-- Ensure event contract expected by OutgoingProbe.
	local ev = {
		kind = kind,
		amount = info.amount,
		amountText = info.amountText,
		rawPipeId = info.rawPipeId,
		spellName = info.spellName,
		spellId = info.spellId,
		amountSource = info.amountSource,
		targetName = info.targetName,
		isAuto = info.isAuto == true,
		isCrit = info.isCrit,
		timestamp = info.timestamp,
		confidence = info.confidence or "UNKNOWN",
		isPeriodic = info.isPeriodic == true,
	}

	local probe = ZSBT.Core and ZSBT.Core.OutgoingProbe
	if probe and probe.OnOutgoingDetected then
		probe:OnOutgoingDetected(ev)
	end
end

function Outgoing:Enable()
	self._enabled = true
end

function Outgoing:Disable()
	self._enabled = false
end
