--!strict
-- MapBuilder (v2): renders the island of Hotwire City from data (Config/WorldLayout) at boot. It decides no geometry
-- of its own: roads, junctions, decks, lots, POIs, plots and props all come from the baked world (docs/v2/world/
-- WORLD_SPEC.md, MIGRATION.md §4). Builders live in Systems/World:
--
--   Kit          part factory (explicit Look MaterialVariants), 512-stud streaming cells, counts, cooperative yields
--   Roads        ground roads + junction geometry, sidewalks, medians, crosswalks, stop bars, street bridges
--   Freeways     freeway / ramp decks, barriers with gore cuts, girders, piers, trench walls, sign gantries
--   Signals      mast-arm signals (one moving lens per head, server-driven from WorldQuery.signalState), stop signs
--   Streetscape  lamps (StreetLight / NightGlow), palms, trees, poles + wires, billboards, bus stops, hydrants, bins
--   Places       POIs (+ interaction parts), garage plot pads, open lots, paths, helipads, stunt ramps, rails
--   Bridges      cable-stayed / arch / truss / lift bridges, Palmera Pier + Ferris wheel
--   Landmarks    SUNWOOD sign, lighthouse, cranes, ship, wind farm, dam, speedway, ...
--   Terrain      runtime Terrain from Util/WorldTerrain in 64-stud chunks (graded to the roads, water, materials)
--   Skeleton     persistent invisible collision under every deck, bridge span and the channel floor
--   Streaming    RequestStreamAroundAsync ahead of fast drivers (when StreamingEnabled)
--
-- Boot: init() builds the folders (Map/{Cells, Skeleton, POIs, Plots, Landmarks, Buildings}), the collision skeleton,
-- every POI, the plot pads and
-- everything within NEAR_RADIUS of a plot or Hotwire Plaza, synchronously (systems later in ORDER find their parts);
-- start() builds the rest with task.wait yields, then the terrain chunk by chunk (spawn areas first), then starts
-- the signal and lift-bridge drivers, and sets Map attribute "Built" = true (Built signal). Map/Buildings stays
-- empty: BuildingService (A3) fills it from WorldLayout.Parcels.
--
-- build(parent, opts) does everything synchronously (tests, tools/blender/preview dumps).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local WorldLayout = require(Shared.Config.WorldLayout)
local Signal = require(Shared.Util.Signal)

local World = script.Parent:WaitForChild("World")
local Kit = require(World.Kit)
local Roads = require(World.Roads)
local Freeways = require(World.Freeways)
local Signals = require(World.Signals)
local Streetscape = require(World.Streetscape)
local Places = require(World.Places)
local Bridges = require(World.Bridges)
local Landmarks = require(World.Landmarks)
local TerrainBuilder = require(World.Terrain)
local Skeleton = require(World.Skeleton)
local Streaming = require(World.Streaming)

local MapBuilder = {}

MapBuilder.VERSION = 2
MapBuilder.PART_BUDGET = 42000 -- the world layer (roads, decks, props, POIs, landmarks); A3's buildings come on top
MapBuilder.NEAR_RADIUS = 900
MapBuilder.TAG_ROAD = "Road"
MapBuilder.TAG_STREET_LIGHT = "StreetLight"
MapBuilder.TAG_NIGHT_GLOW = "NightGlow"
MapBuilder.TAG_BILLBOARD = "Billboard"

MapBuilder.Built = Signal.new() -- (counts: { [string]: number }, parts: number)

export type BuildOpts = {
	terrain: boolean?, -- write the Terrain (default true; tests pass false)
	yield: (() -> ())?, -- cooperative yield between batches (boot); nil = synchronous
}

local mapFolder: Folder? = nil
local ctxRef: Kit.Ctx? = nil
local built = false

-- Spawn anchors: Hotwire Plaza (the fallback spawn) and the 8 garages.
local function anchors(): { Vector3 }
	local list: { Vector3 } = { WorldLayout.Spawns.default.Position }
	for _, p in WorldLayout.Plots do
		table.insert(list, p.cframe.Position)
	end
	return list
end

local function nearAnchor(p: Vector3, r: number): boolean
	for _, a in anchors() do
		local dx, dz = p.X - a.X, p.Z - a.Z
		if dx * dx + dz * dz <= r * r then
			return true
		end
	end
	return false
end

local function edgeMid(ei: number): Vector3
	local pts = WorldLayout.Edges[ei].points
	return pts[(#pts + 1) // 2]
end

local function newMap(parent: Instance): Folder
	local old = parent:FindFirstChild("Map")
	if old then
		old:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = "Map"
	f:SetAttribute("WorldVersion", WorldLayout.VERSION)
	f:SetAttribute("WorldHash", WorldLayout.HASH)
	f:SetAttribute("Built", false)
	f.Parent = parent
	return f
end

-- Skeleton + POIs + plots + everything near the spawn anchors (synchronous).
local function buildNear(ctx: Kit.Ctx, geos: { [number]: Roads.JunctionGeo }, trims: { [number]: Roads.EdgeTrim })
	for _, name in { "POIs", "Plots", "Landmarks", "Buildings" } do
		Kit.folder(ctx, name)
	end
	Skeleton.build(ctx)
	Places.buildPlots(ctx)
	Places.buildPOIs(ctx)
	local R = MapBuilder.NEAR_RADIUS
	local function edgeNear(id: number): boolean
		if id < 0 then
			local g = geos[-id]
			return g ~= nil and nearAnchor(g.center, R)
		end
		return nearAnchor(edgeMid(id), R)
	end
	Roads.build(ctx, geos, trims, edgeNear)
	Freeways.build(ctx, function(ei: number): boolean
		return nearAnchor(edgeMid(ei), R)
	end)
	Signals.build(ctx, geos, function(id: number): boolean
		return nearAnchor(geos[id].center, R)
	end)
	if WorldLayout.hasServerData() then
		Streetscape.build(ctx, function(p: WorldLayout.Place): boolean
			return nearAnchor(p.pos, R)
		end)
	end
end

-- The rest of the world (the complement of buildNear's filters).
local function buildFar(ctx: Kit.Ctx, geos: { [number]: Roads.JunctionGeo }, trims: { [number]: Roads.EdgeTrim })
	local R = MapBuilder.NEAR_RADIUS
	Roads.build(ctx, geos, trims, function(id: number): boolean
		if id < 0 then
			local g = geos[-id]
			return g ~= nil and not nearAnchor(g.center, R)
		end
		return not nearAnchor(edgeMid(id), R)
	end)
	Freeways.build(ctx, function(ei: number): boolean
		return not nearAnchor(edgeMid(ei), R)
	end)
	Freeways.buildCuts(ctx)
	Freeways.buildGantries(ctx)
	Signals.build(ctx, geos, function(id: number): boolean
		return not nearAnchor(geos[id].center, R)
	end)
	if WorldLayout.hasServerData() then
		Streetscape.build(ctx, function(p: WorldLayout.Place): boolean
			return not nearAnchor(p.pos, R)
		end)
	end
	Places.buildOpenParcels(ctx)
	Places.buildPaths(ctx)
	Places.buildHelipads(ctx)
	Places.buildStuntJumps(ctx)
	Places.buildLevelCrossings(ctx)
	Places.buildRails(ctx)
	Bridges.build(ctx)
	Landmarks.build(ctx)
end

local function finish(ctx: Kit.Ctx, f: Folder)
	f:SetAttribute("Parts", ctx.parts)
	f:SetAttribute("Built", true)
	built = true
	MapBuilder.Built:Fire(ctx.counts, ctx.parts)
end

-- Synchronous full build under parent (tests, tools). Returns the Map folder.
function MapBuilder.build(parent: Instance, opts: BuildOpts?): Folder
	local f = newMap(parent)
	mapFolder = f
	Signals.reset()
	local ctx = Kit.new(f, if opts then opts.yield else nil)
	ctxRef = ctx
	local geos, trims = Roads.junctions()
	buildNear(ctx, geos, trims)
	buildFar(ctx, geos, trims)
	if not opts or opts.terrain ~= false then
		local terrain = Workspace:FindFirstChildOfClass("Terrain")
		if terrain then
			pcall(function()
				terrain:Clear()
			end)
			TerrainBuilder.build(terrain, WorldLayout.Spawns.default.Position, if opts then opts.yield else nil)
		end
	end
	finish(ctx, f)
	return f
end

-- One Clouds instance under Terrain (LightingService adopts it and drives cover / density by time of day).
function MapBuilder.ensureClouds(terrain: Terrain): Clouds
	local clouds = terrain:FindFirstChildOfClass("Clouds") or Instance.new("Clouds")
	clouds.Cover = 0.45
	clouds.Density = 0.6
	clouds.Color = Color3.fromRGB(252, 252, 255)
	clouds.Parent = terrain
	return clouds :: Clouds
end

-- The island's Terrain (synchronous; World/Terrain) + the Clouds. Returns the chunk count.
function MapBuilder.buildTerrain(terrain: Terrain, yieldFn: (() -> ())?): number
	MapBuilder.ensureClouds(terrain)
	return TerrainBuilder.build(terrain, WorldLayout.Spawns.default.Position, yieldFn)
end

function MapBuilder.getMapFolder(): Folder
	local f = mapFolder
	if f and f.Parent then
		return f
	end
	local existing = Workspace:FindFirstChild("Map")
	if existing and existing:IsA("Folder") then
		mapFolder = existing
		return existing
	end
	local nf = newMap(Workspace)
	mapFolder = nf
	return nf
end

-- Part counts by category (after a build).
function MapBuilder.counts(): ({ [string]: number }, number)
	local ctx = ctxRef
	if not ctx then
		return {}, 0
	end
	return ctx.counts, ctx.parts
end

function MapBuilder.isBuilt(): boolean
	return built
end

local pendingGeo: { geos: { [number]: Roads.JunctionGeo }, trims: { [number]: Roads.EdgeTrim } }? = nil

function MapBuilder.init()
	local f = newMap(Workspace)
	mapFolder = f
	Signals.reset()
	local ctx = Kit.new(f, nil)
	ctxRef = ctx
	local geos, trims = Roads.junctions()
	local ok, err = pcall(buildNear, ctx, geos, trims)
	if not ok then
		warn("[MapBuilder] near build failed: " .. tostring(err))
	end
	pendingGeo = { geos = geos, trims = trims }
end

function MapBuilder.start()
	local f = mapFolder
	local ctx = ctxRef
	local pg = pendingGeo
	if not (f and ctx and pg) then
		return
	end
	pendingGeo = nil
	ctx.yield = function()
		task.wait()
	end
	local t0 = os.clock()
	local ok, err = pcall(buildFar, ctx, pg.geos, pg.trims)
	if not ok then
		warn("[MapBuilder] build failed: " .. tostring(err))
	end
	Signals.start()
	Bridges.start()
	Streaming.start()
	local partsTime = os.clock() - t0
	local terrain = Workspace:FindFirstChildOfClass("Terrain")
	local chunks = 0
	local t1 = os.clock()
	if terrain then
		MapBuilder.ensureClouds(terrain)
		local okT, errT = pcall(function()
			-- spawn areas first: the plaza, then each garage's surroundings come with the radial order
			chunks = TerrainBuilder.build(terrain, WorldLayout.Spawns.default.Position, function()
				task.wait()
			end, 0.010)
		end)
		if not okT then
			warn("[MapBuilder] terrain failed: " .. tostring(errT))
		end
	end
	finish(ctx, f)
	print(
		("[MapBuilder] v2 world: %d parts (budget %d), %.1f s parts, %d terrain chunks in %.1f s"):format(
			ctx.parts,
			MapBuilder.PART_BUDGET,
			partsTime,
			chunks,
			os.clock() - t1
		)
	)
end

return MapBuilder
