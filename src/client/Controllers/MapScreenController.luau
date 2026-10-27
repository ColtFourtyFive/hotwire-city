--!strict
-- MapScreenController: the full city map, shown as the pause menu's MAP tab (gta_ui_language §2.13, §5.12).
--
--  * Open with M (straight to the MAP tab), P then Q / E, by clicking / tapping the radar, or
--    MapScreenController.open(), which asks MenuController for the pause menu on MAP; the pause menu calls show() /
--    hide() as the tab changes. Without a MenuController it shows on its own. Close with Backspace / B or M again.
--    Gamepad players open it from the pause menu (D-pad up belongs to the phone, §5.11).
--  * Gamepad (bound while shown, sinks the character / driving binds): left stick pans, LT / RT or the right stick
--    zoom, A sets the waypoint under the center reticle (on it: clears it), X clears, Y finds you, B closes.
--  * Pan by dragging (mouse or one finger), zoom with the mouse wheel (around the cursor), a pinch (around the
--    fingers) or the +/- buttons; the target button re-centers on you.
--  * Click / tap the map to set your waypoint (WaypointController id Config/Minimap.CUSTOM_WAYPOINT.ID: the GPS route
--    on the radar); tapping a blip drops the waypoint right on that place. Tap your waypoint again (or Clear
--    waypoint) to remove it.
--  * Shows the same map art as the radar, district names (Oswald labels, nothing baked; they step aside from blips),
--    every blip in the GTA palette (shops / landmarks white, your garage blue, rivals grey with their names,
--    waypoints, police red / blue, the chopper, other players), the GPS route and you. The legend sits top-right of
--    the content area (touch: behind a Legend button) and takes 2-3 columns or scrolls when it would reach the tools.
--  * Presses that land on the chrome (buttons, legend, GPS line) never also drop a waypoint (overChrome).
--  * Map layer: a raw ScreenGui (no UIScale) under the pause chrome so input math stays in real pixels; the map's
--    own chrome (GPS line, tools, legend) is a Kit.screen with the usual scaling.
--
-- Public API: open(), close(), toggle(), isOpen(), show(), hide()
-- Pure helpers (tests): fitScale, fitCenterZ, worldToScreen, screenToWorld, zoomAround, clampCenter, isTap,
--   legendEntries, legendLayout, placeLabel, chromeTopFor.

local ContextActionService = game:GetService("ContextActionService")
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
local PauseMenu = require(UI:WaitForChild("PauseMenu"))

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
-- legend panel (design px): heading row, panel padding, grid rows / columns and gaps
local LEGEND_HEADER = 24
local LEGEND_PAD = 8
local LEGEND_ROW = 20
local LEGEND_COLUMN = 170
local LEGEND_COLUMN_GAP = 8
local LEGEND_ROW_GAP = 0
local LEGEND_GAP = 8 -- below the pause tabs, above the bottom row
-- zoom / recenter: a row of flat squares at the content area's bottom-right
local TOOL_SIZE = 36
local TOOL_SIZE_TOUCH = 48
local TOOL_GAP = 6
local ACTION_PAD = "HC_MapPad"
local PAD_PRIORITY = Enum.ContextActionPriority.High.Value + 100 -- above VehicleClient's driving binds and the pause menu

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

export type LegendEntry = { icon: string, color: Color3, text: string }

-- Legend rows (GTA palette), in order: garages, the fixed POIs, then the dynamic blips.
function MapScreenController.legendEntries(): { LegendEntry }
	local B = MinimapConfig.BLIPS
	local list: { LegendEntry } = {
		{ icon = "garage", color = C.Blue, text = B.ownGarage.label },
		{ icon = B.otherGarage.icon, color = C.TextDim, text = "Rival Garage" },
	}
	for _, def in MinimapConfig.POIS do
		table.insert(list, { icon = def.icon, color = MinimapController.poiColor(def.id, def.color), text = def.label })
	end
	table.insert(list, { icon = B.hotDrop.icon, color = C.Yellow, text = B.hotDrop.label })
	table.insert(list, { icon = B.waypoint.icon, color = C.Waypoint, text = B.waypoint.label })
	table.insert(list, { icon = B.police.icon, color = C.Red, text = B.police.label })
	table.insert(list, { icon = B.heli.icon, color = C.Red, text = B.heli.label })
	table.insert(list, { icon = B.player.icon, color = C.Freemode, text = "Other Players" })
	return list
end

-- Real px the pause header + tabs take at the top of a `screenH` px tall screen (the fit view starts below it).
function MapScreenController.chromeTopFor(screenH: number, touch: boolean?): number
	return screenH * PauseMenu.frame(touch == true).top
end

-- Height (design px) of the zoom / recenter row at the content area's bottom-right.
function MapScreenController.toolSize(touch: boolean): number
	return if touch then TOOL_SIZE_TOUCH else TOOL_SIZE
end

export type LegendLayout = {
	cols: number,
	width: number,
	height: number,
	right: number, -- design px from the canvas left to the panel's right edge (the content area's right edge)
	top: number, -- design px from the canvas top to the panel's top edge
	scrolls: boolean,
}

-- Legend panel for `count` rows on the chrome canvas (design px, inset-relative), in the pause menu's content area
-- (PauseMenu.frame): top-right under the tabs, never down into the bottom row (zoom / recenter, and on touch the
-- Legend button that shows it). One column on desktop, two when one would scroll and two still take under half the
-- content width; touch starts at two and takes three when that stops the scrolling and fits. Rows scroll otherwise.
function MapScreenController.legendLayout(count: number, canvasW: number, canvasH: number, touch: boolean): LegendLayout
	local F = PauseMenu.frame(touch)
	local right = canvasW * F.right
	local contentW = canvasW * (F.right - F.left)
	local top = canvasH * F.top + LEGEND_GAP
	local toolsTop = canvasH * F.bottom - MapScreenController.toolSize(touch)
	local maxH = toolsTop - LEGEND_GAP - top
	local minH = LEGEND_PAD * 2 + LEGEND_HEADER + LEGEND_ROW
	local function shape(cols: number): (number, number)
		local rows = math.max(1, math.ceil(count / cols))
		local full = LEGEND_PAD * 2 + LEGEND_HEADER + rows * LEGEND_ROW + (rows - 1) * LEGEND_ROW_GAP
		local width = LEGEND_PAD * 2 + cols * LEGEND_COLUMN + (cols - 1) * LEGEND_COLUMN_GAP
		return full, width
	end
	local cols = if touch then 2 else 1
	local full, width = shape(cols)
	local more = cols + 1
	local fullMore, widthMore = shape(more)
	local roomFor = if touch then contentW - 16 else contentW * 0.45
	if full > maxH and widthMore <= roomFor then
		cols, full, width = more, fullMore, widthMore
	end
	local height = math.max(math.min(full, maxH), minH)
	local scrolls = height < full
	if scrolls then
		width += 8 -- room for the scroll bar
	end
	return { cols = cols, width = width, height = height, right = right, top = top, scrolls = scrolls }
end

-- Where a district name (box centered at x, y with half sizes hw, hh; screen px) can go without covering a blip or
-- another name: the first of y, one step up, one down, two up, two down whose box clears every obstacle box (centers
-- obsX / obsY, half sizes obsW / obsH). nil when none does (the name is skipped this frame).
function MapScreenController.placeLabel(
	x: number,
	y: number,
	hw: number,
	hh: number,
	obsX: { number },
	obsY: { number },
	obsW: { number },
	obsH: { number },
	n: number
): number?
	local step = hh * 2 + 4
	for _, k in { 0, -1, 1, -2, 2 } do
		local cy = y + k * step
		local clear = true
		for i = 1, n do
			if math.abs(obsX[i] - x) < hw + obsW[i] and math.abs(obsY[i] - cy) < hh + obsH[i] then
				clear = false
				break
			end
		end
		if clear then
			return cy
		end
	end
	return nil
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
	legendRows: ScrollingFrame,
	legendGrid: UIGridLayout,
	legendToggle: TextButton,
	hint: TextLabel,
	reticle: Frame,
	tools: Frame,
	zoomIn: TextButton,
	zoomOut: TextButton,
	recenter: TextButton,
	blockers: { GuiObject }, -- chrome a press must not fall through to the map from (overChrome)
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
-- gamepad (ContextActionService while open): left stick pans, LT / RT and the right stick zoom
local padStick = Vector2.zero
local padZoom = 0 -- right stick Y
local padIn, padOut = 0, 0 -- RT / LT pressure
local padBound = false

local function cellOf(icon: string): { number }?
	return MinimapController.cellOf(icon)
end

-- Real px of the map gui (1280x720 when nothing is measurable, e.g. headless).
local function viewport(): (number, number)
	local ok, size = pcall(function(): Vector2
		local u = ui
		if u then
			local abs = u.backdrop.AbsoluteSize
			if abs.X > 1 and abs.Y > 1 then
				return abs
			end
		end
		local cam = Workspace.CurrentCamera
		return if cam then cam.ViewportSize else Vector2.zero
	end)
	if ok and size.X > 1 and size.Y > 1 then
		return size.X, size.Y
	end
	return 1280, 720
end

-- Real px the pause header + tabs take at the top of the screen.
local function chromeTop(): number
	return MapScreenController.chromeTopFor(vpH, Kit.isTouch())
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
	-- sized by the legend's UIGridLayout (LEGEND_COLUMN x LEGEND_ROW)
	local row = Kit.new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, LEGEND_ROW),
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

	-- chrome (in the pause menu's content area: GPS line + hint bottom-left, tools bottom-right, legend top-right) -------
	local chrome = Kit.screen("HC_MapChrome", Theme.Layers.Pause + 1, { touchMin = Theme.TouchMinScale })
	chrome.Enabled = false
	local hint = Kit.text("", "body", 14, {
		Name = "Hint",
		TextColor3 = C.TextDim,
		AnchorPoint = Vector2.new(0, 0),
		Size = UDim2.fromOffset(640, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = chrome,
	})

	-- GPS line (bottom-left of the content area)
	local gpsChip = Kit.panel({
		Name = "Gps",
		AnchorPoint = Vector2.new(0, 1),
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

	-- zoom / recenter: a row of flat squares at the content area's bottom-right
	local tools = Kit.new("Frame", {
		Name = "Tools",
		AnchorPoint = Vector2.new(1, 1),
		BackgroundTransparency = 1,
		Parent = chrome,
	})
	Kit.list(Enum.FillDirection.Horizontal, TOOL_GAP, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Bottom).Parent =
		tools
	local function toolButton(text: string, order: number): TextButton
		return Kit.button(text, nil, {
			Size = UDim2.fromOffset(TOOL_SIZE, TOOL_SIZE),
			TextSize = 24,
			LayoutOrder = order,
			Parent = tools,
		})
	end
	local zoomIn = toolButton("+", 1)
	zoomIn.Name = "ZoomIn"
	local zoomOut = toolButton("-", 2)
	zoomOut.Name = "ZoomOut"
	local recenter = toolButton("", 3)
	recenter.Name = "Recenter"
	Kit.image("hud.arrow", {
		Name = "Glyph",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(20, 20),
		ZIndex = 4,
		Parent = recenter,
	})
	local clearButton = Kit.instructionButton(nil, "Clear waypoint", {
		Name = "ClearWaypoint",
		AnchorPoint = Vector2.new(1, 1),
		Visible = false,
		Parent = chrome,
	})

	-- legend (top-right of the content area; on touch a panel toggled by its Legend button in the bottom row). Rows sit
	-- in a grid inside a scroll frame: legendLayout picks the columns and caps the height above the bottom row.
	local legend = Kit.panel({
		Name = "Legend",
		Active = true,
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(190, 300),
		Parent = chrome,
	})
	Kit.padding(LEGEND_PAD, LEGEND_PAD + 2).Parent = legend
	Kit.text("LEGEND", "condensed", 14, {
		Name = "Heading",
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, LEGEND_HEADER - 2),
		Parent = legend,
	})
	local legendRows = Kit.new("ScrollingFrame", {
		Name = "Rows",
		Active = true,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, LEGEND_HEADER),
		Size = UDim2.new(1, 0, 1, -LEGEND_HEADER),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.TextDim,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = legend,
	})
	local legendGrid = Kit.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(LEGEND_COLUMN, LEGEND_ROW),
		CellPadding = UDim2.fromOffset(LEGEND_COLUMN_GAP, LEGEND_ROW_GAP),
		FillDirection = Enum.FillDirection.Horizontal,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = legendRows,
	})
	local order = 1
	for _, row in MapScreenController.legendEntries() do
		legendRow(legendRows, order, row.icon, row.color, row.text)
		order += 1
	end
	local legendToggle = Kit.button("Legend", nil, {
		Name = "LegendToggle",
		Size = UDim2.fromOffset(110, TOOL_SIZE_TOUCH),
		AnchorPoint = Vector2.new(1, 1),
		Visible = false,
		Parent = chrome,
	})

	-- gamepad: the waypoint goes where this center reticle points
	local reticle = Kit.new("Frame", {
		Name = "Reticle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(44, 44),
		Visible = false,
		ZIndex = 6,
		Parent = backdrop,
	})
	Kit.new("UICorner", { CornerRadius = UDim.new(1, 0), Parent = reticle })
	Kit.new("UIStroke", { Color = WHITE, Thickness = 2, Transparency = 0.1, Parent = reticle })
	for i = 0, 3 do
		local vertical = i % 2 == 0
		Kit.new("Frame", {
			Name = "Tick",
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = WHITE,
			BorderSizePixel = 0,
			Position = UDim2.new(
				0.5,
				if vertical then 0 elseif i == 1 then 26 else -26,
				0.5,
				if not vertical then 0 elseif i == 0 then -26 else 26
			),
			Size = UDim2.fromOffset(if vertical then 2 else 12, if vertical then 12 else 2),
			ZIndex = 6,
			Parent = reticle,
		})
	end

	-- chrome that swallows presses (Active) and that onTap ignores even if the engine lets the press through
	for _, g in { hint, gpsChip, tools } do
		(g :: GuiObject).Active = true
	end
	local blockers: { GuiObject } =
		{ hint, gpsChip, tools, zoomIn, zoomOut, recenter, clearButton, legend, legendToggle }

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
		legendRows = legendRows,
		legendGrid = legendGrid,
		legendToggle = legendToggle,
		hint = hint,
		reticle = reticle,
		tools = tools,
		zoomIn = zoomIn,
		zoomOut = zoomOut,
		recenter = recenter,
		blockers = blockers,
	}
	return u
end

-- Button handlers (kept out of build() so the UI can be built headlessly: MapScreenController.mount).
local function wireButtons(u: Ui)
	local function zoomBy(factor: number)
		local lo, hi = limits()
		cx, cz, scale = MapScreenController.zoomAround(cx, cz, scale, factor, vpW / 2, vpH / 2, vpW, vpH, lo, hi)
		accum = math.huge
	end
	u.zoomIn.Activated:Connect(function()
		zoomBy(1.5)
	end)
	u.zoomOut.Activated:Connect(function()
		zoomBy(1 / 1.5)
	end)
	u.recenter.Activated:Connect(function()
		local p = rootPos()
		if p then
			cx, cz = MapScreenController.clampCenter(p.X, p.Z)
			local lo, hi = limits()
			scale = math.clamp(math.max(scale, lo * 2.5), lo, hi)
			accum = math.huge
		end
	end)
	u.clearButton.Activated:Connect(function()
		MinimapController.setCustomWaypoint(nil)
		pcall(SoundController.play, "Click")
		accum = math.huge
	end)
	u.legendToggle.Activated:Connect(function()
		u.legend.Visible = not u.legend.Visible
		u.legendToggle.Text = if u.legend.Visible then "Hide" else "Legend"
	end)
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

-- per-frame scratch: boxes (screen px; center + half sizes) the district names step aside from: static blips, then
-- the names already placed
local obsX: { number } = {}
local obsY: { number } = {}
local obsW: { number } = {}
local obsH: { number } = {}
local obsCount = 0
local function addObstacle(x: number, y: number, hw: number, hh: number)
	obsCount += 1
	obsX[obsCount] = x
	obsY[obsCount] = y
	obsW[obsCount] = hw
	obsH[obsCount] = hh
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
	obsCount = 0
	local obstacleHalf = blipSize * 0.5 + 2

	-- POIs
	for _, poi in poiList() do
		local sx, sy = MapScreenController.worldToScreen(poi.pos.X, poi.pos.Z, cx, cz, scale, vpW, vpH)
		blipPut(u.blips, poi.icon, poi.color, blipSize, sx, sy, 2)
		addHotspot(poi.pos.X, poi.pos.Z, poi.label, sx, sy)
		addObstacle(sx, sy, obstacleHalf, obstacleHalf)
	end
	-- garages
	local plots = Workspace:FindFirstChild("Plots")
	local me = player.UserId
	local B = MinimapConfig.BLIPS
	local ownerSize = math.max(MAP.OWNER_LABEL_MIN, math.floor(MAP.OWNER_LABEL_SIZE * uiScale))
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
				labelPut(u.labels, name, ownerSize, garageColor, sx, sy + blipSize * 0.5 + ownerSize * 0.5 + 4, 2)
			end
			addHotspot(door.X, door.Z, name or "GARAGE", sx, sy)
			addObstacle(sx, sy, obstacleHalf, obstacleHalf)
		end
	end
	-- other players (small dots, lowest)
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local char = other.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				local p = root.Position
				local sx, sy = MapScreenController.worldToScreen(p.X, p.Z, cx, cz, scale, vpW, vpH)
				blipPut(u.blips, B.player.icon, C.Freemode, math.floor(blipSize * 0.5), sx, sy, 1)
			end
		end
	end
	-- police cars + chopper (flash red / blue while the siren is on)
	local red = MinimapController.flashOn(clock, MinimapConfig.RADAR.WANTED_FLASH_HZ)
	for i, model in MinimapController.getPolice() do
		if model.PrimaryPart then
			local p = (model.PrimaryPart :: BasePart).Position
			local sx, sy = MapScreenController.worldToScreen(p.X, p.Z, cx, cz, scale, vpW, vpH)
			local siren = model:GetAttribute("Siren") == true
			local flash = siren and MinimapController.flashOn(clock, MinimapConfig.RADAR.WANTED_FLASH_HZ, i)
			blipPut(u.blips, B.police.icon, if flash then C.Red else C.Blue, math.floor(blipSize * 0.55), sx, sy, 3)
		end
	end
	for _, model in MinimapController.getHelis() do
		if model.PrimaryPart then
			local p = (model.PrimaryPart :: BasePart).Position
			local sx, sy = MapScreenController.worldToScreen(p.X, p.Z, cx, cz, scale, vpW, vpH)
			blipPut(u.blips, B.heli.icon, if red then C.Red else C.Blue, blipSize, sx, sy, 3)
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
		addObstacle(sx, sy, obstacleHalf, obstacleHalf)
	end
	blipEnd(u.blips)

	-- district labels (UI text, nothing baked): step aside from the blips placed above
	local labelSize = math.floor(MAP.LABEL_SIZE * uiScale * math.clamp(0.9 + zoomLevel * 0.1, 0.9, 1.4))
	for _, d in MinimapConfig.DISTRICTS do
		if d.tier == 1 or zoomLevel >= 1.6 then
			local sx, sy = MapScreenController.worldToScreen(d.x, d.z, cx, cz, scale, vpW, vpH)
			if sx > -200 and sx < vpW + 200 and sy > -50 and sy < vpH + 50 then
				local size = if d.tier == 1 then labelSize else math.floor(labelSize * 0.78)
				-- display font, all caps: ~0.62 em per glyph
				local hw, hh = #d.name * size * 0.31, (size + 6) / 2
				local y = MapScreenController.placeLabel(sx, sy, hw, hh, obsX, obsY, obsW, obsH, obsCount)
				if y then
					labelPut(u.labels, d.name, size, C.Text, sx, y, 1)
					addObstacle(sx, y, hw + 2, hh + 2)
				end
			end
		end
	end
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

-- Radial deadzone, rescaled so the stick still reaches 1 at full tilt.
local function deadzone(v: Vector2): Vector2
	local m = v.Magnitude
	if m <= MAP.PAD_DEADZONE then
		return Vector2.zero
	end
	return v.Unit * math.min(1, (m - MAP.PAD_DEADZONE) / (1 - MAP.PAD_DEADZONE))
end

local function padStep(dt: number)
	local stick = deadzone(padStick)
	if stick.Magnitude > 0 then
		-- stick up = north (screen up); the speed is in screen px so it feels the same at every zoom
		local px = MAP.PAD_PAN_SPEED * dt * uiScale
		cx, cz = MapScreenController.clampCenter(cx + stick.X * px / scale, cz - stick.Y * px / scale)
		accum = math.huge
	end
	local z = padIn - padOut
	if math.abs(padZoom) > MAP.PAD_DEADZONE then
		z += padZoom
	end
	if math.abs(z) > 0.05 then
		local lo, hi = limits()
		local factor = MAP.PAD_ZOOM_RATE ^ (math.clamp(z, -1, 1) * dt)
		cx, cz, scale = MapScreenController.zoomAround(cx, cz, scale, factor, vpW / 2, vpH / 2, vpW, vpH, lo, hi)
		accum = math.huge
	end
end

local function step(dt: number)
	if not isOpen then
		return
	end
	clock += dt
	accum += dt
	routeAccum += dt
	if padBound then
		padStep(dt)
	end
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

-- Is the (inset-relative) press position on a chrome element (hint, buttons, legend, GPS line)? Those take
-- the press themselves; it must not also drop a waypoint on the map underneath, whatever the engine's input sinking
-- does across the two ScreenGuis.
local function overChrome(raw: Vector2): boolean
	local u = ui
	if not (u and u.chrome.Enabled) then
		return false
	end
	local ok, hit = pcall(function(): boolean
		for _, g in u.blockers do
			if g.Visible then
				local p, size = g.AbsolutePosition, g.AbsoluteSize
				if raw.X >= p.X and raw.X <= p.X + size.X and raw.Y >= p.Y and raw.Y <= p.Y + size.Y then
					return true
				end
			end
		end
		return false
	end)
	return ok and hit
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
			if overChrome(Vector2.new(input.Position.X, input.Position.Y)) then
				return
			end
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

local function isGamepad(): boolean
	local ok, last = pcall(function()
		return UserInputService:GetLastInputType()
	end)
	return ok and typeof(last) == "EnumItem" and string.sub(last.Name, 1, 7) == "Gamepad"
end

-- Design canvas of the chrome ScreenGui (inset-relative; touch scale floor Theme.TouchMinScale).
local function chromeCanvas(u: Ui): (number, number)
	local size = Kit.canvasSize(u.chrome)
	return size.X, size.Y
end

-- Chrome placement in the pause menu's content area (PauseMenu.frame) + hint text + gamepad reticle for the current
-- input type. The legend starts hidden behind its Legend button on touch and always shows otherwise (re-applied
-- when the input type flips while open).
local chromeTouch: boolean? = nil
local function applyChrome(u: Ui, reset: boolean?)
	local touch = Kit.isTouch()
	if reset or touch ~= chromeTouch then
		chromeTouch = touch
		u.legend.Visible = not touch
		u.legendToggle.Text = "Legend"
	end
	local pad = not touch and isGamepad()
	local w, h = chromeCanvas(u)
	local F = PauseMenu.frame(touch)
	local left, right = w * F.left, w * F.right
	local bottom = h * F.bottom
	-- tools row bottom-right, Clear waypoint left of it, the GPS line bottom-left, the hint just under the content
	local ts = MapScreenController.toolSize(touch)
	for _, b in { u.zoomIn, u.zoomOut, u.recenter } do
		b.Size = UDim2.fromOffset(ts, ts)
	end
	local toolsW = ts * 3 + TOOL_GAP * 2
	u.tools.Size = UDim2.fromOffset(toolsW, ts)
	u.tools.Position = UDim2.fromOffset(right, bottom)
	-- touch: the Legend button joins the bottom row, left of the tools
	local rowX = right - toolsW - 10
	u.legendToggle.Size = UDim2.fromOffset(110, ts)
	u.legendToggle.Position = UDim2.fromOffset(rowX, bottom)
	if touch then
		rowX -= 110 + 10
	end
	u.clearButton.Position = UDim2.fromOffset(rowX, bottom)
	u.gpsChip.Position = UDim2.fromOffset(left, bottom)
	u.hint.Position = UDim2.fromOffset(left, bottom + 8)
	u.hint.Visible = not touch -- touch: the pause footer's Back button owns that row
	-- legend top-right (touch: under its button)
	local count = #MapScreenController.legendEntries()
	local lay = MapScreenController.legendLayout(count, w, h, touch)
	u.legend.Size = UDim2.fromOffset(lay.width, lay.height)
	u.legend.Position = UDim2.fromOffset(lay.right, lay.top)
	u.legendGrid.CellSize = UDim2.fromOffset(LEGEND_COLUMN, LEGEND_ROW)
	u.legendRows.ScrollingEnabled = lay.scrolls
	u.legendToggle.Visible = touch
	u.hint.Text = if touch
		then "Tap to set a waypoint  ·  Pinch to zoom  ·  Drag to move"
		elseif pad then "[A] Set waypoint  ·  [LT / RT] Zoom  ·  [X] Clear  ·  [Y] Find me  ·  [B] Back"
		else "Click to set a waypoint  ·  Scroll to zoom  ·  Drag to move"
	u.reticle.Visible = pad
end

local function onPad(_name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if not isOpen then
		return Enum.ContextActionResult.Pass
	end
	local key = input.KeyCode
	local ended = state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel
	if key == Enum.KeyCode.Thumbstick1 then
		padStick = if ended then Vector2.zero else Vector2.new(input.Position.X, input.Position.Y)
	elseif key == Enum.KeyCode.Thumbstick2 then
		padZoom = if ended then 0 else input.Position.Y
	elseif key == Enum.KeyCode.ButtonR2 then
		padIn = if ended then 0 else math.clamp(input.Position.Z, 0, 1)
	elseif key == Enum.KeyCode.ButtonL2 then
		padOut = if ended then 0 else math.clamp(input.Position.Z, 0, 1)
	elseif state == Enum.UserInputState.Begin then
		if key == Enum.KeyCode.ButtonA then
			-- the reticle sits at the screen center (on your waypoint: clears it, like a second tap)
			onTap(Vector2.new(vpW / 2, vpH / 2))
		elseif key == Enum.KeyCode.ButtonX then
			if MinimapController.getCustomWaypoint() then
				MinimapController.setCustomWaypoint(nil)
				pcall(SoundController.play, "Click")
				accum = math.huge
			end
		elseif key == Enum.KeyCode.ButtonY then
			local p = rootPos()
			if p then
				cx, cz = MapScreenController.clampCenter(p.X, p.Z)
				accum = math.huge
			end
		elseif key == Enum.KeyCode.ButtonB then
			task.defer(MapScreenController.close)
		end
	end
	-- sunk: the character / camera / driving binds don't react while the map is up
	return Enum.ContextActionResult.Sink
end

local function bindPad()
	if padBound then
		return
	end
	padBound = true
	padStick, padZoom, padIn, padOut = Vector2.zero, 0, 0, 0
	pcall(function()
		ContextActionService:BindActionAtPriority(
			ACTION_PAD,
			onPad,
			false,
			PAD_PRIORITY,
			Enum.KeyCode.Thumbstick1,
			Enum.KeyCode.Thumbstick2,
			Enum.KeyCode.ButtonL2,
			Enum.KeyCode.ButtonR2,
			Enum.KeyCode.ButtonA,
			Enum.KeyCode.ButtonB,
			Enum.KeyCode.ButtonX,
			Enum.KeyCode.ButtonY
		)
	end)
end

local function unbindPad()
	if not padBound then
		return
	end
	padBound = false
	padStick, padZoom, padIn, padOut = Vector2.zero, 0, 0, 0
	pcall(function()
		ContextActionService:UnbindAction(ACTION_PAD)
	end)
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
	applyChrome(u, true)
	u.mapGui.Enabled = true
	u.chrome.Enabled = true
	bindPad()
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
	unbindPad()
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
	if pauseOpen and typeof(menu.togglePause) == "function" then
		-- §5.12: M opens the MAP tab directly; it closes the menu only when MAP is already the tab on show
		pcall(menu.togglePause, "MAP")
	elseif isOpen or pauseOpen then
		MapScreenController.close()
	else
		MapScreenController.open()
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------------------------------

function MapScreenController.init() end

-- Build the map UI without wiring any engine events (start() calls this first; headless tests call it alone).
function MapScreenController.mount()
	if not ui then
		ui = build()
	end
end

-- Advance one frame by hand / tap at a screen point (map gui px) (headless tests; the live game uses RenderStepped
-- and real input).
function MapScreenController.step(dt: number)
	step(dt)
end

function MapScreenController.tap(at: Vector2)
	if isOpen then
		onTap(at)
	end
end

function MapScreenController.start()
	MapScreenController.mount()
	local u = ui :: Ui
	wireButtons(u)
	bindInput(u)
	MinimapController.RouteChanged:Connect(function()
		if isOpen then
			routeAccum = math.huge
		end
	end)
	u.chrome:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if isOpen then
			applyChrome(u)
		end
	end)
	pcall(function()
		UserInputService.LastInputTypeChanged:Connect(function()
			if isOpen then
				applyChrome(u)
			end
		end)
	end)
	-- M: the MAP tab. Gamepad: the pause menu (D-pad up is the phone, §5.11; B closes through the pad bind).
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
