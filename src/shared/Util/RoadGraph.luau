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
-- generation-stamped scratch arrays, so a route on the current city takes well under a millisecond.
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
	for i, n in W.Nodes do
		nodes[i] = n.pos
		nodeLevel[i] = 0
	end
	for _, e in W.Edges do
		local pts = e.points
		local class = RoadGraph.WORLD_CLASS[e.class] or "street"
		local lanes = math.max(e.lanesF, e.lanesB, 1)
		local prev = e.a
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
			end
			prev = cur
		end
	end
	return RoadGraph._finalize(nodes, nodeLevel, edges)
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

local function heapPush(self: Graph, size: number, node: number, f: number): number
	local hn, hf = self.heapNode, self.heapF
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

local function heapPop(self: Graph, size: number): (number, number, number)
	local hn, hf = self.heapNode, self.heapF
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

-- Shortest drivable polyline from fromPos to toPos (both snapped onto the nearest road centerline). nil when the
-- graph is empty or toPos can't be reached (one-way traps / disconnected islands).
function Graph.route(self: Graph, fromPos: Vector3, toPos: Vector3): { Vector3 }?
	local P, e1, t1 = self:nearestPoint(fromPos)
	local Q, e2, t2 = self:nearestPoint(toPos)
	if not (P and Q and e1 and e2 and t1 and t2) then
		return nil
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
			size = heapPush(self, size, node, cost + (nodes[node] - Q).Magnitude)
		end
	end
	-- start: leave P toward E1.b (a->b, always allowed) or toward E1.a (two-way only)
	open(E1.b, (1 - t1) * E1.length, 0)
	if not E1.oneWay then
		open(E1.a, t1 * E1.length, 0)
	end

	while size > 0 do
		local node, f
		node, f, size = heapPop(self, size)
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
