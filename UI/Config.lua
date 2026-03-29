------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - Configuration UI
-- Builds the master AceConfig-3.0 options table with all 8 tabs.
-- Each tab is constructed in ConfigTabs.lua and assembled here.
------------------------------------------------------------------------

local ADDON_NAME, ZSBT = ...
local Addon = ZSBT.Addon
local LSM = LibStub("LibSharedMedia-3.0")

ZSBT._editingSpellRuleSpellID = ZSBT._editingSpellRuleSpellID or nil
ZSBT._editingBuffRuleSpellID = ZSBT._editingBuffRuleSpellID or nil
ZSBT._editingTriggerIndex = ZSBT._editingTriggerIndex or nil

function ZSBT.ResolveSpellInputToID(input)
	if input == nil then return nil, nil end
	local s = tostring(input or "")
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then return nil, nil end

	local n = tonumber(s)
	if n and n > 0 then
		local name = nil
		if C_Spell and C_Spell.GetSpellInfo then
			local ok, info = pcall(C_Spell.GetSpellInfo, n)
			name = ok and info and info.name or nil
		end
		if not name and GetSpellInfo then
			local ok, fetched = pcall(GetSpellInfo, n)
			name = ok and fetched or nil
		end
		return n, name
	end

	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, s)
		if ok and type(info) == "table" then
			local sid = info.spellID or info.spellId
			if type(sid) == "number" and sid > 0 then
				return sid, info.name
			end
		end
	end
	if GetSpellInfo then
		local ok, name, _, _, _, _, _, spellId = pcall(GetSpellInfo, s)
		if ok and type(spellId) == "number" and spellId > 0 then
			return spellId, name
		end
	end

	return nil, nil
end

function ZSBT.GetResolvedSpellLabel(spellId)
	if type(spellId) ~= "number" or spellId <= 0 then return "" end
	local name = nil
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
		name = ok and info and info.name or nil
	end
	if not name and GetSpellInfo then
		local ok, fetched = pcall(GetSpellInfo, spellId)
		name = ok and fetched or nil
	end
	name = name or ("Spell #" .. tostring(spellId))
	return "Resolved: " .. tostring(name) .. " (ID: " .. tostring(spellId) .. ")"
end

do
    local AceGUI = LibStub("AceGUI-3.0", true)
    if AceGUI and not AceGUI:GetWidgetVersion("ZSBT_InstantEditBox") then
        local Type, Version = "ZSBT_InstantEditBox", 1

        local CreateFrame, UIParent = CreateFrame, UIParent

        local function Control_OnEnter(frame)
            frame.obj:Fire("OnEnter")
        end

        local function Control_OnLeave(frame)
            frame.obj:Fire("OnLeave")
        end

        local function EditBox_OnEscapePressed(frame)
            AceGUI:ClearFocus()
        end

        local function EditBox_OnEnterPressed(frame)
            local self = frame.obj
            -- Enter already commits the value. Avoid double-committing when focus is
            -- subsequently lost due to UI refresh/tab switches.
            self._zsbtSkipNextFocusLostCommit = true
            self:Fire("OnEnterPressed", frame:GetText() or "")
            AceGUI:ClearFocus()
        end

        local function EditBox_OnTextChanged(frame)
            local self = frame.obj
            if self._zsbtSettingText then return end
            self.lasttext = frame:GetText() or ""
        end

        local function EditBox_OnFocusLost(frame)
            local self = frame.obj
            if self._zsbtSkipNextFocusLostCommit then
                self._zsbtSkipNextFocusLostCommit = nil
                return
            end
            self:Fire("OnEnterPressed", frame:GetText() or "")
        end

        local function EditBox_OnFocusGained(frame)
            AceGUI:SetFocus(frame.obj)
        end

        local methods = {
            OnAcquire = function(self)
                self:SetWidth(200)
                self:SetDisabled(false)
                self:SetLabel("")
                self:SetText("")
                self:SetMaxLetters(0)
            end,

            OnRelease = function(self)
                self.editbox:ClearFocus()
                self.frame:SetScript("OnShow", nil)
            end,

            SetDisabled = function(self, disabled)
                self.disabled = disabled
                if disabled then
                    self.editbox:EnableMouse(false)
                    self.editbox:ClearFocus()
                    self.editbox:SetTextColor(0.5, 0.5, 0.5)
                    self.label:SetTextColor(0.5, 0.5, 0.5)
                else
                    self.editbox:EnableMouse(true)
                    self.editbox:SetTextColor(1, 1, 1)
                    self.label:SetTextColor(1, .82, 0)
                end
            end,

            SetText = function(self, text)
                text = text or ""
                if tostring(self.editbox:GetText() or "") == tostring(text) then
                    return
                end

                local hadFocus = self.editbox:HasFocus()
                local cursor = self.editbox:GetCursorPosition()

                self._zsbtSettingText = true
                self.editbox:SetText(text)
                if hadFocus then
                    local maxPos = #text
                    if cursor > maxPos then cursor = maxPos end
                    self.editbox:SetCursorPosition(cursor)
                else
                    self.editbox:SetCursorPosition(0)
                end
                self._zsbtSettingText = false
            end,

            GetText = function(self)
                return self.editbox:GetText()
            end,

            SetLabel = function(self, text)
                text = text or ""
                if text ~= "" then
                    self.label:SetText(text)
                    self.label:Show()
                    self.editbox:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 7, -18)
                    self:SetHeight(44)
                    self.alignoffset = 30
                else
                    self.label:SetText("")
                    self.label:Hide()
                    self.editbox:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 7, 0)
                    self:SetHeight(26)
                    self.alignoffset = 12
                end
            end,

            SetMaxLetters = function(self, num)
                self.editbox:SetMaxLetters(num or 0)
            end,

            ClearFocus = function(self)
                self.editbox:ClearFocus()
                self.frame:SetScript("OnShow", nil)
            end,

            SetFocus = function(self)
                self.editbox:SetFocus()
                if not self.frame:IsShown() then
                    self.frame:SetScript("OnShow", function(f)
                        f.obj.editbox:SetFocus()
                        f:SetScript("OnShow", nil)
                    end)
                end
            end,

            HighlightText = function(self, from, to)
                self.editbox:HighlightText(from, to)
            end,
        }

        local function Constructor()
            local frame = CreateFrame("Frame", nil, UIParent)
            frame:Hide()

            local editbox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
            editbox:SetAutoFocus(false)
            editbox:SetFontObject(ChatFontNormal)
            editbox:SetScript("OnEscapePressed", EditBox_OnEscapePressed)
            editbox:SetScript("OnEnterPressed", EditBox_OnEnterPressed)
            editbox:SetScript("OnTextChanged", EditBox_OnTextChanged)
            editbox:SetScript("OnEditFocusGained", EditBox_OnFocusGained)
            editbox:SetScript("OnEditFocusLost", EditBox_OnFocusLost)
            editbox:SetScript("OnEnter", Control_OnEnter)
            editbox:SetScript("OnLeave", Control_OnLeave)
            editbox:SetPoint("TOPLEFT", frame, "TOPLEFT", 7, 0)
            editbox:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -7, 0)

            local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetPoint("TOPLEFT", frame, "TOPLEFT", 7, 0)
            label:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -7, 0)
            label:SetJustifyH("LEFT")
            label:Hide()

            local widget = {
                type = Type,
                frame = frame,
                editbox = editbox,
                label = label,
            }

            for k, v in pairs(methods) do
                widget[k] = v
            end

            editbox.obj = widget
            frame.obj = widget

            return AceGUI:RegisterAsWidget(widget)
        end

        AceGUI:RegisterWidgetType(Type, Constructor, Version)
    end
end

------------------------------------------------------------------------
-- Helper: Build a dropdown values table from a key/value table
------------------------------------------------------------------------
function ZSBT.ValuesFromKeys(tbl)
    local out = {}
    for k, _ in pairs(tbl) do
        out[k] = k
    end

    return out
end

function ZSBT.BuildBuffRulesOptionsTable()
    assert(ZSBT.BuildTab_BuffRulesManager, "ConfigTabs.lua must be loaded before Config.lua")

	local tab = ZSBT.BuildTab_BuffRulesManager()
	local args = (tab and tab.args) or {}

    return {
        type = "group",
		name = "|cFFFFD100Buff Rules|r",
		childGroups = "tab",
		args = args,
    }
end

------------------------------------------------------------------------
-- Helper: Get available scroll area names from current profile
------------------------------------------------------------------------
function ZSBT.GetScrollAreaNames()
    local names = {}
    if ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.scrollAreas then
        for name, _ in pairs(ZSBT.db.profile.scrollAreas) do
            names[name] = name
        end
    end
    return names
end

function ZSBT.BuildTriggerEditorOptionsTable()
	local function getTrigger()
		local idx = ZSBT._editingTriggerIndex
		local db = ZSBT.db and ZSBT.db.char and ZSBT.db.char.triggers
		local items = db and db.items
		if type(idx) ~= "number" or type(items) ~= "table" then return nil end
		return items[idx]
	end

	local function notify()
		if ZSBT.RefreshTriggersTab then
			ZSBT.RefreshTriggersTab()
		end
		local ACR = LibStub("AceConfigRegistry-3.0", true)
		if ACR then
			ACR:NotifyChange("ZSBT")
		end
	end

	local function ensureTrigger()
		local idx = ZSBT._editingTriggerIndex
		local db = ZSBT.db and ZSBT.db.char and ZSBT.db.char.triggers
		if not (type(idx) == "number" and idx > 0 and db) then return nil end
		db.items = db.items or {}
		db.items[idx] = db.items[idx] or { enabled = true, throttleSec = 0, action = {} }
		db.items[idx].action = db.items[idx].action or {}
		return db.items[idx]
	end

	local EVENT_VALUES = {
		["AURA_GAIN"] = "AURA_GAIN",
		["AURA_FADE"] = "AURA_FADE",
		["AURA_STACKS"] = "AURA_STACKS",
		["COOLDOWN_READY"] = "COOLDOWN_READY",
		["LOW_HEALTH"] = "LOW_HEALTH",
		["RESOURCE_THRESHOLD"] = "RESOURCE_THRESHOLD",
		["SPELL_USABLE"] = "SPELL_USABLE",
		["SPELLCAST_SUCCEEDED"] = "SPELLCAST_SUCCEEDED",
		["KILLING_BLOW"] = "KILLING_BLOW",
		["UT_KILL_1"] = "UT_KILL_1",
		["UT_KILL_2"] = "UT_KILL_2",
		["UT_KILL_3"] = "UT_KILL_3",
		["UT_KILL_4"] = "UT_KILL_4",
		["UT_KILL_5"] = "UT_KILL_5",
		["UT_KILL_6"] = "UT_KILL_6",
		["UT_KILL_7"] = "UT_KILL_7",
		["ENTER_COMBAT"] = "ENTER_COMBAT",
		["LEAVE_COMBAT"] = "LEAVE_COMBAT",
		["TARGET_CHANGED"] = "TARGET_CHANGED",
		["EQUIPMENT_CHANGED"] = "EQUIPMENT_CHANGED",
		["SPEC_CHANGED"] = "SPEC_CHANGED",
	}

	local EVENT_HELP = {
		AURA_GAIN = "Fires when you gain a buff/aura. Optionally set SpellID to match a specific aura.",
		AURA_FADE = "Fires when a buff/aura fades. Optionally set SpellID to match a specific aura.",
		AURA_STACKS = "Fires when the player's aura stack count is at/above the configured threshold. Optionally set Max Stacks to cap it.",
		COOLDOWN_READY = "Fires when a tracked cooldown becomes ready. Best used with specific SpellID.",
		LOW_HEALTH = "Fires when Blizzard's low health warning triggers (red border).",
		RESOURCE_THRESHOLD = "Fires when your resource (mana/rage/energy/etc.) crosses the threshold (above or below).",
		SPELL_USABLE = "Fires when the spell becomes usable (edge: unusable  usable). Uses polling and can flicker based on resources/targeting; use Rearm-after-unusable and/or Throttle to prevent noise. Great workaround for Execute-style reminders when target HP is protected.",
		SPELLCAST_SUCCEEDED = "Fires when you successfully cast a spell (UNIT_SPELLCAST_SUCCEEDED on player). Optionally set SpellID to match a specific spell.",
		KILLING_BLOW = "Fires when you personally land a killing blow (combat log PARTY_KILL).",
		UT_KILL_1 = "Fires on the 1st kill in a rapid kill chain (UT announcer). Tokens: {count} {value}.",
		UT_KILL_2 = "Fires on the 2nd kill in a rapid kill chain (UT announcer). Tokens: {count} {value}.",
		UT_KILL_3 = "Fires on the 3rd kill in a rapid kill chain (UT announcer). Tokens: {count} {value}.",
		UT_KILL_4 = "Fires on the 4th kill in a rapid kill chain (UT announcer). Tokens: {count} {value}.",
		UT_KILL_5 = "Fires on the 5th kill in a rapid kill chain (UT announcer). Tokens: {count} {value}.",
		UT_KILL_6 = "Fires on the 6th kill in a rapid kill chain (UT announcer). Tokens: {count} {value}.",
		UT_KILL_7 = "Fires on the 7th+ kill in a rapid kill chain (UT announcer). Tokens: {count} {value}.",
		ENTER_COMBAT = "Fires when you enter combat.",
		LEAVE_COMBAT = "Fires when you leave combat.",
		TARGET_CHANGED = "Fires when your target changes.",
		EQUIPMENT_CHANGED = "Fires when your equipment changes (slot id in {value}).",
		SPEC_CHANGED = "Fires when your specialization changes.",
	}

	local function GetEventHelpText()
		local t = getTrigger()
		local et = (type(t) == "table" and t.eventType) or "AURA_GAIN"
		return EVENT_HELP[et] or ""
	end

	return {
		type = "group",
		name = "Trigger Editor",
		args = {
			eventHelp = {
				type = "description",
				name = function() return GetEventHelpText() end,
				order = 0.5,
				fontSize = "medium",
				width = "full",
			},
			header = { type = "header", name = "Edit Trigger", order = 1 },
			info = {
				type = "description",
				name = "Text tokens: {spell} {id} {event} {pct} {threshold} {unit} {power} {value} {stacks} {count} {label}",
				order = 2,
				fontSize = "medium",
			},
			enabled = {
				type = "toggle",
				name = "Enabled",
				order = 3,
				width = "full",
				get = function()
					local t = getTrigger()
					return type(t) == "table" and t.enabled ~= false
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.enabled = v and true or false
					notify()
				end,
			},
			eventType = {
				type = "select",
				name = "Event Type",
				order = 4,
				values = EVENT_VALUES,
				get = function()
					local t = getTrigger()
					return type(t) == "table" and t.eventType or "AURA_GAIN"
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.eventType = v
					notify()
				end,
			},
			spellId = {
				type = "input",
				name = "SpellID (optional)",
				desc = "Enter a SpellID or exact spell name. Used for Aura Gain/Fade, Cooldown Ready, Spell Usable, Aura Stacks, and Spellcast Succeeded triggers. Leave blank to match any.",
				order = 5,
				hidden = function()
					local t = getTrigger(); local et = t and t.eventType
					return not (et == "AURA_GAIN" or et == "AURA_FADE" or et == "COOLDOWN_READY" or et == "SPELL_USABLE" or et == "AURA_STACKS" or et == "SPELLCAST_SUCCEEDED")
				end,
				get = function()
					local t = getTrigger()
					return (type(t) == "table" and type(t.spellId) == "number") and tostring(t.spellId) or ""
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					local sid = nil
					if type(v) == "string" and v:gsub("%s+", "") ~= "" then
						if ZSBT.ResolveSpellInputToID then
							local resolvedID = ZSBT.ResolveSpellInputToID(v)
							sid = resolvedID
						else
							sid = tonumber(v)
						end
					end
					t.spellId = (type(sid) == "number" and sid > 0) and sid or nil
					notify()
				end,
			},
			spellIdResolved = {
				type = "description",
				name = function()
					local t = getTrigger()
					local sid = t and t.spellId
					return (ZSBT.GetResolvedSpellLabel and ZSBT.GetResolvedSpellLabel(sid)) or ""
				end,
				order = 5.01,
				width = "full",
				hidden = function()
					local t = getTrigger(); local et = t and t.eventType
					if not (et == "AURA_GAIN" or et == "AURA_FADE" or et == "COOLDOWN_READY" or et == "SPELL_USABLE" or et == "AURA_STACKS" or et == "SPELLCAST_SUCCEEDED") then
						return true
					end
					return not (t and type(t.spellId) == "number")
				end,
			},
			auraSecretWarning = {
				type = "description",
				name = "Note: Some buffs/auras are hidden (\"secret\") during combat and cannot be detected reliably by SpellID. For those spells, use Spellcast Succeeded instead.",
				order = 5.02,
				width = "full",
				hidden = function()
					local t = getTrigger(); local et = t and t.eventType
					if not (et == "AURA_GAIN" or et == "AURA_FADE") then return true end
					return not (t and type(t.spellId) == "number")
				end,
			},
			convertAuraToSpellcast = {
				type = "execute",
				name = "Convert to Spellcast Succeeded",
				desc = "Switch this trigger to SPELLCAST_SUCCEEDED while keeping the SpellID and action settings.",
				order = 5.03,
				width = "full",
				hidden = function()
					local t = getTrigger(); local et = t and t.eventType
					if not (et == "AURA_GAIN" or et == "AURA_FADE") then return true end
					return not (t and type(t.spellId) == "number")
				end,
				func = function()
					local t = ensureTrigger(); if not t then return end
					t.eventType = "SPELLCAST_SUCCEEDED"
					notify()
				end,
			},
			powerType = {
				type = "select",
				name = "Power Type",
				order = 5.2,
				hidden = function()
					local t = getTrigger(); return not (t and t.eventType == "RESOURCE_THRESHOLD")
				end,
				values = {
					["MANA"] = "MANA",
					["RAGE"] = "RAGE",
					["ENERGY"] = "ENERGY",
					["FOCUS"] = "FOCUS",
					["RUNIC_POWER"] = "RUNIC_POWER",
					["FURY"] = "FURY",
					["PAIN"] = "PAIN",
				},
				get = function()
					local t = getTrigger(); return (t and t.powerType) or "RAGE"
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.powerType = v
					notify()
				end,
			},
			direction = {
				type = "select",
				name = "Direction",
				order = 5.21,
				hidden = function()
					local t = getTrigger(); return not (t and t.eventType == "RESOURCE_THRESHOLD")
				end,
				values = { ["BELOW"] = "BELOW", ["ABOVE"] = "ABOVE" },
				get = function()
					local t = getTrigger(); return (t and t.direction) or "BELOW"
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.direction = v
					notify()
				end,
			},
			thresholdValue = {
				type = "range",
				name = "Power Threshold",
				order = 5.22,
				min = 0,
				max = 200,
				step = 1,
				hidden = function()
					local t = getTrigger(); return not (t and t.eventType == "RESOURCE_THRESHOLD")
				end,
				get = function()
					local t = getTrigger(); return (t and tonumber(t.thresholdValue)) or 20
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.thresholdValue = tonumber(v) or 0
					notify()
				end,
			},
			minStacks = {
				type = "range",
				name = "Min Stacks",
				order = 5.3,
				min = 0,
				max = 50,
				step = 1,
				hidden = function()
					local t = getTrigger(); return not (t and t.eventType == "AURA_STACKS")
				end,
				get = function()
					local t = getTrigger(); return (t and tonumber(t.minStacks)) or 1
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.minStacks = tonumber(v) or 0
					notify()
				end,
			},
			maxStacks = {
				type = "range",
				name = "Max Stacks (0=off)",
				order = 5.31,
				min = 0,
				max = 50,
				step = 1,
				hidden = function()
					local t = getTrigger(); return not (t and t.eventType == "AURA_STACKS")
				end,
				get = function()
					local t = getTrigger(); return (t and tonumber(t.maxStacks)) or 0
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					local n = tonumber(v) or 0
					t.maxStacks = (n > 0) and n or nil
					notify()
				end,
			},
			onlyInCombat = {
				type = "toggle",
				name = "Only In Combat",
				desc = "For SPELL_USABLE: only check/fire while you are in combat.",
				order = 5.4,
				width = "full",
				hidden = function()
					local t = getTrigger(); return not (t and t.eventType == "SPELL_USABLE")
				end,
				get = function()
					local t = getTrigger(); return t and t.onlyInCombat ~= false
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.onlyInCombat = v and true or false
					notify()
				end,
			},
			rearmUnusableSec = {
				type = "range",
				name = "Rearm after unusable (sec)",
				desc = "For SPELL_USABLE: requires the spell to be unusable for this many seconds before it can fire again (helps prevent flicker spam). 0 = off.",
				order = 5.41,
				min = 0,
				max = 30,
				softMax = 30,
				step = 0.05,
				width = "full",
				hidden = function()
					local t = getTrigger(); return not (t and t.eventType == "SPELL_USABLE")
				end,
				get = function()
					local t = getTrigger(); return type(t) == "table" and (tonumber(t.rearmUnusableSec) or 0) or 0
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.rearmUnusableSec = tonumber(v) or 0
					notify()
				end,
			},
			throttle = {
				type = "range",
				name = "Throttle (sec)",
				desc = "Minimum time between firings for this trigger.",
				order = 6,
				min = 0,
				max = 30,
				softMax = 30,
				step = 0.05,
				get = function()
					local t = getTrigger();
					return type(t) == "table" and (tonumber(t.throttleSec) or 0) or 0
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.throttleSec = tonumber(v) or 0
					notify()
				end,
			},
			fontOverride = {
				type = "toggle",
				name = "Font Override",
				desc = "Override the font settings for this trigger's notification.",
				order = 6.1,
				width = "full",
				get = function()
					local t = getTrigger(); local a = t and t.action
					return type(a) == "table" and a.fontOverride == true
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.action = t.action or {}
					t.action.fontOverride = v and true or false
					notify()
				end,
			},
			fontFace = {
				type = "select",
				name = "Font Face",
				order = 6.11,
				values = function() return ZSBT.BuildFontDropdown() end,
				hidden = function()
					local t = getTrigger(); local a = t and t.action
					return not (type(a) == "table" and a.fontOverride == true)
				end,
				get = function()
					local t = getTrigger(); local a = t and t.action
					return (type(a) == "table" and type(a.fontFace) == "string" and a.fontFace ~= "") and a.fontFace or "Friz Quadrata TT"
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.action = t.action or {}
					t.action.fontFace = (type(v) == "string" and v ~= "") and v or nil
					notify()
				end,
			},
			fontOutline = {
				type = "select",
				name = "Outline Style",
				order = 6.12,
				values = function() return ZSBT.ValuesFromKeys(ZSBT.OUTLINE_STYLES) end,
				hidden = function()
					local t = getTrigger(); local a = t and t.action
					return not (type(a) == "table" and a.fontOverride == true)
				end,
				get = function()
					local t = getTrigger(); local a = t and t.action
					return (type(a) == "table" and type(a.fontOutline) == "string" and a.fontOutline ~= "") and a.fontOutline or "Thin"
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.action = t.action or {}
					t.action.fontOutline = (type(v) == "string" and v ~= "") and v or nil
					notify()
				end,
			},
			fontSize = {
				type = "range",
				name = "Font Size (0=use scale)",
				order = 6.13,
				min = 0,
				max = 72,
				softMax = 32,
				step = 1,
				hidden = function()
					local t = getTrigger(); local a = t and t.action
					return not (type(a) == "table" and a.fontOverride == true)
				end,
				get = function()
					local t = getTrigger(); local a = t and t.action
					return type(a) == "table" and (tonumber(a.fontSize) or 0) or 0
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.action = t.action or {}
					local n = tonumber(v) or 0
					t.action.fontSize = (n > 0) and n or nil
					notify()
				end,
			},
			fontScale = {
				type = "range",
				name = "Font Scale",
				desc = "Multiplier applied to the resolved scroll area font size when Font Size is 0.",
				order = 6.14,
				min = 0.5,
				max = 3.0,
				softMax = 2.0,
				step = 0.05,
				hidden = function()
					local t = getTrigger(); local a = t and t.action
					return not (type(a) == "table" and a.fontOverride == true)
				end,
				get = function()
					local t = getTrigger(); local a = t and t.action
					return type(a) == "table" and (tonumber(a.fontScale) or 1.0) or 1.0
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.action = t.action or {}
					t.action.fontScale = tonumber(v) or 1.0
					notify()
				end,
			},
			sticky = {
				type = "toggle",
				name = "Sticky",
				desc = "Make this trigger display like a crit (Pow-style placement) with optional scale/duration boosts.",
				order = 6.2,
				width = "full",
				get = function()
					local t = getTrigger(); local a = t and t.action
					return type(a) == "table" and a.sticky == true
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.action = t.action or {}
					t.action.sticky = v and true or false
					notify()
				end,
			},
			stickyScale = {
				type = "range",
				name = "Sticky Scale",
				order = 6.21,
				min = 1.0,
				max = 3.0,
				softMax = 2.0,
				step = 0.05,
				hidden = function()
					local t = getTrigger(); local a = t and t.action
					return not (type(a) == "table" and a.sticky == true)
				end,
				get = function()
					local t = getTrigger(); local a = t and t.action
					return type(a) == "table" and (tonumber(a.stickyScale) or 1.5) or 1.5
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.action = t.action or {}
					t.action.stickyScale = tonumber(v) or 1.5
					notify()
				end,
			},
			stickyDurationMult = {
				type = "range",
				name = "Sticky Duration Mult",
				order = 6.22,
				min = 1.0,
				max = 4.0,
				softMax = 2.0,
				step = 0.05,
				hidden = function()
					local t = getTrigger(); local a = t and t.action
					return not (type(a) == "table" and a.sticky == true)
				end,
				get = function()
					local t = getTrigger(); local a = t and t.action
					return type(a) == "table" and (tonumber(a.stickyDurationMult) or 1.5) or 1.5
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.action = t.action or {}
					t.action.stickyDurationMult = tonumber(v) or 1.5
					notify()
				end,
			},
			text = {
				type = "input",
				name = "Text",
				desc = "Trigger text (supports tokens).",
				order = 10,
				width = "full",
				get = function()
					local t = getTrigger(); local a = t and t.action
					return (type(a) == "table" and type(a.text) == "string") and a.text or ""
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.action.text = tostring(v or "")
					notify()
				end,
			},
			scrollArea = {
				type = "select",
				name = "Scroll Area",
				order = 11,
				values = function()
					local names = ZSBT.GetScrollAreaNames()
					return names
				end,
				get = function()
					local t = getTrigger(); local a = t and t.action
					return (type(a) == "table" and type(a.scrollArea) == "string" and a.scrollArea ~= "") and a.scrollArea or "Notifications"
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.action.scrollArea = (type(v) == "string" and v ~= "") and v or "Notifications"
					notify()
				end,
			},
			sound = {
				type = "select",
				name = "Sound",
				order = 12,
				values = function() return ZSBT.BuildSoundDropdown() end,
				get = function()
					local t = getTrigger(); local a = t and t.action
					return (type(a) == "table" and type(a.sound) == "string" and a.sound ~= "") and a.sound or "None"
				end,
				set = function(_, v)
					local t = ensureTrigger(); if not t then return end
					t.action.sound = (type(v) == "string" and v ~= "") and v or "None"
					notify()
				end,
			},
			color = {
				type = "color",
				name = "Color",
				order = 13,
				get = function()
					local t = getTrigger(); local a = t and t.action
					local c = type(a) == "table" and a.color
					if type(c) ~= "table" then return 1, 1, 1 end
					return tonumber(c.r) or 1, tonumber(c.g) or 1, tonumber(c.b) or 1
				end,
				set = function(_, r, g, b)
					local t = ensureTrigger(); if not t then return end
					t.action.color = { r = r, g = g, b = b }
					notify()
				end,
			},
			test = {
				type = "execute",
				name = "Test Trigger",
				desc = "Fire this trigger once using a simulated event (uses current editor settings).",
				order = 20,
				width = "full",
				func = function()
					local t = getTrigger(); if type(t) ~= "table" then return end
					local trg = ZSBT.Core and ZSBT.Core.Triggers
					if not (trg and trg.FireEvent) then return end

					local et = t.eventType or "AURA_GAIN"
					local sid = type(t.spellId) == "number" and t.spellId or nil
					local testSid = sid or 123
					local spellName = nil
					if testSid and C_Spell and C_Spell.GetSpellInfo then
						local ok, info = pcall(C_Spell.GetSpellInfo, testSid)
						spellName = ok and info and info.name or nil
					end
					spellName = spellName or (testSid and ("Spell #" .. tostring(testSid)) or nil)

					local ctx = { eventType = et, _skipThrottle = true }
					if et == "AURA_GAIN" then
						ctx.event = "GAIN"; ctx.unit = "player"; ctx.spellId = testSid; ctx.spellName = spellName or "Example Aura"; ctx.stacks = 1
					elseif et == "AURA_FADE" then
						ctx.event = "FADE"; ctx.unit = "player"; ctx.spellId = testSid; ctx.spellName = spellName or "Example Aura"; ctx.stacks = 0
					elseif et == "AURA_STACKS" then
						ctx.event = "STACKS"; ctx.unit = "player"; ctx.spellId = testSid; ctx.spellName = spellName or "Example Aura"; ctx.stacks = math.max(tonumber(t.minStacks) or 1, 5); ctx.threshold = tonumber(t.minStacks) or 1
					elseif et == "COOLDOWN_READY" then
						ctx.event = "READY"; ctx.unit = "player"; ctx.spellId = testSid; ctx.spellName = spellName or "Example Cooldown"
					elseif et == "LOW_HEALTH" then
						ctx.event = "LOW_HEALTH"; ctx.pct = 15; ctx.threshold = 30
					elseif et == "RESOURCE_THRESHOLD" then
						ctx.event = "POWER"; ctx.unit = "player"; ctx.powerType = "RAGE"; ctx.value = 80; ctx.threshold = 70
					elseif et == "SPELL_USABLE" then
						ctx.event = "USABLE"; ctx.unit = "player"; ctx.spellId = testSid; ctx.spellName = spellName or "Example Spell"
					elseif et == "SPELLCAST_SUCCEEDED" then
						ctx.event = "SUCCEEDED"; ctx.unit = "player"; ctx.spellId = testSid; ctx.spellName = spellName or "Example Spell"
					elseif et == "KILLING_BLOW" then
						ctx.event = "PARTY_KILL"; ctx.unit = "player"; ctx.value = "Training Dummy"; ctx.threshold = "Creature-0-0-0-0-0-0000000000"; ctx.spellName = "Training Dummy"
					elseif et == "ENTER_COMBAT" then
						ctx.event = "ENTER_COMBAT"; ctx.unit = "player"
					elseif et == "LEAVE_COMBAT" then
						ctx.event = "LEAVE_COMBAT"; ctx.unit = "player"
					elseif et == "TARGET_CHANGED" then
						ctx.event = "TARGET_CHANGED"; ctx.unit = "target"
					elseif et == "EQUIPMENT_CHANGED" then
						ctx.event = "EQUIPMENT_CHANGED"; ctx.unit = "player"; ctx.value = 16; ctx.threshold = 1
					elseif et == "SPEC_CHANGED" then
						ctx.event = "SPEC_CHANGED"; ctx.unit = "player"
					end

					trg:FireEvent(et, ctx)
				end,
			},
		},
	}
end

function ZSBT.BuildSpellRuleEditorOptionsTable()
	return {
		type = "group",
		name = "Spell Rule Editor",
		args = {
			header = { type = "header", name = "Edit Spell Rule", order = 1 },
			spellLabel = {
				type = "description",
				name = function()
					local id = ZSBT._editingSpellRuleSpellID
					if type(id) ~= "number" then return "No spell selected." end
					local name = (C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id) and C_Spell.GetSpellInfo(id).name) or (GetSpellInfo and GetSpellInfo(id))
					name = name or ("Spell #" .. tostring(id))
					return name .. "  |cFF888888(ID: " .. tostring(id) .. ")|r"
				end,
				order = 2,
				fontSize = "medium",
			},
			enabled = {
				type = "toggle",
				name = "Enabled",
				order = 3,
				width = "full",
				get = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					return type(r) == "table" and r.enabled ~= false
				end,
				set = function(_, v)
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.spellRules = sc.spellRules or {}
					sc.spellRules[id] = sc.spellRules[id] or {}
					sc.spellRules[id].enabled = v and true or false
				end,
			},
			throttle = {
				type = "range",
				name = "Throttle (sec)",
				desc = "Minimum time between displays for this spell (Outgoing only).",
				order = 4,
				min = 0,
				max = 2.0,
				softMax = 1.0,
				step = 0.05,
				get = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					return type(r) == "table" and (tonumber(r.throttleSec) or 0) or 0
				end,
				set = function(_, v)
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.spellRules = sc.spellRules or {}
					sc.spellRules[id] = sc.spellRules[id] or {}
					sc.spellRules[id].throttleSec = tonumber(v) or 0
				end,
			},
			scrollArea = {
				type = "select",
				name = "Scroll Area Override",
				desc = "Optional: override the default Spell Rules scroll area for this spell.",
				order = 5,
				values = function()
					local v = { ["(Default)"] = "(Default)" }
					local names = ZSBT.GetScrollAreaNames()
					for k, name in pairs(names) do v[k] = name end
					return v
				end,
				get = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					return (type(r) == "table" and type(r.scrollArea) == "string" and r.scrollArea ~= "") and r.scrollArea or "(Default)"
				end,
				set = function(_, v)
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.spellRules = sc.spellRules or {}
					sc.spellRules[id] = sc.spellRules[id] or {}
					if v == "(Default)" then
						sc.spellRules[id].scrollArea = nil
					else
						sc.spellRules[id].scrollArea = (type(v) == "string" and v ~= "") and v or nil
					end
				end,
			},
			aggHeader = {
				type = "header",
				name = "Aggregation",
				order = 6,
			},
			aggCaveat = {
				type = "description",
				name = "Note (WoW 12.x Midnight): Aggregation only applies when ZSBT receives a valid SpellID for the outgoing event. Some combat sources do not provide a SpellID (events may show as spellId=nil / no icon), and those cannot be aggregated per-spell.",
				order = 6.1,
				fontSize = "medium",
			},
			aggEnabled = {
				type = "toggle",
				name = "Enable Aggregation",
				desc = "Combine rapid repeated hits into a single line (e.g. Whirlwind shows (xN)).",
				order = 7,
				width = "full",
				hidden = function() return type(ZSBT._editingSpellRuleSpellID) ~= "number" end,
				get = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local agg = r and r.aggregate
					return type(agg) == "table" and agg.enabled == true
				end,
				set = function(_, v)
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.spellRules = sc.spellRules or {}
					sc.spellRules[id] = sc.spellRules[id] or {}
					sc.spellRules[id].aggregate = sc.spellRules[id].aggregate or {}
					sc.spellRules[id].aggregate.enabled = v and true or false
				end,
			},
			aggWindow = {
				type = "range",
				name = "Aggregation Window (sec)",
				desc = "Time window for combining hits.",
				order = 8,
				min = 0.10,
				max = 1.25,
				softMax = 0.80,
				step = 0.05,
				hidden = function() return type(ZSBT._editingSpellRuleSpellID) ~= "number" end,
				get = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local agg = r and r.aggregate
					return type(agg) == "table" and (tonumber(agg.windowSec) or 0.60) or 0.60
				end,
				set = function(_, v)
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.spellRules = sc.spellRules or {}
					sc.spellRules[id] = sc.spellRules[id] or {}
					sc.spellRules[id].aggregate = sc.spellRules[id].aggregate or {}
					sc.spellRules[id].aggregate.windowSec = tonumber(v) or 0.60
				end,
			},
			aggShowCount = {
				type = "toggle",
				name = "Show (xN) Count",
				desc = "Append a hit count marker like (x5) to aggregated events.",
				order = 9,
				width = "full",
				hidden = function() return type(ZSBT._editingSpellRuleSpellID) ~= "number" end,
				get = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local agg = r and r.aggregate
					return type(agg) ~= "table" or agg.showCount ~= false
				end,
				set = function(_, v)
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.spellRules = sc.spellRules or {}
					sc.spellRules[id] = sc.spellRules[id] or {}
					sc.spellRules[id].aggregate = sc.spellRules[id].aggregate or {}
					sc.spellRules[id].aggregate.showCount = v and true or false
				end,
			},
			similarHitsEnabled = {
				type = "toggle",
				name = "Similar Hits (xN, crits)",
				desc = "Optional: for multi-hit spells (e.g. Whirlwind), show (xN, 1 crit) on the aggregated line. Not enabled by default.",
				order = 9.1,
				width = "full",
				hidden = function() return type(ZSBT._editingSpellRuleSpellID) ~= "number" end,
				get = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local sh = r and r.similarHits
					return type(sh) == "table" and sh.enabled == true
				end,
				set = function(_, v)
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.spellRules = sc.spellRules or {}
					sc.spellRules[id] = sc.spellRules[id] or {}
					sc.spellRules[id].similarHits = sc.spellRules[id].similarHits or {}
					sc.spellRules[id].similarHits.enabled = v and true or false
				end,
			},
			styleHeader = {
				type = "header",
				name = "Style Override",
				order = 10,
			},
			styleFontOverride = {
				type = "toggle",
				name = "Font Override",
				desc = "Override font and color for this spell's outgoing text.",
				order = 11,
				width = "full",
				hidden = function() return type(ZSBT._editingSpellRuleSpellID) ~= "number" end,
				get = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local st = r and r.style
					return type(st) == "table" and st.fontOverride == true
				end,
				set = function(_, v)
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.spellRules = sc.spellRules or {}
					sc.spellRules[id] = sc.spellRules[id] or {}
					sc.spellRules[id].style = sc.spellRules[id].style or {}
					sc.spellRules[id].style.fontOverride = v and true or false
				end,
			},
			styleFontFace = {
				type = "select",
				name = "Font Face",
				order = 12,
				values = function() return ZSBT.BuildFontDropdown() end,
				hidden = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local st = r and r.style
					return not (type(st) == "table" and st.fontOverride == true)
				end,
				get = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local st = r and r.style
					return (type(st) == "table" and type(st.fontFace) == "string" and st.fontFace ~= "") and st.fontFace or "Friz Quadrata TT"
				end,
				set = function(_, v)
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.spellRules = sc.spellRules or {}
					sc.spellRules[id] = sc.spellRules[id] or {}
					sc.spellRules[id].style = sc.spellRules[id].style or {}
					sc.spellRules[id].style.fontFace = (type(v) == "string" and v ~= "") and v or nil
				end,
			},
			styleFontOutline = {
				type = "select",
				name = "Outline Style",
				order = 13,
				values = function() return ZSBT.ValuesFromKeys(ZSBT.OUTLINE_STYLES) end,
				hidden = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local st = r and r.style
					return not (type(st) == "table" and st.fontOverride == true)
				end,
				get = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local st = r and r.style
					return (type(st) == "table" and type(st.fontOutline) == "string" and st.fontOutline ~= "") and st.fontOutline or "Thin"
				end,
				set = function(_, v)
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.spellRules = sc.spellRules or {}
					sc.spellRules[id] = sc.spellRules[id] or {}
					sc.spellRules[id].style = sc.spellRules[id].style or {}
					sc.spellRules[id].style.fontOutline = (type(v) == "string" and v ~= "") and v or nil
				end,
			},
			styleFontSize = {
				type = "range",
				name = "Font Size (0=use scale)",
				order = 14,
				min = 0,
				max = 72,
				softMax = 32,
				step = 1,
				hidden = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local st = r and r.style
					return not (type(st) == "table" and st.fontOverride == true)
				end,
				get = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local st = r and r.style
					return type(st) == "table" and (tonumber(st.fontSize) or 0) or 0
				end,
				set = function(_, v)
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.spellRules = sc.spellRules or {}
					sc.spellRules[id] = sc.spellRules[id] or {}
					sc.spellRules[id].style = sc.spellRules[id].style or {}
					local n = tonumber(v) or 0
					sc.spellRules[id].style.fontSize = (n > 0) and n or nil
				end,
			},
			styleFontScale = {
				type = "range",
				name = "Font Scale",
				desc = "Multiplier applied to the resolved scroll area font size when Font Size is 0.",
				order = 15,
				min = 0.5,
				max = 3.0,
				softMax = 2.0,
				step = 0.05,
				hidden = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local st = r and r.style
					return not (type(st) == "table" and st.fontOverride == true)
				end,
				get = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local st = r and r.style
					return type(st) == "table" and (tonumber(st.fontScale) or 1.0) or 1.0
				end,
				set = function(_, v)
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.spellRules = sc.spellRules or {}
					sc.spellRules[id] = sc.spellRules[id] or {}
					sc.spellRules[id].style = sc.spellRules[id].style or {}
					sc.spellRules[id].style.fontScale = tonumber(v) or 1.0
				end,
			},
			styleColor = {
				type = "color",
				name = "Color",
				order = 16,
				hidden = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local st = r and r.style
					return not (type(st) == "table" and st.fontOverride == true)
				end,
				get = function()
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.spellRules and id and sc.spellRules[id]
					local st = r and r.style
					local c = type(st) == "table" and st.color
					if type(c) ~= "table" then return 1, 1, 1 end
					return tonumber(c.r) or 1, tonumber(c.g) or 1, tonumber(c.b) or 1
				end,
				set = function(_, r, g, b)
					local id = ZSBT._editingSpellRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.spellRules = sc.spellRules or {}
					sc.spellRules[id] = sc.spellRules[id] or {}
					sc.spellRules[id].style = sc.spellRules[id].style or {}
					sc.spellRules[id].style.color = { r = r, g = g, b = b }
				end,
			},
		},
	}
end

function ZSBT.BuildBuffRuleEditorOptionsTable()
	return {
		type = "group",
		name = "Buff Rule Editor",
		args = {
			header = { type = "header", name = "Edit Buff Rule", order = 1 },
			spellLabel = {
				type = "description",
				name = function()
					local id = ZSBT._editingBuffRuleSpellID
					if type(id) ~= "number" then return "No buff selected." end
					local name = (C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id) and C_Spell.GetSpellInfo(id).name) or (GetSpellInfo and GetSpellInfo(id))
					name = name or ("Spell #" .. tostring(id))
					return name .. "  |cFF888888(ID: " .. tostring(id) .. ")|r"
				end,
				order = 2,
				fontSize = "medium",
			},
			enabled = {
				type = "toggle",
				name = "Enabled",
				order = 3,
				width = "full",
				get = function()
					local id = ZSBT._editingBuffRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.auraRules and id and sc.auraRules[id]
					return type(r) == "table" and r.enabled ~= false
				end,
				set = function(_, v)
					local id = ZSBT._editingBuffRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.auraRules = sc.auraRules or {}
					sc.auraRules[id] = sc.auraRules[id] or {}
					sc.auraRules[id].enabled = v and true or false
				end,
			},
			hideGain = {
				type = "toggle",
				name = "Hide Gain",
				order = 4,
				width = "full",
				get = function()
					local id = ZSBT._editingBuffRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.auraRules and id and sc.auraRules[id]
					return type(r) == "table" and r.suppressGain == true
				end,
				set = function(_, v)
					local id = ZSBT._editingBuffRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.auraRules = sc.auraRules or {}
					sc.auraRules[id] = sc.auraRules[id] or {}
					sc.auraRules[id].suppressGain = v and true or false
				end,
			},
			hideFade = {
				type = "toggle",
				name = "Hide Fade",
				order = 5,
				width = "full",
				get = function()
					local id = ZSBT._editingBuffRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.auraRules and id and sc.auraRules[id]
					return type(r) == "table" and r.suppressFade == true
				end,
				set = function(_, v)
					local id = ZSBT._editingBuffRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.auraRules = sc.auraRules or {}
					sc.auraRules[id] = sc.auraRules[id] or {}
					sc.auraRules[id].suppressFade = v and true or false
				end,
			},
			throttle = {
				type = "range",
				name = "Throttle (sec)",
				desc = "Minimum time between notifications for this buff (gain/fade tracked separately).",
				order = 6,
				min = 0,
				max = 10.0,
				softMax = 2.0,
				step = 0.05,
				get = function()
					local id = ZSBT._editingBuffRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.auraRules and id and sc.auraRules[id]
					return type(r) == "table" and (tonumber(r.throttleSec) or 0) or 0
				end,
				set = function(_, v)
					local id = ZSBT._editingBuffRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.auraRules = sc.auraRules or {}
					sc.auraRules[id] = sc.auraRules[id] or {}
					sc.auraRules[id].throttleSec = tonumber(v) or 0
				end,
			},
			scrollArea = {
				type = "select",
				name = "Scroll Area Override",
				desc = "Optional: override the default Buff Rules scroll area for this buff.",
				order = 7,
				values = function()
					local v = { ["(Default)"] = "(Default)" }
					local names = ZSBT.GetScrollAreaNames()
					for k, name in pairs(names) do v[k] = name end
					return v
				end,
				get = function()
					local id = ZSBT._editingBuffRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					local r = sc and sc.auraRules and id and sc.auraRules[id]
					return (type(r) == "table" and type(r.scrollArea) == "string" and r.scrollArea ~= "") and r.scrollArea or "(Default)"
				end,
				set = function(_, v)
					local id = ZSBT._editingBuffRuleSpellID
					local sc = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl
					if not (sc and type(id) == "number") then return end
					sc.auraRules = sc.auraRules or {}
					sc.auraRules[id] = sc.auraRules[id] or {}
					if v == "(Default)" then
						sc.auraRules[id].scrollArea = nil
					else
						sc.auraRules[id].scrollArea = (type(v) == "string" and v ~= "") and v or nil
					end
				end,
			},
		},
	}
end

------------------------------------------------------------------------
-- Helper: Build font dropdown values from LibSharedMedia
-- Returns a table suitable for AceConfig select "values".
-- Uses standard select type â€” no LSM30_Font widget required.
------------------------------------------------------------------------
function ZSBT.BuildFontDropdown()
    local fonts = {}
    if LSM then
        for _, name in ipairs(LSM:List("font")) do
            fonts[name] = name
        end
    end
    -- Ensure default WoW font is always present
    if not fonts["Friz Quadrata TT"] then
        fonts["Friz Quadrata TT"] = "Friz Quadrata TT"
    end
    return fonts
end

------------------------------------------------------------------------
-- Helper: Build sound dropdown values from LibSharedMedia
-- Returns a table suitable for AceConfig select "values".
-- Uses standard select type â€” no LSM30_Sound widget required.
-- Always includes a "None" option at the top.
------------------------------------------------------------------------
function ZSBT.BuildSoundDropdown()
    local sounds = { ["None"] = "None" }
    if LSM then
        for _, name in ipairs(LSM:List("sound")) do
            sounds[name] = name
        end
    end
    return sounds
end

------------------------------------------------------------------------
-- Helper: Play an LSM sound by key name
-- Used by "Test" buttons next to sound dropdowns.
------------------------------------------------------------------------
function ZSBT.PlayLSMSound(soundKey)
    if not soundKey or soundKey == "None" then return end
    if not LSM then return end
    local path = LSM:Fetch("sound", soundKey)
    if path then
        PlaySoundFile(path, "Master")
    end
end


-- In-Game Help (Quick Reference)
-- Injected at the bottom of each config tab.
------------------------------------------------------------------------

local HELP_MD = {
	gettingStarted = [[# Getting Started

## Open the configuration
- Type `/zsbt` in chat.
- Use the tabs on the left to configure features.

## Recommended first run
- **Optional: choose a preset profile**
  - Go to `DB Profiles`.
  - Select one of the shipped preset profiles (Melee / Ranged / Tank / Healer / Pet Class).
  - If you ever want to restore a preset back to its shipped layout, use the reset buttons at the bottom of `DB Profiles`.
- **Enable the addon**
  - Go to `General`.
  - Make sure `Enabled` is on.
- **Confirm scroll areas are enabled**
  - Go to `Scroll Areas`.
  - Ensure the `Incoming`, `Outgoing`, and `Notifications` areas are enabled.
- **Unlock and place scroll areas**
  - Go to `Scroll Areas`.
  - Use the unlock/move controls (if present) to position each area where you want it.
  - Adjust `Width` / `Height` so text doesn’t clip.
- **Pick your number formatting**
  - Go to `General` -> `Numbers`.
  - Choose the Number Format you prefer (full numbers, abbreviated, etc.).
- **Pick fonts**
  - Go to `General` for the master font.
  - Optionally override fonts per scroll area in `Scroll Areas`.
- **Test**
  - Hit a target dummy or fight a mob.
  - You should see:
    - Incoming damage/heals in `Incoming`
    - Your damage/heals in `Outgoing`
    - Alerts (if enabled) in `Notifications`

## Quick setup checklist
- **Optional: pick a preset profile**
  - Go to `DB Profiles`.
  - Select a shipped preset profile.
- **Enable ZSBT**
  - Go to `General`.
  - Make sure `Enabled` is on.
- **Pick your font**
  - Go to `General`.
  - Adjust the master font (face/size/outline).
- **Place your scroll areas**
  - Go to `Scroll Areas`.
  - Move/size the `Incoming`, `Outgoing`, and `Notifications` areas.
- **Confirm you see messages**
  - Hit a target dummy or fight a mob.
  - You should see numbers in `Incoming` / `Outgoing` and alerts in `Notifications`.

## Common commands
- `/zsbt` Open configuration
- `/zsbt minimap` Toggle minimap button
- `/zsbt reset` Reset settings to defaults
- `/zsbt version` Show addon version
]],

	general = [[# General

The General tab controls core behavior that applies across the whole addon.

## Where to configure
- `/zsbt` -> `General`

## Dungeon/Raid Aware Outgoing
When enabled, ZSBT applies extra restrictions to outgoing detection while you are in dungeons and raids.

### Why this exists
In group content, some combat text feeds can become ambiguous or can look like “your” damage when it was actually done by a follower/party member.

This setting prioritizes correct attribution over completeness.

### What you may notice
- Outgoing numbers can become quieter in instances.
- Auto-attacks may be suppressed in some situations.

## Experimental fallbacks (instances)
These options only appear when `Dungeon/Raid Aware Outgoing` is enabled.

### Use Damage Meter Outgoing Fallback (Experimental)
Uses Blizzard’s damage meter totals as a last-resort outgoing source when outgoing becomes too quiet in instances.

### Use Damage Meter Incoming Damage Fallback (Experimental)
Uses Blizzard’s damage-taken totals as a last-resort incoming damage source when incoming combat text becomes ambiguous/secret in instances.

### Show Auto Attacks in Instances (Experimental)
Enables a conservative fallback for auto-attacks in restricted instance mode.

## Recommended test checklist
1. Enable `Dungeon/Raid Aware Outgoing`.
2. Do a small follower dungeon pull.
3. If outgoing is too quiet, enable `Use Damage Meter Outgoing Fallback (Experimental)` and retest.
4. If incoming damage is missing/secret, enable `Use Damage Meter Incoming Damage Fallback (Experimental)` and retest.
5. Only if swings are missing, try `Show Auto Attacks in Instances (Experimental)`.

## Open-World Tuning
These settings change how ZSBT attributes outgoing events in open world and edge cases.

### Quiet Outgoing When Idle
Suppress outgoing numbers from ambiguous attribution sources unless they can be correlated to your own casts/periodic effects.

### Allow Auto Attacks While Quiet
Optional companion toggle for melee classes. Re-enables a conservative auto-attack fallback while quiet mode is enabled.
]],

	quickControlBar = [[# Quick Control Bar

The Quick Control Bar is an optional on-screen widget that lets you toggle common tuning settings without opening the full configuration UI.

## Enable
- `/zsbt` -> `General` -> `Enable Quick Control Bar`

## How to use
- Drag the bar to position it anywhere on your screen.
- `Instance` opens a menu for Dungeon/Raid tuning toggles.
- `Open World` opens a menu for Open-World tuning toggles.
- `PvP` opens a menu for PvP tuning toggles.
- `Unlock/Lock` toggles scroll area unlock mode for quick positioning.
]],

	combatLogSettings = [[# Combat Log Settings (Required for Fallback Detection)

ZSBT primarily uses secure combat text signals (Combat Log events and Blizzard combat text feeds).

However, some of ZSBT’s **fallback detection** relies on **combat messages being generated** so the addon can listen to them via chat combat events.

If your Combat Log filters are too restrictive, you may see issues like:
- Missing outgoing spell hits / ticks in some situations
- Missing periodic damage (DoTs) in edge cases
- Missing kill-credit / death messages used by fallback logic

## What you need to enable (high level)
You must make sure these are enabled in Combat Log filtering:
- **My Actions**
- **What happened to me**

And within those, ensure these categories are enabled:
- **Damage**
- **Healing**
- **Misses** (optional, but recommended)
- **Deaths** / **Killing blows** (recommended)

## Step-by-step (click-by-click)
1. **Open your Combat Log window**
   - Open chat.
   - If you don’t have a Combat Log tab, create a new chat tab and set it to Combat Log.

2. **Open Combat Log settings**
   - Right-click your chat tab name.
   - Click `Settings` (or `Chat Settings`).
   - Go to the `Combat Log` section.

3. **Open the Combat Log "Filters" / "What to Log" panel**
   - Look for a button like `Filters`, `What to Log`, or `Configure`.

4. **Enable the two required filter presets**
   - Enable:
     - `My Actions`
     - `What happened to me`

5. **Inside each preset, enable the categories ZSBT needs**
   In BOTH `My Actions` and `What happened to me`, make sure these are enabled:
   - `Damage`
   - `Spell damage`
   - `Periodic damage`
   - `Melee / swings`
   - `Healing` (including periodic heals)

6. **Recommended extras (more reliable fallbacks)**
   In BOTH presets, also enable:
   - `Misses` (dodge/parry/block/resist/immune)
   - `Deaths` / `Killing blows`

7. **Reload UI**
   - Type `/reload`

## Notes
- ZSBT can still run with restrictive logs, but you may lose some fallback coverage.
- If you use other combat log addons, avoid disabling these categories globally.

## Quick verification
- Attack a target dummy for 10 seconds.
- You should see:
  - Outgoing hits
  - DoT ticks (if you apply one)
  - Crits (if you crit)

If you still see missing outgoing events after enabling these, check:
- `General` -> master enable
- `Outgoing` -> enable outgoing damage
- `Spam Control` -> thresholds (min threshold not too high)
]],

	scrollAreas = [[# Scroll Areas

Scroll areas control where text appears on your screen and how it animates.

## Where to configure
- `/zsbt` -> `Scroll Areas`

## The default areas
- **Notifications**
  - Used for alerts (cooldowns ready, warnings, triggers, UT announcements).
- **Outgoing**
  - Your damage/healing.
- **Incoming**
  - Damage/healing you receive.

## How to position an area
- Select the scroll area by name.
- Adjust:
  - `Anchor`
  - `X Offset`
  - `Y Offset`
  - `Width` / `Height`

## Animation settings
Each scroll area has its own animation settings.

- **Animation Type**
  - Options include `Parabola`, `Fireworks`, `Waterfall`, `Straight`, `Static`.
- **Direction / Justify**
  - Controls movement direction and text alignment.
- **Duration / Fade / Scale / Arc**
  - Controls how long and how dramatic the animation is.

## Font per scroll area
Each area can use the global font or a per-area font.

- Set `Use Global` (if available) to use the font from `General`.
- Otherwise set a custom:
  - `Font Face`
  - `Font Size`
  - `Font Outline`

## Troubleshooting
- **Text appears but overlaps too much**
  - Reduce `Max Messages`.
  - Increase `Height`.
  - Increase animation duration slightly.
- **Text is clipped**
  - Increase `Width` and/or `Height`.
- **Notifications feel too small**
  - Increase the `Notifications` area font size.

## Testing
- Use `Test Selected` to fire regular test events into the selected scroll area.
- Use `Test Crit` to fire crit-style test events. This also fires incoming heal/damage crit tests using your `Incoming` crit routing overrides.
]],

	incoming = [[# Incoming

Incoming controls what you see when you take damage or receive healing.

## Where to configure
- `/zsbt` -> `Incoming`

## Incoming damage
- **Enable/disable** incoming damage.
- Choose the `Scroll Area` (usually `Incoming`).
- Set a `Min Threshold` to hide small hits.
- Toggle whether to show `Misses`.

## Incoming healing
- **Enable/disable** incoming healing.
- Choose the `Scroll Area`.
- Toggle whether to show `Overheal`.
- Set a `Min Threshold`.

## Crit routing
- Incoming damage crits: `Incoming` -> `Incoming Damage` -> `Incoming Crit Damage`.
- Incoming healing crits: `Incoming` -> `Incoming Healing` -> `Incoming Crit Heals`.

## Tips
- If you’re in a raid and see too much spam, increase `Min Threshold` and enable merging in `Spam Control`.
- If you only want to see big hits, set `Min Threshold` higher.
]],

	outgoing = [[# Outgoing

Outgoing controls what you see when you deal damage or healing.

## Where to configure
- `/zsbt` -> `Outgoing`

## Step-by-step setup
- **Pick a scroll area**
  - Set `Outgoing Damage` -> `Scroll Area` to your `Outgoing` scroll area.
  - Set `Outgoing Healing` -> `Scroll Area` to where you want heals (often also `Outgoing`).
- **Set thresholds**
  - Start with a low `Min Threshold` so you can confirm everything works.
  - Raise it later if you want to hide small hits/ticks.
- **Decide how to show crits**
  - If you like crit emphasis, enable crits and use sticky crit styling.
  - If you route crits to a separate scroll area, you can also configure a dedicated crit color.
- **Decide how to handle auto attacks**
  - If white swings clutter your view, reduce or disable auto attack display (or raise thresholds).

## Outgoing damage
- **Enable/disable** outgoing damage.
- Choose the `Scroll Area` (usually `Outgoing`).
- Set `Min Threshold` to hide small hits.
- Configure `Auto Attack` display behavior.
- Toggle whether to show `Misses`.

## Outgoing healing
- **Enable/disable** outgoing healing.
- Choose the `Scroll Area`.
- Toggle whether to show `Overheal`.
- Set `Min Threshold`.

## Crits
- Crits can be enabled separately.
- If you want crits to stand out, use sticky crit styling.

## Spell names and icons
- `Show Spell Names` shows the ability name (when available).
- `Show Spell Icons` shows an icon (when safe).

## Periodic damage (DoTs)
- Periodic effects (DoTs) should appear as outgoing damage ticks.
- Depending on the available 12.x-safe signals, periodic ticks may be strongest/reliably detected for your current `target`.

## Tips
- For a cleaner look:
  - Disable spell names.
  - Keep icons on.
  - Enable merging in `Spam Control`.

## Group/instance note
- If you have a “dungeon/raid aware outgoing” restriction enabled, outgoing fallback signals can be limited in instanced content to avoid mis-attributing group activity to you.
]],

	pets = [[# Pets

Pets controls how pet/guardian damage is displayed.

## Where to configure
- `/zsbt` -> `Pets`

## Options
- **Outgoing Pet Damage**: damage dealt by your pet/guardian (routing, threshold, colors).
- **Incoming Pet Healing**: healing done to your pet (optional routing + threshold + colors).
- **Incoming Pet Damage**: damage taken by your pet (optional routing + threshold + colors).
- **Aggregation**: how outgoing pet hits are labeled.
- **Merge Window** / **Show Count**: controls how multiple outgoing pet hits are merged.

## Tips
- If pet spam is overwhelming, raise `Min Threshold` and use a larger merge window.
]],

	spamControl = [[# Spam Control

Spam Control helps reduce noise by merging rapid hits and applying thresholds.

## Where to configure
- `/zsbt` -> `Spam Control`

## Merging (AoE condensing)
- Enable merging to combine multiple rapid hits into one line.
- Adjust the merge `Window` to control how long hits are collected.
- Enable `Show Count` to display “(xN)” style counts.

## Throttling / thresholds
- Use minimum thresholds to hide small damage/heals.
- Use auto-attack suppression thresholds if available.

## Routing defaults
- Choose default scroll areas for new spell/aura rules.

## Spell Rules (Per-Spell)
Spell Rules let you add **per-spell throttles** for outgoing combat text.

- **What Spell Rules affect**
  - Outgoing damage/healing display (not Notifications).
- **What Spell Rules do**
  - Apply an additional, per-spell throttle window so that repeated events from the same spell don’t spam the scroll area.
- **Where to configure**
  - `/zsbt` -> `Spam Control` -> `Open Spell Rules Manager`

### How to add a spell rule
- Enter a **SpellID** (or exact spell name) and click `Add`.
- Then click `Edit` on the rule to adjust settings (enabled, throttle).

### Recently Seen Spells
The Spell Rules Manager includes **Recently Seen Spells**:
- Attack a target for a few seconds.
- Click `Refresh Recent Spells`.
- Use this list to discover SpellIDs you may want to add rules for.

### Spell Rules examples
- **Example: Reduce spam from a frequent proc/hit**
  - Add a rule for the proc spell.
  - Set throttle to something like `0.20` to `0.60` seconds.
- **Example: Keep big cooldowns “instant”**
  - Do not add spell rules to major cooldown hits.
  - Or keep throttle very low.

## Buff Rules (Notifications)
Buff Rules let you control which **buff gain/fade notifications** you see.

- **What Buff Rules affect**
  - Notifications for your own auras/procs (gain/fade).
- **What Buff Rules do**
  - Allow you to:
    - enable/disable a buff’s notifications
    - suppress Gain and/or Fade independently
    - add a per-buff throttle (spam control)
- **Where to configure**
  - `/zsbt` -> `Spam Control` -> `Open Buff Rules Manager`

### “Whitelist mode” (only show configured buffs)
The Spam Control tab has toggles that control whether **unconfigured** buffs are allowed:
- If you disable showing gains/fades without rules, only buffs with a Buff Rule will display.

### Recently Seen Buffs
The Buff Rules Manager includes **Recently Seen Buffs**:
- Trigger a proc or gain buffs.
- Click `Refresh Recent Buffs`.
- Use this list to discover spellIDs to add rules for.

### Templates
The Buff Rules Manager includes merge-only class templates:
- `Apply Class Templates (Merge Only)` adds useful rules without overwriting your custom rules.
- `Include All Specs` is recommended if you play multiple specs.

### Buff Rules examples
- **Example: Hide a noisy proc’s fade**
  - Add the proc as a Buff Rule.
  - Enable it.
  - Set `Suppress Fade` on.
- **Example: Keep only important cooldown buffs**
  - Disable “Show Buff Gains Without Rules” and “Show Buff Fades Without Rules”.
  - Add rules only for the buffs you care about (major cooldowns, trinket procs, defensives).
- **Example: Stop spam from stacking buffs**
  - Add a Buff Rule.
  - Set a small throttle like `1.0` to `3.0` seconds.

## Tips
- If big pulls create unreadable spam:
  - Enable merging
  - Increase merge window slightly
  - Raise min thresholds
]],

	triggers = [[# Triggers

Triggers let you create your own notifications when specific events happen.

## Where to configure
- `/zsbt` -> `Triggers`

## Enable triggers
- Turn on `Enable Triggers`.

## How triggers work (mental model)
- A trigger has:
  - **Event Type**: what kind of thing you’re watching for.
  - **Optional Spell ID filter**: for event types that represent a specific spell/aura/cooldown.
  - **Throttle**: minimum time between firings for that trigger.
  - **Action**: what to show/play when it fires (text, scroll area, sound, color, sticky).

## Event Types (what each one means)

### Aura-based
- **AURA_GAIN**
  - Fires when you gain the configured aura (buff or debuff) on yourself.
  - Requires `Spell ID`.
- **AURA_FADE**
  - Fires when the configured aura fades from you.
  - Requires `Spell ID`.
- **AURA_STACKS**
  - Fires when the configured aura stack count changes.
  - Requires `Spell ID`.

### Cooldown/spell-based
- **COOLDOWN_READY**
  - Fires when a tracked cooldown becomes ready.
  - Requires `Spell ID`.
- **SPELL_USABLE**
  - Fires when a spell becomes usable.
  - Typically requires `Spell ID`.
- **SPELLCAST_SUCCEEDED**
  - Fires when the player (or pet) successfully casts a spell.
  - Requires `Spell ID`.

### Combat state / general
- **ENTER_COMBAT**
  - Fires when you enter combat.
- **LEAVE_COMBAT**
  - Fires when you leave combat.
- **TARGET_CHANGED**
  - Fires when your target changes.
- **EQUIPMENT_CHANGED**
  - Fires when an equipment slot changes.
- **SPEC_CHANGED**
  - Fires when your spec changes.

### Warnings / thresholds
- **LOW_HEALTH**
  - Fires when low-health warning logic triggers.
- **RESOURCE_THRESHOLD**
  - Fires when a configured resource threshold is crossed.

### Kill / UT-style
- **KILLING_BLOW**
  - Fires when you get a killing blow.
- **UT_KILL_1** through **UT_KILL_7**
  - UT announcer tier events.
  - Install the preset UT triggers via the `Setup UT Announcer Triggers` button.

## Add a trigger
- Click `Add Trigger`.
- Configure:
  - **Event Type** (what kind of event fires the trigger)
  - **Spell ID** (if the event is tied to a specific spell)
  - **Throttle** (minimum time between repeated firings)

## Action (what happens when it fires)
- **Text**: what to display.
- **Scroll Area**: usually `Notifications`.
- **Sound**: choose from the sound dropdown.
- **Color**: set the message color.
- **Sticky**: make it pop like a crit.
- **Font Override**: choose a specific font/outline for this trigger.

## Text placeholders
- **`{spell}`**: resolved spell/aura name (when available)
- **`{id}`**: spell ID
- **`{event}`**: event label (GAIN/FADE/READY/etc.)
- **`{pct}`**: percent value (used by low health)
- **`{threshold}`**: threshold value (used by low health / resource threshold / equipment)
- **`{unit}`**: unit name/id (when available)
- **`{power}`**: power type (for resource threshold)
- **`{value}`**: value payload (slot id, killed unit name, etc.)
- **`{stacks}`**: aura stacks
- **`{count}`**: generic count field (if provided)
- **`{label}`**: generic label field (if provided)

## Throttle (anti-spam)
- Throttle is per-trigger.
- If a trigger could fire rapidly, set a throttle like `0.5` to `2.0` seconds.
]],

	cooldowns = [[# Cooldowns

Cooldowns shows alerts when tracked cooldowns become ready.

## Where to configure
- `/zsbt` -> `Cooldowns`

## Enable cooldown tracking
- Turn `Enabled` on.

## Add tracked cooldowns
- Add spells to the tracked list (spell IDs) in the cooldowns UI.

## Output
- **Scroll Area**: where the alert appears (usually `Notifications`).
- **Format**: the message format (for example: `%s Ready!`).
- **Sound**: select a sound to play.

## Tips
- Use a distinct sound for cooldown ready so it’s easy to notice.
- Keep cooldown alerts in `Notifications` rather than `Incoming/Outgoing`.
]],

	media = [[# Media

Media controls sound events and custom media registration.

## Where to configure
- `/zsbt` -> `Media`

## Sound events
- Choose sounds for built-in events like:
  - Low Health Warning
  - Cooldown Ready

## Custom media
If you have your own font or sound file, you can register it in the `Custom Media` section.

### Step-by-step: add a custom font
1. **Get a font file**
   - Format: `.ttf`
2. **Put the file in the ZSBT fonts folder**
   - Copy your font file to:
     - `World of Warcraft\_retail_\Interface\AddOns\ZSBT\Media\Fonts\`
   - Example:
     - `...\ZSBT\Media\Fonts\MyFont.ttf`
3. **Open the Media tab**
   - Type `/zsbt`
   - Click `Media`
4. **Register the font in ZSBT**
   - Find the `Custom Media` section.
   - Fill in:
     - `Custom Font Name`
     - `Font Filename` (no extension)
   - Click `Add Font`.
5. **Use the font**
   - Go to `General` or `Scroll Areas`.

### Step-by-step: add a custom sound
1. **Get a sound file**
   - Format: `.ogg`
2. **Put the file in the ZSBT sounds folder**
   - Copy your sound file to:
     - `World of Warcraft\_retail_\Interface\AddOns\ZSBT\Media\Sounds\`
3. **Open the Media tab**
4. **Register the sound in ZSBT**
   - Fill in:
     - `Custom Sound Name`
     - `Sound Filename` (no extension)
   - Click `Add Sound`.
5. **Test the sound**
   - Pick your sound and click `Play Sound`.

## Customize the announcements

- `/zsbt` -> `Triggers`
	]],

	diagnostics = [[# Diagnostics

Diagnostics controls debug logging.

## Where to configure
- `/zsbt` -> `Diagnostics`

## Debug level
- Use a higher debug level only when troubleshooting.
- Higher values produce more chat/log spam.

## Recommended bug report flow
- Set debug level high.
- Reproduce the issue once.
- Copy/paste the relevant `ZSBT:` lines.
- Set debug level back to `0`.

## Helpful commands
- `/zsbt debug 0-4` Set debug level

## Tips
- Reset debug level back to `0` after troubleshooting.
]],

	notifications = [[# Notifications

Notifications controls what kinds of alerts are allowed to appear in your Notifications scroll area.

## Where to configure
- `/zsbt` -> `Notifications`

## Loot Alerts
Loot is split into three categories:
- Loot Items
- Loot Money (gold/silver/copper)
- Loot Currency (tokens/currencies)

Loot templates and loot filtering are configured under:
- `/zsbt` -> `Notifications` -> `Loot Alerts`

## Trade Skill Alerts
Trade skills are split into two categories:
- Trade Skills: Skill Ups
- Trade Skills: Learned Recipes/Spells

Trade skill templates are configured under:
- `/zsbt` -> `Notifications` -> `Trade Skill Alerts`

### How to use Loot Alerts

#### 1) Turn on the category (and choose where it goes)
- Go to `/zsbt` -> `Notifications`.
- Enable any of:
  - `Loot Items`
  - `Loot Money`
  - `Loot Currency`
- Use the `Route To` dropdown next to each category to choose which scroll area receives that alert.

#### 2) Customize the message template
- Go to `/zsbt` -> `Notifications` -> `Loot Alerts`.
- Each loot type has its own template.

Template codes:
- `%e` The thing you gained (item link / money string / currency link)
- `%a` Amount gained
- `%t` Total owned (your new total)

For Trade Skills:
- `%e` Skill name (Skill Ups) or learned recipe/spell link/name (Learned)
- `%a` Amount gained (Skill Ups)
- `%t` New level (Skill Ups)

Examples:
- `+%a %e (%t)` (MSBT-style)
- `+%e x%a` (simple)
- `+%e` (minimal)

#### 3) Configure loot filtering (items only)
Loot filters apply to Loot Items.

- `Show Created/Pushed Items`
  - Off: hides items produced by crafting/creation messages.
  - On: shows them.
- `Always Show Quest Items`
  - If enabled, quest items are shown even if they would normally be hidden by quality or exclusion filters.
- `Quality Exclusions`
  - Hide loot of selected qualities.
- `Items Excluded (one per line)`
  - Hide items by name (one per line).
- `Items Allowed (one per line)`
  - Allow-list always wins: if an item is listed here, it will be shown even if excluded by quality or name.

## What belongs in Notifications
Notifications is intended for short, high-signal messages like:
- Cooldowns ready
- Procs / reactive abilities
- Buff/debuff gain or fade messages
- Loot / money / reputation / honor progress
- Warnings (low health, low mana)
- UT announcer events
- Custom Triggers

## Step-by-step setup
- Ensure you have a Notifications scroll area
- Enable the categories you care about
- Route to the right scroll area
  - For most notification categories (combat state, progress, loot items/money/currency, auras, power full), use the `Route To` selector in the `Notifications` tab.
  - Cooldown ready routing is configured in the `Cooldowns` tab.
  - Custom trigger routing is configured per-trigger in the `Triggers` tab.

## Tips
- If notifications are too noisy, disable categories you don’t care about.
- If notifications are hard to read, increase font size and height.
]],

	troubleshooting = [[# Troubleshooting

If something feels “off”, start here.

## Quick checklist (30 seconds)
- Confirm the addon is enabled: `/zsbt` -> `General` -> `Enabled`
- Confirm you have at least one visible scroll area enabled: `/zsbt` -> `Scroll Areas`
- If `Combat Only` is enabled, you will see very little out of combat
- Lower thresholds temporarily to confirm output is working
- Type `/reload`

Use the topics below for more specific fixes.
]],

	troubleshooting_nothing = [[# Nothing Shows

If ZSBT is enabled but you see nothing:

## 1) Enable ZSBT
- `/zsbt` -> `General` -> `Enabled`

## 2) Enable a scroll area
- `/zsbt` -> `Scroll Areas`
- Ensure at least one visible area is enabled:
  - `Incoming`
  - `Outgoing`
  - `Notifications`

## 3) Combat-only settings
- If `Combat Only` is enabled, test while in combat.

## 4) Thresholds
- If minimum thresholds are too high, smaller events are hidden.
- Temporarily lower thresholds to confirm output is working.

## 5) Reload
- `/reload`
]],

	troubleshooting_icons = [[# Icons/Names

ZSBT tries to show spell icons and spell names only when it can do so reliably.

## Check options
- Make sure `Show Spell Icons` and/or `Show Spell Names` are enabled.

## Instance/group content note
- In dungeons and raids, some combat signals can be more ambiguous.
- You may see fewer icons/names because ZSBT prefers correctness over guessing.

## If something is consistently wrong
- If the same spell is consistently wrong and you can reproduce it, report it (see Bug Report).
]],

	troubleshooting_spam = [[# Spam

If ZSBT is working but it’s too noisy:

## Spam Control
- `/zsbt` -> `Spam Control`
- Enable merging to condense rapid hits.
- Raise thresholds gradually until only meaningful events show.

## Scroll Areas
- Reduce `Max Messages` (if present).
- Increase the scroll area `Height` so lines have room.
]],

	troubleshooting_triggers = [[# Triggers/Cooldowns

If a trigger or cooldown alert doesn’t fire, it’s usually one of these:

## Feature disabled
- Ensure the Triggers/Cooldowns system is enabled.
- Ensure the specific trigger/cooldown entry is enabled.

## Routed to the wrong place
- Route alerts to a visible scroll area (usually `Notifications`).

## Wrong SpellID
- Verify the spell ID and test with a known ability.

## Event expectations
- Some trigger types fire only on a state change (example: “became usable”).
]],

	troubleshooting_media = [[# Custom Media

If custom fonts or sounds don’t appear in dropdowns:

## Reload is required
- `/reload`

## Fonts
- Format: `.ttf`
- Folder: `Media/Fonts/`
- When registering, use the filename without extension.

## Sounds
- Format: `.ogg`
- Folder: `Media/Sounds/`
- When registering, use the filename without extension.
]],

	troubleshooting_blizzardCombatText = [[# Blizzard Combat Text

## Incoming heals/damage showing from Blizzard
If you see Blizzard combat text (for example, incoming heals) while ZSBT is enabled:

- Enable `/zsbt` -> `General` -> `Suppress All Blizzard Combat Text`.
- If you prefer Blizzard outgoing numbers above enemy heads, enable `/zsbt` -> `Outgoing` -> `Turn off ZSBT outgoing and use Blizzard FCT`.

## Useful command
- `/zsbt dumpcvars` prints the relevant Blizzard combat text CVars and defaults.

## XP/world text size is too small
If you previously changed CVars to reduce XP/progress spam and your world text now looks too small:

- Run `/zsbt dumpcvars` and check the "World / XP text scale CVars" section.
- Restore the relevant CVar to its default value (shown in the dump output).
]],

	troubleshooting_limits = [[# Limits (Expected)

These are common reports that can be expected behavior depending on settings and what signals WoW provides:

## Fewer icons/names in group content
- Some signals do not include a reliable spell ID.
- ZSBT will omit icons/names rather than display the wrong spell.

## Outgoing can be quieter in instances
- If `Dungeon/Raid Aware Outgoing` is enabled, ZSBT may suppress uncertain attribution.
- This reduces false positives in group content.

## PvP can be quieter (or missing swings)
- If PvP Strict Mode is enabled, ZSBT tightens attribution in battlegrounds/arenas.
- If you are missing swings while PvP Strict Mode is enabled, try disabling `Disable Auto-Attack Fallback (PvP)`.

## Defaults and migration
- On upgrade, ZSBT only applies new defaults to existing profiles when a setting is missing (unset/nil).
- ZSBT does not overwrite explicit user choices.

## What to try
- If outgoing is too quiet in an instance, review `General` -> instance tuning (and any experimental fallbacks).

## Config window size
- ZSBT uses a default window size only when no saved window size exists.
]],

	troubleshooting_bug = [[# Bug Report

If you think you found a real bug, these details help the most:

## Include
- What you expected vs what happened.
- Open world vs dungeon/raid.
- The specific spell/ability (and SpellID if possible).
- Repro steps.

## Diagnostics (recommended)
- Raise debug level.
- Reproduce the issue once.
- Copy/paste the relevant `ZSBT:` lines.
- Set debug level back to `0`.
]],

	utAnnouncer = [[# UT Announcer

UT Announcer is an Unreal Tournament–style multi-kill announcer implemented as Triggers.

## Where to configure
- `/zsbt` -> `Alerts` -> `Triggers`

## Enable / install the presets
- Click `Setup UT Announcer Triggers`.
- This is merge-only (it adds missing UT_KILL triggers but does not overwrite your edits).

## Output
- **Channel**: where the announcement appears (party/raid).
- **Format**: the message format (for example: `%s Ready!`).
- **Sound**: select a sound to play.

## Tips
- Use a distinct sound for UT Announcer so it’s easy to notice.
- Keep UT Announcer events in a visible scroll area (usually `Notifications`).
]],

}

local HELP_TOPICS = {
	gettingStarted = { name = "Getting Started", docKey = "gettingStarted" },
	general = { name = "General", docKey = "general" },
	quickControlBar = { name = "Quick Control Bar", docKey = "quickControlBar" },
	combatLogSettings = { name = "Combat Log Settings", docKey = "combatLogSettings" },
	dbProfiles = {
		name = "DB Profiles (Presets)",
		text =
			"Profiles are saved configurations.\n\n" ..
			"Shipped preset profiles\n" ..
			"- ZSBT - Preset: Melee\n" ..
			"- ZSBT - Preset: Ranged\n" ..
			"- ZSBT - Preset: Tank\n" ..
			"- ZSBT - Preset: Healer\n" ..
			"- ZSBT - Preset: Pet Class\n\n" ..
			"Reset preset buttons (bottom of DB Profiles)\n" ..
			"- Resets the preset profile back to the shipped layout.\n" ..
			"- Does NOT switch your currently selected profile.",
	},
	scrollAreas = { name = "Scroll Areas", docKey = "scrollAreas" },
	incoming = { name = "Incoming", docKey = "incoming" },
	outgoing = { name = "Outgoing", docKey = "outgoing" },
	pets = { name = "Pets", docKey = "pets" },
	spamControl = { name = "Spam Control", docKey = "spamControl" },
	triggers = { name = "Triggers", docKey = "triggers" },
	cooldowns = { name = "Cooldowns", docKey = "cooldowns" },
	notifications = { name = "Notifications", docKey = "notifications" },
	media = { name = "Media", docKey = "media" },
	utAnnouncer = { name = "UT Announcer", docKey = "utAnnouncer" },
	diagnostics = { name = "Diagnostics", docKey = "diagnostics" },
	troubleshooting = {
		name = "Troubleshooting",
		docKey = "troubleshooting",
		children = {
			"troubleshooting_nothing",
			"troubleshooting_icons",
			"troubleshooting_spam",
			"troubleshooting_triggers",
			"troubleshooting_media",
			"troubleshooting_blizzardCombatText",
			"troubleshooting_limits",
			"troubleshooting_bug",
		},
	},
	troubleshooting_nothing = { name = "Nothing Shows", docKey = "troubleshooting_nothing" },
	troubleshooting_icons = { name = "Icons/Names", docKey = "troubleshooting_icons" },
	troubleshooting_spam = { name = "Spam", docKey = "troubleshooting_spam" },
	troubleshooting_triggers = { name = "Triggers/Cooldowns", docKey = "troubleshooting_triggers" },
	troubleshooting_media = { name = "Custom Media", docKey = "troubleshooting_media" },
	troubleshooting_blizzardCombatText = { name = "Blizzard Combat Text", docKey = "troubleshooting_blizzardCombatText" },
	troubleshooting_limits = { name = "Limits", docKey = "troubleshooting_limits" },
	troubleshooting_bug = { name = "Bug Report", docKey = "troubleshooting_bug" },
}

local HELP_ORDER = {
	"gettingStarted",
	"general",
	"quickControlBar",
	"combatLogSettings",
	"dbProfiles",
	"scrollAreas",
	"incoming",
	"outgoing",
	"pets",
	"spamControl",
	"triggers",
	"cooldowns",
	"notifications",
	"media",
	"utAnnouncer",
	"diagnostics",
}

local TROUBLESHOOTING_ORDER = {
	"troubleshooting",
}

local function prettyPrintMarkdown(md)
	if type(md) ~= "string" then return "" end
	local s = md:gsub("\r\n", "\n")
	s = s:gsub("\n\n\n+", "\n\n")
	-- Headers
	s = s:gsub("^#%s+", "")
	s = s:gsub("\n#%s+", "\n")
	s = s:gsub("\n##%s+", "\n\n")
	-- Links: [Text](Target) -> Text (Target)
	s = s:gsub("%[([^%]]+)%]%(([^%)]+)%)", "%1 (%2)")
	-- Bold / emphasis markers
	s = s:gsub("%*%*", "")
	s = s:gsub("%*", "")
	-- Bullets: keep simple dash bullets, but normalize indentation
	s = s:gsub("\n%- ", "\n- ")
	s = s:gsub("\n%-%-%-+\n", "\n")
	-- Inline code markers
	s = s:gsub("`", "")
	-- Collapse excessive whitespace again after transforms
	s = s:gsub("\n\n\n+", "\n\n")
	return s
end


local helpPopup
local helpPopupEdit
local helpPopupTitle
local helpPopupTitleBar
local helpPopupScroll

local function ensureHelpState()
	if not ZSBT.db or not ZSBT.db.char then return nil end
	ZSBT.db.char.ui = ZSBT.db.char.ui or {}
	ZSBT.db.char.ui.help = ZSBT.db.char.ui.help or {}
	if ZSBT.db.char.ui.help.expanded == nil then
		ZSBT.db.char.ui.help.expanded = false
	end
	if type(ZSBT.db.char.ui.help.selected) ~= "string" or ZSBT.db.char.ui.help.selected == "" then
		ZSBT.db.char.ui.help.selected = "gettingStarted"
	end
	return ZSBT.db.char.ui.help
end

local function ensureHelpPopup()
	if helpPopup and helpPopup:IsShown() then
		return helpPopup
	end
	if not helpPopup then
		helpPopup = CreateFrame("Frame", "ZSBT_HelpPopup", UIParent, "BackdropTemplate")
		helpPopup:SetSize(720, 520)
		helpPopup:SetPoint("CENTER")
		helpPopup:SetResizable(true)
		if helpPopup.SetResizeBounds then
			helpPopup:SetResizeBounds(520, 360)
		end
		helpPopup:SetMovable(true)
		helpPopup:EnableMouse(true)
		helpPopup:RegisterForDrag("LeftButton")
		helpPopup:SetScript("OnDragStart", function(self) self:StartMoving() end)
		helpPopup:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

		local dk = ZSBT and ZSBT.COLORS and ZSBT.COLORS.DARK or { r = 0.08, g = 0.09, b = 0.10 }
		local border = ZSBT and ZSBT.COLORS and ZSBT.COLORS.BORDER or { r = 0.2, g = 0.2, b = 0.2 }
		helpPopup:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Buttons\\WHITE8X8",
			edgeSize = 1,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		helpPopup:SetBackdropColor(dk.r, dk.g, dk.b, 0.98)
		helpPopup:SetBackdropBorderColor(border.r, border.g, border.b, 0.6)

		local titleBar = CreateFrame("Frame", nil, helpPopup, "BackdropTemplate")
		titleBar:SetPoint("TOPLEFT", 6, -6)
		titleBar:SetPoint("TOPRIGHT", -6, -6)
		titleBar:SetHeight(28)
		titleBar:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Buttons\\WHITE8X8",
			edgeSize = 1,
			insets = { left = 2, right = 2, top = 2, bottom = 2 },
		})
		local dm = ZSBT and ZSBT.COLORS and ZSBT.COLORS.DARK_MID or { r = 0.10, g = 0.11, b = 0.12 }
		local accent = ZSBT and ZSBT.COLORS and ZSBT.COLORS.ACCENT or border
		titleBar:SetBackdropColor(dm.r, dm.g, dm.b, 0.90)
		titleBar:SetBackdropBorderColor(accent.r, accent.g, accent.b, 0.6)
		helpPopupTitleBar = titleBar

		local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		title:SetPoint("LEFT", 10, 0)
		title:SetJustifyH("LEFT")
		if accent then
			title:SetTextColor(accent.r, accent.g, accent.b, 1.0)
		end
		helpPopupTitle = title

		local close = CreateFrame("Button", nil, helpPopup, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -6, -6)

		local scroll = CreateFrame("ScrollFrame", nil, helpPopup, "UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 12, -42)
		scroll:SetPoint("BOTTOMRIGHT", -32, 12)
		helpPopupScroll = scroll

		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetAutoFocus(false)
		edit:EnableMouse(true)
		edit:SetFontObject(ChatFontNormal)
		edit:SetWidth(660)
		edit:SetTextColor(1, 1, 1, 1)
		edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
		edit:SetScript("OnTextChanged", function(self) scroll:UpdateScrollChildRect() end)

		scroll:SetScrollChild(edit)
		helpPopupEdit = edit

		local grip = CreateFrame("Button", nil, helpPopup)
		grip:SetPoint("BOTTOMRIGHT", -4, 4)
		grip:SetSize(18, 18)
		grip:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
		local tex = grip:CreateTexture(nil, "OVERLAY")
		tex:SetAllPoints(grip)
		tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
		grip.tex = tex
		grip:SetScript("OnMouseDown", function(_, button)
			if button == "LeftButton" then
				helpPopup:StartSizing("BOTTOMRIGHT")
			end
		end)
		grip:SetScript("OnMouseUp", function(_, button)
			if button == "LeftButton" then
				helpPopup:StopMovingOrSizing()
			end
		end)
		grip:SetScript("OnEnter", function()
			if grip.tex then grip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight") end
		end)
		grip:SetScript("OnLeave", function()
			if grip.tex then grip.tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up") end
		end)

		helpPopup:SetScript("OnSizeChanged", function(self)
			local w = self:GetWidth() or 720
			local h = self:GetHeight() or 520
			if (not self.SetResizeBounds) then
				if w < 520 then w = 520 end
				if h < 360 then h = 360 end
				self:SetSize(w, h)
			end
			local newW = w - 60
			if newW < 320 then newW = 320 end
			if helpPopupEdit and helpPopupEdit.SetWidth then
				helpPopupEdit:SetWidth(newW)
			end
			if helpPopupScroll and helpPopupScroll.UpdateScrollChildRect then
				helpPopupScroll:UpdateScrollChildRect()
			end
		end)
	end

	helpPopup:Show()
	return helpPopup
end

function ZSBT.OpenHelpTopicInPopup(topicKey)
	local topic = HELP_TOPICS[topicKey]
	if type(topic) ~= "table" then return end
	local st = ensureHelpState()
	if st and st.selected == topicKey and helpPopup and helpPopup:IsShown() then
		return
	end
	if st then
		st.selected = topicKey
	end
	local frame = ensureHelpPopup()
	if not frame then return end

	local titleText = "ZSBT Help"
	if type(topic.name) == "string" and topic.name ~= "" then
		titleText = "ZSBT Help: " .. topic.name
	end
	if helpPopupTitle then
		helpPopupTitle:SetText(titleText)
	end

	local body = ""
	if type(topic.text) == "string" and topic.text ~= "" then
		body = topic.text
	elseif type(topic.docKey) == "string" then
		body = prettyPrintMarkdown(HELP_MD[topic.docKey])
	end

	if helpPopupEdit then
		helpPopupEdit:SetText(body or "")
		helpPopupEdit:ClearFocus()
	end
end

function ZSBT.UpdateHelpPopupIfOpen(topicKey)
	if not (helpPopup and helpPopup.IsShown and helpPopup:IsShown()) then
		return
	end
	local topic = HELP_TOPICS[topicKey]
	if type(topic) ~= "table" then return end

	local st = ensureHelpState()
	if st and st.selected == topicKey then
		return
	end
	if st then
		st.selected = topicKey
	end

	local titleText = "ZSBT Help"
	if type(topic.name) == "string" and topic.name ~= "" then
		titleText = "ZSBT Help: " .. topic.name
	end
	if helpPopupTitle then
		helpPopupTitle:SetText(titleText)
	end

	local body = ""
	if type(topic.text) == "string" and topic.text ~= "" then
		body = topic.text
	elseif type(topic.docKey) == "string" then
		body = prettyPrintMarkdown(HELP_MD[topic.docKey])
	end

	if helpPopupEdit then
		helpPopupEdit:SetText(body or "")
		helpPopupEdit:ClearFocus()
	end
end

local function buildHelpTreeArgs(orderKeys)
	local args = {}
	local order = 1
	local keys = (type(orderKeys) == "table") and orderKeys or HELP_ORDER
	for _, key in ipairs(keys) do
		local topic = HELP_TOPICS[key]
		if type(topic) == "table" and type(topic.name) == "string" then
			local children = topic.children
			local groupArgs
			if type(children) == "table" and #children > 0 then
				groupArgs = {}
				groupArgs.openPopup = {
					type = "execute",
					name = "Open In Window",
					desc = "Open this help topic in a separate window so you can keep it visible while configuring ZSBT.",
					order = 0,
					width = "full",
					func = function()
						if ZSBT and ZSBT.OpenHelpTopicInPopup then
							ZSBT.OpenHelpTopicInPopup(key)
						end
					end,
				}
				groupArgs.body = {
					type = "description",
					name = function()
						if type(topic.text) == "string" and topic.text ~= "" then
							return topic.text
						end
						if type(topic.docKey) == "string" then
							return prettyPrintMarkdown(HELP_MD[topic.docKey])
						end
						return ""
					end,
					order = 0.01,
					width = "full",
					fontSize = "medium",
				}
				local childOrder = 1
				for _, childKey in ipairs(children) do
					local child = HELP_TOPICS[childKey]
					if type(child) == "table" and type(child.name) == "string" then
						groupArgs[childKey] = {
							type = "group",
							name = child.name,
							order = childOrder,
							args = {
								openPopup = {
									type = "execute",
									name = "Open In Window",
									desc = "Open this help topic in a separate window so you can keep it visible while configuring ZSBT.",
									order = 0.1,
									width = "full",
									func = function()
										if ZSBT and ZSBT.OpenHelpTopicInPopup then
											ZSBT.OpenHelpTopicInPopup(childKey)
										end
									end,
								},
								body = {
									type = "description",
									name = function()
										if type(child.text) == "string" and child.text ~= "" then
											return child.text
										end
										if type(child.docKey) == "string" then
											return prettyPrintMarkdown(HELP_MD[child.docKey])
										end
										return ""
									end,
									order = 1,
									width = "full",
									fontSize = "medium",
								},
							},
						}
						childOrder = childOrder + 1
					end
				end
			end
			args[key] = {
				type = "group",
				name = topic.name,
				order = order,
				args = groupArgs or {
					popupHelp = {
						type = "description",
						name = "Tip: If you want to keep this help visible while you change settings in other tabs, click the button below to open it in a separate window.",
						order = 0,
						width = "full",
						fontSize = "medium",
					},
					syncPopupIfOpen = {
						type = "description",
						name = function()
							if ZSBT and ZSBT.UpdateHelpPopupIfOpen then
								ZSBT.UpdateHelpPopupIfOpen(key)
							end
							return ""
						end,
						order = 0.01,
						hidden = function()
							return not (helpPopup and helpPopup.IsShown and helpPopup:IsShown())
						end,
						width = "full",
					},
					openChatSettings = (key == "combatLogSettings") and {
						type = "execute",
						name = "Open Combat Log / Chat Settings",
						desc = "Opens WoW's chat settings so you can quickly get to Combat Log filters.",
						order = 0.05,
						width = "full",
						func = function()
							pcall(function()
								if UIParentLoadAddOn and not ChatConfigFrame then
									UIParentLoadAddOn("Blizzard_ChatConfig")
								end
							end)

							if ChatFrame_OpenChatConfig then
								pcall(function() ChatFrame_OpenChatConfig(DEFAULT_CHAT_FRAME or ChatFrame1) end)
							end
							if ChatConfigFrame and ChatConfigFrame.Show then
								pcall(function()
									ChatConfigFrame:Show()
									ChatConfigFrame:Raise()
								end)
							end

							if not (ChatConfigFrame and ChatConfigFrame.IsShown and ChatConfigFrame:IsShown()) then
								if Addon and Addon.Print then
									Addon:Print("Unable to open Chat/Combat Log settings automatically. Open Chat Settings manually and go to Combat Log filters.")
								end
							end
						end,
					} or nil,
					openPopup = {
						type = "execute",
						name = "Open In Window",
						desc = "Open this help topic in a separate window so you can keep it visible while configuring ZSBT.",
						order = 0.1,
						width = "full",
						func = function()
							if ZSBT and ZSBT.OpenHelpTopicInPopup then
								ZSBT.OpenHelpTopicInPopup(key)
							end
						end,
					},
					body = {
						type = "description",
						name = function()
							if type(topic.text) == "string" and topic.text ~= "" then
								return topic.text
							end
							if type(topic.docKey) == "string" then
								return prettyPrintMarkdown(HELP_MD[topic.docKey])
							end
							return ""
						end,
						order = 1,
						width = "full",
						fontSize = "medium",
					},
				},
			}
			order = order + 1
		end
	end
	return args
end

local function buildHelpTopicArgs(topicKey)
	local tree = buildHelpTreeArgs({ topicKey })
	local grp = tree and tree[topicKey]
	if type(grp) == "table" and type(grp.args) == "table" then
		return grp.args
	end
	return {}
end

------------------------------------------------------------------------
-- Build the complete options table
-- Called once during OnInitialize.
-- Profiles tab is injected by Init.lua after DB creation.
------------------------------------------------------------------------
function ZSBT.BuildOptionsTable()
    -- Ensure ConfigTabs has been loaded
    assert(ZSBT.BuildTab_General, "ConfigTabs.lua must be loaded before Config.lua")

    local options = {
        type = "group",
        name = "|cFFFFD100Zore's|r |cFFFFFFFFScrolling Battle Text|r  |cFF888888v" .. (ZSBT.VERSION or "1.0") .. "|r",
        childGroups = "tree",
        args = {
            ----------------------------------------------------------------
            -- Tab 0: Quick Start
            ----------------------------------------------------------------
            quickStart = ZSBT.BuildTab_QuickStart(),

            ----------------------------------------------------------------
            -- Tab 1: General
            ----------------------------------------------------------------
            general = ZSBT.BuildTab_General(),

            ----------------------------------------------------------------
            -- Tab 0.5: Display
            ----------------------------------------------------------------
            display = ZSBT.BuildTab_Display(),

            ----------------------------------------------------------------
            -- Tab 0.75: Alerts
            ----------------------------------------------------------------
            alerts = ZSBT.BuildTab_Alerts(),

            ----------------------------------------------------------------
            -- Tab 0.9: Combat Text
            ----------------------------------------------------------------
            combatText = ZSBT.BuildTab_CombatText(),

            ----------------------------------------------------------------
            -- Tab 2: Profiles
            ----------------------------------------------------------------
            profiles = ZSBT.BuildTab_ProfilesRoot(),

            ----------------------------------------------------------------
            -- Tab 9: Maintenance
            ----------------------------------------------------------------
            maintenance = {
                type = "group",
                name = "|cFFFFD100Help and Support|r",
                order = 9,
                childGroups = "tree",
                args = {
                    maintenance_help = {
                        type = "group",
                        name = "|cFFFFD100Help|r",
                        order = 1,
                        childGroups = "tree",
                        args = buildHelpTreeArgs(),
                    },

                    maintenance_troubleshooting = {
                        type = "group",
                        name = "|cFFFFD100Troubleshooting|r",
                        order = 2,
                        childGroups = "tree",
                        args = buildHelpTopicArgs("troubleshooting"),
                    },
                },
            },

            ----------------------------------------------------------------
            -- AceDB Profiles tab (injected by Init.lua after DB init)
            ----------------------------------------------------------------
        },
    }

    return options
end

function ZSBT.BuildSpellRulesOptionsTable()
    assert(ZSBT.BuildTab_SpellRulesManager, "ConfigTabs.lua must be loaded before Config.lua")

    local tab = ZSBT.BuildTab_SpellRulesManager()
    local args = (tab and tab.args) or {}

    return {
        type = "group",
		name = "|cFFFFD100Spell Rules|r",
		childGroups = "tab",
		args = {
			main = {
				type  = "group",
				name  = "Spell Rules",
				order = 1,
				args  = args,
			},
		},
    }
end

------------------------------------------------------------------------
-- ZSBT Dark Theme Styling
-- Hooks into AceConfigDialog:Open to apply custom dark+green theme.
------------------------------------------------------------------------

local strikeSilverHooked = false

-- Reusable backdrop templates
local BACKDROP_MAIN = {
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
    insets   = { left = 3, right = 3, top = 3, bottom = 3 },
}

local BACKDROP_INNER = {
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
    insets   = { left = 2, right = 2, top = 2, bottom = 2 },
}
-- Style buttons: strip WoW default textures, apply flat dark + green
------------------------------------------------------------------------
local function StyleButton(btn)
    if true then return end
    if not btn or btn.zsbtBtnStyled then return end
    btn.zsbtBtnStyled = true

    local accent = ZSBT.COLORS.ACCENT
    local dk = ZSBT.COLORS.DARK_MID

    -- Strip default textures
    for _, part in ipairs({"Left","Right","Middle","LeftDisabled","RightDisabled","MiddleDisabled"}) do
        if btn[part] then btn[part]:SetAlpha(0) end
    end
    pcall(function() local t = btn:GetNormalTexture(); if t then t:SetAlpha(0) end end)
    pcall(function() local t = btn:GetPushedTexture(); if t then t:SetAlpha(0) end end)
    pcall(function() local t = btn:GetHighlightTexture(); if t then t:SetAlpha(0) end end)

    -- Flat backdrop
    if not btn.SetBackdrop then Mixin(btn, BackdropTemplateMixin) end
    btn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(dk.r, dk.g, dk.b, 0.95)
    btn:SetBackdropBorderColor(accent.r, accent.g, accent.b, 0.6)

    local fs = btn:GetFontString()
    if fs then fs:SetTextColor(accent.r, accent.g, accent.b, 1.0) end

    -- Hover glow
    btn:HookScript("OnEnter", function(self)
        self:SetBackdropColor(accent.r * 0.25, accent.g * 0.25, accent.b * 0.25, 0.95)
        self:SetBackdropBorderColor(accent.r, accent.g, accent.b, 1.0)
    end)
    btn:HookScript("OnLeave", function(self)
        self:SetBackdropColor(dk.r, dk.g, dk.b, 0.95)
        self:SetBackdropBorderColor(accent.r, accent.g, accent.b, 0.6)
    end)
end

local function IsDescendantOf(frame, ancestor)
    if not frame or not ancestor then return false end
    local p = frame
    while p do
        if p == ancestor then return true end
        if not p.GetParent then break end
        p = p:GetParent()
    end
    return false
end

local function FindAceTreeFrame(root)
    if not root then return nil end
    for _, child in ipairs({ root:GetChildren() }) do
        local name = child.GetName and child:GetName() or nil
        if name and name:match("^AceConfigDialogTreeGroup") and name:match("ScrollBar$") then
            local parent = child.GetParent and child:GetParent() or nil
            return parent
        end
        local found = FindAceTreeFrame(child)
        if found then return found end
    end
    return nil
end

local function IsLeftNavButton(btn, treeframe)
    if not btn then return false end
    local name = btn.GetName and btn:GetName() or nil
    if name and name:match("^AceGUI30TreeButton") then
        return true
    end
    if treeframe and IsDescendantOf(btn, treeframe) then
        return true
    end
    return false
end

local function HasButtonLabel(btn)
    if not btn then return false end
    if btn.GetText and btn:GetText() and btn:GetText() ~= "" then
        return true
    end
    if btn.GetFontString then
        local fs = btn:GetFontString()
        local t = fs and fs.GetText and fs:GetText() or nil
        if t and t ~= "" then
            return true
        end
    end
    return false
end

local function StyleAllButtons(frame)
    if not frame then return end
    local treeframe = FindAceTreeFrame(frame)
    for _, child in ipairs({ frame:GetChildren() }) do
        if child:IsObjectType("Button") then
            if not IsLeftNavButton(child, treeframe) and HasButtonLabel(child) then
                StyleButton(child)
            end
        end
        StyleAllButtons(child)
    end
end

function ZSBT.ApplyStrikeSilverStyling()
    if strikeSilverHooked then return end
    strikeSilverHooked = true

    local ACD = LibStub("AceConfigDialog-3.0", true)
    if not ACD then return end

    local function ShouldStyleApp(appName)
        return appName == "ZSBT"
            or appName == "ZSBT_SpellRules"
            or appName == "ZSBT_BuffRules"
            or appName == "ZSBT_SpellRuleEditor"
            or appName == "ZSBT_BuffRuleEditor"
            or appName == "ZSBT_TriggerEditor"
    end

    local function ApplySavedMainConfigGeometry(f)
        if not (f and f.GetScale and f.SetScale and f.SetSize) then return end
        if not (ZSBT and ZSBT.db and ZSBT.db.char) then return end
        ZSBT.db.char.ui = ZSBT.db.char.ui or {}
        ZSBT.db.char.ui.configWindow = ZSBT.db.char.ui.configWindow or {}
        local cw = ZSBT.db.char.ui.configWindow
        if cw.width == nil then cw.width = 900 end
        if cw.height == nil then cw.height = 720 end
        local s = tonumber(cw.scale)
        local w = tonumber(cw.width)
        local h = tonumber(cw.height)
        f._zsbtApplyingGeometry = true
        if s and s > 0.1 and s < 5 then
            pcall(function() f:SetScale(s) end)
        end
        if w and h and w > 200 and h > 200 then
            pcall(function() f:SetSize(w, h) end)
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if f then f._zsbtApplyingGeometry = false end
            end)
        else
            f._zsbtApplyingGeometry = false
        end
    end

    hooksecurefunc(ACD, "Open", function(self, appName)
        if not ShouldStyleApp(appName) then
            return
        end

        local frame = self.OpenFrames[appName]
        if not frame or not frame.frame then return end

        local f = frame.frame
        local dk = ZSBT.COLORS.DARK
        local border = ZSBT.COLORS.BORDER

        if appName == "ZSBT" then
            if C_Timer and C_Timer.After then
                C_Timer.After(0, function() ApplySavedMainConfigGeometry(f) end)
            else
                ApplySavedMainConfigGeometry(f)
            end
            if not f._zsbtSizeHooked and f.HookScript then
                f._zsbtSizeHooked = true
                f:HookScript("OnHide", function()
                    if not (ZSBT and ZSBT.db and ZSBT.db.char) then return end
                    if f._zsbtApplyingGeometry == true then return end
                    ZSBT.db.char.ui = ZSBT.db.char.ui or {}
                    ZSBT.db.char.ui.configWindow = ZSBT.db.char.ui.configWindow or {}
                    local ww = f.GetWidth and f:GetWidth() or nil
                    local hh = f.GetHeight and f:GetHeight() or nil
                    local ss = f.GetScale and f:GetScale() or nil
                    if type(ww) == "number" and ww > 200 then ZSBT.db.char.ui.configWindow.width = ww end
                    if type(hh) == "number" and hh > 200 then ZSBT.db.char.ui.configWindow.height = hh end
                    if type(ss) == "number" and ss > 0.1 then ZSBT.db.char.ui.configWindow.scale = ss end
                end)
                f:HookScript("OnSizeChanged", function()
                    if not (ZSBT and ZSBT.db and ZSBT.db.char) then return end
                    if f._zsbtApplyingGeometry == true then return end
                    ZSBT.db.char.ui = ZSBT.db.char.ui or {}
                    ZSBT.db.char.ui.configWindow = ZSBT.db.char.ui.configWindow or {}
                    local ww = f.GetWidth and f:GetWidth() or nil
                    local hh = f.GetHeight and f:GetHeight() or nil
                    local ss = f.GetScale and f:GetScale() or nil
                    if type(ww) == "number" and ww > 200 then ZSBT.db.char.ui.configWindow.width = ww end
                    if type(hh) == "number" and hh > 200 then ZSBT.db.char.ui.configWindow.height = hh end
                    if type(ss) == "number" and ss > 0.1 then ZSBT.db.char.ui.configWindow.scale = ss end
                end)
                if f.SetScale then
                    hooksecurefunc(f, "SetScale", function(_, scale)
                        if not (ZSBT and ZSBT.db and ZSBT.db.char) then return end
                        ZSBT.db.char.ui = ZSBT.db.char.ui or {}
                        ZSBT.db.char.ui.configWindow = ZSBT.db.char.ui.configWindow or {}
                        local s = tonumber(scale)
                        if type(s) == "number" and s > 0.1 then
                            ZSBT.db.char.ui.configWindow.scale = s
                        end
                    end)
                end
            end
        end

        if not f.zsbtStyled then
            if not f.SetBackdrop then Mixin(f, BackdropTemplateMixin) end
            f:SetBackdrop(BACKDROP_MAIN)
            f:SetBackdropColor(dk.r, dk.g, dk.b, 0.98)
            f:SetBackdropBorderColor(border.r, border.g, border.b, 0.6)

            -- Title text
            for _, region in pairs({ f:GetRegions() }) do
                if region:IsObjectType("FontString") then
                    local text = region:GetText()
                    if text and (text:find("Zore") or text:find("Scrolling")) then
                        region:SetTextColor(ZSBT.COLORS.TEXT_LIGHT.r,
                                            ZSBT.COLORS.TEXT_LIGHT.g,
                                            ZSBT.COLORS.TEXT_LIGHT.b, 1.0)
                    end
                end
            end
            f.zsbtStyled = true
            ZSBT._configMainFrame = f
        end

        ZSBT.StyleTabButtons(frame)

        -- Style inner content containers
        ZSBT.StyleInnerContainers(frame)

        -- Keep confirmation popups above the AceConfig window.
        if ZSBT.EnsurePopupsOnTop then
            ZSBT.EnsurePopupsOnTop(f)
        end
    end)
    hooksecurefunc(ACD, "SelectGroup", function(self, appName, ...)
        if not ShouldStyleApp(appName) then
            return
        end
        local frame = self.OpenFrames and self.OpenFrames[appName]
        if not frame or not frame.frame then return end
        if appName == "ZSBT" then
            if C_Timer and C_Timer.After then
                C_Timer.After(0, function() ApplySavedMainConfigGeometry(frame.frame) end)
            else
                ApplySavedMainConfigGeometry(frame.frame)
            end
        end
    end)
end

function ZSBT.ReapplyMainConfigGeometrySoon()
	local f = ZSBT and ZSBT._configMainFrame
	if not (f and f.GetWidth and f.GetHeight and f.SetSize) then return end
	if not (ZSBT and ZSBT.db and ZSBT.db.char) then return end
	if f._zsbtReapplyQueued == true then return end

	local ww = f:GetWidth()
	local hh = f:GetHeight()
	local ss = f.GetScale and f:GetScale() or nil
	if type(ww) ~= "number" or type(hh) ~= "number" then return end

	ZSBT.db.char.ui = ZSBT.db.char.ui or {}
	ZSBT.db.char.ui.configWindow = ZSBT.db.char.ui.configWindow or {}
	if ww > 200 then ZSBT.db.char.ui.configWindow.width = ww end
	if hh > 200 then ZSBT.db.char.ui.configWindow.height = hh end
	if type(ss) == "number" and ss > 0.1 then ZSBT.db.char.ui.configWindow.scale = ss end

	f._zsbtReapplyQueued = true
	local function reapply()
		if not f then return end
		f._zsbtApplyingGeometry = true
		if type(ss) == "number" and ss > 0.1 and ss < 5 and f.SetScale then
			pcall(function() f:SetScale(ss) end)
		end
		pcall(function() f:SetSize(ww, hh) end)
		f._zsbtApplyingGeometry = false
		f._zsbtReapplyQueued = false
	end

	if C_Timer and C_Timer.After then
		C_Timer.After(0, reapply)
		C_Timer.After(0.01, reapply)
	else
		reapply()
	end
end

function ZSBT.LockMainConfigWindowGeometryForRefresh()
	local f = ZSBT and ZSBT._configMainFrame
	if not (f and f.SetSize and f.GetWidth and f.GetHeight) then return end
	if f._zsbtGeomLockActive == true then return end

	local w = f:GetWidth()
	local h = f:GetHeight()
	if type(w) ~= "number" or type(h) ~= "number" then return end

	f._zsbtGeomLockActive = true
	f._zsbtGeomLockW = w
	f._zsbtGeomLockH = h
	f._zsbtOrigSetSize = f._zsbtOrigSetSize or f.SetSize
	f._zsbtOrigSetWidth = f._zsbtOrigSetWidth or f.SetWidth
	f._zsbtOrigSetHeight = f._zsbtOrigSetHeight or f.SetHeight

	f.SetSize = function(self, ww, hh)
		return self:_zsbtOrigSetSize(self._zsbtGeomLockW, self._zsbtGeomLockH)
	end
	f.SetWidth = function(self, _)
		return self:_zsbtOrigSetWidth(self._zsbtGeomLockW)
	end
	f.SetHeight = function(self, _)
		return self:_zsbtOrigSetHeight(self._zsbtGeomLockH)
	end

	local function unlock()
		if not f then return end
		if f._zsbtOrigSetSize then f.SetSize = f._zsbtOrigSetSize end
		if f._zsbtOrigSetWidth then f.SetWidth = f._zsbtOrigSetWidth end
		if f._zsbtOrigSetHeight then f.SetHeight = f._zsbtOrigSetHeight end
		f._zsbtGeomLockActive = false
		f._zsbtGeomLockW = nil
		f._zsbtGeomLockH = nil
	end

	if C_Timer and C_Timer.After then
		C_Timer.After(0, unlock)
		C_Timer.After(0.02, unlock)
		C_Timer.After(0.05, unlock)
	else
		unlock()
	end
end

------------------------------------------------------------------------
-- Style tab buttons with Strike Silver colors
-- Finds the AceGUI TabGroup child and applies accent color to active tab.
------------------------------------------------------------------------
function ZSBT.StyleTabButtons(aceFrame)
    if not aceFrame then return end

    -- The AceGUI Frame widget has children; the first is typically the TabGroup
    local tabGroup = nil
    if aceFrame.children then
        for _, child in ipairs(aceFrame.children) do
            if child.type == "TabGroup" then
                tabGroup = child
                break
            end
        end
    end

    if not tabGroup or not tabGroup.tabs then return end

    local accent = ZSBT.COLORS.ACCENT
    local tabInactive = ZSBT.COLORS.TAB_INACTIVE
    local border = ZSBT.COLORS.BORDER

    -- Style tab button backgrounds and text
    for _, tab in ipairs(tabGroup.tabs) do
        if tab and tab.GetFontString then
            local fs = tab:GetFontString()
            if fs then
                -- Default: Pure white for readability on dark background
                fs:SetTextColor(tabInactive.r, tabInactive.g, tabInactive.b, 1.0)
            end
        end
    end

    -- Hook tab selection to recolor active tab with accent
    if not tabGroup.zsbtTabHooked then
        tabGroup.zsbtTabHooked = true

        hooksecurefunc(tabGroup, "SelectTab", function(self, tabValue)
            if not self.tabs then return end
            for _, tab in ipairs(self.tabs) do
                local fs = tab:GetFontString()
                if fs then
                    if tab.value == tabValue then
                        fs:SetTextColor(accent.r, accent.g, accent.b, 1.0)
                    else
                        fs:SetTextColor(tabInactive.r, tabInactive.g, tabInactive.b, 1.0)
                    end
                end
            end
            -- Restyle buttons after tab switch (new buttons get created lazily)
            C_Timer.After(0.1, function()
                if ZSBT._configMainFrame then StyleAllButtons(ZSBT._configMainFrame) end
            end)
        end)
    end

    -- Style the tab bar container backdrop if the border frame exists
    if tabGroup.border then
        local tabBorder = tabGroup.border
        if not tabBorder.SetBackdrop then
            Mixin(tabBorder, BackdropTemplateMixin)
        end
        tabBorder:SetBackdrop(BACKDROP_INNER)
        local dm = ZSBT.COLORS.DARK_MID
        tabBorder:SetBackdropColor(dm.r, dm.g, dm.b, 0.85)
        tabBorder:SetBackdropBorderColor(ZSBT.COLORS.BORDER.r, ZSBT.COLORS.BORDER.g, ZSBT.COLORS.BORDER.b, 0.4)
    end
end

------------------------------------------------------------------------
-- Style inner containers: section borders, scrollable content areas
-- Recursively walks AceGUI children to find InlineGroup/BlizOptionsGroup
-- and applies consistent chrome borders.
------------------------------------------------------------------------
function ZSBT.StyleInnerContainers(aceFrame)
    if not aceFrame or not aceFrame.children then return end

    local border = ZSBT.COLORS.BORDER

    local function styleChild(widget)
        if widget.border then
            local b = widget.border
            if not b.zsbtStyled then
                if not b.SetBackdrop then
                    Mixin(b, BackdropTemplateMixin)
                end
                b:SetBackdrop(BACKDROP_INNER)
                local dm = ZSBT.COLORS.DARK_MID
                b:SetBackdropColor(dm.r, dm.g, dm.b, 0.9)
                b:SetBackdropBorderColor(border.r, border.g, border.b, 0.4)
                b.zsbtStyled = true
            end
        end

        if widget.children then
            for _, child in ipairs(widget.children) do
                styleChild(child)
            end
        end
    end

    for _, child in ipairs(aceFrame.children) do
        styleChild(child)
    end
end

------------------------------------------------------------------------
-- Popup / Z-Order Safety
-- Ensure StaticPopup confirmations don't hide behind the AceConfig frame.
------------------------------------------------------------------------

local popupsOnTopHooked = false

local function RaiseStaticPopupFrame(popupFrame, anchorFrame)
    if not popupFrame then return end
    popupFrame:SetFrameStrata("FULLSCREEN_DIALOG")

    local baseLevel = 0
    if anchorFrame and anchorFrame.GetFrameLevel then
        baseLevel = anchorFrame:GetFrameLevel() or 0
    end
    popupFrame:SetFrameLevel(baseLevel + 200)

    if popupFrame.SetToplevel then
        popupFrame:SetToplevel(true)
    end
end

function ZSBT.EnsurePopupsOnTop(anchorFrame)
    if popupsOnTopHooked then return end
    popupsOnTopHooked = true

    if not StaticPopup_Show then return end

    hooksecurefunc("StaticPopup_Show", function()
        for i = 1, (STATICPOPUP_NUMDIALOGS or 4) do
            local f = _G["StaticPopup" .. i]
            if f and f:IsShown() then
                RaiseStaticPopupFrame(f, anchorFrame)
            end
        end
    end)
end

------------------------------------------------------------------------
-- Cooldown Overlay Visibility Control
-- The overlay is parented to the TabGroup content frame, so we must
-- explicitly hide it when the user is not on the Cooldowns tab.
------------------------------------------------------------------------

ZSBT.UI = ZSBT.UI or {}

function ZSBT.SetCooldownOverlayVisible(isVisible)
    local o = ZSBT.UI and ZSBT.UI.CooldownDropOverlay
    if not o then return end
    -- Option B: drag/drop overlay removed (buggy). Force hidden.
    if false and isVisible then
        if o.mainText then
            o.mainText:SetText("|cFF00CC66[ Drag Spell Here ]|r")
        end
        if o.iconOverlay then
            o.iconOverlay:Hide()
        end
        o:EnableMouse(true)
        o:Show()
    else
        o:Hide()
        o:EnableMouse(false)
        ClearCursor()
    end
end

function ZSBT.SetSpellRulesOverlayVisible(isVisible)
    local o = ZSBT.UI and ZSBT.UI.SpellRulesDropOverlay
    if not o then return end
    if isVisible then
        o:Show()
    else
        o:Hide()
    end
end

local cooldownOverlayTabHooked = false

function ZSBT.HookCooldownOverlayTabSwitch(aceFrame)
    if cooldownOverlayTabHooked then return end
    if not aceFrame or not aceFrame.children then return end

    local tabGroup
    for _, child in ipairs(aceFrame.children) do
        if child.type == "TabGroup" then
            tabGroup = child
            break
        end
    end
    if not tabGroup then return end
    cooldownOverlayTabHooked = true

    local function update(selected)
        ZSBT.SetCooldownOverlayVisible(selected == "cooldowns")
    end

    if tabGroup.SelectTab then
        hooksecurefunc(tabGroup, "SelectTab", function(_, group)
            update(group)
        end)
    end

	-- Some AceGUI paths use SetGroup instead of SelectTab
	if tabGroup.SetGroup then
		hooksecurefunc(tabGroup, "SetGroup", function(self, group)
			-- group may be nil; fall back to status.selected
			local selected = group or (self.status and self.status.selected)
			update(selected)
		end)
	end

    local selected = tabGroup.status and tabGroup.status.selected
    update(selected)
end

local spellRulesOverlayTabHooked = false

function ZSBT.HookSpellRulesOverlayTabSwitch(aceFrame)
    if spellRulesOverlayTabHooked then return end
    if not aceFrame or not aceFrame.children then return end

    local tabGroup
    for _, child in ipairs(aceFrame.children) do
        if child.type == "TabGroup" then
            tabGroup = child
            break
        end
    end
    if not tabGroup then return end
    spellRulesOverlayTabHooked = true

    local function update(selected)
        ZSBT.SetSpellRulesOverlayVisible(selected == "spamControl")
    end

    if tabGroup.SelectTab then
        hooksecurefunc(tabGroup, "SelectTab", function(_, group)
            update(group)
        end)
    end

	-- Some AceGUI paths use SetGroup instead of SelectTab
	if tabGroup.SetGroup then
		hooksecurefunc(tabGroup, "SetGroup", function(self, group)
			local selected = group or (self.status and self.status.selected)
			update(selected)
		end)
	end

    local selected = tabGroup.status and tabGroup.status.selected
    update(selected)
end

------------------------------------------------------------------------
-- Cooldown Drop Overlay
-- Creates a high-strata overlay frame that's parented to the tab content
-- and positioned to overlay the "Drag Spell Here" description text.
------------------------------------------------------------------------

local cooldownDropOverlay = nil

local function ResolveSpellIDFromCursor(cursorType, id, subType, extra1, extra2, extra3, extra4)
	if not cursorType or not id then return nil end

	local function dbg(msg)
		local dl = ZSBT and ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and tonumber(ZSBT.db.profile.diagnostics.debugLevel)
		if dl and dl >= 2 and ZSBT.Addon and ZSBT.Addon.Print then
			ZSBT.Addon:Print(msg)
		end
	end

	if cursorType == "spell" then
		local spellID = nil

		-- Some spell drags (notably talents) may report id=0, with the real spellID
		-- appearing in a later return value from GetCursorInfo().
		local function considerExtra(v)
			if spellID then return end
			if type(v) == "number" and v > 0 and C_Spell and C_Spell.GetSpellInfo then
				local info = C_Spell.GetSpellInfo(v)
				if info and info.name then
					spellID = v
				end
			end
		end
		considerExtra(extra1)
		considerExtra(extra2)
		considerExtra(extra3)
		considerExtra(extra4)

		-- IMPORTANT: spellbook drags often provide a spellbook slot index, not a spellID.
		-- If we treat slot numbers as spellIDs, we'll incorrectly resolve (e.g. 81 => Dodge).
		if type(id) == "number" and id > 0 and C_SpellBook and C_SpellBook.GetSpellBookItemInfo and Enum and Enum.SpellBookSpellBank then
			local banks = {}
			if subType == "pet" then
				banks = { Enum.SpellBookSpellBank.Pet }
			elseif subType == "spell" then
				banks = { Enum.SpellBookSpellBank.Player }
			else
				banks = { Enum.SpellBookSpellBank.Player, Enum.SpellBookSpellBank.Pet }
			end
			for _, bank in ipairs(banks) do
				local info = C_SpellBook.GetSpellBookItemInfo(id, bank)
				if info and type(info.spellID) == "number" and info.spellID > 0 then
					spellID = info.spellID
					break
				end
			end
		end

		-- If spellbook lookup failed, id may already be a spellID (e.g. action bar drag).
		if not spellID and type(id) == "number" and id > 0 and C_Spell and C_Spell.GetSpellInfo then
			local info = C_Spell.GetSpellInfo(id)
			if info and info.name then
				spellID = id
			end
		end

		dbg(("Cooldown drop cursor spell: id=%s subType=%s extra1=%s extra2=%s extra3=%s extra4=%s => spellID=%s")
			:format(tostring(id), tostring(subType), tostring(extra1), tostring(extra2), tostring(extra3), tostring(extra4), tostring(spellID)))
		return spellID
	end

	-- Macro drag can present as cursorType="macro" with id=macroIndex.
	if cursorType == "macro" and type(id) == "number" and id > 0 and type(GetMacroSpell) == "function" then
		local ok, spellID = pcall(GetMacroSpell, id)
		if ok and type(spellID) == "number" and spellID > 0 then
			dbg(("Cooldown drop cursor macro: macro=%s => spellID=%s"):format(tostring(id), tostring(spellID)))
			return spellID
		end
	end

    	-- Action bar drag can present as cursorType="action" with id=actionSlot
	if cursorType == "action" and type(GetActionInfo) == "function" then
		local ok, atype, actionID = pcall(GetActionInfo, id)
		if ok and atype == "spell" and type(actionID) == "number" and actionID > 0 then
			dbg(("Cooldown drop cursor action: slot=%s => spellID=%s"):format(tostring(id), tostring(actionID)))
			return actionID
		end
	end
    return nil
end

function ZSBT.CreateCooldownDropOverlay()
    local ACD = LibStub("AceConfigDialog-3.0", true)
    if not ACD then return end
    
    -- Find the ZSBT config frame
    local configFrame = ACD.OpenFrames["ZSBT"]
    if not configFrame or not configFrame.frame then return end
    
    -- Get the group container content frame (where the actual options are displayed)
    local contentFrame = nil
    if configFrame.children then
        for _, child in ipairs(configFrame.children) do
            if child.type == "TreeGroup" or child.type == "TabGroup" then
                contentFrame = child.content
                break
            end
        end
    end
    
    if not contentFrame then return end

	-- Visibility is controlled via AceConfigDialog:SelectGroup hook (tree navigation).
    
    -- Create overlay if it doesn't exist
    if not cooldownDropOverlay then
        local accent = ZSBT.COLORS.ACCENT
        local dk = ZSBT.COLORS.DARK
        
        cooldownDropOverlay = CreateFrame("Frame", "ZSBT_CooldownDropOverlay", contentFrame, "BackdropTemplate")
        cooldownDropOverlay:SetSize(520, 70)
        cooldownDropOverlay:EnableMouse(true)
        
        -- Keep it above the tab content, but don't force it above other UI windows.
        cooldownDropOverlay:SetFrameStrata(contentFrame:GetFrameStrata() or "MEDIUM")
        cooldownDropOverlay:SetFrameLevel((contentFrame:GetFrameLevel() or 0) + 10)
        
        -- Backdrop styling
        cooldownDropOverlay:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
            insets   = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        cooldownDropOverlay:SetBackdropColor(dk.r * 1.2, dk.g * 1.2, dk.b * 1.2, 0.95)
        cooldownDropOverlay:SetBackdropBorderColor(accent.r, accent.g, accent.b, 0.7)
        
        -- Icon placeholder
        local iconBg = cooldownDropOverlay:CreateTexture(nil, "ARTWORK")
        iconBg:SetSize(36, 36)
        iconBg:SetPoint("LEFT", cooldownDropOverlay, "LEFT", 14, 0)
        iconBg:SetColorTexture(0.15, 0.15, 0.15, 1.0)
        
        -- Icon overlay (shows after drop)
        local iconOverlay = cooldownDropOverlay:CreateTexture(nil, "OVERLAY")
        iconOverlay:SetSize(34, 34)
        iconOverlay:SetPoint("CENTER", iconBg, "CENTER", 0, 0)
        iconOverlay:Hide()
        cooldownDropOverlay.iconOverlay = iconOverlay
        
        -- Main text
        local mainText = cooldownDropOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        mainText:SetPoint("LEFT", iconBg, "RIGHT", 15, 8)
        mainText:SetJustifyH("LEFT")
        mainText:SetText("|cFF00CC66[ Drag Spell Here ]|r")
        cooldownDropOverlay.mainText = mainText
        
        -- Subtext
        local subText = cooldownDropOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        subText:SetPoint("TOPLEFT", mainText, "BOTTOMLEFT", 0, -3)
        subText:SetJustifyH("LEFT")
        subText:SetText("|cFF888888Drag from spellbook or action bar|r")
        
        -- Hover highlight
        local highlight = cooldownDropOverlay:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(accent.r, accent.g, accent.b, 0.15)
		
        
        -- Drag handlers
        cooldownDropOverlay:SetScript("OnReceiveDrag", function(self)
            local cursorType, id, subType, extra1, extra2, extra3, extra4 = GetCursorInfo()
            local spellID = ResolveSpellIDFromCursor(cursorType, id, subType, extra1, extra2, extra3, extra4)
            
            if spellID then
                
                if spellID and spellID > 0 then
                    -- Add to tracking
                    ZSBT.db.char.cooldowns = ZSBT.db.char.cooldowns or {}
                    ZSBT.db.char.cooldowns.tracked = ZSBT.db.char.cooldowns.tracked or {}
                    if not ZSBT.db.char.cooldowns.tracked[spellID] then
                        ZSBT.db.char.cooldowns.tracked[spellID] = true
                        
                        -- Get spell info
                        local name, icon
                        if C_Spell and C_Spell.GetSpellInfo then
                            local info = C_Spell.GetSpellInfo(spellID)
                            if info then
                                name = info.name
                                icon = info.iconID
                            end
                        end
                        
                        -- Visual feedback
                        if icon and self.iconOverlay then
                            self.iconOverlay:SetTexture(icon)
                            self.iconOverlay:Show()
                        end
                        if self.mainText then
                            self.mainText:SetText("|cFF00FF00Added!|r")
                        end
                        
                        -- Reset after 2 seconds
                        C_Timer.After(2.0, function()
                            if self.mainText then
                                self.mainText:SetText("|cFF00CC66[ Drag Spell Here ]|r")
                            end
                            if self.iconOverlay then
                                self.iconOverlay:Hide()
                            end
                        end)
                        
                        local displayName = name and (name .. " (ID: " .. spellID .. ")") or ("Spell ID: " .. spellID)
                        ZSBT.Addon:Print("Now tracking: " .. displayName)
                        
                        -- Refresh UI
                        LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                    else
                        ZSBT.Addon:Print("Spell ID " .. spellID .. " is already being tracked.")
                    end
                else
                    ZSBT.Addon:Print("Could not resolve spell ID. Try dragging from action bar.")
                end
                ClearCursor()
            elseif cursorType == "petaction" then
                ClearCursor()
                ZSBT.Addon:Print("Pet abilities cannot be tracked.")
            elseif cursorType == "item" then
                -- Item drag: store as string key to avoid ID collisions with spells
                local itemID = id
                if itemID and itemID > 0 then
                    local key = "item:" .. itemID
                    ZSBT.db.char.cooldowns = ZSBT.db.char.cooldowns or {}
                    ZSBT.db.char.cooldowns.tracked = ZSBT.db.char.cooldowns.tracked or {}
                    if not ZSBT.db.char.cooldowns.tracked[key] then
                        ZSBT.db.char.cooldowns.tracked[key] = true

                        -- Get item info (may be nil if not cached yet)
                        local name, icon
                        if C_Item and C_Item.GetItemInfo then
                            name, _, _, _, _, _, _, _, _, icon = C_Item.GetItemInfo(itemID)
                        end

                        -- Visual feedback
                        if icon and self.iconOverlay then
                            self.iconOverlay:SetTexture(icon)
                            self.iconOverlay:Show()
                        end
                        if self.mainText then
                            self.mainText:SetText("|cFF00FF00Added!|r")
                        end

                        -- Reset after 2 seconds
                        C_Timer.After(2.0, function()
                            if self.mainText then
                                self.mainText:SetText("|cFF00CC66[ Drag Spell Here ]|r")
                            end
                            if self.iconOverlay then
                                self.iconOverlay:Hide()
                            end
                        end)

                        local displayName = name and (name .. " (Item ID: " .. itemID .. ")") or ("Item ID: " .. itemID)
                        ZSBT.Addon:Print("Now tracking: " .. displayName)

                        -- Refresh UI
                        LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                    else
                        ZSBT.Addon:Print("Item ID " .. itemID .. " is already being tracked.")
                    end
                end
                ClearCursor()
            else
                ClearCursor()
            end
        end)
        
        cooldownDropOverlay:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" then
                local cursorType, id = GetCursorInfo()
                if (cursorType == "spell" or cursorType == "item") and id and id > 0 then
                    -- Trigger the same logic as OnReceiveDrag
                    self:GetScript("OnReceiveDrag")(self)
                end
            end
        end)
    end

    -- If the config frame was rebuilt, re-parent to the current content frame.
    if cooldownDropOverlay:GetParent() ~= contentFrame then
        cooldownDropOverlay:SetParent(contentFrame)
        cooldownDropOverlay:SetFrameStrata(contentFrame:GetFrameStrata() or "MEDIUM")
        cooldownDropOverlay:SetFrameLevel((contentFrame:GetFrameLevel() or 0) + 10)
    end

    -- Expose a stable reference for tab switching control
    ZSBT.UI.CooldownDropOverlay = cooldownDropOverlay
    
    -- Position the overlay: Should appear below "Tracked Spells" header
    -- Approximate Y offset from top of content area
    cooldownDropOverlay:ClearAllPoints()
    cooldownDropOverlay:SetPoint("TOP", contentFrame, "TOP", 0, -180)
	
    
    -- Default to hidden; tab hook (or this function) will show only on "cooldowns".
    ZSBT.SetCooldownOverlayVisible(false)

    local status = ACD.GetStatusTable and ACD:GetStatusTable("ZSBT")
    local selected = status and status.selected
    ZSBT.SetCooldownOverlayVisible(selected == "cooldowns")
end

------------------------------------------------------------------------
-- Spell Rules Drop Overlay (Spam Control)
-- Mirrors the cooldown overlay UX: drag a spell to add a per-spell
-- outgoing throttle rule.
------------------------------------------------------------------------

local spellRulesDropOverlay = nil

local function FindSpellRulesInstructionFontString(root)
	if not root then return nil end

	local needle = "Drag a spell here to create a per-spell outgoing throttle rule"

	local function scanFrame(frame, depth)
		if not frame or depth > 6 then return nil end

		for _, region in pairs({ frame:GetRegions() }) do
			if region and region.IsObjectType and region:IsObjectType("FontString") then
				local ok, txt = pcall(region.GetText, region)
				if ok and type(txt) == "string" and txt:find(needle, 1, true) then
					return region
				end
			end
		end

		for _, child in ipairs({ frame:GetChildren() }) do
			local found = scanFrame(child, depth + 1)
			if found then return found end
		end

		return nil
	end

	return scanFrame(root, 0)
end

local function FindFontStringBySubstring(root, needle)
	if not root or not needle then return nil end

	local function scanFrame(frame, depth)
		if not frame or depth > 10 then return nil end

		for _, region in pairs({ frame:GetRegions() }) do
			if region and region.IsObjectType and region:IsObjectType("FontString") then
				local ok, txt = pcall(region.GetText, region)
				if ok and type(txt) == "string" and txt:find(needle, 1, true) then
					return region
				end
			end
		end

		for _, child in ipairs({ frame:GetChildren() }) do
			local found = scanFrame(child, depth + 1)
			if found then return found end
		end

		return nil
	end

	return scanFrame(root, 0)
end

local function FindFontStringByExactText(root, needle)
	if not root or not needle then return nil end

	local function scanFrame(frame, depth)
		if not frame or depth > 10 then return nil end

		for _, region in pairs({ frame:GetRegions() }) do
			if region and region.IsObjectType and region:IsObjectType("FontString") then
				local ok, txt = pcall(region.GetText, region)
				if ok and type(txt) == "string" and txt == needle then
					return region
				end
			end
		end

		for _, child in ipairs({ frame:GetChildren() }) do
			local found = scanFrame(child, depth + 1)
			if found then return found end
		end

		return nil
	end

	return scanFrame(root, 0)
end

local function FindSpellRulesDropZoneHostFrame(contentRoot)
	-- Host group title.
	local fs = FindFontStringByExactText(contentRoot, "[ Drag Spell Here ]")
	if not fs then
		fs = FindFontStringBySubstring(contentRoot, "Drag Spell Here")
	end
	if not fs then return nil end
	local p = fs:GetParent()
	if not p then return nil end
	return p
end

local function FindSpellRulesPresetButtonFontString(root)
	if not root then return nil end

	local needle = "Apply Protection Preset"

	local function scanFrame(frame, depth)
		if not frame or depth > 8 then return nil end

		for _, region in pairs({ frame:GetRegions() }) do
			if region and region.IsObjectType and region:IsObjectType("FontString") then
				local ok, txt = pcall(region.GetText, region)
				if ok and type(txt) == "string" and txt:find(needle, 1, true) then
					return region
				end
			end
		end

		for _, child in ipairs({ frame:GetChildren() }) do
			local found = scanFrame(child, depth + 1)
			if found then return found end
		end

		return nil
	end

	return scanFrame(root, 0)
end

function ZSBT.CreateSpellRulesDropOverlay()
    local ACD = LibStub("AceConfigDialog-3.0", true)
    if not ACD then return end

    local configFrame = ACD.OpenFrames["ZSBT_SpellRules"]
    if not configFrame or not configFrame.frame then return end

    local contentFrame = nil
    if configFrame.children then
        for _, child in ipairs(configFrame.children) do
            if child and child.content then
                contentFrame = child.content
                break
            end
        end
    end
    if not contentFrame then contentFrame = configFrame.frame end
    if not contentFrame then return end

	local host = FindSpellRulesDropZoneHostFrame(contentFrame)
	-- If we can't find the host widget, fall back to the right pane contentFrame.
	if not host then
		host = contentFrame
	end

    if not spellRulesDropOverlay then
        local accent = ZSBT.COLORS.ACCENT
        local dk = ZSBT.COLORS.DARK

        spellRulesDropOverlay = CreateFrame("Frame", "ZSBT_SpellRulesDropOverlay", host, "BackdropTemplate")
        spellRulesDropOverlay:SetSize(520, 70)
        spellRulesDropOverlay:EnableMouse(true)
		spellRulesDropOverlay:SetFrameStrata(host:GetFrameStrata() or "DIALOG")
		spellRulesDropOverlay:SetFrameLevel((host.GetFrameLevel and host:GetFrameLevel() or 1) + 5)

        spellRulesDropOverlay:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
            insets   = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        spellRulesDropOverlay:SetBackdropColor(dk.r * 1.2, dk.g * 1.2, dk.b * 1.2, 0.95)
        spellRulesDropOverlay:SetBackdropBorderColor(accent.r, accent.g, accent.b, 0.7)

        local iconBg = spellRulesDropOverlay:CreateTexture(nil, "ARTWORK")
        iconBg:SetSize(36, 36)
        iconBg:SetPoint("LEFT", spellRulesDropOverlay, "LEFT", 14, 0)
        iconBg:SetColorTexture(0.15, 0.15, 0.15, 1.0)

        local iconOverlay = spellRulesDropOverlay:CreateTexture(nil, "OVERLAY")
        iconOverlay:SetSize(34, 34)
        iconOverlay:SetPoint("CENTER", iconBg, "CENTER", 0, 0)
        iconOverlay:Hide()
        spellRulesDropOverlay.iconOverlay = iconOverlay

        local mainText = spellRulesDropOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        mainText:SetPoint("LEFT", iconBg, "RIGHT", 15, 8)
        mainText:SetJustifyH("LEFT")
        mainText:SetText("|cFF00CC66[ Drag Spell Here ]|r")
        spellRulesDropOverlay.mainText = mainText

        local subText = spellRulesDropOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        subText:SetPoint("TOPLEFT", mainText, "BOTTOMLEFT", 0, -3)
        subText:SetJustifyH("LEFT")
        subText:SetText("|cFF888888Adds an outgoing spam rule (throttle slider)|r")

        local highlight = spellRulesDropOverlay:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(accent.r, accent.g, accent.b, 0.15)

        spellRulesDropOverlay:SetScript("OnReceiveDrag", function(self)
            local cursorType, id, subType = GetCursorInfo()
            local spellID = ResolveSpellIDFromCursor(cursorType, id, subType)

            if spellID and spellID > 0 then
                local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
                if sc then
                    sc.spellRules = sc.spellRules or {}
                    if not sc.spellRules[spellID] then
                        sc.spellRules[spellID] = { enabled = true, throttleSec = 0.20 }
                    elseif type(sc.spellRules[spellID]) == "table" and sc.spellRules[spellID].enabled == nil then
                        sc.spellRules[spellID].enabled = true
                    end

                    local name, icon
                    if C_Spell and C_Spell.GetSpellInfo then
                        local info = C_Spell.GetSpellInfo(spellID)
                        if info then
                            name = info.name
                            icon = info.iconID
                        end
                    end

                    if icon and self.iconOverlay then
                        self.iconOverlay:SetTexture(icon)
                        self.iconOverlay:Show()
                    end
                    if self.mainText then
                        self.mainText:SetText("|cFF00FF00Added!|r")
                    end

                    C_Timer.After(2.0, function()
                        if self.mainText then
                            self.mainText:SetText("|cFF00CC66[ Drag Spell Here ]|r")
                        end
                        if self.iconOverlay then
                            self.iconOverlay:Hide()
                        end
                    end)

                    local displayName = name and (name .. " (ID: " .. spellID .. ")") or ("Spell ID: " .. spellID)
                    if ZSBT.Addon and ZSBT.Addon.Print then
                        ZSBT.Addon:Print("Added spell rule: " .. displayName)
                    end

                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end
            else
                if ZSBT.Addon and ZSBT.Addon.Print then
                    ZSBT.Addon:Print("Could not resolve spell ID. Try dragging from action bar.")
                end
            end
            ClearCursor()
        end)

        spellRulesDropOverlay:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" then
                local cursorType, id = GetCursorInfo()
                if (cursorType == "spell" or cursorType == "action") and id and id > 0 then
                    self:GetScript("OnReceiveDrag")(self)
                end
            end
        end)
    end

    ZSBT.UI.SpellRulesDropOverlay = spellRulesDropOverlay

    	spellRulesDropOverlay:ClearAllPoints()
	if spellRulesDropOverlay:GetParent() ~= host then
		spellRulesDropOverlay:SetParent(host)
	end
	spellRulesDropOverlay:SetPoint("TOPLEFT", host, "TOPLEFT", 6, -6)
	spellRulesDropOverlay:SetPoint("TOPRIGHT", host, "TOPRIGHT", -6, -6)
	spellRulesDropOverlay:SetHeight(70)

	ZSBT.SetSpellRulesOverlayVisible(true)
end

function ZSBT.HideCooldownDropOverlay()
    if cooldownDropOverlay then
        cooldownDropOverlay:Hide()
    end
end
