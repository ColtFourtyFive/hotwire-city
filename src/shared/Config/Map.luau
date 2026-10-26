--!strict
-- Island city layout constants. All positions in studs. See Shared/Util/MapLayout for derived geometry.
--
-- The city is a square road grid. Road centerlines sit at i * GRID_SPACING for i in LINE_MIN..LINE_MAX
-- along both axes. A "block" (bx, bz) is the square between lines bx..bx+1 and bz..bz+1, so its
-- center is ((bx + 0.5) * GRID_SPACING, (bz + 0.5) * GRID_SPACING). Blocks are raised by CURB_HEIGHT.

local Map = {}

Map.GRID_SPACING = 160
Map.ROAD_WIDTH = 40
Map.LINE_MIN = -5
Map.LINE_MAX = 5
Map.BLOCK_MIN = -5
Map.BLOCK_MAX = 4
Map.HALF_EXTENT = 800 -- outermost road centerline (ring road)
Map.ROAD_Y = 0 -- top surface of asphalt
Map.CURB_HEIGHT = 0.6 -- blocks / sidewalks / garage floors are this much above ROAD_Y
Map.SIDEWALK_WIDTH = 8
Map.LANE_OFFSET = 8 -- traffic lane center offset to the right of the road centerline
Map.PARK_OFFSET = 15.5 -- parked car center offset to the right of the road centerline
Map.SAND_EXTENT = 900 -- beach from ring road edge to here
Map.WATER_EXTENT = 1800
Map.BOUNDARY = 960 -- invisible walls (players/cars can't leave the island)
Map.WATER_LEVEL = -2

export type BlockRef = { x: number, z: number }
export type PlotDef = { block: BlockRef, face: Vector3 } -- face = direction from block center to its entrance road

-- 8 player garages on the outer ring of blocks; each faces the inner road.
Map.Plots = {
	{ block = { x = -5, z = -2 }, face = Vector3.new(1, 0, 0) },
	{ block = { x = -2, z = -5 }, face = Vector3.new(0, 0, 1) },
	{ block = { x = 1, z = -5 }, face = Vector3.new(0, 0, 1) },
	{ block = { x = 4, z = -2 }, face = Vector3.new(-1, 0, 0) },
	{ block = { x = 4, z = 1 }, face = Vector3.new(-1, 0, 0) },
	{ block = { x = 1, z = 4 }, face = Vector3.new(0, 0, -1) },
	{ block = { x = -2, z = 4 }, face = Vector3.new(0, 0, -1) },
	{ block = { x = -5, z = 1 }, face = Vector3.new(1, 0, 0) },
} :: { PlotDef }

-- Special blocks (points of interest). Anything not listed (and not a plot) is generic city.
Map.Blocks = {
	SpawnPlaza = { x = -1, z = 0 },
	Dealership = { x = 0, z = 0 },
	PoliceHQ = { x = 0, z = -1 },
	GearShop = { x = -1, z = -1 },
	SprayShopA = { x = -3, z = 2 },
	SprayShopB = { x = 2, z = -3 },
	ChopShop = { x = -5, z = -5 },
	StuntPark = { x = 4, z = 4 },
	Park = { x = -5, z = 4 },
	Pier = { x = 4, z = -5 },
} :: { [string]: BlockRef }

-- Downtown = blocks with |x+0.5| and |z+0.5| <= this get skyscrapers.
Map.DOWNTOWN_RADIUS = 2

-- Garage interior layout in plot-local space (see MapLayout.plotOrigin): local -Z points out the front door.
Map.Garage = {
	HALF_WIDTH = 48,
	FRONT_Z = -44,
	BACK_Z = 48,
	WALL_HEIGHT = 22,
	WALL_THICKNESS = 2,
	DOOR_WIDTH = 34,
	DOOR_HEIGHT = 16,
	SLOT_X = 33, -- slot columns at x = -SLOT_X (left) and +SLOT_X (right)
	SLOT_ZS = { -22, -10, 2, 14, 26, 38 },
	SLOT_PAD_SIZE = Vector3.new(16, 0.2, 10),
	DROPOFF_CENTER = Vector3.new(0, 0, -34),
	DROPOFF_SIZE = Vector3.new(30, 12, 16),
	COLLECT_CENTER = Vector3.new(0, 0, 40),
	COLLECT_SIZE = Vector3.new(12, 0.4, 12),
	LOCK_BUTTON = Vector3.new(-24, 0, -40),
	DRIVE_OUT_SPAWN = Vector3.new(0, 0, 8), -- owner's cars spawn here facing out the door
	OWNER_SPAWN = Vector3.new(0, 0, 24),
	SIGN = Vector3.new(0, 26, -46),
}

-- Hot Drop locations (world XZ; y is set to ROAD_Y). Mostly intersections so cars can reach them.
Map.HotDropPoints = {
	Vector3.new(-480, 0, -160),
	Vector3.new(320, 0, 480),
	Vector3.new(-160, 0, -480),
	Vector3.new(480, 0, 160),
	Vector3.new(0, 0, -640),
	Vector3.new(-640, 0, 0),
	Vector3.new(640, 0, -480),
	Vector3.new(-320, 0, 640),
	Vector3.new(160, 0, 320),
	Vector3.new(-320, 0, -320),
} :: { Vector3 }

return Map
