------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - Diagnostics
-- Debug output and SavedVariables event logging.
------------------------------------------------------------------------

local ADDON_NAME, ZSBT = ...
local Addon = ZSBT.Addon

------------------------------------------------------------------------
-- Debug Print (respects current debug level)
------------------------------------------------------------------------
function Addon:DebugPrint(requiredLevel, ...)
    local currentLevel = self.db and self.db.profile.diagnostics.debugLevel or 0
    if currentLevel >= requiredLevel then
        self:Print("|cFF00CC66[Debug " .. requiredLevel .. "]|r", ...)
    end
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
	local d = self.db and self.db.profile and self.db.profile.diagnostics
	return d and d.perfEnabled == true and type(debugprofilestop) == "function"
end

function Addon:PerfBegin(key)
	if not self:_perfEnabled() then return nil end
	if type(key) ~= "string" or key == "" then return nil end
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
		self:Print("|cFFCC66FF[PERF]|r " .. table.concat(parts, " "))
	end
	wipe(p.acc)
	wipe(p.cnt)
end

