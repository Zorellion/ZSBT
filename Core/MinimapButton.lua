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

local LDB_NAME = "ZSBT"

-- Minimap icon
-- Note: If a texture path fails to load, WoW can render the texture region as solid white.
-- We defensively choose the bundled icon only if it exists and otherwise fall back.
local BUNDLED_ICON_TEXTURE = "Interface\\AddOns\\ZSBT\\Media\\Textures\\ZSBT_Icon.tga"
local FALLBACK_ICON_TEXTURE = "Interface\\Buttons\\UI-OptionsButton"

local function pickIconPath()
	return BUNDLED_ICON_TEXTURE
end

-- Blizzard-style round minimap button art
local BORDER_TEXTURE = "Interface\\Minimap\\MiniMap-TrackingBorder"
local HIGHLIGHT_TEXTURE = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

function MM:UpdateVisibility()
	if not ZSBT.db or not ZSBT.db.profile or not ZSBT.db.profile.general then return end
	local g = ZSBT.db.profile.general
	g.minimap = g.minimap or {}
	local dbicon = self._dbicon
	if not dbicon or not dbicon.IsRegistered or not dbicon:IsRegistered(LDB_NAME) then
		return
	end
	if g.minimap.hide then
		pcall(dbicon.Hide, dbicon, LDB_NAME)
	else
		pcall(dbicon.Show, dbicon, LDB_NAME)
	end
end

function MM:SetHidden(hidden)
    if not ZSBT.db then return end
    ZSBT.db.profile.general.minimap.hide = hidden and true or false
    self:UpdateVisibility()
end

function MM:Init()
    if self._dbicon then
        self:UpdateVisibility()
        return
    end

    if not ZSBT.db or not ZSBT.db.profile or not ZSBT.db.profile.general then return end

    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not (LDB and DBIcon) then
        return
    end

    local g = ZSBT.db.profile.general
    g.minimap = g.minimap or {}
    if type(g.minimap.hide) ~= "boolean" then g.minimap.hide = false end

    if type(g.minimap.minimapPos) ~= "number" then
        if type(g.minimap.angle) == "number" then
            g.minimap.minimapPos = g.minimap.angle
        else
            g.minimap.minimapPos = 220
        end
    end
    g.minimap.angle = g.minimap.minimapPos

    if _G and _G["ZSBT_MinimapButton"] then
        local legacy = _G["ZSBT_MinimapButton"]
        pcall(function()
            if legacy.UnregisterAllEvents then legacy:UnregisterAllEvents() end
            legacy:Hide()
            legacy:SetScript("OnShow", nil)
            legacy:SetScript("OnEnter", nil)
            legacy:SetScript("OnLeave", nil)
        end)
    end

    local function tooltipLines(tt)
        if not tt or not tt.AddLine then return end
        tt:AddLine("|cFF00CC66Zore's|r Scrolling Battle Text", 1, 1, 1)
        tt:AddLine("|cFF808C9Ev" .. (ZSBT.VERSION or "1.0") .. "|r")
        tt:AddLine(" ")
        tt:AddLine("Left-Click:", 0.9, 0.9, 0.9)
        tt:AddLine("  Open configuration", 1, 1, 1)
        tt:AddLine("Right-Click:", 0.9, 0.9, 0.9)
        tt:AddLine("  Close configuration", 1, 1, 1)
        tt:AddLine("Middle-Click:", 0.9, 0.9, 0.9)
        tt:AddLine("  Toggle Enable ZSBT", 1, 1, 1)
    end

    local ldbObj = LDB:NewDataObject(LDB_NAME, {
        type = "launcher",
        text = "ZSBT",
        icon = pickIconPath(),
        OnClick = function(_, btn)
            local gg = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
            if not gg then return end

            if btn == "LeftButton" then
                if Addon and Addon.OpenConfig then
                    Addon:OpenConfig()
                end
                return
            end
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
            if btn == "MiddleButton" then
                gg.enabled = not gg.enabled
                if ZSBT.Core and ZSBT.Core.Enable and ZSBT.Core.Disable then
                    if gg.enabled then
                        ZSBT.Core:Enable()
                    else
                        ZSBT.Core:Disable()
                    end
                end
            end
        end,
        OnTooltipShow = function(tt)
            tooltipLines(tt)
        end,
    })

    self._ldb = ldbObj
    self._dbicon = DBIcon

    pcall(function()
        if DBIcon.Register then
            DBIcon:Register(LDB_NAME, ldbObj, g.minimap)
        end
    end)

    self:UpdateVisibility()
end
