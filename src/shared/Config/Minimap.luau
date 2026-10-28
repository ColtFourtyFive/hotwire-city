--!strict
-- Minimap (GTA-style radar), fullscreen map and GPS tuning.
--
-- The GENERATED block is written by `python3 -I tools/minimap/build.py` (see tools/minimap/README.md): the map image
-- tiles uploaded to Roblox, the world square they cover and the blip icon atlas. Re-run it whenever the city layout
-- changes. Everything else here is hand-tuned. Design px are on the 1280x720 Kit.screen canvas.

local Minimap = {}

-- BEGIN GENERATED (tools/minimap/build.py)
-- World square covered by the map image (studs) and its tiles (row 1 = north = smallest Z, column 1 = west).
Minimap.WORLD_MIN = Vector2.new(-6656, -6756)
Minimap.WORLD_SIZE = 13312
Minimap.TILE_COUNT = 4
Minimap.TILE_PIXELS = 1024
Minimap.TILES = {
	{
		"rbxassetid://71683536088484",
		"rbxassetid://84634038482707",
		"rbxassetid://112294688995030",
		"rbxassetid://105785173088824",
	},
	{
		"rbxassetid://118661809691704",
		"rbxassetid://130950512674969",
		"rbxassetid://132999271595403",
		"rbxassetid://91215438591211",
	},
	{
		"rbxassetid://116769361546354",
		"rbxassetid://91042641368167",
		"rbxassetid://73651916911637",
		"rbxassetid://89888633861705",
	},
	{
		"rbxassetid://71624217327690",
		"rbxassetid://129977074106293",
		"rbxassetid://77985728837924",
		"rbxassetid://108570046331914",
	},
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

-- The v2 island (Config/WorldLayout.Bounds play area): the fullscreen map fits a square of FIT_SPAN studs around the
-- origin, pans stay within CENTER_LIMIT, waypoints land at GROUND_Y (the city grade).
Minimap.ISLAND_HALF = 6300
Minimap.FIT_SPAN = (6300 + 100) * 2
Minimap.CENTER_LIMIT = 6300 + 80
Minimap.GROUND_Y = 12

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
	TOUCH_TOP = 10, -- design px below the topbar inset (touch); the N marker pokes ~11 px above the rim
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
	ROUTE_BUDGET_MS = 4, -- a RoadGraph.route slower than this is logged (VIBE_ROUTING #22)
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
-- "gear", "spray" and "chop" put a blip on every Lock & Load / Fresh Coat / chop yard of the v2 island.
Minimap.POIS = {
	{ id = "dealership", icon = "car", color = Color3.fromRGB(0, 214, 255), label = "Hotwire Motors", at = "dealer" },
	{ id = "gearshop", icon = "wrench", color = Color3.fromRGB(255, 205, 50), label = "Lock & Load", at = "gear" },
	{ id = "spray", icon = "spray", color = Color3.fromRGB(255, 120, 200), label = "Fresh Coat", at = "spray" },
	{ id = "chop", icon = "saw", color = Color3.fromRGB(255, 140, 40), label = "Chop Shop", at = "chop" },
	{ id = "police", icon = "badge", color = Color3.fromRGB(70, 140, 255), label = "HCPD HQ", at = "poi:PoliceHQ" },
	{
		id = "plaza",
		icon = "star",
		color = Color3.fromRGB(255, 255, 255),
		label = "Hotwire Plaza",
		at = "poi:SpawnPlaza",
		radarRange = 500,
	},
	{
		id = "stunt",
		icon = "flag",
		color = Color3.fromRGB(255, 52, 140),
		label = "Stunt Jump",
		at = "poi:StuntPark",
		radarRange = 600,
	},
	{
		id = "park",
		icon = "tree",
		color = Color3.fromRGB(90, 220, 120),
		label = "Echo Park",
		at = "poi:Park",
		radarRange = 600,
	},
	{
		id = "pier",
		icon = "wheel",
		color = Color3.fromRGB(120, 230, 255),
		label = "Palmera Pier",
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
-- tier 2 = once zoomed in a little. Positions: the v2 districts' centroids, sub-zones and landmarks (WorldLayout).
Minimap.DISTRICTS = {
	{ name = "PINNACLE HEIGHTS", x = 175, z = -372, tier = 1 },
	{ name = "MIDTOWN", x = -2405, z = -380, tier = 1 },
	{ name = "PALMERA BEACH", x = -4730, z = -265, tier = 1 },
	{ name = "SUNWOOD HILLS", x = -1874, z = -3140, tier = 1 },
	{ name = "THE FOUNDRY", x = 2445, z = -735, tier = 1 },
	{ name = "RUST FLATS", x = 2655, z = 1755, tier = 1 },
	{ name = "SOUTHGATE", x = -856, z = 2188, tier = 1 },
	{ name = "IRON BAY", x = 595, z = 3976, tier = 1 },
	{ name = "HOTWIRE INTERNATIONAL", x = -4026, z = 3152, tier = 1 },
	{ name = "RED MESA", x = 4300, z = 400, tier = 1 },
	{ name = "CACTUS JUNCTION", x = 4330, z = -550, tier = 2 },
	{ name = "DRIFTWOOD", x = 5830, z = -2200, tier = 2 },
	{ name = "MOUNT TALON", x = 4300, z = -3030, tier = 2 },
	{ name = "OLD TOWN", x = -870, z = -875, tier = 2 },
	{ name = "CIVIC CENTER", x = -150, z = 600, tier = 2 },
	{ name = "GILDED MILE", x = -1950, z = -275, tier = 2 },
	{ name = "THE STRIP", x = -1500, z = -2115, tier = 2 },
	{ name = "ECHO PARK", x = -1750, z = 1870, tier = 2 },
	{ name = "DUSTBOWL SPEEDWAY", x = 4420, z = 2820, tier = 2 },
	{ name = "STATE PRISON", x = 4650, z = 1400, tier = 2 },
	{ name = "HIDDEN COVE", x = -2900, z = -4120, tier = 2 },
	{ name = "PALMERA MARINA", x = -5100, z = 2250, tier = 2 },
} :: { District }

export type Area = { name: string, x0: number, z0: number, x1: number, z1: number }

-- Area name shown next to the radar: the first box (world studs) containing the player wins, so places come before
-- the sub-zones and districts they sit in (district boxes are their polygons' bounds, most specific first).
Minimap.AREAS = {
	{ name = "HOTWIRE PLAZA", x0 = 361, z0 = -503, x1 = 691, z1 = -307 },
	{ name = "HOTWIRE MOTORS", x0 = -1733, z0 = 794, x1 = -1563, z1 = 1014 },
	{ name = "HCPD HQ", x0 = -865, z0 = 247, x1 = -695, z1 = 453 },
	{ name = "PINNACLE TOWER", x0 = -25, z0 = -517, x1 = 175, z1 = -317 },
	{ name = "LIBERTY SQUARE", x0 = -96, z0 = 252, x1 = 256, z1 = 602 },
	{ name = "ECHO PARK", x0 = -2050, z0 = 1680, x1 = -1450, z1 = 2060 },
	{ name = "DUSTBOWL SPEEDWAY", x0 = 3970, z0 = 2520, x1 = 4870, z1 = 3120 },
	{ name = "STATE PRISON", x0 = 4200, z0 = 1050, x1 = 5100, z1 = 1750 },
	{ name = "RAIL YARD", x0 = 2330, z0 = 1180, x1 = 3700, z1 = 1520 },
	{ name = "PALMERA MARINA", x0 = -5460, z0 = 1800, x1 = -4740, z1 = 2700 },
	{ name = "HIDDEN COVE", x0 = -3150, z0 = -4180, x1 = -2650, z1 = -4060 },
	{ name = "COUNTRY CLUB", x0 = -4420, z0 = -2780, x1 = -3650, z1 = -2240 },
	{ name = "MOUNT TALON", x0 = 3600, z0 = -3730, x1 = 5000, z1 = -2330 },
	{ name = "FINANCIAL CORE", x0 = -500, z0 = -1000, x1 = 900, z1 = 300 },
	{ name = "OLD TOWN", x0 = -1240, z0 = -2050, x1 = -500, z1 = 300 },
	{ name = "CIVIC CENTER", x0 = -600, z0 = 300, x1 = 300, z1 = 900 },
	{ name = "ARTS DISTRICT", x0 = 1000, z0 = 500, x1 = 1590, z1 = 1290 },
	{ name = "GILDED MILE", x0 = -2400, z0 = -700, x1 = -1500, z1 = 150 },
	{ name = "THE STRIP", x0 = -2400, z0 = -2330, x1 = -600, z1 = -1900 },
	{ name = "PALMERA NORTH", x0 = -4520, z0 = -2100, x1 = -3760, z1 = -1080 },
	{ name = "CACTUS JUNCTION", x0 = 3880, z0 = -980, x1 = 4780, z1 = -120 },
	{ name = "DRIFTWOOD", x0 = 5560, z0 = -2520, x1 = 6100, z1 = -1880 },
	{ name = "PINNACLE HEIGHTS", x0 = -1240, z0 = -2050, x1 = 1590, z1 = 1290 },
	{ name = "MIDTOWN", x0 = -3570, z0 = -2050, x1 = -1240, z1 = 1290 },
	{ name = "PALMERA BEACH", x0 = -5700, z0 = -2250, x1 = -3760, z1 = 1720 },
	{ name = "THE FOUNDRY", x0 = 1590, z0 = -1900, x1 = 3300, z1 = 430 },
	{ name = "RUST FLATS", x0 = 1590, z0 = 430, x1 = 3720, z1 = 3100 },
	{ name = "SOUTHGATE", x0 = -2560, z0 = 1290, x1 = 1590, z1 = 3080 },
	{ name = "IRON BAY", x0 = -2000, z0 = 3360, x1 = 3150, z1 = 4660 },
	{ name = "HOTWIRE INTERNATIONAL", x0 = -6000, z0 = 1720, x1 = -2240, z1 = 4500 },
	{ name = "SUNWOOD HILLS", x0 = -5600, z0 = -4800, x1 = 2300, z1 = -1880 },
	{ name = "RED MESA", x0 = 1500, z0 = -5000, x1 = 6400, z1 = 4100 },
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
