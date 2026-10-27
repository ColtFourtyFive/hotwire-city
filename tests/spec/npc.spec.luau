--!nocheck
-- NPC slice (docs/ART_PASS.md AP3): curated outfit parsing, sidewalk waypoints, flee / hit decisions, the humanoid
-- budget, the procedural R15 rig, seated drivers in every car, comic ejection, the BUSTED officer, shopkeepers and
-- pedestrians (procedural templates: the harness has no avatar catalog), plus the Traffic / Police hooks.
return function(t)
	local H = t.H
	H.setMode("server")
	local fs = require("@lune/fs")
	local serde = require("@lune/serde")
	local Vector3 = H.roblox.Vector3
	local CFrame = H.roblox.CFrame
	local Instance = H.roblox.Instance
	local MapLayout = H.require("src/shared/Util/MapLayout")
	-- NPC sidewalk wandering is still grid-locked (GridLayout); shops / plaza / zones are the v2 world (MapLayout)
	local GridLayout = H.require("src/shared/Util/GridLayout")
	local WorldQuery = H.require("src/shared/Util/WorldQuery")
	local MapConfig = H.require("src/shared/Config/Map")
	local Cars = H.require("src/shared/Config/Cars")
	local CarBuilder = H.require("src/shared/Vehicle/CarBuilder")
	local Outfits = H.require("src/server/Config/NPCOutfits")
	local NPC = H.require("src/server/Systems/NPCService")
	local Traffic = H.require("src/server/Systems/TrafficService")
	local Police = H.require("src/server/Systems/PoliceService")

	local S = MapConfig.GRID_SPACING
	local BLOCK_HALF = (S - MapConfig.ROAD_WIDTH) / 2
	local LOT_HALF = BLOCK_HALF - MapConfig.SIDEWALK_WIDTH
	local CURB_TOP = GridLayout.CURB_TOP

	local function flatDist(a, b)
		return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
	end

	local function deepEq(a, b, path)
		if type(a) ~= type(b) then
			return false, path .. ": type " .. type(a) .. " vs " .. type(b)
		end
		if type(a) ~= "table" then
			if a == b then
				return true
			end
			return false, path .. ": " .. tostring(a) .. " vs " .. tostring(b)
		end
		for k, v in a do
			local ok, why = deepEq(v, b[k], path .. "." .. tostring(k))
			if not ok then
				return false, why
			end
		end
		for k in b do
			if a[k] == nil then
				return false, path .. "." .. tostring(k) .. " missing"
			end
		end
		return true
	end

	-- vertical extent of a (possibly rotated) part
	local function topOf(p)
		local cf, s = p.CFrame, p.Size
		local half = 0.5
			* (math.abs(cf.RightVector.Y) * s.X + math.abs(cf.UpVector.Y) * s.Y + math.abs(cf.LookVector.Y) * s.Z)
		return cf.Position.Y + half, cf.Position.Y - half
	end

	local function bounds(model)
		local top, bottom = -math.huge, math.huge
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
				local tp, bt = topOf(d)
				top = math.max(top, tp)
				bottom = math.min(bottom, bt)
			end
		end
		return top, bottom
	end

	local function cleanup()
		local f = H.workspace:FindFirstChild("NPCs")
		if f then
			f:Destroy()
		end
		NPC._reset()
	end

	-- OUTFITS -----------------------------------------------------------------------------------------------------------

	local curation = serde.decode("json", fs.readFile("assets/curation/vehicles-characters-props.json"))

	t.test("curation JSON parses into exactly the baked outfit table and pool", function()
		local roles, pool = Outfits.fromCuration(curation)
		local ok, why = deepEq(roles, Outfits.Roles, "Roles")
		t.ok(ok, "regenerate NPCOutfits.Roles from the curation JSON: " .. tostring(why))
		local ok2, why2 = deepEq(pool, Outfits.Pool, "Pool")
		t.ok(ok2, "regenerate NPCOutfits.Pool: " .. tostring(why2))
		for _, key in { "police_officer", "chef_vendor", "car_salesman", "accessory_pool" } do
			t.ok(key == "accessory_pool" and pool ~= nil or roles[key] ~= nil, key .. " curated")
		end
		t.ok(#Outfits.civilians() >= 6, "civilian variety")
	end)

	t.test("every curated catalog item lands in the description field its assetType names", function()
		local field =
			{ [11] = "Shirt", [12] = "Pants", [8] = "HatAccessory", [41] = "HairAccessory", [42] = "FaceAccessory" }
		local checked = 0
		for _, entry in curation do
			local key = type(entry.role) == "string" and entry.role:match("^npc_(.+)$")
			if not key or key == "accessory_pool" then
				continue
			end
			local outfit = Outfits.Roles[key]
			t.ok(outfit ~= nil, key)
			for _, val in entry.outfit do
				local items = if val[1] ~= nil then val else { val }
				for _, item in items do
					local f = field[item.assetType]
					t.ok(f ~= nil, "known assetType " .. tostring(item.assetType))
					if f == "Shirt" or f == "Pants" then
						t.eq(outfit[f], item.id, key .. "." .. f)
					else
						t.ok(table.find(outfit[f], item.id) ~= nil, key .. "." .. f .. " has " .. item.id)
					end
					checked += 1
				end
			end
		end
		t.ok(checked >= 30, "items checked")
		-- classic clothing ids are numbers, accessories become comma lists
		local police = Outfits.descriptionFields(Outfits.Roles.police_officer)
		t.eq(police.Shirt, 4196154381)
		t.eq(police.Pants, 9670576178)
		t.eq(police.HatAccessory, "1081392")
		t.eq(police.FaceAccessory, "51245241")
		t.eq(police.HairAccessory, "")
		local multi = Outfits.descriptionFields({
			name = "x",
			Shirt = 1,
			Pants = 2,
			HatAccessory = { 10, 20 },
			HairAccessory = { 30 },
			FaceAccessory = {},
		})
		t.eq(multi.HatAccessory, "10,20")
		t.eq(multi.HairAccessory, "30")
		t.eq(multi.FaceAccessory, "")
	end)

	t.test("alternates are partial outfits merged over the base; pool remixes keep the clothes", function()
		local chefPaper = Outfits.get("chef_vendor", 1)
		t.eq(chefPaper.HatAccessory[1], 10476359, "hat swapped")
		t.eq(chefPaper.Shirt, Outfits.Roles.chef_vendor.Shirt, "jacket kept")
		t.eq(chefPaper.HairAccessory[1], 62234425, "hair kept")
		local white = Outfits.get("car_salesman", 1)
		t.eq(white.Shirt, 6553589977)
		t.eq(Outfits.get("car_salesman", 9), nil)
		local pool = Outfits.Pool
		for _, civ in Outfits.civilians() do
			for seed = 0, 7 do
				local base = Outfits.Roles[civ]
				local v = Outfits.poolVariant(base, pool, seed)
				t.eq(v.Shirt, base.Shirt)
				t.eq(v.Pants, base.Pants)
				t.ok(#v.HatAccessory <= 1 and #v.HairAccessory <= 1, "one hat / one hair at most")
				local hat = v.HatAccessory[1]
				if hat and table.find(pool.hatsWithHair, hat) then
					t.eq(#v.HairAccessory, 0, "hat with built-in hair: no extra hair")
				else
					t.eq(#v.HairAccessory, 1, "a hair")
				end
				t.eq(Outfits.poolVariant(base, pool, seed).HairAccessory[1], v.HairAccessory[1], "deterministic")
			end
		end
	end)

	-- SIDEWALKS -----------------------------------------------------------------------------------------------------------

	t.test("sidewalk rings stay on the sidewalk: off the roads, out of garages and drive-in zones", function()
		local sprays = MapLayout.sprayZones()
		local chopCf, chopSize = MapLayout.chopZone()
		for bx = MapConfig.BLOCK_MIN, MapConfig.BLOCK_MAX do
			for bz = MapConfig.BLOCK_MIN, MapConfig.BLOCK_MAX do
				local ring, perSide = NPC._sidewalkRing(bx, bz)
				local c = GridLayout.blockCenter(bx, bz)
				t.eq(#ring, perSide * 4, "4 sides")
				for k = 0, 3 do
					local corner = ring[k * perSide + 1]
					t.near(math.abs(corner.X - c.X), BLOCK_HALF - NPC.SIDEWALK_INSET, 1e-6, "corner x")
					t.near(math.abs(corner.Z - c.Z), BLOCK_HALF - NPC.SIDEWALK_INSET, 1e-6, "corner z")
				end
				for i, a in ring do
					local b = ring[i % #ring + 1]
					t.ok(flatDist(a, b) <= NPC.RING_SPACING + 1e-6, "waypoint spacing")
					for k = 0, 8 do
						local p = a:Lerp(b, k / 8)
						local where = ("block %d,%d point %d"):format(bx, bz, i)
						t.near(p.Y, CURB_TOP, 1e-6, where .. " at curb height")
						t.ok(not GridLayout.isOnRoad(p), where .. " off the road")
						local off = math.max(math.abs(p.X - c.X), math.abs(p.Z - c.Z))
						t.ok(off > LOT_HALF and off < BLOCK_HALF, where .. " inside the sidewalk band")
						local up = p + Vector3.new(0, 2, 0)
						t.eq(MapLayout.plotAt(up), nil, where .. " outside every garage")
						for _, z in sprays do
							t.ok(not MapLayout.isInBox(z.cframe, z.size, up), where .. " outside the spray booth")
						end
						t.ok(not MapLayout.isInBox(chopCf, chopSize, up), where .. " outside the chop shop")
					end
				end
			end
		end
	end)

	t.test("flee targets are clamped onto the block", function()
		local c = GridLayout.blockCenter(1, 2)
		local p = NPC._clampToBlock(c + Vector3.new(80, 5, -200), 1, 2)
		t.ok(not GridLayout.isOnRoad(p), "never into the road")
		t.near(p.Y, CURB_TOP, 1e-6)
		t.near(p.X - c.X, BLOCK_HALF - 1.5, 1e-6)
		local inside = NPC._clampToBlock(c + Vector3.new(10, 0, 10), 1, 2)
		t.near(inside.X, c.X + 10, 1e-6)
	end)

	-- DECISIONS -----------------------------------------------------------------------------------------------------------

	t.test("flee decision: fast cars heading at you, sideways out of their line", function()
		local ped = Vector3.new(0, CURB_TOP, 0)
		-- straight at the ped from 20 studs, 50 studs/s, ped slightly to the car's left
		local dir = NPC._fleeDecision(ped, Vector3.new(-1.5, 0, 20), Vector3.new(0, 0, -50))
		t.ok(dir ~= nil, "flees")
		t.near(dir.Magnitude, 1, 1e-6)
		t.near(dir:Dot(Vector3.new(0, 0, -1)), 0, 1e-6, "perpendicular to the car")
		t.ok(dir.X > 0.99, "away from the car's line")
		t.eq(NPC._fleeDecision(ped, Vector3.new(0, 0, 20), Vector3.new(0, 0, -20)), nil, "slow car")
		t.eq(NPC._fleeDecision(ped, Vector3.new(0, 0, 40), Vector3.new(0, 0, -60)), nil, "too far")
		t.eq(NPC._fleeDecision(ped, Vector3.new(0, 0, -10), Vector3.new(0, 0, -60)), nil, "already past")
		t.eq(NPC._fleeDecision(ped, Vector3.new(12, 0, 10), Vector3.new(0, 0, -60)), nil, "passing wide")
		local dead = NPC._fleeDecision(ped, Vector3.new(0, 0, 15), Vector3.new(0, 0, -60))
		t.ok(dead and math.abs(dead.X) > 0.99, "dead ahead: dive sideways")
		-- traffic at full speed in its lane never scares a pedestrian on the sidewalk ring
		local ring = NPC._sidewalkRing(0, 0)
		for _, p in ring do
			for _, axis in { "X", "Z" } do
				for _, line in { 0, 1 } do
					for _, d in { 1, -1 } do
						local lane = Traffic._lanePoint(axis, line, d, if axis == "X" then p.X else p.Z)
						local vel = Traffic._forward(axis, d) * 45
						t.eq(NPC._fleeDecision(p, lane - vel * 0.2, vel), nil, "lane traffic")
						t.ok(
							not NPC._carHitsPed(p, lane - vel * 0.25, lane, vel.Unit, 9, 3.65),
							"lane traffic never hits the sidewalk"
						)
					end
				end
			end
		end
	end)

	t.test("hit test sweeps the car's path since the last tick", function()
		local ped = Vector3.new(0, CURB_TOP, 0)
		local look = Vector3.new(0, 0, -1)
		-- 60 studs/s at 4 Hz: 15 studs between ticks, straight through the ped
		t.ok(NPC._carHitsPed(ped, Vector3.new(0.5, 0, 9), Vector3.new(0.5, 0, -6), look, 7, 3.5), "tunnelled hit")
		t.ok(NPC._carHitsPed(ped, Vector3.new(4, 0, 6), Vector3.new(4, 0, 6), look, 7, 3.5), "bumper contact")
		t.ok(not NPC._carHitsPed(ped, Vector3.new(9, 0, 9), Vector3.new(9, 0, -6), look, 7, 3.5), "missed")
		t.ok(not NPC._carHitsPed(ped, Vector3.new(0, 20, 9), Vector3.new(0, 20, -6), look, 7, 3.5), "flying over")
		t.ok(not NPC._carHitsPed(ped, Vector3.new(0, 0, 30), Vector3.new(0, 0, 20), look, 7, 3.5), "not there yet")
	end)

	t.test("humanoid budget: per-kind caps and the 40 total", function()
		t.ok(NPC._budgetAllows("traffic", {}), "empty")
		t.ok(not NPC._budgetAllows("traffic", { traffic = NPC.BUDGET.traffic }), "traffic cap")
		t.ok(not NPC._budgetAllows("nonsense", {}), "unknown kind")
		t.ok(not NPC._budgetAllows("total", {}), "total is not a kind")
		-- greedy fill in any order never passes the total
		for _, order in
			{
				{ "traffic", "police", "pedestrian", "shopkeeper", "officer" },
				{ "pedestrian", "officer", "shopkeeper", "police", "traffic" },
			}
		do
			local live = { ejected = 0 }
			local total = 0
			for _ = 1, 100 do
				for _, kind in order do
					if NPC._budgetAllows(kind, live) then
						live[kind] = (live[kind] or 0) + 1
						total += 1
					end
				end
			end
			t.eq(total, NPC.BUDGET.total, "fills to the total exactly")
		end
		t.ok(not NPC._budgetAllows("officer", { ejected = 39, officer = 1 }), "ejected NPCs count")
		t.eq(NPC._pedTarget(0), 0)
		t.eq(NPC._pedTarget(1), NPC.PED_MIN)
		t.eq(NPC._pedTarget(3), NPC.PED_MIN + 2)
		t.eq(NPC._pedTarget(8), NPC.PED_MAX)
		t.ok(NPC.PED_MIN >= 10 and NPC.PED_MAX <= 14, "10-14 civilians")
		t.ok(NPC.PED_TICK >= 0.25, "<= 4 Hz")
	end)

	t.test("seated scale and knee bend fit the figure into the car", function()
		t.eq(NPC._seatedScale(10, 0.5, 3.5), 1, "roomy van")
		t.near(NPC._seatedScale(3, 0.5, 3.5), 0.75, 1e-9)
		t.eq(NPC._seatedScale(0.5, 0.5, 3.5), NPC.MIN_DRIVER_SCALE, "floor")
		t.eq(NPC._seatedScale(nil, 0.5, 3.5), 0.85, "unknown car")
		t.eq(NPC._kneeAngle(3, 1.3), 90, "shins straight down")
		local low = NPC._kneeAngle(0.6, 1.3)
		t.ok(low < 30 and low >= 19, "low seat stretches the legs")
		t.eq(NPC._kneeAngle(nil, 1.3), 90)
	end)

	t.test("pedestrian spawn points: on a ring, not too close to anyone, behind the player when possible", function()
		local rng = H.Random.new(77)
		local center = MapLayout.spawnCFrame().Position
		local other = center + Vector3.new(120, 0, 0)
		local roots = { center, other }
		local look = Vector3.new(1, 0, 0)
		local behind = 0
		for _ = 1, 40 do
			local bx, bz, idx = NPC._pickSpawn(center, look, roots, rng)
			t.ok(bx ~= nil, "found")
			local p = NPC._sidewalkRing(bx, bz)[idx]
			local d = flatDist(p, center)
			t.ok(d >= NPC.PED_SPAWN_MIN and d <= NPC.PED_SPAWN_MAX, "distance band")
			t.ok(flatDist(p, other) >= NPC.PED_SPAWN_MIN, "clear of every player")
			if (p - center):Dot(look) < 0 then
				behind += 1
			end
		end
		t.eq(behind, 40, "behind the player")
		t.eq(NPC._pickSpawn(Vector3.new(5000, 0, 5000), nil, { Vector3.new(5000, 0, 5000) }, rng), nil, "off the map")
	end)

	t.test("shopkeeper spots: clerk behind the gear counter, salesman clear of the pads, cart in the plaza", function()
		local spots = NPC._shopkeeperSpots()
		local counter = MapLayout.gearShopCounter()
		local rel = spots.gear.Position - counter.Position
		t.ok(rel:Dot(counter.LookVector) < -2, "behind the counter")
		t.ok(rel.Magnitude < 4, "at the counter")
		t.ok(spots.gear.LookVector:Dot(counter.LookVector) > 0.99, "faces the customers")
		for _, pad in MapLayout.dealerPads() do
			t.ok(flatDist(pad.Position, spots.dealer.Position) > 11, "clear of dealer pad")
		end
		local function inFootprint(id, pos)
			local poi = WorldQuery.poi(id)
			local lp = poi.cframe:PointToObjectSpace(pos)
			return math.abs(lp.X) <= poi.size.X / 2 and math.abs(lp.Z) <= poi.size.Z / 2
		end
		t.ok(inFootprint("Dealership", spots.dealer.Position), "salesman on the dealership lot")
		for name, cf in spots do
			t.ok(not MapLayout.isOnRoad(cf.Position), name .. " off the road")
			t.ok(cf.Position.Y >= MapLayout.CURB_TOP - 1e-6, name .. " at or above curb height")
		end
		t.ok(inFootprint("HotwirePlaza", spots.cart.Position), "cart on the plaza")
		t.ok(flatDist(spots.cart.Position, MapLayout.spawnCFrame().Position) > 20, "clear of the spawn")
		t.ok(spots.hotdog.LookVector:Dot(spots.cart.LookVector) > 0.99, "vendor faces the cart's front")
		t.ok((spots.hotdog.Position - spots.cart.Position):Dot(spots.cart.LookVector) < -2, "vendor behind the cart")
	end)

	-- RIGS ------------------------------------------------------------------------------------------------------------------

	t.test("procedural R15 rig: named parts and joints, consistent motors, feet on the ground, no scripts", function()
		local rig = NPC.buildRig(Outfits.Looks.police, H.Random.new(5))
		local hum = rig:FindFirstChildOfClass("Humanoid")
		t.ok(hum ~= nil, "humanoid")
		t.eq(hum.RigType, H.roblox.Enum.HumanoidRigType.R15)
		t.eq(rig.PrimaryPart.Name, "HumanoidRootPart")
		t.ok(hum:FindFirstChildOfClass("Animator") ~= nil, "animator for the default animations")
		local motors = 0
		for _, d in rig:GetDescendants() do
			t.ok(not d:IsA("LuaSourceContainer"), "no scripts")
			if d:IsA("Motor6D") then
				motors += 1
				local a = (d.Part0.CFrame * d.C0).Position
				local b = (d.Part1.CFrame * d.C1).Position
				t.ok((a - b).Magnitude < 1e-4, d.Name .. " consistent")
			end
		end
		t.eq(motors, 15, "R15 joints")
		for _, name in { "LeftHip", "RightKnee", "Neck", "Waist", "Root", "LeftShoulder", "RightWrist" } do
			local found = false
			for _, d in rig:GetDescendants() do
				if d:IsA("Motor6D") and d.Name == name then
					found = true
				end
			end
			t.ok(found, name)
		end
		local top, bottom = bounds(rig)
		t.near(bottom, 0, 1e-4, "feet on y = 0")
		t.ok(top > 5 and top < 6.5, "about 5-6 studs tall with the cap")
		local root = rig.PrimaryPart
		t.near(root.CFrame.Position.Y - root.Size.Y / 2, hum.HipHeight, 1e-4, "HipHeight = root bottom above ground")
		local head = rig:FindFirstChild("Head")
		t.ok(head:FindFirstChildOfClass("Decal") ~= nil, "face")
		local offset, thighHalf, aboveHip = NPC._measure(rig)
		t.ok(offset and math.abs(offset.Y + 1) < 1e-4, "hips 1 below the root")
		t.near(thighHalf, 0.5, 1e-4)
		t.near(aboveHip, top - 2.3, 1e-4)
		t.near(NPC._shinLength(rig), 1.3, 1e-4)
	end)

	t.test("templates: procedural fallback for every role when the avatar catalog is unavailable", function()
		cleanup()
		t.eq(NPC.isReady(), false)
		t.eq(NPC.spawnDriver(Instance.new("Seat"), "civilian"), nil, "not ready -> callers keep their dummy")
		local fired = false
		local conn = NPC.Ready:Connect(function()
			fired = true
		end)
		t.eq(NPC._buildTemplates(false), 0, "no avatars in the harness")
		conn:Disconnect()
		t.ok(fired and NPC.isReady(), "ready")
	end)

	t.test("seated drivers fit every car: welded, frozen, posed, under the roof, above the floor", function()
		local built = 0
		for _, def in Cars.List do
			NPC._reset()
			NPC._buildTemplates(false)
			local car = CarBuilder.build(def.id, "None")
			car.Parent = H.workspace
			local seat = car:FindFirstChild("DriverSeat")
			local npc = NPC.spawnDriver(seat, "civilian")
			t.ok(npc ~= nil, def.id .. " got a driver")
			t.eq(npc.Parent, car, "inside the car model")
			local root = npc.PrimaryPart
			local weld = root:FindFirstChild("ToCar")
			t.ok(weld and weld.Part1 == seat, "welded to the seat")
			local hum = npc:FindFirstChildOfClass("Humanoid")
			t.eq(hum.PlatformStand, true, "PlatformStand")
			t.eq(hum.EvaluateStateMachine, false, "no state machine")
			t.ok(root.CFrame.LookVector:Dot(seat.CFrame.LookVector) > 0.999, "faces forward")
			for _, d in npc:GetDescendants() do
				if d:IsA("BasePart") then
					t.eq(d.Massless, true, "massless")
					t.eq(d.CanCollide, false, "no collisions")
					t.eq(d.CanTouch, false, "no touch")
					t.eq(d.Anchored, false, "rides with the car")
				elseif d:IsA("Motor6D") then
					local a = (d.Part0.CFrame * d.C0).Position
					local b = (d.Part1.CFrame * d.C1).Position
					t.ok((a - b).Magnitude < 1e-3, def.id .. " " .. d.Name .. " solved")
				end
				t.ok(not d:IsA("LuaSourceContainer"), "no scripts")
			end
			-- thighs forward: the upper leg hangs along the car's forward axis
			local thigh = npc:FindFirstChild("LeftUpperLeg")
			t.ok(math.abs(thigh.CFrame.UpVector:Dot(seat.CFrame.LookVector)) > 0.95, def.id .. " sitting")
			local chassis = car.PrimaryPart
			local ground = chassis.CFrame.Position.Y - car:GetAttribute("RideHeight")
			local floor = chassis.CFrame.Position.Y - chassis.Size.Y / 2
			local seatTop = seat.CFrame.Position.Y + seat.Size.Y / 2
			local base = math.max(seatTop, floor + NPC.FLOOR_MARGIN)
			local roof = ground + car:GetAttribute("Height") - NPC.ROOF_MARGIN
			local need = npc:GetAttribute("ThighHalf") + npc:GetAttribute("AboveHip")
			local top, bottom = bounds(npc)
			if (roof - base) / need >= NPC.MIN_DRIVER_SCALE then
				t.ok(top <= roof + 0.02, ("%s head under the roof (%.2f > %.2f)"):format(def.id, top, roof))
			end
			t.ok(bottom >= floor - 0.35, ("%s feet above the floor (%.2f < %.2f)"):format(def.id, bottom, floor))
			car:Destroy()
			built += 1
		end
		t.ok(built >= 20, "cars")
	end)

	t.test("police driver, budget cap, comic eject", function()
		cleanup()
		NPC._buildTemplates(false)
		local cop = CarBuilder.buildDef(Cars.Police, "None")
		cop.Parent = H.workspace
		local officer = NPC.spawnDriver(cop:FindFirstChild("DriverSeat"), "police")
		t.ok(officer ~= nil, "officer seated")
		t.ok(officer:FindFirstChild("HatBadge", true) ~= nil, "police look")
		t.eq(NPC.getCounts().police, 1)
		-- traffic cap
		local cars = {}
		for i = 1, NPC.BUDGET.traffic + 1 do
			local car = CarBuilder.build("rustbucket", "None")
			car.Parent = H.workspace
			cars[i] = car
			local npc = NPC.spawnDriver(car:FindFirstChild("DriverSeat"), "civilian")
			if i <= NPC.BUDGET.traffic then
				t.ok(npc ~= nil, "under the traffic cap")
			else
				t.eq(npc, nil, "over the traffic cap: caller uses its dummy")
			end
		end
		t.eq(NPC.getCounts().traffic, NPC.BUDGET.traffic)
		-- a destroyed car frees its driver's budget slot
		cars[1]:Destroy()
		t.ok(NPC.canSpawn("traffic"), "slot freed")
		-- yeet
		local victim = cars[2]:FindFirstChild("NPCDriver")
		NPC.ejectComic(victim, Vector3.new(30, 0, 0))
		t.eq(victim.Parent, H.workspace:FindFirstChild("NPCs"), "out of the car")
		t.eq(victim.PrimaryPart:FindFirstChild("ToCar"), nil, "unwelded")
		local sockets, enabledMotors = 0, 0
		for _, d in victim:GetDescendants() do
			if d:IsA("BallSocketConstraint") then
				sockets += 1
			elseif d:IsA("Motor6D") and d.Enabled then
				enabledMotors += 1
				t.eq(d.Name, "Root", "only the root joint stays rigid")
			elseif d:IsA("BasePart") then
				t.eq(d.Anchored, false)
			end
		end
		t.eq(sockets, 14, "ragdoll")
		t.eq(enabledMotors, 1)
		local hum = victim:FindFirstChildOfClass("Humanoid")
		t.eq(hum.PlatformStand, true)
		t.eq(hum.BreakJointsOnDeath, false, "never breaks apart")
		t.eq(NPC.getCounts().ejected, 1, "counted until removed")
		NPC.ejectComic(Instance.new("Model"), nil) -- not in the world: ignored
		for _, car in cars do
			car:Destroy()
		end
		cop:Destroy()
	end)

	t.test("BUSTED officer: standing at the spot, anchored, visual only, capped", function()
		cleanup()
		t.eq(NPC.spawnOfficerAt(CFrame.new(0, CURB_TOP, 0), 4), nil, "not ready")
		NPC._buildTemplates(false)
		local spot = CFrame.lookAt(Vector3.new(10, CURB_TOP, 20), Vector3.new(10, CURB_TOP, 0))
		local officer = NPC.spawnOfficerAt(spot, 4)
		t.ok(officer ~= nil, "spawned")
		local root = officer.PrimaryPart
		t.eq(root.Anchored, true)
		t.ok(root.CFrame.LookVector:Dot(spot.LookVector) > 0.999, "facing the player")
		local _, bottom = bounds(officer)
		t.near(bottom, CURB_TOP, 1e-4, "feet on the ground")
		for _, d in officer:GetDescendants() do
			if d:IsA("BasePart") then
				t.eq(d.CanCollide, false, "visual only")
			end
		end
		t.ok(NPC.spawnOfficerAt(spot, 4) ~= nil, "second")
		t.eq(NPC.spawnOfficerAt(spot, 4), nil, "officer cap")
		t.eq(NPC.spawnOfficerAt("nope", 4), nil, "bad args")
		-- PoliceService picks the spot: toward the nearest cruiser, else the suspect's right
		local suspect = Vector3.new(100, CURB_TOP, 100)
		local cf = Police._bustOfficerSpot(suspect, Vector3.new(0, 0, -1), Vector3.new(130, 0, 100))
		t.near(flatDist(cf.Position, suspect), 4.5, 1e-6)
		t.ok(cf.Position.X > suspect.X + 4, "toward the cruiser")
		t.ok(cf.LookVector:Dot((suspect - cf.Position).Unit) > 0.999, "faces the suspect")
		local side = Police._bustOfficerSpot(suspect, Vector3.new(0, 0, -1), Vector3.new(900, 0, 900))
		t.ok(side.Position.X > suspect.X + 4, "far cruiser: at the suspect's right")
		local none = Police._bustOfficerSpot(suspect, Vector3.new(0, 0, -1), nil)
		t.near(none.Position.Y, suspect.Y, 1e-6)
	end)

	t.test("shopkeepers: three anchored idlers, a hotdog cart when the plaza has no stand", function()
		cleanup()
		NPC._buildTemplates(false)
		NPC._placeShopkeepers()
		t.eq(NPC.getCounts().shopkeeper, 3)
		local folder = H.workspace:FindFirstChild("NPCs")
		t.ok(folder:FindFirstChild("HotdogCart") ~= nil, "fallback cart")
		local chef = false
		for _, m in folder:GetChildren() do
			if m.Name == "Shopkeeper" then
				t.eq(m.PrimaryPart.Anchored, true)
				if m:FindFirstChild("HatToque") then
					chef = true
				end
			end
		end
		t.ok(chef, "the hotdog vendor is the chef")

		-- the city has its own hotdog stand (an AssetSlot near the plaza): the vendor goes behind it, no cart
		cleanup()
		NPC._buildTemplates(false)
		local plaza = MapLayout.poiCenter("SpawnPlaza")
		local slot = Instance.new("Model")
		slot.Name = "HotdogSlot"
		local box = Instance.new("Part")
		box.Size = Vector3.new(6, 4, 3)
		local standCf = CFrame.lookAt(plaza + Vector3.new(-20, 2, 30), plaza + Vector3.new(-20, 2, 40))
		box.CFrame = standCf
		box.Parent = slot
		slot.PrimaryPart = box
		slot:SetAttribute("Role", "hotdog_stand")
		slot:AddTag("AssetSlot")
		slot.Parent = H.workspace
		NPC._placeShopkeepers()
		local f2 = H.workspace:FindFirstChild("NPCs")
		t.eq(f2:FindFirstChild("HotdogCart"), nil, "no fallback cart")
		local vendor = nil
		for _, m in f2:GetChildren() do
			if m:FindFirstChild("HatToque") then
				vendor = m
			end
		end
		t.ok(vendor ~= nil, "vendor placed")
		local rel = vendor.PrimaryPart.CFrame.Position - standCf.Position
		t.ok(rel:Dot(standCf.LookVector) < -2, "behind the stand")
		t.ok(flatDist(vendor.PrimaryPart.CFrame.Position, standCf.Position) < 4, "at the stand")
		t.ok(vendor.PrimaryPart.CFrame.LookVector:Dot(standCf.LookVector) > 0.99, "facing the customers")
		slot:Destroy()
		cleanup()
	end)

	t.test("pedestrians: spawn on a ring, walk it, turn around when stuck, vanish with no players around", function()
		cleanup()
		NPC._buildTemplates(false)
		local pause = NPC.CORNER_PAUSE_CHANCE
		NPC.CORNER_PAUSE_CHANCE = 0 -- deterministic walk
		local center = MapLayout.spawnCFrame().Position
		t.ok(NPC._spawnPedestrian(center, Vector3.new(1, 0, 0), { center }), "spawned")
		local folder = H.workspace:FindFirstChild("NPCs")
		local ped = folder:FindFirstChild("Pedestrian")
		t.ok(ped ~= nil, "in the NPCs folder")
		local rec = NPC._record(ped)
		t.eq(rec.kind, "pedestrian")
		t.eq(ped.PrimaryPart.Anchored, false, "walks under physics")
		local hum = ped:FindFirstChildOfClass("Humanoid")
		t.ok(hum.WalkSpeed >= NPC.WALK_SPEED[1] and hum.WalkSpeed <= NPC.WALK_SPEED[2], "strolling speed")
		local _, bottom = bounds(ped)
		t.near(bottom, CURB_TOP, 1e-4, "feet on the sidewalk")
		local ring = rec.ring
		t.ok(table.find(ring, rec.target) ~= nil, "heading for a ring waypoint")
		-- arrive: next waypoint (or a short pause at a corner)
		local now = os.clock() + 1
		local idx = rec.idx
		ped:PivotTo(CFrame.new(rec.target + Vector3.new(0, 3.3, 0)))
		NPC._stepPedestrians(now)
		t.ok(rec.idx ~= idx, "advanced along the ring")
		t.eq(rec.state, "walk")
		-- stuck (no physics in the harness: it never moves): turn around, then give up
		rec.state = "walk"
		local dir = rec.dir
		NPC._stepPedestrians(now + 0.3)
		NPC._stepPedestrians(now + 0.3 + NPC.STUCK_TIME + 0.1)
		t.eq(rec.dir, -dir, "turned around")
		local t0 = now + 0.3 + NPC.STUCK_TIME + 0.1
		for k = 1, 4 do
			NPC._stepPedestrians(t0 + k * (NPC.STUCK_TIME + 0.1))
		end
		t.eq(ped.Parent, nil, "respawned after being stuck")
		t.eq(NPC.getCounts().pedestrian, 0)
		-- empty server (the harness has no players): nobody walks
		NPC._spawnPedestrian(center, nil, { center })
		t.eq(NPC.getCounts().pedestrian, 1)
		NPC._manage()
		t.eq(NPC.getCounts().pedestrian, 0, "despawned: no player within range")
		NPC.CORNER_PAUSE_CHANCE = pause
		cleanup()
	end)

	-- PERF / COLLISION (findings NPC-PERF-10/14, npc-peds-collide-with-client-cars) ----------------------------------

	t.test("humans only where they show: closed hero shells keep the dummy, open tops / bare bodies get one", function()
		local function car(id, shelled)
			local m = CarBuilder.build(id, "None")
			m:SetAttribute("CarId", id)
			if shelled then
				m:SetAttribute("HeroMesh", true)
			end
			return m
		end
		t.eq(NPC.driverVisible(car("grandma_sedan", false)), true, "procedural body: glass shows the driver")
		t.eq(NPC.driverVisible(car("grandma_sedan", true)), false, "closed shell hides the driver")
		t.eq(NPC.driverVisible(car("toilet_turbo", true)), true, "open-top shell shows the rider")
		local cop = CarBuilder.buildDef(Cars.Police, "None")
		cop:SetAttribute("CarId", "police")
		cop:SetAttribute("HeroMesh", true)
		t.eq(NPC.driverVisible(cop), false, "police_unit shell is closed")
		t.eq(NPC.driverVisible(nil), true, "no car: nothing hides it")
		for key in NPC.OPEN_TOP_SHELLS do
			t.ok(Cars.get(key) ~= nil, "open-top key is a car: " .. key)
		end
		-- no all-at-once upgrade bursts on NPCService.Ready (Traffic + Police upgrade gradually, out of view)
		local traffic = fs.readFile("src/server/Systems/TrafficService.luau")
		local police = fs.readFile("src/server/Systems/PoliceService.luau")
		t.ok(not traffic:find("upgradeDrivers, math.huge", 1, true), "no traffic driver burst")
		t.ok(not police:find("NPCService.Ready:Connect", 1, true), "no officer burst")
		t.ok(police:find('"Dealership", "NPCs"', 1, true) ~= nil, "pedestrians never block police line of sight")
	end)

	t.test("NPC parts are in the NPC collision group (cars pass through them); spawn skins from a small set", function()
		cleanup()
		NPC._buildTemplates(false)
		local VehicleService = H.require("src/server/Systems/VehicleService")
		t.eq(VehicleService.NPC_GROUP, "NPC")
		t.eq(VehicleService.CAR_GROUP, "Car")
		t.eq(VehicleService.ensureCollisionGroups(), true, "groups registered (idempotent)")
		local car = CarBuilder.build("rustbucket", "None")
		car.Parent = H.workspace
		local npc = NPC.spawnDriver(car:FindFirstChild("DriverSeat"), "civilian")
		local parts = 0
		for _, d in npc:GetDescendants() do
			if d:IsA("BasePart") then
				parts += 1
				t.eq(d.CollisionGroup, "NPC", "driver part " .. d.Name)
			end
		end
		t.ok(parts > 10, "R15 parts")
		NPC.ejectComic(npc, Vector3.new(30, 0, 0))
		for _, d in npc:GetDescendants() do
			if d:IsA("BasePart") then
				t.eq(d.CollisionGroup, "NPC", "ragdoll part " .. d.Name)
			end
		end
		local allowed = {}
		for _, i in NPC.SPAWN_SKINS do
			t.ok(Outfits.SKIN_TONES[i] ~= nil, "skin index " .. i)
			allowed[Outfits.SKIN_TONES[i]] = true
		end
		t.ok(#NPC.SPAWN_SKINS <= 4, "a few tones (shared clothing composites)")
		local r = H.Random.new(11)
		local seen = 0
		local got = {}
		for _ = 1, 60 do
			local c = NPC._spawnSkin(r)
			t.ok(allowed[c], "tone from the set")
			if not got[c] then
				got[c] = true
				seen += 1
			end
		end
		t.eq(seen, #NPC.SPAWN_SKINS, "every tone used")
		car:Destroy()
		cleanup()
	end)

	-- TRAFFIC / POLICE HOOKS --------------------------------------------------------------------------------------------

	t.test("traffic dummy fallback: palette override and weld for police cruisers", function()
		local cop = CarBuilder.buildDef(Cars.Police, "None")
		local seat = cop:FindFirstChild("DriverSeat")
		local dummy = Traffic.attachDummy(cop, seat, cop.PrimaryPart, Traffic.POLICE_PALETTE)
		t.eq(dummy.Parent, cop)
		t.eq(dummy:FindFirstChild("Torso").Color, Traffic.POLICE_PALETTE.shirt, "police blue")
		t.eq(dummy:FindFirstChild("Hat").Color, Traffic.POLICE_PALETTE.hat)
		local weld = dummy.PrimaryPart:FindFirstChild("ToCar")
		t.ok(weld and weld.Part1 == cop.PrimaryPart, "welded")
		t.eq(dummy:FindFirstChildOfClass("Humanoid"), nil, "no humanoid: outside the NPC budget")
		-- same random draws with or without a palette (deterministic traffic)
		local a = Traffic.buildDriver(seat.CFrame, 0.8, H.Random.new(3))
		local b = Traffic.buildDriver(seat.CFrame, 0.8, H.Random.new(3), { hat = Traffic.POLICE_PALETTE.hat })
		t.eq(a:FindFirstChild("Torso").Color, b:FindFirstChild("Torso").Color)
		t.eq(a:FindFirstChild("Head").Color, b:FindFirstChild("Head").Color)
		cop:Destroy()
	end)
end
