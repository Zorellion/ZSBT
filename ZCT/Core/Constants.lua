------------------------------------------------------------------------
-- Zore's Combat Text - Constants
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
ZSBT.ZCT = ZSBT.ZCT or {}
local ZCT = ZSBT.ZCT

ZCT = ZCT or {}
ZCT.VERSION = "0.1.0"
ZCT.ADDON_NAME = ADDON_NAME

------------------------------------------------------------------------
-- Color-coded combat-log filter
------------------------------------------------------------------------
-- The "ZCT" filter is written into Blizzard_CombatLog_Filters at
-- PLAYER_LOGOUT (secure processor rule) and activated via currentFilter.
-- lineColoring gives each combat-log event a unique RGB; LogLines.lua
-- classifies COMBAT_LOG_MESSAGE lines by matching that palette. Never
-- parse the message text — it is a sealed KString.

ZCT.FILTER_NAME = "ZSBT"

-- Palette: one distinct RGB per event kind. Values are written into the
-- filter's eventColoring and matched with a tolerance (colors may be
-- gamma-adjusted). Keep hues far apart.
ZCT.KIND_COLORS = {
    direct    = { 0.95, 0.55, 0.15 },  -- orange
    tick      = { 0.65, 0.45, 1.00 },  -- violet
    melee     = { 0.90, 0.90, 0.90 },  -- light grey
    ranged    = { 0.80, 0.60, 0.40 },  -- tan
    directMiss= { 0.60, 0.65, 0.80 },  -- blue-grey
    tickMiss  = { 0.65, 0.55, 0.80 },  -- muted violet
    meleeMiss = { 0.60, 0.60, 0.60 },  -- grey
    rangedMiss= { 0.65, 0.60, 0.50 },  -- brown-grey
    heal      = { 0.40, 1.00, 0.50 },  -- green
    hot       = { 0.50, 0.85, 0.60 },  -- light green
    shield    = { 1.00, 0.60, 0.25 },  -- amber
    shieldMiss= { 0.72, 0.58, 0.45 },  -- dull amber
    -- Log-only kinds (incoming utility/reactive events). Never in the
    -- outgoing pairing kind sets, so lines of these can't be claimed
    -- as hits. Ported from the legacy ZSBT palette.
    interrupt = { 1.00, 0.45, 0.10 },  -- red-orange
    purge     = { 0.30, 0.85, 1.00 },  -- cyan-blue
    cleanse   = { 0.40, 0.95, 0.80 },  -- teal
    steal     = { 0.60, 0.80, 1.00 },  -- light blue
    dispelFailed = { 0.55, 0.72, 0.82 }, -- grey-blue
    broke     = { 1.00, 0.35, 0.35 },  -- red
    kill      = { 1.00, 1.00, 1.00 },  -- white
    extra     = { 0.15, 0.85, 0.85 },  -- cyan
}

-- Combat-log event name -> kind. *_MISSED suffixes are expanded at load.
local EVENT_KINDS = {
    -- direct damage
    SPELL_DAMAGE          = "direct",
    SPELL_LEECH           = "direct",
    SPELL_DRAIN           = "direct",
    SPELL_BUILDING_DAMAGE = "direct",
    -- periodic damage
    SPELL_PERIODIC_DAMAGE = "tick",
    SPELL_PERIODIC_LEECH  = "tick",
    SPELL_PERIODIC_DRAIN  = "tick",
    -- melee / ranged / shield
    SWING_DAMAGE          = "melee",
    RANGE_DAMAGE          = "ranged",
    DAMAGE_SHIELD         = "shield",
    DAMAGE_SPLIT          = "direct",
    ENVIRONMENTAL_DAMAGE  = "direct",
    -- heals
    SPELL_HEAL            = "heal",
    SPELL_BUILDING_HEAL   = "heal",
    SPELL_PERIODIC_HEAL   = "hot",
    -- base miss events (suffixes added below)
    SPELL_MISSED          = "directMiss",
    SPELL_PERIODIC_MISSED = "tickMiss",
    SWING_MISSED          = "meleeMiss",
    RANGE_MISSED          = "rangedMiss",
    DAMAGE_SHIELD_MISSED  = "shieldMiss",
}

local MISS_TYPES = {
    "ABSORB", "BLOCK", "DEFLECT", "DODGE", "EVADE", "IMMUNE",
    "MISS", "PARRY", "REFLECT", "RESIST",
}
for _, prefix in ipairs({ "SPELL", "SPELL_PERIODIC", "SWING", "RANGE", "DAMAGE_SHIELD" }) do
    local kind = EVENT_KINDS[prefix .. "_MISSED"]
    if kind then
        for _, miss in ipairs(MISS_TYPES) do
            EVENT_KINDS[prefix .. "_MISSED_" .. miss] = kind
        end
    end
end
ZCT.EVENT_KINDS = EVENT_KINDS

------------------------------------------------------------------------
-- Log-only events: incoming utility/reactive combat (interrupts, dispels,
-- steals, aura breaks, kills, extra attacks). These ride the filter's
-- destination-restricted part and get palette colors, but their kinds are
-- never in the outgoing pairing sets — a classified line of these can
-- never be claimed as a hit. Direction is still ambiguous per line (the
-- API gives one color per event), which is fine: nothing pairs on them.
------------------------------------------------------------------------
local LOG_EVENT_KINDS = {
    SPELL_INTERRUPT = "interrupt",
    SPELL_DISPEL = "purge",
    SPELL_DISPEL_BUFF = "purge",
    SPELL_DISPEL_DEBUFF = "cleanse",
    SPELL_DISPEL_FAILED = "dispelFailed",
    SPELL_STOLEN = "steal",
    SPELL_STOLEN_BUFF = "steal",
    SPELL_STOLEN_DEBUFF = "steal",
    SPELL_AURA_BROKEN = "broke",
    SPELL_AURA_BROKEN_SPELL = "broke",
    SPELL_AURA_BROKEN_BUFF = "broke",
    SPELL_AURA_BROKEN_DEBUFF = "broke",
    SPELL_AURA_BROKEN_SPELL_BUFF = "broke",
    SPELL_AURA_BROKEN_SPELL_DEBUFF = "broke",
    PARTY_KILL = "kill",
    SPELL_EXTRA_ATTACKS = "extra",
}
ZCT.LOG_EVENT_KINDS = LOG_EVENT_KINDS

-- Kinds that become scroll events. Derived from LOG_EVENT_KINDS so the
-- set can't drift from the palette. The filter's dest part means these
-- happened TO you/your pet (kill credit excepted).
local UTILITY_LINE_KINDS = {}
for _, kind in pairs(LOG_EVENT_KINDS) do UTILITY_LINE_KINDS[kind] = true end
ZCT.UTILITY_LINE_KINDS = UTILITY_LINE_KINDS

-- The eventList for the filter's destination (incoming) part: exactly the
-- log-only events. Damage/heal/miss events are deliberately absent — they
-- share event names with outgoing events, so their lines can't be told
-- apart and would corrupt the pairing buffer.
local incoming = {}
for event in pairs(LOG_EVENT_KINDS) do incoming[event] = true end
ZCT.INCOMING_LINE_EVENTS = incoming

------------------------------------------------------------------------
-- Whitelisted events (no CLEU — it errors on RegisterEvent in 12.x)
------------------------------------------------------------------------
ZCT.WATCHED_EVENTS = {
    "COMBAT_LOG_MESSAGE",
    "COMBAT_TEXT_UPDATE",
    "UNIT_COMBAT",
    "UNIT_HEALTH",
    "UNIT_HEALTH_FREQUENT",
    "UNIT_SPELLCAST_SUCCEEDED",
    "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_STOP",
    "UNIT_SPELLCAST_CHANNEL_START",
    "UNIT_SPELLCAST_CHANNEL_STOP",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
    "PLAYER_ENTERING_WORLD",
    "PLAYER_LOGOUT",
    "COMBAT_LOG_APPLY_FILTER_SETTINGS",
    "COMBAT_LOG_ENTRIES_CLEARED",
}

-- Functions the Probe inspects for availability (never assumed).
ZCT.PROBE_C_FUNCS = {
    "C_CombatText", "C_CombatLog", "C_Secrets", "C_CurveUtil",
    "C_DurationUtil", "C_Spell", "C_DamageMeter",
}

-- Global functions worth probing (existence + signature when hooked).
ZCT.PROBE_GLOBALS = {
    "CombatText_AddMessage",
    "CombatText_AddMessage_v2",
    "CombatText_AddMessage2",
    "CombatText_AddMessage2_v2",
    "GetCurrentCombatTextEventInfo",
    "issecretvalue", "canaccessvalue", "canaccessallvalues",
    "hasanysecretvalues", "issecrettable", "canaccesstable",
    "HasSecretValues", "secretwrap", "secretunwrap", "scrub",
    "scrubsecretvalues",
}

-- Damage-ish kinds for line pairing (a classified line of these proves
-- "your damage happened now").
ZCT.DAMAGE_LINE_KINDS = {
    direct = true, tick = true, melee = true, ranged = true,
    shield = true,
}
ZCT.HEAL_LINE_KINDS = { heal = true, hot = true }
ZCT.MISS_LINE_KINDS = {
    directMiss = true, tickMiss = true, meleeMiss = true,
    rangedMiss = true, shieldMiss = true,
}
