--!strict
-- WorldLayout (v2): the whole island city of Hotwire City as data. Design: docs/v2/world/WORLD_SPEC.md; migration from
-- Config/Map + Util/MapLayout: docs/v2/world/MIGRATION.md; runtime queries: Util/WorldQuery.
--
-- The world is GENERATED offline (tools/world/gen, Lune) and BAKED (tools/world/bake.luau) into two data modules:
--   Config/WorldData                core, shared with clients: roads, junctions, POIs, plots, districts, zones...
--   Server/Config/WorldDataLots     server only: lots (Parcels), parking / police / off-street spawns, streetscape,
--                                   roadblocks, ETA fields, the tower plan (loaded on first access, server only)
-- This module rebuilds the runtime tables from them (no generation at boot: tech critique 8) and installs the baked
-- terrain edits (level pads under garages / POIs, the H1 trench) into Util/WorldTerrain, so heightAt / gradeAt agree
-- with the baked road heights on the server and on every client.
--
--   Scale, SEA_LEVEL, GRADE, Bounds, Speed, JunctionDelay     real-scale constants (1 stud ~= 0.28 m)
--   Coast, Islands, Water, Channel, TerrainZones, heightAt / gradeAt     terrain (Util/WorldTerrain)
--   Districts, SubZones, ActiveCore, ReservedAreas, districtAt / subzoneAt
--   Nodes, Edges, Intersections, Gores, Weaves                the road graph (multi-level, strongly connected)
--   POIs, Plots, Landmarks, HotDrops, StuntJumps, Helipads, SafeZones, RestrictedZones
--   Routes (armored runs, races), ArmoredRules, LiftBridge, HeistDropoffs, CarSwaps, OnboardingOrder
--   Rails, Paths, Bridges, LevelCrossings
--   Spawns { hospital, default, bustedRelease | parking, offstreet, police, traffic (server) }
--   Parcels, Streetscape, Roadblocks, EtaFields, TowerPlan, PropClusters (server only, lazy)
--
-- Axes: +X east, -Z north (map up), +Y up. Right-hand traffic. Heights: sea level 0, city grade 12.

local WorldGen = require(script.Parent.Parent.Util.WorldGen)
local WorldTerrain = require(script.Parent.Parent.Util.WorldTerrain)
local Data: any = require(script.Parent.WorldData)

type P2 = WorldGen.P2

-------------------------------------------------------------------------------------------------------------------------
-- Types (the data contract every consumer builds against)
-------------------------------------------------------------------------------------------------------------------------

export type RoadClass =
	"freeway"
	| "ramp"
	| "highway"
	| "rural"
	| "boulevard"
	| "avenue"
	| "street"
	| "alley"
	| "dirt"
	| "pier"
	| "channel"
	| "runway"
	| "service"

export type Node = {
	id: number,
	pos: Vector3,
	edges: { number },
	intersection: number?,
}

export type Edge = {
	id: number,
	a: number, -- node ids; one-way edges are travelled a -> b
	b: number,
	points: { Vector3 }, -- centerline polyline, Y = road surface
	length: number,
	class: RoadClass,
	name: string,
	oneWay: boolean,
	lanesF: number, -- lanes travelling a -> b
	lanesB: number, -- lanes travelling b -> a (0 when one-way)
	laneWidth: number,
	median: number,
	parking: boolean,
	width: number, -- curb-to-curb (median, parking lanes and shoulders included)
	sidewalk: number, -- each side
	shoulder: number,
	shoulderOut: number, -- freeways: outside (right) / inside (left) shoulders
	shoulderIn: number,
	speed: number, -- AI cruise speed (studs/s)
	layer: number, -- 0 ground, 1 deck / trench, 2 / 3 flyover levels, -1 channel
	elevated: boolean, -- on a deck: needs supports
	sunken: boolean, -- below the natural grade in a walled cut (the H1 trench, the channel)
	fill: number, -- max height above the natural grade
	bridge: boolean, -- has bridge spans (water, the Rust River channel, a canyon)
	spans: { { number } }, -- bridge spans { s0, s1 } (arc length from a)
	tunnel: boolean,
	corridor: string?, -- freeway carriageways sharing one corridor
	district: string,
	traffic: boolean, -- AI traffic uses it
	aux: { { number } }, -- arc-length spans with an auxiliary right lane (merge / diverge / weave)
	tags: { string },
	way: number,
}

export type Approach = {
	edge: number,
	inbound: boolean,
	outbound: boolean,
	heading: Vector3, -- unit, pointing away from the node along the edge
	class: RoadClass,
	name: string,
	lanesIn: number,
}

-- movement: "all" (lefts yield), "through" (through + right; lefts held), "left" (protected lefts)
export type Phase = { approaches: { number }, green: number, movement: string }

export type Intersection = {
	id: number,
	node: number,
	pos: Vector3,
	control: "signal" | "stop" | "allway" | "yield" | "merge" | "none",
	radius: number, -- clear box: no parking, lots or props inside this radius
	approaches: { Approach },
	stopApproaches: { number },
	phases: { Phase },
	cycle: number,
	amber: number,
	allRed: number,
	offset: number, -- green-wave offset (seconds)
	district: string,
}

export type Gore = { node: number, ramp: number, carriageway: string, kind: string }

export type POI = {
	id: string,
	name: string,
	kind: string,
	brand: string?,
	district: string,
	cframe: CFrame, -- footprint center at ground; LookVector faces the street (front door side)
	size: Vector3, -- X frontage width, Y height, Z depth
	entrance: Vector3, -- curb point in front of the door
	edge: number, -- frontage edge
	tags: { string },
}

export type Plot = {
	index: number,
	name: string,
	district: string,
	cframe: CFrame, -- garage origin (v1 plot frame): ground centre at curb height, LookVector out of the door
	size: Vector3, -- reserved footprint (garage building + apron)
	door: Vector3,
	curbSpot: CFrame, -- right-hand curb spot just past the driveway (newbie car)
	edge: number,
	nearestOnRamp: number, -- straight-line studs to the closest on-ramp terminal
	onRampSeconds: number, -- time-weighted drive to the nearest on-ramp
	doorToPinnacle: number, -- degrees between the door heading and Pinnacle Tower
	service: { [string]: number }, -- road studs to the nearest police / gunshop / spray / chop / dealership / hospital
	onboardingOk: boolean, -- dealership <= 3k, gun shop <= 1.5k, police >= 800 (first-session plot preference)
	onboardingScore: number,
}

export type Parcel = {
	id: number,
	district: string,
	subzone: string?,
	use: string, -- office_tower, apartment, house, warehouse, parking_lot, plaza, park, ...
	cframe: CFrame, -- ground centre (Y = street level at the frontage), LookVector faces the street
	size: Vector3, -- X frontage width, Y target height (0 = open lot), Z depth
	floors: number,
	edge: number, -- frontage edge (0 for yard / hangar rows)
	style: string, -- facade style key (district / sub-zone)
	seed: number, -- deterministic variety
	tower: boolean?, -- part of the skyline plan
	podium: { number }?, -- { height, tower setback } for planned towers
	crown: string?, -- spire | slant | stepped | helipad | lit_band | machinery | flat
	stilts: boolean?, -- hills: ground falls away behind the frontage
}

export type Landmark = {
	id: string,
	name: string,
	kind: string,
	cframe: CFrame,
	size: Vector3,
	district: string,
	note: string?,
	edge: number?, -- bridges: the edge and span they stand on
	span: { number }?,
}

export type Zone = {
	id: string,
	name: string,
	cframe: CFrame,
	size: Vector3,
	district: string,
	note: string?,
	pool: string?, -- hot drops: "normal" | "longhaul"
	heat: number?, -- explicit stars for activities inside restricted zones
	exempt: { string }?,
	respawns: { CFrame }?,
	garagesWithin60s: number?,
}

export type StuntJump = {
	id: string,
	name: string,
	kind: string, -- kicker | drop | splash
	cframe: CFrame, -- lip; LookVector = jump direction
	size: Vector3,
	angle: number,
	minSpeed: number,
	landing: Vector3,
	airtime: number,
	apex: number,
	runup: number,
	heat: number?,
	note: string?,
}

export type Route = {
	id: string,
	name: string,
	kind: string, -- armored | race
	stops: { Vector3 },
	path: { Vector3 },
	edges: { number }, -- signed edge ids (negative = travelled b -> a)
	length: number,
	seconds: number,
	laps: number,
	policeClear: number?,
	doorClear: number?,
}

export type District = {
	id: string,
	name: string,
	style: string,
	materials: { string },
	polygon: { Vector3 },
	priority: number,
	height: { number },
	density: number,
	heat: number,
	carTier: string,
	color: { number },
	lot: any,
	sidewalk: number,
}

export type SubZone = {
	id: string,
	name: string,
	district: string,
	poly: { P2 },
	style: string?,
	materials: { string }?,
	height: { number }?,
	carTier: string?,
	note: string?,
}

export type ParkingSpot = { cframe: CFrame, edge: number, district: string, tier: string, side: number, s: number }
export type OffSpot = { cframe: CFrame, district: string, tier: string, parcel: number, kind: string }
export type PoliceSpawn = { cframe: CFrame, station: string, edge: number }
export type TrafficEdge = { edge: number, weight: number }

-- Streetscape placement: pos = ground point (sidewalk top), yaw = facing (degrees, CFrame.Angles convention).
export type Place = {
	kind: string,
	pos: Vector3,
	yaw: number,
	edge: number,
	h: number?,
	light: boolean?,
	run: number?,
	median: boolean?, -- palms planted in a boulevard median
}

export type Roadblock = {
	id: number,
	kind: string,
	edge: number,
	s: number,
	cframe: CFrame,
	width: number,
	lanes: number,
	trap: boolean,
}

export type Bridge = { edge: number, name: string, spans: { { number } }, kind: string }

-------------------------------------------------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------------------------------------------------

local WorldLayout = {}

WorldLayout.VERSION = Data.version :: number
WorldLayout.HASH = Data.hash :: string

WorldLayout.Scale = {
	STUD_METERS = 0.28,
	LANE = 12.5, -- 3.5 m travel lane
	PARKING_LANE = 9, -- 2.5 m curb parking lane
	SIDEWALK = 13, -- 3.6 m (12 suburbs .. 14 downtown)
	CURB_HEIGHT = 0.6, -- 17 cm
	STOREY = 12.5, -- 3.5 m floor-to-floor
	CAR_LENGTH = 17, -- 4.8 m sedan
	CAR_WIDTH = 7, -- 2.0 m
	CHARACTER_HEIGHT = 5.5,
	PARKING_SPACING = 24, -- curb spot pitch (car + gap)
	DECK = 28, -- freeway deck above grade (7.8 m)
	FLYOVER = 24, -- extra height per interchange level
	TRENCH = 26, -- H1 north leg cut below grade
	CLEARANCE = 16, -- min vertical clearance between crossing roads (4.5 m)
	FREEWAY_SHOULDER_OUT = 8,
	FREEWAY_SHOULDER_IN = 4,
	CARRIAGEWAY_GAP = 3, -- concrete barrier between freeway carriageways
	ALLEY_WIDTH = 18,
	GRAVITY = 196.2, -- equals default.project.json Workspace.Gravity (tests check)
}
local S = WorldLayout.Scale

WorldLayout.SEA_LEVEL = WorldTerrain.SEA_LEVEL
WorldLayout.GRADE = WorldTerrain.GRADE

WorldLayout.Bounds = {
	min = Vector3.new(-6600, -80, -5400),
	max = Vector3.new(6600, 1100, 5200),
	playMinX = -6300,
	playMaxX = 6300,
	playMinZ = -5100,
	playMaxZ = 4900,
}

-- AI cruise speeds (studs/s ~= km/h at 0.28 m/stud); they also weight routing (travel time).
WorldLayout.Speed = {
	freeway = 90,
	ramp = 55,
	highway = 85,
	rural = 66,
	boulevard = 60,
	avenue = 56,
	street = 42,
	alley = 22,
	dirt = 36,
	pier = 18,
	channel = 55,
	runway = 80,
	service = 25,
} :: { [string]: number }
-- Seconds lost at the junction you arrive at (expected wait), by control.
WorldLayout.JunctionDelay = { signal = 6, allway = 3, stop = 3, yield = 1, merge = 0, none = 0 } :: { [string]: number }
WorldLayout.MaxSpeed = (Data.maxSpeed or 90) :: number

-------------------------------------------------------------------------------------------------------------------------
-- Terrain (Util/WorldTerrain + the baked edits)
-------------------------------------------------------------------------------------------------------------------------

local function polyIn(flat: { number }): { P2 }
	local out: { P2 } = {}
	for i = 1, #flat, 2 do
		table.insert(out, { x = flat[i], z = flat[i + 1] })
	end
	return out
end

do
	local cuts: { WorldTerrain.Cut } = {}
	for _, c in Data.cuts do
		table.insert(cuts, { name = c.name, points = polyIn(c.points), half = c.half, floorY = c.floorY })
	end
	WorldTerrain.setEdits(Data.pads, cuts)
end

WorldLayout.Coast = WorldTerrain.Coast
WorldLayout.Islands = WorldTerrain.Islands
WorldLayout.Water = WorldTerrain.Water
WorldLayout.Channel = WorldTerrain.Channel
WorldLayout.TerrainZones = WorldTerrain.TerrainZones
WorldLayout.gradeAt = WorldTerrain.gradeAt
WorldLayout.heightAt = WorldTerrain.heightAt

-------------------------------------------------------------------------------------------------------------------------
-- Districts and sub-zones
-------------------------------------------------------------------------------------------------------------------------

local Districts: { District } = {}
local districtPolys: { { P2 } } = {}
local districtBoxes: { { number } } = {}
for i, d in Data.districts do
	local poly = polyIn(d.poly)
	local pts: { Vector3 } = {}
	for _, p in poly do
		table.insert(pts, Vector3.new(p.x, 0, p.z))
	end
	Districts[i] = {
		id = d.id,
		name = d.name,
		style = d.style,
		materials = d.materials,
		polygon = pts,
		priority = d.priority,
		height = d.height,
		density = d.density,
		heat = d.heat,
		carTier = d.carTier,
		color = d.color,
		lot = d.lot,
		sidewalk = d.sidewalk or 0,
	}
	districtPolys[i] = poly
	local x0, z0, x1, z1 = WorldGen.polyBounds(poly)
	districtBoxes[i] = { x0, z0, x1, z1 }
end
WorldLayout.Districts = Districts

-- Most specific district containing (x, z) (Red Mesa countryside when nothing else does).
function WorldLayout.districtAt(x: number, z: number): string
	local best, bestP = "mesa", -1
	for i, d in Districts do
		local bb = districtBoxes[i]
		if
			d.priority > bestP
			and x >= bb[1]
			and x <= bb[3]
			and z >= bb[2]
			and z <= bb[4]
			and WorldGen.pointInPoly(districtPolys[i], x, z)
		then
			best, bestP = d.id, d.priority
		end
	end
	return best
end

local SubZones: { SubZone } = {}
local subBoxes: { { number } } = {}
for i, z in Data.subzones do
	local copy: any = table.clone(z)
	copy.poly = polyIn(z.poly)
	SubZones[i] = copy
	local x0, z0, x1, z1 = WorldGen.polyBounds(copy.poly)
	subBoxes[i] = { x0, z0, x1, z1 }
end
WorldLayout.SubZones = SubZones

function WorldLayout.subzoneAt(x: number, z: number): SubZone?
	for i, sz in SubZones do
		local bb = subBoxes[i]
		if x >= bb[1] and x <= bb[3] and z >= bb[2] and z <= bb[4] and WorldGen.pointInPoly(sz.poly, x, z) then
			return sz
		end
	end
	return nil
end

WorldLayout.ActiveCore = polyIn(Data.activeCore)
local reserved: { { name: string, poly: { P2 } } } = {}
for _, r in Data.reserved do
	table.insert(reserved, { name = r.name, poly = polyIn(r.poly) })
end
WorldLayout.ReservedAreas = reserved

-------------------------------------------------------------------------------------------------------------------------
-- Road graph
-------------------------------------------------------------------------------------------------------------------------

local Nodes: { Node } = {}
for i, p in Data.nodes do
	Nodes[i] = { id = i, pos = p, edges = {}, intersection = nil }
end

local Edges: { Edge } = {}
for i, d in Data.edges do
	local flat: { number } = d.p
	local pts: { Vector3 } = table.create(#flat // 3)
	for k = 1, #flat, 3 do
		table.insert(pts, Vector3.new(flat[k], flat[k + 1], flat[k + 2]))
	end
	local spans: { { number } } = d.spans or {}
	local e: Edge = {
		id = i,
		a = d.a,
		b = d.b,
		points = pts,
		length = d.len,
		class = d.class,
		name = d.name,
		oneWay = d.oneWay == true,
		lanesF = d.lanesF or 0,
		lanesB = d.lanesB or 0,
		laneWidth = S.LANE,
		median = d.median or 0,
		parking = d.parking == true,
		width = d.width,
		sidewalk = d.sidewalk or 0,
		shoulder = d.shoulder or 0,
		shoulderOut = d.shoulderOut or 0,
		shoulderIn = d.shoulderIn or 0,
		speed = d.speed,
		layer = d.layer or 0,
		elevated = d.elevated == true,
		sunken = d.sunken == true,
		fill = d.fill or 0,
		bridge = #spans > 0,
		spans = spans,
		tunnel = d.tunnel == true,
		corridor = d.corridor,
		district = d.district,
		traffic = d.traffic == true,
		aux = d.aux or {},
		tags = d.tags or {},
		way = d.way or 0,
	}
	Edges[i] = e
	table.insert(Nodes[e.a].edges, i)
	if e.b ~= e.a then
		table.insert(Nodes[e.b].edges, i)
	end
end
WorldLayout.Nodes = Nodes
WorldLayout.Edges = Edges

local Intersections: { Intersection } = {}
for i, d in Data.intersections do
	local apps: { Approach } = {}
	for _, a in d.approaches do
		local e = Edges[a[1]]
		local flags = a[2]
		table.insert(apps, {
			edge = a[1],
			inbound = flags % 2 == 1,
			outbound = flags >= 2,
			heading = Vector3.new(a[3], 0, a[4]),
			class = e.class,
			name = e.name,
			lanesIn = a[5],
		})
	end
	local phases: { Phase } = {}
	for _, ph in d.phases or {} do
		local members: { number } = {}
		for k = 3, #ph do
			table.insert(members, ph[k])
		end
		table.insert(phases, { green = ph[1], movement = ph[2], approaches = members })
	end
	local it: Intersection = {
		id = i,
		node = d.node,
		pos = Nodes[d.node].pos,
		control = d.control,
		radius = d.radius,
		approaches = apps,
		stopApproaches = d.stopApproaches or {},
		phases = phases,
		cycle = d.cycle or 0,
		amber = d.amber or 3,
		allRed = d.allRed or 1.5,
		offset = d.offset or 0,
		district = d.district,
	}
	Intersections[i] = it
	Nodes[d.node].intersection = i
end
WorldLayout.Intersections = Intersections
WorldLayout.Gores = (Data.gores or {}) :: { Gore }
WorldLayout.Weaves = (Data.weaves or {}) :: { { number } }
WorldLayout.DroppedEdges = (Data.droppedEdges or {}) :: { string }

-- Turn kind from inbound approach a to outbound approach b: "left" | "right" | "through" | "uturn".
function WorldLayout.turnKind(a: Approach, b: Approach): string
	local inx, inz = -a.heading.X, -a.heading.Z
	local ox, oz = b.heading.X, b.heading.Z
	local rx, rz = WorldGen.right(inx, inz)
	local side = ox * rx + oz * rz
	local fwd = ox * inx + oz * inz
	if fwd < -0.85 then
		return "uturn"
	elseif side > 0.5 then
		return "right"
	elseif side < -0.5 then
		return "left"
	end
	return "through"
end

-------------------------------------------------------------------------------------------------------------------------
-- Places, zones, events, extra geometry
-------------------------------------------------------------------------------------------------------------------------

local function withDefaults<T>(list: { any }?, fill: (any) -> ()): { T }
	local out = list or {}
	for _, x in out do
		fill(x)
	end
	return out :: any
end

WorldLayout.POIs = withDefaults(Data.pois, function(p: any)
	p.tags = p.tags or {}
end) :: { POI }
WorldLayout.Plots = (Data.plots or {}) :: { Plot }
WorldLayout.Landmarks = (Data.landmarks or {}) :: { Landmark }
WorldLayout.HotDrops = (Data.hotDrops or {}) :: { Zone }
WorldLayout.HotDropRules = (Data.hotDropRules or {}) :: { [string]: number }
WorldLayout.StuntJumps = (Data.stuntJumps or {}) :: { StuntJump }
WorldLayout.Helipads = (Data.helipads or {}) :: { Zone }
WorldLayout.SafeZones = (Data.safeZones or {}) :: { Zone }
WorldLayout.RestrictedZones = (Data.restrictedZones or {}) :: { Zone }
WorldLayout.Routes = (Data.routes or {}) :: { Route }
WorldLayout.ArmoredRules = (Data.armoredRules or {}) :: { [string]: number }
WorldLayout.LiftBridge = Data.liftBridge :: any
WorldLayout.HeistDropoffs = (Data.heistDropoffs or {}) :: { any }
WorldLayout.CarSwaps = (Data.carSwaps or {}) :: { any }
WorldLayout.OnboardingOrder = (Data.onboardingOrder or {}) :: { number }
WorldLayout.Rails = (Data.rails or {}) :: { { name: string, points: { Vector3 }, tracks: number, spacing: number } }
WorldLayout.Paths = (Data.paths or {}) :: { { name: string, kind: string, width: number, points: { Vector3 } } }
WorldLayout.Bridges = (Data.bridges or {}) :: { Bridge }
WorldLayout.LevelCrossings = (Data.levelCrossings or {}) :: { { rail: string, edge: number, pos: Vector3 } }
WorldLayout.Stats = (Data.stats or {}) :: { [string]: any }
WorldLayout.PierDir = Data.pierDir :: any
WorldLayout.RingTrench = Data.ringTrench :: any
WorldLayout.PlacementErrors = {} :: { string } -- the generator's; the bake refuses nothing, the spec checks the build
WorldLayout.RouteErrors = {} :: { string }

-------------------------------------------------------------------------------------------------------------------------
-- Server-only data (lazy): lots, spawns, streetscape, roadblocks, ETA fields
-------------------------------------------------------------------------------------------------------------------------

local lotsData: any = nil
local function lots(): any
	if lotsData then
		return lotsData
	end
	local RunService = game:GetService("RunService")
	assert(RunService:IsServer(), "WorldLayout: lots / spawns / streetscape are server-only data")
	local sss = game:GetService("ServerScriptService")
	local server = sss:FindFirstChild("Server")
	local config = server and server:FindFirstChild("Config")
	local module = config and config:FindFirstChild("WorldDataLots")
	assert(
		module and module:IsA("ModuleScript"),
		"WorldLayout: ServerScriptService.Server.Config.WorldDataLots missing"
	)
	lotsData = require(module) :: any
	return lotsData
end

local trafficEdges: { TrafficEdge } = {}
for i, e in Edges do
	if e.traffic then
		table.insert(trafficEdges, { edge = i, weight = e.length * (e.lanesF + e.lanesB) })
	end
end

-- Spawns: the small sets are core; parking / offstreet / police come from the server-only module on first access.
local spawnsCore = Data.spawns or {}
local Spawns = {
	hospital = (spawnsCore.hospital or {}) :: { CFrame },
	default = (spawnsCore.default or CFrame.new(0, 15, 0)) :: CFrame,
	bustedRelease = (spawnsCore.bustedRelease or CFrame.new(0, 15, 0)) :: CFrame,
	traffic = trafficEdges,
	parking = (nil :: any) :: { ParkingSpot },
	offstreet = (nil :: any) :: { OffSpot },
	police = (nil :: any) :: { PoliceSpawn },
}
setmetatable(Spawns :: any, {
	__index = function(t: any, k: string): any
		if k == "parking" or k == "offstreet" or k == "police" then
			local v = lots()[k] or {}
			rawset(t, k, v)
			return v
		end
		return nil
	end,
})
WorldLayout.Spawns = Spawns

local LAZY: { [string]: string } = {
	Parcels = "parcels",
	Streetscape = "streetscape",
	Roadblocks = "roadblocks",
	EtaFields = "etaFields",
	TowerPlan = "towerPlan",
	PropClusters = "propClusters",
	Vistas = "vistas",
	SignSamples = "signSamples",
	SignVisibility = "signVisibility",
}
-- typed declarations for the lazy fields (nil until first access; resolved by the metatable below)
WorldLayout.Parcels = (nil :: any) :: { Parcel }
WorldLayout.Streetscape = (nil :: any) :: { [string]: { Place } }
WorldLayout.Roadblocks = (nil :: any) :: { Roadblock }
WorldLayout.EtaFields = (nil :: any) :: { [string]: { number } }
WorldLayout.TowerPlan = (nil :: any) :: { any }
WorldLayout.PropClusters = (nil :: any) :: { { kind: string, name: string, points: { Vector3 } } }
WorldLayout.Vistas = (nil :: any) :: { { name: string, pos: Vector3 } }
WorldLayout.SignSamples = (nil :: any) :: { Vector3 }
WorldLayout.SignVisibility = (nil :: any) :: { [string]: number }

-- Is the server-only data available here (server, module present)?
function WorldLayout.hasServerData(): boolean
	local ok = pcall(lots)
	return ok
end

setmetatable(WorldLayout :: any, {
	__index = function(t: any, k: string): any
		local key = LAZY[k]
		if key then
			local v = lots()[key]
			if v == nil then
				v = {}
			end
			rawset(t, k, v)
			return v
		end
		return nil
	end,
})

return WorldLayout
