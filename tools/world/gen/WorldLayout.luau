--!strict
-- WorldLayout generator (v2): the whole island city of Hotwire City as data. AUTHORING TOOL: it runs in Lune
-- (tools/world/gen.luau) and its output is baked by tools/world/bake.luau into
--   src/shared/Config/WorldData.luau          shared (server + clients): roads, junctions, POIs, plots, districts...
--   src/server/Config/WorldServerData.luau    server only: lots, spawns, routes, streetscape, ETA fields...
-- The game never runs this file. Design: docs/v2/world/WORLD_SPEC.md; migration: docs/v2/world/MIGRATION.md;
-- runtime queries: src/shared/Util/WorldQuery.luau.
--
-- Pure and deterministic: no Instances, no services, no Random. The hand-authored parts (freeway corridors and
-- interchanges, arterials, hill roads, POIs, plots, landmarks, jumps, routes) are plain tables below; repetitive
-- parts (district grids + alleys, lots, towers, parking, streetscape) are generated with Util/WorldGen. Terrain is
-- Util/WorldTerrain (shared with the runtime).
--
-- Axes: +X east, -Z north (map up), +Y up. Right-hand traffic. Heights: sea level 0, city grade 12.

local Shared = game:GetService("ReplicatedStorage").Shared
local WorldGen = require(Shared.Util.WorldGen)
local WorldTerrain = require(Shared.Util.WorldTerrain)

type P2 = WorldGen.P2
type P3 = WorldGen.P3

local WorldLayout = {}

WorldLayout.VERSION = 3

-- Terrain edits from a previous build must not leak into this one.
WorldTerrain.setEdits({}, {})

-------------------------------------------------------------------------------------------------------------------------
-- 1. Scale (lead decision: 1 stud ~= 0.28 m)
-------------------------------------------------------------------------------------------------------------------------

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
	FLYOVER = 24, -- extra height per interchange level (clearance 16 + deck 3 + margin)
	TRENCH = 26, -- H1 north leg cut below grade
	CLEARANCE = 16, -- min vertical clearance between crossing roads (4.5 m)
	FREEWAY_SHOULDER_OUT = 8,
	FREEWAY_SHOULDER_IN = 4,
	CARRIAGEWAY_GAP = 3, -- concrete barrier between freeway carriageways
	ALLEY_WIDTH = 18, -- shared single-lane alley (5 m)
	GRAVITY = 196.2, -- must equal default.project.json Workspace.Gravity (tests check); stunt jump arcs use it
}

local S = WorldLayout.Scale
local LANE = S.LANE

WorldLayout.SEA_LEVEL = WorldTerrain.SEA_LEVEL
WorldLayout.GRADE = WorldTerrain.GRADE
local GRADE = WorldLayout.GRADE
local DECK_Y = GRADE + S.DECK -- 40
local L2_Y = DECK_Y + S.FLYOVER -- 64
local L3_Y = L2_Y + S.FLYOVER -- 88
local TRENCH_Y = GRADE - S.TRENCH -- -14

WorldLayout.Bounds = {
	min = Vector3.new(-6600, -80, -5400),
	max = Vector3.new(6600, 1100, 5200),
	playMinX = -6300,
	playMaxX = 6300,
	playMinZ = -5100,
	playMaxZ = 4900,
}

-- AI cruise speeds (studs/s ~= km/h at 0.28 m/stud). These also weight routing (travel time), so the GPS, police and
-- armored trucks prefer the freeway the way drivers do.
local SPEED: { [string]: number } = {
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
}
WorldLayout.Speed = SPEED
-- Seconds lost at the junction you arrive at (expected wait), by control.
WorldLayout.JunctionDelay = { signal = 6, allway = 3, stop = 3, yield = 1, merge = 0, none = 0 }

-- Terrain (shared module) re-exported for the bake and the tools.
WorldLayout.Coast = WorldTerrain.Coast
WorldLayout.Islands = WorldTerrain.Islands
WorldLayout.Water = WorldTerrain.Water
WorldLayout.Channel = WorldTerrain.Channel
WorldLayout.TerrainZones = WorldTerrain.TerrainZones
local gradeAt = WorldTerrain.gradeAt
local heightAt = WorldTerrain.heightAt
local landAtLeast = WorldTerrain.landAtLeast
WorldLayout.gradeAt = gradeAt
WorldLayout.heightAt = heightAt

local SMOOTH = WorldGen.smoothstep

-------------------------------------------------------------------------------------------------------------------------
-- 2. Districts and sub-zones
-------------------------------------------------------------------------------------------------------------------------

export type LotRule = {
	width: { number }, -- frontage {min, max}
	depth: { number },
	setback: { number },
	density: number, -- share of frontage that gets a lot
	uses: { { any } }, -- { use, weight }
}

type DistrictDef = {
	id: string,
	name: string,
	style: string,
	materials: { string },
	poly: { P2 },
	priority: number,
	height: { number },
	density: number,
	heat: number,
	carTier: string,
	color: { number },
	lot: LotRule,
	sidewalk: number,
}

local function poly(list: { { number } }): { P2 }
	local out: { P2 } = {}
	for _, p in list do
		table.insert(out, { x = p[1], z = p[2] })
	end
	return out
end

local DISTRICTS: { DistrictDef } = {
	{
		id = "downtown",
		name = "Pinnacle Heights",
		style = "glass_towers",
		materials = { "GlassCurtain", "Concrete", "BrushedMetal", "Granite" },
		poly = poly({ { -1240, -2050 }, { 1590, -2020 }, { 1590, 1290 }, { -1240, 1290 } }),
		priority = 2,
		height = { 90, 300 },
		density = 0.96,
		heat = 4,
		carTier = "sports",
		color = { 92, 132, 196 },
		lot = {
			width = { 110, 170 },
			depth = { 110, 160 },
			setback = { 0, 6 },
			density = 0.96,
			uses = {
				{ "office_tower", 30 },
				{ "residential_tower", 14 },
				{ "office_midrise", 16 },
				{ "hotel", 6 },
				{ "parking_garage", 8 },
				{ "plaza", 6 },
				{ "retail", 14 },
			},
		},
		sidewalk = 14,
	},
	{
		id = "midtown",
		name = "Midtown",
		style = "commercial_midrise",
		materials = { "Stucco", "Brick", "Glass", "Concrete" },
		poly = poly({ { -3570, -2050 }, { -1240, -2050 }, { -1240, 1290 }, { -3570, 1290 } }),
		priority = 2,
		height = { 30, 200 },
		density = 0.92,
		heat = 3,
		carTier = "sedan",
		color = { 150, 118, 200 },
		lot = {
			width = { 70, 130 },
			depth = { 90, 125 },
			setback = { 0, 8 },
			density = 0.92,
			uses = {
				{ "office_midrise", 22 },
				{ "apartment", 26 },
				{ "retail", 24 },
				{ "restaurant", 8 },
				{ "hotel", 5 },
				{ "parking_lot", 9 },
				{ "parking_garage", 4 },
				{ "nightclub", 2 },
			},
		},
		sidewalk = 13,
	},
	{
		id = "beach",
		name = "Palmera Beach",
		style = "beach_deco",
		materials = { "PastelStucco", "WhiteConcrete", "Glass", "Wood" },
		poly = poly({ { -5700, -2250 }, { -3760, -2250 }, { -3760, 1720 }, { -5700, 1720 } }),
		priority = 2,
		height = { 24, 120 },
		density = 0.86,
		heat = 2,
		carTier = "muscle",
		color = { 238, 196, 120 },
		lot = {
			width = { 70, 120 },
			depth = { 80, 110 },
			setback = { 4, 12 },
			density = 0.86,
			uses = {
				{ "beach_hotel", 24 },
				{ "apartment", 26 },
				{ "retail", 18 },
				{ "restaurant", 14 },
				{ "parking_lot", 8 },
				{ "motel", 10 },
			},
		},
		sidewalk = 14,
	},
	{
		id = "hills",
		name = "Sunwood Hills",
		style = "hills_mansion",
		materials = { "WhiteStucco", "Travertine", "Glass", "Wood" },
		poly = poly({
			{ -5600, -2250 },
			{ -3760, -2250 },
			{ -3760, -1900 },
			{ 1800, -1880 },
			{ 2300, -4300 },
			{ 1500, -4800 },
			{ -5600, -4600 },
		}),
		priority = 1,
		height = { 22, 42 },
		density = 0.7,
		heat = 3,
		carTier = "super",
		color = { 110, 170, 100 },
		lot = {
			width = { 90, 150 },
			depth = { 90, 140 },
			setback = { 12, 25 },
			density = 0.82,
			uses = { { "mansion", 46 }, { "villa", 34 }, { "house", 20 } },
		},
		sidewalk = 0,
	},
	{
		id = "foundry",
		name = "The Foundry",
		style = "brick_lofts",
		materials = { "Brick", "CorrugatedMetal", "Concrete", "Glass" },
		poly = poly({ { 1590, -1900 }, { 3300, -1900 }, { 3300, 430 }, { 1590, 430 } }),
		priority = 2,
		height = { 24, 110 },
		density = 0.86,
		heat = 2,
		carTier = "sedan",
		color = { 196, 110, 84 },
		lot = {
			width = { 80, 150 },
			depth = { 100, 140 },
			setback = { 0, 6 },
			density = 0.86,
			uses = {
				{ "loft", 34 },
				{ "warehouse", 22 },
				{ "brewery", 7 },
				{ "gallery", 7 },
				{ "retail", 10 },
				{ "parking_lot", 10 },
				{ "office_midrise", 6 },
				{ "nightclub", 4 },
			},
		},
		sidewalk = 13,
	},
	{
		id = "rust",
		name = "Rust Flats",
		style = "industrial",
		materials = { "CorrugatedMetal", "RustyMetal", "Concrete", "Brick" },
		poly = poly({ { 1590, 430 }, { 3720, 430 }, { 3720, 3100 }, { 1590, 3060 } }),
		priority = 2,
		height = { 22, 70 },
		density = 0.72,
		heat = 1,
		carTier = "beater",
		color = { 150, 140, 120 },
		lot = {
			width = { 150, 260 },
			depth = { 140, 220 },
			setback = { 10, 30 },
			density = 0.74,
			uses = { { "warehouse", 44 }, { "factory", 24 }, { "yard", 16 }, { "shed", 10 }, { "parking_lot", 6 } },
		},
		sidewalk = 12,
	},
	{
		id = "southgate",
		name = "Southgate",
		style = "suburb_stucco",
		materials = { "Stucco", "RoofTile", "WoodSiding", "Concrete" },
		poly = poly({ { -2560, 1290 }, { 1590, 1290 }, { 1590, 3080 }, { -2340, 3080 }, { -2560, 2200 } }),
		priority = 2,
		height = { 16, 42 },
		density = 0.9,
		heat = 2,
		carTier = "sedan",
		color = { 222, 150, 104 },
		lot = {
			width = { 55, 72 },
			depth = { 90, 110 },
			setback = { 18, 24 },
			density = 0.9,
			uses = {
				{ "house", 70 },
				{ "duplex", 10 },
				{ "corner_store", 4 },
				{ "retail_strip", 6 },
				{ "church", 2 },
				{ "park", 3 },
				{ "parking_lot", 3 },
				{ "apartment", 2 },
			},
		},
		sidewalk = 12,
	},
	{
		id = "port",
		name = "Iron Bay",
		style = "port",
		materials = { "Concrete", "CorrugatedMetal", "PaintedSteel" },
		poly = poly({
			{ -1950, 3380 },
			{ 2800, 3360 },
			{ 3150, 3820 },
			{ 2820, 4560 },
			{ -1250, 4660 },
			{ -2000, 4080 },
		}),
		priority = 2,
		height = { 20, 64 },
		density = 0.8,
		heat = 4,
		carTier = "muscle",
		color = { 96, 150, 160 },
		lot = {
			width = { 180, 300 },
			depth = { 150, 220 },
			setback = { 10, 20 },
			density = 0.85,
			uses = { { "container_yard", 50 }, { "warehouse", 35 }, { "shed", 15 } },
		},
		sidewalk = 10,
	},
	{
		id = "airport",
		name = "Hotwire International",
		style = "airport",
		materials = { "Concrete", "Glass", "PaintedSteel" },
		poly = poly({
			{ -5980, 2750 },
			{ -4800, 2680 },
			{ -4700, 1720 },
			{ -2560, 1720 },
			{ -2560, 2200 },
			{ -2240, 3250 },
			{ -2720, 4120 },
			{ -3050, 4400 },
			{ -5650, 4500 },
			{ -6000, 4180 },
		}),
		priority = 2,
		height = { 20, 90 },
		density = 0.6,
		heat = 5,
		carTier = "sedan",
		color = { 170, 176, 190 },
		lot = {
			width = { 160, 260 },
			depth = { 140, 200 },
			setback = { 20, 30 },
			density = 0.5,
			uses = { { "hangar", 40 }, { "warehouse", 30 }, { "parking_lot", 30 } },
		},
		sidewalk = 12,
	},
	{
		id = "cactus",
		name = "Cactus Junction",
		style = "desert_town",
		materials = { "Adobe", "WoodSiding", "CorrugatedMetal" },
		poly = poly({ { 3880, -980 }, { 4780, -980 }, { 4780, -120 }, { 3880, -120 } }),
		priority = 3,
		height = { 14, 36 },
		density = 0.75,
		heat = 1,
		carTier = "muscle",
		color = { 214, 160, 96 },
		lot = {
			width = { 70, 110 },
			depth = { 80, 120 },
			setback = { 8, 16 },
			density = 0.75,
			uses = {
				{ "house", 44 },
				{ "shop", 20 },
				{ "diner", 8 },
				{ "motel", 8 },
				{ "shed", 12 },
				{ "parking_lot", 8 },
			},
		},
		sidewalk = 10,
	},
	{
		id = "driftwood",
		name = "Driftwood",
		style = "beach_shack",
		materials = { "WoodSiding", "WeatheredWood", "CorrugatedMetal" },
		poly = poly({ { 5560, -2520 }, { 6100, -2520 }, { 6100, -1880 }, { 5560, -1880 } }),
		priority = 3,
		height = { 14, 30 },
		density = 0.7,
		heat = 1,
		carTier = "muscle",
		color = { 226, 190, 140 },
		lot = {
			width = { 60, 100 },
			depth = { 70, 100 },
			setback = { 6, 14 },
			density = 0.8,
			uses = { { "house", 40 }, { "shop", 20 }, { "diner", 14 }, { "motel", 12 }, { "parking_lot", 14 } },
		},
		sidewalk = 10,
	},
	{
		id = "mesa",
		name = "Red Mesa",
		style = "desert_rural",
		materials = { "Sandstone", "WoodSiding", "CorrugatedMetal" },
		poly = poly({
			{ 1800, -1880 },
			{ 1590, -1900 },
			{ 3300, -1900 },
			{ 3300, 430 },
			{ 3720, 430 },
			{ 3720, 3100 },
			{ 4000, 4100 },
			{ 6400, 4100 },
			{ 6400, -5000 },
			{ 1500, -5000 },
			{ 2300, -4300 },
		}),
		priority = 1,
		height = { 14, 30 },
		density = 0.15,
		heat = 1,
		carTier = "muscle",
		color = { 200, 120, 80 },
		lot = {
			width = { 120, 220 },
			depth = { 120, 200 },
			setback = { 40, 60 },
			density = 0.14,
			uses = { { "farmhouse", 40 }, { "barn", 30 }, { "shed", 30 } },
		},
		sidewalk = 0,
	},
}

local districtById: { [string]: DistrictDef } = {}
for _, d in DISTRICTS do
	districtById[d.id] = d
end

local districtBoxes: { { number } } = {}
for i, d in DISTRICTS do
	local x0, z0, x1, z1 = WorldGen.polyBounds(d.poly)
	districtBoxes[i] = { x0, z0, x1, z1 }
end

local function districtAt(x: number, z: number): string
	local best, bestP = "mesa", -1
	for i, d in DISTRICTS do
		local bb = districtBoxes[i]
		if
			d.priority > bestP
			and x >= bb[1]
			and x <= bb[3]
			and z >= bb[2]
			and z <= bb[4]
			and WorldGen.pointInPoly(d.poly, x, z)
		then
			best, bestP = d.id, d.priority
		end
	end
	return best
end
WorldLayout.districtAt = districtAt

-- Sub-zones: style / height / use overrides inside a district (so downtown is not one style everywhere), plus the
-- rules the parking-tier and streetscape passes read. Lots within `blend` of a district or sub-zone border dither
-- between the two styles (no hard seams).
export type SubZone = {
	id: string,
	name: string,
	district: string,
	poly: { P2 },
	style: string?,
	materials: { string }?,
	height: { number }?,
	uses: { { any } }?,
	setback: { number }?,
	width: { number }?,
	carTier: string?,
	note: string?,
}

local SUBZONES: { SubZone } = {
	{
		id = "financial",
		name = "Financial Core",
		district = "downtown",
		poly = poly({ { -500, -1000 }, { 900, -1000 }, { 900, 300 }, { -500, 300 } }),
		style = "glass_towers",
		height = { 120, 300 },
		carTier = "sports",
		note = "glass curtain walls; the explicit tower plan stands here",
	},
	{
		id = "oldtown",
		name = "Old Town",
		district = "downtown",
		poly = poly({ { -1240, -2050 }, { -500, -2050 }, { -500, 300 }, { -1240, 300 } }),
		style = "brick_terracotta",
		materials = { "Brick", "Terracotta", "Limestone", "Glass" },
		height = { 60, 180 },
		uses = {
			{ "office_midrise", 30 },
			{ "apartment", 24 },
			{ "theater", 6 },
			{ "retail", 24 },
			{ "hotel", 8 },
			{ "parking_garage", 8 },
		},
		carTier = "sedan",
		note = "1920s brick and terracotta, cornices, theater marquees",
	},
	{
		id = "civic",
		name = "Civic Center",
		district = "downtown",
		poly = poly({ { -600, 300 }, { 300, 300 }, { 300, 900 }, { -600, 900 } }),
		style = "civic_stone",
		materials = { "Limestone", "Granite", "Concrete", "Glass" },
		height = { 40, 140 },
		uses = { { "civic", 40 }, { "office_midrise", 30 }, { "plaza", 15 }, { "parking_garage", 15 } },
		carTier = "sedan",
		note = "City Hall (stepped tower, pyramid top) and Liberty Square",
	},
	{
		id = "warehouse_edge",
		name = "Arts Warehouse Edge",
		district = "downtown",
		poly = poly({ { 1000, 500 }, { 1590, 500 }, { 1590, 1290 }, { 1000, 1290 } }),
		style = "brick_lofts",
		materials = { "Brick", "CorrugatedMetal", "PaintedMural" },
		height = { 24, 80 },
		uses = { { "warehouse", 30 }, { "loft", 30 }, { "parking_lot", 25 }, { "gallery", 15 } },
		carTier = "beater",
		note = "low warehouses, surface lots, murals",
	},
	{
		id = "palmera_north",
		name = "Palmera North (condo towers)",
		district = "beach",
		poly = poly({ { -4520, -2100 }, { -3760, -2100 }, { -3760, -1080 }, { -4520, -1080 } }),
		height = { 40, 120 },
		carTier = "sports",
		note = "condo tower cluster north of the pier",
	},
	{
		id = "palmera_south",
		name = "Palmera South (deco strip)",
		district = "beach",
		poly = poly({ { -4600, -900 }, { -3760, -900 }, { -3760, 1720 }, { -4600, 1720 } }),
		height = { 24, 70 },
		uses = {
			{ "beach_hotel", 24 },
			{ "apartment", 22 },
			{ "retail", 18 },
			{ "restaurant", 16 },
			{ "parking_lot", 8 },
			{ "motel", 12 },
		},
		carTier = "muscle",
		note = "low art-deco hotels: 24-70 studs",
	},
	{
		id = "gilded",
		name = "Gilded Mile",
		district = "midtown",
		poly = poly({ { -2400, -700 }, { -1500, -700 }, { -1500, 150 }, { -2400, 150 } }),
		height = { 60, 200 },
		carTier = "sports",
		note = "hotel tower cluster at Gilded Mile x Crown",
	},
	{
		id = "strip",
		name = "The Strip (Sunwood Boulevard)",
		district = "hills",
		poly = poly({ { -2400, -2330 }, { -600, -2330 }, { -600, -1900 }, { -2400, -1900 } }),
		style = "strip_commercial",
		materials = { "Stucco", "Neon", "Glass", "Concrete" },
		height = { 24, 60 },
		width = { 60, 110 },
		setback = { 0, 6 },
		uses = { { "nightclub", 28 }, { "retail", 26 }, { "restaurant", 24 }, { "hotel", 8 }, { "theater", 6 }, { "parking_lot", 8 } },
		carTier = "sports",
		note = "clubs, a theater, rooftop billboards; 0-6 setbacks",
	},
}
WorldLayout.SubZones = SUBZONES

local subzoneBoxes: { { number } } = {}
for i, z in SUBZONES do
	local x0, z0, x1, z1 = WorldGen.polyBounds(z.poly)
	subzoneBoxes[i] = { x0, z0, x1, z1 }
end

local function subzoneAt(x: number, z: number): SubZone?
	for i, sz in SUBZONES do
		local bb = subzoneBoxes[i]
		if x >= bb[1] and x <= bb[3] and z >= bb[2] and z <= bb[4] and WorldGen.pointInPoly(sz.poly, x, z) then
			return sz
		end
	end
	return nil
end
WorldLayout.subzoneAt = subzoneAt

-- Active Core: where 8 players actually meet (gameplay critique 5). Garages, most Hot Drops, the bank, dealerships,
-- gun shops and every armored run's start or end must be inside it (tests).
WorldLayout.ActiveCore = poly({ { -4700, -2400 }, { 3000, -2400 }, { 3000, 2600 }, { -4700, 2600 } })

-------------------------------------------------------------------------------------------------------------------------
-- 3. Road ways (authored + generated) -> graph
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

type YMode = "ground" | "deck" | "ramp" | "profile" | "fixed" | "table"

-- A freeway carriageway as geometry (the full polyline, before it is split into ways where its lane count changes).
type Carriageway = {
	name: string,
	pts: { P2 },
	cum: { number },
	lanesAt: (s: number) -> number, -- through lanes at arc length s
	yAt: (x: number, z: number) -> number, -- deck height at the point nearest (x, z)
	ways: { any }, -- the Way pieces
}

-- Ramp / flyover vertical design inputs (resolved by profileRamps).
type RampInfo = {
	level: number, -- 1 deck / diamond / direct ramp, 2 = first flyover level, 3 = second
	startCar: Carriageway?, -- diverges from this carriageway (gore at the start)
	endCar: Carriageway?, -- merges into this carriageway (gore at the end)
	startCont: any?, -- continues this way (no gore): overlap with it near the start is expected
	endCont: any?,
	startY: number?,
	endY: number?,
	ease: boolean?, -- eased between the holds (diamond ramps)
	stub: boolean?, -- dead-end construction stub
}

type Way = {
	id: number,
	name: string,
	class: RoadClass,
	pts: { P2 },
	lanes: number, -- per direction (one-way: total)
	oneWay: boolean,
	median: number,
	parking: boolean,
	sidewalk: number,
	shoulder: number,
	speed: number,
	layer: number,
	noCross: boolean,
	keepDeadEnd: boolean,
	traffic: boolean,
	corridor: string?,
	generated: boolean,
	district: string?,
	widthOverride: number?,
	carriage: Carriageway?,
	ramp: RampInfo?,
	tags: { [string]: boolean }?,
	-- vertical
	yMode: YMode,
	y0: number?,
	y1: number?,
	fixedY: number?,
	profile: ((s: number, L: number) -> number)?,
	minProfile: ((s: number, L: number) -> number)?, -- ground mode: never below this
	maxProfile: ((s: number, L: number) -> number)?, -- ground mode: never above this (cut corridors)
	maxGrade: number,
	bridges: { { number } }?, -- arc-length spans flown over (Y linear between the span ends)
	tunnels: { { number } }?, -- arc-length spans under terrain
	ys: { number }?, -- computed per point
	ysTable: { number }?, -- table mode: heights per point of pts
}

local ways: { Way } = {}

local CLASS_DEFAULTS: { [string]: { lanes: number, median: number, parking: boolean, sidewalk: number, shoulder: number, grade: number } } =
	{
		freeway = { lanes = 3, median = 0, parking = false, sidewalk = 0, shoulder = 0, grade = 0.07 },
		ramp = { lanes = 1, median = 0, parking = false, sidewalk = 0, shoulder = 3, grade = 0.08 },
		highway = { lanes = 2, median = 16, parking = false, sidewalk = 0, shoulder = 7, grade = 0.08 },
		rural = { lanes = 1, median = 0, parking = false, sidewalk = 0, shoulder = 5, grade = 0.11 },
		boulevard = { lanes = 3, median = 12, parking = false, sidewalk = 14, shoulder = 0, grade = 0.08 },
		avenue = { lanes = 2, median = 10, parking = true, sidewalk = 13, shoulder = 0, grade = 0.1 },
		street = { lanes = 1, median = 0, parking = true, sidewalk = 12, shoulder = 0, grade = 0.13 },
		alley = { lanes = 1, median = 0, parking = false, sidewalk = 0, shoulder = 0, grade = 0.14 },
		dirt = { lanes = 1, median = 0, parking = false, sidewalk = 0, shoulder = 2, grade = 0.14 },
		pier = { lanes = 1, median = 0, parking = false, sidewalk = 10, shoulder = 0, grade = 0.05 },
		channel = { lanes = 2, median = 0, parking = false, sidewalk = 0, shoulder = 10, grade = 0.05 },
		runway = { lanes = 2, median = 0, parking = false, sidewalk = 0, shoulder = 25, grade = 0.02 },
		service = { lanes = 1, median = 0, parking = false, sidewalk = 0, shoulder = 2, grade = 0.12 },
	}

type WayOpts = {
	lanes: number?,
	oneWay: boolean?,
	median: number?,
	parking: boolean?,
	sidewalk: number?,
	shoulder: number?,
	speed: number?,
	layer: number?,
	noCross: boolean?,
	keepDeadEnd: boolean?,
	traffic: boolean?,
	corridor: string?,
	generated: boolean?,
	district: string?,
	widthOverride: number?,
	carriage: Carriageway?,
	ramp: RampInfo?,
	tags: { [string]: boolean }?,
	yMode: YMode?,
	y0: number?,
	y1: number?,
	fixedY: number?,
	profile: ((s: number, L: number) -> number)?,
	minProfile: ((s: number, L: number) -> number)?,
	maxProfile: ((s: number, L: number) -> number)?,
	maxGrade: number?,
	bridges: { { number } }?,
	tunnels: { { number } }?,
}

local function addWay(name: string, class: RoadClass, pts: { P2 }, o: WayOpts?): Way
	local opts: WayOpts = o or {}
	local def = CLASS_DEFAULTS[class]
	local w: Way = {
		id = #ways + 1,
		name = name,
		class = class,
		pts = pts,
		lanes = opts.lanes or def.lanes,
		oneWay = opts.oneWay == true,
		median = opts.median or def.median,
		parking = if opts.parking ~= nil then opts.parking else def.parking,
		sidewalk = opts.sidewalk or def.sidewalk,
		shoulder = opts.shoulder or def.shoulder,
		speed = opts.speed or SPEED[class],
		layer = opts.layer or 0,
		noCross = opts.noCross == true,
		keepDeadEnd = opts.keepDeadEnd == true,
		traffic = if opts.traffic ~= nil
			then opts.traffic
			else (
				class ~= "pier"
				and class ~= "channel"
				and class ~= "runway"
				and class ~= "service"
				and class ~= "alley"
			),
		corridor = opts.corridor,
		generated = opts.generated == true,
		district = opts.district,
		widthOverride = opts.widthOverride or (if class == "alley" then S.ALLEY_WIDTH else nil),
		carriage = opts.carriage,
		ramp = opts.ramp,
		tags = opts.tags,
		yMode = opts.yMode or "ground",
		y0 = opts.y0,
		y1 = opts.y1,
		fixedY = opts.fixedY,
		profile = opts.profile,
		minProfile = opts.minProfile,
		maxProfile = opts.maxProfile,
		maxGrade = opts.maxGrade or def.grade,
		bridges = opts.bridges,
		tunnels = opts.tunnels,
	}
	table.insert(ways, w)
	return w
end

local function carriagewayWidth(lanes: number): number
	return lanes * LANE + S.FREEWAY_SHOULDER_OUT + S.FREEWAY_SHOULDER_IN
end

-- Curb-to-curb width of a way.
local function wayWidth(w: Way): number
	if w.widthOverride then
		return w.widthOverride
	end
	local lanesTotal = if w.oneWay then w.lanes else w.lanes * 2
	local park = if w.parking then 2 * S.PARKING_LANE else 0
	if w.class == "freeway" then
		return carriagewayWidth(w.lanes)
	end
	return lanesTotal * LANE + w.median + park + 2 * w.shoulder
end

local function P(x: number, z: number): P2
	return { x = x, z = z }
end

local function reversed(pts: { P2 }): { P2 }
	local out: { P2 } = {}
	for i = #pts, 1, -1 do
		table.insert(out, pts[i])
	end
	return out
end

local function append(dst: { P2 }, src: { P2 })
	for i, p in src do
		local last = dst[#dst]
		if i == 1 and last and WorldGen.dist(last.x, last.z, p.x, p.z) < 0.5 then
			continue
		end
		table.insert(dst, p)
	end
end

local function unit(dx: number, dz: number): (number, number)
	local l = math.sqrt(dx * dx + dz * dz)
	if l < 1e-9 then
		return 1, 0
	end
	return dx / l, dz / l
end

-- Point and travel tangent at arc length s along a polyline (with a lateral offset to the right of travel).
local function along(pts: { P2 }, s: number, lat: number?): (P2, number, number)
	local x, z, tx, tz = WorldGen.polyAt(pts, s)
	local d = lat or 0
	local rx, rz = WorldGen.right(tx, tz)
	return P(x + rx * d, z + rz * d), tx, tz
end

-- Cubic Bezier between two points with given unit headings (handles scaled by k * distance).
local function curve(a: P2, ax: number, az: number, b: P2, bx: number, bz: number, k: number?): { P2 }
	local d = WorldGen.dist(a.x, a.z, b.x, b.z)
	local h = (k or 0.42) * d
	return WorldGen.bezier(a, P(a.x + ax * h, a.z + az * h), P(b.x - bx * h, b.z - bz * h), b, 10)
end

-- Sub-polyline between arc lengths, in either direction (s0 > s1 walks backwards).
local function sliceDir(pts: { P2 }, s0: number, s1: number): { P2 }
	if s0 <= s1 then
		return WorldGen.polySlice(pts, s0, s1)
	end
	return reversed(WorldGen.polySlice(pts, s1, s0))
end

-- Auxiliary-lane centre: lateral offset to the right of travel for a carriageway with `lanes` through lanes.
local function auxOffset(lanes: number): number
	local cw = carriagewayWidth(lanes)
	return -cw / 2 + S.FREEWAY_SHOULDER_IN + lanes * LANE + LANE / 2
end
-- Lateral clearance a ramp needs from a carriageway centerline before it may leave the deck plane (deck edge with
-- the auxiliary lane + barrier + the ramp's own half width).
local RAMP_HALF = (LANE + 2 * 3) / 2
local function holdClear(lanes: number): number
	return auxOffset(lanes) + LANE / 2 + 2 + RAMP_HALF + 1.5
end

local TAPER = 75 -- gore taper length (ramp centerline leaves the carriageway centerline for the auxiliary lane)

-- Diverge gore: from the carriageway centerline at arc s (a graph node) out to the auxiliary lane over TAPER.
local function goreOut(c: Carriageway, s: number): { P2 }
	local aux = auxOffset(c.lanesAt(s))
	local out: { P2 } = {}
	local n = 6
	for k = 0, n do
		local t = k / n
		local p = along(c.pts, s + TAPER * t, aux * t * t * (3 - 2 * t))
		table.insert(out, p)
	end
	return out
end

-- Merge gore: from the auxiliary lane back onto the carriageway centerline at arc s.
local function goreIn(c: Carriageway, s: number): { P2 }
	local aux = auxOffset(c.lanesAt(s))
	local out: { P2 } = {}
	local n = 6
	for k = 0, n do
		local t = k / n
		local u = 1 - t
		local p = along(c.pts, s - TAPER * u, aux * u * u * (3 - 2 * u))
		table.insert(out, p)
	end
	return out
end

local function carS(c: Carriageway, x: number, z: number): number
	local _, s = WorldGen.polyProject(c.pts, x, z)
	return s
end

-- Gores recorded for the builders (barrier cuts) and the auxiliary-lane pass.
type GoreRec = { car: Carriageway, s: number, kind: string, ramp: string }
local goreRecs: { GoreRec } = {}

local function rampWay(name: string, pts: { P2 }, info: RampInfo, o: WayOpts?): Way
	local opts: WayOpts = o or {}
	opts.oneWay = true
	opts.noCross = true
	opts.layer = opts.layer or (if info.level >= 2 then info.level else 1)
	opts.ramp = info
	opts.yMode = "table"
	local w = addWay(name, "ramp", pts, opts)
	if info.startCar then
		local c = info.startCar :: Carriageway
		table.insert(goreRecs, { car = c, s = carS(c, pts[1].x, pts[1].z), kind = "diverge", ramp = name })
	end
	if info.endCar then
		local c = info.endCar :: Carriageway
		table.insert(goreRecs, { car = c, s = carS(c, pts[#pts].x, pts[#pts].z), kind = "merge", ramp = name })
	end
	return w
end

-------------------------------------------------------------------------------------------------------------------------
-- 3a. Corridors (two one-way carriageways around a centerline; offsets and lane counts may vary along it)
-------------------------------------------------------------------------------------------------------------------------

type Corridor = {
	name: string,
	center: { P2 },
	cum: { number },
	fwd: Carriageway, -- right of the centerline direction, travels with it
	bwd: Carriageway, -- left, travels against it
	offsetAt: (s: number) -> number,
	lanesAt: (s: number) -> number,
	yAtCenter: (s: number) -> number,
	setProfile: (fn: (sc: number) -> number) -> (),
}

type CorridorOpts = {
	lanesAt: ((s: number) -> number)?,
	offsetAt: ((s: number) -> number)?,
	breaks: { number }?, -- centerline arc lengths where the carriageway ways are split (lane changes)
	way: WayOpts?,
}

local function corridor(name: string, center: { P2 }, lanes: number, labels: { string }, co: CorridorOpts?): Corridor
	local copts: CorridorOpts = co or {}
	local cum = WorldGen.polyCum(center)
	local L = cum[#cum]
	local lanesAt = copts.lanesAt or function(_s: number): number
		return lanes
	end
	local offsetAt = copts.offsetAt
		or function(s: number): number
			return carriagewayWidth(lanesAt(s)) / 2 + S.CARRIAGEWAY_GAP / 2
		end
	local profileFn: (sc: number) -> number = function(_sc: number): number
		return DECK_Y
	end
	local function centerS(x: number, z: number): number
		local _, s = WorldGen.polyProject(center, x, z)
		return s
	end
	local function makeCar(side: number, label: string): Carriageway
		local pts = WorldGen.polyOffsetVar(center, function(i: number, _s: number): number
			return side * offsetAt(cum[i])
		end)
		if side < 0 then
			pts = reversed(pts)
		end
		local car: Carriageway = {
			name = name .. " " .. label,
			pts = pts,
			cum = WorldGen.polyCum(pts),
			lanesAt = function(s: number): number
				local x, z = WorldGen.polyAt(pts, s)
				return lanesAt(centerS(x, z))
			end,
			yAt = function(x: number, z: number): number
				return profileFn(centerS(x, z))
			end,
			ways = {},
		}
		-- split into ways at the breaks (centerline arc lengths, mapped onto this carriageway)
		local cuts: { number } = {}
		for _, b in copts.breaks or {} do
			local bx, bz = WorldGen.polyAt(center, b)
			local _, sb = WorldGen.polyProject(pts, bx, bz)
			table.insert(cuts, sb)
		end
		table.sort(cuts)
		local Lc = car.cum[#car.cum]
		local s0 = 0
		table.insert(cuts, Lc)
		for _, s1 in cuts do
			if s1 - s0 > 1 then
				local piece = WorldGen.polySlice(pts, s0, s1)
				local mx, mz = WorldGen.polyAt(pts, (s0 + s1) / 2)
				local opts: WayOpts = {}
				for k, v in (copts.way or {}) :: any do
					(opts :: any)[k] = v
				end
				opts.lanes = lanesAt(centerS(mx, mz))
				opts.oneWay = true
				opts.layer = opts.layer or 1
				opts.corridor = name
				opts.carriage = car
				opts.yMode = "profile"
				local w = addWay(name .. " " .. label, "freeway", piece, opts)
				local wp = w
				wp.profile = function(s: number, _L: number): number
					local x, z = WorldGen.polyAt(wp.pts, s)
					return profileFn(centerS(x, z))
				end
				table.insert(car.ways, w)
				s0 = s1
			end
		end
		return car
	end
	local fwd = makeCar(1, labels[1])
	local bwd = makeCar(-1, labels[2])
	local c: Corridor = {
		name = name,
		center = center,
		cum = cum,
		fwd = fwd,
		bwd = bwd,
		offsetAt = offsetAt,
		lanesAt = lanesAt,
		yAtCenter = function(s: number): number
			return profileFn(s)
		end,
		setProfile = function(fn: (sc: number) -> number)
			profileFn = fn
		end,
	}
	local _ = L
	return c
end

-- Ground-following carriageways (the H9 descending into Sunwood Canyon): switch every way of a corridor to ground mode.
local function groundCorridor(c: Corridor, minProfile: (x: number, z: number) -> number, maxGrade: number)
	for _, car in { c.fwd, c.bwd } do
		for _, w in car.ways do
			local wp = w
			wp.yMode = "ground"
			wp.maxGrade = maxGrade
			wp.minProfile = function(s: number, _L: number): number
				local x, z = WorldGen.polyAt(wp.pts, s)
				return minProfile(x, z)
			end
		end
		local carRef = car
		carRef.yAt = function(x: number, z: number): number
			return math.max(gradeAt(x, z), minProfile(x, z))
		end
	end
end

-- Merge two carriageways of a corridor into one two-way road over the corridor's last `len` studs.
local function corridorTail(c: Corridor, len: number, name: string, class: RoadClass, o: WayOpts?): Way
	local L = c.cum[#c.cum]
	local mx, mz = WorldGen.polyAt(c.center, L - len)
	local m = P(mx, mz)
	-- forward carriageway: its last way ends at the merge point; backward: its first way starts there
	local fw = c.fwd.ways[#c.fwd.ways]
	local _, s = WorldGen.polyProject(fw.pts, mx, mz)
	local pts = WorldGen.polySlice(fw.pts, 0, math.max(0, s - 160))
	local _, _, tx, tz = WorldGen.polyAt(fw.pts, s - 160)
	local a = pts[#pts]
	append(pts, WorldGen.bezier(a, P(a.x + tx * 70, a.z + tz * 70), P(m.x - tx * 35, m.z - tz * 35), m, 20))
	fw.pts = pts
	local bw = c.bwd.ways[1]
	local wl = WorldGen.polyLength(bw.pts)
	local _, s2 = WorldGen.polyProject(bw.pts, mx, mz)
	local rest = WorldGen.polySlice(bw.pts, math.min(wl, s2 + 160), wl)
	local _, _, tx2, tz2 = WorldGen.polyAt(bw.pts, s2 + 160)
	local b = rest[1]
	local head = WorldGen.bezier(m, P(m.x + tx2 * 35, m.z + tz2 * 35), P(b.x - tx2 * 70, b.z - tz2 * 70), b, 20)
	append(head, rest)
	bw.pts = head
	local tail = WorldGen.polySlice(c.center, L - len, L)
	return addWay(name, class, tail, o)
end

-------------------------------------------------------------------------------------------------------------------------
-- 3b. Interchanges. Every ramp leaves / joins a carriageway at a gore (a graph node on the carriageway centerline,
--     then a taper onto the auxiliary lane). Heights are designed afterwards by profileRamps (section 3d).
-------------------------------------------------------------------------------------------------------------------------

local GeometryErrors: { string } = {}
WorldLayout.GeometryErrors = GeometryErrors

-- Diamond (or half diamond) where surface road `ave` crosses corridor `main` near (cx, cz). Ramps run along guide
-- lines offset from the corridor centerline (so they follow curves) and end at signalized terminals on the avenue.
-- ramps = "full" | "a+" | "a-": a+ keeps only the ramps on the +centerline-direction side of the avenue.
type DiamondOpts = { ld: number?, ramps: string?, label: string? }
local function diamond(main: Corridor, ave: Way, cx: number, cz: number, dopts: DiamondOpts?)
	local o: DiamondOpts = dopts or {}
	local ld = o.ld or 500
	local which = o.ramps or "full"
	local _, sC = WorldGen.polyProject(main.center, cx, cz)
	local Lc = main.cum[#main.cum]
	for _, side in { 1, -1 } do
		local car = if side > 0 then main.fwd else main.bwd
		local dir = side -- fwd travels with the centerline, bwd against it
		for _, kind in { "off", "on" } do
			local sign = if kind == "off" then -dir else dir
			if (which == "a+" and sign < 0) or (which == "a-" and sign > 0) then
				continue
			end
			local sPortC = sC + sign * ld
			local px, pz = WorldGen.polyAt(main.center, sPortC)
			local sCar = carS(car, px, pz)
			local lanes = car.lanesAt(sCar)
			local lateral = main.offsetAt(sC) + holdClear(lanes) + 6
			-- guide (centerline offset), walked in the carriageway's travel direction, extended past the avenue
			local gFrom, gTo
			if kind == "off" then
				gFrom, gTo = sPortC + dir * (TAPER + 120), sC + dir * 200
			else
				gFrom, gTo = sC - dir * 200, sPortC - dir * (TAPER + 120)
			end
			local lo, hi = math.clamp(math.min(gFrom, gTo), 0, Lc), math.clamp(math.max(gFrom, gTo), 0, Lc)
			local guide = WorldGen.polyOffset(WorldGen.polySlice(main.center, lo, hi), side * lateral)
			if dir < 0 then
				guide = reversed(guide)
			end
			-- terminal: first crossing of the guide with the avenue
			local hit: P2? = nil
			local hitSeg = 0
			for i = 1, #guide - 1 do
				local a, b = guide[i], guide[i + 1]
				for k = 1, #ave.pts - 1 do
					local c, d = ave.pts[k], ave.pts[k + 1]
					local t = WorldGen.segIntersect(a.x, a.z, b.x, b.z, c.x, c.z, d.x, d.z, 0)
					if t then
						hit = P(a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t)
						hitSeg = i
						break
					end
				end
				if hit then
					break
				end
			end
			if not hit then
				table.insert(GeometryErrors, ("diamond %s x %s: ramp guide misses the avenue"):format(main.name, ave.name))
				continue
			end
			local term = hit :: P2
			local name = (o.label or main.name) .. (if kind == "off" then " off-ramp" else " on-ramp")
			local pts: { P2 } = {}
			if kind == "off" then
				local g = goreOut(car, sCar)
				append(pts, g)
				local ge = g[#g]
				local _, _, gtx, gtz = WorldGen.polyAt(car.pts, sCar + TAPER)
				local _, _, htx, htz = WorldGen.polyAt(guide, 0)
				append(pts, curve(ge, gtx, gtz, guide[1], htx, htz))
				for i = 2, hitSeg do
					table.insert(pts, guide[i])
				end
				table.insert(pts, term)
				rampWay(name, pts, { level = 1, startCar = car, ease = true })
			else
				table.insert(pts, term)
				for i = hitSeg + 1, #guide do
					table.insert(pts, guide[i])
				end
				local g = goreIn(car, sCar)
				local _, _, gtx, gtz = WorldGen.polyAt(car.pts, sCar - TAPER)
				local gl = WorldGen.polyLength(guide)
				local _, _, htx, htz = WorldGen.polyAt(guide, gl)
				append(pts, curve(pts[#pts], htx, htz, g[1], gtx, gtz))
				append(pts, g)
				rampWay(name, pts, { level = 1, endCar = car, ease = true })
			end
		end
	end
end

-- Local frame of a T junction where a branch leaves corridor `main` at branchCenter[1] (on main's centerline).
type TFrame = {
	sJ: number,
	sigma: number, -- +1 when the branch is on the right of main's centerline direction
	N: Carriageway, -- near carriageway (branch side), travels +e
	F: Carriageway, -- far carriageway, travels -e
	o: number, -- main carriageway offset at the junction
	ex: number,
	ez: number,
	wx: number, -- toward the branch
	wz: number,
	J: P2,
}

local function tframe(main: Corridor, branchCenter: { P2 }): TFrame
	local J = branchCenter[1]
	local _, sJ = WorldGen.polyProject(main.center, J.x, J.z)
	local _, _, mtx, mtz = WorldGen.polyAt(main.center, sJ)
	local bx, bz = unit(branchCenter[2].x - J.x, branchCenter[2].z - J.z)
	local rx, rz = WorldGen.right(mtx, mtz)
	local sigma = if rx * bx + rz * bz > 0 then 1 else -1
	local ex, ez = mtx * sigma, mtz * sigma
	local wx, wz = WorldGen.right(ex, ez)
	return {
		sJ = sJ,
		sigma = sigma,
		N = if sigma > 0 then main.fwd else main.bwd,
		F = if sigma > 0 then main.bwd else main.fwd,
		o = main.offsetAt(sJ),
		ex = ex,
		ez = ez,
		wx = wx,
		wz = wz,
		J = J,
	}
end

-- Carriageway arc length at local coordinate a (along e) of a T frame.
local function frameS(main: Corridor, f: TFrame, c: Carriageway, a: number): number
	local x, z = WorldGen.polyAt(main.center, f.sJ + f.sigma * a)
	return carS(c, x, z)
end

-- Centerline offset to the far side of a T frame, walked from local a0 to a1.
local function farGuide(main: Corridor, f: TFrame, dist: number, a0: number, a1: number): { P2 }
	local s0, s1 = f.sJ + f.sigma * a0, f.sJ + f.sigma * a1
	local lo, hi = math.min(s0, s1), math.max(s0, s1)
	local g = WorldGen.polyOffset(WorldGen.polySlice(main.center, lo, hi), -f.sigma * dist)
	if s0 > s1 then
		g = reversed(g)
	end
	return g
end

local function tangentAt(pts: { P2 }, s: number): (number, number)
	local _, _, tx, tz = WorldGen.polyAt(pts, s)
	return tx, tz
end

-- Trumpet (H9 Sunwood Interchange): all six movements, one 270-degree loop and a sweeping flyover on the far side.
local function trumpet(name: string, main: Corridor, branchCenter: { P2 }, lanes: number, labels: { string }): Corridor
	local f = tframe(main, branchCenter)
	local J, o = f.J, f.o
	local ex, ez, wx, wz = f.ex, f.ez, f.wx, f.wz
	local N, F = f.N, f.F
	local function L(a: number, b: number): P2
		return P(J.x + ex * a + wx * b, J.z + ez * a + wz * b)
	end
	local R, Lb, Lm, Ln, Ls, gapM = 150, 400, 260, 400, 220, 16
	local branch = corridor(
		name,
		WorldGen.polySlice(branchCenter, o + Lb, WorldGen.polyLength(branchCenter)),
		lanes,
		labels
	)
	local Out, In = branch.fwd, branch.bwd
	local ob = branch.offsetAt(0)
	-- 1. N -> Out (direct, right exit before the junction)
	do
		local sN = frameS(main, f, N, -(ob + Ln))
		local pts = goreOut(N, sN)
		local gin = goreIn(Out, Lm)
		local tx, tz = tangentAt(N.pts, sN + TAPER)
		local qx, qz = tangentAt(Out.pts, Lm - TAPER)
		append(pts, curve(pts[#pts], tx, tz, gin[1], qx, qz))
		append(pts, gin)
		rampWay(name .. " ramp", pts, { level = 1, startCar = N, endCar = Out })
	end
	-- 2. In -> N (direct, right merge after the junction)
	do
		local inL = In.cum[#In.cum]
		local pts = goreOut(In, inL - Lm)
		local sN = frameS(main, f, N, ob + Ln)
		local gin = goreIn(N, sN)
		local tx, tz = tangentAt(In.pts, inL - Lm + TAPER)
		local qx, qz = tangentAt(N.pts, sN - TAPER)
		append(pts, curve(pts[#pts], tx, tz, gin[1], qx, qz))
		append(pts, gin)
		rampWay(name .. " ramp", pts, { level = 1, startCar = In, endCar = N })
	end
	-- 3. In -> F: over the main line, then a 270-degree loop on the far side merging into F
	do
		local start = In.pts[#In.pts]
		local b0 = -o - R - gapM
		local pts: { P2 } = { start }
		append(pts, WorldGen.densify({ start, L(ob, b0) }, 30))
		local n = 40
		for i = 1, n do
			local phi = math.pi + (1.5 * math.pi) * i / n
			table.insert(pts, L(ob + R + R * math.cos(phi), b0 + R * math.sin(phi)))
		end
		local sF = frameS(main, f, F, ob + R - 260)
		local gin = goreIn(F, sF)
		local qx, qz = tangentAt(F.pts, sF - TAPER)
		append(pts, curve(pts[#pts], -ex, -ez, gin[1], qx, qz))
		append(pts, gin)
		rampWay(name .. " loop", pts, { level = 2, startCont = In, endCar = F })
	end
	-- 4. F -> Out: sweeping semi-directional ramp around the loop, over the main line
	do
		local aD = ob + 2 * R + Ls
		local sF = frameS(main, f, F, aD)
		local pts = goreOut(F, sF)
		local bTop = -o - 2 * R - gapM - 80
		local ctrl: { P2 } = {
			pts[#pts],
			L(aD - TAPER - 60, -o - 60),
			L(ob + 2 * R + 60, bTop),
			L(-ob, bTop),
			Out.pts[1],
		}
		append(pts, WorldGen.fillet(ctrl, 170, nil, 20))
		rampWay(name .. " flyover", pts, { level = 2, startCar = F, endCont = Out })
	end
	return branch
end

-- Directional T ("stack"): direct ramps for the two right turns, two curving flyovers for the left turns, which
-- cross the main line and each other (levels L2 and L3). The far-side footprint is a narrow collector strip along
-- the far carriageway instead of a trumpet's loop (gta critique 6).
type StackParams = { Lb: number, Ln: number, Lm: number, A2: number, A3: number, turn: number }
local STACK_DEFAULT: StackParams = { Lb = 640, Ln = 380, Lm = 260, A2 = 600, A3 = 700, turn = 230 }

local function stackT(
	name: string,
	main: Corridor,
	branchCenter: { P2 },
	lanes: number,
	labels: { string },
	params: StackParams?
): Corridor
	local Pm: StackParams = params or STACK_DEFAULT
	local f = tframe(main, branchCenter)
	local o = f.o
	local N, F = f.N, f.F
	local branch = corridor(
		name,
		WorldGen.polySlice(branchCenter, o + Pm.Lb, WorldGen.polyLength(branchCenter)),
		lanes,
		labels
	)
	local Out, In = branch.fwd, branch.bwd
	local ob = branch.offsetAt(0)
	-- 1. N -> Out (direct right turn)
	do
		local sN = frameS(main, f, N, -(ob + Pm.Ln))
		local pts = goreOut(N, sN)
		local gin = goreIn(Out, Pm.Lm)
		local tx, tz = tangentAt(N.pts, sN + TAPER)
		local qx, qz = tangentAt(Out.pts, Pm.Lm - TAPER)
		append(pts, curve(pts[#pts], tx, tz, gin[1], qx, qz))
		append(pts, gin)
		rampWay(name .. " ramp", pts, { level = 1, startCar = N, endCar = Out })
	end
	-- 2. In -> N (direct right turn)
	do
		local inL = In.cum[#In.cum]
		local pts = goreOut(In, inL - Pm.Lm)
		local sN = frameS(main, f, N, ob + Pm.Ln)
		local gin = goreIn(N, sN)
		local tx, tz = tangentAt(In.pts, inL - Pm.Lm + TAPER)
		local qx, qz = tangentAt(N.pts, sN - TAPER)
		append(pts, curve(pts[#pts], tx, tz, gin[1], qx, qz))
		append(pts, gin)
		rampWay(name .. " ramp", pts, { level = 1, startCar = In, endCar = N })
	end
	-- 3. F -> Out (left turn, L2): diverge to the far side, collector along F, curve across the main line
	do
		local sF = frameS(main, f, F, Pm.A2)
		local pts = goreOut(F, sF)
		local guide = farGuide(main, f, o + 72, Pm.A2 - TAPER - 120, Pm.turn)
		local tx, tz = tangentAt(F.pts, sF + TAPER)
		local hx, hz = tangentAt(guide, 0)
		append(pts, curve(pts[#pts], tx, tz, guide[1], hx, hz))
		append(pts, guide)
		local gl = WorldGen.polyLength(guide)
		local gx, gz = tangentAt(guide, gl)
		local qx, qz = tangentAt(Out.pts, 0)
		append(pts, curve(pts[#pts], gx, gz, Out.pts[1], qx, qz, 0.5))
		rampWay(name .. " flyover", pts, { level = 2, startCar = F, endCont = Out })
	end
	-- 4. In -> F (left turn, L3): from the end of In, curve across the main line, collector, merge into F
	do
		local inL = In.cum[#In.cum]
		local start = In.pts[#In.pts]
		local tx, tz = tangentAt(In.pts, inL)
		local guide = farGuide(main, f, o + 72, -Pm.turn, -(Pm.A3 - TAPER - 120))
		local hx, hz = tangentAt(guide, 0)
		local pts: { P2 } = { start }
		append(pts, curve(start, tx, tz, guide[1], hx, hz, 0.5))
		append(pts, guide)
		local sF = frameS(main, f, F, -Pm.A3)
		local gin = goreIn(F, sF)
		local gl = WorldGen.polyLength(guide)
		local gx, gz = tangentAt(guide, gl)
		local qx, qz = tangentAt(F.pts, sF - TAPER)
		append(pts, curve(pts[#pts], gx, gz, gin[1], qx, qz))
		append(pts, gin)
		rampWay(name .. " high flyover", pts, { level = 3, startCont = In, endCar = F })
	end
	return branch
end

-------------------------------------------------------------------------------------------------------------------------
-- 3c. Freeways: H1 Ring (elevated, north leg in a trench, 4+4 on the east and south legs), H9 Sunwood Freeway
--     (trumpet), H2 Port Expressway / H6 Desert Freeway / H7 Airport Freeway (directional stacks), H3 Palmera
--     Freeway (spur to the pier), the Unfinished Ramp stub.
-------------------------------------------------------------------------------------------------------------------------

-- South leg skewed 3 degrees (pivot at the south-east corner); unequal corner radii.
local SKEW = math.tan(math.rad(3))
local function southLegZ(x: number): number
	return 1350 + (1650 - x) * SKEW
end
local RING_CTRL: { P2 } = {
	P(-430, southLegZ(-430)), -- seam on the south leg, between the Harbor and Iron Bay interchanges
	P(-3650, southLegZ(-3650)), -- SW corner
	P(-3650, -1800), -- NW corner
	P(1650, -1800), -- NE corner
	P(1650, 1350), -- SE corner
	P(-430, southLegZ(-430)),
}
local ringCenter = WorldGen.densify(WorldGen.fillet(RING_CTRL, 600, { [2] = 450, [3] = 600, [4] = 1100, [5] = 600 }, 40), 60)
local ringCum = WorldGen.polyCum(ringCenter)
local RING_L = ringCum[#ringCum]
local function ringS(x: number, z: number): number
	local _, s = WorldGen.polyProject(ringCenter, x, z)
	return s
end
-- 4+4 lanes from the middle of the NE corner, down the east leg and along the south leg to the middle of the SW corner
local sSWmid = ringS(-3650 + 140, southLegZ(-3650) - 140)
local sNEmid = ringS(1650 - 320, -1800 + 320)
local function ringFour(s: number): number
	-- 1 on the 4-lane legs, 0 on the 3-lane legs, smooth over 150 studs either side of the change
	local a = SMOOTH(sSWmid + 150, sSWmid - 150, s)
	local b = SMOOTH(sNEmid - 150, sNEmid + 150, s)
	return math.max(a, b)
end
local H1 = corridor("H1 Ring Freeway", ringCenter, 3, { "(clockwise)", "(counter-clockwise)" }, {
	lanesAt = function(s: number): number
		return if s <= sSWmid or s >= sNEmid then 4 else 3
	end,
	offsetAt = function(s: number): number
		return carriagewayWidth(3) / 2 + S.CARRIAGEWAY_GAP / 2 + (LANE / 2) * ringFour(s)
	end,
	breaks = { sSWmid, sNEmid },
})
-- North leg: deck -> trench (26 below grade) from east of the Sunwood Interchange to the NE corner, so downtown looks
-- north to the hills over a sunken freeway and the streets bridge it (gta critique 6).
local sTd0, sTd1 = ringS(-1950, -1800), ringS(-1050, -1800)
local sTr0 = ringS(420, -1800)
local sTr1 = sTr0 + 1000
local function eased(a: number, b: number, t: number): number
	t = math.clamp(t, 0, 1)
	return a + (b - a) * (0.5 * t + 0.5 * t * t * (3 - 2 * t))
end
local function ringY(sc: number): number
	if sc >= sTd0 and sc <= sTd1 then
		return eased(DECK_Y, TRENCH_Y, (sc - sTd0) / (sTd1 - sTd0))
	elseif sc > sTd1 and sc < sTr0 then
		return TRENCH_Y
	elseif sc >= sTr0 and sc <= sTr1 then
		return eased(TRENCH_Y, DECK_Y, (sc - sTr0) / (sTr1 - sTr0))
	end
	return DECK_Y
end
H1.setProfile(ringY)
WorldLayout.RingTrench = { from = sTd0, bottom = sTd1, riseFrom = sTr0, riseTo = sTr1, y = TRENCH_Y }

local function ringPoint(x: number, z: number): P2
	local _, _, px, pz = WorldGen.polyProject(ringCenter, x, z)
	return P(px, pz)
end

-- H9 Sunwood Freeway: north from the ring (Sunwood Interchange, trumpet) down into Sunwood Canyon to Hidden Cove.
local H9center: { P2 } = WorldGen.fillet({
	ringPoint(-2600, -1800),
	P(-2600, -2330),
	P(-2720, -2800),
	P(-2900, -3250),
	P(-2960, -3640),
}, 500, nil, 40)
local H9 = trumpet("H9 Sunwood Freeway", H1, H9center, 2, { "(northbound)", "(southbound)" })
groundCorridor(H9, function(_x: number, z: number): number
	-- deck past the trumpet's ramp merges, then a 6.5% descent into the canyon
	local d = math.max(0, -2520 - z)
	return math.max(GRADE, DECK_Y - d * 0.065)
end, 0.065)
corridorTail(H9, 170, "H9 Sunwood Freeway", "highway", { lanes = 2, median = 6 })

-- H2 Port Expressway: Iron Bay Interchange (stack) -> over Southgate on the deck -> Iron Bay Bridge -> port island.
local H2center: { P2 } =
	{ ringPoint(500, southLegZ(500)), P(500, 2000), P(500, 2600), P(500, 3000), P(500, 3420), P(500, 3800), P(500, 4020) }
local H2 = stackT("H2 Port Expressway", H1, H2center, 2, { "(southbound)", "(northbound)" })
H2.setProfile(function(sc: number): number
	local _, z = WorldGen.polyAt(H2.center, sc)
	local top = DECK_Y + 26 -- 66: ship clearance over the channel
	if z < 2620 then
		return DECK_Y
	elseif z < 3180 then
		return eased(DECK_Y, top, (z - 2620) / 560)
	elseif z < 3280 then
		return top
	end
	return eased(top, GRADE, (z - 3280) / 700)
end)
corridorTail(H2, 160, "H2 Port Expressway", "highway", { lanes = 2, median = 6 })

-- H6 Desert Freeway: Rust River Interchange (stack) on the east leg -> viaduct over the river, Riverside Drive and
-- Foundry Avenue -> Forge Avenue diamond -> grade by X ~ 3,700 -> divided highway past Cactus Junction through the
-- cuesta gap to the Coast Highway.
local H6center: { P2 } = WorldGen.fillet({
	ringPoint(1650, -450),
	P(2600, -450),
	P(3450, 40),
	P(4200, 125),
	P(5000, 115),
	P(5665, 110),
}, 600, nil, 40)
local H6 = stackT("H6 Desert Freeway", H1, H6center, 2, { "(eastbound)", "(westbound)" })
do
	local sCrown = 0
	local _ = sCrown
	H6.setProfile(function(sc: number): number
		local x = WorldGen.polyAt(H6.center, sc)
		if x < 2700 then
			return DECK_Y
		elseif x < 3080 then
			return eased(DECK_Y, 31, (x - 2700) / 380) -- over Crown Boulevard, down toward the Forge diamond
		elseif x < 3420 then
			return 31
		end
		return eased(31, GRADE, (x - 3420) / 400)
	end)
end
local H6tail = corridorTail(H6, 1750, "H6 Desert Freeway", "highway", { lanes = 2, median = 16 })

-- H7 Airport Freeway: Airport Interchange (stack) on the south leg -> south over west Southgate -> west into HCI. It comes
-- down to grade inside the airport and ends at the Terminal Drive loop (arrivals level); the Departures deck rises
-- inside the loop above the arrivals curb.
local H7center: { P2 } = WorldGen.fillet({
	ringPoint(-2100, southLegZ(-2100)),
	P(-2390, 2330),
	P(-2560, 2610),
	P(-3602, 2620),
}, 380, nil, 30)
local H7 = stackT(
	"H7 Airport Freeway",
	H1,
	H7center,
	2,
	{ "(southbound)", "(northbound)" },
	{ Lb = 620, Ln = 380, Lm = 260, A2 = 600, A3 = 780, turn = 230 }
)
H7.setProfile(function(sc: number): number
	return eased(DECK_Y, GRADE, (sc - 1020) / 420)
end)
local H7tail = corridorTail(
	H7,
	H7.cum[#H7.cum] - 1460,
	"H7 Airport Freeway",
	"boulevard",
	{ lanes = 2, median = 12, parking = false, sidewalk = 14 }
)

-- H3 Palmera Freeway: the beach spur. A Y fork on the outer (southbound) carriageway of the west leg, then a short
-- descending freeway ending at a signal on Palmera Drive facing the pier (the I-10 at Santa Monica, parodied).
local H3center: { P2 } = { P(-3900, -950), P(-4300, -950), P(-4478, -950) }
local H3 = corridor("H3 Palmera Freeway", H3center, 2, { "(westbound)", "(eastbound)" })
H3.setProfile(function(sc: number): number
	return eased(DECK_Y, GRADE, (sc - 0) / 420)
end)
do
	local f = tframe(H1, { ringPoint(-3650, -950), P(-3900, -950) })
	local N = f.N
	-- N -> Palmera Freeway westbound
	local sN = frameS(H1, f, N, -400)
	local pts = goreOut(N, sN)
	local tx, tz = tangentAt(N.pts, sN + TAPER)
	local w0 = H3.fwd.pts[1]
	local qx, qz = tangentAt(H3.fwd.pts, 0)
	append(pts, curve(pts[#pts], tx, tz, w0, qx, qz, 0.5))
	rampWay("H3 Palmera Freeway ramp", pts, { level = 1, startCar = N, endCont = H3.fwd })
	-- Palmera Freeway eastbound -> N
	local bl = H3.bwd.cum[#H3.bwd.cum]
	local b1 = H3.bwd.pts[#H3.bwd.pts]
	local bx, bz = tangentAt(H3.bwd.pts, bl)
	local sN2 = frameS(H1, f, N, 400)
	local gin = goreIn(N, sN2)
	local gx, gz = tangentAt(N.pts, sN2 - TAPER)
	local pts2: { P2 } = { b1 }
	append(pts2, curve(b1, bx, bz, gin[1], gx, gz, 0.5))
	append(pts2, gin)
	rampWay("H3 Palmera Freeway ramp", pts2, { level = 1, startCont = H3.bwd, endCar = N })
end
corridorTail(H3, 150, "Palmera Freeway", "boulevard", { lanes = 2, median = 12, parking = false, sidewalk = 14 })

-- The Unfinished Ramp: a dead-end flyover stub off the east leg (northbound), rising toward the Rust River and ending
-- in mid-air at its west lip. Stunt jump `sj_unfinished` launches off its end over the channel onto Riverside Drive.
local stubWay: Way
do
	local f = tframe(H1, { ringPoint(1650, 420), P(1900, 420) })
	local N = f.N
	local sN = frameS(H1, f, N, -200)
	local pts = goreOut(N, sN)
	local tx, tz = tangentAt(N.pts, sN + TAPER)
	-- channel west lip at this Z
	local _, sCh = WorldGen.polyProject(WorldTerrain.Channel.points, 2000, 330)
	local cx, cz = WorldGen.polyAt(WorldTerrain.Channel.points, sCh)
	local lipX = cx - (WorldTerrain.channelFloorHalf(cz) + WorldTerrain.Channel.wallRun) - 2
	local a = P(1830, cz)
	append(pts, curve(pts[#pts], tx, tz, a, 1, 0, 0.5))
	append(pts, WorldGen.densify({ a, P(lipX, cz) }, 40))
	stubWay = rampWay("Unfinished Ramp", pts, { level = 2, startCar = N, endY = L2_Y - 6, stub = true }, {
		keepDeadEnd = true,
		traffic = false,
		tags = { stub = true },
	})
end

-------------------------------------------------------------------------------------------------------------------------
-- 4. Surface roads: arterials, airport, hills, countryside, port, specials, the Rust River channel
-------------------------------------------------------------------------------------------------------------------------

local function smooth(ctrl: { { number } }, r: number?): { P2 }
	return WorldGen.fillet(poly(ctrl), r or 260, nil, 30)
end

-- Palmera Drive: beachfront boulevard (palms in a wide median); north end becomes Cliffside Road, south end runs into
-- the airport loop past the marina.
local palmeraDrive = addWay(
	"Palmera Drive",
	"boulevard",
	smooth({
		{ -4440, -2160 },
		{ -4470, -1500 },
		{ -4500, -500 },
		{ -4480, 500 },
		{ -4540, 1300 },
		{ -4570, 1760 },
		{ -4622, 2150 },
	}, 600),
	{ lanes = 2, median = 16, parking = true, sidewalk = 14 }
)
local _ = palmeraDrive

local crown = addWay(
	"Crown Boulevard",
	"boulevard",
	smooth({
		{ -4495, -330 },
		{ -3650, -350 },
		{ -2900, -330 },
		{ -2100, -270 },
		{ -1240, -250 },
		{ 1650, -250 },
		{ 2300, -250 },
		{ 3000, -330 },
	}, 700),
	{ lanes = 3, median = 12 }
)
local _c = crown

local mission = addWay(
	"Mission Avenue",
	"avenue",
	smooth(
		{ { -4482, 700 }, { -3650, 660 }, { -2600, 630 }, { -1240, 650 }, { 1650, 650 }, { 2400, 660 }, { 3600, 720 } },
		700
	),
	{ lanes = 2, median = 10, parking = true }
)

local sunwoodBlvd = addWay(
	"Sunwood Boulevard",
	"avenue",
	smooth({
		{ -4441, -2080 },
		{ -3600, -2140 },
		{ -2600, -2100 },
		{ -1500, -2170 },
		{ -500, -2120 },
		{ 500, -2160 },
		{ 1500, -2080 },
		{ 2050, -2040 },
		{ 2430, -1960 },
		{ 3150, -1820 },
	}, 600),
	{ lanes = 2, median = 8, parking = true }
)
local _s = sunwoodBlvd

local liberty = addWay(
	"Liberty Avenue",
	"boulevard",
	smooth({ { -150, -2142 }, { -150, -250 }, { -150, 1350 }, { -150, 2260 }, { -150, 2930 } }),
	{ lanes = 3, median = 12 }
)

local harbor = addWay(
	"Harbor Avenue",
	"avenue",
	smooth({
		{ -1100, -2170 },
		{ -1100, -1200 },
		{ -1100, -250 },
		{ -1100, 650 },
		{ -1100, 1350 },
		{ -1100, 2270 },
		{ -1100, 2990 },
		{ -1100, 3480 },
		{ -1100, 3560 },
	}),
	{ lanes = 2, median = 6, parking = false, bridges = {} }
)

addWay(
	"Gilded Mile",
	"avenue",
	smooth({ { -3380, -1600 }, { -2900, -1150 }, { -2300, -620 }, { -1700, -60 }, { -1240, 360 } }, 900),
	{ lanes = 2, median = 18, parking = true, sidewalk = 14 }
)

addWay(
	"Vista Avenue",
	"avenue",
	smooth(
		{ { -2300, -2100 }, { -2300, -1200 }, { -2330, -300 }, { -2360, 640 }, { -2380, 1350 }, { -2400, 2250 } },
		700
	),
	{ lanes = 2, median = 8, parking = true }
)

addWay(
	"Foundry Avenue",
	"avenue",
	smooth({ { 2430, -1960 }, { 2420, -1000 }, { 2430, -250 }, { 2460, 660 }, { 2470, 1600 }, { 2470, 2950 } }),
	{ lanes = 2, median = 0, parking = true }
)

-- Forge Avenue: the Foundry's east arterial (H6 diamond).
local forge = addWay(
	"Forge Avenue",
	"avenue",
	smooth({ { 3150, -1820 }, { 3320, -1000 }, { 3350, -420 }, { 3355, 300 }, { 3360, 712 } }, 600),
	{ lanes = 2, median = 8, parking = true }
)

-- Riverside Drive (east bank) and West Bank Road follow the bent channel.
local CH = WorldTerrain.Channel
local function channelBank(z0: number, z1: number, side: number, extra: number): { P2 }
	local _, s0 = WorldGen.polyProject(CH.points, 2000, z0)
	local _, s1 = WorldGen.polyProject(CH.points, 2000, z1)
	local slice = WorldGen.polySlice(CH.points, math.min(s0, s1), math.max(s0, s1))
	-- channel points run north -> south; their right is west. side +1 = east bank
	local out = WorldGen.polyOffsetVar(slice, function(i: number, _s: number): number
		local z = slice[i].z
		return -side * (WorldTerrain.channelFloorHalf(z) + CH.wallRun + extra)
	end)
	return WorldGen.densify(out, 120)
end
local riverside = addWay("Riverside Drive", "street", channelBank(-2010, 2290, 1, 40), { lanes = 1, parking = true })
local westBank = addWay("West Bank Road", "street", channelBank(2230, 2560, -1, 40), { lanes = 1, parking = true })

local airportBlvd = addWay(
	"Airport Boulevard",
	"boulevard",
	smooth({ { -2660, 636 }, { -2700, 1000 }, { -2730, 1450 }, { -2900, 1800 }, { -3300, 2000 }, { -3602, 2150 } }, 400),
	{ lanes = 3, median = 12 }
)
local _a = airportBlvd

addWay(
	"Southgate Avenue",
	"avenue",
	smooth({
		{ -2900, 1800 },
		{ -2400, 2250 },
		{ -1100, 2270 },
		{ -150, 2260 },
		{ 1000, 2290 },
		{ 2085, 2290 },
		{ 2450, 2300 },
		{ 3500, 2350 },
	}, 700),
	{ lanes = 2, median = 8, parking = true }
)

-- Hotwire International: one-way Terminal Drive loop (arrivals curb in front of the terminal), the Departures deck
-- stacked above the arrivals curb (two-level drop-off), hangar road, two parallel runways and taxiways.
local terminalLoop = addWay(
	"Terminal Drive",
	"avenue",
	smooth({ { -3602, 2150 }, { -3602, 2620 }, { -4620, 2620 }, { -4620, 2150 }, { -3602, 2150 } }, 70),
	{ lanes = 2, oneWay = true, median = 0, parking = false, sidewalk = 14 }
)
local _t = terminalLoop
-- Departures: leaves the loop's east side, climbs inside the loop, runs stacked 22 above the arrivals curb along the
-- terminal face (the two-level drop-off), and comes back down inside the loop onto its west side.
do
	local pts = smooth({
		{ -3602, 2290 },
		{ -3660, 2340 },
		{ -3665, 2500 },
		{ -3760, 2620 },
		{ -4460, 2620 },
		{ -4560, 2560 },
		{ -4565, 2360 },
		{ -4620, 2300 },
	}, 90)
	local Ld = WorldGen.polyLength(pts)
	local top = GRADE + S.FLYOVER
	addWay("HCI Departures", "avenue", pts, {
		lanes = 2,
		oneWay = true,
		median = 0,
		parking = false,
		sidewalk = 0,
		shoulder = 3,
		layer = 1,
		noCross = true,
		yMode = "profile",
		profile = function(s: number, _L: number): number
			if s < 300 then
				return eased(GRADE, top, (s - 30) / 250)
			elseif s > Ld - 300 then
				return eased(top, GRADE, (s - (Ld - 280)) / 250)
			end
			return top
		end,
		tags = { departures = true },
	})
end
addWay(
	"Hangar Road",
	"service",
	smooth({ { -3150, 2617 }, { -3100, 2720 }, { -2950, 2800 }, { -2600, 2900 } }, 200),
	{ lanes = 1, traffic = false, keepDeadEnd = true }
)
addWay("Runway 09R/27L", "runway", { P(-5350, 3330), P(-2780, 3330) }, { lanes = 2, keepDeadEnd = true })
addWay("Runway 09L/27R", "runway", { P(-5650, 3790), P(-2690, 3790) }, { lanes = 2, keepDeadEnd = true })
addWay(
	"Taxiway Alpha",
	"service",
	{ P(-3000, 2700), P(-3000, 3150), P(-2900, 3330) },
	{ lanes = 1, traffic = false, keepDeadEnd = true }
)
addWay(
	"Taxiway Bravo",
	"service",
	{ P(-2900, 3330), P(-2880, 3560), P(-2850, 3790) },
	{ lanes = 1, traffic = false, keepDeadEnd = true }
)

-- Coast Highway: the scenic loop. It hugs the north cliffs (60-120 from the edge), drops to Sandpiper Bay and
-- Driftwood Beach, tunnels through the north-east cape, runs east of the cuesta and back into Rust Flats.
local coastHwy = addWay(
	"Coast Highway",
	"highway",
	smooth({
		{ -2960, -3640 },
		{ -2450, -3980 },
		{ -1900, -4140 },
		{ -1500, -4200 },
		{ -900, -4230 },
		{ -400, -4240 },
		{ 300, -4300 },
		{ 900, -4380 },
		{ 1450, -4560 },
		{ 2150, -4560 },
		{ 2900, -4390 },
		{ 3700, -4420 },
		{ 4400, -4370 },
		{ 4800, -4300 },
		{ 5150, -4150 },
		{ 5420, -3750 },
		{ 5640, -3200 },
		{ 5880, -2300 },
		{ 5760, -1500 },
		{ 5640, -680 },
		{ 5690, 400 },
		{ 5600, 1600 },
		{ 5250, 2600 },
		{ 4650, 3330 },
		{ 3800, 3480 },
		{ 3280, 3050 },
		{ 2900, 2780 },
		{ 2450, 2760 },
	}, 550),
	{ lanes = 2, median = 16 }
)

addWay(
	"Cliffside Road",
	"rural",
	smooth(
		{ { -4440, -2160 }, { -4560, -2700 }, { -4380, -3250 }, { -3920, -3610 }, { -3350, -3760 }, { -2960, -3640 } },
		400
	),
	{ lanes = 1 }
)

-- Red Mesa Road: Crown Boulevard's rural continuation through Cactus Junction and the cuesta gap to the east coast.
addWay(
	"Red Mesa Road",
	"rural",
	smooth({
		{ 3000, -330 },
		{ 3500, -520 },
		{ 3900, -560 },
		{ 4330, -560 },
		{ 4780, -560 },
		{ 5200, -680 },
		{ 5640, -680 },
	}, 500),
	{ lanes = 1 }
)

-- Foothill Road: from the Foundry along the reservoir's south shore (dam) and west of it up to the north coast.
addWay(
	"Foothill Road",
	"rural",
	smooth({
		{ 3150, -1820 },
		{ 3420, -2120 },
		{ 3200, -2400 },
		{ 2700, -2420 },
		{ 2420, -2700 },
		{ 2430, -3400 },
		{ 2600, -4100 },
		{ 2850, -4385 },
	}, 450),
	{ lanes = 1 }
)

addWay(
	"Dustbowl Road",
	"rural",
	smooth({ { 4330, -560 }, { 4300, 300 }, { 4100, 1200 }, { 4200, 2100 }, { 4420, 2650 }, { 4650, 3330 } }, 600),
	{ lanes = 1 }
)
addWay("Mesa Cutoff", "rural", smooth({ { 3600, 720 }, { 3900, 900 }, { 4150, 1050 } }, 300), { lanes = 1 })
addWay(
	"Quarry Road",
	"dirt",
	smooth({ { 5700, -2550 }, { 5350, -2600 }, { 5050, -2640 } }, 300),
	{ keepDeadEnd = true, traffic = false }
)
addWay(
	"Windfarm Road",
	"dirt",
	smooth({ { 5560, -3300 }, { 5380, -3050 }, { 5250, -2900 } }, 200),
	{ keepDeadEnd = true, traffic = false }
)
addWay(
	"Northpoint Road",
	"rural",
	smooth({ { 1500, -4545 }, { 1540, -4630 } }, 100),
	{ keepDeadEnd = true, traffic = false }
)
-- Driftwood: the beach hamlet below the Coast Highway.
addWay(
	"Driftwood Lane",
	"street",
	smooth({ { 5870, -2420 }, { 5800, -2200 }, { 5790, -2000 } }, 200),
	{ lanes = 1, parking = true, sidewalk = 10 }
)
-- Oil field and trailer park in the Red Mesa transition band (X 3300..4000).
addWay(
	"Derrick Road",
	"dirt",
	smooth({ { 3420, -2120 }, { 3600, -1800 }, { 3700, -1400 }, { 3620, -1100 } }, 200),
	{ keepDeadEnd = true, traffic = false }
)
addWay(
	"Sundown Trailer Court",
	"street",
	smooth({ { 3560, -480 }, { 3600, -800 }, { 3760, -950 } }, 150),
	{ lanes = 1, parking = false, sidewalk = 0, keepDeadEnd = true }
)
-- Mesa Track: dirt climb onto the north-east butte (Mesa Launch stunt).
addWay(
	"Mesa Track",
	"dirt",
	smooth({ { 4780, -560 }, { 4820, -900 }, { 4700, -1300 }, { 4560, -1560 }, { 4500, -1680 } }, 200),
	{ keepDeadEnd = true, traffic = false, maxGrade = 0.15 }
)

-- Talon Summit Trail: a dirt road spiralling up Mount Talon at ~11% from Foothill Road to the summit lookout.
do
	local PK = WorldTerrain.PEAK
	local pts: { P2 } = {}
	local a = math.rad(128) -- bearing from the peak (0 = +X, 90 = +Z): start on the south-west foot
	local d = PK.radius * 0.93
	local function profileT(y: number): number
		-- radial distance where the (noise-free) cone reaches height y
		local u = math.clamp(y / PK.height, 0, 0.999)
		return PK.radius * (1 - u ^ (1 / 1.55))
	end
	local y = PK.height * (1 - d / PK.radius) ^ 1.55
	local step = 30
	for _ = 1, 600 do
		table.insert(pts, P(PK.x + math.cos(a) * d, PK.z + math.sin(a) * d))
		if y > PK.height * 0.86 then
			break
		end
		local ny = y + step * 0.105
		local nd = profileT(ny)
		local dd = d - nd
		if dd >= step then
			nd = d - step * 0.9
			dd = step * 0.9
		end
		a -= math.sqrt(step * step - dd * dd) / d
		d, y = nd, ny
	end
	addWay("Talon Summit Trail", "dirt", pts, { keepDeadEnd = true, traffic = false, maxGrade = 0.16 })
end

-- Sunwood Hills: ridge drive, switchbacks, observatory road, contour streets, mansion lanes, museum and club drives.
local skyline = addWay(
	"Skyline Drive",
	"rural",
	smooth({
		{ -4560, -2700 },
		{ -4100, -2950 },
		{ -3550, -3120 },
		{ -3150, -3200 },
		{ -2600, -3180 },
		{ -2100, -3260 },
		{ -1500, -3120 },
		{ -950, -3180 },
		{ -520, -3080 },
		{ 100, -3200 },
		{ 700, -3050 },
		{ 1150, -2700 },
		{ 1450, -2160 },
	}, 300),
	{ lanes = 1, sidewalk = 0, maxGrade = 0.12, bridges = {} }
)

local HILL_ROADS: { { any } } = {
	-- name, class, control points, fillet radius, dead end
	{
		"Sunwood Canyon Road",
		"rural",
		{ { -1500, -2170 }, { -1300, -2330 }, { -1720, -2470 }, { -1360, -2620 }, { -1780, -2770 }, { -1420, -2930 }, { -1500, -3120 } },
		110,
		false,
	},
	{
		"Starview Road",
		"rural",
		{ { -150, -2142 }, { 120, -2360 }, { -380, -2520 }, { 160, -2700 }, { -360, -2860 }, { 0, -2990 }, { -520, -3080 } },
		120,
		false,
	},
	{
		"Vista del Mar Drive",
		"rural",
		{ { -3600, -2140 }, { -3500, -2400 }, { -3560, -2650 }, { -3800, -2850 }, { -4100, -2950 } },
		160,
		false,
	},
	{
		"Laurel Canyon Drive",
		"rural",
		{ { -2100, -3260 }, { -2050, -2900 }, { -2250, -2650 }, { -1960, -2470 }, { -2180, -2300 }, { -2000, -2115 } },
		130,
		false,
	},
	{ "Coldwater Drive", "rural", { { 700, -3050 }, { 650, -2700 }, { 900, -2450 }, { 700, -2300 }, { 820, -2150 } }, 140, false },
	{ "Hillcrest Drive", "street", { { -2180, -2300 }, { -2380, -2360 }, { -2480, -2490 } }, 120, true },
	{ "Manzanita Drive", "street", { { -1300, -2330 }, { -1050, -2350 }, { -780, -2330 } }, 140, false },
	{ "Toyon Lane", "street", { { -1050, -2560 }, { -750, -2600 }, { -430, -2560 } }, 140, false },
	{ "Oak Glen Road", "street", { { 160, -2700 }, { 400, -2760 }, { 650, -2700 } }, 140, false },
	{ "Rimrock Drive", "street", { { 900, -2450 }, { 1080, -2520 }, { 1258, -2500 } }, 120, false },
	{ "Chaparral Lane", "street", { { -2250, -2650 }, { -2450, -2700 }, { -2560, -2850 } }, 120, true },
	{ "Ridgeview Lane", "street", { { -1420, -2930 }, { -1180, -2960 }, { -960, -3170 } }, 140, false },
	{ "Overlook Drive", "street", { { -360, -2860 }, { -650, -2850 }, { -800, -2750 } }, 120, false },
	{ "Sycamore Ridge", "street", { { 650, -2700 }, { 560, -2880 }, { 400, -2980 } }, 120, true },
	{ "Pinecrest Way", "street", { { 300, -2160 }, { 250, -2350 }, { 420, -2450 } }, 120, false },
	{ "Canyon Crest Drive", "street", { { -1780, -2770 }, { -1950, -2830 }, { -2050, -2900 } }, 100, false },
	{ "Glen Oaks Road", "street", { { -1720, -2470 }, { -1050, -2560 }, { -800, -2750 } }, 160, false },
	{ "Sunwood Terrace", "street", { { -500, -2120 }, { -700, -2380 }, { -900, -2420 } }, 120, true },
	{ "Mirador Court", "street", { { -130, -2660 }, { 250, -2620 }, { 420, -2450 } }, 120, false },
	{ "Sierra Vista Lane", "street", { { -3500, -2400 }, { -3330, -2470 }, { -3200, -2340 } }, 120, true },
	{ "Bel Mar Lane", "street", { { -950, -3180 }, { -1150, -3270 }, { -1350, -3240 } }, 140, true },
	{ "Ocean Crest Way", "street", { { -3550, -3120 }, { -3450, -3480 }, { -3700, -3700 } }, 160, true },
	{ "Hollow Oak Drive", "street", { { 100, -3200 }, { 330, -3275 }, { 520, -3225 } }, 140, true },
	{ "Summit Ridge Road", "street", { { -2600, -3180 }, { -2450, -3275 }, { -2280, -3262 } }, 140, true },
	{ "Museum Drive", "street", { { -3300, -3170 }, { -3290, -3060 }, { -3280, -2990 } }, 80, true },
}
for _, r in HILL_ROADS do
	local class: RoadClass = r[2]
	local opts: WayOpts = { lanes = 1, maxGrade = 0.15 }
	if class == "street" then
		opts.parking = false
		opts.sidewalk = 0
		opts.maxGrade = 0.16
	end
	opts.keepDeadEnd = r[5]
	addWay(r[1], class, smooth(r[3], r[4]), opts)
end

-- Iron Bay: terminal ring road + container road.
addWay(
	"Terminal Way",
	"avenue",
	smooth({
		{ -1100, 3560 },
		{ 700, 3560 },
		{ 2550, 3560 },
		{ 2800, 3880 },
		{ 2560, 4320 },
		{ 700, 4380 },
		{ -1050, 4400 },
		{ -1650, 4020 },
		{ -1550, 3640 },
		{ -1100, 3560 },
	}, 220),
	{ lanes = 2, median = 0, parking = false, sidewalk = 10 }
)
addWay("Container Road", "street", { P(-1600, 4000), P(500, 4020), P(2780, 3980) }, { parking = false, sidewalk = 8 })
addWay("Quay Road", "street", { P(-600, 3560), P(-600, 4390) }, { parking = false, sidewalk = 8 })
addWay("Dock Street", "street", { P(1700, 3560), P(1700, 4350) }, { parking = false, sidewalk = 8 })

-- Rust Flats rail yard service road (along the tracks; Hot Drop and stunt access).
local railYardRoad = addWay("Rail Yard Road", "service", { P(2330, 1255), P(3000, 1255), P(3100, 1190), P(3100, 900) }, {
	lanes = 1,
	traffic = false,
	sidewalk = 0,
})
local _r = railYardRoad

-- Palmera Pier: drivable wooden pier into the ocean, angled 10 degrees off the shore normal (no traffic).
local PIER_DIR = { x = -math.cos(math.rad(10)), z = math.sin(math.rad(10)) }
WorldLayout.PierDir = PIER_DIR
do
	local root = P(-4478, -950)
	local pts: { P2 } = { root }
	for _, d in { 300, 700, 1150, 1450 } do
		table.insert(pts, P(root.x + PIER_DIR.x * d, root.z + PIER_DIR.z * d))
	end
	addWay("Palmera Pier", "pier", pts, { lanes = 1, keepDeadEnd = true, yMode = "fixed", fixedY = GRADE + 1 })
end

-- Rust River channel floor (drivable, sunken) + four access ramps that alternate banks about every 1.1-1.5k studs.
local channelWay: Way
do
	local pts = CH.points
	local _, sN = WorldGen.polyProject(pts, 1990, -1700)
	local _, sS = WorldGen.polyProject(pts, 1990, 2800)
	local drive = WorldGen.polySlice(pts, sN, sS)
	channelWay = addWay("Rust River Channel", "channel", drive, {
		lanes = 2,
		layer = -1,
		noCross = true,
		keepDeadEnd = true,
		traffic = false,
		yMode = "profile",
		profile = function(s: number, _L: number): number
			return WorldTerrain.channelFloorY(sN + s)
		end,
	})
	local function onBank(bank: Way, x: number, z: number): P2
		local _, _, px, pz = WorldGen.polyProject(bank.pts, x, z)
		return P(px, pz)
	end
	-- side +1 = east bank. dirAlong +1: the ramp climbs toward increasing channel arc length (south).
	local function channelRamp(name: string, zFloor: number, side: number, dirAlong: number, bank: Way)
		local _, sF = WorldGen.polyProject(pts, 1990, zFloor)
		local fx, fz = WorldGen.polyAt(pts, sF)
		local function lateral(s: number, d: number): P2
			local x, z, tx, tz = WorldGen.polyAt(pts, s)
			local rx, rz = WorldGen.right(tx, tz) -- west
			return P(x - rx * side * d, z - rz * side * d)
		end
		local _, cz = WorldGen.polyAt(pts, sF)
		local half = WorldTerrain.channelFloorHalf(cz)
		local p1 = lateral(sF + dirAlong * 70, half - 14)
		local p2 = lateral(sF + dirAlong * 250, half + CH.wallRun + 4)
		local bx, bz = WorldGen.polyAt(pts, sF + dirAlong * 380)
		local p3 = onBank(bank, bx + side * 200, bz)
		local ramp = { P(fx, fz), p1, p2, p3 }
		addWay(name, "service", WorldGen.densify(ramp, 40), {
			lanes = 1,
			layer = -1,
			noCross = true,
			traffic = false,
			yMode = "ramp",
			y0 = WorldTerrain.channelFloorY(sF),
			y1 = GRADE,
		})
	end
	channelRamp("Channel Ramp North", -1560, 1, -1, riverside)
	channelRamp("Channel Ramp Crown", -120, 1, -1, riverside)
	channelRamp("Channel Ramp Rail Yard", 1620, 1, -1, riverside)
	channelRamp("Channel Ramp South", 2700, -1, -1, westBank)
end

-------------------------------------------------------------------------------------------------------------------------
-- 3d. Diamonds on the surface arterials, then ramp heights
-------------------------------------------------------------------------------------------------------------------------

-- Snap loose ends of ground roads onto the road they were drawn to join (fillets pull control points off the final
-- polyline): an endpoint within reach of another ground road, but not on it, is moved onto it. Cul-de-sacs
-- (keepDeadEnd) only snap their first point.
local function snapEnds(onlyGenerated: boolean)
	local idx = WorldGen.segIndex(128)
	local function isGround(w: Way): boolean
		return w.layer == 0 and not w.noCross and w.class ~= "freeway" and w.class ~= "ramp"
	end
	for wi, w in ways do
		if isGround(w) then
			for k = 1, #w.pts - 1 do
				WorldGen.segAdd(idx, w.pts[k].x, w.pts[k].z, w.pts[k + 1].x, w.pts[k + 1].z, wi, k, 0)
			end
		end
	end
	for wi, w in ways do
		if not isGround(w) or (onlyGenerated and not w.generated) then
			continue
		end
		local ends = if w.keepDeadEnd then { 1 } else { 1, #w.pts }
		for _, ei in ends do
			local p = w.pts[ei]
			local best: P2? = nil
			local reach = if w.generated then 45 else 120
			local bestD = reach
			WorldGen.segQuery(idx, p.x, p.z, reach, function(id: number)
				if idx.owner[id] == wi then
					return
				end
				local _, x, z, d = WorldGen.projectSeg(p.x, p.z, idx.ax[id], idx.az[id], idx.bx[id], idx.bz[id])
				if d < bestD then
					bestD = d
					best = P(x, z)
				end
			end)
			if best and bestD > 0.05 then
				w.pts[ei] = best :: P2
			end
		end
	end
end
snapEnds(false)

diamond(H1, liberty, -150, -1800, { label = "H1 Liberty" })
diamond(H1, harbor, -1100, -1800, { ramps = "a-", label = "H1 Harbor North" })
diamond(H1, harbor, -1100, southLegZ(-1100), { ramps = "a-", label = "H1 Harbor South" })
diamond(H1, mission, -3650, 660, { label = "H1 Mission West" })
diamond(H1, mission, 1650, 650, { ramps = "a+", ld = 560, label = "H1 Mission East" })
diamond(H6, forge, 3350, -20, { ld = 430, label = "H6 Forge" })

-- Ramp heights. Each ramp holds the deck height of the carriageway it leaves / joins until it is clear of that deck
-- (no ramp slab ever cuts into a deck: tech critique 4), then eases to its other end; flyovers rise to clear every
-- deck and lower flyover they cross by S.FLYOVER (L2 over decks, L3 over L2). Processed by level so higher flyovers
-- see the lower ones' final heights.
local RampYIndex = WorldGen.segIndex(96)
local rampYOwner: { Way } = {}

local function levelOf(w: Way): number
	if w.ramp then
		return (w.ramp :: RampInfo).level
	end
	if w.class == "freeway" or w.layer >= 1 then
		return 1
	end
	return 0
end

-- Height of an elevated way at the point of it nearest (x, z).
local function elevY(w: Way, x: number, z: number): number
	if w.ysTable then
		local pts, ys = w.pts, w.ysTable :: { number }
		local best, by = math.huge, ys[1]
		for k = 1, #pts - 1 do
			local t, _, _, d = WorldGen.projectSeg(x, z, pts[k].x, pts[k].z, pts[k + 1].x, pts[k + 1].z)
			if d < best then
				best, by = d, ys[k] + (ys[k + 1] - ys[k]) * t
			end
		end
		return by
	end
	if w.carriage then
		return (w.carriage :: Carriageway).yAt(x, z)
	end
	if w.yMode == "deck" then
		return DECK_Y
	elseif w.yMode == "fixed" then
		return w.fixedY or GRADE
	elseif w.profile then
		local _, s = WorldGen.polyProject(w.pts, x, z)
		return (w.profile :: (number, number) -> number)(s, WorldGen.polyLength(w.pts))
	end
	return gradeAt(x, z)
end

local function indexElevated(w: Way)
	table.insert(rampYOwner, w)
	local id = #rampYOwner
	local pad = wayWidth(w) / 2 + (if w.class == "freeway" then LANE else 0) + 2
	for k = 1, #w.pts - 1 do
		WorldGen.segAdd(RampYIndex, w.pts[k].x, w.pts[k].z, w.pts[k + 1].x, w.pts[k + 1].z, id, k, pad)
	end
end

local function carOf(x: any): Carriageway?
	if x == nil then
		return nil
	end
	return x :: Carriageway
end

local function profileRamp(w: Way)
	local info = w.ramp :: RampInfo
	local pts = WorldGen.densify(w.pts, 8)
	local cum = WorldGen.polyCum(pts)
	local n = #pts
	local L = cum[n]
	local p1, pn = pts[1], pts[n]
	local startCar, endCar = carOf(info.startCar), carOf(info.endCar)
	local startCont, endCont = carOf(info.startCont), carOf(info.endCont)
	local y0 = info.startY
		or (if startCar then startCar.yAt(p1.x, p1.z) elseif startCont then startCont.yAt(p1.x, p1.z) else nil)
		or gradeAt(p1.x, p1.z)
	local y1 = info.endY
		or (if endCar then endCar.yAt(pn.x, pn.z) elseif endCont then endCont.yAt(pn.x, pn.z) else nil)
		or gradeAt(pn.x, pn.z)
	-- hold zones: still over the carriageway's deck (incl. its auxiliary lane)
	local function lateralFrom(c: Carriageway, p: P2): (number, number)
		local d, s = WorldGen.polyProject(c.pts, p.x, p.z)
		return d, c.lanesAt(s)
	end
	local sH0, sH1 = 0, L
	if startCar then
		for k = 1, n do
			local d, lanes = lateralFrom(startCar, pts[k])
			if d >= holdClear(lanes) then
				sH0 = cum[k]
				break
			end
			sH0 = cum[k]
		end
	end
	if endCar then
		for k = n, 1, -1 do
			local d, lanes = lateralFrom(endCar, pts[k])
			if d >= holdClear(lanes) then
				sH1 = cum[k]
				break
			end
			sH1 = cum[k]
		end
	end
	if sH1 < sH0 then
		table.insert(GeometryErrors, ("%s: hold zones overlap (%.0f..%.0f)"):format(w.name, sH0, sH1))
		sH1 = sH0
	end
	-- crossing requirements
	local myLevel = info.level
	local myHalf = wayWidth(w) / 2
	local req = table.create(n, -math.huge)
	for k = 1, n do
		local p = pts[k]
		local s = cum[k]
		WorldGen.segQuery(RampYIndex, p.x, p.z, 0, function(id: number)
			local o = rampYOwner[RampYIndex.owner[id]]
			if o == w then
				return
			end
			local oc = o.carriage
			if oc ~= nil and ((oc == startCar and s <= sH0 + 40) or (oc == endCar and s >= sH1 - 40)) then
				return
			end
			if (oc ~= nil and oc == startCont and s < 140) or (oc ~= nil and oc == endCont and s > L - 140) then
				return
			end
			local _, _, _, d = WorldGen.projectSeg(
				p.x,
				p.z,
				RampYIndex.ax[id],
				RampYIndex.az[id],
				RampYIndex.bx[id],
				RampYIndex.bz[id]
			)
			local oHalf = wayWidth(o) / 2 + (if o.class == "freeway" then 6.5 else 0)
			if d >= oHalf + myHalf + 2 then
				return
			end
			local ol = levelOf(o)
			-- siblings that leave the same carriageway / join the same one run side by side near that end
			local orr = o.ramp
			if orr ~= nil then
				local oStart = orr.startCar or orr.startCont
				local oEnd = orr.endCar or orr.endCont
				local myStart = info.startCar or info.startCont
				local myEnd = info.endCar or info.endCont
				if (myStart ~= nil and oStart == myStart and s < 320) or (myEnd ~= nil and oEnd == myEnd and s > L - 320) then
					return
				end
				if oEnd ~= nil and oEnd == myStart and s < 200 then
					return
				end
				if oStart ~= nil and oStart == myEnd and s > L - 200 then
					return
				end
			end
			if ol > myLevel then
				return -- it flies over me (it is profiled later)
			end
			-- ramps that meet at a shared end (a diamond's on- and off-ramp at their terminal)
			for _, oe in { o.pts[1], o.pts[#o.pts] } do
				for _, me in { p1, pn } do
					if WorldGen.dist(oe.x, oe.z, me.x, me.z) < 3 and WorldGen.dist(p.x, p.z, me.x, me.z) < 160 then
						return
					end
				end
			end
			if myLevel == 1 and (orr ~= nil or o.class == "freeway") and not info.stub then
				table.insert(GeometryErrors, ("%s crosses %s on the deck level at (%d, %d)"):format(w.name, o.name, p.x, p.z))
				return
			end
			local need = elevY(o, p.x, p.z) + S.FLYOVER
			if need > req[k] then
				req[k] = need
				if _G.DEBUG_REQ and w.name:find(_G.DEBUG_REQ) then
					print("REQ", w.name, "s", math.floor(s), "from", o.name, o.class, need)
				end
			end
		end)
	end
	-- fit: max(base, cones of the requirements), smoothed, holds re-pinned
	local g = 0.088
	local base = table.create(n, 0)
	for k = 1, n do
		local s = cum[k]
		if s <= sH0 then
			base[k] = y0
		elseif s >= sH1 then
			base[k] = y1
		else
			local t = (s - sH0) / math.max(1e-6, sH1 - sH0)
			if info.ease then
				t = 0.5 * t + 0.5 * t * t * (3 - 2 * t)
			end
			base[k] = y0 + (y1 - y0) * t
		end
	end
	local lb = table.create(n, -math.huge)
	for j = 1, n do
		if req[j] > -math.huge then
			for k = 1, n do
				local v = req[j] - g * math.abs(cum[k] - cum[j])
				if v > lb[k] then
					lb[k] = v
				end
			end
		end
	end
	local ys = table.create(n, 0)
	for k = 1, n do
		ys[k] = math.max(base[k], lb[k])
	end
	for _ = 1, 4 do
		local nxt = table.clone(ys)
		for k = 2, n - 1 do
			nxt[k] = (ys[k - 1] + 2 * ys[k] + ys[k + 1]) / 4
		end
		for k = 1, n do
			local s = cum[k]
			nxt[k] = math.max(nxt[k], lb[k])
			if s <= sH0 then
				nxt[k] = y0
			elseif s >= sH1 then
				nxt[k] = y1
			end
		end
		ys = nxt
	end
	-- cap the grade by raising the low side (never breaks a clearance requirement)
	local gmax = 0.095
	for k = n, 2, -1 do -- ascents: raise the lower point behind
		local lim = ys[k] - gmax * (cum[k] - cum[k - 1])
		if ys[k - 1] < lim and cum[k - 1] > sH0 then
			ys[k - 1] = lim
		end
	end
	for k = 2, n do -- descents: raise the lower point ahead
		local lim = ys[k - 1] - gmax * (cum[k] - cum[k - 1])
		if ys[k] < lim and cum[k] < sH1 then
			ys[k] = lim
		end
	end
	for k = 1, n do
		local s = cum[k]
		if (s <= sH0 and lb[k] > y0 + 0.5) or (s >= sH1 and lb[k] > y1 + 0.5) then
			table.insert(
				GeometryErrors,
				("%s: crossing inside its hold zone at (%d, %d) needs %.0f"):format(w.name, pts[k].x, pts[k].z, lb[k])
			)
			break
		end
	end
	local worst, worstAt = 0, 0
	local j = 1
	for k = 2, n do
		while cum[k] - cum[j + 1] >= 8 do
			j += 1
		end
		local run = cum[k] - cum[j]
		if run >= 8 then
			local gk = math.abs(ys[k] - ys[j]) / run
			if gk > worst then
				worst, worstAt = gk, cum[k]
			end
		end
	end
	if worst > 0.105 then
		table.insert(
			GeometryErrors,
			("%s: grade %.3f at s %.0f (length %.0f, holds %.0f..%.0f)"):format(w.name, worst, worstAt, L, sH0, sH1)
		)
	end
	w.pts = pts
	w.ysTable = ys
	w.yMode = "table"
	local ysRef = ys
	w.profile = function(s: number, _L: number): number
		local _, _, _, _, i, t = WorldGen.polyAtCum(pts, cum, s)
		return ysRef[i] + (ysRef[math.min(i + 1, n)] - ysRef[i]) * t
	end
end

do
	for _, w in ways do
		if (w.class == "freeway" or (w.layer >= 1 and w.ramp == nil)) and not w.generated then
			indexElevated(w)
		end
	end
	local rampsByLevel: { Way } = {}
	for _, w in ways do
		if w.ramp then
			table.insert(rampsByLevel, w)
		end
	end
	table.sort(rampsByLevel, function(a: Way, b: Way): boolean
		local la, lb = (a.ramp :: RampInfo).level, (b.ramp :: RampInfo).level
		if la ~= lb then
			return la < lb
		end
		return a.id < b.id
	end)
	for _, w in rampsByLevel do
		profileRamp(w)
		indexElevated(w)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- 5. District street grids (generated) + mid-block alleys
-------------------------------------------------------------------------------------------------------------------------

type GridSpec = {
	district: string,
	origin: P2,
	angle: number, -- degrees, rotation of the local u (east) axis
	us: { number }, -- streets running along v, at these u offsets
	vs: { number }, -- streets running along u, at these v offsets
	alleys: { number }?, -- alleys running along v at these u offsets (mid-block chase shortcuts, no AI traffic)
	clip: { P2 },
	class: RoadClass?,
	lanes: number?,
	parking: boolean?,
	sidewalk: number?,
	oneWayU: { [number]: number }?, -- index in us -> +1 (along +v) / -1
	oneWayV: { [number]: number }?,
	warp: { number }?, -- { amplitude, wavelength }
	drop: number?, -- share of interior block sides removed (superblocks, T-junctions)
	namesU: { string }?,
	namesV: { string }?,
	seed: number,
}

local function range(a: number, b: number, step: number, jitter: number, seed: number): { number }
	local out = {}
	local i = 0
	local v = a
	while v <= b + 1e-6 do
		i += 1
		local j = (WorldGen.hash(i, seed, 7) - 0.5) * 2 * jitter
		table.insert(out, v + j)
		v += step
	end
	return out
end

local function midpoints(list: { number }, extra: { number }?): { number }
	local all = table.clone(list)
	for _, v in extra or {} do
		table.insert(all, v)
	end
	table.sort(all)
	local out = {}
	for i = 1, #all - 1 do
		if all[i + 1] - all[i] > 260 then
			table.insert(out, (all[i] + all[i + 1]) / 2)
		end
	end
	return out
end

local midtownUs = range(-1150, 1150, 300, 40, 202)
local foundryUs = range(-640, 600, 320, 30, 505)

local GRIDS: { GridSpec } = {
	{
		-- Pinnacle Heights: big blocks (450-500 x 450-650 between the arterials), alternating one-way pairs and a
		-- mid-block alley in every block (gta critique 7). Harbor (-1100), Liberty (-150), Crown (-250) and Mission
		-- (650) are the authored arterials.
		district = "downtown",
		origin = P(0, 0),
		angle = 0,
		us = { -650, 300, 750, 1200 },
		vs = { -1450, -900, 200, 1150 },
		alleys = midpoints({ -650, 300, 750, 1200 }, { -1100, -150, 1650 }),
		clip = poly({ { -1160, -2160 }, { 2380, -2160 }, { 2380, 1360 }, { -1160, 1360 } }),
		class = "street",
		lanes = 2,
		parking = true,
		sidewalk = 14,
		oneWayU = { [1] = 1, [2] = -1, [3] = 1, [4] = -1 },
		oneWayV = { [1] = 1, [2] = -1, [3] = 1, [4] = -1 },
		drop = 0,
		namesU = { "Spring Street", "Olive Street", "Hope Street", "Flower Street" },
		namesV = { "1st Street", "3rd Street", "7th Street", "9th Street" },
		seed = 101,
	},
	{
		district = "midtown",
		origin = P(-2400, -300),
		angle = -11,
		us = midtownUs,
		vs = range(-1500, 1650, 270, 35, 203),
		alleys = midpoints(midtownUs),
		clip = poly({ { -3570, -1700 }, { -1240, -1700 }, { -1240, 1280 }, { -3570, 1280 } }),
		parking = true,
		drop = 0.12,
		namesU = {
			"Rosewood Ave",
			"Larchmont St",
			"Fairfax St",
			"La Paz St",
			"Highland St",
			"Orange St",
			"Cahuenga St",
			"Wilcox St",
			"Gower St",
		},
		namesV = {
			"Fountain St",
			"Romaine St",
			"Willoughby St",
			"Melrose St",
			"Beverly St",
			"Rosalind St",
			"Oakwood St",
			"Clinton St",
			"Rangely St",
			"Waring St",
			"Lemon St",
			"Lindo St",
		},
		seed = 202,
	},
	{
		district = "beach",
		origin = P(-4100, 0),
		angle = 2,
		us = { 30 },
		vs = range(-2000, 1500, 280, 30, 303),
		clip = poly({ { -4470, -2100 }, { -3790, -2100 }, { -3790, 1650 }, { -4520, 1650 } }),
		parking = true,
		drop = 0.0,
		namesU = { "Breaker Street" },
		namesV = {
			"Coral St",
			"Shell St",
			"Marlin St",
			"Pelican St",
			"Sandbar St",
			"Tarpon St",
			"Kelp St",
			"Gull St",
			"Reef St",
			"Tide St",
			"Dune St",
			"Surf St",
			"Wave St",
			"Palm St",
		},
		seed = 303,
	},
	{
		district = "southgate",
		origin = P(-500, 2200),
		angle = 3,
		us = range(-1900, 2000, 340, 50, 404),
		vs = range(-640, 760, 250, 30, 405),
		clip = poly({ { -2540, 1440 }, { 1860, 1440 }, { 1860, 2960 }, { -2340, 2960 }, { -2540, 2200 } }),
		parking = true,
		warp = { 55, 1100 },
		drop = 0.1,
		namesU = {
			"Alameda St",
			"Avalon Blvd",
			"Compton St",
			"Denker Ave",
			"Ely St",
			"Figueroa St",
			"Grand St",
			"Hoover St",
			"Imperial St",
			"Jefferson St",
			"Kansas Ave",
			"Lemon Ave",
		},
		namesV = { "Grove Street", "Forest Ave", "Jamestown Rd", "Kingsley Dr", "Normandie St", "Orchard Ave" },
		seed = 404,
	},
	{
		district = "foundry",
		origin = P(2700, -700),
		angle = 6,
		us = foundryUs,
		vs = range(-1150, 1100, 300, 30, 506),
		alleys = midpoints(foundryUs),
		clip = poly({ { 2180, -1880 }, { 3300, -1880 }, { 3300, 430 }, { 2180, 430 } }),
		parking = true,
		drop = 0.12,
		namesU = { "Kiln Street", "Anvil Street", "Bellows St", "Crucible St", "Forge St" },
		namesV = { "Copper St", "Brass St", "Tin St", "Zinc St", "Iron St", "Nickel St", "Cobalt St", "Lead St" },
		seed = 505,
	},
	{
		district = "rust",
		origin = P(2900, 1700),
		angle = 0,
		us = range(-800, 700, 500, 40, 606),
		vs = range(-1100, 1100, 430, 40, 607),
		clip = poly({ { 2330, 440 }, { 3700, 440 }, { 3700, 1180 }, { 2330, 1180 } }),
		parking = false,
		drop = 0.05,
		namesU = { "Rail Street", "Boxcar Ave", "Coupler St", "Ballast St" },
		namesV = { "Smelter Rd", "Slag St", "Cinder St", "Rivet St", "Gantry St", "Pylon St" },
		seed = 606,
	},
	{
		district = "rust",
		origin = P(2900, 1700),
		angle = 0,
		us = range(-800, 700, 500, 40, 606),
		vs = range(-1100, 1100, 430, 40, 607),
		clip = poly({ { 2330, 1520 }, { 3700, 1520 }, { 3700, 3000 }, { 2330, 3000 } }),
		parking = false,
		drop = 0.05,
		namesU = { "Rail Street", "Boxcar Ave", "Coupler St", "Ballast St" },
		namesV = { "Smelter Rd", "Slag St", "Cinder St", "Rivet St", "Gantry St", "Pylon St" },
		seed = 607,
	},
	{
		district = "cactus",
		origin = P(4330, -560),
		angle = 0,
		us = { -330, -110, 110, 330 },
		vs = { -330, -110, 220 },
		clip = poly({ { 3930, -930 }, { 4730, -930 }, { 4730, -170 }, { 3930, -170 } }),
		parking = true,
		sidewalk = 10,
		drop = 0.0,
		namesU = { "Saguaro St", "Ocotillo St", "Yucca St", "Mesquite St" },
		namesV = { "Rattler Rd", "Main Street", "Coyote St" },
		seed = 707,
	},
}

local authoredCount = #ways

local function generateGrid(g: GridSpec)
	local a = math.rad(g.angle)
	local ux, uz = math.cos(a), math.sin(a)
	local vx, vz = -uz, ux
	local function W(u: number, v: number): P2
		return P(g.origin.x + ux * u + vx * v, g.origin.z + uz * u + vz * v)
	end
	local minU, maxU = g.us[1], g.us[#g.us]
	local minV, maxV = g.vs[1], g.vs[#g.vs]
	local padU, padV = 1200, 1200
	local function emit(fam: string, idx: number, pts: { P2 }, alley: boolean?)
		local pieces: { { P2 } } = {}
		local cur: { P2 } = {}
		for i = 1, #pts - 1 do
			local p, q = pts[i], pts[i + 1]
			local ins = WorldGen.clipSegToPoly(p.x, p.z, q.x, q.z, g.clip)
			if #ins == 0 then
				if #cur >= 2 then
					table.insert(pieces, cur)
				end
				cur = {}
			else
				for k, iv in ins do
					local t0, t1 = iv[1], iv[2]
					local a0 = P(p.x + (q.x - p.x) * t0, p.z + (q.z - p.z) * t0)
					local a1 = P(p.x + (q.x - p.x) * t1, p.z + (q.z - p.z) * t1)
					if t0 > 1e-9 or k > 1 then
						if #cur >= 2 then
							table.insert(pieces, cur)
						end
						cur = { a0 }
					elseif #cur == 0 then
						cur = { a0 }
					end
					table.insert(cur, a1)
					if t1 < 1 - 1e-9 then
						table.insert(pieces, cur)
						cur = {}
					end
				end
			end
		end
		if #cur >= 2 then
			table.insert(pieces, cur)
		end
		local names = if fam == "u" then g.namesU else g.namesV
		local name = if alley
			then "Alley"
			elseif names and names[idx] then names[idx]
			else (g.district .. " " .. fam .. idx)
		local oneDir = if alley
			then nil
			elseif fam == "u" then (g.oneWayU and g.oneWayU[idx])
			else (g.oneWayV and g.oneWayV[idx])
		for _, piece in pieces do
			if WorldGen.polyLength(piece) < 40 then
				continue
			end
			local pts2 = piece
			if oneDir and oneDir < 0 then
				pts2 = reversed(piece)
			end
			if alley then
				addWay(name, "alley", pts2, { generated = true, district = g.district })
			else
				addWay(name, g.class or "street", pts2, {
					lanes = if oneDir then (g.lanes or 2) else 1,
					oneWay = oneDir ~= nil,
					parking = g.parking,
					sidewalk = g.sidewalk,
					generated = true,
					district = g.district,
				})
			end
		end
	end
	local function uLine(i: number, u: number): { P2 }
		local pts: { P2 } = {}
		local v = minV - padV
		while v <= maxV + padV + 1e-6 do
			local uu = u
			if g.warp then
				uu += g.warp[1] * math.sin((v / g.warp[2]) * 2 * math.pi + i * 0.7)
			end
			table.insert(pts, W(uu, v))
			v += 40
		end
		return pts
	end
	-- streets along v at each u (split per block so some interior sides can be dropped)
	for i, u in g.us do
		local pts = uLine(i, u)
		if g.drop and g.drop > 0 and i > 1 and i < #g.us then
			local kept: { P2 } = {}
			local pieces: { { P2 } } = {}
			for k = 1, #g.vs - 1 do
				if WorldGen.hash(i, k, g.seed) < g.drop then
					local cut0, cut1 = g.vs[k] + 2, g.vs[k + 1] - 2
					local before: { P2 } = {}
					local after: { P2 } = {}
					for _, p in (if #kept > 0 then kept else pts) do
						local pv = (p.x - g.origin.x) * vx + (p.z - g.origin.z) * vz
						if pv <= cut0 then
							table.insert(before, p)
						elseif pv >= cut1 then
							table.insert(after, p)
						end
					end
					if #before >= 2 then
						table.insert(pieces, before)
					end
					kept = after
				end
			end
			if #pieces > 0 then
				table.insert(pieces, kept)
				for _, pc in pieces do
					if #pc >= 2 then
						emit("u", i, pc)
					end
				end
				continue
			end
		end
		emit("u", i, pts)
	end
	for i, u in g.alleys or {} do
		emit("u", i, uLine(i + 50, u), true)
	end
	for i, v in g.vs do
		local pts: { P2 } = {}
		local u = minU - padU
		while u <= maxU + padU + 1e-6 do
			local vv = v
			if g.warp then
				vv += g.warp[1] * 0.6 * math.sin((u / (g.warp[2] * 1.3)) * 2 * math.pi + i)
			end
			table.insert(pts, W(u, vv))
			u += 40
		end
		if g.drop and g.drop > 0 and i > 1 and i < #g.vs then
			local pieces: { { P2 } } = {}
			local cur: { P2 } = {}
			local cutRanges = {}
			for k = 1, #g.us - 1 do
				if WorldGen.hash(k, i, g.seed + 1) < g.drop then
					table.insert(cutRanges, { g.us[k] + 2, g.us[k + 1] - 2 })
				end
			end
			if #cutRanges > 0 then
				for _, p in pts do
					local pu = (p.x - g.origin.x) * ux + (p.z - g.origin.z) * uz
					local inCut = false
					for _, r in cutRanges do
						if pu > r[1] and pu < r[2] then
							inCut = true
						end
					end
					if inCut then
						if #cur >= 2 then
							table.insert(pieces, cur)
						end
						cur = {}
					else
						table.insert(cur, p)
					end
				end
				if #cur >= 2 then
					table.insert(pieces, cur)
				end
				for _, pc in pieces do
					emit("v", i, pc)
				end
				continue
			end
		end
		emit("v", i, pts)
	end
end

for _, g in GRIDS do
	generateGrid(g)
end
