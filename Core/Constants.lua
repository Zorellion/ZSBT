------------------------------------------------------------------------
-- Zore's Scrolling Battle Text - Constants
-- Named constants used throughout the addon. No magic numbers.
------------------------------------------------------------------------

local ADDON_NAME, ZSBT = ...

------------------------------------------------------------------------
-- Version & Identity
------------------------------------------------------------------------
ZSBT.VERSION = "4.0.10"
ZSBT.ADDON_TITLE = "Zore's Scrolling Battle Text"
ZSBT.ADDON_SHORT = "ZSBT"
ZSBT.ADDON_AUTHOR = "Zorellion"
ZSBT.SLASH_PRIMARY = "/zsbt"

------------------------------------------------------------------------
-- Debug Levels
------------------------------------------------------------------------
ZSBT.DEBUG_LEVEL_NONE       = 0    -- Production mode
ZSBT.DEBUG_LEVEL_SUPPRESSED = 1    -- Show filtered/suppressed events
ZSBT.DEBUG_LEVEL_CONFIDENCE = 2    -- Show confidence scores
ZSBT.DEBUG_LEVEL_ALL_EVENTS = 3    -- Everything (verbose)
ZSBT.DEBUG_LEVEL_TRACE      = 4    -- High-signal tracing (OUTDBG/PETDBG)
ZSBT.DEBUG_LEVEL_CORRELATION = 5   -- Correlation tracing (chat -> outgoing -> icon)

------------------------------------------------------------------------
-- Confidence Thresholds
------------------------------------------------------------------------
ZSBT.CONFIDENCE_THRESHOLD_SOLO  = 0.6
ZSBT.CONFIDENCE_THRESHOLD_GROUP = 0.85

-- Confidence contribution factors
ZSBT.CONFIDENCE_DIRECT_CAST     = 0.7
ZSBT.CONFIDENCE_PET_OWNERSHIP   = 0.5
ZSBT.CONFIDENCE_ACTIVE_AURA     = 0.2
ZSBT.CONFIDENCE_AUTO_ATTACK     = 0.3

------------------------------------------------------------------------
-- Deduplication
------------------------------------------------------------------------
ZSBT.FINGERPRINT_HISTORY_SIZE = 30    -- Number of fingerprints to retain

------------------------------------------------------------------------
-- Diagnostics
------------------------------------------------------------------------
ZSBT.DIAG_MAX_ENTRIES = 1000          -- Max diagnostic log entries

------------------------------------------------------------------------
-- UI Dimensions
------------------------------------------------------------------------
ZSBT.CONFIG_WIDTH  = 900
ZSBT.CONFIG_HEIGHT = 820

------------------------------------------------------------------------
-- Slider Ranges
------------------------------------------------------------------------
ZSBT.FONT_SIZE_MIN = 8
ZSBT.FONT_SIZE_MAX = 32
ZSBT.ALPHA_MIN     = 0
ZSBT.ALPHA_MAX     = 1

ZSBT.SCROLL_OFFSET_MIN  = -3000
ZSBT.SCROLL_OFFSET_MAX  = 3000
ZSBT.SCROLL_WIDTH_MIN   = 20
ZSBT.SCROLL_WIDTH_MAX   = 800
ZSBT.SCROLL_HEIGHT_MIN  = 100
ZSBT.SCROLL_HEIGHT_MAX  = 600

ZSBT.MERGE_WINDOW_MIN = 0.5
ZSBT.MERGE_WINDOW_MAX = 5.0

------------------------------------------------------------------------
-- Damage School Indices (matches WoW API school masks)
------------------------------------------------------------------------
ZSBT.SCHOOL_PHYSICAL = 0x1
ZSBT.SCHOOL_HOLY     = 0x2
ZSBT.SCHOOL_FIRE     = 0x4
ZSBT.SCHOOL_NATURE   = 0x8
ZSBT.SCHOOL_FROST    = 0x10
ZSBT.SCHOOL_SHADOW   = 0x20
ZSBT.SCHOOL_ARCANE   = 0x40

------------------------------------------------------------------------
-- Color Scheme: "Strike Silver"
------------------------------------------------------------------------
ZSBT.COLORS = {
    -- Brand colors
    BRAND_GREEN   = { r = 0.00, g = 0.80, b = 0.40 },   -- #00CC66  (Zore's green)
    BRAND_GOLD    = { r = 1.00, g = 0.80, b = 0.20 },   -- #FFCC33  (accent gold)

    -- UI Chrome
    PRIMARY       = { r = 0.75, g = 0.75, b = 0.75 },   -- #C0C0C0
    PRIMARY_LIGHT = { r = 0.91, g = 0.91, b = 0.91 },   -- #E8E8E8
    ACCENT        = { r = 1.00, g = 0.82, b = 0.00 },   -- #FFD100  (Blizzard yellow)
    TAB_INACTIVE  = { r = 0.70, g = 0.73, b = 0.78 },   -- #B3BAC7  (softer inactive text)

    -- Backgrounds
    DARK          = { r = 0.08, g = 0.10, b = 0.14 },   -- #141A24  (deepened main bg)
    DARK_MID      = { r = 0.12, g = 0.15, b = 0.20 },   -- #1F2633  (section bg)
    DARK_LIGHT    = { r = 0.16, g = 0.20, b = 0.26 },   -- #293342  (hover/raised)

    -- Borders
    BORDER        = { r = 0.25, g = 0.30, b = 0.38 },   -- #404D61  (subtle dark border)
    BORDER_ACCENT = { r = 1.00, g = 0.82, b = 0.00 },   -- #FFD100  (yellow highlight border)

    -- Text
    TEXT_LIGHT    = { r = 0.92, g = 0.94, b = 0.96 },   -- #EBF0F5  (primary text)
    TEXT_DIM      = { r = 0.50, g = 0.55, b = 0.62 },   -- #808C9E  (secondary/desc text)
}

------------------------------------------------------------------------
-- Outline Styles (keys for dropdown, values for WoW fontstring flags)
------------------------------------------------------------------------
ZSBT.OUTLINE_STYLES = {
    ["None"]       = "",
    ["Thin"]       = "OUTLINE",
    ["Thick"]      = "THICKOUTLINE",
    ["Monochrome"] = "MONOCHROME",
}

------------------------------------------------------------------------
-- Animation Styles
------------------------------------------------------------------------
ZSBT.ANIMATION_STYLES = {
    ["Scroll"]           = "straight",
    ["Straight"]         = "straight",
    ["Parabola"]         = "parabola",
    ["Fireworks"]         = "fireworks",
    ["Waterfall"]        = "waterfall",
    ["Static"]           = "static",
    ["Pow"]              = "pow",
}

------------------------------------------------------------------------
-- Text Alignment
------------------------------------------------------------------------
ZSBT.TEXT_ALIGNMENTS = {
    ["Left"]   = "LEFT",
    ["Center"] = "CENTER",
    ["Right"]  = "RIGHT",
}

------------------------------------------------------------------------
-- Scroll Direction
------------------------------------------------------------------------
ZSBT.SCROLL_DIRECTIONS = {
    ["Up"]   = "UP",
    ["Down"] = "DOWN",
}

------------------------------------------------------------------------
-- Auto-Attack Display Modes
------------------------------------------------------------------------
ZSBT.AUTOATTACK_MODES = {
    ["Show All"]        = "all",
    ["Show Only Crits"] = "crits",
    ["Hide"]            = "hide",
}

------------------------------------------------------------------------
-- Pet Aggregation Styles
------------------------------------------------------------------------
ZSBT.PET_AGGREGATION = {
    ["Generic (\"Pet Hit X\")"]   = "generic",
    ["Attempt Pet Name"]          = "named",
    ["None (Numbers Only)"]       = "none",
    ["Spell Name"]                = "spell",
}

------------------------------------------------------------------------
-- WoW 12.0 Secret Value Safety
------------------------------------------------------------------------
-- Blizzard's secret-value test APIs (12.0+): issecretvalue() checks a single
-- value, issecrettable()/canaccesstable() cover secret Lua tables, and
-- canaccessvalue() reports whether THIS execution context may operate on the
-- value (restrictions are context-dependent: open world vs. dungeon/raid/PvP).
-- HasSecretValues() additionally detects secrets nested inside tables.
-- The pcall probes remain as a last resort for clients without these APIs.

-- Secret-value probes: hoisted so hot display paths can pcall() them
-- without allocating a fresh closure per call.
local function _secAdd0(v) return v + 0 end
local function _secEqEmpty(v) return v == "" end
local function _secRoundV(v) return v:round() end
local function _secFloorV(v) return v:floor() end
local function _secEq0(v) return v == 0 end

local function hasSecret(v)
    if v == nil then return false end
    if issecretvalue and issecretvalue(v) then return true end
    if issecrettable and type(v) == "table" and issecrettable(v) then return true end
    if HasSecretValues and HasSecretValues(v) then return true end
    -- Fallback for clients without the secret APIs: pcall probe.
    if type(v) == "number" then
        local ok = pcall(_secAdd0, v)
        return not ok
    end
    if type(v) == "string" then
        local ok = pcall(_secEqEmpty, v)
        return not ok
    end
    return false
end

-- True when the current (possibly tainted) execution context is allowed to
-- perform operations on v. False on old clients that lack the API — callers
-- should treat "unknown" conservatively.
function ZSBT.CanAccessValue(v)
    if v == nil then return true end
    if canaccessvalue then
        local ok, res = pcall(canaccessvalue, v)
        if ok and type(res) == "boolean" then return res end
    end
    return not hasSecret(v)
end

function ZSBT.IsSecret(v)
    return hasSecret(v)
end

function ZSBT.IsSafeNumber(v)
    if v == nil then return false end
    if type(v) ~= "number" then return false end
    return not hasSecret(v)
end

function ZSBT.IsSafeString(v)
    if v == nil then return false end
    if type(v) ~= "string" then return false end
    return not hasSecret(v)
end

-- Shared damage-school -> color lookup. Honors profile.media.schoolColors
-- when configured; composite masks resolve to a dominant school (cosmic/
-- chaos -> arcane, shadowflame -> shadow). Pure physical returns nil so
-- callers keep their neutral/white fallback.
function ZSBT.SchoolColorFromMask(mask)
    if not ZSBT.IsSafeNumber(mask) or mask <= 0 then return nil end
    local band = (bit and bit.band) or (bit32 and bit32.band)
    if type(band) ~= "function" then return nil end
    local colors = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.media
        and ZSBT.db.profile.media.schoolColors
    local function col(name, r, g, b)
        local c = colors and colors[name]
        if type(c) == "table" and type(c.r) == "number"
            and type(c.g) == "number" and type(c.b) == "number" then
            return { r = c.r, g = c.g, b = c.b }
        end
        return { r = r, g = g, b = b }
    end
    if band(mask, 64) ~= 0 then return col("arcane", 1.00, 0.50, 1.00) end
    if band(mask, 32) ~= 0 then return col("shadow", 0.60, 0.20, 1.00) end
    if band(mask, 16) ~= 0 then return col("frost",  0.40, 0.80, 1.00) end
    if band(mask, 8)  ~= 0 then return col("nature", 0.30, 1.00, 0.30) end
    if band(mask, 4)  ~= 0 then return col("fire",   1.00, 0.30, 0.00) end
    if band(mask, 2)  ~= 0 then return col("holy",   1.00, 0.90, 0.50) end
    return nil
end

-- "Midnight Proxy" pattern: re-fetch a CLEAN, UNTAINTED spell name
-- from the local game client cache using the spell ID.
function ZSBT.CleanSpellName(spellId)
    if not ZSBT.IsSafeNumber(spellId) then return nil end
    if C_Spell and C_Spell.GetSpellName then
        local name = C_Spell.GetSpellName(spellId)
        if type(name) == "string" and ZSBT.IsSafeString(name) and name ~= "" then
            return name
        end
    end
    if GetSpellInfo then
        local name = GetSpellInfo(spellId)
        if type(name) == "string" and ZSBT.IsSafeString(name) and name ~= "" then
            return name
        end
    end
    return nil
end

-- Resolve a display-ready amount.
-- Returns: displayText, isTainted
-- If we can't produce a clean number and there's no raw pipe,
-- returns nil so the event is skipped (no "Hit"/"Heal" labels).
function ZSBT.ResolveDisplayAmount(numericAmount, amountText, kind)
    -- Prefer clean numeric formatting when available.
    if ZSBT.IsSafeNumber(numericAmount) then
        if ZSBT.FormatDisplayAmount then
            return ZSBT.FormatDisplayAmount(numericAmount), false
        end

        return tostring(math.floor(numericAmount + 0.5)), false
    end
    -- amountText might be a clean string (from tostring on a safe number).
    if ZSBT.IsSafeString(amountText) then
        if type(amountText) == "string" then
            local cleaned = amountText:gsub(",", "")
            local n = tonumber(cleaned)
            if type(n) == "number" then
                if ZSBT.FormatDisplayAmount then
                    return ZSBT.FormatDisplayAmount(n), false
                end
                return tostring(math.floor(n + 0.5)), false
            end
        end
        return nil, false
    end
    -- Everything is tainted — return nil. Caller should use raw pipe
    -- or skip the event. No "Hit"/"Heal" fallback labels.
    return nil, true
end

-- Round a display-bound amount without breaking secret values.
-- Safe numbers round via math.floor. Retail secret numbers cannot do
-- arithmetic, but the secret userdata exposes :floor()/:round() — the
-- result stays secret so it can pass straight to SetText. Anything
-- without a usable round path is returned unchanged.
local _roundFS = nil
local function _roundDbg(src)
    local zb = ZSBT.ZBattleText
    if zb and zb.FileLog then zb:FileLog("RND src=" .. src) end
end
function ZSBT.RoundDisplayValue(v)
    if ZSBT.IsSafeNumber(v) then
        return math.floor(v + 0.5)
    end
    if v == nil then return nil end
    local sv = "n/a"
    if type(issecretvalue) == "function" then
        local okSV, isSV = pcall(issecretvalue, v)
        sv = okSV and tostring(isSV) or "err"
    end
    _roundDbg("in t=" .. tostring(type(v)) .. " sv=" .. sv)
    -- Safe strings pass through. Secret strings (KString) have
    -- type(v)=="string" too — they must fall through to the rounding
    -- attempts, otherwise a fractional secret string renders at full
    -- precision ("21222.2300").
    if type(v) == "string" then
        if not ZSBT.IsSafeString or ZSBT.IsSafeString(v) then return v end
    end
    local ok, r = pcall(_secRoundV, v)
    if ok and r ~= nil then _roundDbg("mround") return r end
    local ok2, r2 = pcall(_secFloorV, v)
    if ok2 and r2 ~= nil then _roundDbg("mfloor") return r2 end
    local okN, rN = pcall(math.floor, v)
    if okN and rN ~= nil then _roundDbg("luafloor") return rN end
    -- Secret number without math methods: format it C-side through a
    -- scratch FontString — SetFormattedText("%.0f", secret) evaluates
    -- where the real value is visible and GetText yields a displayable
    -- string. Retail secrets otherwise render floats at full precision.
    if CreateFrame then
        if _roundFS == nil then
            local f = CreateFrame("Frame")
            -- A font object is required or SetFormattedText can fail
            -- on some clients.
            _roundFS = (f and f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")) or false
        end
        if _roundFS then
            -- Split the pcalls: SetFormattedText evaluates the secret
            -- C-side; GetText may return a KString (still displayable).
            local okFmt = pcall(_roundFS.SetFormattedText, _roundFS, "%.0f", v)
            if okFmt then
                local okG, txt = pcall(_roundFS.GetText, _roundFS)
                if okG and txt ~= nil then
                    _roundDbg("fs t=" .. tostring(type(txt)))
                    return txt
                end
                _roundDbg("fsgetfail")
            else
                _roundDbg("fsfmtfail")
            end
        else
            _roundDbg("noframe")
        end
    else
        _roundDbg("nocreate")
    end
    _roundDbg("raw")
    return v
end

-- True only when an amount provably displays as zero. UNIT_COMBAT emits
-- absorb/blocked entries with amount == 0; the safe-number drop can't see
-- a secret's value, so evaluate it C-side through a scratch FontString
-- (same trick as RoundDisplayValue). A KString GetText or any failure
-- returns false — unproven amounts keep their display slot.
local _zeroFS = nil
local function scratchFS()
    if _zeroFS == nil then
        local f = CreateFrame and CreateFrame("Frame")
        _zeroFS = (f and f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")) or false
    end
    return _zeroFS or nil
end
-- C-side evaluate a possibly-secret amount into a displayable string via
-- SetFormattedText(fmt, v) -> GetText. Returns nil when evaluation fails;
-- the result may be a KString (still renderable by SetText).
function ZSBT.EvaluateDisplayAmount(v, fmt)
    local fs = scratchFS()
    if not fs then return nil end
    local okFmt = pcall(fs.SetFormattedText, fs, fmt or "%.0f", v)
    if not okFmt then return nil end
    local okG, txt = pcall(fs.GetText, fs)
    if okG then return txt end
    return nil
end
-- C-side formatted render of mixed safe/secret args through a scratch
-- FontString — SetFormattedText evaluates secrets where Lua cannot.
-- Returns the text (possibly a KString, still renderable by SetText)
-- or nil on evaluation failure.
function ZSBT.FormatDisplaySecret(fmt, ...)
    local fs = scratchFS()
    if not fs then return nil end
    local okFmt = pcall(fs.SetFormattedText, fs, fmt, ...)
    if not okFmt then return nil end
    local okG, txt = pcall(fs.GetText, fs)
    if okG then return txt end
    return nil
end

function ZSBT.DisplayAmountIsZero(v)
    if v == nil then return false end
    if ZSBT.IsSafeNumber(v) then return v == 0 end
    -- Direct comparison: secret-number == is forbidden in tainted
    -- contexts but cheap to probe.
    local okEq, eq = pcall(_secEq0, v)
    if okEq then return eq == true end
    local txt = ZSBT.EvaluateDisplayAmount(v, "%.0f")
    if ZSBT.IsSafeString(txt) then
        return txt == "0" or txt == "-0"
    end
    -- KString result: C-side string compare may evaluate secrets where
    -- Lua equality cannot.
    if txt ~= nil and type(strcmputf8i) == "function" then
        local okA, rA = pcall(strcmputf8i, txt, "0")
        if okA and rA == 0 then return true end
        local okB, rB = pcall(strcmputf8i, txt, "-0")
        if okB and rB == 0 then return true end
    end
    return false
end

ZSBT.NUMBER_FORMATS = {
    none = "None",
    short1 = "Short (K/M/B, 1 decimal)",
    short2 = "Short (K/M/B, 2 decimals)",
    short0 = "Short (K/M/B, no decimals)",
    shortK = "Thousands (K, 1 decimals)",
    sig3 = "Significant digits (3)",
}

function ZSBT.FormatDisplayAmount(n)
    if not ZSBT.IsSafeNumber(n) then
        return nil
    end

    local prof = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.general
    local mode = (prof and prof.numberFormat) or "none"
    mode = tostring(mode or "none")

    local function roundInt(x)
        return math.floor(x + 0.5)
    end

    if mode == "none" then
        return tostring(roundInt(n))
    end

    local absN = math.abs(n)
    local sign = (n < 0) and "-" or ""

    local function fmtShort(value, decimals, suffix)
        if decimals <= 0 then
            return sign .. tostring(roundInt(value)) .. suffix
        end
        local s = string.format("%s%0." .. tostring(decimals) .. "f%s", sign, value, suffix)
        s = s:gsub("(%..-)0+([KMBT])$", "%1%2")
        s = s:gsub("%.([KMBT])$", "%1")
        return s
    end

    local function short(decimals)
        if absN >= 1e12 then
            return fmtShort(absN / 1e12, decimals, "T")
        elseif absN >= 1e9 then
            return fmtShort(absN / 1e9, decimals, "B")
        elseif absN >= 1e6 then
            return fmtShort(absN / 1e6, decimals, "M")
        elseif absN >= 1e3 then
            return fmtShort(absN / 1e3, decimals, "K")
        else
            return tostring(roundInt(n))
        end
    end

    if mode == "short0" then
        return short(0)
    elseif mode == "short1" then
        return short(1)
    elseif mode == "short2" then
        return short(2)
    elseif mode == "shortK" then
        local value = absN / 1000
        local s = string.format("%s%.1fK", sign, value)
        s = s:gsub("%.0K$", "K")
        return s
    elseif mode == "sig3" then
        if absN < 1000 then
            return tostring(roundInt(n))
        end
        local exp = math.floor(math.log10(absN))
        local scaled = absN / (10 ^ (exp - 2))
        local rounded = roundInt(scaled)
        local sig = rounded * (10 ^ (exp - 2))
        local out = sig
        if absN >= 1e12 then
            out = sig / 1e12
            return fmtShort(out, 2, "T")
        elseif absN >= 1e9 then
            out = sig / 1e9
            return fmtShort(out, 2, "B")
        elseif absN >= 1e6 then
            out = sig / 1e6
            return fmtShort(out, 2, "M")
        else
            out = sig / 1e3
            return fmtShort(out, 2, "K")
        end
    end

    return tostring(roundInt(n))
end

-- Fetch the spell icon texture path for a given spell ID.
-- Tries multiple APIs for Midnight compatibility.
function ZSBT.CleanSpellIcon(spellId)
    if not ZSBT.IsSafeNumber(spellId) then return nil end

    -- Try C_Spell.GetSpellTexture (Midnight primary)
    if C_Spell and C_Spell.GetSpellTexture then
        local tex = C_Spell.GetSpellTexture(spellId)
        if tex then return tex end
    end

    -- Try GetSpellTexture (legacy)
    if GetSpellTexture then
        local tex = GetSpellTexture(spellId)
        if tex then return tex end
    end

    -- Try C_Spell.GetSpellInfo -> iconID
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellId)
        if info and info.iconID then return info.iconID end
    end

    return nil
end

------------------------------------------------------------------------
-- Secret Value Visual Filtering (Midnight-safe)
--
-- In dungeons/raids, damage values are "secret" — we can't do math.
-- This uses Blizzard's visual evaluation APIs to filter without taint:
--   1. C_CurveUtil — native curve evaluation on secret values
--   2. StatusBar trick — visual fill state comparison
--   3. Fallback — show everything (no filtering in dungeons)
------------------------------------------------------------------------

-- Reusable hidden StatusBar for threshold evaluation
local thresholdBar = nil

local function GetThresholdBar()
    if not thresholdBar then
        thresholdBar = CreateFrame("StatusBar", nil, UIParent)
        thresholdBar:SetSize(1, 1)
        thresholdBar:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -100, -100)
        thresholdBar:Hide()
        -- Create a fill texture we can measure
        local fill = thresholdBar:CreateTexture(nil, "OVERLAY")
        fill:SetColorTexture(1, 1, 1, 1)
        thresholdBar:SetStatusBarTexture(fill)
    end
    return thresholdBar
end

-- Evaluate whether a secret value passes a threshold.
-- Returns an alpha multiplier: 0 = hide, 1 = show.
-- Safe to call on both clean and tainted values.
function ZSBT.EvaluateSecretThreshold(secretValue, threshold)
    if not threshold or threshold <= 0 then return 1.0 end
    if secretValue == nil then return 1.0 end

    -- If value is clean (open world), just compare directly
    if ZSBT.IsSafeNumber(secretValue) then
        if secretValue < threshold then return 0 end
        return 1.0
    end

    -- Value is tainted (dungeon/raid) — try Midnight-safe visual eval

    -- Approach 1: C_CurveUtil (Midnight native curve evaluation)
    -- Evaluates a piecewise curve against a secret value, returns clean result
    if C_CurveUtil and C_CurveUtil.GetCurveValueAtPoint then
        local ok, alpha = pcall(function()
            -- Step curve: 0 below threshold, 1 at/above
            return C_CurveUtil.GetCurveValueAtPoint(secretValue, {
                { x = 0, y = 0 },
                { x = threshold - 1, y = 0 },
                { x = threshold, y = 1 },
            })
        end)
        if ok and type(alpha) == "number" then return alpha end
    end

    -- Approach 1b: Try alternate C_CurveUtil signatures
    if C_CurveUtil then
        -- Try EvaluateCurve
        local ok, alpha = pcall(function()
            if C_CurveUtil.EvaluateCurve then
                return C_CurveUtil.EvaluateCurve(secretValue, threshold)
            end
        end)
        if ok and type(alpha) == "number" then return alpha end

        -- Try GetValue
        local ok2, alpha2 = pcall(function()
            if C_CurveUtil.GetValue then
                return C_CurveUtil.GetValue(secretValue, threshold)
            end
        end)
        if ok2 and type(alpha2) == "number" then return alpha2 end
    end

    -- Approach 2: StatusBar visual fill evaluation
    -- Set threshold as max, secret as value. If fill < 100%, value < threshold.
    local bar = GetThresholdBar()
    local ok3, result = pcall(function()
        bar:SetMinMaxValues(0, threshold)
        bar:SetValue(secretValue)
        -- GetStatusBarValues returns current, min, max as potentially clean values
        local cur = bar:GetValue()
        if cur and ZSBT.IsSafeNumber(cur) then
            return cur >= threshold and 1.0 or 0
        end
        return nil
    end)
    if ok3 and type(result) == "number" then return result end

    -- Fallback: can't evaluate in dungeon, show everything
    return 1.0
end

------------------------------------------------------------------------
-- Class-Colored Name
-- Wraps a unit name in its class color escape sequence.
-- Returns the colored string, or plain name if class can't be determined.
------------------------------------------------------------------------
function ZSBT.ClassColorName(name, unit)
    if not name or not ZSBT.IsSafeString(name) then return name end
    if not unit then return name end

    -- pcall(UnitClass, unit) returns: ok, localizedName, className
    local ok, _, className = pcall(UnitClass, unit)
    if not ok or not className or not ZSBT.IsSafeString(className) then return name end

    local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[className]
    if classColor and classColor.colorStr then
        return "|c" .. classColor.colorStr .. name .. "|r"
    end
    return name
end

------------------------------------------------------------------------
-- Training Dummy Detection
-- Checks if a unit is a training dummy by NPC ID from its GUID.
-- Common dummy NPC IDs across expansions.
------------------------------------------------------------------------
local TRAINING_DUMMY_NPCS = {
    -- Stormwind / Orgrimmar
    [31146] = true, [31144] = true, [32666] = true, [32667] = true,
    [46647] = true, [67127] = true, [153285] = true, [153292] = true,
    -- Garrison / Class Hall
    [87317] = true, [87318] = true, [87320] = true, [87321] = true,
    [87322] = true, [87329] = true, [87762] = true, [88288] = true,
    [88314] = true, [88836] = true, [89078] = true,
    -- BfA / Shadowlands / Dragonflight
    [144078] = true, [144080] = true, [144081] = true, [144082] = true,
    [164653] = true, [189617] = true, [189632] = true, [194643] = true,
    [194644] = true, [194648] = true, [194649] = true,
    -- TWW / Midnight
    [198594] = true, [199052] = true, [220242] = true, [225983] = true,
    [225984] = true, [225985] = true,
}

-- Cache: avoid per-event pcall overhead
local _dummyCache = { guid = nil, isDummy = false }

function ZSBT.IsTrainingDummy(unit)
    if not unit then return false end
    local ok, guid = pcall(UnitGUID, unit)
    if not ok or not guid or not ZSBT.IsSafeString(guid) then return false end

    -- Return cached result if same target
    if guid == _dummyCache.guid then return _dummyCache.isDummy end

    -- GUID format: "Creature-0-XXXX-XXXX-XXXX-NPCID-XXXXXXXX"
    local npcId = tonumber(guid:match("Creature%-.-%-.-%-.-%-.-%-(%d+)%-"))
    local result = false
    if npcId and TRAINING_DUMMY_NPCS[npcId] then
        result = true
    else
        -- Fallback: check unit name for "Training Dummy" or "Dungeoneer"
        local ok2, name = pcall(UnitName, unit)
        if ok2 and name and ZSBT.IsSafeString(name) then
            if name:find("Training Dummy") or name:find("Dungeoneer") then
                result = true
            end
        end
    end

    _dummyCache.guid = guid
    _dummyCache.isDummy = result
    return result
end

------------------------------------------------------------------------
-- Miss subtype normalization (ZCT parity). evt.action / missType arrive
-- as UNIT_COMBAT tokens (DODGE, SPELL_MISS, SWING_DODGED...) or display
-- words ("Dodge"). Reduce to the canonical subtype used by the
-- misses.hidden config table; nil = unknown (never hidden — fail open).
------------------------------------------------------------------------
ZSBT.MISS_SUBTYPES = { "DODGE", "MISS", "PARRY", "BLOCK", "RESIST",
    "ABSORB", "EVADE", "IMMUNE", "REFLECT", "DEFLECT" }

function ZSBT.NormalizeMissSubtype(s)
    if type(s) ~= "string" or s == "" then return nil end
    local u = s:upper():gsub("MISSED$", "MISS")
        :gsub("DODGED$", "DODGE"):gsub("PARRIED$", "PARRY")
    for _, k in ipairs(ZSBT.MISS_SUBTYPES) do
        local n = #k
        if u == k or (u:sub(-n) == k and u:sub(-n - 1, -n - 1) == "_") then
            return k
        end
    end
    return nil
end
