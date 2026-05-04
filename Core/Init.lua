------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - Initialization
-- Creates the addon object, registers chat commands, initializes DB.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

------------------------------------------------------------------------
-- Create the Ace3 addon object
------------------------------------------------------------------------
ZSBT.Addon = LibStub("AceAddon-3.0"):NewAddon("ZSBT", "AceConsole-3.0")

local Addon = ZSBT.Addon

------------------------------------------------------------------------
-- Combat lockdown defer state
------------------------------------------------------------------------
local pendingParserEnable = false
local pendingParserDisable = false

------------------------------------------------------------------------
-- Enable/Disable parsers (with combat lockdown protection)
------------------------------------------------------------------------
local function EnableParsers()
    if InCombatLockdown() then
        pendingParserEnable = true
        pendingParserDisable = false
        return false -- Deferred
    end

    if ZSBT.Parser then
        -- Enable data processors (sets _enabled flag, no event registration)
        if ZSBT.Parser.Incoming and ZSBT.Parser.Incoming.Enable then
            ZSBT.Parser.Incoming:Enable()
        end
        if ZSBT.Parser.Outgoing and ZSBT.Parser.Outgoing.Enable then
            ZSBT.Parser.Outgoing:Enable()
        end
        if ZSBT.Parser.Cooldowns and ZSBT.Parser.Cooldowns.Enable then
            ZSBT.Parser.Cooldowns:Enable()
        end
 
        -- Enable master event coordinator (wires EventCollector -> PulseEngine)
        -- NOTE: Does NOT use COMBAT_LOG_EVENT_UNFILTERED; uses whitelisted
        -- events only (UNIT_COMBAT, UNIT_HEALTH, COMBAT_TEXT_UPDATE, etc.)
        -- This MUST be last so data processors are ready before events fire
        if ZSBT.Parser.CombatLog and ZSBT.Parser.CombatLog.Enable then
            ZSBT.Parser.CombatLog:Enable()
        end
    end
 
    pendingParserEnable = false
    return true -- Success
end
 
local function DisableParsers()
    if InCombatLockdown() then
        pendingParserDisable = true
        pendingParserEnable = false
        return false -- Deferred
    end
 
    if ZSBT.Parser then
        -- Disable master listener FIRST (stops event flow)
        if ZSBT.Parser.CombatLog and ZSBT.Parser.CombatLog.Disable then
            ZSBT.Parser.CombatLog:Disable()
        end
 
        -- Then disable data processors (clears _enabled flag)
        if ZSBT.Parser.Incoming and ZSBT.Parser.Incoming.Disable then
            ZSBT.Parser.Incoming:Disable()
        end
        if ZSBT.Parser.Outgoing and ZSBT.Parser.Outgoing.Disable then
            ZSBT.Parser.Outgoing:Disable()
        end
        if ZSBT.Parser.Cooldowns and ZSBT.Parser.Cooldowns.Disable then
            ZSBT.Parser.Cooldowns:Disable()
        end
    end
 
    pendingParserDisable = false
    return true -- Success
end

------------------------------------------------------------------------
-- Combat lockdown watcher frame
------------------------------------------------------------------------
local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_ENABLED" then
        -- Combat ended, retry any pending operations
        if pendingParserEnable then
            EnableParsers()
        elseif pendingParserDisable then
            DisableParsers()
        end
    end
end)

------------------------------------------------------------------------
-- UT Announcer preset triggers (shipped)
-- Stored per-character in db.char.triggers.items.
-- If the user deletes them, we keep a tombstone list so they won't be
-- re-seeded by migrations or initialization.
------------------------------------------------------------------------
local function GetUTAnnouncerPresetTriggers()
	return {
		{
			id = "ut_kill_1",
			enabled = true,
			eventType = "UT_KILL_1",
			throttleSec = 0,
			action = {
				text = "First Blood!",
				scrollArea = "Notifications",
				sound = "ZSBT: First Blood",
				color = { r = 1.0, g = 0.0, b = 0.11764705882353 },
				sticky = true,
				stickyScale = 2,
				stickyDurationMult = 1.5,
				fontOverride = true,
				fontFace = "ZSBT: PermanentMarker",
				fontOutline = "Thin",
			},
		},
		{
			id = "ut_kill_2",
			enabled = true,
			eventType = "UT_KILL_2",
			throttleSec = 0,
			action = {
				text = "Double Kill!",
				scrollArea = "Notifications",
				sound = "ZSBT: Double Kill",
				color = { r = 1.0, g = 0.0, b = 0.11764705882353 },
				sticky = true,
				stickyScale = 2,
				stickyDurationMult = 1.5,
				fontOverride = true,
				fontFace = "ZSBT: PermanentMarker",
				fontOutline = "Thin",
			},
		},
		{
			id = "ut_kill_3",
			enabled = true,
			eventType = "UT_KILL_3",
			throttleSec = 0,
			action = {
				text = "Killing Spree!",
				scrollArea = "Notifications",
				sound = "ZSBT: Killing Spree",
				color = { r = 1.0, g = 0.0, b = 0.11764705882353 },
				sticky = true,
				stickyScale = 2,
				stickyDurationMult = 1.5,
				fontOverride = true,
				fontFace = "ZSBT: PermanentMarker",
				fontOutline = "Thin",
			},
		},
		{
			id = "ut_kill_4",
			enabled = true,
			eventType = "UT_KILL_4",
			throttleSec = 0,
			action = {
				text = "Mega Kill!",
				scrollArea = "Notifications",
				sound = "ZSBT: Mega Kill",
				color = { r = 1.0, g = 0.0, b = 0.11764705882353 },
				sticky = true,
				stickyScale = 2,
				stickyDurationMult = 1.5,
				fontOverride = true,
				fontFace = "ZSBT: PermanentMarker",
				fontOutline = "Thin",
			},
		},
		{
			id = "ut_kill_5",
			enabled = true,
			eventType = "UT_KILL_5",
			throttleSec = 0,
			action = {
				text = "Rampage!",
				scrollArea = "Notifications",
				sound = "ZSBT: Rampage",
				color = { r = 1.0, g = 0.0, b = 0.11764705882353 },
				sticky = true,
				stickyScale = 2,
				stickyDurationMult = 1.5,
				fontOverride = true,
				fontFace = "ZSBT: PermanentMarker",
				fontOutline = "Thin",
			},
		},
		{
			id = "ut_kill_6",
			enabled = true,
			eventType = "UT_KILL_6",
			throttleSec = 0,
			action = {
				text = "Unstoppable!",
				scrollArea = "Notifications",
				sound = "ZSBT: Unstoppable",
				color = { r = 1.0, g = 0.0, b = 0.11764705882353 },
				sticky = true,
				stickyScale = 2,
				stickyDurationMult = 1.5,
				fontOverride = true,
				fontFace = "ZSBT: PermanentMarker",
				fontOutline = "Thin",
			},
		},
		{
			id = "ut_kill_7",
			enabled = true,
			eventType = "UT_KILL_7",
			throttleSec = 0,
			action = {
				text = "God Like!",
				scrollArea = "Notifications",
				sound = "ZSBT: Godlike",
				color = { r = 1.0, g = 0.81176470588235, b = 0.0 },
				sticky = true,
				stickyScale = 2,
				stickyDurationMult = 1.5,
				fontOverride = true,
				fontFace = "ZSBT: PermanentMarker",
				fontOutline = "Thin",
			},
		},
	}
end

function ZSBT.RestoreUTAnnouncerPresets()
	if not (ZSBT and ZSBT.db and ZSBT.db.char) then return end
	ZSBT.db.char.triggers = ZSBT.db.char.triggers or { enabled = true, items = {} }
	ZSBT.db.char.triggers.items = ZSBT.db.char.triggers.items or {}
	ZSBT.db.char.triggers.utDeletedPresets = {}

	local items = ZSBT.db.char.triggers.items
	local existing = {}
	for _, trig in ipairs(items) do
		if type(trig) == "table" and type(trig.eventType) == "string" and trig.eventType ~= "" then
			existing[trig.eventType] = true
		end
	end

	local presets = GetUTAnnouncerPresetTriggers()
	for _, trig in ipairs(presets) do
		if type(trig) == "table" and type(trig.eventType) == "string" and existing[trig.eventType] ~= true then
			items[#items + 1] = trig
			existing[trig.eventType] = true
		end
	end

	ZSBT.db.char.migrations = ZSBT.db.char.migrations or {}
	ZSBT.db.char.migrations.utPresets_v1 = true
end

------------------------------------------------------------------------
-- OnInitialize: Fires once when addon loads (before PLAYER_LOGIN)
------------------------------------------------------------------------
function Addon:OnInitialize()
    -- Initialize AceDB with our defaults and enable profiles
    self.db = LibStub("AceDB-3.0"):New("ZSBTDB", ZSBT.DEFAULTS, true)

    -- Store reference in shared namespace for cross-file access
    ZSBT.db = self.db

	-- Selective migration: apply shipped General defaults to existing profiles
	-- only when those keys are unset (nil). Do not overwrite user choices.
	local function migrateGeneralDefaultsOnce()
		if not self.db then return end
		self.db.global = self.db.global or {}
		self.db.global.migrations = self.db.global.migrations or {}
		if self.db.global.migrations.generalDefaults_v1 == true then return end

		local keys = {
			"instanceAwareOutgoing",
			"damageMeterOutgoingFallback",
			"damageMeterIncomingFallback",
			"autoAttackRestrictFallback",
			"quietOutgoingWhenIdle",
			"quietOutgoingAutoAttacks",
			"strictOutgoingCombatLogOnly",
			"pvpStrictEnabled",
			"pvpStrictDisableAutoAttackFallback",
		}
		local defaults = ZSBT.DEFAULTS and ZSBT.DEFAULTS.profile and ZSBT.DEFAULTS.profile.general or nil
		if type(defaults) ~= "table" then
			self.db.global.migrations.generalDefaults_v1 = true
			return
		end

		local profiles = self.db.profiles
		if type(profiles) == "table" then
			for _, prof in pairs(profiles) do
				if type(prof) == "table" then
					prof.general = prof.general or {}
					for _, k in ipairs(keys) do
						if prof.general[k] == nil and defaults[k] ~= nil then
							prof.general[k] = defaults[k]
						end
					end
				end
			end
		end

		self.db.global.migrations.generalDefaults_v1 = true
	end

	-- Follow-up selective migration: some keys were introduced after v1 shipped.
	-- Apply them only if missing, without changing existing user choices.
	local function migrateGeneralDefaults_v2()
		if not self.db then return end
		self.db.global = self.db.global or {}
		self.db.global.migrations = self.db.global.migrations or {}
		if self.db.global.migrations.generalDefaults_v2 == true then return end

		local keys = {
			"pvpStrictEnabled",
			"pvpStrictDisableAutoAttackFallback",
		}
		local defaults = ZSBT.DEFAULTS and ZSBT.DEFAULTS.profile and ZSBT.DEFAULTS.profile.general or nil
		if type(defaults) ~= "table" then
			self.db.global.migrations.generalDefaults_v2 = true
			return
		end

		local profiles = self.db.profiles
		if type(profiles) == "table" then
			for _, prof in pairs(profiles) do
				if type(prof) == "table" then
					prof.general = prof.general or {}
					for _, k in ipairs(keys) do
						if prof.general[k] == nil and defaults[k] ~= nil then
							prof.general[k] = defaults[k]
						end
					end
				end
			end
		end

		self.db.global.migrations.generalDefaults_v2 = true
	end

	migrateGeneralDefaultsOnce()
	migrateGeneralDefaults_v2()

	-- Diagnostics migration: seed new channel-based debug settings from legacy fields.
	local function migrateDiagnosticsDebugChannels_v1()
		if not self.db then return end
		self.db.global = self.db.global or {}
		self.db.global.migrations = self.db.global.migrations or {}
		if self.db.global.migrations.diagnosticsDebugChannels_v1 == true then return end

		local defaults = ZSBT.DEFAULTS and ZSBT.DEFAULTS.profile and ZSBT.DEFAULTS.profile.diagnostics or nil
		local profiles = self.db.profiles
		if type(profiles) == "table" then
			for _, prof in pairs(profiles) do
				if type(prof) == "table" then
					prof.diagnostics = prof.diagnostics or {}
					local d = prof.diagnostics

					-- Seed default level from legacy debugLevel if new field is missing.
					if d.debugDefaultLevel == nil then
						local legacy = tonumber(d.debugLevel) or 0
						d.debugDefaultLevel = legacy
					end

					-- Ensure channel table exists.
					if type(d.debugChannels) ~= "table" then
						d.debugChannels = {}
					end
					local ch = d.debugChannels

					-- Fill any missing channels from defaults.
					if type(defaults) == "table" and type(defaults.debugChannels) == "table" then
						for k, v in pairs(defaults.debugChannels) do
							if ch[k] == nil then
								ch[k] = v
							end
						end
					end

					-- Seed cooldowns channel override from legacy cooldownsDebugLevel if unset.
					if ch.cooldowns == nil then
						ch.cooldowns = 0
					end
					if (tonumber(ch.cooldowns) or 0) == 0 then
						local legacyCd = tonumber(d.cooldownsDebugLevel) or 0
						if legacyCd > 0 then
							ch.cooldowns = legacyCd
						end
					end
				end
			end
		end

		self.db.global.migrations.diagnosticsDebugChannels_v1 = true
	end

	-- Migration: split legacy Notifications "progress" category into
	-- playerXP / honor / reputation (and remove legacy keys afterwards).
	local function migrateNotificationsProgressSplit_v1()
		if not self.db then return end
		self.db.global = self.db.global or {}
		self.db.global.migrations = self.db.global.migrations or {}
		if self.db.global.migrations.notificationsProgressSplit_v1 == true then return end

		local function copyIfMissing(tbl, srcKey, dstKey)
			if type(tbl) ~= "table" then return end
			if tbl[dstKey] ~= nil then return end
			if tbl[srcKey] == nil then return end
			tbl[dstKey] = tbl[srcKey]
		end

		local function moveCategory(prof)
			if type(prof) ~= "table" then return end
			if type(prof.notifications) == "table" and prof.notifications.progress ~= nil then
				copyIfMissing(prof.notifications, "progress", "playerXP")
				copyIfMissing(prof.notifications, "progress", "honor")
				copyIfMissing(prof.notifications, "progress", "reputation")
			end
			if type(prof.notificationsRouting) == "table" and prof.notificationsRouting.progress ~= nil then
				copyIfMissing(prof.notificationsRouting, "progress", "playerXP")
				copyIfMissing(prof.notificationsRouting, "progress", "honor")
				copyIfMissing(prof.notificationsRouting, "progress", "reputation")
			end
			if type(prof.notificationsTemplates) == "table" and prof.notificationsTemplates.progress ~= nil then
				copyIfMissing(prof.notificationsTemplates, "progress", "playerXP")
				copyIfMissing(prof.notificationsTemplates, "progress", "honor")
				copyIfMissing(prof.notificationsTemplates, "progress", "reputation")
			end
			if type(prof.notificationsPerType) == "table" and type(prof.notificationsPerType.progress) == "table" then
				copyIfMissing(prof.notificationsPerType, "progress", "playerXP")
				copyIfMissing(prof.notificationsPerType, "progress", "honor")
				copyIfMissing(prof.notificationsPerType, "progress", "reputation")
			end

			-- Cleanup legacy keys (avoid leaving dead settings behind).
			if type(prof.notifications) == "table" then prof.notifications.progress = nil end
			if type(prof.notificationsRouting) == "table" then prof.notificationsRouting.progress = nil end
			if type(prof.notificationsTemplates) == "table" then prof.notificationsTemplates.progress = nil end
			if type(prof.notificationsPerType) == "table" then prof.notificationsPerType.progress = nil end
		end

		-- Apply to all profiles.
		local profiles = self.db.profiles
		if type(profiles) == "table" then
			for _, prof in pairs(profiles) do
				moveCategory(prof)
			end
		end

		-- Also apply to currently active profile (safety).
		moveCategory(self.db.profile)

		self.db.global.migrations.notificationsProgressSplit_v1 = true
	end

	migrateDiagnosticsDebugChannels_v1()
	migrateNotificationsProgressSplit_v1()

	ZSBT.Presets = ZSBT.Presets or {}
	local Presets = ZSBT.Presets

	local function listProfiles(db)
		if not db or type(db.ListProfiles) ~= "function" then return nil end
		local ok, t = pcall(db.ListProfiles, db)
		if ok and type(t) == "table" then return t end
		return nil
	end

	local function profileExists(db, name)
		if type(name) ~= "string" or name == "" then return false end
		local profiles = listProfiles(db)
		if type(profiles) ~= "table" then return false end
		return profiles[name] ~= nil
	end

	local function ensureScrollArea(profile, name, data)
		if type(profile) ~= "table" then return end
		profile.scrollAreas = profile.scrollAreas or {}
		profile.scrollAreas[name] = profile.scrollAreas[name] or {}
		local area = profile.scrollAreas[name]
		for k, v in pairs(data or {}) do
			area[k] = v
		end
	end

	local function applyCritDefaults(profile)
		if type(profile) ~= "table" then return end
		ensureScrollArea(profile, "Crits", {
			xOffset = 420,
			yOffset = 120,
			width = 120,
			height = 220,
			alignment = "Center",
			direction = "Up",
			animation = "Straight",
			animSpeed = 1.0,
		})

		profile.outgoing = profile.outgoing or {}
		profile.outgoing.crits = profile.outgoing.crits or {}
		profile.outgoing.crits.enabled = true
		profile.outgoing.crits.scrollArea = "Crits"
		profile.outgoing.crits.sticky = true
		if profile.outgoing.crits.instanceSoundMode == nil then
			profile.outgoing.crits.instanceSoundMode = "Only when amount is known"
		end

		profile.general = profile.general or {}
		profile.general.critFont = profile.general.critFont or {}
		profile.general.critFont.face = "ZSBT: PORKY"
		profile.general.critFont.useScale = true
		profile.general.critFont.scale = 1.5
		profile.general.critFont.anim = "Pow"
	end

	local SHIPPED = {
		Melee = {
			profileName = "ZSBT - Preset: Melee",
			scrollAreas = {
				Incoming = { xOffset = -220, yOffset = -40, width = 120, height = 280 },
				Outgoing = { xOffset = 220, yOffset = -40, width = 120, height = 280 },
				Notifications = { xOffset = 0, yOffset = 220, width = 320, height = 120 },
			},
		},
		Ranged = {
			profileName = "ZSBT - Preset: Ranged",
			scrollAreas = {
				Incoming = { xOffset = -240, yOffset = 10, width = 120, height = 280 },
				Outgoing = { xOffset = 240, yOffset = 10, width = 120, height = 280 },
				Notifications = { xOffset = 0, yOffset = 240, width = 320, height = 120 },
			},
		},
		Tank = {
			profileName = "ZSBT - Preset: Tank",
			scrollAreas = {
				Incoming = { xOffset = -200, yOffset = -20, width = 140, height = 320 },
				Outgoing = { xOffset = 260, yOffset = -40, width = 110, height = 260 },
				Notifications = { xOffset = 0, yOffset = 240, width = 340, height = 120 },
			},
		},
		Healer = {
			profileName = "ZSBT - Preset: Healer",
			scrollAreas = {
				Incoming = { xOffset = -260, yOffset = -30, width = 110, height = 260 },
				Outgoing = { xOffset = 220, yOffset = -10, width = 140, height = 320 },
				Notifications = { xOffset = 0, yOffset = 240, width = 340, height = 120 },
			},
		},
		PetClass = {
			profileName = "ZSBT - Preset: Pet Class",
			scrollAreas = {
				PetIncoming = { xOffset = -520, yOffset = 260, width = 140, height = 220 },
				PetOutgoing = { xOffset = -520, yOffset = 10, width = 140, height = 220 },
				Incoming = { xOffset = -240, yOffset = -40, width = 120, height = 280 },
				Outgoing = { xOffset = 240, yOffset = -40, width = 120, height = 280 },
				Notifications = { xOffset = 0, yOffset = 230, width = 320, height = 120 },
			},
			pets = {
				enabled = true,
				scrollArea = "Pet Outgoing",
				showHealing = true,
				healScrollArea = "Pet Incoming",
			},
		},
	}

	local function applyPresetToProfile(profile, presetId)
		local def = SHIPPED[presetId]
		if type(profile) ~= "table" or type(def) ~= "table" then return false end

		local sa = def.scrollAreas or {}
		if type(sa.Incoming) == "table" then
			ensureScrollArea(profile, "Incoming", sa.Incoming)
		end
		if type(sa.Outgoing) == "table" then
			ensureScrollArea(profile, "Outgoing", sa.Outgoing)
		end
		if type(sa.Notifications) == "table" then
			ensureScrollArea(profile, "Notifications", sa.Notifications)
		end
		if type(sa.PetIncoming) == "table" then
			ensureScrollArea(profile, "Pet Incoming", sa.PetIncoming)
		end
		if type(sa.PetOutgoing) == "table" then
			ensureScrollArea(profile, "Pet Outgoing", sa.PetOutgoing)
		end

		profile.incoming = profile.incoming or {}
		profile.incoming.damage = profile.incoming.damage or {}
		profile.incoming.healing = profile.incoming.healing or {}
		profile.incoming.damage.scrollArea = "Incoming"
		profile.incoming.healing.scrollArea = "Incoming"

		profile.outgoing = profile.outgoing or {}
		profile.outgoing.damage = profile.outgoing.damage or {}
		profile.outgoing.healing = profile.outgoing.healing or {}
		profile.outgoing.damage.scrollArea = "Outgoing"
		profile.outgoing.healing.scrollArea = "Outgoing"

		if type(def.pets) == "table" then
			profile.pets = profile.pets or {}
			for k, v in pairs(def.pets) do
				profile.pets[k] = v
			end
		end

		applyCritDefaults(profile)
		return true
	end

	local function resetPresetProfile(presetId)
		local def = SHIPPED[presetId]
		if not def or type(def.profileName) ~= "string" then return false end
		local db = ZSBT.db
		if not db or type(db.SetProfile) ~= "function" then return false end

		local active = nil
		if type(db.GetCurrentProfile) == "function" then
			local ok, cur = pcall(db.GetCurrentProfile, db)
			if ok and type(cur) == "string" then active = cur end
		end

		pcall(db.SetProfile, db, def.profileName)
		if type(db.CopyProfile) == "function" then
			pcall(db.CopyProfile, db, "Default", true)
		end
		applyPresetToProfile(db.profile, presetId)

		if active and active ~= def.profileName then
			pcall(db.SetProfile, db, active)
		end
		return true
	end

	function Presets.ResetPreset(presetId)
		return resetPresetProfile(presetId)
	end

	function Presets.SeedOnce()
		local db = ZSBT.db
		if not db or not db.profile then return end

		local active = nil
		if type(db.GetCurrentProfile) == "function" then
			local ok, cur = pcall(db.GetCurrentProfile, db)
			if ok and type(cur) == "string" then active = cur end
		end

		for presetId, def in pairs(SHIPPED) do
			if type(def) == "table" and type(def.profileName) == "string" then
				if not profileExists(db, def.profileName) then
					pcall(db.SetProfile, db, def.profileName)
					if type(db.CopyProfile) == "function" then
						pcall(db.CopyProfile, db, "Default", true)
					end
					applyPresetToProfile(db.profile, presetId)
				end
			end
		end

		if active and type(active) == "string" then
			pcall(db.SetProfile, db, active)
		end

	end

	Presets.SeedOnce()

    	-- Refresh any live "Unlock Scroll Areas" overlay frames when the active
	-- AceDB profile changes (otherwise the old profile's frames remain visible).
	local function HandleProfileSwap()
        if ZSBT and ZSBT.IsScrollAreasUnlocked and ZSBT.IsScrollAreasUnlocked() then
            if ZSBT.RefreshScrollAreaFrames then
                ZSBT.RefreshScrollAreaFrames()
            elseif ZSBT.UpdateScrollAreaFrames then
                ZSBT.UpdateScrollAreaFrames()
            end
        end

        local ACR = LibStub("AceConfigRegistry-3.0", true)
        if ACR and ACR.NotifyChange then
            ACR:NotifyChange("ZSBT")
        end
    end

    if self.db and self.db.RegisterCallback then
        self.db:RegisterCallback("OnProfileChanged", HandleProfileSwap)
        self.db:RegisterCallback("OnProfileCopied", HandleProfileSwap)
        self.db:RegisterCallback("OnProfileReset", HandleProfileSwap)
    end

	-- One-time migration: move per-character rule data out of profiles.
	-- Layout remains in profiles; rules/triggers live in db.char.
	local function migrateRulesToCharOnce()
		if not self.db then return end
		self.db.global = self.db.global or {}
		self.db.global.migrations = self.db.global.migrations or {}
		if self.db.global.migrations.rulesToChar_v1 == true then return end

		self.db.char = self.db.char or {}
		self.db.char.spamControl = self.db.char.spamControl or {}
		self.db.char.spamControl.spellRules = self.db.char.spamControl.spellRules or {}
		self.db.char.spamControl.auraRules = self.db.char.spamControl.auraRules or {}
		self.db.char.triggers = self.db.char.triggers or { enabled = true, items = {} }
		self.db.char.triggers.items = self.db.char.triggers.items or {}

		local prof = self.db.profile
		local psc = prof and prof.spamControl
		local function normalizeNumericKey(k)
			if type(k) == "number" then return k end
			if type(k) ~= "string" then return k end
			local nk = tonumber(k)
			if nk and tostring(nk) == k then
				return nk
			end
			return k
		end
		if psc and type(psc.spellRules) == "table" then
			for sid, rule in pairs(psc.spellRules) do
				sid = normalizeNumericKey(sid)
				if self.db.char.spamControl.spellRules[sid] == nil and type(rule) == "table" then
					local copy = {}
					for k, v in pairs(rule) do copy[k] = v end
					self.db.char.spamControl.spellRules[sid] = copy
				end
			end
			psc.spellRules = nil
		end
		if psc and type(psc.auraRules) == "table" then
			for sid, rule in pairs(psc.auraRules) do
				sid = normalizeNumericKey(sid)
				if self.db.char.spamControl.auraRules[sid] == nil and type(rule) == "table" then
					local copy = {}
					for k, v in pairs(rule) do copy[k] = v end
					self.db.char.spamControl.auraRules[sid] = copy
				end
			end
			psc.auraRules = nil
		end

		local ptr = prof and prof.triggers
		if ptr and type(ptr) == "table" then
			local ok = true
			if type(ptr.enabled) == "boolean" then
				self.db.char.triggers.enabled = ptr.enabled
			end
			if type(ptr.items) == "table" then
				ok = pcall(function()
					self.db.char.triggers.utDeletedPresets = self.db.char.triggers.utDeletedPresets or {}
					local utDeleted = self.db.char.triggers.utDeletedPresets
					local items = self.db.char.triggers.items
					items = type(items) == "table" and items or {}
					self.db.char.triggers.items = items

					local function trigKey(trig)
						if type(trig) ~= "table" then return nil end
						if type(trig.id) == "string" and trig.id ~= "" then
							return "id:" .. trig.id
						end
						local et = (type(trig.eventType) == "string") and trig.eventType or ""
						local sid = trig.spellId
						if type(sid) == "string" then
							sid = normalizeNumericKey(sid)
						end
						sid = (type(sid) == "number") and sid or 0
						return "et:" .. et .. ":sid:" .. tostring(sid)
					end

					local existing = {}
					for _, trig in ipairs(items) do
						local k = trigKey(trig)
						if k then existing[k] = true end
					end

					for _, trig in ipairs(ptr.items) do
						if type(trig) == "table" then
							if type(trig.eventType) == "string" and utDeleted[trig.eventType] == true then
								-- User deleted this shipped UT preset; keep deleted.
							else
								local copy = {}
								for k, v in pairs(trig) do
									if k == "spellId" then
										copy[k] = normalizeNumericKey(v)
									elseif type(v) == "table" then
										local sub = {}
										for k2, v2 in pairs(v) do sub[k2] = v2 end
										copy[k] = sub
									else
										copy[k] = v
									end
								end
								local k = trigKey(copy)
								if k == nil or existing[k] ~= true then
									items[#items + 1] = copy
									if k then existing[k] = true end
								end
							end
						end
					end
				end)
			end
			if ok then
				prof.triggers = nil
			end
		end

		self.db.global.migrations.rulesToChar_v1 = true
	end

	local function migrateWhirlwindAggregateToSpellRuleOnce()
		if not self.db then return end
		self.db.global = self.db.global or {}
		self.db.global.migrations = self.db.global.migrations or {}
		if self.db.global.migrations.wwAggToSpellRule_v1 == true then return end

		self.db.char = self.db.char or {}
		self.db.char.spamControl = self.db.char.spamControl or {}
		self.db.char.spamControl.spellRules = self.db.char.spamControl.spellRules or {}

		local prof = self.db.profile
		local psc = prof and prof.spamControl
		local ww = psc and psc.whirlwindAggregate
		if type(ww) == "table" then
			local rules = self.db.char.spamControl.spellRules
			for _, sid in ipairs({1680, 190411}) do
				rules[sid] = rules[sid] or { enabled = true }
				local r = rules[sid]
				r.aggregate = r.aggregate or {}
				if type(ww.enabled) == "boolean" then
					r.aggregate.enabled = ww.enabled
				end
				if ww.window ~= nil then
					r.aggregate.windowSec = tonumber(ww.window) or r.aggregate.windowSec
				end
				if type(ww.showCount) == "boolean" then
					r.aggregate.showCount = ww.showCount
				end
			end
		end

		self.db.global.migrations.wwAggToSpellRule_v1 = true
	end

	local function seedUTPresetsOnce()
		if not self.db then return end
		self.db.global = self.db.global or {}
		self.db.global.migrations = self.db.global.migrations or {}
		-- Note: triggers are per-character (db.char). Do NOT block this behind a
		-- global one-time migration flag, otherwise alts won't get the presets.

		self.db.char = self.db.char or {}
		self.db.char.migrations = self.db.char.migrations or {}
		self.db.char.triggers = self.db.char.triggers or { enabled = true, items = {} }
		self.db.char.triggers.items = self.db.char.triggers.items or {}
		self.db.char.triggers.utDeletedPresets = self.db.char.triggers.utDeletedPresets or {}
		local utDeleted = self.db.char.triggers.utDeletedPresets

		local items = self.db.char.triggers.items

		-- Always enforce tombstones / cleanup on load so deleted shipped UT presets
		-- stay deleted, even if the original seeding migration already ran.
		-- Also de-dupe UT presets by eventType (can happen via prior migrations/copies).
		local seenUT = {}
		for i = #items, 1, -1 do
			local trig = items[i]
			local et = (type(trig) == "table" and type(trig.eventType) == "string") and trig.eventType or nil
			if et and et:match("^UT_KILL_%d+") then
				if utDeleted[et] == true then
					table.remove(items, i)
				elseif seenUT[et] == true then
					table.remove(items, i)
				else
					seenUT[et] = true
				end
			end
		end

		-- If we've already seeded UT presets for this character, stop after cleanup.
		if self.db.char.migrations.utPresets_v1 == true then return end

		local existing = {}
		for _, trig in ipairs(items) do
			if type(trig) == "table" and type(trig.eventType) == "string" and trig.eventType ~= "" then
				existing[trig.eventType] = true
			end
		end

		local presets = GetUTAnnouncerPresetTriggers()

		for _, trig in ipairs(presets) do
			if type(trig) == "table" and type(trig.eventType) == "string" and existing[trig.eventType] ~= true and utDeleted[trig.eventType] ~= true then
				items[#items + 1] = trig
				existing[trig.eventType] = true
			end
		end

		self.db.char.migrations.utPresets_v1 = true
		self.db.global.migrations.utPresets_v1 = true
	end

	migrateRulesToCharOnce()
	migrateWhirlwindAggregateToSpellRuleOnce()
	seedUTPresetsOnce()

	-- One-time migration: move cooldown tracked list to db.char (per-character).
	local function migrateCooldownsTrackedToCharOnce()
		if not self.db then return end
		self.db.global = self.db.global or {}
		self.db.global.migrations = self.db.global.migrations or {}
		if self.db.global.migrations.cooldownsTrackedToChar_v1 == true then return end

		self.db.char = self.db.char or {}
		self.db.char.cooldowns = self.db.char.cooldowns or {}
		self.db.char.cooldowns.tracked = self.db.char.cooldowns.tracked or {}

		local prof = self.db.profile
		local pc = prof and prof.cooldowns
		local tracked = pc and pc.tracked
		if type(tracked) == "table" then
			for idKey, v in pairs(tracked) do
				local nk = idKey
				if type(nk) == "string" then
					local n2 = tonumber(nk)
					if n2 and tostring(n2) == nk then nk = n2 end
				end
				if self.db.char.cooldowns.tracked[nk] == nil then
					self.db.char.cooldowns.tracked[nk] = v
				end
			end
			-- Keep profile.cooldowns.tracked for backward compatibility with older code,
			-- but new code should read/write db.char.cooldowns.tracked.
		end

		self.db.global.migrations.cooldownsTrackedToChar_v1 = true
	end

	migrateCooldownsTrackedToCharOnce()

	-- One-time migration: update Notifications scroll area defaults for existing profiles.
	-- We only update profiles that still look like the old shipped default (Static + Up + stock geometry)
	-- to avoid overwriting users that customized the Notifications animation.
	local function migrateNotificationsScrollAreaAnim_v1()
		if not self.db then return end
		self.db.global = self.db.global or {}
		self.db.global.migrations = self.db.global.migrations or {}
		if self.db.global.migrations.notificationsScrollAnim_v1 == true then return end

		local function shouldMigrateArea(area)
			if type(area) ~= "table" then return false end
			local anim = area.animation
			local dir = area.direction
			if anim ~= "Static" then return false end
			if dir ~= "Up" then return false end
			if area.xOffset ~= 0 then return false end
			if area.yOffset ~= 200 then return false end
			if area.width ~= 300 then return false end
			if area.height ~= 100 then return false end
			if area.alignment ~= "Center" then return false end
			return true
		end

		local function applyToProfile(prof)
			if type(prof) ~= "table" then return end
			local sa = prof.scrollAreas
			if type(sa) ~= "table" then return end
			local n = sa["Notifications"]
			if shouldMigrateArea(n) then
				n.animation = "Straight"
				n.direction = "Up"
			end
		end

		applyToProfile(self.db.profile)
		local profiles = self.db.profiles
		if type(profiles) == "table" then
			for _, prof in pairs(profiles) do
				applyToProfile(prof)
			end
		end

		self.db.global.migrations.notificationsScrollAnim_v1 = true
	end

	migrateNotificationsScrollAreaAnim_v1()

	-- One-time migration: ensure all Notifications categories have template defaults
	-- and initialize per-category style/sound settings for Notifications.
	local function migrateNotificationsPerType_v1()
		if not self.db then return end
		self.db.global = self.db.global or {}
		self.db.global.migrations = self.db.global.migrations or {}
		if self.db.global.migrations.notificationsPerType_v1 == true then return end

		local defaults = ZSBT.DEFAULTS and ZSBT.DEFAULTS.profile or nil
		local defTpl = defaults and defaults.notificationsTemplates or {}
		local defPer = defaults and defaults.notificationsPerType or {}

		for _, prof in pairs(self.db.profiles or {}) do
			if type(prof) == "table" then
				prof.notificationsTemplates = prof.notificationsTemplates or {}
				for k, v in pairs(defTpl) do
					if prof.notificationsTemplates[k] == nil and v ~= nil then
						prof.notificationsTemplates[k] = v
					end
				end

				prof.notificationsPerType = prof.notificationsPerType or {}
				for k, v in pairs(defPer) do
					if type(prof.notificationsPerType[k]) ~= "table" and type(v) == "table" then
						prof.notificationsPerType[k] = v
					else
						local cur = prof.notificationsPerType[k]
						if type(cur) == "table" and type(v) == "table" then
							cur.style = type(cur.style) == "table" and cur.style or (type(v.style) == "table" and v.style or {})
							cur.sound = type(cur.sound) == "table" and cur.sound or (type(v.sound) == "table" and v.sound or {})
							if cur.style.fontOverride == nil and v.style and v.style.fontOverride ~= nil then
								cur.style.fontOverride = v.style.fontOverride
							end
							if cur.sound.enabled == nil and v.sound and v.sound.enabled ~= nil then
								cur.sound.enabled = v.sound.enabled
							end
							if cur.sound.soundKey == nil and v.sound and v.sound.soundKey ~= nil then
								cur.sound.soundKey = v.sound.soundKey
							end
						end
					end
				end
			end
		end

		self.db.global.migrations.notificationsPerType_v1 = true
	end

	migrateNotificationsPerType_v1()

	-- One-time migration: split legacy combatState category into enterCombat/leaveCombat.
	local function migrateCombatStateSplit_v1()
		if not self.db then return end
		self.db.global = self.db.global or {}
		self.db.global.migrations = self.db.global.migrations or {}
		if self.db.global.migrations.combatStateSplit_v1 == true then return end

		local function applyToProfile(prof)
			if type(prof) ~= "table" then return end
			local n = prof.notifications
			local r = prof.notificationsRouting
			local t = prof.notificationsTemplates
			local per = prof.notificationsPerType
			local function copyTable(src)
				if type(src) ~= "table" then return nil end
				local out = {}
				for k, v in pairs(src) do
					out[k] = v
				end
				return out
			end

			if type(n) == "table" and n.enterCombat == nil then n.enterCombat = n.combatState end
			if type(n) == "table" and n.leaveCombat == nil then n.leaveCombat = n.combatState end

			if type(r) == "table" and r.enterCombat == nil then r.enterCombat = r.combatState end
			if type(r) == "table" and r.leaveCombat == nil then r.leaveCombat = r.combatState end

			if type(t) == "table" and t.enterCombat == nil then t.enterCombat = t.combatState end
			if type(t) == "table" and t.leaveCombat == nil then t.leaveCombat = t.combatState end

			if type(per) == "table" and type(per.combatState) == "table" then
				local cs = per.combatState
				if type(per.enterCombat) ~= "table" then
					per.enterCombat = { style = copyTable(cs.style), sound = copyTable(cs.sound) }
				end
				if type(per.leaveCombat) ~= "table" then
					per.leaveCombat = { style = copyTable(cs.style), sound = copyTable(cs.sound) }
				end
			end
		end

		applyToProfile(self.db.profile)
		for _, prof in pairs(self.db.profiles or {}) do
			applyToProfile(prof)
		end

		self.db.global.migrations.combatStateSplit_v1 = true
	end

	migrateCombatStateSplit_v1()

	-- Default to per-character profiles so different characters don't share
	-- spell/buff rules unless explicitly configured via AceDB profiles.
	local function getCharKey()
		local name = UnitName and UnitName("player")
		local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName())
		if type(name) ~= "string" or name == "" then return nil end
		if type(realm) ~= "string" or realm == "" then realm = "UnknownRealm" end
		return name .. "-" .. realm
	end

	local function ensurePerCharacterProfile()
		if not self.db or not self.db.profile or not self.db.profile.general then return end
		if self.db.profile.general.perCharacterProfile ~= true then return end

		local charKey = getCharKey()
		if not charKey then return end

		-- If this character has never selected a profile, assign a dedicated one.
		local pk = self.db.keys and self.db.keys.profile
		if type(pk) == "table" and pk[charKey] == nil then
			pk[charKey] = charKey
			pcall(function() self.db:SetProfile(charKey) end)
		end
	end

	ensurePerCharacterProfile()

    if ZSBT.Core and ZSBT.Core.Minimap and ZSBT.Core.Minimap.Init then
        ZSBT.Core.Minimap:Init()
    end

	    -- Register LibSharedMedia-3.0 defaults (ensure base WoW font is listed)
	local LSM = LibStub("LibSharedMedia-3.0", true)
	if LSM and not ZSBT.PlayLSMSound then
		function ZSBT.PlayLSMSound(soundKey)
			if not soundKey or soundKey == "None" then return end
			local path = LSM:Fetch("sound", soundKey)
			if path then
				local p = ZSBT.db and ZSBT.db.profile
				local media = p and p.media
				local channel = media and media.soundChannel
				if type(channel) ~= "string" or channel == "" then
					channel = "Master"
				end
				local _, handle = PlaySoundFile(path, channel)
				return handle
			end
		end
	end
	if LSM then
		pcall(function()
			LSM:Register("font", "ZSBT: Audiowide", [[Interface\AddOns\ZSBT\Media\Fonts\Audiowide.ttf]])
			LSM:Register("font", "ZSBT: JotiOne", [[Interface\AddOns\ZSBT\Media\Fonts\JotiOne.ttf]])
			LSM:Register("font", "ZSBT: Nosifer", [[Interface\AddOns\ZSBT\Media\Fonts\Nosifer.ttf]])
			LSM:Register("font", "ZSBT: PORKY", [[Interface\AddOns\ZSBT\Media\Fonts\PORKY.TTF]])
			LSM:Register("font", "ZSBT: PORKY Heavy", [[Interface\AddOns\ZSBT\Media\Fonts\PORKY_Heavy.TTF]])
			LSM:Register("font", "ZSBT: PermanentMarker", [[Interface\AddOns\ZSBT\Media\Fonts\PermanentMarker-Regular.ttf]])
			LSM:Register("font", "ZSBT: Metamorphous", [[Interface\AddOns\ZSBT\Media\Fonts\Metamorphous-Regular.ttf]])
			LSM:Register("font", "ZSBT: Bungee", [[Interface\AddOns\ZSBT\Media\Fonts\Bungee-Regular.ttf]])
			LSM:Register("font", "ZSBT: Blood Hunter", [[Interface\AddOns\ZSBT\Media\Fonts\Blood Hunter TTF Demo.ttf]])
			LSM:Register("font", "ZSBT: Blood Regular", [[Interface\AddOns\ZSBT\Media\Fonts\Blood-Regular.ttf]])
			LSM:Register("font", "ZSBT: Blooddrip", [[Interface\AddOns\ZSBT\Media\Fonts\Blooddrip.ttf]])
			LSM:Register("font", "ZSBT: Bloody Terror", [[Interface\AddOns\ZSBT\Media\Fonts\Bloody Terror TTF Personal.ttf]])
			LSM:Register("font", "ZSBT: Brushed", [[Interface\AddOns\ZSBT\Media\Fonts\Brushed.ttf]])
			LSM:Register("font", "ZSBT: DarkWaters", [[Interface\AddOns\ZSBT\Media\Fonts\DarkWaters-Regular.ttf]])
			LSM:Register("font", "ZSBT: Dracutaz", [[Interface\AddOns\ZSBT\Media\Fonts\Dracutaz.ttf]])
			LSM:Register("font", "ZSBT: Edo", [[Interface\AddOns\ZSBT\Media\Fonts\edo.ttf]])
			LSM:Register("font", "ZSBT: Sketch", [[Interface\AddOns\ZSBT\Media\Fonts\Sketch.ttf]])
			LSM:Register("font", "ZSBT: AgentOrange", [[Interface\AddOns\ZSBT\Media\Fonts\AgentOrange.ttf]])
			LSM:Register("font", "ZSBT: Wedgie Regular", [[Interface\AddOns\ZSBT\Media\Fonts\Wedgie Regular.ttf]])
			LSM:Register("font", "ZSBT: ALBAS", [[Interface\AddOns\ZSBT\Media\Fonts\ALBAS___.TTF]])
			LSM:Register("font", "ZSBT: airstrike", [[Interface\AddOns\ZSBT\Media\Fonts\airstrike.ttf]])
			LSM:Register("font", "ZSBT: airstrike3d", [[Interface\AddOns\ZSBT\Media\Fonts\airstrike3d.ttf]])
			LSM:Register("font", "ZSBT: airstrikeacad", [[Interface\AddOns\ZSBT\Media\Fonts\airstrikeacad.ttf]])
			LSM:Register("font", "ZSBT: From Cartoon Blocks", [[Interface\AddOns\ZSBT\Media\Fonts\From Cartoon Blocks.ttf]])
			LSM:Register("font", "ZSBT: orange juice 2.0", [[Interface\AddOns\ZSBT\Media\Fonts\orange juice 2.0.ttf]])
			LSM:Register("font", "ZSBT: Sin City", [[Interface\AddOns\ZSBT\Media\Fonts\Sin City.ttf]])
			LSM:Register("font", "ZSBT: Zombies Brainless", [[Interface\AddOns\ZSBT\Media\Fonts\Zombies Brainless.ttf]])
			LSM:Register("font", "ZSBT: SuperAdorable", [[Interface\AddOns\ZSBT\Media\Fonts\SuperAdorable.ttf]])
			LSM:Register("font", "ZSBT: SuperShiny", [[Interface\AddOns\ZSBT\Media\Fonts\SuperShiny.ttf]])
			LSM:Register("font", "ZSBT: StoryScript Regular", [[Interface\AddOns\ZSBT\Media\Fonts\StoryScript-Regular.ttf]])
			LSM:Register("sound", "ZSBT: Enter Combat", [[Interface\AddOns\ZSBT\Media\Sounds\EnterCombat.ogg]])
			LSM:Register("sound", "ZSBT: Leave Combat", [[Interface\AddOns\ZSBT\Media\Sounds\LeaveCombat.ogg]])
			LSM:Register("sound", "ZSBT: Horn", [[Interface\AddOns\ZSBT\Media\Sounds\Horn.ogg]])
			LSM:Register("sound", "ZSBT: Growl", [[Interface\AddOns\ZSBT\Media\Sounds\Growl.ogg]])
			LSM:Register("sound", "ZSBT: Finish Him", [[Interface\AddOns\ZSBT\Media\Sounds\Finish Him.ogg]])
			LSM:Register("sound", "ZSBT: First Blood", [[Interface\AddOns\ZSBT\Media\Sounds\first-blood.ogg]])
			LSM:Register("sound", "ZSBT: Double Kill", [[Interface\AddOns\ZSBT\Media\Sounds\double-kill.ogg]])
			LSM:Register("sound", "ZSBT: Killing Spree", [[Interface\AddOns\ZSBT\Media\Sounds\killing-spree.ogg]])
			LSM:Register("sound", "ZSBT: Mega Kill", [[Interface\AddOns\ZSBT\Media\Sounds\mega-kill.ogg]])
			LSM:Register("sound", "ZSBT: Godlike", [[Interface\AddOns\ZSBT\Media\Sounds\godlike.ogg]])
			LSM:Register("sound", "ZSBT: Flawless Victory", [[Interface\AddOns\ZSBT\Media\Sounds\flawless-victory.ogg]])
			LSM:Register("sound", "ZSBT: Air Horn", [[Interface\AddOns\ZSBT\Media\Sounds\air-horn.ogg]])
			LSM:Register("sound", "ZSBT: Brass Shot", [[Interface\AddOns\ZSBT\Media\Sounds\brass-shot.ogg]])
			LSM:Register("sound", "ZSBT: Dragon Roar", [[Interface\AddOns\ZSBT\Media\Sounds\dragon-roar-364481.ogg]])
			LSM:Register("sound", "ZSBT: Fatality", [[Interface\AddOns\ZSBT\Media\Sounds\fatality.ogg]])
			LSM:Register("sound", "ZSBT: Losing Horn", [[Interface\AddOns\ZSBT\Media\Sounds\losing-horn.ogg]])
			LSM:Register("sound", "ZSBT: Rampage", [[Interface\AddOns\ZSBT\Media\Sounds\rampage.ogg]])
			LSM:Register("sound", "ZSBT: Ship Horn", [[Interface\AddOns\ZSBT\Media\Sounds\ship-horn.ogg]])
			LSM:Register("sound", "ZSBT: Unstoppable", [[Interface\AddOns\ZSBT\Media\Sounds\unstoppable.ogg]])
		end)
		local custom = self.db and self.db.profile and self.db.profile.media and self.db.profile.media.custom
		local fonts = custom and custom.fonts
		if type(fonts) == "table" then
			for name, path in pairs(fonts) do
				if type(name) == "string" and name ~= "" and type(path) == "string" and path ~= "" then
					pcall(function() LSM:Register("font", name, path) end)
				end
			end
		end
		local sounds = custom and custom.sounds
		if type(sounds) == "table" then
			for name, path in pairs(sounds) do
				if type(name) == "string" and name ~= "" and type(path) == "string" and path ~= "" then
					pcall(function() LSM:Register("sound", name, path) end)
				end
			end
		end
	end

	-- Keep quick control bar profile-specific on profile switches.
	if self.db and type(self.db.RegisterCallback) == "function" then
		local function refreshQuickBar()
			if ZSBT.UI and ZSBT.UI.QuickControlBar and ZSBT.UI.QuickControlBar.Init then
				ZSBT.UI.QuickControlBar:Init()
			end
		end
		pcall(self.db.RegisterCallback, self.db, "OnProfileChanged", refreshQuickBar)
		pcall(self.db.RegisterCallback, self.db, "OnProfileCopied", refreshQuickBar)
		pcall(self.db.RegisterCallback, self.db, "OnProfileReset", refreshQuickBar)
	end

    -- Register slash commands
    self:RegisterChatCommand("zsbt", "HandleSlashCommand")

	    -- Build and register Ace3 options table (assembled in Config.lua)
	    if ZSBT.BuildOptionsTable then
	        local options = ZSBT.BuildOptionsTable()

	        		-- Inject the AceDBOptions-3.0 profiles tab into the options tree
			local AceDBOptions = LibStub("AceDBOptions-3.0", true)
			if AceDBOptions then
				local mainDb = self.db
				local function deepCopyTable(src, seen)
					if type(src) ~= "table" then return src end
					-- IMPORTANT: Never deep-copy the AceDB database object.
					-- If we clone it, the Profiles UI would operate on a detached copy and
					-- newly created profiles would not persist to SavedVariables.
					if src == mainDb then return src end
					seen = seen or {}
					if seen[src] then return seen[src] end
					local dst = {}
					seen[src] = dst
					for k, v in pairs(src) do
						dst[deepCopyTable(k, seen)] = deepCopyTable(v, seen)
					end
					local mt = getmetatable(src)
					if mt ~= nil then
						setmetatable(dst, mt)
					end
					return dst
				end
				local function wrapHandler(handler)
					if type(handler) ~= "table" then return handler end
					local h = {}
					setmetatable(h, { __index = handler })
					h.DeleteProfile = function(selfH, info, value)
						if value == "Default" then
							return
						end
						if type(handler.DeleteProfile) == "function" then
							return handler.DeleteProfile(handler, info, value)
						end
					end
					return h
				end
				local function cloneProfilesTable(t)
					local copy = deepCopyTable(t)
					if copy and copy.handler then
						copy.handler = wrapHandler(copy.handler)
					end
					return copy
				end
				local function safeGetProfilesTable(db)
					local ok, t = pcall(AceDBOptions.GetOptionsTable, AceDBOptions, db, true)
					if not ok then return nil end
					return cloneProfilesTable(t)
				end
				local function safeListProfiles(handler, info)
					if not handler or type(handler.ListProfiles) ~= "function" then return nil end
					local ok, t = pcall(handler.ListProfiles, handler, info)
					if ok and type(t) == "table" then return t end
					return nil
				end
				local function safeSetChooseArg(tbl)
					local chooseOpt = tbl and tbl.args and tbl.args.choose
					if chooseOpt then
						chooseOpt.arg = "nocurrent"
					end
				end
				local function safeRestrictDeleteDefault(tbl)
					local deleteOpt = tbl and tbl.args and tbl.args.delete
					if deleteOpt then
						deleteOpt.values = function(info)
							local profiles = safeListProfiles(info and info.handler, info)
							if type(profiles) == "table" then
								profiles["Default"] = nil
							end
							return profiles
						end
						deleteOpt.disabled = function(info)
							local profiles = info and info.option and info.option.values and info.option.values(info)
							return (type(profiles) ~= "table") or (not next(profiles))
						end
					end
				end
				-- Request the profiles options table without AceDBOptions' built-in
				-- "common" suggestions (realm/class/char/Default). We only want to show
				-- real saved profiles the user has actually created.
				local profilesTable = safeGetProfilesTable(self.db)
				if profilesTable and profilesTable.handler and profilesTable.args then
					local addon = self
					local function getCharKey()
						local name = UnitName and UnitName("player")
						local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName())
						if type(name) ~= "string" or name == "" then return nil end
						if type(realm) ~= "string" or realm == "" then realm = "UnknownRealm" end
						return name .. "-" .. realm
					end
					addon._copyFromCharKey = addon._copyFromCharKey or ""
					addon._copyCharMode = addon._copyCharMode or "merge"
					local function getSvCharTable()
						local sv = mainDb and mainDb.sv
						local ch = sv and sv.char
						if type(ch) == "table" then return ch end
						return nil
					end
					local function listCharKeys()
						local out = {}
						local ch = getSvCharTable()
						local cur = getCharKey()
						if type(ch) ~= "table" then
							return out
						end
						for k in pairs(ch) do
							if type(k) == "string" and k ~= "" and k ~= cur then
								out[k] = k
							end
						end
						return out
					end
					local function mergeMissing(dst, src)
						if type(dst) ~= "table" or type(src) ~= "table" then return end
						for k, v in pairs(src) do
							if dst[k] == nil then
								dst[k] = deepCopyTable(v)
							end
						end
					end
					local function replaceTable(dst, src)
						if type(dst) ~= "table" or type(src) ~= "table" then return end
						for k in pairs(dst) do
							dst[k] = nil
						end
						for k, v in pairs(src) do
							dst[k] = deepCopyTable(v)
						end
					end
					local function copyFromSelectedChar(copySpellRules, copyAuraRules, copyTriggers)
						local fromKey = addon._copyFromCharKey
						if type(fromKey) ~= "string" or fromKey == "" then
							if addon and addon.Print then addon:Print("Select a source character first.") end
							return
						end
						local ch = getSvCharTable()
						local src = ch and ch[fromKey]
						local dst = mainDb and mainDb.char
						if type(src) ~= "table" or type(dst) ~= "table" then
							if addon and addon.Print then addon:Print("Source/target character data not available.") end
							return
						end
						local mode = addon._copyCharMode
						if mode ~= "merge" and mode ~= "replace" then mode = "merge" end
						local changed = false
						if copySpellRules then
							dst.spamControl = dst.spamControl or {}
							dst.spamControl.spellRules = dst.spamControl.spellRules or {}
							local srcRules = src.spamControl and src.spamControl.spellRules
							if type(srcRules) == "table" then
								if mode == "replace" then
									replaceTable(dst.spamControl.spellRules, srcRules)
								else
									mergeMissing(dst.spamControl.spellRules, srcRules)
								end
								changed = true
							end
						end
						if copyAuraRules then
							dst.spamControl = dst.spamControl or {}
							dst.spamControl.auraRules = dst.spamControl.auraRules or {}
							local srcRules = src.spamControl and src.spamControl.auraRules
							if type(srcRules) == "table" then
								if mode == "replace" then
									replaceTable(dst.spamControl.auraRules, srcRules)
								else
									mergeMissing(dst.spamControl.auraRules, srcRules)
								end
								changed = true
							end
						end
						if copyTriggers then
							dst.triggers = dst.triggers or { enabled = true, items = {} }
							dst.triggers.items = dst.triggers.items or {}
							local srcTrig = src.triggers
							local srcItems = srcTrig and srcTrig.items
							if type(srcItems) == "table" then
								if mode == "replace" then
									dst.triggers.enabled = (srcTrig and srcTrig.enabled ~= false) and true or false
									dst.triggers.items = deepCopyTable(srcItems)
								changed = true
								else
									local existing = {}
									for _, t in ipairs(dst.triggers.items) do
										if type(t) == "table" then
											local id = t.id or t._key
											if id ~= nil then existing[tostring(id)] = true end
										end
									end
									for _, t in ipairs(srcItems) do
										if type(t) == "table" then
											local id = t.id or t._key
											if id == nil or existing[tostring(id)] ~= true then
												dst.triggers.items[#dst.triggers.items + 1] = deepCopyTable(t)
												changed = true
											end
										end
									end
								end
							end
						end
						if changed then
							if copyTriggers and ZSBT and type(ZSBT.RefreshTriggersTab) == "function" then
								pcall(ZSBT.RefreshTriggersTab)
							end
							local ACR2 = LibStub("AceConfigRegistry-3.0", true)
							if ACR2 then
								pcall(function() ACR2:NotifyChange("ZSBT_SpellRules") end)
								pcall(function() ACR2:NotifyChange("ZSBT_BuffRules") end)
								pcall(function() ACR2:NotifyChange("ZSBT") end)
							end
							if addon and addon.Print then addon:Print("Copied rules/triggers from " .. tostring(fromKey) .. " (" .. tostring(mode) .. ").") end
						end
					end

					profilesTable.args.zsbtPresetProfiles = {
						type = "group",
						name = "Preset Profiles",
						order = 999,
						inline = true,
						args = {
						desc = {
							type = "description",
							name = "Restore shipped preset profiles (layouts) to their defaults. This only modifies the preset profile itself and does not change which profile you currently have selected.",
							order = 1,
							width = "full",
						},
						resetMelee = {
							type = "execute",
							name = "Reset Preset: Melee",
							order = 2,
							width = "full",
							func = function()
								if ZSBT and ZSBT.Presets and ZSBT.Presets.ResetPreset then
									ZSBT.Presets.ResetPreset("Melee")
									if addon and addon.Print then addon:Print("Reset preset: Melee") end
								end
							end,
						},
						resetRanged = {
							type = "execute",
							name = "Reset Preset: Ranged",
							order = 3,
							width = "full",
							func = function()
								if ZSBT and ZSBT.Presets and ZSBT.Presets.ResetPreset then
									ZSBT.Presets.ResetPreset("Ranged")
									if addon and addon.Print then addon:Print("Reset preset: Ranged") end
								end
							end,
						},
						resetTank = {
							type = "execute",
							name = "Reset Preset: Tank",
							order = 4,
							width = "full",
							func = function()
								if ZSBT and ZSBT.Presets and ZSBT.Presets.ResetPreset then
									ZSBT.Presets.ResetPreset("Tank")
									if addon and addon.Print then addon:Print("Reset preset: Tank") end
								end
							end,
						},
						resetHealer = {
							type = "execute",
							name = "Reset Preset: Healer",
							order = 5,
							width = "full",
							func = function()
								if ZSBT and ZSBT.Presets and ZSBT.Presets.ResetPreset then
									ZSBT.Presets.ResetPreset("Healer")
									if addon and addon.Print then addon:Print("Reset preset: Healer") end
								end
							end,
						},
						resetPetClass = {
							type = "execute",
							name = "Reset Preset: Pet Class",
							order = 6,
							width = "full",
							func = function()
								if ZSBT and ZSBT.Presets and ZSBT.Presets.ResetPreset then
									ZSBT.Presets.ResetPreset("PetClass")
									if addon and addon.Print then addon:Print("Reset preset: Pet Class") end
								end
							end,
						},
					},
				}

				profilesTable.args.zsbtCopyCharData = {
					type = "group",
					name = "Copy Rules / Triggers",
					order = 998,
					inline = true,
					args = {
						desc = {
							type = "description",
							name = "Copy per-character Spell Rules, Buff Rules, and Triggers into your current character. Profiles do not include these items.",
							order = 1,
							width = "full",
						},
						fromChar = {
							type = "select",
							name = "Copy From Character",
							order = 2,
							width = "full",
							values = function() return listCharKeys() end,
							get = function() return addon._copyFromCharKey end,
							set = function(_, v) addon._copyFromCharKey = tostring(v or "") end,
						},
						mode = {
							type = "select",
							name = "Copy Mode",
							order = 3,
							width = "full",
							values = { merge = "Merge (add missing)", replace = "Replace" },
							get = function() return addon._copyCharMode end,
							set = function(_, v) addon._copyCharMode = tostring(v or "merge") end,
						},
						copySpellRules = {
							type = "execute",
							name = "Copy Spell Rules",
							order = 10,
							width = "full",
							func = function() copyFromSelectedChar(true, false, false) end,
						},
						copyAuraRules = {
							type = "execute",
							name = "Copy Buff Rules",
							order = 11,
							width = "full",
							func = function() copyFromSelectedChar(false, true, false) end,
						},
						copyTriggers = {
							type = "execute",
							name = "Copy Triggers",
							order = 12,
							width = "full",
							func = function() copyFromSelectedChar(false, false, true) end,
						},
						copyAll = {
							type = "execute",
							name = "Copy All (Rules + Triggers)",
							order = 13,
							width = "full",
							func = function() copyFromSelectedChar(true, true, true) end,
						},
					},
				}

				safeSetChooseArg(profilesTable)
				safeRestrictDeleteDefault(profilesTable)
				profilesTable.order = 100
				profilesTable.name = "|cFFFFD100DB Profiles|r"
				if options and options.args and options.args.profiles and options.args.profiles.args then
					options.args.profiles.args.acedbProfiles = profilesTable
				elseif options and options.args then
					options.args.acedbProfiles = profilesTable
				end
			end
		end
		local ACR = LibStub("AceConfig-3.0", true)
		local ACD = LibStub("AceConfigDialog-3.0", true)
		if not ACR or not ACD then
			self:Print("|cFFFF4444ZSBT config libraries are missing.|r")
			self:Print("This usually means you installed a no-lib build or the addon was installed incompletely.")
			self:Print("Fix: reinstall ZSBT with embedded libraries, or install the standalone 'Ace3' addon.")
			return
		end
		ACR:RegisterOptionsTable("ZSBT", options)
		self.configDialog = ACD

        -- Set the default size for the config dialog
        self.configDialog:SetDefaultSize("ZSBT", ZSBT.CONFIG_WIDTH,
                                         ZSBT.CONFIG_HEIGHT)

		-- Apply Strike Silver color scheme to config frame
		if ZSBT.ApplyStrikeSilverStyling then
			ZSBT.ApplyStrikeSilverStyling()
		end

		-- Register Spell Rules Manager as a separate config window
		if ZSBT.BuildSpellRulesOptionsTable then
			ACR:RegisterOptionsTable("ZSBT_SpellRules", function()
				return ZSBT.BuildSpellRulesOptionsTable()
			end)
			self.configDialog:SetDefaultSize("ZSBT_SpellRules", 760, 620)
		end

		if ZSBT.BuildBuffRulesOptionsTable then
			ACR:RegisterOptionsTable("ZSBT_BuffRules", function()
				return ZSBT.BuildBuffRulesOptionsTable()
			end)
			self.configDialog:SetDefaultSize("ZSBT_BuffRules", 760, 620)
		end

		if ZSBT.BuildSpellRuleEditorOptionsTable then
			ACR:RegisterOptionsTable("ZSBT_SpellRuleEditor", function()
				return ZSBT.BuildSpellRuleEditorOptionsTable()
			end)
			self.configDialog:SetDefaultSize("ZSBT_SpellRuleEditor", 520, 420)
		end

		if ZSBT.BuildBuffRuleEditorOptionsTable then
			ACR:RegisterOptionsTable("ZSBT_BuffRuleEditor", function()
				return ZSBT.BuildBuffRuleEditorOptionsTable()
			end)
			self.configDialog:SetDefaultSize("ZSBT_BuffRuleEditor", 520, 470)
		end

		if ZSBT.BuildTriggerEditorOptionsTable then
			ACR:RegisterOptionsTable("ZSBT_TriggerEditor", function()
				return ZSBT.BuildTriggerEditorOptionsTable()
			end)
			self.configDialog:SetDefaultSize("ZSBT_TriggerEditor", 560, 520)
		end

		if ZSBT.BuildDebugOptionsTable then
			ACR:RegisterOptionsTable("ZSBT_Debug", function()
				return ZSBT.BuildDebugOptionsTable()
			end)
			self.configDialog:SetDefaultSize("ZSBT_Debug", 620, 520)
		end
	end

    self:Print("|cFF00CC66" .. ZSBT.ADDON_TITLE .. "|r |cFF808C9Ev" .. ZSBT.VERSION ..
                   "|r loaded. Type |cFF00CC66/zsbt|r to configure.")
end

------------------------------------------------------------------------
-- OnEnable: Fires when addon is enabled (after PLAYER_LOGIN)
------------------------------------------------------------------------
function Addon:OnEnable()
    local masterEnabled = self.db and self.db.profile and
                              self.db.profile.general and
                              self.db.profile.general.enabled == true

	pcall(function()
		local existingHandle = ZSBT._lcpConsumerHandle
		local LibStub = _G.LibStub
		if not LibStub then return end
		local LCP = LibStub("LibCombatPulse-1.0", true)
		if not (LCP and LCP.NewConsumer) then return end
		if existingHandle and type(LCP._consumers) == "table" and LCP._consumers["ZSBT"] then
			return
		end
		-- Enable cutover: ZSBT consumes parser events via LibCombatPulse forwarder.
		if not ZSBT._lcpForwarderHandle then
			ZSBT._lcpForwarderHandle = LCP:NewConsumer("ZSBT_FORWARDER", {
				OnEvent = function(ev)
					if type(ev) ~= "table" then return end
					local dir = ev.direction
					if dir == "incoming" then
						local parser = ZSBT.Parser and ZSBT.Parser.Incoming
						if parser and parser.ProcessEvent then
							parser:ProcessEvent(ev)
						end
					elseif dir == "outgoing" then
						local parser = ZSBT.Parser and ZSBT.Parser.Outgoing
						if parser and parser.ProcessEvent then
							parser:ProcessEvent(ev)
						end
					end
				end,
			}, {
				enableCombat = true,
				enableProgress = true,
				enableInterrupts = true,
				enableCooldowns = true,
				minConfidence = "LOW",
			})
			ZSBT._lcpCutoverEnabled = true
		end
		ZSBT._lcpSampleLastAt = ZSBT._lcpSampleLastAt or 0
		local channelDbg = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("lcp")) or 0
		local legacyDbg = (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.debugLevel) or 0
		if (tonumber(channelDbg) or 0) >= 5 or (tonumber(legacyDbg) or 0) >= 5 then
			if Addon and Addon.Print and not ZSBT._lcpDbgRegisteredPrintDone then
				ZSBT._lcpDbgRegisteredPrintDone = true
				Addon:Print("LibCombatPulse consumers active (cutover enabled).")
			end
		end
		ZSBT._lcpConsumerHandle = LCP:NewConsumer("ZSBT", {
			OnEvent = function(ev)
				local channelDbg = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("lcp")) or 0
				local legacyDbg = (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.debugLevel) or 0
				if (tonumber(channelDbg) or 0) < 5 and (tonumber(legacyDbg) or 0) < 5 then return end
				local tNow = (GetTime and GetTime()) or 0
				if (tNow - (ZSBT._lcpSampleLastAt or 0)) < 0.75 then return end
				ZSBT._lcpSampleLastAt = tNow
				if Addon and Addon.Print then
					local function safeStr(v)
						if v == nil then return "nil" end
						if type(v) ~= "string" then return tostring(v) end
						if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
						return "<secret>"
					end
					local function safeNum(v)
						if v == nil then return "nil" end
						if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
						local n = tonumber(v)
						if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(n) then return tostring(n) end
						return safeStr(v)
					end
					local kind = ev and ev.kind
					local et = ev and ev.eventType
					local dir = ev and ev.direction
					local parts = {}
					parts[#parts + 1] = "LCP"
					parts[#parts + 1] = "kind=" .. safeStr(kind)
					parts[#parts + 1] = "type=" .. safeStr(et)
					parts[#parts + 1] = "dir=" .. safeStr(dir)
					if kind == "damage" or kind == "heal" then
						parts[#parts + 1] = "amt=" .. safeNum(ev.amount)
						parts[#parts + 1] = "amtText=" .. safeStr(ev.amountText)
						parts[#parts + 1] = "spellId=" .. safeNum(ev.spellId)
						parts[#parts + 1] = "tgt=" .. safeStr(ev.targetName)
						parts[#parts + 1] = "crit=" .. safeStr(ev.isCrit)
						parts[#parts + 1] = "per=" .. safeStr(ev.isPeriodic)
						parts[#parts + 1] = "src=" .. safeStr(ev.amountSource)
						parts[#parts + 1] = "conf=" .. safeStr(ev.confidence)
					elseif kind == "miss" then
						parts[#parts + 1] = "spellId=" .. safeNum(ev.spellId)
						parts[#parts + 1] = "tgt=" .. safeStr(ev.targetName)
						parts[#parts + 1] = "missType=" .. safeStr(ev.missType)
						parts[#parts + 1] = "miss=" .. safeStr(ev.amountText)
						parts[#parts + 1] = "src=" .. safeStr(ev.amountSource)
						parts[#parts + 1] = "conf=" .. safeStr(ev.confidence)
					elseif kind == "cooldown_ready" then
						parts[#parts + 1] = "spellId=" .. safeNum(ev.spellId)
						parts[#parts + 1] = "spell=" .. safeStr(ev.spellName)
						parts[#parts + 1] = "method=" .. safeStr(ev.method)
						parts[#parts + 1] = "conf=" .. safeStr(ev.confidence)
					elseif kind == "aura_gain" or kind == "aura_fade" then
						parts[#parts + 1] = "spellId=" .. safeNum(ev.spellId)
						parts[#parts + 1] = "spell=" .. safeStr(ev.spellName)
						parts[#parts + 1] = "src=" .. safeStr(ev.source)
						parts[#parts + 1] = "conf=" .. safeStr(ev.confidence)
					elseif kind == "interrupt" or kind == "cast_stop" then
						parts[#parts + 1] = "spellId=" .. safeNum(ev.spellId)
						parts[#parts + 1] = "spell=" .. safeStr(ev.spellName)
						parts[#parts + 1] = "tgt=" .. safeStr(ev.targetName)
						parts[#parts + 1] = "conf=" .. safeStr(ev.confidence)
					else
						parts[#parts + 1] = "spellId=" .. safeNum(ev and ev.spellId)
						parts[#parts + 1] = "tgt=" .. safeStr(ev and ev.targetName)
						parts[#parts + 1] = "conf=" .. safeStr(ev and ev.confidence)
					end
					Addon:Print(table.concat(parts, " "))
				end
			end,
		}, {
			enableCombat = true,
			enableProgress = true,
			enableInterrupts = true,
			enableCooldowns = true,
			minConfidence = "LOW",
		})
	end)

    -- Always init core once (safe, no-op skeleton)
    if ZSBT.Core and ZSBT.Core.Init then ZSBT.Core:Init() end

    -- CRITICAL: Use PLAYER_ENTERING_WORLD to defer parser enable
    -- This event ALWAYS fires outside combat and after all protected loading is complete
    local enableFrame = CreateFrame("Frame")
    enableFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    enableFrame:SetScript("OnEvent", function(self, event)
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")

        -- UI: initialize quick control bar after UIParent is ready.
        if ZSBT.UI and ZSBT.UI.QuickControlBar and ZSBT.UI.QuickControlBar.Init then
            ZSBT.UI.QuickControlBar:Init()
        end

        if masterEnabled then
            if ZSBT.Core and ZSBT.Core.Enable then ZSBT.Core:Enable() end

            -- Enable parsers with combat lockdown protection
            local success = EnableParsers()
            if not success then
                Addon:Print("In combat - ZSBT will fully enable after combat ends.")
            end
        else
            -- Respect saved disabled state
            DisableParsers()
            if ZSBT.Core and ZSBT.Core.Disable then ZSBT.Core:Disable() end
        end
    end)

	-- Apply merge-only class/spec templates on spec change (optional)
	local specFrame = CreateFrame("Frame")
	specFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	specFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
	specFrame:SetScript("OnEvent", function(_, evt, unit)
		if unit and unit ~= "player" then return end
		local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
		local tpl = sc and sc.templates
		if tpl and tpl.applyAllSpecs == true then return end
		if tpl and tpl.autoApplyOnSpecChange == true then
			if ZSBT.ApplyCurrentClassSpecTemplates_Merge then
				ZSBT.ApplyCurrentClassSpecTemplates_Merge()
			end
			local ACR = LibStub("AceConfigRegistry-3.0", true)
			if ACR then
				ACR:NotifyChange("ZSBT_SpellRules")
				ACR:NotifyChange("ZSBT_BuffRules")
				ACR:NotifyChange("ZSBT")
			end
		end
	end)
end

------------------------------------------------------------------------
-- OnDisable: Fires when addon is disabled
------------------------------------------------------------------------
function Addon:OnDisable()
    DisableParsers()
    if ZSBT.Core and ZSBT.Core.Disable then ZSBT.Core:Disable() end
end
-- Slash Command Router
------------------------------------------------------------------------
function Addon:HandleSlashCommand(input)
	local cmd, nextPos = self:GetArgs(input, 1)
	local rest = ""
	if type(input) == "string" and type(nextPos) == "number" and nextPos ~= 1e9 then
		rest = input:sub(nextPos)
		rest = rest:gsub("^%s+", "")
	end

	if not cmd or cmd == "" then
		self:OpenConfig()
		return
	end

    cmd = cmd:lower()

    if cmd == "minimap" then
		local mm = ZSBT.Core and ZSBT.Core.Minimap
		if not (mm and (mm.SetHidden or mm.UpdateVisibility)) then
			self:Print("Minimap button module not available.")
			return
		end
		if mm.Init then
			mm:Init()
		end
		local g = ZSBT.db.profile.general
		g.minimap.hide = not g.minimap.hide
		if mm.SetHidden then
			mm:SetHidden(g.minimap.hide)
		else
			mm:UpdateVisibility()
		end
		self:Print(("Minimap button %s."):format(g.minimap.hide and "hidden" or "shown"))
		return
	end

    if cmd == "debug" then
        self:HandleDebugCommand(rest)
        return
    elseif cmd == "cddebug" then
        self:HandleCooldownDebugCommand(rest)
        return
    elseif cmd == "reset" then
        self:HandleResetCommand()
        return
    elseif cmd == "version" then
        self:Print(ZSBT.ADDON_TITLE .. " v" .. ZSBT.VERSION)
        return
    elseif cmd == "auratest" then
        if ZSBT.Core and ZSBT.Core.RunAuraTest then
            ZSBT.Core:RunAuraTest()
        end
        return
    elseif cmd == "restorefct" then
        if ZSBT.Core and ZSBT.Core.RestoreBlizzardFCT then
            ZSBT.Core:RestoreBlizzardFCT()
            self:Print("Restored Blizzard Floating Combat Text settings.")
        end
        return
    elseif cmd == "dumpcvars" then
		local function safeGet(name)
			if type(GetCVar) ~= "function" then return nil end
			local ok, val = pcall(GetCVar, name)
			if not ok then return nil end
			return val
		end
		local function safeDefault(name)
			if type(GetCVarDefault) ~= "function" then return nil end
			local ok, val = pcall(GetCVarDefault, name)
			if not ok then return nil end
			return val
		end
		local function dump(name)
			local v = safeGet(name)
			local d = safeDefault(name)
			if v == nil and d == nil then
				self:Print(name .. "=<nil>")
				return
			end
			if d ~= nil then
				self:Print(name .. "=" .. tostring(v) .. " (def " .. tostring(d) .. ")")
			else
				self:Print(name .. "=" .. tostring(v))
			end
		end
		self:Print("Blizzard Combat Text CVars:")
		dump("enableFloatingCombatText")
		dump("enableCombatText")
		dump("floatingCombatTextCombatDamage")
		dump("floatingCombatTextCombatDamage_v2")
		dump("floatingCombatTextCombatDamageAllAutos")
		dump("floatingCombatTextCombatDamageAllAutos_v2")
		dump("floatingCombatTextCombatHealing")
		dump("floatingCombatTextCombatHealing_v2")
		dump("floatingCombatTextCombatXP")
		dump("floatingCombatTextCombatXP_v2")
		dump("fctCombatXP")
		dump("fctCombatXP_v2")
		dump("floatingCombatTextReactives")
		dump("floatingCombatTextReactives_v2")
		dump("CombatDamage")
		dump("CombatHealing")
		self:Print("World / XP text scale CVars:")
		dump("WorldTextScale")
		dump("WorldTextSize")
		dump("worldTextScale")
		dump("worldTextSize")
		dump("chatBubblesTextSize")
		dump("floatingCombatTextFloatMode")
		dump("floatingCombatTextFloatMode_v2")
		return
	end

    self:Print("|cFF808C9EUnknown command:|r " .. cmd)
	self:Print("|cFF00CC66Usage:|r /zsbt [minimap | debug [show | <0-5> | <channel> <0-5>] | cddebug [0-5] | reset | version | auratest | restorefct | dumpcvars]")
end

------------------------------------------------------------------------
-- Open Configuration Window
------------------------------------------------------------------------
function Addon:OpenConfig()
	if self.configDialog then
		self.configDialog:Open("ZSBT")
	end
end

function Addon:OpenSpellRulesManager()
	if self.configDialog then
		self.configDialog:Open("ZSBT_SpellRules")
	end
end

function Addon:OpenBuffRulesManager()
    if self.configDialog then
        self.configDialog:Open("ZSBT_BuffRules")
    end
end

function Addon:OpenDebugConfig()
	if self.configDialog then
		self.configDialog:Open("ZSBT_Debug")
	end
end

function Addon:OpenSpellRuleEditor(spellID)
	if type(spellID) ~= "number" then return end
	ZSBT._editingSpellRuleSpellID = spellID
	if self.configDialog then
		self.configDialog:Open("ZSBT_SpellRuleEditor")
	end
end

function Addon:OpenBuffRuleEditor(spellID)
	if type(spellID) ~= "number" then return end
	ZSBT._editingBuffRuleSpellID = spellID
	if self.configDialog then
		self.configDialog:Open("ZSBT_BuffRuleEditor")
	end
end

function Addon:OpenTriggerEditor(index)
	index = tonumber(index)
	if not index or index <= 0 then return end
	ZSBT._editingTriggerIndex = index
	if self.configDialog then
		self.configDialog:Open("ZSBT_TriggerEditor")
	end
end

------------------------------------------------------------------------
-- Debug Level Command
------------------------------------------------------------------------
function Addon:HandleDebugCommand(levelStr)
	local function usage()
		self:Print("Usage:")
		self:Print("  /zsbt debug show")
		self:Print("  /zsbt debug frame <1-10>          (route debug output to ChatFrameN)")
		self:Print("  /zsbt debug <0-5>                 (set global default)")
		self:Print("  /zsbt debug <channel> <0-5>       (set per-channel override)")
		self:Print("Levels: 0=Off, 1=Error, 2=Warn, 3=Info, 4=Debug, 5=Trace")
		self:Print("Channels: core, cooldowns, incoming, outgoing, triggers, notifications, ui, diagnostics, lcp, safety, perf")
	end

	local function show()
		local d = self.db and self.db.profile and self.db.profile.diagnostics
		if type(d) ~= "table" then
			self:Print("Diagnostics not initialized.")
			return
		end
		local def = tonumber(d.debugDefaultLevel)
		if type(def) ~= "number" then def = tonumber(d.debugLevel) or 0 end
		self:Print("Debug default level: " .. tostring(def))
		self:Print("Debug chat frame: " .. tostring(d.debugChatFrame or 1))
		local ch = d.debugChannels
		if type(ch) ~= "table" then
			self:Print("Debug channels: <none>")
			return
		end
		local keys = {}
		for k in pairs(ch) do keys[#keys + 1] = k end
		table.sort(keys)
		for i = 1, #keys do
			local k = keys[i]
			self:Print("  " .. tostring(k) .. "=" .. tostring(ch[k]))
		end
	end

	local input = (type(levelStr) == "string") and levelStr or ""
	input = input:gsub("^%s+", ""):gsub("%s+$", "")
	if input == "" then
		if self.OpenDebugConfig then
			self:OpenDebugConfig()
		else
			show()
		end
		return
	end

	local a, b = self:GetArgs(input, 2)
	a = a and a:lower() or nil

	if a == "show" then
		show()
		return
	end

	if a == "frame" or a == "chatframe" then
		local n = tonumber(b)
		if type(n) ~= "number" or n < 1 or n > 10 then
			usage()
			return
		end
		self.db.profile.diagnostics.debugChatFrame = n
		self:Print("Debug output routed to ChatFrame" .. tostring(n))
		return
	end

	-- /zsbt debug <0-5>
	local nA = tonumber(a)
	if nA ~= nil and b == nil then
		local level = nA
		if level < 0 or level > 5 then
			usage()
			return
		end
		self.db.profile.diagnostics.debugDefaultLevel = level
		self:Print("Debug default level set to " .. tostring(level))
		return
	end

	-- /zsbt debug <channel> <0-5>
	local channel = a
	local level = tonumber(b)
	if type(channel) ~= "string" or channel == "" or level == nil or level < 0 or level > 5 then
		usage()
		return
	end
	self.db.profile.diagnostics.debugChannels = self.db.profile.diagnostics.debugChannels or {}
	self.db.profile.diagnostics.debugChannels[channel] = level
	self:Print("Debug channel '" .. tostring(channel) .. "' set to " .. tostring(level))
end

------------------------------------------------------------------------
-- Cooldown Debug Level Command
------------------------------------------------------------------------
function Addon:HandleCooldownDebugCommand(levelStr)
	local level = tonumber(levelStr)
	if not level or level < 0 or level > 5 then
		self:Print("Usage: /zsbt cddebug [0-5]")
		self:Print("  Alias for: /zsbt debug cooldowns <0-5>")
		return
	end

	self.db.profile.diagnostics.cooldownsDebugLevel = level
	self.db.profile.diagnostics.debugChannels = self.db.profile.diagnostics.debugChannels or {}
	self.db.profile.diagnostics.debugChannels.cooldowns = level
	self:Print("Cooldown debug channel set to " .. tostring(level))
end

------------------------------------------------------------------------
-- Reset to Defaults (with confirmation gate)
------------------------------------------------------------------------
function Addon:HandleResetCommand()
    self.db:ResetProfile()
    self:Print("Profile reset to defaults.")
end

