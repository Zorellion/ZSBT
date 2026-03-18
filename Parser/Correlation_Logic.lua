local ADDON_NAME, ZSBT = ...

ZSBT.Parser = ZSBT.Parser or {}
ZSBT.Parser.CorrelationLogic = ZSBT.Parser.CorrelationLogic or {}
local Logic = ZSBT.Parser.CorrelationLogic

local CONFIDENCE = {
	HIGH = "HIGH",
	MEDIUM = "MEDIUM",
	LOW = "LOW",
	UNKNOWN = "UNKNOWN",
}
Logic.CONFIDENCE = CONFIDENCE

local function abs(v)
	if v < 0 then return -v end
	return v
end

--[[
Scoring matrix (0-100):
	+55 spellId exact match (best identifier across async streams)
	+20 target exact match (strong for single target and projectile travel)
	+15 short timing delta (<0.10s)
	+8  medium timing delta (<0.30s)
	+4  long timing delta (<1.20s)
	-30 explicit periodic event (DoT ticks should not steal active casts)
	-20 suspiciously old sample (>1.50s)

Thresholds:
	>=70 HIGH, >=45 MEDIUM, >=25 LOW, else UNKNOWN.
These values bias toward precision over recall to avoid incorrect attribution
when events are desynchronized in WoW 12.0.
]]
function Logic:scoreCandidate(castState, sample)
	if not castState or not sample then
		return 0, CONFIDENCE.UNKNOWN
	end

	local score = 0

	-- Timing delta: timestamps are safe numbers from GetTime().
	local delta = abs((sample.timestamp or 0) - (castState.startedAt or 0))

	-- Spell ID match (strongest signal) — IDs are safe integers.
	if ZSBT.IsSafeNumber(sample.spellId) and ZSBT.IsSafeNumber(castState.spellId)
	   and sample.spellId == castState.spellId then
		score = score + 55
	end

	-- Target match — compare only if both names are safe (untainted) strings.
	-- Tainted names are skipped entirely rather than using pcall band-aids.
	if ZSBT.IsSafeString(sample.targetName) and ZSBT.IsSafeString(castState.targetName)
	   and sample.targetName == castState.targetName then
		score = score + 20
	end

	-- Timing
	if delta <= 0.10 then
		score = score + 15
	elseif delta <= 0.30 then
		score = score + 8
	elseif delta <= 1.20 then
		score = score + 4
	else
		score = score - 20
	end

	-- Periodic penalty
	if sample.isPeriodic then
		score = score - 30
	end

	-- Secret Value handling: if sample has no amount, cap confidence at MEDIUM
	if sample.isSecret then
		if score >= 45 then return score, CONFIDENCE.MEDIUM end
		if score >= 25 then return score, CONFIDENCE.LOW end
		return score, CONFIDENCE.UNKNOWN
	end

	-- Normal confidence thresholds
	if score >= 70 then return score, CONFIDENCE.HIGH end
	if score >= 45 then return score, CONFIDENCE.MEDIUM end
	if score >= 25 then return score, CONFIDENCE.LOW end
	return score, CONFIDENCE.UNKNOWN
end

function Logic:findBestCast(activeCasts, sample)
	if not activeCasts or not sample then return nil, nil, 0 end

	local bestState, bestConfidence, bestScore = nil, nil, -999
	for i = 1, #activeCasts do
		local cast = activeCasts[i]
		if cast and cast.status ~= "EXPIRED" then
			local score, confidence = self:scoreCandidate(cast, sample)
			if score > bestScore then
				bestState = cast
				bestConfidence = confidence
				bestScore = score
			end
		end
	end

	if not bestState then
		return nil, CONFIDENCE.UNKNOWN, 0
	end
	return bestState, bestConfidence, bestScore
end
