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
