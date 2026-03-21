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
		if psc and type(psc.spellRules) == "table" then
			for sid, rule in pairs(psc.spellRules) do
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
			if type(ptr.enabled) == "boolean" then
				self.db.char.triggers.enabled = ptr.enabled
			end
			if type(ptr.items) == "table" and #self.db.char.triggers.items == 0 then
				self.db.char.triggers.utDeletedPresets = self.db.char.triggers.utDeletedPresets or {}
				local utDeleted = self.db.char.triggers.utDeletedPresets
				for i, trig in ipairs(ptr.items) do
					if type(trig) == "table" then
						if type(trig.eventType) == "string" and utDeleted[trig.eventType] == true then
							-- User deleted this shipped UT preset; keep deleted.
						else
							local copy = {}
							for k, v in pairs(trig) do
								if type(v) == "table" then
									local sub = {}
									for k2, v2 in pairs(v) do sub[k2] = v2 end
									copy[k] = sub
								else
									copy[k] = v
								end
							end
							self.db.char.triggers.items[i] = copy
						end
					end
				end
			end
			prof.triggers = nil
		end

		self.db.global.migrations.rulesToChar_v1 = true
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
				if self.db.char.cooldowns.tracked[idKey] == nil then
					self.db.char.cooldowns.tracked[idKey] = v
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
				PlaySoundFile(path, "Master")
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
			LSM:Register("font", "ZSBT: SuperAdorable", [[Interface\AddOns\ZSBT\Media\Fonts\SuperAdorable.ttf]])
			LSM:Register("font", "ZSBT: SuperShiny", [[Interface\AddOns\ZSBT\Media\Fonts\SuperShiny.ttf]])
			LSM:Register("font", "ZSBT: StoryScript Regular", [[Interface\AddOns\ZSBT\Media\Fonts\StoryScript-Regular.ttf]])
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
			-- Request the profiles options table without AceDBOptions' built-in
			-- "common" suggestions (realm/class/char/Default). We only want to show
			-- real saved profiles the user has actually created.
			local profilesTable = AceDBOptions:GetOptionsTable(self.db, true)
			-- Prevent deleting the Default profile from the Profiles tab.
			-- AceDB itself already blocks deleting the active profile, but we also
			-- explicitly protect the "Default" profile.
			if profilesTable and profilesTable.handler and profilesTable.args then
				local addon = self
				local handler = profilesTable.handler
				local oldDeleteProfile = handler.DeleteProfile
				handler.DeleteProfile = function(h, info, value)
					if value == "Default" then
						return
					end
					if oldDeleteProfile then
						return oldDeleteProfile(h, info, value)
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

				local chooseOpt = profilesTable.args.choose
				if chooseOpt then
					chooseOpt.arg = "nocurrent"
				end

				local deleteOpt = profilesTable.args.delete
				if deleteOpt then
					deleteOpt.values = function(info)
						local profiles = info.handler:ListProfiles(info)
						if type(profiles) == "table" then
							profiles["Default"] = nil
						end
						return profiles
					end
					deleteOpt.disabled = function(info)
						local profiles = info.option.values(info)
						return (type(profiles) ~= "table") or (not next(profiles))
					end
				end
			end
			profilesTable.order = 100
			profilesTable.name = "|cFFFFD100DB Profiles|r"
			options.args.acedbProfiles = profilesTable
		end
        LibStub("AceConfig-3.0"):RegisterOptionsTable("ZSBT", options)
        self.configDialog = LibStub("AceConfigDialog-3.0")

        -- Set the default size for the config dialog
        self.configDialog:SetDefaultSize("ZSBT", ZSBT.CONFIG_WIDTH,
                                         ZSBT.CONFIG_HEIGHT)

        -- Apply Strike Silver color scheme to config frame
        if ZSBT.ApplyStrikeSilverStyling then
            ZSBT.ApplyStrikeSilverStyling()
        end

		-- Register Spell Rules Manager as a separate config window
		if ZSBT.BuildSpellRulesOptionsTable then
			LibStub("AceConfig-3.0"):RegisterOptionsTable("ZSBT_SpellRules", function()
				return ZSBT.BuildSpellRulesOptionsTable()
			end)
			self.configDialog:SetDefaultSize("ZSBT_SpellRules", 760, 620)
		end

		if ZSBT.BuildBuffRulesOptionsTable then
			LibStub("AceConfig-3.0"):RegisterOptionsTable("ZSBT_BuffRules", function()
				return ZSBT.BuildBuffRulesOptionsTable()
			end)
			self.configDialog:SetDefaultSize("ZSBT_BuffRules", 760, 620)
		end

		if ZSBT.BuildSpellRuleEditorOptionsTable then
			LibStub("AceConfig-3.0"):RegisterOptionsTable("ZSBT_SpellRuleEditor", function()
				return ZSBT.BuildSpellRuleEditorOptionsTable()
			end)
			self.configDialog:SetDefaultSize("ZSBT_SpellRuleEditor", 520, 420)
		end

		if ZSBT.BuildBuffRuleEditorOptionsTable then
			LibStub("AceConfig-3.0"):RegisterOptionsTable("ZSBT_BuffRuleEditor", function()
				return ZSBT.BuildBuffRuleEditorOptionsTable()
			end)
			self.configDialog:SetDefaultSize("ZSBT_BuffRuleEditor", 520, 470)
		end

		if ZSBT.BuildTriggerEditorOptionsTable then
			LibStub("AceConfig-3.0"):RegisterOptionsTable("ZSBT_TriggerEditor", function()
				return ZSBT.BuildTriggerEditorOptionsTable()
			end)
			self.configDialog:SetDefaultSize("ZSBT_TriggerEditor", 560, 520)
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

------------------------------------------------------------------------
-- Slash Command Router
------------------------------------------------------------------------
function Addon:HandleSlashCommand(input)
    local cmd, rest = self:GetArgs(input, 2)

    if not cmd or cmd == "" then
        self:OpenConfig()
        return
    end

    cmd = cmd:lower()

    if cmd == "minimap" then
        if ZSBT.Core and ZSBT.Core.Minimap and ZSBT.Core.Minimap.UpdateVisibility then
            local g = ZSBT.db.profile.general
            g.minimap.hide = not g.minimap.hide
            ZSBT.Core.Minimap:UpdateVisibility()
            self:Print(("Minimap button %s."):format(g.minimap.hide and "hidden" or "shown"))
        end
        return
    end

    if cmd == "debug" then
        self:HandleDebugCommand(rest)
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
    end

    self:Print("|cFF808C9EUnknown command:|r " .. cmd)
	self:Print("|cFF00CC66Usage:|r /zsbt [minimap | debug 0-4 | reset | version | auratest | restorefct]")
end

------------------------------------------------------------------------
-- Open Configuration Window
------------------------------------------------------------------------
function Addon:OpenConfig()
    if self.configDialog then
        self.configDialog:Open("ZSBT")

        local frame = self.configDialog.OpenFrames["ZSBT"]
        if frame and frame.frame then
            local f = frame.frame

            -- Prevent AceConfigDialog from auto-closing when spellbook opens
            if not f.zsbtHooked then
                f.zsbtHooked = true

                -- Store original Hide function
                local origHide = f.Hide

                -- Hook Hide to block auto-closes
                f.Hide = function(self, ...)
                    -- Only allow closes when explicitly permitted
                    if not self.zsbtAllowClose then return end
                    return origHide(self, ...)
                end
            end

            -- Find the close button by searching the frame's children
            local function findCloseButton(parent, depth)
                depth = depth or 0
                if depth > 0 then return end -- ONLY check depth 0!

                for i = 1, parent:GetNumChildren() do
                    local child = select(i, parent:GetChildren())
                    if child and child.GetObjectType and child:GetObjectType() ==
                        "Button" then
                        local text = child:GetText()
                        if text and (text:lower():match("close") or text == "X") then
                            child:HookScript("PreClick", function()
                                f.zsbtAllowClose = true
                                C_Timer.After(0.05, function()
                                    f.zsbtAllowClose = false
                                end)
                            end)
                        end
                    end
                end
            end

            findCloseButton(f)

            -- ESC key handler — protected in instances/combat.
            -- Only set up when safe (not in combat).
            if not InCombatLockdown() then
                f:EnableKeyboard(true)
                f:SetPropagateKeyboardInput(true)
                f:SetScript("OnKeyDown", function(self, key)
                    if key == "ESCAPE" then
                        self.zsbtAllowClose = true
                        self:Hide()
                        C_Timer.After(0.05, function()
                            if self then
                                self.zsbtAllowClose = false
                            end
                        end)
                    end
                end)
            end
        end
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
    local level = tonumber(levelStr)
    if not level or level < ZSBT.DEBUG_LEVEL_NONE or level >
		ZSBT.DEBUG_LEVEL_TRACE then
		self:Print("Usage: /zsbt debug [0-4]")
		self:Print("  0 = Off, 1 = Suppressed, 2 = Confidence, 3 = All Events, 4 = Trace")
		return
    end

    self.db.profile.diagnostics.debugLevel = level
    	local names = {
		[0] = "Off",
		[1] = "Suppressed",
		[2] = "Confidence",
		[3] = "All Events",
		[4] = "Trace",
	}
    self:Print("Debug level set to " .. level .. " (" .. names[level] .. ")")
end

------------------------------------------------------------------------
-- Reset to Defaults (with confirmation gate)
------------------------------------------------------------------------
function Addon:HandleResetCommand()
    self.db:ResetProfile()
    self:Print("Profile reset to defaults.")
end

