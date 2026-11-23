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

-- Chaos school (127) tooltips cover every school; hits may report the
-- composite masks 124/126 (FCT SchoolFits).
local function spellSchoolFits(learned, school)
	if learned == nil or school == nil then return true end
	if learned == school then return true end
	return learned == 127 and (school == 124 or school == 126)
end

local castSchoolOk -- fwd decl; real def below
local consumeBestPendingCast -- fwd decl; emit() calls it before the real def below
local claimSignature -- fwd decl; emit() calls it before the real def below
local sigBaseForTrigger -- fwd decl; same reason
local sigEmpowerForTrigger -- fwd decl; same reason
local sigSeed -- fwd decl; enqueuePendingCast calls it before the real def below
local anySwingRecent -- fwd decl; emit() stamps _swingProven before the real def below

-- Friendly non-player casts (pet slot, imps, guardians) recorded in
-- _petCasts. A hit claims one of them instead of taking the most recent
-- unconditionally: the newest school-fitting cast wins (FCT candidate
-- scoring) and each cast has an outcome budget — PET_CAST_MAX_CLAIMS
-- stamps total, covering AoE like Whiplash while stopping one cast from
-- absorbing an unlimited run of foreign hits.
local PET_CAST_MAX_CLAIMS = 8
-- A spell in the player's own spellbook can never be pet damage. The
-- UNIT_SPELLCAST_SUCCEEDED pet/friendly paths occasionally report a
-- player-known sid under a non-player token (Incinerate landing in
-- _petCasts produced a "Conflagrate|pet"-class misroute). IsPlayerSpell
-- is authoritative and locale-free; an API error stays permissive.
local function isPlayerSpellId(spellId)
	if type(spellId) ~= "number" then return false end
	if not (IsPlayerSpell and type(IsPlayerSpell) == "function") then return false end
	local ok, res = pcall(IsPlayerSpell, spellId)
	return ok == true and res == true
end

local function consumePetCast(self, t, window, hitSchool)
	local casts = self._petCasts
	if type(casts) ~= "table" then return nil end
	local w = window or 1.5
	for i = #casts, 1, -1 do
		local c = casts[i]
		local age = t - (c.at or 0)
		if age > w then break end
		-- Per-cast claim budget: AoE pet casts (Whiplash) claim many hits,
		-- but a single-target nuke's real damage lands first in the window
		-- — every claim past its budget is a stray wearing a pet name
		-- (Affliction's dense same-school tick stream starves this hard).
		local maxClaims = PET_CAST_MAX_CLAIMS
		if ZSBT.ClassDB and ZSBT.ClassDB.PetCastBudget then
			maxClaims = ZSBT.ClassDB.PetCastBudget(c.spellId) or maxClaims
		end
		if age >= 0
			and (c.claims or 0) < maxClaims
			and not isPlayerSpellId(c.spellId)
			and (not ZSBT.IsSafeNumber or ZSBT.IsSafeNumber(c.spellId))
			and castSchoolOk(self, c.spellId, hitSchool) then
			c.claims = (c.claims or 0) + 1
			return c.spellId, c.unit
		end
	end
	return nil
end

-- Non-mutating variant: does a school-matching pet cast record sit
-- unclaimed in the window? Used by the disambiguation picker — a pending
-- record is PROOF a pet spell is in flight, which outranks inferred dot
-- attribution for the next school-matching wound.
local function pendingPetCast(self, t, window, hitSchool)
	local casts = self._petCasts
	if type(casts) ~= "table" then return nil end
	local w = window or 1.5
	for i = #casts, 1, -1 do
		local c = casts[i]
		local age = t - (c.at or 0)
		if age > w then break end
		local maxClaims = PET_CAST_MAX_CLAIMS
		if ZSBT.ClassDB and ZSBT.ClassDB.PetCastBudget then
			maxClaims = ZSBT.ClassDB.PetCastBudget(c.spellId) or maxClaims
		end
		if age >= 0
			and (c.claims or 0) < maxClaims
			and not isPlayerSpellId(c.spellId)
			and (not ZSBT.IsSafeNumber or ZSBT.IsSafeNumber(c.spellId))
			and castSchoolOk(self, c.spellId, hitSchool) then
			return c.spellId, c.unit
		end
	end
	return nil
end

-- Spell facts read from the spell's own description (adapted from
-- Forever Combat Text, MIT).
-- C_Spell.GetSpellDescription is plain for your spells even on secret-
-- value clients, so a cast knows its own damage school from the moment
-- it is first parsed — no confirmed-hit bootstrap needed. The full FCT
-- school table covers composite names (Shadowflame 36, Chaos 127) so
-- warlock/hunter tooltips resolve exactly.
local SPELL_SCHOOL_WORDS = {
	physical = 1, holy = 2, fire = 4, nature = 8,
	frost = 16, shadow = 32, arcane = 64,
	holystrike = 3, flamestrike = 5, stormstrike = 9,
	froststrike = 17, shadowstrike = 33, spellstrike = 65,
	holyfire = 6, holystorm = 10, holyfrost = 18,
	shadowholy = 34, divine = 66,
	firestorm = 12, frostfire = 20, shadowflame = 36, spellfire = 68,
	froststorm = 24, shadowstorm = 40, spellstorm = 72,
	shadowfrost = 48, spellfrost = 80, spellshadow = 96,
	elemental = 28, cosmic = 106, chromatic = 124, magic = 126, chaos = 127,
	radiant = 6, twilight = 34, plague = 40, astral = 72, volcanic = 12,
}
local spellFactsCache = {}
local function SpellFacts(spellId)
	-- type() is safe on secrets ("number"), but indexing a table with a
	-- secret key throws — IsSafeNumber is the real gate.
	if type(spellId) ~= "number" then return nil end
	if ZSBT.IsSafeNumber and not ZSBT.IsSafeNumber(spellId) then return nil end
	local c = spellFactsCache[spellId]
	if c ~= nil then return c or nil end
	local facts
	local locale = GetLocale and GetLocale()
	if (locale == "enUS" or locale == "enGB")
		and C_Spell and type(C_Spell.GetSpellDescription) == "function" then
		local ok, text = pcall(C_Spell.GetSpellDescription, spellId)
		if ok and ZSBT.IsSafeString and ZSBT.IsSafeString(text) and text ~= "" then
			local lower = text:lower()
			local school, multi, harms = nil, false, false
			if not (lower:find("^heals") or lower:find("heals %d") or lower:find("restores %d") or lower:find("converts %d+ health")) then
				if lower:find("%d+ damage") then harms = true end
				for word in lower:gmatch("(%a+) damage") do
					local s = SPELL_SCHOOL_WORDS[word]
					if s then
						harms = true
						if school and school ~= s then multi = true end
						school = school or s
					end
				end
				if not school and (lower:find("weapon damage", 1, true) or lower:find("melee damage", 1, true)
					or lower:find("ranged damage", 1, true) or lower:find("fires several missiles", 1, true)) then
					school, harms = 1, true
				end
				facts = { school = (not multi) and school or nil, damages = harms }
			else
				facts = { damages = false }
			end
		elseif type(C_Spell.RequestLoadSpellData) == "function" then
			pcall(C_Spell.RequestLoadSpellData, spellId)
		end
	end
	if facts then spellFactsCache[spellId] = facts end
	return facts
end

-- A cast may only claim a hit it can plausibly have made:
-- * a spell whose own tooltip deals no damage claims nothing;
-- * a tooltip-declared school is authoritative (FCT catalog facts);
-- * a school learned from confirmed hits gates identically;
-- * unknown stays permissive (a guess, like FCT).
-- This is what stops "Consecration shown as Shadow Bolt".
castSchoolOk = function(self, spellId, school)
	if type(spellId) ~= "number" then return true end
	-- Secret spellIds can't index or compare — permissive, like unknown.
	if ZSBT.IsSafeNumber and not ZSBT.IsSafeNumber(spellId) then return true end
	-- Forever: UNIT_COMBAT's wound school is unreliable (paladin Holy
	-- hits arrive as 32), so it can't veto a *player* cast record's own
	-- school — age-recency matching stays and the palette line proves
	-- ownership. Pet records keep the check: their ids aren't player
	-- spells, and school is all that stops an imp's Firebolt record
	-- from claiming a melee wound.
	if ZSBT.ClassDB and ZSBT.ClassDB.IsForever and ZSBT.ClassDB.IsForever()
		and isPlayerSpellId(spellId) then
		return true
	end
	local facts = SpellFacts(spellId)
	if facts and facts.damages == false then return false end
	if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school)) then return true end
	if facts and type(facts.school) == "number" then
		return spellSchoolFits(facts.school, school)
	end
	-- Module-declared school gates next (mod.dots/channels): verified
	-- data for exactly the spells whose tooltips omit a damage school.
	if ZSBT.ClassDB and ZSBT.ClassDB.DeclaredSchoolFits then
		local fits = ZSBT.ClassDB.DeclaredSchoolFits(spellId, school)
		if fits ~= nil then return fits end
	end
	return spellSchoolFits(self._learnedSpellSchool[spellId], school)
end

-- Forward parsed events to the configured sink callback.
-- /zsbt audit: one line per attributed combat event, written to
-- prof.auditLog in SavedVariables. Fields mirror what the combat-log
-- filter shows (name/school/crit/amount-when-safe) plus ZSBT's own
-- attribution (sid, src bucket) so sessions can be diffed line-by-line.
local AUDIT_TYPES = {
	OUTGOING_DAMAGE_COMBAT = true,
	PET_DAMAGE_COMBAT = true,
	OUTGOING_MISS_COMBAT = true,
	OUTGOING_HEAL_COMBAT = true,
	PET_HEAL_LOG = true,
	PET_INCOMING_DAMAGE_COMBAT = true,
}
local function auditEmit(eventType, payload)
	if ZSBT._auditTrace ~= true then return end
	if AUDIT_TYPES[eventType] ~= true then return end
	local zbt = ZSBT.ZBattleText
	if zbt and zbt.AuditDamageEvent then
		zbt:AuditDamageEvent(eventType, payload)
	end
end

-- Raw audit note for funnel tracing (candidates, gate drops). Self-gates
-- on _auditTrace via ZB:Audit.
local function auditNote(msg)
	if ZSBT._auditTrace ~= true then return end
	local zbt = ZSBT.ZBattleText
	if zbt and zbt.Audit then zbt:Audit(msg) end
end

local function emit(eventType, payload)
	-- ZBattleText ownership veto: when the combat-log filter is trusted,
	-- ambiguous outgoing damage must be corroborated by a palette line.
	-- Untrusted => OfferOutgoing returns true and nothing changes.
	if eventType == "OUTGOING_DAMAGE_COMBAT" and payload then
		-- Melee anchor for proc riders: a school-1 wound that actually
		-- EMITTED as ours (named claim or auto emit) proves a weapon
		-- attack happened. Stamping at emit time — not wound arrival —
		-- means a co-attacker's bare swing can never feed the anchor
		-- during a contested lapse; foreign wounds never get this far.
		if payload.schoolMask == 1
			and (payload.isAuto == true or payload.spellId ~= nil) then
			Collector._lastPhysWoundAt = payload.timestamp or now()
		end
		-- Last shot for the player's own cast before pet-claiming: nuke
		-- hits with travel time (HoG/Implosion/Demonbolt) can miss the
		-- 0.85s candidate window upstream and would otherwise die
		-- unattributed in the pet bucket. A still-queued record means no
		-- hit has claimed this cast yet, so consuming it here is always
		-- that cast's first legitimate outcome.
		if payload.spellId == nil and payload.schoolMask ~= 1 and payload._petRoute ~= false then
			local mc = consumeBestPendingCast(Collector, payload.timestamp or now(), nil, 2.0, true, payload.schoolMask)
			if mc and mc.spellId ~= nil then
				payload.spellId = mc.spellId
				payload._sidLearn = true
			end
		end
		-- Unattributed non-physical hit + a recent friendly/minion cast =
		-- likely temporary-pet damage. Flag it here so EVERY emit path
		-- (bucket flush, physical direct, auto fallback) can deliver as
		-- pet damage after the veto proves ownership. Physical school-1
		-- hits stay generic: melee is indistinguishable from autos.
		if payload.spellId == nil and payload.schoolMask ~= 1 and payload._petRoute ~= false then
			-- Consume-style match: newest school-fitting pet cast claims the
			-- hit (budgeted), and the stamp counts as trusted provenance.
			local psid = consumePetCast(Collector, payload.timestamp or now(), 1.2, payload.schoolMask)
			local resolved = nil
			if psid == nil and ZSBT.ClassDB and ZSBT.ClassDB.ResolvePetSpellId then
				-- Guardian casts are invisible; the class module names the
				-- hit only when one active guardian spell fits the school.
				psid = ZSBT.ClassDB.ResolvePetSpellId(Collector, payload.schoolMask, payload.timestamp or now())
				resolved = psid ~= nil
			end
			if psid ~= nil then
				payload._petRoute = true
				payload.petSpellId = psid
				payload._petSidLearn = (not resolved) or nil
				payload.petEvidence = resolved and "resolve" or "cast"
				payload.petBucket = "summons"
			end
		end
		-- Signature claim: an unattributed hit inside a trigger window may
		-- be a linked proc's wound (book correlations). Runs after real
		-- cast evidence and pet claims — both are stronger provenance.
		if payload.spellId == nil and payload.petSpellId == nil
			and payload.schoolMask ~= 1 and payload._petRoute ~= false then
			local ssid, trig = claimSignature(Collector, payload.timestamp or now(), payload.schoolMask)
			if ssid ~= nil then
				payload.spellId = ssid
				payload._sigClaim = true
				-- The trigger cast that seeded this claim (Shadow Bolt
				-- for Secrets of the Coven). Display metadata only —
				-- attribution evidence stays keyed to the proc sid.
				payload.baseSpellId = trig
			end
		end
		-- Class school whitelist: after every attribution attempt, a still-
		-- unattributed hit carrying a school the active module cannot
		-- produce is provably foreign (follower/party damage on a shared
		-- target). Kill it here so it can neither emit nor queue for a
		-- palette line. Autos are exempt (school-1 by definition) and an
		-- unverifiable mask passes — the veto needs certainty, not hunches.
		-- Forever is exempt: UNIT_COMBAT reports bogus schools there
		-- (paladin Seal/Judgement hits arrive as school-32), so the mask
		-- cannot prove foreignness — line pairing stays the real gate.
		if payload.spellId == nil and payload.petSpellId == nil
			and payload._petRoute ~= true and payload.isAuto ~= true
			and not (ZSBT.ClassDB and ZSBT.ClassDB.IsForever
				and ZSBT.ClassDB.IsForever())
			and ZSBT.ClassDB and ZSBT.ClassDB.SchoolAllowed
			and not ZSBT.ClassDB.SchoolAllowed(payload.schoolMask) then
			-- Whitelists can't predeclare proc/trinket/hero-talent schools
			-- (stub classes run on book-derived masks only), and feed lines
			-- routinely lag the wound past intake. Instead of killing the
			-- hit here, tag it and let pairing decide: a claimed MINE line
			-- is stronger proof than any list, and an off-whitelist wound
			-- that never meets a line dies at flush — foreign as before.
			-- A non-auto wound can never own a melee/ranged line (autos
			-- are school-1, shots are whitelisted) — letting an
			-- off-whitelist wound borrow a white line is provably foreign
			-- (druid arcane claimed kind=melee on a co-attacker dummy).
			local lineProof = nil
			local zbtS = ZSBT.ZBattleText
			if zbtS and zbtS.PeekDamageLine then
				lineProof = zbtS:PeekDamageLine(payload.timestamp or now(), 0.30,
					{ direct = true, tick = true, shield = true })
			end
			-- Sustained-foreign horizon: autoContested lapses between
			-- spaced foreign ticks, so each wound evaluated alone could
			-- steal a line mid-stream. A prior off-whitelist wound inside
			-- the horizon means a foreign stream is active — kill every
			-- follower. A lone trinket proc still gets its line chance.
			local tW = payload.timestamp or now()
			local fsPrior = Collector and Collector._fschoolUntil
			if lineProof then
				-- A MINE line proves "our feed reported damage near t",
				-- not "THIS wound is ours" — lines carry no school/sid.
				-- With a second attacker recently armed, an off-whitelist
				-- wound borrowing a nearby own-line is indistinguishable
				-- from a trinket proc: kill it rather than display foreign
				-- damage. Uncontested, the bypass stands (trinkets).
				local contUntil = Collector and Collector._autoContestUntil
				if (type(contUntil) == "number" and contUntil > tW)
					or (type(fsPrior) == "number" and fsPrior > tW) then
					payload._foreignSchool = true
					auditNote(("AUDSCH defer-contested school=%s crit=%s"):format(
						tostring(payload.schoolMask), tostring(payload.isCrit == true)))
				else
					auditNote(("AUDSCH bypass=line school=%s kind=%s"):format(
						tostring(payload.schoolMask), tostring(lineProof)))
				end
			else
				payload._foreignSchool = true
				auditNote(("AUDSCH defer school=%s crit=%s"):format(
					tostring(payload.schoolMask), tostring(payload.isCrit == true)))
			end
			if Collector then
				Collector._fschoolUntil = tW + 2.5
				Collector._fschoolCount = (Collector._fschoolCount or 0) + 1
				payload._fschoolSeq = Collector._fschoolCount
			end
		end
		-- PLAYER_SWING provenance: an unattributed school-1 hit inside the
		-- swing window is backed by the client's own per-swing report —
		-- stamp it so the veto treats it as proven (fast melee-line claim,
		-- one retry on a lagging line) instead of a generic tier-2 guess.
		if payload.spellId == nil and payload.schoolMask == 1
			and Collector._swingSupported == true
			and anySwingRecent(Collector, payload.timestamp or now()) then
			payload._swingProven = true
		end
	end
	-- Strict toggle also covers direct pet-path emits: PET_DAMAGE_COMBAT
	-- bypasses the veto queue entirely, so without this check unnamed pet
	-- hits would display even with hideUnattributed on.
	if eventType == "PET_DAMAGE_COMBAT" and payload
		and payload.spellId == nil and payload.petSpellId == nil then
		local prof = ZSBT.db and ZSBT.db.profile
		local strictProof = ZSBT.Core and ZSBT.Core.IsRequireProofEnabled
			and ZSBT.Core:IsRequireProofEnabled() == true
		if strictProof or (prof and type(prof.classModule) == "table" and prof.classModule.hideUnattributed == true) then
			auditNote(("AUDSUPP ht=%.3f school=%s crit=%s src=pet"):format(
				tonumber(payload.timestamp) or 0, tostring(payload.schoolMask),
				tostring(payload.isCrit == true)))
			return
		end
	end
	if eventType == "OUTGOING_DAMAGE_COMBAT"
		and ZSBT.ZBattleText and ZSBT.ZBattleText.OfferOutgoing
		and not ZSBT.ZBattleText:OfferOutgoing(payload) then
		return
	end
	-- OfferOutgoing sets _vetoConfirmed when a palette line proved
	-- ownership (fast match): teach the spell's school for future stamps —
	-- but only when the sid came from a consumed cast record.
	if eventType == "OUTGOING_DAMAGE_COMBAT" and payload and payload._vetoConfirmed == true then
		local learnSid = payload.spellId or payload.petSpellId
		local learnTrust = (payload.spellId ~= nil and payload._sidLearn == true)
			or (payload.spellId == nil and payload.petSpellId ~= nil and payload._petSidLearn == true)
		Collector:LearnConfirmedSchool(learnSid, payload.schoolMask, learnTrust)
	end
	-- Veto-approved unattributed hits that look like minion/pet damage
	-- deliver as PET_DAMAGE_COMBAT so they get pet styling. The swap
	-- happens only after OfferOutgoing has proven ownership (or the
	-- filter is untrusted, where behaviour is unchanged heuristics).
	local sinkType = eventType
	if eventType == "OUTGOING_DAMAGE_COMBAT" and payload and payload._petRoute == true then
		-- Two cases keep this payload out of pet scroll:
		--  1. A player spellId landed after the pet-route guess (deferred
		--     retry dual-claim) — a hit wearing a real cast's name
		--     belongs in outgoing, not pet scroll.
		--  2. The school is provably impossible for any class minion —
		--     the wound is foreign and emits as generic instead.
		local petSchoolForeign = ZSBT.ClassDB and ZSBT.ClassDB.PetSchoolAllowed
			and ZSBT.ClassDB.PetSchoolAllowed(payload.schoolMask) == false
		if payload.spellId ~= nil or petSchoolForeign then
			payload._petRoute = nil
			local zbtX = ZSBT.ZBattleText
			if zbtX and zbtX.FileLog then
				zbtX:FileLog(("PET_ROUTE_STRIP sid=%s school=%s"):format(
					tostring(payload.spellId), tostring(payload.schoolMask)))
			end
		else
			sinkType = "PET_DAMAGE_COMBAT"
			local zbt3 = ZSBT.ZBattleText
			if zbt3 and zbt3.FileLog then
				zbt3:FileLog(("PET_ROUTE petSid=%s school=%s"):format(tostring(payload.petSpellId), tostring(payload.schoolMask)))
			end
		end
	end
	-- Empower-pair display: the claimed sid may be a linked proc of a
	-- recent trigger cast regardless of which path claimed it (own cast
	-- record, pair twin, or sig). Stamp the trigger so the render can
	-- show [cast icon][proc icon] — display metadata, not attribution.
	if sinkType == "OUTGOING_DAMAGE_COMBAT" and payload
		and payload.spellId ~= nil then
		if payload.baseSpellId == nil then
			local trig = sigBaseForTrigger(Collector, payload.timestamp or now(), payload.spellId)
			if trig ~= nil then payload.baseSpellId = trig end
		end
		-- Trigger-side pair: the claim is a plain cast sid — a linked
		-- proc's active buff proves the empowerment, so show its icon
		-- alongside the cast's.
		if payload.baseSpellId == nil and payload.empowerId == nil then
			local proc = sigEmpowerForTrigger(Collector, payload.timestamp or now(), payload.spellId)
			if proc ~= nil then payload.empowerId = proc end
		end
	end
	if Collector._sink then
		auditEmit(sinkType, payload)
		Collector._sink(sinkType, payload)
		-- Hit->display latency for the ucdrop trace: timestamp is the
		-- UNIT_COMBAT hit time, so dly captures veto defer + merge +
		-- dispatch cost. Anything above ~0.5s is pipeline, not scroll anim.
		if ZSBT.ZBattleText and ZSBT.ZBattleText.FileLog and payload and payload.timestamp then
			ZSBT.ZBattleText:FileLog(("SHOW %s sid=%s dly=%.2f"):format(sinkType, tostring(payload.spellId), now() - payload.timestamp))
		end
	end
end

local function OutDbgLevel()
	local lvl = 0
	local Addon = ZSBT and ZSBT.Addon
	if Addon and Addon.GetDebugLevel then
		lvl = tonumber(Addon:GetDebugLevel("outgoing")) or 0
	else
		lvl = (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (tonumber(ZSBT.db.profile.diagnostics.debugLevel) or 0)) or 0
	end
	if ZSBT._ucDropTrace == true and lvl < 4 then lvl = 4 end
	return lvl
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
	local Addon = ZSBT and ZSBT.Addon
	if Addon and Addon.Dbg then
		Addon:Dbg("outgoing", 4, dbgSafe(msg))
		return
	end
	if Addon and Addon.Print then
		Addon:Print(dbgSafe(msg))
	end
end

-- Pipeline drop tracer: every silent return on the unattributed
-- target-WOUND path prints UC_DROP so we can see exactly where hits die.
local function dbgDrop(reason, tok, school)
	auditNote(("AUDD reason=%s token=%s school=%s"):format(
		tostring(reason), dbgSafe(tok), dbgSafe(school)))
	if OutDbgLevel() >= 4 or ZSBT._ucDropTrace == true then
		ECPrint(("UC_DROP reason=%s token=%s school=%s"):format(reason, dbgSafe(tok), dbgSafe(school)))
		local z = ZSBT.ZBattleText
		if z and z.FileLog then
			z:FileLog(("UC_DROP reason=%s token=%s school=%s"):format(tostring(reason), dbgSafe(tok), dbgSafe(school)))
		end
	end
end

-- True when the ZBattleText ownership veto can decide emits. Ambiguous
-- candidates (pet-minion hits, shared-target damage) may then flow to
-- emit() where OfferOutgoing pairs them with a palette line instead of
-- dying in the heuristic gates.
local function zbtVetoActive()
	local z = ZSBT.ZBattleText
	if not (z and z.VetoActive) then return false end
	local ok, res = pcall(z.VetoActive, z)
	return ok and res == true
end


local function isCritChatMessage(msg)
	if type(msg) ~= "string" then return false end
	-- Use lowercase checks to catch: "crits", "critically", and "critical".
	local m = msg:lower()
	return (m:find("crits", 1, true) ~= nil)
		or (m:find("critically", 1, true) ~= nil)
		or (m:find("critical", 1, true) ~= nil)
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

local function isWarlockPlayer()
	if isPlayerClassTag and isPlayerClassTag("WARLOCK") then
		return true
	end
	if UnitClass then
		local okC, _, tag = pcall(UnitClass, "player")
		if okC and tag == "WARLOCK" then
			return true
		end
	end
	return false
end

local function isImpPet()
	-- Best-effort: creature family is localized but should contain "Imp" on enUS.
	-- When unavailable, return false and fall back to broader heuristics.
	if not UnitCreatureFamily then return false end
	local okF, fam = pcall(UnitCreatureFamily, "pet")
	if okF and type(fam) == "string" and fam ~= "" then
		return fam:find("Imp", 1, true) ~= nil
	end
	return false
end

local function flushBestOutgoing(self, token)
	if not self or not token then return end
	local bucket = self._bestOutgoingByToken and self._bestOutgoingByToken[token]
	if not bucket then return end
	self._bestOutgoingByToken[token] = nil
	local Addon = ZSBT and ZSBT.Addon
	local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("outgoing"))
		or ((ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0)) or 0)

	local pipeId = self._rawPipeCount + 1
	self._rawPipeCount = pipeId
	self._rawPipe[pipeId] = bucket.amount
	self._lastOutgoingCombatAt = bucket.timestamp
	self._lastOutgoingCombatTargetName = bucket.targetName
	if (tonumber(dl) or 0) >= 4 then
		ECPrint(("FLUSH_BEST token=%s spellId=%s amt=%s school=%s crit=%s cnt=%s max=%s second=%s")
			:format(dbgSafe(token), dbgSafe(bucket.spellId), dbgSafe(bucket.amount), dbgSafe(bucket.schoolMask), dbgSafe(bucket.isCrit), dbgSafe(bucket._seenCount), dbgSafe(bucket._seenMax), dbgSafe(bucket._seenSecond)))
	end

	local zbt = ZSBT.ZBattleText
	if zbt and zbt.FileLog then
		zbt:FileLog(("FLUSH sid=%s school=%s cnt=%s crit=%s"):format(tostring(bucket.spellId), tostring(bucket.schoolMask), tostring(bucket._seenCount), tostring(bucket.isCrit)))

	end
	auditNote(("AUDFLUSH sid=%s school=%s cnt=%s crit=%s"):format(
		tostring(bucket.spellId), tostring(bucket.schoolMask), tostring(bucket._seenCount), tostring(bucket.isCrit == true)))
	emit("OUTGOING_DAMAGE_COMBAT", {
		timestamp = bucket.timestamp,
		rawPipeId = pipeId,
		spellId = bucket.spellId,
		_sidLearn = bucket._sidLearn,
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
-- spellId -> damage school, learned ONLY from veto-confirmed (line-paired)
-- outgoing hits. Unconfirmed hits never teach (FCT Trust/Doubt): a foreign
-- hit that slips past heuristics cannot write a bad school.
Collector._learnedSpellSchool = Collector._learnedSpellSchool or {}
Collector._schoolVotes = Collector._schoolVotes or {}
local PENDING_CAST_WINDOW_SEC = 2.5
local PENDING_CAST_MAX = 12

-- Periodic (DoT) combat text attribution: COMBAT_TEXT_UPDATE periodic ticks can
-- arrive long after the original cast and after the pending cast entry has been
-- consumed. Track recently-cast spell IDs so periodic ticks can still be routed
-- to outgoing.
Collector._recentPeriodicSpellAt = Collector._recentPeriodicSpellAt or {}
local PERIODIC_OUTGOING_WINDOW_SEC = 30.0

-- Class-module dot resolution: name-primary via the active Classes/ module,
-- ids as fast path. Returns the dot entry table or nil.
local function dotEntryForSpellId(spellId)
	local ClassDB = ZSBT.ClassDB
	if ClassDB and ClassDB.DotEntry then
		return ClassDB.DotEntry(spellId)
	end
	return nil
end

-- Dot/channel entries may declare school as a scalar or as a set
-- (composite-school ticks — e.g. Voltaic Blaze burns report fire|nature
-- 12 while the impact is pure nature 8). nil decl = unconstrained;
-- returns true/false/nil matching DeclaredSchoolFits semantics.
local function dotEntrySchoolEq(decl, school)
	if decl == nil then return nil end
	if type(decl) == "table" then
		if decl[school] == true then return true end
		for _, m in ipairs(decl) do
			if m == school then return true end
		end
		return false
	end
	return decl == school
end

local function isKnownPeriodicSpellId(spellId)
	if type(spellId) ~= "number" then return false end
	local ClassDB = ZSBT.ClassDB
	if ClassDB and ClassDB.IsDotSpell then
		return ClassDB.IsDotSpell(spellId)
	end
	-- Fallback (class modules failed to load): legacy warlock-only ids.
	return spellId == 172 or spellId == 980 or spellId == 30108 or spellId == 27243
end

-- Record one dot application: recency + spell-level anchor + per-target
-- (name) and per-mob (GUID) records. Used by the dot-cast seeding path
-- and by applicator casts (Ravage -> Dreadful Wound). _dotAppliedAoe is
-- deliberately NOT written here — only genuine multi-mob applications
-- (aoe-flagged casts, aoe-marked applicators) earn that anchor.
local function seedDotApplication(self, spellId, at)
	self._recentPeriodicSpellAt[spellId] = at
	self._dotAppliedAt = self._dotAppliedAt or {}
	self._dotAppliedAt[spellId] = at
	-- Per-target application map for the disambiguation path:
	-- tab-dotting needs each mob's own phase anchor, and a wound on
	-- the current target must not claim a dot applied elsewhere.
	local tgtName = safeUnitName("target")
	-- IsSafeString: safeUnitName returns secrets as-is for
	-- SetText; they can't be compared or used as map keys.
	if ZSBT.IsSafeString and ZSBT.IsSafeString(tgtName) then
		local map = self._dotAppliedTarget
		if not map then map = {} ; self._dotAppliedTarget = map end
		local sm = map[spellId]
		if not sm then sm = {} ; map[spellId] = sm end
		sm[tgtName] = at
	end
	-- GUID-keyed mirror for nameplate lookup: off-target DoT
	-- attribution needs a collision-free mob identity (two
	-- same-named mobs each holding a dot).
	if UnitGUID then
		local okG, g = pcall(UnitGUID, "target")
		if okG and ZSBT.IsSafeString and ZSBT.IsSafeString(g) then
			local gm = self._dotAppliedGuid
			if not gm then gm = {} ; self._dotAppliedGuid = gm end
			local sm = gm[spellId]
			if not sm then sm = {} ; gm[spellId] = sm end
			sm[g] = at
		end
	end
end

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
		return spellId == 1680 or spellId == 190411 or spellId == 199658
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

-- School-aware variant of getMostRecentPeriodicSpellId: a wound may only
-- claim a periodic sid whose declared school accepts it (module entry,
-- else the spellbook record). Without the gate the most-recent seed wins
-- regardless of school — Flame Shock was observed claiming school-1
-- melee swings and school-5 totem hits. No declared school means nothing
-- to disprove, not proof: stay permissive so undeclared dots still claim.
local function dotSchoolFitsWound(spellId, school)
	local entry = dotEntryForSpellId(spellId)
	local decl = entry and entry.school
	if decl == nil then
		local sb = ZSBT.Spellbook
		local rec = sb and sb.Entry and sb:Entry(spellId) or nil
		decl = rec and rec.school
	end
	if decl == nil then return true end
	return dotEntrySchoolEq(decl, school) == true
end

local function getMostRecentPeriodicSpellIdForSchool(self, tNow, school)
	if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school)) then
		return getMostRecentPeriodicSpellId(self, tNow)
	end
	local m = self and self._recentPeriodicSpellAt
	if type(m) ~= "table" then return nil end
	local bestId, bestAt
	for sid, at in pairs(m) do
		if type(sid) == "number" and type(at) == "number" then
			local age = tNow - at
			if age >= 0 and age <= PERIODIC_OUTGOING_WINDOW_SEC then
				if ((not bestAt) or at > bestAt)
					and dotSchoolFitsWound(sid, school) then
					bestAt = at
					bestId = sid
				end
			end
		end
	end
	return bestId
end

-- The same periodic tick can arrive twice in one frame (UNIT_COMBAT fires for
-- both the "target" token and the nameplate token remapped to target). Dedup
-- DOT emits per spellId within a short window so ticks don't double-display.
local function isDuplicateDotEmit(self, t, spellId)
	local lastAt = self._lastDotEmitAt or 0
	if self._lastDotEmitSpellId == spellId and (t - lastAt) >= 0 and (t - lastAt) < 0.35 then
		return true
	end
	self._lastDotEmitAt = t
	self._lastDotEmitSpellId = spellId
	return false
end


-- Per-dot tick cadence gate. Real DoT ticks arrive on a roughly fixed
-- interval; foreign players' hits on a shared target do not. Only
-- attribute a hit as a dot tick when it lands in a plausible tick slot:
-- either the first tick after application, or ~one interval after the
-- previously attributed tick. Returns false -> caller drops dotSpellId
-- and lets the normal attribution paths decide instead.
local DOT_DEFAULT_TICK_INTERVAL = 2.0
-- Prefer the spellbook-derived interval (the client's own description
-- states the tick rate); fall back to the module entry's, then default.
local function dotTickInterval(spellId, entry)
	local sb = ZSBT.Spellbook
	local rec = sb and sb.Entry and sb:Entry(spellId) or nil
	if rec and type(rec.interval) == "number" and rec.interval > 0 then
		return rec.interval
	end
	if entry and type(entry.interval) == "number" and entry.interval > 0 then
		return entry.interval
	end
	-- Channel-owned sids: the module's channel interval is the tick period
	-- (era drains tick at 1s; a 2.0 default would reject real ticks).
	if ZSBT.ClassDB and ZSBT.ClassDB.ChannelMatch then
		local ch = ZSBT.ClassDB.ChannelMatch(spellId)
		if ch and type(ch.interval) == "number" and ch.interval > 0 then
			return ch.interval
		end
	end
	return DOT_DEFAULT_TICK_INTERVAL
end

local function dotCadenceOk(self, t, spellId)
	local entry = dotEntryForSpellId(spellId)
	local iv = dotTickInterval(spellId, entry)
	local st = self._dotTickState
	if type(st) ~= "table" then
		st = {}
		self._dotTickState = st
	end
	local rec = st[spellId]
	local lastAt = (type(rec) == "table") and rec.lastAt or nil
	if type(lastAt) == "number" then
		local dt = t - lastAt
		if dt >= (iv * 0.55) and dt <= (iv * 2.1) then
			rec.lastAt = t
			return true
		end
		-- Same-wave multi-target: AoE spread (Lava Lash -> Flame Shock on 5,
		-- Ascendance spread) applies the debuff to every target at once, so
		-- all their ticks land in one burst. A wound within ~150ms of a
		-- claimed tick is another target's copy of the same wave, not a
		-- foreign interloper — claim it or 4/5 of every wave goes generic.
		if dt >= 0 and dt <= 0.15 then
			rec.lastAt = t
			return true
		end
		-- Stale record (dot expired / long gap): treat as first-tick below.
		if dt > (iv * 3.5) then
			rec = nil
			st[spellId] = nil
		end
	end
	-- First observed tick: must be plausibly after application. _dotAppliedAt
	-- is stamped on cast only (tick emits refresh _recentPeriodicSpellAt, so
	-- it cannot be used for this).
	local appliedAt = self._dotAppliedAt and self._dotAppliedAt[spellId]
	if type(appliedAt) == "number" then
		local dt = t - appliedAt
		if dt >= (iv * 0.4) and dt <= (iv * 3.0) then
			st[spellId] = { lastAt = t }
			return true
		end
		return false
	end
	-- No application record (legacy state): allow once and start cadence.
	st[spellId] = { lastAt = t }
	return true
end

-- Non-mutating cadence prediction for multi-dot disambiguation: era dot
-- ticks are phase-locked to application — tick N lands at appliedAt+N*iv
-- with only latency jitter. A wound is a candidate tick for this sid iff
-- its time sits near a multiple of that dot's interval. Two same-school
-- dots only collide where their phases coincide (rare), and any wound
-- matching both stays generic — never wrong beats sometimes named.
local function dotCadencePredict(self, t, spellId, appliedAtOverride)
	local entry = dotEntryForSpellId(spellId)
	local st = self._dotTickState
	local rec = (type(st) == "table") and st[spellId] or nil
	-- Learned period (confirmed tick gaps) outranks book/module/2.0 —
	-- the model adapts to what this client actually schedules.
	local prof = ZSBT.db and ZSBT.db.profile
	local learnedPer = (rec and type(rec.period) == "number" and rec.period > 0 and rec.period)
		or (prof and prof.learnedDotPeriods and prof.learnedDotPeriods[spellId])
	local iv = learnedPer or dotTickInterval(spellId, entry)
	local jitter = 0.45
	-- Three timing anchors, any is sufficient: phase-lock from the cast
	-- (per-target when a name key exists), OR distance from the last
	-- confirmed tick, OR the predicted next beat — each real tick
	-- re-locks the schedule instead of letting drift accumulate.
	local appliedAt = appliedAtOverride
		or (self._dotAppliedAt and self._dotAppliedAt[spellId])
	if type(appliedAt) == "number" and t >= appliedAt then
		local phase = (t - appliedAt) % iv
		if phase <= jitter or phase >= (iv - jitter) then
			return true
		end
	end
	local nextAt = (type(rec) == "table") and rec.nextAt or nil
	if type(nextAt) == "number" and math.abs(t - nextAt) <= jitter then
		return true
	end
	local lastAt = (type(rec) == "table") and rec.lastAt or nil
	if type(lastAt) == "number" then
		local dt = t - lastAt
		return dt >= (iv * 0.7) and dt <= (iv * 1.45)
	end
	return false -- no timing anchor at all: cannot prove cadence
end

local HOT_DEFAULT_TICK_INTERVAL = 3.0
local HOT_PHASE_JITTER = 0.5
local HOT_LINE_WINDOW = 0.30
-- Alias reports of one heal (same UC re-fired on target + softfriend +
-- partyN tokens) share a UC timestamp; distinct heals to the same unit
-- are spaced far wider than this.
local HEAL_ALIAS_WINDOW = 0.12

-- Unit identity for alias dedup: GUID when it resolves, unit name as
-- fallback (soft-target tokens may not expose a GUID). Either matching
-- the last claim's key counts as the same unit.
local function healUnitKeys(unit)
	local guid, name = nil, nil
	if UnitGUID then
		local okG, g = pcall(UnitGUID, unit)
		if okG and ZSBT.IsSafeString and ZSBT.IsSafeString(g) then guid = g end
	end
	if safeUnitName then
		local n = safeUnitName(unit)
		-- KString names are unique objects per token — they can never
		-- dedup-match, so only safe strings are usable as keys.
		if n ~= nil and ZSBT.IsSafeString and ZSBT.IsSafeString(n) then name = n end
	end
	return guid, name
end

-- Per-unit claim maps: alias claims for different units interleave (a
-- hot tick on party2 between a dummy heal's target+softfriend reports),
-- so a single last-claim slot gets clobbered and misses real dups.
local function isHealAliasDup(self, unit, t)
	if type(t) ~= "number" then return false end
	local guid, name = healUnitKeys(unit)
	local g = self._healClaimByGuid
	if guid ~= nil and g ~= nil then
		local la = g[guid]
		if type(la) == "number" and math.abs(t - la) <= HEAL_ALIAS_WINDOW then
			return true
		end
	end
	local n = self._healClaimByName
	if name ~= nil and n ~= nil then
		local la = n[name]
		if type(la) == "number" and math.abs(t - la) <= HEAL_ALIAS_WINDOW then
			return true
		end
	end
	return false
end

local function noteHealClaim(self, unit, t)
	local guid, name = healUnitKeys(unit)
	local g = self._healClaimByGuid
	if g == nil then g = {} ; self._healClaimByGuid = g end
	local n = self._healClaimByName
	if n == nil then n = {} ; self._healClaimByName = n end
	if guid ~= nil then g[guid] = t end
	n[name or unit] = t
end

-- sid=0 "proven but unnameable" emits are the moduleless fallback:
-- classes without a module (Forever-era paladin, etc.) need them or
-- their heals vanish entirely. With a module active every real
-- outgoing heal resolves a name through the cast window or armed hot
-- records, so an unnamed emit means a foreign UC consumed one of our
-- lines or a tick slipped naming — rendering it bare is the phantom
-- number users see scrolling next to the real ticks.
local function unnamedHealsAllowed()
	return not (ZSBT.ClassDB and ZSBT.ClassDB.ActiveModule
		and ZSBT.ClassDB.ActiveModule())
end

-- Outgoing heal attribution (UNIT_COMBAT HEAL on a healed unit's token —
-- partyN/raidN/focus/targettarget/target — carries no source unit).
-- Ownership proof is a filtered combat-log line: the ZBattleText filter
-- is source-restricted to MINE+MY_PET, so a classified "hot" or "heal"
-- line near the UC event proves a heal of OURS just happened. Aura reads
-- are unavailable on Retail (auras are secret) so no aura gate exists
-- here — the line IS the gate. Follower/NPC heals produce no filtered
-- line at all, so they can never pair.
--
-- Returns: sid, periodic, why —
--   sid ~= nil : proven ours, named spell (emit with spellId=sid)
--   sid == 0   : proven ours, unnamed (emit bare)
--   nil, why   : no proof — caller drops or queues for deferred pairing
--
-- COMBAT_LOG_MESSAGE and UNIT_COMBAT arrive in either order, the same
-- race OfferOutgoing solves for damage by deferring: a UC event that
-- finds no line is queued briefly and re-paired when its line lands
-- (see queuePendingHotHeal / zb._healLineHook below).
--
-- Dedup is two-layered: a successful claim is recorded per unit
-- (HEAL_ALIAS_WINDOW) so aliased re-reports collapse, and line
-- consumption keeps unmatched repeats from finding a second line.
local function matchOutgoingHotTick(self, unit, t)
	-- A heal landing on the player is incoming, not outgoing — the
	-- unit == "player" path already renders it. Tokens that resolve to
	-- self (targettarget while the mob targets us) re-report the same
	-- heal and would double-render it as ours.
	if UnitIsUnit then
		local okU, res = pcall(UnitIsUnit, unit, "player")
		if okU then
			local okC, eq = pcall(function() return res == true end)
			if okC and eq == true then return nil, nil, "self" end
		end
	end
	-- An attackable unit cannot receive the player's healing; if it
	-- reports a HEAL it is the mob's own regen, not outgoing.
	if UnitCanAttack then
		local okH, h = pcall(UnitCanAttack, "player", unit)
		if okH then
			local okC, eq = pcall(function() return h == true end)
			if okC and eq == true then return nil, nil, "attackable" end
		end
	end
	local zb = ZSBT.ZBattleText
	if not (zb and zb.PeekHealLine and zb.TakeHealLine) then
		return nil, nil, "no_feed"
	end
	-- Alias dedup: one heal re-reports under every token resolving to
	-- the healed unit (target AND softfriend AND partyN in one frame).
	-- Line consumption alone cannot collapse it — when direct+hot lines
	-- are buffered together each alias steals a different line and the
	-- same heal renders twice. A claim already recorded for the same
	-- unit within the alias window means this UC re-reports a rendered
	-- heal.
	-- Peek before consuming: the line's timestamp is the canonical
	-- identity of the heal it proves. Retail reports ONE heal on the
	-- SAME token twice up to ~0.2s apart — the readable action=HEAL
	-- report, then a tainted amount twin — beyond the UC-time alias
	-- window, but the line the twin steals still carries the original
	-- heal's time. Dedup against claims by line time when a line is
	-- buffered, else by UC time.
	local peekKind, peekAt = zb:PeekHealLine(t, HOT_LINE_WINDOW, nil)
	if isHealAliasDup(self, unit, peekAt or t) then
		return nil, nil, "dup"
	end
	local nearKind = zb:TakeHealLine(t, HOT_LINE_WINDOW, nil)
	if nearKind == nil then
		return nil, nil, "noline"
	end
	local claimAt = peekAt or t
	-- A "heal" line is a direct heal of ours (SPELL_HEAL). Name it via
	-- the cast window when a recent player cast exists.
	if nearKind == "heal" then
		local dsid = 0
		if self._lastPlayerSpellAt and self._lastPlayerSpellId then
			local age = t - self._lastPlayerSpellAt
			if age >= 0 and age <= 1.5 then
				dsid = self._lastPlayerSpellId
			end
		end
		if dsid == 0 and not unnamedHealsAllowed() then
			-- Suppressed, not emitted: do not poison the dedup map or
			-- the real UC for this heal drops against a phantom claim.
			return nil, nil, "unnamed"
		end
		noteHealClaim(self, unit, claimAt)
		return dsid, false, nil
	end
	-- "hot" line: a periodic heal of ours (SPELL_PERIODIC_HEAL).
	-- Naming: recs+cadence pick which armed hot ticked. Established ticks
	-- need interval spacing from the last claimed tick on this unit;
	-- first ticks must land on a phase boundary of the cast stamp.
	-- Tick state keys on the underlying unit, not the token: the same
	-- heal can report under aliased tokens (partyN AND targettarget when
	-- the mob targets that member) — GUID collapses them to one state.
	local recs = self._hotRecs
	if type(recs) ~= "table" or next(recs) == nil then
		if not unnamedHealsAllowed() then
			return nil, nil, "unnamed"
		end
		noteHealClaim(self, unit, claimAt)
		return 0, true, nil -- proven ours, nothing armed to name it
	end
	local key = unit
	if UnitGUID then
		local okG, g = pcall(UnitGUID, unit)
		if okG and ZSBT.IsSafeString and ZSBT.IsSafeString(g) then
			key = g
		end
	end
	local st = self._hotTickState
	if type(st) ~= "table" then st = {} ; self._hotTickState = st end
	local us = st[key]
	if type(us) ~= "table" then us = {} ; st[key] = us end
	local prof = ZSBT.db and ZSBT.db.profile
	local learnedPer = type(prof) == "table" and prof.learnedHotPeriods or nil
	local cadSid, cadScore = nil, nil
	local firstSid, firstDelta = nil, nil
	local liveCount, singleSid = 0, nil
	for sid, rec in pairs(recs) do
		if t > (rec.expiresAt or 0) then
			recs[sid] = nil
			us[sid] = nil
		else
			liveCount = liveCount + 1
			singleSid = sid
			local ts = us[sid]
			-- Learned period (confirmed tick gaps this session, then
			-- persisted) outranks module/book intervals — the model
			-- adapts to what this client actually schedules, same as
			-- the DoT learner.
			local tsPer = (type(ts) == "table" and type(ts.period) == "number"
				and ts.period > 0) and ts.period or nil
			local iv = tsPer or (learnedPer and learnedPer[sid])
				or rec.interval or HOT_DEFAULT_TICK_INTERVAL
			local lastAt = (type(ts) == "table") and ts.lastAt or nil
			if type(lastAt) == "number" then
				local dt = t - lastAt
				if dt >= (iv * 0.55) and dt <= (iv * 2.5) then
					local score = math.abs(dt - iv)
					if cadScore == nil or score < cadScore then
						cadSid, cadScore = sid, score
					end
				end
			else
				local applyAt = rec.appliedAt
				if type(applyAt) == "number" and t >= applyAt then
					local phase = (t - applyAt) % iv
					local delta = math.min(phase, iv - phase)
					if delta <= HOT_PHASE_JITTER
						and (firstDelta == nil or delta < firstDelta) then
						firstSid, firstDelta = sid, delta
					end
				end
			end
		end
	end
	if next(recs) == nil then
		self._hotRecs = nil
		self._hotTickState = nil
	end
	-- Exactly one live hot + a proven periodic-heal line: the tick IS
	-- that spell even when cadence/phase misses (a wrong seeded interval
	-- would otherwise silently drop every tick).
	local sid = cadSid or firstSid
	if sid == nil and liveCount == 1 then sid = singleSid end
	if sid == nil then
		if not unnamedHealsAllowed() then
			return nil, nil, "unnamed"
		end
		noteHealClaim(self, unit, claimAt)
		return 0, true, nil -- proven ours, unnamed
	end
	local prev = us[sid]
	local period = nil
	if type(prev) == "table" and type(prev.lastAt) == "number" then
		local gap = t - prev.lastAt
		if gap > 0.3 and gap < 6 then
			period = (type(prev.period) == "number" and prev.period > 0)
				and (prev.period * 0.6 + gap * 0.4) or gap
			if prof then
				prof.learnedHotPeriods = prof.learnedHotPeriods or {}
				prof.learnedHotPeriods[sid] = period
			end
		elseif type(prev.period) == "number" then
			period = prev.period
		end
	end
	us[sid] = { lastAt = t, period = period }
	noteHealClaim(self, unit, claimAt)
	return sid, true, nil
end

-- Deferred pairing for UC events whose combat-log line has not arrived
-- yet (either-order delivery — the same race OfferOutgoing defers for
-- damage). The queued entry holds the raw amount; the emit runs at
-- line-arrival time with the UC event's original timestamp.
local HOT_PENDING_MAX = 16

local function queuePendingHotHeal(self, unit, t, amount, school, isCrit)
	local pq = self._pendingHotHeal
	if not pq then pq = {} ; self._pendingHotHeal = pq end
	-- Expire stale entries in place; a heal that never meets its line
	-- is foreign and stays unemitted by design.
	local j = 1
	for i = 1, #pq do
		local e = pq[i]
		if e.claimed ~= true and (t - e.t) <= HOT_LINE_WINDOW + 0.2 then
			pq[j] = e
			j = j + 1
		end
	end
	for i = #pq, j, -1 do pq[i] = nil end
	if #pq >= HOT_PENDING_MAX then table.remove(pq, 1) end
	pq[#pq + 1] = {
		unit = unit, t = t, amount = amount,
		school = school, isCrit = isCrit, claimed = false,
	}
	-- Register the line-arrival hook once; each newly buffered heal line
	-- retries every queued UC event against it. The matcher handles both
	-- kinds: "hot" lines go through rec+cadence naming, "heal" lines pair
	-- as direct heals named by the cast window.
	local zb = ZSBT.ZBattleText
	if zb and zb._healLineHook == nil then
		local selfRef = self
		zb._healLineHook = function(tl, kind)
			local pq2 = selfRef._pendingHotHeal
			if not pq2 then return end
			for i = 1, #pq2 do
				local e = pq2[i]
				if e.claimed ~= true and math.abs(e.t - tl) <= HOT_LINE_WINDOW then
					local hsid, hPeriodic, hWhy = matchOutgoingHotTick(selfRef, e.unit, e.t)
					-- Any terminal reason (dup/self/attackable/unnamed)
					-- resolves the entry — only "noline" retries.
					if hWhy ~= nil and hWhy ~= "noline" then
						e.claimed = true
					end
					if hsid ~= nil then
						e.claimed = true
						local pipeId = selfRef._rawPipeCount + 1
						selfRef._rawPipeCount = pipeId
						selfRef._rawPipe[pipeId] = e.amount
						auditNote(("AUDH unit=%s sid=%s defer=1"):format(
							dbgSafe(e.unit), tostring(hsid)))
						emit("OUTGOING_HEAL_COMBAT", {
							timestamp = e.t,
							rawPipeId = pipeId,
							amountText = (ZSBT.IsSafeNumber(e.amount) and tostring(e.amount)) or nil,
							spellId = hsid ~= 0 and hsid or nil,
							targetName = safeUnitName(e.unit),
							isCrit = e.isCrit == true,
							isPeriodic = hPeriodic == true or nil,
							schoolMask = ZSBT.IsSafeNumber(e.school) and e.school or nil,
						})
					end
				end
			end
		end
	end
end

local function offTargetDotsEnabled()
	local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
	return g == nil or g.showDotsOnOtherEnemies ~= false
end

-- Off-target periodic attribution ("show dots on other enemies"): a
-- UNIT_COMBAT wound on a non-target nameplate can only be named if a
-- DoT application record exists for THAT mob. The nameplate unit token
-- carries the identity directly — GUID preferred (collision-free when
-- several same-named mobs are dotted), name as the fallback key space
-- _dotAppliedTarget writes. Candidates must pass the same cadence
-- proof the target path uses; the best phase fit wins, none stays
-- generic rather than wrong.
local function resolveOffTargetDot(self, unit, t, school)
	local gm = self._dotAppliedGuid
	local nm = self._dotAppliedTarget
	if type(gm) ~= "table" and type(nm) ~= "table" then return nil end
	local g, n
	if UnitGUID then
		local ok, v = pcall(UnitGUID, unit)
		if ok and ZSBT.IsSafeString and ZSBT.IsSafeString(v) then g = v end
	end
	local un = safeUnitName(unit)
	if ZSBT.IsSafeString and ZSBT.IsSafeString(un) then n = un end
	if g == nil and n == nil then return nil end
	local best, bestDist = nil, nil
	local seen = nil
	local function consider(sid, at)
		if type(sid) ~= "number" or type(at) ~= "number"
			or (t - at) < 0 or (t - at) > PERIODIC_OUTGOING_WINDOW_SEC then
			return
		end
		seen = seen or {}
		if seen[sid] then return end
		seen[sid] = true
		-- School gate: a school-1 melee hit on a dotted nameplate cannot be
		-- that DoT's tick no matter how clean the phase looks. A declared
		-- dot school is authoritative for TICK claims (Flame Shock ticks
		-- report 4/5/12 on the wire while its tooltip says Volcanic — the
		-- cast's tooltip school is the wrong evidence for tick claims).
		-- Undeclared dots keep the cast/tooltip veto, plus the module
		-- dotGuard hook so pet-school strays stay out here too.
		local dent = dotEntryForSpellId(sid)
		if dent and dent.school ~= nil then
			if dotEntrySchoolEq(dent.school, school) ~= true then return end
		elseif not castSchoolOk(self, sid, school) then
			return
		end
		local entry = dotEntryForSpellId(sid)
		if entry and ZSBT.ClassDB and ZSBT.ClassDB.DotGuard
			and ZSBT.ClassDB.DotGuard(entry, school) == false then
			return
		end
		if not dotCadencePredict(self, t, sid, at) then return end
		local iv = dotTickInterval(sid) or 2.0
		local phase = (t - at) % iv
		local dist = math.min(phase, iv - phase)
		if bestDist == nil or dist < bestDist then best, bestDist = sid, dist end
	end
	local guidSeen = nil
	if g and type(gm) == "table" then
		for sid, sm in pairs(gm) do
			if type(sm) == "table" then
				guidSeen = guidSeen or {}
				guidSeen[sid] = true
				consider(sid, sm[g])
			end
		end
	end
	if n and type(nm) == "table" then
		for sid, sm in pairs(nm) do
			-- When the unit's GUID resolves and this dot keeps GUID
			-- records, a missing record is proof this mob never got our
			-- bleed — the name map cannot vouch for a different
			-- same-named mob (adjacent identical training dummies).
			-- Name records remain the fallback only where GUID
			-- evidence is absent (secret GUIDs, unrecorded sid).
			if type(sm) == "table" and not (guidSeen and guidSeen[sid]) then
				consider(sid, sm[n])
			end
		end
	end
	-- Multi-mob application anchors (AoE casts, applicator-seeded dots):
	-- a recorded mass application makes the cast's own time a valid phase
	-- reference for any nameplate in range — no per-mob record needed.
	-- Single-target applications never write this map, so a direct Rip
	-- cast cannot vouch for wounds on mobs it never touched.
	for sid, at in pairs(self._dotAppliedAoe or {}) do
		consider(sid, at)
	end
	return best
end

local function arePetsEnabled()
	local petConf = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.pets
	return petConf and petConf.enabled == true
end

local function getPetFamilyLower()
	if not UnitCreatureFamily then return nil end
	local okF, fam = pcall(UnitCreatureFamily, "pet")
	if okF and type(fam) == "string" and fam ~= "" then
		return string.lower(fam)
	end
	return nil
end

local function getUnitNpcId(unit)
	if not UnitGUID then return nil end
	local okG, guid = pcall(UnitGUID, unit)
	if not okG or type(guid) ~= "string" or guid == "" then return nil end
	-- GUID format: Type-0-ServerID-InstanceID-ZoneUID-ID-SpawnUID
	local _, _, _, _, _, id = strsplit("-", guid)
	local n = tonumber(id)
	if type(n) == "number" and n > 0 then
		return n
	end
	return nil
end

-- Pet school signatures live in the active Classes/ module now
-- (Classes/Registry.lua -> mod.petSchoolHit / petSchoolHitRecent).
local function isLikelyPetSchoolHit(school)
	local ClassDB = ZSBT.ClassDB
	if ClassDB and ClassDB.PetSchoolHit then
		return ClassDB.PetSchoolHit(school)
	end
	return false
end

local function isLikelyPetSchoolHitGivenRecentPlayerSpell(self, school, lastPlayerSpellId)
	local ClassDB = ZSBT.ClassDB
	if ClassDB and ClassDB.PetSchoolHitRecent then
		return ClassDB.PetSchoolHitRecent(self, school, lastPlayerSpellId)
	end
	return false
end

local function isLikelyPetPhysicalHit(school)
	local ClassDB = ZSBT.ClassDB
	if ClassDB and ClassDB.PetPhysicalHit then
		return ClassDB.PetPhysicalHit(school)
	end
	return false
end

-- PLAYER_SWING gives a public per-swing report (melee/ranged) on 12.x.
-- A melee hit lands ~0.45s after its swing; ranged shots fly up to ~2s
-- (FCT measured values).
local SWING_HIT_WINDOW, RANGED_HIT_WINDOW = 0.9, 2.0
anySwingRecent = function(self, t)
	local sw = self._swingAt
	if type(sw) ~= "table" then return false end
	for hand, at in pairs(sw) do
		local w = (hand == "ranged" or hand == "RANGED") and RANGED_HIT_WINDOW or SWING_HIT_WINDOW
		local dt = t - at
		if dt >= 0 and dt <= w then return true end
	end
	return false
end

-- true when a player swing plausibly produced this hit. When PLAYER_SWING
-- is unavailable on this client we cannot verify — stay permissive
-- (legacy behavior) rather than eating all auto-attacks, unless the
-- class module knows the class never swings (warlock/mage/priest).
local function swingExplainsHit(self, t)
	if ZSBT.ClassDB and ZSBT.ClassDB.VetoAuto and ZSBT.ClassDB.VetoAuto() then
		return false
	end
	-- Class evidence override: e.g. hunter decides auto vs pet melee by
	-- which line kind (ranged vs melee) the palette buffered nearby.
	if ZSBT.ClassDB and ZSBT.ClassDB.SwingEvidence then
		local se = ZSBT.ClassDB.SwingEvidence(self, t)
		if se ~= nil then return se == true end
	end
	if self._swingSupported ~= true then return true end
	return anySwingRecent(self, t)
end

-- Contention detection for unattributed physical hits. UC carries no
-- source on Retail, so when a second player (or follower/pet the gates
-- didn't catch) melees the same target, each would-be auto claim is a
-- coin flip over who owns it. Two auto candidates landing inside ~80%
-- of our own swing cannot both be ours — while that contention is live,
-- suppress auto-fallback emits instead of showing someone else's number.
-- Detection runs on post-twin-dedup candidates, so our own
-- nameplate->target re-reports never false-trigger it.
local AUTO_CONTEST_MIN = 0.55
local AUTO_CONTEST_GRACE = 3.0
local function autoContestWindow(self)
	local win = AUTO_CONTEST_MIN
	if UnitAttackSpeed then
		local okS, mh = pcall(UnitAttackSpeed, "player")
		if okS and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(mh) and mh > 0 then
			win = math.max(win, mh * 0.8)
		end
	end
	return win
end

local function autoContested(self, t, feed)
	local prof = ZSBT.db and ZSBT.db.profile
	local dmg = prof and prof.outgoing and prof.outgoing.damage
	if dmg and dmg.hideAutoContested == false then return false end
	-- Deferred-evidence pump: a wound with no MINE line at eval time is
	-- queued (~0.15s) before it can count as attacker evidence — the
	-- wound's own line frequently lands a frame or two late. On recheck,
	-- a wound still bare is a genuine possible-foreign and feeds; a
	-- wound whose line arrived in the meantime is excused forever.
	-- Entries older than 2s are discarded, never fed — a stale wound
	-- from a dead queue must not arm a later fight.
	local pend = self._autoCandPend
	if type(pend) == "table" then
		local zbtD = ZSBT.ZBattleText
		local i = 1
		while i <= #pend do
			local wt = pend[i]
			local age = t - wt
			if age >= 0.15 then
				if age <= 2.0 then
					local bare = not (self._lastDotEmitAt == wt
						or (zbtD and zbtD.PeekDamageLine
							and zbtD:PeekDamageLine(wt, 0.20, nil, true) ~= nil))
					if bare then
						local last = self._lastAutoCandAt
						self._lastAutoCandAt = wt
						if type(last) == "number" and (wt - last) > 0
							and (wt - last) < autoContestWindow(self) then
							self._autoContestUntil = wt + AUTO_CONTEST_GRACE
						end
					end
				end
				table.remove(pend, i)
			else
				i = i + 1
			end
		end
		if #pend == 0 then self._autoCandPend = nil end
	end
	local contested = (self._autoContestUntil or 0) > t
	if feed ~= false then
		-- Only target-path callers feed: off-target nameplate traffic
		-- (foreign cleave on OTHER mobs) must not arm target contention,
		-- or nearby AoE suppresses our own target autos unnecessarily.
		-- A wound carrying its own evidence is never a second attacker:
		-- a class hook that just claimed it as a named tick stamps
		-- _lastDotEmitAt == t, and a buffered MINE combat-log line means
		-- our own feed already reported it (bleed ticks, autos). Without
		-- this, a solo bleed class's own tick/auto cadence keeps the
		-- detector permanently armed and suppresses real hits.
		-- includeConsumed: own hits get their line claimed by their own
		-- emit milliseconds before the next own wound evaluates — at pet-
		-- swarm densities that evicted line is the only evidence left.
		-- Tight window: own wound/line pairs are the same event and land
		-- near-simultaneously; a foreign wound can only coincide with our
		-- line by chance, so a narrow excuse window bounds leak coverage.
		-- Wounds still bare here defer to the pending queue above rather
		-- than feeding immediately — see the pump comment.
		local zbt = ZSBT.ZBattleText
		local lineBacked = self._lastDotEmitAt == t
			or (zbt and zbt.PeekDamageLine
				and zbt:PeekDamageLine(t, 0.12, nil, true) ~= nil) or nil
		if not lineBacked then
			pend = self._autoCandPend
			if type(pend) ~= "table" then pend = {} ; self._autoCandPend = pend end
			pend[#pend + 1] = t
		end
	end
	return contested
end

-- Forward declaration needed so the cache wrapper defined below can reference it.
local hasTargetDebuffSpellId

-- Per-spellId TTL cache: avoids re-enumerating auras (and allocating the ForEachAura
-- closure) on every UNIT_COMBAT tick. Entries: [spellId] = { guid, result, expiry }
local _debuffCache = {}
local _debuffCacheGuid = nil
local _debuffCacheGuidAt = 0

local function cachedHasTargetDebuffSpellId(spellId)
	if type(spellId) ~= "number" then return false end
	local t = now()
	-- Refresh target GUID at most once per Lua frame to avoid repeated pcall overhead.
	if t - _debuffCacheGuidAt > 0.01 then
		local safeGuid = nil
		if UnitGUID then
			local ok, g = pcall(UnitGUID, "target")
			-- Only store the GUID when it is a safe (non-tainted) string; tainted GUIDs
			-- cannot be used as table keys or compared without crashing in 12.x instances.
			if ok and type(g) == "string" and ZSBT.IsSafeString and ZSBT.IsSafeString(g) then
				safeGuid = g
			end
		end
		_debuffCacheGuid = safeGuid
		_debuffCacheGuidAt = t
	end
	local guid = _debuffCacheGuid
	-- No safe GUID available (tainted instance context) — bypass cache entirely.
	if guid == nil then
		return hasTargetDebuffSpellId(spellId)
	end
	local entry = _debuffCache[spellId]
	if entry then
		-- pcall guards against stale tainted entries that may have been stored before
		-- this fix; once entries are refreshed with a safe guid the pcall always succeeds.
		local ok, matches = pcall(function() return entry.guid == guid and t < entry.expiry end)
		if ok and matches then
			return entry.result
		end
	end
	local result = hasTargetDebuffSpellId(spellId)
	if not entry then entry = {}; _debuffCache[spellId] = entry end
	entry.guid = guid
	entry.result = result
	entry.expiry = t + 1.5
	return result
end

-- Era multi-dot picker (mod.dotCadenceDisambig): instead of naming the
-- most recent dot, evaluate every periodic sid in the window against the
-- wound's school, target-debuff presence, and per-dot cadence. Exactly
-- one survivor names the hit; zero or multiple stay generic — with two
-- same-school dots up, a wound that fits both cadences cannot be proven
-- and "never wrong" beats "sometimes named".
local function pickDotByCadenceDisambig(self, t, school, amount, isCrit)
	local m = self and self._recentPeriodicSpellAt
	if type(m) ~= "table" then return nil end
	-- A pending pet cast record is PROOF a pet spell is in flight — the
	-- next school-matching wound is most likely that bolt, not a dot tick.
	-- Proven claims outrank inferred ones; this replaces the era module's
	-- old blanket school-4 veto, which suppressed Immolate entirely
	-- whenever an imp was active.
	local pendingPet = pendingPetCast(self, t, 1.5, school)
	local woundTgt = safeUnitName("target")
	-- Typed-line evidence (FCT model): the combat-log filter classifies
	-- MINE/MY_PET lines by kind — a "tick" line near this wound means the
	-- client itself logged a periodic hit. Peek only; the real pairing
	-- consumes the line downstream. Both lines present = ambiguous
	-- environment, evidence cancels out.
	local tickLine, directLine = nil, nil
	local zbt = ZSBT.ZBattleText
	if zbt and zbt.PeekDamageLine then
		tickLine = zbt:PeekDamageLine(t, 0.30, { tick = true })
		if not tickLine then
			directLine = zbt:PeekDamageLine(t, 0.30,
				{ direct = true, melee = true, ranged = true, shield = true })
		end
	end
	local pick, count = nil, 0
	-- Survivor pool + scores for the scored race (reused tables — no
	-- per-wound allocation).
	local pool = self._disambigPool
	if pool then wipe(pool) else pool = {} ; self._disambigPool = pool end
	local scores = self._disambigScores
	if scores then wipe(scores) else scores = {} ; self._disambigScores = scores end
	local rejNoEntry, rejSchool, rejCadence, rejChan, rejTarget, rejRescued, scanned = 0, 0, 0, 0, 0, 0, 0
	-- Target-debuff presence is a TIEBREAKER, not a gate: era aura APIs
	-- may not expose the data at all, and multi-target DoTing means a real
	-- tick from another mob arrives while this target lacks the debuff.
	-- School + cadence phase-lock is the proof; the aura check only
	-- disambiguates when several candidates survive.
	local debuffPick, debuffCount = nil, 0
	local prof = ZSBT.db and ZSBT.db.profile
	local learnedAm = type(prof) == "table" and prof.learnedTickAmounts or nil
	local learnedPer = type(prof) == "table" and prof.learnedDotPeriods or nil
	-- Score a gated survivor: predicted-beat proximity + amount fit vs the
	-- learned EMA → persisted amount → tooltip-derived expected tick.
	-- Lower is better; ~0.5/leg when that evidence is unavailable.
	local function candidateScore(sid, entry)
		local score = 0
		local st = self._dotTickState
		local rec = type(st) == "table" and st[sid] or nil
		local nextAt = rec and rec.nextAt
		if type(nextAt) == "number" then
			local off = math.abs(t - nextAt)
			score = score + ((off <= 0.45) and (off / 0.45 * 0.3) or 0.8)
		else
			score = score + 0.5
		end
		local ref = self._dotTickAmounts and self._dotTickAmounts[sid]
		if not ref and learnedAm then ref = learnedAm[sid] end
		if not ref then
			local iv = (rec and rec.period) or (learnedPer and learnedPer[sid])
				or dotTickInterval(sid, entry)
			local sb = ZSBT.Spellbook
			local sbRec = sb and sb.Entry and sb:Entry(sid)
			if sbRec and type(sbRec.dotTotal) == "number" and type(sbRec.dotDur) == "number"
				and sbRec.dotDur > 0 then
				ref = sbRec.dotTotal * iv / sbRec.dotDur
			end
		end
		if ref and ref > 0 and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(amount) then
			local cmp = (isCrit == true) and (amount * 0.5) or amount
			score = score + math.min(1, math.abs(cmp - ref) / ref)
		else
			score = score + 0.5
		end
		return score
	end
	for sid, at in pairs(m) do
		if type(sid) == "number" and type(at) == "number"
			and (t - at) >= 0 and (t - at) <= PERIODIC_OUTGOING_WINDOW_SEC then
			scanned = scanned + 1
			local entry = dotEntryForSpellId(sid)
			if not entry then
				rejNoEntry = rejNoEntry + 1
			elseif ZSBT.ClassDB.ChannelMatch and ZSBT.ClassDB.ChannelMatch(sid) then
				-- Channel-owned sid (Drain Soul derives as "dot" from the
				-- book too): its ticks claim through the channel path, and
				-- a ~1s interval would accept nearly every wound's phase —
				-- including it here only manufactures collisions.
				rejChan = rejChan + 1
			elseif entry.school and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school) and dotEntrySchoolEq(entry.school, school) == false then
				rejSchool = rejSchool + 1
			elseif pendingPet ~= nil and entry.school and ZSBT.IsSafeNumber(school) and dotEntrySchoolEq(entry.school, school) == true then
				-- Wound is contested by a proven pet claim: don't let a
				-- same-school dot steal it. Falls through to the pet path.
				rejSchool = rejSchool + 1
			else
				-- Per-target scoping: a wound on the current target may
				-- only claim a dot applied to that mob. Unknown names are
				-- permissive (CombatText wounds carry no target).
				local appliedOv, tgtOk = nil, true
				local map = self._dotAppliedTarget and self._dotAppliedTarget[sid]
				if type(map) == "table" and ZSBT.IsSafeString
					and ZSBT.IsSafeString(woundTgt) then
					if map[woundTgt] ~= nil then
						appliedOv = map[woundTgt]
					elseif next(map) ~= nil then
						-- Only a recorded multi-mob application excuses a
						-- missing per-mob record (AoE cast or applicator);
						-- a single-target application elsewhere cannot
						-- vouch for a wound on this mob.
						local aoeAt = self._dotAppliedAoe and self._dotAppliedAoe[sid]
						if type(aoeAt) == "number" then
							appliedOv = aoeAt
						else
							tgtOk = false
						end
					end
				end
				if not tgtOk then
					rejTarget = rejTarget + 1
				elseif not dotCadencePredict(self, t, sid, appliedOv) then
					-- A typed "tick" line with no competing direct line is
					-- the client's own confirmation a periodic hit fired —
					-- rescue the candidate at a score penalty. Real ticks
					-- that wandered off-schedule recover their names.
					if tickLine ~= nil then
						count = count + 1
						pool[count] = sid
						scores[count] = candidateScore(sid, entry) + 0.4
						rejRescued = (rejRescued or 0) + 1
					else
						rejCadence = rejCadence + 1
					end
				else
					count = count + 1
					pool[count] = sid
					scores[count] = candidateScore(sid, entry)
					if cachedHasTargetDebuffSpellId(sid) then
						debuffPick = sid
						debuffCount = debuffCount + 1
					end
				end
			end
		end
	end
	-- A live channel joins the candidate pool instead of greedily claiming
	-- every same-school wound: its ticks phase-lock to channel start, so a
	-- DoT tick landing between channel ticks is no longer eaten by the
	-- channel — and a wound both could explain goes generic, not wrong.
	local ch = self._channel
	if type(ch) == "table" and type(ch.startedAt) == "number"
		and type(ch.untilAt) == "number" and t <= ch.untilAt
		and ch.spellId == self._lastPlayerSpellId then
		scanned = scanned + 1
		local chSchoolOk = true
		if ch.school ~= nil and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school) then
			chSchoolOk = dotEntrySchoolEq(ch.school, school) == true
		end
		local iv = (type(ch.interval) == "number" and ch.interval > 0) and ch.interval
			or dotTickInterval(ch.spellId)
		local elapsed = t - ch.startedAt
		if not chSchoolOk then
			rejSchool = rejSchool + 1
		elseif not tickLine and elapsed < (iv * 0.5) then
			rejCadence = rejCadence + 1
		else
			-- Interval-proportional jitter: era drain channels tick at 1s,
			-- where a fixed 0.45s band accepts ~90% of all wounds and
			-- manufactures collisions. Phase from channel start OR distance
			-- from the last claimed tick — same self-correcting anchors as
			-- the dot path (drains wander too).
			local jitter = math.min(0.45, math.max(0.20, iv * 0.30))
			local phase = elapsed % iv
			local phaseOk = phase <= jitter or phase >= (iv - jitter)
			if not phaseOk then
				local lastCh = ch.lastTickAt
				if type(lastCh) == "number" and lastCh > 0 then
					local dt = t - lastCh
					phaseOk = dt >= (iv * 0.7) and dt <= (iv * 1.45)
				end
			end
			if phaseOk or (tickLine ~= nil and chSchoolOk) then
				count = count + 1
				pool[count] = ch.spellId
				scores[count] = candidateScore(ch.spellId, nil)
					+ (phaseOk and 0 or 0.4)
				if cachedHasTargetDebuffSpellId(ch.spellId) then
					debuffPick = ch.spellId
					debuffCount = debuffCount + 1
				end
			else
				rejCadence = rejCadence + 1
			end
		end
	end
	-- Scored race: the best-fitting survivor wins only if it beats the
	-- runner-up by a margin — near-tied candidates stay honest generic
	-- (the FCT DIRECT_MATCH_MARGIN model), never a coin flip.
	local ret, retWhy = nil, nil
	if count == 1 then
		ret = pool[1]
	elseif count > 1 then
		local bestI
		for i = 1, count do
			if not bestI or scores[i] < scores[bestI] then bestI = i end
		end
		local ambiguous = false
		for i = 1, count do
			if i ~= bestI and scores[i] <= scores[bestI] + 0.15 then
				ambiguous = true
				break
			end
		end
		if not ambiguous then
			ret, retWhy = pool[bestI], "score"
		end
		if ret == nil and debuffCount == 1 then
			ret, retWhy = debuffPick, "debuff"
		end
		-- Typed-line veto: a MINE-sourced direct/melee line near the wound
		-- with no tick line is counter-evidence — suppress a weak pick
		-- (score >= 0.75 = no beat and no amount fit). Strong picks stand:
		-- a bolt landing mid-tick-stream must not starve real ticks.
		if ret ~= nil and directLine ~= nil and scores[bestI] >= 0.75 then
			ret, retWhy = nil, "lineveto"
		end
	end
	-- Stamp the channel's tick anchor only on an actual pick: it feeds the
	-- distance-from-last-tick check next wound (self-correcting cadence).
	if ret ~= nil and type(ch) == "table" and ret == ch.spellId then
		ch.lastTickAt = t
	end
	if auditNote then
		auditNote(("AUDD reason=DOTDISAMBIG scan=%s surv=%s ret=%s why=%s debuffpass=%s pet=%s line=%s rescued=%s noentry=%s school=%s chan=%s tgt=%s cadence=%s")
			:format(dbgSafe(scanned), dbgSafe(count), dbgSafe(ret), dbgSafe(retWhy), dbgSafe(debuffCount),
				dbgSafe(pendingPet), dbgSafe(tickLine and "tick" or (directLine and "direct" or nil)),
				dbgSafe(rejRescued), dbgSafe(rejNoEntry), dbgSafe(rejSchool), dbgSafe(rejChan),
				dbgSafe(rejTarget), dbgSafe(rejCadence)))
	end
	return ret
end

local function pickDotForWound(self, t, school, amount, isCrit)
	-- A module shipping its own physical-wound classifier owns school-1
	-- dot naming (Warrior: Rend classifier + Ravager window — its docs
	-- keep every other physical bleed generic by design). The generic
	-- pick must not compete: its isDuplicateDotEmit shares _lastDotEmit*
	-- state with the module hook, so a white swing following a hook
	-- emit was silently dropped, and surviving swings wore bleed names.
	local mod = ZSBT.ClassDB and ZSBT.ClassDB.ActiveModule
		and ZSBT.ClassDB.ActiveModule()
	if mod and mod.onPhysicalWound then return nil end
	if ZSBT.ClassDB and ZSBT.ClassDB.DotCadenceDisambig
		and ZSBT.ClassDB.DotCadenceDisambig() then
		return pickDotByCadenceDisambig(self, t, school, amount, isCrit)
	end
	return getMostRecentPeriodicSpellIdForSchool(self, t, school)
end

-- Proc riders (mod.procRiders): guaranteed on-attack procs that fire no
-- cast record (Flametongue Weapon procs on EVERY weapon attack). The
-- evidence bar for naming a wound: school matches the rider, a school-1
-- wound landed within the anchor window (a weapon attack just happened),
-- the target is not contested (a co-attacker's swing can't feed it), and
-- the rider's cadence cap admits another claim (one proc per attack).
local function pickProcRider(self, t, school)
	local riders = ZSBT.ClassDB and ZSBT.ClassDB.ProcRiders
		and ZSBT.ClassDB.ProcRiders()
	if type(riders) ~= "table" then return nil end
	if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school)) then return nil end
	local anchor = self._lastPhysWoundAt
	if type(anchor) ~= "number" or (t - anchor) < 0 or (t - anchor) > 0.35 then
		return nil
	end
	if autoContested(self, t) then return nil end
	local last = self._procRiderLast
	for _, r in ipairs(riders) do
		if type(r) == "table" and type(r.sid) == "number"
			and dotEntrySchoolEq(r.school, school) == true then
			local lastAt = last and last[r.sid]
			if not (type(lastAt) == "number" and (t - lastAt) < (r.minGap or 0.30)) then
				if type(last) ~= "table" then last = {} ; self._procRiderLast = last end
				last[r.sid] = t
				return r.sid
			end
		end
	end
	return nil
end

-- The picked sid is the live channel itself: its ticks must bypass the
-- DoT-only gates downstream (target-debuff presence, dedup window, the
-- recent-cast veto — the "recent cast" IS this channel).
local function isLiveChannelPick(self, t, sid)
	local ch = self._channel
	return type(ch) == "table" and type(sid) == "number"
		and ch.spellId == sid
		and type(ch.untilAt) == "number" and t <= ch.untilAt
end

-- Learned tick amounts: EMA of a sid's claimed non-crit tick amounts.
-- Era dots tick for a consistent per-rank value, so the learned average
-- is a strong discriminator when phase-locking leaves collisions. Only
-- feeds the tiebreak where the module opted in — amounts stay unread
-- (possibly secret) on clients that don't.
local function noteDotTickAmount(self, spellId, amount, isCrit, t, tgtName)
	if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(amount) then
		if isCrit == true then amount = amount * 0.5 end
		if amount > 0 then
			local am = self._dotTickAmounts
			if not am then am = {} ; self._dotTickAmounts = am end
			local avg = am[spellId]
			am[spellId] = avg and (avg * 0.65 + amount * 0.35) or amount
		end
	end
	-- Learned rhythm + persistence are disambig-module features: the
	-- confirmed-tick gap refines the sid's true period, and nextAt is the
	-- predicted beat the scorer prefers. Persisted so it survives /reload.
	if not (ZSBT.ClassDB and ZSBT.ClassDB.DotCadenceDisambig
		and ZSBT.ClassDB.DotCadenceDisambig()) then return end
	if type(t) ~= "number" then return end
	local st = self._dotTickState
	if type(st) ~= "table" then st = {} ; self._dotTickState = st end
	local rec = st[spellId]
	if type(rec) ~= "table" then rec = {} ; st[spellId] = rec end
	-- Learn gaps only between ticks on the SAME mob: tab-dotting
	-- interleaves two targets' beats into one record and drags the
	-- learned interval below the true beat (Immolate learned 1.69s on
	-- a 3s beat). Secret names can't compare — those ticks still stamp
	-- confirmedAt/nextAt but never teach, which is safe not loss.
	local sameTgt = false
	if ZSBT.IsSafeString and ZSBT.IsSafeString(tgtName) then
		if type(rec.lastTgt) ~= "string" then
			sameTgt = true
		else
			local okEq, eq = pcall(function() return tgtName == rec.lastTgt end)
			sameTgt = okEq and eq == true
		end
		rec.lastTgt = tgtName
	end
	if type(rec.confirmedAt) == "number" and sameTgt then
		local gap = t - rec.confirmedAt
		local iv = rec.period or dotTickInterval(spellId)
		-- A gap near 1x period refines the learned interval; a gap at 2x+
		-- is skipped ticks — keep the learned value, don't grow it.
		if gap >= iv * 0.7 and gap <= iv * 1.45 then
			rec.period = rec.period and (rec.period * 0.6 + gap * 0.4) or gap
		end
	end
	rec.confirmedAt = t
	rec.nextAt = t + (rec.period or dotTickInterval(spellId))
	local prof = ZSBT.db and ZSBT.db.profile
	if type(prof) == "table" then
		local avg = self._dotTickAmounts and self._dotTickAmounts[spellId]
		if avg then
			prof.learnedTickAmounts = prof.learnedTickAmounts or {}
			prof.learnedTickAmounts[spellId] = avg
		end
		if rec.period then
			prof.learnedDotPeriods = prof.learnedDotPeriods or {}
			prof.learnedDotPeriods[spellId] = rec.period
		end
	end
end

hasTargetDebuffSpellId = function(spellId)
	if type(spellId) ~= "number" then return false end
	local wantName = nil
	if ZSBT and ZSBT.CleanSpellName then
		wantName = ZSBT.CleanSpellName(spellId)
	end
	-- Corruption can present as a different aura spellId in some starter/tutorial contexts.
	-- Treat those variants as present for safe DoT attribution.
	if spellId == 172 then
		if AuraUtil and AuraUtil.FindAuraBySpellId then
			local okV, auraV = pcall(AuraUtil.FindAuraBySpellId, 146739, "target", "HARMFUL|PLAYER")
			if okV and auraV then
				return true
			end
			local okV2, auraV2 = pcall(AuraUtil.FindAuraBySpellId, 146739, "target", "HARMFUL")
			if okV2 and auraV2 then
				return true
			end
		end
	end
	if AuraUtil and AuraUtil.FindAuraBySpellId then
		local okP, auraP = pcall(AuraUtil.FindAuraBySpellId, spellId, "target", "HARMFUL|PLAYER")
		if okP and auraP then
			return true
		end
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
		local scanned = 0
		local firstSid = nil
		local firstName = nil
		pcall(function()
			AuraUtil.ForEachAura("target", "HARMFUL", 255, function(auraData)
				scanned = scanned + 1
				local sid = SafeAuraSpellId(auraData)
				if firstSid == nil and sid ~= nil then
					firstSid = sid
					local nm = auraData and auraData.name
					if type(nm) == "string" then firstName = nm end
				end
				local okEq, eq = pcall(function() return sid == spellId end)
				if okEq and eq then
					found = true
					return false
				end
				if spellId == 172 and type(sid) == "number" and sid == 146739 then
					found = true
					return false
				end
				if wantName and type(auraData) == "table" and type(auraData.name) == "string" and auraData.name == wantName then
					found = true
					return false
				end
				return true
			end, true)
		end)
		if found then return true end
		-- WoW 12.x (and some tutorial/instanced contexts) can return "secret" aura fields.
		-- When Corruption is active, the aura can be present but its spellId/name may be
		-- unsafe to compare. If exactly one harmful aura is visible and its spellId is a
		-- numeric value that fails IsSafeNumber, treat Corruption as present.
		if spellId == 172 and scanned == 1 and type(firstSid) == "number" then
			if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(firstSid)) then
				return true
			end
		end
		if OutDbgLevel and OutDbgLevel() >= 4 and spellId == 172 then
			local tNow = now()
			if (tNow - (Collector._dbgLastDebuffMissAt or 0)) > 0.75 then
				Collector._dbgLastDebuffMissAt = tNow
				local ex = nil
				if UnitExists then
					local okE, e = pcall(UnitExists, "target")
					if okE then ex = e end
				end
				ECPrint(("DEBUFF_MISS spellId=%s unit=target exists=%s scanned=%s firstSid=%s firstName=%s")
					:format(dbgSafe(spellId), dbgSafe(ex), dbgSafe(scanned), dbgSafe(firstSid), dbgSafe(firstName)))
			end
		end
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
	-- Some intake paths deliver spellIds as strings ("1226019"); a
	-- string sid silently misses every == / table-key compare below
	-- (pending-cast wants, exclusion lists, signature links). Coerce
	-- at the boundary so the whole pool is number-keyed.
	spellId = tonumber(spellId) or spellId
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
	-- A spell whose own tooltip deals no damage can never own a hit — the
	-- FCT "Curse of Tongues" fix; summon/curse casts stay out of the pool
	-- so their spellId can't stamp foreign damage.
	local castFacts = SpellFacts(spellId)
	if castFacts and castFacts.damages == false then
		return
	end
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
	-- Signature window: separate from the pending record — a cast's own
	-- direct hit consumes the record while its linked procs still fly.
	sigSeed(self, spellId, tNow)
end

-- Veto-confirmed (line-paired) outgoing hits teach the spell's damage
-- school. Called from emit()'s fast path and ZBattleText's deferred
-- delivery — both mean a MINE/MY_PET palette line confirmed ownership.
-- Vote-guarded (FCT): a single confirmed hit is still a guess — a school
-- is only taught once it leads the vote with >= 2 confirmations, so one
-- stolen line can't poison the table. Learned values persist to the
-- profile so the ratchet survives /reload.
local SCHOOL_LEARN_VOTES = 2
function Collector:_persistLearnedSchool(spellId, schoolMask)
	local prof = ZSBT.db and ZSBT.db.profile
	if type(prof) ~= "table" then return end
	prof.learnedSpellSchools = prof.learnedSpellSchools or {}
	prof.learnedSpellSchools[spellId] = schoolMask
end

function Collector:LearnConfirmedSchool(spellId, schoolMask, trusted)
	if type(spellId) ~= "number" then return end
	if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(spellId)) then return end
	if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(schoolMask)) then return end
	-- Provenance gate (FCT Trust): only a sid bound to a consumed cast
	-- record may teach. Recency/fallback stamps are guesses — a foreign
	-- hit confirmed by a stolen line would otherwise teach its school to
	-- your spell (the "Demonbolt learned Holy" poison).
	if trusted ~= true then return end
	-- Tooltip-declared schools are already authoritative; nothing to learn.
	local facts = SpellFacts(spellId)
	if facts and type(facts.school) == "number" then return end
	local votes = self._schoolVotes[spellId]
	if type(votes) ~= "table" then
		votes = {}
		self._schoolVotes[spellId] = votes
	end
	votes[schoolMask] = (votes[schoolMask] or 0) + 1
	local learned = self._learnedSpellSchool[spellId]
	if learned ~= nil then
		if learned == schoolMask then return end
		-- A contradicting school may flip the learned value only after it
		-- out-votes the incumbent (poisoned bootstrap / patched spells).
		if votes[schoolMask] >= (votes[learned] or 0) + 2 then
			self._learnedSpellSchool[spellId] = schoolMask
			self:_persistLearnedSchool(spellId, schoolMask)
		end
		return
	end
	local against = 0
	for other, n in pairs(votes) do
		if other ~= schoolMask then against = against + n end
	end
	if votes[schoolMask] >= SCHOOL_LEARN_VOTES and votes[schoolMask] > against then
		self._learnedSpellSchool[spellId] = schoolMask
		self:_persistLearnedSchool(spellId, schoolMask)
	end
end

-- Signature claim ------------------------------------------------------
-- An unattributed non-physical hit may be a linked proc's wound: the
-- book's correlation layer maps "cast X -> spells whose tooltips
-- reference X" (triggers, modifiers, hero procs). Every damage-capable
-- cast seeds a short window here — the pending record can be consumed
-- by the cast's own direct hit while its proc is still in flight, so
-- windows are tracked separately. A candidate must be a wound source
-- (facts don't deny damage), school-fit, and reach composite
-- confidence: a strong link edge claims outright; a mention needs the
-- hero-tree proc prior plus a declared school match. Module-excluded
-- and no-damage sids never claim. Claims are guesses, not provenance —
-- they do not teach schools.
local SIG_WINDOW = 2.5
local SIG_MAX = 16
local SIG_LEARN_MIN = 2      -- observations before a binding boosts score
local SIG_LEARN_MAX = 99     -- bound the counter so stale data decays
local sigBand = (bit and bit.band) or (bit32 and bit32.band)
Collector._sigCasts = Collector._sigCasts or {}

-- Instance write gate: solo/world is school — bindings form, windows
-- count, claims corroborate. Group content applies bindings read-only:
-- target overlap + proc soup make timing evidence weakest exactly
-- where volume is highest, so a poisoned edge costs nothing there.
local function sigCanLearn()
	if not IsInInstance then return true end
	local inInst = IsInInstance()
	return not (inInst == true)
end

-- Learned trigger->proc bindings, persisted sid-keyed like
-- learnedSpellSchools. n = fires observed, w = windows offered
-- (fire rate), rel = relearn counter (bindings wiped by drift).
Collector._procBindings = Collector._procBindings or nil

local function sigBindings(self)
	if self._procBindings ~= nil then return self._procBindings end
	self._procBindings = {}
	local prof = ZSBT.db and ZSBT.db.profile
	local saved = type(prof) == "table" and prof.learnedProcLinks or nil
	if type(saved) == "table" then
		for trig, t in pairs(saved) do
			local tt = tonumber(trig)
			if tt and type(t) == "table" then
				local rec = self._procBindings[tt]
				if not rec then rec = {} self._procBindings[tt] = rec end
				for proc, e in pairs(t) do
					local pp = tonumber(proc)
					if pp and type(e) == "table" then
						rec[pp] = {
							n = tonumber(e.n) or 0,
							w = tonumber(e.w) or 0,
							rel = tonumber(e.rel) or 0,
							schools = type(e.schools) == "table" and e.schools or {},
						}
					end
				end
			end
		end
	end
	return self._procBindings
end

local function sigBindEntry(self, trig, proc)
	trig = tonumber(trig) or trig
	proc = tonumber(proc) or proc
	local b = sigBindings(self)
	local bt = b[trig]
	if not bt then bt = {} b[trig] = bt end
	local e = bt[proc]
	if not e then e = { n = 0, w = 0, rel = 0, schools = {} } bt[proc] = e end
	return e
end

local function sigPersist(self, trig, proc, e)
	local prof = ZSBT.db and ZSBT.db.profile
	if type(prof) ~= "table" then return end
	prof.learnedProcLinks = prof.learnedProcLinks or {}
	-- Persist the WHOLE trigger bucket: unclaimed edges' window counts
	-- are still fire-rate evidence — losing them to reload would
	-- undercount opportunities for procs that simply never fired.
	local b = sigBindings(self)
	local src = b[trig]
	if not src then return end
	local t = prof.learnedProcLinks[trig]
	if not t then t = {} prof.learnedProcLinks[trig] = t end
	for p, ent in pairs(src) do
		t[p] = { n = ent.n, w = ent.w, rel = ent.rel, schools = ent.schools }
	end
end

local function sigExpire(self, tNow)
	local l = self._sigCasts
	for i = #l, 1, -1 do
		if (tNow - l[i].at) > SIG_WINDOW then table.remove(l, i) end
	end
end

sigSeed = function(self, spellId, tNow)
	local l = self._sigCasts
	l[#l + 1] = { sid = spellId, at = tNow }
	if #l > SIG_MAX then table.remove(l, 1) end
	-- Opportunity counter: every open window is a chance for each linked
	-- proc to fire. Only counted where writes are allowed.
	if not sigCanLearn() then return end
	local sb = ZSBT.Spellbook
	if not (sb and sb.LinksFrom) then return end
	for _, trig in ipairs({ spellId, sb:PairOf(spellId) }) do
		if type(trig) == "number" then
			local links = sb:LinksFrom(trig)
			if type(links) == "table" then
				for procSid in pairs(links) do
					if type(procSid) == "number" then
						local e = sigBindEntry(self, trig, procSid)
						e.w = e.w + 1
					end
				end
			end
		end
	end
end

local function sigMaskFit(rec, hitSchool)
	if type(hitSchool) ~= "number" or not sigBand then return true end
	local ms = rec and rec.masks
	if type(ms) ~= "table" or #ms == 0 then return true end
	for _, m in ipairs(ms) do
		if sigBand(m, hitSchool) ~= 0 then return true end
	end
	return false
end

claimSignature = function(self, tNow, hitSchool)
	local sb = ZSBT.Spellbook
	if not (sb and sb.LinksFrom and sb.PairOf) then return nil end
	sigExpire(self, tNow)
	local excl = ZSBT.ClassDB and ZSBT.ClassDB.ExcludedSpellId or nil
	local best, bestScore, bestDt, bestVia, refusedSid, refusedTalentSid
	for _, w in ipairs(self._sigCasts) do
		local seen = {}
		for _, trig in ipairs({ w.sid, sb:PairOf(w.sid) }) do
			if type(trig) == "number" and seen[trig] ~= true then
				seen[trig] = true
				local links = sb:LinksFrom(trig)
				if type(links) == "table" then
					for procSid, strength in pairs(links) do
						if type(procSid) == "number"
							and (excl == nil or excl(procSid) ~= true) then
							local rec = sb:Entry(procSid)
							local facts = SpellFacts(procSid)
							local bind = sigBindings(self)[trig]
							bind = bind and bind[procSid] or nil
							-- Proc-icon honesty: a linked proc may only wear a
							-- wound (its icon reaches the screen) when the proc
							-- ITSELF provably deals damage — positive damage
							-- text in its own tooltip, or a binding that
							-- already earned >=MIN claims with a clean drift
							-- record (rel>0 means it learned a wrong stream
							-- before — n inherited from the loose gate is not
							-- proof). Buff/passive links still feed correlation
							-- (w/n counters, link map) but can never claim.
							local damagesProven = (facts and facts.damages == true)
								or (bind and bind.n >= SIG_LEARN_MIN and bind.rel == 0)
							-- Talent-node sids are not damage events — the
							-- talent modifies a cast, it never fires itself.
							-- A linked talent feeds correlation (w/n, the sb
							-- map, the empower-pair icon) but can never own a
							-- wound's identity.
							local isTalent = (type(rec) == "table" and rec.talent == true)
							if type(rec) == "table"
								and (not facts or facts.damages ~= false)
								and sigMaskFit(rec, hitSchool) then
								local score = (strength == "strong" and 2 or 0)
									+ (rec.subTree ~= nil and 1 or 0)
									+ (type(rec.masks) == "table" and #rec.masks > 0 and 1 or 0)
								-- A corroborated binding is its own
								-- evidence: earned confidence, still gated by
								-- window + school fit — and a drift-flagged
								-- binding (rel>0 learned a wrong stream before)
								-- can't self-boost.
								if bind and bind.n >= SIG_LEARN_MIN and bind.rel == 0 then
									score = score + 2
								end
								if score >= 3 then
									if isTalent then
										refusedTalentSid = refusedTalentSid or procSid
									elseif damagesProven then
										local dt = tNow - w.at
										if bestScore == nil or score > bestScore
											or (score == bestScore and dt < bestDt) then
											best, bestScore, bestDt, bestVia = procSid, score, dt, trig
										end
									else
										refusedSid = refusedSid or procSid
									end
								end
							end
						end
					end
				end
			end
		end
	end
	-- Refused candidates leave a trail in the pressure ledger:
	-- rej:SIG_NODAMAGE:<sid> (no damage proof) or rej:SIG_TALENT:<sid>
	-- (talent-node sid — correlation only, never an icon).
	if best == nil and refusedTalentSid ~= nil then
		auditNote(("AUDD reason=SIG_TALENT spellId=%s school=%s"):format(
			dbgSafe(refusedTalentSid), dbgSafe(hitSchool)))
	elseif best == nil and refusedSid ~= nil then
		auditNote(("AUDD reason=SIG_NODAMAGE spellId=%s school=%s"):format(
			dbgSafe(refusedSid), dbgSafe(hitSchool)))
	end
	if best then
		local bn = -1
		if sigCanLearn() then
			local e = sigBindEntry(self, bestVia, best)
			-- School drift: a bound proc reporting a school that shares NO
			-- bits with anything it produced before = the binding learned
			-- the wrong stream. Composite overlap is same-family, not
			-- drift (Dark Matter ticks 36 and 4 — 4 is inside 36).
			if type(hitSchool) == "number" then
				local related, any = false, false
				for s in pairs(e.schools) do
					any = true
					if s == hitSchool or (sigBand and sigBand(s, hitSchool) ~= 0) then
						related = true
					end
				end
				if any and not related then
					e.n = 0
					e.rel = e.rel + 1
					e.schools = {}
				end
				e.schools[hitSchool] = true
			end
			e.n = math.min(e.n + 1, SIG_LEARN_MAX)
			sigPersist(self, bestVia, best, e)
			bn = e.n
		end
		auditNote(("AUDSIG sid=%s via=%s score=%d dt=%.2f school=%s bind=%s"):format(
			tostring(best), tostring(bestVia), bestScore or 0,
			bestDt or 0, tostring(hitSchool), tostring(bn)))
	end
	return best, bestVia
end

-- Empower-pair display: a wound legitimately claimed by its own cast
-- evidence may still be a linked proc of a recent trigger (Secrets of
-- the Coven via Shadow Bolt). Stamp the trigger so the render can show
-- the pair — correlation as display metadata, never attribution.
sigBaseForTrigger = function(self, tNow, claimSid)
	if type(claimSid) ~= "number" then return nil end
	sigExpire(self, tNow)
	local sb = ZSBT.Spellbook
	if not (sb and sb.LinksFrom) then return nil end
	local best, bestDt
	for _, w in ipairs(self._sigCasts) do
		for _, trig in ipairs({ w.sid, sb:PairOf(w.sid) }) do
			if type(trig) == "number" then
				local links = sb:LinksFrom(trig)
				if type(links) == "table" and links[claimSid] ~= nil then
					local dt = tNow - w.at
					if bestDt == nil or dt < bestDt then
						best, bestDt = trig, dt
					end
				end
			end
		end
	end
	return best
end

-- Empower-pair display, trigger side: the wound was claimed by a plain
-- cast sid (Shadow Bolt) that is itself a link trigger — the empowered
-- variant can't be told from a normal bolt by identity. Presence of a
-- linked proc's buff on the player is the honest signal: Secrets of
-- the Coven active when the bolt's damage lands means the pair
-- [bolt][Secrets] is evidence, not decoration.
sigEmpowerForTrigger = function(self, tNow, claimSid)
	if type(claimSid) ~= "number" then return nil end
	local sb = ZSBT.Spellbook
	if not (sb and sb.LinksFrom and sb.Entry) then return nil end
	-- Existence check only — FindAuraBySpellId answers "is an aura with
	-- this sid up" without touching any secret name/field. Same pattern
	-- as the trigger system's proc-alert detection (Triggers.lua).
	local find = AuraUtil and AuraUtil.FindAuraBySpellId
	if type(find) ~= "function" then return nil end
	for _, trig in ipairs({ claimSid, sb:PairOf(claimSid) }) do
		if type(trig) == "number" then
			local links = sb:LinksFrom(trig)
			if type(links) == "table" then
				for procSid in pairs(links) do
					if type(procSid) == "number" then
						local ok, aura = pcall(find, procSid, "player", "HELPFUL")
						if ok and aura ~= nil then
							return procSid
						end
					end
				end
			end
		end
	end
	return nil
end

-- /zsbt sb + the class page read learned bindings for display.
function Collector:ProcBindings()
	return sigBindings(self)
end

consumeBestPendingCast = function(self, tNow, wantSpellId, maxWindowSec, doConsume, hitSchool)
	expirePendingCasts(self, tNow)
	-- String sids miss every == below; coerce (see enqueuePendingCast).
	wantSpellId = tonumber(wantSpellId) or wantSpellId
	local window = maxWindowSec or PENDING_CAST_WINDOW_SEC
	local bestI, best, bestDt
	local excl = ZSBT.ClassDB and ZSBT.ClassDB.ExcludedSpellId or nil
	for i = 1, #(self._pendingCasts or {}) do
		local c = self._pendingCasts[i]
		-- Excluded sids (module-denied names) never produce enemy damage,
		-- so a wound can never legitimately wear them — the record stays
		-- queued for expiry but is skipped as a match.
		if c and c.at and c.spellId
			and (excl == nil or excl(c.spellId) ~= true) then
			if (not wantSpellId) or c.spellId == wantSpellId then
				if castSchoolOk(self, c.spellId, hitSchool) then
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
	end
	if bestI then
		if doConsume == nil or doConsume == true then
			table.remove(self._pendingCasts, bestI)
			-- Per-cast-instance claim count ("sid@castAt"): the recency
			-- stamps below draw from the same budget, so a consumed cast
			-- cannot re-claim hits through the make-it-work path.
			self._castClaims = self._castClaims or {}
			local ck = tostring(best.spellId) .. "@" .. tostring(best.at)
			self._castClaims[ck] = (self._castClaims[ck] or 0) + 1
		end
		return best
	end
	return nil
end

-- Recency-stamp claim: a cast instance may name at most `budget` hits
-- total across pending-consume AND recency paths (class modules raise
-- the budget for known AoE/burst spells; default 1 for single-hit).
-- Also removes the still-queued record for that cast so it cannot be
-- consumed a second time by a later hit.
local function miwClaim(self, lastId, lastAt, t, school)
	local key = tostring(lastId) .. "@" .. tostring(lastAt)
	self._castClaims = self._castClaims or {}
	local n = self._castClaims[key] or 0
	local budget = 1
	if ZSBT.ClassDB and ZSBT.ClassDB.CastBudget then
		local b = ZSBT.ClassDB.CastBudget(lastId)
		if type(b) == "number" and b > 0 then budget = b end
	end
	if n >= budget then return nil end
	consumeBestPendingCast(self, t, lastId, nil, true, school)
	self._castClaims[key] = n + 1
	return true
end

-- Capture successful casts for downstream correlation.
-- Player casts: used for outgoing spell icons.
-- Target/enemy casts: used for incoming spell icons.
-- PLAYER_SWING (swingType, swingDuration): each player weapon swing is a
-- public report — melee and ranged. Pet/follower/teammate melee never
-- produces one, so auto-attack claims can require a matching swing.
function Collector:handlePlayerSwing(swingType)
	local t = now()
	self._swingAt = self._swingAt or {}
	local hand = "main"
	if type(swingType) == "string" and swingType ~= "" then hand = swingType end
	self._swingAt[hand] = t
	auditNote(("AUDSWING hand=%s"):format(dbgSafe(hand)))
end

-- Live module/collector state for the config UI's Class page.
function Collector:ClassModuleState()
	local prof = ZSBT.db and ZSBT.db.profile
	local learned = 0
	for _ in pairs(self._learnedSpellSchool or {}) do learned = learned + 1 end
	return {
		learnedCount = learned,
		learned = self._learnedSpellSchool,
		guardianUntil = self._guardianUntil,
		swingSupported = self._swingSupported == true,
		petCasts = self._petCasts and #self._petCasts or 0,
		pendingCasts = self._pendingCasts and #self._pendingCasts or 0,
		allowAuto = type(prof) == "table" and type(prof.classModule) == "table"
			and prof.classModule.allowAutoAttack or nil,
	}
end

function Collector:handleSpellcastSucceeded(unit, guid, spellId)
	if not spellId then return end
	-- Secret spellIds can't index tables or be compared downstream —
	-- a secret sid is useless to every correlation path, so drop early.
	if ZSBT.IsSafeNumber and not ZSBT.IsSafeNumber(spellId) then return end

	-- Pet casts are used for custom triggers (e.g. Growl), but should not
	-- participate in the player cast correlation pipeline.
	if unit == "pet" then
		local trg = ZSBT.Core and ZSBT.Core.Triggers
		if trg and trg.OnSpellcastSucceeded then
			pcall(function() trg:OnSpellcastSucceeded(unit, spellId) end)
		end
		-- Track friendly non-player casts (pet, imps, guardians) for pet-hit
		-- attribution. Also records non-pet friendly units so we can learn
		-- which unit token temporary pets cast under. Player spellbook sids
		-- are rejected: under a non-player token they can only poison the
		-- pet-cast pool (a pet scroll hit wearing a player spell's name).
		local zbtc = ZSBT.ZBattleText
		if isPlayerSpellId(spellId) then
			if zbtc and zbtc.FileLog then
				zbtc:FileLog(("PET_CAST_REJECT unit=%s sid=%s"):format(tostring(unit), tostring(spellId)))
			end
			return
		end
		self._petCasts = self._petCasts or {}
		local tCast = now()
		self._petCasts[#self._petCasts + 1] = { unit = unit, spellId = spellId, at = tCast }
		if #self._petCasts > 24 then table.remove(self._petCasts, 1) end
		if zbtc and zbtc.FileLog then
			zbtc:FileLog(("PET_CAST unit=%s sid=%s"):format(tostring(unit), tostring(spellId)))
		end
		return
	end
	-- Other friendly units (temporary pets like Wild Imps may cast under
	-- their own unit token): record them too, filtered to friends only.
	if unit ~= "player" and unit ~= "target" and UnitIsFriend then
		-- targettarget resolves to the player whenever the mob is attacking
		-- you; without this check the player's own casts land in _petCasts
		-- and petRoute can tag player damage as pet damage.
		local isPlayerAlias = false
		if UnitIsUnit then
			local okP, pres = pcall(UnitIsUnit, unit, "player")
			if okP then
				local okPC, peq = pcall(function() return pres == true end)
				if okPC and peq == true then isPlayerAlias = true end
			end
		end
		if not isPlayerAlias then
			local okF, isFriend = pcall(UnitIsFriend, "player", unit)
			if okF and isFriend == true then
				local zbtc2 = ZSBT.ZBattleText
				-- Same-class followers share our spellbook: their casts
				-- can never name pet damage, so player sids are refused.
				if isPlayerSpellId(spellId) then
					if zbtc2 and zbtc2.FileLog then
						zbtc2:FileLog(("FRIEND_CAST_REJECT unit=%s sid=%s"):format(tostring(unit), tostring(spellId)))
					end
				else
					self._petCasts = self._petCasts or {}
					local tCast2 = now()
					self._petCasts[#self._petCasts + 1] = { unit = unit, spellId = spellId, at = tCast2 }
					if #self._petCasts > 24 then table.remove(self._petCasts, 1) end
					if zbtc2 and zbtc2.FileLog then
						zbtc2:FileLog(("FRIEND_CAST unit=%s sid=%s"):format(tostring(unit), tostring(spellId)))
					end
				end
			end
		end
	end
	-- Trace casts from units we do not record (enemies, unknown tokens)
	-- so temporary-pet cast tokens can be identified. Throttled per unit.
	if unit ~= "player" and unit ~= "target" and unit ~= "pet" then
		local zc = ZSBT.ZBattleText
		if zc and zc.FileLog and ZSBT._ucDropTrace == true then
			local ck = "uccast_" .. tostring(unit)
			local ct = now()
			if ct - (self[ck] or -9) >= 0.5 then
				self[ck] = ct
				zc:FileLog(("UC_CAST unit=%s sid=%s"):format(tostring(unit), tostring(spellId)))
			end
		end
	end

	if unit == "player" then
		self._castToken = (self._castToken or 0) + 1
		self._lastPlayerSpellId = spellId
		self._lastPlayerSpellName = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or nil
		self._lastPlayerSpellAt = now()
		-- Class-module cast hooks: DK ghoul summons, Warlock channels
		-- (Drain Life/Soul), Warrior Rend tick seeding.
		if ZSBT.ClassDB and ZSBT.ClassDB.OnPlayerCast then
			ZSBT.ClassDB.OnPlayerCast(self, spellId, self._lastPlayerSpellName, self._lastPlayerSpellAt)
		end
		local dl = OutDbgLevel()
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
		-- Applicator casts: the cast id is not a dot but applies one
		-- (Primal Wrath -> Rip, Ravage -> Dreadful Wound, Starfall ->
		-- its tick sid). Seeding gives the applied sid its application
		-- records so its ticks can name. _dotAppliedAoe is only written
		-- for entries marked aoe (true multi-mob applications); single-
		-- target applicators get per-target records only.
		if ZSBT.ClassDB and ZSBT.ClassDB.DotApplicators then
			local applied = ZSBT.ClassDB.DotApplicators(spellId)
			if type(applied) == "table" then
				for _, e in ipairs(applied) do
					-- Entries are { sid, aoe=bool } or a bare sid.
					-- aoe=nil means the applicator hits only its target
					-- (Ravage -> Dreadful Wound) — per-target records,
					-- no multi-mob anchor.
					local dsid = (type(e) == "table") and e.sid or e
					if type(dsid) == "number" then
						seedDotApplication(self, dsid, self._lastPlayerSpellAt)
						if type(e) == "table" and e.aoe == true then
							self._dotAppliedAoe = self._dotAppliedAoe or {}
							self._dotAppliedAoe[dsid] = self._lastPlayerSpellAt
						end
					end
				end
			end
		end
		if isKnownPeriodicSpellId(spellId) then
			seedDotApplication(self, spellId, self._lastPlayerSpellAt)
			-- The dot's own cast is inherently AoE (Thrash, Sunfire,
			-- Starfall): it debuffs everything in range, so the cast also
			-- stands as a multi-mob application anchor.
			local castEntry = dotEntryForSpellId(spellId)
			if castEntry and castEntry.aoe == true then
				self._dotAppliedAoe = self._dotAppliedAoe or {}
				self._dotAppliedAoe[spellId] = self._lastPlayerSpellAt
			end
		end

		-- Outgoing heal-over-time seeds: a module-declared hot cast arms an
		-- attribution record. The record alone claims nothing — a HEAL on a
		-- friendly unit only emits when a filtered combat-log "hot" line
		-- (source-restricted MINE+MY_PET) proves the tick is ours and
		-- cadence names the spell (see matchOutgoingHotTick).
		if ZSBT.ClassDB and ZSBT.ClassDB.HotEntry then
			local he = ZSBT.ClassDB.HotEntry(spellId)
			if he then
				local sb = ZSBT.Spellbook
				local sbRec = sb and sb.Entry and sb:Entry(spellId) or nil
				local iv = (sbRec and type(sbRec.interval) == "number" and sbRec.interval > 0 and sbRec.interval)
					or (type(he.interval) == "number" and he.interval > 0 and he.interval)
					or HOT_DEFAULT_TICK_INTERVAL
				local dur = (type(he.duration) == "number" and he.duration > 0 and he.duration) or 15
				local recs = self._hotRecs
				if not recs then recs = {} ; self._hotRecs = recs end
				recs[spellId] = {
					appliedAt = self._lastPlayerSpellAt,
					interval = iv,
					expiresAt = self._lastPlayerSpellAt + dur + 1.5,
				}
				auditNote(("AUDHSEED sid=%s iv=%s dur=%s"):format(
					tostring(spellId), tostring(iv), tostring(dur)))
			end
		end

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
	return spellId == 1680 or spellId == 190411 or spellId == 199658
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
	local sid = st.spellId or 190411
	local tEmit = st.t or now()
	local normSum = st.normSum
	local normCount = st.normCount
	local critSum = st.critSum
	local critCount = st.critCount
	if type(normSum) ~= "number" then normSum = 0 end
	if type(normCount) ~= "number" then normCount = 0 end
	if type(critSum) ~= "number" then critSum = 0 end
	if type(critCount) ~= "number" then critCount = 0 end
	if normSum <= 0 and critSum <= 0 then return end
	if normCount <= 0 and normSum > 0 then normCount = 1 end
	if critCount <= 0 and critSum > 0 then critCount = 1 end

	-- When aggregation is enabled, keep crits and non-crits as separate aggregated
	-- lines so crit styling/routing remains accurate.
	if normSum > 0 then
		emit("OUTGOING_DAMAGE_COMBAT", {
			timestamp = tEmit,
			amount = normSum,
			amountText = tostring(math.floor(normSum + 0.5)),
			spellId = sid,
			amountSource = "UNIT_COMBAT_PHYSICAL",
			targetName = st.targetName,
			isCrit = false,
			schoolMask = 1,
			wwCount = normCount,
		})
	end
	if critSum > 0 then
		emit("OUTGOING_DAMAGE_COMBAT", {
			timestamp = tEmit,
			amount = critSum,
			amountText = tostring(math.floor(critSum + 0.5)),
			spellId = sid,
			amountSource = "UNIT_COMBAT_PHYSICAL",
			targetName = st.targetName,
			isCrit = true,
			schoolMask = 1,
			wwCount = critCount,
		})
	end
end

-- Named callback avoids allocating a new closure on every Whirlwind hit.
local function _wwFlushCallback()
	if Collector and Collector._wwAgg then
		wwAggFlush(Collector)
	end
end

local function wwAggPush(self, t, spellId, amount, isCrit, allowInfer)
	if not (self and ZSBT.IsSafeNumber(amount) and amount > 0) then return end
	self._wwAgg = self._wwAgg or {}
	local st = self._wwAgg
	st.t = st.t or t
	-- Crit inference: prefer explicit crit flag when available. If unavailable on some
	-- clients (UNIT_COMBAT may not flag crits), infer crit-like hits as ~2x the
	-- smallest observed hit in this bucket.
	local prevMin = (ZSBT.IsSafeNumber(st.minHit) and st.minHit > 0) and st.minHit or nil
	st.minHit = prevMin and math.min(prevMin, amount) or amount
	local critLike = (isCrit == true)
	if allowInfer == true and critLike ~= true and prevMin and prevMin >= 600 then
		-- Use a conservative threshold to reduce false positives from off-hand variance.
		if amount >= (prevMin * 1.75) and amount >= (prevMin + 250) then
			critLike = true
		end
	end
	if critLike == true and isCrit ~= true then
		local dl = OutDbgLevel()
		if dl >= 5 then
			ECPrint(("WW_CRIT_INFER token=%s spellId=%s amt=%s prevMin=%s")
				:format(dbgSafe(self._castToken), dbgSafe(spellId), dbgSafe(amount), dbgSafe(prevMin)))
		end
	end
	if critLike == true then
		st.critSum = (st.critSum or 0) + amount
		st.critCount = (st.critCount or 0) + 1
	else
		st.normSum = (st.normSum or 0) + amount
		st.normCount = (st.normCount or 0) + 1
	end
	st.targetName = st.targetName or safeUnitName("target")
	st.token = st.token or self._castToken
	st.spellId = st.spellId or spellId
	if st.timer and st.timer.Cancel then
		pcall(function() st.timer:Cancel() end)
	end
	local win = wwAggWindowSec(spellId)
	if C_Timer and C_Timer.NewTimer then
		st.timer = C_Timer.NewTimer(win, _wwFlushCallback)
	elseif C_Timer and C_Timer.After then
		st.timer = nil
		C_Timer.After(win, _wwFlushCallback)
	end
end

local function dbgChatPush(self, row)
	if not self then return nil end
	local dl = OutDbgLevel()
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
	local dl = OutDbgLevel()
	local quietMode = isQuietOutgoingWhenIdle()

	-- In instances, some clients can mark chat combat messages as secret/unsafe.
	-- We still want outgoing numbers when "Your ..." messages are available, but we
	-- must avoid comparing/printing secret strings. For unsafe messages, use a
	-- minimal parser: extract the amount and attribute it to the most recent cast.
	if not isSafeMsg then
		-- Secret payloads: string APIs may reject secret strings on some
		-- clients/builds. Probe once; bail cleanly rather than error per-event.
		local okFind, findRes = pcall(function() return msg:find("Your ", 1, true) == 1 end)
		if not okFind or findRes ~= true then
			return
		end
		local tNow = now()
		local token = self._castToken
		if not token or not self._lastPlayerSpellAt or not self._lastPlayerSpellId then
			return
		end
		if ZSBT.ClassDB and ZSBT.ClassDB.ExcludedSpellId
			and ZSBT.ClassDB.ExcludedSpellId(self._lastPlayerSpellId) then
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
		local okMatch, amountText = pcall(function() return msg:match("(%d[%d,]*)") end)
		local amount = nil
		if okMatch and amountText then
			local okAmt, resAmt = pcall(parseAmountFromChat, amountText)
			amount = okAmt and resAmt or nil
		end
		-- If the parse yielded a secret value we cannot compare it — bail.
		if not amount or (ZSBT.IsSafeNumber and not ZSBT.IsSafeNumber(amount)) or amount <= 0 then
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
		local okCrit, isCrit = pcall(isCritChatMessage, msg)
		isCrit = okCrit and isCrit == true
		if isWhirlwindSpellId(self._lastPlayerSpellId) and wwAggEnabled(self._lastPlayerSpellId) then
			self._wwAggChatToken = token
			self._wwAggChatAt = tNow
			wwAggPush(self, tNow, self._lastPlayerSpellId, amount, isCrit, false)
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
		if arePetsEnabled() ~= true then
			return
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
					local tNowPet = now()
					local lastFb = self._lastPetFallbackAt or 0
					local isDup = (tNowPet - lastFb) >= 0 and (tNowPet - lastFb) < PET_OUTGOING_DEDUP_WINDOW
					if not isDup then
						self._lastPetChatAt = tNowPet
						self._lastPetChatAmount = amt
						local isCrit2 = (msg:find("crits", 1, true) ~= nil) or (msg:find("critically", 1, true) ~= nil)
						local pipeId = self._rawPipeCount + 1
						self._rawPipeCount = pipeId
						self._rawPipe[pipeId] = amt
						emit("PET_DAMAGE_COMBAT", {
							timestamp = tNowPet,
							rawPipeId = pipeId,
							isCrit = isCrit2,
							schoolMask = nil,
							targetName = pTarget,
						})
					end
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
							local tNowPet = now()
							local lastFb = self._lastPetFallbackAt or 0
							local isDup = (tNowPet - lastFb) >= 0 and (tNowPet - lastFb) < PET_OUTGOING_DEDUP_WINDOW
							if not isDup then
								local isCrit3 = (msg:find("Critical", 1, true) ~= nil) or (msg:find("CRITICAL", 1, true) ~= nil)
								local pipeId = self._rawPipeCount + 1
								self._rawPipeCount = pipeId
								self._rawPipe[pipeId] = amt2
								self._lastPetChatAt = tNowPet
								self._lastPetChatAmount = amt2
								emit("PET_DAMAGE_COMBAT", {
									timestamp = tNowPet,
									rawPipeId = pipeId,
									isCrit = isCrit3,
									schoolMask = nil,
									targetName = petTarget2,
								})
							end
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
	if ZSBT.ClassDB and ZSBT.ClassDB.ExcludedSpellId
		and ZSBT.ClassDB.ExcludedSpellId(self._lastPlayerSpellId) then
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
	local isCrit = isCritChatMessage(msg)
	if isWhirlwindSpellId(self._lastPlayerSpellId) and wwAggEnabled(self._lastPlayerSpellId) then
		-- If Whirlwind aggregation is enabled, funnel addon-readable chat hits into the
		-- same aggregation bucket and suppress per-hit emits (prevents duplicates/crit routing).
		self._wwAggChatToken = token
		self._wwAggChatAt = tNow
		wwAggPush(self, tNow, self._lastPlayerSpellId, amount, isCrit, false)
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
	if ZSBT.IsSafeNumber then
		-- Some clients/builds may return the spellId in different slots depending on token.
		-- Only trust values that are already safe numbers.
		if ZSBT.IsSafeNumber(rawArg3) then
			ctSpellId = rawArg3
		elseif ZSBT.IsSafeNumber(rawArg2) then
			ctSpellId = rawArg2
		end
	end

	-- The amount is rawArg1 for most event types.
	-- We pass it RAW to the display layer via the raw pipe.
	local rawAmount = rawArg1

	-- High-signal trace: confirm COMBAT_TEXT_UPDATE is firing and what tokens
	-- the client is using for event type.
	local dl = OutDbgLevel()
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
		if OutDbgLevel() >= 3 then
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
			outgoingSpellId = pickDotForWound(self, tNow, school, rawAmount, isCrit)
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
			-- COMBAT_TEXT_UPDATE fires for nearby combat text — foreign hits
			-- on other units included — so only accept it as incoming when the
			-- player is plausibly the victim. UnitAffectingCombat cannot be
			-- trusted (it can stick true), so corroborate with evidence that
			-- cannot lie: our health dropped, or we are actively fighting
			-- (recent cast or outgoing wounds on our target). Standing AFK
			-- near a dummy fight satisfies neither.
			local ctOK = false
			local hNowCT = UnitHealth and UnitHealth("player")
			local hPrevCT = self._lastHealth and self._lastHealth["player"]
			if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(hNowCT) and ZSBT.IsSafeNumber(hPrevCT) and hNowCT < hPrevCT then
				ctOK = true
			elseif (tNow - (self._lastPlayerSpellAt or 0)) <= 4
				or (tNow - (self._lastTargetWoundAt or 0)) <= 4
			then
				ctOK = true
			end
			if not ctOK then
				local zCt = ZSBT.ZBattleText
				if zCt and zCt.FileLog and ZSBT._ucDropTrace == true then
					zCt:FileLog(("CTDROPPED t=%.3f why=no_victim_evidence")
						:format(tNow))
				end
				return
			end
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

		-- Optional: suppress healer names on incoming heals. Some clients
		-- return a formatted combat-text string containing the healer's
		-- name instead of a bare amount. Clean strings can be reduced to
		-- their numeric portion; secret strings cannot be inspected, so we
		-- skip this event BEFORE stamping _lastCombatTextHealAt — otherwise
		-- the UNIT_COMBAT heal dedup window would suppress the nameless
		-- UNIT_COMBAT heal fallback and the heal would not display at all.
		local pipeAmount = rawAmount
		local healCfg = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.incoming
			and ZSBT.db.profile.incoming.healing
		if healCfg and healCfg.showHealerNames == false and type(rawAmount) == "string" then
			if ZSBT.IsSafeString(rawAmount) then
				local numStr
				for tok in rawAmount:gmatch("[%d%,%.]+") do numStr = tok end
				local n = numStr and tonumber((numStr:gsub(",", "")))
				if ZSBT.IsSafeNumber(n) then
					pipeAmount = n
				else
					return
				end
			else
				return
			end
		end

		self._lastCombatTextHealAt = now()

		local pipeId = self._rawPipeCount + 1
		self._rawPipeCount = pipeId
		self._rawPipe[pipeId] = pipeAmount
		local numAmount, amountText, secret = nil, nil, false
		if type(launderAmount) == "function" then
			numAmount, amountText, secret = launderAmount(pipeAmount)
		else
			if ZSBT.IsSafeNumber(pipeAmount) then
				numAmount = pipeAmount
				amountText = tostring(math.floor(pipeAmount + 0.5))
			else
				local okS, s = pcall(tostring, pipeAmount)
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
		if ZSBT.IsSafeNumber(pipeAmount) then
			local curHealth = UnitHealth and UnitHealth("player")
			local maxHealth = UnitHealthMax and UnitHealthMax("player")
			if ZSBT.IsSafeNumber(curHealth) and ZSBT.IsSafeNumber(maxHealth) and maxHealth > 0 then
				-- Post-heal: if at max, some healing was wasted
				if curHealth >= maxHealth then
					-- Pre-heal health was: current - effective_heal
					-- effective_heal = pipeAmount - overheal
					-- But at max: effective_heal = maxHealth - preHealth
					-- And preHealth = curHealth - effective_heal = maxHealth - effective_heal
					-- So: pipeAmount = effective + overheal
					--     effective = maxHealth - preHealth
					-- We know preHealth from snapshot OR estimate:
					local preHealth = self._lastHealth and self._lastHealth["player"]
					if ZSBT.IsSafeNumber(preHealth) and preHealth < maxHealth then
						local deficit = maxHealth - preHealth
						overheal = pipeAmount - deficit
						if overheal < 0 then overheal = nil end
					else
						-- No pre-health snapshot: assume full overheal if at max
						-- This is conservative — may overcount slightly
						overheal = pipeAmount
					end
				end
				-- Update health snapshot for next calculation
				self._lastHealth = self._lastHealth or {}
				self._lastHealth["player"] = curHealth
			end
		end

		local zC = ZSBT.ZBattleText
		if zC and zC.FileLog then
			zC:FileLog(("CT_HEAL sid=%s per=%s"):format(tostring(healSpellId), tostring(isPeriodic == true)))
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
		local zM = ZSBT.ZBattleText
		if zM and zM.FileLog then
			zM:FileLog(("MISS_EMIT type=%s"):format(tostring(arg1)))
		end
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
		local numAmount, amountText, secret = nil, nil, false
		if type(launderAmount) == "function" then
			numAmount, amountText, secret = launderAmount(rawAmount)
		end
		emit("COMBAT_TEXT_HONOR", {
			timestamp = now(),
			rawPipeId = pipeId,
			amount = numAmount,
			amountText = amountText,
			isSecret = secret,
		})
		return
	end

	-- XP gains
	if arg1 == "COMBAT_XP_GAIN" then
		local pipeId = self._rawPipeCount + 1
		self._rawPipeCount = pipeId
		self._rawPipe[pipeId] = rawAmount
		local numAmount, amountText, secret = nil, nil, false
		if type(launderAmount) == "function" then
			numAmount, amountText, secret = launderAmount(rawAmount)
		end
		emit("COMBAT_TEXT_XP", {
			timestamp = now(),
			rawPipeId = pipeId,
			amount = numAmount,
			amountText = amountText,
			isSecret = secret,
		})
		return
	end

	-- Reputation gains
	if arg1 == "FACTION" then
		local pipeId = self._rawPipeCount + 1
		self._rawPipeCount = pipeId
		self._rawPipe[pipeId] = rawAmount
		local numAmount, amountText, secret = nil, nil, false
		if type(launderAmount) == "function" then
			numAmount, amountText, secret = launderAmount(rawAmount)
		end
		emit("COMBAT_TEXT_REP", {
			timestamp = now(),
			rawPipeId = pipeId,
			amount = numAmount,
			amountText = amountText,
			isSecret = secret,
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
Collector._lastAutoOutgoingAt = Collector._lastAutoOutgoingAt or 0
local OUTGOING_HEALTH_DEDUP_WINDOW = 0.12
-- White swings (isAuto / spellId == nil) can be reported through both the
-- physical and non-physical UNIT_COMBAT branches in the same tick because the
-- school field is unreliable on Midnight. Auto-attack swing timers cannot go
-- below ~0.5s even with haste and autos cannot cleave, so a short window only
-- collapses duplicate reports of the same swing.
local AUTO_OUTGOING_DEDUP_WINDOW = 0.35
-- Pet outgoing can be reported by multiple sources for the same swing:
-- UNIT_COMBAT("target") fallback (sometimes delivered twice), chat
-- "Your pet hits" lines, and the DK guardian path. Pet attack speed cannot
-- go below ~0.5s, so a short window only collapses duplicate reports.
local PET_OUTGOING_DEDUP_WINDOW = 0.35

-- Detect incoming player damage/healing from UNIT_COMBAT.
-- In 12.0, the `action` string arg may be tainted. Rather than checking
-- action == "WOUND", we emit all UNIT_COMBAT events for "player" that
-- have a non-nil amount and let downstream consumers categorize by context.
-- UNIT_COMBAT only fires for: WOUND, HEAL, BLOCK, DODGE, PARRY, RESIST, etc.
-- Only WOUND and HEAL carry meaningful amounts.
-- Trace units that UNIT_COMBAT reports but the outgoing pipeline cannot
-- use (non-target nameplates, party/boss tokens, etc.). Minion/pet damage
-- may arrive under tokens we currently drop silently; this makes them
-- visible in the ucdrop log. Throttled per unit to bound spam.
function Collector:_dbgDropUnit(unit)
	local z = ZSBT.ZBattleText
	if not (z and z.FileLog) then return end
	if ZSBT._ucDropTrace ~= true then return end
	local key = "ucunit_" .. tostring(unit)
	local t = now()
	if t - (Collector[key] or -9) < 0.5 then return end
	Collector[key] = t
	-- Unit predicates/names can be secret on Retail: probe each inside
	-- its own pcall and report "secret" rather than killing the event.
	local function probeBool(fn, ...)
		local ok, res = pcall(fn, ...)
		if not ok then return "err" end
		local ok2, eq = pcall(function() return res == true end)
		if not ok2 then return "secret" end
		return tostring(res)
	end
	local hostile = "?"
	if UnitCanAttack then hostile = probeBool(UnitCanAttack, "player", unit) end
	local istarget = "?"
	if UnitIsUnit then istarget = probeBool(UnitIsUnit, unit, "target") end
	local uname = "?"
	if UnitName then
		local okN, n = pcall(UnitName, unit)
		if okN and ZSBT.IsSafeString(n) then uname = n end
	end
	z:FileLog(("UC_UNIT unit=%s hostile=%s istarget=%s name=%s"):format(
		tostring(unit), hostile, istarget, tostring(uname)))
end

function Collector:handleUnitCombat(unit, action, descriptor, amount, school)
	-- ucdrop raw trace: log every UNIT_COMBAT event shape so we can see
	-- what Retail actually delivers for target/minion damage (secret
	-- actions, nil amounts, non-WOUND verbs). Throttled per unit.
	do
		local z = ZSBT.ZBattleText
		if z and z.FileLog and ZSBT._ucDropTrace == true then
			local key = "ucraw_" .. tostring(unit)
			local tt = now()
			if tt - (Collector[key] or -9) >= 0.4 then
				Collector[key] = tt
				local aType = type(action)
				local aPrev = (aType == "string" and ZSBT.IsSafeString and ZSBT.IsSafeString(action)) and action or aType
				z:FileLog(("UC_RAW unit=%s action=%s amtNil=%s amtT=%s descT=%s school=%s"):format(
					tostring(unit), tostring(aPrev), tostring(amount == nil),
					tostring(type(amount)), tostring(type(descriptor)), tostring(school)))
			end
		end
	end
	-- Midnight (12.0+): UNIT_COMBAT does not fire for the "target" unit token on some
	-- clients (confirmed via debug: only UNIT_COMBAT_PLAYER lines appear). It DOES fire
	-- for nameplate tokens (nameplate1..nameplateN) when a nameplated unit takes damage.
	-- The addon already receives these (RegisterEvent("UNIT_COMBAT") is unit-wide) but
	-- previously dropped them here. If a nameplate token refers to the player's current
	-- target, remap it to "target" so the existing outgoing pipeline handles the hit.
	if unit ~= "player" and unit ~= "target" and unit ~= "pet" then
		-- Outgoing heal-over-time ticks land on the healed unit's token
		-- (partyN/raidN/focus/targettarget...) — never "target" — and were
		-- dropped wholesale below. A HEAL here only emits when a
		-- cast-seeded hot record is live AND the unit verifiably carries
		-- the player's own HoT aura; follower heals on the same unit pass
		-- neither gate and drop as before.
		do
			local aH = (ZSBT.IsSafeString and ZSBT.IsSafeString(action)) and action or nil
			-- Readable action is required: every real heal UC — direct
			-- AND periodic — reports action="HEAL" on this build. The
			-- aH == nil candidacy accepted damage-class amount events
			-- (the ~1s-cadence AUDCAND stream on friendly tokens), which
			-- queued as pending heals, stole the next real heal's
			-- combat-text line, and emitted a WOUND amount as a heal —
			-- the phantom "second tick".
			if aH == "HEAL" and amount ~= nil then
				local tH = now()
				local hsid, hPeriodic, why = matchOutgoingHotTick(self, unit, tH)
				if hsid == nil then
					if why == "noline" then
						local isCritQ = false
						if type(descriptor) == "string" and descriptor:upper():find("CRIT", 1, true) then
							isCritQ = true
						end
						queuePendingHotHeal(self, unit, tH, amount, school, isCritQ)
					else
						auditNote(("AUDHX unit=%s why=%s"):format(dbgSafe(unit), tostring(why)))
					end
				end
				if hsid ~= nil then
					local isCritH = false
					if type(descriptor) == "string" and descriptor:upper():find("CRIT", 1, true) then
						isCritH = true
					end
					local pipeId = self._rawPipeCount + 1
					self._rawPipeCount = pipeId
					self._rawPipe[pipeId] = amount
					auditNote(("AUDH unit=%s sid=%s"):format(dbgSafe(unit), tostring(hsid)))
					emit("OUTGOING_HEAL_COMBAT", {
						timestamp = tH,
						rawPipeId = pipeId,
						amountText = (ZSBT.IsSafeNumber(amount) and tostring(amount)) or nil,
						spellId = hsid ~= 0 and hsid or nil,
						targetName = safeUnitName(unit),
						isCrit = isCritH,
						isPeriodic = hPeriodic == true or nil,
						schoolMask = ZSBT.IsSafeNumber(school) and school or nil,
					})
					return
				end
			end
		end
		-- "softenemy" is Retail's soft-target enemy token: UnitIsUnit confirms
		-- it is the player's target, but the token itself is not "target", so
		-- its UNIT_COMBAT events were being dropped wholesale.
		if type(unit) == "string" and (unit:match("^nameplate%d+$") or unit == "softenemy") then
			local isTarget = false
			if UnitIsUnit then
				local okU, res = pcall(UnitIsUnit, unit, "target")
				-- res can be a secret boolean on Retail: compare inside pcall
				-- so a secret result cannot kill the whole UNIT_COMBAT event.
				if okU then
					local okC, eq = pcall(function() return res == true end)
					if okC and eq == true then isTarget = true end
				end
			end
			if isTarget then
				local dl = OutDbgLevel()
				if dl >= 4 then
					local tNow = now()
					if (tNow - (Collector._dbgLastNameplateRemapAt or 0)) > 0.25 then
						Collector._dbgLastNameplateRemapAt = tNow
						ECPrint(("NAMEPLATE_REMAP unit=%s action=%s amt=%s school=%s -> target")
							:format(dbgSafe(unit), dbgSafe(action), dbgSafe(amount), dbgSafe(school)))
					end
				end
				unit = "target"
			else
				-- Not the current target. On Retail group content the target's own
				-- UNIT_COMBAT may never fire under an accepted token while hostile
				-- nameplates/softenemy keep reporting WOUNDs with amounts. When the
				-- ZBattleText veto is live, offer these as generic unattributed
				-- candidates: OfferOutgoing still requires a nearby palette line,
				-- and our filter only contains player+pet sources, so other
				-- players' damage on the same mobs cannot pair and drops safely.
				-- No cast/dot attribution is attempted — off-target hits cannot be
				-- identified, so they emit spellId=nil (pet-routed when a recent
				-- friendly cast exists).
				local emitted = false
				-- Only offer UNATTRIBUTED off-target hits while the target token
				-- itself has stopped reporting WOUNDs (~1.5s). When target events
				-- flow normally, hostile nameplate traffic is almost always
				-- foreign or redundant cleave and stays out of the pipe entirely.
				-- A wound with a DoT application record on this nameplate is
				-- different: the mob's own cast evidence names it, so it emits
				-- attributed regardless of the starve window.
				local tgtStarved = (now() - (self._lastTargetWoundAt or 0)) > 1.5
				if zbtVetoActive() and amount ~= nil then
					local aStr = (ZSBT.IsSafeString and ZSBT.IsSafeString(action)) and action or nil
					if aStr == "WOUND" then
						local hostile = false
						if UnitCanAttack then
							local okH, h = pcall(UnitCanAttack, "player", unit)
							if okH then
								local okC, eq = pcall(function() return h == true end)
								if okC and eq == true then hostile = true end
							end
						end
						if hostile then
							local offSid = nil
							local offSidIsDot = false
							local offTgtName = safeUnitName(unit)
							if offTargetDotsEnabled() then
								offSid = resolveOffTargetDot(self, unit, now(), school)
								offSidIsDot = offSid ~= nil
							end
							-- Cleave fan-out: one cast wounds every mob in
							-- range, but only the target's wound can cast-
							-- match. A nameplate wound school-matching a
							-- recent cast AND backed by an unconsumed
							-- "direct" MINE line is our AoE hit — the
							-- combat log emits one direct line per target
							-- struck, so claims self-limit to the real hit
							-- count. The shared sid@castAt budget bounds
							-- over-naming; consumed casts fall back to the
							-- recency stamp (same key).
							if offSid == nil then
								local tOff = now()
								local cand, candAt = nil, nil
								local bestDt = nil
								for _, c in ipairs(self._pendingCasts or {}) do
									if c and c.at and c.spellId then
										local dt = tOff - c.at
										if dt >= 0 and dt <= 0.5
											and castSchoolOk(self, c.spellId, school)
											and (not bestDt or dt < bestDt) then
											bestDt = dt
											cand, candAt = c.spellId, c.at
										end
									end
								end
								if cand == nil then
									local lastId, lastAt = self._lastPlayerSpellId, self._lastPlayerSpellAt
									if type(lastId) == "number" and type(lastAt) == "number"
										and (tOff - lastAt) >= 0 and (tOff - lastAt) <= 0.5
										and castSchoolOk(self, lastId, school) then
										cand, candAt = lastId, lastAt
									end
								end
								if cand ~= nil then
									local zbt = ZSBT.ZBattleText
									if zbt and zbt.PeekDamageLine
										and zbt:PeekDamageLine(tOff, 0.35, { direct = true }) then
										local ck = tostring(cand) .. "@" .. tostring(candAt)
										self._castClaims = self._castClaims or {}
										local n = self._castClaims[ck] or 0
										local budget = 1
										if ZSBT.ClassDB and ZSBT.ClassDB.CastBudget then
											local b = ZSBT.ClassDB.CastBudget(cand)
											if type(b) == "number" and b > 0 then budget = b end
										end
										if n < budget then
											self._castClaims[ck] = n + 1
											offSid = cand
										end
									end
								end
							end
							if offSid ~= nil or tgtStarved then
								if offSid == nil then
									-- In instances another attacker is guaranteed —
									-- but v2 lines can still prove off-target pet
									-- AoE (MY_PET class) and veto foreign cleave
									-- (FLIN). Queue for arbitration instead of the
									-- blanket instance drop. Named off-target DoT
									-- ticks (offSid ~= nil) still pass through.
									local instOff = false
									if IsInInstance then
										local okI, resI = pcall(IsInInstance)
										if okI and resI == true then instOff = true end
									end
									if instOff then
										dbgDrop("BYPASS_OFFT_INST", self._castToken, school)
									end
									-- An unattributed off-target hit can only be
									-- ours if we are actually fighting. With no
									-- combat of our own, nameplate traffic from
									-- nearby players' fights streamed straight
									-- into the scroll through the cold-feed
									-- delivery (no lines yet = unconditional
									-- queue delivery). DoT-recorded hits are
									-- named/provable and skip this.
									-- "In combat" is not enough — a ticking DoT or a
									-- stale flag keeps it set while nothing of ours is
									-- actually swinging. An unattributed off-target hit
									-- can only be our cleave/AoE when we cast or swung
									-- very recently; otherwise it is foreign traffic
									-- stealing lingering filtered lines.
									local ownActive = false
									do
										local lastCast = self._lastPlayerSpellAt
										if type(lastCast) == "number"
											and (now() - lastCast) >= 0
											and (now() - lastCast) <= 2.0 then
											ownActive = true
										end
									end
									if not ownActive and UnitAffectingCombat then
										local okC, res = pcall(UnitAffectingCombat, "player")
										if okC and res == true
											and (now() - (self._lastTargetWoundAt or 0)) <= 2.0 then
											ownActive = true
										end
									end
									if not ownActive then
										dbgDrop("OFFT_NOCOMBAT", self._castToken, school)
										return
									end
									-- Unattributed off-target hits are contested too:
									-- a burst of foreign cleave/AoE on shared mobs is
									-- exactly the traffic that steals filtered lines.
									if autoContested(self, now(), false) then
										dbgDrop("CONTESTED_OFFT", self._castToken, school)
										return
									end
								end
								local isCritOff = false
								if type(descriptor) == "string" then
									isCritOff = descriptor:upper():find("CRIT", 1, true) ~= nil
								end
								if offSidIsDot then
									self._recentPeriodicSpellAt[offSid] = now()
									noteDotTickAmount(self, offSid, amount, isCritOff, now(), offTgtName)
								end
								local pipeId = self._rawPipeCount + 1
								self._rawPipeCount = pipeId
								self._rawPipe[pipeId] = amount
								local zbtOff = ZSBT.ZBattleText
								if zbtOff and zbtOff.FileLog then
									zbtOff:FileLog(("OFFT unit=%s sid=%s school=%s"):format(
										tostring(unit), tostring(offSid), tostring(school)))
								end
								emit("OUTGOING_DAMAGE_COMBAT", {
									timestamp = now(),
									rawPipeId = pipeId,
									spellId = offSid,
									amountSource = "COMBAT_LOG",
									targetName = offTgtName,
									isCrit = isCritOff,
									isPeriodic = offSidIsDot or nil,
									schoolMask = (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school)) and school or nil,
								})
								emitted = true
							end
						end
					end
				end
				if not emitted then
					self:_dbgDropUnit(unit)
				end
			return
			end
		else
			self:_dbgDropUnit(unit)
			return
		end
	end

	-- Stamp when UNIT_COMBAT reports a WOUND on the resolved target token.
	-- The OFFT (off-target) fallback only emits while this goes stale, so
	-- normal target reporting keeps foreign nameplate hits out of the pipe.
	if unit == "target" then
		local aW = (ZSBT.IsSafeString and ZSBT.IsSafeString(action)) and action or nil
		if aW == "WOUND" then
			self._lastTargetWoundAt = now()
		end
	end
	if amount == nil then return end
	-- UNIT_COMBAT may emit ABSORB/blocked-style entries with amount==0.
	-- These are not actual damage/heal events and must be ignored to prevent
	-- false incoming spam (especially in WoW 12.0 where attribution is limited).
	-- Secret amounts hide the same zeros — evaluate C-side; only proven
	-- zeros are dropped (untestable secrets keep their slot).
	local isZeroAmt = ZSBT.DisplayAmountIsZero and ZSBT.DisplayAmountIsZero(amount)
	-- When the secret cannot be evaluated at all (opaque KString on this
	-- client), fall back to the safe school discriminator: the absorb-style
	-- pseudo-entries report school == 0 while real wounds always carry a
	-- school >= 1. Only fires for non-safe amounts — a safe nonzero amount
	-- is trusted regardless of what school rides beside it.
	if isZeroAmt ~= true
		and not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(amount))
		and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school) and school == 0 then
		isZeroAmt = true
	end
	if isZeroAmt == true then
		local zbtZ = ZSBT.ZBattleText
		if zbtZ and zbtZ.FileLog then
			zbtZ:FileLog(("ZERO_DROP unit=%s school=%s"):format(tostring(unit), tostring(school)))
		end
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
		if arePetsEnabled() ~= true then
			return
		end
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
		-- Context-tiered ownership (CLAUDE.md masterplan): while the
		-- combat-log veto is live it is the ownership proof and restrict
		-- adds nothing; when the feed is dead, context auto-engages the
		-- conservative fallback — solo stays permissive, group/instance/PvP
		-- restricts unattributed hits so foreign damage cannot bleed in.
		local tier = (ZSBT.Core and ZSBT.Core.OutgoingStrictnessTier
			and ZSBT.Core:OutgoingStrictnessTier()) or "live"
		local autoRestrict = (ZSBT.Core and ZSBT.Core.IsAutoRestrictActive
			and ZSBT.Core:IsAutoRestrictActive())
			or (ZSBT.Core and ZSBT.Core.ShouldRestrictOutgoingFallback
				and ZSBT.Core:ShouldRestrictOutgoingFallback()) or false
		local quietMode = isQuietOutgoingWhenIdle()
		-- Legacy explicit-strict keys (pre-migration compat) plus the new
		-- "Require combat-log proof" toggle: an enabled strict toggle still
		-- forces restrict even while the veto is live.
		local legacyStrict = isPvPStrictActive()
			or isStrictOutgoingCombatLogOnly()
			or quietMode == true
			or (ZSBT.Core and ZSBT.Core.IsRequireProofEnabled
				and ZSBT.Core:IsRequireProofEnabled())
		local restrict = autoRestrict or legacyStrict
		local instanceAware = restrict
			or (ZSBT.Core and ZSBT.Core.IsInstanceAwareOutgoingEnabled
				and ZSBT.Core:IsInstanceAwareOutgoingEnabled()) or false
		auditNote(("AUDT tier=%s restrict=%s"):format(
			tostring(tier), tostring(restrict == true)))
		-- If combat text / chat already produced an outgoing number for the current cast
		-- token, suppress UNIT_COMBAT(target) for that token to avoid double numbers.
		if self._castToken and self._lastCombatTextOutgoingToken == self._castToken then
			-- Exception: pet outgoing fallback can also use UNIT_COMBAT(target) on some
			-- clients. Do not suppress the entire UNIT_COMBAT(target) handler when pets
			-- are enabled and the pet is currently fighting and the player isn't actively
			-- casting (i.e., this cannot be a duplicate of the player's cast).
			local allowPetFallback = false
			if arePetsEnabled() == true and UnitAffectingCombat and UnitExists then
				local okEx, hasPet = pcall(UnitExists, "pet")
				if okEx and hasPet == true then
					local okPet, inPetCombat = pcall(UnitAffectingCombat, "pet")
					if okPet and inPetCombat == true then
						local tNow = now()
						local lastAt = self._lastPlayerSpellAt
						local recentPlayerCast = false
						if type(lastAt) == "number" then
							local age = tNow - lastAt
							if age >= 0 and age <= 1.0 then
								recentPlayerCast = true
							end
						end
						if not recentPlayerCast then
							allowPetFallback = true
						end
					end
				end
			end
			if not allowPetFallback then
				return
			end
		end
		local inInst = false
		local members = 0
		if type(GetNumGroupMembers) == "function" then
			local okM, m = pcall(GetNumGroupMembers)
			if okM and type(m) == "number" then members = m end
		end
		if IsInInstance then
			local okI, inst = pcall(IsInInstance)
			if okI and inst == true then
				inInst = true
				-- Inside instances, UNIT_COMBAT("target") has no source attribution and can
				-- easily pick up follower/party damage.
				if instanceAware == true then
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
						local recentlyCast = (type(lastAt) == "number" and (tNow - lastAt) >= 0 and (tNow - lastAt) <= 0.90)
						if not recentlyCast then
							-- Exception: periodic damage can tick well after the cast and we'd still like
							-- to show *player* DoTs without opening the door to follower/party damage.
							-- Allow the pipeline only when we can correlate to a very recent periodic spell.
							local dotSpellId = getMostRecentPeriodicSpellId and getMostRecentPeriodicSpellId(self, tNow) or nil
							local okDot = false
							if dotSpellId and self._recentPeriodicSpellAt and type(self._recentPeriodicSpellAt[dotSpellId]) == "number" then
								local age = tNow - (self._recentPeriodicSpellAt[dotSpellId] or 0)
								if age >= 0 and age <= (PERIODIC_OUTGOING_WINDOW_SEC or 8.0) then
									okDot = true
								end
							end
							if not okDot then
								-- ZBattleText veto-aware bypass: when the trusted palette feed is
								-- live, OfferOutgoing still requires a nearby combat-log line,
								-- so unattributed hits can flow as candidates instead of dying
								-- here during the idle window after the opener's cast ages out.
								if not zbtVetoActive() then
									dbgDrop("INST_GATE", self._castToken, school)
									return
								end
							end
						end
					end
				end
			end
		end
		local dl = OutDbgLevel()
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
		if actionStr == "WOUND" then
			-- Same hit reported through a second unit token (target /
			-- softenemy / nameplate remap) arrives within a frame or two.
			-- Collapse exact school+crit twins inside 50ms so duplicates
			-- cannot steal palette lines from distinct hits. Only dedups
			-- safe-number schools; secret schools always pass through.
			-- Amount joins the signature whenever it is safe (Forever's
			-- amounts are readable; Retail's are secret) — a re-report is
			-- identical in every field, while two genuinely distinct hits
			-- sharing school+crit (Judgement + Holy Strike) almost always
			-- differ in amount and must not collapse.
			if ZSBT.IsSafeNumber(school) then
				local amtSig = (ZSBT.IsSafeNumber(amount) and amount) or nil
				local sig = self._lastTargetWoundSig
				if sig and (t - sig.t) >= 0 and (t - sig.t) < 0.05
					and sig.school == school and sig.crit == isCrit
					and sig.amount == amtSig then
					auditNote(("AUDTWIN school=%s crit=%s amt=%s"):format(
						dbgSafe(school), tostring(isCrit == true), dbgSafe(amount)))
					return
				end
				self._lastTargetWoundSig = { t = t, school = school, crit = isCrit, amount = amtSig }
			end
			local zbtc = ZSBT.ZBattleText
			if zbtc and zbtc.FileLog then
				zbtc:FileLog(("CAND school=%s crit=%s"):format((ZSBT.IsSafeNumber(school) and tostring(school)) or "sec", tostring(isCrit == true)))
			end
			if not self._auditCapNoted then
				self._auditCapNoted = true
				auditNote(("AUDCAP swing=%s"):format(tostring(self._swingSupported == true)))
			end
			auditNote(("AUDCAND school=%s crit=%s"):format(
				(ZSBT.IsSafeNumber(school) and tostring(school)) or "sec", tostring(isCrit == true)))
		elseif actionStr then
			-- Same non-damage event (HEAL, MISS/DODGE/PARRY/...) reported through
			-- a second unit token (target + nameplate remap) in the same frame.
			-- Damage dedups via _lastTargetWoundSig; these actions emit
			-- immediately downstream, so collapse same-action twins here.
			local sig = self._lastTargetActionSig
			if sig and (t - sig.t) >= 0 and (t - sig.t) < 0.05
				and sig.action == actionStr then
				return
			end
			self._lastTargetActionSig = { t = t, action = actionStr }
		end
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
			local petsEnabled = (arePetsEnabled() == true)
			local okEx, hasPet = pcall(UnitExists, "pet")
			if petsEnabled ~= true then
				if dl >= 4 and ZSBT.IsSafeNumber(amount) and amount > 0 and (not isPhysicalEarly) and (ZSBT.IsSafeNumber(school) and school == 4) then
					ECPrint(("PET_FALLBACK_SKIP petsEnabled=0 token=%s amt=%s school=%s")
						:format(dbgSafe(self._castToken), dbgSafe(amount), dbgSafe(school)))
				end
			elseif okEx and hasPet == true then
				local okPet, inPetCombat = pcall(UnitAffectingCombat, "pet")
				if okPet and inPetCombat == true then
					local recentPlayerCast = false
					if self._lastPlayerSpellAt then
						local age = t - (self._lastPlayerSpellAt or 0)
						local maxAge = (restrict == true) and 0.90 or 1.25
						-- Non-physical spells (e.g. Shadow Bolt) can have longer travel times,
						-- so allow a longer window before treating target WOUND events as pet damage.
						if not (ZSBT.IsSafeNumber(school) and school == 1) then
							maxAge = math.max(maxAge, 2.50)
						end
						if age >= 0 and age <= maxAge then
							recentPlayerCast = true
						end
					end
					-- General safety: if the hit's school strongly suggests it's pet damage for this
					-- class, don't let the player's recent-cast window hijack it.
					if isLikelyPetSchoolHitGivenRecentPlayerSpell(self, school, self._lastPlayerSpellId) then
						recentPlayerCast = false
					end
					-- DoT ticks can arrive long after the cast and look like small magic WOUND
					-- events. If we have a recent periodic spell in our window, prefer treating
					-- this as player periodic damage instead of pet damage.
					local dotSpellId = nil
					if not isPhysicalEarly then
						dotSpellId = pickDotForWound(self, t, school, amount, isCrit)
					end
					-- Class-module dot guard: e.g. Warlock Imp fire hits are pet damage,
					-- never player DoT ticks.
					if ZSBT.ClassDB and ZSBT.ClassDB.DotGuard then
						if ZSBT.ClassDB.DotGuard(dotSpellId and dotEntryForSpellId(dotSpellId) or nil, school) == false then
							recentPlayerCast = false
							dotSpellId = nil
						end
					end
					-- School safety: a DoT entry may declare its school; never attribute
					-- hits of a different school to it (spellId variants included).
					local dotEntry = dotSpellId and dotEntryForSpellId(dotSpellId) or nil
					if dotEntry and dotEntry.school and ZSBT.IsSafeNumber(school) and dotEntrySchoolEq(dotEntry.school, school) == false then
						dotSpellId = nil
					end
					if dl >= 4 and ZSBT.IsSafeNumber(amount) and amount > 0 and (not isPhysicalEarly) and (ZSBT.IsSafeNumber(school) and school == 4) then
						local petFam = getPetFamilyLower()
						local petNpcId = getUnitNpcId("pet")
						ECPrint(("PET_FALLBACK_EVAL token=%s restrict=%s recentPlayerCast=%s dotSpellId=%s amt=%s school=%s")
							:format(dbgSafe(self._castToken), dbgSafe(restrict), dbgSafe(recentPlayerCast), dbgSafe(dotSpellId), dbgSafe(amount), dbgSafe(school))
							.. (petNpcId and (" petNpcId=" .. tostring(petNpcId)) or "")
							.. (petFam and (" petFam=" .. tostring(petFam)) or ""))
					end
					-- Safety: only treat it as a DoT tick if the target actually has the debuff.
					-- Without this, any recent non-periodic cast (e.g. Shadow Bolt) can "stick"
					-- as the spellId for unrelated magic WOUND ticks.
					local chanPick = isLiveChannelPick(self, t, dotSpellId)
					if dotSpellId and not chanPick and (not cachedHasTargetDebuffSpellId(dotSpellId)) then
						local allowDot = false
						local de2 = dotEntryForSpellId(dotSpellId)
						if de2 and de2.school and ZSBT.IsSafeNumber(school)
							and dotEntrySchoolEq(de2.school, school) == true then
							allowDot = true
						end
						if not allowDot then
							dotSpellId = nil
						end
					end
					if dotSpellId and dotCadenceOk(self, t, dotSpellId) then
						if not isCorroboratedHugeHit(t, amount, dotSpellId) then
							if dl >= 4 then
								ECPrint(("BIG_HIT_SUPPRESS src=UNIT_COMBAT_DOT token=%s spellId=%s amt=%s")
									:format(dbgSafe(self._castToken), dbgSafe(dotSpellId), dbgSafe(amount)))
							end
							auditNote(("AUDD reason=DOT_HUGE_SUPPRESS spellId=%s school=%s"):format(dbgSafe(dotSpellId), dbgSafe(school)))
							return
						end
						if not chanPick and isDuplicateDotEmit(self, t, dotSpellId) then
							auditNote(("AUDD reason=DOT_DUP spellId=%s"):format(dbgSafe(dotSpellId)))
							return
						end
						self._recentPeriodicSpellAt[dotSpellId] = t
						local tName = safeUnitName("target")
						noteDotTickAmount(self, dotSpellId, amount, isCrit, t, tName)
						local pipeId = self._rawPipeCount + 1
						self._rawPipeCount = pipeId
						self._rawPipe[pipeId] = amount
						emit("OUTGOING_DAMAGE_COMBAT", {
							timestamp = t,
							rawPipeId = pipeId,
							amount = amount,
							amountText = (ZSBT.IsSafeNumber(amount) and tostring(amount)) or nil,
							spellId = dotSpellId,
							amountSource = "UNIT_COMBAT_DOT",
							targetName = tName,
							isCrit = isCrit,
							isPeriodic = true,
							channelClaim = chanPick == true,
							schoolMask = (ZSBT.IsSafeNumber(school) and school) or nil,
						})
						self._lastOutgoingCombatAt = t
						self._lastOutgoingCombatTargetName = tName
						return
					end
					-- UNIT_COMBAT has no source attribution on Midnight, so the pet
					-- fallback must not claim hits it can't identify. Only schools
					-- matching a known pet signature are pet-eligible — this keeps
					-- procs and the player's own non-physical abilities out of the
					-- pet scroll. Unknown/nil schools stay permissive.
					local petEligibleHit = true
					if ZSBT.IsSafeNumber(school) and not isLikelyPetSchoolHit(school) then
						petEligibleHit = false
						-- Class hook: physical pets (warlock Dreadstalker/
						-- Gloomhound melee). A school-1 hit the player's own
						-- swing explains is never the pet's. With the veto
						-- trusted, group content is safe — a MY_PET melee
						-- line must confirm the hit downstream; untrusted
						-- stays solo-only (foreign swings are unverifiable).
						if school == 1 and isLikelyPetPhysicalHit(school)
							and not (self._swingSupported == true and anySwingRecent(self, t))
							and (zbtVetoActive() or not members or members <= 1) then
							petEligibleHit = true
						end
					end
					if not recentPlayerCast and petEligibleHit then
						if not isCorroboratedHugePetHit(t, amount) then
							if dl >= 4 then
								ECPrint(("BIG_HIT_SUPPRESS src=PET_FALLBACK token=%s amt=%s")
									:format(dbgSafe(self._castToken), dbgSafe(amount)))
							end
							auditNote(("AUDD reason=PET_HUGE_SUPPRESS school=%s"):format(dbgSafe(school)))
							return
						end
						-- Group-aware pet gate: when restrict is active (Quiet/Strict/PvP/Instance-Aware)
						-- and we're in a group, only emit if the hit's school matches a known pet
						-- signature. This prevents other players' damage on shared targets from
						-- being misattributed as pet damage.
						if restrict == true and members and members > 1 then
							if not isLikelyPetSchoolHit(school) then
								-- v2: a MY_PET line can still prove this hit
								-- (guardian/pet damage the school table misses);
								-- foreign lines veto co-attacker wounds at flush.
								if zbtVetoActive() then
									auditNote(("AUDD reason=BYPASS_PET_GROUP_SUPPRESS school=%s"):format(dbgSafe(school)))
								else
									if dl >= 4 then
										ECPrint(("PET_FALLBACK_GROUP_SUPPRESS restrict=%s members=%s school=%s amt=%s")
											:format(dbgSafe(restrict), dbgSafe(members), dbgSafe(school), dbgSafe(amount)))
									end
									auditNote(("AUDD reason=PET_GROUP_SUPPRESS school=%s"):format(dbgSafe(school)))
									return
								end
							end
						end
						-- Shared-target guard: a co-attacker's pet melee is
						-- indistinguishable from ours (same school-1 signature,
						-- no source in UNIT_COMBAT). Line-less wounds feed the
						-- contested detector — our own pet hits carry MINE
						-- pet lines and never feed — and while it's armed the
						-- claim dies here instead of wearing our pet's name.
						if autoContested(self, t) then
							dbgDrop("CONTESTED", self._castToken, school)
							return
						end
						-- Dedup: the same pet swing can arrive twice via UNIT_COMBAT
						-- or once here and once via the "Your pet hits" chat line.
						local lastPetFb = self._lastPetFallbackAt or 0
						local lastPetChat = self._lastPetChatAt or 0
						if (t - lastPetFb) >= 0 and (t - lastPetFb) < PET_OUTGOING_DEDUP_WINDOW then
							auditNote("AUDD reason=PET_FB_DEDUP")
							return
						end
						if (t - lastPetChat) >= 0 and (t - lastPetChat) < PET_OUTGOING_DEDUP_WINDOW then
							auditNote("AUDD reason=PET_CHAT_DEDUP")
							return
						end
						self._lastPetFallbackAt = t
						local pipeId = self._rawPipeCount + 1
						-- Safety: ensure unique rawPipeId. Some clients / reload edges can cause
						-- _rawPipeCount to rewind, which would make Pulse_Engine read a nil value
						-- (and the pet hit would never display).
						if self._rawPipe and self._rawPipe[pipeId] ~= nil then
							local i = pipeId
							while self._rawPipe[i] ~= nil do
								i = i + 1
							end
							pipeId = i
						end
						self._rawPipeCount = pipeId
						self._rawPipe[pipeId] = amount
						if dl >= 4 then
							ECPrint(("PET_FALLBACK_EMIT token=%s rawPipeId=%s amt=%s school=%s")
								:format(dbgSafe(self._castToken), dbgSafe(pipeId), dbgSafe(amount), dbgSafe(school)))
						end
						local zbt2 = ZSBT.ZBattleText
						if zbt2 and zbt2.FileLog then
							zbt2:FileLog(("PET_EMIT school=%s"):format(tostring(school)))
						end
						local petSid, petUnit = consumePetCast(self, t, 1.5, school)
						local petSidTrusted = petSid ~= nil
						local petEvidence = petSid and "cast" or nil
						if petSid == nil and ZSBT.ClassDB and ZSBT.ClassDB.ResolvePetSpellId then
							petSid = ZSBT.ClassDB.ResolvePetSpellId(self, school, t)
							petEvidence = petSid and "resolve" or nil
						end
						if petSid == nil and ZSBT.IsSafeNumber(school) and school == 1
							and ZSBT.ClassDB and ZSBT.ClassDB.ResolvePetMelee then
							-- Class may name verified pet melee (warlock:
							-- "Auto Attack"). Class-guess, not provenance.
							petSid = ZSBT.ClassDB.ResolvePetMelee(self)
							petEvidence = petSid and "melee" or nil
						end
						if zbtVetoActive() then
							-- Pet hits go through the ownership veto: a MY_PET
							-- line must confirm them (the sinkType swap delivers
							-- PET_DAMAGE_COMBAT after pairing). Foreign damage
							-- produces no such line and FLIN vetoes it.
							emit("OUTGOING_DAMAGE_COMBAT", {
								timestamp = t,
								rawPipeId = pipeId,
								spellId = nil,
								petSpellId = petSid,
								_petSidLearn = petSidTrusted or nil,
								petUnit = petUnit,
								petEvidence = petEvidence or "guess",
								_petRoute = true,
								amount = amount,
								amountText = (ZSBT.IsSafeNumber(amount) and tostring(amount)) or nil,
								isCrit = isCrit,
								petBucket = (ZSBT.IsSafeNumber(school) and school ~= 1) and "summons" or nil,
								schoolMask = ZSBT.IsSafeNumber(school) and school or nil,
								targetName = safeUnitName("target"),
							})
						else
						emit("PET_DAMAGE_COMBAT", {
							timestamp = t,
							rawPipeId = pipeId,
							petSpellId = petSid,
							_petSidLearn = petSidTrusted or nil,
							petUnit = petUnit,
							petEvidence = petEvidence or "guess",
							amount = amount,
							amountText = (ZSBT.IsSafeNumber(amount) and tostring(amount)) or nil,
							isCrit = isCrit,
							petBucket = (ZSBT.IsSafeNumber(school) and school ~= 1) and "summons" or nil,
							schoolMask = ZSBT.IsSafeNumber(school) and school or nil,
							targetName = safeUnitName("target"),
						})
						end
						return
					end
				end
			elseif okEx and hasPet ~= true then
				-- Guardian-style pets (e.g. DK ghoul): class module decides.
				if ZSBT.ClassDB and ZSBT.ClassDB.OnGuardianWound then
					if ZSBT.ClassDB.OnGuardianWound(self, {
						t = t,
						amount = amount,
						isCrit = isCrit,
						school = school,
						restrict = restrict,
						members = members,
						dl = dl,
						emit = emit,
						safeUnitName = safeUnitName,
						petSchoolHit = isLikelyPetSchoolHit,
						dedupWindow = PET_OUTGOING_DEDUP_WINDOW,
						ecPrint = ECPrint,
						dbgSafe = dbgSafe,
					}) then
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
				-- A non-attackable target's non-HEAL amount events are a
				-- continuous damage-class stream (its own regen/noise),
				-- not heals — real outgoing heals always arrive with a
				-- readable action="HEAL" on this build. The old
				-- nil-action candidacy queued these as pending heals,
				-- let them steal the next real heal's line, and emitted
				-- a WOUND amount as a heal tick.
				auditNote("AUDD reason=NOT_ATTACKABLE")
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
			-- Mob self-heals: the player cannot heal an attackable (hostile)
			-- unit, so a HEAL on the target token is never outgoing when the
			-- target can be attacked (e.g. Owlbeast HoTs). Friendly targets
			-- (healers' allies, pets) are not attackable and pass through.
			if UnitCanAttack then
				local okA, canAtk = pcall(UnitCanAttack, "player", "target")
				if okA then
					local okC, eq = pcall(function() return canAtk == true end)
					if okC and eq == true then
						return
					end
				end
			end
			local pipeId = self._rawPipeCount + 1
			self._rawPipeCount = pipeId
			self._rawPipe[pipeId] = amount

			local spellId = nil
			local hotTick = false
			local castNamed = false
			if self._lastPlayerSpellAt and self._lastPlayerSpellId then
				local age = t - (self._lastPlayerSpellAt or 0)
				if age >= 0 and age <= 1.5
					and miwClaim(self, self._lastPlayerSpellId, self._lastPlayerSpellAt, t, school) then
					spellId = self._lastPlayerSpellId
					castNamed = true
				end
			end
			local provenHeal = false
			if spellId == nil then
				-- HoT ticks land far outside the cast window: claim via
				-- filtered heal-line ownership + cast-seeded cadence on
				-- the target. sid == 0 means the line proved ours but no
				-- armed hot named it — a bare proven heal still emits.
				local hsid, hPeriodic, why = matchOutgoingHotTick(self, "target", t)
				if hsid == nil then
					if why == "noline" then
						queuePendingHotHeal(self, "target", t, amount, school, isCrit)
						return
					end
					auditNote(("AUDHX unit=target why=%s"):format(tostring(why)))
				end
				if hsid ~= nil and hsid ~= 0 then
					spellId = hsid
					hotTick = hPeriodic == true
				end
				if hsid == 0 then
					provenHeal = true
					hotTick = hPeriodic == true
				end
			end
			if restrict and spellId == nil and not provenHeal then
				return
			end

			-- Alias dedup: this same direct heal also re-reports on other
			-- tokens (softfriend/partyN) which route through the matcher —
			-- when the cast window named it, the matcher never ran, so the
			-- gate has to live here too. When spellId == nil the matcher
			-- already checked and recorded this UC's own claim (checking
			-- again would self-dup and suppress this emit).
			if castNamed then
				if isHealAliasDup(self, "target", t) then
					return
				end
				noteHealClaim(self, "target", t)
			end

			local zH = ZSBT.ZBattleText
			if zH and zH.FileLog then
				zH:FileLog(("HEAL_TGT sid=%s restrict=%s"):format(tostring(spellId), tostring(restrict == true)))
			end
			emit("OUTGOING_HEAL_COMBAT", {
				timestamp = t,
				rawPipeId = pipeId,
				amountText = (ZSBT.IsSafeNumber(amount) and tostring(amount)) or nil,
				spellId = spellId,
				targetName = safeUnitName("target"),
				isCrit = isCrit,
				isPeriodic = hotTick or nil,
				schoolMask = ZSBT.IsSafeNumber(school) and school or nil,
			})
			return
		end
		if actionStr and actionStr ~= "WOUND" then
			-- Miss outcomes (MISS/DODGE/PARRY/BLOCK/ABSORB/etc.) arrive as their
			-- own action with no damage amount; emit them as miss text instead.
			if actionStr == "MISS" or actionStr == "DODGE" or actionStr == "PARRY"
				or actionStr == "BLOCK" or actionStr == "ABSORB" or actionStr == "IMMUNE"
				or actionStr == "DEFLECT" or actionStr == "REFLECT" or actionStr == "EVADE" then
				local spellId = nil
				if self._lastPlayerSpellAt and self._lastPlayerSpellId then
					local age = t - self._lastPlayerSpellAt
					if age >= 0 and age <= 1.5
						and miwClaim(self, self._lastPlayerSpellId, self._lastPlayerSpellAt, t, school) then
						spellId = self._lastPlayerSpellId
					end
				end
				if restrict and not spellId then
					return
				end
				emit("OUTGOING_MISS_COMBAT", {
					timestamp = t,
					amountText = actionStr,
					spellId = spellId,
					amountSource = "UNIT_COMBAT_MISS",
					targetName = safeUnitName("target"),
					isCrit = false,
				})
			end
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
		-- With a pet out, only block the auto-attack fallback when the pet is
		-- actually fighting AND this hit matches a known pet damage school.
		-- Pet-eligible hits are claimed by the pet fallback earlier; anything
		-- else is the player's own swing and should be allowed through.
		local petMayOwnHit = false
		if hasPet and UnitAffectingCombat then
			local okPC, inPetCombat = pcall(UnitAffectingCombat, "pet")
			if okPC and inPetCombat == true and isLikelyPetSchoolHit(school) then
				petMayOwnHit = true
			end
		end
		local allowAutoFallback = false
		if restrict == true and (not petMayOwnHit) then
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
				if members and members > 1 then
					allowAutoFallback = false
				else
					local inPlayerCombat = false
					if UnitAffectingCombat then
						local okC, res = pcall(UnitAffectingCombat, "player")
						if okC and type(res) == "boolean" then inPlayerCombat = res end
					end
					if inPlayerCombat then
						-- Midnight: IsCurrentSpell(6603)/IsSpellInRange are unreliable or return
						-- secret values, so isPlayerAutoAttackActive()/isPlayerMeleeEngaged()
						-- frequently return false even while actively swinging. When solo (the
						-- members>1 case is already handled above), treat "in combat with a
						-- hostile target" as sufficient evidence of an auto-attack.
						local autoOk = isPlayerAutoAttackActive() or isPlayerMeleeEngaged()
						if (not autoOk) then
							autoOk = true
						end
						if autoOk then
							allowAutoFallback = true
						end
					end
				end
			end
			end
		end
		-- Safety: never allow auto-attack fallback inside group instances when instance-aware
		-- outgoing is enabled; UNIT_COMBAT(target) has no source attribution and will leak.
		if allowAutoFallback == true and instanceAware == true and inInst == true and members and members > 1 then
			allowAutoFallback = false
		end

		-- PHYSICAL: do not merge. Multiple swings / cleaves / multistrikes would be
		-- incorrectly collapsed. We only accept physical UNIT_COMBAT(target) when it is
		-- unambiguous (no pet) or when we can match it to a recent player cast.
		if isPhysical then
			-- Midnight: lower the physical noise floor from 50 to 2 so low-level
			-- characters (whose white swings can be 5-15 damage) still see outgoing.
			-- On max-level characters, sub-2 physical hits are effectively noise.
			if ZSBT.IsSafeNumber(amount) and amount > 0 and amount < 2 then
				return
			end
			-- Rend (772) periodic ticks are physical WOUND events in 12.x and contain no spellId.
			-- Warrior-only heuristic: after a recent Rend cast, emit tick-like wounds as periodic.
			-- Warrior Rend tick classifier lives in Classes/Warrior.lua now.
			if ZSBT.ClassDB and ZSBT.ClassDB.OnPhysicalWound then
				ZSBT.ClassDB.OnPhysicalWound(self, {
					t = t,
					amount = amount,
					isCrit = isCrit,
					actionStr = actionStr,
					hasTargetDebuff = cachedHasTargetDebuffSpellId,
					autoAttackActive = isPlayerAutoAttackActive,
					outDbgLevel = OutDbgLevel,
					ecPrint = ECPrint,
					dbgSafe = dbgSafe,
					safeUnitName = safeUnitName,
					emit = emit,
				})
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
			local matchedCast = consumeBestPendingCast(self, t, wantSpellId, castWindow, doConsume, school)
			-- Strict/restricted mode normally requires a pending-cast match. For Whirlwind,
			-- the UNIT_COMBAT(target) stream can contain more hits than we can reliably
			-- match; allow a short post-cast window to still attribute as Whirlwind.
			if (not matchedCast) and isWhirlwindSpellId(wantSpellId) and wwRecent then
				matchedCast = { spellId = wantSpellId, eligibleIcon = true }
			end
			-- Physical DoT ticks (feral/warrior bleeds) never reach the
			-- non-physical dot path — they surface here. A school-1 wound
			-- earns a bleed name only when a MINE-filtered "tick" line
			-- corroborates that a periodic hit of ours just fired, and the
			-- wound lands on the picked dot's own tick grid; everything
			-- else falls through to the white-hit machinery unchanged.
			if not matchedCast then
				local dotSpellId = pickDotForWound(self, t, school, amount, isCrit)
				-- Aura reads are unreliable on secret-value clients — the
				-- corroborating evidence is the MINE-filtered "tick" line:
				-- our bleed ticks always produce one, a foreign white hit
				-- never does. Cadence then phase-locks the wound to the
				-- picked dot's own tick grid.
				local tickOk = nil
				if dotSpellId then
					local zbt = ZSBT.ZBattleText
					tickOk = (zbt and zbt.PeekDamageLine)
						and (zbt:PeekDamageLine(t, 0.30, { tick = true }) ~= nil) or nil
				end
				local cadOk = (dotSpellId and tickOk) and dotCadenceOk(self, t, dotSpellId) or nil
				auditNote(("AUDD reason=PDOT_EVAL ret=%s tk=%s cad=%s dis=%s")
					:format(dbgSafe(dotSpellId), dbgSafe(tickOk), dbgSafe(cadOk),
						dbgSafe(ZSBT.ClassDB and ZSBT.ClassDB.DotCadenceDisambig and ZSBT.ClassDB.DotCadenceDisambig() or nil)))
				if not tickOk then
					dotSpellId = nil
				end
				if dotSpellId and cadOk then
					if not isDuplicateDotEmit(self, t, dotSpellId) then
						self._recentPeriodicSpellAt[dotSpellId] = t
						local tName = safeUnitName("target")
						noteDotTickAmount(self, dotSpellId, amount, isCrit, t, tName)
						local pipeId = self._rawPipeCount + 1
						self._rawPipeCount = pipeId
						self._rawPipe[pipeId] = amount
						emit("OUTGOING_DAMAGE_COMBAT", {
							timestamp = t,
							rawPipeId = pipeId,
							amount = amount,
							amountText = (ZSBT.IsSafeNumber(amount) and tostring(amount)) or nil,
							spellId = dotSpellId,
							amountSource = "UNIT_COMBAT_DOT",
							targetName = tName,
							isCrit = isCrit,
							isPeriodic = true,
							schoolMask = ZSBT.IsSafeNumber(school) and school or nil,
						})
					end
					return
				end
			end
			-- Contested: another attacker on this target makes every
			-- unattributed physical hit a coin flip — drop it outright so it
			-- can neither emit nor reach the pending queue and steal our
			-- filtered lines. This gate must run before the fallback block
			-- (which falls through to BYPASS_RESTRICT_PHYS -> AUDQ under veto,
			-- where the foreign candidate claims melee lines anyway) and it
			-- must see EVERY unmatched physical UC or the detector starves.
			-- Cast-matched (named) hits skip this entirely. In instances an
			-- unattributed physical hit can never be proven ours (another
			-- attacker is guaranteed) — drop it without feeding detection.
			if restrict and (not matchedCast) then
				if inInst == true then
					-- v2: MY_PET/MINE lines can still prove unattributed
					-- wounds in instances (pet melee, autos); FLIN vetoes
					-- the guaranteed co-attacker's hits at flush instead.
					if zbtVetoActive() then
						dbgDrop("BYPASS_INST_UNATTR", self._castToken, school)
						matchedCast = { spellId = nil, eligibleIcon = false }
					else
						dbgDrop("INST_UNATTR", self._castToken, school)
						return
					end
				end
				if not matchedCast and autoContested(self, t) then
					dbgDrop("CONTESTED", self._castToken, school)
					return
				end
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
						if okS and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(mh) and mh > 0 then
							speed = mh
						end
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
				-- PLAYER_SWING: a real swing must back an auto claim, or pet/
				-- follower melee gets shown as your auto-attack.
				if canShow and not swingExplainsHit(self, t) then
					canShow = false
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
				if zbtVetoActive() then
					dbgDrop("BYPASS_RESTRICT_PHYS", self._castToken, school)
					matchedCast = { spellId = nil, eligibleIcon = false }
				else
					dbgDrop("RESTRICT_PHYS", self._castToken, school)
					return
				end
			end
			if hasPet and not matchedCast then
				-- With a pet out, unattributed physical hits were assumed to be the
				-- pet's. Only drop them here when the pet fallback could actually
				-- claim this hit (school signature match); otherwise it's the
				-- player's own swing and should continue to the white-hit path.
				if isLikelyPetSchoolHit(school) then
					if zbtVetoActive() then
						dbgDrop("BYPASS_PET_SCHOOL_PHYS", self._castToken, school)
						matchedCast = { spellId = nil, eligibleIcon = false }
					else
						dbgDrop("PET_SCHOOL_PHYS", self._castToken, school)
						return
					end
				end
			end
			local spellId = nil
			if matchedCast then
				spellId = (matchedCast.eligibleIcon == true) and matchedCast.spellId or nil
			end
			-- Hybrid (open-world) gating: physical WOUND events on the target have no source
			-- attribution. When we're not in strict/restricted correlation mode, only show
			-- "white hits" (spellId nil) if we have strong evidence the player is actually
			-- swinging. This reduces leakage when other players are also attacking your target.
			if (restrict ~= true) and (quietMode ~= true) and (spellId == nil) then
				if inInst == true then
					if zbtVetoActive() then
						dbgDrop("BYPASS_INST_UNATTR", self._castToken, school)
					else
						dbgDrop("INST_UNATTR", self._castToken, school)
						return
					end
				elseif autoContested(self, t) then
					dbgDrop("CONTESTED", self._castToken, school)
					return
				end
				local okSwing = true
				local inPlayerCombat = false
				if UnitAffectingCombat then
					local okC, res = pcall(UnitAffectingCombat, "player")
					if okC and type(res) == "boolean" then inPlayerCombat = res end
				end
				if not inPlayerCombat then
					okSwing = false
				end
				local canAtk = nil
				if okSwing and UnitCanAttack then
					local okA, a = pcall(UnitCanAttack, "player", "target")
					if okA then canAtk = a end
					if a == false then
						okSwing = false
					end
				end
				local autoOk = nil
				if okSwing then
					-- Midnight: IsCurrentSpell(6603)/IsSpellInRange/CheckInteractDistance are
					-- unreliable or return secret values, so isPlayerAutoAttackActive() and
					-- isPlayerMeleeEngaged() frequently return false even while actively
					-- swinging. In solo open-world (restrict off, quiet off) there is no one
					-- else to attribute the hit to, so treat "player in combat with a hostile
					-- target" as sufficient evidence of a white swing. Group/instance leakage
					-- is still handled by the restrict/instance-aware gates above.
					autoOk = (isPlayerAutoAttackActive() or isPlayerMeleeEngaged()) and true or false
					if (not autoOk) and (not inPlayerCombat) then
						okSwing = false
					end
				end
				if not okSwing then
					auditNote(("AUDD reason=WHT_EV inCbt=%s canAtk=%s auto=%s school=%s")
						:format(tostring(inPlayerCombat), tostring(canAtk), tostring(autoOk), dbgSafe(school)))
					return
				end
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
				dbgDrop("WHT_HUGE", self._castToken, school)
				return
			end
			if isWhirlwindSpellId(spellId) and wwAggEnabled(spellId)
				and ZSBT.IsSafeNumber(amount) and amount > 0 then
				-- If we are receiving addon-readable Whirlwind chat hits for this same cast,
				-- do not double-count the UNIT_COMBAT stream.
				local chatTok = self._wwAggChatToken
				local chatAt = self._wwAggChatAt or 0
				if chatTok == self._castToken and (t - chatAt) >= 0 and (t - chatAt) <= 1.25 then
					return
				end
				wwAggPush(self, t, spellId, amount, isCrit, true)
				return
			end
			if ZSBT.ClassDB and ZSBT.ClassDB.OnMatchedPhysical then
				ZSBT.ClassDB.OnMatchedPhysical(self, spellId, t, amount)
			end
			-- Dedup unattributed white swings across the physical and
			-- auto-fallback branches (same swing can be reported twice with
			-- different school values). Spell-attributed hits are exempt so
			-- Cleave/Whirlwind multi-hits are never collapsed.
			if spellId == nil then
				local lastAuto = self._lastAutoOutgoingAt or 0
				if (t - lastAuto) >= 0 and (t - lastAuto) < AUTO_OUTGOING_DEDUP_WINDOW then
					dbgDrop("WHT_DEDUP", self._castToken, school)
					return
				end
				self._lastAutoOutgoingAt = t
			end
			local pipeId = self._rawPipeCount + 1
			self._rawPipeCount = pipeId
			self._rawPipe[pipeId] = amount
			self._lastOutgoingCombatAt = t
			self._lastOutgoingCombatTargetName = safeUnitName("target")
			-- A physical hit with no cast and no player swing is not your
			-- auto — pet melee claims it when the class hook allows (the
			-- veto then verifies a MY_PET line when trusted).
			local swingOk = swingExplainsHit(self, t)
			local petRoutePhys = nil
			local petSidPhys = nil
			local petEvidence = nil
			if spellId == nil and not swingOk
				and isLikelyPetPhysicalHit(school)
				and (zbtVetoActive() or not members or members <= 1) then
				petRoutePhys = true
				petSidPhys = consumePetCast(self, t, 1.5, school)
				local petSidPhysTrusted = petSidPhys ~= nil
				petEvidence = petSidPhys and "cast" or nil
				if petSidPhys == nil and ZSBT.ClassDB and ZSBT.ClassDB.ResolvePetSpellId then
					petSidPhys = ZSBT.ClassDB.ResolvePetSpellId(self, school, t)
					petEvidence = petSidPhys and "resolve" or nil
				end
				if petSidPhys == nil and ZSBT.ClassDB and ZSBT.ClassDB.ResolvePetMelee then
					-- Opt-in pet melee naming (6603 "Auto Attack"): the hit
					-- still must claim a MY_PET line downstream.
					petSidPhys = ZSBT.ClassDB.ResolvePetMelee(self)
					petEvidence = petSidPhys and "melee" or nil
				end
			end
			emit("OUTGOING_DAMAGE_COMBAT", {
				timestamp = t,
				rawPipeId = pipeId,
				spellId = spellId,
				_sidLearn = (matchedCast ~= nil and spellId ~= nil) or nil,
				isAuto = (spellId == nil and swingOk),
				_petRoute = petRoutePhys,
				petSpellId = petSidPhys,
				_petSidLearn = petSidPhysTrusted or nil,
				petEvidence = petRoutePhys and (petEvidence or "guess") or nil,
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
		-- Exception: channeled periodic spells like Drain Life should emit each tick.
		if actionStr == "WOUND" and (not isPhysicalEarly) then
			-- Channeled periodic spells (Drain Life/Soul etc.): the class module
			-- seeds self._channel on cast; emit each tick while the channel is live
			-- and the channel spell is still the most recent player cast.
			-- With cadence disambiguation the channel competes in the
			-- picker's candidate pool instead of greedily claiming every
			-- same-school wound (which ate real DoT ticks mid-channel).
			local ch = self._channel
			local disambigOn = ZSBT.ClassDB and ZSBT.ClassDB.DotCadenceDisambig
				and ZSBT.ClassDB.DotCadenceDisambig() == true
			if not disambigOn
				and type(ch) == "table" and type(ch.untilAt) == "number" and t <= ch.untilAt then
				local wantSid = self._lastPlayerSpellId
				if wantSid == ch.spellId then
					-- School check: a channel's ticks arrive at one mask
					-- (declared school=N, or the derived mask set). A
					-- wrong-school tick in the window is a foreign/DoT
					-- hit, not this channel — falls through to normal
					-- attribution or generic instead of stealing the name.
					local schoolOk = true
					if ch.school ~= nil and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school) then
						schoolOk = dotEntrySchoolEq(ch.school, school) == true
					end
					if not schoolOk then
						auditNote(("AUDD reason=CHANNEL_SCHOOL school=%s want=%s"):format(
							dbgSafe(school), dbgSafe(ch.school)))
					end
					local dtTick = t - (ch.lastTickAt or 0)
					if schoolOk and dtTick >= (ch.tickMin or 0.12) then
						ch.lastTickAt = t
						local pipeId = self._rawPipeCount + 1
						self._rawPipeCount = pipeId
						self._rawPipe[pipeId] = amount
						self._lastOutgoingCombatAt = t
						self._lastOutgoingCombatTargetName = safeUnitName("target")
						emit("OUTGOING_DAMAGE_COMBAT", {
							timestamp = t,
							rawPipeId = pipeId,
							spellId = ch.spellId,
							amountSource = "UNIT_COMBAT_DOT",
							targetName = safeUnitName("target"),
							isCrit = isCrit,
							isPeriodic = true,
							channelClaim = true,
							schoolMask = (ZSBT.IsSafeNumber(school) and school) or nil,
						})
						return
					end
				end
			end
		end
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
			-- Small non-physical hits can be either real spell damage (low level / old content)
			-- or tiny procs/secondary effects. Prefer attribution first; only suppress when
			-- we cannot correlate it to a recent cast/periodic effect.
			local suppressIfUnattributed = false
			if not isPhysical and ZSBT.IsSafeNumber(amount) and amount > 0 and amount < 500 then
				-- DoT ticks often show up as small UNIT_COMBAT(target) magic WOUND events.
				-- If we recently cast a periodic-capable spell, treat this as outgoing
				-- periodic damage.
				local dotSpellId = pickDotForWound(self, t, school, amount, isCrit)
				-- Safety: only treat it as a DoT tick if the target actually has the debuff.
				local debuffOk = nil
				local chanPick = isLiveChannelPick(self, t, dotSpellId)
				if dotSpellId and not chanPick then
					debuffOk = cachedHasTargetDebuffSpellId(dotSpellId)
					if debuffOk ~= true then
						local allowDot = false
						local de3 = dotEntryForSpellId(dotSpellId)
						if de3 and de3.school and ZSBT.IsSafeNumber(school)
							and dotEntrySchoolEq(de3.school, school) == true then
							allowDot = true
						end
						if not allowDot then
							if dl >= 4 then
								ECPrint(("DOT_ATTRIB_FAIL src=UNIT_COMBAT_SMALL token=%s dotSpellId=%s debuffOk=%s amt=%s school=%s")
									:format(dbgSafe(self._castToken), dbgSafe(dotSpellId), dbgSafe(debuffOk), dbgSafe(amount), dbgSafe(school)))
							end
							dotSpellId = nil
						end
					end
				end
				if dotSpellId and dotCadenceOk(self, t, dotSpellId) then
					if dl >= 4 and ZSBT.IsSafeNumber(amount) and amount >= BIG_HIT_THRESHOLD then
						ECPrint(("BIG_HIT DOT token=%s spellId=%s amt=%s")
							:format(dbgSafe(self._castToken), dbgSafe(dotSpellId), dbgSafe(amount)))
					end
					if not chanPick and isDuplicateDotEmit(self, t, dotSpellId) then
						return
					end
					self._recentPeriodicSpellAt[dotSpellId] = t
					local tName = safeUnitName("target")
					noteDotTickAmount(self, dotSpellId, amount, isCrit, t, tName)
					local pipeId = self._rawPipeCount + 1
					self._rawPipeCount = pipeId
					self._rawPipe[pipeId] = amount
					emit("OUTGOING_DAMAGE_COMBAT", {
						timestamp = t,
						rawPipeId = pipeId,
						amount = amount,
						amountText = (ZSBT.IsSafeNumber(amount) and tostring(amount)) or nil,
						spellId = dotSpellId,
						amountSource = "UNIT_COMBAT_DOT",
						targetName = tName,
						isCrit = isCrit,
						isPeriodic = true,
						channelClaim = chanPick == true,
						schoolMask = (ZSBT.IsSafeNumber(school) and school) or nil,
					})
					self._lastOutgoingCombatAt = t
					self._lastOutgoingCombatTargetName = tName
					return
				end
				suppressIfUnattributed = true
			end
			-- Physical with a pet is too ambiguous.
			if isPhysical and hasPet then
				if zbtVetoActive() then
					dbgDrop("BYPASS_PHYS_PET", self._castToken, school)
					matchedCast = { spellId = nil, eligibleIcon = false }
				else
					dbgDrop("PHYS_PET", self._castToken, school)
					return
				end
			end
			local castWindow = (restrict == true) and 0.55 or 0.85
			local wantSpellId = nil
			if restrict == true then
				wantSpellId = self._lastPlayerSpellId
			end
			matchedCast = matchedCast or consumeBestPendingCast(self, t, wantSpellId, castWindow, nil, school)
			if not matchedCast then
				-- Class-module DoT attribution (secret-safe): an unattributed
				-- non-physical WOUND can be a periodic tick. No amount comparisons
				-- are needed — the amount goes straight into the raw pipe, which is
				-- the only display-safe path for secret values on Retail 12.x.
				local dotSpellId = pickDotForWound(self, t, school, amount, isCrit)
				-- Don't let a DoT steal a hit that probably belongs to a nuke cast
				-- moments ago: if the last cast was a non-dot spell within ~1.5s,
				-- leave attribution to the make-it-work window below.
				local dotBlockedByRecentCast = false
				local eraClient = ZSBT.ClassDB and ZSBT.ClassDB.IsForever
					and ZSBT.ClassDB.IsForever() == true or nil
				local blockedDotCastId = nil
				local lastCastAt = self._lastPlayerSpellAt
				local lastCastId = self._lastPlayerSpellId
				if type(lastCastAt) == "number" and type(lastCastId) == "number"
					and (t - lastCastAt) >= 0 and (t - lastCastAt) <= 1.50
					and not dotEntryForSpellId(lastCastId)
					and not (ZSBT.ClassDB and ZSBT.ClassDB.ExcludedSpellId
						and ZSBT.ClassDB.ExcludedSpellId(lastCastId)) then
					dotBlockedByRecentCast = true
					-- Era: the cast veto is mutual. castSchoolOk exempts player
					-- casts on Forever (wound schools lie there), so a frequent
					-- recast like wand Shoot can block a surviving dot pick and
					-- then take the same wound no-line. When a pick was actually
					-- vetoed, the blocking cast cannot claim noline either —
					-- the wound goes generic rather than wearing a wrong name.
					if eraClient and dotSpellId ~= nil then
						blockedDotCastId = lastCastId
					end
				end
				local chanPick = isLiveChannelPick(self, t, dotSpellId)
				if dotSpellId and (not dotBlockedByRecentCast or chanPick) then
					if ZSBT.ClassDB and ZSBT.ClassDB.DotGuard then
						if ZSBT.ClassDB.DotGuard(dotEntryForSpellId(dotSpellId), school) == false then
							dotSpellId = nil
						end
					end
					local dotEntry = dotSpellId and dotEntryForSpellId(dotSpellId) or nil
					if dotEntry and dotEntry.school and ZSBT.IsSafeNumber(school) and dotEntrySchoolEq(dotEntry.school, school) == false then
						dotSpellId = nil
					end
					if dotSpellId and not chanPick then
						local debuffOk = cachedHasTargetDebuffSpellId(dotSpellId)
						if debuffOk ~= true then
							local allowDot = false
							if dotEntry and dotEntry.school and ZSBT.IsSafeNumber(school) and dotEntrySchoolEq(dotEntry.school, school) == true then
								allowDot = true
							end
							if not allowDot then
								dotSpellId = nil
							end
						end
					end
					if dotSpellId and isCorroboratedHugeHit(t, amount, dotSpellId) then
						-- Cadence gate: reject hits that don't land in a plausible
						-- tick slot (shared-target bleed-through protection).
						if not dotCadenceOk(self, t, dotSpellId) then
							dotSpellId = nil
						else
						if not chanPick and isDuplicateDotEmit(self, t, dotSpellId) then
							return
						end
						if OutDbgLevel() >= 4 then
							ECPrint(("DOT_ATTRIB src=UNIT_COMBAT_MERGE token=%s spellId=%s amt=%s school=%s")
								:format(dbgSafe(self._castToken), dbgSafe(dotSpellId), dbgSafe(amount), dbgSafe(school)))
						end
						self._recentPeriodicSpellAt[dotSpellId] = t
						local tName = safeUnitName("target")
						noteDotTickAmount(self, dotSpellId, amount, isCrit, t, tName)
						local pipeId = self._rawPipeCount + 1
						self._rawPipeCount = pipeId
						self._rawPipe[pipeId] = amount
						self._lastOutgoingCombatAt = t
						self._lastOutgoingCombatTargetName = tName
						emit("OUTGOING_DAMAGE_COMBAT", {
							timestamp = t,
							rawPipeId = pipeId,
							spellId = dotSpellId,
							amountSource = "UNIT_COMBAT_DOT",
							targetName = tName,
							isCrit = isCrit,
							isPeriodic = true,
							channelClaim = chanPick == true,
							schoolMask = (ZSBT.IsSafeNumber(school) and school) or nil,
						})
						return
						end
					end
				end
				if suppressIfUnattributed == true then
					-- Midnight: the school field is unreliable (physical abilities like
					-- Sinister Strike report school=32), so auto-attacks land in this
					-- non-physical branch with no cast to correlate and would be silently
					-- dropped. In solo open-world (restrict off, quiet off), emit them as
					-- auto-attacks directly (no bucket merge, like the physical path) so
					-- white swings display. Group/instance leakage is still handled by
					-- the restrict/instance-aware gates above.
					-- Allow auto-attack fallback in two cases:
					--  (a) open-world non-quiet (restrict off, quiet off)
					--  (b) quiet mode with "show auto attacks while quiet" enabled
					-- In both cases require solo (no group) to avoid leaking other players'
					-- damage on shared targets, since UNIT_COMBAT(target) has no source on Midnight.
					local allowAutoHere = (restrict ~= true and quietMode ~= true)
						or (quietMode == true and isQuietOutgoingAutoAttacks() == true)
					if allowAutoHere then
						local inPlayerCombat = false
						if UnitAffectingCombat then
							local okC, res = pcall(UnitAffectingCombat, "player")
							if okC and type(res) == "boolean" then inPlayerCombat = res end
						end
						local canAtk = true
						if UnitCanAttack then
							local okA, a = pcall(UnitCanAttack, "player", "target")
							if okA and a == false then canAtk = false end
						end
						if inPlayerCombat and canAtk and (not (members and members > 1))
							and (not inInst)
							and (not autoContested(self, t)) and swingExplainsHit(self, t) then
							-- Same dedup as the physical branch: the fallback and
							-- physical paths can both fire for one white swing.
							local lastAuto = self._lastAutoOutgoingAt or 0
							if (t - lastAuto) >= 0 and (t - lastAuto) < AUTO_OUTGOING_DEDUP_WINDOW then
								return
							end
							self._lastAutoOutgoingAt = t
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
						else
							auditNote(("AUDD reason=AUTO_FB inCbt=%s canAtk=%s members=%s swing=%s school=%s")
								:format(tostring(inPlayerCombat), tostring(canAtk), dbgSafe(members),
									tostring(swingExplainsHit(self, t)), dbgSafe(school)))
						end
					else
						auditNote(("AUDD reason=AUTO_FB_OFF restrict=%s quiet=%s school=%s")
							:format(tostring(restrict == true), tostring(quietMode == true), dbgSafe(school)))
					end
					dbgDrop("SUPPRESS_UNATTR", self._castToken, school)
					return
				end
				-- "Make it work" mode: if we cannot confidently attribute to a specific spell,
				-- still show the outgoing number when it occurs shortly after the player's own cast.
				-- This sacrifices icons/attribution but prevents outgoing going silent.
				-- IMPORTANT: do NOT bypass strict/restricted/quiet modes (PvP strict, instance-aware,
				-- or user-enabled strict outgoing). In those modes we require a real pending-cast match.
				if restrict == true or quietMode == true then
					-- Quiet/strict modes: still allow *your own* outgoing when it can be correlated
					-- to a very recent cast timestamp, even if the pending-cast queue missed it.
					-- For travel-time spells (e.g., Shadow Bolt), allow a longer window.
					-- When grouped (open world OR instance), do NOT use timestamp-only
					-- attribution because UNIT_COMBAT(target) has no ownership and will leak
					-- other players' damage on shared targets.
					if members and members > 1 then
						if zbtVetoActive() then
							dbgDrop("BYPASS_GROUP_GATE", self._castToken, school)
							matchedCast = { spellId = nil, eligibleIcon = false }
						else
							dbgDrop("GROUP_GATE", self._castToken, school)
							return
						end
					end
					local lastAt = self._lastPlayerSpellAt
					local lastId = self._lastPlayerSpellId
					if type(lastAt) == "number" and type(lastId) == "number" then
						local age = t - lastAt
						local maxAge = castWindow
						if lastId == 686 then
							maxAge = math.max(maxAge, 2.50)
						elseif not isPhysical then
							maxAge = math.max(maxAge, 1.25)
						end
						if age >= 0 and age <= maxAge and castSchoolOk(self, lastId, school)
							and not (ZSBT.ClassDB and ZSBT.ClassDB.ExcludedSpellId
								and ZSBT.ClassDB.ExcludedSpellId(lastId))
							and blockedDotCastId ~= lastId
							and miwClaim(self, lastId, lastAt, t, school) then
							matchedCast = { spellId = lastId, eligibleIcon = true }
						else
							if zbtVetoActive() then
								dbgDrop("BYPASS_RESTRICT_AGE", self._castToken, school)
								matchedCast = { spellId = nil, eligibleIcon = false }
							else
								dbgDrop("RESTRICT_AGE", self._castToken, school)
								return
							end
						end
					else
						if zbtVetoActive() then
							dbgDrop("BYPASS_RESTRICT_NOCAST", self._castToken, school)
							matchedCast = { spellId = nil, eligibleIcon = false }
						else
							dbgDrop("RESTRICT_NOCAST", self._castToken, school)
							return
						end
					end
				end
				-- matchedCast may already be set by the PHYS_PET/GROUP_GATE veto
				-- bypass; the make-it-work tail must not overwrite or re-drop it.
				if matchedCast == nil then
					local lastAt = self._lastPlayerSpellAt
					if type(lastAt) == "number" then
					local age = t - lastAt
					if age >= 0 and age <= 1.25 then
						-- If we have a last spell id, prefer attributing to it over emitting spellId=nil.
						-- Shadow Bolt landings frequently arrive via UNIT_COMBAT(target) with no clean
						-- pending-cast match; treat them as the last cast within a longer window.
						local lastId = self._lastPlayerSpellId
						if type(lastId) == "number" then
							local maxAge = 1.25
							if lastId == 686 then
								maxAge = 2.50
							end
							if age >= 0 and age <= maxAge and castSchoolOk(self, lastId, school)
								and blockedDotCastId ~= lastId
								and miwClaim(self, lastId, lastAt, t, school) then
								matchedCast = { spellId = lastId, eligibleIcon = true }
							else
								-- Quiet/strict: suppress unattributed numbers when we cannot even loosely
								-- correlate to a recent player cast.
								if quietMode == true or restrict == true then
									if not zbtVetoActive() then
										dbgDrop("MIW_QUIET", self._castToken, school)
										return
									end
								end
								matchedCast = { spellId = nil, eligibleIcon = false }
							end
						else
							if quietMode == true or restrict == true then
								if not zbtVetoActive() then
									dbgDrop("MIW_QUIET", self._castToken, school)
									return
								end
							end
							matchedCast = { spellId = nil, eligibleIcon = false }
						end
					else
						if zbtVetoActive() then
							dbgDrop("BYPASS_MIW_AGE", self._castToken, school)
							matchedCast = { spellId = nil, eligibleIcon = false }
						else
							dbgDrop("MIW_AGE", self._castToken, school)
							return
						end
					end
				else
					if zbtVetoActive() then
						dbgDrop("BYPASS_MIW_NO_CAST", self._castToken, school)
						matchedCast = { spellId = nil, eligibleIcon = false }
					else
						dbgDrop("MIW_NO_CAST", self._castToken, school)
						return
					end
				end
				end
			end
		end

		local spellId = nil
		local sidLearn = nil
		if existing and existing.spellId then
			spellId = existing.spellId
			sidLearn = existing._sidLearn
		elseif matchedCast then
			spellId = (matchedCast.eligibleIcon == true) and matchedCast.spellId or nil
			sidLearn = (matchedCast.spellId ~= nil) or nil
		end

		-- Shared-target guard for the generic emit: a wound that earned no
		-- name is indistinguishable from a co-attacker's hit on the same
		-- mob. In instances it can never be proven ours; in the open world
		-- it feeds the contested detector (line-less wounds only — own
		-- damage carries a MINE line and never feeds) and dies while armed.
		if spellId == nil then
			if inInst == true then
				if zbtVetoActive() then
					dbgDrop("BYPASS_INST_UNATTR", self._castToken, school)
				else
					dbgDrop("INST_UNATTR", self._castToken, school)
					return
				end
			elseif autoContested(self, t) then
				dbgDrop("CONTESTED", self._castToken, school)
				return
			end
			-- Proc riders (mod.procRiders): guaranteed on-attack procs with
			-- no cast record. All sid claims failed — a school-matching
			-- wound riding a fresh melee anchor names itself. Emitted
			-- directly: it is a separate proc hit, not a duplicate report.
			local riderSid = pickProcRider(self, t, school)
			if riderSid then
				local pipeIdR = self._rawPipeCount + 1
				self._rawPipeCount = pipeIdR
				self._rawPipe[pipeIdR] = amount
				emit("OUTGOING_DAMAGE_COMBAT", {
					timestamp = t,
					rawPipeId = pipeIdR,
					spellId = riderSid,
					amountSource = "UNIT_COMBAT_PROC",
					targetName = safeUnitName("target"),
					isCrit = isCrit,
					procClaim = true,
					schoolMask = (ZSBT.IsSafeNumber(school) and school) or nil,
				})
				return
			end
		end

		local schoolMask = (ZSBT.IsSafeNumber(school) and school) or nil
		auditNote(("AUDMB school=%s crit=%s spellId=%s"):format(dbgSafe(school), tostring(isCrit == true), dbgSafe(spellId)))


		-- Merge window: multiple UNIT_COMBAT(target) hits can arrive per cast.
		-- Keep only the largest amount in a short window to avoid showing tiny
		-- proc/secondary values (the root cause of the "300-900 Shadow Bolt" bug).
		local token = tokenKey
		local targetName = safeUnitName("target")
		local bucket = self._bestOutgoingByToken[token]
		if not bucket then
			if not isCorroboratedHugeHit(t, amount, spellId or self._lastPlayerSpellId) then
				if dl >= 4 then
					ECPrint(("BIG_HIT_SUPPRESS src=UNIT_COMBAT_BEST_START token=%s spellId=%s amt=%s")
						:format(dbgSafe(self._castToken), dbgSafe(spellId), dbgSafe(amount)))
				end
				auditNote(("AUDD reason=BUCKET_HUGE_SUPPRESS spellId=%s school=%s"):format(dbgSafe(spellId), dbgSafe(schoolMask)))
				return
			end
			bucket = {
				timestamp = t,
				token = token,
				spellId = spellId,
				_sidLearn = sidLearn,

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
			-- The bucket exists to merge the extra wound reports a SINGLE
			-- cast produces. A wound that attributed a DIFFERENT spell is a
			-- separate hit, not a duplicate report (two casts landing
			-- together — Judgement + strike): emit it under its own name
			-- instead of letting the merge eat its number.
			if ZSBT.IsSafeNumber(spellId) and ZSBT.IsSafeNumber(bucket.spellId)
				and spellId ~= bucket.spellId then
				local pipeIdM = self._rawPipeCount + 1
				self._rawPipeCount = pipeIdM
				self._rawPipe[pipeIdM] = amount
				auditNote(("AUDMSPLIT sid=%s bsid=%s"):format(
					dbgSafe(spellId), dbgSafe(bucket.spellId)))
				emit("OUTGOING_DAMAGE_COMBAT", {
					timestamp = t,
					rawPipeId = pipeIdM,
					spellId = spellId,
					_sidLearn = sidLearn,
					amountSource = "UNIT_COMBAT_SPLIT",
					targetName = targetName,
					isCrit = isCrit,
					schoolMask = schoolMask,
				})
				return
			end
			-- A foreign hit must not ride a real spell's merge bucket: when the
			-- bucket's spell has a learned school and this hit contradicts it,
			-- emit generic instead of wearing the wrong name and amount.
			if bucket.spellId and not castSchoolOk(self, bucket.spellId, schoolMask) then
				local pipeIdM = self._rawPipeCount + 1
				self._rawPipeCount = pipeIdM
				self._rawPipe[pipeIdM] = amount
				emit("OUTGOING_DAMAGE_COMBAT", {
					timestamp = t,
					rawPipeId = pipeIdM,
					spellId = nil,
					amountSource = "UNIT_COMBAT_SCHOOL_MISMATCH",
					targetName = targetName,
					isCrit = isCrit,
					schoolMask = schoolMask,
				})
				return
			end
			-- An unnamed bucket + a differently-schooled wound is a second
			-- source, not a duplicate (seal proc riding a weapon proc) —
			-- emit it on its own instead of collapsing to max. A sid-bearing
			-- wound keeps its name here.
			if bucket.spellId == nil
				and ZSBT.IsSafeNumber(schoolMask) and ZSBT.IsSafeNumber(bucket.schoolMask)
				and schoolMask ~= bucket.schoolMask then
				local pipeIdM = self._rawPipeCount + 1
				self._rawPipeCount = pipeIdM
				self._rawPipe[pipeIdM] = amount
				auditNote(("AUDMSPLIT sid=%s school=%s bschool=%s"):format(
					dbgSafe(spellId), dbgSafe(schoolMask), dbgSafe(bucket.schoolMask)))
				emit("OUTGOING_DAMAGE_COMBAT", {
					timestamp = t,
					rawPipeId = pipeIdM,
					spellId = spellId,
					_sidLearn = sidLearn,
					amountSource = "UNIT_COMBAT_SPLIT",
					targetName = targetName,
					isCrit = isCrit,
					schoolMask = schoolMask,
				})
				return
			end
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
	if (t - self._lastCombatTextDamageAt) < DEDUP_WINDOW then
		local zI = ZSBT.ZBattleText
		if zI and zI.FileLog and ZSBT._ucDropTrace == true then
			zI:FileLog("INC_DROP reason=CT_DEDUP")
		end
		return
	end
	if unit == "player" and action == "WOUND" then
		if OutDbgLevel() >= 3 then
			if ZSBT.Addon and ZSBT.Addon.Print and (t - (Collector._dbgLastUnitCombatPlayerAt or 0)) > 0.25 then
				Collector._dbgLastUnitCombatPlayerAt = t
				ECPrint(("UNIT_COMBAT_PLAYER action=%s desc=%s amt=%s")
					:format(dbgSafe(action), dbgSafe(descriptor), dbgSafe(amount)))
			end
		end
	end
	if (t - self._lastCombatTextHealAt) < DEDUP_WINDOW then
		local zI2 = ZSBT.ZBattleText
		if zI2 and zI2.FileLog and ZSBT._ucDropTrace == true then
			zI2:FileLog("INC_DROP reason=HEAL_DEDUP")
		end
		return
	end

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
		-- Forever/secret-value clients: UNIT_COMBAT amounts arrive as secret
		-- values. Route the raw amount through the pipe so the display layer
		-- can SetText() it directly (same pattern as COMBAT_TEXT_HEAL).
		local healPipeId = self._rawPipeCount + 1
		self._rawPipeCount = healPipeId
		self._rawPipe[healPipeId] = amount
		emit("INCOMING_HEAL_COMBAT", {
			timestamp = now(),
			rawPipeId = healPipeId,
			amount = numAmount,
			amountText = amountText,
			isCrit = isCrit,
			isSecret = secret,
			school = ZSBT.IsSafeNumber(school) and school or nil,
		})
	elseif actionStr == "WOUND" then
		-- Confirmed WOUND (damage taken).
		if isPhysical and isFalling then
			local fallPipeId = self._rawPipeCount + 1
			self._rawPipeCount = fallPipeId
			self._rawPipe[fallPipeId] = amount
			emit("FALL_DAMAGE", {
				timestamp = now(),
				unit = unit,
				rawPipeId = fallPipeId,
				amount = numAmount,
				amountText = amountText,
				isCrit = false,
				isSecret = secret,
				school = isPhysical and school or 1,
			})
		else
			if not playerHealthDropped() then
				local zI3 = ZSBT.ZBattleText
				if zI3 and zI3.FileLog and ZSBT._ucDropTrace == true then
					zI3:FileLog("INC_DROP reason=HP_NODROP action=" .. tostring(actionStr))
				end
				return
			end
			local zI4 = ZSBT.ZBattleText
			if zI4 and zI4.FileLog and ZSBT._ucDropTrace == true then
				zI4:FileLog("INC_EMIT WOUND")
			end
			self._lastUnitCombatPlayerDamageAt = now()
			local dmgPipeId = self._rawPipeCount + 1
			self._rawPipeCount = dmgPipeId
			self._rawPipe[dmgPipeId] = amount
			emit("INCOMING_DAMAGE", {
				timestamp = now(),
				unit = unit,
				rawPipeId = dmgPipeId,
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
	local dl = OutDbgLevel()
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
		-- Only track player self-healing via health deltas. Non-player healing deltas
		-- (e.g. mouseover/target party members) are frequently caused by external
		-- sources and can be misclassified as outgoing heals.
		if unit == "player" then
			local healAmt = -delta
			if healAmt > 50000 then
				if dl >= 4 then
					ECPrint(("HEALTH_HEAL_CLAMP unit=%s guid=%s old=%s new=%s max=%s amt=%s")
						:format(dbgSafe(unit), dbgSafe(guid), dbgSafe(oldHealth), dbgSafe(health), dbgSafe(healthMax), dbgSafe(healAmt)))
				end
				self._lastHealth[unit] = health
				return
			end
			self._lastPlayerHealthHealAt = now()
			emit("HEALTH_HEAL", {
				timestamp = now(),
				unit = unit,
				amount = healAmt,
				targetName = safeUnitName(unit),
				health = health,
				healthMax = healthMax,
			})
		end
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
	local dl = OutDbgLevel()
	if dl >= 5 and self._dbgWWInferGatePrinted ~= true then
		self._dbgWWInferGatePrinted = true
		ECPrint("WW_INFER_GATE prevMin>=600 (UNIT_COMBAT only); chat uses explicit crit only")
	end

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
			elseif event == "PLAYER_SWING" then
				Collector:handlePlayerSwing(...)
			elseif CHAT_OUTGOING_EVENTS[event] then
				local dl = OutDbgLevel()
				local msg = select(1, ...)
				local msgSafe = type(msg) == "string" and (not ZSBT.IsSafeString or ZSBT.IsSafeString(msg))
				local zc = ZSBT.ZBattleText
				if zc and zc.FileLog and ZSBT._ucDropTrace == true then
					if msgSafe then
						zc:FileLog(("CHAT_OUT evt=%s msg=%s"):format(tostring(event), tostring(msg:sub(1, 120))))
					else
						zc:FileLog(("CHAT_OUT evt=%s msg=<unsafe>"):format(tostring(event)))
					end
				end
				if dl >= 5 then
					if msgSafe and (msg:find("Whirlwind", 1, true) or msg:find("whirlwind", 1, true)) then
						Collector._dbgWWChatRecvAt = now()
						Collector._dbgWWChatRecvCount = (Collector._dbgWWChatRecvCount or 0) + 1
						ECPrint(("CHAT_OUT WW recv evt=%s msg=%s"):format(dbgSafe(event), dbgSafe(msg:sub(1, 160))))
					end
				elseif dl >= 4 then
					if msgSafe then
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
	-- Probe the known entry points: record full arg signatures (count, type,
	-- secret status, safe previews) into a ring buffer for "/zsbt ctprobe".
	if not self._combatTextAddHooked and type(hooksecurefunc) == "function" then
		local probe = Collector._ctAddProbe or {}
		Collector._ctAddProbe = probe
		local PROBE_CAP = 300
		local function argDesc(v)
			local tv = type(v)
			if tv == "nil" then return "nil" end
			if tv == "number" then
				if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then
					return "num:" .. tostring(v)
				end
				return "num:?"
			end
			if tv == "string" then
				if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then
					local s = v
					pcall(function()
						s = (v:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "<icon>"))
					end)
					if type(s) ~= "string" then s = v end
					if #s > 48 then s = s:sub(1, 48) .. "..." end
					return "str:" .. s
				end
				return "str:?"
			end
			if tv == "boolean" then return "bool:" .. tostring(v) end
			local ok, s = pcall(tostring, v)
			if ok and type(s) == "string" then
				if #s > 32 then s = s:sub(1, 32) .. "..." end
				return tv .. ":" .. s
			end
			return tv
		end
		local hookNames = {
			"CombatText_AddMessage",
			"CombatText_AddMessage_v2",
			"CombatText_AddMessage2",
			"CombatText_AddMessage2_v2",
		}
		local fnCounts = Collector._ctAddCounts
		if type(fnCounts) ~= "table" then fnCounts = {}; Collector._ctAddCounts = fnCounts end
		local fnLastAt = Collector._ctAddLastAt
		if type(fnLastAt) ~= "table" then fnLastAt = {}; Collector._ctAddLastAt = fnLastAt end
		local function record(fnName, ...)
			fnCounts[fnName] = (fnCounts[fnName] or 0) + 1
			local tNow = now()
			-- Per-function throttle: hot utilities (e.g. EnumerateActiveFontStrings
			-- fires per frame) must not evict real message-path entries. Count
			-- every call, but only buffer/print at most one entry per fn per 0.2s.
			if (tNow - (fnLastAt[fnName] or -10)) < 0.20 then return end
			fnLastAt[fnName] = tNow
			local n = select("#", ...)
			if n > 16 then n = 16 end
			local parts = {}
			for i = 1, n do
				parts[i] = i .. "=" .. argDesc((select(i, ...)))
			end
			local sig = table.concat(parts, " | ")
			probe[#probe + 1] = { at = tNow, fn = fnName, n = select("#", ...), sig = sig }
			if #probe > PROBE_CAP then
				table.remove(probe, 1)
			end
			local dl = OutDbgLevel()
			if dl >= 4 then
				if (tNow - (Collector._dbgLastCombatTextAddAt or 0)) > 0.20 then
					Collector._dbgLastCombatTextAddAt = tNow
					ECPrint("CT_ADD " .. fnName .. " n=" .. tostring(select("#", ...)) .. " " .. sig)
				end
			end
		end
		for _, fnName in ipairs(hookNames) do
			if type(_G[fnName]) == "function" then
				self._combatTextAddHooked = true
				hooksecurefunc(fnName, function(...) record(fnName, ...) end)
			end
		end
		if self._combatTextAddHooked then
			ECPrint("CTADD_PROBE installed on CombatText_AddMessage* (use /zsbt ctprobe to dump)")
		end
		-- Widen the net: nameplate text on 12.x may not flow through the four
		-- AddMessage globals at all. Enumerate every global matching
		-- CombatText/FloatingCombatText, hook any callable not already
		-- covered, and log the full discovered list once.
		local hookedSet = {}
		for _, fnName in ipairs(hookNames) do hookedSet[fnName] = true end
		local discovered = {}
		local hookCount = 0
		for k, v in pairs(_G) do
			if type(k) == "string"
				and (k:find("CombatText") or k:find("FloatingCombatText")) then
				if type(v) == "function" then
					discovered[#discovered + 1] = k
					if not hookedSet[k] and hookCount < 60 then
						hookCount = hookCount + 1
						hooksecurefunc(k, (function(name)
							return function(...) record(name, ...) end
						end)(k))
					end
				else
					discovered[#discovered + 1] = k .. ":" .. type(v)
				end
			end
		end
		-- 12.x combat text is mixin/table-based: the AddMessage globals do not
		-- exist. Probe function members of the known combat-text tables via
		-- hooksecurefunc(table, name, fn). pcall-guarded: C_ tables and
		-- protected mixins can reject hooks.
		local tableRoots = {
			"CombatTextMixin", "CombatTextUtil", "C_CombatText", "CombatText",
			"CombatTextTypeInfo", "CombatTextConstants", "CombatTextFont",
		}
		for _, tname in ipairs(tableRoots) do
			local t = _G[tname]
			if type(t) == "table" then
				local fnames = {}
				for k, v in pairs(t) do
					if type(v) == "function" then
						fnames[#fnames + 1] = tostring(k)
						if hookCount < 80 then
							local label = tname .. "." .. tostring(k)
							local ok = pcall(hooksecurefunc, t, k, function(...) record(label, ...) end)
							if ok then hookCount = hookCount + 1 end
						end
					end
				end
				table.sort(fnames)
				local shown = table.concat(fnames, ",")
				if #shown > 400 then shown = shown:sub(1, 400) .. "..." end
				discovered[#discovered + 1] = tname .. "={" .. shown .. "}"
			end
		end
		table.sort(discovered)
		Collector._ctAddDiscovered = discovered
		ECPrint("CTADD_SCAN hooks=" .. tostring(hookCount) .. " :: " .. table.concat(discovered, ", "))
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
	-- PLAYER_SWING: public per-swing report on 12.x. Registered in a pcall —
	-- an unsupported client marks _swingSupported false and auto claims
	-- keep the legacy permissive path.
	self._swingSupported = pcall(function() self._frame:RegisterEvent("PLAYER_SWING") end) == true
	-- Restore learned spell schools from the profile so the school gate
	-- keeps its ratchet across /reload. Votes seed at threshold so a saved
	-- school isn't instantly flippable.
	-- v2: values learned before provenance-gated learning may be poisoned
	-- (a foreign hit's stolen line taught Demonbolt "Holy"); wipe once.
	-- Any saved school that contradicts the spell's own tooltip-declared
	-- school is also dropped — the tooltip is authoritative.
	do
		local prof = ZSBT.db and ZSBT.db.profile
		local saved = type(prof) == "table" and prof.learnedSpellSchools or nil
		if type(prof) == "table" and prof.learnedSpellSchoolsVer ~= 2 then
			saved = nil
			prof.learnedSpellSchools = {}
			prof.learnedSpellSchoolsVer = 2
		end
		if type(saved) == "table" then
			for sid, school in pairs(saved) do
				if type(sid) == "number" and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school) then
					local facts = SpellFacts(sid)
					if not (facts and type(facts.school) == "number" and not spellSchoolFits(facts.school, school)) then
						self._learnedSpellSchool[sid] = school
						local v = self._schoolVotes[sid]
						if type(v) ~= "table" then v = {} self._schoolVotes[sid] = v end
						v[school] = math.max(v[school] or 0, SCHOOL_LEARN_VOTES)
					end
				end
			end
		end
	end
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
		pcall(function() self._frame:UnregisterEvent("PLAYER_SWING") end)
		for evtName in pairs(CHAT_OUTGOING_EVENTS) do
			pcall(function() self._frame:UnregisterEvent(evtName) end)
		end
	end
	resetFallingState()
	-- Drop queued/deferred work so nothing emits against pre-disable
	-- state on re-enable: merge buckets, deferred heal pairing, and the
	-- line-arrival hook all reference wounds that are already dead.
	self._bestOutgoingByToken = {}
	self._pendingHotHeal = nil
	self._hotTickState = nil
	self._healClaimByGuid = nil
	self._healClaimByName = nil
	self._lastAutoCandAt = nil
	self._autoContestUntil = nil
	local zb = ZSBT.ZBattleText
	if zb and zb._healLineHook then
		zb._healLineHook = nil
	end
	self._enabled = false
	self._lastHealth = {}
	self._lastPlayerSpellName = nil
	self._lastPlayerSpellId = nil
end
