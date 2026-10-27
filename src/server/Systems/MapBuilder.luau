--!strict
-- MapBuilder: builds the static island city into Workspace.Map (SPEC §3 + §6).
--
-- Every coordinate comes from Config/Map + Util/MapLayout so all systems agree on where things are.
--
--   Map/Ground     base slab under the island (safety net)
--   Map/Roads      asphalt parts (tag "Road") + Markings (center dashes, edge lines, crosswalks: non-collide,
--                  non-query so suspension rays ride on the asphalt)
--   Map/Blocks     raised blocks (CURB_TOP): 4 sidewalk strips + a lot interior per block, curb-cut driveway ramps.
--                  Lot parts carry attributes BlockX, BlockZ, District, Poi ("" if none), PlotIndex (0 if none).
--   Map/Buildings  one Model per building, tag "AssetSlot" (Category="Buildings", Role="building_<class>", Fit,
--                  Footprint) so a later MapDresser can swap in art.
--   Map/POIs       SpawnPlaza, Dealership, PoliceHQ, GearShop, SprayShopA/B, ChopShop, StuntPark, Park, Pier
--   Map/Props      street lights (lamp parts tagged "StreetLight"; every third one holds a PointLight), palm /
--                  round trees (Models tagged "AssetSlot", Category="Props"), hydrants, benches
--   Map/Beach      promenade, sand, slopes, corner dunes, umbrellas, lifeguard towers
--   Map/Boundary   invisible collidable walls at ±BOUNDARY
--
-- Night contract (LightingService): parts tagged "NightGlow" carry DayColor/DayMaterial + NightColor/NightMaterial
-- attributes (window bands light up, lamp heads turn Neon).
--
-- build(parent) is pure instance construction (harness-compatible, SPEC §10). init() = build(Workspace) + Terrain
-- water/seabed (live engine only).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local MapConfig = require(Shared.Config.Map)
local MapLayout = require(Shared.Util.MapLayout)

local MapBuilder = {}

MapBuilder.SEED = 7331
MapBuilder.PART_BUDGET = 9000
MapBuilder.TAG_ROAD = "Road"
MapBuilder.TAG_STREET_LIGHT = "StreetLight"
MapBuilder.TAG_NIGHT_GLOW = "NightGlow"
-- Block holding the city landmark (giant neon tower right behind the Dealership in the spawn's view).
MapBuilder.LANDMARK_BLOCK = { x = 1, z = 0 }

---------------------------------------------------------------------------------------------------------------
-- Derived geometry
---------------------------------------------------------------------------------------------------------------

local S = MapConfig.GRID_SPACING
local RW = MapConfig.ROAD_WIDTH
local HALF_ROAD = RW / 2
local ROAD_Y = MapConfig.ROAD_Y
local CURB_H = MapConfig.CURB_HEIGHT
local CURB_TOP = MapLayout.CURB_TOP
local SW = MapConfig.SIDEWALK_WIDTH
local BLOCK_HALF = (S - RW) / 2 -- 60: block edge (= road edge) from the block center
local LOT_HALF = BLOCK_HALF - SW -- 52: lot interior edge
local BUILD_HALF = LOT_HALF - 2 -- buildings stay inside this (sidewalks stay clear)
local EXT = MapConfig.HALF_EXTENT + HALF_ROAD -- 820: outer edge of the ring road
local GROUND_BOTTOM = ROAD_Y - 2 -- roads + blocks extend down to here
local MARK_T = 0.1
local MARK_Y = ROAD_Y + 0.04
local PROMENADE_OUT = EXT + 8
local SAND_TOP = ROAD_Y + 0.3
local SLOPE_START = MapConfig.SAND_EXTENT - 20
local SLOPE_END = math.min(MapConfig.SAND_EXTENT + 40, MapConfig.BOUNDARY - 12)
local SEABED_Y = MapConfig.WATER_LEVEL - 12
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis (local X) -> world Y

local FONT = Font.fromEnum(Enum.Font.FredokaOne)

---------------------------------------------------------------------------------------------------------------
-- Palette (bold cartoon)
---------------------------------------------------------------------------------------------------------------

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local C = {
	base = rgb(44, 46, 60),
	road = rgb(58, 61, 80),
	dash = rgb(255, 210, 64),
	edge = rgb(236, 238, 246),
	crosswalk = rgb(242, 244, 250),
	sidewalk = rgb(212, 212, 222),
	lot = {
		downtown = rgb(170, 168, 186),
		midrise = rgb(200, 190, 172),
		lowrise = rgb(118, 198, 92),
		beach = rgb(138, 208, 100),
		plot = rgb(150, 154, 170),
	} :: { [string]: Color3 },
	sand = rgb(248, 224, 162),
	sandDeep = rgb(232, 204, 140),
	promenade = rgb(236, 196, 150),
	dark = rgb(30, 32, 48),
	white = rgb(245, 246, 250),
	metal = rgb(70, 74, 92),
	pole = rgb(52, 56, 72),
	lampDay = rgb(255, 244, 214),
	lampNight = rgb(255, 214, 140),
	windowDay = rgb(58, 92, 140),
	windowNight = rgb(255, 208, 120),
	water = rgb(60, 196, 255),
	trunk = rgb(150, 104, 64),
	leafA = rgb(56, 168, 72),
	leafB = rgb(92, 204, 84),
	wood = rgb(176, 120, 72),
	pink = rgb(255, 52, 140),
	cyan = rgb(0, 214, 255),
	yellow = rgb(255, 205, 50),
	lime = rgb(120, 255, 120),
	purple = rgb(170, 90, 255),
	orange = rgb(255, 140, 40),
	red = rgb(235, 60, 60),
	police = rgb(40, 104, 235),
}

local NEON = { C.pink, C.cyan, C.purple, C.yellow, C.lime, C.orange }
local TOWER_GLASS = {
	rgb(64, 178, 214),
	rgb(56, 100, 196),
	rgb(122, 92, 206),
	rgb(76, 200, 176),
	rgb(206, 104, 176),
	rgb(150, 176, 214),
	rgb(40, 140, 170),
}
local TOWER_BAND = { rgb(240, 242, 250), rgb(200, 206, 222), rgb(44, 48, 70), rgb(250, 230, 200) }
local PLASTER = {
	rgb(240, 124, 104),
	rgb(236, 200, 140),
	rgb(92, 182, 182),
	rgb(172, 150, 222),
	rgb(122, 182, 240),
	rgb(142, 212, 170),
	rgb(250, 170, 128),
	rgb(232, 232, 238),
	rgb(244, 140, 170),
}
local SHOP = {
	rgb(232, 72, 72),
	rgb(250, 150, 50),
	rgb(250, 210, 70),
	rgb(90, 200, 100),
	rgb(70, 140, 240),
	rgb(160, 92, 222),
	rgb(240, 110, 170),
	rgb(40, 190, 200),
}
local PASTEL = {
	rgb(250, 182, 202),
	rgb(170, 232, 202),
	rgb(250, 232, 150),
	rgb(170, 212, 250),
	rgb(212, 182, 242),
	rgb(250, 202, 160),
	rgb(246, 246, 240),
}
local ROOF = { rgb(200, 90, 70), rgb(90, 100, 132), rgb(60, 150, 150), rgb(190, 60, 70), rgb(120, 80, 160) }
local AD_TEXTS = {
	"NITRO COLA",
	"BONK BAT CO.",
	"GOT CARS?",
	"SPEEDY SNAX",
	"DUCK INSURANCE",
	"HONK MORE",
	"TURBO TOAST",
	"CRUISE CONTROL",
	"VROOM VITAMINS",
	"GARAGE GOALS",
}
local SHOP_NAMES = {
	"PIZZA",
	"DONUTS",
	"TACOS",
	"BURGERS",
	"ARCADE",
	"COFFEE",
	"SUSHI",
	"GYM",
	"COMICS",
	"TOYS",
	"NOODLES",
	"BOBA",
	"DINER",
	"MUSIC",
	"FRIES",
	"HOT DOGS",
	"SNEAKERS",
	"PETS",
}

---------------------------------------------------------------------------------------------------------------
-- Instance helpers
---------------------------------------------------------------------------------------------------------------

type PartOpts = {
	material: Enum.Material?,
	collide: boolean?,
	query: boolean?,
	shadow: boolean?,
	transparency: number?,
	reflectance: number?,
	shape: Enum.PartType?,
	class: string?,
}

local function tag(inst: Instance, name: string)
	CollectionService:AddTag(inst, name)
end

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, opts: PartOpts?): BasePart
	local o: PartOpts = opts or {}
	local p = Instance.new(o.class or "Part") :: BasePart
	p.Name = name
	p.Anchored = true
	if o.shape then
		(p :: any).Shape = o.shape
	end
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = o.material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	local collide = if o.collide == nil then true else o.collide
	p.CanCollide = collide
	p.CanQuery = if collide then true else o.query == true
	p.CanTouch = false
	p.CastShadow = if o.shadow == nil then true else o.shadow
	if o.transparency then
		p.Transparency = o.transparency
	end
	if o.reflectance then
		p.Reflectance = o.reflectance
	end
	p.Parent = parent
	return p
end

-- Non-collidable, non-queryable decoration.
local function deco(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?
): BasePart
	return part(parent, name, size, cf, color, {
		material = material,
		collide = false,
		shadow = material ~= Enum.Material.Neon,
	})
end

local function neon(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3): BasePart
	return deco(parent, name, size, cf, color, Enum.Material.Neon)
end

local function wedge(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	collide: boolean?
): BasePart
	return part(parent, name, size, cf, color, { class = "WedgePart", collide = collide })
end

-- Vertical cylinder centered at cf.
local function cyl(
	parent: Instance,
	name: string,
	height: number,
	diameter: number,
	cf: CFrame,
	color: Color3,
	opts: PartOpts?
): BasePart
	local o: PartOpts = table.clone(opts or {})
	o.shape = Enum.PartType.Cylinder
	return part(parent, name, Vector3.new(height, diameter, diameter), cf * UPRIGHT, color, o)
end

local function ball(
	parent: Instance,
	name: string,
	diameter: number,
	pos: Vector3,
	color: Color3,
	opts: PartOpts?
): BasePart
	local o: PartOpts = table.clone(opts or {})
	o.shape = Enum.PartType.Ball
	return part(parent, name, Vector3.new(diameter, diameter, diameter), CFrame.new(pos), color, o)
end

-- Wedge ramp: footprint centered at groundCenter, rising along ascentDir (horizontal unit) to `height`.
-- WedgePart convention: low edge at local -Z (front), tall face at +Z (back) => LookVector = -ascentDir.
local function ramp(
	parent: Instance,
	name: string,
	groundCenter: Vector3,
	ascentDir: Vector3,
	width: number,
	length: number,
	height: number,
	color: Color3
): BasePart
	local center = groundCenter + Vector3.new(0, height / 2, 0)
	return wedge(parent, name, Vector3.new(width, height, length), CFrame.lookAt(center, center - ascentDir), color)
end

local function folder(name: string, parent: Instance): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

-- Day/night material swap metadata read by LightingService.
local function nightGlow(p: BasePart, nightColor: Color3, nightMaterial: string?)
	p:SetAttribute("DayColor", p.Color)
	p:SetAttribute("DayMaterial", p.Material.Name)
	p:SetAttribute("NightColor", nightColor)
	p:SetAttribute("NightMaterial", nightMaterial or "Neon")
	tag(p, MapBuilder.TAG_NIGHT_GLOW)
end

local function addText(board: BasePart, face: Enum.NormalId, text: string, fg: Color3, maxDistance: number)
	local sg = Instance.new("SurfaceGui")
	sg.Name = "SignGui_" .. face.Name
	sg.Face = face
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 20
	sg.LightInfluence = 0
	sg.Brightness = 1.6
	sg.MaxDistance = maxDistance
	sg.ClipsDescendants = true
	sg.ResetOnSpawn = false
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0.94, 0.84)
	label.Position = UDim2.fromScale(0.03, 0.08)
	label.Text = text
	label.TextColor3 = fg
	label.FontFace = FONT
	label.TextScaled = true
	local stroke = Instance.new("UIStroke")
	stroke.Color = C.dark
	stroke.Thickness = math.clamp(board.Size.Y * 0.9, 2, 8)
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	stroke.Parent = label
	label.Parent = sg
	sg.Parent = board
end

type SignOpts = { glow: Color3?, back: boolean?, maxDistance: number?, collide: boolean? }

-- Sign board facing its LookVector (Front face) with optional neon frame behind and text on the back too.
local function sign(
	parent: Instance,
	name: string,
	text: string,
	size: Vector3,
	cf: CFrame,
	bg: Color3,
	fg: Color3,
	opts: SignOpts?
): BasePart
	local o: SignOpts = opts or {}
	local board = part(parent, name, size, cf, bg, { collide = o.collide == true })
	if o.glow then
		neon(parent, name .. "Glow", Vector3.new(size.X + 1.2, size.Y + 1.2, size.Z * 0.5), cf, o.glow)
	end
	local dist = o.maxDistance or 600
	addText(board, Enum.NormalId.Front, text, fg, dist)
	if o.back then
		addText(board, Enum.NormalId.Back, text, fg, dist)
	end
	return board
end

local function pick<T>(rng: Random, list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

local function rand(rng: Random, a: number, b: number): number
	return rng:NextNumber(a, b)
end

---------------------------------------------------------------------------------------------------------------
-- Context
---------------------------------------------------------------------------------------------------------------

type Ctx = {
	root: Folder,
	ground: Folder,
	roads: Folder,
	markings: Folder,
	blocks: Folder,
	buildings: Folder,
	pois: Folder,
	props: Folder,
	beach: Folder,
	boundary: Folder,
	lightIndex: number,
}

type Rect = { x0: number, x1: number, z0: number, z1: number }
type Cut = { side: string, a: number, b: number }

local SIDES: { [string]: { normal: Vector3, along: Vector3 } } = {
	N = { normal = Vector3.new(0, 0, -1), along = Vector3.new(1, 0, 0) },
	S = { normal = Vector3.new(0, 0, 1), along = Vector3.new(1, 0, 0) },
	W = { normal = Vector3.new(-1, 0, 0), along = Vector3.new(0, 0, 1) },
	E = { normal = Vector3.new(1, 0, 0), along = Vector3.new(0, 0, 1) },
}
local SIDE_ORDER = { "N", "E", "S", "W" }

local function sideOfFace(face: Vector3): string
	if math.abs(face.X) > math.abs(face.Z) then
		return if face.X > 0 then "E" else "W"
	end
	return if face.Z > 0 then "S" else "N"
end

local function blockKey(bx: number, bz: number): string
	return bx .. "," .. bz
end

-- "downtown" | "midrise" | "lowrise" | "beach" (by ring distance from the city center; uses DOWNTOWN_RADIUS).
function MapBuilder.districtOf(bx: number, bz: number): string
	local ax, az = math.abs(bx + 0.5), math.abs(bz + 0.5)
	local R = MapConfig.DOWNTOWN_RADIUS
	if ax <= R and az <= R then
		return "downtown"
	end
	local r = math.max(ax, az)
	if r <= R + 1 then
		return "midrise"
	elseif r <= R + 2 then
		return "lowrise"
	end
	return "beach"
end

local plotByBlock: { [string]: number } = {}
for i, def in MapConfig.Plots do
	plotByBlock[blockKey(def.block.x, def.block.z)] = i
end
local poiByBlock: { [string]: string } = {}
for name, b in MapConfig.Blocks do
	poiByBlock[blockKey(b.x, b.z)] = name
end

-- Curb cuts (driveway ramps through the sidewalk) per block, in block-local along-coordinates.
local function cutsFor(bx: number, bz: number): { Cut }
	local key = blockKey(bx, bz)
	local cuts: { Cut } = {}
	local plot = plotByBlock[key]
	if plot then
		local half = (MapConfig.Garage.DOOR_WIDTH + 6) / 2
		table.insert(cuts, { side = sideOfFace(MapConfig.Plots[plot].face), a = -half, b = half })
	end
	local poi = poiByBlock[key]
	if poi == "Dealership" then
		table.insert(cuts, { side = "N", a = -50, b = 50 })
	elseif poi == "SprayShopA" or poi == "SprayShopB" then
		table.insert(cuts, { side = "N", a = -15, b = 15 })
	elseif poi == "ChopShop" then
		table.insert(cuts, { side = "S", a = -17, b = 17 })
	elseif poi == "StuntPark" then
		table.insert(cuts, { side = "W", a = -44, b = -16 })
		table.insert(cuts, { side = "N", a = -20, b = 20 })
	end
	return cuts
end
MapBuilder.cutsFor = cutsFor

---------------------------------------------------------------------------------------------------------------
-- Props
---------------------------------------------------------------------------------------------------------------

local function assetSlot(m: Model, category: string, role: string, fit: number)
	tag(m, "AssetSlot")
	m:SetAttribute("Category", category)
	m:SetAttribute("Role", role)
	m:SetAttribute("Fit", fit)
end

local function palm(parent: Instance, ground: Vector3, height: number, rng: Random): Model
	local m = Instance.new("Model")
	m.Name = "PalmTree"
	assetSlot(m, "Props", "palm_tree", height)
	m.WorldPivot = CFrame.new(ground)
	local lean = CFrame.Angles(rand(rng, -0.12, 0.12), 0, rand(rng, -0.12, 0.12))
	local baseCf = CFrame.new(ground) * lean
	cyl(m, "Trunk", height, 1.5, baseCf * CFrame.new(0, height / 2, 0), C.trunk, { material = Enum.Material.Wood })
	local top = (baseCf * CFrame.new(0, height, 0)).Position
	local yaw0 = rand(rng, 0, math.pi * 2)
	for i = 0, 3 do
		local yaw = yaw0 + i * math.pi / 2 + rand(rng, -0.25, 0.25)
		local droop = rand(rng, 0.25, 0.5)
		local dir = Vector3.new(math.cos(yaw) * math.cos(droop), -math.sin(droop), math.sin(yaw) * math.cos(droop))
		local len = height * 0.55 + 3
		local center = top + dir * (len / 2 - 0.5)
		deco(
			m,
			"Frond",
			Vector3.new(2.8, 0.4, len),
			CFrame.lookAt(center, center + dir),
			if i % 2 == 0 then C.leafA else C.leafB
		)
	end
	m.Parent = parent
	return m
end

local function roundTree(parent: Instance, ground: Vector3, height: number, rng: Random): Model
	local m = Instance.new("Model")
	m.Name = "Tree"
	assetSlot(m, "Props", "tree", height)
	m.WorldPivot = CFrame.new(ground)
	local trunkH = height * 0.45
	cyl(m, "Trunk", trunkH + 1, 1.6, CFrame.new(ground + Vector3.new(0, (trunkH + 1) / 2, 0)), C.trunk, {
		material = Enum.Material.Wood,
	})
	local d = height * 0.62
	local green = if rng:NextNumber() < 0.5 then C.leafA else C.leafB
	ball(m, "Canopy", d, ground + Vector3.new(0, trunkH + d * 0.42, 0), green, { collide = false })
	if rng:NextNumber() < 0.55 then
		local off = Vector3.new(rand(rng, -1, 1), 0, rand(rng, -1, 1)) * d * 0.3
		ball(m, "Canopy", d * 0.7, ground + Vector3.new(0, trunkH + d * 0.75, 0) + off, C.leafB, { collide = false })
	end
	m.Parent = parent
	return m
end

local function bench(parent: Instance, cf: CFrame, color: Color3?)
	-- cf at ground, LookVector = the way a sitter faces
	local col = color or C.wood
	part(parent, "Bench", Vector3.new(6, 0.6, 2.2), cf * CFrame.new(0, 1.6, 0), col)
	part(parent, "BenchBack", Vector3.new(6, 2.2, 0.5), cf * CFrame.new(0, 2.8, 1.1), col)
	deco(parent, "BenchLegs", Vector3.new(5, 1.3, 1.6), cf * CFrame.new(0, 0.65, 0), C.metal)
end

local function hydrant(parent: Instance, pos: Vector3)
	cyl(parent, "Hydrant", 2.4, 1.2, CFrame.new(pos + Vector3.new(0, 1.2, 0)), C.red)
	ball(parent, "HydrantCap", 1.3, pos + Vector3.new(0, 2.5, 0), rgb(255, 200, 60), { collide = false })
end

-- Street light at a sidewalk ground point; the lamp arm reaches out over the road (outward).
local function streetLight(ctx: Ctx, ground: Vector3, outward: Vector3)
	ctx.lightIndex += 1
	local poleH = 15
	part(
		ctx.props,
		"LightPole",
		Vector3.new(0.7, poleH, 0.7),
		CFrame.new(ground + Vector3.new(0, poleH / 2, 0)),
		C.pole
	)
	local lampPos = ground + outward * 2.4 + Vector3.new(0, poleH + 0.2, 0)
	local lamp = part(
		ctx.props,
		"StreetLamp",
		Vector3.new(1.4, 0.7, 5.6),
		CFrame.lookAt(lampPos, lampPos + outward),
		C.lampDay,
		{
			collide = false,
			shadow = false,
		}
	)
	nightGlow(lamp, C.lampNight)
	tag(lamp, MapBuilder.TAG_STREET_LIGHT)
	-- PERF: a light on every third lamp only, short range (the Neon lamp heads carry the night look; ~200 overlapping
	-- Range-48 lights cost mobile GPUs during the night segment)
	if ctx.lightIndex % 3 == 0 then
		local light = Instance.new("PointLight")
		light.Name = "Light"
		light.Range = 32
		light.Brightness = 1.6
		light.Color = rgb(255, 210, 150)
		light.Shadows = false
		light.Enabled = false
		light.Parent = lamp
	end
end

---------------------------------------------------------------------------------------------------------------
-- Buildings
---------------------------------------------------------------------------------------------------------------

local function newBuilding(parent: Instance, class: string, origin: CFrame, w: number, d: number, h: number): Model
	local m = Instance.new("Model")
	m.Name = class
	assetSlot(m, "Buildings", "building_" .. string.lower(class), math.max(w, d))
	m:SetAttribute("Footprint", Vector3.new(w, h, d))
	m.WorldPivot = origin
	m.Parent = parent
	return m
end

-- Ring band: a box slightly larger than the facade => one part shows a stripe on all four sides.
local function band(
	m: Instance,
	name: string,
	origin: CFrame,
	w: number,
	d: number,
	y: number,
	hgt: number,
	grow: number,
	color: Color3,
	material: Enum.Material?
): BasePart
	return part(m, name, Vector3.new(w + grow, hgt, d + grow), origin * CFrame.new(0, y, 0), color, {
		material = material,
		collide = false,
		shadow = false,
	})
end

-- Downtown glass tower. origin: ground center (CURB_TOP), LookVector = street front.
local function buildTower(parent: Instance, rng: Random, origin: CFrame, w: number, d: number, h: number): Model
	local m = newBuilding(parent, "Tower", origin, w, d, h)
	local glass = pick(rng, TOWER_GLASS)
	local bandColor = pick(rng, TOWER_BAND)
	local accent = pick(rng, NEON)
	local podH = 9
	part(m, "Podium", Vector3.new(w + 4, podH, d + 4), origin * CFrame.new(0, podH / 2, 0), rgb(70, 72, 92))
	local lobby = band(m, "Lobby", origin, w + 4, d + 4, 3.4, 5.2, 0.4, C.windowDay, Enum.Material.Glass)
	nightGlow(lobby, C.windowNight)
	neon(m, "PodiumTrim", Vector3.new(w + 4.6, 0.6, d + 4.6), origin * CFrame.new(0, podH - 0.3, 0), accent)

	if rng:NextNumber() < 0.5 then
		-- vertical neon fins on the front corners of the main shaft
		local finH = (h - podH) * 0.55
		for _, sx in { -1, 1 } do
			neon(
				m,
				"Fin",
				Vector3.new(0.6, finH, 0.6),
				origin * CFrame.new(sx * (w / 2 + 0.1), podH + finH / 2, -d / 2 - 0.1),
				accent
			)
		end
	end
	local style = rng:NextInteger(1, 3)
	local tiers: { { number } }
	local th = h - podH
	if style == 1 then
		tiers = { { 1, 0.6 }, { 0.74, 0.25 }, { 0.5, 0.15 } }
	elseif style == 2 then
		tiers = { { 1, 1 } }
	else
		tiers = { { 1, 0.72 }, { 0.68, 0.28 } }
	end
	local y = podH
	local tw, td = w, d
	for ti, tier in tiers do
		tw, td = w * tier[1], d * tier[1]
		local tierH = math.max(8, th * tier[2])
		part(m, "Shaft", Vector3.new(tw, tierH, td), origin * CFrame.new(0, y + tierH / 2, 0), glass, {
			material = Enum.Material.Glass,
			reflectance = 0.08,
		})
		local spacing = math.max(13, tierH / 8)
		local by = spacing
		local count = 0
		while by < tierH - 4 and count < 9 do
			local b = band(m, "FloorBand", origin, tw, td, y + by, 1.1, 0.5, bandColor)
			nightGlow(b, accent)
			by += spacing
			count += 1
		end
		y += tierH
		neon(m, "Crown", Vector3.new(tw + 0.8, 1.2, td + 0.8), origin * CFrame.new(0, y - 0.6, 0), accent)
		if ti < #tiers then
			part(m, "Ledge", Vector3.new(tw + 1, 1, td + 1), origin * CFrame.new(0, y + 0.5, 0), bandColor)
			y += 1
		end
	end
	-- roof feature
	local crown = rng:NextInteger(1, 3)
	if crown == 1 then
		part(m, "Antenna", Vector3.new(1, 26, 1), origin * CFrame.new(0, y + 13, 0), C.metal)
		ball(m, "AntennaTip", 2, (origin * CFrame.new(0, y + 26.5, 0)).Position, C.red, {
			material = Enum.Material.Neon,
			collide = false,
			shadow = false,
		})
	elseif crown == 2 then
		local wh = math.min(tw, td) * 0.45
		wedge(m, "SlantRoof", Vector3.new(tw, wh, td), origin * CFrame.new(0, y + wh / 2, 0), glass)
	else
		cyl(m, "Helipad", 0.6, math.min(tw, td) - 3, origin * CFrame.new(0, y + 0.3, 0), C.dark)
		neon(
			m,
			"HelipadH",
			Vector3.new(1.2, 0.2, math.min(tw, td) * 0.35),
			origin * CFrame.new(0, y + 0.65, 0),
			C.yellow
		)
	end
	if crown ~= 2 then
		part(
			m,
			"RoofBox",
			Vector3.new(math.min(8, tw * 0.3), 4, math.min(6, td * 0.3)),
			origin * CFrame.new(tw * 0.25, y + 2, td * 0.22),
			C.metal
		)
	end
	return m
end

-- Mid-rise office / apartment with ribbon windows.
local function buildMidrise(parent: Instance, rng: Random, origin: CFrame, w: number, d: number, h: number): Model
	local m = newBuilding(parent, "Midrise", origin, w, d, h)
	local body = pick(rng, PLASTER)
	local accent = pick(rng, SHOP)
	part(m, "Body", Vector3.new(w, h, d), origin * CFrame.new(0, h / 2, 0), body)
	local store = band(m, "Storefront", origin, w, d, 3.3, 5.4, 0.5, C.windowDay, Enum.Material.Glass)
	nightGlow(store, C.windowNight)
	local y = 10.5
	local count = 0
	while y < h - 4 and count < 7 do
		local b = band(m, "Windows", origin, w, d, y, 3.4, 0.4, C.windowDay, Enum.Material.Glass)
		if rng:NextNumber() < 0.75 then -- some floors stay dark at night (lived-in look)
			nightGlow(b, C.windowNight)
		end
		y += 8.5
		count += 1
	end
	part(m, "Cap", Vector3.new(w + 1, 1.4, d + 1), origin * CFrame.new(0, h + 0.7, 0), accent)
	-- awning over the street entrance
	local aw = math.min(w - 4, 22)
	wedge(m, "Awning", Vector3.new(aw, 1.6, 4), origin * CFrame.new(0, 7, -d / 2 - 2), accent, false)
	if rng:NextNumber() < 0.5 then
		cyl(
			m,
			"WaterTank",
			5,
			6,
			origin * CFrame.new(w * 0.22, h + 3.9, d * 0.18),
			C.wood,
			{ material = Enum.Material.Wood }
		)
	else
		part(m, "RoofBox", Vector3.new(7, 3, 5), origin * CFrame.new(-w * 0.2, h + 2.9, d * 0.15), C.metal)
	end
	if rng:NextNumber() < 0.22 then
		-- rooftop parody ad facing the street (tag "Billboard": an art pass can swap the text for an image)
		local bw = math.min(w * 0.8, 26)
		local ad = AD_TEXTS[rng:NextInteger(1, #AD_TEXTS)]
		local board = sign(
			m,
			"Billboard",
			ad,
			Vector3.new(bw, 8, 0.8),
			origin * CFrame.new(0, h + 9.4, -d / 2 + 3),
			C.white,
			pick(rng, SHOP),
			{
				glow = pick(rng, NEON),
				maxDistance = 500,
			}
		)
		tag(board, "Billboard")
		board:SetAttribute("AdText", ad)
		for _, sx in { -1, 1 } do
			part(
				m,
				"BillboardPost",
				Vector3.new(0.8, 6, 0.8),
				origin * CFrame.new(sx * bw * 0.35, h + 3.4, -d / 2 + 3.4),
				C.metal
			)
		end
	end
	return m
end

local function buildShop(
	parent: Instance,
	rng: Random,
	origin: CFrame,
	w: number,
	d: number,
	h: number,
	name: string
): Model
	local m = newBuilding(parent, "Shop", origin, w, d, h)
	local body = pick(rng, SHOP)
	local accent = pick(rng, NEON)
	part(m, "Body", Vector3.new(w, h, d), origin * CFrame.new(0, h / 2, 0), body)
	local store = band(m, "Storefront", origin, w, d, 4, 6, 0.3, C.windowDay, Enum.Material.Glass)
	nightGlow(store, C.windowNight)
	wedge(m, "Awning", Vector3.new(w - 2, 1.8, 4.5), origin * CFrame.new(0, 8.2, -d / 2 - 2.25), C.white, false)
	local signH = math.min(3.6, h - 10.5)
	sign(
		m,
		"ShopSign",
		name,
		Vector3.new(w * 0.78, signH, 0.8),
		origin * CFrame.new(0, 9.6 + signH / 2, -d / 2 - 0.4),
		C.dark,
		accent,
		{
			maxDistance = 260,
		}
	)
	part(m, "Cap", Vector3.new(w + 0.8, 1, d + 0.8), origin * CFrame.new(0, h + 0.5, 0), body:Lerp(C.dark, 0.45))
	neon(m, "CapTrim", Vector3.new(w + 1, 0.3, d + 1), origin * CFrame.new(0, h + 0.15, 0), accent)
	return m
end

local function buildHouse(parent: Instance, rng: Random, origin: CFrame, w: number, d: number, h: number): Model
	local m = newBuilding(parent, "House", origin, w, d, h)
	part(m, "Body", Vector3.new(w, h, d), origin * CFrame.new(0, h / 2, 0), pick(rng, PASTEL))
	local win = band(m, "Windows", origin, w, d, h * 0.6, 2.6, 0.3, C.windowDay, Enum.Material.Glass)
	if rng:NextNumber() < 0.8 then
		nightGlow(win, C.windowNight)
	end
	local roofColor = pick(rng, ROOF)
	local rh = math.min(7, d * 0.35)
	local half = d / 2 + 0.8
	wedge(m, "Roof", Vector3.new(w + 1.6, rh, half), origin * CFrame.new(0, h + rh / 2, -half / 2), roofColor)
	wedge(
		m,
		"Roof",
		Vector3.new(w + 1.6, rh, half),
		origin * CFrame.new(0, h + rh / 2, half / 2) * CFrame.Angles(0, math.pi, 0),
		roofColor
	)
	part(
		m,
		"Door",
		Vector3.new(3.6, 6, 0.4),
		origin * CFrame.new(rand(rng, -w * 0.25, w * 0.25), 3, -d / 2 - 0.2),
		pick(rng, SHOP)
	)
	return m
end

---------------------------------------------------------------------------------------------------------------
-- District fill (generic city blocks)
---------------------------------------------------------------------------------------------------------------

local function splitRect(r: Rect, nx: number, nz: number, gap: number): { Rect }
	local out: { Rect } = {}
	local w = (r.x1 - r.x0 - gap * (nx - 1)) / nx
	local d = (r.z1 - r.z0 - gap * (nz - 1)) / nz
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			local x0 = r.x0 + i * (w + gap)
			local z0 = r.z0 + j * (d + gap)
			table.insert(out, { x0 = x0, x1 = x0 + w, z0 = z0, z1 = z0 + d })
		end
	end
	return out
end

-- Facing (outward to the nearest street) for a parcel center in block-local coords.
local function outwardFor(cx: number, cz: number, rng: Random): Vector3
	if math.abs(cx) > math.abs(cz) + 1 then
		return Vector3.new(math.sign(cx), 0, 0)
	elseif math.abs(cz) > math.abs(cx) + 1 then
		return Vector3.new(0, 0, math.sign(cz))
	end
	if rng:NextNumber() < 0.5 then
		return Vector3.new(if cx >= 0 then 1 else -1, 0, 0)
	end
	return Vector3.new(0, 0, if cz >= 0 then 1 else -1)
end

-- Parcel frame: returns origin CFrame (ground center, facing out), available width (local X) and depth (local Z).
local function parcelFrame(blockOrigin: Vector3, r: Rect, outward: Vector3): (Vector3, number, number)
	local cx, cz = (r.x0 + r.x1) / 2, (r.z0 + r.z1) / 2
	local sx, sz = r.x1 - r.x0, r.z1 - r.z0
	local center = blockOrigin + Vector3.new(cx, 0, cz)
	if math.abs(outward.X) > 0.5 then
		return center, sz, sx
	end
	return center, sx, sz
end

local function frameAt(center: Vector3, outward: Vector3, pushOut: number): CFrame
	local p = center + outward * pushOut
	return CFrame.lookAt(p, p + outward)
end

local function miniPlaza(ctx: Ctx, rng: Random, center: Vector3, outward: Vector3)
	palm(ctx.props, center + Vector3.new(rand(rng, -6, 6), 0, rand(rng, -6, 6)), rand(rng, 16, 22), rng)
	local bcf = CFrame.lookAt(center + outward * 6, center + outward * 12)
	bench(ctx.props, bcf)
	cyl(ctx.props, "Planter", 1.4, 9, CFrame.new(center + outward * -6 + Vector3.new(0, 0.7, 0)), rgb(196, 170, 140))
	ball(ctx.props, "Bush", 6, center + outward * -6 + Vector3.new(0, 2.2, 0), C.leafB, { collide = false })
end

local function fillParcel(
	ctx: Ctx,
	rng: Random,
	district: string,
	blockOrigin: Vector3,
	r: Rect,
	forceBuilding: boolean
): boolean
	local cx, cz = (r.x0 + r.x1) / 2, (r.z0 + r.z1) / 2
	local outward = outwardFor(cx, cz, rng)
	local center, aw, ad = parcelFrame(blockOrigin, r, outward)
	if aw < 14 or ad < 14 then
		return false
	end
	local roll = rng:NextNumber()
	if district == "downtown" then
		if not forceBuilding and roll < 0.18 then
			miniPlaza(ctx, rng, center, outward)
			return false
		end
		local w = math.clamp(aw * rand(rng, 0.66, 0.86), 18, aw - 6)
		local d = math.clamp(ad * rand(rng, 0.66, 0.86), 18, ad - 6)
		local dist = (blockOrigin - Vector3.new(0, blockOrigin.Y, 0)).Magnitude
		local h = rand(rng, 95, 175) * (if dist < S * 1.2 then 1.15 else 1)
		local push = (ad - (d + 4)) / 2 * rand(rng, 0, 0.6)
		buildTower(ctx.buildings, rng, frameAt(center, outward, push), w, d, h)
	elseif district == "midrise" then
		if not forceBuilding and roll < 0.15 then
			miniPlaza(ctx, rng, center, outward)
			return false
		end
		local w = math.clamp(aw * rand(rng, 0.68, 0.92), 16, aw - 2)
		local d = math.clamp(ad * rand(rng, 0.62, 0.86), 16, ad - 5)
		local h = rand(rng, 28, 64)
		local push = (ad - (d + 4.5)) / 2 * rand(rng, 0.3, 1)
		buildMidrise(ctx.buildings, rng, frameAt(center, outward, push), w, d, h)
	elseif district == "lowrise" then
		if roll < 0.55 and aw >= 34 then
			-- two shops side by side along the street
			local right = CFrame.lookAt(center, center + outward).RightVector
			local sw = aw / 2 - 2
			for k = -1, 1, 2 do
				local d = math.clamp(ad * rand(rng, 0.55, 0.8), 14, ad - 5)
				local h = rand(rng, 14, 21)
				local c = center + right * (k * aw / 4)
				local push = (ad - (d + 4.5)) / 2
				buildShop(ctx.buildings, rng, frameAt(c, outward, push), sw, d, h, pick(rng, SHOP_NAMES))
			end
		elseif roll < 0.85 then
			local w = math.clamp(aw * rand(rng, 0.6, 0.85), 16, aw - 2)
			local d = math.clamp(ad * rand(rng, 0.55, 0.8), 16, ad - 5)
			buildMidrise(ctx.buildings, rng, frameAt(center, outward, (ad - (d + 4.5)) / 2), w, d, rand(rng, 20, 34))
		else
			local w = math.clamp(aw * 0.6, 14, aw - 2)
			local d = math.clamp(ad * 0.55, 14, ad - 5)
			buildShop(
				ctx.buildings,
				rng,
				frameAt(center, outward, (ad - (d + 4.5)) / 2),
				w,
				d,
				rand(rng, 14, 20),
				pick(rng, SHOP_NAMES)
			)
			roundTree(ctx.props, center - outward * (ad / 2 - 5), rand(rng, 14, 20), rng)
		end
	else -- beach houses
		local w = math.clamp(aw * rand(rng, 0.55, 0.75), 14, aw - 4)
		local d = math.clamp(ad * rand(rng, 0.5, 0.65), 12, ad - 6)
		local h = rand(rng, 10.5, 13)
		local push = (ad - d) / 2 - 3
		buildHouse(ctx.buildings, rng, frameAt(center, outward, push), w, d, h)
		if rng:NextNumber() < 0.45 then
			local right = CFrame.lookAt(center, center + outward).RightVector
			local side = if rng:NextNumber() < 0.5 then -1 else 1
			local tp = center - outward * (ad / 2 - 4) + right * side * (aw / 2 - 4)
			if rng:NextNumber() < 0.5 then
				palm(ctx.props, tp, rand(rng, 14, 19), rng)
			else
				roundTree(ctx.props, tp, rand(rng, 12, 17), rng)
			end
		end
	end
	return true
end

-- Fill a block-local rectangle with the district's buildings.
local function fillArea(ctx: Ctx, rng: Random, district: string, blockOrigin: Vector3, area: Rect)
	local sx, sz = area.x1 - area.x0, area.z1 - area.z0
	local target = if district == "beach" then 33 else 48
	local gap = if district == "beach" then 3 else 6
	local nx = math.max(1, math.floor(sx / target + 0.35))
	local nz = math.max(1, math.floor(sz / target + 0.35))
	local parcels = splitRect(area, nx, nz, gap)
	local built = 0
	for i, r in parcels do
		local cx, cz = (r.x0 + r.x1) / 2, (r.z0 + r.z1) / 2
		if district == "beach" and nx == 3 and nz == 3 and math.abs(cx) < 8 and math.abs(cz) < 8 then
			-- backyard center: pool + tree
			local c = blockOrigin + Vector3.new(cx, 0, cz)
			part(ctx.props, "PoolDeck", Vector3.new(18, 0.3, 13), CFrame.new(c + Vector3.new(0, 0.15, 0)), C.white)
			part(ctx.props, "Pool", Vector3.new(15, 0.3, 10), CFrame.new(c + Vector3.new(0, 0.3, 0)), C.water, {
				collide = false,
				reflectance = 0.15,
			})
			palm(ctx.props, c + Vector3.new(11, 0, 8), rand(rng, 15, 19), rng)
		else
			if fillParcel(ctx, rng, district, blockOrigin, r, built == 0 and i == #parcels) then
				built += 1
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- Ground, roads, markings
---------------------------------------------------------------------------------------------------------------

local function buildGround(ctx: Ctx)
	local half = SLOPE_START
	part(
		ctx.ground,
		"BaseSlab",
		Vector3.new(half * 2, 4, half * 2),
		CFrame.new(0, GROUND_BOTTOM - 0.4 - 2, 0),
		C.base,
		{
			shadow = false,
		}
	)
end

local function markingPart(ctx: Ctx, name: string, size: Vector3, pos: Vector3, color: Color3)
	part(ctx.markings, name, size, CFrame.new(pos), color, { collide = false, shadow = false })
end

local function buildRoads(ctx: Ctx)
	local rt = ROAD_Y - GROUND_BOTTOM
	local edgeOff = HALF_ROAD - 1.6
	for line = MapConfig.LINE_MIN, MapConfig.LINE_MAX do
		local c = line * S
		-- X road: runs along X at z = c, full length (owns the intersections)
		local rx =
			part(ctx.roads, "Road_X" .. line, Vector3.new(EXT * 2, rt, RW), CFrame.new(0, ROAD_Y - rt / 2, c), C.road, {
				shadow = false,
			})
		tag(rx, MapBuilder.TAG_ROAD)
		rx:SetAttribute("Axis", "X")
		rx:SetAttribute("Line", line)
		for k = MapConfig.LINE_MIN, MapConfig.LINE_MAX - 1 do
			local a = k * S + HALF_ROAD
			local b = (k + 1) * S - HALF_ROAD
			local len = b - a
			local mid = (a + b) / 2
			-- Z road segment between two X roads
			local rz = part(
				ctx.roads,
				"Road_Z" .. line,
				Vector3.new(RW, rt, len),
				CFrame.new(c, ROAD_Y - rt / 2, mid),
				C.road,
				{
					shadow = false,
				}
			)
			tag(rz, MapBuilder.TAG_ROAD)
			rz:SetAttribute("Axis", "Z")
			rz:SetAttribute("Line", line)
			-- markings for both axes' segment k on this line
			for _, along in { 20, 60, 100 } do
				local p = a + along
				markingPart(ctx, "CenterDash", Vector3.new(16, MARK_T, 0.8), Vector3.new(p, MARK_Y, c), C.dash)
				markingPart(ctx, "CenterDash", Vector3.new(0.8, MARK_T, 16), Vector3.new(c, MARK_Y, p), C.dash)
			end
			for _, sgn in { -1, 1 } do
				markingPart(
					ctx,
					"EdgeLine",
					Vector3.new(len, MARK_T, 0.6),
					Vector3.new(mid, MARK_Y, c + sgn * edgeOff),
					C.edge
				)
				markingPart(
					ctx,
					"EdgeLine",
					Vector3.new(0.6, MARK_T, len),
					Vector3.new(c + sgn * edgeOff, MARK_Y, mid),
					C.edge
				)
			end
		end
	end
	-- crosswalks at downtown intersections
	local R = MapConfig.DOWNTOWN_RADIUS
	for i = -R, R do
		for j = -R, R do
			local ic = Vector3.new(i * S, MARK_Y, j * S)
			for _, dir in { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) } do
				local perp = Vector3.new(dir.Z, 0, dir.X)
				local center = ic + dir * (HALF_ROAD + 4.5)
				for _, off in { -13.5, -4.5, 4.5, 13.5 } do
					local p = center + perp * off
					local size = if math.abs(dir.X) > 0 then Vector3.new(6, MARK_T, 5) else Vector3.new(5, MARK_T, 6)
					markingPart(ctx, "Crosswalk", size, p, C.crosswalk)
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- Blocks: sidewalks, lots, curb cuts, street lights, hydrants
---------------------------------------------------------------------------------------------------------------

local function buildBlockBase(ctx: Ctx, bx: number, bz: number, origin: Vector3, district: string, cuts: { Cut })
	local key = blockKey(bx, bz)
	local poi = poiByBlock[key]
	local plot = plotByBlock[key]
	local hgt = CURB_TOP - GROUND_BOTTOM
	local yc = (CURB_TOP + GROUND_BOTTOM) / 2

	-- lot interior
	local lotColor = if plot then C.lot.plot else C.lot[district]
	local lotMat = Enum.Material.SmoothPlastic
	local reflect: number? = nil
	if poi == "Park" then
		lotColor, lotMat = rgb(104, 192, 80), Enum.Material.Grass
	elseif poi == "SpawnPlaza" then
		lotColor = rgb(240, 226, 198)
	elseif poi == "Dealership" then
		lotColor, reflect = rgb(234, 236, 246), 0.06
	elseif poi == "PoliceHQ" then
		lotColor = rgb(176, 184, 204)
	elseif poi == "ChopShop" then
		lotColor = rgb(150, 126, 98)
	elseif poi == "StuntPark" then
		lotColor = rgb(84, 90, 116)
	elseif poi == "Pier" then
		lotColor, lotMat = rgb(206, 156, 104), Enum.Material.WoodPlanks
	elseif not plot and (district == "lowrise" or district == "beach") then
		lotMat = Enum.Material.Grass
	end
	local lot = part(
		ctx.blocks,
		"Lot",
		Vector3.new(LOT_HALF * 2, hgt, LOT_HALF * 2),
		CFrame.new(origin.X, yc, origin.Z),
		lotColor,
		{
			material = lotMat,
			reflectance = reflect,
			shadow = false,
		}
	)
	lot:SetAttribute("BlockX", bx)
	lot:SetAttribute("BlockZ", bz)
	lot:SetAttribute("District", district)
	lot:SetAttribute("Poi", poi or "")
	lot:SetAttribute("PlotIndex", plot or 0)

	-- sidewalk strips (N/S span the corners; W/E between them), split around curb cuts
	for _, sideName in SIDE_ORDER do
		local side = SIDES[sideName]
		local lo, hi = -BLOCK_HALF, BLOCK_HALF
		if sideName == "W" or sideName == "E" then
			lo, hi = -LOT_HALF, LOT_HALF
		end
		local sideCuts = {}
		for _, cut in cuts do
			if cut.side == sideName then
				table.insert(sideCuts, cut)
			end
		end
		table.sort(sideCuts, function(x, y)
			return x.a < y.a
		end)
		local stripCenter = side.normal * (BLOCK_HALF - SW / 2)
		local function strip(a: number, b: number)
			if b - a < 0.05 then
				return
			end
			local mid = (a + b) / 2
			local pos = origin + stripCenter + side.along * mid
			local size = if math.abs(side.along.X) > 0 then Vector3.new(b - a, hgt, SW) else Vector3.new(SW, hgt, b - a)
			part(ctx.blocks, "Sidewalk", size, CFrame.new(pos.X, yc, pos.Z), C.sidewalk, { shadow = false })
		end
		local cursor = lo
		for _, cut in sideCuts do
			local a, b = math.max(cut.a, lo), math.min(cut.b, hi)
			strip(cursor, a)
			-- curb-cut ramp: low edge at the road, top flush with the sidewalk
			local mid = (a + b) / 2
			local pos = origin + stripCenter + side.along * mid
			local center = Vector3.new(pos.X, ROAD_Y + CURB_H / 2, pos.Z)
			local rampPart = wedge(
				ctx.blocks,
				"DrivewayRamp",
				Vector3.new(b - a, CURB_H, SW),
				CFrame.lookAt(center, center + side.normal),
				C.sidewalk
			)
			rampPart.CastShadow = false
			cursor = b
		end
		strip(cursor, hi)
	end

	-- street lights: one per side, avoiding curb cuts
	for si, sideName in SIDE_ORDER do
		local side = SIDES[sideName]
		local first = if (bx + bz + si) % 2 == 0 then 34 else -34
		for _, off in { first, -first } do
			local blocked = false
			for _, cut in cuts do
				if cut.side == sideName and off >= cut.a - 4 and off <= cut.b + 4 then
					blocked = true
				end
			end
			if not blocked then
				local g = origin + side.normal * (BLOCK_HALF - 1.4) + side.along * off
				streetLight(ctx, Vector3.new(g.X, CURB_TOP, g.Z), side.normal)
				break
			end
		end
	end
	-- hydrant on a sidewalk corner (every other block)
	if (bx + bz) % 2 == 0 then
		local sx = if bx % 2 == 0 then 1 else -1
		local sz = if bz % 3 == 0 then 1 else -1
		hydrant(ctx.props, Vector3.new(origin.X + sx * (BLOCK_HALF - 4), CURB_TOP, origin.Z + sz * (BLOCK_HALF - 2)))
	end
end

---------------------------------------------------------------------------------------------------------------
-- POIs
---------------------------------------------------------------------------------------------------------------

local function L(o: Vector3, x: number, y: number, z: number): CFrame
	return CFrame.new(o.X + x, o.Y + y, o.Z + z)
end

local function facing(pos: Vector3, dir: Vector3): CFrame
	return CFrame.lookAt(pos, pos + dir)
end

local function buildSpawnPlaza(ctx: Ctx, f: Folder, o: Vector3)
	local rng = Random.new(MapBuilder.SEED + 11)
	-- mosaic rings around the spawn
	cyl(f, "PlazaRing", 0.2, 84, L(o, 0, 0, 0), rgb(70, 204, 204), { shadow = false })
	cyl(f, "PlazaRing", 0.2, 72, L(o, 0, 0.1, 0), rgb(250, 240, 220), { shadow = false })
	cyl(f, "PlazaRing", 0.2, 26, L(o, 0, 0.2, 0), rgb(255, 120, 170), { shadow = false })

	-- SpawnLocation (fallback spawn; PlotService moves characters into their garages)
	local spawnCf = MapLayout.spawnCFrame()
	local spawnPad = Instance.new("SpawnLocation")
	spawnPad.Name = "SpawnLocation"
	spawnPad.Anchored = true
	spawnPad.Size = Vector3.new(12, 1, 12)
	spawnPad.CFrame = spawnCf * CFrame.new(0, 0.1, 0)
	spawnPad.Color = C.pink
	spawnPad.Material = Enum.Material.SmoothPlastic
	spawnPad.TopSurface = Enum.SurfaceType.Smooth
	spawnPad.BottomSurface = Enum.SurfaceType.Smooth
	spawnPad.Neutral = true
	spawnPad.Duration = 0
	spawnPad.Enabled = true
	spawnPad.AllowTeamChangeOnTouch = false
	spawnPad.CanTouch = false
	spawnPad.Parent = f
	cyl(
		f,
		"SpawnRing",
		0.3,
		16,
		spawnCf * CFrame.new(0, 0.3, 0),
		C.cyan,
		{ material = Enum.Material.Neon, collide = false, shadow = false }
	)

	-- fountain (west of the spawn, so the spawn looks east at the Dealership)
	local fo = Vector3.new(o.X - 30, o.Y, o.Z)
	local stone = rgb(228, 222, 210)
	cyl(f, "FountainBasin", 2.4, 28, L(fo, 0, 1.2, 0), stone)
	cyl(
		f,
		"FountainTrim",
		0.6,
		28.4,
		L(fo, 0, 1.4, 0),
		C.cyan,
		{ material = Enum.Material.Neon, collide = false, shadow = false }
	)
	cyl(
		f,
		"FountainWater",
		0.3,
		25,
		L(fo, 0, 2.5, 0),
		C.water,
		{ collide = false, transparency = 0.15, reflectance = 0.2, shadow = false }
	)
	cyl(f, "FountainPillar", 7, 3.5, L(fo, 0, 3.5, 0), stone)
	cyl(f, "FountainBowl", 1, 12, L(fo, 0, 7, 0), stone)
	cyl(f, "FountainBowlWater", 0.2, 10.6, L(fo, 0, 7.55, 0), C.water, { collide = false, shadow = false })
	cyl(
		f,
		"FountainJet",
		5,
		1.6,
		L(fo, 0, 10, 0),
		rgb(160, 236, 255),
		{ material = Enum.Material.Neon, collide = false, shadow = false }
	)
	for _, d in { Vector3.new(0, 0, 1), Vector3.new(0, 0, -1), Vector3.new(-1, 0, 0) } do
		local p = fo + d * 20
		bench(f, CFrame.lookAt(p, p - d), rgb(255, 120, 170))
	end

	-- leaderboards facing the spawn
	local boards = {
		{ stat = "totalEarned", z = -28, glow = C.yellow, name = "LeaderboardEarned" },
		{ stat = "steals", z = 28, glow = C.pink, name = "LeaderboardSteals" },
	}
	for _, b in boards do
		local ground = Vector3.new(o.X + 33, o.Y, o.Z + b.z)
		local center = ground + Vector3.new(0, 13.5, 0)
		local look = Vector3.new(spawnCf.Position.X, center.Y, spawnCf.Position.Z)
		local cf = CFrame.lookAt(center, look)
		local board = part(f, b.name, Vector3.new(24, 15, 1), cf, rgb(18, 20, 38))
		board:SetAttribute("Stat", b.stat)
		board:SetAttribute("Face", "Front")
		tag(board, "LeaderboardBoard")
		neon(f, b.name .. "Glow", Vector3.new(25.4, 16.4, 0.5), cf * CFrame.new(0, 0, 0.4), b.glow)
		for _, sx in { -9, 9 } do
			local legPos = (cf * CFrame.new(sx, -10.25, 0.3)).Position
			part(f, "BoardLeg", Vector3.new(1, 6.5, 1), CFrame.new(legPos), C.metal)
		end
	end

	-- welcome sign behind the fountain (both faces)
	local signPos = Vector3.new(o.X - 47, o.Y + 17, o.Z)
	sign(
		f,
		"WelcomeSign",
		"HOTWIRE CITY",
		Vector3.new(34, 8, 1.4),
		facing(signPos, Vector3.new(1, 0, 0)),
		rgb(26, 28, 52),
		C.yellow,
		{
			glow = C.pink,
			back = true,
		}
	)
	for _, sz in { -12, 12 } do
		part(f, "SignPost", Vector3.new(1.4, 13, 1.4), L(o, -47, 6.5, sz), C.metal)
	end

	-- corner planters with palms
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local p = Vector3.new(o.X + sx * 42, o.Y, o.Z + sz * 42)
			part(f, "Planter", Vector3.new(9, 2, 9), CFrame.new(p + Vector3.new(0, 1, 0)), rgb(214, 170, 130))
			palm(ctx.props, p + Vector3.new(0, 2, 0), rand(rng, 17, 22), rng)
		end
	end
end

local function buildDealership(_ctx: Ctx, f: Folder, o: Vector3)
	-- turntable pads (DealershipService puts cars on MapLayout.dealerPads())
	for i, cf in MapLayout.dealerPads() do
		local pad = cyl(f, "DealerPad" .. i, 0.2, 20, cf * CFrame.new(0, 0.1, 0), rgb(36, 38, 58), { shadow = false })
		pad:SetAttribute("PadIndex", i)
		tag(pad, "DealerPad")
		cyl(f, "DealerPadRim", 0.1, 21.4, cf * CFrame.new(0, 0.05, 0), if i % 2 == 0 then C.cyan else C.pink, {
			material = Enum.Material.Neon,
			collide = false,
			shadow = false,
		})
	end
	-- glass walls on W/S/E; the north side stays open so stolen cars can drive out to the north road
	local glass = rgb(170, 230, 255)
	local gopts: PartOpts = { material = Enum.Material.Glass, transparency = 0.55, shadow = false }
	part(f, "GlassWall", Vector3.new(100, 16, 0.6), L(o, 0, 8, 46), glass, gopts)
	part(f, "GlassWall", Vector3.new(0.6, 16, 92), L(o, 50, 8, 0), glass, gopts)
	part(f, "GlassWall", Vector3.new(0.6, 16, 92), L(o, -50, 8, 0), glass, gopts)
	for _, x in { -25, 0, 25 } do
		part(f, "Mullion", Vector3.new(1, 16, 1), L(o, x, 8, 46), C.white)
	end
	for _, z in { -23, 0, 23 } do
		part(f, "Mullion", Vector3.new(1, 16, 1), L(o, 50, 8, z), C.white)
		part(f, "Mullion", Vector3.new(1, 16, 1), L(o, -50, 8, z), C.white)
	end
	for _, x in { -50.5, 50.5 } do
		part(f, "Pillar", Vector3.new(2.6, 18, 2.6), L(o, x, 9, -47.5), C.white)
		part(f, "Pillar", Vector3.new(2.6, 18, 2.6), L(o, x, 9, 46.5), C.white)
	end
	-- roof canopy with a neon edge and light panels
	-- canopy frame around a big skylight (display cars stay visible from above)
	part(f, "Canopy", Vector3.new(106, 1.6, 14), L(o, 0, 18.8, -42.5), C.white)
	part(f, "Canopy", Vector3.new(106, 1.6, 14), L(o, 0, 18.8, 41.5), C.white)
	part(f, "Canopy", Vector3.new(14, 1.6, 70), L(o, -46, 18.8, -0.5), C.white)
	part(f, "Canopy", Vector3.new(14, 1.6, 70), L(o, 46, 18.8, -0.5), C.white)
	part(f, "Skylight", Vector3.new(78, 0.6, 70), L(o, 0, 19.2, -0.5), rgb(170, 230, 255), {
		material = Enum.Material.Glass,
		transparency = 0.6,
		shadow = false,
	})
	part(f, "SkylightBeam", Vector3.new(1, 1.2, 70), L(o, 0, 19.2, -0.5), C.white)
	neon(f, "CanopyEdge", Vector3.new(106.6, 0.6, 98.6), L(o, 0, 18.3, -0.5), C.pink)
	for _, z in { -22, 22 } do
		local panel = neon(f, "LightPanel", Vector3.new(70, 0.3, 3), L(o, 0, 17.85, z * 1.95), rgb(255, 250, 235))
		local light = Instance.new("PointLight")
		light.Range = 40
		light.Brightness = 1.2
		light.Shadows = false
		light.Parent = panel
	end
	-- signs: north (road) + west (faces the spawn plaza)
	sign(
		f,
		"DealerSignNorth",
		"HOTWIRE MOTORS",
		Vector3.new(64, 9, 1.2),
		facing(Vector3.new(o.X, o.Y + 24.6, o.Z - 48.5), Vector3.new(0, 0, -1)),
		rgb(24, 26, 50),
		C.white,
		{
			glow = C.cyan,
		}
	)
	sign(
		f,
		"DealerSignWest",
		"HOTWIRE MOTORS",
		Vector3.new(60, 8, 1.2),
		facing(Vector3.new(o.X - 52, o.Y + 24.1, o.Z), Vector3.new(-1, 0, 0)),
		rgb(24, 26, 50),
		C.yellow,
		{
			glow = C.pink,
		}
	)
	-- (no restock board here: DealershipService builds and draws its own countdown sign in front of the back glass)
end

local function buildPoliceHQ(_ctx: Ctx, f: Folder, o: Vector3)
	-- main building x in [-26, 44], z in [-42, 42]; entrance faces west (busted release spot at x = -50)
	local front = Vector3.new(-1, 0, 0)
	local bc = Vector3.new(o.X + 9, o.Y, o.Z)
	local origin = CFrame.lookAt(bc, bc + front) -- local X = world -Z, local -Z = west
	local w, d, h = 84, 70, 30
	local m = newBuilding(f, "PoliceHQ", origin, w, d, h)
	part(m, "Body", Vector3.new(w, h, d), origin * CFrame.new(0, h / 2, 0), C.white)
	for _, y in { 5.5, 15.5, 25.5 } do
		local win = band(m, "Windows", origin, w, d, y, 4.2, 0.4, C.windowDay, Enum.Material.Glass)
		nightGlow(win, rgb(200, 230, 255))
	end
	for _, y in { 10, 21 } do
		local b = band(m, "PoliceStripe", origin, w, d, y, 2.2, 0.6, C.police)
		nightGlow(b, C.police)
	end
	part(m, "Parapet", Vector3.new(w + 1, 1.6, d + 1), origin * CFrame.new(0, h + 0.8, 0), rgb(26, 40, 90))
	-- entrance portico + doors
	part(m, "Portico", Vector3.new(28, 1.2, 10), origin * CFrame.new(0, 12.6, -d / 2 - 5), C.white)
	neon(m, "PorticoTrim", Vector3.new(28.4, 0.5, 10.4), origin * CFrame.new(0, 12.1, -d / 2 - 5), C.police)
	for _, x in { -12.5, 12.5 } do
		part(m, "PorticoPillar", Vector3.new(1.6, 12, 1.6), origin * CFrame.new(x, 6, -d / 2 - 9), C.white)
	end
	deco(
		m,
		"Doors",
		Vector3.new(12, 9, 0.6),
		origin * CFrame.new(0, 4.5, -d / 2 - 0.3),
		rgb(30, 50, 100),
		Enum.Material.Glass
	)
	-- signs
	sign(
		m,
		"PoliceSign",
		"POLICE",
		Vector3.new(34, 7, 1.2),
		origin * CFrame.new(0, h + 5.2, -d / 2 + 0.6),
		C.police,
		C.white,
		{
			glow = C.white,
		}
	)
	sign(
		m,
		"PoliceSignNorth",
		"POLICE",
		Vector3.new(30, 6, 1.2),
		facing(Vector3.new(bc.X, o.Y + h + 4.6, o.Z - 42.4), Vector3.new(0, 0, -1)),
		C.police,
		C.white,
		{
			glow = C.white,
		}
	)
	-- rooftop: helipad, antenna, siren bars
	cyl(m, "Helipad", 0.5, 28, origin * CFrame.new(-12, h + 0.25, 10), rgb(56, 60, 76))
	neon(m, "HelipadH", Vector3.new(1.4, 0.2, 10), origin * CFrame.new(-15, h + 0.55, 10), C.yellow)
	neon(m, "HelipadH", Vector3.new(1.4, 0.2, 10), origin * CFrame.new(-9, h + 0.55, 10), C.yellow)
	neon(m, "HelipadH", Vector3.new(6, 0.2, 1.4), origin * CFrame.new(-12, h + 0.55, 10), C.yellow)
	part(m, "Antenna", Vector3.new(1, 20, 1), origin * CFrame.new(30, h + 10, 20), C.metal)
	neon(m, "SirenRed", Vector3.new(4, 1.4, 1.4), origin * CFrame.new(-w / 2 + 3, h + 2.3, -d / 2 + 1.5), C.red)
	neon(m, "SirenBlue", Vector3.new(4, 1.4, 1.4), origin * CFrame.new(w / 2 - 3, h + 2.3, -d / 2 + 1.5), C.police)
	-- flag pole in front
	part(f, "FlagPole", Vector3.new(0.6, 24, 0.6), L(o, -40, 12, 22), C.white)
	deco(f, "Flag", Vector3.new(0.2, 4, 7), L(o, -40, 21.5, 25.6), C.police)
end

local function buildGearShop(ctx: Ctx, f: Folder, o: Vector3)
	-- storefront open to the south; the counter sits at MapLayout.gearShopCounter()
	local wallColor = rgb(255, 196, 64)
	part(f, "ShopBackWall", Vector3.new(52, 18, 2), L(o, 0, 9, 9), wallColor)
	part(f, "ShopSideWall", Vector3.new(2, 18, 36), L(o, -25, 9, 26), wallColor)
	part(f, "ShopSideWall", Vector3.new(2, 18, 36), L(o, 25, 9, 26), wallColor)
	part(f, "ShopRoof", Vector3.new(54, 1.6, 38), L(o, 0, 18.8, 26), rgb(40, 44, 70))
	part(f, "ShopHeader", Vector3.new(52, 5, 2), L(o, 0, 15.5, 43), wallColor)
	for _, x in { -24.75, 24.75 } do
		part(f, "ShopPillar", Vector3.new(2.5, 13, 2.5), L(o, x, 6.5, 43), rgb(40, 44, 70))
	end
	part(f, "ShopFloor", Vector3.new(48, 0.2, 33), L(o, 0, 0.1, 26.5), rgb(56, 58, 96), { shadow = false })
	wedge(f, "ShopAwning", Vector3.new(48, 2, 5), L(o, 0, 13.8, 46.5) * CFrame.Angles(0, math.pi, 0), C.pink, false)

	-- the counter (ShopService finds it by tag)
	local counterCf = MapLayout.gearShopCounter()
	local counter =
		part(f, "GearShopCounter", Vector3.new(16, 3.6, 3), counterCf * CFrame.new(0, 1.8, 0), rgb(110, 70, 200))
	tag(counter, "GearShopCounter")
	neon(f, "CounterTrim", Vector3.new(16.2, 0.4, 0.2), counterCf * CFrame.new(0, 3.2, -1.55), C.cyan)
	part(f, "CounterTop", Vector3.new(16.6, 0.4, 3.6), counterCf * CFrame.new(0, 3.8, 0), C.white)

	-- wall of gear behind the counter
	for _, x in { -14, 14 } do
		part(f, "Shelf", Vector3.new(12, 10, 2.5), L(o, x, 5, 11.5), rgb(70, 50, 40))
	end
	deco(
		f,
		"BigBat",
		Vector3.new(1.4, 1.4, 11),
		L(o, 0, 9, 10.4) * CFrame.Angles(0, 0, 0) * CFrame.Angles(math.rad(-50), 0, 0),
		C.wood
	)
	neon(f, "ZapperBolt", Vector3.new(1.2, 6, 0.3), L(o, -6, 12, 10.2) * CFrame.Angles(0, 0, math.rad(25)), C.yellow)
	neon(
		f,
		"ZapperBolt",
		Vector3.new(1.2, 6, 0.3),
		L(o, -4.4, 8.5, 10.2) * CFrame.Angles(0, 0, math.rad(-25)),
		C.yellow
	)
	deco(f, "SpikeDisplay", Vector3.new(8, 1, 0.6), L(o, 6, 13, 10.3), C.red)
	local lamp = neon(f, "ShopLight", Vector3.new(30, 0.3, 4), L(o, 0, 17.8, 26), rgb(255, 250, 235))
	local light = Instance.new("PointLight")
	light.Range = 36
	light.Brightness = 1.3
	light.Shadows = false
	light.Parent = lamp

	sign(
		f,
		"GearShopSign",
		"GEAR SHOP",
		Vector3.new(40, 6, 1.2),
		facing(Vector3.new(o.X, o.Y + 22.6, o.Z + 44.6), Vector3.new(0, 0, 1)),
		rgb(24, 26, 50),
		C.yellow,
		{
			glow = C.cyan,
		}
	)

	-- downtown tower on the north half
	local rng = Random.new(MapBuilder.SEED + 23)
	local tc = Vector3.new(o.X, o.Y, o.Z - 26)
	buildTower(ctx.buildings, rng, facing(tc, Vector3.new(0, 0, -1)), 42, 36, 130)
end

local function buildSprayShop(
	ctx: Ctx,
	f: Folder,
	o: Vector3,
	zoneCf: CFrame,
	zoneSize: Vector3,
	color: Color3,
	accent: Color3,
	rng: Random
)
	-- booth around the zone, open on the road side (-Z); the zone interior stays clear
	local zc = zoneCf.Position
	local hx = zoneSize.X / 2 + 3 -- wall center offset (wall 2 thick, 2 studs clearance)
	local back = zc.Z + zoneSize.Z / 2 + 2 -- back wall center z
	local front = o.Z - LOT_HALF
	local wallLen = back - front
	local wallH = 18
	for _, sx in { -1, 1 } do
		local wp = Vector3.new(zc.X + sx * hx, o.Y + wallH / 2, front + wallLen / 2)
		part(f, "BoothWall", Vector3.new(2, wallH, wallLen), CFrame.new(wp), color)
		neon(f, "BoothStripe", Vector3.new(0.3, 0.6, wallLen - 4), CFrame.new(wp.X - sx * 1.15, o.Y + 12, wp.Z), accent)
		-- paint splats on the outside
		for k = 1, 2 do
			deco(
				f,
				"PaintSplat",
				Vector3.new(0.2, rand(rng, 2.5, 4.5), rand(rng, 3, 6)),
				CFrame.new(wp.X + sx * 1.1, o.Y + rand(rng, 4, 13), front + wallLen * (k / 3)),
				pick(rng, NEON)
			)
		end
	end
	part(f, "BoothBackWall", Vector3.new(hx * 2 + 2, wallH, 2), CFrame.new(zc.X, o.Y + wallH / 2, back), color)
	neon(f, "BoothStripe", Vector3.new(hx * 2 - 2, 0.6, 0.3), CFrame.new(zc.X, o.Y + 12, back - 1.15), accent)
	part(
		f,
		"BoothRoof",
		Vector3.new(hx * 2 + 4, 1.6, wallLen + 3),
		CFrame.new(zc.X, o.Y + wallH + 0.8, front + wallLen / 2 - 0.5),
		rgb(36, 38, 60)
	)
	part(f, "BoothHeader", Vector3.new(hx * 2 + 2, 3, 2), CFrame.new(zc.X, o.Y + 16.5, front), color)
	neon(f, "BoothHeaderTrim", Vector3.new(hx * 2 + 2, 0.5, 0.3), CFrame.new(zc.X, o.Y + 15.2, front - 1.1), accent)
	deco(
		f,
		"SprayFloor",
		Vector3.new(zoneSize.X, 0.1, zoneSize.Z - 2),
		CFrame.new(zc.X, o.Y + 0.05, zc.Z + 1),
		rgb(40, 42, 64)
	)
	neon(f, "SprayFloorEdge", Vector3.new(zoneSize.X, 0.12, 0.6), CFrame.new(zc.X, o.Y + 0.06, front + 1.5), accent)
	sign(
		f,
		"SpraySign",
		"SPRAY",
		Vector3.new(24, 6, 1.2),
		facing(Vector3.new(zc.X, o.Y + 22.7, front - 0.6), Vector3.new(0, 0, -1)),
		rgb(255, 52, 140),
		C.white,
		{
			glow = C.cyan,
		}
	)
	-- the rest of the block: a paint store beside the booth and mid-rise on the south half
	buildShop(
		ctx.buildings,
		rng,
		facing(Vector3.new(o.X + 35, o.Y, o.Z - 37), Vector3.new(0, 0, -1)),
		26,
		20,
		16,
		"PAINT"
	)
	palm(ctx.props, Vector3.new(o.X - 34, o.Y, o.Z - 40), 18, rng)
	bench(ctx.props, facing(Vector3.new(o.X - 34, o.Y, o.Z - 30), Vector3.new(0, 0, -1)))
	fillArea(ctx, rng, "midrise", o, { x0 = -BUILD_HALF, x1 = BUILD_HALF, z0 = back + 4 - o.Z, z1 = BUILD_HALF })
end

local function buildChopShop(_ctx: Ctx, f: Folder, o: Vector3, zoneCf: CFrame, zoneSize: Vector3)
	local rng = Random.new(MapBuilder.SEED + 31)
	local zc = zoneCf.Position
	local hx = zoneSize.X / 2 + 3
	local back = zc.Z - zoneSize.Z / 2 - 2
	local front = o.Z + LOT_HALF
	local wallLen = front - back
	local wallH = 18
	local metal = rgb(120, 126, 140)
	for _, sx in { -1, 1 } do
		part(
			f,
			"ShopWall",
			Vector3.new(2, wallH, wallLen),
			CFrame.new(zc.X + sx * hx, o.Y + wallH / 2, back + wallLen / 2),
			metal,
			{
				material = Enum.Material.CorrodedMetal,
			}
		)
		neon(
			f,
			"WarningStripe",
			Vector3.new(0.3, 0.6, wallLen - 4),
			CFrame.new(zc.X + sx * (hx - 1.15), o.Y + 12, back + wallLen / 2),
			C.orange
		)
	end
	part(f, "ShopBackWall", Vector3.new(hx * 2 + 2, wallH, 2), CFrame.new(zc.X, o.Y + wallH / 2, back), metal, {
		material = Enum.Material.CorrodedMetal,
	})
	part(
		f,
		"ShopRoof",
		Vector3.new(hx * 2 + 4, 1.6, wallLen + 3),
		CFrame.new(zc.X, o.Y + wallH + 0.8, back + wallLen / 2 + 0.5),
		rgb(60, 52, 48)
	)
	part(f, "ShopHeader", Vector3.new(hx * 2 + 2, 3, 2), CFrame.new(zc.X, o.Y + 16.5, front), rgb(40, 40, 46))
	neon(f, "HazardTrim", Vector3.new(hx * 2 + 2, 0.5, 0.3), CFrame.new(zc.X, o.Y + 15.2, front + 1.1), C.yellow)
	deco(
		f,
		"ChopFloor",
		Vector3.new(zoneSize.X, 0.1, zoneSize.Z - 3),
		CFrame.new(zc.X, o.Y + 0.05, zc.Z - 1.5),
		rgb(60, 56, 54)
	)
	sign(
		f,
		"ChopSign",
		"CHOP SHOP",
		Vector3.new(30, 6, 1.2),
		facing(Vector3.new(zc.X, o.Y + 22.7, front + 0.6), Vector3.new(0, 0, 1)),
		C.orange,
		C.dark,
		{
			glow = C.yellow,
		}
	)
	-- junkyard: fence, crushed cars, tires, crane, barrels
	local fence = rgb(150, 92, 62)
	local fh = 8
	local edge = LOT_HALF - 0.4
	part(
		f,
		"Fence",
		Vector3.new(LOT_HALF * 2, fh, 0.6),
		L(o, 0, fh / 2, -edge),
		fence,
		{ material = Enum.Material.CorrodedMetal }
	)
	part(
		f,
		"Fence",
		Vector3.new(0.6, fh, LOT_HALF * 2),
		L(o, -edge, fh / 2, 0),
		fence,
		{ material = Enum.Material.CorrodedMetal }
	)
	part(
		f,
		"Fence",
		Vector3.new(0.6, fh, LOT_HALF * 2),
		L(o, edge, fh / 2, 0),
		fence,
		{ material = Enum.Material.CorrodedMetal }
	)
	local gapHalf = hx + 1
	local segLen = LOT_HALF - gapHalf
	for _, sx in { -1, 1 } do
		part(f, "Fence", Vector3.new(segLen, fh, 0.6), L(o, sx * (gapHalf + segLen / 2), fh / 2, edge), fence, {
			material = Enum.Material.CorrodedMetal,
		})
	end
	local junk = { rgb(170, 70, 60), rgb(80, 110, 160), rgb(120, 130, 80), rgb(150, 150, 150), rgb(200, 160, 60) }
	for _, stack in { { -34, -32 }, { -8, -38 }, { 32, -30 }, { -36, 8 } } do
		for k = 0, 2 do
			local yaw = rand(rng, -0.3, 0.3)
			part(
				f,
				"CrushedCar",
				Vector3.new(8, 3, 5),
				L(o, stack[1] + rand(rng, -0.6, 0.6), 1.5 + k * 3, stack[2]) * CFrame.Angles(0, yaw, 0),
				pick(rng, junk),
				{
					material = Enum.Material.CorrodedMetal,
				}
			)
		end
	end
	for _, t in { { 36, 6 }, { 40, 14 }, { -30, 30 }, { 10, -20 } } do
		for k = 0, 1 do
			cyl(f, "Tire", 1.2, 3.4, L(o, t[1], 0.6 + k * 1.2, t[2]), rgb(28, 28, 32))
		end
	end
	local crane = rgb(255, 196, 40)
	part(f, "CraneMast", Vector3.new(2.5, 32, 2.5), L(o, 34, 16, -10), crane)
	part(f, "CraneBoom", Vector3.new(2, 2, 34), L(o, 34, 32, -24), crane)
	deco(f, "CraneCable", Vector3.new(0.3, 12, 0.3), L(o, 34, 25, -38), C.dark)
	cyl(f, "CraneMagnet", 1.2, 6, L(o, 34, 18.4, -38), C.dark)
	for _, b in { { -44, 40 }, { -40, 43 }, { 44, 42 } } do
		cyl(f, "Barrel", 3.4, 2.4, L(o, b[1], 1.7, b[2]), if b[1] > 0 then C.police else C.red)
	end
end

-- Quarter pipe made of tilted planks approximating a circular transition.
local function quarterPipe(
	f: Folder,
	start: Vector3,
	outward: Vector3,
	lateral: Vector3,
	width: number,
	radius: number,
	color: Color3
)
	local steps = 4
	local stepAngle = math.rad(20)
	for i = 0, steps - 1 do
		local a0, a1 = i * stepAngle, (i + 1) * stepAngle
		local p0s, p0y = radius * math.sin(a0), radius * (1 - math.cos(a0))
		local p1s, p1y = radius * math.sin(a1), radius * (1 - math.cos(a1))
		local phi = (a0 + a1) / 2
		local ms, my = (p0s + p1s) / 2 + 0.5 * math.sin(phi), (p0y + p1y) / 2 - 0.5 * math.cos(phi)
		local len = math.sqrt((p1s - p0s) ^ 2 + (p1y - p0y) ^ 2) + 0.35
		local pos = start + outward * ms + Vector3.new(0, my, 0)
		local up = outward * -math.sin(phi) + Vector3.new(0, math.cos(phi), 0)
		local cf = CFrame.fromMatrix(pos, lateral, up)
		part(f, "PipePlank", Vector3.new(width, 1, len), cf, color)
	end
	local topS = radius * math.sin(steps * stepAngle)
	local topY = radius * (1 - math.cos(steps * stepAngle))
	local deckLen = 4.5
	local deckCenter = start + outward * (topS + deckLen / 2) + Vector3.new(0, topY / 2, 0)
	local deckSize = if math.abs(outward.X) > 0.5
		then Vector3.new(deckLen, topY, width)
		else Vector3.new(width, topY, deckLen)
	part(f, "PipeDeck", deckSize, CFrame.new(deckCenter), rgb(60, 62, 84))
	local copingPos = start + outward * (topS + 0.2) + Vector3.new(0, topY + 0.2, 0)
	local copingSize = if math.abs(outward.X) > 0.5 then Vector3.new(0.6, 0.5, width) else Vector3.new(width, 0.5, 0.6)
	neon(f, "PipeCoping", copingSize, CFrame.new(copingPos), C.yellow)
end

local function buildStuntPark(_ctx: Ctx, f: Folder, o: Vector3)
	local east = Vector3.new(1, 0, 0)
	local west = Vector3.new(-1, 0, 0)
	-- big jump over a pool (approach from the west road curb cut)
	ramp(f, "LaunchRamp", o + Vector3.new(-36, 0, -30), east, 18, 28, 9, C.orange)
	neon(f, "LaunchLip", Vector3.new(0.6, 0.5, 18), L(o, -22.3, 9, -30), C.yellow)
	part(f, "PoolFloor", Vector3.new(30, 0.2, 22), L(o, -7, 0.1, -30), rgb(110, 210, 240), { shadow = false })
	part(f, "PoolWater", Vector3.new(30, 1.4, 22), L(o, -7, 0.9, -30), C.water, {
		material = Enum.Material.Glass,
		collide = false,
		transparency = 0.35,
		shadow = false,
	})
	for _, z in { -41.5, -18.5 } do
		part(f, "PoolRim", Vector3.new(31, 1, 1), L(o, -7, 0.5, z), C.white)
	end
	ramp(f, "LandingRamp", o + Vector3.new(24, 0, -30), west, 22, 32, 8, C.cyan)
	-- half-pipe (two quarter pipes facing each other)
	local lateral = Vector3.new(0, 0, 1)
	quarterPipe(f, o + Vector3.new(-30, 0, 27), west, lateral, 26, 12, rgb(255, 90, 160))
	quarterPipe(f, o + Vector3.new(30, 0, 27), east, lateral, 26, 12, rgb(130, 100, 255))
	deco(f, "PipeStripe", Vector3.new(60, 0.1, 1), L(o, 0, 0.05, 27), C.white)
	-- kickers
	for i, x in { -30, 0, 30 } do
		ramp(f, "Kicker", o + Vector3.new(x, 0, -4), east, 10, 9, 2.6 + i * 0.5, ({ C.lime, C.yellow, C.pink })[i])
	end
	-- mega ramp along the south edge: launches cars east over the flat
	ramp(f, "MegaRamp", o + Vector3.new(-21, 0, 47), east, 9, 52, 14, C.yellow)
	neon(f, "MegaLip", Vector3.new(0.6, 0.5, 9), L(o, 4.7, 14, 47), C.pink)
	-- painted floor stripes
	for i, z in { -10, 7 } do
		deco(
			f,
			"FloorStripe",
			Vector3.new(96, 0.1, 1.2),
			L(o, 0, 0.05, z),
			if i == 1 then C.pink else C.cyan,
			Enum.Material.Neon
		)
	end
	for _, x in { -40, -20, 0, 20, 40 } do
		deco(f, "FloorStripe", Vector3.new(1.2, 0.1, 15), L(o, x, 0.05, -1.5), C.white)
	end
	-- bleachers on the north edge
	for k = 0, 2 do
		part(
			f,
			"Bleacher",
			Vector3.new(36, 1.4 + k * 1.4, 3),
			L(o, 28, (1.4 + k * 1.4) / 2, -44 - k * 3),
			if k % 2 == 0 then C.white else C.police
		)
	end
	-- entrance arch over the west approach
	for _, z in { -46.8, -13.2 } do
		part(f, "ArchPillar", Vector3.new(2.4, 19, 2.4), L(o, -56.5, 9.5, z), C.dark)
		neon(f, "ArchPillarTrim", Vector3.new(2.6, 0.6, 2.6), L(o, -56.5, 18.6, z), C.lime)
	end
	sign(
		f,
		"StuntSign",
		"STUNT PARK",
		Vector3.new(36, 6, 1.4),
		facing(Vector3.new(o.X - 56.5, o.Y + 22, o.Z - 30), west),
		rgb(30, 32, 56),
		C.lime,
		{
			glow = C.pink,
			back = true,
		}
	)
end

local function buildPark(ctx: Ctx, f: Folder, o: Vector3)
	local rng = Random.new(MapBuilder.SEED + 41)
	-- pond
	cyl(f, "PondRim", 0.3, 43, L(o, 12, 0, 8), rgb(214, 200, 168), { shadow = false })
	cyl(f, "PondRim", 0.3, 29, L(o, -10, 0, 22), rgb(214, 200, 168), { shadow = false })
	cyl(f, "Pond", 0.3, 40, L(o, 12, 0.15, 8), C.water, { reflectance = 0.15, shadow = false })
	cyl(f, "Pond", 0.3, 26, L(o, -10, 0.15, 22), C.water, { reflectance = 0.15, shadow = false })
	for _, lp in { { 6, 2 }, { 20, 14 }, { -12, 26 } } do
		cyl(f, "LilyPad", 0.1, 2.6, L(o, lp[1], 0.36, lp[2]), C.leafB, { collide = false, shadow = false })
	end
	-- paths
	local path = rgb(230, 208, 164)
	part(f, "Path", Vector3.new(LOT_HALF * 2, 0.2, 5), L(o, 0, 0.1, -30), path, { shadow = false })
	part(f, "Path", Vector3.new(5, 0.2, LOT_HALF * 2), L(o, -35, 0.1, 0), path, { shadow = false })
	-- trees
	for _, t in
		{
			{ -46, -46 },
			{ -20, -44 },
			{ 8, -46 },
			{ 46, -44 },
			{ -46, -14 },
			{ -22, -12 },
			{ 44, -18 },
			{ -46, 14 },
			{ 44, 34 },
			{ -46, 44 },
			{ -24, 46 },
			{ 6, 44 },
			{ 16, 47 },
			{ 46, 8 },
		}
	do
		roundTree(ctx.props, Vector3.new(o.X + t[1], o.Y, o.Z + t[2]), rand(rng, 14, 22), rng)
	end
	-- benches along the paths
	for _, b in { { -10, -26.5, 1 }, { 20, -26.5, 1 }, { -31.5, 8, 0 }, { -31.5, -46, 0 } } do
		local p = Vector3.new(o.X + b[1], o.Y, o.Z + b[2])
		local dir = if b[3] == 1 then Vector3.new(0, 0, -1) else Vector3.new(-1, 0, 0)
		bench(f, facing(p, dir), rgb(90, 160, 90))
	end
	-- gazebo
	local g = Vector3.new(o.X + 30, o.Y, o.Z - 44)
	cyl(f, "GazeboFloor", 1, 14, L(g, 0, 0.5, 0), C.white)
	for k = 0, 3 do
		local a = k * math.pi / 2 + math.pi / 4
		part(f, "GazeboPost", Vector3.new(0.8, 9, 0.8), L(g, math.cos(a) * 5.5, 5.5, math.sin(a) * 5.5), C.white)
	end
	cyl(f, "GazeboRoof", 1.2, 16, L(g, 0, 10.6, 0), rgb(200, 80, 90))
	cyl(f, "GazeboRoofTop", 2, 8, L(g, 0, 12.2, 0), rgb(200, 80, 90))
	-- flower beds
	for i, fb in { { -20, -36 }, { 14, -36 }, { -42, -24 }, { -42, 30 } } do
		part(
			f,
			"FlowerBed",
			Vector3.new(7, 0.9, 3),
			L(o, fb[1], 0.45, fb[2]),
			({ C.red, C.yellow, C.pink, C.purple })[i]
		)
	end
	-- playground slide
	part(f, "SlideTower", Vector3.new(5, 7, 5), L(o, 32, 3.5, 30), C.yellow)
	ramp(f, "Slide", o + Vector3.new(32, 0, 40.5), Vector3.new(0, 0, -1), 3.4, 16, 7, C.red)
	sign(
		f,
		"ParkSign",
		"CITY PARK",
		Vector3.new(16, 4, 0.8),
		facing(Vector3.new(o.X + 40, o.Y + 6, o.Z - LOT_HALF + 1), Vector3.new(0, 0, -1)),
		rgb(60, 130, 70),
		C.white,
		{
			maxDistance = 300,
			collide = true,
		}
	)
	part(f, "SignPost", Vector3.new(0.8, 4, 0.8), L(o, 40, 2, -LOT_HALF + 1.2), C.wood)
end

local function buildFerrisWheel(f: Folder, hub: Vector3, axle: Vector3)
	local R = 32
	local W = CFrame.lookAt(hub, hub + axle)
	local wheelModel = Instance.new("Model")
	wheelModel.Name = "FerrisWheel"
	wheelModel:SetAttribute("Hub", hub)
	wheelModel:SetAttribute("Axis", axle)
	tag(wheelModel, "FerrisWheel")
	wheelModel.WorldPivot = W
	wheelModel.Parent = f
	local rotor = Instance.new("Model")
	rotor.Name = "Rotor"
	rotor.WorldPivot = W
	rotor.Parent = wheelModel
	local segs = 16
	local segLen = 2 * R * math.sin(math.pi / segs) + 0.6
	for i = 0, segs - 1 do
		local a = (i + 0.5) * 2 * math.pi / segs
		local cf = W * CFrame.new(R * math.cos(a), R * math.sin(a), 0) * CFrame.Angles(0, 0, a + math.pi / 2)
		neon(rotor, "Rim", Vector3.new(segLen, 1.2, 2.4), cf, if i % 2 == 0 then C.pink else C.cyan)
	end
	for k = 0, 3 do
		deco(rotor, "Spoke", Vector3.new(R * 2, 0.6, 0.6), W * CFrame.Angles(0, 0, k * math.pi / 4), C.white)
	end
	local colors = { C.red, C.orange, C.yellow, C.lime, C.cyan, C.police, C.purple, C.pink }
	for k = 0, 7 do
		local a = k * math.pi / 4 + math.pi / 8
		local attach = (W * CFrame.new(R * math.cos(a), R * math.sin(a), 0)).Position
		local yaw = W - W.Position
		local _, ry, _ = yaw:ToOrientation()
		deco(
			rotor,
			"Gondola",
			Vector3.new(4.5, 4, 4.5),
			CFrame.new(attach - Vector3.new(0, 3.2, 0)) * CFrame.Angles(0, ry, 0),
			colors[k + 1]
		)
	end
	part(
		wheelModel,
		"Hub",
		Vector3.new(7, 5, 5),
		W * CFrame.Angles(0, math.pi / 2, 0),
		C.dark,
		{ shape = Enum.PartType.Cylinder }
	)
	local groundY = CURB_TOP
	for _, side in { -4, 4 } do
		for _, sx in { -17, 17 } do
			local top = (W * CFrame.new(0, 0, side)).Position
			local foot = (W * CFrame.new(sx, 0, side)).Position
			foot = Vector3.new(foot.X, groundY, foot.Z)
			local mid = (top + foot) / 2
			part(wheelModel, "Leg", Vector3.new(1.4, 1.4, (top - foot).Magnitude), CFrame.lookAt(mid, top), C.white)
		end
	end
	part(wheelModel, "WheelBase", Vector3.new(40, 1, 14), W * CFrame.new(0, -(hub.Y - CURB_TOP) + 0.5, 0), C.dark)
end

local function buildPier(ctx: Ctx, f: Folder, o: Vector3)
	local rng = Random.new(MapBuilder.SEED + 53)
	-- ferris wheel landmark facing downtown
	local toCenter = Vector3.new(-o.X, 0, -o.Z)
	local axle = if toCenter.Magnitude > 1 then toCenter.Unit else Vector3.new(0, 0, 1)
	buildFerrisWheel(f, Vector3.new(o.X + 6, o.Y + 38, o.Z + 6), axle)
	-- game booths
	for i, x in { -36, -12, 12, 36 } do
		local bc = Vector3.new(o.X + x, o.Y, o.Z + 44)
		part(f, "Booth", Vector3.new(10, 8, 6), CFrame.new(bc + Vector3.new(0, 4, 0)), pick(rng, SHOP))
		wedge(
			f,
			"BoothAwning",
			Vector3.new(11, 2, 3),
			facing(bc + Vector3.new(0, 9, -4.2), Vector3.new(0, 0, -1)),
			if i % 2 == 0 then C.white else C.red,
			false
		)
	end
	sign(
		f,
		"PierSign",
		"PIER",
		Vector3.new(18, 5, 1),
		facing(Vector3.new(o.X - 30, o.Y + 14, o.Z - 40), Vector3.new(0, 0, -1)),
		rgb(30, 32, 56),
		C.cyan,
		{
			glow = C.pink,
			back = true,
		}
	)
	for _, x in { -36, -24 } do
		part(f, "SignPost", Vector3.new(0.8, 11.5, 0.8), L(o, x, 5.75, -40), C.wood)
	end

	-- the pier itself: from the promenade north over the beach and out over the water
	local deckTop = SAND_TOP + 1.3
	local x = o.X
	local outward = if o.Z < 0 then -1 else 1
	local z0 = outward * PROMENADE_OUT
	local zEnd = outward * (MapConfig.BOUNDARY - 10)
	local endLen = 24
	local mainLen = math.abs(zEnd - z0) - endLen
	local wood = rgb(186, 134, 88)
	local deckOpts: PartOpts = { material = Enum.Material.WoodPlanks }
	part(
		f,
		"PierDeck",
		Vector3.new(18, 1, mainLen),
		CFrame.new(x, deckTop - 0.5, z0 + outward * mainLen / 2),
		wood,
		deckOpts
	)
	part(
		f,
		"PierEnd",
		Vector3.new(34, 1, endLen),
		CFrame.new(x, deckTop - 0.5, zEnd - outward * endLen / 2),
		wood,
		deckOpts
	)
	local rampCenter = Vector3.new(x, CURB_TOP + (deckTop - CURB_TOP) / 2, z0 - outward * 3)
	wedge(
		f,
		"PierRamp",
		Vector3.new(18, deckTop - CURB_TOP, 6),
		CFrame.lookAt(rampCenter, rampCenter - Vector3.new(0, 0, outward)),
		wood
	)
	for _, sx in { -1, 1 } do
		part(
			f,
			"PierRail",
			Vector3.new(0.5, 3, mainLen),
			CFrame.new(x + sx * 8.75, deckTop + 1.5, z0 + outward * mainLen / 2),
			C.white
		)
		part(
			f,
			"PierRail",
			Vector3.new(0.5, 3, endLen),
			CFrame.new(x + sx * 16.75, deckTop + 1.5, zEnd - outward * endLen / 2),
			C.white
		)
	end
	local postBottom = SEABED_Y - 2
	local postH = deckTop - 1 - postBottom
	for k = 1, 6 do
		local z = z0 + outward * k * (mainLen / 6.5)
		for _, sx in { -1, 1 } do
			part(
				f,
				"PierPost",
				Vector3.new(1.4, postH, 1.4),
				CFrame.new(x + sx * 7.6, postBottom + postH / 2, z),
				rgb(120, 84, 56)
			)
		end
	end
	-- bait shop + lamps at the end
	local hutC = Vector3.new(x + 10, deckTop, zEnd - outward * 8)
	part(f, "BaitShop", Vector3.new(10, 8, 8), CFrame.new(hutC + Vector3.new(0, 4, 0)), C.cyan)
	wedge(
		f,
		"BaitShopRoof",
		Vector3.new(11, 3, 9),
		CFrame.new(hutC + Vector3.new(0, 9.5, 0)) * CFrame.Angles(0, math.pi / 2, 0),
		C.red
	)
	for k = 1, 3 do
		local lz = z0 + outward * k * (mainLen / 3.2)
		local g = Vector3.new(x - 8.2, deckTop, lz)
		ctx.lightIndex += 1
		part(f, "PierLampPole", Vector3.new(0.5, 9, 0.5), CFrame.new(g + Vector3.new(0, 4.5, 0)), C.pole)
		local head =
			ball(f, "PierLamp", 1.6, g + Vector3.new(0, 9.4, 0), C.lampDay, { collide = false, shadow = false })
		nightGlow(head, C.lampNight)
		tag(head, MapBuilder.TAG_STREET_LIGHT)
		if k ~= 2 then
			local pl = Instance.new("PointLight")
			pl.Range = 30
			pl.Brightness = 1.4
			pl.Color = rgb(255, 210, 150)
			pl.Shadows = false
			pl.Enabled = false
			pl.Parent = head
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- Beach + boundary
---------------------------------------------------------------------------------------------------------------

local function buildBeach(ctx: Ctx)
	local f = ctx.beach
	local rng = Random.new(MapBuilder.SEED + 61)
	local pw = PROMENADE_OUT - EXT
	local pHgt = CURB_TOP - GROUND_BOTTOM
	local pY = (CURB_TOP + GROUND_BOTTOM) / 2
	-- promenade ring (N/S span the corners)
	for _, sz in { -1, 1 } do
		part(
			f,
			"Promenade",
			Vector3.new(PROMENADE_OUT * 2, pHgt, pw),
			CFrame.new(0, pY, sz * (EXT + pw / 2)),
			C.promenade,
			{ shadow = false }
		)
	end
	for _, sx in { -1, 1 } do
		part(
			f,
			"Promenade",
			Vector3.new(pw, pHgt, EXT * 2),
			CFrame.new(sx * (EXT + pw / 2), pY, 0),
			C.promenade,
			{ shadow = false }
		)
	end
	-- flat sand ring
	local sandBottom = SEABED_Y
	local sHgt = SAND_TOP - sandBottom
	local sY = (SAND_TOP + sandBottom) / 2
	local sw = SLOPE_START - PROMENADE_OUT
	local sandOpts: PartOpts = { material = Enum.Material.Sand, shadow = false }
	for _, sz in { -1, 1 } do
		part(
			f,
			"Sand",
			Vector3.new(SLOPE_START * 2, sHgt, sw),
			CFrame.new(0, sY, sz * (PROMENADE_OUT + sw / 2)),
			C.sand,
			sandOpts
		)
	end
	for _, sx in { -1, 1 } do
		part(
			f,
			"Sand",
			Vector3.new(sw, sHgt, PROMENADE_OUT * 2),
			CFrame.new(sx * (PROMENADE_OUT + sw / 2), sY, 0),
			C.sand,
			sandOpts
		)
	end
	-- slopes into the water
	local slopeLen = SLOPE_END - SLOPE_START
	local slopeH = SAND_TOP - sandBottom
	for _, s in { -1, 1 } do
		local cz = s * (SLOPE_START + slopeLen / 2)
		local pz = Vector3.new(0, sandBottom + slopeH / 2, cz)
		wedge(
			f,
			"SandSlope",
			Vector3.new(SLOPE_START * 2, slopeH, slopeLen),
			CFrame.lookAt(pz, pz + Vector3.new(0, 0, s)),
			C.sandDeep
		).Material =
			Enum.Material.Sand
		local px = Vector3.new(s * (SLOPE_START + slopeLen / 2), sandBottom + slopeH / 2, 0)
		wedge(
			f,
			"SandSlope",
			Vector3.new(SLOPE_START * 2, slopeH, slopeLen),
			CFrame.lookAt(px, px + Vector3.new(s, 0, 0)),
			C.sandDeep
		).Material =
			Enum.Material.Sand
	end
	-- rounded dunes covering the four corners (a big sphere whose top is flush with the sand at the corner)
	local R = 133
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local c = Vector3.new(sx * SLOPE_START, SAND_TOP - R, sz * SLOPE_START)
			local dune = ball(f, "CornerDune", R * 2, c, C.sandDeep, { material = Enum.Material.Sand, shadow = false })
			dune.CastShadow = false
		end
	end

	-- palms along the beach, umbrellas, towels, lifeguard towers
	local pierBlock = MapConfig.Blocks.Pier
	local pierX = (pierBlock.x + 0.5) * S
	local pierSideZ = if pierBlock.z < 0 then -1 else 1
	local palmD = PROMENADE_OUT + 10
	local step = 140
	local count = math.floor((EXT * 2 - 80) / step)
	local startA = -(count * step) / 2
	for k = 0, count do
		local a = startA + k * step
		for _, sideV in { Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0) } do
			local along = if sideV.X == 0 then Vector3.new(a, 0, 0) else Vector3.new(0, 0, a)
			local p = sideV * palmD + along
			local nearPier = sideV.Z == pierSideZ and math.abs(p.X - pierX) < 26
			if not nearPier then
				palm(ctx.props, Vector3.new(p.X, SAND_TOP, p.Z), rand(rng, 16, 24), rng)
			end
		end
	end
	local umbrellaColors = { C.pink, C.cyan, C.yellow, C.orange, C.lime, C.purple }
	for k = 0, 11 do
		local sideIdx = k % 4
		local sideV = ({ Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0) })[sideIdx + 1]
		local a = -600 + math.floor(k / 4) * 520 + rand(rng, -60, 60) + (if sideIdx % 2 == 0 then 70 else -50)
		local along = if sideV.X == 0 then Vector3.new(a, 0, 0) else Vector3.new(0, 0, a)
		local p = sideV * (PROMENADE_OUT + 32) + along
		if not (sideV.Z == pierSideZ and math.abs(p.X - pierX) < 30) then
			local g = Vector3.new(p.X, SAND_TOP, p.Z)
			local col = umbrellaColors[k % #umbrellaColors + 1]
			deco(f, "UmbrellaPole", Vector3.new(0.4, 8, 0.4), CFrame.new(g + Vector3.new(0, 4, 0)), C.white)
			cyl(
				f,
				"Umbrella",
				0.8,
				9,
				CFrame.new(g + Vector3.new(0, 8, 0)) * CFrame.Angles(rand(rng, -0.15, 0.15), 0, rand(rng, -0.15, 0.15)),
				col,
				{
					collide = false,
				}
			)
			deco(
				f,
				"Towel",
				Vector3.new(3, 0.1, 6),
				CFrame.new(g + Vector3.new(3.5, 0.05, 1)) * CFrame.Angles(0, rand(rng, -0.4, 0.4), 0),
				pick(rng, umbrellaColors)
			)
		end
	end
	for i, sideV in { Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0), Vector3.new(0, 0, -1) } do
		local a = if i % 2 == 0 then 240 else -260
		local along = if sideV.X == 0 then Vector3.new(a, 0, 0) else Vector3.new(0, 0, a)
		local g = sideV * (PROMENADE_OUT + 40) + along
		local base = Vector3.new(g.X, SAND_TOP, g.Z)
		part(f, "LifeguardStand", Vector3.new(4, 7, 4), CFrame.new(base + Vector3.new(0, 3.5, 0)), C.white)
		part(f, "LifeguardCabin", Vector3.new(6.5, 4.5, 6.5), CFrame.new(base + Vector3.new(0, 9.25, 0)), C.red)
		part(f, "LifeguardRoof", Vector3.new(7.6, 0.6, 7.6), CFrame.new(base + Vector3.new(0, 11.8, 0)), C.white)
	end
end

local function buildBoundary(ctx: Ctx)
	local B = MapConfig.BOUNDARY
	local T = 4
	local H = 460
	local y = -60 + H / 2
	local opts: PartOpts = { transparency = 1, shadow = false }
	for _, s in { -1, 1 } do
		part(
			ctx.boundary,
			"BoundaryWall",
			Vector3.new(B * 2 + T * 2, H, T),
			CFrame.new(0, y, s * (B + T / 2)),
			C.dark,
			opts
		)
		part(
			ctx.boundary,
			"BoundaryWall",
			Vector3.new(T, H, B * 2 + T * 2),
			CFrame.new(s * (B + T / 2), y, 0),
			C.dark,
			opts
		)
	end
end

---------------------------------------------------------------------------------------------------------------
-- Blocks dispatcher
---------------------------------------------------------------------------------------------------------------

-- "Hotwire Tower": the tallest building in the city, visible from everywhere (navigation + skyline icon).
local function buildLandmark(ctx: Ctx, o: Vector3)
	local f = folder("HotwireTower", ctx.pois)
	local origin = CFrame.lookAt(o, o + Vector3.new(-1, 0, 0)) -- front faces west (toward the spawn plaza)
	local m = newBuilding(f, "Landmark", origin, 56, 56, 300)
	local glass = rgb(46, 40, 110)
	local glassOpts: PartOpts = { material = Enum.Material.Glass, reflectance = 0.1 }
	-- podium + plaza
	part(m, "Podium", Vector3.new(84, 12, 84), origin * CFrame.new(0, 6, 0), rgb(36, 38, 60))
	local lobby = band(m, "Lobby", origin, 84, 84, 5, 7, 0.4, C.windowDay, Enum.Material.Glass)
	nightGlow(lobby, C.windowNight)
	neon(m, "PodiumTrim", Vector3.new(84.8, 0.8, 84.8), origin * CFrame.new(0, 11.6, 0), C.cyan)
	local tiers = { { 56, 12, 140 }, { 44, 140, 210 }, { 30, 210, 252 } }
	for i, t in tiers do
		local w, y0, y1 = t[1], t[2], t[3]
		part(m, "Shaft", Vector3.new(w, y1 - y0, w), origin * CFrame.new(0, (y0 + y1) / 2, 0), glass, glassOpts)
		local y = y0 + 16
		while y < y1 - 6 do
			local b = band(m, "FloorBand", origin, w, w, y, 1.2, 0.5, rgb(90, 80, 170))
			nightGlow(b, if i % 2 == 1 then C.pink else C.cyan)
			y += 16
		end
		neon(
			m,
			"Crown",
			Vector3.new(w + 1, 1.6, w + 1),
			origin * CFrame.new(0, y1 - 0.8, 0),
			if i % 2 == 1 then C.pink else C.cyan
		)
		-- corner fins (always neon): the tower's signature look
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				neon(
					m,
					"Fin",
					Vector3.new(1, y1 - y0 - 6, 1),
					origin * CFrame.new(sx * (w / 2 + 0.2), (y0 + y1) / 2, sz * (w / 2 + 0.2)),
					C.pink
				)
			end
		end
	end
	part(m, "SpireBase", Vector3.new(10, 8, 10), origin * CFrame.new(0, 256, 0), C.dark)
	part(m, "Spire", Vector3.new(2.4, 50, 2.4), origin * CFrame.new(0, 285, 0), C.white)
	ball(m, "SpireTip", 4, (origin * CFrame.new(0, 311, 0)).Position, C.red, {
		material = Enum.Material.Neon,
		collide = false,
		shadow = false,
	})
	-- giant billboards on the first setback (front = west toward the spawn, back = east)
	for _, dir in { -1, 1 } do
		sign(
			m,
			"TowerSign",
			"HOTWIRE CITY",
			Vector3.new(44, 11, 1.4),
			origin * CFrame.new(0, 148, dir * 23.5) * CFrame.Angles(0, if dir < 0 then 0 else math.pi, 0),
			rgb(20, 18, 50),
			C.yellow,
			{
				glow = C.pink,
				maxDistance = 2000,
			}
		)
	end
	-- plaza dressing
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			palm(ctx.props, Vector3.new(o.X + sx * 46, o.Y, o.Z + sz * 46), 20, Random.new(sx * 3 + sz * 7 + 100))
		end
	end
end

local function buildBlocks(ctx: Ctx)
	for bx = MapConfig.BLOCK_MIN, MapConfig.BLOCK_MAX do
		for bz = MapConfig.BLOCK_MIN, MapConfig.BLOCK_MAX do
			local key = blockKey(bx, bz)
			local origin = MapLayout.blockCenter(bx, bz)
			local district = MapBuilder.districtOf(bx, bz)
			local cuts = cutsFor(bx, bz)
			buildBlockBase(ctx, bx, bz, origin, district, cuts)
			local rng = Random.new(MapBuilder.SEED + (bx + 20) * 97 + (bz + 20) * 1013)
			local poi = poiByBlock[key]
			if plotByBlock[key] then
				continue -- flat empty lot: PlotService builds the garage here
			elseif not poi and bx == MapBuilder.LANDMARK_BLOCK.x and bz == MapBuilder.LANDMARK_BLOCK.z then
				buildLandmark(ctx, origin)
			elseif poi then
				local f = folder(poi, ctx.pois)
				if poi == "SpawnPlaza" then
					buildSpawnPlaza(ctx, f, origin)
				elseif poi == "Dealership" then
					buildDealership(ctx, f, origin)
				elseif poi == "PoliceHQ" then
					buildPoliceHQ(ctx, f, origin)
				elseif poi == "GearShop" then
					buildGearShop(ctx, f, origin)
				elseif poi == "SprayShopA" or poi == "SprayShopB" then
					local zones = MapLayout.sprayZones()
					local zone = if poi == "SprayShopA" then zones[1] else zones[2]
					local col = if poi == "SprayShopA" then rgb(60, 200, 210) else rgb(150, 100, 240)
					buildSprayShop(
						ctx,
						f,
						origin,
						zone.cframe,
						zone.size,
						col,
						if poi == "SprayShopA" then C.pink else C.yellow,
						rng
					)
				elseif poi == "ChopShop" then
					local zcf, zsize = MapLayout.chopZone()
					buildChopShop(ctx, f, origin, zcf, zsize)
				elseif poi == "StuntPark" then
					buildStuntPark(ctx, f, origin)
				elseif poi == "Park" then
					buildPark(ctx, f, origin)
				elseif poi == "Pier" then
					buildPier(ctx, f, origin)
				else
					fillArea(
						ctx,
						rng,
						district,
						origin,
						{ x0 = -BUILD_HALF, x1 = BUILD_HALF, z0 = -BUILD_HALF, z1 = BUILD_HALF }
					)
				end
			else
				fillArea(
					ctx,
					rng,
					district,
					origin,
					{ x0 = -BUILD_HALF, x1 = BUILD_HALF, z0 = -BUILD_HALF, z1 = BUILD_HALF }
				)
			end
		end
	end
end

---------------------------------------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------------------------------------

local mapFolder: Folder? = nil

-- Builds and returns the "Map" folder under parent (replacing an existing one). Harness-compatible.
function MapBuilder.build(parent: Instance): Folder
	local existing = parent:FindFirstChild("Map")
	if existing then
		existing:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = "Map"
	local ctx: Ctx = {
		root = root,
		ground = folder("Ground", root),
		roads = folder("Roads", root),
		markings = nil :: any,
		blocks = folder("Blocks", root),
		buildings = folder("Buildings", root),
		pois = folder("POIs", root),
		props = folder("Props", root),
		beach = folder("Beach", root),
		boundary = folder("Boundary", root),
		lightIndex = 0,
	}
	ctx.markings = folder("Markings", ctx.roads)
	buildGround(ctx)
	buildRoads(ctx)
	buildBlocks(ctx)
	buildBeach(ctx)
	buildBoundary(ctx)
	root.Parent = parent
	mapFolder = root
	return root
end

-- Ocean water + seabed around the island (live engine only; FillBlock in tiles to keep each call small).
function MapBuilder.buildTerrain(terrain: Terrain)
	local inner = SLOPE_START
	local outer = MapConfig.WATER_EXTENT
	local waterTop = MapConfig.WATER_LEVEL
	-- terrain voxels are 4 studs: keep the water/sand boundary on the voxel grid so no voxel is split
	local waterBottom = math.floor((SEABED_Y + 2) / 4) * 4
	local bedBottom = waterBottom - 16
	local rects = {
		{ -outer, outer, -outer, -inner },
		{ -outer, outer, inner, outer },
		{ -outer, -inner, -inner, inner },
		{ inner, outer, -inner, inner },
	}
	local TILE = 512
	for _, r in rects do
		local x0, x1, z0, z1 = r[1], r[2], r[3], r[4]
		local x = x0
		while x < x1 do
			local xs = math.min(TILE, x1 - x)
			local z = z0
			while z < z1 do
				local zs = math.min(TILE, z1 - z)
				local cx, cz = x + xs / 2, z + zs / 2
				terrain:FillBlock(
					CFrame.new(cx, (waterTop + waterBottom) / 2, cz),
					Vector3.new(xs, waterTop - waterBottom, zs),
					Enum.Material.Water
				)
				terrain:FillBlock(
					CFrame.new(cx, (waterBottom + bedBottom) / 2, cz),
					Vector3.new(xs, waterBottom - bedBottom, zs),
					Enum.Material.Sand
				)
				z += zs
			end
			x += xs
		end
	end
	terrain.WaterColor = rgb(24, 186, 214)
	terrain.WaterTransparency = 0.35
	terrain.WaterReflectance = 0.6
	terrain.WaterWaveSize = 0.12
	terrain.WaterWaveSpeed = 9
end

function MapBuilder.getMapFolder(): Folder
	if mapFolder and mapFolder.Parent then
		return mapFolder
	end
	local found = Workspace:FindFirstChild("Map")
	if found and found:IsA("Folder") then
		mapFolder = found
		return found
	end
	return MapBuilder.build(Workspace)
end

function MapBuilder.init()
	MapBuilder.build(Workspace)
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		local ok, err = pcall(MapBuilder.buildTerrain, terrain)
		if not ok then
			warn("[MapBuilder] terrain fill failed: " .. tostring(err))
		end
	end
end

return MapBuilder
