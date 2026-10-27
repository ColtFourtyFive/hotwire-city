--!strict
-- World/Streetscape: the baked street furniture (WorldLayout.Streetscape, server only) as low-part props.
--
--   lamp          pole + cobra head (2 parts). The head is tagged "StreetLight" + "NightGlow" (lens glows at night);
--                 LIGHT_SHARE of them carry a downward SpotLight (mobile light budget: ~40 % of ~1.7k lamps, never
--                 two lit neighbours in a row on one side)
--   freeway_lamp  tall median pole with a cross arm and two heads (4 parts); only the data's `light` ones are lit
--   palm          Washingtonia: trunk + dead-frond skirt + round head + two crossed fronds (5 parts; SpecialMesh spheres)
--   tree          trunk + canopy ellipsoid (2 parts)
--   pole          wooden utility pole + cross arm, a wire to the next pole of the same run (3 parts)
--   billboard     monopole + 52 x 15 bulletin panel tagged "Billboard" (MapDresser puts the ad decal on)
--   busstop       roof + glass back + bench (3)
--   hydrant, bin  1 part each
--
-- Every prop's first part carries attribute Prop = kind (a mesh dresser can swap them later, PropsV2).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local Kit = require(script.Parent.Kit)

type Ctx = Kit.Ctx
type Place = WorldLayout.Place

local Streetscape = {}

Streetscape.LIGHT_SHARE = 0.4
Streetscape.TAG_LIGHT = "StreetLight"

local LAMP_DAY = Color3.fromRGB(196, 196, 186)
local LAMP_NIGHT = Color3.fromRGB(255, 214, 160)
local SODIUM = Color3.fromRGB(255, 196, 132)

local AD_TEXTS = {
	"NITRO COLA",
	"DUCK INSURANCE",
	"GOT CARS?",
	"SPEEDY SNAX",
	"CRUISE CONTROL",
	"TURBO TOAST",
	"HONK MORE",
	"VROOM VITAMINS",
}

local function yawCF(pos: Vector3, yaw: number): CFrame
	return CFrame.new(pos) * CFrame.Angles(0, math.rad(yaw), 0)
end

local function ellipsoid(ctx: Ctx, cat: string, size: Vector3, cf: CFrame, style: Kit.Style): Part
	local p = Kit.part(ctx, cat, size, cf, style, { collide = false, query = false })
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = p
	return p
end

local function addLight(head: BasePart, range: number, brightness: number)
	local l = Instance.new("SpotLight")
	l.Name = "Light"
	l.Face = Enum.NormalId.Bottom
	l.Angle = 120
	l.Range = range
	l.Brightness = brightness
	l.Color = SODIUM
	l.Shadows = false
	l.Enabled = false
	l.Parent = head
	CollectionService:AddTag(head, Streetscape.TAG_LIGHT)
end

-- Cobra-head lamp: pole at pos, the head reaching toward the road (yaw = facing the road).
local function lamp(ctx: Ctx, p: Place, index: number)
	local h = p.h or 26
	local cf = yawCF(p.pos, p.yaw)
	local pole = Kit.post(ctx, "LampPole", p.pos, h, 0.9, Kit.style("metal_grey"), { shadow = false })
	pole:SetAttribute("Prop", "lamp")
	local reach = 7
	local head = Kit.part(
		ctx,
		"LampHead",
		Vector3.new(1.5, 0.8, reach + 1),
		cf * CFrame.new(0, h - 0.2, -(reach + 1) / 2 + 0.4) * CFrame.Angles(math.rad(4), 0, 0),
		Kit.style("metal_grey"),
		{ collide = false, shadow = false }
	)
	head.Color = LAMP_DAY
	Kit.nightGlow(head, LAMP_NIGHT)
	-- the lamp budget: a deterministic share carries a real light
	if p.light ~= false and Kit.hash(index, 77, 4401) < Streetscape.LIGHT_SHARE then
		addLight(head, 48, 2.2)
	end
end

local function freewayLamp(ctx: Ctx, p: Place)
	local h = p.h or 34
	local cf = yawCF(p.pos, p.yaw)
	local pole = Kit.post(ctx, "FwLampPole", p.pos, h, 1.2, Kit.style("metal_grey"), { shadow = false })
	pole:SetAttribute("Prop", "freeway_lamp")
	local arm = 22
	Kit.part(
		ctx,
		"FwLampArm",
		Vector3.new(arm * 2, 0.6, 0.6),
		cf * CFrame.new(0, h, 0),
		Kit.style("metal_grey"),
		{ collide = false, shadow = false }
	)
	for _, side in { -1, 1 } do
		local head = Kit.part(
			ctx,
			"FwLampHead",
			Vector3.new(3.2, 0.8, 1.6),
			cf * CFrame.new(side * (arm - 1.5), h - 0.6, 0),
			Kit.style("metal_grey"),
			{ collide = false, shadow = false }
		)
		head.Color = LAMP_DAY
		Kit.nightGlow(head, LAMP_NIGHT)
		if p.light then
			addLight(head, 60, 2.4)
		end
	end
end

local function palm(ctx: Ctx, p: Place, index: number)
	local h = p.h or 80
	local lean = (Kit.hash(index, 3, 811) - 0.5) * 0.08
	local d = 2.2 + Kit.hash(index, 4, 811) * 0.6
	local trunk = Kit.part(
		ctx,
		"PalmTrunk",
		Vector3.new(h, d, d),
		CFrame.new(p.pos + Vector3.new(0, h / 2, 0))
			* CFrame.Angles(0, math.rad(p.yaw), 0)
			* CFrame.Angles(lean, 0, 0)
			* CFrame.Angles(0, 0, math.pi / 2),
		Kit.style("palm_trunk"),
		{ shape = Enum.PartType.Cylinder }
	)
	trunk:SetAttribute("Prop", "palm")
	local top = trunk.CFrame * Vector3.new(h / 2, 0, 0)
	-- dead fronds (the brown "skirt") under a round head of fan leaves, two long fronds breaking the silhouette
	ellipsoid(ctx, "PalmSkirt", Vector3.new(6, 9, 6), CFrame.new(top - Vector3.new(0, 4.5, 0)), Kit.style("bark"))
	local yaw = math.rad(p.yaw)
	ellipsoid(
		ctx,
		"PalmCrown",
		Vector3.new(11, 8, 11),
		CFrame.new(top + Vector3.new(0, 1, 0)) * CFrame.Angles(0, yaw, 0),
		Kit.style("foliage_palm")
	)
	for k = 0, 1 do
		ellipsoid(
			ctx,
			"PalmFrond",
			Vector3.new(22, 1.6, 5),
			CFrame.new(top + Vector3.new(0, 0.5, 0))
				* CFrame.Angles(0, yaw + k * math.pi / 2 + 0.4, math.rad(if k == 0 then 8 else -8)),
			Kit.style("foliage_palm")
		)
	end
end

local function tree(ctx: Ctx, p: Place, index: number)
	local h = p.h or 26
	local trunkH = h * 0.42
	local trunk = Kit.post(ctx, "TreeTrunk", p.pos, trunkH + 2, 1.6, Kit.style("bark"))
	trunk:SetAttribute("Prop", "tree")
	local w = h * (0.55 + Kit.hash(index, 5, 1231) * 0.2)
	local tint = Kit.hash(index, 6, 1231)
	local canopy = ellipsoid(
		ctx,
		"TreeCanopy",
		Vector3.new(w, h - trunkH + 2, w * 0.9),
		CFrame.new(p.pos + Vector3.new(0, trunkH + (h - trunkH) / 2, 0)) * CFrame.Angles(0, math.rad(p.yaw), 0),
		Kit.style("foliage")
	)
	canopy.Color = Color3.fromRGB(math.floor(66 + tint * 24), math.floor(92 + tint * 20), math.floor(46 + tint * 10))
end

local function pole(ctx: Ctx, p: Place, nextPole: Place?)
	local h = p.h or 45
	local cf = yawCF(p.pos, p.yaw)
	local post = Kit.post(ctx, "UtilityPole", p.pos - Vector3.new(0, 2, 0), h + 2, 1.4, Kit.style("pole_wood"))
	post:SetAttribute("Prop", "pole")
	Kit.part(
		ctx,
		"PoleArm",
		Vector3.new(9, 0.6, 0.6),
		cf * CFrame.new(0, h - 2, 0),
		Kit.style("pole_wood"),
		{ collide = false, shadow = false }
	)
	if nextPole and (nextPole.pos - p.pos).Magnitude < 260 then
		local a = p.pos + Vector3.new(0, h - 1.6, 0)
		local b = nextPole.pos + Vector3.new(0, (nextPole.h or 45) - 1.6, 0)
		Kit.rod(ctx, "Wire", a, b, 0.18, Kit.style("paint_black"), { collide = false, query = false, shadow = false })
	end
end

local function billboard(ctx: Ctx, p: Place, index: number)
	local h = p.h or 40
	local cf = yawCF(p.pos, p.yaw)
	local post = Kit.post(ctx, "BillboardPole", p.pos - Vector3.new(0, 3, 0), h + 3, 3.2, Kit.style("metal_grey"))
	post:SetAttribute("Prop", "billboard")
	local board = Kit.part(
		ctx,
		"Billboard",
		Vector3.new(52, 15, 1.2),
		cf * CFrame.new(0, h + 7.5, 0),
		Kit.style("sign_white"),
		{ tag = "Billboard" }
	)
	board:SetAttribute("AdBack", false)
	board:SetAttribute("AdText", AD_TEXTS[(index - 1) % #AD_TEXTS + 1])
end

local function busstop(ctx: Ctx, p: Place)
	local cf = yawCF(p.pos, p.yaw)
	-- the shelter faces the road (LookVector); its back panel stands away from the curb
	local roof =
		Kit.part(ctx, "BusShelter", Vector3.new(14, 0.5, 5.5), cf * CFrame.new(0, 8.6, 0), Kit.style("metal_dark"))
	roof:SetAttribute("Prop", "busstop")
	Kit.part(
		ctx,
		"BusShelterBack",
		Vector3.new(14, 7.6, 0.3),
		cf * CFrame.new(0, 4.6, 2.5),
		Kit.style("glass_clear"),
		{ transparency = 0.55 }
	)
	Kit.part(ctx, "BusBench", Vector3.new(10, 0.5, 1.8), cf * CFrame.new(0, 1.8, 1.4), Kit.style("metal_grey"))
end

local function hydrant(ctx: Ctx, p: Place)
	local hp = Kit.post(ctx, "Hydrant", p.pos, 2.6, 1.1, Kit.style("paint_yellow"))
	hp:SetAttribute("Prop", "hydrant")
end

local function bin(ctx: Ctx, p: Place)
	local b = Kit.post(ctx, "Bin", p.pos, 3.2, 2.1, Kit.style("metal_green"))
	b:SetAttribute("Prop", "bin")
end

-- Builds every placement (filter: kind, index -> keep?).
function Streetscape.build(ctx: Ctx, filter: ((Place) -> boolean)?)
	local S = WorldLayout.Streetscape
	local function each(kind: string, fn: (Place, number) -> ())
		for i, p in S[kind] or {} do
			if filter == nil or filter(p) then
				fn(p, i)
				Kit.tick(ctx)
			end
		end
	end
	each("lamp", function(p, i)
		lamp(ctx, p, i)
	end)
	each("freeway_lamp", function(p)
		freewayLamp(ctx, p)
	end)
	each("palm", function(p, i)
		palm(ctx, p, i)
	end)
	each("tree", function(p, i)
		tree(ctx, p, i)
	end)
	local poles = S.pole or {}
	each("pole", function(p, i)
		local nxt = poles[i + 1]
		pole(ctx, p, if nxt and nxt.run == p.run then nxt else nil)
	end)
	each("billboard", function(p, i)
		billboard(ctx, p, i)
	end)
	each("busstop", function(p)
		busstop(ctx, p)
	end)
	each("hydrant", function(p)
		hydrant(ctx, p)
	end)
	each("bin", function(p)
		bin(ctx, p)
	end)
end

return Streetscape
