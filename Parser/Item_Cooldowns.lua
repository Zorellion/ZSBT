------------------------------------------------------------------------
-- ZSBT - Item Cooldown Alerts
--
-- Tracks items the player uses (action bar, equipment slots, bags, item
-- links) and scrolls a notification when the item's cooldown finishes —
-- the "Onyxia head is ready" style alert.
--
-- Detection mirrors MSBT: hook the use APIs, record the itemID, then poll
-- C_Container.GetItemCooldown after a short delay. Cooldown values may be
-- secret on modern clients; when unreadable we fall back to a countdown
-- from the last known duration.
--
-- Emits through Core:EmitNotificationTemplate with category "itemCooldowns".
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

local IC = {}
ZSBT.ItemCooldowns = IC

IC._watched = {}   -- itemID -> time the use was recorded
IC._active = {}    -- itemID -> last known remaining seconds (fallback)
IC._recent = {}    -- itemID -> last seen use time (for exclusion suggestions)
IC._frame = nil
IC._elapsed = 0
IC._verbose = false
IC._dbgLastPrint = 0

local function icDbg(msg)
	if IC._verbose ~= true then return end
	local Addon = ZSBT and ZSBT.Addon
	if Addon and Addon.Print then
		local t = GetTime()
		if t - IC._dbgLastPrint >= 0.15 then
			IC._dbgLastPrint = t
			Addon:Print("ICDBG " .. msg)
		end
	end
end

local WATCH_DELAY = 1.0     -- wait before reading the cooldown (cast lands first)
local UPDATE_INTERVAL = 0.1
local MAX_WATCHED = 32

local function normNum(v)
	if type(v) ~= "number" then return nil end
	if ZSBT.IsSafeNumber and not ZSBT.IsSafeNumber(v) then return nil end
	return v
end

local function itemNameFor(itemID)
	if C_Item and C_Item.GetItemInfo then
		local ok, name = pcall(C_Item.GetItemInfo, itemID)
		if ok and ZSBT.IsSafeString and ZSBT.IsSafeString(name) and name ~= "" then
			return name
		end
	end
	return nil
end

local function isExcluded(itemID)
	local ex = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.itemCooldownExclusions
	if type(ex) ~= "table" then return false end
	if ex["i" .. itemID] then return true end
	local name = itemNameFor(itemID)
	if name and ex["n" .. name:lower()] then return true end
	return false
end

local function recordUse(itemID)
	icDbg(("use itemID=%s"):format(tostring(itemID)))
	if type(itemID) ~= "number" or itemID <= 0 then return end
	-- Remember every detected use so the exclusions UI can suggest items.
	local recent = IC._recent
	recent[itemID] = GetTime()
	local rcount = 0
	for _ in pairs(recent) do rcount = rcount + 1 end
	if rcount > 64 then
		local oldestID, oldestT = nil, math.huge
		for id, t in pairs(recent) do
			if t < oldestT then oldestID, oldestT = id, t end
		end
		if oldestID then recent[oldestID] = nil end
	end
	if isExcluded(itemID) then
		icDbg(("excluded itemID=%s"):format(tostring(itemID)))
		return
	end
	local Core = ZSBT.Core
	local master = Core and Core.IsMasterEnabled and Core:IsMasterEnabled() == true
	local cat = Core and Core.IsNotificationCategoryEnabled and Core:IsNotificationCategoryEnabled("itemCooldowns") == true
	if not (master and cat) then
		icDbg(("gate master=%s cat=%s"):format(tostring(master), tostring(cat)))
		return
	end
	local w = IC._watched
	if w[itemID] == nil then
		local count = 0
		for _ in pairs(w) do count = count + 1 end
		if count >= MAX_WATCHED then return end
	end
	w[itemID] = GetTime()
	icDbg(("record itemID=%s watched=%d"):format(tostring(itemID), (function() local n=0 for _ in pairs(w) do n=n+1 end return n end)()))
	IC:_ensureFrame()
end

function IC:_ensureFrame()
	if self._frame then
		self._frame:Show()
		return
	end
	self._frame = CreateFrame("Frame")
	self._frame:Hide()
	self._frame:SetScript("OnUpdate", function(_, elapsed)
		IC:_tick(elapsed)
	end)
end

function IC:_startCooldown(itemID)
	local startTime, duration = nil, nil
	if C_Container and C_Container.GetItemCooldown then
		local ok, s, d = pcall(C_Container.GetItemCooldown, itemID)
		if ok then startTime, duration = s, d end
	end
	startTime = normNum(startTime)
	duration = normNum(duration)
	icDbg(("cd itemID=%s start=%s dur=%s"):format(tostring(itemID), tostring(startTime), tostring(duration)))
	if duration and duration > 0 then
		self._active[itemID] = duration
		self:_ensureFrame()
		return true
	end
	return false
end

function IC:GetRecentItemIDs()
	local list = {}
	for id, t in pairs(self._recent or {}) do
		list[#list + 1] = { id = id, t = t }
	end
	table.sort(list, function(a, b) return a.t > b.t end)
	return list
end

function IC:_displayReady(itemID)
	local name = itemNameFor(itemID)
	if not name then return end
	local Core = ZSBT.Core
	if Core and Core.EmitNotificationTemplate then
		Core:EmitNotificationTemplate("itemCooldowns", "%e is ready", { e = name },
			{ r = 0.4, g = 1.0, b = 0.5 })
	end
end

function IC:_tick(elapsed)
	self._elapsed = self._elapsed + (elapsed or UPDATE_INTERVAL)
	if self._elapsed < UPDATE_INTERVAL then return end
	self._elapsed = 0

	local now = GetTime()
	for itemID, usedAt in pairs(self._watched) do
		if now - usedAt >= WATCH_DELAY then
			self._watched[itemID] = nil
			self:_startCooldown(itemID)
		end
	end

	for itemID, remaining in pairs(self._active) do
		local startTime, duration = nil, nil
		if C_Container and C_Container.GetItemCooldown then
			local ok, s, d = pcall(C_Container.GetItemCooldown, itemID)
			if ok then startTime, duration = s, d end
		end
		startTime = normNum(startTime)
		duration = normNum(duration)
		-- Prefer the live cooldown read; when values are secret/unreadable,
		-- fall back to counting down the last known remaining time.
		local rem
		if startTime and duration then
			rem = startTime + duration - now
		else
			rem = remaining - UPDATE_INTERVAL
		end
		if rem <= 0 then
			self._active[itemID] = nil
			icDbg(("ready itemID=%s name=%s"):format(tostring(itemID), tostring(itemNameFor(itemID))))
			self:_displayReady(itemID)
		else
			self._active[itemID] = rem
		end
	end

	if not next(self._watched) and not next(self._active) then
		self._frame:Hide()
	end
end

------------------------------------------------------------------------
-- Use hooks — record the itemID for every supported use path.
------------------------------------------------------------------------
local function hookUseAction(slot)
	if type(GetActionInfo) ~= "function" then return end
	local ok, atype, itemID = pcall(GetActionInfo, slot)
	if ok and atype == "item" then
		recordUse(itemID)
	end
end

local function hookUseInventoryItem(slot)
	if type(GetInventoryItemID) ~= "function" then return end
	local ok, itemID = pcall(GetInventoryItemID, "player", slot)
	if ok then recordUse(itemID) end
end

local function hookUseContainerItem(bag, slot)
	if not (C_Container and C_Container.GetContainerItemID) then return end
	local ok, itemID = pcall(C_Container.GetContainerItemID, bag, slot)
	if ok then recordUse(itemID) end
end

local function hookUseItemByName(itemName)
	if type(itemName) ~= "string" or itemName == "" then return end
	if not (GetItemInfo and type(GetItemInfo) == "function") then return end
	local ok, _, itemLink = pcall(GetItemInfo, itemName)
	if not ok or type(itemLink) ~= "string" then return end
	local itemID = tonumber(itemLink:match("item:(%d+)"))
	recordUse(itemID)
end

------------------------------------------------------------------------
-- BAG_UPDATE_COOLDOWN fallback — secure action buttons bypass the Lua
-- use-functions on modern clients, so hook coverage alone misses most
-- real uses. When a bag cooldown update arrives, scan that bag (and the
-- equipped slots) for a cooldown that just started; that slot's item is
-- the one that was used. The event is infrequent enough to scan inline.
------------------------------------------------------------------------

local function justStarted(startTime, now)
	startTime = normNum(startTime)
	if not startTime then return false end
	return startTime >= now - 1.5 and startTime <= now + 0.25
end

local function scanAllBagsForNewCooldown()
	if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemID) then return end
	-- Retail reports bag=nil on BAG_UPDATE_COOLDOWN; scan every bag slot.
	for bag = 0, 10 do
		local okN, numSlots = pcall(C_Container.GetContainerNumSlots, bag)
		if okN and type(numSlots) == "number" and numSlots > 0 then
			for slot = 1, numSlots do
				local okID, itemID = pcall(C_Container.GetContainerItemID, bag, slot)
				if okID and type(itemID) == "number" and itemID > 0 then
					local s, d
					if C_Container.GetContainerItemCooldown then
						local okCD, cs, cd = pcall(C_Container.GetContainerItemCooldown, bag, slot)
						if okCD then s, d = cs, cd end
					end
					if s == nil and GetContainerItemCooldown then
						local okCD, gs, gd = pcall(GetContainerItemCooldown, bag, slot)
						if okCD then s, d = gs, gd end
					end
					s = normNum(s); d = normNum(d)
					if s and d and d > 0 and justStarted(s, GetTime()) then
						icDbg(("bagscan bag=%s slot=%s itemID=%s dur=%s"):format(tostring(bag), tostring(slot), tostring(itemID), tostring(d)))
						recordUse(itemID)
					end
				end
			end
		end
	end
end

local function scanEquipForNewCooldown()
	if type(GetInventoryItemID) ~= "function" then return end
	local now = GetTime()
	for slot = 1, 20 do
		local okID, itemID = pcall(GetInventoryItemID, "player", slot)
		if okID and type(itemID) == "number" and itemID > 0 then
			local s, d
			if C_Container and C_Container.GetInventoryItemCooldown then
				local okCD, is_, id_ = pcall(C_Container.GetInventoryItemCooldown, "player", slot)
				if okCD then s, d = is_, id_ end
			end
			if s == nil and GetInventoryItemCooldown then
				local okCD, gs, gd = pcall(GetInventoryItemCooldown, "player", slot)
				if okCD then s, d = gs, gd end
			end
			s = normNum(s); d = normNum(d)
			if s and d and d > 0 and justStarted(s, now) then
				icDbg(("equipscan slot=%s itemID=%s dur=%s"):format(tostring(slot), tostring(itemID), tostring(d)))
				recordUse(itemID)
			end
		end
	end
end

IC._bagScanPending = false
IC._bagScanElapsed = 0
IC._bagFrame = CreateFrame("Frame")
IC._bagFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
IC._bagEvents = 0
IC._bagFrame:SetScript("OnEvent", function(_, _, bag)
	IC._bagEvents = IC._bagEvents + 1
	icDbg(("BAG_UPDATE_COOLDOWN #%d bag=%s"):format(IC._bagEvents, tostring(bag)))
	IC._bagScanPending = true
end)
IC._bagFrame:SetScript("OnUpdate", function(_, elapsed)
	if not IC._bagScanPending then return end
	IC._bagScanElapsed = IC._bagScanElapsed + (elapsed or 0)
	if IC._bagScanElapsed < 0.25 then return end
	IC._bagScanElapsed = 0
	IC._bagScanPending = false
	scanAllBagsForNewCooldown()
	scanEquipForNewCooldown()
end)

IC._hookLog = {}

local function tryHook(label, t, name, fn)
	local ok = false
	if type(t) == "table" and type(t[name]) == "function" then
		ok = pcall(hooksecurefunc, t, name, fn) == true
	elseif type(t) == "string" and type(_G[t]) == "function" then
		ok = pcall(hooksecurefunc, t, fn) == true
	end
	IC._hookLog[#IC._hookLog + 1] = label .. "=" .. tostring(ok)
end

if hooksecurefunc then
	tryHook("UseAction", "UseAction", nil, hookUseAction)
	tryHook("UseInventoryItem", "UseInventoryItem", nil, hookUseInventoryItem)
	tryHook("C_Container.UseContainerItem", C_Container, "UseContainerItem", hookUseContainerItem)
	tryHook("UseItemByName", "UseItemByName", nil, hookUseItemByName)
	tryHook("C_Item.UseItemByName", C_Item, "UseItemByName", hookUseItemByName)
	tryHook("C_Item.UseItemByID", C_Item, "UseItemByID", function(itemID)
		recordUse(itemID)
	end)
	tryHook("C_Container.UseItem", C_Container, "UseItem", function(bag, slot)
		if C_Container and C_Container.GetContainerItemID then
			local okI, itemID = pcall(C_Container.GetContainerItemID, bag, slot)
			if okI then recordUse(itemID) end
		end
	end)
end

return IC
