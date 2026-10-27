--!nocheck
-- MapDresser on the v2 world: MapBuilder v2 builds procedural props itself (no AssetSlots on the map), its billboards
-- get the ad decals, and the dresser still swaps the AssetSlots other systems place (DealershipService's showroom,
-- garages) for kit meshes: placement, scale, yaw, colliders, shadows, NoDress, late templates, boot order.
return function(t)
	local H = t.H
	H.setMode("server")
	local MapBuilder = H.require("src/server/Systems/MapBuilder")
	local MapDresser = H.require("src/server/Systems/MapDresser")
	local Assets = H.require("src/shared/Config/Assets")
	local Vector3, CFrame = H.roblox.Vector3, H.roblox.CFrame

	local folder = MapBuilder.build(H.workspace, { terrain = false })

	-- fake templates (the harness has no InsertService) -------------------------------------------------------------
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
	local missingKey = "pine_tree" -- pretend this one failed to load
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

	-- AssetSlots like the ones systems place: a Model tagged AssetSlot (Category, Role, Fit, optional Yaw) with a
	-- solid placeholder part, its pivot = the dressed asset's ground CFrame
	local ROLES = {
		{ "Props", "palm_tree", 34 },
		{ "Props", "tree", 24 },
		{ "Props", "bench", 8 },
		{ "Props", "hotdog_stand", 10 },
		{ "Buildings", "car_showroom", 100 },
	}
	local function fixture(parent, n)
		local list = {}
		for i = 1, n do
			local r = ROLES[(i - 1) % #ROLES + 1]
			local m = H.roblox.Instance.new("Model")
			m.Name = "Slot" .. i
			m:AddTag(MapDresser.TAG_SLOT)
			m:SetAttribute("Category", r[1])
			m:SetAttribute("Role", r[2])
			m:SetAttribute("Fit", r[3])
			if i % 3 == 0 then
				m:SetAttribute("Yaw", 90)
			end
			local ground = CFrame.lookAt(Vector3.new(i * 37, 12.6, -i * 53), Vector3.new(i * 37, 12.6, -i * 53 - 1))
			local ph = H.roblox.Instance.new("Part")
			ph.Name = "Placeholder"
			ph.Size = Vector3.new(4, r[3] * 0.5, 4)
			ph.CFrame = ground * CFrame.new(0, r[3] * 0.25, 0)
			ph.Anchored = true
			ph.CanCollide = r[1] == "Props"
			ph.Parent = m
			m.WorldPivot = ground
			m.Parent = parent
			table.insert(list, m)
		end
		return list
	end

	t.test("the v2 map places no AssetSlots (procedural props); billboards are tagged with fallback text", function()
		local slots = 0
		local boards = 0
		for _, d in folder:GetDescendants() do
			if d:HasTag(MapDresser.TAG_SLOT) then
				slots += 1
			end
			if d:IsA("BasePart") and d:HasTag("Billboard") then
				boards += 1
				t.ok(type(d:GetAttribute("AdText")) == "string", "fallback ad text")
			end
		end
		t.eq(slots, 0, "no slots on the v2 map")
		t.ok(boards >= 10, "billboards: " .. boards)
	end)

	t.test("billboards: ad decals from Assets.billboardAds(), deterministic, idempotent", function()
		local boards = {}
		for _, d in folder:GetDescendants() do
			if d:IsA("BasePart") and d:HasTag("Billboard") then
				table.insert(boards, d)
			end
		end
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
			t.eq(MapDresser.adFor(b, Assets.billboardAds()), front.Texture)
		end
		local variety = 0
		for _ in used do
			variety += 1
		end
		t.ok(variety >= 4, "ad variety " .. variety)
		t.eq(MapDresser.applyBillboards(folder), 0, "idempotent")
	end)

	t.test("MapDresser: resolve picks deterministic variants", function()
		local holder = H.roblox.Instance.new("Folder")
		holder.Parent = H.workspace
		local seen = {}
		for _, m in fixture(holder, 60) do
			if m:GetAttribute("Role") == "palm_tree" then
				local _, k1 = MapDresser.resolve(m)
				local _, k2 = MapDresser.resolve(m)
				t.eq(k1, k2, "stable variant")
				seen[k1] = true
			end
		end
		t.ok(seen.palm_tree_a and seen.palm_tree_b, "both palm variants used")
		holder:Destroy()
	end)

	t.test("MapDresser: placement, scale, yaw, colliders, shadows; missing art keeps the placeholder", function()
		MapDresser._setSource(fakeSource)
		local holder = H.roblox.Instance.new("Folder")
		holder.Parent = H.workspace
		local list = fixture(holder, 40)
		local checked = { Buildings = 0, Props = 0 }
		local kept = 0
		for _, m in list do
			local cat, key = MapDresser.resolve(m)
			if key == missingKey then
				t.eq(MapDresser.dressSlot(m), nil, "missing template")
				t.ok(m.Parent == holder, "placeholder kept")
				kept += 1
				continue
			end
			local yaw = m:GetAttribute("Yaw") or 0
			local want = m:GetPivot() * CFrame.Angles(0, math.rad(yaw), 0)
			local factor = m:GetAttribute("Fit") / Assets[cat][key].size
			local solid = {}
			for _, d in m:GetDescendants() do
				if d:IsA("BasePart") and d.CanCollide then
					table.insert(solid, { cf = d.CFrame, size = d.Size })
				end
			end
			local clone = MapDresser.dressSlot(m)
			t.ok(clone and clone.Parent == holder, "clone placed in the slot's folder")
			t.ok(m.Parent == nil, "placeholder gone")
			t.ok(clone:FindFirstChild("AssetRoot") == nil, "template root dropped")
			local pivot = clone:GetPivot()
			t.ok((pivot.Position - want.Position).Magnitude < 1e-3, "on the slot's ground point")
			t.ok(pivot.LookVector:Dot(want.LookVector) > 0.999, "front faces the slot's front")
			local mesh = clone:FindFirstChild("Mesh")
			local size = Assets[cat][key].size
			t.near(mesh.Size.Y, size * factor, size * 0.011, "scaled to Fit")
			local holderC = clone:FindFirstChild(MapDresser.COLLIDERS)
			if cat == "Buildings" then
				t.ok(mesh.CanCollide and mesh.CanQuery and mesh.CastShadow, "buildings collide + cast shadows")
			else
				t.ok(not mesh.CanCollide and not mesh.CanQuery, "prop meshes never collide")
				local kept2 = if holderC then holderC:GetChildren() else {}
				t.eq(#kept2, #solid, "placeholder colliders kept: " .. key)
				for _, c in kept2 do
					t.ok(c.CanCollide and c.Anchored and c.Transparency == 1, "collider solid + invisible")
				end
			end
			t.eq(MapDresser.dressSlot(m), nil, "a dressed slot is not dressed twice")
			checked[cat] += 1
		end
		t.ok(checked.Buildings > 0 and checked.Props > 10 and kept > 0, "checked")
		MapDresser._setSource(nil)
		holder:Destroy()
	end)

	t.test("MapDresser: NoDress slots and pre-dressed boards are left alone", function()
		MapDresser._setSource(fakeSource)
		local holder = H.roblox.Instance.new("Folder")
		holder.Parent = H.workspace
		local own = fixture(holder, 1)[1]
		own:SetAttribute("NoDress", true)
		t.eq(MapDresser.dressSlot(own), nil, "NoDress respected")
		t.ok(own.Parent ~= nil, "placeholder kept")
		local map = MapBuilder.build(H.workspace, { terrain = false })
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
		holder:Destroy()
		folder = map
	end)

	t.test("MapDresser.start: a template landing mid-pass still dresses its slots; Map marked Dressed", function()
		local AssetLibrary = H.require("src/server/Systems/AssetLibrary")
		local lateKey = "car_showroom"
		local available = false
		local fired = false
		local source = {}
		source.get = function(cat, key)
			if key == "workbench" and not fired and not available then
				available = true
				fired = true
				AssetLibrary.Ready:Fire("Buildings", lateKey, fakeSource.get("Buildings", lateKey))
			end
			if key == lateKey and not available then
				return nil
			end
			return fakeSource.get(cat, key)
		end
		source.clone = function(cat, key, cf, parent)
			if not source.get(cat, key) then
				return nil
			end
			return fakeSource.clone(cat, key, cf, parent)
		end
		MapDresser._setSource(source)
		local map = H.workspace:FindFirstChild("Map")
		local inMap = H.roblox.Instance.new("Folder")
		inMap.Name = "SystemSlots"
		inMap.Parent = map
		fixture(inMap, 10)
		-- a slot of another system outside Workspace.Map, nested deep so the pass reaches it last
		local extra = H.roblox.Instance.new("Folder")
		extra.Name = "LateGapExtra"
		extra.Parent = H.workspace
		local holder = extra
		for i = 1, 8 do
			local f = H.roblox.Instance.new("Folder")
			f.Name = "Level" .. i
			f.Parent = holder
			holder = f
		end
		local slot = H.roblox.Instance.new("Model")
		slot.Name = "Workbench"
		slot:AddTag(MapDresser.TAG_SLOT)
		slot:SetAttribute("Category", "Props")
		slot:SetAttribute("Role", "workbench")
		slot:SetAttribute("Fit", 8)
		slot.WorldPivot = CFrame.new(5000, 0, 5000)
		slot.Parent = holder
		local wait0 = MapDresser.WAIT_TIMEOUT
		MapDresser.WAIT_TIMEOUT = 0
		local ok, err = pcall(MapDresser.start)
		MapDresser.WAIT_TIMEOUT = wait0
		t.ok(ok, tostring(err))
		local lunetask = require("@lune/task")
		lunetask.wait()
		lunetask.wait()
		t.ok(fired, "the template landed during the pass")
		local left = 0
		for _, d in map:GetDescendants() do
			if d:IsA("Model") and d:HasTag(MapDresser.TAG_SLOT) then
				local _, key = MapDresser.resolve(d)
				if key == lateKey then
					left += 1
				end
			end
		end
		t.eq(left, 0, lateKey .. " placeholders left after the late template")
		t.ok(MapDresser.isDone(), "done")
		t.eq(map:GetAttribute("Dressed"), true, "Workspace.Map marked Dressed for the loading screen")
		MapDresser._setSource(nil)
		extra:Destroy()
		inMap:Destroy()
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
