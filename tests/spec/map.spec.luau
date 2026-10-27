--!nocheck
-- MapBuilder + LightingService: geometry contracts other systems rely on.
return function(t)
	local H = t.H
	H.setMode("server")
	local MapBuilder = H.require("src/server/Systems/MapBuilder")
	local LightingService = H.require("src/server/Systems/LightingService")
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local MapConfig = H.require("src/shared/Config/Map")
	local Vector3 = H.roblox.Vector3
	-- tag lookup within the built map (H.game is the raw DataModel; the CollectionService shim lives in module envs)
	local CollectionService = {
		GetTagged = function(_, tag)
			local out = {}
			for _, d in H.workspace:GetDescendants() do
				if d:HasTag(tag) then
					table.insert(out, d)
				end
			end
			return out
		end,
	}

	local folder = MapBuilder.build(H.workspace)
	local CURB_TOP = MapLayout.CURB_TOP
	local ROAD_Y = MapConfig.ROAD_Y

	local parts = {}
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end

	-- world AABB of a part (rotation-aware, conservative for balls/cylinders)
	local function aabb(p)
		local c = { p.CFrame:GetComponents() }
		local hx, hy, hz = p.Size.X / 2, p.Size.Y / 2, p.Size.Z / 2
		local ex = math.abs(c[4]) * hx + math.abs(c[5]) * hy + math.abs(c[6]) * hz
		local ey = math.abs(c[7]) * hx + math.abs(c[8]) * hy + math.abs(c[9]) * hz
		local ez = math.abs(c[10]) * hx + math.abs(c[11]) * hy + math.abs(c[12]) * hz
		return Vector3.new(c[1] - ex, c[2] - ey, c[3] - ez), Vector3.new(c[1] + ex, c[2] + ey, c[3] + ez)
	end
	local function boxAabb(cf, size)
		local c = { cf:GetComponents() }
		local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
		local ex = math.abs(c[4]) * hx + math.abs(c[5]) * hy + math.abs(c[6]) * hz
		local ey = math.abs(c[7]) * hx + math.abs(c[8]) * hy + math.abs(c[9]) * hz
		local ez = math.abs(c[10]) * hx + math.abs(c[11]) * hy + math.abs(c[12]) * hz
		return Vector3.new(c[1] - ex, c[2] - ey, c[3] - ez), Vector3.new(c[1] + ex, c[2] + ey, c[3] + ez)
	end
	local EPS = 0.02
	local function overlaps(amin, amax, bmin, bmax)
		return amin.X < bmax.X - EPS
			and amax.X > bmin.X + EPS
			and amin.Y < bmax.Y - EPS
			and amax.Y > bmin.Y + EPS
			and amin.Z < bmax.Z - EPS
			and amax.Z > bmin.Z + EPS
	end
	-- parts (above the floor) intersecting a world box
	local function blockers(bmin, bmax, floorTop, filter)
		local out = {}
		for _, p in parts do
			local pmin, pmax = aabb(p)
			if pmax.Y > floorTop + EPS and overlaps(pmin, pmax, bmin, bmax) and (filter == nil or filter(p)) then
				table.insert(out, p:GetFullName() .. " @" .. tostring(p.CFrame.Position))
			end
		end
		return out
	end

	t.test("overlap detector sanity (not vacuous)", function()
		local c = MapLayout.blockCenter(MapBuilder.LANDMARK_BLOCK.x, MapBuilder.LANDMARK_BLOCK.z)
		local hits = blockers(c - Vector3.new(10, 0, 10), c + Vector3.new(10, 50, 10), CURB_TOP + 0.05)
		t.ok(#hits > 0, "landmark tower should block its own footprint")
		local zcf, zsize = MapLayout.chopZone()
		local zmin, zmax = boxAabb(zcf, zsize)
		local around = blockers(zmin - Vector3.new(4, 0, 4), zmax + Vector3.new(4, 4, 0), CURB_TOP + 0.3)
		t.ok(#around > 0, "chop shop walls sit just outside the zone")
	end)

	t.test("map folder layout", function()
		t.eq(folder.Name, "Map")
		t.eq(folder.Parent, H.workspace)
		for _, name in { "Ground", "Roads", "Blocks", "Buildings", "POIs", "Props", "Beach", "Boundary" } do
			t.ok(folder:FindFirstChild(name), "missing subfolder " .. name)
		end
		t.eq(MapBuilder.getMapFolder(), folder, "getMapFolder")
	end)

	t.test("part budget and anchoring", function()
		t.ok(#parts > 3000, "suspiciously few parts: " .. #parts)
		t.ok(#parts <= MapBuilder.PART_BUDGET, ("map has %d parts (budget %d)"):format(#parts, MapBuilder.PART_BUDGET))
		for _, p in parts do
			t.ok(p.Anchored, "unanchored part " .. p:GetFullName())
			for i, v in { p.Size.X, p.Size.Y, p.Size.Z } do
				t.ok(v > 0 and v <= 2048, ("bad size axis %d on %s: %s"):format(i, p:GetFullName(), tostring(v)))
			end
		end
	end)

	t.test("rebuild replaces the old map", function()
		local again = MapBuilder.build(H.workspace)
		local count = 0
		for _, c in H.workspace:GetChildren() do
			if c.Name == "Map" then
				count += 1
			end
		end
		t.eq(count, 1, "exactly one Map folder")
		folder = again
		parts = {}
		for _, d in folder:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(parts, d)
			end
		end
	end)

	t.test("plot lots stay empty (PlotService builds there)", function()
		for i = 1, MapLayout.plotCount() do
			local cf, size = MapLayout.plotInteriorZone(i)
			local bmin, bmax = boxAabb(cf, size)
			local hits = blockers(bmin, bmax, CURB_TOP + 0.05)
			t.ok(#hits == 0, ("plot %d interior blocked by %s"):format(i, table.concat(hits, ", ")))
		end
	end)

	t.test("plot driveways have a curb-cut ramp", function()
		for i = 1, MapLayout.plotCount() do
			-- the sidewalk directly in front of the garage door
			local p = MapLayout.plotToWorld(
				i,
				Vector3.new(0, 0, -(MapConfig.GRID_SPACING - MapConfig.ROAD_WIDTH) / 2 + 4)
			).Position
			local found = false
			for _, part in folder.Blocks:GetChildren() do
				if
					part.Name == "DrivewayRamp"
					and (part.CFrame.Position - Vector3.new(p.X, part.CFrame.Position.Y, p.Z)).Magnitude < 1
				then
					found = true
					t.ok(part:IsA("WedgePart"), "ramp is a wedge")
					t.near(part.CFrame.Position.Y + part.Size.Y / 2, CURB_TOP, 1e-3, "ramp top flush with sidewalk")
					-- low edge (front) faces the road: LookVector points away from the plot
					local out = MapLayout.plotOrigin(i).LookVector
					t.ok(part.CFrame.LookVector:Dot(out) > 0.99, "ramp faces the road")
					t.ok(part.Size.X >= MapConfig.Garage.DOOR_WIDTH, "ramp wide enough")
				end
			end
			t.ok(found, "no driveway ramp in front of plot " .. i)
		end
	end)

	t.test("spray + chop zones are clear", function()
		for k, z in MapLayout.sprayZones() do
			local bmin, bmax = boxAabb(z.cframe, z.size)
			local hits = blockers(bmin, bmax, CURB_TOP + 0.3)
			t.ok(#hits == 0, ("spray zone %d blocked by %s"):format(k, table.concat(hits, ", ")))
		end
		local ccf, csize = MapLayout.chopZone()
		local bmin, bmax = boxAabb(ccf, csize)
		local hits = blockers(bmin, bmax, CURB_TOP + 0.3)
		t.ok(#hits == 0, "chop zone blocked by " .. table.concat(hits, ", "))
	end)

	t.test("dealer pads + north exit are clear", function()
		for i, cf in MapLayout.dealerPads() do
			local bmin, bmax = boxAabb(cf * H.roblox.CFrame.new(0, 4.5, 0), Vector3.new(10, 8, 16))
			local hits = blockers(bmin, bmax, CURB_TOP + 0.3)
			t.ok(#hits == 0, ("dealer pad %d blocked by %s"):format(i, table.concat(hits, ", ")))
		end
		-- corridor from the front row to the north road
		local c = MapLayout.poiCenter("Dealership")
		local bmin = Vector3.new(c.X - 44, CURB_TOP, c.Z - 62)
		local bmax = Vector3.new(c.X + 44, CURB_TOP + 8, c.Z - 30)
		local hits = blockers(bmin, bmax, CURB_TOP + 0.3, function(p)
			return p.CanCollide
		end)
		t.ok(#hits == 0, "dealership exit blocked by " .. table.concat(hits, ", "))
	end)

	t.test("roads: tagged, at ROAD_Y, under every hot drop + parking spot", function()
		local roads = {}
		for _, p in parts do
			if p:HasTag("Road") then
				table.insert(roads, p)
				t.near(p.CFrame.Position.Y + p.Size.Y / 2, ROAD_Y, 1e-3, "road top at ROAD_Y")
				t.ok(p.CanCollide and p.CanQuery, "road collidable")
			end
		end
		local lines = MapConfig.LINE_MAX - MapConfig.LINE_MIN + 1
		t.ok(#roads >= lines + lines * (lines - 1), "road count " .. #roads)
		local function onRoad(pos)
			for _, r in roads do
				local lp = r.CFrame:PointToObjectSpace(pos)
				if math.abs(lp.X) <= r.Size.X / 2 and math.abs(lp.Z) <= r.Size.Z / 2 then
					return true
				end
			end
			return false
		end
		for _, cf in MapLayout.hotDropCFrames() do
			t.ok(onRoad(cf.Position), "no road under hot drop " .. tostring(cf.Position))
		end
		for _, cf in MapLayout.parkingSpots() do
			t.ok(onRoad(cf.Position), "no road under parking spot " .. tostring(cf.Position))
		end
		for _, cf in MapLayout.policeSpawns() do
			t.ok(onRoad(cf.Position), "no road under police spawn " .. tostring(cf.Position))
		end
	end)

	t.test("road corridors are free of obstacles (car height)", function()
		local S, RW = MapConfig.GRID_SPACING, MapConfig.ROAD_WIDTH
		local function notRoad(p)
			return not p:HasTag("Road") and p.Parent and p.Parent.Name ~= "Markings"
		end
		for line = MapConfig.LINE_MIN, MapConfig.LINE_MAX do
			local c = line * S
			local ext = MapConfig.HALF_EXTENT + RW / 2
			-- X road and Z road, full length
			local hitsX = blockers(
				Vector3.new(-ext, ROAD_Y + 0.3, c - RW / 2),
				Vector3.new(ext, ROAD_Y + 8, c + RW / 2),
				ROAD_Y + 0.3,
				notRoad
			)
			t.ok(#hitsX == 0, ("X road %d blocked by %s"):format(line, table.concat(hitsX, ", ")))
			local hitsZ = blockers(
				Vector3.new(c - RW / 2, ROAD_Y + 0.3, -ext),
				Vector3.new(c + RW / 2, ROAD_Y + 8, ext),
				ROAD_Y + 0.3,
				notRoad
			)
			t.ok(#hitsZ == 0, ("Z road %d blocked by %s"):format(line, table.concat(hitsZ, ", ")))
		end
	end)

	t.test("parked-car spots are clear", function()
		for _, cf in MapLayout.parkingSpots() do
			local bmin, bmax = boxAabb(cf * H.roblox.CFrame.new(0, 3.3, 0), Vector3.new(7, 6, 14))
			local hits = blockers(bmin, bmax, ROAD_Y + 0.3)
			t.ok(#hits == 0, "parking spot blocked by " .. table.concat(hits, ", "))
		end
	end)

	t.test("buildings stay inside their lots (sidewalks clear)", function()
		local S = MapConfig.GRID_SPACING
		local lotHalf = (S - MapConfig.ROAD_WIDTH) / 2 - MapConfig.SIDEWALK_WIDTH
		for _, m in folder.Buildings:GetChildren() do
			local pivot = m:GetPivot().Position
			local bx, bz = MapLayout.blockAt(pivot)
			local c = MapLayout.blockCenter(bx, bz)
			for _, p in m:GetDescendants() do
				if p:IsA("BasePart") then
					local pmin, pmax = aabb(p)
					local ok = pmin.X >= c.X - lotHalf - 0.6
						and pmax.X <= c.X + lotHalf + 0.6
						and pmin.Z >= c.Z - lotHalf - 0.6
						and pmax.Z <= c.Z + lotHalf + 0.6
					t.ok(ok, ("%s.%s leaves its lot (block %d,%d)"):format(m.Name, p.Name, bx, bz))
				end
			end
			t.ok(m:HasTag("AssetSlot"), "building tagged AssetSlot")
			t.eq(m:GetAttribute("Category"), "Buildings")
		end
		t.ok(#folder.Buildings:GetChildren() > 200, "enough buildings: " .. #folder.Buildings:GetChildren())
	end)

	t.test("spawn plaza: SpawnLocation + leaderboards", function()
		local spawnCf = MapLayout.spawnCFrame()
		local spawns = {}
		for _, d in folder:GetDescendants() do
			if d:IsA("SpawnLocation") then
				table.insert(spawns, d)
			end
		end
		t.eq(#spawns, 1, "one SpawnLocation")
		local sp = spawns[1]
		t.ok(sp.Neutral, "neutral")
		t.eq(sp.Duration, 0, "no forcefield")
		t.near(sp.CFrame.Position.X, spawnCf.Position.X, 1e-3, "spawn x")
		t.near(sp.CFrame.Position.Z, spawnCf.Position.Z, 1e-3, "spawn z")
		t.ok(sp.CFrame.LookVector:Dot(spawnCf.LookVector) > 0.99, "spawn faces the dealership")
		local boards = {}
		for _, p in CollectionService:GetTagged("LeaderboardBoard") do
			if p:IsDescendantOf(folder) then
				boards[p:GetAttribute("Stat")] = p
			end
		end
		t.ok(boards.totalEarned and boards.steals, "both leaderboards present")
		for stat, b in boards do
			t.ok(b:IsA("BasePart"), stat .. " board is a part")
			t.eq(b:GetAttribute("Face"), "Front")
			local toSpawn = (spawnCf.Position - b.CFrame.Position) * Vector3.new(1, 0, 1)
			t.ok(b.CFrame.LookVector:Dot(toSpawn.Unit) > 0.95, stat .. " board faces the spawn")
		end
	end)

	t.test("gear shop counter", function()
		local tagged = {}
		for _, p in CollectionService:GetTagged("GearShopCounter") do
			if p:IsDescendantOf(folder) then
				table.insert(tagged, p)
			end
		end
		t.eq(#tagged, 1, "one GearShopCounter")
		local counter = tagged[1]
		t.eq(counter.Name, "GearShopCounter")
		local target = MapLayout.gearShopCounter().Position
		t.near(counter.CFrame.Position.X, target.X, 1e-3, "counter x")
		t.near(counter.CFrame.Position.Z, target.Z, 1e-3, "counter z")
		t.ok(counter.CanCollide, "counter collidable")
		-- customers stand in front of the counter (toward the street): keep that space open
		local front = MapLayout.gearShopCounter() * H.roblox.CFrame.new(0, 3.5, -6)
		local bmin, bmax = boxAabb(front, Vector3.new(12, 6, 8))
		local hits = blockers(bmin, bmax, CURB_TOP + 0.3)
		t.ok(#hits == 0, "counter front blocked by " .. table.concat(hits, ", "))
	end)

	t.test("busted release spot is open ground", function()
		local cf = MapLayout.bustedReleaseCFrame()
		local bmin, bmax = boxAabb(cf, Vector3.new(6, 6, 6))
		local hits = blockers(bmin, bmax, CURB_TOP + 0.3)
		t.ok(#hits == 0, "release spot blocked by " .. table.concat(hits, ", "))
		t.ok(cf.Position.Y > CURB_TOP, "release above the sidewalk")
	end)

	t.test("boundary walls", function()
		local walls = folder.Boundary:GetChildren()
		t.eq(#walls, 4)
		for _, w in walls do
			t.ok(w.CanCollide, "wall collides")
			t.eq(w.Transparency, 1)
			local p = w.CFrame.Position
			local d = math.max(math.abs(p.X), math.abs(p.Z))
			t.ok(math.abs(d - MapConfig.BOUNDARY) <= 3, "wall at boundary: " .. tostring(p))
		end
	end)

	t.test("street lights + night glow metadata", function()
		local lamps, lights = 0, 0
		for _, p in CollectionService:GetTagged("StreetLight") do
			if p:IsDescendantOf(folder) then
				lamps += 1
				if p:FindFirstChildOfClass("PointLight") then
					lights += 1
				end
			end
		end
		t.ok(lamps >= 300, "street lights: " .. lamps)
		t.ok(
			lights >= lamps * 0.25 and lights <= lamps * 0.42,
			("about every third lamp has a light (%d/%d)"):format(lights, lamps)
		)
		local glows = 0
		for _, p in CollectionService:GetTagged("NightGlow") do
			if p:IsDescendantOf(folder) then
				glows += 1
				t.eq(typeof(p:GetAttribute("NightColor")), "Color3")
				t.eq(typeof(p:GetAttribute("DayColor")), "Color3")
				t.ok(H.roblox.Enum.Material[p:GetAttribute("NightMaterial")] ~= nil, "night material valid")
				t.ok(H.roblox.Enum.Material[p:GetAttribute("DayMaterial")] ~= nil, "day material valid")
			end
		end
		t.ok(glows > 500, "night glow parts: " .. glows)
	end)

	t.test("every POI is built", function()
		for name in MapConfig.Blocks do
			t.ok(folder.POIs:FindFirstChild(name), "missing POI " .. name)
		end
		t.ok(folder.POIs:FindFirstChild("HotwireTower"), "landmark")
		for i = 1, 8 do
			t.ok(folder.POIs.Dealership:FindFirstChild("DealerPad" .. i), "dealer pad disc " .. i)
		end
	end)

	t.test("districts", function()
		t.eq(MapBuilder.districtOf(-1, -1), "downtown")
		t.eq(MapBuilder.districtOf(1, 1), "downtown")
		t.eq(MapBuilder.districtOf(2, 0), "midrise")
		t.eq(MapBuilder.districtOf(-4, 0), "lowrise")
		t.eq(MapBuilder.districtOf(4, 0), "beach")
	end)

	-- LightingService ----------------------------------------------------------------------------------------
	t.test("lighting: cycle math", function()
		local L = LightingService
		t.near(L.hourAt(0), L.SUNRISE, 1e-6, "sunrise")
		t.near(L.hourAt(L.DAY_SECONDS / 2), 12, 1e-6, "noon")
		t.near(L.hourAt(L.DAY_SECONDS), L.SUNSET, 1e-6, "sunset")
		t.near(L.hourAt(L.DAY_SECONDS + L.NIGHT_SECONDS / 2), 0, 1e-6, "midnight")
		t.near(L.hourAt(L.CYCLE_SECONDS), L.SUNRISE, 1e-6, "wraps")
		for _, h in { 0, 3, 6, 9.5, 12, 17.9, 18, 21, 23.5 } do
			t.near(L.hourAt(L.timeForHour(h)), h, 1e-6, "inverse at " .. h)
		end
		t.ok(not L.isNightHour(12), "noon is day")
		t.ok(L.isNightHour(22), "22h is night")
		t.ok(L.isNightHour(3), "3h is night")
		t.ok(not L.isNightHour(7), "7h is day")
		-- ~4 of 16 minutes are night
		local nightSecs = 0
		for s = 0, L.CYCLE_SECONDS - 1 do
			if L.isNightHour(L.hourAt(s)) then
				nightSecs += 1
			end
		end
		t.ok(nightSecs >= 230 and nightSecs <= 300, "night seconds per cycle: " .. nightSecs)
		local noon, midnight = L.lookAt(12), L.lookAt(0)
		t.ok(noon.brightness > midnight.brightness, "day brighter than night")
		t.ok(midnight.bloom > noon.bloom, "neon blooms more at night")
	end)

	t.test("lighting: init + night toggles lamps and glow", function()
		local L = LightingService
		local Lighting = H.game:GetService("Lighting")
		L.init()
		for _, cls in { "Atmosphere", "Sky", "BloomEffect", "ColorCorrectionEffect", "SunRaysEffect" } do
			t.ok(Lighting:FindFirstChildOfClass(cls), "missing " .. cls)
		end
		local fired = nil
		L.NightChanged:Connect(function(v)
			fired = v
		end)
		L.setClockTime(12)
		t.eq(L.isNight(), false)
		L.setClockTime(22)
		t.eq(L.isNight(), true)
		t.eq(Lighting:GetAttribute("IsNight"), true)
		t.eq(fired, true, "NightChanged fired")
		t.ok(math.abs(Lighting.ClockTime - 22) < 0.1, "clock jumped")
		for _, p in CollectionService:GetTagged("StreetLight") do
			local pl = p:FindFirstChildOfClass("PointLight")
			if pl then
				t.ok(pl.Enabled, "street light on at night")
			end
		end
		local glow = CollectionService:GetTagged("NightGlow")[1]
		t.eq(glow.Material.Name, glow:GetAttribute("NightMaterial"), "first glow batch switched")
		L.setClockTime(12)
		t.eq(L.isNight(), false)
		for _, p in CollectionService:GetTagged("StreetLight") do
			local pl = p:FindFirstChildOfClass("PointLight")
			if pl then
				t.ok(not pl.Enabled, "street light off by day")
			end
		end
	end)

	-- leave the shared harness workspace clean for other specs
	folder:Destroy()
end
