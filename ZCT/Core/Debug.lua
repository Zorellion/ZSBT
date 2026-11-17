------------------------------------------------------------------------
-- Zore's Combat Text - Debug Channels
-- Leveled, channel-scoped debug output. Never print() in hot paths;
-- route through ZCT.Dbg(channel, level, ...).
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
ZSBT.ZCT = ZSBT.ZCT or {}
local ZCT = ZSBT.ZCT

ZCT = ZCT or {}
ZCT.Dbg = ZCT.Dbg or {}
local Dbg = ZCT.Dbg

-- channel -> current level (0 = off). Levels are per-channel so the probe
-- can run at 4 while display stays quiet.
Dbg._levels = Dbg._levels or {
    probe       = 0,
    lines       = 0,
    filter      = 0,
    incoming    = 0,
    outgoing    = 0,
    correlate   = 0,
    display     = 0,
    config      = 0,
    auras       = 0,
    notify      = 0,
    interrupts  = 0,
}

-- Reserved levels: 1=errors/state, 2=summary, 3=flow, 4=trace, 5=verbose
function Dbg:SetLevel(channel, level)
    if self._levels[channel] == nil then return false end
    self._levels[channel] = math.max(0, math.min(5, tonumber(level) or 0))
    return true
end

function Dbg:GetLevel(channel)
    return self._levels[channel] or 0
end

function Dbg:Enabled(channel)
    return (self._levels[channel] or 0) > 0
end

local function safeStr(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "string" then
        if ZCT.IsSafeString and not ZCT.IsSafeString(v) then return "<secret-str>" end
        if #v > 60 then return v:sub(1, 57) .. "..." end
        return '"' .. v .. '"'
    end
    if t == "number" then
        if ZCT.IsSafeNumber and not ZCT.IsSafeNumber(v) then return "<secret-num>" end
        return tostring(v)
    end
    if t == "table" then
        if ZCT.IsSecret and ZCT.IsSecret(v) then return "<secret-table>" end
        return "table"
    end
    if t == "function" then return "function" end
    if t == "boolean" then return tostring(v) end
    return "<" .. t .. ">"
end

local function levelTag(level)
    return ({ "ERR", "WRN", "INF", "TRC", "VRB" })[math.min(5, math.max(1, level))] or "DBG"
end

-- Dbg(channel, level, msg) or Dbg(channel, level, fmt, ...)
function Dbg:Log(channel, level, a1, ...)
    local lvl = self._levels[channel] or 0
    if lvl < level then return end
    local msg
    if select("#", ...) > 0 and type(a1) == "string" and a1:find("%%") then
        local ok, s = pcall(string.format, a1, ...)
        msg = ok and s or a1
    else
        local n = select("#", ...)
        if n == 0 then
            msg = safeStr(a1)
        else
            local parts = { safeStr(a1) }
            for i = 1, n do parts[#parts + 1] = safeStr(select(i, ...)) end
            msg = table.concat(parts, " ")
        end
    end
    local line = ("|cff998866[ZCT %s %s]|r %s"):format(channel:upper(), levelTag(level), tostring(msg))
    -- tostring(msg) may itself be unsafe if msg contains secrets embedded in
    -- a safe string — acceptable: safeStr already filtered arg values.
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(line)
    end
end

-- Convenience wrappers
function Dbg:Err(channel, ...)   return self:Log(channel, 1, ...) end
function Dbg:Warn(channel, ...)  return self:Log(channel, 2, ...) end
function Dbg:Info(channel, ...)  return self:Log(channel, 3, ...) end
function Dbg:Trace(channel, ...) return self:Log(channel, 4, ...) end
function Dbg:Verb(channel, ...)  return self:Log(channel, 5, ...) end

-- Global shorthand matching ZSBT style: ZCT.Dbg("probe", 4, "...")
function ZCT.DbgPrint(channel, level, ...)
    return Dbg:Log(channel, level, ...)
end
