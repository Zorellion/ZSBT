------------------------------------------------------------------------
-- ZSBT - Minimap Button (simple native implementation, no LDB)
-- Left Click:  Open config
-- Right Click: Close config (if open)
-- Middle Click: Toggle ZSBT enabled/disabled
-- Drag (Left): Move around minimap ring
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...

ZSBT.Core = ZSBT.Core or {}
ZSBT.Core.Minimap = ZSBT.Core.Minimap or {}
local MM = ZSBT.Core.Minimap
local Addon = ZSBT.Addon

local BUTTON_NAME = "ZSBT_MinimapButton"

-- Minimap icon
-- Note: If a texture path fails to load, WoW can render the texture region as solid white.
-- We defensively choose the bundled icon only if it exists and otherwise fall back.
local BUNDLED_ICON_TEXTURE = "Interface\\AddOns\\ZSBT\\Media\\Textures\\ZSBT_Icon.tga"
local FALLBACK_ICON_TEXTURE = "Interface\\Buttons\\UI-OptionsButton"

local function applyIconTexture(tex)
	if not tex or not tex.SetTexture then return end
	pcall(tex.SetTexture, tex, BUNDLED_ICON_TEXTURE)
	local okId, fileId = pcall(function()
		if tex.GetTextureFileID then
			return tex:GetTextureFileID()
		end
		return nil
	end)
	if okId and type(fileId) == "number" and fileId > 0 then
		return
	end
	local okGet, cur = pcall(tex.GetTexture, tex)
	if (not okGet) or cur == nil or cur == "" then
		pcall(tex.SetTexture, tex, FALLBACK_ICON_TEXTURE)
		return
	end
	if tostring(cur) == tostring(BUNDLED_ICON_TEXTURE) then
		-- Some clients keep the path even if the texture failed to resolve.
		-- Use the fallback to guarantee a visible icon.
		pcall(tex.SetTexture, tex, FALLBACK_ICON_TEXTURE)
	end
end

-- Blizzard-style round minimap button art
local BORDER_TEXTURE = "Interface\\Minimap\\MiniMap-TrackingBorder"
local HIGHLIGHT_TEXTURE = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local DEFAULT_RADIUS = 80

local ICON_SIZE = 18
local ICON_OFFSET_X = 0
local ICON_OFFSET_Y = 0
local ICON_TEXCOORD_L = 0.07
local ICON_TEXCOORD_R = 0.93
local ICON_TEXCOORD_T = 0.07
local ICON_TEXCOORD_B = 0.93

local function getRadius(button)
    if Minimap and Minimap.GetWidth and Minimap.GetHeight and button and button.GetWidth then
        local w = Minimap:GetWidth() or 140
        local h = Minimap:GetHeight() or 140
        local mmR = math.min(w, h) / 2
        local bR = (button:GetWidth() or 24) / 2
        local pad = 2
        return mmR + bR - pad
    end
    return DEFAULT_RADIUS
end

local function clampAngle(a)
    if a == nil then return 220 end
    a = a % 360
    if a < 0 then a = a + 360 end
    return a
end

local function angleToXY(angle, radius)
    local rad = math.rad(angle)
    local r = radius or DEFAULT_RADIUS
    local x = math.cos(rad) * r
    local y = math.sin(rad) * r
    return x, y
end

local function resolveButton(self)
    if self and self.button then
        return self.button
    end
    local b = _G and _G[BUTTON_NAME]
    if self and b then
        self.button = b
    end
    return b
end

local function applyExternalMinimapButtonsHidden(hidden)
    if not _G then return end
    for k, v in pairs(_G) do
        if type(k) == "string" and k ~= BUTTON_NAME and k:find("ZSBT_MinimapButton", 1, true) then
            if type(v) == "table" or type(v) == "userdata" then
                local okHide = (v.Hide and v.Show)
                if okHide then
                    if hidden then
                        if v.SetAlpha then v:SetAlpha(0) end
                        v:Hide()
                    else
                        if v.SetAlpha then v:SetAlpha(1) end
                        v:Show()
                    end
                end
            end
        end
    end
end

local function cursorAngleFromMinimap()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale

    local dx = cx - mx
    local dy = cy - my
    local angle = math.deg(math.atan2(dy, dx))
    return clampAngle(angle)
end

function MM:ApplyPosition()
    local b = resolveButton(self)
    if not b or not ZSBT.db then return end

    local angle = clampAngle(ZSBT.db.profile.general.minimap.angle)
    local x, y = angleToXY(angle, getRadius(b))

    -- Critical: clear points first to avoid anchor-family conflicts.
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function MM:UpdateVisibility()
    local b = resolveButton(self)
    if not b or not ZSBT.db then return end
    if ZSBT.db.profile.general.minimap.hide then
        if b.SetAlpha then b:SetAlpha(0) end
        b:Hide()
		applyExternalMinimapButtonsHidden(true)
		if C_Timer and C_Timer.After then
			C_Timer.After(0, function()
				local bb = resolveButton(self)
				if bb and ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					and ZSBT.db.profile.general.minimap
					and ZSBT.db.profile.general.minimap.hide then
					if bb.SetAlpha then bb:SetAlpha(0) end
					bb:Hide()
					applyExternalMinimapButtonsHidden(true)
				end
			end)
		end
    else
        if b.SetAlpha then b:SetAlpha(1) end
        b:Show()
		applyExternalMinimapButtonsHidden(false)
		-- Apply position on next frame as well; certain UI refreshes can occur
		-- in the same tick as Show() and briefly misalign the textures/anchor.
		self:ApplyPosition()
		if C_Timer and C_Timer.After then
			C_Timer.After(0, function()
				if ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					and ZSBT.db.profile.general.minimap
					and not ZSBT.db.profile.general.minimap.hide then
					self:ApplyPosition()
				end
			end)
		end
    end
end

function MM:SetHidden(hidden)
    if not ZSBT.db then return end
    ZSBT.db.profile.general.minimap.hide = hidden and true or false
    self:UpdateVisibility()
end

function MM:Init()
    if self.button then
        self:UpdateVisibility()
        return
    end

    if not Minimap or not ZSBT.db or not ZSBT.db.profile or not ZSBT.db.profile.general then return end

    local b = CreateFrame("Button", BUTTON_NAME, Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)

    local function pickIconTexture()
        return BUNDLED_ICON_TEXTURE
    end

    local function addCircleMask(tex)
        if true then
            return nil
        end
        if not tex or not tex.AddMaskTexture or not b.CreateMaskTexture then return nil end
        local mask = b:CreateMaskTexture()
        mask:SetTexture(CIRCLE_MASK)
        mask:SetAllPoints(tex)
        tex:AddMaskTexture(mask)
        b._masks = b._masks or {}
        b._masks[#b._masks + 1] = mask
        return mask
    end

    -- Icon (gear) - circular masked
    local icon = b:CreateTexture(nil, "ARTWORK")
    if icon.SetBlendMode then icon:SetBlendMode("BLEND") end
    if icon.SetDesaturated then icon:SetDesaturated(false) end
    icon:SetTexture(pickIconTexture())
    applyIconTexture(icon)
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("CENTER", b, "CENTER", ICON_OFFSET_X, ICON_OFFSET_Y)
    icon:SetTexCoord(ICON_TEXCOORD_L, ICON_TEXCOORD_R, ICON_TEXCOORD_T, ICON_TEXCOORD_B)
    b.icon = icon

    addCircleMask(icon)

    -- Gold ring border
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetTexture(BORDER_TEXTURE)
    border:SetSize(54, 54)
    border:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.border = border

    -- Highlight / pushed feedback
    b:SetHighlightTexture(HIGHLIGHT_TEXTURE, "ADD")
    local hl = b:GetHighlightTexture()
    if hl then
        hl:SetTexCoord(0, 1, 0, 1)
        hl:SetAllPoints(border)
    end

    local pushed = b:CreateTexture(nil, "ARTWORK")
    if pushed.SetBlendMode then pushed:SetBlendMode("BLEND") end
    if pushed.SetDesaturated then pushed:SetDesaturated(false) end
    pushed:SetTexture(pickIconTexture())
    applyIconTexture(pushed)
    pushed:SetSize(ICON_SIZE, ICON_SIZE)
    pushed:SetPoint("CENTER", b, "CENTER", ICON_OFFSET_X + 1, ICON_OFFSET_Y - 1)
    pushed:SetTexCoord(ICON_TEXCOORD_L, ICON_TEXCOORD_R, ICON_TEXCOORD_T, ICON_TEXCOORD_B)

    addCircleMask(pushed)
    b:SetPushedTexture(pushed)

    b:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    b:RegisterForDrag("LeftButton")

	-- Enforce hide in real time: if anything re-shows the button while the
	-- profile says it should be hidden, immediately hide it again.
	b:HookScript("OnShow", function()
		if ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
			and ZSBT.db.profile.general.minimap
			and ZSBT.db.profile.general.minimap.hide then
			if b.SetAlpha then b:SetAlpha(0) end
			b:Hide()
			applyExternalMinimapButtonsHidden(true)
			return
		end
		if b.SetAlpha then b:SetAlpha(1) end
		applyExternalMinimapButtonsHidden(false)
		if C_Timer and C_Timer.After then
			C_Timer.After(0, function()
				if ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
					and ZSBT.db.profile.general.minimap
					and not ZSBT.db.profile.general.minimap.hide then
					MM:ApplyPosition()
				end
			end)
		end
	end)

    --------------------------------------------------------------------
    -- Tooltip (attach ONCE; not inside OnClick)
    --------------------------------------------------------------------
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:ClearLines()

        GameTooltip:AddLine("|cFF00CC66Zore's|r Scrolling Battle Text", 1, 1, 1)
        GameTooltip:AddLine("|cFF808C9Ev" .. (ZSBT.VERSION or "1.0") .. "|r")
        GameTooltip:AddLine(" ")

        GameTooltip:AddLine("Left-Click:", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("  Open configuration", 1, 1, 1)

        GameTooltip:AddLine("Right-Click:", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("  Close configuration", 1, 1, 1)

        GameTooltip:AddLine("Middle-Click:", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("  Toggle Enable ZSBT", 1, 1, 1)

        GameTooltip:Show()
    end)

    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    --------------------------------------------------------------------
    -- Dragging: constrained to minimap ring (no StartMoving)
    --------------------------------------------------------------------
    b:SetScript("OnDragStart", function(self)
        self.isDragging = true
        self:SetScript("OnUpdate", function()
            local angle = cursorAngleFromMinimap()
            ZSBT.db.profile.general.minimap.angle = angle
            MM:ApplyPosition()
        end)
    end)

    b:SetScript("OnDragStop", function(self)
        self.isDragging = false
        self:SetScript("OnUpdate", nil)
        -- position already saved continuously
    end)

    --------------------------------------------------------------------
    -- Click behavior
    --------------------------------------------------------------------
    b:SetScript("OnClick", function(_, btn)
        local g = ZSBT.db.profile.general

        -- Left click: open config
        if btn == "LeftButton" then
            if Addon and Addon.OpenConfig then
                Addon:OpenConfig()
            end
            return
        end

        -- Right click: close config (if open)
        if btn == "RightButton" then
            if Addon and Addon.configDialog then
                local frame = Addon.configDialog.OpenFrames
                    and Addon.configDialog.OpenFrames["ZSBT"]

                if frame and frame.frame then
                    frame.frame.zsbtAllowClose = true
                    frame.frame:Hide()
                    frame.frame.zsbtAllowClose = false
                end
            end
            return
        end

        -- Middle click: toggle addon enabled/disabled
        if btn == "MiddleButton" then
            g.enabled = not g.enabled

            if ZSBT.Core and ZSBT.Core.Enable and ZSBT.Core.Disable then
                if g.enabled then
                    ZSBT.Core:Enable()
                else
                    ZSBT.Core:Disable()
                end
            end

            if Addon and Addon.Print then
                Addon:Print(("ZSBT %s."):format(g.enabled and "enabled" or "disabled"))
            end

            -- Refresh config UI if it's open so checkbox updates immediately.
            local ACR = LibStub("AceConfigRegistry-3.0", true)
            if ACR then
                ACR:NotifyChange("ZSBT")
            end

            return
        end
    end)

    self.button = b
    self:UpdateVisibility()
end
