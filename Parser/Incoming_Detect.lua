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
-- Incoming Spell Attribution State
-- ============================================================
local SPELL_EXPIRE = 2.0
local MAX_PENDING_SPELLS = 5
local pendingSpells = {}
local incomingFrame = CreateFrame("Frame")

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

-- ============================================================
-- Pending Queue Helpers
-- ============================================================
local function PrunePendingSpells(now)
    -- Remove stale entries outside the spell correlation window.
    local i = 1
    while i <= #pendingSpells do
        local entry = pendingSpells[i]
        if (now - entry.time) > SPELL_EXPIRE then
            table.remove(pendingSpells, i)
        else
            i = i + 1
        end
    end
end

local function PushPendingSpell(spellID)
    local spellInfo = C_Spell.GetSpellInfo(spellID)
    if not spellInfo then return end

    -- Store spell cast metadata for upcoming UNIT_COMBAT damage correlation.
    pendingSpells[#pendingSpells + 1] = {
        spellID = spellID,
        name = spellInfo.name,
        icon = spellInfo.iconID,
        time = GetTime(),
    }

    -- Keep queue bounded to avoid memory bloat.
    while #pendingSpells > MAX_PENDING_SPELLS do
        table.remove(pendingSpells, 1)
    end
end

local function AttachPendingSpell(ev, now)
    local bestIndex
    local bestDelta

    -- Find the closest recent spell cast inside the attribution window.
    for i = #pendingSpells, 1, -1 do
        local entry = pendingSpells[i]
        local delta = now - entry.time
        if delta >= 0 and delta <= SPELL_EXPIRE then
            if not bestDelta or delta < bestDelta then
                bestDelta = delta
                bestIndex = i
            end
        end
    end

    if not bestIndex then return end

    local match = pendingSpells[bestIndex]
    ev.spellID = match.spellID
    ev.spellName = match.name
    ev.spellIcon = match.icon
    table.remove(pendingSpells, bestIndex)
end

-- ============================================================
-- UNIT_SPELLCAST_SUCCEEDED Listener (hostile casts only)
-- NOTE: Event_Collector also listens for UNIT_SPELLCAST_SUCCEEDED
-- but only for unit=="player" (outgoing correlation). This handler
-- captures hostile casts from target/nameplates for incoming spell
-- attribution. They are complementary, not duplicated.
-- ============================================================
incomingFrame:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event ~= "UNIT_SPELLCAST_SUCCEEDED" then return end
    if not Incoming._enabled then return end

    -- Capture hostile casts from target and nameplates only.
    if unit ~= "target" and not (unit and unit:match("^nameplate")) then return end
    if not UnitCanAttack("player", unit) then return end
    if not spellID then return end

    -- Prune old entries on every cast before inserting fresh metadata.
    local now = GetTime()
    PrunePendingSpells(now)
    PushPendingSpell(spellID)
end)
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

    -- Correlate recent hostile casts to incoming direct damage events.
    if ev.kind == "damage" then
        AttachPendingSpell(ev, GetTime())
    end

    local probe = ZSBT.Core and ZSBT.Core.IncomingProbe
    if probe and probe.OnIncomingDetected then
        probe:OnIncomingDetected(ev)
    end
end
-- Incoming is now managed by CombatLog_Detect.lua
function Incoming:Enable()
    self._enabled = true
    incomingFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end

function Incoming:Disable()
    self._enabled = false
    incomingFrame:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end
