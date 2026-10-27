--!nocheck
-- RoadGraph: graph construction from the layout, connectivity, A* route validity (every point and every segment on
-- asphalt), determinism, one-way handling, T-junction splitting and route performance.
return function(t)
	local H = t.H
	local Vector3 = H.roblox.Vector3
	local RoadGraph = H.require("src/shared/Util/RoadGraph")
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local MapConfig = H.require("src/shared/Config/Map")
	local S = MapConfig.GRID_SPACING
	local lines = MapConfig.LINE_MAX - MapConfig.LINE_MIN + 1

	local graph = RoadGraph.build()

	-- every point along a polyline (sampled every 4 studs) is on asphalt
	local function assertOnRoad(points, label)
		for i = 1, #points do
			t.ok(MapLayout.isOnRoad(points[i]), ("%s: point %d off road %s"):format(label, i, tostring(points[i])))
			if i > 1 then
				local a, b = points[i - 1], points[i]
				local len = (b - a).Magnitude
				local steps = math.max(1, math.ceil(len / 4))
				for k = 1, steps - 1 do
					local p = a:Lerp(b, k / steps)
					t.ok(
						MapLayout.isOnRoad(p),
						("%s: segment %d leaves the road at %s"):format(label, i - 1, tostring(p))
					)
				end
			end
		end
	end

	-- a road point: random line, random position along it
	local function randomRoadPoint(rng)
		local line = rng:NextInteger(MapConfig.LINE_MIN, MapConfig.LINE_MAX)
		local along = rng:NextNumber(-MapConfig.HALF_EXTENT, MapConfig.HALF_EXTENT)
		local lateral = rng:NextNumber(-MapConfig.ROAD_WIDTH / 2 + 1, MapConfig.ROAD_WIDTH / 2 - 1)
		if rng:NextNumber() < 0.5 then
			return Vector3.new(along, MapConfig.ROAD_Y, line * S + lateral)
		end
		return Vector3.new(line * S + lateral, MapConfig.ROAD_Y, along)
	end

	t.test("grid layout: one node per intersection, one edge per block side", function()
		local nodes, edges = graph:stats()
		t.eq(nodes, lines * lines, "nodes")
		t.eq(edges, 2 * lines * (lines - 1), "edges")
		for _, e in graph.edges do
			t.near(e.length, S, 1e-3, "edge length")
			t.ok(not e.oneWay, "grid roads are two-way")
			t.eq(e.width, MapConfig.ROAD_WIDTH, "width")
		end
	end)

	t.test("road classes: ring highway, avenues, streets", function()
		t.eq(RoadGraph.gridClass(MapConfig.LINE_MIN), "highway")
		t.eq(RoadGraph.gridClass(MapConfig.LINE_MAX), "highway")
		t.eq(RoadGraph.gridClass(0), "avenue")
		t.eq(RoadGraph.gridClass(1), "street")
		local counts = {}
		for _, e in graph.edges do
			counts[e.class] = (counts[e.class] or 0) + 1
		end
		t.ok((counts.highway or 0) > 0 and (counts.avenue or 0) > 0 and (counts.street or 0) > 0, "all classes used")
	end)

	t.test("graph is connected (BFS from node 1 reaches every node)", function()
		local seen, queue, head = { [1] = true }, { 1 }, 1
		while head <= #queue do
			local n = queue[head]
			head += 1
			for _, arc in graph.adj[n] do
				local e = graph.edges[math.abs(arc)]
				local nxt = if arc > 0 then e.b else e.a
				if not seen[nxt] then
					seen[nxt] = true
					table.insert(queue, nxt)
				end
			end
		end
		t.eq(#queue, #graph.nodes, "reachable nodes")
	end)

	t.test("nodes sit on intersections and on asphalt", function()
		for _, p in graph.nodes do
			t.ok(MapLayout.isOnRoad(p), "node off road " .. tostring(p))
			t.near(p.X / S, math.round(p.X / S), 1e-9, "node x on a grid line")
			t.near(p.Z / S, math.round(p.Z / S), 1e-9, "node z on a grid line")
		end
	end)

	t.test("nearestNode / nearestPoint", function()
		local idx, pos = graph:nearestNode(Vector3.new(170, 5, -150))
		t.ok(idx ~= nil, "found")
		t.eq(pos, Vector3.new(160, MapConfig.ROAD_Y, -160), "nearest intersection")
		local p, e, tt, d = graph:nearestPoint(Vector3.new(75, 3, 12))
		t.ok(p and e and tt and d, "projection")
		t.near(p.X, 75, 1e-6, "projects straight down onto the X road")
		t.near(p.Z, 0, 1e-6, "on the centerline")
		-- module-level helpers use the cached layout graph
		local i2 = RoadGraph.nearestNode(Vector3.new(-805, 0, 790))
		t.eq(graph.nodes[i2], Vector3.new(-800, 0, 800), "corner of the ring road")
		-- far out at sea still snaps onto the ring road
		local far = RoadGraph.nearestPoint(Vector3.new(3000, 0, 20))
		t.near(far.X, 800, 1e-6, "far point snaps to the ring")
	end)

	t.test("route along one road is a straight 2-point line", function()
		local a = Vector3.new(-300, 0, 160)
		local b = Vector3.new(250, 0, 158)
		local r = graph:route(a, b)
		t.ok(r ~= nil, "route")
		t.eq(#r, 2, "straight")
		t.near(RoadGraph.routeLength(r), 550, 1e-3, "length")
		assertOnRoad(r, "straight")
	end)

	t.test("route length is the Manhattan distance on a full grid", function()
		local a = Vector3.new(-480, 0, -400) -- on Z road x=-480
		local b = Vector3.new(330, 0, 480) -- on X road z=480
		local r = graph:route(a, b)
		t.ok(r ~= nil, "route")
		local expected = math.abs(-480 - 330) + math.abs(-400 - 480)
		t.near(RoadGraph.routeLength(r), expected, 1e-3, "manhattan length")
		assertOnRoad(r, "manhattan")
		t.near(r[1].X, -480, 1e-6, "starts on the road at the start")
		t.near(r[#r].Z, 480, 1e-6, "ends on the road at the target")
	end)

	t.test("off-road endpoints snap to the nearest road (garage drop-off)", function()
		for i = 1, MapLayout.plotCount() do
			local cf = MapLayout.plotDropoffZone(i)
			local spawn = MapLayout.spawnCFrame().Position
			local r = graph:route(spawn, cf.Position)
			t.ok(r ~= nil and #r >= 2, "route to plot " .. i)
			assertOnRoad(r, "plot " .. i)
			-- the last point is the road spot right in front of the garage door
			local d = (Vector3.new(r[#r].X, 0, r[#r].Z) - Vector3.new(cf.Position.X, 0, cf.Position.Z)).Magnitude
			t.ok(d < S * 0.5, ("plot %d: route ends %.1f studs from the drop-off"):format(i, d))
		end
	end)

	t.test("200 random road-to-road routes exist, lie on roads and are deterministic", function()
		local rng = H.Random.new(1234)
		for k = 1, 200 do
			local a, b = randomRoadPoint(rng), randomRoadPoint(rng)
			local r = graph:route(a, b)
			t.ok(r ~= nil, "route " .. k)
			assertOnRoad(r, "random " .. k)
			-- never shorter than the straight line, never longer than Manhattan + one detour around a block
			local len = RoadGraph.routeLength(r)
			local straight = (Vector3.new(r[#r].X, 0, r[#r].Z) - Vector3.new(r[1].X, 0, r[1].Z)).Magnitude
			t.ok(len + 1e-3 >= straight, "route shorter than the crow flies")
			local manhattan = math.abs(r[#r].X - r[1].X) + math.abs(r[#r].Z - r[1].Z)
			t.ok(len <= manhattan + 2 * S + 1e-3, ("route %d too long: %.1f vs %.1f"):format(k, len, manhattan))
			local again = graph:route(a, b)
			t.eq(#again, #r, "deterministic point count")
			for i = 1, #r do
				t.eq(again[i], r[i], "deterministic point " .. i)
			end
		end
	end)

	t.test("a route never needs a U-turn shortcut through blocks (no diagonal segments)", function()
		local rng = H.Random.new(99)
		for _ = 1, 50 do
			local r = graph:route(randomRoadPoint(rng), randomRoadPoint(rng))
			for i = 2, #r do
				local d = r[i] - r[i - 1]
				t.ok(math.abs(d.X) < 1e-6 or math.abs(d.Z) < 1e-6, "axis-aligned segment")
			end
		end
	end)

	t.test("performance: routes take < 5 ms (average far below)", function()
		local rng = H.Random.new(7)
		local pts = {}
		for i = 1, 200 do
			pts[i] = randomRoadPoint(rng)
		end
		-- best of 3 per route: the test machine is shared, so single samples catch GC / scheduler noise
		local worst, total = 0, 0
		for i = 1, 100 do
			local best = math.huge
			for _ = 1, 3 do
				local t0 = os.clock()
				graph:route(pts[i], pts[i + 100])
				best = math.min(best, os.clock() - t0)
			end
			worst = math.max(worst, best)
			total += best
		end
		t.ok(worst < 0.005, ("worst route %.3f ms"):format(worst * 1000))
		t.ok(total / 100 < 0.002, ("average route %.3f ms"):format(total / 100 * 1000))
		local t0 = os.clock()
		RoadGraph.build()
		t.ok(os.clock() - t0 < 0.1, "graph build < 100 ms")
	end)

	t.test("custom segments: T-junctions split, crossings connect, levels don't", function()
		local g = RoadGraph.build({
			{ a = Vector3.new(0, 0, 0), b = Vector3.new(100, 0, 0), width = 20 },
			{ a = Vector3.new(50, 0, 0), b = Vector3.new(50, 0, 80), width = 20 }, -- T onto the first
			{ a = Vector3.new(0, 0, 40), b = Vector3.new(100, 0, 40), width = 20 }, -- crosses the stem at (50, 40)
			{ a = Vector3.new(80, 10, -50), b = Vector3.new(80, 10, 100), width = 20, level = 1 }, -- overpass
		})
		local nodes, edges = g:stats()
		-- (0,0) (50,0) (100,0) (50,80) (50,40) (0,40) (100,40) + overpass ends (80,-50) (80,100)
		t.eq(nodes, 9, "nodes")
		t.eq(edges, 7, "edges (overpass stays one edge)")
		local r = g:route(Vector3.new(5, 0, 0), Vector3.new(95, 0, 40))
		t.ok(r ~= nil, "route via the T")
		t.near(RoadGraph.routeLength(r), 45 + 40 + 45, 1e-3, "via the stem")
		-- overpass is unreachable from the street level
		t.eq(g:route(Vector3.new(5, 0, 0), Vector3.new(80, 10, 90)), nil, "different level is disconnected")
	end)

	t.test("custom segments: one-way streets are respected", function()
		-- a square loop: the top side is one-way west -> east, the rest two-way
		local g = RoadGraph.build({
			{ a = Vector3.new(0, 0, 0), b = Vector3.new(100, 0, 0), width = 20, oneWay = true },
			{ a = Vector3.new(100, 0, 0), b = Vector3.new(100, 0, 100), width = 20 },
			{ a = Vector3.new(100, 0, 100), b = Vector3.new(0, 0, 100), width = 20 },
			{ a = Vector3.new(0, 0, 100), b = Vector3.new(0, 0, 0), width = 20 },
		})
		local east = g:route(Vector3.new(10, 0, 0), Vector3.new(90, 0, 0))
		t.near(RoadGraph.routeLength(east), 80, 1e-3, "with the flow: straight")
		local west = g:route(Vector3.new(90, 0, 0), Vector3.new(10, 0, 0))
		t.near(RoadGraph.routeLength(west), 10 + 100 + 100 + 100 + 10, 1e-3, "against the flow: around the loop")
	end)

	t.test("projectToPolyline", function()
		local pts = { Vector3.new(0, 0, 0), Vector3.new(100, 0, 0), Vector3.new(100, 0, 100) }
		local d, i, tt, p = RoadGraph.projectToPolyline(pts, Vector3.new(50, 0, 10))
		t.near(d, 10, 1e-9, "distance")
		t.eq(i, 1, "segment")
		t.near(tt, 0.5, 1e-9, "t")
		t.near(p.X, 50, 1e-9, "point")
		local d2, i2 = RoadGraph.projectToPolyline(pts, Vector3.new(130, 0, 60))
		t.near(d2, 30, 1e-9, "second segment distance")
		t.eq(i2, 2, "second segment")
		t.eq(RoadGraph.routeLength(nil), 0, "nil route length")
	end)
end
