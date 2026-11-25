-- Classes/Registry.lua — Per-class combat module registry
--
-- Each Classes/<Class>.lua file calls ZSBT.ClassDB.Register(tag, module).
-- Event_Collector consults the ACTIVE class module (the player's class)
-- for class-specific combat logic instead of hardcoding per-class branches:
--
--   module.dots                = { { names={...}, ids={...}, school=N? }, ... }
--   module.hots                = { { names={...}, ids={...}, interval=N?, duration=N? }, ... }
--   module.channels            = { { names={...}, ids={...}, duration=N, tickMin=N }, ... }
--   module.petSchoolHit        = function(school, helpers) -> bool end
--   module.petSchoolHitRecent  = function(self, school, lastPlayerSpellId, helpers) -> bool end
--   module.onCast              = function(self, spellId, spellName, t) end
--   module.onMatchedPhysical   = function(self, spellId, t, amount) end
--   module.onPhysicalWound     = function(self, ctx) end          -- may emit; EC continues
--   module.onGuardianWound     = function(self, ctx) -> true|nil  -- true = handled, EC returns
--   module.resolvePetMelee     = function(self, helpers) -> spellId|nil
--   module.dotGuard            = function(entry, school, helpers) -> false|nil end
--
-- Spell identity is NAME-PRIMARY: CleanSpellName strips rank suffixes so a
-- single canonical name covers every rank and every client (Retail 686 vs
-- Forever 705 style ID drift). ids are kept as a fallback fast path only.

local ADDON_NAME, ZSBT = ...
if not ZSBT then return end

local ClassDB = {}
ZSBT.ClassDB = ClassDB

ClassDB._modules = {}
ClassDB._activeTag = nil
ClassDB._activeMod = nil

-- Client detection: World of Warcraft: Forever (codename "Camelot",
-- project 18) is a second game type in the Mainline family — modern API
-- surface but Classic+ content, so spell ids, talents, and guardian
-- semantics all differ from Retail. Same-name spell data would actively
-- mislead the modules, so Retail modules must not load there: Era
-- modules live in Classes/Era/<Class>.lua and opt in via
-- mod.client = "era". Early Forever betas reported project 1
-- (Mainline), so a false here means "not confirmed Forever" and the
-- Retail data set is the safer default.
function ClassDB.IsForever()
	return WOW_PROJECT_ID == (WOW_PROJECT_CAMELOT or 18)
end

function ClassDB.Register(tag, mod)
	if type(tag) ~= "string" or tag == "" or type(mod) ~= "table" then return end
	-- Modules are client-scoped: Era files declare mod.client = "era" and
	-- are dormant on Retail; everything else defaults to Retail and is
	-- dormant on Forever. Saves cross-client id drift poisoning every
	-- learned table.
	if (mod.client == "era") ~= ClassDB.IsForever() then return end
	ClassDB._modules[tag] = mod
end

function ClassDB.Get(tag)
	return ClassDB._modules[tag]
end

-- Player class tag, cached (class cannot change mid-session).
function ClassDB.PlayerTag()
	if ClassDB._activeTag ~= nil or ClassDB._activeChecked then
		return ClassDB._activeTag
	end
	ClassDB._activeChecked = true
	if UnitClass then
		local ok, _, tag = pcall(UnitClass, "player")
		if ok and type(tag) == "string" then
			ClassDB._activeTag = tag
		end
	end
	return ClassDB._activeTag
end

function ClassDB.ActiveModule()
	local tag = ClassDB.PlayerTag()
	if not tag then return nil end
	if ClassDB._activeMod == nil and ClassDB._activeModChecked ~= true then
		ClassDB._activeModChecked = true
		ClassDB._activeMod = ClassDB._modules[tag] or false
	end
	if ClassDB._activeMod == false then return nil end
	return ClassDB._activeMod
end

---------------------------------------------------------------------------
-- Shared helpers handed to modules (they cannot see Event_Collector locals)
---------------------------------------------------------------------------
local _helpers = nil
function ClassDB.Helpers()
	if _helpers then return _helpers end
	local isClassTag
	if type(_G.isPlayerClassTag) == "function" then
		isClassTag = _G.isPlayerClassTag
	end
	_helpers = {
		isClassTag = isClassTag,
		family = function()
			if not UnitCreatureFamily then return nil end
			local okF, fam = pcall(UnitCreatureFamily, "pet")
			if okF and type(fam) == "string" and fam ~= "" then
				return string.lower(fam)
			end
			return nil
		end,
		npcId = function(unit)
			if not UnitGUID then return nil end
			local okG, guid = pcall(UnitGUID, unit or "pet")
			if not okG or type(guid) ~= "string" or guid == "" then return nil end
			local _, _, _, _, _, id = strsplit("-", guid)
			local n = tonumber(id)
			if type(n) == "number" and n > 0 then return n end
			return nil
		end,
		safeNumber = function(v)
			return ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) == true
		end,
		cleanName = function(spellId)
			return ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or nil
		end,
	}
	return _helpers
end

---------------------------------------------------------------------------
-- Dot index build (lazy, per module)
---------------------------------------------------------------------------
local function buildDotIndex(mod)
	if mod._dotIndexBuilt then return end
	mod._dotIndexBuilt = true
	local names, ids = {}, {}
	for _, entry in ipairs(mod.dots or {}) do
		entry._canon = entry.names and entry.names[1] or nil
		for _, n in ipairs(entry.names or {}) do
			names[n] = entry
		end
		for _, id in ipairs(entry.ids or {}) do
			ids[id] = entry
		end
	end
	mod._dotNames = names
	mod._dotIds = ids
end

local function buildHotIndex(mod)
	if mod._hotIndexBuilt then return end
	mod._hotIndexBuilt = true
	local names, ids = {}, {}
	for _, entry in ipairs(mod.hots or {}) do
		entry._canon = entry.names and entry.names[1] or nil
		for _, n in ipairs(entry.names or {}) do
			names[n] = entry
		end
		for _, id in ipairs(entry.ids or {}) do
			ids[id] = entry
		end
	end
	mod._hotNames = names
	mod._hotIds = ids
end

local function buildChannelIndex(mod)
	if mod._chanIndexBuilt then return end
	mod._chanIndexBuilt = true
	local names, ids = {}, {}
	for _, ch in ipairs(mod.channels or {}) do
		for _, n in ipairs(ch.names or {}) do
			names[n] = ch
		end
		for _, id in ipairs(ch.ids or {}) do
			ids[id] = ch
		end
	end
	mod._chanNames = names
	mod._chanIds = ids
end

local function buildExcludeIndex(mod)
	if mod._exclIndexBuilt then return end
	mod._exclIndexBuilt = true
	local names = {}
	for _, n in ipairs(mod.exclude or {}) do
		names[n] = true
	end
	mod._exclNames = names
end

local function buildRangedIndex(mod)
	if mod._rangedIndexBuilt then return end
	mod._rangedIndexBuilt = true
	local names, ids = {}, {}
	for _, n in ipairs(mod.ranged or {}) do
		names[n] = true
	end
	for _, id in ipairs(mod.rangedIds or {}) do
		ids[id] = true
	end
	mod._rangedNames = names
	mod._rangedIds = ids
end

-- Module-declared ranged spells (mod.ranged = { names }, mod.rangedIds
-- = { ids }): a spell wound that produces RANGE_DAMAGE lines — wand
-- Shoot on era clients — should reach for a ranged line first at
-- pairing instead of letting any spell wound steal one.
function ClassDB.PreferRangedLine(spellId)
	if type(spellId) ~= "number" then return false end
	local mod = ClassDB.ActiveModule()
	if not mod then return false end
	if type(mod.ranged) ~= "table" and type(mod.rangedIds) ~= "table" then
		return false
	end
	buildRangedIndex(mod)
	if mod._rangedIds[spellId] == true then return true end
	local sn = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or nil
	if type(sn) == "string" and sn ~= "" then
		if sn:find("(", 1, true) then
			sn = (sn:gsub("%s*%(%s*[Rr]ank%s+%d+%s*%)%s*$", ""))
		end
		return mod._rangedNames[sn] == true
	end
	return false
end

-- Module-denied spells (mod.exclude = { names }): a name here can never
-- resolve to a dot/channel entry through ANY path — module, taught, or
-- spellbook-derived. Used for spells that parse as periodic but never
-- damage an enemy (Health Funnel drains the caster): the book fallback
-- would otherwise re-add what the module deliberately left out.
function ClassDB.ExcludedSpellId(spellId)
	if type(spellId) ~= "number" then return false end
	local mod = ClassDB.ActiveModule()
	if not mod or type(mod.exclude) ~= "table" then return false end
	buildExcludeIndex(mod)
	local sn = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or nil
	if type(sn) ~= "string" or sn == "" then return false end
	if sn:find("(", 1, true) then
		sn = (sn:gsub("%s*%(%s*[Rr]ank%s+%d+%s*%)%s*$", ""))
	end
	return mod._exclNames[sn] == true
end

---------------------------------------------------------------------------
-- Player-taught spells (drag-and-drop on the Class page). Stored per
-- character: db.char.classTaught[spellId] = { name, role, budget? }.
-- Roles: "dot" = periodic ticks named; "channel" = tick window opens on
-- cast; "cast" = multi-hit naming budget. Taught entries bypass the
-- module tables entirely so they work even when a class has no module
-- or the module predates the spell. Reads are hot-path safe: a miss
-- allocates nothing.
---------------------------------------------------------------------------
local function taughtEntry(spellId)
	if type(spellId) ~= "number" then return nil end
	local char = ZSBT.db and ZSBT.db.char
	local t = char and char.classTaught
	local e = t and t[spellId]
	if type(e) == "table" and type(e.role) == "string" then return e end
	return nil
end

-- Best-effort role inference from the spell's description text — the API
-- exposes no periodic/channel flags on a spellId, so the localized
-- tooltip string is the only signal. Heuristic: the Class page keeps
-- manual overrides. Channeled wins over periodic (Mind Flay-style spells
-- describe both; the channel window is the right mechanism for them).
function ClassDB.InferRole(spellId)
	local desc
	if C_Spell and C_Spell.GetSpellDescription then
		local ok, d = pcall(C_Spell.GetSpellDescription, spellId)
		if ok and type(d) == "string" then desc = d end
	end
	if type(desc) ~= "string" or desc == "" then return "cast" end
	-- Shared parser lives in Classes/Spellbook.lua so the teach UI and
	-- the book-derived layer classify descriptions identically.
	local sb = ZSBT.Spellbook
	local parsed = sb and sb.ParseDesc and sb.ParseDesc(desc, spellId)
	return (parsed and parsed.role) or "cast"
end

function ClassDB.TeachSpell(spellId, name, role, budget)
	if type(spellId) ~= "number" or spellId <= 0 then return false end
	if role == "auto" then role = ClassDB.InferRole(spellId) end
	if role ~= "dot" and role ~= "channel" and role ~= "cast" then return false end
	local char = ZSBT.db and ZSBT.db.char
	if type(char) ~= "table" then return false end
	char.classTaught = char.classTaught or {}
	char.classTaught[spellId] = {
		name = (type(name) == "string" and name ~= "") and name or tostring(spellId),
		role = role,
		budget = (role == "cast" and tonumber(budget)) or nil,
	}
	return true
end

function ClassDB.Unteach(spellId)
	local char = ZSBT.db and ZSBT.db.char
	local t = char and char.classTaught
	if type(t) == "table" then t[spellId] = nil end
end

-- Structured view of everything the active module ships with: dots,
-- channels, cast budgets, guardian summon triggers, guardian spellbook.
-- Modules expose the last two as mod.guardianSummons/mod.guardianSpells
-- (aliases to their file-local tables). UI-only: allocates freely.
function ClassDB.KnowledgeList()
	local out = {}
	local mod = ClassDB.ActiveModule()
	if not mod then return out end
	local clean = ZSBT.CleanSpellName
	local function nameOf(sid)
		local nm = clean and clean(sid)
		return (type(nm) == "string" and nm ~= "") and nm or tostring(sid)
	end
	-- School masks for the knowledge list's color coding: module tables
	-- declare them where known; for plain casts/summons the spellbook
	-- layer's parsed masks are the fallback (nil = neutral text).
	local function sidSchool(sid)
		local sb = ZSBT.Spellbook
		local e = sb and sb.Entry and sb:Entry(sid)
		return e and e.masks and e.masks[1] or nil
	end
	-- mod.bookScopedKnowledge: the knowledge list only shows module rows
	-- whose spell actually exists in the player's CURRENT book. On era/
	-- Forever the module table is a superset of any level's real kit —
	-- book-scoping makes the pane show the level-appropriate baseline and
	-- grow as new ranks/spells are learned. No book API = show all.
	local bookScoped = mod.bookScopedKnowledge == true
	local sbBook = ZSBT.Spellbook
	local function bookHasNames(names)
		if not bookScoped or not (sbBook and sbBook.IdForName) then return true end
		for _, n in ipairs(names or {}) do
			if sbBook:IdForName(n) ~= nil then return true end
		end
		return false
	end
	local function bookHasSid(sid)
		if not bookScoped or not (sbBook and sbBook.Entry) then return true end
		return sbBook:Entry(sid) ~= nil
	end
	for _, e in ipairs(mod.dots or {}) do
		if bookHasNames(e.names) then
			out[#out + 1] = {
				kind = "DoT",
				name = (e.names and e.names[1]) or "?",
				ids = e.ids,
				school = e.school,
				extra = type(e.school) == "number" and ("school " .. e.school) or nil,
			}
		end
	end
	for _, e in ipairs(mod.channels or {}) do
		if bookHasNames(e.names) then
			out[#out + 1] = {
				kind = "Channel",
				name = (e.names and e.names[1]) or "?",
				ids = e.ids,
				school = e.school,
				extra = type(e.duration) == "number" and (e.duration .. "s") or nil,
			}
		end
	end
	for sid, budget in pairs(mod.castBudget or {}) do
		if bookHasSid(sid) then
			out[#out + 1] = {
				kind = "Cast",
				name = nameOf(sid),
				ids = { sid },
				school = sidSchool(sid),
				extra = "x" .. tostring(budget),
			}
		end
	end
	for sid, wins in pairs(mod.guardianSummons or {}) do
		if bookHasSid(sid) then
			local groups = {}
			for _, g in ipairs(wins) do groups[#groups + 1] = tostring(g.group) end
			out[#out + 1] = {
				kind = "Summon",
				name = nameOf(sid),
				ids = { sid },
				school = sidSchool(sid),
				extra = table.concat(groups, "/"),
			}
		end
	end
	for group, spells in pairs(mod.guardianSpells or {}) do
		for _, sp in ipairs(spells) do
			out[#out + 1] = {
				kind = "Guardian",
				name = nameOf(sp.sid),
				ids = { sp.sid },
				school = sp.school,
				extra = tostring(group) .. "/sch" .. tostring(sp.school),
			}
		end
	end
	-- Next-swing strikes: one row per canonical name listing every
	-- declared rank; any rank in the book scopes the whole name in.
	if type(mod.nextSwing) == "table" then
		local byName, inBook = {}, {}
		for sid in pairs(mod.nextSwing) do
			local nm = nameOf(sid)
			byName[nm] = byName[nm] or {}
			byName[nm][#byName[nm] + 1] = sid
			if bookHasSid(sid) then inBook[nm] = true end
		end
		for nm, ids in pairs(byName) do
			if inBook[nm] then
				table.sort(ids)
				out[#out + 1] = { kind = "NextSwing", name = nm, ids = ids }
			end
		end
	end
	-- Ranged kit: name-primary rows (era modules carry name lists).
	if type(mod.ranged) == "table" then
		for _, n in ipairs(mod.ranged) do
			if bookHasNames({ n }) then
				out[#out + 1] = { kind = "Ranged", name = n }
			end
		end
	end
	-- Denied casts (no enemy damage — log-verified or mechanical).
	if type(mod.exclude) == "table" then
		for _, n in ipairs(mod.exclude) do
			if bookHasNames({ n }) then
				out[#out + 1] = { kind = "Exclude", name = n }
			end
		end
	end
	-- Pinned per-sid facts that correct client/tooltip data (school
	-- re-mapping like Camelot's physical Thunder Clap).
	if type(mod.spellFacts) == "table" then
		for sid, facts in pairs(mod.spellFacts) do
			if bookHasSid(sid) and type(facts) == "table" then
				local bits = {}
				if type(facts.school) == "number" then bits[#bits + 1] = "sch" .. facts.school end
				if facts.nextSwing == true then bits[#bits + 1] = "nextSwing" end
				out[#out + 1] = {
					kind = "Fact", name = nameOf(sid), ids = { sid },
					school = facts.school,
					extra = table.concat(bits, " "),
				}
			end
		end
	end
	table.sort(out, function(a, b)
		if a.kind ~= b.kind then return a.kind < b.kind end
		return tostring(a.name) < tostring(b.name)
	end)
	return out
end

-- Is this school mask inside the damage kit? The effective whitelist
-- is the module's mod.schools UNION the spellbook-derived masks — the
-- book only adds masks for spells the player currently knows, so it can
-- widen the set to a new spec's kit but never invent a school the class
-- doesn't have. Neither table present = "no whitelist", everything
-- passes. An unverifiable (secret or non-numeric) mask also passes —
-- the veto only fires on certainty.
function ClassDB.SchoolAllowed(schoolMask)
	local mod = ClassDB.ActiveModule()
	-- Era wands cover the whole school space — a module can declare
	-- schoolsAny to say no foreign-school exclusion exists at all.
	if mod and mod.schoolsAny == true then return true end
	local modSet = mod and type(mod.schools) == "table" and mod.schools or nil
	local sb = ZSBT.Spellbook
	local derived = sb and sb.Masks and sb:Masks() or nil
	if modSet == nil and (derived == nil or next(derived) == nil) then
		return true
	end
	if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(schoolMask)) then return true end
	if modSet and modSet[schoolMask] == true then return true end
	if derived and derived[schoolMask] == true then return true end
	return false
end

-- Does the active module already know this spellId? Returns a short
-- kind string ("dot"/"channel"/"cast"/"summon"/"guardian") so the teach
-- UI can flag a redundant drop. Name check included so a cast-id
-- different from the table id still matches its dot/channel entry.
function ClassDB.KnowsSpell(spellId)
	if type(spellId) ~= "number" then return nil end
	local mod = ClassDB.ActiveModule()
	if not mod then return nil end
	local sn = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or nil
	for _, e in ipairs(mod.dots or {}) do
		for _, id in ipairs(e.ids or {}) do
			if id == spellId then return "dot" end
		end
		if type(sn) == "string" then
			for _, n in ipairs(e.names or {}) do
				if n == sn then return "dot" end
			end
		end
	end
	for _, e in ipairs(mod.channels or {}) do
		for _, id in ipairs(e.ids or {}) do
			if id == spellId then return "channel" end
		end
		if type(sn) == "string" then
			for _, n in ipairs(e.names or {}) do
				if n == sn then return "channel" end
			end
		end
	end
	if mod.castBudget and mod.castBudget[spellId] then return "cast" end
	if mod.guardianSummons and mod.guardianSummons[spellId] then return "summon" end
	for _, spells in pairs(mod.guardianSpells or {}) do
		for _, sp in ipairs(spells) do
			if sp.sid == spellId then return "guardian" end
		end
	end
	return nil
end

-- Sorted list for the Class page UI (allocates; UI-only, never hot path).
function ClassDB.TaughtList()
	local out = {}
	local char = ZSBT.db and ZSBT.db.char
	local t = char and char.classTaught
	if type(t) == "table" then
		for sid, e in pairs(t) do
			if type(e) == "table" then
				out[#out + 1] = { sid = sid, name = e.name, role = e.role, budget = e.budget }
			end
		end
	end
	table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
	return out
end

-- Resolve a spellId to a dot entry: name-primary (rank/client agnostic),
-- id-set as fallback when the name cannot be resolved.
function ClassDB.DotEntry(spellId)
	if type(spellId) ~= "number" then return nil end
	if ClassDB.ExcludedSpellId(spellId) then return nil end
	local te = taughtEntry(spellId)
	if te and te.role == "dot" then
		te._dotEntry = te._dotEntry or {
			names = { te.name },
			_canon = te.name,
			ids = { spellId },
			school = te.school,
			_taught = true,
		}
		return te._dotEntry
	end
	local mod = ClassDB.ActiveModule()
	if mod and mod.dots then
		buildDotIndex(mod)
		local sn = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or nil
		if type(sn) == "string" and sn ~= "" then
			-- Era/Forever ranks can arrive as "Corruption (Rank 4)" —
			-- all ranks of a spell share one module entry.
			if sn:find("(", 1, true) then
				sn = (sn:gsub("%s*%(%s*[Rr]ank%s+%d+%s*%)%s*$", ""))
			end
			local e = mod._dotNames[sn]
			if e then return e end
		end
		local e = mod._dotIds[spellId]
		if e then return e end
	end
	-- Spellbook-derived fallback: the spell is in the player's current
	-- book and its description parsed as periodic, so seed it like a
	-- module dot even though no table lists it yet.
	local sb = ZSBT.Spellbook
	local rec = sb and sb.Entry and sb:Entry(spellId)
	if rec and rec.role == "dot" then
		rec._dotEntry = rec._dotEntry or {
			names = { rec.name or tostring(spellId) },
			_canon = rec.name,
			ids = { spellId },
			school = rec.masks and rec.masks[1] or nil,
			interval = rec.interval,
			_derived = true,
		}
		return rec._dotEntry
	end
	-- Learned-proc fallback: UNIT_AURA observed our own periodic debuff
	-- land on an enemy (trinket/enchant/set procs — no class cast to
	-- declare them), and the binding was persisted to the profile.
	-- Same entry shape; survives sessions like learnedSpellSchools.
	local prof = ZSBT.db and ZSBT.db.profile
	local ld = prof and prof.learnedProcDots and prof.learnedProcDots[spellId]
	if type(ld) == "table" then
		ClassDB._learnedDotEntry = ClassDB._learnedDotEntry or {}
		local e = ClassDB._learnedDotEntry[spellId]
		if not e or e._ld ~= ld then
			e = {
				names = { ld.name or tostring(spellId) },
				_canon = ld.name,
				ids = { spellId },
				school = ld.school,
				interval = ld.interval,
				_learned = true,
				_ld = ld,
			}
			ClassDB._learnedDotEntry[spellId] = e
		end
		return e
	end
	return nil
end

function ClassDB.IsDotSpell(spellId)
	return ClassDB.DotEntry(spellId) ~= nil
end

-- Resolve a spellId to a heal-over-time entry (module-declared only:
-- hots are module data, no taught/spellbook fallback — outgoing heal
-- attribution needs deliberate cadence/duration data, not guesses).
function ClassDB.HotEntry(spellId)
	if type(spellId) ~= "number" then return nil end
	local mod = ClassDB.ActiveModule()
	if not mod or type(mod.hots) ~= "table" then return nil end
	buildHotIndex(mod)
	local sn = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or nil
	if type(sn) == "string" and sn ~= "" then
		if sn:find("(", 1, true) then
			sn = (sn:gsub("%s*%(%s*[Rr]ank%s+%d+%s*%)%s*$", ""))
		end
		local e = mod._hotNames[sn]
		if e then return e end
	end
	return mod._hotIds[spellId]
end

-- Known-school verdict for a cast claim: does a pre-combat source pin
-- this spellId to a school that fits the wound's mask? Sources, in
-- order: module dot/channel declarations, then the spellbook scan's
-- derived masks. The book parsed descriptions at login while the text
-- was still readable, so its masks are plain numbers that stay
-- non-secret during combat — exactly when SpellFacts goes blind.
-- Returns true/false when a verdict exists, nil when nothing is known
-- (caller stays permissive/learned). Chaos (127) accepts the composite
-- masks 124/126 the client reports on wounds.
function ClassDB.DeclaredSchoolFits(spellId, school)
	if type(spellId) ~= "number" or type(school) ~= "number" then return nil end
	if ZSBT.IsSafeNumber
		and (not ZSBT.IsSafeNumber(spellId) or not ZSBT.IsSafeNumber(school)) then
		return nil
	end
	local e = ClassDB.DotEntry(spellId)
	local decl = e and e.school or nil
	if decl == nil then
		local c = ClassDB.ChannelMatch(spellId)
		decl = c and c.school or nil
	end
	if decl == nil then
		local f = ClassDB.SpellFactOverride(spellId)
		decl = f and f.school or nil
	end
	if decl == nil then
		local sb = ZSBT.Spellbook
		local rec = sb and sb.Entry and sb:Entry(spellId)
		decl = rec and rec.masks or nil
	end
	if type(decl) == "table" then
		if decl[school] == true then return true end
		local has127 = decl[127] == true
		for _, m in ipairs(decl) do
			if m == school then return true end
			if m == 127 then has127 = true end
		end
		return has127 and (school == 124 or school == 126)
	end
	if type(decl) == "number" then
		if decl == school then return true end
		return decl == 127 and (school == 124 or school == 126)
	end
	return nil
end

-- mod.spellFacts[spellId] = { damages = bool, school = N }: explicit
-- spell facts for tooltips the SpellFacts parser can't read (proc
-- damage with non-standard description text). SpellFacts consults this
-- after its own parse so overrides also repair damages=false verdicts.
function ClassDB.SpellFactOverride(spellId)
	local mod = ClassDB.ActiveModule()
	if mod and type(mod.spellFacts) == "table" and type(spellId) == "number" then
		return mod.spellFacts[spellId]
	end
	return nil
end

-- Guaranteed on-attack procs lacking a cast record (mod.procRiders list
-- of { sid, school, minGap }): the collector may name a same-school wound
-- when a melee weapon attack is anchored and uncontested. nil = none.
function ClassDB.ProcRiders()
	local mod = ClassDB.ActiveModule()
	if not mod or type(mod.procRiders) ~= "table" then return nil end
	return mod.procRiders
end

-- Per-pet-cast claim budget (mod.petCastBudget[spellId]): how many hits
-- one recorded pet cast may claim. Modules declare single-target pet
-- nukes at 1 so strays can't ride the cast's window; nil = default cap.
function ClassDB.PetCastBudget(spellId)
	local mod = ClassDB.ActiveModule()
	if not mod or type(mod.petCastBudget) ~= "table" then return nil end
	return mod.petCastBudget[spellId]
end

-- Player-cast records whose legitimate hits are pet-sourced (cls=pet
-- lines): Kill Command's strike, Bloodshed's bleed. Pet-evidence
-- vetoes must never touch them — their real hits look identical to
-- pet steals at wound level; the flight gate owns theft for these.
function ClassDB.PetExecuted(spellId)
	local mod = ClassDB.ActiveModule()
	if not mod or type(mod.petExecuted) ~= "table" then return nil end
	return mod.petExecuted[spellId] == true or nil
end

-- Next-swing strikes (Heroic Strike, Cleave on Camelot): the queued
-- cast emits an EMPTY damage report at press time — the empowered
-- swing cannot land at press time by definition, so a wound carrying
-- a nextSwing sid at the cast instant is a phantom, never the hit.
function ClassDB.NextSwing(spellId)
	local mod = ClassDB.ActiveModule()
	if not mod or type(mod.nextSwing) ~= "table" then return nil end
	return mod.nextSwing[spellId] == true or nil
end

function ClassDB.ChannelMatch(spellId)
	if type(spellId) ~= "number" then return nil end
	if ClassDB.ExcludedSpellId(spellId) then return nil end
	local te = taughtEntry(spellId)
	if te and te.role == "channel" then
		te._chan = te._chan or {
			names = { te.name },
			duration = tonumber(te.duration) or 8,
			tickMin = tonumber(te.tickMin) or 0.4,
			_taught = true,
		}
		return te._chan
	end
	local mod = ClassDB.ActiveModule()
	if mod and mod.channels then
		buildChannelIndex(mod)
		local sn = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or nil
		if type(sn) == "string" and sn ~= "" then
			if sn:find("(", 1, true) then
				sn = (sn:gsub("%s*%(%s*[Rr]ank%s+%d+%s*%)%s*$", ""))
			end
			local c = mod._chanNames[sn]
			if c then return c end
		end
		local c = mod._chanIds[spellId]
		if c then return c end
	end
	-- Spellbook-derived fallback, same as DotEntry: a spell in the
	-- current book that parses as channeled opens a tick window even
	-- without a module entry. Duration comes from castTime (channel
	-- spells report it), else the taught-entry defaults.
	local sb = ZSBT.Spellbook
	local rec = sb and sb.Entry and sb:Entry(spellId)
	if rec and rec.role == "channel" then
		if not rec._chan then
			-- Derived masks become a set so the tick-claim school check
			-- accepts every variant the description resolved.
			local mset
			if type(rec.masks) == "table" then
				mset = {}
				for _, m in ipairs(rec.masks) do mset[m] = true end
			end
			rec._chan = {
				names = { rec.name or tostring(spellId) },
				duration = tonumber(rec.duration) or 8,
				tickMin = tonumber(rec.tickMin) or 0.4,
				school = mset,
				_derived = true,
			}
		end
		return rec._chan
	end
	return nil
end

---------------------------------------------------------------------------
-- Hook dispatch (all nil-safe)
---------------------------------------------------------------------------
-- Module functions must never kill a wound/cast path: a throwing hook is
-- logged (throttled) and treated as absent. Callers keep their nil-checks.
local _hookErrAt = 0
local function safeHook(fnName, fn, ...)
	local ok, r = pcall(fn, ...)
	if ok == true then return r end
	local t = GetTime and GetTime() or 0
	if t - _hookErrAt >= 5 then
		_hookErrAt = t
		local zbt = ZSBT.ZBattleText
		if zbt and zbt.FileLog then
			zbt:FileLog(("HOOKERR fn=%s err=%s"):format(fnName, tostring(r)))
		end
	end
	return nil
end

function ClassDB.OnPlayerCast(self, spellId, spellName, t)
	local mod = ClassDB.ActiveModule()
	if mod and mod.onCast then
		safeHook("onCast", mod.onCast, self, spellId, spellName, t)
	end
	-- Generic channel seed: any module-declared or taught channel opens
	-- its tick window on cast. The registry owns this seed — module-side
	-- seeds lacked startedAt, which left the channel invisible to the
	-- cadence-disambig pool. +0.4 grace lets the final tick land.
	local ch = ClassDB.ChannelMatch(spellId)
	if ch then
		self._channel = {
			startedAt = t,
			untilAt = t + (ch.duration or 6.0) + 0.4,
			lastTickAt = 0,
			spellId = spellId,
			tickMin = ch.tickMin or 0.12,
			interval = ch.interval,
			school = ch.school,
		}
	end
end

function ClassDB.OnMatchedPhysical(self, spellId, t, amount)
	local mod = ClassDB.ActiveModule()
	if mod and mod.onMatchedPhysical then
		safeHook("onMatchedPhysical", mod.onMatchedPhysical, self, spellId, t, amount)
	end
end

function ClassDB.OnPhysicalWound(self, ctx)
	local mod = ClassDB.ActiveModule()
	if mod and mod.onPhysicalWound then
		safeHook("onPhysicalWound", mod.onPhysicalWound, self, ctx)
	end
end

function ClassDB.OnGuardianWound(self, ctx)
	local mod = ClassDB.ActiveModule()
	if mod and mod.onGuardianWound then
		return safeHook("onGuardianWound", mod.onGuardianWound, self, ctx) == true
	end
	return false
end

function ClassDB.PetSchoolHit(school)
	local mod = ClassDB.ActiveModule()
	if mod and mod.petSchoolHit then
		return safeHook("petSchoolHit", mod.petSchoolHit, school, ClassDB.Helpers()) == true
	end
	return false
end

-- Pet-side counterpart to SchoolAllowed: false ONLY when the school is
-- provably impossible for any of the class's pets/guardians — used to
-- strip a wrongly pet-routed wound (a foreign hit that consumed a
-- MY_PET palette line or claimed a pet cast via an unknown-school
-- window). nil/true = can't disprove it, allow.
function ClassDB.PetSchoolAllowed(school)
	local mod = ClassDB.ActiveModule()
	if mod and mod.petSchoolAllowed then
		return safeHook("petSchoolAllowed", mod.petSchoolAllowed, school, ClassDB.Helpers())
	end
	return nil
end

function ClassDB.PetSchoolHitRecent(self, school, lastPlayerSpellId)
	local mod = ClassDB.ActiveModule()
	if mod and mod.petSchoolHitRecent then
		return safeHook("petSchoolHitRecent", mod.petSchoolHitRecent, self, school, lastPlayerSpellId, ClassDB.Helpers()) == true
	end
	return false
end

-- Physical pet damage (school 1) can't live in petSchoolHit: that signature
-- also gates restrict bypasses, where treating melee as pet would leak
-- foreign swings. This hook is consulted ONLY by the pet-fallback emit.
function ClassDB.PetPhysicalHit(school)
	local mod = ClassDB.ActiveModule()
	if mod and mod.petPhysicalHit then
		return safeHook("petPhysicalHit", mod.petPhysicalHit, school, ClassDB.Helpers()) == true
	end
	return false
end

-- True when the class can never produce auto-attack damage worth showing
-- (warlock/mage/priest: every school-1 hit is pet melee or foreign). The
-- collector treats a veto like "no player swing explains this" — hits
-- route to pet-physical or drop instead of wearing your auto-attack.
-- Line kinds an auto-attack candidate may claim (nil = default
-- melee+ranged). Hunter returns {ranged=true}: its auto-shots produce
-- RANGE_DAMAGE lines while pet melee produces SWING_DAMAGE, so the
-- restriction keeps auto claims from eating pet-swing lines.
function ClassDB.AutoLineKinds()
	local mod = ClassDB.ActiveModule()
	if mod and mod.autoLineKinds then
		return safeHook("autoLineKinds", mod.autoLineKinds, ClassDB.Helpers())
	end
	return nil
end

-- Class-decided swing evidence for a school-1 hit at time t:
-- true = player's swing explains it (auto), false = it isn't the
-- player's swing (pet route), nil = fall back to default behavior.
function ClassDB.SwingEvidence(self, t)
	local mod = ClassDB.ActiveModule()
	if mod and mod.swingEvidence then
		return safeHook("swingEvidence", mod.swingEvidence, self, t, ClassDB.Helpers())
	end
	return nil
end

function ClassDB.VetoAuto()
	local mod = ClassDB.ActiveModule()
	if mod and mod.vetoAuto then
		return safeHook("vetoAuto", mod.vetoAuto, ClassDB.Helpers()) == true
	end
	return false
end

-- Names an unattributed pet hit from class knowledge: guardian activity
-- tracked from the player's summon casts + a unique school→spell map.
-- Guardian casts are invisible to UNIT_SPELLCAST_SUCCEEDED, so this is
-- the only way Wild Imp bolts etc. can be named. Returns nil when
-- ambiguous — generic pet display beats a wrong name.
function ClassDB.ResolvePetSpellId(self, school, t)
	local mod = ClassDB.ActiveModule()
	if mod and mod.resolvePetSpellId then
		return safeHook("resolvePetSpellId", mod.resolvePetSpellId, self, school, t, ClassDB.Helpers())
	end
	return nil
end

-- Names a physical (school-1) pet hit that produced no cast record.
-- Warlock uses this to display verified pet melee as "Auto Attack" —
-- the hit still must claim a MY_PET line first, so the name can only
-- land on damage the combat-log palette already proved was a pet's.
function ClassDB.ResolvePetMelee(self)
	local mod = ClassDB.ActiveModule()
	if mod and mod.resolvePetMelee then
		return safeHook("resolvePetMelee", mod.resolvePetMelee, self, ClassDB.Helpers())
	end
	return nil
end

-- Per-cast-instance naming budget for the recency-stamp paths: how many
-- hits one cast of spellId may name. Class knowledge — AoE/burst spells
-- (Implosion) claim many, single-target nukes default to 1. nil = default.
function ClassDB.CastBudget(spellId)
	local te = taughtEntry(spellId)
	if te and te.role == "cast" then
		local b = tonumber(te.budget)
		if b and b >= 1 then return math.floor(b) end
		return 1
	end
	local mod = ClassDB.ActiveModule()
	if mod and mod.castBudget then
		return mod.castBudget[spellId]
	end
	return nil
end

-- Returns false when the module vetoes this dot attribution (e.g. warlock
-- Imp fire hits are pet damage, never DoT ticks). nil/true = allowed.
function ClassDB.DotGuard(entry, school)
	local mod = ClassDB.ActiveModule()
	if mod and mod.dotGuard then
		return safeHook("dotGuard", mod.dotGuard, entry, school, ClassDB.Helpers())
	end
	return nil
end

-- Era multi-dot disambiguation: when the module declares
-- mod.dotCadenceDisambig, unattributed periodic wounds are evaluated
-- against EVERY active same-school dot (debuff check + tighter tick-
-- cadence prediction) instead of blindly naming the most recent cast.
-- Retail modules leave this unset: single-most-recent behavior stays.
-- AoE applicator casts (Primal Wrath -> Rip): the cast id is not a dot
-- but applies one to every enemy in range. Returns a list of applied
-- dot sids for the collector to seed application anchors with.
function ClassDB.DotApplicators(spellId)
	local mod = ClassDB.ActiveModule()
	if mod and type(mod.dotApplicators) == "table" then
		return mod.dotApplicators[spellId]
	end
	return nil
end

function ClassDB.DotCadenceDisambig()
	local mod = ClassDB.ActiveModule()
	if mod ~= nil then return mod.dotCadenceDisambig == true end
	-- Module-less era fallback: the spellbook already derives each known
	-- spell's role/school/interval, so a class with no era module still
	-- runs the disambiguation engine on the book alone — modules only
	-- add what tooltips can't express. Retail never enters this path.
	if not ClassDB.IsForever() then return false end
	local sb = ZSBT.Spellbook
	return sb ~= nil and sb.HasPeriodic ~= nil and sb:HasPeriodic() == true
end

-- Which class-module UI toggles apply to this class. Modules declare
-- mod.toggles = { key = true }; the Class page and quick-bar menu only
-- render toggles the active module supports, so e.g. a warrior never
-- sees "Show pet melee hits". Unknown/absent = unsupported.
function ClassDB.SupportsToggle(key)
	local mod = ClassDB.ActiveModule()
	return mod ~= nil and mod.toggles ~= nil and mod.toggles[key] == true
end

-- One-time load confirmation: prints the resolved class tag and whether a
-- module was found, so "did my class module load?" is answerable in chat.
local _classCheckFrame = ((ZSBT.Perf and ZSBT.Perf.frame) or CreateFrame)("CLASS")
if _classCheckFrame then
	_classCheckFrame:RegisterEvent("PLAYER_LOGIN")
	_classCheckFrame:SetScript("OnEvent", function()
		local tag = ClassDB.PlayerTag()
		local mod = ClassDB.ActiveModule()
		local msg = ("[ZSBT] Class module: %s -> %s")
			:format(tostring(tag or "?"), mod and "loaded" or "none (no module for this class)")
		if ZSBT.Addon and ZSBT.Addon.Print then
			ZSBT.Addon:Print(msg)
		else
			print(msg)
		end
	end)
end

return ClassDB
