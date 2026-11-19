------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - ZCT-style config shell
-- Left-sidebar page navigation + focused page content, matching the
-- standalone ZCT config flow while reusing ZSBT's AceConfig options.
--
-- Each nav page registers its own options table (ZSBT_pg_<id>) whose
-- args are extracted from ZSBT.BuildOptionsTable(), then is rendered by
-- AceConfigDialog:Open(appName, container) into an AceGUI "Frame"
-- widget reparented inside the page frame. All get/set/hidden logic
-- stays verbatim — this is presentation-only.
--
-- This shell IS the UI. "/zsbt" opens it. The classic AceConfigDialog
-- "ZSBT" window and the "/zsbt zctui" alias are DISABLED — see
-- Addon:OpenConfig in Core/Init.lua.
------------------------------------------------------------------------

local ADDON_NAME, ZSBT = ...

local L = ZSBT.L

local Shell = {}
ZSBT.ConfigShell = Shell

local ACD = LibStub("AceConfigDialog-3.0", true)
local ACR = LibStub("AceConfigRegistry-3.0", true)
local AceGUI = LibStub("AceGUI-3.0", true)

------------------------------------------------------------------------
-- Teach-a-spell drag capture state (file scope so a page rebuild never
-- orphans the hook closures). Cursor args are ambiguous — GetCursorInfo
-- returns slot/book indices alongside the spellId, and any small number
-- validates as *a* spell name. The pickups carry the true spellId; the
-- action slot is recorded so a bar drag can be restored — the pickup
-- empties the slot before our drop fires, so without the restore the
-- spell would be deleted from the bar.
------------------------------------------------------------------------
local dragActionSlot, dragActionAt, dragSpellId, dragSpellAt
if type(hooksecurefunc) == "function" then
	if type(_G.PickupAction) == "function" then
		hooksecurefunc("PickupAction", function(slot)
			if type(slot) == "number" then
				dragActionSlot = slot
				dragActionAt = GetTime and GetTime() or 0
			end
		end)
	end
	if type(_G.PickupSpell) == "function" then
		hooksecurefunc("PickupSpell", function(id)
			if type(id) == "number" then
				dragSpellId = id
				dragSpellAt = GetTime and GetTime() or 0
			end
		end)
	end
end

------------------------------------------------------------------------
-- Nav pages (ZCT flow order). getArgs resolves into BuildOptionsTable()
-- output and must return a GROUP table (not bare args): AceConfig only
-- adds a ScrollFrame for mixed leaf+group content one level below a
-- tree node, so each page root holds exactly one group child — the
-- same shape the classic UI's root tree produces.
------------------------------------------------------------------------
local function wrapGroup(label, args)
	return { type = "group", name = label, order = 1, childGroups = "tree", args = args }
end

local NAV = {
	{ id = "general",   label = L["|cFFFFD100General|r"],           order = 1,
	  getArgs = function(a) return a.general end },
	{ id = "profiles",  label = L["|cFFFFD100DB Profiles|r"],      order = 2,
	  getArgs = function(a) return a.profiles end },
	{ id = "combat",    label = L["|cFFFFD100Combat Text|r"],      order = 3,
	  getArgs = function(a)
		  local ct = a.combatText
		  if not (ct and ct.args) then return nil end
		  -- Spam Control lives on its own nav page; drop it here.
		  local copy = {}
		  for k, v in pairs(ct.args) do
			  if k ~= "spamControl" then copy[k] = v end
		  end
		  return wrapGroup(L["|cFFFFD100Combat Text|r"], copy)
	  end },
	{ id = "crits",     label = L["|cFFFFD100Crits|r"],            order = 4,
	  getArgs = function(a) return a.crits end },
	{ id = "alerts",    label = L["|cFFFFD100Alerts|r"],           order = 5,
	  getArgs = function(a) return a.alerts end },
	{ id = "resources", label = L["|cFFFFD100Resources|r"],        order = 6,
	  getArgs = function(a)
		  local r = a.resources
		  local rt = r and r.args and r.args.resourceTracker
		  if not (rt and rt.args) then return nil end
		  return wrapGroup(L["|cFFFFD100Resource Tracker|r"], rt.args)
	  end },
	{ id = "areas",     label = L["|cFFFFD100Scroll Areas|r"],     order = 7,
	  getArgs = function(a) return a.scrollAreas end },
	{ id = "spam",      label = L["|cFFFFD100Spam Control|r"],     order = 8,
	  getArgs = function(a)
		  local ct = a.combatText
		  local sc = ct and ct.args and ct.args.spamControl
		  if not (sc and sc.args) then return nil end
		  return wrapGroup(L["|cFFFFD100Spam Control|r"], sc.args)
	  end },
	{ id = "class",     label = L["|cFFFFD100Class|r"],            order = 9,
	  customPage = true },
	{ id = "help",      label = L["|cFFFFD100Help and Support|r"], order = 10,
	  getArgs = function(a) return a.maintenance end },
	{ id = "donate",    label = L["|cFFFFD100Donate|r"],           order = 11,
	  customPage = true },
}

local DEFAULT_W, DEFAULT_H = ZSBT.CONFIG_WIDTH or 900, ZSBT.CONFIG_HEIGHT or 820
local MIN_W, MIN_H = 640, 480
local SIDE_W = 150

local frame, content, sidebar
local navButtons = {}
local pageFrames = {}
local pageWidgets = {}
local pageFed = {}
local activePage
local registeredApps = {}

------------------------------------------------------------------------
-- NotifyChange fan-out: arg set() functions call NotifyChange("ZSBT"),
-- but page widgets live under ZSBT_pg_* app names. Fan "ZSBT" out to
-- every registered page app so hidden/disabled/order deps refresh.
------------------------------------------------------------------------
local function installNotifyFanout()
	if not ACR or ACR._zsbtShellFanout then return end
	ACR._zsbtShellFanout = true
	local orig = ACR.NotifyChange
	ACR.NotifyChange = function(self, appName, ...)
		orig(self, appName, ...)
		if appName == "ZSBT" then
			for app in pairs(registeredApps) do
				orig(self, app)
			end
		end
	end
end

------------------------------------------------------------------------
-- Shell chrome
------------------------------------------------------------------------
local COL = {
	bg      = { 0.055, 0.065, 0.085, 0.97 },
	sidebar = { 0.075, 0.09, 0.115, 1.0 },
	track   = { 0.16, 0.19, 0.24, 1.0 },
	accent  = { 1.00, 0.82, 0.00, 1.0 },   -- ZSBT gold
	text    = { 0.92, 0.93, 0.95, 1.0 },
}

local function setBg(f, color, border)
	f:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		tile = true, tileSize = 8, edgeSize = 1,
		insets = { left = 1, right = 1, top = 1, bottom = 1 },
	})
	f:SetBackdropColor(color[1], color[2], color[3], color[4] or 1)
	if border then f:SetBackdropBorderColor(border[1], border[2], border[3], border[4]) end
end

local function shellFont(parent, size, color, text)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFont(GameFontNormal:GetFont())
	fs:SetTextColor(color[1], color[2], color[3], color[4] or 1)
	fs:SetText(text or "")
	fs:SetHeight(size * 1.4)
	return fs
end

local function getShellSize()
	local g = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
	local s = g and g.configShellSize
	local w = (type(s) == "table" and tonumber(s.width)) or DEFAULT_W
	local h = (type(s) == "table" and tonumber(s.height)) or DEFAULT_H
	return w, h
end

local function saveShellSize()
	if not frame then return end
	local w, h = frame:GetWidth(), frame:GetHeight()
	ZSBT.db.profile.general = ZSBT.db.profile.general or {}
	ZSBT.db.profile.general.configShellSize = { width = w, height = h }
end

local function buildShell()
	if frame then return end
	frame = CreateFrame("Frame", "ZSBT_ConfigShell", UIParent, "BackdropTemplate")
	local w, h = getShellSize()
	frame:SetSize(w, h)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetResizable(true)
	frame:SetResizeBounds(MIN_W, MIN_H)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	setBg(frame, COL.bg, { 0.35, 0.55, 0.35, 1 })

	-- Drag strip across the top
	local drag = CreateFrame("Frame", nil, frame)
	drag:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -4)
	drag:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -4)
	drag:SetHeight(30)
	drag:EnableMouse(true)
	drag:RegisterForDrag("LeftButton")
	drag:SetScript("OnDragStart", function() frame:StartMoving() end)
	drag:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

	-- Resize grip (bottom-right), persists size on release.
	-- UIPanelResizeButtonTemplate does not exist on this client — custom grip.
	local rs = CreateFrame("Button", nil, frame)
	rs:SetSize(18, 18)
	rs:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
	rs:EnableMouse(true)
	rs:RegisterForDrag("LeftButton")
	rs:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
	rs:SetScript("OnMouseUp", function()
		frame:StopMovingOrSizing()
		saveShellSize()
	end)
	for i = 1, 2 do
		local line = rs:CreateTexture(nil, "ARTWORK")
		local sz = 14 - (i - 1) * 6
		line:SetSize(sz, sz)
		line:SetPoint("BOTTOMRIGHT", -4 + (i - 1) * 3, 4 - (i - 1) * 3)
		line:SetTexture(137057) -- Interface\\Tooltips\\UI-Tooltip-Border
		local x = 0.1 * sz / 17
		line:SetTexCoord(0.05 - x, 0.5, 0.05, 0.5 + x, 0.05, 0.5 - x, 0.5 + x, 0.5)
	end

	sidebar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	sidebar:SetWidth(SIDE_W)
	sidebar:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -8)
	sidebar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 8)
	setBg(sidebar, COL.sidebar)

	-- Title pinned to the bottom of the nav sidebar
	local title = shellFont(sidebar, 12, COL.text,
		"ZSBT  |cFF888888v" .. tostring(ZSBT.VERSION or "?"))
	title:SetPoint("BOTTOM", sidebar, "BOTTOM", 0, 10)

	content = CreateFrame("Frame", nil, frame)
	content:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_W + 18, -12)
	content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 14)

	navButtons, pageFrames, pageWidgets, pageFed = {}, {}, {}, {}
	local navY = -14
	for _, nav in ipairs(NAV) do
		local b = CreateFrame("Button", nil, sidebar, "BackdropTemplate")
		b:SetSize(SIDE_W - 16, 30)
		b:SetPoint("TOP", sidebar, "TOP", 0, navY)
		setBg(b, COL.sidebar, COL.track)
		local t = shellFont(b, 14, COL.text, nav.label)
		t:SetPoint("LEFT", b, "LEFT", 12, 0)
		b._label = t
		b:SetScript("OnClick", function() Shell:ShowPage(nav.id) end)
		navButtons[nav.id] = b
		navY = navY - 36
	end
end

------------------------------------------------------------------------
-- Donate page: custom content (no AceConfig options). WoW has no addon
-- API for opening external URLs, so the Ko-fi link is shown in a
-- selectable edit box for copy/paste.
------------------------------------------------------------------------
-- Class page: custom content (no AceConfig options). Shows the active
-- class module, its live attribution state (learned schools, guardian
-- activity, tracked casts), and the class tweaks the module exposes.
-- Refreshes on every show — guardian windows count down in real time.
local function buildClassPage(pf)
	local title = shellFont(pf, 18, COL.accent,
		L["|cFFFFD100Class Module|r"])
	title:SetPoint("TOP", pf, "TOP", 0, -20)

	local body = shellFont(pf, 13, COL.text, "")
	body:SetWidth(620)
	body:SetJustifyH("LEFT")
	body:SetPoint("TOPLEFT", pf, "TOPLEFT", 20, -56)

	-- Long descriptions live in hover tooltips so the page stays compact.
	local function attachTip(f, tipFn)
		f:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(tipFn(), 1, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		f:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end

	-- Class-flavored guardian naming for the tooltip (module-declared).
	local function guardianLabel()
		local mod = ZSBT.ClassDB and ZSBT.ClassDB.ActiveModule
			and ZSBT.ClassDB.ActiveModule()
		return (mod and mod.guardianLabel) or L["your pets and guardians"]
	end

	-- Toggle set is module-declared (mod.toggles): only supported keys
	-- render. Hints are tooltips, not inline text.
	local toggleDefs = {
		{ key = "resolveGuardians",
			label = L["Name guardian spells"],
			tip = function()
				return (L["Guardian damage (%s) is named from summon tracking. Off = those hits fall back to generic pet damage."])
					:format(guardianLabel())
			end,
			get = function(prof) return not (prof and prof.classModule and prof.classModule.resolveGuardians == false) end,
			set = function(prof, v) prof.classModule.resolveGuardians = v end,
		},
		{ key = "namePetMelee",
			label = L["Show pet melee hits"],
			tip = function()
				return L["Pet melee verified by a combat-log line displays as 'Auto Attack'. A stolen MY_PET line could still name a foreign swing."]
			end,
			get = function(prof) return prof and prof.classModule and prof.classModule.namePetMelee == true end,
			set = function(prof, v) prof.classModule.namePetMelee = v end,
		},
	}
	local toggles = {}
	for _, def in ipairs(toggleDefs) do
		if ZSBT.ClassDB and ZSBT.ClassDB.SupportsToggle
			and ZSBT.ClassDB.SupportsToggle(def.key) then
			local cb = CreateFrame("CheckButton", nil, pf, "InterfaceOptionsCheckButtonTemplate")
			cb:SetPoint("TOPLEFT", body, "BOTTOMLEFT", -4, -8 - #toggles * 26)
			cb.Text:SetText(def.label)
			cb.Text:SetTextColor(1, 1, 1)
			cb:SetScript("OnClick", function(self)
				local prof = ZSBT.db and ZSBT.db.profile
				if not prof then return end
				prof.classModule = prof.classModule or {}
				def.set(prof, self:GetChecked() == true)
			end)
			attachTip(cb, def.tip)
			toggles[#toggles + 1] = { def = def, cb = cb }
		end
	end

	-- Status detail (inferred schools, active guardians) spans full width
	-- under the toggles, above the split panes.
	local detail = shellFont(pf, 12, COL.dim or COL.text, "")
	detail:SetWidth(620)
	detail:SetJustifyH("LEFT")
	if toggles[#toggles] then
		detail:SetPoint("TOPLEFT", toggles[#toggles].cb, "BOTTOMLEFT", -4, -10)
	else
		detail:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 4, -16)
	end

	--------------------------------------------------------------------
	-- Split panes: module knowledge scrolls on the left; teach-a-spell
	-- and taught spells sit in a right column. Both panes anchor to the
	-- page edges so they track the resizable window.
	--------------------------------------------------------------------
	local knowledgeTitle = shellFont(pf, 12, COL.accent,
		L["|cFFFFD100Module knowledge|r"])
	knowledgeTitle:SetPoint("TOPLEFT", detail, "BOTTOMLEFT", 0, -16)

	local knowledgeScroll = CreateFrame("ScrollFrame", nil, pf, "UIPanelScrollFrameTemplate")
	knowledgeScroll:SetPoint("TOPLEFT", knowledgeTitle, "BOTTOMLEFT", 0, -6)
	knowledgeScroll:SetPoint("BOTTOMRIGHT", pf, "BOTTOM", -10, 8)
	local knowledgeChild = CreateFrame("Frame", nil, knowledgeScroll)
	knowledgeChild:SetSize(420, 1)
	knowledgeScroll:SetScrollChild(knowledgeChild)

	local rightCol = CreateFrame("Frame", nil, pf)
	rightCol:SetPoint("TOPRIGHT", pf, "TOPRIGHT", -8, 0)
	rightCol:SetPoint("TOP", knowledgeTitle, "TOP", 0, 0)
	rightCol:SetPoint("BOTTOMLEFT", pf, "BOTTOM", 10, 8)

	local teachTitle = shellFont(rightCol, 12, COL.accent,
		L["|cFFFFD100Teach a spell|r"])
	teachTitle:SetPoint("TOPLEFT", rightCol, "TOPLEFT", 0, 0)

	-- Drop row: label text left, drop target right styled as a Blizzard
	-- empty action-bar slot (reads as "a spell goes here" instead of a
	-- random ability icon). A taught spell's icon shows inside the slot.
	local dropRow = CreateFrame("Frame", nil, rightCol)
	dropRow:SetPoint("TOPLEFT", teachTitle, "BOTTOMLEFT", 0, -6)
	dropRow:SetSize(240, 48)
	local dropLabel = shellFont(dropRow, 11, COL.dim or COL.text,
		L["Drag a spell from your bar or spellbook here"])
	dropLabel:SetPoint("TOPLEFT", dropRow, "TOPLEFT", 0, -4)
	dropLabel:SetWidth(170)
	dropLabel:SetJustifyH("LEFT")
	local drop = CreateFrame("Button", nil, dropRow)
	drop:SetSize(44, 44)
	drop:SetPoint("LEFT", dropLabel, "RIGHT", 6, 4)
	local dropSlot = drop:CreateTexture(nil, "BACKGROUND")
	dropSlot:SetAllPoints()
	dropSlot:SetTexture("Interface\\Buttons\\UI-Quickslot2")
	local dropIcon = drop:CreateTexture(nil, "ARTWORK")
	dropIcon:SetPoint("TOPLEFT", 6, -6)
	dropIcon:SetPoint("BOTTOMRIGHT", -6, 6)
	dropIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	local roleState = { role = "auto" }
	local roleDefs = {
		{ key = "auto",    label = L["Auto (guess)"] },
		{ key = "dot",     label = L["Damage over Time"] },
		{ key = "channel", label = L["Channeled"] },
		{ key = "cast",    label = L["Multi-hit cast"] },
	}
	local roleCbs = {}
	for i, rd in ipairs(roleDefs) do
		local cb = CreateFrame("CheckButton", nil, rightCol, "InterfaceOptionsCheckButtonTemplate")
		cb:SetSize(24, 24)
		cb:SetPoint("TOPLEFT", dropRow, "BOTTOMLEFT", -4, -4 - (i - 1) * 26)
		cb.Text:SetText(rd.label)
		cb.Text:SetTextColor(1, 1, 1)
		cb:SetScript("OnClick", function(self)
			roleState.role = rd.key
			for _, other in ipairs(roleCbs) do
				other:SetChecked(other == self)
			end
		end)
		cb:SetChecked(rd.key == roleState.role)
		roleCbs[i] = cb
	end

	local budgetBox = CreateFrame("EditBox", nil, rightCol, "InputBoxTemplate")
	budgetBox:SetSize(44, 20)
	budgetBox:SetPoint("LEFT", roleCbs[4], "RIGHT", 120, 0)
	budgetBox:SetAutoFocus(false)
	budgetBox:SetNumeric(true)
	budgetBox:SetMaxLetters(3)
	budgetBox:SetText("5")
	budgetBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	local budgetLabel = shellFont(rightCol, 11, COL.dim or COL.text, L["hits"])
	budgetLabel:SetPoint("LEFT", budgetBox, "RIGHT", 6, 0)
	attachTip(budgetBox, function()
		return L["How many hits one cast of this spell may name."]
	end)

	local confirmFs = shellFont(rightCol, 11, COL.text, "")
	confirmFs:SetPoint("TOPLEFT", roleCbs[4], "BOTTOMLEFT", 4, -10)
	confirmFs:SetWidth(300)
	confirmFs:SetJustifyH("LEFT")

	local taughtTitle = shellFont(rightCol, 12, COL.accent,
		L["|cFFFFD100Taught spells|r"])
	taughtTitle:SetPoint("TOPLEFT", confirmFs, "BOTTOMLEFT", -4, -14)

	local taughtRows = {}
	local refreshTaught

	local function dragNow()
		return GetTime and GetTime() or 0
	end
	local function nameFor(sid)
		local nm = ZSBT.CleanSpellName and ZSBT.CleanSpellName(sid)
		return (type(nm) == "string" and nm ~= "") and nm or nil
	end
	local function slotSpell(slot)
		if type(_G.GetActionInfo) ~= "function" then return nil end
		local ok, at, aid = pcall(GetActionInfo, slot)
		if ok and at == "spell" and type(aid) == "number" and aid > 0 then
			return aid
		end
		return nil
	end

	-- Pickup records win (true spellId); cursor args are last resort.
	-- Returns spellId, name, sourceSlot(optional).
	local function resolveDrag()
		local now = dragNow()
		if dragSpellId and (now - (dragSpellAt or -99)) < 3 then
			local nm = nameFor(dragSpellId)
			if nm then
				local slot = (dragActionAt and (now - dragActionAt) < 3)
					and dragActionSlot or nil
				return dragSpellId, nm, slot
			end
		end
		if dragActionSlot and dragActionAt and (now - dragActionAt) < 3 then
			local aid = slotSpell(dragActionSlot)
			local nm = aid and nameFor(aid)
			if nm then return aid, nm, dragActionSlot end
		end
		if type(GetCursorInfo) ~= "function" then return nil end
		local ctype, a1, a2, a3 = GetCursorInfo()
		if ctype == "action" and type(a1) == "number" then
			local aid = slotSpell(a1)
			local nm = aid and nameFor(aid)
			if nm then return aid, nm, a1 end
		end
		if ctype ~= "spell" then return nil end
		for _, v in ipairs({ a3, a2, a1 }) do
			if type(v) == "number" and v > 0 then
				local nm = nameFor(v)
				if nm then return v, nm, nil end
			end
		end
		return nil
	end

	local function applyTeach(sid, nm)
		local budget = tonumber(budgetBox:GetText())
		local role = roleState.role
		if role == "auto" and ZSBT.ClassDB and ZSBT.ClassDB.InferRole then
			role = ZSBT.ClassDB.InferRole(sid)
		end
		if ZSBT.ClassDB and ZSBT.ClassDB.TeachSpell
			and ZSBT.ClassDB.TeachSpell(sid, nm, role, budget) then
			local known = ZSBT.ClassDB.KnowsSpell
				and ZSBT.ClassDB.KnowsSpell(sid) or nil
			local suffix = known
				and (" |cFFFFAA00(known: %s)|r"):format(tostring(known)) or ""
			confirmFs:SetText(("|cFF55FF55+%s|r (%d) → %s%s")
				:format(tostring(nm), sid, tostring(role), suffix))
			local tex = C_Spell and C_Spell.GetSpellTexture
				and C_Spell.GetSpellTexture(sid)
			if tex then dropIcon:SetTexture(tex) end
			if refreshTaught then refreshTaught() end
		end
	end

	local function tryTeach()
		local sid, nm, srcSlot = resolveDrag()
		if not sid then return end
		if ClearCursor then ClearCursor() end
		-- Restore a bar-dragged spell into its source slot; a pickup
		-- empties the slot before our drop fires. PlaceAction is
		-- protected in combat — pcall keeps the failure silent there.
		if srcSlot and type(_G.PickupSpell) == "function"
			and type(_G.PlaceAction) == "function" then
			pcall(PickupSpell, sid)
			pcall(PlaceAction, srcSlot)
		end
		dragActionSlot, dragSpellId = nil, nil
		applyTeach(sid, nm)
	end
	drop:SetScript("OnReceiveDrag", tryTeach)
	drop:SetScript("OnClick", tryTeach)

	local taughtMore = shellFont(rightCol, 11, COL.dim or COL.text, "")
	taughtMore:Hide()

	refreshTaught = function()
		local list = (ZSBT.ClassDB and ZSBT.ClassDB.TaughtList)
			and ZSBT.ClassDB.TaughtList() or {}
		local MAX_ROWS = 12
		local need = math.max(#taughtRows, math.min(#list, MAX_ROWS))
		for i = 1, need do
			local row = taughtRows[i]
			local e = list[i]
			if e and i <= MAX_ROWS then
				if not row then
					row = {}
					row.fs = shellFont(rightCol, 11, COL.text, "")
					row.fs:SetPoint("TOPLEFT", taughtTitle, "BOTTOMLEFT", 10, -6 - (i - 1) * 16)
					row.rm = CreateFrame("Button", nil, rightCol)
					row.rm:SetSize(16, 16)
					row.rm:SetPoint("LEFT", row.fs, "RIGHT", 8, 0)
					local rmT = shellFont(row.rm, 11, COL.dim or COL.text, "x")
					rmT:SetAllPoints()
					row.rm:SetScript("OnClick", function()
						if row._sid and ZSBT.ClassDB and ZSBT.ClassDB.Unteach then
							ZSBT.ClassDB.Unteach(row._sid)
						end
						refreshTaught()
					end)
					taughtRows[i] = row
				end
				row._sid = e.sid
				local label = ("%s (%d) . %s")
					:format(tostring(e.name), e.sid, tostring(e.role))
				if e.role == "cast" and e.budget then
					label = label .. (" x%d"):format(tonumber(e.budget) or 0)
				end
				row.fs:SetText(label)
				row.fs:Show()
				row.rm:Show()
			elseif row then
				row._sid = nil
				row.fs:Hide()
				row.rm:Hide()
			end
		end
		if #list > MAX_ROWS then
			taughtMore:SetText(("+%d more"):format(#list - MAX_ROWS))
			taughtMore:SetPoint("TOPLEFT", taughtTitle, "BOTTOMLEFT", 10, -6 - MAX_ROWS * 16)
			taughtMore:Show()
		else
			taughtMore:Hide()
		end
	end

	--------------------------------------------------------------------
	-- Spellbook flyout: a movable pop-out panel listing the player's
	-- spellbook entries, anchored just outside the page's right edge.
	-- Parented to the class page so it hides when the page does. Rows
	-- drag via C_Spell.PickupSpell — the pickup hook captures the exact
	-- id and no bar slot is emptied. Clicking a row teaches directly.
	--------------------------------------------------------------------
	local flyout = CreateFrame("Frame", nil, pf, "BackdropTemplate")
	flyout:SetSize(230, 380)
	flyout:SetPoint("TOPLEFT", pf, "TOPRIGHT", 10, 0)
	flyout:SetMovable(true)
	flyout:EnableMouse(true)
	flyout:RegisterForDrag("LeftButton")
	flyout:SetScript("OnDragStart", function(self) self:StartMoving() end)
	flyout:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	flyout:Hide()
	setBg(flyout, COL.sidebar)
	local flyTitle = shellFont(flyout, 12, COL.accent, L["Spellbook"])
	flyTitle:SetPoint("TOP", flyout, "TOP", 0, -8)

	local flyScroll = CreateFrame("ScrollFrame", nil, flyout, "UIPanelScrollFrameTemplate")
	flyScroll:SetPoint("TOPLEFT", flyout, "TOPLEFT", 4, -30)
	flyScroll:SetPoint("BOTTOMRIGHT", flyout, "BOTTOMRIGHT", -24, 8)
	local flyChild = CreateFrame("Frame", nil, flyScroll)
	flyChild:SetSize(190, 1)
	flyScroll:SetScrollChild(flyChild)

	local flyRows = {}
	local flyEmpty
	local function buildSpellList()
		local entries = {}
		if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines
			and C_SpellBook.GetSpellBookItemInfo and Enum
			and Enum.SpellBookSpellBank and Enum.SpellBookItemType then
			local n = C_SpellBook.GetNumSpellBookSkillLines() or 0
			for li = 1, n do
				local info = C_SpellBook.GetSpellBookSkillLineInfo
					and C_SpellBook.GetSpellBookSkillLineInfo(li)
				local count = info and (info.numSpellBookItems or 0) or 0
				local base = info and (info.itemOffsetIndex or 0) or 0
				for j = 1, count do
					local ok, it = pcall(C_SpellBook.GetSpellBookItemInfo,
						base + j, Enum.SpellBookSpellBank.Player)
					if ok and type(it) == "table" and it.spellID
						and it.itemType == Enum.SpellBookItemType.Spell then
						entries[#entries + 1] = {
							sid = it.spellID,
							name = it.name or "?",
							icon = it.iconID or it.iconFileID,
						}
					end
				end
			end
		end
		table.sort(entries, function(a, b)
			return tostring(a.name) < tostring(b.name)
		end)
		for i, e in ipairs(entries) do
			local row = flyRows[i]
			if not row then
				local btn = CreateFrame("Button", nil, flyChild)
				btn:SetSize(190, 24)
				btn:RegisterForDrag("LeftButton")
				local tex = btn:CreateTexture(nil, "ARTWORK")
				tex:SetSize(20, 20)
				tex:SetPoint("LEFT", btn, "LEFT", 2, 0)
				local fs = shellFont(btn, 11, COL.text, "")
				fs:SetPoint("LEFT", tex, "RIGHT", 6, 0)
				fs:SetWidth(158)
				fs:SetJustifyH("LEFT")
				row = { btn = btn, tex = tex, fs = fs }
				row.btn:SetScript("OnDragStart", function()
					if row._sid then
						local pick = (C_Spell and C_Spell.PickupSpell) or _G.PickupSpell
						if type(pick) == "function" then pcall(pick, row._sid) end
					end
				end)
				row.btn:SetScript("OnClick", function()
					if row._sid then
						local nm = nameFor(row._sid) or tostring(row._sid)
						applyTeach(row._sid, nm)
					end
				end)
				flyRows[i] = row
			end
			row._sid = e.sid
			row.btn:SetPoint("TOPLEFT", flyChild, "TOPLEFT", 0, -(i - 1) * 26)
			row.tex:SetTexture(e.icon or 134400)
			row.fs:SetText(tostring(e.name))
			row.btn:Show()
		end
		for i = #entries + 1, #flyRows do
			flyRows[i].btn:Hide()
		end
		flyChild:SetHeight(math.max(1, #entries * 26))
		if #entries == 0 then
			if not flyEmpty then
				flyEmpty = shellFont(flyChild, 11, COL.dim or COL.text,
					L["Spellbook enumeration unavailable"])
				flyEmpty:SetPoint("TOPLEFT", flyChild, "TOPLEFT", 4, -4)
			end
			flyEmpty:Show()
		elseif flyEmpty then
			flyEmpty:Hide()
		end
	end

	local flyoutBuilt = false
	local spellBtn = CreateFrame("Button", nil, rightCol, "UIPanelButtonTemplate")
	spellBtn:SetSize(90, 22)
	spellBtn:SetPoint("TOPRIGHT", rightCol, "TOPRIGHT", 0, 0)
	spellBtn:SetText(L["Spellbook"])
	spellBtn:SetScript("OnClick", function()
		if flyout:IsShown() then
			flyout:Hide()
		else
			if not flyoutBuilt then
				flyoutBuilt = true
				buildSpellList()
			end
			flyout:Show()
		end
	end)

	local knowledgeRows = {}
	local function refreshKnowledge()
		local list = (ZSBT.ClassDB and ZSBT.ClassDB.KnowledgeList)
			and ZSBT.ClassDB.KnowledgeList() or {}
		local need = math.max(#knowledgeRows, #list)
		for i = 1, need do
			local row = knowledgeRows[i]
			local e = list[i]
			if e then
				if not row then
					row = shellFont(knowledgeChild, 11, COL.text, "")
					row:SetPoint("TOPLEFT", knowledgeChild, "TOPLEFT", 8, -4 - (i - 1) * 14)
					row:SetWidth(400)
					row:SetJustifyH("LEFT")
					knowledgeRows[i] = row
				end
				local ids = ""
				if type(e.ids) == "table" and #e.ids > 0 then
					local parts = {}
					for _, id in ipairs(e.ids) do parts[#parts + 1] = tostring(id) end
					ids = " (" .. table.concat(parts, ",") .. ")"
				end
				row:SetText(("|cFF888888%s|r %s%s%s")
					:format(tostring(e.kind), tostring(e.name), ids,
						e.extra and (" - " .. tostring(e.extra)) or ""))
				row:Show()
			elseif row then
				row:Hide()
			end
		end
		knowledgeChild:SetHeight(math.max(1, 10 + #list * 14))
	end

	local function refresh()
		local cdb = ZSBT.ClassDB
		local mod = cdb and cdb.ActiveModule and cdb.ActiveModule()
		local tag = cdb and cdb.PlayerTag and cdb.PlayerTag() or "?"
		local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
		local st = ec and ec.ClassModuleState and ec:ClassModuleState() or nil

		if not mod then
			body:SetText(L["No class module is loaded for this character."])
			for _, t in ipairs(toggles) do t.cb:Hide() end
			detail:SetText("")
			refreshTaught()
			refreshKnowledge()
			return
		end
		local prof = ZSBT.db and ZSBT.db.profile
		for _, t in ipairs(toggles) do
			t.cb:Show()
			t.cb:SetChecked(t.def.get(prof))
		end

		local autoVetoed = cdb.VetoAuto and cdb.VetoAuto() == true
		local lines = {
			("|cFFFFD100Module:|r %s"):format(tostring(tag)),
			("|cFFFFD100Auto-attacks:|r %s"):format(autoVetoed and "vetoed (class never swings)" or "allowed"),
			("|cFFFFD100PLAYER_SWING:|r %s"):format(st and st.swingSupported and "available" or "unavailable (Retail)"),
			("|cFFFFD100Inferred spell schools:|r %d"):format(st and st.learnedCount or 0),
			("|cFFFFD100Casts tracked:|r %d pending / %d pet"):format(
				st and st.pendingCasts or 0, st and st.petCasts or 0),
		}
		body:SetText(table.concat(lines, "\n"))

		local d = {}
		if st and type(st.learned) == "table" then
			local names = {}
			for sid, school in pairs(st.learned) do
				local nm = ZSBT.CleanSpellName and ZSBT.CleanSpellName(sid) or tostring(sid)
				names[#names + 1] = ("%s=%s"):format(tostring(nm), tostring(school))
			end
			table.sort(names)
			if #names > 0 then
				d[#d + 1] = L["Inferred (spells with no static school data):"]
					.. " " .. table.concat(names, ", ")
			end
		end
		if st and type(st.guardianUntil) == "table" then
			local t = GetTime and GetTime() or 0
			local g = {}
			for group, untilAt in pairs(st.guardianUntil) do
				if type(untilAt) == "number" and untilAt > t then
					g[#g + 1] = ("%s %.1fs"):format(tostring(group), untilAt - t)
				end
			end
			table.sort(g)
			d[#d + 1] = L["Active guardians:"] .. " " .. (#g > 0 and table.concat(g, ", ") or L["none"])
		end
		detail:SetText(table.concat(d, "\n"))
		refreshTaught()
		refreshKnowledge()
	end
	pf:SetScript("OnShow", refresh)
end

local function buildDonatePage(pf)
	local title = shellFont(pf, 18, COL.accent,
		L["|cFFFFD100Support Zore's Scrolling Battle Text|r"])
	title:SetPoint("TOP", pf, "TOP", 0, -20)

	local body = shellFont(pf, 13, COL.text,
		L["Thank you for using ZSBT! Donations are appreciated but never required — they help keep development going.\n\nIf you'd like to support the project, you can donate on Ko-fi:"])
	body:SetWidth(480)
	body:SetJustifyH("CENTER")
	body:SetPoint("TOP", title, "BOTTOM", 0, -20)

	local eb = CreateFrame("EditBox", nil, pf, "InputBoxTemplate")
	eb:SetSize(360, 24)
	eb:SetPoint("TOP", body, "BOTTOM", 0, -24)
	eb:SetText("https://ko-fi.com/zorellion")
	eb:SetCursorPosition(0)

	local hint = shellFont(pf, 11, COL.text,
		L["Click the link above, press Ctrl+A then Ctrl+C, and paste it into your browser."])
	hint:SetWidth(480)
	hint:SetJustifyH("CENTER")
	hint:SetPoint("TOP", eb, "BOTTOM", 0, -12)
end

------------------------------------------------------------------------
-- Pages: lazy AceGUI "BlizOptionsGroup" container per page, fed by
-- ACD:Open. This is the same chromeless container AceConfig uses for
-- option groups — no window chrome, just a title label + content frame,
-- so pages match the classic UI's look. FeedGroup wraps it in a
-- ScrollFrame automatically (it is not InlineGroup/SimpleGroup).
------------------------------------------------------------------------
local function ensurePage(id)
	local pf = pageFrames[id]
	if not (pf and ACD and AceGUI) then return end
	if pageFed[id] then return end
	for _, nav in ipairs(NAV) do
		if nav.id == id and nav.customPage then
			pageFed[id] = true
			return
		end
	end

	-- Reuse the widget across re-opens: ACD:Open ReleaseChildren +
	-- re-feeds it, which is exactly the refresh we want after a rebuild.
	local w = pageWidgets[id]
	if not w then
		w = AceGUI:Create("BlizOptionsGroup")
		pageWidgets[id] = w
	end

	local appName = "ZSBT_pg_" .. id
	local ok, err = pcall(ACD.Open, ACD, appName, w)
	if not ok then
		ZSBT:Print("[ZSBT] config page '" .. id .. "' failed: " .. tostring(err))
		return
	end

	w.frame:ClearAllPoints()
	w.frame:SetParent(pf)
	w.frame:SetAllPoints(pf)
	w.frame:SetFrameStrata("DIALOG")
	-- BlizOptionsGroup has no Show() method, so ACD:Open's `if f.Show`
	-- skips it and the frame stays hidden from its constructor.
	w.frame:Show()
	pageFed[id] = true
end

function Shell:ShowPage(id)
	if not frame then return end
	if activePage == id then return end
	activePage = id
	for bid, btn in pairs(navButtons) do
		local on = bid == id
		if btn._label then
			if on then
				btn._label:SetTextColor(COL.accent[1], COL.accent[2], COL.accent[3], 1)
			else
				btn._label:SetTextColor(COL.text[1], COL.text[2], COL.text[3], 1)
			end
		end
	end
	for pid, pf in pairs(pageFrames) do
		pf:SetShown(pid == id)
	end
	ensurePage(id)
end

------------------------------------------------------------------------
-- Open / close
------------------------------------------------------------------------
function Shell:Open()
	if not (ACD and ACR and AceGUI and ZSBT.BuildOptionsTable) then
		ZSBT:Print(L["Config UI unavailable."])
		return
	end
	installNotifyFanout()

	-- Rebuild options so dynamic args (resource buttons per class etc.)
	-- reflect the current character, same as OpenConfig does. _shellMode
	-- tells the tab builders to harvest args into page buckets; the
	-- legacy UI builds without it and keeps the original structure.
	ZSBT._shellMode = true
	local ok, options = pcall(ZSBT.BuildOptionsTable)
	ZSBT._shellMode = nil
	if not (ok and type(options) == "table" and options.args) then
		ZSBT:Print("[ZSBT] config build failed: " .. tostring(options))
		return
	end

	-- The AceDBOptions profiles table is injected into the options tree at
	-- OnInitialize and again by OpenConfig on rebuild — the shell rebuilds
	-- its own table every open, so it must inject too or DB Profiles is blank.
	if ZSBT.Addon and ZSBT.Addon.InjectDBProfilesOptions then
		pcall(ZSBT.Addon.InjectDBProfilesOptions, ZSBT.Addon, options)
	end

	-- (Re)register page option tables. Root holds exactly one group
	-- child so AceConfig renders the same tree+scroll shape as the
	-- classic UI's top-level tabs.
	wipe(registeredApps)
	for _, nav in ipairs(NAV) do
		if not nav.customPage then
		local group = nav.getArgs(options.args)
		if type(group) == "table" and type(group.args) == "table" then
			local appName = "ZSBT_pg_" .. nav.id
			ACR:RegisterOptionsTable(appName, {
				type = "group",
				name = nav.label,
				order = nav.order,
				childGroups = "tree",
				args = { [nav.id] = group },
			}, true)
			registeredApps[appName] = true
		end
		end
	end

	buildShell()

	-- Page frames (created once, reused across opens)
	for _, nav in ipairs(NAV) do
		if not pageFrames[nav.id] then
			local pf = CreateFrame("Frame", nil, content)
			pf:SetAllPoints(content)
			pf:Hide()
			pageFrames[nav.id] = pf
			if nav.id == "donate" then
				buildDonatePage(pf)
			elseif nav.id == "class" then
				buildClassPage(pf)
			end
		end
	end

	-- Pages fed under a previous registration are stale — refed lazily
	-- only if the app name changed is not a concern (same names), but
	-- args were rebuilt, so drop fed flags to re-feed on next show.
	for id in pairs(pageFed) do pageFed[id] = nil end

	frame:Show()
	if activePage and pageFrames[activePage] then
		Shell:ShowPage(activePage)
	else
		Shell:ShowPage("general")
	end
end

function Shell:Toggle()
	if frame and frame:IsShown() then
		frame:Hide()
	else
		Shell:Open()
	end
end

function Shell:IsShown()
	return frame ~= nil and frame:IsShown()
end
