local MAJOR, MINOR = "LibCombatPulse-1.0", 2

local LibStub = _G.LibStub
if not LibStub then
	return
end

local lib, oldminor = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then
	return
end

lib._consumers = lib._consumers or {}

local function shallowCopy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

local function now()
	local ok, t = pcall(function()
		return (type(GetTime) == "function" and GetTime()) or 0
	end)
	if ok and type(t) == "number" then
		return t
	end
	return 0
end

local function normalizeEvent(evt)
	if type(evt) ~= "table" then return nil end
	if evt.kind ~= nil then
		evt.kind = tostring(evt.kind)
	else
		evt.kind = "unknown"
	end
	if evt.eventType ~= nil then
		evt.eventType = tostring(evt.eventType)
	end
	if evt.direction ~= nil then
		evt.direction = tostring(evt.direction)
	end
	if type(evt.timestamp) ~= "number" then
		evt.timestamp = now()
	end
	return evt
end

local function normalizeOpts(opts)
	if type(opts) ~= "table" then opts = {} end
	if opts.enableCombat == nil then opts.enableCombat = true end
	if opts.enableProgress == nil then opts.enableProgress = true end
	if opts.enableInterrupts == nil then opts.enableInterrupts = true end
	if opts.enableCooldowns == nil then opts.enableCooldowns = true end
	if opts.copyEvent == nil then opts.copyEvent = true end
	if type(opts.minConfidence) ~= "string" or opts.minConfidence == "" then
		opts.minConfidence = "LOW"
	end
	if opts.includeRaw == nil then opts.includeRaw = false end
	return opts
end

local function isEnabledByConfidence(minConf, evtConf)
	minConf = tostring(minConf or "LOW")
	evtConf = tostring(evtConf or "LOW")
	local rank = { LOW = 1, MED = 2, HIGH = 3 }
	return (rank[evtConf] or 1) >= (rank[minConf] or 1)
end

local function consumerMatches(consumer, evt)
	if not consumer or consumer.enabled ~= true then return false end
	local opts = consumer.opts or {}
	if not isEnabledByConfidence(opts.minConfidence, evt and evt.confidence) then
		return false
	end
	local kind = evt and evt.kind
	if type(opts.kinds) == "table" then
		if opts.kinds[kind] ~= true then
			return false
		end
	end
	local dir = evt and evt.direction
	if dir ~= nil and type(opts.directions) == "table" then
		if opts.directions[dir] ~= true then
			return false
		end
	end
	local et = evt and evt.eventType
	if et ~= nil and type(opts.eventTypes) == "table" then
		if opts.eventTypes[et] ~= true then
			return false
		end
	end
	if kind == "damage" or kind == "heal" or kind == "miss" or kind == "aura_gain" or kind == "aura_fade" then
		return opts.enableCombat == true
	end
	if kind == "xp" or kind == "honor" or kind == "reputation" then
		return opts.enableProgress == true
	end
	if kind == "interrupt" or kind == "cast_stop" then
		return opts.enableInterrupts == true
	end
	if kind == "cooldown_ready" then
		return opts.enableCooldowns == true
	end
	-- Unknown kinds default to combat opt.
	return opts.enableCombat == true
end

local ConsumerHandle = {}
ConsumerHandle.__index = ConsumerHandle

function ConsumerHandle:Enable()
	if self._id and lib._consumers[self._id] then
		lib._consumers[self._id].enabled = true
	end
end

function ConsumerHandle:Disable()
	if self._id and lib._consumers[self._id] then
		lib._consumers[self._id].enabled = false
	end
end

function ConsumerHandle:SetOptions(opts)
	if self._id and lib._consumers[self._id] then
		lib._consumers[self._id].opts = normalizeOpts(opts)
	end
end

function ConsumerHandle:GetOptions()
	if self._id and lib._consumers[self._id] then
		return lib._consumers[self._id].opts
	end
	return nil
end

function ConsumerHandle:Unregister()
	if self._id and lib._consumers[self._id] then
		lib._consumers[self._id] = nil
	end
end

function lib:GetVersion()
	return MINOR
end

function lib:NewConsumer(consumerId, callbacks, opts)
	consumerId = tostring(consumerId or "")
	if consumerId == "" then
		return nil
	end
	if type(callbacks) ~= "table" then
		callbacks = {}
	end

	lib._consumers[consumerId] = {
		id = consumerId,
		callbacks = callbacks,
		opts = normalizeOpts(opts),
		enabled = true,
	}

	return setmetatable({ _id = consumerId }, ConsumerHandle)
end

function lib:Emit(evt)
	evt = normalizeEvent(evt)
	if not evt then return end
	for _, consumer in pairs(lib._consumers) do
		if consumerMatches(consumer, evt) then
			local cb = consumer.callbacks
			local f = cb and (cb.OnEvent or cb.onEvent)
			if type(f) == "function" then
				local opts = consumer.opts or {}
				local payload = evt
				if opts.copyEvent == true then
					payload = shallowCopy(evt)
				end
				pcall(f, payload)
			end
		end
	end
end
