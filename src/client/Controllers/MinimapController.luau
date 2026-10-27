--!strict
-- MinimapController: the GTA V radar (gta_ui_language §2.2, §5.1) + GPS routing.
--
--  * Radar: a flat rectangle (0.150 W x 0.189 H, UI/HudLayout: bottom-left on desktop, top-left under the top bar on
--    touch) with no rounded corners or bezel. The city map image (Config/Minimap tiles) turns with the camera; the
--    player arrow sits centred, 60% down; the zoom eases out with speed while driving. A plain clipping Frame (no
--    CanvasGroup: rotated children clip correctly since the 2026 rollout).
--  * Blips (upright, pooled ImageLabels on the blip atlas) in the GTA palette: shops / landmarks white, your garage
--    blue (sticks to the edge when off-radar), other garages grey, police red / blue while the siren is on, the
--    chopper, other players (small Freemode-blue dots), every WaypointController waypoint in its own colour (sticky).
--  * Wanted: a 2 px red / blue flash around the radar while a cop can see you; blue vision cones (wedge sprites) for
--    cops within range while they search for you.
--  * GPS: a thin route line in the target's colour (yellow objective, purple waypoint) along the roads (RoadGraph
--    A*), recomputed when the target changes / moves or when the player strays; the driven part is trimmed every
--    frame, and the remaining distance shows top-right inside the radar. The custom map waypoint clears itself on
--    arrival. Entering a new area shows its name in the HUD's bottom-right script block (HUDController.showLocation).
--  * Click / tap the radar for the full map (pause menu MAP tab). Hidden in streamer mode (settings.hideHud).
--  * Cost: one RenderStep update at <= RADAR.UPDATE_HZ; no Instance.new or table allocation per frame (pools grow only
--    when more blips than ever before are on screen).
--
-- Public API (beyond init/start):
--   getRoute(): ({ Vector3 }?, Color3?, Vector3?)   current GPS polyline (road points), its color and the real target
--   getGpsTarget(): (string?, Vector3?)            active GPS waypoint id + position
--   setCustomWaypoint(pos: Vector3?, label?)       place / clear the player's map waypoint
--   getCustomWaypoint(): Vector3?, getRemaining(): number (studs left on the route), getPolice(): { Model }
--   RouteChanged: Signal()                         fires when the polyline is recomputed or cleared
--   newRouteRenderer(parent, width, outline) / drawRoute(renderer, ...)   shared with MapScreenController
-- Pure helpers (tests): worldToMap, mapToWorld, headingOf, rotate, radarOffset, radarToWorld, clampToCircle,
--   clampToRect, zoomFor, smooth, waypointIcon, routable, priorityOf, pickTarget, areaAt, titleCase, poiPositions,
--   wantedRadius, segmentGeometry, flashOn, cellOf, poiColor.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = Shared:WaitForChild("Config")
local MapConfig = require(Config:WaitForChild("Map"))
local MinimapConfig = require(Config:WaitForChild("Minimap"))
local Util = Shared:WaitForChild("Util")
local MapLayout = require(Util:WaitForChild("MapLayout"))
local RoadGraph = require(Util:WaitForChild("RoadGraph"))
local Signal = require(Util:WaitForChild("Signal"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))
local HudLayout = require(UI:WaitForChild("HudLayout"))

-- Earlier in the client ORDER: safe to require at the top.
local HUDController = require(script.Parent:WaitForChild("HUDController"))
local SoundController = require(script.Parent:WaitForChild("SoundController"))
local WaypointController = require(script.Parent:WaitForChild("WaypointController"))

local MinimapController = {}

MinimapController.RouteChanged = Signal.new()

local player = Players.LocalPlayer

local RADAR = MinimapConfig.RADAR
local GPS = MinimapConfig.GPS
local WANTED = MinimapConfig.WANTED
local WORLD_MIN = MinimapConfig.WORLD_MIN
local WORLD_SIZE = MinimapConfig.WORLD_SIZE
local CUSTOM = MinimapConfig.CUSTOM_WAYPOINT
local ATLAS = MinimapConfig.ATLAS
local CELLS = MinimapConfig.ATLAS_CELLS :: { [string]: { number } }
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local ROUTE_DARK = Color3.fromRGB(10, 12, 16)
local C = Theme.Colors
-- GTA map palette (gta_ui_language §3 map tiles)
local MAP_WATER = Color3.fromHex("#1F3445")
local MAP_ROAD = Color3.fromHex("#8C8C8C")
local ROUTE_WIDTH = 4 -- GTA's GPS line is thin
local ROUTE_OUTLINE = 1.5
local RADAR_ARROW = 16
local BLIP_SIZE = 16
local BLIP_SMALL = 8
local CONE_RANGE = 400 -- studs: cops whose vision cone shows while they search
local CONE_RADIUS = 90 -- studs: cone length
local BLIP_OWN_GARAGE = C.Blue
MinimapController.PIVOT_Y = 0.6 -- the player sits centred, 60% down (GTA V)
local UPDATE_DT = 1 / RADAR.UPDATE_HZ
local SLOW_DT = GPS.SELECT_INTERVAL

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
-------------------------------------------------------------------------------------------------------------------------

-- World XZ -> map image space in studs from the image's top-left (u right = +X, v down = +Z).
function MinimapController.worldToMap(x: number, z: number): (number, number)
	return x - WORLD_MIN.X, z - WORLD_MIN.Y
end

function MinimapController.mapToWorld(u: number, v: number): (number, number)
	return u + WORLD_MIN.X, v + WORLD_MIN.Y
end

-- Heading of a horizontal look vector in degrees clockwise from north (-Z): north 0, east 90, south 180, west -90.
function MinimapController.headingOf(lx: number, lz: number): number
	if lx == 0 and lz == 0 then
		return 0
	end
	return math.deg(math.atan2(lx, -lz))
end

-- Rotate a screen offset (y down) clockwise by `deg` degrees (same sense as GuiObject.Rotation).
function MinimapController.rotate(x: number, y: number, deg: number): (number, number)
	local r = math.rad(deg)
	local c, s = math.cos(r), math.sin(r)
	return x * c - y * s, x * s + y * c
end

-- Radar pixel offset (from the radar center) of a world delta (dx, dz) at `scale` px per stud with the map turned by
-- `rotDeg` (the radar container's Rotation).
function MinimapController.radarOffset(dx: number, dz: number, scale: number, rotDeg: number): (number, number)
	return MinimapController.rotate(dx * scale, dz * scale, rotDeg)
end

-- Inverse of radarOffset: radar pixel offset -> world delta.
function MinimapController.radarToWorld(sx: number, sy: number, scale: number, rotDeg: number): (number, number)
	local x, y = MinimapController.rotate(sx, sy, -rotDeg)
	return x / scale, y / scale
end

-- Pull a point back onto a circle of radius r when it's outside: (x, y, wasOutside).
function MinimapController.clampToCircle(x: number, y: number, r: number): (number, number, boolean)
	local d = math.sqrt(x * x + y * y)
	if d <= r or d < 1e-6 then
		return x, y, false
	end
	return x / d * r, y / d * r, true
end

-- Pull a point (relative to the pivot) back inside the rectangle [left, right] x [top, bottom] along the ray from the
-- pivot, keeping its direction: (x, y, wasOutside). Edge-clamped blips (GTA's sticky objective / home / waypoint).
function MinimapController.clampToRect(
	x: number,
	y: number,
	left: number,
	right: number,
	top: number,
	bottom: number
): (number, number, boolean)
	if x >= left and x <= right and y >= top and y <= bottom then
		return x, y, false
	end
	local t = 1
	if x > right and x > 1e-9 then
		t = math.min(t, right / x)
	elseif x < left and x < -1e-9 then
		t = math.min(t, left / x)
	end
	if y > bottom and y > 1e-9 then
		t = math.min(t, bottom / y)
	elseif y < top and y < -1e-9 then
		t = math.min(t, top / y)
	end
	t = math.max(0, t)
	return x * t, y * t, true
end

-- "SUNSET BEACH" -> "Sunset Beach" (the script font reads best in title case).
function MinimapController.titleCase(text: string): string
	return (
		string.gsub(string.lower(text), "(%a)([%w']*)", function(a: string, b: string): string
			return string.upper(a) .. b
		end)
	)
end

-- GTA palette for a fixed POI blip (shops / landmarks white, police HQ blue); the config colour otherwise.
local POI_COLORS: { [string]: Color3 } = {
	dealership = C.Text,
	gearshop = C.Text,
	spray = C.Text,
	chop = C.Text,
	police = C.Blue,
	plaza = C.BlipDefault,
	stunt = C.BlipDefault,
	park = C.BlipDefault,
	pier = C.BlipDefault,
}
function MinimapController.poiColor(id: string, fallback: Color3): Color3
	return POI_COLORS[id] or fallback
end

-- Target zoom (studs from the radar center to its edge).
function MinimapController.zoomFor(driving: boolean, speed: number): number
	if not driving then
		return RADAR.ZOOM_FOOT
	end
	local t = math.clamp((if speed == speed then speed else 0) / RADAR.ZOOM_SPEED_FULL, 0, 1)
	t = t * t * (3 - 2 * t) -- smoothstep: holds close-in at low speed, opens up on the straights
	return RADAR.ZOOM_DRIVE_MIN + (RADAR.ZOOM_DRIVE_MAX - RADAR.ZOOM_DRIVE_MIN) * t
end

-- Frame-rate independent exponential approach.
function MinimapController.smooth(current: number, target: number, dt: number, rate: number): number
	return current + (target - current) * (1 - math.exp(-rate * math.max(0, dt)))
end

function MinimapController.waypointIcon(id: string): string
	local icons = MinimapConfig.WAYPOINT_ICONS
	local exact = icons[id]
	if exact then
		return exact
	end
	local best, bestLen = MinimapConfig.DEFAULT_WAYPOINT_ICON, 0
	for prefix, icon in icons do
		if #prefix > bestLen and string.sub(id, 1, #prefix) == prefix then
			best, bestLen = icon, #prefix
		end
	end
	return best
end

-- Does the GPS route to this waypoint? (informational ones only get a blip)
function MinimapController.routable(id: string): boolean
	for _, prefix in GPS.NO_ROUTE_PREFIX do
		if string.sub(id, 1, #prefix) == prefix then
			return false
		end
	end
	return true
end

-- Lower = more important. Unlisted ids rank after every listed one.
function MinimapController.priorityOf(id: string): number
	for i, key in GPS.PRIORITY do
		if key == id then
			return i
		end
	end
	return #GPS.PRIORITY + 1
end

-- Pick the GPS target among candidates { { id, pos } }: best priority, then id order (deterministic).
function MinimapController.pickTarget(list: { { id: string, pos: Vector3 } }): (string?, Vector3?)
	local bestId: string?, bestPos: Vector3? = nil, nil
	local bestRank = math.huge
	for _, c in list do
		if MinimapController.routable(c.id) then
			local rank = MinimapController.priorityOf(c.id)
			if rank < bestRank or (rank == bestRank and bestId ~= nil and c.id < bestId) then
				bestId, bestPos, bestRank = c.id, c.pos, rank
			end
		end
	end
	return bestId, bestPos
end

-- Area name under a world position (Config/Minimap.AREAS, first box that contains it).
function MinimapController.areaAt(pos: Vector3): string
	for _, a in MinimapConfig.AREAS do
		if pos.X >= a.x0 and pos.X <= a.x1 and pos.Z >= a.z0 and pos.Z <= a.z1 then
			return a.name
		end
	end
	return MinimapConfig.AREA_DEFAULT
end

-- World positions of a POI blip spec (Config/Minimap.POIS[i].at).
function MinimapController.poiPositions(at: string): { Vector3 }
	local out: { Vector3 } = {}
	if at == "spray" then
		for _, z in MapLayout.sprayZones() do
			table.insert(out, z.cframe.Position - Vector3.new(0, z.size.Y / 2, 0))
		end
	elseif at == "chop" then
		local cf, size = MapLayout.chopZone()
		table.insert(out, cf.Position - Vector3.new(0, size.Y / 2, 0))
	elseif at == "gear" then
		table.insert(out, MapLayout.gearShopCounter().Position)
	elseif at == "dealer" then
		table.insert(out, MapLayout.poiCenter("Dealership"))
	elseif string.sub(at, 1, 4) == "poi:" then
		local name = string.sub(at, 5)
		if MapConfig.Blocks[name] then
			table.insert(out, MapLayout.poiCenter(name))
		end
	end
	return out
end

-- Police search-area radius (studs) for a star count (0 = none).
function MinimapController.wantedRadius(stars: number): number
	if stars < 1 then
		return 0
	end
	return WANTED.RADIUS_BASE + WANTED.RADIUS_PER_STAR * (math.min(stars, 5) - 1)
end

-- Route segment a -> b in map space (studs from the map's top-left): center (cu, cv), length, angle (degrees).
function MinimapController.segmentGeometry(
	ax: number,
	az: number,
	bx: number,
	bz: number
): (number, number, number, number)
	local au, av = MinimapController.worldToMap(ax, az)
	local bu, bv = MinimapController.worldToMap(bx, bz)
	local du, dv = bu - au, bv - av
	return (au + bu) / 2, (av + bv) / 2, math.sqrt(du * du + dv * dv), math.deg(math.atan2(dv, du))
end

-- Two-phase flash (red / blue): true for the first phase.
function MinimapController.flashOn(t: number, hz: number, phase: number?): boolean
	return math.floor(t * hz * 2 + (phase or 0)) % 2 == 0
end

-- Atlas cell for an icon name (falls back to the generic diamond / dot).
function MinimapController.cellOf(icon: string): { number }?
	return CELLS[icon] or CELLS[MinimapConfig.DEFAULT_WAYPOINT_ICON] or CELLS.dot
end

-------------------------------------------------------------------------------------------------------------------------
-- Route renderer (shared with MapScreenController): pill segments laid out in the map frame's scale space, so a
-- zoom only resizes the parent frame; the line keeps a constant pixel width with round caps (UICorner) and a dark
-- outline layer underneath.
-------------------------------------------------------------------------------------------------------------------------

export type RouteRenderer = {
	layer: Frame,
	under: Frame,
	over: Frame,
	outlines: { Frame },
	cores: { Frame },
	used: number,
	width: number,
	outline: number,
	color: Color3,
}

local function pill(parent: Instance, color: Color3, z: number): Frame
	local f = Kit.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = z,
		Visible = false,
		Parent = parent,
	})
	Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = f })
	return f
end

function MinimapController.newRouteRenderer(parent: GuiObject, width: number, outline: number): RouteRenderer
	local layer = Kit.new("Frame", {
		Name = "Route",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		Parent = parent,
	})
	local under = Kit.new("Frame", {
		Name = "Outline",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Parent = layer,
	})
	local over = Kit.new("Frame", {
		Name = "Core",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = layer,
	})
	return {
		layer = layer,
		under = under,
		over = over,
		outlines = {},
		cores = {},
		used = 0,
		width = width,
		outline = outline,
		color = WHITE,
	}
end

-- Lay out segment i (a -> b in world XZ). transparency: 0 solid; tail segments fade a little.
local function setSegment(r: RouteRenderer, i: number, ax: number, az: number, bx: number, bz: number, alpha: number)
	local core = r.cores[i]
	local out = r.outlines[i]
	if not core then
		out = pill(r.under, ROUTE_DARK, 1)
		core = pill(r.over, r.color, 2)
		r.outlines[i] = out
		r.cores[i] = core
	end
	local cu, cv, len, angle = MinimapController.segmentGeometry(ax, az, bx, bz)
	local pos = UDim2.fromScale(cu / WORLD_SIZE, cv / WORLD_SIZE)
	local w = r.width
	local o = w + r.outline * 2
	core.Position = pos
	core.Size = UDim2.new(len / WORLD_SIZE, w, 0, w)
	core.Rotation = angle
	core.BackgroundColor3 = r.color
	core.BackgroundTransparency = alpha
	core.Visible = true
	out.Position = pos
	out.Size = UDim2.new(len / WORLD_SIZE, o, 0, o)
	out.Rotation = angle
	out.BackgroundTransparency = math.max(0.15, alpha)
	out.Visible = true
end

-- Draw points[first + 1 .. n] starting from (sx, sz) (the trimmed head), then an optional faded tail to the real
-- target (tx, tz) when it is off the road. Hides leftovers. nil points clears.
function MinimapController.drawRoute(
	r: RouteRenderer,
	points: { Vector3 }?,
	first: number,
	sx: number,
	sz: number,
	color: Color3,
	tail: Vector3?
)
	r.color = color
	local n = 0
	if points and #points >= 2 then
		local px, pz = sx, sz
		for i = first + 1, #points do
			local p = points[i]
			if math.abs(p.X - px) + math.abs(p.Z - pz) > 0.05 then
				n += 1
				setSegment(r, n, px, pz, p.X, p.Z, 0)
				px, pz = p.X, p.Z
			end
		end
		if tail and math.abs(tail.X - px) + math.abs(tail.Z - pz) > 2 then
			n += 1
			setSegment(r, n, px, pz, tail.X, tail.Z, 0.35)
		end
	end
	for i = n + 1, r.used do
		r.cores[i].Visible = false
		r.outlines[i].Visible = false
	end
	r.used = n
end

-- Fast path: only move the head segment (index 1) to start at (sx, sz).
local function moveHead(r: RouteRenderer, sx: number, sz: number, bx: number, bz: number)
	if r.used >= 1 then
		setSegment(r, 1, sx, sz, bx, bz, 0)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------------------------------------------------

type BlipPool = {
	parent: Frame,
	items: { ImageLabel },
	icon: { string },
	color: { Color3 },
	size: { number },
	used: number,
	shown: number,
}

type ConePool = { parent: Frame, items: { ImageLabel }, used: number, shown: number }

type Radar = {
	gui: ScreenGui,
	holder: TextButton,
	flash: Frame,
	flashStroke: UIStroke,
	clip: Frame,
	spin: Frame,
	world: Frame,
	route: RouteRenderer,
	cones: ConePool,
	blips: BlipPool,
	arrow: ImageLabel,
	north: ImageLabel,
	dist: Frame,
	distDot: ImageLabel,
	distLabel: TextLabel,
}

local radar: Radar? = nil
local hidden = false
local touchLayout = false
-- radar rect (design px) and the player pivot inside it (GTA V: centred, 60% down)
local rectW, rectH = 192, 136
local pivotX, pivotY = 96, 82
local spinSize = 300

local zoom = RADAR.ZOOM_FOOT
local lastScale = -1
local lastWorldX, lastWorldY = math.huge, math.huge
local accum = 0
local slowAccum = math.huge
local clock = 0
local lastArea = ""

-- GPS
local route: { Vector3 }? = nil
local routeTarget: Vector3? = nil -- the real target (may be off-road)
local routeTargetId: string? = nil
local routeColor = WHITE
local routeHead = 1 -- route segment the player is on (points[routeHead] -> points[routeHead + 1])
local lastRouteAt = -math.huge
local remaining = 0
local gpsId: string? = nil
local gpsPos: Vector3? = nil
local candidates: { { id: string, pos: Vector3, color: Color3 } } = {}
local candidateCount = 0

-- blips sources
type PoiEntry = { pos: Vector3, icon: string, color: Color3, range: number? }
local pois: { PoiEntry } = {}
type GarageEntry = { index: number, pos: Vector3, model: Instance?, owner: number }
local garages: { GarageEntry } = {}
local police: { Model } = {}
local helis: { Model } = {}
local otherRoots: { BasePart } = {}

local function lazy(name: string): any
	local mod = script.Parent:FindFirstChild(name)
	if not (mod and mod:IsA("ModuleScript")) then
		return nil
	end
	local ok, result = pcall(require, mod :: any)
	return if ok and typeof(result) == "table" then result else nil
end

local function rootPart(): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-------------------------------------------------------------------------------------------------------------------------
-- Blip + cone pools
-------------------------------------------------------------------------------------------------------------------------

local function newPool(parent: Frame): BlipPool
	return { parent = parent, items = {}, icon = {}, color = {}, size = {}, used = 0, shown = 0 }
end

local function poolBegin(pool: BlipPool)
	pool.used = 0
end

local function poolPut(pool: BlipPool, icon: string, color: Color3, size: number, x: number, y: number, z: number)
	local i = pool.used + 1
	pool.used = i
	local item = pool.items[i]
	if not item then
		item = Kit.new("ImageLabel", {
			Name = "Blip",
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			Image = ATLAS,
			ScaleType = Enum.ScaleType.Fit,
			Parent = pool.parent,
		})
		if ATLAS == "" then
			-- no atlas yet (tools/minimap/build.py not run): plain colored dots
			item.BackgroundTransparency = 0
			Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = item })
		end
		pool.items[i] = item
		pool.icon[i] = ""
		pool.size[i] = -1
		pool.color[i] = BLACK
	end
	local it = item :: ImageLabel
	if pool.icon[i] ~= icon then
		pool.icon[i] = icon
		local cell = MinimapController.cellOf(icon)
		if cell then
			it.ImageRectOffset = Vector2.new(cell[1], cell[2])
			it.ImageRectSize = Vector2.new(cell[3], cell[4])
		end
	end
	if pool.color[i] ~= color then
		pool.color[i] = color
		it.ImageColor3 = color
		it.BackgroundColor3 = color
	end
	if pool.size[i] ~= size then
		pool.size[i] = size
		it.Size = UDim2.fromOffset(size, size)
	end
	it.Position = UDim2.fromOffset(x, y)
	it.ZIndex = z
	if i > pool.shown then
		it.Visible = true
	end
end

local function poolEnd(pool: BlipPool)
	for i = pool.used + 1, pool.shown do
		pool.items[i].Visible = false
	end
	for i = pool.shown + 1, pool.used do
		pool.items[i].Visible = true
	end
	pool.shown = pool.used
end

-- Police vision cones (§5.1): wedge sprites in map space (they turn with the map), apex on the cop.
local function conePut(pool: ConePool, u: number, v: number, radius: number, heading: number)
	local i = pool.used + 1
	pool.used = i
	local item = pool.items[i]
	if not item then
		item = Kit.image("wedge", {
			Name = "Cone",
			AnchorPoint = Vector2.new(0.5, 0.5),
			ScaleType = Enum.ScaleType.Stretch,
			ImageColor3 = C.Blue,
			ImageTransparency = 0.55,
			ZIndex = 2,
			Parent = pool.parent,
		})
		pool.items[i] = item
	end
	local it = item :: ImageLabel
	it.Position = UDim2.fromScale(u / WORLD_SIZE, v / WORLD_SIZE)
	it.Size = UDim2.fromScale(radius * 2 / WORLD_SIZE, radius * 2 / WORLD_SIZE)
	it.Rotation = heading
	if i > pool.shown then
		it.Visible = true
	end
end

local function coneEnd(pool: ConePool)
	for i = pool.used + 1, pool.shown do
		pool.items[i].Visible = false
	end
	for i = pool.shown + 1, pool.used do
		pool.items[i].Visible = true
	end
	pool.shown = pool.used
end

-------------------------------------------------------------------------------------------------------------------------
-- Build
-------------------------------------------------------------------------------------------------------------------------

-- Fallback when the map tiles are not uploaded yet: draw the road graph as plain frames (static, built once).
local function buildFallbackRoads(world: Frame)
	local g = RoadGraph.get()
	for _, e in g.edges do
		local a, b = g.nodes[e.a], g.nodes[e.b]
		local cu, cv, len, angle = MinimapController.segmentGeometry(a.X, a.Z, b.X, b.Z)
		Kit.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = MAP_ROAD,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(cu / WORLD_SIZE, cv / WORLD_SIZE),
			Size = UDim2.fromScale((len + e.width) / WORLD_SIZE, e.width * 0.4 / WORLD_SIZE),
			Rotation = angle,
			ZIndex = 1,
			Parent = world,
		})
	end
end

local function buildRadar(): Radar
	local gui = Kit.screen("HC_Minimap", Theme.Layers.HUD, { touchMin = Theme.TouchMinScale })
	local holder = Kit.new("TextButton", {
		Name = "Radar",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.fromOffset(rectW, rectH),
		Parent = gui,
	})
	-- red / blue flash while a cop can see you (§2.2): a 2 px frame just outside the map
	local flash = Kit.new("Frame", {
		Name = "Flash",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 4, 1, 4),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 1,
		Parent = holder,
	})
	local flashStroke = Kit.new("UIStroke", {
		Color = C.Red,
		Thickness = 2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = flash,
	})
	-- the map: a plain clipping Frame (rotated children clip correctly since the 2026 rollout, §5.1)
	local clip = Kit.new("Frame", {
		Name = "Clip",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = MAP_WATER,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		ZIndex = 2,
		Parent = holder,
	})
	Kit.new("UIStroke", {
		Color = BLACK,
		Thickness = 1,
		Transparency = 0.4,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = clip,
	})
	local spin = Kit.new("Frame", {
		Name = "Spin",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(spinSize, spinSize),
		ZIndex = 1,
		Parent = clip,
	})
	local world = Kit.new("Frame", {
		Name = "World",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(WORLD_SIZE, WORLD_SIZE),
		ZIndex = 1,
		Parent = spin,
	})
	local n = MinimapConfig.TILE_COUNT
	local anyTile = false
	for r = 1, n do
		for c = 1, n do
			local id = MinimapConfig.TILES[r] and MinimapConfig.TILES[r][c] or ""
			if id ~= "" then
				anyTile = true
				Kit.new("ImageLabel", {
					Name = ("Tile%d_%d"):format(r, c),
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
					Image = id,
					-- a hair of overlap hides seams between tiles when the map is scaled
					Position = UDim2.fromScale((c - 1) / n, (r - 1) / n),
					Size = UDim2.new(1 / n, 1, 1 / n, 1),
					ZIndex = 1,
					Parent = world,
				})
			end
		end
	end
	if not anyTile then
		buildFallbackRoads(world)
	end
	local coneLayer = Kit.new("Frame", {
		Name = "Cones",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = world,
	})
	local routeR = MinimapController.newRouteRenderer(world, ROUTE_WIDTH, ROUTE_OUTLINE)

	local blipLayer = Kit.new("Frame", {
		Name = "Blips",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = clip,
	})
	local arrow = Kit.image("hud.arrow", {
		Name = "Player",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(RADAR_ARROW, RADAR_ARROW),
		ZIndex = 7,
		Parent = holder,
	})
	local north = Kit.image("hud.north", {
		Name = "North",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(16, 16),
		ZIndex = 8,
		Parent = holder,
	})
	-- GPS distance (GTA VI-style readout, top-right inside the radar)
	local dist = Kit.new("Frame", {
		Name = "Distance",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -4, 0, 4),
		Size = UDim2.fromOffset(0, 16),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = BLACK,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 8,
		Parent = holder,
	})
	Kit.new("UIPadding", {
		PaddingLeft = UDim.new(0, 4),
		PaddingRight = UDim.new(0, 5),
		Parent = dist,
	})
	Kit.list(Enum.FillDirection.Horizontal, 3, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center).Parent =
		dist
	local distDot = Kit.new("ImageLabel", {
		Name = "Icon",
		BackgroundTransparency = 1,
		Image = ATLAS,
		Size = UDim2.fromOffset(10, 10),
		LayoutOrder = 1,
		ZIndex = 9,
		Parent = dist,
	})
	local distLabel = Kit.text("0m", "condensedMedium", 12, {
		Name = "Text",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 16),
		LayoutOrder = 2,
		ZIndex = 9,
		Parent = dist,
	})

	return {
		gui = gui,
		holder = holder,
		flash = flash,
		flashStroke = flashStroke,
		clip = clip,
		spin = spin,
		world = world,
		route = routeR,
		cones = { parent = coneLayer, items = {}, used = 0, shown = 0 },
		blips = newPool(blipLayer),
		arrow = arrow,
		north = north,
		dist = dist,
		distDot = distDot,
		distLabel = distLabel,
	}
end

-- Placement from the shared HUD layout (UI/HudLayout): bottom-left on desktop, top-left on touch.
local function applyLayout()
	local r = radar
	if not r then
		return
	end
	touchLayout = Kit.isTouch()
	local canvas = Kit.canvasSize(r.gui)
	local L = HudLayout.compute(canvas.X, canvas.Y, touchLayout)
	rectW, rectH = L.radar.w, L.radar.h
	pivotX, pivotY = rectW * 0.5, rectH * MinimapController.PIVOT_Y
	local far = math.max(pivotX, rectW - pivotX)
	local farY = math.max(pivotY, rectH - pivotY)
	spinSize = math.ceil(2 * math.sqrt(far * far + farY * farY)) + 4
	r.holder.Position = UDim2.fromOffset(L.radar.x, L.radar.y)
	r.holder.Size = UDim2.fromOffset(rectW, rectH)
	r.spin.Size = UDim2.fromOffset(spinSize, spinSize)
	r.spin.Position = UDim2.fromOffset(pivotX, pivotY)
	r.arrow.Position = UDim2.fromOffset(pivotX, pivotY)
	lastScale = -1
	lastWorldX = math.huge
end

-------------------------------------------------------------------------------------------------------------------------
-- Sources
-------------------------------------------------------------------------------------------------------------------------

local function buildPois()
	RoadGraph.get() -- build the road graph now, not on the first GPS request
	table.clear(pois)
	for _, def in MinimapConfig.POIS do
		local ok, list = pcall(MinimapController.poiPositions, def.at)
		if ok then
			for _, pos in list do
				table.insert(pois, {
					pos = pos,
					icon = def.icon,
					color = MinimapController.poiColor(def.id, def.color),
					range = def.radarRange,
				})
			end
		end
	end
	table.clear(garages)
	local G = MapConfig.Garage
	for i = 1, MapLayout.plotCount() do
		local door = MapLayout.plotToWorld(i, Vector3.new(0, 0, (G.FRONT_Z + G.DROPOFF_CENTER.Z) / 2)).Position
		table.insert(garages, { index = i, pos = door, model = nil, owner = 0 })
	end
end

-- Slow refresh: garage owners, other players' roots.
local function refreshOwners()
	local plots = Workspace:FindFirstChild("Plots")
	for _, g in garages do
		local model = g.model
		if not (model and model.Parent) then
			model = if plots then plots:FindFirstChild("Plot" .. g.index) else nil
			g.model = model
		end
		local owner = if model then model:GetAttribute("OwnerUserId") else nil
		g.owner = if typeof(owner) == "number" then owner else 0
	end
	table.clear(otherRoots)
	for _, p in Players:GetPlayers() do
		if p ~= player then
			local char = p.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				table.insert(otherRoots, root)
			end
		end
	end
end

local function trackTag(tag: string, list: { Model })
	local function add(inst: Instance)
		if inst:IsA("Model") and not table.find(list, inst) then
			table.insert(list, inst)
		end
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(add)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(function(inst: Instance)
		local i = table.find(list, inst :: any)
		if i then
			table.remove(list, i)
		end
	end)
	for _, inst in CollectionService:GetTagged(tag) do
		add(inst)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- GPS
-------------------------------------------------------------------------------------------------------------------------

local function collectCandidate(id: string, pos: Vector3, color: Color3, _label: string)
	candidateCount += 1
	local c = candidates[candidateCount]
	if c then
		c.id, c.pos, c.color = id, pos, color
	else
		candidates[candidateCount] = { id = id, pos = pos, color = color }
	end
end

-- Refresh `candidates` from WaypointController (every radar frame: blips of moving targets stay live).
local function collectWaypoints()
	candidateCount = 0
	WaypointController.each(collectCandidate)
end

local function pickGps(): (string?, Vector3?, Color3)
	local bestId: string?, bestPos: Vector3?, bestColor = nil, nil, WHITE
	local bestRank = math.huge
	for i = 1, candidateCount do
		local c = candidates[i]
		if MinimapController.routable(c.id) then
			local rank = MinimapController.priorityOf(c.id)
			if rank < bestRank or (rank == bestRank and bestId ~= nil and c.id < bestId) then
				bestId, bestPos, bestColor, bestRank = c.id, c.pos, c.color, rank
			end
		end
	end
	return bestId, bestPos, bestColor
end

local function clearRoute()
	if route ~= nil or routeTargetId ~= nil then
		route = nil
		routeTarget = nil
		routeTargetId = nil
		remaining = 0
		local r = radar
		if r then
			MinimapController.drawRoute(r.route, nil, 1, 0, 0, routeColor, nil)
			r.dist.Visible = false
		end
		MinimapController.RouteChanged:Fire()
	end
end

local function updateRemaining(pos: Vector3)
	local pts = route
	if not pts then
		remaining = 0
		return
	end
	local _, seg, _, proj = RoadGraph.projectToPolyline(pts, pos)
	local total = (pts[seg + 1] - proj).Magnitude
	for i = seg + 1, #pts - 1 do
		total += (pts[i + 1] - pts[i]).Magnitude
	end
	local t = routeTarget
	if t then
		local last = pts[#pts]
		total += Vector3.new(t.X - last.X, 0, t.Z - last.Z).Magnitude
	end
	remaining = total
	local r = radar
	if r then
		r.distLabel.Text = WaypointController.formatDistance(total)
	end
end

local function redrawRoute(pos: Vector3)
	local r = radar
	local pts = route
	if not (r and pts) then
		return
	end
	local _, seg, _, proj = RoadGraph.projectToPolyline(pts, pos)
	routeHead = seg
	MinimapController.drawRoute(r.route, pts, seg, proj.X, proj.Z, routeColor, routeTarget)
end

local function computeRoute(pos: Vector3, id: string, target: Vector3, color: Color3)
	local t0 = os.clock()
	local ok, pts = pcall(RoadGraph.route, pos, target)
	lastRouteAt = clock
	if not ok or not pts then
		clearRoute()
		return
	end
	route = pts
	routeTarget = target
	routeTargetId = id
	routeColor = color
	local r = radar
	if r then
		r.distDot.ImageColor3 = color
		local cell = MinimapController.cellOf(MinimapController.waypointIcon(id))
		if cell then
			r.distDot.ImageRectOffset = Vector2.new(cell[1], cell[2])
			r.distDot.ImageRectSize = Vector2.new(cell[3], cell[4])
		end
		r.dist.Visible = not hidden
	end
	redrawRoute(pos)
	updateRemaining(pos)
	MinimapController.RouteChanged:Fire()
	local ms = (os.clock() - t0) * 1000
	if ms > 5 then
		warn(("[MinimapController] slow GPS route: %.1f ms"):format(ms))
	end
end

-- Slow tick: pick the target, decide whether to re-route, arrival check, wanted bookkeeping, owners.
local function slowTick(pos: Vector3)
	-- custom waypoint arrival
	local custom = WaypointController.getPosition(CUSTOM.ID)
	if custom and Vector3.new(custom.X - pos.X, 0, custom.Z - pos.Z).Magnitude <= GPS.ARRIVE_RADIUS then
		WaypointController.clear(CUSTOM.ID)
		pcall(SoundController.play, "Pickup")
	end

	local id, target, color = pickGps()
	gpsId, gpsPos = id, target
	if not (id and target) then
		clearRoute()
		return
	end
	if Vector3.new(target.X - pos.X, 0, target.Z - pos.Z).Magnitude <= GPS.MIN_ROUTE then
		clearRoute()
		return
	end
	local need = false
	if id ~= routeTargetId or route == nil then
		need = true -- new target: route right away
	else
		local old = routeTarget
		if old and Vector3.new(old.X - target.X, 0, old.Z - target.Z).Magnitude > GPS.TARGET_MOVED then
			need = clock - lastRouteAt >= GPS.REROUTE_MIN_INTERVAL
		elseif route then
			local d = RoadGraph.projectToPolyline(route, pos)
			if d > GPS.REROUTE_DISTANCE then
				need = clock - lastRouteAt >= GPS.REROUTE_MIN_INTERVAL
			end
		end
	end
	if need then
		computeRoute(pos, id, target, color)
	else
		if color ~= routeColor then
			routeColor = color
			redrawRoute(pos)
		end
		updateRemaining(pos)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Frame update
-------------------------------------------------------------------------------------------------------------------------

local function headingDeg(cf: CFrame): number
	local look = cf.LookVector
	return MinimapController.headingOf(look.X, look.Z)
end

local function radarRotation(cf: CFrame): number
	local mode = RADAR.ROTATE
	if mode == "north" then
		return 0
	elseif mode == "heading" then
		return -headingDeg(cf)
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return 0
	end
	local look = cam.CFrame.LookVector
	return -MinimapController.headingOf(look.X, look.Z)
end

local function wantedStars(): number
	local w = player:GetAttribute("Wanted")
	return if typeof(w) == "number" then w else 0
end

local function update(dt: number)
	local r = radar
	local root = rootPart()
	if not r or not root then
		return
	end
	clock += dt
	accum += dt
	slowAccum += dt
	if accum < UPDATE_DT then
		return
	end
	local step = accum
	accum = 0

	local rootCf = root.CFrame
	local pos = rootCf.Position
	collectWaypoints()
	if slowAccum >= SLOW_DT then
		slowAccum = 0
		slowTick(pos)
		if math.floor(clock) ~= math.floor(clock - SLOW_DT) then
			refreshOwners()
			local area = MinimapController.areaAt(pos)
			if area ~= lastArea then
				local first = lastArea == ""
				lastArea = area
				-- GTA: the district name shows in the bottom-right script block on entering it
				if not first and area ~= MinimapConfig.AREA_DEFAULT then
					local hud = lazy("HUDController")
					if hud and typeof(hud.showLocation) == "function" then
						pcall(hud.showLocation, nil, MinimapController.titleCase(area), nil)
					end
				end
			end
		end
	end
	if hidden then
		return -- streamer mode: GPS bookkeeping (routes, arrival) keeps running, nothing is drawn
	end

	-- zoom + scale: `zoom` studs fill the distance from the player up to the top edge
	local vel = root.AssemblyLinearVelocity
	local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	local driving = player:GetAttribute("Driving") == true
	zoom = MinimapController.smooth(zoom, MinimapController.zoomFor(driving, speed), step, RADAR.ZOOM_RESPONSE)
	local scale = pivotY / zoom
	local rot = radarRotation(rootCf)
	local half = spinSize / 2

	-- map container
	if math.abs(scale - lastScale) > 1e-4 then
		lastScale = scale
		r.world.Size = UDim2.fromOffset(WORLD_SIZE * scale, WORLD_SIZE * scale)
	end
	local u, v = MinimapController.worldToMap(pos.X, pos.Z)
	local wx, wy = half - u * scale, half - v * scale
	if math.abs(wx - lastWorldX) > 0.01 or math.abs(wy - lastWorldY) > 0.01 then
		lastWorldX, lastWorldY = wx, wy
		r.world.Position = UDim2.fromOffset(wx, wy)
	end
	r.spin.Rotation = rot
	r.arrow.Rotation = headingDeg(rootCf) + rot
	local inset = 8
	local left, right = -pivotX + inset, rectW - pivotX - inset
	local top, bottom = -pivotY + inset, rectH - pivotY - inset
	local nx, ny = MinimapController.rotate(0, -1000, rot)
	nx, ny = MinimapController.clampToRect(nx, ny, left, right, top, bottom)
	r.north.Position = UDim2.fromOffset(pivotX + nx, pivotY + ny)

	-- GPS head trim
	local pts = route
	if pts and r.route.used >= 1 then
		local head = routeHead
		-- advance / step back by at most a couple of segments: the player moves continuously
		local best, bestD = head, math.huge
		for i = math.max(1, head - 1), math.min(#pts - 1, head + 2) do
			local a, b = pts[i], pts[i + 1]
			local dx, dz = b.X - a.X, b.Z - a.Z
			local len2 = dx * dx + dz * dz
			local t = if len2 > 1e-9 then math.clamp(((pos.X - a.X) * dx + (pos.Z - a.Z) * dz) / len2, 0, 1) else 0
			local px, pz = a.X + dx * t - pos.X, a.Z + dz * t - pos.Z
			local d = px * px + pz * pz
			if d < bestD then
				best, bestD = i, d
			end
		end
		if best ~= head then
			redrawRoute(pos)
		else
			local a, b = pts[head], pts[head + 1]
			local dx, dz = b.X - a.X, b.Z - a.Z
			local len2 = dx * dx + dz * dz
			local t = if len2 > 1e-9 then math.clamp(((pos.X - a.X) * dx + (pos.Z - a.Z) * dz) / len2, 0, 1) else 0
			moveHead(r.route, a.X + dx * t, a.Z + dz * t, b.X, b.Z)
		end
	end

	-- wanted: red / blue flash while a cop sees you; vision cones while they search (§5.1)
	local stars = wantedStars()
	local seen = player:GetAttribute("WantedSeen") ~= false
	if stars >= 1 and seen then
		r.flash.Visible = true
		r.flashStroke.Color = if MinimapController.flashOn(clock, 2) then C.Red else C.Blue
	elseif r.flash.Visible then
		r.flash.Visible = false
	end
	local cones = r.cones
	cones.used = 0
	if stars >= 1 and not seen then
		for _, model in police do
			local pp = model.PrimaryPart
			if pp then
				local p = pp.Position
				local dx, dz = p.X - pos.X, p.Z - pos.Z
				if dx * dx + dz * dz < CONE_RANGE * CONE_RANGE then
					local cu, cv = MinimapController.worldToMap(p.X, p.Z)
					local look = pp.CFrame.LookVector
					conePut(cones, cu, cv, CONE_RADIUS, MinimapController.headingOf(look.X, look.Z))
				end
			end
		end
	end
	coneEnd(cones)

	-- blips ------------------------------------------------------------------------------------------------------
	local pool = r.blips
	poolBegin(pool)
	local big = BLIP_SIZE
	local small = BLIP_SMALL
	local view = zoom * 1.6

	local function inRect(x: number, y: number): boolean
		return x >= left and x <= right and y >= top and y <= bottom
	end

	-- other players (lowest)
	for _, other in otherRoots do
		if other.Parent then
			local p = other.Position
			local dx, dz = p.X - pos.X, p.Z - pos.Z
			if dx * dx + dz * dz < view * view then
				local x, y = MinimapController.radarOffset(dx, dz, scale, rot)
				if inRect(x, y) then
					poolPut(pool, "dot", C.Freemode, small, pivotX + x, pivotY + y, 1)
				end
			end
		end
	end
	-- landmarks / shops
	for _, poi in pois do
		local dx, dz = poi.pos.X - pos.X, poi.pos.Z - pos.Z
		local d2 = dx * dx + dz * dz
		local range = poi.range
		if d2 < view * view and (range == nil or d2 < range * range) then
			local x, y = MinimapController.radarOffset(dx, dz, scale, rot)
			if inRect(x, y) then
				poolPut(pool, poi.icon, poi.color, big, pivotX + x, pivotY + y, 2)
			end
		end
	end
	-- garages (own garage sticks to the edge)
	local me = player.UserId
	for _, g in garages do
		local mine = g.owner == me and me ~= 0
		if mine or g.owner ~= 0 then
			local dx, dz = g.pos.X - pos.X, g.pos.Z - pos.Z
			local x, y = MinimapController.radarOffset(dx, dz, scale, rot)
			if mine then
				x, y = MinimapController.clampToRect(x, y, left, right, top, bottom)
				poolPut(pool, "garage", BLIP_OWN_GARAGE, big + 2, pivotX + x, pivotY + y, 4)
			elseif inRect(x, y) then
				poolPut(pool, "garage", C.TextDim, big - 4, pivotX + x, pivotY + y, 2)
			end
		end
	end
	-- police cars + chopper (red / blue while the siren is on)
	for i, model in police do
		local pp = model.PrimaryPart
		if pp then
			local p = pp.Position
			local dx, dz = p.X - pos.X, p.Z - pos.Z
			if dx * dx + dz * dz < view * view then
				local x, y = MinimapController.radarOffset(dx, dz, scale, rot)
				if inRect(x, y) then
					local siren = model:GetAttribute("Siren") == true
					local c = if siren and MinimapController.flashOn(clock, RADAR.WANTED_FLASH_HZ, i)
						then C.Red
						else C.Blue
					poolPut(pool, "dot", c, small + 2, pivotX + x, pivotY + y, 3)
				end
			end
		end
	end
	for _, model in helis do
		local pp = model.PrimaryPart
		if pp then
			local p = pp.Position
			local x, y = MinimapController.radarOffset(p.X - pos.X, p.Z - pos.Z, scale, rot)
			x, y = MinimapController.clampToRect(x, y, left, right, top, bottom)
			poolPut(
				pool,
				"heli",
				if MinimapController.flashOn(clock, 2) then C.Red else C.Blue,
				big,
				pivotX + x,
				pivotY + y,
				3
			)
		end
	end
	-- waypoints (sticky to the edge, on top)
	for i = 1, candidateCount do
		local c = candidates[i]
		local dx, dz = c.pos.X - pos.X, c.pos.Z - pos.Z
		local x, y = MinimapController.radarOffset(dx, dz, scale, rot)
		x, y = MinimapController.clampToRect(x, y, left, right, top, bottom)
		poolPut(pool, MinimapController.waypointIcon(c.id), c.color, big + 2, pivotX + x, pivotY + y, 5)
	end
	poolEnd(pool)
end

-------------------------------------------------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------------------------------------------------

function MinimapController.getRoute(): ({ Vector3 }?, Color3?, Vector3?)
	if not route then
		return nil, nil, nil
	end
	return route, routeColor, routeTarget
end

function MinimapController.getGpsTarget(): (string?, Vector3?)
	return gpsId, gpsPos
end

function MinimapController.getRemaining(): number
	return remaining
end

function MinimapController.setCustomWaypoint(pos: Vector3?, label: string?)
	if typeof(pos) == "Vector3" then
		WaypointController.set(CUSTOM.ID, pos, C.Waypoint, label or CUSTOM.LABEL)
	else
		WaypointController.clear(CUSTOM.ID)
	end
	slowAccum = math.huge -- re-pick + route on the next frame
end

function MinimapController.getCustomWaypoint(): Vector3?
	return WaypointController.getPosition(CUSTOM.ID)
end

-- Police cars currently tracked (CollectionService tag "Police"); read-only.
function MinimapController.getPolice(): { Model }
	return police
end

function MinimapController.isHidden(): boolean
	return hidden
end

-- Advance one frame by hand (headless tests). The live game drives this from RenderStepped.
function MinimapController.step(dt: number)
	update(dt)
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

local function setHidden(value: boolean)
	hidden = value
	local r = radar
	if r then
		r.gui.Enabled = not value
		r.dist.Visible = not value and route ~= nil
	end
end

function MinimapController.init() end

-- Build the radar without wiring any engine events (start() calls this first; headless tests call it alone).
function MinimapController.mount()
	if radar then
		return
	end
	buildPois()
	radar = buildRadar()
	applyLayout()
	trackTag("Police", police)
	trackTag("PoliceHeli", helis)
	refreshOwners()
end

function MinimapController.start()
	MinimapController.mount()
	local r = radar :: Radar

	r.gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyLayout)
	local scale = r.gui:FindFirstChildOfClass("UIScale")
	if scale then
		scale:GetPropertyChangedSignal("Scale"):Connect(applyLayout)
	end
	pcall(function()
		UserInputService.LastInputTypeChanged:Connect(function()
			if Kit.isTouch() ~= touchLayout then
				applyLayout()
			end
		end)
	end)

	r.holder.Activated:Connect(function()
		local map = lazy("MapScreenController")
		if map and typeof(map.toggle) == "function" then
			map.toggle()
		end
	end)

	-- streamer mode
	HUDController.VisibilityChanged:Connect(function(isHidden: boolean)
		setHidden(isHidden == true)
	end)
	local okHidden, value = pcall(HUDController.isHidden)
	setHidden(okHidden and value == true)

	RunService.RenderStepped:Connect(function(dt: number)
		debug.profilebegin("HC_Minimap")
		update(dt)
		debug.profileend()
	end)
end

return MinimapController
