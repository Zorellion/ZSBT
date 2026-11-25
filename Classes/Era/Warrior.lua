-- Classes/Era/Warrior.lua — Warrior attribution for the Forever client
-- (Camelot, project 18). Loaded ONLY on Forever via the ClassDB gate —
-- mod.client = "era" makes this file inert on Retail.
--
-- Name-primary by design: Forever spellIds are RANKED (a different id per
-- rank — log shows Heroic Strike 78/284/285, Rend 772/6546/6547), so no
-- table below carries ids where a name match suffices — the engine
-- resolves each combat-log id to its localized name and matches `names`.
-- Facts below are derived from Camelot's own logs (2026-11) and the
-- client-read ability tables at warcraftforever.wiki — NOT classic-era
-- databases; Camelot re-schools and re-mechanics freely (Thunder Clap is
-- PHYSICAL here, Intercept deals damage, Deep Wound is singular).
--
-- Verified against Forever combat logs:
--   SPELL_PERIODIC_DAMAGE "Rend" 0x1 ticks ~3s (measured 22.897→28.862)
--   SPELL_DAMAGE "Heroic Strike" 0x1 (empowered swing reports under the
--     strike's own sid — it IS the hit, never suppress)
--   SPELL_DAMAGE rows: Thunder Clap, Hamstring, Revenge, Shield Bash,
--     Overpower, Mocking Blow, Deep Wound — all 0x1
--   Zero SPELL_DAMAGE: Battle Shout, Demoralizing Shout, Charge (only
--     SPELL_ENERGIZE), Sunder Armor — hence mod.exclude
local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}
mod.client = "era"

mod.dotCadenceDisambig = true

-- The spellbook IS the baseline: the knowledge pane lists only module
-- rows whose spell exists in the current book, so it shows the level-
-- appropriate kit and grows as new spells/ranks are learned.
mod.bookScopedKnowledge = true

mod.dots = {
	-- Rend bleeds every ~3s (log-measured, matches the 9–21s rank
	-- durations). Deep Wound is the Arms-talent crit bleed (singular
	-- name on Camelot; the aura rows log AURA_APPLIED so aura-poll can
	-- scope it). Both are school 1 with the same cadence — same-school
	-- same-interval collisions stay generic by design, honest rather
	-- than misnamed.
	{ names = { "Rend" },                        school = 1, interval = 3 },
	{ names = { "Deep Wound", "Deep Wounds" },   school = 1, interval = 3 },
}

-- Next-swing strikes. Queuing one emits an EMPTY damage report at the
-- press instant — FCT's documented Camelot mechanic (SpellCatalog
-- nextSwing): the empowered swing cannot land at press time by
-- definition, so a sid-carrying wound riding the cast timestamp is the
-- phantom ("Heroic Strike 0" in scroll). The collector drops those; the
-- real hit arrives on the swing (melee wound, or the same sid at
-- hit-time — its cast record is left unconsumed either way). Sid-keyed
-- because the report carries the ranked cast id. Ids from FCT's
-- client-derived catalog; Heroic Strike is tape-verified (78).
mod.nextSwing = {
	-- Heroic Strike ranks (verified: 78; FCT catalog for the rest)
	[78] = true, [284] = true, [285] = true, [1608] = true,
	[11564] = true, [11565] = true, [11566] = true, [11567] = true,
	[25286] = true, [25712] = true,
	-- Cleave ranks (same mechanic; FCT unverified but same report class)
	[845] = true, [7369] = true, [11608] = true, [11609] = true,
	[20569] = true,
}
-- Intercept deals damage on Camelot (unlike vanilla) so it stays
-- claimable.

mod.ranged = { "Shoot", "Shoot Bow", "Shoot Gun", "Shoot Crossbow", "Throw" }
mod.rangedIds = { 5019, 2764 } -- log-verified ids; ranks/name cover the rest

-- Denied outright: casts that never deal enemy damage on Camelot. Log-
-- verified where noted; the rest are mechanical (buffs/utility) per the
-- client-read kit. Absence is not enough — exclusion survives every
-- derivation path (same false-premise class as the DH Frailty trap).
mod.exclude = {
	"Battle Shout",            -- log-verified: buff only, 0 damage rows
	"Demoralizing Shout",      -- log-verified: debuff only
	"Sunder Armor",            -- log-verified: armor debuff, 0 damage
	"Charge",                  -- log-verified: rage+stun only ("Charge
	                           --   Stun" is a different name, unaffected)
	"Challenging Shout",
	"Intimidating Shout",
	"Piercing Howl",
	"Battle Stance",
	"Defensive Stance",
	"Berserker Stance",
	"Taunt",
	"Disarm",
	"Shield Block",
	"Shield Wall",
	"Last Stand",
	"Bloodrage",
	"Berserker Rage",
	"Recklessness",
	"Retaliation",             -- buff; counterattacks land as melee
	"Sweeping Strikes",        -- buff; extra strikes land as melee
	"Death Wish",
	"Enrage",
	"Blood Fury",              -- orc racial AP buff, no damage
	"Shatter Curse",           -- utility (seen in a live Camelot book)
	"Might of Stormwind",      -- world buff, fires constantly in logs
	"Plainsrunning",           -- mount speed, no damage
	"Anger Management",
	"Commanding Shout",
}

-- A warrior's own damage is ALL physical (school 1) on Camelot — even
-- Thunder Clap (re-schooled from classic nature, log-verified 0x1) — but
-- weapon procs/enchants can carry any school (fiery, shadow, frost), so
-- the derived whitelist would veto real proc wounds. Warrior is also a
-- melee class surrounded by school-1 traffic, so a school whitelist buys
-- almost no foreign suppression anyway. schoolsAny: proc wounds keep
-- their names; foreign suppression falls to the group gate.
mod.schoolsAny = true

-- Thunder Clap is PHYSICAL on Camelot (re-schooled; the spellbook's
-- tooltip parse may still derive nature from "thunder" wording). Pin the
-- log-verified rank ids; unlisted ranks fill from spellbook/learned.
mod.spellFacts = {
	[6343] = { school = 1 }, -- Thunder Clap r1 (log-verified 0x1)
	[8198] = { school = 1 }, -- Thunder Clap r2 (log-verified 0x1)
}

-- Multi-target casts: the cast seeds a budget so each target's hit can
-- claim the name. Budgets from the client-read kit; ids from live logs.
mod.castBudget = {
	[6343] = 4, -- Thunder Clap r1 — "up to 4 targets" (wiki)
	[8198] = 4, -- Thunder Clap r2
	[845]  = 2, -- Cleave r1 — target + one nearby enemy
}

-- Warriors melee for real — autos are legitimate display. No vetoAuto.
-- Warriors have no pets — no petSchool/guardian functions.

mod.toggles = {
	namePetMelee = true,
}

ZSBT.ClassDB.Register("WARRIOR", mod)
return mod
