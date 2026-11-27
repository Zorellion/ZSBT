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

-- Read a unit's GUID, tolerating secret/absent returns. GUIDs are the
-- identity channel the UT kill-announcer uses when names are secret.
local function safeTargetGUID(unit)
	if not unit or type(UnitGUID) ~= "function" then return nil end
	local ok, value = pcall(UnitGUID, unit)
	-- Secret strings report type()=="string" but throw on any comparison
	-- (incl. == ""), so the safety filter must run before the empty check.
	if not ok or type(value) ~= "string" then return nil end
	if ZSBT.IsSafeString and not ZSBT.IsSafeString(value) then return nil end
	if value == "" then return nil end
	return value
end

-- Chaos school (127) tooltips cover every school; hits may report the
-- composite masks 124/126.
local function spellSchoolFits(learned, school)
	if learned == nil or school == nil then return true end
	if learned == school then return true end
	return learned == 127 and (school == 124 or school == 126)
end

local castSchoolOk -- fwd decl; real def below
local auraSpellName -- fwd decl; pet-evidence veto calls it before the real def below
local consumeBestPendingCast -- fwd decl; emit() calls it before the real def below
local miwClaim -- fwd decl; emit() calls it before the real def below
local claimSignature -- fwd decl; emit() calls it before the real def below
local sigBaseForTrigger -- fwd decl; same reason
local sigEmpowerForTrigger -- fwd decl; same reason
local sigSeed -- fwd decl; enqueuePendingCast calls it before the real def below
local anySwingRecent -- fwd decl; emit() stamps _swingProven before the real def below
local swingPredictedNear -- fwd decl; emit() stamps _swingGuessed before the real def below

-- Friendly non-player casts (pet slot, imps, guardians) recorded in
-- _petCasts. A hit claims one of them instead of taking the most recent
-- unconditionally: the newest school-fitting cast wins (candidate
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
-- it is first parsed — no confirmed-hit bootstrap needed. The full
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
				facts = { school = (not multi) and school or nil, damages = harms,
					heals = (lower:find("heals you") or lower:find("heal you")
						or lower:find("healing you") or lower:find("friendly target"))
						and true or nil }
			else
				facts = { damages = false }
			end
		elseif type(C_Spell.RequestLoadSpellData) == "function" then
			pcall(C_Spell.RequestLoadSpellData, spellId)
		end
	end
	-- Module-declared facts override the tooltip parse: proc spells whose
	-- descriptions never say "<school> damage" (Infliction of Sorrow:
	-- "deals 10% of the remaining damage") parse as damages=false and can
	-- never name their own hits without an explicit entry.
	local ovr = ZSBT.ClassDB and ZSBT.ClassDB.SpellFactOverride
		and ZSBT.ClassDB.SpellFactOverride(spellId) or nil
	if type(ovr) == "table" then
		facts = facts or {}
		if ovr.damages ~= nil then facts.damages = ovr.damages end
		if type(ovr.school) == "number" then facts.school = ovr.school end
		if ovr.heals ~= nil then facts.heals = ovr.heals end
	end
	if facts then spellFactsCache[spellId] = facts end
	return facts
end

-- A cast may only claim a hit it can plausibly have made:
-- * a spell whose own tooltip deals no damage claims nothing;
-- * a tooltip-declared school is authoritative (catalog facts);
-- * a school learned from confirmed hits gates identically;
-- * unknown stays permissive (a guess).
-- This is what stops "Consecration shown as Shadow Bolt".
castSchoolOk = function(self, spellId, school)
	if type(spellId) ~= "number" then return true end
	-- Secret spellIds can't index or compare — permissive, like unknown.
	if ZSBT.IsSafeNumber and not ZSBT.IsSafeNumber(spellId) then return true end
	-- Wand sid: Shoot's own spell school reads 0x1 regardless of the
	-- equipped wand's element, so facts/tooltips cannot prove a wand
	-- wound's school — but the learned weapon school can. Once known it
	-- is authoritative: a wound of another school is never this cast's
	-- shot (an arcane wand's pending record claimed a school-4 Immolate
	-- tick). Unknown stays permissive — same contract as below.
	if ZSBT.ClassDB and ZSBT.ClassDB.PreferRangedLine
		and ZSBT.ClassDB.PreferRangedLine(spellId) then
		-- Physical boundary holds even before the element learns: no
		-- ranged-family sid is ever phys (wand shots are elemental,
		-- Bleak Arrows is shadow) — a school-1 wound is someone's swing.
		-- Observed: hunter phys wounds (Cobra/Barbed/melee) consuming the
		-- Bleak record every ~2.4s auto-swing while _wandSchool bootstraps.
		if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school)
			and school == 1 then return false end
		local ws = self._wandSchool
		if type(ws) == "number" and ZSBT.IsSafeNumber
			and ZSBT.IsSafeNumber(school) then
			return spellSchoolFits(ws, school)
		end
		-- Bootstrap fallback: the learned school from prior claims gates
		-- while the wand vote is still collecting (permissive if neither).
		local learned = self._learnedSpellSchool
			and self._learnedSpellSchool[spellId]
		if type(learned) == "number" and ZSBT.IsSafeNumber
			and ZSBT.IsSafeNumber(school) then
			return spellSchoolFits(learned, school)
		end
		return true
	end
	-- Forever: UNIT_COMBAT's wound school is unreliable (paladin Holy
	-- hits arrive as 32), so it can't veto a *player* cast record's own
	-- school — age-recency matching stays and the palette line proves
	-- ownership. Pet records keep the check: their ids aren't player
	-- spells, and school is all that stops an imp's Firebolt record
	-- from claiming a melee wound.
	-- The physical boundary still holds even for player casts: a
	-- school-1 wound is someone's swing — the paladin anomaly was
	-- magic-vs-magic, never phys-vs-magic — and letting phys wounds eat
	-- cast records misattributes pet/co-attacker melee (observed:
	-- Corruption's pending record claimed a school-1 wound). Only a
	-- declared/learned school vetoes; undeclared keeps the exemption.
	if ZSBT.ClassDB and ZSBT.ClassDB.IsForever and ZSBT.ClassDB.IsForever()
		and isPlayerSpellId(spellId) then
		if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school) and school == 1 then
			local facts = SpellFacts(spellId)
			if facts and facts.damages == false then return false end
			if facts and type(facts.school) == "number" then
				return spellSchoolFits(facts.school, school)
			end
			if ZSBT.ClassDB and ZSBT.ClassDB.DeclaredSchoolFits then
				local fits = ZSBT.ClassDB.DeclaredSchoolFits(spellId, school)
				if fits ~= nil then return fits end
			end
			local learned = self._learnedSpellSchool and self._learnedSpellSchool[spellId]
			if learned ~= nil then return spellSchoolFits(learned, school) end
		end
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
local function auditNote(fmt, ...)
	if ZSBT._auditTrace ~= true then return end
	local msg = (select("#", ...) > 0) and fmt:format(...) or fmt
	local zbt = ZSBT.ZBattleText
	if zbt and zbt.Audit then zbt:Audit(msg) end
end
-- Secret-value compare/call helpers: hoisted so hot paths can pcall() them
-- without allocating a fresh closure per event.
local function _secTrue(v) return v == true end
local function _secEq(a, b) return a == b end
local function _secFieldEq(t, k, v) return t[k] == v end
local function _secDebuffHit(e, g, t) return e.guid == g and t < e.expiry end
local function _secFindYour(m) return m:find("Your ", 1, true) == 1 end
local function _secAurasOpen() return C_Secrets.ShouldAurasBeSecret() == false end
local function _secStripCodes(s)
	return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "<icon>"))
end

-- Per-cast-instance claim counts: claims[sid] = array of { at=, n= } records.
-- The off-target cleave scan walks this on every foreign wound — nested
-- numeric keys avoid building "sid@at" strings on write and matching them
-- back apart per entry on read.
local function castClaimGet(self, sid, at)
	local list = self._castClaims and self._castClaims[sid]
	if not list then return 0 end
	for i = 1, #list do
		local rec = list[i]
		if rec.at == at then return rec.n or 0 end
	end
	return 0
end

local function castClaimAdd(self, sid, at)
	local claims = self._castClaims
	if not claims then claims = {} ; self._castClaims = claims end
	local list = claims[sid]
	if not list then list = {} ; claims[sid] = list end
	for i = 1, #list do
		local rec = list[i]
		if rec.at == at then
			rec.n = (rec.n or 0) + 1
			return
		end
	end
	list[#list + 1] = { at = at, n = 1 }
end


local function emit(eventType, payload)
	-- ZBattleText ownership veto: when the combat-log filter is trusted,
	-- ambiguous outgoing damage must be corroborated by a palette line.
	-- Untrusted => OfferOutgoing returns true and nothing changes.
	if eventType == "OUTGOING_DAMAGE_COMBAT" and payload then
		-- Budget-claim ordinal for the noline-theft gate: miwClaim sets
		-- _miwOrd when a wound takes a slot of a shared cast record.
		-- Stamp and clear so a stale ordinal can never tag a payload
		-- whose sid came from a different path.
		if payload.spellId ~= nil and Collector._miwOrd ~= nil then
			payload._claimOrd = Collector._miwOrd
		end
		Collector._miwOrd = nil
		-- Melee anchor for proc riders: a school-1 wound that actually
		-- EMITTED as ours (named claim or auto emit) proves a weapon
		-- attack happened. Stamping at emit time — not wound arrival —
		-- means a co-attacker's bare swing can never feed the anchor
		-- during a contested lapse; foreign wounds never get this far.
		if payload.schoolMask == 1
			and (payload.isAuto == true or payload.spellId ~= nil) then
			Collector._lastPhysWoundAt = payload.timestamp or now()
		end
		-- Wand family anchor: a ranged-declared sid emitting proves a
		-- shot landed. Auto-shoot wounds continue for the whole wand
		-- session after the activation's single cast record is spent, so
		-- the last claimed shot re-arms pickWandShot.
		if payload.spellId ~= nil and ZSBT.ClassDB
			and ZSBT.ClassDB.PreferRangedLine
			and ZSBT.ClassDB.PreferRangedLine(payload.spellId) then
			Collector._wandSid = payload.spellId
			Collector._wandAt = payload.timestamp or now()
			-- Wand-element vote: claimed shots teach the school when the
			-- ranged-slot tooltip can't be read (wand-vote model). Only a
			-- ranged-line-proven claim votes — a pending-cast claim that
			-- consumed a wrong-school wound would teach the wrong element
			-- during bootstrap and then gate real shots out.
			local wm = payload.schoolMask
			if payload.wandProven == true
				and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(wm) and wm ~= 1
				and Collector._wandSchool == nil then
				local wv = Collector._wandVotes
				if not wv then wv = {} ; Collector._wandVotes = wv end
				wv[wm] = (wv[wm] or 0) + 1
				if wv[wm] >= 2 then Collector._wandSchool = wm end
			end
		end
		-- Last shot for the player's own cast before pet-claiming: nuke
		-- hits with travel time (HoG/Implosion/Demonbolt) can miss the
		-- 0.85s candidate window upstream and would otherwise die
		-- unattributed in the pet bucket. A still-queued record means no
		-- hit has claimed this cast yet, so consuming it here is always
		-- that cast's first legitimate outcome.
		if payload.spellId == nil and payload.schoolMask ~= 1 and payload._petRoute ~= false then
			local mc = consumeBestPendingCast(Collector, payload.timestamp or now(), nil, 2.0, true, payload.schoolMask)
			if mc == nil then
				-- AoE tail: the cast's pending record is already spent on
				-- another target's hit, but the per-cast class budget may
				-- still have room. Without this, Implosion/HoG splash hits
				-- fall through to pet naming and wear a guardian's name
				-- into the pet scroll.
				local lastId, lastAt = Collector._lastPlayerSpellId, Collector._lastPlayerSpellAt
				local t = payload.timestamp or now()
				if type(lastId) == "number" and type(lastAt) == "number"
					and (t - lastAt) >= 0 and (t - lastAt) <= 1.5
					and castSchoolOk(Collector, lastId, payload.schoolMask)
					and miwClaim(Collector, lastId, lastAt, t, payload.schoolMask) then
					mc = { spellId = lastId }
				end
			end
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
					auditNote("AUDSCH defer-contested school=%s crit=%s", 
						tostring(payload.schoolMask), tostring(payload.isCrit == true))
				else
					auditNote("AUDSCH bypass=line school=%s kind=%s", 
						tostring(payload.schoolMask), tostring(lineProof))
				end
			else
				payload._foreignSchool = true
				auditNote("AUDSCH defer school=%s crit=%s", 
					tostring(payload.schoolMask), tostring(payload.isCrit == true))
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
		-- Retail has no swing event — the learned cadence stamps
		-- _swingGuessed instead, a weaker proven tier gated through a
		-- narrowed foreign-line check at the noline rescue.
		if payload.spellId == nil and payload.schoolMask == 1
			and payload._petRoute ~= true
			and not (ZSBT.ClassDB and ZSBT.ClassDB.VetoAuto
				and ZSBT.ClassDB.VetoAuto()) then
			-- _petRoute/vetoAuto exclusions: a pet-routed wound is never our
			-- swing's hit (a ranged report covers all schools for 2.0s —
			-- warlock pet melee wore _swingProven and died fnear at tier-1),
			-- and a no-auto class has no swing to prove.
			if Collector._swingSupported == true
				and anySwingRecent(Collector, payload.timestamp or now()) then
				payload._swingProven = true
			elseif Collector._swingSupported ~= true
				and swingPredictedNear(Collector, payload.timestamp or now()) then
				payload._swingGuessed = true
			end
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
				zbtX:FileLog("PET_ROUTE_STRIP sid=%s school=%s", 
					tostring(payload.spellId), tostring(payload.schoolMask))
			end
		else
			sinkType = "PET_DAMAGE_COMBAT"
			local zbt3 = ZSBT.ZBattleText
			if zbt3 and zbt3.FileLog then
				zbt3:FileLog("PET_ROUTE petSid=%s school=%s", tostring(payload.petSpellId), tostring(payload.schoolMask))
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
		-- Cadence anchor for the Retail swing predictor: a school-1 sid=nil
		-- hit reaching the sink is a confirmed own auto (queued candidates
		-- that die never get here). Pet-routed payloads are excluded —
		-- pet melee is not our swing.
		if sinkType == "OUTGOING_DAMAGE_COMBAT" and payload
			and payload.schoolMask == 1 and payload.spellId == nil
			and payload._petRoute ~= true then
			Collector:NoteSwingAnchor(payload.timestamp or now())
		end
		-- Hit->display latency for the ucdrop trace: timestamp is the
		-- UNIT_COMBAT hit time, so dly captures veto defer + merge +
		-- dispatch cost. Anything above ~0.5s is pipeline, not scroll anim.
		if ZSBT.ZBattleText and ZSBT.ZBattleText.FileLog and payload and payload.timestamp then
			ZSBT.ZBattleText:FileLog("SHOW %s sid=%s psid=%s pev=%s ht=%.3f dly=%.2f", 
				sinkType, tostring(payload.spellId), tostring(payload.petSpellId),
				tostring(payload.petEvidence), tonumber(payload.timestamp) or 0,
				now() - payload.timestamp)
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
	auditNote("AUDD reason=%s token=%s school=%s", 
		tostring(reason), dbgSafe(tok), dbgSafe(school))
	if OutDbgLevel() >= 4 or ZSBT._ucDropTrace == true then
		ECPrint(("UC_DROP reason=%s token=%s school=%s"):format(reason, dbgSafe(tok), dbgSafe(school)))
		local z = ZSBT.ZBattleText
		if z and z.FileLog then
			z:FileLog("UC_DROP reason=%s token=%s school=%s", tostring(reason), dbgSafe(tok), dbgSafe(school))
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
	self._lastOutgoingCombatTargetGUID = bucket.targetGUID or safeTargetGUID("target")
	if self._lastOutgoingCombatTargetGUID then
		local m = self._ownAtByGuid or {}; self._ownAtByGuid = m
		m[self._lastOutgoingCombatTargetGUID] = self._lastOutgoingCombatAt

		local n = 0
		for _ in pairs(m) do n = n + 1; if n > 48 then break end end
		if n > 48 then
			local cut = self._lastOutgoingCombatAt - 6
			for k, v in pairs(m) do if v < cut then m[k] = nil end end
		end
	end
	if (tonumber(dl) or 0) >= 4 then
		ECPrint(("FLUSH_BEST token=%s spellId=%s amt=%s school=%s crit=%s cnt=%s max=%s second=%s")
			:format(dbgSafe(token), dbgSafe(bucket.spellId), dbgSafe(bucket.amount), dbgSafe(bucket.schoolMask), dbgSafe(bucket.isCrit), dbgSafe(bucket._seenCount), dbgSafe(bucket._seenMax), dbgSafe(bucket._seenSecond)))
	end

	local zbt = ZSBT.ZBattleText
	if zbt and zbt.FileLog then
		zbt:FileLog("FLUSH sid=%s school=%s cnt=%s crit=%s", tostring(bucket.spellId), tostring(bucket.schoolMask), tostring(bucket._seenCount), tostring(bucket.isCrit))

	end
	auditNote("AUDFLUSH sid=%s school=%s cnt=%s crit=%s", 
		tostring(bucket.spellId), tostring(bucket.schoolMask), tostring(bucket._seenCount), tostring(bucket.isCrit == true))
	emit("OUTGOING_DAMAGE_COMBAT", {
		timestamp = bucket.timestamp,
		rawPipeId = pipeId,
		spellId = bucket.spellId,
		_sidLearn = bucket._sidLearn,
		wandProven = bucket.wandProven,
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
-- outgoing hits. Unconfirmed hits never teach (trust/doubt): a foreign
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
local function seedDotApplicationOnUnit(self, spellId, unit, at)
	self._recentPeriodicSpellAt[spellId] = at
	self._dotAppliedAt = self._dotAppliedAt or {}
	self._dotAppliedAt[spellId] = at
	-- Per-target application map for the disambiguation path:
	-- tab-dotting needs each mob's own phase anchor, and a wound on
	-- the current target must not claim a dot applied elsewhere.
	local tgtName = safeUnitName(unit)
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
		local okG, g = pcall(UnitGUID, unit)
		if okG and ZSBT.IsSafeString and ZSBT.IsSafeString(g) then
			local gm = self._dotAppliedGuid
			if not gm then gm = {} ; self._dotAppliedGuid = gm end
			local sm = gm[spellId]
			if not sm then sm = {} ; gm[spellId] = sm end
			sm[g] = at
		end
	end
end

local function seedDotApplication(self, spellId, at)
	-- A SENT-bound target outranks "target": the press-time recipient is
	-- the real application mob even if the player re-targeted mid-cast.
	if self._lastCastTargetAt == at
		and ZSBT.IsSafeString and ZSBT.IsSafeString(self._lastCastTargetName) then
		local tn = self._lastCastTargetName
		self._recentPeriodicSpellAt[spellId] = at
		self._dotAppliedAt = self._dotAppliedAt or {}
		self._dotAppliedAt[spellId] = at
		local map = self._dotAppliedTarget
		if not map then map = {} ; self._dotAppliedTarget = map end
		local sm = map[spellId]
		if not sm then sm = {} ; map[spellId] = sm end
		sm[tn] = at
		local tg = self._lastCastTargetGuid
		if ZSBT.IsSafeString and ZSBT.IsSafeString(tg) then
			local gm = self._dotAppliedGuid
			if not gm then gm = {} ; self._dotAppliedGuid = gm end
			local sg = gm[spellId]
			if not sg then sg = {} ; gm[spellId] = sg end
			sg[tg] = at
		end
		return
	end
	seedDotApplicationOnUnit(self, spellId, "target", at)
end

local isPlayerClassTag
local isWhirlwindSpellId

if type(_G.isPlayerClassTag) ~= "function" then
	_G.isPlayerClassTag = function(tag)
		if type(tag) ~= "string" or tag == "" then return false end
		if type(UnitClass) ~= "function" then return false end
		local ok, _, classTag = pcall(UnitClass, "player")
		-- classTag may be a secret string — guard before comparing.
		return ok and type(classTag) == "string"
			and (not ZSBT.IsSafeString or ZSBT.IsSafeString(classTag))
			and classTag == tag
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
		return rec.interval, true
	end
	if entry and type(entry.interval) == "number" and entry.interval > 0 then
		return entry.interval, true
	end
	-- Channel-owned sids: the module's channel interval is the tick period
	-- (era drains tick at 1s; a 2.0 default would reject real ticks).
	if ZSBT.ClassDB and ZSBT.ClassDB.ChannelMatch then
		local ch = ZSBT.ClassDB.ChannelMatch(spellId)
		if ch and type(ch.interval) == "number" and ch.interval > 0 then
			return ch.interval, true
		end
	end
	return DOT_DEFAULT_TICK_INTERVAL, false
end

-- Learned periods (rec.period / persisted learnedDotPeriods) only refine
-- declared data — they may never replace it outright. A poisoned value
-- (one bad first gap births rec.period; every real gap then fails the
-- refine window, sealing the error and persisting it across sessions —
-- Corruption stuck at 1.994 vs its true 3.0, ratio 0.66) is detected by
-- bounding the learned value to 0.7-1.4x the declared interval: the band
-- covers haste-class drift but not a half-rate poison. Untrusted defaults
-- (no declared source) don't bound: learning is all those sids have.
local function boundedDotPeriod(self, spellId, entry)
	entry = entry or dotEntryForSpellId(spellId)
	local decl, trusted = dotTickInterval(spellId, entry)
	local st = self._dotTickState
	local rec = type(st) == "table" and st[spellId] or nil
	local prof = ZSBT.db and ZSBT.db.profile
	local learned = (rec and type(rec.period) == "number" and rec.period > 0 and rec.period)
		or (prof and prof.learnedDotPeriods and prof.learnedDotPeriods[spellId])
	if type(learned) == "number" and learned > 0
		and (not trusted or (learned >= decl * 0.7 and learned <= decl * 1.4)) then
		return learned
	end
	return decl
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
	-- Learned period refines the declared interval within a sanity band —
	-- never replaces it (boundedDotPeriod rejects poisoned values).
	local iv = boundedDotPeriod(self, spellId, entry)
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
			local okC, eq = pcall(_secTrue, res)
			if okC and eq == true then return nil, nil, "self" end
		end
	end
	-- An attackable unit cannot receive the player's healing; if it
	-- reports a HEAL it is the mob's own regen, not outgoing.
	if UnitCanAttack then
		local okH, h = pcall(UnitCanAttack, "player", unit)
		if okH then
			local okC, eq = pcall(_secTrue, h)
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
						auditNote("AUDH unit=%s sid=%s defer=1", 
							dbgSafe(e.unit), tostring(hsid))
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
	-- Can't-be evidence: a direct/melee/ranged/shield palette line near
	-- the wound means a direct hit, never a periodic tick — no dot may
	-- claim it. Peeked only when no tick line exists (both present =
	-- ambiguous environment; cadence decides instead). Direct hits like
	-- Blood Mist procs and cleave waves were wearing dot names without
	-- this veto.
	local zbtVeto = ZSBT.ZBattleText
	if zbtVeto and zbtVeto.PeekDamageLine
		and zbtVeto:PeekDamageLine(t, 0.30, { tick = true }) == nil
		and zbtVeto:PeekDamageLine(t, 0.30,
			{ direct = true, melee = true, ranged = true, shield = true }) ~= nil then
		return nil
	end
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
	-- Secret GUIDs report type()=="string" but throw on compare/strsplit —
	-- filter them before the empty check (unusable here anyway).
	if not okG or type(guid) ~= "string" then return nil end
	if ZSBT.IsSafeString and not ZSBT.IsSafeString(guid) then return nil end
	if guid == "" then return nil end
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

-- PLAYER_SWING gives a public per-swing report (melee/ranged) — Forever
-- client only; the event does not exist on Retail. Timing model:
-- a melee hit lands ~0.45s after its
-- swing report; ranged shots fly 0.05-2.0s (forward only — a shot never
-- claims a hit that preceded the report). The lag is learned PER HAND —
-- a dual wielder's two weapons land after different delays — from wounds
-- emitted inside the pairing window (NoteSwingAnchor). Before 3 samples
-- per hand the window is the recorded range [0.25, 0.9]; afterwards it
-- tightens to lag-0.10 .. lag+0.15 so a teammate's blow landing just
-- after our swing can't take our swing's slot. Variable hands keep the
-- wide range. A hit may also arrive one extra animation late (measured
-- 0.98-1.31s on a rogue): a second window at lag+[0.25, 0.9] covers it
-- and never teaches. Finally the report may FOLLOW its wound by up to
-- 0.35s — ZBattleText's flush re-tests queued wounds retroactively.
local SWING_LAG_SAMPLES = 9
local SWING_MIN_LAG, SWING_MAX_LAG = 0.25, 0.9
local SWING_EARLY, SWING_LATE = 0.10, 0.15
local SWING_DELAYED_FROM, SWING_DELAYED_TO = 0.25, 0.9
local SWING_USUAL_DELAY = 0.45
local SWING_LATE_SWING = 0.35
local RANGED_HIT_WINDOW = 2.0

local _swingHands
local function swingHandName(swingType)
	-- Forever passes numeric Enum.PlayerSwingType; accept strings too.
	if type(swingType) == "string" and swingType ~= "" then return swingType end
	if not _swingHands then
		_swingHands = {}
		local kinds = Enum and Enum.PlayerSwingType
		if kinds then
			if kinds.MainHand then _swingHands[kinds.MainHand] = "main" end
			if kinds.OffHand then _swingHands[kinds.OffHand] = "off" end
			if kinds.Ranged then _swingHands[kinds.Ranged] = "ranged" end
		end
	end
	return _swingHands[swingType]
end

local function swingMedianLag(lags)
	if type(lags) ~= "table" or #lags < 3 then return nil end
	local sorted = {}
	for i = 1, #lags do sorted[i] = lags[i] end
	table.sort(sorted)
	return sorted[math.floor((#sorted + 1) / 2)]
end

local function meleeLagWindow(self, hand)
	local lags = self._swingLags and self._swingLags[hand]
	local lag = swingMedianLag(lags)
	if not lag then return SWING_MIN_LAG, SWING_MAX_LAG, SWING_USUAL_DELAY end
	local early = math.max(0.05, lag - SWING_EARLY)
	local late = lag + SWING_LATE
	for _, d in ipairs(lags) do
		if d < early or d > late then
			return math.min(SWING_MIN_LAG, early), math.max(SWING_MAX_LAG, late), lag
		end
	end
	return early, late, lag
end

anySwingRecent = function(self, t)
	local sw = self._swingAt
	if type(sw) ~= "table" then return false end
	for hand, at in pairs(sw) do
		local dt = t - at
		if hand == "ranged" or hand == "RANGED" then
			if dt >= 0.05 and dt <= RANGED_HIT_WINDOW then return true end
		elseif dt < 0 then
			if dt >= -SWING_LATE_SWING then return true end
		else
			local early, late, lag = meleeLagWindow(self, hand)
			if (dt >= early and dt <= late)
				or (dt >= lag + SWING_DELAYED_FROM
					and dt <= lag + SWING_DELAYED_TO) then
				return true
			end
		end
	end
	return false
end

-- Public for ZBattleText's flush-time late-swing upgrade: a queued wound's
-- swing may arrive between emit and flush (negative dt above).
function Collector:SwingCovers(t)
	return anySwingRecent(self, t)
end

-- Retail swing cadence: with no per-swing event, learn our own auto
-- rhythm instead. Every school-1 sid=nil wound that EMITS as ours is a
-- confirmed auto anchor; the median anchor gap is the swing interval;
-- wounds within slack of a predicted tick are swing-plausible and get
-- _swingGuessed — a weaker proven tier that reaches the noline rescue
-- only through a narrowed foreign-line gate (a foreign wound's own
-- line arrives same-frame, so a tight window still vetoes it).
-- Anchors come from emitted shows only, never bare wounds — a
-- co-attacker's swing can never seed the model.
local SWING_GUESS_MAX_ANCHORS = 12
local SWING_GUESS_MIN_GAP, SWING_GUESS_MAX_GAP = 0.4, 5.0
local SWING_GUESS_HORIZON_TICKS = 2.5
local SWING_GUESS_SLACK_FRAC, SWING_GUESS_SLACK_MAX = 0.30, 0.35

function Collector:NoteSwingAnchor(t)
	if type(t) ~= "number" then return end
	-- Forever path: pair the emitted wound with the melee swing whose
	-- window it fell inside and learn that hand's lag (median of up to
	-- SWING_LAG_SAMPLES). In-window hits only — a delayed-window hit
	-- never teaches, and a wound fitting both hands pairs to the
	-- nearer report. An emitted wound that fits NO window teaches
	-- nothing (it was a proc, not a swing's hit).
	if self._swingSupported == true then
		local sw = self._swingAt
		if type(sw) == "table" then
			local bestHand, bestDt = nil, nil
			for hand, at in pairs(sw) do
				if hand ~= "ranged" and hand ~= "RANGED" then
					local dt = t - at
					local early, late = meleeLagWindow(self, hand)
					if dt >= early and dt <= late
						and (bestDt == nil or dt < bestDt) then
						bestHand, bestDt = hand, dt
					end
				end
			end
			if bestHand then
				self._swingLags = self._swingLags or {}
				local lags = self._swingLags[bestHand]
				if type(lags) ~= "table" then
					lags = {}
					self._swingLags[bestHand] = lags
				end
				lags[#lags + 1] = bestDt
				while #lags > SWING_LAG_SAMPLES do table.remove(lags, 1) end
			end
		end
		return
	end
	local L = self._swingLearn
	if type(L) ~= "table" then
		L = { anchors = {} }
		self._swingLearn = L
	end
	local a = L.anchors
	a[#a + 1] = t
	if #a > SWING_GUESS_MAX_ANCHORS then table.remove(a, 1) end
	local gaps = {}
	for i = math.max(2, #a - 8), #a do
		local g = a[i] - a[i - 1]
		if g >= SWING_GUESS_MIN_GAP and g <= SWING_GUESS_MAX_GAP then
			gaps[#gaps + 1] = g
		end
	end
	if #gaps >= 2 then
		-- Harmonic voting: sparse anchors produce gaps that are
		-- multiples of the true interval (a missed show every other
		-- beat), so a bare median learns a double interval. Each gap
		-- votes for itself and its /2, /3 divisors — the true root
		-- collects votes from every multiple; a double interval only
		-- collects its own. Measured need: 35 anchors in 155s never
		-- locked a ~1.3s fury cadence under the median.
		local votes = {}
		for _, g in ipairs(gaps) do
			for d = 1, 3 do
				local iv = g / d
				if iv >= SWING_GUESS_MIN_GAP then
					local merged = false
					for _, v in ipairs(votes) do
						if math.abs(v.iv - iv) <= 0.15 then
							v.n = v.n + 1
							v.iv = (v.iv * (v.n - 1) + iv) / v.n
							merged = true
							break
						end
					end
					if not merged then
						votes[#votes + 1] = { iv = iv, n = 1 }
					end
				end
			end
		end
		local best = nil
		for _, v in ipairs(votes) do
			if not best or v.n > best.n then best = v end
		end
		if best then L.interval = best.iv end
	end
	-- Refresh the horizon on every anchor whenever an interval exists —
	-- a UnitAttackSpeed-seeded interval engages prediction from the
	-- first anchor instead of waiting for a second emitted gap.
	if type(L.interval) == "number" then
		L.horizon = t + L.interval * SWING_GUESS_HORIZON_TICKS
	end
end

swingPredictedNear = function(self, t, slackMul)
	local L = self._swingLearn
	if type(L) ~= "table" then
		L = { anchors = {} }
		self._swingLearn = L
	end
	-- Cold-start seed: before emitted anchors teach the cadence, fall
	-- back to the weapon speed when the client exposes it (returns
	-- secret in combat on some builds — the IsSafeNumber gate skips it
	-- there). Retry on a throttle rather than burning one attempt: a
	-- build that answers out of combat or after a haste shift still
	-- gets seeded. Dual wield seeds the combined rate (hits land ~at
	-- 1/(1/mh + 1/oh)); a single speed under-predicts rather than
	-- over-predicts, which is the safe miss direction. Learned anchor
	-- gaps overwrite the seed the moment two shows land.
	if type(L.interval) ~= "number" and t - (L.seedTryAt or 0) > 5 then
		L.seedTryAt = t
		if UnitAttackSpeed then
			local okS, mh, oh = pcall(UnitAttackSpeed, "player")
			if okS and ZSBT.IsSafeNumber then
				local iv = nil
				if ZSBT.IsSafeNumber(mh) and mh > 0 then
					iv = mh
					if ZSBT.IsSafeNumber(oh) and oh > 0 then
						iv = 1 / (1 / mh + 1 / oh)
					end
				end
				if iv then
					L.interval = math.max(SWING_GUESS_MIN_GAP,
						math.min(SWING_GUESS_MAX_GAP, iv))
				end
			end
		end
	end
	if type(L.interval) ~= "number" then return false end
	if type(L.horizon) ~= "number" or t > L.horizon then return false end
	local last = L.anchors[#L.anchors]
	if type(last) ~= "number" then return false end
	local k = math.floor((t - last) / L.interval + 0.5)
	if k < -1 or k > math.ceil(SWING_GUESS_HORIZON_TICKS) then return false end
	-- slackMul shrinks the beat window for precision-sensitive callers:
	-- the phys claim gate passes ~0.35 (real swings land ±~0.05s of the
	-- predicted beat; a wide window eats ability hits that merely
	-- coincide). Classifier vetoes use the default (recall-friendly).
	local slack = math.min(SWING_GUESS_SLACK_MAX, L.interval * SWING_GUESS_SLACK_FRAC) * (slackMul or 1)
	return math.abs(t - (last + k * L.interval)) <= slack
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
	-- Always-on: the detector arms the contested gate and suppresses
	-- unattributed auto wounds when a second attacker cadence shows.
	-- The former hideAutoContested toggle had wider scope than its name
	-- implied and was removed from the UI; db key is dormant.
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
		local ok, matches = pcall(_secDebuffHit, entry, guid, t)
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
	-- Typed-line evidence: the combat-log filter classifies
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
	-- Wand veto: while a wand family is live a RANGED line near the
	-- wound is the client's proof a shot fired — such a wound is never a
	-- dot tick (the derived NOT: ranged line => not-periodic). A tick
	-- line still wins a same-instant collision (real tick + real shot).
	-- includeConsumed: the shot's own claim may have eaten the line.
	if tickLine == nil and self._wandSid ~= nil and zbt and zbt.PeekDamageLine
		and zbt:PeekDamageLine(t, 0.35, { ranged = true }, true) ~= nil then
		return nil
	end
	-- Drain co-heal evidence: entries flagging drains damage AND heal
	-- each tick, so a heal line co-timed with the wound is the client's
	-- own proof a drain fired. Two provenance channels: a heal LINE in
	-- the buffer, or a self-sourced COMBAT_TEXT_UPDATE heal (healer name
	-- readable on Forever). Bonus-only in scoring — absence is never
	-- penalized because suppression behavior is unverified.
	local healLine = nil
	if zbt and zbt.PeekHealLine then
		healLine = zbt:PeekHealLine(t, 0.35, nil)
	end
	if healLine == nil and type(self._drainHealAt) == "number"
		and (t - self._drainHealAt) >= 0 and (t - self._drainHealAt) <= 0.5 then
		healLine = "ctheal"
	end
	-- Amount-matched leech: a self-heal for EXACTLY the wound
	-- amount in the same moment is proof-positive a drain fired — an
	-- unrelated heal can't fake the equality. nil = unproven (suppression
	-- means absence is never trusted), true = proven.
	local leech = nil
	local ph = self._playerHeals
	if type(ph) == "table" and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(amount) then
		for i = #ph, 1, -1 do
			local h = ph[i]
			if (t - h.at) > 0.5 then break end
			if h.amount == amount and math.abs(h.at - t) <= 0.06 then
				leech = true
				break
			end
		end
	end
	local pick, count = nil, 0
	-- Survivor pool + scores for the scored race (reused tables — no
	-- per-wound allocation).
	local pool = self._disambigPool
	if pool then wipe(pool) else pool = {} ; self._disambigPool = pool end
	local scores = self._disambigScores
	if scores then wipe(scores) else scores = {} ; self._disambigScores = scores end
	-- Entry-level dedup: two sids resolving to one dot entry (a cast sid
	-- plus the aura-reported rank sid, or rank variants) are ONE dot —
	-- pooling both manufactures a same-entry near-tie and kills the
	-- claim. Keep the better score.
	local entIdx = self._disambigEntIdx
	if entIdx then wipe(entIdx) else entIdx = {} ; self._disambigEntIdx = entIdx end
	local debuffPick, debuffCount = nil, 0
	local function addCand(sid, entry, sc, debOk)
		local prev = entry and entIdx[entry] or nil
		if prev then
			if sc < scores[prev] then
				pool[prev] = sid
				scores[prev] = sc
				if debOk then debuffPick = sid end
			end
			return
		end
		count = count + 1
		pool[count] = sid
		scores[count] = sc
		if entry then entIdx[entry] = count end
		if debOk then
			debuffPick = sid
			debuffCount = debuffCount + 1
		end
	end
	local rejNoEntry, rejSchool, rejCadence, rejChan, rejTarget, rejRescued, rejIsNot, scanned = 0, 0, 0, 0, 0, 0, 0, 0
	-- Target-debuff presence is a TIEBREAKER, not a gate: era aura APIs
	-- may not expose the data at all, and multi-target DoTing means a real
	-- tick from another mob arrives while this target lacks the debuff.
	-- School + cadence phase-lock is the proof; the aura check only
	-- disambiguates when several candidates survive.
	local prof = ZSBT.db and ZSBT.db.profile
	local learnedAm = type(prof) == "table" and prof.learnedTickAmounts or nil
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
			local iv = boundedDotPeriod(self, sid, entry)
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
		-- drains evidence, two strengths (the drains-vs-leech rule):
		-- amount-matched leech is proof a drain fired — drains entries get
		-- the bonus AND non-drains take the penalty (a wound carrying its
		-- own heal is never honestly a non-drain's tick). A bare co-timed
		-- heal line stays bonus-only: full-overheal suppression means its
		-- absence must never count against a non-drain.
		if leech == true then
			score = score + ((entry and entry.drains == true) and -0.40 or 1.0)
		elseif entry and entry.drains == true and healLine ~= nil then
			score = score - 0.40
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
				-- IS NOT vetoes: positive contradiction excludes the
				-- candidate outright — a spell is only what it is, it does
				-- not out-score what it is not. Leech proves a drain fired
				-- (a wound carrying its own exact-amount self-heal cannot
				-- be a non-drain's tick). Session-learned tick amounts
				-- prove a different dot (a 60-hit wound is never a 28-tick
				-- spell); persisted amounts only score, never veto — they
				-- predate the learner-trust gate. Bands stay wide: partial
				-- resists (25/50/75%) must not veto a real tick.
				local notCand = nil
				if leech == true and entry.drains ~= true then
					notCand = true
				else
					local refAm = self._dotTickAmounts and self._dotTickAmounts[sid]
					if type(refAm) == "number" and refAm > 0
						and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(amount) then
						local cmp = (isCrit == true) and (amount * 0.5) or amount
						if cmp > refAm * 1.6 or cmp < refAm * 0.4 then
							notCand = true
						end
					end
				end
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
				if notCand then
					rejIsNot = rejIsNot + 1
				elseif not tgtOk then
					rejTarget = rejTarget + 1
				elseif not dotCadencePredict(self, t, sid, appliedOv) then
					-- A typed "tick" line with no competing direct line is
					-- the client's own confirmation a periodic hit fired —
					-- rescue the candidate at a score penalty. Real ticks
					-- that wandered off-schedule recover their names.
					if tickLine ~= nil then
						addCand(sid, entry, candidateScore(sid, entry) + 0.4, false)
						rejRescued = (rejRescued or 0) + 1
					else
						rejCadence = rejCadence + 1
						-- Anchor dump: which timing anchor failed — appliedAt
						-- phase, predicted nextAt, or last confirmed tick.
						if auditNote then
							local rc = self._dotTickState and self._dotTickState[sid]
							auditNote("AUDCAD sid=%s applied=%s next=%s last=%s per=%s", 
								dbgSafe(sid),
								dbgSafe(appliedOv or (self._dotAppliedAt and self._dotAppliedAt[sid])),
								dbgSafe(rc and rc.nextAt), dbgSafe(rc and rc.lastAt),
								dbgSafe(rc and rc.period))
						end
					end
				else
					-- Name-keyed debuff sightings (era): the aura poll saw
					-- this entry's declared name on the current target —
					-- the sid-keyed read can't see name-primary entries.
					local namePass = false
					local nd = self._nameDebuffAt
					if type(nd) == "table" and type(entry.names) == "table" then
						for _, nm in ipairs(entry.names) do
							local at = nd[nm]
							if type(at) == "number" and (t - at) >= 0 and (t - at) <= 2.0 then
								namePass = true
								break
							end
						end
					end
					addCand(sid, entry, candidateScore(sid, entry),
						namePass or cachedHasTargetDebuffSpellId(sid))
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
			-- Same IS NOT vetoes as the dot path: a leech-proven wound is
			-- never a non-drain channel's tick, and a session-learned tick
			-- amount far off the wound excludes the channel too.
			local chNot = nil
			if leech == true and ch.drains ~= true then
				chNot = true
			else
				local refAm = self._dotTickAmounts and self._dotTickAmounts[ch.spellId]
				if type(refAm) == "number" and refAm > 0
					and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(amount) then
					local cmp = (isCrit == true) and (amount * 0.5) or amount
					if cmp > refAm * 1.6 or cmp < refAm * 0.4 then
						chNot = true
					end
				end
			end
			if chNot then
				rejIsNot = rejIsNot + 1
			elseif phaseOk or (tickLine ~= nil and chSchoolOk) then
				-- Pass a drains-bearing pseudo-entry so candidateScore's own
				-- leech/healLine terms judge the channel correctly (entry=nil
				-- was scored as non-drains, penalizing the proven drain).
				local chEnt = self._disambigChEntry
				if chEnt then chEnt.drains = ch.drains
				else chEnt = { drains = ch.drains } ; self._disambigChEntry = chEnt end
				addCand(ch.spellId, chEnt,
					candidateScore(ch.spellId, chEnt)
						+ (phaseOk and 0 or 0.4),
					cachedHasTargetDebuffSpellId(ch.spellId))
			else
				rejCadence = rejCadence + 1
			end
		end
	end
	-- Scored race: the best-fitting survivor wins only if it beats the
	-- runner-up by a margin — near-tied candidates stay honest generic
	-- (a direct-match margin), never a coin flip.
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
	-- Learner trust: a pick backed by
	-- evidence independent of learned state may teach — an aura/debuff
	-- tiebreak, a live channel's own ticks, or a sole survivor that was
	-- rescued by the client's typed tick line. Sole-survivor guesses and
	-- score-margin wins emit but never teach: their evidence derives from
	-- learned features, so a wrong pick would poison exactly what the next
	-- pick scores on — and the poison defends itself (the
	-- Corruption-learned-1.994 loop).
	self._dotPickTeach = ret ~= nil and (
		retWhy == "debuff"
		or (type(ch) == "table" and ret == ch.spellId)
		or (count == 1 and (rejRescued or 0) > 0)) or nil
	if auditNote then
		auditNote("AUDD reason=DOTDISAMBIG scan=%s surv=%s ret=%s why=%s debuffpass=%s pet=%s line=%s heal=%s wand=%s rescued=%s noentry=%s school=%s chan=%s tgt=%s cadence=%s isnot=%s teach=%s", dbgSafe(scanned), dbgSafe(count), dbgSafe(ret), dbgSafe(retWhy), dbgSafe(debuffCount),
				dbgSafe(pendingPet), dbgSafe(tickLine and "tick" or (directLine and "direct" or nil)),
				dbgSafe(leech and "leech" or healLine), dbgSafe(self._wandSid),
				dbgSafe(rejRescued), dbgSafe(rejNoEntry), dbgSafe(rejSchool), dbgSafe(rejChan),
				dbgSafe(rejTarget), dbgSafe(rejCadence), dbgSafe(rejIsNot), dbgSafe(self._dotPickTeach))
	end
	return ret
end

local function pickDotForWound(self, t, school, amount, isCrit)
	-- Learner-trust flag for the claim path: only a pick carrying evidence
	-- independent of learned state may teach. Cleared here so the module
	-- and recency-fallback paths leave it nil — a guess must never write
	-- the learned features it will be scored against next wound.
	self._dotPickTeach = nil
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

-- Your wand's element, read off the ranged slot's tooltip damage line
-- ("33 - 62 Fire Damage", or bare "N - N Damage" for physical) —
-- English-client pattern only. Re-read on equipment
-- change; when unreadable the claimed-shot vote learns it instead.
local WAND_SCHOOL_WORDS = {
	holy = 2, fire = 4, nature = 8, frost = 16, shadow = 32, arcane = 64,
}
local function readWandSchool()
	if not (C_TooltipInfo and C_TooltipInfo.GetInventoryItem) then return nil end
	local ok, data = pcall(C_TooltipInfo.GetInventoryItem, "player", 18)
	if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
	for i = 1, math.min(#data.lines, 30) do
		local lt = data.lines[i] and data.lines[i].leftText
		if type(lt) == "string" and (not ZSBT.IsSafeString or ZSBT.IsSafeString(lt)) then
			local lower = lt:lower()
			local _, _, word = lower:match("^(%d+) %- (%d+) (%a+) damage$")
			if word and WAND_SCHOOL_WORDS[word] then return WAND_SCHOOL_WORDS[word] end
			if lower:match("^%d+ %- %d+ damage$") then return 1 end
		end
	end
	return nil
end

-- Sustained wand family (mod.ranged/mod.rangedIds): era wand Shoot is
-- auto-shoot — the activation writes one cast record, then wounds keep
-- arriving for the whole session with nothing left to claim. A recent
-- claimed/recorded shot PLUS the client's own ranged line near the
-- wound is the sustained-family proof (melee-swing parity for wands).
-- NOT-gates: non-physical only; a known wand element rejects every
-- other school; and no claim without the ranged line the shot itself
-- produced (consumed included — a same-instant wound may have eaten it).
local function pickWandShot(self, t, school)
	if not (ZSBT.ClassDB and ZSBT.ClassDB.PreferRangedLine) then return nil end
	if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school)) then return nil end
	if school == 1 then return nil end
	local ws = self._wandSchool
	if type(ws) == "number" and ws ~= school then return nil end
	local sid, lastAt = self._wandSid, self._wandAt
	if type(sid) ~= "number" then return nil end
	-- A real ranged swing is the tighter anchor (shot→hit flight is
	-- 0.05-2.0s); fall back to the last claimed shot's family
	-- window when no swing reported this shot.
	local dt
	local swAt = self._swingAt and self._swingAt.ranged
	if type(swAt) == "number" then
		local dsw = t - swAt
		if dsw >= 0.05 and dsw <= 2.00 then dt = dsw end
	end
	if dt == nil then
		if type(lastAt) ~= "number" then return nil end
		dt = t - lastAt
		if dt < 0 or dt > 3.00 then return nil end
	end
	if not ZSBT.ClassDB.PreferRangedLine(sid) then return nil end
	local zbt = ZSBT.ZBattleText
	if not (zbt and zbt.PeekDamageLine) then return nil end
	if zbt:PeekDamageLine(t, 0.35, { ranged = true }, true) == nil then return nil end
	return sid
end
-- handleUnitCombat is at the 60-upvalue ceiling — reach it through
-- self instead of capturing the local.
Collector._pickWandShot = pickWandShot

-- Flight window for ranged-family record claims. Some feeds carry no
-- tick/ranged line kinds at all (retail hunter feed observed:
-- direct+melee claims only — zero tick, zero ranged), so the line-kind
-- proof the rival veto was built on never fires there. The surviving
-- discriminator is record-age: a shot's hit lands at a consistent
-- flight delay after its cast (~0.6-0.7s observed for auto-shot), while
-- a dot tick's offset from the shot's record is uniform noise.
-- _wandFlight learns the cast->hit delay from claimed shots (EMA);
-- unlearned defaults cover observed flight with margin.
local function wandFlightWindow(self)
	local f = self._wandFlight
	if type(f) == "number" and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(f) then
		return math.max(0.05, f - 0.35), f + 0.45
	end
	-- Unlearned: observed auto-shot flight spans 0.07s (point-blank) to
	-- ~0.94s (missile travel at range) — keep the lo bound low and let
	-- the hi bound carry the discrimination once the EMA converges.
	return 0.05, 1.20
end

-- Is a pending record claim for this sid inside the flight window?
-- PreferRangedLine records are shots — their hits always land at
-- flight time, so anything outside the window cannot be their wound
-- (a Black Arrow tick at +1.4s is not the Bleak shot's hit).
-- Other sids learn the same physics per-spell (_flightBySid EMA from
-- confirmed consumes; measured: Cobra 0.80s, Wailing Arrow 0.91s,
-- Black Arrow 0.43s): a wound outside its own record's flight span is
-- never that cast's hit — interleaved same-school casts otherwise let
-- wounds steal the freshest record (a Barbed hit at +0.24s wearing the
-- Cobra record). Gate only arms after 3 learns — a poisoned first
-- window would lock real hits out permanently. Unlearned: permissive.
local function familyRecordInFlight(self, spellId, dt)
	if ZSBT.ClassDB and ZSBT.ClassDB.PreferRangedLine
		and ZSBT.ClassDB.PreferRangedLine(spellId) then
		local lo, hi = wandFlightWindow(self)
		return dt >= lo and dt <= hi
	end
	local fb = self._flightBySid
	local rec = fb and fb[spellId]
	if type(rec) ~= "table" or (rec.n or 0) < 3 then
		-- Unlearned: still floor the claim on retail — a wound at
		-- cast-time is a coincident steal, not this spell's hit (a KC
		-- record eaten at dt=0 leaves its real +0.4s pet strike with
		-- an empty pool). Era instants genuinely hit same-frame, so
		-- the floor is era-exempt.
		if ZSBT.ClassDB and ZSBT.ClassDB.IsForever
			and ZSBT.ClassDB.IsForever() then return true end
		return dt >= 0.15
	end
	local f = rec.ema
	if type(f) ~= "number" or not (ZSBT.IsSafeNumber
		and ZSBT.IsSafeNumber(f)) then return true end
	return dt >= math.max(0.05, f - 0.35) and dt <= f + 0.45
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
-- canLearn: the claim must carry evidence independent of learned state
-- (debuff pass, live channel, typed tick line, cast-seeded pick). A guess
-- still emits — it just can't write period/amount/beat anchors, because a
-- wrong name's learning defends itself.
local function noteDotTickAmount(self, spellId, amount, isCrit, t, tgtName, canLearn)
	if canLearn ~= true then return end
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
			local okEq, eq = pcall(_secFieldEq, rec, "lastTgt", tgtName)
			sameTgt = okEq and eq == true
		end
		rec.lastTgt = tgtName
	end
	if type(rec.confirmedAt) == "number" and sameTgt then
		local gap = t - rec.confirmedAt
		local iv = boundedDotPeriod(self, spellId)
		-- A gap near 1x period refines the learned interval; a gap at 2x+
		-- is skipped ticks — keep the learned value, don't grow it. A
		-- poisoned rec.period can't blend its way home (0.6x weight would
		-- drag convergence through several more out-of-band values), so an
		-- out-of-band record resets to the observed gap outright.
		if gap >= iv * 0.7 and gap <= iv * 1.45 then
			local cur = rec.period
			if type(cur) == "number" and cur > 0
				and cur >= iv * 0.7 and cur <= iv * 1.45 then
				rec.period = cur * 0.6 + gap * 0.4
			else
				rec.period = gap
			end
		end
	end
	rec.confirmedAt = t
	rec.nextAt = t + boundedDotPeriod(self, spellId)
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
		pcall(AuraUtil.ForEachAura, "target", "HARMFUL", 255, function(auraData)
				scanned = scanned + 1
				local sid = SafeAuraSpellId(auraData)
				if firstSid == nil and sid ~= nil then
					firstSid = sid
					local nm = auraData and auraData.name
					if type(nm) == "string" then firstName = nm end
				end
				local okEq, eq = pcall(_secEq, sid, spellId)
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
			local okEq, eq = pcall(_secEq, sid, spellId)
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
		local zR = ZSBT.ZBattleText
		if zR and zR.FileLog and ZSBT._ucDropTrace == true then
			zR:FileLog("PEND_REF sid=%s why=helpful", tostring(spellId))
		end
		return
	end
	-- Enqueue even when classification is unknown so outgoing doesn't go silent
	-- on clients where IsHelpfulSpell/IsHarmfulSpell are unreliable.
	-- Icon eligibility: prefer concrete signals. Hostile target at cast time is
	-- a strong indicator of a damage cast.
	local eligibleIcon = (helpful == false) or (harmful == true) or (targetHostile == true)
	-- A spell whose own tooltip deals no damage can never own a hit — the
	-- "Curse of Tongues" fix; summon/curse casts stay out of the pool
	-- so their spellId can't stamp foreign damage.
	local castFacts = SpellFacts(spellId)
	if castFacts and castFacts.damages == false then
		local zR = ZSBT.ZBattleText
		if zR and zR.FileLog and ZSBT._ucDropTrace == true then
			zR:FileLog("PEND_REF sid=%s why=nodmg", tostring(spellId))
		end
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
	-- Damage-cast pin: only casts that passed the enqueue gates count.
	-- Non-damage casts (DRW, Gorefiend's) are refused above but still
	-- move _lastPlayerSpellId — pinning wound claims to THAT sid strands
	-- the real damage cast's record (its wounds can never == the pin).
	self._lastPlayerDamageCastId = spellId
	self._lastPlayerDamageCastAt = tNow
	-- Signature window: separate from the pending record — a cast's own
	-- direct hit consumes the record while its linked procs still fly.
	sigSeed(self, spellId, tNow)
end

-- Veto-confirmed (line-paired) outgoing hits teach the spell's damage
-- school. Called from emit()'s fast path and ZBattleText's deferred
-- delivery — both mean a MINE/MY_PET palette line confirmed ownership.
-- Vote-guarded: a single confirmed hit is still a guess — a school
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
	-- Provenance gate: only a sid bound to a consumed cast
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
		auditNote("AUDD reason=SIG_TALENT spellId=%s school=%s", 
			dbgSafe(refusedTalentSid), dbgSafe(hitSchool))
	elseif best == nil and refusedSid ~= nil then
		auditNote("AUDD reason=SIG_NODAMAGE spellId=%s school=%s", 
			dbgSafe(refusedSid), dbgSafe(hitSchool))
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
		auditNote("AUDSIG sid=%s via=%s score=%d dt=%.2f school=%s bind=%s", 
			tostring(best), tostring(bestVia), bestScore or 0,
			bestDt or 0, tostring(hitSchool), tostring(bn))
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

-- Channel first-tick floor (shared by pending-queue and recency claims):
-- a channeled spell has no direct hit — every wound it produces is a tick
-- landing ~one interval after cast start. A wound arriving earlier than
-- that wearing the channel's name is a same-school DoT tick stolen (a
-- Drain Life pending record claimed Corruption's on-schedule tick at
-- dt=0.70 while the real first tick landed at 1.07). Skipping keeps the
-- record alive for the true tick.
local function channelTickFloorOk(spellId, dt)
	if not (ZSBT.ClassDB and ZSBT.ClassDB.ChannelMatch) then return true end
	local ch = ZSBT.ClassDB.ChannelMatch(spellId)
	if ch and type(ch.interval) == "number" and ch.interval > 0 then
		return dt >= ch.interval * 0.8
	end
	return true
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
					-- Flight gate: a ranged-family record only claims
					-- wounds at shot-flight age — a same-school tick or
					-- stray wound outside the window cannot steal it
					-- (post-veto fall-through was handing the Bleak
					-- record to Black Arrow ticks it had just vetoed).
					-- Its cap is the flight hi, not the generic window:
					-- shot flight (~0.6-1.2s) outruns castWindow 0.85.
					local cap = window
					if ZSBT.ClassDB and ZSBT.ClassDB.PreferRangedLine
						and ZSBT.ClassDB.PreferRangedLine(c.spellId) then
						local _, fhi = wandFlightWindow(self)
						cap = fhi
					else
						-- Learned flight may outrun the generic window:
						-- real Cobra hits land ~0.8s; the cap grows to
						-- the learned hi so its own hits still claim.
						local frec = self._flightBySid
							and self._flightBySid[c.spellId]
						if type(frec) == "table" and (frec.n or 0) >= 3
							and type(frec.ema) == "number" then
							cap = math.max(window, frec.ema + 0.45)
						end
						-- A next-swing record must outlive the press
						-- frame: its real hit lands on the swing, up
						-- to a weapon period out (tape: +2.84s). The
						-- pool expiry (3.25s) still bounds it — 3.2
						-- keeps claims inside that life.
						if ZSBT.ClassDB and ZSBT.ClassDB.NextSwing
							and ZSBT.ClassDB.NextSwing(c.spellId) then
							cap = math.max(cap, 3.2)
						end
					end
					if dt >= 0 and dt <= cap
						and familyRecordInFlight(self, c.spellId, dt)
						and channelTickFloorOk(c.spellId, dt) then
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
			castClaimAdd(self, best.spellId, best.at)
			-- Flight learning: claimed hits teach their sid's cast->hit
			-- delay (per-sid EMA + count) so the flight gate tightens
			-- around the real span instead of staying permissive.
			local fl = tNow - best.at
			if fl >= 0.05 and fl <= 2.0 then
				local fb = self._flightBySid
				if not fb then fb = {} ; self._flightBySid = fb end
				local rec = fb[best.spellId]
				if type(rec) ~= "table" then
					rec = { ema = fl, n = 0 }
					fb[best.spellId] = rec
				end
				if type(rec.ema) == "number" then
					rec.ema = rec.ema * 0.7 + fl * 0.3
				else
					rec.ema = fl
				end
				rec.n = (rec.n or 0) + 1
				if ZSBT.ClassDB and ZSBT.ClassDB.PreferRangedLine
					and ZSBT.ClassDB.PreferRangedLine(best.spellId) then
					local cur = self._wandFlight
					self._wandFlight = (type(cur) == "number")
						and (cur * 0.7 + fl * 0.3) or fl
				end
			end
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
miwClaim = function(self, lastId, lastAt, t, school)
	if not channelTickFloorOk(lastId, t - lastAt) then return nil end
	local n = castClaimGet(self, lastId, lastAt)
	local budget = 1
	if ZSBT.ClassDB and ZSBT.ClassDB.CastBudget then
		local b = ZSBT.ClassDB.CastBudget(lastId)
		if type(b) == "number" and b > 0 then budget = b end
	end
	if n >= budget then return nil end
	consumeBestPendingCast(self, t, lastId, nil, true, school)
	castClaimAdd(self, lastId, lastAt)
	-- Claim ordinal for the noline-theft gate: slot 1 of a recency record
	-- is most plausibly our own hit wave; foreign wounds drain late slots.
	-- emit() stamps it on the payload, then clears.
	self._miwOrd = n + 1
	return true
end

-- Capture successful casts for downstream correlation.
-- Player casts: used for outgoing spell icons.
-- Target/enemy casts: used for incoming spell icons.
-- PLAYER_SWING (swingDuration, swingType): each player weapon swing is a
-- public report — melee and ranged. Pet/follower/teammate melee never
-- produces one, so auto-attack claims can require a matching swing.
-- swingType is numeric Enum.PlayerSwingType on Forever; duration is the
-- weapon's swing speed — a >0.3s change drops that hand's learned lag
-- (weapon swap / big haste shift).
function Collector:handlePlayerSwing(swingDuration, swingType)
	local t = now()
	self._swingAt = self._swingAt or {}
	local hand = swingHandName(swingType) or "main"
	self._swingAt[hand] = t
	if hand ~= "ranged" and type(swingDuration) == "number" then
		self._swingSpeed = self._swingSpeed or {}
		local speed = self._swingSpeed[hand]
		if type(speed) == "number" and math.abs(swingDuration - speed) > 0.3 then
			if self._swingLags then self._swingLags[hand] = nil end
		end
		self._swingSpeed[hand] = swingDuration
	end
	auditNote("AUDSWING hand=%s", dbgSafe(hand))
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

-- UNIT_SPELLCAST_SENT (unit, target, castGUID, spellId): the intended
-- recipient at press time, player-only. SUCCEEDED joins on castGUID —
-- the real application mob for per-mob dot anchors instead of
-- "whoever is targeted now" (the cast-target model).
function Collector:handleSpellcastSent(unit, target, castGUID, spellId)
	if unit ~= "player" then return end
	if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(spellId)) then return end
	local list = self._sentCasts
	if not list then list = {} ; self._sentCasts = list end
	list[#list + 1] = { guid = castGUID, target = target,
		spellId = spellId, at = now() }
	while #list > 8 do table.remove(list, 1) end
	local tgtSafe = ZSBT.IsSafeString and ZSBT.IsSafeString(target)
	auditNote("AUDSENT sid=%s tgt=%s safe=%s", dbgSafe(spellId),
		(tgtSafe and tostring(target):sub(1, 24)) or tostring(type(target)),
		tostring(tgtSafe == true))
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
			pcall(trg.OnSpellcastSucceeded, trg, unit, spellId)
		end
		-- Track friendly non-player casts (pet, imps, guardians) for pet-hit
		-- attribution. Also records non-pet friendly units so we can learn
		-- which unit token temporary pets cast under. Player spellbook sids
		-- are rejected: under a non-player token they can only poison the
		-- pet-cast pool (a pet scroll hit wearing a player spell's name).
		local zbtc = ZSBT.ZBattleText
		if isPlayerSpellId(spellId) then
			if zbtc and zbtc.FileLog then
				zbtc:FileLog("PET_CAST_REJECT unit=%s sid=%s", tostring(unit), tostring(spellId))
			end
			return
		end
		self._petCasts = self._petCasts or {}
		local tCast = now()
		self._petCasts[#self._petCasts + 1] = { unit = unit, spellId = spellId, at = tCast }
		if #self._petCasts > 24 then table.remove(self._petCasts, 1) end
		if zbtc and zbtc.FileLog then
			zbtc:FileLog("PET_CAST unit=%s sid=%s", tostring(unit), tostring(spellId))
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
				local okPC, peq = pcall(_secTrue, pres)
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
						zbtc2:FileLog("FRIEND_CAST_REJECT unit=%s sid=%s", tostring(unit), tostring(spellId))
					end
				else
					self._petCasts = self._petCasts or {}
					local tCast2 = now()
					self._petCasts[#self._petCasts + 1] = { unit = unit, spellId = spellId, at = tCast2 }
					if #self._petCasts > 24 then table.remove(self._petCasts, 1) end
					if zbtc2 and zbtc2.FileLog then
						zbtc2:FileLog("FRIEND_CAST unit=%s sid=%s", tostring(unit), tostring(spellId))
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
				zc:FileLog("UC_CAST unit=%s sid=%s", tostring(unit), tostring(spellId))
			end
		end
	end

	if unit == "player" then
		self._castToken = (self._castToken or 0) + 1
		-- Excluded casts (hidden applicators, zero-damage abilities) never
		-- name wounds, so they must not become the last-cast anchor either
		-- — every recency/pin path reads this stamp and a ~1s applicator
		-- would hold it permanently (retail DH: Frailty's hidden cast
		-- kept winning miw/offt/whirlwind claims over the real spells).
		local exclCast = ZSBT.ClassDB and ZSBT.ClassDB.ExcludedSpellId
			and ZSBT.ClassDB.ExcludedSpellId(spellId) == true
		if not exclCast then
		self._lastPlayerSpellId = spellId
		self._lastPlayerSpellName = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or nil
		self._lastPlayerSpellAt = now()
		-- Cast→target binding (UNIT_SPELLCAST_SENT): the press-time
		-- recipient pairs via castGUID — the real application mob for
		-- per-mob dot anchors, even if the player re-targeted mid-cast.
		-- The SENT target arg may be a unit token or a bare name.
		self._lastCastTargetName, self._lastCastTargetGuid = nil, nil
		local sent = self._sentCasts
		if type(sent) == "table" then
			for i = #sent, 1, -1 do
				local e = sent[i]
				if e.spellId == spellId and (e.guid == nil or e.guid == guid) then
					local tgt = e.target
					if ZSBT.IsSafeString and ZSBT.IsSafeString(tgt) then
						local okE, exists = UnitExists and pcall(UnitExists, tgt)
						if okE and exists == true then
							local nm = safeUnitName(tgt)
							if nm then self._lastCastTargetName = nm end
							if UnitGUID then
								local okG, g = pcall(UnitGUID, tgt)
								if okG and ZSBT.IsSafeString and ZSBT.IsSafeString(g) then
									self._lastCastTargetGuid = g
								end
							end
						else
							self._lastCastTargetName = tgt
						end
					end
					table.remove(sent, i)
					break
				end
			end
		end
		self._lastCastTargetAt = self._lastPlayerSpellAt
		end
		-- Wand family anchor at activation: a ranged-declared cast seeds
		-- the sustained family even if the pending-cast queue drops it.
		if ZSBT.ClassDB and ZSBT.ClassDB.PreferRangedLine
			and ZSBT.ClassDB.PreferRangedLine(spellId) then
			self._wandSid = spellId
			self._wandAt = self._lastPlayerSpellAt
		end
		-- Class-module cast hooks: DK ghoul summons, Warlock channels
		-- (Drain Life/Soul), Warrior Rend tick seeding.
		if ZSBT.ClassDB and ZSBT.ClassDB.OnPlayerCast then
			local okC, hookErrC = pcall(ZSBT.ClassDB.OnPlayerCast, self, spellId, self._lastPlayerSpellName, self._lastPlayerSpellAt)
			if okC ~= true and hookErrC ~= nil then
				local tE = now()
				if tE - (self._hookErrAt or -9) >= 5 then
					self._hookErrAt = tE
					local zbt = ZSBT.ZBattleText
					if zbt and zbt.FileLog then
						zbt:FileLog("HOOKERR fn=onCast err=%s", dbgSafe(hookErrC))
					end
				end
			end
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
				auditNote("AUDHSEED sid=%s iv=%s dur=%s", 
					tostring(spellId), tostring(iv), tostring(dur))
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
	-- classTag may be a secret string — guard before comparing.
	return ok and type(classTag) == "string"
		and (not ZSBT.IsSafeString or ZSBT.IsSafeString(classTag))
		and classTag == tag
end

local function isWhirlwindSpellId(spellId)
	return spellId == 1680 or spellId == 190411 or spellId == 199658
end

-- "NOT cleave" eligibility for off-target wounds: a single-target cast
-- can never own a nameplate wound — its one hit arrives on the target
-- token. castBudget==1 casts are excluded so e.g. Death Coil can't wear
-- a cleave wound. (The "match me to ONLY this" rule for OFFT claims.)
-- Lives on Collector: handleUnitCombat is at the 60-upvalue Lua limit —
-- a file-local here would overflow it; Collector is already captured.
function Collector.CastCleavesOffTarget(spellId)
	local b = 1
	if ZSBT.ClassDB and ZSBT.ClassDB.CastBudget then
		local bv = ZSBT.ClassDB.CastBudget(spellId)
		if type(bv) == "number" and bv > 0 then b = bv end
	end
	return b > 1
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
		pcall(st.timer.Cancel, st.timer)
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
	st.targetGUID = st.targetGUID or safeTargetGUID("target")
	st.token = st.token or self._castToken
	st.spellId = st.spellId or spellId
	if st.timer and st.timer.Cancel then
		pcall(st.timer.Cancel, st.timer)
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
		local okFind, findRes = pcall(_secFindYour, msg)
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
		local okMatch, amountText = pcall(string.match, msg, "(%d[%d,]*)")
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
			self._lastOutgoingCombatTargetGUID = safeTargetGUID("target")
			if self._lastOutgoingCombatTargetGUID then
				local m = self._ownAtByGuid or {}; self._ownAtByGuid = m
				m[self._lastOutgoingCombatTargetGUID] = self._lastOutgoingCombatAt
		
				local n = 0
				for _ in pairs(m) do n = n + 1; if n > 48 then break end end
				if n > 48 then
					local cut = self._lastOutgoingCombatAt - 6
					for k, v in pairs(m) do if v < cut then m[k] = nil end end
				end
			end

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
					zCt:FileLog("CTDROPPED t=%.3f why=no_victim_evidence", tNow)
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
		-- rawArg1 is the SOURCE NAME for HEAL/PERIODIC_HEAL kinds
		-- (GetCurrentEventInfo contract) — on Forever a self-sourced heal
		-- near a target wound is provenanced drain-tick evidence
		-- (Siphon Life, drain channels), independent of the heal LINE
		-- buffer.
		local srcSafe = ZSBT.IsSafeString and ZSBT.IsSafeString(rawArg1)
		local src2Safe = ZSBT.IsSafeString and ZSBT.IsSafeString(rawArg2)
		local pname = safeUnitName("player")
		if pname and ((srcSafe and rawArg1 == pname) or (src2Safe and rawArg2 == pname)) then
			self._drainHealAt = now()
		end
		local tP = now()
		if tP - (self._ctInfoProbeAt or -9) >= 8 then
			self._ctInfoProbeAt = tP
			auditNote("AUDCTI type=%s r1=%s(%s) r2=%s(%s) r3=%s", 
				dbgSafe(arg1),
				(srcSafe and tostring(rawArg1):sub(1, 20)) or "?", tostring(type(rawArg1)),
				(src2Safe and tostring(rawArg2):sub(1, 20)) or "?", tostring(type(rawArg2)),
				tostring(rawArg3))
		end
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

		-- For heals: use player.s own spell (self-heals) — but only a cast that
		-- can actually heal; a heal may never wear a damage-only cast's name.
		local healSpellId = nil
		if self._lastPlayerSpellAt and (now() - self._lastPlayerSpellAt) < 0.5 then
			local f = SpellFacts(self._lastPlayerSpellId)
			if (not f) or f.heals then healSpellId = self._lastPlayerSpellId end
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
			zC:FileLog("CT_HEAL sid=%s per=%s", tostring(healSpellId), tostring(isPeriodic == true))
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
			zM:FileLog("MISS_EMIT type=%s", tostring(arg1))
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
Collector._lastOutgoingCombatTargetGUID = Collector._lastOutgoingCombatTargetGUID or nil
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
		local ok2, eq = pcall(_secTrue, res)
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
	z:FileLog("UC_UNIT unit=%s hostile=%s istarget=%s name=%s", 
		tostring(unit), hostile, istarget, tostring(uname))
end


-- handleUnitCombat sits at the 60-upvalue ceiling: every file-local it
-- captures costs one slot. Two escape routes keep headroom — self-fields
-- (Collector._x) for helpers already invoked on self (the method arg is
-- not an upvalue), and H: one captured table holding the plain helpers
-- and constants this body reaches for.
local H = {
	emit = emit, auditNote = auditNote, dbgDrop = dbgDrop, dbgSafe = dbgSafe,
	ECPrint = ECPrint, OutDbgLevel = OutDbgLevel, safeUnitName = safeUnitName,
	now = now, launderAmount = launderAmount, wipeStalePipeEntries = wipeStalePipeEntries,
	zbtVetoActive = zbtVetoActive,
	isStrictOutgoingCombatLogOnly = isStrictOutgoingCombatLogOnly,
	isPvPStrictActive = isPvPStrictActive, getPvPStrictFlag = getPvPStrictFlag,
	isQuietOutgoingWhenIdle = isQuietOutgoingWhenIdle,
	isQuietOutgoingAutoAttacks = isQuietOutgoingAutoAttacks,
	isPlayerAutoAttackActive = isPlayerAutoAttackActive,
	isPlayerMeleeEngaged = isPlayerMeleeEngaged,
	offTargetDotsEnabled = offTargetDotsEnabled,
	arePetsEnabled = arePetsEnabled, getPetFamilyLower = getPetFamilyLower,
	getUnitNpcId = getUnitNpcId,
	isLikelyPetSchoolHit = isLikelyPetSchoolHit,
	isLikelyPetPhysicalHit = isLikelyPetPhysicalHit,
	isWhirlwindSpellId = isWhirlwindSpellId, wwAggEnabled = wwAggEnabled,
	dotEntryForSpellId = dotEntryForSpellId,
	dotEntrySchoolEq = dotEntrySchoolEq,
	cachedHasTargetDebuffSpellId = cachedHasTargetDebuffSpellId,
	BIG_HIT_THRESHOLD = BIG_HIT_THRESHOLD,
	PERIODIC_OUTGOING_WINDOW_SEC = PERIODIC_OUTGOING_WINDOW_SEC,
	DEDUP_WINDOW = DEDUP_WINDOW,
	AUTO_OUTGOING_DEDUP_WINDOW = AUTO_OUTGOING_DEDUP_WINDOW,
	PET_OUTGOING_DEDUP_WINDOW = PET_OUTGOING_DEDUP_WINDOW,
}
Collector._pickDotForWound = pickDotForWound
Collector._pickProcRider = pickProcRider
Collector._isLiveChannelPick = isLiveChannelPick
Collector._consumeBestPendingCast = consumeBestPendingCast
Collector._consumePetCast = consumePetCast
Collector._miwClaim = miwClaim
Collector._matchOutgoingHotTick = matchOutgoingHotTick
Collector._queuePendingHotHeal = queuePendingHotHeal
Collector._resolveOffTargetDot = resolveOffTargetDot
Collector._flushBestOutgoing = flushBestOutgoing
Collector._castSchoolOk = castSchoolOk
Collector._swingExplainsHit = swingExplainsHit
Collector._autoContested = autoContested
Collector._dotCadenceOk = dotCadenceOk
Collector._isDuplicateDotEmit = isDuplicateDotEmit
Collector._noteDotTickAmount = noteDotTickAmount
Collector._isLikelyPetSchoolHitGivenRecentPlayerSpell = isLikelyPetSchoolHitGivenRecentPlayerSpell
Collector._isHealAliasDup = isHealAliasDup
Collector._noteHealClaim = noteHealClaim
Collector._getMostRecentPeriodicSpellId = getMostRecentPeriodicSpellId
Collector._wwAggPush = wwAggPush
Collector._anySwingRecent = anySwingRecent
Collector._swingPredictedNear = swingPredictedNear

-- Huge-hit corroboration helpers: file-locals so handleUnitCombat does not
-- allocate three closures on every wound call.
local function getAdaptiveBigHitThreshold(self, tNow)
	local base = H.BIG_HIT_THRESHOLD
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

local function isCorroboratedHugeHit(self, restrict, tNow, amt, spellId)
	if not (restrict == true) then return true end
	local thresh = getAdaptiveBigHitThreshold(self, tNow)
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

local function isCorroboratedHugePetHit(self, restrict, tNow, amt)
	if not (restrict == true) then return true end
	local thresh = getAdaptiveBigHitThreshold(self, tNow)
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

function Collector:handleUnitCombat(unit, action, descriptor, amount, school)
	-- Token as delivered, before the nameplate/softenemy -> "target" remap
	-- below: the wound dedup uses it to tell a real cross-token re-report
	-- from two distinct hits on the same target.
	local rawUnit = unit
	-- ucdrop raw trace: log every UNIT_COMBAT event shape so we can see
	-- what Retail actually delivers for target/minion damage (secret
	-- actions, nil amounts, non-WOUND verbs). Throttled per unit.
	do
		local z = ZSBT.ZBattleText
		if z and z.FileLog and ZSBT._ucDropTrace == true then
			local key = "ucraw_" .. tostring(unit)
			local tt = H.now()
			if tt - (Collector[key] or -9) >= 0.4 then
				Collector[key] = tt
				local aType = type(action)
				local aPrev = (aType == "string" and ZSBT.IsSafeString and ZSBT.IsSafeString(action)) and action or aType
				local aVal = (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(amount))
					and tostring(amount) or "sec"
				local dVal = (ZSBT.IsSafeString and ZSBT.IsSafeString(descriptor))
					and descriptor or "sec"
				z:FileLog("UC_RAW unit=%s action=%s amtNil=%s amtT=%s amtV=%s descT=%s descV=%s school=%s", 
					tostring(unit), tostring(aPrev), tostring(amount == nil),
					tostring(type(amount)), aVal, tostring(type(descriptor)), dVal, tostring(school))
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
				local tH = H.now()
				local hsid, hPeriodic, why = self:_matchOutgoingHotTick(unit, tH)
				if hsid == nil then
					if why == "noline" then
						local isCritQ = false
						if type(descriptor) == "string" and descriptor:upper():find("CRIT", 1, true) then
							isCritQ = true
						end
						self:_queuePendingHotHeal(unit, tH, amount, school, isCritQ)
					else
						H.auditNote("AUDHX unit=%s why=%s", H.dbgSafe(unit), tostring(why))
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
					H.auditNote("AUDH unit=%s sid=%s", H.dbgSafe(unit), tostring(hsid))
					H.emit("OUTGOING_HEAL_COMBAT", {
						timestamp = tH,
						rawPipeId = pipeId,
						amountText = (ZSBT.IsSafeNumber(amount) and tostring(amount)) or nil,
						spellId = hsid ~= 0 and hsid or nil,
						targetName = H.safeUnitName(unit),
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
					local okC, eq = pcall(_secTrue, res)
					if okC and eq == true then isTarget = true end
				end
			end
			if isTarget then
				local dl = H.OutDbgLevel()
				if dl >= 4 then
					local tNow = H.now()
					if (tNow - (Collector._dbgLastNameplateRemapAt or 0)) > 0.25 then
						Collector._dbgLastNameplateRemapAt = tNow
						H.ECPrint(("NAMEPLATE_REMAP unit=%s action=%s amt=%s school=%s -> target")
							:format(H.dbgSafe(unit), H.dbgSafe(action), H.dbgSafe(amount), H.dbgSafe(school)))
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
				local tgtStarved = (H.now() - (self._lastTargetWoundAt or 0)) > 1.5
				if H.zbtVetoActive() and amount ~= nil then
					local aStr = (ZSBT.IsSafeString and ZSBT.IsSafeString(action)) and action or nil
					if aStr == "WOUND" then
						local hostile = false
						if UnitCanAttack then
							local okH, h = pcall(UnitCanAttack, "player", unit)
							if okH then
								local okC, eq = pcall(_secTrue, h)
								if okC and eq == true then hostile = true end
							end
						end
						if hostile then
							local offSid = nil
							local offSidIsDot = false
							local offTgtName = H.safeUnitName(unit)
							if H.offTargetDotsEnabled() then
								offSid = self:_resolveOffTargetDot(unit, H.now(), school)
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
								local tOff = H.now()
								local cand, candAt = nil, nil
								local bestDt = nil
								for _, c in ipairs(self._pendingCasts or {}) do
									if c and c.at and c.spellId then
										local dt = tOff - c.at
										if dt >= 0 and dt <= 0.5
											and Collector.CastCleavesOffTarget(c.spellId)
											and self:_castSchoolOk(c.spellId, school)
											and (not bestDt or dt < bestDt) then
											bestDt = dt
											cand, candAt = c.spellId, c.at
										end
									end
								end
								-- Proven-cast fan-out: the pending record is
								-- single-consume — the target wound eats it, so
								-- cleave hits #2..N find pool=EMPTY. But the
								-- claim survives in _castClaims (sid@castAt)
								-- where n>=1 means the cast already PROVED it
								-- produces hits; its remaining budget can name
								-- this follow-up. Same gate as target-path
								-- recency, via the same shared key.
								if cand == nil then
									local claims = self._castClaims or {}
									for sid, list in pairs(claims) do
										if type(sid) == "number" then
											for i = 1, #list do
												local rec = list[i]
												local at, n = rec.at, rec.n or 0
												if type(at) == "number" and n >= 1 then
													local dt = tOff - at
													if dt >= 0 and dt <= 0.75
														and Collector.CastCleavesOffTarget(sid)
														and self:_castSchoolOk(sid, school)
														and (not bestDt or dt < bestDt) then
														bestDt = dt
														cand, candAt = sid, at
													end
												end
											end
										end
									end
								end
								if cand == nil then
									local lastId = self._lastPlayerDamageCastId or self._lastPlayerSpellId
									local lastAt = self._lastPlayerDamageCastAt or self._lastPlayerSpellAt
									if type(lastId) == "number" and type(lastAt) == "number"
										and (tOff - lastAt) >= 0 and (tOff - lastAt) <= 0.5
										and Collector.CastCleavesOffTarget(lastId)
										and self:_castSchoolOk(lastId, school) then
										cand, candAt = lastId, lastAt
									end
								end
								if cand ~= nil then
									local zbt = ZSBT.ZBattleText
									if zbt and zbt.PeekDamageLine
										and zbt:PeekDamageLine(tOff, 0.35, { direct = true }) then
										local n = castClaimGet(self, cand, candAt)
										local budget = 1
										if ZSBT.ClassDB and ZSBT.ClassDB.CastBudget then
											local b = ZSBT.ClassDB.CastBudget(cand)
											if type(b) == "number" and b > 0 then budget = b end
										end
										if n < budget then
											castClaimAdd(self, cand, candAt)
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
										H.dbgDrop("BYPASS_OFFT_INST", self._castToken, school)
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
											and (H.now() - lastCast) >= 0
											and (H.now() - lastCast) <= 2.0 then
											ownActive = true
										end
									end
									if not ownActive and UnitAffectingCombat then
										local okC, res = pcall(UnitAffectingCombat, "player")
										if okC and res == true
											and (H.now() - (self._lastTargetWoundAt or 0)) <= 2.0 then
											ownActive = true
										end
									end
									if not ownActive then
										H.dbgDrop("OFFT_NOCOMBAT", self._castToken, school)
										return
									end
									-- Unattributed off-target hits are contested too:
									-- a burst of foreign cleave/AoE on shared mobs is
									-- exactly the traffic that steals filtered lines.
									if self:_autoContested(H.now(), false) then
										H.dbgDrop("CONTESTED_OFFT", self._castToken, school)
										return
									end
								end
								local isCritOff = false
								if type(descriptor) == "string" then
									isCritOff = descriptor:upper():find("CRIT", 1, true) ~= nil
								end
								if offSidIsDot then
									self._recentPeriodicSpellAt[offSid] = H.now()
									-- Cast-seeded off-target pick: the sid came
									-- from a pending cast record — proven.
									self:_noteDotTickAmount(offSid, amount, isCritOff, H.now(), offTgtName, true)
								end
								local pipeId = self._rawPipeCount + 1
								self._rawPipeCount = pipeId
								self._rawPipe[pipeId] = amount
								local zbtOff = ZSBT.ZBattleText
								if zbtOff and zbtOff.FileLog then
									zbtOff:FileLog("OFFT unit=%s sid=%s school=%s", 
										tostring(unit), tostring(offSid), tostring(school))
								end
								H.emit("OUTGOING_DAMAGE_COMBAT", {
									timestamp = H.now(),
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
	-- Per-GUID: every wound on any token also stamps _woundAtByGuid[guid] so the
	-- UT announcer's foreign-blow veto can see hits on off-target victims
	-- (a mob you damaged then untargeted still earns nameplate-token wounds).
	do
		local aW = (ZSBT.IsSafeString and ZSBT.IsSafeString(action)) and action or nil
		if aW == "WOUND" then
			if unit == "target" then
				self._lastTargetWoundAt = H.now()
			end
			local gW = safeTargetGUID(unit)
			if gW then
				local m = self._woundAtByGuid
				if type(m) ~= "table" then m = {}; self._woundAtByGuid = m end
				m[gW] = H.now()
				local n = 0
				for _ in pairs(m) do n = n + 1; if n > 48 then break end end
				if n > 48 then
					local cut = H.now() - 6
					for k, v in pairs(m) do if v < cut then m[k] = nil end end
				end
			end
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
			zbtZ:FileLog("ZERO_DROP unit=%s school=%s", tostring(unit), tostring(school))
		end
		return
	end
	H.wipeStalePipeEntries()

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
		if H.arePetsEnabled() ~= true then
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
			H.emit("PET_HEAL_LOG", {
				timestamp = H.now(),
				amount = numAmount,
				amountText = amtText,
				spellId = nil,
				spellName = nil,
				isCrit = isCrit,
				isPeriodic = true,
				overheal = nil,
				targetName = H.safeUnitName("pet"),
			})
		elseif actionStr == "WOUND" or actionStr == nil then
			local pipeId = self._rawPipeCount + 1
			self._rawPipeCount = pipeId
			self._rawPipe[pipeId] = amount
			H.emit("PET_INCOMING_DAMAGE_COMBAT", {
				timestamp = H.now(),
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
		local quietMode = H.isQuietOutgoingWhenIdle()
		-- Legacy explicit-strict keys (pre-migration compat): an enabled
		-- strict toggle still forces restrict even while the veto is live.
		local legacyStrict = H.isPvPStrictActive()
			or H.isStrictOutgoingCombatLogOnly()
			or quietMode == true
		local restrict = autoRestrict or legacyStrict
		local instanceAware = restrict
			or (ZSBT.Core and ZSBT.Core.IsInstanceAwareOutgoingEnabled
				and ZSBT.Core:IsInstanceAwareOutgoingEnabled()) or false
		H.auditNote("AUDT tier=%s restrict=%s", 
			tostring(tier), tostring(restrict == true))
		-- If combat text / chat already produced an outgoing number for the current cast
		-- token, suppress UNIT_COMBAT(target) for that token to avoid double numbers.
		if self._castToken and self._lastCombatTextOutgoingToken == self._castToken then
			-- Exception: pet outgoing fallback can also use UNIT_COMBAT(target) on some
			-- clients. Do not suppress the entire UNIT_COMBAT(target) handler when pets
			-- are enabled and the pet is currently fighting and the player isn't actively
			-- casting (i.e., this cannot be a duplicate of the player's cast).
			local allowPetFallback = false
			if H.arePetsEnabled() == true and UnitAffectingCombat and UnitExists then
				local okEx, hasPet = pcall(UnitExists, "pet")
				if okEx and hasPet == true then
					local okPet, inPetCombat = pcall(UnitAffectingCombat, "pet")
					if okPet and inPetCombat == true then
						local tNow = H.now()
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
						local tNow = H.now()
						local lastAt = self._lastPlayerSpellAt
						local recentlyCast = (type(lastAt) == "number" and (tNow - lastAt) >= 0 and (tNow - lastAt) <= 0.90)
						if not recentlyCast then
							-- Exception: periodic damage can tick well after the cast and we'd still like
							-- to show *player* DoTs without opening the door to follower/party damage.
							-- Allow the pipeline only when we can correlate to a very recent periodic spell.
							local dotSpellId = self._getMostRecentPeriodicSpellId and self:_getMostRecentPeriodicSpellId(tNow) or nil
							local okDot = false
							if dotSpellId and self._recentPeriodicSpellAt and type(self._recentPeriodicSpellAt[dotSpellId]) == "number" then
								local age = tNow - (self._recentPeriodicSpellAt[dotSpellId] or 0)
								if age >= 0 and age <= (H.PERIODIC_OUTGOING_WINDOW_SEC or 8.0) then
									okDot = true
								end
							end
							if not okDot then
								-- ZBattleText veto-aware bypass: when the trusted palette feed is
								-- live, OfferOutgoing still requires a nearby combat-log line,
								-- so unattributed hits can flow as candidates instead of dying
								-- here during the idle window after the opener's cast ages out.
								if not H.zbtVetoActive() then
									H.dbgDrop("INST_GATE", self._castToken, school)
									return
								end
							end
						end
					end
				end
			end
		end
		local dl = H.OutDbgLevel()
		if dl >= 4 then
			local tName = H.safeUnitName("target")
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
			local tDbg = H.now()
			if dl >= 4 and dl < 5 and (tDbg - (Collector._dbgLastUnitCombatTargetAt or 0)) > 0.25 then
				Collector._dbgLastUnitCombatTargetAt = tDbg
				H.ECPrint(("UNIT_COMBAT_TARGET name=%s guid=%s hostile=%s action=%s desc=%s amt=%s school=%s")
					:format(H.dbgSafe(tName), H.dbgSafe(tGuid), H.dbgSafe(hostile), H.dbgSafe(action), H.dbgSafe(descriptor), H.dbgSafe(amount), H.dbgSafe(school)))
			end
		end

		local t = H.now()
		local actionStr = ZSBT.IsSafeString(action) and action or nil
		local isPhysicalEarly = ZSBT.IsSafeNumber(school) and school == 1
		if actionStr == "WOUND" then
			-- Same hit reported through a SECOND unit token (target /
			-- softenemy / nameplate remap) arrives within a frame or two.
			-- Collapse exact school+crit twins inside 50ms so duplicates
			-- cannot steal palette lines from distinct hits. Two fields
			-- pin the signature to a real re-report: the EFFECTIVE unit
			-- must match (post-remap — "nameplate3"->"target" and
			-- "softenemy"->"target" are the same victim), while the
			-- REPORTING token must differ. Distinct hits on the same unit
			-- share the token (imp swarm via one nameplate) and cleave
			-- hits on different units share neither — with amounts secret
			-- on Retail the old school+crit-only signature was eating
			-- ~half of all rapid wounds. Only dedups safe-number schools;
			-- secret schools always pass through. Amount joins the
			-- signature whenever it is safe (Forever's amounts are
			-- readable; Retail's are secret).
			if ZSBT.IsSafeNumber(school) then
				local amtSig = (ZSBT.IsSafeNumber(amount) and amount) or nil
				-- Per effective-unit last-signature: cleave streams
				-- interleave wounds across dummies, and a single shared
				-- slot would compare a wound against an unrelated unit's.
				local sigs = self._lastWoundSigByUnit
				if type(sigs) ~= "table" then
					sigs = {}
					self._lastWoundSigByUnit = sigs
				end
				local ukey = type(unit) == "string" and unit or "?"
				local sig = sigs[ukey]
				-- 20ms window: genuine re-reports dispatch same-frame
				-- (measured ~0ms apart), while a co-attacker's same-school
				-- same-crit wound can land anywhere — a wider window ate
				-- real hits under contention (~1k kills/60s on a shared
				-- dummy). Secret amounts already collapse the signature to
				-- (school,crit) on Retail, so width is the only knob left.
				if sig and (t - sig.t) >= 0 and (t - sig.t) < 0.02
					and sig.token ~= rawUnit
					and sig.school == school and sig.crit == isCrit
					and sig.amount == amtSig then
					H.auditNote("AUDTWIN school=%s crit=%s amt=%s tok=%s", 
						H.dbgSafe(school), tostring(isCrit == true), H.dbgSafe(amount), H.dbgSafe(rawUnit))
					return
				end
				sigs[ukey] = { t = t, school = school, crit = isCrit, amount = amtSig, token = rawUnit }
				-- Bound the map: nameplates churn, so expire entries
				-- older than the dedup window in the same pass.
				for k, v in pairs(sigs) do
					if (t - v.t) >= 0.05 then sigs[k] = nil end
				end
			end
			local zbtc = ZSBT.ZBattleText
			if zbtc and zbtc.FileLog then
				zbtc:FileLog("CAND school=%s crit=%s", (ZSBT.IsSafeNumber(school) and tostring(school)) or "sec", tostring(isCrit == true))
			end
			if not self._auditCapNoted then
				self._auditCapNoted = true
				H.auditNote("AUDCAP swing=%s", tostring(self._swingSupported == true))
			end
			H.auditNote("AUDCAND school=%s crit=%s", 
				(ZSBT.IsSafeNumber(school) and tostring(school)) or "sec", tostring(isCrit == true))
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
		if dl >= 4 and ZSBT.IsSafeNumber(amount) and amount >= getAdaptiveBigHitThreshold(self, t) then
			local members = nil
			if type(GetNumGroupMembers) == "function" then
				local okM, m = pcall(GetNumGroupMembers)
				if okM and type(m) == "number" then members = m end
			end
			H.ECPrint(("BIG_HIT UNIT_COMBAT_TARGET token=%s lastSpell=%s restrict=%s members=%s amt=%s school=%s desc=%s")
				:format(H.dbgSafe(self._castToken), H.dbgSafe(self._lastPlayerSpellId), H.dbgSafe(restrict), H.dbgSafe(members), H.dbgSafe(amount), H.dbgSafe(school), H.dbgSafe(descriptor)))
		end

		-- Pet combat fallback:
		-- Some clients never fire UNIT_COMBAT("pet") WOUND, but do fire UNIT_COMBAT("target")
		-- for pet hits. Also, UnitAffectingCombat("player") may be true during pet combat.
		-- Heuristic: if pet is in combat and we have no recent player cast to attribute,
		-- treat WOUND events on target as pet damage.
		if actionStr == "WOUND" and UnitAffectingCombat and UnitExists then
			local petsEnabled = (H.arePetsEnabled() == true)
			local okEx, hasPet = pcall(UnitExists, "pet")
			if petsEnabled ~= true then
				if dl >= 4 and ZSBT.IsSafeNumber(amount) and amount > 0 and (not isPhysicalEarly) and (ZSBT.IsSafeNumber(school) and school == 4) then
					H.ECPrint(("PET_FALLBACK_SKIP petsEnabled=0 token=%s amt=%s school=%s")
						:format(H.dbgSafe(self._castToken), H.dbgSafe(amount), H.dbgSafe(school)))
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
					if self:_isLikelyPetSchoolHitGivenRecentPlayerSpell(school, self._lastPlayerSpellId) then
						recentPlayerCast = false
					end
					-- DoT ticks can arrive long after the cast and look like small magic WOUND
					-- events. If we have a recent periodic spell in our window, prefer treating
					-- this as player periodic damage instead of pet damage.
					local dotSpellId = nil
					if not isPhysicalEarly then
						dotSpellId = self:_pickDotForWound(t, school, amount, isCrit)
					end
					-- Class-module dot guard: e.g. Warlock Imp fire hits are pet damage,
					-- never player DoT ticks.
					if ZSBT.ClassDB and ZSBT.ClassDB.DotGuard then
						if ZSBT.ClassDB.DotGuard(dotSpellId and H.dotEntryForSpellId(dotSpellId) or nil, school) == false then
							recentPlayerCast = false
							dotSpellId = nil
						end
					end
					-- School safety: a DoT entry may declare its school; never attribute
					-- hits of a different school to it (spellId variants included).
					local dotEntry = dotSpellId and H.dotEntryForSpellId(dotSpellId) or nil
					if dotEntry and dotEntry.school and ZSBT.IsSafeNumber(school) and H.dotEntrySchoolEq(dotEntry.school, school) == false then
						dotSpellId = nil
					end
					if dl >= 4 and ZSBT.IsSafeNumber(amount) and amount > 0 and (not isPhysicalEarly) and (ZSBT.IsSafeNumber(school) and school == 4) then
						local petFam = H.getPetFamilyLower()
						local petNpcId = H.getUnitNpcId("pet")
						H.ECPrint(("PET_FALLBACK_EVAL token=%s restrict=%s recentPlayerCast=%s dotSpellId=%s amt=%s school=%s")
							:format(H.dbgSafe(self._castToken), H.dbgSafe(restrict), H.dbgSafe(recentPlayerCast), H.dbgSafe(dotSpellId), H.dbgSafe(amount), H.dbgSafe(school))
							.. (petNpcId and (" petNpcId=" .. tostring(petNpcId)) or "")
							.. (petFam and (" petFam=" .. tostring(petFam)) or ""))
					end
					-- Safety: only treat it as a DoT tick if the target actually has the debuff.
					-- Without this, any recent non-periodic cast (e.g. Shadow Bolt) can "stick"
					-- as the spellId for unrelated magic WOUND ticks.
					local chanPick = self:_isLiveChannelPick(t, dotSpellId)
					if dotSpellId and not chanPick and (not H.cachedHasTargetDebuffSpellId(dotSpellId)) then
						local allowDot = false
						local de2 = H.dotEntryForSpellId(dotSpellId)
						if de2 and de2.school and ZSBT.IsSafeNumber(school)
							and H.dotEntrySchoolEq(de2.school, school) == true then
							allowDot = true
						end
						if not allowDot then
							dotSpellId = nil
						end
					end
					if dotSpellId and self:_dotCadenceOk(t, dotSpellId) then
						if not isCorroboratedHugeHit(self, restrict, t, amount, dotSpellId) then
							if dl >= 4 then
								H.ECPrint(("BIG_HIT_SUPPRESS src=UNIT_COMBAT_DOT token=%s spellId=%s amt=%s")
									:format(H.dbgSafe(self._castToken), H.dbgSafe(dotSpellId), H.dbgSafe(amount)))
							end
							H.auditNote("AUDD reason=DOT_HUGE_SUPPRESS spellId=%s school=%s", H.dbgSafe(dotSpellId), H.dbgSafe(school))
							return
						end
						if not chanPick and self:_isDuplicateDotEmit(t, dotSpellId) then
							H.auditNote("AUDD reason=DOT_DUP spellId=%s", H.dbgSafe(dotSpellId))
							return
						end
						self._recentPeriodicSpellAt[dotSpellId] = t
						local tName = H.safeUnitName("target")
						self:_noteDotTickAmount(dotSpellId, amount, isCrit, t, tName,
							chanPick == true or self._dotPickTeach == true
								or H.cachedHasTargetDebuffSpellId(dotSpellId) == true)
						local pipeId = self._rawPipeCount + 1
						self._rawPipeCount = pipeId
						self._rawPipe[pipeId] = amount
						H.emit("OUTGOING_DAMAGE_COMBAT", {
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
						self._lastOutgoingCombatTargetGUID = safeTargetGUID("target")
						if self._lastOutgoingCombatTargetGUID then
							local m = self._ownAtByGuid or {}; self._ownAtByGuid = m
							m[self._lastOutgoingCombatTargetGUID] = self._lastOutgoingCombatAt
					
							local n = 0
							for _ in pairs(m) do n = n + 1; if n > 48 then break end end
							if n > 48 then
								local cut = self._lastOutgoingCombatAt - 6
								for k, v in pairs(m) do if v < cut then m[k] = nil end end
							end
						end
						return
					end
					-- UNIT_COMBAT has no source attribution on Midnight, so the pet
					-- fallback must not claim hits it can't identify. Only schools
					-- matching a known pet signature are pet-eligible — this keeps
					-- procs and the player's own non-physical abilities out of the
					-- pet scroll. Unknown/nil schools stay permissive.
					local petEligibleHit = true
					if ZSBT.IsSafeNumber(school) and not H.isLikelyPetSchoolHit(school) then
						petEligibleHit = false
						-- Class hook: physical pets (warlock Dreadstalker/
						-- Gloomhound melee). A school-1 hit the player's own
						-- swing explains is never the pet's. With the veto
						-- trusted, group content is safe — a MY_PET melee
						-- line must confirm the hit downstream; untrusted
						-- stays solo-only (foreign swings are unverifiable).
						if school == 1 and H.isLikelyPetPhysicalHit(school)
							and not (self._swingSupported == true and self:_anySwingRecent(t))
							and (H.zbtVetoActive() or not members or members <= 1) then
							petEligibleHit = true
						end
					end
					if not recentPlayerCast and petEligibleHit then
						if not isCorroboratedHugePetHit(self, restrict, t, amount) then
							if dl >= 4 then
								H.ECPrint(("BIG_HIT_SUPPRESS src=PET_FALLBACK token=%s amt=%s")
									:format(H.dbgSafe(self._castToken), H.dbgSafe(amount)))
							end
							H.auditNote("AUDD reason=PET_HUGE_SUPPRESS school=%s", H.dbgSafe(school))
							return
						end
						-- Group-aware pet gate: when restrict is active (Quiet/Strict/PvP/Instance-Aware)
						-- and we're in a group, only emit if the hit's school matches a known pet
						-- signature. This prevents other players' damage on shared targets from
						-- being misattributed as pet damage.
						if restrict == true and members and members > 1 then
							if not H.isLikelyPetSchoolHit(school) then
								-- v2: a MY_PET line can still prove this hit
								-- (guardian/pet damage the school table misses);
								-- foreign lines veto co-attacker wounds at flush.
								if H.zbtVetoActive() then
									H.auditNote("AUDD reason=BYPASS_PET_GROUP_SUPPRESS school=%s", H.dbgSafe(school))
								else
									if dl >= 4 then
										H.ECPrint(("PET_FALLBACK_GROUP_SUPPRESS restrict=%s members=%s school=%s amt=%s")
											:format(H.dbgSafe(restrict), H.dbgSafe(members), H.dbgSafe(school), H.dbgSafe(amount)))
									end
									H.auditNote("AUDD reason=PET_GROUP_SUPPRESS school=%s", H.dbgSafe(school))
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
						if self:_autoContested(t) then
							H.dbgDrop("CONTESTED", self._castToken, school)
							return
						end
						-- Wound-vs-wound re-reports are already collapsed
						-- upstream by the token-aware target-wound dedup
						-- (AUDTWIN). This path still dedups against a "Your
						-- pet hits" chat line — the chat emit covers the
						-- same hit's display.
						local lastPetChat = self._lastPetChatAt or 0
						if (t - lastPetChat) >= 0 and (t - lastPetChat) < H.PET_OUTGOING_DEDUP_WINDOW then
							H.auditNote("AUDD reason=PET_CHAT_DEDUP")
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
							H.ECPrint(("PET_FALLBACK_EMIT token=%s rawPipeId=%s amt=%s school=%s")
								:format(H.dbgSafe(self._castToken), H.dbgSafe(pipeId), H.dbgSafe(amount), H.dbgSafe(school)))
						end
						local petSid, petUnit = self:_consumePetCast(t, 1.5, school)
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
						local zbt2 = ZSBT.ZBattleText
						if zbt2 and zbt2.FileLog then
							zbt2:FileLog("PET_EMIT ht=%.3f school=%s psid=%s pev=%s tok=%s", 
								tonumber(t) or 0, tostring(school), tostring(petSid),
								tostring(petEvidence or "guess"), tostring(self._castToken))
						end
						if H.zbtVetoActive() then
							-- Pet hits go through the ownership veto: a MY_PET
							-- line must confirm them (the sinkType swap delivers
							-- PET_DAMAGE_COMBAT after pairing). Foreign damage
							-- produces no such line and FLIN vetoes it.
							H.emit("OUTGOING_DAMAGE_COMBAT", {
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
								targetName = H.safeUnitName("target"),
							})
						else
						H.emit("PET_DAMAGE_COMBAT", {
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
							targetName = H.safeUnitName("target"),
						})
						end
						return
					end
				end
			elseif okEx and hasPet ~= true then
				-- Guardian-style pets (e.g. DK ghoul): class module decides.
				if ZSBT.ClassDB and ZSBT.ClassDB.OnGuardianWound then
					local okG, handledOrErr = pcall(ZSBT.ClassDB.OnGuardianWound, self, {
						t = t,
						amount = amount,
						isCrit = isCrit,
						school = school,
						restrict = restrict,
						members = members,
						dl = dl,
						emit = H.emit,
						safeUnitName = H.safeUnitName,
						petSchoolHit = H.isLikelyPetSchoolHit,
						dedupWindow = H.PET_OUTGOING_DEDUP_WINDOW,
						ecPrint = H.ECPrint,
						dbgSafe = H.dbgSafe,
					})
					if okG ~= true then
						local tE = H.now()
						if tE - (self._hookErrAt or -9) >= 5 then
							self._hookErrAt = tE
							local zbt = ZSBT.ZBattleText
							if zbt and zbt.FileLog then
								zbt:FileLog("HOOKERR fn=guardianWound err=%s", H.dbgSafe(handledOrErr))
							end
						end
					elseif handledOrErr then
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
				H.auditNote("AUDD reason=NOT_ATTACKABLE")
				return
			end
		end

		if actionStr == "HEAL" then
			-- PvP Strict Mode: UNIT_COMBAT(target) healing has no ownership attribution and
			-- can frequently represent other players' healing on your target.
			-- Suppress to prevent green outgoing noise (especially for non-healer classes).
			if H.isPvPStrictActive() then
				return
			end
			-- Mob self-heals: the player cannot heal an attackable (hostile)
			-- unit, so a HEAL on the target token is never outgoing when the
			-- target can be attacked (e.g. Owlbeast HoTs). Friendly targets
			-- (healers' allies, pets) are not attackable and pass through.
			if UnitCanAttack then
				local okA, canAtk = pcall(UnitCanAttack, "player", "target")
				if okA then
					local okC, eq = pcall(_secTrue, canAtk)
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
					and self:_miwClaim(self._lastPlayerSpellId, self._lastPlayerSpellAt, t, school) then
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
				local hsid, hPeriodic, why = self:_matchOutgoingHotTick("target", t)
				if hsid == nil then
					if why == "noline" then
						self:_queuePendingHotHeal("target", t, amount, school, isCrit)
						return
					end
					H.auditNote("AUDHX unit=target why=%s", tostring(why))
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
				if self:_isHealAliasDup("target", t) then
					return
				end
				self:_noteHealClaim("target", t)
			end

			local zH = ZSBT.ZBattleText
			if zH and zH.FileLog then
				zH:FileLog("HEAL_TGT sid=%s restrict=%s", tostring(spellId), tostring(restrict == true))
			end
			H.emit("OUTGOING_HEAL_COMBAT", {
				timestamp = t,
				rawPipeId = pipeId,
				amountText = (ZSBT.IsSafeNumber(amount) and tostring(amount)) or nil,
				spellId = spellId,
				targetName = H.safeUnitName("target"),
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
				-- PARRY/DODGE/BLOCK misses come only from melee attacks —
				-- a no-auto class produces none (observed: Tangkresh's
				-- parried swing wore Bane of Agony's pending record).
				local meleeAvoid = actionStr == "PARRY" or actionStr == "DODGE"
					or actionStr == "BLOCK"
				local vetoesAuto = ZSBT.ClassDB and ZSBT.ClassDB.VetoAuto
					and ZSBT.ClassDB.VetoAuto() or false
				if self._lastPlayerSpellAt and self._lastPlayerSpellId
					and not (meleeAvoid and vetoesAuto)
					and not (ZSBT.ClassDB and ZSBT.ClassDB.ExcludedSpellId
						and ZSBT.ClassDB.ExcludedSpellId(self._lastPlayerSpellId)) then
					local age = t - self._lastPlayerSpellAt
					if age >= 0 and age <= 1.5
						and self:_miwClaim(self._lastPlayerSpellId, self._lastPlayerSpellAt, t, school) then
						spellId = self._lastPlayerSpellId
					end
				end
				if restrict and not spellId then
					return
				end
				H.emit("OUTGOING_MISS_COMBAT", {
					timestamp = t,
					amountText = actionStr,
					spellId = spellId,
					amountSource = "UNIT_COMBAT_MISS",
					targetName = H.safeUnitName("target"),
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
			if okPC and inPetCombat == true and H.isLikelyPetSchoolHit(school) then
				petMayOwnHit = true
			end
		end
		local allowAutoFallback = false
		if restrict == true and (not petMayOwnHit) then
			if H.isPvPStrictActive() and H.getPvPStrictFlag("pvpStrictDisableAutoAttackFallback") ~= false then
				allowAutoFallback = false
			else
			-- Normal behavior: instance-only opt-in auto-attack fallback.
			if quietMode ~= true then
				if ZSBT and ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general and ZSBT.db.profile.general.autoAttackRestrictFallback == true then
					allowAutoFallback = true
				end
			-- Quiet mode behavior: separate opt-in for showing auto-attacks while quiet.
			elseif H.isQuietOutgoingAutoAttacks() == true then
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
						-- secret values, so H.isPlayerAutoAttackActive()/H.isPlayerMeleeEngaged()
						-- frequently return false even while actively swinging. When solo (the
						-- members>1 case is already handled above), treat "in combat with a
						-- hostile target" as sufficient evidence of an auto-attack.
						local autoOk = H.isPlayerAutoAttackActive() or H.isPlayerMeleeEngaged()
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
			-- pcall: a module bug must not abort the core wound path —
			-- an error here previously killed the wound outright.
			if ZSBT.ClassDB and ZSBT.ClassDB.OnPhysicalWound then
				local okHook, hookErr = pcall(ZSBT.ClassDB.OnPhysicalWound, self, {
					t = t,
					amount = amount,
					isCrit = isCrit,
					actionStr = actionStr,
					hasTargetDebuff = H.cachedHasTargetDebuffSpellId,
					autoAttackActive = H.isPlayerAutoAttackActive,
					outDbgLevel = H.OutDbgLevel,
					ecPrint = H.ECPrint,
					dbgSafe = H.dbgSafe,
					safeUnitName = H.safeUnitName,
					emit = H.emit,
					-- Module-side swing veto: the collector's learned cadence
					-- marks wounds that sit on a predicted own-swing beat.
					-- Classifiers must not name those (Deep Wounds would
					-- otherwise eat the melee stream at ~3s gaps).
					swingPredicted = function(tt)
						return self:_swingPredictedNear(tt) == true
					end,
				})
				if okHook ~= true and hookErr ~= nil then
					-- Throttled: one audit line per 5s so a bad module
					-- can't flood the ring while errors persist.
					local tE = H.now()
					if tE - (self._hookErrAt or -9) >= 5 then
						self._hookErrAt = tE
						local zbt = ZSBT.ZBattleText
						if zbt and zbt.FileLog then
							zbt:FileLog("HOOKERR err=%s", H.dbgSafe(hookErr))
						end
					end
				end
			end
			-- Attempt to attribute physical hits to a recent cast (abilities like Shield Slam).
			-- If no match exists, treat as auto-attack (no icon). If a pet exists, we require
			-- a match to avoid mis-attributing pet melee.
			-- 0.55 matches the non-physical restrict window below: UC wounds
			-- lag the cast 0.3-0.9s on this client, so 0.35 starved named
			-- claims while still being wide enough to admit foreign hits.
			-- The palette line is the ownership proof downstream either way.
			local castWindow = (restrict == true) and 0.55 or 0.85
			-- Pin to the last ENQUEUED cast (damage casts only): refused casts
			-- like DRW/Gorefiend's still move _lastPlayerSpellId, which would
			-- pin wound claims to a sid that can never match the pool.
			local dmgId, dmgAt = self._lastPlayerDamageCastId, self._lastPlayerDamageCastAt
			local wantSpellId = nil
			if restrict == true then
				wantSpellId = dmgId or self._lastPlayerSpellId
			end
			local wwRecent = false
			if H.isWhirlwindSpellId(dmgId or self._lastPlayerSpellId) and (dmgAt or self._lastPlayerSpellAt) then
				local age = t - (dmgAt or self._lastPlayerSpellAt or 0)
				if age >= 0 and age <= 0.85 then
					wwRecent = true
				end
			end
			if wwRecent and not wantSpellId then
				wantSpellId = dmgId or self._lastPlayerSpellId
			end
			local doConsume = true
			if restrict ~= true then
				doConsume = true
			elseif H.isWhirlwindSpellId(wantSpellId) then
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
			-- Swing-beat wounds are auto attacks: they carry no identity and
			-- can only ever steal a cast's name/budget. Excluding them from
			-- cast claims is unconditional — the autoAttackMode toggle then
			-- governs display only (Hide = silent, Show All = anonymous).
			-- OFFT is NOT gated: swings only hit the current target, so a
			-- nameplate wound on a beat is a real cleave hit. Bleed-tick
			-- naming (physDotCand) also stays open — a DoT tick may
			-- legitimately coincide with a swing beat.
			local onSwingBeat = self:_swingPredictedNear(t, 0.35)
			-- Physical DoT eval runs BEFORE cast claims: tick-grid
			-- membership + a MINE "tick" line is stronger identity evidence
			-- than cast-window proximity — otherwise every bleed tick that
			-- lands inside a cast window steals the cast's icon (the "I'm
			-- HS, not VS" defect). A real direct hit produces a "direct"
			-- line, fails tickOk below, and falls through to cast claims.
			local physDotCand = nil
			do
				local dotSpellId = self:_pickDotForWound(t, school, amount, isCrit)
				physDotCand = dotSpellId
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
				local cadOk = (dotSpellId and tickOk) and self:_dotCadenceOk(t, dotSpellId) or nil
				H.auditNote("AUDD reason=PDOT_EVAL ret=%s tk=%s cad=%s dis=%s", H.dbgSafe(dotSpellId), H.dbgSafe(tickOk), H.dbgSafe(cadOk),
						H.dbgSafe(ZSBT.ClassDB and ZSBT.ClassDB.DotCadenceDisambig and ZSBT.ClassDB.DotCadenceDisambig() or nil))
				if not tickOk then
					dotSpellId = nil
				end
				if dotSpellId and cadOk then
					if not self:_isDuplicateDotEmit(t, dotSpellId) then
						self._recentPeriodicSpellAt[dotSpellId] = t
						local tName = H.safeUnitName("target")
						-- Proven: a client-typed tick line was required to
						-- reach this claim.
						self:_noteDotTickAmount(dotSpellId, amount, isCrit, t, tName, true)
						local pipeId = self._rawPipeCount + 1
						self._rawPipeCount = pipeId
						self._rawPipe[pipeId] = amount
						H.emit("OUTGOING_DAMAGE_COMBAT", {
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
			-- Pet-evidence veto (IS NOT): a cls=pet line at this instant
			-- tags this wound a pet hit. With a pending pet cast record
			-- naming a DIFFERENT spell, it is that pet spell's hit —
			-- never the player record it would steal (tape: Bite/autos
			-- claiming Cobra/KC records, real hits then finding
			-- pool=EMPTY). Same-name pet strikes (KC strike 83381 vs
			-- player record 34026) stay claimable — the record IS their
			-- name. Line-only proof (autos) vetoes on retail only.
			-- PetExecuted sids are exempt both ways: their legitimate
			-- hits are pet-lined by design (KC strike, Bloodshed bleed),
			-- so pet evidence can never distinguish steal from strike —
			-- the flight gate owns that question for them.
			local petVeto = nil
			local zbtV = ZSBT.ZBattleText
			if zbtV and zbtV.PeekDamageLine
				and zbtV:PeekDamageLine(t, 0.12, { melee = true }) then
				local peek = self:_consumeBestPendingCast(t, wantSpellId, castWindow, false, school)
				if not peek and wantSpellId then
					peek = self:_consumeBestPendingCast(t, nil, castWindow, false, school)
				end
				if peek
					and not (ZSBT.ClassDB and ZSBT.ClassDB.PetExecuted
						and ZSBT.ClassDB.PetExecuted(peek.spellId)) then
					local pSid = pendingPetCast(self, t, 1.5, school)
					if pSid and pSid ~= peek.spellId then
						local pN, rN = auraSpellName(pSid), auraSpellName(peek.spellId)
						if pN and rN and pN ~= rN then petVeto = true end
					elseif pSid == nil
						and not (ZSBT.ClassDB and ZSBT.ClassDB.IsForever
							and ZSBT.ClassDB.IsForever()) then
						petVeto = true
					end
				end
			end
			-- Empty-report drop (prefer the queued strike's hit: the
			-- next-swing frame carries an Empty Report before the real
			-- Hit, and the empty one rides the cast's own instant —
			-- cast.at == first.at). A phys wound claiming a pending
			-- nextSwing record at dt≈0 is that phantom — the empowered
			-- swing cannot land at press time. Amounts are secret on
			-- this client (type() lies: "number", IsSafeNumber fails)
			-- so the report's 0 amount is unreadable — the cast-time
			-- coincidence is the only legible marker. The record stays
			-- unconsumed so the SAME-frame real hit (the second wound,
			-- e.g. the sid=nil crit in the tape) claims it — a
			-- record-bound wound is proven, which on Forever emits
			-- noline and skips the foreign vetoes that killed it.
			-- Swing-beat wounds stay exempt: a press landing on the
			-- beat is a real swing, not the phantom.
			if onSwingBeat ~= true and ZSBT.ClassDB and ZSBT.ClassDB.NextSwing then
				local peekNS = self:_consumeBestPendingCast(t, wantSpellId, castWindow, false, school)
				if not peekNS and wantSpellId then
					peekNS = self:_consumeBestPendingCast(t, nil, castWindow, false, school)
				end
				-- Pool-miss fallback: the last-damage-cast stamp proves
				-- the press even when the record pool is starved
				-- (tape: level-up transiently broke claimability —
				-- phantom emitted "0" until /reload rebuilt state).
				if not peekNS then
					local lsid = self._lastPlayerDamageCastId or self._lastPlayerSpellId
					local lat = self._lastPlayerDamageCastAt or self._lastPlayerSpellAt
					if lsid and lat and ZSBT.ClassDB.NextSwing(lsid) then
						peekNS = { spellId = lsid, at = lat }
					end
				end
				-- One drop per cast: the frame's SECOND report is the
				-- real hit — dropping every same-instant wound
				-- kills the damage entirely (tape: both nameplate and
				-- target reports dropped, nothing showed).
				if peekNS and peekNS.at and (t - peekNS.at) < 0.30
					and ZSBT.ClassDB.NextSwing(peekNS.spellId)
					and self._emptyReportCastAt ~= peekNS.at then
					self._emptyReportCastAt = peekNS.at
					local zbtN = ZSBT.ZBattleText
					if zbtN and zbtN.FileLog and ZSBT._ucDropTrace == true then
						zbtN:FileLog("EMPTY_REPORT sid=%s dt=%.2f", tostring(peekNS.spellId), t - peekNS.at)
					end
					return
				end
			end
			local matchedCast = nil
			if onSwingBeat ~= true and not petVeto then
				matchedCast = self:_consumeBestPendingCast(t, wantSpellId, castWindow, doConsume, school)
				-- Pin miss -> pool fallback: the newest cast can be a
				-- different school than this wound (DK: phys wound pinned
				-- to a shadow cast can never match, stranding its OWN
				-- phys record in the pool). self._castSchoolOk still filters,
				-- and foreign ownership is proven downstream by palette
				-- lines — the pin was only ever a preference, not a gate.
				if not matchedCast and wantSpellId then
					matchedCast = self:_consumeBestPendingCast(t, nil, castWindow, doConsume, school)
				end
			end
			if not matchedCast then
				-- PHYS_MISS: record exactly why the pending pool couldn't name
				-- this wound — want sid, and every queued cast as sid@dt —
				-- so logs answer "no record / wrong pin / aged out" directly.
				-- swing=1 marks intentional exclusion (predicted white hit).
				local zbtM = ZSBT.ZBattleText
				if zbtM and zbtM.FileLog and ZSBT._ucDropTrace == true then
					local parts = nil
					for _, c in ipairs(self._pendingCasts or {}) do
						if c and c.at and c.spellId then
							parts = (parts and (parts .. ",") or "") .. tostring(c.spellId) .. "@" .. string.format("%.2f", t - c.at)
						end
					end
					zbtM:FileLog("PHYS_MISS want=%s school=%s pool=%s%s%s", 
						tostring(wantSpellId), tostring(school), parts or "EMPTY",
						onSwingBeat == true and " swing=1" or "",
						petVeto == true and " pv=1" or "")
				end
			end
			-- Strict/restricted mode normally requires a pending-cast match. For Whirlwind,
			-- the UNIT_COMBAT(target) stream can contain more hits than we can reliably
			-- match; allow a short post-cast window to still attribute as Whirlwind.
			if (not matchedCast) and onSwingBeat ~= true and not petVeto
				and H.isWhirlwindSpellId(wantSpellId) and wwRecent then
				matchedCast = { spellId = wantSpellId, eligibleIcon = true }
			end
			-- Recency claim (parity with the non-physical miw path): a cast's
			-- pending record is single-consume, so hits #2..N of a cleave —
			-- and phys wounds landing past the pending window — can still
			-- name off the last cast. self._miwClaim enforces the sid@castAt
			-- budget; self._castSchoolOk keeps a shadow cast from naming a phys
			-- wound. Skipped when a phys DoT already claimed this wound's
			-- slot (bleed ticks must not wear the applicator's name) and
			-- when the wound sits on a predicted swing beat (white swings
			-- stay anonymous rather than wearing the last cast).
			if restrict and not matchedCast and physDotCand == nil
				and onSwingBeat ~= true and not petVeto then
				local lastAt = dmgAt or self._lastPlayerSpellAt
				local lastId = dmgId or self._lastPlayerSpellId
				if type(lastAt) == "number" and type(lastId) == "number" then
					local age = t - lastAt
					-- The cast must have already produced a claimed hit
					-- (pending or OFFT) — that makes this a cleave follow-
					-- up, not a stray wound borrowing the name. And 0.75s,
					-- not the non-physical 1.25: measured claims past ~0.7s
					-- were the NEXT ability's wounds wearing this name.
					local prior = castClaimGet(self, lastId, lastAt)
					if age >= 0 and age <= 0.75 and prior >= 1
						and self:_castSchoolOk(lastId, school)
						and not (ZSBT.ClassDB and ZSBT.ClassDB.ExcludedSpellId
							and ZSBT.ClassDB.ExcludedSpellId(lastId))
						and self:_miwClaim(lastId, lastAt, t, school) then
						matchedCast = { spellId = lastId, eligibleIcon = true }
					end
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
					if H.zbtVetoActive() then
						H.dbgDrop("BYPASS_INST_UNATTR", self._castToken, school)
						matchedCast = { spellId = nil, eligibleIcon = false }
					else
						H.dbgDrop("INST_UNATTR", self._castToken, school)
						return
					end
				end
				if not matchedCast and self:_autoContested(t) then
					H.dbgDrop("CONTESTED", self._castToken, school)
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
				if canShow and not self:_swingExplainsHit(t) then
					canShow = false
				end
				if canShow then
					self._lastAutoRestrictAt = t
					local pipeId = self._rawPipeCount + 1
					self._rawPipeCount = pipeId
					self._rawPipe[pipeId] = amount
					self._lastOutgoingCombatAt = t
					self._lastOutgoingCombatTargetName = H.safeUnitName("target")
					self._lastOutgoingCombatTargetGUID = safeTargetGUID("target")
					if self._lastOutgoingCombatTargetGUID then
						local m = self._ownAtByGuid or {}; self._ownAtByGuid = m
						m[self._lastOutgoingCombatTargetGUID] = self._lastOutgoingCombatAt
				
						local n = 0
						for _ in pairs(m) do n = n + 1; if n > 48 then break end end
						if n > 48 then
							local cut = self._lastOutgoingCombatAt - 6
							for k, v in pairs(m) do if v < cut then m[k] = nil end end
						end
					end
					H.emit("OUTGOING_DAMAGE_COMBAT", {
						timestamp = t,
						rawPipeId = pipeId,
						spellId = nil,
						isAuto = true,
						amountSource = "UNIT_COMBAT_AUTO_FALLBACK",
						targetName = H.safeUnitName("target"),
						isCrit = isCrit,
						schoolMask = ZSBT.IsSafeNumber(school) and school or nil,
					})
					return
				end
			end
			if restrict and not matchedCast then
				if H.zbtVetoActive() then
					H.dbgDrop("BYPASS_RESTRICT_PHYS", self._castToken, school)
					matchedCast = { spellId = nil, eligibleIcon = false }
				else
					H.dbgDrop("RESTRICT_PHYS", self._castToken, school)
					return
				end
			end
			if hasPet and not matchedCast then
				-- With a pet out, unattributed physical hits were assumed to be the
				-- pet's. Only drop them here when the pet fallback could actually
				-- claim this hit (school signature match); otherwise it's the
				-- player's own swing and should continue to the white-hit path.
				if H.isLikelyPetSchoolHit(school) then
					if H.zbtVetoActive() then
						H.dbgDrop("BYPASS_PET_SCHOOL_PHYS", self._castToken, school)
						matchedCast = { spellId = nil, eligibleIcon = false }
					else
						H.dbgDrop("PET_SCHOOL_PHYS", self._castToken, school)
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
					if H.zbtVetoActive() then
						H.dbgDrop("BYPASS_INST_UNATTR", self._castToken, school)
					else
						H.dbgDrop("INST_UNATTR", self._castToken, school)
						return
					end
				elseif self:_autoContested(t) then
					H.dbgDrop("CONTESTED", self._castToken, school)
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
					-- unreliable or return secret values, so H.isPlayerAutoAttackActive() and
					-- H.isPlayerMeleeEngaged() frequently return false even while actively
					-- swinging. In solo open-world (restrict off, quiet off) there is no one
					-- else to attribute the hit to, so treat "player in combat with a hostile
					-- target" as sufficient evidence of a white swing. Group/instance leakage
					-- is still handled by the restrict/instance-aware gates above.
					autoOk = (H.isPlayerAutoAttackActive() or H.isPlayerMeleeEngaged()) and true or false
					if (not autoOk) and (not inPlayerCombat) then
						okSwing = false
					end
				end
				if not okSwing then
					H.auditNote("AUDD reason=WHT_EV inCbt=%s canAtk=%s auto=%s school=%s", tostring(inPlayerCombat), tostring(canAtk), tostring(autoOk), H.dbgSafe(school))
					return
				end
			end
			-- Prevent Whirlwind multi-hit attribution from absorbing unrelated huge physical
			-- spikes in restricted instances (follower/party melee has no source attribution).
			if restrict == true and H.isWhirlwindSpellId(spellId) and ZSBT.IsSafeNumber(amount) then
				local st = self._restrictPhysMulti
				if type(st) == "table" and st.token == self._castToken and H.isWhirlwindSpellId(st.spellId) then
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
			if not isCorroboratedHugeHit(self, restrict, t, amount, spellId or self._lastPlayerSpellId) then
				if dl >= 4 then
					H.ECPrint(("BIG_HIT_SUPPRESS src=UNIT_COMBAT_PHYSICAL token=%s spellId=%s amt=%s")
						:format(H.dbgSafe(self._castToken), H.dbgSafe(spellId), H.dbgSafe(amount)))
				end
				H.dbgDrop("WHT_HUGE", self._castToken, school)
				return
			end
			if H.isWhirlwindSpellId(spellId) and H.wwAggEnabled(spellId)
				and ZSBT.IsSafeNumber(amount) and amount > 0 then
				-- If we are receiving addon-readable Whirlwind chat hits for this same cast,
				-- do not double-count the UNIT_COMBAT stream.
				local chatTok = self._wwAggChatToken
				local chatAt = self._wwAggChatAt or 0
				if chatTok == self._castToken and (t - chatAt) >= 0 and (t - chatAt) <= 1.25 then
					return
				end
				self:_wwAggPush(t, spellId, amount, isCrit, true)
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
				if (t - lastAuto) >= 0 and (t - lastAuto) < H.AUTO_OUTGOING_DEDUP_WINDOW then
					H.dbgDrop("WHT_DEDUP", self._castToken, school)
					return
				end
				self._lastAutoOutgoingAt = t
			end
			local pipeId = self._rawPipeCount + 1
			self._rawPipeCount = pipeId
			self._rawPipe[pipeId] = amount
			self._lastOutgoingCombatAt = t
			self._lastOutgoingCombatTargetName = H.safeUnitName("target")
			self._lastOutgoingCombatTargetGUID = safeTargetGUID("target")
			if self._lastOutgoingCombatTargetGUID then
				local m = self._ownAtByGuid or {}; self._ownAtByGuid = m
				m[self._lastOutgoingCombatTargetGUID] = self._lastOutgoingCombatAt
		
				local n = 0
				for _ in pairs(m) do n = n + 1; if n > 48 then break end end
				if n > 48 then
					local cut = self._lastOutgoingCombatAt - 6
					for k, v in pairs(m) do if v < cut then m[k] = nil end end
				end
			end
			-- A physical hit with no cast and no player swing is not your
			-- auto — pet melee claims it when the class hook allows (the
			-- veto then verifies a MY_PET line when trusted).
			local swingOk = self:_swingExplainsHit(t)
			local petRoutePhys = nil
			local petSidPhys = nil
			local petEvidence = nil
			if spellId == nil and not swingOk
				and H.isLikelyPetPhysicalHit(school)
				and (H.zbtVetoActive() or not members or members <= 1) then
				petRoutePhys = true
				petSidPhys = self:_consumePetCast(t, 1.5, school)
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
			H.emit("OUTGOING_DAMAGE_COMBAT", {
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
				targetName = H.safeUnitName("target"),
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
						schoolOk = H.dotEntrySchoolEq(ch.school, school) == true
					end
					if not schoolOk then
						H.auditNote("AUDD reason=CHANNEL_SCHOOL school=%s want=%s", 
							H.dbgSafe(school), H.dbgSafe(ch.school))
					end
					local dtTick = t - (ch.lastTickAt or 0)
					if schoolOk and dtTick >= (ch.tickMin or 0.12) then
						ch.lastTickAt = t
						local pipeId = self._rawPipeCount + 1
						self._rawPipeCount = pipeId
						self._rawPipe[pipeId] = amount
						self._lastOutgoingCombatAt = t
						self._lastOutgoingCombatTargetName = H.safeUnitName("target")
						self._lastOutgoingCombatTargetGUID = safeTargetGUID("target")
						if self._lastOutgoingCombatTargetGUID then
							local m = self._ownAtByGuid or {}; self._ownAtByGuid = m
							m[self._lastOutgoingCombatTargetGUID] = self._lastOutgoingCombatAt
					
							local n = 0
							for _ in pairs(m) do n = n + 1; if n > 48 then break end end
							if n > 48 then
								local cut = self._lastOutgoingCombatAt - 6
								for k, v in pairs(m) do if v < cut then m[k] = nil end end
							end
						end
						H.emit("OUTGOING_DAMAGE_COMBAT", {
							timestamp = t,
							rawPipeId = pipeId,
							spellId = ch.spellId,
							amountSource = "UNIT_COMBAT_DOT",
							targetName = H.safeUnitName("target"),
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
				local dotSpellId = self:_pickDotForWound(t, school, amount, isCrit)
				-- Safety: only treat it as a DoT tick if the target actually has the debuff.
				local debuffOk = nil
				local chanPick = self:_isLiveChannelPick(t, dotSpellId)
				if dotSpellId and not chanPick then
					debuffOk = H.cachedHasTargetDebuffSpellId(dotSpellId)
					if debuffOk ~= true then
						local allowDot = false
						local de3 = H.dotEntryForSpellId(dotSpellId)
						if de3 and de3.school and ZSBT.IsSafeNumber(school)
							and H.dotEntrySchoolEq(de3.school, school) == true then
							allowDot = true
						end
						if not allowDot then
							if dl >= 4 then
								H.ECPrint(("DOT_ATTRIB_FAIL src=UNIT_COMBAT_SMALL token=%s dotSpellId=%s debuffOk=%s amt=%s school=%s")
									:format(H.dbgSafe(self._castToken), H.dbgSafe(dotSpellId), H.dbgSafe(debuffOk), H.dbgSafe(amount), H.dbgSafe(school)))
							end
							dotSpellId = nil
						end
					end
				end
				if dotSpellId and self:_dotCadenceOk(t, dotSpellId) then
					if dl >= 4 and ZSBT.IsSafeNumber(amount) and amount >= H.BIG_HIT_THRESHOLD then
						H.ECPrint(("BIG_HIT DOT token=%s spellId=%s amt=%s")
							:format(H.dbgSafe(self._castToken), H.dbgSafe(dotSpellId), H.dbgSafe(amount)))
					end
					if not chanPick and self:_isDuplicateDotEmit(t, dotSpellId) then
						return
					end
					self._recentPeriodicSpellAt[dotSpellId] = t
					local tName = H.safeUnitName("target")
					self:_noteDotTickAmount(dotSpellId, amount, isCrit, t, tName,
						chanPick == true or debuffOk == true or self._dotPickTeach == true)
					local pipeId = self._rawPipeCount + 1
					self._rawPipeCount = pipeId
					self._rawPipe[pipeId] = amount
					H.emit("OUTGOING_DAMAGE_COMBAT", {
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
					self._lastOutgoingCombatTargetGUID = safeTargetGUID("target")
					if self._lastOutgoingCombatTargetGUID then
						local m = self._ownAtByGuid or {}; self._ownAtByGuid = m
						m[self._lastOutgoingCombatTargetGUID] = self._lastOutgoingCombatAt
				
						local n = 0
						for _ in pairs(m) do n = n + 1; if n > 48 then break end end
						if n > 48 then
							local cut = self._lastOutgoingCombatAt - 6
							for k, v in pairs(m) do if v < cut then m[k] = nil end end
						end
					end
					return
				end
				suppressIfUnattributed = true
			end
			-- Physical with a pet is too ambiguous.
			if isPhysical and hasPet then
				if H.zbtVetoActive() then
					H.dbgDrop("BYPASS_PHYS_PET", self._castToken, school)
					matchedCast = { spellId = nil, eligibleIcon = false }
				else
					H.dbgDrop("PHYS_PET", self._castToken, school)
					return
				end
			end
			local castWindow = (restrict == true) and 0.55 or 0.85
			local wantSpellId = nil
			if restrict == true then
				wantSpellId = self._lastPlayerDamageCastId or self._lastPlayerSpellId
			end
			-- Non-phys DoT eval BEFORE cast claims (phys-path parity): a
			-- grid-corroborated tick is stronger identity evidence than
			-- cast-window proximity — a Blood Plague tick inside a Death
			-- Coil window must not steal the Coil icon. The nuke guard is
			-- now evidence-based: only a direct-kind palette line near the
			-- wound blocks the dot pick — cast recency alone is always
			-- true in combat and was what let ticks wear nukes.
			local blockedDotCastId = nil
			if not matchedCast then
				-- Class-module DoT attribution (secret-safe): an unattributed
				-- non-physical WOUND can be a periodic tick. No amount comparisons
				-- are needed — the amount goes straight into the raw pipe, which is
				-- the only display-safe path for secret values on Retail 12.x.
				local dotSpellId = self:_pickDotForWound(t, school, amount, isCrit)
				-- Don't let a DoT steal a hit that probably belongs to a nuke cast
				-- moments ago — but only when the nuke's own evidence is
				-- present: a direct/melee/ranged/shield palette line near
				-- the wound (the hit's own claim to being non-periodic).
				local dotBlockedByRecentCast = false
				local eraClient = ZSBT.ClassDB and ZSBT.ClassDB.IsForever
					and ZSBT.ClassDB.IsForever() == true or nil
				local lastCastAt = self._lastPlayerSpellAt
				local lastCastId = self._lastPlayerSpellId
				local directEvidence = false
				local zbtDL = ZSBT.ZBattleText
				if zbtDL and zbtDL.PeekDamageLine then
					directEvidence = zbtDL:PeekDamageLine(t, 0.30,
						{ direct = true, melee = true, ranged = true, shield = true }) ~= nil
				end
				if type(lastCastAt) == "number" and type(lastCastId) == "number"
					and (t - lastCastAt) >= 0 and (t - lastCastAt) <= 1.50
					and directEvidence == true
					and not H.dotEntryForSpellId(lastCastId)
					and not (ZSBT.ClassDB and ZSBT.ClassDB.ExcludedSpellId
						and ZSBT.ClassDB.ExcludedSpellId(lastCastId)) then
					dotBlockedByRecentCast = true
					-- Era: the cast veto is mutual. self._castSchoolOk exempts player
					-- casts on Forever (wound schools lie there), so a frequent
					-- recast like wand Shoot can block a surviving dot pick and
					-- then take the same wound no-line. When a pick was actually
					-- vetoed, the blocking cast cannot claim noline either —
					-- the wound goes generic rather than wearing a wrong name.
					if eraClient and dotSpellId ~= nil then
						blockedDotCastId = lastCastId
					end
				end
				-- Rival-cast veto (IS NOT, retail only): a fresh pending cast
				-- record for a DIFFERENT same-school sid outranks a DoT anchor
				-- unless the wound carries periodic proof — a tick-kind feed
				-- line. The Black Arrow anchor claimed every Bleak Arrows auto
				-- wound: same s32, the BA debuff is always up when Bleak fires,
				-- and the ~2.4s shot cadence sits inside the tick gate's
				-- window. A real tick keeps its tick line; the shot's hit holds
				-- a ranged/direct line instead and belongs to its own record.
				-- Era excluded: Forever's feed produces no tick-kind lines at
				-- all (proof can never fire) and its disambig picker already
				-- runs typed-line evidence — the veto would hand cast records
				-- real DoT ticks there.
				if not eraClient and dotSpellId and not dotBlockedByRecentCast then
					local shotProof = nil
					local famRec = nil
					-- Flight-window family proof first: a wound landing at
					-- shot-flight age of an unconsumed ranged-family record
					-- IS that shot. On feeds without tick/ranged line kinds
					-- this record-age check is the only discriminator, and
					-- consuming the record here also stops the vetoed wound's
					-- pending-cast fall-through from stealing it (observed:
					-- vetoed Black Arrow ticks claiming the Bleak record).
					local prl = ZSBT.ClassDB and ZSBT.ClassDB.PreferRangedLine
					if prl then
						local lo, hi = wandFlightWindow(self)
						for _, c in ipairs(self._pendingCasts or {}) do
							if c and type(c.at) == "number" and c.spellId
								and prl(c.spellId) and c.spellId ~= dotSpellId then
								local rdt = t - c.at
								if rdt >= lo and rdt <= hi then famRec = c end
							end
						end
					end
					if famRec then
						shotProof = famRec.spellId
					else
						local rival = self:_consumeBestPendingCast(t, nil, castWindow, false, school)
						if rival and rival.spellId ~= dotSpellId then
							shotProof = rival.spellId
						end
						if not shotProof and self._wandSid ~= nil
							and type(self._wandAt) == "number"
							and (t - self._wandAt) >= 0 and (t - self._wandAt) <= 3.5 then
							-- Sustained ranged family live (Bleak Arrows/Shoot): a
							-- RANGED line near the wound is the client's proof a shot
							-- fired even after the shot's cast record expired —
							-- flight-time wounds otherwise feed the DoT anchor.
							-- (disambig picker's wand veto, applied to the anchor path;
							-- includeConsumed — the shot's own claim may have eaten it.)
							local zbtW = ZSBT.ZBattleText
							if zbtW and zbtW.PeekDamageLine and zbtW:PeekDamageLine(t, 0.35, { ranged = true }, true) ~= nil then
								shotProof = self._wandSid
							end
						end
					end
					if shotProof then
						local zbtT = ZSBT.ZBattleText
						local tickLine = zbtT and zbtT.PeekDamageLine
							and zbtT:PeekDamageLine(t, 0.30, { tick = true })
						if not tickLine then
							local claimed = nil
							if famRec then
								local mc = self:_consumeBestPendingCast(t, famRec.spellId, nil, true, school)
								if mc then
									claimed = { spellId = mc.spellId, eligibleIcon = mc.eligibleIcon, wandProven = true }
								end
							end
							if famRec and not claimed then
								-- The family record was school-rejected on
								-- consume — the wound is not its shot after
								-- all; leave the anchor intact.
							else
								H.auditNote("AUDD reason=DOT_RIVAL_VETO dot=%s rival=%s school=%s", H.dbgSafe(dotSpellId), H.dbgSafe(shotProof), H.dbgSafe(school))
								if claimed then matchedCast = claimed end
								dotSpellId = nil
							end
						end
					end
				end
				local chanPick = self:_isLiveChannelPick(t, dotSpellId)
				if dotSpellId and (not dotBlockedByRecentCast or chanPick) then
					if ZSBT.ClassDB and ZSBT.ClassDB.DotGuard then
						if ZSBT.ClassDB.DotGuard(H.dotEntryForSpellId(dotSpellId), school) == false then
							dotSpellId = nil
						end
					end
					local dotEntry = dotSpellId and H.dotEntryForSpellId(dotSpellId) or nil
					if dotEntry and dotEntry.school and ZSBT.IsSafeNumber(school) and H.dotEntrySchoolEq(dotEntry.school, school) == false then
						dotSpellId = nil
					end
					if dotSpellId and not chanPick then
						local debuffOk = H.cachedHasTargetDebuffSpellId(dotSpellId)
						if debuffOk ~= true then
							local allowDot = false
							if dotEntry and dotEntry.school and ZSBT.IsSafeNumber(school) and H.dotEntrySchoolEq(dotEntry.school, school) == true then
								allowDot = true
							end
							if not allowDot then
								dotSpellId = nil
							end
						end
					end
					if dotSpellId and isCorroboratedHugeHit(self, restrict, t, amount, dotSpellId) then
						-- Cadence gate: reject hits that don't land in a plausible
						-- tick slot (shared-target bleed-through protection).
						if not self:_dotCadenceOk(t, dotSpellId) then
							dotSpellId = nil
						else
						if not chanPick and self:_isDuplicateDotEmit(t, dotSpellId) then
							return
						end
						if H.OutDbgLevel() >= 4 then
							H.ECPrint(("DOT_ATTRIB src=UNIT_COMBAT_MERGE token=%s spellId=%s amt=%s school=%s")
								:format(H.dbgSafe(self._castToken), H.dbgSafe(dotSpellId), H.dbgSafe(amount), H.dbgSafe(school)))
						end
						self._recentPeriodicSpellAt[dotSpellId] = t
						local tName = H.safeUnitName("target")
						self:_noteDotTickAmount(dotSpellId, amount, isCrit, t, tName,
							chanPick == true or self._dotPickTeach == true)
						local pipeId = self._rawPipeCount + 1
						self._rawPipeCount = pipeId
						self._rawPipe[pipeId] = amount
						self._lastOutgoingCombatAt = t
						self._lastOutgoingCombatTargetName = tName
						self._lastOutgoingCombatTargetGUID = safeTargetGUID("target")
						if self._lastOutgoingCombatTargetGUID then
							local m = self._ownAtByGuid or {}; self._ownAtByGuid = m
							m[self._lastOutgoingCombatTargetGUID] = self._lastOutgoingCombatAt
					
							local n = 0
							for _ in pairs(m) do n = n + 1; if n > 48 then break end end
							if n > 48 then
								local cut = self._lastOutgoingCombatAt - 6
								for k, v in pairs(m) do if v < cut then m[k] = nil end end
							end
						end
						H.emit("OUTGOING_DAMAGE_COMBAT", {
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
			end
			matchedCast = matchedCast or self:_consumeBestPendingCast(t, wantSpellId, castWindow, nil, school)
			-- Same pin-fallback as the phys path: a non-phys wound pinned
			-- to a phys cast is equally unclaimable; school-fit keeps the
			-- pool search honest and ownership still needs a palette line.
			if not matchedCast and wantSpellId then
				matchedCast = self:_consumeBestPendingCast(t, nil, castWindow, nil, school)
			end
			-- Sustained wand family: Shoot's activation record is spent
			-- after the first hits; the last claimed shot + the client's
			-- own ranged line is the proof for the rest of the session.
			if not matchedCast then
				local wandSid = self._pickWandShot and self._pickWandShot(self, t, school)
				if wandSid ~= nil then
					-- wandProven: the ranged line proved a shot — this claim
					-- may vote the wand's element. Pending-cast claims stay
					-- unproven (a consumed wrong-school wound would teach
					-- the wrong element during bootstrap).
					matchedCast = { spellId = wandSid, eligibleIcon = true, wandProven = true }
					H.dbgDrop("WAND_FAM", self._castToken, school)
				end
			end
			if not matchedCast then
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
						or (quietMode == true and H.isQuietOutgoingAutoAttacks() == true)
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
							and (not self:_autoContested(t)) and self:_swingExplainsHit(t) then
							-- Same dedup as the physical branch: the fallback and
							-- physical paths can both fire for one white swing.
							local lastAuto = self._lastAutoOutgoingAt or 0
							if (t - lastAuto) >= 0 and (t - lastAuto) < H.AUTO_OUTGOING_DEDUP_WINDOW then
								return
							end
							self._lastAutoOutgoingAt = t
							local pipeId = self._rawPipeCount + 1
							self._rawPipeCount = pipeId
							self._rawPipe[pipeId] = amount
							self._lastOutgoingCombatAt = t
							self._lastOutgoingCombatTargetName = H.safeUnitName("target")
							self._lastOutgoingCombatTargetGUID = safeTargetGUID("target")
							if self._lastOutgoingCombatTargetGUID then
								local m = self._ownAtByGuid or {}; self._ownAtByGuid = m
								m[self._lastOutgoingCombatTargetGUID] = self._lastOutgoingCombatAt
						
								local n = 0
								for _ in pairs(m) do n = n + 1; if n > 48 then break end end
								if n > 48 then
									local cut = self._lastOutgoingCombatAt - 6
									for k, v in pairs(m) do if v < cut then m[k] = nil end end
								end
							end
								H.emit("OUTGOING_DAMAGE_COMBAT", {
								timestamp = t,
								rawPipeId = pipeId,
								spellId = nil,
								isAuto = true,
								amountSource = "UNIT_COMBAT_AUTO_FALLBACK",
								targetName = H.safeUnitName("target"),
								isCrit = isCrit,
								schoolMask = ZSBT.IsSafeNumber(school) and school or nil,
							})
							return
						else
							H.auditNote("AUDD reason=AUTO_FB inCbt=%s canAtk=%s members=%s swing=%s school=%s", tostring(inPlayerCombat), tostring(canAtk), H.dbgSafe(members),
									tostring(self:_swingExplainsHit(t)), H.dbgSafe(school))
						end
					else
						H.auditNote("AUDD reason=AUTO_FB_OFF restrict=%s quiet=%s school=%s", tostring(restrict == true), tostring(quietMode == true), H.dbgSafe(school))
					end
					H.dbgDrop("SUPPRESS_UNATTR", self._castToken, school)
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
						if H.zbtVetoActive() then
							H.dbgDrop("BYPASS_GROUP_GATE", self._castToken, school)
							matchedCast = { spellId = nil, eligibleIcon = false }
						else
							H.dbgDrop("GROUP_GATE", self._castToken, school)
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
						if age >= 0 and age <= maxAge and self:_castSchoolOk(lastId, school)
							and not (ZSBT.ClassDB and ZSBT.ClassDB.ExcludedSpellId
								and ZSBT.ClassDB.ExcludedSpellId(lastId))
							and blockedDotCastId ~= lastId
							and self:_miwClaim(lastId, lastAt, t, school) then
							matchedCast = { spellId = lastId, eligibleIcon = true }
						else
							if H.zbtVetoActive() then
								H.dbgDrop("BYPASS_RESTRICT_AGE", self._castToken, school)
								matchedCast = { spellId = nil, eligibleIcon = false }
							else
								H.dbgDrop("RESTRICT_AGE", self._castToken, school)
								return
							end
						end
					else
						if H.zbtVetoActive() then
							H.dbgDrop("BYPASS_RESTRICT_NOCAST", self._castToken, school)
							matchedCast = { spellId = nil, eligibleIcon = false }
						else
							H.dbgDrop("RESTRICT_NOCAST", self._castToken, school)
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
							if age >= 0 and age <= maxAge and self:_castSchoolOk(lastId, school)
								and blockedDotCastId ~= lastId
								and not (ZSBT.ClassDB and ZSBT.ClassDB.ExcludedSpellId
									and ZSBT.ClassDB.ExcludedSpellId(lastId))
								and self:_miwClaim(lastId, lastAt, t, school) then
								matchedCast = { spellId = lastId, eligibleIcon = true }
							else
								-- Quiet/strict: suppress unattributed numbers when we cannot even loosely
								-- correlate to a recent player cast.
								if quietMode == true or restrict == true then
									if not H.zbtVetoActive() then
										H.dbgDrop("MIW_QUIET", self._castToken, school)
										return
									end
								end
								matchedCast = { spellId = nil, eligibleIcon = false }
							end
						else
							if quietMode == true or restrict == true then
								if not H.zbtVetoActive() then
									H.dbgDrop("MIW_QUIET", self._castToken, school)
									return
								end
							end
							matchedCast = { spellId = nil, eligibleIcon = false }
						end
					else
						if H.zbtVetoActive() then
							H.dbgDrop("BYPASS_MIW_AGE", self._castToken, school)
							matchedCast = { spellId = nil, eligibleIcon = false }
						else
							H.dbgDrop("MIW_AGE", self._castToken, school)
							return
						end
					end
				else
					if H.zbtVetoActive() then
						H.dbgDrop("BYPASS_MIW_NO_CAST", self._castToken, school)
						matchedCast = { spellId = nil, eligibleIcon = false }
					else
						H.dbgDrop("MIW_NO_CAST", self._castToken, school)
						return
					end
				end
				end
			end
		end

		local spellId = nil
		local sidLearn = nil
		local wandProven = nil
		if existing and existing.spellId then
			spellId = existing.spellId
			sidLearn = existing._sidLearn
			wandProven = existing.wandProven
		elseif matchedCast then
			spellId = (matchedCast.eligibleIcon == true) and matchedCast.spellId or nil
			sidLearn = (matchedCast.spellId ~= nil) or nil
			wandProven = matchedCast.wandProven
		end

		-- Shared-target guard for the generic emit: a wound that earned no
		-- name is indistinguishable from a co-attacker's hit on the same
		-- mob. In instances it can never be proven ours; in the open world
		-- it feeds the contested detector (line-less wounds only — own
		-- damage carries a MINE line and never feeds) and dies while armed.
		if spellId == nil then
			if inInst == true then
				if H.zbtVetoActive() then
					H.dbgDrop("BYPASS_INST_UNATTR", self._castToken, school)
				else
					H.dbgDrop("INST_UNATTR", self._castToken, school)
					return
				end
			elseif self:_autoContested(t) then
				H.dbgDrop("CONTESTED", self._castToken, school)
				return
			end
			-- Proc riders (mod.procRiders): guaranteed on-attack procs with
			-- no cast record. All sid claims failed — a school-matching
			-- wound riding a fresh melee anchor names itself. Emitted
			-- directly: it is a separate proc hit, not a duplicate report.
			local riderSid = self:_pickProcRider(t, school)
			if riderSid then
				local pipeIdR = self._rawPipeCount + 1
				self._rawPipeCount = pipeIdR
				self._rawPipe[pipeIdR] = amount
				H.emit("OUTGOING_DAMAGE_COMBAT", {
					timestamp = t,
					rawPipeId = pipeIdR,
					spellId = riderSid,
					amountSource = "UNIT_COMBAT_PROC",
					targetName = H.safeUnitName("target"),
					isCrit = isCrit,
					procClaim = true,
					schoolMask = (ZSBT.IsSafeNumber(school) and school) or nil,
				})
				return
			end
		end

		local schoolMask = (ZSBT.IsSafeNumber(school) and school) or nil
		H.auditNote("AUDMB school=%s crit=%s spellId=%s", H.dbgSafe(school), tostring(isCrit == true), H.dbgSafe(spellId))


		-- Merge window: multiple UNIT_COMBAT(target) hits can arrive per cast.
		-- Keep only the largest amount in a short window to avoid showing tiny
		-- proc/secondary values (the root cause of the "300-900 Shadow Bolt" bug).
		local token = tokenKey
		local targetName = H.safeUnitName("target")
		local bucket = self._bestOutgoingByToken[token]
		if not bucket then
			if not isCorroboratedHugeHit(self, restrict, t, amount, spellId or self._lastPlayerSpellId) then
				if dl >= 4 then
					H.ECPrint(("BIG_HIT_SUPPRESS src=UNIT_COMBAT_BEST_START token=%s spellId=%s amt=%s")
						:format(H.dbgSafe(self._castToken), H.dbgSafe(spellId), H.dbgSafe(amount)))
				end
				H.auditNote("AUDD reason=BUCKET_HUGE_SUPPRESS spellId=%s school=%s", H.dbgSafe(spellId), H.dbgSafe(schoolMask))
				return
			end
			bucket = {
				timestamp = t,
				token = token,
				spellId = spellId,
				_sidLearn = sidLearn,
				wandProven = wandProven,

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
				C_Timer.After(0.08, function()
					local _perf = ZSBT.Perf
					local _pt0 = _perf and _perf.on and _perf.t()
					self:_flushBestOutgoing(token)
					if _pt0 then _perf:done("ec.woundflush", _pt0) end
				end)
			else
				-- Fallback: emit immediately if timers are unavailable.
				self:_flushBestOutgoing(token)
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
				H.auditNote("AUDMSPLIT sid=%s bsid=%s", 
					H.dbgSafe(spellId), H.dbgSafe(bucket.spellId))
				H.emit("OUTGOING_DAMAGE_COMBAT", {
					timestamp = t,
					rawPipeId = pipeIdM,
					spellId = spellId,
					_sidLearn = sidLearn,
					wandProven = wandProven,
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
			if bucket.spellId and not self:_castSchoolOk(bucket.spellId, schoolMask) then
				local pipeIdM = self._rawPipeCount + 1
				self._rawPipeCount = pipeIdM
				self._rawPipe[pipeIdM] = amount
				H.emit("OUTGOING_DAMAGE_COMBAT", {
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
				H.auditNote("AUDMSPLIT sid=%s school=%s bschool=%s", 
					H.dbgSafe(spellId), H.dbgSafe(schoolMask), H.dbgSafe(bucket.schoolMask))
				H.emit("OUTGOING_DAMAGE_COMBAT", {
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
				bucket.targetGUID = safeTargetGUID("target") or bucket.targetGUID
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
	local t = H.now()
	if (t - self._lastCombatTextDamageAt) < H.DEDUP_WINDOW then
		local zI = ZSBT.ZBattleText
		if zI and zI.FileLog and ZSBT._ucDropTrace == true then
			zI:FileLog("INC_DROP reason=CT_DEDUP")
		end
		return
	end
	if unit == "player" and action == "WOUND" then
		if H.OutDbgLevel() >= 3 then
			if ZSBT.Addon and ZSBT.Addon.Print and (t - (Collector._dbgLastUnitCombatPlayerAt or 0)) > 0.25 then
				Collector._dbgLastUnitCombatPlayerAt = t
				H.ECPrint(("UNIT_COMBAT_PLAYER action=%s desc=%s amt=%s")
					:format(H.dbgSafe(action), H.dbgSafe(descriptor), H.dbgSafe(amount)))
			end
		end
	end
	if (t - self._lastCombatTextHealAt) < H.DEDUP_WINDOW then
		local zI2 = ZSBT.ZBattleText
		if zI2 and zI2.FileLog and ZSBT._ucDropTrace == true then
			zI2:FileLog("INC_DROP reason=HEAL_DEDUP")
		end
		return
	end

	local numAmount, amountText, secret = H.launderAmount(amount)

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
			local tNow = H.now()
			if not (self._lastPlayerHealthHealAt and (tNow - self._lastPlayerHealthHealAt) <= 0.30) then
				return
			end
		end
		-- Leech evidence (player heals): a readable self-heal is recorded
		-- so a wound of the SAME amount in the same moment proves a drain
		-- tick (Siphon Life / drain channels). The health-rise check above
		-- drops full-overheal drains, so a miss here is suppression, not
		-- absence — the picker's penalty must only ever fire on a HIT.
		if ZSBT.IsSafeNumber(numAmount) then
			local ph = self._playerHeals
			if not ph then ph = {} ; self._playerHeals = ph end
			local tH = H.now()
			while ph[1] and (tH - ph[1].at > 1 or #ph > 16) do table.remove(ph, 1) end
			ph[#ph + 1] = { at = tH, amount = numAmount }
		end
		-- Forever/secret-value clients: UNIT_COMBAT amounts arrive as secret
		-- values. Route the raw amount through the pipe so the display layer
		-- can SetText() it directly (same pattern as COMBAT_TEXT_HEAL).
		local healPipeId = self._rawPipeCount + 1
		self._rawPipeCount = healPipeId
		self._rawPipe[healPipeId] = amount
		H.emit("INCOMING_HEAL_COMBAT", {
			timestamp = H.now(),
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
			H.emit("FALL_DAMAGE", {
				timestamp = H.now(),
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
			self._lastUnitCombatPlayerDamageAt = H.now()
			local dmgPipeId = self._rawPipeCount + 1
			self._rawPipeCount = dmgPipeId
			self._rawPipe[dmgPipeId] = amount
			H.emit("INCOMING_DAMAGE", {
				timestamp = H.now(),
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

-- UNIT_AURA: our own periodic debuffs on an enemy are application
-- anchors for dots no cast can seed (trinket/enchant/set procs).
-- updateInfo is fully secret in combat on 12.x — never touch it.
-- Instead presence-POLL the known dot sid set with engine-side
-- APIs: FindAuraBySpellId does the sid compare + the HARMFUL|PLAYER
-- filter does the own-source proof, so nothing secret reaches Lua.
-- An absence->presence edge is the application instant.
auraSpellName = function(sid)
	if C_Spell and C_Spell.GetSpellName then
		local ok, n = pcall(C_Spell.GetSpellName, sid)
		if ok and ZSBT.IsSafeString and ZSBT.IsSafeString(n) and n ~= "" then return n end
	end
	return nil
end

local function auraPollCandidates(self)
	-- Rebuilt lazily: module dot ids + learned proc dots + gear sids
	-- whose Spellbook record parsed periodic.
	local now2 = now()
	if self._auraPollSids and self._auraPollBuiltAt
		and (now2 - self._auraPollBuiltAt) < 2.0 then
		return self._auraPollSids
	end
	local set = {}
	local ClassDB = ZSBT.ClassDB
	local mod = ClassDB and ClassDB.ActiveModule and ClassDB.ActiveModule() or nil
	if mod and type(mod.dots) == "table" then
		for _, e in ipairs(mod.dots) do
			if type(e) == "table" and type(e.ids) == "table" then
				for _, sid in ipairs(e.ids) do
					if type(sid) == "number" then
						set[sid] = (type(e.names) == "table" and e.names[1]) or true
					end
				end
			end
			-- Era modules are name-primary (ids omitted — ranked spell ids
			-- differ per rank): the declared name itself is the poll key.
			if type(e) == "table" and type(e.names) == "table"
				and type(e.names[1]) == "string"
				and (type(e.ids) ~= "table" or #e.ids == 0) then
				set[e.names[1]] = e.names[1]
			end
		end
	end
	local prof = ZSBT.db and ZSBT.db.profile
	if prof and type(prof.learnedProcDots) == "table" then
		for sid in pairs(prof.learnedProcDots) do
			if type(sid) == "number" then set[sid] = auraSpellName(sid) or true end
		end
	end
	local sb = ZSBT.Spellbook
	if sb and type(sb._gear) == "table" then
		for _, g in pairs(sb._gear) do
			local sid = type(g) == "table" and g.sid or nil
			if type(sid) == "number" then
				local rec = sb.Entry and sb:Entry(sid) or nil
				if rec and rec.role == "dot" then set[sid] = auraSpellName(sid) or true end
			end
		end
	end
	self._auraPollSids = set
	self._auraPollBuiltAt = now2
	return set
end

function Collector:handleUnitAura(unit, _updateInfo)
	-- _updateInfo is fully secret (isFullUpdate/addedAuras are secret
	-- booleans/tables in combat — reading either errors). Ignored.
	if type(unit) ~= "string" then return end
	if unit ~= "target" and unit:sub(1, 9) ~= "nameplate" then return end
	-- Per-unit poll throttle: UNIT_AURA churns many times/sec per nameplate
	-- on big pulls, each firing a full candidate-sid scan. Edges are
	-- state-compared (present vs seen), not event-driven, so coalescing to
	-- ~50ms per unit delays detection by at most 50ms and misses nothing.
	local tNow = now()
	local lastPoll = self._auraPollUnitAt
	if not lastPoll then lastPoll = {} ; self._auraPollUnitAt = lastPoll end
	local lp = lastPoll[unit]
	if lp and (tNow - lp) < 0.05 then return end
	lastPoll[unit] = tNow
	-- AuraUtil may be absent on 12.x builds — GetAuraDataBySpellName is the
	-- fallback; both compare engine-side so no secret field is ever read.
	local findById = AuraUtil and AuraUtil.FindAuraBySpellId or nil
	local findByName = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName or nil
	local sids = auraPollCandidates(self)
	if not sids then return end
	-- One-shot probe: proves the handler ran, how many sids are polled, and
	-- which aura APIs exist (a silent AuraUtil==nil was the failure suspect).
	if not self._auraPollLogged then
		self._auraPollLogged = true
		local n = 0
		for _ in pairs(sids) do n = n + 1 end
		local zbtA = ZSBT.ZBattleText
		if zbtA and zbtA.FileLog then
			zbtA:FileLog("AURA_POLL cands=%d unit=%s byId=%s byName=%s", n, tostring(unit), tostring(findById ~= nil), tostring(findByName ~= nil))
		end
		if zbtA and zbtA.Audit then
			zbtA:Audit("AURA_POLL cands=%d unit=%s byId=%s byName=%s", n, tostring(unit), tostring(findById ~= nil), tostring(findByName ~= nil))
		end
	end
	if not findById and not findByName then return end
	-- Seen-state keyed by unit GUID (mob identity survives token reuse);
	-- token itself is the fallback when GUID is unreadable.
	local key = nil
	if UnitGUID then
		local okG, g = pcall(UnitGUID, unit)
		if okG and ZSBT.IsSafeString and ZSBT.IsSafeString(g) then key = g end
	end
	if key == nil then key = unit end
	local seen = self._auraDotSeen
	if not seen then seen = {} ; self._auraDotSeen = seen end
	local us = seen[key]
	if not us then us = {} ; seen[key] = us end
	local t = now()
	local presentCount = 0
	for sid, name in pairs(sids) do
		local present, auraSid = false, nil
		if findById and type(sid) == "number" then
			local okP, a = pcall(findById, sid, unit, "HARMFUL|PLAYER")
			present = okP and a ~= nil or false
			if present then auraSid = sid end
		end
		if not present and findByName and type(name) == "string" then
			local okN, a2 = pcall(findByName, unit, name, "HARMFUL|PLAYER")
			present = okN and a2 ~= nil or false
			-- The returned AuraData carries the REAL rank sid for this
			-- client — era entries are name-primary precisely because the
			-- id isn't known at author time; the aura tells us. Fields are
			-- secret in combat (Camelot runs Midnight's restrictions): only
			-- a readable `false` from ShouldAurasBeSecret unlocks the read —
			-- presence itself needs no fields (the compare already ran
			-- engine-side).
			if present and type(a2) == "table" then
				local secret = true
				if C_Secrets and C_Secrets.ShouldAurasBeSecret then
					local okS, open = pcall(_secAurasOpen)
					secret = not (okS and open == true)
				else
					secret = false
				end
				if not secret and type(a2.spellId) == "number"
					and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(a2.spellId) then
					auraSid = a2.spellId
				end
			end
		end
		if present then presentCount = presentCount + 1 end
		-- Target-unit presence records name-keyed debuff sightings for
		-- the picker's era tiebreaker (sid-keyed reads cover ids only).
		if present and unit == "target" and type(name) == "string" then
			local nd = self._nameDebuffAt
			if not nd then nd = {} ; self._nameDebuffAt = nd end
			nd[name] = t
		end
		-- Presence edges seed anchors: sid-keyed candidates under their
		-- own id; name-keyed (era) candidates under the sid the aura
		-- itself reported, when readable — the client's true rank id.
		local anchorSid = (type(sid) == "number" and sid) or auraSid
		local seenKey = (type(sid) == "number" and sid) or ("n:" .. tostring(name))
		if present and not us[seenKey] then
			us[seenKey] = true
			if type(anchorSid) == "number" then
				seedDotApplicationOnUnit(self, anchorSid, unit, t)
			end
			local zbtS = ZSBT.ZBattleText
			if zbtS and zbtS.FileLog then
				zbtS:FileLog("AURA_SEED unit=%s key=%s sid=%s", tostring(unit), tostring(seenKey), tostring(anchorSid))
			end
			if zbtS and zbtS.Audit then
				zbtS:Audit("AURA_SEED unit=%s key=%s sid=%s", tostring(unit), tostring(seenKey), tostring(anchorSid))
			end
		elseif not present and us[seenKey] then
			us[seenKey] = nil
		end
	end
	-- Per-unit first-poll probe: present>0 on a unit carrying a known debuff
	-- proves the compare returns data; nameplate rows prove UNIT_AURA fires
	-- on nameplate tokens at all.
	if not us._probed then
		us._probed = true
		local zbtP = ZSBT.ZBattleText
		if zbtP and zbtP.FileLog then
			zbtP:FileLog("AURA_PROBE unit=%s present=%d", tostring(unit), presentCount)
		end
		if zbtP and zbtP.Audit then
			zbtP:Audit("AURA_PROBE unit=%s present=%d", tostring(unit), presentCount)
		end
	end
	-- Bound the map: dead mobs leave stale keys.
	local n = self._auraSeenCount or 0
	self._auraSeenCount = n + 1
	if self._auraSeenCount >= 200 then
		self._auraSeenCount = 0
		local k = 0
		for _ in pairs(seen) do k = k + 1 if k > 64 then wipe(seen) break end end
	end
end

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
			local _perf = ZSBT.Perf
			local _pt0 = _perf and _perf.on and _perf.t()
			if event == "UNIT_SPELLCAST_SUCCEEDED" then
				Collector:handleSpellcastSucceeded(...)
			elseif event == "UNIT_SPELLCAST_SENT" then
				Collector:handleSpellcastSent(...)
			elseif event == "UNIT_HEALTH" or event == "UNIT_HEALTH_FREQUENT" then
				Collector:handleUnitHealth(...)
			elseif event == "COMBAT_TEXT_UPDATE" then
				Collector:handleCombatTextUpdate(...)
			elseif event == "UNIT_COMBAT" then
				Collector:handleUnitCombat(...)
			elseif event == "UNIT_AURA" then
				Collector:handleUnitAura(...)
			elseif event == "PLAYER_EQUIPMENT_CHANGED" then
				-- Gear swap changes the effect-sid set — rescan lazily.
				if ZSBT.Spellbook then ZSBT.Spellbook._scanned = nil end
				-- A new wand can mean a new element: re-read the ranged
				-- slot's tooltip and clear the learned vote.
				self._wandSchool = readWandSchool()
				self._wandVotes = nil
			elseif event == "PLAYER_SWING" then
				Collector:handlePlayerSwing(...)
			elseif CHAT_OUTGOING_EVENTS[event] then
				local dl = OutDbgLevel()
				local msg = select(1, ...)
				local msgSafe = type(msg) == "string" and (not ZSBT.IsSafeString or ZSBT.IsSafeString(msg))
				local zc = ZSBT.ZBattleText
				if zc and zc.FileLog and ZSBT._ucDropTrace == true then
					if msgSafe then
						zc:FileLog("CHAT_OUT evt=%s msg=%s", tostring(event), tostring(msg:sub(1, 120)))
					else
						zc:FileLog("CHAT_OUT evt=%s msg=<unsafe>", tostring(event))
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
			if _pt0 then _perf:done("EC." .. tostring(event), _pt0) end
		end)
	end

	-- Blizzard 12.0 combat text pipeline: COMBAT_TEXT_UPDATE may not carry damage
	-- tokens in some environments, even though Blizzard is rendering damage.
	-- Probe the known entry points: record full arg signatures (count, type,
	-- secret status, safe previews) into a ring buffer for "/zsbt ctprobe".
	-- LAZY-INSTALLED on first "/zsbt ctprobe" — hooksecurefunc is permanent
	-- for the session, and ~140 always-on hooks on per-frame combat-text
	-- functions is debug overhead normal users must never pay.
	Collector._installCTProbe = function()
		if self._combatTextAddHooked or type(hooksecurefunc) ~= "function" then return end
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
					local okSt, sStripped = pcall(_secStripCodes, v)
					if okSt and type(sStripped) == "string" then s = sStripped end
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
		Collector._fallingFrame = (ZSBT.Perf and ZSBT.Perf.frame or CreateFrame)("ECFALL")
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
	-- UNIT_SPELLCAST_SENT (player only): cast→target binding — the
	-- press-time recipient joins SUCCEEDED via castGUID. pcall-guarded:
	-- not every client family exposes it.
	pcall(function() self._frame:RegisterEvent("UNIT_SPELLCAST_SENT") end)
	self._frame:RegisterEvent("UNIT_HEALTH")
	-- Wand element from the ranged-slot tooltip;
	-- nil when unreadable — the claimed-shot vote learns it instead.
	self._wandSchool = readWandSchool()
	pcall(function() self._frame:RegisterEvent("UNIT_HEALTH_FREQUENT") end)
	self._frame:RegisterEvent("COMBAT_TEXT_UPDATE")
	self._frame:RegisterEvent("UNIT_COMBAT")
	-- UNIT_AURA seeds dot-application anchors on target/nameplate debuffs
	-- (proc dots have no cast); PLAYER_EQUIPMENT_CHANGED invalidates the
	-- spellbook gear pass.
	self._frame:RegisterEvent("UNIT_AURA")
	self._frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
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
		-- v2 of dot learning: periods and tick amounts persisted before the
		-- learner-trust gate may encode misattributed rhythm (Corruption
		-- learned 1.994s/Immolate 1.694s off another dot's ticks, and
		-- learnedTickAmounts still bias scoring with no bound to catch
		-- them). Wipe both once — only teaching-grade claims rebuild them.
		if type(prof) == "table" and prof.learnedDotDataVer ~= 2 then
			prof.learnedDotPeriods = nil
			prof.learnedTickAmounts = nil
			prof.learnedDotDataVer = 2
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
		self._frame:UnregisterEvent("UNIT_AURA")
		self._frame:UnregisterEvent("PLAYER_EQUIPMENT_CHANGED")
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
	self._auraDotSeen = nil
	self._auraPollSids = nil
	self._auraPollBuiltAt = nil
	self._auraSeenCount = nil
	local zb = ZSBT.ZBattleText
	if zb and zb._healLineHook then
		zb._healLineHook = nil
	end
	self._enabled = false
	self._lastHealth = {}
	self._lastPlayerSpellName = nil
	self._lastPlayerSpellId = nil
end
