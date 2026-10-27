--!nocheck
-- Art pass AP2 (city dressing): asset slots, budgets, clearance of the DRESSED city (kit bounds from
-- MapBuilder.slotBoxes, i.e. where the meshes will stand), terrain dressing, billboards, MapDresser behaviour.
return function(t)
	local H = t.H
	H.setMode("server")
	local MapBuilder = H.require("src/server/Systems/MapBuilder")
	local MapDresser = H.require("src/server/Systems/MapDresser")
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local MapConfig = H.require("src/shared/Config/Map")
	local Assets = H.require("src/shared/Config/Assets")
	local Vector3, CFrame = H.roblox.Vector3, H.roblox.CFrame
	local CURB_TOP = MapLayout.CURB_TOP
	local S, RW = MapConfig.GRID_SPACING, MapConfig.ROAD_WIDTH

	local folder = MapBuilder.build(H.workspace)
	local slots = MapBuilder.slots(folder)

	local inSlot = {}
	for _, m in slots do
		for _, d in m:GetDescendants() do
			inSlot[d] = m
		end
	end
	local parts = {}
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end

	-- oriented boxes + separating-axis overlap test (exact for rotated slots like the ferris wheel)
	local function obb(cf, size)
		return {
			c = cf.Position,
			ax = { cf.RightVector, cf.UpVector, cf.LookVector },
			h = { size.X / 2, size.Y / 2, size.Z / 2 },
		}
	end
	local function intersects(a, b, eps)
		local axes = { a.ax[1], a.ax[2], a.ax[3], b.ax[1], b.ax[2], b.ax[3] }
		for i = 1, 3 do
			for j = 1, 3 do
				local c = a.ax[i]:Cross(b.ax[j])
				if c.Magnitude > 1e-6 then
					table.insert(axes, c.Unit)
				end
			end
		end
		local d = b.c - a.c
		for _, L in axes do
			local ra, rb = 0, 0
			for i = 1, 3 do
				ra += a.h[i] * math.abs(a.ax[i]:Dot(L))
				rb += b.h[i] * math.abs(b.ax[i]:Dot(L))
			end
			if math.abs(d:Dot(L)) >= ra + rb - eps then
				return false
			end
		end
		return true
	end
	local function aabbBox(minV, maxV)
		return obb(CFrame.new((minV + maxV) / 2), maxV - minV)
	end

	local slotBoxes = {}
	for i, m in slots do
		slotBoxes[i] = {}
		for _, b in MapBuilder.slotBoxes(m) do
			table.insert(slotBoxes[i], obb(b.cframe, b.size))
		end
	end
	local function label(m)
		return ("%s[%s] @%s"):format(m:GetFullName(), tostring(m:GetAttribute("Role")), tostring(m:GetPivot().Position))
	end
	-- slots whose dressed bounds hit a box (lamp / signal arms and canopies only count where they really are)
	local function slotHits(box, filter)
		local out = {}
		for i, m in slots do
			if filter == nil or filter(m) then
				for _, b in slotBoxes[i] do
					if intersects(b, box, 0.05) then
						table.insert(out, label(m))
						break
					end
				end
			end
		end
		return out
	end

	t.test("asset slot budgets (mobile)", function()
		local buildings, props = 0, 0
		for _, m in slots do
			if m:GetAttribute("Category") == "Buildings" then
				buildings += 1
			else
				props += 1
			end
		end
		print(("    [mapdress] slots: %d buildings, %d props"):format(buildings, props))
		t.ok(buildings <= MapBuilder.BUILDING_SLOT_BUDGET, "building slots " .. buildings)
		t.ok(props <= MapBuilder.PROP_SLOT_BUDGET, "prop slots " .. props)
		t.ok(buildings >= 90, "the city has enough buildings: " .. buildings)
		t.ok(props >= 250, "the city has enough props: " .. props)
	end)

	t.test("part budget with and without placeholders", function()
		local placeholder = 0
		for _, p in parts do
			if inSlot[p] then
				placeholder += 1
			end
		end
		local remaining = #parts - placeholder
		print(
			("    [mapdress] parts: %d total, %d in placeholders, %d remain once dressed"):format(
				#parts,
				placeholder,
				remaining
			)
		)
		t.ok(#parts <= MapBuilder.PART_BUDGET, "fallback city parts " .. #parts)
		t.ok(remaining <= MapBuilder.PART_BUDGET, "dressed city procedural parts " .. remaining)
	end)

	t.test("every slot is well-formed and resolves to a Config/Assets key", function()
		local keys = {}
		for _, m in slots do
			local cat, role, fit = m:GetAttribute("Category"), m:GetAttribute("Role"), m:GetAttribute("Fit")
			t.ok(cat == "Buildings" or cat == "Props", "category of " .. m:GetFullName())
			t.ok(type(role) == "string" and role ~= "", "role of " .. m:GetFullName())
			t.ok(type(fit) == "number" and fit > 0, "fit of " .. m:GetFullName())
			local yaw = m:GetAttribute("Yaw")
			t.ok(yaw == nil or type(yaw) == "number", "yaw of " .. m:GetFullName())
			local c, key = MapDresser.resolve(m)
			t.ok(c == cat and key ~= nil and Assets[cat][key] ~= nil, "unresolvable role " .. label(m))
			keys[key] = true
			local pivot = m:GetPivot()
			t.ok(pivot.UpVector.Y > 0.999, "slot pivot upright: " .. label(m))
			-- standing on the curb, the sand, or a pier deck (never floating / sunk)
			local y = pivot.Position.Y
			t.ok(y >= -0.01 and y <= 3, "slot ground height " .. y .. " " .. label(m))
			t.ok(#m:GetChildren() > 0, "placeholder present: " .. label(m))
		end
		-- the kit is actually used: every district role shows up
		for _, k in
			{
				"skyscraper_neon",
				"skyscraper_deco",
				"skyscraper_twist",
				"office_block",
				"apartment_balcony",
				"brick_loft",
				"convenience_store",
				"diner",
				"pizza_shop",
				"donut_shop",
				"gas_station",
				"hotel_beach",
				"beach_villa",
				"surf_shack",
				"suburban_house",
				"warehouse",
				"police_hq",
				"gear_shop",
				"spray_booth",
				"chop_shop",
				"lighthouse",
				"palm_tree_a",
				"palm_tree_b",
				"round_tree",
				"pine_tree",
				"street_lamp",
				"traffic_light",
				"bench",
				"fire_hydrant",
				"trash_can",
				"bus_stop",
				"mailbox",
				"newspaper_box",
				"flower_bed",
				"bush",
				"rock",
				"hotdog_stand",
				"fountain",
				"ferris_wheel",
				"water_tower",
				"lifeguard_tower",
				"beach_umbrella",
				"beach_chair",
				"surfboard_rack",
				"shipping_container",
				"crate_stack",
				"dumpster",
				"car_crusher",
				"oil_barrels",
				"road_barrier",
				"traffic_cone",
				"billboard",
			}
		do
			t.ok(keys[k], "kit asset never placed: " .. k)
		end
	end)

	t.test("districts: zones and their buildings", function()
		t.eq(MapBuilder.zoneOf(-1, -2), "downtown")
		t.eq(MapBuilder.zoneOf(2, 0), "midtown")
		t.eq(MapBuilder.zoneOf(3, 0), "shops")
		t.eq(MapBuilder.zoneOf(-4, 0), "suburbs")
		t.eq(MapBuilder.zoneOf(-5, 0), "suburbs")
		t.eq(MapBuilder.zoneOf(0, -5), "docks")
		t.eq(MapBuilder.zoneOf(4, 0), "beachfront")
		t.eq(MapBuilder.zoneOf(0, 4), "beachfront")
		local allowed = {
			downtown = { skyscraper_neon = true, skyscraper_deco = true, skyscraper_twist = true, office_block = true },
			midtown = { apartment_balcony = true, brick_loft = true, office_block = true, convenience_store = true },
			shops = { diner = true, pizza_shop = true, donut_shop = true, gas_station = true, convenience_store = true },
			suburbs = { suburban_house = true, beach_villa = true },
			beachfront = { hotel_beach = true, beach_villa = true },
			docks = { warehouse = true },
		}
		for _, m in folder.Buildings:GetChildren() do
			local bx, bz = MapLayout.blockAt(m:GetPivot().Position)
			local zone = MapBuilder.zoneOf(bx, bz)
			t.ok(
				allowed[zone][m:GetAttribute("Role")],
				("%s in %s (%d,%d)"):format(m:GetAttribute("Role"), zone, bx, bz)
			)
		end
		-- POI art
		t.ok(folder.POIs.SpawnPlaza:FindFirstChild("Fountain"), "plaza fountain")
		t.ok(folder.POIs.SpawnPlaza:FindFirstChild("HotdogStand"), "plaza hotdog stand")
		t.ok(folder.POIs.Pier:FindFirstChild("FerrisWheelArt"), "pier ferris wheel")
		t.ok(folder.POIs.Pier:FindFirstChild("lighthouse"), "pier lighthouse")
		t.ok(folder.POIs.Park:FindFirstChild("Fountain"), "park fountain")
	end)

	-- functional zones + drive paths that dressed art must never block
	local protected = {}
	local function protect(name, cf, size)
		table.insert(protected, { name = name, box = obb(cf, size) })
	end
	local G = MapConfig.Garage
	for i = 1, MapLayout.plotCount() do
		local cf, size = MapLayout.plotInteriorZone(i)
		protect("plot " .. i .. " interior", cf, size)
		-- driveway from the garage door to the road
		local depth = (S - RW) / 2 + G.FRONT_Z
		protect(
			"plot " .. i .. " driveway",
			MapLayout.plotToWorld(i, Vector3.new(0, 4, G.FRONT_Z + depth / 2 - 2)),
			Vector3.new(G.DOOR_WIDTH + 4, 8, math.abs(depth) + 4)
		)
	end
	for i, cf in MapLayout.dealerPads() do
		protect("dealer pad " .. i, cf * CFrame.new(0, 4.5, 0), Vector3.new(10, 8, 16))
	end
	local dc = MapLayout.poiCenter("Dealership")
	protect("dealership north exit", CFrame.new(dc.X, CURB_TOP + 4, dc.Z - 46), Vector3.new(88, 8, 32))
	for k, z in MapLayout.sprayZones() do
		protect("spray zone " .. k, z.cframe, z.size)
		-- opening from the booth to the north road
		local zc = z.cframe.Position
		local front = zc.Z - z.size.Z / 2
		local roadEdge = math.floor(zc.Z / S) * S + RW / 2
		protect(
			"spray opening " .. k,
			CFrame.new(zc.X, CURB_TOP + 4, (front + roadEdge) / 2),
			Vector3.new(26, 8, math.abs(front - roadEdge) + 2)
		)
	end
	local ccf, csize = MapLayout.chopZone()
	protect("chop zone", ccf, csize)
	local cz = ccf.Position
	local chopRoad = (math.floor(cz.Z / S) + 1) * S - RW / 2
	protect(
		"chop opening",
		CFrame.new(cz.X, CURB_TOP + 4, (cz.Z + chopRoad) / 2),
		Vector3.new(30, 8, chopRoad - cz.Z + 2)
	)
	protect("gear counter", MapLayout.gearShopCounter() * CFrame.new(0, 2, 0), Vector3.new(16, 4, 3))
	protect("gear counter front", MapLayout.gearShopCounter() * CFrame.new(0, 3.5, -6), Vector3.new(12, 6, 8))
	for i, cf in MapLayout.policeSpawns() do
		protect("police spawn " .. i, cf * CFrame.new(0, 3.3, 0), Vector3.new(8, 6, 16))
	end
	for i, cf in MapLayout.hotDropCFrames() do
		protect("hot drop " .. i, cf * CFrame.new(0, 4, 0), Vector3.new(24, 8, 24))
	end
	for i, cf in MapLayout.parkingSpots() do
		protect("parking " .. i, cf * CFrame.new(0, 3.3, 0), Vector3.new(7, 6, 14))
	end
	protect("busted release", MapLayout.bustedReleaseCFrame(), Vector3.new(6, 6, 6))
	protect("spawn", MapLayout.spawnCFrame() * CFrame.new(0, 4, 0), Vector3.new(12, 8, 12))
	-- every road strip at car height
	local ext = MapConfig.HALF_EXTENT + RW / 2
	for line = MapConfig.LINE_MIN, MapConfig.LINE_MAX do
		local c = line * S
		protect("X road " .. line, CFrame.new(0, MapConfig.ROAD_Y + 4.15, c), Vector3.new(ext * 2, 7.7, RW))
		protect("Z road " .. line, CFrame.new(c, MapConfig.ROAD_Y + 4.15, 0), Vector3.new(RW, 7.7, ext * 2))
	end

	t.test("dressed art keeps every functional zone and drive path clear", function()
		local bad = {}
		for _, z in protected do
			local hits = slotHits(z.box)
			if #hits > 0 then
				table.insert(bad, z.name .. " <- " .. table.concat(hits, "; "))
			end
		end
		t.ok(#bad == 0, "blocked:\n      " .. table.concat(bad, "\n      "))
	end)

	t.test("protected-zone check is not vacuous", function()
		-- a fake slot box on the lane of X road 0 must be caught
		local hits = 0
		for _, z in protected do
			if intersects(z.box, obb(CFrame.new(0, 3, 8), Vector3.new(4, 4, 4)), 0.05) then
				hits += 1
			end
		end
		t.ok(hits > 0, "road lane box detected")
		local towers = slotHits(aabbBox(Vector3.new(-310, 20, -310), Vector3.new(-170, 60, -170)))
		t.ok(#towers > 0, "downtown twist tower found by its slot box")
	end)

	t.test("buildings sit inside their lots and never overlap each other or solid props", function()
		local lotHalf = (S - RW) / 2 - MapConfig.SIDEWALK_WIDTH
		local bad = {}
		for i, m in slots do
			if m:GetAttribute("Category") == "Buildings" and m:IsDescendantOf(folder.Buildings) then
				local p = m:GetPivot().Position
				local bx, bz = MapLayout.blockAt(p)
				local c = MapLayout.blockCenter(bx, bz)
				local lot = aabbBox(
					Vector3.new(c.X - lotHalf - 0.5, -10, c.Z - lotHalf - 0.5),
					Vector3.new(c.X + lotHalf + 0.5, 1000, c.Z + lotHalf + 0.5)
				)
				local b = slotBoxes[i][1]
				-- inside: every box corner within the lot
				for _, sx in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local corner = b.c + b.ax[1] * (b.h[1] * sx) + b.ax[3] * (b.h[3] * sz)
						if math.abs(corner.X - c.X) > lotHalf + 0.5 or math.abs(corner.Z - c.Z) > lotHalf + 0.5 then
							table.insert(bad, "leaves its lot: " .. label(m))
						end
					end
				end
				local _ = lot
			end
		end
		for i, a in slots do
			if a:GetAttribute("Category") == "Buildings" then
				for j, b in slots do
					if j ~= i and (b:GetAttribute("Category") == "Props" or j > i) then
						for _, bb in slotBoxes[j] do
							if bb.c.Y - bb.h[2] < CURB_TOP + 6 and intersects(slotBoxes[i][1], bb, 0.3) then
								table.insert(bad, "overlap: " .. label(a) .. " x " .. label(b))
								break
							end
						end
					end
				end
			end
		end
		t.ok(#bad == 0, table.concat(bad, "\n      "))
	end)

	t.test("solid props don't stand inside each other", function()
		local SOFT = { palm_tree = true, tree = true, street_lamp = true, traffic_light = true, billboard = true }
		local bad = {}
		for i, a in slots do
			if a:GetAttribute("Category") == "Props" then
				for j = i + 1, #slots do
					local b = slots[j]
					if b:GetAttribute("Category") == "Props" then
						-- trees / lamps / billboards: only their trunk / pole / post (first box) is solid
						local ba = slotBoxes[i][1]
						local bb = slotBoxes[j][1]
						local ra, rb = a:GetAttribute("Role"), b:GetAttribute("Role")
						if not (SOFT[ra] and SOFT[rb]) and intersects(ba, bb, 0.3) then
							table.insert(bad, label(a) .. " x " .. label(b))
						end
					end
				end
			end
		end
		t.ok(#bad == 0, table.concat(bad, "\n      "))
	end)

	t.test("dressed art clears the procedural walls, posts and signs that stay", function()
		local IGNORE = { BillboardPost = true }
		local solids = {}
		for _, p in parts do
			if
				not inSlot[p]
				and p.CanCollide
				and not IGNORE[p.Name]
				and not p:HasTag("Road")
				and p.Parent ~= folder.Ground
				and p.Parent ~= folder.Beach
				and p.Parent ~= folder.Boundary
				and p.Name ~= "Lot"
				and p.Name ~= "Sidewalk"
				and p.Name ~= "DrivewayRamp"
			then
				table.insert(solids, { part = p, box = obb(p.CFrame, p.Size) })
			end
		end
		local bad = {}
		for i, m in slots do
			for k, b in slotBoxes[i] do
				if k == 1 or m:GetAttribute("Category") == "Buildings" then
					for _, s in solids do
						if intersects(b, s.box, 0.3) then
							table.insert(bad, label(m) .. " x " .. s.part:GetFullName())
						end
					end
				end
			end
		end
		t.ok(#bad == 0, table.concat(bad, "\n      "))
	end)

	t.test("street lamps keep a lit bulb outside the slot", function()
		local lamps = 0
		for _, m in slots do
			if m:GetAttribute("Role") == "street_lamp" then
				lamps += 1
			end
		end
		local bulbs, lit = 0, 0
		for _, p in folder.Props:GetChildren() do
			if p.Name == "LampBulb" then
				bulbs += 1
				t.ok(p:HasTag("StreetLight") and p:HasTag("NightGlow"), "bulb tags")
				t.ok(not inSlot[p], "bulb outside the slot")
				if p:FindFirstChildOfClass("PointLight") then
					lit += 1
				end
			end
		end
		t.eq(bulbs, lamps, "one bulb per lamp")
		t.eq(lit, bulbs, "every bulb has a light")
	end)

	t.test("traffic lights stand at downtown intersections, never on the ring road", function()
		local n = 0
		for _, m in slots do
			if m:GetAttribute("Role") == "traffic_light" then
				n += 1
				local p = m:GetPivot().Position
				local lx, lz = math.round(p.X / S), math.round(p.Z / S)
				t.ok(
					math.abs(lx) < MapConfig.LINE_MAX and math.abs(lz) < MapConfig.LINE_MAX,
					"signal near the ring road"
				)
				t.ok(math.abs(p.X - lx * S) < 40 and math.abs(p.Z - lz * S) < 40, "signal at an intersection")
			end
		end
		t.ok(n >= 9, "traffic lights: " .. n)
	end)

	t.test("billboards: boards tagged, ad decals from Assets.billboardAds()", function()
		local boards = {}
		for _, p in parts do
			if p:HasTag("Billboard") then
				table.insert(boards, p)
				t.ok(not inSlot[p], "board outlives the placeholder: " .. p:GetFullName())
				t.ok(type(p:GetAttribute("AdText")) == "string", "fallback ad text")
			end
		end
		t.ok(#boards >= 10, "billboards: " .. #boards)
		local n = MapDresser.applyBillboards(folder)
		t.eq(n, #boards, "every board got an ad")
		local ads = {}
		for _, a in Assets.billboardAds() do
			ads[a] = true
		end
		local used = {}
		for _, b in boards do
			local front = b:FindFirstChild("AdFront")
			t.ok(front and front:IsA("Decal") and front.Face == H.roblox.Enum.NormalId.Front, "front decal")
			t.ok(ads[front.Texture], "decal uses an ad image")
			used[front.Texture] = true
			if b:GetAttribute("AdBack") then
				t.ok(b:FindFirstChild("AdBack"), "back decal when the back is visible")
			end
			local gui = b:FindFirstChild("SignGui_Front")
			t.ok(gui == nil or gui.Enabled == false, "fallback text hidden under the decal")
			-- deterministic
			t.eq(MapDresser.adFor(b, Assets.billboardAds()), front.Texture)
		end
		local variety = 0
		for _ in used do
			variety += 1
		end
		t.ok(variety >= 4, "ad variety " .. variety)
		t.eq(MapDresser.applyBillboards(folder), 0, "idempotent")
	end)

	t.test("plaza logo sign shows Images.logo_hotwire_city", function()
		local sign = folder.POIs.SpawnPlaza:FindFirstChild("WelcomeSign")
		t.ok(sign, "welcome sign")
		local found = 0
		for _, g in sign:GetChildren() do
			if g:IsA("SurfaceGui") then
				local img = g:FindFirstChildOfClass("ImageLabel")
				t.ok(img and img.Image == Assets.Images.logo_hotwire_city, "logo image")
				found += 1
			end
		end
		t.eq(found, 2, "front + back")
	end)

	t.test("terrain: grass under the park + plaza beds, water kept, clouds", function()
		table.clear(H.terrainOps)
		local terrain = H.workspace:FindFirstChildOfClass("Terrain")
		MapBuilder.buildTerrain(terrain)
		local park = MapLayout.poiCenter("Park")
		local plaza = MapLayout.poiCenter("SpawnPlaza")
		local water, parkGrass, beds = 0, 0, 0
		for _, op in H.terrainOps do
			if op[1] == "FillBlock" then
				local cf, size, mat = op[2], op[3], op[4]
				if mat == H.roblox.Enum.Material.Water then
					water += 1
				elseif mat == H.roblox.Enum.Material.Grass then
					local p = cf.Position
					local top = p.Y + size.Y / 2
					if (Vector3.new(p.X, 0, p.Z) - Vector3.new(park.X, 0, park.Z)).Magnitude < 1 then
						parkGrass += 1
						t.ok(size.X >= 100 and size.Z >= 100, "park lawn covers the lot")
						t.ok(top > CURB_TOP - 0.2 and top < CURB_TOP + 0.6, "lawn surface near curb height: " .. top)
					elseif
						math.abs(math.abs(p.X - plaza.X) - 42) < 1 and math.abs(math.abs(p.Z - plaza.Z) - 42) < 1
					then
						beds += 1
					end
				end
			end
		end
		t.ok(water > 0, "ocean water")
		t.eq(parkGrass, 1, "park grass")
		t.eq(beds, 4, "plaza planter beds")
		local clouds = terrain:FindFirstChildOfClass("Clouds")
		t.ok(clouds, "clouds")
		t.near(clouds.Cover, 0.45, 0.01, "cloud cover")
		t.near(clouds.Density, 0.6, 0.01, "cloud density")
		-- the park lot sits under the grass, every other lot at curb height
		for _, lot in folder.Blocks:GetChildren() do
			if lot.Name == "Lot" then
				local top = lot.CFrame.Position.Y + lot.Size.Y / 2
				if lot:GetAttribute("Poi") == "Park" then
					t.ok(top < CURB_TOP - 0.5, "park lot lowered under the lawn")
				else
					t.near(top, CURB_TOP, 1e-3, "lot top")
				end
			end
		end
	end)

	-- MapDresser with fake templates (the harness has no InsertService) --------------------------------------
	local function fakeTemplate(category, key)
		local def = Assets[category][key]
		local m = H.roblox.Instance.new("Model")
		m.Name = key
		local root = H.roblox.Instance.new("Part")
		root.Name = "AssetRoot"
		root.Size = Vector3.one
		root.Transparency = 1
		root.CFrame = CFrame.new()
		root.Anchored = true
		root.Parent = m
		m.PrimaryPart = root
		local body = H.roblox.Instance.new("MeshPart")
		body.Name = "Mesh"
		body.Size = Vector3.new(def.size, def.size, def.size)
		body.CFrame = CFrame.new(0, def.size / 2, 0)
		body.Anchored = true
		body.CanCollide = false
		body.CanQuery = false
		body.Parent = m
		return m
	end
	local templates = {}
	local missingKey = "flower_bed" -- Creator Store asset: pretend it failed to load
	local fakeSource = {
		get = function(cat, key)
			if key == missingKey or not Assets[cat] or not Assets[cat][key] then
				return nil
			end
			templates[cat .. "/" .. key] = templates[cat .. "/" .. key] or fakeTemplate(cat, key)
			return templates[cat .. "/" .. key]
		end,
	}
	fakeSource.clone = function(cat, key, cf, parent)
		local tpl = fakeSource.get(cat, key)
		if not tpl then
			return nil
		end
		local c = tpl:Clone()
		if cf then
			c:PivotTo(cf)
		end
		if parent then
			c.Parent = parent
		end
		return c
	end

	t.test("MapDresser: resolve picks deterministic variants", function()
		local seen = {}
		for _, m in slots do
			if m:GetAttribute("Role") == "palm_tree" then
				local _, k1 = MapDresser.resolve(m)
				local _, k2 = MapDresser.resolve(m)
				t.eq(k1, k2, "stable variant")
				seen[k1] = true
			end
		end
		t.ok(seen.palm_tree_a and seen.palm_tree_b, "both palm variants used")
	end)

	t.test("MapDresser: dresses every slot, keeps placeholders for missing art", function()
		MapDresser._setSource(fakeSource)
		local expected = {}
		local before = #slots
		for _, m in slots do
			local cat, key = MapDresser.resolve(m)
			local yaw = m:GetAttribute("Yaw") or 0
			expected[m] = {
				cat = cat,
				key = key,
				parent = m.Parent,
				name = m.Name,
				pivot = m:GetPivot() * CFrame.Angles(0, math.rad(yaw), 0),
				factor = m:GetAttribute("Fit") / Assets[cat][key].size,
			}
		end
		local n = MapDresser.dressAll(folder, 0)
		local kept = 0
		for m, e in expected do
			if e.key == missingKey then
				t.ok(m.Parent == e.parent, "placeholder kept when the template is missing")
				kept += 1
			else
				t.ok(m.Parent == nil, "placeholder removed after dressing: " .. e.name)
			end
		end
		t.eq(n, before - kept, "dressed count")
		-- inspect the clones
		local clones = 0
		for _, d in folder:GetDescendants() do
			if d:IsA("Model") and d:GetAttribute("Dressed") == true then
				clones += 1
				t.ok(not d:HasTag("AssetSlot"), "clone is not a slot")
				t.ok(d:FindFirstChild("Mesh") and d:FindFirstChild("AssetRoot"), "clone body + root")
			end
		end
		t.eq(clones, n, "one clone per dressed slot")
		-- remaining procedural parts in the dressed city
		local count = 0
		for _, d in folder:GetDescendants() do
			if d:IsA("BasePart") then
				count += 1
			end
		end
		t.ok(count <= MapBuilder.PART_BUDGET + n * 2, "dressed part count " .. count)
		MapDresser._setSource(nil)
	end)

	-- a fresh map for precise per-slot checks
	t.test("MapDresser: placement, scale, yaw, collisions, shadows", function()
		MapDresser._setSource(fakeSource)
		local map = MapBuilder.build(H.workspace)
		local list = MapBuilder.slots(map)
		local checked = { Buildings = 0, Props = 0 }
		for _, m in list do
			local cat, key = MapDresser.resolve(m)
			if key ~= missingKey then
				local yaw = m:GetAttribute("Yaw") or 0
				local want = m:GetPivot() * CFrame.Angles(0, math.rad(yaw), 0)
				local factor = m:GetAttribute("Fit") / Assets[cat][key].size
				local parent = m.Parent
				local clone = MapDresser.dressSlot(m)
				t.ok(clone and clone.Parent == parent, "clone placed in the slot's folder")
				t.ok(m.Parent == nil, "placeholder gone")
				local root = clone:FindFirstChild("AssetRoot")
				t.ok((root.CFrame.Position - want.Position).Magnitude < 1e-3, "on the slot's ground point")
				t.ok(root.CFrame.LookVector:Dot(want.LookVector) > 0.999, "front faces the slot's front")
				local mesh = clone:FindFirstChild("Mesh")
				local size = Assets[cat][key].size
				t.near(mesh.Size.Y, size * factor, size * 0.011, "scaled to Fit (1% tolerance)")
				t.near(mesh.CFrame.Position.Y - root.CFrame.Position.Y, mesh.Size.Y / 2, 1e-3, "scaled about the root")
				if cat == "Buildings" then
					t.ok(mesh.CanCollide and mesh.CanQuery, "buildings collide")
					t.ok(mesh.CastShadow, "buildings cast shadows")
				else
					t.ok(not mesh.CanCollide and not mesh.CanQuery, "props never collide")
					local big = Assets[cat][key].size * factor >= MapDresser.SMALL_PROP
					t.eq(mesh.CastShadow, big, "small props cast no shadow: " .. key)
				end
				t.ok(not root.CanCollide and not root.CanQuery, "root stays inert")
				t.eq(MapDresser.dressSlot(m), nil, "a dressed slot is not dressed twice")
				checked[cat] += 1
			end
		end
		t.ok(checked.Buildings > 50 and checked.Props > 200, "checked " .. checked.Buildings .. "/" .. checked.Props)
		MapDresser._setSource(nil)
		map:Destroy()
	end)

	t.test("MapDresser: missing templates leave the procedural city intact", function()
		MapDresser._setSource({
			get = function()
				return nil
			end,
			clone = function()
				return nil
			end,
		})
		local map = MapBuilder.build(H.workspace)
		local before = #MapBuilder.slots(map)
		t.eq(MapDresser.dressAll(map, 0), 0, "nothing dressed")
		t.eq(#MapBuilder.slots(map), before, "every placeholder still there")
		MapDresser._setSource(nil)
		map:Destroy()
	end)

	t.test("MapDresser: NoDress slots and pre-dressed boards are left alone", function()
		MapDresser._setSource(fakeSource)
		local map = MapBuilder.build(H.workspace)
		local list = MapBuilder.slots(map)
		local own = list[1]
		own:SetAttribute("NoDress", true)
		t.eq(MapDresser.dressSlot(own), nil, "NoDress respected")
		t.ok(own.Parent ~= nil, "placeholder kept")
		-- boards: a preset image wins, an existing decal means hands off
		local boards = {}
		for _, d in map:GetDescendants() do
			if d:IsA("BasePart") and d:HasTag("Billboard") then
				table.insert(boards, d)
			end
		end
		boards[1]:SetAttribute("AdImage", Assets.Images.ad_hotwire_motors)
		local mine = H.roblox.Instance.new("Decal")
		mine.Texture = Assets.Images.logo_hotwire_city
		mine.Parent = boards[2]
		MapDresser.applyBillboards(map)
		t.eq(boards[1]:FindFirstChild("AdFront").Texture, Assets.Images.ad_hotwire_motors, "preset ad used")
		local decals = 0
		for _, c in boards[2]:GetChildren() do
			if c:IsA("Decal") then
				decals += 1
			end
		end
		t.eq(decals, 1, "a board that already has a decal is not touched")
		MapDresser._setSource(nil)
		map:Destroy()
	end)

	t.test("MapDresser: boot order + public API", function()
		local src = require("@lune/fs").readFile("src/server/init.server.luau")
		local a = src:find('"AssetLibrary"', 1, true)
		local b = src:find('"MapDresser"', 1, true)
		t.ok(a and b and b > a, "MapDresser boots right after AssetLibrary")
		t.eq(type(MapDresser.isDone), "function")
		t.eq(type(MapDresser.Done.Connect), "function")
		t.eq(type(MapDresser.start), "function")
	end)

	if folder.Parent then
		folder:Destroy()
	end
end
