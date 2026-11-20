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

local _schoolNames = nil
local function schoolNames()
	if _schoolNames then return _schoolNames end
	_schoolNames = {}
	for _, src in ipairs(SCHOOL_SOURCES) do
		local s = rawget(_G, src.global)
		if type(s) == "string" and s ~= "" then
			if ZSBT.IsSafeString == nil or ZSBT.IsSafeString(s) then
				_schoolNames[#_schoolNames + 1] = { name = s, masks = src.masks }
			end
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
	for i = 1, math.min(#data.lines, 8) do
		local line = data.lines[i]
		for _, key in ipairs({ "leftText", "rightText" }) do
			local tx = line and line[key]
			if type(tx) == "string" and tx ~= ""
				and (ZSBT.IsSafeString == nil or ZSBT.IsSafeString(tx))
				and tx:lower():find("channel") then
				return true
			end
		end
	end
	return false
end

function Spellbook.ParseDesc(desc, spellId)
	if type(desc) ~= "string" or desc == "" then return nil end
	if ZSBT.IsSafeString and not ZSBT.IsSafeString(desc) then return nil end
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
	if d:find("channel") or chanMs or isChanneledTip(spellId) then
		role = "channel"
	elseif not selfDrain and not d:find("summon")
		and (d:find("every") or d:find("periodic") or d:find("over time")
			or d:find("per second") or d:find("per sec")
			or d:find("damage over")) then
		role = "dot"
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
		if remaining:find(pat) then
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
local function enumPetBank(bank, sink)
	local added, emptyRun = 0, 0
	for i = 1, 60 do
		local ok, it = pcall(C_SpellBook.GetSpellBookItemInfo, i, bank)
		local it2 = ok and it or nil
		if type(it2) ~= "table" or it2.itemType ~= Enum.SpellBookItemType.Spell then
			emptyRun = emptyRun + 1
			if emptyRun >= 10 then break end
		else
			emptyRun = 0
			local sid = it2.spellID or it2.actionID
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
	return added
end

local function enumBank(bank, sink)
	if not (C_SpellBook and C_SpellBook.GetSpellBookItemInfo
		and Enum and Enum.SpellBookSpellBank and Enum.SpellBookItemType) then
		return 0
	end
	if bank == Enum.SpellBookSpellBank.Pet then
		return enumPetBank(bank, sink)
	end
	return enumPlayerBank(bank, sink)
end

-- Selected talent nodes -> granted spellIDs. Talent-passive and
-- hero-tree damage spells never appear in the base spellbook, so
-- without this pass the derived layer knows nothing about a large
-- part of the kit's actual wound output. Selected nodes only —
-- unbought choices contribute nothing.
local function enumTalentSpells(sink, have)
	if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID
		and C_Traits and C_Traits.GetConfigInfo and C_Traits.GetTreeInfo
		and C_Traits.GetNodeInfo and C_Traits.GetEntryInfo
		and C_Traits.GetDefinitionInfo) then
		return 0
	end
	local configID = C_ClassTalents.GetActiveConfigID()
	if type(configID) ~= "number" then return 0 end
	local okC, cInfo = pcall(C_Traits.GetConfigInfo, configID)
	if not (okC and type(cInfo) == "table" and type(cInfo.treeIDs) == "table") then
		return 0
	end
	local added = 0
	for _, treeID in ipairs(cInfo.treeIDs) do
		local okT, tInfo = pcall(C_Traits.GetTreeInfo, configID, treeID)
		if okT and type(tInfo) == "table" and type(tInfo.nodes) == "table" then
			for _, nodeID in ipairs(tInfo.nodes) do
				local okN, nInfo = pcall(C_Traits.GetNodeInfo, configID, nodeID)
				local ae = okN and type(nInfo) == "table" and nInfo.activeEntry or nil
				local entryID = type(ae) == "table" and ae.entryID
					or (type(ae) == "number" and ae or nil)
				if okN and type(nInfo) == "table"
					and (tonumber(nInfo.currentRank) or 0) > 0
					and type(entryID) == "number" then
					local okE, eInfo = pcall(C_Traits.GetEntryInfo,
						configID, entryID)
					local defID = okE and type(eInfo) == "table" and eInfo.definitionID or nil
					local okD, dInfo = defID and pcall(C_Traits.GetDefinitionInfo, defID) or nil
					local sid = okD and type(dInfo) == "table" and tonumber(dInfo.spellID) or nil
					if type(sid) == "number" and sid > 0 and not have[sid] then
						have[sid] = true
						local name
						if C_Spell and C_Spell.GetSpellName then
							local okNm, nm = pcall(C_Spell.GetSpellName, sid)
							if okNm and type(nm) == "string" and nm ~= ""
								and (ZSBT.IsSafeString == nil or ZSBT.IsSafeString(nm)) then
								name = nm
							end
						end
						sink[#sink + 1] = { sid = sid, name = name, talent = true }
						added = added + 1
					end
				end
			end
		end
	end
	return added
end

function Spellbook:Scan()
	local t0 = debugprofilestop and debugprofilestop() or 0
	local raw = {}
	enumBank(Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player, raw)
	local have = {}
	for _, e in ipairs(raw) do have[e.sid] = true end
	enumTalentSpells(raw, have)
	local petRaw = {}
	enumBank(Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Pet, petRaw)

	local entries, byName, masks, petEntries = {}, {}, {}, {}
	for _, e in ipairs(raw) do
		local rec = { sid = e.sid, name = e.name, role = "cast", talent = e.talent or nil }
		if e.name and C_Spell and C_Spell.GetSpellDescription then
			local ok, desc = pcall(C_Spell.GetSpellDescription, e.sid)
			if ok and type(desc) == "string" then
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

	self._entries = entries
	self._byName = byName
	self._masks = masks
	self._petEntries = petEntries
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
	pcall(function()
		frame:RegisterEvent("SPELLS_CHANGED")
		frame:RegisterEvent("TRAIT_CONFIG_UPDATED")
		frame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
		frame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
		frame:RegisterEvent("PET_BAR_UPDATE")
	end)
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
function Spellbook:Dump(printFn)
	local p = printFn or print
	ensureScanned(self)
	local n, dots, chans, talents = 0, 0, 0, 0
	for sid, rec in pairs(self._entries) do
		n = n + 1
		if rec.talent then talents = talents + 1 end
		if rec.role == "dot" then dots = dots + 1 end
		if rec.role == "channel" then chans = chans + 1 end
	end
	p(("Spellbook: %d spells (%d talent, %d dot, %d channel), %d pet, %.1fms")
		:format(n, dots, chans, (function() local c = 0 for _ in pairs(self._petEntries) do c = c + 1 end return c end)(), self._scanMs or 0))
	local masks = {}
	for m in pairs(self._masks) do masks[#masks + 1] = m end
	table.sort(masks)
	local bits = {}
	for _, m in ipairs(masks) do bits[#bits + 1] = tostring(m) end
	p("Derived schools: " .. (#bits > 0 and table.concat(bits, ", ") or "none"))
	-- Interesting entries only: anything not plain "cast".
	local flagged = {}
	for sid, rec in pairs(self._entries) do
		if rec.role ~= "cast" or rec.masks then
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

return Spellbook
