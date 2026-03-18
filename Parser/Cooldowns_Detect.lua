------------------------------------------------------------------------
-- ZSBT - Cooldowns Detection
--
-- Midnight 12.0 Limitations:
--   - Charge-based spells: recharge data is SECRET when charges > 0.
--     We can only track reliably when ALL charges are spent (0 remaining).
--   - Simple cooldown spells: OnCooldownDone works via CooldownFrame.
--
-- Strategy:
--   - CooldownFrame with OnCooldownDone for in-combat detection
--   - SPELL_UPDATE_COOLDOWN dur==0 for out-of-combat fallback
--   - For charge spells: only apply CD frame when charges hit 0
--
-- Debug: /zsbt debug 2
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.Parser = ZSBT.Parser or {}
ZSBT.Parser.Cooldowns = ZSBT.Parser.Cooldowns or {}
local Cooldowns = ZSBT.Parser.Cooldowns
local Addon     = ZSBT.Addon

Cooldowns._enabled = false
Cooldowns._frame   = nil
Cooldowns._state   = {}
Cooldowns._cdFrames = {}

local function CdDebug(msg)
    if not Addon then return end
    local level = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics
                  and ZSBT.db.profile.diagnostics.debugLevel or 0
    if level >= 2 then
        Addon:Print("|cFF00CCFF[CD]|r " .. msg)
    end
end

------------------------------------------------------------------------
-- Read charges (silent)
------------------------------------------------------------------------
local function ReadCharges(spellId)
    if C_Spell and C_Spell.GetSpellCharges then
        local info = C_Spell.GetSpellCharges(spellId)
        if info then
            local cur = info.currentCharges
            local max = info.maxCharges
            if ZSBT.IsSafeNumber(cur) and ZSBT.IsSafeNumber(max) and max > 0 then
                return cur, max
            end
        end
    end
    return nil, nil
end

------------------------------------------------------------------------
-- Fire "ready" notification (debounce: 1s)
------------------------------------------------------------------------
local function FireReady(spellId, method)
    local state = Cooldowns._state[spellId]
    if state and state.lastFiredAt and (GetTime() - state.lastFiredAt) < 1.0 then
        return
    end
    if state then state.lastFiredAt = GetTime() end

    local spellName = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId)
        or (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellId))
        or ("Spell #" .. spellId)

    CdDebug(spellName .. " -> READY! (" .. method .. ")")

    local decide = ZSBT.Core and ZSBT.Core.Cooldowns
    if decide and decide.OnCooldownReady then
        decide:OnCooldownReady({
            spellId   = spellId,
            spellName = spellName,
            timestamp = GetTime(),
        })
    end
end

------------------------------------------------------------------------
-- Apply cooldown to the hidden CooldownFrame.
------------------------------------------------------------------------
local function ApplyCooldownToFrame(spellId)
    local cd = Cooldowns._cdFrames[spellId]
    if not cd then return false end

    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(spellId)
        if info and info.startTime and info.duration then
            cd:SetCooldown(info.startTime, info.duration)
            CdDebug("  Applied CD to frame for " .. spellId)
            return true
        end
    end

    return false
end

------------------------------------------------------------------------
-- Create a hidden CooldownFrame for a tracked spell.
------------------------------------------------------------------------
local function CreateCDFrame(spellId)
    if Cooldowns._cdFrames[spellId] then return end

    local parent = CreateFrame("Frame", nil, UIParent)
    parent:SetSize(1, 1)
    parent:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -100, -100)

    local cd = CreateFrame("Cooldown", nil, parent, "CooldownFrameTemplate")
    cd:SetAllPoints(parent)
    cd:SetHideCountdownNumbers(true)

    cd:SetScript("OnCooldownDone", function()
        if not Cooldowns._enabled then return end
        local state = Cooldowns._state[spellId]
        if not state or not state.isOnCD then return end

        state.isOnCD = false
        FireReady(spellId, "OnCooldownDone")

        -- Re-apply if still recharging (charge-based: 0->1, check for 1->2)
        C_Timer.After(0.2, function()
            if not Cooldowns._enabled then return end
            local st = Cooldowns._state[spellId]
            if not st then return end

            -- Check if spell is still on CD (another charge recharging)
            local applied = ApplyCooldownToFrame(spellId)
            if applied then
                st.isOnCD = true
                CdDebug("  Re-applied CD — tracking next charge for " .. spellId)
            end
        end)
    end)

    Cooldowns._cdFrames[spellId] = cd
end

local function EnsureTrackedInitialized(spellId)
	if not spellId then return end
	if not Cooldowns._cdFrames[spellId] then
		CreateCDFrame(spellId)
	end
	if not Cooldowns._state[spellId] then
		Cooldowns._state[spellId] = { isOnCD = false, lastFiredAt = 0, seenStart = false }
	end
end

------------------------------------------------------------------------
-- Cast Detection
------------------------------------------------------------------------
local function OnSpellcastSucceeded(_, event, unit, _, spellId)
    if unit ~= "player" then return end
    if not Cooldowns._enabled then return end
    if not spellId then return end

    local pdb = ZSBT.db and ZSBT.db.profile
    if not pdb or not pdb.cooldowns or not pdb.cooldowns.enabled then return end
    local cdb = ZSBT.db and ZSBT.db.char and ZSBT.db.char.cooldowns
    local tracked = cdb and cdb.tracked
    if not tracked then return end
    if not (tracked[spellId] or tracked[tostring(spellId)]) then return end
	EnsureTrackedInitialized(spellId)

    local name = ZSBT.CleanSpellName and ZSBT.CleanSpellName(spellId) or tostring(spellId)
    CdDebug("Cast: " .. name .. " (ID:" .. spellId .. ")")

    local state = Cooldowns._state[spellId] or {}
    state.isOnCD = true
    state.seenStart = true
    state.castTime = GetTime()
    Cooldowns._state[spellId] = state

    -- Delay to let the CD actually start, then apply
    C_Timer.After(0.15, function()
        if not Cooldowns._enabled then return end
        local applied = ApplyCooldownToFrame(spellId)
        CdDebug("  Applied CD: " .. tostring(applied))
    end)
end

------------------------------------------------------------------------
-- SPELL_UPDATE events: out-of-combat fallback
------------------------------------------------------------------------
local function OnSpellUpdate(source)
    if not Cooldowns._enabled then return end
    local pdb = ZSBT.db and ZSBT.db.profile
    if not pdb or not pdb.cooldowns or not pdb.cooldowns.enabled then return end
    local cdb = ZSBT.db and ZSBT.db.char and ZSBT.db.char.cooldowns
    local tracked = cdb and cdb.tracked
    if type(tracked) ~= "table" then return end

	-- Many spells report the Global Cooldown as a spell cooldown.
	-- We only want to treat "real" cooldowns as state transitions.
	local MIN_REAL_CD_SEC = 1.7

    for idKey, _ in pairs(tracked) do
        local spellId = tonumber(idKey)
        if spellId then
            EnsureTrackedInitialized(spellId)
            local state = Cooldowns._state[spellId]
            if C_Spell and C_Spell.GetSpellCooldown and state then
				local info = C_Spell.GetSpellCooldown(spellId)
				local dur = info and info.duration
				local start = info and info.startTime

				-- If cast detection missed (macro, talent edge cases), we still want to
				-- treat the spell as "on cooldown" as soon as we observe a real cooldown.
				if state.isOnCD ~= true
					and ZSBT.IsSafeNumber(dur) and ZSBT.IsSafeNumber(start)
					and dur and dur > MIN_REAL_CD_SEC and start and start > 0 then
					state.isOnCD = true
					state.seenStart = true
					ApplyCooldownToFrame(spellId)
					CdDebug("  Observed CD start via " .. tostring(source) .. " for " .. tostring(spellId))
				end

				-- If we were on CD and duration hits 0, fire ready.
				if state.isOnCD == true and info and ZSBT.IsSafeNumber(dur) and dur == 0 then
					state.isOnCD = false
					if state.seenStart == true then
						state.seenStart = false
						FireReady(spellId, source .. "/dur=0")
					else
						CdDebug("  Suppressed READY (no observed start) for " .. tostring(spellId) .. " via " .. tostring(source))
					end
				end
			end
        end
    end
end

------------------------------------------------------------------------
-- Enable / Disable
------------------------------------------------------------------------
function Cooldowns:Enable()
    if self._enabled then return end

	-- Many spells report the Global Cooldown as a spell cooldown.
	-- We only want to treat "real" cooldowns as state transitions.
	local MIN_REAL_CD_SEC = 1.7

    if not self._frame then
        self._frame = CreateFrame("Frame")
        self._frame:SetScript("OnEvent", function(_, event, ...)
            if event == "UNIT_SPELLCAST_SUCCEEDED" then
                OnSpellcastSucceeded(nil, event, ...)
            elseif event == "SPELL_UPDATE_CHARGES" then
                C_Timer.After(0.15, function()
                    if Cooldowns._enabled then OnSpellUpdate("CHARGES") end
                end)
            elseif event == "SPELL_UPDATE_COOLDOWN" then
                OnSpellUpdate("CD_EVENT")
            end
        end)
    end

    self._frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    self._frame:RegisterEvent("SPELL_UPDATE_CHARGES")
    self._frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")

    self._state = {}
    self._enabled = true

    local pdb = ZSBT.db and ZSBT.db.profile
    local cdb = ZSBT.db and ZSBT.db.char and ZSBT.db.char.cooldowns
    local tracked = cdb and cdb.tracked
    if pdb and pdb.cooldowns and pdb.cooldowns.enabled and type(tracked) == "table" then
        local names = {}
        for idKey, _ in pairs(tracked) do
            local sid = tonumber(idKey)
            if sid then
                local n = ZSBT.CleanSpellName and ZSBT.CleanSpellName(sid) or tostring(sid)
                names[#names + 1] = n
                CreateCDFrame(sid)
                self._state[sid] = { isOnCD = false, lastFiredAt = 0, seenStart = false }

                -- Seed current cooldown state (helps when enabling mid-cooldown).
                if C_Spell and C_Spell.GetSpellCooldown then
                    local info = C_Spell.GetSpellCooldown(sid)
                    local dur = info and info.duration
                    local start = info and info.startTime
                    if ZSBT.IsSafeNumber(dur) and ZSBT.IsSafeNumber(start)
                        and dur and dur > MIN_REAL_CD_SEC and start and start > 0 then
                        self._state[sid].isOnCD = true
                        ApplyCooldownToFrame(sid)
                    end
                end
            end
        end
        CdDebug("Enabled. Tracking: " .. table.concat(names, ", "))
    end
end

function Cooldowns:Disable()
    if not self._enabled then return end
    if self._frame then
        self._frame:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        self._frame:UnregisterEvent("SPELL_UPDATE_CHARGES")
        self._frame:UnregisterEvent("SPELL_UPDATE_COOLDOWN")
    end
    for _, cd in pairs(self._cdFrames) do
        cd:SetCooldown(0, 0)
    end
    self._state = {}
    self._enabled = false
    CdDebug("Disabled.")
end
