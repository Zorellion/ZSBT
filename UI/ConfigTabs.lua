------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - Configuration Tab Definitions
-- Each function builds one AceConfig options group (tab).
-- Order values control tab ordering in the UI.
--
-- NOTE: All font/sound dropdowns use standard "select" type with
-- ZSBT.BuildFontDropdown() / ZSBT.BuildSoundDropdown() helpers.
-- No LSM30_Font or LSM30_Sound widget dependencies.
------------------------------------------------------------------------

local ADDON_NAME, ZSBT = ...
local Addon = ZSBT.Addon

------------------------------------------------------------------------
-- Compatibility: C_Spell.GetSpellInfo for WoW 12.0+
-- Returns spell name or fallback string. Handles nil gracefully.
------------------------------------------------------------------------
local function SafeGetSpellName(spellID)
    if not spellID then return nil end
    -- WoW 12.0+: use C_Spell.GetSpellInfo which returns a table
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.name then
            return info.name
        end
    end
    -- Fallback for older API (pre-12.0)
    if GetSpellInfo then
        local name = GetSpellInfo(spellID)
        if name then return name end
    end
    return nil
end

if StaticPopupDialogs and not StaticPopupDialogs["TRUESTRIKE_REMOVE_SPELL"] then
	StaticPopupDialogs["TRUESTRIKE_REMOVE_SPELL"] = {
		text = "Remove %s from tracking?",
		button1 = ACCEPT,
		button2 = CANCEL,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
		preferredIndex = 3,
		OnAccept = function(self, idKey)
			if not idKey then return end
			if not ZSBT or not ZSBT.db or not ZSBT.db.char then return end
			ZSBT.db.char.cooldowns = ZSBT.db.char.cooldowns or {}
			ZSBT.db.char.cooldowns.tracked = ZSBT.db.char.cooldowns.tracked or {}
			ZSBT.db.char.cooldowns.tracked[idKey] = nil
			LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
		end,
	}
end

if StaticPopupDialogs and not StaticPopupDialogs["TRUESTRIKE_DELETE_SCROLLAREA"] then
	StaticPopupDialogs["TRUESTRIKE_DELETE_SCROLLAREA"] = {
		text = "Delete scroll area '%s'?",
		button1 = ACCEPT,
		button2 = CANCEL,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
		preferredIndex = 3,
		OnAccept = function(self, areaName)
			if ZSBT and ZSBT.DeleteScrollAreaByName then
				ZSBT.DeleteScrollAreaByName(areaName, false)
			end
		end,
	}
end

if StaticPopupDialogs and not StaticPopupDialogs["TRUESTRIKE_DELETE_LAST_SCROLLAREA"] then
	StaticPopupDialogs["TRUESTRIKE_DELETE_LAST_SCROLLAREA"] = {
		text = "'%s' is your last scroll area. Delete it anyway? A new default scroll area will be created.",
		button1 = ACCEPT,
		button2 = CANCEL,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
		preferredIndex = 3,
		OnAccept = function(self, areaName)
			if ZSBT and ZSBT.DeleteScrollAreaByName then
				ZSBT.DeleteScrollAreaByName(areaName, true)
			end
		end,
	}
end

------------------------------------------------------------------------
-- TAB 9: TRIGGERS
------------------------------------------------------------------------
function ZSBT.BuildTab_Triggers()
	return {
		type = "group",
		name = "|cFFFFD100Triggers|r",
		order = 10,
		args = {
			header = { type = "header", name = "Custom Triggers", order = 1 },
			enabled = {
				type = "toggle",
				name = "Enable Triggers",
				order = 2,
				width = "full",
				get = function() return ZSBT.db.char.triggers.enabled == true end,
				set = function(_, v) ZSBT.db.char.triggers.enabled = v and true or false end,
			},
			desc = {
				type = "description",
				name = "Triggers let you fire custom notifications on events like buffs, cooldown ready, and low health/mana.",
				order = 3,
				fontSize = "medium",
			},
			restoreUT = {
				type = "execute",
				name = "Setup UT Announcer Triggers",
				desc = "Adds the shipped UT_KILL_1..UT_KILL_7 triggers (merge-only).",
				order = 3.5,
				width = "full",
				func = function()
					if ZSBT and ZSBT.LockMainConfigWindowGeometryForRefresh then
						ZSBT.LockMainConfigWindowGeometryForRefresh()
					end
					if ZSBT and ZSBT.ReapplyMainConfigGeometrySoon then
						ZSBT.ReapplyMainConfigGeometrySoon()
					end
					if ZSBT and ZSBT.RestoreUTAnnouncerPresets then
						ZSBT:RestoreUTAnnouncerPresets()
					end
					if ZSBT.RefreshTriggersTab then ZSBT.RefreshTriggersTab() end
					local ACR = LibStub("AceConfigRegistry-3.0", true)
					if ACR then ACR:NotifyChange("ZSBT") end
					if ZSBT and ZSBT.ReapplyMainConfigGeometrySoon then
						ZSBT.ReapplyMainConfigGeometrySoon()
					end
				end,
			},
			add = {
				type = "execute",
				name = "Add Trigger",
				order = 4,
				width = "full",
				func = function()
					local tdb = ZSBT.db and ZSBT.db.char and ZSBT.db.char.triggers
					if not tdb then return end
					tdb.items = tdb.items or {}
					local idx = #tdb.items + 1
					tdb.items[idx] = {
						id = tostring(idx),
						enabled = true,
						eventType = "AURA_GAIN",
						spellId = nil,
						throttleSec = 0,
						action = { text = "{spell}!", scrollArea = "Notifications", sound = "None", color = { r = 1, g = 1, b = 1 } },
					}
					if ZSBT.RefreshTriggersTab then ZSBT.RefreshTriggersTab() end
					local ACR = LibStub("AceConfigRegistry-3.0", true)
					if ACR then ACR:NotifyChange("ZSBT") end
				end,
			},
			listHeader = {
				type = "header",
				name = "Triggers",
				order = 10,
			},
			list = {
				type = "group",
				name = "",
				inline = true,
				order = 11,
				args = {},
			},
		},
	}
end

do
	local original = ZSBT.BuildTab_Triggers
	ZSBT.BuildTab_Triggers = function()
		local tab = original()
		ZSBT._triggersTabRef = tab
		local container = tab.args.list
		if not container then return tab end
		container.args = {}

		ZSBT.RefreshTriggersTab = function()
			if not ZSBT._triggersTabRef or not ZSBT._triggersTabRef.args or not ZSBT._triggersTabRef.args.list then return end
			local listContainer = ZSBT._triggersTabRef.args.list
			listContainer.args = {}

			local tdb = ZSBT.db and ZSBT.db.char and ZSBT.db.char.triggers
			local items = tdb and tdb.items
			if type(items) ~= "table" then return end

			local order = 1
			for idx = 1, math.min(#items, 60) do
				local t = items[idx]
				if type(t) == "table" then
					listContainer.args["label_" .. idx] = {
						type = "description",
						name = function()
							local tt = ZSBT.db.char.triggers.items[idx]
							if type(tt) ~= "table" then return "" end
							local et = tt.eventType or "?"
							local sid = tt.spellId
							local a = tt.action
							local text = (type(a) == "table" and type(a.text) == "string" and a.text ~= "") and a.text or "(no text)"
							local extra = sid and (" (" .. tostring(sid) .. ")") or ""
							return (tt.enabled ~= false and "|cFFFFD100" or "|cFF888888") .. et .. extra .. "|r: " .. text
						end,
						order = order,
						width = "double",
					}
					listContainer.args["edit_" .. idx] = {
						type = "execute",
						name = "Edit",
						order = order + 0.1,
						width = "half",
						func = function()
							if Addon and Addon.OpenTriggerEditor then
								Addon:OpenTriggerEditor(idx)
							end
						end,
					}
					listContainer.args["remove_" .. idx] = {
						type = "execute",
						name = "|cFFFF4444Remove|r",
						order = order + 0.2,
						width = "half",
						func = function()
							if ZSBT and ZSBT.LockMainConfigWindowGeometryForRefresh then
								ZSBT.LockMainConfigWindowGeometryForRefresh()
							end
							if ZSBT and ZSBT.ReapplyMainConfigGeometrySoon then
								ZSBT.ReapplyMainConfigGeometrySoon()
							end
							local tdb2 = ZSBT.db and ZSBT.db.char and ZSBT.db.char.triggers
							if not (tdb2 and type(tdb2.items) == "table") then return end
							local trig = tdb2.items[idx]
							local et = (type(trig) == "table" and type(trig.eventType) == "string") and trig.eventType or nil
							if et and et:match("^UT_KILL_%d+") then
								tdb2.utDeletedPresets = tdb2.utDeletedPresets or {}
								tdb2.utDeletedPresets[et] = true
							end
							table.remove(tdb2.items, idx)
							if ZSBT.RefreshTriggersTab then ZSBT.RefreshTriggersTab() end
							local ACR = LibStub("AceConfigRegistry-3.0", true)
							if ACR then ACR:NotifyChange("ZSBT") end
						end,
					}
					order = order + 1
				end
			end
		end

		if ZSBT.RefreshTriggersTab then ZSBT.RefreshTriggersTab() end

		return tab
	end
end

------------------------------------------------------------------------
-- Buff Rules Manager (separate AceConfig window)
------------------------------------------------------------------------

local buffRuleSpellInput = ""
local buffRuleSpellResolvedID = nil

function ZSBT.BuildTab_BuffRulesManager()
	return {
		type  = "group",
		name  = "|cFFFFD100Buff Rules|r",
		order = 1,
		args  = {
			headerRules = {
				type  = "header",
				name  = "Buff Rules (Notifications)",
				order = 1,
			},
			rulesDesc = {
				type     = "description",
				name     = "Control which player buff (aura/proc) gained/faded notifications you see. Useful for taming noisy procs: disable Gain/Fade per buff, or add a small throttle. Use 'Recently Seen Buffs' below to discover spellIDs.",
				order    = 2,
				fontSize = "medium",
			},
			addHeader = {
				type  = "header",
				name  = "Add Buff Rule",
				order = 10,
			},
			spellIdInput = {
				type  = "input",
				name  = "Buff SpellID",
				desc  = "Enter a SpellID or exact spell name to add a rule.",
				order = 11,
				width = "full",
				get   = function() return buffRuleSpellInput end,
				set   = function(_, val)
					buffRuleSpellInput = tostring(val or "")
					local sid = nil
					if ZSBT.ResolveSpellInputToID then
						sid = ZSBT.ResolveSpellInputToID(buffRuleSpellInput)
					else
						sid = tonumber(buffRuleSpellInput)
					end
					buffRuleSpellResolvedID = (type(sid) == "number" and sid > 0) and sid or nil
				end,
			},
			spellIdResolved = {
				type  = "description",
				name  = function()
					return (ZSBT.GetResolvedSpellLabel and ZSBT.GetResolvedSpellLabel(buffRuleSpellResolvedID)) or ""
				end,
				order = 11.05,
				width = "full",
				hidden = function() return not (type(buffRuleSpellResolvedID) == "number") end,
			},
			addSpellId = {
				type  = "execute",
				name  = "Add",
				desc  = "Add a rule for this buff SpellID (merge-only).",
				order = 12,
				width = "full",
				func  = function()
					local spellID = nil
					if ZSBT.ResolveSpellInputToID then
						spellID = ZSBT.ResolveSpellInputToID(buffRuleSpellInput)
					else
						spellID = tonumber(buffRuleSpellInput)
					end
					if not spellID then return end
					local name = SafeGetSpellName(spellID)
					if not name then return end
					local sc = ZSBT.db.char.spamControl
					sc.auraRules = sc.auraRules or {}
					if sc.auraRules[spellID] == nil then
						sc.auraRules[spellID] = { enabled = true, throttleSec = 0.00, suppressGain = false, suppressFade = false }
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT_BuffRules")
				end,
			},
			addRuleSpacer = {
				type  = "description",
				name  = " ",
				order = 13,
			},
			templatesHeader = {
				type  = "header",
				name  = "Templates",
				order = 14,
			},
			templatesApply = {
				type  = "execute",
				name  = "Apply Class Templates (Merge Only)",
				desc  = "Applies built-in templates for your class. Merge-only (never overwrites existing rules).",
				order = 15,
				width = "full",
				func  = function()
					ZSBT.ApplyCurrentClassSpecTemplates_Merge()
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT_SpellRules")
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT_BuffRules")
				end,
			},
			templatesAllSpecs = {
				type  = "toggle",
				name  = "Include All Specs (Recommended)",
				desc  = "If enabled, applies templates for ALL specs for your class (more rules, less maintenance).",
				order = 15.1,
				width = "full",
				get   = function()
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					return sc and sc.templates and sc.templates.applyAllSpecs == true
				end,
				set   = function(_, v)
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					if not sc then return end
					sc.templates = sc.templates or {}
					sc.templates.applyAllSpecs = v and true or false
				end,
			},
			templatesNote = {
				type  = "description",
				name  = "Templates are merge-only: they add missing rules but never overwrite your custom rules.",
				order = 16,
				width = "full",
				fontSize = "medium",
			},

			headerRecent = {
				type  = "header",
				name  = "Recently Seen Buffs",
				order = 20,
			},
			recentDesc = {
				type     = "description",
				name     = "These suggestions are based on buffs ZSBT has recently seen on you. Gain a buff (proc, cooldown, etc.) to populate this list.",
				order    = 21,
				fontSize = "medium",
			},
			recentStatus = {
				type     = "description",
				name     = function()
					local stats = ZSBT.Core and ZSBT.Core._recentBuffStats
					local n = 0
					if type(stats) == "table" then
						for _ in pairs(stats) do n = n + 1 end
					end
					return "Recorded recent buffs: " .. tostring(n)
				end,
				order    = 21.5,
				fontSize = "medium",
			},
			recentRefresh = {
				type  = "execute",
				name  = "Refresh Recent Buffs",
				desc  = "Refresh the Recently Seen Buffs list.",
				order = 22,
				width = "full",
				func  = function()
					local stats = ZSBT.Core and ZSBT.Core._recentBuffStats
					local n = 0
					if type(stats) == "table" then
						for _ in pairs(stats) do n = n + 1 end
					end
					if Addon and Addon.Print then
						Addon:Print("Buff Rules: recorded recent buffs = " .. tostring(n))
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT_BuffRules")
				end,
			},
			recentContainer = {
				type   = "group",
				name   = "Recent Buffs",
				order  = 23,
				inline = true,
				args   = {},
			},

			rulesListHeader = {
				type     = "description",
				name     = function()
					local rules = ZSBT.db.char.spamControl.spellRules or {}
					local count = 0
					for _ in pairs(rules) do count = count + 1 end
					if count == 0 then
						return "No spell rules configured."
					end
					return "Configured spell rules: |cFF00CC66" .. tostring(count) .. "|r"
				end,
				order    = 30,
				fontSize = "medium",
			},
			rulesListContainer = {
				type   = "group",
				name   = "Buff Rules List",
				order  = 31,
				inline = true,
				hidden = function()
					local rules = ZSBT.db.char.spamControl.auraRules or {}
					return next(rules) == nil
				end,
				args   = {},
			},
		},
	}
end

do
	local originalBuilder = ZSBT.BuildTab_BuffRulesManager

	ZSBT.BuildTab_BuffRulesManager = function()
		local tab = originalBuilder()
		local rulesContainer = tab.args.rulesListContainer
		local recentContainer = tab.args.recentContainer

		local function getSortedRuleSpellIDs()
			local rules = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl and ZSBT.db.char.spamControl.auraRules
			if type(rules) ~= "table" then return {} end
			local sorted = {}
			for spellID, rule in pairs(rules) do
				if type(spellID) == "number" and type(rule) == "table" then
					sorted[#sorted + 1] = spellID
				end
			end
			table.sort(sorted)
			return sorted
		end

		if rulesContainer then
			rulesContainer.args = {}
			local MAX_SLOTS = 80
			local baseOrder = 1
			for slot = 1, MAX_SLOTS do
				local slotIndex = slot
				local function getSpellID()
					local sorted = getSortedRuleSpellIDs()
					return sorted[slotIndex]
				end

				rulesContainer.args["ruleLabel_" .. slot] = {
						type   = "description",
						name   = function()
							local spellID = getSpellID()
							if not spellID then return "" end
							local name = SafeGetSpellName(spellID) or ("Spell #" .. tostring(spellID))
							return "  \226\128\162 " .. name .. "  |cFF888888(ID: " .. tostring(spellID) .. ")|r"
						end,
						order  = baseOrder + (slot - 1) * 7,
						width  = "double",
						hidden = function() return getSpellID() == nil end,
						fontSize = "medium",
					}

				rulesContainer.args["ruleEnabled_" .. slot] = {
						type   = "toggle",
						name   = "Enabled",
						order  = baseOrder + (slot - 1) * 7 + 1,
						width  = "half",
						hidden = function() return getSpellID() == nil end,
						get    = function()
							local spellID = getSpellID(); if not spellID then return false end
							local rule = ZSBT.db.char.spamControl.auraRules[spellID]
							return type(rule) == "table" and rule.enabled ~= false
						end,
						set    = function(_, val)
							local spellID = getSpellID(); if not spellID then return end
							local rules = ZSBT.db.char.spamControl.auraRules
							rules[spellID] = rules[spellID] or {}
							rules[spellID].enabled = val and true or false
						end,
					}

				rulesContainer.args["ruleEdit_" .. slot] = {
					type   = "execute",
					name   = "Edit",
					order  = baseOrder + (slot - 1) * 7 + 2,
					width  = "half",
					hidden = function() return getSpellID() == nil end,
					func   = function()
						local spellID = getSpellID(); if not spellID then return end
						if Addon and Addon.OpenBuffRuleEditor then
							Addon:OpenBuffRuleEditor(spellID)
						end
					end,
				}

				rulesContainer.args["ruleRemove_" .. slot] = {
						type   = "execute",
						name   = "|cFFFF4444Remove|r",
						order  = baseOrder + (slot - 1) * 7 + 3,
						width  = "half",
						hidden = function() return getSpellID() == nil end,
						func   = function()
							local spellID = getSpellID(); if not spellID then return end
							ZSBT.db.char.spamControl.auraRules[spellID] = nil
							LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT_BuffRules")
						end,
					}
				end
		end

		if recentContainer then
			recentContainer.args = {}
			local stats = ZSBT.Core and ZSBT.Core._recentBuffStats
			local rules = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl and ZSBT.db.char.spamControl.auraRules
			if type(stats) == "table" and type(rules) == "table" then
				local items = {}
				for spellID, e in pairs(stats) do
					if type(spellID) == "number" and type(e) == "table" then
						items[#items + 1] = { id = spellID, count = tonumber(e.count) or 0, lastSeen = tonumber(e.lastSeen) or 0 }
					end
				end
				table.sort(items, function(a, b)
					if a.count == b.count then return a.lastSeen > b.lastSeen end
					return a.count > b.count
				end)
				local MAX = 12
				local shown = 0
				for i = 1, #items do
					if shown >= MAX then break end
					local spellID = items[i].id
					if rules[spellID] == nil then
						shown = shown + 1
						local row = shown
						local name = SafeGetSpellName(spellID) or ("Spell #" .. tostring(spellID))
						local seen = tonumber(items[i].count) or 0
						recentContainer.args["recentLabel_" .. row] = {
						type  = "description",
						name  = ("%s  |cFF888888(ID: %s, seen: %d)|r"):format(name, tostring(spellID), seen),
						order = row * 3,
						width = "double",
					}
						recentContainer.args["recentAdd_" .. row] = {
						type  = "execute",
						name  = "Add Rule",
						desc  = "Add a buff rule for this SpellID.",
						order = row * 3 + 1,
						width = "half",
						disabled = false,
						func  = function()
							if rules[spellID] == nil then
								rules[spellID] = { enabled = true, throttleSec = 0.00, suppressGain = false, suppressFade = false }
								LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT_BuffRules")
							end
						end,
					}
						recentContainer.args["recentSpacer_" .. row] = {
						type  = "description",
						name  = " ",
						order = row * 3 + 2,
						width = "full",
					}
					end
				end
			end
		end

		return tab
	end
end

------------------------------------------------------------------------
-- Compatibility: C_Item.GetItemInfo
-- Returns item name or fallback string. Handles nil gracefully.
------------------------------------------------------------------------
local function SafeGetItemName(itemID)
    if not itemID then return nil end
    itemID = tonumber(itemID)
    if not itemID then return nil end
    if C_Item and C_Item.GetItemInfo then
        local name = C_Item.GetItemInfo(itemID)
        if name then return name end
    end
    return nil
end

local function FindSpellIDInSpellbookByName(targetName)
	if not targetName or type(targetName) ~= "string" then return nil end
	if not C_SpellBook or not C_SpellBook.GetSpellBookItemInfo then return nil end

	local banks = {
		Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player,
		Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Pet,
	}

	for _, bank in ipairs(banks) do
		if bank then
			for slot = 1, 500 do
				local spellInfo = C_SpellBook.GetSpellBookItemInfo(slot, bank)
				if not spellInfo then break end
				if spellInfo.spellID and spellInfo.name == targetName then
					return spellInfo.spellID
				end
			end
		end
	end

	return nil
end

function ZSBT.ApplyWarriorSpellRulePreset_Merge()
	-- Legacy wrapper (backward compatibility)
	if ZSBT.ApplySpellRuleTemplate_Merge then
		ZSBT.ApplySpellRuleTemplate_Merge("WARRIOR", "COMMON")
	end
end

local function ApplyWarriorSpecPreset_Merge(specName)
	if not ZSBT.db or not ZSBT.db.profile or not ZSBT.db.profile.spamControl then return end

	-- Always apply the common preset first (merge-only).
	if ZSBT.ApplyWarriorSpellRulePreset_Merge then
		ZSBT.ApplyWarriorSpellRulePreset_Merge()
	end

	local sc = ZSBT.db.char.spamControl
	sc.spellRules = sc.spellRules or {}

	local function knowsSpell(spellID)
		if not spellID or type(spellID) ~= "number" then return false end
		if type(IsPlayerSpell) == "function" then
			local ok, res = pcall(IsPlayerSpell, spellID)
			if ok and type(res) == "boolean" and res == true then return true end
		end
		if C_SpellBook and C_SpellBook.ContainsSpell then
			local ok, res = pcall(C_SpellBook.ContainsSpell, spellID)
			if ok and type(res) == "boolean" and res == true then return true end
		end
		return false
	end

	local function addRuleAny(spellIDs, throttleSec)
		if type(spellIDs) ~= "table" then return end
		for _, id in ipairs(spellIDs) do
			if type(id) == "number" and knowsSpell(id) then
				if sc.spellRules[id] == nil then
					sc.spellRules[id] = { enabled = true, throttleSec = throttleSec }
				end
				return
			end
		end
	end

	-- Spec-specific candidates
	if specName == "ARMS" then
		addRuleAny({12294}, 0.15)             -- Mortal Strike
		addRuleAny({7384}, 0.15)              -- Overpower
		addRuleAny({262161, 167105}, 0.25)    -- Warbreaker / Colossus Smash
		addRuleAny({227847}, 0.40)            -- Bladestorm
	elseif specName == "FURY" then
		addRuleAny({23881}, 0.15)             -- Bloodthirst
		addRuleAny({85288}, 0.15)             -- Raging Blow
		addRuleAny({184367}, 0.25)            -- Rampage
		addRuleAny({280735}, 0.35)            -- Siegebreaker
	elseif specName == "PROT" then
		addRuleAny({20243}, 0.25)             -- Devastate
		addRuleAny({46968}, 0.35)             -- Shockwave
	end

	local ACR = LibStub("AceConfigRegistry-3.0", true)
	if ACR then ACR:NotifyChange("ZSBT") end
end

function ZSBT.ApplyWarriorSpellRulePreset_Arms_Merge()
	ApplyWarriorSpecPreset_Merge("ARMS")
end

function ZSBT.ApplyWarriorSpellRulePreset_Fury_Merge()
	ApplyWarriorSpecPreset_Merge("FURY")
end

function ZSBT.ApplyWarriorSpellRulePreset_Prot_Merge()
	ApplyWarriorSpecPreset_Merge("PROT")
end


------------------------------------------------------------------------
-- Class / Spec Templates (merge-only)
------------------------------------------------------------------------
if not ZSBT.RuleTemplates then
	ZSBT.RuleTemplates = { spellRules = {}, auraRules = {} }
end

local function ensureTemplateTable(kind, classTag)
	if not ZSBT.RuleTemplates then ZSBT.RuleTemplates = { spellRules = {}, auraRules = {} } end
	ZSBT.RuleTemplates[kind] = ZSBT.RuleTemplates[kind] or {}
	ZSBT.RuleTemplates[kind][classTag] = ZSBT.RuleTemplates[kind][classTag] or {}
	return ZSBT.RuleTemplates[kind][classTag]
end

local DebugPrint

local function knowsSpell(spellID)
	if not spellID or type(spellID) ~= "number" then return false end
	if type(IsPlayerSpell) == "function" then
		local ok, res = pcall(IsPlayerSpell, spellID)
		-- WoW 12.0: res may be a "secret boolean" (tainted) and must not be compared/used.
		if ok and type(res) == "boolean" and res == true then return true end
	end
	if C_SpellBook and C_SpellBook.ContainsSpell then
		local ok, res = pcall(C_SpellBook.ContainsSpell, spellID)
		if ok and type(res) == "boolean" and res == true then return true end
	end
	return false
end

local function getPlayerClassTag()
	if type(UnitClass) ~= "function" then
		DebugPrint("getPlayerClassTag: UnitClass not available")
		return nil
	end
	local ok, _, classTag = pcall(UnitClass, "player")
	if not ok then
		DebugPrint("getPlayerClassTag: UnitClass() failed")
		return nil
	end
	if type(classTag) ~= "string" or classTag == "" then
		DebugPrint("getPlayerClassTag: UnitClass returned no classTag")
		return nil
	end
	if ZSBT and ZSBT.IsSafeString and not ZSBT.IsSafeString(classTag) then
		DebugPrint("getPlayerClassTag: classTag is not safe")
		return nil
	end
	return classTag
end

local function getPlayerSpecNameTag(classTag)
	-- Returns a stable-ish short tag, e.g. "ARMS", "FURY", etc. If we don't know, fall back to specID string.
	local specIndex = GetSpecialization and GetSpecialization()
	if not specIndex then return nil end
	local specID = GetSpecializationInfo and GetSpecializationInfo(specIndex)
	if not specID then return nil end

	-- Known name mappings (can be extended without changing any UI).
	local SPEC_TAGS = {
		WARRIOR = { [71] = "ARMS", [72] = "FURY", [73] = "PROT" },
		PALADIN = { [65] = "HOLY", [66] = "PROT", [70] = "RET" },
		HUNTER  = { [253] = "BM", [254] = "MM", [255] = "SV" },
		ROGUE   = { [259] = "ASSASS", [260] = "OUTLAW", [261] = "SUB" },
		PRIEST  = { [256] = "DISC", [257] = "HOLY", [258] = "SHADOW" },
		DEATHKNIGHT = { [250] = "BLOOD", [251] = "FROST", [252] = "UNHOLY" },
		SHAMAN  = { [262] = "ELE", [263] = "ENH", [264] = "RESTO" },
		MAGE    = { [62] = "ARCANE", [63] = "FIRE", [64] = "FROST" },
		WARLOCK = { [265] = "AFF", [266] = "DEMO", [267] = "DESTRO" },
		MONK    = { [268] = "BREW", [269] = "WW", [270] = "MW" },
		DRUID   = { [102] = "BAL", [103] = "FERAL", [104] = "GUARD", [105] = "RESTO" },
		DEMONHUNTER = { [577] = "HAVOC", [581] = "VENGE" },
		EVOKER  = { [1467] = "DEV", [1468] = "PRES", [1473] = "AUG" },
	}

	local byClass = SPEC_TAGS[classTag]
	if byClass and byClass[specID] then return byClass[specID] end
	return tostring(specID)
end

DebugPrint = function(msg)
	if Addon and Addon.Dbg then
		Addon:Dbg("diagnostics", 3, msg)
	elseif Addon and Addon.Print then
		Addon:Print(tostring(msg))
	elseif DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
		DEFAULT_CHAT_FRAME:AddMessage("ZSBT: " .. tostring(msg))
	end
end

local function mergeSpellRulesFromTemplateEntries(entries, classTag, specTag)
	if not ZSBT.db or not ZSBT.db.char or not ZSBT.db.char.spamControl then return 0, 0 end
	local sc = ZSBT.db.char.spamControl
	sc.spellRules = sc.spellRules or {}

	local added = 0
	local missing = 0

	local function addRuleAny(spellIDs, throttleSec)
		if type(spellIDs) ~= "table" then return end
		for _, id in ipairs(spellIDs) do
			-- Do not rely on IsPlayerSpell/C_SpellBook.ContainsSpell here.
			-- On WoW 12.0 these can return secret values and prevent merges from applying.
			-- Adding rules for unknown spells is harmless (they will never match events).
			if type(id) == "number" and id > 0 then
				if sc.spellRules[id] == nil then
					sc.spellRules[id] = { enabled = true, throttleSec = throttleSec }
					added = added + 1
				end
				return
			end
		end
		missing = missing + 1
	end

	if type(entries) == "table" then
		for _, e in ipairs(entries) do
			if type(e) == "table" and type(e.throttleSec) == "number" and type(e.spellIDs) == "table" then
				addRuleAny(e.spellIDs, e.throttleSec)
			end
		end
	end

	DebugPrint(("Spell rule template applied (%s/%s): added %d rule(s)."):format(tostring(classTag), tostring(specTag), added))
	return added, missing
end

local function mergeAuraRulesFromTemplateEntries(entries, classTag, specTag)
	if not ZSBT.db or not ZSBT.db.char or not ZSBT.db.char.spamControl then return 0 end
	local sc = ZSBT.db.char.spamControl
	sc.auraRules = sc.auraRules or {}

	local added = 0
	local missing = 0

	local function addRuleAny(spellIDs, throttleSec, suppressGain, suppressFade)
		if type(spellIDs) ~= "table" then return end
		for _, id in ipairs(spellIDs) do
			if type(id) == "number" and id > 0 then
				if sc.auraRules[id] == nil then
					sc.auraRules[id] = {
						enabled = true,
						throttleSec = throttleSec or 0.00,
						suppressGain = suppressGain == true,
						suppressFade = suppressFade == true,
					}
					added = added + 1
				end
				return
			end
		end
		missing = missing + 1
	end

	if type(entries) == "table" then
		for _, e in ipairs(entries) do
			if type(e) == "table" and type(e.spellIDs) == "table" then
				addRuleAny(e.spellIDs, tonumber(e.throttleSec) or 0.00, e.suppressGain, e.suppressFade)
			end
		end
	end

	DebugPrint(("Buff rule template applied (%s/%s): added %d rule(s)."):format(tostring(classTag), tostring(specTag), added))
	return added, missing
end

function ZSBT.ApplySpellRuleTemplate_Merge(classTag, specTag)
	classTag = classTag or getPlayerClassTag()
	if not classTag then DebugPrint("ApplySpellRuleTemplate_Merge: could not detect class.") return end
	local spec = specTag or getPlayerSpecNameTag(classTag) or "COMMON"
	local byClass = ZSBT.RuleTemplates and ZSBT.RuleTemplates.spellRules and ZSBT.RuleTemplates.spellRules[classTag]
	if not byClass then DebugPrint(("No spell templates registered for %s"):format(tostring(classTag))) return end
	local common = byClass.COMMON or byClass["COMMON"]
	local specEntries = byClass[spec]
	if not common and not specEntries then
		DebugPrint(("No spell template entries for %s/%s"):format(tostring(classTag), tostring(spec)))
		return
	end
	if common then mergeSpellRulesFromTemplateEntries(common, classTag, "COMMON") end
	if specEntries then mergeSpellRulesFromTemplateEntries(specEntries, classTag, spec) end
	local ACR = LibStub("AceConfigRegistry-3.0", true)
	if ACR then ACR:NotifyChange("ZSBT_SpellRules") end
end

function ZSBT.ApplyAuraRuleTemplate_Merge(classTag, specTag)
	classTag = classTag or getPlayerClassTag()
	if not classTag then DebugPrint("ApplyAuraRuleTemplate_Merge: could not detect class.") return end
	local spec = specTag or getPlayerSpecNameTag(classTag) or "COMMON"
	local byClass = ZSBT.RuleTemplates and ZSBT.RuleTemplates.auraRules and ZSBT.RuleTemplates.auraRules[classTag]
	if not byClass then DebugPrint(("No buff templates registered for %s"):format(tostring(classTag))) return end
	local common = byClass.COMMON or byClass["COMMON"]
	local specEntries = byClass[spec]
	if not common and not specEntries then
		DebugPrint(("No buff template entries for %s/%s"):format(tostring(classTag), tostring(spec)))
		return
	end
	if common then mergeAuraRulesFromTemplateEntries(common, classTag, "COMMON") end
	if specEntries then mergeAuraRulesFromTemplateEntries(specEntries, classTag, spec) end
	local ACR = LibStub("AceConfigRegistry-3.0", true)
	if ACR then ACR:NotifyChange("ZSBT_BuffRules") end
end

function ZSBT.ApplyCurrentClassSpecTemplates_Merge()
	local classTag = getPlayerClassTag()
	if not classTag then DebugPrint("ApplyCurrentClassSpecTemplates_Merge: could not detect class.") return end
	local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
	local tpl = sc and sc.templates
	local applyAll = tpl and tpl.applyAllSpecs == true

	if applyAll then
		DebugPrint(("Applying templates for %s (ALL SPECS)..."):format(tostring(classTag)))
		local bySpell = ZSBT.RuleTemplates and ZSBT.RuleTemplates.spellRules and ZSBT.RuleTemplates.spellRules[classTag]
		if bySpell then
			if bySpell.COMMON then mergeSpellRulesFromTemplateEntries(bySpell.COMMON, classTag, "COMMON") end
			for specKey, entries in pairs(bySpell) do
				if specKey ~= "COMMON" and type(entries) == "table" then
					mergeSpellRulesFromTemplateEntries(entries, classTag, specKey)
				end
			end
		end

		local byAura = ZSBT.RuleTemplates and ZSBT.RuleTemplates.auraRules and ZSBT.RuleTemplates.auraRules[classTag]
		if byAura then
			if byAura.COMMON then mergeAuraRulesFromTemplateEntries(byAura.COMMON, classTag, "COMMON") end
			for specKey, entries in pairs(byAura) do
				if specKey ~= "COMMON" and type(entries) == "table" then
					mergeAuraRulesFromTemplateEntries(entries, classTag, specKey)
				end
			end
		end

		local ACR = LibStub("AceConfigRegistry-3.0", true)
		if ACR then
			ACR:NotifyChange("ZSBT_SpellRules")
			ACR:NotifyChange("ZSBT_BuffRules")
		end
		return
	end

	local specTag = getPlayerSpecNameTag(classTag)
	DebugPrint(("Applying templates for %s/%s..."):format(tostring(classTag), tostring(specTag)))
	ZSBT.ApplySpellRuleTemplate_Merge(classTag, specTag)
	ZSBT.ApplyAuraRuleTemplate_Merge(classTag, specTag)
end

-- Seed: migrate the existing Warrior presets into the generic template registry.
do
	local sr = ensureTemplateTable("spellRules", "WARRIOR")
	if type(sr.COMMON) ~= "table" then
		sr.COMMON = {
			{ spellIDs = {115767, 262115}, throttleSec = 0.40 }, -- Deep Wounds
			{ spellIDs = {772}, throttleSec = 0.35 },           -- Rend
			{ spellIDs = {6343}, throttleSec = 0.25 },          -- Thunder Clap
			{ spellIDs = {190411, 1680}, throttleSec = 0.20 },  -- Whirlwind
			{ spellIDs = {1464}, throttleSec = 0.15 },          -- Slam
			{ spellIDs = {163201, 5308}, throttleSec = 0.15 },  -- Execute
			{ spellIDs = {23922}, throttleSec = 0.15 },         -- Shield Slam
			{ spellIDs = {6572}, throttleSec = 0.15 },          -- Revenge
		}
	end
	if type(sr.ARMS) ~= "table" then
		sr.ARMS = {
			{ spellIDs = {12294}, throttleSec = 0.15 },          -- Mortal Strike
			{ spellIDs = {7384}, throttleSec = 0.15 },           -- Overpower
			{ spellIDs = {262161, 167105}, throttleSec = 0.25 }, -- Warbreaker / Colossus Smash
			{ spellIDs = {227847}, throttleSec = 0.40 },         -- Bladestorm
		}
	end
	if type(sr.FURY) ~= "table" then
		sr.FURY = {
			{ spellIDs = {23881}, throttleSec = 0.15 },          -- Bloodthirst
			{ spellIDs = {85288}, throttleSec = 0.15 },          -- Raging Blow
			{ spellIDs = {184367}, throttleSec = 0.25 },         -- Rampage
			{ spellIDs = {280735}, throttleSec = 0.35 },         -- Siegebreaker
		}
	end
	if type(sr.PROT) ~= "table" then
		sr.PROT = {
			{ spellIDs = {20243}, throttleSec = 0.25 },          -- Devastate
			{ spellIDs = {46968}, throttleSec = 0.35 },          -- Shockwave
		}
	end
end

-- Seed: conservative starter spell templates for other classes/specs.
-- NOTE: IDs vary across expansions; we use small candidate lists and only apply what the player actually knows.
do
	local function seedSpell(classTag, specTag, entries)
		local t = ensureTemplateTable("spellRules", classTag)
		if type(t[specTag]) ~= "table" then
			t[specTag] = entries
		end
	end

	-- DEATHKNIGHT
	seedSpell("DEATHKNIGHT", "COMMON", {
		{ spellIDs = {55078}, throttleSec = 0.35 }, -- Blood Plague
		{ spellIDs = {55095}, throttleSec = 0.35 }, -- Frost Fever
		{ spellIDs = {49998}, throttleSec = 0.20 }, -- Death Strike
		{ spellIDs = {47541}, throttleSec = 0.20 }, -- Death Coil
		{ spellIDs = {43265, 52212}, throttleSec = 0.35 }, -- Death and Decay
	})
	seedSpell("DEATHKNIGHT", "BLOOD", {
		{ spellIDs = {50842}, throttleSec = 0.35 }, -- Blood Boil
		{ spellIDs = {206930}, throttleSec = 0.45 }, -- Heart Strike (varies; harmless if missing)
	})
	seedSpell("DEATHKNIGHT", "FROST", {
		{ spellIDs = {49143}, throttleSec = 0.25 }, -- Frost Strike
		{ spellIDs = {49184}, throttleSec = 0.25 }, -- Howling Blast
	})
	seedSpell("DEATHKNIGHT", "UNHOLY", {
		{ spellIDs = {77575}, throttleSec = 0.25 }, -- Outbreak
		{ spellIDs = {85948}, throttleSec = 0.30 }, -- Festering Strike
	})

	-- DEMONHUNTER
	seedSpell("DEMONHUNTER", "COMMON", {
		{ spellIDs = {258920}, throttleSec = 0.35 }, -- Immolation Aura
		{ spellIDs = {162243}, throttleSec = 0.25 }, -- Demon's Bite
		{ spellIDs = {210153}, throttleSec = 0.25 }, -- Death Sweep
		{ spellIDs = {198013}, throttleSec = 0.45 }, -- Eye Beam
	})
	seedSpell("DEMONHUNTER", "HAVOC", {
		{ spellIDs = {258921, 258860}, throttleSec = 0.35 }, -- Fel Barrage / similar
		{ spellIDs = {201427}, throttleSec = 0.30 }, -- Annihilation
	})
	seedSpell("DEMONHUNTER", "VENGE", {
		{ spellIDs = {189112}, throttleSec = 0.35 }, -- Infernal Strike
	})

	-- DRUID
	seedSpell("DRUID", "COMMON", {
		{ spellIDs = {8921}, throttleSec = 0.30 }, -- Moonfire
		{ spellIDs = {93402}, throttleSec = 0.30 }, -- Sunfire
		{ spellIDs = {77758}, throttleSec = 0.35 }, -- Thrash
		{ spellIDs = {1079}, throttleSec = 0.35 }, -- Rip
		{ spellIDs = {1822}, throttleSec = 0.25 }, -- Rake
	})
	seedSpell("DRUID", "BAL", {
		{ spellIDs = {190984}, throttleSec = 0.35 }, -- Solar Wrath
		{ spellIDs = {194153}, throttleSec = 0.35 }, -- Lunar Strike
	})
	seedSpell("DRUID", "FERAL", {
		{ spellIDs = {5221}, throttleSec = 0.25 }, -- Shred
		{ spellIDs = {22568}, throttleSec = 0.25 }, -- Ferocious Bite
	})
	seedSpell("DRUID", "GUARD", {
		{ spellIDs = {6807}, throttleSec = 0.25 }, -- Maul
		{ spellIDs = {192090}, throttleSec = 0.35 }, -- Thrash (Guardian alt)
	})
	seedSpell("DRUID", "RESTO", {
		{ spellIDs = {48438}, throttleSec = 0.45 }, -- Wild Growth
		{ spellIDs = {774}, throttleSec = 0.30 }, -- Rejuvenation
	})

	-- EVOKER
	seedSpell("EVOKER", "COMMON", {
		{ spellIDs = {356995}, throttleSec = 0.30 }, -- Disintegrate
		{ spellIDs = {357208}, throttleSec = 0.45 }, -- Fire Breath
		{ spellIDs = {361469}, throttleSec = 0.35 }, -- Living Flame
	})
	seedSpell("EVOKER", "DEV", {
		{ spellIDs = {359073}, throttleSec = 0.40 }, -- Eternity Surge
	})
	seedSpell("EVOKER", "PRES", {
		{ spellIDs = {367226}, throttleSec = 0.50 }, -- Spiritbloom
		{ spellIDs = {361469}, throttleSec = 0.35 }, -- Living Flame (heals)
	})
	seedSpell("EVOKER", "AUG", {
		{ spellIDs = {395152}, throttleSec = 0.45 }, -- Eruption
	})

	-- HUNTER
	seedSpell("HUNTER", "COMMON", {
		{ spellIDs = {75}, throttleSec = 0.20 }, -- Auto Shot
		{ spellIDs = {2643}, throttleSec = 0.25 }, -- Multi-Shot
		{ spellIDs = {56641}, throttleSec = 0.25 }, -- Steady Shot
		{ spellIDs = {1978, 271788}, throttleSec = 0.35 }, -- Serpent Sting (varies)
	})
	seedSpell("HUNTER", "BM", {
		{ spellIDs = {34026}, throttleSec = 0.25 }, -- Kill Command
		{ spellIDs = {193455}, throttleSec = 0.35 }, -- Cobra Shot
	})
	seedSpell("HUNTER", "MM", {
		{ spellIDs = {19434}, throttleSec = 0.35 }, -- Aimed Shot
		{ spellIDs = {257620}, throttleSec = 0.35 }, -- Multi-Shot / Trick Shots related
	})
	seedSpell("HUNTER", "SV", {
		{ spellIDs = {259387}, throttleSec = 0.30 }, -- Mongoose Bite
		{ spellIDs = {271014}, throttleSec = 0.35 }, -- Wildfire Bomb
	})

	-- MAGE
	seedSpell("MAGE", "COMMON", {
		{ spellIDs = {1449}, throttleSec = 0.30 }, -- Arcane Explosion
		{ spellIDs = {5143}, throttleSec = 0.35 }, -- Arcane Missiles
		{ spellIDs = {116}, throttleSec = 0.25 }, -- Frostbolt
		{ spellIDs = {133}, throttleSec = 0.25 }, -- Fireball
		{ spellIDs = {30455}, throttleSec = 0.25 }, -- Ice Lance
		{ spellIDs = {108853}, throttleSec = 0.25 }, -- Fire Blast
		{ spellIDs = {190356}, throttleSec = 0.45 }, -- Blizzard
	})
	seedSpell("MAGE", "ARCANE", {
		{ spellIDs = {30451}, throttleSec = 0.25 }, -- Arcane Blast
		{ spellIDs = {44425}, throttleSec = 0.35 }, -- Arcane Barrage
	})
	seedSpell("MAGE", "FIRE", {
		{ spellIDs = {11366}, throttleSec = 0.35 }, -- Pyroblast
		{ spellIDs = {2120}, throttleSec = 0.45 }, -- Flamestrike
	})
	seedSpell("MAGE", "FROST", {
		{ spellIDs = {44614}, throttleSec = 0.35 }, -- Flurry
		{ spellIDs = {84714}, throttleSec = 0.40 }, -- Frozen Orb
	})

	-- MONK
	seedSpell("MONK", "COMMON", {
		{ spellIDs = {100780}, throttleSec = 0.25 }, -- Tiger Palm
		{ spellIDs = {100784}, throttleSec = 0.25 }, -- Blackout Kick
		{ spellIDs = {101546}, throttleSec = 0.35 }, -- Spinning Crane Kick
	})
	seedSpell("MONK", "BREW", {
		{ spellIDs = {121253}, throttleSec = 0.35 }, -- Keg Smash
		{ spellIDs = {115181}, throttleSec = 0.35 }, -- Breath of Fire
	})
	seedSpell("MONK", "WW", {
		{ spellIDs = {107428}, throttleSec = 0.30 }, -- Rising Sun Kick
		{ spellIDs = {113656}, throttleSec = 0.30 }, -- Fists of Fury
	})
	seedSpell("MONK", "MW", {
		{ spellIDs = {116670}, throttleSec = 0.40 }, -- Vivify
		{ spellIDs = {115175}, throttleSec = 0.45 }, -- Soothing Mist
	})

	-- PALADIN
	seedSpell("PALADIN", "COMMON", {
		{ spellIDs = {26573}, throttleSec = 0.35 }, -- Consecration
		{ spellIDs = {20271}, throttleSec = 0.25 }, -- Judgment
		{ spellIDs = {35395}, throttleSec = 0.25 }, -- Crusader Strike
		{ spellIDs = {53595}, throttleSec = 0.30 }, -- Hammer of the Righteous
	})
	seedSpell("PALADIN", "HOLY", {
		{ spellIDs = {20473}, throttleSec = 0.40 }, -- Holy Shock
		{ spellIDs = {85222}, throttleSec = 0.45 }, -- Light of Dawn
	})
	seedSpell("PALADIN", "PROT", {
		{ spellIDs = {31935}, throttleSec = 0.35 }, -- Avenger's Shield
		{ spellIDs = {53600}, throttleSec = 0.30 }, -- Shield of the Righteous
	})
	seedSpell("PALADIN", "RET", {
		{ spellIDs = {85256}, throttleSec = 0.25 }, -- Templar's Verdict
		{ spellIDs = {53385}, throttleSec = 0.35 }, -- Divine Storm
	})

	-- PRIEST
	seedSpell("PRIEST", "COMMON", {
		{ spellIDs = {589}, throttleSec = 0.35 }, -- Shadow Word: Pain
		{ spellIDs = {34914}, throttleSec = 0.35 }, -- Vampiric Touch
		{ spellIDs = {15407}, throttleSec = 0.35 }, -- Mind Flay
	})
	seedSpell("PRIEST", "DISC", {
		{ spellIDs = {47540}, throttleSec = 0.35 }, -- Penance
		{ spellIDs = {585}, throttleSec = 0.25 }, -- Smite
	})
	seedSpell("PRIEST", "HOLY", {
		{ spellIDs = {2061}, throttleSec = 0.30 }, -- Flash Heal
		{ spellIDs = {34861}, throttleSec = 0.45 }, -- Sanctify
	})
	seedSpell("PRIEST", "SHADOW", {
		{ spellIDs = {8092}, throttleSec = 0.35 }, -- Mind Blast
		{ spellIDs = {228260}, throttleSec = 0.45 }, -- Void Eruption
	})

	-- ROGUE
	seedSpell("ROGUE", "COMMON", {
		{ spellIDs = {1752}, throttleSec = 0.20 }, -- Sinister Strike
		{ spellIDs = {1943}, throttleSec = 0.35 }, -- Rupture
		{ spellIDs = {196819}, throttleSec = 0.35 }, -- Eviscerate (alt)
	})
	seedSpell("ROGUE", "ASSASS", {
		{ spellIDs = {703}, throttleSec = 0.35 }, -- Garrote
		{ spellIDs = {121411}, throttleSec = 0.35 }, -- Crimson Tempest
	})
	seedSpell("ROGUE", "OUTLAW", {
		{ spellIDs = {193315}, throttleSec = 0.25 }, -- Saber Slash
		{ spellIDs = {185763}, throttleSec = 0.35 }, -- Pistol Shot
	})
	seedSpell("ROGUE", "SUB", {
		{ spellIDs = {53}, throttleSec = 0.25 }, -- Backstab
		{ spellIDs = {196819, 32645}, throttleSec = 0.35 }, -- Eviscerate/Ambush alt
	})

	-- SHAMAN
	seedSpell("SHAMAN", "COMMON", {
		{ spellIDs = {188389}, throttleSec = 0.35 }, -- Flame Shock
		{ spellIDs = {188443, 421}, throttleSec = 0.40 }, -- Chain Lightning
		{ spellIDs = {403}, throttleSec = 0.30 }, -- Lightning Bolt
	})
	seedSpell("SHAMAN", "ELE", {
		{ spellIDs = {51505}, throttleSec = 0.40 }, -- Lava Burst
		{ spellIDs = {61882}, throttleSec = 0.45 }, -- Earthquake
	})
	seedSpell("SHAMAN", "ENH", {
		{ spellIDs = {17364}, throttleSec = 0.25 }, -- Stormstrike
		{ spellIDs = {60103}, throttleSec = 0.35 }, -- Lava Lash
	})
	seedSpell("SHAMAN", "RESTO", {
		{ spellIDs = {1064}, throttleSec = 0.45 }, -- Chain Heal
		{ spellIDs = {61295}, throttleSec = 0.45 }, -- Riptide
	})

	-- WARLOCK
	seedSpell("WARLOCK", "COMMON", {
	})
	seedSpell("WARLOCK", "AFF", {
		{ spellIDs = {172}, throttleSec = 0.35 }, -- Corruption
		{ spellIDs = {980}, throttleSec = 0.35 }, -- Agony
		{ spellIDs = {30108}, throttleSec = 0.45 }, -- Unstable Affliction (legacy)
		{ spellIDs = {198590}, throttleSec = 0.35 }, -- Drain Soul
		{ spellIDs = {205180}, throttleSec = 0.45 }, -- Summon Darkglare
	})
	seedSpell("WARLOCK", "DEMO", {
		{ spellIDs = {686}, throttleSec = 0.25 }, -- Shadow Bolt
		{ spellIDs = {105174}, throttleSec = 0.30 }, -- Hand of Gul'dan
		{ spellIDs = {104316}, throttleSec = 0.35 }, -- Call Dreadstalkers
	})
	seedSpell("WARLOCK", "DESTRO", {
		{ spellIDs = {348}, throttleSec = 0.35 }, -- Immolate
		{ spellIDs = {29722}, throttleSec = 0.35 }, -- Incinerate
		{ spellIDs = {116858}, throttleSec = 0.40 }, -- Chaos Bolt
		{ spellIDs = {5740}, throttleSec = 0.45 }, -- Rain of Fire
	})

	-- Add a minimal aura template baseline (conservative): common long-term buffs that are often noisy.
	local function seedAura(classTag, specTag, entries)
		local t = ensureTemplateTable("auraRules", classTag)
		if type(t[specTag]) ~= "table" then
			t[specTag] = entries
		end
	end
	seedAura("MAGE", "COMMON", {
		{ spellIDs = {1459}, throttleSec = 1.00, suppressGain = true, suppressFade = true }, -- Arcane Intellect
	})
	seedAura("MAGE", "ARCANE", {
		{ spellIDs = {12042}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("MAGE", "FIRE", {
		{ spellIDs = {190319}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("MAGE", "FROST", {
		{ spellIDs = {12472}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("PRIEST", "COMMON", {
		{ spellIDs = {21562}, throttleSec = 1.00, suppressGain = true, suppressFade = true }, -- Power Word: Fortitude
	})
	seedAura("PRIEST", "DISC", {
		{ spellIDs = {10060}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {194384}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("PRIEST", "HOLY", {
		{ spellIDs = {200183}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("PRIEST", "SHADOW", {
		{ spellIDs = {194249, 391109}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("WARRIOR", "COMMON", {
		{ spellIDs = {6673}, throttleSec = 1.00, suppressGain = true, suppressFade = true }, -- Battle Shout
		{ spellIDs = {1719}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {260708}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("WARRIOR", "PROT", {
		{ spellIDs = {871}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {2565}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {1160}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("DRUID", "COMMON", {
		{ spellIDs = {1126}, throttleSec = 1.00, suppressGain = true, suppressFade = true }, -- Mark of the Wild
	})
	seedAura("DRUID", "BAL", {
		{ spellIDs = {194223}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {194223, 102560}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("DRUID", "FERAL", {
		{ spellIDs = {5217}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {106951}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("DRUID", "GUARD", {
		{ spellIDs = {192081}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {22812}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("DRUID", "RESTO", {
		{ spellIDs = {33891}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {102342}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("PALADIN", "COMMON", {
		{ spellIDs = {465, 19746}, throttleSec = 1.00, suppressGain = true, suppressFade = true },
	})
	seedAura("PALADIN", "HOLY", {
		{ spellIDs = {31884}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {216331}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("PALADIN", "PROT", {
		{ spellIDs = {31850}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {86659}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("PALADIN", "RET", {
		{ spellIDs = {31884}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {231895}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("HUNTER", "COMMON", {
		{ spellIDs = {19506}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("HUNTER", "BM", {
		{ spellIDs = {19574}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {193530}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("HUNTER", "MM", {
		{ spellIDs = {288613}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {260402}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("HUNTER", "SV", {
		{ spellIDs = {266779}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("ROGUE", "COMMON", {
		{ spellIDs = {1966}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("ROGUE", "ASSASS", {
		{ spellIDs = {121471}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {32645, 360194}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("ROGUE", "OUTLAW", {
		{ spellIDs = {315496}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("ROGUE", "SUB", {
		{ spellIDs = {185422}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("SHAMAN", "COMMON", {
		{ spellIDs = {2825, 32182}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("SHAMAN", "ELE", {
		{ spellIDs = {114050}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("SHAMAN", "ENH", {
		{ spellIDs = {30823}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("SHAMAN", "RESTO", {
		{ spellIDs = {16191}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("WARLOCK", "COMMON", {
		{ spellIDs = {104773}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("WARLOCK", "AFF", {
		{ spellIDs = {113860}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("WARLOCK", "DEMO", {
		{ spellIDs = {196099}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("WARLOCK", "DESTRO", {
	})
	seedAura("DEATHKNIGHT", "COMMON", {
		{ spellIDs = {48792}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("DEATHKNIGHT", "BLOOD", {
		{ spellIDs = {55233}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("DEATHKNIGHT", "FROST", {
		{ spellIDs = {51271}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("DEATHKNIGHT", "UNHOLY", {
	})
	seedAura("DEMONHUNTER", "HAVOC", {
		{ spellIDs = {162264}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("DEMONHUNTER", "VENGE", {
		{ spellIDs = {203720}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {204021}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("MONK", "BREW", {
		{ spellIDs = {115308}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
		{ spellIDs = {215479}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("MONK", "WW", {
		{ spellIDs = {137639}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("MONK", "MW", {
		{ spellIDs = {197908}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("EVOKER", "DEV", {
		{ spellIDs = {375087}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("EVOKER", "PRES", {
		{ spellIDs = {370537}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
	seedAura("EVOKER", "AUG", {
		{ spellIDs = {404977, 406732}, throttleSec = 1.00, suppressGain = false, suppressFade = true },
	})
end


------------------------------------------------------------------------
-- TAB 0: QUICK START
-- Setup-first tab with the most common controls and actions.
------------------------------------------------------------------------
function ZSBT.BuildTab_QuickStart()
	local function general()
		return ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
	end

	local function core()
		return ZSBT and ZSBT.Core or nil
	end

	local function notify()
		local reg = LibStub and LibStub("AceConfigRegistry-3.0", true)
		if reg and reg.NotifyChange then
			reg:NotifyChange("ZSBT")
		end
	end

	local function toggleUnlock()
		if ZSBT and ZSBT.IsScrollAreasUnlocked and ZSBT.IsScrollAreasUnlocked() then
			if ZSBT.HideScrollAreaFrames then ZSBT.HideScrollAreaFrames() end
			return
		end
		if ZSBT and ZSBT.ShowScrollAreaFrames then ZSBT.ShowScrollAreaFrames() end
	end

	local function testNotifications()
		if ZSBT and ZSBT.TestScrollArea then
			ZSBT.TestScrollArea("Notifications")
		end
	end

	local function testIncoming()
		if ZSBT and ZSBT.TestIncomingDamageCrit then
			ZSBT.TestIncomingDamageCrit()
		end
		if ZSBT and ZSBT.TestIncomingHealCrit then
			ZSBT.TestIncomingHealCrit()
		end
	end

	local function testOutgoing()
		if not (ZSBT and ZSBT.TestScrollAreaCrit) then return end
		local areaToTest = "Outgoing"
		local oc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.outgoing and ZSBT.db.profile.outgoing.crits
		if oc and oc.enabled == true and type(oc.scrollArea) == "string" and oc.scrollArea ~= "" then
			areaToTest = oc.scrollArea
		end
		ZSBT.TestScrollAreaCrit(areaToTest)
	end

	return {
		type  = "group",
		name  = "|cFFFFD100Quick Start|r",
		order = 0.5,
		args  = {
			header = { type = "header", name = "Quick Start", order = 1 },
			desc = {
				type = "description",
				name = "Get ZSBT working quickly: enable output, place scroll areas, and test.",
				order = 2,
				fontSize = "medium",
			},

			masterHeader = { type = "header", name = "Master Controls", order = 10 },
			enabled = {
				type = "toggle",
				name = "Enable ZSBT",
				desc = "Master switch to enable or disable all ZSBT output.",
				width = "full",
				order = 11,
				get = function()
					local g = general(); return g and g.enabled == true
				end,
				set = function(_, v)
					local g = general(); if not g then return end
					g.enabled = v and true or false
					local c = core(); if c and c.SetEnabled then c:SetEnabled(g.enabled == true) end
					notify()
				end,
			},
			combatOnly = {
				type = "toggle",
				name = "Combat Only Mode",
				desc = "Only display ZSBT output while you are in combat.",
				width = "full",
				order = 12,
				get = function()
					local g = general(); return g and g.combatOnly == true
				end,
				set = function(_, v)
					local g = general(); if not g then return end
					g.combatOnly = v and true or false
					notify()
				end,
			},

			blizzardHeader = { type = "header", name = "Blizzard Combat Text", order = 20 },
			hideBlizzardFCT = {
				type = "toggle",
				name = "Hide Blizzard Combat Text",
				desc = "Controls whether ZSBT hides Blizzard combat text.\n\nThis modifies Blizzard CVars, which persist even if you disable or uninstall ZSBT. Turn this off to restore Blizzard combat text.",
				order = 21,
				width = "full",
				get = function()
					local g = general(); if not g then return false end
					if g.hideBlizzardFCT ~= nil then return g.hideBlizzardFCT == true end
					local mode = g.blizzardFCTSuppressMode
					if mode == nil then
						return g.suppressBlizzardFCT == true
					end
					return mode ~= "none"
				end,
				set = function(_, v)
					local g = general(); if not g then return end
					g.hideBlizzardFCT = v and true or false
					local c = core(); if c and c.ApplyBlizzardFCTCVars then c:ApplyBlizzardFCTCVars() end
					notify()
				end,
			},
			hideBlizzardFCTOutgoing = {
				type = "toggle",
				name = "Hide Blizzard Outgoing Damage",
				order = 21.1,
				width = "full",
				hidden = function() local g = general(); return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = general(); return g and g.hideBlizzardFCTOutgoing ~= false end,
				set = function(_, v)
					local g = general(); if not g then return end
					g.hideBlizzardFCTOutgoing = v and true or false
					local c = core(); if c and c.ApplyBlizzardFCTCVars then c:ApplyBlizzardFCTCVars() end
					notify()
				end,
			},
			hideBlizzardFCTIncomingDamage = {
				type = "toggle",
				name = "Hide Blizzard Incoming Damage",
				order = 21.2,
				width = "full",
				hidden = function() local g = general(); return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = general(); return g and g.hideBlizzardFCTIncomingDamage ~= false end,
				set = function(_, v)
					local g = general(); if not g then return end
					g.hideBlizzardFCTIncomingDamage = v and true or false
					local c = core(); if c and c.ApplyBlizzardFCTCVars then c:ApplyBlizzardFCTCVars() end
					notify()
				end,
			},
			hideBlizzardFCTIncomingHealing = {
				type = "toggle",
				name = "Hide Blizzard Incoming Healing",
				order = 21.3,
				width = "full",
				hidden = function() local g = general(); return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = general(); return g and g.hideBlizzardFCTIncomingHealing ~= false end,
				set = function(_, v)
					local g = general(); if not g then return end
					g.hideBlizzardFCTIncomingHealing = v and true or false
					local c = core(); if c and c.ApplyBlizzardFCTCVars then c:ApplyBlizzardFCTCVars() end
					notify()
				end,
			},
			hideBlizzardFCTReactives = {
				type = "toggle",
				name = "Hide Blizzard Reactives / Procs",
				order = 21.4,
				width = "full",
				hidden = function() local g = general(); return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = general(); return g and g.hideBlizzardFCTReactives ~= false end,
				set = function(_, v)
					local g = general(); if not g then return end
					g.hideBlizzardFCTReactives = v and true or false
					local c = core(); if c and c.ApplyBlizzardFCTCVars then c:ApplyBlizzardFCTCVars() end
					notify()
				end,
			},
			hideBlizzardFCTXPRepHonor = {
				type = "toggle",
				name = "Hide Blizzard XP / Rep / Honor",
				order = 21.5,
				width = "full",
				hidden = function() local g = general(); return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = general(); return g and g.hideBlizzardFCTXPRepHonor ~= false end,
				set = function(_, v)
					local g = general(); if not g then return end
					g.hideBlizzardFCTXPRepHonor = v and true or false
					local c = core(); if c and c.ApplyBlizzardFCTCVars then c:ApplyBlizzardFCTCVars() end
					notify()
				end,
			},
			hideBlizzardFCTResourceGains = {
				type = "toggle",
				name = "Hide Blizzard Resource Gains",
				order = 21.6,
				width = "full",
				hidden = function() local g = general(); return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = general(); return g and g.hideBlizzardFCTResourceGains ~= false end,
				set = function(_, v)
					local g = general(); if not g then return end
					g.hideBlizzardFCTResourceGains = v and true or false
					local c = core(); if c and c.ApplyBlizzardFCTCVars then c:ApplyBlizzardFCTCVars() end
					notify()
				end,
			},
			hideBlizzardFCTPet = {
				type = "toggle",
				name = "Hide Blizzard Pet Combat Text",
				order = 21.7,
				width = "full",
				hidden = function() local g = general(); return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = general(); return g and g.hideBlizzardFCTPet ~= false end,
				set = function(_, v)
					local g = general(); if not g then return end
					g.hideBlizzardFCTPet = v and true or false
					local c = core(); if c and c.ApplyBlizzardFCTCVars then c:ApplyBlizzardFCTCVars() end
					notify()
				end,
			},
			restoreBlizzardFCTNow = {
				type = "execute",
				name = "Restore Blizzard Combat Text Now",
				desc = "Restore Blizzard combat text now (panic button).",
				order = 22,
				width = "full",
				disabled = function()
					local g = general(); if not g then return true end
					if g.hideBlizzardFCT == true then return false end
					local mode = g.blizzardFCTSuppressMode
					if mode == nil then return g.suppressBlizzardFCT ~= true end
					return mode == "none"
				end,
				func = function()
					local c = core(); if c and c.RestoreBlizzardFCT then c:RestoreBlizzardFCT() end
				end,
			},

			scrollAreaHeader = { type = "header", name = "Scroll Areas", order = 30 },
			unlockScrollAreas = {
				type = "execute",
				name = function()
					if ZSBT and ZSBT.IsScrollAreasUnlocked and ZSBT.IsScrollAreasUnlocked() then
						return "Lock Scroll Areas"
					end
					return "Unlock Scroll Areas"
				end,
				desc = "Show draggable frames on screen for each scroll area. Drag to reposition, then lock to save.",
				order = 31,
				width = "full",
				func = function() toggleUnlock(); notify() end,
			},
			testNotifications = {
				type = "execute",
				name = "Test Notifications",
				desc = "Fire test text into the Notifications scroll area.",
				order = 32,
				width = "full",
				func = function() testNotifications() end,
			},
			testIncoming = {
				type = "execute",
				name = "Test Incoming",
				desc = "Fire test incoming damage/heal text into your configured Incoming areas.",
				order = 33,
				width = "full",
				func = function() testIncoming() end,
			},
			testOutgoing = {
				type = "execute",
				name = "Test Outgoing",
				desc = "Fire test outgoing text into your configured Outgoing areas.",
				order = 34,
				width = "full",
				func = function() testOutgoing() end,
			},

			quickBarHeader = { type = "header", name = "Quick Control Bar", order = 40 },
			quickControlBarEnabled = {
				type = "toggle",
				name = "Enable Quick Control Bar",
				desc = "Show a draggable on-screen bar for quickly toggling instance/open-world tuning settings and unlocking scroll areas.",
				order = 41,
				width = "full",
				get = function()
					local g = general(); return g and g.quickControlBarEnabled == true
				end,
				set = function(_, v)
					local g = general(); if not g then return end
					g.quickControlBarEnabled = v and true or false
					local qb = ZSBT and ZSBT.UI and ZSBT.UI.QuickControlBar
					if qb and qb.Init then qb:Init() end
					if qb and qb.RefreshVisibility then qb:RefreshVisibility() end
					notify()
				end,
			},
			quickControlBarResetPos = {
				type = "execute",
				name = "Reset Quick Control Bar Position",
				desc = "Reset the Quick Control Bar position to the default.",
				order = 41.1,
				width = "full",
				disabled = function()
					local g = general(); return not (g and g.quickControlBarEnabled == true)
				end,
				func = function()
					local qb = ZSBT and ZSBT.UI and ZSBT.UI.QuickControlBar
					if qb and qb.ResetPosition then
						qb:ResetPosition()
					elseif qb and qb._frame then
						local g = general()
						if g then
							g.quickControlBarPos = { x = 0, y = 220 }
						end
						if qb.Init then qb:Init() end
					end
					notify()
				end,
			},
		},
	}
end

------------------------------------------------------------------------
-- TAB 0.5: DISPLAY
-- Consolidated entry point for Scroll Areas + Media.
------------------------------------------------------------------------
function ZSBT.BuildTab_Display()
	local sa = ZSBT.BuildTab_ScrollAreas and ZSBT.BuildTab_ScrollAreas() or nil
	local media = ZSBT.BuildTab_Media and ZSBT.BuildTab_Media() or nil
	if type(sa) == "table" then
		sa.order = 1
		sa.name = "|cFFFFD100Scroll Areas|r"
	end
	if type(media) == "table" then
		media.order = 2
		media.name = "|cFFFFD100Media|r"
	end

	return {
		type = "group",
		name = "|cFFFFD100Display|r",
		order = 0.7,
		childGroups = "tree",
		args = {
			scrollAreas = sa or { type = "group", name = "|cFFFFD100Scroll Areas|r", order = 1, args = {} },
			media = media or { type = "group", name = "|cFFFFD100Media|r", order = 2, args = {} },
		},
	}
end

------------------------------------------------------------------------
-- TAB 0.75: ALERTS
-- Consolidated entry point for Notifications + Triggers + Cooldowns.
------------------------------------------------------------------------
function ZSBT.BuildTab_Alerts()
	local notifications = ZSBT.BuildTab_Notifications and ZSBT.BuildTab_Notifications() or nil
	local triggers = ZSBT.BuildTab_Triggers and ZSBT.BuildTab_Triggers() or nil
	local cooldowns = ZSBT.BuildTab_Cooldowns and ZSBT.BuildTab_Cooldowns() or nil
	if type(notifications) == "table" then
		notifications.order = 1
		notifications.name = "|cFFFFD100Notifications|r"
	end
	if type(triggers) == "table" then
		triggers.order = 2
		triggers.name = "|cFFFFD100Triggers|r"
	end
	if type(cooldowns) == "table" then
		cooldowns.order = 3
		cooldowns.name = "|cFFFFD100Cooldowns|r"
	end

	return {
		type = "group",
		name = "|cFFFFD100Alerts|r",
		order = 0.85,
		childGroups = "tree",
		args = {
			notifications = notifications or { type = "group", name = "|cFFFFD100Notifications|r", order = 1, args = {} },
			triggers = triggers or { type = "group", name = "|cFFFFD100Triggers|r", order = 2, args = {} },
			cooldowns = cooldowns or { type = "group", name = "|cFFFFD100Cooldowns|r", order = 3, args = {} },
		},
	}
end

------------------------------------------------------------------------
-- TAB 0.9: COMBAT TEXT
-- Consolidated entry point for Incoming + Outgoing + Pets + Spam Control.
------------------------------------------------------------------------
function ZSBT.BuildTab_CombatText()
	local incoming = ZSBT.BuildTab_Incoming and ZSBT.BuildTab_Incoming() or nil
	local outgoing = ZSBT.BuildTab_Outgoing and ZSBT.BuildTab_Outgoing() or nil
	local pets = ZSBT.BuildTab_Pets and ZSBT.BuildTab_Pets() or nil
	local spamControl = ZSBT.BuildTab_SpamControl and ZSBT.BuildTab_SpamControl() or nil
	if type(incoming) == "table" then
		incoming.order = 1
		incoming.name = "|cFFFFD100Incoming|r"
	end
	if type(outgoing) == "table" then
		outgoing.order = 2
		outgoing.name = "|cFFFFD100Outgoing|r"
	end
	if type(pets) == "table" then
		pets.order = 3
		pets.name = "|cFFFFD100Pets|r"
	end
	if type(spamControl) == "table" then
		spamControl.order = 4
		spamControl.name = "|cFFFFD100Spam Control|r"
	end

	return {
		type = "group",
		name = "|cFFFFD100Combat Text|r",
		order = 0.9,
		childGroups = "tree",
		args = {
			incoming = incoming or { type = "group", name = "|cFFFFD100Incoming|r", order = 1, args = {} },
			outgoing = outgoing or { type = "group", name = "|cFFFFD100Outgoing|r", order = 2, args = {} },
			pets = pets or { type = "group", name = "|cFFFFD100Pets|r", order = 3, args = {} },
			spamControl = spamControl or { type = "group", name = "|cFFFFD100Spam Control|r", order = 4, args = {} },
		},
	}
end

------------------------------------------------------------------------
-- TAB 2: PROFILES
-- Consolidated entry point for Import/Export + DB Profiles.
-- DB Profiles content is injected by Init.lua after DB creation.
------------------------------------------------------------------------
function ZSBT.BuildTab_ProfilesRoot()
	local importExport = ZSBT.BuildTab_Profiles and ZSBT.BuildTab_Profiles() or nil
	if type(importExport) == "table" then
		importExport.order = 1
		importExport.name = "|cFFFFD100Import / Export|r"
	end

	return {
		type = "group",
		name = "|cFFFFD100Profiles|r",
		order = 2.0,
		childGroups = "tree",
		args = {
			importExport = importExport or { type = "group", name = "|cFFFFD100Import / Export|r", order = 1, args = {} },
			acedbProfiles = { type = "group", name = "|cFFFFD100DB Profiles|r", order = 2, args = {} },
		},
	}
end

------------------------------------------------------------------------
-- TAB 9: MAINTENANCE
-- Container for Help/Troubleshooting and other operational tools.
------------------------------------------------------------------------
function ZSBT.BuildTab_Maintenance()
	return {
		type = "group",
		name = "|cFFFFD100Maintenance|r",
		order = 9,
		childGroups = "tree",
		args = {},
	}
end

-------------------------------------------------------------------------
-- TAB 1: GENERAL
-- Master font, global behavior, quick actions, profile management.
-------------------------------------------------------------------------
function ZSBT.BuildTab_General()
    return {
        type  = "group",
		name  = "|cFFFFD100General|r",
        order = 0.6,
        args  = {
            -- Branded header
            brandHeader = {
                type  = "description",
				name  = "|cFFFFD100Zore's|r |cFFEBF0F5Scrolling Battle Text|r\n" ..
						"|cFF808C9Eby " .. (ZSBT.ADDON_AUTHOR or "Zorellion") .. "  |  /zsbt  |  v" .. (ZSBT.VERSION or "1.0") .. "|r",
				fontSize = "large",
				order = 0,
				width = "full",
			},
            brandSpacer = {
                type = "description",
                name = " ",
                order = 0.5,
                width = "full",
            },
            headerMaster = {
                type  = "header",
				name  = "|cFFFFD100System|r",
                order = 1,
            },
            enabled = {
                type  = "toggle",
                name  = "|cFFEBF0F5Enable ZSBT|r",
                desc  = "Master switch to enable or disable all ZSBT output.",
                width = "full",
                order = 2,
                get   = function() return ZSBT.db.profile.general.enabled end,
                set   = function(_, val)
                    ZSBT.db.profile.general.enabled = val

                    -- Drive runtime gating immediately (safe no-ops in skeleton layers).
                    if ZSBT.Core then
                        if val and ZSBT.Core.Enable then ZSBT.Core:Enable() end
                        if (not val) and ZSBT.Core.Disable then ZSBT.Core:Disable() end
                    end

                    if ZSBT.Parser then
                        if val then
                            if ZSBT.Parser.CombatLog and ZSBT.Parser.CombatLog.Enable then
                                ZSBT.Parser.CombatLog:Enable()
                            end
                            if ZSBT.Parser.Cooldowns and ZSBT.Parser.Cooldowns.Enable then
                                ZSBT.Parser.Cooldowns:Enable()
                            end
                        else
                            if ZSBT.Parser.Cooldowns and ZSBT.Parser.Cooldowns.Disable then
                                ZSBT.Parser.Cooldowns:Disable()
                            end
                            if ZSBT.Parser.CombatLog and ZSBT.Parser.CombatLog.Disable then
                                ZSBT.Parser.CombatLog:Disable()
                            end
                        end
                    end

                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            combatOnly = {
                type  = "toggle",
                name  = "Combat Only Mode",
                desc  = "Only display ZSBT output while you are in combat.",
                width = "full",
                order = 3,
                get   = function() return ZSBT.db.profile.general.combatOnly end,
                set   = function(_, val)
                    ZSBT.db.profile.general.combatOnly = val
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },

			hideBlizzardFCT = {
				type = "toggle",
				name = "Hide Blizzard Combat Text",
				desc = "Controls whether ZSBT hides Blizzard combat text.",
				order = 3.5,
				width = "full",
				get = function()
					local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					return g and g.hideBlizzardFCT == true
				end,
				set = function(_, v)
					local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					if not g then return end
					g.hideBlizzardFCT = v and true or false
					if ZSBT.Core and ZSBT.Core.ApplyBlizzardFCTCVars then
						ZSBT.Core:ApplyBlizzardFCTCVars()
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			hideBlizzardFCTOutgoing = {
				type = "toggle",
				name = "Hide Blizzard Outgoing Damage",
				order = 3.51,
				width = "full",
				hidden = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return g and g.hideBlizzardFCTOutgoing ~= false end,
				set = function(_, v)
					local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					if not g then return end
					g.hideBlizzardFCTOutgoing = v and true or false
					if ZSBT.Core and ZSBT.Core.ApplyBlizzardFCTCVars then ZSBT.Core:ApplyBlizzardFCTCVars() end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			hideBlizzardFCTIncomingDamage = {
				type = "toggle",
				name = "Hide Blizzard Incoming Damage",
				order = 3.52,
				width = "full",
				hidden = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return g and g.hideBlizzardFCTIncomingDamage ~= false end,
				set = function(_, v)
					local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					if not g then return end
					g.hideBlizzardFCTIncomingDamage = v and true or false
					if ZSBT.Core and ZSBT.Core.ApplyBlizzardFCTCVars then ZSBT.Core:ApplyBlizzardFCTCVars() end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			hideBlizzardFCTIncomingHealing = {
				type = "toggle",
				name = "Hide Blizzard Incoming Healing",
				order = 3.53,
				width = "full",
				hidden = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return g and g.hideBlizzardFCTIncomingHealing ~= false end,
				set = function(_, v)
					local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					if not g then return end
					g.hideBlizzardFCTIncomingHealing = v and true or false
					if ZSBT.Core and ZSBT.Core.ApplyBlizzardFCTCVars then ZSBT.Core:ApplyBlizzardFCTCVars() end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			hideBlizzardFCTReactives = {
				type = "toggle",
				name = "Hide Blizzard Reactives / Procs",
				order = 3.54,
				width = "full",
				hidden = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return g and g.hideBlizzardFCTReactives ~= false end,
				set = function(_, v)
					local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					if not g then return end
					g.hideBlizzardFCTReactives = v and true or false
					if ZSBT.Core and ZSBT.Core.ApplyBlizzardFCTCVars then ZSBT.Core:ApplyBlizzardFCTCVars() end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			hideBlizzardFCTXPRepHonor = {
				type = "toggle",
				name = "Hide Blizzard XP / Rep / Honor",
				order = 3.55,
				width = "full",
				hidden = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return g and g.hideBlizzardFCTXPRepHonor ~= false end,
				set = function(_, v)
					local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					if not g then return end
					g.hideBlizzardFCTXPRepHonor = v and true or false
					if ZSBT.Core and ZSBT.Core.ApplyBlizzardFCTCVars then ZSBT.Core:ApplyBlizzardFCTCVars() end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			hideBlizzardFCTResourceGains = {
				type = "toggle",
				name = "Hide Blizzard Resource Gains",
				order = 3.56,
				width = "full",
				hidden = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return g and g.hideBlizzardFCTResourceGains ~= false end,
				set = function(_, v)
					local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					if not g then return end
					g.hideBlizzardFCTResourceGains = v and true or false
					if ZSBT.Core and ZSBT.Core.ApplyBlizzardFCTCVars then ZSBT.Core:ApplyBlizzardFCTCVars() end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			hideBlizzardFCTPet = {
				type = "toggle",
				name = "Hide Blizzard Pet Combat Text",
				order = 3.57,
				width = "full",
				hidden = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return not (g and g.hideBlizzardFCT == true) end,
				get = function() local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general; return g and g.hideBlizzardFCTPet ~= false end,
				set = function(_, v)
					local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					if not g then return end
					g.hideBlizzardFCTPet = v and true or false
					if ZSBT.Core and ZSBT.Core.ApplyBlizzardFCTCVars then ZSBT.Core:ApplyBlizzardFCTCVars() end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			restoreBlizzardFCTNow = {
				type  = "execute",
				name  = "Restore Blizzard Combat Text Now",
				desc  = "Restore Blizzard combat text now (panic button).",
				order = 3.58,
				width = "full",
				disabled = function()
					local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					if not g then return true end
					return g.hideBlizzardFCT ~= true
				end,
				func = function()
					if ZSBT.Core and ZSBT.Core.RestoreBlizzardFCT then
						ZSBT.Core:RestoreBlizzardFCT()
						LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
					end
				end,
			},
			headerUI = {
				type  = "header",
				name  = "UI",
				order = 3.56,
			},
			quickControlBarEnabled = {
				type  = "toggle",
				name  = "Enable Quick Control Bar",
				desc  = "Show a draggable on-screen bar for quickly toggling instance/open-world tuning settings and unlocking scroll areas.",
				order = 3.57,
				width = "full",
				get   = function() return ZSBT.db.profile.general.quickControlBarEnabled == true end,
				set   = function(_, val)
					ZSBT.db.profile.general.quickControlBarEnabled = val and true or false
					if ZSBT.UI and ZSBT.UI.QuickControlBar then
						if val and ZSBT.UI.QuickControlBar.Init then
							ZSBT.UI.QuickControlBar:Init()
						end
						if ZSBT.UI.QuickControlBar.RefreshVisibility then
							ZSBT.UI.QuickControlBar:RefreshVisibility()
						end
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			quickControlBarResetPos = {
				type  = "execute",
				name  = "Reset Quick Control Bar Position",
				desc  = "Reset the Quick Control Bar position to the default.",
				order = 3.575,
				width = "full",
				disabled = function() return ZSBT.db.profile.general.quickControlBarEnabled ~= true end,
				func = function()
					if ZSBT.UI and ZSBT.UI.QuickControlBar and ZSBT.UI.QuickControlBar.ResetPosition then
						ZSBT.UI.QuickControlBar:ResetPosition()
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},

			minimapHide = {
				type  = "toggle",
				name  = "Hide Minimap Button",
				desc  = "Hide the ZSBT minimap button. You can also toggle it with /zsbt minimap.",
				order = 3.58,
				width = "full",
				get   = function()
					local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					if not g or not g.minimap then return false end
					return g.minimap.hide == true
				end,
				set   = function(_, val)
					local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					if not g then return end
					g.minimap = g.minimap or {}
					g.minimap.hide = val and true or false
					local mm = ZSBT.Core and ZSBT.Core.Minimap
					if mm and mm.Init then
						mm:Init()
					end
					if mm and mm.SetHidden then
						mm:SetHidden(g.minimap.hide)
					elseif mm and mm.UpdateVisibility then
						mm:UpdateVisibility()
					end
					local b = _G and _G["ZSBT_MinimapButton"]
					if b then
						if g.minimap.hide then
							b:Hide()
						else
							b:Show()
							if mm and mm.ApplyPosition then
								mm:ApplyPosition()
							end
						end
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},

			headerDungeonRaidTuning = {
				type  = "header",
				name  = "Dungeon/Raid Tuning",
				order = 3.61,
			},
			dungeonRaidTuningHelp = {
				type  = "description",
				name  = "These settings adjust outgoing detection behavior specifically for dungeons/raids/follower dungeons where combat text and attribution can be restricted or ambiguous. Use them to reduce group/party cross-talk or to restore missing numbers in restricted content.",
				order = 3.62,
				width = "full",
			},

			instanceAwareOutgoing = {
				type  = "toggle",
				name  = "Dungeon/Raid Aware Outgoing",
				desc  = "When enabled, ZSBT will restrict outgoing detection in dungeons and raids to avoid showing group/raid target damage as your outgoing. This may reduce outgoing numbers in group content.",
				order = 3.65,
				width = "full",
				get   = function() return ZSBT.db.profile.general.instanceAwareOutgoing == true end,
				set   = function(_, val)
					ZSBT.db.profile.general.instanceAwareOutgoing = val and true or false
					if val ~= true then
						ZSBT.db.profile.general.damageMeterOutgoingFallback = false
						ZSBT.db.profile.general.damageMeterIncomingFallback = false
						ZSBT.db.profile.general.autoAttackRestrictFallback = false
					end
					if ZSBT.Core and ZSBT.Core.UpdateInstanceState then
						ZSBT.Core:UpdateInstanceState(true)
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			damageMeterOutgoingFallback = {
				type  = "toggle",
				name  = "Use Damage Meter Outgoing Fallback (Experimental)",
				desc  = "When Dungeon/Raid Aware Outgoing is enabled and outgoing becomes too quiet in follower dungeons/instances, this can use Blizzard's damage meter totals (Retail 12.x) as an outgoing fallback. This may be less detailed (no crit flags) and can increase duplicate numbers if other sources are also active.",
				order = 3.66,
				width = "full",
				hidden = function()
					return ZSBT.db.profile.general.instanceAwareOutgoing ~= true
				end,
				get   = function() return ZSBT.db.profile.general.damageMeterOutgoingFallback == true end,
				set   = function(_, val)
					ZSBT.db.profile.general.damageMeterOutgoingFallback = val and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			damageMeterIncomingFallback = {
				type  = "toggle",
				name  = "Use Damage Meter Incoming Damage Fallback (Experimental)",
				desc  = "When Dungeon/Raid Aware Outgoing is enabled and incoming combat text becomes ambiguous/secret in follower dungeons, this can use Blizzard's damage meter damage-taken totals (Retail 12.x) as a last-resort incoming damage fallback. This may be less detailed (no spell/school/crit flags) and can increase noise if other sources are also active.",
				order = 3.665,
				width = "full",
				hidden = function()
					return ZSBT.db.profile.general.instanceAwareOutgoing ~= true
				end,
				get   = function() return ZSBT.db.profile.general.damageMeterIncomingFallback == true end,
				set   = function(_, val)
					ZSBT.db.profile.general.damageMeterIncomingFallback = val and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			autoAttackRestrictFallback = {
				type  = "toggle",
				name  = "Show Auto Attacks in Instances (Experimental)",
				desc  = "When Dungeon/Raid Aware Outgoing is enabled, auto-attacks may be suppressed in follower dungeons because physical UNIT_COMBAT(target) has no source attribution. This option enables a conservative last-resort auto-attack fallback in restrict mode. It may occasionally misattribute follower/other melee swings.",
				order = 3.6655,
				width = "full",
				hidden = function()
					return ZSBT.db.profile.general.instanceAwareOutgoing ~= true
				end,
				get   = function() return ZSBT.db.profile.general.autoAttackRestrictFallback == true end,
				set   = function(_, val)
					ZSBT.db.profile.general.autoAttackRestrictFallback = val and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},

			headerPvPTuning = {
				type  = "header",
				name  = "PvP Tuning",
				order = 3.6656,
			},
			pvpTuningHelp = {
				type  = "description",
				name  = "These settings tighten outgoing attribution while inside battlegrounds and arenas. They are designed to reduce bleed-through (other players showing as your outgoing) and to improve icon/color correctness by requiring stronger ownership signals.",
				order = 3.6657,
				width = "full",
			},
			pvpStrictEnabled = {
				type  = "toggle",
				name  = "Enable PvP Strict Mode (Experimental)",
				desc  = "Only applies inside PvP/Arena instances. Prioritizes correctness over completeness: expect fewer outgoing numbers, but fewer wrong icons/colors and less bleed-through.",
				order = 3.6658,
				width = "full",
				get   = function() return ZSBT.db.profile.general.pvpStrictEnabled == true end,
				set   = function(_, val)
					ZSBT.db.profile.general.pvpStrictEnabled = val and true or false
					if ZSBT.Core and ZSBT.Core.UpdateInstanceState then
						ZSBT.Core:UpdateInstanceState(true)
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			pvpStrictDisableAutoAttackFallback = {
				type  = "toggle",
				name  = "Disable Auto-Attack Fallback (PvP)",
				desc  = "When PvP Strict Mode is enabled, suppress the last-resort auto-attack fallback used in restricted attribution modes.",
				order = 3.66585,
				width = "full",
				hidden = function() return ZSBT.db.profile.general.pvpStrictEnabled ~= true end,
				get   = function() return ZSBT.db.profile.general.pvpStrictDisableAutoAttackFallback ~= false end,
				set   = function(_, val)
					ZSBT.db.profile.general.pvpStrictDisableAutoAttackFallback = val and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},

			headerExperimentalTuning = {
				type  = "header",
				name  = "Open-World Tuning",
				order = 3.666,
			},
			experimentalTuningHelp = {
				type  = "description",
				name  = "These settings change how ZSBT attributes outgoing events in open world and edge cases. Enable them if you see incorrect attribution (for example, other players' damage on shared targets). Some options may reduce the amount of outgoing text shown.",
				order = 3.667,
				width = "full",
			},
			strictOutgoingCombatLogOnly = {
				type  = "toggle",
				name  = "Strict Outgoing (Combat Log Only)",
				desc  = "Experimental mode to reduce incorrect outgoing attribution. This option is intended to stop cases where other players' damage shows up as your outgoing on shared targets (like training dummies). Depending on your client/environment, it may reduce outgoing numbers in some content.",
				order = 3.668,
				width = "full",
				get   = function() return ZSBT.db.profile.general.strictOutgoingCombatLogOnly == true end,
				set   = function(_, val)
					ZSBT.db.profile.general.strictOutgoingCombatLogOnly = val and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			quietOutgoingWhenIdle = {
				type  = "toggle",
				name  = "Quiet Outgoing When Idle (Experimental)",
				desc  = "Suppress outgoing numbers from ambiguous attribution sources unless they can be correlated to your own casts/periodic effects. This can prevent other players' damage on shared targets from being misattributed as your outgoing, but may reduce outgoing text (especially auto-attacks).",
				order = 3.669,
				width = "full",
				get   = function() return ZSBT.db.profile.general.quietOutgoingWhenIdle == true end,
				set   = function(_, val)
					ZSBT.db.profile.general.quietOutgoingWhenIdle = val and true or false
					if val ~= true then
						ZSBT.db.profile.general.quietOutgoingAutoAttacks = false
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			quietOutgoingAutoAttacks = {
				type  = "toggle",
				name  = "Allow Auto Attacks While Quiet (Experimental)",
				desc  = "When Quiet Outgoing When Idle is enabled, auto-attacks are suppressed for correctness (UNIT_COMBAT(target) has no source attribution). This option re-enables a conservative auto-attack fallback when your auto-attack is actually active, but it can still occasionally misattribute swings on shared targets.",
				order = 3.6695,
				width = "full",
				hidden = function()
					return ZSBT.db.profile.general.quietOutgoingWhenIdle ~= true
				end,
				get   = function() return ZSBT.db.profile.general.quietOutgoingAutoAttacks == true end,
				set   = function(_, val)
					ZSBT.db.profile.general.quietOutgoingAutoAttacks = val and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},

			headerFont = {
				type  = "header",
				name  = "Master Font",
                order = 10,
            },
            fontFace = {
                type   = "select",
                name   = "Font Face",
                desc   = "Global font used for all ZSBT combat text.",
                order  = 11,
                values = function() return ZSBT.BuildFontDropdown() end,
                get    = function() return ZSBT.db.profile.general.font.face end,
                set    = function(_, val)
                    ZSBT.db.profile.general.font.face = val
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            fontSize = {
                type  = "range",
                name  = "Font Size",
                desc  = "Base size for ZSBT combat text numbers.",
                order = 12,
                min   = ZSBT.FONT_SIZE_MIN,
                max   = ZSBT.FONT_SIZE_MAX,
                step  = 1,
                get   = function() return ZSBT.db.profile.general.font.size end,
                set   = function(_, val)
                    ZSBT.db.profile.general.font.size = val
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            fontOutline = {
                type   = "select",
                name   = "Outline Style",
                desc   = "Font outline thickness.",
                order  = 13,
                values = ZSBT.ValuesFromKeys(ZSBT.OUTLINE_STYLES),
                get    = function() return ZSBT.db.profile.general.font.outline end,
                set    = function(_, val)
                    ZSBT.db.profile.general.font.outline = val
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            fontAlpha = {
                type      = "range",
                name      = "Text Opacity",
                desc      = "Global transparency for ZSBT text.",
                order     = 14,
                min       = ZSBT.ALPHA_MIN,
                max       = ZSBT.ALPHA_MAX,
                step      = 0.05,
                isPercent = true,
                get       = function() return ZSBT.db.profile.general.font.alpha end,
                set       = function(_, val)
                    ZSBT.db.profile.general.font.alpha = val
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },

			headerNumbers = {
				type  = "header",
				name  = "Numbers",
				order = 15,
			},
			numbersHelp = {
				type  = "description",
				name  = "When running older content, damage/heal values can become very large and hard to read at a glance.\n" ..
						"Number Format lets you abbreviate big amounts (K/M/B) while keeping smaller numbers unchanged.\n\n" ..
						"This setting only affects incoming/outgoing damage and healing amounts (and overheal text). It does not change Triggers text.",
				order = 15.05,
				width = "full",
			},
			numberFormat = {
				type   = "select",
				name   = "Number Format",
				desc   = "Format large incoming/outgoing damage and healing numbers for readability.",
				order  = 16,
				values = function() return ZSBT.NUMBER_FORMATS end,
				get    = function() return ZSBT.db.profile.general.numberFormat or "none" end,
				set    = function(_, val)
					ZSBT.db.profile.general.numberFormat = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},

            -- Crit Font Settings
            headerCritFont = {
                type  = "header",
                name  = "Critical Hit Font",
                order = 20,
            },
            critFontFace = {
                type   = "select",
                name   = "Crit Font Face",
                desc   = "Font used for critical hits. Leave blank to use master font.",
                order  = 21,
                values = function()
                    local fonts = ZSBT.BuildFontDropdown()
                    fonts["__use_master__"] = "(Use Master Font)"
                    return fonts
                end,
                get    = function()
                    local f = ZSBT.db.profile.general.critFont and ZSBT.db.profile.general.critFont.face
                    return f or "__use_master__"
                end,
                set    = function(_, val)
                    if not ZSBT.db.profile.general.critFont then
                        ZSBT.db.profile.general.critFont = {}
                    end
                    if val == "__use_master__" then
                        ZSBT.db.profile.general.critFont.face = nil
                    else
                        ZSBT.db.profile.general.critFont.face = val
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            critFontSize = {
                type  = "range",
                name  = "Crit Font Size",
                desc  = "Font size for critical hit text.",
                order = 22,
                min   = ZSBT.FONT_SIZE_MIN,
                max   = 48,
                step  = 1,
                hidden = function()
                    local cf = ZSBT.db.profile.general.critFont
                    return cf and cf.useScale == true
                end,
                get   = function()
                    return (ZSBT.db.profile.general.critFont and ZSBT.db.profile.general.critFont.size) or 28
                end,
                set   = function(_, val)
                    if not ZSBT.db.profile.general.critFont then
                        ZSBT.db.profile.general.critFont = {}
                    end
                    ZSBT.db.profile.general.critFont.size = val
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            critUseScale = {
                type  = "toggle",
                name  = "Use Crit Scale (instead of fixed size)",
                desc  = "When enabled, crit size is derived from your normal font size using Crit Scale. When disabled, Crit Font Size is used.",
                order = 23,
                width = "full",
                get   = function()
                    local cf = ZSBT.db.profile.general.critFont
                    return cf and cf.useScale == true
                end,
                set   = function(_, v)
                    if not ZSBT.db.profile.general.critFont then
                        ZSBT.db.profile.general.critFont = {}
                    end
                    ZSBT.db.profile.general.critFont.useScale = v and true or false
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
			critAnim = {
				type   = "select",
				name   = "Crit Animation",
				desc   = "Choose whether crits use the sticky Pow animation or follow the scroll area's animation.",
				order  = 23.5,
				values = { Pow = "Pow (Sticky)", Area = "Use Scroll Area Animation" },
				get    = function()
					local cf = ZSBT.db.profile.general.critFont
					return (cf and (cf.anim == "Area" or cf.anim == "Pow")) and cf.anim or "Pow"
				end,
				set    = function(_, val)
					if not ZSBT.db.profile.general.critFont then
						ZSBT.db.profile.general.critFont = {}
					end
					ZSBT.db.profile.general.critFont.anim = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
            critFontOutline = {
                type   = "select",
                name   = "Crit Outline",
                desc   = "Outline style for critical hit text.",
                order  = 24,
                values = { None = "None", Thin = "Thin", Thick = "Thick", Monochrome = "Monochrome" },
                get    = function()
                    return (ZSBT.db.profile.general.critFont and ZSBT.db.profile.general.critFont.outline) or "Thick"
                end,
                set    = function(_, val)
                    if not ZSBT.db.profile.general.critFont then
                        ZSBT.db.profile.general.critFont = {}
                    end
                    ZSBT.db.profile.general.critFont.outline = val
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            critFontScale = {
                type  = "range",
                name  = "Crit Scale",
                desc  = "Scale multiplier vs normal font size.",
                order = 24.5,
                min   = 1.0,
                max   = 3.0,
                step  = 0.1,
                hidden = function()
                    local cf = ZSBT.db.profile.general.critFont
                    return not (cf and cf.useScale == true)
                end,
                get   = function()
                    return (ZSBT.db.profile.general.critFont and ZSBT.db.profile.general.critFont.scale) or 1.5
                end,
                set   = function(_, val)
                    if not ZSBT.db.profile.general.critFont then
                        ZSBT.db.profile.general.critFont = {}
                    end
                    ZSBT.db.profile.general.critFont.scale = val
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            headerQuickActions = {
                type  = "header",
                name  = "Quick Actions",
                order = 40,
            },
            resetDefaults = {
                type    = "execute",
                name    = "Reset to Defaults",
                desc    = "Reset settings to defaults (tracked cooldown spells are preserved).",
                order   = 41,
                confirm = true,
                confirmText = "Reset all settings to defaults?\n\nTracked cooldown spells will be preserved.",
                func    = function()
                    -- Preserve tracked cooldown spells.
                    local preservedTracked = nil
                    if ZSBT.db
                        and ZSBT.db.char
                        and ZSBT.db.char.cooldowns
                        and ZSBT.db.char.cooldowns.tracked then

                        preservedTracked = {}
                        for k, v in pairs(ZSBT.db.char.cooldowns.tracked) do
                            preservedTracked[k] = v
                        end
                    end

                    ZSBT.db:ResetProfile()

                    if preservedTracked then
                        ZSBT.db.char = ZSBT.db.char or {}
                        ZSBT.db.char.cooldowns = ZSBT.db.char.cooldowns or {}
                        ZSBT.db.char.cooldowns.tracked = preservedTracked
                    end

                    Addon:Print("Settings reset to defaults.")
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            reloadUI = {
                type    = "execute",
                name    = "Reload UI",
                desc    = "Reload the World of Warcraft user interface.",
                order   = 42,
                confirm = true,
                confirmText = "Reload the UI now?",
                func    = function() ReloadUI() end,
            },
        },
    }
end

------------------------------------------------------------------------
-- TAB 3: NOTIFICATIONS
-- Manage what categories can emit to the Notifications scroll area.
------------------------------------------------------------------------
function ZSBT.BuildTab_Notifications()
	local STYLE_CATEGORIES = {
		enterCombat = true,
		leaveCombat = true,
		progress = true,
		companionXP = true,
		lootItems = true,
		lootMoney = true,
		lootCurrency = true,
		tradeskillUps = true,
		tradeskillLearned = true,
		power = true,
	}
	local CATEGORY_LABELS = {
		enterCombat = "Enter Combat",
		leaveCombat = "Leave Combat",
		progress = "Progress (XP / Honor / Reputation)",
		companionXP = "Companion XP",
		lootItems = "Loot Items",
		lootMoney = "Loot Money",
		lootCurrency = "Loot Currency",
		tradeskillUps = "Trade Skills: Skill Ups",
		tradeskillLearned = "Trade Skills: Learned Recipes/Spells",
		interrupts = "Interrupts (Successful)",
		caststops = "Cast Stops (Stuns/CC)",
		power = "Power",
	}
	local TEMPLATE_DESCS = {
		enterCombat = "Template codes: %e=event text.",
		leaveCombat = "Template codes: %e=event text.",
		progress = "Template codes: %e=event text.",
		companionXP = "Template codes: %e=event text.",
		lootItems = "Template codes: %e=item, %a=amount looted, %t=total owned.",
		lootMoney = "Template codes: %e=money string.",
		lootCurrency = "Template codes: %e=currency link/name, %a=amount gained, %t=total quantity.",
		tradeskillUps = "Template codes: %e=skill, %a=amount, %t=new level.",
		tradeskillLearned = "Template codes: %e=learned recipe/spell.",
		interrupts = "Message template codes: %t=target, %s=your ability.",
		caststops = "Message template codes: %t=target, %s=your ability.",
		power = "Template codes: %e=event text.",
	}
	local DEFAULT_TEMPLATES = {
		enterCombat = "%e",
		leaveCombat = "%e",
		progress = "%e",
		companionXP = "%e",
		lootItems = "+%a %e (%t)",
		lootMoney = "+%e",
		lootCurrency = "+%a %e (%t)",
		tradeskillUps = "%e +%a (%t)",
		tradeskillLearned = "Learned: %e",
		interrupts = "%t Interrupted!",
		caststops = "%t Interrupted!",
		power = "%e",
	}

	local function getCat(key)
		local p = ZSBT.db and ZSBT.db.profile
		local n = p and p.notifications
		local v = n and n[key]
		return v ~= false
	end
	local function setCat(key, val)
		ZSBT.db.profile.notifications = ZSBT.db.profile.notifications or {}
		ZSBT.db.profile.notifications[key] = val and true or false
		LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
	end
	local function getTpl(key, fallback)
		local p = ZSBT.db and ZSBT.db.profile
		local t = p and p.notificationsTemplates
		local v = t and t[key]
		if type(v) ~= "string" or v == "" then
			return fallback
		end
		return v
	end
	local function setTpl(key, val)
		ZSBT.db.profile.notificationsTemplates = ZSBT.db.profile.notificationsTemplates or {}
		if type(val) ~= "string" then val = "" end
		ZSBT.db.profile.notificationsTemplates[key] = val
		LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
	end
	local function splitLinesToSet(s)
		local out = {}
		if type(s) ~= "string" then return out end
		for part in s:gmatch("[^,\n\r]+") do
			local name = part:gsub("^%s+", ""):gsub("%s+$", "")
			if name ~= "" then
				out[name] = true
			end
		end
		return out
	end
	local function setToLines(set)
		if type(set) ~= "table" then return "" end
		local keys = {}
		for k, v in pairs(set) do
			if v == true and type(k) == "string" and k ~= "" then
				table.insert(keys, k)
			end
		end
		table.sort(keys)
		return table.concat(keys, "\n")
	end
	local function getRoute(key)
		local p = ZSBT.db and ZSBT.db.profile
		local r = p and p.notificationsRouting
		local v = r and r[key]
		if type(v) ~= "string" or v == "" then
			return "Notifications"
		end
		return v
	end
	local function setRoute(key, val)
		ZSBT.db.profile.notificationsRouting = ZSBT.db.profile.notificationsRouting or {}
		if type(val) ~= "string" or val == "" then
			ZSBT.db.profile.notificationsRouting[key] = "Notifications"
		else
			ZSBT.db.profile.notificationsRouting[key] = val
		end
		LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
	end
	local function routeSelect(key, order)
		return {
			type = "select",
			name = "Route To",
			desc = "Choose which scroll area this notification category should emit into.",
			order = order,
			width = "normal",
			values = function() return ZSBT.GetScrollAreaNames() end,
			get = function() return getRoute(key) end,
			set = function(_, v) setRoute(key, v) end,
		}
	end

	local function getPerType(key)
		local p = ZSBT.db and ZSBT.db.profile
		local nt = p and p.notificationsPerType
		local v = nt and nt[key]
		return type(v) == "table" and v or nil
	end
	local function ensurePerType(key)
		ZSBT.db.profile.notificationsPerType = ZSBT.db.profile.notificationsPerType or {}
		ZSBT.db.profile.notificationsPerType[key] = ZSBT.db.profile.notificationsPerType[key] or {}
		local v = ZSBT.db.profile.notificationsPerType[key]
		v.style = type(v.style) == "table" and v.style or {}
		v.sound = type(v.sound) == "table" and v.sound or {}
		if v.sound.enabled == nil then v.sound.enabled = false end
		if key == "enterCombat" and v.sound.stopOnLeaveCombat == nil then v.sound.stopOnLeaveCombat = false end
		if type(v.sound.soundKey) ~= "string" or v.sound.soundKey == "" then v.sound.soundKey = "None" end
		return v
	end

	local function buildStyleSoundArgs(key, baseOrder)
		if not STYLE_CATEGORIES[key] then
			return {}
		end
		return {
			styleHeader = { type = "header", name = "Style", order = baseOrder },
			color = {
				type = "color",
				name = "Color",
				order = baseOrder + 0.1,
				get = function()
					local c = getPerType(key)
					local style = c and c.style
					local col = style and style.color
					col = col or { r = 1, g = 1, b = 1 }
					return col.r, col.g, col.b
				end,
				set = function(_, r, g, b)
					local c = ensurePerType(key)
					c.style.color = { r = r, g = g, b = b }
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			fontOverride = {
				type = "toggle",
				name = "Font Override",
				desc = "Override the font settings for this notification type.",
				order = baseOrder + 0.2,
				width = "full",
				get = function()
					local c = getPerType(key)
					return c and c.style and c.style.fontOverride == true
				end,
				set = function(_, v)
					local c = ensurePerType(key)
					c.style.fontOverride = v and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			fontFace = {
				type = "select",
				name = "Font Face",
				order = baseOrder + 0.3,
				values = function() return ZSBT.BuildFontDropdown() end,
				disabled = function()
					local c = getPerType(key)
					return not (c and c.style and c.style.fontOverride == true)
				end,
				get = function()
					local c = getPerType(key)
					return (c and c.style and c.style.fontFace) or ZSBT.db.profile.general.font.face
				end,
				set = function(_, v)
					local c = ensurePerType(key)
					c.style.fontFace = v
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			fontOutline = {
				type = "select",
				name = "Outline Style",
				order = baseOrder + 0.4,
				values = ZSBT.ValuesFromKeys(ZSBT.OUTLINE_STYLES),
				disabled = function()
					local c = getPerType(key)
					return not (c and c.style and c.style.fontOverride == true)
				end,
				get = function()
					local c = getPerType(key)
					return (c and c.style and c.style.fontOutline) or ZSBT.db.profile.general.font.outline
				end,
				set = function(_, v)
					local c = ensurePerType(key)
					c.style.fontOutline = v
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			fontSize = {
				type = "range",
				name = "Font Size",
				order = baseOrder + 0.5,
				min = 8,
				max = 72,
				step = 1,
				disabled = function()
					local c = getPerType(key)
					return not (c and c.style and c.style.fontOverride == true)
				end,
				get = function()
					local c = getPerType(key)
					return tonumber((c and c.style and c.style.fontSize) or 18) or 18
				end,
				set = function(_, v)
					local c = ensurePerType(key)
					c.style.fontSize = v
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			soundHeader = { type = "header", name = "Sound", order = baseOrder + 1 },
			soundEnabled = {
				type = "toggle",
				name = "Play a Sound",
				order = baseOrder + 1.1,
				width = "full",
				get = function()
					local c = getPerType(key)
					return c and c.sound and c.sound.enabled == true
				end,
				set = function(_, v)
					local c = ensurePerType(key)
					c.sound.enabled = v and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			soundKey = {
				type = "select",
				name = "Sound",
				order = baseOrder + 1.2,
				values = function() return (ZSBT.BuildSoundDropdown and ZSBT.BuildSoundDropdown()) or { ["None"] = "None" } end,
				disabled = function()
					local c = getPerType(key)
					return not (c and c.sound and c.sound.enabled == true)
				end,
				get = function()
					local c = getPerType(key)
					local sk = c and c.sound and c.sound.soundKey
					return (type(sk) == "string" and sk ~= "") and sk or "None"
				end,
				set = function(_, v)
					local c = ensurePerType(key)
					c.sound.soundKey = v
				end,
			},
			soundTest = {
				type = "execute",
				name = "Play Sound",
				order = baseOrder + 1.3,
				width = "half",
				disabled = function()
					local c = getPerType(key)
					return not (c and c.sound and c.sound.enabled == true)
				end,
				func = function()
					local c = getPerType(key)
					local sk = c and c.sound and c.sound.soundKey
					if type(sk) ~= "string" then sk = "None" end
					if ZSBT.PlayLSMSound then
						ZSBT.PlayLSMSound(sk)
					end
				end,
			},
			stopOnLeaveCombat = {
				type = "toggle",
				name = "Stop sound when leaving combat",
				desc = "If enabled, the Enter Combat sound will be stopped when you leave combat so the Leave Combat sound can play cleanly.",
				order = baseOrder + 1.4,
				width = "full",
				hidden = function() return key ~= "enterCombat" end,
				disabled = function()
					local c = getPerType(key)
					return not (c and c.sound and c.sound.enabled == true)
				end,
				get = function()
					local c = getPerType(key)
					return c and c.sound and c.sound.stopOnLeaveCombat == true
				end,
				set = function(_, v)
					local c = ensurePerType(key)
					c.sound.stopOnLeaveCombat = v and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
		}
	end

	local function buildLeafGroup(key, order)
		return {
			type = "group",
			name = CATEGORY_LABELS[key] or key,
			order = order,
			args = (function()
				local args = {}
				args.enabled = {
					type = "toggle",
					name = "Enabled",
					order = 1,
					width = "full",
					get = function() return getCat(key) end,
					set = function(_, v) setCat(key, v) end,
				}
				args.route = routeSelect(key, 1.1)
				args.template = {
					type = "input",
					name = "Template",
					desc = TEMPLATE_DESCS[key] or "Template codes: %e=event text.",
					order = 1.2,
					width = "full",
					get = function() return getTpl(key, DEFAULT_TEMPLATES[key] or "%e") end,
					set = function(_, v) setTpl(key, v) end,
				}
				local extra = buildStyleSoundArgs(key, 2)
				for k, v in pairs(extra) do
					args[k] = v
				end
				return args
			end)(),
		}
	end

	return {
		type  = "group",
		name  = "|cFFFFD100Notifications|r",
		order = 3,
		childGroups = "tree",
		args  = {
			header = {
				type  = "header",
				name  = "Notifications Scroll Area",
				order = 1,
			},
			desc = {
				type     = "description",
				name     = "Choose which notification categories can emit into the Notifications scroll area.",
				order    = 2,
				fontSize = "medium",
			},
			spacer = { type = "description", name = " ", order = 2.5, width = "full" },
			enabled = {
				type  = "toggle",
				name  = "Enable Notifications Area",
				desc  = "If disabled, nothing will be shown in the Notifications scroll area (combat enter/leave, progress, loot, etc.).",
				order = 2.6,
				width = "full",
				get   = function() return ZSBT.db.profile.general.notificationsEnabled ~= false end,
				set   = function(_, val)
					ZSBT.db.profile.general.notificationsEnabled = val and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},

			combatState = {
				type = "group",
				name = "Combat State",
				order = 3,
				args = {
					enterCombat = buildLeafGroup("enterCombat", 1),
					leaveCombat = buildLeafGroup("leaveCombat", 2),
				},
			},
			progress = buildLeafGroup("progress", 4),
			companionXP = buildLeafGroup("companionXP", 4.1),
			lootAlerts = {
				type = "group",
				name = "Loot Alerts",
				order = 5,
				args = {
					lootItems = buildLeafGroup("lootItems", 1),
					lootMoney = buildLeafGroup("lootMoney", 2),
					lootCurrency = buildLeafGroup("lootCurrency", 3),
				},
			},
			tradeSkillAlerts = {
				type = "group",
				name = "Trade Skill Alerts",
				order = 6,
				args = {
					tradeskillUps = buildLeafGroup("tradeskillUps", 1),
					tradeskillLearned = buildLeafGroup("tradeskillLearned", 2),
				},
			},
			interruptAlerts = {
				type = "group",
				name = "Interrupt Alerts",
				order = 7,
				args = {
					interrupts = {
						type  = "toggle",
						name  = "Interrupts (Successful)",
						order = 1,
						width = "full",
						get   = function() return getCat("interrupts") end,
						set   = function(_, v) setCat("interrupts", v) end,
					},
					interruptsTemplate = {
						type = "input",
						name = "Interrupts Template",
						desc = "Message template codes: %t=target, %s=your ability.",
						order = 1.1,
						width = "full",
						get = function() return getTpl("interrupts", "%t Interrupted!") end,
						set = function(_, v) setTpl("interrupts", v) end,
					},
					caststops = {
						type  = "toggle",
						name  = "Cast Stops (Stuns/CC)",
						desc  = "Show a notification when your stun/CC causes a target cast to stop (optional).",
						order = 2,
						width = "full",
						get   = function() return getCat("caststops") end,
						set   = function(_, v) setCat("caststops", v) end,
					},
					caststopsTemplate = {
						type = "input",
						name = "Cast Stops Template",
						desc = "Message template codes: %t=target, %s=your ability.",
						order = 2.1,
						width = "full",
						get = function() return getTpl("caststops", "%t Interrupted!") end,
						set = function(_, v) setTpl("caststops", v) end,
					},
					sharedHeader = { type = "header", name = "Shared Style / Sound", order = 3 },
					overrideArea = {
						type = "select",
						name = "Route To",
						desc = "Choose which scroll area both Interrupts and Cast Stops should emit into.",
						order = 3.1,
						width = "normal",
						values = function()
							return ZSBT.GetScrollAreaNames and ZSBT.GetScrollAreaNames() or {}
						end,
						get = function()
							local c = ZSBT.db.profile.interruptAlerts
							return (c and type(c.scrollArea) == "string" and c.scrollArea ~= "") and c.scrollArea or "Notifications"
						end,
						set = function(_, val)
							ZSBT.db.profile.interruptAlerts = ZSBT.db.profile.interruptAlerts or {}
							ZSBT.db.profile.interruptAlerts.scrollArea = val
							LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
						end,
					},
					color = {
						type = "color",
						name = "Color",
						desc = "Color for both Interrupts and Cast Stops.",
						order = 3.2,
						get = function()
							local c = ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.color
							c = c or { r = 1.0, g = 0.6, b = 0.0 }
							return c.r, c.g, c.b
						end,
						set = function(_, r, g, b)
							ZSBT.db.profile.interruptAlerts = ZSBT.db.profile.interruptAlerts or {}
							ZSBT.db.profile.interruptAlerts.color = { r = r, g = g, b = b }
							LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
						end,
					},
					fontOverride = {
						type = "toggle",
						name = "Font Override",
						desc = "Override the font settings for both Interrupts and Cast Stops.",
						order = 3.3,
						width = "full",
						get = function() return ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.fontOverride == true end,
						set = function(_, v)
							ZSBT.db.profile.interruptAlerts = ZSBT.db.profile.interruptAlerts or {}
							ZSBT.db.profile.interruptAlerts.fontOverride = v and true or false
							LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
						end,
					},
					fontFace = {
						type = "select",
						name = "Font Face",
						order = 3.4,
						values = function() return ZSBT.BuildFontDropdown() end,
						disabled = function() return not (ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.fontOverride == true) end,
						get = function() return (ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.fontFace) or ZSBT.db.profile.general.font.face end,
						set = function(_, v)
							ZSBT.db.profile.interruptAlerts = ZSBT.db.profile.interruptAlerts or {}
							ZSBT.db.profile.interruptAlerts.fontFace = v
							LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
						end,
					},
					fontOutline = {
						type = "select",
						name = "Outline Style",
						order = 3.5,
						values = ZSBT.ValuesFromKeys(ZSBT.OUTLINE_STYLES),
						disabled = function() return not (ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.fontOverride == true) end,
						get = function() return (ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.fontOutline) or ZSBT.db.profile.general.font.outline end,
						set = function(_, v)
							ZSBT.db.profile.interruptAlerts = ZSBT.db.profile.interruptAlerts or {}
							ZSBT.db.profile.interruptAlerts.fontOutline = v
							LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
						end,
					},
					fontSize = {
						type = "range",
						name = "Font Size",
						order = 3.6,
						min = 8,
						max = 72,
						step = 1,
						disabled = function() return not (ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.fontOverride == true) end,
						get = function() return tonumber((ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.fontSize) or 18) or 18 end,
						set = function(_, v)
							ZSBT.db.profile.interruptAlerts = ZSBT.db.profile.interruptAlerts or {}
							ZSBT.db.profile.interruptAlerts.fontSize = v
							LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
						end,
					},
					soundEnabled = {
						type = "toggle",
						name = "Play a Sound",
						order = 3.7,
						width = "full",
						get = function() return ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.soundEnabled == true end,
						set = function(_, v)
							ZSBT.db.profile.interruptAlerts = ZSBT.db.profile.interruptAlerts or {}
							ZSBT.db.profile.interruptAlerts.soundEnabled = v and true or false
							LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
						end,
					},
					sound = {
						type = "select",
						name = "Sound",
						order = 3.8,
						values = function() return (ZSBT.BuildSoundDropdown and ZSBT.BuildSoundDropdown()) or { ["None"] = "None" } end,
						disabled = function() return not (ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.soundEnabled == true) end,
						get = function()
							local c = ZSBT.db.profile.interruptAlerts
							return (c and type(c.sound) == "string" and c.sound ~= "") and c.sound or "None"
						end,
						set = function(_, v)
							ZSBT.db.profile.interruptAlerts = ZSBT.db.profile.interruptAlerts or {}
							ZSBT.db.profile.interruptAlerts.sound = v
						end,
					},
					soundTest = {
						type = "execute",
						name = "Play Sound",
						order = 3.9,
						width = "half",
						disabled = function() return not (ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.soundEnabled == true) end,
						func = function()
							local c = ZSBT.db.profile.interruptAlerts
							if c and ZSBT.PlayLSMSound then
								ZSBT.PlayLSMSound(c.sound)
							end
						end,
					},
					chatHeader = { type = "header", name = "Chat Announcement", order = 4 },
					chatEnabled = {
						type = "toggle",
						name = "Show Successful Interrupts in Chat",
						desc = "When enabled, ZSBT will print a chat message locally when you successfully interrupt (interrupts only; does not announce stuns/CC).",
						order = 4.1,
						width = "full",
						get = function() return ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.chatEnabled == true end,
						set = function(_, v)
							ZSBT.db.profile.interruptAlerts = ZSBT.db.profile.interruptAlerts or {}
							ZSBT.db.profile.interruptAlerts.chatEnabled = v and true or false
							LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
						end,
					},
					chatTemplate = {
						type = "input",
						name = "Template",
						desc = "Template codes: %p=your name, %s=your ability, %t=target.",
						order = 4.2,
						width = "full",
						disabled = function() return not (ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.chatEnabled == true) end,
						get = function()
							local c = ZSBT.db.profile.interruptAlerts
							return (c and type(c.chatTemplate) == "string" and c.chatTemplate ~= "") and c.chatTemplate or "%p %s interrupted %t!"
						end,
						set = function(_, v)
							ZSBT.db.profile.interruptAlerts = ZSBT.db.profile.interruptAlerts or {}
							ZSBT.db.profile.interruptAlerts.chatTemplate = v
							LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
						end,
					},
					chatTest = {
						type = "execute",
						name = "Test Chat",
						order = 4.3,
						width = "half",
						disabled = function() return not (ZSBT.db.profile.interruptAlerts and ZSBT.db.profile.interruptAlerts.chatEnabled == true) end,
						func = function()
							local c = ZSBT.db.profile.interruptAlerts or {}
							local msg = c.chatTemplate or "%p %s interrupted %t!"
							msg = msg:gsub("%%p", UnitName("player") or "Player")
							msg = msg:gsub("%%s", "Pummel")
							msg = msg:gsub("%%t", "Target")
							if ZSBT.IsSafeString and not ZSBT.IsSafeString(msg) then return end
							if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
								DEFAULT_CHAT_FRAME:AddMessage(msg)
							elseif ChatFrame1 and ChatFrame1.AddMessage then
								ChatFrame1:AddMessage(msg)
							elseif ZSBT and ZSBT.Addon and ZSBT.Addon.Print then
								ZSBT.Addon:Print(msg)
							end
						end,
					},
				},
			},
			power = {
				type  = "toggle",
				name  = "Power Full",
				order = 8,
				width = "full",
				get   = function() return getCat("power") end,
				set   = function(_, v) setCat("power", v) end,
			},
			powerRoute = routeSelect("power", 8.1),
		},
	}
end
------------------------------------------------------------------------
-- TAB 2: SCROLL AREAS
-- Create/delete/rename scroll areas and configure their geometry.
------------------------------------------------------------------------


-- Module-level state for selected scroll area
local selectedScrollArea = nil
local renameScrollAreaBuffer = ""
local createScrollAreaBuffer = ""

local function GetFallbackScrollAreaName()
    -- Prefer Incoming if it exists; otherwise pick the first available area name.
    if ZSBT and ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.scrollAreas then
        if ZSBT.db.profile.scrollAreas["Incoming"] then
            return "Incoming"
        end
        for name in pairs(ZSBT.db.profile.scrollAreas) do
            return name
        end
    end
    return nil
end

local function EnsureSelectedScrollArea()
    local names = ZSBT.GetScrollAreaNames and ZSBT.GetScrollAreaNames() or nil
    if names and selectedScrollArea and names[selectedScrollArea] then
        return selectedScrollArea
    end

    -- Default to Incoming if present.
    if names and names["Incoming"] then
        selectedScrollArea = "Incoming"
        return selectedScrollArea
    end

    -- Otherwise choose first available.
    if names then
        for name in pairs(names) do
            selectedScrollArea = name
            return selectedScrollArea
        end
    end

    -- Last resort: check raw table (should not happen if values() is correct).
    selectedScrollArea = GetFallbackScrollAreaName()
    return selectedScrollArea
end

function ZSBT.SetSelectedScrollArea(areaName)
	if type(areaName) ~= "string" or areaName == "" then return end
	if not ZSBT or not ZSBT.db or not ZSBT.db.profile or not ZSBT.db.profile.scrollAreas then return end
	if not ZSBT.db.profile.scrollAreas[areaName] then return end
	selectedScrollArea = areaName
	local reg = LibStub and LibStub("AceConfigRegistry-3.0", true)
	if reg and reg.NotifyChange then
		reg:NotifyChange("ZSBT")
	end
end

local function ReplaceScrollAreaRefsInProfile(oldName, newName)
    if not oldName or not newName or oldName == newName then return end
    if not ZSBT or not ZSBT.db or not ZSBT.db.profile then return end

    local function walk(tbl)
        for k, v in pairs(tbl) do
            if type(v) == "table" then
                walk(v)
            elseif k == "scrollArea" and v == oldName then
                tbl[k] = newName
            end
        end
    end

    walk(ZSBT.db.profile)
end

local function CreateDefaultScrollArea(name)
    name = name or "Incoming"
    if ZSBT.db.profile.scrollAreas[name] then return name end

    ZSBT.db.profile.scrollAreas[name] = {
        xOffset   = -450,
        yOffset   = 250,
        width     = 200,
        height    = 300,
        alignment = "Center",
        direction = "Up",
        animation = "Straight",
        animSpeed = 1.0,
        font      = {
            useGlobal = true,
            face      = ZSBT.db.profile.general.font.face,
            size      = ZSBT.db.profile.general.font.size,
            outline   = ZSBT.db.profile.general.font.outline,
            alpha     = ZSBT.db.profile.general.font.alpha,
        },
    }
    return name
end

local function MakeUniqueScrollAreaName(base)
    base = base or "New Area"
    if not ZSBT.db.profile.scrollAreas[base] then return base end
    local i = 2
    while true do
        local candidate = base .. " " .. i
        if not ZSBT.db.profile.scrollAreas[candidate] then
            return candidate
        end
        i = i + 1
    end
end

function ZSBT.DeleteScrollAreaByName(areaName, allowLast)
	if type(areaName) ~= "string" or areaName == "" then return end
	if not (ZSBT and ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.scrollAreas) then return end
	if not ZSBT.db.profile.scrollAreas[areaName] then return end

	local count = 0
	for _ in pairs(ZSBT.db.profile.scrollAreas) do count = count + 1 end
	if count <= 1 and not allowLast then
		return
	end

	-- Pick a fallback scroll area for rerouting references.
	local fallback = nil
	for name in pairs(ZSBT.db.profile.scrollAreas) do
		if name ~= areaName then
			fallback = name
			break
		end
	end

	ZSBT.db.profile.scrollAreas[areaName] = nil

	if not fallback then
		-- We deleted the last one; recreate a default.
		fallback = CreateDefaultScrollArea("Incoming")
	end

	ReplaceScrollAreaRefsInProfile(areaName, fallback)
	selectedScrollArea = fallback
	if renameScrollAreaBuffer == areaName then
		renameScrollAreaBuffer = ""
	end
	if createScrollAreaBuffer == areaName then
		createScrollAreaBuffer = ""
	end

	if ZSBT.IsScrollAreasUnlocked and ZSBT.IsScrollAreasUnlocked() and ZSBT.RefreshScrollAreaFrames then
		ZSBT.RefreshScrollAreaFrames()
	end
	local reg = LibStub and LibStub("AceConfigRegistry-3.0", true)
	if reg and reg.NotifyChange then
		reg:NotifyChange("ZSBT")
	end
	if ZSBT.Addon and ZSBT.Addon.Print then
		ZSBT.Addon:Print("Deleted scroll area: " .. areaName)
	end
end

function ZSBT.BuildTab_ScrollAreas()
    return {
        type  = "group",
		name  = "|cFFFFD100Scroll Areas|r",
        order = 2,
        args  = {
            ----------------------------------------------------------------
            -- Area Selection & Management
            ----------------------------------------------------------------
            headerAreas = {
                type  = "header",
                name  = "Scroll Area Management",
                order = 1,
            },
            spacerAreas = {
                type  = "description",
                name  = " ",
                order = 1.5,
                width = "full",
            },

            -- Line 1: Select + Delete
            rowSelect = {
                type   = "group",
                name   = "",
                inline = true,
                order  = 2,
                args   = {
                    selectArea = {
                        type   = "select",
                        name   = "Select Scroll Area",
                        desc   = "Choose a scroll area to configure.",
                        order  = 1,
                        width  = "double",
                        values = function() return ZSBT.GetScrollAreaNames() end,
                        get    = function() return EnsureSelectedScrollArea() end,
                        set    = function(_, val)
                            selectedScrollArea = val
                            LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                        end,
                    },
                    deleteArea = {
                        type     = "execute",
                        name     = "Delete Selected",
                        desc     = "Remove the currently selected scroll area.",
                        order    = 2,
                        width    = "normal",
                        disabled = function() return not EnsureSelectedScrollArea() end,
                        func     = function()
                            local sel = EnsureSelectedScrollArea()
                            if not sel then return end

                            local count = 0
                            for _ in pairs(ZSBT.db.profile.scrollAreas) do count = count + 1 end

                            if count <= 1 then
                                -- Last area safeguard: we never allow zero areas. We delete, then immediately create a new default.
                                StaticPopup_Show("TRUESTRIKE_DELETE_LAST_SCROLLAREA", sel, nil, sel)
                                return
                            end

                            StaticPopup_Show("TRUESTRIKE_DELETE_SCROLLAREA", sel, nil, sel)
                        end,
                    },
                },
            },

            -- Line 2: Rename + Apply
            rowRename = {
                type   = "group",
                name   = "",
                inline = true,
                order  = 3,
                args   = {
                    renameAreaName = {
                        type   = "input",
                        name   = "Rename Selected",
                        desc   = "Rename the currently selected scroll area.",
                        order  = 1,
                        width  = "double",
                        hidden = function() return not EnsureSelectedScrollArea() end,
                        get    = function()
                            if renameScrollAreaBuffer == "" then
                                return EnsureSelectedScrollArea() or ""
                            end
                            return renameScrollAreaBuffer
                        end,
                        set    = function(_, val)
                            renameScrollAreaBuffer = strtrim(val or "")
                        end,
                    },
                    applyRename = {
                        type     = "execute",
                        name     = "Apply Rename",
                        desc     = "Apply the rename to the selected scroll area.",
                        order    = 2,
                        width    = "normal",
                        hidden   = function() return not EnsureSelectedScrollArea() end,
                        disabled = function()
                            local sel = EnsureSelectedScrollArea()
                            local newName = strtrim(renameScrollAreaBuffer or "")
                            if not sel or newName == "" or newName == sel then return true end
                            return ZSBT.db.profile.scrollAreas[newName] ~= nil
                        end,
                        func     = function()
                            local oldName = EnsureSelectedScrollArea()
                            local newName = strtrim(renameScrollAreaBuffer or "")
                            if not oldName or newName == "" or newName == oldName then return end

                            if ZSBT.db.profile.scrollAreas[newName] then
                                ZSBT.Addon:Print("Scroll area '" .. newName .. "' already exists.")
                                return
                            end

                            ZSBT.db.profile.scrollAreas[newName] = ZSBT.db.profile.scrollAreas[oldName]
                            ZSBT.db.profile.scrollAreas[oldName] = nil

                            ReplaceScrollAreaRefsInProfile(oldName, newName)

                            selectedScrollArea = newName
                            renameScrollAreaBuffer = ""

                            if ZSBT.IsScrollAreasUnlocked and ZSBT.IsScrollAreasUnlocked() and ZSBT.RefreshScrollAreaFrames then
                                ZSBT.RefreshScrollAreaFrames()
                            end

                            LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                            ZSBT.Addon:Print("Renamed scroll area: " .. oldName .. " -> " .. newName)
                        end,
                    },
                },
            },

            -- Line 3: Create New Area (input + explicit Create button)
            rowCreate = {
                type   = "group",
                name   = "",
                inline = true,
                order  = 4,
                args   = {
                    createAreaName = {
                        type  = "input",
                        name  = "Create New Area",
                        desc  = "Type a name and press Enter (or click OK) to create. If blank, nothing will be created.",
                        order = 1,
                        width = "full",
                        get   = function() return createScrollAreaBuffer or "" end,
                        set   = function(_, val)
                            val = strtrim(val or "")
                            createScrollAreaBuffer = val
                            if val == "" then
                                LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                                return
                            end

                            if ZSBT.db.profile.scrollAreas[val] then
                                Addon:Print("Scroll area '" .. val .. "' already exists.")
                                return
                            end

                            ZSBT.db.profile.scrollAreas[val] = {
                                xOffset   = -450,
                                yOffset   = 250,
                                width     = 200,
                                height    = 300,
                                alignment = "Center",
                                direction = "Up",
                                animation = "Straight",
                                animSpeed = 1.0,
                                font      = {
                                    useGlobal = true,
                                    face      = ZSBT.db.profile.general.font.face,
                                    size      = ZSBT.db.profile.general.font.size,
                                    outline   = ZSBT.db.profile.general.font.outline,
                                    alpha     = ZSBT.db.profile.general.font.alpha,
                                },
                            }

                            selectedScrollArea = val
                            createScrollAreaBuffer = ""
                            Addon:Print("Created scroll area: " .. val)

                            if ZSBT.IsScrollAreasUnlocked and ZSBT.IsScrollAreasUnlocked() and ZSBT.RefreshScrollAreaFrames then
                                ZSBT.RefreshScrollAreaFrames()
                            end
                            LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                        end,
                    },
                },
            },

            -- Line 4: Lock / Unlock
            unlockAreas = {
                type  = "execute",
                name  = function()
                    if ZSBT.IsScrollAreasUnlocked and ZSBT.IsScrollAreasUnlocked() then
                        return "Lock Scroll Areas"
                    end
                    return "Unlock Scroll Areas"
                end,
                desc  = "Show draggable frames on screen for each scroll area. Drag to reposition, then lock to save.",
                order = 5,
                width = "full",
                func  = function()
                    if ZSBT.IsScrollAreasUnlocked and ZSBT.IsScrollAreasUnlocked() then
                        ZSBT.HideScrollAreaFrames()
                        Addon:Print("Scroll areas locked.")
                    else
                        ZSBT.ShowScrollAreaFrames()
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },

            ----------------------------------------------------------------
            -- Unlock / Lock Toggle
            ----------------------------------------------------------------
-- Geometry (only visible when an area is selected)
            ----------------------------------------------------------------
            spacerGeometry = {
                type   = "description",
                name   = " ",
                order  = 9.5,
                width  = "full",
                hidden = function() return not selectedScrollArea end,
            },
            headerGeometry = {
                type   = "header",
                name   = "Geometry",
                order  = 10,
                hidden = function() return not selectedScrollArea end,
            },
            xOffset = {
                type   = "range",
                name   = "X Offset",
                desc   = "Horizontal position relative to screen center.",
                order  = 11,
                min    = ZSBT.SCROLL_OFFSET_MIN,
                max    = ZSBT.SCROLL_OFFSET_MAX,
                step   = 5,
                hidden = function() return not selectedScrollArea end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return area and area.xOffset or 0
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if area then
                        area.xOffset = val
                        -- Update visualization frame in real-time
                        if ZSBT.UpdateScrollAreaFrames then
                            ZSBT.UpdateScrollAreaFrames()
                        end
                    end
                end,
            },
            yOffset = {
                type   = "range",
                name   = "Y Offset",
                desc   = "Vertical position relative to screen center.",
                order  = 12,
                min    = ZSBT.SCROLL_OFFSET_MIN,
                max    = ZSBT.SCROLL_OFFSET_MAX,
                step   = 5,
                hidden = function() return not selectedScrollArea end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return area and area.yOffset or 0
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if area then
                        area.yOffset = val
                        -- Update visualization frame in real-time
                        if ZSBT.UpdateScrollAreaFrames then
                            ZSBT.UpdateScrollAreaFrames()
                        end
                    end
                end,
            },
            areaWidth = {
                type   = "range",
                name   = "Width",
                desc   = "Width of the scroll area in pixels.",
                order  = 13,
                min    = ZSBT.SCROLL_WIDTH_MIN,
                max    = ZSBT.SCROLL_WIDTH_MAX,
                step   = 10,
                hidden = function() return not selectedScrollArea end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return area and area.width or 200
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if area then
                        area.width = val
                        -- Update visualization frame in real-time
                        if ZSBT.UpdateScrollAreaFrames then
                            ZSBT.UpdateScrollAreaFrames()
                        end
                    end
                end,
            },
            areaHeight = {
                type   = "range",
                name   = "Height",
                desc   = "Height of the scroll area in pixels.",
                order  = 14,
                min    = ZSBT.SCROLL_HEIGHT_MIN,
                max    = ZSBT.SCROLL_HEIGHT_MAX,
                step   = 10,
                hidden = function() return not selectedScrollArea end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return area and area.height or 300
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if area then
                        area.height = val
                        -- Update visualization frame in real-time
                        if ZSBT.UpdateScrollAreaFrames then
                            ZSBT.UpdateScrollAreaFrames()
                        end
                    end
                end,
            },

            ----------------------------------------------------------------
            -- Font Override (per selected area)
            ----------------------------------------------------------------
            headerAreaFont = {
                type   = "header",
                name   = "Font Override",
                order  = 15,
                hidden = function() return not selectedScrollArea end,
            },
            areaFontUseGlobal = {
                type   = "toggle",
                name   = "Use Global Font",
                desc   = "When enabled, this scroll area uses the Master Font from the General tab.",
                order  = 16,
                width  = "full",
                hidden = function() return not selectedScrollArea end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    local f = area and area.font
                    if not f then return true end
                    return f.useGlobal ~= false
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if not area then return end
                    area.font = area.font or {
                        useGlobal = true,
                        face      = ZSBT.db.profile.general.font.face,
                        size      = ZSBT.db.profile.general.font.size,
                        outline   = ZSBT.db.profile.general.font.outline,
                        alpha     = ZSBT.db.profile.general.font.alpha,
                    }
                    area.font.useGlobal = val and true or false
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            areaFontFace = {
                type   = "select",
                name   = "Font Face",
                desc   = "Font used for this scroll area when Use Global Font is disabled.",
                order  = 17,
                values = function() return ZSBT.BuildFontDropdown() end,
                hidden = function()
                    if not selectedScrollArea then return true end
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return not area or not area.font or area.font.useGlobal ~= false
                end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return area and area.font and area.font.face or ZSBT.db.profile.general.font.face
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if not area then return end
                    area.font = area.font or { useGlobal = false }
                    area.font.face = val
                end,
            },
            areaFontSize = {
                type   = "range",
                name   = "Font Size",
                desc   = "Font size for this scroll area when Use Global Font is disabled.",
                order  = 18,
                min    = ZSBT.FONT_SIZE_MIN,
                max    = ZSBT.FONT_SIZE_MAX,
                step   = 1,
                hidden = function()
                    if not selectedScrollArea then return true end
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return not area or not area.font or area.font.useGlobal ~= false
                end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return area and area.font and area.font.size or ZSBT.db.profile.general.font.size
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if not area then return end
                    area.font = area.font or { useGlobal = false }
                    area.font.size = val
                end,
            },
            areaFontOutline = {
                type   = "select",
                name   = "Outline Style",
                desc   = "Outline style for this scroll area when Use Global Font is disabled.",
                order  = 19,
                values = ZSBT.ValuesFromKeys(ZSBT.OUTLINE_STYLES),
                hidden = function()
                    if not selectedScrollArea then return true end
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return not area or not area.font or area.font.useGlobal ~= false
                end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return area and area.font and area.font.outline or ZSBT.db.profile.general.font.outline
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if not area then return end
                    area.font = area.font or { useGlobal = false }
                    area.font.outline = val
                end,
            },
            areaFontAlpha = {
                type      = "range",
                name      = "Text Opacity",
                desc      = "Text opacity for this scroll area when Use Global Font is disabled.",
                order     = 20,
                min       = ZSBT.ALPHA_MIN,
                max       = ZSBT.ALPHA_MAX,
                step      = 0.05,
                isPercent = true,
                hidden = function()
                    if not selectedScrollArea then return true end
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return not area or not area.font or area.font.useGlobal ~= false
                end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return area and area.font and area.font.alpha or ZSBT.db.profile.general.font.alpha
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if not area then return end
                    area.font = area.font or { useGlobal = false }
                    area.font.alpha = val
                end,
            },

            ----------------------------------------------------------------
            -- Layout & Animation
            ----------------------------------------------------------------
            spacerLayout = {
                type   = "description",
                name   = " ",
                order  = 20.5,
                width  = "full",
                hidden = function() return not selectedScrollArea end,
            },
            headerLayout = {
                type   = "header",
                name   = "Layout & Animation",
                order  = 21,
                hidden = function() return not selectedScrollArea end,
            },
            alignment = {
                type   = "select",
                name   = "Text Alignment",
                desc   = "Horizontal text alignment within the scroll area.",
                order  = 22,
                values = ZSBT.ValuesFromKeys(ZSBT.TEXT_ALIGNMENTS),
                hidden = function() return not selectedScrollArea end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return area and area.alignment or "Center"
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if area then area.alignment = val end
                end,
            },
            direction = {
                type   = "select",
                name   = "Scroll Direction",
                desc   = "Direction text scrolls.",
                order  = 23,
                values = ZSBT.ValuesFromKeys(ZSBT.SCROLL_DIRECTIONS),
                hidden = function() return not selectedScrollArea end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return area and area.direction or "Up"
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if area then area.direction = val end
                end,
            },
            animation = {
                type   = "select",
                name   = "Animation Style",
                desc   = "How text moves through the scroll area.",
                order  = 24,
                values = ZSBT.ValuesFromKeys(ZSBT.ANIMATION_STYLES),
                hidden = function() return not selectedScrollArea end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if not area then return "Straight" end
                    -- Backward-compat migration: fold Parabola Left/Right into Parabola + side
                    if area.animation == "Parabola Left" or area.animation == "parabola_left" then
                        area.animation = "Parabola"
                        area.parabolaSide = "Left"
                    elseif area.animation == "Parabola Right" or area.animation == "parabola_right" then
                        area.animation = "Parabola"
                        area.parabolaSide = "Right"
                    elseif area.animation == "Fireworks Bottom" or area.animation == "fireworks_bottom" then
                        area.animation = "Fireworks"
                        area.fireworksOrigin = "Bottom"
                    elseif area.animation == "Fireworks Top" or area.animation == "fireworks_top" then
                        area.animation = "Fireworks"
                        area.fireworksOrigin = "Top"
                    elseif area.animation == "Fireworks Left" or area.animation == "fireworks_left" then
                        area.animation = "Fireworks"
                        area.fireworksOrigin = "Left"
                    elseif area.animation == "Fireworks Right" or area.animation == "fireworks_right" then
                        area.animation = "Fireworks"
                        area.fireworksOrigin = "Right"
                    elseif area.animation == "Waterfall Down" or area.animation == "waterfall_down" then
                        area.animation = "Waterfall"
                        area.direction = "Down"
                        if not area.waterfallStyle then area.waterfallStyle = "Smooth" end
                    elseif area.animation == "Waterfall Up" or area.animation == "waterfall_up" then
                        area.animation = "Waterfall"
                        area.direction = "Up"
                        if not area.waterfallStyle then area.waterfallStyle = "Smooth" end
                    end
                    return area.animation or "Straight"
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if area then area.animation = val end
                    -- Force AceConfig to re-evaluate hidden states (animSpeed depends on this)
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            waterfallStyle = {
                type   = "select",
                name   = "Waterfall Style",
                desc   = "Add wave/ripple character to the waterfall movement.",
                order  = 24.7,
                values = {
                    Smooth = "Smooth",
                    Wavy = "Wavy",
                    Ripple = "Ripple",
                    Turbulent = "Turbulent",
                },
                hidden = function()
                    if not selectedScrollArea then return true end
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return not area or area.animation ~= "Waterfall"
                end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return (area and area.waterfallStyle) or "Smooth"
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if not area then return end
                    area.waterfallStyle = val
                end,
            },
            fireworksOrigin = {
                type   = "select",
                name   = "Fireworks Origin",
                desc   = "Where the fireworks burst originates from.",
                order  = 24.6,
                values = { Bottom = "Bottom", Top = "Top", Left = "Left", Right = "Right" },
                hidden = function()
                    if not selectedScrollArea then return true end
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return not area or area.animation ~= "Fireworks"
                end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return (area and area.fireworksOrigin) or "Bottom"
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if not area then return end
                    area.fireworksOrigin = val
                end,
            },
            parabolaSide = {
                type   = "select",
                name   = "Parabola Side",
                desc   = "Which side the parabola arcs toward (C vs backwards-C).",
                order  = 24.5,
                values = { Left = "Left", Right = "Right" },
                hidden = function()
                    if not selectedScrollArea then return true end
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return not area or area.animation ~= "Parabola"
                end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return (area and area.parabolaSide) or "Left"
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if not area then return end
                    area.parabolaSide = val
                end,
            },
            animSpeed = {
                type   = "range",
                name   = "Animation Speed",
                desc   = "Duration in seconds for text animation (1.0 = normal).",
                order  = 25,
                width  = "full",
                min    = 0.5,
                max    = 3.0,
                step   = 0.1,
                -- Hidden when no area selected, or when animation style is Static
                hidden = function()
                    if not selectedScrollArea then return true end
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if area and area.animation == "Static" then return true end
                    return false
                end,
                get    = function()
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    return area and area.animSpeed or 1.0
                end,
                set    = function(_, val)
                    local area = ZSBT.db.profile.scrollAreas[selectedScrollArea]
                    if area then area.animSpeed = val end
                end,
            },
            testAnimation = {
                type     = "execute",
                name     = "Test Selected",
                desc     = "Fire 3 test events into this scroll area using its current settings. " ..
                           "Scroll areas must be unlocked to test.",
                order    = 26,
                width    = full,
                hidden   = function() return not selectedScrollArea end,
                disabled = function()
                    if not selectedScrollArea then return true end
                    if ZSBT.IsScrollAreasUnlocked and not ZSBT.IsScrollAreasUnlocked() then
                        return true
                    end
                    return false
                end,
                func     = function()
                    if ZSBT.TestScrollArea then
                        ZSBT.TestScrollArea(selectedScrollArea)
                    else
                        Addon:Print("Display system not yet available.")
                    end
                end,
            },
            testCrit = {
                type     = "execute",
                name     = "Test Crit",
                desc     = "Fire 3 crit test events with the Pow/sticky animation and crit font settings. " ..
                           "Scroll areas must be unlocked to test.",
                order    = 26.5,
                width    = full,
                hidden   = function() return not selectedScrollArea end,
                disabled = function()
                    if not selectedScrollArea then return true end
                    if ZSBT.IsScrollAreasUnlocked and not ZSBT.IsScrollAreasUnlocked() then
                        return true
                    end
                    return false
                end,
                func     = function()
                    if ZSBT.TestScrollAreaCrit then
                        local areaToTest = selectedScrollArea
                        local oc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.outgoing and ZSBT.db.profile.outgoing.crits
                        if oc and oc.enabled == true and type(oc.scrollArea) == "string" and oc.scrollArea ~= "" then
                            areaToTest = oc.scrollArea
                        end
                        ZSBT.TestScrollAreaCrit(areaToTest)
						if ZSBT.TestIncomingHealCrit then
							ZSBT.TestIncomingHealCrit()
						end
						if ZSBT.TestIncomingDamageCrit then
							ZSBT.TestIncomingDamageCrit()
						end
                    else
                        Addon:Print("Crit test not yet available.")
                    end
                end,
            },
            testAllAreas = {
                type     = "execute",
                name     = function()
                    if ZSBT.IsContinuousTesting and ZSBT.IsContinuousTesting() then
                        return "Stop All Tests"
                    end
                    return "Test All (Unlocked)"
                end,
                desc     = "Toggle continuous test animation on all unlocked scroll areas. " ..
                           "Animations repeat every 3 seconds. Scroll areas must be unlocked to test.",
                order    = 27,
                width    = full,
                disabled = function()
                    -- Disabled if areas aren't unlocked (unless already running, then allow stop)
                    if ZSBT.IsContinuousTesting and ZSBT.IsContinuousTesting() then
                        return false
                    end
                    if ZSBT.IsScrollAreasUnlocked and not ZSBT.IsScrollAreasUnlocked() then
                        return true
                    end
                    return false
                end,
                func     = function()
                    if ZSBT.IsContinuousTesting and ZSBT.IsContinuousTesting() then
                        if ZSBT.StopContinuousTesting then
                            ZSBT.StopContinuousTesting()
                        end
                    else
                        if ZSBT.StartContinuousTesting then
                            ZSBT.StartContinuousTesting()
                        end
                    end
                end,
            },

            selectedAreaLabel = {
                type   = "description",
                name   = function()
                    if not selectedScrollArea then return "" end
                    return "|cFF888888Selected:|r " .. selectedScrollArea
                end,
                order  = 28,
                width  = "full",
                fontSize = "medium",
                hidden = function() return not selectedScrollArea end,
            },
        },
    }
end

------------------------------------------------------------------------
-- TAB 3: INCOMING
-- Incoming damage and healing configuration.
------------------------------------------------------------------------
function ZSBT.BuildTab_Incoming()
    local function cap()
        return ZSBT.Core and ZSBT.Core.IncomingProbe and ZSBT.Core.IncomingProbe.cap
    end

    local function reportLine()
        local p = ZSBT.Core and ZSBT.Core.IncomingProbe
        if not p or not p.GetCapabilityReport then
            return "Incoming probe not loaded."
        end
        local r = p:GetCapabilityReport()
        return ("Probe: source=%s | flags=%s | school=%s | periodic=%s | buffer=%d/%d")
            :format(r.source, r.hasFlagText, r.hasSchool, r.hasPeriodic, r.bufferCount, r.bufferMax)
    end

    return {
        type  = "group",
		name  = "|cFFFFD100Incoming|r",
        order = 4,
        args  = {
            ----------------------------------------------------------------
            -- Incoming Damage
            ----------------------------------------------------------------
            headerDamage = {
                type  = "header",
                name  = "Incoming Damage",
                order = 1,
            },
            damageEnabled = {
                type  = "toggle",
                name  = "Show Incoming Damage",
                desc  = "Display damage taken by your character.",
                width = "full",
                order = 2,
                get   = function() return ZSBT.db.profile.incoming.damage.enabled end,
                set   = function(_, val) ZSBT.db.profile.incoming.damage.enabled = val end,
            },
            damageScrollArea = {
                type   = "select",
                name   = "Scroll Area",
                desc   = "Which scroll area displays incoming damage.",
                order  = 3,
                values = function() return ZSBT.GetScrollAreaNames() end,
                get    = function() return ZSBT.db.profile.incoming.damage.scrollArea end,
                set    = function(_, val) ZSBT.db.profile.incoming.damage.scrollArea = val end,
            },
			damageCritScrollArea = {
				type   = "select",
				name   = "Crit Scroll Area (optional)",
				desc   = "Override scroll area for incoming damage crits only. Leave blank to use the normal Incoming Damage scroll area.",
				order  = 3.05,
				hidden = function() return true end,
				values = function()
					local t = ZSBT.GetScrollAreaNames()
					t[""] = "(Use normal)"
					return t
				end,
				get    = function()
					return ZSBT.db.profile.incoming.damage.critScrollArea or ""
				end,
				set    = function(_, val)
					ZSBT.db.profile.incoming.damage.critScrollArea = (val == "") and nil or val
				end,
			},
            damageShowFlags = {
                type  = "toggle",
                name  = "Show Damage Flags",
                desc  = "Display flags like Crushing, Glancing, Absorb, Block, Resist.",
                width = "full",
                order = 4,
                disabled = function()
                    local c = cap()
                    return c and c.hasFlagText == false
                end,
                get   = function() return ZSBT.db.profile.incoming.damage.showFlags end,
                set   = function(_, val) ZSBT.db.profile.incoming.damage.showFlags = val end,
            },
            damageShowMisses = {
                type  = "toggle",
                name  = "Show Misses / Avoids",
                desc  = "Display avoidance text like Miss, Dodge, Parry, Block, Resist, Absorb.",
                width = "full",
                order = 4.1,
                get   = function()
                    local d = ZSBT.db.profile.incoming.damage
                    return d == nil or d.showMisses ~= false
                end,
                set   = function(_, val)
                    ZSBT.db.profile.incoming.damage.showMisses = val and true or false
                end,
            },
            thresholdTip = {
                type     = "description",
                name     = "Tip: You can type a value above the slider (up to 15000).",
                order    = 4.2,
                width    = "full",
                fontSize = "medium",
            },

            ----------------------------------------------------------------
            -- Color Settings
            ----------------------------------------------------------------
            headerColors = {
                type  = "header",
                name  = "Color Settings",
                order = 4.25,
            },
            useSchoolColors = {
                type  = "toggle",
                name  = "Use Damage School Colors (may be limited)",
                desc  = "Color incoming damage numbers by damage school (Fire, Frost, etc.). On modern WoW, some events may not provide reliable school information.",
                width = "full",
                order = 4.26,
                disabled = function()
                    local cap = ZSBT.GetUnitCombatCapabilities
                    if type(cap) ~= "function" then return false end
                    local c = cap()
                    return c and c.hasSchool == false
                end,
                get   = function() return ZSBT.db.profile.incoming.useSchoolColors end,
                set   = function(_, val) ZSBT.db.profile.incoming.useSchoolColors = val end,
            },
            customDamageColor = {
                type     = "color",
                name     = "Custom Damage Color",
                desc     = "Fallback damage color when school colors are disabled.",
                order    = 4.27,
                disabled = function() return ZSBT.db.profile.incoming.useSchoolColors end,
                get      = function()
                    local c = ZSBT.db.profile.incoming.customDamageColor
                    return c.r, c.g, c.b
                end,
                set      = function(_, r, g, b)
                    local c = ZSBT.db.profile.incoming.customDamageColor
                    c.r, c.g, c.b = r, g, b
                end,
            },
            customHealingColor = {
                type     = "color",
                name     = "Custom Healing Color",
                desc     = "Fallback healing color when school colors are disabled.",
                order    = 4.28,
                disabled = function() return ZSBT.db.profile.incoming.useSchoolColors end,
                get      = function()
                    local c = ZSBT.db.profile.incoming.customHealingColor
                    return c.r, c.g, c.b
                end,
                set      = function(_, r, g, b)
                    local c = ZSBT.db.profile.incoming.customHealingColor
                    c.r, c.g, c.b = r, g, b
                end,
            },
            showSpellIcons = {
                type  = "toggle",
                name  = "Show Spell Icons (may be inaccurate)",
                desc  = "Display the spell icon next to incoming damage/heal numbers. On modern WoW, spell attribution is not always reliable, so icons may be incorrect.",
                width = "full",
                order = 4.29,
                get   = function() return ZSBT.db.profile.incoming.showSpellIcons end,
                set   = function(_, val) ZSBT.db.profile.incoming.showSpellIcons = val end,
            },
			headerCritsSplitDamage = {
				type  = "header",
				name  = "Incoming Crit Damage",
				order = 4.41,
			},
			incomingCritDamageFontEnabled = {
				type  = "toggle",
				name  = "Override Crit Font (Incoming Crit Damage)",
				desc  = "If enabled, incoming critical damage uses this crit font instead of the Global Crit Font.",
				order = 4.415,
				width = "full",
				get   = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return type(cf) == "table" and cf.enabled == true
				end,
				set   = function(_, v)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.critFont = ZSBT.db.profile.incoming.critDamage.critFont or {}
					ZSBT.db.profile.incoming.critDamage.critFont.enabled = v and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			incomingCritDamageFontFace = {
				type   = "select",
				name   = "Crit Font Face",
				desc   = "Font used for incoming critical damage.",
				order  = 4.416,
				values = function() return ZSBT.BuildFontDropdown() end,
				disabled = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get    = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return cf and cf.face or "__use_master__"
				end,
				set    = function(_, val)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.critFont = ZSBT.db.profile.incoming.critDamage.critFont or {}
					if val == "__use_master__" then
						ZSBT.db.profile.incoming.critDamage.critFont.face = nil
					else
						ZSBT.db.profile.incoming.critDamage.critFont.face = val
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			incomingCritDamageFontSize = {
				type  = "range",
				name  = "Crit Font Size",
				desc  = "Font size for incoming critical damage text.",
				order = 4.417,
				min   = ZSBT.FONT_SIZE_MIN,
				max   = 48,
				step  = 1,
				disabled = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true) or (cf and cf.useScale == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get   = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return (cf and cf.size) or 28
				end,
				set   = function(_, val)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.critFont = ZSBT.db.profile.incoming.critDamage.critFont or {}
					ZSBT.db.profile.incoming.critDamage.critFont.size = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			incomingCritDamageUseScale = {
				type  = "toggle",
				name  = "Use Crit Scale (instead of fixed size)",
				desc  = "When enabled, crit size is derived from your normal font size using Crit Scale.",
				order = 4.418,
				width = "full",
				disabled = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get   = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return cf and cf.useScale == true
				end,
				set   = function(_, v)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.critFont = ZSBT.db.profile.incoming.critDamage.critFont or {}
					ZSBT.db.profile.incoming.critDamage.critFont.useScale = v and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			incomingCritDamageAnim = {
				type   = "select",
				name   = "Crit Animation",
				desc   = "Choose whether crits use the sticky Pow animation or follow the scroll area's animation.",
				order  = 4.419,
				values = { Pow = "Pow (Sticky)", Area = "Use Scroll Area Animation" },
				disabled = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get    = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return (cf and (cf.anim == "Area" or cf.anim == "Pow")) and cf.anim or "Pow"
				end,
				set    = function(_, val)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.critFont = ZSBT.db.profile.incoming.critDamage.critFont or {}
					ZSBT.db.profile.incoming.critDamage.critFont.anim = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			incomingCritDamageFontOutline = {
				type   = "select",
				name   = "Crit Outline",
				desc   = "Outline style for incoming critical damage text.",
				order  = 4.42,
				values = { None = "None", Thin = "Thin", Thick = "Thick", Monochrome = "Monochrome" },
				disabled = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get    = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return (cf and cf.outline) or "Thick"
				end,
				set    = function(_, val)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.critFont = ZSBT.db.profile.incoming.critDamage.critFont or {}
					ZSBT.db.profile.incoming.critDamage.critFont.outline = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			incomingCritDamageFontScale = {
				type  = "range",
				name  = "Crit Scale",
				desc  = "Scale multiplier vs normal font size.",
				order = 4.421,
				min   = 1.0,
				max   = 3.0,
				step  = 0.1,
				disabled = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true) or not (cf and cf.useScale == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get   = function()
					local cf = ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.critFont
					return (cf and cf.scale) or 1.5
				end,
				set   = function(_, val)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.critFont = ZSBT.db.profile.incoming.critDamage.critFont or {}
					ZSBT.db.profile.incoming.critDamage.critFont.scale = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			critDamageEnabled = {
				type  = "toggle",
				name  = "Route Incoming Crit Damage to a Different Scroll Area",
				desc  = "If enabled, incoming critical damage uses the crit scroll area below.",
				width = "full",
				order = 4.422,
				get   = function() return ZSBT.db.profile.incoming.critDamage and ZSBT.db.profile.incoming.critDamage.enabled == true end,
				set   = function(_, v)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.enabled = v and true or false
				end,
			},
			critDamageScrollArea = {
				type   = "select",
				name   = "Crit Damage Scroll Area",
				desc   = "Scroll area to use for incoming critical damage when routing is enabled.",
				order  = 4.43,
				values = function() return ZSBT.GetScrollAreaNames() end,
				disabled = function()
					local c = ZSBT.db.profile.incoming.critDamage
					return not (c and c.enabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.incoming.critDamage
					return (c and type(c.scrollArea) == "string" and c.scrollArea ~= "") and c.scrollArea or "Incoming"
				end,
				set = function(_, v)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.scrollArea = v
				end,
			},
			critDamageColor = {
				type  = "color",
				name  = "Crit Damage Color",
				desc  = "Color for incoming critical damage when routed to the Crit Damage Scroll Area.",
				order = 4.44,
				get = function()
					local c = ZSBT.db.profile.incoming.critDamage
					local col = c and c.color
					if type(col) ~= "table" then return 1, 0.2, 0.2 end
					return col.r or 1, col.g or 0.2, col.b or 0.2
				end,
				set = function(_, r, g, b)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.color = { r = r, g = g, b = b }
				end,
			},
			critDamageSticky = {
				type  = "toggle",
				name  = "Sticky Crit Damage (slightly bigger + longer)",
				desc  = "Makes incoming critical damage feel more impactful by slightly increasing size and on-screen duration.",
				width = "full",
				order = 4.45,
				get   = function()
					local c = ZSBT.db.profile.incoming.critDamage
					return c == nil or c.sticky ~= false
				end,
				set   = function(_, v)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.sticky = v and true or false
				end,
			},
			critDamageStickyJiggle = {
				type  = "toggle",
				name  = "Sticky Jiggle (shake)",
				desc  = "When Sticky is enabled, also apply the shake/jiggle animation. Disable this if you want Sticky sizing/placement without shaking.",
				width = "full",
				order = 4.451,
				hidden = function()
					local c = ZSBT.db.profile.incoming.critDamage
					return not (c == nil or c.sticky ~= false)
				end,
				get   = function()
					local c = ZSBT.db.profile.incoming.critDamage
					return c == nil or c.stickyJiggle ~= false
				end,
				set   = function(_, v)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.stickyJiggle = v and true or false
				end,
			},
			critDamageSoundEnabled = {
				type = "toggle",
				name = "Play a Sound on Incoming Crit Damage",
				desc = "Plays a sound when you take a critical hit.",
				width = "full",
				order = 4.46,
				get = function()
					local c = ZSBT.db.profile.incoming.critDamage
					return c and c.soundEnabled == true
				end,
				set = function(_, v)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.soundEnabled = v and true or false
				end,
			},
			critDamageSound = {
				type = "select",
				name = "Crit Damage Sound",
				desc = "Sound to play when an incoming crit damage triggers.",
				order = 4.47,
				values = function() return (ZSBT.BuildSoundDropdown and ZSBT.BuildSoundDropdown()) or { ["None"] = "None" } end,
				disabled = function()
					local c = ZSBT.db.profile.incoming.critDamage
					return not (c and c.soundEnabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.incoming.critDamage
					return (c and type(c.sound) == "string" and c.sound ~= "") and c.sound or "None"
				end,
				set = function(_, v)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.sound = v
				end,
			},
			critDamageSoundTest = {
				type = "execute",
				name = "Test Crit Damage Sound",
				order = 4.48,
				disabled = function()
					local c = ZSBT.db.profile.incoming.critDamage
					return not (c and c.soundEnabled == true)
				end,
				func = function()
					local c = ZSBT.db.profile.incoming.critDamage
					if c and ZSBT.PlayLSMSound then
						ZSBT.PlayLSMSound(c.sound)
					end
				end,
			},
			critDamageMinSoundAmount = {
				type = "range",
				name = "Minimum Crit Damage Amount (sound)",
				desc = "Only play the crit sound when the crit amount is at or above this value. In instances, the exact amount may be unavailable.",
				order = 4.49,
				min = 0,
				max = 999999,
				softMax = 250000,
				step = 100,
				disabled = function()
					local c = ZSBT.db.profile.incoming.critDamage
					return not (c and c.soundEnabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.incoming.critDamage
					return (c and tonumber(c.minSoundAmount)) or 0
				end,
				set = function(_, v)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.minSoundAmount = tonumber(v) or 0
				end,
			},
			critDamageInstanceSoundMode = {
				type = "select",
				name = "Instances: When amount is unavailable (damage)",
				desc = "In dungeons/raids, crit amounts can be protected/secret. Choose how crit sounds behave when the amount can't be safely compared.",
				order = 4.5,
				values = function()
					return {
						["Any Crit"] = "Any Crit",
						["Only when amount is known"] = "Only when amount is known",
					}
				end,
				disabled = function()
					local c = ZSBT.db.profile.incoming.critDamage
					return not (c and c.soundEnabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.incoming.critDamage
					return (c and type(c.instanceSoundMode) == "string" and c.instanceSoundMode ~= "") and c.instanceSoundMode or "Only when amount is known"
				end,
				set = function(_, v)
					ZSBT.db.profile.incoming.critDamage = ZSBT.db.profile.incoming.critDamage or {}
					ZSBT.db.profile.incoming.critDamage.instanceSoundMode = v
				end,
			},
            damageMinThreshold = {
                type    = "range",
                name    = "Minimum Damage Threshold",
                desc    = "Suppress incoming damage below this value (0 = show all).",
                order   = 5,
                min     = 0,
                max     = 15000,
                softMax = 3000,
                step    = 50,
                get     = function() return ZSBT.db.profile.incoming.damage.minThreshold end,
                set     = function(_, val) ZSBT.db.profile.incoming.damage.minThreshold = val end,
            },

            ----------------------------------------------------------------
            -- Incoming Healing
            ----------------------------------------------------------------
            headerHealing = {
                type  = "header",
                name  = "Incoming Healing",
                order = 10,
            },
            healingEnabled = {
                type  = "toggle",
                name  = "Show Incoming Healing",
                desc  = "Display healing received by your character.",
                width = "full",
                order = 11,
                get   = function() return ZSBT.db.profile.incoming.healing.enabled end,
                set   = function(_, val) ZSBT.db.profile.incoming.healing.enabled = val end,
            },
            healingScrollArea = {
                type   = "select",
                name   = "Scroll Area",
                desc   = "Which scroll area displays incoming healing.",
                order  = 12,
                values = function() return ZSBT.GetScrollAreaNames() end,
                get    = function() return ZSBT.db.profile.incoming.healing.scrollArea end,
                set    = function(_, val) ZSBT.db.profile.incoming.healing.scrollArea = val end,
            },
			healingCritScrollArea = {
				type   = "select",
				name   = "Crit Scroll Area (optional)",
				desc   = "Override scroll area for incoming healing crits only. Leave blank to use the normal Incoming Healing scroll area.",
				order  = 12.05,
				hidden = function() return true end,
				values = function()
					local t = ZSBT.GetScrollAreaNames()
					t[""] = "(Use normal)"
					return t
				end,
				get    = function()
					return ZSBT.db.profile.incoming.healing.critScrollArea or ""
				end,
				set    = function(_, val)
					ZSBT.db.profile.incoming.healing.critScrollArea = (val == "") and nil or val
				end,
			},
            healingShowHoTs = {
                type  = "toggle",
                name  = "Show HoT Ticks Separately",
                desc  = "Display each Heal-over-Time tick as its own number. (Requires periodic classification from the live source.)",
                width = "full",
                order = 13,
                get   = function() return ZSBT.db.profile.incoming.healing.showHoTTicks end,
                set   = function(_, val) ZSBT.db.profile.incoming.healing.showHoTTicks = val end,
            },
            showOverheal = {
                type  = "toggle",
                name  = "Show Overhealing (may be limited)",
                desc  = "Display overheal amount next to heals (e.g. 5000 (OH 1200)). On modern WoW, overheal data may be unavailable for some events.",
                width = "full",
                order = 13.5,
                get   = function() return ZSBT.db.profile.incoming.healing.showOverheal end,
                set   = function(_, val) ZSBT.db.profile.incoming.healing.showOverheal = val end,
            },
            healingMinThreshold = {
                type    = "range",
                name    = "Minimum Healing Threshold",
                desc    = "Suppress incoming heals below this value (0 = show all).",
                order   = 14,
                min     = 0,
                max     = 15000,
                softMax = 3000,
                step    = 50,
                get     = function() return ZSBT.db.profile.incoming.healing.minThreshold end,
                set     = function(_, val) ZSBT.db.profile.incoming.healing.minThreshold = val end,
            },
			headerCritsSplitHealing = {
				type  = "header",
				name  = "Incoming Crit Heals",
				order = 15,
			},
			incomingCritHealingFontEnabled = {
				type  = "toggle",
				name  = "Override Crit Font (Incoming Crit Heals)",
				desc  = "If enabled, incoming critical heals use this crit font instead of the Global Crit Font.",
				order = 15.01,
				width = "full",
				get   = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return type(cf) == "table" and cf.enabled == true
				end,
				set   = function(_, v)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.critFont = ZSBT.db.profile.incoming.critHealing.critFont or {}
					ZSBT.db.profile.incoming.critHealing.critFont.enabled = v and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			incomingCritHealingFontFace = {
				type   = "select",
				name   = "Crit Font Face",
				desc   = "Font used for incoming critical heals.",
				order  = 15.02,
				values = function() return ZSBT.BuildFontDropdown() end,
				disabled = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get    = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return cf and cf.face or "__use_master__"
				end,
				set    = function(_, val)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.critFont = ZSBT.db.profile.incoming.critHealing.critFont or {}
					if val == "__use_master__" then
						ZSBT.db.profile.incoming.critHealing.critFont.face = nil
					else
						ZSBT.db.profile.incoming.critHealing.critFont.face = val
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			incomingCritHealingFontSize = {
				type  = "range",
				name  = "Crit Font Size",
				desc  = "Font size for incoming critical heal text.",
				order = 15.03,
				min   = ZSBT.FONT_SIZE_MIN,
				max   = 48,
				step  = 1,
				disabled = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true) or (cf and cf.useScale == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get   = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return (cf and cf.size) or 28
				end,
				set   = function(_, val)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.critFont = ZSBT.db.profile.incoming.critHealing.critFont or {}
					ZSBT.db.profile.incoming.critHealing.critFont.size = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			incomingCritHealingUseScale = {
				type  = "toggle",
				name  = "Use Crit Scale (instead of fixed size)",
				desc  = "When enabled, crit size is derived from your normal font size using Crit Scale.",
				order = 15.035,
				width = "full",
				disabled = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get   = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return cf and cf.useScale == true
				end,
				set   = function(_, v)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.critFont = ZSBT.db.profile.incoming.critHealing.critFont or {}
					ZSBT.db.profile.incoming.critHealing.critFont.useScale = v and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			incomingCritHealingAnim = {
				type   = "select",
				name   = "Crit Animation",
				desc   = "Choose whether crits use the sticky Pow animation or follow the scroll area's animation.",
				order  = 15.04,
				values = { Pow = "Pow (Sticky)", Area = "Use Scroll Area Animation" },
				disabled = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get    = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return (cf and (cf.anim == "Area" or cf.anim == "Pow")) and cf.anim or "Pow"
				end,
				set    = function(_, val)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.critFont = ZSBT.db.profile.incoming.critHealing.critFont or {}
					ZSBT.db.profile.incoming.critHealing.critFont.anim = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			incomingCritHealingFontOutline = {
				type   = "select",
				name   = "Crit Outline",
				desc   = "Outline style for incoming critical heal text.",
				order  = 15.05,
				values = { None = "None", Thin = "Thin", Thick = "Thick", Monochrome = "Monochrome" },
				disabled = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get    = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return (cf and cf.outline) or "Thick"
				end,
				set    = function(_, val)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.critFont = ZSBT.db.profile.incoming.critHealing.critFont or {}
					ZSBT.db.profile.incoming.critHealing.critFont.outline = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			incomingCritHealingFontScale = {
				type  = "range",
				name  = "Crit Scale",
				desc  = "Scale multiplier vs normal font size.",
				order = 15.06,
				min   = 1.0,
				max   = 3.0,
				step  = 0.1,
				disabled = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true) or not (cf and cf.useScale == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get   = function()
					local cf = ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.critFont
					return (cf and cf.scale) or 1.5
				end,
				set   = function(_, val)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.critFont = ZSBT.db.profile.incoming.critHealing.critFont or {}
					ZSBT.db.profile.incoming.critHealing.critFont.scale = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			critHealingEnabled = {
				type  = "toggle",
				name  = "Route Incoming Crit Heals to a Different Scroll Area",
				desc  = "If enabled, incoming critical heals use the crit scroll area below.",
				width = "full",
				order = 15.1,
				get   = function() return ZSBT.db.profile.incoming.critHealing and ZSBT.db.profile.incoming.critHealing.enabled == true end,
				set   = function(_, v)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.enabled = v and true or false
				end,
			},
			critHealingScrollArea = {
				type   = "select",
				name   = "Crit Heal Scroll Area",
				desc   = "Scroll area to use for incoming critical heals when routing is enabled.",
				order  = 15.2,
				values = function() return ZSBT.GetScrollAreaNames() end,
				disabled = function()
					local c = ZSBT.db.profile.incoming.critHealing
					return not (c and c.enabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.incoming.critHealing
					return (c and type(c.scrollArea) == "string" and c.scrollArea ~= "") and c.scrollArea or "Incoming"
				end,
				set = function(_, v)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.scrollArea = v
				end,
			},
			critHealingColor = {
				type  = "color",
				name  = "Crit Heal Color",
				desc  = "Color for incoming critical heals when routed to the Crit Heal Scroll Area.",
				order = 15.3,
				get = function()
					local c = ZSBT.db.profile.incoming.critHealing
					local col = c and c.color
					if type(col) ~= "table" then return 0.2, 1, 0.4 end
					return col.r or 0.2, col.g or 1, col.b or 0.4
				end,
				set = function(_, r, g, b)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.color = { r = r, g = g, b = b }
				end,
			},
			critHealingSticky = {
				type  = "toggle",
				name  = "Sticky Crit Heals (slightly bigger + longer)",
				desc  = "Makes incoming critical heals feel more impactful by slightly increasing size and on-screen duration.",
				width = "full",
				order = 15.4,
				get   = function()
					local c = ZSBT.db.profile.incoming.critHealing
					return c == nil or c.sticky ~= false
				end,
				set   = function(_, v)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.sticky = v and true or false
				end,
			},
			critHealingStickyJiggle = {
				type  = "toggle",
				name  = "Sticky Jiggle (shake)",
				desc  = "When Sticky is enabled, also apply the shake/jiggle animation. Disable this if you want Sticky sizing/placement without shaking.",
				width = "full",
				order = 15.401,
				hidden = function()
					local c = ZSBT.db.profile.incoming.critHealing
					return not (c == nil or c.sticky ~= false)
				end,
				get   = function()
					local c = ZSBT.db.profile.incoming.critHealing
					return c == nil or c.stickyJiggle ~= false
				end,
				set   = function(_, v)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.stickyJiggle = v and true or false
				end,
			},
			critHealingSoundEnabled = {
				type = "toggle",
				name = "Play a Sound on Incoming Crit Heals",
				desc = "Plays a sound when you receive a critical heal.",
				width = "full",
				order = 15.5,
				get = function()
					local c = ZSBT.db.profile.incoming.critHealing
					return c and c.soundEnabled == true
				end,
				set = function(_, v)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.soundEnabled = v and true or false
				end,
			},
			critHealingSound = {
				type = "select",
				name = "Crit Heal Sound",
				desc = "Sound to play when an incoming crit heal triggers.",
				order = 15.6,
				values = function() return (ZSBT.BuildSoundDropdown and ZSBT.BuildSoundDropdown()) or { ["None"] = "None" } end,
				disabled = function()
					local c = ZSBT.db.profile.incoming.critHealing
					return not (c and c.soundEnabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.incoming.critHealing
					return (c and type(c.sound) == "string" and c.sound ~= "") and c.sound or "None"
				end,
				set = function(_, v)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.sound = v
				end,
			},
			critHealingSoundTest = {
				type = "execute",
				name = "Test Crit Heal Sound",
				order = 15.7,
				disabled = function()
					local c = ZSBT.db.profile.incoming.critHealing
					return not (c and c.soundEnabled == true)
				end,
				func = function()
					local c = ZSBT.db.profile.incoming.critHealing
					if c and ZSBT.PlayLSMSound then
						ZSBT.PlayLSMSound(c.sound)
					end
				end,
			},
			critHealingMinSoundAmount = {
				type = "range",
				name = "Minimum Crit Heal Amount (sound)",
				desc = "Only play the crit sound when the crit amount is at or above this value. In instances, the exact amount may be unavailable.",
				order = 15.8,
				min = 0,
				max = 999999,
				softMax = 250000,
				step = 100,
				disabled = function()
					local c = ZSBT.db.profile.incoming.critHealing
					return not (c and c.soundEnabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.incoming.critHealing
					return (c and tonumber(c.minSoundAmount)) or 0
				end,
				set = function(_, v)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.minSoundAmount = tonumber(v) or 0
				end,
			},
			critHealingInstanceSoundMode = {
				type = "select",
				name = "Instances: When amount is unavailable (heals)",
				desc = "In dungeons/raids, crit amounts can be protected/secret. Choose how crit sounds behave when the amount can't be safely compared.",
				order = 15.9,
				values = function()
					return {
						["Any Crit"] = "Any Crit",
						["Only when amount is known"] = "Only when amount is known",
					}
				end,
				disabled = function()
					local c = ZSBT.db.profile.incoming.critHealing
					return not (c and c.soundEnabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.incoming.critHealing
					return (c and type(c.instanceSoundMode) == "string" and c.instanceSoundMode ~= "") and c.instanceSoundMode or "Only when amount is known"
				end,
				set = function(_, v)
					ZSBT.db.profile.incoming.critHealing = ZSBT.db.profile.incoming.critHealing or {}
					ZSBT.db.profile.incoming.critHealing.instanceSoundMode = v
				end,
			},

            ----------------------------------------------------------------
            -- UI/UX Validation Harness (Capture + Replay)
            ----------------------------------------------------------------
            headerProbe = {
                type  = "header",
                name  = "Incoming Diagnostics (UI Test)",
                order = 30,
            },
            probeReport = {
                type  = "description",
                name  = reportLine,
                order = 31,
                width = "full",
                fontSize = "medium",
            },
            probeStart10 = {
                type  = "execute",
                name  = "Capture 10s",
                desc  = "Capture real incoming UNIT_COMBAT events for 10 seconds and emit them live.",
                order = 32,
                func  = function()
                    local p = ZSBT.Core and ZSBT.Core.IncomingProbe
                    if p and p.StartCapture then p:StartCapture(10) end
                end,
            },
            probeStart30 = {
                type  = "execute",
                name  = "Capture 30s",
                desc  = "Capture real incoming UNIT_COMBAT events for 30 seconds and emit them live.",
                order = 33,
                func  = function()
                    local p = ZSBT.Core and ZSBT.Core.IncomingProbe
                    if p and p.StartCapture then p:StartCapture(30) end
                end,
            },
            probeStop = {
                type  = "execute",
                name  = "Stop Capture",
                desc  = "Stop capture early.",
                order = 34,
                func  = function()
                    local p = ZSBT.Core and ZSBT.Core.IncomingProbe
                    if p and p.StopCapture then p:StopCapture(false) end
                end,
            },
            probeReplay1 = {
                type  = "execute",
                name  = "Replay (1x)",
                desc  = "Replay the captured sample through display routing.",
                order = 35,
                func  = function()
                    local p = ZSBT.Core and ZSBT.Core.IncomingProbe
                    if p and p.Replay then p:Replay(1.0) end
                end,
            },
            probeReplay2 = {
                type  = "execute",
                name  = "Replay (2x)",
                desc  = "Replay faster.",
                order = 36,
                func  = function()
                    local p = ZSBT.Core and ZSBT.Core.IncomingProbe
                    if p and p.Replay then p:Replay(2.0) end
                end,
            },
            probeStopReplay = {
                type  = "execute",
                name  = "Stop Replay",
                desc  = "Stop replay early.",
                order = 37,
                func  = function()
                    local p = ZSBT.Core and ZSBT.Core.IncomingProbe
                    if p and p.StopReplay then p:StopReplay(false) end
                end,
            },
            probePrint = {
                type  = "execute",
                name  = "Print Capability Report",
                desc  = "Print a one-line capability report to chat.",
                order = 38,
                func  = function()
                    local p = ZSBT.Core and ZSBT.Core.IncomingProbe
                    if p and p.PrintCapabilityReport then p:PrintCapabilityReport() end
                end,
            },
        },
    }
end

------------------------------------------------------------------------
-- TAB 5: OUTGOING
-- Outgoing damage and healing configuration.
------------------------------------------------------------------------
function ZSBT.BuildTab_Outgoing()
    local function reportLine()
        local p = ZSBT.Core and ZSBT.Core.OutgoingProbe
        if not p or not p.GetStatusLine then
            return "Outgoing probe not available."
        end
        local s = p:GetStatusLine() or {}
        local cap = string.format("buffer=%d/%d", tonumber(s.bufferCount) or 0,
                                  tonumber(s.bufferMax) or 0)
        if s.capturing then
            return "Outgoing probe: capturing… " .. cap
        end
        if s.replaying then
            return "Outgoing probe: replaying… " .. cap
        end
        return "Outgoing probe: idle. " .. cap
    end

    return {
        type  = "group",
		name  = "|cFFFFD100Outgoing|r",
        order = 5,
        args  = {
            ----------------------------------------------------------------
            -- Outgoing Damage
            ----------------------------------------------------------------
            headerDamage = {
                type  = "header",
                name  = "Outgoing Damage",
                order = 1,
            },
            damageEnabled = {
                type  = "toggle",
                name  = "Show Outgoing Damage",
                desc  = "Display damage dealt by your character.",
                width = "full",
                order = 2,
                get   = function() return ZSBT.db.profile.outgoing.damage.enabled end,
                set   = function(_, val) ZSBT.db.profile.outgoing.damage.enabled = val end,
            },
            showSpellNames = {
                type  = "toggle",
                name  = "Show Spell Names",
                desc  = "Append the spell name after damage numbers.",
                width = "full",
                order = 3,
                get   = function() return ZSBT.db.profile.outgoing.showSpellNames end,
                set   = function(_, val) ZSBT.db.profile.outgoing.showSpellNames = val end,
            },
            showSpellIcons = {
                type  = "toggle",
                name  = "Show Spell Icons (may be inaccurate)",
                desc  = "Display the spell icon next to outgoing damage/heal numbers. On modern WoW, spell attribution is not always reliable, so icons may be incorrect.",
                width = "full",
                order = 3.5,
                get   = function() return ZSBT.db.profile.outgoing.showSpellIcons end,
                set   = function(_, val) ZSBT.db.profile.outgoing.showSpellIcons = val end,
            },
            useSchoolColors = {
                type  = "toggle",
                name  = "Use School Colors (may be limited)",
                desc  = "Color damage by school (fire=orange, frost=blue, shadow=purple, etc.). Crits always show yellow. On modern WoW, some events may not provide reliable school information.",
                width = "full",
                order = 3.6,
                get   = function() return ZSBT.db.profile.outgoing.useSchoolColors end,
                set   = function(_, val) ZSBT.db.profile.outgoing.useSchoolColors = val end,
            },
            customDamageColor = {
                type     = "color",
                name     = "Custom Damage Color",
                desc     = "Fallback damage color when school colors are disabled.",
                order    = 3.7,
                disabled = function() return ZSBT.db.profile.outgoing.useSchoolColors end,
                get      = function()
                    local c = ZSBT.db.profile.outgoing.customDamageColor
                    return c.r, c.g, c.b
                end,
                set      = function(_, r, g, b)
                    local c = ZSBT.db.profile.outgoing.customDamageColor
                    c.r, c.g, c.b = r, g, b
                end,
            },
            customHealingColor = {
                type     = "color",
                name     = "Custom Healing Color",
                desc     = "Fallback healing color when school colors are disabled.",
                order    = 3.8,
                disabled = function() return ZSBT.db.profile.outgoing.useSchoolColors end,
                get      = function()
                    local c = ZSBT.db.profile.outgoing.customHealingColor
                    return c.r, c.g, c.b
                end,
                set      = function(_, r, g, b)
                    local c = ZSBT.db.profile.outgoing.customHealingColor
                    c.r, c.g, c.b = r, g, b
                end,
            },
            damageScrollArea = {
                type   = "select",
                name   = "Scroll Area",
                desc   = "Which scroll area displays outgoing damage.",
                order  = 4,
                values = function() return ZSBT.GetScrollAreaNames() end,
                get    = function() return ZSBT.db.profile.outgoing.damage.scrollArea end,
                set    = function(_, val) ZSBT.db.profile.outgoing.damage.scrollArea = val end,
            },
            showTargets = {
                type  = "toggle",
                name  = "Show Target Names",
                desc  = "Display target name alongside damage numbers (where available).",
                width = "full",
                order = 5,
                get   = function() return ZSBT.db.profile.outgoing.damage.showTargets end,
                set   = function(_, val) ZSBT.db.profile.outgoing.damage.showTargets = val end,
            },
            autoAttackMode = {
                type   = "select",
                name   = "Auto-Attack Display",
                desc   = "How to display auto-attack/auto-shot damage.",
                order  = 6,
                values = ZSBT.ValuesFromKeys(ZSBT.AUTOATTACK_MODES),
                get    = function() return ZSBT.db.profile.outgoing.damage.autoAttackMode end,
                set    = function(_, val) ZSBT.db.profile.outgoing.damage.autoAttackMode = val end,
            },
            thresholdTip = {
                type     = "description",
                name     = "Tip: You can type a value above the slider (up to 15000).",
                order    = 6.1,
                width    = "full",
                fontSize = "medium",
            },
            damageMinThreshold = {
                type    = "range",
                name    = "Minimum Damage Threshold",
                desc    = "Suppress outgoing damage below this value (0 = show all).",
                order   = 7,
                min     = 0,
                max     = 15000,
                softMax = 3000,
                step    = 50,
                get     = function() return ZSBT.db.profile.outgoing.damage.minThreshold end,
                set     = function(_, val) ZSBT.db.profile.outgoing.damage.minThreshold = val end,
            },
            damageShowMisses = {
                type  = "toggle",
                name  = "Show Misses / Avoids",
                desc  = "Display avoidance text like Miss, Dodge, Parry, Block, Immune, Resist.",
                width = "full",
                order = 7.1,
                get   = function()
                    local d = ZSBT.db.profile.outgoing.damage
                    return d == nil or d.showMisses ~= false
                end,
                set   = function(_, val)
                    ZSBT.db.profile.outgoing.damage.showMisses = val and true or false
                end,
            },

            ----------------------------------------------------------------
            -- Outgoing Crits (Routing + Sticky)
            ----------------------------------------------------------------
			headerCritsSplitDamage = {
				type  = "header",
				name  = "Outgoing Crit Damage",
				order = 8.41,
			},
			outgoingCritDamageFontEnabled = {
				type  = "toggle",
				name  = "Override Crit Font (Outgoing Crit Damage)",
				desc  = "If enabled, outgoing critical damage uses this crit font instead of the Global Crit Font.",
				order = 8.415,
				width = "full",
				get   = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return type(cf) == "table" and cf.enabled == true
				end,
				set   = function(_, v)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.critFont = ZSBT.db.profile.outgoing.critDamage.critFont or {}
					ZSBT.db.profile.outgoing.critDamage.critFont.enabled = v and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			outgoingCritDamageFontFace = {
				type   = "select",
				name   = "Crit Font Face",
				desc   = "Font used for outgoing critical damage.",
				order  = 8.416,
				values = function() return ZSBT.BuildFontDropdown() end,
				disabled = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get    = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return cf and cf.face or "__use_master__"
				end,
				set    = function(_, val)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.critFont = ZSBT.db.profile.outgoing.critDamage.critFont or {}
					if val == "__use_master__" then
						ZSBT.db.profile.outgoing.critDamage.critFont.face = nil
					else
						ZSBT.db.profile.outgoing.critDamage.critFont.face = val
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			outgoingCritDamageFontSize = {
				type  = "range",
				name  = "Crit Font Size",
				desc  = "Font size for outgoing critical damage text.",
				order = 8.417,
				min   = ZSBT.FONT_SIZE_MIN,
				max   = 48,
				step  = 1,
				disabled = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true) or (cf and cf.useScale == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get   = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return (cf and cf.size) or 28
				end,
				set   = function(_, val)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.critFont = ZSBT.db.profile.outgoing.critDamage.critFont or {}
					ZSBT.db.profile.outgoing.critDamage.critFont.size = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			outgoingCritDamageUseScale = {
				type  = "toggle",
				name  = "Use Crit Scale (instead of fixed size)",
				desc  = "When enabled, crit size is derived from your normal font size using Crit Scale.",
				order = 8.418,
				width = "full",
				disabled = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get   = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return cf and cf.useScale == true
				end,
				set   = function(_, v)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.critFont = ZSBT.db.profile.outgoing.critDamage.critFont or {}
					ZSBT.db.profile.outgoing.critDamage.critFont.useScale = v and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			outgoingCritDamageAnim = {
				type   = "select",
				name   = "Crit Animation",
				desc   = "Choose whether crits use the sticky Pow animation or follow the scroll area's animation.",
				order  = 8.419,
				values = { Pow = "Pow (Sticky)", Area = "Use Scroll Area Animation" },
				disabled = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get    = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return (cf and (cf.anim == "Area" or cf.anim == "Pow")) and cf.anim or "Pow"
				end,
				set    = function(_, val)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.critFont = ZSBT.db.profile.outgoing.critDamage.critFont or {}
					ZSBT.db.profile.outgoing.critDamage.critFont.anim = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			outgoingCritDamageFontOutline = {
				type   = "select",
				name   = "Crit Outline",
				desc   = "Outline style for outgoing critical damage text.",
				order  = 8.42,
				values = { None = "None", Thin = "Thin", Thick = "Thick", Monochrome = "Monochrome" },
				disabled = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get    = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return (cf and cf.outline) or "Thick"
				end,
				set    = function(_, val)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.critFont = ZSBT.db.profile.outgoing.critDamage.critFont or {}
					ZSBT.db.profile.outgoing.critDamage.critFont.outline = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			outgoingCritDamageFontScale = {
				type  = "range",
				name  = "Crit Scale",
				desc  = "Scale multiplier vs normal font size.",
				order = 8.421,
				min   = 1.0,
				max   = 3.0,
				step  = 0.1,
				disabled = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true) or not (cf and cf.useScale == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get   = function()
					local cf = ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.critFont
					return (cf and cf.scale) or 1.5
				end,
				set   = function(_, val)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.critFont = ZSBT.db.profile.outgoing.critDamage.critFont or {}
					ZSBT.db.profile.outgoing.critDamage.critFont.scale = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			critDamageEnabled = {
				type  = "toggle",
				name  = "Route Outgoing Crit Damage to a Different Scroll Area",
				desc  = "If enabled, outgoing critical damage uses the crit scroll area below.",
				width = "full",
				order = 8.422,
				get   = function() return ZSBT.db.profile.outgoing.critDamage and ZSBT.db.profile.outgoing.critDamage.enabled == true end,
				set   = function(_, v)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.enabled = v and true or false
				end,
			},
			critDamageScrollArea = {
				type   = "select",
				name   = "Crit Damage Scroll Area",
				desc   = "Scroll area to use for outgoing critical damage when routing is enabled.",
				order  = 8.43,
				values = function() return ZSBT.GetScrollAreaNames() end,
				disabled = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					return not (c and c.enabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					return (c and type(c.scrollArea) == "string" and c.scrollArea ~= "") and c.scrollArea or "Outgoing"
				end,
				set = function(_, v)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.scrollArea = v
				end,
			},
			critDamageColor = {
				type  = "color",
				name  = "Crit Damage Color",
				desc  = "Color for outgoing critical damage when routed to the Crit Damage Scroll Area.",
				order = 8.44,
				get = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					local col = c and c.color
					if type(col) ~= "table" then return 1, 1, 0 end
					return col.r or 1, col.g or 1, col.b or 0
				end,
				set = function(_, r, g, b)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.color = { r = r, g = g, b = b }
				end,
			},
			critDamageSticky = {
				type  = "toggle",
				name  = "Sticky Crit Damage (slightly bigger + longer)",
				desc  = "Makes outgoing critical damage feel more impactful by slightly increasing size and on-screen duration.",
				width = "full",
				order = 8.45,
				get   = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					return c == nil or c.sticky ~= false
				end,
				set   = function(_, v)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.sticky = v and true or false
				end,
			},
			critDamageStickyJiggle = {
				type  = "toggle",
				name  = "Sticky Jiggle (shake)",
				desc  = "When Sticky is enabled, also apply the shake/jiggle animation. Disable this if you want Sticky sizing/placement without shaking.",
				width = "full",
				order = 8.451,
				hidden = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					return not (c == nil or c.sticky ~= false)
				end,
				get   = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					return c == nil or c.stickyJiggle ~= false
				end,
				set   = function(_, v)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.stickyJiggle = v and true or false
				end,
			},
			critDamageSoundEnabled = {
				type = "toggle",
				name = "Play a Sound on Outgoing Crit Damage",
				desc = "Plays a sound when you land a critical hit.",
				width = "full",
				order = 8.46,
				get = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					return c and c.soundEnabled == true
				end,
				set = function(_, v)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.soundEnabled = v and true or false
				end,
			},
			critDamageSound = {
				type = "select",
				name = "Crit Damage Sound",
				desc = "Sound to play when an outgoing crit damage triggers.",
				order = 8.47,
				values = function() return (ZSBT.BuildSoundDropdown and ZSBT.BuildSoundDropdown()) or { ["None"] = "None" } end,
				disabled = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					return not (c and c.soundEnabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					return (c and type(c.sound) == "string" and c.sound ~= "") and c.sound or "None"
				end,
				set = function(_, v)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.sound = v
				end,
			},
			critDamageSoundTest = {
				type = "execute",
				name = "Test Crit Damage Sound",
				order = 8.48,
				disabled = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					return not (c and c.soundEnabled == true)
				end,
				func = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					if c and ZSBT.PlayLSMSound then
						ZSBT.PlayLSMSound(c.sound)
					end
				end,
			},
			critDamageMinSoundAmount = {
				type = "range",
				name = "Minimum Crit Damage Amount (sound)",
				desc = "Only play the crit sound when the crit amount is at or above this value. In instances, the exact amount may be unavailable.",
				order = 8.49,
				min = 0,
				max = 999999,
				softMax = 250000,
				step = 100,
				disabled = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					return not (c and c.soundEnabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					return (c and tonumber(c.minSoundAmount)) or 0
				end,
				set = function(_, v)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.minSoundAmount = tonumber(v) or 0
				end,
			},
			critDamageInstanceSoundMode = {
				type = "select",
				name = "Instances: When amount is unavailable (damage)",
				desc = "In dungeons/raids, crit amounts can be protected/secret. Choose how crit sounds behave when the amount can't be safely compared.",
				order = 8.5,
				values = function()
					return {
						["Any Crit"] = "Any Crit",
						["Only when amount is known"] = "Only when amount is known",
					}
				end,
				disabled = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					return not (c and c.soundEnabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.outgoing.critDamage
					return (c and type(c.instanceSoundMode) == "string" and c.instanceSoundMode ~= "") and c.instanceSoundMode or "Only when amount is known"
				end,
				set = function(_, v)
					ZSBT.db.profile.outgoing.critDamage = ZSBT.db.profile.outgoing.critDamage or {}
					ZSBT.db.profile.outgoing.critDamage.instanceSoundMode = v
				end,
			},

            ----------------------------------------------------------------
            -- Outgoing Crit Font Override
            ----------------------------------------------------------------

            ----------------------------------------------------------------
            -- Outgoing Healing
            ----------------------------------------------------------------
            headerHealing = {
                type  = "header",
                name  = "Outgoing Healing",
                order = 10,
            },
            healingEnabled = {
                type  = "toggle",
                name  = "Show Outgoing Healing",
                desc  = "Display healing done by your character.",
                width = "full",
                order = 11,
                get   = function() return ZSBT.db.profile.outgoing.healing.enabled end,
                set   = function(_, val) ZSBT.db.profile.outgoing.healing.enabled = val end,
            },
            healingScrollArea = {
                type   = "select",
                name   = "Scroll Area",
                desc   = "Which scroll area displays outgoing healing.",
                order  = 12,
                values = function() return ZSBT.GetScrollAreaNames() end,
                get    = function() return ZSBT.db.profile.outgoing.healing.scrollArea end,
                set    = function(_, val) ZSBT.db.profile.outgoing.healing.scrollArea = val end,
            },
            showOverheal = {
                type  = "toggle",
                name  = "Show Overhealing (may be limited)",
                desc  = "Display overhealing amounts. On modern WoW, overheal data may be unavailable for some events.",
                width = "full",
                order = 13,
                get   = function() return ZSBT.db.profile.outgoing.healing.showOverheal end,
                set   = function(_, val) ZSBT.db.profile.outgoing.healing.showOverheal = val end,
            },
            healingMinThreshold = {
                type    = "range",
                name    = "Minimum Healing Threshold",
                desc    = "Suppress outgoing heals below this value (0 = show all).",
                order   = 14,
                min     = 0,
                max     = 15000,
                softMax = 3000,
                step    = 50,
                get     = function() return ZSBT.db.profile.outgoing.healing.minThreshold end,
                set     = function(_, val) ZSBT.db.profile.outgoing.healing.minThreshold = val end,
            },
			headerCritsSplitHealing = {
				type  = "header",
				name  = "Outgoing Crit Heals",
				order = 15,
			},
			outgoingCritHealingFontEnabled = {
				type  = "toggle",
				name  = "Override Crit Font (Outgoing Crit Heals)",
				desc  = "If enabled, outgoing critical heals use this crit font instead of the Global Crit Font.",
				order = 15.01,
				width = "full",
				get   = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return type(cf) == "table" and cf.enabled == true
				end,
				set   = function(_, v)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.critFont = ZSBT.db.profile.outgoing.critHealing.critFont or {}
					ZSBT.db.profile.outgoing.critHealing.critFont.enabled = v and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			outgoingCritHealingFontFace = {
				type   = "select",
				name   = "Crit Font Face",
				desc   = "Font used for outgoing critical heals.",
				order  = 15.02,
				values = function() return ZSBT.BuildFontDropdown() end,
				disabled = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get    = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return cf and cf.face or "__use_master__"
				end,
				set    = function(_, val)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.critFont = ZSBT.db.profile.outgoing.critHealing.critFont or {}
					if val == "__use_master__" then
						ZSBT.db.profile.outgoing.critHealing.critFont.face = nil
					else
						ZSBT.db.profile.outgoing.critHealing.critFont.face = val
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			outgoingCritHealingFontSize = {
				type  = "range",
				name  = "Crit Font Size",
				desc  = "Font size for outgoing critical heal text.",
				order = 15.03,
				min   = ZSBT.FONT_SIZE_MIN,
				max   = 48,
				step  = 1,
				disabled = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true) or (cf and cf.useScale == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get   = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return (cf and cf.size) or 28
				end,
				set   = function(_, val)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.critFont = ZSBT.db.profile.outgoing.critHealing.critFont or {}
					ZSBT.db.profile.outgoing.critHealing.critFont.size = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			outgoingCritHealingUseScale = {
				type  = "toggle",
				name  = "Use Crit Scale (instead of fixed size)",
				desc  = "When enabled, crit size is derived from your normal font size using Crit Scale.",
				order = 15.035,
				width = "full",
				disabled = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get   = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return cf and cf.useScale == true
				end,
				set   = function(_, v)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.critFont = ZSBT.db.profile.outgoing.critHealing.critFont or {}
					ZSBT.db.profile.outgoing.critHealing.critFont.useScale = v and true or false
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			outgoingCritHealingAnim = {
				type   = "select",
				name   = "Crit Animation",
				desc   = "Choose whether crits use the sticky Pow animation or follow the scroll area's animation.",
				order  = 15.04,
				values = { Pow = "Pow (Sticky)", Area = "Use Scroll Area Animation" },
				disabled = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get    = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return (cf and (cf.anim == "Area" or cf.anim == "Pow")) and cf.anim or "Pow"
				end,
				set    = function(_, val)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.critFont = ZSBT.db.profile.outgoing.critHealing.critFont or {}
					ZSBT.db.profile.outgoing.critHealing.critFont.anim = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			outgoingCritHealingFontOutline = {
				type   = "select",
				name   = "Crit Outline",
				desc   = "Outline style for outgoing critical heal text.",
				order  = 15.05,
				values = { None = "None", Thin = "Thin", Thick = "Thick", Monochrome = "Monochrome" },
				disabled = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get    = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return (cf and cf.outline) or "Thick"
				end,
				set    = function(_, val)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.critFont = ZSBT.db.profile.outgoing.critHealing.critFont or {}
					ZSBT.db.profile.outgoing.critHealing.critFont.outline = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			outgoingCritHealingFontScale = {
				type  = "range",
				name  = "Crit Scale",
				desc  = "Scale multiplier vs normal font size.",
				order = 15.06,
				min   = 1.0,
				max   = 3.0,
				step  = 0.1,
				disabled = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true) or not (cf and cf.useScale == true)
				end,
				hidden = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return not (type(cf) == "table" and cf.enabled == true)
				end,
				get   = function()
					local cf = ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.critFont
					return (cf and cf.scale) or 1.5
				end,
				set   = function(_, val)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.critFont = ZSBT.db.profile.outgoing.critHealing.critFont or {}
					ZSBT.db.profile.outgoing.critHealing.critFont.scale = val
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end,
			},
			critHealingEnabled = {
				type  = "toggle",
				name  = "Route Outgoing Crit Heals to a Different Scroll Area",
				desc  = "If enabled, outgoing critical heals use the crit scroll area below.",
				width = "full",
				order = 15.1,
				get   = function() return ZSBT.db.profile.outgoing.critHealing and ZSBT.db.profile.outgoing.critHealing.enabled == true end,
				set   = function(_, v)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.enabled = v and true or false
				end,
			},
			critHealingScrollArea = {
				type   = "select",
				name   = "Crit Heal Scroll Area",
				desc   = "Scroll area to use for outgoing critical heals when routing is enabled.",
				order  = 15.2,
				values = function() return ZSBT.GetScrollAreaNames() end,
				disabled = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					return not (c and c.enabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					return (c and type(c.scrollArea) == "string" and c.scrollArea ~= "") and c.scrollArea or "Outgoing"
				end,
				set = function(_, v)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.scrollArea = v
				end,
			},
			critHealingColor = {
				type  = "color",
				name  = "Crit Heal Color",
				desc  = "Color for outgoing critical heals when routed to the Crit Heal Scroll Area.",
				order = 15.3,
				get = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					local col = c and c.color
					if type(col) ~= "table" then return 0.2, 1, 0.4 end
					return col.r or 0.2, col.g or 1, col.b or 0.4
				end,
				set = function(_, r, g, b)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.color = { r = r, g = g, b = b }
				end,
			},
			critHealingSticky = {
				type  = "toggle",
				name  = "Sticky Crit Heals (slightly bigger + longer)",
				desc  = "Makes outgoing critical heals feel more impactful by slightly increasing size and on-screen duration.",
				width = "full",
				order = 15.4,
				get   = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					return c == nil or c.sticky ~= false
				end,
				set   = function(_, v)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.sticky = v and true or false
				end,
			},
			critHealingStickyJiggle = {
				type  = "toggle",
				name  = "Sticky Jiggle (shake)",
				desc  = "When Sticky is enabled, also apply the shake/jiggle animation. Disable this if you want Sticky sizing/placement without shaking.",
				width = "full",
				order = 15.401,
				hidden = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					return not (c == nil or c.sticky ~= false)
				end,
				get   = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					return c == nil or c.stickyJiggle ~= false
				end,
				set   = function(_, v)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.stickyJiggle = v and true or false
				end,
			},
			critHealingSoundEnabled = {
				type = "toggle",
				name = "Play a Sound on Outgoing Crit Heals",
				desc = "Plays a sound when you land a critical heal.",
				width = "full",
				order = 15.5,
				get = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					return c and c.soundEnabled == true
				end,
				set = function(_, v)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.soundEnabled = v and true or false
				end,
			},
			critHealingSound = {
				type = "select",
				name = "Crit Heal Sound",
				desc = "Sound to play when an outgoing crit heal triggers.",
				order = 15.6,
				values = function() return (ZSBT.BuildSoundDropdown and ZSBT.BuildSoundDropdown()) or { ["None"] = "None" } end,
				disabled = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					return not (c and c.soundEnabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					return (c and type(c.sound) == "string" and c.sound ~= "") and c.sound or "None"
				end,
				set = function(_, v)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.sound = v
				end,
			},
			critHealingSoundTest = {
				type = "execute",
				name = "Test Crit Heal Sound",
				order = 15.7,
				disabled = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					return not (c and c.soundEnabled == true)
				end,
				func = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					if c and ZSBT.PlayLSMSound then
						ZSBT.PlayLSMSound(c.sound)
					end
				end,
			},
			critHealingMinSoundAmount = {
				type = "range",
				name = "Minimum Crit Heal Amount (sound)",
				desc = "Only play the crit sound when the crit amount is at or above this value. In instances, the exact amount may be unavailable.",
				order = 15.8,
				min = 0,
				max = 999999,
				softMax = 250000,
				step = 100,
				disabled = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					return not (c and c.soundEnabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					return (c and tonumber(c.minSoundAmount)) or 0
				end,
				set = function(_, v)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.minSoundAmount = tonumber(v) or 0
				end,
			},
			critHealingInstanceSoundMode = {
				type = "select",
				name = "Instances: When amount is unavailable (heals)",
				desc = "In dungeons/raids, crit amounts can be protected/secret. Choose how crit sounds behave when the amount can't be safely compared.",
				order = 15.9,
				values = function()
					return {
						["Any Crit"] = "Any Crit",
						["Only when amount is known"] = "Only when amount is known",
					}
				end,
				disabled = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					return not (c and c.soundEnabled == true)
				end,
				get = function()
					local c = ZSBT.db.profile.outgoing.critHealing
					return (c and type(c.instanceSoundMode) == "string" and c.instanceSoundMode ~= "") and c.instanceSoundMode or "Only when amount is known"
				end,
				set = function(_, v)
					ZSBT.db.profile.outgoing.critHealing = ZSBT.db.profile.outgoing.critHealing or {}
					ZSBT.db.profile.outgoing.critHealing.instanceSoundMode = v
				end,
			},

            ----------------------------------------------------------------
            -- UI/UX Validation Harness (Capture + Replay)
            ----------------------------------------------------------------
            headerProbe = {
                type  = "header",
                name  = "Outgoing Diagnostics (UI Test)",
                order = 20,
            },
            probeReport = {
                type  = "description",
                name  = reportLine,
                order = 21,
                width = "full",
                fontSize = "medium",
            },
            probeStart45 = {
                type  = "execute",
                name  = "Capture 45s",
                desc  = "Capture real outgoing CLEU events for 45 seconds and emit them live.",
                order = 22,
                func  = function()
                    local p = ZSBT.Core and ZSBT.Core.OutgoingProbe
                    if p and p.StartCapture then p:StartCapture(45) end
                end,
            },
            probeStart90 = {
                type  = "execute",
                name  = "Capture 90s",
                desc  = "Longer capture to reliably observe at least one natural auto-attack crit.",
                order = 23,
                func  = function()
                    local p = ZSBT.Core and ZSBT.Core.OutgoingProbe
                    if p and p.StartCapture then p:StartCapture(90) end
                end,
            },
            probeStop = {
                type  = "execute",
                name  = "Stop Capture",
                desc  = "Stop capture early.",
                order = 24,
                func  = function()
                    local p = ZSBT.Core and ZSBT.Core.OutgoingProbe
                    if p and p.StopCapture then p:StopCapture(false) end
                end,
            },
            probeReplay1 = {
                type  = "execute",
                name  = "Replay (1x)",
                desc  = "Replay the captured sample through display routing.",
                order = 25,
                func  = function()
                    local p = ZSBT.Core and ZSBT.Core.OutgoingProbe
                    if p and p.Replay then p:Replay(1.0) end
                end,
            },
            probeReplay2 = {
                type  = "execute",
                name  = "Replay (2x)",
                desc  = "Replay faster.",
                order = 26,
                func  = function()
                    local p = ZSBT.Core and ZSBT.Core.OutgoingProbe
                    if p and p.Replay then p:Replay(2.0) end
                end,
            },
            probeStopReplay = {
                type  = "execute",
                name  = "Stop Replay",
                desc  = "Stop replay early.",
                order = 27,
                func  = function()
                    local p = ZSBT.Core and ZSBT.Core.OutgoingProbe
                    if p and p.StopReplay then p:StopReplay(false) end
                end,
            },
        },
    }
end

------------------------------------------------------------------------
-- TAB 6: PETS
-- Pet damage display configuration.
------------------------------------------------------------------------
function ZSBT.BuildTab_Pets()
    return {
        type  = "group",
		name  = "Pets",
        order = 6,
        args  = {
            headerPets = {
                type  = "header",
                name  = "Outgoing Pet Damage",
                order = 1,
            },
            enabled = {
                type  = "toggle",
                name  = "Show Outgoing Pet Damage",
                desc  = "Display damage dealt by your pets and guardians.",
                width = "full",
                order = 2,
                get   = function() return ZSBT.db.profile.pets.enabled end,
                set   = function(_, val) ZSBT.db.profile.pets.enabled = val end,
            },
            scrollArea = {
                type   = "select",
                name   = "Scroll Area",
                desc   = "Which scroll area displays pet damage.",
                order  = 3,
                values = function() return ZSBT.GetScrollAreaNames() end,
                get    = function() return ZSBT.db.profile.pets.scrollArea end,
                set    = function(_, val) ZSBT.db.profile.pets.scrollArea = val end,
            },
            aggregation = {
                type   = "select",
                name   = "Aggregation Style",
                desc   = "How pet damage is labeled.",
                order  = 4,
                values = ZSBT.ValuesFromKeys(ZSBT.PET_AGGREGATION),
                get    = function() return ZSBT.db.profile.pets.aggregation end,
                set    = function(_, val) ZSBT.db.profile.pets.aggregation = val end,
            },
            minThreshold = {
                type    = "range",
                name    = "Minimum Outgoing Pet Damage Threshold",
                desc    = "Suppress pet damage below this value (0 = show all).",
                order   = 5,
                min     = 0,
                max     = 10000,
                softMax = 5000,
                step    = 50,
                get     = function() return ZSBT.db.profile.pets.minThreshold end,
                set     = function(_, val) ZSBT.db.profile.pets.minThreshold = val end,
            },
			outgoingDamageColor = {
				type  = "color",
				name  = "Outgoing Damage Color",
				desc  = "Color for outgoing pet damage (non-crits).",
				order = 5.2,
				disabled = function() return ZSBT.db.profile.pets.enabled ~= true end,
				get = function()
					local col = ZSBT.db.profile.pets.outgoingDamageColor
					if type(col) ~= "table" then return 1, 1, 1 end
					return col.r or 1, col.g or 1, col.b or 1
				end,
				set = function(_, r, g, b)
					ZSBT.db.profile.pets.outgoingDamageColor = { r = r, g = g, b = b }
				end,
			},
			outgoingCritColor = {
				type  = "color",
				name  = "Outgoing Crit Color",
				desc  = "Color for outgoing pet damage crits.",
				order = 5.3,
				disabled = function() return ZSBT.db.profile.pets.enabled ~= true end,
				get = function()
					local col = ZSBT.db.profile.pets.outgoingCritColor
					if type(col) ~= "table" then return 1, 1, 0 end
					return col.r or 1, col.g or 1, col.b or 0
				end,
				set = function(_, r, g, b)
					ZSBT.db.profile.pets.outgoingCritColor = { r = r, g = g, b = b }
				end,
			},
			mergeWindowSec = {
				type    = "range",
				name    = "Merge Pet Hits Window (sec)",
				desc    = "Merge multiple pet hits that occur within this time window into a single line (0 = off).",
				order   = 6,
				min     = 0,
				max     = 1.0,
				softMax = 0.5,
				step    = 0.05,
				get     = function() return ZSBT.db.profile.pets.mergeWindowSec or 0 end,
				set     = function(_, val) ZSBT.db.profile.pets.mergeWindowSec = val end,
			},
			showCount = {
				type  = "toggle",
				name  = "Show Merge Count (xN)",
				desc  = "When merging pet hits, show how many hits were combined (xN).",
				order = 7,
				width = "full",
				get   = function() return ZSBT.db.profile.pets.showCount ~= false end,
				set   = function(_, val) ZSBT.db.profile.pets.showCount = val and true or false end,
			},

			headerPetHealing = {
				type  = "header",
				name  = "Incoming Pet Healing",
				order = 8,
			},
			showHealing = {
				type  = "toggle",
				name  = "Show Incoming Pet Healing",
				desc  = "Display healing done to your pet (e.g. Mend Pet ticks). When disabled, pet healing will be treated as normal Outgoing Healing.",
				width = "full",
				order = 9,
				get   = function() return ZSBT.db.profile.pets.showHealing == true end,
				set   = function(_, val) ZSBT.db.profile.pets.showHealing = val and true or false end,
			},
			healScrollArea = {
				type   = "select",
				name   = "Pet Healing Scroll Area",
				desc   = "Which scroll area displays pet healing when enabled.",
				order  = 10,
				values = function() return ZSBT.GetScrollAreaNames() end,
				get    = function() return ZSBT.db.profile.pets.healScrollArea end,
				set    = function(_, val) ZSBT.db.profile.pets.healScrollArea = val end,
				disabled = function() return ZSBT.db.profile.pets.showHealing ~= true end,
			},
			healMinThreshold = {
				type    = "range",
				name    = "Minimum Incoming Pet Healing Threshold",
				desc    = "Suppress pet healing below this value (0 = show all).",
				order   = 11,
				min     = 0,
				max     = 10000,
				softMax = 5000,
				step    = 50,
				get     = function() return ZSBT.db.profile.pets.healMinThreshold or 0 end,
				set     = function(_, val) ZSBT.db.profile.pets.healMinThreshold = val end,
				disabled = function() return ZSBT.db.profile.pets.showHealing ~= true end,
			},
			incomingHealColor = {
				type  = "color",
				name  = "Incoming Heal Color",
				desc  = "Color for incoming heals to your pet (non-crits).",
				order = 11.2,
				disabled = function() return ZSBT.db.profile.pets.showHealing ~= true end,
				get = function()
					local col = ZSBT.db.profile.pets.incomingHealColor
					if type(col) ~= "table" then return 0.60, 0.80, 0.60 end
					return col.r or 0.60, col.g or 0.80, col.b or 0.60
				end,
				set = function(_, r, g, b)
					ZSBT.db.profile.pets.incomingHealColor = { r = r, g = g, b = b }
				end,
			},
			incomingHealCritColor = {
				type  = "color",
				name  = "Incoming Heal Crit Color",
				desc  = "Color for incoming heal crits to your pet.",
				order = 11.3,
				disabled = function() return ZSBT.db.profile.pets.showHealing ~= true end,
				get = function()
					local col = ZSBT.db.profile.pets.incomingHealCritColor
					if type(col) ~= "table" then return 0.80, 1.00, 0.00 end
					return col.r or 0.80, col.g or 1.00, col.b or 0.00
				end,
				set = function(_, r, g, b)
					ZSBT.db.profile.pets.incomingHealCritColor = { r = r, g = g, b = b }
				end,
			},

			headerPetIncomingDamage = {
				type  = "header",
				name  = "Incoming Pet Damage",
				order = 12,
			},
			showIncomingDamage = {
				type  = "toggle",
				name  = "Show Incoming Pet Damage",
				desc  = "Display damage taken by your pet.",
				width = "full",
				order = 13,
				get   = function() return ZSBT.db.profile.pets.showIncomingDamage == true end,
				set   = function(_, val) ZSBT.db.profile.pets.showIncomingDamage = val and true or false end,
			},
			incomingDamageScrollArea = {
				type   = "select",
				name   = "Incoming Pet Damage Scroll Area",
				desc   = "Which scroll area displays incoming pet damage when enabled.",
				order  = 14,
				values = function() return ZSBT.GetScrollAreaNames() end,
				get    = function() return ZSBT.db.profile.pets.incomingDamageScrollArea end,
				set    = function(_, val) ZSBT.db.profile.pets.incomingDamageScrollArea = val end,
				disabled = function() return ZSBT.db.profile.pets.showIncomingDamage ~= true end,
			},
			incomingDamageMinThreshold = {
				type    = "range",
				name    = "Minimum Incoming Pet Damage Threshold",
				desc    = "Suppress incoming pet damage below this value (0 = show all).",
				order   = 15,
				min     = 0,
				max     = 10000,
				softMax = 5000,
				step    = 50,
				get     = function() return ZSBT.db.profile.pets.incomingDamageMinThreshold or 0 end,
				set     = function(_, val) ZSBT.db.profile.pets.incomingDamageMinThreshold = val end,
				disabled = function() return ZSBT.db.profile.pets.showIncomingDamage ~= true end,
			},
			incomingDamageColor = {
				type  = "color",
				name  = "Incoming Damage Color",
				desc  = "Color for incoming damage to your pet (non-crits).",
				order = 15.2,
				disabled = function() return ZSBT.db.profile.pets.showIncomingDamage ~= true end,
				get = function()
					local col = ZSBT.db.profile.pets.incomingDamageColor
					if type(col) ~= "table" then return 1.00, 0.30, 0.30 end
					return col.r or 1.00, col.g or 0.30, col.b or 0.30
				end,
				set = function(_, r, g, b)
					ZSBT.db.profile.pets.incomingDamageColor = { r = r, g = g, b = b }
				end,
			},
			incomingDamageCritColor = {
				type  = "color",
				name  = "Incoming Damage Crit Color",
				desc  = "Color for incoming damage crits to your pet.",
				order = 15.3,
				disabled = function() return ZSBT.db.profile.pets.showIncomingDamage ~= true end,
				get = function()
					local col = ZSBT.db.profile.pets.incomingDamageCritColor
					if type(col) ~= "table" then return 1.00, 0.80, 0.20 end
					return col.r or 1.00, col.g or 0.80, col.b or 0.20
				end,
				set = function(_, r, g, b)
					ZSBT.db.profile.pets.incomingDamageCritColor = { r = r, g = g, b = b }
				end,
			},

            ----------------------------------------------------------------
            -- Instance Warning
            ----------------------------------------------------------------
            spacer1 = { type = "description", name = "\n", order = 20 },
            instanceWarning = {
                type     = "description",
                name     = "|cFFFFAA00Note:|r In instanced content (dungeons, raids), pet names may be " ..
                           "unavailable due to WoW API restrictions. Pet damage will display as " ..
                           "\"Pet\" in those scenarios regardless of aggregation setting.",
                order    = 21,
                fontSize = "medium",
            },
        },
    }
end

------------------------------------------------------------------------
-- TAB 7: SPAM CONTROL
-- Merging, throttling, and special suppression settings.
------------------------------------------------------------------------
function ZSBT.BuildTab_SpamControl()
    return {
        type  = "group",
		name  = "|cFFFFD100Spam Control|r",
        order = 7,
        args  = {
            ----------------------------------------------------------------
            -- Merging
            ----------------------------------------------------------------
            headerMerge = {
                type  = "header",
                name  = "Spell Merging",
                order = 1,
            },
            mergeDesc = {
                type     = "description",
                name     = "Combine rapid repeated hits into a single display when they share the same SpellID. " ..
                           "Note: In WoW 12.x, some abilities emit multiple SpellIDs (sub-spells/procs), so Spell Rules (per-spell throttles/aggregation) may be more accurate.",
                order    = 2,
                fontSize = "medium",
            },
            mergeEnabled = {
                type  = "toggle",
                name  = "Enable Spell Merging",
                desc  = "Merge rapid repeated hits when events share the same SpellID.",
                width = "full",
                order = 3,
                get   = function() return ZSBT.db.profile.spamControl.merging.enabled end,
                set   = function(_, val) ZSBT.db.profile.spamControl.merging.enabled = val end,
            },
            mergeWindow = {
                type     = "range",
                name     = "Merge Window (seconds)",
                desc     = "Time window to group hits from the same spell.",
                order    = 4,
                min      = ZSBT.MERGE_WINDOW_MIN,
                max      = ZSBT.MERGE_WINDOW_MAX,
                step     = 0.1,
                disabled = function() return not ZSBT.db.profile.spamControl.merging.enabled end,
                get      = function() return ZSBT.db.profile.spamControl.merging.window end,
                set      = function(_, val) ZSBT.db.profile.spamControl.merging.window = val end,
            },
            mergeShowCount = {
                type     = "toggle",
                name     = "Show Merge Count",
                desc     = "Display hit count (e.g., \"x3\") alongside merged damage.",
                width    = "full",
                order    = 5,
                disabled = function() return not ZSBT.db.profile.spamControl.merging.enabled end,
                get      = function() return ZSBT.db.profile.spamControl.merging.showCount end,
                set      = function(_, val) ZSBT.db.profile.spamControl.merging.showCount = val end,
            },

            ----------------------------------------------------------------
            -- Throttling
            ----------------------------------------------------------------
            headerThrottle = {
                type  = "header",
                name  = "Throttling",
                order = 10,
            },
            thresholdTip = {
                type     = "description",
                name     = "Tip: You can type a value above the slider (up to 15000).",
                order    = 10.5,
                width    = "full",
                fontSize = "medium",
            },
            minDamage = {
                type    = "range",
                name    = "Global Minimum Damage",
                desc    = "Suppress all damage events below this value (0 = show all).",
                order   = 11,
                min     = 0,
                max     = 15000,
                softMax = 2000,
                step    = 25,
                get     = function() return ZSBT.db.profile.spamControl.throttling.minDamage end,
                set     = function(_, val) ZSBT.db.profile.spamControl.throttling.minDamage = val end,
            },
            minHealing = {
                type    = "range",
                name    = "Global Minimum Healing",
                desc    = "Suppress all healing events below this value (0 = show all).",
                order   = 12,
                min     = 0,
                max     = 15000,
                softMax = 2000,
                step    = 25,
                get     = function() return ZSBT.db.profile.spamControl.throttling.minHealing end,
                set     = function(_, val) ZSBT.db.profile.spamControl.throttling.minHealing = val end,
            },
            hideAutoBelow = {
                type    = "range",
                name    = "Hide Auto-Attacks Below",
                desc    = "Suppress auto-attack damage below this value (0 = show all).",
                order   = 13,
                min     = 0,
                max     = 5000,
                softMax = 1000,
                step    = 25,
                get     = function() return ZSBT.db.profile.spamControl.throttling.hideAutoBelow end,
                set     = function(_, val) ZSBT.db.profile.spamControl.throttling.hideAutoBelow = val end,
            },

            headerPulse = {
                type  = "header",
                name  = "Pulse Engine",
                order = 14,
            },
            pulseMaxBucket = {
                type    = "range",
                name    = "Pulse Queue Size",
                desc    = "Maximum queued parser events before the oldest are dropped.",
                order   = 15,
                min     = 20,
                max     = 600,
                softMax = 240,
                step    = 10,
                get     = function()
                    local pe = ZSBT.db.profile.spamControl.pulseEngine
                    return (pe and pe.maxBucketSize) or 120
                end,
                set     = function(_, val)
                    if not ZSBT.db.profile.spamControl.pulseEngine then
                        ZSBT.db.profile.spamControl.pulseEngine = {}
                    end
                    ZSBT.db.profile.spamControl.pulseEngine.maxBucketSize = val
                    local engine = ZSBT.Parser and ZSBT.Parser.PulseEngine
                    if engine and engine.ApplyConfig then engine:ApplyConfig() end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            pulseMaxWork = {
                type    = "range",
                name    = "Max Work Per Pulse",
                desc    = "Maximum parser events processed per pulse tick (higher = more CPU, fewer drops).",
                order   = 16,
                min     = 10,
                max     = 200,
                softMax = 100,
                step    = 5,
                get     = function()
                    local pe = ZSBT.db.profile.spamControl.pulseEngine
                    return (pe and pe.maxWorkPerPulse) or 80
                end,
                set     = function(_, val)
                    if not ZSBT.db.profile.spamControl.pulseEngine then
                        ZSBT.db.profile.spamControl.pulseEngine = {}
                    end
                    ZSBT.db.profile.spamControl.pulseEngine.maxWorkPerPulse = val
                    local engine = ZSBT.Parser and ZSBT.Parser.PulseEngine
                    if engine and engine.ApplyConfig then engine:ApplyConfig() end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },

            ----------------------------------------------------------------
            -- Special Cases
            ----------------------------------------------------------------
            headerSpecial = {
                type  = "header",
                name  = "Special Cases",
                order = 20,
            },
            suppressDummy = {
                type  = "toggle",
                name  = "Suppress Training Dummy Internal Damage",
                desc  = "Filter out the large internal damage numbers that training dummies " ..
                        "generate (these are not real damage).",
                width = "full",
                order = 21,
                get   = function() return ZSBT.db.profile.spamControl.suppressDummyDamage end,
                set   = function(_, val) ZSBT.db.profile.spamControl.suppressDummyDamage = val end,
            },

			----------------------------------------------------------------
			-- Spell Rules Manager
			----------------------------------------------------------------
			headerRules = {
				type  = "header",
				name  = "Spell Rules (Per-Spell)",
				order = 30,
			},
			routingHeader = {
				type  = "header",
				name  = "Routing Defaults",
				order = 29.5,
			},
			spellRulesDefaultArea = {
				type   = "select",
				name   = "Spell Rules Default Scroll Area",
				desc   = "Default scroll area for Spell Rules when a rule does not specify its own scroll area.",
				order  = 29.6,
				values = function() return ZSBT.GetScrollAreaNames() end,
				get    = function()
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					local r = sc and sc.routing
					return (r and r.spellRulesDefaultArea) or "Outgoing"
				end,
				set    = function(_, val)
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					if not sc then return end
					sc.routing = sc.routing or {}
					sc.routing.spellRulesDefaultArea = val
				end,
			},
			auraRulesDefaultArea = {
				type   = "select",
				name   = "Buff Rules Default Scroll Area",
				desc   = "Default scroll area for Buff Rules notifications when a rule does not specify its own scroll area.",
				order  = 29.7,
				values = function() return ZSBT.GetScrollAreaNames() end,
				get    = function()
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					local r = sc and sc.routing
					return (r and r.auraRulesDefaultArea) or "Notifications"
				end,
				set    = function(_, val)
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					if not sc then return end
					sc.routing = sc.routing or {}
					sc.routing.auraRulesDefaultArea = val
				end,
			},
			auraShowUnconfiguredGains = {
				type  = "toggle",
				name  = "Show Buff Gains Without Rules",
				desc  = "If disabled, helpful buff gain notifications only show when you have a Buff Rule for that spell (whitelist mode).",
				width = "full",
				order = 29.8,
				get   = function()
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					local g = sc and sc.auraGlobal
					if type(g) ~= "table" then return true end
					return g.showUnconfiguredGains ~= false
				end,
				set   = function(_, v)
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					if not sc then return end
					sc.auraGlobal = sc.auraGlobal or {}
					sc.auraGlobal.showUnconfiguredGains = v and true or false
				end,
			},
			auraShowUnconfiguredFades = {
				type  = "toggle",
				name  = "Show Buff Fades Without Rules",
				desc  = "If disabled, helpful buff fade notifications only show when you have a Buff Rule for that spell (whitelist mode).",
				width = "full",
				order = 29.9,
				get   = function()
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					local g = sc and sc.auraGlobal
					if type(g) ~= "table" then return true end
					return g.showUnconfiguredFades ~= false
				end,
				set   = function(_, v)
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					if not sc then return end
					sc.auraGlobal = sc.auraGlobal or {}
					sc.auraGlobal.showUnconfiguredFades = v and true or false
				end,
			},
			auraShowUnconfiguredDebuffGains = {
				type  = "toggle",
				name  = "Show Debuff Gains Without Rules",
				desc  = "If disabled, harmful debuff gain notifications only show when you have a Debuff Rule for that spell (whitelist mode).",
				width = "full",
				order = 29.91,
				get   = function()
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					local g = sc and sc.auraGlobal
					if type(g) ~= "table" then return true end
					if g.showUnconfiguredDebuffGains == nil then
						return g.showUnconfiguredGains ~= false
					end
					return g.showUnconfiguredDebuffGains ~= false
				end,
				set   = function(_, v)
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					if not sc then return end
					sc.auraGlobal = sc.auraGlobal or {}
					sc.auraGlobal.showUnconfiguredDebuffGains = v and true or false
				end,
			},
			auraShowUnconfiguredDebuffFades = {
				type  = "toggle",
				name  = "Show Debuff Fades Without Rules",
				desc  = "If disabled, harmful debuff fade notifications only show when you have a Debuff Rule for that spell (whitelist mode).",
				width = "full",
				order = 29.92,
				get   = function()
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					local g = sc and sc.auraGlobal
					if type(g) ~= "table" then return true end
					if g.showUnconfiguredDebuffFades == nil then
						return g.showUnconfiguredFades ~= false
					end
					return g.showUnconfiguredDebuffFades ~= false
				end,
				set   = function(_, v)
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					if not sc then return end
					sc.auraGlobal = sc.auraGlobal or {}
					sc.auraGlobal.showUnconfiguredDebuffFades = v and true or false
				end,
			},
			rulesManagerDesc = {
				type     = "description",
				name     = "Manage per-spell outgoing throttles in a separate window.",
				order    = 31,
				fontSize = "medium",
			},
			openSpellRulesManager = {
				type  = "execute",
				name  = "Open Spell Rules Manager",
				desc  = "Open the Spell Rules Manager window.",
				order = 32,
				width = "full",
				func  = function()
					if Addon and Addon.OpenSpellRulesManager then
						Addon:OpenSpellRulesManager()
					end
				end,
			},
			openBuffRulesManager = {
				type  = "execute",
				name  = "Open Buff Rules Manager",
				desc  = "Open the Buff Rules Manager window.",
				order = 33,
				width = "full",
				func  = function()
					if Addon and Addon.OpenBuffRulesManager then
						Addon:OpenBuffRulesManager()
					end
				end,
			},
        },
    }
end

function ZSBT.BuildTab_SpellRulesManager()
	return {
		type  = "group",
		name  = "|cFFFFD100Spell Rules|r",
		order = 1,
		args  = {
			headerRules = {
				type  = "header",
				name  = "Spell Rules (Per-Spell)",
				order = 1,
			},
			rulesDesc = {
				type     = "description",
				name     = "Create per-spell outgoing throttle rules. These rules apply to Outgoing damage/healing only (not notifications).",
				order    = 2,
				fontSize = "medium",
			},
			addByIdHeader = {
				type  = "header",
				name  = "Add Rule",
				order = 10,
			},
			spellIdInput = {
				type  = "input",
				name  = "SpellID",
				desc  = "Enter a SpellID or exact spell name to add a rule.",
				order = 11,
				width = "full",
				get   = function() return spellRuleSpellInput end,
				set   = function(_, val) spellRuleSpellInput = tostring(val or "") end,
			},
			spellIdResolved = {
				type  = "description",
				name  = function()
					local sid = nil
					if ZSBT.ResolveSpellInputToID then
						sid = ZSBT.ResolveSpellInputToID(spellRuleSpellInput)
					else
						sid = tonumber(spellRuleSpellInput)
					end
					return (ZSBT.GetResolvedSpellLabel and ZSBT.GetResolvedSpellLabel(sid)) or ""
				end,
				order = 11.05,
				width = "full",
				hidden = function()
					local sid = nil
					if ZSBT.ResolveSpellInputToID then
						sid = ZSBT.ResolveSpellInputToID(spellRuleSpellInput)
					else
						sid = tonumber(spellRuleSpellInput)
					end
					return not (type(sid) == "number")
				end,
			},
			addSpellId = {
				type  = "execute",
				name  = "Add",
				desc  = "Add a rule for this SpellID (merge-only).",
				order = 12,
				width = "full",
				func  = function()
					local spellID = nil
					if ZSBT.ResolveSpellInputToID then
						spellID = ZSBT.ResolveSpellInputToID(spellRuleSpellInput)
					else
						spellID = tonumber(spellRuleSpellInput)
					end
					if not spellID then return end
					local name = SafeGetSpellName(spellID)
					if not name then return end
					local sc = ZSBT.db.profile.spamControl
					sc.spellRules = sc.spellRules or {}
					if sc.spellRules[spellID] == nil then
						sc.spellRules[spellID] = { enabled = true, throttleSec = 0.20 }
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT_SpellRules")
				end,
			},
			addRuleSpacer = {
				type  = "description",
				name  = " ",
				order = 13,
			},
			presetsHeader = {
				type  = "header",
				name  = "Templates",
				order = 14,
			},
			rulesTemplateApplyAll = {
				type  = "execute",
				name  = "Apply Class Templates (Merge Only)",
				desc  = "Applies built-in templates for your class. Merge-only (never overwrites existing rules).",
				order = 15,
				width = "full",
				func  = function()
					ZSBT.ApplyCurrentClassSpecTemplates_Merge()
				end,
			},
			rulesTemplateAllSpecs = {
				type  = "toggle",
				name  = "Include All Specs (Recommended)",
				desc  = "If enabled, applies templates for ALL specs for your class (more rules, less maintenance).",
				order = 15.1,
				width = "full",
				get   = function()
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					return sc and sc.templates and sc.templates.applyAllSpecs == true
				end,
				set   = function(_, v)
					local sc = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.spamControl
					if not sc then return end
					sc.templates = sc.templates or {}
					sc.templates.applyAllSpecs = v and true or false
				end,
			},
			rulesTemplateNote = {
				type  = "description",
				name  = "Templates are merge-only: they add missing rules but never overwrite your custom rules.",
				order = 16,
				width = "full",
				fontSize = "medium",
			},

			headerRecent = {
				type  = "header",
				name  = "Recently Seen Spells",
				order = 20,
			},
			recentRefresh = {
				type  = "execute",
				name  = "Refresh Recent Spells",
				desc  = "Refresh the Recently Seen Spells list.",
				order = 20.5,
				width = "full",
				func  = function()
					local probe = ZSBT.Core and ZSBT.Core.OutgoingProbe
					local stats = probe and probe._recentSpellStats
					local n = 0
					if type(stats) == "table" then
						for _ in pairs(stats) do n = n + 1 end
					end
					if Addon and Addon.Print then
						Addon:Print("Spell Rules: recorded recent spells = " .. tostring(n))
					end
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT_SpellRules")
				end,
			},
			recentDesc = {
				type     = "description",
				name     = "These suggestions are based on outgoing spells ZSBT has recently emitted. Attack a target for a few seconds to populate this list.",
				order    = 21,
				fontSize = "medium",
			},
			recentStatus = {
				type     = "description",
				name     = function()
					local probe = ZSBT.Core and ZSBT.Core.OutgoingProbe
					local stats = probe and probe._recentSpellStats
					local n = 0
					if type(stats) == "table" then
						for _ in pairs(stats) do n = n + 1 end
					end
					return "Recorded recent spells: " .. tostring(n)
				end,
				order    = 21.5,
				fontSize = "medium",
			},
			recentContainer = {
				type   = "group",
				name   = "Recent Spells",
				order  = 22,
				inline = true,
				args   = {},
			},

			rulesListHeader = {
				type     = "description",
				name     = function()
					local rules = ZSBT.db.char.spamControl.spellRules or {}
					local count = 0
					for _ in pairs(rules) do count = count + 1 end
					if count == 0 then
						return "\n|cFF888888No spell rules yet.|r"
					end
					return "\n|cFFFFFFFFConfigured spell rules:|r"
				end,
				order    = 30,
				fontSize = "medium",
			},
			rulesListContainer = {
				type        = "group",
				name        = "Spell Rules List",
				order       = 31,
				inline      = true,
				hidden      = function()
					local rules = ZSBT.db.char.spamControl.spellRules or {}
					return next(rules) == nil
				end,
				args        = {},
			},
		},
	}
end

------------------------------------------------------------------------
-- Inject dynamic per-spell throttle rule controls into Spell Rules Manager.
------------------------------------------------------------------------
do
	local originalBuilder = ZSBT.BuildTab_SpellRulesManager

	ZSBT.BuildTab_SpellRulesManager = function()
		local tab = originalBuilder()
		local container = tab.args.rulesListContainer
		if not container then return tab end

		local MAX_RULE_SLOTS = 80
		local baseOrder = 1

		local function getSortedRuleSpellIDs()
			local rules = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl and ZSBT.db.char.spamControl.spellRules
			if not rules then return {} end
			local sorted = {}
			for spellID, rule in pairs(rules) do
				if type(spellID) == "number" and type(rule) == "table" then
					sorted[#sorted + 1] = spellID
				end
			end
			table.sort(sorted)
			return sorted
		end

		for slot = 1, MAX_RULE_SLOTS do
			local slotIndex = slot

			local function getSpellID()
				local sorted = getSortedRuleSpellIDs()
				return sorted[slotIndex]
			end

			container.args["ruleLabel_" .. slot] = {
				type   = "description",
				name   = function()
					local spellID = getSpellID()
					if not spellID then return "" end
					local name = SafeGetSpellName(spellID) or ("Spell #" .. tostring(spellID))
					return "  \226\128\162 " .. name .. "  |cFF888888(ID: " .. tostring(spellID) .. ")|r"
				end,
				order  = baseOrder + (slot - 1) * 4,
				width  = "double",
				hidden = function() return getSpellID() == nil end,
				fontSize = "medium",
			}

			container.args["ruleEnabled_" .. slot] = {
				type   = "toggle",
				name   = "Enabled",
				order  = baseOrder + (slot - 1) * 4 + 1,
				width  = "half",
				hidden = function() return getSpellID() == nil end,
				get    = function()
					local spellID = getSpellID()
					if not spellID then return false end
					local rule = ZSBT.db.char.spamControl.spellRules[spellID]
					if type(rule) ~= "table" then return false end
					return rule.enabled ~= false
				end,
				set    = function(_, val)
					local spellID = getSpellID()
					if not spellID then return end
					local rules = ZSBT.db.char.spamControl.spellRules
					rules[spellID] = rules[spellID] or {}
					rules[spellID].enabled = val and true or false
				end,
			}

			container.args["ruleEdit_" .. slot] = {
				type   = "execute",
				name   = "Edit",
				order  = baseOrder + (slot - 1) * 4 + 2,
				width  = "half",
				hidden = function() return getSpellID() == nil end,
				func   = function()
					local spellID = getSpellID(); if not spellID then return end
					if Addon and Addon.OpenSpellRuleEditor then
						Addon:OpenSpellRuleEditor(spellID)
					end
				end,
			}

			container.args["ruleRemove_" .. slot] = {
				type   = "execute",
				name   = "|cFFFF4444Remove|r",
				order  = baseOrder + (slot - 1) * 4 + 3,
				width  = "half",
				hidden = function() return getSpellID() == nil end,
				func   = function()
					local spellID = getSpellID()
					if not spellID then return end
					local rules = ZSBT.db.char.spamControl.spellRules
					rules[spellID] = nil
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT_SpellRules")
				end,
			}
		end

		local recentContainer = tab.args.recentContainer
		if recentContainer then
			recentContainer.args = {}
			local probe = ZSBT.Core and ZSBT.Core.OutgoingProbe
			local stats = probe and probe._recentSpellStats
			local rules = ZSBT.db and ZSBT.db.char and ZSBT.db.char.spamControl and ZSBT.db.char.spamControl.spellRules
			if type(stats) == "table" and type(rules) == "table" then
				local items = {}
				for spellID, st in pairs(stats) do
					if type(spellID) == "number" and type(st) == "table" then
						items[#items + 1] = {
							spellID = spellID,
							count = tonumber(st.count) or 0,
							lastAt = tonumber(st.lastAt) or 0,
						}
					end
				end
				table.sort(items, function(a, b)
					if a.count == b.count then
						return a.lastAt > b.lastAt
					end
					return a.count > b.count
				end)

				local maxItems = 12
				local shown = 0
				local recentBuffs = ZSBT.Core and ZSBT.Core._recentBuffStats
				for i = 1, #items do
					if shown >= maxItems then break end
					local it = items[i]
					local spellID = it.spellID
					if rules[spellID] == nil and not (type(recentBuffs) == "table" and recentBuffs[spellID] ~= nil) then
						shown = shown + 1
						local row = shown
						local name = SafeGetSpellName(spellID) or ("Spell #" .. tostring(spellID))
						recentContainer.args["recentLabel_" .. row] = {
						type  = "description",
						name  = ("%s  |cFF888888(ID: %s, seen: %d)|r"):format(name, tostring(spellID), it.count or 0),
						order = row * 3,
						width = "double",
					}
						recentContainer.args["recentAdd_" .. row] = {
						type  = "execute",
						name  = "Add Rule",
						desc  = "Create a per-spell outgoing throttle rule (merge-only).",
						order = row * 3 + 1,
						width = "half",
						disabled = false,
						func  = function()
							if rules[spellID] == nil then
								rules[spellID] = { enabled = true, throttleSec = 0.20 }
								LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT_SpellRules")
							end
						end,
					}
						recentContainer.args["recentSpacer_" .. row] = {
						type  = "description",
						name  = " ",
						order = row * 3 + 2,
						width = "full",
					}
					end
				end
			end
		end

		return tab
	end
end

------------------------------------------------------------------------
-- TAB 8: COOLDOWNS
-- Cooldown notification settings and tracked spell management.
-- Uses C_Spell.GetSpellInfo() for WoW 12.0+ compatibility.
------------------------------------------------------------------------

-- Module-level state for spell input
local cooldownSpellInput = ""

local spellRuleSpellInput = ""

function ZSBT.BuildTab_Cooldowns()
    return {
        type  = "group",
		name  = "|cFFFFD100Cooldowns|r",
        order = 8,
        args  = {
            ----------------------------------------------------------------
            -- Cooldown Notifications
            ----------------------------------------------------------------
            headerCooldowns = {
                type  = "header",
                name  = "Cooldown Notifications",
                order = 1,
            },
            midnightChargeNote = {
				type  = "description",
				name  = "|cFFFFD100Midnight 12.0 note:|r Multi-charge spells (charges) may not be reliably trackable because charge/recharge data can be hidden (\"secret\"). Cooldown ready notifications for charge spells may be delayed or unavailable.",
				order = 1.1,
				width = "full",
			},
			cooldownsDebugLevel = {
				type  = "select",
				name  = "Cooldown Debug Level",
				desc  = "Debug output for cooldown tracking only (cooldowns debug channel). Use /zsbt debug cooldowns <0-5>.",
				order = 1.5,
				values = function()
					return {
						[0] = "Off",
						[1] = "1 - Basic",
						[2] = "2 - Events",
						[3] = "3 - Timers",
						[4] = "4 - Cooldown API",
						[5] = "5 - Very Noisy",
					}
				end,
				get = function()
					local d = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics
					return (d and tonumber(d.cooldownsDebugLevel)) or 0
				end,
				set = function(_, val)
					ZSBT.db.profile.diagnostics.cooldownsDebugLevel = tonumber(val) or 0
				end,
			},
            enabled = {
                type  = "toggle",
                name  = "Show Cooldown Notifications",
                desc  = "Display a notification when tracked spells come off cooldown.",
                width = "full",
                order = 2,
                get   = function() return ZSBT.db.profile.cooldowns.enabled end,
                set   = function(_, val) ZSBT.db.profile.cooldowns.enabled = val end,
            },
            scrollArea = {
                type     = "select",
                name     = "Scroll Area",
                desc     = "Which scroll area displays cooldown notifications.",
                order    = 3,
                values   = function() return ZSBT.GetScrollAreaNames() end,
                disabled = function() return not ZSBT.db.profile.cooldowns.enabled end,
                get      = function() return ZSBT.db.profile.cooldowns.scrollArea end,
                set      = function(_, val) ZSBT.db.profile.cooldowns.scrollArea = val end,
            },
            showSpellIcon = {
                type  = "toggle",
                name  = "Show Spell Icon",
                desc  = "Include the spell icon in cooldown notifications.",
                order = 3.5,
                width = "full",
                disabled = function() return not ZSBT.db.profile.cooldowns.enabled end,
                get   = function() return ZSBT.db.profile.cooldowns.showSpellIcon == true end,
                set   = function(_, v) ZSBT.db.profile.cooldowns.showSpellIcon = v and true or false end,
            },
            format = {
                type     = "input",
                name     = "Notification Format",
                desc     = "Text format for cooldown notifications. Use %s for spell name.",
                order    = 4,
                width    = "double",
                disabled = function() return not ZSBT.db.profile.cooldowns.enabled end,
                get      = function() return ZSBT.db.profile.cooldowns.format end,
                set      = function(_, val) ZSBT.db.profile.cooldowns.format = val end,
            },
            -- Sound dropdown: standard select using BuildSoundDropdown()
            sound = {
                type     = "select",
                name     = "Notification Sound",
                desc     = "Sound to play when a cooldown finishes.",
                order    = 5,
                values   = function() return ZSBT.BuildSoundDropdown() end,
                -- No dialogControl — uses standard dropdown
                disabled = function() return not ZSBT.db.profile.cooldowns.enabled end,
                get      = function() return ZSBT.db.profile.media.sounds.cooldownReady end,
                set      = function(_, val) ZSBT.db.profile.media.sounds.cooldownReady = val end,
            },
            -- Test button for cooldown sound
            testCooldownSound = {
                type     = "execute",
                name     = "Play Sound",
                desc     = "Preview the selected notification sound.",
                order    = 6,
                width    = "half",
                disabled = function() return not ZSBT.db.profile.cooldowns.enabled end,
                func     = function()
                    ZSBT.PlayLSMSound(ZSBT.db.profile.media.sounds.cooldownReady)
                end,
            },

            ----------------------------------------------------------------
            -- Tracked Spells Management
            ----------------------------------------------------------------
            headerTracked = {
                type  = "header",
                name  = "Tracked Spells",
                order = 10,
            },
            manualEntryLabel = {
                type     = "description",
                name     = "\n|cFFFFFFFFOr enter spell ID or exact spell name manually:|r",
                order    = 20,
                fontSize = "medium",
                hidden   = function() return not ZSBT.db.profile.cooldowns.enabled end,
            },
            addSpellInput = {
                type     = "input",
                name     = "Spell ID or Name",
                desc     = "Enter a numeric spell ID or exact spell name to track.",
                order    = 21,
                width    = "normal",
                disabled = function() return not ZSBT.db.profile.cooldowns.enabled end,
                get      = function() return cooldownSpellInput end,
                set      = function(_, val)
                    cooldownSpellInput = tostring(val or "")
                end,
            },
            addSpellResolved = {
                type  = "description",
                name  = function()
                    local sid = nil
                    if ZSBT.ResolveSpellInputToID then
                        sid = ZSBT.ResolveSpellInputToID(cooldownSpellInput)
                    else
                        sid = tonumber(cooldownSpellInput)
                    end
                    return (ZSBT.GetResolvedSpellLabel and ZSBT.GetResolvedSpellLabel(sid)) or ""
                end,
                order = 21.05,
                width = "full",
                hidden = function()
                    local sid = nil
                    if ZSBT.ResolveSpellInputToID then
                        sid = ZSBT.ResolveSpellInputToID(cooldownSpellInput)
                    else
                        sid = tonumber(cooldownSpellInput)
                    end
                    return not (type(sid) == "number")
                end,
            },
            addSpellButton = {
                type     = "execute",
                name     = "Add",
                desc     = "Add the entered spell ID to tracking.",
                order    = 22,
                width    = "half",
                disabled = function()
                    if not ZSBT.db.profile.cooldowns.enabled then return true end
                    local sid = nil
                    if ZSBT.ResolveSpellInputToID then
                        sid = ZSBT.ResolveSpellInputToID(cooldownSpellInput)
                    else
                        sid = tonumber(cooldownSpellInput)
                    end
                    return type(sid) ~= "number"
                end,
                func     = function()
                    local spellID = nil
                    if ZSBT.ResolveSpellInputToID then
                        spellID = ZSBT.ResolveSpellInputToID(cooldownSpellInput)
                    else
                        spellID = tonumber(cooldownSpellInput)
                    end
                    if spellID then
                        local name = SafeGetSpellName(spellID)
                        if name then
                            ZSBT.db.char.cooldowns = ZSBT.db.char.cooldowns or {}
                            ZSBT.db.char.cooldowns.tracked = ZSBT.db.char.cooldowns.tracked or {}
                            ZSBT.db.char.cooldowns.tracked[spellID] = true
                            Addon:Print("Now tracking: " .. name .. " (ID: " .. spellID .. ")")
                        else
                            ZSBT.db.char.cooldowns = ZSBT.db.char.cooldowns or {}
                            ZSBT.db.char.cooldowns.tracked = ZSBT.db.char.cooldowns.tracked or {}
                            ZSBT.db.char.cooldowns.tracked[spellID] = true
                            Addon:Print("Now tracking spell ID: " .. spellID .. " (name not found)")
                        end
                        cooldownSpellInput = ""
                        LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                    end
                end,
            },
            trackedListHeader = {
                type     = "description",
                name     = function()
                    local tracked = ZSBT.db.char and ZSBT.db.char.cooldowns and ZSBT.db.char.cooldowns.tracked or {}
                    local count = 0
                    for _ in pairs(tracked) do count = count + 1 end
                    if count == 0 then
                        return "\n|cFF888888No spells currently tracked.|r"
                    end
                    return "\n|cFFFFFFFFCurrently tracking " .. count .. " spell(s):|r"
                end,
                order    = 30,
                fontSize = "medium",
            },
            trackedListContainer = {
                type     = "group",
                name     = "Tracked Spells List",
                order    = 31,
                childGroups = "tree",  -- Makes it a collapsible tree with auto-scroll
                hidden   = function()
                    local count = 0
                    local tracked = ZSBT.db.char and ZSBT.db.char.cooldowns and ZSBT.db.char.cooldowns.tracked or {}
                    for _ in pairs(tracked) do count = count + 1 end
                    return count == 0
                end,
                args     = {},  -- Will be populated dynamically below
            },
            -- Dynamic per-spell entries with X (remove) buttons
            -- Built dynamically below in BuildTab_Cooldowns
        },
    }
end

------------------------------------------------------------------------
-- Override BuildTab_Cooldowns to inject dynamic per-spell remove buttons.
-- We wrap the original builder to add execute buttons for each tracked
-- spell, using a stable ordering based on spell ID.
--
-- AceConfig doesn't support truly dynamic widget lists, so we rebuild
-- the args table each time the tab group is accessed by using a
-- "get children dynamically" pattern via the args function closures.
------------------------------------------------------------------------
do
    local originalBuilder = ZSBT.BuildTab_Cooldowns

    ZSBT.BuildTab_Cooldowns = function()
        local tab = originalBuilder()

        -- Get the tracked list container
        local container = tab.args.trackedListContainer

        local MAX_TRACKED_SLOTS = 50
        local baseOrder = 1  -- Start at 1 within the container

        for slot = 1, MAX_TRACKED_SLOTS do
            local slotIndex = slot

            local function getSlotIDKey()
                local sorted = {}
                local tracked = ZSBT.db.char and ZSBT.db.char.cooldowns and ZSBT.db.char.cooldowns.tracked or {}
                for idKey, _ in pairs(tracked) do
                    sorted[#sorted + 1] = idKey
                end
                -- Mixed types (numbers for spells, strings for items) require a safe comparator
                table.sort(sorted, function(a, b) return tostring(a) < tostring(b) end)
                return sorted[slotIndex]
            end

            -- Entry label
            container.args["trackedSpell_" .. slot] = {
                type   = "description",
                name   = function()
                    local idKey = getSlotIDKey()
                    if not idKey then return "" end

                    if type(idKey) == "string" and idKey:match("^item:") then
                        local itemID = tonumber(idKey:match("^item:(%d+)$"))
                        local name = SafeGetItemName(itemID) or ("Item #" .. tostring(itemID or "?"))
                        return "  \226\128\162 " .. name .. "  |cFF888888(ID: " .. tostring(itemID or "?") .. ")|r"
                    else
                        local spellID = idKey
                        local name = SafeGetSpellName(spellID) or ("Spell #" .. spellID)
                        return "  \226\128\162 " .. name .. "  |cFF888888(ID: " .. spellID .. ")|r"
                    end
                end,
                order  = baseOrder + (slot - 1) * 2,
                width  = "double",
                hidden = function() return getSlotIDKey() == nil end,
                fontSize = "medium",
            }

            -- Remove (X) button
            container.args["removeSpell_" .. slot] = {
                type   = "execute",
                name   = "|cFFFF4444X|r",
                desc   = function()
                    local idKey = getSlotIDKey()
                    if not idKey then return "Remove entry" end

                    if type(idKey) == "string" and idKey:match("^item:") then
                        local itemID = tonumber(idKey:match("^item:(%d+)$"))
                        local name = SafeGetItemName(itemID) or ("Item #" .. tostring(itemID or "?"))
                        return "Remove " .. name .. " from tracking"
                    else
                        local spellID = idKey
                        local name = SafeGetSpellName(spellID) or ("Spell #" .. spellID)
                        return "Remove " .. name .. " from tracking"
                    end
                end,
                order  = baseOrder + (slot - 1) * 2 + 1,
                width  = "half",
                hidden = function() return getSlotIDKey() == nil end,
                func   = function()
                    local idKey = getSlotIDKey()
                    if idKey then
                        local name
                        if type(idKey) == "string" and idKey:match("^item:") then
                            local itemID = tonumber(idKey:match("^item:(%d+)$"))
                            name = SafeGetItemName(itemID) or ("Item #" .. tostring(itemID or "?"))
                        else
                            local spellID = idKey
                            name = SafeGetSpellName(spellID) or ("Spell #" .. spellID)
                        end
                        StaticPopup_Show("TRUESTRIKE_REMOVE_SPELL", name, nil, idKey)
                    end
                end,
            }
        end

        return tab
    end
end

------------------------------------------------------------------------
-- TAB 9: MEDIA
-- Sound events and damage school color pickers.
-- All sound dropdowns use standard select with BuildSoundDropdown().
-- Each sound dropdown has a "Play Sound" test button.
------------------------------------------------------------------------
function ZSBT.BuildTab_Media()
    local customFontName = ""
    local customFontFile = ""
    local customSoundName = ""
    local customSoundFile = ""

    local function ensureCustomTables()
        local p = ZSBT.db and ZSBT.db.profile
        if not p then return nil end
        p.media = p.media or {}
        p.media.custom = p.media.custom or {}
        p.media.custom.fonts = p.media.custom.fonts or {}
        p.media.custom.sounds = p.media.custom.sounds or {}
        return p.media.custom
    end

    local function registerCustom(kind, name, path)
        local LSM = LibStub("LibSharedMedia-3.0", true)
        if not LSM then return false end
        local ok = pcall(function() LSM:Register(kind, name, path) end)
        return ok == true
    end

    local function buildCustomMediaListArgs()
        local args = {}
        local custom = ensureCustomTables()
        if not custom then return args end

        local row = 0

        local function addRow(label, onRemove, onPlay)
            row = row + 1
            args["label_" .. row] = {
                type  = "description",
                name  = label,
                order = row * 3,
                width = "double",
            }
            args["remove_" .. row] = {
                type  = "execute",
                name  = "Remove",
                order = row * 3 + 1,
                width = "half",
                func  = function()
                    if onRemove then onRemove() end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            }
            args["play_" .. row] = {
                type  = "execute",
                name  = "Play",
                order = row * 3 + 2,
                width = "half",
                hidden = function() return onPlay == nil end,
                func  = function()
                    if onPlay then onPlay() end
                end,
            }
        end

        local fontNames = {}
        for name, _ in pairs(custom.fonts) do
            if type(name) == "string" then fontNames[#fontNames + 1] = name end
        end
        table.sort(fontNames)
        for _, name in ipairs(fontNames) do
            addRow("Font: " .. name, function()
                custom.fonts[name] = nil
            end, nil)
        end

        local soundNames = {}
        for name, _ in pairs(custom.sounds) do
            if type(name) == "string" then soundNames[#soundNames + 1] = name end
        end
        table.sort(soundNames)
        for _, name in ipairs(soundNames) do
            addRow("Sound: " .. name, function()
                custom.sounds[name] = nil
            end, function()
                if ZSBT.PlayLSMSound then
                    ZSBT.PlayLSMSound(name)
                end
            end)
        end

        if row == 0 then
            args.none = {
                type = "description",
                name = "No custom media registered.",
                order = 1,
                width = "full",
            }
        end

        return args
    end

    local function normalizeBaseFilename(s)
        s = tostring(s or "")
        s = s:gsub("^%s+", ""):gsub("%s+$", "")
        s = s:gsub("[/]+", "\\")
        s = s:gsub("^Interface\\AddOns\\ZSBT\\Media\\Fonts\\", "")
        s = s:gsub("^Interface\\AddOns\\ZSBT\\Media\\Sounds\\", "")
        s = s:gsub("\\+", "")
        s = s:gsub("%.[%w]+$", "")
        return s
    end

    local function openRegisteredMediaWindow()
        local AceGUI = LibStub("AceGUI-3.0", true)
        if not AceGUI then return end

        if ZSBT._registeredMediaWindow then
            pcall(function() ZSBT._registeredMediaWindow:Release() end)
            ZSBT._registeredMediaWindow = nil
        end

        local frame = AceGUI:Create("Frame")
        ZSBT._registeredMediaWindow = frame
        frame:SetTitle("Currently Registered Media")
        frame:SetLayout("Fill")
        frame:SetWidth(520)
        frame:SetHeight(480)
        frame:EnableResize(true)

        local scroll = AceGUI:Create("ScrollFrame")
        scroll:SetLayout("Flow")
        frame:AddChild(scroll)

        local custom = ensureCustomTables()
        local args = buildCustomMediaListArgs()

        local function addRow(label, onRemove, onPlay)
            local lbl = AceGUI:Create("Label")
            lbl:SetText(label)
            lbl:SetFullWidth(true)
            scroll:AddChild(lbl)

            local btnRow = AceGUI:Create("SimpleGroup")
            btnRow:SetLayout("Flow")
            btnRow:SetFullWidth(true)
            scroll:AddChild(btnRow)

            local removeBtn = AceGUI:Create("Button")
            removeBtn:SetText("Remove")
            removeBtn:SetWidth(140)
            removeBtn:SetCallback("OnClick", function()
                if onRemove then onRemove() end
                LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                openRegisteredMediaWindow()
            end)
            btnRow:AddChild(removeBtn)

            if onPlay then
                local playBtn = AceGUI:Create("Button")
                playBtn:SetText("Play")
                playBtn:SetWidth(140)
                playBtn:SetCallback("OnClick", function()
                    onPlay()
                end)
                btnRow:AddChild(playBtn)
            end

            local spacer = AceGUI:Create("Label")
            spacer:SetText(" ")
            spacer:SetFullWidth(true)
            scroll:AddChild(spacer)
        end

        local fontNames = {}
        for name, _ in pairs(custom and custom.fonts or {}) do
            if type(name) == "string" then fontNames[#fontNames + 1] = name end
        end
        table.sort(fontNames)
        for _, name in ipairs(fontNames) do
            addRow("Font: " .. name, function()
                custom.fonts[name] = nil
            end, nil)
        end

        local soundNames = {}
        for name, _ in pairs(custom and custom.sounds or {}) do
            if type(name) == "string" then soundNames[#soundNames + 1] = name end
        end
        table.sort(soundNames)
        for _, name in ipairs(soundNames) do
            addRow("Sound: " .. name, function()
                custom.sounds[name] = nil
            end, function()
                if ZSBT.PlayLSMSound then
                    ZSBT.PlayLSMSound(name)
                end
            end)
        end

        if #fontNames == 0 and #soundNames == 0 then
            local none = AceGUI:Create("Label")
            none:SetText("No custom media registered.")
            none:SetFullWidth(true)
            scroll:AddChild(none)
        end
    end

    local customMediaListArgs = buildCustomMediaListArgs()

    return {
        type  = "group",
		name  = "|cFFFFD100Media|r",
        order = 9,
        args  = {
            ----------------------------------------------------------------
            -- Sound Events
            ----------------------------------------------------------------
            headerSounds = {
                type  = "header",
                name  = "Sound Events",
                order = 1,
            },
            -- Low Health sound: standard select
            lowHealthSound = {
                type   = "select",
                name   = "Low Health Warning",
                desc   = "Sound to play when Blizzard's low health warning triggers (red border).",
                order  = 2,
                values = function() return ZSBT.BuildSoundDropdown() end,
                -- No dialogControl — uses standard dropdown
                get    = function() return ZSBT.db.profile.media.sounds.lowHealth end,
                set    = function(_, val) ZSBT.db.profile.media.sounds.lowHealth = val end,
            },
            testLowHealth = {
                type  = "execute",
                name  = "Play Sound",
                desc  = "Preview the selected low health warning sound.",
                order = 3,
                width = "half",
                func  = function()
                    ZSBT.PlayLSMSound(ZSBT.db.profile.media.sounds.lowHealth)
                end,
            },

            -- Cooldown Ready sound: standard select
            cooldownReadySound = {
                type   = "select",
                name   = "Cooldown Ready",
                desc   = "Sound to play when a tracked cooldown finishes.",
                order  = 4,
                values = function() return ZSBT.BuildSoundDropdown() end,
                -- No dialogControl — uses standard dropdown
                get    = function() return ZSBT.db.profile.media.sounds.cooldownReady end,
                set    = function(_, val) ZSBT.db.profile.media.sounds.cooldownReady = val end,
            },
            testCooldownReady = {
                type  = "execute",
                name  = "Play Sound",
                desc  = "Preview the selected cooldown ready sound.",
                order = 5,
                width = "half",
                func  = function()
                    ZSBT.PlayLSMSound(ZSBT.db.profile.media.sounds.cooldownReady)
                end,
            },

            ----------------------------------------------------------------
            -- Custom Media
            ----------------------------------------------------------------
            headerCustomMedia = {
                type  = "header",
                name  = "Custom Media",
                order = 6,
            },
            customMediaDesc = {
                type  = "description",
                name  = "1) Put fonts in: Interface\\AddOns\\ZSBT\\Media\\Fonts (TTF). 2) Put sounds in: Interface\\AddOns\\ZSBT\\Media\\Sounds (OGG). 3) Enter the filename (no extension) and click Add.",
                order = 7,
                width = "full",
                fontSize = "medium",
            },

            customFontName = {
                type  = "input",
                name  = "Custom Font Name",
                desc  = "Display name used in dropdowns.",
                order = 8,
                width = "normal",
                dialogControl = "ZSBT_InstantEditBox",
                get   = function() return customFontName end,
                set   = function(_, v) customFontName = tostring(v or "") end,
            },
            customFontFile = {
                type  = "input",
                name  = "Font Filename",
                desc  = "Example: MyFont (will load ZSBT\\Media\\Fonts\\MyFont.ttf)",
                order = 9,
                width = "double",
                dialogControl = "ZSBT_InstantEditBox",
                get   = function() return customFontFile end,
                set   = function(_, v) customFontFile = tostring(v or "") end,
            },
            customFontAdd = {
                type  = "execute",
                name  = "Add Font",
                order = 10,
                width = "full",
                disabled = function()
                    return customFontName == "" or customFontFile == ""
                end,
                func  = function()
                    local custom = ensureCustomTables()
                    if not custom then return end
                    local name = tostring(customFontName or "")
                    local base = normalizeBaseFilename(customFontFile)
                    if name == "" or base == "" then return end

                    local path = "Interface\\AddOns\\ZSBT\\Media\\Fonts\\" .. base .. ".ttf"

                    custom.fonts[name] = path
                    registerCustom("font", name, path)
                    customFontName = ""
                    customFontFile = ""
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },

            customSoundName = {
                type  = "input",
                name  = "Custom Sound Name",
                desc  = "Display name used in dropdowns.",
                order = 11,
                width = "normal",
                dialogControl = "ZSBT_InstantEditBox",
                get   = function() return customSoundName end,
                set   = function(_, v) customSoundName = tostring(v or "") end,
            },
            customSoundFile = {
                type  = "input",
                name  = "Sound Filename",
                desc  = "Example: MySound (will load ZSBT\\Media\\Sounds\\MySound.ogg)",
                order = 12,
                width = "double",
                dialogControl = "ZSBT_InstantEditBox",
                get   = function() return customSoundFile end,
                set   = function(_, v) customSoundFile = tostring(v or "") end,
            },
            customSoundAdd = {
                type  = "execute",
                name  = "Add Sound",
                order = 13,
                width = "full",
                disabled = function()
                    return customSoundName == "" or customSoundFile == ""
                end,
                func  = function()
                    local custom = ensureCustomTables()
                    if not custom then return end
                    local name = tostring(customSoundName or "")
                    local base = normalizeBaseFilename(customSoundFile)
                    if name == "" or base == "" then return end

                    local path = "Interface\\AddOns\\ZSBT\\Media\\Sounds\\" .. base .. ".ogg"

                    custom.sounds[name] = path
                    registerCustom("sound", name, path)
                    customSoundName = ""
                    customSoundFile = ""
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },

            openRegisteredMedia = {
                type  = "execute",
                name  = "Currently Registered Media",
                desc  = "View and manage registered custom fonts and sounds.",
                order = 14,
                width = "full",
                func  = function()
                    openRegisteredMediaWindow()
                end,
            },

            ----------------------------------------------------------------
            -- Damage School Colors
            ----------------------------------------------------------------
            headerSchoolColors = {
                type  = "header",
                name  = "Damage School Colors",
                order = 20,
            },
            schoolColorDesc = {
                type     = "description",
                name     = "Customize the color used for each damage school when " ..
                           "school-based coloring is enabled.",
                order    = 21,
                fontSize = "medium",
            },
            colorPhysical = {
                type  = "color",
                name  = "Physical",
                order = 22,
                get   = function()
                    local c = ZSBT.db.profile.media.schoolColors.physical
                    return c.r, c.g, c.b
                end,
                set   = function(_, r, g, b)
                    local c = ZSBT.db.profile.media.schoolColors.physical
                    c.r, c.g, c.b = r, g, b
                end,
            },
            colorHoly = {
                type  = "color",
                name  = "Holy",
                order = 23,
                get   = function()
                    local c = ZSBT.db.profile.media.schoolColors.holy
                    return c.r, c.g, c.b
                end,
                set   = function(_, r, g, b)
                    local c = ZSBT.db.profile.media.schoolColors.holy
                    c.r, c.g, c.b = r, g, b
                end,
            },
            colorFire = {
                type  = "color",
                name  = "Fire",
                order = 24,
                get   = function()
                    local c = ZSBT.db.profile.media.schoolColors.fire
                    return c.r, c.g, c.b
                end,
                set   = function(_, r, g, b)
                    local c = ZSBT.db.profile.media.schoolColors.fire
                    c.r, c.g, c.b = r, g, b
                end,
            },
            colorNature = {
                type  = "color",
                name  = "Nature",
                order = 25,
                get   = function()
                    local c = ZSBT.db.profile.media.schoolColors.nature
                    return c.r, c.g, c.b
                end,
                set   = function(_, r, g, b)
                    local c = ZSBT.db.profile.media.schoolColors.nature
                    c.r, c.g, c.b = r, g, b
                end,
            },
            colorFrost = {
                type  = "color",
                name  = "Frost",
                order = 26,
                get   = function()
                    local c = ZSBT.db.profile.media.schoolColors.frost
                    return c.r, c.g, c.b
                end,
                set   = function(_, r, g, b)
                    local c = ZSBT.db.profile.media.schoolColors.frost
                    c.r, c.g, c.b = r, g, b
                end,
            },
            colorShadow = {
                type  = "color",
                name  = "Shadow",
                order = 27,
                get   = function()
                    local c = ZSBT.db.profile.media.schoolColors.shadow
                    return c.r, c.g, c.b
                end,
                set   = function(_, r, g, b)
                    local c = ZSBT.db.profile.media.schoolColors.shadow
                    c.r, c.g, c.b = r, g, b
                end,
            },
            colorArcane = {
                type  = "color",
                name  = "Arcane",
                order = 28,
                get   = function()
                    local c = ZSBT.db.profile.media.schoolColors.arcane
                    return c.r, c.g, c.b
                end,
                set   = function(_, r, g, b)
                    local c = ZSBT.db.profile.media.schoolColors.arcane
                    c.r, c.g, c.b = r, g, b
                end,
            },

            ----------------------------------------------------------------
            -- Reset Colors
            ----------------------------------------------------------------
            spacer1 = { type = "description", name = "\n", order = 19 },
            resetColors = {
                type    = "execute",
                name    = "Reset School Colors to Defaults",
                desc    = "Restore all damage school colors to their factory defaults.",
                order   = 30,
                confirm = true,
                confirmText = "Reset all damage school colors to defaults?",
                func    = function()
                    local defaults = ZSBT.DEFAULTS.profile.media.schoolColors
                    local current  = ZSBT.db.profile.media.schoolColors
                    for school, color in pairs(defaults) do
                        current[school] = { r = color.r, g = color.g, b = color.b }
                    end
                    Addon:Print("Damage school colors reset to defaults.")
                end,
            },
        },
    }
end

------------------------------------------------------------------------
-- Test Scroll Area Function
-- Fires 3 "TEST 12345" texts into a named scroll area with 0.3s stagger.
-- Uses C_Timer for staggered firing. Falls back to chat output if
-- the Display system isn't built yet.
------------------------------------------------------------------------
if not ZSBT.TestScrollArea then
function ZSBT.TestScrollArea(areaName)
    if not areaName then return end

    local area = ZSBT.db and ZSBT.db.profile.scrollAreas[areaName]
    if not area then
        ZSBT.Addon:Print("Scroll area '" .. areaName .. "' not found.")
        return
    end

    -- Number of test texts and stagger delay
    local TEST_COUNT = 3
    local STAGGER_SECONDS = 0.3

    for i = 1, TEST_COUNT do
        -- Use C_Timer to stagger the test outputs
        C_Timer.After((i - 1) * STAGGER_SECONDS, function()
            -- If the Display system has a rendering function, use it
            if ZSBT.DisplayText then
                ZSBT.DisplayText(areaName, "TEST 12345", {
                    r = ZSBT.COLORS.ACCENT.r,
                    g = ZSBT.COLORS.ACCENT.g,
                    b = ZSBT.COLORS.ACCENT.b,
                })
            else
                -- Fallback: print to chat until Display system is implemented
                ZSBT.Addon:Print("|cFF00CC66TEST 12345|r ÃƒÂ¢Ã¢â‚¬Â Ã¢â‚¬â„¢ [" .. areaName .. "] (" .. i .. "/" .. TEST_COUNT .. ")")
            end
        end)
    end
end
end

------------------------------------------------------------------------
-- Tab: Profiles — Import / Export
-- Serializes the current profile using AceSerializer-3.0 and provides
-- a text box for copy/paste sharing.
------------------------------------------------------------------------
local profileText = ""
local profileStatus = ""

local localHex = {
	["0"] = 0,
	["1"] = 1,
	["2"] = 2,
	["3"] = 3,
	["4"] = 4,
	["5"] = 5,
	["6"] = 6,
	["7"] = 7,
	["8"] = 8,
	["9"] = 9,
	["a"] = 10,
	["b"] = 11,
	["c"] = 12,
	["d"] = 13,
	["e"] = 14,
	["f"] = 15,
}

local function HexEncode(str)
	if type(str) ~= "string" then return "" end
	return (str:gsub(".", function(c)
		return string.format("%02x", string.byte(c))
	end))
end

local function HexDecode(hex)
	if type(hex) ~= "string" then return nil end
	if (#hex % 2) ~= 0 then return nil end
	local out = {}
	for i = 1, #hex, 2 do
		local hi = localHex[string.lower(hex:sub(i, i))]
		local lo = localHex[string.lower(hex:sub(i + 1, i + 1))]
		if hi == nil or lo == nil then return nil end
		out[#out + 1] = string.char(hi * 16 + lo)
	end
	return table.concat(out)
end

local function BuildSharePayloadFromProfile(profile)
    if type(profile) ~= "table" then return nil end

    local payload = {
        _zsbt = "share",
        ver = 1,
        addonVersion = ZSBT.VERSION,
        profile = profile,
    }
    return payload
end

function ZSBT.BuildTab_Profiles()
    return {
        type  = "group",
		name  = "|cFFFFD100Import / Export|r",
		order = 11,
        args  = {
            headerProfiles = {
                type  = "header",
                name  = "|cFFFFD100Profile Management|r",
                order = 1,
            },
            profileDesc = {
                type  = "description",
                name  = "|cFF808C9EExport your current settings to share with others, or import a profile string to load someone else's configuration. Import will overwrite your current profile.|r",
                order = 2,
                width = "full",
                fontSize = "medium",
            },
            spacer1 = {
                type = "description", name = " ", order = 3, width = "full",
            },
            exportBtn = {
                type    = "execute",
                name    = "Export Current Profile",
                desc    = "Serialize your current profile into a versioned share string.",
                order   = 4,
                width   = "normal",
                func    = function()
                    local AceSerializer = LibStub("AceSerializer-3.0", true)
                    if not AceSerializer then
                        profileStatus = "|cFFFF4444AceSerializer not available.|r"
                        return
                    end
                    local profile = ZSBT.db and ZSBT.db.profile
                    if not profile then
                        profileStatus = "|cFFFF4444No profile data found.|r"
                        return
                    end

                    local payload = BuildSharePayloadFromProfile(profile)
                    local ok, serialized = pcall(function()
                        return AceSerializer:Serialize(payload)
                    end)
                    if ok and type(serialized) == "string" and serialized ~= "" then
                        -- Encode to a printable string for AceGUI multiline inputs / clipboard friendliness
                        profileText = "ZSBT1:" .. HexEncode(serialized)
                        profileStatus = "|cFF00CC66Profile exported! Copy the text below.|r"
                    else
                        profileStatus = "|cFFFF4444Serialization failed.|r"
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            importBtn = {
                type    = "execute",
                name    = "Import Profile",
                desc    = "Load settings from the text box below. This will overwrite your current profile.",
                order   = 5,
                width   = "normal",
                confirm = true,
                confirmText = "This will overwrite your current profile settings. Are you sure?",
                func    = function()
                    local AceSerializer = LibStub("AceSerializer-3.0", true)
                    if not AceSerializer then
                        profileStatus = "|cFFFF4444AceSerializer not available.|r"
                        return
                    end
                    if not profileText or profileText == "" then
                        profileStatus = "|cFFFF4444Paste a profile string first.|r"
                        return
                    end

                    local importStr = profileText
                    if type(importStr) == "string" and importStr:sub(1, 6) == "ZSBT1:" then
                        local decoded = HexDecode(importStr:sub(7))
                        if not decoded then
                            profileStatus = "|cFFFF4444Invalid ZSBT1 string (decode failed).|r"
                            LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                            return
                        end
                        importStr = decoded
                    end

                    local ok, data = AceSerializer:Deserialize(importStr)

                    local importedProfile = nil
                    local importKind = nil

                    if ok and type(data) == "table" then
                        if data._zsbt == "share" then
                            if data.ver ~= 1 then
                                profileStatus = "|cFFFF4444Unsupported share string version.|r"
                                LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                                return
                            end
                            if type(data.profile) == "table" then
                                importedProfile = data.profile
                                importKind = "share"
                            end
                        elseif data._zsbt == nil and data.ver == nil then
                            importedProfile = data
                            importKind = "legacy"
                        end
                    end

                    if type(importedProfile) == "table" then
                        local profile = ZSBT.db.profile
                        for k, v in pairs(importedProfile) do
                            if k ~= "char" then
                                profile[k] = v
                            end
                        end

                        if importKind == "legacy" then
                            profileStatus = "|cFF00CC66Legacy profile imported successfully! /reload to apply.|r"
                        else
                            profileStatus = "|cFF00CC66Profile imported successfully! /reload to apply.|r"
                        end
                        if ZSBT.Addon and ZSBT.Addon.Print then
                            ZSBT.Addon:Print("Profile imported. Type /reload to apply all changes.")
                        end
                    else
                        profileStatus = "|cFFFF4444Invalid profile string. Check that you pasted the complete text.|r"
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            spacer2 = {
                type = "description", name = " ", order = 6, width = "full",
            },
            statusText = {
                type  = "description",
                name  = function() return profileStatus end,
                order = 7,
                width = "full",
                fontSize = "medium",
            },
            spacer3 = {
                type = "description", name = " ", order = 8, width = "full",
            },
            headerTextBox = {
                type  = "header",
                name  = "Profile Data",
                order = 9,
            },
            clearTextBox = {
                type  = "execute",
                name  = "Clear",
                desc  = "Clear the text box.",
                order = 9.5,
                width = "half",
                func  = function()
                    profileText = ""
                    profileStatus = ""
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
                end,
            },
            profileTextBox = {
                type      = "input",
                name      = "",
                desc      = "Profile data string. Export fills this, or paste an import string here.",
                order     = 10,
                multiline = 15,
                width     = "full",
                get       = function() return profileText end,
                set       = function(_, val)
                    profileText = val
                    profileStatus = ""
                end,
            },
        },
    }
end
