------------------------------------------------------------------------
-- ZSBT - Cooldowns Decision Layer
-- Receives COOLDOWN_READY events from the parser, formats the
-- notification text, plays the configured sound, and emits to display.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.Core = ZSBT.Core or {}
ZSBT.Core.Cooldowns = ZSBT.Core.Cooldowns or {}
local Cooldowns = ZSBT.Core.Cooldowns
local Addon     = ZSBT.Addon

local function CdDbg(requiredLevel, msg)
	if not (Addon and Addon.Print) then return end
	local level = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics
		and ZSBT.db.profile.diagnostics.cooldownsDebugLevel or 0
	if level and level >= requiredLevel then
		Addon:Print("|cFF00CCFF[CD]|r " .. tostring(msg))
	end
end

function Cooldowns:Enable()
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Cooldowns:Enable()")
    end
end

function Cooldowns:Disable()
    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(1, "Cooldowns:Disable()")
    end
end

------------------------------------------------------------------------
-- Contract: Parser.Cooldowns calls this when a spell comes off cooldown.
-- event = { spellId, spellName, timestamp }
------------------------------------------------------------------------
function Cooldowns:OnCooldownReady(event)
    if not event or not event.spellName then return end

    local db = ZSBT.db and ZSBT.db.profile
	CdDbg(2, "OnCooldownReady spellId=" .. tostring(event.spellId) .. " spellName=" .. tostring(event.spellName))
    if not db or not db.cooldowns or not db.cooldowns.enabled then
		CdDbg(1, "Cooldowns notify suppressed: db.cooldowns.enabled is false")
		return
	end
	if ZSBT.Core and ZSBT.Core.IsNotificationCategoryEnabled then
		if ZSBT.Core:IsNotificationCategoryEnabled("cooldowns") == false then
			CdDbg(1, "Cooldowns notify suppressed: Notifications category 'cooldowns' disabled")
			return
		end
	end

    -- Format the notification text
    local fmt = db.cooldowns.format or "%s Ready!"
    local text = fmt:format(event.spellName)

    -- Determine scroll area
    local area = db.cooldowns.scrollArea or "Notifications"

    -- Color: bright yellow for cooldown readiness
    local color = { r = 1.0, g = 0.82, b = 0.0 }

    -- Play configured sound
    local soundKey = db.cooldowns and db.cooldowns.sound
    if (not soundKey) or soundKey == "None" then
        soundKey = db.media and db.media.sounds and db.media.sounds.cooldownReady
    end
    if soundKey and soundKey ~= "None" and ZSBT.PlayLSMSound then
        ZSBT.PlayLSMSound(soundKey)
    end

    -- Emit to display
    local meta = { kind = "notification", cooldown = true, spellId = event.spellId }
    if ZSBT.DisplayText then
        ZSBT.DisplayText(area, text, color, meta)
    elseif ZSBT.Core and ZSBT.Core.Display and ZSBT.Core.Display.Emit then
        ZSBT.Core.Display:Emit(area, text, color, meta)
	else
		CdDbg(1, "Cooldowns notify suppressed: no display backend")
    end

	-- Fire custom triggers (optional)
	local trg = ZSBT.Core and ZSBT.Core.Triggers
	if trg and trg.OnCooldownReady then
		trg:OnCooldownReady(event)
	end

    if Addon and Addon.DebugPrint then
        Addon:DebugPrint(2, "Cooldown ready: " .. text)
    end
end
