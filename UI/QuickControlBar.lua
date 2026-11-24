local ADDON_NAME, ZSBT = ...
local L = ZSBT.L

ZSBT.UI = ZSBT.UI or {}
ZSBT.UI.QuickControlBar = ZSBT.UI.QuickControlBar or {}
local QuickBar = ZSBT.UI.QuickControlBar

local function notifyConfig()
	local reg = LibStub and LibStub("AceConfigRegistry-3.0", true)
	if reg and reg.NotifyChange then
		reg:NotifyChange("ZSBT")
	end
end

local function getGeneral()
	return ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general or nil
end

local function isEnabled()
	local g = getGeneral()
	return g and g.quickControlBarEnabled == true
end

local function ensurePositionDefaults(g)
	g.quickControlBarPos = g.quickControlBarPos or {}
	if type(g.quickControlBarPos.x) ~= "number" then g.quickControlBarPos.x = 0 end
	if type(g.quickControlBarPos.y) ~= "number" then g.quickControlBarPos.y = 220 end
end

local function applyPosition(frame)
	local g = getGeneral()
	if not g or not frame then return end
	ensurePositionDefaults(g)
	frame:ClearAllPoints()
	frame:SetPoint("CENTER", UIParent, "CENTER", g.quickControlBarPos.x, g.quickControlBarPos.y)
end

local function savePosition(frame)
	local g = getGeneral()
	if not g or not frame then return end
	ensurePositionDefaults(g)

	local centerX = UIParent:GetWidth() / 2
	local centerY = UIParent:GetHeight() / 2
	local frameX = frame:GetLeft() + (frame:GetWidth() / 2)
	local frameY = frame:GetBottom() + (frame:GetHeight() / 2)
	local x = math.floor(frameX - centerX + 0.5)
	local y = math.floor(frameY - centerY + 0.5)
	g.quickControlBarPos.x = x
	g.quickControlBarPos.y = y
end

local function refreshActiveDropDown()
	if not QuickBar or not QuickBar._dropDown then return end
	if UIDropDownMenu_Refresh then
		pcall(UIDropDownMenu_Refresh, QuickBar._dropDown, nil, 1)
	end
	if UIDropDownMenu_RefreshAll then
		pcall(UIDropDownMenu_RefreshAll, QuickBar._dropDown)
	end
end

local function getDeadFeedMode()
	local g = getGeneral()
	return (g and g.deadFeedMode) or "strict"
end

local function setDeadFeedMode(mode)
	local g = getGeneral()
	if not g then return end
	g.deadFeedMode = mode
	notifyConfig()
	refreshActiveDropDown()
end

-- Outgoing accuracy menu: one exclusive dead-feed mode plus the
-- surviving display toggles, sectioned by what each layer controls.
local function buildOutgoingMenu()
	local items = {
		{ text = L["Outgoing Accuracy"], isTitle = true },
		{ text = L["FALLBACK — ONLY IF FEED STOPS"], isTitle = true, notCheckable = true },
		{
			text = L["Strict — proven hits only"],
			checked = function() return getDeadFeedMode() == "strict" end,
			func = function() setDeadFeedMode("strict") end,
			tooltipTitle = L["Strict"],
			tooltipText = L["If the combat-log feed stops or starves, only hits that can still be proven yours display. Safest, but your numbers may go quiet."],
			tooltipOnButton = true,
			keepShownOnClick = true,
		},
		{
			text = L["Relaxed — unproven hits too"],
			checked = function() return getDeadFeedMode() == "relaxed" end,
			func = function() setDeadFeedMode("relaxed") end,
			tooltipTitle = L["Relaxed"],
			tooltipText = L["Unproven hits keep flowing when the feed is dead. A group member's damage on your target may rarely appear as yours."],
			tooltipOnButton = true,
			keepShownOnClick = true,
		},
		{
			text = L["Damage Meter — aggregate totals (default)"],
			checked = function() return getDeadFeedMode() == "meter" end,
			func = function() setDeadFeedMode("meter") end,
			tooltipTitle = L["Damage Meter"],
			tooltipText = L["Substitutes Blizzard's running damage totals while the feed is dead. Fewer per-hit details, no crit flags, but your numbers never go silent."],
			tooltipOnButton = true,
			keepShownOnClick = true,
		},
	}
	-- Way back: shown only while the fallback is off its default.
	if getDeadFeedMode() ~= ZSBT._defaultDeadFeedMode() then
		items[#items + 1] = {
			text = L["Reset to Default"],
			notCheckable = true,
			func = function() setDeadFeedMode(ZSBT._defaultDeadFeedMode()) end,
			tooltipTitle = L["Reset to Default"],
			tooltipText = L["Restore the Damage Meter fallback. Normal proven mode is automatic either way — this only matters while the feed is dead."],
			tooltipOnButton = true,
			keepShownOnClick = true,
		}
	end
	items[#items + 1] = { text = L["VISIBILITY"], isTitle = true, notCheckable = true }
	items[#items + 1] = {
			text = L["Proven hits without proof line"],
			isNotRadio = true,
			checked = function()
				local d = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.outgoing and ZSBT.db.profile.outgoing.damage
				return d ~= nil and d.provenNoLine == true
			end,
			func = function()
				local dmg = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.outgoing and ZSBT.db.profile.outgoing.damage
				if dmg then
					dmg.provenNoLine = not (dmg.provenNoLine == true)
					notifyConfig()
					refreshActiveDropDown()
				end
			end,
			tooltipTitle = L["Show Proven Hits Without Lines (Experimental)"],
			tooltipText = L["Hits proven by your own casts or swings display even when their proof line never arrives. Restores outgoing visibility in raids where the feed starves; a co-attacker's hit that steals a cast record can also display."],
			tooltipOnButton = true,
			keepShownOnClick = true,
	}
	-- Class-module pet naming: only for pet classes whose module
	-- declares the toggle.
	if ZSBT.ClassDB and ZSBT.ClassDB.SupportsToggle
		and ZSBT.ClassDB.SupportsToggle("namePetMelee") then
		items[#items + 1] = {
			text = L["Pet melee shows as \"Auto Attack\""],
			isNotRadio = true,
			checked = function()
				local cm = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.classModule
				return cm ~= nil and cm.namePetMelee == true
			end,
			func = function()
				local prof = ZSBT.db and ZSBT.db.profile
				if prof then
					prof.classModule = prof.classModule or {}
					prof.classModule.namePetMelee = not (prof.classModule.namePetMelee == true)
					notifyConfig()
					refreshActiveDropDown()
				end
			end,
			tooltipTitle = L["Show Pet Melee Hits as \"Auto Attack\""],
			tooltipText = L["Your pet's physical hits display as \"Auto Attack\" instead of a generic number. Only applies when the combat log already proved the hit came from your pet."],
			tooltipOnButton = true,
			keepShownOnClick = true,
		}
	end
	return items
end

-- Module-declared toggles only (mod.toggles): a class never sees an
-- option its module doesn't support.
local CLASS_MENU_TOGGLES = {
	{ key = "resolveGuardians", text = L["Name Guardian Spells"],
		get = function(cm) return cm.resolveGuardians ~= false end,
		flip = function(cm) return not (cm.resolveGuardians ~= false) end },
}

local function buildClassMenu()
	local prof = ZSBT.db and ZSBT.db.profile or {}
	local items = {}
	for _, def in ipairs(CLASS_MENU_TOGGLES) do
		if ZSBT.ClassDB and ZSBT.ClassDB.SupportsToggle
			and ZSBT.ClassDB.SupportsToggle(def.key) then
			items[#items + 1] = {
				text = def.text,
				isNotRadio = true,
				checked = function()
					local c = prof.classModule or {}
					return def.get(c)
				end,
				func = function()
					prof.classModule = prof.classModule or {}
					prof.classModule[def.key] = def.flip(prof.classModule)
					notifyConfig()
					refreshActiveDropDown()
				end,
				keepShownOnClick = true,
			}
		end
	end
	-- Always offer a way into the class page: modules with no toggles
	-- (warrior) still have knowledge + spell teaching there.
	items[#items + 1] = {
		text = L["Open Class Module"],
		isNotRadio = true,
		func = function()
			local shell = ZSBT.ConfigShell
			if shell and shell.Open then
				shell:Open()
				if shell.ShowPage then shell:ShowPage("class") end
			end
		end,
	}
	return items
end

local function showMenu(anchor, which)
	if not anchor or not which then return end
	if not QuickBar._dropDown then return end
	QuickBar._activeMenu = which
	if ToggleDropDownMenu then
		ToggleDropDownMenu(1, nil, QuickBar._dropDown, anchor, 0, 0)
	end
end

local function updateUnlockButtonText()
	if not QuickBar._btnUnlock then return end
	if ZSBT.IsScrollAreasUnlocked and ZSBT.IsScrollAreasUnlocked() then
		QuickBar._btnUnlock:SetText(L["Lock"])
	else
		QuickBar._btnUnlock:SetText(L["Unlock"])
	end
end

function QuickBar:ResetPosition()
	local g = getGeneral()
	if not g then return end
	ensurePositionDefaults(g)
	g.quickControlBarPos.x = 0
	g.quickControlBarPos.y = 220
	if self._frame then
		applyPosition(self._frame)
	end
end

function QuickBar:RefreshVisibility()
	if not self._frame then return end
	if isEnabled() then
		self._frame:Show()
	else
		self._frame:Hide()
	end
end

function QuickBar:Init()
	if self._frame then
		self:RefreshVisibility()
		updateUnlockButtonText()
		return
	end

	self._dropDown = CreateFrame("Frame", "ZSBT_QuickControlBarMenu", UIParent, "UIDropDownMenuTemplate")
	UIDropDownMenu_Initialize(self._dropDown, function(_, level)
		if level ~= 1 then return end
		local which = QuickBar._activeMenu
		local menu = nil
		if which == "outgoing" then
			menu = buildOutgoingMenu()
		elseif which == "class" then
			menu = buildClassMenu()
		end
		if type(menu) ~= "table" then return end
		for _, item in ipairs(menu) do
			UIDropDownMenu_AddButton(item, level)
		end
	end, "MENU")

	local f = CreateFrame("Frame", "ZSBT_QuickControlBar", UIParent, "BackdropTemplate")
	f:SetSize(280, 28)
	f:SetFrameStrata("DIALOG")
	f:SetFrameLevel(50)
	f:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	f:SetBackdropColor(0, 0, 0, 0.55)
	f:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.9)

	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")

	local _pendingSavePos = false
	f:SetScript("OnDragStart", function(self)
		if InCombatLockdown() then return end
		self:StartMoving()
	end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		if InCombatLockdown() then
			-- Defer position save until combat ends so ClearAllPoints is not
			-- called during lockdown on a child of a potentially protected ancestor.
			_pendingSavePos = true
			return
		end
		savePosition(self)
		notifyConfig()
	end)
	-- Flush any deferred position save once combat unlocks.
	f:RegisterEvent("PLAYER_REGEN_ENABLED")
	f:SetScript("OnEvent", function(self, event)
		if event == "PLAYER_REGEN_ENABLED" and _pendingSavePos then
			_pendingSavePos = false
			savePosition(self)
			notifyConfig()
		end
	end)

	local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("LEFT", f, "LEFT", 6, 0)
	label:SetText("ZSBT")
	f:SetScript("OnEnter", function()
		GameTooltip:SetOwner(f, "ANCHOR_TOP")
		GameTooltip:SetText(L["ZSBT - Quick Control Bar"])
		GameTooltip:AddLine(L["Drag to move."], 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	f:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

	local btnOutgoing = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	btnOutgoing:SetSize(80, 22)
	btnOutgoing:SetPoint("LEFT", label, "RIGHT", 6, 0)
	btnOutgoing:SetText(L["Outgoing"])
	btnOutgoing:SetScript("OnClick", function()
		showMenu(btnOutgoing, "outgoing")
	end)
	btnOutgoing:SetScript("OnEnter", function()
		GameTooltip:SetOwner(btnOutgoing, "ANCHOR_TOP")
		GameTooltip:SetText(L["ZSBT - Outgoing Ownership"])
		GameTooltip:AddLine(L["Quick toggle outgoing ownership options."], 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	btnOutgoing:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

	-- Class-module button: labeled with the player's class, visible when
	-- a class module is loaded. The menu holds the module's toggles plus
	-- an "Open Class Module" shortcut, so even a module with no toggles
	-- (warrior) gets a button — its knowledge/teaching page still exists.
	local cdb = ZSBT.ClassDB
	local classMod = cdb and cdb.ActiveModule and cdb.ActiveModule()
	-- Stub modules (registered placeholders with no data) don't get a
	-- button — there's nothing to toggle and the page is covered anyway.
	local classModActive = classMod ~= nil and classMod._stub ~= true
	local btnAnchor = btnOutgoing
	if classModActive then
		local _, className = UnitClass("player")
		local btnClass = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		btnClass:SetSize(80, 22)
		btnClass:SetPoint("LEFT", btnOutgoing, "RIGHT", 4, 0)
		btnClass:SetText(className or L["Class"])
		btnClass:SetScript("OnClick", function()
			showMenu(btnClass, "class")
		end)
		btnClass:SetScript("OnEnter", function()
			GameTooltip:SetOwner(btnClass, "ANCHOR_TOP")
			GameTooltip:SetText(L["ZSBT - Class Module"])
			GameTooltip:AddLine(L["Quick toggle class-module attribution tweaks."], 0.8, 0.8, 0.8, true)
			GameTooltip:Show()
		end)
		btnClass:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
		btnAnchor = btnClass
	end

	local btnUnlock = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	btnUnlock:SetSize(60, 22)
	btnUnlock:SetPoint("LEFT", btnAnchor, "RIGHT", 4, 0)
	btnUnlock:SetText(L["Unlock"])
	btnUnlock:SetScript("OnClick", function()
		if ZSBT.IsScrollAreasUnlocked and ZSBT.IsScrollAreasUnlocked() then
			if ZSBT.HideScrollAreaFrames then
				ZSBT.HideScrollAreaFrames()
			end
		else
			if ZSBT.ShowScrollAreaFrames then
				ZSBT.ShowScrollAreaFrames()
			end
		end
		updateUnlockButtonText()
		notifyConfig()
	end)
	btnUnlock:SetScript("OnEnter", function()
		GameTooltip:SetOwner(btnUnlock, "ANCHOR_TOP")
		GameTooltip:SetText(L["ZSBT - Scroll Areas"])
		GameTooltip:AddLine(L["Unlock/lock scroll areas for dragging."], 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	btnUnlock:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

	self._frame = f
	self._btnUnlock = btnUnlock
	self._label = label

	local g = getGeneral()
	if g then
		ensurePositionDefaults(g)
	end
	applyPosition(f)
	updateUnlockButtonText()
	self:RefreshVisibility()
end
