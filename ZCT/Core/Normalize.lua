------------------------------------------------------------------------
-- Zore's Combat Text - Event Normalization + Dispatch
-- Pooled CombatEvent objects; handlers Acquire/Release via New/Dispatch.
-- No per-event table allocation in hot paths.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
ZSBT.ZCT = ZSBT.ZCT or {}
local ZCT = ZSBT.ZCT

ZCT = ZCT or {}
ZCT.Normalize = ZCT.Normalize or {}
local Normalize = ZCT.Normalize

local MAX_POOL = 200
local pool = {}
local poolCount = 0

-- Sinks receive (evt) synchronously; they must not retain evt.
Normalize._sinks = Normalize._sinks or {}

function Normalize:AddSink(fn)
    self._sinks[#self._sinks + 1] = fn
end

-- Acquire a pooled event pre-filled with defaults.
function Normalize:New(kind)
    local evt = poolCount > 0 and table.remove(pool) or {}
    evt.kind = kind or "unknown"
    evt.direction = nil       -- "in" | "out"
    evt.amount = nil          -- number | secret raw | nil
    evt.amountIsSecret = false
    evt.crit = false
    evt.periodic = false
    evt.miss = false
    evt.school = nil          -- safe bitmask or nil
    evt.spellId = nil
    evt.spellName = nil
    evt.pet = false
    evt.unit = nil
    evt.action = nil
    evt.lineKind = nil        -- palette kind when paired
    evt.at = GetTime()
    evt._text = nil           -- safe display string (no secrets)
    evt._raw = nil            -- raw secret passthrough for SetText
    return evt
end

function Normalize:Release(evt)
    if not evt then return end
    -- Clear every field so nothing secret lingers in the pool.
    for k in pairs(evt) do evt[k] = nil end
    if poolCount < MAX_POOL then
        poolCount = poolCount + 1
        pool[poolCount] = evt
    end
end

function Normalize:Dispatch(evt)
    if not evt then return end
    for i = 1, #self._sinks do
        local ok, err = pcall(self._sinks[i], evt)
        if not ok then
            -- Sink errors are bugs: always surface them, never gate on
            -- debug level or they silently kill the pipeline.
            local tb = debug and debug.traceback and debug.traceback("", 3) or ""
            tb = tb:gsub("\n%s*", " | "):sub(1, 500)
            local msg = ("|cffdd5555[ZCT sink error]|r %s\n%s"):format(tostring(err), tb)
            if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
                DEFAULT_CHAT_FRAME:AddMessage(msg)
            end
        end
    end
    self:Release(evt)
end

-- Convenience: build + dispatch in one call. fields is a plain table of
-- overrides applied onto a pooled event.
function Normalize:Emit(kind, fields)
    local evt = self:New(kind)
    if fields then
        for k, v in pairs(fields) do evt[k] = v end
    end
    self:Dispatch(evt)
end
