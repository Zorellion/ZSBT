local ADDON_NAME, ZSBT = ...

ZSBT.Parser = ZSBT.Parser or {}
ZSBT.Parser.StateManager = ZSBT.Parser.StateManager or {}
local StateManager = ZSBT.Parser.StateManager

StateManager.activeCasts = StateManager.activeCasts or {}
StateManager.nextToken = StateManager.nextToken or 0

local function now()
	return (GetTime and GetTime()) or 0
end

--[[
State machine:
PENDING  -> MATCHED  when at least one hit is correlated.
PENDING  -> EXPIRED  when timeout elapses with no accepted hits.
MATCHED  -> EXPIRED  when timeout elapses after last accepted hit.

We keep expired records only long enough for diagnostics; the pulse engine
cleans them aggressively to keep per-pulse cost low.
]]
function StateManager:createCastState(spellId, spellName, sourceUnit, startedAt, timeoutSec)
	self.nextToken = self.nextToken + 1

	local state = {
		token = self.nextToken,
		spellId = spellId,
		spellName = spellName,
		sourceUnit = sourceUnit or "player",
		startedAt = startedAt or now(),
		lastHitAt = nil,
		expiresAt = (startedAt or now()) + (timeoutSec or 0.50),
		status = "PENDING",
		hits = {},
		totalAmount = 0,
		isChannel = false,
	}

	table.insert(self.activeCasts, state)
	return state
end

function StateManager:getActiveCasts()
	return self.activeCasts
end

function StateManager:markMatched(state, hit)
	if not state then return end
	state.status = "MATCHED"
	state.lastHitAt = hit and hit.timestamp or now()
	if hit then
		table.insert(state.hits, hit)
		if hit and ZSBT.IsSafeNumber(hit.amount) then
			state.totalAmount = state.totalAmount + hit.amount
		end
	end
end

function StateManager:expireStaleStates(atTime)
	atTime = atTime or now()
	local casts = self.activeCasts
	for i = #casts, 1, -1 do
		local state = casts[i]
		if state and state.expiresAt and state.expiresAt <= atTime then
			state.status = "EXPIRED"
			table.remove(casts, i)
		end
	end
end

function StateManager:clear()
	self.activeCasts = {}
	self.nextToken = 0
end
