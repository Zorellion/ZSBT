------------------------------------------------------------------------
-- ZSBT - Core Orchestrator (Skeleton)
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.Core = ZSBT.Core or {}
local Core  = ZSBT.Core
local Addon = ZSBT.Addon

Core._initialized = Core._initialized or false
Core._enabled     = Core._enabled or false
Core._inGroupInstance = Core._inGroupInstance or false

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

local function getAuraRuleForSpell(spellID)
	local sc = ZSBT and ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
	local rules = sc and sc.auraRules
	if type(spellID) ~= "number" or type(rules) ~= "table" then return nil end
	local rule = rules[spellID]
	if type(rule) ~= "table" then return nil end
	if rule.enabled == false then return { disabled = true } end
	return rule
end

function Core:ShouldEmitBuffNotif(spellID, isGain, isHarmfulOverride)
	local isHarmful = (isHarmfulOverride == true)
	if isHarmfulOverride == nil and type(spellID) == "number" then
		if type(AuraUtil) == "table" and type(AuraUtil.FindAuraBySpellId) == "function" then
			local ok, aura = pcall(AuraUtil.FindAuraBySpellId, spellID, "player", "HARMFUL")
			isHarmful = ok and aura ~= nil
		end
	end
	local rule = getAuraRuleForSpell(spellID)
	local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("core"))
		or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
	if not rule then
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
	if type(spellID) ~= "number" then
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
	local state = self._auraRuleLastShown[spellID]
	if type(state) ~= "table" then
		state = { gain = 0, fade = 0 }
		self._auraRuleLastShown[spellID] = state
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

function Core:IsStrictOutgoingCombatLogOnlyEnabled()
	if not (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general) then return false end
	local g = ZSBT.db.profile.general
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
        text = "ZSBT detected Blizzard Floating Combat Text is currently disabled.\n\nRestore your previous Blizzard combat text settings?",
        button1 = "Restore",
        button2 = "Not Now",
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
				text = "|T" .. icon .. ":15:15:0:0:64:64:4:60:4:60|t " .. text
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
				"Route output to Zore's Scrolling Battle Text.",
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
					desc = "Route output through ZSBT.",
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
-- Skill ups and learned recipes/spells (MSBT-style) routed via Notifications.
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
			local tpl = getTemplate("tradeskillLearned", "Learned: %e")
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
		[15487] = true, -- Silence
		[147362] = true, -- Counter Shot
		[351338] = true, -- Quell
		-- Blood Elf racial
		[28730] = true, -- Arcane Torrent
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
		[1766] = "Kick",
		[57994] = "Wind Shear",
		[183752] = "Disrupt",
		[47528] = "Mind Freeze",
		[187707] = "Muzzle",
		[31935] = "Avenger's Shield",
		[6552] = "Pummel",
		[96231] = "Rebuke",
		[116705] = "Spear Hand Strike",
		[106839] = "Skull Bash",
		[2139] = "Counterspell",
		[19647] = "Spell Lock",
		[15487] = "Silence",
		[147362] = "Counter Shot",
		[351338] = "Quell",
		[28730] = "Arcane Torrent",
		-- Cast-stops (stuns/CC)
		[107570] = "Storm Bolt",
		[46968] = "Shockwave",
		[132168] = "Shockwave",
		[5246] = "Intimidating Shout",
		[179057] = "Chaos Nova",
		[205630] = "Illidan's Grasp",
		[221562] = "Asphyxiate",
		[108194] = "Asphyxiate",
		[91800] = "Gnaw",
		[47481] = "Gnaw",
		[30283] = "Shadowfury",
		[6789] = "Mortal Coil",
		[6358] = "Seduction",
		[5782] = "Fear",
		[261589] = "Seduction",
		[192058] = "Capacitor Totem",
		[51514] = "Hex",
		[118905] = "Static Charge",
		[19577] = "Intimidation",
		[186387] = "Bursting Shot",
		[213691] = "Scatter Shot",
		[187650] = "Freezing Trap",
		[853] = "Hammer of Justice",
		[20066] = "Repentance",
		[408] = "Kidney Shot",
		[1833] = "Cheap Shot",
		[6770] = "Sap",
		[2094] = "Blind",
		[1776] = "Gouge",
		[119381] = "Leg Sweep",
		[5211] = "Mighty Bash",
		[115078] = "Paralysis",
		[33786] = "Cyclone",
		[339] = "Entangling Roots",
		[118] = "Polymorph",
		[82691] = "Ring of Frost",
		[157981] = "Blizzard",
		[8122] = "Psychic Scream",
		[9484] = "Shackle Undead",
		[605] = "Mind Control",
		[374348] = "Land Slide",
		[370565] = "Terrorize",
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
			if unit == "player" and type(spellId) == "number" then
				local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("notifications"))
					or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
				Core._lastStopperSpellId = spellId

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
							if UnitGUID and UnitGUID(unit) then
								targetUnit = unit
								targetGUID = UnitGUID(unit)
								targetName = UnitName and UnitName(unit)
								break
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
							if UnitGUID and UnitGUID(unit) then
								targetUnit = unit
								targetGUID = UnitGUID(unit)
								targetName = UnitName and UnitName(unit)
								break
							end
						end
					end

					Core._lastCastStopTargetGUID = targetGUID
					Core._lastCastStopTargetName = targetName
					Core._lastCastStopTargetUnit = targetUnit

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
							local tpl = getTemplate("caststops", "Stopped: %e (%t)")
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
			local tpl = getTemplate(templateKey or emitCategory, "%t Interrupted!")
			local out = applyTemplate(tpl, { e = "", p = playerName, s = stopperLabel, t = targetName })
			if out and out ~= "" then
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
				local a, b = msg:match("You interrupt (.+)'s (.+)%.?")
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
		local tpl = getTemplate("interrupts", "Interrupted: %e")
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
					SafePrint("|cFF00CC66[UT]|r suppress UNIT_HEALTH (killCreditOnly=true)")
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
					SafePrint("|cFF00CC66[UT]|r killcheck deadEdge=true"
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
			local t = m:match("You have slain (.+)")
			if t then
				t = t:gsub("[!.]+$", "")
				return t
			end
			t = m:match("You have killed (.+)")
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

function Core:EmitNotification(text, color, category)
	if category and not self:IsNotificationCategoryEnabled(category) then
		return
	end
	if category == "interrupts" or category == "caststops" then
		local area = "Notifications"
		if type(category) == "string" and category ~= "" and self.GetNotificationScrollArea then
			area = self:GetNotificationScrollArea(category)
		end
		if ZSBT.DisplayText then
			ZSBT.DisplayText(area, text, color, { kind = "notification", category = category })
		elseif self.Display and self.Display.Emit then
			self.Display:Emit(area, text, color, { kind = "notification", category = category })
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
	if ZSBT.DisplayText then
		ZSBT.DisplayText(area, text, finalColor, meta)
	elseif self.Display and self.Display.Emit then
		self.Display:Emit(area, text, finalColor, meta)
	end
end

function Core:EmitBuffNotification(spellID, text, color, category)
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
		if ZSBT.DisplayText then
			ZSBT.DisplayText(area, text, color, { kind = "notification" })
		elseif self.Display and self.Display.Emit then
			self.Display:Emit(area, text, color, { kind = "notification" })
		end
		return
	end
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

	local meta = { kind = "notification" }
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
				ZSBT.PlayLSMSound(soundKey)
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

function Core:InitBuffTracking()
    if self._buffFrame then return end
    self._buffFrame = CreateFrame("Frame")
    self._buffFrame:RegisterUnitEvent("UNIT_AURA", "player")
	pcall(function() self._buffFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player") end)
    self._buffFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    self._buffFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    self._buffFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    self._buffFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
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
								ZSBTAddon:Print("[AURA] Deferred scan complete, tracked auras: " .. tostring(count) .. " sampleIDs: " .. table.concat(ids, ", "))
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
                Core:ScanPlayerAuras(nil)
            end
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
                    if not (info and (info.isFullUpdate or info.addedAuras or info.removedAuraInstanceIDs)) then
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
            Addon:Print("AuraTest: ZSBT is disabled.")
        end
        return
    end
    self._auraInstanceMap = {}
    self:EmitNotification("AuraTest: scanning...", {r = 1.0, g = 1.0, b = 0.2})
    self:ScanPlayerAuras(nil)

    local count = 0
    for _ in pairs(self._auraInstanceMap or {}) do
        count = count + 1
    end
    self:EmitNotification("AuraTest: found " .. tostring(count), {r = 1.0, g = 1.0, b = 0.2})
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
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        return C_UnitAuras.GetAuraDataByIndex("player", index, filter)
    end
    if type(filter) == "string" and filter:find("HELPFUL", 1, true) then
        if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
            return C_UnitAuras.GetBuffDataByIndex("player", index)
        end
    elseif type(filter) == "string" and filter:find("HARMFUL", 1, true) then
        if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
            return C_UnitAuras.GetDebuffDataByIndex("player", index)
        end
    end
    return nil
end

function Core:ScanPlayerAuras(updateInfo, silent)
    if not self._auraInstanceMap then self._auraInstanceMap = {} end
    if not self._trackedAuraNames then self._trackedAuraNames = {} end
    
    -- Check loading/transition suppression (zone changes only)
    if not silent and self._suppressAurasUntil then
        local now = GetTime and GetTime() or 0
        if now < self._suppressAurasUntil then
            silent = true
        else
            self._suppressAurasUntil = nil
        end
    end

	local function ResolveSpellIdByName(name)
		if type(name) ~= "string" then return nil end
		if ZSBT.IsSafeString and not ZSBT.IsSafeString(name) then return nil end
		local okEmpty, isEmpty = pcall(function() return name == "" end)
		if not okEmpty or isEmpty == true then return nil end
		if C_Spell and C_Spell.GetSpellInfo then
			local ok, info = pcall(C_Spell.GetSpellInfo, name)
			local sid = ok and info and (info.spellID or info.spellId) or nil
			if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
				return sid
			end
		end
		if GetSpellInfo then
			local ok, _, _, _, _, _, _, spellId = pcall(GetSpellInfo, name)
			if ok and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(spellId) then
				return spellId
			end
		end
		return nil
	end

    -- Full scan: rebuild everything from scratch
    if not updateInfo or updateInfo.isFullUpdate then
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
                    local okToShow = self:ShouldEmitBuffNotif(sid, true, isHelpful ~= true)
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

        -- Detect fades by instance ID
        for oldInstanceId, oldName in pairs(oldInstances) do
            if not newInstances[oldInstanceId] then
                if not silent then
                    local sid = self._auraInstanceSpellIDs and self._auraInstanceSpellIDs[oldInstanceId]
                    local isHarmful = self._auraInstanceIsHarmful and self._auraInstanceIsHarmful[oldInstanceId] == true
                    if isHarmful and (not sid) then
                        sid = self._auraInstanceHarmfulSpellIDs and self._auraInstanceHarmfulSpellIDs[oldInstanceId]
                    end
                    local okToShow = self:ShouldEmitBuffNotif(sid, false, isHarmful)
                    if okToShow then
                        if sid and type(sid) == "number" then
                            self:EmitBuffNotification(sid, BuildAuraNotifText("-", oldName or "Aura"), {r = 0.6, g = 0.6, b = 0.6}, "auras")
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
            end
        end

        self._auraInstanceMap = newInstances
        return
    end

    -- Incremental: handle added auras
    if updateInfo.addedAuras then
		local trg = ZSBT.Core and ZSBT.Core.Triggers
		if trg and trg.SyncWatchedAurasFromCore then
			pcall(function() trg:SyncWatchedAurasFromCore() end)
		end
        local needsRescan = false
        for _, aura in ipairs(updateInfo.addedAuras) do
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
                if not self._auraInstanceMap[instanceId] then
                    self._auraInstanceMap[instanceId] = name or "Aura"
                    local color = {r = 0.5, g = 0.8, b = 1.0}  -- buff blue
                    if isHarmful == true then
                        color = {r = 1.0, g = 0.4, b = 0.4}  -- debuff red
                    end
                    if isHarmful ~= true and type(sid) == "number" then
                        self:RecordRecentBuff(sid)
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
                        local okToShow = self:ShouldEmitBuffNotif(sid, true, isHarmful)
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
	if updateInfo.updatedAuraInstanceIDs then
		local needsRescan = false
		for _, instanceId in ipairs(updateInfo.updatedAuraInstanceIDs) do
			if instanceId then
				local auraData = nil
				if C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
					-- In some builds, this can throw when payloads are secret.
					pcall(function()
						auraData = C_UnitAuras.GetAuraDataByAuraInstanceID("player", instanceId)
					end)
				end

				if auraData then
					local name, isHarmful = extractAuraInfo(auraData)
					local sid = ResolveSafeAuraSpellID(auraData)
					if type(sid) == "number" and isHarmful ~= true then
						self:RecordRecentBuff(sid)
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
	if updateInfo.removedAuraInstanceIDs then
		local trg = ZSBT.Core and ZSBT.Core.Triggers
		if trg and trg.SyncWatchedAurasFromCore then
			pcall(function() trg:SyncWatchedAurasFromCore() end)
		end
        local needsRescan = false
        local dl = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("core"))
			or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
		for _, instanceId in ipairs(updateInfo.removedAuraInstanceIDs) do
			local name = self._auraInstanceMap[instanceId]
			local sid = self._auraInstanceSpellIDs and self._auraInstanceSpellIDs[instanceId]
			local isHarmful = self._auraInstanceIsHarmful and self._auraInstanceIsHarmful[instanceId] == true
			if isHarmful and (not sid) then
				sid = self._auraInstanceHarmfulSpellIDs and self._auraInstanceHarmfulSpellIDs[instanceId]
			end
            -- Fallback: if not in cache, try to resolve from game API
            if not name and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
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
					local okToShow = self:ShouldEmitBuffNotif(sid, false, isHarmful)
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
							self:EmitBuffNotification(sid, BuildAuraNotifText("-", name), {r = 0.6, g = 0.6, b = 0.6}, "auras")
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
    if updateInfo and not updateInfo.isFullUpdate
       and not updateInfo.addedAuras and not updateInfo.removedAuraInstanceIDs then
        self:ScanPlayerAuras(nil)
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

	local GOLD = (type(GOLD_AMOUNT) == "string") and GOLD_AMOUNT:gsub("%%d *", "") or nil
	local SILVER = (type(SILVER_AMOUNT) == "string") and SILVER_AMOUNT:gsub("%%d *", "") or nil
	local COPPER = (type(COPPER_AMOUNT) == "string") and COPPER_AMOUNT:gsub("%%d *", "") or nil
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

	add("Reputation with %s increased by %d.", 1)
	add("Reputation with %s decreased by %d.", -1)
	add("Your reputation with %s has increased by %d.", 1)
	add("Your reputation with %s has decreased by %d.", -1)

	table.insert(_repChangePatterns, { pat = "Reputation with (.+) increased by ([%d,]+)", sign = 1 })
	table.insert(_repChangePatterns, { pat = "Reputation with (.+) decreased by ([%d,]+)", sign = -1 })
	table.insert(_repChangePatterns, { pat = "Your reputation with (.+) has increased by ([%d,]+)", sign = 1 })
	table.insert(_repChangePatterns, { pat = "Your reputation with (.+) has decreased by ([%d,]+)", sign = -1 })
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
					local who, amt = text:match("(.+) has gained (%d[%d,]+) experience")
					if not who or not amt then
						who, amt = text:match("(.+) gains (%d[%d,]+) experience")
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
						if not okS or type(sText) ~= "string" then sText = "<secret>" end
						Addon:Dbg("diagnostics", 4, "[XPDBG] ev=CHATFRAME safe=" .. tostring(isSafeText)
							.. " who=" .. tostring(whoLabel)
							.. " xp=" .. tostring(xp)
							.. " msg=" .. sText)
					elseif dl >= 4 and ZSBT.Addon and ZSBT.Addon.Print then
						local okS, sText = pcall(tostring, text)
						if not okS or type(sText) ~= "string" then sText = "<secret>" end
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
				xp = msg:match("You gain (%d[%d,]+) experience")
				if not xp then
					local who, amt = msg:match("(.+) gains (%d[%d,]+) experience")
					if not who or not amt then
						who, amt = msg:match("(.+) has gained (%d[%d,]+) experience")
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
				if not okS or type(sMsg) ~= "string" then sMsg = "<secret>" end
				Addon:Dbg("diagnostics", 4, "[XPDBG] ev=" .. tostring(event)
					.. " safe=" .. tostring(isSafe)
					.. " who=" .. tostring(whoXP)
					.. " xp=" .. tostring(xp)
					.. " msg=" .. sMsg)
			elseif dl >= 4 and ZSBT.Addon and ZSBT.Addon.Print then
				local okS, sMsg = pcall(tostring, msg)
				if not okS or type(sMsg) ~= "string" then sMsg = "<secret>" end
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
            local honor = msg:match("(%d[%d,]+) honor")
            if honor then
                honor = honor:gsub(",", "")
                Core._lastHonorNotifAt = t
				Core:EmitNotification("+" .. honor .. " Honor", {r = 1.0, g = 0.5, b = 0.0}, "honor")
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

        -- Only track primary resource
        local pType = UnitPowerType("player")
        local current = UnitPower("player", pType)
        local max = UnitPowerMax("player", pType)

        if not ZSBT.IsSafeNumber(current) or not ZSBT.IsSafeNumber(max) then return end
        if max <= 0 then return end

        local pct = (current / max) * 100
        local prevPct = Core._lastPowerPct[pType] or 0
        Core._lastPowerPct[pType] = pct

        -- Notify at full resource
        if pct >= 100 and prevPct < 100 then
            local powerName = "Resource"
            if pType == 0 then powerName = "Mana"
            elseif pType == 1 then powerName = "Rage"
            elseif pType == 2 then powerName = "Focus"
            elseif pType == 3 then powerName = "Energy"
            elseif pType == 4 then powerName = "Combo Points"
            elseif pType == 6 then powerName = "Runic Power"
            elseif pType == 8 then powerName = "Astral Power"
            elseif pType == 9 then powerName = "Holy Power"
            elseif pType == 11 then powerName = "Maelstrom"
            elseif pType == 12 then powerName = "Chi"
            elseif pType == 13 then powerName = "Insanity"
            elseif pType == 17 then powerName = "Fury"
            elseif pType == 18 then powerName = "Pain"
            end
            Core:EmitNotification(powerName .. " Full!", {r = 1.0, g = 0.6, b = 0.0}, "power")
        end
    end)
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
