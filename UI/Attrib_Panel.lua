-- Attribution debug panel.
--
-- Live view of how every outgoing combat event was resolved: which spellId
-- it carried, whether that ID came from the event itself (EVENT), was
-- inferred from a recent cast (LAST_CAST), or stayed anonymous (NONE), plus
-- pet-routed hits. Colors encode the resolution source so misattribution is
-- visible at a glance during heavier-combat testing.
--
-- Toggle: /zsbt attrib   (or /zsbt attribpanel)
-- Debug UI: Debug Configuration -> Quick Actions -> "Attribution Panel"

local ADDON_NAME, ZSBT = ...

local Panel = {}
ZSBT.AttribPanel = Panel

Panel._entries = {}
Panel._MAX = 200
Panel._frame = nil
Panel._body = nil
Panel._title = nil
Panel._dirty = false
Panel._lastFlush = 0
Panel._copyBox = nil

local SOURCE_COLORS = {
	EVENT = "|cff7CFC7C",      -- green: spellId came on the event itself
	LAST_CAST = "|cff6C9BF5",  -- blue: inferred from a recent player cast
	NONE = "|cff999999",       -- gray: anonymous / rejected
	PET = "|cffF5A623",        -- orange: claimed by the pet stream
	SKIP = "|cffFF5555",       -- red: secret/empty event, not displayed
}

local KIND_COLORS = {
	damage = "|cffFFD100",
	heal = "|cff40FF50",
	miss = "|cffFF8040",
	pet = "|cffF5A623",
}

local function safeText(v)
	if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
	if type(v) == "string" and not tostring(v):find("Secret") then return v end
	return nil
end

local function fmtAmount(evt)
	if evt == nil then return "?" end
	if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(evt.amount) then
		return tostring(evt.amount)
	end
	local t = safeText(evt.amountText)
	if t then return t end
	return "<secret>"
end

local function spellLabel(spellId)
	if type(spellId) ~= "number" then return "-" end
	local name = nil
	if ZSBT.CleanSpellName then
		local ok, n = pcall(ZSBT.CleanSpellName, spellId)
		if ok then name = n end
	end
	if type(name) == "string" and name ~= "" then
		return name .. "|cff888888(" .. tostring(spellId) .. ")|r"
	end
	return "|cffAAAAAA" .. tostring(spellId) .. "|r"
end

local function clock()
	local t = GetTime and GetTime() or 0
	local h = math.floor(t / 3600) % 24
	local m = math.floor(t / 60) % 60
	local s = math.floor(t % 60)
	return ("%02d:%02d:%02d"):format(h, m, s)
end

-- Record one resolved outgoing event. Called from Outgoing_Probe after
-- spell resolution, before the secret/empty early-out so skipped events
-- are visible too.
function Panel:RecordOutgoing(evt, resolvedSpellID, spellSource)
	if type(evt) ~= "table" then return end
	local kind = tostring(evt.kind or "?")
	local src = tostring(spellSource or "NONE")
	local school = evt.schoolMask
	local parts = {
		"|cff666666" .. clock() .. "|r",
		(KIND_COLORS[kind] or "|cffffffff") .. kind:upper() .. "|r",
		spellLabel(resolvedSpellID),
		(SOURCE_COLORS[src] or SOURCE_COLORS.NONE) .. src .. "|r",
	}
	if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school) then
		parts[#parts + 1] = "|cff888888sch=" .. tostring(school) .. "|r"
	end
	if evt.isCrit == true then
		parts[#parts + 1] = "|cffFF5555CRIT|r"
	end
	if evt.isAuto == true then
		parts[#parts + 1] = "|cff888888auto|r"
	end
	local srcName = safeText(evt.amountSource)
	if srcName then
		parts[#parts + 1] = "|cff555555" .. srcName .. "|r"
	end
	parts[#parts + 1] = fmtAmount(evt)
	if evt.isSecret == true then
		parts[#parts + 1] = (SOURCE_COLORS.SKIP or "|cffFF5555") .. "SECRET-SKIP|r"
	elseif evt.rawPipeId == nil and evt.amount == nil and evt.amountText == nil then
		parts[#parts + 1] = (SOURCE_COLORS.SKIP or "|cffFF5555") .. "EMPTY-SKIP|r"
	end
	self:_push(table.concat(parts, "  "))
end

-- Record a pet-stream hit (PET_DAMAGE_COMBAT) as claimed by the pet path.
function Panel:RecordPet(sample)
	if type(sample) ~= "table" then return end
	local school = sample.schoolMask
	local parts = {
		"|cff666666" .. clock() .. "|r",
		(KIND_COLORS.pet or "|cffF5A623") .. "PET|r",
		(SOURCE_COLORS.PET or "|cffF5A623") .. "PET_STREAM|r",
		"|cffAAAAAA- |r",
	}
	if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(school) then
		parts[#parts + 1] = "|cff888888sch=" .. tostring(school) .. "|r"
	end
	if sample.isCrit == true then
		parts[#parts + 1] = "|cffFF5555CRIT|r"
	end
	if sample.petBucket then
		parts[#parts + 1] = "|cff888888" .. tostring(sample.petBucket) .. "|r"
	end
	parts[#parts + 1] = fmtAmount(sample)
	self:_push(table.concat(parts, "  "))
end

function Panel:_push(line)
	local entries = self._entries
	entries[#entries + 1] = line
	if #entries > self._MAX then
		table.remove(entries, 1)
	end
	self._dirty = true
end

local function flush(self)
	if not self._dirty then return end
	self._dirty = false
	local body = self._body
	if not body then return end
	local entries = self._entries
	local n = #entries
	if n == 0 then
		body:SetText("|cff888888(no outgoing events recorded yet)|r")
		return
	end
	-- Newest at bottom, like a combat log.
	local chunks = {}
	for i = n, math.max(1, n - 120), -1 do
		chunks[#chunks + 1] = entries[i]
	end
	body:SetText(table.concat(chunks, "\n"))
end

function Panel:_EnsureFrame()
	if self._frame then return self._frame end
	local f = CreateFrame("Frame", "ZSBT_AttribPanel", UIParent, "BackdropTemplate")
	f:SetSize(520, 340)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	f:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	f:SetBackdropColor(0, 0, 0, 0.82)
	f:SetBackdropBorderColor(0.4, 0.6, 1.0, 0.9)

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText("|cff6C9BF5ZSBT Attribution|r  |cff888888/zsbt attrib to toggle|r")
	self._title = title

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	local copyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	copyBtn:SetSize(64, 20)
	copyBtn:SetPoint("TOPRIGHT", close, "TOPLEFT", -4, 0)
	copyBtn:SetText("Copy")
	copyBtn:SetScript("OnClick", function() self:CopyToClipboard() end)

	local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	body:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
	body:SetJustifyH("LEFT")
	body:SetJustifyV("TOP")
	body:SetNonSpaceWrap(false)
	body:SetPoint("TOPLEFT", 10, -28)
	body:SetPoint("BOTTOMRIGHT", -10, 10)
	body:SetText("|cff888888(no outgoing events recorded yet)|r")
	self._body = body

	f:EnableKeyboard(false)
	f:SetScript("OnUpdate", function(self2, elapsed)
		self._lastFlush = (self._lastFlush or 0) + elapsed
		if self._lastFlush >= 0.15 then
			self._lastFlush = 0
			flush(self)
		end
	end)
	f:Hide()
	self._frame = f
	return f
end

function Panel:IsShown()
	return self._frame ~= nil and self._frame:IsShown() == true
end

function Panel:Toggle()
	local f = self:_EnsureFrame()
	if f:IsShown() then
		f:Hide()
	else
		flush(self)
		f:Show()
	end
end

function Panel:Show()
	local f = self:_EnsureFrame()
	flush(self)
	f:Show()
end

function Panel:Hide()
	if self._frame then self._frame:Hide() end
end

-- Strip |cffRRGGBB / |r color codes for plain-text copying.
local function stripColors(s)
	return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|cff%x%x%x%x%x%x%x%x", ""))
end

-- Plain-text rendering of the buffer, oldest -> newest.
function Panel:GetPlainText()
	local entries = self._entries
	local chunks = {}
	for i = 1, #entries do
		chunks[#chunks + 1] = stripColors(entries[i])
	end
	return table.concat(chunks, "\n")
end

-- WoW has no direct clipboard API; the standard pattern is to stuff the
-- text into a focused EditBox, select-all, and let the user press Ctrl+C.
function Panel:CopyToClipboard()
	if not self._copyBox then
		local eb = CreateFrame("EditBox", "ZSBT_AttribCopyBox", UIParent, "BackdropTemplate")
		eb:SetSize(520, 320)
		eb:SetPoint("CENTER", UIParent, "CENTER", 0, -80)
		eb:SetFrameStrata("DIALOG")
		eb:SetBackdrop({
			bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		eb:SetBackdropColor(0, 0, 0, 0.92)
		eb:SetBackdropBorderColor(0.4, 0.6, 1.0, 0.9)
		eb:SetTextInsets(10, 10, 10, 10)
		eb:SetMultiLine(true)
		eb:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
		eb:SetAutoFocus(false)
		eb:EnableKeyboard(true)
		eb:EnableMouse(true)
		eb:SetScript("OnEscapePressed", function() eb:Hide() end)
		eb:Hide()
		self._copyBox = eb
	end
	local eb = self._copyBox
	eb:SetText(self:GetPlainText())
	eb:Show()
	eb:HighlightText()
	eb:SetFocus()
	if ZSBT.Addon and ZSBT.Addon.Print then
		ZSBT.Addon:Print("Attribution log loaded — press Ctrl+C to copy, Esc to close.")
	end
end

function Panel:Clear()
	self._entries = {}
	self._dirty = true
	if self._body then
		self._body:SetText("|cff888888(cleared)|r")
	end
end

return Panel
