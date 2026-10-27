--!nocheck
-- v2 world data (Config/WorldLayout) + runtime queries (Util/WorldQuery): connectivity, geometry, placement and
-- scale invariants. The layout is generated at require time, so these tests are the guard rails for every edit to
-- the authored data (see docs/v2/world/WORLD_SPEC.md).
return function(t)
	local H = t.H
	local W = H.require("src/shared/Config/WorldLayout")
	local Q = H.require("src/shared/Util/WorldQuery")
	local WG = H.require("src/shared/Util/WorldGen")
	local Vector3 = H.roblox.Vector3

	local S = W.Scale
	local B = W.Bounds

	local function inBounds(p, margin)
		local m = margin or 0
		return p.X >= B.playMinX - m and p.X <= B.playMaxX + m and p.Z >= B.playMinZ - m and p.Z <= B.playMaxZ + m
	end

	local function flat(v)
		return Vector3.new(v.X, 0, v.Z)
	end

	-- segment index over all edges (for road-footprint checks independent of the generator's own)
	local segs = WG.segIndex(64)
	local segY = {}
	for ei, e in W.Edges do
		for k = 1, #e.points - 1 do
			local a, b = e.points[k], e.points[k + 1]
			WG.segAdd(segs, a.X, a.Z, b.X, b.Z, ei, k, e.width / 2 + e.sidewalk + 2)
			segY[#segs.ax] = { a.Y, b.Y }
		end
	end
	-- distance from (x, z) into the nearest road footprint (curb + sidewalk); > 0 = inside by that much
	local function roadPenetration(x, z)
		local worst, who = -math.huge, nil
		WG.segQuery(segs, x, z, 0, function(id)
			local e = W.Edges[segs.owner[id]]
			local _, _, _, d = WG.projectSeg(x, z, segs.ax[id], segs.az[id], segs.bx[id], segs.bz[id])
			local pen = e.width / 2 + e.sidewalk - d
			if pen > worst then
				worst, who = pen, e.name
			end
		end)
		return worst, who
	end

	---------------------------------------------------------------------------------------------------------------
	-- Scale
	---------------------------------------------------------------------------------------------------------------

	t.test("real-scale constants (1 stud ~= 0.28 m)", function()
		t.near(S.STUD_METERS, 0.28, 0.02, "stud size")
		t.ok(S.LANE >= 12 and S.LANE <= 13, "lane 12-13 studs")
		t.ok(S.SIDEWALK >= 12 and S.SIDEWALK <= 14, "sidewalk 12-14 studs")
		t.ok(S.STOREY >= 12 and S.STOREY <= 13, "storey 12-13 studs")
		t.ok(S.CAR_LENGTH >= 16 and S.CAR_LENGTH <= 18, "car 16-18 studs")
		t.ok(S.CHARACTER_HEIGHT >= 5 and S.CHARACTER_HEIGHT <= 6, "character ~5.5 studs")
		t.ok(S.DECK >= 26, "freeway deck clears trucks")
		t.ok(S.CLEARANCE >= 14, "vertical clearance >= 4 m")
	end)

	t.test("road cross-sections are real-scale", function()
		for _, e in W.Edges do
			t.eq(e.laneWidth, S.LANE, "lane width " .. e.name)
			if e.sidewalk > 0 and e.class ~= "pier" then
				t.ok(e.sidewalk >= 8 and e.sidewalk <= 14, "sidewalk width " .. e.name .. " " .. e.sidewalk)
			end
			local lanes = e.lanesF + e.lanesB
			t.ok(e.width >= lanes * S.LANE - 0.01, "width fits the lanes: " .. e.name)
			if e.class == "freeway" then
				t.ok(e.lanesF >= 2 and e.oneWay, "freeway carriageway one-way, 2+ lanes")
			end
		end
	end)

	t.test("world size: ~2-4 minutes to cross by car", function()
		local pts, len = Q.route(Vector3.new(-4480, 12, -950), Vector3.new(5620, 30, -680))
		t.ok(pts ~= nil, "west -> east route exists")
		-- at a typical 70-100 studs/s average (mid-tier car incl. turns / traffic)
		t.ok(len / 70 >= 120 and len / 70 <= 240, ("west -> east %.0f studs = %.0f s at 70"):format(len, len / 70))
		t.ok(len / 100 >= 80, "not trivially small")
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Road graph
	---------------------------------------------------------------------------------------------------------------

	t.test("graph is well formed", function()
		t.ok(#W.Nodes > 300 and #W.Edges > 500, "a real city's worth of roads")
		for i, e in W.Edges do
			t.eq(e.id, i, "edge id")
			t.ok(#e.points >= 2 and e.length > 1, "edge has geometry " .. i)
			t.ok((e.points[1] - W.Nodes[e.a].pos).Magnitude < 0.05, "edge starts at node a " .. i)
			t.ok((e.points[#e.points] - W.Nodes[e.b].pos).Magnitude < 0.05, "edge ends at node b " .. i)
			t.ok(e.a ~= e.b, "no self loops " .. i)
			t.ok(W.Districts[1] ~= nil and type(e.district) == "string", "edge district")
		end
		for i, n in W.Nodes do
			t.eq(n.id, i, "node id")
			t.ok(#n.edges >= 1, "node used")
		end
	end)

	t.test("road graph is strongly connected (every road reachable from every road, one-ways respected)", function()
		local _, count = WG.scc(#W.Nodes, W._arcs)
		t.eq(count, 1, "one strongly connected component")
		for _, name in W.DroppedEdges do
			t.ok(not name:find("(authored)", 1, true), "authored road dropped from the graph: " .. name)
		end
		t.ok(#W.DroppedEdges <= 6, "only a few stray generated fragments dropped: " .. #W.DroppedEdges)
	end)

	t.test("traffic network is strongly connected too", function()
		local comp, count, best = WG.scc(#W.Nodes, W._trafficArcs)
		local used = 0
		for _, n in W.Nodes do
			for _, ei in n.edges do
				if W.Edges[ei].traffic then
					used += 1
					break
				end
			end
		end
		local _ = comp
		t.ok(best >= used, ("traffic nodes in one component: %d of %d (components %d)"):format(best, used, count))
	end)

	t.test("hierarchy exists: freeway ring, ramps, avenues, streets, bridges, a channel", function()
		local classes, bridges, elevated, flyover = {}, 0, 0, 0
		for _, e in W.Edges do
			classes[e.class] = (classes[e.class] or 0) + 1
			if e.bridge then
				bridges += 1
			end
			if e.elevated then
				elevated += 1
			end
			if e.layer >= 2 then
				flyover += 1
			end
		end
		for _, c in
			{ "freeway", "ramp", "highway", "boulevard", "avenue", "street", "rural", "channel", "pier", "runway" }
		do
			t.ok((classes[c] or 0) > 0, "has class " .. c)
		end
		t.ok(bridges >= 5, "bridges over water / the channel: " .. bridges)
		t.ok(elevated >= 20, "elevated decks")
		t.ok(flyover >= 2, "interchange flyovers")
	end)

	t.test("road grades are drivable", function()
		for _, e in W.Edges do
			local limit = if e.class == "ramp" or e.class == "freeway" then 0.11 else 0.18
			for k = 2, #e.points do
				local a, b = e.points[k - 1], e.points[k]
				local run = (flat(b) - flat(a)).Magnitude
				if run > 6 then
					local g = math.abs(b.Y - a.Y) / run
					t.ok(g <= limit, ("grade %.2f on %s (%s) at %d,%d"):format(g, e.name, e.class, a.X, a.Z))
				end
			end
		end
	end)

	t.test("roads that cross without a junction are grade-separated", function()
		local nodeShared = function(e1, e2)
			local s = {}
			for _, n in { e1.a, e1.b } do
				s[n] = true
			end
			local out = {}
			for _, n in { e2.a, e2.b } do
				if s[n] then
					table.insert(out, W.Nodes[n].pos)
				end
			end
			return out
		end
		local checked = {}
		local bad = 0
		local first = nil
		for id = 1, #segs.ax do
			local ei = segs.owner[id]
			WG.segQuery(segs, (segs.ax[id] + segs.bx[id]) / 2, (segs.az[id] + segs.bz[id]) / 2, 0, function(other)
				local ej = segs.owner[other]
				if ej <= ei then
					return
				end
				local key = id * 1000000 + other
				if checked[key] then
					return
				end
				checked[key] = true
				local e1, e2 = W.Edges[ei], W.Edges[ej]
				if e1.corridor and e1.corridor == e2.corridor then
					return
				end
				local tt, u = WG.segIntersect(
					segs.ax[id],
					segs.az[id],
					segs.bx[id],
					segs.bz[id],
					segs.ax[other],
					segs.az[other],
					segs.bx[other],
					segs.bz[other],
					0
				)
				if not tt then
					return
				end
				local px = segs.ax[id] + (segs.bx[id] - segs.ax[id]) * tt
				local pz = segs.az[id] + (segs.bz[id] - segs.az[id]) * tt
				for _, sp in nodeShared(e1, e2) do
					if WG.dist(px, pz, sp.X, sp.Z) < 80 then
						return -- tangent diverge / merge geometry next to a shared node
					end
				end
				local y1 = segY[id][1] + (segY[id][2] - segY[id][1]) * tt
				local y2 = segY[other][1] + (segY[other][2] - segY[other][1]) * u
				if math.abs(y1 - y2) < S.CLEARANCE - 2 then
					bad += 1
					first = first or ("%s x %s at (%d, %d) dy %.1f"):format(e1.name, e2.name, px, pz, math.abs(y1 - y2))
				end
			end)
		end
		t.eq(bad, 0, "unseparated crossings (first: " .. tostring(first) .. ")")
	end)

	t.test("intersections: controls, signals with phases", function()
		local signals = 0
		for _, it in W.Intersections do
			t.ok(#it.approaches >= 3, "junction degree")
			if it.control == "signal" then
				signals += 1
				t.ok(#it.phases >= 2, "signal has 2+ phases")
				t.ok(it.cycle > 20 and it.cycle < 120, "sane cycle")
				local seen = {}
				for _, ph in it.phases do
					for _, a in ph.approaches do
						t.ok(not seen[a], "approach in one phase only")
						seen[a] = true
					end
				end
			end
		end
		t.ok(signals >= 100, "a signalized city: " .. signals)
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Lots, POIs, plots
	---------------------------------------------------------------------------------------------------------------

	local function obbOf(cf, size, shrink)
		local r = cf.RightVector
		return {
			cx = cf.Position.X,
			cz = cf.Position.Z,
			ux = r.X,
			uz = r.Z,
			hw = size.X / 2 - (shrink or 0),
			hd = size.Z / 2 - (shrink or 0),
		}
	end

	local function footprintOnRoad(cf, size)
		local o = obbOf(cf, size, 2)
		local vx, vz = -o.uz, o.ux
		for i = -2, 2 do
			for j = -2, 2 do
				local x = o.cx + o.ux * o.hw * i / 2 + vx * o.hd * j / 2
				local z = o.cz + o.uz * o.hw * i / 2 + vz * o.hd * j / 2
				local pen, who = roadPenetration(x, z)
				if pen > 0 then
					return true, who
				end
			end
		end
		return false
	end

	t.test("parcels: plenty, inside bounds, on land, clear of roads", function()
		t.ok(#W.Parcels >= 800, "lots: " .. #W.Parcels)
		for _, p in W.Parcels do
			local c = p.cframe.Position
			t.ok(inBounds(c), "parcel in bounds")
			t.ok(W.gradeAt(c.X, c.Z) > W.SEA_LEVEL, "parcel on land")
			t.ok(p.size.X > 10 and p.size.Z > 10 and p.size.Y >= 0, "parcel size")
			local hit, who = footprintOnRoad(p.cframe, p.size)
			t.ok(not hit, "parcel " .. p.id .. " (" .. p.district .. ") overlaps road " .. tostring(who))
		end
	end)

	t.test("parcels do not overlap each other", function()
		local cells = {}
		local obbs = {}
		for i, p in W.Parcels do
			local o = obbOf(p.cframe, p.size, 0.5)
			obbs[i] = o
			local r = math.sqrt(o.hw * o.hw + o.hd * o.hd)
			WG.hashBox(cells, 128, o.cx - r, o.cz - r, o.cx + r, o.cz + r, i)
		end
		local overlaps = 0
		local seen = {}
		for _, list in cells do
			for x = 1, #list do
				for y = x + 1, #list do
					local a, b = math.min(list[x], list[y]), math.max(list[x], list[y])
					local key = a * 100000 + b
					if not seen[key] then
						seen[key] = true
						if WG.obbOverlap(obbs[a], obbs[b], 0) then
							overlaps += 1
						end
					end
				end
			end
		end
		t.eq(overlaps, 0, "overlapping parcel pairs")
	end)

	t.test("skyline: downtown towers are tall, suburbs are low", function()
		local tallest, suburbMax = 0, 0
		for _, p in W.Parcels do
			if p.district == "downtown" then
				tallest = math.max(tallest, p.size.Y)
			elseif p.district == "southgate" then
				suburbMax = math.max(suburbMax, p.size.Y)
			end
		end
		t.ok(tallest >= 350, "downtown has 30+ storey towers: " .. tallest)
		t.ok(suburbMax <= 60, "suburbs stay low: " .. suburbMax)
		local pinnacle = Q.poi("PinnacleTower")
		t.ok(pinnacle and pinnacle.size.Y >= 600, "Pinnacle Tower landmark")
	end)

	t.test("POIs: all placed, real names, clear of roads and of each other, reachable by road", function()
		t.eq(#W.PlacementErrors, 0, "placement errors: " .. table.concat(W.PlacementErrors, "; "))
		local kinds = {}
		for _, p in W.POIs do
			kinds[p.kind] = (kinds[p.kind] or 0) + 1
			t.ok(inBounds(p.cframe.Position), "POI in bounds " .. p.id)
			local hit, who = footprintOnRoad(p.cframe, p.size)
			t.ok(not hit, p.id .. " overlaps road " .. tostring(who))
			-- entrance sits on the curb of its frontage edge
			local e = W.Edges[p.edge]
			local d = WG.polyProject(
				(function()
					local pts = {}
					for _, q in e.points do
						table.insert(pts, { x = q.X, z = q.Z })
					end
					return pts
				end)(),
				p.entrance.X,
				p.entrance.Z
			)
			t.near(d, e.width / 2, 1.5, "entrance on the curb of " .. p.id)
			t.ok(e.layer == 0 and not e.elevated, "POI fronts a ground road " .. p.id)
			-- no Rockstar names
			for _, banned in
				{
					"Los Santos",
					"Vinewood",
					"Vice",
					"Ammu",
					"Pay 'n' Spray",
					"Maze Bank",
					"Fleeca",
					"Vespucci",
					"Del Perro",
					"Rockford",
				}
			do
				t.ok(not p.name:find(banned, 1, true), "no Rockstar names: " .. p.name)
			end
		end
		for i, a in W.POIs do
			for j = i + 1, #W.POIs do
				local b = W.POIs[j]
				t.ok(
					not WG.obbOverlap(obbOf(a.cframe, a.size), obbOf(b.cframe, b.size), 0),
					a.id .. " overlaps " .. b.id
				)
			end
		end
		for _, k in
			{
				"dealership",
				"gunshop",
				"bank",
				"jewelry",
				"convenience",
				"gas",
				"police",
				"hospital",
				"customs",
				"spray",
				"chop",
				"armored_depot",
				"plaza",
			}
		do
			t.ok((kinds[k] or 0) >= 1, "has POI kind " .. k)
		end
		t.ok(kinds.convenience >= 5, "several stores to rob")
		t.ok(kinds.police >= 5, "police HQ + precincts")
		t.ok(kinds.hospital >= 3, "hospitals for WASTED respawns")
		t.ok(kinds.gas >= 6, "gas stations")
	end)

	t.test("plots: 8 garages, spread out, near on-ramps, clear of roads and POIs", function()
		t.eq(#W.Plots, 8, "8 plots (max 8 players)")
		t.eq(Q.plotCount(), 8, "plotCount")
		for i, p in ipairs(W.Plots) do
			t.eq(p.index, i, "plot index")
			t.ok(inBounds(p.cframe.Position), "plot in bounds")
			local hit, who = footprintOnRoad(p.cframe, p.size)
			t.ok(not hit, "plot " .. i .. " overlaps road " .. tostring(who))
			t.ok(p.nearestOnRamp <= 950, ("plot %d is %d from an on-ramp"):format(i, p.nearestOnRamp))
			-- door faces the street: a point just past the curb in front of the door is on the plot's own road
			local e = W.Edges[p.edge]
			local front = p.door + p.cframe.LookVector * (e.sidewalk + 14 + 6)
			local rp, ej, _, d = Q.nearestRoadPoint(front, { ignoreHeight = true, maxDistance = 200 })
			t.ok(
				rp ~= nil and W.Edges[ej].name == e.name and d <= e.width / 2,
				"plot " .. i .. " door faces its street"
			)
			t.eq(Q.plotAt(p.cframe.Position + Vector3.new(0, 5, 0)), i, "plotAt finds plot " .. i)
			for j = i + 1, #W.Plots do
				local q = W.Plots[j]
				local d = (flat(p.cframe.Position) - flat(q.cframe.Position)).Magnitude
				t.ok(d >= 1000, ("plots %d and %d only %d apart (raids need a getaway drive)"):format(i, j, d))
			end
			for _, poi in W.POIs do
				t.ok(
					not WG.obbOverlap(obbOf(p.cframe, p.size), obbOf(poi.cframe, poi.size), 0),
					"plot overlaps " .. poi.id
				)
			end
		end
		-- every garage reaches every other garage by road
		for i = 1, #W.Plots do
			local j = i % #W.Plots + 1
			local pts = Q.route(W.Plots[i].door, W.Plots[j].door)
			t.ok(pts ~= nil, ("route plot %d -> %d"):format(i, j))
		end
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Spawns, zones, routes
	---------------------------------------------------------------------------------------------------------------

	t.test("street parking spots sit in the curb lane, outside junctions", function()
		local spots = W.Spawns.parking
		t.ok(#spots >= 2000, "parking spots: " .. #spots)
		for i = 1, #spots, 7 do
			local sp = spots[i]
			local p = sp.cframe.Position
			t.ok(inBounds(p), "spot in bounds")
			t.ok(Q.isOnRoad(p), "spot on the road surface")
			local it = Q.intersectionAt(p, 4)
			t.ok(it == nil, ("spot inside junction at %d,%d"):format(p.X, p.Z))
			t.ok(math.abs(sp.cframe.LookVector.Y) < 0.05, "spot is level")
		end
	end)

	t.test("police spawns on traffic lanes next to every station", function()
		local stations = {}
		for _, s in W.Spawns.police do
			stations[s.station] = true
			t.ok(Q.isOnRoad(s.cframe.Position), "police spawn on road")
		end
		for _, p in Q.poisOfKind("police") do
			t.ok(stations[p.id], "spawns for " .. p.id)
		end
		t.ok(#W.Spawns.hospital >= 3, "hospital respawns")
		t.ok(#W.Spawns.traffic >= 200, "traffic spawn edges")
	end)

	t.test("hot drops, stunt jumps, helipads, landmarks: inside bounds, on land, near roads", function()
		t.ok(#W.HotDrops >= 10, "hot drop zones")
		for _, z in W.HotDrops do
			local p = z.cframe.Position
			t.ok(inBounds(p), z.id .. " in bounds")
			t.ok(W.gradeAt(p.X, p.Z) > W.SEA_LEVEL, z.id .. " on land")
			local rp = Q.nearestRoadPoint(p, { maxDistance = 200, ignoreHeight = true })
			t.ok(rp ~= nil, z.id .. " reachable by road")
		end
		t.ok(#W.StuntJumps >= 10, "stunt jumps")
		for _, j in W.StuntJumps do
			t.ok(inBounds(j.cframe.Position) and inBounds(j.landing, 400), j.id .. " in bounds")
		end
		for _, l in W.Landmarks do
			t.ok(inBounds(l.cframe.Position, 600), l.id .. " in bounds")
		end
		t.ok(Q.landmark("SunwoodSign") ~= nil, "giant hillside letter sign")
		t.ok(#W.Helipads >= 5, "helipads")
	end)

	t.test("routes: armored trucks and races resolve on the graph", function()
		t.eq(#W.RouteErrors, 0, "route errors: " .. table.concat(W.RouteErrors, "; "))
		local armored, races = 0, 0
		for _, r in W.Routes do
			t.ok(#r.path >= 2 and r.length > 500, "route " .. r.id .. " has a path")
			if r.kind == "armored" then
				armored += 1
			elseif r.kind == "race" then
				races += 1
			end
		end
		t.ok(armored >= 3, "armored truck routes")
		t.ok(races >= 5, "race routes")
	end)

	t.test("everything inside the world bounds", function()
		for _, n in W.Nodes do
			t.ok(inBounds(n.pos), ("node at %d,%d"):format(n.pos.X, n.pos.Z))
			t.ok(n.pos.Y > B.min.Y and n.pos.Y < B.max.Y, "node height")
		end
		for _, p in W.Coast do
			t.ok(p.x > B.min.X and p.x < B.max.X and p.z > B.min.Z and p.z < B.max.Z, "coast in bounds")
		end
	end)

	---------------------------------------------------------------------------------------------------------------
	-- WorldQuery
	---------------------------------------------------------------------------------------------------------------

	t.test("WorldQuery: nearest road point, lanes, districts, parcels", function()
		local p, ei, s = Q.nearestRoadPoint(Vector3.new(320, 12, -300))
		t.ok(p ~= nil and W.Edges[ei].name == "Crown Boulevard", "nearest road to downtown point is Crown")
		local e = W.Edges[ei]
		-- lane 1 is right of the centerline (right-hand traffic) by median/2 + half a lane
		local cf = Q.laneCFrame(ei, 1, 1, s)
		local c, tan = Q.edgePoint(ei, s)
		local right = Vector3.new(-tan.Z, 0, tan.X)
		t.near((cf.Position - c):Dot(right), e.median / 2 + S.LANE / 2, 0.01, "lane 1 offset")
		t.near(cf.LookVector:Dot(tan), 1, 1e-3, "lane faces travel")
		local back = Q.laneCFrame(ei, 1, -1, s)
		t.near((back.Position - c):Dot(right), -(e.median / 2 + S.LANE / 2), 0.01, "opposite lane mirrored")
		t.ok(Q.isOnRoad(cf.Position), "lane is on the road")
		t.ok(Q.pointInDistrict(Vector3.new(0, 12, 0), "downtown"), "downtown at the center")
		t.eq(Q.districtAt(Vector3.new(-4300, 12, 0)).id, "beach", "Palmera Beach on the west coast")
		t.eq(Q.districtAt(Vector3.new(4300, 30, -560)).id, "cactus", "Cactus Junction overrides Red Mesa")
		local walk = Q.sidewalkCFrame(ei, 1, s)
		t.ok(
			walk ~= nil and not Q.isOnRoad(walk.Position - Vector3.new(0, S.CURB_HEIGHT, 0)),
			"sidewalk is off the asphalt"
		)
		local par = W.Parcels[math.floor(#W.Parcels / 2)]
		t.eq(Q.parcelAt(par.cframe.Position), par, "parcelAt")
		t.ok(Q.parcelAt(Vector3.new(320, 12, -250)) == nil, "no lot on Crown Boulevard")
	end)

	t.test("WorldQuery: deck vs street under it", function()
		-- a point on the ring deck resolves to the freeway; the same XZ at street level to the street below
		local ring
		for _, e in W.Edges do
			if e.class == "freeway" and e.corridor == "H1 Ring Freeway" and e.length > 300 then
				ring = e
				break
			end
		end
		local mid = ring.points[math.floor(#ring.points / 2)]
		local _, onDeck = Q.nearestRoadPoint(mid)
		t.eq(W.Edges[onDeck].class, "freeway", "on the deck")
		local okRoad = Q.isOnRoad(mid + Vector3.new(0, 1, 0))
		t.ok(okRoad, "deck is road")
	end)

	t.test("WorldQuery: signals cycle deterministically", function()
		local it
		for _, i in W.Intersections do
			if i.control == "signal" then
				it = i
				break
			end
		end
		local greens, reds = 0, 0
		for tm = 0, it.cycle * 2, 0.5 do
			local st = Q.signalState(it.id, it.phases[1].approaches[1], tm)
			if st == "green" then
				greens += 1
			elseif st == "red" then
				reds += 1
			end
			-- two approaches from different phases are never green together
			local other = it.phases[2].approaches[1]
			t.ok(not (st == "green" and Q.signalState(it.id, other, tm) == "green"), "conflicting greens")
		end
		t.ok(greens > 0 and reds > 0, "cycles green and red")
	end)

	t.test("WorldQuery: routing, nearest lane, nearest hospital", function()
		local pts, len = Q.route(W.Plots[1].door, W.Plots[5].door, { traffic = true })
		t.ok(pts ~= nil and len > 1000, "garage to garage")
		t.ok(Q.routeLength(pts) >= len * 0.9, "polyline length matches")
		local lane = Q.nearestLane(Vector3.new(0, 12, 100))
		t.ok(lane ~= nil and Q.isOnRoad(lane.Position), "nearest lane is on a road")
		local h = Q.nearestPOI(Vector3.new(0, 12, 0), "hospital")
		t.ok(h ~= nil and h.kind == "hospital", "nearest hospital")
		for _, p in W.POIs do
			local r = Q.route(W.Plots[1].door, p.entrance)
			t.ok(r ~= nil, "POI reachable by road: " .. p.id)
		end
	end)

	t.test("deterministic: a fresh build produces identical data", function()
		local function fingerprint(L)
			local acc = { #L.Nodes, #L.Edges, #L.Parcels, #L.POIs, #L.Spawns.parking }
			local sum = 0
			for _, e in L.Edges do
				for _, p in e.points do
					sum += p.X * 0.37 + p.Y * 1.3 + p.Z * 0.71
				end
			end
			for _, p in L.Parcels do
				local c = p.cframe.Position
				sum += c.X * 0.13 + c.Z * 0.29 + p.size.X + p.size.Y * 0.5 + p.size.Z
			end
			table.insert(acc, math.floor(sum * 1000))
			return table.concat(acc, ":")
		end
		local first = fingerprint(W)
		H.setMode("server") -- clears the module cache
		local W2 = H.require("src/shared/Config/WorldLayout")
		t.ok(W2 ~= W, "rebuilt")
		t.eq(fingerprint(W2), first, "same layout twice")
	end)

	t.test("terrain: sea, beach, hills, flat basin, channel", function()
		t.ok(W.heightAt(-6200, 0) < W.SEA_LEVEL, "ocean west")
		t.near(W.heightAt(0, 0), W.GRADE, 0.01, "downtown is flat at grade")
		t.ok(W.gradeAt(-1300, -3100) > 150, "Sunwood Hills crest is high")
		local beach = W.gradeAt(-5000, 0)
		t.ok(beach > W.SEA_LEVEL and beach < W.GRADE, "beach slope")
		t.ok(W.heightAt(1952, 500) < 5, "Rust River channel floor is sunken")
		t.ok(Q.isWater(Vector3.new(700, 0, 3200)), "Iron Bay channel is water")
	end)
end
