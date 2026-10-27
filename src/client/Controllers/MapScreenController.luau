--!strict
-- MapScreenController: the full city map, shown as the pause menu's MAP tab (gta_ui_language §2.13, §5.12).
--
--  * Open with M (straight to the MAP tab), P then Q / E, by clicking / tapping the radar, or
--    MapScreenController.open(), which asks MenuController for the pause menu on MAP; the pause menu calls show() /
--    hide() as the tab changes. Without a MenuController it shows on its own. Close with Backspace / B or M again.
--  * Pan by dragging (mouse or one finger), zoom with the mouse wheel (around the cursor), a pinch (around the
--    fingers) or the +/- buttons; the target button re-centers on you.
--  * Click / tap the map to set your waypoint (WaypointController id Config/Minimap.CUSTOM_WAYPOINT.ID: the 3D beam in
--    the world + the GPS route on the radar); tapping a blip drops the waypoint right on that place. Tap your
--    waypoint again (or CLEAR WAYPOINT) to remove it.
--  * Shows the same map art as the radar, district names (Oswald labels, nothing baked), every blip in the GTA
--    palette (shops / landmarks white, your garage blue, rivals grey with their names, waypoints, police red / blue),
--    the GPS route and you. A legend sits on the right (collapsible on phones); zoom / re-centre are flat squares.
--  * Map layer: a raw ScreenGui (no UIScale) under the pause chrome so input math stays in real pixels; the map's
--    own chrome (GPS line, tools, legend) is a Kit.screen with the usual scaling.
--
-- Public API: open(), close(), toggle(), isOpen(), show(), hide()
-- Pure helpers (tests): fitScale, fitCenterZ, worldToScreen, screenToWorld, zoomAround, clampCenter, isTap.

local GuiService = game:GetService("GuiService")
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

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI:WaitForChild("Kit"))
local Theme = require(UI:WaitForChild("Theme"))

-- Earlier in the client ORDER: safe to require at the top.
local MinimapController = require(script.Parent:WaitForChild("MinimapController"))
local SoundController = require(script.Parent:WaitForChild("SoundController"))
local WaypointController = require(script.Parent:WaitForChild("WaypointController"))

local MapScreenController = {}

local player = Players.LocalPlayer

local MAP = MinimapConfig.MAP
local GPS = MinimapConfig.GPS
local CUSTOM = MinimapConfig.CUSTOM_WAYPOINT
local WORLD_MIN = MinimapConfig.WORLD_MIN
local WORLD_SIZE = MinimapConfig.WORLD_SIZE
local ATLAS = MinimapConfig.ATLAS
local CELLS = MinimapConfig.ATLAS_CELLS :: { [string]: { number } }
local FIT_SPAN = (MapConfig.BOUNDARY + 50) * 2 -- studs the fit-to-screen view shows (the whole island + surf)
local CENTER_LIMIT = MapConfig.BOUNDARY + 40
local UPDATE_DT = 1 / 30
local WHITE = Color3.new(1, 1, 1)
local C = Theme.Colors
local MAP_WATER = Color3.fromHex("#1F3445")
local PAUSE_TOP = 0.235 -- the pause header + tabs take the top of the screen (UI/PauseMenu.frame)

-------------------------------------------------------------------------------------------------------------------------
-- Pure helpers (exported for tests). A view is (cx, cz, scale): world point at the screen center + px per stud.
-------------------------------------------------------------------------------------------------------------------------

-- px per stud that shows the whole island below a `top` px header (default 0).
function MapScreenController.fitScale(vpW: number, vpH: number, top: number?): number
	return math.max(1e-3, math.min(vpW, vpH - (top or 0)) / FIT_SPAN)
end

-- View center z that centers the island in the area below a `top` px header at `scale`.
function MapScreenController.fitCenterZ(scale: number, top: number?): number
	return -((top or 0) / 2) / scale
end

function MapScreenController.worldToScreen(
	x: number,
	z: number,
	cx: number,
	cz: number,
	scale: number,
	vpW: number,
	vpH: number
): (number, number)
	return vpW / 2 + (x - cx) * scale, vpH / 2 + (z - cz) * scale
end

function MapScreenController.screenToWorld(
	sx: number,
	sy: number,
	cx: number,
	cz: number,
	scale: number,
	vpW: number,
	vpH: number
): (number, number)
	return cx + (sx - vpW / 2) / scale, cz + (sy - vpH / 2) / scale
end

function MapScreenController.clampCenter(cx: number, cz: number): (number, number)
	return math.clamp(cx, -CENTER_LIMIT, CENTER_LIMIT), math.clamp(cz, -CENTER_LIMIT, CENTER_LIMIT)
end

-- Zoom by `factor` keeping the world point under screen (sx, sy) fixed; scale clamped to [minScale, maxScale].
-- Returns the new (cx, cz, scale).
function MapScreenController.zoomAround(
	cx: number,
	cz: number,
	scale: number,
	factor: number,
	sx: number,
	sy: number,
	vpW: number,
	vpH: number,
	minScale: number,
	maxScale: number
): (number, number, number)
	local wx, wz = MapScreenController.screenToWorld(sx, sy, cx, cz, scale, vpW, vpH)
	local s = math.clamp(scale * factor, minScale, maxScale)
	local ncx = wx - (sx - vpW / 2) / s
	local ncz = wz - (sy - vpH / 2) / s
	ncx, ncz = MapScreenController.clampCenter(ncx, ncz)
	return ncx, ncz, s
end

-- A press counts as a tap when it moved less than `slop` px and was released within `maxTime` seconds.
function MapScreenController.isTap(moved: number, held: number, slop: number?, maxTime: number?): boolean
	return moved <= (slop or MAP.TAP_SLOP) and held <= (maxTime or MAP.TAP_TIME)
end

-------------------------------------------------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------------------------------------------------

type Pool = { parent: Frame, items: { ImageLabel }, used: number, shown: number }
type LabelPool = { parent: Frame, items: { TextLabel }, used: number, shown: number }

type Ui = {
	mapGui: ScreenGui,
	backdrop: Frame,
	world: Frame,
	overlay: Frame,
	route: MinimapController.RouteRenderer,
	blips: Pool,
	labels: LabelPool,
	arrow: ImageLabel,
	chrome: ScreenGui,
	gpsChip: Frame,
	gpsIcon: ImageLabel,
	gpsText: TextLabel,
	clearButton: TextButton,
	legend: Frame,
	legendToggle: TextButton,
	hint: TextLabel,
}

local ui: Ui? = nil
local isOpen = false
local cx, cz, scale = 0, 0, 1
local vpW, vpH = 1280, 720
local uiScale = 1
local accum = 0
local routeAccum = 0
local clock = 0

type Hotspot = { x: number, z: number, label: string, sx: number, sy: number }
local hotspots: { Hotspot } = {} -- tappable blips this frame (screen px), rebuilt each refresh
local hotspotCount = 0

-- input
type Press = { start: Vector2, last: Vector2, t: number, moved: number }
local presses: { [InputObject]: Press } = {}
local pressCount = 0
local pinchDist = 0
local pinchMid = Vector2.zero

local function cellOf(icon: string): { number }?
	return MinimapController.cellOf(icon)
end

local function viewport(): (number, number)
	local u = ui
	if u then
		local abs = u.backdrop.AbsoluteSize
		if abs.X > 1 and abs.Y > 1 then
			return abs.X, abs.Y
		end
	end
	local cam = Workspace.CurrentCamera
	if cam then
		return cam.ViewportSize.X, cam.ViewportSize.Y
	end
	return 1280, 720
end

-- Real px the pause header + tabs take at the top of the screen.
local function chromeTop(): number
	return vpH * PAUSE_TOP
end

local function limits(): (number, number)
	local fit = MapScreenController.fitScale(vpW, vpH, chromeTop())
	return fit * MAP.MIN_ZOOM, fit * MAP.MAX_ZOOM
end

local function rootPos(): Vector3?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

-------------------------------------------------------------------------------------------------------------------------
-- Pools
-------------------------------------------------------------------------------------------------------------------------

local function blipPut(pool: Pool, icon: string, color: Color3, size: number, x: number, y: number, z: number)
	local i = pool.used + 1
	pool.used = i
	local item = pool.items[i]
	if not item then
		item = Kit.new("ImageLabel", {
			Name = "Blip",
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			Image = ATLAS,
			Parent = pool.parent,
		})
		if ATLAS == "" then
			item.BackgroundTransparency = 0
			Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = item })
		end
		pool.items[i] = item
	end
	local it = item :: ImageLabel
	local cell = cellOf(icon)
	if cell then
		it.ImageRectOffset = Vector2.new(cell[1], cell[2])
		it.ImageRectSize = Vector2.new(cell[3], cell[4])
	end
	it.ImageColor3 = color
	it.BackgroundColor3 = color
	it.Size = UDim2.fromOffset(size, size)
	it.Position = UDim2.fromOffset(x, y)
	it.ZIndex = z
end

local function blipEnd(pool: Pool)
	for i = pool.used + 1, pool.shown do
		pool.items[i].Visible = false
	end
	for i = 1, pool.used do
		pool.items[i].Visible = true
	end
	pool.shown = pool.used
	pool.used = 0
end

local function labelPut(pool: LabelPool, text: string, size: number, color: Color3, x: number, y: number, z: number)
	local i = pool.used + 1
	pool.used = i
	local item = pool.items[i]
	if not item then
		item = Kit.text("", "condensed", 18, {
			Name = "Label",
			AnchorPoint = Vector2.new(0.5, 0.5),
			AutomaticSize = Enum.AutomaticSize.X,
			TextTransparency = 0.15,
			Parent = pool.parent,
		})
		Kit.new("UIStroke", {
			Color = Color3.new(0, 0, 0),
			Thickness = 1,
			Transparency = 0.5,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
			Parent = item,
		})
		pool.items[i] = item
	end
	local it = item :: TextLabel
	if it.Text ~= text then
		it.Text = text
	end
	it.TextSize = size
	it.Size = UDim2.fromOffset(0, size + 6)
	it.TextColor3 = color
	it.Position = UDim2.fromOffset(x, y)
	it.ZIndex = z
end

local function labelEnd(pool: LabelPool)
	for i = pool.used + 1, pool.shown do
		pool.items[i].Visible = false
	end
	for i = 1, pool.used do
		pool.items[i].Visible = true
	end
	pool.shown = pool.used
	pool.used = 0
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

local function legendRow(parent: Instance, order: number, icon: string, color: Color3, text: string)
	local row = Kit.new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = order,
		Parent = parent,
	})
	atlasImage(icon, {
		Size = UDim2.fromOffset(16, 16),
		Position = UDim2.fromOffset(0, 2),
		ImageColor3 = color,
		BackgroundColor3 = color,
		BackgroundTransparency = if ATLAS == "" then 0 else 1,
		Parent = row,
	})
	Kit.text(text, "condensedMedium", 13, {
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(24, 0),
		Size = UDim2.new(1, -24, 1, 0),
		Parent = row,
	})
end

local function build(): Ui
	local pg = player:WaitForChild("PlayerGui")
	local mapGui = Kit.new("ScreenGui", {
		Name = "HC_Map",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = Theme.Layers.Pause - 1,
		Enabled = false,
		Parent = pg,
	})
	local backdrop = Kit.new("Frame", {
		Name = "Backdrop",
		Active = true,
		BackgroundColor3 = MAP_WATER,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		Parent = mapGui,
	})
	local world = Kit.new("Frame", {
		Name = "World",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(WORLD_SIZE, WORLD_SIZE),
		ZIndex = 1,
		Parent = backdrop,
	})
	local n = MinimapConfig.TILE_COUNT
	for r = 1, n do
		for c = 1, n do
			local id = MinimapConfig.TILES[r] and MinimapConfig.TILES[r][c] or ""
			Kit.new("ImageLabel", {
				Name = ("Tile%d_%d"):format(r, c),
				BackgroundColor3 = MinimapConfig.LAND_COLOR,
				BackgroundTransparency = if id == "" then 0.6 else 1,
				BorderSizePixel = 0,
				Image = id,
				Position = UDim2.fromScale((c - 1) / n, (r - 1) / n),
				Size = UDim2.new(1 / n, 1, 1 / n, 1),
				ZIndex = 1,
				Parent = world,
			})
		end
	end
	local routeR = MinimapController.newRouteRenderer(world, GPS.MAP_WIDTH, GPS.OUTLINE)
	-- soft edge vignette over the map (top + bottom bands)
	for _, top in { true, false } do
		local band = Kit.new("Frame", {
			Name = if top then "ShadeTop" else "ShadeBottom",
			BackgroundColor3 = Color3.new(0, 0, 0),
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, if top then 0 else 1),
			Position = UDim2.fromScale(0, if top then 0 else 1),
			Size = UDim2.fromScale(1, 0.22),
			ZIndex = 4,
			Parent = backdrop,
		})
		Kit.new("UIGradient", {
			Rotation = if top then 90 else -90,
			Transparency = NumberSequence.new(0.15, 1),
			Parent = band,
		})
	end
	local overlay = Kit.new("Frame", {
		Name = "Overlay",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 5,
		Parent = backdrop,
	})
	local labelLayer = Kit.new("Frame", {
		Name = "Labels",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Parent = overlay,
	})
	local blipLayer = Kit.new("Frame", {
		Name = "Blips",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 2,
		Parent = overlay,
	})
	local arrow = Kit.image("hud.arrow", {
		Name = "Player",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(36, 36),
		ZIndex = 3,
		Parent = overlay,
	})

	-- chrome (under the pause header: GPS line bottom-left, tools + legend right) --------------------------------------
	local chrome = Kit.screen("HC_MapChrome", Theme.Layers.Pause + 1, { touchMin = Theme.TouchMinScale })
	chrome.Enabled = false
	local hint = Kit.text("", "body", 14, {
		Name = "Hint",
		TextColor3 = C.TextDim,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0.16, 0, 0.82, 34),
		Size = UDim2.fromOffset(640, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = chrome,
	})

	-- GPS line (bottom-left of the content area)
	local gpsChip = Kit.panel({
		Name = "Gps",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0.16, 0.82),
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		Visible = false,
		Parent = chrome,
	})
	Kit.new("UIPadding", {
		PaddingLeft = UDim.new(0, 8),
		PaddingRight = UDim.new(0, 12),
		Parent = gpsChip,
	})
	Kit.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center).Parent =
		gpsChip
	local gpsIcon = atlasImage("pin", {
		Name = "Icon",
		Size = UDim2.fromOffset(20, 20),
		LayoutOrder = 1,
		Parent = gpsChip,
	})
	local gpsText = Kit.text("", "condensedMedium", 16, {
		Name = "Text",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
		LayoutOrder = 2,
		Parent = gpsChip,
	})

	-- zoom / recenter (flat squares, right edge of the content area)
	local tools = Kit.new("Frame", {
		Name = "Tools",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(0.84, 0.82),
		Size = UDim2.fromOffset(40, 132),
		BackgroundTransparency = 1,
		Parent = chrome,
	})
	Kit.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Bottom).Parent =
		tools
	local function toolButton(text: string, order: number): TextButton
		return Kit.button(text, nil, {
			Size = UDim2.fromOffset(40, 40),
			TextSize = 24,
			LayoutOrder = order,
			Parent = tools,
		})
	end
	local zoomIn = toolButton("+", 1)
	local zoomOut = toolButton("-", 2)
	local recenter = toolButton("", 3)
	recenter.Name = "Recenter"
	Kit.image("hud.arrow", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(20, 20),
		ZIndex = 4,
		Parent = recenter,
	})
	local clearButton = Kit.instructionButton(nil, "Clear waypoint", {
		Name = "ClearWaypoint",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(0.84, -52, 0.82, 0),
		Visible = false,
		Parent = chrome,
	})

	-- legend (right side of the content area, GTA pause-map style)
	local legend = Kit.panel({
		Name = "Legend",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(0.84, PAUSE_TOP + 0.02),
		Size = UDim2.fromOffset(190, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = chrome,
	})
	Kit.padding(8, 10).Parent = legend
	Kit.list(Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Left).Parent = legend
	Kit.text("LEGEND", "condensed", 14, {
		LayoutOrder = 0,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 22),
		Parent = legend,
	})
	local order = 1
	local B = MinimapConfig.BLIPS
	legendRow(legend, order, "garage", C.Blue, B.ownGarage.label)
	order += 1
	legendRow(legend, order, B.otherGarage.icon, C.TextDim, "Rival Garage")
	order += 1
	for _, def in MinimapConfig.POIS do
		legendRow(legend, order, def.icon, MinimapController.poiColor(def.id, def.color), def.label)
		order += 1
	end
	legendRow(legend, order, B.hotDrop.icon, C.Yellow, B.hotDrop.label)
	order += 1
	legendRow(legend, order, B.waypoint.icon, C.Waypoint, B.waypoint.label)
	order += 1
	legendRow(legend, order, B.police.icon, C.Red, B.police.label)
	local legendToggle = Kit.button("Legend", nil, {
		Name = "LegendToggle",
		Size = UDim2.fromOffset(110, 36),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(0.97, PAUSE_TOP + 0.02),
		Visible = false,
		Parent = chrome,
	})

	local u: Ui = {
		mapGui = mapGui,
		backdrop = backdrop,
		world = world,
		overlay = overlay,
		route = routeR,
		blips = { parent = blipLayer, items = {}, used = 0, shown = 0 },
		labels = { parent = labelLayer, items = {}, used = 0, shown = 0 },
		arrow = arrow,
		chrome = chrome,
		gpsChip = gpsChip,
		gpsIcon = gpsIcon,
		gpsText = gpsText,
		clearButton = clearButton,
		legend = legend,
		legendToggle = legendToggle,
		hint = hint,
	}

	local function zoomBy(factor: number)
		local lo, hi = limits()
		cx, cz, scale = MapScreenController.zoomAround(cx, cz, scale, factor, vpW / 2, vpH / 2, vpW, vpH, lo, hi)
		accum = math.huge
	end
	zoomIn.Activated:Connect(function()
		zoomBy(1.5)
	end)
	zoomOut.Activated:Connect(function()
		zoomBy(1 / 1.5)
	end)
	recenter.Activated:Connect(function()
		local p = rootPos()
		if p then
			cx, cz = MapScreenController.clampCenter(p.X, p.Z)
			local lo, hi = limits()
			scale = math.clamp(math.max(scale, lo * 2.5), lo, hi)
			accum = math.huge
		end
	end)
	clearButton.Activated:Connect(function()
		MinimapController.setCustomWaypoint(nil)
		pcall(SoundController.play, "Click")
		accum = math.huge
	end)
	legendToggle.Activated:Connect(function()
		legend.Visible = not legend.Visible
		legendToggle.Text = if legend.Visible then "HIDE" else "LEGEND"
	end)
	return u
end

-------------------------------------------------------------------------------------------------------------------------
-- Refresh (view + blips)
-------------------------------------------------------------------------------------------------------------------------

local function addHotspot(x: number, z: number, label: string, sx: number, sy: number)
	hotspotCount += 1
	local h = hotspots[hotspotCount]
	if h then
		h.x, h.z, h.label, h.sx, h.sy = x, z, label, sx, sy
	else
		hotspots[hotspotCount] = { x = x, z = z, label = label, sx = sx, sy = sy }
	end
end

-- per-frame scratch for waypoint blips
local wpScratchCount = 0
local wpIds: { string } = {}
local wpPos: { Vector3 } = {}
local wpColor: { Color3 } = {}
local function collectWaypoint(id: string, pos: Vector3, color: Color3, _label: string)
	wpScratchCount += 1
	wpIds[wpScratchCount] = id
	wpPos[wpScratchCount] = pos
	wpColor[wpScratchCount] = color
end

local poiCache: { { pos: Vector3, icon: string, color: Color3, label: string } }? = nil
local function poiList(): { { pos: Vector3, icon: string, color: Color3, label: string } }
	local cached = poiCache
	if cached then
		return cached
	end
	local list = {}
	for _, def in MinimapConfig.POIS do
		for _, pos in MinimapController.poiPositions(def.at) do
			table.insert(list, {
				pos = pos,
				icon = def.icon,
				color = MinimapController.poiColor(def.id, def.color),
				label = string.upper(def.label),
			})
		end
	end
	poiCache = list
	return list
end

local garageDoors: { Vector3 }? = nil
local function garageList(): { Vector3 }
	local cached = garageDoors
	if cached then
		return cached
	end
	local G = MapConfig.Garage
	local list = {}
	for i = 1, MapLayout.plotCount() do
		table.insert(list, MapLayout.plotToWorld(i, Vector3.new(0, 0, (G.FRONT_Z + G.DROPOFF_CENTER.Z) / 2)).Position)
	end
	garageDoors = list
	return list
end

local function refresh()
	local u = ui
	if not u then
		return
	end
	vpW, vpH = viewport()
	uiScale = Kit.uiScale(Theme.TouchMinScale)
	local lo, hi = limits()
	scale = math.clamp(scale, lo, hi)
	cx, cz = MapScreenController.clampCenter(cx, cz)

	-- map frame
	local ox, oy = MapScreenController.worldToScreen(WORLD_MIN.X, WORLD_MIN.Y, cx, cz, scale, vpW, vpH)
	u.world.Position = UDim2.fromOffset(ox, oy)
	u.world.Size = UDim2.fromOffset(WORLD_SIZE * scale, WORLD_SIZE * scale)

	local zoomLevel = scale / MapScreenController.fitScale(vpW, vpH, chromeTop())
	local blipSize = math.floor(MAP.BLIP_SIZE * uiScale * math.clamp(0.85 + zoomLevel * 0.08, 0.85, 1.25))
	hotspotCount = 0

	-- district labels
	local labelSize = math.floor(MAP.LABEL_SIZE * uiScale * math.clamp(0.9 + zoomLevel * 0.1, 0.9, 1.4))
	for _, d in MinimapConfig.DISTRICTS do
		if d.tier == 1 or zoomLevel >= 1.6 then
			local sx, sy = MapScreenController.worldToScreen(d.x, d.z, cx, cz, scale, vpW, vpH)
			if sx > -200 and sx < vpW + 200 and sy > -50 and sy < vpH + 50 then
				local size = if d.tier == 1 then labelSize else math.floor(labelSize * 0.78)
				labelPut(u.labels, d.name, size, Theme.Colors.Text, sx, sy, 1)
			end
		end
	end

	-- POIs
	for _, poi in poiList() do
		local sx, sy = MapScreenController.worldToScreen(poi.pos.X, poi.pos.Z, cx, cz, scale, vpW, vpH)
		blipPut(u.blips, poi.icon, poi.color, blipSize, sx, sy, 2)
		addHotspot(poi.pos.X, poi.pos.Z, poi.label, sx, sy)
	end
	-- garages
	local plots = Workspace:FindFirstChild("Plots")
	local me = player.UserId
	local B = MinimapConfig.BLIPS
	for i, door in garageList() do
		local model = if plots then plots:FindFirstChild("Plot" .. i) else nil
		local owner = if model then model:GetAttribute("OwnerUserId") else nil
		if typeof(owner) == "number" and owner ~= 0 then
			local mine = owner == me
			local sx, sy = MapScreenController.worldToScreen(door.X, door.Z, cx, cz, scale, vpW, vpH)
			local def = if mine then B.ownGarage else B.otherGarage
			local garageColor = if mine then C.Blue else C.TextDim
			blipPut(
				u.blips,
				def.icon,
				garageColor,
				if mine then blipSize + 6 else blipSize,
				sx,
				sy,
				if mine then 4 else 3
			)
			local name = if mine then "YOUR GARAGE" else nil
			if not mine and model then
				local ownerName = model:GetAttribute("OwnerName")
				if typeof(ownerName) == "string" and ownerName ~= "" then
					name = string.upper(ownerName) .. "'S GARAGE"
				end
			end
			if name and zoomLevel >= 1.3 then
				labelPut(
					u.labels,
					name,
					math.floor(13 * uiScale),
					garageColor,
					sx,
					sy + blipSize * 0.5 + 10 * uiScale,
					2
				)
			end
			addHotspot(door.X, door.Z, name or "GARAGE", sx, sy)
		end
	end
	-- police
	for _, model in MinimapController.getPolice() do
		if model.PrimaryPart then
			local p = (model.PrimaryPart :: BasePart).Position
			local sx, sy = MapScreenController.worldToScreen(p.X, p.Z, cx, cz, scale, vpW, vpH)
			local red = MinimapController.flashOn(clock, MinimapConfig.RADAR.WANTED_FLASH_HZ)
			blipPut(
				u.blips,
				B.police.icon,
				if red and model:GetAttribute("Siren") == true then C.Red else C.Blue,
				math.floor(blipSize * 0.55),
				sx,
				sy,
				3
			)
		end
	end
	-- waypoints (on top)
	wpScratchCount = 0
	WaypointController.each(collectWaypoint)
	local gpsId = MinimapController.getGpsTarget()
	for i = 1, wpScratchCount do
		local pos = wpPos[i]
		local sx, sy = MapScreenController.worldToScreen(pos.X, pos.Z, cx, cz, scale, vpW, vpH)
		local size = blipSize + 6
		if wpIds[i] == gpsId then
			size += math.floor((2 + 2 * math.sin(clock * 5)) * uiScale)
		end
		blipPut(u.blips, MinimapController.waypointIcon(wpIds[i]), wpColor[i], size, sx, sy, 5)
	end
	blipEnd(u.blips)
	labelEnd(u.labels)

	-- you
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		local p = root.Position
		local sx, sy = MapScreenController.worldToScreen(p.X, p.Z, cx, cz, scale, vpW, vpH)
		local look = root.CFrame.LookVector
		u.arrow.Position = UDim2.fromOffset(sx, sy)
		u.arrow.Rotation = MinimapController.headingOf(look.X, look.Z)
		u.arrow.Size = UDim2.fromOffset(math.floor(38 * uiScale), math.floor(38 * uiScale))
		u.arrow.Visible = true
	else
		u.arrow.Visible = false
	end

	-- chrome state
	local custom = MinimapController.getCustomWaypoint()
	u.clearButton.Visible = custom ~= nil
end

local function refreshRoute()
	local u = ui
	if not u then
		return
	end
	local pts, color, target = MinimapController.getRoute()
	u.route.width = GPS.MAP_WIDTH * uiScale
	u.route.outline = GPS.OUTLINE * uiScale
	if pts and color then
		local p = rootPos()
		local first, sx, sz = 1, pts[1].X, pts[1].Z
		if p then
			local _, seg, _, proj = RoadGraph.projectToPolyline(pts, p)
			first, sx, sz = seg, proj.X, proj.Z
		end
		MinimapController.drawRoute(u.route, pts, first, sx, sz, color, target)
		local id = MinimapController.getGpsTarget()
		local cell = cellOf(MinimapController.waypointIcon(id or ""))
		if cell then
			u.gpsIcon.ImageRectOffset = Vector2.new(cell[1], cell[2])
			u.gpsIcon.ImageRectSize = Vector2.new(cell[3], cell[4])
		end
		u.gpsIcon.ImageColor3 = color
		local label = "GPS"
		if id then
			WaypointController.each(function(wid, _pos, _color, wlabel)
				if wid == id then
					label = wlabel
				end
			end)
		end
		u.gpsText.Text = ("%s  ·  %s"):format(
			string.upper(label),
			WaypointController.formatDistance(MinimapController.getRemaining())
		)
		u.gpsChip.Visible = true
	else
		MinimapController.drawRoute(u.route, nil, 1, 0, 0, WHITE, nil)
		u.gpsChip.Visible = false
	end
end

local function step(dt: number)
	if not isOpen then
		return
	end
	clock += dt
	accum += dt
	routeAccum += dt
	if accum >= UPDATE_DT then
		accum = 0
		refresh()
	end
	if routeAccum >= 0.5 then
		routeAccum = 0
		refreshRoute()
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Input
-------------------------------------------------------------------------------------------------------------------------

local function inputPos(input: InputObject): Vector2
	-- InputObject positions exclude the topbar inset; the map gui ignores it
	local inset = GuiService:GetGuiInset()
	return Vector2.new(input.Position.X, input.Position.Y) + inset
end

local function onTap(at: Vector2)
	-- tap your waypoint again: remove it
	local custom = MinimapController.getCustomWaypoint()
	if custom then
		local sx, sy = MapScreenController.worldToScreen(custom.X, custom.Z, cx, cz, scale, vpW, vpH)
		if (Vector2.new(sx, sy) - at).Magnitude <= MAP.CLEAR_RADIUS * uiScale then
			MinimapController.setCustomWaypoint(nil)
			pcall(SoundController.play, "Click")
			accum = math.huge
			return
		end
	end
	-- tapped a blip: drop the waypoint right on it
	local best, bestD = 0, MAP.BLIP_SIZE * 0.8 * uiScale
	for i = 1, hotspotCount do
		local h = hotspots[i]
		local d = (Vector2.new(h.sx, h.sy) - at).Magnitude
		if d < bestD then
			best, bestD = i, d
		end
	end
	local wx, wz
	local label = CUSTOM.LABEL
	if best > 0 then
		local h = hotspots[best]
		wx, wz, label = h.x, h.z, h.label
	else
		wx, wz = MapScreenController.screenToWorld(at.X, at.Y, cx, cz, scale, vpW, vpH)
	end
	local lim = MapConfig.BOUNDARY - 10
	wx, wz = math.clamp(wx, -lim, lim), math.clamp(wz, -lim, lim)
	MinimapController.setCustomWaypoint(Vector3.new(wx, MapConfig.ROAD_Y, wz), label)
	pcall(SoundController.play, "ClickBright")
	accum = math.huge
	routeAccum = 0.4 -- show the new route almost immediately (the radar re-routes on its next frame)
end

local function countPresses(): number
	local n = 0
	for _ in presses do
		n += 1
	end
	return n
end

local function pinchState(): (number, Vector2)
	local a: Vector2?, b: Vector2? = nil, nil
	for _, pr in presses do
		if a == nil then
			a = pr.last
		elseif b == nil then
			b = pr.last
		end
	end
	if a and b then
		return (a - b).Magnitude, (a + b) / 2
	end
	return 0, a or Vector2.zero
end

local function bindInput(u: Ui)
	u.backdrop.InputBegan:Connect(function(input: InputObject)
		if not isOpen then
			return
		end
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			local p = inputPos(input)
			presses[input] = { start = p, last = p, t = os.clock(), moved = 0 }
			pressCount = countPresses()
			if pressCount >= 2 then
				pinchDist, pinchMid = pinchState()
				for _, pr in presses do
					pr.moved = math.huge -- a pinch is never a tap
				end
			end
		end
	end)
	u.backdrop.InputChanged:Connect(function(input: InputObject)
		if not isOpen then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			local p = inputPos(input)
			local lo, hi = limits()
			local factor = if input.Position.Z > 0 then MAP.WHEEL_STEP else 1 / MAP.WHEEL_STEP
			cx, cz, scale = MapScreenController.zoomAround(cx, cz, scale, factor, p.X, p.Y, vpW, vpH, lo, hi)
			accum = math.huge
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if not isOpen then
			return
		end
		local t = input.UserInputType
		local pr: Press? = nil
		if t == Enum.UserInputType.Touch then
			pr = presses[input]
		elseif t == Enum.UserInputType.MouseMovement then
			for key, value in presses do
				if key.UserInputType == Enum.UserInputType.MouseButton1 then
					pr = value
				end
			end
		end
		if not pr then
			return
		end
		local p = inputPos(input)
		local delta = p - pr.last
		pr.last = p
		pr.moved = math.max(pr.moved, (p - pr.start).Magnitude)
		if pressCount >= 2 then
			local dist, mid = pinchState()
			if pinchDist > 1 and dist > 1 then
				local lo, hi = limits()
				cx, cz, scale =
					MapScreenController.zoomAround(cx, cz, scale, dist / pinchDist, mid.X, mid.Y, vpW, vpH, lo, hi)
			end
			local pan = mid - pinchMid
			cx, cz = MapScreenController.clampCenter(cx - pan.X / scale, cz - pan.Y / scale)
			pinchDist, pinchMid = dist, mid
		elseif pr.moved > MAP.TAP_SLOP then
			cx, cz = MapScreenController.clampCenter(cx - delta.X / scale, cz - delta.Y / scale)
		end
		accum = math.huge
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		local pr = presses[input]
		if not pr then
			return
		end
		presses[input] = nil
		pressCount = countPresses()
		if pressCount >= 2 then
			pinchDist, pinchMid = pinchState()
		end
		if isOpen and pressCount == 0 and MapScreenController.isTap(pr.moved, os.clock() - pr.t) then
			onTap(pr.start)
		end
	end)
end

-------------------------------------------------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------------------------------------------------

function MapScreenController.isOpen(): boolean
	return isOpen
end

local function lazyMenu(): any
	local mod = script.Parent:FindFirstChild("MenuController")
	if not (mod and mod:IsA("ModuleScript")) then
		return nil
	end
	local ok, result = pcall(require, mod :: any)
	return if ok and typeof(result) == "table" and typeof(result.openPause) == "function" then result else nil
end

-- Draw the map (the pause menu's MAP tab calls this when the tab shows).
function MapScreenController.show()
	local u = ui
	if not u or isOpen then
		return
	end
	isOpen = true
	table.clear(presses)
	pressCount = 0
	vpW, vpH = viewport()
	local lo = limits()
	scale = lo
	cx, cz = 0, MapScreenController.fitCenterZ(scale, chromeTop())
	local touch = Kit.isTouch()
	u.hint.Text = if touch
		then "Tap to set a waypoint  ·  Pinch to zoom  ·  Drag to move"
		else "Click to set a waypoint  ·  Scroll to zoom  ·  Drag to move"
	u.legend.Visible = not touch
	u.legendToggle.Visible = touch
	u.legendToggle.Text = "LEGEND"
	u.mapGui.Enabled = true
	u.chrome.Enabled = true
	accum = math.huge
	routeAccum = math.huge
	step(0)
end

function MapScreenController.hide()
	local u = ui
	if not u or not isOpen then
		return
	end
	isOpen = false
	table.clear(presses)
	pressCount = 0
	u.mapGui.Enabled = false
	u.chrome.Enabled = false
end

-- Open the full map: the pause menu on its MAP tab (or the bare map without a MenuController).
function MapScreenController.open()
	local menu = lazyMenu()
	if menu then
		pcall(menu.openPause, "MAP")
		return
	end
	MapScreenController.show()
	pcall(SoundController.play, "Whoosh")
end

function MapScreenController.close()
	local menu = lazyMenu()
	if menu and typeof(menu.closePause) == "function" then
		pcall(menu.closePause)
	end
	MapScreenController.hide()
end

function MapScreenController.toggle()
	local menu = lazyMenu()
	local pauseOpen = menu ~= nil and typeof(menu.isPauseOpen) == "function" and menu.isPauseOpen()
	if isOpen or pauseOpen then
		MapScreenController.close()
	else
		MapScreenController.open()
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

function MapScreenController.init() end

function MapScreenController.start()
	local u = build()
	ui = u
	bindInput(u)
	MinimapController.RouteChanged:Connect(function()
		if isOpen then
			routeAccum = math.huge
		end
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == MAP.KEY then
			MapScreenController.toggle()
		end
	end)
	RunService.RenderStepped:Connect(function(dt: number)
		if isOpen then
			debug.profilebegin("HC_MapScreen")
			step(dt)
			debug.profileend()
		end
	end)
end

return MapScreenController
