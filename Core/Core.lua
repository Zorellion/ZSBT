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

function Core:ShouldEmitBuffNotif(spellID, isGain)
	if type(spellID) ~= "number" then return true end
	local rule = getAuraRuleForSpell(spellID)
	if not rule then
		local sc = ZSBT and ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
		local g = sc and sc.auraGlobal
		if isGain and g and g.showUnconfiguredGains == false then return false end
		if (not isGain) and g and g.showUnconfiguredFades == false then return false end
		return true
	end
	if rule.disabled then return false end

	if isGain and rule.suppressGain then return false end
	if (not isGain) and rule.suppressFade then return false end

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
	local members = 0
	if type(GetNumGroupMembers) == "function" then
		local okM, m = pcall(GetNumGroupMembers)
		if okM and type(m) == "number" then members = m end
	end
	local isGroup = isPartyOrRaidInstance and members > 1
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
        return
    end

    -- Fallback: enable the most important CVars to recover from a "stuck off" state.
    trySetCVar("enableFloatingCombatText", "1")
    trySetCVar("floatingCombatTextCombatDamage", "1")
    trySetCVar("floatingCombatTextCombatHealing", "1")
    trySetCVar("floatingCombatTextCombatDamage_v2", "1")
    trySetCVar("floatingCombatTextCombatHealing_v2", "1")
    trySetCVar("floatingCombatTextReactives_v2", "1")

    restoreCombatTextFrames()
    restoreCombatTextAddFns()
end

function Core:EnsureBlizzardFCTEnabled()
    -- Do NOT restore from backup here. This path is called frequently (zoning, regen enabled)
    -- and should never overwrite user preferences beyond ensuring combat text is not stuck OFF.
    trySetCVar("enableFloatingCombatText", "1")
    trySetCVar("floatingCombatTextCombatDamage", "1")
    trySetCVar("floatingCombatTextCombatHealing", "1")
    trySetCVar("floatingCombatTextCombatDamage_v2", "1")
    trySetCVar("floatingCombatTextCombatHealing_v2", "1")
    trySetCVar("floatingCombatTextReactives_v2", "1")
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

    -- CRITICAL: Always ensure CombatDamage/CombatHealing are ON.
    -- A previous build wrongly set these to 0, which kills UNIT_COMBAT events.
    trySetCVar("CombatDamage", "1")
    trySetCVar("CombatHealing", "1")

    -- Suppress Blizzard's own floating combat text
    if g.suppressBlizzardFCT then
        self:SuppressBlizzardFCT()
    else
        -- If we are NOT suppressing, ensure the key CVars are on.
        -- Do not restore full backups here, since this runs repeatedly.
        self:EnsureBlizzardFCTEnabled()
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

    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Core:Init()")
    end

    if self.IncomingProbe and self.IncomingProbe.Init then
        self.IncomingProbe:Init()
    end
end

function Core:Enable()
    if self._enabled then return end
    self:Init()
    self._enabled = true

    if Addon and Addon.DebugPrint then
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
    self:InitPowerTracking()
    self:InitProgressTracking()
end

function Core:Disable()
    if not self._enabled then return end
    self._enabled = false

    if Addon and Addon.DebugPrint then
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
            Core:EmitNotification("+Combat", {r = 1, g = 0.2, b = 0.2}, "combatState")
        elseif event == "PLAYER_REGEN_ENABLED" then
            Core:EmitNotification("-Combat", {r = 0.2, g = 1, b = 0.2}, "combatState")
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
		local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
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

		local dl = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0
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

function Core:EmitNotification(text, color, category)
	if category and not self:IsNotificationCategoryEnabled(category) then
		return
	end
	local area = "Notifications"
	if type(category) == "string" and category ~= "" and self.GetNotificationScrollArea then
		area = self:GetNotificationScrollArea(category)
	end
    if ZSBT.DisplayText then
		ZSBT.DisplayText(area, text, color, { kind = "notification" })
    elseif self.Display and self.Display.Emit then
		self.Display:Emit(area, text, color, { kind = "notification" })
    end
end

function Core:EmitBuffNotification(spellID, text, color, category)
	if category and not self:IsNotificationCategoryEnabled(category) then
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

	if ZSBT.DisplayText then
		ZSBT.DisplayText(area, text, color, { kind = "notification" })
	elseif self.Display and self.Display.Emit then
		self.Display:Emit(area, text, color, { kind = "notification" })
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
        if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
            Core._auraInstanceMap = {}
            Core._trackedAuraNames = {}
			Core._auraInstanceSpellIDs = {}
			Core._auraRuleLastShown = {}
            C_Timer.After(0.5, function()
                if Core.IsMasterEnabled and Core:IsMasterEnabled() then
                    Core:ScanPlayerAuras(nil)
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

            local sid = isHelpful and ResolveSafeAuraSpellID(auraData) or nil
            local name = extractAuraInfo(auraData)
			if isHelpful and not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid)) then
				sid = ResolveSpellIdByName(name)
			end
            if not newInstances[instanceId] then
                newInstances[instanceId] = name or defaultName
                if isHelpful and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
                    self._auraInstanceSpellIDs[instanceId] = sid
                    self:RecordRecentBuff(sid)
                end
                if not oldInstances[instanceId] then
                    if not silent then
                        local okToShow = true
                        if isHelpful and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
                            okToShow = self:ShouldEmitBuffNotif(sid, true)
                        end
                        if isHelpful and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
                            local trg = ZSBT.Core and ZSBT.Core.Triggers
                            if trg and trg.OnAuraGain then trg:OnAuraGain(sid) end
                        end
                        if okToShow then
                            if isHelpful and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
                                self:EmitBuffNotification(sid, BuildAuraNotifText("+", newInstances[instanceId]), gainColor, "auras")
                            else
                                self:EmitNotification(BuildAuraNotifText("+", newInstances[instanceId]), gainColor, "auras")
                            end
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
                    local okToShow = true
                    if type(sid) == "number" then
                        okToShow = self:ShouldEmitBuffNotif(sid, false)
                    end
                    if okToShow then
                        if type(sid) == "number" then
                            self:EmitBuffNotification(sid, BuildAuraNotifText("-", oldName or "Aura"), {r = 0.6, g = 0.6, b = 0.6}, "auras")
                        else
                            self:EmitNotification(BuildAuraNotifText("-", oldName or "Aura"), {r = 0.6, g = 0.6, b = 0.6}, "auras")
                        end
                    end
                end
                if type(sid) == "number" then
                    local trg = ZSBT.Core and ZSBT.Core.Triggers
                    if trg and trg.OnAuraFade then trg:OnAuraFade(sid) end
                end
                if self._auraInstanceSpellIDs then
                    self._auraInstanceSpellIDs[oldInstanceId] = nil
                end
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
            local sid = nil
            if isHarmful ~= true then
                sid = ResolveSafeAuraSpellID(aura)
				if not (ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid)) then
					sid = ResolveSpellIdByName(name)
				end
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
                    if isHarmful ~= true and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
                        self:RecordRecentBuff(sid)
                    end
                    if not silent then
                        local okToShow = true
                        if isHarmful ~= true and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
                            okToShow = self:ShouldEmitBuffNotif(sid, true)
                        end
                        if okToShow then
							if isHarmful then
								self:EmitNotification(BuildAuraNotifText("+", self._auraInstanceMap[instanceId]), color, "auras")
							else
								if sid and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
									self:EmitBuffNotification(sid, BuildAuraNotifText("+", self._auraInstanceMap[instanceId]), color, "auras")
								else
									self:EmitNotification(BuildAuraNotifText("+", self._auraInstanceMap[instanceId]), color, "auras")
								end
							end
                        end
                    end
                    if isHarmful ~= true and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
                        local trg = ZSBT.Core and ZSBT.Core.Triggers
                        if trg and trg.OnAuraGain then trg:OnAuraGain(sid) end
						if self._auraInstanceSpellIDs and instanceId then
							self._auraInstanceSpellIDs[instanceId] = sid
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
                    auraData = C_UnitAuras.GetAuraDataByAuraInstanceID("player", instanceId)
                end

                if auraData then
                    local name, isHarmful = extractAuraInfo(auraData)
                    -- Only consider helpful buffs for the buff rules manager.
                    if isHarmful ~= true then
                        local sid = ResolveSafeAuraSpellID(auraData)
                        if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid) then
                            self:RecordRecentBuff(sid)
                            if self._auraInstanceSpellIDs then
                                self._auraInstanceSpellIDs[instanceId] = sid
                            end
                        end

                        -- Keep cache name updated if we have one.
                        if instanceId and name then
                            self._auraInstanceMap[instanceId] = name
                        end
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
        for _, instanceId in ipairs(updateInfo.removedAuraInstanceIDs) do
            local name = self._auraInstanceMap[instanceId]
            if name then
                local sid = self._auraInstanceSpellIDs and self._auraInstanceSpellIDs[instanceId]
                self._auraInstanceMap[instanceId] = nil
                if not silent then
                    local okToShow = true
                    if type(sid) == "number" then
                        okToShow = self:ShouldEmitBuffNotif(sid, false)
                    end
                    if okToShow then
                        if sid and ZSBT.IsSafeNumber(sid) then
                            self:EmitBuffNotification(sid, BuildAuraNotifText("-", name), {r = 0.6, g = 0.6, b = 0.6}, "auras")
                        else
                            self:EmitNotification(BuildAuraNotifText("-", name), {r = 0.6, g = 0.6, b = 0.6}, "auras")
                        end
                    end
                end
                if type(sid) == "number" then
                    local trg = ZSBT.Core and ZSBT.Core.Triggers
                    if trg and trg.OnAuraFade then trg:OnAuraFade(sid) end
                end
                if self._auraInstanceSpellIDs then
                    self._auraInstanceSpellIDs[instanceId] = nil
                end
            else
                -- If our cache missed a prior add, rescan to resync.
                needsRescan = true
            end
        end

        if needsRescan then
            self:ScanPlayerAuras(nil)
            return
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
			local text = recolorMoneyString(moneyString or msg)
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
Core._lastHonorNotifAt = 0
Core._lastRepNotifAt = 0
local PROGRESS_DEDUP_WINDOW = 1.0  -- 1 second dedup window

Core._utKillLastAt = 0
Core._utKillChain = 0

function Core:InitProgressTracking()
    if self._progressFrame then return end
    self._progressFrame = CreateFrame("Frame")
    self._progressFrame:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
    self._progressFrame:RegisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN")
    self._progressFrame:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
    self._progressFrame:SetScript("OnEvent", function(_, event, msg)
        if not Core:IsMasterEnabled() then return end
        if not msg or type(msg) ~= "string" then return end
        if not ZSBT.IsSafeString(msg) then return end
        local t = GetTime()

        if event == "CHAT_MSG_COMBAT_XP_GAIN" then
            if (t - Core._lastXPNotifAt) < PROGRESS_DEDUP_WINDOW then return end
            local xp = msg:match("(%d[%d,]+) experience")
            if xp then
                xp = xp:gsub(",", "")
                Core._lastXPNotifAt = t
                Core:EmitNotification("+" .. xp .. " XP", {r = 0.6, g = 0.4, b = 1.0}, "progress")
            end
        elseif event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
            if (t - Core._lastHonorNotifAt) < PROGRESS_DEDUP_WINDOW then return end
            local honor = msg:match("(%d[%d,]+) honor")
            if honor then
                honor = honor:gsub(",", "")
                Core._lastHonorNotifAt = t
                Core:EmitNotification("+" .. honor .. " Honor", {r = 1.0, g = 0.5, b = 0.0}, "progress")
            end
        elseif event == "CHAT_MSG_COMBAT_FACTION_CHANGE" then
            if (t - Core._lastRepNotifAt) < PROGRESS_DEDUP_WINDOW then return end
            local faction, amount = msg:match("Reputation with (.+) increased by (%d+)")
            if faction and amount then
                Core._lastRepNotifAt = t
                Core:EmitNotification("+" .. amount .. " " .. faction, {r = 0.0, g = 0.8, b = 0.6}, "progress")
            else
                local factionLoss, amountLoss = msg:match("Reputation with (.+) decreased by (%d+)")
                if factionLoss and amountLoss then
                    Core._lastRepNotifAt = t
                    Core:EmitNotification("-" .. amountLoss .. " " .. factionLoss, {r = 0.8, g = 0.2, b = 0.2}, "progress")
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
