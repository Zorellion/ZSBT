------------------------------------------------------------------------
-- ZSBT - Outgoing Probe / Replay Harness (UI/UX Validation)
--
-- Purpose:
--   - Capture *real* outgoing events (from Parser.Outgoing) into a ring buffer
--   - Replay captured events through display routing to validate the Outgoing UI
--
-- Scope rules for this probe:
--   - Outgoing = player-only. Pet/guardian damage must NOT appear here.
--   - This is NOT the engine. No attribution beyond player-only flag filtering.
--   - No spam control, merging, throttling, or learning.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.Core = ZSBT.Core or {}
ZSBT.Core.OutgoingProbe = ZSBT.Core.OutgoingProbe or {}
local Probe = ZSBT.Core.OutgoingProbe
local Addon = ZSBT.Addon

-- Internal state
Probe._initialized = Probe._initialized or false
Probe._capturing = Probe._capturing or false
Probe._replaying = Probe._replaying or false
Probe._captureEnds = Probe._captureEnds or 0
Probe._ticker = Probe._ticker or nil

-- School color lookup (shared with Incoming_Probe)
local function SchoolColorFromMask(mask)
    if not ZSBT.IsSafeNumber(mask) then return nil end
    local band = (bit and bit.band) or (bit32 and bit32.band)
    if type(band) ~= "function" then return nil end
    if mask > 0 and band(mask, mask - 1) ~= 0 then return nil end
    if mask == ZSBT.SCHOOL_PHYSICAL then return nil end
    if mask == ZSBT.SCHOOL_HOLY    then return {r = 1.00, g = 0.90, b = 0.50} end
    if mask == ZSBT.SCHOOL_FIRE    then return {r = 1.00, g = 0.35, b = 0.20} end
    if mask == ZSBT.SCHOOL_NATURE  then return {r = 0.30, g = 1.00, b = 0.30} end
    if mask == ZSBT.SCHOOL_FROST   then return {r = 0.50, g = 0.85, b = 1.00} end
    if mask == ZSBT.SCHOOL_SHADOW  then return {r = 0.65, g = 0.45, b = 1.00} end
    if mask == ZSBT.SCHOOL_ARCANE  then return {r = 0.60, g = 0.60, b = 1.00} end
    return nil
end

Probe._maxBuffer = Probe._maxBuffer or 300
Probe._buffer = Probe._buffer or {}
Probe._bufHead = Probe._bufHead or 0
Probe._bufCount = Probe._bufCount or 0

local function Now() return (GetTime and GetTime()) or 0 end

local function Debug(level, ...)
    if Addon and Addon.DebugPrint then Addon:DebugPrint(level, ...) end
end

local function Dbg4(prefix, msg)
	local dbg = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.debugLevel or 0
	if dbg >= 4 and Addon and Addon.Print then
		Addon:Print(prefix .. " " .. msg)
	end
end

Probe._spellRuleLastAt = Probe._spellRuleLastAt or {}
Probe._recentSpellStats = Probe._recentSpellStats or {}
Probe._recentSpellMax = Probe._recentSpellMax or 60

local function PushEvent(evt)
    Probe._bufHead = (Probe._bufHead % Probe._maxBuffer) + 1
    Probe._buffer[Probe._bufHead] = evt
    Probe._bufCount = math.min(Probe._bufCount + 1, Probe._maxBuffer)
end

local function SnapshotBuffer()
    local out = {}
    if Probe._bufCount == 0 then return out end

    local start = Probe._bufHead - Probe._bufCount + 1
    for i = 0, Probe._bufCount - 1 do
        local idx = start + i
        while idx <= 0 do idx = idx + Probe._maxBuffer end
        while idx > Probe._maxBuffer do idx = idx - Probe._maxBuffer end
        out[#out + 1] = Probe._buffer[idx]
    end
    return out
end

function Probe:Init()
    if self._initialized then return end
    self._initialized = true
    Debug(1, "Core.OutgoingProbe:Init()")
end

function Probe:IsCapturing() return self._capturing == true end
function Probe:IsReplaying() return self._replaying == true end

function Probe:ResetCapture()
    self._buffer = {}
    self._bufHead = 0
    self._bufCount = 0
end

function Probe:StartCapture(seconds)
    self:Init()

    if self._capturing then return end
    self:StopReplay(false)

    seconds = tonumber(seconds) or 30
    if seconds < 1 then seconds = 1 end
    if seconds > 120 then seconds = 120 end

    self:ResetCapture()

    self._capturing = true
    self._captureEnds = Now() + seconds

    Debug(1, ("Core.OutgoingProbe:StartCapture(%ss)"):format(seconds))
    if Addon and Addon.Print then
        Addon:Print(
            ("Outgoing probe capture started (%ss). Auto-attack and cast a few spells; do at least one heal if possible.")
                :format(seconds))
    end

    C_Timer.After(seconds, function()
        if Probe and Probe._capturing then Probe:StopCapture(true) end
    end)
end

function Probe:StopCapture(auto)
    if not self._capturing then return end
    self._capturing = false
    self._captureEnds = 0

    Debug(1, "Core.OutgoingProbe:StopCapture()")
    if Addon and Addon.Print then
        Addon:Print(("Outgoing probe capture %s. Captured %d events.")
                        :format(auto and "ended" or "stopped", self._bufCount))
    end
end

function Probe:Replay(speed)
    self:Init()
    if self._replaying then return end
    self:StopCapture(false)

    local events = SnapshotBuffer()
    if #events == 0 then
        if Addon and Addon.Print then
            Addon:Print("Outgoing probe has no captured events to replay. Capture first.")
        end
        return
    end

    speed = tonumber(speed) or 1.0
    if speed < 0.25 then speed = 0.25 end
    if speed > 4.0 then speed = 4.0 end

    self._replaying = true
    local i = 1

    Debug(1, ("Core.OutgoingProbe:Replay(speed=%s) events=%d"):format(speed, #events))
    if Addon and Addon.Print then
        Addon:Print(("Outgoing probe replay started (%d events, speed x%.2f).")
                        :format(#events, speed))
    end

    local interval = 0.20 / speed
    self._ticker = C_Timer.NewTicker(interval, function()
        if not Probe or not Probe._replaying then return end
        local evt = events[i]
        if evt then
            Probe:ProcessOutgoingEvent(evt, true)
            i = i + 1
        end
        if i > #events then Probe:StopReplay(true) end
    end)
end

function Probe:StopReplay(auto)
    if not self._replaying then return end
    self._replaying = false

    if self._ticker then
        self._ticker:Cancel()
        self._ticker = nil
    end

    Debug(1, "Core.OutgoingProbe:StopReplay()")
    if Addon and Addon.Print then
        Addon:Print(("Outgoing probe replay %s."):format(auto and "completed" or "stopped"))
    end
end

function Probe:GetStatusLine()
    local cap = {}
    cap.bufferCount = self._bufCount or 0
    cap.bufferMax = self._maxBuffer or 0
    cap.capturing = self._capturing == true
    cap.replaying = self._replaying == true
    return cap
end

-- evt contract from Parser.Outgoing:
-- {
--   ts=number,
--   kind="damage"|"heal",
--   amount=number,
--   overheal=number|nil,
--   isAuto=true|false,
--   isCrit=true|false,
--   spellID=number|nil,
--   spellName=string|nil,
--   targetName=string|nil,
--   schoolMask=number|nil,
-- }
function Probe:OnOutgoingDetected(evt)
    if not evt or type(evt) ~= "table" then return end

    if self._capturing then
        PushEvent(evt)
    end

    -- Always emit to display when the addon is enabled — not just during capture.
    self:ProcessOutgoingEvent(evt, false)
end

function Probe:ProcessOutgoingEvent(evt, isReplay)
    if not ZSBT.db or not ZSBT.db.profile or not ZSBT.db.profile.outgoing then
        return
    end

    local prof = ZSBT.db.profile.outgoing
    local kind = evt.kind
    if kind ~= "damage" and kind ~= "heal" and kind ~= "miss" then return end

	local resolvedSpellID = nil
	local spellSource = "NONE"
	local lastAge = nil
	local isSecret = (evt and evt.isSecret == true)
	local isEmpty = (evt and evt.rawPipeId == nil and evt.amount == nil and evt.amountText == nil)
	if evt and type(evt.spellId) == "number" and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(evt.spellId) then
		resolvedSpellID = evt.spellId
		spellSource = "EVENT"
	elseif ZSBT.Parser and ZSBT.Parser.EventCollector then
		local ec = ZSBT.Parser.EventCollector
		local sid = ec and ec._lastPlayerSpellId
		local sat = ec and ec._lastPlayerSpellAt
		local t = Now()
		if type(sat) == "number" then
			lastAge = t - sat
		end
		if (evt and evt.allowLastCast == true)
			and (not isSecret) and (not isEmpty) and (evt and evt.isAuto ~= true)
			and type(sid) == "number" and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(sid)
			and type(sat) == "number" and (t - sat) < 1.5 then
			resolvedSpellID = sid
			spellSource = "LAST_CAST"
		end
	end

	Dbg4("|cFFCC66FF[OUTDBG]|r", ("Probe kind=%s amt=%s rawPipeId=%s evtSpellId=%s resolved=%s source=%s lastAge=%s target=%s crit=%s auto=%s secret=%s empty=%s")
		:format(
			tostring(kind),
			tostring(evt and (evt.amountText or evt.amount)),
			tostring(evt and evt.rawPipeId),
			tostring(evt and evt.spellId),
			tostring(resolvedSpellID),
			tostring(spellSource),
			tostring(lastAge),
			tostring(evt and evt.targetName),
			tostring(evt and evt.isCrit == true),
			tostring(evt and evt.isAuto == true),
			tostring(isSecret),
			tostring(isEmpty)
		))

	-- Secret/empty events are used for correlation diagnostics only; they should
	-- not consume throttle budgets or be attributed to "last cast".
	if isSecret or isEmpty then
		return
	end

	if evt and type(evt) == "table" and type(resolvedSpellID) == "number" and (kind == "damage" or kind == "heal") then
		local sid = resolvedSpellID
		local t = Now()
		local st = self._recentSpellStats[sid]
		if not st then
			st = { count = 0, lastAt = 0 }
			self._recentSpellStats[sid] = st
		end
		st.count = (st.count or 0) + 1
		st.lastAt = t

		local n = 0
		for _ in pairs(self._recentSpellStats) do n = n + 1 end
		if n > (self._recentSpellMax or 60) then
			local oldestId, oldestAt
			for id, v in pairs(self._recentSpellStats) do
				local at = v and v.lastAt or 0
				if not oldestAt or at < oldestAt then
					oldestAt = at
					oldestId = id
				end
			end
			if oldestId then
				self._recentSpellStats[oldestId] = nil
			end
		end
	end

    -- Miss events: display immediately with gray color
    if kind == "miss" then
        if prof.damage and prof.damage.showMisses == false then
            return
        end
        local conf = prof.damage
        if not conf or not conf.enabled then return end
        local area = conf.scrollArea or "Outgoing"
        local missText = ZSBT.IsSafeString(evt.amountText) and evt.amountText or "Miss"
        local color = {r = 0.70, g = 0.70, b = 0.70}
        local meta = { probe = true, kind = kind }
        if ZSBT.DisplayText then
            ZSBT.DisplayText(area, missText, color, meta)
        elseif ZSBT.Core and ZSBT.Core.Display and ZSBT.Core.Display.Emit then
            ZSBT.Core.Display:Emit(area, missText, color, meta)
        end
        return
    end

    -- RAW PIPE: retrieve untouched secret value for direct SetText()
    local rawPipeValue = nil
    if evt.rawPipeId and ZSBT.Parser and ZSBT.Parser.EventCollector then
        local ec = ZSBT.Parser.EventCollector
        rawPipeValue = ec._rawPipe[evt.rawPipeId]
        ec._rawPipe[evt.rawPipeId] = nil  -- consume it
    end

    -- Suppress training dummy damage if enabled
    local spam = ZSBT.db.profile.spamControl
    if spam and spam.suppressDummyDamage and ZSBT.IsTrainingDummy("target") then
        return
    end

		local sr = spam and spam.spellRules
		local routing = spam and spam.routing
		local defaultRuleArea = nil
		if type(resolvedSpellID) == "number" and sr and next(sr) ~= nil and routing and type(routing.spellRulesDefaultArea) == "string" and routing.spellRulesDefaultArea ~= "" then
			defaultRuleArea = routing.spellRulesDefaultArea
		end
		local ruleArea = nil
		if sr and type(resolvedSpellID) == "number" then
			local rule = sr[resolvedSpellID]
			if type(rule) == "table" and rule.enabled ~= false then
				ruleArea = (type(rule.scrollArea) == "string" and rule.scrollArea ~= "") and rule.scrollArea or nil
				local throttleSec = tonumber(rule.throttleSec) or 0
				if throttleSec > 0 then
					local t = Now()
					local last = self._spellRuleLastAt[resolvedSpellID]
					if last and (t - last) < throttleSec then
						return
					end
					self._spellRuleLastAt[resolvedSpellID] = t
				end
			end
		end

    -- Resolve display amount using the safe helper.
    local displayText, isTainted = ZSBT.ResolveDisplayAmount(evt.amount, evt.amountText, kind)

    if kind == "damage" then
        local conf = prof.damage
        if not conf or not conf.enabled then return end

        -- Auto-attack filtering (uses safe booleans, not tainted strings).
        if evt.isAuto == true then
            local mode = tostring(conf.autoAttackMode or "Show All")
            if mode == "Hide" then return end
            if mode == "Show Only Crits" and evt.isCrit ~= true then return end
        end

        if type(displayText) == "nil" and rawPipeValue == nil then return end

        -- Apply thresholds: use raw pipe value if it's a clean number,
        -- otherwise use evt.amount. Skip entirely if both are tainted (dungeon).
        local thresholdAmt = nil
        if rawPipeValue ~= nil and ZSBT.IsSafeNumber(rawPipeValue) then
            thresholdAmt = rawPipeValue
        elseif not isTainted and ZSBT.IsSafeNumber(evt.amount) then
            thresholdAmt = evt.amount
        end

        if thresholdAmt then
            if thresholdAmt <= 0 then return end
            -- Per-category threshold (Outgoing tab)
            local minT = tonumber(conf.minThreshold) or 0
            if minT > 0 and thresholdAmt < minT then return end
            -- Global spam control thresholds (Spam Control tab)
            local spam = ZSBT.db.profile.spamControl and ZSBT.db.profile.spamControl.throttling
            if spam then
                if spam.minDamage and spam.minDamage > 0 and thresholdAmt < spam.minDamage then return end
                if evt.isAuto and spam.hideAutoBelow and spam.hideAutoBelow > 0 and thresholdAmt < spam.hideAutoBelow then return end
            end
        end

        -- Use raw pipe value if available, otherwise processed text.
        -- Convert clean raw pipe numbers to strings so merge buffer can work.
        local text
        if rawPipeValue ~= nil then
            if ZSBT.IsSafeNumber(rawPipeValue) then
                if ZSBT.FormatDisplayAmount then
                    text = ZSBT.FormatDisplayAmount(rawPipeValue)
                else
                    text = tostring(math.floor(rawPipeValue + 0.5))
                end
            else
                text = rawPipeValue  -- tainted, pass through for pcall SetText
            end
        else
            text = displayText
        end

        -- Append spell name only if text is a clean safe string (not raw pipe).
		local trustedForSpellLabel = (evt and (
			evt.amountSource == "COMBAT_TEXT"
			or evt.amountSource == "DAMAGE_METER"
			or evt.amountSource == "COMBAT_LOG"
			or evt.amountSource == "UNIT_COMBAT_DOT"
			or evt.amountSource == "UNIT_COMBAT_BEST"
			or evt.amountSource == "UNIT_COMBAT_PHYSICAL"
			or evt.amountSource == "UNIT_COMBAT_AUTO_FALLBACK"
		))
		if rawPipeValue == nil and prof.showSpellNames and evt.isAuto ~= true and trustedForSpellLabel then
			local cleanName = ZSBT.CleanSpellName(evt.spellId)
			if cleanName and ZSBT.IsSafeString(text) then
				text = text .. " " .. cleanName
			end
		end

        -- Append target name with class color (only if safe/clean).
        if conf.showTargets and ZSBT.IsSafeString(evt.targetName) and evt.targetName ~= "" then
            local coloredName = ZSBT.ClassColorName(evt.targetName, "target") or evt.targetName
            text = text .. " -> " .. coloredName
        end

        local color = {r = 1.00, g = 0.25, b = 0.25}  -- default red
		-- School color if enabled
		if prof.useSchoolColors then
			if ZSBT.IsSafeNumber(evt.schoolMask) then
				local schoolColor = SchoolColorFromMask(evt.schoolMask)
				if schoolColor then
					color = schoolColor
				else
					-- Physical or unknown school: white/neutral
					color = {r = 1.00, g = 1.00, b = 1.00}
				end
			else
				color = {r = 1.00, g = 1.00, b = 1.00}
			end
		else
			local c = prof.customDamageColor
			if type(c) == "table" and type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
				if not (c.r == 1 and c.g == 1 and c.b == 1) then
					color = { r = c.r, g = c.g, b = c.b }
				end
			end
		end
		local critConf = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.outgoing and ZSBT.db.profile.outgoing.crits
		-- Crit color: when routing to crit area, use configured crit color (if set)
		if evt.isCrit and critConf and critConf.enabled == true and type(critConf.scrollArea) == "string" and critConf.scrollArea ~= "" then
			local cc = critConf.color
			if type(cc) == "table" and type(cc.r) == "number" and type(cc.g) == "number" and type(cc.b) == "number" then
				color = { r = cc.r, g = cc.g, b = cc.b }
			else
				color = {r = 1.00, g = 1.00, b = 0.00}
			end
		elseif evt.isCrit then
			-- Default crit color: yellow for damage crits (overrides school)
			color = {r = 1.00, g = 1.00, b = 0.00}
		end
        local meta = {
            probe = true,
            replay = isReplay == true,
            stream = "outgoing",
            kind = kind,
            isAuto = evt.isAuto == true,
            isCrit = evt.isCrit == true,
            school = evt.schoolMask,
        }

        -- Dungeon-safe visual filtering: pass tainted value + threshold
        if rawPipeValue ~= nil and not ZSBT.IsSafeNumber(rawPipeValue) then
            local catMin = tonumber(conf.minThreshold) or 0
            local spam = ZSBT.db.profile.spamControl and ZSBT.db.profile.spamControl.throttling
            local globalMin = 0
            if spam then
                globalMin = tonumber(spam.minDamage) or 0
                if evt.isAuto and spam.hideAutoBelow and spam.hideAutoBelow > 0 then
                    globalMin = math.max(globalMin, tonumber(spam.hideAutoBelow) or 0)
                end
            end
            local effectiveThreshold = math.max(catMin, globalMin)
            if effectiveThreshold > 0 then
                meta.secretRawValue = rawPipeValue
                meta.filterThreshold = effectiveThreshold
            end
        end

        -- Attach spell icon if enabled. Never show an ability icon for auto-attacks
        -- (auto-attack correlation can be ambiguous and would cause "stuck" icons).
        				local trustedForSpellIcon = (evt and (
					evt.amountSource == "COMBAT_TEXT"
					or evt.amountSource == "DAMAGE_METER"
					or evt.amountSource == "COMBAT_LOG"
					or evt.amountSource == "UNIT_COMBAT_DOT"
					or evt.amountSource == "UNIT_COMBAT_BEST"
					or evt.amountSource == "UNIT_COMBAT_PHYSICAL"
					or evt.amountSource == "UNIT_COMBAT_AUTO_FALLBACK"
				)) or (evt and evt.isPeriodic == true)
		if prof.showSpellIcons and evt.isAuto ~= true and evt.spellId and trustedForSpellIcon then
			local tex = ZSBT.CleanSpellIcon(evt.spellId)
			if tex then meta.spellIcon = tex end
		end

        local areaToUse = ruleArea or conf.scrollArea or defaultRuleArea or "Outgoing"
        if evt.isCrit and critConf and critConf.enabled == true and type(critConf.scrollArea) == "string" and critConf.scrollArea ~= "" then
            areaToUse = critConf.scrollArea
            meta.critRouted = true
            if critConf.sticky ~= false then
                meta.stickyCrit = true
                meta.stickyScale = 1.12
                meta.stickyDurationMult = 1.25
            end
        elseif evt.isCrit and critConf and critConf.sticky ~= false then
            -- Even without routing, allow sticky styling when enabled.
            meta.stickyCrit = true
            meta.stickyScale = 1.12
            meta.stickyDurationMult = 1.25
        end

        local dbg = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.debugLevel or 0
        if dbg >= 3 and Addon and Addon.Print then
            local function safeDbg(v)
                if v == nil then return "nil" end
                if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
                if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
                return "<secret>"
            end
            Addon:Print("|cFF00CC66[OUT]|r " .. safeDbg(areaToUse) .. " " .. safeDbg(evt.spellId) .. " " .. safeDbg(text))
        end

        if ZSBT.DisplayText then
            ZSBT.DisplayText(areaToUse, text, color, meta)
        elseif ZSBT.Core and ZSBT.Core.Display and ZSBT.Core.Display.Emit then
            ZSBT.Core.Display:Emit(areaToUse, text, color, meta)
        end

    else
        local conf = prof.healing
        if not conf or not conf.enabled then return end

        local areaToUse = ruleArea or conf.scrollArea or defaultRuleArea or "Outgoing"
        local text

        local dbg = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.debugLevel or 0
        if dbg >= 4 then
            local at = evt and evt.amountText
            if ZSBT.IsSafeString(at) then
                local cleaned = at:gsub(",", "")
                if tonumber(cleaned) == nil then
                    Dbg4("|cFFCC66FF[OUTDBG]|r", ("HEAL_NONNUM amountText=%s amount=%s rawPipeId=%s tainted=%s")
                        :format(tostring(at), tostring(evt and evt.amount), tostring(evt and evt.rawPipeId), tostring(isTainted)))
                end
            end
        end

        -- Try raw pipe first (same as damage path)
        local healAmt = nil
        if rawPipeValue ~= nil and ZSBT.IsSafeNumber(rawPipeValue) then
            healAmt = rawPipeValue
        elseif not isTainted and ZSBT.IsSafeNumber(evt.amount) then
            healAmt = evt.amount
        end

        if healAmt and healAmt > 50000 then
            if dbg >= 4 then
                Dbg4("|cFFCC66FF[OUTDBG]|r", ("OUT_HEAL_CLAMP amt=%s rawPipeId=%s spellId=%s target=%s")
                    :format(tostring(healAmt), tostring(evt and evt.rawPipeId), tostring(evt and evt.spellId), tostring(evt and evt.targetName)))
            end
            return
        end

        if healAmt then
            if healAmt <= 0 then return end

            local over = tonumber(evt.overheal) or 0
            if over < 0 then over = 0 end

            local displayAmt = healAmt
            if not conf.showOverheal then
                displayAmt = healAmt - over
            end
            if displayAmt <= 0 then return end

            -- Per-category threshold
            local minT = tonumber(conf.minThreshold) or 0
            if minT > 0 and displayAmt < minT then return end

            -- Global spam control threshold
            local spam = ZSBT.db.profile.spamControl and ZSBT.db.profile.spamControl.throttling
            if spam and spam.minHealing and spam.minHealing > 0 and displayAmt < spam.minHealing then return end

            if ZSBT.FormatDisplayAmount then
                text = ZSBT.FormatDisplayAmount(displayAmt)
            else
                text = tostring(math.floor(displayAmt + 0.5))
            end

            if prof.showSpellNames then
                local cleanName = ZSBT.CleanSpellName(evt.spellId)
                if cleanName then
                    text = text .. " " .. cleanName
                end
            end

            if conf.showOverheal and over > 0 then
                local overText
                if ZSBT.FormatDisplayAmount then
                    overText = ZSBT.FormatDisplayAmount(over)
                else
                    overText = tostring(math.floor(over + 0.5))
                end
                text = text .. " (OH " .. overText .. ")"
            end
        elseif rawPipeValue ~= nil then
            -- Tainted raw pipe (dungeon) — pass through
            text = rawPipeValue
        elseif isTainted and displayText then
            text = displayText
        else
            return
        end

        local color = {r = 0.20, g = 1.00, b = 0.20}
		if not prof.useSchoolColors then
			local c = prof.customHealingColor
			if type(c) == "table" and type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
				if not (c.r == 1 and c.g == 1 and c.b == 1) then
					color = { r = c.r, g = c.g, b = c.b }
				end
			end
		end
		local critConf = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.outgoing and ZSBT.db.profile.outgoing.crits
		-- Crit color: when routing to crit area, use configured crit color (if set)
		if evt.isCrit and critConf and critConf.enabled == true and type(critConf.scrollArea) == "string" and critConf.scrollArea ~= "" then
			local cc = critConf.color
			if type(cc) == "table" and type(cc.r) == "number" and type(cc.g) == "number" and type(cc.b) == "number" then
				color = { r = cc.r, g = cc.g, b = cc.b }
			else
				color = {r = 0.20, g = 1.00, b = 0.40}
			end
		elseif evt.isCrit then
			-- Default crit color: bright green for heal crits
			color = {r = 0.20, g = 1.00, b = 0.40}
		end
        local meta = {
            probe = true,
            replay = isReplay == true,
            stream = "outgoing",
            kind = kind,
            isCrit = evt.isCrit == true,
            school = evt.schoolMask,
        }

        if evt.isCrit and critConf and critConf.enabled == true and type(critConf.scrollArea) == "string" and critConf.scrollArea ~= "" then
			areaToUse = critConf.scrollArea
			meta.critRouted = true
			if critConf.sticky ~= false then
				meta.stickyCrit = true
				meta.stickyScale = 1.12
				meta.stickyDurationMult = 1.25
            end
        elseif evt.isCrit and critConf and critConf.sticky ~= false then
            meta.stickyCrit = true
            meta.stickyScale = 1.12
            meta.stickyDurationMult = 1.25
        end

        -- Dungeon-safe visual filtering for heals
        if rawPipeValue ~= nil and not ZSBT.IsSafeNumber(rawPipeValue) then
            local catMin = tonumber(conf.minThreshold) or 0
            local spam = ZSBT.db.profile.spamControl and ZSBT.db.profile.spamControl.throttling
            local globalMin = (spam and tonumber(spam.minHealing)) or 0
            local effectiveThreshold = math.max(catMin, globalMin)
            if effectiveThreshold > 0 then
                meta.secretRawValue = rawPipeValue
                meta.filterThreshold = effectiveThreshold
            end
        end

        -- Attach spell icon if enabled
        if prof.showSpellIcons and evt.spellId then
            local tex = ZSBT.CleanSpellIcon(evt.spellId)
            if tex then meta.spellIcon = tex end
        end

        if ZSBT.DisplayText then
            ZSBT.DisplayText(areaToUse, text, color, meta)
        elseif ZSBT.Core and ZSBT.Core.Display and ZSBT.Core.Display.Emit then
            ZSBT.Core.Display:Emit(areaToUse, text, color, meta)
        end

		local dbg3 = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and ZSBT.db.profile.diagnostics.debugLevel or 0
		if dbg3 >= 3 and Addon and Addon.Print then
			local function safeDbg(v)
				if v == nil then return "nil" end
				if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
				if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
				return "<secret>"
			end
			Addon:Print("|cFF00CC66[OUT]|r " .. safeDbg(areaToUse) .. " " .. safeDbg(evt.spellId) .. " " .. safeDbg(text))
		end
    end
end
