--!nocheck
-- Export the city's top-down geometry for tools/minimap/render_map.py.
--
--   lune run tools/minimap/export.luau <out.json>
--
-- Everything comes from the real builders (headless, via tests/harness), so the map image always matches the game:
--   roads     RoadGraph edges of the current layout (MapLayout.roadSegments() or the Config/Map grid): a, b, width,
--             class (highway / avenue / street / alley), level
--   parts     every BasePart MapBuilder.build() makes outside asset slots: name, material, color, top/bottom Y and the
--             8 box corners projected to XZ (the renderer takes the convex hull) or a ball center + radius;
--             Lot parts carry their Zone / Poi / PlotIndex attributes
--   slots     dressed asset slots (Buildings: kit footprint boxes, Props: role + position) - the same boxes the
--             AssetLibrary meshes are fitted into
--   garages   the 8 player garage footprints (Config/Map.Garage in plot space)
--   terrain   MapBuilder.buildTerrain FillBlock ops (park grass, seabed sand, water)
--   pois      Config/Map.Blocks centers
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Harness = require("../../tests/harness")

local out = process.args[1] or "build/minimap_geometry.json"

local MapBuilder = Harness.require("src/server/Systems/MapBuilder")
local MapLayout = Harness.require("src/shared/Util/MapLayout")
local MapConfig = Harness.require("src/shared/Config/Map")
local RoadGraph = Harness.require("src/shared/Util/RoadGraph")
local Vector3 = Harness.roblox.Vector3

local function r2(v)
	return math.floor(v * 100 + 0.5) / 100
end

local function corners(cf, size)
	local pts = {}
	for _, sx in { -0.5, 0.5 } do
		for _, sy in { -0.5, 0.5 } do
			for _, sz in { -0.5, 0.5 } do
				local p = cf * Vector3.new(size.X * sx, size.Y * sy, size.Z * sz)
				table.insert(pts, { r2(p.X), r2(p.Z) })
			end
		end
	end
	return pts
end

local function yRange(cf, size)
	local lo, hi = math.huge, -math.huge
	for _, sx in { -0.5, 0.5 } do
		for _, sy in { -0.5, 0.5 } do
			for _, sz in { -0.5, 0.5 } do
				local y = (cf * Vector3.new(size.X * sx, size.Y * sy, size.Z * sz)).Y
				lo = math.min(lo, y)
				hi = math.max(hi, y)
			end
		end
	end
	return r2(lo), r2(hi)
end

local folder = MapBuilder.build(Harness.workspace)
table.clear(Harness.terrainOps)
MapBuilder.buildTerrain(Harness.workspace:FindFirstChildOfClass("Terrain"))

-- slots -----------------------------------------------------------------------------------------------------------
local inSlot = {}
local slots = {}
for _, m in MapBuilder.slots(folder) do
	local boxes = {}
	for _, b in MapBuilder.slotBoxes(m) do
		local lo, hi = yRange(b.cframe, b.size)
		table.insert(boxes, { hull = corners(b.cframe, b.size), bottom = lo, top = hi })
	end
	local pivot = m:GetPivot().Position
	table.insert(slots, {
		category = m:GetAttribute("Category"),
		role = m:GetAttribute("Role"),
		fit = m:GetAttribute("Fit"),
		pos = { r2(pivot.X), r2(pivot.Z) },
		boxes = boxes,
	})
	for _, d in m:GetDescendants() do
		inSlot[d] = true
	end
end

-- parts -----------------------------------------------------------------------------------------------------------
local parts = {}
for _, d in folder:GetDescendants() do
	if d:IsA("BasePart") and not inSlot[d] and d.Transparency < 0.95 then
		local cf, size = d.CFrame, d.Size
		local entry = {
			name = d.Name,
			material = d.Material.Name,
			color = {
				math.floor(d.Color.R * 255 + 0.5),
				math.floor(d.Color.G * 255 + 0.5),
				math.floor(d.Color.B * 255 + 0.5),
			},
			shape = if d:IsA("Part") then d.Shape.Name else d.ClassName,
		}
		local lo, hi = yRange(cf, size)
		entry.bottom, entry.top = lo, hi
		if d:IsA("Part") and d.Shape.Name == "Ball" then
			entry.center = { r2(cf.Position.X), r2(cf.Position.Z) }
			entry.centerY = r2(cf.Position.Y)
			entry.radius = r2(math.min(size.X, size.Y, size.Z) / 2)
		else
			entry.hull = corners(cf, size)
		end
		if d.Name == "Lot" then
			entry.zone = d:GetAttribute("Zone")
			entry.poi = d:GetAttribute("Poi")
			entry.plot = d:GetAttribute("PlotIndex")
			entry.block = { d:GetAttribute("BlockX"), d:GetAttribute("BlockZ") }
		end
		table.insert(parts, entry)
	end
end

-- garages ---------------------------------------------------------------------------------------------------------
local G = MapConfig.Garage
local garages = {}
for i = 1, MapLayout.plotCount() do
	local depth = G.BACK_Z - G.FRONT_Z
	local cf = MapLayout.plotToWorld(i, Vector3.new(0, G.WALL_HEIGHT / 2, (G.BACK_Z + G.FRONT_Z) / 2))
	local size = Vector3.new(G.HALF_WIDTH * 2, G.WALL_HEIGHT, depth)
	local door = MapLayout.plotToWorld(i, Vector3.new(0, 0, G.FRONT_Z)).Position
	table.insert(garages, { index = i, hull = corners(cf, size), door = { r2(door.X), r2(door.Z) } })
end

-- roads -----------------------------------------------------------------------------------------------------------
local graph = RoadGraph.build()
local roads = {}
for _, e in graph.edges do
	local a, b = graph.nodes[e.a], graph.nodes[e.b]
	table.insert(roads, {
		a = { r2(a.X), r2(a.Z) },
		b = { r2(b.X), r2(b.Z) },
		width = e.width,
		class = e.class,
		level = e.level,
		oneWay = e.oneWay,
	})
end
local nodes = {}
for i, p in graph.nodes do
	table.insert(nodes, { r2(p.X), r2(p.Z), #graph.adj[i] })
end

-- terrain ---------------------------------------------------------------------------------------------------------
local terrain = {}
for _, op in Harness.terrainOps do
	if op[1] == "FillBlock" then
		local lo, hi = yRange(op[2], op[3])
		table.insert(terrain, { material = op[4].Name, hull = corners(op[2], op[3]), bottom = lo, top = hi })
	end
end

-- POIs ------------------------------------------------------------------------------------------------------------
local pois = {}
for name in MapConfig.Blocks do
	local c = MapLayout.poiCenter(name)
	pois[name] = { r2(c.X), r2(c.Z) }
end

local data = {
	config = {
		gridSpacing = MapConfig.GRID_SPACING,
		roadWidth = MapConfig.ROAD_WIDTH,
		halfExtent = MapConfig.HALF_EXTENT,
		sandExtent = MapConfig.SAND_EXTENT,
		boundary = MapConfig.BOUNDARY,
		roadY = MapConfig.ROAD_Y,
		curbTop = MapLayout.CURB_TOP,
		waterLevel = MapConfig.WATER_LEVEL,
	},
	roads = roads,
	nodes = nodes,
	parts = parts,
	slots = slots,
	garages = garages,
	terrain = terrain,
	pois = pois,
}
fs.writeFile(out, serde.encode("json", data))
print(("minimap export: %d roads, %d parts, %d slots, %d garages -> %s"):format(#roads, #parts, #slots, #garages, out))
