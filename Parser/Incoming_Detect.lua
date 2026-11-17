local ADDON_NAME, ZSBT = ...
ZSBT.Parser = ZSBT.Parser or {}
ZSBT.Parser.Incoming = ZSBT.Parser.Incoming or {}
local Incoming = ZSBT.Parser.Incoming

local Addon = ZSBT.Addon
local function Debug(level, ...)
	if Addon and Addon.Dbg then
		Addon:Dbg("incoming", level, ...)
		return
	end
	if ZSBT.Core and ZSBT.Core.Debug then
		ZSBT.Core:Debug(level, ...)
	elseif ZSBT.Debug then
		ZSBT.Debug(level, ...)
	end
end

-- ============================================================
-- Incoming Spell Attribution
-- ZCT owns incoming attribution now: bridge events arrive with
-- spellId already resolved (nil when unattributed). The old
-- hostile-cast correlation queue was removed — it recorded the
-- player's OWN casts on nameplates as "hostile" and stamped wrong
-- spellIds/icons onto incoming events.
-- ============================================================

local function safeBool(v)
    if type(v) ~= "boolean" then return false end
    local ok, val = pcall(function()
        return v == true
    end)
    if ok then return val end
    return false
end

local function safeStrOrNil(v)
	if v == nil then return nil end
	if ZSBT and ZSBT.IsSafeString and ZSBT.IsSafeString(v) then
		return v
	end
	return nil
end

local function safeNumOrNil(v)
	if v == nil then return nil end
	if ZSBT and ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then
		return v
	end
	return nil
end

------------------------------------------------------------------------
-- WoW 12.0 Midnight Compliance: Named Key Access Only
------------------------------------------------------------------------
-- CRITICAL CHANGES:
-- ✓ Replaced index-based access (info[12]) with named keys (info.amount)
-- ✓ Removed tonumber() calls on Secret Values (info.amount, info.critical)
-- ✓ Pass info.amount DIRECTLY to display without arithmetic/comparisons
-- ✗ REMOVED: Numeric comparisons, amount fallbacks

function Incoming:ProcessEvent(info)
    if not self._enabled then return end
    if not info or type(info) ~= "table" then return end

    local db = ZSBT.db and ZSBT.db.profile
    if not db or not db.incoming then return end

    local ev = nil

    -- Pulse engine normalized path.
    -- IMPORTANT: Incoming is *damage/heal to the player*.
    -- We must not accept normalized events that target other units, otherwise
    -- outgoing damage can be misrouted into the Incoming scroll area.
    if info.kind == "damage" or info.kind == "heal" or info.kind == "miss" then
        if info.kind == "damage" then
            if not (db.incoming.damage and db.incoming.damage.enabled) then return end
        elseif info.kind == "heal" then
            if not (db.incoming.healing and db.incoming.healing.enabled) then return end
        end
        -- "miss" events always pass through (dodge/parry/block are important)

		local playerName = UnitName and UnitName("player") or nil
		if ZSBT.IsSafeString and ZSBT.IsSafeString(info.targetName) and ZSBT.IsSafeString(playerName) then
			if info.targetName ~= playerName then
				return
			end
		end

        ev = {
            kind = info.kind,
            amount = info.amount,
            amountText = info.amountText,
            rawPipeId = info.rawPipeId,
            spellID = info.spellId,
            spellName = info.spellName,
            spellIcon = info.spellIcon,
            schoolMask = info.schoolMask,
            isCrit = safeBool(info.isCrit),
            isPeriodic = info.isPeriodic == true,
            overheal = info.overheal,
            timestamp = info.timestamp,
            targetName = info.targetName,
            confidence = info.confidence,
        }

		ev.amountText = safeStrOrNil(ev.amountText)
		ev.targetName = safeStrOrNil(ev.targetName)
		ev.spellName = safeStrOrNil(ev.spellName)
		ev.confidence = safeStrOrNil(ev.confidence)
		ev.spellID = safeNumOrNil(ev.spellID)
		ev.spellIcon = safeNumOrNil(ev.spellIcon)
		ev.schoolMask = safeNumOrNil(ev.schoolMask)

        if ev.targetName == nil then
            ev.targetName = UnitName("player")
        end

    -- Legacy combat-log shaped payload path.
    else
        local timestamp = info.timestamp
        local subevent = info.subEvent
        local destGUID = info.destGUID

        -- In 12.0, subevent and destGUID may be tainted secret strings.
        -- If they're tainted, we can't process this legacy path at all —
        -- the PulseEngine handles tainted events via UNIT_COMBAT instead.
        if not ZSBT.IsSafeString(subevent) then return end
        if not ZSBT.IsSafeString(destGUID) then return end

        -- Safe string path: normal comparisons are fine.
        if destGUID ~= UnitGUID("player") then return end

        local isDamage = subevent:find("_DAMAGE") ~= nil
        local isHeal = subevent:find("_HEAL") ~= nil

        ev = {
            timestamp  = timestamp,
            targetName = UnitName("player"),
        }

        -- Basic categorization
        if isDamage then
            if not (db.incoming.damage and db.incoming.damage.enabled) then return end
            ev.kind = "damage"
            -- Launder amount at the boundary: keep numeric if possible,
            -- always produce a display string for Secret Value safety.
            if ZSBT.IsSafeNumber(info.amount) then
                ev.amount = info.amount
                ev.amountText = tostring(math.floor(info.amount + 0.5))
            else
                ev.amount = nil
                ev.amountText = info.amount  -- Pass raw for SetText() display
                ev.isSecret = true
            end
            ev.schoolMask = info.school      -- Safe: non-secret
            ev.isCrit = safeBool(info.critical)

        elseif isHeal then
            if not (db.incoming.healing and db.incoming.healing.enabled) then return end
            ev.kind = "heal"
            if ZSBT.IsSafeNumber(info.amount) then
                ev.amount = info.amount
                ev.amountText = tostring(math.floor(info.amount + 0.5))
            else
                ev.amount = nil
                ev.amountText = info.amount  -- Pass raw for SetText() display
                ev.isSecret = true
            end
            ev.isCrit = safeBool(info.critical)
        else
            return
        end
    end

    local probe = ZSBT.Core and ZSBT.Core.IncomingProbe
    if probe and probe.OnIncomingDetected then
        probe:OnIncomingDetected(ev)
    end
end
-- Incoming is now managed by CombatLog_Detect.lua
function Incoming:Enable()
    self._enabled = true
end

function Incoming:Disable()
    self._enabled = false
end
