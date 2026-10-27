--!strict
-- WeaponModels: part-built placeholder weapons with real-world proportions (GTA reads guns ~1.2x in hand), in matte
-- blued steel, black polymer, walnut and ash, until the mesh pipeline lands (Config/Weapons asset.mesh). No neon, no
-- cartoon colours (kill list). Pure instance construction: harness-compatible, used by WeaponService (Tools) and by
-- GunShopUI (ViewportFrame previews).
--
-- Frame: the Handle sits at the shooting hand's grip point; the barrel runs along -Z, the sights are +Y. With the
-- default R15 RightGripAttachment and Tool.Grip = identity the gun points where the arm points. Melee weapons run
-- along +Y (their Tool.Grip tilts them).
-- Every part except the Handle carries attribute "Tint" = "metal" | "polymer" | "wood" | "rubber" | "brass" (tints
-- recolour metal + polymer only). The Handle is a small invisible part; a "Muzzle" Attachment marks the barrel tip.

local WeaponModels = {}

local STEEL = Color3.fromRGB(38, 39, 42)
local STEEL_WORN = Color3.fromRGB(58, 59, 62)
local POLYMER = Color3.fromRGB(27, 27, 29)
local POLYMER_GREY = Color3.fromRGB(46, 47, 50)
local WALNUT = Color3.fromRGB(92, 56, 33)
local ASH = Color3.fromRGB(196, 162, 118)
local TAPE = Color3.fromRGB(22, 22, 24)
local RUBBER = Color3.fromRGB(20, 20, 21)
local BRASS = Color3.fromRGB(176, 140, 72)
local GLASS = Color3.fromRGB(60, 80, 96)

local ALONG_Z = CFrame.Angles(0, math.rad(90), 0) -- cylinder axis (local X) onto Z
local ALONG_Y = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis onto Y
local ALONG_X = CFrame.new()

type Ctx = { parent: Instance, scale: number, count: number }

local MATERIAL: { [string]: Enum.Material } = {
	metal = Enum.Material.Metal,
	polymer = Enum.Material.SmoothPlastic,
	wood = Enum.Material.Wood,
	rubber = Enum.Material.Fabric,
	brass = Enum.Material.Metal,
	glass = Enum.Material.Glass,
	tape = Enum.Material.Fabric,
}

local function finish(p: BasePart, tint: string, color: Color3)
	p.Color = color
	p.Material = MATERIAL[tint] or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Massless = true
	p:SetAttribute("Tint", tint)
end

local function box(
	ctx: Ctx,
	name: string,
	size: Vector3,
	pos: Vector3,
	tint: string,
	color: Color3,
	rotX: number?
): Part
	local s = ctx.scale
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size * s
	p.CFrame = CFrame.new(pos * s) * CFrame.Angles(math.rad(rotX or 0), 0, 0)
	finish(p, tint, color)
	p.Parent = ctx.parent
	ctx.count += 1
	return p
end

-- Cylinder of `length` and `diameter` centred at pos, along "X" | "Y" | "Z".
local function cyl(
	ctx: Ctx,
	name: string,
	length: number,
	diameter: number,
	pos: Vector3,
	axis: string,
	tint: string,
	color: Color3,
	rotX: number?
): Part
	local s = ctx.scale
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(length, diameter, diameter) * s
	local orient = if axis == "Z" then ALONG_Z elseif axis == "Y" then ALONG_Y else ALONG_X
	p.CFrame = CFrame.new(pos * s) * CFrame.Angles(math.rad(rotX or 0), 0, 0) * orient
	finish(p, tint, color)
	p.Parent = ctx.parent
	ctx.count += 1
	return p
end

-- BUILDERS (sizes in in-hand studs before ctx.scale) --------------------------------------------------------------------

local function pistolGrip(ctx: Ctx, rake: number, color: Color3)
	box(ctx, "Grip", Vector3.new(0.14, 0.44, 0.2), Vector3.new(0, -0.02, 0.03), "polymer", color, -rake)
end

local BUILDERS: { [string]: (Ctx) -> Vector3 } = {}

BUILDERS.pistol = function(ctx)
	pistolGrip(ctx, 14, POLYMER)
	box(ctx, "Frame", Vector3.new(0.13, 0.09, 0.52), Vector3.new(0, 0.19, -0.17), "polymer", POLYMER)
	box(ctx, "Slide", Vector3.new(0.13, 0.13, 0.8), Vector3.new(0, 0.3, -0.2), "metal", STEEL)
	box(ctx, "SlideSerrations", Vector3.new(0.135, 0.09, 0.12), Vector3.new(0, 0.3, 0.12), "metal", STEEL_WORN)
	cyl(ctx, "Barrel", 0.06, 0.075, Vector3.new(0, 0.29, -0.61), "Z", "metal", STEEL_WORN)
	box(ctx, "GuardBottom", Vector3.new(0.04, 0.03, 0.2), Vector3.new(0, 0.07, -0.15), "polymer", POLYMER)
	box(ctx, "GuardFront", Vector3.new(0.04, 0.12, 0.03), Vector3.new(0, 0.12, -0.25), "polymer", POLYMER)
	box(ctx, "Trigger", Vector3.new(0.03, 0.08, 0.03), Vector3.new(0, 0.12, -0.11), "metal", STEEL)
	box(ctx, "Hammer", Vector3.new(0.04, 0.06, 0.05), Vector3.new(0, 0.36, 0.2), "metal", STEEL)
	box(ctx, "FrontSight", Vector3.new(0.02, 0.03, 0.03), Vector3.new(0, 0.38, -0.56), "metal", STEEL)
	box(ctx, "RearSight", Vector3.new(0.1, 0.03, 0.03), Vector3.new(0, 0.38, 0.15), "metal", STEEL)
	box(ctx, "MagBase", Vector3.new(0.15, 0.035, 0.22), Vector3.new(0, -0.25, 0.08), "polymer", POLYMER_GREY)
	return Vector3.new(0, 0.29, -0.64)
end

BUILDERS.handcannon = function(ctx)
	pistolGrip(ctx, 12, RUBBER)
	box(ctx, "Frame", Vector3.new(0.15, 0.1, 0.62), Vector3.new(0, 0.2, -0.22), "metal", STEEL)
	box(ctx, "Slide", Vector3.new(0.16, 0.15, 0.62), Vector3.new(0, 0.32, -0.08), "metal", STEEL)
	box(ctx, "Barrel", Vector3.new(0.13, 0.13, 0.78), Vector3.new(0, 0.34, -0.47), "metal", STEEL_WORN)
	box(ctx, "BarrelRib", Vector3.new(0.05, 0.03, 0.78), Vector3.new(0, 0.42, -0.47), "metal", STEEL)
	box(ctx, "GuardBottom", Vector3.new(0.045, 0.035, 0.24), Vector3.new(0, 0.07, -0.17), "metal", STEEL)
	box(ctx, "GuardFront", Vector3.new(0.045, 0.13, 0.035), Vector3.new(0, 0.12, -0.29), "metal", STEEL)
	box(ctx, "Trigger", Vector3.new(0.03, 0.08, 0.03), Vector3.new(0, 0.13, -0.12), "metal", STEEL_WORN)
	box(ctx, "Hammer", Vector3.new(0.05, 0.07, 0.06), Vector3.new(0, 0.38, 0.24), "metal", STEEL)
	box(ctx, "FrontSight", Vector3.new(0.025, 0.04, 0.04), Vector3.new(0, 0.45, -0.8), "metal", STEEL)
	box(ctx, "RearSight", Vector3.new(0.11, 0.035, 0.04), Vector3.new(0, 0.42, 0.18), "metal", STEEL)
	box(ctx, "MagBase", Vector3.new(0.16, 0.04, 0.24), Vector3.new(0, -0.25, 0.08), "metal", STEEL)
	return Vector3.new(0, 0.34, -0.87)
end

BUILDERS.microsmg = function(ctx)
	pistolGrip(ctx, 6, POLYMER)
	box(ctx, "Receiver", Vector3.new(0.16, 0.2, 0.72), Vector3.new(0, 0.28, -0.18), "metal", STEEL)
	box(ctx, "TopCover", Vector3.new(0.14, 0.04, 0.5), Vector3.new(0, 0.4, -0.12), "metal", STEEL_WORN)
	box(ctx, "CockingKnob", Vector3.new(0.05, 0.05, 0.05), Vector3.new(0, 0.44, -0.3), "metal", STEEL)
	cyl(ctx, "Barrel", 0.25, 0.07, Vector3.new(0, 0.27, -0.66), "Z", "metal", STEEL_WORN)
	cyl(ctx, "BarrelNut", 0.05, 0.11, Vector3.new(0, 0.27, -0.55), "Z", "metal", STEEL)
	box(ctx, "Mag", Vector3.new(0.1, 0.24, 0.14), Vector3.new(0, -0.34, 0.04), "metal", STEEL_WORN, -6)
	box(ctx, "GuardBottom", Vector3.new(0.04, 0.03, 0.22), Vector3.new(0, 0.08, -0.16), "metal", STEEL)
	box(ctx, "Trigger", Vector3.new(0.03, 0.08, 0.03), Vector3.new(0, 0.13, -0.11), "metal", STEEL)
	box(ctx, "StockArm", Vector3.new(0.03, 0.03, 0.42), Vector3.new(0.09, 0.3, 0.12), "metal", STEEL)
	box(ctx, "StockPlate", Vector3.new(0.03, 0.2, 0.05), Vector3.new(0.09, 0.22, 0.32), "metal", STEEL)
	box(ctx, "FrontSight", Vector3.new(0.025, 0.05, 0.03), Vector3.new(0, 0.42, -0.5), "metal", STEEL)
	return Vector3.new(0, 0.27, -0.79)
end

BUILDERS.tacsmg = function(ctx)
	pistolGrip(ctx, 14, POLYMER)
	box(ctx, "Receiver", Vector3.new(0.15, 0.22, 1.0), Vector3.new(0, 0.3, -0.25), "metal", STEEL)
	box(ctx, "TriggerGroup", Vector3.new(0.13, 0.12, 0.42), Vector3.new(0, 0.16, -0.05), "polymer", POLYMER)
	box(ctx, "Handguard", Vector3.new(0.18, 0.19, 0.4), Vector3.new(0, 0.27, -0.95), "polymer", POLYMER)
	cyl(ctx, "CockingTube", 0.55, 0.065, Vector3.new(0, 0.44, -0.78), "Z", "metal", STEEL)
	cyl(ctx, "Barrel", 0.18, 0.075, Vector3.new(0, 0.32, -1.24), "Z", "metal", STEEL_WORN)
	box(ctx, "Mag", Vector3.new(0.09, 0.44, 0.14), Vector3.new(0, 0.0, -0.45), "metal", STEEL_WORN, 12)
	box(ctx, "Magwell", Vector3.new(0.13, 0.1, 0.18), Vector3.new(0, 0.17, -0.44), "metal", STEEL)
	box(ctx, "RearSight", Vector3.new(0.07, 0.07, 0.08), Vector3.new(0, 0.45, 0.15), "metal", STEEL)
	box(ctx, "FrontSight", Vector3.new(0.06, 0.1, 0.05), Vector3.new(0, 0.46, -1.12), "metal", STEEL)
	box(ctx, "StockBarL", Vector3.new(0.025, 0.025, 0.55), Vector3.new(0.065, 0.33, 0.5), "metal", STEEL)
	box(ctx, "StockBarR", Vector3.new(0.025, 0.025, 0.55), Vector3.new(-0.065, 0.33, 0.5), "metal", STEEL)
	box(ctx, "Buttplate", Vector3.new(0.16, 0.3, 0.05), Vector3.new(0, 0.26, 0.78), "rubber", RUBBER)
	return Vector3.new(0, 0.32, -1.33)
end

BUILDERS.pump = function(ctx)
	box(ctx, "Wrist", Vector3.new(0.13, 0.22, 0.36), Vector3.new(0, 0.15, 0.17), "polymer", POLYMER, -10)
	box(ctx, "Receiver", Vector3.new(0.16, 0.28, 0.75), Vector3.new(0, 0.3, -0.3), "metal", STEEL)
	cyl(ctx, "Barrel", 1.66, 0.1, Vector3.new(0, 0.39, -1.5), "Z", "metal", STEEL)
	cyl(ctx, "MagTube", 1.36, 0.11, Vector3.new(0, 0.25, -1.35), "Z", "metal", STEEL_WORN)
	cyl(ctx, "TubeCap", 0.07, 0.12, Vector3.new(0, 0.25, -2.06), "Z", "metal", STEEL)
	box(ctx, "Forend", Vector3.new(0.21, 0.2, 0.56), Vector3.new(0, 0.26, -1.25), "polymer", POLYMER)
	for i = 1, 4 do
		box(
			ctx,
			"ForendRib",
			Vector3.new(0.215, 0.04, 0.04),
			Vector3.new(0, 0.2, -1.07 - i * 0.09),
			"polymer",
			POLYMER_GREY
		)
	end
	box(ctx, "GuardBottom", Vector3.new(0.04, 0.03, 0.26), Vector3.new(0, 0.07, -0.08), "metal", STEEL)
	box(ctx, "Trigger", Vector3.new(0.03, 0.09, 0.03), Vector3.new(0, 0.13, -0.05), "metal", STEEL)
	box(ctx, "Stock", Vector3.new(0.15, 0.34, 0.72), Vector3.new(0, 0.12, 0.66), "polymer", POLYMER, -4)
	box(ctx, "Buttpad", Vector3.new(0.16, 0.42, 0.06), Vector3.new(0, 0.1, 1.04), "rubber", RUBBER)
	cyl(ctx, "Bead", 0.03, 0.035, Vector3.new(0, 0.46, -2.28), "Y", "brass", BRASS)
	return Vector3.new(0, 0.39, -2.34)
end

BUILDERS.comrade = function(ctx)
	box(ctx, "Grip", Vector3.new(0.12, 0.38, 0.18), Vector3.new(0, -0.02, 0.04), "polymer", WALNUT, -16)
	box(ctx, "Receiver", Vector3.new(0.15, 0.24, 0.95), Vector3.new(0, 0.3, -0.3), "metal", STEEL)
	box(ctx, "DustCover", Vector3.new(0.13, 0.05, 0.8), Vector3.new(0, 0.44, -0.2), "metal", STEEL_WORN)
	box(ctx, "Handguard", Vector3.new(0.17, 0.2, 0.46), Vector3.new(0, 0.29, -1.0), "wood", WALNUT)
	box(ctx, "GasTube", Vector3.new(0.11, 0.08, 0.42), Vector3.new(0, 0.43, -1.0), "wood", WALNUT)
	cyl(ctx, "Barrel", 0.84, 0.07, Vector3.new(0, 0.31, -1.64), "Z", "metal", STEEL)
	box(ctx, "FrontSight", Vector3.new(0.06, 0.16, 0.07), Vector3.new(0, 0.38, -1.84), "metal", STEEL)
	cyl(ctx, "MuzzleBrake", 0.13, 0.095, Vector3.new(0, 0.31, -1.99), "Z", "metal", STEEL_WORN)
	box(ctx, "RearSight", Vector3.new(0.08, 0.05, 0.12), Vector3.new(0, 0.46, -0.66), "metal", STEEL)
	box(ctx, "MagUpper", Vector3.new(0.09, 0.3, 0.17), Vector3.new(0, 0.04, -0.5), "metal", STEEL_WORN, 10)
	box(ctx, "MagLower", Vector3.new(0.09, 0.28, 0.17), Vector3.new(0, -0.22, -0.6), "metal", STEEL_WORN, 25)
	box(ctx, "GuardBottom", Vector3.new(0.04, 0.03, 0.24), Vector3.new(0, 0.12, -0.12), "metal", STEEL)
	box(ctx, "Trigger", Vector3.new(0.03, 0.09, 0.03), Vector3.new(0, 0.17, -0.1), "metal", STEEL)
	box(ctx, "Stock", Vector3.new(0.13, 0.28, 0.76), Vector3.new(0, 0.18, 0.56), "wood", WALNUT, -6)
	box(ctx, "Buttplate", Vector3.new(0.14, 0.4, 0.04), Vector3.new(0, 0.12, 0.94), "metal", STEEL)
	return Vector3.new(0, 0.31, -2.06)
end

BUILDERS.carbine = function(ctx)
	box(ctx, "Grip", Vector3.new(0.12, 0.36, 0.17), Vector3.new(0, -0.02, 0.04), "polymer", POLYMER, -18)
	box(ctx, "Upper", Vector3.new(0.14, 0.18, 0.75), Vector3.new(0, 0.36, -0.2), "metal", STEEL)
	box(ctx, "Lower", Vector3.new(0.13, 0.16, 0.6), Vector3.new(0, 0.21, -0.2), "metal", STEEL_WORN)
	box(ctx, "Rail", Vector3.new(0.06, 0.035, 0.72), Vector3.new(0, 0.465, -0.2), "metal", STEEL)
	box(ctx, "Handguard", Vector3.new(0.17, 0.19, 0.8), Vector3.new(0, 0.34, -0.98), "polymer", POLYMER)
	box(ctx, "HandguardRail", Vector3.new(0.06, 0.035, 0.78), Vector3.new(0, 0.45, -0.98), "metal", STEEL)
	cyl(ctx, "Barrel", 0.5, 0.065, Vector3.new(0, 0.33, -1.62), "Z", "metal", STEEL)
	box(ctx, "FrontSight", Vector3.new(0.04, 0.16, 0.04), Vector3.new(0, 0.48, -1.42), "metal", STEEL)
	cyl(ctx, "FlashHider", 0.11, 0.08, Vector3.new(0, 0.33, -1.92), "Z", "metal", STEEL_WORN)
	box(ctx, "OpticMount", Vector3.new(0.08, 0.07, 0.12), Vector3.new(0, 0.51, -0.22), "metal", STEEL)
	cyl(ctx, "Optic", 0.24, 0.13, Vector3.new(0, 0.6, -0.22), "Z", "metal", STEEL)
	cyl(ctx, "OpticLens", 0.01, 0.1, Vector3.new(0, 0.6, -0.345), "Z", "glass", GLASS)
	box(ctx, "Mag", Vector3.new(0.1, 0.42, 0.18), Vector3.new(0, -0.03, -0.36), "metal", STEEL_WORN, 8)
	box(ctx, "GuardBottom", Vector3.new(0.04, 0.03, 0.22), Vector3.new(0, 0.11, -0.1), "metal", STEEL)
	box(ctx, "Trigger", Vector3.new(0.03, 0.08, 0.03), Vector3.new(0, 0.16, -0.08), "metal", STEEL)
	cyl(ctx, "BufferTube", 0.45, 0.1, Vector3.new(0, 0.33, 0.4), "Z", "metal", STEEL)
	box(ctx, "Stock", Vector3.new(0.14, 0.3, 0.32), Vector3.new(0, 0.27, 0.6), "polymer", POLYMER)
	box(ctx, "Buttpad", Vector3.new(0.15, 0.36, 0.05), Vector3.new(0, 0.25, 0.78), "rubber", RUBBER)
	return Vector3.new(0, 0.33, -1.98)
end

BUILDERS.marksman = function(ctx)
	box(ctx, "Grip", Vector3.new(0.12, 0.34, 0.16), Vector3.new(0, -0.02, 0.04), "wood", WALNUT, -18)
	box(ctx, "Receiver", Vector3.new(0.14, 0.24, 0.85), Vector3.new(0, 0.3, -0.3), "metal", STEEL)
	box(ctx, "Handguard", Vector3.new(0.15, 0.2, 0.6), Vector3.new(0, 0.3, -1.03), "wood", WALNUT)
	cyl(ctx, "Barrel", 1.26, 0.07, Vector3.new(0, 0.32, -1.96), "Z", "metal", STEEL)
	cyl(ctx, "FlashHider", 0.15, 0.09, Vector3.new(0, 0.32, -2.64), "Z", "metal", STEEL_WORN)
	box(ctx, "ScopeMount", Vector3.new(0.06, 0.16, 0.3), Vector3.new(0, 0.47, -0.3), "metal", STEEL)
	cyl(ctx, "Scope", 0.76, 0.14, Vector3.new(0, 0.6, -0.3), "Z", "metal", STEEL)
	cyl(ctx, "ScopeBell", 0.14, 0.2, Vector3.new(0, 0.6, -0.72), "Z", "metal", STEEL)
	cyl(ctx, "ScopeEye", 0.12, 0.17, Vector3.new(0, 0.6, 0.12), "Z", "metal", STEEL)
	cyl(ctx, "ScopeLens", 0.01, 0.17, Vector3.new(0, 0.6, -0.795), "Z", "glass", GLASS)
	box(ctx, "Mag", Vector3.new(0.09, 0.3, 0.16), Vector3.new(0, 0.03, -0.42), "metal", STEEL_WORN, 10)
	box(ctx, "GuardBottom", Vector3.new(0.04, 0.03, 0.22), Vector3.new(0, 0.11, -0.1), "metal", STEEL)
	box(ctx, "Trigger", Vector3.new(0.03, 0.08, 0.03), Vector3.new(0, 0.16, -0.08), "metal", STEEL)
	box(ctx, "Stock", Vector3.new(0.12, 0.34, 0.9), Vector3.new(0, 0.15, 0.6), "wood", WALNUT)
	box(ctx, "CheekRest", Vector3.new(0.13, 0.07, 0.4), Vector3.new(0, 0.38, 0.56), "wood", WALNUT)
	box(ctx, "Buttplate", Vector3.new(0.14, 0.42, 0.05), Vector3.new(0, 0.12, 1.07), "rubber", RUBBER)
	return Vector3.new(0, 0.32, -2.72)
end

BUILDERS.bat = function(ctx)
	cyl(ctx, "Knob", 0.05, 0.17, Vector3.new(0, -0.42, 0), "Y", "wood", ASH)
	cyl(ctx, "GripTape", 0.85, 0.13, Vector3.new(0, 0.02, 0), "Y", "tape", TAPE)
	cyl(ctx, "Taper", 0.62, 0.17, Vector3.new(0, 0.75, 0), "Y", "wood", ASH)
	cyl(ctx, "Barrel", 1.15, 0.245, Vector3.new(0, 1.62, 0), "Y", "wood", ASH)
	cyl(ctx, "End", 0.05, 0.22, Vector3.new(0, 2.22, 0), "Y", "wood", ASH)
	return Vector3.new(0, 2.25, 0)
end

BUILDERS.crowbar = function(ctx)
	cyl(ctx, "Shaft", 1.5, 0.09, Vector3.new(0, 0.55, 0), "Y", "metal", STEEL)
	box(ctx, "HookA", Vector3.new(0.09, 0.3, 0.09), Vector3.new(0, 1.38, -0.08), "metal", STEEL, 40)
	box(ctx, "HookB", Vector3.new(0.09, 0.24, 0.09), Vector3.new(0, 1.47, -0.27), "metal", STEEL, 100)
	box(ctx, "Claw", Vector3.new(0.1, 0.22, 0.06), Vector3.new(0, -0.27, -0.03), "metal", STEEL_WORN, 15)
	return Vector3.new(0, 1.5, -0.3)
end

BUILDERS.nightstick = function(ctx)
	cyl(ctx, "Shaft", 2.0, 0.12, Vector3.new(0, 0.8, 0), "Y", "polymer", POLYMER)
	cyl(ctx, "SideHandle", 0.42, 0.11, Vector3.new(0, 0.12, -0.22), "Z", "polymer", POLYMER)
	cyl(ctx, "Cap", 0.04, 0.13, Vector3.new(0, 1.8, 0), "Y", "rubber", RUBBER)
	return Vector3.new(0, 1.8, 0)
end

BUILDERS.knuckles = function(ctx)
	box(ctx, "Bar", Vector3.new(0.44, 0.09, 0.07), Vector3.new(0, -0.05, -0.12), "brass", BRASS)
	for i = 0, 3 do
		cyl(ctx, "Ring", 0.07, 0.13, Vector3.new(-0.165 + i * 0.11, 0.05, -0.12), "Z", "brass", BRASS)
	end
	box(ctx, "Palm", Vector3.new(0.3, 0.06, 0.1), Vector3.new(0, -0.1, 0.0), "brass", BRASS)
	return Vector3.new(0, 0.05, -0.15)
end

BUILDERS.fists = function(_ctx)
	return Vector3.zero
end

-- Kessler Stun Gun (gadget): yellow / black polymer, like the real thing.
BUILDERS.taser = function(ctx)
	pistolGrip(ctx, 12, POLYMER)
	box(ctx, "Body", Vector3.new(0.14, 0.17, 0.5), Vector3.new(0, 0.28, -0.14), "polymer", Color3.fromRGB(214, 176, 44))
	box(ctx, "Cartridge", Vector3.new(0.15, 0.16, 0.14), Vector3.new(0, 0.28, -0.46), "polymer", POLYMER)
	box(ctx, "GuardBottom", Vector3.new(0.04, 0.03, 0.2), Vector3.new(0, 0.08, -0.13), "polymer", POLYMER)
	box(ctx, "Trigger", Vector3.new(0.03, 0.08, 0.03), Vector3.new(0, 0.13, -0.1), "polymer", POLYMER)
	box(ctx, "Laser", Vector3.new(0.05, 0.04, 0.06), Vector3.new(0, 0.18, -0.36), "polymer", POLYMER_GREY)
	return Vector3.new(0, 0.28, -0.54)
end

-- Stinger Strip carried case (gadget).
BUILDERS.spikes = function(ctx)
	box(ctx, "Case", Vector3.new(0.7, 0.26, 0.42), Vector3.new(0, -0.05, 0), "polymer", POLYMER)
	box(ctx, "Band", Vector3.new(0.72, 0.06, 0.43), Vector3.new(0, 0.02, 0), "polymer", Color3.fromRGB(214, 176, 44))
	box(ctx, "Strap", Vector3.new(0.3, 0.05, 0.08), Vector3.new(0, 0.12, 0), "rubber", RUBBER)
	return Vector3.new(0, 0, -0.25)
end

function WeaponModels.has(key: string): boolean
	return BUILDERS[key] ~= nil
end

-- Builds the parts of `key` into `container` around a fresh invisible "Handle". Returns (handle, partCount).
function WeaponModels.assemble(container: Instance, key: string, scale: number?): (BasePart, number)
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.2, 0.2, 0.2)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.CanTouch = false
	handle.CanQuery = false
	handle.CastShadow = false
	handle.Massless = true
	handle.CFrame = CFrame.new()
	handle.Parent = container
	local ctx: Ctx = { parent = container, scale = scale or 1, count = 0 }
	local builder = BUILDERS[key] or BUILDERS.fists
	local muzzle = builder(ctx)
	local att = Instance.new("Attachment")
	att.Name = "Muzzle"
	att.Position = muzzle * ctx.scale
	att.Parent = handle
	return handle, ctx.count
end

-- Welds every other BasePart in `container` to `handle` (WeldConstraint parented to the part), unanchored.
function WeaponModels.weld(container: Instance, handle: BasePart)
	handle.Anchored = false
	for _, d in container:GetDescendants() do
		if d:IsA("BasePart") and d ~= handle then
			d.Anchored = false
			local w = Instance.new("WeldConstraint")
			w.Part0 = handle
			w.Part1 = d
			w.Parent = d
		end
	end
end

-- A display model (anchored, PrimaryPart = Handle) for ViewportFrames.
function WeaponModels.buildModel(key: string, scale: number?): Model
	local model = Instance.new("Model")
	model.Name = key
	local handle = WeaponModels.assemble(model, key, scale)
	model.PrimaryPart = handle
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	return model
end

-- Recolours tintable parts (metal + polymer) of a built weapon.
function WeaponModels.applyTint(container: Instance, color: Color3, material: Enum.Material)
	for _, d in container:GetDescendants() do
		if d:IsA("BasePart") then
			local tint = d:GetAttribute("Tint")
			if tint == "metal" or tint == "polymer" then
				d.Color = color
				d.Material = material
			end
		end
	end
end

return WeaponModels
