--!strict
-- CarBuilder: builds every car in Hotwire City procedurally from Parts (no meshes) in a bold cartoon style.
--
-- MODEL CONTRACT (docs/SPEC.md §8) — VehicleService, VehicleController, WheelAnimator, GarageService,
-- DealershipService, PoliceService and the Index UI all depend on these names/classes:
--   * PrimaryPart "Chassis": invisible box, the ONLY collidable body part. Model pivot = Chassis CFrame.
--   * Attachments "WheelFL" / "WheelFR" / "WheelRL" / "WheelRR" in Chassis at the wheel hub centers (built pose).
--   * Visual wheels "Wheel_FL".. (Cylinder Parts, axis = local X) with Welds "WheelWeld_FL".. parented to the
--     Chassis (Part0 = Chassis, Part1 = wheel, C1 = identity) so WheelAnimator can animate C0. Rims ("Rim_FL"..)
--     are WeldConstraint-ed to their wheel, so they follow any C0 change.
--   * "DriverSeat" VehicleSeat (Disabled, CanTouch=false, MaxSpeed/Torque/TurnSpeed=0, no HUD, invisible).
--   * Two invisible collidable Ball "BumpStop"s under the axles (bottoms 0.25 above the ground in the built pose).
--     They only carry a car that rests WITHOUT a VehicleController: a running controller makes them non-collidable
--     (they sit below the 0.6 curb and would snag every curb) and restores them on destroy.
--     DriverSeat + BumpStops are omitted when opts.forDisplay = true (garage/dealer/Index display cars).
--   * Every other part: CanCollide/CanQuery/CanTouch=false, Massless, unanchored, WeldConstraint to Chassis.
--   * Paint attribute on paintable parts: "primary" | "accent" | "glass". Primary parts also store
--     "BaseColor"/"BaseMaterial" so applyMutation(model, "None") can restore them.
--   * Diamond/Galaxy: a ParticleEmitter CarBuilder.SPARKLES_NAME on the biggest primary part, or the biggest shell
--     part on HeroMesh cars (clients gate it by distance, WheelAnimator).
--   * Lights: "Headlight" (neon, child SpotLight "Beam" disabled by default), "Taillight" (neon red);
--     police: "SirenRed" / "SirenBlue" (neon). Extras: "Blinker", "TaxiSign", "RoofLight", "Beacon",
--     "Thruster", "HoverGlow", "Underglow" (all neon).
--   * Model attributes: RideHeight (pivot height above ground in the built pose), WheelRadius, Length, Width,
--     Height, Style, CarId, Mutation, BodyCenter (Vector3: x/z center of the visible body relative to the chassis, y 0).
--     Model.ModelStreamingMode = Atomic. Server-built models are not tagged; models built on a client carry the
--     CollectionService tag CarBuilder.CLIENT_TAG ("ClientCar") so AssetClient can re-skin them late.
--   * HERO SHELLS (docs/ART_PASS.md AP1): build/buildDef end with applyShell(model). When the template
--     ReplicatedStorage.AssetLibrary.Hero[CarId] exists (police: "police_unit"), its clone becomes the Model child
--     CarBuilder.SHELL_NAME ("HeroShell"): scaled to Length (uniformly shrunk if wider than Width x 1.15), bottom on the
--     ground plane under the chassis (SHELL_LIFT: hover car floats), centered on BodyCenter, every part unanchored /
--     Massless / CanCollide, CanQuery, CanTouch false and WeldConstraint-ed to the Chassis. The procedural visuals stay
--     but get Transparency 1 (their SurfaceGuis are disabled; the original value is kept in attribute "ShellHidden")
--     so Headlight beams, wheel welds and attachments keep working; the police unit's SirenRed/SirenBlue stay visible,
--     raised onto the shell roof (other cars hide theirs: the mesh has its own lightbar). Open-top shells
--     (SHELL_SEAT_DROP) lower the DriverSeat into the mesh's seat. Model attributes HeroMesh = true and ShellHeight
--     (shell roof above the ground). No template (Lune harness, failed or not-yet-loaded asset) = no-op: the
--     procedural car is the fallback. removeShell(model) undoes it.
--
-- BUILT POSE: the ground plane is y = 0, the car is centered on x/z and faces -Z (pivot LookVector).
-- Wheels rest on the ground; the chassis center sits RideHeight above it. Spawn with
--   model:PivotTo(groundCFrame * CFrame.new(0, model:GetAttribute("RideHeight") + 0.3, 0))
--
-- Pure instance construction (harness-compatible, see SPEC §10): no yields, deterministic. The only services touched
-- are read-only lookups (ReplicatedStorage.AssetLibrary for shells, RunService:IsClient for the client tag).

local Shared = script.Parent.Parent
local Cars = require(Shared.Config.Cars)
local Rarity = require(Shared.Config.Rarity)

type CarDef = Cars.CarDef
type MutationId = Rarity.MutationId

export type BuildOpts = { forDisplay: boolean? }
export type StyleDims = { length: number, width: number, height: number, wheelRadius: number }

type Look = {
	color: Color3,
	material: Enum.Material,
	paint: string?,
	transparency: number?,
	reflectance: number?,
}

type Variant = { [string]: any }

type Looks = {
	primary: Look,
	accent: Look,
	accentNeon: Look,
	rim: Look, -- accent, or chrome when the accent is too dark to read against a tire
	glass: Look,
	tire: Look,
	chrome: Look,
	dark: Look,
	black: Look,
	white: Look,
	head: Look,
	tail: Look,
	hidden: Look,
}

type Ctx = {
	def: CarDef,
	model: Model,
	forDisplay: boolean,
	chassis: Part?,
	parts: { BasePart },
	weldTo: { [BasePart]: BasePart },
	noWeld: { [BasePart]: boolean },
	looks: Looks,
	variant: Variant,
	wheelRadius: number,
	axles: { number },
	seat: Vector3?, -- (x, seat TOP y, z)
}

type Facing = "F" | "B" | "L" | "R"
type Axis = "X" | "Y" | "Z"
type Shape = "Block" | "Wedge" | "Cyl" | "Ball"

-- Road-car body recipe (z stations run front (-) to back (+); y is height above ground).
type RoadSpec = {
	L: number,
	W: number,
	r: number,
	tw: number,
	twR: number?,
	axleF: number,
	axleR: number,
	wheelOut: number?,
	bodyBot: number,
	beltY: number,
	noseY: number?,
	tailY: number?,
	cabF: number,
	cabFT: number,
	cabRT: number,
	cabR: number,
	roofY: number,
	roofT: number?,
	cabInset: number?,
	pillars: number?,
	rearGlass: boolean?,
	roofLook: Look?,
	rim: Look?,
	rimScale: number?,
	hiddenWheels: boolean?,
	bumper: Look?,
	grille: Look?,
	flare: Look?,
	archLift: number?,
	mirrors: boolean?,
	headW: number?,
	headH: number?,
	headInset: number?,
	headY: number?,
	roundHeads: boolean?,
	tailW: number?,
	tailH: number?,
	tailBar: boolean?,
	mass: number,
	chassisBot: number?,
	chassisH: number?,
	seatX: number?,
	seatTop: number?,
	seatZ: number?,
}

type Stations = {
	hl: number,
	W: number,
	beltY: number,
	roofY: number,
	roofBot: number,
	Wc: number,
	lowY: number,
	noseY: number,
	tailY: number,
	headY: number,
	headX: number,
	cabF: number,
	cabR: number,
	hoodY: (z: number) -> number, -- hood surface height at z (front of the windshield)
}

local CarBuilder = {}

local V = Vector3.new
local PI = math.pi
local SMOOTH = Enum.Material.SmoothPlastic
local NEON = Enum.Material.Neon

local SPARKLES_NAME = "MutationSparkles"
CarBuilder.SPARKLES_NAME = SPARKLES_NAME
local SPARKLES_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local WHEEL_KEYS = { "FL", "FR", "RL", "RR" }
local BUMPSTOP_SIZE = 1 -- ball diameter (radius 0.5)
local BUMPSTOP_CLEARANCE = 0.25 -- bump-stop bottom height above the ground in the built pose

local SHELL_NAME = "HeroShell"
CarBuilder.SHELL_NAME = SHELL_NAME
local CLIENT_TAG = "ClientCar"
CarBuilder.CLIENT_TAG = CLIENT_TAG
local SHELL_WIDTH_SLACK = 1.15 -- a shell may be this much wider than the procedural body before it is scaled down
local SIREN_GAP = 0.05 -- police sirens sit this far above the shell roof
local HIDDEN_ATTR = "ShellHidden" -- procedural part / decal hidden by applyShell: its old Transparency (guis: true)
local PRE_SHELL_ATTR = "PreShellOffset" -- siren CFrame relative to the chassis before applyShell raised it
local STASH_NAME = "ShellStash" -- Folder parking a shell part's SurfaceAppearance while a mutation hides the texture
-- direct children applyShell never hides (physics / invisible parts); the police unit also keeps its siren lights
-- (EffectsController flashes them). Other police-style cars (retired_cruiser) wear the mesh's own static lightbar.
local SHELL_KEEP = { Chassis = true, DriverSeat = true, BumpStop = true }
local SIREN_NAMES = { SirenRed = true, SirenBlue = true }
-- Open-top shells whose seat sits lower than the procedural body's: DriverSeat drop (studs) so the rider sits in
-- the mesh's seat instead of hovering above it (measured with tools/shell_lineup.py; skipped while occupied).
local SHELL_SEAT_DROP: { [string]: number } = {
	toilet_turbo = 0.8,
	rubber_ducky = 1.2,
}
-- Shells that float instead of standing on the ground (studs above it): the hover car's pods hover like its glow.
local SHELL_LIFT: { [string]: number } = {
	hover_car = 0.8,
}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local COLORS = {
	tire = rgb(36, 36, 42),
	glass = rgb(34, 50, 78),
	head = rgb(255, 246, 212),
	tail = rgb(255, 36, 56),
	chrome = rgb(214, 218, 228),
	dark = rgb(48, 50, 58),
	black = rgb(22, 22, 26),
	white = rgb(250, 250, 252),
	beam = rgb(255, 240, 205),
}

local function look(color: Color3, material: Enum.Material?, paint: string?, transparency: number?): Look
	return { color = color, material = material or SMOOTH, paint = paint, transparency = transparency }
end

local function materialByName(name: string?, fallback: Enum.Material): Enum.Material
	if not name then
		return fallback
	end
	local ok, mat = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	if ok and typeof(mat) == "EnumItem" then
		return mat :: any
	end
	return fallback
end

-- Per-car flourishes on top of the shared style silhouettes (keyed by car id).
local VARIANTS: { [string]: Variant } = {
	rustbucket = { bodyMaterial = "CorrodedMetal", rust = true },
	mini_bean = { roofAccent = true },
	hot_hatch = { spoiler = true, stripes = true },
	grandma_sedan = { blinker = true, whitewalls = true, roofAccent = true },
	yellow_cab = { label = "TAXI" },
	pizza_van = { pizza = true, label = "PIZZA" },
	bull_charger = { horns = true },
	stallion_gt = { doubleStripe = true },
	neon_drift = { neonAccent = true, underglow = true },
	retired_cruiser = { label = "RETIRED" },
	police_unit = { label = "POLICE" },
	gold_rush = { bodyMaterial = "Foil" },
	midnight_phantom = { neonAccent = true },
	night_raven = { batFins = true },
	diamond_dragster = { bodyMaterial = "Glass", underglow = true },
	bank_truck = { label = "BANK" },
	ice_cream = { label = "ICE CREAM" },
}

local function makeLooks(def: CarDef, variant: Variant): Looks
	local bodyMat = materialByName(variant.bodyMaterial, SMOOTH)
	local accentMat = if variant.neonAccent then NEON else SMOOTH
	local a = def.accent
	local accentReadable = 0.299 * a.R + 0.587 * a.G + 0.114 * a.B >= 0.2
	local chrome: Look = { color = COLORS.chrome, material = SMOOTH, reflectance = 0.15 }
	return {
		primary = look(def.color, bodyMat, "primary"),
		accent = look(def.accent, accentMat, "accent"),
		accentNeon = look(def.accent, NEON, "accent"),
		rim = if accentReadable then look(def.accent, accentMat, "accent") else chrome,
		glass = look(COLORS.glass, Enum.Material.Glass, "glass", 0.3),
		tire = look(COLORS.tire),
		chrome = chrome,
		dark = look(COLORS.dark),
		black = look(COLORS.black),
		white = look(COLORS.white),
		head = look(COLORS.head, NEON),
		tail = look(COLORS.tail, NEON),
		hidden = look(COLORS.tire, SMOOTH, nil, 1),
	}
end

------------------------------------------------------------------------------------------------------------------
-- Part helpers (all positions are in the built pose: ground y = 0, front = -Z)
------------------------------------------------------------------------------------------------------------------

local function addPart(ctx: Ctx, shape: Shape, name: string, size: Vector3, cf: CFrame, lk: Look): BasePart
	local part: BasePart
	if shape == "Wedge" then
		part = Instance.new("WedgePart")
	else
		local p = Instance.new("Part")
		if shape == "Cyl" then
			p.Shape = Enum.PartType.Cylinder
		elseif shape == "Ball" then
			p.Shape = Enum.PartType.Ball
		end
		part = p
	end
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = lk.color
	part.Material = lk.material
	part.Transparency = lk.transparency or 0
	part.Reflectance = lk.reflectance or 0
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if lk.material == NEON or (lk.transparency or 0) >= 1 or math.max(size.X, size.Y, size.Z) < 1.2 then
		part.CastShadow = false
	end
	local paint = lk.paint
	if paint then
		part:SetAttribute("Paint", paint)
		if paint == "primary" then
			part:SetAttribute("BaseColor", lk.color)
			part:SetAttribute("BaseMaterial", lk.material.Name)
		end
	end
	part.Parent = ctx.model
	table.insert(ctx.parts, part)
	return part
end

-- Axis-aligned block filling [x0,x1] x [y0,y1] x [z0,z1].
local function span(
	ctx: Ctx,
	name: string,
	x0: number,
	x1: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number,
	lk: Look
): BasePart
	return addPart(
		ctx,
		"Block",
		name,
		V(x1 - x0, y1 - y0, z1 - z0),
		CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2),
		lk
	)
end

-- Block of width w centered on x = xc (default 0).
local function blk(
	ctx: Ctx,
	name: string,
	w: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number,
	lk: Look,
	xc: number?
): BasePart
	local x = xc or 0
	return span(ctx, name, x - w / 2, x + w / 2, y0, y1, z0, z1, lk)
end

local WEDGE_ROT: { [Facing]: CFrame } = {
	F = CFrame.new(),
	B = CFrame.Angles(0, PI, 0),
	R = CFrame.Angles(0, -PI / 2, 0),
	L = CFrame.Angles(0, PI / 2, 0),
}

-- Wedge filling the box [x0,x1]x[y0,y1]x[z0,z1]. Its slope faces `facing` (F = -Z front, B = +Z, L = -X, R = +X)
-- and up (down when `down`): e.g. facing "F" rises from the front-bottom edge to the back-top edge.
local function wspan(
	ctx: Ctx,
	name: string,
	x0: number,
	x1: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number,
	facing: Facing,
	lk: Look,
	down: boolean?
): BasePart
	local sx, sy, sz = x1 - x0, y1 - y0, z1 - z0
	local size = if facing == "L" or facing == "R" then V(sz, sy, sx) else V(sx, sy, sz)
	local rot = WEDGE_ROT[facing]
	if down then
		rot = rot * CFrame.Angles(0, 0, PI)
	end
	return addPart(ctx, "Wedge", name, size, CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2) * rot, lk)
end

local function wdg(
	ctx: Ctx,
	name: string,
	w: number,
	y0: number,
	y1: number,
	z0: number,
	z1: number,
	facing: Facing,
	lk: Look,
	xc: number?,
	down: boolean?
): BasePart
	local x = xc or 0
	return wspan(ctx, name, x - w / 2, x + w / 2, y0, y1, z0, z1, facing, lk, down)
end

local CYL_ROT: { [Axis]: CFrame } = {
	X = CFrame.new(),
	Y = CFrame.Angles(0, 0, PI / 2),
	Z = CFrame.Angles(0, PI / 2, 0),
}

local function cyl(ctx: Ctx, name: string, axis: Axis, length: number, dia: number, pos: Vector3, lk: Look): BasePart
	return addPart(ctx, "Cyl", name, V(length, dia, dia), CFrame.new(pos) * CYL_ROT[axis], lk)
end

local function ball(ctx: Ctx, name: string, dia: number, pos: Vector3, lk: Look): BasePart
	return addPart(ctx, "Ball", name, V(dia, dia, dia), CFrame.new(pos), lk)
end

-- Neon headlight with a disabled SpotLight facing -Z. round = Ball "bug-eye" (size.X = diameter); never rotated so
-- the SpotLight's Front face stays the car's front.
local function headlight(ctx: Ctx, size: Vector3, pos: Vector3, round: boolean?): BasePart
	local part = if round
		then addPart(ctx, "Ball", "Headlight", V(size.X, size.X, size.X), CFrame.new(pos), ctx.looks.head)
		else addPart(ctx, "Block", "Headlight", size, CFrame.new(pos), ctx.looks.head)
	local beam = Instance.new("SpotLight")
	beam.Name = "Beam"
	beam.Enabled = false
	beam.Face = Enum.NormalId.Front
	beam.Brightness = 3
	beam.Range = 45
	beam.Angle = 65
	beam.Shadows = false
	beam.Color = COLORS.beam
	beam.Parent = part
	return part
end

-- Cartoon text decal on one or more faces of a part (SurfaceGui; not a part, so free for the part budget).
local function label(part: BasePart, faces: { Enum.NormalId }, text: string, color: Color3, stroke: Color3?)
	for _, face in faces do
		local gui = Instance.new("SurfaceGui")
		gui.Name = "Label"
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.LightInfluence = 0.6
		gui.MaxDistance = 160
		gui.Parent = part
		local text_ = Instance.new("TextLabel")
		text_.Name = "Text"
		text_.Size = UDim2.fromScale(1, 1)
		text_.BackgroundTransparency = 1
		text_.Text = text
		text_.TextScaled = true
		text_.Font = Enum.Font.FredokaOne
		text_.TextColor3 = color
		if stroke then
			text_.TextStrokeColor3 = stroke
			text_.TextStrokeTransparency = 0.2
		else
			text_.TextStrokeTransparency = 1
		end
		text_.Parent = gui
	end
end

------------------------------------------------------------------------------------------------------------------
-- Chassis, wheels, seat, bump-stops
------------------------------------------------------------------------------------------------------------------

local function getChassis(ctx: Ctx): Part
	local chassis = ctx.chassis
	assert(chassis, "CarBuilder: style did not create a chassis")
	return chassis
end

-- Invisible collision hull for the lower body. `mass` is the target AssemblyMass (SPEC: ~900-3000).
local function setupChassis(ctx: Ctx, length: number, width: number, bottom: number, height: number, mass: number): Part
	local c = Instance.new("Part")
	c.Name = "Chassis"
	c.Size = V(width, height, length)
	c.CFrame = CFrame.new(0, bottom + height / 2, 0)
	c.Transparency = 1
	c.Anchored = false
	c.CanCollide = true
	c.CanQuery = true
	c.CanTouch = true
	c.Massless = false
	c.CastShadow = false
	c.TopSurface = Enum.SurfaceType.Smooth
	c.BottomSurface = Enum.SurfaceType.Smooth
	local density = math.clamp(mass / (width * height * length), 0.7, 100)
	c.CustomPhysicalProperties = PhysicalProperties.new(density, 0.3, 0, 1, 1)
	c.Parent = ctx.model
	ctx.model.PrimaryPart = c
	ctx.chassis = c
	return c
end

type WheelSpec = {
	r: number,
	twF: number,
	twR: number,
	axleF: number,
	axleR: number,
	trackF: number, -- |x| of the front hubs
	trackR: number,
	rim: Look?,
	rimScale: number?,
	hidden: boolean?,
}

local function setupWheels(ctx: Ctx, w: WheelSpec)
	local chassis = getChassis(ctx)
	local origin = chassis.CFrame.Position
	ctx.wheelRadius = w.r
	ctx.axles = { w.axleF, w.axleR }
	for _, key in WHEEL_KEYS do
		local front = string.sub(key, 1, 1) == "F"
		local side = if string.sub(key, 2, 2) == "L" then -1 else 1
		local hub = V(side * (if front then w.trackF else w.trackR), w.r, if front then w.axleF else w.axleR)
		local tw = if front then w.twF else w.twR

		local att = Instance.new("Attachment")
		att.Name = "Wheel" .. key
		-- set both: identical in Roblox; the Lune harness stores them independently
		att.CFrame = CFrame.new(hub - origin)
		att.Position = hub - origin
		att.Parent = chassis

		local tire = addPart(
			ctx,
			"Cyl",
			"Wheel_" .. key,
			V(tw, w.r * 2, w.r * 2),
			CFrame.new(hub),
			if w.hidden then ctx.looks.hidden else ctx.looks.tire
		)
		ctx.noWeld[tire] = true
		local weld = Instance.new("Weld")
		weld.Name = "WheelWeld_" .. key
		weld.Part0 = chassis
		weld.Part1 = tire
		weld.C0 = CFrame.new(hub - origin)
		weld.C1 = CFrame.new()
		weld.Parent = chassis

		local rimLook = w.rim
		if rimLook and not w.hidden then
			local rim = cyl(ctx, "Rim_" .. key, "X", tw + 0.12, w.r * 2 * (w.rimScale or 0.56), hub, rimLook)
			ctx.weldTo[rim] = tire
		end
	end
end

local function setupSeat(ctx: Ctx)
	local s = ctx.seat or V(-1.5, 1.5, 0)
	local seat = Instance.new("VehicleSeat")
	seat.Name = "DriverSeat"
	seat.Size = V(2, 0.3, 2)
	seat.CFrame = CFrame.new(s.X, s.Y - 0.15, s.Z)
	seat.Transparency = 1
	seat.Anchored = false
	seat.CanCollide = false
	seat.CanQuery = false
	seat.CanTouch = false
	seat.Massless = true
	seat.CastShadow = false
	seat.Disabled = true
	seat.MaxSpeed = 0
	seat.Torque = 0
	seat.TurnSpeed = 0
	seat.HeadsUpDisplay = false
	seat.TopSurface = Enum.SurfaceType.Smooth
	seat.BottomSurface = Enum.SurfaceType.Smooth
	seat.Parent = ctx.model
	table.insert(ctx.parts, seat)
end

local function setupBumpStops(ctx: Ctx)
	for _, z in ctx.axles do
		local stop = Instance.new("Part")
		stop.Name = "BumpStop"
		stop.Shape = Enum.PartType.Ball
		stop.Size = V(BUMPSTOP_SIZE, BUMPSTOP_SIZE, BUMPSTOP_SIZE)
		stop.CFrame = CFrame.new(0, BUMPSTOP_CLEARANCE + BUMPSTOP_SIZE / 2, z)
		stop.Transparency = 1
		stop.Anchored = false
		stop.CanCollide = true
		stop.CanQuery = false
		stop.CanTouch = false
		stop.Massless = true
		stop.CastShadow = false
		stop.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0, 1, 1)
		stop.Parent = ctx.model
		table.insert(ctx.parts, stop)
	end
end

local function weldAll(ctx: Ctx)
	local chassis = getChassis(ctx)
	for _, part in ctx.parts do
		if not ctx.noWeld[part] then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "Weld"
			weld.Part0 = ctx.weldTo[part] or chassis
			weld.Part1 = part
			weld.Parent = part
		end
	end
end

-- World-space AABB of the visible parts.
local function measure(parts: { BasePart }): (Vector3, Vector3)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, p in parts do
		if p.Transparency < 1 then
			local cf = p.CFrame
			local h = p.Size / 2
			local rx, ry, rz = cf.RightVector, cf.UpVector, cf.LookVector
			local ex = math.abs(rx.X) * h.X + math.abs(ry.X) * h.Y + math.abs(rz.X) * h.Z
			local ey = math.abs(rx.Y) * h.X + math.abs(ry.Y) * h.Y + math.abs(rz.Y) * h.Z
			local ez = math.abs(rx.Z) * h.X + math.abs(ry.Z) * h.Y + math.abs(rz.Z) * h.Z
			local c = cf.Position
			minX, maxX = math.min(minX, c.X - ex), math.max(maxX, c.X + ex)
			minY, maxY = math.min(minY, c.Y - ey), math.max(maxY, c.Y + ey)
			minZ, maxZ = math.min(minZ, c.Z - ez), math.max(maxZ, c.Z + ez)
		end
	end
	if minX == math.huge then
		return Vector3.zero, Vector3.zero
	end
	return V(minX, minY, minZ), V(maxX, maxY, maxZ)
end

------------------------------------------------------------------------------------------------------------------
-- Generic road car: lower body + greenhouse + lights + trim. Most styles start here and add personality.
------------------------------------------------------------------------------------------------------------------

-- Rounded wheel arches: an off-center cylinder tucked just inside each tire's outer face. From the side it shows as
-- a crescent hugging the top of the tire; from above it reads as a chunky rounded fender bulge.
local function wheelArches(
	ctx: Ctx,
	outerX: number,
	axles: { number },
	r: number,
	depth: number,
	lk: Look,
	lift: number?
)
	local rad = r + 0.15
	local cy = 2 * r + (lift or 0.45) - rad
	for _, az in axles do
		for _, sx in { -1, 1 } do
			cyl(ctx, "Arch", "X", depth, rad * 2, V(sx * (outerX - 0.05 - depth / 2), cy, az), lk)
		end
	end
end

local function roadCar(ctx: Ctx, s: RoadSpec): Stations
	local W, r = s.W, s.r
	local hl = s.L / 2
	local beltY = s.beltY
	local noseY = math.min(s.noseY or beltY, beltY)
	local tailY = math.min(s.tailY or beltY, beltY)
	local lowY = math.min(noseY, tailY)
	local roofT = s.roofT or 0.4
	local roofBot = s.roofY - roofT
	local Wc = W - 2 * (s.cabInset or 0.45)
	local P, G = ctx.looks.primary, ctx.looks.glass
	local roofLook = s.roofLook or P

	setupChassis(ctx, s.L - 0.8, W - 0.6, s.chassisBot or 0.9, s.chassisH or 1.8, s.mass)
	local wheelOut = s.wheelOut or 0.2
	local twR = s.twR or s.tw
	setupWheels(ctx, {
		r = r,
		twF = s.tw,
		twR = twR,
		axleF = s.axleF,
		axleR = s.axleR,
		trackF = W / 2 + wheelOut - s.tw / 2,
		trackR = W / 2 + wheelOut - twR / 2,
		rim = s.rim,
		rimScale = s.rimScale,
		hidden = s.hiddenWheels,
	})

	-- Lower body: base slab, hood (wedge if the nose is lower than the belt line), cabin sides, rear deck.
	blk(ctx, "Body", W, s.bodyBot, lowY, -hl, hl, P)
	local frontEnd = if noseY < beltY then s.cabF else -hl
	local rearStart = if tailY < beltY then s.cabR else hl
	if beltY > lowY + 0.01 then
		blk(ctx, "Door", W, lowY, beltY, frontEnd, rearStart, P)
	end
	if noseY < beltY then
		if noseY > lowY + 0.01 then
			blk(ctx, "Nose", W, lowY, noseY, -hl, s.cabF, P)
		end
		wdg(ctx, "Hood", W, noseY, beltY, -hl, s.cabF, "F", P)
	end
	if tailY < beltY then
		if tailY > lowY + 0.01 then
			blk(ctx, "Tail", W, lowY, tailY, s.cabR, hl, P)
		end
		wdg(ctx, "Deck", W, tailY, beltY, s.cabR, hl, "B", P)
	end

	-- Greenhouse: windshield, side windows, rear window, roof with a little overhang, pillars.
	wdg(ctx, "Windshield", Wc, beltY, roofBot, s.cabF, s.cabFT, "F", G)
	blk(ctx, "Windows", Wc, beltY, roofBot, s.cabFT, s.cabRT, G)
	if s.cabR > s.cabRT + 0.05 then
		wdg(ctx, "RearWindow", Wc, beltY, roofBot, s.cabRT, s.cabR, "B", if s.rearGlass == false then P else G)
	end
	blk(ctx, "Roof", Wc + 0.2, roofBot, s.roofY, s.cabFT - 0.15, s.cabRT + 0.15, roofLook)
	local pillars = s.pillars or 1
	for i = 1, pillars do
		local z = s.cabFT + (s.cabRT - s.cabFT) * i / (pillars + 1)
		blk(ctx, "Pillar", Wc + 0.08, beltY, roofBot, z - 0.18, z + 0.18, roofLook)
	end

	-- Lights
	local headY = s.headY or (noseY - 0.42)
	local hw, hh = s.headW or 1.3, s.headH or 0.5
	local hx = W / 2 - (s.headInset or 0.95)
	for _, sx in { -1, 1 } do
		if s.roundHeads then
			headlight(ctx, V(hw, hw, hw), V(sx * hx, headY, -hl + 0.1), true)
		else
			headlight(ctx, V(hw, hh, 0.3), V(sx * hx, headY, -hl - 0.06))
		end
	end
	local tailYc = tailY - 0.4
	if s.tailBar then
		span(
			ctx,
			"Taillight",
			-W / 2 + 0.6,
			W / 2 - 0.6,
			tailYc - 0.14,
			tailYc + 0.14,
			hl - 0.1,
			hl + 0.07,
			ctx.looks.tail
		)
	else
		local th = s.tailH or 0.5
		for _, sx in { -1, 1 } do
			blk(
				ctx,
				"Taillight",
				s.tailW or 1.2,
				tailYc - th / 2,
				tailYc + th / 2,
				hl - 0.1,
				hl + 0.07,
				ctx.looks.tail,
				sx * hx
			)
		end
	end

	-- Trim
	local bumper = s.bumper
	if bumper then
		blk(ctx, "BumperF", W + 0.1, s.bodyBot - 0.05, s.bodyBot + 0.5, -hl - 0.3, -hl + 0.3, bumper)
		blk(ctx, "BumperR", W + 0.1, s.bodyBot - 0.05, s.bodyBot + 0.5, hl - 0.3, hl + 0.3, bumper)
	end
	local grille = s.grille
	if grille then
		local gw = math.max(2 * (hx - hw / 2) - 0.3, 1)
		blk(ctx, "Grille", gw, headY - 0.3, headY + 0.3, -hl - 0.06, -hl + 0.1, grille)
	end
	local flare = s.flare
	if flare then
		wheelArches(ctx, W / 2 + wheelOut, { s.axleF, s.axleR }, r, math.max(s.tw, twR) + 0.35, flare, s.archLift)
	end
	if s.mirrors then
		for _, sx in { -1, 1 } do
			blk(ctx, "Mirror", 0.5, beltY + 0.15, beltY + 0.55, s.cabF + 0.35, s.cabF + 0.85, P, sx * (Wc / 2 + 0.3))
		end
	end

	-- Driver seat (left side; right-hand traffic). Seat top low enough that a seated avatar's head fits.
	local seatTop = s.seatTop or math.clamp(roofBot - 3.45, 0.45, beltY - 0.2)
	ctx.seat = V(s.seatX or -(Wc / 4 + 0.15), seatTop, s.seatZ or (s.cabFT + (s.cabRT - s.cabFT) * 0.4))

	return {
		hl = hl,
		W = W,
		beltY = beltY,
		roofY = s.roofY,
		roofBot = roofBot,
		Wc = Wc,
		lowY = lowY,
		noseY = noseY,
		tailY = tailY,
		headY = headY,
		headX = hx,
		cabF = s.cabF,
		cabR = s.cabR,
		hoodY = function(z: number): number
			local t = math.clamp((z + hl) / math.max(s.cabF + hl, 0.01), 0, 1)
			return noseY + (beltY - noseY) * t
		end,
	}
end

local function merge(base: { [string]: any }, over: { [string]: any }?): RoadSpec
	if over then
		for k, v in over do
			base[k] = v
		end
	end
	return (base :: any) :: RoadSpec
end

local function sedanSpec(ctx: Ctx, over: { [string]: any }?): RoadSpec
	local L = ctx.looks
	return merge({
		L = 13.4,
		W = 6.8,
		r = 1.32,
		tw = 1.1,
		axleF = -4.25,
		axleR = 4.25,
		bodyBot = 0.85,
		beltY = 2.85,
		noseY = 2.55,
		tailY = 2.55,
		cabF = -2.3,
		cabFT = -0.85,
		cabRT = 2.7,
		cabR = 3.9,
		roofY = 5.55,
		roofT = 0.4,
		cabInset = 0.45,
		pillars = 1,
		rim = L.chrome,
		bumper = L.chrome,
		grille = L.chrome,
		mirrors = true,
		mass = 1250,
	}, over)
end

local function hyperSpec(ctx: Ctx, over: { [string]: any }?): RoadSpec
	local L = ctx.looks
	return merge({
		L = 15.0,
		W = 7.9,
		r = 1.4,
		tw = 1.35,
		twR = 1.7,
		axleF = -4.8,
		axleR = 4.6,
		bodyBot = 0.65,
		beltY = 2.1,
		noseY = 1.1,
		tailY = 2.1,
		cabF = -2.0,
		cabFT = -0.35,
		cabRT = 1.0,
		cabR = 3.4,
		roofY = 3.95,
		roofT = 0.3,
		cabInset = 1.45,
		pillars = 0,
		rim = L.rim,
		rimScale = 0.62,
		flare = L.primary,
		headW = 1.7,
		headH = 0.28,
		headInset = 1.2,
		tailBar = true,
		mass = 1400,
		chassisBot = 0.75,
		chassisH = 1.4,
	}, over)
end

-- Box-van body shared by the delivery van and the ice cream truck.
local function boxVan(ctx: Ctx, roofY: number, mass: number): Stations
	local L = ctx.looks
	local P, G = L.primary, L.glass
	local len, W = 13.6, 7.0
	local hl = len / 2
	local beltY = 3.0
	setupChassis(ctx, len - 0.8, W - 0.6, 0.9, 1.9, mass)
	setupWheels(ctx, {
		r = 1.35,
		twF = 1.15,
		twR = 1.15,
		axleF = -4.5,
		axleR = 4.4,
		trackF = W / 2 + 0.2 - 0.575,
		trackR = W / 2 + 0.2 - 0.575,
		rim = L.chrome,
	})
	blk(ctx, "Body", W, 0.85, beltY, -hl, hl, P)
	wdg(ctx, "Hood", W, beltY, 3.55, -hl, -4.9, "F", P)
	blk(ctx, "Door", W, beltY, 3.55, -4.9, -3.0, P)
	wdg(ctx, "Windshield", W - 0.5, 3.55, roofY - 0.5, -4.9, -3.0, "F", G)
	blk(ctx, "Cargo", W, beltY, roofY, -3.0, hl, P)
	blk(ctx, "Windows", W + 0.06, 3.9, roofY - 1.15, -2.9, -1.0, G)
	local hx = W / 2 - 0.95
	for _, sx in { -1, 1 } do
		headlight(ctx, V(1.3, 0.6, 0.3), V(sx * hx, 2.35, -hl - 0.06))
		blk(ctx, "Taillight", 0.7, 1.6, 3.4, hl - 0.1, hl + 0.07, L.tail, sx * (W / 2 - 0.5))
		blk(ctx, "Mirror", 0.5, 3.75, 4.35, -4.4, -3.9, P, sx * (W / 2 + 0.25))
	end
	blk(ctx, "BumperF", W + 0.1, 0.8, 1.35, -hl - 0.3, -hl + 0.3, L.dark)
	blk(ctx, "BumperR", W + 0.1, 0.8, 1.35, hl - 0.3, hl + 0.3, L.dark)
	blk(ctx, "Grille", 2.8, 2.05, 2.65, -hl - 0.06, -hl + 0.1, L.dark)
	ctx.seat = V(-1.55, roofY - 0.5 - 3.4, -2.2)
	return {
		hl = hl,
		W = W,
		beltY = beltY,
		roofY = roofY,
		roofBot = roofY,
		Wc = W,
		lowY = beltY,
		noseY = beltY,
		tailY = beltY,
		headY = 2.35,
		headX = hx,
		cabF = -4.9,
		cabR = -3.0,
		hoodY = function(_z: number): number
			return beltY
		end,
	}
end

------------------------------------------------------------------------------------------------------------------
-- Styles
------------------------------------------------------------------------------------------------------------------

-- Strip lying on the (possibly sloped) hood: stripes, vents. A thin wedge parallel to the hood surface.
local function onHood(
	ctx: Ctx,
	st: Stations,
	name: string,
	w: number,
	z0: number,
	z1: number,
	lk: Look,
	xc: number?
): BasePart
	local ya, yb = st.hoodY(z0) + 0.04, st.hoodY(z1) + 0.04
	if yb - ya < 0.02 then
		return blk(ctx, name, w, ya - 0.04, ya, z0, z1, lk, xc)
	end
	return wdg(ctx, name, w, ya, yb, z0, z1, "F", lk, xc)
end

local STYLES: { [string]: (ctx: Ctx) -> () } = {}

STYLES.compact = function(ctx: Ctx)
	local v, L = ctx.variant, ctx.looks
	local st = roadCar(ctx, {
		L = 11.2,
		W = 6.6,
		r = 1.35,
		tw = 1.15,
		axleF = -3.6,
		axleR = 3.55,
		bodyBot = 0.8,
		beltY = 2.8,
		noseY = 2.4,
		cabF = -2.5,
		cabFT = -1.1,
		cabRT = 3.75,
		cabR = 4.5,
		roofY = 5.6,
		roofT = 0.45,
		cabInset = 0.4,
		pillars = 1,
		roofLook = if v.roofAccent then L.accent else nil,
		rim = L.chrome,
		bumper = L.dark,
		grille = L.dark,
		flare = L.primary,
		mirrors = true,
		headW = 1.05,
		headH = 0.6,
		headY = 2.0,
		headInset = 1.15,
		roundHeads = true,
		mass = 950,
	})
	local hl = st.hl
	if v.stripes then
		for _, x in { -0.45, 0.45 } do
			onHood(ctx, st, "Stripe", 0.5, -hl - 0.01, st.cabF, L.accent, x)
			blk(ctx, "Stripe", 0.5, st.roofY, st.roofY + 0.04, -1.25, 3.9, L.accent, x)
		end
	end
	if v.spoiler then
		blk(ctx, "Spoiler", st.Wc + 0.2, st.roofY - 0.2, st.roofY + 0.05, 3.9, 4.9, L.accent)
	end
	if v.rust then
		-- "Held together by duct tape and hope": primer-grey replacement door, rust spots, duct-tape X, odd rim
		blk(ctx, "SpareDoor", st.W + 0.06, 1.05, st.beltY - 0.12, -0.95, 1.5, look(rgb(120, 150, 150)))
		blk(ctx, "Rust", st.W + 0.08, 1.3, 2.0, 2.4, 3.6, L.accent)
		onHood(ctx, st, "Rust", 1.6, -4.6, -3.2, L.accent, 1.2)
		local tape = look(rgb(190, 192, 198))
		for _, a in { 0.55, -0.55 } do
			addPart(
				ctx,
				"Block",
				"DuctTape",
				V(st.W + 0.1, 0.32, 1.9),
				CFrame.new(0, 1.85, -3.0) * CFrame.Angles(a, 0, 0),
				tape
			)
		end
		for _, part in ctx.parts do
			if part.Name == "Rim_RL" then
				part.Color = rgb(250, 250, 250) -- mismatched spare
			elseif string.sub(part.Name, 1, 4) == "Rim_" then
				part.Color = rgb(120, 84, 60)
			end
		end
	end
end

STYLES.sedan = function(ctx: Ctx)
	local v, L = ctx.variant, ctx.looks
	local st = roadCar(
		ctx,
		sedanSpec(ctx, {
			rim = if v.whitewalls then L.white else L.chrome,
			rimScale = if v.whitewalls then 0.78 else 0.56,
			roofLook = if v.roofAccent then L.accent else nil,
		})
	)
	if v.blinker then
		-- "Turn signal has been on since 1994."
		blk(
			ctx,
			"Blinker",
			0.45,
			st.headY - 0.25,
			st.headY + 0.25,
			-st.hl - 0.1,
			-st.hl + 0.1,
			look(rgb(255, 150, 20), NEON),
			-(st.W / 2 - 0.25)
		)
	end
end

STYLES.taxi = function(ctx: Ctx)
	local L = ctx.looks
	local st = roadCar(ctx, sedanSpec(ctx, { mirrors = false, bumper = L.dark }))
	-- checker band (black squares on the yellow body, both sides)
	local z0, z1, n = -st.hl + 0.9, st.hl - 0.9, 9
	local cell = (z1 - z0) / n
	for i = 0, n - 1, 2 do
		blk(ctx, "Checker", st.W + 0.06, 1.75, 2.25, z0 + i * cell, z0 + (i + 1) * cell, L.accent)
	end
	-- roof sign
	local cz = 0.9
	blk(ctx, "SignBase", 2.2, st.roofY, st.roofY + 0.2, cz - 0.45, cz + 0.45, L.dark)
	local sign =
		blk(ctx, "TaxiSign", 2.8, st.roofY + 0.2, st.roofY + 1.05, cz - 0.4, cz + 0.4, look(rgb(255, 236, 140), NEON))
	label(sign, { Enum.NormalId.Front, Enum.NormalId.Back }, ctx.variant.label or "TAXI", COLORS.black)
end

STYLES.van = function(ctx: Ctx)
	local v, L = ctx.variant, ctx.looks
	local st = boxVan(ctx, 7.0, 1700)
	local hl, W = st.hl, st.W
	local stripe = blk(ctx, "Stripe", W + 0.06, 3.45, 4.0, -0.9, hl - 0.25, L.accent)
	blk(ctx, "RearSplit", 0.14, 1.0, 6.7, hl - 0.05, hl + 0.04, L.dark)
	blk(ctx, "RearWindow", W - 2.0, 5.0, 6.4, hl - 0.05, hl + 0.05, L.glass)
	if v.label then
		label(stripe, { Enum.NormalId.Left, Enum.NormalId.Right }, v.label, COLORS.white, rgb(120, 20, 20))
	end
	if v.pizza then
		-- giant pizza slice sign on the roof (tip down), visible from both sides
		local cheese = look(rgb(255, 196, 64))
		local z, a, h, y0 = 1.6, 2.1, 3.0, st.roofY + 0.05
		local yc = y0 + h / 2
		addPart(ctx, "Wedge", "Pizza", V(0.4, h, a), CFrame.new(0, yc, z + a / 2) * CFrame.Angles(PI, 0, 0), cheese)
		addPart(ctx, "Wedge", "Pizza", V(0.4, h, a), CFrame.new(0, yc, z - a / 2) * CFrame.Angles(0, 0, PI), cheese)
		cyl(ctx, "Crust", "Z", 2 * a + 0.5, 0.95, V(0, y0 + h + 0.1, z), look(rgb(214, 140, 60)))
		local pep = look(rgb(200, 40, 35))
		cyl(ctx, "Pepperoni", "X", 0.5, 0.9, V(0, y0 + h - 0.75, z - 0.85), pep)
		cyl(ctx, "Pepperoni", "X", 0.5, 0.8, V(0, y0 + h - 0.9, z + 0.95), pep)
		cyl(ctx, "Pepperoni", "X", 0.5, 0.7, V(0, y0 + h - 1.85, z + 0.05), pep)
	end
end

STYLES.icecream = function(ctx: Ctx)
	local v, L = ctx.variant, ctx.looks
	local st = boxVan(ctx, 6.4, 1700)
	local hl, W, roofY = st.hl, st.W, st.roofY
	-- frosting roof trim
	blk(ctx, "Trim", W + 0.2, roofY - 0.1, roofY + 0.3, -3.1, hl + 0.1, L.accent)
	-- serving window + awning on the curb (right) side
	local window = span(ctx, "ServeWindow", W / 2 - 0.05, W / 2 + 0.07, 3.6, 5.3, -0.6, 3.6, L.dark)
	wspan(ctx, "Awning", W / 2, W / 2 + 0.85, 5.4, 6.0, -0.8, 3.8, "R", L.accent)
	if v.label then
		label(window, { Enum.NormalId.Right }, v.label, rgb(255, 120, 190), COLORS.white)
	end
	-- giant cone on the roof
	local cone = look(rgb(226, 170, 96))
	local z = -0.4
	cyl(ctx, "Cone", "Y", 0.9, 1.0, V(0, roofY + 0.45, z), cone)
	cyl(ctx, "Cone", "Y", 0.9, 1.8, V(0, roofY + 1.30, z), cone)
	cyl(ctx, "Cone", "Y", 0.9, 2.6, V(0, roofY + 2.15, z), cone)
	ball(ctx, "Scoop", 3.0, V(0, roofY + 3.30, z), L.primary)
	ball(ctx, "Drip", 0.7, V(1.0, roofY + 2.55, z - 0.75), L.primary)
	ball(ctx, "Drip", 0.55, V(-0.95, roofY + 2.45, z + 0.6), L.primary)
	ball(ctx, "Cherry", 0.75, V(0.15, roofY + 5.00, z), look(rgb(230, 20, 40)))
	ctx.seat = V(-1.55, roofY - 0.5 - 3.4, -2.2)
end

STYLES.pickup = function(ctx: Ctx)
	local L = ctx.looks
	local P, G = L.primary, L.glass
	local len, W = 14.4, 7.0
	local hl = len / 2
	setupChassis(ctx, len - 0.8, W - 0.6, 1.1, 1.9, 1800)
	setupWheels(ctx, {
		r = 1.5,
		twF = 1.3,
		twR = 1.3,
		axleF = -4.6,
		axleR = 4.6,
		trackF = W / 2 + 0.25 - 0.65,
		trackR = W / 2 + 0.25 - 0.65,
		rim = L.chrome,
		rimScale = 0.55,
	})
	local floorY, beltY, roofY = 2.45, 3.6, 6.4
	blk(ctx, "Body", W, 1.25, floorY, -hl, hl, P)
	local cabBack = 1.0
	blk(ctx, "Hood", W, floorY, beltY, -hl, cabBack, P)
	wdg(ctx, "Windshield", W - 0.9, beltY, roofY - 0.4, -2.7, -1.3, "F", G)
	blk(ctx, "Windows", W - 0.9, beltY, roofY - 0.4, -1.3, cabBack - 0.2, G)
	blk(ctx, "CabBack", W - 0.9, beltY, roofY - 0.4, cabBack - 0.2, cabBack, P)
	blk(ctx, "Roof", W - 0.7, roofY - 0.4, roofY, -1.45, cabBack + 0.05, P)
	-- open bed
	for _, sx in { -1, 1 } do
		blk(ctx, "BedWall", 0.35, floorY, beltY, cabBack, hl - 0.3, P, sx * (W / 2 - 0.175))
	end
	blk(ctx, "Tailgate", W, floorY, beltY, hl - 0.35, hl, L.accent)
	local dirt = look(L.accent.color, Enum.Material.Ground)
	ball(ctx, "Dirt", 4.4, V(-0.4, 2.3, 3.7), dirt)
	ball(ctx, "Dirt", 3.4, V(0.9, 2.5, 5.3), dirt)
	-- lights + trim
	local hx = W / 2 - 0.95
	for _, sx in { -1, 1 } do
		headlight(ctx, V(1.2, 0.6, 0.3), V(sx * hx, 3.0, -hl - 0.06))
		blk(ctx, "Taillight", 0.5, 2.6, 3.4, hl - 0.1, hl + 0.07, L.tail, sx * (W / 2 - 0.4))
		blk(ctx, "Mirror", 0.5, 3.75, 4.3, -2.4, -1.9, P, sx * (W / 2 - 0.2))
	end
	blk(ctx, "Grille", 2.6, 2.55, 3.45, -hl - 0.06, -hl + 0.1, L.chrome)
	blk(ctx, "BumperF", W + 0.2, 1.1, 1.8, -hl - 0.35, -hl + 0.3, L.chrome)
	blk(ctx, "BumperR", W + 0.2, 1.1, 1.8, hl - 0.3, hl + 0.35, L.chrome)
	wheelArches(ctx, W / 2 + 0.25, { -4.6, 4.6 }, 1.5, 1.65, L.dark, 0.35)
	blk(ctx, "RoofLight", 2.4, roofY, roofY + 0.3, -1.3, -0.95, look(rgb(255, 190, 40), NEON))
	ctx.seat = V(-1.5, roofY - 0.4 - 3.45, -0.35)
end

STYLES.muscle = function(ctx: Ctx)
	local v, L = ctx.variant, ctx.looks
	local st = roadCar(ctx, {
		L = 14.6,
		W = 7.2,
		r = 1.42,
		tw = 1.15,
		twR = 1.6,
		axleF = -4.7,
		axleR = 4.5,
		bodyBot = 0.85,
		beltY = 2.75,
		cabF = -0.9,
		cabFT = 0.45,
		cabRT = 2.85,
		cabR = 4.2,
		roofY = 4.95,
		roofT = 0.4,
		cabInset = 0.55,
		pillars = 0,
		rim = L.chrome,
		rimScale = 0.6,
		bumper = L.chrome,
		grille = L.dark,
		flare = L.primary,
		headW = 1.0,
		headH = 0.6,
		mass = 1500,
	})
	local hl, beltY = st.hl, st.beltY
	-- hood scoop
	blk(ctx, "Scoop", 1.9, beltY, beltY + 0.55, -3.4, -1.4, L.primary)
	blk(ctx, "ScoopIntake", 1.5, beltY + 0.1, beltY + 0.45, -3.46, -3.3, L.black)
	-- racing stripes over hood, roof and trunk
	local xs = if v.doubleStripe then { -0.55, 0.55 } else { 0 }
	local sw = if v.doubleStripe then 0.55 else 1.3
	for _, x in xs do
		blk(ctx, "Stripe", sw, beltY, beltY + 0.04, -hl - 0.01, -0.9, L.accent, x)
		blk(ctx, "Stripe", sw, st.roofY, st.roofY + 0.04, 0.3, 3.0, L.accent, x)
		blk(ctx, "Stripe", sw, beltY, beltY + 0.04, 4.2, hl + 0.01, L.accent, x)
	end
	wdg(ctx, "Ducktail", st.W, beltY, beltY + 0.4, hl - 1.0, hl, "F", L.primary)
	for _, sx in { -1, 1 } do
		cyl(ctx, "Exhaust", "Z", 1.0, 0.45, V(sx * 1.8, 0.95, hl + 0.2), L.chrome)
	end
	if v.horns then
		-- bull horns hood ornament
		local horn = look(rgb(245, 235, 210))
		local tip = look(rgb(70, 60, 50))
		for _, sx in { -1, 1 } do
			local base = CFrame.new(sx * 0.55, beltY + 0.35, -hl + 0.9) * CFrame.Angles(0, 0, sx * 0.5)
			addPart(ctx, "Cyl", "Horn", V(2.0, 0.6, 0.6), base * CFrame.new(sx * 0.9, 0, 0), horn)
			local tipCf = base * CFrame.new(sx * 1.9, 0, 0) * CFrame.Angles(0, 0, sx * 0.9)
			addPart(ctx, "Cyl", "HornTip", V(1.1, 0.42, 0.42), tipCf * CFrame.new(sx * 0.4, 0, 0), tip)
		end
	end
end

STYLES.sports = function(ctx: Ctx)
	local v, L = ctx.variant, ctx.looks
	local st = roadCar(ctx, {
		L = 14.2,
		W = 7.2,
		r = 1.35,
		tw = 1.2,
		twR = 1.45,
		axleF = -4.6,
		axleR = 4.4,
		bodyBot = 0.75,
		beltY = 2.45,
		noseY = 1.6,
		tailY = 2.25,
		cabF = -1.5,
		cabFT = 0.1,
		cabRT = 1.9,
		cabR = 4.6,
		roofY = 4.35,
		roofT = 0.35,
		cabInset = 0.65,
		pillars = 0,
		rim = L.rim,
		rimScale = 0.62,
		flare = L.primary,
		mirrors = true,
		headW = 1.5,
		headH = 0.4,
		headInset = 1.05,
		bumper = nil,
		mass = 1300,
		chassisBot = 0.8,
		chassisH = 1.6,
	})
	local hl, W = st.hl, st.W
	blk(ctx, "Splitter", W + 0.1, 0.62, 0.78, -hl - 0.35, -hl + 0.7, L.dark)
	blk(ctx, "Intake", W + 0.06, 1.15, 2.0, 2.0, 3.1, L.dark)
	for _, sx in { -1, 1 } do
		blk(ctx, "WingStrut", 0.25, st.tailY, st.tailY + 0.6, hl - 0.85, hl - 0.45, L.dark, sx * 2.3)
	end
	blk(ctx, "Wing", W - 0.4, st.tailY + 0.6, st.tailY + 0.82, hl - 1.2, hl - 0.15, L.accent)
	blk(ctx, "Diffuser", W - 1.4, 0.6, 1.0, hl - 0.2, hl + 0.2, L.dark)
	if v.underglow then
		blk(ctx, "Underglow", W - 1.2, 0.55, 0.68, -hl + 1.6, hl - 1.6, L.accentNeon)
	end
end

STYLES.suv = function(ctx: Ctx)
	local L = ctx.looks
	local st = roadCar(ctx, {
		L = 14.6,
		W = 7.4,
		r = 1.55,
		tw = 1.3,
		axleF = -4.6,
		axleR = 4.5,
		bodyBot = 1.2,
		beltY = 3.55,
		noseY = 3.25,
		cabF = -2.7,
		cabFT = -1.3,
		cabRT = 5.9,
		cabR = 6.5,
		roofY = 6.9,
		roofT = 0.45,
		cabInset = 0.45,
		pillars = 2,
		rim = L.chrome,
		rimScale = 0.55,
		bumper = L.accent,
		grille = L.dark,
		flare = L.accent,
		mirrors = true,
		headW = 1.3,
		headH = 0.6,
		mass = 1900,
		chassisBot = 1.15,
		chassisH = 2.0,
	})
	local hl, Wc, roofY = st.hl, st.Wc, st.roofY
	for _, sx in { -1, 1 } do
		blk(ctx, "RoofRail", 0.25, roofY, roofY + 0.35, -1.0, 5.6, L.accent, sx * (Wc / 2 - 0.3))
	end
	-- roof cargo box ("can I speak to your manager?" luggage)
	blk(ctx, "CargoBox", Wc - 2.0, roofY + 0.1, roofY + 1.0, 1.0, 4.6, L.accent)
	wdg(ctx, "CargoBoxNose", Wc - 2.0, roofY + 0.1, roofY + 1.0, 0.2, 1.0, "F", L.accent)
	-- spare wheel on the tailgate
	cyl(ctx, "SpareTire", "Z", 0.8, 2.6, V(0, 3.1, hl + 0.4), L.tire)
	cyl(ctx, "SpareCover", "Z", 0.9, 1.7, V(0, 3.1, hl + 0.45), L.primary)
end

STYLES.limo = function(ctx: Ctx)
	local L = ctx.looks
	local st = roadCar(
		ctx,
		sedanSpec(ctx, {
			L = 17.0,
			W = 7.0,
			r = 1.3,
			axleF = -6.1,
			axleR = 6.2,
			cabF = -4.4,
			cabFT = -2.9,
			cabRT = 5.4,
			cabR = 6.5,
			roofY = 5.4,
			pillars = 3,
			mass = 2200,
		})
	)
	local hl, Wc, roofY = st.hl, st.Wc, st.roofY
	blk(ctx, "ChromeStrip", st.W + 0.06, 1.75, 1.95, -hl + 1.0, hl - 1.0, L.accent)
	-- "Comes with a hot tub. Probably."
	blk(ctx, "HotTub", Wc - 1.2, roofY, roofY + 0.6, 1.4, 4.9, L.white)
	blk(ctx, "TubWater", Wc - 1.8, roofY + 0.45, roofY + 0.56, 1.7, 4.6, look(rgb(60, 200, 255), NEON))
	ctx.seat = V(-(Wc / 4 + 0.15), math.clamp(st.roofBot - 3.45, 0.45, 2.6), -1.6)
end

STYLES.police = function(ctx: Ctx)
	local v, L = ctx.variant, ctx.looks
	local st = roadCar(
		ctx,
		sedanSpec(ctx, {
			L = 13.8,
			W = 7.0,
			r = 1.35,
			axleF = -4.35,
			axleR = 4.35,
			cabF = -2.3,
			cabFT = -0.8,
			cabRT = 2.8,
			cabR = 3.9,
			rim = L.dark,
			rimScale = 0.6,
			bumper = L.dark,
			grille = L.dark,
			mass = 1500,
		})
	)
	local hl, roofY = st.hl, st.roofY
	-- two-tone doors
	local doors = blk(ctx, "Doors", st.W + 0.06, 1.05, st.beltY - 0.05, -0.9, 2.9, L.accent)
	if v.label then
		local textColor = if L.accent.color.R + L.accent.color.G + L.accent.color.B > 1.5
			then COLORS.black
			else COLORS.white
		label(doors, { Enum.NormalId.Left, Enum.NormalId.Right }, v.label, textColor)
	end
	-- lightbar
	blk(ctx, "LightbarBase", 3.8, roofY, roofY + 0.25, 0.3, 1.3, L.dark)
	blk(ctx, "SirenRed", 1.7, roofY + 0.25, roofY + 0.7, 0.4, 1.2, look(rgb(255, 30, 40), NEON), -0.92)
	blk(ctx, "SirenBlue", 1.7, roofY + 0.25, roofY + 0.7, 0.4, 1.2, look(rgb(30, 90, 255), NEON), 0.92)
	-- push bar
	blk(ctx, "PushBar", 3.4, 0.9, 2.1, -hl - 0.75, -hl - 0.35, L.black)
end

STYLES.super = function(ctx: Ctx)
	local L = ctx.looks
	local st = roadCar(ctx, {
		L = 15.0,
		W = 7.6,
		r = 1.4,
		tw = 1.3,
		twR = 1.6,
		axleF = -4.75,
		axleR = 4.6,
		bodyBot = 0.7,
		beltY = 2.35,
		noseY = 1.3,
		tailY = 2.1,
		cabF = -2.4,
		cabFT = -0.5,
		cabRT = 1.2,
		cabR = 4.4,
		rearGlass = false,
		roofY = 4.15,
		roofT = 0.32,
		cabInset = 0.95,
		pillars = 0,
		rim = L.rim,
		rimScale = 0.6,
		flare = L.primary,
		mirrors = true,
		headW = 1.6,
		headH = 0.32,
		headInset = 1.1,
		tailBar = true,
		mass = 1400,
		chassisBot = 0.8,
		chassisH = 1.5,
	})
	local hl, W = st.hl, st.W
	blk(ctx, "Splitter", W + 0.1, 0.58, 0.72, -hl - 0.35, -hl + 0.8, L.dark)
	blk(ctx, "Intake", W + 0.06, 1.1, 2.05, 1.5, 2.9, L.dark)
	wdg(ctx, "Spoiler", W - 0.6, st.beltY, st.beltY + 0.45, hl - 1.2, hl - 0.1, "F", L.accent)
	-- roof snorkel: a dark ram-air scoop running back from the roof over the engine cover
	blk(ctx, "RoofScoop", 1.7, st.roofY - 0.1, st.roofY + 0.4, 0.2, 2.6, L.dark)
	wdg(ctx, "RoofScoopLip", 1.7, st.roofY - 0.1, st.roofY + 0.4, -0.3, 0.2, "F", L.dark)
	blk(ctx, "Diffuser", W - 1.4, 0.55, 1.0, hl - 0.2, hl + 0.2, L.dark)
	for _, sx in { -1, 1 } do
		onHood(ctx, st, "HoodVent", 0.9, -4.9, -3.5, L.dark, sx * 1.4)
	end
end

local function hyperExtras(ctx: Ctx, st: Stations, wing: boolean)
	local v, L = ctx.variant, ctx.looks
	local hl, W = st.hl, st.W
	onHood(ctx, st, "Stripe", 1.1, -hl - 0.01, st.cabF, L.accent)
	blk(ctx, "Splitter", W + 0.2, 0.52, 0.66, -hl - 0.4, -hl + 0.9, L.dark)
	blk(ctx, "SideLine", W + 0.06, 1.45, 1.62, st.cabF, hl - 1.6, L.accent)
	blk(ctx, "Intake", W + 0.06, 0.95, 1.8, 1.3, 2.7, L.dark)
	blk(ctx, "Diffuser", W - 1.2, 0.55, 1.0, hl - 0.2, hl + 0.25, L.dark)
	if v.batFins then
		for _, sx in { -1, 1 } do
			wdg(ctx, "Fin", 0.3, st.tailY, st.tailY + 2.2, hl - 3.4, hl - 0.1, "F", L.primary, sx * 2.6)
		end
	elseif wing then
		for _, sx in { -1, 1 } do
			blk(ctx, "WingStrut", 0.25, st.tailY, st.tailY + 1.35, hl - 1.1, hl - 0.6, L.dark, sx * 2.2)
		end
		blk(ctx, "Wing", W - 0.3, st.tailY + 1.35, st.tailY + 1.6, hl - 1.6, hl - 0.2, L.accent)
	end
	if v.underglow then
		blk(ctx, "Underglow", W - 1.6, 0.48, 0.6, -hl + 1.8, hl - 1.8, L.accentNeon)
	end
end

STYLES.hyper = function(ctx: Ctx)
	local st = roadCar(ctx, hyperSpec(ctx))
	hyperExtras(ctx, st, true)
end

STYLES.rocket = function(ctx: Ctx)
	local L = ctx.looks
	local st = roadCar(ctx, hyperSpec(ctx, { L = 13.6, axleF = -4.3, axleR = 4.1, cabF = -1.9, cabR = 3.0 }))
	hyperExtras(ctx, st, false)
	local hl = st.hl
	local y = 1.55
	cyl(ctx, "Nozzle", "Z", 1.9, 2.5, V(0, y, hl + 0.85), look(rgb(70, 72, 82), Enum.Material.Metal))
	cyl(ctx, "NozzleRing", "Z", 0.35, 2.9, V(0, y, hl + 1.65), L.accent)
	cyl(ctx, "Thruster", "Z", 0.15, 2.0, V(0, y, hl + 1.8), look(rgb(255, 170, 40), NEON))
	for _, sx in { -1, 1 } do
		wdg(ctx, "Fin", 0.3, st.tailY, st.tailY + 2.0, hl - 2.8, hl - 0.1, "F", L.accent, sx * 2.7)
	end
end

STYLES.monster = function(ctx: Ctx)
	local L = ctx.looks
	local P, G = L.primary, L.glass
	local len, W, r = 13.6, 6.2, 2.6
	local hl = len / 2
	local axleF, axleR, track = -4.4, 4.4, 3.15
	setupChassis(ctx, len - 1.2, W - 0.4, 2.7, 1.9, 2600)
	setupWheels(ctx, {
		r = r,
		twF = 2.0,
		twR = 2.0,
		axleF = axleF,
		axleR = axleR,
		trackF = track,
		trackR = track,
		rim = L.rim,
		rimScale = 0.5,
	})
	local bot, floorY, beltY, roofY = 3.6, 4.7, 5.5, 8.0
	blk(ctx, "Body", W, bot, floorY, -hl, hl, P)
	blk(ctx, "Hood", W, floorY, beltY, -hl, 1.7, P)
	wdg(ctx, "Windshield", W - 0.9, beltY, roofY - 0.4, -1.4, -0.2, "F", G)
	blk(ctx, "Windows", W - 0.9, beltY, roofY - 0.4, -0.2, 1.5, G)
	blk(ctx, "CabBack", W - 0.9, beltY, roofY - 0.4, 1.5, 1.7, P)
	blk(ctx, "Roof", W - 0.7, roofY - 0.4, roofY, -0.35, 1.75, P)
	for _, sx in { -1, 1 } do
		blk(ctx, "BedWall", 0.35, floorY, beltY, 1.7, hl, P, sx * (W / 2 - 0.175))
	end
	blk(ctx, "Tailgate", W - 0.7, floorY, beltY, hl - 0.3, hl, P)
	-- exposed axles + shocks
	for _, az in { axleF, axleR } do
		cyl(ctx, "Axle", "X", 2 * track, 0.7, V(0, r, az), L.dark)
		for _, sx in { -1, 1 } do
			blk(ctx, "Shock", 0.5, r + 0.2, bot + 0.2, az - 0.25, az + 0.25, L.chrome, sx * 2.0)
		end
	end
	local hx = W / 2 - 0.9
	for _, sx in { -1, 1 } do
		headlight(ctx, V(1.1, 0.6, 0.3), V(sx * hx, 5.05, -hl - 0.06))
		blk(ctx, "Taillight", 0.6, 4.75, 5.35, hl - 0.1, hl + 0.07, L.tail, sx * (W / 2 - 0.4))
	end
	blk(ctx, "BumperF", W + 0.3, bot, bot + 0.6, -hl - 0.4, -hl + 0.2, L.chrome)
	blk(ctx, "BumperR", W + 0.3, bot, bot + 0.6, hl - 0.2, hl + 0.4, L.chrome)
	-- roll bar over the bed
	for _, sx in { -1, 1 } do
		blk(ctx, "RollBar", 0.4, beltY, roofY + 0.2, 2.6, 3.0, L.accent, sx * (W / 2 - 0.45))
	end
	blk(ctx, "RollBar", W - 0.5, roofY - 0.2, roofY + 0.2, 2.6, 3.0, L.accent)
	blk(ctx, "LightbarBase", 3.6, roofY, roofY + 0.2, -0.1, 0.4, L.dark)
	blk(ctx, "RoofLight", 3.2, roofY + 0.2, roofY + 0.55, 0.0, 0.3, look(rgb(255, 240, 180), NEON))
	ctx.seat = V(-1.3, roofY - 0.4 - 3.45, 0.5)
end

STYLES.armored = function(ctx: Ctx)
	local v, L = ctx.variant, ctx.looks
	local P, G = L.primary, L.glass
	local len, W = 14.6, 7.6
	local hl = len / 2
	setupChassis(ctx, len - 0.8, W - 0.6, 1.0, 2.0, 3000)
	setupWheels(ctx, {
		r = 1.45,
		twF = 1.3,
		twR = 1.3,
		axleF = -4.7,
		axleR = 4.4,
		trackF = W / 2 + 0.2 - 0.65,
		trackR = W / 2 + 0.2 - 0.65,
		rim = L.dark,
		rimScale = 0.6,
	})
	local beltY, roofY, cabRoof = 3.1, 7.4, 6.6
	blk(ctx, "Body", W, 1.1, beltY, -hl, hl, P)
	wdg(ctx, "Hood", W, beltY, 3.7, -hl, -4.6, "F", P)
	blk(ctx, "Cab", W - 0.2, beltY, cabRoof, -4.6, -3.0, P)
	blk(ctx, "Cargo", W, beltY, roofY, -3.0, hl, P)
	blk(ctx, "Windshield", W - 1.6, 4.8, 6.1, -4.66, -4.5, G)
	blk(ctx, "Windows", W - 0.1, 4.9, 6.1, -4.2, -3.25, G)
	blk(ctx, "Slits", W + 0.06, 6.0, 6.4, -1.0, 5.6, G)
	local band = blk(ctx, "Band", W + 0.06, 3.9, 4.9, -2.9, hl - 0.3, L.accent)
	if v.label then
		label(
			band,
			{ Enum.NormalId.Left, Enum.NormalId.Right },
			"$ " .. v.label .. " $",
			rgb(255, 230, 90),
			COLORS.black
		)
	end
	-- vault door on the back
	local steel = look(rgb(150, 156, 166), Enum.Material.DiamondPlate)
	cyl(ctx, "VaultDoor", "Z", 0.3, 3.6, V(0, 5.0, hl + 0.15), steel)
	cyl(ctx, "VaultHub", "Z", 0.3, 0.9, V(0, 5.0, hl + 0.4), L.chrome)
	blk(ctx, "VaultHandle", 2.4, 4.85, 5.15, hl + 0.3, hl + 0.5, L.chrome)
	-- "It's literally full of money": cash sacks piled on the roof
	local sack = look(rgb(214, 186, 122), Enum.Material.Fabric)
	local tie = look(rgb(60, 150, 70))
	for _, b in { { -1.1, 1.0, 2.0 }, { 0.9, 2.4, 1.6 }, { -0.4, 3.6, 1.3 } } do
		local x, z, d = b[1], b[2], b[3]
		ball(ctx, "MoneyBag", d, V(x, roofY + d * 0.42, z), sack)
		cyl(ctx, "MoneyBagTie", "Y", 0.35, d * 0.45, V(x, roofY + d * 0.88, z), tie)
	end
	-- heavy bumpers, bull bar, beacons, lights
	local hx = W / 2 - 1.0
	for _, sx in { -1, 1 } do
		headlight(ctx, V(1.2, 0.6, 0.3), V(sx * hx, 2.45, -hl - 0.06))
		blk(ctx, "Taillight", 0.8, 2.2, 3.0, hl - 0.1, hl + 0.07, L.tail, sx * (W / 2 - 0.6))
		blk(
			ctx,
			"Beacon",
			0.6,
			cabRoof + 0.8,
			cabRoof + 1.2,
			-2.9,
			-2.4,
			look(rgb(255, 160, 20), NEON),
			sx * (W / 2 - 0.5)
		)
	end
	blk(ctx, "Grille", 3.0, 2.1, 2.85, -hl - 0.06, -hl + 0.1, L.dark)
	blk(ctx, "BumperF", W + 0.2, 0.95, 1.7, -hl - 0.4, -hl + 0.3, L.black)
	blk(ctx, "BumperR", W + 0.2, 0.95, 1.7, hl - 0.3, hl + 0.4, L.black)
	blk(ctx, "BullBar", W * 0.6, 1.7, 3.3, -hl - 0.6, -hl - 0.3, L.black)
	ctx.seat = V(-1.7, cabRoof - 3.6, -3.6)
end

STYLES.tank = function(ctx: Ctx)
	local L = ctx.looks
	local P = L.primary
	local treadLook = look(rgb(42, 42, 46))
	setupChassis(ctx, 11.4, 6.6, 0.9, 1.8, 3000)
	setupWheels(ctx, {
		r = 1.1,
		twF = 1.2,
		twR = 1.2,
		axleF = -3.8,
		axleR = 3.8,
		trackF = 2.95,
		trackR = 2.95,
		hidden = true,
	})
	for _, sx in { -1, 1 } do
		local x = sx * 2.95
		blk(ctx, "Tread", 1.9, 0.15, 2.05, -4.9, 4.9, treadLook, x)
		cyl(ctx, "TreadEnd", "X", 1.9, 1.9, V(x, 1.1, -4.9), treadLook)
		cyl(ctx, "TreadEnd", "X", 1.9, 1.9, V(x, 1.1, 4.9), treadLook)
		for _, z in { -2.5, 0, 2.5 } do
			cyl(ctx, "RoadWheel", "X", 2.0, 1.35, V(x, 1.1, z), L.accent)
		end
	end
	blk(ctx, "Hull", 4.2, 0.8, 2.2, -5.2, 5.2, L.accent)
	blk(ctx, "Deck", 7.6, 2.05, 3.0, -4.6, 5.9, P)
	wdg(ctx, "Glacis", 7.6, 2.05, 3.0, -6.3, -4.6, "F", P)
	cyl(ctx, "Turret", "Y", 1.4, 4.8, V(0, 3.65, 0.7), P)
	ball(ctx, "Dome", 3.8, V(0, 4.2, 0.9), P)
	cyl(ctx, "Barrel", "Z", 5.0, 0.8, V(0, 4.0, -3.9), L.accent)
	cyl(ctx, "Muzzle", "Z", 0.9, 1.2, V(0, 4.0, -6.5), L.dark)
	-- open hatch lid behind the commander
	addPart(
		ctx,
		"Cyl",
		"Hatch",
		V(0.25, 1.6, 1.6),
		CFrame.new(0, 6.35, 2.15) * CFrame.Angles(0, PI / 2, 0.25),
		L.accent
	)
	for _, sx in { -1, 1 } do
		headlight(ctx, V(0.8, 0.45, 0.3), V(sx * 2.7, 2.35, -6.2))
		blk(ctx, "Taillight", 0.8, 2.3, 2.75, 5.85, 6.0, L.tail, sx * 2.9)
	end
	-- commander rides waist-deep in the hatch
	ctx.seat = V(0, 4.35, 1.1)
end

STYLES.hover = function(ctx: Ctx)
	local L = ctx.looks
	local st = roadCar(ctx, {
		L = 13.4,
		W = 7.0,
		r = 1.2,
		tw = 1.0,
		axleF = -4.2,
		axleR = 4.2,
		wheelOut = -0.6,
		hiddenWheels = true,
		bodyBot = 1.35,
		beltY = 2.7,
		noseY = 1.95,
		tailY = 2.35,
		cabF = -1.9,
		cabFT = -0.3,
		cabRT = 1.9,
		cabR = 4.0,
		roofY = 4.6,
		roofT = 0.3,
		cabInset = 1.05,
		pillars = 0,
		roofLook = L.glass,
		headW = 1.6,
		headH = 0.3,
		headInset = 1.0,
		tailBar = true,
		mass = 1200,
		chassisBot = 1.0,
		chassisH = 1.6,
	})
	local hl, W = st.hl, st.W
	local pad = look(rgb(70, 76, 92))
	for _, az in { -4.2, 4.2 } do
		for _, sx in { -1, 1 } do
			cyl(ctx, "HoverPad", "Y", 0.55, 2.4, V(sx * 2.6, 1.15, az), pad)
			cyl(ctx, "HoverGlow", "Y", 0.14, 2.0, V(sx * 2.6, 0.84, az), L.accentNeon)
		end
	end
	blk(ctx, "Underglow", W - 1.4, 1.22, 1.34, -hl + 1.4, hl - 1.4, L.accentNeon)
	blk(ctx, "SideLine", W + 0.06, 2.0, 2.15, -hl + 1.0, hl - 0.6, L.accentNeon)
	wdg(ctx, "Fin", 0.3, st.tailY, st.tailY + 1.5, hl - 2.8, hl - 0.2, "F", L.accent)
end

STYLES.hotdog = function(ctx: Ctx)
	local L = ctx.looks
	setupChassis(ctx, 12.0, 6.0, 0.9, 1.8, 1000)
	setupWheels(ctx, {
		r = 1.15,
		twF = 0.95,
		twR = 0.95,
		axleF = -4.0,
		axleR = 4.0,
		trackF = 2.85,
		trackR = 2.85,
		rim = L.rim,
		rimScale = 0.55,
	})
	local bun = look(rgb(232, 166, 84))
	local by = 2.25
	for _, sx in { -1, 1 } do
		cyl(ctx, "Bun", "Z", 10.0, 2.9, V(sx * 1.3, by, 0), bun)
		ball(ctx, "BunEnd", 2.9, V(sx * 1.3, by, -5.0), bun)
		ball(ctx, "BunEnd", 2.9, V(sx * 1.3, by, 5.0), bun)
	end
	local sy = 3.4
	cyl(ctx, "Sausage", "Z", 11.2, 2.2, V(0, sy, 0), L.primary)
	ball(ctx, "SausageEnd", 2.2, V(0, sy, -5.6), L.primary)
	ball(ctx, "SausageEnd", 2.2, V(0, sy, 5.6), L.primary)
	-- mustard squiggle
	local pts = {
		V(0.45, 0, -5.0),
		V(-0.45, 0, -3.6),
		V(0.45, 0, -2.2),
		V(-0.45, 0, -0.8),
		V(0.45, 0, 0.6),
		V(-0.45, 0, 2.0),
		V(0.45, 0, 3.4),
		V(-0.45, 0, 4.8),
	}
	local top = sy + 1.1
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local d = b - a
		local mid = (a + b) / 2
		local yaw = math.atan2(d.X, d.Z)
		addPart(
			ctx,
			"Block",
			"Mustard",
			V(0.38, 0.24, d.Magnitude + 0.3),
			CFrame.new(mid.X, top - 0.02, mid.Z) * CFrame.Angles(0, yaw, 0),
			L.accent
		)
	end
	for _, sx in { -1, 1 } do
		headlight(ctx, V(0.9, 0.55, 0.3), V(sx * 1.3, 1.9, -6.3))
		blk(ctx, "Taillight", 0.9, 1.65, 2.15, 6.15, 6.42, L.tail, sx * 1.3)
	end
	-- rider sits on top of the sausage
	ctx.seat = V(0, top - 0.1, 1.4)
end

STYLES.duck = function(ctx: Ctx)
	local L = ctx.looks
	local P = L.primary
	setupChassis(ctx, 9.6, 5.6, 0.9, 1.8, 1000)
	setupWheels(ctx, {
		r = 1.15,
		twF = 1.0,
		twR = 1.0,
		axleF = -3.3,
		axleR = 3.3,
		trackF = 2.75,
		trackR = 2.75,
		rim = L.rim,
		rimScale = 0.55,
	})
	ball(ctx, "Body", 6.2, V(0, 3.3, 0.3), P)
	ball(ctx, "Body", 5.2, V(0, 3.4, 2.3), P)
	wdg(ctx, "Tail", 2.6, 3.6, 6.7, 3.6, 5.8, "F", P)
	ball(ctx, "Head", 4.2, V(0, 7.15, -1.9), P)
	cyl(ctx, "Wing", "X", 6.5, 3.4, V(0, 3.7, 0.9), P)
	cyl(ctx, "Beak", "Y", 0.7, 2.5, V(0, 6.9, -4.15), L.accent)
	cyl(ctx, "Beak", "Y", 0.4, 2.0, V(0, 6.4, -3.95), look(rgb(230, 100, 20)))
	for _, sx in { -1, 1 } do
		ball(ctx, "Eye", 1.15, V(sx * 0.9, 7.85, -3.45), L.white)
		ball(ctx, "Pupil", 0.62, V(sx * 0.95, 7.95, -3.88), L.black)
		ball(ctx, "Blush", 0.75, V(sx * 1.55, 7.0, -3.2), look(rgb(255, 150, 140)))
		headlight(ctx, V(0.8, 0.5, 0.3), V(sx * 1.3, 2.3, -2.2))
		blk(ctx, "Taillight", 0.7, 2.1, 2.5, 4.3, 4.55, L.tail, sx * 1.2)
	end
	ctx.seat = V(0, 6.0, 1.5)
end

STYLES.couch = function(ctx: Ctx)
	local L = ctx.looks
	local fabric = Enum.Material.Fabric
	local P = look(L.primary.color, materialByName(ctx.variant.bodyMaterial, fabric), "primary")
	local A = look(L.accent.color, fabric, "accent")
	local W = 8.0
	setupChassis(ctx, 6.6, W - 0.8, 0.9, 1.6, 1000)
	setupWheels(ctx, {
		r = 1.05,
		twF = 0.9,
		twR = 0.9,
		axleF = -2.55,
		axleR = 2.55,
		trackF = 3.0,
		trackR = 3.0,
		rim = L.chrome,
		rimScale = 0.5,
	})
	blk(ctx, "Base", W, 1.0, 2.5, -3.5, 2.0, P)
	blk(ctx, "Back", W, 1.0, 5.4, 2.0, 3.5, P)
	cyl(ctx, "BackRoll", "X", W, 1.5, V(0, 5.4, 2.75), P)
	local armX = W / 2 - 0.65
	for _, sx in { -1, 1 } do
		blk(ctx, "Arm", 1.3, 2.5, 3.9, -3.5, 2.0, P, sx * armX)
		cyl(ctx, "ArmRoll", "Z", 5.5, 1.3, V(sx * armX, 3.9, -0.75), P)
	end
	local cw = (W - 2.6) / 2 - 0.05
	local cx = cw / 2 + 0.025
	for _, sx in { -1, 1 } do
		blk(ctx, "Cushion", cw, 2.5, 3.3, -3.4, 1.95, A, sx * cx)
		addPart(
			ctx,
			"Block",
			"BackCushion",
			V(cw, 2.3, 0.8),
			CFrame.new(sx * cx, 4.3, 1.75) * CFrame.Angles(-0.2, 0, 0),
			A
		)
		headlight(ctx, V(0.8, 0.5, 0.25), V(sx * armX, 3.3, -3.55))
		blk(ctx, "Taillight", 1.0, 1.8, 2.3, 3.45, 3.6, L.tail, sx * (W / 2 - 0.9))
	end
	-- throw pillow, TV remote and a soda can — the couch life
	addPart(
		ctx,
		"Block",
		"Pillow",
		V(1.5, 1.5, 0.55),
		CFrame.new(cx + 0.9, 3.85, 0.8) * CFrame.Angles(-0.35, 0, PI / 4),
		look(rgb(255, 120, 150), fabric)
	)
	blk(ctx, "Remote", 0.42, 4.55, 4.72, -2.2, -1.2, L.black, armX)
	cyl(ctx, "Soda", "Y", 0.9, 0.55, V(-armX, 5.0, -2.4), look(rgb(225, 30, 40)))
	ctx.seat = V(-cx, 3.3, -0.7)
end

STYLES.toilet = function(ctx: Ctx)
	local L = ctx.looks
	local P = look(L.primary.color, L.primary.material, "primary")
	P.reflectance = 0.08
	setupChassis(ctx, 8.4, 5.0, 0.9, 1.5, 900)
	setupWheels(ctx, {
		r = 1.05,
		twF = 0.9,
		twR = 0.9,
		axleF = -3.0,
		axleR = 2.9,
		trackF = 2.65,
		trackR = 2.65,
		rim = L.rim,
		rimScale = 0.55,
	})
	blk(ctx, "Deck", 5.0, 1.0, 1.45, -4.3, 4.3, L.dark)
	cyl(ctx, "Pedestal", "Y", 1.4, 2.2, V(0, 2.15, -0.9), P)
	cyl(ctx, "Bowl", "Y", 1.4, 3.9, V(0, 3.5, -1.2), P)
	cyl(ctx, "Water", "Y", 0.1, 2.9, V(0, 4.17, -1.3), look(rgb(110, 205, 255)))
	blk(ctx, "Tank", 3.8, 3.0, 6.4, 0.9, 2.5, P)
	blk(ctx, "TankLid", 4.1, 6.4, 6.75, 0.75, 2.65, P)
	blk(ctx, "FlushHandle", 0.9, 5.8, 6.05, 0.62, 0.9, L.chrome, -1.3)
	-- lid (raised) leaning on the tank
	addPart(
		ctx,
		"Cyl",
		"Lid",
		V(0.3, 4.0, 4.0),
		CFrame.new(0, 5.45, 0.6) * CFrame.Angles(0.12, 0, 0) * CFrame.Angles(0, PI / 2, 0),
		L.accent
	)
	cyl(ctx, "PaperRoll", "X", 1.1, 1.3, V(1.75, 2.1, -2.9), L.white)
	for _, sx in { -1, 1 } do
		cyl(ctx, "Exhaust", "Z", 2.4, 0.95, V(sx * 1.2, 2.6, 3.6), L.chrome)
		cyl(ctx, "Thruster", "Z", 0.2, 0.75, V(sx * 1.2, 2.6, 4.85), L.accentNeon)
		headlight(ctx, V(0.9, 0.35, 0.3), V(sx * 1.85, 1.22, -4.38))
		blk(ctx, "Taillight", 0.9, 1.05, 1.4, 4.25, 4.4, L.tail, sx * 1.85)
	end
	-- rider sits on the bowl, facing away from the tank
	ctx.seat = V(0, 4.25, -1.1)
end

------------------------------------------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------------------------------------------

local warnedIds: { [string]: boolean } = {}
local warnedShells: { [string]: boolean } = {}

local function isClient(): boolean
	local ok, client = pcall(function()
		return game:GetService("RunService"):IsClient()
	end)
	return ok and client == true
end

local function resolveDef(carId: string): CarDef
	local def = Cars.get(carId)
	if def then
		return def
	end
	if carId == Cars.Police.id or carId == "police" then
		return Cars.Police
	end
	if not warnedIds[carId] then
		warnedIds[carId] = true
		warn(("[CarBuilder] unknown car id %q, building %s instead"):format(carId, Cars.List[1].id))
	end
	return Cars.List[1]
end

-- Build a car from a CarDef (works for Cars.Police and any ad-hoc def). See the contract at the top of this file.
function CarBuilder.buildDef(def: CarDef, mutation: MutationId?, opts: BuildOpts?): Model
	local forDisplay = opts ~= nil and opts.forDisplay == true
	local variant = VARIANTS[def.id] or {}
	local model = Instance.new("Model")
	model.Name = def.id
	local ctx: Ctx = {
		def = def,
		model = model,
		forDisplay = forDisplay,
		chassis = nil,
		parts = {},
		weldTo = {},
		noWeld = {},
		looks = makeLooks(def, variant),
		variant = variant,
		wheelRadius = 1.3,
		axles = {},
		seat = nil,
	}
	local builder = STYLES[def.style] or STYLES.sedan
	builder(ctx)
	local chassis = getChassis(ctx)
	if not forDisplay then
		setupSeat(ctx)
		setupBumpStops(ctx)
	end
	weldAll(ctx)

	local minV, maxV = measure(ctx.parts)
	model:SetAttribute("RideHeight", chassis.CFrame.Position.Y)
	model:SetAttribute("WheelRadius", ctx.wheelRadius)
	model:SetAttribute("Length", maxV.Z - minV.Z)
	model:SetAttribute("Width", maxV.X - minV.X)
	model:SetAttribute("Height", maxV.Y)
	model:SetAttribute("BodyCenter", V((minV.X + maxV.X) / 2, 0, (minV.Z + maxV.Z) / 2))
	model:SetAttribute("Style", def.style)
	model:SetAttribute("CarId", def.id)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	CarBuilder.applyMutation(model, mutation or "None")
	if isClient() then
		model:AddTag(CLIENT_TAG)
	end
	-- art is optional: a broken template must never break a build (the procedural car stays)
	local ok, err = pcall(CarBuilder.applyShell, model)
	if not ok and not warnedShells[def.id] then
		warnedShells[def.id] = true
		warn(("[CarBuilder] hero shell for %s failed: %s"):format(def.id, tostring(err)))
	end
	return model
end

-- Build a catalog car by id (unknown ids fall back to the first catalog car with a warning).
function CarBuilder.build(carId: string, mutation: MutationId?, opts: BuildOpts?): Model
	return CarBuilder.buildDef(resolveDef(carId), mutation, opts)
end

local function primaryParts(model: Model): { BasePart }
	local out = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("Paint") == "primary" then
			table.insert(out, d)
		end
	end
	-- front-to-back order so Rainbow gradients sweep along the car
	table.sort(out, function(a, b)
		return a.CFrame.Position.Z < b.CFrame.Position.Z
	end)
	return out
end

local function baseLook(part: BasePart): (Color3, Enum.Material)
	local color = part:GetAttribute("BaseColor")
	local matName = part:GetAttribute("BaseMaterial")
	local baseColor = if typeof(color) == "Color3" then color else part.Color
	local baseMat = materialByName(if typeof(matName) == "string" then matName else nil, part.Material)
	return baseColor, baseMat
end

------------------------------------------------------------------------------------------------------------------
-- Hero shells (docs/ART_PASS.md AP1; contract at the top of this file)
------------------------------------------------------------------------------------------------------------------

-- Hero template key of a car model: its CarId (the police cruiser's is Cars.Police.id = "police_unit").
function CarBuilder.shellKey(model: Instance): string?
	local carId = model:GetAttribute("CarId")
	if typeof(carId) ~= "string" or carId == "" then
		return nil
	end
	return if carId == "police" then Cars.Police.id else carId
end

-- The published Hero template for `key`, or nil (Lune harness, failed load, or AssetLibrary still loading).
function CarBuilder.shellTemplate(key: string): Model?
	local ok, found = pcall(function()
		local lib = game:GetService("ReplicatedStorage"):FindFirstChild("AssetLibrary")
		local hero = lib and lib:FindFirstChild("Hero")
		return hero and hero:FindFirstChild(key)
	end)
	if ok and typeof(found) == "Instance" and found:IsA("Model") then
		return found
	end
	return nil
end

-- The shell's parts (empty when the model has no shell).
local function shellParts(model: Model): { BasePart }
	local out = {}
	local shell = model:FindFirstChild(SHELL_NAME)
	if shell then
		for _, d in shell:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(out, d)
			end
		end
	end
	return out
end

-- AABB of the visible `parts` in the space of `ref`.
local function boundsIn(ref: CFrame, parts: { BasePart }): (Vector3?, Vector3?)
	local minV: Vector3? = nil
	local maxV: Vector3? = nil
	for _, p in parts do
		if p.Transparency < 1 then
			local cf = ref:ToObjectSpace(p.CFrame)
			local h = p.Size / 2
			local rx, ry, rz = cf.RightVector, cf.UpVector, cf.LookVector
			local e = V(
				math.abs(rx.X) * h.X + math.abs(ry.X) * h.Y + math.abs(rz.X) * h.Z,
				math.abs(rx.Y) * h.X + math.abs(ry.Y) * h.Y + math.abs(rz.Y) * h.Z,
				math.abs(rx.Z) * h.X + math.abs(ry.Z) * h.Y + math.abs(rz.Z) * h.Z
			)
			local c = cf.Position
			minV = if minV then minV:Min(c - e) else c - e
			maxV = if maxV then maxV:Max(c + e) else c + e
		end
	end
	return minV, maxV
end

local function weldToChassis(chassis: BasePart, part: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Name = "Weld"
	weld.Part0 = chassis
	weld.Part1 = part
	weld.Parent = part
end

local function unweld(part: BasePart)
	for _, c in part:GetChildren() do
		if c:IsA("WeldConstraint") then
			c:Destroy()
		end
	end
end

-- Size-independent child scales (FileMesh SpecialMesh scale / offsets, Texture tiling) follow a part resize.
local function scaleExtras(part: BasePart, f: number)
	for _, d in part:GetDescendants() do
		if d:IsA("SpecialMesh") then
			if d.MeshType == Enum.MeshType.FileMesh then
				d.Scale *= f
			end
			d.Offset *= f
		elseif d:IsA("Texture") then
			d.StudsPerTileU *= f
			d.StudsPerTileV *= f
		end
	end
end

-- Procedural visuals -> Transparency 1 (kept as parts: welds, attachments, Headlight beams, sparkles keep working).
local function hideProcedural(model: Model, chassis: BasePart, keepSirens: boolean)
	for _, child in model:GetChildren() do
		local keep = SHELL_KEEP[child.Name] or (keepSirens and SIREN_NAMES[child.Name])
		if child:IsA("BasePart") and child ~= chassis and not keep and child.Transparency < 1 then
			child:SetAttribute(HIDDEN_ATTR, child.Transparency)
			child.Transparency = 1
			for _, d in child:GetDescendants() do
				if d:IsA("SurfaceGui") and d.Enabled then
					d:SetAttribute(HIDDEN_ATTR, true)
					d.Enabled = false
				elseif d:IsA("Decal") and d.Transparency < 1 then
					d:SetAttribute(HIDDEN_ATTR, d.Transparency)
					d.Transparency = 1
				end
			end
		end
	end
end

-- Moves a welded part to `target` (remembering its pre-shell spot for removeShell) and re-welds it there.
local function moveWelded(part: BasePart, chassis: BasePart, target: CFrame)
	if part:GetAttribute(PRE_SHELL_ATTR) == nil then
		part:SetAttribute(PRE_SHELL_ATTR, chassis.CFrame:ToObjectSpace(part.CFrame))
	end
	unweld(part)
	part.CFrame = target
	weldToChassis(chassis, part)
end

-- A police light raised onto the shell roof (same x/z over the chassis).
local function raiseSiren(part: BasePart, chassis: BasePart, ground: CFrame, roofY: number)
	local rel = ground:ToObjectSpace(part.CFrame)
	local p = rel.Position
	moveWelded(part, chassis, ground * CFrame.new(p.X, roofY + SIREN_GAP + part.Size.Y / 2, p.Z) * rel.Rotation)
end

-- Lower the DriverSeat into an open-top shell's seat (never under a seated driver: a late re-skin leaves it be).
local function fitSeat(model: Model, chassis: BasePart, key: string)
	local drop = SHELL_SEAT_DROP[key]
	local found = model:FindFirstChild("DriverSeat")
	if not drop or not found or not found:IsA("VehicleSeat") then
		return
	end
	local seat = found :: VehicleSeat
	local okOcc, occupant = pcall(function()
		return seat.Occupant
	end)
	if okOcc and occupant ~= nil then
		return
	end
	moveWelded(seat, chassis, seat.CFrame * CFrame.new(0, -drop, 0))
end

-- Dress a built car in its hero mesh shell (see the contract at the top). Returns true when the model wears a shell
-- (already or now), false when there is no template / the model is not a CarBuilder car. Idempotent; works on
-- display, dealership and ViewportFrame models and on cars already placed in the world (late template arrival).
function CarBuilder.applyShell(model: Model): boolean
	if model:FindFirstChild(SHELL_NAME) then
		return true
	end
	local key = CarBuilder.shellKey(model)
	local template = if key then CarBuilder.shellTemplate(key) else nil
	local chassisInst = model.PrimaryPart or model:FindFirstChild("Chassis")
	local length = model:GetAttribute("Length")
	local ride = model:GetAttribute("RideHeight")
	if not key or not template or not chassisInst or not chassisInst:IsA("BasePart") then
		return false
	end
	if typeof(length) ~= "number" or length <= 0 or typeof(ride) ~= "number" then
		return false
	end
	local chassis = chassisInst :: BasePart

	-- template frame: its AssetRoot (bottom-center, front -Z), then measure the visible mesh in that frame
	local shell = template:Clone()
	local root = shell:FindFirstChild("AssetRoot")
	local ref = if root and root:IsA("BasePart") then root.CFrame else shell:GetPivot()
	if root then
		root:Destroy()
	end
	local parts: { BasePart } = {}
	for _, d in shell:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	local minV, maxV = boundsIn(ref, parts)
	if not minV or not maxV then
		shell:Destroy()
		return false
	end
	local size = maxV - minV
	local f = length / math.max(size.Z, 0.01)
	local width = model:GetAttribute("Width")
	if typeof(width) == "number" and width > 0 and size.X * f > width * SHELL_WIDTH_SLACK then
		f = width * SHELL_WIDTH_SLACK / math.max(size.X, 0.01)
	end

	-- ground plane under the body center (+ SHELL_LIFT for floaters); the shell's bottom-center goes there
	local center = model:GetAttribute("BodyCenter")
	local c = if typeof(center) == "Vector3" then center else Vector3.zero
	local lift = SHELL_LIFT[key] or 0
	local ground = chassis.CFrame * CFrame.new(c.X, -ride + lift, c.Z)
	local anchor = V((minV.X + maxV.X) / 2, minV.Y, (minV.Z + maxV.Z) / 2)
	for _, p in parts do
		local rel = ref:ToObjectSpace(p.CFrame)
		p.Size = p.Size * f
		p.CFrame = ground * CFrame.new((rel.Position - anchor) * f) * rel.Rotation
		scaleExtras(p, f)
		p.Anchored = false
		p.Massless = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		weldToChassis(chassis, p)
	end
	shell.Name = SHELL_NAME
	shell:SetAttribute("ShellKey", key)
	shell:SetAttribute("ShellScale", f)
	shell.Parent = model

	local roofY = size.Y * f
	model:SetAttribute("HeroMesh", true)
	model:SetAttribute("ShellHeight", roofY + lift)
	local police = key == Cars.Police.id
	hideProcedural(model, chassis, police)
	for _, child in model:GetChildren() do
		if police and child:IsA("BasePart") and SIREN_NAMES[child.Name] then
			raiseSiren(child, chassis, ground, roofY)
		end
	end
	fitSeat(model, chassis, key)
	local mutation = model:GetAttribute("Mutation")
	CarBuilder.applyMutation(model, if typeof(mutation) == "string" then mutation :: MutationId else "None")
	return true
end

-- Undo applyShell: the procedural look comes back (parts, guis, siren spots, mutation). True if a shell was removed.
function CarBuilder.removeShell(model: Model): boolean
	local shell = model:FindFirstChild(SHELL_NAME)
	if not shell then
		return false
	end
	shell:Destroy()
	local chassis = model.PrimaryPart or model:FindFirstChild("Chassis")
	for _, d in model:GetDescendants() do
		local hidden = d:GetAttribute(HIDDEN_ATTR)
		if hidden ~= nil then
			if typeof(hidden) == "number" and (d:IsA("BasePart") or d:IsA("Decal")) then
				(d :: any).Transparency = hidden
			elseif d:IsA("SurfaceGui") then
				d.Enabled = true
			end
			d:SetAttribute(HIDDEN_ATTR, nil)
		end
	end
	for _, child in model:GetChildren() do
		local pre = child:GetAttribute(PRE_SHELL_ATTR)
		if typeof(pre) == "CFrame" and child:IsA("BasePart") and chassis and chassis:IsA("BasePart") then
			unweld(child)
			child.CFrame = chassis.CFrame * pre
			weldToChassis(chassis, child)
			child:SetAttribute(PRE_SHELL_ATTR, nil)
		end
	end
	model:SetAttribute("HeroMesh", nil)
	model:SetAttribute("ShellHeight", nil)
	local mutation = model:GetAttribute("Mutation")
	CarBuilder.applyMutation(model, if typeof(mutation) == "string" then mutation :: MutationId else "None")
	return true
end

-- A shell part's texture on/off. TextureID is kept in attribute "ShellTextureID"; a SurfaceAppearance (which only
-- applies as a direct child) is parked in a STASH_NAME Folder while off, so "None" restores both.
local function setShellTexture(part: BasePart, on: boolean)
	if part:IsA("MeshPart") then
		local mesh = part :: MeshPart
		local okRead, current = pcall(function()
			return mesh.TextureID
		end)
		local now: string = if okRead and typeof(current) == "string" then current else ""
		local stored = part:GetAttribute("ShellTextureID")
		local original: string = if typeof(stored) == "string" then stored else now
		if typeof(stored) ~= "string" then
			part:SetAttribute("ShellTextureID", original)
		end
		local want = if on then original else ""
		if now ~= want then
			pcall(function()
				mesh.TextureID = want
			end)
		end
	end
	local stash = part:FindFirstChild(STASH_NAME)
	if on then
		if stash then
			for _, c in stash:GetChildren() do
				c.Parent = part
			end
			stash:Destroy()
		end
		return
	end
	for _, c in part:GetChildren() do
		if c:IsA("SurfaceAppearance") then
			if not stash then
				local folder = Instance.new("Folder")
				folder.Name = STASH_NAME
				folder.Parent = part
				stash = folder
			end
			c.Parent = stash
		end
	end
end

-- Mutation look of the shell: None = the mesh's own texture (or flat spray paint after repaint), Gold / Diamond /
-- Galaxy = texture off + mutation color/material, Rainbow = texture off (clients cycle the hue, WheelAnimator).
local function mutateShell(model: Model, mutId: MutationId, mdef: Rarity.MutationDef, parts: { BasePart })
	local paint = model:GetAttribute("ShellPaint")
	local textured = mutId == "None" and typeof(paint) ~= "Color3"
	local n = #parts
	for i, part in parts do
		local stored = part:GetAttribute("ShellBaseColor")
		local matName = part:GetAttribute("ShellBaseMaterial")
		local baseColor: Color3 = if typeof(stored) == "Color3" then stored else part.Color
		local baseMat = materialByName(if typeof(matName) == "string" then matName else nil, part.Material)
		if typeof(stored) ~= "Color3" then
			part:SetAttribute("ShellBaseColor", baseColor)
			part:SetAttribute("ShellBaseMaterial", baseMat.Name)
		end
		setShellTexture(part, textured)
		if textured then
			part.Color = baseColor
			part.Material = baseMat
		elseif mutId == "Rainbow" then
			part.Material = mdef.material or SMOOTH
			part.Color = Color3.fromHSV(((i - 1) / math.max(n, 1)) % 1, 0.75, 1)
		elseif mutId == "None" then
			-- spray-shop repaint: a texture can't be tinted, so the shell goes flat in the new paint
			part.Color = if typeof(paint) == "Color3" then paint else baseColor
			part.Material = SMOOTH
		else
			part.Color = mdef.color or baseColor
			part.Material = mdef.material or baseMat
		end
	end
end

-- Recolor/re-material the primary paint for a mutation and add sparkles (Diamond/Galaxy). Rainbow gets a static
-- rainbow sweep here; clients animate the hue (WheelAnimator). HeroMesh cars restyle their shell parts too.
-- Always sets the model attribute "Mutation".
function CarBuilder.applyMutation(model: Model, mutation: MutationId)
	local mutId: MutationId = if Rarity.Mutations[mutation] then mutation else "None"
	local mdef = Rarity.getMutation(mutId)

	for _, d in model:GetDescendants() do
		if d.Name == SPARKLES_NAME and d:IsA("ParticleEmitter") then
			d:Destroy()
		end
	end

	local shell = shellParts(model)
	if #shell > 0 then
		mutateShell(model, mutId, mdef, shell)
	end

	local parts = primaryParts(model)
	local n = #parts
	local biggest: BasePart? = nil
	local biggestVol = -1
	for i, part in parts do
		local baseColor, baseMat = baseLook(part)
		if part:GetAttribute("BaseColor") == nil then
			part:SetAttribute("BaseColor", baseColor)
			part:SetAttribute("BaseMaterial", baseMat.Name)
		end
		if mutId == "None" then
			part.Color = baseColor
			part.Material = baseMat
		elseif mutId == "Rainbow" then
			part.Material = mdef.material or SMOOTH
			part.Color = Color3.fromHSV(((i - 1) / math.max(n, 1)) % 1, 0.75, 1)
		else
			part.Color = mdef.color or baseColor
			part.Material = mdef.material or baseMat
		end
		local vol = part.Size.X * part.Size.Y * part.Size.Z
		if vol > biggestVol then
			biggestVol = vol
			biggest = part
		end
	end
	-- on a HeroMesh car the sparkles fill the visible shell instead of a hidden body part
	local shellVol = -1
	for _, part in shell do
		local vol = part.Size.X * part.Size.Y * part.Size.Z
		if vol > shellVol then
			shellVol = vol
			biggest = part
		end
	end

	if (mutId == "Diamond" or mutId == "Galaxy") and biggest then
		local pe = Instance.new("ParticleEmitter")
		pe.Name = SPARKLES_NAME
		pe.Texture = SPARKLES_TEXTURE
		pe.Rate = if mutId == "Galaxy" then 8 else 5
		pe.Lifetime = NumberRange.new(0.6, 1.3)
		pe.Speed = NumberRange.new(0.5, 1.6)
		pe.SpreadAngle = Vector2.new(180, 180)
		pe.Rotation = NumberRange.new(0, 360)
		pe.RotSpeed = NumberRange.new(-120, 120)
		pe.LightEmission = 1
		pe.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.3, 0.55),
			NumberSequenceKeypoint.new(1, 0),
		})
		if mutId == "Galaxy" then
			pe.Color = ColorSequence.new(rgb(200, 140, 255), rgb(90, 200, 255))
		else
			pe.Color = ColorSequence.new(rgb(255, 255, 255), rgb(170, 240, 255))
		end
		pe.Parent = biggest
	end

	model:SetAttribute("Mutation", mutId)
end

-- Repaint the primary paint (e.g. Spray Shop). Keeps the mutation look when the car has a recolor mutation.
-- A hero shell (now or arriving later) shows the paint flat (attribute ShellPaint; see mutateShell).
function CarBuilder.repaint(model: Model, color: Color3)
	for _, part in primaryParts(model) do
		part:SetAttribute("BaseColor", color)
	end
	model:SetAttribute("ShellPaint", color)
	local mutation = model:GetAttribute("Mutation")
	CarBuilder.applyMutation(model, if typeof(mutation) == "string" then mutation :: any else "None")
end

-- Toggle the headlight SpotLights (night driving).
function CarBuilder.setHeadlights(model: Model, on: boolean)
	for _, d in model:GetDescendants() do
		if d:IsA("SpotLight") and d.Parent and d.Parent.Name == "Headlight" then
			d.Enabled = on
		end
	end
end

-- Every style the builder knows (one per Cars.CarStyle).
function CarBuilder.styles(): { string }
	local out = {}
	for name in STYLES do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

local dimsCache: { [string]: StyleDims } = {}

-- Nominal outer dimensions of a style (measured from a reference build; cached).
function CarBuilder.styleDims(style: string): StyleDims
	local cached = dimsCache[style]
	if cached then
		return cached
	end
	local def: CarDef = {
		id = "_dims_" .. style,
		name = style,
		rarity = "Common",
		style = style :: any,
		color = COLORS.white,
		accent = COLORS.dark,
		income = 0,
		price = 0,
		topSpeed = 1,
		accel = 1,
		grip = 1,
		street = false,
		dealer = false,
		stealable = false,
		flavor = "",
	}
	local model = CarBuilder.buildDef(def, "None", { forDisplay = true })
	local dims: StyleDims = {
		length = model:GetAttribute("Length") :: number,
		width = model:GetAttribute("Width") :: number,
		height = model:GetAttribute("Height") :: number,
		wheelRadius = model:GetAttribute("WheelRadius") :: number,
	}
	model:Destroy()
	dimsCache[style] = dims
	return dims
end

return CarBuilder
