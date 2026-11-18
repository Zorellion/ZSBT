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

local function updateUnlockButtonText()
	if not QuickBar._btnUnlock then return end
	if ZSBT.IsScrollAreasUnlocked and ZSBT.IsScrollAreasUnlocked() then
		QuickBar._btnUnlock:SetText(L["Lock"])
	else
		QuickBar._btnUnlock:SetText(L["Unlock"])
	end
end

local function strictOutgoingOn()
	local g = getGeneral()
	return g and g.strictOutgoingAlways == true
end

local function updateStrictButton()
	local btn = QuickBar._btnStrict
	if not btn then return end
	local fs = btn.Text or btn.GetFontString and btn:GetFontString()
	if not fs then return end
	if strictOutgoingOn() then
		fs:SetTextColor(0.2, 1.0, 0.2)
	else
		fs:SetTextColor(0.8, 0.8, 0.8)
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
		updateStrictButton()
		return
	end

	local f = CreateFrame("Frame", "ZSBT_QuickControlBar", UIParent, "BackdropTemplate")
	f:SetSize(185, 28)
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

	local btnUnlock = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	btnUnlock:SetSize(60, 22)
	btnUnlock:SetPoint("LEFT", label, "RIGHT", 6, 0)
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

	local btnStrict = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	btnStrict:SetSize(60, 22)
	btnStrict:SetPoint("LEFT", btnUnlock, "RIGHT", 6, 0)
	btnStrict:SetText(L["Strict"])
	btnStrict:SetScript("OnClick", function()
		local g = getGeneral()
		if not g then return end
		g.strictOutgoingAlways = not strictOutgoingOn()
		updateStrictButton()
		notifyConfig()
	end)
	btnStrict:SetScript("OnEnter", function()
		GameTooltip:SetOwner(btnStrict, "ANCHOR_TOP")
		GameTooltip:SetText(L["Strict Outgoing Detection"])
		GameTooltip:AddLine(L["Require proof before showing outgoing damage, even outside groups. Reduces foreign damage leaking into your scroll areas; may hide some of your own hits."], 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	btnStrict:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

	self._frame = f
	self._btnUnlock = btnUnlock
	self._btnStrict = btnStrict
	self._label = label

	local g = getGeneral()
	if g then
		ensurePositionDefaults(g)
	end
	applyPosition(f)
	updateUnlockButtonText()
	updateStrictButton()
	self:RefreshVisibility()
end
