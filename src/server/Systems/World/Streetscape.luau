--!strict
-- World/Streetscape: the baked street furniture (WorldLayout.Streetscape, server only) as low-part props.
--
--   lamp          pole + cobra head (2 parts). The head is tagged "StreetLight" + "NightGlow" (lens glows at night);
--                 LIGHT_SHARE of them carry a downward SpotLight (mobile light budget: ~40 % of ~1.7k lamps, never
--                 two lit neighbours in a row on one side)
--   freeway_lamp  tall median pole with a cross arm and two heads (4 parts); only the data's `light` ones are lit
--   palm          Washingtonia: trunk + compact head + four drooping fronds (6 parts; SpecialMesh spheres)
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

Streetscape.TAG_LIGHT = "StreetLight"

-- Real light pools at night (VIBE_ROUTING #12). Every lamp head glows (NightGlow); a SpotLight pointing down makes the
-- pool on the asphalt. Lights are budgeted per 512-stud streaming cell (World/Kit cells), so a client never holds more
-- than LIGHT_BUDGET lights per cell it has streamed in: freeway heads first (the deck is otherwise pitch black), then
-- street lamps in a deterministic order, no two lit street lamps closer than LIGHT_SPACING. The densest cell has 23
-- heads, so most cells light every lamp.
Streetscape.LIGHT_BUDGET = 16
Streetscape.LIGHT_SPACING = 55
-- range / brightness / cone angle; `drop` puts the source that far under the head (an Attachment) so a tall freeway
-- mast still throws a full pool on the deck within the engine's 60-stud light range
Streetscape.LIGHT = {
	street = { range = 48, brightness = 3, angle = 120, drop = 0.6 },
	freeway = { range = 56, brightness = 4.5, angle = 116, drop = 10 },
}
-- High-pressure sodium on the freeways, industry, suburbs and countryside; warm white in the core and the beach.
Streetscape.SODIUM = Color3.fromRGB(255, 160, 76)
Streetscape.WARM_WHITE = Color3.fromRGB(255, 222, 182)
Streetscape.WARM_DISTRICTS = { downtown = true, midtown = true, beach = true, hills = true } :: { [string]: boolean }

local LAMP_DAY = Color3.fromRGB(196, 196, 186)

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

-- Lamp colour by where it stands: sodium on freeways and outside the core, warm white in the core and the beach.
function Streetscape.lampColor(kind: string, p: Place): Color3
	if kind == "freeway_lamp" then
		return Streetscape.SODIUM
	end
	local e = p.edge and WorldLayout.Edges[p.edge]
	local district = if e then e.district else WorldLayout.districtAt(p.pos.X, p.pos.Z)
	if e and (e.class == "freeway" or e.class == "ramp" or e.class == "highway") then
		return Streetscape.SODIUM
	end
	return if Streetscape.WARM_DISTRICTS[district] then Streetscape.WARM_WHITE else Streetscape.SODIUM
end

export type LightPlan = { lamp: { [number]: boolean }, freeway_lamp: { [number]: boolean }, perCell: { [string]: number } }
local planCache: LightPlan? = nil

-- Which lamps carry a real light (deterministic; independent of build order and of the near / far boot split).
function Streetscape.lightPlan(): LightPlan
	local cached = planCache
	if cached then
		return cached
	end
	local S = WorldLayout.Streetscape
	type Cand = { kind: string, index: number, pos: Vector3, rank: number, cost: number }
	local byCell: { [string]: { Cand } } = {}
	local function add(kind: string, index: number, pos: Vector3, rank: number, cost: number)
		local key = math.floor(pos.X / Kit.CELL) .. "_" .. math.floor(pos.Z / Kit.CELL)
		local list = byCell[key]
		if not list then
			list = {}
			byCell[key] = list
		end
		table.insert(list, { kind = kind, index = index, pos = pos, rank = rank, cost = cost })
	end
	for i, p in S.freeway_lamp or {} do
		add("freeway_lamp", i, p.pos, Kit.hash(i, 91, 4401), 2) -- two heads per mast
	end
	for i, p in S.lamp or {} do
		if p.light ~= false then
			add("lamp", i, p.pos, 1 + Kit.hash(i, 77, 4401), 1)
		end
	end
	local plan: LightPlan = { lamp = {}, freeway_lamp = {}, perCell = {} }
	local keys: { string } = {}
	for key in byCell do
		table.insert(keys, key)
	end
	table.sort(keys)
	local spacing2 = Streetscape.LIGHT_SPACING * Streetscape.LIGHT_SPACING
	for _, key in keys do
		local list = byCell[key]
		table.sort(list, function(a: Cand, b: Cand): boolean
			if a.rank ~= b.rank then
				return a.rank < b.rank
			end
			return a.index < b.index
		end)
		local used = 0
		local lit: { Vector3 } = {}
		for _, c in list do
			if used + c.cost > Streetscape.LIGHT_BUDGET then
				continue
			end
			local ok = true
			if c.kind == "lamp" then
				for _, q in lit do
					local dx, dz = q.X - c.pos.X, q.Z - c.pos.Z
					if dx * dx + dz * dz < spacing2 and math.abs(q.Y - c.pos.Y) < 12 then
						ok = false
						break
					end
				end
			end
			if ok then
				used += c.cost
				plan[c.kind][c.index] = true
				if c.kind == "lamp" then
					table.insert(lit, c.pos)
				end
			end
		end
		plan.perCell[key] = used
	end
	planCache = plan
	return plan
end

-- A downward SpotLight under `head` (in an Attachment `drop` studs below it), off by day: LightingService switches
-- every "StreetLight"-tagged instance's lights at night.
local function addLight(head: BasePart, spec: { range: number, brightness: number, angle: number, drop: number }, color: Color3)
	local att = Instance.new("Attachment")
	att.Name = "LightPool"
	att.CFrame = head.CFrame:ToObjectSpace(CFrame.new(head.Position - Vector3.new(0, spec.drop, 0)))
	att.Parent = head
	local l = Instance.new("SpotLight")
	l.Name = "Light"
	l.Face = Enum.NormalId.Bottom
	l.Angle = spec.angle
	l.Range = spec.range
	l.Brightness = spec.brightness
	l.Color = color
	l.Shadows = false
	l.Enabled = false
	l.Parent = att
	CollectionService:AddTag(att, Streetscape.TAG_LIGHT)
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
	local color = Streetscape.lampColor("lamp", p)
	Kit.nightGlow(head, color)
	if Streetscape.lightPlan().lamp[index] then
		-- the pool comes from the lens at the street end of the head
		local lens = head.CFrame * CFrame.new(0, -0.4, -(reach + 1) / 2 + 1)
		local att = Instance.new("Attachment")
		att.Name = "LightPool"
		att.CFrame = head.CFrame:ToObjectSpace(CFrame.new(lens.Position))
		att.Parent = head
		local spec = Streetscape.LIGHT.street
		local l = Instance.new("SpotLight")
		l.Name = "Light"
		l.Face = Enum.NormalId.Bottom
		l.Angle = spec.angle
		l.Range = spec.range
		l.Brightness = spec.brightness
		l.Color = color
		l.Shadows = false
		l.Enabled = false
		l.Parent = att
		CollectionService:AddTag(att, Streetscape.TAG_LIGHT)
	end
end

local function freewayLamp(ctx: Ctx, p: Place, index: number)
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
	local lit = Streetscape.lightPlan().freeway_lamp[index] == true
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
		Kit.nightGlow(head, Streetscape.SODIUM)
		if lit then
			addLight(head, Streetscape.LIGHT.freeway, Streetscape.SODIUM)
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
	-- a compact head of fan leaves with four fronds drooping out of it, so the silhouette reads as a palm from the
	-- street and from the air (a flat pair of crossed fronds read as a mushroom with ears)
	local yaw = math.rad(p.yaw)
	ellipsoid(
		ctx,
		"PalmCrown",
		Vector3.new(9, 7, 9),
		CFrame.new(top + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, yaw, 0),
		Kit.style("foliage_palm")
	)
	local len = 17
	for k = 0, 3 do
		local a = yaw + k * math.pi / 2 + 0.35
		local droop = math.rad(24 + 10 * Kit.hash(index, 5 + k, 811))
		local out = Vector3.new(math.cos(a), 0, -math.sin(a))
		local centre = top + out * (len / 2 * math.cos(droop)) - Vector3.new(0, len / 2 * math.sin(droop) - 1, 0)
		ellipsoid(
			ctx,
			"PalmFrond",
			Vector3.new(len, 1.2, 5.5),
			CFrame.new(centre) * CFrame.Angles(0, a, 0) * CFrame.Angles(0, 0, -droop),
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
