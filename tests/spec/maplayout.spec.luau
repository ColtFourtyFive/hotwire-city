--!nocheck
-- MapLayout (v2 compatibility shim): every function a consumer calls exists and answers from the v2 world.
return function(t)
	local H = t.H
	H.setMode("server")
	local fs = require("@lune/fs")
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local MapConfig = H.require("src/shared/Config/Map")
	local WorldLayout = H.require("src/shared/Config/WorldLayout")
	local WorldQuery = H.require("src/shared/Util/WorldQuery")
	local RoadGraph = H.require("src/shared/Util/RoadGraph")
	local Vector3 = H.roblox.Vector3
	local CFrame = H.roblox.CFrame

	local function flatDist(a, b)
		return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
	end
	local function inFootprint(poi, pos, slack)
		local lp = poi.cframe:PointToObjectSpace(pos)
		local s = slack or 0
		return math.abs(lp.X) <= poi.size.X / 2 + s and math.abs(lp.Z) <= poi.size.Z / 2 + s
	end

	t.test("consumer contract: every MapLayout.<name> used in src exists in the shim", function()
		local used = {}
		local function scan(dir)
			for _, e in fs.readDir(dir) do
				local path = dir .. "/" .. e
				if fs.isDir(path) then
					scan(path)
				elseif e:match("%.luau$") and path ~= "src/shared/Util/MapLayout.luau" then
					for name in fs.readFile(path):gmatch("MapLayout%.([%a_][%w_]*)") do
						used[name] = path
					end
				end
			end
		end
		scan("src")
		local n = 0
		for name, path in used do
			if name ~= "Axis" then -- a type
				n += 1
				t.ok(MapLayout[name] ~= nil, ("MapLayout.%s (used by %s) is missing"):format(name, path))
			end
		end
		t.ok(n >= 25, "consumers scanned: " .. n)
		-- v2/combat's API is part of the contract too
		for _, name in { "hospitals", "hospitalCFrame", "gunStores", "safeZones", "safeZoneAt" } do
			t.ok(type(MapLayout[name]) == "function", name)
		end
	end)

	t.test("first spawn: on a downtown sidewalk, mid-block, clear, facing the skyline (VIBE_ROUTING #2)", function()
		local cf = MapLayout.spawnCFrame()
		local feet = cf.Position - Vector3.new(0, MapLayout.SPAWN_ROOT, 0)
		t.near(feet.Y, MapLayout.CURB_TOP, 0.05, "feet on the sidewalk top")
		t.eq(WorldLayout.districtAt(feet.X, feet.Z), "downtown", "in Pinnacle Heights")
		t.ok(not WorldQuery.isOnRoad(feet), "not on the asphalt")
		local plaza = WorldQuery.poi("HotwirePlaza")
		local e = WorldLayout.Edges[plaza.edge]
		local p, ei = WorldQuery.nearestRoadPoint(feet, { maxDistance = 200 })
		t.eq(ei, plaza.edge, "beside the plaza's street")
		local off = flatDist(feet, p)
		t.ok(
			off > e.width / 2 and off < e.width / 2 + e.sidewalk,
			("on its sidewalk (%.1f from the centreline)"):format(off)
		)
		-- not inside the plaza, another POI, a plot or a building parcel
		for _, poi in WorldLayout.POIs do
			t.ok(not inFootprint(poi, feet), "inside POI " .. poi.id)
		end
		for i = 1, MapLayout.plotCount() do
			t.ok(MapLayout.plotAt(feet + Vector3.new(0, 3, 0)) ~= i, "inside garage " .. i)
		end
		t.ok(WorldQuery.parcelAt(feet) == nil, "inside a building parcel")
		-- mid-block: outside every junction box
		for _, it in WorldLayout.Intersections do
			t.ok(flatDist(it.pos, feet) > it.radius + 10, "in junction " .. it.id)
		end
		-- nothing of the streetscape to spawn into
		for kind, list in WorldLayout.Streetscape do
			for _, pl in list do
				t.ok(flatDist(pl.pos, feet) > 4, ("%s %.1f studs from the spawn"):format(kind, flatDist(pl.pos, feet)))
			end
		end
		-- facing along the boulevard, toward the tall towers (the parcels ahead are taller than the ones behind)
		local _, tan = WorldQuery.edgePoint(plaza.edge, MapLayout.SPAWN_S)
		t.ok(math.abs(cf.LookVector:Dot(tan)) > 0.99, "looks along the street")
		local ahead, behind = 0, 0
		for _, parcel in WorldLayout.Parcels do
			local d = parcel.cframe.Position - feet
			if d.Magnitude < 900 and parcel.size.Y > 0 then
				if d:Dot(cf.LookVector) > 0 then
					ahead = math.max(ahead, parcel.size.Y)
				else
					behind = math.max(behind, parcel.size.Y)
				end
			end
		end
		t.ok(ahead > behind, ("skyline ahead (%d) taller than behind (%d)"):format(ahead, behind))
		t.ok(flatDist(feet, WorldLayout.Spawns.default.Position) < 300, "a few steps from Hotwire Plaza")
	end)

	t.test("plots: v1 plot-local layout on the v2 plot frames", function()
		t.eq(MapLayout.plotCount(), #WorldLayout.Plots)
		t.eq(MapLayout.plotCount(), 8)
		for i = 1, MapLayout.plotCount() do
			local o = MapLayout.plotOrigin(i)
			t.eq(o, WorldLayout.Plots[i].cframe, "origin = plot frame")
			local icf, isize = MapLayout.plotInteriorZone(i)
			local dcf, dsize = MapLayout.plotDropoffZone(i)
			for s = 1, MapLayout.maxPhysicalSlots() do
				local p = MapLayout.slotWorld(i, s).Position + Vector3.new(0, 2, 0)
				t.ok(MapLayout.isInBox(icf, isize, p), ("plot %d slot %d outside interior"):format(i, s))
				t.ok(not MapLayout.isInBox(dcf, dsize, p), ("plot %d slot %d in dropoff"):format(i, s))
				t.eq(MapLayout.plotAt(p), i, "plotAt")
			end
			t.ok(MapLayout.isInBox(icf, isize, dcf.Position), "drop-off inside the garage")
			local w = MapLayout.plotToWorld(i, MapConfig.Garage.OWNER_SPAWN)
			t.near((w.Position - (o * CFrame.new(MapConfig.Garage.OWNER_SPAWN)).Position).Magnitude, 0, 1e-6)
		end
	end)

	t.test("plots face their entrance road", function()
		for i = 1, MapLayout.plotCount() do
			local o = MapLayout.plotOrigin(i)
			local plot = WorldLayout.Plots[i]
			-- the point just past the reserved footprint's front edge is on (or at the curb of) a road
			local front = (o * CFrame.new(0, 0, -(plot.size.Z / 2 + 14))).Position
			local p, _, _, d = WorldQuery.nearestRoadPoint(front, { maxDistance = 120, ignoreHeight = true })
			t.ok(p ~= nil and d < 60, ("plot %d front %.0f studs from a road"):format(i, d))
			t.ok(MapLayout.isOnRoad(plot.curbSpot.Position), "plot " .. i .. " curb spot on the road")
		end
	end)

	t.test("POIs: v1 names and v2 ids resolve on the island", function()
		for _, name in
			{
				"SpawnPlaza",
				"Dealership",
				"PoliceHQ",
				"GearShop",
				"SprayShopA",
				"SprayShopB",
				"ChopShop",
				"StuntPark",
				"Park",
				"Pier",
				"PinnacleTower",
				"SunwoodSign",
			}
		do
			local c = MapLayout.poiCenter(name)
			t.ok(c.Y > WorldLayout.SEA_LEVEL - 1 and c.Y < 1100, name .. " height")
			t.ok(c.X > WorldLayout.Bounds.playMinX and c.X < WorldLayout.Bounds.playMaxX, name .. " in bounds")
		end
		local plaza = WorldQuery.poi("HotwirePlaza")
		t.ok(inFootprint(plaza, WorldLayout.Spawns.default.Position), "hub point on Hotwire Plaza")
		local hq = WorldQuery.poi("PoliceHQ")
		t.ok(flatDist(MapLayout.bustedReleaseCFrame().Position, hq.cframe.Position) < 200, "release at HQ")
	end)

	t.test("dealer pads: v1 showroom layout inside Hotwire Motors, cars face -Z", function()
		local poi = WorldQuery.poi("Dealership")
		local pads = MapLayout.dealerPads()
		t.eq(#pads, 8)
		for _, cf in pads do
			t.ok(inFootprint(poi, cf.Position), "pad on the lot")
			t.near(cf.LookVector.Z, -1, 1e-6, "faces -Z (the drive-out)")
			t.near(cf.Position.Y, poi.cframe.Position.Y + WorldLayout.Scale.CURB_HEIGHT, 1e-4, "on the lot")
		end
	end)

	t.test("drive-in bays and counters sit in their POIs, bays open to the street", function()
		local sprays = MapLayout.sprayZones()
		t.eq(#sprays, #WorldQuery.poisOfKind("spray"))
		local function check(kind, zones)
			for _, z in zones do
				local owner = nil
				for _, poi in WorldQuery.poisOfKind(kind) do
					if inFootprint(poi, z.cframe.Position) then
						owner = poi
					end
				end
				t.ok(owner ~= nil, kind .. " bay inside a POI")
				if owner then
					local lp = owner.cframe:PointToObjectSpace(z.cframe.Position)
					t.ok(lp.Z - z.size.Z / 2 < -owner.size.Z / 2 + 10, kind .. " bay opens to the street")
					t.ok(z.size.X >= 50 and z.size.Y >= 20, kind .. " bay fits a car")
				end
			end
		end
		check("spray", sprays)
		check("chop", MapLayout.chopZones())
		local cf, size = MapLayout.chopZone()
		t.ok(inFootprint(WorldQuery.poi("ChopShop"), cf.Position) and size.X > 0, "v1 chopZone = Rusty's")
		local counters = MapLayout.gearShopCounters()
		t.eq(#counters, #WorldQuery.poisOfKind("gunshop"))
		t.eq(MapLayout.gearShopCounter(), counters[1])
		for _, g in MapLayout.gunStores() do
			local poi = WorldQuery.poi(g.name)
			t.ok(poi ~= nil and inFootprint(poi, g.cframe.Position), "gun store spot in its shop")
		end
	end)

	t.test("roads: lanes, spawns, hot drops and parking are on v2 roads", function()
		for _, cf in MapLayout.policeSpawns() do
			t.ok(MapLayout.isOnRoad(cf.Position), "police spawn on road " .. tostring(cf.Position))
		end
		t.eq(#MapLayout.policeSpawns(), #WorldLayout.Spawns.police)
		local drops = MapLayout.hotDropCFrames()
		t.eq(#drops, #WorldLayout.HotDrops)
		for _, cf in drops do
			t.ok(MapLayout.isOnRoad(cf.Position), "hot drop on road")
		end
		local spots = MapLayout.parkingSpots()
		t.eq(#spots, #WorldLayout.Spawns.parking)
		for k = 1, #spots, 37 do
			t.ok(MapLayout.isOnRoad(spots[k].Position), "parking spot on road")
		end
		-- nearestLane / laneCFrame / roadCFrame land on real lanes
		local rng = H.Random.new(5)
		for _ = 1, 40 do
			local p = Vector3.new(rng:NextNumber(-3000, 3000), 12, rng:NextNumber(-1800, 2400))
			local lane = MapLayout.nearestLane(p)
			t.ok(MapLayout.isOnRoad(lane.Position), "nearest lane on road")
		end
		local cf = MapLayout.laneCFrame("X", 0, 120, 1)
		t.ok(MapLayout.isOnRoad(cf.Position), "v1 laneCFrame snaps onto a lane")
		t.ok(cf.LookVector.X > -0.1, "heading kept (+X, or across when the nearest road runs N-S)")
		local rc = MapLayout.roadCFrame("Z", 1, -200, -1)
		t.ok(MapLayout.isOnRoad(rc.Position) and rc.LookVector.Z < 0.1, "v1 roadCFrame on a road, heading -Z")
	end)

	t.test("isOnRoad: true on edge centrelines, false inside lots", function()
		local n = 0
		for ei, e in WorldLayout.Edges do
			if ei % 9 == 0 then
				local p = WorldQuery.edgePoint(ei, e.length / 2)
				t.ok(MapLayout.isOnRoad(p), "centreline of edge " .. ei)
				n += 1
			end
		end
		t.ok(n > 50, "sampled edges")
		local lots = 0
		for k, p in WorldLayout.Parcels do
			if k % 11 == 0 and p.size.X > 40 and p.size.Z > 40 then
				lots += 1
				t.ok(not MapLayout.isOnRoad(p.cframe.Position + Vector3.new(0, 1, 0)), "lot centre off road " .. k)
			end
		end
		t.ok(lots > 50, "sampled lots")
	end)

	t.test("combat API: hospitals, gun stores, safe zones", function()
		local hospitals = MapLayout.hospitals()
		t.eq(#hospitals, #WorldLayout.Spawns.hospital)
		for _, h in hospitals do
			local near = WorldQuery.nearestPOI(h.cframe.Position, "hospital")
			t.ok(near and near.name == h.name, "named after the nearest hospital")
		end
		local cf, name = MapLayout.hospitalCFrame(hospitals[#hospitals].cframe.Position + Vector3.new(5, 0, 5))
		t.eq(name, hospitals[#hospitals].name)
		t.eq(cf, hospitals[#hospitals].cframe)
		local zones = MapLayout.safeZones()
		local kinds = {}
		for _, z in zones do
			kinds[z.kind] = (kinds[z.kind] or 0) + 1
		end
		t.eq(kinds.garage, 8)
		t.eq(kinds.gunstore, #WorldQuery.poisOfKind("gunshop"))
		t.ok((kinds.hospital or 0) >= 5 and (kinds.dealership or 0) >= 3, "data safe zones")
		t.eq(kinds.spray, #WorldQuery.poisOfKind("spray"))
		t.eq(kinds.release, 1)
		local icf = MapLayout.plotInteriorZone(3)
		local z = MapLayout.safeZoneAt(icf.Position)
		t.ok(z and z.kind == "garage" and z.plotIndex == 3, "inside garage 3")
		t.eq(MapLayout.safeZoneAt(Vector3.new(0, 600, 0)), nil, "nothing in the sky")
	end)

	t.test("GPS: RoadGraph uses the v2 world graph", function()
		t.ok(MapLayout.WORLD_VERSION ~= nil, "v2 shim")
		local g = RoadGraph.get()
		local _, edges = g:stats()
		t.ok(edges > 3000, "world graph edges: " .. edges)
		local segs = MapLayout.roadSegments()
		t.ok(#segs == edges or #segs >= edges, "roadSegments covers every polyline segment")
	end)
end
