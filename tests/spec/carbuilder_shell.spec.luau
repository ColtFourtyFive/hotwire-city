--!nocheck
-- Shared/Vehicle/CarBuilder hero shells (docs/ART_PASS.md AP1). The harness has no AssetLibrary, so these tests install
-- fake normalized Hero templates in the ReplicatedStorage shim (Harness.replicated) to drive applyShell: scaling to
-- Length, width cap, ground contact, welds, hidden procedural parts, police sirens, mutations + restore, idempotency.
return function(t)
	local H = t.H
	local Instance = H.roblox.Instance
	local Vector3 = H.roblox.Vector3
	local CFrame = H.roblox.CFrame
	local Color3 = H.roblox.Color3
	local Enum = H.roblox.Enum
	local CarBuilder = H.require("src/shared/Vehicle/CarBuilder")
	local Cars = H.require("src/shared/Config/Cars")
	local Rarity = H.require("src/shared/Config/Rarity")
	-- legacy path: these cars without their v2 Model (see tests/legacy_shells.luau)
	local restoreVehicles = require("../legacy_shells").clear(Cars)

	local TEXTURE = "rbxassetid://424242"

	-- A template exactly as AssetLibrary._normalize leaves it: Model <key>, PrimaryPart AssetRoot (1x1x1, invisible,
	-- anchored) at the origin = bottom-center, front -Z. The mesh is a textured MeshPart with a SurfaceAppearance,
	-- yawed 90 degrees like an imported GLB whose length ran along X (`size` is its post-yaw x/y/z extent), plus an
	-- untextured spoiler Part so multi-part bounds are exercised.
	local function makeTemplate(key, size)
		local m = Instance.new("Model")
		m.Name = key
		local root = Instance.new("Part")
		root.Name = "AssetRoot"
		root.Size = Vector3.new(1, 1, 1)
		root.Transparency = 1
		root.Anchored = true
		root.CFrame = CFrame.new()
		root.Parent = m
		m.PrimaryPart = root
		local body = Instance.new("MeshPart")
		body.Name = "Body"
		body.Size = Vector3.new(size.Z, size.Y * 0.9, size.X) -- native: length along X
		body.CFrame = CFrame.new(0, size.Y * 0.45, 0) * CFrame.Angles(0, math.rad(-90), 0)
		body.TextureID = TEXTURE
		body.Color = Color3.fromRGB(200, 200, 200)
		body.Material = Enum.Material.Plastic
		body.Anchored = true
		body.CanCollide = false
		body.Parent = m
		local sa = Instance.new("SurfaceAppearance")
		sa.Name = "Look"
		sa.Parent = body
		local spoiler = Instance.new("Part")
		spoiler.Name = "Spoiler"
		spoiler.Size = Vector3.new(size.X * 0.8, size.Y * 0.1, size.Z * 0.1)
		spoiler.CFrame = CFrame.new(0, size.Y * 0.95, size.Z * 0.45)
		spoiler.Anchored = true
		spoiler.Parent = m
		m:SetAttribute("AssetKey", key)
		return m
	end

	-- Installs ReplicatedStorage.AssetLibrary.Hero.<key> templates while fn runs (always removed afterwards).
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
		local ok, err = pcall(fn, hero)
		H.replicated.AssetLibrary = nil
		lib:Destroy()
		if not ok then
			error(err, 0)
		end
	end

	local function shellOf(model)
		return model:FindFirstChild(CarBuilder.SHELL_NAME)
	end

	local function shellPartsOf(model)
		local out = {}
		local shell = shellOf(model)
		if shell then
			for _, d in shell:GetDescendants() do
				if d:IsA("BasePart") then
					table.insert(out, d)
				end
			end
		end
		return out
	end

	-- AABB of parts in the frame `ref`
	local function bounds(ref, parts)
		local minV, maxV
		for _, p in parts do
			local half = p.Size / 2
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local w = ref:PointToObjectSpace(p.CFrame * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
						minV = if minV then minV:Min(w) else w
						maxV = if maxV then maxV:Max(w) else w
					end
				end
			end
		end
		return minV, maxV
	end

	local function weldedToChassis(part, chassis)
		for _, c in part:GetChildren() do
			if c:IsA("WeldConstraint") and c.Part0 == chassis and c.Part1 == part then
				return true
			end
		end
		return false
	end

	local function meshOf(model)
		for _, p in shellPartsOf(model) do
			if p:IsA("MeshPart") then
				return p
			end
		end
		return nil
	end

	local SEDAN = { X = 7.5, Y = 5.9, Z = 14 } -- grandma_sedan GLB proportions (W/L 0.54, H/L 0.42)

	t.test("no template: applyShell is a no-op and the procedural car is untouched", function()
		local m = CarBuilder.build("grandma_sedan", "None", { forDisplay = true })
		t.ok(shellOf(m) == nil, "no shell without AssetLibrary")
		t.ok(m:GetAttribute("HeroMesh") == nil, "no HeroMesh")
		t.eq(CarBuilder.applyShell(m), false, "applyShell reports no shell")
		local visible = 0
		for _, c in m:GetChildren() do
			if c:IsA("BasePart") and c.Transparency < 1 then
				visible += 1
			end
			t.ok(c:GetAttribute("ShellHidden") == nil, c.Name .. " not marked hidden")
		end
		t.ok(visible > 10, "procedural parts visible")
		local bc = m:GetAttribute("BodyCenter")
		t.ok(typeof(bc) == "Vector3" and bc.Y == 0, "BodyCenter attribute")
	end)

	t.test("build() dresses the car: scaled to Length, on the ground, welded, procedural parts hidden", function()
		local tpl = makeTemplate("grandma_sedan", SEDAN)
		withTemplates({ tpl }, function()
			for _, display in { true, false } do
				local m = CarBuilder.build("grandma_sedan", "None", { forDisplay = display })
				local tag = if display then " (display)" else " (drivable)"
				local shell = shellOf(m)
				t.ok(shell and shell:IsA("Model"), "HeroShell model" .. tag)
				t.eq(m:GetAttribute("HeroMesh"), true, "HeroMesh attribute" .. tag)
				t.ok(shell:FindFirstChild("AssetRoot", true) == nil, "AssetRoot removed" .. tag)
				t.eq(shell:GetAttribute("ShellKey"), "grandma_sedan", "ShellKey" .. tag)
				local chassis = m.PrimaryPart
				t.eq(chassis.Name, "Chassis", "PrimaryPart still the chassis" .. tag)
				local parts = shellPartsOf(m)
				t.eq(#parts, 2, "both template parts cloned" .. tag)
				for _, p in parts do
					t.ok(not p.Anchored and p.Massless, p.Name .. " unanchored + massless" .. tag)
					t.ok(not p.CanCollide and not p.CanQuery and not p.CanTouch, p.Name .. " no collision/query/touch")
					t.ok(weldedToChassis(p, chassis), p.Name .. " WeldConstraint to Chassis" .. tag)
				end
				-- measured in the ground frame under the chassis (built pose: y = 0 plane)
				local ride = m:GetAttribute("RideHeight")
				local ground = chassis.CFrame * CFrame.new(0, -ride, 0)
				local minV, maxV = bounds(ground, parts)
				t.near(maxV.Z - minV.Z, m:GetAttribute("Length"), 1e-3, "shell length = Length" .. tag)
				t.near(minV.Y, 0, 1e-3, "shell bottom on the ground" .. tag)
				local bc = m:GetAttribute("BodyCenter")
				t.near((minV.Z + maxV.Z) / 2, bc.Z, 1e-3, "centered on BodyCenter z" .. tag)
				t.near((minV.X + maxV.X) / 2, bc.X, 1e-3, "centered on BodyCenter x" .. tag)
				t.ok(maxV.X - minV.X <= m:GetAttribute("Width") * 1.15 + 1e-3, "width within the cap" .. tag)
				t.near(m:GetAttribute("ShellHeight"), maxV.Y, 1e-3, "ShellHeight = shell roof" .. tag)
				-- uniform scale: the mesh keeps its proportions
				local f = (maxV.Z - minV.Z) / SEDAN.Z
				t.near(maxV.Y - minV.Y, SEDAN.Y * f, 1e-3, "uniform scale (height)" .. tag)
				-- yawed mesh: its long native X axis now runs along the car (chassis Z)
				local mesh = meshOf(m)
				t.ok(math.abs(chassis.CFrame:VectorToObjectSpace(mesh.CFrame.RightVector).Z) > 0.99, "mesh yaw kept")

				-- procedural visuals hidden but kept; physics / lights intact
				for _, c in m:GetChildren() do
					if c:IsA("BasePart") then
						t.eq(c.Transparency, 1, c.Name .. " hidden" .. tag)
					end
				end
				local hidden = 0
				for _, c in m:GetChildren() do
					if c:IsA("BasePart") and typeof(c:GetAttribute("ShellHidden")) == "number" then
						hidden += 1
					end
				end
				t.ok(hidden > 10, "procedural visuals marked ShellHidden" .. tag)
				for _, k in { "FL", "FR", "RL", "RR" } do
					t.ok(m:FindFirstChild("Wheel_" .. k), "wheel kept " .. k)
					t.ok(chassis:FindFirstChild("WheelWeld_" .. k), "wheel weld kept " .. k)
					t.ok(chassis:FindFirstChild("Wheel" .. k), "wheel attachment kept " .. k)
				end
				local head = m:FindFirstChild("Headlight")
				t.ok(head and head:FindFirstChild("Beam") and head:FindFirstChild("Beam"):IsA("SpotLight"), "beam kept")
				t.eq(m:FindFirstChild("DriverSeat") ~= nil, not display, "seat only on drivable cars" .. tag)
				t.eq(chassis.CanCollide, true, "chassis still collides" .. tag)
			end
			-- the template itself is never modified
			t.ok(tpl:FindFirstChild("AssetRoot"), "template keeps AssetRoot")
			t.ok(tpl:FindFirstChild("Body").Anchored, "template parts stay anchored")
			t.near(tpl:FindFirstChild("Body").Size.X, SEDAN.Z, 1e-6, "template size untouched")
		end)
	end)

	t.test("labels (SurfaceGuis) on hidden parts are disabled", function()
		withTemplates({ makeTemplate("yellow_cab", SEDAN) }, function()
			local m = CarBuilder.build("yellow_cab", "None", { forDisplay = true })
			local guis = 0
			for _, d in m:GetDescendants() do
				if d:IsA("SurfaceGui") then
					guis += 1
					t.eq(d.Enabled, false, "label disabled on " .. d.Parent.Name)
					t.eq(d:GetAttribute("ShellHidden"), true, "label marked")
				end
			end
			t.ok(guis > 0, "the cab has labels")
		end)
	end)

	t.test("width cap: a too-wide mesh is scaled down uniformly to Width x 1.15", function()
		local wide = { X = 14, Y = 7, Z = 14 }
		withTemplates({ makeTemplate("grandma_sedan", wide) }, function()
			local m = CarBuilder.build("grandma_sedan", "None", { forDisplay = true })
			local ground = m.PrimaryPart.CFrame * CFrame.new(0, -m:GetAttribute("RideHeight"), 0)
			local minV, maxV = bounds(ground, shellPartsOf(m))
			local w = m:GetAttribute("Width") * 1.15
			t.near(maxV.X - minV.X, w, 1e-3, "width capped")
			t.near(maxV.Z - minV.Z, w, 1e-3, "length shrunk by the same factor")
			t.near(minV.Y, 0, 1e-3, "still on the ground")
		end)
	end)

	t.test("late arrival on a car already placed in the world (moved + turned)", function()
		local m = CarBuilder.build("grandma_sedan", "None")
		local ride = m:GetAttribute("RideHeight")
		local placed = CFrame.new(120, 7, -45) * CFrame.Angles(0, math.rad(37), 0) * CFrame.new(0, ride, 0)
		m:PivotTo(placed)
		t.ok(shellOf(m) == nil, "built bare")
		withTemplates({ makeTemplate("grandma_sedan", SEDAN) }, function()
			t.eq(CarBuilder.applyShell(m), true, "applyShell dresses it")
			local chassis = m.PrimaryPart
			local ground = chassis.CFrame * CFrame.new(0, -ride, 0)
			t.near((ground.Position - Vector3.new(120, 7, -45)).Magnitude, 0, 1e-3, "ground under the placed car")
			local minV, maxV = bounds(ground, shellPartsOf(m))
			t.near(minV.Y, 0, 1e-3, "bottom on the road")
			t.near(maxV.Z - minV.Z, m:GetAttribute("Length"), 1e-3, "length along the car's own Z")
		end)
	end)

	t.test("applyShell is idempotent", function()
		withTemplates({ makeTemplate("hot_hatch", SEDAN) }, function()
			local m = CarBuilder.build("hot_hatch", "Gold", { forDisplay = true })
			local before = #shellPartsOf(m)
			local cf = meshOf(m).CFrame
			t.eq(CarBuilder.applyShell(m), true, "second call reports the shell")
			t.eq(CarBuilder.applyShell(m), true, "third call too")
			local shells = 0
			for _, c in m:GetChildren() do
				if c.Name == CarBuilder.SHELL_NAME then
					shells += 1
				end
			end
			t.eq(shells, 1, "exactly one shell")
			t.eq(#shellPartsOf(m), before, "same parts")
			t.near((meshOf(m).CFrame.Position - cf.Position).Magnitude, 0, 1e-6, "not moved")
			local welds = 0
			for _, c in meshOf(m):GetChildren() do
				if c:IsA("WeldConstraint") then
					welds += 1
				end
			end
			t.eq(welds, 1, "one weld per shell part")
			for _, c in m:GetChildren() do
				if c:IsA("BasePart") and c:GetAttribute("ShellHidden") ~= nil then
					t.ok(c:GetAttribute("ShellHidden") < 1, c.Name .. " keeps its original transparency")
				end
			end
		end)
	end)

	t.test("police unit: police_unit shell, sirens stay visible on top of the roof", function()
		withTemplates({ makeTemplate("police_unit", { X = 7.5, Y = 6.25, Z = 14.85 }) }, function()
			local m = CarBuilder.buildDef(Cars.Police, "None")
			t.eq(m:GetAttribute("HeroMesh"), true, "police dressed")
			t.eq(shellOf(m):GetAttribute("ShellKey"), "police_unit", "police_unit template")
			local chassis = m.PrimaryPart
			local ground = chassis.CFrame * CFrame.new(0, -m:GetAttribute("RideHeight"), 0)
			local roof = m:GetAttribute("ShellHeight")
			local _, shellMax = bounds(ground, shellPartsOf(m))
			t.near(roof, shellMax.Y, 1e-3, "roof height")
			local sirens = 0
			for _, c in m:GetChildren() do
				if c.Name == "SirenRed" or c.Name == "SirenBlue" then
					sirens += 1
					t.eq(c.Transparency, 0, c.Name .. " visible")
					t.ok(c:GetAttribute("ShellHidden") == nil, c.Name .. " not hidden")
					local minV = bounds(ground, { c })
					t.ok(
						minV.Y >= roof and minV.Y <= roof + 0.2,
						("%s sits on the roof (%.2f vs %.2f)"):format(c.Name, minV.Y, roof)
					)
					t.ok(weldedToChassis(c, chassis), c.Name .. " re-welded to the chassis")
					local welds = 0
					for _, w in c:GetChildren() do
						if w:IsA("WeldConstraint") then
							welds += 1
						end
					end
					t.eq(welds, 1, c.Name .. " single weld")
					t.ok(typeof(c:GetAttribute("PreShellOffset")) == "CFrame", c.Name .. " remembers its spot")
				end
			end
			t.eq(sirens, 2, "both siren lights")
			t.eq(m:FindFirstChild("LightbarBase").Transparency, 1, "procedural lightbar base hidden")
		end)
	end)

	t.test("police without its template stays procedural even when other shells exist", function()
		withTemplates({ makeTemplate("grandma_sedan", SEDAN) }, function()
			local m = CarBuilder.buildDef(Cars.Police, "None")
			t.ok(m:GetAttribute("HeroMesh") == nil, "no police shell")
			t.eq(m:FindFirstChild("SirenRed").Transparency, 0, "sirens untouched")
		end)
	end)

	t.test("police-style civilian cars hide their static sirens under the mesh's own lightbar", function()
		withTemplates({ makeTemplate("retired_cruiser", SEDAN) }, function()
			local m = CarBuilder.build("retired_cruiser", "None")
			t.eq(m:GetAttribute("HeroMesh"), true, "dressed")
			for _, name in { "SirenRed", "SirenBlue" } do
				local siren = m:FindFirstChild(name)
				t.ok(siren, name .. " kept as a part")
				t.eq(siren.Transparency, 1, name .. " hidden")
				t.ok(siren:GetAttribute("PreShellOffset") == nil, name .. " not moved")
			end
		end)
	end)

	t.test("open-top shells lower the DriverSeat into the mesh seat (re-welded, restored by removeShell)", function()
		-- the toilet left the v2 catalog (CarAliases): an ad-hoc def keeps the open-top seat path covered
		local toilet = table.clone(Cars.ById.rustbucket)
		toilet.id = "toilet_turbo"
		toilet.style = "toilet"
		toilet.vehicle = nil
		withTemplates({ makeTemplate("toilet_turbo", { X = 8.8, Y = 6.4, Z = 7.3 }) }, function()
			local bare = CarBuilder.buildDef(toilet, "None")
			local m = CarBuilder.buildDef(toilet, "None")
			local chassis = m.PrimaryPart
			local function seatY(model)
				return model.PrimaryPart.CFrame:ToObjectSpace(model:FindFirstChild("DriverSeat").CFrame).Position
			end
			t.ok(bare:GetAttribute("HeroMesh") == true, "both dressed (template installed for both)")
			local seat = m:FindFirstChild("DriverSeat")
			t.ok(weldedToChassis(seat, chassis), "seat re-welded")
			local welds = 0
			for _, c in seat:GetChildren() do
				if c:IsA("WeldConstraint") then
					welds += 1
				end
			end
			t.eq(welds, 1, "single seat weld")
			local pre = seat:GetAttribute("PreShellOffset")
			t.ok(typeof(pre) == "CFrame", "pre-shell seat spot remembered")
			t.near(seatY(m).Y, pre.Position.Y - 0.8, 1e-4, "seat lowered 0.8")
			t.near(seatY(m).Z, pre.Position.Z, 1e-4, "same z")
			CarBuilder.removeShell(m)
			t.near(seatY(m).Y, pre.Position.Y, 1e-4, "seat restored")
			local display = CarBuilder.buildDef(toilet, "None", { forDisplay = true })
			t.ok(display:FindFirstChild("DriverSeat") == nil, "display cars have no seat to move")
			t.eq(display:GetAttribute("HeroMesh"), true, "display toilet dressed")
		end)
	end)

	t.test("mutations swap the shell texture for the mutation material and None restores it", function()
		withTemplates({ makeTemplate("grandma_sedan", SEDAN) }, function()
			local m = CarBuilder.build("grandma_sedan", "None", { forDisplay = true })
			local mesh = meshOf(m)
			local spoiler = shellOf(m):FindFirstChild("Spoiler")
			local baseColor, baseMat = mesh.Color, mesh.Material
			t.eq(mesh.TextureID, TEXTURE, "textured at None")
			t.ok(mesh:FindFirstChild("Look") and mesh:FindFirstChild("Look"):IsA("SurfaceAppearance"), "SA applied")

			for _, mut in { "Gold", "Diamond", "Galaxy" } do
				CarBuilder.applyMutation(m, mut)
				local mdef = Rarity.getMutation(mut)
				t.eq(mesh.TextureID, "", mut .. " clears TextureID")
				t.ok(mesh:FindFirstChild("Look") == nil, mut .. " SurfaceAppearance off the part")
				local stash = mesh:FindFirstChild("ShellStash")
				t.ok(stash and stash:FindFirstChild("Look"), mut .. " SurfaceAppearance stashed")
				t.ok(mesh.Color == mdef.color, mut .. " color")
				t.eq(mesh.Material, mdef.material, mut .. " material")
				t.eq(spoiler.Material, mdef.material, mut .. " on every shell part")
				t.eq(m:GetAttribute("Mutation"), mut, mut .. " attribute")
			end
			-- sparkles: on the visible shell, exactly one emitter
			CarBuilder.applyMutation(m, "Diamond")
			local emitters = {}
			for _, d in m:GetDescendants() do
				if d.Name == CarBuilder.SPARKLES_NAME then
					table.insert(emitters, d)
				end
			end
			t.eq(#emitters, 1, "one sparkle emitter")
			t.ok(emitters[1].Parent == mesh, "sparkles on the biggest shell part")

			CarBuilder.applyMutation(m, "Rainbow")
			t.eq(mesh.TextureID, "", "Rainbow keeps the texture off")
			t.eq(mesh.Material, Enum.Material.SmoothPlastic, "Rainbow material")
			t.eq(#(function()
				local out = {}
				for _, d in m:GetDescendants() do
					if d.Name == CarBuilder.SPARKLES_NAME then
						table.insert(out, d)
					end
				end
				return out
			end)(), 0, "no sparkles on Rainbow")

			CarBuilder.applyMutation(m, "None")
			t.eq(mesh.TextureID, TEXTURE, "None restores TextureID")
			t.ok(mesh:FindFirstChild("Look") and mesh:FindFirstChild("Look"):IsA("SurfaceAppearance"), "SA restored")
			t.ok(mesh:FindFirstChild("ShellStash") == nil, "stash folder gone")
			t.ok(mesh.Color == baseColor, "base color restored")
			t.eq(mesh.Material, baseMat, "base material restored")
		end)
	end)

	t.test("a mutated build dresses the shell in it; repaint goes flat", function()
		withTemplates({ makeTemplate("grandma_sedan", SEDAN) }, function()
			local m = CarBuilder.build("grandma_sedan", "Galaxy", { forDisplay = true })
			local mesh = meshOf(m)
			t.eq(mesh.Material, Enum.Material.ForceField, "Galaxy shell")
			t.eq(mesh.TextureID, "", "Galaxy shell untextured")
			for _, d in m:GetDescendants() do
				if d:IsA("BasePart") and d:GetAttribute("Paint") == "primary" then
					t.eq(d.Material, Enum.Material.ForceField, "hidden procedural paint mutated too")
				end
			end
			-- spray shop: mutation look wins, then the flat paint shows once the mutation is gone
			local paint = Color3.fromRGB(10, 200, 90)
			CarBuilder.repaint(m, paint)
			t.eq(mesh.Material, Enum.Material.ForceField, "Galaxy kept after repaint")
			CarBuilder.applyMutation(m, "None")
			t.ok(mesh.Color == paint, "sprayed shell shows the paint")
			t.eq(mesh.TextureID, "", "sprayed shell untextured")
			t.eq(mesh.Material, Enum.Material.SmoothPlastic, "sprayed material")
			local plain = CarBuilder.build("grandma_sedan", "None", { forDisplay = true })
			CarBuilder.repaint(plain, paint)
			t.ok(meshOf(plain).Color == paint and meshOf(plain).TextureID == "", "repaint on a textured shell")
		end)
	end)

	t.test("removeShell brings the procedural car back", function()
		withTemplates({ makeTemplate("police_unit", { X = 7.5, Y = 6.25, Z = 14.85 }) }, function()
			local ref = CarBuilder.buildDef(Cars.Police, "Diamond")
			local m = CarBuilder.buildDef(Cars.Police, "Diamond")
			t.eq(CarBuilder.removeShell(m), true, "removed")
			t.eq(CarBuilder.removeShell(m), false, "nothing left to remove")
			t.ok(shellOf(m) == nil and m:GetAttribute("HeroMesh") == nil, "bare again")
			-- compare against the procedural layout captured before dressing: the stored ShellHidden values
			for _, c in m:GetChildren() do
				if c:IsA("BasePart") then
					t.ok(c:GetAttribute("ShellHidden") == nil, c.Name .. " unmarked")
					t.ok(c:GetAttribute("PreShellOffset") == nil, c.Name .. " offset cleared")
				end
			end
			local refSiren = m:FindFirstChild("SirenRed")
			local sirenRel = m.PrimaryPart.CFrame:ToObjectSpace(refSiren.CFrame)
			t.ok(sirenRel.Position.Y < 5.5, "siren back at the procedural lightbar")
			for _, d in m:GetDescendants() do
				if d:IsA("SurfaceGui") then
					t.eq(d.Enabled, true, "label back on")
				end
				if d.Name == CarBuilder.SPARKLES_NAME then
					t.ok(d.Parent:GetAttribute("Paint") == "primary", "sparkles back on the body")
				end
			end
			local visible = 0
			for _, c in m:GetChildren() do
				if c:IsA("BasePart") and c.Transparency < 1 then
					visible += 1
				end
			end
			t.ok(visible > 10, "procedural parts visible again")
			t.ok(ref:GetAttribute("HeroMesh") == true, "reference car still dressed")
		end)
	end)

	t.test("client-built models carry the ClientCar tag; server-built ones don't", function()
		local server = CarBuilder.build("grandma_sedan", "None", { forDisplay = true })
		t.ok(not server:HasTag(CarBuilder.CLIENT_TAG), "server build untagged")
		H.setMode("client")
		local restoreClient = require("../legacy_shells").clear(H.require("src/shared/Config/Cars"))
		local ok, err = pcall(function()
			local ClientBuilder = H.require("src/shared/Vehicle/CarBuilder")
			local m = ClientBuilder.build("grandma_sedan", "None", { forDisplay = true })
			t.ok(m:HasTag(ClientBuilder.CLIENT_TAG), "client build tagged")
			t.eq(ClientBuilder.CLIENT_TAG, "ClientCar", "tag name")
		end)
		restoreClient()
		H.setMode("server")
		if not ok then
			error(err, 0)
		end
	end)

	t.test("WheelAnimator agrees on the shell name and cycles the shell on Rainbow HeroMesh cars", function()
		H.setMode("client")
		local restoreClient = require("../legacy_shells").clear(H.require("src/shared/Config/Cars"))
		local ok, err = pcall(function()
			local WheelAnimator = H.require("src/client/Controllers/WheelAnimator")
			local ClientBuilder = H.require("src/shared/Vehicle/CarBuilder")
			t.eq(WheelAnimator.SHELL_NAME, ClientBuilder.SHELL_NAME, "SHELL_NAME")
			local bare = ClientBuilder.build("grandma_sedan", "Rainbow", { forDisplay = true })
			local parts = WheelAnimator.rainbowParts(bare)
			t.ok(#parts > 0, "procedural rainbow parts")
			for _, p in parts do
				t.eq(p:GetAttribute("Paint"), "primary", "primary paint")
			end
			withTemplates({ makeTemplate("grandma_sedan", SEDAN) }, function()
				local m = ClientBuilder.build("grandma_sedan", "Rainbow", { forDisplay = true })
				local shellParts = WheelAnimator.rainbowParts(m)
				t.eq(#shellParts, 2, "shell parts cycle")
				for _, p in shellParts do
					t.ok(p:IsDescendantOf(m:FindFirstChild(ClientBuilder.SHELL_NAME)), p.Name .. " in the shell")
				end
				t.eq(meshOf(m).TextureID, "", "rainbow shell untextured")
			end)
		end)
		restoreClient()
		H.setMode("server")
		if not ok then
			error(err, 0)
		end
	end)

	t.test("broken template never breaks a build", function()
		local empty = Instance.new("Model")
		empty.Name = "grandma_sedan"
		withTemplates({ empty }, function()
			local m = CarBuilder.build("grandma_sedan", "None")
			t.ok(m.PrimaryPart and m.PrimaryPart.Name == "Chassis", "car built")
			t.ok(m:GetAttribute("HeroMesh") == nil, "no shell from an empty template")
			t.ok(shellOf(m) == nil, "no leftover shell")
		end)
	end)

	t.test("opts.noShell (Index cards): procedural even with a template, and AssetClient leaves it bare", function()
		H.setMode("client")
		local restoreClient = require("../legacy_shells").clear(H.require("src/shared/Config/Cars"))
		local ok, err = pcall(function()
			local ClientBuilder = H.require("src/shared/Vehicle/CarBuilder")
			local AssetClient = H.require("src/client/Controllers/AssetClient")
			local views = Instance.new("Folder")
			views.Name = "IndexViews"
			views.Parent = H.workspace
			local okInner, errInner = pcall(function()
				withTemplates({ makeTemplate("grandma_sedan", SEDAN) }, function()
					local card = ClientBuilder.build("grandma_sedan", "None", { forDisplay = true, noShell = true })
					card.Parent = views
					t.ok(shellOf(card) == nil, "card: no hero shell")
					t.ok(card:GetAttribute("HeroMesh") == nil, "card: no HeroMesh")
					t.eq(card:GetAttribute(ClientBuilder.NO_SHELL_ATTR), true, "card marked NoShell")
					local detail = ClientBuilder.build("grandma_sedan", "None", { forDisplay = true })
					t.ok(shellOf(detail) ~= nil, "detail view (default opts) still wears the shell")
					t.ok(detail:GetAttribute(ClientBuilder.NO_SHELL_ATTR) == nil, "default build not marked")
					local dressed, bare = AssetClient.reskin("grandma_sedan")
					t.eq(dressed + bare, 0, "late re-skin skips NoShell cards")
					t.ok(shellOf(card) == nil, "card still procedural")
					local visible = 0
					for _, c in card:GetChildren() do
						if c:IsA("BasePart") and c.Transparency < 1 then
							visible += 1
						end
					end
					t.ok(visible > 10, "procedural parts visible on the card")
					detail:Destroy()
				end)
			end)
			views:Destroy()
			if not okInner then
				error(errInner, 0)
			end
		end)
		restoreClient()
		H.setMode("server")
		if not ok then
			error(err, 0)
		end
	end)
	restoreVehicles()
end
