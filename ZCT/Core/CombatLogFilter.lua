------------------------------------------------------------------------
-- Zore's Combat Text - Color-Coded Combat-Log Filter
-- Writes the "ZCT" filter into Blizzard_CombatLog_Filters at
-- PLAYER_LOGOUT (mid-session application can taint the secure
-- combat-log processor) and verifies it at login. While our filter is
-- active the combat log shows only player+pet lines — accepted tradeoff
-- shared with the legacy ZSBT design. See CLAUDE.md.
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
ZSBT.ZCT = ZSBT.ZCT or {}
local ZCT = ZSBT.ZCT

ZCT = ZCT or {}
ZCT.CombatLogFilter = ZCT.CombatLogFilter or {}
local Filter = ZCT.CombatLogFilter

Filter._pairingTrusted = false
Filter._verified = false

local FILTER_NAME = ZCT.FILTER_NAME or "ZCT"
local KIND_COLORS = ZCT.KIND_COLORS
local EVENT_KINDS = ZCT.EVENT_KINDS
local LOG_EVENT_KINDS = ZCT.LOG_EVENT_KINDS or {}

local function copyValue(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = copyValue(val) end
    return out
end

-- Deep-enough compare of our palette against a filter's eventColoring.
-- Pairing kinds are strict (drift breaks attribution). Log-only kinds are
-- lenient: an older filter written before they existed still pairs fine,
-- so a missing entry is OK — a wrong one is not.
local function colorMatches(got, want)
    return type(got) == "table" and type(want) == "table"
        and math.abs((got.r or -1) - want[1]) <= 0.02
        and math.abs((got.g or -1) - want[2]) <= 0.02
        and math.abs((got.b or -1) - want[3]) <= 0.02
end

local function paletteMatches(ec)
    if type(ec) ~= "table" then return false end
    for event, kind in pairs(EVENT_KINDS) do
        if not colorMatches(ec[event], KIND_COLORS[kind]) then return false end
    end
    for event, kind in pairs(LOG_EVENT_KINDS) do
        local got = ec[event]
        if got ~= nil and not colorMatches(got, KIND_COLORS[kind]) then
            return false
        end
    end
    return true
end

-- Our filter is one or two parts:
--   source part: sourceFlags = {MINE, MY_PET} only, no destFlags on
--   dest part:   destFlags   = {MINE, MY_PET} only, no sourceFlags on
-- The one-part (source-only) shape is the pre-incoming format and stays
-- trusted so outgoing pairing doesn't break before the next logout
-- rewrites the filter.
local function sourcesRestricted(f)
    local mineFlag = COMBATLOG_FILTER_MINE
    local petFlag = COMBATLOG_FILTER_MY_PET
    if type(mineFlag) ~= "number" or type(petFlag) ~= "number" then return false end
    if type(f.filters) ~= "table" or #f.filters == 0 then return false end
    local sawSource = false
    for _, part in ipairs(f.filters) do
        if type(part) ~= "table" then return false end
        local sf, df = part.sourceFlags, part.destFlags
        local srcOk = type(sf) == "table"
            and sf[mineFlag] == true and sf[petFlag] == true
        local dstOk = type(df) == "table"
            and df[mineFlag] == true and df[petFlag] == true
        if srcOk then
            for flag, on in pairs(sf) do
                if on and flag ~= mineFlag and flag ~= petFlag then srcOk = false break end
            end
        end
        if dstOk then
            for flag, on in pairs(df) do
                if on and flag ~= mineFlag and flag ~= petFlag then dstOk = false break end
            end
        end
        if srcOk and not dstOk then
            -- Source part: destFlags must be absent or all-false.
            if df ~= nil then
                for _, on in pairs(df) do
                    if on then srcOk = false break end
                end
            end
        elseif dstOk and not srcOk then
            -- Dest part: sourceFlags must be absent or all-false.
            if sf ~= nil then
                for _, on in pairs(sf) do
                    if on then dstOk = false break end
                end
            end
        else
            return false
        end
        if srcOk then sawSource = true end
    end
    return sawSource
end

-- Is the ACTIVE combat-log filter ours, palette intact, sources restricted?
-- Returns ok, reason (reason explains a false result for status/warnings).
function Filter:IsReady()
    local saved = _G.Blizzard_CombatLog_Filters
    if type(saved) ~= "table" or type(saved.filters) ~= "table" then
        return false, "no combat-log filter data"
    end
    local cur = saved.currentFilter
    local f = type(cur) == "number" and saved.filters[cur] or nil
    if type(f) ~= "table" then return false, "no current filter" end
    if f.name ~= FILTER_NAME then
        return false, ("current filter is '%s', not '%s'"):format(tostring(f.name), FILTER_NAME)
    end
    -- Cross-check what the UI actually applied: Blizzard_CombatLog keeps a
    -- global pointing at the live filter settings. If it exists and names a
    -- different filter, the saved-var index alone is lying to us.
    local applied = _G.Blizzard_CombatLog_CurrentSettings
    if type(applied) == "table" and type(applied.name) == "string"
        and applied.name ~= f.name then
        return false, ("applied filter is '%s', not '%s'"):format(applied.name, FILTER_NAME)
    end
    local settings = f.settings
    if type(settings) ~= "table" or settings.lineColoring ~= true then
        return false, "line coloring off"
    end
    local colors = f.colors
    if type(colors) ~= "table" or not paletteMatches(colors.eventColoring) then
        return false, "palette changed"
    end
    if not sourcesRestricted(f) then return false, "sources not restricted to you+pet" end
    return true, nil
end

function Filter:IsPairingTrusted()
    return Filter._pairingTrusted == true
end

local function findOurIndex()
    local saved = _G.Blizzard_CombatLog_Filters
    if type(saved) ~= "table" or type(saved.filters) ~= "table" then return nil end
    for i, f in ipairs(saved.filters) do
        if type(f) == "table" and f.name == FILTER_NAME then return i end
    end
    return nil
end

-- Slow poll: the filter-change events don't fire reliably on every client,
-- so detection can't depend on them. Verifies every tick (cheap) so the
-- popup path always engages. NOTE: refocusing is impossible — the apply
-- path (QuickButton_OnClick -> ApplyFilterSettings -> ClearEventFilters)
-- is protected; only the user can switch the filter back.
function Filter:Tick()
    local now = GetTime and GetTime() or 0
    if now - (Filter._tickAt or 0) < 1 then return end
    Filter._tickAt = now

    local idx = findOurIndex()
    if not idx then return end -- not installed yet; written at logout
    local saved = _G.Blizzard_CombatLog_Filters
    if tonumber(saved.currentFilter) == idx then
        Filter:Verify()
        return
    end

    Filter:Verify() -- keep the warning/popup path live
end

-- Re-verify against live saved vars (called on login + filter-change events).
local function say(msg)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end
end

function Filter:Verify()
    Filter._verified = true
    local ok, why = Filter:IsReady()
    local was = Filter._lastTrusted
    Filter._pairingTrusted = ok
    Filter._reason = why
    Filter._lastTrusted = ok
    -- Tell the player on every change, then re-remind every 30s while the
    -- filter stays broken — the chat line alone gets missed. ZCT can't
    -- switch the filter back itself (the apply path is protected), so the
    -- popup is the only way to reach them.
    local now = GetTime and GetTime() or 0
    if ok then
        Filter._popupAt = nil
        Filter._lastWarnAt = nil
        if was == false then
            say(("|cff66aaff[ZSBT]|r The '%s' combat log filter is active again — outgoing text restored.")
                :format(FILTER_NAME))
        end
    elseif was ~= false or (now - (Filter._lastWarnAt or 0)) >= 30 then
        local saved = _G.Blizzard_CombatLog_Filters
        local exists = false
        if type(saved) == "table" and type(saved.filters) == "table" then
            for _, f in ipairs(saved.filters) do
                if type(f) == "table" and f.name == FILTER_NAME then exists = true end
            end
        end
        Filter._lastWarnAt = now
        if exists then
            local whyText = tostring(why)
            say(("|cffdd5555[ZSBT]|r Outgoing text needs the '%s' combat log filter (%s). "
                .. "Click the %s button at the top of the combat log.")
                :format(FILTER_NAME, whyText, FILTER_NAME))
            Filter:ShowLostPopup(whyText)
        else
            say(("|cffdd5555[ZSBT]|r The '%s' combat log filter is installed when you log "
                .. "out. Log out and back in to enable outgoing text.")
                :format(FILTER_NAME))
        end
    end
    if ZCT.Dbg and ZCT.Dbg.Enabled and ZCT.Dbg:Enabled("filter") then
        ZCT.Dbg:Info("filter", "verify: pairingTrusted=%s", tostring(Filter._pairingTrusted))
    end
    return Filter._pairingTrusted
end

-- Popup shown when the player switches the combat-log filter away from
-- ours — the chat line alone gets missed. Throttled so a flapping filter
-- doesn't stack popups.
function Filter:ShowLostPopup(why)
    local now = GetTime and GetTime() or 0
    if Filter._popupAt and (now - Filter._popupAt) < 5 then return end
    if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then return end
    Filter._popupAt = now

    StaticPopupDialogs["ZSBT_COMBAT_LOG_FILTER"] = {
        text = ("|cffdd5555ZSBT|r outgoing combat text is off.\n\n"
            .. "The '%s' combat log filter is no longer selected (%s).\n\n"
            .. "Click the %s button at the top of the combat log to turn it back on.")
            :format(FILTER_NAME, tostring(why), FILTER_NAME),
        button1 = "Open Combat Log",
        button2 = "Later",
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        OnAccept = function()
            local cl = _G.COMBATLOG
            if type(cl) == "table" or type(cl) == "userdata" then
                if cl.Show then cl:Show() end
                if cl.SetAlpha then cl:SetAlpha(1) end
            end
        end,
        OnCancel = function() end,
    }
    StaticPopup_Show("ZSBT_COMBAT_LOG_FILTER")
end

-- Write (or refresh) the "ZCT" filter. MUST run at PLAYER_LOGOUT — applying
-- filter settings mid-session can taint Blizzard's secure processor.
function Filter:InstallAtLogout()
    local saved = _G.Blizzard_CombatLog_Filters
    if type(saved) ~= "table" or type(saved.filters) ~= "table" then return false end

    -- Clone the user's current filter so the log keeps showing everything
    -- it did; we only overlay event colours for the kinds we classify.
    local current = saved.currentFilter
    local template = (type(current) == "number" and saved.filters[current]) or saved.filters[1]
    if type(template) ~= "table" then return false end

    local filter = copyValue(template)
    filter.name = FILTER_NAME
    filter.quickButtonName = FILTER_NAME
    filter.hasQuickButton = true
    filter.tooltip = FILTER_NAME

    filter.settings = filter.settings or {}
    filter.settings.lineColoring = true
    filter.settings.lineColorPriority = 3
    filter.settings.lineHighlighting = false

    filter.colors = filter.colors or {}
    filter.colors.eventColoring = filter.colors.eventColoring or {}
    for event, kind in pairs(EVENT_KINDS) do
        local c = KIND_COLORS[kind]
        filter.colors.eventColoring[event] = { r = c[1], g = c[2], b = c[3], a = 1 }
    end
    for event, kind in pairs(LOG_EVENT_KINDS) do
        local c = KIND_COLORS[kind]
        filter.colors.eventColoring[event] = { r = c[1], g = c[2], b = c[3], a = 1 }
    end
    filter.colors.highlightedEvents = filter.colors.highlightedEvents or {}

    -- Two-part filter:
    --   part 1 (source): sourceFlags = you+pet — every event our outgoing
    --     pairing can claim. eventList preserves whatever the template's
    --     parts listed (union; nil = all events, same as before).
    --   part 2 (dest):   destFlags = you+pet, eventList = log-only
    --     utility events (interrupts, dispels, steals, kills). Damage/
    --     heal/miss events are excluded on purpose: they share event
    --     names with outgoing events, so their lines can't be told apart
    --     and would corrupt the pairing buffer.
    local mineFlag = COMBATLOG_FILTER_MINE
    local petFlag = COMBATLOG_FILTER_MY_PET
    if type(mineFlag) == "number" and type(petFlag) == "number" then
        local srcEvents
        if type(filter.filters) == "table" then
            for _, p in ipairs(filter.filters) do
                if type(p) == "table" and type(p.eventList) == "table" then
                    srcEvents = srcEvents or {}
                    for ev, on in pairs(p.eventList) do
                        if on then srcEvents[ev] = true end
                    end
                end
            end
        end
        local inEvents = {}
        for event in pairs(ZCT.INCOMING_LINE_EVENTS or {}) do
            inEvents[event] = true
        end
        filter.filters = {
            {
                sourceFlags = { [mineFlag] = true, [petFlag] = true },
                eventList = srcEvents,
            },
            {
                destFlags = { [mineFlag] = true, [petFlag] = true },
                eventList = inEvents,
            },
        }
    end

    local index
    for i, f in ipairs(saved.filters) do
        if type(f) == "table" and f.name == FILTER_NAME then
            index = i
            break
        end
    end
    index = index or (#saved.filters + 1)
    saved.filters[index] = filter
    saved.currentFilter = index

    if ZCT.Dbg and ZCT.Dbg.Enabled and ZCT.Dbg:Enabled("filter") then
        ZCT.Dbg:Info("filter", "filter '%s' written at index %d", FILTER_NAME, index)
    end
    return true
end

-- Blizzard_CombatLog turns filtered events OFF whenever the Combat Log
-- chat window hides (COMBATLOG OnHide -> SetFilteredEventsEnabled(false)),
-- e.g. switching chat tabs or a chat addon parking the window. That kills
-- COMBAT_LOG_MESSAGE and with it all outgoing text. Post-hook OnHide and
-- turn the feed straight back on (display is unaffected — the hidden
-- window shows nothing). Hooked after Blizzard_CombatLog sets its own
-- OnHide, or SetScript would wipe our hook.
local function keepFeedOn()
    if C_CombatLog and C_CombatLog.SetFilteredEventsEnabled then
        pcall(C_CombatLog.SetFilteredEventsEnabled, true)
    end
    Filter.feedRestores = (Filter.feedRestores or 0) + 1
end

function Filter:HookCombatLogWindow()
    if self._hookedLog then return true end
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    local loaded = isLoaded and isLoaded("Blizzard_CombatLog")
    local cl = _G.COMBATLOG or _G.ChatFrame2
    if not loaded or type(cl) ~= "table" or not cl.HookScript then return false end
    cl:HookScript("OnHide", keepFeedOn)
    -- Quick-button clicks switch the current filter; re-check right after.
    if type(_G.Blizzard_CombatLog_QuickButton_OnClick) == "function" then
        hooksecurefunc("Blizzard_CombatLog_QuickButton_OnClick", function()
            Filter:Verify()
        end)
    end
    self._hookedLog = true
    return true
end

-- Frame wiring: filter lifecycle events.
if not Filter._frame then
    Filter._frame = CreateFrame("Frame")
    Filter._frame:RegisterEvent("PLAYER_LOGOUT")
    Filter._frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    pcall(Filter._frame.RegisterEvent, Filter._frame, "COMBAT_LOG_APPLY_FILTER_SETTINGS")
    Filter._frame:RegisterEvent("ADDON_LOADED")
    -- Belt and braces: the feed may already be off before our OnHide hook
    -- exists (window hidden at load). Entering combat re-arms it so the
    -- first hits of a fight aren't lost.
    Filter._frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    Filter._frame:SetScript("OnEvent", function(_, event, arg1)
        if event == "PLAYER_REGEN_DISABLED" then
            Filter:HookCombatLogWindow()
            keepFeedOn()
        elseif event == "ADDON_LOADED" then
            if arg1 == "Blizzard_CombatLog" or arg1 == ADDON_NAME then
                Filter:HookCombatLogWindow()
            end
        elseif event == "PLAYER_LOGOUT" then
            Filter:InstallAtLogout()
        elseif event == "PLAYER_ENTERING_WORLD" then
            Filter:HookCombatLogWindow()
            Filter:Verify()
        elseif event == "COMBAT_LOG_APPLY_FILTER_SETTINGS" then
            -- User changed filters in the combat-log UI; re-check cheaply.
            C_Timer.After(0.5, function() Filter:Verify() end)
        end
    end)
end

-- Detection can't rely on filter-change events alone (they don't fire on
-- every client) — poll lightly so drift always surfaces.
if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(1, function() Filter:Tick() end)
end
