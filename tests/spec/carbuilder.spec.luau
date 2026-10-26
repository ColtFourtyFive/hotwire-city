--!nocheck
-- Shared/Vehicle/CarBuilder: every catalog car + the police unit builds and honors the model contract (SPEC §8)
-- that VehicleService, VehicleController, WheelAnimator, Garage/Dealership display and the Index rely on.
return function(t)
	local H = t.H
	local Enum = H.roblox.Enum
	local CFrame = H.roblox.CFrame
	local CarBuilder = H.require("src/shared/Vehicle/CarBuilder")
	local Cars = H.require("src/shared/Config/Cars")
	local Rarity = H.require("src/shared/Config/Rarity")

	local ALL_STYLES = {
		"compact",
		"sedan",
		"taxi",
		"van",
		"pickup",
		"muscle",
		"sports",
		"suv",
		"limo",
		"police",
		"super",
		"hyper",
		"monster",
		"armored",
		"icecream",
		"tank",
		"hover",
		"hotdog",
		"duck",
		"couch",
		"toilet",
		"rocket",
	}
	local WHEELS = { "FL", "FR", "RL", "RR" }

	local defs = {}
	for _, d in Cars.List do
		table.insert(defs, d)
	end
	table.insert(defs, Cars.Police)

	local function build(def, mutation, opts)
		if def == Cars.Police then
			return CarBuilder.buildDef(def, mutation, opts)
		end
		return CarBuilder.build(def.id, mutation, opts)
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

	local function weldedTo(part)
		for _, c in part:GetChildren() do
			if c:IsA("WeldConstraint") and c.Part1 == part then
				return c.Part0
			end
		end
		return nil
	end

	-- built-pose models are cached so the many checks below don't rebuild 33 cars each time
	local built = {}
	for _, def in defs do
		built[def.id] = build(def, "None")
	end

	t.test("every CarStyle has a builder and every catalog style is covered", function()
		local known = {}
		for _, s in CarBuilder.styles() do
			known[s] = true
		end
		for _, s in ALL_STYLES do
			t.ok(known[s], "missing style builder " .. s)
		end
		for _, def in defs do
			t.ok(known[def.style], def.id .. " uses unknown style " .. def.style)
		end
	end)

	t.test("chassis is the invisible collidable PrimaryPart and the pivot", function()
		for _, def in defs do
			local m = built[def.id]
			local id = def.id
			local chassis = m:FindFirstChild("Chassis")
			t.ok(chassis and chassis:IsA("Part"), id .. " has Chassis")
			t.ok(m.PrimaryPart == chassis, id .. " PrimaryPart = Chassis")
			t.eq(chassis.Transparency, 1, id .. " chassis invisible")
			t.ok(chassis.CanCollide and chassis.CanQuery, id .. " chassis collidable/queryable")
			t.ok(not chassis.Anchored and not chassis.Massless, id .. " chassis unanchored & massive")
			local cpp = chassis.CustomPhysicalProperties
			t.ok(cpp ~= nil, id .. " chassis CustomPhysicalProperties")
			local mass = cpp.Density * chassis.Size.X * chassis.Size.Y * chassis.Size.Z
			t.ok(mass >= 850 and mass <= 3100, ("%s mass %.0f outside 900-3000"):format(id, mass))
			t.near(cpp.Elasticity, 0, 1e-6, id .. " elasticity")
			t.eq(m.ModelStreamingMode, Enum.ModelStreamingMode.Atomic, id .. " streaming atomic")
			local pivot = m:GetPivot()
			t.near((pivot.Position - chassis.CFrame.Position).Magnitude, 0, 1e-4, id .. " pivot = chassis")
			t.near(pivot.Position.Y, m:GetAttribute("RideHeight"), 1e-4, id .. " RideHeight = pivot height")
			t.ok(pivot.LookVector.Z < -0.99, id .. " faces -Z")
		end
	end)

	t.test("model attributes", function()
		for _, def in defs do
			local m = built[def.id]
			local id = def.id
			for _, a in { "RideHeight", "WheelRadius", "Length", "Width", "Height" } do
				t.ok(typeof(m:GetAttribute(a)) == "number", id .. " number attribute " .. a)
			end
			t.eq(m:GetAttribute("Style"), def.style, id .. " Style")
			t.eq(m:GetAttribute("CarId"), def.id, id .. " CarId")
			t.eq(m:GetAttribute("Mutation"), "None", id .. " Mutation")
			local r = m:GetAttribute("WheelRadius")
			t.ok(r >= 1 and r <= 2.8, id .. " wheel radius " .. r)
			t.ok(m:GetAttribute("RideHeight") > r * 0.6, id .. " ride height sane")
		end
	end)

	t.test("size limits (garage slot 16x10, limo may be 18)", function()
		for _, def in defs do
			local m = built[def.id]
			local maxLen = if def.style == "limo" then 18 else 16
			t.ok(m:GetAttribute("Length") <= maxLen, ("%s length %.2f"):format(def.id, m:GetAttribute("Length")))
			t.ok(m:GetAttribute("Width") <= 8.5, ("%s width %.2f"):format(def.id, m:GetAttribute("Width")))
			t.ok(m:GetAttribute("Height") <= 12, ("%s height %.2f"):format(def.id, m:GetAttribute("Height")))
			t.ok(m:GetAttribute("Length") >= 7, def.id .. " not tiny")
		end
	end)

	t.test("part budget <= 40", function()
		for _, def in defs do
			local n = #partsOf(built[def.id])
			t.ok(n <= 40, ("%s has %d parts"):format(def.id, n))
		end
	end)

	t.test("wheels: attachments at hubs, cylinders, welds, resting on the ground", function()
		for _, def in defs do
			local m = built[def.id]
			local id = def.id
			local chassis = m.PrimaryPart
			local r = m:GetAttribute("WheelRadius")
			local groundY = m:GetPivot().Position.Y - m:GetAttribute("RideHeight")
			for _, k in WHEELS do
				local att = chassis:FindFirstChild("Wheel" .. k)
				t.ok(att and att:IsA("Attachment"), id .. " attachment Wheel" .. k)
				local wheel = m:FindFirstChild("Wheel_" .. k)
				t.ok(wheel and wheel:IsA("Part"), id .. " part Wheel_" .. k)
				t.eq(wheel.Shape, Enum.PartType.Cylinder, id .. " wheel is a cylinder")
				t.ok(not wheel.CanCollide and wheel.Massless and not wheel.CanTouch, id .. " wheel non-physical")
				t.near(wheel.Size.Y / 2, r, 1e-3, id .. " wheel radius matches attribute")
				local weld = chassis:FindFirstChild("WheelWeld_" .. k)
				t.ok(weld and weld:IsA("Weld"), id .. " WheelWeld_" .. k .. " in Chassis")
				t.ok(weld.Part0 == chassis and weld.Part1 == wheel, id .. " weld parts")
				t.near((weld.C0.Position - att.Position).Magnitude, 0, 1e-4, id .. " C0 at attachment")
				t.near((att.CFrame.Position - att.Position).Magnitude, 0, 1e-4, id .. " attachment CFrame/Position")
				local expected = chassis.CFrame * weld.C0 * weld.C1:Inverse()
				t.near((expected.Position - wheel.CFrame.Position).Magnitude, 0, 1e-3, id .. " wheel at weld pose")
				local hub = chassis.CFrame * att.Position
				t.near(hub.Y - r, groundY, 0.15, id .. " wheel " .. k .. " bottom on ground")
				local front = string.sub(k, 1, 1) == "F"
				local left = string.sub(k, 2, 2) == "L"
				t.ok((hub.Z < 0) == front, id .. " " .. k .. " front/rear")
				t.ok((hub.X < 0) == left, id .. " " .. k .. " left/right")
			end
		end
	end)

	t.test("only Chassis and BumpStops collide; everything else welded, massless, unanchored", function()
		for _, def in defs do
			local m = built[def.id]
			local id = def.id
			local chassis = m.PrimaryPart
			local stops = 0
			local groundY = m:GetPivot().Position.Y - m:GetAttribute("RideHeight")
			for _, p in partsOf(m) do
				t.ok(not p.Anchored, id .. " " .. p.Name .. " anchored")
				if p.Name == "BumpStop" then
					stops += 1
					t.eq(p.Shape, Enum.PartType.Ball, id .. " bump-stop is a ball")
					t.ok(p.CanCollide and p.Transparency == 1 and p.Massless, id .. " bump-stop props")
					t.near(p.CFrame.Position.Y - p.Size.Y / 2, groundY + 0.25, 0.1, id .. " bump-stop clearance")
					t.ok(weldedTo(p) == chassis, id .. " bump-stop welded")
				elseif p ~= chassis then
					t.ok(not p.CanCollide, id .. " unexpected collidable " .. p.Name)
					t.ok(not p.CanTouch, id .. " CanTouch " .. p.Name)
					t.ok(not p.CanQuery, id .. " CanQuery " .. p.Name)
					t.ok(p.Massless, id .. " not massless " .. p.Name)
					if string.sub(p.Name, 1, 6) ~= "Wheel_" then
						t.ok(weldedTo(p) ~= nil, id .. " not welded " .. p.Name)
					end
				end
			end
			t.eq(stops, 2, id .. " bump-stop count")
		end
	end)

	t.test("driver seat contract", function()
		for _, def in defs do
			local m = built[def.id]
			local id = def.id
			local seat = m:FindFirstChild("DriverSeat")
			t.ok(seat and seat:IsA("VehicleSeat"), id .. " DriverSeat")
			t.ok(seat.Disabled, id .. " seat disabled")
			t.ok(not seat.CanTouch and not seat.CanCollide, id .. " seat touch/collide")
			t.eq(seat.MaxSpeed, 0, id .. " MaxSpeed")
			t.eq(seat.Torque, 0, id .. " Torque")
			t.eq(seat.TurnSpeed, 0, id .. " TurnSpeed")
			t.ok(not seat.HeadsUpDisplay, id .. " HUD")
			t.eq(seat.Transparency, 1, id .. " seat invisible")
			t.ok(weldedTo(seat) == m.PrimaryPart, id .. " seat welded to chassis")
			t.ok(math.abs(seat.CFrame.Position.Z) < m:GetAttribute("Length") / 2, id .. " seat inside the car")
		end
	end)

	t.test("lights and paint", function()
		for _, def in defs do
			local m = built[def.id]
			local id = def.id
			local heads, tails, primary, sirenR, sirenB = 0, 0, 0, 0, 0
			for _, p in partsOf(m) do
				if p.Name == "Headlight" then
					heads += 1
					t.eq(p.Material, Enum.Material.Neon, id .. " headlight neon")
					local beam = p:FindFirstChildOfClass("SpotLight")
					t.ok(beam and beam.Enabled == false, id .. " headlight SpotLight disabled")
				elseif p.Name == "Taillight" then
					tails += 1
					t.eq(p.Material, Enum.Material.Neon, id .. " taillight neon")
				elseif p.Name == "SirenRed" then
					sirenR += 1
				elseif p.Name == "SirenBlue" then
					sirenB += 1
				end
				local paint = p:GetAttribute("Paint")
				if paint ~= nil then
					t.ok(
						paint == "primary" or paint == "accent" or paint == "glass",
						id .. " paint value " .. tostring(paint)
					)
				end
				if paint == "primary" then
					primary += 1
					t.ok(typeof(p:GetAttribute("BaseColor")) == "Color3", id .. " BaseColor")
				elseif paint == "glass" then
					t.ok(p.Transparency > 0 and p.Transparency < 0.6, id .. " glass transparency")
				end
			end
			t.eq(heads, 2, id .. " two headlights")
			t.ok(tails >= 1, id .. " taillights")
			t.ok(primary >= 2, id .. " primary paint parts")
			if def.style == "police" then
				t.ok(sirenR >= 1 and sirenB >= 1, id .. " siren lights")
			end
		end
	end)

	t.test("hover and tank wheels are invisible, others visible", function()
		for _, def in defs do
			local m = built[def.id]
			local hidden = def.style == "hover" or def.style == "tank"
			for _, k in WHEELS do
				local w = m:FindFirstChild("Wheel_" .. k)
				t.eq(w.Transparency == 1, hidden, def.id .. " wheel visibility")
			end
		end
	end)

	t.test("forDisplay omits seat and bump-stops but keeps the rest", function()
		for _, def in defs do
			local full = built[def.id]
			local disp = build(def, "None", { forDisplay = true })
			t.ok(disp:FindFirstChild("DriverSeat") == nil, def.id .. " display has no seat")
			t.ok(disp:FindFirstChild("BumpStop") == nil, def.id .. " display has no bump-stops")
			t.ok(disp.PrimaryPart and disp.PrimaryPart.Name == "Chassis", def.id .. " display chassis")
			t.ok(disp.PrimaryPart:FindFirstChild("WheelWeld_FL") ~= nil, def.id .. " display wheel welds")
			t.eq(#partsOf(disp), #partsOf(full) - 3, def.id .. " display part count")
			t.near(
				disp:GetAttribute("RideHeight"),
				full:GetAttribute("RideHeight"),
				1e-6,
				def.id .. " same ride height"
			)
			t.near(disp:GetAttribute("Length"), full:GetAttribute("Length"), 1e-6, def.id .. " same length")
		end
	end)

	t.test("PivotTo a ground CFrame like VehicleService puts the wheels on that ground", function()
		local m = CarBuilder.build("bigfoot", "None")
		local ground = CFrame.new(120, 5, -40) * CFrame.Angles(0, 1.1, 0)
		m:PivotTo(ground * CFrame.new(0, m:GetAttribute("RideHeight"), 0))
		local r = m:GetAttribute("WheelRadius")
		for _, k in WHEELS do
			local w = m:FindFirstChild("Wheel_" .. k)
			t.near(w.CFrame.Position.Y - r, 5, 0.15, "wheel " .. k .. " on ground after pivot")
		end
		local look = m:GetPivot().LookVector
		t.near(look.Y, 0, 1e-4, "still level")
	end)

	t.test("deterministic builds", function()
		local a = CarBuilder.build("hotdog_wagon", "None")
		local b = CarBuilder.build("hotdog_wagon", "None")
		local pa, pb = partsOf(a), partsOf(b)
		t.eq(#pa, #pb, "same part count")
		for i = 1, #pa do
			t.eq(pa[i].Name, pb[i].Name, "same order")
			t.near((pa[i].CFrame.Position - pb[i].CFrame.Position).Magnitude, 0, 1e-6, "same placement")
		end
	end)

	local function primaries(m)
		local out = {}
		for _, p in partsOf(m) do
			if p:GetAttribute("Paint") == "primary" then
				table.insert(out, p)
			end
		end
		return out
	end

	local function sparkles(m)
		local n = 0
		for _, d in m:GetDescendants() do
			if d:IsA("ParticleEmitter") and d.Name == "MutationSparkles" then
				n += 1
				t.eq(d.Texture, "rbxasset://textures/particles/sparkles_main.dds", "sparkle texture")
				t.ok(d.Rate > 0 and d.Rate <= 10, "low sparkle rate")
			end
		end
		return n
	end

	local function sameColor(a, b)
		return math.abs(a.R - b.R) < 0.01 and math.abs(a.G - b.G) < 0.01 and math.abs(a.B - b.B) < 0.01
	end

	t.test("mutations recolor primary paint, add sparkles, set the attribute", function()
		for _, mut in { "Gold", "Diamond", "Galaxy" } do
			local mdef = Rarity.Mutations[mut]
			local m = CarBuilder.build("stallion_gt", mut)
			t.eq(m:GetAttribute("Mutation"), mut, mut .. " attribute")
			for _, p in primaries(m) do
				t.ok(sameColor(p.Color, mdef.color), mut .. " color on " .. p.Name)
				t.eq(p.Material, mdef.material, mut .. " material on " .. p.Name)
			end
			local expected = if mut == "Gold" then 0 else 1
			t.eq(sparkles(m), expected, mut .. " sparkle emitters")
		end
		local rainbow = CarBuilder.build("stallion_gt", "Rainbow")
		t.eq(rainbow:GetAttribute("Mutation"), "Rainbow", "rainbow attribute")
		local ps = primaries(rainbow)
		t.ok(not sameColor(ps[1].Color, ps[#ps].Color), "rainbow sweep varies hue")
		t.eq(sparkles(rainbow), 0, "no rainbow sparkles")
		-- accent paint is never touched
		local gold = CarBuilder.build("stallion_gt", "Gold")
		for _, p in partsOf(gold) do
			if p:GetAttribute("Paint") == "accent" then
				t.ok(sameColor(p.Color, Cars.get("stallion_gt").accent), "accent untouched")
			end
		end
	end)

	t.test("applyMutation is re-appliable and None restores the base look", function()
		local base = CarBuilder.build("mini_bean", "None")
		local before = {}
		for _, p in primaries(base) do
			before[p] = { p.Color, p.Material }
		end
		CarBuilder.applyMutation(base, "Galaxy")
		t.eq(sparkles(base), 1, "galaxy sparkles")
		CarBuilder.applyMutation(base, "Diamond")
		t.eq(sparkles(base), 1, "sparkles replaced, not stacked")
		CarBuilder.applyMutation(base, "None")
		t.eq(sparkles(base), 0, "sparkles removed")
		t.eq(base:GetAttribute("Mutation"), "None", "attribute reset")
		for p, look in before do
			t.ok(sameColor(p.Color, look[1]), "color restored " .. p.Name)
			t.eq(p.Material, look[2], "material restored " .. p.Name)
		end
		CarBuilder.applyMutation(base, "Bogus")
		t.eq(base:GetAttribute("Mutation"), "None", "unknown mutation -> None")
	end)

	t.test("repaint and headlights helpers", function()
		local m = CarBuilder.build("grandma_sedan", "None")
		local red = H.roblox.Color3.fromRGB(255, 0, 0)
		CarBuilder.repaint(m, red)
		for _, p in primaries(m) do
			t.ok(sameColor(p.Color, red), "repainted " .. p.Name)
		end
		CarBuilder.setHeadlights(m, true)
		for _, p in partsOf(m) do
			if p.Name == "Headlight" then
				t.ok(p:FindFirstChildOfClass("SpotLight").Enabled, "headlight on")
			end
		end
		local g = CarBuilder.build("grandma_sedan", "Gold")
		CarBuilder.repaint(g, red)
		t.eq(g:GetAttribute("Mutation"), "Gold", "repaint keeps mutation")
		t.ok(sameColor(primaries(g)[1].Color, Rarity.Mutations.Gold.color), "gold look kept")
	end)

	t.test("unknown ids fall back, police def builds by id", function()
		local m = CarBuilder.build("definitely_not_a_car", "None")
		t.ok(m.PrimaryPart ~= nil, "fallback build")
		local p = CarBuilder.build(Cars.Police.id, "None")
		t.eq(p:GetAttribute("Style"), "police", "police by id")
	end)

	t.test("styleDims for every style", function()
		for _, s in ALL_STYLES do
			local d = CarBuilder.styleDims(s)
			t.ok(d.length > 7 and d.length <= 18, s .. " length")
			t.ok(d.width > 5 and d.width <= 8.5, s .. " width")
			t.ok(d.height > 3 and d.height <= 12, s .. " height")
			t.ok(d.wheelRadius >= 1 and d.wheelRadius <= 2.8, s .. " wheel radius")
			t.ok(CarBuilder.styleDims(s) == d, s .. " cached")
		end
		local mono = CarBuilder.styleDims("monster")
		t.ok(mono.wheelRadius > 2.4, "monster wheels are huge")
	end)
end
