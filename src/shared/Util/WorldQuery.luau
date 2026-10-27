--!strict
-- WorldQuery: runtime questions about the v2 world (Config/WorldLayout). Pure (no Instances, no services), shared by
-- server systems (traffic, police, spawns, events) and clients (GPS, minimap, HUD). Indexes are built lazily on first
-- use. Successor of Util/MapLayout (see docs/v2/world/MIGRATION.md for the function-by-function mapping).
--
-- Terrain     heightAt(pos) / gradeAt(pos), isWater(pos), shoreDistance(pos)
-- Districts   districtAt(pos) -> District, pointInDistrict(pos, id)
-- Roads       nearestRoadPoint(pos, opts?), isOnRoad(pos, margin?), edgePoint(edge, s), laneCFrame(edge, lane, dir, s),
--             laneCount(edge, dir), laneOffset(edge, lane, dir), parkingCFrame(edge, side, s), sidewalkCFrame(edge, side, s),
--             nearestLane(pos, heading?),
--             outgoing(node), otherEnd(edge, node), route(from, to, opts?), routeLength(points), arcs(traffic?)
-- Junctions   intersectionAt(pos, slack?), signalState(intersection, approach, time)
-- Places      parcelAt(pos) (server), poi(id), poisOfKind(kind), nearestPOI(pos, kind), plot(i), plotAt(pos),
--             plotCount(), landmark(id), eta(fieldId, pos) (server)
--
-- Routing is time-weighted (travel seconds at the AI cruise speed + the expected wait at the junction you arrive at),
-- so the GPS, police and armored trucks take the freeway the way drivers do; the start and goal are virtual nodes on
-- the projected edges (one-ways and the unit's heading respected), so a route never starts with a chord through a
-- block (tech critiques 2, 3).

local WorldLayout = require(script.Parent.Parent.Config.WorldLayout)
local WorldGen = require(script.Parent.WorldGen)

type Edge = WorldLayout.Edge
type Node = WorldLayout.Node
type Parcel = WorldLayout.Parcel
type POI = WorldLayout.POI
type Plot = WorldLayout.Plot
type District = WorldLayout.District
type Intersection = WorldLayout.Intersection

local WorldQuery = {}

local Edges = WorldLayout.Edges
local Nodes = WorldLayout.Nodes

local function xz(pos: Vector3): (number, number)
	return pos.X, pos.Z
end

-------------------------------------------------------------------------------------------------------------------------
-- Terrain
-------------------------------------------------------------------------------------------------------------------------

-- Terrain surface height (channel / reservoir carved in).
function WorldQuery.heightAt(pos: Vector3): number
	return WorldLayout.heightAt(xz(pos))
end

-- Smooth grade (what roads and lots sit on; ignores the channel carve).
function WorldQuery.gradeAt(pos: Vector3): number
	return WorldLayout.gradeAt(xz(pos))
end

-- True over the sea (natural grade below sea level) or inside the reservoir. The Rust River channel floor is below
-- sea level too but dry (flood gate), so this uses the uncarved grade, not heightAt.
function WorldQuery.isWater(pos: Vector3): boolean
	local x, z = xz(pos)
	if WorldLayout.gradeAt(x, z) < WorldLayout.SEA_LEVEL then
		return true
	end
	for _, w in WorldLayout.Water do
		if WorldGen.pointInPoly(w.points, x, z) then
			return true
		end
	end
	return false
end

-------------------------------------------------------------------------------------------------------------------------
-- Districts
-------------------------------------------------------------------------------------------------------------------------

local districtById: { [string]: District } = {}
for _, d in WorldLayout.Districts do
	districtById[d.id] = d
end

function WorldQuery.district(id: string): District?
	return districtById[id]
end

-- The most specific district containing pos (Red Mesa countryside when nothing else does).
function WorldQuery.districtAt(pos: Vector3): District
	return districtById[WorldLayout.districtAt(xz(pos))]
end

function WorldQuery.pointInDistrict(pos: Vector3, id: string): boolean
	return WorldLayout.districtAt(xz(pos)) == id
end

-------------------------------------------------------------------------------------------------------------------------
-- Road segment index (3D aware: an elevated deck and the street under it are told apart by height)
-------------------------------------------------------------------------------------------------------------------------

type SegIdx = WorldGen.SegIndex
local segIdx: SegIdx? = nil
local segY0: { number } = {}
local segY1: { number } = {}
local segS0: { number } = {} -- arc length at the segment start
local MAX_PAD = 60

local function segments(): SegIdx
	local idx = segIdx
	if idx then
		return idx
	end
	local built = WorldGen.segIndex(64)
	for ei, e in Edges do
		local pts = e.points
		local acc = 0
		local pad = math.min(MAX_PAD, e.width / 2 + e.sidewalk + 2)
		for k = 1, #pts - 1 do
			local a, b = pts[k], pts[k + 1]
			WorldGen.segAdd(built, a.X, a.Z, b.X, b.Z, ei, k, pad)
			local id = #built.ax
			segY0[id] = a.Y
			segY1[id] = b.Y
			segS0[id] = acc
			acc += WorldGen.dist(a.X, a.Z, b.X, b.Z)
		end
	end
	segIdx = built
	return built
end

export type RoadQuery = {
	maxDistance: number?, -- XZ search radius (default 400)
	classes: { [string]: boolean }?, -- only these road classes
	traffic: boolean?, -- only edges AI traffic may use
	layer: number?, -- only this layer (0 ground, 1 deck, 2 flyover, -1 channel)
	ignoreHeight: boolean?, -- pure top-down distance (default: 3D, vertical gaps weigh 3x)
}

local function edgeOk(e: Edge, q: RoadQuery?): boolean
	if q == nil then
		return true
	end
	if q.classes and not q.classes[e.class] then
		return false
	end
	if q.traffic and not e.traffic then
		return false
	end
	if q.layer ~= nil and e.layer ~= q.layer then
		return false
	end
	return true
end

-- Closest point on any road centerline: (point, edgeId, s along the edge, score distance). nil when nothing is in
-- range. The score is XZ distance + 3 x vertical gap, so under a freeway you get the street, on the deck the deck.
function WorldQuery.nearestRoadPoint(pos: Vector3, q: RoadQuery?): (Vector3?, number?, number, number)
	local idx = segments()
	local maxD = if q and q.maxDistance then q.maxDistance else 400
	local ignoreY = q ~= nil and q.ignoreHeight == true
	local x, z = xz(pos)
	local best: number? = nil
	local bestScore, bestS, bx, by, bz = math.huge, 0, 0, 0, 0
	local radius = 32
	while true do
		WorldGen.segQuery(idx, x, z, radius, function(id: number)
			local ei = idx.owner[id]
			local e = Edges[ei]
			if not edgeOk(e, q) then
				return
			end
			local t, px, pz, d = WorldGen.projectSeg(x, z, idx.ax[id], idx.az[id], idx.bx[id], idx.bz[id])
			if d > maxD then
				return
			end
			local py = segY0[id] + (segY1[id] - segY0[id]) * t
			local score = if ignoreY then d else d + 3 * math.abs(pos.Y - py)
			if score < bestScore - 1e-9 or (math.abs(score - bestScore) <= 1e-9 and best ~= nil and ei < best) then
				local seg = WorldGen.dist(idx.ax[id], idx.az[id], idx.bx[id], idx.bz[id])
				best, bestScore, bestS, bx, by, bz = ei, score, segS0[id] + t * seg, px, py, pz
			end
		end)
		if best ~= nil and bestScore <= radius then
			break
		end
		if radius >= maxD then
			break
		end
		radius = math.min(maxD, radius * 2)
	end
	if best == nil then
		return nil, nil, 0, math.huge
	end
	return Vector3.new(bx, by, bz), best, bestS, bestScore
end

-- Is pos on a road surface (between the curbs, within 6 studs of the deck height)? Returns the edge as well.
function WorldQuery.isOnRoad(pos: Vector3, margin: number?): (boolean, number?)
	local idx = segments()
	local x, z = xz(pos)
	local m = margin or 0
	local hit: number? = nil
	WorldGen.segQuery(idx, x, z, 0, function(id: number)
		if hit then
			return
		end
		local ei = idx.owner[id]
		local e = Edges[ei]
		local t, _, _, d = WorldGen.projectSeg(x, z, idx.ax[id], idx.az[id], idx.bx[id], idx.bz[id])
		local py = segY0[id] + (segY1[id] - segY0[id]) * t
		if d <= e.width / 2 + m and math.abs(pos.Y - py) <= 6 then
			hit = ei
		end
	end)
	return hit ~= nil, hit
end

-------------------------------------------------------------------------------------------------------------------------
-- Along an edge
-------------------------------------------------------------------------------------------------------------------------

local cumCache: { [number]: { number } } = {}
local function cumOf(ei: number): { number }
	local c = cumCache[ei]
	if c then
		return c
	end
	local pts = Edges[ei].points
	local out = table.create(#pts, 0)
	for k = 2, #pts do
		out[k] = out[k - 1] + WorldGen.dist(pts[k - 1].X, pts[k - 1].Z, pts[k].X, pts[k].Z)
	end
	cumCache[ei] = out
	return out
end

-- Point and unit tangent (a -> b direction, flat) at arc length s along edge ei.
function WorldQuery.edgePoint(ei: number, s: number): (Vector3, Vector3)
	local e = Edges[ei]
	local pts = e.points
	local cum = cumOf(ei)
	local n = #pts
	s = math.clamp(s, 0, cum[n])
	local lo, hi = 1, n - 1
	while lo < hi do
		local mid = (lo + hi + 1) // 2
		if cum[mid] <= s then
			lo = mid
		else
			hi = mid - 1
		end
	end
	local i = lo
	while i < n - 1 and cum[i + 1] - cum[i] < 1e-9 do
		i += 1
	end
	local a, b = pts[i], pts[i + 1]
	local len = cum[i + 1] - cum[i]
	local t = if len > 1e-9 then math.clamp((s - cum[i]) / len, 0, 1) else 0
	local tan = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	tan = if tan.Magnitude > 1e-9 then tan.Unit else Vector3.new(1, 0, 0)
	return a:Lerp(b, t), tan
end

-- Lanes travelling in direction dir (+1 = a -> b, -1 = b -> a).
function WorldQuery.laneCount(ei: number, dir: number): number
	local e = Edges[ei]
	return if dir >= 0 then e.lanesF else e.lanesB
end

-- Lateral offset of lane `lane` (1 = innermost, next to the centerline / median; one-way: 1 = leftmost) to the
-- RIGHT of the travel direction, measured from the edge centerline. One-way carriageways with uneven shoulders (the
-- freeways: 4 inside, 8 outside) put the lanes where they are painted (tech critique 12).
function WorldQuery.laneOffset(ei: number, lane: number, dir: number): number
	local e = Edges[ei]
	local W = e.laneWidth
	if e.oneWay then
		local n = e.lanesF
		local margin = e.width - n * W
		local left = if e.class == "freeway" then e.shoulderIn else margin / 2
		return -e.width / 2 + left + (lane - 0.5) * W
	end
	local _ = dir
	return e.median / 2 + (lane - 0.5) * W
end

-- CFrame on lane `lane` at arc length s (always measured from node a), facing the travel direction dir. Y = road.
function WorldQuery.laneCFrame(ei: number, lane: number, dir: number, s: number): CFrame
	local p, tan = WorldQuery.edgePoint(ei, s)
	local f = if dir >= 0 then tan else -tan
	local right = Vector3.new(-f.Z, 0, f.X)
	local pos = p + right * WorldQuery.laneOffset(ei, lane, dir)
	return CFrame.lookAt(pos, pos + f)
end

-- Curb parking spot on side (+1 right of a -> b, -1 left) at arc length s, facing the adjacent traffic flow.
function WorldQuery.parkingCFrame(ei: number, side: number, s: number): CFrame
	local e = Edges[ei]
	local p, tan = WorldQuery.edgePoint(ei, s)
	local right = Vector3.new(-tan.Z, 0, tan.X)
	local pos = p + right * side * (e.width / 2 - WorldLayout.Scale.PARKING_LANE / 2)
	local f = if side < 0 and not e.oneWay then -tan else tan
	return CFrame.lookAt(pos, pos + f)
end

-- Middle of the sidewalk on side (+1 right of a -> b, -1 left) at arc length s, at curb-top height, facing a -> b.
-- nil when the edge has no sidewalk (freeway, rural, alley). NPC walkers follow these and turn at junction radii.
function WorldQuery.sidewalkCFrame(ei: number, side: number, s: number): CFrame?
	local e = Edges[ei]
	if e.sidewalk <= 0 then
		return nil
	end
	local p, tan = WorldQuery.edgePoint(ei, s)
	local right = Vector3.new(-tan.Z, 0, tan.X)
	local pos = p + right * side * (e.width / 2 + e.sidewalk / 2) + Vector3.new(0, WorldLayout.Scale.CURB_HEIGHT, 0)
	return CFrame.lookAt(pos, pos + tan)
end

-- Nearest legal traffic-lane CFrame (outer lane, facing a legal direction; the one closest to `heading` if given).
-- Replacement for MapLayout.nearestLane (police respawns, placing cars legally).
function WorldQuery.nearestLane(pos: Vector3, heading: Vector3?, q: RoadQuery?): CFrame?
	local query: RoadQuery = q or { traffic = true }
	local p, ei, s = WorldQuery.nearestRoadPoint(pos, query)
	if p == nil or ei == nil then
		return nil
	end
	local e = Edges[ei]
	local _, tan = WorldQuery.edgePoint(ei, s)
	local dir = 1
	if not e.oneWay then
		if heading then
			dir = if heading:Dot(tan) >= 0 then 1 else -1
		else
			-- the side of the road pos is on
			local right = Vector3.new(-tan.Z, 0, tan.X)
			dir = if (pos - p):Dot(right) >= 0 then 1 else -1
		end
	end
	local lanes = WorldQuery.laneCount(ei, dir)
	return WorldQuery.laneCFrame(ei, math.max(1, lanes), dir, s)
end

-- The node at the other end of edge ei.
function WorldQuery.otherEnd(ei: number, nodeId: number): number
	local e = Edges[ei]
	return if e.a == nodeId then e.b else e.a
end

export type Exit = { edge: number, to: number, dir: number, heading: Vector3 }

-- Legal ways out of a node (for traffic turn choices): edge, the node it leads to, travel direction, heading.
function WorldQuery.outgoing(nodeId: number): { Exit }
	local out: { Exit } = {}
	for _, ei in Nodes[nodeId].edges do
		local e = Edges[ei]
		if e.a == nodeId then
			local _, tan = WorldQuery.edgePoint(ei, 0)
			table.insert(out, { edge = ei, to = e.b, dir = 1, heading = tan })
		end
		if e.b == nodeId and not e.oneWay then
			local _, tan = WorldQuery.edgePoint(ei, e.length)
			table.insert(out, { edge = ei, to = e.a, dir = -1, heading = -tan })
		end
	end
	return out
end

-------------------------------------------------------------------------------------------------------------------------
-- Routing (time-weighted A* on the directed graph; GPS, police, armored trucks)
-------------------------------------------------------------------------------------------------------------------------

local function nodePos(i: number): (number, number)
	local p = Nodes[i].pos
	return p.X, p.Z
end

-- Seconds lost arriving at `node` along edge ei (signals always; stop / all-way / yield on the approaches that stop).
local function arrivalDelay(ei: number, node: number): number
	local n = Nodes[node]
	local id = n.intersection
	if id == nil then
		return 0
	end
	local it = WorldLayout.Intersections[id]
	if it.control == "signal" then
		return WorldLayout.JunctionDelay.signal
	elseif it.control == "merge" or it.control == "none" then
		return 0
	end
	for _, k in it.stopApproaches do
		if it.approaches[k].edge == ei then
			return WorldLayout.JunctionDelay[it.control] or 0
		end
	end
	return 0
end

local function timeCost(i: number, forward: boolean): number
	local e = Edges[i]
	return e.length / math.max(e.speed, 5) + arrivalDelay(i, if forward then e.b else e.a)
end

local arcCache: { [string]: { { WorldGen.Arc } } } = {}
-- Directed arcs (cached): traffic = only roads AI traffic uses; shortest = cost in studs instead of seconds.
function WorldQuery.arcs(traffic: boolean?, shortest: boolean?): { { WorldGen.Arc } }
	local key = (if traffic then "t" else "a") .. (if shortest then "d" else "s")
	local cached = arcCache[key]
	if cached then
		return cached
	end
	local built = WorldGen.arcs(
		#Nodes,
		Edges,
		function(i: number): boolean
			return Edges[i].oneWay
		end,
		if traffic
			then function(i: number): boolean
				return Edges[i].traffic
			end
			else nil,
		if shortest then nil else timeCost
	)
	arcCache[key] = built
	return built
end

export type RouteOpts = {
	traffic: boolean?, -- keep to roads AI traffic uses (no pier, channel, runway, alleys)
	shortest: boolean?, -- minimise studs instead of seconds
	heading: Vector3?, -- the unit's facing: starting against it on a two-way road costs a U-turn
	maxSnap: number?, -- how far from a road the endpoints may be (default 3000)
}

local UTURN_SECONDS = 12

-- Start / goal seeds for a point snapped onto edge ei at arc s ({ node = cost }), respecting one-ways.
local function seedsFor(
	ei: number,
	s: number,
	asStart: boolean,
	shortest: boolean,
	heading: Vector3?
): { [number]: number }
	local e = Edges[ei]
	local k = if shortest then 1 else 1 / math.max(e.speed, 5)
	local L = e.length
	local out: { [number]: number } = {}
	if asStart then
		local fwdPenalty, backPenalty = 0, 0
		if heading and not e.oneWay then
			local _, tan = WorldQuery.edgePoint(ei, s)
			local pen = if shortest then UTURN_SECONDS * 20 else UTURN_SECONDS
			if heading:Dot(tan) >= 0 then
				backPenalty = pen
			else
				fwdPenalty = pen
			end
		end
		out[e.b] = (L - s) * k + fwdPenalty
		if not e.oneWay then
			out[e.a] = s * k + backPenalty
		end
	else
		out[e.a] = s * k
		if not e.oneWay then
			out[e.b] = (L - s) * k
		end
	end
	return out
end

-- Points of edge ei from arc s0 to s1 (either direction), endpoints included.
local function slice(ei: number, s0: number, s1: number, out: { Vector3 })
	local pts = Edges[ei].points
	local cum = cumOf(ei)
	local function push(p: Vector3)
		local last = out[#out]
		if last == nil or (last - p).Magnitude > 0.05 then
			table.insert(out, p)
		end
	end
	push((WorldQuery.edgePoint(ei, s0)))
	if s0 <= s1 then
		for k = 1, #pts do
			if cum[k] > s0 + 0.01 and cum[k] < s1 - 0.01 then
				push(pts[k])
			end
		end
	else
		for k = #pts, 1, -1 do
			if cum[k] < s0 - 0.01 and cum[k] > s1 + 0.01 then
				push(pts[k])
			end
		end
	end
	push((WorldQuery.edgePoint(ei, s1)))
end

-- Drivable polyline from (the road nearest) fromPos to (the road nearest) toPos. Returns (points, length in studs,
-- signed edge ids, cost) or nil when unreachable. The first and last pieces run along the snapped edges.
function WorldQuery.route(
	fromPos: Vector3,
	toPos: Vector3,
	opts: RouteOpts?
): ({ Vector3 }?, number, { number }, number)
	local traffic = opts ~= nil and opts.traffic == true
	local shortest = opts ~= nil and opts.shortest == true
	local maxSnap = if opts and opts.maxSnap then opts.maxSnap else 3000
	local q: RoadQuery = { traffic = traffic, maxDistance = maxSnap }
	local pa, ea, sa = WorldQuery.nearestRoadPoint(fromPos, q)
	local pb, eb, sb = WorldQuery.nearestRoadPoint(toPos, q)
	if pa == nil or pb == nil or ea == nil or eb == nil then
		return nil, 0, {}, math.huge
	end
	local arcs = WorldQuery.arcs(traffic, shortest)
	local starts = seedsFor(ea, sa, true, shortest, opts and opts.heading)
	local goals = seedsFor(eb, sb, false, shortest, nil)
	local hScale = if shortest then 1 else 1 / math.max(WorldLayout.MaxSpeed, 1)
	-- same edge and drivable directly
	local direct: number? = nil
	if ea == eb and (sb >= sa or not Edges[ea].oneWay) then
		local e = Edges[ea]
		direct = math.abs(sb - sa) * (if shortest then 1 else 1 / math.max(e.speed, 5))
	end
	local path, startNode, goalNode, cost = WorldGen.astarMulti(arcs, nodePos, starts, goals, pb.X, pb.Z, hScale)
	local pts: { Vector3 } = {}
	if direct ~= nil and (path == nil or (direct :: number) <= cost) then
		slice(ea, sa, sb, pts)
		return pts, math.abs(sb - sa), { if sb >= sa then ea else -ea }, direct :: number
	end
	if path == nil then
		return nil, 0, {}, math.huge
	end
	local edges: { number } = {}
	local length = 0
	local eA = Edges[ea]
	if startNode == eA.b then
		slice(ea, sa, eA.length, pts)
		table.insert(edges, ea)
		length += eA.length - sa
	else
		slice(ea, sa, 0, pts)
		table.insert(edges, -ea)
		length += sa
	end
	for _, signed in path do
		local ei = math.abs(signed)
		local e = Edges[ei]
		if signed > 0 then
			slice(ei, 0, e.length, pts)
		else
			slice(ei, e.length, 0, pts)
		end
		table.insert(edges, signed)
		length += e.length
	end
	local eB = Edges[eb]
	if goalNode == eB.a then
		slice(eb, 0, sb, pts)
		table.insert(edges, eb)
		length += sb
	else
		slice(eb, eB.length, sb, pts)
		table.insert(edges, -eb)
		length += eB.length - sb
	end
	return pts, length, edges, cost
end

function WorldQuery.routeLength(points: { Vector3 }?): number
	if not points then
		return 0
	end
	local total = 0
	for i = 2, #points do
		total += (points[i] - points[i - 1]).Magnitude
	end
	return total
end

-------------------------------------------------------------------------------------------------------------------------
-- Intersections + signals
-------------------------------------------------------------------------------------------------------------------------

local interCells: { [number]: { number } }? = nil
local function interIndex(): { [number]: { number } }
	local c = interCells
	if c then
		return c
	end
	local built: { [number]: { number } } = {}
	for _, it in WorldLayout.Intersections do
		local r = it.radius
		WorldGen.hashBox(built, 64, it.pos.X - r, it.pos.Z - r, it.pos.X + r, it.pos.Z + r, it.id)
	end
	interCells = built
	return built
end

-- The junction whose clear box contains pos (radius + slack), at a matching height.
function WorldQuery.intersectionAt(pos: Vector3, slack: number?): Intersection?
	local cells = interIndex()
	local list = cells[WorldGen.cellKey(math.floor(pos.X / 64), math.floor(pos.Z / 64))]
	if not list then
		return nil
	end
	local best: Intersection? = nil
	local bestD = math.huge
	for _, id in list do
		local it = WorldLayout.Intersections[id]
		local d = WorldGen.dist(pos.X, pos.Z, it.pos.X, it.pos.Z)
		if d <= it.radius + (slack or 0) and math.abs(pos.Y - it.pos.Y) < 8 and d < bestD then
			best, bestD = it, d
		end
	end
	return best
end

export type SignalState = "green" | "amber" | "red" | "none"

-- Deterministic signal state for approach index `approach` of intersection `id` at time t (e.g.
-- workspace:GetServerTimeNow()): every client and the server agree without replication.
function WorldQuery.signalState(id: number, approach: number, t: number): SignalState
	local it = WorldLayout.Intersections[id]
	if it.control ~= "signal" or it.cycle <= 0 then
		return "none"
	end
	local tc = (t + it.offset) % it.cycle
	local acc = 0
	for _, ph in it.phases do
		local member = table.find(ph.approaches, approach) ~= nil
		if tc < acc + ph.green then
			return if member then "green" else "red"
		elseif tc < acc + ph.green + it.amber then
			return if member then "amber" else "red"
		end
		acc += ph.green + it.amber + it.allRed
		if tc < acc then
			return "red"
		end
	end
	return "red"
end

-------------------------------------------------------------------------------------------------------------------------
-- Parcels, POIs, plots, landmarks
-------------------------------------------------------------------------------------------------------------------------

local parcelCells: { [number]: { number } }? = nil
local PARCEL_CELL = 128

local function parcelIndex(): { [number]: { number } }
	local c = parcelCells
	if c then
		return c
	end
	local built: { [number]: { number } } = {}
	for _, p in WorldLayout.Parcels do
		local r = math.sqrt(p.size.X * p.size.X + p.size.Z * p.size.Z) / 2
		local c0 = p.cframe.Position
		WorldGen.hashBox(built, PARCEL_CELL, c0.X - r, c0.Z - r, c0.X + r, c0.Z + r, p.id)
	end
	parcelCells = built
	return built
end

-- The lot containing pos (top-down), or nil. Server only (lots are server data): nil on clients.
function WorldQuery.parcelAt(pos: Vector3): Parcel?
	if not WorldLayout.hasServerData() then
		return nil
	end
	local list = parcelIndex()[WorldGen.cellKey(math.floor(pos.X / PARCEL_CELL), math.floor(pos.Z / PARCEL_CELL))]
	if not list then
		return nil
	end
	for _, id in list do
		local p = WorldLayout.Parcels[id]
		local lp = p.cframe:PointToObjectSpace(pos)
		if math.abs(lp.X) <= p.size.X / 2 and math.abs(lp.Z) <= p.size.Z / 2 then
			return p
		end
	end
	return nil
end

local poiById: { [string]: POI } = {}
for _, p in WorldLayout.POIs do
	poiById[p.id] = p
end

function WorldQuery.poi(id: string): POI?
	return poiById[id]
end

function WorldQuery.poisOfKind(kind: string): { POI }
	local out: { POI } = {}
	for _, p in WorldLayout.POIs do
		if p.kind == kind then
			table.insert(out, p)
		end
	end
	return out
end

-- Nearest POI of a kind by straight-line distance to its entrance (e.g. "hospital" for WASTED respawns).
function WorldQuery.nearestPOI(pos: Vector3, kind: string): POI?
	local best: POI? = nil
	local bestD = math.huge
	for _, p in WorldLayout.POIs do
		if p.kind == kind then
			local d = (p.entrance - pos).Magnitude
			if d < bestD then
				best, bestD = p, d
			end
		end
	end
	return best
end

function WorldQuery.plotCount(): number
	return #WorldLayout.Plots
end

function WorldQuery.plot(index: number): Plot
	local p = WorldLayout.Plots[index]
	assert(p, "bad plot index")
	return p
end

-- Plot whose reserved footprint contains pos (top-down, any height up to 60 above the ground), or nil.
function WorldQuery.plotAt(pos: Vector3): number?
	for i, p in WorldLayout.Plots do
		local lp = p.cframe:PointToObjectSpace(pos)
		if math.abs(lp.X) <= p.size.X / 2 and math.abs(lp.Z) <= p.size.Z / 2 and lp.Y > -4 and lp.Y < 60 then
			return i
		end
	end
	return nil
end

-- Seconds from pos to an ETA field's target (Hot Drop zone id, or "<armored route id>_<stop>"), or nil. Server only.
function WorldQuery.eta(fieldId: string, pos: Vector3): number?
	if not WorldLayout.hasServerData() then
		return nil
	end
	local field = WorldLayout.EtaFields[fieldId]
	if not field then
		return nil
	end
	local p, ei, s = WorldQuery.nearestRoadPoint(pos, { maxDistance = 3000 })
	if p == nil or ei == nil then
		return nil
	end
	local best = math.huge
	for node, c in seedsFor(ei, s, true, false, nil) do
		local f = field[node]
		if f and f >= 0 then
			best = math.min(best, c + f)
		end
	end
	return if best < math.huge then best else nil
end

function WorldQuery.landmark(id: string): WorldLayout.Landmark?
	for _, l in WorldLayout.Landmarks do
		if l.id == id then
			return l
		end
	end
	return nil
end

return WorldQuery
