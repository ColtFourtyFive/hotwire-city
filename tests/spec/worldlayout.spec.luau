--!nocheck
-- v2 world data (Config/WorldLayout = the baked tools/world/gen output) + runtime queries (Util/WorldQuery):
-- connectivity, geometry, placement, gameplay rules from the world critiques (docs/v2/world/CRITIQUES.md, accepted in
-- WORLD_SPEC.md "Critique log") and scale invariants. These are the guard rails for every edit to the generator:
-- edit tools/world/gen, run `lune run tools/world/bake.luau`, then `lune run tests/run.luau worldlayout`.
return function(t)
	local H = t.H
	H.setMode("server")
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
	-- distance from (x, z) into the nearest road footprint (curb + sidewalk); > 0 = inside by that much. Elevated
	-- decks are reported separately (lots may stand under them only as open uses or low enough).
	local function roadPenetration(x, z, withElevated)
		local worst, who, whoEdge = -math.huge, nil, nil
		WG.segQuery(segs, x, z, 0, function(id)
			local e = W.Edges[segs.owner[id]]
			if e.elevated and not withElevated then
				return
			end
			local _, _, _, d = WG.projectSeg(x, z, segs.ax[id], segs.az[id], segs.bx[id], segs.bz[id])
			local pen = e.width / 2 + e.sidewalk - d
			if pen > worst then
				worst, who, whoEdge = pen, e.name, e
			end
		end)
		return worst, who, whoEdge
	end

	---------------------------------------------------------------------------------------------------------------
	-- Bake
	---------------------------------------------------------------------------------------------------------------

	t.test("baked data is up to date with the generator (fresh build -> identical bake)", function()
		local generate = require("../../tools/world/gen")
		local Bake = require("../../tools/world/bakelib")
		local fs = require("@lune/fs")
		local fresh = generate()
		t.eq(#fresh.PlacementErrors, 0, "placement errors: " .. table.concat(fresh.PlacementErrors, "; "))
		t.eq(#fresh.RouteErrors, 0, "route errors: " .. table.concat(fresh.RouteErrors, "; "))
		t.eq(#fresh.GeometryErrors, 0, "geometry errors: " .. table.concat(fresh.GeometryErrors, "; "))
		local coreText, coreHash, lotsText, lotsHash = Bake.bake(fresh)
		t.eq(W.HASH, coreHash, "core hash (re-run lune run tools/world/bake.luau)")
		t.ok(fs.readFile(Bake.CORE_PATH) == coreText, "core file matches a fresh bake")
		t.ok(fs.readFile(Bake.LOTS_PATH) == lotsText, "lots file matches a fresh bake: " .. lotsHash)
		-- a second build is identical (determinism: no Random, integer hashes only)
		local again = generate()
		local coreText2 = Bake.bake(again)
		t.ok(coreText2 == coreText, "two builds bake to identical text")
	end)

	t.test("client loads the core without the server data; the server gets lots lazily", function()
		H.setMode("client")
		local Wc = H.require("src/shared/Config/WorldLayout")
		t.ok(#Wc.Edges == #W.Edges and #Wc.POIs == #W.POIs, "core is shared")
		t.ok(not Wc.hasServerData(), "no lots on a client")
		t.ok(not pcall(function()
			return Wc.Parcels
		end), "Parcels are server-only")
		H.setMode("server")
		W = H.require("src/shared/Config/WorldLayout")
		Q = H.require("src/shared/Util/WorldQuery")
		t.ok(W.hasServerData() and #W.Parcels > 0, "server lots")
	end)

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
		local fs = require("@lune/fs")
		local serde = require("@lune/serde")
		local project = serde.decode("json", fs.readFile("default.project.json"))
		t.eq(project.tree.Workspace["$properties"].Gravity, S.GRAVITY, "jump arcs use the place gravity")
	end)

	t.test("road cross-sections are real-scale", function()
		for _, e in W.Edges do
			t.eq(e.laneWidth, S.LANE, "lane width " .. e.name)
			if e.sidewalk > 0 and e.class ~= "pier" then
				t.ok(e.sidewalk >= 8 and e.sidewalk <= 14, "sidewalk width " .. e.name .. " " .. e.sidewalk)
			end
			local lanes = e.lanesF + e.lanesB
			if e.class ~= "alley" then -- alleys are one shared 18-stud lane
				t.ok(e.width >= lanes * S.LANE - 0.01, "width fits the lanes: " .. e.name)
			end
			if e.class == "freeway" then
				t.ok(e.lanesF >= 2 and e.oneWay, "freeway carriageway one-way, 2+ lanes")
			end
		end
	end)

	t.test("world size: ~2-4 minutes to cross by car", function()
		local pts, len = Q.route(Vector3.new(-4480, 12, -950), Vector3.new(5620, 30, -680), { shortest = true })
		t.ok(pts ~= nil, "west -> east route exists")
		t.ok(len / 70 >= 120 and len / 70 <= 260, ("west -> east %.0f studs = %.0f s at 70"):format(len, len / 70))
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
			t.ok(type(e.district) == "string", "edge district")
			for _, sp in e.spans do
				t.ok(sp[1] >= -0.01 and sp[2] <= e.length + 0.01 and sp[2] > sp[1], "bridge span inside its edge")
			end
		end
		for i, n in W.Nodes do
			t.eq(n.id, i, "node id")
			t.ok(#n.edges >= 1, "node used")
		end
	end)

	t.test("road graph is strongly connected (every road reachable from every road, one-ways respected)", function()
		local _, count = WG.scc(#W.Nodes, Q.arcs(false, true))
		t.eq(count, 1, "one strongly connected component")
		for _, name in W.DroppedEdges do
			t.ok(not name:find("(authored)", 1, true), "authored road dropped from the graph: " .. name)
		end
		t.ok(#W.DroppedEdges <= 6, "only a few stray generated fragments dropped: " .. #W.DroppedEdges)
	end)

	t.test("traffic network is strongly connected too (no AI pockets)", function()
		local comp, count, best, bestId = WG.scc(#W.Nodes, Q.arcs(true, true))
		local used = 0
		for i, n in W.Nodes do
			for _, ei in n.edges do
				if W.Edges[ei].traffic then
					used += 1
					t.ok(comp[i] == bestId, "traffic node in the main component " .. i)
					break
				end
			end
		end
		t.ok(best >= used, ("traffic nodes in one component: %d of %d (components %d)"):format(best, used, count))
	end)

	t.test("hierarchy exists: freeway ring, ramps, avenues, streets, alleys, bridges, a channel", function()
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
			{
				"freeway",
				"ramp",
				"highway",
				"boulevard",
				"avenue",
				"street",
				"alley",
				"rural",
				"channel",
				"pier",
				"runway",
			}
		do
			t.ok((classes[c] or 0) > 0, "has class " .. c)
		end
		t.ok(bridges >= 10, "bridges over water / the channel / the canyon: " .. bridges)
		t.ok(elevated >= 20, "elevated decks")
		t.ok(flyover >= 4, "interchange flyovers")
		-- every street crossing the Rust River channel is a bridge (no road drawn over a void)
		local crossings = 0
		for _, e in W.Edges do
			if e.layer == 0 and (e.class == "street" or e.class == "avenue" or e.class == "boulevard") then
				for k = 1, #e.points - 1 do
					local a, b = e.points[k], e.points[k + 1]
					local found = false
					for i = 0, 10 do
						local p = a:Lerp(b, i / 10)
						if W.heightAt(p.X, p.Z) < -1 and W.gradeAt(p.X, p.Z) > 0 and p.Y > 8 then
							crossings += 1
							t.ok(e.bridge, "road over the channel is a bridge: " .. e.name)
							found = true
							break
						end
					end
					if found then
						break
					end
				end
			end
		end
		t.ok(crossings >= 6, "streets bridge the channel: " .. crossings)
	end)

	t.test("road grades are drivable", function()
		for _, e in W.Edges do
			-- hill cul-de-sacs climb like LA's (real ones reach ~30 %); everything else stays gentle
			local limit = if e.class == "ramp" or e.class == "freeway"
				then 0.11
				elseif e.district == "hills" then 0.24
				else 0.18
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

	t.test("intersections: controls, signals with phases, ramp terminals signalized", function()
		local signals = 0
		for _, it in W.Intersections do
			t.ok(#it.approaches >= 3, "junction degree")
			if it.control == "signal" then
				signals += 1
				t.ok(#it.phases >= 2, "signal has 2+ phases")
				t.ok(it.cycle > 20 and it.cycle < 150, "sane cycle " .. it.cycle)
				-- an approach may lead with a protected-left phase and then run in its through phase, but it is
				-- never in two phases of the same kind
				local seen = {}
				for _, ph in it.phases do
					for _, a in ph.approaches do
						local key = a .. ":" .. (if ph.movement == "left" then "left" else "main")
						t.ok(not seen[key], "approach in one phase of each kind")
						seen[key] = true
					end
				end
			end
			-- tech critique 1: a ramp meeting a layer-0 street at grade is a signal
			local hasRamp, ground = false, false
			for _, a in it.approaches do
				local e = W.Edges[a.edge]
				if e.class == "ramp" then
					hasRamp = true
				elseif e.layer == 0 then
					ground = true
				end
			end
			if hasRamp and ground and math.abs(it.pos.Y - W.gradeAt(it.pos.X, it.pos.Z)) < 3 then
				t.eq(it.control, "signal", ("ramp terminal at (%d, %d)"):format(it.pos.X, it.pos.Z))
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

	local function footprintOnRoad(cf, size, withElevated)
		local o = obbOf(cf, size, 2)
		local vx, vz = -o.uz, o.ux
		for i = -2, 2 do
			for j = -2, 2 do
				local x = o.cx + o.ux * o.hw * i / 2 + vx * o.hd * j / 2
				local z = o.cz + o.uz * o.hw * i / 2 + vz * o.hd * j / 2
				local pen, who, e = roadPenetration(x, z, withElevated)
				if pen > 0 then
					return true, who, e
				end
			end
		end
		return false
	end

	t.test("parcels: plenty, inside bounds, on land, clear of roads, never piercing a deck", function()
		t.ok(#W.Parcels >= 800, "lots: " .. #W.Parcels)
		for _, p in W.Parcels do
			local c = p.cframe.Position
			t.ok(inBounds(c), "parcel in bounds")
			t.ok(W.gradeAt(c.X, c.Z) > W.SEA_LEVEL, "parcel on land")
			t.ok(p.size.X > 10 and p.size.Z > 10 and p.size.Y >= 0, "parcel size")
			local hit, who = footprintOnRoad(p.cframe, p.size, false)
			t.ok(not hit, "parcel " .. p.id .. " (" .. p.district .. ") overlaps road " .. tostring(who))
			-- gta critique 10: a lot under a deck is open (or its top stays 16 under the deck)
			local over, _, e = footprintOnRoad(p.cframe, p.size, true)
			if over and e and e.elevated and p.size.Y > 0 then
				local deckY = math.huge
				for _, q in e.points do
					deckY = math.min(deckY, q.Y)
				end
				t.ok(c.Y + p.size.Y <= deckY - 16, ("lot %d (%s) pierces %s"):format(p.id, p.use, e.name))
			end
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

	t.test("skyline: a real tower cluster downtown (gta critique 1), suburbs stay low", function()
		local tallest, suburbMax, over380, over220 = 0, 0, 0, 0
		for _, p in W.Parcels do
			if p.district == "downtown" then
				tallest = math.max(tallest, p.size.Y)
				if p.size.Y >= 380 then
					over380 += 1
				end
				if p.size.Y >= 220 then
					over220 += 1
				end
			elseif p.district == "southgate" then
				suburbMax = math.max(suburbMax, p.size.Y)
			end
		end
		t.ok(tallest >= 560, "downtown has 45+ storey towers: " .. tallest)
		t.ok(over380 >= 8, "8+ towers over 380: " .. over380)
		t.ok(over220 >= 25, "25+ towers over 220: " .. over220)
		t.ok(suburbMax <= 60, "suburbs stay low: " .. suburbMax)
		local pinnacle = Q.poi("PinnacleTower")
		t.ok(pinnacle and pinnacle.size.Y >= 700, "Pinnacle Tower landmark")
		for _, p in W.Parcels do
			if p.tower then
				t.ok(p.size.X >= 160 and p.size.Z >= 160, "tower footprint >= 160 x 160")
				t.ok(p.podium ~= nil and p.crown ~= nil, "tower has podium + crown")
			end
		end
	end)

	t.test("POIs: all placed, real names, clear of roads and of each other, reachable by road", function()
		local kinds = {}
		for _, p in W.POIs do
			kinds[p.kind] = (kinds[p.kind] or 0) + 1
			t.ok(inBounds(p.cframe.Position), "POI in bounds " .. p.id)
			local hit, who = footprintOnRoad(p.cframe, p.size, false)
			t.ok(not hit, p.id .. " overlaps road " .. tostring(who))
			-- entrance sits on the curb of its frontage edge (or at the dead end it faces)
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
			t.ok(d <= e.width / 2 + 1.5, "entrance on the curb of " .. p.id)
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
					"Chiliad",
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
		t.ok(kinds.chop >= 3, "chop shops spread out (gameplay critique 8)")
	end)

	t.test("plots: 8 garages, spread out, near on-ramps, clear, level, facing the skyline", function()
		t.eq(#W.Plots, 8, "8 plots (max 8 players)")
		t.eq(Q.plotCount(), 8, "plotCount")
		local pinnacle = Q.poi("PinnacleTower").cframe.Position
		for i, p in ipairs(W.Plots) do
			t.eq(p.index, i, "plot index")
			t.ok(inBounds(p.cframe.Position), "plot in bounds")
			t.ok(WG.pointInPoly(W.ActiveCore, p.cframe.Position.X, p.cframe.Position.Z), "plot in the Active Core")
			local hit, who = footprintOnRoad(p.cframe, p.size, true)
			t.ok(not hit, "plot " .. i .. " overlaps road " .. tostring(who))
			t.ok(p.onRampSeconds <= 90, ("plot %d is %.0f s from an on-ramp"):format(i, p.onRampSeconds))
			-- door faces the street: a point just past the curb in front of the door is on the plot's own road
			local e = W.Edges[p.edge]
			local front = p.door + p.cframe.LookVector * (e.sidewalk + 14 + 6)
			local rp, ej, _, d = Q.nearestRoadPoint(front, { ignoreHeight = true, maxDistance = 200 })
			t.ok(
				rp ~= nil and W.Edges[ej].name == e.name and d <= e.width / 2,
				"plot " .. i .. " door faces its street"
			)
			t.eq(Q.plotAt(p.cframe.Position + Vector3.new(0, 5, 0)), i, "plotAt finds plot " .. i)
			-- tech critique 13: the garage floor stands on level ground (a pad)
			local o = obbOf(p.cframe, p.size, 4)
			for _, c in WG.obbCorners(o) do
				local h = W.heightAt(c.x, c.z)
				t.ok(
					math.abs(h - (p.cframe.Position.Y - S.CURB_HEIGHT)) <= 2.5,
					("plot %d footprint is level (%.1f vs %.1f)"):format(i, h, p.cframe.Position.Y)
				)
			end
			-- gameplay critiques 1, 8: police far, services near
			t.ok(p.service.police >= 1000, ("plot %d police only %d road studs away"):format(i, p.service.police))
			t.ok(p.service.gunshop <= 2000, ("plot %d gun shop %d"):format(i, p.service.gunshop))
			t.ok(p.service.dealership <= 4000, ("plot %d dealership %d"):format(i, p.service.dealership))
			t.ok(p.service.chop <= 5000, ("plot %d chop %d"):format(i, p.service.chop))
			t.ok(p.service.spray <= 3000, ("plot %d spray %d"):format(i, p.service.spray))
			-- gta critique 9: the first frame out of the door frames the skyline (Palmera faces the ocean)
			if i ~= 1 then
				local tp = flat(pinnacle - p.door).Unit
				local ang = math.deg(math.acos(math.clamp(tp:Dot(flat(p.cframe.LookVector).Unit), -1, 1)))
				t.ok(ang <= 40, ("plot %d door is %.0f deg off Pinnacle Tower"):format(i, ang))
			end
			for j = i + 1, #W.Plots do
				local q = W.Plots[j]
				local dd = (flat(p.cframe.Position) - flat(q.cframe.Position)).Magnitude
				t.ok(dd >= 900, ("plots %d and %d only %d apart (raids need a getaway drive)"):format(i, j, dd))
				local _, road = Q.route(p.door, q.door, { shortest = true })
				t.ok(road >= 1200, ("plots %d and %d only %d road studs apart"):format(i, j, road))
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
		-- onboarding order: the best first-session plots first (gameplay critique 12)
		t.eq(#W.OnboardingOrder, 8, "onboarding order")
		t.ok(W.Plots[W.OnboardingOrder[1]].onboardingOk, "the first onboarding plot passes the onboarding rule")
	end)

	---------------------------------------------------------------------------------------------------------------
	-- Spawns, zones, routes
	---------------------------------------------------------------------------------------------------------------

	t.test("street parking spots sit in the curb lane, outside junctions; tiers spread", function()
		local spots = W.Spawns.parking
		t.ok(#spots >= 2000, "parking spots: " .. #spots)
		local tiers = {}
		for i, sp in spots do
			tiers[sp.tier] = (tiers[sp.tier] or 0) + 1
			if i % 7 == 0 then
				local p = sp.cframe.Position
				t.ok(inBounds(p), "spot in bounds")
				t.ok(Q.isOnRoad(p), "spot on the road surface")
				local it = Q.intersectionAt(p, 4)
				t.ok(it == nil, ("spot inside junction at %d,%d"):format(p.X, p.Z))
				t.ok(math.abs(sp.cframe.LookVector.Y) < 0.05, "spot is level")
			end
		end
		for _, sp in W.Spawns.offstreet do
			tiers[sp.tier] = (tiers[sp.tier] or 0) + 1
			t.ok(not Q.isOnRoad(sp.cframe.Position), "off-street spot is off the road")
		end
		local total = 0
		for _, n in tiers do
			total += n
		end
		-- gameplay critique 13 / tech critique 15: no tier dominates; rare tiers exist in numbers
		for _, tier in { "beater", "sedan", "muscle", "sports" } do
			local share = (tiers[tier] or 0) / total
			t.ok(share >= 0.08 and share <= 0.5, ("tier %s share %.2f"):format(tier, share))
		end
		t.ok((tiers.super or 0) >= 100, "super spots: " .. tostring(tiers.super))
		t.ok((tiers.hyper or 0) >= 60, "hyper spots: " .. tostring(tiers.hyper))
	end)

	t.test("police spawns on traffic lanes next to every station; HQ has 12", function()
		local stations = {}
		for _, s in W.Spawns.police do
			stations[s.station] = (stations[s.station] or 0) + 1
			t.ok(Q.isOnRoad(s.cframe.Position), "police spawn on road")
		end
		for _, p in Q.poisOfKind("police") do
			t.ok((stations[p.id] or 0) >= 4, "spawns for " .. p.id)
		end
		t.ok((stations.PoliceHQ or 0) >= 12, "HQ lanes: " .. tostring(stations.PoliceHQ))
		t.ok(#W.Spawns.hospital >= 3, "hospital respawns")
		t.ok(#W.Spawns.traffic >= 200, "traffic spawn edges")
	end)

	t.test("hot drops: pools, reach, restricted flags, respawns (gameplay critiques 5, 6, 14)", function()
		t.ok(#W.HotDrops >= 10, "hot drop zones")
		local normal = 0
		for _, z in W.HotDrops do
			local p = z.cframe.Position
			t.ok(inBounds(p), z.id .. " in bounds")
			t.ok(W.gradeAt(p.X, p.Z) > W.SEA_LEVEL, z.id .. " on land")
			local rp = Q.nearestRoadPoint(p, { maxDistance = 260, ignoreHeight = true })
			t.ok(rp ~= nil, z.id .. " reachable by road")
			if z.pool == "normal" then
				normal += 1
				t.ok(WG.pointInPoly(W.ActiveCore, p.X, p.Z), z.id .. " (normal) inside the Active Core")
				t.ok((z.garagesWithin60s or 0) >= 5, ("%s within 60 s of %d garages"):format(z.id, z.garagesWithin60s))
			end
			for _, rz in W.RestrictedZones do
				local lp = rz.cframe:PointToObjectSpace(p)
				if math.abs(lp.X) <= rz.size.X / 2 and math.abs(lp.Z) <= rz.size.Z / 2 then
					t.ok(z.heat ~= nil or z.pool == "longhaul", z.id .. " inside " .. rz.id .. " without a flag")
				end
			end
			t.ok(W.EtaFields[z.id] ~= nil, "ETA field for " .. z.id)
		end
		t.ok(normal >= 8, "normal pool: " .. normal)
		local eta = Q.eta("hd_plaza", W.Plots[3].door)
		t.ok(eta ~= nil and eta > 10 and eta < 400, "ETA plaza from plot 3: " .. tostring(eta))
	end)

	t.test("stunt jumps: ballistic, flagged inside restricted zones; landmarks and helipads", function()
		t.ok(#W.StuntJumps >= 10, "stunt jumps: " .. #W.StuntJumps)
		for _, j in W.StuntJumps do
			t.ok(inBounds(j.cframe.Position) and inBounds(j.landing, 400), j.id .. " in bounds")
			t.ok(j.airtime >= 0.25, ("%s airtime %.2f"):format(j.id, j.airtime))
			-- the landing is where a Scale.GRAVITY arc from the lip at minSpeed comes down
			local look = j.cframe.LookVector
			local a = math.rad(j.angle)
			local vh, vy = j.minSpeed * math.cos(a), j.minSpeed * math.sin(a)
			local tt = j.airtime
			local x = j.cframe.Position.X + look.X * vh * tt
			local z = j.cframe.Position.Z + look.Z * vh * tt
			local y = j.cframe.Position.Y + vy * tt - 0.5 * S.GRAVITY * tt * tt
			t.ok((Vector3.new(x, y, z) - j.landing).Magnitude < 40, j.id .. " landing on the arc")
			for _, rz in W.RestrictedZones do
				local lp = rz.cframe:PointToObjectSpace(j.cframe.Position)
				if math.abs(lp.X) <= rz.size.X / 2 and math.abs(lp.Z) <= rz.size.Z / 2 then
					t.ok(j.heat ~= nil, j.id .. " inside " .. rz.id .. " without heat")
				end
			end
		end
		for _, l in W.Landmarks do
			t.ok(inBounds(l.cframe.Position, 600), l.id .. " in bounds")
		end
		t.ok(Q.landmark("SunwoodSign") ~= nil, "giant hillside letter sign")
		t.ok(Q.landmark("IronBayBridge") ~= nil, "cable-stayed port bridge")
		t.ok(#W.Helipads >= 5, "helipads")
	end)

	t.test("SUNWOOD sign: on the ridge, facing the city, visible from the vistas (gta critique 3)", function()
		local sign = Q.landmark("SunwoodSign")
		t.ok(sign.cframe.Position.Y >= 450, "sign base on the summit ridge: " .. sign.cframe.Position.Y)
		t.ok(sign.cframe.LookVector.Z > 0.9, "sign faces the city (south)")
		-- the skyline clusters (gta critique 1) hide it from Echo Park and the pier (Gilded Mile and Palmera North
		-- towers stand in the line of sight): it must hold from the freeway decks and downtown
		for _, name in { "H1 west deck", "H1 north-west deck", "Liberty at Crown" } do
			local n = W.SignVisibility[name]
			t.ok(n and n >= 5, ("sign visible %s/9 from %s"):format(tostring(n), name))
		end
	end)

	t.test("routes: armored runs and races resolve; armored runs keep clear (gameplay critique 9)", function()
		local armored, races = 0, 0
		for _, r in W.Routes do
			t.ok(#r.path >= 2 and r.length > 500, "route " .. r.id .. " has a path")
			t.ok(#r.edges >= 1 and r.seconds > 0, "route " .. r.id .. " has edges + time")
			if r.kind == "armored" then
				armored += 1
				t.ok(r.length >= 2500 and r.length <= 9000, ("armored %s length %d"):format(r.id, r.length))
				t.ok(r.policeClear >= 100, ("armored %s passes %d from a police entrance"):format(r.id, r.policeClear))
				t.ok(r.doorClear >= 100, ("armored %s passes %d from a garage door"):format(r.id, r.doorClear))
			elseif r.kind == "race" then
				races += 1
			end
		end
		t.ok(armored >= 5, "armored truck routes")
		t.ok(races >= 6, "race routes")
		-- every garage within 1,500 of at least one run
		for i, p in W.Plots do
			local best = math.huge
			for _, r in W.Routes do
				if r.kind == "armored" then
					for _, q in r.path do
						best = math.min(best, (flat(q) - flat(p.door)).Magnitude)
					end
				end
			end
			t.ok(best <= 1500, ("plot %d is %d from the nearest armored run"):format(i, best))
		end
	end)

	t.test("roadblocks, the lift bridge, heist drop-offs and car swaps (gameplay critiques 10, 11)", function()
		t.ok(#W.Roadblocks >= 80, "roadblock anchors: " .. #W.Roadblocks)
		local kinds, trap = {}, 0
		for _, rb in W.Roadblocks do
			kinds[rb.kind] = (kinds[rb.kind] or 0) + 1
			if rb.trap then
				trap += 1
			end
			t.ok(Q.isOnRoad(rb.cframe.Position), "roadblock on its road")
		end
		for _, k in { "straight", "bridge", "terminal", "pass" } do
			t.ok((kinds[k] or 0) > 0, "roadblock kind " .. k)
		end
		t.ok(trap >= 2, "port bridges marked as traps")
		t.ok(W.LiftBridge ~= nil and W.LiftBridge.period > 0, "Harbor lift bridge event")
		t.eq(#W.HeistDropoffs, 3, "one drop-off per heist exit")
		t.ok(#W.CarSwaps >= 3, "car swaps")
		local ramps = 0
		for _, e in W.Edges do
			if e.name:find("^Channel Ramp") then
				ramps += 1
			end
		end
		t.ok(ramps >= 4, "channel ramps (no single-exit trench): " .. ramps)
	end)

	t.test("streetscape: lamps, palms, trees, poles, billboards placed off the asphalt", function()
		local sc = W.Streetscape
		t.ok(#sc.lamp >= 1000, "lamps: " .. #sc.lamp)
		t.ok(#sc.palm >= 500, "palms: " .. #sc.palm)
		t.ok(#sc.tree >= 500, "trees: " .. #sc.tree)
		t.ok(#sc.pole >= 200, "utility poles: " .. #sc.pole)
		t.ok(#sc.billboard >= 20, "billboards: " .. #sc.billboard)
		t.ok(#sc.busstop >= 50, "bus stops: " .. #sc.busstop)
		for _, kind in { "lamp", "palm", "tree", "pole", "busstop", "hydrant" } do
			for i, it in sc[kind] do
				if i % 5 == 0 and not it.median then
					local p = it.pos
					t.ok(
						not Q.isOnRoad(p - Vector3.new(0, 0.5, 0)),
						("%s %d on the asphalt at %d,%d"):format(kind, i, p.X, p.Z)
					)
				end
			end
		end
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
		local p, ei, s = Q.nearestRoadPoint(Vector3.new(410, 12, -252))
		t.ok(p ~= nil and W.Edges[ei].name == "Crown Boulevard", "nearest road is Crown: " .. W.Edges[ei].name)
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
		t.ok(Q.parcelAt(Vector3.new(520, 12, -250)) == nil, "no lot on Crown Boulevard")
	end)

	t.test("WorldQuery: freeway lanes sit where they are painted (uneven shoulders)", function()
		for _, e in W.Edges do
			if e.class == "freeway" then
				local s = e.length / 2
				local c, tan = Q.edgePoint(e.id, s)
				local right = Vector3.new(-tan.Z, 0, tan.X)
				local inner = (Q.laneCFrame(e.id, 1, 1, s).Position - c):Dot(right)
				local outer = (Q.laneCFrame(e.id, e.lanesF, 1, s).Position - c):Dot(right)
				t.near(inner, -e.width / 2 + e.shoulderIn + S.LANE / 2, 0.01, "inner lane")
				t.near(outer, e.width / 2 - e.shoulderOut - S.LANE / 2, 0.01, "outer lane")
				break
			end
		end
	end)

	t.test("WorldQuery: deck vs street under it", function()
		local ring
		for _, e in W.Edges do
			if e.class == "freeway" and e.corridor == "H1 Ring Freeway" and e.elevated and e.length > 300 then
				ring = e
				break
			end
		end
		local mid = ring.points[math.floor(#ring.points / 2)]
		local _, onDeck = Q.nearestRoadPoint(mid)
		t.eq(W.Edges[onDeck].class, "freeway", "on the deck")
		t.ok(Q.isOnRoad(mid + Vector3.new(0, 1, 0)), "deck is road")
	end)

	t.test("WorldQuery: signals cycle deterministically", function()
		local it
		for _, i in W.Intersections do
			if i.control == "signal" and #i.phases >= 2 and i.phases[1].movement == "all" then
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
			local other = it.phases[2].approaches[1]
			if other then
				t.ok(not (st == "green" and Q.signalState(it.id, other, tm) == "green"), "conflicting greens")
			end
		end
		t.ok(greens > 0 and reds > 0, "cycles green and red")
	end)

	t.test("WorldQuery: time-weighted routing takes the freeway; polylines stay on the roads", function()
		-- tech critique 2: Palmera -> Rust Flats garage is mostly freeway
		local pts, len, edges = Q.route(W.Plots[1].door, W.Plots[5].door, { traffic = true })
		t.ok(pts ~= nil and len > 1000, "garage to garage")
		t.ok(Q.routeLength(pts) >= len * 0.9, "polyline length matches")
		local fw = 0
		for _, signed in edges do
			local e = W.Edges[math.abs(signed)]
			if e.class == "freeway" or e.class == "ramp" then
				fw += e.length
			end
		end
		t.ok(fw >= len * 0.5, ("freeway share %.0f of %.0f"):format(fw, len))
		local _, lenShort = Q.route(W.Plots[1].door, W.Plots[5].door, { traffic = true, shortest = true })
		t.ok(lenShort <= len, "shortest is shorter than fastest")
		-- tech critique 3: every polyline sample lies on some road (no chords through blocks), incl. the first leg
		local function onSomeRoad(p)
			local ok = false
			WG.segQuery(segs, p.X, p.Z, 0, function(id)
				if ok then
					return
				end
				local e = W.Edges[segs.owner[id]]
				local _, _, _, d = WG.projectSeg(p.X, p.Z, segs.ax[id], segs.az[id], segs.bx[id], segs.bz[id])
				if d <= e.width / 2 + 2 then
					ok = true
				end
			end)
			return ok
		end
		local rng = H.Random.new(7)
		for _ = 1, 25 do
			local a = W.Spawns.parking[rng:NextInteger(1, #W.Spawns.parking)].cframe.Position
			local b = W.Spawns.parking[rng:NextInteger(1, #W.Spawns.parking)].cframe.Position
			local r = Q.route(a, b, { traffic = true })
			t.ok(r ~= nil, "route between parking spots")
			for k = 2, #r do
				local steps = math.max(1, math.ceil((r[k] - r[k - 1]).Magnitude / 20))
				for i = 0, steps do
					local p = r[k - 1]:Lerp(r[k], i / steps)
					t.ok(onSomeRoad(p), ("route leaves the road at %d,%d"):format(p.X, p.Z))
				end
			end
		end
		local lane = Q.nearestLane(Vector3.new(0, 12, 100))
		t.ok(lane ~= nil and Q.isOnRoad(lane.Position), "nearest lane is on a road")
		local h = Q.nearestPOI(Vector3.new(0, 12, 0), "hospital")
		t.ok(h ~= nil and h.kind == "hospital", "nearest hospital")
		for _, p in W.POIs do
			local r = Q.route(W.Plots[1].door, p.entrance)
			t.ok(r ~= nil, "POI reachable by road: " .. p.id)
		end
	end)

	t.test("terrain: sea, beach, hills, a peak, flat basin, channel, reservoir", function()
		t.ok(W.heightAt(-6200, 0) < W.SEA_LEVEL, "ocean west")
		t.near(W.heightAt(0, 0), W.GRADE, 0.01, "downtown is flat at grade")
		t.ok(W.gradeAt(-1300, -3100) > 150, "Sunwood Hills crest is high")
		t.ok(W.gradeAt(4300, -3030) > 700, "Mount Talon dominates the north-east (gta critique 2)")
		local beach = W.gradeAt(-5000, 0)
		t.ok(beach > W.SEA_LEVEL and beach < W.GRADE, "beach slope")
		local ch = W.Channel.points
		local mid = ch[math.floor(#ch / 2)]
		t.ok(W.heightAt(mid.x, mid.z) < 5, "Rust River channel floor is sunken")
		t.ok(Q.isWater(Vector3.new(700, 0, 3200)), "Iron Bay channel is water")
		t.ok(not Q.isWater(Vector3.new(mid.x, -5, mid.z)), "the Rust River channel is dry")
		local lake = W.Water[1]
		local cx, cz = WG.polyCentroid(lake.points)
		t.ok(Q.isWater(Vector3.new(cx, 70, cz)), "the reservoir is water")
	end)
end
