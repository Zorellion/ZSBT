------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - Diagnostics
-- Debug output and SavedVariables event logging.
------------------------------------------------------------------------

local ADDON_NAME, ZSBT = ...
local Addon = ZSBT.Addon

------------------------------------------------------------------------
-- Debug Print (channel + severity)
------------------------------------------------------------------------
local function SafeToString(v)
	if v == nil then return "nil" end
	if ZSBT and type(ZSBT.IsSecret) == "function" then
		local okS, isSecret = pcall(ZSBT.IsSecret, v)
		if okS and isSecret == true then
			return "<secret>"
		end
	end
	local ok, s = pcall(tostring, v)
	if not ok or type(s) ~= "string" then
		return "<secret>"
	end
	if ZSBT and type(ZSBT.IsSafeString) == "function" then
		local ok2, safe = pcall(ZSBT.IsSafeString, s)
		if ok2 and safe ~= true then
			return "<secret>"
		end
	end
	return s
end

function Addon:GetDebugLevel(channel)
	local d = self.db and self.db.profile and self.db.profile.diagnostics
	if type(d) ~= "table" then return 0 end

	local defaultLevel = tonumber(d.debugDefaultLevel)
	if type(defaultLevel) ~= "number" then
		defaultLevel = tonumber(d.debugLevel) or 0
	end

	if type(channel) ~= "string" or channel == "" then
		return defaultLevel
	end

	local ch = d.debugChannels
	if type(ch) ~= "table" then
		return defaultLevel
	end
	local v = ch[channel]
	if v == nil then
		return defaultLevel
	end
	local n = tonumber(v)
	if type(n) ~= "number" then
		return defaultLevel
	end
	return n
end

local function ChannelPrefix(channel)
	if type(channel) ~= "string" or channel == "" then
		channel = "debug"
	end
	local map = {
		core = "CORE",
		cooldowns = "CD",
		incoming = "IN",
		outgoing = "OUT",
		triggers = "TRIG",
		notifications = "NOTIF",
		ui = "UI",
		diagnostics = "DIAG",
		safety = "SAFE",
		perf = "PERF",
	}
	local short = map[channel] or channel:upper()
	return "|cFF00CC66[" .. short .. "]|r"
end

-- level: 0=off, 1=error, 2=warn, 3=info, 4=debug, 5=trace
function Addon:Dbg(channel, requiredLevel, ...)
	requiredLevel = tonumber(requiredLevel) or 0
	if requiredLevel <= 0 then return end
	local cur = self:GetDebugLevel(channel)
	if (tonumber(cur) or 0) < requiredLevel then return end

	local prefix = ChannelPrefix(channel)
	local n = select('#', ...)
	if n <= 0 then
		self:Print(prefix)
		return
	end
	local parts = {}
	for i = 1, n do
		parts[#parts + 1] = SafeToString(select(i, ...))
	end
	self:Print(prefix .. " " .. table.concat(parts, " "))
end

function Addon:DbgOnce(key, channel, requiredLevel, ...)
	if type(key) ~= "string" or key == "" then
		return self:Dbg(channel, requiredLevel, ...)
	end
	self._dbgOnce = self._dbgOnce or {}
	if self._dbgOnce[key] == true then return end
	self._dbgOnce[key] = true
	return self:Dbg(channel, requiredLevel, ...)
end

function Addon:DbgRate(key, sec, channel, requiredLevel, ...)
	if type(key) ~= "string" or key == "" then
		return self:Dbg(channel, requiredLevel, ...)
	end
	sec = tonumber(sec) or 0
	if sec <= 0 then
		return self:Dbg(channel, requiredLevel, ...)
	end
	local now = (GetTime and GetTime()) or 0
	self._dbgRate = self._dbgRate or {}
	local last = tonumber(self._dbgRate[key]) or 0
	if last > 0 and (now - last) < sec then
		return
	end
	self._dbgRate[key] = now
	return self:Dbg(channel, requiredLevel, ...)
end

-- Back-compat: treat legacy DebugPrint(level, ...) as DIAG channel.
function Addon:DebugPrint(requiredLevel, ...)
	return self:Dbg("diagnostics", requiredLevel, ...)
end

------------------------------------------------------------------------
-- Log Event to SavedVariables (for post-session analysis)
------------------------------------------------------------------------
function Addon:LogEvent(eventData)
    local diag = self.db and self.db.profile.diagnostics
    if not diag or not diag.captureEnabled then
        return
    end

    local log = diag.log
    if type(log) ~= "table" then
        log = {}
        diag.log = log
    end

    local maxEntries = tonumber(diag.maxEntries) or 1000
    if maxEntries < 1 then maxEntries = 1 end

    if type(diag.qHead) ~= "number" then diag.qHead = 1 end
    if type(diag.qTail) ~= "number" then diag.qTail = 0 end
    if type(diag.qCount) ~= "number" then diag.qCount = 0 end

    -- One-time migration: if the log already contains a linear history but indices
    -- are reset, adopt the existing entries into the queue.
    if diag.qCount == 0 and diag.qTail == 0 and #log > 0 then
        local keep = math.min(#log, maxEntries)
        if keep < #log then
            local start = #log - keep + 1
            local newLog = {}
            for i = start, #log do
                newLog[#newLog + 1] = log[i]
            end
            log = newLog
            diag.log = log
        end
        diag.qHead = 1
        diag.qTail = #log
        diag.qCount = #log
    end

    -- Drop oldest if at capacity (O(1))
    if diag.qCount >= maxEntries then
        log[diag.qHead] = nil
        diag.qHead = diag.qHead + 1
        if diag.qHead > maxEntries then diag.qHead = 1 end
        diag.qCount = diag.qCount - 1
    end

    diag.qTail = diag.qTail + 1
    if diag.qTail > maxEntries then diag.qTail = 1 end

    eventData.timestamp = GetTime()
    log[diag.qTail] = eventData
    diag.qCount = diag.qCount + 1
end

------------------------------------------------------------------------
-- Clear Diagnostic Log
------------------------------------------------------------------------
function Addon:ClearDiagnosticLog()
    if self.db and self.db.profile.diagnostics then
        wipe(self.db.profile.diagnostics.log)
        self.db.profile.diagnostics.qHead = 1
        self.db.profile.diagnostics.qTail = 0
        self.db.profile.diagnostics.qCount = 0
        self:Print("Diagnostic log cleared.")
    end
end

function Addon:_perfEnabled()
	local enabled = false
	if self.GetDebugLevel then
		enabled = (tonumber(self:GetDebugLevel("perf")) or 0) > 0
	else
		local d = self.db and self.db.profile and self.db.profile.diagnostics
		enabled = (d and d.perfEnabled == true) or false
	end
	local hasClock = type(debugprofilestop) == "function"
	if enabled and not hasClock then
		-- Avoid silent failure when profiling is enabled but the client doesn't expose debugprofilestop().
		if self.DbgOnce then
			self:DbgOnce("perf_no_debugprofilestop", "safety", 1, "Performance profiling enabled but debugprofilestop() is unavailable in this client.")
		elseif self.Dbg then
			self:Dbg("safety", 1, "Performance profiling enabled but debugprofilestop() is unavailable in this client.")
		else
			self:Print("Performance profiling enabled but debugprofilestop() is unavailable in this client.")
		end
	end
	return enabled and hasClock
end

function Addon:PerfBegin(key)
	if not self:_perfEnabled() then return nil end
	if type(key) ~= "string" or key == "" then return nil end
	-- Self-diagnosing: confirm profiling is actually running (rate-limited).
	if self.DbgRate then
		self:DbgRate("perf_active", 2.0, "perf", 3, "Perf profiling active")
	end
	return { debugprofilestop(), key }
end

function Addon:PerfEnd(token)
	if not token then return end
	local startMs, key = token[1], token[2]
	if type(startMs) ~= "number" or type(key) ~= "string" then return end
	local stopMs = debugprofilestop()
	local dt = stopMs - startMs
	if dt < 0 then return end
	self._perf = self._perf or { lastReportAt = 0, acc = {}, cnt = {} }
	local p = self._perf
	p.acc[key] = (p.acc[key] or 0) + dt
	p.cnt[key] = (p.cnt[key] or 0) + 1

	local now = (GetTime and GetTime()) or 0
	if (now - (p.lastReportAt or 0)) < 1.0 then return end
	p.lastReportAt = now

	local out = {}
	for k, v in pairs(p.acc) do
		out[#out + 1] = { k = k, ms = v, c = p.cnt[k] or 0 }
	end
	table.sort(out, function(a, b) return (a.ms or 0) > (b.ms or 0) end)
	local parts = {}
	local maxShow = 6
	for i = 1, math.min(#out, maxShow) do
		local it = out[i]
		parts[#parts + 1] = tostring(it.k) .. "=" .. string.format("%.2f", it.ms) .. "ms(" .. tostring(it.c) .. ")"
	end
	if #parts > 0 then
		-- Profiling is enabled by the perf debug channel; output verbosity is
		-- also controlled by the unified debug channel.
		if self.Dbg then
			self:Dbg("perf", 3, table.concat(parts, " "))
		else
			self:Print("|cFFCC66FF[PERF]|r " .. table.concat(parts, " "))
		end
	end
	wipe(p.acc)
	wipe(p.cnt)
end

