-- Classes/Hunter.lua — Hunter-specific combat attribution
--
-- Inverted from Warlock: the player's own damage is heavily PHYSICAL
-- (auto-shot, Aimed Shot, Kill Shot, Mongoose/Raptor), so school-1 is
-- player-ambiguous, not a pet signature. Pet damage is named through
-- real cast records (hunter pets have a "pet" token — Bite/Claw/Smack,
-- Kill Command damage casts are attributed to the pet in the log) and
-- MY_PET-proven melee naming. Signature-based pet claiming is OFF for
-- all schools: every hunter damage school overlaps a player school.
--
-- Guardian-side damage (Dire Beast, A Murder of Crows, Stampede, Animal
-- Companion) is almost entirely physical melee — unnameable by design,
-- tracked below only as activity windows for future school'd entries.

local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {
	{ names = { "Serpent Sting" },  ids = { 1978, 271788 }, school = 8 },
	{ names = { "Black Arrow" },    ids = {},               school = 32 }, -- Dark Ranger; name-primary
	{ names = { "Latent Poison" },  ids = { 378016 },       school = 8 }, -- SV wildfire injector
}

-- Channeled volleys: each shot is a separate UNIT_COMBAT hit; channel
-- tracking lets the whole volley name itself off one cast.
mod.channels = {
	{ names = { "Rapid Fire" },       ids = { 257044 }, duration = 2.0, tickMin = 0.12 },
	{ names = { "Fury of the Eagle" }, ids = { 203415 }, duration = 4.0, tickMin = 0.12 },
}

-- Per-cast-instance naming budget (same mechanism as warlock): AoE and
-- multi-hit casts may name several hits; single-target stays at 1.
mod.castBudget = {
	[2643]   = 8,  -- Multi-Shot
	[257620] = 8,  -- Multi-Shot (Marksmanship variant)
	[260243] = 8,  -- Volley
	[212680] = 8,  -- Explosive Shot (detonation is AoE)
	[271788] = 8,  -- Serpent Sting (Volley/Serpentstalker's spread applies)
	[259495] = 8,  -- Wildfire Bomb
	[269747] = 8,  -- Wildfire Bomb (old id, still emitted in some paths)
	[120360] = 12, -- Barrage
	[212436] = 8,  -- Butchery
	[186387] = 8,  -- Bursting Shot
	[392060] = 6,  -- Wailing Arrow (AoE shadow)
	[257044] = 10, -- Rapid Fire volley (fallback; channels usually catch it)
	[203415] = 12, -- Fury of the Eagle volley
}

-- Player summon casts → guardian activity windows. Guardian damage is
-- physical melee (Dire Beast, Murder of Crows crows, Stampede beasts,
-- Animal Companion second pet), so the windows currently only support
-- future school'd spellbook entries — melee stays generic regardless.
local GUARDIAN_SUMMONS = {
	[204432] = { { group = "direbeast", duration = 8 },
		{ group = "darkhound", duration = 8 } },            -- Dire Beast (verified log cast id)
	[120679] = { { group = "direbeast", duration = 8 },
		{ group = "darkhound", duration = 8 } },            -- Dire Beast (pre-Midnight id)
	[131894] = { { group = "crows",     duration = 15 } },  -- A Murder of Crows
	[201430] = { { group = "stampede",  duration = 12 } },  -- Stampede
	[288613] = { { group = "darkminion", duration = 20 } }, -- Trueshot (Wailing Dead)
}

-- Class-module UI toggles this module supports.
mod.toggles = {
	namePetMelee = true,
	resolveGuardians = true,
}

-- Non-physical guardian spellbook. The only school'd guardian damage in
-- the kit is Dark Ranger: Shadow Thrash's id doubles as the MM Dark
-- Minion's "Blighted Arrow" (same spell page lists both). Dire Beast,
-- Murder of Crows, Stampede, and Pack Leader beasts are all physical —
-- unnameable by design. Hound/minion basic attacks aren't broadcast in
-- the combat log at all (documented Blizzard bug), so nothing else can
-- be captured either.
local GUARDIAN_SPELLS = {
	darkhound  = { { sid = 1264485, school = 32 } }, -- Shadow Thrash (BM)
	darkminion = { { sid = 1264485, school = 32 } }, -- "Blighted Arrow" (MM, same id)
}

-- Hunter pet damage overlaps every player school — a signature would
-- claim the player's own auto-shots and physical nukes. OFF entirely:
-- real pet hits name via consumePetCast (pet token casts) instead.
function mod.petSchoolHit(school, helpers)
	return false
end

function mod.petSchoolHitRecent(self, school, lastPlayerSpellId, helpers)
	return false
end

-- Pet physical eligibility: hunter pets melee constantly, so a school-1
-- hit the player's swing does NOT explain is pet-eligible. Only reached
-- when swingEvidence already ruled out the player's auto.
function mod.petPhysicalHit(school, helpers)
	return helpers and helpers.safeNumber and helpers.safeNumber(school)
		and school == 1
end

-- Survival is the melee spec: pet and player melee lines are
-- indistinguishable there, so evidence stays permissive.
local function isSurvival()
	if not GetSpecialization then return false end
	return GetSpecialization() == 3
end

-- Auto-attack line restriction: BM/MM auto-shots produce RANGE_DAMAGE
-- lines while pet melee produces SWING_DAMAGE. Restricting auto claims
-- to ranged frees melee lines for pet-melee naming. SV keeps the
-- default (its own swings are melee too).
function mod.autoLineKinds(helpers)
	if isSurvival() then return nil end
	return { ranged = true }
end

-- Swing evidence via palette peek: a ranged line near the hit means
-- the player's shot explains it (auto). A melee line with no ranged
-- line means a pet swung — not the player's swing. Neither buffered
-- yet: nil = permissive (the deferred veto applies autoLineKinds then).
function mod.swingEvidence(self, t, helpers)
	if isSurvival() then return nil end
	local zbt = ZSBT.ZBattleText
	if not (zbt and zbt.PeekDamageLine) then return nil end
	if zbt:PeekDamageLine(t, 1.0, { ranged = true }) then return true end
	if zbt:PeekDamageLine(t, 1.0, { melee = true }) then return false end
	return nil
end

-- Name physical pet hits "Auto Attack" (6603) when the user opts in.
-- Same contract as warlock: the hit must claim a MY_PET palette line
-- first, so the name can only land on palette-proven pet damage.
-- profile.classModule.namePetMelee (Class page toggle), default off.
function mod.resolvePetMelee(self, helpers)
	local cm = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.classModule
	if cm and cm.namePetMelee == true then return 6603 end
	return nil
end

-- Guardian spellbook resolution: same exactly-one-match rule as warlock.
-- Currently has no non-physical entries, so this names nothing until
-- verified guardian damage ids are added above.
function mod.resolvePetSpellId(self, school, t, helpers)
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
	if ambiguous then return nil end
	return best
end

-- Channel seeding (Rapid Fire / Fury of the Eagle) + guardian windows.
function mod.onCast(self, spellId, spellName, t)
	local ch = ZSBT.ClassDB.ChannelMatch(spellId)
	if ch then
		self._channel = {
			untilAt = t + (ch.duration or 2.0),
			lastTickAt = 0,
			spellId = spellId,
			tickMin = ch.tickMin or 0.12,
		}
	end
	local summon = GUARDIAN_SUMMONS[spellId]
	if summon then
		self._guardianUntil = self._guardianUntil or {}
		for _, g in ipairs(summon) do
			self._guardianUntil[g.group] = t + g.duration
		end
	end
	-- Black Arrow (Dark Ranger, cast id varies) can proc a Dark Minion
	-- via Corpsecaller — open its window on every cast.
	if spellName == "Black Arrow" then
		self._guardianUntil = self._guardianUntil or {}
		self._guardianUntil["darkminion"] = t + 20
	end
end

ZSBT.ClassDB.Register("HUNTER", mod)
return mod
