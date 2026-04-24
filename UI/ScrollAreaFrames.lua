------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - Scroll Area Visualization
-- Feature A: Unlock/Lock mode - draggable colored frames showing area
--            positions and sizes on screen.
-- Feature B: Test animation - fires dummy text into a scroll area.
------------------------------------------------------------------------

local ADDON_NAME, ZSBT = ...
local Addon = ZSBT.Addon

------------------------------------------------------------------------
-- Hidden recycling frame for orphaned UI objects.
-- WoW 12.0 can block rendering of frames with nil parents; reparenting
-- to a hidden frame is the safe disposal pattern.
------------------------------------------------------------------------
local recyclingBin = CreateFrame("Frame", "ZSBT_RecyclingBin", UIParent)
recyclingBin:Hide()
recyclingBin:SetAllPoints(UIParent)
recyclingBin:SetAlpha(0)

------------------------------------------------------------------------
-- Object Pools — reuse FontStrings and Frames to prevent memory leaks.
-- Without pooling, every combat text creates 1-2 FontStrings + 1 Frame
-- that accumulate forever (thousands per hour in AoE combat).
------------------------------------------------------------------------
local fontStringPool = {}  -- available FontStrings ready for reuse
local iconFSPool = {}      -- available icon FontStrings ready for reuse
local animFramePool = {}   -- available animation driver Frames ready for reuse

-- Forward declarations (AnimEngine is defined before the pool helpers below).
local RecycleFontString
local RecycleIconFS
local RecycleAnimFrame

------------------------------------------------------------------------
-- Central Animation Engine (MSBT-style)
-- Single OnUpdate, per-scroll-area active event lists, and spawn-time
-- re-timing to prevent overlap.
------------------------------------------------------------------------

ZSBT.AnimEngine = ZSBT.AnimEngine or {}
local AnimEngine = ZSBT.AnimEngine

AnimEngine._enabled = AnimEngine._enabled or true
AnimEngine._frame = AnimEngine._frame or CreateFrame("Frame")
AnimEngine._areas = AnimEngine._areas or {} -- [areaKey] = { events = {}, staticLanes = {} }

local MSBT_MOVEMENT_SPEED = (3 / 260)
local MSBT_MIN_VERTICAL_SPACING = 8
local MSBT_DEFAULT_FADE_PERCENT = 0.8
local MSBT_ANIMATION_DELAY = 0.015

local MSBT_POW_FADE_IN_TIME = 0.17
local MSBT_POW_DISPLAY_TIME = 1.5
local MSBT_POW_FADE_OUT_TIME = 0.5
local MSBT_POW_TEXT_DELTA = 0.7
local MSBT_JIGGLE_DELAY_TIME = 0.05

local MSBT_POW_TEXT_DELTA_STICKY = 0.95
local MSBT_JIGGLE_DELAY_TIME_STICKY = 0.035
local MSBT_JIGGLE_RANGE_STICKY = 2

local function AE_Now()
	return (GetTime and GetTime()) or 0
end

local function AE_InitWaterfallSpacing(newDisplayEvent, activeDisplayEvents, direction)
	-- Time-domain spacing like MSBT Straight/Parabola, but using Waterfall's scrollTime.
	-- This keeps waterfall variants unique (wave math stays in update), while preventing spawn-edge overlap.
	local scrollTime = newDisplayEvent.scrollTime
	local scrollHeight = newDisplayEvent.scrollHeight
	if not (scrollTime and scrollTime > 0 and scrollHeight and scrollHeight > 0) then
		return
	end
	local perPixelTime = scrollTime / scrollHeight
	local numActive = #activeDisplayEvents
	if numActive == 0 then
		return
	end
	if direction == "Down" then
		local current = newDisplayEvent
		for x = numActive, 1, -1 do
			local prev = activeDisplayEvents[x]
			local topTimeCurrent = current.elapsedTime + (current.fontSize + MSBT_MIN_VERTICAL_SPACING) * perPixelTime
			if prev.elapsedTime < topTimeCurrent then
				prev.elapsedTime = topTimeCurrent
			else
				break
			end
			current = prev
		end
	else
		local current = newDisplayEvent
		for x = numActive, 1, -1 do
			local prev = activeDisplayEvents[x]
			local topTimePrev = prev.elapsedTime + (prev.fontSize + MSBT_MIN_VERTICAL_SPACING) * perPixelTime
			if topTimePrev < current.elapsedTime then
				prev.elapsedTime = current.elapsedTime + (prev.fontSize + MSBT_MIN_VERTICAL_SPACING) * perPixelTime
			else
				break
			end
			current = prev
		end
	end
end

local function AE_GetAreaState(areaKey)
	local st = AnimEngine._areas[areaKey]
	if not st then
		st = { events = {}, staticLanes = {} }
		AnimEngine._areas[areaKey] = st
	end
	if not st.events then st.events = {} end
	if not st.staticLanes then st.staticLanes = {} end
	return st
end

local function AE_IsVerticalScrollStyle(styleId)
	return styleId == "Straight" or styleId == "Parabola" or styleId == "Waterfall"
end

local function AE_SecondsPerPixel(ev)
	local h = math.max(1, ev.areaH or 1)
	local d = math.max(0.05, ev.duration or 0.05)
	return d / h
end

local function AE_MinSeparationSeconds(ev)
	-- Approximate MSBT: (fontSize + MIN_VERTICAL_SPACING) worth of travel time.
	-- We don't have MSBT's MOVEMENT_SPEED, so we use duration/height.
	local fontSize = ev.effectiveFontSize or ev.fontSize or 18
	local spacing = 2
	local secondsPerPixel = AE_SecondsPerPixel(ev)
	return (fontSize + spacing) * secondsPerPixel
end

local function AE_MinSeparationSecondsBetween(newEv, oldEv)
	-- Use new event's movement rate to convert pixels->seconds, and ensure
	-- enough pixels to clear either line's height.
	local newFont = newEv.effectiveFontSize or newEv.fontSize or 18
	local oldFont = (oldEv and (oldEv.effectiveFontSize or oldEv.fontSize)) or newFont
	local spacingPx = math.max(newFont, oldFont) + 2
	return spacingPx * AE_SecondsPerPixel(newEv)
end

local function AE_ResolveStyleId(ev)
	-- Sticky crits always use Pow by default.
	if ev.meta and (ev.meta.stickyCrit == true or ev.meta.sticky == true) then return "Pow" end
	if ev.usePow then return "Pow" end
	local style = ev.animStyle or "Straight"
	style = tostring(style)
	style = style:gsub("^%s+", ""):gsub("%s+$", "")
	if style:lower():find("fireworks", 1, true) then return "Fireworks" end
	if style:lower():find("waterfall", 1, true) then return "Waterfall" end
	if style:lower() == "static" then return "Static" end
	if style:lower():find("parabola", 1, true) then return "Parabola" end
	return "Straight"
end

local function AE_MSBT_AnchorPoint(ev)
	local v = (ev.dirMult and ev.dirMult < 0) and "TOP" or "BOTTOM"
	if ev.anchorH == "LEFT" then
		return v .. "LEFT"
	elseif ev.anchorH == "RIGHT" then
		return v .. "RIGHT"
	end
	return v
end

local function AE_MSBT_ScrollUp(displayEvent, animationProgress)
	displayEvent.positionY = displayEvent.scrollHeight * animationProgress
end

local function AE_MSBT_ScrollDown(displayEvent, animationProgress)
	displayEvent.positionY = displayEvent.scrollHeight - displayEvent.scrollHeight * animationProgress
end

local function AE_MSBT_ScrollLeftParabolaUp(displayEvent, animationProgress)
	AE_MSBT_ScrollUp(displayEvent, animationProgress)
	local y = displayEvent.positionY - displayEvent.midPoint
	displayEvent.positionX = (y * y) / displayEvent.fourA
end

local function AE_MSBT_ScrollLeftParabolaDown(displayEvent, animationProgress)
	AE_MSBT_ScrollDown(displayEvent, animationProgress)
	local y = displayEvent.positionY - displayEvent.midPoint
	displayEvent.positionX = (y * y) / displayEvent.fourA
end

local function AE_MSBT_ScrollRightParabolaUp(displayEvent, animationProgress)
	AE_MSBT_ScrollUp(displayEvent, animationProgress)
	local y = displayEvent.positionY - displayEvent.midPoint
	displayEvent.positionX = displayEvent.scrollWidth - ((y * y) / displayEvent.fourA)
end

local function AE_MSBT_ScrollRightParabolaDown(displayEvent, animationProgress)
	AE_MSBT_ScrollDown(displayEvent, animationProgress)
	local y = displayEvent.positionY - displayEvent.midPoint
	displayEvent.positionX = displayEvent.scrollWidth - ((y * y) / displayEvent.fourA)
end

local function AE_MSBT_InitStraight(newDisplayEvent, activeDisplayEvents, direction)
	newDisplayEvent.scrollTime = newDisplayEvent.scrollHeight * MSBT_MOVEMENT_SPEED

	local anchorPoint = newDisplayEvent.anchorPoint
	if anchorPoint == "BOTTOMLEFT" then
		newDisplayEvent.positionX = 0
	elseif anchorPoint == "BOTTOM" then
		newDisplayEvent.positionX = newDisplayEvent.scrollWidth / 2
	elseif anchorPoint == "BOTTOMRIGHT" then
		newDisplayEvent.positionX = newDisplayEvent.scrollWidth
	end

	local numActiveAnimations = #activeDisplayEvents
	if direction == "Down" then
		newDisplayEvent.animationHandler = AE_MSBT_ScrollDown
		if numActiveAnimations == 0 then return end

		local perPixelTime = MSBT_MOVEMENT_SPEED / newDisplayEvent.animationSpeed
		local currentDisplayEvent = newDisplayEvent
		local prevDisplayEvent, topTimeCurrent
		for x = numActiveAnimations, 1, -1 do
			prevDisplayEvent = activeDisplayEvents[x]
			topTimeCurrent = currentDisplayEvent.elapsedTime + (currentDisplayEvent.fontSize + MSBT_MIN_VERTICAL_SPACING) * perPixelTime
			if prevDisplayEvent.elapsedTime < topTimeCurrent then
				prevDisplayEvent.elapsedTime = topTimeCurrent
			else
				break
			end
			currentDisplayEvent = prevDisplayEvent
		end
	else
		newDisplayEvent.animationHandler = AE_MSBT_ScrollUp
		if numActiveAnimations == 0 then return end

		local perPixelTime = MSBT_MOVEMENT_SPEED / newDisplayEvent.animationSpeed
		local currentDisplayEvent = newDisplayEvent
		local prevDisplayEvent, topTimePrev
		for x = numActiveAnimations, 1, -1 do
			prevDisplayEvent = activeDisplayEvents[x]
			topTimePrev = prevDisplayEvent.elapsedTime - (prevDisplayEvent.fontSize + MSBT_MIN_VERTICAL_SPACING) * perPixelTime
			if topTimePrev < currentDisplayEvent.elapsedTime then
				prevDisplayEvent.elapsedTime = currentDisplayEvent.elapsedTime + (prevDisplayEvent.fontSize + MSBT_MIN_VERTICAL_SPACING) * perPixelTime
			else
				return
			end
			currentDisplayEvent = prevDisplayEvent
		end
	end
end

local function AE_MSBT_AnimatePowJiggle(displayEvent, animationProgress)
	local fadeInPercent = MSBT_POW_FADE_IN_TIME / displayEvent.scrollTime
	if animationProgress <= fadeInPercent then
		local isSticky = (displayEvent.meta and (displayEvent.meta.stickyCrit == true or displayEvent.meta.sticky == true))
		local d = isSticky and MSBT_POW_TEXT_DELTA_STICKY or MSBT_POW_TEXT_DELTA
		local t = (fadeInPercent > 0) and (animationProgress / fadeInPercent) or 1
		local k = 1 - t
		local slam = isSticky and 1.35 or 1.0
		displayEvent.fontString:SetTextHeight(displayEvent.fontSize * (1 + ((k * k) * d * slam)))
		return
	end

	if animationProgress <= (displayEvent.fadePercent or MSBT_DEFAULT_FADE_PERCENT) then
		local elapsedTime = displayEvent.elapsedTime or 0
		local last = displayEvent.timeLastJiggled or 0
		local delay = (displayEvent.meta and (displayEvent.meta.stickyCrit == true or displayEvent.meta.sticky == true)) and MSBT_JIGGLE_DELAY_TIME_STICKY or MSBT_JIGGLE_DELAY_TIME
		local range = (displayEvent.meta and (displayEvent.meta.stickyCrit == true or displayEvent.meta.sticky == true)) and MSBT_JIGGLE_RANGE_STICKY or 1
		if (elapsedTime - last) > delay then
			displayEvent.positionX = (displayEvent.originalPositionX or 0) + math.random(-range, range)
			displayEvent.positionY = (displayEvent.originalPositionY or 0) + math.random(-range, range)
			displayEvent.timeLastJiggled = elapsedTime
		end

		if not displayEvent._powFontRestored then
			local fontPath, _, fontOutline = displayEvent.fontString:GetFont()
			displayEvent.fontString:SetFont(fontPath, displayEvent.fontSize, fontOutline)
			displayEvent._powFontRestored = true
		end
	end
end

local function AE_MSBT_InitParabola(newDisplayEvent, activeDisplayEvents, direction, behavior)
	AE_MSBT_InitStraight(newDisplayEvent, activeDisplayEvents, direction)
	if direction == "Down" then
		newDisplayEvent.animationHandler = (behavior == "CurvedRight") and AE_MSBT_ScrollRightParabolaDown or AE_MSBT_ScrollLeftParabolaDown
	else
		newDisplayEvent.animationHandler = (behavior == "CurvedRight") and AE_MSBT_ScrollRightParabolaUp or AE_MSBT_ScrollLeftParabolaUp
	end
	local midPoint = newDisplayEvent.scrollHeight / 2
	newDisplayEvent.midPoint = midPoint
	newDisplayEvent.fourA = (midPoint * midPoint) / newDisplayEvent.scrollWidth
end

local function AE_MSBT_AnimatePowNormal(displayEvent, animationProgress)
	local fadeInPercent = MSBT_POW_FADE_IN_TIME / displayEvent.scrollTime
	if animationProgress <= fadeInPercent then
		local isSticky = (displayEvent.meta and (displayEvent.meta.stickyCrit == true or displayEvent.meta.sticky == true))
		local d = isSticky and MSBT_POW_TEXT_DELTA_STICKY or MSBT_POW_TEXT_DELTA
		local t = (fadeInPercent > 0) and (animationProgress / fadeInPercent) or 1
		local k = 1 - t
		local slam = isSticky and 1.35 or 1.0
		displayEvent.fontString:SetTextHeight(displayEvent.fontSize * (1 + ((k * k) * d * slam)))
	else
		if not displayEvent._powFontRestored then
			local fontPath, _, fontOutline = displayEvent.fontString:GetFont()
			displayEvent.fontString:SetFont(fontPath, displayEvent.fontSize, fontOutline)
			displayEvent._powFontRestored = true
		end
	end
end

local function AE_MSBT_InitPow(newDisplayEvent, activeDisplayEvents, direction)
	local animationSpeed = newDisplayEvent.animationSpeed
	local scrollTime = MSBT_POW_FADE_IN_TIME + (MSBT_POW_DISPLAY_TIME / animationSpeed) + MSBT_POW_FADE_OUT_TIME
	newDisplayEvent.scrollTime = scrollTime * animationSpeed
	newDisplayEvent.fadePercent = (MSBT_POW_FADE_IN_TIME + (MSBT_POW_DISPLAY_TIME / animationSpeed)) / scrollTime
	local wantJiggle = (newDisplayEvent.meta
		and (newDisplayEvent.meta.stickyCrit == true or newDisplayEvent.meta.sticky == true)
		and newDisplayEvent.meta.stickyJiggle ~= false)
	newDisplayEvent.animationHandler = wantJiggle and AE_MSBT_AnimatePowJiggle or AE_MSBT_AnimatePowNormal

	local anchorPoint = newDisplayEvent.anchorPoint
	if anchorPoint == "BOTTOMLEFT" then
		newDisplayEvent.positionX = 0
	elseif anchorPoint == "BOTTOM" then
		newDisplayEvent.positionX = newDisplayEvent.scrollWidth / 2
	elseif anchorPoint == "BOTTOMRIGHT" then
		newDisplayEvent.positionX = newDisplayEvent.scrollWidth
	end
	newDisplayEvent.positionY = newDisplayEvent.scrollHeight / 2

	-- Randomized seed inside the area to reduce overlap (requested behavior).
	-- Keep the range conservative so it still "feels" like MSBT Pow.
	local rx = (math.random() * 2.0 - 1.0) * (newDisplayEvent.scrollWidth * 0.25)
	local ry = (math.random() * 2.0 - 1.0) * (newDisplayEvent.scrollHeight * 0.20)
	newDisplayEvent.positionX = newDisplayEvent.positionX + rx
	newDisplayEvent.positionY = newDisplayEvent.positionY + ry

	newDisplayEvent.originalPositionX = newDisplayEvent.positionX
	newDisplayEvent.originalPositionY = newDisplayEvent.positionY
	newDisplayEvent.timeLastJiggled = 0

	local numActiveAnimations = #activeDisplayEvents
	if (numActiveAnimations == 0) then return end

	-- MSBT anti-overlap: re-stack existing Pow events vertically around a middle reference.
	if direction == "Down" then
		local middleSticky = math.floor((numActiveAnimations + 2) / 2)
		activeDisplayEvents[middleSticky].originalPositionY = newDisplayEvent.scrollHeight / 2
		activeDisplayEvents[middleSticky].positionY = activeDisplayEvents[middleSticky].originalPositionY
		for x = middleSticky - 1, 1, -1 do
			activeDisplayEvents[x].originalPositionY = activeDisplayEvents[x + 1].originalPositionY - activeDisplayEvents[x].fontSize - MSBT_MIN_VERTICAL_SPACING
			activeDisplayEvents[x].positionY = activeDisplayEvents[x].originalPositionY
		end
		for x = middleSticky + 1, numActiveAnimations do
			activeDisplayEvents[x].originalPositionY = activeDisplayEvents[x - 1].originalPositionY + activeDisplayEvents[x - 1].fontSize + MSBT_MIN_VERTICAL_SPACING
			activeDisplayEvents[x].positionY = activeDisplayEvents[x].originalPositionY
		end
		newDisplayEvent.originalPositionY = activeDisplayEvents[numActiveAnimations].originalPositionY + activeDisplayEvents[numActiveAnimations].fontSize + MSBT_MIN_VERTICAL_SPACING
		newDisplayEvent.positionY = newDisplayEvent.originalPositionY
	else
		local middleSticky = math.ceil(numActiveAnimations / 2)
		activeDisplayEvents[middleSticky].originalPositionY = newDisplayEvent.scrollHeight / 2
		activeDisplayEvents[middleSticky].positionY = activeDisplayEvents[middleSticky].originalPositionY
		for x = middleSticky - 1, 1, -1 do
			activeDisplayEvents[x].originalPositionY = activeDisplayEvents[x + 1].originalPositionY + activeDisplayEvents[x + 1].fontSize + MSBT_MIN_VERTICAL_SPACING
			activeDisplayEvents[x].positionY = activeDisplayEvents[x].originalPositionY
		end
		for x = middleSticky + 1, numActiveAnimations do
			activeDisplayEvents[x].originalPositionY = activeDisplayEvents[x - 1].originalPositionY - activeDisplayEvents[x].fontSize - MSBT_MIN_VERTICAL_SPACING
			activeDisplayEvents[x].positionY = activeDisplayEvents[x].originalPositionY
		end
		newDisplayEvent.originalPositionY = activeDisplayEvents[numActiveAnimations].originalPositionY - activeDisplayEvents[numActiveAnimations].fontSize - MSBT_MIN_VERTICAL_SPACING
		newDisplayEvent.positionY = newDisplayEvent.originalPositionY
	end
end

local function AE_ComputeAnchorPoint(anchorH, dirMult, forceLeft)
	local v = (dirMult > 0) and "BOTTOM" or "TOP"
	if forceLeft then
		return v .. "LEFT"
	end
	if anchorH == "LEFT" then
		return v .. "LEFT"
	elseif anchorH == "RIGHT" then
		return v .. "RIGHT"
	end
	return v
end

local function AE_RecycleEvent(ev)
	if not ev then return end
	RecycleFontString(ev.fs)
	RecycleIconFS(ev.iconFS)
	if ev.iconTex then
		ev.iconTex:Hide()
		ev.iconTex:SetParent(recyclingBin)
	end
end

local function AE_UpdateEvent(ev, dt)
	if not ev then return true end
	local tNow = AE_Now()
	if ev.startAt and tNow < ev.startAt then
		-- MSBT-like behavior: queued events should not be visible until they start.
		-- Without this, repeated tests create a cluttered pile at the spawn anchor.
		if ev.fs then ev.fs:SetAlpha(0) end
		if ev.iconFS then ev.iconFS:SetAlpha(0) end
		if ev.iconTex then ev.iconTex:SetAlpha(0) end
		return false
	end

	-- MSBT throttles updates to ~66Hz using ANIMATION_DELAY.
	ev.timeSinceLastUpdate = (ev.timeSinceLastUpdate or 0) + dt
	if ev.timeSinceLastUpdate < MSBT_ANIMATION_DELAY then
		return false
	end
	local step = ev.timeSinceLastUpdate
	ev.timeSinceLastUpdate = 0

	if ev.elapsedTime ~= nil then
		ev.elapsedTime = ev.elapsedTime + step
	else
		ev.elapsed = (ev.elapsed or 0) + step
	end

	local progress
	if ev.scrollTime and ev.scrollTime > 0 and ev.elapsedTime ~= nil then
		progress = ev.elapsedTime / ev.scrollTime
	elseif ev.duration and ev.duration > 0 then
		progress = (ev.elapsed or 0) / ev.duration
	else
		progress = 1
	end
	if progress >= 1.0 then
		return true
	end

	local xOff2, yOff2 = 0, 0
	local alpha = ev.fontAlpha or 1.0
	local styleId = ev.styleId
	local laneOff = ev.slotOffset or 0
	local function AnchorOriginX()
		local ap = ev.anchorPoint
		if ap == "BOTTOM" or ap == "TOP" then
			return (ev.scrollWidth or ev.areaW or 0) / 2
		elseif ap == "BOTTOMRIGHT" or ap == "TOPRIGHT" then
			return (ev.scrollWidth or ev.areaW or 0)
		end
		return 0
	end

	if styleId == "Pow" then
		-- MSBT Pow: uses SetTextHeight during fade-in and restores font once.
		if ev.animationHandler then
			ev.animationHandler(ev, progress)
		end
		xOff2 = (ev.positionX or 0) - AnchorOriginX()
		yOff2 = ev.positionY or 0
		local maxX = ev.scrollWidth or ev.areaW or 0
		local maxY = ev.scrollHeight or ev.areaH or 0
		if type(xOff2) == "number" then
			if xOff2 > maxX then xOff2 = maxX elseif xOff2 < -maxX then xOff2 = -maxX end
		end
		if type(yOff2) == "number" then
			local ap = ev.anchorPoint
			if type(ap) == "string" and ap:sub(1, 3) == "TOP" then
				if yOff2 > 0 then yOff2 = 0 end
				if yOff2 < -maxY then yOff2 = -maxY end
			else
				if yOff2 < 0 then yOff2 = 0 end
				if yOff2 > maxY then yOff2 = maxY end
			end
		end
		local fadePercent = ev.fadePercent or MSBT_DEFAULT_FADE_PERCENT
		if progress >= fadePercent then
			ev.alpha = (1 - progress) / (1 - fadePercent)
		else
			ev.alpha = 1
		end
		ev.fs:SetAlpha(math.max(0, (ev.masterAlpha or (ev.fontAlpha or 1)) * (ev.alpha or 1)))

	elseif styleId == "Static" then
		-- MSBT-like static: no movement, late fade only. Placement happens via lane.
		xOff2, yOff2 = 0, 0
		local fadeStart = 0.80
		if progress >= fadeStart then
			alpha = alpha * (1.0 - ((progress - fadeStart) / (1.0 - fadeStart)))
		end
		ev.fs:SetAlpha(math.max(0, alpha))

	elseif styleId == "Parabola" then
		-- MSBT exact parabola uses animationHandler set during init.
		if ev.animationHandler then
			ev.animationHandler(ev, progress)
			xOff2 = (ev.positionX or 0) - AnchorOriginX()
			yOff2 = ev.positionY or 0
		end
		local fadeInTime = 0.80
		local fadeInPercent = 0
		if ev.scrollTime and ev.scrollTime > 0 and fadeInTime > 0 then
			fadeInPercent = fadeInTime / ev.scrollTime
			if fadeInPercent > 0.90 then fadeInPercent = 0.90 end
		end
		local fadePercent = ev.fadePercent or MSBT_DEFAULT_FADE_PERCENT
		if fadeInPercent > 0 and progress <= fadeInPercent then
			ev.alpha = progress / fadeInPercent
		elseif progress >= fadePercent then
			ev.alpha = (1 - progress) / (1 - fadePercent)
		else
			ev.alpha = 1
		end
		ev.fs:SetAlpha(math.max(0, (ev.fontAlpha or 1) * (ev.alpha or 1)))

	elseif styleId == "Fireworks" then
		-- Fireworks (2B): keep the burst feel, but avoid identical spawn points.
		local t = progress
		local v = ev.fwSpeed or 1.0
		local g = 1.25
		local travel = t * v
		local gravity = (t * t) * g
		local axis = travel - (0.55 * gravity)
		local side = math.sin(ev.fwTheta or 0) * travel
		local perp = (travel * 0.90) * (ev.fwPerp or 0)

		local origin = ev.fwOrigin or "Bottom"
		local baseX = ev.fwBaseX or 0
		local baseY = ev.fwBaseY or 0
		if origin == "Bottom" then
			yOff2 = (ev.areaH * 0.80) * axis
			xOff2 = baseX + (ev.areaW * 0.55) * side
			xOff2 = xOff2 + (ev.areaW * 0.14) * perp
			yOff2 = yOff2 + baseY
		elseif origin == "Top" then
			yOff2 = -(ev.areaH * 0.80) * axis
			xOff2 = baseX + (ev.areaW * 0.55) * side
			xOff2 = xOff2 + (ev.areaW * 0.14) * perp
			yOff2 = yOff2 + baseY
		elseif origin == "Left" then
			xOff2 = (ev.areaW * 0.80) * axis
			yOff2 = baseY + (ev.areaH * 0.45) * side
			yOff2 = yOff2 + (ev.areaH * 0.14) * perp
			xOff2 = xOff2 + baseX
		elseif origin == "Right" then
			xOff2 = -(ev.areaW * 0.80) * axis
			yOff2 = baseY + (ev.areaH * 0.45) * side
			yOff2 = yOff2 + (ev.areaH * 0.14) * perp
			xOff2 = xOff2 + baseX
		end

		local margin = math.max(6, math.floor((ev.fontSize or 18) * 0.6))
		local maxX = (ev.areaW / 2) - margin
		local maxY = (ev.areaH / 2) - margin
		if xOff2 > maxX then xOff2 = maxX elseif xOff2 < -maxX then xOff2 = -maxX end
		if yOff2 > maxY then yOff2 = maxY elseif yOff2 < -maxY then yOff2 = -maxY end
		if progress < 0.08 then
			alpha = alpha * (progress / 0.08)
		elseif progress > 0.20 then
			alpha = alpha * (1.0 - ((progress - 0.20) / 0.80))
		end
		ev.fs:SetAlpha(math.max(0, alpha))

	elseif styleId == "Waterfall" then
		local eased = progress * (2.0 - progress)
		yOff2 = (ev.areaH * 0.95) * eased * ev.dirMult

		local amp = ev.areaW * 0.06
		local w1 = 2.8
		local w2 = 6.5
		local turb = 0
		local style = ev.waterfallStyle or "Smooth"
		if style == "Wavy" then
			amp = ev.areaW * 0.10
			w1 = 2.0
			w2 = 4.0
		elseif style == "Ripple" then
			amp = ev.areaW * 0.085
			w1 = 2.4
			w2 = 9.0
		elseif style == "Turbulent" then
			amp = ev.areaW * 0.095
			w1 = 3.8
			w2 = 11.5
			turb = ev.areaW * 0.025
		end

		local tWave = (ev.elapsedTime ~= nil) and ev.elapsedTime or (ev.elapsed or 0)
		local wave1 = math.sin((tWave * w1) + (ev.wfPhase1 or 0))
		local wave2 = math.sin((tWave * w2) + (ev.wfPhase2 or 0))
		xOff2 = (wave1 * amp) + (wave2 * (amp * 0.35))
		if turb > 0 then
			xOff2 = xOff2 + (math.sin((tWave * 15.0) + ((ev.wfNoise or 0) * 10.0)) * turb)
		end

		if progress > 0.30 then
			alpha = alpha * (1.0 - ((progress - 0.30) / 0.70))
		end
		ev.fs:SetAlpha(math.max(0, alpha))

	else
		-- Straight (MSBT exact)
		if ev.animationHandler then
			ev.animationHandler(ev, progress)
			xOff2 = (ev.positionX or 0) - AnchorOriginX()
			yOff2 = ev.positionY or 0
		end
		local fadePercent = ev.fadePercent or MSBT_DEFAULT_FADE_PERCENT
		if progress >= fadePercent then
			ev.alpha = (1 - progress) / (1 - fadePercent)
		else
			ev.alpha = 1
		end
		ev.fs:SetAlpha(math.max(0, (ev.fontAlpha or 1) * (ev.alpha or 1)))
	end

	-- Placement (match existing semantics)
	-- MSBT does not ClearAllPoints each tick; doing so can cause flicker.
	if styleId ~= "Straight" and styleId ~= "Parabola" and styleId ~= "Pow" then
		ev.fs:ClearAllPoints()
	end
	local point = ev.anchorPoint or ev.startPoint
	if styleId == "Static" and ev.staticPoint and ev.staticSlotY ~= nil then
		ev.fs:SetPoint(ev.staticPoint, ev.parent, ev.staticPoint, 0, ev.staticSlotY)
	elseif styleId == "Pow" then
		-- MSBT Pow uses the scroll area's anchorPoint.
		ev.fs:SetPoint(point, ev.parent, point, xOff2, yOff2)
	else
		local yPlaced = laneOff + yOff2
		-- When anchored to TOP* for Down scrolling, positive y offsets move ABOVE the frame.
		-- Convert MSBT-style [0..scrollHeight] offsets into downward-negative offsets.
		if type(point) == "string" and point:sub(1, 3) == "TOP" then
			local sh = ev.scrollHeight or ev.areaH or 0
			yPlaced = laneOff - (sh - (yOff2 or 0))
		end
		ev.fs:SetPoint(point, ev.parent, point, xOff2, yPlaced)
	end

	-- Edge fade (keep your existing edge behavior)
	-- MSBT Straight/Parabola doesn't apply extra post-fade; it can cause visible jitter.
	if styleId ~= "Straight" and styleId ~= "Parabola" and styleId ~= "Pow" then
		local currentAlpha = ev.fs:GetAlpha()
		local absY = math.abs(laneOff + yOff2)
		local fadeStart = ev.areaH * 0.75
		local fadeEnd = ev.areaH * 1.2
		if absY > fadeStart then
			local edgeFade = 1.0 - math.min(1.0, (absY - fadeStart) / (fadeEnd - fadeStart))
			currentAlpha = currentAlpha * edgeFade
			ev.fs:SetAlpha(math.max(0, currentAlpha))
		end
	end

	if ev.iconFS then
		ev.iconFS:ClearAllPoints()
		ev.iconFS:SetPoint("RIGHT", ev.fs, "LEFT", -2, 0)
		ev.iconFS:SetAlpha(ev.fs:GetAlpha())
	end
	if ev.iconTex then
		ev.iconTex:ClearAllPoints()
		ev.iconTex:SetPoint("RIGHT", ev.fs, "LEFT", -2, 0)
		ev.iconTex:SetAlpha(ev.fs:GetAlpha())
	end

	return false
end

function AnimEngine:Enqueue(areaKey, ev)
	if not self._enabled then
		-- Fall back to old behavior if disabled.
		return false
	end

	ev.styleId = AE_ResolveStyleId(ev)
	ev.elapsed = 0
	ev.timeSinceLastUpdate = 0
	ev.startAt = AE_Now()

	local st = AE_GetAreaState(areaKey)
	local events = st.events

	-- MSBT-exact initialization for Straight/Parabola.
	if ev.styleId == "Straight" or ev.styleId == "Parabola" then
		ev.startAt = nil
		ev.elapsedTime = 0
		ev.scrollHeight = ev.areaH
		ev.scrollWidth = ev.areaW
		ev.anchorPoint = AE_MSBT_AnchorPoint(ev)
		ev.animationSpeed = (type(ev.animationSpeed) == "number" and ev.animationSpeed > 0) and ev.animationSpeed or 1
		ev.masterAlpha = ev.fontAlpha or 1
		ev.fadePercent = MSBT_DEFAULT_FADE_PERCENT
		ev.alpha = 1
		ev.fontSize = ev.effectiveFontSize or ev.fontSize or 18
		-- Keep the baseline inside the area so large/crit text doesn't spawn above the frame.
		ev.scrollHeight = math.max(1, (ev.areaH or 1) - (ev.fontSize or 18))
		ev.positionX = 0
		ev.positionY = 0
		ev.slotOffset = 0

		local direction = (ev.dirMult and ev.dirMult < 0) and "Down" or "Up"
		local active = {}
		for i = 1, #events do
			local e = events[i]
			if e and (e.styleId == "Straight" or e.styleId == "Parabola") then
				active[#active + 1] = e
			end
		end

		if ev.styleId == "Parabola" then
			local behavior = (ev.paraDir and ev.paraDir > 0) and "CurvedRight" or "CurvedLeft"
			AE_MSBT_InitParabola(ev, active, direction, behavior)
			-- Prevent first-frame lateral snap: seed position on the curve at progress=0.
			if ev.animationHandler then
				ev.animationHandler(ev, 0)
			end
			ev.alpha = 0
			if ev.fs then ev.fs:SetAlpha(0) end
		else
			AE_MSBT_InitStraight(ev, active, direction)
		end
		-- MSBT applies speed after init.
		ev.scrollTime = (ev.scrollTime or 0) / ev.animationSpeed
	end

	-- Waterfall: keep unique wave motion, but use MSBT-style retiming to prevent overlap.
	if ev.styleId == "Waterfall" then
		ev.startAt = nil
		ev.elapsedTime = 0
		ev.scrollHeight = ev.areaH
		ev.scrollWidth = ev.areaW
		ev.anchorPoint = AE_ComputeAnchorPoint(ev.anchorH, ev.dirMult or 1)
		ev.animationSpeed = (type(ev.animationSpeed) == "number" and ev.animationSpeed > 0) and ev.animationSpeed or 1
		-- Keep the baseline inside the area so large/crit text doesn't spawn above the frame.
		local fontSize = ev.effectiveFontSize or ev.fontSize or 18
		ev.scrollHeight = math.max(1, (ev.areaH or 1) - fontSize)
		-- Use the resolved duration as the baseline scroll time.
		ev.scrollTime = (ev.duration or 3.5)
		-- Apply speed like other styles.
		ev.scrollTime = (ev.scrollTime or 0) / ev.animationSpeed

		local direction = (ev.dirMult and ev.dirMult < 0) and "Down" or "Up"
		local active = {}
		for i = 1, #events do
			local e = events[i]
			if e and e.styleId == "Waterfall" and e.elapsedTime ~= nil and e.scrollTime and e.scrollTime > 0 then
				active[#active + 1] = e
			end
		end
		AE_InitWaterfallSpacing(ev, active, direction)
	end

	-- MSBT-exact initialization for Pow (sticky crits).
	if ev.styleId == "Pow" then
		ev.startAt = nil
		ev.elapsedTime = 0
		ev.scrollHeight = ev.areaH
		ev.scrollWidth = ev.areaW
		ev.anchorPoint = AE_MSBT_AnchorPoint(ev)
		ev.animationSpeed = (type(ev.animationSpeed) == "number" and ev.animationSpeed > 0) and ev.animationSpeed or 1
		ev.masterAlpha = ev.fontAlpha or 1
		ev.fadePercent = MSBT_DEFAULT_FADE_PERCENT
		ev.alpha = 1
		ev.fontSize = ev.effectiveFontSize or ev.fontSize or 18
		-- Keep the baseline inside the area so large/crit text doesn't spawn above the frame.
		ev.scrollHeight = math.max(1, (ev.areaH or 1) - (ev.fontSize or 18))
		ev.positionX = 0
		ev.positionY = 0
		ev.fontString = ev.fs

		local direction = (ev.dirMult and ev.dirMult < 0) and "Down" or "Up"
		local active = {}
		for i = 1, #events do
			local e = events[i]
			if e and e.styleId == "Pow" then
				active[#active + 1] = e
			end
		end
		AE_MSBT_InitPow(ev, active, direction)
		ev.scrollTime = (ev.scrollTime or 0) / ev.animationSpeed
	end

	-- Static stacking: choose a lane; if colliding, expire older lines.
	if ev.styleId == "Static" then
		local fontSize = ev.effectiveFontSize or ev.fontSize or 18
		local lineHeight = fontSize + 2
		local usable = math.max(1, (ev.areaH or 1) - fontSize)
		local maxSlots = math.max(1, math.floor(usable / lineHeight) + 1)
		local lane = (st._staticNextLane or 0) % maxSlots
		st._staticNextLane = lane + 1
		if ev.dirMult and ev.dirMult < 0 then
			ev.staticSlotY = ((ev.areaH - fontSize) - (lane * lineHeight))
		else
			ev.staticSlotY = lane * lineHeight
		end
		if ev.anchorH == "LEFT" then
			ev.staticPoint = "BOTTOMLEFT"
		elseif ev.anchorH == "RIGHT" then
			ev.staticPoint = "BOTTOMRIGHT"
		else
			ev.staticPoint = "BOTTOM"
		end
		-- Expire older static events in the same lane band.
		for i = 1, #events do
			local oe = events[i]
			if oe and oe.styleId == "Static" and oe.staticSlotY == ev.staticSlotY then
				oe.elapsed = oe.duration
			end
		end
	end

	-- Fireworks soft separation (2B): nudge random seeds based on recent spawns.
	if ev.styleId == "Fireworks" then
		st._fwSpawnSerial = (st._fwSpawnSerial or 0) + 1
		local s = st._fwSpawnSerial
		ev.fwTheta = (ev.fwTheta or 0) + (math.sin(s * 1.7) * 0.12)
		ev.fwPerp = (ev.fwPerp or 0) + (math.cos(s * 1.3) * 0.10)

		-- Randomize the launch point along the selected origin edge so bursts don't stack.
		local origin = ev.fwOrigin or "Bottom"
		local w = ev.areaW or 0
		local h = ev.areaH or 0
		if origin == "Bottom" or origin == "Top" then
			-- Horizontal spread along the edge.
			ev.fwBaseX = (math.random() * 2.0 - 1.0) * (w * 0.20)
			ev.fwBaseY = 0
		else
			-- Vertical spread along the edge.
			ev.fwBaseX = 0
			ev.fwBaseY = (math.random() * 2.0 - 1.0) * (h * 0.18)
		end

		-- Tiny stagger to separate dense bursts (keeps cadence, reduces overlap).
		local stagger = (s % 3) * 0.02
		ev.startAt = (ev.startAt or AE_Now()) + stagger
	end

	events[#events + 1] = ev

	if not self._frame:IsShown() then
		self._frame:Show()
	end
	return true
end

AnimEngine._frame:SetScript("OnUpdate", function(_, dt)
	if not AnimEngine._enabled then return end
	local tok = ZSBT.Addon and ZSBT.Addon.PerfBegin and ZSBT.Addon:PerfBegin("UI.Anim")
	local budgetMs = nil
	local tStart = nil
	do
		local d = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.diagnostics
		local b = d and tonumber(d.animBudgetMs)
		if type(b) == "number" and b > 0 and type(debugprofilestop) == "function" then
			budgetMs = b
			tStart = debugprofilestop()
		end
	end

	local allEmpty = true
	for areaKey, st in pairs(AnimEngine._areas) do
		local events = st and st.events
		if events and #events > 0 then
			allEmpty = false
			for i = #events, 1, -1 do
				local ev = events[i]
				local done = AE_UpdateEvent(ev, dt)
				if done then
					AE_RecycleEvent(ev)
					table.remove(events, i)
				end
				if budgetMs and tStart then
					local elapsedMs = debugprofilestop() - tStart
					if elapsedMs >= budgetMs then
						if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
						return
					end
				end
			end
		end
	end
	if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end

	if allEmpty then
		AnimEngine._frame:Hide()
	end
end)

local function AcquireFontString(parent)
    local fs = table.remove(fontStringPool)
    if fs then
        fs:SetParent(parent)
        fs:ClearAllPoints()
        fs:SetAlpha(1)
        local okFont, fontPath = pcall(fs.GetFont, fs)
        if okFont and not fontPath and fs.SetFont then
            pcall(fs.SetFont, fs, STANDARD_TEXT_FONT, 12, "")
        end
        pcall(fs.SetText, fs, "")
        fs:Show()
        return fs
    end
    return parent:CreateFontString(nil, "OVERLAY")
end

local function AcquireIconFS(parent)
    local fs = table.remove(iconFSPool)
    if fs then
        fs:SetParent(parent)
        fs:ClearAllPoints()
        fs:SetAlpha(1)
        local okFont, fontPath = pcall(fs.GetFont, fs)
        if okFont and not fontPath and fs.SetFont then
            pcall(fs.SetFont, fs, STANDARD_TEXT_FONT, 12, "")
        end
        pcall(fs.SetText, fs, "")
        fs:Show()
        return fs
    end
    return parent:CreateFontString(nil, "OVERLAY")
end

local function AcquireAnimFrame()
    local f = table.remove(animFramePool)
    if f then
        f:SetScript("OnUpdate", nil)
        return f
    end
    return CreateFrame("Frame")
end

local MAX_POOL_SIZE = 60  -- cap to prevent unbounded growth

RecycleFontString = function(fs)
    if not fs then return end
    fs:Hide()
    fs:SetParent(recyclingBin)
    local okFont, fontPath = pcall(fs.GetFont, fs)
    if okFont and not fontPath and fs.SetFont then
        pcall(fs.SetFont, fs, STANDARD_TEXT_FONT, 12, "")
    end
    pcall(fs.SetText, fs, "")
    if #fontStringPool < MAX_POOL_SIZE then
        fontStringPool[#fontStringPool + 1] = fs
    end
end

RecycleIconFS = function(fs)
    if not fs then return end
    fs:Hide()
    fs:SetParent(recyclingBin)
    local okFont, fontPath = pcall(fs.GetFont, fs)
    if okFont and not fontPath and fs.SetFont then
        pcall(fs.SetFont, fs, STANDARD_TEXT_FONT, 12, "")
    end
    pcall(fs.SetText, fs, "")
    if #iconFSPool < MAX_POOL_SIZE then
        iconFSPool[#iconFSPool + 1] = fs
    end
end

RecycleAnimFrame = function(f)
    if not f then return end
    f:SetScript("OnUpdate", nil)
    if #animFramePool < MAX_POOL_SIZE then
        animFramePool[#animFramePool + 1] = f
    end
end

------------------------------------------------------------------------
-- Constants for visualization frames
------------------------------------------------------------------------

-- Color cycle for scroll area overlay frames (one per area, wraps)
local AREA_COLORS = {
    { r = 1.0, g = 0.2, b = 0.2, a = 0.3 },   -- Red
    { r = 0.2, g = 0.4, b = 1.0, a = 0.3 },   -- Blue
    { r = 0.2, g = 1.0, b = 0.2, a = 0.3 },   -- Green
    { r = 1.0, g = 1.0, b = 0.2, a = 0.3 },   -- Yellow
    { r = 0.7, g = 0.2, b = 1.0, a = 0.3 },   -- Purple
    { r = 1.0, g = 0.6, b = 0.1, a = 0.3 },   -- Orange
}

-- Border alpha is higher for visibility
local BORDER_ALPHA = 0.8

-- Storage for active visualization frames
local activeFrames = {}

-- Track unlock state
local isUnlocked = false

local lockButton = nil

-- Track continuous test state
local isContinuousTesting = false
local continuousTestTimer = nil

------------------------------------------------------------------------
-- Font Resolution
--
-- Scroll areas may override the global font. This is used by the test
-- animation now and will be consumed by the runtime display engine later.
------------------------------------------------------------------------
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
    local outlineFlag = ZSBT.OUTLINE_STYLES[outlineKey] or "OUTLINE"
    local fontAlpha = tonumber(alphaVal) or 1.0

    return fontFace, fontSize, outlineFlag, fontAlpha
end

------------------------------------------------------------------------
-- Feature A: Unlock/Lock Mode
------------------------------------------------------------------------

------------------------------------------------------------------------
-- CreateAreaFrame: Build a single visualization frame for one scroll area
-- @param areaName  (string) Name of the scroll area
-- @param areaData  (table)  Scroll area config {xOffset, yOffset, width, height, ...}
-- @param colorIdx  (number) Index into AREA_COLORS (1-based, wraps)
-- @return frame    (Frame)  The created visualization frame
------------------------------------------------------------------------
local function CreateAreaFrame(areaName, areaData, colorIdx)
    local color = AREA_COLORS[((colorIdx - 1) % #AREA_COLORS) + 1]

    -- Create the frame anchored to screen center (UIParent CENTER)
    local frame = CreateFrame("Frame", "ZSBT_AreaViz_" .. areaName, UIParent,
        "BackdropTemplate")
    frame:SetSize(areaData.width, areaData.height)
    frame:SetPoint("CENTER", UIParent, "CENTER", areaData.xOffset, areaData.yOffset)
    -- Keep frames above the config window while unlocked (new areas must be visible immediately)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(1000)

    -- Semi-transparent colored backdrop with rounded corners
    frame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,  -- Minimum size for rounded border texture
        insets   = { left = 16, right = 16, top = 16, bottom = 16 },
    })
    frame:SetBackdropColor(color.r, color.g, color.b, color.a)
    frame:SetBackdropBorderColor(color.r, color.g, color.b, BORDER_ALPHA)

    -- Area name label (centered in frame)
    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("CENTER", frame, "CENTER", 0, 0)
    label:SetText(areaName)
    label:SetTextColor(1, 1, 1, 0.9)

    -- Offset readout below the name (updates during drag)
    local offsetLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    offsetLabel:SetPoint("TOP", label, "BOTTOM", 0, -4)
    offsetLabel:SetTextColor(0.8, 0.8, 0.8, 0.8)
    offsetLabel:SetText(string.format("X: %d  Y: %d", areaData.xOffset, areaData.yOffset))
    frame.offsetLabel = offsetLabel

    -- Make the frame draggable
    frame:SetMovable(true)
    if frame.SetResizable then
        frame:SetResizable(true)
    end
    local minW = (ZSBT and ZSBT.SCROLL_WIDTH_MIN) or 50
    local minH = (ZSBT and ZSBT.SCROLL_HEIGHT_MIN) or 50
    local maxW = (ZSBT and ZSBT.SCROLL_WIDTH_MAX) or 800
    local maxH = (ZSBT and ZSBT.SCROLL_HEIGHT_MAX) or 800
    if frame.SetResizeBounds then
        frame:SetResizeBounds(minW, minH, maxW, maxH)
    else
        if frame.SetMinResize then frame:SetMinResize(minW, minH) end
        if frame.SetMaxResize then frame:SetMaxResize(maxW, maxH) end
    end
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")

    -- Store references for drag handler
    frame.areaName = areaName

    frame:SetScript("OnMouseDown", function(self)
        if ZSBT and ZSBT.SetSelectedScrollArea and self and self.areaName then
            ZSBT.SetSelectedScrollArea(self.areaName)
        end
    end)

    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)

    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()

        -- Calculate new offset from UIParent CENTER
        local centerX = UIParent:GetWidth() / 2
        local centerY = UIParent:GetHeight() / 2
        local frameX = self:GetLeft() + (self:GetWidth() / 2)
        local frameY = self:GetBottom() + (self:GetHeight() / 2)

        local newXOffset = math.floor(frameX - centerX + 0.5)
        local newYOffset = math.floor(frameY - centerY + 0.5)

        -- Clamp to slider range
        newXOffset = math.max(ZSBT.SCROLL_OFFSET_MIN,
                     math.min(ZSBT.SCROLL_OFFSET_MAX, newXOffset))
        newYOffset = math.max(ZSBT.SCROLL_OFFSET_MIN,
                     math.min(ZSBT.SCROLL_OFFSET_MAX, newYOffset))

        -- Update the saved profile data
        local area = ZSBT.db.profile.scrollAreas[self.areaName]
        if area then
            area.xOffset = newXOffset
            area.yOffset = newYOffset
        end

        -- Snap the frame to the clamped position (in case we clamped)
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "CENTER", newXOffset, newYOffset)

        -- Update the offset readout label immediately
        if self.offsetLabel then
            self.offsetLabel:SetText(string.format("X: %d  Y: %d",
                newXOffset, newYOffset))
        end

        -- Notify AceConfig to refresh sliders if the config dialog is open
        LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
    end)

    -- Optional resize grip (bottom-right)
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(frame:GetFrameLevel() + 5)
    grip:EnableMouse(true)
    grip:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
    local tex = grip:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(grip)
    tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip.tex = tex

    grip:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        frame:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        frame:StopMovingOrSizing()

        local w, h = frame:GetSize()
        w = math.floor((tonumber(w) or 0) + 0.5)
        h = math.floor((tonumber(h) or 0) + 0.5)
        local minW2 = (ZSBT and ZSBT.SCROLL_WIDTH_MIN) or 50
        local minH2 = (ZSBT and ZSBT.SCROLL_HEIGHT_MIN) or 50
        local maxW2 = (ZSBT and ZSBT.SCROLL_WIDTH_MAX) or 800
        local maxH2 = (ZSBT and ZSBT.SCROLL_HEIGHT_MAX) or 800
        w = math.max(minW2, math.min(maxW2, w))
        h = math.max(minH2, math.min(maxH2, h))
        frame:SetSize(w, h)

        local area = ZSBT.db.profile.scrollAreas[frame.areaName]
        if area then
            area.width = w
            area.height = h
        end
        LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
    end)

    frame:Show()
    return frame
end

------------------------------------------------------------------------
-- ShowScrollAreaFrames: Create and display visualization frames for all
-- configured scroll areas. Called when user clicks "Unlock Scroll Areas".
------------------------------------------------------------------------
function ZSBT.ShowScrollAreaFrames()
    -- Clean up any existing frames first
    ZSBT.HideScrollAreaFrames()

    if not ZSBT.db or not ZSBT.db.profile or not ZSBT.db.profile.scrollAreas then
        return
    end

    local colorIdx = 0
    for areaName, areaData in pairs(ZSBT.db.profile.scrollAreas) do
        colorIdx = colorIdx + 1
        local frame = CreateAreaFrame(areaName, areaData, colorIdx)
        activeFrames[areaName] = frame
    end

	if not lockButton then
		lockButton = CreateFrame("Button", "ZSBT_LockScrollAreasButton", UIParent, "UIPanelButtonTemplate")
		lockButton:SetSize(160, 28)
		lockButton:SetText("Lock Scroll Areas")
		lockButton:SetPoint("TOP", UIParent, "TOP", 0, -120)
		lockButton:SetFrameStrata("FULLSCREEN_DIALOG")
		lockButton:SetFrameLevel(1100)
		lockButton:SetScript("OnClick", function()
			if ZSBT and ZSBT.HideScrollAreaFrames then
				ZSBT.HideScrollAreaFrames()
			end
			local reg = LibStub and LibStub("AceConfigRegistry-3.0", true)
			if reg and reg.NotifyChange then
				reg:NotifyChange("ZSBT")
			end
		end)
	end
	lockButton:Show()

    isUnlocked = true
    Addon:Print("Scroll areas unlocked. Drag to reposition.")
end

------------------------------------------------------------------------
-- RefreshScrollAreaFrames: Reconcile active visualization frames with
-- current profile scrollAreas without requiring a lock/unlock cycle.
-- Called after create/delete while unlocked.
------------------------------------------------------------------------
function ZSBT.RefreshScrollAreaFrames()
    if not isUnlocked or not ZSBT.db or not ZSBT.db.profile or not ZSBT.db.profile.scrollAreas then
        return
    end

    local areas = ZSBT.db.profile.scrollAreas

    -- Remove frames that no longer exist
    for areaName, frame in pairs(activeFrames) do
        if not areas[areaName] then
            frame:Hide()
            frame:SetParent(recyclingBin)
            activeFrames[areaName] = nil
        end
    end

    -- Add frames for newly created areas
    local colorIdx = 0
    for _ in pairs(activeFrames) do colorIdx = colorIdx + 1 end

    for areaName, areaData in pairs(areas) do
        if not activeFrames[areaName] then
            colorIdx = colorIdx + 1
            activeFrames[areaName] = CreateAreaFrame(areaName, areaData, colorIdx)
        end
    end

    ZSBT.UpdateScrollAreaFrames()
end

------------------------------------------------------------------------
-- UpdateScrollAreaFrames: Update all active visualization frames to match
-- current profile settings (size, position). Called when sliders are adjusted.
------------------------------------------------------------------------
function ZSBT.UpdateScrollAreaFrames()
    if not isUnlocked or not ZSBT.db or not ZSBT.db.profile then
        return
    end

    for areaName, frame in pairs(activeFrames) do
        local areaData = ZSBT.db.profile.scrollAreas[areaName]
        if areaData then
            -- Update size
            frame:SetSize(areaData.width, areaData.height)
            
            -- Update position
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "CENTER", areaData.xOffset, areaData.yOffset)
            
            -- Update offset label
            if frame.offsetLabel then
                frame.offsetLabel:SetText(string.format("X: %d  Y: %d",
                    areaData.xOffset, areaData.yOffset))
            end
        end
    end
end


------------------------------------------------------------------------
-- HideScrollAreaFrames: Destroy all visualization frames.
-- Called when user clicks "Lock Scroll Areas".
------------------------------------------------------------------------
function ZSBT.HideScrollAreaFrames()
    -- Stop continuous testing if active
    if isContinuousTesting then
        ZSBT.StopContinuousTesting()
    end

	if lockButton then
		lockButton:Hide()
	end

    for areaName, frame in pairs(activeFrames) do
        frame:Hide()
        frame:SetParent(recyclingBin)  -- Release from UI hierarchy
    end
    wipe(activeFrames)

    isUnlocked = false
end

------------------------------------------------------------------------
-- IsUnlocked: Query whether scroll areas are currently in unlock mode.
-- Used by the toggle button in ConfigTabs.
------------------------------------------------------------------------
function ZSBT.IsScrollAreasUnlocked()
    return isUnlocked
end

------------------------------------------------------------------------
-- Feature B: Test Animation
------------------------------------------------------------------------

------------------------------------------------------------------------
-- TestScrollArea: Fire 3 dummy text numbers into the named scroll area.
-- Uses a 0.3s delay between each. Text uses the area's animation style,
-- direction, and alignment settings from the current profile.
-- Only works when scroll areas are unlocked.
--
-- @param areaName (string) Name of scroll area to test
------------------------------------------------------------------------
function ZSBT.TestScrollArea(areaName)
    if not areaName then
        Addon:Print("No scroll area selected for test.")
        return
    end

    -- Require scroll areas to be unlocked
    if not isUnlocked then
        Addon:Print("Scroll areas must be unlocked to test. Click 'Unlock Scroll Areas' first.")
        return
    end

    local area = ZSBT.db and ZSBT.db.profile
                  and ZSBT.db.profile.scrollAreas
                  and ZSBT.db.profile.scrollAreas[areaName]
    if not area then
        Addon:Print("Scroll area '" .. areaName .. "' not found.")
        return
    end

    local fontFace, fontSize, outlineFlag, fontAlpha = ResolveFontForArea(areaName)

    -- Determine alignment anchor point
    local alignmentMap = {
        ["Left"]   = "LEFT",
        ["Center"] = "CENTER",
        ["Right"]  = "RIGHT",
    }
    local anchorH = alignmentMap[area.alignment] or "CENTER"

    -- Determine scroll direction multiplier (Up = positive Y, Down = negative)
    local dirMult = (area.direction == "Down") and -1 or 1

    -- Animation duration base (modified by animSpeed)
    local baseDuration = 2.0   -- seconds for full scroll
    local duration = baseDuration / (area.animSpeed or 1.0)

    -- Mock event templates (same variety as continuous test)
    local mockEvents = {
        "Fireball 1523",
        "Pyroblast 2841",
        "Heal +842",
    }

    for i, text in ipairs(mockEvents) do
        -- Use C_Timer.After for staggered firing (0.0, 0.3, 0.6 seconds)
        C_Timer.After((i - 1) * 0.3, function()
            local color = {r = 1, g = 0.25, b = 0.25}
            ZSBT.FireTestText(text, area, fontFace, fontSize, outlineFlag,
                              fontAlpha, anchorH, dirMult, duration, color)
        end)
    end
end

------------------------------------------------------------------------
-- TestScrollAreaCrit: Fire crit test events into the named scroll area.
-- Uses the crit font settings for the "Pow" sticky animation.
------------------------------------------------------------------------
function ZSBT.TestScrollAreaCrit(areaName)
    if not areaName then
        Addon:Print("No scroll area selected for crit test.")
        return
    end

    if not isUnlocked then
        Addon:Print("Scroll areas must be unlocked to test. Click 'Unlock Scroll Areas' first.")
        return
    end

    local area = ZSBT.db and ZSBT.db.profile
                  and ZSBT.db.profile.scrollAreas
                  and ZSBT.db.profile.scrollAreas[areaName]
    if not area then
        Addon:Print("Scroll area '" .. areaName .. "' not found.")
        return
    end

    local fontFace, fontSize, outlineFlag, fontAlpha = ResolveFontForArea(areaName)
    local anchorH = ({["Left"] = "LEFT", ["Center"] = "CENTER", ["Right"] = "RIGHT"})[area.alignment] or "CENTER"
    local dirMult = (area.direction == "Down") and -1 or 1
    local duration = 2.0 / (area.animSpeed or 1.0)

    -- Resolve crit font settings
    local critMeta = { isCrit = true }
    local profile = ZSBT.db and ZSBT.db.profile
    if profile and profile.general and profile.general.critFont then
        local critConf = profile.general.critFont
        local general = (profile.general and profile.general.font) or {}
        local faceKey = critConf.face or general.face or "Friz Quadrata TT"
        local LSM = LibStub("LibSharedMedia-3.0", true)
        if LSM and faceKey then
            local fetched = LSM:Fetch("font", faceKey)
            if fetched then critMeta.critFace = fetched end
        end
        if critConf.useScale == true then
            critMeta.critSize = nil
        else
            critMeta.critSize = tonumber(critConf.size) or 28
        end
        local outKey = critConf.outline or "Thick"
        critMeta.critOutline = ZSBT.OUTLINE_STYLES and ZSBT.OUTLINE_STYLES[outKey] or "THICKOUTLINE"
        critMeta.critScale = tonumber(critConf.scale) or 1.5
		critMeta.critAnim = critConf.anim
    else
        critMeta.critSize = 28
        critMeta.critOutline = "THICKOUTLINE"
        critMeta.critScale = 1.5
		critMeta.critAnim = "Pow"
    end

    local mockCrits = {
        { text = "*4,271*", color = {r = 1, g = 0.85, b = 0} },
        { text = "*7,892*", color = {r = 1, g = 0.1, b = 0.1} },
        { text = "*+2,150*", color = {r = 0.1, g = 1, b = 0.1} },
    }

    for i, mock in ipairs(mockCrits) do
        C_Timer.After((i - 1) * 0.8, function()
            ZSBT.FireTestText(mock.text, area, fontFace, fontSize, outlineFlag,
                              fontAlpha, anchorH, dirMult, duration, mock.color, critMeta)
        end)
    end
end

local function BuildCritMeta(stream)
	local critMeta = { isCrit = true }
	if type(stream) == "string" and stream ~= "" then
		critMeta.stream = stream
	end
	local profile = ZSBT.db and ZSBT.db.profile
	local general = profile and profile.general
	local masterFont = (general and general.font) or {}

	local critConf = general and general.critFont or nil
	if stream == "incoming" and profile and type(profile.incoming) == "table" then
		local ic = profile.incoming.critFont
		if type(ic) == "table" and ic.enabled == true then
			critConf = ic
		end
	elseif stream == "outgoing" and profile and type(profile.outgoing) == "table" then
		local oc = profile.outgoing.critFont
		if type(oc) == "table" and oc.enabled == true then
			critConf = oc
		end
	end

	if critConf then
		local faceKey = critConf.face or masterFont.face or "Friz Quadrata TT"
		local LSM = LibStub("LibSharedMedia-3.0", true)
		if LSM and faceKey then
			local fetched = LSM:Fetch("font", faceKey)
			if fetched then critMeta.critFace = fetched end
		end
		if critConf.useScale == true then
			critMeta.critSize = nil
		else
			critMeta.critSize = tonumber(critConf.size) or 28
		end
		local outKey = critConf.outline or "Thick"
		critMeta.critOutline = ZSBT.OUTLINE_STYLES and ZSBT.OUTLINE_STYLES[outKey] or "THICKOUTLINE"
		critMeta.critScale = tonumber(critConf.scale) or 1.5
		critMeta.critAnim = critConf.anim
	else
		critMeta.critSize = 28
		critMeta.critOutline = "THICKOUTLINE"
		critMeta.critScale = 1.5
		critMeta.critAnim = "Pow"
	end

	return critMeta
end

function ZSBT.TestIncomingHealCrit()
	if not isUnlocked then
		Addon:Print("Scroll areas must be unlocked to test. Click 'Unlock Scroll Areas' first.")
		return
	end
	local prof = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.incoming
	local conf = prof and prof.healing
	local areaName = (conf and (conf.critScrollArea or conf.scrollArea)) or "Incoming"
	if type(areaName) ~= "string" or areaName == "" then areaName = "Incoming" end
	local area = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.scrollAreas and ZSBT.db.profile.scrollAreas[areaName]
	if not area then
		Addon:Print("Scroll area '" .. tostring(areaName) .. "' not found.")
		return
	end
	local fontFace, fontSize, outlineFlag, fontAlpha = ResolveFontForArea(areaName)
	local anchorH = ({["Left"] = "LEFT", ["Center"] = "CENTER", ["Right"] = "RIGHT"})[area.alignment] or "CENTER"
	local dirMult = (area.direction == "Down") and -1 or 1
	local duration = 2.0 / (area.animSpeed or 1.0)
	local critMeta = BuildCritMeta("incoming")
	local color = {r = 0.20, g = 1.00, b = 0.40}
	ZSBT.FireTestText("*+7,777*", area, fontFace, fontSize, outlineFlag, fontAlpha, anchorH, dirMult, duration, color, critMeta)
end

function ZSBT.TestIncomingDamageCrit()
	if not isUnlocked then
		Addon:Print("Scroll areas must be unlocked to test. Click 'Unlock Scroll Areas' first.")
		return
	end
	local prof = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.incoming
	local conf = prof and prof.damage
	local areaName = (conf and (conf.critScrollArea or conf.scrollArea)) or "Incoming"
	if type(areaName) ~= "string" or areaName == "" then areaName = "Incoming" end
	local area = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.scrollAreas and ZSBT.db.profile.scrollAreas[areaName]
	if not area then
		Addon:Print("Scroll area '" .. tostring(areaName) .. "' not found.")
		return
	end
	local fontFace, fontSize, outlineFlag, fontAlpha = ResolveFontForArea(areaName)
	local anchorH = ({["Left"] = "LEFT", ["Center"] = "CENTER", ["Right"] = "RIGHT"})[area.alignment] or "CENTER"
	local dirMult = (area.direction == "Down") and -1 or 1
	local duration = 2.0 / (area.animSpeed or 1.0)
	local critMeta = BuildCritMeta("incoming")
	local color = {r = 1.00, g = 1.00, b = 0.00}
	ZSBT.FireTestText("*9,999*", area, fontFace, fontSize, outlineFlag, fontAlpha, anchorH, dirMult, duration, color, critMeta)
end

------------------------------------------------------------------------
-- TestAllScrollAreas: Fire test events into ALL unlocked scroll areas.
-- Only fires into areas that are currently unlocked (visualization frames shown).
-- Uses a variety of mock events: damage, healing, and notifications.
-- Each area gets 3 events with 0.3s stagger, respecting each area's
-- individual animation settings.
-- Internal function - called once per test cycle.
------------------------------------------------------------------------
local function FireAllAreasOnce()
    -- Mock event templates (mix of damage, healing, notifications)
    local mockEvents = {
        { text = "Fireball 1523",      type = "damage" },
        { text = "Heal +842",           type = "healing" },
        { text = "Wind Shear Ready!",   type = "notification" },
        { text = "Pyroblast 2841",      type = "damage" },
        { text = "Rejuvenation +234",   type = "healing" },
    }

    -- Fire test events into each unlocked area
    for areaName, _ in pairs(activeFrames) do
        local area = ZSBT.db and ZSBT.db.profile
                      and ZSBT.db.profile.scrollAreas
                      and ZSBT.db.profile.scrollAreas[areaName]
        
        if area then
            local fontFace, fontSize, outlineFlag, fontAlpha = ResolveFontForArea(areaName)

            -- Determine alignment anchor point
            local alignmentMap = {
                ["Left"]   = "LEFT",
                ["Center"] = "CENTER",
                ["Right"]  = "RIGHT",
            }
            local anchorH = alignmentMap[area.alignment] or "CENTER"

            -- Determine scroll direction multiplier
            local dirMult = (area.direction == "Down") and -1 or 1

            -- Animation duration
            local baseDuration = 2.0
            local duration = baseDuration / (area.animSpeed or 1.0)

            -- Fire 3 mock events with stagger
            for i = 1, 3 do
                local mockEvent = mockEvents[((i - 1) % #mockEvents) + 1]
                
                C_Timer.After((i - 1) * 0.3, function()
                    ZSBT.FireTestText(mockEvent.text, area, fontFace, fontSize,
                                      outlineFlag, fontAlpha, anchorH, dirMult, duration)
                end)
            end
        end
    end
end

------------------------------------------------------------------------
-- StartContinuousTesting: Start continuous test animation loop
------------------------------------------------------------------------
function ZSBT.StartContinuousTesting()
    -- Check if any areas are unlocked
    local hasUnlockedAreas = false
    for areaName, _ in pairs(activeFrames) do
        hasUnlockedAreas = true
        break
    end

    if not hasUnlockedAreas then
        Addon:Print("No scroll areas are unlocked. Use 'Unlock Scroll Areas' first.")
        return
    end

    if isContinuousTesting then
        -- Already running
        return
    end

    isContinuousTesting = true
    Addon:Print("Continuous testing started. Animations will repeat every 3 seconds.")

    -- Fire immediately
    FireAllAreasOnce()

    -- Set up repeating timer (3 second interval to allow animations to complete)
    local function RepeatTest()
        if not isContinuousTesting then
            return
        end
        
        FireAllAreasOnce()
        
        -- Schedule next iteration
        continuousTestTimer = C_Timer.After(3.0, RepeatTest)
    end

    -- Schedule first repeat
    continuousTestTimer = C_Timer.After(3.0, RepeatTest)
    
    -- Notify AceConfig to update button name
    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
end

------------------------------------------------------------------------
-- StopContinuousTesting: Stop continuous test animation loop
------------------------------------------------------------------------
function ZSBT.StopContinuousTesting()
    if not isContinuousTesting then
        return
    end

    isContinuousTesting = false
    
    -- Cancel pending timer if any
    if continuousTestTimer then
        continuousTestTimer = nil
    end

    Addon:Print("Continuous testing stopped.")
    
    -- Notify AceConfig to update button name
    LibStub("AceConfigRegistry-3.0"):NotifyChange("ZSBT")
end

------------------------------------------------------------------------
-- IsContinuousTesting: Query whether continuous testing is active
------------------------------------------------------------------------
function ZSBT.IsContinuousTesting()
    return isContinuousTesting
end

------------------------------------------------------------------------
-- FireTestText: Create and animate a single test text FontString.
-- This is a standalone test display, independent of the future
-- Display.lua pooling system.
--
-- @param text         (string) Text to display
-- @param area         (table)  Scroll area config
-- @param fontFace     (string) Font file path
-- @param fontSize     (number) Font size
-- @param outlineFlag  (string) WoW outline flag ("", "OUTLINE", etc.)
-- @param fontAlpha    (number) Starting alpha (0-1)
-- @param anchorH      (string) Horizontal anchor ("LEFT","CENTER","RIGHT")
-- @param dirMult      (number) Direction multiplier (+1 up, -1 down)
-- @param duration     (number) Animation duration in seconds
------------------------------------------------------------------------
-- @param color        (table|nil) Optional {r,g,b,a} text color. If nil,
--                      uses ZSBT.COLORS.ACCENT.
function ZSBT.FireTestText(text, area, fontFace, fontSize, outlineFlag,
                           fontAlpha, anchorH, dirMult, duration, color, meta)
	local tok = ZSBT.Addon and ZSBT.Addon.PerfBegin and ZSBT.Addon:PerfBegin("UI.FireText")
    -- Validate area data with safe defaults
    local xOff = (type(area.xOffset) == "number") and area.xOffset or 0
    local yOff = (type(area.yOffset) == "number") and area.yOffset or 0
    local areaW = (type(area.width) == "number") and area.width or 300
    local areaH = (type(area.height) == "number") and area.height or 200

	-- Crit positioning: when crits share the same scroll area as normal text,
	-- shift them horizontally so they don't overlap the base stream.
	-- Incoming crits shift left; outgoing crits shift right.
	local critSideX = 0
	local critCenterY = false
	local forceInline = ZSBT and ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general and ZSBT.db.profile.general.forceCritsInline == true
	if (not forceInline) and meta and meta.isCrit == true and meta.critRouted ~= true then
		local stream = meta.stream
		if stream == "incoming" then
			critSideX = -1
			critCenterY = true
		elseif stream == "outgoing" then
			critSideX = 1
			critCenterY = true
		end
	end
	if critSideX ~= 0 then
		local shift = math.min(120, math.max(40, areaW * 0.22))
		xOff = xOff + (critSideX * shift)
	end
	if critCenterY then
		local shiftDown = math.min(90, math.max(20, areaH * 0.12))
		yOff = yOff - shiftDown
	end
    local animStyle = area.animation or "Straight"
    local isFireworksEarly = animStyle:find("Fireworks") or animStyle:find("fireworks")
    local fwOriginEarly = nil
    if isFireworksEarly then
        if animStyle == "Fireworks" or animStyle == "fireworks" then
            fwOriginEarly = (area and area.fireworksOrigin) or "Bottom"
        elseif animStyle == "Fireworks Bottom" or animStyle == "fireworks_bottom" then
            fwOriginEarly = "Bottom"
        elseif animStyle == "Fireworks Top" or animStyle == "fireworks_top" then
            fwOriginEarly = "Top"
        elseif animStyle == "Fireworks Left" or animStyle == "fireworks_left" then
            fwOriginEarly = "Left"
        elseif animStyle == "Fireworks Right" or animStyle == "fireworks_right" then
            fwOriginEarly = "Right"
        end
        if not fwOriginEarly then fwOriginEarly = "Bottom" end
    end

    -- Crit / Sticky detection from meta
    local isCrit = meta and meta.isCrit
    local isSticky = meta and meta.sticky == true

    -- Crits can either force Pow (sticky) or follow the scroll area's animation
    local usePow = false
    local critAnim = meta and meta.critAnim
    local critFace = meta and meta.critFace
    local critOutline = meta and meta.critOutline
    local critSize = meta and meta.critSize
    local critScale = (meta and meta.critScale) or 1.5
    local stickyScale = (meta and meta.stickyScale) or 1.0
    local stickyDurationMult = (meta and meta.stickyDurationMult) or 1.0
    local effectiveFontSize = fontSize or 18

    if isCrit then
        if critAnim == nil or critAnim == "Pow" then
            usePow = true
        end
        duration = math.max(duration, 1.5)
        if critSize then
            effectiveFontSize = critSize
        else
            effectiveFontSize = math.floor(effectiveFontSize * critScale)
        end
        if stickyScale and stickyScale > 1 then
            effectiveFontSize = math.floor(effectiveFontSize * stickyScale)
        end
        -- Override font face and outline for crits if configured
        if critFace then fontFace = critFace end
        if critOutline then outlineFlag = critOutline end
    end

    -- Sticky (crit-style) notifications without marking as crit
    if (not isCrit) and isSticky then
        usePow = true
        if type(stickyDurationMult) == "number" and stickyDurationMult > 1 then
            duration = duration * stickyDurationMult
        end
        if type(stickyScale) == "number" and stickyScale > 1 then
            effectiveFontSize = math.floor(effectiveFontSize * stickyScale)
        end
    end

	local parentKey = string.format("test_%d_%d", xOff, yOff)
    
    if not ZSBT._testParentFrames then
        ZSBT._testParentFrames = {}
    end
    
    local parent = ZSBT._testParentFrames[parentKey]
    if not parent then
        parent = CreateFrame("Frame", "ZSBT_TestParent_" .. parentKey, UIParent)
        parent:SetFrameStrata("HIGH")
        -- No clipping — text fades at edges instead
        ZSBT._testParentFrames[parentKey] = parent
    end
    
    parent:ClearAllPoints()
    parent:SetSize(areaW, areaH)
    parent:SetPoint("CENTER", UIParent, "CENTER", xOff, yOff)
    parent:Show()

    -- Slot tracking: stagger new texts so they don't stack on each other.
    -- Wraps around when slots exceed area height.
    if not ZSBT._slotTrackers then
        ZSBT._slotTrackers = {}
    end
    if not ZSBT._slotTrackers[parentKey] then
        ZSBT._slotTrackers[parentKey] = { nextSlot = 0, lastTime = 0, slotExpiry = {} }
    end
    local tracker = ZSBT._slotTrackers[parentKey]
    local now = GetTime()
    -- Reset slot counter after a gap (no events for 0.5s).
    -- For Static text, do NOT reset early, because the whole point is that
    -- it stays on screen and occupies lanes for its full duration.
    local isStaticStyle = (animStyle == "Static" or animStyle == "static")
    local isParabolaStyle = (animStyle == "Parabola" or animStyle == "parabola"
        or animStyle == "Parabola Right" or animStyle == "parabola_right"
        or animStyle == "Parabola Left" or animStyle == "parabola_left")
    if (not isStaticStyle) and (not isParabolaStyle) and (now - tracker.lastTime) > 0.5 then
        tracker.nextSlot = 0
        if tracker.slotExpiry then
            for k in pairs(tracker.slotExpiry) do
                tracker.slotExpiry[k] = nil
            end
        end
    end
    -- Lane spacing. Static in MSBT uses very tight spacing (fontSize + small padding).
    -- Using too much padding makes Static run out of lanes and wrap early.
    local lineHeight = effectiveFontSize + 6
    if isStaticStyle then
        lineHeight = effectiveFontSize + 2
    end
    local maxSlots = math.max(1, math.floor(areaH / lineHeight))
    if isStaticStyle then
        -- Static lanes should fill the entire area up to the top edge.
        -- Account for font height so the last line isn't treated as out-of-bounds
        -- too early (which makes stacking appear to stop around the center).
        local usable = math.max(1, areaH - effectiveFontSize)
        maxSlots = math.max(1, math.floor(usable / lineHeight) + 1)
    end
    local slotOffset = 0
    local staticSlotY = nil
    if not usePow then
        if not tracker.slotExpiry then tracker.slotExpiry = {} end

        -- Find an available lane whose previous text has expired.
        local pickedSlot = nil
        for i = 0, (maxSlots - 1) do
            if not tracker.slotExpiry[i] or tracker.slotExpiry[i] <= now then
                pickedSlot = i
                break
            end
        end
        if pickedSlot == nil then
            -- All lanes are occupied; fall back to round-robin.
            pickedSlot = (tracker.nextSlot % maxSlots)
        end

        -- Fireworks should ignore scroll direction. Use the chosen origin edge
        -- to decide how slots spread so they stay anchored to that border.
        if isFireworksEarly then
            if fwOriginEarly == "Top" then
                -- Spread downward into the area
                slotOffset = -(pickedSlot * lineHeight)
            elseif fwOriginEarly == "Bottom" then
                -- Spread upward into the area
                slotOffset = (pickedSlot * lineHeight)
            else
                -- Left/Right origins: spread around the center vertically
                local center = (maxSlots - 1) / 2
                slotOffset = (pickedSlot - center) * lineHeight
            end
        elseif animStyle == "Static" or animStyle == "static" then
            -- MSBT Static stacks in fixed lanes in a bottom-anchored coordinate space.
            -- Up: start at bottom (0) and go up. Down: start at top (areaH) and go down.
            if dirMult > 0 then
                staticSlotY = pickedSlot * lineHeight
            else
                -- Keep the baseline inside the area so the first line doesn't clip.
                staticSlotY = (areaH - effectiveFontSize) - (pickedSlot * lineHeight)
            end
            slotOffset = 0
        else
            slotOffset = pickedSlot * lineHeight * dirMult
        end
        -- Mark this lane as occupied long enough for the text to clear.
        -- Static should occupy the lane for the full duration (MSBT-like).
        local occupyFor = duration
        if isStaticStyle then
            occupyFor = duration
        elseif isParabolaStyle then
            -- For Parabola (and other vertical scrolling), overlap happens near the
            -- spawn edge if we reuse the lane before the previous text has moved.
            -- Estimate the time needed to move by one line height.
            local travelTime = (lineHeight * duration) / math.max(1, areaH)
            occupyFor = math.min(duration, travelTime + 0.05)
        else
            -- Using most of the duration prevents overlap for dense scrolling bursts.
            occupyFor = duration * 0.85
        end
        tracker.slotExpiry[pickedSlot] = now + occupyFor
        tracker.nextSlot = tracker.nextSlot + 1
    end
    tracker.lastTime = now

    -- Acquire a FontString from pool (or create new)
    local fs = AcquireFontString(parent)
    local fontOk = fs:SetFont(fontFace, effectiveFontSize, outlineFlag or "OUTLINE")
    if not fontOk then
        fs:SetFont("Fonts\\FRIZQT__.TTF", effectiveFontSize, "OUTLINE")
    end

    -- SetText: clean strings directly, tainted via pcall
    if ZSBT.IsSafeString(text) then
        fs:SetText(text)
    elseif ZSBT.IsSafeNumber(text) then
        fs:SetText(tostring(math.floor(text + 0.5)))
    else
        local ok = pcall(fs.SetText, fs, text)
        if not ok then
            fs:SetText("*")
        end
    end
    fs:SetAlpha(fontAlpha or 1.0)
    fs:Show()

    -- Spell icon: prepend |T texture escape to text if clean,
    -- or use a separate icon FontString for raw pipe (tainted) text
    local iconTex = nil  -- kept for cleanup compatibility
    local iconFS = nil   -- second FontString for icon-only
    local iconSize = math.min(fontSize or 18, 16)
    local hasInlineIcon = false

    if meta and meta.spellIcon then
        -- For Center alignment, keep the TEXT centered by itself.
        -- Inline icons become part of the string width and shift the letters to the right.
        -- Use a separate icon FontString instead.
        if anchorH == "CENTER" then
            iconFS = AcquireIconFS(parent)
            iconFS:SetFont(fontFace, effectiveFontSize, outlineFlag or "OUTLINE")
            local iconStr = "|T" .. meta.spellIcon .. ":" .. iconSize .. ":" .. iconSize .. "|t"
            iconFS:SetText(iconStr)
            iconFS:SetPoint("RIGHT", fs, "LEFT", -2, 0)
            iconFS:SetAlpha(fontAlpha or 1.0)
            iconFS:Show()
        else
            if ZSBT.IsSafeString(text) then
                -- Clean text: inline icon escape
                local iconStr = "|T" .. meta.spellIcon .. ":" .. iconSize .. ":" .. iconSize .. "|t "
                fs:SetText(iconStr .. text)
                hasInlineIcon = true
            else
                -- Tainted: use separate icon FontString with embedded texture escape
                iconFS = AcquireIconFS(parent)
                iconFS:SetFont(fontFace, effectiveFontSize, outlineFlag or "OUTLINE")
                local iconStr = "|T" .. meta.spellIcon .. ":" .. iconSize .. ":" .. iconSize .. "|t"
                iconFS:SetText(iconStr)
                iconFS:SetPoint("RIGHT", fs, "LEFT", -2, 0)
                iconFS:SetAlpha(fontAlpha or 1.0)
                iconFS:Show()
            end
        end
    end

    local c = color or ZSBT.COLORS.ACCENT
    if c then
        fs:SetTextColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1.0)
    else
        fs:SetTextColor(1, 1, 1, 1)
    end

    -- Secret value visual filtering (Midnight dungeon-safe)
    -- If meta carries a tainted value + threshold, use C_CurveUtil / StatusBar
    -- to determine if this text should be visible.
    if meta and meta.secretRawValue and meta.filterThreshold then
        local alphaResult = ZSBT.EvaluateSecretThreshold(meta.secretRawValue, meta.filterThreshold)
        if alphaResult == 0 then
            -- Threshold says hide — recycle and bail
            RecycleFontString(fs)
            RecycleIconFS(iconFS)
            if iconTex then iconTex:Hide(); iconTex:SetParent(recyclingBin) end
			if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
            return
        end
    end

    -- Starting position with stagger offset
    local startAnchorV = (dirMult > 0) and "BOTTOM" or "TOP"
    local startPoint = startAnchorV
    if anchorH == "LEFT" then
        startPoint = startAnchorV .. "LEFT"
    elseif anchorH == "RIGHT" then
        startPoint = startAnchorV .. "RIGHT"
    end

    -- Fireworks ignores scroll direction; anchor to the chosen origin border.
    -- Use the early-resolved origin here (fwOrigin is computed later).
    if isFireworksEarly and fwOriginEarly then
        if fwOriginEarly == "Top" then
            startPoint = "TOP"
        elseif fwOriginEarly == "Bottom" then
            startPoint = "BOTTOM"
        elseif fwOriginEarly == "Left" then
            startPoint = "LEFT"
        elseif fwOriginEarly == "Right" then
            startPoint = "RIGHT"
        end
    end

    if usePow then
        fs:SetPoint("CENTER", parent, "CENTER", 0, 0)
    else
        fs:SetPoint(startPoint, parent, startPoint, 0, slotOffset)
    end

    -- Animation
    local totalDistance = areaH
    local elapsed = 0
    local lastFontSize = nil

    -- Determine parabola direction
    local paraDir = 1
    if animStyle == "Parabola Left" or animStyle == "parabola_left" then
        paraDir = -1
    elseif animStyle == "Parabola Right" or animStyle == "parabola_right" then
        paraDir = 1
    elseif animStyle == "Parabola" or animStyle == "parabola" then
        local side = area and area.parabolaSide
        if side == "Left" then
            paraDir = -1
        elseif side == "Right" then
            paraDir = 1
        end
    end
    local isParabola = (animStyle == "Parabola" or animStyle == "parabola"
        or animStyle == "Parabola Right" or animStyle == "parabola_right"
        or animStyle == "Parabola Left" or animStyle == "parabola_left")

    -- Detect new animation types
    local isFireworks = animStyle:find("Fireworks") or animStyle:find("fireworks")
    local isWaterfall = animStyle:find("Waterfall") or animStyle:find("waterfall")

    -- Fireworks: each text gets a random spray vector in a hemisphere
    local fwTheta = 0
    local fwSpeed = 0
    local fwPerp = 0
    local fwOrigin = nil
    if isFireworks then
        if animStyle == "Fireworks" or animStyle == "fireworks" then
            fwOrigin = (area and area.fireworksOrigin) or "Bottom"
        elseif animStyle == "Fireworks Bottom" or animStyle == "fireworks_bottom" then
            fwOrigin = "Bottom"
        elseif animStyle == "Fireworks Top" or animStyle == "fireworks_top" then
            fwOrigin = "Top"
        elseif animStyle == "Fireworks Left" or animStyle == "fireworks_left" then
            fwOrigin = "Left"
        elseif animStyle == "Fireworks Right" or animStyle == "fireworks_right" then
            fwOrigin = "Right"
        end
        -- Spray angle within ~75 degrees of the main axis
        local maxAngle = math.rad(75)
        fwTheta = (math.random() * 2.0 - 1.0) * maxAngle
        -- Perpendicular wobble so bursts look like a bloom, not a line
        fwPerp = (math.random() * 2.0 - 1.0) * 0.35
        -- Base speed (scaled later by area size)
        fwSpeed = 0.95 + math.random() * 0.55
    end

    -- Waterfall: each text gets its own wave phase so lines don't synchronize
    local wfPhase1 = 0
    local wfPhase2 = 0
    local wfNoise = 0
    if isWaterfall then
        wfPhase1 = math.random() * 6.28318
        wfPhase2 = math.random() * 6.28318
        wfNoise = (math.random() * 2.0 - 1.0)
    end

    -- Random position offset for crits
    local critRandX = 0
    local critRandY = 0
    if usePow then
        -- Spread crits across the whole scroll area to reduce overlap.
        -- Use padding so large crits don't spawn clipped at the edges.
        local padX = math.min(areaW * 0.10, (effectiveFontSize or 18) * 2.0)
        local padY = math.min(areaH * 0.10, (effectiveFontSize or 18) * 2.0)
        local maxX = math.max(0, (areaW * 0.5) - padX)
        local maxY = math.max(0, (areaH * 0.5) - padY)
        -- When crits share the normal scroll area (not routed to a crit area),
        -- keep the vertical spread tighter so crits stay closer to the center.
        if meta and meta.isCrit == true and meta.critRouted ~= true then
            maxY = maxY * 0.45
        end
        critRandX = (math.random() * 2.0 - 1.0) * maxX
        critRandY = (math.random() * 2.0 - 1.0) * maxY
    end

    -- Small drift seed to reduce overlap when many events fire together
    local driftPhase = math.random() * 10.0

    -- Central engine path (preferred): enqueue and return.
    -- Keep the legacy per-event OnUpdate path as a fallback.
    if AnimEngine and AnimEngine.Enqueue and AnimEngine._enabled then
        local startPointEngine = startPoint
        -- Parabola in MSBT uses a left-origin coordinate space.
        if isParabola then
            startPointEngine = (dirMult > 0) and "BOTTOMLEFT" or "TOPLEFT"
        end

        local ev = {
            fs = fs,
            iconFS = iconFS,
            iconTex = iconTex,
            parent = parent,
            slotOffset = slotOffset,
            areaW = areaW,
            areaH = areaH,
            animationSpeed = (area and area.animSpeed) or 1.0,
            animStyle = animStyle,
            anchorH = anchorH,
            dirMult = dirMult,
            duration = duration,
            fontFace = fontFace,
            fontSize = fontSize,
            effectiveFontSize = effectiveFontSize,
            outlineFlag = outlineFlag,
            fontAlpha = fontAlpha or 1.0,
            startPoint = startPointEngine,
            paraDir = paraDir,
            waterfallStyle = (area and area.waterfallStyle) or "Smooth",
            wfPhase1 = wfPhase1,
            wfPhase2 = wfPhase2,
            wfNoise = wfNoise,
            fwTheta = fwTheta,
            fwSpeed = fwSpeed,
            fwPerp = fwPerp,
            fwOrigin = fwOriginEarly,
            critRandX = critRandX,
            critRandY = critRandY,
            usePow = usePow,
            driftPhase = driftPhase,
            meta = meta,
        }

        local ok = AnimEngine:Enqueue(parentKey, ev)
        if ok then
			if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
            return
        end
    end

    local animFrame = AcquireAnimFrame()
    animFrame:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        local progress = elapsed / duration
        if progress >= 1.0 then
            RecycleFontString(fs)
            RecycleIconFS(iconFS)
            if iconTex then iconTex:Hide(); iconTex:SetParent(recyclingBin) end
            RecycleAnimFrame(self)
			if tok and ZSBT.Addon and ZSBT.Addon.PerfEnd then ZSBT.Addon:PerfEnd(tok) end
            return
        end

        local yOff2 = 0
        local xOff2 = 0

        if usePow then
            --------------------------------------------------------
            -- CRIT "POW" — zoom in BIG, shake hard, hold, fade out
            --------------------------------------------------------
            local scale = 1.0
            local shakeX = 0
            local shakeY = 0

            if progress < 0.07 then
                local zoomProg = progress / 0.07
                scale = 0.15 + (zoomProg * 1.55)
            elseif progress < 0.18 then
                local shakeProg = (progress - 0.07) / 0.11
                local intensity = (1.0 - shakeProg) * 18
                shakeX = math.sin(elapsed * 60) * intensity
                shakeY = math.cos(elapsed * 55) * (intensity * 0.55)
                scale = 1.55 - (shakeProg * 0.35)
            elseif progress < 0.55 then
                local holdProg = (progress - 0.18) / 0.37
                scale = 1.12 - (holdProg * 0.12)
            elseif progress < 0.70 then
                local bounceProg = (progress - 0.55) / 0.15
                scale = 1.0 + math.sin(bounceProg * math.pi) * 0.06
            else
                local fadeProg = (progress - 0.70) / 0.30
                scale = 1.0 - (fadeProg * 0.45)
            end
            -- Position at random spot within the area (pre-computed)
            yOff2 = critRandY + shakeY
            xOff2 = critRandX + shakeX

            local scaledSize = math.max(8, math.floor(effectiveFontSize * scale))
            if scaledSize ~= lastFontSize then
                lastFontSize = scaledSize
                pcall(fs.SetFont, fs, fontFace, scaledSize, outlineFlag or "OUTLINE")
            end

            local alpha = fontAlpha
            if progress < 0.10 then
                alpha = fontAlpha
            elseif progress > 0.70 then
                alpha = fontAlpha * (1.0 - ((progress - 0.70) / 0.30))
            end
            fs:SetAlpha(math.max(0, alpha))

        elseif animStyle == "Static" or animStyle == "static" then
            --------------------------------------------------------
            -- STATIC — fade in, hold, fade out (notifications)
            --------------------------------------------------------
            -- MSBT Static: no movement; alpha stays full until late fade.
            xOff2 = 0
            yOff2 = 0
            local alpha = fontAlpha
            local fadeStart = 0.80
            if progress >= fadeStart then
                alpha = fontAlpha * (1.0 - ((progress - fadeStart) / (1.0 - fadeStart)))
            end
            fs:SetAlpha(math.max(0, alpha))

        elseif isParabola then
            --------------------------------------------------------
            -- PARABOLA — deep half-moon arc
            --------------------------------------------------------
            -- Match MSBT's Parabola math:
            -- ScrollUp:  positionY = scrollHeight * progress
            -- ScrollDown:positionY = scrollHeight - scrollHeight * progress
            -- x = (y-mid)^2 / fourA, where fourA = (mid^2)/scrollWidth
            -- CurvedRight mirrors X: x = scrollWidth - x

            local positionY
            if dirMult > 0 then
                positionY = totalDistance * progress
            else
                positionY = totalDistance - (totalDistance * progress)
            end

            -- Convert positionY to anchor-relative offset for our SetPoint call.
            yOff2 = (totalDistance * progress) * dirMult

            local midPoint = totalDistance / 2
            local y = positionY - midPoint
            local fourA = (midPoint * midPoint) / math.max(1, areaW)
            local x = (y * y) / fourA

            local positionX
            if paraDir > 0 then
                -- CurvedRight
                positionX = areaW - x
            else
                -- CurvedLeft
                positionX = x
            end

            -- MSBT's parabola always operates in a left-origin coordinate space.
            -- To match CurvedLeft/CurvedRight semantics, we treat positionX as
            -- the literal offset from the LEFT edge and ignore the area's alignment.
            xOff2 = positionX

            local alpha = fontAlpha
            if progress > 0.30 then
                alpha = fontAlpha * (1.0 - ((progress - 0.30) / 0.70))
            end
            fs:SetAlpha(math.max(0, alpha))

        elseif isFireworks then
            --------------------------------------------------------
            -- FIREWORKS — scatter/bloom burst from an origin edge
            -- Each text gets a random spray vector (hemisphere) so
            -- bursts feel like a scatter shot rather than a line.
            --------------------------------------------------------
            local origin = fwOrigin
            if not origin then
                -- Backstop for any unexpected style strings
                if animStyle:find("Bottom") or animStyle:find("bottom") then origin = "Bottom" end
                if animStyle:find("Top") or animStyle:find("top") then origin = "Top" end
                if animStyle:find("Left") or animStyle:find("left") then origin = "Left" end
                if animStyle:find("Right") or animStyle:find("right") then origin = "Right" end
                if not origin then origin = "Bottom" end
            end

            local t = progress
            -- Ballistic feel: strong initial burst + gravity pullback
            local v = fwSpeed
            local g = 1.25
            local travel = t * v
            local gravity = (t * t) * g

            -- Main axis distance (fast start, slow end)
            local axis = travel - (0.55 * gravity)
            -- Lateral spread (bounded). Using sin avoids tan() blowups near 90deg.
            local side = math.sin(fwTheta) * travel
            -- Perp grows early for bloom, then stabilizes
            local perp = (travel * 0.90) * fwPerp

            if origin == "Bottom" then
                -- Launch upward
                yOff2 = (areaH * 0.80) * axis
                xOff2 = (areaW * 0.55) * side
                xOff2 = xOff2 + (areaW * 0.14) * perp
            elseif origin == "Top" then
                -- Launch downward
                yOff2 = -(areaH * 0.80) * axis
                xOff2 = (areaW * 0.55) * side
                xOff2 = xOff2 + (areaW * 0.14) * perp
            elseif origin == "Left" then
                -- Launch rightward
                xOff2 = (areaW * 0.80) * axis
                yOff2 = (areaH * 0.45) * side
                yOff2 = yOff2 + (areaH * 0.14) * perp
            elseif origin == "Right" then
                -- Launch leftward
                xOff2 = -(areaW * 0.80) * axis
                yOff2 = (areaH * 0.45) * side
                yOff2 = yOff2 + (areaH * 0.14) * perp
            end

            -- Keep sparks roughly within the scroll area region (no clipping frame).
            local maxX = areaW * 0.65
            local maxY = areaH * 0.95
            if xOff2 > maxX then xOff2 = maxX elseif xOff2 < -maxX then xOff2 = -maxX end
            if yOff2 > maxY then yOff2 = maxY elseif yOff2 < -maxY then yOff2 = -maxY end

            local alpha = fontAlpha
            if progress > 0.20 then
                alpha = fontAlpha * (1.0 - ((progress - 0.20) / 0.80))
            end
            fs:SetAlpha(math.max(0, alpha))

        elseif isWaterfall then
            --------------------------------------------------------
            -- WATERFALL — vertical flow with optional wavy/ripple feel
            -- Follows scroll area direction (dirMult).
            --------------------------------------------------------
            local t = progress
            local eased = t * (2.0 - t) -- OutQuad

            -- Primary vertical movement (follow scroll direction)
            yOff2 = (totalDistance * 0.95) * eased * dirMult

            local style = (area and area.waterfallStyle) or "Smooth"
            -- Backward compat: style strings might be stored lowercase
            if style == "smooth" then style = "Smooth" end
            if style == "wavy" then style = "Wavy" end
            if style == "ripple" then style = "Ripple" end
            if style == "turbulent" then style = "Turbulent" end

            local amp = areaW * 0.06
            local w1 = 2.8
            local w2 = 6.5
            local turb = 0
            if style == "Wavy" then
                amp = areaW * 0.10
                w1 = 2.0
                w2 = 4.0
            elseif style == "Ripple" then
                amp = areaW * 0.085
                w1 = 2.4
                w2 = 9.0
            elseif style == "Turbulent" then
                amp = areaW * 0.095
                w1 = 3.8
                w2 = 11.5
                turb = areaW * 0.025
            end

            local wave1 = math.sin((elapsed * w1) + wfPhase1)
            local wave2 = math.sin((elapsed * w2) + wfPhase2)
            xOff2 = (wave1 * amp) + (wave2 * (amp * 0.35))
            if turb > 0 then
                -- pseudo-noise: fast small oscillation keyed by wfNoise seed
                xOff2 = xOff2 + (math.sin((elapsed * 15.0) + (wfNoise * 10.0)) * turb)
            end

            local alpha = fontAlpha
            if progress > 0.30 then
                alpha = fontAlpha * (1.0 - ((progress - 0.30) / 0.70))
            end
            fs:SetAlpha(math.max(0, alpha))

        else
            --------------------------------------------------------
            -- STRAIGHT — clean vertical scroll, up or down
            --------------------------------------------------------

            -- OutQuad easing for smooth deceleration
            local eased = progress * (2.0 - progress)
            yOff2 = (totalDistance * 0.75) * eased * dirMult

            -- Fade: visible for first 50%, fade over last 50%
            local alpha = fontAlpha
            if progress > 0.5 then
                alpha = fontAlpha * (1.0 - ((progress - 0.5) / 0.5))
            end
            fs:SetAlpha(math.max(0, alpha))
        end

        fs:ClearAllPoints()
        if usePow then
            fs:SetPoint("CENTER", parent, "CENTER", xOff2, yOff2)
        else
            -- MSBT parabola anchors to the left edge (BottomLeft/TopLeft) regardless
            -- of the scroll area's alignment setting.
            local point = startPoint
            if isParabola then
                point = (dirMult > 0) and "BOTTOMLEFT" or "TOPLEFT"
            end
            -- MSBT Static uses bottom-anchored Y coordinates for stacking.
            if staticSlotY ~= nil then
                if anchorH == "LEFT" then
                    point = "BOTTOMLEFT"
                elseif anchorH == "RIGHT" then
                    point = "BOTTOMRIGHT"
                else
                    point = "BOTTOM"
                end
                fs:SetPoint(point, parent, point, 0, staticSlotY)
            else
                fs:SetPoint(point, parent, point, xOff2, slotOffset + yOff2)
            end
        end

        -- Edge fade: smoothly fade text near top/bottom of area.
        -- Text can go ~20% past the edge before fully invisible.
        local currentAlpha = fs:GetAlpha()
        local absY = math.abs(slotOffset + yOff2)
        local fadeStart = areaH * 0.75  -- start fading at 75% of area
        local fadeEnd = areaH * 1.2     -- fully invisible at 120% (slightly past edge)
        if absY > fadeStart then
            local edgeFade = 1.0 - math.min(1.0, (absY - fadeStart) / (fadeEnd - fadeStart))
            currentAlpha = currentAlpha * edgeFade
            fs:SetAlpha(math.max(0, currentAlpha))
        end

        -- Position icon to the left of text, matching alpha
        if iconTex then
            iconTex:ClearAllPoints()
            iconTex:SetPoint("RIGHT", fs, "LEFT", -2, 0)
            iconTex:SetAlpha(fs:GetAlpha())
        end
        if iconFS then
            iconFS:ClearAllPoints()
            iconFS:SetPoint("RIGHT", fs, "LEFT", -2, 0)
            iconFS:SetAlpha(fs:GetAlpha())
        end
    end)
end

