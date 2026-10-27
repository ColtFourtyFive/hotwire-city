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

	t.test("load queue: every Hero shell first (police, then Common up), then Props and Buildings", function()
		local queue = AssetLibrary.loadQueue()
		local heroes, props, buildings = 0, 0, 0
		for _ in Assets.Hero do
			heroes += 1
		end
		for _ in Assets.Props do
			props += 1
		end
		for _ in Assets.Buildings do
			buildings += 1
		end
		t.eq(#queue, heroes + props + buildings, "every entry queued once")
		t.eq(queue[1].cat, "Hero", "Hero first")
		t.eq(queue[1].key, "police_unit", "police cruiser loads first")
		for i = 1, heroes do
			t.eq(queue[i].cat, "Hero", "Hero block at " .. i)
		end
		for i = heroes + 1, #queue do
			t.ok(queue[i].cat ~= "Hero", "no Hero after the Hero block")
		end
		-- catalog order (Common first) within the Hero block
		for i = 3, heroes do
			t.ok(
				AssetLibrary.heroPriority(queue[i - 1].key) <= AssetLibrary.heroPriority(queue[i].key),
				"priority order " .. queue[i].key
			)
		end
		t.eq(queue[2].key, Cars.List[1].id, "then the first Common car")
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
