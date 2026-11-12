------------------------------------------------------------------------
-- ZSBT - Core Orchestrator (Skeleton)
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

local L = ZSBT.L

ZSBT.Core = ZSBT.Core or {}
local Core  = ZSBT.Core
local Addon = ZSBT.Addon

Core._initialized = Core._initialized or false
Core._enabled     = Core._enabled or false
Core._inGroupInstance = Core._inGroupInstance or false

function Core:IsAurasSecretContext(updateInfo)
	-- Prefer a direct probe of the UNIT_AURA update payload when available.
	if updateInfo ~= nil and HasSecretValues then
		local ok, res = pcall(HasSecretValues, updateInfo)
		if ok and res == true then
			return true
		end
	end

	-- Arena/BG contexts should be treated as restricted even outside combat.
	if type(IsInInstance) == "function" then
		local ok, inInst, instType = pcall(IsInInstance)
		if ok and inInst == true and (instType == "arena" or instType == "pvp") then
			return true
		end
	end

	-- Combat is the primary secret-aura context for player aura tracking.
	if UnitAffectingCombat then
		local ok, inCombat = pcall(UnitAffectingCombat, "player")
		if ok and inCombat == true then
			return true
		end
	end

	return false
end

-- C_Secrets predicates (SecretPredicateAPIDocumentation): per-index and
-- per-instance answers let us skip individual secret auras instead of
-- abandoning the whole scan. All feature-detected; absent on older clients.
function Core:AuraSecretGlobal()
	if C_Secrets and C_Secrets.ShouldAurasBeSecret then
		local ok, res = pcall(C_Secrets.ShouldAurasBeSecret)
		if ok and type(res) == "boolean" then return res end
	end
	return nil
end

function Core:AuraIndexSecret(index, filter)
	if C_Secrets and C_Secrets.ShouldUnitAuraIndexBeSecret then
		local ok, res = pcall(C_Secrets.ShouldUnitAuraIndexBeSecret, "player", index, filter)
		if ok then return res == true end
	end
	return false
end

function Core:AuraInstanceSecret(instanceId)
	if C_Secrets and C_Secrets.ShouldUnitAuraInstanceBeSecret then
		local ok, res = pcall(C_Secrets.ShouldUnitAuraInstanceBeSecret, "player", instanceId)
		if ok then return res == true end
	end
	return false
end

function Core:IsMasterEnabled()
    return ZSBT.db
       and ZSBT.db.profile
       and ZSBT.db.profile.general
       and ZSBT.db.profile.general.enabled == true
end

function Core:RecordRecentBuff(spellID)
	if type(spellID) ~= "number" then return end
	if not self._recentBuffStats then self._recentBuffStats = {} end
	local stats = self._recentBuffStats
	local now = GetTime and GetTime() or 0
	local entry = stats[spellID]
	if type(entry) ~= "table" then
		entry = { count = 0, lastSeen = 0 }
		stats[spellID] = entry
	end
	entry.count = (entry.count or 0) + 1
	entry.lastSeen = now

	local total = 0
	for _ in pairs(stats) do total = total + 1 end
	local MAX = 60
	if total > MAX then
		local oldestId, oldestTs = nil, nil
		for sid, e in pairs(stats) do
			local ts = type(e) == "table" and e.lastSeen or 0
			if not oldestTs or ts < oldestTs then
				oldestTs = ts
				oldestId = sid
			end
		end
		if oldestId then stats[oldestId] = nil end
	end
end

-- Name -> spellID resolution for secret aura contexts. Combat-text aura
-- notices carry a readable name but no spellID; C_Spell/GetSpellInfo accept a
-- name and return the ID even when the aura payload itself is secret.
local _spellIdByNameCache = {}
local SPELL_ID_NAME_CACHE_MAX = 512
local function ResolveSpellIdByName(name)
	if type(name) ~= "string" then return nil end
	if ZSBT.IsSafeString and not ZSBT.IsSafeString(name) then return nil end
	local okEmpty, isEmpty = pcall(function() return name == "" end)
	if not okEmpty or isEmpty == true then return nil end
	local cached = _spellIdByNameCache[name]
	if type(cached) == "number" and cached > 0 then return cached end
	local sid = nil
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, name)
		sid = ok and info and (info.spellID or info.spellId) or nil
	end
	if not (type(sid) == "number" and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid)) and GetSpellInfo then
		local ok, _, _, _, _, _, _, spellId = pcall(GetSpellInfo, name)
		if ok and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(spellId) then
			sid = spellId
		else
			sid = nil
		end
	end
	if type(sid) == "number" and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
		local n = 0
		for _ in pairs(_spellIdByNameCache) do n = n + 1 end
		if n >= SPELL_ID_NAME_CACHE_MAX then _spellIdByNameCache = {} end
		_spellIdByNameCache[name] = sid
		return sid
	end
	return nil
end

local function getAuraRuleForSpell(spellID)
	local sc = ZSBT and ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
	local rules = sc and sc.auraRules
	if type(spellID) ~= "number" or type(rules) ~= "table" then return nil end
	local rule = rules[spellID]
	if type(rule) ~= "table" then return nil end
	if rule.enabled == false then return { disabled = true } end
	return rule
end

function Core:ShouldEmitBuffNotif(spellID, isGain, isHarmfulOverride, auraName, trusted)
	local isHarmful = (isHarmfulOverride == true)
	if isHarmfulOverride == nil and type(spellID) == "number" then
		if type(AuraUtil) == "table" and type(AuraUtil.FindAuraBySpellId) == "function" then
			local ok, aura = pcall(AuraUtil.FindAuraBySpellId, spellID, "player", "HARMFUL")
			isHarmful = ok and aura ~= nil
		end
	end
	local rule = getAuraRuleForSpell(spellID)
	local ruleKey = nil
	if rule ~= nil then
		ruleKey = (type(spellID) == "number") and spellID or nil
	end
	-- Name-keyed rules ("name:X") match every rank of an aura by name; only
	-- consulted when no spellID rule exists and the name is readable.
	if rule == nil and type(auraName) == "string"
		and ZSBT.IsSafeString and ZSBT.IsSafeString(auraName) then
		local scn = ZSBT and ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
		local rules = scn and scn.auraRules
		local nkey = "name:" .. auraName
		local nr = type(rules) == "table" and rules[nkey] or nil
		if type(nr) == "table" then
			rule = (nr.enabled == false) and { disabled = true } or nr
			ruleKey = nkey
		elseif nr == false then
			rule = { disabled = true }
			ruleKey = nkey
		end
	end
	local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("core"))
		or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
	if not rule then
		-- 12.1+ combat/secret context: do not emit unconfigured aura gains/fades.
		-- Trusted sources (combat-text notices, recast pairing) are reliable
		-- Blizzard UI signals and bypass this blanket suppression.
		if trusted ~= true and self.IsAurasSecretContext and self:IsAurasSecretContext() == true then
			return false
		end
		local sc = ZSBT and ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
		local g = sc and sc.auraGlobal
		if isHarmful and isGain and g and g.showUnconfiguredDebuffGains == false then
			if dl >= 4 then
				if Addon and Addon.Dbg then
					Addon:Dbg("core", 4, "[AURA] ShouldEmit: blocked unconfigured debuff gain sid=" .. tostring(spellID))
				else
					local ZSBTAddon = ZSBT and ZSBT.Addon
					if ZSBTAddon and ZSBTAddon.Print then ZSBTAddon:Print("[AURA] ShouldEmit: blocked unconfigured debuff gain sid=" .. tostring(spellID)) end
				end
			end
			return false
		end
		if isHarmful and (not isGain) and g and g.showUnconfiguredDebuffFades == false then
			if dl >= 4 then
				if Addon and Addon.Dbg then
					Addon:Dbg("core", 4, "[AURA] ShouldEmit: blocked unconfigured debuff fade sid=" .. tostring(spellID))
				else
					local ZSBTAddon = ZSBT and ZSBT.Addon
					if ZSBTAddon and ZSBTAddon.Print then ZSBTAddon:Print("[AURA] ShouldEmit: blocked unconfigured debuff fade sid=" .. tostring(spellID)) end
				end
			end
			return false
		end
		if (not isHarmful) and isGain and g and g.showUnconfiguredGains == false then 
			if dl >= 4 then
				if Addon and Addon.Dbg then
					Addon:Dbg("core", 4, "[AURA] ShouldEmit: blocked unconfigured gain sid=" .. tostring(spellID))
				else
					local ZSBTAddon = ZSBT and ZSBT.Addon
					if ZSBTAddon and ZSBTAddon.Print then ZSBTAddon:Print("[AURA] ShouldEmit: blocked unconfigured gain sid=" .. tostring(spellID)) end
				end
			end
			return false 
		end
		if (not isHarmful) and (not isGain) and g and g.showUnconfiguredFades == false then 
			if dl >= 4 then
				if Addon and Addon.Dbg then
					Addon:Dbg("core", 4, "[AURA] ShouldEmit: blocked unconfigured fade sid=" .. tostring(spellID))
				else
					local ZSBTAddon = ZSBT and ZSBT.Addon
					if ZSBTAddon and ZSBTAddon.Print then ZSBTAddon:Print("[AURA] ShouldEmit: blocked unconfigured fade sid=" .. tostring(spellID)) end
				end
			end
			return false 
		end
		return true
	end
	if ruleKey == nil then
		return true
	end
	if rule.disabled then 
		if dl >= 4 then
			if Addon and Addon.Dbg then
				Addon:Dbg("core", 4, "[AURA] ShouldEmit: rule disabled sid=" .. tostring(spellID))
			else
				local ZSBTAddon = ZSBT and ZSBT.Addon
				if ZSBTAddon and ZSBTAddon.Print then ZSBTAddon:Print("[AURA] ShouldEmit: rule disabled sid=" .. tostring(spellID)) end
			end
		end
		return false 
	end

	if isGain and rule.suppressGain then 
		if dl >= 4 then
			if Addon and Addon.Dbg then
				Addon:Dbg("core", 4, "[AURA] ShouldEmit: suppressGain sid=" .. tostring(spellID))
			else
				local ZSBTAddon = ZSBT and ZSBT.Addon
				if ZSBTAddon and ZSBTAddon.Print then ZSBTAddon:Print("[AURA] ShouldEmit: suppressGain sid=" .. tostring(spellID)) end
			end
		end
		return false 
	end
	if (not isGain) and rule.suppressFade then 
		if dl >= 4 then
			if Addon and Addon.Dbg then
				Addon:Dbg("core", 4, "[AURA] ShouldEmit: suppressFade sid=" .. tostring(spellID))
			else
				local ZSBTAddon = ZSBT and ZSBT.Addon
				if ZSBTAddon and ZSBTAddon.Print then ZSBTAddon:Print("[AURA] ShouldEmit: suppressFade sid=" .. tostring(spellID)) end
			end
		end
		return false 
	end

	local throttle = tonumber(rule.throttleSec) or 0
	if throttle <= 0 then return true end

	if not self._auraRuleLastShown then self._auraRuleLastShown = {} end
	local state = self._auraRuleLastShown[ruleKey]
	if type(state) ~= "table" then
		state = { gain = 0, fade = 0 }
		self._auraRuleLastShown[ruleKey] = state
	end
	local now = GetTime and GetTime() or 0
	local key = isGain and "gain" or "fade"
	if (now - (state[key] or 0)) < throttle then
		return false
	end
	state[key] = now
	return true
end

function Core:IsCombatOnlyEnabled()
    return ZSBT.db
       and ZSBT.db.profile
       and ZSBT.db.profile.general
       and ZSBT.db.profile.general.combatOnly == true
end

function Core:IsInstanceAwareOutgoingEnabled()
	return ZSBT.db
		and ZSBT.db.profile
		and ZSBT.db.profile.general
		and ZSBT.db.profile.general.instanceAwareOutgoing == true
end

function Core:ShouldAutoRelaxOutgoingWhenSoloInstance()
	local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
	if not (g and g.autoRelaxOutgoingWhenSolo == true) then
		return false
	end
	if type(IsInInstance) ~= "function" then return false end
	local ok, inInstance, instanceType = pcall(IsInInstance)
	if not ok or inInstance ~= true then return false end
	if instanceType ~= "party" and instanceType ~= "raid" then return false end
	local members = 0
	if type(GetNumGroupMembers) == "function" then
		local okM, m = pcall(GetNumGroupMembers)
		if okM and type(m) == "number" then members = m end
	end
	return members <= 1
end

function Core:IsStrictOutgoingCombatLogOnlyEnabled()
	if not (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general) then return false end
	local g = ZSBT.db.profile.general
	if self.ShouldAutoRelaxOutgoingWhenSoloInstance and self:ShouldAutoRelaxOutgoingWhenSoloInstance() then
		return false
	end
	return g.strictOutgoingCombatLogOnly == true
end

function Core:IsInPvPInstanceType()
	local inInstance, instanceType = false, "none"
	if type(IsInInstance) == "function" then
		local ok, ii, it = pcall(IsInInstance)
		if ok then
			inInstance = ii == true
			instanceType = it
		end
	end
	if not inInstance then return false end
	return instanceType == "pvp" or instanceType == "arena"
end

function Core:IsPvPStrictEnabled()
	return ZSBT.db
		and ZSBT.db.profile
		and ZSBT.db.profile.general
		and ZSBT.db.profile.general.pvpStrictEnabled == true
end

function Core:IsPvPStrictActive()
	return self:IsPvPStrictEnabled() and self:IsInPvPInstanceType()
end

function Core:IsQuietOutgoingWhenIdleEnabled()
	if self.ShouldAutoRelaxOutgoingWhenSoloInstance and self:ShouldAutoRelaxOutgoingWhenSoloInstance() then
		return false
	end
	return ZSBT.db
		and ZSBT.db.profile
		and ZSBT.db.profile.general
		and ZSBT.db.profile.general.quietOutgoingWhenIdle == true
end

function Core:IsQuietOutgoingAutoAttacksEnabled()
	return ZSBT.db
		and ZSBT.db.profile
		and ZSBT.db.profile.general
		and ZSBT.db.profile.general.quietOutgoingAutoAttacks == true
end

function Core:IsInGroupInstance()
	return Core._inGroupInstance == true
end

function Core:ShouldRestrictOutgoingFallback()
	return self:IsInstanceAwareOutgoingEnabled() and self:IsInGroupInstance()
end

function Core:UpdateInstanceState(_silent)
	local inInstance, instanceType = false, "none"
	if type(IsInInstance) == "function" then
		local ok, ii, it = pcall(IsInInstance)
		if ok then
			inInstance = ii == true
			instanceType = it
		end
	end
	local isPartyOrRaidInstance = (inInstance == true) and (instanceType == "party" or instanceType == "raid")
	local isPvPInstance = (inInstance == true) and (instanceType == "pvp" or instanceType == "arena")
	local members = 0
	if type(GetNumGroupMembers) == "function" then
		local okM, m = pcall(GetNumGroupMembers)
		if okM and type(m) == "number" then members = m end
	end
	local isGroup = isPartyOrRaidInstance and members > 1
	if isGroup ~= true and isPvPInstance and members > 1 then
		local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
		if g and g.pvpStrictEnabled == true then
			isGroup = true
		end
	end
	Core._inGroupInstance = isGroup
end

function Core:ShouldEmitNow()
    if not self:IsMasterEnabled() then return false end
    if self:IsCombatOnlyEnabled() then
		local inPlayerCombat = false
		if UnitAffectingCombat then
			local ok, res = pcall(UnitAffectingCombat, "player")
			if ok and type(res) == "boolean" then inPlayerCombat = res end
		end
		if not inPlayerCombat then
			local inPetCombat = false
			if UnitAffectingCombat then
				local ok, res = pcall(UnitAffectingCombat, "pet")
				if ok and type(res) == "boolean" then inPetCombat = res end
			end
			if not inPetCombat then
				-- Combat-only grace: very fast kills can produce a combat event before
				-- UnitAffectingCombat() flips true. If we have evidence of very recent
				-- combat activity, allow emission.
				local tNow = (GetTime and GetTime()) or 0
				local lastAt = tonumber(self._lastCombatActivityAt) or 0
				if lastAt > 0 and (tNow - lastAt) <= 0.75 then
					return true
				end
				return false
			end
		end
    end
    return true
end

------------------------------------------------------------------------
-- CVar helpers (pcall-safe, silent on missing APIs)
------------------------------------------------------------------------
local function trySetCVar(name, value)
    if type(SetCVar) ~= "function" then return end
    pcall(SetCVar, name, value)
end

local function tryGetCVar(name)
    if type(GetCVar) ~= "function" then return nil end
    local ok, val = pcall(GetCVar, name)
    if ok then return val end
    return nil
end

local function ResolveSafeAuraSpellID(auraData)
	if not auraData then return nil end
	local sid = auraData.spellId or auraData.spellID
	if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
		return sid
	end

	local instanceId = auraData.auraInstanceID
	if instanceId and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
		local ok, refetched = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", instanceId)
		if ok and refetched then
			local rsid = refetched.spellId or refetched.spellID
			if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(rsid) then
				return rsid
			end
		end
	end

	return nil
end

------------------------------------------------------------------------
-- Blizzard FCT CVar management
------------------------------------------------------------------------

-- All known Blizzard floating combat text CVars.
-- Setting these to "0" disables Blizzard's own scrolling numbers.
local BLIZZARD_FCT_CVARS = {
    -- Global combat text enable (some clients gate XP/combat text via this)
    "enableCombatText",

    -- Legacy CVars
    "floatingCombatTextCombatDamage",
    "floatingCombatTextCombatHealing",
    "floatingCombatTextCombatXP",
    "floatingCombatTextCombatDamageAllAutos",
    "floatingCombatTextCombatHealingAbsorbTarget",
    "floatingCombatTextCombatHealingAbsorbSelf",
    "floatingCombatTextCombatLogPeriodicSpells",
    "floatingCombatTextCombatState",
    "floatingCombatTextComboPoints",
    "floatingCombatTextDamageReduction",
    "floatingCombatTextDodgeParryMiss",
    "floatingCombatTextEnergyGains",
    "floatingCombatTextFloatMode",
    "floatingCombatTextFriendlyHealers",
    "floatingCombatTextHonorGains",
    "floatingCombatTextLowManaHealth",
    "floatingCombatTextPeriodicEnergyGains",
    "floatingCombatTextPetMeleeDamage",
    "floatingCombatTextPetSpellDamage",
    "floatingCombatTextReactives",
    "floatingCombatTextRepChanges",
    "floatingCombatTextSpellMechanics",
    "floatingCombatTextSpellMechanicsOther",
    "enableFloatingCombatText",

    -- Alternate/compat CVars seen on some clients/addons
    "fctCombatXP",
    "fctCombatXP_v2",

    -- Midnight 12.0 _v2 CVars (override the legacy ones for crits/procs)
    "floatingCombatTextCombatDamage_v2",
    "floatingCombatTextCombatHealing_v2",
    "floatingCombatTextCombatXP_v2",
    "floatingCombatTextReactives_v2",
    "floatingCombatTextCombatDamageAllAutos_v2",
    "floatingCombatTextCombatHealingAbsorbTarget_v2",
    "floatingCombatTextCombatHealingAbsorbSelf_v2",
    "floatingCombatTextCombatLogPeriodicSpells_v2",
    "floatingCombatTextDodgeParryMiss_v2",
    "floatingCombatTextPetMeleeDamage_v2",
    "floatingCombatTextPetSpellDamage_v2",
    "floatingCombatTextSpellMechanics_v2",
    "floatingCombatTextSpellMechanicsOther_v2",
}

-- When the user wants Blizzard outgoing combat text while ZSBT is enabled,
-- we re-enable only the outgoing-related CVars after suppression. This is a
-- best-effort separation: Blizzard routing is shared, but these CVars gate
-- which kinds of messages actually render.
local BLIZZARD_FCT_OUTGOING_CVARS = {
	"enableFloatingCombatText",
	"floatingCombatTextCombatDamage",
	"floatingCombatTextCombatDamage_v2",
	"floatingCombatTextCombatDamageAllAutos",
	"floatingCombatTextCombatDamageAllAutos_v2",
}

-- Best-effort: CVars that primarily affect "incoming" style text (heals/mitigation)
-- while leaving outgoing damage numbers off.
local BLIZZARD_FCT_INCOMING_CVARS = {
	"enableFloatingCombatText",
	"floatingCombatTextCombatHealing",
	"floatingCombatTextCombatHealing_v2",
	"floatingCombatTextCombatHealingAbsorbSelf",
	"floatingCombatTextCombatHealingAbsorbSelf_v2",
	"floatingCombatTextCombatHealingAbsorbTarget",
	"floatingCombatTextCombatHealingAbsorbTarget_v2",
}

local BLIZZARD_FCT_INCOMING_DAMAGE_CVARS = {
	"floatingCombatTextDodgeParryMiss",
	"floatingCombatTextDodgeParryMiss_v2",
	"floatingCombatTextDamageReduction",
}

local BLIZZARD_FCT_REACTIVES_CVARS = {
	"floatingCombatTextReactives",
	"floatingCombatTextReactives_v2",
	"floatingCombatTextSpellMechanics",
	"floatingCombatTextSpellMechanics_v2",
	"floatingCombatTextSpellMechanicsOther",
	"floatingCombatTextSpellMechanicsOther_v2",
	"floatingCombatTextComboPoints",
}

local BLIZZARD_FCT_XP_REP_HONOR_CVARS = {
	"floatingCombatTextCombatXP",
	"floatingCombatTextCombatXP_v2",
	"fctCombatXP",
	"fctCombatXP_v2",
	"floatingCombatTextRepChanges",
	"floatingCombatTextHonorGains",
}

local BLIZZARD_FCT_RESOURCE_GAINS_CVARS = {
	"floatingCombatTextEnergyGains",
	"floatingCombatTextPeriodicEnergyGains",
	"floatingCombatTextLowManaHealth",
}

local BLIZZARD_FCT_PET_CVARS = {
	"floatingCombatTextPetMeleeDamage",
	"floatingCombatTextPetMeleeDamage_v2",
	"floatingCombatTextPetSpellDamage",
	"floatingCombatTextPetSpellDamage_v2",
}

local function trySetCVarGroup(cvars, value)
	if type(cvars) ~= "table" then return end
	for _, cvar in ipairs(cvars) do
		trySetCVar(cvar, value)
	end
end

local function getFCTStateTable()
    local db = ZSBT and ZSBT.db
    if not db then return nil end
    db.global = db.global or {}
    db.global.blizzardFCT = db.global.blizzardFCT or {}
    return db.global.blizzardFCT
end

local function snapshotBlizzardFCTCVarsOnce()
    local st = getFCTStateTable()
    if not st then return end

    -- Only snapshot once per "suppression lifecycle" so we restore the user's original state.
    if type(st.backup) == "table" and st.hasBackup == true then
        return
    end

    local backup = {}
    for _, cvar in ipairs(BLIZZARD_FCT_CVARS) do
        backup[cvar] = tryGetCVar(cvar)
    end

    st.backup = backup
    st.hasBackup = true
    st.suppressedByZSBT = true
    st.promptShown = st.promptShown or false
end

local function restoreBlizzardFCTFromBackup()
    local st = getFCTStateTable()
    local backup = st and st.backup
    if type(backup) ~= "table" then
        return false
    end

    for cvar, val in pairs(backup) do
        if val ~= nil then
            trySetCVar(cvar, val)
        end
    end

    st.suppressedByZSBT = false
    return true
end

local function clearBlizzardFCTBackup()
    local st = getFCTStateTable()
    if not st then return end
    st.backup = nil
    st.hasBackup = false
    st.suppressedByZSBT = false
    st.combatText = nil
end

local function snapshotCombatTextFramesOnce()
    local st = getFCTStateTable()
    if not st then return end
    if type(st.combatText) == "table" then return end

    local frames = {}
    local names = { "CombatText", "CombatText2" }
    for _, name in ipairs(names) do
        local f = _G[name]
        if f and type(f.IsEventRegistered) == "function" then
            frames[name] = {
                hadCombatTextUpdate = f:IsEventRegistered("COMBAT_TEXT_UPDATE") == true,
            }
        end
    end

    st.combatText = frames
end

local function snapshotCombatTextAddFnsOnce()
    local st = getFCTStateTable()
    if not st then return end
    if type(st.ctAddFns) == "table" then return end

    local fns = {}
    local names = {
        "CombatText_AddMessage",
        "CombatText_AddMessage_v2",
        "CombatText_AddMessage2",
        "CombatText_AddMessage2_v2",
    }
    for _, name in ipairs(names) do
        if type(_G[name]) == "function" then
            fns[name] = _G[name]
        end
    end
    st.ctAddFns = fns
end

local function suppressCombatTextAddFns()
    local st = getFCTStateTable()
    local fns = st and st.ctAddFns
    if type(fns) ~= "table" then return end

    for name, fn in pairs(fns) do
        if type(fn) == "function" and type(name) == "string" then
            _G[name] = function() end
        end
    end
end

local function restoreCombatTextAddFns()
    local st = getFCTStateTable()
    local fns = st and st.ctAddFns
    if type(fns) ~= "table" then return end

    for name, fn in pairs(fns) do
        if type(fn) == "function" and type(name) == "string" then
            _G[name] = fn
        end
    end
    st.ctAddFns = nil
end

local function suppressCombatTextFrames()
    local st = getFCTStateTable()
    local frames = st and st.combatText
    if type(frames) ~= "table" then return end

    for name, info in pairs(frames) do
        local f = _G[name]
        if f and type(f.UnregisterEvent) == "function" and info and info.hadCombatTextUpdate == true then
            pcall(f.UnregisterEvent, f, "COMBAT_TEXT_UPDATE")
        end
    end
end

local function restoreCombatTextFrames()
    local st = getFCTStateTable()
    local frames = st and st.combatText
    if type(frames) ~= "table" then return end

    for name, info in pairs(frames) do
        local f = _G[name]
        if f and type(f.RegisterEvent) == "function" and info and info.hadCombatTextUpdate == true then
            pcall(f.RegisterEvent, f, "COMBAT_TEXT_UPDATE")
        end
    end
end

local function suppressBlizzardFCTExceptOutgoing()
	snapshotBlizzardFCTCVarsOnce()
	snapshotCombatTextFramesOnce()
	snapshotCombatTextAddFnsOnce()
	-- Best-effort: suppress all known Blizzard FCT CVars, then re-enable only
	-- outgoing damage/healing ones. Do NOT touch CombatText frame routing here,
	-- since restoring routing can also re-enable incoming text.
	for _, cvar in ipairs(BLIZZARD_FCT_CVARS) do
		trySetCVar(cvar, "0")
	end
	for _, cvar in ipairs(BLIZZARD_FCT_OUTGOING_CVARS) do
		trySetCVar(cvar, "1")
	end

	-- Keep Blizzard CombatText (center-screen style) suppressed, otherwise some
	-- heal/self events can still render even when the floating combat text heal
	-- CVars are 0.
	suppressCombatTextFrames()
	suppressCombatTextAddFns()
end

local function suppressBlizzardFCTExceptIncoming()
	snapshotBlizzardFCTCVarsOnce()
	snapshotCombatTextFramesOnce()
	snapshotCombatTextAddFnsOnce()
	-- Best-effort: suppress all known Blizzard FCT CVars, then re-enable only
	-- "incoming" (healing/absorb) ones.
	for _, cvar in ipairs(BLIZZARD_FCT_CVARS) do
		trySetCVar(cvar, "0")
	end
	for _, cvar in ipairs(BLIZZARD_FCT_INCOMING_CVARS) do
		trySetCVar(cvar, "1")
	end
end

local function cvarsLookSuppressed()
    local v1 = tryGetCVar("enableFloatingCombatText")
    local dmg = tryGetCVar("floatingCombatTextCombatDamage")
    local heal = tryGetCVar("floatingCombatTextCombatHealing")
    local dmg2 = tryGetCVar("floatingCombatTextCombatDamage_v2")
    local heal2 = tryGetCVar("floatingCombatTextCombatHealing_v2")

    return (v1 == "0")
        or (dmg == "0")
        or (heal == "0")
        or (dmg2 == "0")
        or (heal2 == "0")
end

function Core:SuppressBlizzardFCT()
    snapshotBlizzardFCTCVarsOnce()
    snapshotCombatTextFramesOnce()
    snapshotCombatTextAddFnsOnce()
    for _, cvar in ipairs(BLIZZARD_FCT_CVARS) do
        trySetCVar(cvar, "0")
    end

    -- Some clients do not expose XP-related combat text CVars (GetCVar returns nil).
    -- As a last-resort suppression, unregister Blizzard CombatText frames from COMBAT_TEXT_UPDATE.
    suppressCombatTextFrames()

    -- Additional fallback: some clients route XP/rep/honor through CombatText_AddMessage* paths
    -- even when COMBAT_TEXT_UPDATE isn't exposed. Null them out while suppression is active.
    suppressCombatTextAddFns()
end

function Core:RestoreBlizzardFCT()
    if restoreBlizzardFCTFromBackup() then
        restoreCombatTextFrames()
        restoreCombatTextAddFns()
        clearBlizzardFCTBackup()
        return true
    end

	-- Fallback: explicitly re-enable the most important Blizzard FCT CVars.
	-- This is used when the user clicks the restore button or sets suppression to None,
	-- but no snapshot exists (nolib installs, prior restores, or other edge cases).
	trySetCVar("enableFloatingCombatText", "1")
	trySetCVar("floatingCombatTextCombatDamage", "1")
	trySetCVar("floatingCombatTextCombatHealing", "1")
	trySetCVar("floatingCombatTextCombatDamage_v2", "1")
	trySetCVar("floatingCombatTextCombatHealing_v2", "1")
	trySetCVar("floatingCombatTextReactives_v2", "1")

	restoreCombatTextFrames()
	restoreCombatTextAddFns()
	clearBlizzardFCTBackup()
	return true
end

function Core:EnsureBlizzardFCTEnabled()
    -- Deprecated: previously forced Blizzard FCT CVars on during lifecycle events.
    -- This was reported as re-enabling Options -> Combat -> Scrolling combat text settings.
    -- Keep as a no-op for backward compatibility.
end

function Core:MaybePromptRestoreBlizzardFCT()
    if not ZSBT.db or not ZSBT.db.profile or not ZSBT.db.profile.general then return end
    if ZSBT.db.profile.general.suppressBlizzardFCT == true then return end

    local st = getFCTStateTable()
    if not st or st.promptShown == true then return end
    if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then return end
    if type(st.backup) ~= "table" or st.hasBackup ~= true then return end
    if not cvarsLookSuppressed() then return end

    StaticPopupDialogs["ZSBT_RESTORE_BLIZZARD_FCT"] = {
        text = L["ZSBT detected Blizzard Floating Combat Text is currently disabled.\n\nRestore your previous Blizzard combat text settings?"],
        button1 = L["Restore"],
        button2 = L["Not Now"],
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        OnAccept = function()
            Core:RestoreBlizzardFCT()
        end,
        OnCancel = function()
        end,
    }

    st.promptShown = true
    StaticPopup_Show("ZSBT_RESTORE_BLIZZARD_FCT")
end

function Core:ApplyBlizzardFCTCVars()
    if not ZSBT.db or not ZSBT.db.profile or not ZSBT.db.profile.general then return end
	if InCombatLockdown and InCombatLockdown() then
		self._pendingCVarApply = true
		return
	end

    local g = ZSBT.db.profile.general
    if not g.enabled then return end

	if ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.outgoing and ZSBT.db.profile.outgoing.useBlizzardFCTInstead == true then
		ZSBT.db.profile.outgoing.useBlizzardFCTInstead = false
	end

	if g.hideBlizzardFCT == nil then
		local mode = g.blizzardFCTSuppressMode
		if mode == nil then
			mode = (g.suppressBlizzardFCT == true) and "all" or "none"
		end
		if mode == "none" then
			g.hideBlizzardFCT = false
		else
			g.hideBlizzardFCT = true
			g.hideBlizzardFCTOutgoing = (mode == "incoming") and false or true
			g.hideBlizzardFCTIncomingDamage = (mode == "outgoing") and false or true
			g.hideBlizzardFCTIncomingHealing = (mode == "outgoing") and false or true
			g.hideBlizzardFCTReactives = true
			g.hideBlizzardFCTXPRepHonor = true
			g.hideBlizzardFCTResourceGains = true
			g.hideBlizzardFCTPet = true
		end
	end

    -- CRITICAL: Always ensure CombatDamage/CombatHealing are ON.
    -- A previous build wrongly set these to 0, which kills UNIT_COMBAT events.
    trySetCVar("CombatDamage", "1")
    trySetCVar("CombatHealing", "1")

	if g.hideBlizzardFCT ~= true then
		self:RestoreBlizzardFCT()
		return
	end

	snapshotBlizzardFCTCVarsOnce()
	snapshotCombatTextFramesOnce()
	snapshotCombatTextAddFnsOnce()

	local hideOutgoing = (g.hideBlizzardFCTOutgoing ~= false)
	local hideInDmg = (g.hideBlizzardFCTIncomingDamage ~= false)
	local hideInHeal = (g.hideBlizzardFCTIncomingHealing ~= false)
	local hideReact = (g.hideBlizzardFCTReactives ~= false)
	local hideXP = (g.hideBlizzardFCTXPRepHonor ~= false)
	local hideRes = (g.hideBlizzardFCTResourceGains ~= false)
	local hidePet = (g.hideBlizzardFCTPet ~= false)

	local hideAll = hideOutgoing and hideInDmg and hideInHeal and hideReact and hideXP and hideRes and hidePet
	local anyShow = not hideAll
	trySetCVar("enableCombatText", anyShow and "1" or "0")
	trySetCVar("enableFloatingCombatText", anyShow and "1" or "0")

	trySetCVarGroup(BLIZZARD_FCT_OUTGOING_CVARS, hideOutgoing and "0" or "1")
	trySetCVarGroup(BLIZZARD_FCT_INCOMING_CVARS, hideInHeal and "0" or "1")
	trySetCVarGroup(BLIZZARD_FCT_INCOMING_DAMAGE_CVARS, hideInDmg and "0" or "1")
	trySetCVarGroup(BLIZZARD_FCT_REACTIVES_CVARS, hideReact and "0" or "1")
	trySetCVarGroup(BLIZZARD_FCT_XP_REP_HONOR_CVARS, hideXP and "0" or "1")
	trySetCVarGroup(BLIZZARD_FCT_RESOURCE_GAINS_CVARS, hideRes and "0" or "1")
	trySetCVarGroup(BLIZZARD_FCT_PET_CVARS, hidePet and "0" or "1")

	if hideAll then
		suppressCombatTextFrames()
		suppressCombatTextAddFns()
	else
		-- WoW 12.x can still render incoming/self damage/heals via CombatText paths
		-- even when the floating combat text CVars are 0. If the user is allowing
		-- Blizzard outgoing but hiding incoming/reactives, keep CombatText suppressed
		-- to avoid "leaking" Blizzard incoming numbers.
		local allowOutgoing = (hideOutgoing == false)
		local hideAnyIncomingLike = (hideInDmg == true) or (hideInHeal == true) or (hideReact == true)
		if allowOutgoing and hideAnyIncomingLike then
			suppressCombatTextFrames()
			suppressCombatTextAddFns()
		else
			restoreCombatTextFrames()
			restoreCombatTextAddFns()
		end
	end

    -- Option C: if ZSBT previously suppressed and the CVars still look off,
    -- prompt to restore the user's previous values.
    self:MaybePromptRestoreBlizzardFCT()
end

------------------------------------------------------------------------
-- CVar re-application on combat state changes
------------------------------------------------------------------------
-- Blizzard may reset text rendering CVars during zone transitions or
-- combat log filter changes. Re-apply our settings on key lifecycle
-- events to ensure text stays visible.
local cvarWatchFrame = CreateFrame("Frame")
cvarWatchFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
cvarWatchFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
cvarWatchFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
cvarWatchFrame:SetScript("OnEvent", function()
    if Core._enabled then
		Core:UpdateInstanceState(true)
		if Core._pendingCVarApply == true then
			Core._pendingCVarApply = false
			Core:ApplyBlizzardFCTCVars()
		else
			Core:ApplyBlizzardFCTCVars()
		end
    end
end)

function Core:Init()
    if self._initialized then return end
    self._initialized = true

    	if Addon and Addon.Dbg then
		Addon:Dbg("core", 3, "Core:Init()")
	elseif Addon and Addon.DebugPrint then
		Addon:DebugPrint(1, "Core:Init()")
	end

	if self.InitLibSinkOutput then
		self:InitLibSinkOutput()
	end

    if self.IncomingProbe and self.IncomingProbe.Init then
        self.IncomingProbe:Init()
    end
end

function Core:InitLibSinkOutput()
	if self._libSinkInitialized == true then return end
	self._libSinkInitialized = true

	local function getLibSink()
		local t = type(LibStub)
		if t ~= "function" and t ~= "table" then return nil end
		return LibStub("LibSink-2.0", true)
	end

	local function getScrollAreasList()
		local names = {}
		local prof = ZSBT.db and ZSBT.db.profile
		local areas = prof and prof.scrollAreas
		if type(areas) ~= "table" then
			return names
		end
		for areaName in pairs(areas) do
			if type(areaName) == "string" and areaName ~= "" then
				names[#names + 1] = areaName
			end
		end
		table.sort(names)
		return names
	end

	local function resolveAreaForExternal(addonObj, libSink)
		local override = nil
		if addonObj then
			local st = nil
			if libSink and libSink.storageForAddon then
				st = libSink.storageForAddon[addonObj]
			end
			if type(st) ~= "table" then
				local candidates = {
					addonObj.sink_opts,
					addonObj.sinkOpts,
					addonObj.db and addonObj.db.profile and addonObj.db.profile.sink_opts,
					addonObj.db and addonObj.db.profile and addonObj.db.profile.sinkOpts,
					addonObj.db and addonObj.db.sink_opts,
					addonObj.db and addonObj.db.sinkOpts,
					addonObj.db and addonObj.db.profile,
					addonObj.db,
					addonObj.profile,
				}
				for i = 1, #candidates do
					local c = candidates[i]
					if type(c) == "table" and type(c.sink20ScrollArea) ~= "nil" then
						st = c
						break
					end
				end
			end
			override = st and st.sink20ScrollArea
		end
		if type(override) ~= "string" or override == "" then
			if self.GetNotificationScrollArea then
				override = self:GetNotificationScrollArea("externalAddons")
			end
		end
		if type(override) ~= "string" or override == "" then
			override = "Notifications"
		end
		local prof = ZSBT.db and ZSBT.db.profile
		if prof and prof.scrollAreas and prof.scrollAreas[override] == nil then
			override = "Notifications"
		end
		return override
	end

	local function applyNotificationStyle(category, baseColor)
		local meta = { kind = "notification", category = category }
		local finalColor = baseColor
		local conf = (type(category) == "string" and category ~= "") and (self.GetNotificationPerTypeConfig and self:GetNotificationPerTypeConfig(category)) or nil
		if conf then
			local style = conf.style
			if type(style) == "table" then
				if type(style.color) == "table" and type(style.color.r) == "number" then
					finalColor = style.color
				end
				if style.fontOverride == true then
					meta.spellFontOverride = true
					meta.spellFontFace = (type(style.fontFace) == "string" and style.fontFace ~= "") and style.fontFace or nil
					meta.spellFontOutline = (type(style.fontOutline) == "string" and style.fontOutline ~= "") and style.fontOutline or nil
					meta.spellFontSize = tonumber(style.fontSize)
				end
			end
		end
		return finalColor, meta
	end

	local function registerIfAvailable()
		local libSink = getLibSink()
		if not (libSink and libSink.RegisterSink) then
			return false
		end
		if self._zsbtLibSinkRegistered == true then
			return true
		end

		local function sinkHandler(addonObj, text, r, g, b, _, _, _, sticky, _, icon)
			if type(text) ~= "string" then
				text = tostring(text or "")
			end
			if type(icon) == "string" and icon ~= "" then
				text = "|T" .. icon .. L[":15:15:0:0:64:64:4:60:4:60|t "] .. text
			end
			local area = resolveAreaForExternal(addonObj, libSink)
			local color = { r = type(r) == "number" and r or 1, g = type(g) == "number" and g or 1, b = type(b) == "number" and b or 1 }
			local finalColor, meta = applyNotificationStyle("externalAddons", color)
			if sticky == true then
				meta.sticky = true
			end
			if ZSBT.DisplayText then
				ZSBT.DisplayText(area, text, finalColor, meta)
			elseif self.Display and self.Display.Emit then
				self.Display:Emit(area, text, finalColor, meta)
			end
		end

		local ok = pcall(function()
			libSink:RegisterSink(
				"ZSBT",
				"ZSBT",
				L["Route output to Zore's Scrolling Battle Text."],
				sinkHandler,
				getScrollAreasList,
				true
			)
		end)
		if ok then
			self._zsbtLibSinkRegistered = true
			local reg = LibStub and LibStub("AceConfigRegistry-3.0", true)
			if reg and reg.NotifyChange then
				pcall(reg.NotifyChange, reg, "ZSBT")
				pcall(reg.NotifyChange, reg, "KalielsTracker")
				pcall(reg.NotifyChange, reg, "SilverDragon")
			end

			pcall(function()
				local aceAddon = LibStub and LibStub("AceAddon-3.0", true)
				if not aceAddon then return end
				local sd = aceAddon:GetAddon("SilverDragon", true)
				if not sd then return end
				local announce = sd:GetModule("Announce", true)
				if not announce then return end
				if type(announce.GetSinkAce3OptionsDataTable) ~= "function" then return end
				local sinkConfig = announce:GetSinkAce3OptionsDataTable()
				if type(sinkConfig) ~= "table" or type(sinkConfig.args) ~= "table" then return end
				if sinkConfig.args.ZSBT ~= nil then return end
				sinkConfig.args.ZSBT = {
					type = "toggle",
					name = "ZSBT",
					desc = L["Route output through ZSBT."],
				}
			end)

			return true
		end
		return false
	end

	if registerIfAvailable() then
		return
	end

	if self._libSinkWatchFrame then
		return
	end
	self._libSinkWatchFrame = CreateFrame("Frame")
	self._libSinkWatchFrame:RegisterEvent("ADDON_LOADED")
	self._libSinkWatchFrame:SetScript("OnEvent", function()
		if registerIfAvailable() then
			if self._libSinkWatchFrame then
				self._libSinkWatchFrame:UnregisterAllEvents()
				self._libSinkWatchFrame:SetScript("OnEvent", nil)
				self._libSinkWatchFrame = nil
			end
		end
	end)
end

function Core:Enable()
    if self._enabled then return end
    self:Init()
    self._enabled = true

    if Addon and Addon.Dbg then
		Addon:Dbg("core", 3, "Core:Enable()")
	elseif Addon and Addon.DebugPrint then
		Addon:DebugPrint(1, "Core:Enable()")
	end

    self:ApplyBlizzardFCTCVars()

    if self.Display and self.Display.Enable then self.Display:Enable() end
    if self.Triggers and self.Triggers.Enable then self.Triggers:Enable() end
    if self.Cooldowns and self.Cooldowns.Enable then self.Cooldowns:Enable() end
    if self.Combat and self.Combat.Enable then self.Combat:Enable() end
    self:InitNotifications()
    self:InitHealthWarnings()
    self:InitBuffTracking()
    self:InitKillAnnouncer()
    self:InitLootTracking()
    self:InitTradeSkillTracking()
	self:InitInterruptTracking()
    self:InitPowerTracking()
    self:InitComboPoints()
    self:InitProgressTracking()
end

function Core:Disable()
    if not self._enabled then return end
    self._enabled = false

    if Addon and Addon.Dbg then
		Addon:Dbg("core", 3, "Core:Disable()")
	elseif Addon and Addon.DebugPrint then
		Addon:DebugPrint(1, "Core:Disable()")
	end

    if self.Combat and self.Combat.Disable then self.Combat:Disable() end
    if self.Cooldowns and self.Cooldowns.Disable then self.Cooldowns:Disable() end
    if self.Triggers and self.Triggers.Disable then self.Triggers:Disable() end
    if self.Display and self.Display.Disable then self.Display:Disable() end
end

------------------------------------------------------------------------
-- Notification System
-- Emits text to the "Notifications" scroll area for combat events.
------------------------------------------------------------------------
function Core:InitNotifications()
    if self._notifFrame then return end
    self._notifFrame = CreateFrame("Frame")
    self._notifFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    self._notifFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    self._notifFrame:SetScript("OnEvent", function(_, event)
        if not Core:IsMasterEnabled() then return end
        if event == "PLAYER_REGEN_DISABLED" then
			Core:EmitNotificationTemplate("enterCombat", "%e", { e = "+Combat" }, {r = 1, g = 0.2, b = 0.2})
        elseif event == "PLAYER_REGEN_ENABLED" then
			local p = ZSBT.db and ZSBT.db.profile
			local per = p and p.notificationsPerType
			local ec = per and per.enterCombat
			local stopOnLeave = ec and ec.sound and ec.sound.stopOnLeaveCombat == true
			if stopOnLeave and self._enterCombatSoundHandle and StopSound then
				pcall(function() StopSound(self._enterCombatSoundHandle) end)
			end
			self._enterCombatSoundHandle = nil
			Core:EmitNotificationTemplate("leaveCombat", "%e", { e = "-Combat" }, {r = 0.2, g = 1, b = 0.2})
        end
    end)
end

------------------------------------------------------------------------
-- Trade Skill Notifications
-- Skill ups and learned recipes/spells routed via Notifications.
------------------------------------------------------------------------
function Core:InitTradeSkillTracking()
	if self._tradeSkillFrame then return end

	local function getTemplate(key, fallback)
		local p = ZSBT.db and ZSBT.db.profile
		local t = p and p.notificationsTemplates
		local v = t and t[key]
		if type(v) ~= "string" or v == "" then
			return fallback
		end
		return v
	end

	local function getMoneyFormat(key, fallback)
		local p = ZSBT.db and ZSBT.db.profile
		local t = p and p.notificationsMoneyFormat
		local v = t and t[key]
		if type(v) ~= "string" or v == "" then
			return fallback
		end
		return v
	end

	local function applyTemplate(tpl, ctx)
		if type(tpl) ~= "string" or tpl == "" then return nil end
		ctx = ctx or {}
		local out = tpl
		out = out:gsub("%%e", tostring(ctx.e or ""))
		out = out:gsub("%%a", tostring(ctx.a or ""))
		out = out:gsub("%%t", tostring(ctx.t or ""))
		return out
	end

	local function convertGlobalStringToPattern(gs)
		if type(gs) ~= "string" or gs == "" then return nil end
		local pat = gs
		pat = pat:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
		pat = pat:gsub("%%%%%d%$d", "(%%d+)")
		pat = pat:gsub("%%%%d", "(%%d+)")
		pat = pat:gsub("%%%%%d%$s", "(.+)")
		pat = pat:gsub("%%%%s", "(.+)")
		return "^" .. pat .. "$"
	end

	local skillUpPat = convertGlobalStringToPattern(_G.SKILL_RANK_UP)
	local learnRecipePat = convertGlobalStringToPattern(_G.ERR_LEARN_RECIPE_S)
	local learnSpellPat = convertGlobalStringToPattern(_G.ERR_LEARN_SPELL_S)

	self._tradeSkillFrame = CreateFrame("Frame")
	self._tradeSkillFrame:RegisterEvent("CHAT_MSG_SKILL")
	self._tradeSkillFrame:RegisterEvent("CHAT_MSG_SYSTEM")
	self._tradeSkillFrame:SetScript("OnEvent", function(_, event, msg)
		if not Core:IsMasterEnabled() then return end
		if not msg or type(msg) ~= "string" then return end
		if not ZSBT.IsSafeString(msg) then return end

		if event == "CHAT_MSG_SKILL" then
			-- Example (localized): "%s increased to %d."
			local skillName, newRank = nil, nil
			if skillUpPat then
				skillName, newRank = msg:match(skillUpPat)
			end
			if not skillName or not newRank then
				return
			end
			local newLevel = tonumber(newRank)
			if not newLevel then return end
			local tpl = getTemplate("tradeskillUps", "%e +%a (%t)")
			local out = applyTemplate(tpl, { e = skillName, a = 1, t = newLevel })
			if out and out ~= "" then
				Core:EmitNotification(out, { r = 0.2, g = 0.8, b = 1.0 }, "tradeskillUps")
			end
			return
		end

		if event == "CHAT_MSG_SYSTEM" then
			-- Learned recipe/spell messages (localized)
			local learned = nil
			if learnRecipePat then
				learned = msg:match(learnRecipePat)
			end
			if not learned and learnSpellPat then
				learned = msg:match(learnSpellPat)
			end
			if not learned or learned == "" then
				return
			end
			local tpl = getTemplate("tradeskillLearned", L["Learned: %e"])
			local out = applyTemplate(tpl, { e = learned })
			if out and out ~= "" then
				Core:EmitNotification(out, { r = 0.2, g = 0.8, b = 1.0 }, "tradeskillLearned")
			end
			return
		end
	end)
end

function Core:InitInterruptTracking()
	if self._interruptFrame then return end

	local INTERRUPT_SPELL_IDS = {
		-- Rogue / Shaman / Demon Hunter
		[1766] = true,  -- Kick
		[57994] = true, -- Wind Shear
		[183752] = true, -- Disrupt
		-- Death Knight / Hunter / Paladin (extra common interrupts)
		[47528] = true, -- Mind Freeze
		[187707] = true, -- Muzzle
		[31935] = true, -- Avenger's Shield
		-- Warrior / Paladin / Monk / Druid
		[6552] = true,  -- Pummel
		[96231] = true, -- Rebuke
		[116705] = true, -- Spear Hand Strike
		[106839] = true, -- Skull Bash
		-- Mage / Warlock / Priest / Hunter / Evoker
		[2139] = true,  -- Counterspell
		[19647] = true, -- Spell Lock
		[89766] = true, -- Axe Toss
		[347008] = true, -- Axe Toss (alt)
		[15487] = true, -- Silence
		[147362] = true, -- Counter Shot
		[351338] = true, -- Quell
		-- Blood Elf racial
		[28730] = true, -- Arcane Torrent
	}
	-- Warlock: Command Demon is a player-cast wrapper that triggers a pet ability.
	-- Resolve it to the actual pet spellId so interrupt/caststop detection works.
	-- Some clients report a different wrapper spellId (e.g. 119914).
	local COMMAND_DEMON_SPELL_IDS = {
		[119898] = true,
		[119914] = true,
	}
	local CASTSTOP_SPELL_IDS = {
		-- Warrior
		[107570] = true, -- Storm Bolt
		[46968] = true,  -- Shockwave
		[132168] = true, -- Shockwave (alt)
		[5246] = true,   -- Intimidating Shout
		-- Demon Hunter
		[179057] = true, -- Chaos Nova
		[205630] = true, -- Illidan's Grasp (talent)
		-- Death Knight
		[221562] = true, -- Asphyxiate
		[108194] = true, -- Asphyxiate (old/alt)
		[91800] = true,  -- Gnaw (pet stun)
		[47481] = true,  -- Gnaw (old/alt)
		-- Warlock
		[30283] = true,  -- Shadowfury
		[6789] = true,   -- Mortal Coil
		[6358] = true,   -- Seduction
		[5782] = true,   -- Fear
		[261589] = true, -- Seduction ( Succubus via Grimoire of Service )
		-- Shaman
		[192058] = true, -- Capacitor Totem
		[51514] = true,  -- Hex
		[118905] = true, -- Static Charge (Capacitor Totem via talent)
		-- Hunter
		[19577] = true,  -- Intimidation
		[186387] = true, -- Bursting Shot (talent)
		[213691] = true, -- Scatter Shot (talent)
		[187650] = true, -- Freezing Trap
		-- Paladin
		[853] = true,    -- Hammer of Justice
		[20066] = true,  -- Repentance
		-- Rogue
		[408] = true,    -- Kidney Shot
		[1833] = true,   -- Cheap Shot
		[6770] = true,   -- Sap
		[2094] = true,   -- Blind
		[1776] = true,   -- Gouge
		-- Monk
		[119381] = true, -- Leg Sweep
		[5211] = true,   -- Mighty Bash
		[115078] = true, -- Paralysis
		-- Druid
		[33786] = true,  -- Cyclone
		[339] = true,    -- Entangling Roots
		[5211] = true,   -- Mighty Bash (shared)
		-- Mage
		[118] = true,    -- Polymorph
		[82691] = true,  -- Ring of Frost
		[157981] = true, -- Blizzard (talent, slow but can break casts)
		-- Priest
		[8122] = true,   -- Psychic Scream
		[9484] = true,   -- Shackle Undead
		[605] = true,    -- Mind Control (can interrupt casts)
		-- Evoker
		[374348] = true, -- Land Slide
		[370565] = true, -- Terrorize (talent)
	}
	local function resolvePetStopperSpellId()
		if not (UnitExists and UnitExists("pet")) then return nil end
		if type(GetPetActionInfo) ~= "function" then return nil end
		if type(GetSpellInfo) ~= "function" then return nil end
		local maxSlots = _G.NUM_PET_ACTION_SLOTS
		if type(maxSlots) ~= "number" or maxSlots <= 0 then
			maxSlots = 12
		end
		local bestInterrupt = nil
		local bestCastStop = nil
		for i = 1, maxSlots do
			local ok, name, _, _, isToken = pcall(GetPetActionInfo, i)
			if ok and type(name) == "string" and name ~= "" then
				local actionName = name
				if isToken == true and type(_G[actionName]) == "string" then
					actionName = _G[actionName]
				end
				local sid = nil
				pcall(function()
					-- GetSpellInfo(spellName) returns (name, rank, icon, castTime, minRange, maxRange, spellId)
					sid = select(7, GetSpellInfo(actionName))
				end)
				if type(sid) == "number" then
					if (not bestInterrupt) and INTERRUPT_SPELL_IDS[sid] then
						bestInterrupt = sid
					elseif (not bestCastStop) and CASTSTOP_SPELL_IDS[sid] then
						bestCastStop = sid
					end
				end
			end
		end
		return bestInterrupt or bestCastStop
	end
	local function resolveWarlockCommandDemonFallbackSpellId()
		if not UnitCreatureFamily then return nil end
		local okF, fam = pcall(UnitCreatureFamily, "pet")
		if not okF or type(fam) ~= "string" or fam == "" then return nil end
		local f = fam:lower()
		-- Felguard / Wrathguard -> Axe Toss
		if f:find("felguard", 1, true) or f:find("wrathguard", 1, true) then
			return 89766
		end
		-- Felhunter / Observer -> Spell Lock
		if f:find("felhunter", 1, true) or f:find("observer", 1, true) then
			return 19647
		end
		-- Succubus / Incubus -> Seduction (cast-stop)
		if f:find("succubus", 1, true) or f:find("incubus", 1, true) then
			return 6358
		end
		return nil
	end

	local function getTemplate(key, fallback)
		local p = ZSBT.db and ZSBT.db.profile
		local t = p and p.notificationsTemplates
		local v = t and t[key]
		if type(v) ~= "string" or v == "" then
			return fallback
		end
		return v
	end

	local function SafeDbgPrint(msg)
		if Addon and Addon.Dbg then
			Addon:Dbg("notifications", 5, msg)
			return
		end
		if not (ZSBT and ZSBT.Addon and ZSBT.Addon.Print) then return end
		if type(msg) ~= "string" then return end
		if ZSBT.IsSafeString and not ZSBT.IsSafeString(msg) then return end
		ZSBT.Addon:Print(msg)
	end

	local function safeStr(v)
		if type(v) ~= "string" then return tostring(v) end
		if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
		return "<secret>"
	end

	local function coerceSafe(v)
		if type(v) ~= "string" then
			v = tostring(v or "")
		end
		if ZSBT.IsSafeString and not ZSBT.IsSafeString(v) then
			return "<secret>"
		end
		return v
	end

	local _spellLabelCache = {}
	local STOPPER_NAMES = {
		-- Interrupts
		[1766] = L["Kick"],
		[57994] = L["Wind Shear"],
		[183752] = L["Disrupt"],
		[47528] = L["Mind Freeze"],
		[187707] = L["Muzzle"],
		[31935] = L["Avenger's Shield"],
		[6552] = L["Pummel"],
		[96231] = L["Rebuke"],
		[116705] = L["Spear Hand Strike"],
		[106839] = L["Skull Bash"],
		[2139] = L["Counterspell"],
		[19647] = L["Spell Lock"],
		[89766] = L["Axe Toss"],
		[347008] = L["Axe Toss"],
		[15487] = L["Silence"],
		[147362] = L["Counter Shot"],
		[351338] = L["Quell"],
		[28730] = L["Arcane Torrent"],
		-- Cast-stops (stuns/CC)
		[107570] = L["Storm Bolt"],
		[46968] = L["Shockwave"],
		[132168] = L["Shockwave"],
		[5246] = L["Intimidating Shout"],
		[179057] = L["Chaos Nova"],
		[205630] = L["Illidan's Grasp"],
		[221562] = L["Asphyxiate"],
		[108194] = L["Asphyxiate"],
		[91800] = L["Gnaw"],
		[47481] = L["Gnaw"],
		[30283] = L["Shadowfury"],
		[6789] = L["Mortal Coil"],
		[6358] = L["Seduction"],
		[5782] = L["Fear"],
		[261589] = L["Seduction"],
		[192058] = L["Capacitor Totem"],
		[51514] = L["Hex"],
		[118905] = L["Static Charge"],
		[19577] = L["Intimidation"],
		[186387] = L["Bursting Shot"],
		[213691] = L["Scatter Shot"],
		[187650] = L["Freezing Trap"],
		[853] = L["Hammer of Justice"],
		[20066] = L["Repentance"],
		[408] = L["Kidney Shot"],
		[1833] = L["Cheap Shot"],
		[6770] = L["Sap"],
		[2094] = L["Blind"],
		[1776] = L["Gouge"],
		[119381] = L["Leg Sweep"],
		[5211] = L["Mighty Bash"],
		[115078] = L["Paralysis"],
		[33786] = L["Cyclone"],
		[339] = L["Entangling Roots"],
		[118] = L["Polymorph"],
		[82691] = L["Ring of Frost"],
		[157981] = L["Blizzard"],
		[8122] = L["Psychic Scream"],
		[9484] = L["Shackle Undead"],
		[605] = L["Mind Control"],
		[374348] = L["Land Slide"],
		[370565] = L["Terrorize"],
	}
	for id, nm in pairs(STOPPER_NAMES) do
		_spellLabelCache[id] = nm
	end

	local function safeSpellLabel(spellId)
		spellId = tonumber(spellId)
		if not spellId then return "" end
		local cached = _spellLabelCache[spellId]
		if type(cached) == "string" then
			return cached
		end
		local hardcoded = STOPPER_NAMES[spellId]
		if type(hardcoded) == "string" and hardcoded ~= "" then
			_spellLabelCache[spellId] = hardcoded
			return hardcoded
		end
		local name = nil
		pcall(function()
			if GetSpellInfo then
				name = GetSpellInfo(spellId)
			end
		end)
		if type(name) == "string" and name ~= "" and (not ZSBT.IsSafeString or ZSBT.IsSafeString(name)) then
			_spellLabelCache[spellId] = name
			return name
		end
		local fallback = "SpellID:" .. tostring(spellId)
		_spellLabelCache[spellId] = fallback
		return fallback
	end

	local function applyTemplate(tpl, ctx)
		if type(tpl) ~= "string" or tpl == "" then return nil end
		ctx = ctx or {}
		local out = tpl
		local e = coerceSafe(ctx.e)
		local s = coerceSafe(ctx.s)
		local p = coerceSafe(ctx.p)
		local t = coerceSafe(ctx.t)
		out = out:gsub("%%e", e)
		out = out:gsub("%%s", s)
		out = out:gsub("%%p", p)
		out = out:gsub("%%t", t)
		return out
	end

	local function convertGlobalStringToPattern(gs)
		if type(gs) ~= "string" or gs == "" then return nil end
		local pat = gs
		pat = pat:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
		pat = pat:gsub("%%%%%d%$d", "(%%d+)")
		pat = pat:gsub("%%%%d", "(%%d+)")
		pat = pat:gsub("%%%%%d%$s", "(.+)")
		pat = pat:gsub("%%%%s", "(.+)")
		return "^" .. pat .. "$"
	end

	local interruptPat = nil
	if type(_G.ERR_SPELL_INTERRUPTED_S) == "string" then
		interruptPat = convertGlobalStringToPattern(_G.ERR_SPELL_INTERRUPTED_S)
	end

	self._interruptFrame = CreateFrame("Frame")
	pcall(function() self._interruptFrame:RegisterEvent("COMBAT_TEXT_UPDATE") end)
	pcall(function() self._interruptFrame:RegisterEvent("CHAT_MSG_COMBAT_LOG") end)
	pcall(function() self._interruptFrame:RegisterEvent("CHAT_MSG_COMBAT_MISC_INFO") end)
	pcall(function() self._interruptFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE") end)
	pcall(function() self._interruptFrame:RegisterEvent("CHAT_MSG_SPELL_DAMAGES") end)
	pcall(function() self._interruptFrame:RegisterEvent("CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE") end)
	pcall(function() self._interruptFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE") end)
	pcall(function() self._interruptFrame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE") end)
	pcall(function() self._interruptFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED") end)
	pcall(function() self._interruptFrame:RegisterEvent("UNIT_SPELLCAST_START") end)
	pcall(function() self._interruptFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED") end)
	pcall(function() self._interruptFrame:RegisterEvent("UNIT_SPELLCAST_STOP") end)
	pcall(function() self._interruptFrame:RegisterEvent("UNIT_SPELLCAST_FAILED") end)
	pcall(function() self._interruptFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED") end)

	self._interruptFrame:SetScript("OnEvent", function(_, event, msg, ...)
		if not Core:IsMasterEnabled() then return end
		local targetName, spellName = nil, nil
		local emitCategory = nil
		local templateKey = nil

		-- Cache last-seen cast spellId per unit so we can attribute stops even if
		-- UnitCastingInfo() returns nil by the time our own spell SUCCEEDED fires.
		if event == "UNIT_SPELLCAST_START" then
			local unit, castGuid, spellId = msg, ...
			if type(unit) == "string" then
				Core._unitLastCastSpellId = Core._unitLastCastSpellId or {}
				Core._unitLastCastAt = Core._unitLastCastAt or {}
				-- Always record that we saw a cast start, even if spellId is unavailable/secret.
				Core._unitLastCastAt[unit] = GetTime and GetTime() or 0
				if type(spellId) == "number" then
					Core._unitLastCastSpellId[unit] = spellId
				end

				-- Track expected cast end time for interrupt validation
				if unit == "target" or unit == "focus" or unit == "mouseover" or (unit:match("^nameplate")) then
					local startTime, endTime = nil, nil
					pcall(function()
						if UnitCastingInfo then
							startTime, endTime = select(4, UnitCastingInfo(unit))
						end
					end)
					local safeNum = (ZSBT and ZSBT.IsSafeNumber) or nil
					if startTime and endTime and (not safeNum or (safeNum(startTime) and safeNum(endTime))) then
						Core._pendingCasts = Core._pendingCasts or {}
						Core._pendingCasts[unit] = {
							spellId = spellId,
							startTime = startTime / 1000.0,
							endTime = endTime / 1000.0,
							castGuid = castGuid,
						}
						local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("notifications"))
							or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
						if dl >= 5 then
							SafeDbgPrint("[Cast Start] unit=" .. tostring(unit) .. " spellId=" .. tostring(spellId) .. " endTime=" .. string.format("%.3f", endTime / 1000.0))
						end
					end
				end
			end
			return
		end

		-- Castbar-based interrupt inference: when YOU cast something and a watched unit
		-- immediately fires UNIT_SPELLCAST_INTERRUPTED, treat it as a successful interrupt.
		if event == "UNIT_SPELLCAST_SUCCEEDED" then
			local unit, _, spellId = msg, ...
			if (unit == "player" or unit == "pet") and type(spellId) == "number" then
				local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("notifications"))
					or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
				if dl >= 5 and unit == "player" then
					SafeDbgPrint("[Stopper Player SUCCEEDED] spellId=" .. tostring(spellId) .. " label=" .. safeStr(safeSpellLabel(spellId)))
				end
				-- If the player cast Command Demon, resolve to the actual pet ability.
				if unit == "player" and COMMAND_DEMON_SPELL_IDS[spellId] then
					local resolved = resolvePetStopperSpellId()
					if dl >= 5 then
						SafeDbgPrint("[Stopper Command Demon] resolveStart")
						local maxSlots = _G.NUM_PET_ACTION_SLOTS
						if type(maxSlots) ~= "number" or maxSlots <= 0 then maxSlots = 12 end
						if UnitExists and UnitExists("pet") and type(GetPetActionInfo) == "function" then
							for i = 1, maxSlots do
								local okA, name, _, _, isToken = pcall(GetPetActionInfo, i)
								if okA and type(name) == "string" and name ~= "" then
									local actionName = name
									if isToken == true and type(_G[actionName]) == "string" then
										actionName = _G[actionName]
									end
									local sid = nil
									pcall(function() sid = select(7, GetSpellInfo(actionName)) end)
									SafeDbgPrint("[Stopper PetAction] slot=" .. tostring(i)
										.. " name=" .. safeStr(name)
										.. " actionName=" .. safeStr(actionName)
										.. " sid=" .. tostring(sid))
								end
							end
						end
					end
					if not resolved then
						resolved = resolveWarlockCommandDemonFallbackSpellId()
						if type(resolved) == "number" then
							SafeDbgPrint("[Stopper Command Demon] fallbackResolvedSpellId=" .. tostring(resolved))
						end
					end
					if type(resolved) == "number" then
						spellId = resolved
						if dl >= 5 then
							SafeDbgPrint("[Stopper Command Demon] resolvedSpellId=" .. tostring(spellId) .. " label=" .. safeStr(safeSpellLabel(spellId)))
						end
					end
				end
				Core._lastStopperSpellId = spellId
				if dl >= 5 and unit == "pet" then
					SafeDbgPrint("[Stopper Pet SUCCEEDED] spellId=" .. tostring(spellId) .. " label=" .. safeStr(safeSpellLabel(spellId)))
				end

				if INTERRUPT_SPELL_IDS[spellId] then
					Core._lastInterruptAttemptAt = GetTime and GetTime() or 0
					Core._lastInterruptAttemptSpellId = spellId
					-- Cache the spell name at cast time to avoid per-mob GetSpellInfo variability
					Core._lastInterruptSpellName = safeSpellLabel(spellId)
					Core._lastCastStopSpellName = nil
					-- Determine target from priority: target > focus > mouseover > nameplates
					local targetUnit = nil
					local targetGUID = nil
					local targetName = nil
					if UnitGUID and UnitGUID("target") then
						targetUnit = "target"
						targetGUID = UnitGUID("target")
						targetName = UnitName and UnitName("target")
					elseif UnitGUID and UnitGUID("focus") then
						targetUnit = "focus"
						targetGUID = UnitGUID("focus")
						targetName = UnitName and UnitName("focus")
					elseif UnitGUID and UnitGUID("mouseover") then
						targetUnit = "mouseover"
						targetGUID = UnitGUID("mouseover")
						targetName = UnitName and UnitName("mouseover")
					else
						-- Fallback to nameplates if available
						for i = 1, 40 do
							local unit = ("nameplate%d"):format(i)
							if UnitGUID then
								local okG, g = pcall(UnitGUID, unit)
								if okG and type(g) == "string" and ZSBT.IsSafeString and ZSBT.IsSafeString(g) then
									targetUnit = unit
									targetGUID = g
									targetName = UnitName and UnitName(unit)
									break
								end
							end
						end
					end
					Core._lastInterruptTargetGUID = targetGUID
					Core._lastInterruptTargetName = targetName
					Core._lastInterruptTargetUnit = targetUnit
					Core._lastInterruptTargetCastSpellId = nil
					if Core._unitLastCastSpellId and type(Core._unitLastCastSpellId["target"]) == "number" then
						Core._lastInterruptTargetCastSpellId = Core._unitLastCastSpellId["target"]
					end
					pcall(function()
						if UnitCastingInfo then
							local castSpellId = select(9, UnitCastingInfo("target"))
							if type(castSpellId) == "number" then
								Core._lastInterruptTargetCastSpellId = castSpellId
							end
						end
						if UnitChannelInfo and not Core._lastInterruptTargetCastSpellId then
							local chSpellId = select(8, UnitChannelInfo("target"))
							if type(chSpellId) == "number" then
								Core._lastInterruptTargetCastSpellId = chSpellId
							end
						end
					end)
					if dl >= 4 then
						SafeDbgPrint("[Interrupt Attempt] spellId=" .. tostring(spellId) .. " targetCastSpellId=" .. tostring(Core._lastInterruptTargetCastSpellId))
					end
					if dl >= 5 then
						-- Avoid printing spell names directly (can be secret strings in 12.x).
						SafeDbgPrint("[Interrupt Attempt] castSpellName=" .. safeStr((type(Core._lastInterruptTargetCastSpellId) == "number" and GetSpellInfo) and (select(1, GetSpellInfo(Core._lastInterruptTargetCastSpellId))) or nil))
					end

				end

				local castStopsEnabled = Core:IsNotificationCategoryEnabled("caststops")
				if castStopsEnabled and CASTSTOP_SPELL_IDS[spellId] then
					Core._lastCastStopAttemptAt = GetTime and GetTime() or 0
					Core._lastCastStopAttemptSpellId = spellId
					-- Cache the spell name at cast time to avoid per-mob GetSpellInfo variability
					Core._lastCastStopSpellName = safeSpellLabel(spellId)
					Core._lastInterruptSpellName = nil

					-- Determine target from priority: target > focus > mouseover > nameplates
					local targetUnit = nil
					local targetGUID = nil
					local targetName = nil
					if UnitGUID and UnitGUID("target") then
						targetUnit = "target"
						targetGUID = UnitGUID("target")
						targetName = UnitName and UnitName("target")
					elseif UnitGUID and UnitGUID("focus") then
						targetUnit = "focus"
						targetGUID = UnitGUID("focus")
						targetName = UnitName and UnitName("focus")
					elseif UnitGUID and UnitGUID("mouseover") then
						targetUnit = "mouseover"
						targetGUID = UnitGUID("mouseover")
						targetName = UnitName and UnitName("mouseover")
					else
						-- Fallback to nameplates if available
						for i = 1, 40 do
							local unit = ("nameplate%d"):format(i)
							if UnitGUID then
								local okG, g = pcall(UnitGUID, unit)
								if okG and type(g) == "string" and ZSBT.IsSafeString and ZSBT.IsSafeString(g) then
									targetUnit = unit
									targetGUID = g
									targetName = UnitName and UnitName(unit)
									break
								end
							end
						end
					end

					Core._lastCastStopTargetGUID = targetGUID
					Core._lastCastStopTargetName = targetName
					Core._lastCastStopTargetUnit = targetUnit
					-- Some clients do not reliably fire UNIT_SPELLCAST_START for nameplate units
					-- or under certain UI setups. If the target is currently casting at the moment
					-- we attempt a cast-stop, backfill the cast-start timestamp so later validation
					-- can succeed.
					pcall(function()
						if targetUnit and (UnitCastingInfo or UnitChannelInfo) then
							local castSpellId = nil
							if UnitCastingInfo then
								castSpellId = select(9, UnitCastingInfo(targetUnit))
							end
							if not castSpellId and UnitChannelInfo then
								castSpellId = select(8, UnitChannelInfo(targetUnit))
							end
							if type(castSpellId) == "number" then
								Core._unitLastCastAt = Core._unitLastCastAt or {}
								Core._unitLastCastAt[targetUnit] = Core._lastCastStopAttemptAt
							end
						end
					end)

					-- Snapshot target cast info so we can report which spell was stopped.
					Core._lastCastStopSpellId = nil
					if Core._unitLastCastSpellId and targetUnit and type(Core._unitLastCastSpellId[targetUnit]) == "number" then
						Core._lastCastStopSpellId = Core._unitLastCastSpellId[targetUnit]
					end
					Core._lastCastStopSeenAt = (Core._unitLastCastAt and targetUnit and Core._unitLastCastAt[targetUnit]) or nil
					Core._lastCastStopEmittedAt = nil
					pcall(function()
						if UnitCastingInfo and targetUnit then
							local castSpellId = select(9, UnitCastingInfo(targetUnit))
							if type(castSpellId) == "number" then
								Core._lastCastStopSpellId = castSpellId
							end
						end
						if UnitChannelInfo and not Core._lastCastStopSpellId and targetUnit then
							local chSpellId = select(8, UnitChannelInfo(targetUnit))
							if type(chSpellId) == "number" then
								Core._lastCastStopSpellId = chSpellId
							end
						end
					end)

					-- Poll fallback: some clients don't fire UNIT_SPELLCAST_STOP/FAILED reliably for stuns.
					pcall(function()
						if not C_Timer or not C_Timer.After then return end
						local attemptAt = Core._lastCastStopAttemptAt
						local targetGUID = Core._lastCastStopTargetGUID
						local targetUnit = Core._lastCastStopTargetUnit
						local castSpellId = Core._lastCastStopSpellId
						local seenAt = Core._lastCastStopSeenAt
						local function poll()
							if not Core:IsMasterEnabled() then return end
							if not Core:IsNotificationCategoryEnabled("caststops") then return end
							if not attemptAt or (GetTime() - attemptAt) > 0.45 then return end
							if Core._lastCastStopEmittedAt and (GetTime() - Core._lastCastStopEmittedAt) < 0.50 then return end
							if targetGUID and UnitGUID and targetUnit then
								local cur = UnitGUID(targetUnit)
								if type(cur) == "string" and type(targetGUID) == "string" and ZSBT.IsSafeString and ZSBT.IsSafeString(cur) and ZSBT.IsSafeString(targetGUID) then
									if cur ~= targetGUID then return end
								end
							end
							-- Require that we actually saw the cast start very recently (reduces false positives
							-- for casts ending naturally near the attempt time).
							if not seenAt or (attemptAt - seenAt) > 0.25 then return end

							local dl2 = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("notifications"))
								or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
							if dl2 >= 5 then
								SafeDbgPrint("[CastStop Poll] dt=" .. string.format("%.3f", (GetTime() - attemptAt)) .. " castSpellId=" .. tostring(castSpellId))
							end

							local s1 = nil
							local s2 = nil
							pcall(function()
								if UnitCastingInfo and targetUnit then s1 = select(9, UnitCastingInfo(targetUnit)) end
								if UnitChannelInfo and targetUnit then s2 = select(8, UnitChannelInfo(targetUnit)) end
							end)
							local stillCasting = (type(s1) == "number") or (type(s2) == "number")
							if stillCasting then
								-- In instanced content (Delves), spellIDs can become "secret" and comparing them can taint.
								-- If the unit is still casting/channeling, keep waiting rather than trying to match spell IDs.
								return
							end

							-- Cast disappeared early: emit caststop immediately.
							local tn = Core._lastCastStopTargetName
							local sn = nil
							if type(castSpellId) == "number" and GetSpellInfo then
								local n = GetSpellInfo(castSpellId)
								if type(n) == "string" and n ~= "" and (not ZSBT.IsSafeString or ZSBT.IsSafeString(n)) then
									sn = n
								end
							end
							if type(sn) ~= "string" or sn == "" then
								if type(castSpellId) == "number" then
									sn = "SpellID:" .. tostring(castSpellId)
								else
									sn = "Spell"
								end
							end
							if dl2 >= 5 then
								SafeDbgPrint("[CastStop Emit] target=" .. safeStr(tn) .. " spellId=" .. tostring(castSpellId) .. " spellName=" .. safeStr(sn))
							end
							local tpl = getTemplate("caststops", L["Stopped: %e (%t)"])
							local out = applyTemplate(tpl, { e = sn, t = tn })
							if out and out ~= "" then
								Core._lastCastStopEmittedAt = GetTime()
								Core:EmitNotification(out, { r = 1.0, g = 0.6, b = 0.0 }, "caststops")
							end
						end
						C_Timer.After(0.05, poll)
						C_Timer.After(0.12, poll)
						C_Timer.After(0.25, poll)
					end)

					if dl >= 4 then
						SafeDbgPrint("[CastStop Attempt] spellId=" .. tostring(spellId) .. " castSpellId=" .. tostring(Core._lastCastStopSpellId))
					end
				end
			end
			return
		end

		-- Clear pending cast timing when a watched unit successfully completes a cast.
		-- This prevents stale timing from causing later false attributions.
		if event == "UNIT_SPELLCAST_SUCCEEDED" then
			local unit = msg
			if type(unit) == "string" then
				if unit == "target" or unit == "focus" or unit == "mouseover" or unit:match("^nameplate") then
					if Core._pendingCasts and Core._pendingCasts[unit] then
						Core._pendingCasts[unit] = nil
					end
				end
			end
			return
		end

		local isCastEndEvent = (event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED")
		if isCastEndEvent then
			local unit, castGuid, interruptedSpellId = msg, ...
			local tNow = GetTime and GetTime() or 0
			local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("notifications"))
				or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
			local lastInterruptAt = Core._lastInterruptAttemptAt or 0
			local lastCastStopAt = Core._lastCastStopAttemptAt or 0

			if type(unit) ~= "string" then return end
			if unit ~= "target" and unit ~= "focus" and unit ~= "mouseover" and (not unit:match("^nameplate")) then
				return
			end

			-- Validate if this was an early stop (interrupt) vs natural completion.
			-- IMPORTANT: In some restricted content (e.g. Delves), cast timestamps can be secret/tainted.
			-- Only enforce early-stop gating when we have a safe endTime; otherwise fall back to timing heuristics.
			local pendingCast = Core._pendingCasts and Core._pendingCasts[unit]
			local hasSafeTiming = (pendingCast and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(pendingCast.endTime)) or false
			local isEarlyStop = false
			if hasSafeTiming then
				local timeToEnd = pendingCast.endTime - tNow
				if timeToEnd > 0.15 then
					isEarlyStop = true
				end
				if dl >= 5 then
					SafeDbgPrint("[Cast End Validation] unit=" .. tostring(unit) .. " event=" .. tostring(event) .. " timeToEnd=" .. string.format("%.3f", timeToEnd) .. " isEarlyStop=" .. tostring(isEarlyStop))
				end
			end

			local function sawCastStartRecently(unitKey, attemptAt)
				if not attemptAt then return false end
				local seenAt = (Core._unitLastCastAt and Core._unitLastCastAt[unitKey]) or nil
				if type(seenAt) ~= "number" then return false end
				return (attemptAt - seenAt) >= 0 and (attemptAt - seenAt) <= 0.25
			end

			-- Prefer true interrupt attribution when within window.
			if (tNow - lastInterruptAt) <= 0.60 then
				-- For UNIT_SPELLCAST_INTERRUPTED, always allow (explicit interrupt)
				-- For STOP/FAILED, require early-stop validation only when safe timing data is available.
				-- Otherwise, fall back to a conservative heuristic: we must have just seen the cast start.
				if event ~= "UNIT_SPELLCAST_INTERRUPTED" then
					if hasSafeTiming then
						if not isEarlyStop then
							if dl >= 4 then
								SafeDbgPrint("[Interrupt Rejected] unit=" .. tostring(unit) .. " event=" .. tostring(event) .. " not early enough")
							end
							return
						end
					else
						if not sawCastStartRecently(unit, lastInterruptAt) then
							if dl >= 4 then
								SafeDbgPrint("[Interrupt Rejected] unit=" .. tostring(unit) .. " event=" .. tostring(event) .. " no recent cast start")
							end
							return
						end
					end
				end
				if dl >= 4 then
					SafeDbgPrint("[Interrupt Unit] event=" .. tostring(event) .. " unit=" .. tostring(unit) .. " spellId=" .. tostring(interruptedSpellId) .. " dt=" .. string.format("%.3f", (tNow - lastInterruptAt)))
				end
				spellName = ""
				local okName, uName = pcall(function() return UnitName and UnitName(unit) end)
				if okName and type(uName) == "string" and ZSBT.IsSafeString and ZSBT.IsSafeString(uName) then
					if uName ~= "" then
						targetName = uName
					end
				end
				if not targetName then
					if type(Core._lastInterruptTargetName) == "string" and ZSBT.IsSafeString and ZSBT.IsSafeString(Core._lastInterruptTargetName) then
						targetName = Core._lastInterruptTargetName
					end
				end
				emitCategory = "interrupts"
				templateKey = "interrupts"
			end

			-- If not a true interrupt, attempt cast-stop attribution if enabled.
			if not emitCategory and Core:IsNotificationCategoryEnabled("caststops") and (tNow - lastCastStopAt) <= 0.40 then
				-- Require early-stop validation only when safe timing is available.
				-- Otherwise require that we just saw the cast start near the cast-stop attempt.
				if event == "UNIT_SPELLCAST_INTERRUPTED" then
					-- Explicit cast interrupt event: trust it even if we didn't observe cast start.
				elseif hasSafeTiming then
					if not isEarlyStop then
						if dl >= 4 then
							SafeDbgPrint("[CastStop Rejected] unit=" .. tostring(unit) .. " event=" .. tostring(event) .. " not early enough")
						end
						return
					end
				else
					if not sawCastStartRecently(unit, lastCastStopAt) then
						if dl >= 4 then
							SafeDbgPrint("[CastStop Rejected] unit=" .. tostring(unit) .. " event=" .. tostring(event) .. " no recent cast start")
						end
						return
					end
				end
				local expectedGUID = Core._lastCastStopTargetGUID
				local unitGUID = UnitGUID and UnitGUID(unit) or nil
				if expectedGUID and unitGUID then
					if type(expectedGUID) == "string" and type(unitGUID) == "string" and ZSBT.IsSafeString and ZSBT.IsSafeString(expectedGUID) and ZSBT.IsSafeString(unitGUID) then
						if expectedGUID ~= unitGUID then return end
					end
				end

				if dl >= 4 then
					SafeDbgPrint("[CastStop Unit] event=" .. tostring(event) .. " unit=" .. tostring(unit) .. " dt=" .. string.format("%.3f", (tNow - lastCastStopAt)))
				end

				targetName = nil
				if type(Core._lastCastStopTargetName) == "string" and ZSBT.IsSafeString and ZSBT.IsSafeString(Core._lastCastStopTargetName) then
					targetName = Core._lastCastStopTargetName
				end
				if not targetName then
					local okName, uName = pcall(function() return UnitName and UnitName(unit) end)
					if okName and type(uName) == "string" and ZSBT.IsSafeString and ZSBT.IsSafeString(uName) then
						if uName ~= "" then
							targetName = uName
						end
					end
				end
				spellName = ""
				emitCategory = "caststops"
				templateKey = "caststops"
			end
		end
		if emitCategory then
			-- Clean up pending cast state for this unit since we've processed the interrupt/caststop
			if Core._pendingCasts and Core._pendingCasts[unit] then
				Core._pendingCasts[unit] = nil
			end
			local t = GetTime and GetTime() or 0
			Core._notifDedup = Core._notifDedup or {}
			local attemptAt = nil
			local guid = nil
			if emitCategory == "caststops" then
				attemptAt = Core._lastCastStopAttemptAt
				guid = Core._lastCastStopTargetGUID
			else
				attemptAt = Core._lastInterruptAttemptAt
				guid = Core._lastInterruptTargetGUID
			end
			if not guid and UnitGUID and type(unit) == "string" then
				local okG, g = pcall(function() return UnitGUID(unit) end)
				if okG and type(g) == "string" and (not ZSBT.IsSafeString or ZSBT.IsSafeString(g)) then
					guid = g
				end
			end
			local safeGuid = (guid and ZSBT.IsSafeString and ZSBT.IsSafeString(guid)) and guid or ""
			local key = tostring(emitCategory) .. ":" .. tostring(attemptAt or 0) .. ":" .. safeGuid
			local lastKeyAt = Core._notifDedup[key]
			if type(lastKeyAt) == "number" and (t - lastKeyAt) >= 0 and (t - lastKeyAt) < 0.80 then
				return
			end
			Core._notifDedup[key] = t
			if Core._lastNotifCat == emitCategory and (t - (Core._lastNotifAt or 0)) < 0.35 then
				return
			end
			Core._lastNotifCat = emitCategory
			Core._lastNotifAt = t

			local stopperLabel = nil
			if emitCategory == "caststops" then
				stopperLabel = Core._lastCastStopSpellName or safeSpellLabel(Core._lastStopperSpellId)
			else
				stopperLabel = Core._lastInterruptSpellName or safeSpellLabel(Core._lastStopperSpellId)
			end
			local playerName = UnitName and UnitName("player") or ""
			local tpl = getTemplate(templateKey or emitCategory, L["%t Interrupted!"])
			local out = applyTemplate(tpl, { e = "", p = playerName, s = stopperLabel, t = targetName })
			if out and out ~= "" then
				if emitCategory == "caststops" then
					Core._lastCastStopEmittedAt = t
				end
				Core:EmitInterruptAlert(out, emitCategory, { p = playerName, s = stopperLabel, t = targetName })
			end
			return
		end

		-- COMBAT_TEXT_UPDATE interrupt (often available even when CLEU is restricted).
		if event == "COMBAT_TEXT_UPDATE" then
			local ctType = msg
			if ctType == "SPELL_INTERRUPT" then
				local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("notifications"))
					or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
				local a1, a2, a3, a4 = ...
				if dl >= 4 then
					SafeDbgPrint("[Interrupt CT] a1=" .. safeStr(a1) .. " a2=" .. safeStr(a2) .. " a3=" .. safeStr(a3) .. " a4=" .. safeStr(a4))
				end
				if type(a1) == "string" and a1 ~= "" then targetName = a1 end
				if type(a2) == "string" and a2 ~= "" then spellName = a2 end
				if not spellName and type(a3) == "string" and a3 ~= "" then spellName = a3 end
			end
		end

		-- Fallback: parse chat messages.
		if not spellName then
			if not msg or type(msg) ~= "string" then return end
			if not ZSBT.IsSafeString(msg) then return end

			if interruptPat then
				local a, b = msg:match(interruptPat)
				if a and b then
					if type(a) == "string" and type(b) == "string" then
						spellName = a
						targetName = b
					end
				end
			end

			if not spellName then
				local a, b = msg:match(L["You interrupt (.+)'s (.+)%.?"])
				if a and b then
					b = b:gsub("%s+$", "")
					b = b:gsub("%.$", "")
					targetName = a
					spellName = b
				end
			end

			if not spellName then
				local m = msg:lower()
				if not m:find("interrupt", 1, true) then
					return
				end
				spellName = msg
			end
		end

		local t = GetTime and GetTime() or 0
		if Core._lastNotifCat == "interrupts" and (t - (Core._lastNotifAt or 0)) < 0.35 then
			return
		end
		Core._lastNotifCat = "interrupts"
		Core._lastNotifAt = t

		emitCategory = "interrupts"
		local tpl = getTemplate("interrupts", L["Interrupted: %e"])
		local out = applyTemplate(tpl, { e = spellName, t = targetName })
		if out and out ~= "" then
			Core:EmitNotification(out, { r = 1.0, g = 0.6, b = 0.0 }, emitCategory)
		end
	end)
end

function Core:InitKillAnnouncer()
	if self._killAnnouncerFrame then return end
	self._killAnnouncerFrame = CreateFrame("Frame")
	pcall(function() self._killAnnouncerFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH") end)
	pcall(function() self._killAnnouncerFrame:RegisterEvent("CHAT_MSG_COMBAT_LOG") end)
	pcall(function() self._killAnnouncerFrame:RegisterEvent("CHAT_MSG_COMBAT_MISC_INFO") end)
	pcall(function() self._killAnnouncerFrame:RegisterEvent("CHAT_MSG_SYSTEM") end)
	Core._utKillCreditOnly = Core._utKillCreditOnly or false
	Core._utKillCreditSeen = Core._utKillCreditSeen or false
	local okKillingBlow = pcall(function() self._killAnnouncerFrame:RegisterEvent("PLAYER_KILLING_BLOW") end)
	-- Note: successful registration does NOT mean the event will actually fire on this client.
	-- Only suppress fallbacks after we observe a real kill-credit event.
	pcall(function() self._killAnnouncerFrame:RegisterEvent("COMBAT_TEXT_UPDATE") end)
	pcall(function() self._killAnnouncerFrame:RegisterUnitEvent("UNIT_HEALTH", "target") end)
	pcall(function() self._killAnnouncerFrame:RegisterUnitEvent("UNIT_HEALTH_FREQUENT", "target") end)
	pcall(function() self._killAnnouncerFrame:RegisterEvent("PLAYER_TARGET_CHANGED") end)
	Core._utLastTargetDead = Core._utLastTargetDead or nil
	Core._utLastTargetName = Core._utLastTargetName or nil
	Core._utLastTargetSeenAt = Core._utLastTargetSeenAt or 0

	local function dbgSafe(v)
		if v == nil then return "nil" end
		if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
		if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
		if type(v) == "number" then return tostring(v) end
		if type(v) == "boolean" then return tostring(v) end
		return "<secret>"
	end

	local function SafePrint(msg)
		if not (ZSBT and ZSBT.Addon and ZSBT.Addon.Print) then return end
		if ZSBT.IsSafeString and not ZSBT.IsSafeString(msg) then return end
		ZSBT.Addon:Print(msg)
	end

	local function FireUT(targetName)
		local t = GetTime and GetTime() or 0
		local perKillWindowSec = 12.0
		local maxChainDurationSec = 30.0

		local lastAt = Core._utKillLastAt or 0
		local startAt = Core._utChainStartAt or 0
		local withinRolling = (t - lastAt) <= perKillWindowSec
		local withinCap = (startAt > 0) and ((t - startAt) <= maxChainDurationSec) or true

		if withinRolling and withinCap then
			Core._utKillChain = (Core._utKillChain or 0) + 1
		else
			Core._utKillChain = 1
			Core._utChainStartAt = t
		end
		Core._utKillLastAt = t
		if not Core._utChainStartAt or Core._utChainStartAt == 0 then
			Core._utChainStartAt = t
		end

		local n = Core._utKillChain or 1
		local tier = tonumber(n) or 1
		if tier < 1 then tier = 1 end
		if tier > 7 then tier = 7 end
		local eventType = "UT_KILL_" .. tostring(tier)
		local trg = ZSBT.Core and ZSBT.Core.Triggers
		if trg and trg.FireEvent and type(eventType) == "string" then
			trg:FireEvent(eventType, {
				eventType = eventType,
				event = eventType,
				unit = "player",
				value = targetName,
				count = n,
			})
		end
	end

	self._killAnnouncerFrame:SetScript("OnEvent", function(_, event, msg, ...)
		if not Core:IsMasterEnabled() then return end
		local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("notifications"))
			or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
		if event == "COMBAT_TEXT_UPDATE" then
			local ctType = msg
			if ctType ~= "PARTYKILL" and ctType ~= "PARTY_KILL" then return end
			Core._utKillCreditSeen = true
			Core._utKillCreditOnly = true
			local tn = select(1, ...)
			if not (ZSBT.IsSafeString and ZSBT.IsSafeString(tn)) then
				tn = nil
			end
			if not tn or tn == "" then
				tn = (ZSBT.IsSafeString and ZSBT.IsSafeString(Core._utLastTargetName) and Core._utLastTargetName ~= "") and Core._utLastTargetName or nil
			end
			if dl >= 4 then
				SafePrint("|cFF00CC66[UT]|r ct PARTYKILL tn=" .. dbgSafe(tn or nil))
			end
			FireUT(tn or "Target")
			return
		end
		if event == "PLAYER_KILLING_BLOW" then
			Core._utKillCreditSeen = true
			Core._utKillCreditOnly = true
			local tn = nil
			if ZSBT.IsSafeString and ZSBT.IsSafeString(msg) and msg ~= "" then
				tn = msg
			elseif ZSBT.IsSafeString and ZSBT.IsSafeString(Core._utLastTargetName) and Core._utLastTargetName ~= "" then
				tn = Core._utLastTargetName
			end
			if dl >= 4 then
				SafePrint("|cFF00CC66[UT]|r killingblow tn=" .. dbgSafe(tn or nil))
			end
			FireUT(tn or "Target")
			return
		end
		if event == "PLAYER_TARGET_CHANGED" then
			local hasTarget = false
			local okExists, exists = pcall(function()
				return UnitExists and UnitExists("target")
			end)
			if okExists and exists == true then
				hasTarget = true
			end

			-- If the player is tab-targeting and switching to a NEW target, do not infer a kill.
			-- Only consider a kill inference when the target is CLEARED (no target).
			if hasTarget then
				Core._utLastTargetSeenAt = GetTime and GetTime() or 0
				local tn = UnitName and UnitName("target")
				if ZSBT.IsSafeString and ZSBT.IsSafeString(tn) and tn ~= "" then
					Core._utLastTargetName = tn
				end
				return
			end

			-- Target cleared: can happen on death for some clients.
			local tNow = GetTime and GetTime() or 0
			local lastSeenAge = (Core._utLastTargetSeenAt and (tNow - Core._utLastTargetSeenAt)) or nil
			local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
			local lastAt = ec and ec._lastOutgoingCombatAt
			local lastName = ec and ec._lastOutgoingCombatTargetName
			local outAge = (lastAt and (tNow - lastAt)) or nil
			local tn = Core._utLastTargetName
			local nameMatch = false
			if ZSBT.IsSafeString and ZSBT.IsSafeString(tn) and ZSBT.IsSafeString(lastName) and tn ~= "" and lastName ~= "" then
				nameMatch = (tn == lastName)
			end
			local inCombat = false
			pcall(function()
				if UnitAffectingCombat then
					inCombat = (UnitAffectingCombat("player") == true)
				end
			end)
			if dl >= 4 then
				SafePrint("|cFF00CC66[UT]|r targetclear lastDead=" .. dbgSafe(Core._utLastTargetDead)
					.. " lastSeenAge=" .. dbgSafe(lastSeenAge)
					.. " outAge=" .. dbgSafe(outAge)
					.. " nameMatch=" .. dbgSafe(nameMatch)
					.. " combat=" .. dbgSafe(inCombat))
			end
			-- Avoid false positives: only infer kill if the cleared target matches our last outgoing attribution.
			-- Note: UNIT_HEALTH may not tick every frame in some clients, so lastSeenAge can be >1s.
			local minGapSec = 0.25
			local sinceLastUt = (Core._utKillLastAt and (tNow - Core._utKillLastAt)) or nil
			if inCombat and (not sinceLastUt or sinceLastUt >= minGapSec)
				and nameMatch
				and outAge and outAge <= 0.90
				and lastSeenAge and lastSeenAge <= 2.0 then
				FireUT(tn)
			end
			Core._utLastTargetDead = nil
			Core._utLastTargetName = nil
			Core._utLastTargetSeenAt = 0
			return
		end

		if event == "UNIT_HEALTH" or event == "UNIT_HEALTH_FREQUENT" then
			if Core._utKillCreditOnly and Core._utKillCreditSeen then
				if dl >= 4 then
					SafePrint(L["|cFF00CC66[UT]|r suppress UNIT_HEALTH (killCreditOnly=true)"])
				end
				return
			end
			local unit = msg
			if unit ~= "target" then return end
			local okDead, isDead = pcall(function()
				if UnitIsDeadOrGhost then
					return UnitIsDeadOrGhost("target")
				end
				if UnitIsDead then
					return UnitIsDead("target")
				end
				return false
			end)
			if not okDead or type(isDead) ~= "boolean" then return end
			local prevDead = Core._utLastTargetDead
			Core._utLastTargetDead = isDead
			Core._utLastTargetSeenAt = GetTime and GetTime() or 0
			local tn = UnitName and UnitName("target")
			if ZSBT.IsSafeString and ZSBT.IsSafeString(tn) and tn ~= "" then
				Core._utLastTargetName = tn
			end
			if prevDead == nil then return end
			if prevDead == false and isDead == true then
				local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
				local lastAt = ec and ec._lastOutgoingCombatAt
				local lastName = ec and ec._lastOutgoingCombatTargetName
				local tNow = GetTime and GetTime() or 0
				local age = (lastAt and (tNow - lastAt)) or nil
				local tnSafe = (ZSBT.IsSafeString and ZSBT.IsSafeString(tn))
				local lastSafe = (ZSBT.IsSafeString and ZSBT.IsSafeString(lastName))
				if dl >= 4 then
					SafePrint(L["|cFF00CC66[UT]|r killcheck deadEdge=true"]
						.. " age=" .. dbgSafe(age)
						.. " tn=" .. dbgSafe(tnSafe and tn or nil)
						.. " last=" .. dbgSafe(lastSafe and lastName or nil))
				end

				-- Attribution:
				-- 1) Best: match safe target name to last outgoing target name.
				-- 2) Fallback: if we cannot safely compare names (secret strings), rely on a recent outgoing hit.
				if lastAt and age and age <= 1.5 then
					if tnSafe and tn ~= "" and lastSafe and tn == lastName then
						FireUT(tn)
					elseif not lastSafe then
						FireUT(tnSafe and tn or "Target")
					end
				end
			end
			return
		end

		if type(msg) ~= "string" then return end

		local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("notifications"))
			or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
		local msgIsSafe = (not ZSBT.IsSafeString) or (ZSBT.IsSafeString and ZSBT.IsSafeString(msg))
		if dl >= 4 and ZSBT.Addon and ZSBT.Addon.Print then
			local safeMsg = msgIsSafe and msg or "<secret>"
			ZSBT.Addon:Print("|cFF00CC66[UT]|r evt=" .. tostring(event) .. " msg=" .. tostring(safeMsg))
		end
		if not msgIsSafe then return end

		local function extractTarget(m)
			if type(m) ~= "string" then return nil end
			local t = m:match(L["You have slain (.+)"])
			if t then
				t = t:gsub("[!.]+$", "")
				return t
			end
			t = m:match(L["You have killed (.+)"])
			if t then
				t = t:gsub("[!.]+$", "")
				return t
			end
			return nil
		end

		local target = extractTarget(msg)
		if not target then return end
		FireUT(target)
	end)
end

function Core:IsNotificationCategoryEnabled(category)
	if type(category) ~= "string" or category == "" then return true end
	local p = ZSBT.db and ZSBT.db.profile
	local n = p and p.notifications
	local v = n and n[category]
	if v == nil then return true end
	return v ~= false
end

function Core:GetNotificationScrollArea(category)
	local p = ZSBT.db and ZSBT.db.profile
	local routing = p and p.notificationsRouting
	local area = routing and routing[category] or nil
	if type(area) ~= "string" or area == "" then
		area = "Notifications"
	end
	local scrollAreas = p and p.scrollAreas
	if type(scrollAreas) ~= "table" or type(scrollAreas[area]) ~= "table" then
		area = "Notifications"
	end
	return area
end

function Core:EmitInterruptAlert(text, category, ctx)
	if category and not self:IsNotificationCategoryEnabled(category) then
		return
	end
	pcall(function()
		local LibStub = _G.LibStub
		if not LibStub or type(LibStub.GetLibrary) ~= "function" then return end
		local lcp = LibStub:GetLibrary("LibCombatPulse-1.0", true)
		if not (lcp and lcp.Emit) then return end
		ctx = type(ctx) == "table" and ctx or {}
		local kind = (category == "interrupts") and "interrupt" or ((category == "caststops") and "cast_stop" or nil)
		if not kind then return end
		local et = (category == "interrupts") and "INTERRUPT" or ((category == "caststops") and "CAST_STOP" or "INTERRUPT")
		lcp:Emit({
			kind = kind,
			eventType = et,
			direction = "outgoing",
			spellId = tonumber(self._lastStopperSpellId),
			spellName = ctx.s,
			targetName = ctx.t,
			timestamp = (GetTime and GetTime()) or 0,
			confidence = "HIGH",
		})
	end)
	local p = ZSBT.db and ZSBT.db.profile
	local conf = p and p.interruptAlerts
	local area = (conf and type(conf.scrollArea) == "string" and conf.scrollArea ~= "") and conf.scrollArea or nil
	if not area then
		area = (type(category) == "string" and category ~= "" and self.GetNotificationScrollArea) and self:GetNotificationScrollArea(category) or "Notifications"
	end
	local scrollAreas = p and p.scrollAreas
	if type(scrollAreas) ~= "table" or type(scrollAreas[area]) ~= "table" then
		area = "Notifications"
	end
	local color = (conf and type(conf.color) == "table") and conf.color or nil
	if type(color) ~= "table" then
		color = { r = 1.0, g = 0.6, b = 0.0 }
	end
	local meta = { kind = "notification" }
	if conf and conf.fontOverride == true then
		meta.spellFontOverride = true
		meta.spellFontFace = (type(conf.fontFace) == "string" and conf.fontFace ~= "") and conf.fontFace or nil
		meta.spellFontOutline = (type(conf.fontOutline) == "string" and conf.fontOutline ~= "") and conf.fontOutline or nil
		meta.spellFontSize = tonumber(conf.fontSize)
	end

	if conf and conf.soundEnabled == true and ZSBT.PlayLSMSound then
		local soundKey = conf.sound
		if type(soundKey) == "string" and soundKey ~= "" and soundKey ~= "None" then
			ZSBT.PlayLSMSound(soundKey)
		end
	end

	pcall(function()
		if not (conf and conf.chatEnabled == true) then return end
		-- Announce only for true interrupts by default.
		if category ~= "interrupts" then return end
		if type(conf.chatTemplate) ~= "string" or conf.chatTemplate == "" then return end
		ctx = type(ctx) == "table" and ctx or {}
		local pName = tostring(ctx.p or (UnitName and UnitName("player")) or "")
		local sName = tostring(ctx.s or "")
		local tName = tostring(ctx.t or "")
		local msg = conf.chatTemplate
		msg = msg:gsub("%%p", pName)
		msg = msg:gsub("%%s", sName)
		msg = msg:gsub("%%t", tName)
		-- Ensure final message is safe before sending.
		if ZSBT.IsSafeString and not ZSBT.IsSafeString(msg) then return end
		-- Use local chat output instead of SendChatMessage (protected).
		if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
			DEFAULT_CHAT_FRAME:AddMessage(msg)
		elseif ChatFrame1 and ChatFrame1.AddMessage then
			ChatFrame1:AddMessage(msg)
		elseif ZSBT and ZSBT.Addon and ZSBT.Addon.Print then
			ZSBT.Addon:Print(msg)
		end
	end)

	if ZSBT.DisplayText then
		ZSBT.DisplayText(area, text, color, meta)
	elseif self.Display and self.Display.Emit then
		self.Display:Emit(area, text, color, meta)
	end
end

function Core:EmitNotificationTemplate(category, fallbackTpl, ctx, fallbackColor)
	if category and not self:IsNotificationCategoryEnabled(category) then
		return
	end
	local p = ZSBT.db and ZSBT.db.profile
	local t = p and p.notificationsTemplates
	local tpl = (t and type(t[category]) == "string" and t[category] ~= "") and t[category] or fallbackTpl
	if type(tpl) ~= "string" or tpl == "" then return end
	ctx = type(ctx) == "table" and ctx or {}
	local function coerceSafe(v)
		if type(v) ~= "string" then v = tostring(v or "") end
		if ZSBT.IsSafeString and not ZSBT.IsSafeString(v) then
			return "<secret>"
		end
		return v
	end
	local out = tpl
	out = out:gsub("%%e", coerceSafe(ctx.e))
	out = out:gsub("%%a", coerceSafe(ctx.a))
	out = out:gsub("%%t", coerceSafe(ctx.t))
	out = out:gsub("%%s", coerceSafe(ctx.s))
	out = out:gsub("%%p", coerceSafe(ctx.p))
	if out and out ~= "" then
		self:EmitNotification(out, fallbackColor, category)
	end
end

function Core:GetNotificationPerTypeConfig(category)
	local p = ZSBT.db and ZSBT.db.profile
	local nt = p and p.notificationsPerType
	local conf = nt and nt[category]
	return type(conf) == "table" and conf or nil
end

function Core:EmitNotification(text, color, category, extraMeta)
	if category and not self:IsNotificationCategoryEnabled(category) then
		return
	end
	if category == "interrupts" or category == "caststops" then
		local area = "Notifications"
		if type(category) == "string" and category ~= "" and self.GetNotificationScrollArea then
			area = self:GetNotificationScrollArea(category)
		end
		local imeta = { kind = "notification", category = category }
		if type(extraMeta) == "table" then
			for k, v in pairs(extraMeta) do imeta[k] = v end
		end
		if ZSBT.DisplayText then
			ZSBT.DisplayText(area, text, color, imeta)
		elseif self.Display and self.Display.Emit then
			self.Display:Emit(area, text, color, imeta)
		end
		return
	end
	local area = "Notifications"
	if type(category) == "string" and category ~= "" and self.GetNotificationScrollArea then
		area = self:GetNotificationScrollArea(category)
	end
	local meta = { kind = "notification", category = category }
	local finalColor = color
	local conf = type(category) == "string" and category ~= "" and self.GetNotificationPerTypeConfig and self:GetNotificationPerTypeConfig(category) or nil
	if conf then
		local style = conf.style
		if type(style) == "table" then
			if type(style.color) == "table" and type(style.color.r) == "number" then
				finalColor = style.color
			end
			if style.fontOverride == true then
				meta.spellFontOverride = true
				meta.spellFontFace = (type(style.fontFace) == "string" and style.fontFace ~= "") and style.fontFace or nil
				meta.spellFontOutline = (type(style.fontOutline) == "string" and style.fontOutline ~= "") and style.fontOutline or nil
				meta.spellFontSize = tonumber(style.fontSize)
			end
		end
		local sconf = conf.sound
		if type(sconf) == "table" and sconf.enabled == true and ZSBT.PlayLSMSound then
			local soundKey = sconf.soundKey
			if type(soundKey) == "string" and soundKey ~= "" and soundKey ~= "None" then
				local handle = ZSBT.PlayLSMSound(soundKey)
				if category == "enterCombat" and sconf.stopOnLeaveCombat == true then
					self._enterCombatSoundHandle = handle
				end
			end
		end
	end
	if type(extraMeta) == "table" then
		for k, v in pairs(extraMeta) do meta[k] = v end
	end
	if ZSBT.DisplayText then
		ZSBT.DisplayText(area, text, finalColor, meta)
	elseif self.Display and self.Display.Emit then
		self.Display:Emit(area, text, finalColor, meta)
	end
end

function Core:EmitBuffNotification(spellID, text, color, category, extraMeta, isFade)
	if category and not self:IsNotificationCategoryEnabled(category) then
		return
	end
	if category == "interrupts" or category == "caststops" then
		local area = "Notifications"
		if type(category) == "string" and category ~= "" and self.GetNotificationScrollArea then
			area = self:GetNotificationScrollArea(category)
		end
		if type(spellID) == "number" then
			local csc = ZSBT and ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
			local rules = csc and csc.auraRules
			local rule = rules and rules[spellID]
			if type(rule) == "table" and type(rule.scrollArea) == "string" and rule.scrollArea ~= "" then
				area = rule.scrollArea
			end
		end
		local bmeta = { kind = "notification" }
		if type(extraMeta) == "table" then
			for k, v in pairs(extraMeta) do bmeta[k] = v end
		end
		if ZSBT.DisplayText then
			ZSBT.DisplayText(area, text, color, bmeta)
		elseif self.Display and self.Display.Emit then
			self.Display:Emit(area, text, color, bmeta)
		end
		return
	end
	local area = "Notifications"
	if type(category) == "string" and category ~= "" and self.GetNotificationScrollArea then
		area = self:GetNotificationScrollArea(category)
	end
	local rule = nil
	if type(spellID) == "number" then
		local csc = ZSBT and ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
		local rules = csc and csc.auraRules
		rule = rules and rules[spellID]
		if type(rule) ~= "table" or rule.enabled == false then rule = nil end
		if type(rule) == "table" and type(rule.scrollArea) == "string" and rule.scrollArea ~= "" then
			area = rule.scrollArea
		end
	end

	local meta = { kind = "notification" }
	local finalColor = color
	local conf = type(category) == "string" and category ~= "" and self.GetNotificationPerTypeConfig and self:GetNotificationPerTypeConfig(category) or nil
	-- Per-rule sound overrides the category sound when the rule defines one.
	-- Rules may define separate gain/fade sounds; an unset key falls back to
	-- the legacy shared soundKey so older configs keep working.
	local soundConf = conf and conf.sound
	local ruleSoundKey = nil
	if type(rule) == "table" and type(rule.sound) == "table" then
		soundConf = rule.sound
		if soundConf.enabled == true then
			if isFade == true then
				ruleSoundKey = soundConf.fadeKey or soundConf.soundKey
			else
				ruleSoundKey = soundConf.gainKey or soundConf.soundKey
			end
		end
	end
	if conf then
		local style = conf.style
		if type(style) == "table" then
			if type(style.color) == "table" and type(style.color.r) == "number" then
				finalColor = style.color
			end
			if style.fontOverride == true then
				meta.spellFontOverride = true
				meta.spellFontFace = (type(style.fontFace) == "string" and style.fontFace ~= "") and style.fontFace or nil
				meta.spellFontOutline = (type(style.fontOutline) == "string" and style.fontOutline ~= "") and style.fontOutline or nil
				meta.spellFontSize = tonumber(style.fontSize)
			end
		end
	end
	if type(soundConf) == "table" and soundConf.enabled == true and ZSBT.PlayLSMSound then
		local soundKey = ruleSoundKey or soundConf.soundKey
		if type(soundKey) == "string" and soundKey ~= "" and soundKey ~= "None" then
			ZSBT.PlayLSMSound(soundKey)
		end
	end
	if type(extraMeta) == "table" then
		for k, v in pairs(extraMeta) do meta[k] = v end
	end
	-- Per-rule presentation overrides (all opt-in; absent fields keep the
	-- category/default appearance). Mirrors the spellRules rule.style schema.
	if type(rule) == "table" then
		-- A configured rule owns the icon decision: strip inherited icons
		-- (cast-match/cache) unless the rule opts in via showIcon.
		if rule.showIcon ~= true then
			meta.spellIcon = nil
		end
		if rule.showIcon == true and meta.spellIcon == nil and type(spellID) == "number" then
			local tex = nil
			if C_Spell and C_Spell.GetSpellTexture then
				local okT, resT = pcall(C_Spell.GetSpellTexture, spellID)
				if okT and type(resT) == "number" then tex = resT end
			end
			if tex == nil and GetSpellTexture then
				local okT2, resT2 = pcall(GetSpellTexture, spellID)
				if okT2 and type(resT2) == "number" then tex = resT2 end
			end
			if tex ~= nil then meta.spellIcon = tex end
		end
		local style = rule.style
		if type(style) == "table" and style.fontOverride == true then
			local sc = tonumber(style.fontScale)
			local face = style.fontFace
			local outline = style.fontOutline
			local sz = tonumber(style.fontSize)
			if (type(face) == "string" and face ~= "") or (type(outline) == "string" and outline ~= "")
				or (type(sz) == "number" and sz > 0) or (type(sc) == "number" and sc > 0) then
				meta.spellFontOverride = true
				meta.spellFontFace = face
				meta.spellFontOutline = outline
				meta.spellFontSize = sz
				meta.spellFontScale = sc
			end
			local c = style.color
			if type(c) == "table" and type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
				finalColor = { r = c.r, g = c.g, b = c.b }
			end
		end
	end
	if ZSBT.DisplayText then
		ZSBT.DisplayText(area, text, finalColor, meta)
	elseif self.Display and self.Display.Emit then
		self.Display:Emit(area, text, finalColor, meta)
	end
end

------------------------------------------------------------------------
-- Buff / Debuff Tracking
-- Watches UNIT_AURA on "player" for buff gains and fades.
-- Tracks by NAME (not spellId) for Midnight dungeon compatibility
-- where spellId may be tainted/secret.
------------------------------------------------------------------------
Core._trackedAuraNames = {}  -- [name] = true (currently active)
Core._auraInstanceMap = {}   -- [auraInstanceID] = name
Core._auraInstanceSpellIDs = {} -- [auraInstanceID] = spellID (helpful auras only)
Core._auraInstanceHarmfulSpellIDs = {} -- [auraInstanceID] = spellID (harmful auras only)
Core._auraInstanceIsHarmful = {} -- [auraInstanceID] = boolean
Core._auraRuleLastShown = nil  -- [spellID] = { gain=ts, fade=ts }
Core._recentBuffStats = nil -- runtime-only: [spellID] = { count=N, lastSeen=ts }
Core._auraReadAt = nil          -- last readable UNIT_AURA payload (combat-text dedup)
Core._lastUnreadAuraAt = nil    -- last secret/unreadable UNIT_AURA payload (recast pairing)
Core._pairedAuraActive = nil   -- [spellID] = gain timestamp for cast-paired secret buffs
Core._auraInstanceExpires = Core._auraInstanceExpires or {} -- [instanceID] = expirationTime
Core._buffSpellCache = Core._buffSpellCache or {}           -- [spellID] = { name=, icon= }
Core._pendingBuffCast = nil     -- { spell=, at= } awaiting an unreadable aura update
Core._lastCastNotifySpellId = nil -- spellID whose notifyOnCast already fired
Core._lastCastSpellId = nil
Core._lastCastAt = nil

function Core:InitBuffTracking()
    if self._buffFrame then return end
    self._buffFrame = CreateFrame("Frame")
    self._buffFrame:RegisterUnitEvent("UNIT_AURA", "player")
	pcall(function() self._buffFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player") end)
    self._buffFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    self._buffFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self._buffFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    self._buffFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    -- COMBAT_TEXT_UPDATE carries SPELL_AURA_* notices that remain visible
    -- when UNIT_AURA payloads go secret in combat. Not present on all clients.
    pcall(function()
        if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid("COMBAT_TEXT_UPDATE") then return end
        self._buffFrame:RegisterEvent("COMBAT_TEXT_UPDATE")
    end)
    self._buffFrame:SetScript("OnEvent", function(_, event, unit, ...)
        local info = ...
		if event == "PLAYER_ENTERING_WORLD" then
			-- On login/reload: populate tracking tables without clearing
			-- Mark auras seen during init to suppress their notifications later
			Core._auraInitSeq = (tonumber(Core._auraInitSeq) or 0) + 1
			local auraInitSeq = Core._auraInitSeq
			Core._auraInitInProgress = true
			Core._aurasSeenDuringInit = {}
			Core._auraGracePeriodUntil = 0
			-- Immediate scan to capture current auras before any removal happens
			-- Deferred by 0.1s to let the game fully load auras
			C_Timer.After(0.1, function()
				local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("core"))
					or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
				if dl >= 4 then
					if Addon and Addon.Dbg then
						Addon:Dbg("core", 4, "[AURA] PEW deferred scan masterEnabled=" .. tostring(Core:IsMasterEnabled()))
					else
						local ZSBTAddon = ZSBT and ZSBT.Addon
						if ZSBTAddon and ZSBTAddon.Print then
							ZSBTAddon:Print("[AURA] PEW deferred scan masterEnabled=" .. tostring(Core:IsMasterEnabled()))
						end
					end
				end
				if Core.IsMasterEnabled and Core:IsMasterEnabled() then
					Core:ScanPlayerAuras(nil, true)
					if dl >= 4 then
						local count = 0
						local ids = {}
						for id, name in pairs(Core._auraInstanceMap or {}) do
							count = count + 1
							if count <= 5 then
								table.insert(ids, tostring(id) .. "=" .. tostring(name))
							end
						end
						if Addon and Addon.Dbg then
							Addon:Dbg("core", 4, "[AURA] Deferred scan complete, tracked auras: " .. tostring(count) .. " sampleIDs: " .. table.concat(ids, ", "))
						else
							local ZSBTAddon = ZSBT and ZSBT.Addon
							if ZSBTAddon and ZSBTAddon.Print then
								ZSBTAddon:Print("[AURA] Deferred scan complete, tracked auras: " .. tostring(count) .. L[" sampleIDs: "] .. table.concat(ids, ", "))
							end
						end
					end
				elseif dl >= 4 then
					if Addon and Addon.Dbg then
						Addon:Dbg("core", 4, "[AURA] SKIPPED deferred scan - not enabled")
					else
						local ZSBTAddon = ZSBT and ZSBT.Addon
						if ZSBTAddon and ZSBTAddon.Print then
							ZSBTAddon:Print("[AURA] SKIPPED deferred scan - not enabled")
						end
					end
				end
			end)
			-- Follow-up scans at 0.5s and 1.5s to catch any late-loading auras
			C_Timer.After(0.5, function()
				if Core.IsMasterEnabled and Core:IsMasterEnabled() then
					Core:ScanPlayerAuras(nil, true)
				end
			end)
			C_Timer.After(1.5, function()
				if Core.IsMasterEnabled and Core:IsMasterEnabled() then
					Core:ScanPlayerAuras(nil, true)
					Core._auraInitInProgress = false
					-- Keep suppression table for 60 seconds to prevent buff spam when removing auras
					C_Timer.After(60.0, function()
						if Core._auraInitSeq == auraInitSeq then
							Core._aurasSeenDuringInit = nil
						end
					end)
				end
			end)
			return
		end

		if event == "ZONE_CHANGED_NEW_AREA" then
			-- On zone change (flying, teleport): clear tracking and suppress briefly
			-- This prevents buff spam during loading screens between zones
			Core._auraInstanceMap = {}
			Core._trackedAuraNames = {}
			Core._auraInstanceSpellIDs = {}
			Core._auraInstanceHarmfulSpellIDs = {}
			Core._auraInstanceIsHarmful = {}
			Core._auraInstanceExpires = {}
			Core._auraRuleLastShown = {}
			Core._auraInitSeq = (tonumber(Core._auraInitSeq) or 0) + 1
			local auraInitSeq = Core._auraInitSeq
			Core._auraInitInProgress = true
			Core._aurasSeenDuringInit = {}
			Core._auraGracePeriodUntil = 0
			Core._suppressAurasUntil = (GetTime and GetTime() or 0) + 2.0
			C_Timer.After(0.5, function()
				if Core.IsMasterEnabled and Core:IsMasterEnabled() then
					Core:ScanPlayerAuras(nil, true)
					Core._auraInitInProgress = false
					-- Keep suppression table for 60 seconds to prevent buff spam when removing auras
					C_Timer.After(60.0, function()
						if Core._auraInitSeq == auraInitSeq then
							Core._aurasSeenDuringInit = nil
						end
					end)
				end
			end)
			return
		end

        if event == "PLAYER_REGEN_DISABLED" then
            if not Core:IsMasterEnabled() then return end
            -- Combat-enter: suppress aura notifications briefly to avoid false fade/gain bursts
            -- when aura enumeration becomes incomplete/secret.
            Core._suppressAurasUntil = (GetTime and GetTime() or 0) + 1.0
            Core:ScanPlayerAuras(nil, true)
            if C_Timer and C_Timer.NewTicker then
                if Core._auraCombatTicker then
                    Core._auraCombatTicker:Cancel()
                    Core._auraCombatTicker = nil
                end
                Core._auraCombatTicker = C_Timer.NewTicker(0.20, function()
                    if Core.IsMasterEnabled and Core:IsMasterEnabled() then
                        local trg = ZSBT.Core and ZSBT.Core.Triggers
                        if trg and trg.SyncWatchedAurasFromCore then
                            pcall(function() trg:SyncWatchedAurasFromCore() end)
                        end
                        Core:ScanPlayerAuras(nil)
                    end
                end)
            end
            return
        elseif event == "PLAYER_REGEN_ENABLED" then
            if Core._auraCombatTicker then
                Core._auraCombatTicker:Cancel()
                Core._auraCombatTicker = nil
            end
            if Core.IsMasterEnabled and Core:IsMasterEnabled() then
                local trg = ZSBT.Core and ZSBT.Core.Triggers
                if trg and trg.SyncWatchedAurasFromCore then
                    pcall(function() trg:SyncWatchedAurasFromCore() end)
                end
                -- Leaving combat after restricted/secret aura updates can make the next UNIT_AURA
                -- snapshot look like a burst of "new" auras. Suppress aura notifications briefly
                -- and resync silently.
                Core._suppressAurasUntil = (GetTime and GetTime() or 0) + 1.0
                Core:ScanPlayerAuras(nil, true)
                C_Timer.After(0.25, function()
                    if Core.IsMasterEnabled and Core:IsMasterEnabled() then
                        Core:ScanPlayerAuras(nil, true)
                    end
                end)
            end
            return
        end
        if event == "COMBAT_TEXT_UPDATE" then
			-- For this event the first payload arg lands in `unit`.
			Core:OnCombatTextAura(unit)
			return
		end
        if event == "UNIT_SPELLCAST_SUCCEEDED" then
			if unit ~= "player" then return end
			if not Core:IsMasterEnabled() then return end
			local _, spellId = ...
			local trg = ZSBT.Core and ZSBT.Core.Triggers
			if trg and trg.OnSpellcastSucceeded then
				pcall(function() trg:OnSpellcastSucceeded(unit, spellId) end)
			end
			-- Track the last player cast for aura icon attribution and buff
			-- recast pairing (secret aura contexts can't see the refresh).
			Core._lastCastSpellId = spellId
			Core._lastCastAt = GetTime and GetTime() or 0
			if type(spellId) == "number" then
				-- Helpful self-casts seed the buff cache + pending pairing so
				-- secret UNIT_AURA updates can be attributed by spellID. This is
				-- the only reliable ID source on Midnight: aura names/payloads
				-- are secret, but the cast event carries a readable spellID.
				local helpful = false
				if C_Spell and C_Spell.IsSpellHelpful then
					local okH, resH = pcall(C_Spell.IsSpellHelpful, spellId)
					helpful = okH and resH == true
				end
				if helpful then
					-- A cast on a friendly target is theirs, not a self-buff recast.
					local exists = UnitExists and UnitExists("target")
					local assist = exists and UnitCanAssist and UnitCanAssist("player", "target")
					local isSelf = exists and UnitIsUnit and UnitIsUnit("target", "player")
					if not (assist and not isSelf) then
						Core._buffSpellCache = Core._buffSpellCache or {}
						local centry = Core._buffSpellCache[spellId]
						if type(centry) ~= "table" then centry = {}; Core._buffSpellCache[spellId] = centry end
						centry.fromCast = true
						if centry.name == nil then
							local cname = nil
							if C_Spell and C_Spell.GetSpellName then
								local okN, resN = pcall(C_Spell.GetSpellName, spellId)
								if okN then cname = resN end
							end
							if type(cname) ~= "string" and GetSpellInfo then
								local okI, resI = pcall(GetSpellInfo, spellId)
								if okI then cname = resI end
							end
							if type(cname) == "string" and cname ~= "" then centry.name = cname end
						end
						if centry.icon == nil then
							local icon = nil
							if C_Spell and C_Spell.GetSpellTexture then
								local okI, resI = pcall(C_Spell.GetSpellTexture, spellId)
								if okI and type(resI) == "number" then icon = resI end
							end
							if icon == nil and GetSpellTexture then
								local okI2, resI2 = pcall(GetSpellTexture, spellId)
								if okI2 and type(resI2) == "number" then icon = resI2 end
							end
							if icon ~= nil then centry.icon = icon end
						end
						Core._pendingBuffCast = { spell = spellId, at = Core._lastCastAt }
						Core:TryRecastBuffMatch()
					end
				end
			end
			-- Optional per-rule "notify on cast": fires for aura-tracked spells
			-- when the player actually casts them. Non-castable spells never
			-- produce UNIT_SPELLCAST_SUCCEEDED, so the option is inert for them.
			local ar = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl and ZSBT.db.char.spamControl.auraRules
			local arule = (type(spellId) == "number" and type(ar) == "table") and ar[spellId] or nil
			if type(arule) == "table" and arule.notifyOnCast == true and arule.enabled ~= false then
				local cname = nil
				if C_Spell and C_Spell.GetSpellName then
					local okN, resN = pcall(C_Spell.GetSpellName, spellId)
					if okN then cname = resN end
				end
				if type(cname) ~= "string" and GetSpellInfo then
					local okI, resI = pcall(GetSpellInfo, spellId)
					if okI then cname = resI end
				end
				if type(cname) == "string" and cname ~= "" then
					-- Stamp _auraReadAt so the aura gain arriving moments later
					-- doesn't double-notify for the same application.
					Core._auraReadAt = Core._lastCastAt
					Core._lastCastNotifySpellId = spellId
					Core:EmitBuffNotification(spellId, BuildAuraNotifText("+", cname),
						{r = 0.5, g = 0.8, b = 1.0}, "auras")
				end
			end
			return
		end

		if unit ~= "player" then return end
		if not Core:IsMasterEnabled() then return end

        -- Performance filter: skip noisy updates that don't affect our tracking
        if AuraUtil and AuraUtil.ShouldSkipAuraUpdate then
            local ok, skip = pcall(AuraUtil.ShouldSkipAuraUpdate, info)
            if ok and skip then
                -- Never skip while in combat: skipping causes us to miss real changes
                -- and then emit a burst of "new" auras after combat ends.
                if not UnitAffectingCombat("player") then
                    -- Outside combat, only skip when the update does not report actual additions/removals.
                    local hasSignal = false
                    if info then
                        local function isSecret(v)
                            if v == nil then return false end
                            if HasSecretValues then
                                local okS, resS = pcall(HasSecretValues, v)
                                if okS and resS then return true end
                            end
                            if ZSBT and ZSBT.IsSecret then
                                local okZ, resZ = pcall(ZSBT.IsSecret, v)
                                if okZ and resZ then return true end
                            end
                            return false
                        end

                        local okFull, vFull = pcall(function() return info.isFullUpdate end)
                        if okFull and not isSecret(vFull) then
                            local okCmp, isTrue = pcall(function() return vFull == true end)
                            if okCmp and isTrue == true then
                                hasSignal = true
                            end
                        end
                        if not hasSignal then
                            local okAdd, vAdd = pcall(function() return info.addedAuras end)
                            if okAdd and type(vAdd) == "table" and not isSecret(vAdd) then
                                hasSignal = true
                            end
                        end
                        if not hasSignal then
                            local okRem, vRem = pcall(function() return info.removedAuraInstanceIDs end)
                            if okRem and type(vRem) == "table" and not isSecret(vRem) then
                                hasSignal = true
                            end
                        end
                    end
                    if not hasSignal then
                        return
                    end
                end
            end
        end

        local trg = ZSBT.Core and ZSBT.Core.Triggers
        if trg and trg.SyncWatchedAurasFromCore then
            pcall(function() trg:SyncWatchedAurasFromCore() end)
        end
        Core:ScanPlayerAuras(info)
    end)
end

function Core:RunAuraTest()
    if not self.IsMasterEnabled or not self:IsMasterEnabled() then
        if Addon and Addon.Print then
            Addon:Print(L["AuraTest: ZSBT is disabled."])
        end
        return
    end
    self._auraInstanceMap = {}
    self:EmitNotification(L["AuraTest: scanning..."], {r = 1.0, g = 1.0, b = 0.2})
    self:ScanPlayerAuras(nil)

    local count = 0
    for _ in pairs(self._auraInstanceMap or {}) do
        count = count + 1
    end
    self:EmitNotification(L["AuraTest: found "] .. tostring(count), {r = 1.0, g = 1.0, b = 0.2})
end

 local function BuildAuraNotifText(prefix, auraName)
     if type(auraName) ~= "string" then
         return prefix
     end
     local ok, combined = pcall(function()
         return prefix .. auraName
     end)
     if ok and type(combined) == "string" then
         return combined
     end
     -- Secret/tainted strings can fail concatenation; show the name without prefix.
     return auraName
 end

-- Helper: extract a usable name from aura data.
-- Tries: clean spellId -> CleanSpellName, then aura.name field directly.
-- Returns name, isHarmful (or nil)
local function extractAuraInfo(auraData)
    local sid = auraData.spellId or auraData.spellID
    local name = nil
    local isHarmful = nil

    -- Try to read isHarmful safely
    if type(auraData.isHarmful) == "boolean" then
        -- In 12.0, even booleans can be "secret"; never propagate the raw value.
        -- Convert to a plain Lua boolean via pcall-comparison.
        local ok, val = pcall(function()
            return auraData.isHarmful == true
        end)
        if ok then
            isHarmful = val
        end
    end

    -- Prefer spellId -> clean name
    if sid and ZSBT.CleanSpellName and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
        name = ZSBT.CleanSpellName(sid)
        if name then
            return name, isHarmful
        end
    end

    if type(sid) == "number" and ZSBT.IsSafeString then
        if C_Spell and C_Spell.GetSpellName then
            local ok, fetched = pcall(C_Spell.GetSpellName, sid)
            if ok and type(fetched) == "string" and ZSBT.IsSafeString(fetched) then
                if fetched ~= "" then
                    return fetched, isHarmful
                end
            end
        end
        if GetSpellInfo then
            local ok, fetched = pcall(GetSpellInfo, sid)
            if ok and type(fetched) == "string" and ZSBT.IsSafeString(fetched) then
                if fetched ~= "" then
                    return fetched, isHarmful
                end
            end
        end
    end

    -- Fallback: read name directly from aura data.
    -- NOTE: In WoW 12.0 combat, auraData.name may be a secret value.
    -- We allow it through and handle concatenation safely at emit time.
    if auraData.name and type(auraData.name) == "string" then
        return auraData.name, isHarmful
    end

    -- Last resort: refetch by auraInstanceID (some payloads are incomplete/tainted)
    if auraData.auraInstanceID and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
        local refetched = C_UnitAuras.GetAuraDataByAuraInstanceID("player", auraData.auraInstanceID)
        if refetched then
            local rsid = refetched.spellId or refetched.spellID
            if rsid and ZSBT.CleanSpellName and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(rsid) then
                local rname = ZSBT.CleanSpellName(rsid)
                if rname then
                    return rname, isHarmful
                end
            end
            if refetched.name and type(refetched.name) == "string" then
                return refetched.name, isHarmful
            end
        end
    end

    return nil, isHarmful
end

local function GetPlayerAuraByIndex(index, filter)
    if Core.AuraIndexSecret and Core:AuraIndexSecret(index, filter) then return nil end
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, filter)
        if ok then return aura end
        return nil
    end
    if type(filter) == "string" and filter:find("HELPFUL", 1, true) then
        if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
            local ok, aura = pcall(C_UnitAuras.GetBuffDataByIndex, "player", index)
            if ok then return aura end
            return nil
        end
    elseif type(filter) == "string" and filter:find("HARMFUL", 1, true) then
        if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
            local ok, aura = pcall(C_UnitAuras.GetDebuffDataByIndex, "player", index)
            if ok then return aura end
            return nil
        end
    end
    return nil
end

function Core:ScanAuraRulesWatchedPresence(silent)
	local sc = ZSBT and ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
	local rules = sc and sc.auraRules
	if type(rules) ~= "table" then return end
	self._auraRulesPresent = self._auraRulesPresent or {}
	local cache = self._auraRulesPresent

	local trg = ZSBT.Core and ZSBT.Core.Triggers
	local hasPresenceFn = trg and trg.IsAuraPresentSpellId

	local function isHarmfulSpellId(sid)
		if not (AuraUtil and AuraUtil.FindAuraBySpellId) then return false end
		local ok, aura = pcall(AuraUtil.FindAuraBySpellId, sid, "player", "HARMFUL")
		return ok and aura ~= nil
	end

	for sid, rule in pairs(rules) do
		if type(sid) == "number" and type(rule) == "table" and rule.enabled ~= false then
			local present = false
			if hasPresenceFn then
				local okP, resP = pcall(trg.IsAuraPresentSpellId, trg, sid)
				present = okP and resP == true
			else
				if AuraUtil and AuraUtil.FindAuraBySpellId then
					local ok, aura = pcall(AuraUtil.FindAuraBySpellId, sid, "player", "HELPFUL")
					present = ok and aura ~= nil
					if not present then
						ok, aura = pcall(AuraUtil.FindAuraBySpellId, sid, "player", "HARMFUL")
						present = ok and aura ~= nil
					end
				end
			end

			local was = cache[sid]
			local wasPresent = type(was) == "table" and was.present == true
			-- Throttled diagnostic: shows whether presence detection can see
			-- this aura in secret contexts (FindAuraBySpellId vs fallbacks).
			local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("core")) or 0
			if dl >= 4 then
				local lastLog = type(was) == "table" and tonumber(was.dbgAt) or 0
				local nowL = GetTime and GetTime() or 0
				if nowL - lastLog >= 2.0 then
					cache[sid] = cache[sid] or {}
					cache[sid].dbgAt = nowL
					if Addon and Addon.Dbg then
						local diagStr = ""
						local trgD = ZSBT.Core and ZSBT.Core.Triggers
						local dg = trgD and trgD._presenceDiag and trgD._presenceDiag[sid]
						if type(dg) == "table" then
							diagStr = (" sec=%s find=%s enum=%s/%s")
								:format(tostring(dg.sec), tostring(dg.findHit),
									tostring(dg.enumRan), tostring(dg.enumHit))
						end
						Addon:Dbg("core", 4, ("[AURA-PRESENCE] sid=%s present=%s was=%s silent=%s%s")
							:format(tostring(sid), tostring(present), tostring(wasPresent),
								tostring(silent ~= nil and silent == true), diagStr))
					end
				end
			end
			if present and not wasPresent then
				local harmful = isHarmfulSpellId(sid)
				cache[sid] = { present = true, harmful = harmful }
				if not silent then
					local name = (ZSBT and ZSBT.CleanSpellName and ZSBT.CleanSpellName(sid)) or (GetSpellInfo and GetSpellInfo(sid)) or (L["Spell #"] .. tostring(sid))
					-- Cast-pairing may have just announced this gain; don't double it.
					local stamped = self._auraReadAt
					local justAnnounced = type(stamped) == "number"
						and ((GetTime and GetTime() or 0) - stamped) < 0.2
					local okToShow = (not justAnnounced) and self:ShouldEmitBuffNotif(sid, true, harmful, name) or false
					if okToShow then
						-- Mark handled so the combat-text fallback doesn't double it.
						self._auraReadAt = GetTime and GetTime() or 0
						local color = harmful and { r = 1.0, g = 0.4, b = 0.4 } or { r = 0.5, g = 0.8, b = 1.0 }
						if harmful then
							self:EmitNotification(BuildAuraNotifText("+", name), color, "auras")
						else
							self:EmitBuffNotification(sid, BuildAuraNotifText("+", name), color, "auras")
						end
					end
				end
			elseif (not present) and wasPresent then
				local harmful = type(was) == "table" and was.harmful == true
				cache[sid] = { present = false, harmful = harmful }
				if not silent then
					local name = (ZSBT and ZSBT.CleanSpellName and ZSBT.CleanSpellName(sid)) or (GetSpellInfo and GetSpellInfo(sid)) or (L["Spell #"] .. tostring(sid))
					local stamped = self._auraReadAt
					local justAnnounced = type(stamped) == "number"
						and ((GetTime and GetTime() or 0) - stamped) < 0.2
					local okToShow = (not justAnnounced) and self:ShouldEmitBuffNotif(sid, false, harmful, name) or false
					if okToShow then
						-- Mark handled so the combat-text fallback doesn't double it.
						self._auraReadAt = GetTime and GetTime() or 0
						local color = { r = 0.6, g = 0.6, b = 0.6 }
						if harmful then
							self:EmitNotification(BuildAuraNotifText("-", name), color, "auras")
						else
							self:EmitBuffNotification(sid, BuildAuraNotifText("-", name), color, "auras", nil, true)
						end
					end
				end
			end
		end
	end
end

function Core:ScanPlayerAuras(updateInfo, silent)
    if not self._auraInstanceMap then self._auraInstanceMap = {} end
    if not self._trackedAuraNames then self._trackedAuraNames = {} end

	-- 12.1+ secret aura contexts: do not parse UNIT_AURA delta payloads.
	-- Maintain configured auraRules via watched spellID presence checks only.
	-- C_Secrets.ShouldAurasBeSecret gives an authoritative answer when the
	-- client provides it; the combat/arena heuristics remain as fallback and
	-- a genuinely secret payload always wins over an explicit "not secret".
	local secretCtx = self.IsAurasSecretContext and self:IsAurasSecretContext(updateInfo) == true or false
	local payloadSecret = false
	if updateInfo ~= nil and HasSecretValues then
		local okP, resP = pcall(HasSecretValues, updateInfo)
		payloadSecret = okP and resP == true
	end
	local auraSecret = self:AuraSecretGlobal()
	if auraSecret == true then
		secretCtx = true
	elseif auraSecret == false and not payloadSecret then
		secretCtx = false
	end
	if secretCtx then
		if updateInfo ~= nil then
			self._lastUnreadAuraAt = GetTime and GetTime() or 0
			self:TryRecastBuffMatch()
		end
		self:ScanAuraRulesWatchedPresence(silent)
		return
	end

	local function isSecret(v)
		if v == nil then return false end
		if HasSecretValues then
			local ok, res = pcall(HasSecretValues, v)
			if ok and res then return true end
		end
		if ZSBT and ZSBT.IsSecret then
			local ok, res = pcall(ZSBT.IsSecret, v)
			if ok and res then return true end
		end
		return false
	end

	local function safeNonSecretTable(v)
		if type(v) ~= "table" then return nil end
		if isSecret(v) then return nil end
		return v
	end

	local function safeIpairs(v)
		local ok, iter, tbl, idx = pcall(ipairs, v)
		if not ok then
			return function() end, nil, nil
		end
		return iter, tbl, idx
	end

	local function safeHasAny(v)
		local ok, k = pcall(function() return next(v) end)
		return ok and k ~= nil
	end
    
    -- Check loading/transition suppression (zone changes only)
    if not silent and self._suppressAurasUntil then
        local now = GetTime and GetTime() or 0
        if now < self._suppressAurasUntil then
            silent = true
        else
            self._suppressAurasUntil = nil
        end
    end

    -- Full scan: rebuild everything from scratch
    local isFullUpdate = false
    if not updateInfo then
        isFullUpdate = true
    else
        local ok, v = pcall(function() return updateInfo.isFullUpdate end)
        if ok then
            local okCmp, isTrue = pcall(function() return v == true end)
            if okCmp and isTrue == true and not isSecret(v) then
                isFullUpdate = true
            end
        end
    end
    if isFullUpdate then
		local trg = ZSBT.Core and ZSBT.Core.Triggers
		if trg and trg.SyncWatchedAurasFromCore then
			pcall(function() trg:SyncWatchedAurasFromCore() end)
		end
        local oldInstances = self._auraInstanceMap
        local newInstances = {}  -- [instanceID] = name (name may be secret)

        local function tryAddAura(auraData, defaultName, gainColor, isHelpful)
            if not auraData then return end
            local instanceId = auraData.auraInstanceID
            if not instanceId then return end
            -- Secret values (toys, some client builds) can't be used as table
            -- keys — skip auras whose instanceId isn't a usable number.
            if ZSBT.IsSafeNumber and not ZSBT.IsSafeNumber(instanceId) then return end

            -- Track expirationTime for refresh detection (updated auras whose
            -- time left jumped were recast).
            local auraExp = auraData.expirationTime
            if type(auraExp) == "number" and not isSecret(auraExp) then
                if self._auraInstanceExpires then self._auraInstanceExpires[instanceId] = auraExp end
            end

            local sid = ResolveSafeAuraSpellID(auraData)
            local name = extractAuraInfo(auraData)
			if type(sid) ~= "number" then
				sid = ResolveSpellIdByName(name)
			end
            if not newInstances[instanceId] then
                newInstances[instanceId] = name or defaultName
                if type(self._auraInstanceIsHarmful) == "table" then
                    self._auraInstanceIsHarmful[instanceId] = isHelpful ~= true and true or false
                end
                if isHelpful and type(sid) == "number" then
                    self:RecordRecentBuff(sid)
                    -- Cache helpful auras by spell for recast pairing and icon
                    -- attribution when UNIT_AURA payloads go secret.
                    if self._buffSpellCache then
                        local centry = self._buffSpellCache[sid]
                        if type(centry) ~= "table" then centry = {}; self._buffSpellCache[sid] = centry end
                        if name then centry.name = name end
                        local icon = auraData.icon
                        if icon ~= nil and not isSecret(icon) and (type(icon) == "string" or type(icon) == "number") then centry.icon = icon end
                    end
                end
                if type(sid) == "number" then
                    if isHelpful and self._auraInstanceSpellIDs then
                        self._auraInstanceSpellIDs[instanceId] = sid
                    elseif (not isHelpful) and self._auraInstanceHarmfulSpellIDs then
                        self._auraInstanceHarmfulSpellIDs[instanceId] = sid
                    end
                end
                -- Track auras seen during init to suppress their notifications later
                if silent and self._auraInitInProgress and type(sid) == "number" then
                    self._aurasSeenDuringInit[sid] = true
                end
            end
            if not oldInstances[instanceId] then
                -- Skip notification if this aura was seen during init (prevents reload spam)
                local seenDuringInit = type(sid) == "number" and self._aurasSeenDuringInit and self._aurasSeenDuringInit[sid]
                -- Skip notification during grace period after aura removal (prevents instance ID refresh spam)
                local inGracePeriod = self._auraGracePeriodUntil and (GetTime and GetTime() or 0) < self._auraGracePeriodUntil
                if not silent and not seenDuringInit and not inGracePeriod then
                    local okToShow = self:ShouldEmitBuffNotif(sid, true, isHelpful ~= true, name)
                    if okToShow then
                        if sid and type(sid) == "number" then
                            self:EmitBuffNotification(sid, BuildAuraNotifText("+", newInstances[instanceId]), gainColor, "auras")
                        else
                            self:EmitNotification(BuildAuraNotifText("+", newInstances[instanceId]), gainColor, "auras")
                        end
                    end
                end
            end
        end

        local function scanWithSlots(filter, defaultName, gainColor)
            if not (C_UnitAuras and C_UnitAuras.GetAuraSlots and C_UnitAuras.GetAuraDataBySlot) then
                return false
            end

            local continuationToken = nil
            while true do
                local slots
                local ok, a, b = pcall(C_UnitAuras.GetAuraSlots, "player", filter, 255, continuationToken)
                if not ok then
                    return false
                end

                -- API return order can vary by client build:
                -- either (slots, continuationToken) or (continuationToken, slots).
                if type(a) == "table" then
                    slots = a
                    continuationToken = b
                elseif type(b) == "table" then
                    slots = b
                    continuationToken = a
                else
                    slots = nil
                    continuationToken = nil
                end

                if not slots and not continuationToken then
                    -- Nothing usable from this API on this client.
                    return false
                end

                if type(slots) == "table" then
                    for i = 1, #slots do
                        local slot = slots[i]
                        local ok2, auraData = pcall(C_UnitAuras.GetAuraDataBySlot, "player", slot)
                        if ok2 and auraData then
                            tryAddAura(auraData, defaultName, gainColor, filter == "HELPFUL")
                        end
                    end
                end

                if not continuationToken or continuationToken == 0 then
                    break
                end
            end
            return true
        end

        local function scanWithForEach(filter, defaultName, gainColor)
            if not (AuraUtil and AuraUtil.ForEachAura) then return false end
            local ok = pcall(function()
                AuraUtil.ForEachAura("player", filter, 255, function(auraData)
                    if not auraData then return true end
                    tryAddAura(auraData, defaultName, gainColor, filter == "HELPFUL")
                    return true
                end, true)
            end)
            return ok
        end

        -- Scan buffs (aggregate multiple sources to avoid partial enumeration)
        scanWithSlots("HELPFUL", "Buff", {r = 0.5, g = 0.8, b = 1.0})
        scanWithForEach("HELPFUL", "Buff", {r = 0.5, g = 0.8, b = 1.0})
        for i = 1, 255 do
            local auraData = GetPlayerAuraByIndex(i, "HELPFUL")
            if not auraData then break end
            tryAddAura(auraData, "Buff", {r = 0.5, g = 0.8, b = 1.0}, true)
        end

        -- Scan debuffs
        scanWithSlots("HARMFUL", "Debuff", {r = 1.0, g = 0.4, b = 0.4})
        scanWithForEach("HARMFUL", "Debuff", {r = 1.0, g = 0.4, b = 0.4})
        for i = 1, 255 do
            local auraData = GetPlayerAuraByIndex(i, "HARMFUL")
            if not auraData then break end
            tryAddAura(auraData, "Debuff", {r = 1.0, g = 0.4, b = 0.4}, false)
        end

		-- 12.1+ safety: in some combat contexts the aura APIs can return incomplete/empty
		-- results due to secret value restrictions. If a combat scan yields *no* auras but
		-- we previously had some, treat it as unreliable and do not emit fades/gains.
		local newCount = 0
		for _ in pairs(newInstances) do newCount = newCount + 1 end
		local oldCount = 0
		for _ in pairs(oldInstances) do oldCount = oldCount + 1 end
		if UnitAffectingCombat and UnitAffectingCombat("player") and newCount == 0 and oldCount > 0 then
			return
		end

        -- Detect fades by instance ID
        for oldInstanceId, oldName in pairs(oldInstances) do
            if not newInstances[oldInstanceId] then
                if not silent then
                    local sid = self._auraInstanceSpellIDs and self._auraInstanceSpellIDs[oldInstanceId]
                    local isHarmful = self._auraInstanceIsHarmful and self._auraInstanceIsHarmful[oldInstanceId] == true
                    if isHarmful and (not sid) then
                        sid = self._auraInstanceHarmfulSpellIDs and self._auraInstanceHarmfulSpellIDs[oldInstanceId]
                    end
                    local okToShow = self:ShouldEmitBuffNotif(sid, false, isHarmful, oldName)
                    if okToShow then
                        if sid and type(sid) == "number" then
                            self:EmitBuffNotification(sid, BuildAuraNotifText("-", oldName or "Aura"), {r = 0.6, g = 0.6, b = 0.6}, "auras", nil, true)
                        else
                            self:EmitNotification(BuildAuraNotifText("-", oldName or "Aura"), {r = 0.6, g = 0.6, b = 0.6}, "auras")
                        end
                    end
                end
                if type(sid) == "number" then
                    local trg = ZSBT.Core and ZSBT.Core.Triggers
                    if trg then
                        -- Skip synthetic auras to prevent double events
                        local isSynthetic = trg._syntheticAuraExpireAt and type(trg._syntheticAuraExpireAt[sid]) == "number"
                        if isSynthetic then
                            local now = GetTime and GetTime() or 0
                            isSynthetic = now < (trg._syntheticAuraExpireAt[sid] or 0)
                        end
                        if not isSynthetic and trg.OnAuraFade then
                            trg:OnAuraFade(sid, "core")
                        end
                    end
                end
                if self._auraInstanceSpellIDs then self._auraInstanceSpellIDs[oldInstanceId] = nil end
                if self._auraInstanceHarmfulSpellIDs then self._auraInstanceHarmfulSpellIDs[oldInstanceId] = nil end
                if self._auraInstanceIsHarmful then self._auraInstanceIsHarmful[oldInstanceId] = nil end
                if self._auraInstanceExpires then self._auraInstanceExpires[oldInstanceId] = nil end
            end
        end

        self._auraInstanceMap = newInstances
        if updateInfo ~= nil then
            self._auraReadAt = GetTime and GetTime() or 0
        end
        return
    end

    -- Incremental: handle added auras
    local addedAuras = nil
    if updateInfo then
        local ok, v = pcall(function() return updateInfo.addedAuras end)
        if ok and type(v) == "table" and not isSecret(v) then
            addedAuras = v
        end
    end
    if addedAuras then
		local trg = ZSBT.Core and ZSBT.Core.Triggers
		if trg and trg.SyncWatchedAurasFromCore then
			pcall(function() trg:SyncWatchedAurasFromCore() end)
		end
        local needsRescan = false
        for _, aura in safeIpairs(addedAuras) do
            local name, isHarmful = extractAuraInfo(aura)
            local instanceId = aura.auraInstanceID
            local sid = ResolveSafeAuraSpellID(aura)
			if type(sid) ~= "number" then
				sid = ResolveSpellIdByName(name)
			end
            if not instanceId then
                -- Some combat updates can omit instance IDs; fall back to full rescan.
                needsRescan = true
            else
                if updateInfo ~= nil then
                    self._auraReadAt = GetTime and GetTime() or 0
                end
                local auraExp = aura.expirationTime
                if type(auraExp) == "number" and not isSecret(auraExp) then
                    if self._auraInstanceExpires then self._auraInstanceExpires[instanceId] = auraExp end
                end
                if not self._auraInstanceMap[instanceId] then
                    self._auraInstanceMap[instanceId] = name or "Aura"
                    local color = {r = 0.5, g = 0.8, b = 1.0}  -- buff blue
                    if isHarmful == true then
                        color = {r = 1.0, g = 0.4, b = 0.4}  -- debuff red
                    end
                    if isHarmful ~= true and type(sid) == "number" then
                        self:RecordRecentBuff(sid)
                        if self._buffSpellCache then
                            local centry = self._buffSpellCache[sid]
                            if type(centry) ~= "table" then centry = {}; self._buffSpellCache[sid] = centry end
                            if name then centry.name = name end
                            local icon = aura.icon
                            if icon ~= nil and not isSecret(icon) and (type(icon) == "string" or type(icon) == "number") then centry.icon = icon end
                        end
                    end
                    if type(self._auraInstanceIsHarmful) == "table" then
                        self._auraInstanceIsHarmful[instanceId] = isHarmful == true
                    end
                    if type(sid) == "number" then
                        if isHarmful and self._auraInstanceHarmfulSpellIDs then
                            self._auraInstanceHarmfulSpellIDs[instanceId] = sid
                        elseif (not isHarmful) and self._auraInstanceSpellIDs then
                            self._auraInstanceSpellIDs[instanceId] = sid
                        end
                    end
                    -- Track auras seen during init to suppress their notifications later
                    if silent and self._auraInitInProgress and type(sid) == "number" then
                        self._aurasSeenDuringInit[sid] = true
                    end
                    if not silent then
                        local okToShow = self:ShouldEmitBuffNotif(sid, true, isHarmful, name)
                        if okToShow then
							if isHarmful then
								self:EmitNotification(BuildAuraNotifText("+", self._auraInstanceMap[instanceId]), color, "auras")
							else
								if sid and type(sid) == "number" then
									self:EmitBuffNotification(sid, BuildAuraNotifText("+", self._auraInstanceMap[instanceId]), color, "auras")
								else
									self:EmitNotification(BuildAuraNotifText("+", self._auraInstanceMap[instanceId]), color, "auras")
								end
							end
                        end
                    end
                    if type(sid) == "number" then
                        local trg = ZSBT.Core and ZSBT.Core.Triggers
                        if trg then
                            -- Skip synthetic auras to prevent double events
                            local isSynthetic = trg._syntheticAuraExpireAt and type(trg._syntheticAuraExpireAt[sid]) == "number"
                            if isSynthetic then
                                local now = GetTime and GetTime() or 0
                                isSynthetic = now < (trg._syntheticAuraExpireAt[sid] or 0)
                            end
                            if not isSynthetic and trg.OnAuraGain then
                                trg:OnAuraGain(sid, "core-inc")
                            end
                        end
                    end
                end
            end
        end

        if needsRescan then
            self:ScanPlayerAuras(nil)
            return
        end
    end

    -- Incremental: handle refreshed/updated auras (same instance ID)
	-- This catches recasts like Battle Shout that refresh an existing buff.
	local updatedAuraInstanceIDs = nil
	if updateInfo then
		local ok, v = pcall(function() return updateInfo.updatedAuraInstanceIDs end)
		if ok and type(v) == "table" and not isSecret(v) then
			updatedAuraInstanceIDs = v
		end
	end
	if updatedAuraInstanceIDs then
		local needsRescan = false
		for _, instanceId in safeIpairs(updatedAuraInstanceIDs) do
			if instanceId and not self:AuraInstanceSecret(instanceId) then
				local auraData = nil
				if C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
					-- In some builds, this can throw when payloads are secret.
					pcall(function()
						auraData = C_UnitAuras.GetAuraDataByAuraInstanceID("player", instanceId)
					end)
				end

				if auraData then
					if updateInfo ~= nil then
						self._auraReadAt = GetTime and GetTime() or 0
					end
					local name, isHarmful = extractAuraInfo(auraData)
					local sid = ResolveSafeAuraSpellID(auraData)
					if type(sid) == "number" and isHarmful ~= true then
						self:RecordRecentBuff(sid)
						if self._buffSpellCache then
							local centry = self._buffSpellCache[sid]
							if type(centry) ~= "table" then centry = {}; self._buffSpellCache[sid] = centry end
							if name then centry.name = name end
							local icon = auraData.icon
							if icon ~= nil and not isSecret(icon) and (type(icon) == "string" or type(icon) == "number") then centry.icon = icon end
						end
					end
					if type(self._auraInstanceIsHarmful) == "table" then
						self._auraInstanceIsHarmful[instanceId] = isHarmful == true
					end
					if type(sid) == "number" then
						if isHarmful == true and self._auraInstanceHarmfulSpellIDs then
							self._auraInstanceHarmfulSpellIDs[instanceId] = sid
						elseif isHarmful ~= true and self._auraInstanceSpellIDs then
							self._auraInstanceSpellIDs[instanceId] = sid
						end
					end
					-- Refresh detection: a recast keeps the same instanceID but
					-- jumps expirationTime forward. Re-notify like a fresh gain.
					local newExp = auraData.expirationTime
					if self._auraInstanceExpires then
						local oldExp = self._auraInstanceExpires[instanceId]
						if type(oldExp) == "number" and oldExp > 0
							and type(newExp) == "number" and not isSecret(newExp)
							and newExp > oldExp + 2.0 and silent ~= true then
							local rname = name or self._auraInstanceMap[instanceId]
							local rsid = (type(sid) == "number") and sid
								or (self._auraInstanceSpellIDs and self._auraInstanceSpellIDs[instanceId])
							local isHarmfulAura = (isHarmful == true)
								or (self._auraInstanceIsHarmful and self._auraInstanceIsHarmful[instanceId] == true)
							local okToShow = self:ShouldEmitBuffNotif(rsid, true, isHarmfulAura, rname)
							if okToShow then
								local rtext = BuildAuraNotifText("+", rname or "Aura")
								local rcolor = isHarmfulAura and {r = 1.0, g = 0.4, b = 0.4} or {r = 0.5, g = 0.8, b = 1.0}
								if type(rsid) == "number" and not isHarmfulAura then
									self:EmitBuffNotification(rsid, rtext, rcolor, "auras")
								else
									self:EmitNotification(rtext, rcolor, "auras")
								end
							end
						end
						if type(newExp) == "number" and not isSecret(newExp) then
							self._auraInstanceExpires[instanceId] = newExp
						end
					end
					if instanceId and name then
						self._auraInstanceMap[instanceId] = name
					end
				else
					-- Could not resolve the updated aura; rescan to resync.
					needsRescan = true
				end
			end
		end

		if needsRescan then
			self:ScanPlayerAuras(nil)
			return
		end
	end

    -- Incremental: handle removed auras
	local removedAuraInstanceIDs = nil
	if updateInfo then
		local ok, v = pcall(function() return updateInfo.removedAuraInstanceIDs end)
		if ok then
			removedAuraInstanceIDs = safeNonSecretTable(v)
		end
	end
	if removedAuraInstanceIDs then
		local trg = ZSBT.Core and ZSBT.Core.Triggers
		if trg and trg.SyncWatchedAurasFromCore then
			pcall(function() trg:SyncWatchedAurasFromCore() end)
		end
        local needsRescan = false
        local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("core"))
			or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
		for _, instanceId in safeIpairs(removedAuraInstanceIDs) do
			local name = self._auraInstanceMap[instanceId]
			local sid = self._auraInstanceSpellIDs and self._auraInstanceSpellIDs[instanceId]
			local isHarmful = self._auraInstanceIsHarmful and self._auraInstanceIsHarmful[instanceId] == true
			if isHarmful and (not sid) then
				sid = self._auraInstanceHarmfulSpellIDs and self._auraInstanceHarmfulSpellIDs[instanceId]
			end
            -- Fallback: if not in cache, try to resolve from game API
            if not name and not self:AuraInstanceSecret(instanceId)
                and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
                local ok, auraData = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, "player", instanceId)
                if ok and auraData then
                    name = extractAuraInfo(auraData)
                    if isHarmful == false and type(auraData.isHarmful) == "boolean" then
                        local okH, v = pcall(function() return auraData.isHarmful == true end)
                        if okH then isHarmful = v end
                    end
                    if type(sid) ~= "number" then
                        sid = ResolveSafeAuraSpellID(auraData)
                        if type(sid) ~= "number" then
                            sid = ResolveSpellIdByName(name)
                        end
                    end
                end
            end
            if dl >= 4 then
				if Addon and Addon.Dbg then
					local function safeDbg(v)
						if v == nil then return "nil" end
						if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
						if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
						return "<secret>"
					end
					Addon:Dbg("core", 4, "[AURA] REMOVE instanceId=" .. safeDbg(instanceId)
						.. " name=" .. safeDbg(name)
						.. " inCache=" .. safeDbg(self._auraInstanceMap[instanceId] ~= nil)
						.. " sid=" .. safeDbg(sid))
				else
					local ZSBTAddon = ZSBT and ZSBT.Addon
					if ZSBTAddon and ZSBTAddon.Print then
						local function safeDbg(v)
							if v == nil then return "nil" end
							if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
							if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
							return "<secret>"
						end
						pcall(function()
							ZSBTAddon:Print("[AURA] REMOVE instanceId=" .. safeDbg(instanceId)
								.. " name=" .. safeDbg(name)
								.. " inCache=" .. safeDbg(self._auraInstanceMap[instanceId] ~= nil)
								.. " sid=" .. safeDbg(sid))
						end)
					end
				end
			end
			if name then
				if updateInfo ~= nil then
					self._auraReadAt = GetTime and GetTime() or 0
				end
				self._auraInstanceMap[instanceId] = nil
				-- Skip fade notifications during init (instance IDs are unstable after reload)
				local inInitWindow = Core._auraInitInProgress
				if dl >= 4 then
					if Addon and Addon.Dbg then
						local function safeDbg(v)
							if v == nil then return "nil" end
							if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
							if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
							return "<secret>"
						end
						Addon:Dbg("core", 4, "[AURA] FADE check silent=" .. safeDbg(silent)
							.. " init=" .. safeDbg(inInitWindow)
							.. " sid=" .. safeDbg(sid)
							.. " name=" .. safeDbg(name))
					else
						local ZSBTAddon = ZSBT and ZSBT.Addon
						if ZSBTAddon and ZSBTAddon.Print then
							local function safeDbg(v)
								if v == nil then return "nil" end
								if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
								if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
								return "<secret>"
							end
							pcall(function()
								ZSBTAddon:Print("[AURA] FADE check silent=" .. safeDbg(silent)
									.. " init=" .. safeDbg(inInitWindow)
									.. " sid=" .. safeDbg(sid)
									.. " name=" .. safeDbg(name))
							end)
						end
					end
				end
				if silent ~= true and not inInitWindow then
					local okToShow = self:ShouldEmitBuffNotif(sid, false, isHarmful, name)
					if dl >= 4 then
						if Addon and Addon.Dbg then
							Addon:Dbg("core", 4, "[AURA] FADE okToShow=" .. tostring(okToShow))
						else
							local ZSBTAddon = ZSBT and ZSBT.Addon
							if ZSBTAddon and ZSBTAddon.Print then
								ZSBTAddon:Print("[AURA] FADE okToShow=" .. tostring(okToShow))
							end
						end
					end
					if okToShow then
						if sid and type(sid) == "number" then
							if dl >= 4 then
								if Addon and Addon.Dbg then
									Addon:Dbg("core", 4, "[AURA] FADE EMITTING sid=" .. tostring(sid))
								else
									local ZSBTAddon = ZSBT and ZSBT.Addon
									if ZSBTAddon and ZSBTAddon.Print then
										ZSBTAddon:Print("[AURA] FADE EMITTING sid=" .. tostring(sid))
									end
								end
							end
							self:EmitBuffNotification(sid, BuildAuraNotifText("-", name), {r = 0.6, g = 0.6, b = 0.6}, "auras", nil, true)
						else
							if dl >= 4 then
								if Addon and Addon.Dbg then
									local function safeDbg(v)
										if v == nil then return "nil" end
										if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
										if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
										return "<secret>"
									end
									Addon:Dbg("core", 4, "[AURA] FADE EMITTING (no sid) name=" .. safeDbg(name))
								else
									local ZSBTAddon = ZSBT and ZSBT.Addon
									if ZSBTAddon and ZSBTAddon.Print then
										local function safeDbg(v)
											if v == nil then return "nil" end
											if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
											if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
											return "<secret>"
										end
										pcall(function()
											ZSBTAddon:Print("[AURA] FADE EMITTING (no sid) name=" .. safeDbg(name))
										end)
									end
								end
							end
							self:EmitNotification(BuildAuraNotifText("-", name), {r = 0.6, g = 0.6, b = 0.6}, "auras")
						end
					elseif dl >= 4 then
						if Addon and Addon.Dbg then
							Addon:Dbg("core", 4, "[AURA] FADE BLOCKED by ShouldEmitBuffNotif sid=" .. tostring(sid))
						else
							local ZSBTAddon = ZSBT and ZSBT.Addon
							if ZSBTAddon and ZSBTAddon.Print then
								ZSBTAddon:Print("[AURA] FADE BLOCKED by ShouldEmitBuffNotif sid=" .. tostring(sid))
							end
						end
					end
				end
				if type(sid) == "number" then
					local trg = ZSBT.Core and ZSBT.Core.Triggers
					if trg then
						-- Skip synthetic auras to prevent double events
						local isSynthetic = trg._syntheticAuraExpireAt and type(trg._syntheticAuraExpireAt[sid]) == "number"
						if isSynthetic then
							local now = GetTime and GetTime() or 0
							isSynthetic = now < (trg._syntheticAuraExpireAt[sid] or 0)
						end
						if not isSynthetic and trg.OnAuraFade then
							trg:OnAuraFade(sid, "core-rm")
						end
					end
				end
				if self._auraInstanceSpellIDs then self._auraInstanceSpellIDs[instanceId] = nil end
				if self._auraInstanceHarmfulSpellIDs then self._auraInstanceHarmfulSpellIDs[instanceId] = nil end
				if self._auraInstanceIsHarmful then self._auraInstanceIsHarmful[instanceId] = nil end
				if self._auraInstanceExpires then self._auraInstanceExpires[instanceId] = nil end
			end
		end
		if needsRescan then
			-- Set grace period BEFORE rescan so it catches the refreshed auras
			local graceStart = GetTime and GetTime() or 0
			self._auraGracePeriodUntil = graceStart + 1.0
			local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("core"))
				or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
			if dl >= 4 then
				if Addon and Addon.Dbg then
					Addon:Dbg("core", 4, "[AURA] SET grace period (rescan) until=" .. tostring(self._auraGracePeriodUntil))
				else
					local ZSBTAddon = ZSBT and ZSBT.Addon
					if ZSBTAddon and ZSBTAddon.Print then
						ZSBTAddon:Print("[AURA] SET grace period (rescan) until=" .. tostring(self._auraGracePeriodUntil))
					end
				end
			end
			self:ScanPlayerAuras(nil)
			return
		end
        -- Set grace period AFTER processing removals to suppress gain notifications from instance ID refreshes
        -- This ensures fade notifications are shown before suppression kicks in
        local graceStart = GetTime and GetTime() or 0
        self._auraGracePeriodUntil = graceStart + 1.0
        local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("core"))
			or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
        if dl >= 4 then
			if Addon and Addon.Dbg then
				Addon:Dbg("core", 4, "[AURA] SET grace period until=" .. tostring(self._auraGracePeriodUntil))
			else
				local ZSBTAddon = ZSBT and ZSBT.Addon
				if ZSBTAddon and ZSBTAddon.Print then
					ZSBTAddon:Print("[AURA] SET grace period until=" .. tostring(self._auraGracePeriodUntil))
				end
			end
		end
    end

    -- Fallback: if neither added nor removed, do full rescan
    if updateInfo then
        local okFull, vFull = pcall(function() return updateInfo.isFullUpdate end)
        local isFull = false
        if okFull and not isSecret(vFull) then
            local okCmp, isTrue = pcall(function() return vFull == true end)
            if okCmp and isTrue == true then
                isFull = true
            end
        end

        local okAdd, vAdd = pcall(function() return updateInfo.addedAuras end)
        local hasAdded = okAdd and type(vAdd) == "table" and not isSecret(vAdd) and safeHasAny(vAdd)

        local okRem, vRem = pcall(function() return updateInfo.removedAuraInstanceIDs end)
        local hasRemoved = okRem and type(vRem) == "table" and not isSecret(vRem) and safeHasAny(vRem)

        if not isFull and not hasAdded and not hasRemoved then
            self:ScanPlayerAuras(nil)
        end
    end
end

------------------------------------------------------------------------
-- Combat-text aura fallback
-- SPELL_AURA_* combat-text notices still fire when UNIT_AURA payloads go
-- secret in combat. Deduped against _auraReadAt so readable UNIT_AURA
-- updates always win.
------------------------------------------------------------------------
function Core:OnCombatTextAura(kind)
	if type(kind) ~= "string" then return end
	local gained = kind == "SPELL_AURA_START" or kind == "SPELL_AURA_START_HARMFUL"
	local faded  = kind == "SPELL_AURA_END" or kind == "SPELL_AURA_END_HARMFUL"
	if not (gained or faded) then return end
	if not (C_CombatText and C_CombatText.GetCurrentEventInfo) then return end
	local name = C_CombatText.GetCurrentEventInfo()
	if name == nil then return end
	local harmful = kind:find("HARMFUL", 1, true) ~= nil
	local at = GetTime and GetTime() or 0
	C_Timer.After(0.15, function()
		if not (Core.IsMasterEnabled and Core:IsMasterEnabled()) then return end
		if self._auraReadAt and self._auraReadAt >= at - 0.2 then return end
		-- Respect the same anti-spam windows the UNIT_AURA path uses.
		local now = GetTime and GetTime() or 0
		if self._auraInitInProgress or (self._suppressAurasUntil and now < self._suppressAurasUntil) then return end
		local safeName = (ZSBT.IsSafeString and ZSBT.IsSafeString(name)) and name or nil
		-- Secret aura fade attribution: the END event carries no readable name,
		-- but if exactly one cast-paired buff is active it is almost certainly
		-- the one fading. Ambiguous cases (0 or 2+ active) fall through to the
		-- normal toggle-gated path.
		if faded and not harmful and safeName == nil then
			local active = self._pairedAuraActive
			if type(active) == "table" then
				local onlySid = nil
				local count = 0
				local nowA = GetTime and GetTime() or 0
				for sid, ts in pairs(active) do
					if type(sid) == "number" and type(ts) == "number" and (nowA - ts) <= 300 then
						count = count + 1
						onlySid = sid
					else
						active[sid] = nil
					end
				end
				if count == 1 and type(onlySid) == "number" then
					-- Presence polling may have already announced this fade.
					local stamped = self._auraReadAt
					local justAnnounced = type(stamped) == "number"
						and ((GetTime and GetTime() or 0) - stamped) < 0.3
					local entry = self._buffSpellCache and self._buffSpellCache[onlySid]
					local dname = type(entry) == "table" and entry.name or nil
					local okFade = (not justAnnounced) and self:ShouldEmitBuffNotif(onlySid, false, false, dname, true) or false
					if okFade then
						active[onlySid] = nil
						self._auraReadAt = GetTime and GetTime() or 0
						self:EmitBuffNotification(onlySid, BuildAuraNotifText("-", dname or "Aura"),
							{r = 0.6, g = 0.6, b = 0.6}, "auras", nil, true)
						return
					end
				end
			end
		end
		-- Resolve the readable aura name back to a spellID so numeric auraRules,
		-- recent-buff tracking, and the recast/icon caches all work in secret
		-- contexts where UNIT_AURA never exposes the ID.
		local resolvedSid = safeName and ResolveSpellIdByName(safeName) or nil
		if gained and not harmful and type(resolvedSid) == "number" then
			self:RecordRecentBuff(resolvedSid)
			if self._buffSpellCache then
				local centry = self._buffSpellCache[resolvedSid]
				if type(centry) ~= "table" then centry = {}; self._buffSpellCache[resolvedSid] = centry end
				centry.name = safeName
				local icon = nil
				if C_Spell and C_Spell.GetSpellTexture then
					local okI, resI = pcall(C_Spell.GetSpellTexture, resolvedSid)
					if okI and type(resI) == "number" then icon = resI end
				end
				if icon == nil and GetSpellTexture then
					local okI2, resI2 = pcall(GetSpellTexture, resolvedSid)
					if okI2 and type(resI2) == "number" then icon = resI2 end
				end
				if icon ~= nil then centry.icon = icon end
			end
		end
		local okToShow = self:ShouldEmitBuffNotif(resolvedSid, gained, harmful, safeName, true)
		if not okToShow then return end
		local prefix = gained and "+" or "-"
		local color
		if gained then
			color = harmful and {r = 1.0, g = 0.4, b = 0.4} or {r = 0.5, g = 0.8, b = 1.0}
		else
			color = {r = 0.6, g = 0.6, b = 0.6}
		end
		-- Attribute the buff's icon only when the aura name positively matches
		-- the same-frame helpful cast — same-frame alone misattributes icons
		-- to unrelated procs/buffs landing in the same frame.
		local extraMeta = nil
		if gained and not harmful and safeName and self._lastCastSpellId
			and math.abs((self._lastCastAt or 0) - at) <= 0.005 then
			local spell = self._lastCastSpellId
			local spellName = nil
			if C_Spell and C_Spell.GetSpellName then
				local okN, resN = pcall(C_Spell.GetSpellName, spell)
				if okN then spellName = resN end
			end
			if type(spellName) ~= "string" and GetSpellInfo then
				local okI, resI = pcall(GetSpellInfo, spell)
				if okI then spellName = resI end
			end
			if type(spellName) == "string" and spellName ~= ""
				and spellName:lower() == safeName:lower() then
				local tex = nil
				if C_Spell and C_Spell.GetSpellTexture then
					local okT, resT = pcall(C_Spell.GetSpellTexture, spell)
					if okT and type(resT) == "number" then tex = resT end
				end
				if not tex and GetSpellTexture then
					local okT2, resT2 = pcall(GetSpellTexture, spell)
					if okT2 and type(resT2) == "number" then tex = resT2 end
				end
				if tex then extraMeta = { spellIcon = tex } end
			end
		end
		if type(resolvedSid) == "number" then
			self:EmitBuffNotification(resolvedSid, BuildAuraNotifText(prefix, name), color, "auras", extraMeta, gained ~= true)
		else
			self:EmitNotification(BuildAuraNotifText(prefix, name), color, "auras", extraMeta)
		end
	end)
end

------------------------------------------------------------------------
-- Buff recast pairing
-- Recasting a buff you already have refreshes it: no aura is added, and in
-- secret contexts the UNIT_AURA payload can't be read at all. A cast of a
-- spell we've previously seen as our own buff, within 0.5s of an unreadable
-- aura update, re-shows that buff's cached name/icon.
------------------------------------------------------------------------
function Core:TryRecastBuffMatch()
	local cast = self._pendingBuffCast
	if type(cast) ~= "table" then return end
	local now = GetTime and GetTime() or 0
	if now - (cast.at or 0) > 2.0 then
		self._pendingBuffCast = nil
		return
	end
	local unread = self._lastUnreadAuraAt
	if type(unread) ~= "number" or math.abs(cast.at - unread) > 0.5 then return end
	self._pendingBuffCast = nil
	local entry = self._buffSpellCache and self._buffSpellCache[cast.spell]
	if type(entry) ~= "table" then return end
	-- A secret aura update coincided with this cast: record it as a seen buff
	-- so the Buff Rules "Recent Buffs" list populates in secret contexts.
	self:RecordRecentBuff(cast.spell)
	local now2 = GetTime and GetTime() or 0
	-- If notifyOnCast already announced this application, skip the gain emit
	-- but still track the pairing for fade attribution.
	local castNotified = self._lastCastNotifySpellId == cast.spell
		and type(cast.at) == "number" and (now2 - cast.at) <= 1.0
	if castNotified then
		self._pairedAuraActive = self._pairedAuraActive or {}
		self._pairedAuraActive[cast.spell] = now2
		self._pendingBuffCast = nil
		return
	end
	if self._auraInitInProgress or (self._suppressAurasUntil and now2 < self._suppressAurasUntil) then return end
	local okToShow = self:ShouldEmitBuffNotif(cast.spell, true, false, entry.name, true)
	if not okToShow then return end
	-- Mark the aura as handled so the combat-text fallback doesn't double it.
	self._auraReadAt = now2
	local extraMeta = nil
	if entry.icon ~= nil and (type(entry.icon) == "string" or type(entry.icon) == "number") then
		extraMeta = { spellIcon = entry.icon }
	end
	self:EmitBuffNotification(cast.spell, BuildAuraNotifText("+", entry.name or "Aura"),
		{r = 0.5, g = 0.8, b = 1.0}, "auras", extraMeta)
	-- Track the pairing so a later secret SPELL_AURA_END can be attributed
	-- back to this buff when it's the only active candidate.
	self._pairedAuraActive = self._pairedAuraActive or {}
	self._pairedAuraActive[cast.spell] = now2
end

-- Debug helper: dump the player's helpful auras (cache + live scan) so absorb
-- sources can be identified. Secret values are never inspected; names print
-- as <secret> when unreadable, spellIDs print when they are safe numbers.
function Core:DebugDumpPlayerAuras(tag)
	local Addon = ZSBT and ZSBT.Addon
	if not (Addon and Addon.Dbg) then return end
	if (Addon:GetDebugLevel("incoming") or 0) < 4 then return end
	tag = tag or "AURA_DUMP"
	local function sstr(v)
		if v == nil then return "nil" end
		if type(v) == "number" then return tostring(v) end
		if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
		local ok, s = pcall(tostring, v)
		if ok and type(s) == "string" and #s > 0 and #s < 80 then return s end
		return "<secret>"
	end
	local map = self._auraInstanceMap or {}
	local sids = self._auraInstanceSpellIDs or {}
	local n = 0
	for id, name in pairs(map) do
		n = n + 1
		if n > 40 then break end
		Addon:Dbg("incoming", 4, ("[%s] cache inst=%s sid=%s name=%s")
			:format(tag, tostring(id), tostring(sids[id]), sstr(name)))
	end
	if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
		for i = 1, 40 do
			local ok, d = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
			if not ok or type(d) ~= "table" then break end
			local okF, sid, nm, inst = pcall(function()
				return (d.spellId or d.spellID), d.name, d.auraInstanceID
			end)
			if not okF then
				Addon:Dbg("incoming", 4, ("[%s] idx=%d <secret aura>"):format(tag, i))
			else
				Addon:Dbg("incoming", 4, ("[%s] idx=%d sid=%s name=%s inst=%s")
					:format(tag, i, sstr(sid), sstr(nm), tostring(inst)))
			end
		end
	end
	if n == 0 then
		Addon:Dbg("incoming", 4, ("[%s] no cached auras"):format(tag))
	end
end

function Core:InitLootTracking()
    if self._lootFrame then return end

	local function getLootSettings()
		local p = ZSBT.db and ZSBT.db.profile
		local loot = p and p.loot
		if type(loot) ~= "table" then loot = {} end
		return loot
	end

	local function getTemplate(key, fallback)
		local p = ZSBT.db and ZSBT.db.profile
		local t = p and p.notificationsTemplates
		local v = t and t[key]
		if type(v) ~= "string" or v == "" then
			return fallback
		end
		return v
	end

	local function getMoneyFormat(key, fallback)
		local p = ZSBT.db and ZSBT.db.profile
		local t = p and p.notificationsMoneyFormat
		local v = t and t[key]
		if type(v) ~= "string" or v == "" then
			return fallback
		end
		return v
	end

	local function applyTemplate(tpl, ctx)
		if type(tpl) ~= "string" or tpl == "" then return nil end
		ctx = ctx or {}
		local out = tpl
		out = out:gsub("%%e", tostring(ctx.e or ""))
		out = out:gsub("%%a", tostring(ctx.a or ""))
		out = out:gsub("%%t", tostring(ctx.t or ""))
		return out
	end

	local function convertGlobalStringToPattern(gs)
		if type(gs) ~= "string" or gs == "" then return nil end
		local pat = gs
		pat = pat:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
		pat = pat:gsub("%%%%%d%$d", "(%%d+)")
		pat = pat:gsub("%%%%d", "(%%d+)")
		pat = pat:gsub("%%%%%d%$s", "(.+)")
		pat = pat:gsub("%%%%s", "(.+)")
		return "^" .. pat .. "$"
	end

	local function buildPatterns(defs)
		for i = 1, #defs do
			local k = defs[i] and defs[i].key
			defs[i].pat = k and convertGlobalStringToPattern(_G[k]) or nil
		end
		return defs
	end

	local lootDefs = buildPatterns({
		{ key = "LOOT_ITEM_SELF", isCreate = false },
		{ key = "LOOT_ITEM_SELF_MULTIPLE", isCreate = false },
		{ key = "LOOT_ITEM_CREATED_SELF", isCreate = true },
		{ key = "LOOT_ITEM_CREATED_SELF_MULTIPLE", isCreate = true },
		{ key = "LOOT_ITEM_PUSHED_SELF", isCreate = true },
		{ key = "LOOT_ITEM_PUSHED_SELF_MULTIPLE", isCreate = true },
	})

	local moneyDefs = buildPatterns({
		{ key = "YOU_LOOT_MONEY" },
		{ key = "LOOT_MONEY_SPLIT" },
	})

	local currencyDefs = buildPatterns({
		{ key = "CURRENCY_GAINED" },
		{ key = "CURRENCY_GAINED_MULTIPLE" },
		{ key = "CURRENCY_GAINED_MULTIPLE_BONUS" },
	})

	local function escapePattern(s)
		if type(s) ~= "string" then return nil end
		return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
	end

	local GOLD = (type(GOLD_AMOUNT) == "string") and GOLD_AMOUNT:gsub(L["%%d *"], "") or nil
	local SILVER = (type(SILVER_AMOUNT) == "string") and SILVER_AMOUNT:gsub(L["%%d *"], "") or nil
	local COPPER = (type(COPPER_AMOUNT) == "string") and COPPER_AMOUNT:gsub(L["%%d *"], "") or nil
	local GOLD_PAT = GOLD and escapePattern(GOLD) or nil
	local SILVER_PAT = SILVER and escapePattern(SILVER) or nil
	local COPPER_PAT = COPPER and escapePattern(COPPER) or nil

	local function parseMoneyStringToCopper(moneyString)
		if type(moneyString) ~= "string" or moneyString == "" then return nil end
		local g, s, c = 0, 0, 0
		if GOLD_PAT then g = tonumber(moneyString:match("(%d+)%s*" .. GOLD_PAT) or "0") or 0 end
		if SILVER_PAT then s = tonumber(moneyString:match("(%d+)%s*" .. SILVER_PAT) or "0") or 0 end
		if COPPER_PAT then c = tonumber(moneyString:match("(%d+)%s*" .. COPPER_PAT) or "0") or 0 end
		local total = g * 10000 + s * 100 + c
		if total <= 0 then return nil end
		return total
	end

	local function recolorMoneyString(moneyString)
		if type(moneyString) ~= "string" or moneyString == "" then return moneyString end
		local s = moneyString
		if GOLD_PAT then s = s:gsub("(%d+)%s*" .. GOLD_PAT, "|cffffd700%1|r" .. GOLD) end
		if SILVER_PAT then s = s:gsub("(%d+)%s*" .. SILVER_PAT, "|cff808080%1|r" .. SILVER) end
		if COPPER_PAT then s = s:gsub("(%d+)%s*" .. COPPER_PAT, "|cffeda55f%1|r" .. COPPER) end
		return s
	end

	local function tryMatch(defs, msg)
		for i = 1, #defs do
			local d = defs[i]
			local pat = d and d.pat
			if pat then
				local a, b, c = msg:match(pat)
				if a ~= nil then
					return d, a, b, c
				end
			end
		end
		return nil
	end

	local function shouldShowItem(itemLink)
		local loot = getLootSettings()
		local show = true
		local itemName, _, itemQuality, _, _, itemType = nil
		if C_Item and C_Item.GetItemInfo then
			itemName, _, itemQuality, _, _, itemType = C_Item.GetItemInfo(itemLink)
		elseif GetItemInfo then
			itemName, _, itemQuality, _, _, itemType = GetItemInfo(itemLink)
		end

		if type(itemName) == "string" and itemName ~= "" then
			if type(loot.itemsAllowed) == "table" and loot.itemsAllowed[itemName] then
				return true
			end
			if type(loot.itemExclusions) == "table" and loot.itemExclusions[itemName] then
				show = false
			end
		end

		if type(itemQuality) == "number" then
			if type(loot.qualityExclusions) == "table" and loot.qualityExclusions[itemQuality] then
				show = false
			end
		end

		if loot.alwaysShowQuestItems == true and type(itemType) == "string" then
			local questType = nil
			if C_Item and C_Item.GetItemClassInfo then
				questType = C_Item.GetItemClassInfo(LE_ITEM_CLASS_QUESTITEM or (Enum and Enum.ItemClass and Enum.ItemClass.Questitem))
			end
			if questType and itemType == questType then
				show = true
			end
		end

		if type(itemName) == "string" and itemName ~= "" then
			if type(loot.itemsAllowed) == "table" and loot.itemsAllowed[itemName] then
				show = true
			end
		end

		return show
	end

	self._lootFrame = CreateFrame("Frame")
	self._lootFrame:RegisterEvent("CHAT_MSG_LOOT")
	self._lootFrame:RegisterEvent("CHAT_MSG_MONEY")
    self._lootFrame:RegisterEvent("CHAT_MSG_CURRENCY")
    self._lootFrame:SetScript("OnEvent", function(_, event, msg)
        if not Core:IsMasterEnabled() then return end
        if not msg or type(msg) ~= "string" then return end
        if not ZSBT.IsSafeString(msg) then return end

        if event == "CHAT_MSG_MONEY" then
            local d, moneyString = tryMatch(moneyDefs, msg)
            local fmt = getMoneyFormat("lootMoney", "text")
            local text = nil
            if fmt == "icons" and GetCoinTextureString then
                local copper = parseMoneyStringToCopper(moneyString or msg)
                if copper then
                    text = GetCoinTextureString(copper)
                end
            end
            if not text then
                text = recolorMoneyString(moneyString or msg)
            end
            local tpl = getTemplate("lootMoney", "+%e")
            local out = applyTemplate(tpl, { e = text })
            if out and out ~= "" then
                Core:EmitNotification(out, {r = 1.0, g = 0.85, b = 0.0}, "lootMoney")
            end
        elseif event == "CHAT_MSG_LOOT" then
            local d, itemLinkOrName, amount = tryMatch(lootDefs, msg)
            local loot = getLootSettings()
            if d and d.isCreate == true and loot.showCreated ~= true then
                return
            end
            local itemLink = itemLinkOrName
            if type(itemLink) ~= "string" or itemLink == "" then
                return
            end
            if not shouldShowItem(itemLink) then
                return
            end
            local numLooted = tonumber(amount) or 1
            local total = nil
            if C_Item and C_Item.GetItemCount then
                total = C_Item.GetItemCount(itemLink)
            elseif GetItemCount then
                total = GetItemCount(itemLink)
            end
            if type(total) ~= "number" or total <= 0 then
                total = numLooted
            else
                total = total + numLooted
            end
            local tpl = getTemplate("lootItems", "+%a %e (%t)")
            local out = applyTemplate(tpl, { e = itemLink, a = numLooted, t = total })
            if out and out ~= "" then
                Core:EmitNotification(out, {r = 0.6, g = 0.4, b = 1.0}, "lootItems")
            end
        elseif event == "CHAT_MSG_CURRENCY" then
            local d, currencyLinkOrName, amount = tryMatch(currencyDefs, msg)
            local link = currencyLinkOrName
            if type(link) ~= "string" or link == "" then
                return
            end
            local numLooted = tonumber(amount) or 1
            local text = link
            local total = nil
            if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfoFromLink then
                local info = C_CurrencyInfo.GetCurrencyInfoFromLink(link)
                if info and type(info.quantity) == "number" then
                    total = info.quantity
                end
            end
            if type(total) ~= "number" or total < 0 then
                total = 0
            end
            local tpl = getTemplate("lootCurrency", "+%a %e (%t)")
            local out = applyTemplate(tpl, { e = text, a = numLooted, t = total })
            if out and out ~= "" then
                Core:EmitNotification(out, {r = 1.0, g = 0.82, b = 0.0}, "lootCurrency")
            end
        end
    end)
end

------------------------------------------------------------------------
-- Honor / XP / Reputation Tracking
-- Backup path via CHAT_MSG events (COMBAT_TEXT_UPDATE may not fire
-- for all honor/XP gains, especially from quests/bonus events).
-- Dedup: COMBAT_TEXT_UPDATE path sets timestamps; CHAT_MSG skips if recent.
------------------------------------------------------------------------
Core._lastXPNotifAt = 0
Core._lastCompanionXPNotifAt = 0
Core._lastHonorNotifAt = 0
Core._lastRepNotifAt = 0
local PROGRESS_DEDUP_WINDOW = 1.0  -- 1 second dedup window

Core._utKillLastAt = 0
Core._utKillChain = 0

local _repChangePatterns = nil

local function _escapeLuaPattern(s)
	return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

local function _formatToLuaPattern(fmt)
	if type(fmt) ~= "string" or fmt == "" then return nil end
	local litPercent = "\002"
	local tokenS = "\003"
	local tokenD = "\004"
	local s = fmt
	s = s:gsub("%%%%", litPercent)
	s = s:gsub("%%[%d%$]*s", tokenS)
	s = s:gsub("%%[%d%$]*d", tokenD)
	s = _escapeLuaPattern(s)
	s = s:gsub(litPercent, "%%")
	s = s:gsub(tokenS, "(.+)")
	s = s:gsub(tokenD, "([%d,]+)")
	return s
end

local function _initRepChangePatterns()
	if _repChangePatterns then return end
	_repChangePatterns = {}

	local function add(fmt, sign)
		local pat = _formatToLuaPattern(fmt)
		if pat and pat ~= "" then
			table.insert(_repChangePatterns, { pat = pat, sign = sign })
		end
	end

	add(_G.FACTION_STANDING_INCREASED, 1)
	add(_G.FACTION_STANDING_INCREASED_GENERIC, 1)
	add(_G.FACTION_STANDING_INCREASED_ACH_BONUS, 1)
	add(_G.FACTION_STANDING_INCREASED_ACH_BONUS_GENERIC, 1)
	add(_G.FACTION_STANDING_DECREASED, -1)
	add(_G.FACTION_STANDING_DECREASED_GENERIC, -1)

	add(L["Reputation with %s increased by %d."], 1)
	add(L["Reputation with %s decreased by %d."], -1)
	add(L["Your reputation with %s has increased by %d."], 1)
	add(L["Your reputation with %s has decreased by %d."], -1)

	table.insert(_repChangePatterns, { pat = L["Reputation with (.+) increased by ([%d,]+)"], sign = 1 })
	table.insert(_repChangePatterns, { pat = L["Reputation with (.+) decreased by ([%d,]+)"], sign = -1 })
	table.insert(_repChangePatterns, { pat = L["Your reputation with (.+) has increased by ([%d,]+)"], sign = 1 })
	table.insert(_repChangePatterns, { pat = L["Your reputation with (.+) has decreased by ([%d,]+)"], sign = -1 })
end

function Core:ParseReputationChangeMessage(msg)
	_initRepChangePatterns()
	if type(msg) ~= "string" or msg == "" then return nil end

	for _, entry in ipairs(_repChangePatterns) do
		local a, b = msg:match(entry.pat)
		if a and b then
			local na = tonumber((tostring(a):gsub(",", "")))
			local nb = tonumber((tostring(b):gsub(",", "")))
			local faction, amount
			if na and not nb then
				amount = na
				faction = tostring(b)
			elseif nb and not na then
				amount = nb
				faction = tostring(a)
			elseif nb and na then
				amount = nb
				faction = tostring(a)
			else
				amount = tonumber((tostring(b):gsub(",", "")))
				faction = tostring(a)
			end

			if type(amount) == "number" and amount > 0 and faction and faction ~= "" then
				return entry.sign * amount, faction
			end
		end
	end

	return nil
end

function Core:GetWatchedFactionName()
	if C_Reputation and type(C_Reputation.GetWatchedFactionData) == "function" then
		local data = C_Reputation.GetWatchedFactionData()
		if data and type(data.name) == "string" and data.name ~= "" then
			return data.name
		end
	end

	if type(GetWatchedFactionInfo) == "function" then
		local name = GetWatchedFactionInfo()
		if type(name) == "string" and name ~= "" then
			return name
		end
	end

	return nil
end

Core._lastWatchedRepValue = Core._lastWatchedRepValue

function Core:GetWatchedReputationValue()
	if type(GetWatchedFactionInfo) == "function" then
		local name, _, _, _, _, barValue = GetWatchedFactionInfo()
		if type(name) == "string" and name ~= "" and type(barValue) == "number" then
			return barValue, name
		end
	end

	if C_Reputation and type(C_Reputation.GetWatchedFactionData) == "function" then
		local data = C_Reputation.GetWatchedFactionData()
		if data and type(data.name) == "string" and data.name ~= "" then
			local candidates = { "currentReputation", "currentStanding", "barValue", "currentValue", "value" }
			for _, k in ipairs(candidates) do
				if type(data[k]) == "number" then
					return data[k], data.name
				end
			end
		end
	end

	return nil
end

function Core:ComputeWatchedReputationDelta()
	local current, name = self:GetWatchedReputationValue()
	if type(current) ~= "number" then
		return nil
	end
	local prev = self._lastWatchedRepValue
	self._lastWatchedRepValue = current
	if type(prev) ~= "number" then
		return nil
	end
	local delta = current - prev
	if delta == 0 then
		return nil
	end
	return delta, name
end

function Core:InitProgressTracking()
    if self._progressFrame then return end
    self._progressFrame = CreateFrame("Frame")
    self._progressFrame:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
	self._progressFrame:RegisterEvent("CHAT_MSG_SYSTEM")
	self._progressFrame:RegisterEvent("CHAT_MSG_COMBAT_MISC_INFO")
    self._progressFrame:RegisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN")
    self._progressFrame:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
	pcall(function() self._progressFrame:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE_STAT") end)
	if not self._companionXPChatHooked then
		self._companionXPChatHooked = true
		pcall(function()
			local function hookChatFrame(f)
				if not f or type(f) ~= "table" then return end
				if type(f.AddMessage) ~= "function" then return end
				hooksecurefunc(f, "AddMessage", function(_, text)
					if not Core:IsMasterEnabled() then return end
					if type(text) ~= "string" then return end
					local isSafeText = (ZSBT.IsSafeString and ZSBT.IsSafeString(text)) == true
					-- WoW 12.x can pass "secret" strings through chat output; never index/match them.
					if not isSafeText then return end
					local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("diagnostics"))
						or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
					local okName, playerName = pcall(UnitName, "player")
					if not okName or type(playerName) ~= "string" then playerName = nil end
					local who, amt = text:match(L["(.+) has gained (%d[%d,]+) experience"])
					if not who or not amt then
						who, amt = text:match(L["(.+) gains (%d[%d,]+) experience"])
					end
					if not who or not amt then return end
					if playerName and who == playerName then return end
					local tNow = GetTime()
					if (tNow - (Core._lastCompanionXPNotifAt or 0)) < PROGRESS_DEDUP_WINDOW then return end
					local xp = amt:gsub(",", "")
					Core._lastCompanionXPNotifAt = tNow
					local whoLabel = who
					if not (ZSBT.IsSafeString and ZSBT.IsSafeString(whoLabel)) then
						whoLabel = "Companion"
					end
					Core:EmitNotification("+" .. xp .. " XP (" .. whoLabel .. ")", {r = 0.6, g = 0.4, b = 1.0}, "companionXP")
					if dl >= 4 and Addon and Addon.Dbg then
						local okS, sText = pcall(tostring, text)
						if not okS or type(sText) ~= "string" or not (ZSBT.IsSafeString and ZSBT.IsSafeString(sText)) then sText = "<secret>" end
						Addon:Dbg("diagnostics", 4, "[XPDBG] ev=CHATFRAME safe=" .. tostring(isSafeText)
							.. " who=" .. tostring(whoLabel)
							.. " xp=" .. tostring(xp)
							.. " msg=" .. sText)
					elseif dl >= 4 and ZSBT.Addon and ZSBT.Addon.Print then
						local okS, sText = pcall(tostring, text)
						if not okS or type(sText) ~= "string" or not (ZSBT.IsSafeString and ZSBT.IsSafeString(sText)) then sText = "<secret>" end
						ZSBT.Addon:Print("[XPDBG] ev=CHATFRAME safe=" .. tostring(isSafeText) .. " who=" .. tostring(whoLabel) .. " xp=" .. tostring(xp) .. " msg=" .. sText)
					end
				end)
			end
			hookChatFrame(DEFAULT_CHAT_FRAME)
			hookChatFrame(ChatFrame1)
		end)
	end
    self._progressFrame:SetScript("OnEvent", function(_, event, msg)
        if not Core:IsMasterEnabled() then return end
        if not msg or type(msg) ~= "string" then return end
		local isSafe = (ZSBT.IsSafeString and ZSBT.IsSafeString(msg)) == true
		local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("diagnostics"))
			or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
		local isXPEvent = event == "CHAT_MSG_COMBAT_XP_GAIN" or event == "CHAT_MSG_SYSTEM" or event == "CHAT_MSG_COMBAT_MISC_INFO"
		if not isSafe and not isXPEvent then return end
        local t = GetTime()

		if event == "CHAT_MSG_COMBAT_XP_GAIN" or event == "CHAT_MSG_SYSTEM" or event == "CHAT_MSG_COMBAT_MISC_INFO" then
			local okName, playerName = pcall(UnitName, "player")
			if not okName or type(playerName) ~= "string" then playerName = nil end
			local xp, whoXP = nil, nil
			pcall(function()
				xp = msg:match(L["You gain (%d[%d,]+) experience"])
				if not xp then
					local who, amt = msg:match(L["(.+) gains (%d[%d,]+) experience"])
					if not who or not amt then
						who, amt = msg:match(L["(.+) has gained (%d[%d,]+) experience"])
					end
					if who and amt then
						if playerName and who == playerName then
							xp = amt
						else
							whoXP = who
							xp = amt
						end
					end
				end
			end)
			if dl >= 4 and Addon and Addon.Dbg then
				local okS, sMsg = pcall(tostring, msg)
				if not okS or type(sMsg) ~= "string" or not (ZSBT.IsSafeString and ZSBT.IsSafeString(sMsg)) then sMsg = "<secret>" end
				Addon:Dbg("diagnostics", 4, "[XPDBG] ev=" .. tostring(event)
					.. " safe=" .. tostring(isSafe)
					.. " who=" .. tostring(whoXP)
					.. " xp=" .. tostring(xp)
					.. " msg=" .. sMsg)
			elseif dl >= 4 and ZSBT.Addon and ZSBT.Addon.Print then
				local okS, sMsg = pcall(tostring, msg)
				if not okS or type(sMsg) ~= "string" or not (ZSBT.IsSafeString and ZSBT.IsSafeString(sMsg)) then sMsg = "<secret>" end
				ZSBT.Addon:Print("[XPDBG] ev=" .. tostring(event) .. " safe=" .. tostring(isSafe) .. " who=" .. tostring(whoXP) .. " xp=" .. tostring(xp) .. " msg=" .. sMsg)
			end
			if xp then
				xp = xp:gsub(",", "")
				if whoXP and whoXP ~= "" then
					if (t - Core._lastCompanionXPNotifAt) < PROGRESS_DEDUP_WINDOW then return end
					Core._lastCompanionXPNotifAt = t
					local whoLabel = whoXP
					if not (ZSBT.IsSafeString and ZSBT.IsSafeString(whoLabel)) then
						whoLabel = "Companion"
					end
					Core:EmitNotification("+" .. xp .. " XP (" .. whoLabel .. ")", {r = 0.6, g = 0.4, b = 1.0}, "companionXP")
				elseif isSafe then
					if (t - Core._lastXPNotifAt) < PROGRESS_DEDUP_WINDOW then return end
					Core._lastXPNotifAt = t
					Core:EmitNotification("+" .. xp .. " XP", {r = 0.6, g = 0.4, b = 1.0}, "playerXP")
				end
			end
        elseif event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
            if (t - Core._lastHonorNotifAt) < PROGRESS_DEDUP_WINDOW then return end
            local honor = msg:match(L["(%d[%d,]+) honor"])
            if honor then
                honor = honor:gsub(",", "")
                Core._lastHonorNotifAt = t
				Core:EmitNotification("+" .. honor .. L[" Honor"], {r = 1.0, g = 0.5, b = 0.0}, "honor")
            end
		elseif event == "CHAT_MSG_COMBAT_FACTION_CHANGE" or event == "CHAT_MSG_COMBAT_FACTION_CHANGE_STAT" then
			if (t - Core._lastRepNotifAt) < PROGRESS_DEDUP_WINDOW then return end
			local delta, faction = Core:ParseReputationChangeMessage(msg)
			if delta and faction then
				Core._lastRepNotifAt = t
				if delta > 0 then
					Core:EmitNotification("+" .. tostring(delta) .. " " .. faction, {r = 0.0, g = 0.8, b = 0.6}, "reputation")
				else
					Core:EmitNotification(tostring(delta) .. " " .. faction, {r = 0.8, g = 0.2, b = 0.2}, "reputation")
				end
			end
        end
    end)
end

------------------------------------------------------------------------
-- Power Gain Notifications
-- Fires when player reaches max resource (100 Rage, full combo pts, etc.)
------------------------------------------------------------------------
Core._lastPowerPct = {}

function Core:InitPowerTracking()
    if self._powerFrame then return end
    self._powerFrame = CreateFrame("Frame")
    self._powerFrame:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
    self._powerFrame:SetScript("OnEvent", function(_, event, unit, powerType)
        if unit ~= "player" then return end
        if not Core:IsMasterEnabled() then return end

        -- Track every power type this class can use so each resource's
        -- "Resource Full" text notification fires independently.
        local types = {}
        for i = 0, 20 do
            if ZSBT.CpPowerTypeAllowed and ZSBT.CpPowerTypeAllowed(i) then
                types[#types + 1] = i
            end
        end
        if #types == 0 then
            local pType = UnitPowerType("player")
            if pType ~= nil then types[1] = pType end
        end

        for _, pt in ipairs(types) do
            local current = UnitPower("player", pt)
            local max = UnitPowerMax("player", pt)

            if ZSBT.IsSafeNumber(current) and ZSBT.IsSafeNumber(max) and max > 0 then
                local pct = (current / max) * 100
                local prevPct = Core._lastPowerPct[pt] or 0
                Core._lastPowerPct[pt] = pct

                -- Notify at full resource. Per-resource opt-in: the
                -- "power_<pt>" flag must be explicitly enabled in that
                -- resource's config window (absent = off, so classes with
                -- several power types don't spam "X Full!" texts).
                if pct >= 100 and prevPct < 100 then
                    local p = ZSBT.db and ZSBT.db.profile
                    local n = p and p.notifications
                    if n and n["power_" .. pt] == true then
                        Core:EmitNotificationTemplate("power_" .. pt, "%e Full!",
                            { e = ZSBT.PowerTypeName and ZSBT.PowerTypeName(pt) or "Resource" },
                            {r = 1.0, g = 0.6, b = 0.0})
                    end
                end
            end
        end
    end)
end

------------------------------------------------------------------------
-- Resource Counter
-- Persistent on-screen counters for unit power types (combo points,
-- soul shards, mana, etc.), one frame per configured power type.
------------------------------------------------------------------------

local CP_ANCHORS = {
    ["Top Left"]     = { fx = -1, fy =  1 },
    ["Top"]          = { fx =  0, fy =  1 },
    ["Top Right"]    = { fx =  1, fy =  1 },
    ["Left"]         = { fx = -1, fy =  0 },
    ["Center"]       = { fx =  0, fy =  0 },
    ["Right"]        = { fx =  1, fy =  0 },
    ["Bottom Left"]  = { fx = -1, fy = -1 },
    ["Bottom"]       = { fx =  0, fy = -1 },
    ["Bottom Right"] = { fx =  1, fy = -1 },
}

local CP_MAX_PIPS = 12
local CP_PIP_SIZE = 12
local CP_PIP_SPACING = 18

-- DK rune slot shapes (power type 5). White-with-alpha TGAs tinted by the
-- counter's color settings; "square" could reuse WHITE8X8 but keeping all
-- four in Media keeps the code path uniform.
local RUNE_SHAPE_TEX = {
    square  = "Interface\\AddOns\\ZSBT\\Media\\Textures\\ZSBT_Rune_Square.tga",
    diamond = "Interface\\AddOns\\ZSBT\\Media\\Textures\\ZSBT_Rune_Diamond.tga",
    circle  = "Interface\\AddOns\\ZSBT\\Media\\Textures\\ZSBT_Rune_Circle.tga",
    hexagon = "Interface\\AddOns\\ZSBT\\Media\\Textures\\ZSBT_Rune_Hexagon.tga",
}

------------------------------------------------------------------------
-- Resource counters are keyed by power type under
-- profile.resourceCounters[powerType]. Legacy profiles keep their single
-- counter settings in flat comboPoints.* keys; the first access migrates
-- them onto the effective power type (saved powerType when the class can
-- use it, otherwise the unit's main power).
------------------------------------------------------------------------

-- Power types each class can actually use. UnitPowerMax returns a positive
-- max for EVERY power type (combo points reads 5 even on a warlock), so
-- "readable value" checks alone cannot filter — gate by class token.
local ZSBT_CP_CLASS_POWERS = {
	WARRIOR      = { [1] = true },
	PALADIN      = { [0] = true, [9] = true },
	HUNTER       = { [2] = true },
	ROGUE        = { [3] = true, [4] = true },
	PRIEST       = { [0] = true, [13] = true },
	DEATHKNIGHT  = { [5] = true, [6] = true },
	SHAMAN       = { [0] = true, [11] = true },
	MAGE         = { [0] = true, [16] = true },
	WARLOCK      = { [0] = true, [7] = true },
	MONK         = { [3] = true, [12] = true },
	DRUID        = { [0] = true, [1] = true, [3] = true, [4] = true },
	DEMONHUNTER  = { [17] = true, [18] = true },
	EVOKER       = { [0] = true },
}

function ZSBT.CpPowerTypeAllowed(i)
	local _, classToken = UnitClass("player")
	local allowed = classToken and ZSBT_CP_CLASS_POWERS[classToken]
	if not allowed then return true end
	if allowed[i] then return true end
	-- Always allow the unit's current main power type so forms/specs we
	-- didn't enumerate still work.
	local main = UnitPowerType and UnitPowerType("player")
	return i == main
end

local CP_POWER_NAMES = {
	[0] = "Mana", [1] = "Rage", [2] = "Focus", [3] = "Energy",
	[4] = "Combo Points", [5] = "Runes", [6] = "Runic Power",
	[7] = "Soul Shards", [8] = "Astral Power", [9] = "Holy Power",
	[11] = "Maelstrom", [12] = "Chi", [13] = "Insanity",
	[16] = "Arcane Charges", [17] = "Fury", [18] = "Pain",
}

function ZSBT.PowerTypeName(i)
	return CP_POWER_NAMES[tonumber(i) or -1] or ("Power " .. tostring(i))
end

-- Retail 12.x secrets the *current* value of primary power types (mana,
-- rage, ...) while capped count resources (combo points, soul shards, ...)
-- stay readable. C_Secrets.ShouldUnitPowerBeSecret is the authoritative
-- per-type answer; older clients lack it and report false (readable).
function ZSBT.PowerTypeSecret(i)
	if C_Secrets and C_Secrets.ShouldUnitPowerBeSecret then
		local ok, res = pcall(C_Secrets.ShouldUnitPowerBeSecret, "player", tonumber(i))
		if ok and type(res) == "boolean" then return res end
	end
	return false
end

local function CpEffectivePowerType()
	local p = ZSBT.db and ZSBT.db.profile
	local cp = p and p.comboPoints
	local saved = cp and tonumber(cp.powerType)
	if saved and ZSBT.CpPowerTypeAllowed(saved)
		and not ZSBT.PowerTypeSecret(saved) then
		return saved
	end
	local main = UnitPowerType and UnitPowerType("player")
	if main ~= nil and not ZSBT.PowerTypeSecret(main) then return main end
	-- Main power is secret (e.g. warlock mana on Retail): fall back to the
	-- first class-allowed, non-secret type with a real pool.
	for i = 0, 20 do
		if ZSBT.CpPowerTypeAllowed(i) and not ZSBT.PowerTypeSecret(i) then
			local mx = UnitPowerMax and UnitPowerMax("player", i)
			if ZSBT.IsSafeNumber(mx) and mx > 0 then return i end
		end
	end
	return (main ~= nil) and main or (saved or 0)
end

-- Read accessor: returns the counter config for a power type, or nil.
-- Lazily migrates the legacy flat comboPoints.* block the first time.
function ZSBT.ResourceCounterConfig(powerType)
	powerType = tonumber(powerType)
	if not powerType then return nil end
	local p = ZSBT.db and ZSBT.db.profile
	local rc = p and p.resourceCounters
	if rc == nil then
		rc = {}
		p.resourceCounters = rc
		local cp = p.comboPoints
		if cp then
			local pt = CpEffectivePowerType()
			local dst = {}
			for k, v in pairs(cp) do
				if k ~= "powerType" then dst[k] = v end
			end
			rc[pt] = dst

			-- Carry the legacy global "power" notification settings over to
			-- the per-resource "power_<pt>" category (once).
			local nkey = "power_" .. pt
			if type(p.notifications) == "table" and p.notifications[nkey] == nil and p.notifications.power ~= nil then
				p.notifications[nkey] = p.notifications.power
			end
			if type(p.notificationsTemplates) == "table" and p.notificationsTemplates[nkey] == nil and p.notificationsTemplates.power ~= nil then
				p.notificationsTemplates[nkey] = p.notificationsTemplates.power
			end
			if type(p.notificationsRouting) == "table" and p.notificationsRouting[nkey] == nil and p.notificationsRouting.power ~= nil then
				p.notificationsRouting[nkey] = p.notificationsRouting.power
			end
			if type(p.notificationsPerType) == "table" and p.notificationsPerType[nkey] == nil and type(p.notificationsPerType.power) == "table" then
				p.notificationsPerType[nkey] = p.notificationsPerType.power
			end
		end
	end
	return rc[powerType]
end

-- Sensible out-of-box appearance for a counter created from scratch
-- (enabled stays unset so "Show Resource Tracker" begins off).
local RC_DEFAULTS = {
	attachArea = "None",
	anchor = "Bottom",
	xOffset = 7,
	yOffset = 128,
	format = "pips",
	color = { r = 0.8274510502815247, g = 0.0, b = 0.03921568766236305 },
	emptyColor = { r = 0.35, g = 0.35, b = 0.35 },
	outlineColor = { r = 0.0, g = 0.0, b = 0.0 },
	fontSize = 0,
	fontOverride = true,
	fontFace = "ZSBT: Bungee",
	fontOutline = "Thin",
	fontScale = 2.0,
	width = 257,
	height = 77,
	hideAtZero = true,
	hideOutOfCombat = true,
	fullSoundEnabled = false,
	fullSoundKey = "None",
	fullEffect = "none",
}

-- Write accessor: ensures profile.resourceCounters exists (running the
-- legacy migration if needed) and returns the slot for powerType.
function ZSBT.ResourceCounterConfigWrite(powerType)
	powerType = tonumber(powerType)
	if not powerType then return nil end
	ZSBT.ResourceCounterConfig(0) -- force migration/init
	local p = ZSBT.db and ZSBT.db.profile
	local rc = p and p.resourceCounters
	if not rc then return nil end
	local s = rc[powerType]
	if not s then
		s = {}
		for k, v in pairs(RC_DEFAULTS) do s[k] = v end
		rc[powerType] = s
	end
	return s
end

-- Edit mode is shared: scroll-area unlock OR the counter's own unlock.
local function CpEditUnlocked()
    return (ZSBT.IsScrollAreasUnlocked and ZSBT.IsScrollAreasUnlocked())
        or ZSBT._cpUnlocked == true
end

function ZSBT.IsResourceCounterUnlocked()
    return ZSBT._cpUnlocked == true
end

function ZSBT.ToggleResourceCounterUnlock()
    ZSBT._cpUnlocked = not (ZSBT._cpUnlocked == true)
    if ZSBT.RefreshComboPoints then ZSBT.RefreshComboPoints() end
end

-- Gold border shown around the counter while it is in edit mode. Built from
-- edge textures (SetBackdrop is unavailable on this client's frames).
local function SetCpBorder(frame, on)
    if on then
        if not frame._cpBorder then
            local edges = {}
            for _, e in ipairs({
                { "TOPLEFT", "TOPRIGHT", 1, -1, -1, -3 },
                { "BOTTOMLEFT", "BOTTOMRIGHT", 1, 3, -1, 1 },
                { "TOPLEFT", "BOTTOMLEFT", 1, -1, 3, 1 },
                { "TOPRIGHT", "BOTTOMRIGHT", -3, -1, -1, 1 },
            }) do
                local t = frame:CreateTexture(nil, "OVERLAY")
                t:SetColorTexture(1, 0.82, 0, 0.9)
                t:SetPoint("TOPLEFT", frame, e[1], e[3], e[4])
                t:SetPoint("BOTTOMRIGHT", frame, e[2], e[5], e[6])
                t:Hide()
                edges[#edges + 1] = t
            end
            frame._cpBorder = edges
        end
        for _, t in ipairs(frame._cpBorder) do t:Show() end
    elseif frame._cpBorder then
        for _, t in ipairs(frame._cpBorder) do t:Hide() end
    end
end

local function ResolveCpFont(cfg)
    local profile = ZSBT.db and ZSBT.db.profile
    local general = profile and profile.general and profile.general.font or {}
    local LSM = LibStub("LibSharedMedia-3.0", true)
    local override = cfg and cfg.fontOverride == true
    local faceKey = general.face
    if override and type(cfg.fontFace) == "string" and cfg.fontFace ~= "" then
        faceKey = cfg.fontFace
    end
    local face = "Fonts\\FRIZQT__.TTF"
    local fetched = LSM and faceKey and LSM:Fetch("font", faceKey)
    if fetched then face = fetched end
    local size = tonumber(cfg and cfg.fontSize) or 0
    if size <= 0 then
        local sc = override and (tonumber(cfg.fontScale) or 1.0) or 1.0
        size = math.max(8, math.floor(((tonumber(general.size) or 16) * sc) + 0.5))
    end
    local outlineKey = general.outline or "Thin"
    if override and type(cfg.fontOutline) == "string" and cfg.fontOutline ~= "" then
        outlineKey = cfg.fontOutline
    end
    local outline = (ZSBT.OUTLINE_STYLES and ZSBT.OUTLINE_STYLES[outlineKey]) or "OUTLINE"
    return face, size, outline
end

local function PositionComboPoints(frame, cfg)
    local areaName = cfg.attachArea
    local areas = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.scrollAreas
    local area = areaName and areaName ~= "" and areaName ~= "None" and areas and areas[areaName]

    -- Include live area geometry so dragging a scroll area re-anchors the counter.
    local geo = ""
    if area then
        geo = "|" .. tostring(area.xOffset) .. "," .. tostring(area.yOffset)
            .. "," .. tostring(area.width) .. "," .. tostring(area.height)
    end
    local posKey = table.concat({
        tostring(cfg.attachArea), tostring(cfg.anchor),
        tostring(cfg.xOffset), tostring(cfg.yOffset), geo,
    }, "|")
    if frame._cpPosKey == posKey then return end
    frame._cpPosKey = posKey

    local px, py = tonumber(cfg.xOffset) or 0, tonumber(cfg.yOffset) or 0
    if area then
        local a = CP_ANCHORS[cfg.anchor]
        if not a and type(cfg.anchor) == "string" then
            a = CP_ANCHORS[cfg.anchor:sub(1, 1):upper() .. cfg.anchor:sub(2):lower()]
        end
        a = a or CP_ANCHORS["Center"] or { fx = 0, fy = 0 }
        px = (tonumber(area.xOffset) or 0) + a.fx * ((tonumber(area.width) or 100) / 2)
        py = (tonumber(area.yOffset) or 0) + a.fy * ((tonumber(area.height) or 100) / 2)
    end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", px, py)
end

-- Full-effect styles animate the counter's own pip textures / text and LOOP
-- while the resource stays at max, giving a persistent "ready" indicator.
-- The ticker is stopped by RefreshComboPoints the moment the value drops.
local CP_FX_DUR = {
    ignite = 1.2, chromatic = 1.6, shatter = 1.4, afterimage = 1.6,
}

local RefreshComboPoints -- forward declaration (defined below)

local function HsvToRgb(h, s, v)
    h = (h % 360) / 60
    local i = math.floor(h) % 6
    local f = h - math.floor(h)
    local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    if i == 0 then return v, t, p
    elseif i == 1 then return q, v, p
    elseif i == 2 then return p, v, t
    elseif i == 3 then return p, q, v
    elseif i == 4 then return t, p, v
    else return v, p, q end
end

local function CpFxUpdate(frame, cfg)
    local st = frame._cpFx
    if not st then return end
    local p = (GetTime() - st.t0) / st.dur
    if p >= 1 then
        -- Loop: the effect runs continuously while the resource is maxed.
        -- RefreshComboPoints cancels the ticker when the value drops.
        st.t0 = GetTime()
        p = 0
        if st.style == "shatter" and st.dirs then
            for i = 1, st.mx do
                local a = math.random() * 6.28318
                local d = 20 + math.random() * 30
                st.dirs[i] = { math.cos(a) * d, math.sin(a) * d }
            end
        end
    end

    local style = st.style
    local gx, gy, gs, ga = 0, 0, 1, 1
    local hueFx = nil
    local flicker = nil

    if style == "ignite" then
        gs = 1 + 0.07 * math.sin(p * math.pi * 4)
        flicker = (math.sin(p * math.pi * 6) > 0) and 0.75 or 0.15
    elseif style == "chromatic" then
        hueFx = (p * 360) % 360
    elseif style == "afterimage" then
        gs = 1 + 0.22 * math.sin(p * math.pi * 2)
    end

    local pips = frame._cpPips
    local backs = frame._cpPipBacks
    local onR, onG, onB = st.onR, st.onG, st.onB

    for i = 1, st.mx do
        local pip = pips[i]
        local back = backs[i]
        local dx, dy, s, a = gx, gy, gs, ga

        if style == "shatter" then
            local d = st.dirs[i]
            if p < 0.55 then
                local q = p / 0.55
                dx, dy = d[1] * q, d[2] * q
                s, a = 1 - 0.55 * q, 1 - q
            else
                local q = (p - 0.55) / 0.45
                dx, dy = d[1] * (1 - q), d[2] * (1 - q)
                s, a = 0.45 + 0.55 * q, q
            end
        end

        local x = st.xs[i] + dx
        local psz = math.max(2, st.pipSize * s)
        pip:SetSize(psz, psz)
        pip:ClearAllPoints()
        pip:SetPoint("CENTER", frame, "CENTER", x, dy)
        pip:SetAlpha(a)
        if i <= st.cur and (hueFx or flicker) then
            local r, g, b = onR, onG, onB
            if hueFx then
                r, g, b = HsvToRgb(hueFx + i * 25, 0.85, 1)
            elseif flicker then
                r = onR + (1 - onR) * flicker
                g = onG + (1 - onG) * flicker
                b = onB + (1 - onB) * flicker
            end
            pip:SetVertexColor(r, g, b, a)
        end

        local bSize = st.backSize * s
        if style == "afterimage" then
            bSize = st.backSize * (1 + 0.55 * math.sin(math.pi * 2 * p))
        end
        back:SetSize(math.max(2, bSize), math.max(2, bSize))
        back:ClearAllPoints()
        back:SetPoint("CENTER", frame, "CENTER", x, dy)
        back:SetAlpha(0.9 * a)
    end

    local fs = frame._cpText
    if fs then
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", frame, "CENTER", gx, gy)
        fs:SetAlpha(ga)
        if gs ~= 1 and st.fsFace then
            fs:SetFont(st.fsFace, math.max(8, st.fsSize * gs), st.fsOutline)
        end
    end
end

-- Fires the full-resource celebration on the counter's own pips/text. The
-- ticker loops until StopComboPointsFx cancels it (value drops or hides).
local function FireComboPointsEffect(frame, cfg, cur, mx)
    local style = cfg.fullEffect or "ignite"
    local dur = CP_FX_DUR[style]
    if not dur then return end
    local pips = frame._cpPips
    if not pips then return end

    local fw = frame:GetWidth() or 200
    local fh = frame:GetHeight() or 26
    local spacing = fw / mx
    local pipSize = math.min(fh - 8, spacing / 1.5)
    pipSize = math.max(5, math.min(48, pipSize))
    local xs = {}
    for i = 1, mx do xs[i] = (i - (mx + 1) / 2) * spacing end

    local fs = frame._cpText
    local fsFace, fsSize, fsOutline = nil, nil, nil
    if fs then fsFace, fsSize, fsOutline = fs:GetFont() end

    local on = cfg.color or { r = 1, g = 0.82, b = 0 }
    local st = {
        style = style, t0 = GetTime(), dur = dur, mx = mx, cur = cur,
        xs = xs, spacing = spacing, pipSize = pipSize, backSize = pipSize + 4,
        onR = on.r or 1, onG = on.g or 0.82, onB = on.b or 0,
        fsFace = fsFace, fsSize = fsSize, fsOutline = fsOutline,
        dirs = nil,
    }
    if style == "shatter" then
        st.dirs = {}
        for i = 1, mx do
            local a = math.random() * 6.28318
            local d = 20 + math.random() * 30
            st.dirs[i] = { math.cos(a) * d, math.sin(a) * d }
        end
    end

    if frame._cpFxTicker then
        frame._cpFxTicker:Cancel()
        frame._cpFxTicker = nil
    end
    frame._cpFx = st
    frame._cpFxTicker = C_Timer.NewTicker(0.033, function()
        CpFxUpdate(frame, cfg)
    end)
end

-- Cancels the looping full effect and restores the text element. Pip visuals
-- are re-laid-out canonically by the next RefreshComboPoints pass.
local function StopComboPointsFx(frame)
    if frame._cpFxTicker then
        frame._cpFxTicker:Cancel()
        frame._cpFxTicker = nil
    end
    local st = frame._cpFx
    frame._cpFx = nil
    if not st then return end
    local f = frame._cpText
    if f then
        f:ClearAllPoints()
        f:SetPoint("CENTER", frame, "CENTER", 0, 0)
        f:SetAlpha(1)
        if st.fsFace then f:SetFont(st.fsFace, st.fsSize, st.fsOutline) end
    end
end

local function RefreshCpFrame(frame)
    local pt = frame._cpPowerType
    local cfg = pt and ZSBT.ResourceCounterConfig(pt) or nil
    local fs = frame._cpText

    if not cfg or cfg.enabled ~= true then
        StopComboPointsFx(frame)
        frame:Hide()
        frame._cpWasFull = false
        return
    end

    -- The counter is keyed by power type, so the frame's key IS the power.
    local cpType = pt
    local curRaw = UnitPower("player", cpType)
    local mxRaw = UnitPowerMax("player", cpType)
    -- Retail 12.x secrets the current value of primary power types (mana,
    -- rage, ...). Those counters are unsupported — hide rather than display.
    if not ZSBT.IsSafeNumber(curRaw) or not ZSBT.IsSafeNumber(mxRaw) then
        StopComboPointsFx(frame)
        frame:Hide()
        frame._cpWasFull = false
        return
    end
    local cur = math.floor(curRaw)
    local mx = math.floor(mxRaw)
    if mx <= 0 then
        StopComboPointsFx(frame)
        frame:Hide()
        frame._cpWasFull = false
        return
    end

    -- While in edit mode (scroll-area unlock or counter unlock) the counter
    -- must stay visible & grabbable.
    local unlocked = CpEditUnlocked()
    if unlocked ~= frame._cpMouseOn then
        frame._cpMouseOn = unlocked
        frame:EnableMouse(unlocked == true)
        SetCpBorder(frame, unlocked == true)
        if frame._cpGrip then
            if unlocked then frame._cpGrip:Show() else frame._cpGrip:Hide() end
        end
    end
    -- Rune counters stay visible at 0: an all-cooldown board is exactly when
    -- the per-slot sweeps are useful.
    local isRuneMode = cpType == 5 and type(GetRuneCooldown) == "function" and frame._cpRuneBars ~= nil
    if not isRuneMode and not unlocked and cfg.hideAtZero ~= false and cur <= 0 then
        StopComboPointsFx(frame)
        frame:Hide()
        return
    end
    if not unlocked and cfg.hideOutOfCombat == true and not UnitAffectingCombat("player") then
        StopComboPointsFx(frame)
        frame:Hide()
        return
    end

    -- Rune mode snapshots cooldowns for rendering/hide-checks only; runes
    -- continuously recharge so there is no "full"/"depleted" alert edge.
    if isRuneMode then
        frame._cpRuneCd = frame._cpRuneCd or {}
        local ready = 0
        for i = 1, 6 do
            local s, d, r = GetRuneCooldown(i)
            frame._cpRuneCd[i] = { start = s, duration = d, ready = r and true or false }
            if r then ready = ready + 1 end
        end
        frame._cpRuneReady = ready
    end

    -- Full indicator: the chosen effect loops while at max and stops the
    -- instant CP drops below max. Sound still fires only on the rising edge;
    -- re-entering combat at full resumes the loop without replaying the sound.
    -- Secret values cannot be compared, so full detection is skipped entirely.
    local isFull = not isRuneMode and cur >= mx
    if isFull then
        if not frame._cpWasFull
            and cfg.fullSoundEnabled == true
            and type(cfg.fullSoundKey) == "string" and cfg.fullSoundKey ~= "" and cfg.fullSoundKey ~= "None"
            and ZSBT.PlayLSMSound then
            ZSBT.PlayLSMSound(cfg.fullSoundKey)
        end
        local fxKey = cfg.fullEffect or "ignite"
        local running = frame._cpFx ~= nil
        if CP_FX_DUR[fxKey] and (not running or frame._cpFx.style ~= fxKey) then
            FireComboPointsEffect(frame, cfg, cur, mx)
        elseif not CP_FX_DUR[fxKey] and running then
            StopComboPointsFx(frame)
        end
    else
        StopComboPointsFx(frame)
    end
    frame._cpWasFull = isFull
    -- Apply configured frame size (set by resize grip or sliders).
    local tw = tonumber(cfg.width)
    local th = tonumber(cfg.height)
    local nw = tw and math.max(80, math.min(800, tw)) or (frame:GetWidth() or 220)
    local nh = th and math.max(20, math.min(200, th)) or (frame:GetHeight() or 26)
    if frame._cpAppliedW ~= nw or frame._cpAppliedH ~= nh then
        frame._cpAppliedW, frame._cpAppliedH = nw, nh
        frame:SetSize(nw, nh)
    end

    -- DK runes: per-slot cooldown display instead of count pips/text.
    -- Ready runes render in the "on" color; cooling runes fill upward in the
    -- "empty" color (fill = recharge progress). Shapes come from cfg.runeShape.
    if isRuneMode then
        fs:Hide()
        for i = 1, CP_MAX_PIPS do
            frame._cpPips[i]:Hide()
            frame._cpPipBacks[i]:Hide()
        end
        -- Optional: hide the whole tracker while every rune is ready —
        -- runes are normally full, so the tracker only matters mid-fight.
        if cfg.hideAllReady == true and frame._cpRuneReady >= mx and not unlocked then
            frame:Hide()
            return
        end
        local onR, onG, onB = (cfg.color or {}).r or 1, (cfg.color or {}).g or 0.82, (cfg.color or {}).b or 0
        local offR, offG, offB = (cfg.emptyColor or {}).r or 0.35, (cfg.emptyColor or {}).g or 0.35, (cfg.emptyColor or {}).b or 0.35
        local ol = cfg.outlineColor or { r = 0, g = 0, b = 0 }
        local olR, olG, olB = ol.r or 0, ol.g or 0, ol.b or 0
        local shape = (type(cfg.runeShape) == "string" and RUNE_SHAPE_TEX[cfg.runeShape]) and cfg.runeShape or "square"
        local tex = RUNE_SHAPE_TEX[shape]
        if frame._cpRuneTex ~= tex then
            frame._cpRuneTex = tex
            for i = 1, 6 do
                frame._cpRuneBars[i]:SetStatusBarTexture(tex)
                local bk = frame._cpRuneBacks and frame._cpRuneBacks[i]
                if bk then bk:SetTexture(tex) end
            end
        end
        local showTime = cfg.showRuneTime == true
        local rface, rsize, routine = ResolveCpFont(cfg)
        local runeFontKey = rface .. "|" .. tostring(rsize) .. "|" .. tostring(routine)
        if showTime and frame._cpRuneFontKey ~= runeFontKey then
            frame._cpRuneFontKey = runeFontKey
            for j = 1, 6 do
                local t = frame._cpRuneTexts and frame._cpRuneTexts[j]
                if t then t:SetFont(rface, rsize, routine) end
            end
        end
        local fw = frame:GetWidth() or 200
        local fh = frame:GetHeight() or 26
        local slots = math.max(1, math.min(6, mx))
        local spacing = fw / slots
        local slotSize = math.max(5, math.min(48, math.min(fh - 8, spacing / 1.5)))
        local backSize = slotSize + 4
        local now = GetTime()
        for i = 1, 6 do
            local bar = frame._cpRuneBars[i]
            local back = frame._cpRuneBacks and frame._cpRuneBacks[i]
            local cd = frame._cpRuneCd and frame._cpRuneCd[i]
            local rtxt = frame._cpRuneTexts and frame._cpRuneTexts[i]
            if i <= slots then
                local x = (i - (slots + 1) / 2) * spacing
                local ready = cd and cd.ready == true
                local cooling = (not ready) and cd and cd.start and cd.duration and cd.duration > 0
                -- Outline back sits slightly larger behind the shape.
                if back then
                    back:SetVertexColor(olR, olG, olB, 0.9)
                    back:SetSize(backSize, backSize)
                    back:ClearAllPoints()
                    back:SetPoint("CENTER", frame, "CENTER", x, 0)
                    back:Show()
                end
                if ready then
                    bar:SetMinMaxValues(0, 1)
                    bar:SetValue(1)
                    bar:SetStatusBarColor(onR, onG, onB, 1)
                elseif cooling then
                    local elapsed = now - cd.start
                    if elapsed < 0 then elapsed = 0 elseif elapsed > cd.duration then elapsed = cd.duration end
                    bar:SetMinMaxValues(0, cd.duration)
                    bar:SetValue(elapsed)
                    bar:SetStatusBarColor(offR, offG, offB, 0.9)
                else
                    -- No cooldown data and not flagged ready: show empty.
                    bar:SetMinMaxValues(0, 1)
                    bar:SetValue(0)
                    bar:SetStatusBarColor(offR, offG, offB, 0.35)
                end
                bar:SetSize(slotSize, slotSize)
                bar:ClearAllPoints()
                bar:SetPoint("CENTER", frame, "CENTER", x, 0)
                bar:Show()
                -- Optional seconds-remaining readout inside cooling runes.
                if rtxt then
                    if showTime and cooling then
                        local remain = cd.duration - math.max(0, now - cd.start)
                        if remain < 0 then remain = 0 end
                        rtxt:SetText(string.format("%.0f", math.ceil(remain)))
                        rtxt:SetTextColor(onR, onG, onB, 1)
                        rtxt:Show()
                    else
                        rtxt:Hide()
                    end
                end
            else
                bar:Hide()
                if back then back:Hide() end
                if rtxt then rtxt:Hide() end
            end
        end
        PositionComboPoints(frame, cfg)
        frame:Show()
        return
    end

    -- Text / pips
    local fmt = cfg.format or "pips"
    local usePips = (fmt == "pips" and mx <= CP_MAX_PIPS)
    if usePips then
        fs:Hide()
        local onR, onG, onB = (cfg.color or {}).r or 1, (cfg.color or {}).g or 0.82, (cfg.color or {}).b or 0
        local offR, offG, offB = (cfg.emptyColor or {}).r or 0.35, (cfg.emptyColor or {}).g or 0.35, (cfg.emptyColor or {}).b or 0.35
        local ol = cfg.outlineColor or { r = 1, g = 1, b = 1 }
        local olR, olG, olB = ol.r or 1, ol.g or 1, ol.b or 1
        local backs = frame._cpPipBacks
        local pips = frame._cpPips
        -- Pips spread across the frame width; diamond size fits height & spacing.
        local fw = frame:GetWidth() or 200
        local fh = frame:GetHeight() or 26
        local spacing = fw / mx
        local pipSize = math.min(fh - 8, spacing / 1.5)
        pipSize = math.max(5, math.min(48, pipSize))
        local backSize = pipSize + 4
        for i = 1, CP_MAX_PIPS do
            local pip = pips[i]
            local back = backs[i]
            if i <= mx then
                local x = (i - (mx + 1) / 2) * spacing
                if i <= cur then
                    pip:SetVertexColor(onR, onG, onB, 1)
                else
                    pip:SetVertexColor(offR, offG, offB, 0.8)
                end
                back:SetVertexColor(olR, olG, olB, 0.9)
                back:SetSize(backSize, backSize)
                back:ClearAllPoints()
                back:SetPoint("CENTER", frame, "CENTER", x, 0)
                back:Show()
                pip:SetSize(pipSize, pipSize)
                pip:ClearAllPoints()
                pip:SetPoint("CENTER", frame, "CENTER", x, 0)
                pip:Show()
            else
                pip:Hide()
                back:Hide()
            end
        end
    else
        for i = 1, CP_MAX_PIPS do
            frame._cpPips[i]:Hide()
            frame._cpPipBacks[i]:Hide()
        end
        fs:Show()
        local text
        if fmt == "number" then
            text = tostring(cur)
        else
            text = tostring(cur) .. "/" .. tostring(mx)
        end
        fs:SetText(text)
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", frame, "CENTER", 0, 0)
        fs:SetAlpha(1)

        local col = cfg.color or { r = 1, g = 0.82, b = 0 }
        fs:SetTextColor(col.r or 1, col.g or 0.82, col.b or 0)
    end

    local face, size, outline = ResolveCpFont(cfg)
    local fontKey = face .. "|" .. tostring(size) .. "|" .. tostring(outline)
    if frame._cpFontKey ~= fontKey then
        frame._cpFontKey = fontKey
        fs:SetFont(face, size, outline)
    end

    PositionComboPoints(frame, cfg)
    frame:Show()
end

-- Creates (once) and returns the counter frame for a power type.
local function EnsureCpFrame(powerType)
    powerType = tonumber(powerType)
    if not powerType then return nil end
    Core._cpWidgets = Core._cpWidgets or {}
    local frame = Core._cpWidgets[powerType]
    if frame then return frame end

    frame = CreateFrame("Frame", "ZSBT_ResourceCounter_" .. powerType, UIParent)
    frame._cpPowerType = powerType
    frame:SetFrameStrata("HIGH")
    frame:SetSize(220, 26)
    frame:EnableMouse(false)
    frame:Hide()

    -- Pip outline backs: slightly larger rotated squares drawn behind each
    -- diamond for contrast. Drawn on BACKGROUND so pips (ARTWORK) sit on top.
    frame._cpPipBacks = {}
    frame._cpPips = {}
    for i = 1, CP_MAX_PIPS do
        local back = frame:CreateTexture(nil, "BACKGROUND")
        back:SetTexture("Interface\\Buttons\\WHITE8X8")
        back:SetRotation(math.pi / 4)
        back:SetVertexColor(1, 1, 1, 0.9)
        back:Hide()
        frame._cpPipBacks[i] = back

        local pip = frame:CreateTexture(nil, "ARTWORK")
        pip:SetTexture("Interface\\Buttons\\WHITE8X8")
        pip:SetRotation(math.pi / 4)
        pip:SetVertexColor(0.35, 0.35, 0.35, 0.8)
        pip:Hide()
        frame._cpPips[i] = pip
    end

    -- DK runes (power type 5) deplete from full rather than fill, so a count
    -- is misleading: each of the 6 slots is driven by GetRuneCooldown and
    -- shows ready (lit) vs cooling (sweep). Same model as Blizzard's
    -- RuneFrame / MSUF's RUNE_CD mode.
    if powerType == 5 then
        frame._cpRuneBars = {}
        frame._cpRuneBacks = {}
        frame._cpRuneTexts = {}
        for i = 1, 6 do
            -- Outline back: same shape, slightly larger, drawn on BACKGROUND
            -- so the status bar shape sits on top (mirrors the pip backs).
            local back = frame:CreateTexture(nil, "BACKGROUND")
            back:SetVertexColor(0, 0, 0, 0.9)
            back:Hide()
            frame._cpRuneBacks[i] = back

            local bar = CreateFrame("StatusBar", nil, frame)
            bar:SetStatusBarTexture(RUNE_SHAPE_TEX.square)
            bar:SetOrientation("VERTICAL") -- fill grows upward = recharging
            bar:SetMinMaxValues(0, 1)
            bar:Hide()
            frame._cpRuneBars[i] = bar

            local rtxt = bar:CreateFontString(nil, "OVERLAY")
            rtxt:SetPoint("CENTER", bar, "CENTER", 0, 0)
            rtxt:SetJustifyH("CENTER")
            rtxt:SetJustifyV("MIDDLE")
            rtxt:Hide()
            frame._cpRuneTexts[i] = rtxt
        end
        -- Cooldown sweeps need per-frame-ish updates: RUNE_POWER_UPDATE only
        -- fires on spend/energize, not while a rune is recharging.
        frame._cpRuneTick = 0
        frame:SetScript("OnUpdate", function(self, elapsed)
            self._cpRuneTick = (self._cpRuneTick or 0) + elapsed
            if self._cpRuneTick < 0.1 then return end
            self._cpRuneTick = 0
            if self:IsShown() and self._cpRuneBars then
                RefreshCpFrame(self)
            end
        end)
    end

    -- Resizable while unlocked (edit mode), like scroll area frames.
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(80, 20, 800, 200)
    end
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(frame:GetFrameLevel() + 5)
    grip:EnableMouse(true)
    local gripTex = grip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints(grip)
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip._cpGripTex = gripTex
    grip:Hide()
    frame._cpGrip = grip
    grip:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        if not CpEditUnlocked() then return end
        frame:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        frame:StopMovingOrSizing()
        if not CpEditUnlocked() then return end
        local w = math.floor((frame:GetWidth() or 0) + 0.5)
        local h = math.floor((frame:GetHeight() or 0) + 0.5)
        local cfg = ZSBT.ResourceCounterConfigWrite(powerType)
        if cfg then
            cfg.width = math.max(80, math.min(800, w))
            cfg.height = math.max(20, math.min(200, h))
            local ACR = LibStub("AceConfigRegistry-3.0", true)
            if ACR then ACR:NotifyChange("ZSBT") end
        end
        frame._cpAppliedW, frame._cpAppliedH = nil, nil
        RefreshComboPoints()
    end)

    -- Drag-to-move, only while scroll areas are unlocked (edit mode).
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if CpEditUnlocked() then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if not CpEditUnlocked() then return end
        local cx, cy = self:GetCenter()
        local ucx, ucy = UIParent:GetCenter()
        local cfg = ZSBT.ResourceCounterConfigWrite(powerType)
        if not cfg or not cx then return end
        -- Dropping anywhere detaches to a free position.
        cfg.attachArea = "None"
        cfg.xOffset = math.floor(cx - ucx + 0.5)
        cfg.yOffset = math.floor(cy - ucy + 0.5)
        local ACR = LibStub("AceConfigRegistry-3.0", true)
        if ACR then ACR:NotifyChange("ZSBT") end
        frame._cpPosKey = nil
        RefreshComboPoints()
    end)

    -- Watcher: unlock mode can toggle without a power update, so poll lightly
    -- to enable mouse (drag) and force the counter visible while editing.
    C_Timer.NewTicker(0.5, function()
        local unl = CpEditUnlocked()
        if unl ~= frame._cpMouseOn then
            frame._cpMouseOn = unl
            frame:EnableMouse(unl == true)
            SetCpBorder(frame, unl == true)
            if frame._cpGrip then
                if unl then frame._cpGrip:Show() else frame._cpGrip:Hide() end
            end
            if unl then RefreshComboPoints() end
        end
    end)

    local fs = frame:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("CENTER", frame, "CENTER", 0, 0)
    fs:SetJustifyH("CENTER")
    frame._cpText = fs

    Core._cpWidgets[powerType] = frame
    return frame
end

RefreshComboPoints = function()
    -- Force the legacy flat->resourceCounters migration, then refresh every
    -- configured counter and hide frames whose config was removed/disabled.
    ZSBT.ResourceCounterConfig(0)
    local p = ZSBT.db and ZSBT.db.profile
    local rc = p and p.resourceCounters
    local seen = {}
    if rc then
        for pt, cfg in pairs(rc) do
            pt = tonumber(pt)
            if pt and cfg and cfg.enabled == true then
                seen[pt] = true
                local frame = EnsureCpFrame(pt)
                if frame then RefreshCpFrame(frame) end
            end
        end
    end
    if Core._cpWidgets then
        for pt, frame in pairs(Core._cpWidgets) do
            if not seen[pt] then
                StopComboPointsFx(frame)
                frame:Hide()
                frame._cpWasFull = false
            end
        end
    end
end
ZSBT.RefreshComboPoints = function() RefreshComboPoints() end

function Core:InitComboPoints()
    if self._cpEventFrame then return end
    Core._cpWidgets = Core._cpWidgets or {}

    local evFrame = CreateFrame("Frame")
    evFrame:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
    evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    evFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
    evFrame:RegisterEvent("RUNE_POWER_UPDATE")
    evFrame:SetScript("OnEvent", function(_, event, unit)
        if event == "UNIT_POWER_UPDATE" and unit ~= "player" then return end
        if not Core:IsMasterEnabled() then
            if Core._cpWidgets then
                for _, f in pairs(Core._cpWidgets) do
                    if f:IsShown() then f:Hide() end
                end
            end
            return
        end
        RefreshComboPoints()
    end)
    self._cpEventFrame = evFrame

    C_Timer.After(0.5, function() RefreshComboPoints() end)
end

------------------------------------------------------------------------
-- Low Health / Low Mana Warning System
-- Monitors player health and mana, fires warnings when crossing thresholds.
------------------------------------------------------------------------
Core._healthWarnState = false  -- true = already warned, resets when above threshold
Core._healthBorderWarnState = false
Core._manaWarnState   = false

function Core:InitHealthWarnings()
    if self._healthWarnFrame then return end
    self._healthWarnFrame = CreateFrame("Frame")
    self._healthWarnFrame:RegisterEvent("UNIT_HEALTH")
    self._healthWarnFrame:SetScript("OnEvent", function(_, event, unit, ...)
        if unit ~= "player" then return end
        if not Core:IsMasterEnabled() then return end

        local profile = ZSBT.db and ZSBT.db.profile
        if not profile then return end

        if event == "UNIT_HEALTH" then
            Core:CheckLowHealth(profile)
        end
    end)
end

function Core:CheckLowHealth(profile)
    self._healthWarnState = false
    local borderShown = false
    if LowHealthFrame and LowHealthFrame.IsShown then
        local ok, shown = pcall(LowHealthFrame.IsShown, LowHealthFrame)
        if ok and shown == true then borderShown = true end
    end

    if borderShown then
        if not self._healthBorderWarnState then
            self._healthBorderWarnState = true
            local soundKey = profile.media and profile.media.sounds and profile.media.sounds.lowHealth
            if soundKey and soundKey ~= "None" and ZSBT.PlayLSMSound then
                ZSBT.PlayLSMSound(soundKey)
            end
        end
    else
        self._healthBorderWarnState = false
    end
end
