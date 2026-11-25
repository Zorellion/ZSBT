local ADDON_NAME, ZSBT = ...

---------------------------------------------------------------------------
-- Perf harness — opt-in timing instrumentation for freeze/stutter hunts.
-- OFF costs one table-field check per instrumented site.
-- /zsbt perf [on|off|report|reset]
---------------------------------------------------------------------------
local Perf = {}
ZSBT.Perf = Perf

Perf.on = false
Perf.spikeMs = 8          -- record individual spans at/above this
Perf._acc = {}            -- name -> {n=, ms=, max=}
Perf._spikes = {}         -- ring of {t, name, ms}
Perf._noSpike = { ["sb.scanwall"] = true }  -- wall-clock spans, not blocking
local SPIKE_CAP = 200

local dpstop = (debugprofilestop and debugprofilestop)
		or (GetTimePreciseSec and function() return GetTimePreciseSec() * 1000 end)

function Perf.t()
	return dpstop and dpstop() or 0
end

function Perf:done(name, t0)
	local dt = (dpstop and dpstop() or 0) - t0
	local a = self._acc[name]
	if a then
		a.n = a.n + 1
		a.ms = a.ms + dt
		if dt > a.max then a.max = dt end
	else
		self._acc[name] = { n = 1, ms = dt, max = dt }
	end
	if dt >= self.spikeMs and not self._noSpike[name] then
		local sp = self._spikes
		sp[#sp + 1] = { t = GetTime and GetTime() or 0, name = name, ms = dt }
		if #sp > SPIKE_CAP then table.remove(sp, 1) end
	end
end

function Perf:reset()
	self._acc = {}
	self._spikes = {}
end

function Perf:report(printFn)
	local p = printFn or print
	local rows = {}
	for name, a in pairs(self._acc) do rows[#rows + 1] = { name = name, a = a } end
	table.sort(rows, function(x, y) return x.a.ms > y.a.ms end)
	p("|cff66aaff[ZSBT perf]|r span totals (top 25):")
	local shown = 0
	for _, r in ipairs(rows) do
		shown = shown + 1
		if shown > 25 then break end
		p(("  %-28s n=%d total=%.1fms max=%.1fms mean=%.2fms")
			:format(r.name, r.a.n, r.a.ms, r.a.max, r.a.ms / math.max(1, r.a.n)))
	end
	if #self._spikes > 0 then
		p(("|cff66aaff[ZSBT perf]|r spikes >=%dms (last %d):"):format(self.spikeMs, math.min(15, #self._spikes)))
		local from = math.max(1, #self._spikes - 14)
		for i = from, #self._spikes do
			local s = self._spikes[i]
			p(("  t=%.2f %-28s %.1fms"):format(s.t, s.name, s.ms))
		end
	end
end

-- Frame factory: any OnEvent script set on the returned frame is timed
-- as "<label>.<EVENT>" when tracing is on. Cost when off: one boolean
-- check per event dispatch.
function Perf.frame(label, ...)
	if not CreateFrame then return nil end
	local f = CreateFrame("Frame", ...)
	if not f then return nil end
	local orig = f.SetScript
	f.SetScript = function(self, scriptName, handler)
		if scriptName == "OnEvent" and type(handler) == "function" then
			return orig(self, scriptName, function(...)
				local p = ZSBT.Perf
				local t0 = p and p.on and p.t()
				local ev = select(2, ...)
				handler(...)
				if t0 then p:done(tostring(label) .. "." .. tostring(ev), t0) end
			end)
		elseif scriptName == "OnUpdate" and type(handler) == "function" then
			return orig(self, scriptName, function(...)
				local p = ZSBT.Perf
				local t0 = p and p.on and p.t()
				handler(...)
				if t0 then p:done(tostring(label) .. ".OnUpdate", t0) end
			end)
		end
		return orig(self, scriptName, handler)
	end
	return f
end
