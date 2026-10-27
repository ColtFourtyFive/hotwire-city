--!nocheck
-- Export the v2 world's top-down geometry for tools/minimap/render_map.py.
--
--   lune run tools/minimap/export.luau <out.json> [step=32]
--
-- Everything comes from the baked world (Config/WorldLayout through the test harness), so the map image always
-- matches what MapBuilder builds and what the GPS routes on:
--   roads      every edge polyline (x, z), width, class, layer, elevated / sunken, bridge spans
--   parcels    lot footprints (4 corners), use, height, district, tower flag
--   pois       POI footprints, kind, id;  plots: garage footprints + door
--   landmarks  footprints of the structural landmarks;  paths, rails
--   districts  polygons, ids, names, colours
--   terrain    a height grid (every `step` studs) from Util/WorldTerrain + the water level per sample (sea / reservoir)
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local H = require("../../tests/harness")
H.setMode("server")

local out = process.args[1] or "build/minimap/geometry.json"
local STEP = tonumber(process.args[2] or "32")

local W = H.require("src/shared/Config/WorldLayout")
local WT = H.require("src/shared/Util/WorldTerrain")

local function r1(v)
	return math.floor(v * 10 + 0.5) / 10
end

local function corners(cf, sx, sz)
	local pts = {}
	for _, c in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local p = cf * H.roblox.Vector3.new(sx / 2 * c[1], 0, sz / 2 * c[2])
		table.insert(pts, { r1(p.X), r1(p.Z) })
	end
	return pts
end

local roads = {}
for ei, e in W.Edges do
	local pts = {}
	for _, p in e.points do
		table.insert(pts, { r1(p.X), r1(p.Z), r1(p.Y) })
	end
	table.insert(roads, {
		id = ei,
		pts = pts,
		width = e.width,
		sidewalk = e.sidewalk,
		class = e.class,
		layer = e.layer,
		elevated = e.elevated,
		sunken = e.sunken,
		oneWay = e.oneWay,
		median = e.median,
		spans = e.spans,
		name = e.name,
	})
end

local parcels = {}
for _, p in W.Parcels do
	table.insert(parcels, {
		c = corners(p.cframe, p.size.X, p.size.Z),
		use = p.use,
		h = p.size.Y,
		district = p.district,
		tower = p.tower or false,
	})
end

local pois = {}
for _, p in W.POIs do
	table.insert(pois, {
		id = p.id,
		kind = p.kind,
		c = corners(p.cframe, p.size.X, p.size.Z),
		h = p.size.Y,
		center = { r1(p.cframe.Position.X), r1(p.cframe.Position.Z) },
	})
end

local plots = {}
for _, p in W.Plots do
	table.insert(plots, {
		index = p.index,
		c = corners(p.cframe, p.size.X, p.size.Z),
		door = { r1(p.door.X), r1(p.door.Z) },
	})
end

local landmarks = {}
for _, l in W.Landmarks do
	table.insert(landmarks, { id = l.id, kind = l.kind, c = corners(l.cframe, l.size.X, l.size.Z) })
end

local paths = {}
for _, p in W.Paths do
	local pts = {}
	for _, q in p.points do
		table.insert(pts, { r1(q.X), r1(q.Z) })
	end
	table.insert(paths, { kind = p.kind, width = p.width, pts = pts })
end
local rails = {}
for _, r in W.Rails do
	local pts = {}
	for _, q in r.points do
		table.insert(pts, { r1(q.X), r1(q.Z) })
	end
	table.insert(rails, { tracks = r.tracks, spacing = r.spacing or 0, pts = pts })
end

local districts = {}
for _, d in W.Districts do
	local poly = {}
	for _, p in d.polygon do
		table.insert(poly, { r1(p.X), r1(p.Z) })
	end
	table.insert(districts, { id = d.id, name = d.name, color = d.color, poly = poly })
end

-- terrain grid
local B = W.Bounds
local x0, z0 = math.floor(B.min.X / STEP) * STEP, math.floor(B.min.Z / STEP) * STEP
local nx = math.floor((B.max.X - x0) / STEP) + 1
local nz = math.floor((B.max.Z - z0) / STEP) + 1
local heights, water = table.create(nx * nz), table.create(nx * nz)
local t0 = os.clock()
for j = 0, nz - 1 do
	local z = z0 + j * STEP
	for i = 0, nx - 1 do
		local x = x0 + i * STEP
		local h, wl
		if not WT.landAtLeast(x, z, -1150) then
			h, wl = -58, 0
		else
			h = WT.heightAt(x, z)
			wl = -9999
			if h < 0 and not WT.landAtLeast(x, z, 0) then
				wl = 0
			end
			local wet, level = WT.inWater(x, z)
			if wet and h < level then
				wl = level
			end
		end
		heights[j * nx + i + 1] = r1(h)
		water[j * nx + i + 1] = wl
	end
end

fs.writeDir(out:match("^(.*)/[^/]+$") or ".")
fs.writeFile(
	out,
	serde.encode("json", {
		version = W.VERSION,
		hash = W.HASH,
		bounds = { B.min.X, B.min.Z, B.max.X, B.max.Z },
		play = { B.playMinX, B.playMinZ, B.playMaxX, B.playMaxZ },
		roads = roads,
		parcels = parcels,
		pois = pois,
		plots = plots,
		landmarks = landmarks,
		paths = paths,
		rails = rails,
		districts = districts,
		terrain = { x0 = x0, z0 = z0, step = STEP, nx = nx, nz = nz, h = heights, water = water },
	})
)
print(
	("minimap export: %d roads, %d parcels, %d pois, terrain %dx%d (%.1f s) -> %s"):format(
		#roads,
		#parcels,
		#pois,
		nx,
		nz,
		os.clock() - t0,
		out
	)
)
