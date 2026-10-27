--!strict
-- MapBuilder: builds the static island city into Workspace.Map (SPEC §3 + §6, art pass AP2 in docs/ART_PASS.md).
--
-- Every coordinate comes from Config/Map + Util/MapLayout so all systems agree on where things are.
--
--   Map/Ground     base slab under the island (safety net)
--   Map/Roads      asphalt parts (tag "Road") + Markings (center dashes, edge lines, crosswalks: non-collide,
--                  non-query so suspension rays ride on the asphalt)
--   Map/Blocks     raised blocks (CURB_TOP): 4 sidewalk strips + a lot interior per block, curb-cut driveway ramps,
--                  procedural lot dressing (parking lots, pools, hedges, paving). Lot parts carry attributes BlockX,
--                  BlockZ, District, Zone, Poi ("" if none), PlotIndex (0 if none).
--   Map/Buildings  one building slot Model per lot building (see "Asset slots" below)
--   Map/POIs       SpawnPlaza, Dealership, PoliceHQ, GearShop, SprayShopA/B, ChopShop, StuntPark, Park, Pier,
--                  HotwireTower (POI-specific slots live in their POI folder)
--   Map/Props      prop slots (lamps, trees, street furniture, beach + dock props) and the parts that must outlive
--                  a placeholder: lamp bulbs (tag "StreetLight" + PointLight), billboard boards (tag "Billboard"),
--                  pylon signs, neon accents
--   Map/Beach      promenade, sand, slopes, corner dunes
--   Map/Boundary   invisible collidable walls at ±BOUNDARY
--
-- Districts ("Zone" lot attribute): neon Downtown core (skyscrapers + office blocks), Midtown (apartments, lofts,
-- offices, corner stores), Shops (diner / pizza / donut / gas / convenience on the ring around Midtown), Suburbs
-- (west), Beachfront (east + south outer blocks), Docks (north outer blocks, beside the Chop Shop and the Pier).
--
-- Asset slots (art pass contract, consumed by Server/Systems/MapDresser):
--   Models tagged "AssetSlot" with attributes Category ("Buildings" | "Props"), Role (a Config/Assets key, or a
--   variant group such as "palm_tree" / "tree"), Fit (studs along the AssetDef's fit dimension), optional Yaw
--   (degrees about +Y). The slot pivot (WorldPivot) is the asset's ground CFrame: bottom-center, front = LookVector.
--   The slot's children are the procedural placeholder (the fallback look) and are sized to the kit asset's
--   normalized bounds (KIT_DIMS), so clearance checks against placeholders hold for the dressed city too.
--   Anything that must survive dressing (lamp lights, billboard boards, signs, functional POI parts) is NOT inside a
--   slot.
--
-- Night contract (LightingService): parts tagged "NightGlow" carry DayColor/DayMaterial + NightColor/NightMaterial
-- attributes (window bands light up, lamp bulbs and neon accents turn Neon).
--
-- build(parent) is pure instance construction (harness-compatible, SPEC §10). init() = build(Workspace) + Terrain
-- water/seabed, grass beds and clouds (buildTerrain; recorded as no-ops in the harness).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Assets = require(Shared.Config.Assets)
local MapConfig = require(Shared.Config.Map)
local MapLayout = require(Shared.Util.MapLayout)

local MapBuilder = {}

MapBuilder.SEED = 7331
MapBuilder.PART_BUDGET = 9000
MapBuilder.BUILDING_SLOT_BUDGET = 110
MapBuilder.PROP_SLOT_BUDGET = 320
MapBuilder.TAG_ROAD = "Road"
MapBuilder.TAG_STREET_LIGHT = "StreetLight"
MapBuilder.TAG_NIGHT_GLOW = "NightGlow"
MapBuilder.TAG_SLOT = "AssetSlot"
MapBuilder.TAG_BILLBOARD = "Billboard"
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
local LAMP_FIT = 18 -- street lamp height (studs)
local SIGNAL_FIT = 22 -- traffic light height: its mast arm clears car height over the lane

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

-- Image board (SurfaceGui + ImageLabel on one face), e.g. the plaza logo sign.
local function addImage(board: BasePart, face: Enum.NormalId, image: string, maxDistance: number)
	local sg = Instance.new("SurfaceGui")
	sg.Name = "ImageGui_" .. face.Name
	sg.Face = face
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 24
	sg.LightInfluence = 0
	sg.Brightness = 1.4
	sg.MaxDistance = maxDistance
	sg.ResetOnSpawn = false
	local img = Instance.new("ImageLabel")
	img.Name = "Image"
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.Image = image
	img.ScaleType = Enum.ScaleType.Fit
	img.Parent = sg
	sg.Parent = board
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
	adIndex: number,
}

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

-- Art-pass district: "downtown" | "midtown" | "shops" | "suburbs" | "beachfront" | "docks".
-- Shops ring the Midtown blocks; the west edge is Suburbs (next to the Park); the outer north edge is the Docks
-- (between the Chop Shop and the Pier); the outer east + south edges face the beach.
function MapBuilder.zoneOf(bx: number, bz: number): string
	local d = MapBuilder.districtOf(bx, bz)
	if d == "downtown" then
		return "downtown"
	elseif d == "midrise" then
		return "midtown"
	elseif d == "lowrise" then
		return if bx == MapConfig.BLOCK_MIN + 1 then "suburbs" else "shops"
	elseif bz == MapConfig.BLOCK_MIN then
		return "docks"
	elseif bx == MapConfig.BLOCK_MIN then
		return "suburbs"
	end
	return "beachfront"
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
-- Kit bounds + asset slots
---------------------------------------------------------------------------------------------------------------

-- Normalized kit bounds at each AssetDef's default size: X = width, Y = height, Z = depth (front at -Z).
-- Generated from the owned GLBs by `python3 tools/kitgeo.py luau` (same normalization as AssetLibrary._normalize);
-- regenerate when Config/Assets changes. Store assets without a local mesh use rough bounds.
local KIT_DIMS: { [string]: Vector3 } = {
	apartment_balcony = Vector3.new(37.6, 70.0, 28.7),
	beach_villa = Vector3.new(40.7, 30.0, 39.8),
	brick_loft = Vector3.new(28.9, 60.0, 24.9),
	car_showroom = Vector3.new(100.0, 40.6, 70.8),
	chop_shop = Vector3.new(59.8, 55.7, 60.0),
	convenience_store = Vector3.new(32.1, 22.0, 30.7),
	diner = Vector3.new(35.9, 22.0, 30.4),
	donut_shop = Vector3.new(23.1, 28.0, 13.4),
	gas_station = Vector3.new(57.4, 38.9, 60.0),
	gear_shop = Vector3.new(29.2, 28.0, 28.8),
	hotel_beach = Vector3.new(42.5, 60.0, 30.9),
	lighthouse = Vector3.new(37.5, 70.0, 27.1),
	office_block = Vector3.new(48.5, 80.0, 39.2),
	pizza_shop = Vector3.new(32.2, 24.0, 24.1),
	police_hq = Vector3.new(41.4, 45.0, 30.1),
	skyscraper_deco = Vector3.new(77.2, 220.0, 65.2),
	skyscraper_neon = Vector3.new(46.1, 200.0, 46.0),
	skyscraper_twist = Vector3.new(94.8, 240.0, 94.7),
	spray_booth = Vector3.new(25.3, 22.0, 23.0),
	suburban_house = Vector3.new(19.2, 26.0, 19.7),
	surf_shack = Vector3.new(14.9, 18.0, 17.5),
	warehouse = Vector3.new(56.6, 35.0, 46.6),
	beach_chair = Vector3.new(5.2, 5.6, 6.0),
	beach_umbrella = Vector3.new(10.4, 10.0, 9.6),
	bench = Vector3.new(8.0, 5.3, 4.4),
	billboard = Vector3.new(40.0, 40.0, 15.4),
	bus_stop = Vector3.new(16.0, 13.8, 8.2),
	bush = Vector3.new(5.0, 3.5, 5.0),
	car_crusher = Vector3.new(18.0, 18.0, 10.5),
	crate_stack = Vector3.new(6.9, 7.0, 6.8),
	dumpster = Vector3.new(9.0, 6.8, 4.7),
	ferris_wheel = Vector3.new(74.9, 90.0, 27.4),
	fire_hydrant = Vector3.new(2.7, 3.5, 2.7),
	flower_bed = Vector3.new(10.0, 4.0, 10.0), -- store asset (approximate)
	fountain = Vector3.new(30.0, 22.0, 30.0),
	hotdog_stand = Vector3.new(11.7, 10.0, 12.5),
	lifeguard_tower = Vector3.new(12.1, 18.0, 20.0),
	mailbox = Vector3.new(2.7, 4.0, 2.6),
	newspaper_box = Vector3.new(2.5, 4.0, 1.8),
	oil_barrels = Vector3.new(5.0, 3.9, 3.8),
	palm_tree_a = Vector3.new(20.8, 34.0, 22.2),
	palm_tree_b = Vector3.new(17.9, 30.0, 18.5),
	pine_tree = Vector3.new(17.8, 26.0, 17.7),
	road_barrier = Vector3.new(8.0, 4.9, 3.5),
	rock = Vector3.new(6.0, 4.3, 5.6),
	round_tree = Vector3.new(21.7, 24.0, 18.0),
	shipping_container = Vector3.new(8.7, 9.9, 20.0),
	street_lamp = Vector3.new(5.6, 18.0, 9.5),
	surfboard_rack = Vector3.new(9.0, 8.3, 4.2),
	traffic_cone = Vector3.new(2.2, 2.5, 2.4),
	traffic_light = Vector3.new(6.8, 20.0, 13.4),
	trash_can = Vector3.new(3.0, 4.5, 3.0),
	water_tower = Vector3.new(29.7, 60.0, 29.8),
}
MapBuilder.KIT_DIMS = KIT_DIMS

-- Variant groups (MapDresser picks the concrete key by position hash). Placement uses the reference key's bounds;
-- every variant of a group shares the reference's fit dimension.
local VARIANT_REF: { [string]: string } = {
	palm_tree = "palm_tree_a",
	tree = "round_tree",
}
MapBuilder.VARIANT_REF = VARIANT_REF

-- Overhanging props: clearance boxes as fractions of the kit bounds {cx, cz, sx, sz, y0, y1} (center / size as a
-- fraction of W and D; y range as a fraction of H). Lamp + signal arms reach over the road above car height; tree
-- canopies and billboard panels overhang sidewalks.
local OVERHANG: { [string]: { { number } } } = {
	street_lamp = { { 0, 0.226, 1, 0.54, 0, 0.7 }, { 0, 0, 1, 1, 0.7, 1 } },
	traffic_light = { { 0, 0.235, 1, 0.53, 0, 0.4 }, { 0, 0, 1, 1, 0.4, 1 } },
	billboard = { { 0, -0.055, 0.27, 0.64, 0, 0.5 }, { 0, 0, 1, 1, 0.5, 1 } },
	palm_tree = { { 0, 0, 0.6, 0.6, 0, 0.25 }, { 0, 0, 1, 1, 0.25, 1 } },
	tree = { { 0, 0, 0.6, 0.6, 0, 0.25 }, { 0, 0, 1, 1, 0.25, 1 } },
	beach_umbrella = { { 0, 0, 0.2, 0.2, 0, 0.7 }, { 0, 0, 1, 1, 0.7, 1 } },
}

local function kitDef(category: string, key: string): Assets.AssetDef?
	local cat = (Assets :: any)[category]
	if type(cat) == "table" then
		return cat[key]
	end
	return nil
end

-- Kit bounds (W, H, D studs) of `role` dressed at `fit` (studs along its AssetDef's fit dimension).
function MapBuilder.kitSize(category: string, role: string, fit: number): Vector3
	local key = VARIANT_REF[role] or role
	local dims = KIT_DIMS[key] or Vector3.new(4, 4, 4)
	local def = kitDef(category, key)
	if not def or def.size <= 0 then
		return dims
	end
	return dims * (fit / def.size)
end

-- Fit value that dresses `role` at `scale` times its default size.
local function fitFor(category: string, role: string, scale: number): number
	local def = kitDef(category, VARIANT_REF[role] or role)
	return (if def then def.size else 1) * scale
end

-- World clearance boxes of a slot's dressed asset: { { cframe, size } }.
function MapBuilder.slotBoxes(slot: Instance): { { cframe: CFrame, size: Vector3 } }
	local category = slot:GetAttribute("Category")
	local role = slot:GetAttribute("Role")
	local fit = slot:GetAttribute("Fit")
	if type(category) ~= "string" or type(role) ~= "string" or type(fit) ~= "number" or not slot:IsA("Model") then
		return {}
	end
	local yaw = slot:GetAttribute("Yaw")
	local ground = (slot :: Model):GetPivot() * CFrame.Angles(0, math.rad(if type(yaw) == "number" then yaw else 0), 0)
	local size = MapBuilder.kitSize(category, role, fit)
	local prof = OVERHANG[role]
	if not prof then
		return { { cframe = ground * CFrame.new(0, size.Y / 2, 0), size = size } }
	end
	local out = {}
	for _, b in prof do
		local h = (b[6] - b[5]) * size.Y
		table.insert(out, {
			cframe = ground * CFrame.new(b[1] * size.X, (b[5] * size.Y) + h / 2, b[2] * size.Z),
			size = Vector3.new(b[3] * size.X, h, b[4] * size.Z),
		})
	end
	return out
end

-- A slot: Model tagged AssetSlot whose pivot is the dressed asset's ground CFrame (front = LookVector).
local function newSlot(
	parent: Instance,
	name: string,
	category: string,
	role: string,
	ground: CFrame,
	fit: number,
	yaw: number?
): Model
	local m = Instance.new("Model")
	m.Name = name
	tag(m, MapBuilder.TAG_SLOT)
	m:SetAttribute("Category", category)
	m:SetAttribute("Role", role)
	m:SetAttribute("Fit", math.floor(fit * 100 + 0.5) / 100)
	if yaw and yaw ~= 0 then
		m:SetAttribute("Yaw", yaw)
	end
	m.WorldPivot = ground
	m.Parent = parent
	return m
end

-- Ground CFrame at world XZ `pos` (y = curb top unless given) facing `dir`.
local function groundAt(pos: Vector3, dir: Vector3, y: number?): CFrame
	local p = Vector3.new(pos.X, y or CURB_TOP, pos.Z)
	return CFrame.lookAt(p, p + dir)
end

---------------------------------------------------------------------------------------------------------------
-- Props (each is an AssetSlot with a procedural placeholder sized to the kit asset)
---------------------------------------------------------------------------------------------------------------

-- Prop slot at `ground` (front = LookVector). Returns the slot and its dressed bounds (W, H, D).
local function propSlot(
	parent: Instance,
	name: string,
	role: string,
	ground: CFrame,
	fit: number,
	yaw: number?
): (Model, Vector3)
	local m = newSlot(parent, name, "Props", role, ground, fit, yaw)
	return m, MapBuilder.kitSize("Props", role, fit)
end

-- Random yaw in 15° steps (trees / rocks look different from every street).
local function randYaw(rng: Random): number
	return rng:NextInteger(0, 23) * 15
end

local function palm(parent: Instance, ground: Vector3, height: number, rng: Random): Model
	local m = propSlot(parent, "PalmTree", "palm_tree", CFrame.new(ground), height, randYaw(rng))
	local lean = CFrame.Angles(rand(rng, -0.1, 0.1), 0, rand(rng, -0.1, 0.1))
	local baseCf = CFrame.new(ground) * lean
	cyl(m, "Trunk", height, 1.5, baseCf * CFrame.new(0, height / 2, 0), C.trunk, { material = Enum.Material.Wood })
	local top = (baseCf * CFrame.new(0, height, 0)).Position
	local yaw0 = rand(rng, 0, math.pi * 2)
	for i = 0, 3 do
		local yaw = yaw0 + i * math.pi / 2 + rand(rng, -0.25, 0.25)
		local droop = rand(rng, 0.25, 0.5)
		local dir = Vector3.new(math.cos(yaw) * math.cos(droop), -math.sin(droop), math.sin(yaw) * math.cos(droop))
		local len = height * 0.4 + 2
		local center = top + dir * (len / 2 - 0.5)
		deco(
			m,
			"Frond",
			Vector3.new(2.8, 0.4, len),
			CFrame.lookAt(center, center + dir),
			if i % 2 == 0 then C.leafA else C.leafB
		)
	end
	return m
end

local function roundTree(parent: Instance, ground: Vector3, height: number, rng: Random): Model
	local m = propSlot(parent, "Tree", "tree", CFrame.new(ground), height, randYaw(rng))
	local trunkH = height * 0.4
	cyl(m, "Trunk", trunkH + 1, 1.6, CFrame.new(ground + Vector3.new(0, (trunkH + 1) / 2, 0)), C.trunk, {
		material = Enum.Material.Wood,
	})
	local d = height * 0.6
	local green = if rng:NextNumber() < 0.5 then C.leafA else C.leafB
	ball(m, "Canopy", d, ground + Vector3.new(0, height - d / 2 - 0.5, 0), green, { collide = false })
	return m
end

local function bench(parent: Instance, cf: CFrame, color: Color3?): Model
	-- cf at ground, LookVector = the way a sitter faces
	local m = propSlot(parent, "Bench", "bench", cf, 8)
	local col = color or C.wood
	part(m, "Seat", Vector3.new(6.6, 0.6, 2.2), cf * CFrame.new(0, 1.6, 0), col, { collide = false })
	part(m, "BenchBack", Vector3.new(6.6, 2.2, 0.5), cf * CFrame.new(0, 2.8, 1.1), col, { collide = false })
	deco(m, "BenchLegs", Vector3.new(5.6, 1.3, 1.6), cf * CFrame.new(0, 0.65, 0), C.metal)
	return m
end

local function hydrant(parent: Instance, pos: Vector3): Model
	local m = propSlot(parent, "Hydrant", "fire_hydrant", CFrame.new(pos), 3.5)
	cyl(m, "Hydrant", 2.4, 1.2, CFrame.new(pos + Vector3.new(0, 1.2, 0)), C.red, { collide = false })
	ball(m, "HydrantCap", 1.3, pos + Vector3.new(0, 2.5, 0), rgb(255, 200, 60), { collide = false })
	return m
end

local function trashCan(parent: Instance, cf: CFrame): Model
	local m = propSlot(parent, "TrashCan", "trash_can", cf, 4.5)
	cyl(m, "Can", 3.8, 2.6, cf * CFrame.new(0, 1.9, 0), rgb(46, 140, 70), { collide = false })
	cyl(m, "Lid", 0.6, 2.9, cf * CFrame.new(0, 4.1, 0), rgb(36, 110, 56), { collide = false })
	return m
end

local function newspaperBox(parent: Instance, cf: CFrame): Model
	local m = propSlot(parent, "NewspaperBox", "newspaper_box", cf, 4)
	deco(m, "Post", Vector3.new(0.5, 1.6, 0.5), cf * CFrame.new(0, 0.8, 0), C.metal)
	deco(m, "Box", Vector3.new(2.4, 2.4, 1.7), cf * CFrame.new(0, 2.8, 0), C.yellow)
	return m
end

local function mailbox(parent: Instance, cf: CFrame): Model
	local m = propSlot(parent, "Mailbox", "mailbox", cf, 4)
	deco(m, "Legs", Vector3.new(2, 0.9, 1.8), cf * CFrame.new(0, 0.45, 0), C.metal)
	deco(m, "Box", Vector3.new(2.6, 3.1, 2.4), cf * CFrame.new(0, 2.45, 0), C.police)
	return m
end

local function flowerBed(parent: Instance, cf: CFrame, size: number, color: Color3): Model
	local m = propSlot(parent, "FlowerBed", "flower_bed", cf, size)
	deco(m, "Planter", Vector3.new(size, 1.4, size * 0.5), cf * CFrame.new(0, 0.7, 0), C.wood)
	deco(m, "Flowers", Vector3.new(size - 1, 0.8, size * 0.5 - 1), cf * CFrame.new(0, 1.6, 0), color)
	return m
end

local function bush(parent: Instance, pos: Vector3, size: number, rng: Random): Model
	local m = propSlot(parent, "Bush", "bush", CFrame.new(pos), size, randYaw(rng))
	ball(m, "Bush", size, pos + Vector3.new(0, size * 0.32, 0), C.leafB, { collide = false })
	return m
end

local function rock(parent: Instance, pos: Vector3, size: number, rng: Random): Model
	local m = propSlot(parent, "Rock", "rock", CFrame.new(pos), size, randYaw(rng))
	ball(m, "Rock", size * 0.8, pos + Vector3.new(0, size * 0.2, 0), rgb(130, 132, 142), { collide = false })
	return m
end

local function hotdogStand(parent: Instance, cf: CFrame): Model
	local m = propSlot(parent, "HotdogStand", "hotdog_stand", cf, 10)
	deco(m, "Cart", Vector3.new(8, 3.6, 4.4), cf * CFrame.new(0, 2.6, 0), C.red)
	cyl(m, "Wheel", 0.6, 2.4, cf * CFrame.new(-2.5, 1.2, 0) * CFrame.Angles(0, math.pi / 2, 0), C.dark, {
		collide = false,
	})
	deco(m, "UmbrellaPole", Vector3.new(0.4, 5, 0.4), cf * CFrame.new(0, 6.5, 0), C.white)
	cyl(m, "Umbrella", 0.8, 11, cf * CFrame.new(0, 9.4, 0), C.yellow, { collide = false })
	return m
end

local function fountainProp(parent: Instance, cf: CFrame, fit: number): Model
	local m = propSlot(parent, "Fountain", "fountain", cf, fit)
	local k = fit / 30
	local stone = rgb(228, 222, 210)
	cyl(m, "FountainBasin", 2.4 * k, 28 * k, cf * CFrame.new(0, 1.2 * k, 0), stone)
	cyl(m, "FountainWater", 0.3, 25 * k, cf * CFrame.new(0, 2.4 * k, 0), C.water, {
		collide = false,
		transparency = 0.15,
		reflectance = 0.2,
		shadow = false,
	})
	cyl(m, "FountainPillar", 7 * k, 3.5 * k, cf * CFrame.new(0, 5.5 * k, 0), stone)
	cyl(m, "FountainBowl", 1 * k, 12 * k, cf * CFrame.new(0, 9 * k, 0), stone)
	cyl(
		m,
		"FountainJet",
		5 * k,
		1.6 * k,
		cf * CFrame.new(0, 12 * k, 0),
		rgb(160, 236, 255),
		{ material = Enum.Material.Neon, collide = false, shadow = false }
	)
	return m
end

local function waterTower(parent: Instance, cf: CFrame, fit: number): Model
	local m, size = propSlot(parent, "WaterTower", "water_tower", cf, fit)
	local w, h = size.X, size.Y
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			part(
				m,
				"Leg",
				Vector3.new(1.4, h * 0.62, 1.4),
				cf * CFrame.new(sx * w * 0.3, h * 0.31, sz * w * 0.3),
				C.red
			)
		end
	end
	cyl(m, "Tank", h * 0.3, w * 0.9, cf * CFrame.new(0, h * 0.77, 0), rgb(90, 170, 220))
	cyl(m, "TankRoof", h * 0.08, w * 0.6, cf * CFrame.new(0, h * 0.96, 0), rgb(70, 140, 190))
	return m
end

local function lifeguardTower(parent: Instance, cf: CFrame): Model
	local m = propSlot(parent, "LifeguardTower", "lifeguard_tower", cf, 18)
	part(m, "LifeguardStand", Vector3.new(4.5, 9, 4.5), cf * CFrame.new(0, 4.5, -2), C.white)
	part(m, "LifeguardCabin", Vector3.new(7.5, 5.5, 7.5), cf * CFrame.new(0, 11.75, -2), C.red)
	part(m, "LifeguardRoof", Vector3.new(9, 0.8, 9), cf * CFrame.new(0, 17.4, -2), C.white)
	wedge(
		m,
		"LifeguardRamp",
		Vector3.new(2.6, 9, 9),
		cf * CFrame.new(0, 4.5, 5.5) * CFrame.Angles(0, math.pi, 0),
		C.yellow
	)
	return m
end

local function beachUmbrella(parent: Instance, ground: Vector3, color: Color3, rng: Random): Model
	local m = propSlot(parent, "BeachUmbrella", "beach_umbrella", CFrame.new(ground), 10, randYaw(rng))
	deco(m, "UmbrellaPole", Vector3.new(0.4, 9, 0.4), CFrame.new(ground + Vector3.new(0, 4.5, 0)), C.white)
	cyl(
		m,
		"Umbrella",
		0.8,
		9.6,
		CFrame.new(ground + Vector3.new(0, 9, 0)) * CFrame.Angles(rand(rng, -0.12, 0.12), 0, rand(rng, -0.12, 0.12)),
		color,
		{ collide = false }
	)
	return m
end

local function beachChair(parent: Instance, cf: CFrame, color: Color3): Model
	local m = propSlot(parent, "BeachChair", "beach_chair", cf, 6)
	wedge(m, "Chair", Vector3.new(4.4, 3.6, 5.6), cf * CFrame.new(0, 1.8, 0), color, false)
	return m
end

local function surfboardRack(parent: Instance, cf: CFrame, rng: Random): Model
	local m = propSlot(parent, "SurfboardRack", "surfboard_rack", cf, 9)
	deco(m, "Rack", Vector3.new(9, 1, 1.6), cf * CFrame.new(0, 1.2, 0.8), C.wood)
	for i = 0, 3 do
		deco(
			m,
			"Board",
			Vector3.new(1.7, 7.6, 0.4),
			cf * CFrame.new(-3.3 + i * 2.2, 3.9, 0.2) * CFrame.Angles(math.rad(-10), 0, 0),
			pick(rng, NEON)
		)
	end
	return m
end

local function shippingContainer(parent: Instance, cf: CFrame, color: Color3, scale: number?): Model
	local k = scale or 1
	local m, size = propSlot(parent, "ShippingContainer", "shipping_container", cf, 20 * k)
	part(m, "Container", size, cf * CFrame.new(0, size.Y / 2, 0), color, { material = Enum.Material.CorrodedMetal })
	return m
end

local function crateStack(parent: Instance, cf: CFrame): Model
	local m = propSlot(parent, "CrateStack", "crate_stack", cf, 7)
	local wood = rgb(186, 130, 76)
	part(
		m,
		"Crate",
		Vector3.new(4, 3.5, 4),
		cf * CFrame.new(-1.3, 1.75, -1.2),
		wood,
		{ material = Enum.Material.WoodPlanks }
	)
	part(
		m,
		"Crate",
		Vector3.new(3, 3, 3),
		cf * CFrame.new(1.8, 1.5, 1.6),
		wood,
		{ material = Enum.Material.WoodPlanks }
	)
	part(m, "Crate", Vector3.new(3, 3, 3), cf * CFrame.new(-1, 5, -1), wood, { material = Enum.Material.WoodPlanks })
	return m
end

local function oilBarrels(parent: Instance, cf: CFrame): Model
	local m = propSlot(parent, "OilBarrels", "oil_barrels", cf, 5)
	for i, x in { -1.6, 0, 1.6 } do
		cyl(m, "Barrel", 3.6, 1.6, cf * CFrame.new(x, 1.8, 0), ({ C.police, C.red, C.yellow })[i], { collide = false })
	end
	return m
end

local function dumpster(parent: Instance, cf: CFrame): Model
	local m = propSlot(parent, "Dumpster", "dumpster", cf, 9)
	part(m, "Bin", Vector3.new(8.4, 5.4, 4.4), cf * CFrame.new(0, 2.9, 0), rgb(40, 140, 70), { collide = false })
	deco(m, "Lid", Vector3.new(8.6, 0.6, 4.6), cf * CFrame.new(0, 5.9, 0), C.dark)
	return m
end

local function carCrusher(parent: Instance, cf: CFrame): Model
	local m = propSlot(parent, "CarCrusher", "car_crusher", cf, 18)
	local y = rgb(255, 196, 40)
	for _, sx in { -1, 1 } do
		part(m, "Pillar", Vector3.new(2.5, 17, 2.5), cf * CFrame.new(sx * 7.5, 8.5, 0), y)
	end
	part(m, "Beam", Vector3.new(17.5, 2.5, 4), cf * CFrame.new(0, 16.5, 0), y)
	part(m, "Press", Vector3.new(12, 2, 8), cf * CFrame.new(0, 11, 0), C.metal)
	part(m, "Bed", Vector3.new(14, 1.4, 10), cf * CFrame.new(0, 0.7, 0), C.dark)
	return m
end

local function roadBarrier(parent: Instance, cf: CFrame): Model
	local m = propSlot(parent, "RoadBarrier", "road_barrier", cf, 8)
	for _, sx in { -3.2, 3.2 } do
		deco(m, "Leg", Vector3.new(0.6, 4.2, 3), cf * CFrame.new(sx, 2.1, 0), C.orange)
	end
	deco(m, "Bar", Vector3.new(8, 1.2, 0.4), cf * CFrame.new(0, 3.6, 0), C.white)
	return m
end

local function trafficCone(parent: Instance, cf: CFrame): Model
	local m = propSlot(parent, "TrafficCone", "traffic_cone", cf, 2.5)
	deco(m, "Base", Vector3.new(2.2, 0.2, 2.2), cf * CFrame.new(0, 0.1, 0), C.dark)
	cyl(m, "Cone", 2.3, 1.2, cf * CFrame.new(0, 1.35, 0), C.orange, { collide = false })
	return m
end

local function busStop(parent: Instance, cf: CFrame): Model
	-- cf at ground, LookVector toward the road (open side)
	local m = propSlot(parent, "BusStop", "bus_stop", cf, 16)
	local roof = rgb(40, 190, 200)
	part(m, "Roof", Vector3.new(16, 0.8, 8), cf * CFrame.new(0, 13.2, 0), roof, { collide = false })
	for _, sx in { -7.4, 7.4 } do
		for _, sz in { -3.4, 3.4 } do
			deco(m, "Post", Vector3.new(0.5, 12.8, 0.5), cf * CFrame.new(sx, 6.4, sz), C.metal)
		end
	end
	part(m, "BackPanel", Vector3.new(14.6, 8, 0.3), cf * CFrame.new(0, 5.6, 3.5), rgb(170, 230, 255), {
		material = Enum.Material.Glass,
		transparency = 0.5,
		collide = false,
	})
	deco(m, "BusBench", Vector3.new(12, 0.6, 2), cf * CFrame.new(0, 1.8, 2.2), C.wood)
	return m
end

-- Billboard prop: the slot holds the pole + frame; the ad board itself is tagged "Billboard" and lives outside the
-- slot (MapDresser puts a decal on it; it sits on the kit mesh's panel: 33 x 13 at y 26-39, z = +4.1 at fit 40).
local function adText(ctx: Ctx): string
	ctx.adIndex += 1
	return AD_TEXTS[(ctx.adIndex - 1) % #AD_TEXTS + 1]
end

local function billboardProp(ctx: Ctx, cf: CFrame, fit: number, back: boolean): Model
	local k = fit / 40
	local m = propSlot(ctx.props, "BillboardSign", "billboard", cf, fit)
	cyl(m, "Pole", 22 * k, 3 * k, cf * CFrame.new(0, 11 * k, 0), rgb(40, 90, 200))
	part(m, "Catwalk", Vector3.new(36 * k, 0.6, 4 * k), cf * CFrame.new(0, 24.5 * k, 2 * k), C.metal)
	part(m, "Frame", Vector3.new(36 * k, 15 * k, 1.2 * k), cf * CFrame.new(0, 32.4 * k, 4.9 * k), rgb(40, 90, 200))
	local ad = adText(ctx)
	local board = sign(
		ctx.props,
		"Billboard",
		ad,
		Vector3.new(30 * k, 15 * k, 1 * k),
		cf * CFrame.new(0, 32.35 * k, 4.1 * k),
		C.white,
		pick(Random.new(ctx.adIndex), SHOP),
		{ back = back, maxDistance = 700 }
	)
	tag(board, MapBuilder.TAG_BILLBOARD)
	board:SetAttribute("AdText", ad)
	board:SetAttribute("AdBack", back)
	return m
end

-- Street lamp: the pole stands on the sidewalk and the arm reaches out over the road (`outward` = the kit lamp's
-- front). The lit bulb is a separate part (tag "StreetLight" + PointLight + NightGlow) that survives dressing.
local function streetLight(ctx: Ctx, pole: Vector3, outward: Vector3)
	ctx.lightIndex += 1
	local k = LAMP_FIT / 18
	local ground = groundAt(pole + outward * (2.1 * k), outward)
	local m = propSlot(ctx.props, "StreetLamp", "street_lamp", ground, LAMP_FIT)
	local base = Vector3.new(pole.X, CURB_TOP, pole.Z)
	part(m, "LightPole", Vector3.new(0.7, 15, 0.7), CFrame.new(base + Vector3.new(0, 7.5, 0)), C.pole)
	local headPos = base + outward * (4.4 * k) + Vector3.new(0, 14.2 * k, 0)
	deco(m, "LampArm", Vector3.new(0.5, 0.5, 4.6 * k), CFrame.lookAt(headPos - outward * 2.2 * k, headPos), C.pole)
	deco(m, "LampHead", Vector3.new(2.6, 1, 3), CFrame.lookAt(headPos, headPos + outward), C.pole)
	-- the bulb peeks out under the kit lamp's globe (globe bottom ~13 studs up, 4.4 out from the pole)
	local bulb =
		ball(ctx.props, "LampBulb", 1.2, base + outward * (4.4 * k) + Vector3.new(0, 12.75 * k, 0), C.lampDay, {
			collide = false,
			shadow = false,
		})
	nightGlow(bulb, C.lampNight)
	tag(bulb, MapBuilder.TAG_STREET_LIGHT)
	-- PERF: short-range, shadowless; ~100 lamps city-wide (mobile budget, see ART_PASS.md)
	local light = Instance.new("PointLight")
	light.Name = "Light"
	light.Range = 34
	light.Brightness = 1.7
	light.Color = rgb(255, 210, 150)
	light.Shadows = false
	light.Enabled = false
	light.Parent = bulb
end

-- Traffic light on a sidewalk corner; its mast arm reaches over the road along `facing`.
local function trafficLight(ctx: Ctx, pole: Vector3, facingDir: Vector3)
	local k = SIGNAL_FIT / 20
	local ground = groundAt(pole + facingDir * (3.15 * k), facingDir)
	local m = propSlot(ctx.props, "TrafficLight", "traffic_light", ground, SIGNAL_FIT)
	local base = Vector3.new(pole.X, CURB_TOP, pole.Z)
	part(m, "SignalPole", Vector3.new(0.9, 19 * k, 0.9), CFrame.new(base + Vector3.new(0, 9.5 * k, 0)), C.dark)
	local armEnd = base + facingDir * (9.6 * k) + Vector3.new(0, 18 * k, 0)
	local armMid = base + facingDir * (4.8 * k) + Vector3.new(0, 18 * k, 0)
	deco(m, "SignalArm", Vector3.new(0.6, 0.6, 9.6 * k), CFrame.lookAt(armMid, armEnd), C.dark)
	local head = armEnd - facingDir * (1.4 * k) - Vector3.new(0, 4 * k, 0)
	deco(m, "SignalHead", Vector3.new(1.8, 5.4 * k, 1.8), CFrame.lookAt(head, head + facingDir), C.yellow)
	neon(
		m,
		"SignalGreen",
		Vector3.new(0.9, 0.9, 0.3),
		CFrame.lookAt(head, head + facingDir) * CFrame.new(0, -1.6, -0.95),
		C.lime
	)
end

---------------------------------------------------------------------------------------------------------------
-- Buildings (slot placeholders sized to the kit asset: w x h x d around origin, front = origin.LookVector)
---------------------------------------------------------------------------------------------------------------

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

-- Glass tower: podium, stepped shafts with glowing floor bands, neon crowns, spire up to exactly h.
local function towerBody(m: Model, rng: Random, origin: CFrame, w: number, d: number, h: number, style: string)
	local glass = pick(rng, TOWER_GLASS)
	local bandColor = pick(rng, TOWER_BAND)
	local accent = pick(rng, NEON)
	local podH = math.clamp(h * 0.05, 6, 10)
	part(m, "Podium", Vector3.new(w - 0.6, podH, d - 0.6), origin * CFrame.new(0, podH / 2, 0), rgb(70, 72, 92))
	local lobby =
		band(m, "Lobby", origin, w - 0.6, d - 0.6, podH * 0.42, podH * 0.55, 0.5, C.windowDay, Enum.Material.Glass)
	nightGlow(lobby, C.windowNight)
	local tiers: { { number } }
	if style == "twist" then
		tiers = { { 0.86, 0.46 }, { 0.72, 0.3 }, { 0.56, 0.24 } }
	elseif style == "deco" then
		tiers = { { 0.82, 0.42 }, { 0.62, 0.32 }, { 0.4, 0.26 } }
	else
		tiers = { { 0.9, 0.78 }, { 0.62, 0.22 } }
	end
	local shaftTotal = (h - podH) * 0.86
	local y = podH
	for ti, tier in tiers do
		local tw, td = w * tier[1], d * tier[1]
		local tierH = shaftTotal * tier[2]
		part(m, "Shaft", Vector3.new(tw, tierH, td), origin * CFrame.new(0, y + tierH / 2, 0), glass, {
			material = Enum.Material.Glass,
			reflectance = 0.08,
		})
		local spacing = math.max(13, tierH / 7)
		local by = spacing
		local count = 0
		while by < tierH - 4 and count < 8 do
			local b = band(m, "FloorBand", origin, tw, td, y + by, 1.1, 0.5, bandColor)
			nightGlow(b, accent)
			by += spacing
			count += 1
		end
		y += tierH
		neon(m, "Crown", Vector3.new(tw + 0.4, 1.2, td + 0.4), origin * CFrame.new(0, y - 0.6, 0), accent)
		if ti == 1 and rng:NextNumber() < 0.6 then
			for _, sx in { -1, 1 } do
				neon(
					m,
					"Fin",
					Vector3.new(0.6, tierH * 0.8, 0.6),
					origin * CFrame.new(sx * (tw / 2), podH + tierH * 0.45, -td / 2),
					accent
				)
			end
		end
	end
	local spireH = h - y
	if spireH > 1 then
		part(m, "Spire", Vector3.new(1.4, spireH, 1.4), origin * CFrame.new(0, y + spireH / 2, 0), C.white)
	end
end

type Look = { body: Color3, accent: Color3, material: Enum.Material?, windows: Color3 }

-- Mid-rise office / apartment / loft / hotel with ribbon windows and an entrance awning (front 3 studs).
local function midriseBody(m: Model, rng: Random, origin: CFrame, w: number, d: number, h: number, look: Look)
	local bw, bd = w - 0.8, d - 3.4
	local front = CFrame.new(0, 0, 1.5)
	local o = origin * front
	part(m, "Body", Vector3.new(bw, h - 1.4, bd), o * CFrame.new(0, (h - 1.4) / 2, 0), look.body, {
		material = look.material,
	})
	local store = band(m, "Storefront", o, bw, bd, 3.4, 5.4, 0.6, C.windowDay, Enum.Material.Glass)
	nightGlow(store, C.windowNight)
	local y = 10.5
	local step = math.max(8.5, (h - 12) / 7)
	local count = 0
	while y < h - 5 and count < 7 do
		local b = band(m, "Windows", o, bw, bd, y, 3.2, 0.6, look.windows, Enum.Material.Glass)
		if rng:NextNumber() < 0.75 then -- some floors stay dark at night (lived-in look)
			nightGlow(b, C.windowNight)
		end
		y += step
		count += 1
	end
	part(m, "Cap", Vector3.new(bw + 0.6, 1.4, bd + 0.6), o * CFrame.new(0, h - 0.7, 0), look.accent)
	wedge(
		m,
		"Awning",
		Vector3.new(math.min(bw - 4, 22), 1.6, 3),
		origin * CFrame.new(0, 7, -d / 2 + 1.6),
		look.accent,
		false
	)
end

-- Low shop: glass storefront, awning (front 4 studs), name board, neon trim.
local function shopBody(
	m: Model,
	rng: Random,
	origin: CFrame,
	w: number,
	d: number,
	h: number,
	name: string,
	color: Color3?
)
	local bw, bd = w - 0.8, d - 4.4
	local o = origin * CFrame.new(0, 0, 2.2)
	local body = color or pick(rng, SHOP)
	local accent = pick(rng, NEON)
	part(m, "Body", Vector3.new(bw, h - 1, bd), o * CFrame.new(0, (h - 1) / 2, 0), body)
	local store = band(m, "Storefront", o, bw, bd, 4, 6, 0.4, C.windowDay, Enum.Material.Glass)
	nightGlow(store, C.windowNight)
	wedge(m, "Awning", Vector3.new(bw - 2, 1.8, 4), origin * CFrame.new(0, 8.2, -d / 2 + 2), C.white, false)
	local signH = math.clamp(h - 12.5, 2.4, 4)
	sign(
		m,
		"ShopSign",
		name,
		Vector3.new(bw * 0.78, signH, 0.8),
		o * CFrame.new(0, 9.8 + signH / 2, -bd / 2 - 0.4),
		C.dark,
		accent,
		{ maxDistance = 260 }
	)
	part(m, "Cap", Vector3.new(bw + 0.6, 1, bd + 0.6), o * CFrame.new(0, h - 0.5, 0), body:Lerp(C.dark, 0.45))
	neon(m, "CapTrim", Vector3.new(bw + 0.7, 0.3, bd + 0.7), o * CFrame.new(0, h - 1.15, 0), accent)
end

local function houseBody(m: Model, rng: Random, origin: CFrame, w: number, d: number, h: number)
	local wallH = h * 0.6
	local bw, bd = w - 1.6, d - 3
	local o = origin * CFrame.new(0, 0, 1.5)
	part(m, "Body", Vector3.new(bw, wallH, bd), o * CFrame.new(0, wallH / 2, 0), pick(rng, PASTEL))
	local win = band(m, "Windows", o, bw, bd, wallH * 0.6, 2.6, 0.3, C.windowDay, Enum.Material.Glass)
	if rng:NextNumber() < 0.8 then
		nightGlow(win, C.windowNight)
	end
	local roofColor = pick(rng, ROOF)
	local rh = h - wallH
	local half = bd / 2 + 0.6
	wedge(m, "Roof", Vector3.new(bw + 1.4, rh, half), o * CFrame.new(0, wallH + rh / 2, -half / 2), roofColor)
	wedge(
		m,
		"Roof",
		Vector3.new(bw + 1.4, rh, half),
		o * CFrame.new(0, wallH + rh / 2, half / 2) * CFrame.Angles(0, math.pi, 0),
		roofColor
	)
	part(m, "Porch", Vector3.new(bw * 0.5, 0.6, 3), origin * CFrame.new(0, 0.3, -d / 2 + 1.5), C.white)
	part(m, "Door", Vector3.new(3.6, 6, 0.4), o * CFrame.new(0, 3, -bd / 2 - 0.2), pick(rng, SHOP))
end

-- Modern flat-roof villa: two stacked white boxes with glass bands.
local function villaBody(m: Model, rng: Random, origin: CFrame, w: number, d: number, h: number)
	local white = rgb(244, 242, 236)
	local lowH = h * 0.5
	part(m, "Lower", Vector3.new(w - 1, lowH, d - 1), origin * CFrame.new(0, lowH / 2, 0), white)
	local g1 = band(m, "Glass", origin, w - 1, d - 1, lowH * 0.5, lowH * 0.5, 0.3, C.windowDay, Enum.Material.Glass)
	nightGlow(g1, C.windowNight)
	local uw, ud = w * 0.7, d * 0.7
	local upper = origin * CFrame.new(w * 0.1, lowH, d * 0.1)
	part(m, "Upper", Vector3.new(uw, h - lowH - 0.8, ud), upper * CFrame.new(0, (h - lowH - 0.8) / 2, 0), white)
	local g2 =
		band(m, "Glass", upper, uw, ud, (h - lowH) * 0.5, (h - lowH) * 0.4, 0.3, C.windowDay, Enum.Material.Glass)
	nightGlow(g2, C.windowNight)
	part(m, "RoofTrim", Vector3.new(uw + 0.6, 0.8, ud + 0.6), upper * CFrame.new(0, h - lowH - 0.4, 0), pick(rng, NEON))
end

local function gasBody(m: Model, rng: Random, origin: CFrame, w: number, d: number, h: number)
	local red = rgb(226, 52, 52)
	-- kiosk at the back-left, canopy over the pumps at the front-right
	local kw, kd, kh = w * 0.38, d * 0.36, math.min(h * 0.45, 16)
	local kiosk = origin * CFrame.new(-w / 2 + kw / 2 + 0.5, 0, d / 2 - kd / 2 - 0.5)
	part(m, "Kiosk", Vector3.new(kw, kh, kd), kiosk * CFrame.new(0, kh / 2, 0), C.white)
	local glassBand = band(m, "KioskGlass", kiosk, kw, kd, 4, 5, 0.3, C.windowDay, Enum.Material.Glass)
	nightGlow(glassBand, C.windowNight)
	part(m, "KioskRoof", Vector3.new(kw + 0.6, 1.4, kd + 0.6), kiosk * CFrame.new(0, kh + 0.7, 0), red)
	local cw, cd = w * 0.62, d * 0.58
	local canopy = origin * CFrame.new(w / 2 - cw / 2 - 0.5, 0, -d / 2 + cd / 2 + 0.5)
	local ch = h * 0.55
	part(m, "Canopy", Vector3.new(cw, 2, cd), canopy * CFrame.new(0, ch, 0), red)
	local trim =
		neon(m, "CanopyTrim", Vector3.new(cw + 0.3, 0.5, cd + 0.3), canopy * CFrame.new(0, ch - 1.1, 0), C.white)
	trim.Color = C.white
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			part(
				m,
				"CanopyPillar",
				Vector3.new(1.2, ch - 1, 1.2),
				canopy * CFrame.new(sx * cw * 0.35, (ch - 1) / 2, sz * cd * 0.3),
				C.white
			)
		end
	end
	for _, sx in { -1, 1 } do
		part(
			m,
			"Pump",
			Vector3.new(2, 5, 1.4),
			canopy * CFrame.new(sx * cw * 0.18, 2.5, 0),
			pick(rng, { C.red, C.yellow })
		)
	end
end

local function warehouseBody(m: Model, rng: Random, origin: CFrame, w: number, d: number, h: number)
	local wallH = h * 0.72
	local color = pick(rng, { rgb(70, 130, 200), rgb(60, 150, 160), rgb(200, 120, 70), rgb(120, 130, 150) })
	part(m, "Body", Vector3.new(w - 0.6, wallH, d - 0.6), origin * CFrame.new(0, wallH / 2, 0), color, {
		material = Enum.Material.DiamondPlate,
	})
	local rh = h - wallH
	local half = (d - 0.6) / 2
	local roof = color:Lerp(C.dark, 0.35)
	wedge(m, "Roof", Vector3.new(w - 0.6, rh, half), origin * CFrame.new(0, wallH + rh / 2, -half / 2), roof)
	wedge(
		m,
		"Roof",
		Vector3.new(w - 0.6, rh, half),
		origin * CFrame.new(0, wallH + rh / 2, half / 2) * CFrame.Angles(0, math.pi, 0),
		roof
	)
	for i = -1, 1 do
		deco(
			m,
			"RollerDoor",
			Vector3.new(w * 0.22, wallH * 0.55, 0.3),
			origin * CFrame.new(i * w * 0.28, wallH * 0.28, -d / 2 + 0.15),
			rgb(240, 200, 60)
		)
	end
end

local function barnBody(m: Model, _rng: Random, origin: CFrame, w: number, d: number, h: number)
	local wallH = h * 0.55
	local metal = rgb(92, 70, 58)
	part(m, "Body", Vector3.new(w - 1, wallH, d - 1), origin * CFrame.new(0, wallH / 2, 0), metal, {
		material = Enum.Material.CorrodedMetal,
	})
	local rh = h - wallH
	local half = d / 2
	local roof = rgb(170, 100, 70)
	wedge(m, "Roof", Vector3.new(w, rh, half), origin * CFrame.new(0, wallH + rh / 2, -half / 2), roof)
	wedge(
		m,
		"Roof",
		Vector3.new(w, rh, half),
		origin * CFrame.new(0, wallH + rh / 2, half / 2) * CFrame.Angles(0, math.pi, 0),
		roof
	)
	deco(
		m,
		"BarnDoor",
		Vector3.new(w * 0.4, wallH * 0.7, 0.3),
		origin * CFrame.new(0, wallH * 0.35, -d / 2 + 0.3),
		C.dark
	)
end

local function lighthouseBody(m: Model, _rng: Random, origin: CFrame, w: number, d: number, h: number)
	local dia = math.min(w, d) * 0.55
	local towerH = h * 0.72
	for i = 0, 3 do
		cyl(
			m,
			"TowerBand",
			towerH / 4,
			dia * (1 - i * 0.06),
			origin * CFrame.new(0, towerH / 8 + i * towerH / 4, 0),
			if i % 2 == 0 then C.white else C.red
		)
	end
	local lamp = cyl(m, "Lantern", h * 0.12, dia * 0.7, origin * CFrame.new(0, towerH + h * 0.06, 0), C.yellow, {
		material = Enum.Material.Glass,
	})
	nightGlow(lamp, rgb(255, 236, 160))
	cyl(
		m,
		"LanternCap",
		h - towerH - h * 0.12,
		dia * 0.5,
		origin * CFrame.new(0, (h + towerH + h * 0.12) / 2, 0),
		C.red
	)
	part(
		m,
		"KeeperHouse",
		Vector3.new(w * 0.5, h * 0.18, d * 0.4),
		origin * CFrame.new(w * 0.22, h * 0.09, d * 0.25),
		C.white
	)
end

local function hutBody(m: Model, rng: Random, origin: CFrame, w: number, d: number, h: number)
	local stilt = h * 0.25
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			part(
				m,
				"Stilt",
				Vector3.new(1, stilt, 1),
				origin * CFrame.new(sx * w * 0.35, stilt / 2, sz * d * 0.35),
				C.wood
			)
		end
	end
	local bodyH = h * 0.4
	part(
		m,
		"Hut",
		Vector3.new(w * 0.8, bodyH, d * 0.8),
		origin * CFrame.new(0, stilt + bodyH / 2, 0),
		pick(rng, { C.cyan, rgb(90, 200, 160) })
	)
	local rh = h - stilt - bodyH
	local thatch = rgb(222, 180, 90)
	wedge(m, "Thatch", Vector3.new(w, rh, d / 2), origin * CFrame.new(0, stilt + bodyH + rh / 2, -d / 4), thatch)
	wedge(
		m,
		"Thatch",
		Vector3.new(w, rh, d / 2),
		origin * CFrame.new(0, stilt + bodyH + rh / 2, d / 4) * CFrame.Angles(0, math.pi, 0),
		thatch
	)
end

-- Police HQ: white block, blue stripes, window bands, roof sirens (the art kit's police_hq has a light bar too).
local function policeBody(m: Model, _rng: Random, origin: CFrame, w: number, d: number, h: number)
	part(m, "Body", Vector3.new(w - 1, h - 6, d - 4), origin * CFrame.new(0, (h - 6) / 2, 2), C.white)
	local o = origin * CFrame.new(0, 0, 2)
	local y = 6
	while y < h - 10 do
		local win = band(m, "Windows", o, w - 1, d - 4, y, 4.2, 0.4, C.windowDay, Enum.Material.Glass)
		nightGlow(win, rgb(200, 230, 255))
		local b = band(m, "PoliceStripe", o, w - 1, d - 4, y + 4.6, 1.6, 0.6, C.police)
		nightGlow(b, C.police)
		y += 10
	end
	part(m, "Parapet", Vector3.new(w, 1.6, d - 3), o * CFrame.new(0, h - 6 + 0.8, 0), rgb(26, 40, 90))
	part(m, "Portico", Vector3.new(w * 0.4, 1.2, 4), origin * CFrame.new(0, 11, -d / 2 + 2), C.white)
	neon(m, "PorticoTrim", Vector3.new(w * 0.4 + 0.2, 0.5, 4.2), origin * CFrame.new(0, 10.5, -d / 2 + 2), C.police)
	for _, x in { -w * 0.18, w * 0.18 } do
		part(m, "PorticoPillar", Vector3.new(1.6, 10.4, 1.6), origin * CFrame.new(x, 5.2, -d / 2 + 1), C.white)
	end
	deco(
		m,
		"Doors",
		Vector3.new(10, 8, 0.6),
		origin * CFrame.new(0, 4, -d / 2 + 3.6),
		rgb(30, 50, 100),
		Enum.Material.Glass
	)
	-- roof light bar (the HQ's silhouette from the street)
	neon(m, "SirenRed", Vector3.new(w * 0.2, 3, 3), origin * CFrame.new(-w * 0.1, h - 3, 0), C.red)
	neon(m, "SirenBlue", Vector3.new(w * 0.2, 3, 3), origin * CFrame.new(w * 0.1, h - 3, 0), C.police)
	part(m, "SirenBase", Vector3.new(w * 0.5, 2, 5), origin * CFrame.new(0, h - 5.5, 0), C.white)
end

local LOOKS: { [string]: () -> Look } = {
	apartment_balcony = function()
		return { body = PASTEL[1], accent = C.cyan, windows = C.windowDay }
	end,
	brick_loft = function()
		return { body = rgb(168, 78, 58), accent = C.dark, material = Enum.Material.Brick, windows = C.windowDay }
	end,
	office_block = function()
		return { body = rgb(214, 220, 232), accent = rgb(60, 70, 100), windows = rgb(70, 150, 220) }
	end,
	hotel_beach = function()
		return { body = rgb(92, 200, 210), accent = C.pink, windows = rgb(250, 190, 200) }
	end,
}

local SHOP_SIGNS: { [string]: string } = {
	convenience_store = "24/7 MART",
	pizza_shop = "PIZZA",
	diner = "DINER",
	donut_shop = "DONUTS",
	spray_booth = "PAINT",
	gas_station = "GAS",
}
MapBuilder.SHOP_SIGNS = SHOP_SIGNS

local SHOP_COLORS: { [string]: Color3 } = {
	convenience_store = rgb(250, 150, 50),
	pizza_shop = rgb(240, 200, 60),
	diner = rgb(232, 72, 72),
	donut_shop = rgb(90, 170, 220),
	spray_booth = rgb(150, 92, 222),
}

-- Building slot for `role` at `origin` (ground center, front = LookVector), scaled from the kit's default size.
-- Returns the slot and its bounds (W, H, D).
local function buildingSlot(
	parent: Instance,
	rng: Random,
	role: string,
	origin: CFrame,
	scale: number
): (Model, Vector3)
	local dims = (KIT_DIMS[role] or Vector3.new(30, 30, 30)) * scale
	local m = newSlot(parent, role, "Buildings", role, origin, fitFor("Buildings", role, scale))
	m:SetAttribute("Footprint", dims)
	local w, h, d = dims.X, dims.Y, dims.Z
	if role == "skyscraper_twist" then
		towerBody(m, rng, origin, w, d, h, "twist")
	elseif role == "skyscraper_deco" then
		towerBody(m, rng, origin, w, d, h, "deco")
	elseif role == "skyscraper_neon" then
		towerBody(m, rng, origin, w, d, h, "neon")
	elseif LOOKS[role] then
		midriseBody(m, rng, origin, w, d, h, LOOKS[role]())
	elseif SHOP_SIGNS[role] and role ~= "gas_station" then
		shopBody(m, rng, origin, w, d, h, SHOP_SIGNS[role], SHOP_COLORS[role])
	elseif role == "gas_station" then
		gasBody(m, rng, origin, w, d, h)
	elseif role == "suburban_house" then
		houseBody(m, rng, origin, w, d, h)
	elseif role == "beach_villa" then
		villaBody(m, rng, origin, w, d, h)
	elseif role == "warehouse" then
		warehouseBody(m, rng, origin, w, d, h)
	elseif role == "chop_shop" then
		barnBody(m, rng, origin, w, d, h)
	elseif role == "lighthouse" then
		lighthouseBody(m, rng, origin, w, d, h)
	elseif role == "surf_shack" then
		hutBody(m, rng, origin, w, d, h)
	elseif role == "police_hq" then
		policeBody(m, rng, origin, w, d, h)
	else
		part(m, "Body", Vector3.new(w, h, d), origin * CFrame.new(0, h / 2, 0), pick(rng, PLASTER))
	end
	return m, dims
end

-- Largest scale <= maxScale that fits `role` (facing its front) into availW (along the front) x availD (depth).
local function fitScale(role: string, availW: number, availD: number, maxScale: number): number
	local dims = KIT_DIMS[role] or Vector3.new(30, 30, 30)
	return math.min(maxScale, availW / dims.X, availD / dims.Z)
end

---------------------------------------------------------------------------------------------------------------
-- Lot dressing (procedural, never replaced: paving, parking lots, pools, hedges, pylon signs, neon accents)
---------------------------------------------------------------------------------------------------------------

-- World point on the lot (curb top) at block-local (x, z).
local function at(o: Vector3, x: number, z: number): Vector3
	return Vector3.new(o.X + x, CURB_TOP, o.Z + z)
end

local function flat(
	ctx: Ctx,
	name: string,
	o: Vector3,
	x: number,
	z: number,
	sx: number,
	sz: number,
	color: Color3,
	y: number?
)
	local h = y or 0.1
	part(ctx.blocks, name, Vector3.new(sx, h, sz), CFrame.new(at(o, x, z) + Vector3.new(0, h / 2, 0)), color, {
		collide = false,
		shadow = false,
	})
end

-- Parking lot: asphalt pad with stall lines (stalls run along local X when alongX).
local function parkingLot(ctx: Ctx, o: Vector3, x: number, z: number, sx: number, sz: number, alongX: boolean)
	flat(ctx, "ParkingLot", o, x, z, sx, sz, rgb(74, 77, 96), 0.12)
	local len = if alongX then sx else sz
	local depth = if alongX then sz else sx
	local n = math.floor((len - 2) / 9)
	for i = 0, n do
		local a = -len / 2 + 1 + i * 9
		local lineLen = math.min(15, depth * 0.42)
		for _, side in { -1, 1 } do
			local b = side * (depth / 2 - lineLen / 2 - 0.5)
			local lx, lz = if alongX then x + a else x + b, if alongX then z + b else z + a
			local size = if alongX then Vector3.new(0.5, 0.06, lineLen) else Vector3.new(lineLen, 0.06, 0.5)
			part(ctx.blocks, "StallLine", size, CFrame.new(at(o, lx, lz) + Vector3.new(0, 0.15, 0)), C.white, {
				collide = false,
				shadow = false,
			})
		end
	end
end

local function pool(ctx: Ctx, o: Vector3, x: number, z: number, sx: number, sz: number)
	flat(ctx, "PoolDeck", o, x, z, sx + 5, sz + 5, rgb(244, 240, 228), 0.25)
	part(ctx.blocks, "Pool", Vector3.new(sx, 0.2, sz), CFrame.new(at(o, x, z) + Vector3.new(0, 0.3, 0)), C.water, {
		collide = false,
		reflectance = 0.15,
		shadow = false,
	})
end

local function hedge(ctx: Ctx, o: Vector3, x0: number, z0: number, x1: number, z1: number)
	local sx, sz = math.max(2.4, math.abs(x1 - x0)), math.max(2.4, math.abs(z1 - z0))
	part(
		ctx.blocks,
		"Hedge",
		Vector3.new(sx, 2.6, sz),
		CFrame.new(at(o, (x0 + x1) / 2, (z0 + z1) / 2) + Vector3.new(0, 1.3, 0)),
		rgb(70, 160, 76),
		{ material = Enum.Material.Grass, collide = false }
	)
end

-- White picket fence along the lot edge on `side` from along-coordinate a0 to a1 (decor: never collides).
local function picketFence(ctx: Ctx, o: Vector3, side: string, a0: number, a1: number)
	if a1 - a0 < 2 then
		return
	end
	local sd = SIDES[side]
	local c = sd.normal * (LOT_HALF - 0.8) + sd.along * ((a0 + a1) / 2)
	local len = a1 - a0
	local size = if sd.along.X ~= 0 then Vector3.new(len, 2.2, 0.35) else Vector3.new(0.35, 2.2, len)
	part(ctx.blocks, "PicketFence", size, CFrame.new(at(o, c.X, c.Z) + Vector3.new(0, 1.1, 0)), C.white, {
		collide = false,
	})
end

-- Roadside pylon sign (Americana): pole + lit board facing `dir`.
local function pylonSign(ctx: Ctx, pos: Vector3, dir: Vector3, text: string, color: Color3)
	local h = 15
	part(ctx.props, "PylonPole", Vector3.new(1, h, 1), CFrame.new(pos + Vector3.new(0, h / 2, 0)), C.metal)
	local center = pos + Vector3.new(0, h + 2.6, 0)
	local board =
		sign(ctx.props, "PylonSign", text, Vector3.new(11, 5, 1), CFrame.lookAt(center, center + dir), C.dark, color, {
			back = true,
			maxDistance = 400,
		})
	local frame = part(
		ctx.props,
		"PylonFrame",
		Vector3.new(12, 6, 0.6),
		CFrame.lookAt(center, center + dir),
		color:Lerp(C.dark, 0.4),
		{ collide = false, shadow = false }
	)
	nightGlow(frame, color)
	board.CanCollide = false
end

-- Neon outline on the ground around a tower footprint + aviation beacon on top (the downtown night look; both
-- outlive the placeholder).
local function towerAccents(ctx: Ctx, origin: CFrame, w: number, d: number, h: number, color: Color3)
	local m = 1.6
	local ring = {
		{ Vector3.new(w + 2 * m, 0.25, 0.6), Vector3.new(0, 0, -(d / 2 + m)) },
		{ Vector3.new(w + 2 * m, 0.25, 0.6), Vector3.new(0, 0, d / 2 + m) },
		{ Vector3.new(0.6, 0.25, d + 2 * m), Vector3.new(-(w / 2 + m), 0, 0) },
		{ Vector3.new(0.6, 0.25, d + 2 * m), Vector3.new(w / 2 + m, 0, 0) },
	}
	for _, r in ring do
		local p =
			part(ctx.props, "NeonEdge", r[1], origin * CFrame.new(r[2] + Vector3.new(0, 0.12, 0)), rgb(60, 62, 80), {
				collide = false,
				shadow = false,
			})
		nightGlow(p, color)
	end
	local beacon = ball(ctx.props, "Beacon", 2.2, (origin * CFrame.new(0, h + 0.8, 0)).Position, rgb(170, 40, 40), {
		collide = false,
		shadow = false,
	})
	nightGlow(beacon, C.red)
end

---------------------------------------------------------------------------------------------------------------
-- District fill (generic city blocks)
---------------------------------------------------------------------------------------------------------------

-- Building whose front sits `setback` behind the lot edge on `side`, centered at `along` on that edge.
local function frontBuilding(
	ctx: Ctx,
	rng: Random,
	o: Vector3,
	role: string,
	side: string,
	along: number,
	scale: number,
	setback: number?
): (Model, Vector3, CFrame)
	local sd = SIDES[side]
	local dims = (KIT_DIMS[role] or Vector3.new(30, 30, 30)) * scale
	local c = sd.normal * (BUILD_HALF - (setback or 1) - dims.Z / 2) + sd.along * along
	local p = at(o, c.X, c.Z)
	local origin = CFrame.lookAt(p, p + sd.normal)
	local m = buildingSlot(ctx.buildings, rng, role, origin, scale)
	return m, dims, origin
end

-- Sides of a corner quadrant: e.g. "NW" -> N, W.
local QUADRANTS: { [string]: { x: number, z: number, sides: { string } } } = {
	NW = { x = -1, z = -1, sides = { "N", "W" } },
	NE = { x = 1, z = -1, sides = { "N", "E" } },
	SW = { x = -1, z = 1, sides = { "S", "W" } },
	SE = { x = 1, z = 1, sides = { "S", "E" } },
}
local OPPOSITE: { [string]: string } = { NW = "SE", SE = "NW", NE = "SW", SW = "NE" }

-- Along-coordinate of a quadrant on one of its sides (N/S run along X, W/E along Z).
local function quadAlong(q: string, side: string, width: number): number
	local Q = QUADRANTS[q]
	local sgn = if side == "N" or side == "S" then Q.x else Q.z
	return sgn * (BUILD_HALF - width / 2 - 1)
end

local DOWNTOWN_PLAN: { [string]: { any } } = {
	["-2,-2"] = { "solo", "skyscraper_twist", 0.97 },
	["1,-2"] = { "solo", "skyscraper_twist", 0.86 },
	["1,1"] = { "solo", "skyscraper_deco", 1.15 },
	["-2,1"] = { "solo", "skyscraper_deco", 1.04 },
	["-2,-1"] = { "twin", "skyscraper_neon", "office_block" },
	["-2,0"] = { "twin", "skyscraper_deco", "skyscraper_neon" },
	["-1,-2"] = { "twin", "office_block", "skyscraper_neon" },
	["-1,1"] = { "twin", "skyscraper_neon", "skyscraper_deco" },
	["0,-2"] = { "twin", "skyscraper_deco", "office_block" },
	["0,1"] = { "twin", "skyscraper_neon", "office_block" },
	["1,-1"] = { "twin", "office_block", "skyscraper_neon" },
}

local TWIN_SCALE: { [string]: number } = { skyscraper_neon = 1.0, skyscraper_deco = 0.62, office_block = 1.0 }

-- Side of the block facing the city center (towers turn their fronts toward downtown streets).
local function sideTowardCenter(bx: number, bz: number): string
	local cx, cz = bx + 0.5, bz + 0.5
	if math.abs(cx) >= math.abs(cz) then
		return if cx > 0 then "W" else "E"
	end
	return if cz > 0 then "N" else "S"
end

local function fillDowntown(ctx: Ctx, rng: Random, bx: number, bz: number, o: Vector3)
	local plan = DOWNTOWN_PLAN[blockKey(bx, bz)]
	if not plan then
		return
	end
	if plan[1] == "solo" then
		local role, scale = plan[2] :: string, plan[3] :: number
		local side = sideTowardCenter(bx, bz)
		local dims = KIT_DIMS[role] * scale
		local _, _, origin = frontBuilding(ctx, rng, o, role, side, 0, scale, math.max(1, (100 - dims.Z) / 2 - 8))
		towerAccents(ctx, origin, dims.X, dims.Z, dims.Y, pick(rng, NEON))
		if role == "skyscraper_deco" then
			-- back plaza: a palm + a bench
			local back = SIDES[side].normal * -42
			local along = SIDES[side].along
			local pp = o + back + along * -30
			palm(ctx.props, Vector3.new(pp.X, CURB_TOP, pp.Z), rand(rng, 18, 22), rng)
			local bp = at(o, back.X, back.Z)
			bench(ctx.props, CFrame.lookAt(bp, bp - SIDES[side].normal))
			flat(
				ctx,
				"Plaza",
				o,
				back.X,
				back.Z,
				if along.X ~= 0 then 96 else 14,
				if along.Z ~= 0 then 96 else 14,
				rgb(226, 220, 206)
			)
		end
		return
	end
	-- twin towers on diagonal quadrants, small plazas on the other two
	local even = (bx + bz) % 2 == 0
	local qa = if even then "NW" else "NE"
	local qb = OPPOSITE[qa]
	for i, q in { qa, qb } do
		local role = plan[i + 1] :: string
		local side = QUADRANTS[q].sides[rng:NextInteger(1, 2)]
		local scale = fitScale(role, 46, 46, TWIN_SCALE[role] or 1)
		local dims = KIT_DIMS[role] * scale
		local _, _, origin = frontBuilding(ctx, rng, o, role, side, quadAlong(q, side, dims.X), scale, 1)
		if role ~= "office_block" then
			towerAccents(ctx, origin, dims.X, dims.Z, dims.Y, pick(rng, NEON))
		end
	end
	local qc = if even then "NE" else "NW"
	local qd = OPPOSITE[qc]
	for i, q in { qc, qd } do
		local Q = QUADRANTS[q]
		local cx, cz = Q.x * 25, Q.z * 25
		flat(ctx, "Plaza", o, cx, cz, 44, 44, rgb(226, 220, 206))
		if i == 1 and (bx - bz) % 4 == 0 then
			palm(ctx.props, at(o, cx, cz), rand(rng, 17, 21), rng)
		else
			cyl(ctx.blocks, "Planter", 1.4, 10, CFrame.new(at(o, cx, cz) + Vector3.new(0, 0.7, 0)), rgb(196, 170, 140))
			ball(ctx.blocks, "Shrub", 7, at(o, cx, cz) + Vector3.new(0, 2.4, 0), C.leafB, { collide = false })
		end
		if i == 2 then
			-- newspaper box or trash can at the plaza's sidewalk edge
			local sd = SIDES[Q.sides[1]]
			local np = sd.normal * (LOT_HALF - 1.5) + sd.along * (if sd.along.X ~= 0 then cx else cz)
			if (bx + bz) % 2 == 0 then
				newspaperBox(ctx.props, groundAt(at(o, np.X, np.Z), sd.normal))
			else
				trashCan(ctx.props, groundAt(at(o, np.X, np.Z), sd.normal))
			end
		end
	end
end

-- Flat-roof kit buildings that can carry a rooftop ad: { roof height / H, board depth from the front / D }.
local ROOF_AD: { [string]: { number } } = {
	convenience_store = { 1.0, 0.45 },
	pizza_shop = { 1.0, 0.5 },
	office_block = { 0.94, 0.55 },
}

-- Rooftop billboard (tag "Billboard", 16:9 like the ad art) on posts sunk into the roof; lives outside the slot.
local function rooftopAd(ctx: Ctx, rng: Random, role: string, origin: CFrame, dims: Vector3)
	local roof = ROOF_AD[role]
	if not roof then
		return
	end
	local bw = math.min(dims.X * 0.8, 30)
	local bh = bw * 9 / 16
	local roofY = dims.Y * roof[1]
	local z = -dims.Z / 2 + dims.Z * roof[2]
	local ad = adText(ctx)
	local board = sign(
		ctx.props,
		"Billboard",
		ad,
		Vector3.new(bw, bh, 0.8),
		origin * CFrame.new(0, roofY + 3 + bh / 2, z),
		C.white,
		pick(rng, SHOP),
		{ glow = pick(rng, NEON), maxDistance = 500 }
	)
	tag(board, MapBuilder.TAG_BILLBOARD)
	board:SetAttribute("AdText", ad)
	for _, sx in { -1, 1 } do
		part(
			ctx.props,
			"BillboardPost",
			Vector3.new(0.8, 7, 0.8),
			origin * CFrame.new(sx * bw * 0.35, roofY - 0.5, z + 0.6),
			C.metal
		)
	end
end

-- Midtown -------------------------------------------------------------------------------------------------------

local MID_ROLES =
	{ "apartment_balcony", "brick_loft", "office_block", "apartment_balcony", "brick_loft", "convenience_store" }
local MID_MAX: { [string]: number } = {
	apartment_balcony = 1.4,
	brick_loft = 1.5,
	office_block = 1.12,
	convenience_store = 1.4,
}

local function pocketPark(ctx: Ctx, rng: Random, o: Vector3, side: string, busStopHere: boolean)
	-- half-block pocket park on `side`: lawn path, a shade tree, a bench + flower box, maybe a bus stop
	local sd = SIDES[side]
	local c = sd.normal * 25
	local a = sd.along
	flat(ctx, "ParkPath", o, c.X, c.Z, if a.X ~= 0 then 96 else 4, if a.Z ~= 0 then 96 else 4, rgb(230, 208, 164))
	local k = if rng:NextNumber() < 0.5 then -26 else 26
	local tp = c + a * k + sd.normal * rand(rng, -4, 6)
	roundTree(ctx.props, at(o, tp.X, tp.Z), rand(rng, 18, 23), rng)
	local bp = at(o, c.X, c.Z) - sd.normal * 5
	bench(ctx.props, CFrame.lookAt(bp, bp + sd.normal), rgb(90, 160, 90))
	if busStopHere then
		local sp = sd.normal * (LOT_HALF - 4.6) - a * k
		busStop(ctx.props, groundAt(at(o, sp.X, sp.Z), sd.normal))
		local np = sd.normal * (LOT_HALF - 1.5) - a * (k * 0.5)
		newspaperBox(ctx.props, groundAt(at(o, np.X, np.Z), sd.normal))
	end
	local fp = c + sd.normal * 12
	part(
		ctx.blocks,
		"FlowerBox",
		Vector3.new(if a.X ~= 0 then 16 else 3, 0.9, if a.Z ~= 0 then 16 else 3),
		CFrame.new(at(o, fp.X, fp.Z) + Vector3.new(0, 0.45, 0)),
		pick(rng, { C.pink, C.yellow, C.red, C.purple }),
		{ collide = false }
	)
end

local function fillMidtown(ctx: Ctx, rng: Random, bx: number, bz: number, o: Vector3)
	local h = (bx * 3 + bz * 7) % #MID_ROLES
	-- pairs on half the blocks (not the ring corners), a building + pocket park on the rest
	local corner = math.abs(bx + 0.5) == math.abs(bz + 0.5)
	local pair = (bx + bz) % 2 == 0 and not corner
	local sides = if (bx + bz * 3) % 2 == 0 then { "N", "S" } else { "W", "E" }
	if rng:NextNumber() < 0.5 then
		sides = { sides[2], sides[1] }
	end
	for i, side in sides do
		if i == 2 and not pair then
			pocketPark(ctx, rng, o, side, (bx * 5 + bz) % 3 ~= 0)
			break
		end
		local role = MID_ROLES[(h + i - 1) % #MID_ROLES + 1]
		local scale = fitScale(role, 58, 44, MID_MAX[role])
		local dims = KIT_DIMS[role] * scale
		local sgn = if rng:NextNumber() < 0.5 then -1 else 1
		local along = sgn * (BUILD_HALF - dims.X / 2 - 1)
		local _, _, origin = frontBuilding(ctx, rng, o, role, side, along, scale, 1)
		if rng:NextNumber() < 0.5 then
			rooftopAd(ctx, rng, role, origin, dims)
		end
		-- the rest of the half along the street: a parking lot
		local free = 100 - dims.X - 4
		if free >= 22 then
			local sd = SIDES[side]
			local mid = -sgn * (BUILD_HALF - free / 2)
			local depth = 30
			local c = sd.normal * (BUILD_HALF - depth / 2 - 1) + sd.along * mid
			local alongX = sd.along.X ~= 0
			parkingLot(ctx, o, c.X, c.Z, if alongX then free else depth, if alongX then depth else free, alongX)
		end
	end
end

-- Shops ring ----------------------------------------------------------------------------------------------------

local SHOP_PLAN: { [string]: { string } } = {
	["3,-4"] = { "gas" },
	["3,-3"] = { "corner", "diner" },
	["3,-2"] = { "corner", "pizza_shop" },
	["3,-1"] = { "parking" },
	["3,0"] = { "corner", "donut_shop" },
	["3,1"] = { "corner", "pizza_shop" },
	["3,2"] = { "corner", "diner" },
	["3,3"] = { "gas" },
	["-3,-4"] = { "corner", "convenience_store" },
	["-2,-4"] = { "double", "diner", "pizza_shop" },
	["-1,-4"] = { "corner", "donut_shop" },
	["0,-4"] = { "gas" },
	["1,-4"] = { "corner", "pizza_shop" },
	["2,-4"] = { "corner", "diner" },
	["-3,3"] = { "corner", "diner" },
	["-2,3"] = { "corner", "pizza_shop" },
	["-1,3"] = { "parking" },
	["0,3"] = { "corner", "donut_shop" },
	["1,3"] = { "gas" },
	["2,3"] = { "corner", "convenience_store" },
}

local SHOP_MAX: { [string]: number } = { diner = 1.5, pizza_shop = 1.5, donut_shop = 1.6, convenience_store = 1.45 }
local QUAD_KEYS = { "NW", "NE", "SE", "SW" }

-- Shop on a corner quadrant facing one street, parking beside it along that street, pylon sign at the corner.
local function cornerShop(ctx: Ctx, rng: Random, o: Vector3, role: string, q: string, side: string)
	local scale = fitScale(role, 56, 48, SHOP_MAX[role] or 1.3)
	local dims = KIT_DIMS[role] * scale
	local _, _, origin = frontBuilding(ctx, rng, o, role, side, quadAlong(q, side, dims.X), scale, 2)
	if rng:NextNumber() < 0.6 then
		rooftopAd(ctx, rng, role, origin, dims)
	end
	local sd = SIDES[side]
	local Q = QUADRANTS[q]
	local sgn = if sd.along.X ~= 0 then Q.x else Q.z
	-- parking beside the shop, toward the middle of the block edge
	local free = 96 - dims.X - 4
	local depth = 28
	local mid = -sgn * (BUILD_HALF - free / 2)
	local c = sd.normal * (BUILD_HALF - depth / 2 - 1) + sd.along * mid
	local alongX = sd.along.X ~= 0
	parkingLot(ctx, o, c.X, c.Z, if alongX then free else depth, if alongX then depth else free, alongX)
	local pp = sd.normal * (LOT_HALF - 3) + sd.along * (-sgn * 6)
	pylonSign(ctx, at(o, pp.X, pp.Z), sd.normal, SHOP_SIGNS[role] or "SHOP", pick(rng, NEON))
end

local function fillShops(ctx: Ctx, rng: Random, bx: number, bz: number, o: Vector3)
	local plan = SHOP_PLAN[blockKey(bx, bz)]
	if not plan then
		return
	end
	local q = QUAD_KEYS[(bx * 5 + bz * 3) % 4 + 1]
	local kind = plan[1]
	if kind == "corner" or kind == "double" then
		local side = QUADRANTS[q].sides[rng:NextInteger(1, 2)]
		cornerShop(ctx, rng, o, plan[2], q, side)
		local oq = OPPOSITE[q]
		local oc = QUADRANTS[oq]
		if kind == "double" then
			cornerShop(ctx, rng, o, plan[3], oq, oc.sides[rng:NextInteger(1, 2)])
		else
			-- back lawn: hedges + a shade tree
			local cx, cz = oc.x * 26, oc.z * 26
			roundTree(ctx.props, at(o, cx, cz), rand(rng, 18, 24), rng)
			hedge(ctx, o, oc.x * 49, oc.z * 8, oc.x * 49, oc.z * 48)
			hedge(ctx, o, oc.x * 8, oc.z * 49, oc.x * 48, oc.z * 49)
		end
	elseif kind == "gas" then
		local side = QUADRANTS[q].sides[rng:NextInteger(1, 2)]
		local scale = fitScale("gas_station", 70, 70, 1.15)
		local dims = KIT_DIMS.gas_station * scale
		frontBuilding(ctx, rng, o, "gas_station", side, quadAlong(q, side, dims.X), scale, 2)
		local sd = SIDES[side]
		local Q = QUADRANTS[q]
		local sgn = if sd.along.X ~= 0 then Q.x else Q.z
		local pp = sd.normal * (LOT_HALF - 3) + sd.along * (-sgn * (BUILD_HALF - dims.X - 6))
		pylonSign(ctx, at(o, pp.X, pp.Z), sd.normal, "GAS", C.red)
		-- billboard on the opposite corner facing the other street
		local oq = QUADRANTS[OPPOSITE[q]]
		local bside = oq.sides[1]
		local bn = SIDES[bside].normal
		local bp = bn * 36
			+ Vector3.new(oq.x, 0, oq.z) * 22 * (if bn.X ~= 0 then Vector3.new(0, 0, 1) else Vector3.new(1, 0, 0))
		billboardProp(ctx, groundAt(at(o, bp.X, bp.Z), bn), 34, true)
		local tp = Vector3.new(oq.x * 38, 0, oq.z * 4)
		roundTree(ctx.props, at(o, tp.X, tp.Z), rand(rng, 18, 22), rng)
	else -- parking
		parkingLot(ctx, o, 0, -14, 96, 68, true)
		local side = if rng:NextNumber() < 0.5 then "S" else "N"
		local sn = SIDES[side].normal
		local bp = sn * 40 + Vector3.new(-22, 0, 0)
		billboardProp(ctx, groundAt(at(o, bp.X, bp.Z), sn), 38, true)
		hedge(ctx, o, -48, 24, 10, 24)
		roundTree(ctx.props, at(o, 30, 36), rand(rng, 18, 22), rng)
	end
end

-- Suburbs -------------------------------------------------------------------------------------------------------

local function fillSuburbs(ctx: Ctx, rng: Random, bx: number, bz: number, o: Vector3)
	-- one big house per block (two back-to-back houses on some), front lawn + driveway, backyard pool + hedge
	local double = (bz % 4 == 0) and bx == MapConfig.BLOCK_MIN + 1
	local sides = if (bx + bz) % 2 == 0 then { "E", "W" } else { "N", "S" }
	local count = if double then 2 else 1
	for i = 1, count do
		local side = sides[i]
		local role = if not double and (bz + bx) % 3 == 0 then "beach_villa" else "suburban_house"
		local scale = if role == "beach_villa" then 1.3 else 1.6
		local along = (if i == 1 then 1 else -1) * rand(rng, 8, 16)
		local _, dims = frontBuilding(ctx, rng, o, role, side, along, scale, 10)
		local sd = SIDES[side]
		local alongX = sd.along.X ~= 0
		-- driveway beside the house, down to the street
		local dw = sd.normal * (BUILD_HALF - 6) + sd.along * (along + dims.X / 2 + 5)
		flat(ctx, "Driveway", o, dw.X, dw.Z, if alongX then 8 else 14, if alongX then 14 else 8, rgb(206, 204, 210))
		-- picket fence along the front lawn, open at the driveway; mailbox by the gap
		local da = along + dims.X / 2 + 5
		picketFence(ctx, o, side, -48, da - 6)
		picketFence(ctx, o, side, da + 6, 48)
		if i == 1 and (bx + bz) % 2 == 0 then
			local mp = sd.normal * (LOT_HALF - 2.5) + sd.along * math.min(da + 4.6, 46)
			mailbox(ctx.props, groundAt(at(o, mp.X, mp.Z), sd.normal))
		elseif i == 1 then
			-- a round bush by the porch
			local bp = sd.normal * 44 + sd.along * (along - dims.X / 4)
			bush(ctx.props, at(o, bp.X, bp.Z), 5, rng)
		end
		-- garage at the top of the driveway (procedural: it stays in the dressed city)
		if da + 6 <= 48 then
			local gp = sd.normal * 31 + sd.along * (da + 0.8)
			local gcf = CFrame.lookAt(at(o, gp.X, gp.Z), at(o, gp.X, gp.Z) + sd.normal)
			local wall = pick(rng, PASTEL)
			part(ctx.blocks, "HouseGarage", Vector3.new(8.6, 8, 12), gcf * CFrame.new(0, 4, 0), wall)
			part(
				ctx.blocks,
				"HouseGarageRoof",
				Vector3.new(9.2, 0.8, 12.8),
				gcf * CFrame.new(0, 8.4, 0),
				pick(rng, ROOF)
			)
			deco(ctx.blocks, "GarageDoor", Vector3.new(7, 6, 0.3), gcf * CFrame.new(0, 3.2, -6.05), C.white)
		end
		-- front-yard shade tree on the far side from the driveway (every other house)
		if (bx + bz + i) % 2 == 1 or double then
			local ta = math.clamp(along - dims.X / 2 - 12, -40, 40)
			local tp = sd.normal * 40 + sd.along * ta
			roundTree(ctx.props, at(o, tp.X, tp.Z), rand(rng, 16, 21), rng)
		end
		if not double then
			local back = -sd.normal * 25 + sd.along * along
			pool(ctx, o, back.X, back.Z, if alongX then 18 else 10, if alongX then 10 else 18)
			local c = -sd.normal * 49
			hedge(ctx, o, c.X - sd.along.X * 44, c.Z - sd.along.Z * 44, c.X + sd.along.X * 44, c.Z + sd.along.Z * 44)
			-- backyard: garden shed + vegetable rows
			local sp = -sd.normal * 40 + sd.along * -32
			local scf = CFrame.lookAt(at(o, sp.X, sp.Z), at(o, sp.X, sp.Z) + sd.normal)
			part(ctx.blocks, "Shed", Vector3.new(7, 5, 6), scf * CFrame.new(0, 2.5, 0), C.wood, {
				material = Enum.Material.WoodPlanks,
			})
			wedge(ctx.blocks, "ShedRoof", Vector3.new(7.6, 2.4, 6.6), scf * CFrame.new(0, 6.2, 0), rgb(150, 70, 60))
			for r = 0, 2 do
				local gp = -sd.normal * (34 + r * 4) + sd.along * 34
				flat(
					ctx,
					"VeggieRow",
					o,
					gp.X,
					gp.Z,
					if alongX then 14 else 2,
					if alongX then 2 else 14,
					({ rgb(120, 200, 90), rgb(240, 120, 60), rgb(200, 220, 80) })[r + 1],
					0.6
				)
			end
		end
	end
end

-- Beachfront ----------------------------------------------------------------------------------------------------

local function fillBeachfront(ctx: Ctx, rng: Random, bx: number, bz: number, o: Vector3)
	local side = if bx == MapConfig.BLOCK_MAX then "E" else "S"
	local idx = if side == "E" then bz else bx
	local hotel = idx % 2 == 0
	local role = if hotel then "hotel_beach" else "beach_villa"
	local scale = if hotel then 1.45 else 1.35
	local along = if hotel then -18 else 16
	local _, dims = frontBuilding(ctx, rng, o, role, side, along, scale, 10)
	local sd = SIDES[side]
	local alongX = sd.along.X ~= 0
	-- pool terrace beside the building, palm on the terrace, parking behind
	local pc = sd.normal * 26 + sd.along * (if hotel then 30 else -30)
	pool(ctx, o, pc.X, pc.Z, if alongX then 22 else 14, if alongX then 14 else 22)
	local pp = pc + sd.normal * 16
	palm(ctx.props, at(o, pp.X, pp.Z), rand(rng, 18, 24), rng)
	local back = -sd.normal * 36
	parkingLot(ctx, o, back.X, back.Z, if alongX then 90 else 24, if alongX then 24 else 90, alongX)
	local _ = dims
end

-- Docks ---------------------------------------------------------------------------------------------------------

local CONTAINER_COLORS = { rgb(220, 90, 50), rgb(40, 120, 200), rgb(60, 170, 90), rgb(240, 190, 50), rgb(170, 60, 70) }

-- Procedural container stack (background bulk; same bounds as the kit container): `levels` high, long axis along dir.
local function containerStack(ctx: Ctx, o: Vector3, x: number, z: number, dir: Vector3, levels: number, rng: Random)
	local size = KIT_DIMS.shipping_container
	local base = groundAt(at(o, x, z), dir)
	for k = 0, levels - 1 do
		local col = pick(rng, CONTAINER_COLORS)
		part(ctx.blocks, "ContainerStack", size, base * CFrame.new(0, size.Y * (k + 0.5), 0), col, {
			material = Enum.Material.CorrodedMetal,
		})
		deco(
			ctx.blocks,
			"ContainerStripe",
			Vector3.new(size.X + 0.1, 0.6, size.Z + 0.1),
			base * CFrame.new(0, size.Y * (k + 0.85), 0),
			col:Lerp(C.white, 0.35)
		)
	end
end

-- Gantry crane over a container row (procedural landmark of the docks).
local function gantry(ctx: Ctx, o: Vector3, x0: number, x1: number, z: number)
	local h = 26
	local yellow = rgb(255, 196, 40)
	for _, x in { x0, x1 } do
		for _, dz in { -9, 9 } do
			part(
				ctx.blocks,
				"GantryLeg",
				Vector3.new(1.6, h, 1.6),
				CFrame.new(at(o, x, z + dz) + Vector3.new(0, h / 2, 0)),
				yellow
			)
		end
		part(
			ctx.blocks,
			"GantryTie",
			Vector3.new(1.4, 1.4, 19.6),
			CFrame.new(at(o, x, z) + Vector3.new(0, h - 0.7, 0)),
			yellow
		)
	end
	for _, dz in { -9, 9 } do
		part(
			ctx.blocks,
			"GantryBeam",
			Vector3.new(x1 - x0 + 1.6, 2, 1.6),
			CFrame.new(at(o, (x0 + x1) / 2, z + dz) + Vector3.new(0, h + 1, 0)),
			yellow
		)
	end
	part(
		ctx.blocks,
		"GantryCab",
		Vector3.new(5, 3, 19),
		CFrame.new(at(o, (x0 + x1) / 2 + 6, z) + Vector3.new(0, h + 1, 0)),
		C.dark
	)
end

local function fillDocks(ctx: Ctx, rng: Random, bx: number, _bz: number, o: Vector3)
	local yard = bx == -3 or bx == 0
	flat(ctx, "Concrete", o, 0, 0, 100, 100, rgb(176, 178, 186), 0.08)
	if not yard then
		local along = if bx % 2 == 0 then -12 else 12
		local scale = 1.3
		local _, dims = frontBuilding(ctx, rng, o, "warehouse", "N", along, scale, 3)
		-- loading yard behind (south)
		local yz = 30
		local x0 = -along * 0.4
		shippingContainer(ctx.props, groundAt(at(o, x0 - 18, yz), Vector3.new(1, 0, 0)), pick(rng, CONTAINER_COLORS))
		dumpster(ctx.props, groundAt(at(o, x0 + 6, 44), Vector3.new(0, 0, -1)))
		oilBarrels(ctx.props, groundAt(at(o, x0 + 20, 40), Vector3.new(0, 0, -1)))
		containerStack(ctx, o, x0 - 18, 41, Vector3.new(1, 0, 0), 2, rng)
		local _ = dims
	else
		-- container yard: rows of containers, a crate stack
		for i = 0, 2 do
			local x = -30 + i * 13
			shippingContainer(
				ctx.props,
				groundAt(at(o, x, -26), Vector3.new(0, 0, -1)),
				CONTAINER_COLORS[(bx + i) % #CONTAINER_COLORS + 1]
			)
		end
		crateStack(ctx.props, groundAt(at(o, 30, -32), Vector3.new(0, 0, -1)))
		gantry(ctx, o, -40, 8, -26)
		for i = 0, 3 do
			containerStack(ctx, o, -38 + i * 11, -2, Vector3.new(0, 0, -1), 1 + (i + bx) % 3, rng)
		end
		if bx == -3 then
			waterTower(ctx.props, groundAt(at(o, 24, 22), Vector3.new(0, 0, 1)), 60)
		else
			parkingLot(ctx, o, 0, 26, 90, 36, true)
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
	-- crosswalks at downtown + midtown intersections
	local R = MapConfig.DOWNTOWN_RADIUS + 1
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
-- Blocks: sidewalks, lots, curb cuts, street lamps, hydrants
---------------------------------------------------------------------------------------------------------------

local ZONE_LOT: { [string]: { color: Color3, material: Enum.Material } } = {
	downtown = { color = rgb(170, 168, 186), material = Enum.Material.SmoothPlastic },
	midtown = { color = rgb(200, 190, 172), material = Enum.Material.SmoothPlastic },
	shops = { color = rgb(118, 198, 92), material = Enum.Material.Grass },
	suburbs = { color = rgb(112, 196, 88), material = Enum.Material.Grass },
	beachfront = { color = rgb(138, 208, 100), material = Enum.Material.Grass },
	docks = { color = rgb(150, 152, 162), material = Enum.Material.SmoothPlastic },
}

local function buildBlockBase(ctx: Ctx, bx: number, bz: number, origin: Vector3, district: string, cuts: { Cut })
	local key = blockKey(bx, bz)
	local poi = poiByBlock[key]
	local plot = plotByBlock[key]
	local zone = MapBuilder.zoneOf(bx, bz)
	local hgt = CURB_TOP - GROUND_BOTTOM
	local yc = (CURB_TOP + GROUND_BOTTOM) / 2

	-- lot interior
	local look = ZONE_LOT[zone]
	local lotColor = if plot then C.lot.plot else look.color
	local lotMat = if plot then Enum.Material.SmoothPlastic else look.material
	local reflect: number? = nil
	local lotTop = CURB_TOP
	if poi == "Park" then
		-- terrain grass covers the park (MapBuilder.buildTerrain); the lot sits 1 stud lower underneath it
		lotColor, lotMat = rgb(104, 192, 80), Enum.Material.Grass
		lotTop = CURB_TOP - 1
	elseif poi == "SpawnPlaza" then
		lotColor, lotMat = rgb(240, 226, 198), Enum.Material.SmoothPlastic
	elseif poi == "Dealership" then
		lotColor, lotMat, reflect = rgb(234, 236, 246), Enum.Material.SmoothPlastic, 0.06
	elseif poi == "PoliceHQ" then
		lotColor = rgb(176, 184, 204)
	elseif poi == "ChopShop" then
		lotColor, lotMat = rgb(150, 126, 98), Enum.Material.SmoothPlastic
	elseif poi == "StuntPark" then
		lotColor, lotMat = rgb(84, 90, 116), Enum.Material.SmoothPlastic
	elseif poi == "Pier" then
		lotColor, lotMat = rgb(206, 156, 104), Enum.Material.WoodPlanks
	end
	local lotH = lotTop - GROUND_BOTTOM
	local lot = part(
		ctx.blocks,
		"Lot",
		Vector3.new(LOT_HALF * 2, lotH, LOT_HALF * 2),
		CFrame.new(origin.X, GROUND_BOTTOM + lotH / 2, origin.Z),
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
	lot:SetAttribute("Zone", zone)
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

	if plot or poi == "Pier" or poi == "ChopShop" or poi == "StuntPark" then
		return -- PlotService dresses the garage blocks; the corner POIs light themselves
	end
	-- one street lamp per block (alternating N/S vs W/E sides so every road gets some), avoiding curb cuts; the
	-- outer ring gets one on every other block (the prop budget goes to beach palms there)
	local order = if (bx + bz) % 2 == 0 then { "N", "S", "W", "E" } else { "W", "E", "N", "S" }
	local first = if (bx * 3 + bz) % 2 == 0 then 34 else -34
	local placed = district == "beach" and not poi and (bx + bz) % 2 ~= 0
	for _, sideName in order do
		if placed then
			break
		end
		local side = SIDES[sideName]
		for _, off in { first, -first } do
			local blocked = false
			for _, cut in cuts do
				if cut.side == sideName and off >= cut.a - 6 and off <= cut.b + 6 then
					blocked = true
				end
			end
			if not blocked then
				local g = origin + side.normal * (BLOCK_HALF - 3) + side.along * off
				streetLight(ctx, Vector3.new(g.X, CURB_TOP, g.Z), side.normal)
				placed = true
				break
			end
		end
	end
	-- hydrant on the sidewalk of some blocks
	if (bx * 3 + bz * 5) % 14 == 0 then
		local sideName = if bz % 2 == 0 then "S" else "N"
		local side = SIDES[sideName]
		local g = origin + side.normal * (BLOCK_HALF - 2.5) + side.along * (if bx % 2 == 0 then 18 else -18)
		hydrant(ctx.props, Vector3.new(g.X, CURB_TOP, g.Z))
	end
end

-- Traffic lights: one per downtown intersection (checkerboard), on a sidewalk corner, arm over one road.
local function buildTrafficLights(ctx: Ctx)
	local R = MapConfig.DOWNTOWN_RADIUS
	for i = -R, R do
		for j = -R, R do
			if (i + j) % 2 == 0 then
				local corner = Vector3.new(i * S + HALF_ROAD + 4.6, CURB_TOP, j * S + HALF_ROAD + 4.6)
				local dir = if (i - j) % 4 == 0 then Vector3.new(-1, 0, 0) else Vector3.new(0, 0, -1)
				trafficLight(ctx, corner, dir)
			end
		end
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

-- Free-standing sign on two posts (survives dressing: monument signs in front of POI art).
local function postSign(
	parent: Instance,
	name: string,
	text: string,
	ground: Vector3,
	dir: Vector3,
	w: number,
	hgt: number,
	bottom: number,
	bg: Color3,
	fg: Color3,
	glow: Color3?
)
	local center = ground + Vector3.new(0, bottom + hgt / 2, 0)
	local cf = facing(center, dir)
	local board = sign(parent, name, text, Vector3.new(w, hgt, 1.2), cf, bg, fg, { glow = glow, back = true })
	board.CanCollide = true
	board.CanQuery = true
	for _, sx in { -w * 0.32, w * 0.32 } do
		local p = (cf * CFrame.new(sx, 0, 0.9)).Position
		part(parent, name .. "Post", Vector3.new(1, bottom, 1), CFrame.new(p.X, ground.Y + bottom / 2, p.Z), C.metal)
	end
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

	-- fountain centerpiece (west of the spawn, so the spawn looks east at the Dealership) + benches around it
	local fo = Vector3.new(o.X - 30, o.Y, o.Z)
	fountainProp(f, CFrame.new(fo), 30)
	cyl(f, "FountainGlow", 0.2, 32, L(fo, 0, 0.1, 0), C.cyan, {
		material = Enum.Material.Neon,
		collide = false,
		shadow = false,
	})
	for _, d in { Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) } do
		local p = fo + d * 21
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

	-- the big logo sign behind the fountain (Images.logo_hotwire_city on both faces; text fallback underneath)
	local signPos = Vector3.new(o.X - 47, o.Y + 30, o.Z)
	local logoCf = facing(signPos, Vector3.new(1, 0, 0))
	local logo = part(f, "WelcomeSign", Vector3.new(34, 19, 1.4), logoCf, rgb(18, 18, 36))
	addImage(logo, Enum.NormalId.Front, Assets.Images.logo_hotwire_city, 900)
	addImage(logo, Enum.NormalId.Back, Assets.Images.logo_hotwire_city, 900)
	logo:SetAttribute("Image", Assets.Images.logo_hotwire_city)
	neon(f, "WelcomeSignGlow", Vector3.new(35.6, 20.6, 0.6), logoCf * CFrame.new(0, 0, 0.2), C.pink)
	for _, sz in { -12, 12 } do
		part(f, "SignPost", Vector3.new(1.4, 20.5, 1.4), L(o, -47, 10.25, sz), C.metal)
	end

	-- corner planters (grass beds, see buildTerrain) with palms
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local p = Vector3.new(o.X + sx * 42, o.Y, o.Z + sz * 42)
			part(f, "Planter", Vector3.new(9, 2, 9), CFrame.new(p + Vector3.new(0, 1, 0)), rgb(214, 170, 130))
			palm(ctx.props, p + Vector3.new(0, 2, 0), rand(rng, 19, 24), rng)
		end
	end
	-- snacks + street furniture
	hotdogStand(f, facing(Vector3.new(o.X - 6, o.Y, o.Z - 40), Vector3.new(0, 0, 1)))
	trashCan(f, CFrame.new(o.X + 6, o.Y, o.Z - 44))
	trashCan(f, CFrame.new(o.X - 20, o.Y, o.Z + 44))
	flowerBed(f, facing(Vector3.new(o.X + 14, o.Y, o.Z + 44), Vector3.new(0, 0, -1)), 10, C.pink)
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

local function buildPoliceHQ(ctx: Ctx, f: Folder, o: Vector3)
	-- HQ east of center, entrance facing west (busted release spot at x = -50 stays open ground)
	local rng = Random.new(MapBuilder.SEED + 19)
	local front = Vector3.new(-1, 0, 0)
	local scale = 1.6
	local dims = KIT_DIMS.police_hq * scale
	local bc = Vector3.new(o.X + 33 - dims.Z / 2, o.Y, o.Z)
	buildingSlot(f, rng, "police_hq", CFrame.lookAt(bc, bc + front), scale)
	-- monument signs (stay when the HQ art loads): west plaza + north road
	postSign(
		f,
		"PoliceSign",
		"POLICE",
		Vector3.new(o.X - 34, o.Y, o.Z - 30),
		front,
		22,
		6,
		4,
		C.police,
		C.white,
		C.white
	)
	postSign(
		f,
		"PoliceSignNorth",
		"POLICE",
		Vector3.new(o.X + 26, o.Y, o.Z - 46),
		Vector3.new(0, 0, -1),
		22,
		6,
		4,
		C.police,
		C.white,
		C.white
	)
	-- flag pole in front
	part(f, "FlagPole", Vector3.new(0.6, 24, 0.6), L(o, -40, 12, 22), C.white)
	deco(f, "Flag", Vector3.new(0.2, 4, 7), L(o, -40, 21.5, 25.6), C.police)
	-- parked-cruiser bays beside the HQ
	parkingLot(ctx, o, -30, 42, 36, 14, true)
end

local function buildGearShop(ctx: Ctx, f: Folder, o: Vector3)
	local rng = Random.new(MapBuilder.SEED + 23)
	-- the gear_shop art sits behind the counter (front at z = +24); its placeholder is the open storefront
	local gearScale = 30 / KIT_DIMS.gear_shop.Y
	local gearDims = KIT_DIMS.gear_shop * gearScale
	local gearPos = Vector3.new(o.X, o.Y, o.Z + 24 - gearDims.Z / 2)
	local shop = newSlot(
		f,
		"GearShopArt",
		"Buildings",
		"gear_shop",
		CFrame.lookAt(gearPos, gearPos + Vector3.new(0, 0, 1)),
		fitFor("Buildings", "gear_shop", gearScale)
	)
	shop:SetAttribute("Footprint", gearDims)
	-- storefront open to the south; the counter sits at MapLayout.gearShopCounter()
	local wallColor = rgb(255, 196, 64)
	part(shop, "ShopBackWall", Vector3.new(52, 18, 2), L(o, 0, 9, 9), wallColor)
	part(shop, "ShopSideWall", Vector3.new(2, 18, 36), L(o, -25, 9, 26), wallColor)
	part(shop, "ShopSideWall", Vector3.new(2, 18, 36), L(o, 25, 9, 26), wallColor)
	part(shop, "ShopRoof", Vector3.new(54, 1.6, 38), L(o, 0, 18.8, 26), rgb(40, 44, 70))
	part(shop, "ShopHeader", Vector3.new(52, 5, 2), L(o, 0, 15.5, 43), wallColor)
	for _, x in { -24.75, 24.75 } do
		part(shop, "ShopPillar", Vector3.new(2.5, 13, 2.5), L(o, x, 6.5, 43), rgb(40, 44, 70))
	end
	part(shop, "ShopFloor", Vector3.new(48, 0.2, 33), L(o, 0, 0.1, 26.5), rgb(56, 58, 96), { shadow = false })
	wedge(shop, "ShopAwning", Vector3.new(48, 2, 5), L(o, 0, 13.8, 46.5) * CFrame.Angles(0, math.pi, 0), C.pink, false)
	-- wall of gear behind the counter
	for _, x in { -14, 14 } do
		part(shop, "Shelf", Vector3.new(12, 10, 2.5), L(o, x, 5, 11.5), rgb(70, 50, 40))
	end
	deco(shop, "BigBat", Vector3.new(1.4, 1.4, 11), L(o, 0, 9, 10.4) * CFrame.Angles(math.rad(-50), 0, 0), C.wood)
	neon(shop, "ZapperBolt", Vector3.new(1.2, 6, 0.3), L(o, -6, 12, 10.2) * CFrame.Angles(0, 0, math.rad(25)), C.yellow)
	neon(
		shop,
		"ZapperBolt",
		Vector3.new(1.2, 6, 0.3),
		L(o, -4.4, 8.5, 10.2) * CFrame.Angles(0, 0, math.rad(-25)),
		C.yellow
	)
	deco(shop, "SpikeDisplay", Vector3.new(8, 1, 0.6), L(o, 6, 13, 10.3), C.red)
	local lamp = neon(shop, "ShopLight", Vector3.new(30, 0.3, 4), L(o, 0, 17.8, 26), rgb(255, 250, 235))
	local light = Instance.new("PointLight")
	light.Range = 36
	light.Brightness = 1.3
	light.Shadows = false
	light.Parent = lamp

	-- the counter (ShopService finds it by tag) stays put in front of the art
	local counterCf = MapLayout.gearShopCounter()
	local counter =
		part(f, "GearShopCounter", Vector3.new(16, 3.6, 3), counterCf * CFrame.new(0, 1.8, 0), rgb(110, 70, 200))
	tag(counter, "GearShopCounter")
	neon(f, "CounterTrim", Vector3.new(16.2, 0.4, 0.2), counterCf * CFrame.new(0, 3.2, -1.55), C.cyan)
	part(f, "CounterTop", Vector3.new(16.6, 0.4, 3.6), counterCf * CFrame.new(0, 3.8, 0), C.white)

	-- the sign stands on its own posts (it outlives the storefront placeholder)
	local signCf = facing(Vector3.new(o.X, o.Y + 22.6, o.Z + 44.6), Vector3.new(0, 0, 1))
	sign(f, "GearShopSign", "GEAR SHOP", Vector3.new(40, 6, 1.2), signCf, rgb(24, 26, 50), C.yellow, {
		glow = C.cyan,
	})
	for _, sx in { -15, 15 } do
		part(f, "GearSignPost", Vector3.new(1, 19.6, 1), L(o, sx, 9.8, 45.6), C.metal)
	end

	-- downtown tower on the north half
	local scale = fitScale("skyscraper_neon", 46, 38, 0.85)
	local _, dims, origin = frontBuilding(ctx, rng, o, "skyscraper_neon", "N", 0, scale, 1)
	towerAccents(ctx, origin, dims.X, dims.Z, dims.Y, C.yellow)
end

local function buildSprayShop(
	ctx: Ctx,
	f: Folder,
	o: Vector3,
	zoneCf: CFrame,
	zoneSize: Vector3,
	color: Color3,
	accent: Color3,
	rng: Random,
	backRole: string
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
	-- the spray_booth art (paint store) beside the booth, a palm + bench on the other side
	local sScale = 1.1
	local sDims = KIT_DIMS.spray_booth * sScale
	local sp = Vector3.new(o.X + 34, o.Y, o.Z - BUILD_HALF + 1 + sDims.Z / 2)
	buildingSlot(f, rng, "spray_booth", CFrame.lookAt(sp, sp + Vector3.new(0, 0, -1)), sScale)
	palm(ctx.props, Vector3.new(o.X - 34, o.Y, o.Z - 40), 20, rng)
	bench(ctx.props, facing(Vector3.new(o.X - 34, o.Y, o.Z - 29), Vector3.new(0, 0, -1)))
	-- the rest of the block: one Midtown building facing the south street
	local scale = fitScale(backRole, 70, 60, MID_MAX[backRole] or 1.2)
	frontBuilding(ctx, rng, o, backRole, "S", 0, scale, 1)
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
	-- the chop_shop art (rusty barn) behind the drive-in, facing it
	local cScale = 0.72
	local cDims = KIT_DIMS.chop_shop * cScale
	local cp = Vector3.new(o.X - 4, o.Y, back - 5 - cDims.Z / 2)
	buildingSlot(f, rng, "chop_shop", CFrame.lookAt(cp, cp + Vector3.new(0, 0, 1)), cScale)
	-- junkyard: fence, crushed cars, tires, crane, containers, barrels, the car crusher
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
	for _, stack in { { -36, -44 }, { -10, -44 }, { 36, -40 } } do
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
	for _, t in { { -36, 26 }, { -40, 33 } } do
		for k = 0, 1 do
			cyl(f, "Tire", 1.2, 3.4, L(o, t[1], 0.6 + k * 1.2, t[2]), rgb(28, 28, 32))
		end
	end
	local crane = rgb(255, 196, 40)
	part(f, "CraneMast", Vector3.new(2.5, 32, 2.5), L(o, 36, 16, -8), crane)
	part(f, "CraneBoom", Vector3.new(2, 2, 34), L(o, 36, 32, -22), crane)
	deco(f, "CraneCable", Vector3.new(0.3, 12, 0.3), L(o, 36, 25, -36), C.dark)
	cyl(f, "CraneMagnet", 1.2, 6, L(o, 36, 18.4, -36), C.dark)
	shippingContainer(f, groundAt(Vector3.new(o.X - 44, 0, o.Z - 24), Vector3.new(0, 0, 1)), rgb(220, 90, 50))
	shippingContainer(f, groundAt(Vector3.new(o.X - 44, 0, o.Z - 1), Vector3.new(0, 0, 1)), rgb(40, 120, 200))
	carCrusher(f, groundAt(Vector3.new(o.X + 37, 0, o.Z + 22), Vector3.new(-1, 0, 0)))
	oilBarrels(f, groundAt(Vector3.new(o.X - 42, 0, o.Z + 42), Vector3.new(0, 0, -1)))
	crateStack(f, groundAt(Vector3.new(o.X + 43, 0, o.Z + 44), Vector3.new(0, 0, -1)))
	dumpster(f, groundAt(Vector3.new(o.X - 28, 0, o.Z + 45), Vector3.new(0, 0, -1)))
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
	-- cones around the pool, barriers along the east run-off
	for _, c in { { -24, -45 }, { -24, -15 }, { -10, -45 }, { -10, -15 } } do
		trafficCone(f, CFrame.new(o.X + c[1], o.Y, o.Z + c[2]))
	end
	for _, z in { -30, -20, -10, 0 } do
		roadBarrier(f, groundAt(Vector3.new(o.X + 47, 0, o.Z + z), Vector3.new(-1, 0, 0)))
	end
end

local function buildPark(_ctx: Ctx, f: Folder, o: Vector3)
	local rng = Random.new(MapBuilder.SEED + 41)
	-- pond (the lawn itself is Terrain grass, see buildTerrain)
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
	-- fountain plaza on the main path
	cyl(f, "FountainPlaza", 0.2, 30, L(o, 8, 0.12, -30), rgb(236, 222, 196), { shadow = false })
	fountainProp(f, CFrame.new(o.X + 8, o.Y, o.Z - 30), 22)
	-- trees
	for _, t in
		{
			{ -46, -46 },
			{ -22, -45 },
			{ -46, -12 },
			{ 46, -20 },
			{ -46, 18 },
			{ 46, 18 },
			{ -30, 46 },
			{ 8, 46 },
		}
	do
		roundTree(f, Vector3.new(o.X + t[1], o.Y, o.Z + t[2]), rand(rng, 16, 24), rng)
	end
	-- benches along the paths
	for _, b in { { -10, -26.5, 1 }, { -31.5, 8, 0 }, { -31.5, -46, 0 } } do
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
	-- flower beds, rocks by the ponds, bushes
	for i, fb in { { -8, -40 }, { 24, -20 }, { -42, -24 }, { -42, 30 } } do
		flowerBed(
			f,
			facing(Vector3.new(o.X + fb[1], o.Y, o.Z + fb[2]), Vector3.new(0, 0, -1)),
			9,
			({ C.red, C.yellow, C.pink, C.purple })[i]
		)
	end
	for _, r in { { 35, 2 }, { 10, 32 }, { -26, 31 } } do
		rock(f, Vector3.new(o.X + r[1], o.Y, o.Z + r[2]), rand(rng, 4.5, 7), rng)
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
	-- bus stop on the east edge (faces the road)
	busStop(f, facing(Vector3.new(o.X + LOT_HALF - 4.6, o.Y, o.Z - 1), Vector3.new(1, 0, 0)))
end

local function buildFerrisWheel(f: Instance, hub: Vector3, axle: Vector3)
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
	-- ferris wheel landmark facing downtown (slot: the kit ferris_wheel, 80 studs tall)
	local toCenter = Vector3.new(-o.X, 0, -o.Z)
	local axle = if toCenter.Magnitude > 1 then toCenter.Unit else Vector3.new(0, 0, 1)
	local hub = Vector3.new(o.X + 6, o.Y + 38, o.Z + 6)
	local wheelSlot = propSlot(f, "FerrisWheelArt", "ferris_wheel", groundAt(hub, axle), 80)
	buildFerrisWheel(wheelSlot, hub, axle)
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
	hotdogStand(f, facing(Vector3.new(o.X - 26, o.Y, o.Z + 26), Vector3.new(0, 0, -1)))
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
	-- lighthouse on the pier end, facing back at the city
	local lhScale = 0.72
	local lhPos = Vector3.new(x, deckTop, zEnd - outward * 12)
	buildingSlot(f, rng, "lighthouse", CFrame.lookAt(lhPos, lhPos - Vector3.new(0, 0, outward)), lhScale)
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

	-- beach dressing: palms along the sand, umbrellas + chairs, lifeguard towers, surf shacks with board racks
	local pierBlock = MapConfig.Blocks.Pier
	local pierX = (pierBlock.x + 0.5) * S
	local pierSideZ = if pierBlock.z < 0 then -1 else 1
	local SIDE_V = {
		N = Vector3.new(0, 0, -1),
		S = Vector3.new(0, 0, 1),
		W = Vector3.new(-1, 0, 0),
		E = Vector3.new(1, 0, 0),
	}
	local function beachPoint(side: string, a: number, dist: number): (Vector3, Vector3)
		local n = SIDE_V[side]
		local along = if n.X == 0 then Vector3.new(a, 0, 0) else Vector3.new(0, 0, a)
		local p = n * dist + along
		return Vector3.new(p.X, SAND_TOP, p.Z), n
	end
	local function nearPier(p: Vector3, margin: number): boolean
		return p.Z * pierSideZ > EXT and math.abs(p.X - pierX) < margin
	end
	-- beach furniture spots (side, along); palms keep clear of them
	type Spot = { side: string, a: number }
	local SHACKS: { Spot } = { { side = "S", a = -260 }, { side = "E", a = 300 } }
	local TOWERS: { Spot } =
		{ { side = "N", a = -300 }, { side = "S", a = 240 }, { side = "E", a = -260 }, { side = "W", a = 240 } }
	local UMBRELLAS: { Spot } = {
		{ side = "S", a = -380 },
		{ side = "S", a = 60 },
		{ side = "S", a = 420 },
		{ side = "E", a = -330 },
		{ side = "E", a = 90 },
		{ side = "E", a = 560 },
	}
	local COURTS: { Spot } =
		{ { side = "S", a = -120 }, { side = "E", a = -110 }, { side = "W", a = -100 }, { side = "N", a = 120 } }
	local function reserved(side: string, a: number): boolean
		for _, list in { SHACKS, TOWERS, UMBRELLAS, COURTS, { { side = "W", a = -420 } } } do
			for _, r in list do
				if r.side == side and math.abs(r.a - a) < 34 then
					return true
				end
			end
		end
		return false
	end
	for _, side in { "N", "S", "W", "E" } do
		for _, a0 in { -720, -480, -240, 0, 240, 480, 720 } do
			local a = a0 + rand(rng, -30, 30)
			if reserved(side, a) then
				a = a0 + (if a > a0 then -36 else 36)
			end
			local p = beachPoint(side, a, PROMENADE_OUT + 14)
			if not nearPier(p, 44) and not reserved(side, a) then
				palm(ctx.props, p, rand(rng, 20, 28), rng)
			end
		end
	end
	local umbrellaColors = { C.pink, C.cyan, C.yellow, C.orange, C.lime, C.purple }
	for k, s in UMBRELLAS do
		local g, n = beachPoint(s.side, s.a, PROMENADE_OUT + 32)
		beachUmbrella(ctx.props, g, umbrellaColors[k % #umbrellaColors + 1], rng)
		local along = Vector3.new(n.Z, 0, -n.X)
		local cp = g + along * 6 - n * 1
		beachChair(ctx.props, CFrame.lookAt(cp, cp + n), pick(rng, umbrellaColors))
		deco(
			f,
			"Towel",
			Vector3.new(3, 0.1, 6),
			CFrame.lookAt(g - along * 5, g - along * 5 + n) * CFrame.new(0, 0.05, 0),
			pick(rng, umbrellaColors)
		)
	end
	for _, s in TOWERS do
		local g, n = beachPoint(s.side, s.a, PROMENADE_OUT + 36)
		lifeguardTower(ctx.props, CFrame.lookAt(g, g + n))
	end
	for _, s in SHACKS do
		local g, n = beachPoint(s.side, s.a, PROMENADE_OUT + 24)
		buildingSlot(f, rng, "surf_shack", CFrame.lookAt(g, g - n), 1.1)
		local along = Vector3.new(n.Z, 0, -n.X)
		local rp = g + along * 16
		surfboardRack(ctx.props, CFrame.lookAt(rp, rp - n), rng)
	end
	-- beach volleyball courts (lines, posts, net) and a sandcastle on the sunny sides
	for _, s in COURTS do
		local g, n = beachPoint(s.side, s.a, PROMENADE_OUT + 30)
		local court = CFrame.lookAt(g, g + n)
		for _, l in { { 0, -5, 18, 0.5 }, { 0, 5, 18, 0.5 }, { -9, 0, 0.5, 10 }, { 9, 0, 0.5, 10 } } do
			deco(f, "CourtLine", Vector3.new(l[3], 0.1, l[4]), court * CFrame.new(l[1], 0.05, l[2]), C.white)
		end
		for _, z in { -6, 6 } do
			deco(f, "NetPost", Vector3.new(0.4, 8, 0.4), court * CFrame.new(0, 4, z), C.white)
		end
		deco(f, "Net", Vector3.new(0.15, 2.4, 12), court * CFrame.new(0, 6.4, 0), rgb(240, 240, 250))
	end
	for _, s in { { side = "S", a = 180 }, { side = "E", a = 200 } } do
		local g = beachPoint(s.side, s.a, PROMENADE_OUT + 44)
		cyl(f, "Sandcastle", 2, 9, CFrame.new(g + Vector3.new(0, 1, 0)), C.sandDeep, { collide = false })
		for k = 0, 3 do
			local a = k * math.pi / 2
			cyl(
				f,
				"SandTower",
				3.2,
				2.2,
				CFrame.new(g + Vector3.new(math.cos(a) * 3.4, 3.6, math.sin(a) * 3.4)),
				C.sand,
				{ collide = false }
			)
		end
		ball(f, "SandDome", 4, g + Vector3.new(0, 3, 0), C.sand, { collide = false })
	end
	local rg = beachPoint("W", -420, PROMENADE_OUT + 26)
	surfboardRack(ctx.props, CFrame.lookAt(rg, rg + Vector3.new(1, 0, 0)), rng)
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
	-- not an AssetSlot: the signature tower stays procedural (no kit mesh matches it)
	local m = Instance.new("Model")
	m.Name = "Landmark"
	m.WorldPivot = origin
	m.Parent = f
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
					local isA = poi == "SprayShopA"
					local zone = if isA then zones[1] else zones[2]
					buildSprayShop(
						ctx,
						f,
						origin,
						zone.cframe,
						zone.size,
						if isA then rgb(60, 200, 210) else rgb(150, 100, 240),
						if isA then C.pink else C.yellow,
						rng,
						if isA then "apartment_balcony" else "office_block"
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
				end
			else
				local zone = MapBuilder.zoneOf(bx, bz)
				if zone == "downtown" then
					fillDowntown(ctx, rng, bx, bz, origin)
				elseif zone == "midtown" then
					fillMidtown(ctx, rng, bx, bz, origin)
				elseif zone == "shops" then
					fillShops(ctx, rng, bx, bz, origin)
				elseif zone == "suburbs" then
					fillSuburbs(ctx, rng, bx, bz, origin)
				elseif zone == "beachfront" then
					fillBeachfront(ctx, rng, bx, bz, origin)
				elseif zone == "docks" then
					fillDocks(ctx, rng, bx, bz, origin)
				end
			end
		end
	end
	buildTrafficLights(ctx)
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
		adIndex = 0,
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

-- Every AssetSlot Model under root (deterministic order).
function MapBuilder.slots(root: Instance): { Model }
	local out = {}
	for _, d in root:GetDescendants() do
		if d:IsA("Model") and d:HasTag(MapBuilder.TAG_SLOT) then
			table.insert(out, d)
		end
	end
	return out
end

-- Live-engine terrain: ocean water + seabed around the island (FillBlock in tiles to keep each call small), grass
-- beds (the Park lawn and the Spawn Plaza planters) and a soft cloud layer. Harness: recorded as no-ops.
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
	-- Park lawn: the lot part sits 1 stud low; the grass fills the lower voxel layer and just tops it (surface lands
	-- a little under the sidewalk, the pond / paths / plaza parts sit on it)
	local park = MapLayout.poiCenter("Park")
	terrain:FillBlock(
		CFrame.new(park.X, (CURB_TOP + 0.2 - 4) / 2, park.Z),
		Vector3.new(LOT_HALF * 2, CURB_TOP + 0.2 + 4, LOT_HALF * 2),
		Enum.Material.Grass
	)
	-- Spawn Plaza planter beds
	local plaza = MapLayout.poiCenter("SpawnPlaza")
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			terrain:FillBlock(
				CFrame.new(plaza.X + sx * 42, CURB_TOP + 2.2, plaza.Z + sz * 42),
				Vector3.new(8, 1.2, 8),
				Enum.Material.Grass
			)
		end
	end
	-- soft cartoon clouds
	local clouds = terrain:FindFirstChildOfClass("Clouds") or Instance.new("Clouds")
	clouds.Cover = 0.45
	clouds.Density = 0.6
	clouds.Color = rgb(252, 252, 255)
	clouds.Parent = terrain
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
