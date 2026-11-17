------------------------------------------------------------------------
-- Zore's Combat Text - Probe
-- Empirical event/API signature recorder. NOTHING in the feature code may
-- consume an event payload until Probe has recorded its real signature
-- in-game (see CLAUDE.md "Probe-first methodology").
--
-- Records, per watched key: arg count, per-arg {type, secret?, preview}
-- and a signature histogram + recent samples ring. All inspection goes
-- through safe predicates only — secret values are never operated on.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
ZSBT.ZCT = ZSBT.ZCT or {}
local ZCT = ZSBT.ZCT

ZCT = ZCT or {}
ZCT.Probe = ZCT.Probe or {}
local Probe = ZCT.Probe

Probe._enabled = Probe._enabled or true
Probe._records = Probe._records or {}   -- key -> record
Probe._watched = Probe._watched or {}   -- eventName -> true
Probe._hooked  = Probe._hooked or {}    -- fnName -> true
Probe._MAX_SAMPLES = 120
Probe._MAX_PREVIEW = 40

local function isSecretVal(v)
    if issecretvalue then
        local ok, r = pcall(issecretvalue, v)
        if ok then return r == true end
    end
    return false
end

local function canAccessVal(v)
    if canaccessvalue then
        local ok, r = pcall(canaccessvalue, v)
        if ok then return r == true end
    end
    return nil -- unknown
end

-- Safe one-line descriptor for an arg value. NEVER operates on secrets.
local function describe(v)
    local t = type(v)
    if v == nil then return "nil" end
    local secret = isSecretVal(v)
    if t == "number" then
        if secret then return "number:SECRET" end
        return "number:" .. tostring(v)
    end
    if t == "string" then
        if secret or (ZCT.IsSafeString and not ZCT.IsSafeString(v)) then
            return "string:SECRET"
        end
        local s = v
        if #s > Probe._MAX_PREVIEW then s = s:sub(1, Probe._MAX_PREVIEW) .. "~" end
        return 'string:"' .. s .. '"'
    end
    if t == "boolean" then
        if secret then return "boolean:SECRET" end
        return "boolean:" .. tostring(v)
    end
    if t == "table" then
        if secret or (issecrettable and issecrettable(v)) then
            return "table:SECRET"
        end
        return "table"
    end
    if t == "function" then return "function" end
    if secret then return t .. ":SECRET" end
    return t
end

local function recordFor(key)
    local rec = Probe._records[key]
    if not rec then
        rec = { count = 0, sigs = {}, samples = {}, head = 0, tail = 0 }
        Probe._records[key] = rec
    end
    return rec
end

-- Ring push: fixed MAX slots, head wraps; samples never grow unbounded.
local function pushSample(rec, sample)
    local s = rec.samples
    rec.head = (rec.head % Probe._MAX_SAMPLES) + 1
    s[rec.head] = sample
end

-- Record one observation. key = event name or "fn:Name" or "tbl:Name".
function Probe:Record(key, ...)
    if not Probe._enabled then return end
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
        parts[i] = describe((select(i, ...)))
    end
    local sig = n .. "|" .. table.concat(parts, " | ")
    local rec = recordFor(key)
    rec.count = rec.count + 1
    rec.sigs[sig] = (rec.sigs[sig] or 0) + 1
    rec.lastSig = sig
    pushSample(rec, { at = GetTime(), sig = sig })
end

function Probe:_ensureFrame()
    if self._frame then return self._frame end
    local f = CreateFrame("Frame")
    f:SetScript("OnEvent", function(_, event, ...)
        Probe:Record(event, ...)
    end)
    self._frame = f
    -- Register everything already watched.
    for evt in pairs(self._watched) do
        pcall(f.RegisterEvent, f, evt)
    end
    return f
end

-- Watch a WoW event (arg signature recorded on every firing).
function Probe:Watch(eventName)
    if self._watched[eventName] then return end
    self._watched[eventName] = true
    local f = self:_ensureFrame()
    pcall(f.RegisterEvent, f, eventName)
end

function Probe:Unwatch(eventName)
    if not self._watched[eventName] then return end
    self._watched[eventName] = nil
    if self._frame then
        pcall(self._frame.UnregisterEvent, self._frame, eventName)
    end
end

-- Observe a global function via hooksecurefunc (never replaces it).
function Probe:HookFn(name)
    if self._hooked[name] then return end
    local fn = _G[name]
    if type(fn) ~= "function" or type(hooksecurefunc) ~= "function" then
        self._hooked[name] = "unavailable"
        return
    end
    self._hooked[name] = true
    hooksecurefunc(name, function(...)
        Probe:Record("fn:" .. name, ...)
    end)
end

-- Dump a table's keys + value types (for C_* namespace capability discovery).
function Probe:DumpTable(name, tbl)
    if type(tbl) ~= "table" then
        self:Record("tbl:" .. name, "<not a table: " .. type(tbl) .. ">")
        return
    end
    local lines = {}
    local ok = pcall(function()
        for k, v in pairs(tbl) do
            local ks = describe(k)
            local vs = describe(v)
            lines[#lines + 1] = ("%s = %s"):format(ks, vs)
        end
    end)
    if not ok then
        lines[#lines + 1] = "<pairs() failed — secret table?>"
    end
    table.sort(lines)
    local rec = recordFor("tbl:" .. name)
    rec.count = rec.count + 1
    rec.sigs["dump"] = (rec.sigs.dump or 0) + 1
    rec.dumpLines = lines
    rec.lastSig = ("%d keys"):format(#lines)
end

-- Probe availability of C_* sub-functions and global predicates.
-- path is dotted from _G, e.g. "C_CombatText" or "C_CombatText.GetCurrentEventInfo".
function Probe:ProbeAPI()
    local function check(path)
        local ok, res = pcall(function()
            local o = _G
            for part in path:gmatch("[^%.]+") do
                o = o and o[part]
            end
            return o
        end)
        local kind = ok and type(res) or "ERR"
        local rec = recordFor("api:" .. path)
        rec.count = rec.count + 1
        rec.sigs[kind] = (rec.sigs[kind] or 0) + 1
        rec.lastSig = kind
    end
    for _, g in ipairs(ZCT.PROBE_GLOBALS or {}) do
        check(g)
    end
    for _, c in ipairs(ZCT.PROBE_C_FUNCS or {}) do
        check(c)
        -- one level of sub-functions for the namespaces we care about
        if c == "C_CombatText" or c == "C_CombatLog" or c == "C_Secrets" then
            local ns = _G[c]
            if type(ns) == "table" then
                pcall(function()
                    for k in pairs(ns) do
                        check(c .. "." .. tostring(k))
                    end
                end)
            end
        end
    end
end

-- Watch everything declared in Constants. Idempotent.
function Probe:WatchDefaults()
    -- COMBAT_TEXT_UPDATE carries only the type token; the payload
    -- (amount/spellId/crit?) comes from C_CombatText.GetCurrentEventInfo()
    -- inside the event. Record those returns under "ct:payload".
    if not self._ctFrame and C_CombatText and C_CombatText.GetCurrentEventInfo then
        local f = CreateFrame("Frame")
        f:RegisterEvent("COMBAT_TEXT_UPDATE")
        f:SetScript("OnEvent", function(_, event, ...)
            Probe:Record(event, ...)
            local ok, a, b, c, d = pcall(C_CombatText.GetCurrentEventInfo)
            if ok then
                Probe:Record("ct:payload", a, b, c, d)
            else
                Probe:Record("ct:payload", "<call failed>")
            end
        end)
        self._ctFrame = f
    end
    for _, evt in ipairs(ZCT.WATCHED_EVENTS or {}) do
        self:Watch(evt)
    end
    for _, fn in ipairs(ZCT.PROBE_GLOBALS or {}) do
        -- Only hook the CombatText_AddMessage family; predicates are
        -- checked via ProbeAPI instead of hooked.
        if fn:find("CombatText") then
            self:HookFn(fn)
        end
    end
    if self._defaultsProbed then return end
    self._defaultsProbed = true
    self:ProbeAPI()
    for _, c in ipairs(ZCT.PROBE_C_FUNCS or {}) do
        self:DumpTable(c, _G[c])
    end
end

function Probe:Enable()
    self._enabled = true
    local f = self:_ensureFrame()
    for evt in pairs(self._watched) do
        pcall(f.RegisterEvent, f, evt)
    end
end

function Probe:Disable()
    if not self._enabled then return end
    self._enabled = false
    if self._frame then
        for evt in pairs(self._watched) do
            pcall(self._frame.UnregisterEvent, self._frame, evt)
        end
    end
end

local function dumpLine(s)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66aaff[ZCT]|r " .. s)
    end
end

-- Print recorded signatures. filter: optional substring matched against key.
function Probe:Dump(filter)
    local keys = {}
    for k in pairs(self._records) do
        if not filter or k:lower():find(filter:lower(), 1, true) then
            keys[#keys + 1] = k
        end
    end
    table.sort(keys)
    dumpLine(("=== ZCT PROBE DUMP (%d sources) ==="):format(#keys))
    for _, key in ipairs(keys) do
        local rec = self._records[key]
        dumpLine(("--- %s  (fired %d)"):format(key, rec.count))
        if rec.dumpLines then
            for _, l in ipairs(rec.dumpLines) do
                dumpLine("    " .. l)
            end
        else
            -- signature histogram, most common first. Filtered dumps show
            -- more — the user asked for this event specifically.
            local sigs = {}
            for sig, n in pairs(rec.sigs) do sigs[#sigs + 1] = { sig = sig, n = n } end
            table.sort(sigs, function(a, b) return a.n > b.n end)
            local maxShow = filter and 20 or 6
            for i = 1, math.min(maxShow, #sigs) do
                dumpLine(("    [%4dx] %s"):format(sigs[i].n, sigs[i].sig))
            end
            if #sigs > maxShow then
                dumpLine(("    ... +%d more signatures"):format(#sigs - maxShow))
            end
        end
    end
    dumpLine("=== END DUMP ===")
end

-- One-line health summary for /zct status.
function Probe:Summary()
    local total, sources = 0, 0
    for _, rec in pairs(self._records) do
        total = total + rec.count
        sources = sources + 1
    end
    return sources, total
end
