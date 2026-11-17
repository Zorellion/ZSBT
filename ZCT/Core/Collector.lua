------------------------------------------------------------------------
-- Zore's Combat Text - Event Collector
-- Single frame registering every whitelisted event. Phase 1 role: feed
-- the Probe (empirical arg signatures) and LogLines (palette classify).
-- Feature handlers arrive in Phase 2+ and consume ONLY probe-confirmed
-- arg slots.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
ZSBT.ZCT = ZSBT.ZCT or {}
local ZCT = ZSBT.ZCT

ZCT = ZCT or {}
ZCT.Collector = ZCT.Collector or {}
local Collector = ZCT.Collector

Collector._enabled = false

local function safeCall(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local msg = ("|cffdd5555[ZCT handler error:%s]|r %s"):format(label, tostring(err))
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage(msg)
        end
    end
end

local function route(event, ...)
    -- NOTE: the Probe watches the same events on its own frame — do NOT
    -- record here too or every signature would be counted twice.
    if event == "COMBAT_LOG_MESSAGE" and ZCT.LogLines then
        local _, r, g, b = ...
        safeCall("lines", ZCT.LogLines.RecordLine, ZCT.LogLines, r, g, b)
    elseif event == "COMBAT_TEXT_UPDATE" and ZCT.Incoming then
        safeCall("ct", ZCT.Incoming.HandleCombatText, ZCT.Incoming, ...)
    elseif event == "UNIT_COMBAT" then
        if ZCT.Incoming then
            safeCall("uc-in", ZCT.Incoming.HandleUnitCombat, ZCT.Incoming, ...)
        end
        if ZCT.Outgoing then
            safeCall("uc-out", ZCT.Outgoing.HandleUnitCombat, ZCT.Outgoing, ...)
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" and ZCT.Outgoing then
        safeCall("cast", ZCT.Outgoing.HandleSpellCast, ZCT.Outgoing, ...)
    elseif (event == "UNIT_HEALTH" or event == "UNIT_HEALTH_FREQUENT")
        and ZCT.Outgoing and ZCT.Outgoing.NoteHealth then
        safeCall("hp", ZCT.Outgoing.NoteHealth, ZCT.Outgoing, ...)
    end
end

function Collector:Enable()
    if self._enabled then return end
    self._enabled = true

    if not self._frame then
        self._frame = CreateFrame("Frame")
        self._frame:SetScript("OnEvent", function(_, event, ...)
            route(event, ...)
        end)
    end

    for _, evt in ipairs(ZCT.WATCHED_EVENTS or {}) do
        pcall(self._frame.RegisterEvent, self._frame, evt)
    end
    -- UNIT_HEALTH_FREQUENT may not exist on all builds.
    -- COMBAT_LOG_MESSAGE only fires while filtered combat-log events are
    -- enabled; display is unaffected — the chat window controls visibility.
    if C_CombatLog and C_CombatLog.SetFilteredEventsEnabled then
        pcall(C_CombatLog.SetFilteredEventsEnabled, true)
    end

    -- Probe watches the same events independently (its own frame) so the
    -- arg map keeps recording even if feature routing changes later.
    if ZCT.Probe and ZCT.Probe.WatchDefaults then
        ZCT.Probe:WatchDefaults()
    end
end

function Collector:Disable()
    if not self._enabled then return end
    self._enabled = false
    if self._frame then
        for _, evt in ipairs(ZCT.WATCHED_EVENTS or {}) do
            pcall(self._frame.UnregisterEvent, self._frame, evt)
        end
    end
end
