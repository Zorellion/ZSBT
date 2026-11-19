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

	-- Toggle set is module-declared (mod.toggles): each entry makes a
	-- checkbox+hint anchored under the previous one. Classes without a
	-- given toggle never see it.
	local toggleDefs = {
		{ key = "resolveGuardians",
			label = L["Name guardian spells"],
			hint = L["Guardian damage (imps, dreadstalkers, tyrant) is named from summon tracking. Off = those hits fall back to generic pet damage."],
			get = function(prof) return not (prof and prof.classModule and prof.classModule.resolveGuardians == false) end,
			set = function(prof, v) prof.classModule.resolveGuardians = v end,
		},
		{ key = "namePetMelee",
			label = L["Show pet melee hits"],
			hint = L["Pet melee verified by a combat-log line displays as 'Auto Attack'. A stolen MY_PET line could still name a foreign swing."],
			get = function(prof) return prof and prof.classModule and prof.classModule.namePetMelee == true end,
			set = function(prof, v) prof.classModule.namePetMelee = v end,
		},
	}
	local toggles = {}
	local anchor, anchorY = pf, -200
	for _, def in ipairs(toggleDefs) do
		if ZSBT.ClassDB and ZSBT.ClassDB.SupportsToggle
			and ZSBT.ClassDB.SupportsToggle(def.key) then
			local cb = CreateFrame("CheckButton", nil, pf, "InterfaceOptionsCheckButtonTemplate")
			cb:SetPoint("TOPLEFT", anchor, "TOPLEFT", 16, anchorY)
			cb.Text:SetText(def.label)
			cb:SetScript("OnClick", function(self)
				local prof = ZSBT.db and ZSBT.db.profile
				if not prof then return end
				prof.classModule = prof.classModule or {}
				def.set(prof, self:GetChecked() == true)
			end)
			cb.Text:SetTextColor(1, 1, 1)
			local hint = shellFont(pf, 11, COL.dim or COL.text, def.hint)
			hint:SetWidth(580)
			hint:SetJustifyH("LEFT")
			hint:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 26, -6)
			toggles[#toggles + 1] = { def = def, cb = cb, hint = hint }
			anchor, anchorY = hint, -14
		end
	end

	local detail = shellFont(pf, 12, COL.dim or COL.text, "")
	detail:SetWidth(620)
	detail:SetJustifyH("LEFT")
	if toggles[#toggles] then
		detail:SetPoint("TOPLEFT", toggles[#toggles].hint, "BOTTOMLEFT", -26, -18)
	else
		detail:SetPoint("TOPLEFT", pf, "TOPLEFT", 20, -200)
	end

	--------------------------------------------------------------------
	-- Teach-a-spell: drag a spell from the action bar or spellbook onto
	-- the drop box to record its real client spellId. The spell stays on
	-- the bar — ClearCursor ends the drag without a "place" target.
	-- Role decides pipeline treatment: dot = ticks named, channel =
	-- tick window on cast, cast = multi-hit naming budget.
	--------------------------------------------------------------------
	local teachTitle = shellFont(pf, 14, COL.accent,
		L["|cFFFFD100Teach a spell|r"])
	teachTitle:SetPoint("TOPLEFT", detail, "BOTTOMLEFT", 0, -16)

	local drop = CreateFrame("Button", nil, pf, "BackdropTemplate")
	drop:SetSize(44, 44)
	drop:SetPoint("TOPLEFT", teachTitle, "BOTTOMLEFT", 2, -6)
	setBg(drop, COL.track)
	local dropIcon = drop:CreateTexture(nil, "ARTWORK")
	dropIcon:SetPoint("TOPLEFT", 3, -3)
	dropIcon:SetPoint("BOTTOMRIGHT", -3, 3)
	dropIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	dropIcon:SetTexture(136235) -- generic empty-slot look
	local dropLabel = shellFont(pf, 11, COL.dim or COL.text,
		L["Drag a spell from your bar or spellbook here"])
	dropLabel:SetPoint("LEFT", drop, "RIGHT", 10, 10)
	dropLabel:SetWidth(300)
	dropLabel:SetJustifyH("LEFT")

	local roleState = { role = "dot" }
	local roleDefs = {
		{ key = "dot",     label = L["Damage over Time"] },
		{ key = "channel", label = L["Channeled"] },
		{ key = "cast",    label = L["Multi-hit cast"] },
	}
	local roleCbs = {}
	for i, rd in ipairs(roleDefs) do
		local cb = CreateFrame("CheckButton", nil, pf, "InterfaceOptionsCheckButtonTemplate")
		cb:SetSize(24, 24)
		cb:SetPoint("TOPLEFT", drop, "BOTTOMLEFT", -4, -10 - (i - 1) * 28)
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

	local budgetBox = CreateFrame("EditBox", nil, pf, "InputBoxTemplate")
	budgetBox:SetSize(44, 20)
	budgetBox:SetPoint("LEFT", roleCbs[3], "RIGHT", 130, 0)
	budgetBox:SetAutoFocus(false)
	budgetBox:SetNumeric(true)
	budgetBox:SetMaxLetters(3)
	budgetBox:SetText("5")
	budgetBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	local budgetLabel = shellFont(pf, 11, COL.dim or COL.text, L["hits"])
	budgetLabel:SetPoint("LEFT", budgetBox, "RIGHT", 6, 0)

	local confirmFs = shellFont(pf, 11, COL.text, "")
	confirmFs:SetPoint("TOPLEFT", roleCbs[3], "BOTTOMLEFT", 4, -10)

	local taughtTitle = shellFont(pf, 12, COL.accent,
		L["|cFFFFD100Taught spells|r"])
	taughtTitle:SetPoint("TOPLEFT", confirmFs, "BOTTOMLEFT", -4, -14)

	local taughtRows = {}
	local refreshTaught

	local function cursorSpell()
		if type(GetCursorInfo) ~= "function" then return nil end
		local ctype, a1, a2, a3 = GetCursorInfo()
		if ctype ~= "spell" then return nil end
		for _, v in ipairs({ a1, a3, a2 }) do
			if type(v) == "number" and v > 0 then
				local nm = ZSBT.CleanSpellName and ZSBT.CleanSpellName(v)
				if type(nm) == "string" and nm ~= "" then
					return v, nm
				end
			end
		end
		return nil
	end

	local function tryTeach()
		local sid, nm = cursorSpell()
		if not sid then return end
		if ClearCursor then ClearCursor() end
		local budget = tonumber(budgetBox:GetText())
		if ZSBT.ClassDB and ZSBT.ClassDB.TeachSpell
			and ZSBT.ClassDB.TeachSpell(sid, nm, roleState.role, budget) then
			confirmFs:SetText(("|cFF55FF55+%s|r (%d) → %s")
				:format(tostring(nm), sid, tostring(roleState.role)))
			local tex = C_Spell and C_Spell.GetSpellTexture
				and C_Spell.GetSpellTexture(sid)
			if tex then dropIcon:SetTexture(tex) end
			if refreshTaught then refreshTaught() end
		end
	end
	drop:SetScript("OnReceiveDrag", tryTeach)
	drop:SetScript("OnClick", tryTeach)

	refreshTaught = function()
		local list = (ZSBT.ClassDB and ZSBT.ClassDB.TaughtList)
			and ZSBT.ClassDB.TaughtList() or {}
		local need = math.max(#taughtRows, #list)
		for i = 1, need do
			local row = taughtRows[i]
			local e = list[i]
			if e then
				if not row then
					row = {}
					row.fs = shellFont(pf, 11, COL.text, "")
					row.fs:SetPoint("TOPLEFT", taughtTitle, "BOTTOMLEFT", 10, -6 - (i - 1) * 16)
					row.rm = CreateFrame("Button", nil, pf)
					row.rm:SetSize(16, 16)
					row.rm:SetPoint("LEFT", row.fs, "RIGHT", 8, 0)
					local rmT = shellFont(row.rm, 11, COL.dim or COL.text, "×")
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
				local label = ("%s (%d) · %s")
					:format(tostring(e.name), e.sid, tostring(e.role))
				if e.role == "cast" and e.budget then
					label = label .. (" ×%d"):format(tonumber(e.budget) or 0)
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
	end

	local function refresh()
		local cdb = ZSBT.ClassDB
		local mod = cdb and cdb.ActiveModule and cdb.ActiveModule()
		local tag = cdb and cdb.PlayerTag and cdb.PlayerTag() or "?"
		local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
		local st = ec and ec.ClassModuleState and ec:ClassModuleState() or nil

		if not mod then
			body:SetText(L["No class module is loaded for this character."])
			for _, t in ipairs(toggles) do t.cb:Hide(); t.hint:Hide() end
			detail:SetText("")
			refreshTaught()
			return
		end
		local prof = ZSBT.db and ZSBT.db.profile
		for _, t in ipairs(toggles) do
			t.cb:Show(); t.hint:Show()
			t.cb:SetChecked(t.def.get(prof))
		end

		local autoVetoed = cdb.VetoAuto and cdb.VetoAuto() == true
		local lines = {
			("|cFFFFD100Module:|r %s"):format(tostring(tag)),
			("|cFFFFD100Auto-attacks:|r %s"):format(autoVetoed and "vetoed (class never swings)" or "allowed"),
			("|cFFFFD100PLAYER_SWING:|r %s"):format(st and st.swingSupported and "available" or "unavailable (Retail)"),
			("|cFFFFD100Learned spell schools:|r %d"):format(st and st.learnedCount or 0),
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
				d[#d + 1] = L["Learned:"] .. " " .. table.concat(names, ", ")
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
		if mod then
			local names = {}
			for _, e in ipairs(mod.dots or {}) do
				names[#names + 1] = e.names and e.names[1] or "?"
			end
			if #names > 0 then
				d[#d + 1] = L["Dots:"] .. " " .. table.concat(names, ", ")
			end
			names = {}
			for _, e in ipairs(mod.channels or {}) do
				names[#names + 1] = e.names and e.names[1] or "?"
			end
			if #names > 0 then
				d[#d + 1] = L["Channels:"] .. " " .. table.concat(names, ", ")
			end
		end
		detail:SetText(table.concat(d, "\n"))
		refreshTaught()
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
