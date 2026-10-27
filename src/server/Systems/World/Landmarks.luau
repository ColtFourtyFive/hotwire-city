--!strict
-- World/Landmarks: WorldLayout.Landmarks and PropClusters as structures (MapBuilder v2).
--
--   hill_sign     the SUNWOOD sign: 7 block letters (2-5 strokes each) standing on the ridge at their own footing,
--                 lit at night (NightGlow); LevelOfDetail kept via the Landmarks folder models
--   lighthouse, tower (HCI control tower), dam, race_track (grandstands + light towers), quarry (crusher),
--   cranes (5 ship-to-shore gantries), ship (MV Rust Bucket), marina (jetties), breakwater, park (lawns, fountain,
--   Echo Park lake), observatory dome
--   clusters      pumpjacks, wind turbines, substation pylons (+ wires), prison guard towers, trailers
-- Terrain landforms (peak, mesas, cuesta, beach, golf course) are World/Terrain's.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local WorldTerrain = require(Shared.Util.WorldTerrain)
local Kit = require(script.Parent.Kit)

type Ctx = Kit.Ctx
type Landmark = WorldLayout.Landmark

local Landmarks = {}

local function model(ctx: Ctx, name: string, pivot: CFrame): Model
	local m = Instance.new("Model")
	m.Name = name
	pcall(function()
		(m :: any).ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	end)
	m.WorldPivot = pivot
	m.Parent = Kit.folder(ctx, "Landmarks")
	return m
end

local function ground(x: number, z: number): number
	return WorldTerrain.heightAt(x, z)
end

local function at(F: CFrame, x: number, y: number, z: number): CFrame
	return F * CFrame.new(x, y, z)
end

-------------------------------------------------------------------------------------------------------------------------
-- SUNWOOD
-------------------------------------------------------------------------------------------------------------------------

-- Strokes per letter on a unit box (x right 0..1, y up 0..1): { x0, y0, x1, y1 } rectangles; "d" = the N diagonal.
local LETTERS: { [string]: { { number } } } = {
	S = { { 0, 0.84, 1, 1 }, { 0, 0.5, 0.2, 0.92 }, { 0, 0.42, 1, 0.58 }, { 0.8, 0.08, 1, 0.5 }, { 0, 0, 1, 0.16 } },
	U = { { 0, 0.1, 0.2, 1 }, { 0.8, 0.1, 1, 1 }, { 0, 0, 1, 0.16 } },
	N = { { 0, 0, 0.2, 1 }, { 0.8, 0, 1, 1 }, { -1 } },
	W = { { 0, 0.1, 0.18, 1 }, { 0.82, 0.1, 1, 1 }, { 0.41, 0.1, 0.59, 0.62 }, { 0, 0, 1, 0.16 } },
	O = { { 0, 0, 0.2, 1 }, { 0.8, 0, 1, 1 }, { 0.1, 0.84, 0.9, 1 }, { 0.1, 0, 0.9, 0.16 } },
	D = { { 0, 0, 0.2, 1 }, { 0.1, 0.84, 0.72, 1 }, { 0.1, 0, 0.72, 0.16 }, { 0.8, 0.14, 1, 0.86 } },
}

local function sunwood(ctx: Ctx, l: Landmark)
	-- the letters are laid out in a frame turned to face away from the viewer, so its +X is the viewer's right and
	-- the word reads left to right from the city (the landmark's LookVector faces the city)
	local F = l.cframe * CFrame.Angles(0, math.pi, 0)
	local m = model(ctx, l.id, F)
	local word = "SUNWOOD"
	local W, H = l.size.X, l.size.Y
	local slot = W / #word
	local lw = slot * 0.84
	local depth = 4
	local white = Kit.style("sign_white")
	for i = 1, #word do
		local ch = string.sub(word, i, i)
		local cxl = -W / 2 + (i - 0.5) * slot
		-- each letter stands on its own footing (the ridge is not level)
		local foot = (F * CFrame.new(cxl, 0, 0)).Position
		local g = ground(foot.X, foot.Z)
		local base = F.Rotation + Vector3.new(foot.X, g - 3, foot.Z)
		for _, st in LETTERS[ch] do
			if st[1] == -1 then
				-- N diagonal from the top-left to the bottom-right
				local a = at(base, -lw / 2 + lw * 0.12, H * 0.92, 0).Position
				local b = at(base, lw / 2 - lw * 0.12, H * 0.08, 0).Position
				-- (Kit.beam: w lies across the beam horizontally = the letter's depth here; h stays in the letter plane)
				local p = Kit.beam(ctx, "Letter", a, b, depth, lw * 0.22, white, { parent = m })
				Kit.nightGlow(p, Color3.fromRGB(255, 250, 235))
				continue
			end
			local x0, y0, x1, y1 = st[1], st[2], st[3], st[4]
			local sx, sy = (x1 - x0) * lw, (y1 - y0) * H
			local cx = -lw / 2 + (x0 + x1) / 2 * lw
			local cy = (y0 + y1) / 2 * H
			local p = Kit.part(ctx, "Letter", Vector3.new(sx, sy, depth), at(base, cx, cy, 0), white, { parent = m })
			Kit.nightGlow(p, Color3.fromRGB(255, 250, 235))
		end
		-- scaffold legs behind the letter
		for _, lx in { -lw * 0.3, lw * 0.3 } do
			Kit.part(
				ctx,
				"SignLeg",
				Vector3.new(1.2, H * 0.6, 1.2),
				at(base, lx, H * 0.3, -(depth / 2 + 3)),
				Kit.style("metal_grey"),
				{
					parent = m,
				}
			)
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- structures
-------------------------------------------------------------------------------------------------------------------------

local function lighthouse(ctx: Ctx, l: Landmark)
	local p = l.cframe.Position
	local g = ground(p.X, p.Z)
	local m = model(ctx, l.id, CFrame.new(p))
	local H = l.size.Y
	local o: Kit.PartOpts = { parent = m }
	Kit.post(ctx, "LighthouseTower", Vector3.new(p.X, g - 2, p.Z), H * 0.8 + 2, 22, Kit.style("stucco_white"), o)
	Kit.post(ctx, "LighthouseBand", Vector3.new(p.X, g + H * 0.45, p.Z), 10, 22.4, Kit.style("paint_red"), o)
	Kit.post(ctx, "LighthouseGallery", Vector3.new(p.X, g + H * 0.8, p.Z), 1.5, 30, Kit.style("metal_dark"), o)
	local lamp =
		Kit.post(ctx, "LighthouseLamp", Vector3.new(p.X, g + H * 0.8 + 1.5, p.Z), 12, 14, Kit.style("glass_clear"), o)
	Kit.nightGlow(lamp, Color3.fromRGB(255, 240, 200))
	local light = Instance.new("PointLight")
	light.Range = 60
	light.Brightness = 3
	light.Color = Color3.fromRGB(255, 236, 190)
	light.Enabled = false
	light.Parent = lamp
	lamp:AddTag("StreetLight")
	Kit.part(
		ctx,
		"LighthouseRoof",
		Vector3.new(16, 16, 16),
		CFrame.new(p.X, g + H * 0.8 + 15, p.Z),
		Kit.style("paint_red"),
		{
			parent = m,
			shape = Enum.PartType.Ball,
		}
	)
end

local function controlTower(ctx: Ctx, l: Landmark)
	local p = l.cframe.Position
	local g = ground(p.X, p.Z)
	local m = model(ctx, l.id, CFrame.new(p))
	local H = l.size.Y
	local o: Kit.PartOpts = { parent = m }
	Kit.post(ctx, "TowerShaft", Vector3.new(p.X, g, p.Z), H - 22, 14, Kit.style("concrete_modern"), o)
	local cab =
		Kit.part(ctx, "TowerCab", Vector3.new(30, 14, 30), CFrame.new(p.X, g + H - 15, p.Z), Kit.style("glass"), o)
	Kit.nightGlow(cab, Color3.fromRGB(120, 200, 255))
	Kit.part(ctx, "TowerRoof", Vector3.new(34, 2, 34), CFrame.new(p.X, g + H - 7, p.Z), Kit.style("metal_dark"), o)
	local beacon =
		Kit.part(ctx, "Beacon", Vector3.new(2, 2, 2), CFrame.new(p.X, g + H - 3, p.Z), Kit.style("paint_red"), o)
	Kit.nightGlow(beacon, Color3.fromRGB(255, 40, 40))
end

local function dam(ctx: Ctx, l: Landmark)
	local F = l.cframe
	local m = model(ctx, l.id, F)
	local W, H, D = l.size.X, l.size.Y, l.size.Z
	local g = math.min(ground(F.Position.X, F.Position.Z), F.Position.Y - H * 0.5)
	local top = F.Position.Y + 6
	local hgt = top - g
	Kit.part(
		ctx,
		"DamWall",
		Vector3.new(W, hgt, D),
		CFrame.new(F.Position.X, g + hgt / 2, F.Position.Z) * F.Rotation,
		Kit.style("concrete"),
		{
			parent = m,
		}
	)
	Kit.part(
		ctx,
		"DamRoad",
		Vector3.new(W, 1, D * 0.5),
		CFrame.new(F.Position.X, top + 0.5, F.Position.Z) * F.Rotation,
		Kit.style("asphalt"),
		{
			parent = m,
			tag = "Road",
		}
	)
end

local function speedway(ctx: Ctx, l: Landmark)
	local F = l.cframe
	local m = model(ctx, l.id, F)
	local W, D = l.size.X, l.size.Z
	local o: Kit.PartOpts = { parent = m }
	-- grandstand along the north straight (a stepped wedge), press box on top
	local standF = F * CFrame.new(0, 0, -D / 2 - 30)
	Kit.wedge(
		ctx,
		"Grandstand",
		Vector3.new(W * 0.6, 34, 50),
		standF * CFrame.new(0, 17, 0) * CFrame.Angles(0, math.pi, 0),
		Kit.style("concrete"),
		o
	)
	Kit.part(ctx, "PressBox", Vector3.new(W * 0.3, 10, 12), standF * CFrame.new(0, 39, 20), Kit.style("glass"), o)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local pos = (F * CFrame.new(sx * W * 0.45, 0, sz * D * 0.45)).Position
			local g = ground(pos.X, pos.Z)
			Kit.post(ctx, "LightTower", Vector3.new(pos.X, g, pos.Z), 70, 2.5, Kit.style("metal_grey"), o)
			local head = Kit.part(
				ctx,
				"LightBank",
				Vector3.new(10, 6, 2),
				CFrame.new(pos.X, g + 72, pos.Z),
				Kit.style("metal_grey"),
				o
			)
			Kit.nightGlow(head, Color3.fromRGB(255, 250, 230))
		end
	end
end

local function quarry(ctx: Ctx, l: Landmark)
	local F = l.cframe
	local m = model(ctx, l.id, F)
	local p = (F * CFrame.new(l.size.X * 0.35, 0, 0)).Position
	local g = ground(p.X, p.Z)
	Kit.part(
		ctx,
		"Crusher",
		Vector3.new(30, 26, 24),
		CFrame.new(p.X, g + 13, p.Z) * F.Rotation,
		Kit.style("rust"),
		{ parent = m }
	)
	Kit.beam(
		ctx,
		"Conveyor",
		Vector3.new(p.X, g + 24, p.Z),
		Vector3.new(p.X, g + 4, p.Z) + F.LookVector * 70,
		4,
		2,
		Kit.style("metal_dark"),
		{
			parent = m,
		}
	)
end

local function cranes(ctx: Ctx, l: Landmark)
	local F = l.cframe
	local m = model(ctx, l.id, F)
	local W = l.size.X
	local H = l.size.Y
	local steel = Kit.style("steel_red")
	local o: Kit.PartOpts = { parent = m }
	for k = 1, 5 do
		local x = -W / 2 + (k - 0.5) * W / 5
		local C = F * CFrame.new(x, 0, 0)
		for _, lx in { -14, 14 } do
			for _, lz in { -26, 26 } do
				Kit.part(ctx, "CraneLeg", Vector3.new(2.5, H * 0.45, 2.5), C * CFrame.new(lx, H * 0.225, lz), steel, o)
			end
			Kit.part(ctx, "CraneSill", Vector3.new(2.5, 3, 56), C * CFrame.new(lx, H * 0.45, 0), steel, o)
		end
		-- boom out over the water (+Z is the sea side of the landmark frame) and back over the quay
		Kit.part(ctx, "CraneBoom", Vector3.new(32, 5, 190), C * CFrame.new(0, H * 0.45 + 4, 40), steel, o)
		Kit.part(
			ctx,
			"CraneHouse",
			Vector3.new(16, 10, 18),
			C * CFrame.new(0, H * 0.45 + 11, 0),
			Kit.style("steel_white"),
			o
		)
	end
end

local function ship(ctx: Ctx, l: Landmark)
	local F = l.cframe
	local m = model(ctx, l.id, F)
	local W, H, D = l.size.X, l.size.Y, l.size.Z
	local o: Kit.PartOpts = { parent = m }
	Kit.part(ctx, "Hull", Vector3.new(W, 26, D * 0.85), F * CFrame.new(0, 4, D * 0.075), Kit.style("steel_red"), o)
	Kit.wedge(
		ctx,
		"Bow",
		Vector3.new(W, 26, D * 0.15),
		F * CFrame.new(0, 4, -D * 0.425) * CFrame.Angles(0, 0, 0),
		Kit.style("steel_red"),
		o
	)
	Kit.part(
		ctx,
		"Deck",
		Vector3.new(W - 4, 1, D * 0.85),
		F * CFrame.new(0, 17.5, D * 0.075),
		Kit.style("metal_dark"),
		o
	)
	Kit.part(
		ctx,
		"Bridge",
		Vector3.new(W - 10, H - 40, 40),
		F * CFrame.new(0, 18 + (H - 40) / 2, D * 0.4),
		Kit.style("steel_white"),
		o
	)
	-- container rows
	for k = 0, 6 do
		local z = -D * 0.3 + k * D * 0.09
		local c = Kit.part(
			ctx,
			"ShipContainers",
			Vector3.new(W - 12, 8.6 * 3, 40),
			F * CFrame.new(0, 18 + 12.9, z),
			Kit.style("corrugated"),
			o
		)
		c.Color = ({ Color3.fromRGB(176, 72, 44), Color3.fromRGB(36, 92, 150), Color3.fromRGB(52, 122, 72) })[k % 3 + 1]
	end
end

local function park(ctx: Ctx, l: Landmark)
	local F = l.cframe
	local m = model(ctx, l.id, F)
	local W, D = l.size.X, l.size.Z
	local o: Kit.PartOpts = { parent = m }
	Kit.part(ctx, "Lawn", Vector3.new(W - 4, 2, D - 4), F * CFrame.new(0, -0.9, 0), Kit.style("grass"), o)
	if l.id == "EchoPark" then
		local lake = Kit.part(
			ctx,
			"LakeWater",
			Vector3.new(W * 0.5, 1, D * 0.45),
			F * CFrame.new(-W * 0.12, 0.25, 0),
			Kit.style("water"),
			{
				parent = m,
				collide = false,
				transparency = 0.15,
			}
		)
		lake.Color = Color3.fromRGB(44, 96, 104)
	else
		Kit.part(ctx, "Monument", Vector3.new(10, 40, 10), F * CFrame.new(0, 20.5, 0), Kit.style("terrazzo"), o)
		Kit.part(ctx, "MonumentBase", Vector3.new(30, 3, 30), F * CFrame.new(0, 1.5, 0), Kit.style("terrazzo"), o)
	end
end

local function marina(ctx: Ctx, cl: { kind: string, name: string, points: { Vector3 } })
	for i, p in cl.points do
		local y = 4
		local a = Vector3.new(p.X, y, p.Z)
		local b = a + Vector3.new(-400, 0, 0)
		Kit.beam(ctx, "Jetty", a, b, 10, 1.2, Kit.style("wood"))
		for k = 1, 5 do
			local bp = a + Vector3.new(-60 * k, -0.5, (if k % 2 == 0 then 1 else -1) * 14)
			local boat = Kit.part(ctx, "Boat", Vector3.new(7, 4, 22), CFrame.new(bp), Kit.style("steel_white"))
			boat.Color = Color3.fromRGB(230, 230, 226):Lerp(Color3.fromRGB(40, 80, 140), Kit.hash(i, k, 77))
		end
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- prop clusters
-------------------------------------------------------------------------------------------------------------------------

local function pumpjack(ctx: Ctx, p: Vector3, i: number)
	local yaw = Kit.hash(i, 9, 18) * math.pi * 2
	local F = CFrame.new(p) * CFrame.Angles(0, yaw, 0)
	Kit.part(ctx, "PumpBase", Vector3.new(4, 10, 14), F * CFrame.new(0, 5, 0), Kit.style("metal_dark"))
	Kit.part(
		ctx,
		"PumpBeam",
		Vector3.new(1.6, 1.6, 24),
		F * CFrame.new(0, 11, -2) * CFrame.Angles(math.rad(8), 0, 0),
		Kit.style("steel_orange")
	)
	Kit.part(ctx, "PumpHead", Vector3.new(2, 6, 3), F * CFrame.new(0, 10, -14), Kit.style("steel_orange"))
end

local function turbine(ctx: Ctx, p: Vector3, i: number)
	local H = 150
	Kit.post(ctx, "TurbineTower", p - Vector3.new(0, 2, 0), H + 2, 6, Kit.style("steel_white"))
	local yaw = math.rad(225)
	local hub = CFrame.new(p + Vector3.new(0, H, 0)) * CFrame.Angles(0, yaw, 0)
	Kit.part(ctx, "Nacelle", Vector3.new(6, 6, 16), hub * CFrame.new(0, 2, 4), Kit.style("steel_white"))
	local spin = Kit.hash(i, 3, 12) * math.pi * 2
	for k = 0, 2 do
		local a = spin + k * math.pi * 2 / 3
		Kit.part(
			ctx,
			"Blade",
			Vector3.new(3.2, 64, 0.8),
			hub * CFrame.new(0, 2, -4.5) * CFrame.Angles(0, 0, a) * CFrame.new(0, 32, 0),
			Kit.style("steel_white"),
			{ shadow = false }
		)
	end
end

local function pylonTower(ctx: Ctx, p: Vector3, nextP: Vector3?)
	local H = 90
	Kit.part(ctx, "Pylon", Vector3.new(6, H, 6), CFrame.new(p + Vector3.new(0, H / 2, 0)), Kit.style("metal_grey"))
	local dir = if nextP then Vector3.new(nextP.X - p.X, 0, nextP.Z - p.Z) else Vector3.new(1, 0, 0)
	dir = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.new(1, 0, 0)
	local arm = CFrame.lookAt(p + Vector3.new(0, H - 8, 0), p + Vector3.new(0, H - 8, 0) + dir)
	Kit.part(ctx, "PylonArm", Vector3.new(34, 2, 2), arm, Kit.style("metal_grey"))
	if nextP then
		for _, side in { -15, 15 } do
			local a = (arm * CFrame.new(side, -1, 0)).Position
			local b = (
				CFrame.lookAt(nextP + Vector3.new(0, H - 9, 0), nextP + Vector3.new(0, H - 9, 0) + dir)
				* CFrame.new(side, 0, 0)
			).Position
			Kit.rod(
				ctx,
				"PowerLine",
				a,
				b,
				0.3,
				Kit.style("paint_black"),
				{ collide = false, query = false, shadow = false }
			)
		end
	end
end

local function guardTower(ctx: Ctx, p: Vector3)
	Kit.part(ctx, "GuardTowerLeg", Vector3.new(5, 34, 5), CFrame.new(p + Vector3.new(0, 17, 0)), Kit.style("concrete"))
	local cab =
		Kit.part(ctx, "GuardCab", Vector3.new(12, 8, 12), CFrame.new(p + Vector3.new(0, 38, 0)), Kit.style("glass"))
	Kit.nightGlow(cab, Color3.fromRGB(255, 240, 200))
end

local function trailer(ctx: Ctx, p: Vector3, i: number)
	local yaw = (Kit.hash(i, 1, 14) - 0.5) * 0.4 + (if i % 2 == 0 then 0 else math.pi)
	local F = CFrame.new(p) * CFrame.Angles(0, yaw, 0)
	local t = Kit.part(ctx, "Trailer", Vector3.new(14, 10, 46), F * CFrame.new(0, 6, 0), Kit.style("stucco_white"))
	t.Color = Color3.fromRGB(226, 220, 204):Lerp(Color3.fromRGB(150, 190, 200), Kit.hash(i, 2, 14))
end

-------------------------------------------------------------------------------------------------------------------------

local BUILDERS: { [string]: (Ctx, Landmark) -> () } = {
	hill_sign = sunwood,
	lighthouse = lighthouse,
	tower = controlTower,
	dam = dam,
	race_track = speedway,
	quarry = quarry,
	cranes = cranes,
	ship = ship,
	park = park,
	observatory = function(ctx: Ctx, l: Landmark)
		local p = l.cframe.Position
		local g = ground(p.X, p.Z)
		local m = model(ctx, l.id, CFrame.new(p))
		Kit.post(
			ctx,
			"DomeDrum",
			Vector3.new(p.X, g, p.Z),
			26,
			l.size.X * 0.8,
			Kit.style("stucco_white"),
			{ parent = m }
		)
		local dome = Kit.part(
			ctx,
			"Dome",
			Vector3.new(l.size.X * 0.8, l.size.X * 0.8, l.size.X * 0.8),
			CFrame.new(p.X, g + 26, p.Z),
			Kit.style("metal_grey"),
			{
				parent = m,
				shape = Enum.PartType.Ball,
			}
		)
		dome.Color = Color3.fromRGB(176, 180, 186)
	end,
	breakwater = function(ctx: Ctx, l: Landmark)
		local F = l.cframe
		local m = model(ctx, l.id, F)
		Kit.part(
			ctx,
			"Breakwater",
			Vector3.new(l.size.X, 30, l.size.Z),
			F * CFrame.new(0, -11, 0),
			Kit.style("rock"),
			{ parent = m }
		)
	end,
}

function Landmarks.build(ctx: Ctx)
	for _, l in WorldLayout.Landmarks do
		local b = BUILDERS[l.kind]
		if b then
			b(ctx, l)
			Kit.tick(ctx)
		end
	end
	if not WorldLayout.hasServerData() then
		return
	end
	for _, cl in WorldLayout.PropClusters do
		local pts = cl.points
		for i, p in pts do
			if cl.kind == "pumpjack" then
				pumpjack(ctx, p, i)
			elseif cl.kind == "wind_turbine" then
				turbine(ctx, p, i)
			elseif cl.kind == "pylon" then
				pylonTower(ctx, p, pts[i + 1])
			elseif cl.kind == "guard_tower" then
				guardTower(ctx, p)
			elseif cl.kind == "trailer" then
				trailer(ctx, p, i)
			end
		end
		if cl.kind == "jetty" then
			marina(ctx, cl)
		end
		Kit.tick(ctx)
	end
end

return Landmarks
