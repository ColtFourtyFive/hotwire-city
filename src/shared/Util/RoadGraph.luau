--!strict
-- RoadGraph (shared, pure): the drivable road network as a graph + A* GPS routing.
--
--   nodes  intersections, bends and dead ends (every place two road segments cross or touch, plus segment ends)
--   edges  straight road pieces between two nodes, carrying width / class / lanes / one-way / level
--
-- Source of truth: the v2 world graph (RoadGraph.fromWorld: Config/WorldLayout Nodes / Edges) when MapLayout is the v2
-- shim; else MapLayout.roadSegments() when the layout provides it (a list of RoadSegment), else the square grid
-- derived from Config/Map (RoadGraph.gridSegments). A bigger network (curves as polylines, highways, one-way
-- streets, T-junctions, bridges on another `level`) only needs MapLayout.roadSegments() to describe it: segments are
-- split wherever they cross or touch, so the layout never has to pre-split anything.
--
-- No instances, no services: the same answers on the server (police / traffic routing) and the client (GPS).
-- Deterministic (ties break on the lower index) and fast: spatial hashing for lookups, a binary-heap A* with
-- generation-stamped scratch arrays, so a route on the v1 grid takes well under a millisecond.
--
-- v2 world graphs (fromWorld) route on the junction network instead (~700 nodes, not the ~4,400 polyline vertices) and
-- by travel time (road class speed + the expected wait at each junction, WorldQuery.route's cost), so the GPS line
-- takes the freeway. The search runs backward from the goal as an A* aimed at the start (straight-line distance at
-- the fastest road speed: admissible and consistent) and is kept per goal (RoadGraph.TREE_CACHE goals): a re-route to
-- the same objective re-aims the open frontier at the new start and continues, so it settles only what it has not
-- settled before. Budget: < 4 ms per cold route (VIBE_ROUTING #22; roadgraph.spec measures it).
--
-- API
--   RoadGraph.build(segments?) -> Graph        fresh graph (from the layout when segments is nil)
--   RoadGraph.get() -> Graph                   cached graph of the current layout
--   RoadGraph.nearestNode(pos) -> (index?, Vector3?)
--   RoadGraph.nearestPoint(pos) -> (Vector3?, edgeIndex?, t?, distance?)   closest point on any road centerline
--   RoadGraph.route(fromPos, toPos) -> { Vector3 }?   polyline along road centerlines (first point = fromPos snapped
--                                                     onto the network, last = toPos snapped); nil if unreachable
--   RoadGraph.routeLength(points) -> number
--   RoadGraph.projectToPolyline(points, pos) -> (distance, segment, t, point)
--   graph:nearestNode / graph:nearestPoint / graph:route  (same, on a specific graph)

local MapConfig = require(script.Parent.Parent.Config.Map)
local MapLayout = require(script.Parent.MapLayout)

local RoadGraph = {}

export type RoadClass = "highway" | "avenue" | "street" | "alley"

export type RoadSegment = {
	a: Vector3,
	b: Vector3,
	width: number,
	class: RoadClass?,
	oneWay: boolean?, -- true: traffic may only travel a -> b
	lanes: number?, -- lanes per direction (default 1)
	level: number?, -- bridges / overpasses: only segments on the same level connect (default 0)
	name: string?,
}

export type Edge = {
	a: number,
	b: number,
	length: number,
	width: number,
	class: RoadClass,
	oneWay: boolean,
	lanes: number,
	level: number,
	name: string?,
}

type GraphData = {
	nodes: { Vector3 },
	nodeLevel: { number },
	edges: { Edge },
	-- node -> arcs leaving it. Arc k > 0 = edge k travelled a -> b; arc k < 0 = edge -k travelled b -> a.
	adj: { { number } },
	minX: number,
	minZ: number,
	maxX: number,
	maxZ: number,
	-- spatial hashes (cell key -> indices)
	edgeCells: { [number]: { number } },
	nodeCells: { [number]: { number } },
	-- per-query scratch (generation stamped: never cleared, never reallocated)
	edgeStamp: { number },
	nodeStamp: { number },
	stamp: number,
	g: { number },
	parentArc: { number },
	openGen: { number },
	closedGen: { number },
	goalCost: { number },
	goalGen: { number },
	gen: number,
	heapNode: { number },
	heapF: { number },
	-- v2 world graphs only (RoadGraph.fromWorld): the junction-level network the GPS routes on
	net: WorldNet?,
}

-- The v2 junction network (one node per WorldLayout node, one arc per drivable direction of a WorldLayout edge) and
-- the per-goal search cache. Arc costs are seconds (length / AI speed + the expected wait at the junction you arrive
-- at), the same cost WorldQuery.route uses, so the GPS takes the freeway the way GTA's does.
type WorldNet = {
	W: any,
	n: number,
	x: { number },
	z: { number },
	inFrom: { { number } }, -- node v -> the nodes u with an arc u -> v
	inCost: { { number } },
	inEdge: { { number } }, -- signed world edge of that arc (+ei: a -> b, -ei: b -> a)
	k: { number }, -- seconds per stud on world edge ei
	delayA: { number }, -- seconds lost arriving at edge ei's a / b end
	delayB: { number },
	hScale: number, -- 1 / the fastest speed (admissible, consistent heuristic)
	fineEdge: { number }, -- fine edge -> world edge
	fineS0: { number }, -- arc length along the world edge at the fine edge's a end
	cum: { [number]: { number } }, -- lazily: cumulative arc length per world edge polyline vertex
	trees: { [string]: Tree },
	treeOrder: { string },
}

-- One goal's backward A* (from the goal toward the asking start, resumable): settled nodes carry their exact cost to
-- the goal and the arc to take; the open frontier is kept, so the next route to the same goal (a re-route after the
-- player left the line) continues from it instead of starting over.
type Tree = {
	edge: number,
	s: number,
	g: { number }, -- seconds to the goal (exact once settled; an upper bound while open)
	succ: { number }, -- signed world edge to take from the node toward the goal; 0 = finish along the goal edge
	state: { number }, -- 0 unseen, 1 open, 2 settled
	heapNode: { number },
	heapF: { number },
	size: number,
	hx: number, -- the heuristic's target (the current start)
	hz: number,
}

local Graph = {}
Graph.__index = Graph

export type Graph = typeof(setmetatable({} :: GraphData, Graph))

RoadGraph.CELL = 64 -- spatial hash cell (studs)
RoadGraph.SNAP = 1 -- points closer than this (studs) are the same node
local BROAD_CELL = 128 -- broadphase cell for splitting segments
local KEY_SPAN = 2 ^ 21
local EPS = 1e-9

-- Point at param t along a -> b, computed in double precision and snapped to 1/1024 stud so grid intersections land
-- exactly on their integer coordinates (Vector3 is single precision: a:Lerp(b, t) drifts by ~1e-4).
local Q = 1024
local function lerpExact(a: Vector3, b: Vector3, t: number): Vector3
	if t <= 0 then
		return a
	elseif t >= 1 then
		return b
	end
	return Vector3.new(
		math.round((a.X + (b.X - a.X) * t) * Q) / Q,
		math.round((a.Y + (b.Y - a.Y) * t) * Q) / Q,
		math.round((a.Z + (b.Z - a.Z) * t) * Q) / Q
	)
end

local function cellKey(cx: number, cz: number): number
	return (cx + KEY_SPAN) * (KEY_SPAN * 2) + (cz + KEY_SPAN)
end

local function cross2(ax: number, az: number, bx: number, bz: number): number
	return ax * bz - az * bx
end

-------------------------------------------------------------------------------------------------------------------------
-- Layout -> segments
-------------------------------------------------------------------------------------------------------------------------

-- Road class of grid line `line` (shared by the GPS, the map renderer and anything that wants a road hierarchy):
-- the outermost lines are the ring highway, line 0 and the Midtown boundary lines are avenues, the rest streets.
function RoadGraph.gridClass(line: number): RoadClass
	if line == MapConfig.LINE_MIN or line == MapConfig.LINE_MAX then
		return "highway"
	end
	local avenue = MapConfig.DOWNTOWN_RADIUS + 1
	if line == 0 or line == avenue or line == -avenue then
		return "avenue"
	end
	return "street"
end

-- The current city: a full square grid of two-way roads (one lane each way) between the ring road's corners.
function RoadGraph.gridSegments(): { RoadSegment }
	local S = MapConfig.GRID_SPACING
	local lo, hi = MapConfig.LINE_MIN * S, MapConfig.LINE_MAX * S
	local y = MapConfig.ROAD_Y
	local out: { RoadSegment } = {}
	for line = MapConfig.LINE_MIN, MapConfig.LINE_MAX do
		local c = line * S
		local class = RoadGraph.gridClass(line)
		table.insert(out, {
			a = Vector3.new(lo, y, c),
			b = Vector3.new(hi, y, c),
			width = MapConfig.ROAD_WIDTH,
			class = class,
			lanes = 1,
			name = "X" .. line,
		})
		table.insert(out, {
			a = Vector3.new(c, y, lo),
			b = Vector3.new(c, y, hi),
			width = MapConfig.ROAD_WIDTH,
			class = class,
			lanes = 1,
			name = "Z" .. line,
		})
	end
	return out
end

-- Segments of the current layout: MapLayout.roadSegments() when it exists, else the grid.
function RoadGraph.layoutSegments(): { RoadSegment }
	local provider = (MapLayout :: any).roadSegments
	if typeof(provider) == "function" then
		local ok, segs = pcall(provider)
		if ok and typeof(segs) == "table" and #segs > 0 then
			return segs :: { RoadSegment }
		end
	end
	return RoadGraph.gridSegments()
end

-------------------------------------------------------------------------------------------------------------------------
-- Building
-------------------------------------------------------------------------------------------------------------------------

-- Split params (0..1) where segment j crosses / touches segment i (and vice versa).
local function intersect(si: RoadSegment, sj: RoadSegment, splitsI: { number }, splitsJ: { number }, snap: number)
	local px, pz = si.a.X, si.a.Z
	local rx, rz = si.b.X - px, si.b.Z - pz
	local qx, qz = sj.a.X, sj.a.Z
	local sx, sz = sj.b.X - qx, sj.b.Z - qz
	local lenI = math.sqrt(rx * rx + rz * rz)
	local lenJ = math.sqrt(sx * sx + sz * sz)
	if lenI < EPS or lenJ < EPS then
		return
	end
	local denom = cross2(rx, rz, sx, sz)
	local qpx, qpz = qx - px, qz - pz
	if math.abs(denom) < EPS * lenI * lenJ then
		-- parallel: if collinear, each segment splits at the other's endpoints that fall inside it
		if math.abs(cross2(qpx, qpz, rx, rz)) / lenI > snap then
			return
		end
		local function addInside(
			splits: { number },
			ax: number,
			az: number,
			dx: number,
			dz: number,
			len2: number,
			x: number,
			z: number
		)
			local t = ((x - ax) * dx + (z - az) * dz) / len2
			local tol = snap / math.sqrt(len2)
			if t > -tol and t < 1 + tol then
				table.insert(splits, math.clamp(t, 0, 1))
			end
		end
		local li2, lj2 = lenI * lenI, lenJ * lenJ
		addInside(splitsI, px, pz, rx, rz, li2, qx, qz)
		addInside(splitsI, px, pz, rx, rz, li2, qx + sx, qz + sz)
		addInside(splitsJ, qx, qz, sx, sz, lj2, px, pz)
		addInside(splitsJ, qx, qz, sx, sz, lj2, px + rx, pz + rz)
		return
	end
	local t = cross2(qpx, qpz, sx, sz) / denom
	local u = cross2(qpx, qpz, rx, rz) / denom
	local tolI, tolJ = snap / lenI, snap / lenJ
	if t >= -tolI and t <= 1 + tolI and u >= -tolJ and u <= 1 + tolJ then
		table.insert(splitsI, math.clamp(t, 0, 1))
		table.insert(splitsJ, math.clamp(u, 0, 1))
	end
end

local function cellsOfBox(minX: number, minZ: number, maxX: number, maxZ: number, cell: number, fn: (number) -> ())
	for cx = math.floor(minX / cell), math.floor(maxX / cell) do
		for cz = math.floor(minZ / cell), math.floor(maxZ / cell) do
			fn(cellKey(cx, cz))
		end
	end
end

local function insertCell(cells: { [number]: { number } }, key: number, index: number)
	local list = cells[key]
	if list then
		table.insert(list, index)
	else
		cells[key] = { index }
	end
end

function RoadGraph.build(segments: { RoadSegment }?): Graph
	local segs = segments or RoadGraph.layoutSegments()
	local snap = RoadGraph.SNAP
	local n = #segs

	-- 1. split params: ends + every crossing / touching point (broadphase grid of segment boxes)
	local splits: { { number } } = table.create(n)
	local broad: { [number]: { number } } = {}
	for i, s in segs do
		splits[i] = { 0, 1 }
		cellsOfBox(
			math.min(s.a.X, s.b.X) - snap,
			math.min(s.a.Z, s.b.Z) - snap,
			math.max(s.a.X, s.b.X) + snap,
			math.max(s.a.Z, s.b.Z) + snap,
			BROAD_CELL,
			function(key)
				insertCell(broad, key, i)
			end
		)
	end
	local checked: { [number]: boolean } = {}
	local keys: { number } = {}
	for key in broad do
		table.insert(keys, key)
	end
	table.sort(keys) -- deterministic order
	for _, key in keys do
		local list = broad[key]
		for x = 1, #list do
			local i = list[x]
			for y = x + 1, #list do
				local j = list[y]
				local lo, hi = math.min(i, j), math.max(i, j)
				local pair = lo * (n + 1) + hi
				if not checked[pair] then
					checked[pair] = true
					local si, sj = segs[lo], segs[hi]
					if (si.level or 0) == (sj.level or 0) then
						intersect(si, sj, splits[lo], splits[hi], snap)
					end
				end
			end
		end
	end

	-- 2. nodes (deduplicated within SNAP via a 1-stud key grid, neighbors checked) + edges between consecutive splits
	local nodes: { Vector3 } = {}
	local nodeLevel: { number } = {}
	local nodeKeys: { [string]: number } = {}
	local function nodeAt(p: Vector3, level: number): number
		local kx, kz = math.round(p.X / snap), math.round(p.Z / snap)
		for dx = -1, 1 do
			for dz = -1, 1 do
				local idx = nodeKeys[(kx + dx) .. "," .. (kz + dz) .. "," .. level]
				if idx and (nodes[idx] - p).Magnitude <= snap then
					return idx
				end
			end
		end
		table.insert(nodes, p)
		table.insert(nodeLevel, level)
		local idx = #nodes
		nodeKeys[kx .. "," .. kz .. "," .. level] = idx
		return idx
	end

	local edges: { Edge } = {}
	local edgeKeys: { [string]: boolean } = {}
	for i, s in segs do
		local params = splits[i]
		table.sort(params)
		local level = s.level or 0
		local len = (s.b - s.a).Magnitude
		local prevNode: number? = nil
		local prevT = -math.huge
		for _, t in params do
			if prevNode == nil or (t - prevT) * len > snap * 0.5 then
				local node = nodeAt(lerpExact(s.a, s.b, t), level)
				if prevNode and node ~= prevNode then
					local a, b = prevNode, node
					local key = math.min(a, b) .. ":" .. math.max(a, b)
					if not edgeKeys[key] then
						edgeKeys[key] = true
						table.insert(edges, {
							a = a,
							b = b,
							length = (nodes[b] - nodes[a]).Magnitude,
							width = s.width,
							class = s.class or "street",
							oneWay = s.oneWay == true,
							lanes = s.lanes or 1,
							level = level,
							name = s.name,
						})
					end
				end
				prevNode = node
				prevT = t
			end
		end
	end

	return RoadGraph._finalize(nodes, nodeLevel, edges)
end

-- Adjacency, spatial hashes and query scratch for a node / edge list.
function RoadGraph._finalize(nodes: { Vector3 }, nodeLevel: { number }, edges: { Edge }): Graph
	-- 3. adjacency + spatial hashes
	local adj: { { number } } = table.create(#nodes)
	for i = 1, #nodes do
		adj[i] = {}
	end
	local cell = RoadGraph.CELL
	local edgeCells: { [number]: { number } } = {}
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	for e, edge in edges do
		table.insert(adj[edge.a], e)
		if not edge.oneWay then
			table.insert(adj[edge.b], -e)
		end
		local pa, pb = nodes[edge.a], nodes[edge.b]
		local pad = edge.width / 2
		local x0, x1 = math.min(pa.X, pb.X) - pad, math.max(pa.X, pb.X) + pad
		local z0, z1 = math.min(pa.Z, pb.Z) - pad, math.max(pa.Z, pb.Z) + pad
		minX, minZ, maxX, maxZ = math.min(minX, x0), math.min(minZ, z0), math.max(maxX, x1), math.max(maxZ, z1)
		cellsOfBox(x0, z0, x1, z1, cell, function(key)
			insertCell(edgeCells, key, e)
		end)
	end
	local nodeCells: { [number]: { number } } = {}
	for i, p in nodes do
		insertCell(nodeCells, cellKey(math.floor(p.X / cell), math.floor(p.Z / cell)), i)
	end
	if #edges == 0 then
		minX, minZ, maxX, maxZ = 0, 0, 0, 0
	end

	local nNodes = #nodes
	local data: GraphData = {
		nodes = nodes,
		nodeLevel = nodeLevel,
		edges = edges,
		adj = adj,
		minX = minX,
		minZ = minZ,
		maxX = maxX,
		maxZ = maxZ,
		edgeCells = edgeCells,
		nodeCells = nodeCells,
		edgeStamp = table.create(#edges, 0),
		nodeStamp = table.create(nNodes, 0),
		stamp = 0,
		g = table.create(nNodes, 0),
		parentArc = table.create(nNodes, 0),
		openGen = table.create(nNodes, 0),
		closedGen = table.create(nNodes, 0),
		goalCost = table.create(nNodes, 0),
		goalGen = table.create(nNodes, 0),
		gen = 0,
		heapNode = {},
		heapF = {},
	}
	return setmetatable(data, Graph)
end

-- v2 road class -> GPS / minimap class (docs/v2/world/MIGRATION.md §3).
RoadGraph.WORLD_CLASS = {
	freeway = "highway",
	ramp = "highway",
	highway = "highway",
	boulevard = "avenue",
	avenue = "avenue",
	street = "street",
	rural = "street",
	pier = "street",
	runway = "street",
	alley = "alley",
	dirt = "alley",
	service = "alley",
	channel = "alley",
} :: { [string]: RoadClass }

-- The v2 world's explicit road graph (Config/WorldLayout Nodes / Edges): every polyline vertex is a node, every
-- polyline segment an edge, so ramps join levels exactly where the data says and crossings on different levels
-- never connect. Same queries / A* as the grid graph.
function RoadGraph.fromWorld(world: any?): Graph
	local W = world or require(script.Parent.Parent.Config.WorldLayout) :: any
	local nodes: { Vector3 } = {}
	local nodeLevel: { number } = {}
	local edges: { Edge } = {}
	local fineEdge: { number } = {}
	local fineS0: { number } = {}
	for i, n in W.Nodes do
		nodes[i] = n.pos
		nodeLevel[i] = 0
	end
	for ei, e in W.Edges do
		local pts = e.points
		local class = RoadGraph.WORLD_CLASS[e.class] or "street"
		local lanes = math.max(e.lanesF, e.lanesB, 1)
		local prev = e.a
		local s = 0
		nodeLevel[e.a] = math.max(nodeLevel[e.a], e.layer)
		nodeLevel[e.b] = math.max(nodeLevel[e.b], e.layer)
		for k = 2, #pts do
			local cur: number
			if k == #pts then
				cur = e.b
			else
				table.insert(nodes, pts[k])
				table.insert(nodeLevel, e.layer)
				cur = #nodes
			end
			local len = (nodes[cur] - nodes[prev]).Magnitude
			if len > 1e-3 then
				table.insert(edges, {
					a = prev,
					b = cur,
					length = len,
					width = e.width,
					class = class,
					oneWay = e.oneWay,
					lanes = lanes,
					level = e.layer,
					name = e.name,
				})
				fineEdge[#edges] = ei
				fineS0[#edges] = s
			end
			s += len
			prev = cur
		end
	end
	local g = RoadGraph._finalize(nodes, nodeLevel, edges)
	g.net = RoadGraph._worldNet(W, fineEdge, fineS0)
	return g
end

-- Seconds lost arriving at `node` along world edge ei (signals always; stop / all-way / yield on the stop approaches).
local function arrivalDelay(W: any, ei: number, node: number): number
	local id = W.Nodes[node].intersection
	if id == nil then
		return 0
	end
	local it = W.Intersections[id]
	local delays = W.JunctionDelay or {}
	if it.control == "signal" then
		return delays.signal or 0
	elseif it.control == "merge" or it.control == "none" then
		return 0
	end
	for _, k in it.stopApproaches do
		if it.approaches[k].edge == ei then
			return delays[it.control] or 0
		end
	end
	return 0
end

-- The junction network of a v2 world (see WorldNet).
function RoadGraph._worldNet(W: any, fineEdge: { number }, fineS0: { number }): WorldNet
	local n = #W.Nodes
	local x, z = table.create(n, 0), table.create(n, 0)
	local inFrom, inCost, inEdge = table.create(n), table.create(n), table.create(n)
	for i, node in W.Nodes do
		x[i], z[i] = node.pos.X, node.pos.Z
		inFrom[i], inCost[i], inEdge[i] = {}, {}, {}
	end
	local k, delayA, delayB = {}, {}, {}
	local fastest = 5
	for ei, e in W.Edges do
		local speed = math.max(e.speed or 40, 5)
		fastest = math.max(fastest, speed)
		k[ei] = 1 / speed
		delayA[ei] = arrivalDelay(W, ei, e.a)
		delayB[ei] = arrivalDelay(W, ei, e.b)
		-- forward arc a -> b (stored on b's incoming list for the backward search)
		table.insert(inFrom[e.b], e.a)
		table.insert(inCost[e.b], e.length * k[ei] + delayB[ei])
		table.insert(inEdge[e.b], ei)
		if not e.oneWay then
			table.insert(inFrom[e.a], e.b)
			table.insert(inCost[e.a], e.length * k[ei] + delayA[ei])
			table.insert(inEdge[e.a], -ei)
		end
	end
	return {
		W = W,
		n = n,
		x = x,
		z = z,
		inFrom = inFrom,
		inCost = inCost,
		inEdge = inEdge,
		k = k,
		delayA = delayA,
		delayB = delayB,
		hScale = 1 / fastest,
		fineEdge = fineEdge,
		fineS0 = fineS0,
		cum = {},
		trees = {},
		treeOrder = {},
	}
end

-------------------------------------------------------------------------------------------------------------------------
-- Queries
-------------------------------------------------------------------------------------------------------------------------

-- Closest point on edge e to pos: (t, point, distance).
local function projectEdge(self: Graph, e: number, pos: Vector3): (number, Vector3, number)
	local edge = self.edges[e]
	local a, b = self.nodes[edge.a], self.nodes[edge.b]
	local dx, dz = b.X - a.X, b.Z - a.Z
	local len2 = dx * dx + dz * dz
	local t = if len2 > EPS then math.clamp(((pos.X - a.X) * dx + (pos.Z - a.Z) * dz) / len2, 0, 1) else 0
	local p = lerpExact(a, b, t)
	return t, p, (p - pos).Magnitude
end

-- Max ring count before falling back to a full scan (covers the whole graph's box).
local function maxRings(self: Graph, pos: Vector3): number
	local cell = RoadGraph.CELL
	local span = math.max(
		math.abs(pos.X - self.minX),
		math.abs(pos.X - self.maxX),
		math.abs(pos.Z - self.minZ),
		math.abs(pos.Z - self.maxZ)
	)
	return math.ceil(span / cell) + 1
end

-- Closest point on any road centerline: (point, edgeIndex, t, distance). nil on an empty graph.
function Graph.nearestPoint(self: Graph, pos: Vector3): (Vector3?, number?, number?, number?)
	local edges = self.edges
	if #edges == 0 then
		return nil, nil, nil, nil
	end
	self.stamp += 1
	local stamp = self.stamp
	local seen = self.edgeStamp
	local cell = RoadGraph.CELL
	local cx, cz = math.floor(pos.X / cell), math.floor(pos.Z / cell)
	local bestE, bestT, bestP, bestD = 0, 0, pos, math.huge
	local rings = maxRings(self, pos)
	local function visit(key: number)
		local list = self.edgeCells[key]
		if not list then
			return
		end
		for _, e in list do
			if seen[e] ~= stamp then
				seen[e] = stamp
				local t, p, d = projectEdge(self, e, pos)
				if d < bestD - 1e-7 or (math.abs(d - bestD) <= 1e-7 and e < bestE) then
					bestE, bestT, bestP, bestD = e, t, p, d
				end
			end
		end
	end
	for r = 0, rings do
		if bestD <= (r - 1) * cell then
			break
		end
		if r == 0 then
			visit(cellKey(cx, cz))
		else
			for i = -r, r do
				visit(cellKey(cx + i, cz - r))
				visit(cellKey(cx + i, cz + r))
			end
			for i = -r + 1, r - 1 do
				visit(cellKey(cx - r, cz + i))
				visit(cellKey(cx + r, cz + i))
			end
		end
	end
	if bestE == 0 then
		-- far outside every cell: plain scan
		for e = 1, #edges do
			local t, p, d = projectEdge(self, e, pos)
			if d < bestD - 1e-7 then
				bestE, bestT, bestP, bestD = e, t, p, d
			end
		end
	end
	return bestP, bestE, bestT, bestD
end

-- Nearest graph node: (index, position). nil on an empty graph.
function Graph.nearestNode(self: Graph, pos: Vector3): (number?, Vector3?)
	local nodes = self.nodes
	if #nodes == 0 then
		return nil, nil
	end
	local cell = RoadGraph.CELL
	local cx, cz = math.floor(pos.X / cell), math.floor(pos.Z / cell)
	local best, bestD = 0, math.huge
	local function visit(key: number)
		local list = self.nodeCells[key]
		if not list then
			return
		end
		for _, i in list do
			local d = (nodes[i] - pos).Magnitude
			if d < bestD - 1e-7 or (math.abs(d - bestD) <= 1e-7 and i < best) then
				best, bestD = i, d
			end
		end
	end
	for r = 0, maxRings(self, pos) do
		if bestD <= (r - 1) * cell then
			break
		end
		if r == 0 then
			visit(cellKey(cx, cz))
		else
			for i = -r, r do
				visit(cellKey(cx + i, cz - r))
				visit(cellKey(cx + i, cz + r))
			end
			for i = -r + 1, r - 1 do
				visit(cellKey(cx - r, cz + i))
				visit(cellKey(cx + r, cz + i))
			end
		end
	end
	if best == 0 then
		for i, p in nodes do
			local d = (p - pos).Magnitude
			if d < bestD then
				best, bestD = i, d
			end
		end
	end
	return best, nodes[best]
end

-- Binary heap on (f, node): smallest f first, ties on the lower node index (determinism).
local function heapLess(fa: number, na: number, fb: number, nb: number): boolean
	return fa < fb or (fa == fb and na < nb)
end

local function heapPush(hn: { number }, hf: { number }, size: number, node: number, f: number): number
	size += 1
	local i = size
	while i > 1 do
		local p = i // 2
		if heapLess(f, node, hf[p], hn[p]) then
			hn[i], hf[i] = hn[p], hf[p]
			i = p
		else
			break
		end
	end
	hn[i], hf[i] = node, f
	return size
end

local function heapPop(hn: { number }, hf: { number }, size: number): (number, number, number)
	local topNode, topF = hn[1], hf[1]
	local lastNode, lastF = hn[size], hf[size]
	size -= 1
	local i = 1
	while true do
		local l = i * 2
		if l > size then
			break
		end
		local c = l
		local r = l + 1
		if r <= size and heapLess(hf[r], hn[r], hf[l], hn[l]) then
			c = r
		end
		if heapLess(hf[c], hn[c], lastF, lastNode) then
			hn[i], hf[i] = hn[c], hf[c]
			i = c
		else
			break
		end
	end
	if size > 0 then
		hn[i], hf[i] = lastNode, lastF
	end
	return topNode, topF, size
end

-- Drop near-duplicate points and middle points of straight runs (in place).
local function simplify(points: { Vector3 }): { Vector3 }
	local out: { Vector3 } = {}
	for _, p in points do
		local n = #out
		if n == 0 or (p - out[n]).Magnitude > 0.05 then
			if n >= 2 then
				local a, b = out[n - 1], out[n]
				local abx, abz = b.X - a.X, b.Z - a.Z
				local bpx, bpz = p.X - b.X, p.Z - b.Z
				local lab = math.sqrt(abx * abx + abz * abz)
				local lbp = math.sqrt(bpx * bpx + bpz * bpz)
				local straight = lab > EPS
					and lbp > EPS
					and math.abs(cross2(abx, abz, bpx, bpz)) <= 1e-4 * lab * lbp
					and (abx * bpx + abz * bpz) > 0
					and math.abs(b.Y - a.Y - (p.Y - a.Y) * lab / (lab + lbp)) < 0.05
				if straight then
					out[n] = p
					continue
				end
			end
			table.insert(out, p)
		end
	end
	return out
end

-------------------------------------------------------------------------------------------------------------------------
-- v2 world routing: backward A* on the junction network, resumable and cached per goal
-------------------------------------------------------------------------------------------------------------------------

RoadGraph.TREE_CACHE = 6 -- goals whose search is kept (GPS objective, custom waypoint, police targets...)
RoadGraph.GOAL_SNAP = 2 -- studs: goals this close together on one edge share a cached search

-- Cumulative arc length at every polyline vertex of world edge ei (cached).
local function cumOf(net: WorldNet, ei: number): { number }
	local c = net.cum[ei]
	if c then
		return c
	end
	local pts = net.W.Edges[ei].points
	local out = table.create(#pts, 0)
	for i = 2, #pts do
		out[i] = out[i - 1] + (pts[i] - pts[i - 1]).Magnitude
	end
	net.cum[ei] = out
	return out
end

-- Point at arc s along world edge ei.
local function pointAt(net: WorldNet, ei: number, s: number): Vector3
	local pts = net.W.Edges[ei].points
	local cum = cumOf(net, ei)
	local n = #pts
	if s <= 0 then
		return pts[1]
	elseif s >= cum[n] then
		return pts[n]
	end
	local lo, hi = 1, n
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if cum[mid] <= s then
			lo = mid
		else
			hi = mid
		end
	end
	local seg = cum[hi] - cum[lo]
	return lerpExact(pts[lo], pts[hi], if seg > EPS then (s - cum[lo]) / seg else 0)
end

-- Append world edge ei's vertices strictly between arc s0 and s1 (travelling s0 -> s1), then the point at s1 (or
-- `last`).
local function appendSlice(net: WorldNet, ei: number, s0: number, s1: number, out: { Vector3 }, last: Vector3?)
	local pts = net.W.Edges[ei].points
	local cum = cumOf(net, ei)
	if s0 <= s1 then
		for i = 1, #pts do
			if cum[i] > s0 + 0.01 and cum[i] < s1 - 0.01 then
				table.insert(out, pts[i])
			end
		end
	else
		for i = #pts, 1, -1 do
			if cum[i] < s0 - 0.01 and cum[i] > s1 + 0.01 then
				table.insert(out, pts[i])
			end
		end
	end
	table.insert(out, last or pointAt(net, ei, s1))
end

-- The cached search toward (edge E, arc s), most recently used last; a new one seeds the goal edge's ends.
local function treeFor(net: WorldNet, E: number, s: number): Tree
	local key = E .. ":" .. math.round(s / RoadGraph.GOAL_SNAP)
	local order = net.treeOrder
	local tr = net.trees[key]
	if tr then
		local i = table.find(order, key)
		if i and i < #order then
			table.remove(order, i)
			table.insert(order, key)
		end
		return tr
	end
	local n = net.n
	local fresh: Tree = {
		edge = E,
		s = s,
		g = table.create(n, math.huge),
		succ = table.create(n, 0),
		state = table.create(n, 0),
		heapNode = {},
		heapF = {},
		size = 0,
		hx = math.huge,
		hz = math.huge,
	}
	local e = net.W.Edges[E]
	-- reach the goal from E.a driving a -> b (always allowed), or from E.b driving b -> a (two-way only)
	fresh.g[e.a] = s * net.k[E]
	fresh.state[e.a] = 1
	if not e.oneWay then
		local c = (e.length - s) * net.k[E]
		if c < fresh.g[e.b] then
			fresh.g[e.b] = c
			fresh.state[e.b] = 1
		end
	end
	net.trees[key] = fresh
	table.insert(order, key)
	while #order > RoadGraph.TREE_CACHE do
		net.trees[table.remove(order, 1) :: string] = nil
	end
	return fresh
end

-- Point the search's heuristic at a new start (x, z): re-key the open frontier (settled costs stay exact).
local function retarget(net: WorldNet, tr: Tree, x: number, z: number)
	tr.hx, tr.hz = x, z
	local hn, hf = tr.heapNode, tr.heapF
	local size = 0
	local state, g, nx, nz, hs = tr.state, tr.g, net.x, net.z, net.hScale
	for v = 1, net.n do
		if state[v] == 1 then
			local dx, dz = nx[v] - x, nz[v] - z
			size = heapPush(hn, hf, size, v, g[v] + math.sqrt(dx * dx + dz * dz) * hs)
		end
	end
	tr.size = size
end

-- Resume the backward A* until no open node can beat the best start seed. seedA / seedB: the (up to two) nodes the
-- start reaches directly, with what it costs to get there (0 = no such seed). Returns (best total seconds, 1 = leave
-- by seedA / 2 = by seedB / 0 = unreachable).
local function searchTree(
	net: WorldNet,
	tr: Tree,
	x: number,
	z: number,
	seedA: number,
	costA: number,
	seedB: number,
	costB: number
): (number, number)
	if tr.hx ~= x or tr.hz ~= z then
		retarget(net, tr, x, z)
	end
	local g, state, succ = tr.g, tr.state, tr.succ
	local hn, hf = tr.heapNode, tr.heapF
	local nx, nz, hs = net.x, net.z, net.hScale
	local inFrom, inCost, inEdge = net.inFrom, net.inCost, net.inEdge
	local function bestSeed(): (number, number)
		local b, which = math.huge, 0
		if seedA > 0 and g[seedA] < math.huge then
			b, which = costA + g[seedA], 1
		end
		if seedB > 0 and g[seedB] < math.huge and costB + g[seedB] < b then
			b, which = costB + g[seedB], 2
		end
		return b, which
	end
	local best, which = bestSeed()
	local size = tr.size
	while size > 0 and hf[1] < best do
		local v
		v, _, size = heapPop(hn, hf, size)
		if state[v] ~= 2 then
			state[v] = 2
			local gv = g[v]
			local from, cost, edge = inFrom[v], inCost[v], inEdge[v]
			for i = 1, #from do
				local u = from[i]
				if state[u] ~= 2 then
					local ng = gv + cost[i]
					if ng < g[u] then
						g[u] = ng
						succ[u] = edge[i]
						state[u] = 1
						local dx, dz = nx[u] - x, nz[u] - z
						size = heapPush(hn, hf, size, u, ng + math.sqrt(dx * dx + dz * dz) * hs)
						if u == seedA or u == seedB then
							best, which = bestSeed()
						end
					end
				end
			end
		end
	end
	tr.size = size
	return best, which
end

-- Fastest drivable polyline on a v2 world graph (seconds: speed per road class + junction waits).
local function worldRoute(
	net: WorldNet,
	P: Vector3,
	Q: Vector3,
	e1: number,
	t1: number,
	e2: number,
	t2: number,
	fineLen1: number,
	fineLen2: number
): { Vector3 }?
	local Edges = net.W.Edges
	local E1, E2 = net.fineEdge[e1], net.fineEdge[e2]
	local s1 = net.fineS0[e1] + t1 * fineLen1
	local s2 = net.fineS0[e2] + t2 * fineLen2
	local ed1, ed2 = Edges[E1], Edges[E2]
	local direct = math.huge
	if E1 == E2 and (s2 >= s1 or not ed1.oneWay) then
		direct = math.abs(s2 - s1) * net.k[E1]
	end
	local tr = treeFor(net, E2, s2)
	-- leave P forward to E1.b (always allowed) or back to E1.a (two-way only)
	local costFwd = (ed1.length - s1) * net.k[E1] + net.delayB[E1]
	local backNode, costBack = 0, math.huge
	if not ed1.oneWay then
		backNode, costBack = ed1.a, s1 * net.k[E1] + net.delayA[E1]
	end
	local best, which = searchTree(net, tr, P.X, P.Z, ed1.b, costFwd, backNode, costBack)
	local out: { Vector3 } = { P }
	if direct <= best then
		appendSlice(net, E1, s1, s2, out, Q)
		return simplify(out)
	end
	if which == 0 then
		return nil
	end
	-- leave E1 toward the chosen end, follow the tree's arcs, finish along E2
	appendSlice(net, E1, s1, if which == 1 then ed1.length else 0, out)
	local node = if which == 1 then ed1.b else ed1.a
	local guard = net.n + 1
	while guard > 0 do
		guard -= 1
		local se = tr.succ[node]
		if se == 0 then
			break
		end
		local ei = math.abs(se)
		local e = Edges[ei]
		if se > 0 then
			appendSlice(net, ei, 0, e.length, out)
			node = e.b
		else
			appendSlice(net, ei, e.length, 0, out)
			node = e.a
		end
	end
	appendSlice(net, E2, if node == ed2.a then 0 else ed2.length, s2, out, Q)
	local simple = simplify(out)
	if #simple == 1 then
		table.insert(simple, Q)
	end
	return simple
end

-- Shortest drivable polyline from fromPos to toPos (both snapped onto the nearest road centerline). nil when the
-- graph is empty or toPos can't be reached (one-way traps / disconnected islands). On a v2 world graph the route is
-- the fastest one (see worldRoute).
function Graph.route(self: Graph, fromPos: Vector3, toPos: Vector3): { Vector3 }?
	local P, e1, t1 = self:nearestPoint(fromPos)
	local Q, e2, t2 = self:nearestPoint(toPos)
	if not (P and Q and e1 and e2 and t1 and t2) then
		return nil
	end
	local net = self.net
	if net then
		local r = worldRoute(net, P, Q, e1, t1, e2, t2, self.edges[e1].length, self.edges[e2].length)
		if r and #r == 1 then
			table.insert(r, Q) -- start and goal on the same spot: still a valid 2-point polyline
		end
		return r
	end
	local edges, nodes = self.edges, self.nodes
	local E1, E2 = edges[e1], edges[e2]

	self.gen += 1
	local gen = self.gen
	local g, parentArc, openGen, closedGen = self.g, self.parentArc, self.openGen, self.closedGen
	local goalCost, goalGen = self.goalCost, self.goalGen

	local best = math.huge
	local bestNode = -1 -- 0 = direct along the shared edge
	if e1 == e2 and (t2 >= t1 or not E1.oneWay) then
		best = math.abs(t2 - t1) * E1.length
		bestNode = 0
	end

	-- goal: Q is reached from E2.a heading a->b (always allowed) or from E2.b heading b->a (two-way only)
	goalGen[E2.a] = gen
	goalCost[E2.a] = t2 * E2.length
	if not E2.oneWay then
		local c = (1 - t2) * E2.length
		if goalGen[E2.b] ~= gen or c < goalCost[E2.b] then
			goalGen[E2.b] = gen
			goalCost[E2.b] = c
		end
	end

	local size = 0
	local function open(node: number, cost: number, arc: number)
		if closedGen[node] == gen then
			return
		end
		if openGen[node] ~= gen or cost < g[node] then
			openGen[node] = gen
			g[node] = cost
			parentArc[node] = arc
			size = heapPush(self.heapNode, self.heapF, size, node, cost + (nodes[node] - Q).Magnitude)
		end
	end
	-- start: leave P toward E1.b (a->b, always allowed) or toward E1.a (two-way only)
	open(E1.b, (1 - t1) * E1.length, 0)
	if not E1.oneWay then
		open(E1.a, t1 * E1.length, 0)
	end

	while size > 0 do
		local node, f
		node, f, size = heapPop(self.heapNode, self.heapF, size)
		if f >= best then
			break
		end
		if closedGen[node] ~= gen then
			closedGen[node] = gen
			local gn = g[node]
			if goalGen[node] == gen then
				local total = gn + goalCost[node]
				if total < best then
					best = total
					bestNode = node
				end
			end
			for _, arc in self.adj[node] do
				local edge = edges[if arc > 0 then arc else -arc]
				local nextNode = if arc > 0 then edge.b else edge.a
				open(nextNode, gn + edge.length, arc)
			end
		end
	end

	if bestNode < 0 then
		return nil
	end
	local points: { Vector3 } = { P }
	if bestNode > 0 then
		local chain: { number } = {}
		local node = bestNode
		while true do
			table.insert(chain, node)
			local arc = parentArc[node]
			if arc == 0 then
				break
			end
			local edge = edges[if arc > 0 then arc else -arc]
			node = if arc > 0 then edge.a else edge.b
		end
		for i = #chain, 1, -1 do
			table.insert(points, nodes[chain[i]])
		end
	end
	table.insert(points, Q)
	local out = simplify(points)
	if #out == 1 then
		table.insert(out, Q) -- start and goal on the same spot: still a valid 2-point polyline
	end
	return out
end

-- Debug / tests.
function Graph.stats(self: Graph): (number, number)
	return #self.nodes, #self.edges
end

-- Forget the cached per-goal searches (v2 world graphs; tests measure cold routes with it).
function Graph.clearRouteCache(self: Graph)
	local net = self.net
	if net then
		net.trees = {}
		net.treeOrder = {}
	end
end

-------------------------------------------------------------------------------------------------------------------------
-- Module-level helpers (default graph of the current layout)
-------------------------------------------------------------------------------------------------------------------------

local cached: Graph? = nil

function RoadGraph.get(): Graph
	local g = cached
	if g == nil then
		-- the v2 world when the layout is v2 (MapLayout.WORLD_VERSION), else the layout's segments / the grid
		if (MapLayout :: any).WORLD_VERSION ~= nil then
			g = RoadGraph.fromWorld()
		else
			g = RoadGraph.build()
		end
		cached = g
	end
	return g :: Graph
end

-- Drop the cached graph (after the layout changed at runtime).
function RoadGraph.invalidate()
	cached = nil
end

function RoadGraph.nearestNode(pos: Vector3): (number?, Vector3?)
	return RoadGraph.get():nearestNode(pos)
end

function RoadGraph.nearestPoint(pos: Vector3): (Vector3?, number?, number?, number?)
	return RoadGraph.get():nearestPoint(pos)
end

function RoadGraph.route(fromPos: Vector3, toPos: Vector3): { Vector3 }?
	return RoadGraph.get():route(fromPos, toPos)
end

function RoadGraph.routeLength(points: { Vector3 }?): number
	if not points then
		return 0
	end
	local total = 0
	for i = 2, #points do
		total += (points[i] - points[i - 1]).Magnitude
	end
	return total
end

-- Closest point of a polyline to pos (XZ plane): (distance, segment index i (points[i] -> points[i+1]), t, point).
-- A 1-point polyline returns segment 1, t 0. Empty -> (math.huge, 0, 0, pos).
function RoadGraph.projectToPolyline(points: { Vector3 }, pos: Vector3): (number, number, number, Vector3)
	local n = #points
	if n == 0 then
		return math.huge, 0, 0, pos
	end
	if n == 1 then
		local p = points[1]
		local dx, dz = p.X - pos.X, p.Z - pos.Z
		return math.sqrt(dx * dx + dz * dz), 1, 0, p
	end
	local bestD, bestI, bestT = math.huge, 1, 0
	for i = 1, n - 1 do
		local a, b = points[i], points[i + 1]
		local dx, dz = b.X - a.X, b.Z - a.Z
		local len2 = dx * dx + dz * dz
		local t = if len2 > EPS then math.clamp(((pos.X - a.X) * dx + (pos.Z - a.Z) * dz) / len2, 0, 1) else 0
		local px, pz = a.X + dx * t - pos.X, a.Z + dz * t - pos.Z
		local d = px * px + pz * pz
		if d < bestD then
			bestD, bestI, bestT = d, i, t
		end
	end
	return math.sqrt(bestD), bestI, bestT, lerpExact(points[bestI], points[bestI + 1], bestT)
end

return RoadGraph
