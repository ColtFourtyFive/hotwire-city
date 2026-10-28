--!strict
-- World/Places: POIs, garage plots, open lots, paths, helipads, stunt ramps and level crossings (MapBuilder v2).
--
-- Every POI is a Model in Map/POIs named after its id (attributes Kind, Name; ModelStreamingMode Atomic) built in
-- the POI's own frame: origin = footprint centre at street level, local -Z = the street side, front edge at
-- z = -size.Z / 2. The footprint is the data's (`size`), the structure a placeholder (A3 / art passes replace the
-- massing), but every interaction part a system needs is real and where the shim says it is:
--
--   gunshop      walk-in store; "GunStoreCounter" (weapons) + "GearShopCounter" (gear) counters 12 in from the front
--   spray/customs/chop   a drive-in bay open to the street: box (0, 13, -D/2 + 30), size (W - 20, 26, 50)
--   dealership   showroom at the back, 8 "DealerPad" discs on the front lot (MapLayout.dealerPads)
--   plaza        Hotwire Plaza: 2 "LeaderboardBoard" boards, fountain; the SpawnLocation out on its sidewalk
--   police / hospital / bank / ...   massing + entrance canopy + branded sign
--
-- Plots: a level garage pad (140 x 150 at the plot frame) with a driveway apron; PlotService builds the garage on it
-- in the v1 plot-local layout (Config/Map.Garage). Open parcels (park, plaza, parking_lot, yard, container_yard) get
-- their ground cover here; A3's BuildingService builds every other parcel.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local WorldGen = require(Shared.Util.WorldGen)
local Assets = require(Shared.Config.Assets)
local MapLayout = require(Shared.Util.MapLayout)
local WorldQuery = require(Shared.Util.WorldQuery)
local WorldTerrain = require(Shared.Util.WorldTerrain)
local Kit = require(script.Parent.Kit)
local Roads = require(script.Parent.Roads)

type Ctx = Kit.Ctx
type POI = WorldLayout.POI

local Places = {}

local CURB = WorldLayout.Scale.CURB_HEIGHT
local LOT_T = 3

-- The interaction geometry is the shim's (Util/MapLayout), so the systems and the map agree by construction.
Places.BAY_DEPTH = MapLayout.BAY_DEPTH
Places.BAY_FRONT = MapLayout.BAY_FRONT
Places.bayBox = MapLayout.bayBox
Places.counterFrames = MapLayout.counterFrames
Places.dealerPads = MapLayout.dealerPadsOf

-------------------------------------------------------------------------------------------------------------------------
-- helpers
-------------------------------------------------------------------------------------------------------------------------

local function model(ctx: Ctx, folder: string, name: string, pivot: CFrame): Model
	local m = Instance.new("Model")
	m.Name = name
	pcall(function()
		(m :: any).ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	end)
	m.WorldPivot = pivot
	m.Parent = Kit.folder(ctx, folder)
	return m
end

-- Box at local (x, y, z) centre in frame F.
local function box(
	ctx: Ctx,
	parent: Instance,
	cat: string,
	F: CFrame,
	x: number,
	y: number,
	z: number,
	sx: number,
	sy: number,
	sz: number,
	style: Kit.Style,
	opts: Kit.PartOpts?
): Part
	local o: Kit.PartOpts = if opts then table.clone(opts) else {}
	o.parent = parent
	return Kit.part(ctx, cat, Vector3.new(sx, sy, sz), F * CFrame.new(x, y, z), style, o)
end

local function textSign(part: BasePart, face: Enum.NormalId, text: string, fg: Color3, bg: Color3?, font: Enum.Font?)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "SignGui_" .. face.Name
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	gui.LightInfluence = 0.6
	gui.MaxDistance = 900
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = if bg then 0 else 1
	if bg then
		label.BackgroundColor3 = bg
	end
	label.Text = text
	label.TextColor3 = fg
	label.TextScaled = true
	label.Font = font or Enum.Font.GothamBlack
	label.Parent = gui
	gui.Parent = part
end

local BRAND_COLORS: { [string]: { Color3 } } = {
	gunshop = { Color3.fromRGB(28, 28, 30), Color3.fromRGB(236, 196, 64) },
	spray = { Color3.fromRGB(30, 150, 210), Color3.fromRGB(255, 255, 255) },
	customs = { Color3.fromRGB(20, 20, 24), Color3.fromRGB(255, 70, 60) },
	chop = { Color3.fromRGB(96, 70, 44), Color3.fromRGB(255, 210, 120) },
	dealership = { Color3.fromRGB(16, 20, 40), Color3.fromRGB(80, 220, 255) },
	police = { Color3.fromRGB(18, 32, 70), Color3.fromRGB(255, 255, 255) },
	hospital = { Color3.fromRGB(240, 240, 240), Color3.fromRGB(200, 30, 40) },
	bank = { Color3.fromRGB(28, 60, 40), Color3.fromRGB(240, 210, 120) },
	bank_branch = { Color3.fromRGB(28, 60, 40), Color3.fromRGB(240, 210, 120) },
	convenience = { Color3.fromRGB(200, 40, 40), Color3.fromRGB(255, 255, 255) },
	gas = { Color3.fromRGB(240, 120, 20), Color3.fromRGB(255, 255, 255) },
	jewelry = { Color3.fromRGB(30, 24, 40), Color3.fromRGB(240, 200, 255) },
	default = { Color3.fromRGB(32, 34, 40), Color3.fromRGB(240, 240, 236) },
}

local function brandOf(poi: POI): { Color3 }
	return BRAND_COLORS[poi.kind] or BRAND_COLORS.default
end

-- Fascia sign across the front facade (local x centre, height y, front face at z).
local function fascia(ctx: Ctx, m: Model, F: CFrame, poi: POI, w: number, y: number, z: number, h: number?)
	local col = brandOf(poi)
	local sh = h or 5
	local p = box(ctx, m, "Sign", F, 0, y, z - 0.4, math.min(w, 60), sh, 0.8, Kit.style("paint_black"), {
		collide = false,
		query = false,
	})
	p.Color = col[1]
	textSign(p, Enum.NormalId.Front, string.upper(poi.brand or poi.name), col[2], col[1])
	Kit.nightGlow(p, col[1]:Lerp(Color3.new(1, 1, 1), 0.25))
	return p
end

-- Pylon sign at the front corner of the lot.
local function pylon(ctx: Ctx, m: Model, F: CFrame, poi: POI, x: number, z: number, h: number)
	local col = brandOf(poi)
	box(ctx, m, "SignPole", F, x, CURB + h / 2, z, 1.6, h, 1.6, Kit.style("metal_grey"))
	local board = box(ctx, m, "SignBoard", F, x, CURB + h + 5, z, 16, 10, 1.4, Kit.style("paint_black"), {
		collide = false,
	})
	board.Color = col[1]
	textSign(board, Enum.NormalId.Front, string.upper(poi.brand or poi.name), col[2], col[1])
	textSign(board, Enum.NormalId.Back, string.upper(poi.brand or poi.name), col[2], col[1])
	Kit.nightGlow(board, col[1]:Lerp(Color3.new(1, 1, 1), 0.3))
end

-- The lot slab under a footprint (top at curb height).
local function lotSlab(ctx: Ctx, m: Model, F: CFrame, W: number, D: number, style: Kit.Style)
	box(ctx, m, "Lot", F, 0, CURB - LOT_T / 2, 0, W, LOT_T, D, style)
end

-- Solid building box with a roof parapet band, resting on the lot.
local function massing(
	ctx: Ctx,
	m: Model,
	F: CFrame,
	x: number,
	z: number,
	w: number,
	h: number,
	d: number,
	style: Kit.Style
): Part
	local b = box(ctx, m, "Building", F, x, CURB + h / 2, z, w, h, d, style)
	box(ctx, m, "Roof", F, x, CURB + h + 0.6, z, w - 2, 1.2, d - 2, Kit.style("gravel"), { shadow = false })
	return b
end

-- Glass storefront band on the front of a building (local front face at z).
local function storefront(ctx: Ctx, m: Model, F: CFrame, x: number, z: number, w: number, h: number)
	local g = box(ctx, m, "Storefront", F, x, CURB + h / 2 + 0.5, z - 0.3, w - 4, h, 0.6, Kit.style("glass"), {
		collide = false,
		shadow = false,
	})
	Kit.nightGlow(g, Color3.fromRGB(255, 226, 180))
end

-------------------------------------------------------------------------------------------------------------------------
-- POI kinds
-------------------------------------------------------------------------------------------------------------------------

local function bayBuilding(ctx: Ctx, m: Model, F: CFrame, poi: POI, wallStyle: Kit.Style)
	local W, D, H = poi.size.X, poi.size.Z, math.max(poi.size.Y, 28)
	local bayW = W - 20
	local z0 = -D / 2 + Places.BAY_FRONT
	local z1 = z0 + Places.BAY_DEPTH
	-- bay: side walls outside the drive box, roof above 26, back wall
	for _, sx in { -1, 1 } do
		box(ctx, m, "BayWall", F, sx * (bayW / 2 + 2.5), CURB + H / 2, (z0 + z1) / 2, 5, H, z1 - z0, wallStyle)
	end
	box(ctx, m, "BayRoof", F, 0, CURB + 27.5 + 1, (z0 + z1) / 2, W - 10 + 4, 2, z1 - z0 + 2, Kit.style("corrugated"))
	-- the rest of the building behind the bay
	local backD = D / 2 - z1 - 4
	if backD > 8 then
		massing(ctx, m, F, 0, z1 + backD / 2, W - 10, H, backD, wallStyle)
	end
	fascia(ctx, m, F, poi, bayW, CURB + 26, z0 - 0.6, 3.6)
end

local function gunshop(ctx: Ctx, m: Model, F: CFrame, poi: POI)
	local W, D, H = poi.size.X, poi.size.Z, math.max(poi.size.Y, 18)
	local w, d = W - 8, D - 10
	local z0 = -D / 2 + 2
	local zc = z0 + d / 2
	local wall = Kit.style("stucco")
	local T = 1.5
	-- walk-in shell: back + side walls, front wall with a door gap, roof
	box(ctx, m, "Wall", F, 0, CURB + H / 2, z0 + d - T / 2, w, H, T, wall)
	for _, sx in { -1, 1 } do
		box(ctx, m, "Wall", F, sx * (w / 2 - T / 2), CURB + H / 2, zc, T, H, d, wall)
	end
	local door = 10
	local side = (w - door) / 2
	for _, sx in { -1, 1 } do
		box(ctx, m, "Wall", F, sx * (door / 2 + side / 2), CURB + H / 2, z0 + T / 2, side, H, T, wall)
		storefront(ctx, m, F, sx * (door / 2 + side / 2), z0 - 0.2, side, 7)
	end
	box(ctx, m, "Wall", F, 0, CURB + 10 + (H - 10) / 2, z0 + T / 2, door, H - 10, T, wall)
	box(ctx, m, "Roof", F, 0, CURB + H + 0.6, zc, w, 1.2, d, Kit.style("gravel"))
	box(ctx, m, "Floor", F, 0, CURB + 0.1, zc, w - 2 * T, 0.2, d - 2 * T, Kit.style("concrete_modern"), {
		shadow = false,
	})
	-- counters 12 in from the lot front, facing the door
	local gunCf, gearCf = Places.counterFrames(poi)
	local gun = Kit.part(
		ctx,
		"GunStoreCounter",
		Vector3.new(14, 3.6, 3),
		gunCf * CFrame.new(0, 1.8, 0),
		Kit.style("metal_dark"),
		{
			parent = m,
		}
	)
	CollectionService:AddTag(gun, "GunStoreCounter")
	local gear =
		Kit.part(ctx, "GearShopCounter", Vector3.new(14, 3.6, 3), gearCf * CFrame.new(0, 1.8, 0), Kit.style("wood"), {
			parent = m,
		})
	CollectionService:AddTag(gear, "GearShopCounter")
	fascia(ctx, m, F, poi, w, CURB + H - 3, z0, 4)
end

-- Hotwire Motors keeps v1's showroom (world axes around the POI centre: glass on W / S / E, the north side open for the
-- drive-out, a canopy with a skylight at 18.8) so DealershipService's turntables, dressing and sign fit it exactly.
local function v1Showroom(ctx: Ctx, m: Model, poi: POI)
	local o = MapLayout.poiCenter("Dealership")
	local function L(x: number, y: number, z: number): CFrame
		return CFrame.new(o + Vector3.new(x, y, z))
	end
	local function p(name: string, size: Vector3, cf: CFrame, style: Kit.Style, opts: Kit.PartOpts?): Part
		local o2: Kit.PartOpts = if opts then table.clone(opts) else {}
		o2.parent = m
		return Kit.part(ctx, name, size, cf, style, o2)
	end
	local white = Kit.style("paint_white")
	local glassOpts: Kit.PartOpts = { transparency = 0.55, shadow = false }
	p("GlassWall", Vector3.new(100, 16, 0.6), L(0, 8, 46), Kit.style("glass_clear"), glassOpts)
	p("GlassWall", Vector3.new(0.6, 16, 92), L(50, 8, 0), Kit.style("glass_clear"), glassOpts)
	p("GlassWall", Vector3.new(0.6, 16, 92), L(-50, 8, 0), Kit.style("glass_clear"), glassOpts)
	for _, x in { -50.5, 50.5 } do
		p("Pillar", Vector3.new(2.6, 18, 2.6), L(x, 9, -47.5), white)
		p("Pillar", Vector3.new(2.6, 18, 2.6), L(x, 9, 46.5), white)
	end
	p("Canopy", Vector3.new(106, 1.6, 14), L(0, 18.8, -42.5), white)
	p("Canopy", Vector3.new(106, 1.6, 14), L(0, 18.8, 41.5), white)
	p("Canopy", Vector3.new(14, 1.6, 70), L(-46, 18.8, -0.5), white)
	p("Canopy", Vector3.new(14, 1.6, 70), L(46, 18.8, -0.5), white)
	p(
		"Skylight",
		Vector3.new(78, 0.6, 70),
		L(0, 19.2, -0.5),
		Kit.style("glass_clear"),
		{ transparency = 0.6, shadow = false }
	)
	local edge = p("CanopyEdge", Vector3.new(106.6, 0.6, 98.6), L(0, 18.3, -0.5), Kit.style("neon_warm"), {
		collide = false,
		shadow = false,
	})
	edge.Color = Color3.fromRGB(255, 52, 140)
	for i, cf in MapLayout.dealerPads() do
		local pad = p(
			"DealerPad" .. i,
			Vector3.new(0.2, 20, 20),
			cf * CFrame.new(0, 0.1, 0) * CFrame.Angles(0, 0, math.pi / 2),
			Kit.style("paint_black"),
			{ shape = Enum.PartType.Cylinder, shadow = false }
		)
		pad.Color = Color3.fromRGB(36, 38, 58)
		pad:SetAttribute("PadIndex", i)
		CollectionService:AddTag(pad, "DealerPad")
	end
	for _, s in
		{
			{ "DealerSignNorth", Vector3.new(64, 9, 1.2), Vector3.new(0, 24.6, -48.5), Vector3.new(0, 0, -1) },
			{ "DealerSignWest", Vector3.new(60, 8, 1.2), Vector3.new(-52, 24.1, 0), Vector3.new(-1, 0, 0) },
		}
	do
		local pos = o + (s[3] :: Vector3)
		local board =
			p(s[1] :: string, s[2] :: Vector3, CFrame.lookAt(pos, pos + (s[4] :: Vector3)), Kit.style("paint_black"))
		board.Color = Color3.fromRGB(24, 26, 50)
		textSign(
			board,
			Enum.NormalId.Front,
			"HOTWIRE MOTORS",
			Color3.fromRGB(255, 255, 255),
			Color3.fromRGB(24, 26, 50)
		)
		Kit.nightGlow(board, Color3.fromRGB(60, 70, 140))
	end
	local _ = poi
end

local function dealership(ctx: Ctx, m: Model, F: CFrame, poi: POI)
	local W, D, H = poi.size.X, poi.size.Z, math.max(poi.size.Y, 24)
	if poi.id == "Dealership" then
		v1Showroom(ctx, m, poi)
		pylon(ctx, m, F, poi, W / 2 - 10, -D / 2 + 6, 26)
		return
	end
	-- showroom pavilion at the back: glass box under a flat roof
	local zBack = -D / 2 + 84
	local d = D / 2 - zBack - 2
	if d > 10 then
		local glass = box(ctx, m, "Showroom", F, 0, CURB + H / 2, zBack + d / 2, W - 30, H, d, Kit.style("glass"))
		glass.Transparency = 0.25
		Kit.nightGlow(glass, Color3.fromRGB(230, 240, 255))
		box(ctx, m, "Roof", F, 0, CURB + H + 0.8, zBack + d / 2, W - 24, 1.6, d + 6, Kit.style("steel_white"))
	end
	for i, cf in Places.dealerPads(poi) do
		local pad = Kit.part(
			ctx,
			"ShowroomPad" .. i,
			Vector3.new(0.2, 22, 22),
			cf * CFrame.new(0, 0.1, 0) * CFrame.Angles(0, 0, math.pi / 2),
			Kit.style("concrete_modern"),
			{ parent = m, shape = Enum.PartType.Cylinder, shadow = false }
		)
		pad.Color = Color3.fromRGB(46, 48, 60)
	end
	pylon(ctx, m, F, poi, W / 2 - 10, -D / 2 + 6, 26)
	-- bunting poles along the front
	for _, sx in { -1, 1 } do
		box(ctx, m, "FlagPole", F, sx * (W / 2 - 4), CURB + 12, -D / 2 + 4, 0.6, 24, 0.6, Kit.style("metal_grey"))
	end
end

local function gas(ctx: Ctx, m: Model, F: CFrame, poi: POI)
	local W, D = poi.size.X, poi.size.Z
	-- canopy over two pump islands, store at the back
	local cz = -D / 2 + 38
	box(ctx, m, "Canopy", F, 0, CURB + 17, cz, W * 0.62, 2, 44, Kit.style("steel_white"))
	local band = box(ctx, m, "CanopyBand", F, 0, CURB + 17, cz - 22.2, W * 0.62, 2.4, 0.4, Kit.style("paint_red"), {
		collide = false,
	})
	band.Color = brandOf(poi)[1]
	Kit.nightGlow(band, band.Color)
	for _, sx in { -1, 1 } do
		box(ctx, m, "CanopyPost", F, sx * W * 0.22, CURB + 8, cz, 1.6, 16, 1.6, Kit.style("steel_white"))
		box(ctx, m, "PumpIsland", F, sx * W * 0.13, CURB + 0.4, cz, 5, 0.8, 26, Kit.style("concrete"))
		for _, pz in { -7, 7 } do
			box(ctx, m, "Pump", F, sx * W * 0.13, CURB + 3.6, cz + pz, 2.4, 5.6, 3.2, Kit.style("steel_white"))
		end
	end
	local sd = math.max(D / 2 - (cz + 26), 14)
	massing(ctx, m, F, 0, D / 2 - sd / 2 - 2, W * 0.5, 16, sd, Kit.style("stucco_white"))
	storefront(ctx, m, F, 0, D / 2 - sd - 2, W * 0.4, 8)
	fascia(ctx, m, F, poi, W * 0.4, CURB + 13, D / 2 - sd - 2, 3)
	pylon(ctx, m, F, poi, W / 2 - 8, -D / 2 + 5, 28)
end

local function plaza(ctx: Ctx, m: Model, F: CFrame, poi: POI)
	local W, D = poi.size.X, poi.size.Z
	box(ctx, m, "Plaza", F, 0, CURB - LOT_T / 2 + 0.01, 0, W, LOT_T, D, Kit.style("terrazzo"))
	-- SpawnLocation: the first spawn out on the boulevard sidewalk in front of the plaza (MapLayout.spawnCFrame,
	-- VIBE_ROUTING #2). An invisible pad sunk flush into the sidewalk: no glowing spawn plate in the street.
	local spawnCf = MapLayout.spawnCFrame()
	local sp = Instance.new("SpawnLocation")
	sp.Name = "SpawnLocation"
	sp.Anchored = true
	sp.Size = Vector3.new(6, 1, 6)
	local top = spawnCf.Position.Y - MapLayout.SPAWN_ROOT
	sp.CFrame = CFrame.new(spawnCf.Position.X, top - 0.5, spawnCf.Position.Z) * spawnCf.Rotation
	sp.Color = Color3.fromRGB(150, 147, 140)
	sp.Material = Enum.Material.Concrete
	sp.TopSurface = Enum.SurfaceType.Smooth
	sp.BottomSurface = Enum.SurfaceType.Smooth
	sp.Neutral = true
	sp.Duration = 0
	sp.Enabled = true
	sp.AllowTeamChangeOnTouch = false
	sp.CanTouch = false
	sp.CanQuery = false
	sp.CastShadow = false
	sp.Transparency = 1
	sp.Parent = m
	ctx.counts.SpawnLocation = (ctx.counts.SpawnLocation or 0) + 1
	ctx.parts += 1
	-- fountain at the plaza centre
	local fx, fz = -W * 0.18, 0
	Kit.part(
		ctx,
		"Fountain",
		Vector3.new(2, 34, 34),
		F * CFrame.new(fx, CURB + 1, fz) * CFrame.Angles(0, 0, math.pi / 2),
		Kit.style("terrazzo"),
		{ parent = m, shape = Enum.PartType.Cylinder }
	)
	local water = Kit.part(
		ctx,
		"FountainWater",
		Vector3.new(0.4, 30, 30),
		F * CFrame.new(fx, CURB + 1.9, fz) * CFrame.Angles(0, 0, math.pi / 2),
		Kit.style("water"),
		{ parent = m, shape = Enum.PartType.Cylinder, collide = false, query = false, transparency = 0.25 }
	)
	water.Name = "FountainWater"
	box(ctx, m, "FountainSpire", F, fx, CURB + 6, fz, 2.4, 10, 2.4, Kit.style("terrazzo"))
	-- leaderboards facing the plaza's hub point (Spawns.default)
	local spawnLocal = F:PointToObjectSpace(WorldLayout.Spawns.default.Position)
	for i, b in
		{
			{ stat = "totalEarned", x = W * 0.22 },
			{ stat = "steals", x = W * 0.32 },
		}
	do
		local lp = Vector3.new(b.x, CURB + 13.5, (if i == 1 then -1 else 1) * D * 0.18)
		local world = F * CFrame.new(lp)
		local look = F * CFrame.new(spawnLocal.X, lp.Y, spawnLocal.Z)
		local cf = CFrame.lookAt(world.Position, look.Position)
		local board = Kit.part(
			ctx,
			if i == 1 then "LeaderboardEarned" else "LeaderboardSteals",
			Vector3.new(24, 15, 1),
			cf,
			Kit.style("paint_black"),
			{ parent = m }
		)
		board.Color = Color3.fromRGB(18, 20, 38)
		board:SetAttribute("Stat", b.stat)
		board:SetAttribute("Face", "Front")
		CollectionService:AddTag(board, "LeaderboardBoard")
		-- a plain dark metal bezel (no neon outline: the kill list bans neon stripes on edges)
		Kit.part(ctx, "BoardFrame", Vector3.new(25.4, 16.4, 0.5), cf * CFrame.new(0, 0, 0.4), Kit.style("metal_dark"), {
			parent = m,
			collide = false,
			shadow = false,
		})
		Kit.part(ctx, "BoardLeg", Vector3.new(1.2, 7, 1.2), cf * CFrame.new(0, -10.5, 0.3), Kit.style("metal_grey"), {
			parent = m,
		})
	end
	-- the big logo sign at the back of the plaza
	local logo = box(ctx, m, "WelcomeSign", F, -W * 0.4, CURB + 26, D * 0.3, 34, 19, 1.4, Kit.style("paint_black"))
	logo.Color = Color3.fromRGB(18, 18, 36)
	local img = Assets.Images.logo_hotwire_city
	if img then
		for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
			local d = Instance.new("Decal")
			d.Face = face
			d.Texture = img
			d.Parent = logo
		end
		logo:SetAttribute("Image", img)
	end
	box(ctx, m, "SignPost", F, -W * 0.4, CURB + 8, D * 0.3, 1.4, 16, 1.4, Kit.style("metal_grey"))
	-- planters with palms at the corners
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local px, pz = sx * (W / 2 - 14), sz * (D / 2 - 14)
			box(ctx, m, "Planter", F, px, CURB + 1, pz, 9, 2, 9, Kit.style("stucco"))
			local base = (F * CFrame.new(px, CURB + 2, pz)).Position
			Kit.part(
				ctx,
				"PalmTrunk",
				Vector3.new(44, 2.2, 2.2),
				CFrame.new(base + Vector3.new(0, 22, 0)) * CFrame.Angles(0, 0, math.pi / 2),
				Kit.style("palm_trunk"),
				{ parent = m, shape = Enum.PartType.Cylinder }
			)
			local crown = Kit.part(
				ctx,
				"PalmCrown",
				Vector3.new(15, 6, 15),
				CFrame.new(base + Vector3.new(0, 44.5, 0)),
				Kit.style("foliage_palm"),
				{
					parent = m,
					collide = false,
				}
			)
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = crown
		end
	end
end

local function police(ctx: Ctx, m: Model, F: CFrame, poi: POI)
	local W, D, H = poi.size.X, poi.size.Z, math.max(poi.size.Y, 26)
	local d = D * 0.55
	local zc = D / 2 - d / 2 - 2
	massing(ctx, m, F, 0, zc, W - 16, H, d, Kit.style("concrete_modern"))
	storefront(ctx, m, F, 0, zc - d / 2, W * 0.35, 9)
	box(ctx, m, "Canopy", F, 0, CURB + 11, zc - d / 2 - 5, W * 0.4, 1.2, 10, Kit.style("concrete"))
	fascia(ctx, m, F, poi, W * 0.5, CURB + H - 4, zc - d / 2, 4)
	box(ctx, m, "FlagPole", F, -W / 2 + 8, CURB + 16, -D / 2 + 8, 0.6, 32, 0.6, Kit.style("metal_grey"))
end

local function hospital(ctx: Ctx, m: Model, F: CFrame, poi: POI)
	local W, D, H = poi.size.X, poi.size.Z, math.max(poi.size.Y, 30)
	local d = D * 0.62
	local zc = D / 2 - d / 2 - 2
	massing(ctx, m, F, 0, zc, W - 12, H, d, Kit.style("stucco_white"))
	storefront(ctx, m, F, 0, zc - d / 2, W * 0.4, 9)
	box(ctx, m, "ERCanopy", F, W * 0.2, CURB + 12, zc - d / 2 - 9, 34, 1.4, 18, Kit.style("steel_white"))
	local cross =
		box(ctx, m, "Cross", F, -W * 0.28, CURB + H - 8, zc - d / 2 - 0.5, 9, 3, 0.6, Kit.style("paint_red"), {
			collide = false,
		})
	Kit.nightGlow(cross, Color3.fromRGB(255, 40, 40))
	local cross2 =
		box(ctx, m, "Cross", F, -W * 0.28, CURB + H - 8, zc - d / 2 - 0.5, 3, 9, 0.6, Kit.style("paint_red"), {
			collide = false,
		})
	Kit.nightGlow(cross2, Color3.fromRGB(255, 40, 40))
	fascia(ctx, m, F, poi, W * 0.5, CURB + 15, zc - d / 2, 3.4)
end

local function tower(ctx: Ctx, m: Model, F: CFrame, poi: POI, glassTint: Color3)
	local W, D, H = poi.size.X, poi.size.Z, poi.size.Y
	local podH = math.min(36, H * 0.15)
	massing(ctx, m, F, 0, 0, W - 6, podH, D - 6, Kit.style("concrete_modern"))
	storefront(ctx, m, F, 0, -(D - 6) / 2, W * 0.7, 12)
	local sw, sd = W * 0.72, D * 0.72
	local shaft = box(ctx, m, "Tower", F, 0, CURB + podH + (H - podH) / 2, 0, sw, H - podH, sd, Kit.style("glass"))
	shaft.Color = glassTint
	-- mullion bands every 50 studs (cheap facade rhythm)
	local y = CURB + podH + 50
	while y < CURB + H - 10 do
		box(ctx, m, "Band", F, 0, y, 0, sw + 0.8, 1.6, sd + 0.8, Kit.style("concrete_modern"), { shadow = false })
		y += 50
	end
	-- crown
	if table.find(poi.tags, "crown:spire") then
		box(ctx, m, "Crown", F, 0, CURB + H + 12, 0, sw * 0.6, 24, sd * 0.6, Kit.style("glass"))
		local spire = Kit.part(
			ctx,
			"Spire",
			Vector3.new(120, 3, 3),
			F * CFrame.new(0, CURB + H + 24 + 60, 0) * CFrame.Angles(0, 0, math.pi / 2),
			Kit.style("steel_white"),
			{ parent = m, shape = Enum.PartType.Cylinder }
		)
		local _ = spire
		local beacon =
			box(ctx, m, "Beacon", F, 0, CURB + H + 145, 0, 2, 2, 2, Kit.style("paint_red"), { collide = false })
		Kit.nightGlow(beacon, Color3.fromRGB(255, 30, 30))
	elseif table.find(poi.tags, "crown:pyramid") then
		local top = F * CFrame.new(0, CURB + H, 0)
		local half = sw / 2
		for k = 0, 3 do
			local rot = top * CFrame.Angles(0, k * math.pi / 2, 0)
			Kit.wedge(
				ctx,
				"Crown",
				Vector3.new(sw, 40, half),
				rot * CFrame.new(0, 20, -half / 2) * CFrame.Angles(0, math.pi, 0),
				Kit.style("glass"),
				{
					parent = m,
				}
			)
		end
	else
		box(ctx, m, "Crown", F, 0, CURB + H + 6, 0, sw * 0.5, 12, sd * 0.5, Kit.style("metal_grey"))
	end
end

local function genericPOI(ctx: Ctx, m: Model, F: CFrame, poi: POI)
	local W, D = poi.size.X, poi.size.Z
	local H = math.max(poi.size.Y, 16)
	local frontApron = math.min(30, D * 0.3)
	local d = D - frontApron - 4
	local zc = D / 2 - d / 2 - 2
	local style = Kit.style("stucco")
	if poi.kind == "bank" or poi.kind == "bank_branch" or poi.kind == "city_hall" or poi.kind == "museum" then
		style = Kit.style("terrazzo")
	elseif poi.kind == "armored_depot" or poi.kind == "port_office" then
		style = Kit.style("corrugated")
	elseif poi.kind == "jewelry" or poi.kind == "theater" then
		style = Kit.style("stucco_white")
	end
	massing(ctx, m, F, 0, zc, W - 8, H, d, style)
	storefront(ctx, m, F, 0, zc - d / 2, (W - 8) * 0.8, math.min(9, H - 4))
	fascia(ctx, m, F, poi, W * 0.6, CURB + math.min(H - 3, 14), zc - d / 2, 3.6)
	if poi.kind == "convenience" or poi.kind == "diner" or poi.kind == "motel" then
		pylon(ctx, m, F, poi, W / 2 - 6, -D / 2 + 5, 20)
	end
	if poi.kind == "bank" or poi.kind == "city_hall" then
		-- colonnade
		for k = -2, 2 do
			Kit.part(
				ctx,
				"Column",
				Vector3.new(math.min(H, 40), 3.2, 3.2),
				F
					* CFrame.new(k * (W - 30) / 4, CURB + math.min(H, 40) / 2, zc - d / 2 - 6)
					* CFrame.Angles(0, 0, math.pi / 2),
				Kit.style("terrazzo"),
				{ parent = m, shape = Enum.PartType.Cylinder }
			)
		end
	end
	if poi.kind == "prison" then
		-- perimeter wall
		for _, side in { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } do
			local along = if side[1] == 0 then W else D
			local x, z = side[1] * (W / 2 - 2), side[2] * (D / 2 - 2)
			local sx, sz = if side[1] == 0 then along else 3, if side[1] == 0 then 3 else along
			box(ctx, m, "PrisonWall", F, x, CURB + 12, z, sx, 24, sz, Kit.style("concrete"))
		end
	end
end

local function landmarkPOI(ctx: Ctx, m: Model, F: CFrame, poi: POI)
	local W, D, H = poi.size.X, poi.size.Z, poi.size.Y
	if poi.id == "PinnacleTower" then
		tower(ctx, m, F, poi, Color3.fromRGB(70, 104, 132))
	elseif poi.id == "Arena" then
		-- stadium bowl: four stands around the field
		local field = box(ctx, m, "Field", F, 0, CURB + 0.2, 0, W * 0.55, 0.4, D * 0.5, Kit.style("grass"))
		local _ = field
		for _, s in { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } do
			local along = if s[1] == 0 then W else D
			local depth = 0.22 * (if s[1] == 0 then D else W)
			local x = s[1] * (W / 2 - depth / 2)
			local z = s[2] * (D / 2 - depth / 2)
			local sx = if s[1] == 0 then along else depth
			local sz = if s[1] == 0 then depth else along
			box(ctx, m, "Stand", F, x, CURB + H / 2, z, sx, H, sz, Kit.style("concrete_modern"))
		end
		fascia(ctx, m, F, poi, W * 0.5, CURB + H + 4, -D / 2, 6)
	elseif poi.id == "Casino" then
		massing(ctx, m, F, 0, D * 0.12, W - 10, H, D * 0.7, Kit.style("stucco_white"))
		local neon = box(
			ctx,
			m,
			"CasinoNeon",
			F,
			0,
			CURB + H * 0.6,
			D * 0.12 - D * 0.35 - 1,
			W * 0.7,
			8,
			0.6,
			Kit.style("neon_warm"),
			{
				collide = false,
			}
		)
		neon.Color = Color3.fromRGB(255, 60, 160)
		textSign(neon, Enum.NormalId.Front, "LUCKY SEVEN", Color3.fromRGB(255, 240, 120), Color3.fromRGB(120, 10, 60))
		box(ctx, m, "Portico", F, 0, CURB + 14, -D / 2 + 22, W * 0.4, 2, 26, Kit.style("steel_white"))
	elseif poi.id == "Observatory" then
		massing(ctx, m, F, 0, D * 0.1, W * 0.7, 26, D * 0.6, Kit.style("stucco_white"))
		for _, sx in { -1, 1 } do
			local dome = Kit.part(
				ctx,
				"Dome",
				Vector3.new(34, 34, 34),
				F * CFrame.new(sx * W * 0.25, CURB + 26, D * 0.1),
				Kit.style("metal_grey"),
				{
					parent = m,
					shape = Enum.PartType.Ball,
				}
			)
			dome.Color = Color3.fromRGB(70, 74, 80)
		end
		local center = Kit.part(
			ctx,
			"Dome",
			Vector3.new(46, 46, 46),
			F * CFrame.new(0, CURB + 30, D * 0.1),
			Kit.style("metal_grey"),
			{
				parent = m,
				shape = Enum.PartType.Ball,
			}
		)
		center.Color = Color3.fromRGB(70, 74, 80)
	else
		genericPOI(ctx, m, F, poi)
	end
end

local LOT_STYLE: { [string]: string } = {
	gas = "asphalt",
	dealership = "asphalt",
	chop = "gravel",
	customs = "asphalt",
	spray = "asphalt",
	armored_depot = "asphalt",
	plaza = "terrazzo",
	prison = "concrete_dark",
	airport_terminal = "concrete",
	gym = "sand",
}

function Places.buildPOI(ctx: Ctx, poi: POI): Model
	local F = poi.cframe
	local m = model(ctx, "POIs", poi.id, F)
	m:SetAttribute("Kind", poi.kind)
	m:SetAttribute("DisplayName", poi.name)
	local W, D = poi.size.X, poi.size.Z
	if poi.kind ~= "plaza" then
		lotSlab(ctx, m, F, W, D, Kit.style(LOT_STYLE[poi.kind] or "concrete"))
	end
	local k = poi.kind
	if k == "gunshop" then
		gunshop(ctx, m, F, poi)
	elseif k == "spray" then
		bayBuilding(ctx, m, F, poi, Kit.style("stucco_white"))
	elseif k == "customs" then
		bayBuilding(ctx, m, F, poi, Kit.style("corrugated"))
	elseif k == "chop" then
		bayBuilding(ctx, m, F, poi, Kit.style("rust"))
	elseif k == "dealership" then
		dealership(ctx, m, F, poi)
	elseif k == "gas" then
		gas(ctx, m, F, poi)
	elseif k == "plaza" then
		plaza(ctx, m, F, poi)
	elseif k == "police" then
		police(ctx, m, F, poi)
	elseif k == "hospital" then
		hospital(ctx, m, F, poi)
	elseif k == "landmark" then
		landmarkPOI(ctx, m, F, poi)
	elseif k == "city_hall" or (k == "bank" and poi.size.Y > 60) then
		tower(ctx, m, F, poi, Color3.fromRGB(150, 160, 150))
	elseif k == "gym" then
		-- Muscle Beach: an open-air pen of benches on the sand
		for i = -2, 2 do
			box(ctx, m, "GymRack", F, i * 18, CURB + 2.5, 0, 6, 5, 2, Kit.style("metal_dark"))
		end
		fascia(ctx, m, F, poi, 40, CURB + 10, -D / 2 + 4, 4)
	else
		genericPOI(ctx, m, F, poi)
	end
	return m
end

-------------------------------------------------------------------------------------------------------------------------
-- Plots
-------------------------------------------------------------------------------------------------------------------------

-- Studs between the plot's front edge and the back of the sidewalk of the road it faces (0 when none is in front).
function Places.frontGap(plot: WorldLayout.Plot): number
	local F = plot.cframe
	local front = F * Vector3.new(0, 0, -plot.size.Z / 2)
	local p, ei = WorldQuery.nearestRoadPoint(front, { maxDistance = 120 })
	if not p or not ei then
		return 0
	end
	local e = WorldLayout.Edges[ei]
	local along = F.LookVector:Dot(p - front)
	return math.clamp(along - e.width / 2 - (e.sidewalk or 0), 0, 40)
end

-- The garage pad (level at the plot frame) + driveway apron down to the sidewalk.
function Places.buildPlot(ctx: Ctx, plot: WorldLayout.Plot): Model
	local F = plot.cframe
	local m = model(ctx, "Plots", "Plot" .. plot.index, F)
	m:SetAttribute("PlotIndex", plot.index)
	m:SetAttribute("DisplayName", plot.name)
	local W, D = plot.size.X, plot.size.Z
	-- pad top at the plot frame's Y (curb height); deep enough to cover sloped terrain
	box(ctx, m, "PlotPad", F, 0, -3, 0, W, 6, D, Kit.style("concrete_modern"))
	-- the lot's setback between the pad and the back of the sidewalk (13-14 studs on every plot): a concrete apron at
	-- the same height, so the door does not open onto bare ground
	local gap = Places.frontGap(plot)
	if gap > 1 then
		box(ctx, m, "PlotApron", F, 0, -3, -D / 2 - (gap - 0.5) / 2, W, 6, gap - 0.5, Kit.style("concrete_modern"))
	end
	-- driveway: asphalt in front of the door (local -Z) out to the sidewalk
	local dl = 32 + math.max(gap - 0.5, 0)
	box(ctx, m, "Driveway", F, 0, 0.02 - 0.5, -D / 2 + 32 - dl / 2, 44, 1, dl, Kit.style("asphalt"), { tag = "Road" })
	-- low hedges along the sides
	for _, sx in { -1, 1 } do
		box(ctx, m, "Hedge", F, sx * (W / 2 - 2), 2, 0, 3, 4, D - 8, Kit.style("foliage"))
	end
	return m
end

-------------------------------------------------------------------------------------------------------------------------
-- Open parcels
-------------------------------------------------------------------------------------------------------------------------

local CONTAINER_COLORS = {
	Color3.fromRGB(176, 72, 44),
	Color3.fromRGB(36, 92, 150),
	Color3.fromRGB(52, 122, 72),
	Color3.fromRGB(196, 150, 46),
	Color3.fromRGB(130, 50, 56),
	Color3.fromRGB(200, 200, 196),
}

function Places.buildOpenParcel(ctx: Ctx, p: WorldLayout.Parcel)
	local F = p.cframe
	local W, D = p.size.X, p.size.Z
	if p.use == "parking_lot" then
		Kit.part(
			ctx,
			"ParkingLot",
			Vector3.new(W - 2, 2, D - 2),
			F * CFrame.new(0, CURB - 1 - 0.02, 0),
			Kit.style("asphalt_worn"),
			{
				tag = "Road",
			}
		)
	elseif p.use == "plaza" then
		Kit.part(
			ctx,
			"PlazaPaving",
			Vector3.new(W - 2, 2, D - 2),
			F * CFrame.new(0, CURB - 1, 0),
			Kit.style("terrazzo")
		)
	elseif p.use == "park" then
		Kit.part(ctx, "ParkLawn", Vector3.new(W - 2, 2, D - 2), F * CFrame.new(0, CURB - 1, 0), Kit.style("grass"))
		local n = math.clamp(math.floor(W * D / 2500), 1, 6)
		for i = 1, n do
			local x = (Kit.hash(p.id, i, 31) - 0.5) * (W - 20)
			local z = (Kit.hash(p.id, i, 32) - 0.5) * (D - 20)
			local base = (F * CFrame.new(x, CURB, z)).Position
			local h = 22 + 10 * Kit.hash(p.id, i, 33)
			Kit.post(ctx, "TreeTrunk", base, h * 0.45, 1.5, Kit.style("bark"))
			local c = Kit.part(
				ctx,
				"TreeCanopy",
				Vector3.new(h * 0.6, h * 0.6, h * 0.6),
				CFrame.new(base + Vector3.new(0, h * 0.68, 0)),
				Kit.style("foliage"),
				{
					collide = false,
					query = false,
				}
			)
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = c
		end
	elseif p.use == "yard" then
		Kit.part(ctx, "Yard", Vector3.new(W - 2, 2, D - 2), F * CFrame.new(0, CURB - 1, 0), Kit.style("gravel"))
	elseif p.use == "container_yard" then
		Kit.part(ctx, "Yard", Vector3.new(W - 2, 2, D - 2), F * CFrame.new(0, CURB - 1, 0), Kit.style("concrete_dark"))
		-- rows of 40-ft containers (8.5 x 8.6 x 40), stacked 1-3 high
		local cols = math.max(1, math.floor((W - 30) / 11))
		local rows = math.max(1, math.floor((D - 40) / 52))
		local count = 0
		for r = 1, rows do
			for c = 1, cols do
				if count > 90 then
					break
				end
				local x = -W / 2 + 15 + (c - 0.5) * 11
				local z = -D / 2 + 30 + (r - 0.5) * 52
				local h = 1 + math.floor(Kit.hash(p.id, r * 97 + c, 41) * 3)
				local col = CONTAINER_COLORS[1 + math.floor(Kit.hash(p.id, r * 97 + c, 42) * #CONTAINER_COLORS)]
				local cont = Kit.part(
					ctx,
					"Container",
					Vector3.new(8.5, 8.6 * h, 40),
					F * CFrame.new(x, CURB + 4.3 * h, z),
					Kit.style("corrugated")
				)
				cont.Color = col
				count += 1
			end
		end
	end
	Kit.tick(ctx)
end

-------------------------------------------------------------------------------------------------------------------------
-- Paths, helipads, stunt ramps, level crossings, rails
-------------------------------------------------------------------------------------------------------------------------

local PATH_STYLE: { [string]: string } = { boardwalk = "wood", park = "concrete", plaza = "terrazzo", trail = "gravel" }

function Places.buildPaths(ctx: Ctx)
	for _, path in WorldLayout.Paths do
		local style = Kit.style(PATH_STYLE[path.kind] or "concrete")
		local pts = path.points
		local raise = if path.kind == "boardwalk" then 1.4 else 0.15
		Roads.strip(ctx, "Path_" .. path.kind, pts, 0, path.width, raise, 2 + raise, style)
		if path.kind == "boardwalk" then
			-- rail on the sea side every segment (one part per segment)
			Roads.strip(ctx, "BoardwalkRail", pts, path.width / 2 - 0.3, 0.5, raise + 3.2, 3.2, Kit.style("wood"))
		end
	end
end

-- Helipads on ground / POI roofs (A3's tower crowns carry their own).
function Places.buildHelipads(ctx: Ctx)
	for _, z in WorldLayout.Helipads do
		if string.sub(z.id, 1, 10) == "heli_core_" then
			continue
		end
		local cf = z.cframe
		local pad = Kit.part(
			ctx,
			"Helipad",
			Vector3.new(z.size.X, 1, z.size.Z),
			CFrame.new(cf.Position - Vector3.new(0, z.size.Y / 2 - 0.5, 0)) * cf.Rotation,
			Kit.style("concrete_dark")
		)
		textSign(pad, Enum.NormalId.Top, "H", Color3.fromRGB(240, 210, 60), nil, Enum.Font.GothamBlack)
		local gui = pad:FindFirstChildOfClass("SurfaceGui")
		if gui then
			gui.MaxDistance = 1500
		end
	end
end

-- Kicker ramps (wedges rising toward the jump direction); drops and splashes use the existing lips.
function Places.buildStuntJumps(ctx: Ctx)
	for _, j in WorldLayout.StuntJumps do
		if j.kind ~= "kicker" then
			continue
		end
		local cf = j.cframe
		local size = j.size
		-- the lip is at cf; the ramp runs back from it (against LookVector), its tall face at the lip
		local center = cf * CFrame.new(0, -size.Y / 2, size.Z / 2)
		local w = Kit.wedge(ctx, "StuntRamp", size, center * CFrame.Angles(0, math.pi, 0), Kit.style("metal_grey"))
		w.Color = Color3.fromRGB(230, 180, 40)
		w:SetAttribute("Jump", j.id)
	end
end

-- Arc length along edge ei of the point nearest p (XZ).
-- Lifeguard towers on Palmera Beach (the Vespucci look): along the shore either side of the pier, every TOWER_GAP
-- studs, TOWER_SETBACK up the sand from the water line, facing the sea. 5 parts each.
local TOWER_GAP, TOWER_SETBACK = 380, 110
local TOWER_BLUE = Color3.fromRGB(122, 188, 214)

function Places.lifeguardSpots(): { CFrame }
	local pier: WorldLayout.Edge? = nil
	for _, e in WorldLayout.Edges do
		if e.class == "pier" and (pier == nil or e.length > pier.length) then
			pier = e
		end
	end
	if not pier then
		return {}
	end
	local a, b = pier.points[1], pier.points[#pier.points]
	if WorldTerrain.heightAt(a.X, a.Z) < WorldTerrain.heightAt(b.X, b.Z) then
		a, b = b, a -- from the land end
	end
	local dir = Vector3.new(b.X - a.X, 0, b.Z - a.Z).Unit
	local side = Vector3.new(-dir.Z, 0, dir.X)
	local out = {}
	for k = -4, 4 do
		if k == 0 then
			continue -- the pier
		end
		local base = a + side * (k * TOWER_GAP)
		local shore: Vector3? = nil
		for s = 0, 2000, 8 do
			local p = base + dir * s
			if WorldTerrain.heightAt(p.X, p.Z) < 2.5 then
				shore = p
				break
			end
		end
		if not shore then
			continue
		end
		local at = shore - dir * TOWER_SETBACK
		if WorldLayout.districtAt(at.X, at.Z) ~= "beach" or WorldQuery.isOnRoad(at, 30) then
			continue
		end
		local g = WorldTerrain.heightAt(at.X, at.Z)
		if g < 3 then
			continue
		end
		local foot = Vector3.new(at.X, g, at.Z)
		table.insert(out, CFrame.lookAt(foot, foot + dir))
	end
	return out
end

function Places.buildBeach(ctx: Ctx)
	for _, F in Places.lifeguardSpots() do
		Kit.part(ctx, "LifeguardBase", Vector3.new(7, 8, 7), F * CFrame.new(0, 3, 0), Kit.style("paint_white"))
		Kit.part(ctx, "LifeguardDeck", Vector3.new(13, 0.8, 13), F * CFrame.new(0, 7.4, 0), Kit.style("wood"))
		local cabin =
			Kit.part(ctx, "LifeguardCabin", Vector3.new(9, 7, 8), F * CFrame.new(0, 11.3, 1), Kit.style("stucco_white"))
		cabin.Color = TOWER_BLUE
		Kit.part(
			ctx,
			"LifeguardRoof",
			Vector3.new(10.5, 0.8, 9.5),
			F * CFrame.new(0, 15.2, 1),
			Kit.style("paint_white"),
			{ shadow = true }
		)
		-- the ramp up to the deck from the sand behind (landward, local +Z); the wedge's tall face meets the deck
		Kit.wedge(
			ctx,
			"LifeguardRamp",
			Vector3.new(4, 7.8, 14),
			F * CFrame.new(0, 3.9, 6.5 + 7) * CFrame.Angles(0, math.pi, 0),
			Kit.style("wood")
		)
	end
end

function Places.arcOf(ei: number, p: Vector3): number
	local pts = WorldLayout.Edges[ei].points
	local cum = Roads.cumOf(ei)
	local best, bestS = math.huge, 0
	for k = 1, #pts - 1 do
		local t, _, _, d = WorldGen.projectSeg(p.X, p.Z, pts[k].X, pts[k].Z, pts[k + 1].X, pts[k + 1].Z)
		if d < best then
			best = d
			bestS = cum[k] + t * (cum[k + 1] - cum[k])
		end
	end
	return bestS
end

function Places.buildLevelCrossings(ctx: Ctx)
	for _, lc in WorldLayout.LevelCrossings do
		local e = WorldLayout.Edges[lc.edge]
		local p = lc.pos
		-- the crossbucks stand on both sides of the road, 4 studs outside the curb
		local s = Places.arcOf(lc.edge, p)
		local a = Roads.pointAt(lc.edge, math.max(0, s - 2))
		local b = Roads.pointAt(lc.edge, s + 2)
		local h = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		if h.Magnitude < 1e-3 then
			continue
		end
		h = h.Unit
		local r = Vector3.new(-h.Z, 0, h.X)
		for _, side in { 1, -1 } do
			local base = p + r * side * (e.width / 2 + 4) + h * side * 12
			Kit.post(ctx, "CrossingPost", base, 12, 0.5, Kit.style("steel_white"))
			Kit.part(
				ctx,
				"Crossbuck",
				Vector3.new(7, 1.2, 0.2),
				CFrame.lookAt(base + Vector3.new(0, 11, 0), base + Vector3.new(0, 11, 0) + h * side)
					* CFrame.Angles(0, 0, math.rad(40)),
				Kit.style("sign_white"),
				{ collide = false }
			)
		end
	end
end

-- Rail tracks: a ballast bed + two rails per track, one part each per straight run.
function Places.buildRails(ctx: Ctx)
	for _, rail in WorldLayout.Rails do
		local pts = rail.points
		local n = math.max(1, rail.tracks)
		for t = 1, n do
			local off = (t - (n + 1) / 2) * (rail.spacing or 0)
			Roads.strip(ctx, "Ballast", pts, off, 11, 0.6, 2.6, Kit.style("gravel"))
			for _, rs in { -2.4, 2.4 } do
				Roads.strip(ctx, "Rail", pts, off + rs, 0.4, 1.3, 0.7, Kit.style("metal_dark"))
			end
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------

function Places.buildPOIs(ctx: Ctx, filter: ((POI) -> boolean)?)
	for _, poi in WorldLayout.POIs do
		if filter == nil or filter(poi) then
			Places.buildPOI(ctx, poi)
			Kit.tick(ctx)
		end
	end
end

function Places.buildPlots(ctx: Ctx)
	for _, plot in WorldLayout.Plots do
		Places.buildPlot(ctx, plot)
	end
end

Places.OPEN_USES = { park = true, plaza = true, parking_lot = true, yard = true, container_yard = true } :: {
	[string]: boolean,
}

function Places.buildOpenParcels(ctx: Ctx, filter: ((WorldLayout.Parcel) -> boolean)?)
	if not WorldLayout.hasServerData() then
		return
	end
	for _, p in WorldLayout.Parcels do
		if Places.OPEN_USES[p.use] and (filter == nil or filter(p)) then
			Places.buildOpenParcel(ctx, p)
		end
	end
end

return Places
