--!strict
-- WorldLayout generator, phase 3 (AUTHORING TOOL, runs in Lune via tools/world/gen.luau; never shipped).
--
-- Phase 1 built the road graph, phase 2 placed POIs, plots, lots, landmarks, zones and jumps. This phase adds what
-- hangs off routing and the street edges:
--   15. time-weighted routing (travel seconds + junction delay), snapped routes, ETA fields
--   16. spawns: curb parking (car tiers), off-street rare spots, police lanes, traffic edges, respawns
--   17. armored-truck runs and races (planned on the time-weighted graph, police / garage clearances measured)
--   18. roadblock anchors, the Harbor lift bridge, heist drop-offs, car swaps
--   19. per-plot service metrics + onboarding order
--   20. streetscape (lamps, palms, street trees, utility poles, billboards, bus stops, hydrants, bins)
--   21. rails, pedestrian paths, bridges, level crossings
--   22. districts export + stats
-- Pure and deterministic, like phases 1 and 2. Section numbers continue phase 2's.
local Shared = game:GetService("ReplicatedStorage").Shared
local WorldGen = require(Shared.Util.WorldGen)
local WorldTerrain = require(Shared.Util.WorldTerrain)

type P2 = WorldGen.P2
type P3 = WorldGen.P3
type Arc = WorldGen.Arc

return function(WorldLayout: any)
	local ctx = WorldLayout._ctx
	local c2 = WorldLayout._ctx2
	local S = WorldLayout.Scale
	local LANE: number = S.LANE
	local GRADE: number = WorldLayout.GRADE
	local DELAY: { [string]: number } = WorldLayout.JunctionDelay
	local Nodes: { any } = WorldLayout.Nodes
	local Edges: { any } = WorldLayout.Edges
	local Intersections: { any } = WorldLayout.Intersections
	local POIs: { any } = WorldLayout.POIs
	local Plots: { any } = WorldLayout.Plots
	local Parcels: { any } = WorldLayout.Parcels
	local districtAt: (number, number) -> string = WorldLayout.districtAt
	local subzoneAt: (number, number) -> any = WorldLayout.subzoneAt
	local districtById: { [string]: any } = ctx.districtById
	local gradeAt = WorldTerrain.gradeAt
	local heightAt = WorldTerrain.heightAt
	local landAtLeast = WorldTerrain.landAtLeast
	local poly: ({ { number } }) -> { P2 } = ctx.poly

	local edgePts: { { pts: { P3 } } } = c2.edgePts
	local edgeCum: { { number } } = c2.edgeCum
	local roadSegs = c2.roadSegs
	local edgeIndex = c2.edgeIndex
	local roadClearance: (number, number, number, boolean?) -> (boolean, number?) = c2.roadClearance
	local edgeAt: (number, number) -> (number, number, number, number, number) = c2.edgeAt
	local onBridge: (number, number, number) -> boolean = c2.onBridge
	local nodeRadius: (number) -> number = c2.nodeRadius
	local poiById: { [string]: any } = c2.poiById
	local boxAt: (number, number, number, number) -> string? = c2.boxAt
	local inRestricted: (Vector3) -> any = c2.inRestricted

	local function v(x: number, z: number): Vector3
		return Vector3.new(x, gradeAt(x, z), z)
	end

	---------------------------------------------------------------------------------------------------------------------
	-- 15. Time-weighted routing (gameplay critique 2 / tech critique 2): arc cost = travel seconds at the AI cruise speed
	--     + the expected wait at the junction you arrive at (signal always; stop / all-way / yield only on the approaches
	--     that must stop). Heuristic = straight-line / max speed, so A* stays admissible.
	---------------------------------------------------------------------------------------------------------------------

	-- AI traffic must never drive into a pocket it cannot leave: generated one-way stubs that only continue into
	-- alleys (no traffic) fall outside the main strongly connected traffic component; they stay drivable for players
	-- but AI traffic skips them.
	do
		local trafficArcs0 = WorldGen.arcs(#Nodes, Edges, function(i: number): boolean
			return Edges[i].oneWay
		end, function(i: number): boolean
			return Edges[i].traffic
		end)
		local comp, _, _, mainId = WorldGen.scc(#Nodes, trafficArcs0)
		local dropped = 0
		for _, e in Edges do
			if e.traffic and (comp[e.a] ~= mainId or comp[e.b] ~= mainId) then
				e.traffic = false
				dropped += 1
			end
		end
		WorldLayout.TrafficPockets = dropped
	end

	local MAX_SPEED = 0
	for _, e in Edges do
		MAX_SPEED = math.max(MAX_SPEED, e.speed)
	end
	WorldLayout.MaxSpeed = MAX_SPEED

	-- does traffic arriving at `node` along edge `ei` have to stop / wait? -> seconds
	local function arrivalDelay(ei: number, node: number): number
		local n = Nodes[node]
		if not n.intersection then
			return 0
		end
		local it = Intersections[n.intersection]
		if it.control == "signal" then
			return DELAY.signal
		elseif it.control == "merge" or it.control == "none" then
			return 0
		end
		for _, k in it.stopApproaches do
			if it.approaches[k].edge == ei then
				return DELAY[it.control] or 0
			end
		end
		return 0
	end

	local function timeCost(i: number, forward: boolean): number
		local e = Edges[i]
		return e.length / math.max(e.speed, 5) + arrivalDelay(i, if forward then e.b else e.a)
	end
	local function oneWayOf(i: number): boolean
		return Edges[i].oneWay
	end
	local arcsAll = WorldGen.arcs(#Nodes, Edges, oneWayOf, nil, timeCost)
	local arcsTraffic = WorldGen.arcs(#Nodes, Edges, oneWayOf, function(i: number): boolean
		return Edges[i].traffic
	end, timeCost)
	local arcsDist = WorldGen.arcs(#Nodes, Edges, oneWayOf)

	local function nodePos(i: number): (number, number)
		local p = Nodes[i].pos
		return p.X, p.Z
	end

	-- Snap a point onto the nearest usable edge: (edge, s) or nil.
	local function snap(x: number, z: number, usable: ((any) -> boolean)?, maxD: number?): (number?, number)
		local ei, s = WorldGen.nearestEdge(edgeIndex, x, z, maxD or 3000, function(i: number): boolean
			return usable == nil or usable(Edges[i])
		end)
		return ei, s
	end

	-- Seeds for a point on edge ei at arc s: as a start ({ node = cost to reach it }) or a goal ({ node = cost from
	-- it }), respecting one-ways. costPerStud converts the partial edge into the cost unit.
	local function seeds(ei: number, s: number, asStart: boolean, timeUnit: boolean): { [number]: number }
		local e = Edges[ei]
		local k = if timeUnit then 1 / math.max(e.speed, 5) else 1
		local out: { [number]: number } = {}
		local L = e.length
		if asStart then
			out[e.b] = (L - s) * k -- drive forward to b
			if not e.oneWay then
				out[e.a] = s * k
			end
		else
			out[e.a] = s * k -- arrive from a, drive forward to the point
			if not e.oneWay then
				out[e.b] = (L - s) * k
			end
		end
		return out
	end

	-- Polyline of edge ei between arc lengths s0 -> s1 (either direction).
	local function edgeSlice(ei: number, s0: number, s1: number): { Vector3 }
		local pts = edgePts[ei].pts
		local cum = edgeCum[ei]
		local out: { Vector3 } = {}
		local function at(s: number): Vector3
			local px, py, pz = edgeAt(ei, s)
			return Vector3.new(px, py, pz)
		end
		table.insert(out, at(s0))
		if s0 <= s1 then
			for k = 1, #pts do
				if cum[k] > s0 + 0.01 and cum[k] < s1 - 0.01 then
					table.insert(out, Vector3.new(pts[k].x, pts[k].y, pts[k].z))
				end
			end
		else
			for k = #pts, 1, -1 do
				if cum[k] < s0 - 0.01 and cum[k] > s1 + 0.01 then
					table.insert(out, Vector3.new(pts[k].x, pts[k].y, pts[k].z))
				end
			end
		end
		table.insert(out, at(s1))
		return out
	end

	local function appendPts(dst: { Vector3 }, src: { Vector3 })
		for _, p in src do
			local last = dst[#dst]
			if last == nil or (last - p).Magnitude > 0.05 then
				table.insert(dst, p)
			end
		end
	end

	type Leg = { points: { Vector3 }, edges: { number }, cost: number, length: number }

	-- Route between two points snapped onto edges (virtual start / goal nodes on the projected edges, one-ways and the
	-- unit's travel direction respected: tech critique 3). timeUnit = travel seconds, else studs.
	local function routeLeg(
		a: Vector3,
		b: Vector3,
		arcs: { { Arc } },
		usable: ((any) -> boolean)?,
		timeUnit: boolean
	): Leg?
		local ea, sa = snap(a.X, a.Z, usable)
		local eb, sb = snap(b.X, b.Z, usable)
		if ea == nil or eb == nil then
			return nil
		end
		local starts = seeds(ea, sa, true, timeUnit)
		local goals = seeds(eb, sb, false, timeUnit)
		local hScale = if timeUnit then 1 / MAX_SPEED else 1
		-- same edge, forward, no detour needed
		local direct: Leg? = nil
		if ea == eb and (sb >= sa or not Edges[ea].oneWay) then
			local e = Edges[ea]
			local k = if timeUnit then 1 / math.max(e.speed, 5) else 1
			local pts = edgeSlice(ea, sa, sb)
			direct = {
				points = pts,
				edges = { if sb >= sa then ea else -ea },
				cost = math.abs(sb - sa) * k,
				length = math.abs(sb - sa),
			}
		end
		local path, startNode, goalNode, cost = WorldGen.astarMulti(arcs, nodePos, starts, goals, b.X, b.Z, hScale)
		if path == nil then
			return direct
		end
		if direct and direct.cost <= cost then
			return direct
		end
		local pts: { Vector3 } = {}
		local edges: { number } = {}
		local length = 0
		-- first partial edge: from the snapped point to the start node
		local ea2 = ea :: number
		local eA = Edges[ea2]
		if startNode == eA.b then
			appendPts(pts, edgeSlice(ea2, sa, eA.length))
			table.insert(edges, ea2)
			length += eA.length - sa
		else
			appendPts(pts, edgeSlice(ea2, sa, 0))
			table.insert(edges, -ea2)
			length += sa
		end
		for _, signed in path do
			local ei = math.abs(signed)
			local e = Edges[ei]
			if signed > 0 then
				appendPts(pts, edgeSlice(ei, 0, e.length))
			else
				appendPts(pts, edgeSlice(ei, e.length, 0))
			end
			table.insert(edges, signed)
			length += e.length
		end
		local eb2 = eb :: number
		local eB = Edges[eb2]
		if goalNode == eB.a then
			appendPts(pts, edgeSlice(eb2, 0, sb))
			table.insert(edges, eb2)
			length += sb
		else
			appendPts(pts, edgeSlice(eb2, eB.length, sb))
			table.insert(edges, -eb2)
			length += eB.length - sb
		end
		return { points = pts, edges = edges, cost = cost, length = length }
	end
	WorldLayout._routeLeg = function(a: Vector3, b: Vector3, traffic: boolean?): Leg?
		return routeLeg(a, b, if traffic then arcsTraffic else arcsAll, if traffic
			then function(e: any): boolean
				return e.traffic
			end
			else nil, true)
	end

	-- Cost-to-target field (reverse Dijkstra) for a point: seconds (or studs) from every node to the point.
	local revAll = WorldGen.reverseArcs(#Nodes, arcsAll)
	local revDist = WorldGen.reverseArcs(#Nodes, arcsDist)
	local function groundRoad(e: any): boolean
		return e.layer == 0 and not e.elevated
	end
	local function fieldTo(p: Vector3, timeUnit: boolean): { number }
		local ei, s = snap(p.X, p.Z, groundRoad)
		assert(ei, "fieldTo: no road near " .. tostring(p))
		local goals = seeds(ei, s, false, timeUnit)
		local dist = WorldGen.dijkstra(#Nodes, if timeUnit then revAll else revDist, goals)
		return dist
	end
	-- Cost from a point to a field's target: best over the point's snapped start seeds.
	local function costFrom(field: { number }, p: Vector3, timeUnit: boolean): number
		local ei, s = snap(p.X, p.Z, groundRoad)
		if not ei then
			return math.huge
		end
		local best = math.huge
		for node, c in seeds(ei, s, true, timeUnit) do
			best = math.min(best, c + field[node])
		end
		return best
	end

	---------------------------------------------------------------------------------------------------------------------
	-- 16. Spawns
	---------------------------------------------------------------------------------------------------------------------

	-- Street-car tiers: soft progression by district, sports only on the glamour frontages, Southgate alternates beater /
	-- sedan (gameplay critique 13 / tech critique 15). Target mix ~ beater 25 / sedan 30 / muscle 20 / sports 20 /
	-- super 3 / hyper 1-2 % (super / hyper come mostly from the off-street spots).
	local TIER_BY_DISTRICT: { [string]: string } = {
		downtown = "sports",
		midtown = "sedan",
		beach = "muscle",
		hills = "super",
		foundry = "sedan",
		rust = "beater",
		port = "muscle",
		airport = "sedan",
		cactus = "muscle",
		driftwood = "beater",
		mesa = "muscle",
	}
	local SPORTS_ROADS: { [string]: boolean } = { ["Gilded Mile"] = true, ["Crown Boulevard"] = true }
	local MUSCLE_ROADS: { [string]: boolean } = { ["Palmera Drive"] = true, ["Sunwood Boulevard"] = true }
	local function tierOf(ei: number, x: number, z: number): string
		local e = Edges[ei]
		if SPORTS_ROADS[e.name] then
			return "sports"
		end
		local d = districtAt(x, z)
		if MUSCLE_ROADS[e.name] and d ~= "hills" then
			return "muscle"
		end
		local sz = subzoneAt(x, z)
		if sz and sz.carTier then
			return sz.carTier
		end
		local h = WorldGen.hash(ei, 1, 990)
		if d == "southgate" then
			return if h < 0.55 then "beater" else "sedan"
		elseif d == "beach" then
			return if h < 0.4 then "sedan" else "muscle"
		elseif d == "midtown" then
			return if h < 0.55 then "sedan" elseif h < 0.85 then "muscle" else "beater"
		elseif d == "foundry" then
			return if h < 0.35 then "sedan" elseif h < 0.7 then "beater" else "muscle"
		elseif d == "downtown" then
			return if h < 0.75 then "sports" else "muscle"
		end
		return TIER_BY_DISTRICT[d] or districtById[d].carTier
	end

	-- Bus stops first (avenues / boulevards, right curb every ~600): parking keeps clear of them.
	type Item = { kind: string, pos: Vector3, yaw: number, edge: number, side: number }
	local busStops: { Item } = {}
	local avoidCells: { [number]: { { number } } } = {}
	local function avoidAdd(x: number, z: number, r: number)
		local key = WorldGen.cellKey(math.floor(x / 64), math.floor(z / 64))
		local list = avoidCells[key]
		if not list then
			list = {}
			avoidCells[key] = list
		end
		table.insert(list, { x, z, r })
	end
	local function nearAvoid(x: number, z: number): boolean
		local cx, cz = math.floor(x / 64), math.floor(z / 64)
		for dx = -1, 1 do
			for dz = -1, 1 do
				local list = avoidCells[WorldGen.cellKey(cx + dx, cz + dz)]
				if list then
					for _, q in list do
						if (q[1] - x) ^ 2 + (q[2] - z) ^ 2 < q[3] * q[3] then
							return true
						end
					end
				end
			end
		end
		return false
	end
	for _, p in POIs do
		avoidAdd(p.entrance.X, p.entrance.Z, 34)
	end
	for _, p in Plots do
		avoidAdd(p.door.X, p.door.Z, 40)
		local cs = p.curbSpot.Position
		avoidAdd(cs.X, cs.Z, 14) -- the newbie car's own spot
	end

	-- Yaw (degrees) of a horizontal direction, Roblox convention (CFrame.Angles(0, yaw, 0) looks along it).
	local function yawOf(dx: number, dz: number): number
		return math.deg(math.atan2(-dx, -dz))
	end

	for ei, e in Edges do
		if not (e.class == "avenue" or e.class == "boulevard") or e.layer ~= 0 or e.elevated or e.sidewalk <= 0 then
			continue
		end
		local s0 = nodeRadius(e.a) + 60
		local s1 = e.length - nodeRadius(e.b) - 60
		local s = s0 + 200 * WorldGen.hash(ei, 7, 991)
		while s <= s1 do
			if not onBridge(ei, s, 30) then
				local px, py, pz, tx, tz = edgeAt(ei, s)
				local rx, rz = WorldGen.right(tx, tz)
				local sides: { number } = if e.oneWay then { 1 } else { 1, -1 }
				for _, side in sides do
					local off = e.width / 2 + e.sidewalk * 0.62
					local x, z = px + rx * off * side, pz + rz * off * side
					if not nearAvoid(x, z) then
						-- faces the road (shelter open toward the curb)
						table.insert(busStops, {
							kind = "busstop",
							pos = Vector3.new(x, py + S.CURB_HEIGHT, z),
							yaw = yawOf(-rx * side, -rz * side),
							edge = ei,
							side = side,
						})
						avoidAdd(px + rx * (e.width / 2) * side, pz + rz * (e.width / 2) * side, 26)
					end
				end
			end
			s += 600
		end
	end

	type ParkingSpot = { cframe: CFrame, edge: number, district: string, tier: string, side: number, s: number }
	local parking: { ParkingSpot } = {}
	for ei, e in Edges do
		if not e.parking or e.layer ~= 0 or e.elevated then
			continue
		end
		local s0 = nodeRadius(e.a) + 26
		local s1 = e.length - nodeRadius(e.b) - 26
		local laneSide = e.width / 2 - S.PARKING_LANE / 2
		local k = 0
		local s = s0
		while s <= s1 do
			k += 1
			if onBridge(ei, s, 12) then
				s += S.PARKING_SPACING
				continue
			end
			local px, py, pz, tx, tz = edgeAt(ei, s)
			local rx, rz = WorldGen.right(tx, tz)
			for _, side in { 1, -1 } do
				-- right side faces along a->b; left side along b->a (one-way: both curbs face a->b)
				local fx, fz = tx, tz
				if side < 0 and not e.oneWay then
					fx, fz = -tx, -tz
				end
				local sx, sz = px + rx * laneSide * side, pz + rz * laneSide * side
				if not nearAvoid(sx, sz) and WorldGen.hash(ei, k, if side > 0 then 31 else 32) < 0.86 then
					local pos = Vector3.new(sx, py, sz)
					local did = districtAt(sx, sz)
					table.insert(parking, {
						cframe = CFrame.lookAt(pos, pos + Vector3.new(fx, 0, fz)),
						edge = ei,
						district = did,
						tier = tierOf(ei, sx, sz),
						side = side,
						s = s,
					})
				end
			end
			s += S.PARKING_SPACING
		end
	end

	-- Off-street rare spots (tech critique 15): driveways of Sunwood estates (super), the hangar aprons and the port
	-- container yards (hyper). Facing along the street / out of the hangar door.
	type OffSpot = { cframe: CFrame, district: string, tier: string, parcel: number, kind: string }
	local offstreet: { OffSpot } = {}
	for _, p in Parcels do
		local cf: CFrame = p.cframe
		local look, right = cf.LookVector, cf.RightVector
		if p.district == "hills" and (p.use == "mansion" or p.use == "villa") then
			-- parallel in the setback apron in front of the lot, both quarters of the frontage
			for _, q in { -0.25, 0.25 } do
				local base = cf.Position + look * (p.size.Z / 2 + 7) + right * (p.size.X * q)
				local y = gradeAt(base.X, base.Z)
				if math.abs(y - cf.Position.Y) < 4 and not roadClearance(base.X, base.Z, 2) then
					local pos = Vector3.new(base.X, cf.Position.Y, base.Z)
					table.insert(offstreet, {
						cframe = CFrame.lookAt(pos, pos + right),
						district = p.district,
						tier = "super",
						parcel = p.id,
						kind = "driveway",
					})
				end
			end
		elseif p.use == "hangar" then
			for _, q in { -0.3, -0.1, 0.1, 0.3 } do
				local pos = cf.Position + look * (p.size.Z / 2 + 22) + right * (p.size.X * q)
				if not roadClearance(pos.X, pos.Z, 2) then
					table.insert(offstreet, {
						cframe = CFrame.lookAt(pos, pos + look),
						district = p.district,
						tier = "hyper",
						parcel = p.id,
						kind = "hangar",
					})
				end
			end
		elseif p.use == "container_yard" then
			for _, q in { -0.4, -0.24, -0.08, 0.08, 0.24, 0.4 } do
				local pos = cf.Position + right * (p.size.X * q) + look * (p.size.Z * 0.3)
				table.insert(offstreet, {
					cframe = CFrame.lookAt(pos, pos + look),
					district = p.district,
					tier = "hyper",
					parcel = p.id,
					kind = "yard",
				})
			end
		end
	end

	-- Police spawn lanes: 4-8 per station on its frontage street; HQ gets 12, on two different streets (gameplay 11,
	-- tech 15).
	type PoliceSpawn = { cframe: CFrame, station: string, edge: number }
	local police: { PoliceSpawn } = {}
	local function laneSpawns(stationId: string, ei: number, s: number, offsets: { number })
		local e = Edges[ei]
		for _, ds in offsets do
			local lo, hi = nodeRadius(e.a) + 12, e.length - nodeRadius(e.b) - 12
			if hi <= lo then
				lo, hi = e.length / 2, e.length / 2
			end
			local ss = math.clamp(s + ds, lo, hi)
			local dirs: { number } = if e.oneWay then { 1 } else { 1, -1 }
			for _, dir in dirs do
				local px, py, pz, tx, tz = edgeAt(ei, ss)
				local fx, fz = tx * dir, tz * dir
				local rx, rz = WorldGen.right(fx, fz)
				local off = if e.oneWay
					then (e.lanesF * LANE) / 2 - LANE / 2
					else e.median / 2 + (math.max(e.lanesF, 1) - 0.5) * LANE
				local pos = Vector3.new(px + rx * off, py, pz + rz * off)
				table.insert(
					police,
					{ cframe = CFrame.lookAt(pos, pos + Vector3.new(fx, 0, fz)), station = stationId, edge = ei }
				)
			end
		end
	end
	for _, p in POIs do
		if p.kind ~= "police" then
			continue
		end
		local _, s = WorldGen.polyProject(edgePts[p.edge].pts, p.entrance.X, p.entrance.Z)
		if p.id == "PoliceHQ" then
			laneSpawns(p.id, p.edge, s, { -60, 60, -130, 130, -200, 200 })
			-- second street: the nearest other-named traffic edge within 300 of the HQ
			local best: number?, bestD = nil, 300
			WorldGen.segQuery(roadSegs, p.cframe.Position.X, p.cframe.Position.Z, 300, function(id: number)
				local ei = roadSegs.owner[id]
				local e = Edges[ei]
				if e.name == Edges[p.edge].name or not e.traffic or e.layer ~= 0 or e.elevated then
					return
				end
				local d = WorldGen.polyProject(edgePts[ei].pts, p.cframe.Position.X, p.cframe.Position.Z)
				if d < bestD then
					best, bestD = ei, d
				end
			end)
			if best then
				local b = best :: number
				local _, s2 = WorldGen.polyProject(edgePts[b].pts, p.cframe.Position.X, p.cframe.Position.Z)
				laneSpawns(p.id, b, s2, if Edges[b].oneWay then { -60, 60, -120, 120, 0, 180 } else { -60, 60, 0 })
			end
		else
			laneSpawns(p.id, p.edge, s, { -70, 70, -140, 140 })
		end
	end

	type TrafficEdge = { edge: number, weight: number }
	local trafficEdges: { TrafficEdge } = {}
	for ei, e in Edges do
		if e.traffic then
			table.insert(trafficEdges, { edge = ei, weight = e.length * (e.lanesF + e.lanesB) })
		end
	end

	local hospitalRespawns: { CFrame } = {}
	for _, p in POIs do
		if p.kind == "hospital" then
			local look = p.cframe.LookVector
			local e = Edges[p.edge]
			local pos = p.entrance + look * -(e.sidewalk / 2) + Vector3.new(0, S.CURB_HEIGHT + 3, 0)
			table.insert(hospitalRespawns, CFrame.lookAt(pos, pos + look))
		end
	end

	local plaza = poiById.HotwirePlaza
	local hq = poiById.PoliceHQ
	WorldLayout.Spawns = {
		parking = parking,
		offstreet = offstreet,
		police = police,
		traffic = trafficEdges,
		hospital = hospitalRespawns,
		default = if plaza then plaza.cframe + Vector3.new(0, 3, 0) else CFrame.new(0, GRADE + 3, 0),
		bustedRelease = (function(): CFrame
			if hq then
				local e = Edges[hq.edge]
				local pos = hq.entrance - hq.cframe.LookVector * (e.sidewalk / 2) + Vector3.new(0, S.CURB_HEIGHT + 3, 0)
				return CFrame.lookAt(pos, pos + hq.cframe.LookVector)
			end
			return CFrame.new(0, GRADE + 3, 0)
		end)(),
	}

	-- Hot Drop respawns: players WASTED at a drop come back 600-900 studs away (gameplay critique 6): four sidewalk /
	-- curb points around the drop, one per quadrant.
	for _, hd in WorldLayout.HotDrops do
		local c = hd.cframe.Position
		local list: { CFrame } = {}
		for k = 0, 3 do
			local a = math.rad(45 + 90 * k)
			local r = 750
			local tx, tz = c.X + math.cos(a) * r, c.Z + math.sin(a) * r
			local ei, s = snap(tx, tz, function(e: any): boolean
				return e.layer == 0 and not e.elevated and e.class ~= "channel" and e.class ~= "runway"
			end, 400)
			if ei then
				local px, py, pz, ux, uz = edgeAt(ei, s)
				local rx, rz = WorldGen.right(ux, uz)
				local e = Edges[ei]
				local off = e.width / 2 + (if e.sidewalk > 0 then e.sidewalk / 2 else 5)
				local pos = Vector3.new(px + rx * off, py + S.CURB_HEIGHT + 3, pz + rz * off)
				local d = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(c.X, 0, c.Z)).Magnitude
				if d >= 600 and d <= 900 then
					table.insert(list, CFrame.lookAt(pos, Vector3.new(c.X, pos.Y, c.Z)))
				end
			end
		end
		hd.respawns = list
	end

	---------------------------------------------------------------------------------------------------------------------
	-- 17. Armored-truck runs and races. Armored runs avoid police entrances (250) and garage doors (600) by a cost
	--     penalty; the measured clearances are exported (gameplay critique 9).
	---------------------------------------------------------------------------------------------------------------------

	local policeEntrances: { Vector3 } = {}
	for _, p in POIs do
		if p.kind == "police" then
			table.insert(policeEntrances, p.entrance)
		end
	end
	local function minDistTo(list: { Vector3 }, x: number, z: number): number
		local best = math.huge
		for _, q in list do
			best = math.min(best, WorldGen.dist(q.X, q.Z, x, z))
		end
		return best
	end
	local doors: { Vector3 } = {}
	for _, p in Plots do
		table.insert(doors, p.door)
	end
	-- per-edge clearance to police entrances / garage doors (sampled every 25 studs)
	local edgePoliceClear: { number } = {}
	local edgeDoorClear: { number } = {}
	for ei, e in Edges do
		local cp, cd = math.huge, math.huge
		local s = 0
		while s <= e.length do
			local px, _, pz = edgeAt(ei, s)
			cp = math.min(cp, minDistTo(policeEntrances, px, pz))
			cd = math.min(cd, minDistTo(doors, px, pz))
			s += 25
		end
		edgePoliceClear[ei] = cp
		edgeDoorClear[ei] = cd
	end
	local arcsArmored = WorldGen.arcs(#Nodes, Edges, oneWayOf, function(i: number): boolean
		return Edges[i].traffic
	end, function(i: number, forward: boolean): number
		-- additive penalties (seconds): a short detour around a station or a garage door is worth it, a 5x long
		-- run is not
		local c = timeCost(i, forward)
		if edgePoliceClear[i] < 250 then
			c += 30
		end
		if edgeDoorClear[i] < 300 then
			c += 20
		end
		return c
	end)

	type Route = {
		id: string,
		name: string,
		kind: string,
		stops: { Vector3 },
		path: { Vector3 },
		edges: { number },
		length: number,
		seconds: number,
		laps: number,
		policeClear: number?, -- armored: closest approach of the route to a police entrance (excluding the end)
		doorClear: number?, -- armored: closest approach to a garage door
	}
	local Routes: { Route } = {}
	local RouteErrors: { string } = {}
	WorldLayout.RouteErrors = RouteErrors

	local function addRoute(
		id: string,
		name: string,
		kind: string,
		stops: { Vector3 },
		laps: number,
		arcs: { { Arc } },
		usable: ((any) -> boolean)?,
		timeUnit: boolean
	): Route?
		local path: { Vector3 } = {}
		local edges: { number } = {}
		local length, seconds = 0, 0
		for i = 1, #stops - 1 do
			local leg = routeLeg(stops[i], stops[i + 1], arcs, usable, timeUnit)
			if leg == nil and kind == "race" then
				leg = routeLeg(stops[i], stops[i + 1], arcsDist, usable, false)
			end
			if leg == nil then
				table.insert(RouteErrors, ("%s: no path from stop %d to %d"):format(id, i, i + 1))
				continue
			end
			appendPts(path, leg.points)
			for _, ei in leg.edges do
				table.insert(edges, ei)
			end
			length += leg.length
			-- seconds on the real (unpenalised) graph
			for _, signed in leg.edges do
				local e = Edges[math.abs(signed)]
				seconds += e.length / math.max(e.speed, 5)
			end
		end
		local r: Route = {
			id = id,
			name = name,
			kind = kind,
			stops = stops,
			path = path,
			edges = edges,
			length = length,
			seconds = seconds,
			laps = laps,
		}
		table.insert(Routes, r)
		return r
	end

	local function poiStop(id: string): Vector3
		local p = poiById[id]
		assert(p, "missing POI " .. id)
		return p.entrance
	end
	local function trafficOnly(e: any): boolean
		return e.traffic
	end

	local depot = poiStop("ArmoredDepot")
	-- Pickup circuits: each truck collects from branches / stores and ends at the Pinnacle Reserve Bank or back at the
	-- Stackhouse depot, so the runs spread over the core instead of all leaving the depot past one garage.
	local armoredDefs: { { any } } = {
		{ "armored_a", "Stackhouse Run A (Downtown)", { depot, poiStop("BranchFoundry"), poiStop("Bank") } },
		{
			"armored_b",
			"Stackhouse Run B (Midtown & Beach)",
			{ poiStop("BranchBeach"), v(-4060, 300), poiStop("Jewelry"), poiStop("BranchMidtown"), poiStop("Bank") },
		},
		{ "armored_c", "Stackhouse Run C (Southgate)", { poiStop("BranchSouthgate"), poiStop("StoreSouthgate"), depot } },
		{ "armored_d", "Stackhouse Run D (Red Mesa)", { poiStop("BranchCactus"), poiStop("GasRust"), depot } },
		{
			"armored_e",
			"Stackhouse Run E (Sunwood)",
			{ poiStop("BranchSunwood"), v(-1100, -1500), v(-1100, -500), poiStop("Bank") },
		},
	}
	for _, d in armoredDefs do
		local r = addRoute(d[1], d[2], "armored", d[3], 1, arcsArmored, trafficOnly, true)
		if r then
			-- clearances along the path (the bank / branch stops themselves excluded: police may sit near a bank)
			local cp, cd = math.huge, math.huge
			for k, p in r.path do
				local nearStop = false
				for _, st in r.stops do
					if WorldGen.dist(st.X, st.Z, p.X, p.Z) < 150 then
						nearStop = true
						break
					end
				end
				if not nearStop or k == 1 then
					cp = math.min(cp, minDistTo(policeEntrances, p.X, p.Z))
				end
				cd = math.min(cd, minDistTo(doors, p.X, p.Z))
			end
			r.policeClear = cp
			r.doorClear = cd
		end
	end
	WorldLayout.ArmoredRules = {
		spawnMinPlayerDistance = 1000,
		stopPoliceClear = 400,
		routePoliceClear = 250,
		garageNearRun = 1500, -- every garage within this of at least one run
		runGarageClear = 600, -- no run passes closer than this to a garage door
		speed = 55,
		everySeconds = 300,
	}

	local function notFreeway(e: any): boolean
		return e.class ~= "freeway" and e.class ~= "ramp"
	end
	-- Races are planned on distance (the racing line), restricted to the classes each race uses.
	-- the downtown arterial rectangle: Liberty, Mission, Harbor, Crown (all two-way), 3 laps
	addRoute("race_downtown", "Downtown Sprint", "race", {
		v(-150, -200),
		v(-150, 600),
		v(-1050, 650),
		v(-1100, -300),
		v(-200, -250),
	}, 3, WorldGen.arcs(#Nodes, Edges, oneWayOf, function(i: number): boolean
		return notFreeway(Edges[i]) and Edges[i].class ~= "alley"
	end), function(e: any): boolean
		return notFreeway(e) and e.class ~= "alley"
	end, false)
	local function ringOnly(e: any): boolean
		return e.corridor == "H1 Ring Freeway"
	end
	addRoute(
		"race_ring",
		"Ring Run",
		"race",
		{ v(-1000, -1800), v(1650, 0), v(0, 1380), v(-3650, 0), v(-1000, -1800) },
		1,
		WorldGen.arcs(#Nodes, Edges, oneWayOf, function(i: number): boolean
			return ringOnly(Edges[i])
		end),
		ringOnly,
		false
	)
	addRoute("race_coast", "Coast Highway Loop", "race", {
		v(-150, -2142),
		v(-2700, -3000),
		v(1600, -4330),
		v(5650, -1500),
		v(5250, 2600),
		v(2450, 2760),
		v(-150, 2260),
		v(-150, -2142),
	}, 1, arcsDist, nil, false)
	addRoute(
		"race_canyon",
		"Sunwood Canyon Run",
		"race",
		{ v(-1500, -2170), v(-1500, -3120), v(-3150, -3200), v(-4440, -2160), v(-3600, -2140) },
		1,
		arcsDist,
		nil,
		false
	)
	do
		local CH = WorldTerrain.Channel
		local function chAt(z: number): Vector3
			local best, bx = math.huge, 0
			for _, p in CH.points do
				if math.abs(p.z - z) < best then
					best, bx = math.abs(p.z - z), p.x
				end
			end
			return Vector3.new(bx, 0, z)
		end
		local inChannel = function(e: any): boolean
			return e.class == "channel" or e.class == "service" or e.class == "street"
		end
		addRoute(
			"race_channel",
			"Channel Run",
			"race",
			{ v(2091, -1885), chAt(-1300), chAt(400), chAt(2100), v(2041, 2568) },
			1,
			WorldGen.arcs(#Nodes, Edges, oneWayOf, function(i: number): boolean
				return inChannel(Edges[i])
			end),
			inChannel,
			false
		)
	end
	addRoute("race_airport", "Airport Drag", "race", { v(-5250, 3330), v(-2850, 3330) }, 1, arcsDist, function(e: any): boolean
		return e.class == "runway"
	end, false)
	addRoute(
		"race_mesa",
		"Red Mesa Rally",
		"race",
		{ v(3000, -330), v(4330, -560), v(4200, 2100), v(4650, 3300), v(5600, 1600), v(5620, -680), v(4330, -560) },
		1,
		arcsDist,
		nil,
		false
	)
	WorldLayout.Routes = Routes

	-- ETA fields (seconds from every node to each Hot Drop zone / armored stop): EventService picks the zone with the
	-- tightest ETA spread across active players (gameplay critique 5). Garages within 60 s at 100 studs/s (road
	-- distance <= 6,000) are counted per drop for the normal pool test.
	local EtaFields: { [string]: { number } } = {}
	for _, hd in WorldLayout.HotDrops do
		local p = hd.cframe.Position
		local field = fieldTo(p, true)
		local rounded = table.create(#field, 0)
		for i, x in field do
			rounded[i] = if x == math.huge then -1 else math.floor(x * 10 + 0.5) / 10
		end
		EtaFields[hd.id] = rounded
		local dfield = fieldTo(p, false)
		local n = 0
		for _, plot in Plots do
			if costFrom(dfield, plot.door, false) <= 6000 then
				n += 1
			end
		end
		hd.garagesWithin60s = n
	end
	for _, r in Routes do
		if r.kind == "armored" then
			for k, st in r.stops do
				local key = r.id .. "_" .. k
				if not EtaFields[key] then
					local field = fieldTo(st, true)
					local rounded = table.create(#field, 0)
					for i, x in field do
						rounded[i] = if x == math.huge then -1 else math.floor(x * 10 + 0.5) / 10
					end
					EtaFields[key] = rounded
				end
			end
		end
	end
	WorldLayout.EtaFields = EtaFields

	---------------------------------------------------------------------------------------------------------------------
	-- 18. Roadblock anchors, the Harbor lift bridge, heist drop-offs, car swaps (gameplay critiques 10, 11)
	---------------------------------------------------------------------------------------------------------------------

	type Roadblock = {
		id: number,
		kind: string, -- straight | bridge | terminal | interchange | pass
		edge: number,
		s: number,
		cframe: CFrame, -- centerline, LookVector along a -> b
		width: number,
		lanes: number,
		trap: boolean, -- the port bridges: blocking one leaves a single way off the island
	}
	local Roadblocks: { Roadblock } = {}
	local BLOCK_CLASSES: { [string]: boolean } = { avenue = true, boulevard = true, highway = true, freeway = true }
	local PORT_TRAP: { [string]: boolean } = {
		["Harbor Avenue"] = true,
		["H2 Port Expressway (southbound)"] = true,
		["H2 Port Expressway (northbound)"] = true,
	}
	local function addBlock(kind: string, ei: number, s: number)
		local e = Edges[ei]
		local px, py, pz, tx, tz = edgeAt(ei, s)
		local pos = Vector3.new(px, py, pz)
		table.insert(Roadblocks, {
			id = #Roadblocks + 1,
			kind = kind,
			edge = ei,
			s = s,
			cframe = CFrame.lookAt(pos, pos + Vector3.new(tx, 0, tz)),
			width = e.width,
			lanes = e.lanesF + e.lanesB,
			trap = PORT_TRAP[e.name] == true and kind == "bridge",
		})
	end
	for ei, e in Edges do
		if BLOCK_CLASSES[e.class] then
			local lo = nodeRadius(e.a) + 120
			local hi = e.length - nodeRadius(e.b) - 120
			local s = lo + 300
			while s <= hi do
				-- straight: heading within 8 degrees over +-60
				local _, _, _, ax, az = edgeAt(ei, s - 60)
				local _, _, _, bx, bz = edgeAt(ei, s + 60)
				if ax * bx + az * bz > math.cos(math.rad(8)) and not onBridge(ei, s, 20) then
					addBlock("straight", ei, s)
					s += 600
				else
					s += 60
				end
			end
		end
		for _, sp in e.spans do
			if e.class ~= "dirt" and e.class ~= "service" and sp[2] - sp[1] > 60 then
				addBlock("bridge", ei, math.max(0, sp[1] - 25))
				addBlock("bridge", ei, math.min(e.length, sp[2] + 25))
			end
		end
	end
	-- diamond terminals: the ground end of every ramp, 40 studs up the ramp
	for ei, e in Edges do
		if e.class == "ramp" then
			for _, endNode in { e.a, e.b } do
				local n = Nodes[endNode]
				if math.abs(n.pos.Y - gradeAt(n.pos.X, n.pos.Z)) < 3 and n.intersection then
					addBlock("terminal", ei, if endNode == e.a then math.min(40, e.length / 2) else math.max(0, e.length - 40))
				end
			end
		end
	end
	-- named chokepoints
	for _, cp in { { "H9 Sunwood Freeway (northbound)", 0.95, "pass" }, { "H9 Sunwood Freeway (southbound)", 0.05, "pass" } } do
		local ei = c2.edgeNamed(cp[1])
		if ei then
			addBlock(cp[3], ei, Edges[ei].length * cp[2])
		end
	end
	do
		local best: number?, bestS, bestD = nil, 0, math.huge
		for ei, e in Edges do
			if e.name == "Coast Highway" then
				local d, s = WorldGen.polyProject(edgePts[ei].pts, 1540, -4560)
				if d < bestD then
					best, bestS, bestD = ei, s, d
				end
			end
		end
		if best then
			addBlock("pass", best, bestS)
		end
	end
	WorldLayout.Roadblocks = Roadblocks

	-- Harbor lift bridge: a server-clock event (raised 25 s every ~4 min); the gap is a timed jump.
	do
		local lift = nil
		for _, l in WorldLayout.Landmarks do
			if l.id == "HarborBridge" then
				lift = l
			end
		end
		if lift and lift.edge then
			WorldLayout.LiftBridge = {
				edge = lift.edge,
				span = lift.span,
				cframe = lift.cframe,
				period = 240,
				raised = 25,
				gap = 40,
				leafAngle = 70,
				note = "both leaves rise for 25 s every 4 min; at speed the gap is jumpable while they rise",
			}
		end
	end

	-- Heist drop-offs (one per planned exit) and car swaps (gameplay critique 11).
	local bank = poiById.Bank
	local bankField = if bank then fieldTo(bank.entrance, false) else nil
	type Spot = { id: string, name: string, cframe: CFrame, roadFromBank: number?, note: string? }
	local HeistDropoffs: { Spot } = {}
	for _, d in
		{
			{ "heist_north", "Hidden Cove pull-out", -2700, -3800 },
			{ "heist_east", "Rail Yard siding", 2900, 1350 },
			{ "heist_south", "South shore wharf", -1500, 2850 },
		}
	do
		local ei, s = snap(d[3], d[4], function(e: any): boolean
			return e.layer == 0 and not e.elevated and e.class ~= "channel"
		end, 800)
		if ei then
			local px, py, pz, tx, tz = edgeAt(ei, s)
			local pos = Vector3.new(px, py, pz)
			local spot: Spot = {
				id = d[1],
				name = d[2],
				cframe = CFrame.lookAt(pos, pos + Vector3.new(tx, 0, tz)),
			}
			if bankField then
				local ff = bankField :: { number }
				-- distance from the bank to the drop-off = field from the drop-off back to the bank (roads are
				-- near-symmetric); good enough for a metric
				spot.roadFromBank = math.floor(costFrom(ff, pos, false))
			end
			table.insert(HeistDropoffs, spot)
		end
	end
	WorldLayout.HeistDropoffs = HeistDropoffs

	local CarSwaps: { Spot } = {}
	do
		local used: { [number]: boolean } = {}
		for _, t in
			{
				{ "swap_ring", "Under the Ring lot", 760, 1460 },
				{ "swap_midtown", "Midtown parking garage", -2500, -1500 },
				{ "swap_foundry", "Foundry surface lot", 2800, -900 },
				{ "swap_beach", "Palmera beach lot", -4200, -500 },
			}
		do
			local best: any = nil
			local bestD = 900
			for _, p in Parcels do
				if (p.use == "parking_lot" or p.use == "parking_garage") and not used[p.id] then
					local d = WorldGen.dist(p.cframe.Position.X, p.cframe.Position.Z, t[3], t[4])
					if d < bestD then
						best, bestD = p, d
					end
				end
			end
			if best then
				used[best.id] = true
				table.insert(CarSwaps, {
					id = t[1],
					name = t[2],
					cframe = best.cframe + Vector3.new(0, if best.use == "parking_garage" then 0 else 0.5, 0),
					note = best.use .. " lot " .. best.id,
				})
			end
		end
	end
	WorldLayout.CarSwaps = CarSwaps

	---------------------------------------------------------------------------------------------------------------------
	-- 19. Per-plot service metrics (road studs) + onboarding order (gameplay critiques 1, 8, 12)
	---------------------------------------------------------------------------------------------------------------------

	local kindFields: { [string]: { { number } } } = {}
	local function nearestOfKind(kind: string, from: Vector3): (number, string?)
		local list = kindFields[kind]
		if not list then
			list = {}
			for _, p in POIs do
				if p.kind == kind then
					local f = fieldTo(p.entrance, false)
					table.insert(list, f)
					;(f :: any).id = p.id
				end
			end
			kindFields[kind] = list
		end
		local best, bestId = math.huge, nil
		for _, f in list do
			local c = costFrom(f, from, false)
			if c < best then
				best, bestId = c, (f :: any).id
			end
		end
		return best, bestId
	end
	local onRampField = (function(): { number }
		-- seconds to the nearest on-ramp terminal (multi-goal reverse Dijkstra)
		local goals: { [number]: number } = {}
		for _, e in Edges do
			if e.class == "ramp" then
				local n = Nodes[e.a]
				if math.abs(n.pos.Y - gradeAt(n.pos.X, n.pos.Z)) < 3 then
					goals[e.a] = 0
				end
			end
		end
		local dist = WorldGen.dijkstra(#Nodes, revAll, goals)
		return dist
	end)()
	for _, plot in Plots do
		local svc: { [string]: number } = {}
		for _, kind in { "police", "gunshop", "spray", "chop", "dealership", "hospital", "customs" } do
			local d = nearestOfKind(kind, plot.door)
			svc[kind] = math.floor(d)
		end
		plot.service = svc
		plot.onRampSeconds = math.floor(costFrom(onRampField, plot.door, true) * 10 + 0.5) / 10
		local ok = svc.dealership <= 3000 and svc.gunshop <= 1500 and svc.police >= 800
		-- onboarding score: lower is better (dealer + 2 x gun distance, police too close penalised)
		plot.onboardingOk = ok
		plot.onboardingScore = svc.dealership + 2 * svc.gunshop + (if svc.police < 800 then 5000 else 0)
	end
	local order: { number } = {}
	for i = 1, #Plots do
		table.insert(order, i)
	end
	table.sort(order, function(a: number, b: number): boolean
		local pa, pb = Plots[a], Plots[b]
		if pa.onboardingOk ~= pb.onboardingOk then
			return pa.onboardingOk
		end
		if pa.onboardingScore ~= pb.onboardingScore then
			return pa.onboardingScore < pb.onboardingScore
		end
		return a < b
	end)
	WorldLayout.OnboardingOrder = order

	---------------------------------------------------------------------------------------------------------------------
	-- 20. Streetscape (gta critique 4): explicit, deterministic placements the builder instances.
	--     lamp   cobra-head on a pole at the curb, arm over the road (yaw = facing the road); light = carries a light
	--     palm   Washingtonia fan palm (sidewalk curbside or boulevard median); h = height
	--     tree   street tree (downtown / midtown / foundry sidewalks)
	--     pole   wooden utility pole (suburbs, industry, desert town, Coast Highway); wires run pole to pole
	--     billboard  slot facing a freeway deck or an arterial; size = { w, h, raise }
	--     busstop, hydrant, bin
	---------------------------------------------------------------------------------------------------------------------

	type Place = {
		kind: string,
		pos: Vector3,
		yaw: number,
		edge: number,
		h: number?,
		light: boolean?,
		run: number?,
		median: boolean?,
	}
	local Streetscape: { [string]: { Place } } = {
		lamp = {},
		palm = {},
		tree = {},
		pole = {},
		billboard = {},
		busstop = {},
		hydrant = {},
		bin = {},
		freeway_lamp = {},
	}
	for _, b in busStops do
		table.insert(Streetscape.busstop, { kind = "busstop", pos = b.pos, yaw = b.yaw, edge = b.edge })
	end

	local PALM_ROADS: { [string]: boolean } = {
		["Palmera Drive"] = true,
		["Gilded Mile"] = true,
		["Sunwood Boulevard"] = true,
		["Liberty Avenue"] = true,
		["Airport Boulevard"] = true,
		["Terminal Drive"] = true,
		["HCI Departures"] = true,
	}
	local TREE_DISTRICTS: { [string]: boolean } = { downtown = true, midtown = true, foundry = true }
	local POLE_DISTRICTS: { [string]: boolean } =
		{ southgate = true, rust = true, cactus = true, driftwood = true, mesa = true, airport = false }
	local LAMP_SPACING: { [string]: number } = {
		downtown = 95,
		midtown = 105,
		beach = 105,
		foundry = 115,
		southgate = 135,
		rust = 150,
		port = 140,
		airport = 120,
		hills = 160,
		cactus = 140,
		driftwood = 150,
		mesa = 180,
	}
	-- spatial occupancy so items never stack (lamp vs palm vs bus stop vs hydrant), 6-stud radius
	local occCells: { [number]: { { number } } } = {}
	local function occupied(x: number, z: number, r: number): boolean
		local cx, cz = math.floor(x / 32), math.floor(z / 32)
		for dx = -1, 1 do
			for dz = -1, 1 do
				local list = occCells[WorldGen.cellKey(cx + dx, cz + dz)]
				if list then
					for _, q in list do
						if (q[1] - x) ^ 2 + (q[2] - z) ^ 2 < r * r then
							return true
						end
					end
				end
			end
		end
		return false
	end
	local function occupy(x: number, z: number)
		local key = WorldGen.cellKey(math.floor(x / 32), math.floor(z / 32))
		local list = occCells[key]
		if not list then
			list = {}
			occCells[key] = list
		end
		table.insert(list, { x, z })
	end
	for _, b in busStops do
		occupy(b.pos.X, b.pos.Z)
	end

	-- the point on edge ei at s, offset `off` to side `side`, if it is clear of junctions / driveways / lots
	local function curbPoint(ei: number, s: number, side: number, off: number, clearR: number): (Vector3?, number, number)
		local e = Edges[ei]
		local lo, hi = nodeRadius(e.a) + 8, e.length - nodeRadius(e.b) - 8
		if s < lo or s > hi then
			return nil, 0, 0
		end
		local px, py, pz, tx, tz = edgeAt(ei, s)
		local rx, rz = WorldGen.right(tx, tz)
		local x, z = px + rx * off * side, pz + rz * off * side
		if nearAvoid(x, z) or occupied(x, z, clearR) then
			return nil, 0, 0
		end
		-- not on any other road's asphalt (+ 2) or its own (corner overlaps, crossing streets, merging ramps)
		local blocked = false
		WorldGen.segQuery(roadSegs, x, z, 0, function(id: number)
			if blocked then
				return
			end
			local oi = roadSegs.owner[id]
			local o = Edges[oi]
			if o.elevated and o.layer > 0 then
				return
			end
			local _, _, _, d =
				WorldGen.projectSeg(x, z, roadSegs.ax[id], roadSegs.az[id], roadSegs.bx[id], roadSegs.bz[id])
			if d < o.width / 2 + (if oi == ei then 0.5 else 2) then
				blocked = true
			end
		end)
		if blocked then
			return nil, 0, 0
		end
		local y = if e.sidewalk > 0 then py + S.CURB_HEIGHT else math.max(py, heightAt(x, z))
		return Vector3.new(x, y, z), -rx * side, -rz * side
	end

	for ei, e in Edges do
		if e.layer ~= 0 or e.elevated then
			continue
		end
		local d = districtAt(edgePts[ei].pts[1].x, edgePts[ei].pts[1].z)
		local mid = math.floor(#edgePts[ei].pts / 2) + 1
		d = districtAt(edgePts[ei].pts[mid].x, edgePts[ei].pts[mid].z)
		local hasWalk = e.sidewalk > 0
		local cls = e.class
		local major = cls == "avenue" or cls == "boulevard"
		local roadOk = cls == "street" or major or cls == "highway" or cls == "rural"
		if not roadOk then
			continue
		end
		-- lamps: sidewalk roads (both sides on majors, alternating on streets), highways near towns
		local spacing = LAMP_SPACING[d] or 140
		if hasWalk or (cls == "highway" and d ~= "mesa") then
			local off = if hasWalk then e.width / 2 + 1.6 else e.width / 2 + 4
			local s = nodeRadius(e.a) + 14 + spacing * 0.35 * WorldGen.hash(ei, 1, 992)
			local k = 0
			while s < e.length - nodeRadius(e.b) - 8 do
				k += 1
				local sides: { number } = if major then { 1, -1 } else { if k % 2 == 0 then 1 else -1 }
				for _, side in sides do
					local p, fx, fz = curbPoint(ei, s + (if side < 0 and major then spacing / 2 else 0), side, off, 10)
					if p then
						occupy(p.X, p.Z)
						table.insert(Streetscape.lamp, {
							kind = "lamp",
							pos = p,
							yaw = yawOf(fx, fz),
							edge = ei,
							h = if major then 30 else 26,
							light = (k + (if side > 0 then 0 else 1)) % 2 == 0 or major,
						})
					end
				end
				s += spacing
			end
		end
		-- palms: the LA boulevards (sidewalk curbside, both sides), + medians wide enough
		if PALM_ROADS[e.name] and d ~= "hills" or (e.name == "Crown Boulevard" and e.points[1].X < -1240) then
			local off = e.width / 2 + 3.2
			local s = nodeRadius(e.a) + 20 + 20 * WorldGen.hash(ei, 2, 992)
			local k = 0
			while s < e.length - nodeRadius(e.b) - 10 do
				k += 1
				for _, side in { 1, -1 } do
					local p = curbPoint(ei, s, side, if hasWalk then off else e.width / 2 + 8, 7)
					if p then
						occupy(p.X, p.Z)
						table.insert(Streetscape.palm, {
							kind = "palm",
							pos = p,
							yaw = 360 * WorldGen.hash(ei, k * 2 + side, 993),
							edge = ei,
							h = 65 + 35 * WorldGen.hash(ei, k, 994),
						})
					end
				end
				if e.median >= 8 then
					local px, py, pz = edgeAt(ei, s + 20)
					if not occupied(px, pz, 8) and not onBridge(ei, s + 20, 10) then
						occupy(px, pz)
						table.insert(Streetscape.palm, {
							kind = "palm",
							pos = Vector3.new(px, py + S.CURB_HEIGHT, pz),
							yaw = 360 * WorldGen.hash(ei, k, 995),
							edge = ei,
							h = 70 + 30 * WorldGen.hash(ei, k, 996),
							median = true,
						})
					end
				end
				s += 40
			end
		elseif hasWalk and TREE_DISTRICTS[d] and (cls == "street" or major) then
			-- street trees every ~60 in the dense districts (staggered against the lamps)
			local off = e.width / 2 + 3.2
			local s = nodeRadius(e.a) + 30 + 25 * WorldGen.hash(ei, 3, 992)
			local k = 0
			while s < e.length - nodeRadius(e.b) - 12 do
				k += 1
				for _, side in { 1, -1 } do
					if WorldGen.hash(ei, k * 2 + side, 997) < 0.82 then
						local p = curbPoint(ei, s, side, off, 8)
						if p then
							occupy(p.X, p.Z)
							table.insert(Streetscape.tree, {
								kind = "tree",
								pos = p,
								yaw = 360 * WorldGen.hash(ei, k, 998),
								edge = ei,
								h = 22 + 10 * WorldGen.hash(ei, k, 999),
							})
						end
					end
				end
				s += 62
			end
		end
		-- utility poles: one side, every ~130, in the suburbs / industry / desert, and along the Coast Highway
		if POLE_DISTRICTS[d] and (cls == "street" or cls == "rural" or cls == "highway" or major) and not PALM_ROADS[e.name] then
			local side = if WorldGen.hash(ei, 4, 992) < 0.5 then 1 else -1
			local off = if hasWalk then e.width / 2 + e.sidewalk - 1.5 else e.width / 2 + 7
			local s = nodeRadius(e.a) + 20 + 40 * WorldGen.hash(ei, 5, 992)
			local run = ei
			while s < e.length - nodeRadius(e.b) - 10 do
				local p, fx, fz = curbPoint(ei, s, side, off, 8)
				if p then
					occupy(p.X, p.Z)
					table.insert(Streetscape.pole, {
						kind = "pole",
						pos = p,
						yaw = yawOf(fx, fz),
						edge = ei,
						h = 45,
						run = run,
					})
				end
				s += 130
			end
		end
	end

	-- freeway lights on the median barrier of the H1 and the spurs, every 120 (one carriageway carries them)
	for ei, e in Edges do
		local carrier = e.name:find("(clockwise)", 1, true)
			or e.name:find("(northbound)", 1, true)
			or e.name:find("(eastbound)", 1, true)
		if e.class == "freeway" and e.corridor and carrier then
			local s = 30
			while s < e.length - 30 do
				local px, py, pz, tx, tz = edgeAt(ei, s)
				local rx, rz = WorldGen.right(tx, tz)
				-- inside (left) edge of this carriageway = the median
				local off = -(e.width / 2 + S.CARRIAGEWAY_GAP / 2)
				table.insert(Streetscape.freeway_lamp, {
					kind = "freeway_lamp",
					pos = Vector3.new(px + rx * off, py, pz + rz * off),
					yaw = yawOf(tx, tz),
					edge = ei,
					h = 34,
					light = math.floor(s / 120) % 2 == 0,
				})
				s += 120
			end
		end
	end

	-- hydrants and bins at signal / all-way junction corners (one of each per junction)
	for _, it in Intersections do
		if it.control ~= "signal" and it.control ~= "allway" then
			continue
		end
		local placed = 0
		for _, a in it.approaches do
			local e = Edges[a.edge]
			if e.sidewalk <= 0 or e.layer ~= 0 or placed >= 2 then
				continue
			end
			local fromA = e.a == it.node
			local s = if fromA then it.radius + 10 else e.length - it.radius - 10
			local side = if fromA then 1 else -1
			local p = curbPoint(a.edge, s, side, e.width / 2 + 2.2, 6)
			if p then
				occupy(p.X, p.Z)
				placed += 1
				table.insert(if placed == 1 then Streetscape.hydrant else Streetscape.bin, {
					kind = if placed == 1 then "hydrant" else "bin",
					pos = p,
					yaw = 0,
					edge = a.edge,
				})
			end
		end
	end

	-- billboards: slots facing the H1 / spur decks (60-140 studs out, not on roads or lots), every ~500 per side
	do
		local n = 0
		for ei, e in Edges do
			if e.class ~= "freeway" then
				continue
			end
			local s = 200 + 150 * WorldGen.hash(ei, 6, 992)
			while s < e.length - 100 do
				local px, py, pz, tx, tz = edgeAt(ei, s)
				local rx, rz = WorldGen.right(tx, tz)
				for _, dist in { 70, 95, 120 } do
					local x, z = px + rx * (e.width / 2 + dist), pz + rz * (e.width / 2 + dist)
					local g = gradeAt(x, z)
					if
						landAtLeast(x, z, 20)
						and not roadClearance(x, z, 6, true)
						and not boxAt(x, g + 2, z, 6)
						and not c2.inNoLot(x, z)
						and not occupied(x, z, 40)
					then
						occupy(x, z)
						n += 1
						-- face back toward the oncoming traffic (angled 25 degrees toward the deck)
						local fx, fz = -tx * 0.9 - rx * 0.42, -tz * 0.9 - rz * 0.42
						table.insert(Streetscape.billboard, {
							kind = "billboard",
							pos = Vector3.new(x, g, z),
							yaw = yawOf(fx, fz),
							edge = ei,
							h = math.max(py + 18 - g, 40), -- the panel bottom sits above the deck
							run = n,
						})
						break
					end
				end
				s += 520
			end
		end
	end
	WorldLayout.Streetscape = Streetscape

	---------------------------------------------------------------------------------------------------------------------
	-- 21. Rails, pedestrian paths, bridges, level crossings
	---------------------------------------------------------------------------------------------------------------------

	local function v3list(list: { { number } }, r: number?): { Vector3 }
		local out: { Vector3 } = {}
		for _, p in WorldGen.fillet(poly(list), r or 600, nil, 40) do
			table.insert(out, Vector3.new(p.x, gradeAt(p.x, p.z), p.z))
		end
		return out
	end

	WorldLayout.Rails = {
		{ name = "Rail Yard (8 tracks)", points = v3list({ { 2340, 1350 }, { 3690, 1350 } }), tracks = 8, spacing = 18 },
		{
			name = "Red Mesa Freight Line",
			points = v3list({
				{ 3690, 1350 },
				{ 4100, 1150 },
				{ 4700, 300 },
				{ 5150, -800 },
				{ 5300, -2000 },
				{ 5000, -3300 },
				{ 4300, -3800 },
			}),
			tracks = 1,
			spacing = 0,
		},
	}

	-- boardwalk: 60+ inland of the waterline, west of Palmera Drive
	local boardwalk: { { number } } = {}
	do
		local z = -2000
		while z <= 1600 do
			local x = -5000
			while not landAtLeast(x, z, 70) and x < -4650 do
				x += 10
			end
			table.insert(boardwalk, { math.min(x, -4660), z })
			z += 200
		end
	end
	local echo = { -1750, 1870 }
	local plazaPoi = poiById.HotwirePlaza
	local plazaLoop: { { number } } = {}
	if plazaPoi then
		local cf, sz = plazaPoi.cframe, plazaPoi.size
		for _, c in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 }, { -1, -1 } } do
			local p = cf * Vector3.new(c[1] * (sz.X / 2 - 30), 0, c[2] * (sz.Z / 2 - 30))
			table.insert(plazaLoop, { p.X, p.Z })
		end
	end
	WorldLayout.Paths = {
		{ name = "Palmera Boardwalk", kind = "boardwalk", width = 26, points = v3list(boardwalk, 300) },
		{
			name = "Palmera Palm Park",
			kind = "park",
			width = 14,
			points = v3list({ { -4600, -1900 }, { -4610, -1000 }, { -4610, 0 }, { -4605, 1500 } }),
		},
		{
			name = "Echo Park Loop",
			kind = "park",
			width = 10,
			points = v3list({
				{ echo[1] - 260, echo[2] - 150 },
				{ echo[1] + 260, echo[2] - 150 },
				{ echo[1] + 260, echo[2] + 150 },
				{ echo[1] - 260, echo[2] + 150 },
				{ echo[1] - 260, echo[2] - 150 },
			}, 60),
		},
		{ name = "Hotwire Plaza", kind = "plaza", width = 30, points = v3list(plazaLoop, 30) },
		{
			name = "Starview Trail",
			kind = "trail",
			width = 6,
			points = v3list({ { -1450, -2760 }, { -1000, -2900 }, { -520, -3080 } }, 200),
		},
	}

	local landmarkByEdge: { [number]: any } = {}
	for _, l in WorldLayout.Landmarks do
		if l.edge then
			landmarkByEdge[l.edge] = l
		end
	end
	local Bridges = {}
	for _, e in Edges do
		if e.bridge then
			local lmk = landmarkByEdge[e.id]
			local kind = if lmk
				then lmk.kind
				elseif e.layer >= 1 or e.class == "freeway" or e.class == "ramp" then "deck"
				else "girder"
			table.insert(Bridges, { edge = e.id, name = e.name, spans = e.spans, kind = kind })
		end
	end
	-- the H2's cable-stayed bridge spans both carriageways: mark the northbound one too
	for _, b in Bridges do
		if b.name == "H2 Port Expressway (northbound)" then
			b.kind = "bridge_cable"
		end
	end
	WorldLayout.Bridges = Bridges

	local LevelCrossings = {}
	for _, rail in WorldLayout.Rails do
		for k = 1, #rail.points - 1 do
			local a, b = rail.points[k], rail.points[k + 1]
			local seenEdge: { [number]: boolean } = {}
			local mx, mz = (a.X + b.X) / 2, (a.Z + b.Z) / 2
			local r = (Vector3.new(b.X, 0, b.Z) - Vector3.new(a.X, 0, a.Z)).Magnitude / 2 + 1
			WorldGen.segQuery(roadSegs, mx, mz, r, function(id: number)
				local ei = roadSegs.owner[id]
				local e = Edges[ei]
				if e.layer ~= 0 or e.elevated then
					return
				end
				local t = WorldGen.segIntersect(
					a.X,
					a.Z,
					b.X,
					b.Z,
					roadSegs.ax[id],
					roadSegs.az[id],
					roadSegs.bx[id],
					roadSegs.bz[id],
					0
				)
				if t and not seenEdge[ei] then
					seenEdge[ei] = true
					table.insert(LevelCrossings, { rail = rail.name, edge = ei, pos = a:Lerp(b, t) })
				end
			end)
		end
	end
	WorldLayout.LevelCrossings = LevelCrossings

	---------------------------------------------------------------------------------------------------------------------
	-- 22. Districts export + stats
	---------------------------------------------------------------------------------------------------------------------

	local Districts = {}
	for _, d in ctx.DISTRICTS do
		local pts: { Vector3 } = {}
		for _, p in d.poly do
			table.insert(pts, Vector3.new(p.x, 0, p.z))
		end
		table.insert(Districts, {
			id = d.id,
			name = d.name,
			style = d.style,
			materials = d.materials,
			polygon = pts,
			priority = d.priority,
			height = d.height,
			peak = d.peak,
			density = d.density,
			heat = d.heat,
			carTier = d.carTier,
			color = d.color,
			lot = d.lot,
			sidewalk = d.sidewalk,
		})
	end
	WorldLayout.Districts = Districts

	local roadLength = 0
	local signals = 0
	for _, e in Edges do
		roadLength += e.length
	end
	for _, i in Intersections do
		if i.control == "signal" then
			signals += 1
		end
	end
	local tiers: { [string]: number } = {}
	for _, sp in parking do
		tiers[sp.tier] = (tiers[sp.tier] or 0) + 1
	end
	for _, sp in offstreet do
		tiers[sp.tier] = (tiers[sp.tier] or 0) + 1
	end
	local counts: { [string]: number } = {}
	for k, list in Streetscape do
		counts[k] = #list
	end
	WorldLayout.Stats = {
		nodes = #Nodes,
		edges = #Edges,
		intersections = #Intersections,
		signals = signals,
		parcels = #Parcels,
		pois = #POIs,
		parking = #parking,
		offstreet = #offstreet,
		roadLength = roadLength,
		droppedEdges = #WorldLayout.DroppedEdges,
		tiers = tiers,
		streetscape = counts,
		roadblocks = #Roadblocks,
		routes = #Routes,
	}
	local _ = inRestricted
end
