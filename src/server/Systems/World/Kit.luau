--!strict
-- World/Kit: the part factory every MapBuilder v2 builder uses. Pure instance construction (harness-compatible).
--
--   Kit.new(root)                      a build context: Map/Cells/c_<ix>_<iz> Models (512-stud streaming cells),
--                                      per-category part counts, a cooperative yield for the chunked boot build
--   Kit.part(ctx, cat, size, cf, style, opts?)        a Part in the cell under cf (or opts.parent)
--   Kit.wedge / Kit.post / Kit.rod / Kit.beam / Kit.triangle (two wedges) / Kit.quad (rect or two triangles)
--   Kit.style(name)                    { material, variant, color }: Look's PBR MaterialVariants set EXPLICITLY on the
--                                      part (MaterialVariant = "HC_..."), so the PBR look holds even where the global
--                                      base-material overrides are not active (job 0009 found none active in the
--                                      uploaded place); Look.Materials[x].color is the albedo (colour contract)
--
-- Conventions: anchored, CanTouch false everywhere (static world), CanCollide / CanQuery true for anything a car or a
-- bullet should hit, false for paint and foliage. Markings sit 0.02-0.05 above the asphalt with CastShadow false.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Look = require(ReplicatedStorage.Shared.Config.Look)
local WorldGen = require(ReplicatedStorage.Shared.Util.WorldGen)

local Kit = {}

Kit.CELL = 512

export type Style = { material: Enum.Material, variant: string?, color: Color3 }

export type Ctx = {
	root: Folder,
	cells: Folder,
	cellModels: { [string]: Model },
	counts: { [string]: number },
	parts: number,
	folders: { [string]: Folder },
	yield: (() -> ())?,
	yieldEvery: number,
	sinceYield: number,
}

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function lookStyle(variant: string, material: Enum.Material, tint: { number }?): Style
	local def = Look.Materials[variant]
	local c = if tint then tint else (if def then def.color else { 160, 160, 160 })
	return { material = material, variant = if def then variant else nil, color = rgb(c) }
end

local function plain(material: Enum.Material, c: { number }): Style
	return { material = material, variant = nil, color = rgb(c) }
end

-- Named styles (albedo = Look's colour contract unless tinted for a role).
local STYLES: { [string]: Style } = {
	asphalt = lookStyle("HC_Asphalt", Enum.Material.Asphalt),
	asphalt_dark = lookStyle("HC_Asphalt", Enum.Material.Asphalt, { 86, 86, 90 }),
	asphalt_worn = lookStyle("HC_AsphaltWorn", Enum.Material.Asphalt, { 150, 148, 142 }),
	sidewalk = lookStyle("HC_Sidewalk", Enum.Material.Pavement),
	curb = lookStyle("HC_Concrete", Enum.Material.Concrete, { 196, 193, 186 }),
	concrete = lookStyle("HC_Concrete", Enum.Material.Concrete),
	concrete_dark = lookStyle("HC_Concrete", Enum.Material.Concrete, { 150, 147, 140 }),
	concrete_modern = lookStyle("HC_ConcreteModern", Enum.Material.Concrete),
	grass = lookStyle("HC_Grass", Enum.Material.Grass),
	grass_dry = lookStyle("HC_DryGrass", Enum.Material.Ground),
	sand = lookStyle("HC_Sand", Enum.Material.Sand),
	wood = lookStyle("HC_WoodPlanks", Enum.Material.WoodPlanks),
	stucco = lookStyle("HC_Stucco", Enum.Material.Plaster, { 232, 222, 204 }),
	stucco_white = lookStyle("HC_Stucco", Enum.Material.Plaster, { 244, 240, 232 }),
	brick = lookStyle("HC_BrickRed", Enum.Material.Brick),
	terrazzo = lookStyle("HC_Terrazzo", Enum.Material.Marble),
	rust = lookStyle("HC_RustyMetal", Enum.Material.CorrodedMetal),
	corrugated = lookStyle("HC_CorrugatedMetal", Enum.Material.Metal),
	glass = lookStyle("HC_WindowGlass", Enum.Material.SmoothPlastic),
	glass_clear = plain(Enum.Material.Glass, { 160, 180, 190 }),
	gravel = lookStyle("HC_GravelRoof", Enum.Material.Pebble),
	roof_tiles = lookStyle("HC_RoofTiles", Enum.Material.ClayRoofTiles),
	rock = lookStyle("HC_Rock", Enum.Material.Rock),
	metal_dark = plain(Enum.Material.Metal, { 58, 60, 62 }),
	metal_grey = plain(Enum.Material.Metal, { 128, 132, 136 }),
	metal_green = plain(Enum.Material.Metal, { 52, 74, 60 }),
	steel_orange = plain(Enum.Material.Metal, { 196, 96, 34 }),
	steel_red = plain(Enum.Material.Metal, { 150, 44, 34 }),
	steel_white = plain(Enum.Material.Metal, { 222, 224, 226 }),
	paint_white = plain(Enum.Material.SmoothPlastic, { 228, 228, 222 }),
	paint_yellow = plain(Enum.Material.SmoothPlastic, { 222, 178, 52 }),
	paint_red = plain(Enum.Material.SmoothPlastic, { 178, 36, 32 }),
	paint_black = plain(Enum.Material.SmoothPlastic, { 22, 22, 24 }),
	signal_body = plain(Enum.Material.SmoothPlastic, { 34, 34, 30 }),
	sign_green = plain(Enum.Material.SmoothPlastic, { 20, 92, 52 }),
	sign_white = plain(Enum.Material.SmoothPlastic, { 236, 236, 230 }),
	neon_warm = plain(Enum.Material.Neon, { 255, 214, 160 }),
	lens_off = plain(Enum.Material.SmoothPlastic, { 210, 206, 190 }),
	bark = plain(Enum.Material.Wood, { 104, 88, 72 }),
	palm_trunk = plain(Enum.Material.Wood, { 128, 112, 92 }),
	foliage = lookStyle("HC_GrassLeafy", Enum.Material.LeafyGrass, { 74, 98, 52 }),
	foliage_palm = lookStyle("HC_GrassLeafy", Enum.Material.LeafyGrass, { 86, 112, 58 }),
	pole_wood = plain(Enum.Material.Wood, { 92, 74, 58 }),
	water = plain(Enum.Material.Glass, { 30, 70, 80 }),
	invisible = plain(Enum.Material.SmoothPlastic, { 255, 255, 255 }),
}
Kit.STYLES = STYLES

function Kit.style(name: string): Style
	local s = STYLES[name]
	assert(s, "World/Kit: unknown style " .. name)
	return s
end

function Kit.rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

function Kit.new(root: Folder, yieldFn: (() -> ())?): Ctx
	local cells = Instance.new("Folder")
	cells.Name = "Cells"
	cells.Parent = root
	return {
		root = root,
		cells = cells,
		cellModels = {},
		counts = {},
		parts = 0,
		folders = {},
		yield = yieldFn,
		yieldEvery = 600,
		sinceYield = 0,
	}
end

-- A named folder directly under Map (POIs, Plots, Buildings, Skeleton...).
function Kit.folder(ctx: Ctx, name: string): Folder
	local f = ctx.folders[name]
	if f then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = name
	nf.Parent = ctx.root
	ctx.folders[name] = nf
	return nf
end

-- The streaming cell Model holding world position p.
function Kit.cell(ctx: Ctx, p: Vector3): Model
	local ix, iz = math.floor(p.X / Kit.CELL), math.floor(p.Z / Kit.CELL)
	local key = ix .. "_" .. iz
	local m = ctx.cellModels[key]
	if m then
		return m
	end
	local nm = Instance.new("Model")
	nm.Name = "c_" .. key
	pcall(function()
		(nm :: any).ModelStreamingMode = Enum.ModelStreamingMode.Default
	end)
	nm:SetAttribute("CellX", ix)
	nm:SetAttribute("CellZ", iz)
	nm.Parent = ctx.cells
	ctx.cellModels[key] = nm
	return nm
end

-- Cooperative yield for the chunked boot build (no-op when building synchronously).
function Kit.tick(ctx: Ctx)
	local y = ctx.yield
	if y and ctx.sinceYield >= ctx.yieldEvery then
		ctx.sinceYield = 0
		y()
	end
end

export type PartOpts = {
	parent: Instance?,
	collide: boolean?, -- default true
	query: boolean?, -- default = collide
	shadow: boolean?, -- default true
	transparency: number?,
	shape: Enum.PartType?,
	tag: string?,
	name: string?,
}

local function finish(ctx: Ctx, p: BasePart, cat: string, cf: CFrame, style: Style, opts: PartOpts?)
	p.Anchored = true
	p.CanTouch = false
	local collide = if opts and opts.collide ~= nil then opts.collide else true
	p.CanCollide = collide
	p.CanQuery = if opts and opts.query ~= nil then opts.query else collide
	p.CastShadow = if opts and opts.shadow ~= nil then opts.shadow else true
	p.Material = style.material
	if style.variant then
		p.MaterialVariant = style.variant
	end
	p.Color = style.color
	if opts and opts.transparency then
		p.Transparency = opts.transparency
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Name = if opts and opts.name then opts.name else cat
	p.CFrame = cf
	if opts and opts.tag then
		CollectionService:AddTag(p, opts.tag)
	end
	p.Parent = if opts and opts.parent then opts.parent else Kit.cell(ctx, cf.Position)
	ctx.counts[cat] = (ctx.counts[cat] or 0) + 1
	ctx.parts += 1
	ctx.sinceYield += 1
end

function Kit.part(ctx: Ctx, cat: string, size: Vector3, cf: CFrame, style: Style, opts: PartOpts?): Part
	local p = Instance.new("Part")
	if opts and opts.shape then
		p.Shape = opts.shape
	end
	p.Size = Vector3.new(math.max(size.X, 0.05), math.max(size.Y, 0.05), math.max(size.Z, 0.05))
	finish(ctx, p, cat, cf, style, opts)
	return p
end

-- WedgePart: the slope faces local -Z and up, the tall face at +Z (SPEC §10).
function Kit.wedge(ctx: Ctx, cat: string, size: Vector3, cf: CFrame, style: Style, opts: PartOpts?): WedgePart
	local p = Instance.new("WedgePart")
	p.Size = Vector3.new(math.max(size.X, 0.05), math.max(size.Y, 0.05), math.max(size.Z, 0.05))
	finish(ctx, p, cat, cf, style, opts)
	return p
end

-- Vertical cylinder standing on `base` (axis = world up), height h, diameter d.
function Kit.post(ctx: Ctx, cat: string, base: Vector3, h: number, d: number, style: Style, opts: PartOpts?): Part
	local o: PartOpts = opts or {}
	o.shape = Enum.PartType.Cylinder
	return Kit.part(
		ctx,
		cat,
		Vector3.new(h, d, d),
		CFrame.new(base + Vector3.new(0, h / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		style,
		o
	)
end

-- Cylinder between two points (axis along a -> b), diameter d.
function Kit.rod(ctx: Ctx, cat: string, a: Vector3, b: Vector3, d: number, style: Style, opts: PartOpts?): Part
	local o: PartOpts = opts or {}
	o.shape = Enum.PartType.Cylinder
	local len = (b - a).Magnitude
	local dir = (b - a).Unit
	-- cylinder axis = local X: build a frame whose X points along a -> b
	local up = if math.abs(dir.Y) > 0.99 then Vector3.new(1, 0, 0) else Vector3.new(0, 1, 0)
	local zAxis = dir:Cross(up).Unit
	local yAxis = zAxis:Cross(dir).Unit
	local cf = CFrame.fromMatrix((a + b) / 2, dir, yAxis, zAxis)
	return Kit.part(ctx, cat, Vector3.new(len, d, d), cf, style, o)
end

-- Box between two points (length along a -> b), width w (horizontal), height h; pitched with the line.
function Kit.beam(
	ctx: Ctx,
	cat: string,
	a: Vector3,
	b: Vector3,
	w: number,
	h: number,
	style: Style,
	opts: PartOpts?
): Part
	local len = (b - a).Magnitude
	local mid = (a + b) / 2
	local cf = if math.abs((b - a).Unit.Y) > 0.999 then CFrame.new(mid) else CFrame.lookAt(mid, b)
	return Kit.part(ctx, cat, Vector3.new(w, h, len), cf, style, opts)
end

-- Right triangle as one WedgePart: right angle at r, legs to p and q; the slab hangs `thickness` under the
-- triangle's plane. (A WedgePart's triangle has its right angle on the local bottom-back edge (y -Y/2, z +Z/2), a
-- leg along -Z to (y -Y/2, z -Z/2) and a leg along +Y to (y +Y/2, z +Z/2).)
local function rightWedge(
	ctx: Ctx,
	cat: string,
	r: Vector3,
	p: Vector3,
	q: Vector3,
	thickness: number,
	style: Style,
	opts: PartOpts?
): WedgePart?
	local zLen = (r - p).Magnitude
	local yLen = (q - r).Magnitude
	if zLen < 1e-3 or yLen < 1e-3 then
		return nil
	end
	local zAxis = (r - p) / zLen
	local yAxis = (q - r) / yLen
	local xAxis = yAxis:Cross(zAxis)
	if xAxis.Magnitude < 1e-6 then
		return nil
	end
	xAxis = xAxis.Unit
	local upN = if xAxis.Y >= 0 then xAxis else -xAxis
	local center = r + (p - r) / 2 + (q - r) / 2 - upN * (thickness / 2)
	local w = Instance.new("WedgePart")
	w.Size = Vector3.new(thickness, yLen, zLen)
	finish(ctx, w, cat, CFrame.fromMatrix(center, xAxis, yAxis, zAxis), style, opts)
	return w
end

-- Flat triangle (a, b, c at their own heights) of the given thickness under its plane, from two WedgeParts split at
-- the altitude onto the longest side.
function Kit.triangle(
	ctx: Ctx,
	cat: string,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	thickness: number,
	style: Style,
	opts: PartOpts?
): { WedgePart }
	local ab, bc, ca = (b - a).Magnitude, (c - b).Magnitude, (a - c).Magnitude
	if bc > ab and bc >= ca then
		a, b, c = b, c, a
	elseif ca > ab and ca > bc then
		a, b, c = c, a, b
	end
	local out: { WedgePart } = {}
	local abv = b - a
	local abLen = abv.Magnitude
	if abLen < 1e-3 then
		return out
	end
	local u = abv / abLen
	local foot = a + u * (c - a):Dot(u)
	for _, corner in { a, b } do
		local w = rightWedge(ctx, cat, foot, corner, c, thickness, style, opts)
		if w then
			table.insert(out, w)
		end
	end
	return out
end

-- Quad (a, b, c, d in order around the polygon): one Part when it is a rectangle, else two triangles.
function Kit.quad(
	ctx: Ctx,
	cat: string,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3,
	thickness: number,
	style: Style,
	opts: PartOpts?
): { BasePart }
	local ab, bc = b - a, c - b
	local out: { BasePart } = {}
	local parallelogram = ((b - a) - (c - d)).Magnitude < 0.05
	if parallelogram and ab.Magnitude > 1e-3 and bc.Magnitude > 1e-3 and math.abs(ab.Unit:Dot(bc.Unit)) < 0.02 then
		local center = (a + b + c + d) / 4
		local xDir = ab.Unit
		local zDir = bc.Unit
		local up = zDir:Cross(xDir)
		if up.Y < 0 then
			up = -up
		end
		local cf = CFrame.fromMatrix(center - up.Unit * (thickness / 2), xDir, up.Unit)
		table.insert(out, Kit.part(ctx, cat, Vector3.new(ab.Magnitude, thickness, bc.Magnitude), cf, style, opts))
		return out
	end
	for _, w in Kit.triangle(ctx, cat, a, b, c, thickness, style, opts) do
		table.insert(out, w)
	end
	for _, w in Kit.triangle(ctx, cat, a, c, d, thickness, style, opts) do
		table.insert(out, w)
	end
	return out
end

-- A Texture on a part face.
function Kit.texture(
	p: BasePart,
	image: string,
	face: Enum.NormalId,
	tileU: number,
	tileV: number,
	offU: number?,
	offV: number?,
	color: Color3?
): Texture
	local t = Instance.new("Texture")
	t.Texture = image
	t.Face = face
	t.StudsPerTileU = tileU
	t.StudsPerTileV = tileV
	t.OffsetStudsU = offU or 0
	t.OffsetStudsV = offV or 0
	if color then
		t.Color3 = color
	end
	t.Parent = p
	return t
end

-- Night glow contract (LightingService): DayColor/DayMaterial <-> NightColor/NightMaterial, tag "NightGlow".
function Kit.nightGlow(p: BasePart, nightColor: Color3)
	p:SetAttribute("DayColor", p.Color)
	p:SetAttribute("DayMaterial", p.Material.Name)
	p:SetAttribute("NightColor", nightColor)
	p:SetAttribute("NightMaterial", "Neon")
	CollectionService:AddTag(p, "NightGlow")
end

-- Deterministic 0..1 hash of integers (Util/WorldGen.hash).
Kit.hash = WorldGen.hash

return Kit
