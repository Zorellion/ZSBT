------------------------------------------------------------------------
-- ZSBT - Triggers (v1)
-- Power-user custom triggers built on safe event sources (no CLEU).
-- Conditions:
--  - Aura gain/fade (by spellID)
--  - Cooldown ready (tracked cooldowns)
--  - Low health / low mana warnings
-- Actions:
--  - Emit notification text to a chosen scroll area
--  - Optional sound (LSM key)
--  - Optional color
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
local Addon = ZSBT.Addon

ZSBT.Core = ZSBT.Core or {}
ZSBT.Core.Triggers = ZSBT.Core.Triggers or {}
local Triggers = ZSBT.Core.Triggers

local function Now() return (GetTime and GetTime()) or 0 end

local function SafeToString(v)
	local ok, s = pcall(tostring, v)
	if ok and type(s) == "string" then return s end
	return "<secret>"
end

local function TrigDebug(msg)
	local level = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics
		and tonumber(ZSBT.db.profile.diagnostics.debugLevel) or 0
	if level == 5 then
		return
	end
	if level >= 2 then
		local out = "|cFF00CCFF[TRG]|r " .. SafeToString(msg)
		if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
			DEFAULT_CHAT_FRAME:AddMessage(out)
		elseif Addon and Addon.Print then
			Addon:Print(out)
		end
	end
end

local function SafeSpellName(spellId)
	if type(spellId) ~= "number" then return nil end
	if C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(spellId)
		if info and type(info.name) == "string" and info.name ~= "" then
			return info.name
		end
	end
	if GetSpellInfo then
		local name = GetSpellInfo(spellId)
		if type(name) == "string" and name ~= "" then return name end
	end
	return nil
end

local GetTrackedTriggerList

local function GetDB()
	local db = ZSBT.db and ZSBT.db.char
	return db and db.triggers
end

function Triggers:IsEnabled()
	local tdb = GetDB()
	return tdb and tdb.enabled == true
end

local function ResolveText(template, ctx)
	if type(template) ~= "string" or template == "" then
		return nil
	end
	ctx = ctx or {}

	local out = template
	out = out:gsub("{spell}", tostring(ctx.spellName or ""))
	out = out:gsub("{id}", tostring(ctx.spellId or ""))
	out = out:gsub("{event}", tostring(ctx.event or ""))
	out = out:gsub("{pct}", tostring(ctx.pct or ""))
	out = out:gsub("{threshold}", tostring(ctx.threshold or ""))
	out = out:gsub("{unit}", tostring(ctx.unit or ""))
	out = out:gsub("{power}", tostring(ctx.powerType or ""))
	out = out:gsub("{value}", tostring(ctx.value or ""))
	out = out:gsub("{stacks}", tostring(ctx.stacks or ""))
	out = out:gsub("{count}", tostring(ctx.count or ""))
	out = out:gsub("{label}", tostring(ctx.label or ""))
	return out
end

local function EmitAction(action, ctx)
	if type(action) ~= "table" then return end

	local text = ResolveText(action.text, ctx)
	if not text then
		TrigDebug("EmitAction skip: empty text (eventType=" .. tostring(ctx and ctx.eventType) .. ")")
		return
	end

	local area = (type(action.scrollArea) == "string" and action.scrollArea ~= "") and action.scrollArea or "Notifications"
	local color = action.color
	if type(color) ~= "table" then
		color = { r = 1.0, g = 1.0, b = 1.0 }
	end

	local soundKey = action.sound
	if type(soundKey) == "string" and soundKey ~= "" and soundKey ~= "None" and ZSBT.PlayLSMSound then
		ZSBT.PlayLSMSound(soundKey)
	end

	local meta = {
		kind = "notification",
		trigger = true,
		eventType = ctx and ctx.eventType,
		spellId = ctx and ctx.spellId,
		sticky = action.sticky == true,
		stickyScale = tonumber(action.stickyScale),
		stickyDurationMult = tonumber(action.stickyDurationMult),
		triggerFontOverride = action.fontOverride == true,
		triggerFontFace = (type(action.fontFace) == "string" and action.fontFace ~= "") and action.fontFace or nil,
		triggerFontOutline = (type(action.fontOutline) == "string" and action.fontOutline ~= "") and action.fontOutline or nil,
		triggerFontSize = tonumber(action.fontSize),
		triggerFontScale = tonumber(action.fontScale),
	}
	if ZSBT.Core and ZSBT.Core.IsNotificationCategoryEnabled then
		if ZSBT.Core:IsNotificationCategoryEnabled("triggers") == false then
			return
		end
	end
	TrigDebug("EmitAction: area=" .. tostring(area) .. " text=" .. tostring(text) .. " sound=" .. tostring(soundKey)
		.. " fontOverride=" .. tostring(meta.triggerFontOverride) .. "")
	if ZSBT.DisplayText then
		ZSBT.DisplayText(area, text, color, meta)
	elseif ZSBT.Core and ZSBT.Core.Display and ZSBT.Core.Display.Emit then
		ZSBT.Core.Display:Emit(area, text, color, meta)
	else
		TrigDebug("EmitAction skip: no display backend")
	end
end

local function PassThrottle(self, trig)
	local throttle = tonumber(trig.throttleSec) or 0
	if throttle <= 0 then return true end
	self._lastAt = self._lastAt or {}
	local id = trig.id or trig._key
	if not id then return true end
	local last = self._lastAt[id]
	local t = Now()
	if last and (t - last) < throttle then
		return false
	end
	self._lastAt[id] = t
	return true
end

function Triggers:FireEvent(eventType, ctx)
	if not self:IsEnabled() then return end
	local tdb = GetDB()
	local list = tdb and tdb.items
	if type(list) ~= "table" then return end
	local skipThrottle = (type(ctx) == "table" and ctx._skipThrottle == true)

	for _, trig in ipairs(list) do
		if type(trig) == "table" and trig.enabled ~= false then
			if trig.eventType == eventType then
				if skipThrottle or PassThrottle(self, trig) then
					local match = true
					if eventType == "AURA_GAIN" or eventType == "AURA_FADE" or eventType == "COOLDOWN_READY" or eventType == "SPELL_USABLE" or eventType == "AURA_STACKS" or eventType == "SPELLCAST_SUCCEEDED" then
						if type(trig.spellId) == "number" then
							match = (type(ctx) == "table" and ctx.spellId == trig.spellId)
						end
					end

					if match then
						TrigDebug("FireEvent match: eventType=" .. tostring(eventType) .. " trigId=" .. tostring(trig.id or trig._key) .. " spellId=" .. tostring(ctx and ctx.spellId))
						EmitAction(trig.action, ctx)
					end
				end
			end
		end
	end
end

function Triggers:OnAuraGain(spellId)
	local name = SafeSpellName(spellId)
	TrigDebug("OnAuraGain spellId=" .. tostring(spellId) .. " name=" .. tostring(name))
	self:FireEvent("AURA_GAIN", {
		eventType = "AURA_GAIN",
		event = "GAIN",
		spellId = spellId,
		spellName = name or ("Spell #" .. tostring(spellId)),
	})
end

function Triggers:_IsAuraPresent(spellId)
	if type(spellId) ~= "number" or spellId <= 0 then return false, 0 end
	local aura = nil
	if AuraUtil and AuraUtil.FindAuraBySpellId then
		local ok, res = pcall(AuraUtil.FindAuraBySpellId, spellId, "player", "HELPFUL")
		if ok then aura = res end
		if not aura then
			ok, res = pcall(AuraUtil.FindAuraBySpellId, spellId, "player", "HARMFUL")
			if ok then aura = res end
		end
	end
	if not aura and UnitAura then
		for i = 1, 40 do
			local ok, name, _, count, _, _, _, _, _, sid = pcall(UnitAura, "player", i, "HELPFUL")
			if not ok then break end
			if not name then break end
			if sid == spellId then
				aura = { applications = count }
				break
			end
		end
		if not aura then
			for i = 1, 40 do
				local ok, name, _, count, _, _, _, _, _, sid = pcall(UnitAura, "player", i, "HARMFUL")
				if not ok then break end
				if not name then break end
				if sid == spellId then
					aura = { applications = count }
					break
				end
			end
		end
	end
	local stacks = aura and aura.applications or 0
	if type(stacks) ~= "number" then stacks = 0 end
	return aura ~= nil, stacks
end

function Triggers:_CheckAuraGainFade()
	if self._hasAuraGainFade ~= true then return end
	local watch = self._auraWatchIds
	if type(watch) ~= "table" then return end
	self._auraPresent = self._auraPresent or {}

	for sid in pairs(watch) do
		if type(sid) == "number" and sid > 0 then
			local present = self:_IsAuraPresent(sid)
			local was = self._auraPresent[sid] == true
			if present and not was then
				self._auraPresent[sid] = true
				TrigDebug("AuraGain spellId=" .. tostring(sid))
				self:OnAuraGain(sid)
			elseif (not present) and was then
				self._auraPresent[sid] = false
				TrigDebug("AuraFade spellId=" .. tostring(sid))
				self:OnAuraFade(sid)
			end
		end
	end
end

function Triggers:OnAuraFade(spellId)
	local name = SafeSpellName(spellId)
	TrigDebug("OnAuraFade spellId=" .. tostring(spellId) .. " name=" .. tostring(name))
	self:FireEvent("AURA_FADE", {
		eventType = "AURA_FADE",
		event = "FADE",
		spellId = spellId,
		spellName = name or ("Spell #" .. tostring(spellId)),
	})
end

function Triggers:SyncWatchedAurasFromCore()
	if not self:IsEnabled() then
		TrigDebug("AuraSync: skip (triggers disabled)")
		return
	end
	GetTrackedTriggerList(self)
	local watch = self._auraWatchIds
	if type(watch) ~= "table" then
		TrigDebug("AuraSync: skip (no watch table; hasAuraGainFade=" .. tostring(self._hasAuraGainFade) .. ")")
		return
	end
	self._auraPresent = self._auraPresent or {}

	local function SafeAuraSpellId(auraData)
		if type(auraData) ~= "table" then return nil end
		local sid = auraData.spellId or auraData.spellID
		return (type(sid) == "number" and sid > 0) and sid or nil
	end

	local function IsAuraPresent(sid)
		if type(sid) ~= "number" or sid <= 0 then return false end
		-- Fast path if available
		if AuraUtil and AuraUtil.FindAuraBySpellId then
			local ok, aura = pcall(AuraUtil.FindAuraBySpellId, sid, "player", "HELPFUL")
			if ok and aura then return true end
			ok, aura = pcall(AuraUtil.FindAuraBySpellId, sid, "player", "HARMFUL")
			if ok and aura then return true end
			return false
		end

		-- Fallback: enumerate auras and compare spellId when provided
		if AuraUtil and AuraUtil.ForEachAura then
			local found = false
			pcall(function()
				AuraUtil.ForEachAura("player", "HELPFUL", 255, function(auraData)
					local asid = SafeAuraSpellId(auraData)
					if asid == sid then found = true; return false end
					return true
				end, true)
			end)
			if found then return true end
			pcall(function()
				AuraUtil.ForEachAura("player", "HARMFUL", 255, function(auraData)
					local asid = SafeAuraSpellId(auraData)
					if asid == sid then found = true; return false end
					return true
				end, true)
			end)
			return found
		end

		if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
			for i = 1, 255 do
				local ok, auraData = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
				if not ok or not auraData then break end
				local asid = SafeAuraSpellId(auraData)
				if asid == sid then return true end
			end
			for i = 1, 255 do
				local ok, auraData = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HARMFUL")
				if not ok or not auraData then break end
				local asid = SafeAuraSpellId(auraData)
				if asid == sid then return true end
			end
			return false
		end

		return false
	end
	local watchCount = 0
	for _ in pairs(watch) do watchCount = watchCount + 1 end
	if watchCount == 0 then
		TrigDebug("AuraSync: skip (watchCount=0; no AURA_GAIN/AURA_FADE spellIds configured?)")
		return
	end
	TrigDebug("AuraSync: watchCount=" .. tostring(watchCount) .. " watchingAvatar=" .. tostring(watch[107574] == true)
		.. " hasFindAuraBySpellId=" .. tostring(AuraUtil and AuraUtil.FindAuraBySpellId ~= nil)
		.. " hasForEachAura=" .. tostring(AuraUtil and AuraUtil.ForEachAura ~= nil)
		.. " hasAuraByIndex=" .. tostring(C_UnitAuras and C_UnitAuras.GetAuraDataByIndex ~= nil))

	for sid in pairs(watch) do
		if type(sid) == "number" and sid > 0 then
			local present = IsAuraPresent(sid)
			if sid == 107574 then
				TrigDebug("AuraSync: Avatar present=" .. tostring(present))
			end

			local was = self._auraPresent[sid] == true
			if present and not was then
				self._auraPresent[sid] = true
				self:OnAuraGain(sid)
			elseif (not present) and was then
				self._auraPresent[sid] = false
				self:OnAuraFade(sid)
			end
		end
	end
end

function Triggers:OnCooldownReady(event)
	if type(event) ~= "table" then return end
	local spellId = event.spellId
	local spellName = event.spellName or SafeSpellName(spellId)
	self:FireEvent("COOLDOWN_READY", {
		eventType = "COOLDOWN_READY",
		event = "READY",
		spellId = spellId,
		spellName = spellName or (spellId and ("Spell #" .. tostring(spellId)) or "Cooldown"),
	})
end

function Triggers:OnLowHealth(pct, threshold)
	self:FireEvent("LOW_HEALTH", {
		eventType = "LOW_HEALTH",
		event = "LOW_HEALTH",
		pct = pct,
		threshold = threshold,
	})
end

GetTrackedTriggerList = function(self)
	local tdb = GetDB()
	local list = tdb and tdb.items
	if type(list) ~= "table" then return nil end
	self._spellUsableList = nil
	self._resourceList = nil
	self._auraStacksList = nil
	self._auraWatchIds = nil
	self._hasAuraGainFade = false

	local su, res, ast = {}, {}, {}
	local watch = {}
	for _, trig in ipairs(list) do
		if type(trig) == "table" and trig.enabled ~= false and type(trig.eventType) == "string" then
			-- Coerce spellId to number for spellId-based triggers when the UI stores it as a string.
			if trig.eventType == "SPELL_USABLE" or trig.eventType == "COOLDOWN_READY" or trig.eventType == "SPELLCAST_SUCCEEDED" or trig.eventType == "AURA_STACKS" then
				local sid = trig.spellId
				if type(sid) == "string" then
					local n = tonumber(sid)
					if type(n) == "number" and n > 0 then
						trig.spellId = n
						TrigDebug("Trigger spellId coerced to number: eventType=" .. tostring(trig.eventType) .. " spellId=" .. tostring(n))
					end
				end
			end

			if trig.eventType == "SPELL_USABLE" then
				su[#su + 1] = trig
			elseif trig.eventType == "RESOURCE_THRESHOLD" then
				res[#res + 1] = trig
			elseif trig.eventType == "AURA_STACKS" then
				ast[#ast + 1] = trig
			elseif trig.eventType == "AURA_GAIN" or trig.eventType == "AURA_FADE" then
				self._hasAuraGainFade = true
				local sid = trig.spellId
				if type(sid) == "string" then
					local n = tonumber(sid)
					if type(n) == "number" and n > 0 then
						trig.spellId = n
						sid = n
						TrigDebug("Aura trigger spellId coerced to number: " .. tostring(n))
					end
				end
				if type(sid) == "number" and sid > 0 then
					watch[sid] = true
				else
					TrigDebug("Aura trigger missing numeric spellId: eventType=" .. tostring(trig.eventType) .. " spellId=" .. tostring(sid))
				end
			end
		end
	end
	self._spellUsableList = su
	self._resourceList = res
	self._auraStacksList = ast
	self._auraWatchIds = watch
	return list
end

function Triggers:OnSpellcastSucceeded(unit, spellId)
	if unit ~= "player" and unit ~= "pet" then return end
	if type(spellId) ~= "number" then return end
	local name = SafeSpellName(spellId)
	self:FireEvent("SPELLCAST_SUCCEEDED", {
		eventType = "SPELLCAST_SUCCEEDED",
		event = "SUCCEEDED",
		unit = unit,
		spellId = spellId,
		spellName = name or ("Spell #" .. tostring(spellId)),
	})
end

function Triggers:OnEnterCombat()
	self:FireEvent("ENTER_COMBAT", {
		eventType = "ENTER_COMBAT",
		event = "ENTER_COMBAT",
		unit = "player",
	})
end

function Triggers:OnLeaveCombat()
	self:FireEvent("LEAVE_COMBAT", {
		eventType = "LEAVE_COMBAT",
		event = "LEAVE_COMBAT",
		unit = "player",
	})
end

function Triggers:OnTargetChanged()
	self:FireEvent("TARGET_CHANGED", {
		eventType = "TARGET_CHANGED",
		event = "TARGET_CHANGED",
		unit = "target",
	})
end

function Triggers:OnEquipmentChanged(slotId, hasItem)
	self:FireEvent("EQUIPMENT_CHANGED", {
		eventType = "EQUIPMENT_CHANGED",
		event = "EQUIPMENT_CHANGED",
		unit = "player",
		value = tonumber(slotId),
		threshold = (hasItem == true) and 1 or 0,
	})
end

function Triggers:OnSpecChanged(unit)
	if unit and unit ~= "player" then return end
	self:FireEvent("SPEC_CHANGED", {
		eventType = "SPEC_CHANGED",
		event = "SPEC_CHANGED",
		unit = "player",
	})
end

function Triggers:OnCombatLogEvent()
	if not CombatLogGetCurrentEventInfo then return end
	local ok, _, subEvent, _, sourceGUID, _, _, _, destGUID, destName = pcall(CombatLogGetCurrentEventInfo)
	if not ok then return end
	if subEvent ~= "PARTY_KILL" then return end
	if not UnitGUID then return end
	local playerGUID = UnitGUID("player")
	if not playerGUID or sourceGUID ~= playerGUID then return end

	self:FireEvent("KILLING_BLOW", {
		eventType = "KILLING_BLOW",
		event = "PARTY_KILL",
		unit = "player",
		spellName = destName,
		value = destName,
		threshold = destGUID,
	})
end

local function IsInCombat()
	if UnitAffectingCombat then
		local ok, res = pcall(UnitAffectingCombat, "player")
		if ok and type(res) == "boolean" then return res end
	end
	return false
end

local function SafeIsUsableSpell(spellId)
	if type(spellId) ~= "number" then return false end
	-- IMPORTANT: In modern clients, many cooldown/charge values can be returned as
	-- "secret" numeric types. Direct numeric comparisons can throw hard errors.
	-- Only compare values that pass ZSBT.IsSafeNumber.
	local isSafeNumber = ZSBT and ZSBT.IsSafeNumber

	-- Prefer our own cooldown detector state if available (safe + combat reliable).
	local cdParser = ZSBT and ZSBT.Parser and ZSBT.Parser.Cooldowns
	local cdState = cdParser and cdParser._state and cdParser._state[spellId]
	if cdState and cdState.isOnCD == true then
		return false
	end

	local cooldownOk = true
	if C_Spell and C_Spell.GetSpellCharges then
		local okc, info = pcall(C_Spell.GetSpellCharges, spellId)
		if okc and type(info) == "table" then
			local cur = info.currentCharges
			local max = info.maxCharges
			if isSafeNumber and isSafeNumber(cur) and isSafeNumber(max) and max > 0 then
				cooldownOk = (cur > 0) and true or false
			end
		end
	end
	if cooldownOk and C_Spell and C_Spell.GetSpellCooldown then
		local okcd, cd = pcall(C_Spell.GetSpellCooldown, spellId)
		if okcd and type(cd) == "table" then
			local dur = cd.duration
			local start = cd.startTime
			if isSafeNumber and isSafeNumber(dur) and isSafeNumber(start) then
				if dur > 0 then
					cooldownOk = false
				end
			end
		end
	end
	if cooldownOk ~= true then return false end
	if C_Spell and C_Spell.IsSpellUsable then
		local ok, usable = pcall(C_Spell.IsSpellUsable, spellId)
		if ok and type(usable) == "boolean" then return usable end
	end
	if IsUsableSpell then
		local ok, usable = pcall(IsUsableSpell, spellId)
		if ok and type(usable) == "boolean" then return usable end
	end
	return false
end

function Triggers:Enable()
	if self._enabled2 then return end
	self._enabled2 = true
	self._lastAt = {}
	self._lastUsable = {}
	self._lastUnusableAt = {}
	GetTrackedTriggerList(self)

	local function CanRegisterEvents()
		-- Be conservative: if we can't positively confirm we're out of combat
		-- lockdown, do NOT call RegisterEvent (it can hard-error/taint the addon).
		if not UnitAffectingCombat then
			return false
		end
		local okCombat, inCombat = pcall(UnitAffectingCombat, "player")
		if not okCombat or type(inCombat) ~= "boolean" then
			return false
		end
		if inCombat == true then
			return false
		end
		if not InCombatLockdown then
			return false
		end
		local ok, locked = pcall(InCombatLockdown)
		if not ok then
			return false
		end
		if type(locked) ~= "boolean" then
			return false
		end
		if locked == true then
			return false
		end
		return true
	end

	local function RegisterEvents() end

	if not self._frame then
		self._frame = CreateFrame("Frame")
		self._frame:SetScript("OnEvent", function(_, event, ...)
			if not Triggers:IsEnabled() then return end
			GetTrackedTriggerList(Triggers)
			if event == "COMBAT_LOG_EVENT_UNFILTERED" then
				Triggers:OnCombatLogEvent()
				return
			end
			if event == "PLAYER_TARGET_CHANGED" then
				Triggers:OnTargetChanged()
				return
			end
			if event == "UNIT_POWER_UPDATE" or event == "UNIT_DISPLAYPOWER" then
				local unit = ...
				if unit == "player" then
					Triggers:_CheckResources(event)
				end
				return
			end
			if event == "UNIT_AURA" then
				local unit = ...
				if unit == "player" then
					Triggers:_CheckAuraGainFade()
					Triggers:_CheckAuraStacks()
				end
				return
			end
			if event == "UNIT_SPELLCAST_SUCCEEDED" then
				local unit, _, spellId = ...
				Triggers:OnSpellcastSucceeded(unit, spellId)
				return
			end
			if event == "PLAYER_REGEN_DISABLED" then
				Triggers:OnEnterCombat()
				return
			end
			if event == "PLAYER_REGEN_ENABLED" then
				Triggers:OnLeaveCombat()
				return
			end
			if event == "PLAYER_EQUIPMENT_CHANGED" then
				local slotId, hasItem = ...
				Triggers:OnEquipmentChanged(slotId, hasItem)
				return
			end
			if event == "PLAYER_SPECIALIZATION_CHANGED" then
				local unit = ...
				Triggers:OnSpecChanged(unit)
				return
			end
		end)
	end

	-- NOTE: Temporarily disable event registration here because some client
	-- states are treating Frame:RegisterEvent as protected at load time and
	-- will disable the addon. We'll rework Triggers to piggyback on a known
	-- safe event dispatcher.
	self._pendingRegister = nil
	if self._registerRetryTicker then
		self._registerRetryTicker:Cancel()
		self._registerRetryTicker = nil
	end

	if not self._spellUsableTicker and C_Timer and C_Timer.NewTicker then
		self._spellUsableTicker = C_Timer.NewTicker(0.25, function()
			if not Triggers:IsEnabled() then return end
			GetTrackedTriggerList(Triggers)
			if Triggers.SyncWatchedAurasFromCore then
				local now = Now()
				if not Triggers._lastAuraSyncAt or (now - Triggers._lastAuraSyncAt) >= 0.5 then
					Triggers._lastAuraSyncAt = now
					local ok, err = pcall(function() Triggers:SyncWatchedAurasFromCore() end)
					if not ok and Addon and Addon.Print then
						Addon:Print("[TRG] AuraSync error: " .. tostring(err))
					end
				end
			end
			Triggers:_CheckSpellUsable()
		end)
	end
end

function Triggers:Disable()
	self._enabled2 = false
	self._pendingRegister = nil
	if self._registerRetryTicker then
		self._registerRetryTicker:Cancel()
		self._registerRetryTicker = nil
	end
	if self._frame then
		local okToUnreg = true
		if InCombatLockdown then
			local ok, locked = pcall(InCombatLockdown)
			if ok and locked == true then okToUnreg = false end
		end
		if okToUnreg then
			pcall(function() self._frame:UnregisterAllEvents() end)
		else
			-- In combat lockdown; leave events registered and rely on early return
			-- at top of OnEvent because self._enabled2 is false.
		end
	end
	if self._spellUsableTicker then
		self._spellUsableTicker:Cancel()
		self._spellUsableTicker = nil
	end
end

function Triggers:_CheckResources(source)
	local list = self._resourceList
	if type(list) ~= "table" or #list == 0 then return end

	for _, trig in ipairs(list) do
		local pt = trig.powerType
		local threshold = tonumber(trig.thresholdValue) or 0
		local direction = trig.direction or "BELOW"
		local powerTypeEnum = nil
		if type(pt) == "string" and pt ~= "" and _G and _G[pt] then
			powerTypeEnum = _G[pt]
		end
		local p = nil
		local maxp = nil
		if UnitPower then
			local ok, v = pcall(UnitPower, "player", powerTypeEnum)
			if ok and type(v) == "number" then p = v end
		end
		if UnitPowerMax then
			local ok, v = pcall(UnitPowerMax, "player", powerTypeEnum)
			if ok and type(v) == "number" then maxp = v end
		end
		if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(p) then
			local pass = (direction == "ABOVE") and (p >= threshold) or (p <= threshold)
			if pass and PassThrottle(self, trig) then
				self:FireEvent("RESOURCE_THRESHOLD", {
					eventType = "RESOURCE_THRESHOLD",
					event = "POWER",
					unit = "player",
					powerType = pt or "",
					value = p,
					threshold = threshold,
					pct = (ZSBT.IsSafeNumber(maxp) and maxp > 0) and math.floor(((p / maxp) * 100) + 0.5) or nil,
				})
			end
		end
	end
end

function Triggers:_CheckAuraStacks()
	local list = self._auraStacksList
	if type(list) ~= "table" or #list == 0 then return end

	for _, trig in ipairs(list) do
		local sid = trig.spellId
		if type(sid) == "number" and sid > 0 then
			local minStacks = tonumber(trig.minStacks) or 0
			local maxStacks = tonumber(trig.maxStacks) or nil
			local stacks = 0
			if AuraUtil and AuraUtil.FindAuraBySpellId then
				local aura = AuraUtil.FindAuraBySpellId(sid, "player", "HELPFUL")
				stacks = aura and aura.applications or 0
			end
			if type(stacks) ~= "number" then stacks = 0 end
			local pass = stacks >= minStacks
			if pass and type(maxStacks) == "number" then
				pass = stacks <= maxStacks
			end
			if pass and PassThrottle(self, trig) then
				self:FireEvent("AURA_STACKS", {
					eventType = "AURA_STACKS",
					event = "STACKS",
					unit = "player",
					spellId = sid,
					spellName = SafeSpellName(sid) or ("Spell #" .. tostring(sid)),
					stacks = stacks,
					threshold = minStacks,
				})
			end
		end
	end
end

function Triggers:_CheckSpellUsable()
	local list = self._spellUsableList
	if type(list) ~= "table" or #list == 0 then return end
	self._lastUsable = self._lastUsable or {}
	self._lastUnusableAt = self._lastUnusableAt or {}
	local now = (type(GetTime) == "function") and GetTime() or 0

	for _, trig in ipairs(list) do
		local sid = trig.spellId
		if type(sid) == "number" and sid > 0 then
			local onlyCombat = trig.onlyInCombat ~= false
			local inCombat = IsInCombat()
			if (not onlyCombat) or inCombat then
				local usable = SafeIsUsableSpell(sid)
				local cdDur, cdStart = nil, nil
				if C_Spell and C_Spell.GetSpellCooldown then
					local okcd, cd = pcall(C_Spell.GetSpellCooldown, sid)
					if okcd and type(cd) == "table" then
						cdDur = cd.duration
						cdStart = cd.startTime
					end
				end
				local chCur, chMax = nil, nil
				if C_Spell and C_Spell.GetSpellCharges then
					local okch, info = pcall(C_Spell.GetSpellCharges, sid)
					if okch and type(info) == "table" then
						chCur = info.currentCharges
						chMax = info.maxCharges
					end
				end
				local key = trig.id or trig._key or sid
				local wasUsable = self._lastUsable[key] == true
				self._lastUsable[key] = usable and true or false
				local rearmSec = tonumber(trig.rearmUnusableSec) or 0
				local lastUnusable = self._lastUnusableAt[key]

				-- Track when we last observed the spell as unusable.
				if not usable then
					if (not lastUnusable) or wasUsable then
						self._lastUnusableAt[key] = now
						lastUnusable = now
					end
				end

				-- Fire only on edge (unusable -> usable)
				local isEdge = usable and (not wasUsable)
				local rearmOk = true
				local sinceUnusable = nil
				if rearmSec > 0 then
					if type(lastUnusable) == "number" then
						sinceUnusable = now - lastUnusable
						rearmOk = sinceUnusable >= rearmSec
					else
						rearmOk = true
					end
				end
				local passThrottle = isEdge and rearmOk and PassThrottle(self, trig)
				if isEdge and rearmOk and passThrottle then
					self:FireEvent("SPELL_USABLE", {
						eventType = "SPELL_USABLE",
						event = "USABLE",
						_skipThrottle = true,
						unit = "player",
						spellId = sid,
						spellName = SafeSpellName(sid) or ("Spell #" .. tostring(sid)),
					})
					TrigDebug("SpellUsable fire: sid=" .. tostring(sid) .. " combat=" .. tostring(inCombat) .. "")
				else
					TrigDebug("SpellUsable check: sid=" .. tostring(sid)
						.. " usable=" .. tostring(usable)
						.. " cdDur=" .. tostring(cdDur)
						.. " cdStart=" .. tostring(cdStart)
						.. " ch=" .. tostring(chCur) .. "/" .. tostring(chMax)
						.. " wasUsable=" .. tostring(wasUsable)
						.. " edge=" .. tostring(isEdge)
						.. " rearmSec=" .. tostring(rearmSec)
						.. " sinceUnusable=" .. tostring(sinceUnusable)
						.. " passThrottle=" .. tostring(passThrottle)
						.. " combat=" .. tostring(inCombat) .. "")
				end
			else
				TrigDebug("SpellUsable skip: sid=" .. tostring(sid) .. " (not in combat)")
			end
		end
	end
end

function Triggers:DebugDump()
	local tdb = GetDB()
	local n = 0
	if tdb and type(tdb.items) == "table" then
		n = #tdb.items
	end
	if Addon and Addon.Print then
		Addon:Print("Triggers: count = " .. tostring(n))
	end
end
