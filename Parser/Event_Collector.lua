--==================================--
-- Module Setup
--==================================--

-- Initialize addon namespace references.
local ADDON_NAME, ZSBT = ...

-- Ensure parser and collector tables exist before attaching methods.
ZSBT.Parser = ZSBT.Parser or {}
ZSBT.Parser.EventCollector = ZSBT.Parser.EventCollector or {}
local Collector = ZSBT.Parser.EventCollector

-- Persist collector module state across reloads.
Collector._enabled = Collector._enabled or false
Collector._frame = Collector._frame or nil
Collector._sink = Collector._sink or nil
Collector._lastHealth = Collector._lastHealth or {}
Collector._lastUnitGuid = Collector._lastUnitGuid or {}
Collector._lastPlayerSpellName = Collector._lastPlayerSpellName or nil
Collector._lastPlayerSpellId = Collector._lastPlayerSpellId or nil
Collector._lastEnemySpellId = nil
Collector._lastEnemySpellAt = 0

-- Track player falling state to identify fall damage from UNIT_COMBAT.
local isFalling = false
local fallingTimer = nil

local BIG_HIT_THRESHOLD = 50000

-- Forward declaration: COMBAT_TEXT_UPDATE can fire very early during login.
-- handleCombatTextUpdate() references this helper before its assignment later
-- in the file, so we must declare the upvalue now.
local launderAmount

--==================================--
-- Utility Functions
--==================================--

-- Return a consistent timestamp source for emitted events.
local function now()
	return (GetTime and GetTime()) or 0
end

-- Detect restricted "Secret Value" data types using the official API.
local function isSecretValue(v)
	return ZSBT.IsSecret(v)
end

-- Safely resolve unit display names without hard errors.
local function safeUnitName(unit)
	if not unit then return nil end
	local ok, value = pcall(UnitName, unit)
	if not ok then return nil end
	-- In Midnight instances, UnitName may return a secret string.
	-- type() is safe on secrets, but comparison (==, ~=) is NOT.
	if type(value) ~= "string" then return nil end
	-- Use IsSafeString to check if we can compare it
	if ZSBT.IsSafeString and ZSBT.IsSafeString(value) then
		if value == "" then return nil end
		return value
	end
	-- Secret string — return it as-is (can still be passed to SetText)
	return value
end

-- Forward parsed events to the configured sink callback.
local function emit(eventType, payload)
	if ZSBT.Addon and ZSBT.Addon.DebugPrint then
	end
	if Collector._sink then
		Collector._sink(eventType, payload)
	end
end

-- AceConsole's Print() concatenates varargs; passing a Secret Value will
-- hard-error. Use this for ANY debug output that may include raw combat text.
local function dbgSafe(v)
	if v == nil then return "nil" end
	if ZSBT and ZSBT.IsSecret and ZSBT.IsSecret(v) then
		return "<secret>"
	end
	local ok, s = pcall(tostring, v)
	if not ok or type(s) ~= "string" then
		return "<secret>"
	end
	return s
end

local function ECPrint(msg)
	if ZSBT and ZSBT.Addon and ZSBT.Addon.Print then
		ZSBT.Addon:Print("|cFF00CC66[EC]|r " .. dbgSafe(msg))
	end
end

local function isStrictOutgoingCombatLogOnly()
	return ZSBT
		and ZSBT.Core
		and ZSBT.Core.IsStrictOutgoingCombatLogOnlyEnabled
		and ZSBT.Core:IsStrictOutgoingCombatLogOnlyEnabled() == true
end

local function isPvPStrictActive()
	return ZSBT
		and ZSBT.Core
		and ZSBT.Core.IsPvPStrictActive
		and ZSBT.Core:IsPvPStrictActive() == true
end

local function getPvPStrictFlag(key)
	local g = ZSBT and ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
	if type(g) ~= "table" then return nil end
	return g[key]
end

local function isQuietOutgoingWhenIdle()
	return ZSBT
		and ZSBT.Core
		and ZSBT.Core.IsQuietOutgoingWhenIdleEnabled
		and ZSBT.Core:IsQuietOutgoingWhenIdleEnabled() == true
end

local function isQuietOutgoingAutoAttacks()
	return ZSBT
		and ZSBT.Core
		and ZSBT.Core.IsQuietOutgoingAutoAttacksEnabled
		and ZSBT.Core:IsQuietOutgoingAutoAttacksEnabled() == true
end

local function isPlayerAutoAttackActive()
	local aaOn = false
	if IsCurrentSpell then
		local okAA, resAA = pcall(IsCurrentSpell, 6603)
		if okAA and resAA == true then
			return true
		end
		local attackName = nil
		if GetSpellInfo then
			local okN, name = pcall(GetSpellInfo, 6603)
			if okN and type(name) == "string" and name ~= "" then
				attackName = name
			end
		end
		if attackName then
			local okAA2, resAA2 = pcall(IsCurrentSpell, attackName)
			if okAA2 and resAA2 == true then
				return true
			end
			if IsAutoRepeatSpell then
				local okAR, resAR = pcall(IsAutoRepeatSpell, attackName)
				if okAR and resAR == true then
					return true
				end
			end
		end
		local okAA3, resAA3 = pcall(IsCurrentSpell, "Attack")
		if okAA3 and resAA3 == true then
			return true
		end
	end
	return aaOn
end

local function isPlayerMeleeEngaged()
	local canAttack = false
	if UnitCanAttack then
		local okA, resA = pcall(UnitCanAttack, "player", "target")
		if okA and resA == true then
			canAttack = true
		end
	end
	if not canAttack then
		return false
	end
	-- Prefer a range check for Attack (6603) when available.
	if IsSpellInRange then
		local okR, r = pcall(IsSpellInRange, 6603, "target")
		if okR and r == 1 then
			return true
		end
	end
	-- Fallback: interaction distance 3 is "duel/trade" range; close enough to approximate melee.
	if CheckInteractDistance then
		local okD, d = pcall(CheckInteractDistance, "target", 3)
		if okD and d == true then
			return true
		end
	end
	return false
end

local function flushBestOutgoing(self, token)
	if not self or not token then return end
	local bucket = self._bestOutgoingByToken and self._bestOutgoingByToken[token]
	if not bucket then return end
	self._bestOutgoingByToken[token] = nil
	local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0

	local pipeId = self._rawPipeCount + 1
	self._rawPipeCount = pipeId
	self._rawPipe[pipeId] = bucket.amount
	self._lastOutgoingCombatAt = bucket.timestamp
	self._lastOutgoingCombatTargetName = bucket.targetName
	if dl >= 4 then
		ECPrint(("FLUSH_BEST token=%s spellId=%s amt=%s school=%s crit=%s cnt=%s max=%s second=%s")
			:format(dbgSafe(token), dbgSafe(bucket.spellId), dbgSafe(bucket.amount), dbgSafe(bucket.schoolMask), dbgSafe(bucket.isCrit), dbgSafe(bucket._seenCount), dbgSafe(bucket._seenMax), dbgSafe(bucket._seenSecond)))
	end

	emit("OUTGOING_DAMAGE_COMBAT", {
		timestamp = bucket.timestamp,
		rawPipeId = pipeId,
		spellId = bucket.spellId,
		amountSource = "UNIT_COMBAT_BEST",
		targetName = bucket.targetName,
		isCrit = bucket.isCrit,
		schoolMask = bucket.schoolMask,
	})
end

-- Reset fall tracking and cancel any delayed landing timer.
local function resetFallingState()
	isFalling = false
	if fallingTimer then
		fallingTimer:Cancel()
		fallingTimer = nil
	end
end

local function isDamageLikeDisplayType(displayType)
	if type(displayType) ~= "string" then return false end
	local dt = displayType:lower()
	if dt:find("damage", 1, true) then return true end
	return false
end

-- Set the callback that receives normalized parser events.
function Collector:setSink(fn)
	self._sink = fn
end

--[[
WoW 12.0 Outgoing Damage Detection Strategy:

COMBAT_LOG_EVENT_UNFILTERED is protected in 12.0. We use whitelisted
events with a correlation engine instead:
1. UNIT_SPELLCAST_SUCCEEDED - captures when player finishes a cast
2. UNIT_HEALTH - detects health changes on target
3. UNIT_COMBAT - captures direct incoming damage to player
4. COMBAT_TEXT_UPDATE - captures self-heal amounts
5. Correlation engine matches cast -> health drop -> emits damage event

Limitations:
- In instances/M+/raids, UnitHealth() returns "Secret Values" (userdata)
- Cannot calculate damage deltas in restricted content
- Falls back to confidence=UNKNOWN/LOW in those cases
]]

--==================================--
-- Spell Tracking
--==================================--

Collector._pendingCasts = Collector._pendingCasts or {}
Collector._pendingCastNextToken = Collector._pendingCastNextToken or 0
local PENDING_CAST_WINDOW_SEC = 2.5
local PENDING_CAST_MAX = 12

-- Periodic (DoT) combat text attribution: COMBAT_TEXT_UPDATE periodic ticks can
-- arrive long after the original cast and after the pending cast entry has been
-- consumed. Track recently-cast spell IDs so periodic ticks can still be routed
-- to outgoing.
Collector._recentPeriodicSpellAt = Collector._recentPeriodicSpellAt or {}
local PERIODIC_OUTGOING_WINDOW_SEC = 30.0

local isPlayerClassTag
local isWhirlwindSpellId

if type(_G.isPlayerClassTag) ~= "function" then
	_G.isPlayerClassTag = function(tag)
		if type(tag) ~= "string" or tag == "" then return false end
		if type(UnitClass) ~= "function" then return false end
		local ok, _, classTag = pcall(UnitClass, "player")
		return ok and classTag == tag
	end
end

isPlayerClassTag = _G.isPlayerClassTag

if type(_G.isWhirlwindSpellId) ~= "function" then
	_G.isWhirlwindSpellId = function(spellId)
		return spellId == 1680 or spellId == 190411
	end
end

isWhirlwindSpellId = _G.isWhirlwindSpellId

local function getMostRecentPeriodicSpellId(self, tNow)
	local m = self and self._recentPeriodicSpellAt
	if type(m) ~= "table" then return nil end
	local bestId, bestAt
	for sid, at in pairs(m) do
		if type(sid) == "number" and type(at) == "number" then
			local age = tNow - at
			if age >= 0 and age <= PERIODIC_OUTGOING_WINDOW_SEC then
				if (not bestAt) or at > bestAt then
					bestAt = at
					bestId = sid
				end
			end
		end
	end
	return bestId
end

local function hasTargetDebuffSpellId(spellId)
	if type(spellId) ~= "number" then return false end
	if AuraUtil and AuraUtil.FindAuraBySpellId then
		local ok, aura = pcall(AuraUtil.FindAuraBySpellId, spellId, "target", "HARMFUL")
		if ok and aura then
			return true
		end
	end
	local function SafeAuraSpellId(auraData)
		if type(auraData) ~= "table" then return nil end
		local sid = auraData.spellId or auraData.spellID
		-- WoW 12.x can surface "secret" numeric values that are unsafe to compare
		-- using ordering operators (>, <). Only type-check here.
		return (type(sid) == "number") and sid or nil
	end
	if AuraUtil and AuraUtil.ForEachAura then
		local found = false
		pcall(function()
			AuraUtil.ForEachAura("target", "HARMFUL", 255, function(auraData)
				local sid = SafeAuraSpellId(auraData)
				local okEq, eq = pcall(function() return sid == spellId end)
				if okEq and eq then
					found = true
					return false
				end
				return true
			end, true)
		end)
		if found then return true end
	end
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		local seen = 0
		for i = 1, 255 do
			local ok, auraData = pcall(C_UnitAuras.GetAuraDataByIndex, "target", i, "HARMFUL")
			if not ok or not auraData then break end
			seen = seen + 1
			local sid = SafeAuraSpellId(auraData)
			local okEq, eq = pcall(function() return sid == spellId end)
			if okEq and eq then
				return true
			end
		end
	end
	if UnitAura then
		for i = 1, 40 do
			local ok, _, _, _, _, _, _, _, _, sid = pcall(UnitAura, "target", i, "HARMFUL")
			if not ok then break end
			if not sid then break end
			if sid == spellId then
				return true
			end
		end
	end
	if UnitDebuff then
		for i = 1, 40 do
			local ok, _, _, _, _, _, _, _, _, sid = pcall(UnitDebuff, "target", i)
			if not ok then break end
			if not sid then break end
			if sid == spellId then
				return true
			end
		end
	end
	return false
end

local function expirePendingCasts(self, tNow)
	local list = self._pendingCasts
	if not list then return end
	for i = #list, 1, -1 do
		local c = list[i]
		if not c or not c.at or (tNow - c.at) > (PENDING_CAST_WINDOW_SEC + 0.75) then
			table.remove(list, i)
		end
	end
end

local function enqueuePendingCast(self, spellId, spellName, tNow)
	self._pendingCastNextToken = (self._pendingCastNextToken or 0) + 1
	local helpful = nil
	if IsHelpfulSpell then
		local ok, res = pcall(IsHelpfulSpell, spellId)
		if ok then helpful = res end
	end
	local harmful = nil
	if IsHarmfulSpell then
		local ok, res = pcall(IsHarmfulSpell, spellId)
		if ok then harmful = res end
	end
	local targetHostile = nil
	if UnitCanAttack then
		local ok, res = pcall(UnitCanAttack, "player", "target")
		if ok then targetHostile = res end
	end
	-- Option A: never enqueue explicitly helpful casts (buffs/utility) so they
	-- cannot hijack outgoing spell icons.
	if helpful == true then
		return
	end
	-- Enqueue even when classification is unknown so outgoing doesn't go silent
	-- on clients where IsHelpfulSpell/IsHarmfulSpell are unreliable.
	-- Icon eligibility: prefer concrete signals. Hostile target at cast time is
	-- a strong indicator of a damage cast.
	local eligibleIcon = (helpful == false) or (harmful == true) or (targetHostile == true)
	table.insert(self._pendingCasts, {
		token = self._pendingCastNextToken,
		spellId = spellId,
		spellName = spellName,
		at = tNow,
		helpful = helpful,
		harmful = harmful,
		eligibleIcon = eligibleIcon,
		targetHostile = targetHostile,
	})
	if #self._pendingCasts > PENDING_CAST_MAX then
		table.remove(self._pendingCasts, 1)
	end
end

local function consumeBestPendingCast(self, tNow, wantSpellId, maxWindowSec, doConsume)
	expirePendingCasts(self, tNow)
	local window = maxWindowSec or PENDING_CAST_WINDOW_SEC
	local bestI, best, bestDt
	for i = 1, #(self._pendingCasts or {}) do
		local c = self._pendingCasts[i]
		if c and c.at and c.spellId then
			if (not wantSpellId) or c.spellId == wantSpellId then
				local dt = tNow - c.at
				if dt >= 0 and dt <= window then
					if not bestDt or dt < bestDt then
						bestDt = dt
						bestI = i
						best = c
					end
				end
			end
		end
	end
	if bestI then
		if doConsume == nil or doConsume == true then
			table.remove(self._pendingCasts, bestI)
		end
		return best
	end
	return nil
end

-- Capture successful casts for downstream correlation.
-- Player casts: used for outgoing spell icons.
-- Target/enemy casts: used for incoming spell icons.
function Collector:handleSpellcastSucceeded(unit, guid, spellId)
	if not spellId then return end

	-- Pet casts are used for custom triggers (e.g. Growl), but should not
	-- participate in the player cast correlation pipeline.
	if unit == "pet" then
		local trg = ZSBT.Core and ZSBT.Core.Triggers
		if trg and trg.OnSpellcastSucceeded then
			pcall(function() trg:OnSpellcastSucceeded(unit, guid, spellId) end)
		end
		return
	end

	if unit == "player" then
		self._castToken = (self._castToken or 0) + 1
		self._lastPlayerSpellId = spellId
		self._lastPlayerSpellName = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or nil
		self._lastPlayerSpellAt = now()
		if false and isPlayerClassTag("WARRIOR") and spellId == 772 then
			self._rendLastCastAt = self._lastPlayerSpellAt
			self._rendNextTickAt = self._lastPlayerSpellAt + 3.0
			self._rendTickState = nil
			self._rendInitialHitAmt = nil
			local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
			if dl >= 4 then
				ECPrint(("REND_CAST token=%s"):format(dbgSafe(self._castToken)))
			end
		end
		local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
		if dl >= 5 and isWhirlwindSpellId(spellId) then
			local tNow = now()
			local lastRecv = Collector._dbgWWChatRecvAt or 0
			local lastEmit = Collector._dbgWWChatEmitAt or 0
			local recvCount = Collector._dbgWWChatRecvCount or 0
			local emitCount = Collector._dbgWWChatEmitCount or 0
			local recvAge = tNow - lastRecv
			local emitAge = tNow - lastEmit
			ECPrint(("WW_CAST token=%s spellId=%s chatRecvCount=%s chatEmitCount=%s lastChatRecvAge=%.3f lastChatEmitAge=%.3f")
				:format(dbgSafe(self._castToken), dbgSafe(spellId), dbgSafe(recvCount), dbgSafe(emitCount), recvAge, emitAge))
			if recvCount == 0 or recvAge > 30 then
				ECPrint("WW_CAST DIAG: No addon-readable Whirlwind CHAT_MSG combat-log lines received recently; outgoing will rely on UNIT_COMBAT(target) fallback (icons may be missing).")
			end
		end
		local spellName = self._lastPlayerSpellName
		enqueuePendingCast(self, spellId, spellName, self._lastPlayerSpellAt)
		self._recentPeriodicSpellAt[spellId] = self._lastPlayerSpellAt

		-- Prime target health baseline to improve first-hit correlation.
		-- If we acquire a new target and immediately open with a cast, the
		-- first UNIT_HEALTH delta can be missed because oldHealth is nil.
		if self._lastHealth and UnitExists and UnitExists("target") then
			local health = UnitHealth and UnitHealth("target") or nil
			if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(health) then
				self._lastHealth["target"] = health
			end
		end

		emit("SPELLCAST_SUCCEEDED", {
			timestamp = now(),
			unit = unit,
			spellId = spellId,
			spellName = spellName,
			targetName = safeUnitName("target"),
		})
	else
		-- Enemy/target cast — track for incoming spell icons
		self._lastEnemySpellId = spellId
		self._lastEnemySpellAt = now()
	end
end

--==================================--
-- Outgoing Damage From Chat Combat Log
--==================================--

local function parseAmountFromChat(numText)
	if not numText or type(numText) ~= "string" then return nil end
	local cleaned = numText:gsub(",", "")
	local n = tonumber(cleaned)
	if not n then return nil end
	return n
end

isPlayerClassTag = function(tag)
	if type(tag) ~= "string" or tag == "" then return false end
	if type(UnitClass) ~= "function" then return false end
	local ok, _, classTag = pcall(UnitClass, "player")
	return ok and classTag == tag
end

local function isWhirlwindSpellId(spellId)
	return spellId == 1680 or spellId == 190411
end

local function wwSimilarHitsEnabled(spellId)
	local scChar = ZSBT and ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
	local sr = scChar and scChar.spellRules
	local rule = nil
	if sr and (spellId == 1680 or spellId == 190411) then
		rule = sr[spellId] or sr[(spellId == 1680) and 190411 or 1680]
	else
		rule = (sr and (sr[190411] or sr[1680])) or nil
	end
	local sh = rule and rule.similarHits
	return type(sh) == "table" and sh.enabled == true
end

local function wwAggEnabled(spellId)
	local scChar = ZSBT and ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
	local sr = scChar and scChar.spellRules
	local rule = nil
	if sr and (spellId == 1680 or spellId == 190411) then
		rule = sr[spellId] or sr[(spellId == 1680) and 190411 or 1680]
	else
		rule = (sr and (sr[190411] or sr[1680])) or nil
	end
	local agg = rule and rule.aggregate
	return type(agg) == "table" and agg.enabled == true
end

local function wwAggWindowSec(spellId)
	local scChar = ZSBT and ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
	local sr = scChar and scChar.spellRules
	local rule = nil
	if sr and (spellId == 1680 or spellId == 190411) then
		rule = sr[spellId] or sr[(spellId == 1680) and 190411 or 1680]
	else
		rule = (sr and (sr[190411] or sr[1680])) or nil
	end
	local agg = rule and rule.aggregate
	local w = type(agg) == "table" and tonumber(agg.windowSec) or nil
	if type(w) ~= "number" then return 0.35 end
	if w < 0.10 then return 0.10 end
	if w > 1.25 then return 1.25 end
	return w
end

local function wwAggFlush(self)
	if not self then return end
	local st = self._wwAgg
	if type(st) ~= "table" then return end
	self._wwAgg = nil
	self._wwAggChatToken = nil
	self._wwAggChatAt = nil
	if st.timer and st.timer.Cancel then
		pcall(function() st.timer:Cancel() end)
	end
	local sum = st.sum
	local cnt = st.count
	local critCount = st.critCount
	if type(sum) ~= "number" or sum <= 0 then return end
	if type(cnt) ~= "number" or cnt <= 0 then cnt = 1 end
	if type(critCount) ~= "number" or critCount < 0 then critCount = 0 end

	emit("OUTGOING_DAMAGE_COMBAT", {
		timestamp = st.t or now(),
		amount = sum,
		amountText = tostring(math.floor(sum + 0.5)),
		spellId = st.spellId or 190411,
		amountSource = "UNIT_COMBAT_PHYSICAL",
		targetName = st.targetName,
		isCrit = false,
		schoolMask = 1,
		wwCount = cnt,
		wwCritCount = (st.similarHitsEnabled == true) and critCount or nil,
	})
end

local function wwAggPush(self, t, spellId, amount, isCrit)
	if not (self and ZSBT.IsSafeNumber(amount) and amount > 0) then return end
	self._wwAgg = self._wwAgg or {}
	local st = self._wwAgg
	st.t = st.t or t
	st.sum = (st.sum or 0) + amount
	st.count = (st.count or 0) + 1
	st.similarHitsEnabled = st.similarHitsEnabled or wwSimilarHitsEnabled(spellId)
	if st.similarHitsEnabled == true then
		-- Crit inference: prefer explicit crit flag when available. If unavailable on some
		-- clients (UNIT_COMBAT may not flag crits), infer crit-like hits as ~2x the
		-- smallest observed hit in this bucket.
		local prevMin = (ZSBT.IsSafeNumber(st.minHit) and st.minHit > 0) and st.minHit or nil
		st.minHit = prevMin and math.min(prevMin, amount) or amount
		local critLike = (isCrit == true)
		if critLike ~= true and prevMin and prevMin > 0 then
			-- Use a conservative threshold to reduce false positives from off-hand variance.
			if amount >= (prevMin * 1.75) and amount >= (prevMin + 250) then
				critLike = true
			end
		end
		if critLike == true and isCrit ~= true then
			local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
			if dl >= 5 then
				ECPrint(("WW_CRIT_INFER token=%s spellId=%s amt=%s prevMin=%s")
					:format(dbgSafe(self._castToken), dbgSafe(spellId), dbgSafe(amount), dbgSafe(prevMin)))
			end
		end
		if critLike == true then
			st.critCount = (st.critCount or 0) + 1
		else
			st.critCount = st.critCount or 0
		end
	end
	st.targetName = st.targetName or safeUnitName("target")
	st.token = st.token or self._castToken
	st.spellId = st.spellId or spellId
	if st.timer and st.timer.Cancel then
		pcall(function() st.timer:Cancel() end)
	end
	local win = wwAggWindowSec(spellId)
	if C_Timer and C_Timer.NewTimer then
		st.timer = C_Timer.NewTimer(win, function()
			if Collector and Collector._wwAgg then
				wwAggFlush(Collector)
			end
		end)
	elseif C_Timer and C_Timer.After then
		st.timer = nil
		C_Timer.After(win, function()
			if Collector and Collector._wwAgg then
				wwAggFlush(Collector)
			end
		end)
	end
end

local function dbgChatPush(self, row)
	if not self then return nil end
	local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
	if dl < 5 then return nil end
	self._dbgChatSeq = (self._dbgChatSeq or 0) + 1
	local id = self._dbgChatSeq
	self._dbgChatRing = self._dbgChatRing or {}
	self._dbgChatRingHead = ((self._dbgChatRingHead or 0) % 60) + 1
	row = row or {}
	row.id = id
	self._dbgChatRing[self._dbgChatRingHead] = row
	return id
end

local function resolveRecentSpellIdByName(self, wantName, tNow)
	if not wantName or type(wantName) ~= "string" then return nil end
	if not self or type(self._recentPeriodicSpellAt) ~= "table" then return nil end
	local bestId, bestAt
	for sid, at in pairs(self._recentPeriodicSpellAt) do
		if type(sid) == "number" and type(at) == "number" then
			local age = tNow - at
			if age >= 0 and age <= PERIODIC_OUTGOING_WINDOW_SEC then
				local sn = ZSBT.CleanSpellName and ZSBT.CleanSpellName(sid) or nil
				if type(sn) == "string" and sn == wantName then
					if (not bestAt) or at > bestAt then
						bestAt = at
						bestId = sid
					end
				end
			end
		end
	end
	return bestId
end

function Collector:handleChatSelfDamage(event, msg)
	if not msg or type(msg) ~= "string" then return end
	local isSafeMsg = true
	if ZSBT.IsSafeString and not ZSBT.IsSafeString(msg) then
		isSafeMsg = false
	end
	local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
	local quietMode = isQuietOutgoingWhenIdle()

	-- In instances, some clients can mark chat combat messages as secret/unsafe.
	-- We still want outgoing numbers when "Your ..." messages are available, but we
	-- must avoid comparing/printing secret strings. For unsafe messages, use a
	-- minimal parser: extract the amount and attribute it to the most recent cast.
	if not isSafeMsg then
		if msg:find("Your ", 1, true) ~= 1 then
			return
		end
		local tNow = now()
		local token = self._castToken
		if not token or not self._lastPlayerSpellAt or not self._lastPlayerSpellId then
			return
		end
		local dt = tNow - (self._lastPlayerSpellAt or 0)
		local maxDt = 2.5
		if quietMode == true then
			maxDt = 1.25
		end
		if dt < 0 or dt > maxDt then
			return
		end
		local amountText = msg:match("(%d[%d,]*)")
		local amount = amountText and parseAmountFromChat(amountText) or nil
		if not amount or amount <= 0 then
			return
		end
		local sig = tostring(token) .. ":" .. tostring(self._lastPlayerSpellId) .. ":" .. tostring(amount)
		local lastSig = self._lastChatOutgoingSig
		local lastAt = self._lastChatOutgoingSigAt or 0
		if lastSig == sig and (tNow - lastAt) < 0.10 then
			if dl >= 5 then
				ECPrint(("CHAT_OUT dup unsafe token=%s spellId=%s amt=%s")
					:format(dbgSafe(token), dbgSafe(self._lastPlayerSpellId), dbgSafe(amount)))
			end
			return
		end
		self._lastChatOutgoingSig = sig
		self._lastChatOutgoingSigAt = tNow
		if dl >= 4 and amount >= BIG_HIT_THRESHOLD then
			ECPrint(("BIG_HIT CHAT_UNSAFE token=%s spellId=%s amt=%s")
				:format(dbgSafe(token), dbgSafe(self._lastPlayerSpellId), dbgSafe(amount)))
		end
		self._lastOutgoingFromTargetToken = token
		self._lastCombatTextOutgoingToken = token
		local isCrit = (msg:find("Critical", 1, true) ~= nil) or (msg:find("critical", 1, true) ~= nil)
		if isWhirlwindSpellId(self._lastPlayerSpellId) and wwAggEnabled(self._lastPlayerSpellId) then
			self._wwAggChatToken = token
			self._wwAggChatAt = tNow
			wwAggPush(self, tNow, self._lastPlayerSpellId, amount, isCrit)
			return
		end
		self._lastOutgoingChatAt = tNow
		self._lastOutgoingChatSpellId = self._lastPlayerSpellId
		self._lastOutgoingChatAmount = amount
		self._recentOutgoingMax = math.max(self._recentOutgoingMax or 0, amount)
		self._recentOutgoingMaxAt = tNow
		local dbgId = dbgChatPush(self, {
			t = tNow,
			evt = event,
			token = token,
			spellId = self._lastPlayerSpellId,
			spellName = nil,
			targetName = nil,
			amount = amount,
			msg = "<unsafe>",
		})
		if dl >= 5 then
			ECPrint(("CHAT_OUT emit#%s unsafe token=%s spellId=%s amt=%s")
				:format(dbgSafe(dbgId), dbgSafe(token), dbgSafe(self._lastPlayerSpellId), dbgSafe(amount)))
		end
		emit("OUTGOING_DAMAGE_COMBAT", {
			timestamp = tNow,
			amount = amount,
			amountText = tostring(amount),
			spellId = self._lastPlayerSpellId,
			targetName = nil,
			isCrit = isCrit,
			amountSource = "COMBAT_TEXT",
			dbgChatId = dbgId,
			schoolMask = nil,
		})
		return
	end

	local isPeriodicEvent = false
	if type(event) == "string" and event:find("PERIODIC", 1, true) then
		isPeriodicEvent = true
	end
	local looksPeriodicMsg = false
	if msg:find("suffers", 1, true) and msg:find("from your", 1, true) and msg:find("damage", 1, true) then
		looksPeriodicMsg = true
	elseif msg:find("causes", 1, true) and msg:find("to suffer", 1, true) and msg:find("damage", 1, true) then
		looksPeriodicMsg = true
	elseif msg:find(" damaged ", 1, true) and msg:find("Your ", 1, true) == 1 then
		-- Retail periodic wording: "Your Agony damaged Target 2,756 Shadow."
		looksPeriodicMsg = true
	end
	local periodicCandidate = isPeriodicEvent or looksPeriodicMsg

	if periodicCandidate then
		local spellName, targetName, amountText
		targetName, amountText, spellName = msg:match("^(.+) suffers (%d[%d,]*) .- damage from your (.+)%.?")
		if not spellName then
			spellName, targetName, amountText = msg:match("^Your (.+) causes (.+) to suffer (%d[%d,]*) .- damage%.?")
		end
		if not spellName then
			spellName, targetName, amountText = msg:match("^Your (.+) damaged (.+) (%d[%d,]*)")
		end
		if spellName and targetName and amountText then
			local tNow = now()
			local amount = parseAmountFromChat(amountText)
			if amount and amount > 0 then
				local spellId = resolveRecentSpellIdByName(self, spellName, tNow)
				emit("OUTGOING_DAMAGE_COMBAT", {
					timestamp = tNow,
					amount = amount,
					amountText = tostring(amount),
					spellId = spellId,
					targetName = targetName,
					isCrit = false,
					isPeriodic = true,
					amountSource = "COMBAT_TEXT",
					schoolMask = nil,
				})
				return
			end
		end
		if dl >= 4 and ZSBT.Addon and ZSBT.Addon.Print then
			ECPrint(("CHAT_OUT periodic no match evt=%s msg=%s")
				:format(dbgSafe(event), dbgSafe(msg:sub(1, 180))))
		end
		if isPeriodicEvent then
			return
		end
	end

	local spellName, targetName, amountText
	-- Common enUS patterns for outgoing spell hits in the combat log chat.
	spellName, targetName, amountText = msg:match("^Your (.+) hit (.+) (%d[%d,]*)")
	if not spellName then
		spellName, targetName, amountText = msg:match("^Your (.+) hits (.+) for (%d[%d,]*)")
	end
	if not spellName then
		spellName, targetName, amountText = msg:match("^Your (.+) crits (.+) for (%d[%d,]*)")
	end
	if not spellName then
		spellName, targetName, amountText = msg:match("^Your (.+) critically hits (.+) for (%d[%d,]*)")
	end
	if not spellName then
		if dl >= 4 and ZSBT.Addon and ZSBT.Addon.Print then
			ECPrint(("CHAT_OUT no match evt=%s msg=%s"):format(dbgSafe(event), dbgSafe(msg:sub(1, 160))))
		end
		-- Pet damage fallback:
		-- 1) enUS: "Your pet hits X for N"
		-- 2) Combat log tab: "<PetName> <Spell> hit <Target> <Amount> Physical. (Critical)"
		local didPet = false

		do
			local pTarget, pAmountText
			pTarget, pAmountText = msg:match("^Your pet hit (.+) (%d[%d,]*)")
			if not pTarget then
				pTarget, pAmountText = msg:match("^Your pet hits (.+) for (%d[%d,]*)")
			end
			if not pTarget then
				pTarget, pAmountText = msg:match("^Your pet crits (.+) for (%d[%d,]*)")
			end
			if not pTarget then
				pTarget, pAmountText = msg:match("^Your pet critically hits (.+) for (%d[%d,]*)")
			end
			if pTarget and pAmountText then
				local amt = parseAmountFromChat(pAmountText)
				if amt and amt > 0 then
					local isCrit2 = (msg:find("crits", 1, true) ~= nil) or (msg:find("critically", 1, true) ~= nil)
					local pipeId = self._rawPipeCount + 1
					self._rawPipeCount = pipeId
					self._rawPipe[pipeId] = amt
					emit("PET_DAMAGE_COMBAT", {
						timestamp = now(),
						rawPipeId = pipeId,
						isCrit = isCrit2,
						schoolMask = nil,
						targetName = pTarget,
					})
					didPet = true
				end
			end
		end

		if not didPet then
			local okPN, petName = pcall(UnitName, "pet")
			if okPN and ZSBT.IsSafeString(petName) and petName ~= "" then
				local petPrefix, petTarget2, petAmount2 = msg:match("^(.+) hit (.+) (%d[%d,]*)")
				if petPrefix and petTarget2 and petAmount2 then
					if petPrefix:sub(1, #petName + 1) == (petName .. " ") then
						local amt2 = parseAmountFromChat(petAmount2)
						if amt2 and amt2 > 0 then
							local isCrit3 = (msg:find("Critical", 1, true) ~= nil) or (msg:find("CRITICAL", 1, true) ~= nil)
							local pipeId = self._rawPipeCount + 1
							self._rawPipeCount = pipeId
							self._rawPipe[pipeId] = amt2
							self._lastPetChatAt = now()
							self._lastPetChatAmount = amt2
							emit("PET_DAMAGE_COMBAT", {
								timestamp = now(),
								rawPipeId = pipeId,
								isCrit = isCrit3,
								schoolMask = nil,
								targetName = petTarget2,
							})
							didPet = true
						end
					end
				end
			end
		end

		if didPet then
			return
		end
		return
	end
	if dl >= 4 and ZSBT.Addon and ZSBT.Addon.Print then
		ECPrint(("CHAT_OUT match evt=%s spell=%s target=%s amt=%s")
			:format(dbgSafe(event), dbgSafe(spellName), dbgSafe(targetName), dbgSafe(amountText)))
	end

	local tNow = now()
	local token = self._castToken
	if not token or not self._lastPlayerSpellAt or not self._lastPlayerSpellId then
		return
	end
	local dt = tNow - (self._lastPlayerSpellAt or 0)
	if dt < 0 or dt > 2.5 then
		return
	end

	-- Ensure spell name matches last cast (safe-string compare only).
	local lastName = self._lastPlayerSpellName
	local cleanLast = ZSBT.CleanSpellName and ZSBT.CleanSpellName(self._lastPlayerSpellId) or nil
	if ZSBT.IsSafeString and ZSBT.IsSafeString(spellName) then
		if (ZSBT.IsSafeString(lastName) and spellName == lastName) or (ZSBT.IsSafeString(cleanLast) and spellName == cleanLast) then
			-- ok
		else
			return
		end
	else
		return
	end

	-- Duplicate-line guard:
	-- Some clients/event routes can deliver the same combat log chat line more
	-- than once (e.g. different CHAT_MSG_* events). We want multi-hit spells
	-- (Whirlwind, cleaves, etc.) to emit each hit, but avoid printing an
	-- identical duplicate line in the same instant.
	local amount = parseAmountFromChat(amountText)
	if not amount or amount <= 0 then return end
	local sig = tostring(token) .. ":" .. tostring(self._lastPlayerSpellId) .. ":" .. tostring(targetName) .. ":" .. tostring(amount)
	local lastSig = self._lastChatOutgoingSig
	local lastAt = self._lastChatOutgoingSigAt or 0
	if lastSig == sig and (tNow - lastAt) < 0.10 then
		if dl >= 5 then
			ECPrint(("CHAT_OUT dup token=%s spellId=%s target=%s amt=%s")
				:format(dbgSafe(token), dbgSafe(self._lastPlayerSpellId), dbgSafe(targetName), dbgSafe(amount)))
		end
		return
	end
	self._lastChatOutgoingSig = sig
	self._lastChatOutgoingSigAt = tNow
	-- Suppress UNIT_COMBAT(target) fallback for this cast.
	self._lastOutgoingFromTargetToken = token
	self._lastCombatTextOutgoingToken = token

	if dl >= 4 and amount >= BIG_HIT_THRESHOLD then
		ECPrint(("BIG_HIT CHAT token=%s spellId=%s amt=%s")
			:format(dbgSafe(token), dbgSafe(self._lastPlayerSpellId), dbgSafe(amount)))
	end
	local isCrit = (msg:find("Critical", 1, true) ~= nil) or (msg:find("critical", 1, true) ~= nil)
	if isWhirlwindSpellId(self._lastPlayerSpellId) and wwAggEnabled(self._lastPlayerSpellId) then
		-- If Whirlwind aggregation is enabled, funnel addon-readable chat hits into the
		-- same aggregation bucket and suppress per-hit emits (prevents duplicates/crit routing).
		self._wwAggChatToken = token
		self._wwAggChatAt = tNow
		wwAggPush(self, tNow, self._lastPlayerSpellId, amount, isCrit)
		return
	end
	self._lastOutgoingChatAt = tNow
	self._lastOutgoingChatSpellId = self._lastPlayerSpellId
	self._lastOutgoingChatAmount = amount
	self._recentOutgoingMax = math.max(self._recentOutgoingMax or 0, amount)
	self._recentOutgoingMaxAt = tNow
	if isWhirlwindSpellId(self._lastPlayerSpellId) then
		Collector._dbgWWChatEmitAt = tNow
		Collector._dbgWWChatEmitCount = (Collector._dbgWWChatEmitCount or 0) + 1
	end

	local dbgId = dbgChatPush(self, {
		t = tNow,
		evt = event,
		token = token,
		spellId = self._lastPlayerSpellId,
		spellName = spellName,
		targetName = targetName,
		amount = amount,
		msg = (ZSBT.IsSafeString and ZSBT.IsSafeString(msg)) and msg:sub(1, 160) or "<secret>",
	})
	if dl >= 5 then
		ECPrint(("CHAT_OUT emit#%s token=%s spellId=%s spell=%s target=%s amt=%s")
			:format(dbgSafe(dbgId), dbgSafe(token), dbgSafe(self._lastPlayerSpellId), dbgSafe(spellName), dbgSafe(targetName), dbgSafe(amount)))
	end

	emit("OUTGOING_DAMAGE_COMBAT", {
		timestamp = tNow,
		amount = amount,
		amountText = tostring(amount),
		spellId = self._lastPlayerSpellId,
		targetName = targetName,
		isCrit = isCrit,
		amountSource = "COMBAT_TEXT",
		dbgChatId = dbgId,
		schoolMask = nil,
	})
end

local CHAT_OUTGOING_EVENTS = {
	-- Legacy/self-specific (some clients still fire these)
	CHAT_MSG_COMBAT_SELF_HITS = true,
	CHAT_MSG_COMBAT_SELF_DAMAGE = true,
	CHAT_MSG_COMBAT_SELF_MISSES = true,
	CHAT_MSG_SPELL_SELF_DAMAGE = true,
	CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE = true,
	-- Retail/general combat log chat (these vary by client/build)
	CHAT_MSG_SPELL_DAMAGE = true,
	CHAT_MSG_SPELL_PERIODIC_DAMAGE = true,
	CHAT_MSG_COMBAT_DAMAGE = true,
	-- Combat log chat frame ("Combat Log" tab may use this event)
	CHAT_MSG_COMBAT_LOG = true,
}

--==================================--
-- Self Heal Detection (COMBAT_TEXT_UPDATE)
--==================================--

-- COMBAT_TEXT_UPDATE event type classification.
-- These fire for the player character (incoming events).
-- Must include ALL _CRIT variants or crits show as "Hit".
local INCOMING_DAMAGE_TYPES = {
	DAMAGE = true,
	DAMAGE_CRIT = true,
	SPELL_DAMAGE = true,
	SPELL_DAMAGE_CRIT = true,
	DAMAGE_SHIELD = true,
	DAMAGE_SHIELD_CRIT = true,
	PERIODIC_DAMAGE = true,
	PERIODIC_DAMAGE_CRIT = true,
	SPELL_PERIODIC_DAMAGE = true,
	SPELL_PERIODIC_DAMAGE_CRIT = true,
}

-- Crit lookup for fast isCrit resolution
local SCHOOL_PHYSICAL = 1
local CRIT_TYPES = {
	DAMAGE_CRIT = true,
	SPELL_DAMAGE_CRIT = true,
	DAMAGE_SHIELD_CRIT = true,
	PERIODIC_DAMAGE_CRIT = true,
	SPELL_PERIODIC_DAMAGE_CRIT = true,
	HEAL_CRIT = true,
	PERIODIC_HEAL_CRIT = true,
}

local INCOMING_HEAL_TYPES = {
	HEAL = true,
	HEAL_CRIT = true,
	SPELL_HEAL = true,
	SPELL_HEAL_CRIT = true,
	PERIODIC_HEAL = true,
	PERIODIC_HEAL_CRIT = true,
	SPELL_PERIODIC_HEAL = true,
	SPELL_PERIODIC_HEAL_CRIT = true,
}

local PERIODIC_TYPES = {
	PERIODIC_HEAL = true,
	PERIODIC_HEAL_CRIT = true,
	SPELL_PERIODIC_HEAL = true,
	SPELL_PERIODIC_HEAL_CRIT = true,
	PERIODIC_DAMAGE = true,
	PERIODIC_DAMAGE_CRIT = true,
	SPELL_PERIODIC_DAMAGE = true,
	SPELL_PERIODIC_DAMAGE_CRIT = true,
}

local INCOMING_MISS_TYPES = {
	MISS = true,
	DODGE = true,
	PARRY = true,
	BLOCK = true,
	RESIST = true,
	ABSORB = true,
	SPELL_RESISTED = true,
	SPELL_ABSORBED = true,
}

-- "Raw Pipe" for secret values.
-- Values from C_CombatText.GetCurrentEventInfo() must go directly to
-- FontString:SetText() without ANY Lua operations. We store raw values
-- in an indexed array that the display layer reads directly.
Collector._rawPipe = {}
Collector._rawPipeCount = 0
Collector._rawPipeLastWipe = 0

-- Wipe stale pipe entries periodically to prevent memory leak.
-- Called at the start of each COMBAT_TEXT_UPDATE; any entry older than
-- ~2 seconds was never consumed and can be discarded.
local RAW_PIPE_WIPE_INTERVAL = 2.0
local function wipeStalePipeEntries()
	local t = GetTime()
	if (t - Collector._rawPipeLastWipe) < RAW_PIPE_WIPE_INTERVAL then return end
	Collector._rawPipeLastWipe = t
	-- Wipe the entire table and reset counter. Any unconsumed entries
	-- are stale (the display layer consumes within the same frame).
	wipe(Collector._rawPipe)
	Collector._rawPipeCount = 0
end

local function maybeResetRawPipeCounter()
	local rp = Collector._rawPipe
	if type(rp) ~= "table" then return end
	for _ in pairs(rp) do
		return
	end
	Collector._rawPipeCount = 0
end

-- Parse ALL combat text events for the player.
-- This is the primary data source for incoming numbers in Midnight,
-- because C_CombatText feeds Blizzard's own floating text system.
function Collector:handleCombatTextUpdate(arg1)
	if not arg1 then return end
	wipeStalePipeEntries()
	maybeResetRawPipeCounter()

	-- Get the raw event payload. DO NOT perform any operations on these values.
	-- They must go directly to FontString:SetText() for secret values to render.
	local rawArg1, rawArg2, rawArg3
	if C_CombatText and C_CombatText.GetCurrentEventInfo then
		rawArg1, rawArg2, rawArg3 = C_CombatText.GetCurrentEventInfo()
	elseif GetCurrentCombatTextEventInfo then
		rawArg1, rawArg2, rawArg3 = GetCurrentCombatTextEventInfo()
	end

	-- Many combat text damage events include a spellId in the 2nd return value.
	-- Use it as a strong hint for attribution when it is a safe number.
	local ctSpellId = nil
	if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(rawArg2) then
		ctSpellId = rawArg2
	end

	-- The amount is rawArg1 for most event types.
	-- We pass it RAW to the display layer via the raw pipe.
	local rawAmount = rawArg1

	-- High-signal trace: confirm COMBAT_TEXT_UPDATE is firing and what tokens
	-- the client is using for event type.
	local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
	if dl >= 4 and ZSBT.Addon and ZSBT.Addon.Print then
		local tNow = now()
		if (tNow - (Collector._dbgLastCombatTextAnyAt or 0)) > 0.20 then
			Collector._dbgLastCombatTextAnyAt = tNow
			ECPrint(("CT evt=%s raw1=%s raw2=%s raw3=%s")
				:format(dbgSafe(arg1), dbgSafe(rawArg1), dbgSafe(rawArg2), dbgSafe(rawArg3)))
		end
	end

	-- Combat Text Damage
	-- WoW 12.0: COMBAT_TEXT_UPDATE provides a reliable numeric feed, but it is
	-- NOT guaranteed to be the player's outgoing damage (pets/procs/etc can
	-- appear). Only route to OUTGOING when we can attribute it to a recent
	-- player cast; otherwise keep it as incoming combat text damage.
	local isDamage = INCOMING_DAMAGE_TYPES[arg1]
	if not isDamage and type(arg1) == "string" and arg1:find("DAMAGE", 1, true) then
		isDamage = true
	end
	local isHeal = INCOMING_HEAL_TYPES[arg1]
	if not isHeal and type(arg1) == "string" and arg1:find("HEAL", 1, true) then
		isHeal = true
	end

	if isDamage then
		local isCrit = CRIT_TYPES[arg1] or false
		local isPeriodic = PERIODIC_TYPES[arg1] or false
		local tNow = now()
		self._lastCombatTextDamageAt = tNow
		if ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) >= 3 then
			if ZSBT.Addon and ZSBT.Addon.Print and (tNow - (Collector._dbgLastCombatTextDamageAt or 0)) > 0.25 then
				Collector._dbgLastCombatTextDamageAt = tNow
				ECPrint(("CT_DAMAGE evt=%s raw=%s ctSpellId=%s lastPlayerSpellId=%s")
					:format(dbgSafe(arg1), dbgSafe(rawAmount), dbgSafe(ctSpellId), dbgSafe(self._lastPlayerSpellId)))
			end
		end

		local outgoingSpellId = nil
		local matchedCast = nil
		local quietMode = isQuietOutgoingWhenIdle()
		if ctSpellId then
			matchedCast = consumeBestPendingCast(self, tNow, ctSpellId)
			if matchedCast and matchedCast.helpful == true then
				matchedCast = nil
			end
			if matchedCast then
				outgoingSpellId = matchedCast.spellId
			elseif (not quietMode) and self._lastPlayerSpellId and ctSpellId == self._lastPlayerSpellId and self._lastPlayerSpellAt then
				-- Strong evidence path: combat text gave us a spellId that matches the
				-- player's last cast, but ONLY if the cast was very recent. Without a
				-- recency check, party/follower spells can be misattributed as yours.
				local age = tNow - (self._lastPlayerSpellAt or 0)
				if age >= 0 and age <= 1.25 then
					outgoingSpellId = ctSpellId
				end
			elseif isPeriodic and self._recentPeriodicSpellAt and self._recentPeriodicSpellAt[ctSpellId] then
				local age = tNow - (self._recentPeriodicSpellAt[ctSpellId] or 0)
				if age >= 0 and age <= PERIODIC_OUTGOING_WINDOW_SEC then
					outgoingSpellId = ctSpellId
				end
			end
		end
		if (not outgoingSpellId) and isPeriodic and (not ctSpellId) then
			outgoingSpellId = getMostRecentPeriodicSpellId(self, tNow)
		end

		local pipeId = self._rawPipeCount + 1
		self._rawPipeCount = pipeId
		self._rawPipe[pipeId] = rawAmount
		local numAmount, amountText, secret = nil, nil, false
		if type(launderAmount) == "function" then
			numAmount, amountText, secret = launderAmount(rawAmount)
		else
			if ZSBT.IsSafeNumber(rawAmount) then
				numAmount = rawAmount
				amountText = tostring(math.floor(rawAmount + 0.5))
			else
				local okS, s = pcall(tostring, rawAmount)
				if okS and type(s) == "string" then
					amountText = s
				else
					amountText = nil
					secret = true
				end
			end
		end

		if outgoingSpellId then
			-- In follower/party instances, COMBAT_TEXT_UPDATE can include damage not caused
			-- by the player. For non-periodic hits, require a very recent player cast or a
			-- pending-cast match before emitting outgoing.
			if not isPeriodic then
				-- Max correctness mode: non-periodic outgoing must be backed by a pending cast
				-- match. This avoids accepting other-player hits that share a spellId.
				if quietMode == true and not matchedCast then
					outgoingSpellId = nil
				end
				local instanceAware = (ZSBT.Core and ZSBT.Core.IsInstanceAwareOutgoingEnabled and ZSBT.Core:IsInstanceAwareOutgoingEnabled()) or false
				if instanceAware == true and IsInInstance then
					local okI, inInst = pcall(IsInInstance)
					if okI and inInst == true then
						local members = 0
						if type(GetNumGroupMembers) == "function" then
							local okM, m = pcall(GetNumGroupMembers)
							if okM and type(m) == "number" then members = m end
						end
						if members and members > 1 and not matchedCast then
							local lastAt = self._lastPlayerSpellAt
							if not (type(lastAt) == "number" and (tNow - lastAt) >= 0 and (tNow - lastAt) <= 0.90) then
								outgoingSpellId = nil
							end
						end
					end
				end
			end
		end
		if outgoingSpellId then
			-- Mark for health-delta dedup.
			self._lastOutgoingCombatAt = tNow
			self._lastOutgoingCombatTargetName = safeUnitName("target")

			emit("OUTGOING_DAMAGE_COMBAT", {
				timestamp = tNow,
				rawPipeId = pipeId,
				isCrit = isCrit,
				isPeriodic = isPeriodic,
				spellId = outgoingSpellId,
				amountSource = "COMBAT_TEXT",
				schoolMask = nil,
				targetName = self._lastOutgoingCombatTargetName,
			})
			return
		else
			-- Incoming dedup: in 12.0, the same incoming hit can appear via UNIT_COMBAT("player")
			-- and COMBAT_TEXT_UPDATE in rapid succession. If UNIT_COMBAT already emitted
			-- very recently, suppress this COMBAT_TEXT_DAMAGE to avoid duplicate numbers.
			if self._lastUnitCombatPlayerDamageAt and (tNow - self._lastUnitCombatPlayerDamageAt) <= 0.25 then
				return
			end
			-- Not attributable as outgoing: treat as incoming combat text damage.
			emit("COMBAT_TEXT_DAMAGE", {
				timestamp = tNow,
				rawPipeId = pipeId,
				amount = numAmount,
				amountText = amountText,
				isSecret = secret,
				spellId = ctSpellId,
				targetName = safeUnitName("player"),
				isCrit = isCrit,
				isPeriodic = isPeriodic,
			})
		end

		-- Snapshot health after damage for upcoming heal overheal calculation
		local h = UnitHealth and UnitHealth("player")
		if ZSBT.IsSafeNumber(h) then
			self._lastHealth = self._lastHealth or {}
			self._lastHealth["player"] = h
		end


		return
	end

	-- Incoming Heals
	if isHeal then
		local isCrit = CRIT_TYPES[arg1] or false
		local isPeriodic = PERIODIC_TYPES[arg1] or false
		self._lastCombatTextHealAt = now()

		local pipeId = self._rawPipeCount + 1
		self._rawPipeCount = pipeId
		self._rawPipe[pipeId] = rawAmount
		local numAmount, amountText, secret = nil, nil, false
		if type(launderAmount) == "function" then
			numAmount, amountText, secret = launderAmount(rawAmount)
		else
			if ZSBT.IsSafeNumber(rawAmount) then
				numAmount = rawAmount
				amountText = tostring(math.floor(rawAmount + 0.5))
			else
				local okS, s = pcall(tostring, rawAmount)
				if okS and type(s) == "string" then
					amountText = s
				else
					amountText = nil
					secret = true
				end
			end
		end

		-- For heals: use player.s own spell (self-heals)
		local healSpellId = nil
		if self._lastPlayerSpellAt and (now() - self._lastPlayerSpellAt) < 0.5 then
			healSpellId = self._lastPlayerSpellId
		end

		-- Calculate overheal using post-heal health state.
		-- After a heal, if player is at max health, overheal = healAmount - deficit.
		-- If not at max, no overheal occurred.
		local overheal = nil
		if ZSBT.IsSafeNumber(rawAmount) then
			local curHealth = UnitHealth and UnitHealth("player")
			local maxHealth = UnitHealthMax and UnitHealthMax("player")
			if ZSBT.IsSafeNumber(curHealth) and ZSBT.IsSafeNumber(maxHealth) and maxHealth > 0 then
				-- Post-heal: if at max, some healing was wasted
				if curHealth >= maxHealth then
					-- Pre-heal health was: current - effective_heal
					-- effective_heal = rawAmount - overheal
					-- But at max: effective_heal = maxHealth - preHealth
					-- And preHealth = curHealth - effective_heal = maxHealth - effective_heal
					-- So: rawAmount = effective + overheal
					--     effective = maxHealth - preHealth
					-- We know preHealth from snapshot OR estimate:
					local preHealth = self._lastHealth and self._lastHealth["player"]
					if ZSBT.IsSafeNumber(preHealth) and preHealth < maxHealth then
						local deficit = maxHealth - preHealth
						overheal = rawAmount - deficit
						if overheal < 0 then overheal = nil end
					else
						-- No pre-health snapshot: assume full overheal if at max
						-- This is conservative — may overcount slightly
						overheal = rawAmount
					end
				end
				-- Update health snapshot for next calculation
				self._lastHealth = self._lastHealth or {}
				self._lastHealth["player"] = curHealth
			end
		end

		emit("COMBAT_TEXT_HEAL", {
			timestamp = now(),
			rawPipeId = pipeId,
			amount = numAmount,
			amountText = amountText,
			isCrit = isCrit,
			isPeriodic = isPeriodic,
			spellId = healSpellId,
			overheal = overheal,
			targetName = safeUnitName("player"),
		})
		return
	end

	-- Misses / Avoidance (incoming)
	if INCOMING_MISS_TYPES[arg1] then
		emit("COMBAT_TEXT_MISS", {
			timestamp = now(),
			missType = arg1,
			targetName = safeUnitName("player"),
		})
		return
	end

	-- Environmental Damage (drowning, lava, fatigue, falling)
	if arg1 == "ENVIRONMENTAL" then
		local pipeId = self._rawPipeCount + 1
		self._rawPipeCount = pipeId
		self._rawPipe[pipeId] = rawAmount
		emit("COMBAT_TEXT_ENVIRONMENTAL", {
			timestamp = now(),
			rawPipeId = pipeId,
			targetName = safeUnitName("player"),
		})
		return
	end

	-- Honor gains
	if arg1 == "HONOR_GAINED" then
		local pipeId = self._rawPipeCount + 1
		self._rawPipeCount = pipeId
		self._rawPipe[pipeId] = rawAmount
		emit("COMBAT_TEXT_HONOR", {
			timestamp = now(),
			rawPipeId = pipeId,
		})
		return
	end

	-- XP gains
	if arg1 == "COMBAT_XP_GAIN" then
		local pipeId = self._rawPipeCount + 1
		self._rawPipeCount = pipeId
		self._rawPipe[pipeId] = rawAmount
		emit("COMBAT_TEXT_XP", {
			timestamp = now(),
			rawPipeId = pipeId,
		})
		return
	end

	-- Reputation gains
	if arg1 == "FACTION" then
		local pipeId = self._rawPipeCount + 1
		self._rawPipeCount = pipeId
		self._rawPipe[pipeId] = rawAmount
		emit("COMBAT_TEXT_REP", {
			timestamp = now(),
			rawPipeId = pipeId,
		})
		return
	end

	-- Spell/ability became active (procs like Overpower, Revenge, etc.)
	if arg1 == "SPELL_ACTIVE" then
		-- rawAmount here is the spell name string
		if rawAmount and ZSBT.IsSafeString(rawAmount) then
			emit("COMBAT_TEXT_PROC", {
				timestamp = now(),
				spellName = rawAmount,
			})
		end
		return
	end

	-- Reactive spell available
	if arg1 == "SPELL_CAST" then
		if rawAmount and ZSBT.IsSafeString(rawAmount) then
			emit("COMBAT_TEXT_PROC", {
				timestamp = now(),
				spellName = rawAmount,
			})
		end
		return
	end
end

--==================================--
-- Fall Damage Detection (UNIT_COMBAT + IsFalling)
--==================================--

launderAmount = function(raw)
	if raw == nil then return nil, nil, false end
	if ZSBT.IsSafeNumber(raw) then
		return raw, tostring(math.floor(raw + 0.5)), false
	end
	-- Secret Value or non-number: pass raw for SetText() display.
	return nil, raw, true
end

-- Deduplication: when COMBAT_TEXT_UPDATE provides clean data, suppress
-- the parallel UNIT_COMBAT event for the same hit to avoid "Hit" spam.
Collector._lastCombatTextDamageAt = 0
Collector._lastCombatTextHealAt = 0
Collector._dbgLastUnitCombatPlayerAt = 0
Collector._dbgLastCombatTextDamageAt = 0
Collector._lastPlayerHealthDamageAt = 0
local DEDUP_WINDOW = 0.10 -- 100ms window

-- Deduplication: outgoing can be detected via UNIT_COMBAT (target) and
-- also via UNIT_HEALTH deltas. When both fire, we prefer the UNIT_COMBAT
-- path (it carries crit + school) and suppress the near-simultaneous
-- health delta to avoid duplicate lines.
Collector._lastOutgoingCombatAt = Collector._lastOutgoingCombatAt or 0
Collector._lastOutgoingCombatTargetName = Collector._lastOutgoingCombatTargetName or nil
local OUTGOING_HEALTH_DEDUP_WINDOW = 0.12

-- Detect incoming player damage/healing from UNIT_COMBAT.
-- In 12.0, the `action` string arg may be tainted. Rather than checking
-- action == "WOUND", we emit all UNIT_COMBAT events for "player" that
-- have a non-nil amount and let downstream consumers categorize by context.
-- UNIT_COMBAT only fires for: WOUND, HEAL, BLOCK, DODGE, PARRY, RESIST, etc.
-- Only WOUND and HEAL carry meaningful amounts.
function Collector:handleUnitCombat(unit, action, descriptor, amount, school)
	if unit ~= "player" and unit ~= "target" and unit ~= "pet" then return end
	if amount == nil then return end
	-- UNIT_COMBAT may emit ABSORB/blocked-style entries with amount==0.
	-- These are not actual damage/heal events and must be ignored to prevent
	-- false incoming spam (especially in WoW 12.0 where attribution is limited).
	if ZSBT.IsSafeNumber(amount) and amount == 0 then
		return
	end
	wipeStalePipeEntries()

	-- Detect crit from the descriptor arg.
	local isCrit = false
	if type(descriptor) == "string" then
		local d = descriptor
		local u = d:upper()
		if u:find("CRIT", 1, true) then
			isCrit = true
		end
	end

	-- PET: pet incoming damage / healing (UNIT_COMBAT("pet") reports events happening to the pet)
	if unit == "pet" then
		local actionStr = ZSBT.IsSafeString(action) and action or nil
		if actionStr == "HEAL" then
			local numAmount = nil
			local amtText = nil
			if ZSBT.IsSafeNumber(amount) then
				numAmount = amount
				amtText = tostring(math.floor(amount + 0.5))
			else
				local okS, s = pcall(tostring, amount)
				if okS and type(s) == "string" then
					amtText = s
				end
			end
			emit("PET_HEAL_LOG", {
				timestamp = now(),
				amount = numAmount,
				amountText = amtText,
				spellId = nil,
				spellName = nil,
				isCrit = isCrit,
				isPeriodic = true,
				overheal = nil,
				targetName = safeUnitName("pet"),
			})
		elseif actionStr == "WOUND" or actionStr == nil then
			local pipeId = self._rawPipeCount + 1
			self._rawPipeCount = pipeId
			self._rawPipe[pipeId] = amount
			emit("PET_INCOMING_DAMAGE_COMBAT", {
				timestamp = now(),
				rawPipeId = pipeId,
				isCrit = isCrit,
				schoolMask = ZSBT.IsSafeNumber(school) and school or nil,
			})
		end
		return
	end

	-- OUTGOING (best-effort): UNIT_COMBAT("target") has no source attribution in 12.0,
	-- but in some clients it is the only usable signal for player spell hits when
	-- UNIT_HEALTH deltas are missing/suppressed. Only accept it when we can
	-- strictly attribute it to a very recent player cast.
	if unit == "target" then
		local restrict = (ZSBT.Core and ZSBT.Core.ShouldRestrictOutgoingFallback and ZSBT.Core:ShouldRestrictOutgoingFallback()) or false
		local instanceAware = (ZSBT.Core and ZSBT.Core.IsInstanceAwareOutgoingEnabled and ZSBT.Core:IsInstanceAwareOutgoingEnabled()) or false
		local quietMode = isQuietOutgoingWhenIdle()
		-- PvP Strict Mode: battlegrounds/arenas are high-risk for misattribution.
		-- Force restricted attribution behavior when active.
		if isPvPStrictActive() then
			restrict = true
			instanceAware = true
		end
		-- Strict outgoing mode: still allow UNIT_COMBAT(target) for outgoing, but only
		-- when we can correlate it to a very recent player cast (MSBT-style safety).
		if isStrictOutgoingCombatLogOnly() then
			restrict = true
			instanceAware = true
		end
		-- Max correctness: UNIT_COMBAT(target) has no source attribution, so only allow
		-- it when we can correlate to the player's own casts/periodic effects.
		-- This intentionally suppresses auto-attacks from this pipeline.
		if quietMode == true then
			restrict = true
			instanceAware = true
		end
		-- If combat text / chat already produced an outgoing number for the current cast
		-- token, suppress UNIT_COMBAT(target) for that token to avoid double numbers.
		if self._castToken and self._lastCombatTextOutgoingToken == self._castToken then
			return
		end
		local inInst = false
		if IsInInstance then
			local okI, inInst = pcall(IsInInstance)
			if okI and inInst == true then
				inInst = true
				-- Inside instances, UNIT_COMBAT("target") has no source attribution and can
				-- easily pick up follower/party damage.
				if instanceAware == true then
					local members = 0
					if type(GetNumGroupMembers) == "function" then
						local okM, m = pcall(GetNumGroupMembers)
						if okM and type(m) == "number" then members = m end
					end
					-- If there are multiple members (including follower/party NPCs), do not
					-- disable this pipeline entirely (would go silent). Instead, force strict
					-- cast-correlation below so we only emit hits we can attribute.
					if members and members > 1 then
						restrict = true
						-- Hard gate: if the player is not actively casting/attacking, do NOT emit
						-- outgoing from UNIT_COMBAT(target). This prevents follower/party damage on
						-- your target from being misattributed as your outgoing when you're idle.
						local tNow = now()
						local lastAt = self._lastPlayerSpellAt
						if not (type(lastAt) == "number" and (tNow - lastAt) >= 0 and (tNow - lastAt) <= 0.90) then
							return
						end
					end
				end
			end
		end
		local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
		local function getAdaptiveBigHitThreshold(tNow)
			local base = BIG_HIT_THRESHOLD
			local maxRecent = self._recentOutgoingMax or 0
			local maxAt = self._recentOutgoingMaxAt or 0
			if type(tNow) == "number" and type(maxAt) == "number" and maxAt > 0 then
				local age = tNow - maxAt
				if age > 120 then
					maxRecent = maxRecent * 0.25
				elseif age > 60 then
					maxRecent = maxRecent * 0.50
				end
			end
			local scaled = 0
			if type(maxRecent) == "number" and maxRecent > 0 then
				scaled = maxRecent * 3
			end
			return math.max(base, scaled)
		end
		local function isCorroboratedHugeHit(tNow, amt, spellId)
			if not (restrict == true) then return true end
			local thresh = getAdaptiveBigHitThreshold(tNow)
			if not (ZSBT.IsSafeNumber(amt) and amt >= thresh) then return true end
			local lastAt = self._lastOutgoingChatAt
			local lastAmt = self._lastOutgoingChatAmount
			local lastSpell = self._lastOutgoingChatSpellId
			if not (type(lastAt) == "number" and type(lastAmt) == "number" and type(lastSpell) == "number") then
				return false
			end
			local dt = tNow - lastAt
			if dt < 0 or dt > 0.40 then
				return false
			end
			if type(spellId) == "number" and type(lastSpell) == "number" and spellId ~= lastSpell then
				return false
			end
			local diff = math.abs(amt - lastAmt)
			if diff > (math.max(2000, amt * 0.08)) then
				return false
			end
			return true
		end
		local function isCorroboratedHugePetHit(tNow, amt)
			if not (restrict == true) then return true end
			local thresh = getAdaptiveBigHitThreshold(tNow)
			if not (ZSBT.IsSafeNumber(amt) and amt >= thresh) then return true end
			local lastAt = self._lastPetChatAt
			local lastAmt = self._lastPetChatAmount
			if not (type(lastAt) == "number" and type(lastAmt) == "number") then
				return false
			end
			local dt = tNow - lastAt
			if dt < 0 or dt > 0.40 then
				return false
			end
			local diff = math.abs(amt - lastAmt)
			if diff > (math.max(2000, amt * 0.08)) then
				return false
			end
			return true
		end
		if dl >= 4 then
			local tName = safeUnitName("target")
			local tGuid = nil
			if UnitGUID then
				local okG, g = pcall(UnitGUID, "target")
				if okG and type(g) == "string" then tGuid = g end
			end
			local hostile = nil
			if UnitCanAttack then
				local okH, h = pcall(UnitCanAttack, "player", "target")
				if okH then hostile = h end
			end
			local tDbg = now()
			if dl >= 4 and dl < 5 and (tDbg - (Collector._dbgLastUnitCombatTargetAt or 0)) > 0.25 then
				Collector._dbgLastUnitCombatTargetAt = tDbg
				ECPrint(("UNIT_COMBAT_TARGET name=%s guid=%s hostile=%s action=%s desc=%s amt=%s school=%s")
					:format(dbgSafe(tName), dbgSafe(tGuid), dbgSafe(hostile), dbgSafe(action), dbgSafe(descriptor), dbgSafe(amount), dbgSafe(school)))
			end
		end

		local t = now()
		local actionStr = ZSBT.IsSafeString(action) and action or nil
		local isPhysicalEarly = ZSBT.IsSafeNumber(school) and school == 1
		if dl >= 4 and ZSBT.IsSafeNumber(amount) and amount >= getAdaptiveBigHitThreshold(t) then
			local members = nil
			if type(GetNumGroupMembers) == "function" then
				local okM, m = pcall(GetNumGroupMembers)
				if okM and type(m) == "number" then members = m end
			end
			ECPrint(("BIG_HIT UNIT_COMBAT_TARGET token=%s lastSpell=%s restrict=%s members=%s amt=%s school=%s desc=%s")
				:format(dbgSafe(self._castToken), dbgSafe(self._lastPlayerSpellId), dbgSafe(restrict), dbgSafe(members), dbgSafe(amount), dbgSafe(school), dbgSafe(descriptor)))
		end

		-- Pet combat fallback:
		-- Some clients never fire UNIT_COMBAT("pet") WOUND, but do fire UNIT_COMBAT("target")
		-- for pet hits. Also, UnitAffectingCombat("player") may be true during pet combat.
		-- Heuristic: if pet is in combat and we have no recent player cast to attribute,
		-- treat WOUND events on target as pet damage.
		if actionStr == "WOUND" and UnitAffectingCombat and UnitExists then
			local okEx, hasPet = pcall(UnitExists, "pet")
			if okEx and hasPet == true then
				local okPet, inPetCombat = pcall(UnitAffectingCombat, "pet")
				if okPet and inPetCombat == true then
					local recentPlayerCast = false
					if self._lastPlayerSpellAt then
						local age = t - (self._lastPlayerSpellAt or 0)
						local maxAge = (restrict == true) and 0.70 or 1.25
						if age >= 0 and age <= maxAge then
							recentPlayerCast = true
						end
					end
					-- DoT ticks can arrive long after the cast and look like small magic WOUND
					-- events. If we have a recent periodic spell in our window, prefer treating
					-- this as player periodic damage instead of pet damage.
					local dotSpellId = nil
					if not isPhysicalEarly then
						dotSpellId = getMostRecentPeriodicSpellId(self, t)
					end
					-- Safety: only treat it as a DoT tick if the target actually has the debuff.
					-- Without this, any recent non-periodic cast (e.g. Shadow Bolt) can "stick"
					-- as the spellId for unrelated magic WOUND ticks.
					if dotSpellId and (not hasTargetDebuffSpellId(dotSpellId)) then
						dotSpellId = nil
					end
					if dotSpellId then
						if not isCorroboratedHugeHit(t, amount, dotSpellId) then
							if dl >= 4 then
								ECPrint(("BIG_HIT_SUPPRESS src=UNIT_COMBAT_DOT token=%s spellId=%s amt=%s")
									:format(dbgSafe(self._castToken), dbgSafe(dotSpellId), dbgSafe(amount)))
							end
							return
						end
						self._recentPeriodicSpellAt[dotSpellId] = t
						local tName = safeUnitName("target")
						emit("OUTGOING_DAMAGE_COMBAT", {
							timestamp = t,
							amount = amount,
							amountText = tostring(amount),
							spellId = dotSpellId,
							amountSource = "UNIT_COMBAT_DOT",
							targetName = tName,
							isCrit = isCrit,
							isPeriodic = true,
							schoolMask = (ZSBT.IsSafeNumber(school) and school) or nil,
						})
						self._lastOutgoingCombatAt = t
						self._lastOutgoingCombatTargetName = tName
						return
					end
					if not recentPlayerCast then
						if not isCorroboratedHugePetHit(t, amount) then
							if dl >= 4 then
								ECPrint(("BIG_HIT_SUPPRESS src=PET_FALLBACK token=%s amt=%s")
									:format(dbgSafe(self._castToken), dbgSafe(amount)))
							end
							return
						end
						local pipeId = self._rawPipeCount + 1
						self._rawPipeCount = pipeId
						self._rawPipe[pipeId] = amount
						emit("PET_DAMAGE_COMBAT", {
							timestamp = t,
							rawPipeId = pipeId,
							isCrit = isCrit,
							schoolMask = ZSBT.IsSafeNumber(school) and school or nil,
							targetName = safeUnitName("target"),
						})
						return
					end
				end
			end
		end
		-- Healing dummies / friendly targets can still produce noisy UNIT_COMBAT
		-- signals in 12.0. Never treat non-attackable targets as outgoing *damage*.
		-- However, allow HEAL so outgoing healing can still be shown.
		if UnitCanAttack and actionStr ~= "HEAL" then
			local okH2, h2 = pcall(UnitCanAttack, "player", "target")
			if okH2 and h2 == false then
				return
			end
		end

		if actionStr == "HEAL" then
			-- PvP Strict Mode: UNIT_COMBAT(target) healing has no ownership attribution and
			-- can frequently represent other players' healing on your target.
			-- Suppress to prevent green outgoing noise (especially for non-healer classes).
			if isPvPStrictActive() then
				return
			end
			local pipeId = self._rawPipeCount + 1
			self._rawPipeCount = pipeId
			self._rawPipe[pipeId] = amount

			local spellId = nil
			if self._lastPlayerSpellAt and self._lastPlayerSpellId then
				local age = t - (self._lastPlayerSpellAt or 0)
				if age >= 0 and age <= 1.5 then
					spellId = self._lastPlayerSpellId
				end
			end
			if restrict and not spellId then
				return
			end

			emit("OUTGOING_HEAL_COMBAT", {
				timestamp = t,
				rawPipeId = pipeId,
				spellId = spellId,
				targetName = safeUnitName("target"),
				isCrit = isCrit,
				schoolMask = ZSBT.IsSafeNumber(school) and school or nil,
			})
			return
		end
		if actionStr and actionStr ~= "WOUND" then
			return
		end
		-- Filter non-hit descriptors that frequently show up as small/zero values.
		-- These are not reliable "spell hit" signals for our attribution fallback.
		if ZSBT.IsSafeString(descriptor) then
			if descriptor == "ABSORB" or descriptor == "BLOCK" or descriptor == "RESIST" or descriptor == "IMMUNE" then
				return
			end
		end
		local isPhysical = isPhysicalEarly
		local hasPet = false
		if UnitExists then
			local ok, res = pcall(UnitExists, "pet")
			if ok and res == true then hasPet = true end
		end
		local allowAutoFallback = false
		if restrict == true and (not hasPet) then
			if isPvPStrictActive() and getPvPStrictFlag("pvpStrictDisableAutoAttackFallback") ~= false then
				allowAutoFallback = false
			else
			-- Normal behavior: instance-only opt-in auto-attack fallback.
			if quietMode ~= true then
				if ZSBT and ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general and ZSBT.db.profile.general.autoAttackRestrictFallback == true then
					allowAutoFallback = true
				end
			-- Quiet mode behavior: separate opt-in for showing auto-attacks while quiet.
			elseif isQuietOutgoingAutoAttacks() == true then
				local inPlayerCombat = false
				if UnitAffectingCombat then
					local okC, res = pcall(UnitAffectingCombat, "player")
					if okC and type(res) == "boolean" then inPlayerCombat = res end
				end
				if inPlayerCombat then
					if isPlayerAutoAttackActive() or isPlayerMeleeEngaged() then
						allowAutoFallback = true
					end
				end
			end
			end
		end

		-- PHYSICAL: do not merge. Multiple swings / cleaves / multistrikes would be
		-- incorrectly collapsed. We only accept physical UNIT_COMBAT(target) when it is
		-- unambiguous (no pet) or when we can match it to a recent player cast.
		if isPhysical then
			if ZSBT.IsSafeNumber(amount) and amount > 0 and amount < 50 then
				return
			end
			-- Rend (772) periodic ticks are physical WOUND events in 12.x and contain no spellId.
			-- Warrior-only heuristic: after a recent Rend cast, emit tick-like wounds as periodic.
			if false and isPlayerClassTag("WARRIOR") then
				local rAt = self._rendLastCastAt
				if type(rAt) == "number" then
					local ageCast = t - rAt
					if ageCast >= 0 and ageCast <= 24.0 and actionStr == "WOUND" and ZSBT.IsSafeNumber(amount) and amount > 0 then
						local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
						local debuffOk = hasTargetDebuffSpellId(772)
						local nextTickAt = self._rendNextTickAt
						local isNearExpected = false
						local dtNext = nil
						if type(nextTickAt) == "number" then
							dtNext = t - nextTickAt
							-- Asymmetric window: allow being late (events can be delayed), but be
							-- strict about being early to avoid seeding on pre-tick ability hits.
							if dtNext >= -0.20 and dtNext <= 0.90 then
								isNearExpected = true
							end
						end
						if debuffOk ~= true and ageCast <= 0.25 and not self._rendInitialHitAmt then
							if ZSBT.IsSafeNumber(amount) and amount > 0 then
								self._rendInitialHitAmt = amount
							end
						end
						local allowRendAttrib = true
						if debuffOk ~= true then
							if isPlayerAutoAttackActive() then
								if dl >= 5 then
									ECPrint(("REND_DEBUFF_MISS aa=1 ageCast=%.3f amt=%s"):format(ageCast, dbgSafe(amount)))
								end
								allowRendAttrib = false
							end
							if allowRendAttrib and dl >= 5 then
								ECPrint(("REND_DEBUFF_MISS aa=0 ageCast=%.3f amt=%s"):format(ageCast, dbgSafe(amount)))
							end
							-- Do not disable Rend attribution just because we're not near the expected
							-- tick time. Under heavy combat noise, nextTickAt can get out of sync;
							-- we still want to track state so we can detect repeating tick patterns.
						end
						if allowRendAttrib ~= true then
							-- Fall through to generic physical logic below.
						else
							local st = self._rendTickState
							if type(st) ~= "table" then
								st = { amt = nil, lastAt = 0, streak = 0, lastEmitAt = 0 }
								self._rendTickState = st
							end
							if dl >= 5 then
								ECPrint(("REND_CLASS ageCast=%.3f amt=%s next=%s near=%s debuffOk=%s aa=%s cand=%s streak=%s lastAt=%s")
									:format(ageCast, dbgSafe(amount), dbgSafe(nextTickAt), dbgSafe(isNearExpected), dbgSafe(debuffOk), dbgSafe(isPlayerAutoAttackActive()), dbgSafe(st.amt), dbgSafe(st.streak), dbgSafe(st.lastAt)))
							end
							-- If we don't have a baseline tick candidate yet, seed it on the first
							-- near-expected event. This prevents the tickLike window (based on dt)
							-- from never starting due to lastAt=0.
							local canSeed = (debuffOk ~= true and isNearExpected == true and (not dtNext or dtNext >= -0.20) and not (type(st.lastAt) == "number" and st.lastAt > 0))
							if canSeed and ZSBT.IsSafeNumber(self._rendInitialHitAmt) and self._rendInitialHitAmt > 0 then
								-- Require tick candidates to be much smaller than the application hit.
								-- This is ratio-based and scales across level/gear.
								if not (amount <= (self._rendInitialHitAmt * 0.25)) then
									canSeed = false
								end
							end
							if canSeed then
								st.amt = amount
								st.streak = 1
								st.lastAt = t
							end
							local dt = t - (st.lastAt or 0)
							local isSame = false
							if ZSBT.IsSafeNumber(st.amt) and st.amt > 0 then
								local diff = math.abs(amount - st.amt)
								local tol = math.max(10, st.amt * 0.18)
								if diff <= tol then isSame = true end
							end
							local tickLike = (dt >= 1.4 and dt <= 5.8)
							-- Only update streak state on tick-like intervals; intervening non-tick-like
							-- WOUND events are likely melee/other abilities and should not reset the
							-- current tick candidate.
							-- When the Rend debuff isn't confirmed, further require the hit to be near
							-- the expected tick time; otherwise other abilities can constantly reset
							-- the candidate amount.
							local allowTickStateUpdate = tickLike
							if dl >= 5 then
								ECPrint(("REND_CLASS2 dt=%.3f tickLike=%s isSame=%s allowState=%s cand=%s streak=%s")
									:format(dt, dbgSafe(tickLike), dbgSafe(isSame), dbgSafe(allowTickStateUpdate), dbgSafe(st.amt), dbgSafe(st.streak)))
							end
							if allowTickStateUpdate then
								if isSame then
									st.streak = (st.streak or 0) + 1
								else
									-- When debuff isn't confirmed, lock in the candidate amount once we
									-- have a repeating streak to prevent other physical hits near the
									-- tick window from hijacking the classifier.
									if not (debuffOk ~= true and (st.streak or 0) >= 2) then
										st.amt = amount
										st.streak = 1
									end
								end
								st.lastAt = t
								-- If we have a repeating tick-like pattern, resync the expected tick clock
								-- even if we didn't emit yet. This prevents nextTickAt from getting stuck
								-- at cast+3 and missing later ticks under heavy combat noise.
								if debuffOk ~= true and isSame == true and (st.streak or 0) >= 2 then
									-- Typical Rend tick spacing is ~3s; use a tighter band here to avoid
									-- latching onto unrelated repeating damage.
									if dt >= 2.2 and dt <= 3.8 then
										self._rendNextTickAt = t + 3.0
									end
								end
							end
							local firstTickLike = false
							if debuffOk == true then
								firstTickLike = (ageCast >= 1.8 and ageCast <= 6.5)
							elseif isNearExpected == true then
								firstTickLike = true
							end
							local canEmit = false
							if debuffOk == true then
								canEmit = (st.streak or 0) >= 2 or firstTickLike == true
							else
								-- Debuff not confirmed: emit only after a repeating tick pattern is
								-- established. Prefer the expected tick time gate when available, but
								-- also allow the emission when the spacing itself is strongly tick-like
								-- (~3s) to recover when nextTickAt has drifted.
								local streakOk = (st.streak or 0) >= 2
								local spacingOk = (dt >= 2.2 and dt <= 3.8)
								canEmit = streakOk and (isNearExpected == true or spacingOk == true)
							end
							if dl >= 5 then
								ECPrint(("REND_DECIDE canEmit=%s streak=%s near=%s firstTickLike=%s")
									:format(dbgSafe(canEmit), dbgSafe(st.streak), dbgSafe(isNearExpected), dbgSafe(firstTickLike)))
							end
							if canEmit then
								local dtEmit = t - (st.lastEmitAt or 0)
								if dtEmit < 0 or dtEmit > 0.80 then
									st.lastEmitAt = t
									local tName = safeUnitName("target")
									emit("OUTGOING_DAMAGE_COMBAT", {
										timestamp = t,
										amount = amount,
										amountText = tostring(amount),
										spellId = 772,
										amountSource = "UNIT_COMBAT_DOT",
										targetName = tName,
										isCrit = isCrit,
										isPeriodic = true,
										schoolMask = 1,
									})
									local dl2 = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
									if dl2 >= 5 then
										ECPrint(("REND_EMIT ageCast=%.3f amt=%s cand=%s streak=%s near=%s debuffOk=%s")
											:format(ageCast, dbgSafe(amount), dbgSafe(st.amt), dbgSafe(st.streak), dbgSafe(isNearExpected), dbgSafe(debuffOk)))
									end
									self._rendNextTickAt = t + 3.0
									self._lastOutgoingCombatAt = t
									self._lastOutgoingCombatTargetName = tName
								end
							end
						end
					end
				end
			end
			-- Attempt to attribute physical hits to a recent cast (abilities like Shield Slam).
			-- If no match exists, treat as auto-attack (no icon). If a pet exists, we require
			-- a match to avoid mis-attributing pet melee.
			local castWindow = (restrict == true) and 0.35 or 0.85
			local wantSpellId = nil
			if restrict == true then
				wantSpellId = self._lastPlayerSpellId
			end
			local wwRecent = false
			if isWhirlwindSpellId(self._lastPlayerSpellId) and self._lastPlayerSpellAt then
				local age = t - (self._lastPlayerSpellAt or 0)
				if age >= 0 and age <= 0.85 then
					wwRecent = true
				end
			end
			if wwRecent and not wantSpellId then
				wantSpellId = self._lastPlayerSpellId
			end
			local doConsume = true
			if restrict ~= true then
				doConsume = true
			elseif isWhirlwindSpellId(wantSpellId) then
				local tok = self._castToken
				local st = self._restrictPhysMulti
				if type(st) ~= "table" or st.token ~= tok or st.spellId ~= wantSpellId or (t - (st.at or 0)) > 0.60 then
					st = { token = tok, spellId = wantSpellId, at = t, count = 0, firstAmt = nil }
					self._restrictPhysMulti = st
				end
				st.count = (st.count or 0) + 1
				-- Whirlwind can produce many rapid physical hits. In strict/restricted mode,
				-- keep the pending cast available so multiple hits can still be attributed.
				doConsume = false
			end
			local matchedCast = consumeBestPendingCast(self, t, wantSpellId, castWindow, doConsume)
			-- Strict/restricted mode normally requires a pending-cast match. For Whirlwind,
			-- the UNIT_COMBAT(target) stream can contain more hits than we can reliably
			-- match; allow a short post-cast window to still attribute as Whirlwind.
			if (not matchedCast) and isWhirlwindSpellId(wantSpellId) and wwRecent then
				matchedCast = { spellId = wantSpellId, eligibleIcon = true }
			end
			if restrict and (not matchedCast) and allowAutoFallback == true then
				-- Last-resort: show an auto-attack-like hit even though UNIT_COMBAT(target)
				-- has no source attribution in 12.0. Gate aggressively to minimize
				-- follower/party melee misattribution.
				local canShow = true
				if UnitCanAttack then
					local okAtk, atk = pcall(UnitCanAttack, "player", "target")
					if okAtk and atk == false then
						canShow = false
					end
				end
				if canShow then
					local speed = nil
					if UnitAttackSpeed then
						local okS, mh = pcall(UnitAttackSpeed, "player")
						if okS and type(mh) == "number" and mh > 0 then speed = mh end
					end
					local minGap = 0.35
					if type(speed) == "number" then
						minGap = math.max(0.25, speed * 0.45)
					end
					local lastAt = self._lastAutoRestrictAt or 0
					if (t - lastAt) < minGap then
						canShow = false
					end
				end
				if canShow then
					self._lastAutoRestrictAt = t
					local pipeId = self._rawPipeCount + 1
					self._rawPipeCount = pipeId
					self._rawPipe[pipeId] = amount
					self._lastOutgoingCombatAt = t
					self._lastOutgoingCombatTargetName = safeUnitName("target")
					emit("OUTGOING_DAMAGE_COMBAT", {
						timestamp = t,
						rawPipeId = pipeId,
						spellId = nil,
						isAuto = true,
						amountSource = "UNIT_COMBAT_AUTO_FALLBACK",
						targetName = safeUnitName("target"),
						isCrit = isCrit,
						schoolMask = ZSBT.IsSafeNumber(school) and school or nil,
					})
					return
				end
			end
			if restrict and not matchedCast then
				return
			end
			if hasPet and not matchedCast then
				return
			end
			local spellId = nil
			if matchedCast then
				spellId = (matchedCast.eligibleIcon == true) and matchedCast.spellId or nil
			end
			-- Prevent Whirlwind multi-hit attribution from absorbing unrelated huge physical
			-- spikes in restricted instances (follower/party melee has no source attribution).
			if restrict == true and isWhirlwindSpellId(spellId) and ZSBT.IsSafeNumber(amount) then
				local st = self._restrictPhysMulti
				if type(st) == "table" and st.token == self._castToken and isWhirlwindSpellId(st.spellId) then
					if not (ZSBT.IsSafeNumber(st.firstAmt) and st.firstAmt > 0) then
						st.firstAmt = amount
					else
						local first = st.firstAmt
						if amount > (first * 2.2) and amount > (first + 5000) and amount > 20000 then
							return
						end
					end
				end
			end
			if not isCorroboratedHugeHit(t, amount, spellId or self._lastPlayerSpellId) then
				if dl >= 4 then
					ECPrint(("BIG_HIT_SUPPRESS src=UNIT_COMBAT_PHYSICAL token=%s spellId=%s amt=%s")
						:format(dbgSafe(self._castToken), dbgSafe(spellId), dbgSafe(amount)))
				end
				return
			end
			if isWhirlwindSpellId(spellId) and wwAggEnabled(spellId) then
				-- If we are receiving addon-readable Whirlwind chat hits for this same cast,
				-- do not double-count the UNIT_COMBAT stream.
				local chatTok = self._wwAggChatToken
				local chatAt = self._wwAggChatAt or 0
				if chatTok == self._castToken and (t - chatAt) >= 0 and (t - chatAt) <= 1.25 then
					return
				end
				wwAggPush(self, t, spellId, amount, isCrit)
				return
			end
			local pipeId = self._rawPipeCount + 1
			self._rawPipeCount = pipeId
			self._rawPipe[pipeId] = amount
			self._lastOutgoingCombatAt = t
			self._lastOutgoingCombatTargetName = safeUnitName("target")
			emit("OUTGOING_DAMAGE_COMBAT", {
				timestamp = t,
				rawPipeId = pipeId,
				spellId = spellId,
				isAuto = (spellId == nil),
				amountSource = "UNIT_COMBAT_PHYSICAL",
				targetName = safeUnitName("target"),
				isCrit = isCrit,
				schoolMask = ZSBT.IsSafeNumber(school) and school or nil,
			})
			return
		end

		-- NON-PHYSICAL: merge into one best hit per cast.
		-- Merge window: multiple UNIT_COMBAT(target) hits can arrive per cast.
		-- Keep only the largest amount in a short window to avoid showing tiny
		-- proc/secondary values (the root cause of the "300-900 Shadow Bolt" bug).
		local tokenKey = self._castToken
		if not tokenKey then
			-- If we somehow have no cast token, fall back to a time bucket.
			tokenKey = tostring(math.floor(t * 10))
		end
		if not self._bestOutgoingByToken then
			self._bestOutgoingByToken = {}
		end
		local existing = self._bestOutgoingByToken[tokenKey]
		-- Safety: never allow an old bucket to persist and keep re-attributing spellId
		-- across later unrelated UNIT_COMBAT(target) ticks. Buckets are meant to live
		-- only for the short merge window.
		if existing and type(existing.timestamp) == "number" then
			local age = t - existing.timestamp
			if age < 0 or age > 0.20 then
				self._bestOutgoingByToken[tokenKey] = nil
				existing = nil
			end
		end

		-- If no existing bucket, only start one when we can attribute this hit.
		local matchedCast = nil
		if not existing then
			-- Prevent tiny procs/secondary effects from starting a bucket.
			if not isPhysical and ZSBT.IsSafeNumber(amount) and amount > 0 and amount < 500 then
				-- DoT ticks often show up as small UNIT_COMBAT(target) magic WOUND events.
				-- If we recently cast a periodic-capable spell, treat this as outgoing
				-- periodic damage instead of dropping it as a proc.
				local dotSpellId = getMostRecentPeriodicSpellId(self, t)
				-- Safety: only treat it as a DoT tick if the target actually has the debuff.
				if dotSpellId and (not hasTargetDebuffSpellId(dotSpellId)) then
					dotSpellId = nil
				end
				if dotSpellId then
					if dl >= 4 and ZSBT.IsSafeNumber(amount) and amount >= BIG_HIT_THRESHOLD then
						ECPrint(("BIG_HIT DOT token=%s spellId=%s amt=%s")
							:format(dbgSafe(self._castToken), dbgSafe(dotSpellId), dbgSafe(amount)))
					end
					self._recentPeriodicSpellAt[dotSpellId] = t
					local tName = safeUnitName("target")
					emit("OUTGOING_DAMAGE_COMBAT", {
						timestamp = t,
						amount = amount,
						amountText = tostring(amount),
						spellId = dotSpellId,
						amountSource = "UNIT_COMBAT_DOT",
						targetName = tName,
						isCrit = isCrit,
						isPeriodic = true,
						schoolMask = (ZSBT.IsSafeNumber(school) and school) or nil,
					})
					self._lastOutgoingCombatAt = t
					self._lastOutgoingCombatTargetName = tName
					return
				end
				return
			end
			-- Physical with a pet is too ambiguous.
			if isPhysical and hasPet then
				return
			end
			local castWindow = (restrict == true) and 0.55 or 0.85
			local wantSpellId = nil
			if restrict == true then
				wantSpellId = self._lastPlayerSpellId
			end
			matchedCast = consumeBestPendingCast(self, t, wantSpellId, castWindow)
			if not matchedCast then
				return
			end
		end

		local spellId = nil
		if existing and existing.spellId then
			spellId = existing.spellId
		elseif matchedCast then
			spellId = (matchedCast.eligibleIcon == true) and matchedCast.spellId or nil
		end

		-- Merge window: multiple UNIT_COMBAT(target) hits can arrive per cast.
		-- Keep only the largest amount in a short window to avoid showing tiny
		-- proc/secondary values (the root cause of the "300-900 Shadow Bolt" bug).
		local token = tokenKey
		local schoolMask = (ZSBT.IsSafeNumber(school) and school) or nil
		local targetName = safeUnitName("target")
		local bucket = self._bestOutgoingByToken[token]
		if not bucket then
			if not isCorroboratedHugeHit(t, amount, spellId or self._lastPlayerSpellId) then
				if dl >= 4 then
					ECPrint(("BIG_HIT_SUPPRESS src=UNIT_COMBAT_BEST_START token=%s spellId=%s amt=%s")
						:format(dbgSafe(self._castToken), dbgSafe(spellId), dbgSafe(amount)))
				end
				return
			end
			bucket = {
				timestamp = t,
				token = token,
				spellId = spellId,
				targetName = targetName,
				amount = amount,
				_seenCount = 1,
				_seenMax = amount,
				_seenSecond = nil,
				isCrit = isCrit,
				schoolMask = schoolMask,
			}
			self._bestOutgoingByToken[token] = bucket
			if C_Timer and C_Timer.After then
				C_Timer.After(0.08, function() flushBestOutgoing(self, token) end)
			else
				-- Fallback: emit immediately if timers are unavailable.
				flushBestOutgoing(self, token)
			end
		else
			if ZSBT.IsSafeNumber(amount) then
				bucket._seenCount = (bucket._seenCount or 0) + 1
				local maxA = bucket._seenMax
				if (not ZSBT.IsSafeNumber(maxA)) or amount > maxA then
					bucket._seenSecond = maxA
					bucket._seenMax = amount
				elseif (not ZSBT.IsSafeNumber(bucket._seenSecond)) or amount > bucket._seenSecond then
					bucket._seenSecond = amount
				end
			end
			if ZSBT.IsSafeNumber(amount) and (not ZSBT.IsSafeNumber(bucket.amount) or amount > bucket.amount) then
				bucket.amount = amount
				bucket.isCrit = isCrit or bucket.isCrit
				bucket.schoolMask = schoolMask or bucket.schoolMask
				bucket.targetName = targetName or bucket.targetName
				bucket.spellId = bucket.spellId or spellId
			end
		end
		return
	end

	-- Only UNIT_COMBAT("player") is used for incoming damage/heal.
	-- UNIT_COMBAT("target") is ambiguous in WoW 12.0 and must never produce
	-- INCOMING_DAMAGE (it causes the exact spam you observed during pet-only combat).
	if unit ~= "player" then
		return
	end

	-- INCOMING: player taking damage/heals (unit == "player")
	-- Dedup: if COMBAT_TEXT_UPDATE already provided clean data for this
	-- hit within the last 100ms, skip to avoid duplicate text.
	local t = now()
	if (t - self._lastCombatTextDamageAt) < DEDUP_WINDOW then return end
	if unit == "player" and action == "WOUND" then
		if ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) >= 3 then
			if ZSBT.Addon and ZSBT.Addon.Print and (t - (Collector._dbgLastUnitCombatPlayerAt or 0)) > 0.25 then
				Collector._dbgLastUnitCombatPlayerAt = t
				ECPrint(("UNIT_COMBAT_PLAYER action=%s desc=%s amt=%s")
					:format(dbgSafe(action), dbgSafe(descriptor), dbgSafe(amount)))
			end
		end
	end
	if (t - self._lastCombatTextHealAt) < DEDUP_WINDOW then return end

	local numAmount, amountText, secret = launderAmount(amount)

	-- Classify by amount sign and school when action is tainted.
	-- For "player" UNIT_COMBAT: positive amounts = damage taken, 
	-- and physical fall damage has school == 1 while falling.
	local isPhysical = ZSBT.IsSafeNumber(school) and school == 1

	-- Check if action is safe to inspect; if so, use it for routing.
	-- If tainted, we do NOT attempt to guess; in Midnight this can misfire
	-- during pet combat and produce false player damage.
	local actionStr = ZSBT.IsSafeString(action) and action or nil

	-- Sanity check for unit=="player": only emit incoming damage if the
	-- player's health actually dropped. This blocks misfires where UNIT_COMBAT
	-- reports a WOUND-like event even though the player took no damage (e.g.
	-- pet/guardian damage or protected combat text quirks).
	local function playerHealthDropped()
		if unit ~= "player" then return true end
		local cur = UnitHealth and UnitHealth("player") or nil
		if not ZSBT.IsSafeNumber(cur) then
			return true -- fail open: cannot validate in secret-health contexts
		end
		self._lastHealth = self._lastHealth or {}
		local prev = self._lastHealth["player"]
		-- Update baseline immediately so repeated UNIT_COMBAT misfires cannot
		-- spam incoming damage when health is unchanged.
		self._lastHealth["player"] = cur
		if not ZSBT.IsSafeNumber(prev) then
			return false -- require baseline before emitting
		end
		return cur < prev
	end

	if actionStr == "HEAL" then
		-- Player received healing.
		-- WoW 12.0 quirk: UNIT_COMBAT(player) can misfire and report healing-like
		-- events even when the player did not actually gain health. Only trust it
		-- if we also observed a real UNIT_HEALTH(player) increase recently.
		local cur = UnitHealth and UnitHealth("player") or nil
		if ZSBT.IsSafeNumber(cur) then
			local tNow = now()
			if not (self._lastPlayerHealthHealAt and (tNow - self._lastPlayerHealthHealAt) <= 0.30) then
				return
			end
		end
		emit("INCOMING_HEAL_COMBAT", {
			timestamp = now(),
			amount = numAmount,
			amountText = amountText,
			isCrit = isCrit,
			isSecret = secret,
			school = ZSBT.IsSafeNumber(school) and school or nil,
		})
	elseif actionStr == "WOUND" then
		-- Confirmed WOUND (damage taken).
		if isPhysical and isFalling then
			emit("FALL_DAMAGE", {
				timestamp = now(),
				unit = unit,
				amount = numAmount,
				amountText = amountText,
				isCrit = false,
				isSecret = secret,
				school = isPhysical and school or 1,
			})
		else
			if not playerHealthDropped() then
				return
			end
			self._lastUnitCombatPlayerDamageAt = now()
			emit("INCOMING_DAMAGE", {
				timestamp = now(),
				unit = unit,
				amount = numAmount,
				amountText = amountText,
				isCrit = isCrit,
				isSecret = secret,
				school = ZSBT.IsSafeNumber(school) and school or nil,
			})
		end
	end
	-- DODGE, PARRY, BLOCK, RESIST: amount is 0 or irrelevant, skip.
end

--==================================--
-- Unit Health Tracking (UNIT_HEALTH correlation engine)
--==================================--

	-- Track health deltas for units used by the damage correlation engine.
function Collector:handleUnitHealth(unit)
	if unit ~= "target" and unit ~= "mouseover" and unit ~= "player" then return end

	local health = UnitHealth and UnitHealth(unit) or nil
	local healthMax = UnitHealthMax and UnitHealthMax(unit) or nil

	local guid = nil
	if UnitGUID then
		local ok, g = pcall(UnitGUID, unit)
		if ok and type(g) == "string" then
			guid = g
		end
	end

	-- WoW 12.0 Secret Value detection — also handle nil returns
	if not ZSBT.IsSafeNumber(health) or not ZSBT.IsSafeNumber(healthMax) then
		-- Flush any cached health so a stale secret value never
		-- survives into a future arithmetic delta.
		self._lastHealth[unit] = nil
		self._lastUnitGuid[unit] = guid

		-- Only emit secret event if we actually got a value (not nil)
		if isSecretValue(health) or isSecretValue(healthMax) then
			emit("HEALTH_CHANGE_SECRET", {
				timestamp = now(),
				unit = unit,
				targetName = safeUnitName(unit),
				isSecret = true,
			})
		end
		return
	end

	local lastGuid = self._lastUnitGuid[unit]
	if guid ~= nil and lastGuid ~= nil and guid ~= lastGuid then
		self._lastUnitGuid[unit] = guid
		self._lastHealth[unit] = health
		return
	end
	if guid ~= nil and lastGuid == nil then
		self._lastUnitGuid[unit] = guid
	end

	-- Check if we've seen this unit before
	local oldHealth = self._lastHealth[unit]
	self._lastHealth[unit] = health

	-- Guard: oldHealth must be a safe number for arithmetic.
	if not ZSBT.IsSafeNumber(oldHealth) then
		return
	end

	-- Calculate health change (positive = damage, negative = healing)
	local delta = oldHealth - health

	-- Some units (notably training/healing dummies) can have scripted health
	-- resets/regen that produce enormous deltas unrelated to actual spells.
	-- Clamp implausible deltas to prevent fake multi-million heal/damage events.
	local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
	local absDelta = math.abs(delta)
	local maxN = healthMax
	local maxFrac = 0
	local maxUsable = (ZSBT.IsSafeNumber(maxN) and maxN > 0)
	if maxUsable then
		maxFrac = absDelta / maxN
	end
	local shouldClamp = false
	if absDelta > 50000 then
		if not maxUsable then
			shouldClamp = true
		elseif maxFrac >= 0.05 then
			shouldClamp = true
		end
	end
	if shouldClamp then
		if dl >= 4 then
			ECPrint(("UNIT_HEALTH_CLAMP unit=%s guid=%s old=%s new=%s max=%s maxOk=%s delta=%s frac=%s")
				:format(dbgSafe(unit), dbgSafe(guid), dbgSafe(oldHealth), dbgSafe(health), dbgSafe(healthMax), dbgSafe(maxUsable), dbgSafe(delta), dbgSafe(maxFrac)))
		end
		self._lastHealth[unit] = health
		return
	end

	-- Emit damage if health decreased
	if delta > 0 then
		if unit == "player" then
			self._lastPlayerHealthDamageAt = now()
		end
		-- Outgoing dedup: if we just emitted an outgoing hit from UNIT_COMBAT,
		-- suppress the near-simultaneous health delta for the same target.
		if unit == "target" and self._lastOutgoingCombatAt and (now() - self._lastOutgoingCombatAt) < OUTGOING_HEALTH_DEDUP_WINDOW then
			local tn = safeUnitName(unit)
			if ZSBT.IsSafeString(tn) and ZSBT.IsSafeString(self._lastOutgoingCombatTargetName)
				and tn == self._lastOutgoingCombatTargetName then
				return
			end
		end

		emit("HEALTH_DAMAGE", {
			timestamp = now(),
			unit = unit,
			amount = delta,
			targetName = safeUnitName(unit),
			health = health,
			healthMax = healthMax,
		})
	-- Emit healing if health increased
	elseif delta < 0 then
		local healAmt = -delta
		if healAmt > 50000 then
			if dl >= 4 then
				ECPrint(("HEALTH_HEAL_CLAMP unit=%s guid=%s old=%s new=%s max=%s amt=%s")
					:format(dbgSafe(unit), dbgSafe(guid), dbgSafe(oldHealth), dbgSafe(health), dbgSafe(healthMax), dbgSafe(healAmt)))
			end
			self._lastHealth[unit] = health
			return
		end
		if unit == "player" then
			self._lastPlayerHealthHealAt = now()
		end
		emit("HEALTH_HEAL", {
			timestamp = now(),
			unit = unit,
			amount = healAmt,
			targetName = safeUnitName(unit),
			health = health,
			healthMax = healthMax,
		})
	end

	-- Also emit general health change for correlation engine
	emit("UNIT_HEALTH", {
		timestamp = now(),
		unit = unit,
		health = health,
		healthMax = healthMax,
		targetName = safeUnitName(unit),
	})
end

--==================================--
-- Enable / Disable Lifecycle
--==================================--

-- Register events and initialize runtime frames used by the collector.
function Collector:Enable()
	if self._enabled then return end
	resetFallingState()

	-- Create the event frame once and route events to parser handlers.
	if not self._frame then
		self._frame = CreateFrame("Frame")
		self._frame:SetScript("OnEvent", function(_, event, ...)
			if event == "UNIT_SPELLCAST_SUCCEEDED" then
				Collector:handleSpellcastSucceeded(...)
			elseif event == "UNIT_HEALTH" or event == "UNIT_HEALTH_FREQUENT" then
				Collector:handleUnitHealth(...)
			elseif event == "COMBAT_TEXT_UPDATE" then
				Collector:handleCombatTextUpdate(...)
			elseif event == "UNIT_COMBAT" then
				Collector:handleUnitCombat(...)
			elseif CHAT_OUTGOING_EVENTS[event] then
				local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
				local msg = select(1, ...)
				if dl >= 5 then
					if type(msg) == "string" and (msg:find("Whirlwind", 1, true) or msg:find("whirlwind", 1, true)) then
						Collector._dbgWWChatRecvAt = now()
						Collector._dbgWWChatRecvCount = (Collector._dbgWWChatRecvCount or 0) + 1
						ECPrint(("CHAT_OUT WW recv evt=%s msg=%s"):format(dbgSafe(event), dbgSafe(msg:sub(1, 160))))
					end
				elseif dl >= 4 then
					local msg = select(1, ...)
					if type(msg) == "string" then
						ECPrint(("CHAT_OUT recv evt=%s msg=%s"):format(dbgSafe(event), dbgSafe(msg:sub(1, 160))))
					else
						ECPrint(("CHAT_OUT recv evt=%s msg=%s"):format(dbgSafe(event), dbgSafe(msg)))
					end
				end
				Collector:handleChatSelfDamage(event, ...)
			end
		end)
	end

	-- Blizzard 12.0 combat text pipeline: COMBAT_TEXT_UPDATE may not carry damage
	-- tokens in some environments, even though Blizzard is rendering damage.
	-- Hook the known entry points for diagnostics (trace-only for now).
	if not self._combatTextAddHooked and type(hooksecurefunc) == "function" then
		local hookNames = {
			"CombatText_AddMessage",
			"CombatText_AddMessage_v2",
			"CombatText_AddMessage2",
			"CombatText_AddMessage2_v2",
		}
		for _, fnName in ipairs(hookNames) do
			if type(_G[fnName]) == "function" then
				self._combatTextAddHooked = true
				hooksecurefunc(fnName, function(message, scrollFunction, r, g, b, displayType, isSticky)
					local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
					if dl >= 4 and ZSBT.Addon and ZSBT.Addon.Print then
						local tNow = now()
						if (tNow - (Collector._dbgLastCombatTextAddAt or 0)) > 0.20 then
							Collector._dbgLastCombatTextAddAt = tNow
							ZSBT.Addon:Print("|cFF00CC66[EC]|r", ("CT_ADD fn=%s msg=%s type=%s sticky=%s")
								:format(dbgSafe(fnName), dbgSafe(message), dbgSafe(displayType), dbgSafe(isSticky)))
						end
					end
				end)
			end
		end
	end

	-- Create a lightweight OnUpdate watcher once for fall state transitions.
	if not Collector._fallingFrame then
		Collector._fallingFrame = CreateFrame("Frame")
		local acc = 0
		Collector._fallingFrame:SetScript("OnUpdate", function(_, elapsed)
			acc = acc + (elapsed or 0)
			if acc < 0.10 then
				return
			end
			acc = 0
			if IsFalling("player") then
				isFalling = true
				if fallingTimer then
					fallingTimer:Cancel()
					fallingTimer = nil
				end
			elseif isFalling then
				if not fallingTimer then
					fallingTimer = C_Timer.NewTimer(0.25, function()
						isFalling = false
						fallingTimer = nil
					end)
				end
			end
		end)
	end

	-- Subscribe to WoW events used by this collector.
	self._frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
	self._frame:RegisterEvent("UNIT_HEALTH")
	pcall(function() self._frame:RegisterEvent("UNIT_HEALTH_FREQUENT") end)
	self._frame:RegisterEvent("COMBAT_TEXT_UPDATE")
	self._frame:RegisterEvent("UNIT_COMBAT")
	for evtName in pairs(CHAT_OUTGOING_EVENTS) do
		pcall(function() self._frame:RegisterEvent(evtName) end)
	end
	self._enabled = true
	if ZSBT.Addon and ZSBT.Addon.Print then
	end
end

-- Unregister events and clear transient runtime state.
function Collector:Disable()
	if not self._enabled then return end
	if self._frame then
		self._frame:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
		self._frame:UnregisterEvent("UNIT_HEALTH")
		pcall(function() self._frame:UnregisterEvent("UNIT_HEALTH_FREQUENT") end)
		self._frame:UnregisterEvent("COMBAT_TEXT_UPDATE")
		self._frame:UnregisterEvent("UNIT_COMBAT")
		for evtName in pairs(CHAT_OUTGOING_EVENTS) do
			pcall(function() self._frame:UnregisterEvent(evtName) end)
		end
	end
	resetFallingState()
	self._enabled = false
	self._lastHealth = {}
	self._lastPlayerSpellName = nil
	self._lastPlayerSpellId = nil
end
