--!nocheck
-- Export Config/WorldLayout (v2 world data) to JSON for tools/world/render_plan.py and other offline tooling.
--
--   lune run tools/world/export_layout.luau [out.json] [heightmapStep]
--
-- Runs the real module headlessly through tests/harness (Roblox datatypes from @lune/roblox), so the plan image is
-- always drawn from exactly the data the game uses. Default output: build/world_layout.json, heightmap step 32.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../../tests/harness")

local out = process.args[1] or "build/world_layout.json"
local step = tonumber(process.args[2]) or 32

local t0 = os.clock()
local W = Harness.require("src/shared/Config/WorldLayout")
local buildTime = os.clock() - t0

local function r1(v)
	return math.floor(v * 10 + 0.5) / 10
end

local function v3(v)
	return { r1(v.X), r1(v.Y), r1(v.Z) }
end

local function yawOf(cf)
	local look = cf.LookVector
	return math.deg(math.atan2(look.X, -look.Z)) -- 0 = facing north (-Z), 90 = east
end

local function frame(cf, size)
	return {
		pos = v3(cf.Position),
		yaw = r1(yawOf(cf)),
		look = { r1(cf.LookVector.X * 1000) / 1000, r1(cf.LookVector.Z * 1000) / 1000 },
		right = { r1(cf.RightVector.X * 1000) / 1000, r1(cf.RightVector.Z * 1000) / 1000 },
		size = size and v3(size) or nil,
	}
end

local data = {
	meta = {
		version = W.VERSION,
		buildSeconds = buildTime,
		bounds = { min = v3(W.Bounds.min), max = v3(W.Bounds.max) },
		sea = W.SEA_LEVEL,
		grade = W.GRADE,
		scale = W.Scale,
		stats = W.Stats,
		routeErrors = W.RouteErrors,
	},
	coast = {},
	islands = {},
	water = {},
	channel = { points = {}, floorHalfWidth = W.Channel.floorHalfWidth, wallRun = W.Channel.wallRun },
	heightmap = {},
	districts = {},
	edges = {},
	intersections = {},
	parcels = {},
	pois = {},
	plots = {},
	landmarks = {},
	hotDrops = {},
	stuntJumps = {},
	helipads = {},
	restricted = {},
	safeZones = {},
	routes = {},
	rails = {},
	paths = {},
	policeSpawns = {},
	parkingSample = {},
	terrainZones = W.TerrainZones,
}

for _, p in W.Coast do
	table.insert(data.coast, { p.x, p.z, p.kind })
end
for _, isl in W.Islands do
	local pts = {}
	for _, p in isl.points do
		table.insert(pts, { p.x, p.z, p.kind })
	end
	table.insert(data.islands, { name = isl.name, points = pts })
end
for _, w in W.Water do
	local pts = {}
	for _, p in w.points do
		table.insert(pts, { p.x, p.z })
	end
	table.insert(data.water, { name = w.name, level = w.level, points = pts })
end
for _, p in W.Channel.points do
	table.insert(data.channel.points, { p.x, p.z })
end

-- heightmap (terrain surface), row-major from min Z (north) to max Z
do
	local minX, minZ = W.Bounds.min.X, W.Bounds.min.Z
	local maxX, maxZ = W.Bounds.max.X, W.Bounds.max.Z
	local nx = math.floor((maxX - minX) / step) + 1
	local nz = math.floor((maxZ - minZ) / step) + 1
	local rows = {}
	for j = 0, nz - 1 do
		local row = table.create(nx)
		local z = minZ + j * step
		for i = 0, nx - 1 do
			row[i + 1] = r1(W.heightAt(minX + i * step, z))
		end
		rows[j + 1] = row
	end
	data.heightmap = { minX = minX, minZ = minZ, step = step, nx = nx, nz = nz, rows = rows }
end

for _, d in W.Districts do
	local pts = {}
	for _, p in d.polygon do
		table.insert(pts, { p.X, p.Z })
	end
	table.insert(data.districts, {
		id = d.id,
		name = d.name,
		style = d.style,
		polygon = pts,
		priority = d.priority,
		height = d.height,
		density = d.density,
		heat = d.heat,
		carTier = d.carTier,
		color = d.color,
	})
end

for _, e in W.Edges do
	local pts = {}
	for _, p in e.points do
		table.insert(pts, v3(p))
	end
	table.insert(data.edges, {
		id = e.id,
		a = e.a,
		b = e.b,
		name = e.name,
		class = e.class,
		points = pts,
		length = r1(e.length),
		width = e.width,
		sidewalk = e.sidewalk,
		median = e.median,
		parking = e.parking,
		lanesF = e.lanesF,
		lanesB = e.lanesB,
		oneWay = e.oneWay,
		layer = e.layer,
		elevated = e.elevated,
		bridge = e.bridge,
		corridor = e.corridor,
		district = e.district,
		traffic = e.traffic,
	})
end

for _, i in W.Intersections do
	table.insert(data.intersections, { id = i.id, pos = v3(i.pos), control = i.control, radius = r1(i.radius), degree = #i.approaches })
end

for _, p in W.Parcels do
	local f = frame(p.cframe, p.size)
	f.use = p.use
	f.district = p.district
	f.floors = p.floors
	table.insert(data.parcels, f)
end

for _, p in W.POIs do
	local f = frame(p.cframe, p.size)
	f.id = p.id
	f.name = p.name
	f.kind = p.kind
	f.district = p.district
	f.entrance = v3(p.entrance)
	f.tags = p.tags
	table.insert(data.pois, f)
end

for _, p in W.Plots do
	local f = frame(p.cframe, p.size)
	f.index = p.index
	f.name = p.name
	f.district = p.district
	f.door = v3(p.door)
	f.curbSpot = frame(p.curbSpot)
	f.nearestOnRamp = r1(p.nearestOnRamp)
	table.insert(data.plots, f)
end

local function zones(list, into)
	for _, z in list do
		local f = frame(z.cframe, z.size)
		f.id = z.id
		f.name = z.name
		f.kind = z.kind
		f.district = z.district
		f.note = z.note
		table.insert(into, f)
	end
end
zones(W.Landmarks, data.landmarks)
zones(W.HotDrops, data.hotDrops)
zones(W.Helipads, data.helipads)
zones(W.RestrictedZones, data.restricted)
zones(W.SafeZones, data.safeZones)

for _, j in W.StuntJumps do
	local f = frame(j.cframe, j.size)
	f.id = j.id
	f.name = j.name
	f.landing = v3(j.landing)
	f.minSpeed = j.minSpeed
	table.insert(data.stuntJumps, f)
end

for _, r in W.Routes do
	local pts = {}
	for _, p in r.path do
		table.insert(pts, { r1(p.X), r1(p.Z) })
	end
	local stops = {}
	for _, p in r.stops do
		table.insert(stops, v3(p))
	end
	table.insert(data.routes, { id = r.id, name = r.name, kind = r.kind, length = r1(r.length), laps = r.laps, path = pts, stops = stops })
end

for _, r in W.Rails do
	local pts = {}
	for _, p in r.points do
		table.insert(pts, { r1(p.X), r1(p.Z) })
	end
	table.insert(data.rails, { name = r.name, tracks = r.tracks, points = pts })
end
for _, r in W.Paths do
	local pts = {}
	for _, p in r.points do
		table.insert(pts, { r1(p.X), r1(p.Z) })
	end
	table.insert(data.paths, { name = r.name, kind = r.kind, width = r.width, points = pts })
end
for _, s in W.Spawns.police do
	table.insert(data.policeSpawns, { pos = v3(s.cframe.Position), station = s.station })
end
for i, s in W.Spawns.parking do
	if i % 3 == 0 then
		table.insert(data.parkingSample, { pos = v3(s.cframe.Position), look = { r1(s.cframe.LookVector.X * 100) / 100, r1(s.cframe.LookVector.Z * 100) / 100 } })
	end
end

local dir = out:match("^(.*)/[^/]+$")
if dir and not fs.isDir(dir) then
	fs.writeDir(dir)
end
fs.writeFile(out, serde.encode("json", data, false))
print(("wrote %s  (build %.2fs, %d edges, %d parcels, %d pois)"):format(out, buildTime, #data.edges, #data.parcels, #data.pois))
if #W.RouteErrors > 0 then
	for _, e in W.RouteErrors do
		print("route error: " .. e)
	end
end
