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
	{ "", "" },
	{ "", "" },
}
-- Blip atlas (tools/minimap/icons.py): name -> { x, y, w, h } in atlas pixels.
Minimap.ATLAS = ""
Minimap.ATLAS_CELLS = {
	garage = { 0, 0, 64, 64 },
}
-- END GENERATED

export type Cell = { number }

-- Color shown beyond the map image (open ocean) and under tiles while they load.
Minimap.WATER_COLOR = Color3.fromRGB(10, 24, 44)
Minimap.LAND_COLOR = Color3.fromRGB(23, 26, 38)

Minimap.RADAR = {
	DESKTOP_SIZE = 212, -- diameter (design px), bottom-left like GTA V
	TOUCH_SIZE = 164, -- phones: top-left under the topbar, clear of the thumbstick zone
	MARGIN = 16, -- design px from the screen edges
	TOUCH_TOP = 6, -- design px below the topbar inset (touch)
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
	{ name = "MARKET ROW", x = 560, z = 240, tier = 1 },
	{ name = "PALM SUBURBS", x = -720, z = -80, tier = 1 },
	{ name = "SUNSET BEACH", x = 720, z = 80, tier = 1 },
	{ name = "THE DOCKS", x = -80, z = -720, tier = 1 },
	{ name = "SOUTH SHORE", x = 80, z = 720, tier = 1 },
	{ name = "STUNT PARK", x = 720, z = 640, tier = 2 },
	{ name = "CITY PARK", x = -720, z = 640, tier = 2 },
	{ name = "OCEAN PIER", x = 720, z = -910, tier = 2 },
	{ name = "CHOP YARD", x = -720, z = -800, tier = 2 },
} :: { District }

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
}

return Minimap
