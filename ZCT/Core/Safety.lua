------------------------------------------------------------------------
-- Zore's Combat Text - Secret Value Safety (12.0)
-- Ported from ZSBT Core/Constants.lua. Tainted code may store and pass
-- secret values but ANY operation on them is an immediate Lua error.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
ZSBT.ZCT = ZSBT.ZCT or {}
local ZCT = ZSBT.ZCT

ZCT = ZCT or {}

-- True when v is (or contains) a secret value. Uses Blizzard's predicates
-- when present; falls back to a pcall probe on old clients.
local function hasSecret(v)
    if type(v) == "nil" then return false end
    if issecretvalue and issecretvalue(v) then return true end
    if issecrettable and type(v) == "table" and issecrettable(v) then return true end
    if HasSecretValues and HasSecretValues(v) then return true end
    -- Fallback for clients without the secret APIs: pcall probe.
    if type(v) == "number" then
        local ok = pcall(function() return v + 0 end)
        return not ok
    end
    if type(v) == "string" then
        local ok = pcall(function() return v == "" end)
        return not ok
    end
    return false
end

-- True when the current execution context may operate on v.
-- False on old clients that lack the API — callers treat "unknown"
-- conservatively.
function ZCT.CanAccessValue(v)
    if type(v) == "nil" then return true end
    if canaccessvalue then
        local ok, res = pcall(canaccessvalue, v)
        if ok and type(res) == "boolean" then return res end
    end
    return not hasSecret(v)
end

function ZCT.IsSecret(v)
    return hasSecret(v)
end

function ZCT.IsSafeNumber(v)
    if type(v) ~= "number" then return false end
    return not hasSecret(v)
end

function ZCT.IsSafeString(v)
    if type(v) ~= "string" then return false end
    return not hasSecret(v)
end

function ZCT.IsSafeTable(v)
    if type(v) ~= "table" then return false end
    if issecrettable and issecrettable(v) then return false end
    return true
end

-- Re-fetch a CLEAN, untainted spell name from the local client cache.
function ZCT.CleanSpellName(spellId)
    if not ZCT.IsSafeNumber(spellId) then return nil end
    if C_Spell and C_Spell.GetSpellName then
        local name = C_Spell.GetSpellName(spellId)
        if type(name) == "string" and ZCT.IsSafeString(name) and name ~= "" then
            return name
        end
    end
    if GetSpellInfo then
        local name = GetSpellInfo(spellId)
        if type(name) == "string" and ZCT.IsSafeString(name) and name ~= "" then
            return name
        end
    end
    return nil
end

-- True when spellId looks like a usable spell identifier (safe number).
function ZCT.IsSafeSpellId(v)
    return ZCT.IsSafeNumber(v)
end
