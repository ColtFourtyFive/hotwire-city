--!strict
-- EngineClass (PLAN C3 · audio): which engine set (Audio/EngineModel.PROFILES, Config/Sounds Eng_<Set>_*) and which
-- horn a car gets. Read defensively: a model attribute "EngineClass" (any future system may set it) wins, then police
-- (Kind "Police" or a police class), then the catalog's realistic `class` (Cars v2), then the v1 procedural `style`;
-- anything unknown is a sedan.
--
-- Pure: callers pass plain values (attribute values, a CarDef-like table or nil).

local EngineClass = {}

EngineClass.SETS = { "compact", "sedan", "muscle", "sports", "super", "truck", "bike", "police" }
EngineClass.DEFAULT = "sedan"

-- Car class / v1 style -> engine set.
EngineClass.MAP = {
	-- small four-cylinders
	compact = "compact",
	hatch = "compact",
	duck = "compact",
	couch = "compact",
	toilet = "compact",
	-- everyday sedans and limos (smooth V6 / V8)
	sedan = "sedan",
	taxi = "sedan",
	luxury = "sedan",
	limo = "sedan",
	-- V8 muscle
	muscle = "muscle",
	lowrider = "muscle",
	hotdog = "muscle",
	-- sports / super / hyper
	sports = "sports",
	super = "super",
	hyper = "super",
	rocket = "super",
	hover = "super",
	-- trucks, vans, buses, service vehicles (diesel / big block)
	suv = "truck",
	pickup = "truck",
	van = "truck",
	box_truck = "truck",
	bus = "truck",
	fire = "truck",
	ambulance = "truck",
	armored = "truck",
	monster = "truck",
	tank = "truck",
	icecream = "truck",
	-- two wheels
	bike = "bike",
	motorcycle = "bike",
	-- police
	police = "police",
	police_suv = "police",
}

-- Horn per engine set (Config/Sounds keys).
EngineClass.HORNS = {
	compact = "Horn_Compact",
	sedan = "Horn_Sedan",
	muscle = "Horn_Muscle",
	sports = "Horn_Sports",
	super = "Horn_Sports",
	truck = "Horn_Truck",
	bike = "Horn_Compact",
	police = "Horn_Muscle",
}

-- Config/Sounds keys of each engine set's layers ("sports" -> Eng_Sports_Idle / _On / _Off), built once.
export type LayerKeys = { idle: string, on: string, off: string }
EngineClass.KEYS = {} :: { [string]: LayerKeys }
for _, s in EngineClass.SETS do
	local cap = string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
	EngineClass.KEYS[s] =
		{ idle = "Eng_" .. cap .. "_Idle", on = "Eng_" .. cap .. "_On", off = "Eng_" .. cap .. "_Off" }
end

function EngineClass.keysFor(engineSet: string): LayerKeys
	return EngineClass.KEYS[engineSet] or EngineClass.KEYS[EngineClass.DEFAULT]
end

local function set(name: any): string?
	if typeof(name) ~= "string" then
		return nil
	end
	local lower = string.lower(name)
	if EngineClass.MAP[lower] then
		return EngineClass.MAP[lower]
	end
	for _, s in EngineClass.SETS do
		if s == lower then
			return s
		end
	end
	return nil
end

-- Is this a police vehicle (Kind "Police", or a police class / style in the catalog)?
function EngineClass.isPolice(kind: any, def: any): boolean
	if kind == "Police" then
		return true
	end
	if typeof(def) == "table" then
		if def.police == true then
			return true
		end
		local c = def.class
		if c == "police" or c == "police_suv" or def.style == "police" then
			return true
		end
	end
	return false
end

-- Engine set for a car. explicit = the model's "EngineClass" attribute (may be nil / junk), kind = its "Kind"
-- attribute, def = its catalog entry (Config/Cars.get(CarId); nil when unknown).
function EngineClass.resolve(explicit: any, kind: any, def: any): string
	local forced = set(explicit)
	if forced then
		return forced
	end
	if EngineClass.isPolice(kind, def) then
		return "police"
	end
	if typeof(def) == "table" then
		local fromClass = set(def.class)
		if fromClass then
			return fromClass
		end
		local fromStyle = set(def.style)
		if fromStyle then
			return fromStyle
		end
	end
	return EngineClass.DEFAULT
end

-- Kinds whose cars sit still (anchored displays / unclaimed) and never run an engine; AI kinds drive without a
-- seated player.
EngineClass.SILENT_KINDS = { Parked = true, Dealership = true, HotDrop = true } :: { [string]: boolean }
EngineClass.AI_KINDS = { Traffic = true, Police = true } :: { [string]: boolean }

-- Does a car with this Kind / driver state make engine noise?
function EngineClass.isEngineEligible(kind: any, hasDriver: boolean): boolean
	if typeof(kind) ~= "string" then
		return hasDriver
	end
	if EngineClass.SILENT_KINDS[kind] then
		return false
	end
	return hasDriver or EngineClass.AI_KINDS[kind] == true
end

function EngineClass.hornFor(engineSet: string): string
	return EngineClass.HORNS[engineSet] or EngineClass.HORNS.sedan
end

return EngineClass
