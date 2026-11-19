-- Classes/Registry.lua — Per-class combat module registry
--
-- Each Classes/<Class>.lua file calls ZSBT.ClassDB.Register(tag, module).
-- Event_Collector consults the ACTIVE class module (the player's class)
-- for class-specific combat logic instead of hardcoding per-class branches:
--
--   module.dots                = { { names={...}, ids={...}, school=N? }, ... }
--   module.channels            = { { names={...}, ids={...}, duration=N, tickMin=N }, ... }
--   module.petSchoolHit        = function(school, helpers) -> bool end
--   module.petSchoolHitRecent  = function(self, school, lastPlayerSpellId, helpers) -> bool end
--   module.onCast              = function(self, spellId, spellName, t) end
--   module.onMatchedPhysical   = function(self, spellId, t, amount) end
--   module.onPhysicalWound     = function(self, ctx) end          -- may emit; EC continues
--   module.onGuardianWound     = function(self, ctx) -> true|nil  -- true = handled, EC returns
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

function ClassDB.Register(tag, mod)
	if type(tag) ~= "string" or tag == "" or type(mod) ~= "table" then return end
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

-- Resolve a spellId to a dot entry: name-primary (rank/client agnostic),
-- id-set as fallback when the name cannot be resolved.
function ClassDB.DotEntry(spellId)
	if type(spellId) ~= "number" then return nil end
	local mod = ClassDB.ActiveModule()
	if not mod or not mod.dots then return nil end
	buildDotIndex(mod)
	local sn = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or nil
	if type(sn) == "string" and sn ~= "" then
		local e = mod._dotNames[sn]
		if e then return e end
	end
	return mod._dotIds[spellId]
end

function ClassDB.IsDotSpell(spellId)
	return ClassDB.DotEntry(spellId) ~= nil
end

function ClassDB.ChannelMatch(spellId)
	if type(spellId) ~= "number" then return nil end
	local mod = ClassDB.ActiveModule()
	if not mod or not mod.channels then return nil end
	buildChannelIndex(mod)
	local sn = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or nil
	if type(sn) == "string" and sn ~= "" then
		local c = mod._chanNames[sn]
		if c then return c end
	end
	return mod._chanIds[spellId]
end

---------------------------------------------------------------------------
-- Hook dispatch (all nil-safe)
---------------------------------------------------------------------------
function ClassDB.OnPlayerCast(self, spellId, spellName, t)
	local mod = ClassDB.ActiveModule()
	if mod and mod.onCast then
		mod.onCast(self, spellId, spellName, t)
	end
end

function ClassDB.OnMatchedPhysical(self, spellId, t, amount)
	local mod = ClassDB.ActiveModule()
	if mod and mod.onMatchedPhysical then
		mod.onMatchedPhysical(self, spellId, t, amount)
	end
end

function ClassDB.OnPhysicalWound(self, ctx)
	local mod = ClassDB.ActiveModule()
	if mod and mod.onPhysicalWound then
		mod.onPhysicalWound(self, ctx)
	end
end

function ClassDB.OnGuardianWound(self, ctx)
	local mod = ClassDB.ActiveModule()
	if mod and mod.onGuardianWound then
		return mod.onGuardianWound(self, ctx) == true
	end
	return false
end

function ClassDB.PetSchoolHit(school)
	local mod = ClassDB.ActiveModule()
	if mod and mod.petSchoolHit then
		return mod.petSchoolHit(school, ClassDB.Helpers()) == true
	end
	return false
end

function ClassDB.PetSchoolHitRecent(self, school, lastPlayerSpellId)
	local mod = ClassDB.ActiveModule()
	if mod and mod.petSchoolHitRecent then
		return mod.petSchoolHitRecent(self, school, lastPlayerSpellId, ClassDB.Helpers()) == true
	end
	return false
end

-- Physical pet damage (school 1) can't live in petSchoolHit: that signature
-- also gates restrict bypasses, where treating melee as pet would leak
-- foreign swings. This hook is consulted ONLY by the pet-fallback emit.
function ClassDB.PetPhysicalHit(school)
	local mod = ClassDB.ActiveModule()
	if mod and mod.petPhysicalHit then
		return mod.petPhysicalHit(school, ClassDB.Helpers()) == true
	end
	return false
end

-- True when the class can never produce auto-attack damage worth showing
-- (warlock/mage/priest: every school-1 hit is pet melee or foreign). The
-- collector treats a veto like "no player swing explains this" — hits
-- route to pet-physical or drop instead of wearing your auto-attack.
function ClassDB.VetoAuto()
	local mod = ClassDB.ActiveModule()
	if mod and mod.vetoAuto then
		return mod.vetoAuto(ClassDB.Helpers()) == true
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
		return mod.resolvePetSpellId(self, school, t, ClassDB.Helpers())
	end
	return nil
end

-- Returns false when the module vetoes this dot attribution (e.g. warlock
-- Imp fire hits are pet damage, never DoT ticks). nil/true = allowed.
function ClassDB.DotGuard(entry, school)
	local mod = ClassDB.ActiveModule()
	if mod and mod.dotGuard then
		return mod.dotGuard(entry, school, ClassDB.Helpers())
	end
	return nil
end

-- One-time load confirmation: prints the resolved class tag and whether a
-- module was found, so "did my class module load?" is answerable in chat.
local _classCheckFrame = CreateFrame and CreateFrame("Frame") or nil
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
