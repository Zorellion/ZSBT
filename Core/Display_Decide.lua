------------------------------------------------------------------------
-- ZSBT - Display Decision Layer
-- Responsibility: accept "emit requests" and route to the active render
-- system.
--
-- For now (UI/UX harness phase): use ScrollAreaFrames.lua test renderer
-- (ZSBT.FireTestText) as the common animation sink.
------------------------------------------------------------------------

local ADDON_NAME, ZSBT = ...

ZSBT.Core = ZSBT.Core or {}
ZSBT.Core.Display = ZSBT.Core.Display or {}
local Display = ZSBT.Core.Display
local Addon   = ZSBT.Addon

local function ResolveFontForArea(areaName)
    local profile = ZSBT.db and ZSBT.db.profile
    if not profile then
        return "Fonts\\FRIZQT__.TTF", 18, "OUTLINE", 1.0
    end

    local general = (profile.general and profile.general.font) or {}
    local area = (profile.scrollAreas and profile.scrollAreas[areaName]) or nil
    local areaFont = area and area.font or nil

    local useGlobal = true
    if areaFont and areaFont.useGlobal == false then
        useGlobal = false
    end

    local faceKey    = (not useGlobal and areaFont and areaFont.face)    or general.face or "Friz Quadrata TT"
    local sizeVal    = (not useGlobal and areaFont and areaFont.size)    or general.size or 18
    local outlineKey = (not useGlobal and areaFont and areaFont.outline) or general.outline or "Thin"
    local alphaVal   = (not useGlobal and areaFont and areaFont.alpha)   or general.alpha or 1.0

    local LSM = LibStub("LibSharedMedia-3.0", true)
    local fontFace = "Fonts\\FRIZQT__.TTF" -- fallback
    if LSM and faceKey then
        local fetched = LSM:Fetch("font", faceKey)
        if fetched then fontFace = fetched end
    end

    local fontSize = tonumber(sizeVal) or 18
    local outlineFlag = ZSBT.OUTLINE_STYLES and ZSBT.OUTLINE_STYLES[outlineKey] or "OUTLINE"
    local fontAlpha = tonumber(alphaVal) or 1.0

    return fontFace, fontSize, outlineFlag, fontAlpha
end

function Display:Enable()
	if Addon and Addon.Dbg then
		Addon:Dbg("ui", 3, "Display:Enable()")
	elseif Addon and Addon.DebugPrint then
		Addon:DebugPrint(1, "Display:Enable()")
	end
end

function Display:Disable()
	if Addon and Addon.Dbg then
		Addon:Dbg("ui", 3, "Display:Disable()")
	elseif Addon and Addon.DebugPrint then
		Addon:DebugPrint(1, "Display:Disable()")
	end
end

local function ResolveCritFont(meta)
    local profile = ZSBT.db and ZSBT.db.profile
    if not profile or not profile.general then
        return nil, 28, "THICKOUTLINE", 1.5, "Pow"
    end

    local critConf = profile.general.critFont or {}
    if meta and meta.stream == "incoming" then
        local usedKindOverride = false
        local ik = meta.kind
        if ik == "heal" then
            local hc = profile.incoming and profile.incoming.critHealing
            if type(hc) == "table" then
                local hk = hc.critFont
                if type(hk) == "table" and hk.enabled == true then
                    critConf = hk
                    usedKindOverride = true
                end
            end
        else
            local dc = profile.incoming and profile.incoming.critDamage
            if type(dc) == "table" then
                local dk = dc.critFont
                if type(dk) == "table" and dk.enabled == true then
                    critConf = dk
                    usedKindOverride = true
                end
            end
        end

        if not usedKindOverride then
            local ic = profile.incoming and profile.incoming.critFont
            if type(ic) == "table" and ic.enabled == true then
                critConf = ic
            end
        end
    elseif meta and meta.stream == "outgoing" then
        local usedKindOverride = false
        local ok = meta.kind
        if ok == "heal" then
            local hc = profile.outgoing and profile.outgoing.critHealing
            if type(hc) == "table" then
                local hk = hc.critFont
                if type(hk) == "table" and hk.enabled == true then
                    critConf = hk
                    usedKindOverride = true
                end
            end
        else
            local dc = profile.outgoing and profile.outgoing.critDamage
            if type(dc) == "table" then
                local dk = dc.critFont
                if type(dk) == "table" and dk.enabled == true then
                    critConf = dk
                    usedKindOverride = true
                end
            end
        end

        if not usedKindOverride then
            local oc = profile.outgoing and profile.outgoing.critFont
            if type(oc) == "table" and oc.enabled == true then
                critConf = oc
            end
        end
    end
    local general = profile.general.font or {}

    -- Face: use crit override or fall back to master
    local faceKey = critConf.face or general.face or "Friz Quadrata TT"
    local LSM = LibStub("LibSharedMedia-3.0", true)
    local critFace = "Fonts\\FRIZQT__.TTF"
    if LSM and faceKey then
        local fetched = LSM:Fetch("font", faceKey)
        if fetched then critFace = fetched end
    end

    local critSize = tonumber(critConf.size) or 28
    if critConf.useScale == true then
        critSize = nil
    end
    local outlineKey = critConf.outline or "Thick"
    local critOutline = ZSBT.OUTLINE_STYLES and ZSBT.OUTLINE_STYLES[outlineKey] or "THICKOUTLINE"
    local critScale = tonumber(critConf.scale) or 1.5

    local globalCrit = profile.general.critFont
    local mode = critConf.anim
    if mode ~= "Area" and mode ~= "Pow" then
        mode = globalCrit and globalCrit.anim
    end
    if mode ~= "Area" and mode ~= "Pow" then
        mode = "Pow"
    end

    return critFace, critSize, critOutline, critScale, mode
end

------------------------------------------------------------------------
-- AoE Merge Buffer
-- Accumulates rapid-fire events in the same scroll area and combines
-- them into a single display line with count (e.g., "4,271 (x3)").
-- Only merges clean (non-tainted) numeric text. Crits and misses
-- always display individually.
------------------------------------------------------------------------
local mergeBuffer = {}

local function FlushMergeByKey(key)
	local tok = ZSBT.Addon and ZSBT.Addon.PerfBegin and ZSBT.Addon:PerfBegin("UI.FlushMerge")
	local entry = mergeBuffer[key]
	if not entry then return end
	mergeBuffer[key] = nil

    -- Cancel the flush timer to prevent orphaned callback
    if entry.timer then
        entry.timer:Cancel()
        entry.timer = nil
    end

    local text = entry.text
    local showCount = entry.showCount == true
    if entry.count > 1 then
        if entry.mode == "numeric" and type(entry.totalAmount) == "number" and entry.totalAmount > 0 then
            text = tostring(math.floor(entry.totalAmount + 0.5))
            if showCount then
                text = text .. " (x" .. entry.count .. ")"
            end
        elseif showCount then
            -- Secret/tainted or non-numeric text: count-only (no math).
            -- Keep the base label text and append count.
            if ZSBT.IsSafeString(text) then
                text = text .. " (x" .. entry.count .. ")"
            else
                text = "Hits (x" .. entry.count .. ")"
            end
        end
    end

    ZSBT.FireTestText(text, entry.area, entry.fontFace, entry.fontSize,
        entry.outlineFlag, entry.fontAlpha, entry.anchorH, entry.dirMult,
        entry.duration, entry.color, entry.meta)
    if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
end

local function FlushMergesForArea(areaName)
	for k, e in pairs(mergeBuffer) do
		if type(e) == "table" and e.areaName == areaName then
			FlushMergeByKey(k)
		end
	end
end

local function TryMerge(areaName, text, area, fontFace, fontSize, outlineFlag,
						fontAlpha, anchorH, dirMult, duration, color, meta)
	local tok = ZSBT.Addon and ZSBT.Addon.PerfBegin and ZSBT.Addon:PerfBegin("UI.TryMerge")
	-- Check if merging is enabled
	local profile = ZSBT.db and ZSBT.db.profile
	local mergeConf = profile and profile.spamControl and profile.spamControl.merging
	if not mergeConf or not mergeConf.enabled then
		FlushMergesForArea(areaName)
		ZSBT.FireTestText(text, area, fontFace, fontSize, outlineFlag,
			fontAlpha, anchorH, dirMult, duration, color, meta)
		if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
		return
	end

	-- Don't merge: crits, misses, notifications, or tainted raw pipe values
	local isCrit = meta and meta.isCrit
	local isMiss = meta and meta.kind == "miss"
	local isNotification = meta and meta.kind == "notification"
	if isCrit or isMiss or isNotification then
		FlushMergesForArea(areaName)
		ZSBT.FireTestText(text, area, fontFace, fontSize, outlineFlag,
			fontAlpha, anchorH, dirMult, duration, color, meta)
		if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
		return
	end

	local spellId = meta and meta.spellId
	local canSpellMerge = false
	if type(spellId) == "number" then
		-- In WoW 12.x, spellId can be a secret number; never compare it unless it's safe.
		if ZSBT.IsSafeNumber and not ZSBT.IsSafeNumber(spellId) then
			canSpellMerge = false
		elseif spellId > 0 then
			canSpellMerge = true
		end
	end
	if not canSpellMerge then
		-- Avoid merging unrelated events: if we can't key by spellId, do not merge.
		FlushMergesForArea(areaName)
		ZSBT.FireTestText(text, area, fontFace, fontSize, outlineFlag,
			fontAlpha, anchorH, dirMult, duration, color, meta)
		if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
		return
	end

	local window = tonumber(mergeConf.window) or 1.5
	local showCount = mergeConf.showCount == true
	local maxMerge = 8  -- never hold more than 8 hits

	local numVal = tonumber(text:match("^[+-]?%d+"))
	local mode = (numVal ~= nil and ZSBT.IsSafeString and ZSBT.IsSafeString(text)) and "numeric" or "secret"

	-- Key by scroll area + spellId so we merge per spell per window.
	local key = tostring(areaName) .. ":" .. tostring(spellId)
	local existing = mergeBuffer[key]
	if existing then
		local elapsed = GetTime() - existing.lastUpdate
		if elapsed < window and existing.count < maxMerge then
			existing.count = existing.count + 1
			existing.lastUpdate = GetTime()
			if existing.mode == "numeric" and mode == "numeric" and numVal and type(existing.totalAmount) == "number" then
				existing.totalAmount = existing.totalAmount + numVal
			else
				existing.mode = "secret"
				existing.totalAmount = nil
			end
			if existing.timer then
				existing.timer:Cancel()
			end
			existing.timer = C_Timer.NewTimer(window, function()
				FlushMergeByKey(key)
			end)
			if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
			return
		else
			FlushMergeByKey(key)
		end
	end

	-- Start new merge entry with short flush timer
	mergeBuffer[key] = {
		areaName = areaName,
		showCount = showCount,
		text = text,
		mode = mode,
		totalAmount = (mode == "numeric" and numVal) or nil,
		count = 1,
		area = area,
		fontFace = fontFace,
		fontSize = fontSize,
		outlineFlag = outlineFlag,
		fontAlpha = fontAlpha,
		anchorH = anchorH,
		dirMult = dirMult,
		duration = duration,
		color = color,
		meta = meta,
		lastUpdate = GetTime(),
		timer = C_Timer.NewTimer(window, function()
			FlushMergeByKey(key)
		end),
	}
	if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
end

-- Primary contract: engine calls this to request output.
function Display:Emit(areaName, text, color, meta)
    local tok = ZSBT.Addon and ZSBT.Addon.PerfBegin and ZSBT.Addon:PerfBegin("UI.DisplayEmit")
    if Addon and Addon.DebugPrint then
    end

    -- Global gating (Enable ZSBT + Combat Only Mode)
    -- Notifications (cooldowns, warnings, combat enter/leave) always display.
    local isNotification = meta and meta.kind == "notification"
    if not isNotification then
        if ZSBT.Core and ZSBT.Core.ShouldEmitNow and not ZSBT.Core:ShouldEmitNow() then
            if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
            return
        end
    else
        -- Notifications still respect master enable
        if ZSBT.Core and ZSBT.Core.IsMasterEnabled and not ZSBT.Core:IsMasterEnabled() then
            if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
            return
        end
    end

    -- Optional: disable the Notifications scroll area entirely.
    -- This is a hard suppress for any output routed to the Notifications area,
    -- including cooldown ready, buffs, triggers, combat enter/leave, etc.
    do
        local profile = ZSBT.db and ZSBT.db.profile
        local general = profile and profile.general
        if general and general.notificationsEnabled == false then
            if type(areaName) == "string" and areaName == "Notifications" then
                if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
                return
            end
        end
    end

    -- text may be a tainted secret value — do NOT compare it directly.
    -- Use type() checks instead of truthiness tests.
    if type(areaName) == "nil" or type(text) == "nil" then
		if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
        return
    end

	local dbg = (Addon and Addon.GetDebugLevel and Addon:GetDebugLevel("ui"))
		or (ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics and (ZSBT.db.profile.diagnostics.debugLevel or 0) or 0)
	local prof = ZSBT.db and ZSBT.db.profile
	local outHealArea = nil
	if prof and prof.outgoing and prof.outgoing.healing and type(prof.outgoing.healing.scrollArea) == "string" then
		outHealArea = prof.outgoing.healing.scrollArea
	end
	if dbg >= 3 and Addon and Addon.Dbg and meta and meta.kind == "heal" then
		local function safeDbg(v)
			if v == nil then return "nil" end
			if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
			if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
			return "<secret>"
		end
		Addon:Dbg("ui", 3, "EMIT", safeDbg(areaName), "kind=heal", "text=" .. safeDbg(text))
	elseif dbg >= 3 and Addon and Addon.Print and meta and meta.kind == "heal" then
		local function safeDbg(v)
			if v == nil then return "nil" end
			if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
			if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
			return "<secret>"
		end
		Addon:Print("|cFF00CC66[EMIT]|r " .. safeDbg(areaName) .. " kind=heal text=" .. safeDbg(text))
	elseif dbg >= 4 and type(areaName) == "string" then
		local isOutgoingArea = (areaName == "Outgoing") or (outHealArea and areaName == outHealArea)
		if isOutgoingArea and (not (ZSBT.IsSafeString and ZSBT.IsSafeString(text))) then
			local function safeDbg(v)
				if v == nil then return "nil" end
				if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
				if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
				return "<secret>"
			end
			if Addon and Addon.Dbg then
				Addon:Dbg("safety", 4, "EMIT_SECRET", safeDbg(areaName), "kind=" .. safeDbg(meta and meta.kind), "text=" .. safeDbg(text))
			elseif Addon and Addon.Print then
				Addon:Print("|cFF00CC66[EMIT_SECRET]|r " .. safeDbg(areaName)
					.. " kind=" .. safeDbg(meta and meta.kind)
					.. " text=" .. safeDbg(text))
			end
		elseif isOutgoingArea and ZSBT.IsSafeString and ZSBT.IsSafeString(text) then
			local function parseBigNumber(s)
				if type(s) ~= "string" then return nil end
				local token = s:match("([%d%.,]+%s*[KMBT])") or s:match("([%d%.,]+)")
				if not token then return nil end
				token = token:gsub("%s+", "")
				local suffix = token:match("[KMBT]$")
				local numPart = token:gsub("[KMBT]$", "")
				numPart = numPart:gsub(",", "")
				local base = tonumber(numPart)
				if type(base) ~= "number" then return nil end
				local mult = 1
				if suffix == "K" then mult = 1e3
				elseif suffix == "M" then mult = 1e6
				elseif suffix == "B" then mult = 1e9
				elseif suffix == "T" then mult = 1e12
				end
				return base * mult
			end
			local n = parseBigNumber(text)
			if type(n) == "number" and n >= 50000 then
				local function safeDbg(v)
					if v == nil then return "nil" end
					if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
					if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
					return "<secret>"
				end
				if Addon and Addon.Dbg then
					Addon:Dbg("ui", 4, "EMIT_BIG", safeDbg(areaName), "kind=" .. safeDbg(meta and meta.kind), "text=" .. safeDbg(text))
				elseif Addon and Addon.Print then
					Addon:Print("|cFF00CC66[EMIT_BIG]|r " .. safeDbg(areaName)
						.. " kind=" .. safeDbg(meta and meta.kind)
						.. " text=" .. safeDbg(text))
				end
			end
		end
		if ZSBT.IsSafeString and ZSBT.IsSafeString(text) then
			local function parseBigNumberAny(s)
				if type(s) ~= "string" then return nil end
				local token = s:match("([%d%.,]+%s*[KMBT])") or s:match("([%d%.,]+)")
				if not token then return nil end
				token = token:gsub("%s+", "")
				local suffix = token:match("[KMBT]$")
				local numPart = token:gsub("[KMBT]$", "")
				numPart = numPart:gsub(",", "")
				local base = tonumber(numPart)
				if type(base) ~= "number" then return nil end
				local mult = 1
				if suffix == "K" then mult = 1e3
				elseif suffix == "M" then mult = 1e6
				elseif suffix == "B" then mult = 1e9
				elseif suffix == "T" then mult = 1e12
				end
				return base * mult
			end
			local n2 = parseBigNumberAny(text)
			if type(n2) == "number" and n2 >= 1000000 then
				local function safeDbg(v)
					if v == nil then return "nil" end
					if ZSBT.IsSafeString and ZSBT.IsSafeString(v) then return v end
					if ZSBT.IsSafeNumber and ZSBT.IsSafeNumber(v) then return tostring(v) end
					return "<secret>"
				end
				if Addon and Addon.Dbg then
					Addon:Dbg("ui", 4, "EMIT_MILLION", safeDbg(areaName), "kind=" .. safeDbg(meta and meta.kind), "text=" .. safeDbg(text))
				elseif Addon and Addon.Print then
					Addon:Print("|cFF00CC66[EMIT_MILLION]|r " .. safeDbg(areaName)
						.. " kind=" .. safeDbg(meta and meta.kind)
						.. " text=" .. safeDbg(text))
				end
			end
		end
	end

    local profile = ZSBT.db and ZSBT.db.profile
    local area = profile and profile.scrollAreas and profile.scrollAreas[areaName] or nil
    if not area then
        -- Safe fallback: chat-only when a scroll area is missing.
        -- text may be tainted so we pass it directly to Print (which calls SetText).
        if Addon and Addon.Print then
            Addon:Print("Display fallback:", areaName or "?")
        end
        return
    end

    -- Require the test renderer (ScrollAreaFrames.lua)
    if type(ZSBT.FireTestText) ~= "function" then
        if Addon and Addon.Print then
            Addon:Print("Display: no FireTestText renderer")
        end
        return
    end

    local fontFace, fontSize, outlineFlag, fontAlpha = ResolveFontForArea(areaName)
    -- Per-trigger font overrides (Triggers.lua passes these via meta)
    if meta and meta.kind == "notification" and meta.trigger == true and meta.triggerFontOverride == true then
        local LSM = LibStub("LibSharedMedia-3.0", true)
        local faceKey = meta.triggerFontFace
        if LSM and type(faceKey) == "string" and faceKey ~= "" then
            local fetched = LSM:Fetch("font", faceKey)
            if fetched then fontFace = fetched end
        end
        local outlineKey = meta.triggerFontOutline
        if type(outlineKey) == "string" and outlineKey ~= "" and ZSBT.OUTLINE_STYLES and ZSBT.OUTLINE_STYLES[outlineKey] ~= nil then
            outlineFlag = ZSBT.OUTLINE_STYLES[outlineKey]
        end
        local sz = tonumber(meta.triggerFontSize)
        local sc = tonumber(meta.triggerFontScale)
        if type(sz) == "number" and sz > 0 then
            fontSize = sz
        elseif type(sc) == "number" and sc > 0 then
            fontSize = math.max(1, math.floor((tonumber(fontSize) or 18) * sc + 0.5))
        end
    end
    if meta and meta.spellFontOverride == true then
        local LSM = LibStub("LibSharedMedia-3.0", true)
        local faceKey = meta.spellFontFace
        if LSM and type(faceKey) == "string" and faceKey ~= "" then
            local fetched = LSM:Fetch("font", faceKey)
            if fetched then fontFace = fetched end
        end
        local outlineKey = meta.spellFontOutline
        if type(outlineKey) == "string" and outlineKey ~= "" and ZSBT.OUTLINE_STYLES and ZSBT.OUTLINE_STYLES[outlineKey] ~= nil then
            outlineFlag = ZSBT.OUTLINE_STYLES[outlineKey]
        end
        local sz = tonumber(meta.spellFontSize)
        local sc = tonumber(meta.spellFontScale)
        if type(sz) == "number" and sz > 0 then
            fontSize = sz
        elseif type(sc) == "number" and sc > 0 then
            fontSize = math.max(1, math.floor((tonumber(fontSize) or 18) * sc + 0.5))
        end
    end
    local anchorH = (area.alignment == "Left" and "LEFT") or (area.alignment == "Right" and "RIGHT") or "CENTER"
    local dirMult = (area.direction == "Down") and -1 or 1
    local speed = tonumber(area.animSpeed) or 1.0
    if speed <= 0 then speed = 1.0 end
    -- Base duration varies by animation style
    local animKey = area.animation or "Straight"
    local baseDuration = 2.5  -- default for straight scroll
    if animKey == "Static" or animKey == "static" then
        baseDuration = 4.0
    elseif animKey == "Pow" or animKey == "pow" then
        baseDuration = 2.0
    elseif animKey:find("Parabola") or animKey:find("parabola") then
        baseDuration = 3.5
    elseif animKey:find("Fireworks") or animKey:find("fireworks") then
        baseDuration = 3.0
    elseif animKey:find("Waterfall") or animKey:find("waterfall") then
        baseDuration = 3.5
    end
    local duration = baseDuration * (2.0 / (1.0 + speed))

	-- Sticky crit support (set by emitters like Outgoing_Probe)
	if meta and meta.isCrit and meta.stickyCrit and meta.stickyDurationMult then
		local mult = tonumber(meta.stickyDurationMult) or 1
		if mult > 1 then
			duration = duration * mult
		end
	end

    -- Resolve crit font if this is a crit event
    local isCrit = meta and meta.isCrit
    if isCrit then
        local critFace, critSize, critOutline, critScale, critMode = ResolveCritFont(meta)
        if not meta then meta = {} end
		if meta.critFace == nil then meta.critFace = critFace end
		if meta.critSize == nil then meta.critSize = critSize end
		if meta.critOutline == nil then meta.critOutline = critOutline end
		if meta.critScale == nil then meta.critScale = critScale end
		if meta.critAnim == nil then meta.critAnim = critMode end
    end

    TryMerge(areaName, text, area, fontFace, fontSize, outlineFlag, fontAlpha,
        anchorH, dirMult, duration, color, meta)
	if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
end

-- Backward-compat contract
if ZSBT.DisplayText == nil then
    function ZSBT.DisplayText(areaName, text, color, meta)
        return Display:Emit(areaName, text, color, meta)
    end
end
