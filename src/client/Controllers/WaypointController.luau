--!strict
-- WaypointController (SPEC §7): GPS-style guidance to points of interest.
--
-- Each waypoint renders:
--   * a glowing world Beam from the local character to an invisible anchored target part (+ a scrolling sparkle beam),
--   * a light pillar rising from the target so it reads from across the city,
--   * a big floating marker (BillboardGui: pin with icon, label, live distance "245m" — 3 studs = 1 meter),
--   * an on-screen edge arrow (rotating pointer + icon + distance) whenever the target is off-screen.
--
-- Public API:
--   set(id, position: Vector3?, color: Color3?, label: string?)   nil position clears. `Waypoint` remote does the same.
--   track(id, target: Instance | () -> Vector3?, color?, label?)   moving target (Model/BasePart/Attachment or getter).
--   clear(id), clearAll(), has(id), getPosition(id)
-- Auto waypoints:
--   "home"    own plot drop-off (MapLayout.plotDropoffZone(PlotIndex)) while the local player drives a car whose model
--             Kind is "Loot" or "Stolen"; cleared when not driving (only if this controller created it).
--   "hotdrop" Hot Drop location while StateController's HotDropState is active.
-- Auto waypoints hide themselves when a server/other waypoint already marks (almost) the same spot.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net"))
local Config = Shared:WaitForChild("Config")
local Cars = require(Config:WaitForChild("Cars"))
local MapLayout = require(Shared:WaitForChild("Util"):WaitForChild("MapLayout"))

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))

-- Earlier in the client ORDER: safe to require directly.
local StateController = require(script.Parent:WaitForChild("StateController"))

local WaypointController = {}

local player = Players.LocalPlayer

WaypointController.STUDS_PER_METER = 3

local HOME_ID = "home"
local HOTDROP_ID = "hotdrop"
local DELIVERABLE_KINDS: { [string]: boolean } = { Loot = true, Stolen = true }
local DUPLICATE_RADIUS = 30 -- an auto waypoint hides if another waypoint is this close to it
local NEAR_HIDE_BEAM = 18 -- hide the guide beam when this close (studs)
local PILLAR_HEIGHT = 140
local MARKER_HEIGHT = 9
local MARKER_WIDTH = 230 -- billboard pixels (room for "HOT DROP: <CAR NAME>")
local AUTO_TICK = 0.25
local DIST_TICK = 0.1
local ARROW_SIZE = 76
local ARROW_MARGIN = 54 -- design pixels from the screen edge (scaled with the UI)
local ARROW_MARGIN_LEFT = 116 -- wider on the left so arrows clear the HUD side-menu column
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

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
	part: Part,
	beamEnd: Attachment,
	core: Beam,
	glow: Beam,
	pillar: Beam,
	billboard: BillboardGui,
	pin: Frame,
	tip: Frame,
	pinIcon: TextLabel,
	nameLabel: TextLabel,
	distLabel: TextLabel,
	arrow: Frame,
	arrowSpin: Frame,
	arrowBadge: Frame,
	arrowTip: Frame,
	arrowIcon: TextLabel,
	arrowDist: TextLabel,
	arrowScale: UIScale,
	lastDistText: string,
	tweens: { Tween },
	shown: boolean?,
	beamOn: boolean?,
	arrowOn: boolean?,
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

-- Emoji for a waypoint id/label.
function WaypointController.iconFor(id: string, label: string?): string
	local key = string.lower(id .. " " .. (label or ""))
	if key:find("home", 1, true) or key:find("garage", 1, true) or key:find("drop off", 1, true) then
		return "🏠"
	elseif key:find("hotdrop", 1, true) or key:find("hot drop", 1, true) then
		return "🔥"
	elseif key:find("stolen", 1, true) or key:find("thief", 1, true) or key:find("theft", 1, true) then
		return "🚨"
	elseif key:find("dealer", 1, true) then
		return "🏪"
	elseif key:find("chop", 1, true) then
		return "🔧"
	elseif key:find("spray", 1, true) then
		return "🎨"
	elseif key:find("shop", 1, true) or key:find("gear", 1, true) then
		return "🛒"
	elseif key:find("tutorial", 1, true) or key:find("car", 1, true) then
		return "🚗"
	end
	return "📍"
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

-------------------------------------------------------------------------------------------------------------------------
-- State + containers
-------------------------------------------------------------------------------------------------------------------------

local waypoints: { [string]: Waypoint } = {}
local worldFolder: Folder? = nil
local arrowGui: ScreenGui? = nil
local startAttachment: Attachment? = nil
local uiScale = 1

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

local function computeUiScale(): number
	local cam = Workspace.CurrentCamera
	if not cam then
		return 1
	end
	local vp = cam.ViewportSize
	return math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.55, 1.6)
end

-- Edge arrows live in a raw, full-screen ScreenGui (no UIScale, IgnoreGuiInset) so WorldToViewportPoint pixels map
-- 1:1 onto it; each arrow carries its own UIScale matching Kit.screen's scale.
local function getArrowGui(): ScreenGui
	local g = arrowGui
	if g and g.Parent then
		return g
	end
	local gui = Kit.new("ScreenGui", {
		Name = "HC_WaypointArrows",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = Theme.Layers.HUD - 1,
		Parent = player:WaitForChild("PlayerGui"),
	})
	arrowGui = gui
	return gui
end

local function colorSeq(c: Color3): ColorSequence
	return ColorSequence.new(c)
end

-------------------------------------------------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------------------------------------------------

local function circle(color: Color3, size: number, props: { [string]: any }?): Frame
	local f = Kit.new("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(size, size),
	}, {
		Kit.corner(UDim.new(1, 0)),
		Kit.stroke(Theme.Colors.Stroke, 3),
		Kit.gradient(Color3.new(1, 1, 1), Color3.fromRGB(175, 175, 175)),
	})
	if props then
		for k, v in props do
			(f :: any)[k] = v
		end
	end
	return f
end

local function diamond(color: Color3, size: number, props: { [string]: any }?): Frame
	local f = Kit.new("Frame", {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(size, size),
		Rotation = 45,
	}, {
		Kit.corner(UDim.new(0, 4)),
		Kit.stroke(Theme.Colors.Stroke, 3),
	})
	if props then
		for k, v in props do
			(f :: any)[k] = v
		end
	end
	return f
end

local function emojiLabel(text: string, props: { [string]: any }?): TextLabel
	local l = Kit.new("TextLabel", {
		Name = "Icon",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.68, 0.68),
		Text = text,
		TextScaled = true,
		FontFace = Theme.Fonts.Display,
		TextColor3 = Color3.new(1, 1, 1),
	})
	if props then
		for k, v in props do
			(l :: any)[k] = v
		end
	end
	return l
end

local function buildWaypoint(id: string, color: Color3, label: string): Waypoint
	local icon = WaypointController.iconFor(id, label)

	-- world: invisible anchored target with beams + marker
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

	local beamEnd = Instance.new("Attachment")
	beamEnd.Name = "BeamEnd"
	beamEnd.Position = Vector3.new(0, 1.5, 0)
	beamEnd.Parent = part
	local pillarBottom = Instance.new("Attachment")
	pillarBottom.Name = "PillarBottom"
	pillarBottom.Parent = part
	local pillarTop = Instance.new("Attachment")
	pillarTop.Name = "PillarTop"
	pillarTop.Position = Vector3.new(0, PILLAR_HEIGHT, 0)
	pillarTop.Parent = part

	local core = Kit.new("Beam", {
		Name = "Core",
		Attachment1 = beamEnd,
		Color = colorSeq(color),
		FaceCamera = true,
		LightEmission = 1,
		LightInfluence = 0,
		Segments = 2,
		Width0 = 0.7,
		Width1 = 0.7,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.04, 0.25),
			NumberSequenceKeypoint.new(0.85, 0.35),
			NumberSequenceKeypoint.new(1, 0.6),
		}),
		Parent = part,
	})
	local glow = Kit.new("Beam", {
		Name = "Glow",
		Attachment1 = beamEnd,
		Color = colorSeq(color:Lerp(Color3.new(1, 1, 1), 0.25)),
		FaceCamera = true,
		LightEmission = 1,
		LightInfluence = 0,
		Segments = 2,
		Width0 = 2.4,
		Width1 = 2.4,
		Texture = SPARKLE_TEXTURE,
		TextureMode = Enum.TextureMode.Wrap,
		TextureLength = 6,
		TextureSpeed = 1.4,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.05, 0.35),
			NumberSequenceKeypoint.new(1, 0.55),
		}),
		Parent = part,
	})
	local pillar = Kit.new("Beam", {
		Name = "Pillar",
		Attachment0 = pillarBottom,
		Attachment1 = pillarTop,
		Color = colorSeq(color),
		FaceCamera = true,
		LightEmission = 1,
		LightInfluence = 0,
		Segments = 1,
		Width0 = 7,
		Width1 = 2,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.6, 0.65),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = part,
	})

	local billboard = Kit.new("BillboardGui", {
		Name = "Marker",
		Size = UDim2.fromOffset(MARKER_WIDTH, 134),
		StudsOffsetWorldSpace = Vector3.new(0, MARKER_HEIGHT, 0),
		AlwaysOnTop = true,
		LightInfluence = 0,
		ResetOnSpawn = false,
		ClipsDescendants = false,
		Parent = part,
	})
	local tip = diamond(color, 24, {
		Name = "Tip",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(MARKER_WIDTH / 2, 58),
		ZIndex = 1,
		Parent = billboard,
	})
	local pin = circle(color, 64, {
		Name = "Pin",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromOffset(MARKER_WIDTH / 2, 0),
		ZIndex = 2,
		Parent = billboard,
	})
	local pinIcon = emojiLabel(icon, { ZIndex = 3, Parent = pin })
	local nameLabel = Kit.label(label, 20, {
		Name = "Label",
		Position = UDim2.fromOffset(0, 80),
		Size = UDim2.new(1, 0, 0, 24),
		TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.35),
		TextScaled = true,
		ZIndex = 3,
	})
	Kit.new("UITextSizeConstraint", { MaxTextSize = 21, MinTextSize = 11, Parent = nameLabel })
	nameLabel.Parent = billboard
	local distLabel = Kit.label("", 18, {
		Name = "Distance",
		Position = UDim2.fromOffset(0, 106),
		Size = UDim2.new(1, 0, 0, 22),
		ZIndex = 3,
	})
	distLabel.Parent = billboard

	part.Parent = getWorldFolder()

	-- screen: edge arrow
	local arrow = Kit.new("Frame", {
		Name = "Arrow_" .. id,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(ARROW_SIZE, ARROW_SIZE),
		Visible = false,
		Parent = getArrowGui(),
	})
	local arrowScale = Kit.new("UIScale", { Scale = uiScale, Parent = arrow })
	local spin = Kit.new("Frame", {
		Name = "Spin",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = arrow,
	})
	local arrowTip = diamond(color, 30, {
		Name = "Tip",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 12),
		ZIndex = 1,
		Parent = spin,
	})
	local badge = circle(color, 52, {
		Name = "Badge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		ZIndex = 2,
		Parent = spin,
	})
	local badgePulse = Kit.new("UIScale", { Parent = badge })
	local arrowIcon = emojiLabel(icon, { ZIndex = 3, Parent = badge })
	local arrowDist = Kit.label("", 16, {
		Name = "Distance",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(90, 20),
		Position = UDim2.new(0.5, 0, 1, 6),
		ZIndex = 4,
	})
	arrowDist.Parent = arrow

	local tweens: { Tween } = {}
	local bob = TweenService:Create(
		billboard,
		TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ StudsOffsetWorldSpace = Vector3.new(0, MARKER_HEIGHT + 2, 0) }
	)
	bob:Play()
	table.insert(tweens, bob)
	local pulse = TweenService:Create(
		badgePulse,
		TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Scale = 1.12 }
	)
	pulse:Play()
	table.insert(tweens, pulse)

	-- pop the marker in
	local pinScale = Kit.new("UIScale", { Scale = 0.2, Parent = pin })
	TweenService:Create(pinScale, Theme.TweenPop, { Scale = 1 }):Play()

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
		beamEnd = beamEnd,
		core = core,
		glow = glow,
		pillar = pillar,
		billboard = billboard,
		pin = pin,
		tip = tip,
		pinIcon = pinIcon,
		nameLabel = nameLabel,
		distLabel = distLabel,
		arrow = arrow,
		arrowSpin = spin,
		arrowBadge = badge,
		arrowTip = arrowTip,
		arrowIcon = arrowIcon,
		arrowDist = arrowDist,
		arrowScale = arrowScale,
		lastDistText = "",
		tweens = tweens,
	}
end

local function applyStyle(wp: Waypoint, color: Color3, label: string)
	local icon = WaypointController.iconFor(wp.id, label)
	wp.color = color
	wp.label = label
	wp.icon = icon
	wp.core.Color = colorSeq(color)
	wp.glow.Color = colorSeq(color:Lerp(Color3.new(1, 1, 1), 0.25))
	wp.pillar.Color = colorSeq(color)
	wp.pin.BackgroundColor3 = color
	wp.tip.BackgroundColor3 = color
	wp.arrowBadge.BackgroundColor3 = color
	wp.arrowTip.BackgroundColor3 = color
	wp.pinIcon.Text = icon
	wp.arrowIcon.Text = icon
	wp.nameLabel.Text = label
	wp.nameLabel.TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.35)
end

local function bindStart(wp: Waypoint)
	local att = startAttachment
	local a0 = if att and att.Parent then att else nil
	if wp.core.Attachment0 ~= a0 then
		wp.core.Attachment0 = a0
		wp.glow.Attachment0 = a0
	end
end

local function destroyWaypoint(wp: Waypoint)
	for _, t in wp.tweens do
		t:Cancel()
	end
	wp.part:Destroy()
	wp.arrow:Destroy()
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

local function placeTarget(wp: Waypoint, pos: Vector3)
	wp.position = pos
	wp.part.CFrame = CFrame.new(pos)
end

-------------------------------------------------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------------------------------------------------

local function upsert(id: string, color: Color3?, label: string?): Waypoint
	local wp = waypoints[id]
	local c = color or (if wp then wp.color else Theme.Colors.Secondary)
	local l = label or (if wp then wp.label else string.upper(id))
	if not wp then
		wp = buildWaypoint(id, c, l)
		waypoints[id] = wp
		bindStart(wp)
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
		setAuto(HOME_ID, target, Theme.Colors.Cash, "DROP OFF")
	else
		clearAuto(HOME_ID)
	end
end

local function onHotDrop(state: any)
	if WaypointController.hotDropVisible(state, Workspace:GetServerTimeNow()) then
		local def = if typeof(state.carId) == "string" then Cars.get(state.carId) else nil
		local label = if def then "HOT DROP: " .. string.upper(def.name) else "HOT DROP"
		-- setAuto leaves the id alone when EventsClient (or the server) already owns it
		setAuto(HOTDROP_ID, state.position, Theme.Colors.Warning, label)
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
		startAttachment = att :: Attachment
		for _, wp in waypoints do
			bindStart(wp)
		end
	end)
end

-------------------------------------------------------------------------------------------------------------------------
-- Frame update
-------------------------------------------------------------------------------------------------------------------------

local distAccum = 0
local autoAccum = math.huge -- run the slow tick on the first frame
local insets: Insets = { left = 0, top = 0, right = 0, bottom = 0 } -- reused every frame
local topInset = 0

local function setBeam(wp: Waypoint, on: boolean)
	if wp.beamOn ~= on then
		wp.beamOn = on
		wp.core.Enabled = on
		wp.glow.Enabled = on
	end
end

local function setArrow(wp: Waypoint, on: boolean)
	if wp.arrowOn ~= on then
		wp.arrowOn = on
		wp.arrow.Visible = on
	end
end

local function setVisible(wp: Waypoint, visible: boolean)
	if wp.shown ~= visible then
		wp.shown = visible
		wp.billboard.Enabled = visible
		wp.pillar.Enabled = visible
	end
	if not visible then
		setBeam(wp, false)
		setArrow(wp, false)
	end
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
		onHotDrop(StateController.getHotDrop()) -- also expires stale drops without a new push
		updateSuppression()
		local inset = GuiService:GetGuiInset()
		topInset = if typeof(inset) == "Vector2" then inset.Y else 0
		local s = computeUiScale()
		if s ~= uiScale then
			uiScale = s
			for _, wp in waypoints do
				wp.arrowScale.Scale = s
			end
		end
	end

	distAccum += dt
	local refreshDist = distAccum >= DIST_TICK
	if refreshDist then
		distAccum = 0
	end

	local vp = cam.ViewportSize
	local margin = ARROW_MARGIN * uiScale
	insets.left = ARROW_MARGIN_LEFT * uiScale
	insets.right = margin
	insets.top = margin + topInset
	insets.bottom = margin
	local att = startAttachment
	local origin = if att and att.Parent then att.WorldPosition else cam.Focus.Position

	for id, wp in waypoints do
		if wp.instance and wp.instance.Parent == nil then
			WaypointController.clear(id) -- tracked thing is gone
			continue
		end
		local pos = if wp.getter or wp.instance then resolvePosition(wp) else wp.position
		if pos == nil or wp.suppressed then
			setVisible(wp, false)
			continue
		end
		if pos ~= wp.position then
			placeTarget(wp, pos)
		end
		setVisible(wp, true)

		local dist = (pos - origin).Magnitude
		setBeam(wp, dist > NEAR_HIDE_BEAM)

		if refreshDist or wp.lastDistText == "" then
			local text = WaypointController.formatDistance(dist)
			if text ~= wp.lastDistText then
				wp.lastDistText = text
				wp.distLabel.Text = text
				wp.arrowDist.Text = text
			end
		end

		local markerPos = pos + Vector3.new(0, MARKER_HEIGHT * 0.6, 0)
		local screen = cam:WorldToViewportPoint(markerPos)
		local camRel = cam.CFrame:PointToObjectSpace(markerPos)
		local onScreen, p, angle = WaypointController.edgeArrow(screen, vp, insets, nil, camRel)
		setArrow(wp, not onScreen)
		if not onScreen then
			wp.arrow.Position = UDim2.fromOffset(p.X, p.Y)
			wp.arrowSpin.Rotation = angle
			wp.arrowIcon.Rotation = -angle
			-- distance text sits on the inner side of the arrow (toward the screen center)
			local r = math.rad(angle)
			wp.arrowDist.Position = UDim2.new(0.5, -math.sin(r) * 50, 0.5, math.cos(r) * 50)
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
	getArrowGui()

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
