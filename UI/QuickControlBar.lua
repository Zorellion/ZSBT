local ADDON_NAME, ZSBT = ...

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

local function setInstanceAware(val)
	local g = getGeneral()
	if not g then return end
	g.instanceAwareOutgoing = val and true or false
	if val ~= true then
		g.damageMeterOutgoingFallback = false
		g.damageMeterIncomingFallback = false
		g.autoAttackRestrictFallback = false
	end
	if ZSBT.Core and ZSBT.Core.UpdateInstanceState then
		ZSBT.Core:UpdateInstanceState(true)
	end
	notifyConfig()
end

local function setQuietOutgoing(val)
	local g = getGeneral()
	if not g then return end
	g.quietOutgoingWhenIdle = val and true or false
	if val ~= true then
		g.quietOutgoingAutoAttacks = false
		g.strictOutgoingCombatLogOnly = false
	end
	notifyConfig()
end

local function setPvPStrict(val)
	local g = getGeneral()
	if not g then return end
	g.pvpStrictEnabled = val and true or false
	if val ~= true then
		-- Parent off: clear dependents to match Instance menu behavior.
		g.pvpStrictDisableAutoAttackFallback = false
	end
	if ZSBT.Core and ZSBT.Core.UpdateInstanceState then
		ZSBT.Core:UpdateInstanceState(true)
	end
	notifyConfig()
end

local function toggleBool(key)
	local g = getGeneral()
	if not g then return end
	g[key] = not (g[key] == true)
	notifyConfig()
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

local function buildInstanceMenu()
	local g = getGeneral() or {}
	local parentOn = (g.instanceAwareOutgoing == true)
	return {
		{
			text = "Dungeon/Raid Aware Outgoing",
			checked = function() return g.instanceAwareOutgoing == true end,
			func = function()
				setInstanceAware(not (g.instanceAwareOutgoing == true))
				refreshActiveDropDown()
			end,
			keepShownOnClick = true,
		},
		{
			text = "Use Damage Meter Outgoing Fallback",
			isNotRadio = true,
			disabled = (not parentOn),
			checked = function() return g.damageMeterOutgoingFallback == true end,
			func = function() toggleBool("damageMeterOutgoingFallback") end,
			keepShownOnClick = true,
		},
		{
			text = "Use Damage Meter Incoming Damage Fallback",
			isNotRadio = true,
			disabled = (not parentOn),
			checked = function() return g.damageMeterIncomingFallback == true end,
			func = function() toggleBool("damageMeterIncomingFallback") end,
			keepShownOnClick = true,
		},
		{
			text = "Show Auto Attacks in Instances",
			isNotRadio = true,
			disabled = (not parentOn),
			checked = function() return g.autoAttackRestrictFallback == true end,
			func = function() toggleBool("autoAttackRestrictFallback") end,
			keepShownOnClick = true,
		},
	}
end

local function buildPvPMenu()
	local g = getGeneral() or {}
	local parentOn = (g.pvpStrictEnabled == true)
	return {
		{
			text = "PvP Strict Mode",
			checked = function() return g.pvpStrictEnabled == true end,
			func = function()
				setPvPStrict(not (g.pvpStrictEnabled == true))
				refreshActiveDropDown()
			end,
			keepShownOnClick = true,
		},
		{
			text = "Disable Auto-Attack Fallback",
			isNotRadio = true,
			disabled = (not parentOn),
			checked = function() return g.pvpStrictDisableAutoAttackFallback ~= false end,
			func = function()
				toggleBool("pvpStrictDisableAutoAttackFallback")
				refreshActiveDropDown()
			end,
			keepShownOnClick = true,
		},
	}
end

local function buildOpenWorldMenu()
	local g = getGeneral() or {}
	local parentOn = (g.quietOutgoingWhenIdle == true)
	return {
		{
			text = "Quiet Outgoing When Idle",
			checked = function() return g.quietOutgoingWhenIdle == true end,
			func = function()
				setQuietOutgoing(not (g.quietOutgoingWhenIdle == true))
				refreshActiveDropDown()
			end,
			keepShownOnClick = true,
		},
		{
			text = "Allow Auto Attacks While Quiet",
			isNotRadio = true,
			disabled = (not parentOn),
			checked = function() return g.quietOutgoingAutoAttacks == true end,
			func = function()
				toggleBool("quietOutgoingAutoAttacks")
				refreshActiveDropDown()
			end,
			keepShownOnClick = true,
		},
		{
			text = "Strict Outgoing (Combat Log Only)",
			isNotRadio = true,
			checked = function() return g.strictOutgoingCombatLogOnly == true end,
			func = function()
				toggleBool("strictOutgoingCombatLogOnly")
				refreshActiveDropDown()
			end,
			keepShownOnClick = true,
		},
	}
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
		QuickBar._btnUnlock:SetText("Lock")
	else
		QuickBar._btnUnlock:SetText("Unlock")
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
		if which == "instance" then
			menu = buildInstanceMenu()
		elseif which == "openworld" then
			menu = buildOpenWorldMenu()
		elseif which == "pvp" then
			menu = buildPvPMenu()
		end
		if type(menu) ~= "table" then return end
		for _, item in ipairs(menu) do
			UIDropDownMenu_AddButton(item, level)
		end
	end, "MENU")

	local f = CreateFrame("Frame", "ZSBT_QuickControlBar", UIParent, "BackdropTemplate")
	f:SetSize(346, 28)
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
	f:SetScript("OnDragStart", function(self)
		self:StartMoving()
	end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		savePosition(self)
		notifyConfig()
	end)

	local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("LEFT", f, "LEFT", 6, 0)
	label:SetText("ZSBT")
	f:SetScript("OnEnter", function()
		GameTooltip:SetOwner(f, "ANCHOR_TOP")
		GameTooltip:SetText("ZSBT - Quick Control Bar")
		GameTooltip:AddLine("Drag to move.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	f:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

	local btnInstance = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	btnInstance:SetSize(80, 22)
	btnInstance:SetPoint("LEFT", label, "RIGHT", 6, 0)
	btnInstance:SetText("Instance")
	btnInstance:SetScript("OnClick", function()
		showMenu(btnInstance, "instance")
	end)
	btnInstance:SetScript("OnEnter", function()
		GameTooltip:SetOwner(btnInstance, "ANCHOR_TOP")
		GameTooltip:SetText("ZSBT - Instance Control")
		GameTooltip:AddLine("Quick toggle dungeon/raid tuning options.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	btnInstance:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

	local btnWorld = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	btnWorld:SetSize(90, 22)
	btnWorld:SetPoint("LEFT", btnInstance, "RIGHT", 4, 0)
	btnWorld:SetText("Open World")
	btnWorld:SetScript("OnClick", function()
		showMenu(btnWorld, "openworld")
	end)
	btnWorld:SetScript("OnEnter", function()
		GameTooltip:SetOwner(btnWorld, "ANCHOR_TOP")
		GameTooltip:SetText("ZSBT - Open World Control")
		GameTooltip:AddLine("Quick toggle open-world tuning options.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	btnWorld:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

	local btnPvP = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	btnPvP:SetSize(50, 22)
	btnPvP:SetPoint("LEFT", btnWorld, "RIGHT", 4, 0)
	btnPvP:SetText("PvP")
	btnPvP:SetScript("OnClick", function()
		showMenu(btnPvP, "pvp")
	end)
	btnPvP:SetScript("OnEnter", function()
		GameTooltip:SetOwner(btnPvP, "ANCHOR_TOP")
		GameTooltip:SetText("ZSBT - PvP Control")
		GameTooltip:AddLine("Quick toggle PvP tuning options.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	btnPvP:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

	local btnUnlock = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	btnUnlock:SetSize(60, 22)
	btnUnlock:SetPoint("LEFT", btnPvP, "RIGHT", 4, 0)
	btnUnlock:SetText("Unlock")
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
		GameTooltip:SetText("ZSBT - Scroll Areas")
		GameTooltip:AddLine("Unlock/lock scroll areas for dragging.", 0.8, 0.8, 0.8, true)
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
