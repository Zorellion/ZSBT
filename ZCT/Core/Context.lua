------------------------------------------------------------------------
-- Zore's Combat Text - Context
-- Automated content detection. There are no user-facing toggles: the
-- pipeline measures WHERE it is and applies the matching proof level.
--
-- Why strictness exists at all: UNIT_COMBAT carries no source unit, so
-- in a group another member's hit on the same nameplate produces a
-- candidate that can claim OUR palette line and display THEIR amount.
-- Solo (or group-of-one) there is nobody to steal from, so pairing
-- stays loose. Strict = "a group is present" — dungeon, raid, BG, or
-- just a party in the open world; the instance type is still reported
-- for diagnostics and future per-context tuning.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
ZSBT.ZCT = ZSBT.ZCT or {}
local ZCT = ZSBT.ZCT

ZCT = ZCT or {}
ZCT.Context = ZCT.Context or {}
local Context = ZCT.Context

Context._kind = "solo"      -- raid|dungeon|bg|arena|scenario|group|solo
Context._instance = nil     -- raw instance type when instanced
Context._grouped = false

local CONTEXT_EVENTS = {
    "PLAYER_ENTERING_WORLD",
    "ZONE_CHANGED_NEW_AREA",
    "UPDATE_INSTANCE_INFO",
    "GROUP_ROSTER_UPDATE",
    "PARTY_MEMBERS_CHANGED",
}

-- GetInstanceInfo() -> name, type, difficultyID, ...  type is
-- "party"|"raid"|"pvp"|"arena"|"scenario"|"none".
local function instanceKind()
    local ok, _, itype = pcall(GetInstanceInfo)
    if not ok or type(itype) ~= "string"
        or itype == "" or itype == "none" then
        return nil
    end
    if itype == "party" then return "dungeon" end
    if itype == "pvp" then return "bg" end
    return itype -- raid / arena / scenario pass through
end

local function groupSize()
    local ok, n = pcall(GetNumGroupMembers)
    if ok and type(n) == "number" then return n end
    return 0
end

function Context:Update()
    local ikind = instanceKind()
    local grouped = groupSize() > 1
    self._instance = ikind
    self._grouped = grouped
    -- Strict whenever a real group exists — instance type only refines
    -- the label. Instanced but alone relaxes (nobody can steal lines).
    if grouped then
        self._kind = ikind or "group"
    else
        self._kind = "solo"
    end
    if ZCT.Dbg and ZCT.Dbg:Enabled("config") then
        ZCT.Dbg:Info("config", "context=%s instance=%s grouped=%s",
            self._kind, tostring(ikind), tostring(grouped))
    end
end

-- Strict pairing: demand proof before a candidate may claim a line.
function Context:Strict()
    return self._kind ~= "solo"
end

function Context:Kind()
    return self._kind
end

function Context:Enable()
    if self._frame then return end
    local f = CreateFrame("Frame")
    f:SetScript("OnEvent", function() Context:Update() end)
    for _, evt in ipairs(CONTEXT_EVENTS) do
        pcall(f.RegisterEvent, f, evt)
    end
    self._frame = f
    self:Update()
end
