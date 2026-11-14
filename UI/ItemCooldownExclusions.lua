------------------------------------------------------------------------
-- ZSBT - Item Cooldown Exclusions Window
--
-- Drag-and-drop only management for profile.itemCooldownExclusions.
-- Layout: drop zone on top, then two fixed panes — "Recently Used" on
-- the left (click + to exclude) and "Excluded" on the right (click X
-- to remove). Scrollbars are mousewheel-only so rows never sit under
-- a scrollbar.
--
-- Storage keys: "i<itemID>" for resolved items, "n<lowercase name>"
-- for names that could not be resolved to an ID.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

local L = ZSBT.L

local ROW_HEIGHT = 22
local PANE_HEIGHT = 14 * (ROW_HEIGHT + 2)
local PANE_WIDTH = 260

local function exclusions()
	ZSBT.db.profile.itemCooldownExclusions = ZSBT.db.profile.itemCooldownExclusions or {}
	return ZSBT.db.profile.itemCooldownExclusions
end

local function sortedKeys()
	local keys = {}
	for k in pairs(exclusions()) do
		if type(k) == "string" then table.insert(keys, k) end
	end
	table.sort(keys)
	return keys
end

local function itemDisplay(itemID)
	local name, icon
	if C_Item and C_Item.GetItemInfo then
		local ok, n, _, _, _, _, _, _, _, ic = pcall(C_Item.GetItemInfo, itemID)
		if ok then name, icon = n, ic end
	end
	return name or ("Item #" .. tostring(itemID)), icon
end

local function keyToDisplay(k)
	local idStr = k:match("^i(%d+)$")
	if idStr then
		return itemDisplay(tonumber(idStr))
	end
	local nm = k:match("^n(.+)$")
	if nm then
		return nm, nil
	end
	return k, nil
end

------------------------------------------------------------------------
-- Row factory — icon, name, and an action button on the right.
------------------------------------------------------------------------
local function makeRow(content, i)
	local row = CreateFrame("Button", nil, content, "BackdropTemplate")
	row:SetSize(PANE_WIDTH - 12, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -6 - (i - 1) * (ROW_HEIGHT + 2))
	row:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 0,
	})
	row:SetBackdropColor(1, 1, 1, 0.06)

	local icon = row:CreateTexture(nil, "ARTWORK")
	icon:SetSize(16, 16)
	icon:SetPoint("LEFT", row, "LEFT", 6, 0)

	local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	nameText:SetPoint("LEFT", icon, "RIGHT", 6, 0)
	nameText:SetJustifyH("LEFT")
	nameText:SetWidth(PANE_WIDTH - 80)

	local action = CreateFrame("Button", nil, row, "BackdropTemplate")
	action:SetSize(20, 20)
	action:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	action:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	action:SetBackdropColor(0.4, 0.1, 0.1, 0.6)
	action:SetBackdropBorderColor(0.8, 0.3, 0.3, 0.8)
	local actionText = action:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	actionText:SetPoint("CENTER", 0, -1)
	action.text = actionText

	row.icon = icon
	row.nameText = nameText
	row.action = action
	return row
end

local function fillRow(row, name, icon)
	row.nameText:SetText(name)
	if icon then
		row.icon:SetTexture(icon)
	else
		row.icon:SetColorTexture(0.3, 0.3, 0.3, 1)
	end
end

local function styleAction(row, r, g, b, rr, gg, bb, text, enabled)
	row.action.text:SetText(text)
	row.action:SetBackdropColor(r, g, b, 0.6)
	row.action:SetBackdropBorderColor(rr, gg, bb, 0.8)
	row.action:EnableMouse(enabled ~= false)
end

------------------------------------------------------------------------
-- Pane population (mutually recursive — forward declared)
------------------------------------------------------------------------
local refreshExcluded, refreshRecent

refreshExcluded = function(win)
	local keys = sortedKeys()
	local content = win.exclContent
	for i, k in ipairs(keys) do
		local row = content.rows[i]
		if not row then
			row = makeRow(content, i)
			row.action:SetScript("OnClick", function()
				if row.key then
					exclusions()[row.key] = nil
					refreshExcluded(win)
					refreshRecent(win)
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end
			end)
			row.action:SetScript("OnEnter", function() row.action:SetBackdropColor(0.6, 0.15, 0.15, 0.9) end)
			row.action:SetScript("OnLeave", function() row.action:SetBackdropColor(0.4, 0.1, 0.1, 0.6) end)
			row:SetScript("OnClick", function(_, button)
				if button == "RightButton" and row.key then
					exclusions()[row.key] = nil
					refreshExcluded(win)
					refreshRecent(win)
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end
			end)
			styleAction(row, 0.4, 0.1, 0.1, 0.8, 0.3, 0.3, "|cFFFF5555X|r")
			content.rows[i] = row
		end

		local name, icon = keyToDisplay(k)
		row.key = k
		fillRow(row, name, icon)
		row:Show()
	end
	for i = #keys + 1, #content.rows do
		content.rows[i]:Hide()
	end
	content:SetHeight(math.max(PANE_HEIGHT, 6 + #keys * (ROW_HEIGHT + 2)))
	if win.exclEmpty then
		win.exclEmpty:SetShown(#keys == 0)
	end
	if win.exclCount then
		win.exclCount:SetText(#keys .. " excluded")
	end
end

refreshRecent = function(win)
	local ic = ZSBT.ItemCooldowns
	local recent = ic and ic.GetRecentItemIDs and ic:GetRecentItemIDs() or {}
	local ex = exclusions()
	local content = win.recentContent
	for i, entry in ipairs(recent) do
		local row = content.rows[i]
		if not row then
			row = makeRow(content, i)
			row.action:SetScript("OnClick", function()
				if row.itemID then
					exclusions()["i" .. tostring(row.itemID)] = true
					refreshExcluded(win)
					refreshRecent(win)
					LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
				end
			end)
			row.action:SetScript("OnEnter", function() row.action:SetBackdropColor(0.15, 0.5, 0.15, 0.9) end)
			row.action:SetScript("OnLeave", function()
				row.action:SetBackdropColor(0.1, 0.3, 0.1, 0.6)
			end)
			content.rows[i] = row
		end

		local itemID = entry.id
		local name, icon = itemDisplay(itemID)
		row.itemID = itemID
		fillRow(row, name, icon)
		local isEx = ex["i" .. tostring(itemID)] == true
		if isEx then
			styleAction(row, 0.2, 0.2, 0.2, 0.4, 0.4, 0.4, "|cFF888888- |r", false)
		else
			styleAction(row, 0.1, 0.3, 0.1, 0.3, 0.6, 0.3, "|cFF55FF55+ |r")
		end
		row:Show()
	end
	for i = #recent + 1, #content.rows do
		content.rows[i]:Hide()
	end
	content:SetHeight(math.max(PANE_HEIGHT, 6 + #recent * (ROW_HEIGHT + 2)))
	if win.recentEmpty then
		win.recentEmpty:SetShown(#recent == 0)
	end
end

local function refreshAll(win)
	refreshExcluded(win)
	refreshRecent(win)
end

local function wireScroll(win, scroll)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local v1, v2 = self:GetVerticalScrollRange()
		local min, max = 0, 0
		if type(v2) == "number" then
			min, max = v1, v2
		elseif type(v1) == "number" then
			max = v1
		end
		local cur = self:GetVerticalScroll() or 0
		self:SetVerticalScroll(math.max(min, math.min(max, cur - delta * 30)))
	end)
	return scroll
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------
function ZSBT.OpenItemCooldownExclusions()
	if ZSBT._icExclWin then
		if ZSBT._icExclWin:IsShown() then
			ZSBT._icExclWin:Hide()
		else
			refreshAll(ZSBT._icExclWin)
			ZSBT._icExclWin:Show()
		end
		return
	end

	local accent = ZSBT.COLORS and ZSBT.COLORS.ACCENT or { r = 0.4, g = 0.7, b = 1 }
	local dk = ZSBT.COLORS and ZSBT.COLORS.DARK or { r = 0.1, g = 0.1, b = 0.12 }

	local win = CreateFrame("Frame", "ZSBT_ItemCooldownExclusions", UIParent, "BackdropTemplate")
	win:SetSize(600, 200 + 30 + PANE_HEIGHT)
	win:SetPoint("CENTER")
	win:SetFrameStrata("DIALOG")
	win:SetMovable(true)
	win:EnableMouse(true)
	win:RegisterForDrag("LeftButton")
	win:SetScript("OnDragStart", win.StartMoving)
	win:SetScript("OnDragStop", win.StopMovingOrSizing)
	win:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	win:SetBackdropColor(dk.r, dk.g, dk.b, 0.95)
	win:SetBackdropBorderColor(accent.r, accent.g, accent.b, 0.8)

	-- Title
	local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", win, "TOP", 0, -10)
	title:SetText(L["Item Cooldown Exclusions"])

	-- Close button
	local closeBtn = CreateFrame("Button", nil, win)
	closeBtn:SetSize(20, 20)
	closeBtn:SetPoint("TOPRIGHT", win, "TOPRIGHT", -8, -8)
	local closeText = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	closeText:SetPoint("CENTER")
	closeText:SetText("|cFFFF6666X|r")
	closeBtn:SetScript("OnClick", function() win:Hide() end)
	closeBtn:SetScript("OnEnter", function() closeText:SetTextColor(1, 0.4, 0.4) end)
	closeBtn:SetScript("OnLeave", function() closeText:SetTextColor(1, 1, 1) end)

	-- Drop zone (full width)
	local drop = CreateFrame("Button", nil, win, "BackdropTemplate")
	drop:SetSize(560, 40)
	drop:SetPoint("TOP", win, "TOP", 0, -36)
	drop:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	drop:SetBackdropColor(0.15, 0.15, 0.18, 1)
	drop:SetBackdropBorderColor(accent.r, accent.g, accent.b, 0.5)
	drop:SetScript("OnReceiveDrag", function()
		local cursorType, id = GetCursorInfo()
		if cursorType ~= "item" or type(id) ~= "number" or id <= 0 then return end
		local key = "i" .. tostring(math.floor(id))
		if not exclusions()[key] then
			exclusions()[key] = true
			refreshAll(win)
			LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
		end
		ClearCursor()
	end)
	drop:SetScript("OnMouseUp", function(self, button)
		if button == "LeftButton" then
			local cursorType, id = GetCursorInfo()
			if cursorType == "item" and id and id > 0 then
				self:GetScript("OnReceiveDrag")(self)
			end
		end
	end)
	local dropText = drop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	dropText:SetPoint("CENTER")
	dropText:SetText(L["|cFF00CC66[ Drag Item Here To Exclude ]|r"])

	-- Left pane: Recently Used
	local leftPane = CreateFrame("Frame", nil, win)
	leftPane:SetSize(PANE_WIDTH + 20, 30 + PANE_HEIGHT)
	leftPane:SetPoint("TOPLEFT", drop, "BOTTOMLEFT", -10, -12)

	local recentHeader = leftPane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	recentHeader:SetPoint("TOPLEFT", leftPane, "TOPLEFT", 10, 0)
	recentHeader:SetText(L["|cFFFFFFFFRecently Used|r"])

	local recentScroll = wireScroll(win, CreateFrame("ScrollFrame", nil, leftPane))
	recentScroll:SetPoint("TOPLEFT", recentHeader, "BOTTOMLEFT", 0, -4)
	recentScroll:SetPoint("BOTTOMLEFT", leftPane, "BOTTOMLEFT", 0, 0)
	recentScroll:SetWidth(PANE_WIDTH)

	local recentContent = CreateFrame("Frame", nil, recentScroll)
	recentContent:SetSize(PANE_WIDTH, PANE_HEIGHT)
	recentScroll:SetScrollChild(recentContent)
	recentContent.rows = {}
	win.recentContent = recentContent

	local recentEmpty = leftPane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	recentEmpty:SetPoint("TOP", recentScroll, "TOP", 0, -60)
	recentEmpty:SetPoint("LEFT", recentScroll, "LEFT", 0, 0)
	recentEmpty:SetPoint("RIGHT", recentScroll, "RIGHT", 0, 0)
	recentEmpty:SetJustifyH("CENTER")
	recentEmpty:SetText(L["|cFF888888No item cooldowns seen yet.|r"])
	win.recentEmpty = recentEmpty

	-- Right pane: Excluded
	local rightPane = CreateFrame("Frame", nil, win)
	rightPane:SetSize(PANE_WIDTH + 20, 30 + PANE_HEIGHT)
	rightPane:SetPoint("TOPRIGHT", drop, "BOTTOMRIGHT", 10, -12)

	local exclHeader = rightPane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	exclHeader:SetPoint("TOPLEFT", rightPane, "TOPLEFT", 10, 0)
	exclHeader:SetText(L["|cFFFFFFFFExcluded|r"])
	local exclCount = rightPane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	exclCount:SetPoint("LEFT", exclHeader, "RIGHT", 8, 0)
	win.exclCount = exclCount

	local exclScroll = wireScroll(win, CreateFrame("ScrollFrame", nil, rightPane))
	exclScroll:SetPoint("TOPLEFT", exclHeader, "BOTTOMLEFT", 0, -4)
	exclScroll:SetPoint("BOTTOMLEFT", rightPane, "BOTTOMLEFT", 0, 0)
	exclScroll:SetWidth(PANE_WIDTH)

	local exclContent = CreateFrame("Frame", nil, exclScroll)
	exclContent:SetSize(PANE_WIDTH, PANE_HEIGHT)
	exclScroll:SetScrollChild(exclContent)
	exclContent.rows = {}
	win.exclContent = exclContent

	local exclEmpty = rightPane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	exclEmpty:SetPoint("TOP", exclScroll, "TOP", 0, -60)
	exclEmpty:SetPoint("LEFT", exclScroll, "LEFT", 0, 0)
	exclEmpty:SetPoint("RIGHT", exclScroll, "RIGHT", 0, 0)
	exclEmpty:SetJustifyH("CENTER")
	exclEmpty:SetText(L["|cFF888888No excluded items.|r"])
	win.exclEmpty = exclEmpty

	win:SetScript("OnHide", function()
		ClearCursor()
	end)

	ZSBT._icExclWin = win
	refreshAll(win)
	win:Show()
end
