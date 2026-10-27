--!strict
-- CarpipeRig (reference adapter, not wired into src/ yet).
--
-- Turns a Model imported from a carpipe GLB (MeshParts Body, Body2?, Glass, LightsFront?, LightsRear?, Trim,
-- Interior?, WheelFL/FR/RL/RR) plus its sidecar spec (sidecar_to_luau.py output) into the car MODEL CONTRACT
-- used by src/shared/Vehicle/CarBuilder.luau (docs/SPEC.md §8), so VehicleService / WheelAnimator / Garage etc.
-- can drive it unchanged:
--   * PrimaryPart "Chassis" (invisible, the only collidable part), Attachments "WheelFL".. at the hub centres,
--   * wheel MeshParts renamed "Wheel_FL".. with Welds "WheelWeld_FL".. (Part0 = Chassis, C1 = identity),
--   * "DriverSeat" VehicleSeat (disabled, invisible), "Headlight"/"Taillight" with SpotLight "Beam",
--   * Paint attributes "primary" (Body), "accent" (Body2), "glass" (Glass), Model attributes RideHeight,
--     WheelRadius, Length, Width, Height, BodyCenter, HeroMesh = true.
-- BUILT POSE matches carpipe's export: ground y = 0, centred on x/z, front facing -Z.

local CarpipeRig = {}

export type Vec = { number }
export type WheelSpec = { object: string, center: Vec, radius: number, width: number, part_center: Vec }
export type Spec = {
	name: string,
	dimensions: { length: number, width: number, height: number, wheelbase: number? },
	wheels: { [string]: WheelSpec }, -- keys "FL","FR","RL","RR"
	seats: { driver: { position: Vec } },
	lights: { front: { { position: Vec } }, rear: { { position: Vec } } },
	paint: { primary: { color_srgb: Vec } },
	mass: number?,
}

local function v3(t: Vec): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

local function quiet(p: BasePart)
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
end

-- model: the imported Model (parts in BUILT POSE, i.e. as imported at the origin). spec: sidecar table.
function CarpipeRig.rig(model: Model, spec: Spec): Model
	local d = spec.dimensions
	local wr = 0
	for _, w in spec.wheels do
		wr = math.max(wr, w.radius)
	end
	-- Chassis: lower-body collision hull from just above the wheel bottoms to ~55% of the roof height
	local bottom = wr * 0.55
	local h = math.max(d.height * 0.55 - bottom, 1)
	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Size = Vector3.new(d.width * 0.92, h, d.length * 0.96)
	chassis.CFrame = CFrame.new(0, bottom + h / 2, 0)
	chassis.Transparency = 1
	chassis.CanCollide = true
	chassis.CanQuery = true
	chassis.CanTouch = true
	chassis.CastShadow = false
	local mass = spec.mass or 1400
	local density = math.clamp(mass / (chassis.Size.X * chassis.Size.Y * chassis.Size.Z), 0.7, 100)
	chassis.CustomPhysicalProperties = PhysicalProperties.new(density, 0.3, 0, 1, 1)
	chassis.Parent = model
	model.PrimaryPart = chassis
	local origin = chassis.Position

	-- wheels: Weld C0 at the mesh's part centre (differs from the hub only along the axle, so spin stays true)
	for key, w in spec.wheels do
		local part = model:FindFirstChild(w.object) :: BasePart?
		if not part then
			continue
		end
		part.Name = "Wheel_" .. key
		quiet(part)
		local att = Instance.new("Attachment")
		att.Name = "Wheel" .. key
		att.CFrame = CFrame.new(v3(w.center) - origin)
		att.Parent = chassis
		local weld = Instance.new("Weld")
		weld.Name = "WheelWeld_" .. key
		weld.Part0 = chassis
		weld.Part1 = part
		weld.C0 = CFrame.new(v3(w.part_center) - origin)
		weld.C1 = CFrame.new()
		weld.Parent = chassis
	end

	-- body parts: weld + paint tags
	local paintTag = { Body = "primary", Body2 = "accent", Glass = "glass" }
	for _, inst in model:GetChildren() do
		if inst:IsA("BasePart") and inst ~= chassis and not string.match(inst.Name, "^Wheel_") then
			quiet(inst)
			local tag = paintTag[inst.Name]
			if tag then
				inst:SetAttribute("Paint", tag)
				inst:SetAttribute("BaseColor", inst.Color)
				inst:SetAttribute("BaseMaterial", inst.Material.Name)
			end
			if inst.Name == "Glass" then
				inst.Material = Enum.Material.Glass
				inst.Transparency = 0.45
			elseif inst.Name == "LightsFront" then
				inst.Name = "Headlight"
			elseif inst.Name == "LightsRear" then
				inst.Name = "Taillight"
			end
			local wc = Instance.new("WeldConstraint")
			wc.Name = "Weld"
			wc.Part0 = chassis
			wc.Part1 = inst
			wc.Parent = inst
		end
	end
	local body = model:FindFirstChild("Body") :: BasePart?
	if body then
		local c = spec.paint.primary.color_srgb
		body.Color = Color3.new(c[1], c[2], c[3])
		body.Material = Enum.Material.SmoothPlastic
		body.Reflectance = 0.08
	end

	-- headlight beams (disabled until the lights are switched on)
	local head = model:FindFirstChild("Headlight") :: BasePart?
	if head then
		for i, l in spec.lights.front do
			local a = Instance.new("Attachment")
			a.Name = "BeamAttach" .. i
			a.CFrame = CFrame.new(v3(l.position) - origin)
			a.Parent = chassis
			local beam = Instance.new("SpotLight")
			beam.Name = "Beam"
			beam.Face = Enum.NormalId.Front
			beam.Angle = 60
			beam.Range = 45
			beam.Brightness = 3
			beam.Enabled = false
			beam.Parent = a
		end
	end

	-- driver seat at the hip point (seat part top just below it)
	local s = v3(spec.seats.driver.position)
	local seat = Instance.new("VehicleSeat")
	seat.Name = "DriverSeat"
	seat.Size = Vector3.new(2, 0.3, 2)
	seat.CFrame = CFrame.new(s.X, s.Y - 0.15, s.Z)
	seat.Transparency = 1
	quiet(seat)
	seat.CastShadow = false
	seat.Disabled = true
	seat.MaxSpeed = 0
	seat.Torque = 0
	seat.TurnSpeed = 0
	seat.HeadsUpDisplay = false
	seat.Parent = model
	local sw = Instance.new("WeldConstraint")
	sw.Part0 = chassis
	sw.Part1 = seat
	sw.Parent = seat

	model:SetAttribute("RideHeight", chassis.Position.Y)
	model:SetAttribute("WheelRadius", wr)
	model:SetAttribute("Length", d.length)
	model:SetAttribute("Width", d.width)
	model:SetAttribute("Height", d.height)
	model:SetAttribute("BodyCenter", Vector3.new(0, 0, 0))
	model:SetAttribute("HeroMesh", true)
	model:SetAttribute("CarpipeName", spec.name)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	return model
end

-- Runtime repaint (strip route): Body is untextured, so MeshPart.Color is the paint.
function CarpipeRig.paint(model: Model, primary: Color3, accent: Color3?)
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			local tag = p:GetAttribute("Paint")
			if tag == "primary" then
				p.Color = primary
			elseif tag == "accent" and accent then
				p.Color = accent
			end
		elseif p:IsA("SurfaceAppearance") and p.Parent and (p.Parent :: Instance):GetAttribute("Paint") == "primary" then
			-- tint-mask route: SurfaceAppearance authored with AlphaMode = TintMask
			(p :: any).Color = primary
		end
	end
end

return CarpipeRig
