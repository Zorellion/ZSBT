-- Combat-log line classifier.
--
-- COMBAT_LOG_MESSAGE delivers (text, r, g, b, order). The text payload is
-- never read; only the line colour is used, matched against the palette that
-- the "ZSBT" combat-log filter writes into Blizzard_CombatLog_Filters at
-- logout. When the user's active filter isn't ours the colours won't match
-- the palette and the signal stays silent — no runtime verification needed.
--
-- Used to confirm/veto periodic-tick attribution: a hit paired with a
-- tick-coloured line is certainly a DoT tick; one paired with a direct or
-- swing line is not.

local ADDON_NAME, ZSBT = ...

local CL = {}
ZSBT.CombatLogLines = CL

local function clDbg(msg)
	local Addon = ZSBT and ZSBT.Addon
	if Addon and Addon.Dbg then
		Addon:Dbg("outgoing", 4, msg)
	end
end

local FILTER_NAME = "ZSBT"

-- Our own palette: each value is written into the filter's eventColoring and
-- matched here with a small tolerance (colours may be gamma-adjusted).
local KIND_COLORS = {
	direct = { 0.95, 0.55, 0.15 },
	tick   = { 0.65, 0.45, 1.00 },
	melee  = { 0.90, 0.90, 0.90 },
	ranged = { 0.80, 0.60, 0.40 },
	heal   = { 0.40, 1.00, 0.50 },
	hot    = { 0.50, 0.85, 0.60 },
}

local EVENT_KINDS = {
	SPELL_DAMAGE            = "direct",
	SPELL_LEECH             = "direct",
	SPELL_DRAIN             = "direct",
	SPELL_BUILDING_DAMAGE   = "direct",
	SPELL_PERIODIC_DAMAGE   = "tick",
	SPELL_PERIODIC_LEECH    = "tick",
	SWING_DAMAGE            = "melee",
	RANGE_DAMAGE            = "ranged",
	DAMAGE_SHIELD           = "direct",
	DAMAGE_SPLIT            = "direct",
	ENVIRONMENTAL_DAMAGE    = "direct",
	SPELL_HEAL              = "heal",
	SPELL_PERIODIC_HEAL     = "hot",
}

local COLOR_TOLERANCE = 0.02
local LINE_KEEP_SEC   = 2.5
local LINE_MAX        = 32
local SIGNAL_WINDOW   = 4.0

CL._lines = {}
CL._frame = nil

local function classifyColor(r, g, b)
	for kind, rgb in pairs(KIND_COLORS) do
		if math.abs(r - rgb[1]) <= COLOR_TOLERANCE
			and math.abs(g - rgb[2]) <= COLOR_TOLERANCE
			and math.abs(b - rgb[3]) <= COLOR_TOLERANCE then
			return kind
		end
	end
	return nil
end

local function isSafeChannel(v)
	return type(v) == "number" and (not ZSBT.IsSafeNumber or ZSBT.IsSafeNumber(v))
end

-- Record one combat-log line. Only classified (palette-matching) lines are
-- stored, so the buffer stays tiny when the signal isn't active.
function CL:RecordLine(r, g, b)
	if not (isSafeChannel(r) and isSafeChannel(g) and isSafeChannel(b)) then
		return
	end
	local kind = classifyColor(r, g, b)
	if not kind then return end
	if not self._dbgFirstLine then
		self._dbgFirstLine = true
		clDbg(("[CL] first classified line kind=%s rgb=%.3f,%.3f,%.3f"):format(kind, r, g, b))
	end
	local t = GetTime()
	local lines = self._lines
	-- Lines are append-ordered by time; trim expired entries from the front.
	while #lines > 0 and t - lines[1].at > LINE_KEEP_SEC do
		table.remove(lines, 1)
	end
	if #lines >= LINE_MAX then
		table.remove(lines, 1)
	end
	lines[#lines + 1] = { at = t, kind = kind }
	if kind == "tick" then
		self._lastTickAt = t
		clDbg(("CLM_TICK t=%.2f"):format(t))
	end
end

-- Kind of the closest recorded line to a hit timestamp, or nil.
function CL:ClosestKind(tHit, window)
	local best, bestDt
	for i = 1, #self._lines do
		local l = self._lines[i]
		local dt = math.abs(l.at - tHit)
		if dt <= window and (bestDt == nil or dt < bestDt) then
			best, bestDt = l.kind, dt
		end
	end
	return best
end

-- True when any palette-matching line was seen recently — i.e. the combat-log
-- filter is installed and active, so line-based decisions are meaningful.
function CL:SignalSeen()
	local t = GetTime()
	for i = #self._lines, 1, -1 do
		local l = self._lines[i]
		if t - l.at <= SIGNAL_WINDOW then
			return true
		end
	end
	return false
end

-- Deep copy for saved-variable tables.
local function copyValue(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, val in pairs(v) do out[k] = copyValue(val) end
	return out
end

-- Write (or refresh) the "ZSBT" combat-log filter at logout. Filter settings
-- must come from saved variables on disk — applying them mid-session can
-- taint Blizzard's secure combat-log processor — so this runs on PLAYER_LOGOUT
-- and takes effect next login.
function CL:InstallFilterAtLogout()
	local saved = _G.Blizzard_CombatLog_Filters
	if type(saved) ~= "table" or type(saved.filters) ~= "table" then return end

	-- Clone the user's current filter so the log keeps showing everything it
	-- did; we only overlay event colours for the kinds we classify.
	local current = saved.currentFilter
	local template = (type(current) == "number" and saved.filters[current]) or saved.filters[1]
	if type(template) ~= "table" then return end

	local filter = copyValue(template)
	filter.name = FILTER_NAME
	filter.quickButtonName = nil
	filter.hasQuickButton = false

	filter.settings = filter.settings or {}
	filter.settings.lineColoring = true
	filter.settings.lineColorPriority = 3
	filter.settings.lineHighlighting = false

	filter.colors = filter.colors or {}
	filter.colors.eventColoring = filter.colors.eventColoring or {}
	for event, kind in pairs(EVENT_KINDS) do
		local c = KIND_COLORS[kind]
		filter.colors.eventColoring[event] = { r = c[1], g = c[2], b = c[3], a = 1 }
	end

	local index
	for i, f in ipairs(saved.filters) do
		if type(f) == "table" and f.name == FILTER_NAME then
			index = i
			break
		end
	end
	index = index or (#saved.filters + 1)
	saved.filters[index] = filter
	-- The filter must be active for its colours to apply to log lines.
	saved.currentFilter = index
	clDbg(("[CL] filter '%s' written at index %d"):format(FILTER_NAME, index))
end

-- One-time login check: is our filter actually the active one, and does it
-- carry the event colours? Printed via the outgoing debug channel.
function CL:VerifyFilterAtLogin()
	local saved = _G.Blizzard_CombatLog_Filters
	if type(saved) ~= "table" or type(saved.filters) ~= "table" then
		clDbg("[CL] login verify: no Blizzard_CombatLog_Filters saved vars")
		return
	end
	local cur = saved.currentFilter
	local f = type(cur) == "number" and saved.filters[cur] or nil
	-- Dump the raw structure once: filter container type, count, currentFilter
	-- type, and the active filter's relevant fields. Saved vars are ours to
	-- read — no secret-value concerns.
	local n = 0
	for _ in pairs(saved.filters) do n = n + 1 end
	clDbg(("[CL] login verify: filters type=%s count=%d currentFilter=%s(%s)")
		:format(type(saved.filters), n, tostring(cur), type(cur)))
	if type(f) ~= "table" then
		clDbg("[CL] login verify: currentFilter invalid")
		return
	end
	local ec = f.colors and f.colors.eventColoring
	local spd = type(ec) == "table" and ec.SPELL_PERIODIC_DAMAGE or nil
	local spdStr = "nil"
	if type(spd) == "table" then
		spdStr = ("r=%s g=%s b=%s"):format(tostring(spd.r), tostring(spd.g), tostring(spd.b))
	end
	clDbg(("[CL] login verify: active filter='%s' lineColoring=%s spdColor={%s} keys=%s")
		:format(tostring(f.name), tostring(f.settings and f.settings.lineColoring), spdStr,
			type(ec) == "table" and "table" or type(ec)))
end

if not CL._frame then
	CL._frame = CreateFrame("Frame")
	CL._frame:RegisterEvent("PLAYER_LOGOUT")
	CL._frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	CL._frame:SetScript("OnEvent", function(_, event)
		if event == "PLAYER_LOGOUT" then
			CL:InstallFilterAtLogout()
		elseif event == "PLAYER_ENTERING_WORLD" then
			CL:VerifyFilterAtLogin()
		end
	end)
end

clDbg("[CL] module loaded")

return CL
