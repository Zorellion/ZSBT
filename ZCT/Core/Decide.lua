------------------------------------------------------------------------
-- Zore's Combat Text - Decide
-- Maps a normalized CombatEvent to a display spec: which scroll area,
-- what text/raw payload, what color/size. Category settings come from
-- db.categories with built-in defaults (config UI arrives Phase 5).
------------------------------------------------------------------------
local ADDON_NAME, ZSBT = ...
ZSBT.ZCT = ZSBT.ZCT or {}
local ZCT = ZSBT.ZCT

ZCT = ZCT or {}
ZCT.Decide = ZCT.Decide or {}
local Decide = ZCT.Decide

------------------------------------------------------------------------
-- School colors (bitmask -> rgb). WoW school bits:
-- 1 phys, 2 holy, 4 fire, 8 nature, 16 frost, 32 shadow, 64 arcane.
------------------------------------------------------------------------
local SCHOOL_COLORS = {
    [1]  = { 1.00, 1.00, 0.00 },  -- physical: yellow
    [2]  = { 1.00, 0.90, 0.50 },  -- holy: gold
    [4]  = { 1.00, 0.30, 0.00 },  -- fire: orange-red
    [8]  = { 0.30, 1.00, 0.30 },  -- nature: green
    [16] = { 0.40, 0.80, 1.00 },  -- frost: ice blue
    [32] = { 0.60, 0.20, 1.00 },  -- shadow: purple
    [64] = { 1.00, 0.50, 1.00 },  -- arcane: pink
}

-- Fallback color per class when no school is known.
local CLASS_COLORS = {
    damage = { 1.00, 0.45, 0.45 },
    heal   = { 0.40, 1.00, 0.50 },
    miss   = { 0.70, 0.70, 0.80 },
    utility = { 1.00, 1.00, 1.00 },
}
Decide.CLASS_COLORS = CLASS_COLORS

local CRIT_COLOR = { 1.00, 1.00, 0.20 }

------------------------------------------------------------------------
-- Category defaults (merged under db.categories by GetDB later; kept
-- here so Decide works before the config schema lands).
------------------------------------------------------------------------
local PET_TINT = { 0.90, 0.75, 0.45 }
local DEFAULT_CATEGORIES = {
    IncomingDamage    = { enabled = true, scrollArea = "Incoming", useSchoolColors = true },
    IncomingHeal      = { enabled = true, scrollArea = "Incoming", color = { 0.40, 1.00, 0.50 } },
    IncomingMiss      = { enabled = true, scrollArea = "Incoming", color = { 0.70, 0.70, 0.80 } },
    OutgoingDamage    = { enabled = true, scrollArea = "Outgoing", useSchoolColors = true },
    OutgoingHeal      = { enabled = true, scrollArea = "Outgoing", color = { 0.40, 1.00, 0.50 } },
    OutgoingMiss      = { enabled = true, scrollArea = "Outgoing", color = { 0.70, 0.70, 0.80 } },
    -- Pet: hits ON the pet, and hits BY the pet that are provable (pet
    -- spell casts). Tinted by default so they read apart from your own.
    PetIncomingDamage = { enabled = true, scrollArea = "Incoming", useSchoolColors = false, color = PET_TINT },
    PetIncomingHeal   = { enabled = true, scrollArea = "Incoming", color = { 0.55, 0.90, 0.55 } },
    PetIncomingMiss   = { enabled = true, scrollArea = "Incoming", color = { 0.65, 0.62, 0.55 } },
    PetOutgoingDamage = { enabled = true, scrollArea = "Outgoing", useSchoolColors = false, color = PET_TINT },
    PetOutgoingHeal   = { enabled = true, scrollArea = "Outgoing", color = { 0.55, 0.90, 0.55 } },
    -- Utility events (interrupts, dispels, steals, breaks, kills, extra
    -- attacks). Color comes from the palette line itself (evt.rgb);
    -- `color` here is only a fallback if rgb is ever missing.
    IncomingUtility   = { enabled = true, scrollArea = "Incoming",
        showSpellName = true },
    OutgoingUtility   = { enabled = true, scrollArea = "Outgoing",
        showSpellName = true },
}
Decide.DEFAULT_CATEGORIES = DEFAULT_CATEGORIES

local KIND_SUFFIX = { damage = "Damage", heal = "Heal", miss = "Miss",
    utility = "Utility" }

-- Scroll text for utility events when no cast names them. The line color
-- (evt.rgb, the palette color) carries the visual identity.
local UTILITY_LABELS = {
    interrupt = "Interrupted", purge = "Purged", cleanse = "Cleansed",
    steal = "Stolen", dispelFailed = "Dispel Failed",
    broke = "Aura Broken", kill = "Kill", extra = "Extra Attack",
}
Decide.UTILITY_LABELS = UTILITY_LABELS
Decide.UTILITY_KINDS = { "purge", "cleanse", "steal",
    "dispelFailed", "broke", "kill", "extra" }

local function categoryFor(evt, db)
    local suffix = KIND_SUFFIX[evt.kind]
    if not suffix then return nil end
    local dir = (evt.direction == "in" and "Incoming")
        or (evt.direction == "out" and "Outgoing") or nil
    if not dir then return nil end
    -- Utility lines aren't pet-attributed (pet cleanse naming is too
    -- rare to justify two more categories) — they collapse to the
    -- direction-only utility buckets.
    local pet = evt.pet == true and evt.kind ~= "utility"
    -- Caster mode: melee swings carry no spellId and UNIT_COMBAT can't say
    -- who swung, so a caster's "melee" lines are almost always the pet's.
    -- Opt-in because it misattributes real player melee when it's on.
    if not pet and db and db.casterMode == true
        and UnitExists and UnitExists("pet")
        and evt.direction == "out" and not evt.spellId
        and (evt.lineKind == "melee" or evt.lineKind == "meleeMiss") then
        pet = true
    end
    -- No PetOutgoingMiss bucket: outgoing pet misses are nearly
    -- unprovable (melee/ranged carry no spellId), so they fold into
    -- regular OutgoingMiss instead of dying in a dead category.
    if pet and suffix == "Miss" and dir == "Outgoing" then pet = false end
    return (pet and "Pet" or "") .. dir .. suffix
end

-- An area name that exists right now: the requested one, else the first
-- existing area alphabetically (a deleted/renamed area never eats text).
function Decide:ResolveArea(name, db)
    local sa = db and db.scrollAreas
    if type(sa) ~= "table" then return name or "Incoming" end
    if name and type(sa[name]) == "table" then return name end
    local first
    for k, v in pairs(sa) do
        if type(v) == "table" and (not first or k < first) then first = k end
    end
    return first or name or "Incoming"
end

-- Resolve color: crit color (if enabled) > school color > category color >
-- class color > white.
local function resolveColor(evt, cat, crit)
    if evt.crit and (not crit or crit.useColor ~= false) then
        return (crit and type(crit.color) == "table") and crit.color or CRIT_COLOR
    end
    -- Utility events carry their palette color on the event itself.
    if evt.kind == "utility" and type(evt.rgb) == "table" then
        return evt.rgb
    end
    -- School colors apply only to categories that explicitly opt in
    -- (useSchoolColors == true). nil/false means the picked color wins —
    -- heals and misses have no school-color checkbox, so they must not
    -- silently override the user's color choice.
    if cat and cat.useSchoolColors == true and evt.school then
        local c = SCHOOL_COLORS[evt.school]
        if c then return c end
    end
    if cat and cat.color then return cat.color end
    return CLASS_COLORS[evt.kind] or { 1, 1, 1 }
end

-- Icon for a PROVEN spellId only (Outgoing attribution); cached per id.
local iconCache = {}
local function spellIcon(id)
    if not ZCT.IsSafeNumber(id) then return nil end
    local tex = iconCache[id]
    if tex == nil then
        local ok, t
        if C_Spell and C_Spell.GetSpellTexture then
            ok, t = pcall(C_Spell.GetSpellTexture, id)
        elseif GetSpellTexture then
            ok, t = pcall(GetSpellTexture, id)
        end
        tex = (ok and t) or false
        iconCache[id] = tex
    end
    return tex or nil
end

-- Build the display payload. Secrets can ONLY go to FontString:SetText
-- raw — never concatenated. So the spec carries either:
--   spec.raw   -> pass straight to SetText (secret-safe)
--   spec.text  -> safe string
local MISS_TEXT = {
    DODGE = "Dodge", MISS = "Miss", PARRY = "Parry", BLOCK = "Block",
    RESIST = "Resist", ABSORB = "Absorb", EVADE = "Evade",
    IMMUNE = "Immune", REFLECT = "Reflect", DEFLECT = "Deflect",
}
Decide.MISS_TEXT = MISS_TEXT
Decide.MISS_TYPES = { "DODGE", "MISS", "PARRY", "BLOCK", "RESIST",
    "ABSORB", "EVADE", "IMMUNE", "REFLECT", "DEFLECT" }

-- evt.action arrives as a UNIT_COMBAT token (DODGE, ABSORB...) or a
-- COMBAT_TEXT_UPDATE token (SPELL_ABSORB, SWING_MISS, *_MISSED). Reduce
-- both to the bare subtype; nil = unknown (never hidden — fail open).
local function missSubtype(action)
    if type(action) ~= "string" then return nil end
    local u = action:upper():gsub("MISSED$", "MISS")
    for _, k in ipairs(Decide.MISS_TYPES) do
        local n = #k
        if u == k or (u:sub(-n) == k and u:sub(-n - 1, -n - 1) == "_") then
            return k
        end
    end
    return nil
end

-- Crit settings live in per-direction, per-kind buckets:
-- db.crit.{damage,heal} (outgoing) and db.critIn.{damage,heal}
-- (incoming, forked from crit on first write). Heals use the heal
-- bucket; everything else (damage, miss, utility) uses damage.
-- Falls back through sibling bucket -> flat legacy table -> nil.
local function critSettings(db, evt)
    local dir = db.crit
    if evt.direction == "in" and type(db.critIn) == "table" then
        dir = db.critIn
    end
    if type(dir) ~= "table" then return nil end
    local want = (evt.kind == "heal") and "heal" or "damage"
    local b = dir[want]
    if type(b) == "table" then return b end
    local sib = (want == "heal") and dir.damage or dir.heal
    if type(sib) == "table" then return sib end
    -- Legacy flat table that escaped migration: it carries the settings
    -- at top level, so return it directly.
    if dir.style ~= nil or dir.color ~= nil or dir.scale ~= nil
        or dir.useColor ~= nil then
        return dir
    end
    return nil
end

function Decide:Spec(evt)
    -- Merge defaults with user overrides key-by-key: a userCat that only
    -- sets `color` must not drop `enabled`/`scrollArea` from the default.
    local db = ZCT.GetDB and ZCT:GetDB() or {}
    local catName = categoryFor(evt, db)
    if not catName then return nil end

    local userCat = db.categories and db.categories[catName]
    local cat = {}
    local def = DEFAULT_CATEGORIES[catName]
    if def then for k, v in pairs(def) do cat[k] = v end end
    if userCat then for k, v in pairs(userCat) do cat[k] = v end end
    if next(cat) == nil then return nil end
    local userIcons = db.showIcons ~= false
    if cat.enabled == false then return nil end

    -- Min amount: readable amounts only. Secret amounts can't be compared,
    -- so they always pass (the config UI says so).
    local minAmt = tonumber(cat.minAmount)
    if minAmt and minAmt > 0 and evt.kind ~= "miss"
        and ZCT.IsSafeNumber(evt.amount) and evt.amount < minAmt then
        return nil
    end

    -- Crit settings are bucketed per direction AND per kind:
    -- db.crit.{damage,heal} outgoing, db.critIn.{damage,heal} incoming
    -- (critIn forked from crit on first write). Misses/utility crits
    -- fall back to the damage bucket.
    local crit = critSettings(db, evt)
    local area = cat.scrollArea
    local critStyle = "Normal"
    if evt.crit and crit then
        if type(crit.area) == "string" and crit.area ~= "" then area = crit.area end
        critStyle = crit.style or "Normal"
    end
    -- Font precedence: crit override > category override > master font.
    local fontOv = nil
    if evt.crit and crit and crit.fontOverride == true
        and type(crit.font) == "table" then
        fontOv = crit.font
    elseif cat.fontOverride == true and type(cat.font) == "table" then
        fontOv = cat.font
    end
    local spec = {
        area = self:ResolveArea(area, db),
        color = resolveColor(evt, cat, crit),
        crit = evt.crit,
        critScale = crit and tonumber(crit.scale) or 1.35,
        critStyle = critStyle,
        icon = userIcons and spellIcon(evt.spellId) or nil,
        font = fontOv,
        periodic = evt.periodic,
        kind = evt.kind,
        category = catName,
    }

    if evt.kind == "miss" then
        -- Per-category hidden subtypes ("Absorb", "Dodge", ...).
        local sub = missSubtype(evt.action)
        local hidden = cat.hiddenMiss
        if sub and type(hidden) == "table" and hidden[sub] == true then
            return nil
        end
        -- Misses show a word, not a number. Prefer the combat-log-free
        -- action token; fall back to generic "Miss".
        local word = type(evt.action) == "string" and MISS_TEXT[missSubtype(evt.action) or ""]
        spec.text = word or "Miss"
        spec.mode = "text"
    elseif evt.kind == "utility" then
        -- Per-category hidden kinds ("Kill", "Aura Broken", ...).
        local hu = cat.hiddenUtility
        if type(hu) == "table" and hu[evt.lineKind] == true then
            return nil
        end
        -- Spell name when a single recent cast names it, else the kind
        -- label. No amount exists — the KString is never read.
        -- cat.showSpellName == false forces the generic label.
        local name = nil
        if cat.showSpellName ~= false
            and ZCT.IsSafeNumber(evt.spellId) and ZCT.CleanSpellName then
            name = ZCT.CleanSpellName(evt.spellId)
        end
        spec.text = name or UTILITY_LABELS[evt.lineKind] or "Utility"
        spec.mode = "text"
    elseif type(evt.amount) ~= "nil" then
        -- Amount may be secret: hand it to the display raw. When it's a
        -- safe number we can format it ourselves.
        if ZCT.IsSafeNumber(evt.amount) then
            spec.text = tostring(math.floor(evt.amount + 0.5))
            spec.mode = "text"
        else
            spec.raw = evt.amount
            spec.mode = "raw"
        end
    else
        -- No amount available: show the class word rather than nothing.
        spec.text = ({ damage = "Hit", heal = "Heal" })[evt.kind] or "?"
        spec.mode = "text"
    end

    return spec
end

------------------------------------------------------------------------
-- Merging (spam control)
-- Only hits PROVABLY from the same spell merge: outgoing, non-crit,
-- non-periodic, non-miss, with a safe spellId from Outgoing's strict
-- attribution. Incoming events carry no spellId, so they never merge.
-- Readable amounts are summed; if any amount is secret the line shows
-- the latest hit raw with an "xN" badge (never concatenated).
------------------------------------------------------------------------
local mergeState = {} -- category -> spellId -> state (reused tables)

local function tryMerge(spec, evt, db)
    local sp = db.spam
    if not sp or sp.enabled == false then return false end
    if evt.direction ~= "out" or evt.crit or evt.periodic
        or evt.kind == "miss" or evt.kind == "utility"
        or not ZCT.IsSafeNumber(evt.spellId) then
        return false
    end
    local t = ZCT.Display.Now and ZCT.Display:Now()
    if not t then return false end
    local window = tonumber(sp.mergeWindow) or 0.6
    local showCount = sp.mergeShowCount ~= false

    local byCat = mergeState[spec.category]
    if not byCat then byCat = {}; mergeState[spec.category] = byCat end
    local st = byCat[evt.spellId]
    local safe = ZCT.IsSafeNumber(evt.amount)

    if st and st.item and t - st.at <= window then
        local count = st.count + 1
        local sum = (st.sum and safe) and (st.sum + evt.amount) or nil
        local text = sum and tostring(math.floor(sum + 0.5)) or nil
        if ZCT.Display:UpdateMerged(st.item, st.serial, text, evt.amount,
            count, showCount) then
            st.count, st.sum = count, sum
            return true
        end
    end

    local item, serial = ZCT.Display:Show(spec)
    if not item then return true end
    st = st or {}
    st.item, st.serial, st.at, st.count = item, serial, t, 1
    st.sum = safe and evt.amount or nil
    byCat[evt.spellId] = st
    return true
end

------------------------------------------------------------------------
-- Sink: Normalize -> Decide -> Display
------------------------------------------------------------------------
function Decide:Handle(evt)
    local db = ZCT.GetDB and ZCT:GetDB() or nil
    if db and db.enabled == false then return end
    if db and db.combatOnly and not InCombatLockdown() then return end
    local spec = self:Spec(evt)
    if not spec then return end
    -- Crit sound: fires only for events that actually display as crits,
    -- using the direction+kind bucket's settings.
    local critCfg = db and critSettings(db, evt)
    if evt.crit and critCfg and critCfg.soundEnabled == true
        and ZCT.Sounds and ZCT.Sounds.Play then
        ZCT.Sounds:Play(critCfg.sound, critCfg.soundFile)
    end
    if ZCT.Display and ZCT.Display.Show then
        if db and tryMerge(spec, evt, db) then return end
        ZCT.Display:Show(spec)
    elseif ZCT.Dbg and ZCT.Dbg:Enabled("display") then
        ZCT.Dbg:Trace("display", "spec area=%s mode=%s kind=%s",
            spec.area, spec.mode, spec.kind)
    end
end
