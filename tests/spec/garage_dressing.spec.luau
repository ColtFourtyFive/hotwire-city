--!nocheck
-- Art pass AP2b: garage dressing (AssetSlot wall props for MapDresser, the income-tiered loot corner, posters, logo)
-- and the dealership showroom dressing. Keep-out boxes come straight from Config/Map + MapLayout, not from the
-- services under test.
return function(t)
	local H = t.H
	H.setMode("server")
	local Vector3 = H.roblox.Vector3
	local Enum = H.roblox.Enum
	local MapLayout = H.require("src/shared/Util/MapLayout")
	local MapConfig = H.require("src/shared/Config/Map")
	local Assets = H.require("src/shared/Config/Assets")
	local PlotService = H.require("src/server/Systems/PlotService")
	local Dealer = H.require("src/server/Systems/DealershipService")
	local G = MapConfig.Garage
	local EPS = 0.01

	local models = {}
	local function plot(i)
		if not models[i] then
			models[i] = PlotService.buildGarageModel(i)
		end
		return models[i]
	end

	local function slotsOf(root, tag)
		local out = {}
		for _, d in root:GetDescendants() do
			if d:IsA("Model") and d:HasTag(tag) then
				table.insert(out, d)
			end
		end
		return out
	end

	-- Plot-local XZ bounds (minX, maxX, minZ, maxZ) + height range of a slot from its pivot and Footprint (W, H, D).
	local function slotBox(i, m)
		local cf = MapLayout.plotOrigin(i):ToObjectSpace(m.WorldPivot)
		local fp = m:GetAttribute("Footprint")
		local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local p = cf * Vector3.new(sx * fp.X / 2, 0, sz * fp.Z / 2)
				minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
				minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
			end
		end
		return { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ, y0 = cf.Position.Y, y1 = cf.Position.Y + fp.Y }
	end

	local function overlaps(a, b)
		return a.minX < b.maxX - EPS and a.maxX > b.minX + EPS and a.minZ < b.maxZ - EPS and a.maxZ > b.minZ + EPS
	end

	local function rect(cx, cz, w, d)
		return { minX = cx - w / 2, maxX = cx + w / 2, minZ = cz - d / 2, maxZ = cz + d / 2 }
	end

	-- Keep-out areas in plot-local XZ.
	local carLen = 18 -- stretch limo, the longest car (Config/Assets.Hero sizes)
	local keepOut = {}
	for slot = 1, MapLayout.maxPhysicalSlots() do
		local p = MapLayout.slotLocal(slot).Position
		table.insert(keepOut, { name = "slot " .. slot, box = rect(p.X, p.Z, carLen, G.SLOT_PAD_SIZE.Z) })
	end
	local aisleHalf = G.SLOT_X - carLen / 2 -- between the parked cars' noses
	local rowFront = G.SLOT_ZS[1] - G.SLOT_PAD_SIZE.Z / 2
	local rowBack = G.SLOT_ZS[#G.SLOT_ZS]
	-- center aisle: from the first row to the back row's centerline + half a car width (the hangout strip behind it
	-- along the back wall holds the couch, collect pad and loot)
	table.insert(keepOut, {
		name = "aisle",
		box = { minX = -aisleHalf, maxX = aisleHalf, minZ = rowFront, maxZ = rowBack + 2.5 },
	})
	-- back-row exit lanes: a car pulls straight out 6 studs before it can turn
	for _, sx in { -1, 1 } do
		local a, b = sx * (aisleHalf - 6), sx * aisleHalf
		table.insert(keepOut, {
			name = "exit lane",
			box = {
				minX = math.min(a, b),
				maxX = math.max(a, b),
				minZ = rowBack - G.SLOT_PAD_SIZE.Z / 2,
				maxZ = rowBack + G.SLOT_PAD_SIZE.Z / 2,
			},
		})
	end
	local doorHalf = G.DOOR_WIDTH / 2 + 2
	table.insert(keepOut, {
		name = "door path",
		box = { minX = -doorHalf, maxX = doorHalf, minZ = G.FRONT_Z - 16, maxZ = rowFront },
	})
	table.insert(keepOut, {
		name = "dropoff",
		box = rect(G.DROPOFF_CENTER.X, G.DROPOFF_CENTER.Z, G.DROPOFF_SIZE.X, G.DROPOFF_SIZE.Z),
	})
	table.insert(keepOut, {
		name = "collect pad",
		box = rect(G.COLLECT_CENTER.X, G.COLLECT_CENTER.Z, G.COLLECT_SIZE.X + 2.6, G.COLLECT_SIZE.Z + 2.6),
	})
	table.insert(keepOut, {
		name = "lock button",
		box = rect(G.LOCK_BUTTON.X, G.LOCK_BUTTON.Z + 0.4, 7.2 + 2, 4.8 + 2),
	})
	table.insert(keepOut, { name = "owner spawn", box = rect(G.OWNER_SPAWN.X, G.OWNER_SPAWN.Z, 8, 8) })
	table.insert(keepOut, {
		name = "drive-out spawn",
		box = rect(G.DRIVE_OUT_SPAWN.X, G.DRIVE_OUT_SPAWN.Z, 20, 20),
	})

	t.test("garage slots follow the AssetSlot / LootSlot contract", function()
		for i = 1, MapLayout.plotCount() do
			local m = plot(i)
			local dressing = m:FindFirstChild("Dressing")
			t.ok(dressing ~= nil, "Dressing folder")
			local wall = slotsOf(m, "AssetSlot")
			local loot = slotsOf(m, "LootSlot")
			t.ok(#wall >= 6 and #wall <= 7, ("plot %d: %d wall props"):format(i, #wall))
			t.ok(#loot >= 4 and #loot <= 7, ("plot %d: %d loot slots"):format(i, #loot))
			for _, s in wall do
				t.ok(
					s:IsDescendantOf(dressing),
					s.Name .. " under Plot.Dressing (MapDresser finds it in Workspace.Plots)"
				)
				t.ok(not s:HasTag("LootSlot"), s.Name .. " single tag")
			end
			for _, s in loot do
				t.ok(s:IsDescendantOf(m.Loot), s.Name .. " under Plot.Loot")
				t.ok(not s:HasTag("AssetSlot"), s.Name .. ": MapDresser must not touch loot")
				t.ok(typeof(s:GetAttribute("LootTier")) == "number", s.Name .. " LootTier")
			end
			for _, list in { wall, loot } do
				for _, s in list do
					local role = s:GetAttribute("Role")
					t.eq(s:GetAttribute("Category"), "Props", s.Name .. " Category")
					t.ok(
						Assets.Props[role] ~= nil,
						("%s: role %s in Config/Assets.Props"):format(s.Name, tostring(role))
					)
					local fit = s:GetAttribute("Fit")
					t.ok(typeof(fit) == "number" and fit > 0, s.Name .. " Fit")
					t.ok(typeof(s:GetAttribute("Footprint")) == "Vector3", s.Name .. " Footprint")
					local up = s.WorldPivot.UpVector
					t.ok(up.Y > 0.999, s.Name .. " stands upright")
					local parts = 0
					for _, d in s:GetDescendants() do
						if d:IsA("BasePart") then
							parts += 1
							t.eq(d.CanCollide, false, s.Name .. " placeholder never collides")
							t.eq(d.CastShadow, false, s.Name .. " placeholder shadowless")
						end
					end
					t.ok(parts >= 1, s.Name .. " has a procedural fallback")
				end
			end
		end
	end)

	t.test("every garage has the full prop list and 1-2 car lifts", function()
		local twoLiftPlots = 0
		for i = 1, MapLayout.plotCount() do
			local roles = {}
			for _, s in slotsOf(plot(i), "AssetSlot") do
				local r = s:GetAttribute("Role")
				roles[r] = (roles[r] or 0) + 1
			end
			for _, r in { "tool_chest", "tire_stack", "oil_barrels", "workbench", "garage_shelf" } do
				t.ok((roles[r] or 0) >= 1, ("plot %d has %s"):format(i, r))
			end
			local lifts = roles.car_lift or 0
			t.ok(lifts == 1 or lifts == 2, ("plot %d: %d lifts"):format(i, lifts))
			if lifts == 2 then
				twoLiftPlots += 1
			end
			local loot = {}
			for _, s in slotsOf(plot(i), "LootSlot") do
				loot[s:GetAttribute("Role")] = true
			end
			for _, r in { "money_pile", "gold_bars", "safe_vault", "trophy" } do
				t.ok(loot[r], ("plot %d loot has %s"):format(i, r))
			end
		end
		t.ok(twoLiftPlots >= 1 and twoLiftPlots < MapLayout.plotCount(), "some (not all) garages run two lifts")
	end)

	t.test("dressing stays clear of pads, cars, aisle, drop-off, collect, lock, door and spawns", function()
		for i = 1, MapLayout.plotCount() do
			local m = plot(i)
			local all = {}
			for _, tag in { "AssetSlot", "LootSlot" } do
				for _, s in slotsOf(m, tag) do
					table.insert(all, s)
				end
			end
			for _, s in all do
				local b = slotBox(i, s)
				for _, k in keepOut do
					t.ok(not overlaps(b, k.box), ("plot %d: %s intrudes on %s"):format(i, s.Name, k.name))
				end
				-- inside the walls
				local inX = G.HALF_WIDTH - G.WALL_THICKNESS
				t.ok(
					b.minX >= -inX - EPS and b.maxX <= inX + EPS,
					("plot %d: %s inside the side walls"):format(i, s.Name)
				)
				t.ok(
					b.minZ >= G.FRONT_Z + G.WALL_THICKNESS - EPS and b.maxZ <= G.BACK_Z - G.WALL_THICKNESS + EPS,
					("plot %d: %s inside the front/back walls"):format(i, s.Name)
				)
				-- tall props never hide a bay sign (side walls, 6.7..10.3 up over each pad)
				if b.y1 > 6.6 and (b.maxX > G.HALF_WIDTH - 4 or b.minX < -(G.HALF_WIDTH - 4)) then
					for _, z in G.SLOT_ZS do
						t.ok(
							b.maxZ <= z - 3.5 + EPS or b.minZ >= z + 3.5 - EPS,
							("plot %d: %s hides a bay sign"):format(i, s.Name)
						)
					end
				end
			end
			-- floor props don't overlap each other (stacked loot sits on top: different heights)
			for a = 1, #all do
				for c = a + 1, #all do
					local A, B = slotBox(i, all[a]), slotBox(i, all[c])
					local stacked = A.y0 >= B.y1 - 0.6 or B.y0 >= A.y1 - 0.6 or A.y0 > 0.5 or B.y0 > 0.5
					if not stacked then
						t.ok(not overlaps(A, B), ("plot %d: %s overlaps %s"):format(i, all[a].Name, all[c].Name))
					end
				end
			end
		end
	end)

	t.test("layout is deterministic with per-plot variety", function()
		local sigs = {}
		for i = 1, MapLayout.plotCount() do
			local a, b = PlotService._dressLayout(i), PlotService._dressLayout(i)
			t.eq(#a, #b, "same count")
			local sig = {}
			for k, s in a do
				t.ok((s.cf.Position - b[k].cf.Position).Magnitude < 1e-6 and s.role == b[k].role, "deterministic")
				if s.tier == nil then
					table.insert(
						sig,
						("%s@%d,%d"):format(s.role, math.floor(s.cf.Position.X), math.floor(s.cf.Position.Z))
					)
				end
			end
			table.sort(sig)
			sigs[table.concat(sig, ";")] = true
		end
		local n = 0
		for _ in sigs do
			n += 1
		end
		t.ok(n >= 3, "at least three different garage layouts: " .. n)
	end)

	t.test("loot corner grows with the owner's income", function()
		t.eq(PlotService._lootTier(nil), 0, "no income")
		t.eq(PlotService._lootTier(0 / 0), 0, "NaN")
		t.eq(PlotService._lootTier(99), 0, "below tier 1")
		t.eq(PlotService._lootTier(PlotService.LOOT_TIERS[1]), 1, "tier 1")
		t.eq(PlotService._lootTier(PlotService.LOOT_TIERS[3] + 1), 3, "tier 3")
		t.eq(PlotService._lootTier(1e12), #PlotService.LOOT_TIERS, "capped")
		local m = PlotService.buildGarageModel(2)
		local tiers = PlotService._lootTierModels(m)
		t.eq(#tiers, #PlotService.LOOT_TIERS, "tier models")
		local function visibleLoot()
			return #slotsOf(m, "LootSlot")
		end
		local last = -1
		for tier = 0, #PlotService.LOOT_TIERS do
			PlotService._applyLootTier(m, tiers, tier)
			t.eq(m:GetAttribute("LootTier"), tier, "LootTier attribute")
			local n = visibleLoot()
			t.ok(n > last, ("tier %d shows more loot (%d)"):format(tier, n))
			last = n
			for t2, tm in tiers do
				t.eq(tm.Parent == m.Loot, t2 <= tier, ("tier %d model %d parent"):format(tier, t2))
			end
		end
		PlotService._applyLootTier(m, tiers, 0)
		local base = slotsOf(m, "LootSlot")
		t.eq(#base, 1, "vacant / poor garage keeps just the safe")
		t.eq(base[1]:GetAttribute("Role"), "safe_vault", "the safe")
		-- hidden tiers keep their slots (dressed later while hidden, shown on unlock)
		t.ok(#slotsOf(tiers[4], "LootSlot") >= 1, "hidden tier keeps its slots")
	end)

	t.test("posters and the city logo use Config/Assets.Images art", function()
		local ads = {}
		for _, c in Assets.billboardAds() do
			ads[c] = true
		end
		for i = 1, MapLayout.plotCount() do
			local m = plot(i)
			local origin = MapLayout.plotOrigin(i)
			local posters, logos, seen = 0, 0, {}
			for _, d in m:GetDescendants() do
				if d:IsA("Decal") then
					local part = d.Parent
					if part.Name == "Poster" then
						posters += 1
						t.ok(ads[d.Texture], "poster art is an ad_ image")
						t.ok(not seen[d.Texture], "two different posters")
						seen[d.Texture] = true
						t.eq(d.Face, Enum.NormalId.Front, "poster face")
						-- faces into the garage, on the front wall
						t.ok(part.CFrame.LookVector:Dot(-origin.LookVector) > 0.99, "poster faces inside")
						local lp = origin:PointToObjectSpace(part.CFrame.Position)
						t.ok(
							lp.Z > G.FRONT_Z + G.WALL_THICKNESS and lp.Z < G.FRONT_Z + G.WALL_THICKNESS + 0.6,
							"on the wall"
						)
						t.ok(math.abs(lp.X) - part.Size.X / 2 >= G.DOOR_WIDTH / 2, "beside the door, not over it")
					elseif d.Texture == Assets.Images.logo_hotwire_city then
						logos += 1
					end
				end
			end
			t.eq(posters, 2, ("plot %d posters"):format(i))
			t.ok(logos >= 3, ("plot %d logo decals (sign backing front/back + floor): %d"):format(i, logos))
			local crown = m.Building:FindFirstChild("SignLogo")
			t.ok(crown and crown.CanCollide == false, "logo crown")
			local sign = m.Sign
			t.ok(
				crown.CFrame.Position.Y - crown.Size.Y / 2 >= sign.CFrame.Position.Y + sign.Size.Y / 2,
				"crown above the sign"
			)
		end
	end)

	t.test("garage mesh budget", function()
		-- wall props (MapDresser) + loot (PlotService): <= 14 kit meshes per garage at the richest tier
		for i = 1, MapLayout.plotCount() do
			local n = #slotsOf(plot(i), "AssetSlot") + #slotsOf(plot(i), "LootSlot")
			t.ok(n <= 14, ("plot %d: %d kit meshes"):format(i, n))
		end
	end)

	-- Dealership ------------------------------------------------------------------------------------------------------

	local R = H.roblox
	local c = MapLayout.poiCenter("Dealership")
	local function dealerDressing()
		local folder = R.Instance.new("Folder")
		Dealer.buildShowroom(folder)
		local dressing = Dealer.buildDressing(folder)
		return folder, dressing
	end

	t.test("showroom dressing follows the AssetSlot contract", function()
		local _, dressing = dealerDressing()
		t.ok(dressing and dressing:IsA("Model"), "Dressing model")
		local roles = {}
		for _, s in slotsOf(dressing, "AssetSlot") do
			local cat, role = s:GetAttribute("Category"), s:GetAttribute("Role")
			t.ok(
				Assets[cat] and Assets[cat][role],
				("%s: %s/%s in Config/Assets"):format(s.Name, tostring(cat), tostring(role))
			)
			t.ok(typeof(s:GetAttribute("Fit")) == "number", s.Name .. " Fit")
			t.ok(typeof(s:GetAttribute("Footprint")) == "Vector3", s.Name .. " Footprint")
			roles[role] = true
		end
		for _, r in { "car_showroom", "hotdog_stand" } do
			t.ok(roles[r], "has " .. r)
		end
		t.ok(roles.palm_tree_a or roles.palm_tree_b, "palms")
		local banners = {}
		for _, d in dressing:GetDescendants() do
			if d:IsA("Decal") then
				banners[d.Texture] = (banners[d.Texture] or 0) + 1
			end
		end
		t.ok((banners[Assets.Images.ad_hotwire_motors] or 0) >= 2, "Hotwire Motors banners")
		t.ok((banners[Assets.Images.ad_gold_rush] or 0) >= 1, "Gold Rush banners")
		local _, noBackdrop = (function()
			local f = R.Instance.new("Folder")
			return f, Dealer.buildDressing(f, nil, { backdrop = false })
		end)()
		for _, s in slotsOf(noBackdrop, "AssetSlot") do
			t.ok(s:GetAttribute("Role") ~= "car_showroom", "backdrop can be skipped (MapBuilder already has one)")
		end
	end)

	t.test("showroom dressing never blocks the pads, the drive-out or the restock sign", function()
		local folder, dressing = dealerDressing()
		local padR = 10.7 -- MapBuilder pad rim radius
		local carLenD = 18
		local function boxOf(p)
			local cf, size = p.CFrame, p.Size
			local minV, maxV
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local w = cf * Vector3.new(sx * size.X / 2, sy * size.Y / 2, sz * size.Z / 2)
						minV = if minV then minV:Min(w) else w
						maxV = if maxV then maxV:Max(w) else w
					end
				end
			end
			return minV - c, maxV - c
		end
		local items = {}
		for _, s in slotsOf(dressing, "AssetSlot") do
			local fp = s:GetAttribute("Footprint")
			local cf = s.WorldPivot
			local minV, maxV
			for _, sx in { -1, 1 } do
				for _, sz in { -1, 1 } do
					for _, y in { 0, fp.Y } do
						local w = cf * Vector3.new(sx * fp.X / 2, y, sz * fp.Z / 2)
						minV = if minV then minV:Min(w) else w
						maxV = if maxV then maxV:Max(w) else w
					end
				end
			end
			table.insert(items, { name = s.Name, min = minV - c, max = maxV - c })
		end
		for _, p in dressing:GetDescendants() do
			if p:IsA("BasePart") and not p:FindFirstAncestorWhichIsA("Model"):HasTag("AssetSlot") then
				local mn, mx = boxOf(p)
				table.insert(items, { name = p.Name, min = mn, max = mx })
			end
		end
		local signMin, signMax
		for _, p in folder:GetDescendants() do
			if p:IsA("BasePart") and p:FindFirstAncestor("RestockSign") then
				local mn, mx = boxOf(p)
				signMin = if signMin then signMin:Min(mn) else mn
				signMax = if signMax then signMax:Max(mx) else mx
			end
		end
		for _, it in items do
			-- anything below the canopy can meet a car (hero shells reach ~15 studs) or a walker
			local ground = it.min.Y < Dealer.ROOF_Y - 1.6
			if ground then
				-- pads + parked cars
				for _, pad in MapLayout.dealerPads() do
					local p = pad.Position - c
					local r = math.max(padR, carLenD / 2)
					local hit = it.min.X < p.X + r and it.max.X > p.X - r and it.min.Z < p.Z + r and it.max.Z > p.Z - r
					t.ok(not hit, it.name .. " on a pad")
				end
				-- north drive-out: the open front between the corner pillars' inner faces, from the pads to the road
				local inDrive = it.min.X < 49.2 and it.max.X > -49.2 and it.min.Z < -32.7 and it.max.Z > -60
				t.ok(not inDrive, it.name .. " blocks the north drive-out")
				-- middle aisle between the pad rows
				local inAisle = it.min.X < 50 and it.max.X > -50 and it.min.Z < 11.3 and it.max.Z > -11.3
				t.ok(not inAisle, it.name .. " in the middle aisle")
				-- the sidewalk ring stays walkable
				t.ok(
					it.max.X <= 52.01 and it.min.X >= -52.01 and it.max.Z <= 52.01 and it.min.Z >= -52.01,
					it.name .. " on the sidewalk"
				)
			end
			-- restock sign: nothing in front of it (between it and the north road) within its width / height
			local front = it.min.X < signMax.X and it.max.X > signMin.X and it.max.Z < signMin.Z and it.min.Z > -60
			local tall = it.min.Y < signMax.Y and it.max.Y > signMin.Y
			t.ok(not (front and tall), it.name .. " hides the restock sign")
		end
	end)

	t.test("turntable rims: chase brightens, rarity tints, empty dims", function()
		H.setMode("client")
		local DC = H.require("src/client/Controllers/DealershipClient")
		H.setMode("server")
		local base = R.Color3.fromRGB(255, 52, 140)
		local gold = R.Color3.fromRGB(255, 200, 40)
		local function lum(c)
			return c.R + c.G + c.B
		end
		local lo, hi = math.huge, -math.huge
		for k = 0, 40 do
			local col = DC._rimColor(base, nil, false, k * 0.05, 1)
			lo, hi = math.min(lo, lum(col)), math.max(hi, lum(col))
		end
		t.ok(hi - lo > 0.2, "chase pulses")
		t.ok(lo >= lum(base) - 1e-6, "never darker than the brand color")
		local tinted = DC._rimColor(base, gold, false, 0, 1)
		t.ok(math.abs(tinted.G - gold.G) < 0.3 and tinted.G > base.G, "rarity tint")
		t.ok(lum(DC._rimColor(base, gold, true, 0, 1)) < lum(gold) * 0.5, "empty pad dims")
		-- neighbors are out of phase (a chase, not a blink)
		local a, b = DC._rimColor(base, nil, false, 0.3, 1), DC._rimColor(base, nil, false, 0.3, 3)
		t.ok(math.abs(lum(a) - lum(b)) > 1e-3, "phase offset per pad")
	end)

	t.test("MapDresser.dressAll dresses the garage + showroom slots (fake templates)", function()
		local okReq, MapDresser = pcall(H.require, "src/server/Systems/MapDresser")
		if not okReq or typeof(MapDresser) ~= "table" or not MapDresser._setSource or not MapDresser.dressAll then
			return -- MapDresser not available in this tree: nothing to check
		end
		local templates = {}
		local function template(cat, key)
			local def = Assets[cat] and Assets[cat][key]
			if not def then
				return nil
			end
			local id = cat .. "/" .. key
			if not templates[id] then
				local tm = R.Instance.new("Model")
				tm.Name = key
				local root = R.Instance.new("Part")
				root.Name = "AssetRoot"
				root.Size = Vector3.one
				root.CFrame = R.CFrame.new()
				root.Parent = tm
				local body = R.Instance.new("Part")
				body.Name = "Body"
				body.Size = Vector3.new(def.size, def.size, def.size)
				body.CFrame = R.CFrame.new(0, def.size / 2, 0)
				body.Parent = tm
				tm.PrimaryPart = root
				templates[id] = tm
			end
			return templates[id]
		end
		MapDresser._setSource({
			get = template,
			clone = function(cat, key)
				local tm = template(cat, key)
				return tm and tm:Clone()
			end,
		})
		local garage = PlotService.buildGarageModel(5) -- fresh: dressing replaces the slots
		local ok, err = pcall(function()
			for _, root in { garage.Dressing, select(2, dealerDressing()) } do
				local want = {}
				for _, slot in slotsOf(root, "AssetSlot") do
					want[slot.Name] = { pivot = slot.WorldPivot, role = slot:GetAttribute("Role") }
				end
				local n = MapDresser.dressAll(root, 0)
				local expected = 0
				for _ in want do
					expected += 1
				end
				t.eq(n, expected, root.Name .. ": every slot dressed")
				t.eq(#slotsOf(root, "AssetSlot"), 0, root.Name .. ": no placeholder left")
				for name, w in want do
					local clone = root:FindFirstChild(name)
					t.ok(clone and clone:GetAttribute("Dressed") == true, name .. " clone in place")
					t.ok((clone:GetPivot().Position - w.pivot.Position).Magnitude < 1e-3, name .. " stands on its slot")
					t.ok(clone:GetPivot().LookVector:Dot(w.pivot.LookVector) > 0.999, name .. " faces like its slot")
				end
			end
			-- loot is PlotService's: MapDresser leaves it alone
			t.ok(#slotsOf(garage.Loot, "LootSlot") >= 1, "loot slots untouched")
		end)
		MapDresser._setSource(nil)
		if not ok then
			error(err, 0)
		end
	end)
end
