--!nocheck
-- Vehicles v2 (PLAN wave A4): Config/Vehicles + Config/Cars + Config/CarAliases integrity, CarTemplates.prepare on the
-- real-engine import layout (docs/v2/early/vehicles/cloud_probe.json), and every v2 car built through CarBuilder on a
-- stand-in template laid out exactly like the Open Cloud GLB importer leaves an upload (root Model, one
-- "<Object>_Node" Model per object, geometry turned 180 degrees about Y, identity part rotations): model contract,
-- wheel count and placement, seat, lights, sirens, paint, part budget, late in-place conversion, unique names.
return function(t)
	local H = t.H
	local Instance = H.roblox.Instance
	local Vector3 = H.roblox.Vector3
	local CFrame = H.roblox.CFrame
	local Color3 = H.roblox.Color3
	local Enum = H.roblox.Enum
	local fs = require("@lune/fs")
	local serde = require("@lune/serde")

	H.setMode("server")
	local Vehicles = H.require("src/shared/Config/Vehicles")
	local Cars = H.require("src/shared/Config/Cars")
	local CarAliases = H.require("src/shared/Config/CarAliases")
	local Rarity = H.require("src/shared/Config/Rarity")
	local CarBuilder = H.require("src/shared/Vehicle/CarBuilder")
	local CarTemplates = H.require("src/shared/Vehicle/CarTemplates")
	local MeshCar = H.require("src/shared/Vehicle/MeshCar")

	local MAIN = { "FL", "FR", "RL", "RR" }
	local V1_IDS = {
		"rustbucket",
		"grandma_sedan",
		"yellow_cab",
		"pizza_van",
		"mini_bean",
		"hot_hatch",
		"dirt_hauler",
		"family_suv",
		"ice_cream",
		"bull_charger",
		"stallion_gt",
		"bigfoot",
		"viper_strike",
		"stretch_limo",
		"retired_cruiser",
		"raging_bull",
		"crusher",
		"phantom_gt",
		"neon_drift",
		"bank_truck",
		"hyperion_x",
		"gold_rush",
		"midnight_phantom",
		"rocket_car",
		"night_raven",
		"hover_car",
		"mini_tank",
		"hotdog_wagon",
		"rubber_ducky",
		"couch_cruiser",
		"toilet_turbo",
		"diamond_dragster",
	}
	-- names that must never reach the game: GTA vehicle names / makes and real car brands
	local BANNED = {
		"phoenix",
		"cheetah",
		"burrito",
		"dukes",
		"infernus",
		"banshee",
		"stallion",
		"comet",
		"adder",
		"zentorno",
		"elegy",
		"sultan",
		"futo",
		"faggio",
		"vapid",
		"declasse",
		"bravado",
		"albany",
		"benefactor",
		"grotti",
		"pegassi",
		"dinka",
		"karin",
		"ubermacht",
		"obey",
		"maibatsu",
		"jobuilt",
		"brute",
		"mammoth",
		"dewbauchee",
		"illinois",
		"fairheaven",
		"shvan",
		"lightbody",
		"trinity",
		"goblin",
		"ford",
		"chevrolet",
		"chevy",
		"dodge",
		"nissan",
		"toyota",
		"honda",
		"mercedes",
		"benz",
		"bmw",
		"mclaren",
		"lamborghini",
		"ferrari",
		"cadillac",
		"lincoln",
		"hummer",
		"impala",
		"civic",
		"silvia",
		"porsche",
		"audi",
		"volkswagen",
		"jeep",
		"gmc",
		"isuzu",
		"man ",
		"kawasaki",
		"yamaha",
		"suzuki",
	}
	local BANDS = {
		Common = { 3, 7, 120, 400 },
		Uncommon = { 14, 24, 1000, 2400 },
		Rare = { 55, 75, 7000, 11000 },
		Epic = { 220, 320, 40000, 65000 },
		Legendary = { 900, 1300, 250000, 400000 },
		Mythic = { 4000, 6000, 1500000, 2500000 },
		Secret = { 20000, 40000, 10000000, 30000000 },
	}

	-- What the importer hands back for spec `spec` (see the header): sizes / centres from the spec's MeshPart boxes.
	local function fakeImport(spec)
		local root = Instance.new("Model")
		root.Name = "HC car " .. spec.brand .. " " .. spec.model
		for name, box in spec.parts do
			local node = Instance.new("Model")
			node.Name = name .. "_Node"
			node.Parent = root
			local mp = Instance.new("MeshPart")
			mp.Name = name
			mp.Size = box.size
			mp.CFrame = CFrame.new(-box.center.X, box.center.Y, -box.center.Z) -- turned 180 degrees about Y
			mp.Anchored = true
			mp.Parent = node
			if name == "Trim" or name == "Interior" or string.sub(name, 1, 5) == "Wheel" then
				local sa = Instance.new("SurfaceAppearance")
				sa.Parent = mp
			end
		end
		local junk = Instance.new("Script")
		junk.Parent = root
		return root
	end

	local function installFolder()
		local f = Instance.new("Folder")
		f.Name = CarTemplates.FOLDER_NAME
		H.replicated[CarTemplates.FOLDER_NAME] = f
		return f
	end
	local function removeFolder()
		local f = H.replicated[CarTemplates.FOLDER_NAME]
		H.replicated[CarTemplates.FOLDER_NAME] = nil
		if f then
			f:Destroy()
		end
	end
	-- Publish stand-in templates for `specs` (all when nil) while fn runs; always removed afterwards.
	local function withTemplates(specs, fn)
		installFolder()
		local ok, err = pcall(function()
			for _, spec in specs or Vehicles.List do
				local tpl = CarTemplates.prepare(fakeImport(spec), spec)
				assert(tpl, "prepare " .. spec.id)
				CarTemplates.publish(spec.id, tpl)
			end
			fn()
		end)
		removeFolder()
		if not ok then
			error(err, 0)
		end
	end

	local function partsOf(model)
		local out = {}
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(out, d)
			end
		end
		return out
	end
	local function vnear(a, b, eps, msg)
		t.ok((a - b).Magnitude <= eps, ("%s: %s vs %s"):format(msg, tostring(a), tostring(b)))
	end

	-- one catalog def per vehicle (+ police units) for the build tests
	local defsByVehicle = {}
	for _, def in Cars.List do
		if def.vehicle and not defsByVehicle[def.vehicle] then
			defsByVehicle[def.vehicle] = def
		end
	end
	for _, def in Cars.PoliceUnits do
		defsByVehicle[def.vehicle] = def
	end

	---------------------------------------------------------------------------------------------------------- config
	t.test("Config/Vehicles: geometry, budget, seat, lights, paints for every uploaded car model", function()
		t.ok(#Vehicles.List >= 20, "roster size " .. #Vehicles.List)
		for _, s in Vehicles.List do
			local id = s.id
			t.ok(Vehicles.get(id) == s, id .. " lookup")
			t.ok(s.length > 8 and s.length < 50, id .. " length " .. s.length)
			t.ok(s.width > 4 and s.width < 12, id .. " width " .. s.width)
			t.ok(s.height > 3 and s.height < 13, id .. " height " .. s.height)
			t.ok(s.tris > 2000 and s.tris <= 18000, id .. " triangles " .. s.tris)
			t.ok(s.mass >= 900 and s.mass <= 3000, id .. " mass")
			t.ok(s.parts.Body ~= nil, id .. " has a Body MeshPart")
			t.ok(#s.paints >= 1, id .. " paints")
			t.eq(#s.lightsFront, 2, id .. " two headlamps")
			t.eq(#s.lightsRear, 2, id .. " two tail lamps")
			local keys = {}
			for _, w in s.wheels do
				keys[w.key] = w
				t.ok(w.radius > 0.6 and w.radius < 3, id .. " wheel radius")
				t.near(w.center.Y - w.radius, 0, 0.2, id .. " " .. w.key .. " rests on the ground")
				t.ok(s.parts["Wheel" .. w.key] ~= nil, id .. " wheel MeshPart " .. w.key)
				t.near(w.partCenter.Y, w.center.Y, 0.08, id .. " part centre on the axle height")
			end
			for _, k in MAIN do
				t.ok(keys[k] ~= nil, id .. " wheel " .. k)
			end
			t.ok(keys.FL.center.X < 0 and keys.FR.center.X > 0, id .. " left = -X")
			t.ok(keys.FL.center.Z < keys.RL.center.Z, id .. " front = -Z")
			t.ok(s.seat.X < 0, id .. " left-hand drive")
			t.ok(s.seat.Y > 0.5 and s.seat.Y < s.height, id .. " seat height")
			t.ok(math.abs(s.seat.Z) < s.length / 2, id .. " seat inside the car")
			for _, p in s.lightsFront do
				t.ok(p.Z < 0, id .. " headlamp at the front")
			end
			for _, p in s.lightsRear do
				t.ok(p.Z > 0, id .. " tail lamp at the back")
			end
			t.ok(s.credit ~= "", id .. " CC-BY credit")
			t.ok(s.bodyMode == "paint" or s.bodyMode == "livery", id .. " body mode")
		end
	end)

	t.test("Config/Vehicles: police models carry split lightbar lenses, the taxi its roof sign", function()
		for _, id in { "brookline_interceptor", "trailhead_patrol" } do
			local s = Vehicles.get(id)
			t.ok(s and s.sirenRed and s.sirenBlue, id .. " lightbar split")
			t.ok(s.parts.SirenRed and s.parts.SirenBlue, id .. " siren MeshParts")
			t.ok(s.sirenRed.center.Y > s.height * 0.8, id .. " lightbar on the roof")
		end
		t.ok(Vehicles.get("brookline_cab").sign ~= nil, "taxi sign object")
	end)

	t.test("Cars v2: realistic parody names, bands, vehicles, stable v1 ids, aliases", function()
		local seenNames = {}
		for _, def in Cars.List do
			local id = def.id
			t.ok(def.vehicle ~= nil and Vehicles.get(def.vehicle) ~= nil, id .. " has an uploaded model spec")
			t.eq(def.name, def.brand .. " " .. def.model, id .. " display name = brand + model")
			local lower = string.lower(def.name .. " " .. (def.flavor or ""))
			for _, bad in BANNED do
				t.ok(
					string.find(lower, "%f[%a]" .. bad .. "%f[%A]") == nil,
					("%s: banned name %q in %q"):format(id, bad, lower)
				)
			end
			t.ok(not seenNames[def.name], "unique display name " .. def.name)
			seenNames[def.name] = true
			local band = BANDS[def.rarity]
			if band then
				t.ok(def.income >= band[1] and def.income <= band[2], id .. " income in band")
				t.ok(def.price >= band[3] and def.price <= band[4], id .. " price in band")
			end
		end
		for _, def in Cars.PoliceUnits do
			t.ok(def.police == true and Vehicles.get(def.vehicle) ~= nil, def.id .. " police unit model")
		end
		-- every v1 id still resolves: kept as-is, or aliased to the closest-value realistic car
		for _, id in V1_IDS do
			local def = Cars.get(id)
			t.ok(def ~= nil, "v1 id resolves: " .. id)
			if CarAliases.isAlias(id) then
				t.ok(Cars.ById[id] == nil, id .. " left the catalog")
				t.eq(def.id, CarAliases.Map[id], id .. " alias target")
			else
				t.eq(def.id, id, id .. " kept its id")
			end
		end
		for from, to in CarAliases.Map do
			t.ok(Cars.ById[to] ~= nil, ("alias %s -> %s exists"):format(from, to))
			t.ok(Cars.ById[from] == nil, from .. " is not also a catalog id")
			t.eq(CarAliases.resolve(from), to, "resolve " .. from)
		end
		t.eq(CarAliases.resolve("rustbucket"), "rustbucket", "non-alias resolves to itself")
		t.eq(Cars.get("rustbucket").name, "Halden Wren", "starter car name")
	end)

	----------------------------------------------------------------------------------------------- templates
	t.test("CarTemplates.solveFrame undoes the importer's 180-degree turn and a unit scale", function()
		local want = {
			FL = Vector3.new(-2, 1, -5),
			FR = Vector3.new(2, 1, -5),
			RL = Vector3.new(-2, 1, 5),
			RR = Vector3.new(2, 1, 5),
		}
		local got = {}
		for k, v in want do
			got[k] = Vector3.new(-v.X, v.Y, -v.Z) * 0.5 + Vector3.new(10, 3, -4)
		end
		local frame, scale, pivot = CarTemplates.solveFrame(got, want)
		t.ok(frame ~= nil, "solved")
		t.near(scale, 2, 1e-6, "scale")
		for k, v in want do
			vnear(frame:PointToWorldSpace((got[k] - pivot) * scale), v, 1e-4, k)
		end
		t.eq(CarTemplates.wheelKey("WheelFL"), "FL", "wheel key")
		t.eq(CarTemplates.wheelKey("WheelMR2"), "MR2", "extra axle key")
		t.eq(CarTemplates.wheelKey("Wheel_FL"), nil, "rig names are not import names")
	end)

	t.test("CarTemplates.prepare on the real-engine import (cloud probe of the uploaded police cruiser)", function()
		local probe = serde.decode("json", fs.readFile("docs/v2/early/vehicles/cloud_probe.json"))
		local car = nil
		for _, c in probe.cars do
			if c.vid == "brookline_interceptor" and c.ok then
				car = c
			end
		end
		t.ok(car ~= nil, "probe has the cruiser")
		local spec = Vehicles.get("brookline_interceptor")
		-- rebuild the imported tree from the probe: classes, names, parents, CFrames and sizes as the engine reported
		local root = Instance.new("Model")
		local nodes = {}
		for _, e in car.instances do
			if e.class == "Model" and e.parent and string.find(e.parent, "Model:HC car", 1, true) then
				local m = Instance.new("Model")
				m.Name = e.name
				m.Parent = root
				nodes[e.name] = m
			end
		end
		local meshes = 0
		for _, e in car.instances do
			if e.class == "MeshPart" then
				meshes += 1
				local mp = Instance.new("MeshPart")
				mp.Name = e.name
				mp.Size = Vector3.new(e.size[1], e.size[2], e.size[3])
				local c = e.cframe
				local pos = Vector3.new(c.pos[1], c.pos[2], c.pos[3])
				local look = Vector3.new(c.look[1], c.look[2], c.look[3])
				local up = Vector3.new(c.up[1], c.up[2], c.up[3])
				mp.CFrame = CFrame.lookAt(pos, pos + look, up)
				local parentName = string.match(e.parent, "^Model:(.+)$")
				mp.Parent = nodes[parentName] or root
				if e.surfaceAppearance then
					Instance.new("SurfaceAppearance").Parent = mp
				end
			end
		end
		t.ok(meshes >= 12, "probe lists the MeshParts")
		t.ok(nodes.Body_Node ~= nil, "importer wraps objects in <Name>_Node models")
		local tpl = CarTemplates.prepare(root, spec)
		t.ok(tpl ~= nil, "prepared")
		for name, box in spec.parts do
			local p = tpl:FindFirstChild(name)
			t.ok(p ~= nil, "template part " .. name)
			vnear(p.CFrame.Position, box.center, 0.02, name .. " lands on the sidecar centre")
			-- the importer turned the geometry 180 degrees with identity part rotations: prepare turns the parts back
			t.ok(p.CFrame.LookVector.Z > 0.99, name .. " part turned back 180 degrees")
		end
		vnear(tpl.WheelFL.CFrame.Position, spec.wheels[1].partCenter, 0.02, "front-left wheel at front-left")
		t.ok(tpl.LightsFront.CFrame.Position.Z < 0, "headlamps at -Z after preparation")
		t.ok(tpl.Trim:FindFirstChildOfClass("SurfaceAppearance") ~= nil, "PBR SurfaceAppearance kept")
		t.eq(tpl:GetAttribute("TemplateScale"), 1, "studs in, studs out")
		for _, p in tpl:GetChildren() do
			t.ok(p:IsA("BasePart") and p.Anchored and not p.CanCollide, "template parts anchored, non-colliding")
		end
	end)

	t.test("CarTemplates.prepare rejects imports without the four wheels or a Body", function()
		local spec = Vehicles.get("nami")
		local raw = fakeImport(spec)
		raw:FindFirstChild("WheelRR", true):Destroy()
		t.eq(CarTemplates.prepare(raw, spec), nil, "no RR wheel")
		local raw2 = fakeImport(spec)
		raw2:FindFirstChild("Body", true):Destroy()
		t.eq(CarTemplates.prepare(raw2, spec), nil, "no Body")
	end)

	-------------------------------------------------------------------------------------------------- builds
	t.test("every v2 car builds on its template: contract, wheels, seat, lights, paint, budget", function()
		withTemplates(nil, function()
			for vid, def in defsByVehicle do
				local spec = Vehicles.get(vid)
				local m = if def.id == Cars.Police.id or def.id == Cars.PoliceSUV.id
					then CarBuilder.buildDef(def, "None")
					else CarBuilder.build(def.id, "None")
				local id = vid
				t.eq(m:GetAttribute("MeshCar"), true, id .. " mesh car")
				t.eq(m:GetAttribute("Vehicle"), vid, id .. " Vehicle attribute")
				t.eq(m:GetAttribute("MeshPending"), nil, id .. " not pending")
				local chassis = m.PrimaryPart
				t.ok(chassis and chassis.Name == "Chassis", id .. " chassis primary")
				t.eq(chassis.Transparency, 1, id .. " chassis invisible")
				t.ok(chassis.CanCollide and not chassis.Anchored and not chassis.Massless, id .. " chassis physics")
				local cpp = chassis.CustomPhysicalProperties
				local mass = cpp.Density * chassis.Size.X * chassis.Size.Y * chassis.Size.Z
				t.ok(mass >= 850 and mass <= 3100, ("%s mass %.0f"):format(id, mass))
				t.ok(
					chassis.CFrame.Position.Y - chassis.Size.Y / 2 >= MeshCar.CHASSIS_MIN_BOTTOM - 1e-3,
					id .. " curb clearance"
				)
				t.near(m:GetAttribute("RideHeight"), chassis.CFrame.Position.Y, 1e-4, id .. " RideHeight")
				t.ok(m:GetPivot().LookVector.Z < -0.99, id .. " faces -Z")
				t.eq(m.ModelStreamingMode, Enum.ModelStreamingMode.Atomic, id .. " atomic")
				-- wheels: attachments at the axles, MeshParts on welds that WheelAnimator can pose
				local wheelParts = 0
				for _, w in spec.wheels do
					local part = m:FindFirstChild("Wheel_" .. w.key)
					t.ok(part and part:IsA("MeshPart"), id .. " wheel part " .. w.key)
					wheelParts += 1
					vnear(part.CFrame.Position, w.partCenter, 1e-3, id .. " " .. w.key .. " wheel position")
					t.ok(not part.CanCollide and part.Massless and not part.Anchored, id .. " wheel quiet")
					local weld = chassis:FindFirstChild("WheelWeld_" .. w.key)
					t.ok(
						weld and weld:IsA("Weld") and weld.Part0 == chassis and weld.Part1 == part,
						id .. " weld " .. w.key
					)
					vnear(
						(chassis.CFrame * weld.C0 * weld.C1:Inverse()).Position,
						part.CFrame.Position,
						1e-3,
						id .. " weld pose"
					)
					if table.find(MAIN, w.key) then
						local att = chassis:FindFirstChild("Wheel" .. w.key)
						t.ok(att and att:IsA("Attachment"), id .. " attachment " .. w.key)
						vnear(chassis.CFrame:PointToWorldSpace(att.Position), w.center, 1e-3, id .. " hub " .. w.key)
					end
				end
				t.ok(wheelParts >= 4, id .. " wheel count")
				-- seat
				local seat = m:FindFirstChild("DriverSeat")
				t.ok(seat and seat:IsA("VehicleSeat") and seat.Disabled and seat.Transparency == 1, id .. " seat")
				t.ok(seat.CFrame.Position.X < 0, id .. " driver on the left")
				t.near(
					seat.CFrame.Position.Y + seat.Size.Y / 2,
					spec.seat.Y - MeshCar.SEAT_SINK,
					1e-3,
					id .. " seat top"
				)
				local bump = 0
				for _, c in m:GetChildren() do
					if c.Name == "BumpStop" then
						bump += 1
					end
				end
				t.eq(bump, 2, id .. " bump stops")
				-- lights
				local heads, beams, tails = 0, 0, 0
				for _, d in m:GetDescendants() do
					if d:IsA("BasePart") and d.Name == "Headlight" then
						heads += 1
						if d:FindFirstChild("Beam") then
							beams += 1
						end
					elseif d:IsA("BasePart") and d.Name == "Taillight" then
						tails += 1
					end
				end
				t.eq(heads, 2, id .. " headlight anchors")
				t.eq(beams, 2, id .. " beams")
				t.eq(tails, 2, id .. " taillight anchors")
				t.ok(
					m:FindFirstChild("BrakeGlow", true) ~= nil and m:FindFirstChild("ReverseGlow", true) ~= nil,
					id .. " lamps"
				)
				if m:FindFirstChild("LightsFront") then
					t.eq(m.LightsFront:GetAttribute("Lens"), "front", id .. " front lens tagged")
				end
				if m:FindFirstChild("LightsRear") then
					t.eq(m.LightsRear:GetAttribute("Lens"), "rear", id .. " rear lens tagged")
				end
				-- paint
				local body = m:FindFirstChild("Body")
				t.eq(body:GetAttribute("Paint"), "primary", id .. " Body is the paint")
				if spec.bodyMode == "paint" then
					t.ok(body.Color == def.color, id .. " paint colour")
				end
				if spec.bodyImage > 0 then
					t.eq(body.TextureID, "rbxassetid://" .. spec.bodyImage, id .. " body image")
				end
				local glass = m:FindFirstChild("Glass")
				if glass then
					t.eq(glass:GetAttribute("Paint"), "glass", id .. " glass tag")
					t.eq(glass.Material, Enum.Material.Glass, id .. " glass material")
				end
				-- every other part: welded, quiet
				local parts = partsOf(m)
				t.ok(#parts <= 40, ("%s has %d parts"):format(id, #parts))
				for _, p in parts do
					if p ~= chassis and p.Name ~= "BumpStop" then
						t.ok(not p.CanCollide and p.Massless and not p.Anchored, id .. " quiet " .. p.Name)
					end
				end
				-- display variant
				local disp = if def.id == Cars.Police.id or def.id == Cars.PoliceSUV.id
					then CarBuilder.buildDef(def, "None", { forDisplay = true })
					else CarBuilder.build(def.id, "None", { forDisplay = true })
				t.ok(
					disp:FindFirstChild("DriverSeat") == nil and disp:FindFirstChild("BumpStop") == nil,
					id .. " display"
				)
				t.eq(disp:GetAttribute("MeshCar"), true, id .. " display mesh car")
			end
		end)
	end)

	t.test("police units light their lightbar; the retired cruiser's stays dark; taxi sign renamed", function()
		withTemplates({ Vehicles.get("brookline_interceptor"), Vehicles.get("brookline_cab") }, function()
			local unit = CarBuilder.buildDef(Cars.Police, "None")
			t.eq(unit.SirenRed.Material, Enum.Material.Neon, "police red lens neon")
			t.eq(unit.SirenBlue.Material, Enum.Material.Neon, "police blue lens neon")
			local retired = CarBuilder.build("retired_cruiser", "None")
			t.ok(retired.SirenRed.Material ~= Enum.Material.Neon, "retired: dark lightbar")
			local cab = CarBuilder.build("yellow_cab", "None")
			t.ok(cab:FindFirstChild("TaxiSign") ~= nil, "taxi roof sign")
		end)
	end)

	t.test("PivotTo a ground CFrame like VehicleService puts the v2 wheels on that ground", function()
		withTemplates({ Vehicles.get("transit") }, function()
			local m = CarBuilder.build("brennan_transit", "None")
			local ground = CFrame.new(120, 5, -40) * CFrame.Angles(0, 1.1, 0)
			m:PivotTo(ground * CFrame.new(0, m:GetAttribute("RideHeight"), 0))
			for _, w in Vehicles.get("transit").wheels do
				local part = m:FindFirstChild("Wheel_" .. w.key)
				local rel = ground:PointToObjectSpace(part.CFrame.Position)
				t.near(rel.Y - w.radius, 0, 0.12, "bus wheel " .. w.key .. " on the ground")
			end
			t.ok(#Vehicles.get("transit").wheels >= 4, "bus wheels")
		end)
	end)

	t.test("mutations, repaint and rainbow parts on a mesh car", function()
		withTemplates({ Vehicles.get("nami") }, function()
			local m = CarBuilder.build("mini_bean", "Gold")
			t.eq(m:GetAttribute("Mutation"), "Gold", "mutation attribute")
			t.ok(m.Body.Color == Rarity.Mutations.Gold.color, "gold body")
			CarBuilder.applyMutation(m, "None")
			t.ok(m.Body.Color == Cars.ById.mini_bean.color, "None restores the factory paint")
			local red = Color3.fromRGB(150, 20, 30)
			CarBuilder.repaint(m, red)
			t.ok(m.Body.Color == red, "repaint colours the Body MeshPart")
			local d = CarBuilder.build("mini_bean", "Diamond")
			t.ok(d:FindFirstChild(CarBuilder.SPARKLES_NAME, true) ~= nil, "diamond sparkles on a mesh car")
		end)
	end)

	t.test("no template: procedural fallback marked MeshPending; Index cards stay procedural", function()
		removeFolder()
		local m = CarBuilder.build("viper_strike", "None")
		t.eq(m:GetAttribute("MeshCar"), nil, "procedural")
		t.eq(m:GetAttribute("MeshPending"), "hayate", "pending vehicle id")
		t.ok(m:FindFirstChild("Wheel_FL"):GetAttribute("Proc") == true, "procedural parts tagged")
		t.ok(m:FindFirstChild("DriverSeat"):GetAttribute("Proc") == nil, "seat is rig, not visuals")
		withTemplates({ Vehicles.get("hayate") }, function()
			local card = CarBuilder.build("viper_strike", "None", { forDisplay = true, noShell = true })
			t.eq(card:GetAttribute("MeshCar"), nil, "noShell card procedural")
			t.eq(CarBuilder.applyShell(card), false, "cards never convert")
		end)
	end)

	t.test("late template: a placed procedural car converts in place (same chassis, seat, ground)", function()
		removeFolder()
		local m = CarBuilder.build("hot_hatch", "Gold")
		local ground = CFrame.new(300, 12, 80) * CFrame.Angles(0, 2.2, 0)
		m:PivotTo(ground * CFrame.new(0, m:GetAttribute("RideHeight"), 0))
		local chassis, seat = m.PrimaryPart, m:FindFirstChild("DriverSeat")
		chassis.Anchored = true
		local prompt = Instance.new("ProximityPrompt")
		prompt.Parent = chassis
		t.eq(CarBuilder.applyMesh(m), false, "nothing to convert to yet")
		withTemplates({ Vehicles.get("kaze") }, function()
			t.eq(CarBuilder.applyShell(m), true, "applyShell routes to applyMesh")
			t.eq(m:GetAttribute("MeshCar"), true, "converted")
			t.eq(m:GetAttribute("MeshPending"), nil, "no longer pending")
			t.ok(m.PrimaryPart == chassis and m:FindFirstChild("DriverSeat") == seat, "same chassis + seat instances")
			t.ok(prompt.Parent == chassis, "prompts on the chassis survive")
			t.eq(m:GetAttribute("RigVersion"), 1, "rig version bumped")
			for _, p in partsOf(m) do
				t.ok(p:GetAttribute("Proc") ~= true, "procedural part left: " .. p.Name)
			end
			local spec = Vehicles.get("kaze")
			t.near(chassis.Size.X, spec.parts.Body.size.X * MeshCar.CHASSIS_WIDTH, 1e-4, "chassis resized")
			for _, w in spec.wheels do
				local part = m:FindFirstChild("Wheel_" .. w.key)
				local rel = ground:PointToObjectSpace(part.CFrame.Position)
				t.near(rel.Y - w.radius, 0, 0.12, w.key .. " wheel stays on the original ground")
				local weld = chassis:FindFirstChild("WheelWeld_" .. w.key)
				t.ok(weld and weld.Part1 == part, w.key .. " weld re-pointed")
			end
			t.ok(m.Body.Color == Rarity.Mutations.Gold.color, "mutation re-applied")
			t.ok(seat.CFrame.Position.Y < chassis.CFrame.Position.Y + chassis.Size.Y, "seat moved into the mesh cabin")
			t.eq(CarBuilder.applyMesh(m), true, "idempotent")
		end)
	end)

	t.test("AssetLibrary never loads the v1 hero shell of a car with a v2 model", function()
		local AssetLibrary = H.require("src/server/Systems/AssetLibrary")
		local Assets = H.require("src/shared/Config/Assets")
		for key, def in Assets.Hero do
			if CarBuilder.hasMesh(key) then
				t.eq(AssetLibrary.wanted("Hero", key, def), false, key .. " hero skipped")
			end
		end
		t.ok(CarBuilder.hasMesh("police_unit"), "police unit has a v2 model")
		t.ok(CarBuilder.hasMesh("toilet_turbo"), "aliased meme id resolves to a v2 car")
	end)

	--------------------------------------------------------------------------------------- service + client helpers
	t.test("VehicleService: unique model names and factory paints", function()
		local VehicleService = H.require("src/server/Systems/VehicleService")
		t.eq(VehicleService.modelName("yellow_cab", 7), "yellow_cab_7", "car id + VehicleId")
		t.ok(VehicleService.modelName("yellow_cab", 7) ~= VehicleService.modelName("yellow_cab", 8), "unique")
		local rng = H.Random.new(5)
		local seen = {}
		for _ = 1, 60 do
			local c = VehicleService._factoryPaint(Cars.ById.mini_bean, "Parked", nil, rng)
			t.ok(c ~= nil, "street car gets a factory paint")
			seen[c:ToHex()] = true
		end
		local n = 0
		for _ in seen do
			n += 1
		end
		t.ok(n >= 3, "several palette colours used")
		t.eq(VehicleService._factoryPaint(Cars.ById.yellow_cab, "Parked", nil, rng), nil, "liveries keep their colours")
		t.eq(VehicleService._factoryPaint(Cars.ById.mini_bean, "Owned", nil, rng), nil, "owned cars keep theirs")
		local red = Color3.fromRGB(200, 0, 0)
		t.ok(VehicleService._factoryPaint(Cars.ById.yellow_cab, "Owned", red, rng) == red, "explicit paint wins")
	end)

	t.test("WheelAnimator: camera-inside test (BACKLOG 4) and brake / reverse lamps", function()
		H.setMode("client")
		local ok, err = pcall(function()
			local WheelAnimator = H.require("src/client/Controllers/WheelAnimator")
			local size = Vector3.new(6, 5, 17) -- width, height, length
			local inside = WheelAnimator.cameraInside
			t.ok(inside(Vector3.new(0, 0, 0), 2, Vector3.zero, size, 0.4), "centre of the cabin")
			t.ok(inside(Vector3.new(2.9, -1.9, 8.2), 2, Vector3.zero, size, 0.4), "corner inside")
			t.ok(not inside(Vector3.new(0, 4, 0), 2, Vector3.zero, size, 0.4), "above the roof")
			t.ok(not inside(Vector3.new(0, 0, -12), 2, Vector3.zero, size, 0.4), "chase distance behind")
			t.ok(not inside(Vector3.new(4, 0, 0), 2, Vector3.zero, size, 0.4), "beside the door")
			t.ok(inside(Vector3.new(0, 0, 9.5), 2, Vector3.new(0, 0, 1.5), size, 0.4), "body centre offset")
			local lamp = WheelAnimator.lampState
			local b, r = lamp(20, 22, 0.05, nil)
			t.ok(b and not r, "observed hard deceleration lights the brakes")
			b, r = lamp(20, 20.1, 0.05, nil)
			t.ok(not b, "cruising: no brakes")
			b, r = lamp(-5, -4, 0.05, nil)
			t.ok(r, "reversing")
			b, r = lamp(10, 10, 0.05, -1)
			t.ok(b, "driver braking (throttle back while rolling forward)")
			b, r = lamp(0.5, 0.5, 0.05, -1)
			t.ok(not b, "standing still on reverse throttle is not braking")
		end)
		H.setMode("server")
		if not ok then
			error(err, 0)
		end
	end)
end
