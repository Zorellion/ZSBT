------------------------------------------------------------------------
-- ZSBT - Parser Normalization Helpers (Skeleton)
-- Responsibility: normalize raw game data into a consistent event table.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.Parser = ZSBT.Parser or {}
ZSBT.Parser.Normalize = ZSBT.Parser.Normalize or {}
local Normalize = ZSBT.Parser.Normalize
local Addon     = ZSBT.Addon

-- Create a normalized event shell (placeholder)
function Normalize:NewEvent(kind, payload)
    local evt = payload or {}
    evt.kind = kind or "UNKNOWN"

    -- Timestamp is optional; avoid forcing behavior.
    -- The parser may set it later using GetTime().
    return evt
end
