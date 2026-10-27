--!nocheck
-- Headless dump of the v2 world for the Blender preview renderer (tools/blender/preview/render.py).
--
--   lune run tools/blender/preview/dump.luau [outDir=build/preview] [--no-terrain]
--
-- Builds the world exactly as the server does (MapBuilder.build in the Lune harness, Terrain computed by
-- World/Terrain.chunk but not voxelised) and writes:
--   world.json      parts (category, shape, size, CFrame, colour, material + variant, transparency, textures with
--                   local image files, SpecialMesh), stand-ins for what other systems build (A3's parcel buildings as
--                   massing boxes, PlotService's garages), views (camera presets computed on real roads), counts
--   terrain.bin     float32 heights + uint8 material ids + float32 water levels on an 8-stud grid over the bounds
--   terrain.json    the grid header and the material id table
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local H = require("../../../tests/harness")
H.setMode("server")
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

local args = process.args
local outDir = "build/preview"
local withTerrain = true
for _, a in args do
	if a == "--no-terrain" then
		withTerrain = false
	elseif a:sub(1, 2) ~= "--" then
		outDir = a
	end
end
fs.writeDir(outDir)

local MapBuilder = H.require("src/server/Systems/MapBuilder")
local WorldLayout = H.require("src/shared/Config/WorldLayout")
local WorldQuery = H.require("src/shared/Util/WorldQuery")
local Look = H.require("src/shared/Config/Look")
local Markings = H.require("src/server/Systems/World/Markings")
local Terrain = H.require("src/server/Systems/World/Terrain")
local MapConfig = H.require("src/shared/Config/Map")

local t0 = os.clock()
local folder = MapBuilder.build(H.workspace, { terrain = false })
local counts, total = MapBuilder.counts()
print(("built %d parts in %.1f s"):format(total, os.clock() - t0))

-- image id -> local file
local images = {}
for name, d in Look.Decals do
	images[d.image] = "assets/materials/decals/" .. name .. ".png"
end
for key, id in Markings.Images do
	images[id] = "assets/world/markings/" .. key .. ".png"
end

local function r3(v)
	return math.floor(v * 1000 + 0.5) / 1000
end

local parts = {}
for _, p in folder:GetDescendants() do
	if not p:IsA("BasePart") then
		continue
	end
	local shape = "Block"
	if p:IsA("WedgePart") then
		shape = "Wedge"
	elseif p:IsA("Part") then
		shape = p.Shape.Name
	end
	local mesh = p:FindFirstChildOfClass("SpecialMesh")
	if mesh and mesh.MeshType.Name == "Sphere" then
		shape = "Sphere"
	end
	local c = { p.CFrame:GetComponents() }
	for i = 1, 12 do
		c[i] = r3(c[i])
	end
	local tex = nil
	for _, t in p:GetChildren() do
		if t:IsA("Texture") then
			tex = tex or {}
			table.insert(tex, {
				file = images[t.Texture],
				face = t.Face.Name,
				su = t.StudsPerTileU,
				sv = t.StudsPerTileV,
				ou = t.OffsetStudsU,
				ov = t.OffsetStudsV,
			})
		elseif t:IsA("Decal") then
			tex = tex or {}
			table.insert(tex, { file = images[t.Texture], face = t.Face.Name, decal = true })
		end
	end
	local glow = p:GetAttribute("NightColor") ~= nil
	table.insert(parts, {
		n = p.Name,
		s = shape,
		z = { r3(p.Size.X), r3(p.Size.Y), r3(p.Size.Z) },
		c = c,
		k = { math.floor(p.Color.R * 255 + 0.5), math.floor(p.Color.G * 255 + 0.5), math.floor(p.Color.B * 255 + 0.5) },
		m = p.Material.Name,
		v = if p.MaterialVariant ~= "" then p.MaterialVariant else nil,
		t = if p.Transparency > 0 then r3(p.Transparency) else nil,
		x = tex,
		g = if glow then true else nil,
	})
end

-- stand-ins for what other systems build (rendered as such, labelled in the evidence)
local standins = {}
local USE_MAT = {
	office_tower = "glass",
	residential_tower = "glass",
	hotel = "glass",
	office_midrise = "concrete",
	apartment = "stucco",
	loft = "brick",
	beach_hotel = "stucco",
	motel = "stucco",
	house = "stucco",
	duplex = "stucco",
	mansion = "stucco",
	villa = "stucco",
	farmhouse = "wood",
	warehouse = "corrugated",
	factory = "corrugated",
	shed = "corrugated",
	hangar = "corrugated",
	barn = "wood",
	parking_garage = "concrete",
}
local OPEN = { park = true, plaza = true, parking_lot = true, yard = true, container_yard = true }
for _, pc in WorldLayout.Parcels do
	if not OPEN[pc.use] and pc.size.Y > 0 then
		local c = { pc.cframe:GetComponents() }
		for i = 1, 12 do
			c[i] = r3(c[i])
		end
		table.insert(standins, {
			kind = "building",
			use = pc.use,
			mat = USE_MAT[pc.use] or "stucco",
			c = c,
			z = { r3(pc.size.X * 0.92), r3(pc.size.Y), r3(pc.size.Z * 0.9) },
			tower = pc.tower or nil,
			podium = pc.podium,
			seed = pc.seed,
			district = pc.district,
		})
	end
end
local G = MapConfig.Garage
for _, plot in WorldLayout.Plots do
	local cf = plot.cframe * CFrame.new(0, G.WALL_HEIGHT / 2, (G.FRONT_Z + G.BACK_Z) / 2)
	local c = { cf:GetComponents() }
	table.insert(standins, {
		kind = "garage",
		c = c,
		z = { G.HALF_WIDTH * 2 + 4, G.WALL_HEIGHT, G.BACK_Z - G.FRONT_Z + 4 },
		door = { G.DOOR_WIDTH, G.DOOR_HEIGHT },
	})
end

-- camera presets on real geometry ---------------------------------------------------------------------------------
local views = {}
local function view(name, pos, target, fov, note)
	views[name] = { pos = { pos.X, pos.Y, pos.Z }, target = { target.X, target.Y, target.Z }, fov = fov, note = note }
end
-- 1 overview: from the south-south-west over the bay, looking at downtown with the hills behind
view("overview", Vector3.new(-1900, 2300, 6200), Vector3.new(200, 0, -900), 46, "the island from the south")
-- 2 downtown street level: on the boulevard nearest Pinnacle Tower, 400 studs out, looking at the tower
do
	local pin = WorldQuery.poi("PinnacleTower").cframe.Position
	local best, bestD = nil, math.huge
	for ei, e in WorldLayout.Edges do
		if (e.class == "boulevard" or e.class == "avenue") and e.layer == 0 and not e.elevated then
			local p = e.points[(#e.points + 1) // 2]
			local d = (Vector3.new(p.X, 0, p.Z) - Vector3.new(pin.X, 0, pin.Z)).Magnitude
			if d > 380 and d < bestD then
				best, bestD = ei, d
			end
		end
	end
	local e = WorldLayout.Edges[best]
	local p = e.points[(#e.points + 1) // 2]
	local cf = WorldQuery.laneCFrame(best, 1, 1, WorldLayout.Edges[best].length / 2)
	local pos = cf.Position + Vector3.new(0, 6, 0)
	view("downtown_street", pos, Vector3.new(pin.X, pos.Y + 120, pin.Z), 62, "street level on " .. e.name)
end
-- 3 freeway interchange: the node with the most ramp / freeway edges at deck level, seen from 420 up
do
	local best, bestN = nil, -1
	for _, n in WorldLayout.Nodes do
		local k = 0
		for _, ei in n.edges do
			local e = WorldLayout.Edges[ei]
			if e.class == "ramp" or e.class == "freeway" then
				k += 1
			end
		end
		-- prefer the stack interchanges (many ramps within 400 studs)
		if k >= 3 then
			local near = 0
			for _, m in WorldLayout.Nodes do
				if (m.pos - n.pos).Magnitude < 450 then
					for _, ei in m.edges do
						if WorldLayout.Edges[ei].class == "ramp" then
							near += 1
						end
					end
				end
			end
			if near > bestN then
				best, bestN = n, near
			end
		end
	end
	local c = best.pos
	view("freeway_interchange", c + Vector3.new(-520, 380, 640), c, 55, "stack interchange (" .. bestN .. " ramp ends within 450)")
end
-- 4 Palmera beach: from the sand looking out along the pier
do
	local pierEdge = nil
	for ei, e in WorldLayout.Edges do
		if e.class == "pier" and e.length > 200 then
			pierEdge = ei
		end
	end
	local e = WorldLayout.Edges[pierEdge]
	local a, b = e.points[1], e.points[#e.points]
	local dir = (b - a).Unit
	local side = Vector3.new(-dir.Z, 0, dir.X)
	local pos = a - dir * 140 + side * 260 + Vector3.new(0, 26, 0)
	view("palmera_beach", pos, a + dir * 700 + Vector3.new(0, 30, 0), 60, "Palmera Beach and the pier")
end
-- 5 a garage plot: Palmera Garage from across the street
do
	local plot = WorldLayout.Plots[1]
	local cf = plot.cframe
	local front = cf * Vector3.new(0, 0, -plot.size.Z / 2)
	local pos = front + cf.LookVector * 110 + cf.RightVector * 70 + Vector3.new(0, 42, 0)
	view("garage_plot", pos, cf.Position + Vector3.new(0, 8, 0), 58, plot.name)
end
-- 6 hillside sign: from the hills road below the ridge, looking up at SUNWOOD
do
	local sign = WorldQuery.landmark("SunwoodSign")
	local cf = sign.cframe
	local pos = cf.Position + cf.LookVector * 1400 + Vector3.new(-200, -40, 0)
	pos = Vector3.new(pos.X, math.max(WorldLayout.heightAt(pos.X, pos.Z) + 60, pos.Y), pos.Z)
	view("hillside_sign", pos, cf.Position + Vector3.new(0, 70, 0), 40, "the SUNWOOD sign on the summit ridge")
end

local out = {
	version = WorldLayout.VERSION,
	hash = WorldLayout.HASH,
	counts = counts,
	total = total,
	parts = parts,
	standins = standins,
	views = views,
	seaLevel = WorldLayout.SEA_LEVEL,
	bounds = { WorldLayout.Bounds.min.X, WorldLayout.Bounds.min.Z, WorldLayout.Bounds.max.X, WorldLayout.Bounds.max.Z },
}
fs.writeFile(outDir .. "/world.json", serde.encode("json", out))
print(("wrote %s/world.json: %d parts, %d stand-ins"):format(outDir, #parts, #standins))

-- terrain on an 8-stud grid ------------------------------------------------------------------------------------------
if withTerrain then
	local t1 = os.clock()
	local B = WorldLayout.Bounds
	local STEP = 8
	local C = Terrain.CHUNK
	local x0 = math.floor(B.min.X / C) * C
	local z0 = math.floor(B.min.Z / C) * C
	local x1 = math.floor(B.max.X / C) * C
	local z1 = math.floor(B.max.Z / C) * C
	local nx, nz = (x1 - x0) // STEP, (z1 - z0) // STEP
	local hb = buffer.create(nx * nz * 4)
	local wb = buffer.create(nx * nz * 4)
	local mb = buffer.create(nx * nz)
	local matIds, matNames = {}, {}
	local per = C // STEP -- grid cells per chunk side
	local sub = STEP // Terrain.RES -- columns per grid cell
	local N = C // Terrain.RES
	for cx = x0 // C, x1 // C - 1 do
		for cz = z0 // C, z1 // C - 1 do
			local ch = Terrain.chunk(cx, cz)
			for gx = 0, per - 1 do
				for gz = 0, per - 1 do
					local ix, iz = gx * sub, gz * sub
					local i = ix * N + iz + 1
					local h = ch.h[i]
					local w = ch.water[i]
					local mname = ch.mat[i].Name
					local id = matIds[mname]
					if not id then
						table.insert(matNames, mname)
						id = #matNames
						matIds[mname] = id
					end
					local X = (cx * C - x0) // STEP + gx
					local Z = (cz * C - z0) // STEP + gz
					local k = Z * nx + X
					buffer.writef32(hb, k * 4, h)
					buffer.writef32(wb, k * 4, if w == -math.huge then -9999 else w)
					buffer.writeu8(mb, k, id)
				end
			end
		end
	end
	local all = buffer.create(nx * nz * 9)
	buffer.copy(all, 0, hb)
	buffer.copy(all, nx * nz * 4, wb)
	buffer.copy(all, nx * nz * 8, mb)
	fs.writeFile(outDir .. "/terrain.bin", all)
	fs.writeFile(
		outDir .. "/terrain.json",
		serde.encode("json", {
			x0 = x0,
			z0 = z0,
			step = STEP,
			nx = nx,
			nz = nz,
			materials = matNames,
			colors = Look.TerrainColors,
			stats = Terrain.stats,
		})
	)
	print(("wrote terrain %dx%d in %.1f s"):format(nx, nz, os.clock() - t1))
end
