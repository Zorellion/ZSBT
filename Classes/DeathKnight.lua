-- Classes/DeathKnight.lua — Death Knight-specific combat attribution
--
-- Physical ambiguity: DK is a melee class — player and ghoul damage are
-- BOTH heavily school-1 (Obliterate, autos vs ghoul melee/Claw). The
-- hunter ranged/melee palette split does not apply (everything is
-- melee lines), so the old family-gated school-1 signature is OFF:
-- it would claim player physical as ghoul damage. Named pet damage
-- comes from real pet cast records (the Unholy ghoul is a permanent
-- "pet" unit: Claw, Sweeping Claws) and opt-in MY_PET-proven melee
-- naming; summon-window physical still displays unnamed via the
-- legacy guardian-wound emit below.

local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

mod.dots = {
	{ names = { "Frost Fever" },           ids = { 55095 },   school = 16 },
	{ names = { "Blood Plague" },          ids = { 55078 },   school = 32 },
	{ names = { "Virulent Plague" },       ids = { 191587 },  school = 32 }, -- log-verified periodic id
	{ names = { "Dread Plague" },          ids = { 1240996 }, school = 32 }, -- log-verified periodic id
	{ names = { "Trollbane's Icy Fury" },  ids = { 444834 },  school = 48 }, -- Rider proc, player-sourced debuff (log-verified school 0x30)
	{ names = { "Ceaseless Swarm" },       ids = { 450969 },  school = 8 },  -- proc dot, log-verified (117 ticks)
	{ names = { "Spidersting" },           ids = { 452229 },  school = 8 },  -- proc dot, log-verified
	{ names = { "Undeath" },               ids = { 444633 },  school = 48 }, -- proc dot, log-verified school 0x30
}

-- Channeled: Breath of Sindragosa ticks for the channel's duration.
mod.channels = {
	{ names = { "Breath of Sindragosa" }, ids = { 152279 }, duration = 12.0, tickMin = 0.4 },
}

-- Per-cast-instance naming budget: AoE/multi-hit casts may name several
-- hits; single-target stays at 1. Ids are best-known pre-Midnight —
-- verify against a Forever/retail DK combat log; wrong ids simply
-- never match (safe under-naming).
mod.castBudget = {
	[43265]  = 15, -- Death and Decay (ground AoE ticks)
	[52212]  = 15, -- Death and Decay (tick damage id, if cast records land on it)
	[196770] = 10, -- Remorseless Winter (cast id)
	[196771] = 10, -- Remorseless Winter (log-verified damage id)
	[49184]  = 8,  -- Howling Blast
	[207230] = 8,  -- Frostscythe
	[279302] = 6,  -- Frostwyrm's Fury
	[50842]  = 8,  -- Blood Boil
	[206930] = 5,  -- Heart Strike (cleaves up to 5)
	[460501] = 5,  -- Heart Strike, second id (log-verified)
	[433895] = 5,  -- Vampiric Strike (San'layn, log-verified)
	[207317] = 8,  -- Epidemic
	[194844] = 8,  -- Bonestorm
	[195975] = 6,  -- Glacial Advance (line AoE, log-verified)
	[1242178] = 5, -- Necrotic Coil (shadow, log-verified)
	[1242172] = 5, -- Necrotic Coil (shadow+physical, log-verified)
	[390220] = 5,  -- Putrefy (log-verified)
	[1277016] = 5, -- Putrefy, second id (log-verified)
	[152279] = 10, -- Breath of Sindragosa (fallback; channel usually catches it)
}

-- Player summon casts → guardian activity windows. Ids verified on
-- Grimbook's combat log (Rider of the Apocalypse, 2026-11-19).
local GUARDIAN_SUMMONS = {
	[52150]  = { { group = "ghoul",     duration = 60 } }, -- Raise Dead (verified)
	[46584]  = { { group = "ghoul",     duration = 60 } }, -- Raise Dead (legacy id)
	[46585]  = { { group = "ghoul",     duration = 60 } }, -- Raise Dead (legacy id)
	[42650]  = { { group = "army",      duration = 30 },
		{ group = "magus", duration = 15 },
		{ group = "horsemen", duration = 30 } },            -- Army of the Dead (+Magus +Riders)
	[444251] = { { group = "horsemen",  duration = 30 } }, -- Summon Whitemane (Rider proc)
	[444254] = { { group = "horsemen",  duration = 30 } }, -- Summon Trollbane (log-verified)
	[444252] = { { group = "horsemen",  duration = 30 } }, -- Summon Nazgrim (log-verified)
	[444248] = { { group = "horsemen",  duration = 30 } }, -- Summon Mograine (log-verified)
	[288853] = { { group = "ghoul",     duration = 60 } }, -- Raise Abomination (log-verified)
	[317776] = { { group = "magus",     duration = 15 } }, -- Army of the Damned proc summon (log-verified)
	[1242294] = { { group = "magus",    duration = 15 } }, -- Army of the Damned, second id (log-verified)
	[1292072] = { { group = "army",     duration = 15 },
		{ group = "magus", duration = 15 } },               -- Lord of the Dead (log-verified summon)
	[275699] = { { group = "apoc",      duration = 15 } }, -- Apocalypse (modern id)
	[220143] = { { group = "apoc",      duration = 15 } }, -- Apocalypse (older id)
	[63560]  = { { group = "darktrans", duration = 15 },
		{ group = "magus", duration = 15 } },               -- Dark Transformation (+Magus)
	[49206]  = { { group = "gargoyle",  duration = 30 } }, -- Summon Gargoyle
	[81256]  = { { group = "drw",       duration = 20 } }, -- Dancing Rune Weapon (log-verified)
	[49028]  = { { group = "drw",       duration = 20 } }, -- Dancing Rune Weapon, second id (log-verified)
	[1237128] = { { group = "drw",      duration = 20 } }, -- Dancing Rune Weapon, third id (log-verified)
}

-- Class-module UI toggles this module supports.
mod.guardianLabel = "ghouls, magi, or the four horsemen"
mod.toggles = {
	namePetMelee = true,
	resolveGuardians = true,
}

-- Non-physical guardian spellbook. Multiple entries per school make a
-- hit ambiguous (one-match rule -> nil) rather than misnamed. Physical
-- guardian damage (Army/Apocalypse ghoul melee, Bloodworm) has no
-- entries — unnameable by design, same as every other class.
local GUARDIAN_SPELLS = {
	gargoyle  = {
		{ sid = 51963,  school = 48 }, -- Gargoyle Strike (shadowfrost, verify)
		{ sid = 51963,  school = 32 }, -- Gargoyle Strike (shadow, older clients)
	},
	magus     = {
		{ sid = 317791, school = 32 }, -- Shadow Bolt (log-verified)
		{ sid = 1292107, school = 16 }, -- Frostbolt (log-verified; wowhead's 317792 never fired)
	},
	darktrans = {
		{ sid = 1278150, school = 32 }, -- Sweeping Claws (log-verified dominant id; 91778 also fires)
	},
	-- Dancing Rune Weapon: window tracked but spellbook intentionally empty.
	-- Log-verified mirrors: Heart Strike 228645 + Death Strike 49998/45470
	-- (school 1, unnameable), Death's Caress 195292 + Blood Plague 55078
	-- (both school 32 -> two candidates -> ambiguous under one-match).
	drw       = {},
	horsemen  = {
		{ sid = 445513, school = 32 }, -- Whitemane's Death Coil (log-verified)
		-- Nazgrim's Scourge Strike shadow component (445509, school 32) is
		-- deliberately NOT listed: it shares school 32 with Whitemane's DC in
		-- the same window, which would make both ambiguous under the
		-- one-match rule. Its physical component (445508, school 1) is
		-- unnameable like all guardian physical damage.
	},
}
mod.guardianSummons = GUARDIAN_SUMMONS
mod.guardianSpells = GUARDIAN_SPELLS

-- School signature OFF: DK player and ghoul damage share school-1 (and
-- player shadow overlaps ghoul Sweeping Claws). Naming comes from cast
-- records and the windows above instead. NOTE: the previous
-- family-gated school-1 claim risked routing the player's own physical
-- hits into the pet bucket on Unholy (ghoul always up) — same bug
-- class as the original hunter stub.
function mod.petSchoolHit(school, helpers)
	return false
end

function mod.petSchoolHitRecent(self, school, lastPlayerSpellId, helpers)
	return false
end

-- Pet physical eligibility: only when a ghoul-family pet is actually
-- present (Unholy permanent ghoul or a recent summon), so Blood/Frost
-- player physical never pet-routes.
function mod.petPhysicalHit(school, helpers)
	if not (helpers and helpers.safeNumber and helpers.safeNumber(school)) then
		return false
	end
	if school ~= 1 then return false end
	local fam = helpers.family and helpers.family() or nil
	return fam ~= nil and fam:find("ghoul", 1, true) ~= nil
end

-- Name physical pet hits "Auto Attack" (6603) when the user opts in —
-- MY_PET palette line still required, so the name only lands on
-- proven ghoul swings.
function mod.resolvePetMelee(self, helpers)
	local cm = ZSBT.db and ZSBT.db.profile and ZSBT.db.profile.classModule
	if cm and cm.namePetMelee == true then return 6603 end
	return nil
end

-- Guardian spellbook resolution: exactly-one-match rule (same as
-- warlock/hunter). Shadow-32 hits inside overlapping darktrans+magus
-- windows match two sids -> ambiguous -> nil (generic rather than
-- wrong name).
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

-- Channel seeding (Breath of Sindragosa) + guardian windows + the
-- legacy summon timestamp the ported guardian-wound block uses.
local GHOUL_SUMMONS = { [46584] = true, [46585] = true, [42650] = true }
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
	if type(spellId) == "number" and GHOUL_SUMMONS[spellId] then
		self._dkGhoulSummonAt = t
	end
	-- Dark Transformation's cast id varies by client build — key on name
	-- (same approach as hunter's Black Arrow) so the empowered-ghoul
	-- and Magus windows always open.
	if spellName == "Dark Transformation" then
		self._guardianUntil = self._guardianUntil or {}
		self._guardianUntil["darktrans"] = t + 15
		self._guardianUntil["magus"] = t + 15
	end
end

-- Unattributed physical hit after a recent ghoul summon -> guardian pet damage.
-- Ported verbatim from Event_Collector's inline DK guardian block.
function mod.onGuardianWound(self, ctx)
	local t = ctx.t
	local amount = ctx.amount
	local isCrit = ctx.isCrit
	local school = ctx.school
	local restrict = ctx.restrict
	local members = ctx.members
	local dl = ctx.dl
	local emit = ctx.emit
	local safeUnitName = ctx.safeUnitName
	local petSchoolHit = ctx.petSchoolHit
	local dedupWindow = ctx.dedupWindow
	local ECPrint = ctx.ecPrint
	local dbgSafe = ctx.dbgSafe
	local IsSafeNumber = ZSBT.IsSafeNumber

	if not (IsSafeNumber(school) and school == 1) then return false end
	local summonedAt = self._dkGhoulSummonAt
	if type(summonedAt) ~= "number" then return false end
	local ageSummon = t - summonedAt
	if not (ageSummon >= 0 and ageSummon <= 45.0) then return false end
	if not (IsSafeNumber(amount) and amount > 0 and amount <= 3000) then return false end
	local ageCast = nil
	if type(self._lastPlayerSpellAt) == "number" then
		ageCast = t - self._lastPlayerSpellAt
	end
	-- Avoid grabbing the immediate landing of a just-cast physical ability.
	if type(ageCast) == "number" and ageCast >= 0 and ageCast <= 0.15 then
		return false
	end
	-- Group-aware gate for guardian pets.
	if restrict == true and members and members > 1 then
		if not petSchoolHit(school) then
			if dl >= 4 then
				ECPrint(("PET_GUARDIAN_GROUP_SUPPRESS restrict=%s members=%s amt=%s")
					:format(dbgSafe(restrict), dbgSafe(members), dbgSafe(amount)))
			end
			return true
		end
	end
	-- Dedup against the main pet fallback and chat pet lines.
	local lastPetFb = self._lastPetFallbackAt or 0
	local lastPetChat = self._lastPetChatAt or 0
	if (t - lastPetFb) >= 0 and (t - lastPetFb) < dedupWindow then
		return true
	end
	if (t - lastPetChat) >= 0 and (t - lastPetChat) < dedupWindow then
		return true
	end
	self._lastPetFallbackAt = t
	local pipeId = self._rawPipeCount + 1
	if self._rawPipe and self._rawPipe[pipeId] ~= nil then
		local i = pipeId
		while self._rawPipe[i] ~= nil do
			i = i + 1
		end
		pipeId = i
	end
	self._rawPipeCount = pipeId
	self._rawPipe[pipeId] = amount
	if dl >= 4 then
		ECPrint(("PET_GUARDIAN_EMIT class=DK token=%s rawPipeId=%s amt=%s school=%s")
			:format(dbgSafe(self._castToken), dbgSafe(pipeId), dbgSafe(amount), dbgSafe(school)))
	end
	emit("PET_DAMAGE_COMBAT", {
		timestamp = t,
		rawPipeId = pipeId,
		amount = amount,
		amountText = tostring(amount),
		isCrit = isCrit,
		petBucket = nil,
		schoolMask = 1,
		targetName = safeUnitName("target"),
	})
	return true
end

ZSBT.ClassDB.Register("DEATHKNIGHT", mod)
return mod
