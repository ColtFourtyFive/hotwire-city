--!strict
-- MinimapController: GTA-V-style circular radar + GPS routing.
--
--  * Radar: the city map image (Config/Minimap tiles, tools/minimap/build.py) inside a circular CanvasGroup. The map
--    turns with the camera (Config/Minimap.RADAR.ROTATE: "camera" | "heading" | "north"), the player arrow sits in the
--    middle and points where the character / car faces, and the zoom eases out with speed while driving.
--  * Blips (upright, pooled ImageLabels on the blip atlas): own garage (sticks to the rim when off-radar), other
--    players' garages, Dealership, Gear Shop, Spray Shops, Chop Shop, Police HQ, landmarks (only when near), every
--    WaypointController waypoint (sticky, its own color + icon: Hot Drop flame, custom pin, ...), police cars (red /
--    blue flashing dots while the siren is on), the police chopper, other players (small dots).
--  * Wanted: the bezel flashes red / blue and a pulsing search circle marks where the cops last saw you.
--  * GPS: a route line along the roads (RoadGraph A*) to the active waypoint, picked by Config/Minimap.GPS.PRIORITY
--    (the player's own map waypoint first). Recomputed when the target changes / moves, or when the player strays
--    more than GPS.REROUTE_DISTANCE studs off it (throttled). The part already driven is trimmed every frame, and a
--    distance pill under the radar shows what's left. The custom map waypoint clears itself on arrival.
--  * Placement: desktop bottom-left (the HUD menu column wraps above it); touch top-left under the topbar (the HUD
--    buttons move right of it, the event feed goes below it; a compact radar on 16:9 phones) - clear of the
--    thumbstick zone and the driving buttons. Phones get bigger text + blips (touchBoost), not a bigger circle.
--    Hidden in streamer mode (settings.hideHud). Click / tap the radar (M, gamepad D-pad up) for the fullscreen map
--    (MapScreenController).
--  * Cost: one RenderStep update. Every frame: map position / rotation, arrow, N, route head and blip positions (so
--    nothing drifts against the turning map; unchanged values are not re-written). At RADAR.UPDATE_HZ: the waypoint
--    list and the wanted visuals; at GPS.SELECT_INTERVAL: target pick + routing. No Instance.new or table
--    allocation per frame (pools grow only when more blips than ever before are on screen).
--
-- Public API (beyond init/start):
--   getRoute(): ({ Vector3 }?, Color3?, Vector3?)   current GPS polyline (road points), its color and the real target
--   getGpsTarget(): (string?, Vector3?)            active GPS waypoint id + position
--   setCustomWaypoint(pos: Vector3?, label?)       place / clear the player's map waypoint (3D beam via Waypoints)
--   getCustomWaypoint(): Vector3?, getRemaining(): number (studs left on the route), getPolice() / getHelis(): { Model }
--   RouteChanged: Signal()                         fires when the polyline is recomputed or cleared
--   newRouteRenderer(parent, width, outline) / drawRoute(renderer, ...) / moveRouteHead(renderer, ...)   shared with
--                                                  MapScreenController (slot 1 is always the head segment)
-- Pure helpers (tests): worldToMap, mapToWorld, headingOf, rotate, radarOffset, radarToWorld, clampToCircle,
--   zoomFor, smooth, waypointIcon, routable, priorityOf, pickTarget, areaAt, poiPositions, wantedRadius,
--   segmentGeometry, flashOn, cellOf, touchBoost, touchDiameter, touchMetrics, northFade, retryDelay.

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
local ROUTE_DARK = Color3.fromRGB(10, 12, 24)
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

-- Touch readability factor for radar text and blips at UIScale `scale` (phones sit at the 0.55 floor): what
-- Theme.TouchMinScale would give them, capped at RADAR.TOUCH_BOOST_MAX; 1 on desktop / big screens.
function MinimapController.touchBoost(scale: number, touch: boolean): number
	if not touch or not (scale > 0) then
		return 1
	end
	return math.clamp(Theme.TouchMinScale / scale, 1, RADAR.TOUCH_BOOST_MAX)
end

-- Radar diameter on touch for a design canvas (inset-relative, design px): compact on 16:9 phones.
function MinimapController.touchDiameter(canvasW: number, canvasH: number): number
	if canvasW < RADAR.TOUCH_COMPACT_W and canvasH < RADAR.TOUCH_COMPACT_H then
		return RADAR.TOUCH_SIZE_COMPACT
	end
	return RADAR.TOUCH_SIZE
end

export type TouchMetrics = {
	diameter: number,
	boost: number,
	reserve: number, -- design px from the radar's left screen margin the HUD buttons stay clear of (left edge excluded)
	pillHeight: number, -- GPS distance pill (centered 2 px above the radar's bottom edge)
	areaGap: number, -- area name top, below the radar's bottom edge
	areaHeight: number,
	bottom: number, -- design px (inset-relative) where the radar block (radar + pill + area name) ends
}

-- Touch layout numbers for a canvas (design px) at UIScale `scale`: shared by applyLayout and the specs.
function MinimapController.touchMetrics(canvasW: number, canvasH: number, scale: number): TouchMetrics
	local d = MinimapController.touchDiameter(canvasW, canvasH)
	local b = MinimapController.touchBoost(scale, true)
	local pillH = math.ceil(24 * b)
	local areaGap = math.ceil(pillH / 2) + 2
	local areaH = math.ceil(RADAR.AREA_TEXT_TOUCH * b) + 6
	return {
		diameter = d,
		boost = b,
		reserve = d + RADAR.TOUCH_GAP,
		pillHeight = pillH,
		areaGap = areaGap,
		areaHeight = areaH,
		bottom = RADAR.TOUCH_TOP + d + areaGap + areaH,
	}
end

-- Transparency of the N marker for map rotation `rotDeg`: 0 normally, fading to 1 as it passes under the map button
-- on the rim (both travel the same circle; N sits at `rotDeg` clockwise from up).
function MinimapController.northFade(rotDeg: number): number
	local diff = math.abs((rotDeg - RADAR.MAP_BUTTON_ANGLE + 180) % 360 - 180)
	local t = 1 - math.clamp(diff / RADAR.NORTH_FADE_DEG, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Seconds to wait before searching again for a GPS target that failed `failures` times in a row (doubling).
function MinimapController.retryDelay(failures: number): number
	if failures <= 0 then
		return 0
	end
	return math.min(GPS.REROUTE_MIN_INTERVAL * 2 ^ (failures - 1), GPS.FAIL_RETRY_MAX)
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

-- Lay out segment i (a -> b in world XZ). alpha: 0 solid; the off-road tail fades a little. A segment shorter than
-- MIN_SEGMENT studs is hidden (a zero-length pill would draw a stray dot).
local MIN_SEGMENT = 0.05
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
	if len < MIN_SEGMENT then
		core.Visible = false
		out.Visible = false
		return
	end
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

-- Draw the route from (sx, sz) (the player's spot projected onto segment `first`): segment 1 is always the head,
-- (sx, sz) -> points[first + 1] (hidden while it has no length), then points[first + 1 .. n], then an optional faded
-- tail to the real target (tx, tz) when it is off the road. Slot 1 being the head is what lets the per-frame
-- moveHead touch only that segment. Hides leftovers. nil points clears.
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
		local head = points[math.clamp(first + 1, 2, #points)]
		n = 1
		setSegment(r, 1, sx, sz, head.X, head.Z, 0)
		local px, pz = head.X, head.Z
		for i = math.clamp(first + 2, 2, #points + 1), #points do
			local p = points[i]
			if math.abs(p.X - px) + math.abs(p.Z - pz) > MIN_SEGMENT then
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

-- Fast path (every frame): only move the head segment (slot 1, see drawRoute) to start at (sx, sz).
function MinimapController.moveRouteHead(r: RouteRenderer, sx: number, sz: number, bx: number, bz: number)
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
	x: { number },
	y: { number },
	z: { number },
	used: number,
	shown: number,
}

type Radar = {
	gui: ScreenGui,
	holder: TextButton,
	bezel: Frame,
	bezelStroke: UIStroke,
	glowRing: ImageLabel,
	clip: CanvasGroup,
	spin: Frame,
	world: Frame,
	route: RouteRenderer,
	wantedFill: ImageLabel,
	wantedRing: ImageLabel,
	blips: BlipPool,
	arrow: ImageLabel,
	north: Frame,
	northStroke: UIStroke,
	northLabel: TextLabel,
	area: TextLabel,
	areaFit: UITextSizeConstraint,
	dist: Frame,
	distDot: ImageLabel,
	distLabel: TextLabel,
	keyHint: Frame,
	keyLabel: TextLabel,
	keyPad: ImageLabel,
}

local radar: Radar? = nil
local hidden = false
local diameter = RADAR.DESKTOP_SIZE
local touchLayout = false
local padLayout = false
local boost = 1 -- touch readability boost for text + blips (MinimapController.touchBoost)
local blipBig = RADAR.BLIP_SIZE
local blipSmall = RADAR.BLIP_SIZE_SMALL
local northAlpha = 0

local zoom = RADAR.ZOOM_FOOT
local lastScale = -1
local lastWorldX, lastWorldY = math.huge, math.huge
local accum = 0
local slowAccum = math.huge
local clock = 0

-- GPS
local route: { Vector3 }? = nil
local routeTarget: Vector3? = nil -- the real target (may be off-road)
local routeTargetId: string? = nil
local routeColor = WHITE
local routeHead = 1 -- route segment the player is on (points[routeHead] -> points[routeHead + 1])
local lastRouteAt = -math.huge
local remaining = 0
-- unreachable GPS target: don't search again every slow tick (MinimapController.retryDelay)
local failId: string? = nil
local failTarget: Vector3? = nil
local failFrom: Vector3? = nil
local failAt = -math.huge
local failCount = 0
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

-- wanted
local lastSeenPos: Vector3? = nil

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
-- Blip pool
-------------------------------------------------------------------------------------------------------------------------

local function newPool(parent: Frame): BlipPool
	return { parent = parent, items = {}, icon = {}, color = {}, size = {}, x = {}, y = {}, z = {}, used = 0, shown = 0 }
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
		pool.x[i] = math.huge
		pool.y[i] = math.huge
		pool.z[i] = -1
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
	-- placed every frame: write only what moved (a still camera + still player costs nothing)
	if math.abs(pool.x[i] - x) > 0.02 or math.abs(pool.y[i] - y) > 0.02 then
		pool.x[i], pool.y[i] = x, y
		it.Position = UDim2.fromOffset(x, y)
	end
	if pool.z[i] ~= z then
		pool.z[i] = z
		it.ZIndex = z
	end
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

-------------------------------------------------------------------------------------------------------------------------
-- Build
-------------------------------------------------------------------------------------------------------------------------

local function atlasImage(name: string, props: { [string]: any }): ImageLabel
	local cell = CELLS[name]
	local img = Kit.new("ImageLabel", {
		BackgroundTransparency = 1,
		Image = ATLAS,
		ImageRectOffset = if cell then Vector2.new(cell[1], cell[2]) else Vector2.zero,
		ImageRectSize = if cell then Vector2.new(cell[3], cell[4]) else Vector2.zero,
	})
	for k, v in props do
		(img :: any)[k] = v
	end
	return img
end

-- Fallback when the map tiles are not uploaded yet: draw the road graph as plain frames (static, built once).
local function buildFallbackRoads(world: Frame)
	local g = RoadGraph.get()
	for _, e in g.edges do
		local a, b = g.nodes[e.a], g.nodes[e.b]
		local cu, cv, len, angle = MinimapController.segmentGeometry(a.X, a.Z, b.X, b.Z)
		Kit.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = Color3.fromRGB(120, 128, 156),
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
	local gui = Kit.screen("HC_Minimap", Theme.Layers.HUD)
	local holder = Kit.new("TextButton", {
		Name = "Radar",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.fromOffset(diameter, diameter),
		Parent = gui,
	})
	-- soft drop shadow
	atlasImage("_glow", {
		Name = "Shadow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 3, 0.5, 6),
		Size = UDim2.fromScale(1.3, 1.3),
		ImageColor3 = BLACK,
		ImageTransparency = 0.35,
		ZIndex = 0,
		Parent = holder,
	})
	-- wanted glow ring (behind the bezel)
	local glowRing = atlasImage("_ring", {
		Name = "WantedGlow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1.22, 1.22),
		ImageColor3 = WANTED.RED,
		Visible = false,
		ZIndex = 1,
		Parent = holder,
	})
	local bezel = Kit.new("Frame", {
		Name = "Bezel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Colors.Panel,
		ZIndex = 2,
		Parent = holder,
	})
	Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = bezel })
	Kit.gradient(Theme.Colors.PanelLight, Theme.Colors.Background, 90).Parent = bezel
	local bezelStroke = Kit.stroke(Theme.Colors.Stroke, 3)
	bezelStroke.Parent = bezel

	local inner = diameter - RADAR.BORDER * 2
	local clip = Kit.new("CanvasGroup", {
		Name = "Clip",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(inner, inner),
		BackgroundColor3 = MinimapConfig.WATER_COLOR,
		ZIndex = 3,
		Parent = holder,
	})
	Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = clip })
	local spin = Kit.new("Frame", {
		Name = "Spin",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
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
					BackgroundColor3 = MinimapConfig.LAND_COLOR,
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
	local wantedFill = atlasImage("_glow", {
		Name = "WantedArea",
		AnchorPoint = Vector2.new(0.5, 0.5),
		ImageColor3 = WANTED.RED,
		ImageTransparency = 0.45,
		Visible = false,
		ZIndex = 2,
		Parent = world,
	})
	local wantedRing = atlasImage("_ring", {
		Name = "WantedEdge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		ImageColor3 = WANTED.RED,
		Visible = false,
		ZIndex = 2,
		Parent = world,
	})
	local routeR = MinimapController.newRouteRenderer(world, GPS.WIDTH, GPS.OUTLINE)

	-- blips above the edge vignette: the sticky ones (your garage, the GPS target, the chopper) sit on the rim, where
	-- the vignette is darkest
	local blipLayer = Kit.new("Frame", {
		Name = "Blips",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 7,
		Parent = clip,
	})
	atlasImage("_vignette", {
		Name = "Vignette",
		Size = UDim2.fromScale(1, 1),
		ImageTransparency = 0.05,
		ZIndex = 6,
		Parent = clip,
	})
	-- inner highlight ring on top of the map
	local rim = Kit.new("Frame", {
		Name = "Rim",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(inner, inner),
		ZIndex = 4,
		Parent = holder,
	})
	Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = rim })
	Kit.new("UIStroke", {
		Color = WHITE,
		Transparency = 0.82,
		Thickness = 1.5,
		Parent = rim,
	})

	local arrow = atlasImage("_arrow", {
		Name = "Player",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(RADAR.PLAYER_ARROW, RADAR.PLAYER_ARROW),
		ZIndex = 7,
		Parent = holder,
	})

	local north = Kit.new("Frame", {
		Name = "North",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(22, 22),
		BackgroundColor3 = Theme.Colors.Background,
		ZIndex = 8,
		Parent = holder,
	})
	Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = north })
	local northStroke = Kit.stroke(Theme.Colors.TextDim, 1.5)
	northStroke.Parent = north
	local northLabel = Kit.label("N", 14, {
		Size = UDim2.fromScale(1, 1),
		TextWrapped = false,
		ZIndex = 9,
		Parent = north,
	})

	-- GPS distance pill (overlaps the bottom of the bezel)
	local dist = Kit.new("Frame", {
		Name = "Distance",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 1, -2),
		Size = UDim2.fromOffset(92, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Theme.Colors.Background,
		Visible = false,
		ZIndex = 8,
		Parent = holder,
	})
	Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = dist })
	local distStroke = Kit.stroke(Theme.Colors.Stroke, 2)
	distStroke.Parent = dist
	Kit.new("UIPadding", {
		PaddingLeft = UDim.new(0, 6),
		PaddingRight = UDim.new(0, 10),
		Parent = dist,
	})
	Kit.list(Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center).Parent =
		dist
	local distDot = atlasImage("pin", {
		Name = "Icon",
		Size = UDim2.fromOffset(18, 18),
		LayoutOrder = 1,
		ZIndex = 9,
		Parent = dist,
	})
	local distLabel = Kit.label("0m", 16, {
		Name = "Text",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 22),
		TextWrapped = false,
		LayoutOrder = 2,
		ZIndex = 9,
		Parent = dist,
	})

	local area = Kit.label("", RADAR.AREA_TEXT, {
		Name = "Area",
		FontFace = Theme.Fonts.BodyHeavy,
		TextColor3 = Theme.Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = false,
		Size = UDim2.fromOffset(220, 20),
		ZIndex = 8,
		Parent = holder,
	})
	-- touch: the name is scaled down to fit under the radar (never into the HUD buttons right of it)
	local areaFit = Kit.new("UITextSizeConstraint", {
		MaxTextSize = RADAR.AREA_TEXT,
		MinTextSize = 8,
		Parent = area,
	})

	-- "M" key cap (desktop) / map glyph (touch) on the top-right rim: the radar is the map button
	local keyHint = Kit.new("Frame", {
		Name = "MapHint",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, math.floor(diameter * 0.354), 0.5, -math.floor(diameter * 0.354)),
		Size = UDim2.fromOffset(24, 24),
		BackgroundColor3 = Theme.Colors.PanelLight,
		ZIndex = 8,
		Parent = holder,
	})
	Kit.new("UICorner", { CornerRadius = UDim.new(0, 6), Parent = keyHint })
	Kit.stroke(Theme.Colors.Stroke, 2).Parent = keyHint
	local keyLabel = Kit.label("M", 14, {
		Name = "Key",
		Size = UDim2.fromScale(1, 1),
		TextWrapped = false,
		ZIndex = 9,
		Parent = keyHint,
	})
	-- gamepad: the engine's own glyph for the map button (MinimapConfig.MAP.PAD_KEY)
	local keyPad = Kit.new("ImageLabel", {
		Name = "Pad",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.9, 0.9),
		Visible = false,
		ZIndex = 9,
		Parent = keyHint,
	})

	return {
		gui = gui,
		holder = holder,
		bezel = bezel,
		bezelStroke = bezelStroke,
		glowRing = glowRing,
		clip = clip,
		spin = spin,
		world = world,
		route = routeR,
		wantedFill = wantedFill,
		wantedRing = wantedRing,
		blips = newPool(blipLayer),
		arrow = arrow,
		north = north,
		northStroke = northStroke,
		northLabel = northLabel,
		area = area,
		areaFit = areaFit,
		dist = dist,
		distDot = distDot,
		distLabel = distLabel,
		keyHint = keyHint,
		keyLabel = keyLabel,
		keyPad = keyPad,
	}
end

local function isGamepad(): boolean
	local ok, last = pcall(function()
		return UserInputService:GetLastInputType()
	end)
	if not ok or typeof(last) ~= "EnumItem" then
		return false
	end
	return string.sub(last.Name, 1, 7) == "Gamepad"
end

-- Design canvas (inset-relative) of the radar's ScreenGui at UIScale `scale` (1280x720 when nothing is measurable,
-- e.g. headless).
local function canvasSize(gui: ScreenGui, scale: number): (number, number)
	local ok, abs = pcall(function(): Vector2
		local a = gui.AbsoluteSize
		if a.X >= 1 and a.Y >= 1 then
			return a
		end
		local cam = Workspace.CurrentCamera
		return if cam then cam.ViewportSize else Vector2.zero
	end)
	if ok and abs.X >= 1 and abs.Y >= 1 then
		return abs.X / scale, abs.Y / scale
	end
	return 1280, 720
end

-- Placement per input type; tells the HUD which corner the radar takes.
local function applyLayout()
	local r = radar
	if not r then
		return
	end
	touchLayout = Kit.isTouch()
	padLayout = not touchLayout and isGamepad()
	local okScale, measured = pcall(Kit.uiScale)
	local scale = if okScale and typeof(measured) == "number" and measured > 0 then measured else 1
	local cw, ch = canvasSize(r.gui, scale)
	local metrics = MinimapController.touchMetrics(cw, ch, scale)
	diameter = if touchLayout then metrics.diameter else RADAR.DESKTOP_SIZE
	boost = MinimapController.touchBoost(scale, touchLayout)
	blipBig = math.floor(RADAR.BLIP_SIZE * boost + 0.5)
	blipSmall = math.floor(RADAR.BLIP_SIZE_SMALL * boost + 0.5)

	local inner = diameter - RADAR.BORDER * 2
	r.holder.Size = UDim2.fromOffset(diameter, diameter)
	r.clip.Size = UDim2.fromOffset(inner, inner)
	local rim = r.holder:FindFirstChild("Rim")
	if rim and rim:IsA("GuiObject") then
		rim.Size = UDim2.fromOffset(inner, inner)
	end
	local arrow = math.floor(RADAR.PLAYER_ARROW * math.min(boost, 1.2) + 0.5)
	r.arrow.Size = UDim2.fromOffset(arrow, arrow)
	-- N marker + map button (both on the rim; N fades while it passes under the button: northFade)
	local northSize = math.floor(22 * boost + 0.5)
	r.north.Size = UDim2.fromOffset(northSize, northSize)
	r.northLabel.TextSize = math.floor(14 * boost + 0.5)
	local keySize = math.floor(24 * boost + 0.5)
	local kx, ky = MinimapController.rotate(0, -diameter / 2, RADAR.MAP_BUTTON_ANGLE)
	r.keyHint.Size = UDim2.fromOffset(keySize, keySize)
	r.keyHint.Position = UDim2.new(0.5, math.floor(kx), 0.5, math.floor(ky))
	r.keyLabel.TextSize = math.floor(14 * boost + 0.5)
	r.keyLabel.Text = if touchLayout then "🗺" else "M"
	local padImage = ""
	if padLayout then
		local ok, img = pcall(function()
			return UserInputService:GetImageForKeyCode(MinimapConfig.MAP.PAD_KEY)
		end)
		padImage = if ok and typeof(img) == "string" then img else ""
	end
	r.keyPad.Image = padImage
	r.keyPad.Visible = padImage ~= ""
	r.keyLabel.Visible = padImage == ""

	-- GPS distance pill + area name
	local distText = if touchLayout then RADAR.DIST_TEXT_TOUCH else RADAR.DIST_TEXT
	local pillH = if touchLayout then metrics.pillHeight else 24
	r.dist.Size = UDim2.fromOffset(92, pillH)
	r.distDot.Size = UDim2.fromOffset(math.floor(18 * boost + 0.5), math.floor(18 * boost + 0.5))
	r.distLabel.TextSize = math.floor(distText * boost + 0.5)
	r.distLabel.Size = UDim2.fromOffset(0, pillH - 2)

	if touchLayout then
		r.holder.AnchorPoint = Vector2.new(0, 0)
		r.holder.Position = UDim2.fromOffset(12, RADAR.TOUCH_TOP)
		-- area name under the radar + distance pill (still inside the top third: above the thumbstick zone), scaled
		-- down to the radar's width so it never runs into the HUD buttons right of it
		local areaSize = math.floor(RADAR.AREA_TEXT_TOUCH * boost + 0.5)
		r.area.AnchorPoint = Vector2.new(0.5, 0)
		r.area.Position = UDim2.new(0.5, 0, 1, metrics.areaGap)
		r.area.Size = UDim2.fromOffset(diameter + RADAR.TOUCH_GAP, metrics.areaHeight)
		r.area.TextSize = areaSize
		r.area.TextScaled = true
		r.areaFit.MaxTextSize = areaSize
		r.area.TextXAlignment = Enum.TextXAlignment.Center
		pcall(HUDController.setMinimapReserve, metrics.reserve, 0, metrics.bottom)
	else
		r.holder.AnchorPoint = Vector2.new(0, 1)
		r.holder.Position = UDim2.new(0, RADAR.MARGIN, 1, -(RADAR.MARGIN + RADAR.PILL_ROOM))
		-- area name to the right of the radar, bottom-aligned (GTA V's street-name spot)
		r.area.AnchorPoint = Vector2.new(0, 1)
		r.area.Position = UDim2.new(1, 12, 1, -4)
		r.area.Size = UDim2.fromOffset(220, RADAR.AREA_TEXT + 5)
		r.area.TextSize = RADAR.AREA_TEXT
		r.area.TextScaled = false
		r.areaFit.MaxTextSize = RADAR.AREA_TEXT
		r.area.TextXAlignment = Enum.TextXAlignment.Left
		pcall(HUDController.setMinimapReserve, 0, diameter + RADAR.MARGIN + RADAR.PILL_ROOM + RADAR.TOP_CLEARANCE, 0)
	end
	lastScale = -1
	northAlpha = -1
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
				table.insert(pois, { pos = pos, icon = def.icon, color = def.color, range = def.radarRange })
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
		-- remember the miss: slowTick waits retryDelay(failCount) before searching for this target again (the count
		-- restarts when the target or the player has moved somewhere new since the last miss)
		local ft, ff = failTarget, failFrom
		local same = failId == id
			and ft ~= nil
			and ff ~= nil
			and Vector3.new(ft.X - target.X, 0, ft.Z - target.Z).Magnitude <= GPS.TARGET_MOVED
			and Vector3.new(ff.X - pos.X, 0, ff.Z - pos.Z).Magnitude <= GPS.REROUTE_DISTANCE
		failCount = if same then failCount + 1 else 1
		failId, failTarget, failFrom, failAt = id, target, pos, clock
		return
	end
	failId, failTarget, failFrom, failCount = nil, nil, nil, 0
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
		local ft, ff = failTarget, failFrom
		if id == failId and ft and ff then
			-- the last search for this target found no road path (one-way trap, disconnected level): retry only after
			-- a growing wait, or sooner once the target or the player has moved somewhere new
			local moved = Vector3.new(ft.X - target.X, 0, ft.Z - target.Z).Magnitude > GPS.TARGET_MOVED
				or Vector3.new(ff.X - pos.X, 0, ff.Z - pos.Z).Magnitude > GPS.REROUTE_DISTANCE
			local waited = clock - failAt
			need = waited >= MinimapController.retryDelay(failCount) or (moved and waited >= GPS.REROUTE_MIN_INTERVAL)
		end
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
	-- 30 Hz work (waypoint list, wanted visuals). Subtracting (not zeroing) keeps an even cadence under frame-time
	-- jitter; the cap stops a hitch from queueing a burst.
	local tick = accum >= UPDATE_DT
	if tick then
		accum = math.min(accum - UPDATE_DT, UPDATE_DT)
	end

	local rootCf = root.CFrame
	local pos = rootCf.Position
	local slow = slowAccum >= SLOW_DT
	if tick or slow then
		collectWaypoints()
	end
	if slow then
		slowAccum = 0
		slowTick(pos)
		if math.floor(clock) ~= math.floor(clock - SLOW_DT) then
			refreshOwners()
			r.area.Text = MinimapController.areaAt(pos)
		end
	end
	if hidden then
		return -- streamer mode: GPS bookkeeping (routes, arrival) keeps running, nothing is drawn
	end

	-- Every frame from here: the map, the arrow, N, the route head and the blips all move together with the camera
	-- (~6 property sets for the map + one Position per visible blip).
	local vel = root.AssemblyLinearVelocity
	local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	local driving = player:GetAttribute("Driving") == true
	zoom = MinimapController.smooth(zoom, MinimapController.zoomFor(driving, speed), dt, RADAR.ZOOM_RESPONSE)
	local radius = (diameter - RADAR.BORDER * 2) / 2
	local scale = radius / zoom
	local rot = radarRotation(rootCf)

	-- map container
	if math.abs(scale - lastScale) > 1e-4 then
		lastScale = scale
		r.world.Size = UDim2.fromOffset(WORLD_SIZE * scale, WORLD_SIZE * scale)
	end
	local u, v = MinimapController.worldToMap(pos.X, pos.Z)
	local wx, wy = radius - u * scale, radius - v * scale
	if math.abs(wx - lastWorldX) > 0.01 or math.abs(wy - lastWorldY) > 0.01 then
		lastWorldX, lastWorldY = wx, wy
		r.world.Position = UDim2.fromOffset(wx, wy)
	end
	r.spin.Rotation = rot
	r.arrow.Rotation = headingDeg(rootCf) + rot
	local nx, ny = MinimapController.rotate(0, -(diameter / 2 - 3), rot)
	r.north.Position = UDim2.new(0.5, nx, 0.5, ny)
	local fade = MinimapController.northFade(rot)
	if math.abs(fade - northAlpha) > 0.01 then
		northAlpha = fade
		r.north.BackgroundTransparency = fade
		r.northStroke.Transparency = fade
		r.northLabel.TextTransparency = fade
		local labelStroke = r.northLabel:FindFirstChildOfClass("UIStroke")
		if labelStroke then
			labelStroke.Transparency = fade
		end
	end

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
		elseif head + 1 <= #pts then
			local a, b = pts[head], pts[head + 1]
			local dx, dz = b.X - a.X, b.Z - a.Z
			local len2 = dx * dx + dz * dz
			local t = if len2 > 1e-9 then math.clamp(((pos.X - a.X) * dx + (pos.Z - a.Z) * dz) / len2, 0, 1) else 0
			MinimapController.moveRouteHead(r.route, a.X + dx * t, a.Z + dz * t, b.X, b.Z)
		end
	end

	-- wanted (30 Hz: the search area lives in the map frame, so it already moves with it every frame)
	local flashRed = MinimapController.flashOn(clock, RADAR.WANTED_FLASH_HZ)
	if tick then
		local stars = wantedStars()
		if stars >= 1 then
			if player:GetAttribute("WantedSeen") == true or lastSeenPos == nil then
				lastSeenPos = pos
			end
			local seen = lastSeenPos :: Vector3
			local radiusStuds = MinimapController.wantedRadius(stars)
			local cu, cv = MinimapController.worldToMap(seen.X, seen.Z)
			local size = UDim2.fromScale(radiusStuds * 2 / WORLD_SIZE, radiusStuds * 2 / WORLD_SIZE)
			local p = UDim2.fromScale(cu / WORLD_SIZE, cv / WORLD_SIZE)
			local c = if flashRed then WANTED.RED else WANTED.BLUE
			r.wantedFill.Position = p
			r.wantedFill.Size = size
			r.wantedFill.ImageColor3 = c
			r.wantedFill.ImageTransparency = 0.55 + 0.15 * math.sin(clock * 6)
			r.wantedFill.Visible = true
			r.wantedRing.Position = p
			r.wantedRing.Size = size
			r.wantedRing.ImageColor3 = c
			r.wantedRing.Visible = true
			r.bezelStroke.Color = c
			r.bezelStroke.Thickness = 4
			r.glowRing.ImageColor3 = c
			r.glowRing.Visible = true
		elseif r.wantedFill.Visible then
			lastSeenPos = nil
			r.wantedFill.Visible = false
			r.wantedRing.Visible = false
			r.bezelStroke.Color = Theme.Colors.Stroke
			r.bezelStroke.Thickness = 3
			r.glowRing.Visible = false
		end
	end

	-- blips (every frame, so they stay glued to the map while it turns) -----------------------------------------------
	local pool = r.blips
	poolBegin(pool)
	local big = blipBig
	local small = blipSmall
	local edge = radius - math.max(RADAR.EDGE_INSET, big / 2 + 2)
	local view = zoom * 1.05
	local view2 = view * view
	local rr = math.rad(rot)
	local cs, sn = math.cos(rr) * scale, math.sin(rr) * scale
	local px0, pz0 = pos.X, pos.Z

	-- other players (lowest)
	local playerBlip = MinimapConfig.BLIPS.player
	for _, other in otherRoots do
		if other.Parent then
			local p = other.Position
			local dx, dz = p.X - px0, p.Z - pz0
			if dx * dx + dz * dz < view2 then
				poolPut(
					pool,
					playerBlip.icon,
					playerBlip.color,
					small,
					radius + dx * cs - dz * sn,
					radius + dx * sn + dz * cs,
					1
				)
			end
		end
	end
	-- landmarks / shops
	for _, poi in pois do
		local dx, dz = poi.pos.X - px0, poi.pos.Z - pz0
		local d2 = dx * dx + dz * dz
		local range = poi.range
		if d2 < view2 and (range == nil or d2 < range * range) then
			poolPut(pool, poi.icon, poi.color, big, radius + dx * cs - dz * sn, radius + dx * sn + dz * cs, 2)
		end
	end
	-- garages (own garage sticks to the rim)
	local me = player.UserId
	local own = MinimapConfig.BLIPS.ownGarage
	local other = MinimapConfig.BLIPS.otherGarage
	for _, g in garages do
		local mine = g.owner == me and me ~= 0
		if mine or g.owner ~= 0 then
			local dx, dz = g.pos.X - px0, g.pos.Z - pz0
			local x, y = dx * cs - dz * sn, dx * sn + dz * cs
			if mine then
				x, y = MinimapController.clampToCircle(x, y, edge)
				poolPut(pool, own.icon, own.color, big + 2, radius + x, radius + y, 4)
			elseif x * x + y * y < edge * edge then
				poolPut(pool, other.icon, other.color, big - 4, radius + x, radius + y, 2)
			end
		end
	end
	-- police cars + chopper (flash red / blue while the siren is on)
	local pol = MinimapConfig.BLIPS.police
	for i, model in police do
		local pp = model.PrimaryPart
		if pp then
			local p = pp.Position
			local dx, dz = p.X - px0, p.Z - pz0
			if dx * dx + dz * dz < view2 then
				local siren = model:GetAttribute("Siren") == true
				local c = if siren and MinimapController.flashOn(clock, RADAR.WANTED_FLASH_HZ, i)
					then pol.red
					else pol.blue
				poolPut(pool, pol.icon, c, small + 2, radius + dx * cs - dz * sn, radius + dx * sn + dz * cs, 3)
			end
		end
	end
	local heli = MinimapConfig.BLIPS.heli
	for _, model in helis do
		local pp = model.PrimaryPart
		if pp then
			local p = pp.Position
			local dx, dz = p.X - px0, p.Z - pz0
			local x, y = MinimapController.clampToCircle(dx * cs - dz * sn, dx * sn + dz * cs, edge)
			poolPut(pool, heli.icon, if flashRed then heli.color else pol.blue, big, radius + x, radius + y, 3)
		end
	end
	-- waypoints (sticky, on top); the GPS target bobs a little
	for i = 1, candidateCount do
		local c = candidates[i]
		local dx, dz = c.pos.X - px0, c.pos.Z - pz0
		local x, y = MinimapController.clampToCircle(dx * cs - dz * sn, dx * sn + dz * cs, edge)
		local size = big + 2
		if c.id == gpsId then
			size += math.floor((2 + 2 * math.sin(clock * 5)) * boost)
		end
		poolPut(pool, MinimapController.waypointIcon(c.id), c.color, size, radius + x, radius + y, 5)
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
		WaypointController.set(CUSTOM.ID, pos, CUSTOM.COLOR, label or CUSTOM.LABEL)
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

-- Police choppers currently tracked (CollectionService tag "PoliceHeli"); read-only.
function MinimapController.getHelis(): { Model }
	return helis
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

	local cam = Workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(applyLayout)
	end
	-- the canvas (inset-relative) settles after the first layout pass and when the topbar inset changes
	r.gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyLayout)
	pcall(function()
		UserInputService.LastInputTypeChanged:Connect(function()
			if Kit.isTouch() ~= touchLayout or (not touchLayout and isGamepad() ~= padLayout) then
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
