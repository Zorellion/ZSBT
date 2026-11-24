-- Classes/Spellbook.lua — Live spellbook knowledge layer
--
-- Enumerates the player's (and pet's) current spellbook and derives a
-- per-spell knowledge record: name, role (dot/channel/cast), and damage
-- school masks parsed from the spell description. Module tables remain
-- authoritative — the derived layer only fills gaps for spells the
-- active module has not listed, and widens the school whitelist for
-- classes whose module predates their current kit.
--
-- Why: hand-maintained per-class tables rot whenever Blizzard re-ids or
-- reshapes a kit (Midnight re-idded half the warlock book). The
-- spellbook already contains the current id for every known spell, and
-- the description carries enough structure ("every N sec", "channeled",
-- "Fire damage") to derive most of what the tables hand-encode. What it
-- cannot provide stays manual: per-cast hit budgets, pet-family rules,
-- proc/trinket effects that never appear in the book, and anything a
-- combat wound could carry — the wound is anonymous either way.
--
-- Locale caveat: role/school parsing keys off localized text. Where the
-- global strings or description patterns don't resolve, the entry
-- degrades to role "cast" with no schools — strictly additive-safe,
-- never a regression versus module tables alone.

local ADDON_NAME, ZSBT = ...
if not ZSBT then return end

local Spellbook = {}
ZSBT.Spellbook = Spellbook

Spellbook._entries = {}   -- [spellId] = { name, role, duration, tickMin, masks = {m1,...} }
Spellbook._byName = {}    -- [name] = spellId
Spellbook._pairs = {}     -- [talentSid] = bookSid — same-name empowerment twins
Spellbook._links = {}     -- [triggerSid] = { [procSid] = "strong"|"mention" }
Spellbook._masks = {}     -- [mask] = true  (union over all book spells)
Spellbook._petEntries = {}-- [spellId] = { name }
Spellbook._scanned = false

---------------------------------------------------------------------------
-- School-name -> mask map
--
-- Names resolve from localized globals at first use; missing globals are
-- skipped so a client lacking them simply derives no schools. Composite
-- names map to the OBSERVED wound masks, which do not always equal the
-- canonical OR of the base bits (Chaos displays as 127 canonically but
-- Chaos Bolt wounds arrived as 124/0x7c on Retail) — each entry may
-- carry several masks so both variants stay allowed.
---------------------------------------------------------------------------
local SCHOOL_SOURCES = {
	{ global = "STRING_SCHOOL_PHYSICAL",      masks = { 1 } },
	{ global = "STRING_SCHOOL_HOLY",          masks = { 2 } },
	{ global = "STRING_SCHOOL_FIRE",          masks = { 4 } },
	{ global = "STRING_SCHOOL_NATURE",        masks = { 8 } },
	{ global = "STRING_SCHOOL_FROST",         masks = { 16 } },
	{ global = "STRING_SCHOOL_SHADOW",        masks = { 32 } },
	{ global = "STRING_SCHOOL_ARCANE",        masks = { 64 } },
	{ global = "STRING_SCHOOL_HOLYSTRIKE",    masks = { 3 } },
	{ global = "STRING_SCHOOL_FLAMESTRIKE",   masks = { 5 } },
	{ global = "STRING_SCHOOL_DIVINE",        masks = { 6 } },
	{ global = "STRING_SCHOOL_HOLYFIRE",      masks = { 6 } },
	{ global = "STRING_SCHOOL_STORMSTRIKE",   masks = { 9 } },
	{ global = "STRING_SCHOOL_HOLYLIGHTNING", masks = { 10 } },
	{ global = "STRING_SCHOOL_FIRESTORM",     masks = { 12 } },
	{ global = "STRING_SCHOOL_HOLYFROST",     masks = { 18 } },
	{ global = "STRING_SCHOOL_FROSTFIRE",     masks = { 20 } },
	{ global = "STRING_SCHOOL_FROSTSTORM",    masks = { 24 } },
	{ global = "STRING_SCHOOL_HOLYPLAGUE",    masks = { 34 } },
	{ global = "STRING_SCHOOL_SHADOWHOLY",    masks = { 34 } },
	{ global = "STRING_SCHOOL_SHADOWFLAME",   masks = { 36 } },
	{ global = "STRING_SCHOOL_SHADOWFIRE",    masks = { 36 } },
	{ global = "STRING_SCHOOL_SHADOWLIGHTNING", masks = { 40 } },
	{ global = "STRING_SCHOOL_SHADOWSTORM",   masks = { 40 } },
	{ global = "STRING_SCHOOL_SHADOWFROST",   masks = { 48 } },
	{ global = "STRING_SCHOOL_SPELLFIRE",     masks = { 68 } },
	{ global = "STRING_SCHOOL_SPELLSTORM",    masks = { 72 } },
	{ global = "STRING_SCHOOL_SPELLFROST",    masks = { 80 } },
	{ global = "STRING_SCHOOL_SPELLSHADOW",   masks = { 96 } },
	-- Chaos: canonical 127 plus the observed Retail wound mask 124.
	{ global = "STRING_SCHOOL_CHAOS",         masks = { 124, 127 } },
	{ global = "STRING_SCHOOL_COSMIC",        masks = { 127 } },
	{ global = "STRING_SCHOOL_MAGICAL",       masks = { 126 } },
}

-- Periodic clauses that name a resource are generation rhythms, not
-- DoTs — "generates 10 Fury every second" (Blind Fury). Lua patterns
-- have no alternation, so this is a plain word scan.
local RESOURCE_WORDS = {
	"fury", "rage", "energy", "mana", "combo point", "insanity",
	"maelstrom", "essence", "focus", "runic power", "astral power",
	"holy power", "chi", "soul shard", "soul fragment", "pain",
	"maelstrom weapon", "arcane charge", "ebon might",
}
local function namesResource(clause)
	for _, w in ipairs(RESOURCE_WORDS) do
		if clause:find("%f[%a]" .. w .. "%f[%A]") then return true end
	end
	return false
end

local _schoolNames = nil
local function schoolNames()
	if _schoolNames then return _schoolNames end
	_schoolNames = {}
	for _, src in ipairs(SCHOOL_SOURCES) do
		local s = rawget(_G, src.global)
		if type(s) == "string"
			and (ZSBT.IsSafeString == nil or ZSBT.IsSafeString(s))
			and s ~= "" then
			_schoolNames[#_schoolNames + 1] = { name = s, masks = src.masks }
		end
	end
	-- Longest first so "Shadowflame" is consumed before "Shadow"/"Fire"
	-- can double-count inside the same description.
	table.sort(_schoolNames, function(a, b)
		return #a.name > #b.name
	end)
	return _schoolNames
end

---------------------------------------------------------------------------
-- Description parser
--
-- Mirrors ClassDB.InferRole's heuristics (channel > dot > cast) and adds
-- school extraction. English pattern words only; a non-matching locale
-- yields role "cast" + whatever schools matched, which degrades to
-- module-table behavior — never worse than today.
---------------------------------------------------------------------------
-- Tooltip header carries the cast-type label ("Channeled" top-right)
-- even when the description body never says the word — Fel Devastation
-- reads "damage over 2 sec" and scans as a dot on text alone.
local function isChanneledTip(spellId)
	if not (C_TooltipInfo and C_TooltipInfo.GetSpellByID) then return false end
	local ok, data = pcall(C_TooltipInfo.GetSpellByID, spellId)
	if not (ok and type(data) == "table" and type(data.lines) == "table") then return false end
	-- rightText only: the cast-type label sits right-aligned next to
	-- the cast time. Description body lines are leftText — scanning
	-- them lets a passive that mentions "channeling" (Furious Gaze)
	-- claim the channel role.
	-- The cast-type label is its own whole line ("Channeled") — on
	-- this client it sits in leftText with color codes. Whole-line
	-- match after stripping keeps description text ("channeling" in a
	-- sentence) out while surviving color/formatting wrappers.
	for i = 1, math.min(#data.lines, 8) do
		local line = data.lines[i]
		for _, key in ipairs({ "leftText", "rightText" }) do
			local tx = line and line[key]
			-- IsSafeString must gate first: comparing a secret string
			-- to "" errors before the guard can reject it.
			if type(tx) == "string"
				and (ZSBT.IsSafeString == nil or ZSBT.IsSafeString(tx))
				and tx ~= "" then
				local t = tx:lower()
					:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
					:gsub("^%s+", ""):gsub("%s+$", "")
				if t == "channeled" or t == "channel" then return true end
			end
		end
	end
	return false
end

function Spellbook.ParseDesc(desc, spellId)
	if type(desc) ~= "string" then return nil end
	if ZSBT.IsSafeString and not ZSBT.IsSafeString(desc) then return nil end
	if desc == "" then return nil end
	-- Thousands separators are display formatting, not data — "4,289
	-- fire damage" must parse as 4289 or every amount derivation is off
	-- by orders of magnitude.
	local d = (desc:lower()):gsub(",", "")
	local role = "cast"
	-- Summons and self-drains carry periodic language ("deals damage
	-- every 1 sec", "lose 4% of your health every 1 sec") but are not
	-- DoTs: seeding a dot window on Summon Infernal would let every
	-- school-4 stray wear the summon name, and Burning Rush produces no
	-- target wounds at all. Both degrade to "cast" — module tables
	-- (guardianSummons) already own the real behavior.
	local selfDrain = d:find("of your health")
		or d:find("your maximum health")
	-- Channeled spells report a NEGATIVE castTime from GetSpellInfo
	-- (older API convention; kept — harmless when never negative), and
	-- the tooltip header labels channels regardless of body text.
	local chanMs
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
		local ct = ok and type(info) == "table" and tonumber(info.castTime)
		if ct and ct < 0 then chanMs = -ct end
	end
	-- Channel comes only from mechanical sources — the tooltip header's
	-- cast-type label or a negative castTime. A body-text "channel"
	-- mention is usually a passive referencing another spell ("when you
	-- finish channeling Eye Beam" — Furious Gaze), which is not itself
	-- channeled; letting text promote it gives a nil-school passive a
	-- record that can steal ticks inside a real channel window.
	if chanMs or isChanneledTip(spellId) then
		role = "channel"
	-- The role exists to attribute DAMAGE, and the periodic phrase
	-- must modify it. Per clause: "damage" plus a periodic word in
	-- EITHER order counts — real DoTs phrase both ways ("damage over
	-- 12 sec", "every 1 sec it burns for damage") — UNLESS the clause
	-- names a resource, which marks the rhythm as generation
	-- ("generates 10 Fury every second and deals damage" — Blind
	-- Fury's comma-free override text is one clause). A "damage
	-- taken" clause is defensive — but only THAT clause is vetoed;
	-- a real DoT may also buff damage taken (Burning Wound).
	elseif not selfDrain and not d:find("summon") then
		for clause in d:gmatch("[^%.;,]+") do
			local dp = clause:find("damage")
			local pp = clause:find("every") or clause:find("periodic")
				or clause:find("per sec") or clause:find("over")
			if dp and pp then
				-- Direct "damage over/every" is periodic damage even
				-- when the same clause carries a damage-taken rider
				-- ("chaos damage over 15 sec and increasing damage
				-- taken" — Burning Wound). Vetoes only apply to the
				-- indirect match ("damage taken over", "generates
				-- Fury every ... and deals damage").
				local direct = clause:find("damage over")
					or clause:find("damage every")
					or clause:find("damage per sec")
					or clause:find("periodic damage")
				if direct or (not clause:find("damage taken")
					and (dp < pp or not namesResource(clause))) then
					role = "dot"
					break
				end
			end
		end
	end
	-- Tick interval: era/periodic descriptions state it directly
	-- ("every 3 sec", "every 2 seconds", "per second"). This is the
	-- client's own declared cadence — better than any table's guess.
	local interval
	local ivStr = d:match("every (%d+%.?%d*)%s*sec") or d:match("per (%d+%.?%d*)%s*sec")
	if ivStr then
		interval = tonumber(ivStr)
	elseif d:find("every second") or d:find("per second") or d:find("each second") then
		interval = 1
	end
	-- Periodic total + duration: "90 Shadow damage over 18 sec" gives the
	-- expected tick amount (total * interval / duration) BEFORE any tick
	-- is observed — the tooltip bootstraps the learned-amount model.
	-- For direct+periodic spells (Immolate: "60 Fire damage and an
	-- additional 100 Fire damage over 15 sec") the number nearest the
	-- "over" phrase is the periodic total.
	local dotTotal, dotDur
	dotDur = tonumber(d:match("damage[^.]-over (%d+%.?%d*)%s*sec"))
	if dotDur then
		-- Iterate all "N <school> damage...over" matches: a direct+periodic
		-- tooltip ("4618 fire damage and 4289 fire damage over 12 sec") puts
		-- the direct amount first — the periodic total is the number
		-- NEAREST the over-phrase, so the last match wins.
		for num in d:gmatch("(%d+%.?%d*)%s*[%a]*%s*damage[^.]-over") do
			dotTotal = tonumber(num)
		end
	end
	-- Channel duration: negative castTime when present, else the
	-- tooltip's own "over N sec" (Fel Devastation: "damage over 2 sec").
	local duration, tickMin
	if role == "channel" then
		duration = chanMs and math.max(1, math.min(12, chanMs / 1000)) or dotDur or 8
		tickMin = 0.4
	end
	-- School extraction: consume matched names so composite names
	-- ("Shadowflame") don't also emit their base school names. Word
	-- boundaries on both ends — "fire" must not hit "fiery"/"wildfire".
	local masks
	local remaining = " " .. d .. " "
	for _, sn in ipairs(schoolNames()) do
		local plain = sn.name:lower()
		local pat = "%f[%a]" .. plain:gsub("(%W)", "%%%1") .. "%f[%A]"
		-- Per-occurrence veto: a school word feeding "damage taken" is
		-- defensive text, not a wound claim ("reduces arcane damage
		-- taken"). Reject that occurrence; every other context keeps
		-- its vote, so no legitimate mask is ever lost.
		-- Verb/possessive vetoes: "Fire a shot" (Barbed Shot) uses the
		-- school word as the sentence's verb — an article follows, which
		-- a school claim never does ("Fire damage", "fire and shadow"
		-- survive). "Nature's Ally" embeds the word in a possessive.
		local pos, accepted = 1, false
		while not accepted do
			local s, e = remaining:find(pat, pos)
			if not s then break end
			local after = remaining:sub(e + 1, e + 24):match("^%s*(%a+ %a+)")
			local art = after and after:match("^(%a+)") or nil
			local isVerb = art == "a" or art == "an" or art == "the"
			local isPoss = remaining:sub(e + 1, e + 2) == "'s"
			if after ~= "damage taken" and not isVerb and not isPoss then
				accepted = true
			end
			pos = e + 1
		end
		if accepted then
			remaining = remaining:gsub(pat, " ")
			masks = masks or {}
			for _, m in ipairs(sn.masks) do
				masks[m] = true
			end
		end
	end
	local maskList
	if masks then
		maskList = {}
		for m in pairs(masks) do
			maskList[#maskList + 1] = m
		end
	end
	return {
		role = role,
		duration = duration,
		tickMin = tickMin,
		interval = interval,
		dotTotal = dotTotal,
		dotDur = dotDur,
		masks = maskList,
	}
end

---------------------------------------------------------------------------
-- Enumeration
---------------------------------------------------------------------------
local function enumPlayerBank(bank, sink)
	if not (C_SpellBook.GetNumSpellBookSkillLines
		and C_SpellBook.GetSpellBookSkillLineInfo) then
		return 0
	end
	local added = 0
	local lines = C_SpellBook.GetNumSpellBookSkillLines() or 0
	for li = 1, lines do
		local info = C_SpellBook.GetSpellBookSkillLineInfo(li)
		local skip = not info
			or info.shouldHide
			or type(info.offSpecID) == "number"
		if not skip then
			local count = info.numSpellBookItems or 0
			local base = info.itemIndexOffset or 0
			for j = 1, count do
				local ok, it = pcall(C_SpellBook.GetSpellBookItemInfo, base + j, bank)
				if ok and type(it) == "table"
					and it.itemType == Enum.SpellBookItemType.Spell
					and not it.isOffSpec then
					local sid = it.spellID or it.actionID
					if type(sid) == "number" and sid > 0 then
						local name = type(it.name) == "string" and it.name or nil
						if name and ZSBT.IsSafeString and not ZSBT.IsSafeString(name) then
							name = nil
						end
						sink[#sink + 1] = { sid = sid, name = name }
						added = added + 1
					end
				end
			end
		end
	end
	return added
end

-- Pet spellbook: no skill lines — probe the slot space linearly and
-- stop after a consecutive-empty run. Pet books are small (< ~20).
-- Non-retail clients (e.g. Camelot) may lack the Pet spell bank or
-- C_SpellBook entirely; fall back through the legacy pet-book globals
-- and finally the pet action bar, all pcall-guarded.
local function enumPetBank(bank, sink)
	local added = 0
	local spellT = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
	local petAction = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.PetAction
	local function unmask(sid)
		-- PetAction ids pack the spell id in the low 24 bits.
		if type(sid) == "number" and sid > 0xFFFFFF then
			if bit and bit.band then return bit.band(sid, 0xFFFFFF) end
			return sid % 0x1000000
		end
		return sid
	end
	if type(bank) == "number" and C_SpellBook
		and C_SpellBook.GetSpellBookItemInfo and spellT then
		local emptyRun = 0
		for i = 1, 60 do
			local ok, it = pcall(C_SpellBook.GetSpellBookItemInfo, i, bank)
			local it2 = ok and it or nil
			if type(it2) ~= "table" or (it2.itemType ~= spellT
				and it2.itemType ~= petAction) then
				emptyRun = emptyRun + 1
				if emptyRun >= 10 then break end
			else
				emptyRun = 0
				local sid = unmask(it2.spellID or it2.actionID)
				if type(sid) == "number" and sid > 0 then
					local name = type(it2.name) == "string" and it2.name or nil
					if name and ZSBT.IsSafeString and not ZSBT.IsSafeString(name) then
						name = nil
					end
					sink[#sink + 1] = { sid = sid, name = name }
					added = added + 1
				end
			end
		end
	end
	if added == 0 and type(GetSpellBookItemInfo) == "function" then
		local numSpells = 0
		if type(HasPetSpells) == "function" then
			local okN, n2 = pcall(HasPetSpells)
			numSpells = okN and tonumber(n2) or 0
		elseif C_SpellBook and type(C_SpellBook.HasPetSpells) == "function" then
			local okN, n2 = pcall(C_SpellBook.HasPetSpells)
			numSpells = okN and tonumber(n2) or 0
		end
		for i = 1, math.min(numSpells, 60) do
			local ok, st, id = pcall(GetSpellBookItemInfo, i, "pet")
			if ok and (st == "SPELL" or st == "PETACTION") and type(id) == "number" then
				local sid = unmask(id)
				if sid > 0 then
					local name = nil
					if type(GetSpellBookItemName) == "function" then
						local ok2, n2 = pcall(GetSpellBookItemName, i, "pet")
						if ok2 and type(n2) == "string" then name = n2 end
					end
					if name == nil and type(GetSpellInfo) == "function" then
						local ok2, n2 = pcall(GetSpellInfo, sid)
						if ok2 and type(n2) == "string" then name = n2 end
					end
					if name and ZSBT.IsSafeString and not ZSBT.IsSafeString(name) then
						name = nil
					end
					sink[#sink + 1] = { sid = sid, name = name }
					added = added + 1
				end
			end
		end
	end
	if added == 0 and type(GetPetActionInfo) == "function"
		and type(GetSpellInfo) == "function" then
		local maxSlots = _G.NUM_PET_ACTION_SLOTS
		if type(maxSlots) ~= "number" or maxSlots <= 0 then maxSlots = 12 end
		local seen = {}
		for i = 1, maxSlots do
			local ok, name, _, _, isToken = pcall(GetPetActionInfo, i)
			if ok and type(name) == "string" and name ~= "" then
				if isToken == true and type(_G[name]) == "string" then
					name = _G[name]
				end
				local sid = nil
				pcall(function() sid = select(7, GetSpellInfo(name)) end)
				if type(sid) == "number" and sid > 0 and not seen[sid] then
					seen[sid] = true
					if ZSBT.IsSafeString and not ZSBT.IsSafeString(name) then
						name = nil
					end
					sink[#sink + 1] = { sid = sid, name = name }
					added = added + 1
				end
			end
		end
	end
	return added
end

local function enumBank(bank, sink)
	local petBank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Pet
	if bank == petBank then
		-- bank may be nil on clients lacking the Pet enum member;
		-- enumPetBank has pcall-guarded legacy fallbacks.
		return enumPetBank(bank, sink)
	end
	if not (C_SpellBook and C_SpellBook.GetSpellBookItemInfo
		and Enum and Enum.SpellBookSpellBank and Enum.SpellBookItemType) then
		return 0
	end
	return enumPlayerBank(bank, sink)
end

-- Selected talent nodes -> granted spellIDs. Talent-passive and
-- hero-tree damage spells never appear in the base spellbook, so
-- without this pass the derived layer knows nothing about a large
-- part of the kit's actual wound output. Selected nodes only —
-- unbought choices contribute nothing.
local function enumTalentSpells(sink, have)
	-- Stage counters: which link dies when the yield is zero.
	local dbg = { trees = 0, nodes = 0, ranked = 0, entry = 0, sid = 0, bail = "" }
	local function bail(why)
		dbg.bail = why
		return nil, dbg
	end
	if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID
		and C_Traits and C_Traits.GetConfigInfo and C_Traits.GetTreeInfo
		and C_Traits.GetNodeInfo and C_Traits.GetEntryInfo
		and C_Traits.GetDefinitionInfo and C_Traits.GetTreeNodes) then
		return bail("apis")
	end
	local configID = C_ClassTalents.GetActiveConfigID()
	if type(configID) ~= "number" then return bail("config") end
	local okC, cInfo = pcall(C_Traits.GetConfigInfo, configID)
	if not (okC and type(cInfo) == "table" and type(cInfo.treeIDs) == "table") then
		return bail("cinfo")
	end
	local tset, subMap = {}, {}
	for _, treeID in ipairs(cInfo.treeIDs) do
		dbg.trees = dbg.trees + 1
		local okT, nodeIDs = pcall(C_Traits.GetTreeNodes, treeID)
		if okT and type(nodeIDs) == "table" then
			for _, nodeID in ipairs(nodeIDs) do
				dbg.nodes = dbg.nodes + 1
				local okN, nInfo = pcall(C_Traits.GetNodeInfo, configID, nodeID)
				local ae = okN and type(nInfo) == "table" and nInfo.activeEntry or nil
				local entryID = type(ae) == "table" and ae.entryID
					or (type(ae) == "number" and ae or nil)
				if okN and type(nInfo) == "table"
					and (tonumber(nInfo.currentRank) or 0) > 0 then
					dbg.ranked = dbg.ranked + 1
				end
				if okN and type(nInfo) == "table"
					and (tonumber(nInfo.currentRank) or 0) > 0
					and type(entryID) == "number" then
					dbg.entry = dbg.entry + 1
					-- Hero-talent provenance: nodes living in a hero
					-- subtree carry subTreeID. Count hits so the dump
					-- shows whether the client exposes the field.
					local sub = tonumber(nInfo.subTreeID)
					if type(sub) == "number" then
						dbg.sub = (dbg.sub or 0) + 1
					end
					local okE, eInfo = pcall(C_Traits.GetEntryInfo,
						configID, entryID)
					local defID = okE and type(eInfo) == "table" and eInfo.definitionID or nil
					-- NOT `defID and pcall(...) or nil` — the `and`
					-- truncates pcall's returns to one value and
					-- dInfo is always nil.
					local okD, dInfo
					if defID then
						okD, dInfo = pcall(C_Traits.GetDefinitionInfo, defID)
					end
					local sid = okD and type(dInfo) == "table" and tonumber(dInfo.spellID) or nil
					if type(sid) == "number" and sid > 0 then
						dbg.sid = dbg.sid + 1
						-- Coverage set: every granted spell, whether or
						-- not the book already has it. Also the pick-list
						-- a future teach UI would want.
						tset[sid] = true
						if type(sub) == "number" then
							subMap[sid] = sub
						end
					end
					if type(sid) == "number" and sid > 0 and not have[sid] then
						have[sid] = true
						-- Definition override text is the node's own
						-- tooltip — better than the base spell's when
						-- they differ (talent modifiers).
						local desc, name
						if type(dInfo) == "table" then
							local od = dInfo.overrideDescription
							if type(od) == "string"
								and (ZSBT.IsSafeString == nil or ZSBT.IsSafeString(od))
								and od ~= "" then
								desc = od
							end
							local on = dInfo.overrideName
							if type(on) == "string"
								and (ZSBT.IsSafeString == nil or ZSBT.IsSafeString(on))
								and on ~= "" then
								name = on
							end
						end
						if name == nil and C_Spell and C_Spell.GetSpellName then
							local okNm, nm = pcall(C_Spell.GetSpellName, sid)
							if okNm and type(nm) == "string"
								and (ZSBT.IsSafeString == nil or ZSBT.IsSafeString(nm))
								and nm ~= "" then
								name = nm
							end
						end
						sink[#sink + 1] = { sid = sid, name = name, talent = true, desc = desc }
					end
				end
			end
		end
	end
	return tset, dbg, subMap
end

function Spellbook:Scan()
	local t0 = debugprofilestop and debugprofilestop() or 0
	local raw = {}
	enumBank(Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player, raw)
	local have = {}
	for _, e in ipairs(raw) do have[e.sid] = true end
	local tset, tdbg, subMap = enumTalentSpells(raw, have)
	self._talents = tset
	self._talentDbg = tdbg
	self._subMap = subMap or {}
	local petRaw = {}
	enumBank(Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Pet, petRaw)

	local entries, byName, masks, petEntries = {}, {}, {}, {}
	local descs = {}
	for _, e in ipairs(raw) do
		local rec = { sid = e.sid, name = e.name, role = "cast",
			talent = e.talent or (tset and tset[e.sid]) or nil,
			subTree = subMap and subMap[e.sid] or nil }
		-- Node override text wins when present; else the spell's own
		-- description. Name isn't required — sid-keyed records still
		-- feed the school gate either way.
		local desc = e.desc
		if desc == nil and C_Spell and C_Spell.GetSpellDescription then
			local ok, d2 = pcall(C_Spell.GetSpellDescription, e.sid)
			if ok and type(d2) == "string" then desc = d2 end
		end
		if type(desc) == "string"
			and (ZSBT.IsSafeString == nil or ZSBT.IsSafeString(desc)) then
			descs[e.sid] = desc
			local parsed = Spellbook.ParseDesc(desc, e.sid)
			if parsed then
				rec.role = parsed.role
				rec.duration = parsed.duration
				rec.tickMin = parsed.tickMin
				rec.interval = parsed.interval
				rec.dotTotal = parsed.dotTotal
				rec.dotDur = parsed.dotDur
				rec.masks = parsed.masks
			end
		end
		entries[e.sid] = rec
		if e.name and byName[e.name] == nil then
			byName[e.name] = e.sid
		end
		for _, m in ipairs(rec.masks or {}) do
			masks[m] = true
		end
	end
	for _, e in ipairs(petRaw) do
		if e.name then
			petEntries[e.sid] = { name = e.name }
		end
	end

	-- Correlation layer ----------------------------------------------
	-- Pairs: a talent-granted sid that shares a name with a base-book
	-- sid (Void Metamorphosis 471306 vs 1217605) is that spell's
	-- empowerment twin — a cast on either opens the same window.
	local pairs_ = {}
	for sid in pairs(tset or {}) do
		local rec = entries[sid]
		if rec and rec.name then
			local other = byName[rec.name]
			if type(other) == "number" and other ~= sid then
				pairs_[sid] = other
			end
		end
	end
	-- Links: descriptions referencing other known spells by name are
	-- trigger/modifier edges — "your Reap has a chance to", "dealing
	-- damage with Voidblade", "when you cast X". Longest names first so
	-- "Void Metamorphosis" wins over a bare "Void"-prefixed name.
	local names = {}
	for name, sid in pairs(byName) do
		if type(name) == "string" and #name >= 4 then
			names[#names + 1] = { name = name, sid = sid }
		end
	end
	table.sort(names, function(a, b) return #a.name > #b.name end)
	local TRIGGER_CTX = {
		"cast", "dealing damage", "damage with", "when ", "after ",
		"hits", "using ", "strikes", "consumes", "your ",
	}
	local links = {}
	for sid, desc in pairs(descs) do
		local selfName = entries[sid] and entries[sid].name or nil
		for _, n in ipairs(names) do
			if n.sid ~= sid and n.name ~= selfName then
				local pos = desc:find(n.name, 1, true)
				while pos do
					local before = pos > 1 and desc:sub(pos - 1, pos - 1) or " "
					local after = desc:sub(pos + #n.name, pos + #n.name)
					local boundary = not before:match("%a") and not after:match("%a")
					if boundary then
						local ctx = desc:sub(math.max(1, pos - 48), pos - 1):lower()
						local strong = false
						for _, w in ipairs(TRIGGER_CTX) do
							if ctx:find(w, 1, true) then strong = true break end
						end
						local edge = links[n.sid]
						if not edge then edge = {} links[n.sid] = edge end
						if not edge[sid] or strong then
							edge[sid] = strong and "strong" or "mention"
						end
						break
					end
					pos = desc:find(n.name, pos + 1, true)
				end
			end
		end
	end

	-- Gear pass: equipped item effects (trinket use/proc spells, weapon
	-- and enchant effects) parse through the same description machinery
	-- as class spells — DotEntry's spellbook fallback then claims their
	-- periodic wounds with no module table. The item->spell map persists
	-- to profile.gearLibrary so the library survives relog/unequip.
	local gearLib = {}
	if C_Item and C_Item.GetItemSpell and GetInventoryItemID then
		for slot = 1, 17 do
			local okI, itemID = pcall(GetInventoryItemID, "player", slot)
			if okI and type(itemID) == "number" then
				local okS, effSid, effName = pcall(C_Item.GetItemSpell, itemID)
				if okS and type(effSid) == "number" and entries[effSid] == nil then
					local rec = { sid = effSid, gear = true, itemID = itemID,
						slot = slot, role = "cast" }
					if type(effName) == "string" and effName ~= "" then
						rec.name = effName
					elseif C_Spell and C_Spell.GetSpellInfo then
						local okN, info = pcall(C_Spell.GetSpellInfo, effSid)
						if okN and type(info) == "table" and type(info.name) == "string" then
							rec.name = info.name
						end
					end
					local desc
					if C_Spell and C_Spell.GetSpellDescription then
						local okD, d2 = pcall(C_Spell.GetSpellDescription, effSid)
						if okD and type(d2) == "string" and d2 ~= "" then desc = d2 end
					end
					if type(desc) == "string"
						and (ZSBT.IsSafeString == nil or ZSBT.IsSafeString(desc)) then
						local parsed = Spellbook.ParseDesc(desc, effSid)
						if parsed then
							rec.role = parsed.role
							rec.duration = parsed.duration
							rec.tickMin = parsed.tickMin
							rec.interval = parsed.interval
							rec.dotTotal = parsed.dotTotal
							rec.dotDur = parsed.dotDur
							rec.masks = parsed.masks
						end
					end
					entries[effSid] = rec
					if rec.name and byName[rec.name] == nil then
						byName[rec.name] = effSid
					end
					for _, m in ipairs(rec.masks or {}) do masks[m] = true end
					gearLib[itemID] = { sid = effSid, spellName = rec.name }
				end
			end
		end
	end
	self._gear = gearLib
	do
		local prof = ZSBT.db and ZSBT.db.profile
		if type(prof) == "table" then
			prof.gearLibrary = prof.gearLibrary or {}
			for itemID, g in pairs(gearLib) do
				local e = prof.gearLibrary[itemID]
				if not e then
					prof.gearLibrary[itemID] = { sid = g.sid,
						spellName = g.spellName, firstSeen = time() }
				else
					e.sid = g.sid
					e.spellName = g.spellName
					e.lastSeen = time()
				end
			end
		end
	end

	self._entries = entries
	self._byName = byName
	self._masks = masks
	self._petEntries = petEntries
	self._pairs = pairs_
	self._links = links
	self._scanned = true
	self._scanMs = (debugprofilestop and t0 > 0) and (debugprofilestop() - t0) or 0
end

local function ensureScanned(self)
	if not self._scanned then self:Scan() end
end

-- Derived record for a spellId the player currently knows, or nil.
function Spellbook:Entry(spellId)
	if type(spellId) ~= "number" then return nil end
	ensureScanned(self)
	return self._entries[spellId]
end

function Spellbook:IdForName(name)
	if type(name) ~= "string" or name == "" then return nil end
	ensureScanned(self)
	return self._byName[name]
end

-- Derived school-mask set over the current book: { [mask] = true }.
function Spellbook:Masks()
	ensureScanned(self)
	return self._masks
end

-- True when the current book derives at least one dot or channel —
-- the module-less era fallback gate for cadence disambiguation.
function Spellbook:HasPeriodic()
	ensureScanned(self)
	for _, rec in pairs(self._entries) do
		if rec.role == "dot" or rec.role == "channel" then return true end
	end
	return false
end

-- Empowerment twin: talent sid sharing a name with a book sid.
-- Both sids should open the same attribution window.
function Spellbook:PairOf(spellId)
	ensureScanned(self)
	return self._pairs[spellId]
end

-- Trigger edges: spells named in trigger context inside this spell's
-- description. Returns { [procSid] = "strong"|"mention" } or nil.
function Spellbook:LinksFrom(triggerSid)
	ensureScanned(self)
	return self._links[triggerSid]
end

-- Hero-tree membership flag for learner priors (nil = not hero-tree).
function Spellbook:SubTreeOf(spellId)
	ensureScanned(self)
	local rec = self._entries[spellId]
	return rec and rec.subTree or nil
end

---------------------------------------------------------------------------
-- Rescan triggers: spellbook contents change on spec/talent/glyph and
-- pet-summon transitions. Debounced so a talent swap's event burst costs
-- one scan, not five.
---------------------------------------------------------------------------
local frame = CreateFrame and CreateFrame("Frame") or nil
if frame then
	frame._dirty = true
	frame:RegisterEvent("PLAYER_LOGIN")
	if frame.RegisterUnitEvent then
		frame:RegisterUnitEvent("UNIT_PET", "player")
	end
	-- Trait configs load asynchronously after login and fire on
	-- every build/commit; cover the whole lifecycle so a scan
	-- never runs off a half-loaded tree. One pcall each — an
	-- unknown event on this client must not starve the rest.
	for _, ev in ipairs({
		"SPELLS_CHANGED",
		"TRAIT_CONFIG_UPDATED",
		"TRAIT_CONFIG_LIST_RECEIVED",
		"TRAIT_CONFIG_CREATED",
		"TRAIT_CONFIG_DELETED",
		"TRAIT_TREE_CHANGED",
		"ACTIVE_TALENT_GROUP_CHANGED",
		"PLAYER_TALENT_UPDATE",
		"ACTIVE_PLAYER_SPECIALIZATION_CHANGED",
		"PLAYER_SPECIALIZATION_CHANGED",
		"PET_BAR_UPDATE",
	}) do
		pcall(frame.RegisterEvent, frame, ev)
	end
	frame:SetScript("OnEvent", function(self)
		self._dirty = true
		if C_Timer and C_Timer.After then
			C_Timer.After(0.5, function()
				if frame._dirty then
					frame._dirty = false
					Spellbook:Scan()
				end
			end)
		end
	end)
end

---------------------------------------------------------------------------
-- /zsbt sb — dump what the book-derived layer sees for the current
-- spec, so verification is a chat command rather than a code read.
---------------------------------------------------------------------------
function Spellbook:Dump(printFn, showAll)
	local p = printFn or print
	-- Diagnostic command — always print the freshest state, including
	-- a trait config that only finished loading after the login scan.
	self:Scan()
	local n, dots, chans, talents = 0, 0, 0, 0
	for sid, rec in pairs(self._entries) do
		n = n + 1
		if rec.talent then talents = talents + 1 end
		if rec.role == "dot" then dots = dots + 1 end
		if rec.role == "channel" then chans = chans + 1 end
	end
	p(("Spellbook: %d spells (%d talent, %d dot, %d channel), %d pet, %.1fms")
		:format(n, talents, dots, chans, (function() local c = 0 for _ in pairs(self._petEntries) do c = c + 1 end return c end)(), self._scanMs or 0))
	local d = self._talentDbg
	if d then
		p(("  talent-dbg: trees=%d nodes=%d ranked=%d entry=%d sid=%d sub=%d bail=%s")
			:format(d.trees or 0, d.nodes or 0, d.ranked or 0,
				d.entry or 0, d.sid or 0, d.sub or 0, tostring(d.bail or "")))
	end
	local np = 0 for _ in pairs(self._pairs or {}) do np = np + 1 end
	local nl = 0 for _, t in pairs(self._links or {}) do for _ in pairs(t) do nl = nl + 1 end end
	p(("  correlations: %d pairs, %d trigger links"):format(np, nl))
	if showAll then
		for sid, other in pairs(self._pairs or {}) do
			local a = self._entries[sid]
			p(("  pair: %s (%d) -> %s (%d)"):format(
				a and a.name or "?", sid,
				(self._entries[other] and self._entries[other].name) or "?", other))
		end
		for trig, edge in pairs(self._links or {}) do
			local tn = self._entries[trig] and self._entries[trig].name or tostring(trig)
			local parts = {}
			for proc, str in pairs(edge) do
				local pn = self._entries[proc] and self._entries[proc].name or tostring(proc)
				parts[#parts + 1] = pn .. (str == "strong" and "!" or "")
			end
			table.sort(parts)
			p(("  link: %s -> %s"):format(tn, table.concat(parts, ", ")))
		end
		local subRecs = {}
		for sid, rec in pairs(self._entries) do
			if rec.subTree then subRecs[#subRecs + 1] = (rec.name or sid) .. "(" .. sid .. ")" end
		end
		if #subRecs > 0 then
			table.sort(subRecs)
			p("  hero-tree: " .. table.concat(subRecs, ", "))
		end
		-- Learned trigger->proc bindings (collector store): fires,
		-- windows offered, relearn count.
		local ec = ZSBT.Parser and ZSBT.Parser.EventCollector
		local binds = ec and ec.ProcBindings and ec:ProcBindings() or nil
		if type(binds) == "table" then
			local rows = {}
			for trig, t in pairs(binds) do
				local tk = tonumber(trig) or trig
				local tn = self._entries[tk] and self._entries[tk].name or tostring(trig)
				for proc, e in pairs(t) do
					local pk = tonumber(proc) or proc
					local pn = self._entries[pk] and self._entries[pk].name or tostring(proc)
					rows[#rows + 1] = ("  learned: %s -> %s n=%d w=%d rel=%d")
						:format(tn, pn, e.n or 0, e.w or 0, e.rel or 0)
				end
			end
			table.sort(rows)
			for _, r in ipairs(rows) do p(r) end
		end
	end
	local masks = {}
	for m in pairs(self._masks) do masks[#masks + 1] = m end
	table.sort(masks)
	local bits = {}
	for _, m in ipairs(masks) do bits[#bits + 1] = tostring(m) end
	p("Derived schools: " .. (#bits > 0 and table.concat(bits, ", ") or "none"))
	-- Interesting entries only: anything not plain "cast" — unless
	-- /zsbt sb all asked for the full record list.
	local flagged = {}
	for sid, rec in pairs(self._entries) do
		if showAll or rec.role ~= "cast" or rec.masks then
			local mlist = {}
			for _, m in ipairs(rec.masks or {}) do mlist[#mlist + 1] = tostring(m) end
			flagged[#flagged + 1] = {
				label = ("%s%s (%d): %s%s%s%s"):format(
					rec.talent and "*" or "", rec.name or tostring(sid), sid, rec.role,
					type(rec.interval) == "number" and (" iv=" .. rec.interval) or "",
					(type(rec.dotTotal) == "number" and type(rec.dotDur) == "number")
						and (" exp=" .. string.format("%.1f", rec.dotTotal * (rec.interval or 2) / rec.dotDur)) or "",
					#mlist > 0 and (" sch=" .. table.concat(mlist, "/")) or ""),
			}
		end
	end
	table.sort(flagged, function(a, b) return a.label < b.label end)
	for _, f in ipairs(flagged) do p("  " .. f.label) end
end

---------------------------------------------------------------------------
-- /zsbt sb win — the full dump is too long for chat scrollback; render it
-- into a draggable window with a selectable EditBox for Ctrl+A / Ctrl+C.
---------------------------------------------------------------------------
local dumpFrame
function Spellbook:DumpWindow()
	if not dumpFrame then
		local f = CreateFrame("Frame", "ZSBT_SpellbookDump", UIParent)
		-- BackdropTemplate's virtual inherit is gone on new clients;
		-- apply the mixin when the global survives, else fall back to
		-- a plain color-texture background.
		if type(BackdropTemplateMixin) == "table" and type(Mixin) == "function" then
			Mixin(f, BackdropTemplateMixin)
		end
		f:SetSize(780, 560)
		f:SetPoint("CENTER")
		f:SetFrameStrata("DIALOG")
		f:SetMovable(true)
		f:EnableMouse(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", f.StopMovingOrSizing)
		if type(f.SetBackdrop) == "function" then
			f:SetBackdrop({
				bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
				edgeSize = 14,
				insets = { left = 3, right = 3, top = 3, bottom = 3 },
			})
			f:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
			f:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
		else
			local bg = f:CreateTexture(nil, "BACKGROUND")
			bg:SetAllPoints()
			bg:SetColorTexture(0.05, 0.05, 0.08, 0.95)
		end
		if type(UISpecialFrames) == "table" then
			UISpecialFrames[#UISpecialFrames + 1] = "ZSBT_SpellbookDump"
		end
		local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		title:SetPoint("TOPLEFT", 12, -10)
		title:SetText("ZSBT Spellbook Dump — Ctrl+A, Ctrl+C")
		local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -4, -4)
		local sf = CreateFrame("ScrollFrame", nil, f,
			"UIPanelScrollFrameTemplate")
		sf:SetPoint("TOPLEFT", 10, -32)
		sf:SetPoint("BOTTOMRIGHT", -30, 10)
		local eb = CreateFrame("EditBox", nil, sf)
		eb:SetMultiLine(true)
		eb:SetAutoFocus(false)
		eb:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
		eb:SetWidth(720)
		eb:SetScript("OnEscapePressed", function() f:Hide() end)
		sf:SetScrollChild(eb)
		f._edit = eb
		dumpFrame = f
	end
	local buf = {}
	self:Dump(function(s) buf[#buf + 1] = tostring(s) end, true)
	dumpFrame._edit:SetText(table.concat(buf, "\n"))
	dumpFrame._edit:SetCursorPosition(0)
	dumpFrame:Show()
end

return Spellbook
