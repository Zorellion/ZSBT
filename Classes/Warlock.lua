-- Classes/Warlock.lua — Warlock-specific combat attribution
--
-- DoTs (name-primary; ids are fallback fast path):
--   Corruption / Agony / Unstable Affliction / Seed of Corruption / Haunt = shadow (32)
--   Immolate = fire (4)
-- Channel: Drain Life (channeled, emits each tick)
-- Pet rules: Imp fire hits are pet damage, never player DoTs; felhunter/
-- voidwalker/succubus shadow bites stay out of the recent-cast window.

local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {
	{ names = { "Corruption" },             ids = { 172, 146739, 1261158 },       school = 32 },
	{ names = { "Agony" },                  ids = { 980, 1261166 },               school = 32 },
	{ names = { "Unstable Affliction" },    ids = { 30108, 1259790, 1261176 },    school = 32 },
	{ names = { "Seed of Corruption" },     ids = { 27243, 27285 },               school = 32 },
	{ names = { "Haunt" },                  ids = { 48181 },                      school = 32 },
	{ names = { "Immolate" },               ids = { 348 },                        school = 4 },
	-- Destruction's DoT (Midnight): cast 445468, ticks 445474, shadowflame.
	{ names = { "Wither" },                 ids = { 445468, 445474 },             school = 36 },
	-- Soul Anathema self-applies (SPELL_AURA_APPLIED, no cast event), so
	-- the ids below can never seed a window — the entry documents the
	-- periodic for the knowledge pane and future per-dot records.
	{ names = { "Soul Anathema" },          ids = { 450538 },                     school = 32 },
}

mod.channels = {
	{ names = { "Drain Life" }, ids = { 234153 }, duration = 6.0, tickMin = 0.12, school = 32 },
	{ names = { "Drain Soul" }, ids = { 1120, 198590 }, duration = 5.0, tickMin = 0.12, school = 32 },
	-- Rain of Fire: instant ground AoE, ticks ~0.55s (verified); the cast
	-- seeds an 8s window and tick-kind hits claim the name — Ravager-style
	-- because individual ticks carry no cast record. Cast id 1214467 is
	-- Midnight's (legacy 5740 kept for safety), damage id 42223.
	{ names = { "Rain of Fire" }, ids = { 1214467, 5740 }, duration = 8.0, tickMin = 0.4, school = 4 },
}

-- Zero-enemy-damage casts: a wound can never honestly wear these
-- names — not via dot pools, channels, pending-cast stamps, or the
-- make-it-work recency claim, and they must not suppress DoT
-- attribution as a "recent cast". NEVER list a dot/channel name.
mod.exclude = {
	"Health Funnel",
	"Fear",
	"Howl of Terror",
	"Banish",
	"Curse of Weakness",
	"Curse of Tongues",
	"Curse of Exhaustion",
	"Amplify Curse",
	"Shadowfury",
	"Dark Pact",
	"Unending Resolve",
	"Demonic Circle: Teleport",
	"Fel Domination",
	"Ritual of Summoning",
	"Eye of Kilrogg",
	"Subjugate Demon",
	"Summon Imp",
	"Summon Voidwalker",
	"Summon Succubus",
	"Summon Felhunter",
	"Summon Felguard",
	"Summon Incubus",
}

-- Per-cast-instance naming budget for the recency-stamp paths: how many
-- hits one cast may claim. Multi-hit bursts (AoE/splash) claim several;
-- single-target nukes stay at the default of 1 so one cast can never
-- wear its icon on every nearby hit.
mod.castBudget = {
	[105174] = 4,    -- Hand of Gul'dan (impact + splash)
	[196277] = 8,    -- Implosion (per-target hits)
	[434635] = 8,    -- Ruination (AoE)
	[1276462] = 4,   -- Grimoire: Imp Lord variant
	[264106] = 6,    -- Bilescourge Bombers
	[1261153] = 8,   -- Malefic Grasp: ~1 hit per active DoT (verified 3-4/cast)
	[1257052] = 4,   -- Dark Harvest: cast -> damage 1257065 (shadowflame)
	[442726] = 4,    -- Malevolence: cast -> damage 446285 (shadowflame)
	[442804] = 2,    -- Curse of the Satyr
}

-- Provable damage schools (masks observed on player/pet/guardian-owned
-- lines): 1 pet melee, 4 fire (imp/destro), 8 nature (Bile Spit,
-- trinkets), 32 shadow, 36 shadowflame, 40 shadow|nature (Blighted Maw),
-- 127 chaos (Ruination, Diabolic Gaze). Anything else on an
-- unattributed hit is provably foreign — ClassDB.SchoolAllowed vetoes.
mod.schools = { [1] = true, [4] = true, [8] = true, [32] = true,
	[36] = true, [40] = true, [124] = true, [127] = true }

-- Per-pet-cast claim budget (default is PET_CAST_MAX_CLAIMS=8 for AoE).
-- Lash of Pain is strictly single-target and its damage lands ~0.05s
-- after the cast — first in the window, always — so a second claim is
-- a stray school-32 player hit wearing her name.
mod.petCastBudget = { [7814] = 1 }

-- Class-module UI toggles this module supports (Class page + quick bar).
mod.guardianLabel = "imps, dreadstalkers, darkglare, or the tyrant"
mod.toggles = {
	resolveGuardians = true,  -- guardian spellbook naming on/off
	namePetMelee = true,      -- MY_PET-proven melee named "Auto Attack"
}

local function isImpPet(helpers)
	local fam = helpers and helpers.family and helpers.family() or nil
	return fam ~= nil and fam == "imp"
end

-- Imp fire hits are pet damage — never attribute them to player DoTs.
function mod.dotGuard(entry, school, helpers)
	if helpers and helpers.safeNumber and helpers.safeNumber(school)
		and school == 4 and isImpPet(helpers) then
		return false
	end
	return nil
end

-- Pet signature: warlock-pet damage carries the fire bit. UNIT_COMBAT
-- reports composite school masks for minion pets (imp firebolts arrive as
-- 4, 12, 36 etc.), so match the fire bit rather than exact school 4.
-- Shadow (32) is deliberately excluded — it overlaps player DoTs/nukes.
local function hasFireBit(school)
	return math.floor(school / 4) % 2 == 1
end

-- Union of every school a warlock minion can produce across ALL
-- families + guardians: imp fire (4/36), demon shadow (32), melee (1).
-- A pet-routed hit outside this set is provably foreign regardless of
-- which demon is out (holy/nature/frost/arcane have no warlock-minion
-- source). Deliberately NOT family-scoped — guardians make different
-- minions' damage overlap, and a false veto loses real pet damage.
local PET_SCHOOLS = { [1] = true, [4] = true, [32] = true, [36] = true }

function mod.petSchoolAllowed(school, helpers)
	if not (helpers and helpers.safeNumber and helpers.safeNumber(school)) then
		return nil
	end
	return PET_SCHOOLS[school] == true
end

function mod.petSchoolHit(school, helpers)
	-- Fire bit = imp signature ONLY. A succubus/felhunter out means no
	-- pet produces fire damage at all — on Destruction nearly the whole
	-- player kit carries the fire bit, so gating on family is the only
	-- thing keeping player strays out of the pet scroll.
	if helpers and helpers.safeNumber and helpers.safeNumber(school)
		and hasFireBit(school) and isImpPet(helpers) then
		return true
	end
	return false
end

-- Warlock spells whose damage carries the fire bit and therefore must NOT
-- be pet-claimed when they are the recent cast: direct fire nukes, the
-- Immolate family, and fire-bit hybrid nukes (HoG/Implosion/Ruination are
-- Shadowflame). Everything else a lock casts (shadow nukes, dots, summons,
-- defensives) means a nearby fire hit is almost certainly an Imp bolt or
-- Mother of Chaos Chaos Salvo.
local WARLOCK_FIRE_PLAYER_SPELLS = {
	["Immolate"] = true,
	["Incinerate"] = true,
	["Conflagrate"] = true,
	["Firebolt"] = true,
	["Rain of Fire"] = true,
	["Cataclysm"] = true,
	["Infernal Bolt"] = true,
	["Hand of Gul'dan"] = true,
	["Implosion"] = true,
	["Ruination"] = true,
	["Eye of Gul'dan"] = true,
	["Diabolic Gaze"] = true,
	["Rune of Unleashed Fire"] = true,
	["Summon Infernal"] = true,
	-- Destruction (verified Midnight): every fire-bit damage cast, so a
	-- stray fire hit after one of these is not imp-claimed.
	["Wither"] = true,          -- 0x24 shadowflame DoT
	["Chaos Bolt"] = true,      -- 0x7c chromatic
	["Shadowburn"] = true,
	["Soul Fire"] = true,
	["Channel Demonfire"] = true,
	["Malevolence"] = true,     -- 0x24
	["Curse of the Satyr"] = true,
}

-- Recent-cast variant: a fire-bit hit near a recent cast belongs to the
-- Imp/pets UNLESS that cast is a known warlock fire damage spell (then it
-- may be the player's own Incinerate/Immolate/etc). Shadow (32) hits are
-- never pet-claimed here — they overlap player DoTs/nukes.
function mod.petSchoolHitRecent(self, school, lastPlayerSpellId, helpers)
	if not (helpers and helpers.safeNumber and helpers.safeNumber(school)) then
		return false
	end
	if not hasFireBit(school) then return false end
	if not isImpPet(helpers) then return false end
	if type(lastPlayerSpellId) ~= "number" then return false end
	local sn = helpers.cleanName and helpers.cleanName(lastPlayerSpellId) or nil
	if sn == nil then
		-- Name resolution failed: fall back to the old shadow-dot check so
		-- Imp fire near Corruption/Shadow Bolt still routes to the pet.
		local e = ZSBT.ClassDB.DotEntry and ZSBT.ClassDB.DotEntry(lastPlayerSpellId)
		if e and e.school == 32 then
			return true
		end
		return false
	end
	if WARLOCK_FIRE_PLAYER_SPELLS[sn] then return false end
	return true
end

-- A warlock never meaningfully auto-attacks: every school-1 hit is a
-- demon's melee or a foreign swing. Vetoing auto claims routes them to
-- pet-physical/generic instead of displaying as your white swing.
-- profile.classModule.allowAutoAttack (Class page toggle) overrides.
function mod.vetoAuto(helpers)
	local cm = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.classModule
	if cm and cm.allowAutoAttack == true then return false end
	return true
end

-- Physical pet melee (Dreadstalker, Gloomhound, etc). Consulted only by the
-- pet-fallback emit and gated to non-group content by the caller — in
-- groups, foreign swings are indistinguishable from pet melee.
function mod.petPhysicalHit(school, helpers)
	return helpers and helpers.safeNumber and helpers.safeNumber(school)
		and school == 1
end

-- Guardian spellbook (spellIds verified from WoWCombatLog). Guardian casts
-- never reach UNIT_SPELLCAST_SUCCEEDED — they have no unit token — so the
-- only way to name their hits is this table plus summon-activity tracking.
-- school is the exact schoolMask the hit reports.
local GUARDIAN_SPELLS = {
	wildimp = { { sid = 104318, school = 4 } },                     -- Fel Firebolt
	dreadstalker = { { sid = 271971, school = 32 },                 -- Dreadbite
		{ sid = 1276960, school = 40 } },                           -- Blighted Maw (talent rider)
	gloomhound = { { sid = 455491, school = 32 },                   -- Gloom Slash
		{ sid = 267997, school = 8 } },                             -- Bile Spit
	tyrant = { { sid = 1264093, school = 36 } },                    -- Burning Cleave
	-- darkglare deliberately has no entries: its Eye Beam (205231) is
	-- school 32, and during a Darkglare window every unattributed
	-- school-32 hit — the player's own DoT ticks whose windows lapsed,
	-- Soul Anathema, Shadow of Nathreza — would claim the name. On a
	-- spec whose kit is almost entirely school-32 periodic traffic,
	-- leaving the group spell-less keeps those hits honest generics.
	-- infernal likewise: Immolation (19483) is school 4, and Destruction's
	-- stray stream is nearly all fire-bit — a school-4 guardian name
	-- would steal the player's own unpaired hits for 30 straight seconds.
}
mod.guardianSpells = GUARDIAN_SPELLS

-- Player summon casts → which guardian groups go out, and for how long.
-- Keyed on the CAST spellId (UNIT_SPELLCAST_SUCCEEDED), which differs
-- from the damage id — HoG casts as 105174, damages as 86040.
local GUARDIAN_SUMMONS = {
	[86040] = { { group = "wildimp", duration = 11 } },             -- Hand of Gul'dan (dmg id, some builds)
	[105174] = { { group = "wildimp", duration = 11 } },            -- Hand of Gul'dan (cast id)
	[104316] = { { group = "dreadstalker", duration = 12 },
		{ group = "gloomhound", duration = 12 } },                  -- Call Dreadstalkers
	[264119] = { { group = "gloomhound", duration = 15 } },         -- Summon Vilefiend
	[265187] = { { group = "tyrant", duration = 18 } },             -- Summon Demonic Tyrant
	[205180] = { { group = "darkglare", duration = 15 } },          -- Summon Darkglare (Aff)
	[1122] = { { group = "infernal", duration = 30 } },             -- Summon Infernal (Destro)
	[1276452] = { { group = "implord", duration = 20 } },           -- Grimoire: Imp Lord
}
mod.guardianSummons = GUARDIAN_SUMMONS

-- Name an unattributed pet hit: collect the spells every ACTIVE guardian
-- could have produced at this school; exactly one match names the hit,
-- anything else stays generic (a wrong name is worse than no name).
-- An out succubus adds ambiguity to school-32 guardian candidates (Lash
-- of Pain, 7814, is also school 32) but contributes no name of her own —
-- real Lash casts are claimed by consumePetCast before this hook runs.
function mod.resolvePetSpellId(self, school, t, helpers)
	-- profile.classModule.resolveGuardians == false disables guardian
	-- naming entirely (hits fall back to generic pet / suppression).
	local cm = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.classModule
	if cm and cm.resolveGuardians == false then return nil end
	if not (helpers and helpers.safeNumber and helpers.safeNumber(school)) then
		return nil
	end
	if school == 1 then return nil end -- melee swings stay generic
	local best, ambiguous = nil, false
	for group, spells in pairs(GUARDIAN_SPELLS) do
		local active = self._guardianUntil and (self._guardianUntil[group] or 0) >= t
		if active then
			for _, sp in ipairs(spells) do
				if sp.school == school then
					if best == nil then best = sp.sid
					elseif best ~= sp.sid then ambiguous = true end
				end
			end
		end
	end
	if not ambiguous then
		-- A succubus makes guardian school-32 candidates ambiguous (Lash of
		-- Pain is also school 32) — but she must never SUPPLY a name on her
		-- own. Affliction's whole kit is school-32, so an unconditional
		-- claim routes the player's own DoT ticks and bolts into pet
		-- scroll. Her real casts still name hits via consumePetCast.
		local fam = helpers and helpers.family and helpers.family() or nil
		if fam == "succubus" and school == 32 and best ~= nil then
			ambiguous = true
		end
	end
	if ambiguous then return nil end
	return best
end

-- Name physical pet hits "Auto Attack" (6603) when the user opts in.
-- The hit still has to claim a MY_PET line, so the name can only appear
-- on damage the palette already proved came from a pet. No guardian
-- check needed: a pet melee line existing at all means a pet swung.
-- profile.classModule.namePetMelee (Class page toggle), default off —
-- a stolen MY_PET line could otherwise name a foreign swing.
function mod.resolvePetMelee(self, helpers)
	local cm = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.classModule
	if cm and cm.namePetMelee == true then return 6603 end
	return nil
end

-- Channel seeding (Drain Life / Drain Soul) + guardian summon tracking.
function mod.onCast(self, spellId, spellName, t)
	local ch = ZSBT.ClassDB.ChannelMatch(spellId)
	if ch then
		self._channel = {
			untilAt = t + (ch.duration or 6.0),
			lastTickAt = 0,
			spellId = spellId,
			tickMin = ch.tickMin or 0.12,
			school = ch.school,
		}
	end
	local summon = GUARDIAN_SUMMONS[spellId]
	if summon then
		self._guardianUntil = self._guardianUntil or {}
		for _, g in ipairs(summon) do
			self._guardianUntil[g.group] = t + g.duration
		end
	end
end

ZSBT.ClassDB.Register("WARLOCK", mod)
return mod
