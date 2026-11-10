-- Periodic damage tracker.
--
-- Owns all per-DoT attribution state that used to be spread across
-- Event_Collector: the periodic-aura name table, the throttled target aura
-- scan, cast-seeded candidates, and per-DoT records (apply time, staleness,
-- learned school, learned tick interval, predicted next tick).
--
-- MatchHit() returns the best periodic candidate for an unattributed hit;
-- confidence policy (pending casts, schools, quiet modes, class gates) stays
-- at the call sites because each path's rules genuinely differ.
--
-- Hard limits honoured here:
--   * no COMBAT_LOG_EVENT_UNFILTERED (protected on secret-value clients)
--   * no combat-log text reads — CombatLog_Lines consumes RGB only
--   * secret values never compared/concatenated; only safe numbers are stored

local ADDON_NAME, ZSBT = ...

local PT = {}
ZSBT.PeriodicTracker = PT

local function ptDbg(msg)
	local Addon = ZSBT and ZSBT.Addon
	if Addon and Addon.Dbg then
		Addon:Dbg("outgoing", 4, msg)
	end
end

local function now()
	return GetTime()
end

local function IsSafeNumber(v)
	return ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) or false
end

local function dbgSafe(v)
	if type(v) == "number" and IsSafeNumber(v) then
		return string.format("%s", v)
	end
	if type(v) == "string" and (not ZSBT.IsSafeString or ZSBT.IsSafeString(v)) then
		return v
	end
	return tostring(v)
end

local SCAN_INTERVAL    = 0.4   -- aura scan throttle (called per hit)
local AURA_STALE_SEC   = 2.0   -- drop aura records not re-seen within this
local CAST_WINDOW_SEC  = 30.0  -- cast/emit recency window for candidates
local TICK_WINDOW_SEC  = 0.35  -- hit-vs-predicted-tick tolerance
local MIN_INTERVAL_SEC = 0.4   -- plausible DoT tick spacing bounds
local MAX_INTERVAL_SEC = 6.0

-- AuraData exposes no "periodic" flag or tick interval, so periodic effects
-- are classified by name. Single table for ALL classes — matched against
-- auras actually present on the target, so it self-verifies.
local PERIODIC_AURA_NAMES = {
	-- Warlock
	["Corruption"] = true, ["Agony"] = true, ["Unstable Affliction"] = true,
	["Seed of Corruption"] = true, ["Wither"] = true, ["Siphon Life"] = true,
	["Immolate"] = true,
	-- Druid
	["Moonfire"] = true, ["Sunfire"] = true, ["Insect Swarm"] = true,
	["Thrash"] = true, ["Rake"] = true, ["Rip"] = true,
	-- Hunter
	["Serpent Sting"] = true, ["Barbed Shot"] = true,
	-- Rogue
	["Deadly Poison"] = true, ["Instant Poison"] = true, ["Wound Poison"] = true,
	["Rupture"] = true, ["Garrote"] = true,
	-- Death Knight
	["Frost Fever"] = true, ["Blood Plague"] = true, ["Virulent Plague"] = true,
	-- Shaman
	["Flame Shock"] = true,
	-- Priest
	["Shadow Word: Pain"] = true, ["Vampiric Touch"] = true,
	["Devouring Plague"] = true, ["Purge the Wicked"] = true,
	["Holy Fire"] = true,
	-- Mage
	["Nether Tempest"] = true, ["Living Bomb"] = true,
	-- Evoker
	["Fire Breath"] = true,
	-- Warrior
	["Rend"] = true, ["Deep Wounds"] = true,
}

-- Canonical spellIds kept as a fallback for casts whose name doesn't resolve
-- (secret strings / CleanSpellName unavailable). Name matching is preferred;
-- this list exists only where the id check used to be stricter.
local KNOWN_PERIODIC_IDS = {
	-- Warlock
	[172] = true,     -- Corruption
	[980] = true,     -- Agony
	[30108] = true,   -- Unstable Affliction
	[27243] = true,   -- Seed of Corruption
	[157736] = true,  -- Immolate
	[348] = true,     -- Immolate (legacy id)
	-- Shaman
	[188389] = true,  -- Flame Shock
	-- Druid
	[164812] = true,  -- Moonfire
	[164815] = true,  -- Sunfire
	[1822] = true,    -- Rake
	[1079] = true,    -- Rip
	-- Priest
	[589] = true,     -- Shadow Word: Pain
	[34914] = true,   -- Vampiric Touch
	[2944] = true,    -- Devouring Plague
	[204197] = true,  -- Purge the Wicked
	[14914] = true,   -- Holy Fire
	-- Mage
	[114923] = true,  -- Nether Tempest
	[44457] = true,   -- Living Bomb
	-- Evoker
	[357208] = true,  -- Fire Breath
	-- Death Knight
	[55095] = true,   -- Frost Fever
	[55078] = true,   -- Blood Plague
	-- Rogue
	[703] = true,     -- Garrote
	[1943] = true,    -- Rupture
	-- Hunter
	[217200] = true,  -- Barbed Shot
	-- Warrior
	[772] = true,     -- Rend
	[115767] = true,  -- Deep Wounds
}

local function normalizeAuraName(nm)
	if type(nm) ~= "string" or nm == "" then return nil end
	if ZSBT.IsSafeString and not ZSBT.IsSafeString(nm) then return nil end
	nm = (nm:match("^([^%(]+)") or nm):gsub("^%s+", ""):gsub("%s+$", "")
	if nm == "" then return nil end
	return nm
end

local function isPeriodicAuraNameString(nm)
	nm = normalizeAuraName(nm)
	return nm ~= nil and PERIODIC_AURA_NAMES[nm] == true
end

local function auraIsPeriodicDot(auraData, sid)
	-- Prefer the interval field if a client ever exposes it.
	local iv = auraData.interval
	if type(iv) == "number" and iv > 0 then return true end
	-- auraData.name first (already localized client-side), then
	-- CleanSpellName(spellId) as fallback.
	local nm = nil
	if type(auraData.name) == "string" then
		nm = auraData.name
	elseif type(sid) == "number" and ZSBT.CleanSpellName then
		nm = ZSBT.CleanSpellName(sid)
	end
	return isPeriodicAuraNameString(nm)
end

-- Per-DoT record:
--   applyAt     true application time (expirationTime - duration), reset on
--               refresh; scan-detection time when those fields are unsafe
--   seenAt      last aura-scan sighting (staleness expiry)
--   recencyAt   last cast or confirmed-tick emit (cast-memory window)
--   name        aura/cast name when known (for name-based resolution)
--   school      learned from the first confirmed tick (no per-class tables)
--   interval    learned tick spacing (nil until >=2 confirmed ticks)
--   nextTickAt  predicted next tick (lastTickAt + interval)
--   lastTickAt  last confirmed tick emit
--   seedSource  "cast" | "aura"
PT._dots = {}
PT._scanAt = 0

local function dotRecord(self, sid, seed)
	local d = self._dots[sid]
	if d == nil then
		d = { seedSource = seed }
		self._dots[sid] = d
	end
	return d
end

-- Seed a periodic candidate from a successful player cast. Name matching
-- covers every class; the small id list is the fallback for unresolved names.
function PT:NotePlayerCast(spellId, spellName, t)
	if type(spellId) ~= "number" or not IsSafeNumber(spellId) then return end
	if not isPeriodicAuraNameString(spellName) and KNOWN_PERIODIC_IDS[spellId] ~= true then
		return
	end
	local d = dotRecord(self, spellId, "cast")
	d.recencyAt = t
	if type(d.applyAt) ~= "number" then
		d.applyAt = t
	end
	local nm = normalizeAuraName(spellName)
	if nm then d.name = nm end
	ptDbg(("PT_SEED sid=%s name=%s"):format(dbgSafe(spellId), dbgSafe(nm)))
end

-- Throttled target-aura scan. Freshly applied debuffs are invisible to the
-- aura APIs for seconds on secret-value clients, so aura absence is not
-- evidence of absence — cast-seeded records carry the early window.
function PT:ScanTargetAuras(t)
	if (t - (self._scanAt or 0)) < SCAN_INTERVAL then return end
	self._scanAt = t
	local dots = self._dots
	local stats = { total = 0, periodic = 0 }
	local function noteAura(auraData)
		if type(auraData) ~= "table" then return true end
		stats.total = stats.total + 1
		if not self._dbgAuraFieldsDumped then
			self._dbgAuraFieldsDumped = true
			local keys = {}
			for k in pairs(auraData) do
				keys[#keys + 1] = tostring(k)
			end
			table.sort(keys)
			ptDbg(("AURA_FIELDS %s"):format(table.concat(keys, ",")))
		end
		local sid = auraData.spellId or auraData.spellID
		if not (type(sid) == "number" and IsSafeNumber(sid)) then return true end
		if not auraIsPeriodicDot(auraData, sid) then return true end
		stats.periodic = stats.periodic + 1
		-- When the API exposes the source, prefer player/pet-sourced auras.
		local src = auraData.sourceUnit
		if src ~= nil and src ~= "player" and src ~= "pet" then return true end
		-- True application time over first-scan time: the scan is throttled and
		-- fresh auras are API-invisible for seconds, so scan time would make
		-- every new DoT look "young" and drop its first ticks.
		local applyAt = t
		local exp, dur = auraData.expirationTime, auraData.duration
		if IsSafeNumber(exp) and IsSafeNumber(dur) and dur > 0 then
			local a = exp - dur
			if type(a) == "number" and IsSafeNumber(a) and a > 0 and a <= t then
				applyAt = a
			end
		end
		local d = dots[sid]
		if d == nil then
			d = { seedSource = "aura" }
			dots[sid] = d
			d.applyAt = applyAt
		elseif math.abs(applyAt - (d.applyAt or t)) > 0.25 then
			-- New application (refresh/recast): reset the application clock.
			d.applyAt = applyAt
		end
		d.seenAt = t
		d.recencyAt = d.recencyAt or t
		local nm = normalizeAuraName(auraData.name)
		if nm then d.name = nm end
		return true
	end
	if AuraUtil and AuraUtil.ForEachAura then
		pcall(function()
			AuraUtil.ForEachAura("target", "HARMFUL", 255, noteAura, true)
		end)
	end
	-- Expire records that are neither aura-fresh nor cast-fresh.
	for sid, d in pairs(dots) do
		local auraFresh = type(d.seenAt) == "number" and (t - d.seenAt) <= AURA_STALE_SEC
		local castFresh = type(d.recencyAt) == "number"
			and (t - d.recencyAt) >= 0 and (t - d.recencyAt) <= CAST_WINDOW_SEC
		if not (auraFresh or castFresh) then
			dots[sid] = nil
		end
	end
	if stats.total > 0 then
		local ages = {}
		for sid, d in pairs(dots) do
			if type(d.seenAt) == "number" and (t - d.seenAt) <= AURA_STALE_SEC then
				ages[#ages + 1] = ("%d@%.2f"):format(sid, t - (d.applyAt or t))
			end
		end
		ptDbg(("AURA_SCAN total=%s periodic=%s tracked=%s ages=%s")
			:format(dbgSafe(stats.total), dbgSafe(stats.periodic), dbgSafe(#ages),
				table.concat(ages, ",")))
	end
end

-- Returns the best periodic candidate for an unattributed hit:
--   sid, auraBacked, dotAge
-- auraBacked means the debuff is live on the target right now (ground truth).
-- dotAge is seconds since the true application when known. Scoring prefers
-- aura-fresh records, then learned-school matches, then predicted-tick
-- alignment, then most recent application.
function PT:MatchHit(t, school)
	self:ScanTargetAuras(t)
	local schoolSafe = IsSafeNumber(school)
	local bestId, bestAura, bestScore, bestApply
	local candN = 0
	for sid, d in pairs(self._dots) do
		local auraFresh = type(d.seenAt) == "number" and (t - d.seenAt) <= AURA_STALE_SEC
		local castFresh = type(d.recencyAt) == "number"
			and (t - d.recencyAt) >= 0 and (t - d.recencyAt) <= CAST_WINDOW_SEC
		if auraFresh or castFresh then
			candN = candN + 1
			local score = auraFresh and 4 or 1
			if schoolSafe and d.school ~= nil and school == d.school then
				score = score + 2
			end
			if type(d.nextTickAt) == "number" and math.abs(t - d.nextTickAt) <= TICK_WINDOW_SEC then
				score = score + 2
			end
			local ap = d.applyAt or 0
			if bestScore == nil or score > bestScore or (score == bestScore and ap > (bestApply or 0)) then
				bestId, bestAura, bestScore, bestApply = sid, auraFresh, score, ap
			end
		end
	end
	if bestId == nil then return nil, false, nil end
	local d = self._dots[bestId]
	local dotAge = (type(d.applyAt) == "number") and (t - d.applyAt) or nil
	if candN > 1 then
		ptDbg(("PT_MATCH sid=%s score=%s aura=%s cand=%d sch=%s nextTick=%s")
			:format(dbgSafe(bestId), dbgSafe(bestScore), dbgSafe(bestAura), candN,
				dbgSafe(d.school), dbgSafe(d.nextTickAt and (d.nextTickAt - t) or nil)))
	end
	return bestId, bestAura, dotAge
end

-- Aura-backed ground truth for callers that still gate on it.
function PT:IsTracked(spellId)
	local d = type(spellId) == "number" and self._dots[spellId] or nil
	return type(d) == "table" and type(d.seenAt) == "number"
		and (now() - d.seenAt) <= AURA_STALE_SEC
end

-- Record a confirmed periodic emit: refresh recency, learn the tick's school,
-- and update the learned interval / predicted next tick.
function PT:NoteEmit(spellId, t, school)
	if type(spellId) ~= "number" then return end
	local d = dotRecord(self, spellId, "cast")
	if type(d.lastTickAt) == "number" then
		local dt = t - d.lastTickAt
		if dt >= MIN_INTERVAL_SEC and dt <= MAX_INTERVAL_SEC then
			-- Simple running estimate; converges fast for steady ticks.
			local newIv = (type(d.interval) == "number")
				and ((d.interval * 0.6) + (dt * 0.4)) or dt
			if type(d.interval) ~= "number" or math.abs(newIv - d.interval) > 0.1 then
				ptDbg(("PT_LEARN sid=%s interval=%.2f"):format(dbgSafe(spellId), newIv))
			end
			d.interval = newIv
		end
	end
	d.lastTickAt = t
	d.recencyAt = t
	if type(d.interval) == "number" then
		d.nextTickAt = t + d.interval
	end
	if IsSafeNumber(school) then
		d.school = school
	end
end

-- Recency timestamp for a specific spell (cast-memory reads, e.g. the
-- combat-text path's spellId recency check).
function PT:RecentAt(spellId)
	local d = type(spellId) == "number" and self._dots[spellId] or nil
	return (type(d) == "table") and d.recencyAt or nil
end

-- Window accessor so call sites don't hardcode the 30s constant.
function PT:CastWindowSec()
	return CAST_WINDOW_SEC
end

-- Most recent candidate whose spell name matches (replaces
-- resolveRecentSpellIdByName's map iteration).
function PT:RecentByName(wantName, tNow)
	local nm = normalizeAuraName(wantName)
	if not nm then return nil end
	local bestId, bestAt
	for sid, d in pairs(self._dots) do
		local match = (d.name == nm)
		if not match and ZSBT.CleanSpellName then
			match = (ZSBT.CleanSpellName(sid) == nm)
		end
		if match and type(d.recencyAt) == "number" then
			local age = tNow - d.recencyAt
			if age >= 0 and age <= CAST_WINDOW_SEC
				and (bestAt == nil or d.recencyAt > bestAt) then
				bestAt, bestId = d.recencyAt, sid
			end
		end
	end
	return bestId
end

-- Number of currently tracked dots (diagnostics).
function PT:Count()
	local n = 0
	for _ in pairs(self._dots) do n = n + 1 end
	return n
end
