--!strict
-- WaypointController (SPEC §7; v2: gta_ui_language §5.3/§9): GTA-style guidance to points of interest.
--
-- The route itself is the minimap GPS (MinimapController draws it and edge-clamps the blip); in the world each
-- waypoint shows only what GTA shows:
--   * destinations (a fixed position): a translucent CORONA (two stacked cylinders, the upper one fainter, in the
--     waypoint colour) on the ground, drawn within CORONA_RANGE studs,
--   * a CHEVRON (UIAssets hud.chevron) floating over the spot or over a tracked car / NPC, with a small condensed
--     label and the live distance ("245m", 3 studs = 1 meter). Sized with the screen UI scale (touch floor included).
-- No beams, light pillars, emoji pins or screen-edge arrows any more.
-- Colours (hudcolor.dat): Yellow = objective / your garage, Blue = a car to take, Red = your stolen car, Waypoint
-- purple = the player's map pin, Gold = Hot Drop, white = shops (Spray).
-- Streamer mode (HUDController.VisibilityChanged) hides chevrons and coronas.
--
-- Public API:
--   set(id, position: Vector3?, color: Color3?, label: string?)   nil position clears. `Waypoint` remote does the same.
--   track(id, target: Instance | () -> Vector3?, color?, label?)   moving target (Model/BasePart/Attachment or getter).
--   clear(id), clearAll(), has(id), getPosition(id)
--   each(fn(id, position, color, label))                           every shown waypoint (minimap / map blips + GPS)
--   step(dt)                                                        one frame by hand (headless tests)
-- Auto waypoints:
--   "home"    own plot drop-off (MapLayout.plotDropoffZone(PlotIndex)) while the local player drives a car whose model
--             Kind is "Loot" or "Stolen"; cleared when not driving (only if this controller created it).
--   "hotdrop" Hot Drop location while StateController's HotDropState is active.
--   "spray"   nearest Spray Shop (MapLayout.sprayZones) with its price while the player is wanted (Wanted > 0).
-- Auto waypoints hide themselves when a server/other waypoint already marks (almost) the same spot.
-- Pure helpers (tests): formatDistance, iconFor (UIAssets glyph key), edgeArrow (kept for the map screen's edge maths),
--   hotDropVisible, isNearAny, sprayCost, nearestIndex, markerStyle.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Config = Shared:WaitForChild("Config")
local Cars = require(Config:WaitForChild("Cars"))
local Economy = require(Config:WaitForChild("Economy"))
local Util = Shared:WaitForChild("Util")
local Format = require(Util:WaitForChild("Format"))
local MapLayout = require(Util:WaitForChild("MapLayout"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))

-- Earlier in the client ORDER: safe to require directly.
local StateController = require(script.Parent:WaitForChild("StateController"))

local WaypointController = {}

local player = Players.LocalPlayer
local C = Theme.Colors

WaypointController.STUDS_PER_METER = 3

local HOME_ID = "home"
local HOTDROP_ID = "hotdrop"
local SPRAY_ID = "spray"
local DELIVERABLE_KINDS: { [string]: boolean } = { Loot = true, Stolen = true }
local DUPLICATE_RADIUS = 30 -- an auto waypoint hides if another waypoint is this close to it
local AUTO_TICK = 0.25
local DIST_TICK = 0.1
local CORONA_RANGE = 450 -- studs: coronas are only drawn this close (GTA draw distance)
local CORONA_DIAMETER = 9
local CORONA_LOW = 1.6 -- height of the brighter lower ring
local CORONA_HIGH = 4.5 -- height of the faint upper ring
local CORONA_ALPHA_LOW = 0.55
local CORONA_ALPHA_HIGH = 0.82
local CHEVRON_HEIGHT = 7 -- studs over a destination
local CHEVRON_HEIGHT_TRACKED = 6 -- studs over a tracked model's pivot
local CHEVRON_HIDE_NEAR = 10 -- studs: the chevron fades away once you are standing in the corona
local MARKER_W = 140 -- billboard design px
local MARKER_H = 74

type Getter = () -> Vector3?

type Waypoint = {
	id: string,
	position: Vector3?,
	getter: Getter?,
	instance: Instance?,
	color: Color3,
	label: string,
	icon: string,
	auto: boolean,
	suppressed: boolean,
	part: Part, -- invisible anchor the billboard hangs from
	corona: Model,
	ringLow: Part,
	ringHigh: Part,
	billboard: BillboardGui,
	markerScale: UIScale,
	chevron: ImageLabel,
	nameLabel: TextLabel,
	distLabel: TextLabel,
	lastDistText: string,
	bob: Tween,
	shown: boolean?,
	coronaOn: boolean?,
}

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests)
-------------------------------------------------------------------------------------------------------------------------

-- 735 studs -> "245m", 3600 studs -> "1.2km"
function WaypointController.formatDistance(studs: number): string
	if studs ~= studs or studs < 0 then
		studs = 0
	end
	local meters = studs / WaypointController.STUDS_PER_METER
	if meters >= 999.5 then
		return string.format("%.1fkm", meters / 1000)
	end
	return string.format("%dm", math.floor(meters + 0.5))
end

-- UIAssets glyph key ("sheet.cell") for a waypoint id/label (pause-map legend, phone, feed).
function WaypointController.iconFor(id: string, label: string?): string
	local key = string.lower(id .. " " .. (label or ""))
	if key:find("home", 1, true) or key:find("garage", 1, true) or key:find("drop off", 1, true) then
		return "apps.garage"
	elseif key:find("hotdrop", 1, true) or key:find("hot drop", 1, true) then
		return "hud.car"
	elseif key:find("stolen", 1, true) or key:find("thief", 1, true) or key:find("theft", 1, true) then
		return "hud.cctv"
	elseif key:find("dealer", 1, true) then
		return "apps.store"
	elseif key:find("chop", 1, true) or key:find("spray", 1, true) then
		return "hud.wrench"
	elseif key:find("shop", 1, true) or key:find("gear", 1, true) then
		return "apps.store"
	elseif key:find("cash", 1, true) then
		return "hud.cash"
	elseif key:find("tutorial", 1, true) or key:find("car", 1, true) then
		return "hud.car"
	end
	return "hud.pin"
end

export type MarkerStyle = { corona: boolean, chevron: boolean, chevronHeight: number }

-- What a waypoint draws: a fixed destination gets a corona + chevron; a tracked Instance (a car, a thief) only a
-- chevron over it. Close to a destination the chevron goes (you are standing in the corona).
-- Tuple form for the per-frame loop (no table per waypoint per frame): (corona, chevron, chevronHeight).
function WaypointController.markerFlags(tracked: boolean, distance: number): (boolean, boolean, number)
	local d = if distance == distance then distance else math.huge
	return not tracked and d <= CORONA_RANGE,
		tracked or d > CHEVRON_HIDE_NEAR,
		if tracked then CHEVRON_HEIGHT_TRACKED else CHEVRON_HEIGHT
end

function WaypointController.markerStyle(tracked: boolean, distance: number): MarkerStyle
	local corona, chevron, chevronHeight = WaypointController.markerFlags(tracked, distance)
	return { corona = corona, chevron = chevron, chevronHeight = chevronHeight }
end

--[[
	Screen-edge arrow math.
	screen: Camera:WorldToViewportPoint result (X, Y in pixels; Z = depth, negative when behind the camera).
	viewport: viewport size in pixels.
	margin: pixels kept from the screen edges — a number (all sides; topMargin overrides the top) or a table
	{ left, top, right, bottom } (e.g. a wider left inset to clear the HUD side menu).
	camRel (optional, preferred): the target in camera space (Camera.CFrame:PointToObjectSpace). Its (X, -Y) is the
	exact on-screen direction for points in front AND behind, without the projection singularity for points near
	the camera plane (e.g. a target directly beside you). Without it, the projected point is used and mirrored when
	behind the camera.
	Returns (onScreen, position: Vector2, rotationDegrees). rotation is GUI Rotation (clockwise, 0 = pointing up).
]]
export type Insets = { left: number, top: number, right: number, bottom: number }

function WaypointController.edgeArrow(
	screen: Vector3,
	viewport: Vector2,
	margin: number | Insets,
	topMargin: number?,
	camRel: Vector3?
): (boolean, Vector2, number)
	local w, h = viewport.X, viewport.Y
	local inFront = screen.Z > 0
	if inFront and screen.X >= 0 and screen.X <= w and screen.Y >= 0 and screen.Y <= h then
		return true, Vector2.new(screen.X, screen.Y), 0
	end
	local cx, cy = w / 2, h / 2
	local dx, dy
	if camRel then
		dx, dy = camRel.X, -camRel.Y
	else
		dx, dy = screen.X - cx, screen.Y - cy
		if not inFront then
			dx, dy = -dx, -dy
		end
	end
	local len = math.sqrt(dx * dx + dy * dy)
	if len ~= len or len < 1e-4 or len == math.huge then
		-- directly behind (or degenerate): point straight down
		dx, dy = 0, 1
	else
		dx, dy = dx / len, dy / len
	end
	local minX, maxX, minY, maxY
	if typeof(margin) == "table" then
		minX, maxX = margin.left, w - margin.right
		minY, maxY = margin.top, h - margin.bottom
	else
		minX, maxX = margin, w - margin
		minY, maxY = topMargin or margin, h - margin
	end
	-- degenerate (tiny viewport): collapse onto the center instead of producing inverted bounds
	if minX > maxX then
		minX, maxX = cx, cx
	end
	if minY > maxY then
		minY, maxY = cy, cy
	end
	local t = math.huge
	if dx > 1e-6 then
		t = math.min(t, (maxX - cx) / dx)
	elseif dx < -1e-6 then
		t = math.min(t, (minX - cx) / dx)
	end
	if dy > 1e-6 then
		t = math.min(t, (maxY - cy) / dy)
	elseif dy < -1e-6 then
		t = math.min(t, (minY - cy) / dy)
	end
	if t == math.huge or t < 0 then
		t = 0
	end
	local pos = Vector2.new(cx + dx * t, cy + dy * t)
	local angle = math.deg(math.atan2(dx, -dy))
	return false, pos, angle
end

-- Should the Hot Drop be marked? Server sends {active=false, startsAt, position} during the countdown and
-- {active=true, position, endsAt} once it lands. Same phases as EventsClient.hotDropPhase (server-time based):
-- pending/live -> true; nothing, or a stale state (missed landing / missed expiry) -> false.
function WaypointController.hotDropVisible(state: any, now: number): boolean
	if typeof(state) ~= "table" or typeof(state.position) ~= "Vector3" then
		return false
	end
	if state.active == true then
		return not (typeof(state.endsAt) == "number" and state.endsAt < now - 2)
	end
	if typeof(state.startsAt) == "number" then
		return state.startsAt >= now - 15
	end
	return false
end

-- Is `pos` within radius of any position in `others`?
function WaypointController.isNearAny(pos: Vector3, others: { Vector3 }, radius: number): boolean
	for _, o in others do
		if (o - pos).Magnitude <= radius then
			return true
		end
	end
	return false
end

-- Spray Shop price for `stars` (same rule as WantedService: per star, the larger of the flat minimum and
-- SPRAY_INCOME_SECONDS of income).
function WaypointController.sprayCost(stars: number, incomePerSec: number?): number
	local income = if typeof(incomePerSec) == "number"
			and incomePerSec == incomePerSec
			and incomePerSec > 0
		then incomePerSec
		else 0
	local perStar = math.max(Economy.SPRAY_COST_PER_STAR, income * (Economy.SPRAY_INCOME_SECONDS or 0))
	return math.floor(math.floor(math.max(0, stars)) * perStar)
end

-- Index of the position in `targets` closest to `from` (nil for an empty list).
function WaypointController.nearestIndex(targets: { Vector3 }, from: Vector3): number?
	local best, bestDist = nil, math.huge
	for i, p in targets do
		local d = (p - from).Magnitude
		if d < bestDist then
			best, bestDist = i, d
		end
	end
	return best
end

-------------------------------------------------------------------------------------------------------------------------
-- State + containers
-------------------------------------------------------------------------------------------------------------------------

local waypoints: { [string]: Waypoint } = {}
local worldFolder: Folder? = nil
local originAttachment: Attachment? = nil
local uiScale = 1
local hudHidden = false -- streamer mode

local function getWorldFolder(): Folder
	local f = worldFolder
	if f and f.Parent then
		return f
	end
	local existing = Workspace:FindFirstChild("HC_Waypoints")
	if existing and existing:IsA("Folder") then
		worldFolder = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "HC_Waypoints"
	folder.Parent = Workspace
	worldFolder = folder
	return folder
end

-- Kit.screen's scale with the touch floor: markers stay readable on phones without dwarfing the screen.
local function computeUiScale(): number
	return Kit.uiScale(Theme.TouchMinScale)
end

-------------------------------------------------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------------------------------------------------

local function ring(name: string, color: Color3, height: number, alpha: number, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Cylinder -- the cylinder axis is X; placeCorona stands it up
	p.Size = Vector3.new(height, CORONA_DIAMETER, CORONA_DIAMETER)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Transparency = alpha
	p.Locked = true
	p.Parent = parent
	return p
end

local function buildWaypoint(id: string, color: Color3, label: string): Waypoint
	local icon = WaypointController.iconFor(id, label)

	-- invisible anchored target the chevron billboard hangs from
	local part = Instance.new("Part")
	part.Name = "Waypoint_" .. id
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(1, 1, 1)
	part.CFrame = CFrame.new(0, -10000, 0)

	local corona = Instance.new("Model")
	corona.Name = "Corona"
	local ringLow = ring("Low", color, CORONA_LOW, CORONA_ALPHA_LOW, corona)
	local ringHigh = ring("High", color, CORONA_HIGH, CORONA_ALPHA_HIGH, corona)
	corona.Parent = part

	-- billboard pixels are raw screen pixels: the design-size root is scaled to the screen UI scale (update())
	local billboard = Kit.new("BillboardGui", {
		Name = "Marker",
		Size = UDim2.fromOffset(math.floor(MARKER_W * uiScale), math.floor(MARKER_H * uiScale)),
		StudsOffsetWorldSpace = Vector3.new(0, CHEVRON_HEIGHT, 0),
		AlwaysOnTop = true,
		LightInfluence = 0,
		ResetOnSpawn = false,
		ClipsDescendants = false,
		Enabled = not hudHidden,
		Parent = part,
	})
	local root = Kit.new("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(MARKER_W, MARKER_H),
		Parent = billboard,
	})
	local markerScale = Kit.new("UIScale", { Scale = uiScale, Parent = root })
	local nameLabel = Kit.text(string.upper(label), "condensed", 15, {
		Name = "Label",
		Size = UDim2.new(1, 0, 0, 18),
		TextColor3 = C.Text,
		TextStrokeColor3 = C.Black,
		TextStrokeTransparency = 0.35,
		Parent = root,
	})
	local distLabel = Kit.text("", "body", 13, {
		Name = "Distance",
		Position = UDim2.fromOffset(0, 17),
		Size = UDim2.new(1, 0, 0, 16),
		TextColor3 = C.Text,
		TextStrokeColor3 = C.Black,
		TextStrokeTransparency = 0.35,
		Parent = root,
	})
	local chevron = Kit.image("hud.chevron", {
		Name = "Chevron",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 36),
		Size = UDim2.fromOffset(30, 30),
		ImageColor3 = color,
		Parent = root,
	})
	-- a soft drop shadow so a yellow chevron still reads against a bright sky
	Kit.image("hud.chevron", {
		Name = "Shadow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 1, 0.5, 2),
		Size = UDim2.fromScale(1.12, 1.12),
		ImageColor3 = C.Black,
		ImageTransparency = 0.55,
		ZIndex = 0,
		Parent = chevron,
	})

	part.Parent = getWorldFolder()

	-- the looping bob only runs while the chevron is on screen (setVisible pauses it)
	local bob = TweenService:Create(
		chevron,
		TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Position = UDim2.new(0.5, 0, 0, 42) }
	)

	return {
		id = id,
		position = nil,
		getter = nil,
		instance = nil,
		color = color,
		label = label,
		icon = icon,
		auto = false,
		suppressed = false,
		part = part,
		corona = corona,
		ringLow = ringLow,
		ringHigh = ringHigh,
		billboard = billboard,
		markerScale = markerScale,
		chevron = chevron,
		nameLabel = nameLabel,
		distLabel = distLabel,
		lastDistText = "",
		bob = bob,
	}
end

local function applyStyle(wp: Waypoint, color: Color3, label: string)
	wp.color = color
	wp.label = label
	wp.icon = WaypointController.iconFor(wp.id, label)
	wp.ringLow.Color = color
	wp.ringHigh.Color = color
	wp.chevron.ImageColor3 = color
	wp.nameLabel.Text = string.upper(Kit.sanitize(label))
end

local function destroyWaypoint(wp: Waypoint)
	wp.bob:Cancel()
	wp.part:Destroy()
end

local function resolvePosition(wp: Waypoint): Vector3?
	local getter = wp.getter
	if getter then
		local ok, pos = pcall(getter)
		if ok and typeof(pos) == "Vector3" then
			return pos
		end
		return nil
	end
	local inst = wp.instance
	if inst then
		if inst.Parent == nil then
			return nil
		end
		if inst:IsA("Attachment") then
			return inst.WorldPosition
		elseif inst:IsA("BasePart") then
			return inst.Position
		elseif inst:IsA("Model") then
			return inst:GetPivot().Position
		end
		return nil
	end
	return wp.position
end

local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

local function placeTarget(wp: Waypoint, pos: Vector3)
	wp.position = pos
	wp.part.CFrame = CFrame.new(pos)
	if not (wp.getter or wp.instance) then
		-- coronas sit on the ground at a fixed destination; the upper ring stacks on the lower one
		wp.ringLow.CFrame = CFrame.new(pos + Vector3.new(0, CORONA_LOW / 2, 0)) * UPRIGHT
		wp.ringHigh.CFrame = CFrame.new(pos + Vector3.new(0, CORONA_LOW + CORONA_HIGH / 2, 0)) * UPRIGHT
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------------------------------------------------

local function upsert(id: string, color: Color3?, label: string?): Waypoint
	local wp = waypoints[id]
	local c = color or (if wp then wp.color else C.Yellow)
	local l = label or (if wp then wp.label else string.upper(id))
	if not wp then
		wp = buildWaypoint(id, c, l)
		waypoints[id] = wp
	else
		applyStyle(wp, c, l)
	end
	return wp :: Waypoint
end

-- Show (or move/restyle) a static waypoint. position nil clears it.
function WaypointController.set(id: string, position: Vector3?, color: Color3?, label: string?)
	if typeof(id) ~= "string" or id == "" then
		return
	end
	if typeof(position) ~= "Vector3" then
		WaypointController.clear(id)
		return
	end
	local wp = upsert(id, color, label)
	wp.getter = nil
	wp.instance = nil
	wp.auto = false
	placeTarget(wp, position)
end

-- Follow a moving target: an Instance (Model / BasePart / Attachment) or a function returning a Vector3 (or nil to
-- hide while unknown). The waypoint clears itself when a tracked Instance is destroyed.
function WaypointController.track(id: string, target: any, color: Color3?, label: string?)
	if typeof(id) ~= "string" or id == "" then
		return
	end
	local wp = upsert(id, color, label)
	wp.auto = false
	if typeof(target) == "function" then
		wp.getter = target
		wp.instance = nil
	elseif typeof(target) == "Instance" then
		wp.getter = nil
		wp.instance = target
	else
		wp.getter = nil
		wp.instance = nil
	end
	local pos = resolvePosition(wp)
	if pos then
		placeTarget(wp, pos)
	end
end

function WaypointController.clear(id: string)
	local wp = waypoints[id]
	if wp then
		waypoints[id] = nil
		destroyWaypoint(wp)
	end
end

function WaypointController.clearAll()
	for id in table.clone(waypoints) do
		WaypointController.clear(id)
	end
end

function WaypointController.has(id: string): boolean
	return waypoints[id] ~= nil
end

function WaypointController.getPosition(id: string): Vector3?
	local wp = waypoints[id]
	return if wp then wp.position else nil
end

-- Calls fn(id, position, color, label) for every shown waypoint (known position, not hidden as a duplicate of
-- another one). Used by the minimap / fullscreen map for blips and GPS; pass a long-lived function (no per-call
-- allocation here).
function WaypointController.each(fn: (string, Vector3, Color3, string) -> ())
	for id, wp in waypoints do
		local pos = wp.position
		if pos and not wp.suppressed then
			fn(id, pos, wp.color, wp.label)
		end
	end
end

-- Internal: set a waypoint owned by this controller (auto=true).
local function setAuto(id: string, position: Vector3, color: Color3, label: string)
	local existing = waypoints[id]
	if existing and not existing.auto then
		return -- someone else owns this id right now; don't fight them
	end
	if
		existing
		and existing.position
		and (existing.position - position).Magnitude < 0.5
		and existing.label == label
	then
		return
	end
	local wp = upsert(id, color, label)
	wp.getter = nil
	wp.instance = nil
	wp.auto = true
	placeTarget(wp, position)
end

local function clearAuto(id: string)
	local wp = waypoints[id]
	if wp and wp.auto then
		WaypointController.clear(id)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Auto waypoints
-------------------------------------------------------------------------------------------------------------------------

local function drivingDeliverable(): boolean
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not (seat and seat:IsA("VehicleSeat")) then
		return false
	end
	-- the seat's parent is the car model (CarBuilder contract); nearest Model ancestor tolerates nesting
	local model = seat:FindFirstAncestorWhichIsA("Model")
	if not model then
		return false
	end
	local kind = model:GetAttribute("Kind")
	return typeof(kind) == "string" and DELIVERABLE_KINDS[kind] == true
end

local function homeTarget(): Vector3?
	local plotIndex = player:GetAttribute("PlotIndex")
	if typeof(plotIndex) ~= "number" or plotIndex % 1 ~= 0 or plotIndex < 1 or plotIndex > MapLayout.plotCount() then
		return nil
	end
	local ok, cf, size = pcall(MapLayout.plotDropoffZone, plotIndex)
	if not ok then
		return nil
	end
	-- the zone box is centered size.Y/2 above the garage floor; aim at the floor
	return (cf :: CFrame).Position - Vector3.new(0, (size :: Vector3).Y / 2, 0)
end

local function updateAutoHome()
	local target = if drivingDeliverable() then homeTarget() else nil
	if target then
		setAuto(HOME_ID, target, C.Yellow, "GARAGE")
	else
		clearAuto(HOME_ID)
	end
end

-- While wanted: point at the nearest Spray Shop with its price (the "lose the cops at a Spray Shop" hint is useless
-- if nobody can find one).
local sprayTargets: { Vector3 }? = nil
local function updateAutoSpray()
	local stars = player:GetAttribute("Wanted")
	local root = originAttachment
	if typeof(stars) ~= "number" or stars < 1 or not (root and root.Parent) then
		clearAuto(SPRAY_ID)
		return
	end
	local targets = sprayTargets
	if not targets then
		local list: { Vector3 } = {}
		local ok, zones = pcall(MapLayout.sprayZones)
		if ok and typeof(zones) == "table" then
			for _, zone in zones do
				-- the zone box floats size.Y/2 above the street; aim at the floor
				table.insert(list, zone.cframe.Position - Vector3.new(0, zone.size.Y / 2, 0))
			end
		end
		sprayTargets = list
		targets = list
	end
	local idx = WaypointController.nearestIndex(targets :: { Vector3 }, root.WorldPosition)
	if not idx then
		clearAuto(SPRAY_ID)
		return
	end
	local cost = WaypointController.sprayCost(stars, player:GetAttribute("IncomePerSec"))
	setAuto(SPRAY_ID, (targets :: { Vector3 })[idx], C.Text, "SPRAY " .. Format.cash(cost))
end

local function onHotDrop(state: any)
	if WaypointController.hotDropVisible(state, Workspace:GetServerTimeNow()) then
		local def = if typeof(state.carId) == "string" then Cars.get(state.carId) else nil
		local label = if def then "HOT DROP: " .. string.upper(def.name) else "HOT DROP"
		-- setAuto leaves the id alone when EventsClient (or the server) already owns it
		setAuto(HOTDROP_ID, state.position, C.Gold, label)
	elseif waypoints[HOTDROP_ID] then
		-- the drop is over (claimed/expired/stale): clear whoever set it
		WaypointController.clear(HOTDROP_ID)
	end
end

-- Hide auto waypoints that duplicate another waypoint's spot.
local othersScratch: { Vector3 } = {}
local function updateSuppression()
	table.clear(othersScratch)
	for _, wp in waypoints do
		if not wp.auto and wp.position then
			table.insert(othersScratch, wp.position)
		end
	end
	for _, wp in waypoints do
		local pos = wp.position
		wp.suppressed = wp.auto and pos ~= nil and WaypointController.isNearAny(pos, othersScratch, DUPLICATE_RADIUS)
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Character binding
-------------------------------------------------------------------------------------------------------------------------

local function bindCharacter(char: Model)
	task.spawn(function()
		local root = char:WaitForChild("HumanoidRootPart", 10)
		if not (root and root:IsA("BasePart")) or char.Parent == nil then
			return
		end
		local att = root:FindFirstChild("HC_WaypointStart")
		if not (att and att:IsA("Attachment")) then
			att = Instance.new("Attachment")
			att.Name = "HC_WaypointStart"
			att.Position = Vector3.new(0, -1, 0)
			att.Parent = root
		end
		originAttachment = att :: Attachment
	end)
end

-------------------------------------------------------------------------------------------------------------------------
-- Frame update
-------------------------------------------------------------------------------------------------------------------------

local distAccum = 0
local autoAccum = math.huge -- run the slow tick on the first frame

local function lazyHud(): any
	local mod = script.Parent:FindFirstChild("HUDController")
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, mod :: any)
	return if ok and typeof(result) == "table" then result else nil
end

local function setCorona(wp: Waypoint, on: boolean)
	if wp.coronaOn ~= on then
		wp.coronaOn = on
		wp.corona.Parent = if on then wp.part else nil
	end
end

-- Chevron billboard on/off (its bob tween only runs while shown).
local function setChevron(wp: Waypoint, on: boolean)
	if wp.shown ~= on then
		wp.shown = on
		wp.billboard.Enabled = on
		if on then
			wp.bob:Play()
		else
			wp.bob:Pause()
		end
	end
end

local function hide(wp: Waypoint)
	setChevron(wp, false)
	setCorona(wp, false)
end

local function update(dt: number)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end

	autoAccum += dt
	if autoAccum >= AUTO_TICK then
		autoAccum = 0
		updateAutoHome()
		updateAutoSpray()
		onHotDrop(StateController.getHotDrop()) -- also expires stale drops without a new push
		updateSuppression()
		local s = computeUiScale()
		if s ~= uiScale then
			uiScale = s
			for _, wp in waypoints do
				wp.markerScale.Scale = s
				wp.billboard.Size = UDim2.fromOffset(math.floor(MARKER_W * s), math.floor(MARKER_H * s))
			end
		end
	end

	distAccum += dt
	local refreshDist = distAccum >= DIST_TICK
	if refreshDist then
		distAccum = 0
	end

	local att = originAttachment
	local origin = if att and att.Parent then att.WorldPosition else cam.Focus.Position

	for id, wp in waypoints do
		if wp.instance and wp.instance.Parent == nil then
			WaypointController.clear(id) -- tracked thing is gone
			continue
		end
		local tracked = wp.getter ~= nil or wp.instance ~= nil
		local pos = if tracked then resolvePosition(wp) else wp.position
		if pos == nil or wp.suppressed then
			hide(wp)
			continue
		end
		if pos ~= wp.position then
			placeTarget(wp, pos)
		end
		local dist = (pos - origin).Magnitude
		local corona, chevron, chevronHeight = WaypointController.markerFlags(tracked, dist)
		-- standing in the corona keeps the ring but loses the chevron; streamer mode hides both
		setChevron(wp, chevron and not hudHidden)
		setCorona(wp, corona and not hudHidden)
		if wp.shown and wp.billboard.StudsOffsetWorldSpace.Y ~= chevronHeight then
			wp.billboard.StudsOffsetWorldSpace = Vector3.new(0, chevronHeight, 0)
		end

		if refreshDist or wp.lastDistText == "" then
			local text = WaypointController.formatDistance(dist)
			if text ~= wp.lastDistText then
				wp.lastDistText = text
				wp.distLabel.Text = text
			end
		end
	end
end

-- Advance one frame by hand (headless tests). The live game drives this from RunService.PreRender.
function WaypointController.step(dt: number)
	update(dt)
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

function WaypointController.init() end

function WaypointController.start()
	uiScale = computeUiScale()

	local ok, err = pcall(Net.listen, "Waypoint", function(id: any, position: any, color: any, label: any)
		if typeof(id) ~= "string" or #id == 0 or #id > 64 then
			return
		end
		if typeof(position) == "Vector3" then
			WaypointController.set(
				id,
				position,
				if typeof(color) == "Color3" then color else nil,
				if typeof(label) == "string" then label else nil
			)
		else
			WaypointController.clear(id)
		end
	end)
	if not ok then
		warn("[WaypointController] Waypoint remote unavailable: " .. tostring(err))
	end

	StateController.HotDropChanged:Connect(onHotDrop)
	onHotDrop(StateController.getHotDrop())

	-- streamer mode: chevrons and coronas go (update() re-applies visibility every frame)
	local hud = lazyHud()
	if hud and hud.VisibilityChanged and typeof(hud.isHidden) == "function" then
		local function applyHidden(value: boolean)
			hudHidden = value == true
		end
		hud.VisibilityChanged:Connect(applyHidden)
		local okHidden, value = pcall(hud.isHidden)
		applyHidden(okHidden and value == true)
	end

	player.CharacterAdded:Connect(bindCharacter)
	if player.Character then
		bindCharacter(player.Character)
	end

	RunService.PreRender:Connect(function(dt: number)
		debug.profilebegin("HC_Waypoints")
		update(dt)
		debug.profileend()
	end)
end

return WaypointController
