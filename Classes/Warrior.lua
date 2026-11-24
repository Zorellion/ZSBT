-- Classes/Warrior.lua — Warrior-specific combat attribution
--
-- Warrior is the pure-physical baseline: no permanent pet, no guardian
-- summons, nearly every hit school-1. That means:
--
--   * Physical periodic ticks CANNOT be school-matched — a school-1 WOUND
--     is indistinguishable from a melee swing. Rend survives because it
--     ships a dedicated amount-pattern classifier (onPhysicalWound,
--     ported verbatim from Event_Collector's inline state machine).
--     Deep Wounds claims via deepWoundsWound (debuff-gated cadence +
--     swing-prediction veto below). Thunderous Roar bleeds and other
--     school-1 procs have no equivalent and stay generic — honest
--     floor, same as guardian physical on other classes.
--   * No guardian windows. Ravager is PLAYER-sourced on the verified
--     client; the talented button (cast id 1235113) is covered by the
--     cast budget + cast-seeded tick window (ravagerWound). The
--     Whirling Blade proc variant emits no cast, no summon, and its
--     debuff is a secret aura — verified unattributable, stays
--     generic like Devastator/Phalanx.
--   * mod.toggles stays empty: there is no pet melee to name and no
--     guardian spellbook to resolve, so the Class page shows no
--     class toggles.
--
-- Thunderous Roar is deliberately NOT in mod.dots: cast id == damage
-- id, and a dots entry would seed it as periodic, which can misroute
-- its own direct hit (the Blood Boil lesson on DK). Same rule keeps
-- every Fury bleed out: Cold Steel Hot Blood, Odyn's Fury bleed,
-- Gushing Wound — all school-1, all unnameable regardless.
--
-- Fury notes: multi-strike buttons carry budgets (Rampage, Raging
-- Blow, Crushing Blow, Bloodbath, Annihilator, Onslaught, Odyn's
-- Fury). Single-hit buttons (Execute incl. Sudden Death, Bloodthirst,
-- Storm Bolt) pair through the normal cast path — no budget needed.
-- Slayer's Strike / Lightning Strike procs have no cast record —
-- generic floor, same as Devastator.

local ADDON_NAME, ZSBT = ...
if not ZSBT or not ZSBT.ClassDB then return end

local mod = {}

local RAVAGER_CAST_SID = 1235113
local RAVAGER_TICK_SID = 156287
local RAVAGER_WINDOW = 12.5

mod.dots = {
	{ names = { "Rend" },         ids = { 772, 388539 }, school = 1 }, -- 772=cast, 388539=log-verified tick/aura sid
	{ names = { "Thunder Clap" }, ids = { 6343 },   school = 1 }, -- bleed rider, physical
	{ names = { "Deep Wounds" },  ids = { 262115, 262111 }, school = 1 }, -- mastery proc, never cast directly; 262115 = log-verified tick/aura sid
}

-- Channeled: Bladestorm ticks every ~1s for the channel duration. Auto
-- attacks are suppressed while channeling, so the window can't eat a
-- player swing. Ravager is NOT here: its damage comes from the weapon
-- NPC (guardian physical), not a player channel.
mod.channels = {
	-- 227847 = base cast; 446035 = Unrelenting Onslaught replacement
	-- (web + log verified). Tick damage sid is 50622 — named via the
	-- spellbook-derived dot path, not the channel.
	{ names = { "Bladestorm" }, ids = { 227847, 446035 }, duration = 6.0, tickMin = 0.6, school = 1 },
	-- Demolish (Colossus key talent): 2s channel, ~100ms periodic
	-- triggers + 3 strikes + 10yd AoE.
	{ names = { "Demolish" },   ids = { 436358 }, duration = 2.0, tickMin = 0.05, school = 1 },
	-- Ravager: player-sourced ticks (156287) every ~1-2s for ~12s —
	-- effectively a channel the weapon runs for you. Cast 228920 opens
	-- the window; tick lines claim inside it. Autos (melee lines) are
	-- safe: the channel claims tick-kind lines only.
	-- Ravager is NOT here: it fires with no SPELL_CAST_SUCCESS on this
	-- client (verified on the prot log), so a channel window would never
	-- open. Its ticks are caught by the debuff-gated classifier below.
}

-- Per-cast-instance naming budget: AoE/multi-hit casts may name several
-- hits; single-target stays at 1. Ids are best-known pre-Midnight —
-- verify against a real warrior combat log; wrong ids simply never
-- match (safe under-naming). Manual teaching fills any drift.
mod.castBudget = {
	[1680]   = 12, -- Whirlwind cast id (log-verified: emits double cast records)
	[199658] = 10, -- Whirlwind second cast id (log-verified; dmg ids 199658/199850/411547)
	[190411] = 12, -- Whirlwind Fury cast id (log-verified; shared dmg family)
	[845]    = 6,  -- Cleave (frontal cleave)
	[262161] = 10, -- Warbreaker (Arms AoE CS replacement — one hit per target)
	[6343]   = 10, -- Thunder Clap (AoE direct; bleed is unnameable)
	[435222] = 10, -- Thunder Blast (Mountain Thane TC replacement, log-verified)
	[46968]  = 10, -- Shockwave (cone AoE)
	[6572]   = 10, -- Revenge (frontal AoE, log-verified)
	[385952] = 5,  -- Shield Charge cast id (damage id 385954, drift log-verified)
	[118000] = 10, -- Dragon Roar
	[397364] = 10, -- Thunderous Roar (direct AoE; bleed is unnameable)
	[6544]   = 10, -- Heroic Leap (landing AoE; sb-verified cast id)
	[227847] = 8,  -- Bladestorm (fallback; channel usually catches it)
	[184367] = 10, -- Rampage (log-verified: 4 strikes dmg ids 201363/201364/184707/184709, +cleave)
	[315720] = 6,  -- Onslaught (multi-strike Fury; verify)
	[385059] = 8,  -- Odyn's Fury cast 1 (log-verified: one cast record per component)
	[385060] = 8,  -- Odyn's Fury cast 2 (log-verified)
	[385061] = 8,  -- Odyn's Fury Off-Hand cast (log-verified)
	[385062] = 8,  -- Odyn's Fury cast 3 (log-verified)
	[85288]  = 8,  -- Raging Blow (2 strike components; Meat Cleaver can cleave)
	[5308]   = 5,  -- Execute (log-verified: Fury strikes MH+OH — dmg 280849 + Execute Off-Hand 163558)
	[335097] = 8,  -- Crushing Blow (empowered Raging Blow; verify id)
	[335096] = 6,  -- Bloodbath (empowered Bloodthirst; verify id)
	[383917] = 6,  -- Annihilator (talent replacing Raging Blow; verify id)
	[376079] = 8,  -- Spear of Bastion (if still in kit; verify)
	-- Ravager button cast id (user-verified 1235113). The throw damage
	-- (228920) pairs via this budget; the cast also opens the 12s
	-- ravagerWound window that names periodic ticks (156287).
	-- The Whirling Blade proc variant produces no cast and is
	-- unattributable — see the classifier comment below.
	[1235113] = 8,
}

-- Provable damage schools for the kit (masks observed on player-owned
-- lines): 1 physical, 8 nature (Lightning Strike, Ground Current,
-- Thorn Bloom), 9 physical|nature (Thunder Blast). An unattributed hit
-- carrying any other school is provably foreign — follower/party
-- damage on a shared target — and ClassDB.SchoolAllowed vetoes it
-- before it can queue for a palette line. School-1 generics stay
-- ambiguous by design (follower melee is indistinguishable from ours).
mod.schools = { [1] = true, [8] = true, [9] = true }

-- No pet spells to match, no pet physical damage — warrior has no
-- permanent or controllable pet.
function mod.petSchoolHit(school, helpers)
	return false
end

function mod.petSchoolHitRecent(self, school, lastPlayerSpellId, helpers)
	return false
end

function mod.petPhysicalHit(school, helpers)
	return false
end

-- The module supports no class toggles: nothing to name for pets or
-- guardians. ClassDB.SupportsToggle() hides every toggle on the page.
mod.toggles = {}

-- Applicators: Fury applies via Execute (Executioner's Wrath proc). Arms
-- Mastery applies on most direct strikes — Mortal Strike, Cleave, Colossus
-- Smash/Warbreaker, Bladestorm, Execute. A non-applying cast in the set
-- still seeds harmlessly: cadence/streak evidence gates every claim.
local DW_APPLICATOR_SIDS = {
	[5308]    = true, -- Execute (Fury cast id — Executioner's Wrath)
	[281000]  = true, -- Execute (Arms cast id — log-verified applier)
	[12294]   = true, -- Mortal Strike (Arms Mastery applier)
	[845]     = true, -- Cleave (Arms Mastery applier)
	[167105]  = true, -- Colossus Smash (Arms Mastery applier)
	[262161]  = true, -- Warbreaker (CS replacement; Mastery applier)
	[227847]  = true, -- Bladestorm (Mastery applier)
	[446035]  = true, -- Bladestorm (Unrelenting Onslaught variant)
	[1269383] = true, -- Heroic Strike (log-verified: DW apply same-frame)
	[436358]  = true, -- Demolish (Colossus — strikes plausibly apply)
}

-- Cast seeding: Rend cast starts tick tracking; Bladestorm opens the
-- channel window.
local function isRendSpell(spellId)
	local e = ZSBT.ClassDB.DotEntry and ZSBT.ClassDB.DotEntry(spellId)
	return e ~= nil and e._canon == "Rend"
end

function mod.onCast(self, spellId, spellName, t)
	-- Applicator casts tracked separately: _lastPlayerSpellId gets
	-- overwritten by periodic-trigger casts (Bladestorm ticks arrive as
	-- 50622 cast events) between the applicator cast and its wound, so
	-- the seed must not read the shared field.
	if DW_APPLICATOR_SIDS[spellId] == true then
		self._dwAppAt = t
		self._dwAppSid = spellId
	end
	if isRendSpell(spellId) then
		self._rendSpellId = spellId
		self._rendLastCastAt = t
		self._rendNextTickAt = t + 3.0
		self._rendInitialHitAmt = nil
		self._rendTickState = nil
	end
	local ch = ZSBT.ClassDB.ChannelMatch(spellId)
	if ch then
		self._channel = {
			untilAt = t + (ch.duration or 2.0),
			lastTickAt = 0,
			spellId = spellId,
			tickMin = ch.tickMin or 0.12,
			school = ch.school,
		}
	end
	if spellId == RAVAGER_CAST_SID then
		-- Talented Ravager button: the only observable signal on this
		-- client. Opens the tick window ravagerWound claims against.
		self._ravWinUntil = t + RAVAGER_WINDOW
		self._ravTickAt = nil
	end
end

-- Matched-physical seeding: a physical WOUND correlated to a Rend cast
-- also (re)seeds the tick clock with the observed amount.
function mod.onMatchedPhysical(self, spellId, t, amount)
	if isRendSpell(spellId) then
		self._rendSpellId = spellId
		self._rendLastCastAt = t
		self._rendNextTickAt = t + 3.0
		self._rendInitialHitAmt = amount
		self._rendTickState = nil
	end
end

local function ravAudit(msg)
	local ZB = ZSBT.ZBattleText
	if ZB and ZB.FileLog then
		ZB:FileLog(msg)
	end
end

-- Rend tick classifier. Timing-only: wound amounts are secrets on this
-- client (sv=true on every rendered value), so the old amount-consistency
-- machinery could never run. mod.onCast seeds the window on a Rend cast
-- (cast sid 772; tick sid 388539). Beats roll at a learned interval —
-- nominal ~2.45s on this build (haste-scaled from the 3.0s classic
-- cadence). First on-beat wound observes, second claims; debuff presence
-- upgrades beat 1 to a claim. Same architecture as deepWoundsWound.
local REND_TICK_NOMINAL = 2.45
local REND_FIRST_TICK   = 2.45
local REND_BLEED_LIFE   = 15.5  -- Rend duration; recasts re-seed the clock
local REND_SLACK        = 0.50  -- learned interval absorbs per-player haste

function mod.onPhysicalWound(self, ctx)
	local t = ctx.t
	local amount = ctx.amount
	local isCrit = ctx.isCrit
	local actionStr = ctx.actionStr
	local emit = ctx.emit
	local safeUnitName = ctx.safeUnitName
	local IsSafeNumber = ZSBT.IsSafeNumber

	if actionStr ~= "WOUND" then return end
	if self._lastDotEmitAt == t or self._ravClaimAt == t then return end
	-- Arms 2H swings (~3.0s) sit directly on Rend's cadence — the swing
	-- veto keeps melee out of the bleed name.
	local swv = ctx.swingPredicted and ctx.swingPredicted(t) == true or false
	if swv then return end

	local st = self._rendTick
	if type(st) ~= "table" then
		st = { nextAt = 0, lastAt = 0, interval = REND_TICK_NOMINAL, seen = 0, castAt = 0 }
		self._rendTick = st
	end

	-- Seed: mod.onCast stamps _rendLastCastAt on a Rend cast. Recasts
	-- re-seed — a refresh restarts the tick clock too.
	local rAt = self._rendLastCastAt
	if type(rAt) == "number" and rAt <= t and rAt > (st.castAt or 0) then
		st.castAt = rAt
		st.nextAt = rAt + REND_FIRST_TICK
		st.lastAt = 0
		st.seen = 0
		st.interval = REND_TICK_NOMINAL
		ravAudit(("REND seed lat=%.3f sid=%s"):format(rAt, ctx.dbgSafe(self._rendSpellId)))
	end
	if st.nextAt <= 0 then return end
	if (t - st.castAt) > REND_BLEED_LIFE then
		st.nextAt = 0
		return
	end

	local debuffOk = ctx.hasTargetDebuff and ctx.hasTargetDebuff(self._rendSpellId or 772) == true
	local dt = t - st.nextAt
	if dt < -REND_SLACK or dt > REND_SLACK then return end

	-- On-beat wound: learn the interval from consecutive beats, then
	-- roll the prediction one tick forward.
	local beatDt = t - (st.lastAt or 0)
	if st.lastAt > 0 and beatDt >= 1.8 and beatDt <= 3.6 then
		st.interval = beatDt
	end
	st.lastAt = t
	st.nextAt = t + st.interval
	st.seen = (st.seen or 0) + 1
	if debuffOk == true then
		st.seen = st.seen + 1
	end
	if st.seen < 2 then
		ravAudit(("REND observe dt=%.2f"):format(dt))
		return
	end

	self._lastDotEmitAt = t
	self._lastDotEmitSpellId = self._rendSpellId or 772
	local tName = safeUnitName("target")
	local pipeId = self._rawPipeCount + 1
	self._rawPipeCount = pipeId
	self._rawPipe[pipeId] = amount
	emit("OUTGOING_DAMAGE_COMBAT", {
		timestamp = t,
		rawPipeId = pipeId,
		amount = amount,
		amountText = (IsSafeNumber(amount) and tostring(amount)) or nil,
		spellId = self._rendSpellId or 772,
		amountSource = "UNIT_COMBAT_DOT",
		targetName = tName,
		isCrit = isCrit,
		isPeriodic = true,
		schoolMask = 1,
	})
	self._lastOutgoingCombatAt = t
	self._lastOutgoingCombatTargetName = tName
	ravAudit(("REND claim dt=%.2f debuff=%s seen=%s"):format(
		dt, tostring(debuffOk), tostring(st.seen)))
end

-- Ravager tick classifier. Two sources exist on this client:
--
--   * Talented button (cast id 1235113): SPELL_CAST_SUCCESS fires →
--     onCast opens _ravWinUntil. Ticks claim inside that window.
--   * Whirling Blade talent proc: produces NO observable signal — no
--     cast in the combat log, no UNIT_SPELLCAST_SUCCEEDED, no summon,
--     and its "Ravaged" debuff is an unreadable secret aura. Verified
--     unattributable on this client; stays generic with the other
--     proc-damage floor (Devastator, Phalanx, Lightning Strike).
--
-- While the window is open, ticks are a stable ~2.0s school-1 cadence:
-- a wound landing 1.8-2.4s after the last claimed tick takes the name.
-- The first tick anchors and stays generic by design.
local function ravagerWound(self, ctx)
	local t = ctx.t
	local amount = ctx.amount
	local isCrit = ctx.isCrit
	local actionStr = ctx.actionStr
	local safeUnitName = ctx.safeUnitName
	local emit = ctx.emit
	local IsSafeNumber = ZSBT.IsSafeNumber

	if actionStr ~= "WOUND" then return end
	local winUntil = self._ravWinUntil
	if type(winUntil) ~= "number" or t > winUntil then
		if self._ravTickAt ~= nil then
			self._ravTickAt = nil
			ravAudit("RAVWIN close")
		end
		return
	end
	local last = self._ravTickAt
	if type(last) ~= "number" then
		-- No anchor yet: mark the window so the NEXT hit at tick
		-- cadence can claim. First tick stays generic by design.
		self._ravTickAt = t
		ravAudit("RAVWIN open")
		return
	end
	local dt = t - last
	if dt < 1.8 then return end
	if dt > 2.4 then
		-- Anchor expired without a claim inside a live window.
		-- Re-anchor so the next in-cadence hit can claim — without this
		-- the classifier went permanently dead after one overshoot.
		self._ravTickAt = t
		ravAudit(("RAV reanchor dt=%.2f"):format(dt))
		return
	end
	self._ravTickAt = t
	self._ravClaimAt = t
	ravAudit(("RAV claim dt=%.2f"):format(dt))
	local pipeId = self._rawPipeCount + 1
	self._rawPipeCount = pipeId
	self._rawPipe[pipeId] = amount
	local tName = safeUnitName("target")
	emit("OUTGOING_DAMAGE_COMBAT", {
		timestamp = t,
		rawPipeId = pipeId,
		amount = amount,
		amountText = (IsSafeNumber(amount) and tostring(amount)) or nil,
		spellId = RAVAGER_TICK_SID,
		amountSource = "UNIT_COMBAT_DOT",
		targetName = tName,
		isCrit = isCrit,
		isPeriodic = true,
		schoolMask = 1,
	})
	self._lastOutgoingCombatAt = t
	self._lastOutgoingCombatTargetName = tName
end

-- Deep Wounds tick classifier (tick/aura sid 262115, log-verified).
-- DW is a mastery proc: it is never cast, so no cast record can seed it.
-- The substitute bootstrap is the player's own debuff on target
-- (HARMFUL|PLAYER — only OUR application counts). With the debuff live,
-- ticks are a stable ~3s school-1 cadence (haste-scaled; ~2.7s observed
-- on a fury log). Two structural guards:
--   * ctx.swingPredicted veto: a wound ON the learned own-swing beat is
--     melee, not a tick — swing priority wins or DW would eat the melee
--     stream at unlucky ~3s gaps.
--   * _lastDotEmitAt/_ravClaimAt: a wound already named by the cast-
--     seeded Rend/Ravager classifiers can't be re-emitted as DW.
-- Amount is a soft reference: DW ticks repeat a stable per-application
-- value; a mismatched wound re-anchors (it, or the old anchor, was an
-- interloper) rather than claiming or teaching. First debuff-gated
-- wound only anchors — same first-tick-stays-generic rule as Ravager.
-- Limit: only the CURRENT target's debuff gates claims, so off-target
-- cleave-spread DW ticks stay generic (same floor as Rend's classifier).
local DW_TICK_SID = 262115
-- Log-verified (Nov 2026 dummy): Executioner's Wrath Deep Wounds ticks
-- every ~1.0s for ~6s — NOT the classic 3s bleed. Applicator is
-- Execute (5308): every observed 262115 apply lands same-frame as an
-- Execute cast. Amounts are secret on this client (sv=true on every
-- rendered value), so this classifier is timing-only: applicator seed
-- + on-beat cadence, debuff presence as an evidence upgrade.
local DW_TICK_NOMINAL = 1.0
local DW_FIRST_TICK = 1.0      -- observed first tick +0.95..+2.0s post-apply
local DW_BLEED_LIFE = 6.8      -- ~5-6 ticks then the bleed is done
local DW_SLACK = 0.30

local function deepWoundsWound(self, ctx)
	local t = ctx.t
	local amount = ctx.amount
	local isCrit = ctx.isCrit
	local actionStr = ctx.actionStr
	local emit = ctx.emit
	local safeUnitName = ctx.safeUnitName
	local IsSafeNumber = ZSBT.IsSafeNumber

	if actionStr ~= "WOUND" then return end
	if self._lastDotEmitAt == t or self._ravClaimAt == t then return end

	local st = self._dwTick
	if type(st) ~= "table" then
		st = { anchor = 0, nextAt = 0, seen = 0, debuff = false }
		self._dwTick = st
	end
	-- Diagnostic (temporary): one record per 2s proves the hook runs and
	-- exposes which gate rejects — swing veto, unarmed anchor, or a
	-- lastPlayerSpellId that is not what the seed expects.
	local swv = ctx.swingPredicted and ctx.swingPredicted(t) == true or false
	local diagAt = self._dwDiagAt or 0
	if t - diagAt >= 2 then
		self._dwDiagAt = t
		ravAudit(("DW hook app=%s anch=%.1f swv=%s"):format(
			ctx.dbgSafe(self._dwAppSid), st.anchor, tostring(swv)))
	end
	if swv then return end
	-- Applicator seed: a mastery/DW applicator cast opens a ~6s bleed
	-- window (tracked in onCast — the shared last-spell field is
	-- polluted by trigger casts). Non-applying members of the set seed
	-- harmlessly — the observed-beat requirement still gates claims.
	local lat = self._dwAppAt
	if type(lat) == "number" and lat > st.anchor
		and (t - lat) <= 0.5 then
		st.anchor = lat
		st.nextAt = lat + DW_FIRST_TICK
		st.seen = 0
		st.debuff = false
		ravAudit(("DW seed lat=%.3f sid=%s"):format(lat, ctx.dbgSafe(self._dwAppSid)))
	end
	if st.anchor <= 0 then return end
	if (t - st.anchor) > DW_BLEED_LIFE then
		st.anchor = 0
		return
	end
	-- A live 262115 aura upgrades evidence mid-bleed: an on-beat wound
	-- may claim immediately instead of waiting for a prior observed
	-- beat. On clients where hostile auras are unreadable this simply
	-- never fires and the stricter streak rule carries the load.
	if not st.debuff and ctx.hasTargetDebuff(DW_TICK_SID) == true then
		st.debuff = true
	end
	local dt = t - st.nextAt
	if dt < -DW_SLACK then return end
	if dt > DW_SLACK then
		-- Expected beat slipped unclaimed (upstream drop, or a bad
		-- seed): advance at most one missed beat; a wound still
		-- off-beat is an interloper — restart the stream.
		local k = math.floor(dt / DW_TICK_NOMINAL + 0.5)
		if k < 1 or k > 2 then
			st.anchor = 0
			return
		end
		st.nextAt = st.nextAt + k * DW_TICK_NOMINAL
		dt = t - st.nextAt
		if dt > DW_SLACK then
			st.anchor = 0
			return
		end
		st.seen = 0
	end
	st.seen = st.seen + 1
	st.nextAt = st.nextAt + DW_TICK_NOMINAL
	if not st.debuff and st.seen < 2 then
		-- First on-beat wound after an unconfirmed seed is observation,
		-- not claim: timing alone can't separate a real tick from an
		-- interloper until the stream shows a second beat.
		ravAudit(("DW observe dt=%.2f"):format(dt))
		return
	end
	self._lastDotEmitAt = t
	self._lastDotEmitSpellId = DW_TICK_SID
	local pipeId = self._rawPipeCount + 1
	self._rawPipeCount = pipeId
	self._rawPipe[pipeId] = amount
	local tName = safeUnitName("target")
	emit("OUTGOING_DAMAGE_COMBAT", {
		timestamp = t,
		rawPipeId = pipeId,
		amount = amount,
		amountText = (IsSafeNumber(amount) and tostring(amount)) or nil,
		spellId = DW_TICK_SID,
		amountSource = "UNIT_COMBAT_DOT",
		targetName = tName,
		isCrit = isCrit,
		isPeriodic = true,
		schoolMask = 1,
	})
	self._lastOutgoingCombatAt = t
	self._lastOutgoingCombatTargetName = tName
	ravAudit(("DW claim dt=%.2f debuff=%s seen=%d"):format(
		dt, tostring(st.debuff), st.seen))
end

-- onPhysicalWound entry: run the Ravager check BEFORE the Rend block —
-- the Rend classifier early-returns when no Rend cast exists, which is
-- always true for prot/fury, and would starve the Ravager check. Deep
-- Wounds runs last: its evidence (debuff + cadence) is the weakest of
-- the three, so cast-seeded claims name contested wounds first.
local physicalWoundInner = mod.onPhysicalWound
function mod.onPhysicalWound(self, ctx)
	ravagerWound(self, ctx)
	physicalWoundInner(self, ctx)
	deepWoundsWound(self, ctx)
end

ZSBT.ClassDB.Register("WARRIOR", mod)
return mod
