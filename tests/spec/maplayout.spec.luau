--!nocheck
-- Geometry sanity for the city layout.
return function(t)
	local H = t.H
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local MapConfig = H.require("src/shared/Config/Map")
	local Vector3 = H.roblox.Vector3

	t.test("plots face their entrance road", function()
		for i = 1, MapLayout.plotCount() do
			local o = MapLayout.plotOrigin(i)
			-- the point 60 studs out the front door must be on a road
			local front = (o * H.roblox.CFrame.new(0, 0, -(MapConfig.GRID_SPACING / 2))).Position
			t.ok(MapLayout.isOnRoad(front), "plot " .. i .. " front not on road: " .. tostring(front))
		end
	end)
	t.test("slots are inside the garage and not in the dropoff", function()
		for i = 1, MapLayout.plotCount() do
			local icf, isize = MapLayout.plotInteriorZone(i)
			local dcf, dsize = MapLayout.plotDropoffZone(i)
			for s = 1, MapLayout.maxPhysicalSlots() do
				local p = MapLayout.slotWorld(i, s).Position + Vector3.new(0, 2, 0)
				t.ok(MapLayout.isInBox(icf, isize, p), ("plot %d slot %d outside interior"):format(i, s))
				t.ok(not MapLayout.isInBox(dcf, dsize, p), ("plot %d slot %d in dropoff"):format(i, s))
				t.eq(MapLayout.plotAt(p), i, "plotAt")
			end
		end
	end)
	t.test("plots don't overlap POIs", function()
		local used = {}
		for _, def in MapConfig.Plots do
			used[def.block.x .. "," .. def.block.z] = "plot"
		end
		for name, b in MapConfig.Blocks do
			t.ok(used[b.x .. "," .. b.z] == nil, name .. " overlaps a plot")
			used[b.x .. "," .. b.z] = name
		end
	end)
	t.test("parking spots are on roads, away from intersections and plot driveways", function()
		local spots = MapLayout.parkingSpots()
		t.ok(#spots >= 50, "enough parking spots: " .. #spots)
		for _, cf in spots do
			local p = cf.Position
			t.ok(MapLayout.isOnRoad(p), "spot off road " .. tostring(p))
			-- not inside an intersection box
			local S = MapConfig.GRID_SPACING
			local rx = math.abs(p.X - math.round(p.X / S) * S)
			local rz = math.abs(p.Z - math.round(p.Z / S) * S)
			t.ok(not (rx <= 28 and rz <= 28), "spot in intersection " .. tostring(p))
			for i = 1, MapLayout.plotCount() do
				local o = MapLayout.plotOrigin(i)
				local lp = o:PointToObjectSpace(p)
				local inDriveway = math.abs(lp.X) < 24 and lp.Z < -40 and lp.Z > -100
				t.ok(not inDriveway, "spot blocks plot " .. i .. " driveway")
			end
		end
	end)
	t.test("hot drops on roads", function()
		for _, cf in MapLayout.hotDropCFrames() do
			t.ok(MapLayout.isOnRoad(cf.Position), "hot drop off road")
		end
	end)
	t.test("lanes are on the right side", function()
		local cf = MapLayout.laneCFrame("Z", 0, 100, 1) -- driving +Z on x=0 road
		-- facing +Z, right-hand side is -X in Roblox (RightVector of lookAt +Z is -X)
		t.near(cf.Position.X, -MapConfig.LANE_OFFSET, 1e-6, "lane x")
		t.near(cf.LookVector.Z, 1, 1e-6)
	end)
	t.test("police spawns on roads", function()
		for _, cf in MapLayout.policeSpawns() do
			t.ok(MapLayout.isOnRoad(cf.Position))
		end
	end)
	t.test("dealer pads inside dealership block", function()
		local c = MapLayout.poiCenter("Dealership")
		for _, cf in MapLayout.dealerPads() do
			local d = cf.Position - c
			t.ok(math.abs(d.X) < 52 and math.abs(d.Z) < 52)
		end
	end)
end
