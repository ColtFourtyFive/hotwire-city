--!nocheck
-- Hero shell plumbing around CarBuilder.applyShell (docs/ART_PASS.md AP1): AssetLibrary load priority, the server's
-- late-arrival re-skin of cars already in Workspace, and AssetClient's re-skin of client-built (ClientCar) models.
-- Templates come from the real AssetLibrary._normalize run on a fake imported mesh, installed in the harness
-- ReplicatedStorage shim (Harness.replicated) and always removed afterwards.
return function(t)
	local H = t.H
	local Instance = H.roblox.Instance
	local Vector3 = H.roblox.Vector3
	local CFrame = H.roblox.CFrame

	H.setMode("server")
	local AssetLibrary = H.require("src/server/Systems/AssetLibrary")
	local Assets = H.require("src/shared/Config/Assets")
	local CarBuilder = H.require("src/shared/Vehicle/CarBuilder")
	local Cars = H.require("src/shared/Config/Cars")

	-- What InsertService:LoadAsset hands back for an uploaded GLB: a container Model holding the textured MeshPart,
	-- long axis along +X (the manifests' yaw -90 turns it to face -Z), floating somewhere off the origin.
	local function rawImport(length, width, height)
		local raw = Instance.new("Model")
		raw.Name = "Imported"
		local mesh = Instance.new("MeshPart")
		mesh.Name = "Mesh"
		mesh.Size = Vector3.new(length, height, width)
		mesh.CFrame = CFrame.new(40, 12, -7)
		mesh.TextureID = "rbxassetid://777"
		mesh.Parent = raw
		local junk = Instance.new("Script")
		junk.Parent = mesh
		return raw
	end

	local function template(key)
		local def = Assets.Hero[key]
		local tpl = AssetLibrary._normalize(rawImport(2.0, 1.0, 0.8), key, def)
		assert(tpl, "normalize failed for " .. key)
		return tpl
	end

	local function withTemplates(templates, fn)
		local lib = Instance.new("Folder")
		lib.Name = "AssetLibrary"
		local hero = Instance.new("Folder")
		hero.Name = "Hero"
		hero.Parent = lib
		for _, tpl in templates do
			tpl.Parent = hero
		end
		H.replicated.AssetLibrary = lib
		local ok, err = pcall(fn, lib)
		H.replicated.AssetLibrary = nil
		lib:Destroy()
		if not ok then
			error(err, 0)
		end
	end

	-- Workspace.Vehicles / Dealership / Plots.Plot3.Display with a few server-built cars (removed afterwards).
	local function withWorld(fn)
		local made = {}
		local function folder(name, parent)
			local f = Instance.new("Folder")
			f.Name = name
			f.Parent = parent
			return f
		end
		local vehicles = folder("Vehicles", H.workspace)
		local dealership = folder("Dealership", H.workspace)
		local plots = folder("Plots", H.workspace)
		local plot = Instance.new("Model")
		plot.Name = "Plot3"
		plot.Parent = plots
		local display = folder("Display", plot)
		table.insert(made, vehicles)
		table.insert(made, dealership)
		table.insert(made, plots)
		local function car(id, parent, x, opts)
			local m = if id == "police"
				then CarBuilder.buildDef(Cars.Police, "None", opts)
				else CarBuilder.build(id, "None", opts)
			m:PivotTo(CFrame.new(x, m:GetAttribute("RideHeight"), 30) * CFrame.Angles(0, math.rad(x), 0))
			m.Parent = parent
			return m
		end
		local world = {
			street = car("grandma_sedan", vehicles, 0),
			other = car("hot_hatch", vehicles, 20),
			police = car("police", vehicles, 40),
			dealer = car("grandma_sedan", dealership, 60, { forDisplay = true }),
			slot = car("grandma_sedan", display, 80, { forDisplay = true }),
		}
		local ok, err = pcall(fn, world)
		for _, f in made do
			f:Destroy()
		end
		if not ok then
			error(err, 0)
		end
	end

	t.test("load queue: early heroes, then Buildings, then wanted Props, then the remaining heroes", function()
		local queue = AssetLibrary.loadQueue()
		local early = function(key)
			local def = Cars.get(key)
			return key == Cars.Police.id or (def ~= nil and AssetLibrary.EARLY_HERO_TIERS[def.rarity] == true)
		end
		local want = { Hero = 0, Props = 0, Buildings = 0 }
		for _, cat in { "Hero", "Props", "Buildings" } do
			for key, def in Assets[cat] do
				if AssetLibrary.wanted(cat, key, def) then
					want[cat] += 1
				end
			end
		end
		t.eq(#queue, want.Hero + want.Props + want.Buildings, "every wanted entry queued once")
		local seen = {}
		for _, item in queue do
			local id = item.cat .. "/" .. item.key
			t.ok(not seen[id], "queued once: " .. id)
			seen[id] = true
			t.ok(AssetLibrary.wanted(item.cat, item.key, item.def), "only wanted entries: " .. id)
		end
		t.eq(queue[1].cat, "Hero", "Hero first")
		t.eq(queue[1].key, "police_unit", "police cruiser loads first")
		t.eq(queue[2].key, Cars.List[1].id, "then the first Common car")
		-- phases: early heroes -> Buildings -> Props -> late heroes
		local function phase(item)
			if item.cat == "Hero" then
				return if early(item.key) then 1 else 4
			end
			return if item.cat == "Buildings" then 2 else 3
		end
		local counts = { 0, 0, 0, 0 }
		for i, item in queue do
			counts[phase(item)] += 1
			if i > 1 then
				t.ok(phase(queue[i - 1]) <= phase(item), "phase order at " .. item.key)
				if phase(queue[i - 1]) == phase(item) and item.cat == "Hero" then
					t.ok(
						AssetLibrary.heroPriority(queue[i - 1].key) <= AssetLibrary.heroPriority(item.key),
						"hero priority order " .. item.key
					)
				end
			end
		end
		t.ok(counts[1] >= 6 and counts[2] == want.Buildings and counts[4] > 0, "all four phases present")
		-- every Building is in by entry ~1/3 of the queue (was 87-108 of 108)
		local lastBuilding = 0
		for i, item in queue do
			if item.cat == "Buildings" then
				lastBuilding = i
			end
		end
		t.ok(lastBuilding <= counts[1] + counts[2], "buildings right after the early heroes")
	end)

	t.test("loaded Props / Buildings are the ones something places; SKIP is exactly the unused ones", function()
		local fs = require("@lune/fs")
		-- every source file that could place a kit key (Config/Assets itself and AssetLibrary don't count)
		local sources = {}
		local function scan(dir)
			for _, e in fs.readDir(dir) do
				local path = dir .. "/" .. e
				if fs.isDir(path) then
					scan(path)
				elseif
					e:match("%.luau$")
					and path ~= "src/shared/Config/Assets.luau"
					and path ~= "src/server/Systems/AssetLibrary.luau"
				then
					table.insert(sources, fs.readFile(path))
				end
			end
		end
		scan("src")
		local blob = table.concat(sources, "\n")
		local function used(key)
			return blob:find('"' .. key .. '"', 1, true) ~= nil
		end
		for _, cat in { "Props", "Buildings" } do
			for key, def in Assets[cat] do
				if AssetLibrary.wanted(cat, key, def) then
					t.ok(
						used(key),
						cat .. "/" .. key .. " is loaded but nothing places it: add it to AssetLibrary.SKIP"
					)
				else
					t.ok(not used(key), cat .. "/" .. key .. " is used now: take it out of AssetLibrary.SKIP")
				end
			end
		end
		for cat, keys in AssetLibrary.SKIP do
			for key in keys do
				t.ok(Assets[cat] and Assets[cat][key], "SKIP names a real entry: " .. cat .. "/" .. key)
			end
		end
	end)

	t.test("Creator Store models: allowlist sanitize + part cap; owned models keep decals", function()
		local function storeRaw(parts)
			local raw = Instance.new("Model")
			for i = 1, parts do
				local p = Instance.new("Part")
				p.Size = Vector3.new(1, 1, 1)
				p.CFrame = CFrame.new(i, 0.5, 0)
				p.Parent = raw
				if i == 1 then
					for _, cls in { "Decal", "SurfaceGui", "PointLight", "ParticleEmitter", "SpecialMesh", "Texture" } do
						local c = Instance.new(cls)
						c.Name = cls
						c.Parent = p
					end
				end
			end
			return raw
		end
		local def = { ids = { 1 }, source = "store", fit = "maxDim", size = 4 }
		local tpl = AssetLibrary._normalize(storeRaw(3), "store_test", def)
		t.ok(tpl ~= nil, "a small store model normalizes")
		local kept = {}
		for _, d in tpl:GetDescendants() do
			kept[d.ClassName] = true
		end
		t.ok(kept.SpecialMesh, "meshes stay")
		for _, cls in { "Decal", "SurfaceGui", "PointLight", "ParticleEmitter", "Texture" } do
			t.ok(not kept[cls], "store " .. cls .. " stripped")
		end
		t.eq(AssetLibrary._normalize(storeRaw(AssetLibrary.MAX_STORE_PARTS + 1), "store_big", def), nil, "part cap")
		local owned = AssetLibrary._normalize(
			storeRaw(3),
			"owned_test",
			{ ids = { 1 }, source = "owned", fit = "maxDim", size = 4 }
		)
		t.ok(owned:FindFirstChild("Decal", true) ~= nil, "owned models keep their decals")
		t.ok(owned:FindFirstChild("PointLight", true) ~= nil, "owned models: blocklist only")
	end)

	t.test("normalized template + applyShell: GLB yaw honored, mesh runs along the car", function()
		local tpl = template("grandma_sedan")
		t.ok(tpl:FindFirstChildWhichIsA("Script", true) == nil, "sanitized")
		withTemplates({ tpl }, function()
			local m = CarBuilder.build("grandma_sedan", "None")
			t.eq(m:GetAttribute("HeroMesh"), true, "dressed from a normalized template")
			local mesh = m:FindFirstChild(CarBuilder.SHELL_NAME):FindFirstChild("Mesh")
			local rel = m.PrimaryPart.CFrame:ToObjectSpace(mesh.CFrame)
			t.ok(math.abs(rel.RightVector.Z) > 0.99, "native length axis (X) now along the car (Z)")
			t.near(mesh.Size.X, m:GetAttribute("Length"), 1e-3, "mesh length = Length")
			local bottom = rel.Position.Y - mesh.Size.Y / 2
			t.near(bottom, -m:GetAttribute("RideHeight"), 1e-3, "mesh bottom on the ground")
		end)
	end)

	t.test("late arrival: reskin dresses that CarId in Vehicles, Dealership and plot Displays only", function()
		withWorld(function(world)
			withTemplates({ template("grandma_sedan") }, function()
				t.eq(AssetLibrary.reskin("grandma_sedan"), 3, "street + dealer + garage display")
				for _, name in { "street", "dealer", "slot" } do
					local m = world[name]
					t.eq(m:GetAttribute("HeroMesh"), true, name .. " dressed")
					local ground = m.PrimaryPart.CFrame * CFrame.new(0, -m:GetAttribute("RideHeight"), 0)
					local mesh = m:FindFirstChild(CarBuilder.SHELL_NAME):FindFirstChild("Mesh")
					local rel = ground:ToObjectSpace(mesh.CFrame)
					t.near(rel.Position.Y - mesh.Size.Y / 2, 0, 1e-3, name .. " shell on its ground")
				end
				-- display shells (no DriverSeat) cast no shadow; drivable cars keep theirs (ART-PERF-03)
				for _, name in { "street", "dealer", "slot" } do
					local mesh = world[name]:FindFirstChild(CarBuilder.SHELL_NAME):FindFirstChild("Mesh")
					t.eq(mesh.CastShadow, name == "street", name .. " shell shadow")
				end
				t.ok(world.other:GetAttribute("HeroMesh") == nil, "other car ids untouched")
				t.ok(world.police:GetAttribute("HeroMesh") == nil, "police untouched")
				t.eq(AssetLibrary.reskin("grandma_sedan"), 0, "already dressed cars are skipped")
			end)
		end)
	end)

	t.test("late arrival via AssetLibrary.Ready (police_unit re-skins the police cruiser)", function()
		withWorld(function(world)
			withTemplates({ template("police_unit") }, function(lib)
				AssetLibrary.init() -- adopts the (fake) existing ReplicatedStorage.AssetLibrary, hooks Ready
				AssetLibrary.Ready:Fire("Props", "police_unit", lib.Hero.police_unit)
				t.ok(world.police:GetAttribute("HeroMesh") == nil, "non-Hero categories ignored")
				AssetLibrary.Ready:Fire("Hero", "police_unit", lib.Hero.police_unit)
				t.eq(world.police:GetAttribute("HeroMesh"), true, "police dressed on Ready")
				t.eq(world.police:FindFirstChild("SirenRed").Transparency, 0, "siren still visible")
				t.ok(world.street:GetAttribute("HeroMesh") == nil, "sedan waits for its own template")
			end)
		end)
	end)

	t.test("AssetClient re-skins client-built (ClientCar) models only", function()
		local serverCar = CarBuilder.build("grandma_sedan", "None") -- built in server mode: untagged
		H.setMode("client")
		local ok, err = pcall(function()
			local ClientBuilder = H.require("src/shared/Vehicle/CarBuilder")
			local AssetClient = H.require("src/client/Controllers/AssetClient")
			local gui = Instance.new("Folder") -- stands in for the Index ViewportFrame (anywhere in the DataModel)
			gui.Name = "IndexViews"
			gui.Parent = H.workspace
			local okInner, errInner = pcall(function()
				local view = Instance.new("ViewportFrame")
				view.Parent = gui
				local card = ClientBuilder.build("grandma_sedan", "None", { forDisplay = true })
				card.Parent = view
				local other = ClientBuilder.build("hot_hatch", "None", { forDisplay = true })
				other.Parent = view
				serverCar.Parent = gui
				t.ok(not serverCar:HasTag(ClientBuilder.CLIENT_TAG), "server-built car untagged")
				t.ok(card:HasTag(ClientBuilder.CLIENT_TAG), "Index card tagged")
				local dressed, bare = AssetClient.reskin("grandma_sedan")
				t.eq(dressed + bare, 1, "no template yet: one candidate")
				t.eq(dressed, 0, "nothing to dress without a template")
				withTemplates({ template("grandma_sedan") }, function()
					local d2, b2 = AssetClient.reskin("grandma_sedan")
					t.eq(d2, 1, "card dressed")
					t.eq(b2, 0, "nothing left bare")
					t.eq(card:GetAttribute("HeroMesh"), true, "HeroMesh on the card")
					t.ok(other:GetAttribute("HeroMesh") == nil, "other id untouched")
					t.ok(serverCar:GetAttribute("HeroMesh") == nil, "server-built car left to the server")
					t.eq(select(1, AssetClient.reskin("grandma_sedan")), 0, "idempotent")
					local copy = card:Clone() -- MenuController's detail view clones the card model
					t.ok(copy:FindFirstChild(ClientBuilder.SHELL_NAME), "a clone keeps the shell")
				end)
			end)
			gui:Destroy()
			if not okInner then
				error(errInner, 0)
			end
		end)
		H.setMode("server")
		if not ok then
			error(err, 0)
		end
	end)
end
