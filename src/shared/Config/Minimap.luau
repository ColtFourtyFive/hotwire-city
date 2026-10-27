--!strict
-- Minimap (GTA-style radar), fullscreen map and GPS tuning.
--
-- The GENERATED block is written by `python3 -I tools/minimap/build.py` (see tools/minimap/README.md): the map image
-- tiles uploaded to Roblox, the world square they cover and the blip icon atlas. Re-run it whenever the city layout
-- changes. Everything else here is hand-tuned. Design px are on the 1280x720 Kit.screen canvas.

local Minimap = {}

-- BEGIN GENERATED (tools/minimap/build.py)
-- World square covered by the map image (studs) and its tiles (row 1 = north = smallest Z, column 1 = west).
Minimap.WORLD_MIN = Vector2.new(-1024, -1024)
Minimap.WORLD_SIZE = 2048
Minimap.TILE_COUNT = 2
Minimap.TILE_PIXELS = 1024
Minimap.TILES = {
	{ "rbxassetid://117519932574490", "rbxassetid://125804761967084" },
	{ "rbxassetid://84265254994123", "rbxassetid://71493891656879" },
}
-- Blip atlas (tools/minimap/icons.py): name -> { x, y, w, h } in atlas pixels.
Minimap.ATLAS = "rbxassetid://120282250823159"
Minimap.ATLAS_CELLS = {
	garage = { 0, 0, 64, 64 },
	car = { 64, 0, 64, 64 },
	wrench = { 128, 0, 64, 64 },
	spray = { 192, 0, 64, 64 },
	saw = { 256, 0, 64, 64 },
	flame = { 320, 0, 64, 64 },
	pin = { 384, 0, 64, 64 },
	badge = { 448, 0, 64, 64 },
	dot = { 0, 64, 64, 64 },
	heli = { 64, 64, 64, 64 },
	star = { 128, 64, 64, 64 },
	flag = { 192, 64, 64, 64 },
	tree = { 256, 64, 64, 64 },
	wheel = { 320, 64, 64, 64 },
	cash = { 384, 64, 64, 64 },
	alert = { 448, 64, 64, 64 },
	target = { 0, 128, 64, 64 },
	home = { 64, 128, 64, 64 },
	square = { 128, 128, 64, 64 },
	person = { 192, 128, 64, 64 },
	trophy = { 256, 128, 64, 64 },
	bolt = { 320, 128, 64, 64 },
	chevron = { 384, 128, 64, 64 },
	diamond = { 448, 128, 64, 64 },
	_vignette = { 0, 256, 256, 256 },
	_glow = { 256, 256, 128, 128 },
	_ring = { 384, 256, 128, 128 },
	_arrow = { 256, 384, 128, 128 },
	_disc = { 384, 384, 128, 128 },
}
-- END GENERATED

export type Cell = { number }

-- Color shown beyond the map image (open ocean) and under tiles while they load.
Minimap.WATER_COLOR = Color3.fromRGB(10, 24, 44)
Minimap.LAND_COLOR = Color3.fromRGB(23, 26, 38)

Minimap.RADAR = {
	DESKTOP_SIZE = 200, -- diameter (design px), bottom-left like GTA V
	TOUCH_SIZE = 164, -- phones: top-left under the topbar, clear of the thumbstick zone
	-- 16:9 phones (design canvas narrower than TOUCH_COMPACT_W and shorter than TOUCH_COMPACT_H): a smaller radar so
	-- the HUD menu strip right of it keeps two rows above the thumbstick zone. Tablets keep TOUCH_SIZE.
	TOUCH_SIZE_COMPACT = 132,
	TOUCH_COMPACT_W = 1300,
	TOUCH_COMPACT_H = 760,
	TOUCH_GAP = 12, -- touch: design px between the radar and the HUD buttons right of it
	MARGIN = 16, -- design px from the screen edges
	PILL_ROOM = 12, -- desktop: extra bottom space so the GPS distance pill (hanging off the rim) stays on screen
	-- desktop: design px kept free above the radar top for what pokes out of it (the N marker reaches ~8 px above
	-- the rim, the wanted glow ~22 px), so the HUD menu column never overlaps them
	TOP_CLEARANCE = 28,
	TOUCH_TOP = 6, -- design px below the topbar inset (touch)
	-- Phones sit at the 0.55 UIScale floor: radar text and blips grow by Theme.TouchMinScale / scale (capped here)
	-- so they read like the rest of the HUD; the radar circle itself (and the HUD space it reserves) does not.
	TOUCH_BOOST_MAX = 1.4,
	AREA_TEXT = 15, -- area name (design px)
	AREA_TEXT_TOUCH = 18,
	DIST_TEXT = 16, -- GPS distance pill
	DIST_TEXT_TOUCH = 18,
	MAP_BUTTON_ANGLE = 45, -- the "M" / map button on the rim (degrees clockwise from up)
	NORTH_FADE_DEG = 24, -- the N marker fades out while it passes under the map button (within this many degrees)
	BORDER = 4, -- bezel thickness (design px)
	UPDATE_HZ = 30,
	-- zoom = studs from the radar center to its edge
	ZOOM_FOOT = 165,
	ZOOM_DRIVE_MIN = 220,
	ZOOM_DRIVE_MAX = 400,
	ZOOM_SPEED_FULL = 150, -- studs/s at which the driving zoom is fully out
	ZOOM_RESPONSE = 2.5, -- 1/s exponential smoothing toward the target zoom
	-- "camera": the map turns with the camera (GTA V); "heading": with the character / car facing; "north": fixed
	ROTATE = "camera",
	BLIP_SIZE = 22, -- design px (icons)
	BLIP_SIZE_SMALL = 12, -- police / players dots
	EDGE_INSET = 10, -- sticky blips sit this far inside the rim
	PLAYER_ARROW = 30,
	WANTED_FLASH_HZ = 2.5,
}

Minimap.GPS = {
	REROUTE_DISTANCE = 40, -- studs off the drawn route before it is recomputed
	REROUTE_MIN_INTERVAL = 0.75, -- seconds between recomputes (throttle)
	FAIL_RETRY_MAX = 8, -- seconds: an unreachable target is retried after doubling waits, up to this
	TARGET_MOVED = 50, -- a moving target (stolen car, dropped loot) re-routes after moving this far
	SELECT_INTERVAL = 0.25, -- seconds between picks of the active GPS target
	ARRIVE_RADIUS = 30, -- the custom map waypoint clears itself within this many studs
	MIN_ROUTE = 24, -- closer than this to the target: no route line
	WIDTH = 6, -- route line (design px, radar)
	OUTLINE = 2.5, -- dark outline each side (design px)
	MAP_WIDTH = 7, -- route line on the fullscreen map
	-- Which waypoint the GPS follows when several exist (first match wins); ids not listed come last, in id order.
	PRIORITY = { "map", "tutorial", "theft", "home", "stolen_car", "chop", "spray", "hotdrop", "cashrain" },
	-- Waypoints that get a blip but never a GPS route (informational).
	NO_ROUTE_PREFIX = { "dealer_rare" },
}

-- The player-placed waypoint (fullscreen map tap / click). Shows the 3D beam via WaypointController.
Minimap.CUSTOM_WAYPOINT = {
	ID = "map",
	COLOR = Color3.fromRGB(186, 94, 255),
	LABEL = "WAYPOINT",
}

-- Waypoint id -> atlas icon (exact id first, then prefix); anything else uses DEFAULT_WAYPOINT_ICON.
Minimap.WAYPOINT_ICONS = {
	map = "pin",
	tutorial = "target",
	theft = "home",
	home = "home",
	stolen_car = "alert",
	chop = "saw",
	spray = "spray",
	hotdrop = "flame",
	cashrain = "cash",
	dealer_rare = "car",
} :: { [string]: string }
Minimap.DEFAULT_WAYPOINT_ICON = "diamond"

export type PoiBlip = {
	id: string,
	icon: string,
	color: Color3,
	label: string,
	at: string, -- "poi:<Config/Map.Blocks name>" | "spray" (every Spray Shop) | "chop" | "gear" | "dealer"
	radarRange: number?, -- only on the radar within this many studs (nil = whenever it is inside the radar)
	legend: boolean?,
}

-- Fixed points of interest (positions resolved from MapLayout at runtime, so a new layout moves them for free).
Minimap.POIS = {
	{ id = "dealership", icon = "car", color = Color3.fromRGB(0, 214, 255), label = "Dealership", at = "dealer" },
	{ id = "gearshop", icon = "wrench", color = Color3.fromRGB(255, 205, 50), label = "Gear Shop", at = "gear" },
	{ id = "spray", icon = "spray", color = Color3.fromRGB(255, 120, 200), label = "Spray Shop", at = "spray" },
	{ id = "chop", icon = "saw", color = Color3.fromRGB(255, 140, 40), label = "Chop Shop", at = "chop" },
	{ id = "police", icon = "badge", color = Color3.fromRGB(70, 140, 255), label = "Police HQ", at = "poi:PoliceHQ" },
	{
		id = "plaza",
		icon = "star",
		color = Color3.fromRGB(255, 255, 255),
		label = "Spawn Plaza",
		at = "poi:SpawnPlaza",
		radarRange = 500,
	},
	{
		id = "stunt",
		icon = "flag",
		color = Color3.fromRGB(255, 52, 140),
		label = "Stunt Park",
		at = "poi:StuntPark",
		radarRange = 600,
	},
	{
		id = "park",
		icon = "tree",
		color = Color3.fromRGB(90, 220, 120),
		label = "City Park",
		at = "poi:Park",
		radarRange = 600,
	},
	{
		id = "pier",
		icon = "wheel",
		color = Color3.fromRGB(120, 230, 255),
		label = "Ocean Pier",
		at = "poi:Pier",
		radarRange = 600,
	},
} :: { PoiBlip }

-- Dynamic blips.
Minimap.BLIPS = {
	ownGarage = { icon = "garage", color = Color3.fromRGB(70, 235, 110), label = "Your Garage" },
	otherGarage = { icon = "garage", color = Color3.fromRGB(150, 156, 190), label = "Garage" },
	police = { icon = "dot", red = Color3.fromRGB(255, 60, 60), blue = Color3.fromRGB(60, 120, 255), label = "Police" },
	heli = { icon = "heli", color = Color3.fromRGB(255, 80, 80), label = "Police Chopper" },
	player = { icon = "dot", color = Color3.fromRGB(0, 214, 255), label = "Player" },
	hotDrop = { icon = "flame", color = Color3.fromRGB(255, 190, 40), label = "Hot Drop" },
	waypoint = { icon = "pin", color = Color3.fromRGB(186, 94, 255), label = "Waypoint" },
}

-- Wanted: the police search area (GTA V's flashing circle) around where the cops last saw you.
Minimap.WANTED = {
	RADIUS_BASE = 70, -- studs at 1 star
	RADIUS_PER_STAR = 25,
	FLASH_HZ = 2.5,
	RED = Color3.fromRGB(255, 50, 60),
	BLUE = Color3.fromRGB(50, 110, 255),
}

export type District = { name: string, x: number, z: number, tier: number }

-- District names drawn as UI labels on the fullscreen map (nothing is baked into the image). tier 1 = always,
-- tier 2 = once zoomed in a little.
Minimap.DISTRICTS = {
	{ name = "DOWNTOWN", x = 0, z = -240, tier = 1 },
	{ name = "MIDTOWN", x = -400, z = -400, tier = 1 },
	{ name = "MARKET ROW", x = 240, z = -560, tier = 1 },
	{ name = "PALM SUBURBS", x = -720, z = -80, tier = 1 },
	{ name = "SUNSET BEACH", x = 720, z = 80, tier = 1 },
	-- on the ring road, clear of the garage rows at z = -+681 (labels also step aside from blips at runtime)
	{ name = "THE DOCKS", x = 0, z = -820, tier = 1 },
	{ name = "SOUTH SHORE", x = 0, z = 820, tier = 1 },
	{ name = "STUNT PARK", x = 720, z = 640, tier = 2 },
	{ name = "CITY PARK", x = -720, z = 640, tier = 2 },
	{ name = "OCEAN PIER", x = 720, z = -910, tier = 2 },
	{ name = "CHOP YARD", x = -720, z = -800, tier = 2 },
} :: { District }

export type Area = { name: string, x0: number, z0: number, x1: number, z1: number }

-- Area name shown next to the radar: the first box (world studs) containing the player wins, so landmarks come
-- before the district rings they sit in. Mirrors MapBuilder.zoneOf's rings (block size 160, ring road at +-800).
Minimap.AREAS = {
	{ name = "STUNT PARK", x0 = 640, z0 = 640, x1 = 800, z1 = 800 },
	{ name = "CITY PARK", x0 = -800, z0 = 640, x1 = -640, z1 = 800 },
	{ name = "OCEAN PIER", x0 = 640, z0 = -1000, x1 = 800, z1 = -640 },
	{ name = "CHOP YARD", x0 = -800, z0 = -800, x1 = -640, z1 = -640 },
	{ name = "SPAWN PLAZA", x0 = -160, z0 = 0, x1 = 0, z1 = 160 },
	{ name = "DEALERSHIP", x0 = 0, z0 = 0, x1 = 160, z1 = 160 },
	{ name = "POLICE HQ", x0 = 0, z0 = -160, x1 = 160, z1 = 0 },
	{ name = "DOWNTOWN", x0 = -320, z0 = -320, x1 = 320, z1 = 320 },
	{ name = "MIDTOWN", x0 = -480, z0 = -480, x1 = 480, z1 = 480 },
	{ name = "THE DOCKS", x0 = -820, z0 = -820, x1 = 820, z1 = -640 },
	{ name = "PALM SUBURBS", x0 = -820, z0 = -820, x1 = -480, z1 = 820 },
	{ name = "MARKET ROW", x0 = -640, z0 = -640, x1 = 640, z1 = 640 },
	{ name = "SUNSET BEACH", x0 = 640, z0 = -960, x1 = 960, z1 = 960 },
	{ name = "SOUTH SHORE", x0 = -960, z0 = 640, x1 = 960, z1 = 960 },
	{ name = "NORTH BEACH", x0 = -960, z0 = -960, x1 = 960, z1 = -640 },
	{ name = "WEST BEACH", x0 = -960, z0 = -960, x1 = -640, z1 = 960 },
} :: { Area }
Minimap.AREA_DEFAULT = "OPEN WATER"

-- Fullscreen map.
Minimap.MAP = {
	KEY = Enum.KeyCode.M,
	MIN_ZOOM = 1, -- x fit-to-screen
	MAX_ZOOM = 6,
	WHEEL_STEP = 1.18,
	TAP_SLOP = 10, -- real px a touch may move and still count as a tap
	TAP_TIME = 0.4,
	CLEAR_RADIUS = 26, -- real px: tapping this close to your custom waypoint removes it
	BLIP_SIZE = 30,
	LABEL_SIZE = 20,
	OWNER_LABEL_SIZE = 15, -- garage owner names (design px; never under OWNER_LABEL_MIN real px)
	OWNER_LABEL_MIN = 14,
	CHROME_TOP = 84, -- design px of title / hint / GPS chip; the fit view starts below it
	LEGEND_ROW = 26, -- design px per legend row
	LEGEND_COLUMN = 196, -- design px per legend column (touch: two columns, scrolls when it still can't fit)
	-- gamepad: D-pad up opens / closes the map; left stick pans, LT / RT (or the right stick) zoom, A sets the waypoint
	-- under the center reticle (again on it: clears), X clears, Y re-centers, B closes
	PAD_KEY = Enum.KeyCode.DPadUp,
	PAD_PAN_SPEED = 720, -- real px per second at full stick
	PAD_ZOOM_RATE = 2.4, -- zoom factor per second at full trigger
	PAD_DEADZONE = 0.18,
}

return Minimap
