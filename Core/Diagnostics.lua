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
