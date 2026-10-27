--!strict
-- MeshCar: the CarBuilder v2 rig for uploaded car Models (Config/Vehicles + Shared/Vehicle/CarTemplates).
--
-- It keeps the v1 MODEL CONTRACT (docs/SPEC.md §8, top of CarBuilder) so VehicleService, VehicleController,
-- WheelAnimator, Garage / Dealership display, Traffic, Police and the Index drive a v2 car unchanged:
--   * "Chassis": invisible box, the only collidable body part, PrimaryPart and pivot. Sized from the Body MeshPart's
--     box (94% wide, 97% long) between a curb-safe floor (>= CHASSIS_MIN_BOTTOM above the ground) and 62% of the roof
--     height; CustomPhysicalProperties density gives the class mass (Config/Vehicles.mass, 1100-3000).
--   * Attachments "WheelFL".. at the true axle centres (carpipe sidecar), so the raycast suspension pushes where the
--     tyres are. Wheels are the uploaded MeshParts renamed "Wheel_FL".., each on a Weld "WheelWeld_FL".. (Part0 =
--     Chassis, C0 = the wheel's built-pose frame, C1 = identity): WheelAnimator spins / steers / bobs them by C0, about
--     the MeshPart's own X axis (= the axle: carpipe straightens and centres every wheel). Extra axles (bus / truck
--     duals, "WheelML".. -> "Wheel_ML") get welds too and spin with the rear wheels.
--   * "DriverSeat" VehicleSeat with its top SEAT_SINK below the sidecar's hip point; two "BumpStop" balls under the
--     axles (both omitted for forDisplay).
--   * Every MeshPart: unanchored, Massless, CanCollide / CanQuery / CanTouch false, WeldConstraint to the Chassis.
--     Body = Paint "primary" (MeshPart.Color is the paint; Body.TextureID = Vehicles.bodyImage: the overlay with the
--     paint pixels transparent, or the full livery), Body2 = "accent", Glass = "glass" (Material Glass).
--     Trim / Interior / Wheels keep the importer's SurfaceAppearance (PBR); LightsFront / LightsRear keep their
--     TextureID and are tagged Lens = "front" / "rear" (WheelAnimator lights them at night / on the brakes).
--   * Lights: two invisible "Headlight" anchor parts at the sidecar lamp centres (front face -Z) holding the disabled
--     SpotLight "Beam" (CarBuilder.setHeadlights, WheelAnimator night cones); two invisible "Taillight" anchors at the
--     rear lamps, the first holding PointLights "BrakeGlow" / "ReverseGlow" (disabled; WheelAnimator).
--   * Police: the lightbar lenses "SirenRed" / "SirenBlue" (MeshParts split out by carpipe) are Neon on units with
--     def.police (EffectsController flashes them on Police-tagged cars); other cars (the retired cruiser) keep them
--     dark. Taxi roof sign -> "TaxiSign".
--   * Model attributes: the v1 set (RideHeight, WheelRadius, Length, Width, Height, BodyCenter, Style, CarId) plus
--     Vehicle (Config/Vehicles id), MeshCar = true, Brand, and RigVersion (bumped whenever the rig is rebuilt in
--     place so WheelAnimator re-reads its welds).
-- BUILT POSE as everywhere: ground y = 0, wheel midpoint at x = z = 0, front -Z.
--
-- Late arrival: a car built while its template was not ready is the v1 procedural car with attribute MeshPending =
-- <vehicle id>. MeshCar.convert() turns it into the mesh rig IN PLACE (same Model, Chassis, seat and prompt
-- instances: VehicleService / Traffic / Police keep their references): procedural visuals (attribute Proc) are
-- destroyed, the Chassis is resized around its own centre, wheel attachments / seat / bump stops move to the spec,
-- the mesh is mounted, and an anchored car is lifted or lowered so its tyres stay on the ground.
--
-- Pure instance construction (Lune harness: tests publish stand-in templates through CarTemplates.publish).

local Shared = script.Parent.Parent
local Cars = require(Shared.Config.Cars)
local Vehicles = require(Shared.Config.Vehicles)

type CarDef = Cars.CarDef
type Spec = Vehicles.Spec

local MeshCar = {}

MeshCar.CHASSIS_MIN_BOTTOM = 0.75 -- studs above the ground (v1 curbs are 0.6 high)
MeshCar.CHASSIS_TOP = 0.62 -- fraction of the car's height
MeshCar.CHASSIS_MIN_HEIGHT = 1.2
MeshCar.CHASSIS_WIDTH = 0.94 -- fraction of the Body box
MeshCar.CHASSIS_LENGTH = 0.97
MeshCar.SEAT_SINK = 0.35 -- seat top below the sidecar's hip point
MeshCar.GLASS_TRANSPARENCY = 0.35
MeshCar.GLASS_COLOR = Color3.fromRGB(26, 31, 35)
MeshCar.PAINT_REFLECTANCE = 0.08
MeshCar.SIREN_RED = Color3.fromRGB(255, 36, 36)
MeshCar.SIREN_BLUE = Color3.fromRGB(40, 110, 255)
MeshCar.SIREN_DARK_RED = Color3.fromRGB(90, 24, 24)
MeshCar.SIREN_DARK_BLUE = Color3.fromRGB(24, 34, 80)
MeshCar.LIVERY_COLOR = Color3.fromRGB(245, 245, 245)
MeshCar.PROC_ATTR = "Proc" -- marks CarBuilder's procedural visual parts (destroyed by convert)
MeshCar.PENDING_ATTR = "MeshPending"
MeshCar.BUMPSTOP_SIZE = 1
MeshCar.BUMPSTOP_CLEARANCE = 0.25

local V = Vector3.new
local WHEEL_MAIN = { "FL", "FR", "RL", "RR" }
local KEEP = { Chassis = true, DriverSeat = true, BumpStop = true }

export type WheelLayout = { key: string, hub: Vector3, part: Vector3, radius: number, main: boolean }
export type Layout = {
	chassisCenter: Vector3, -- built pose
	chassisSize: Vector3,
	density: number,
	wheels: { WheelLayout },
	seatCFrame: CFrame, -- built pose (seat part centre)
	axleZ: { number },
	bodyCenter: Vector3, -- built pose, y = 0
}

-- The rig geometry of a vehicle in the built pose (pure).
function MeshCar.layout(spec: Spec): Layout
	local body = spec.parts.Body
	local bc = if body then body.center else (spec.bboxMin + spec.bboxMax) / 2
	local bs = if body then body.size else spec.bboxMax - spec.bboxMin
	local bodyBottom = bc.Y - bs.Y / 2
	local bottom = math.max(MeshCar.CHASSIS_MIN_BOTTOM, math.min(bodyBottom + 0.15, spec.wheelRadius * 0.9))
	local top = math.max(bottom + MeshCar.CHASSIS_MIN_HEIGHT, spec.height * MeshCar.CHASSIS_TOP)
	local size = V(bs.X * MeshCar.CHASSIS_WIDTH, top - bottom, bs.Z * MeshCar.CHASSIS_LENGTH)
	local center = V(bc.X, (bottom + top) / 2, bc.Z)
	local density = math.clamp(spec.mass / (size.X * size.Y * size.Z), 0.7, 100)
	local wheels: { WheelLayout } = {}
	local front, rear = math.huge, -math.huge
	for _, w in spec.wheels do
		local main = table.find(WHEEL_MAIN, w.key) ~= nil
		table.insert(wheels, { key = w.key, hub = w.center, part = w.partCenter, radius = w.radius, main = main })
		if main then
			front = math.min(front, w.center.Z)
			rear = math.max(rear, w.center.Z)
		end
	end
	local s = spec.seat
	local seatTop = s.Y - MeshCar.SEAT_SINK
	return {
		chassisCenter = center,
		chassisSize = size,
		density = density,
		wheels = wheels,
		seatCFrame = CFrame.new(s.X, seatTop - 0.15, s.Z),
		axleZ = { front, rear },
		bodyCenter = V(bc.X, 0, bc.Z),
	}
end

local function quiet(p: BasePart)
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
end

local function weldConstraint(chassis: BasePart, part: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Name = "Weld"
	w.Part0 = chassis
	w.Part1 = part
	w.Parent = part
end

local function unweld(part: BasePart)
	for _, c in part:GetChildren() do
		if c:IsA("WeldConstraint") then
			c:Destroy()
		end
	end
end

local function anchorPart(name: string, size: Vector3, cf: CFrame, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Transparency = 1
	p.CastShadow = false
	quiet(p)
	p.Parent = parent
	return p
end

-- Is this def's lightbar live (Neon sirens)?
function MeshCar.isPolice(def: CarDef): boolean
	return def.police == true
end

-- Paint / material looks of one mounted MeshPart (by role name, before renaming).
local function dressPart(part: BasePart, role: string, def: CarDef, spec: Spec)
	part.CastShadow = role ~= "Interior" and role ~= "Glass" and role ~= "SirenRed" and role ~= "SirenBlue"
	if role == "Body" then
		-- a livery image covers the whole body (its colour only shows through transparent texels); an untextured
		-- livery body (strip route: e.g. the fire truck's red) is just the catalog colour
		local livery = spec.bodyMode == "livery" and spec.bodyImage > 0
		local color = if livery then MeshCar.LIVERY_COLOR else def.color
		part.Color = color
		part.Material = Enum.Material.SmoothPlastic
		part.Reflectance = MeshCar.PAINT_REFLECTANCE
		part:SetAttribute("Paint", "primary")
		part:SetAttribute("BaseColor", color)
		part:SetAttribute("BaseMaterial", "SmoothPlastic")
		if spec.bodyImage > 0 and part:IsA("MeshPart") then
			(part :: MeshPart).TextureID = "rbxassetid://" .. tostring(spec.bodyImage)
		end
	elseif role == "Body2" then
		part.Color = def.accent
		part.Material = Enum.Material.SmoothPlastic
		part.Reflectance = MeshCar.PAINT_REFLECTANCE
		part:SetAttribute("Paint", "accent")
		part:SetAttribute("BaseColor", def.accent)
		part:SetAttribute("BaseMaterial", "SmoothPlastic")
	elseif role == "Glass" then
		part.Color = MeshCar.GLASS_COLOR
		part.Material = Enum.Material.Glass
		part.Transparency = MeshCar.GLASS_TRANSPARENCY
		part.Reflectance = 0.1
		part:SetAttribute("Paint", "glass")
	elseif role == "LightsFront" or role == "LightsRear" then
		part.Material = Enum.Material.SmoothPlastic
		part.Color = Color3.new(1, 1, 1)
		part:SetAttribute("Lens", if role == "LightsFront" then "front" else "rear")
	elseif role == "SirenRed" or role == "SirenBlue" then
		local red = role == "SirenRed"
		if MeshCar.isPolice(def) then
			part.Material = Enum.Material.Neon
			part.Color = if red then MeshCar.SIREN_RED else MeshCar.SIREN_BLUE
		else
			part.Material = Enum.Material.SmoothPlastic
			part.Color = if red then MeshCar.SIREN_DARK_RED else MeshCar.SIREN_DARK_BLUE
			part.Transparency = 0.15
		end
	elseif role == "Sign" then
		part.Material = Enum.Material.SmoothPlastic
		part.Color = Color3.new(1, 1, 1)
	end
end

local RENAME = { Sign = "TaxiSign" } :: { [string]: string }

-- Mount the template's MeshParts, wheels, lights and (unless display) seat + bump stops onto `chassis`, with the
-- built pose placed at world CFrame `ground`. Existing wheel attachments / seat / bump stops are moved, not duplicated.
local function mount(
	model: Model,
	chassis: BasePart,
	def: CarDef,
	spec: Spec,
	template: Model,
	ground: CFrame,
	L: Layout,
	forDisplay: boolean
)
	local origin = ground * CFrame.new(L.chassisCenter) -- = chassis frame in the built pose
	local function toChassis(builtPos: Vector3): Vector3
		return origin:PointToObjectSpace(ground:PointToWorldSpace(builtPos))
	end
	-- physics wheel attachments (main four)
	for _, w in L.wheels do
		if w.main then
			local att = chassis:FindFirstChild("Wheel" .. w.key)
			if not (att and att:IsA("Attachment")) then
				local a = Instance.new("Attachment")
				a.Name = "Wheel" .. w.key
				a.Parent = chassis
				att = a
			end
			local pos = toChassis(w.hub)
			local a = att :: Attachment
			-- set both: identical in Roblox; the Lune harness stores them independently
			a.CFrame = CFrame.new(pos)
			a.Position = pos
		end
	end
	-- mesh parts
	local parts: { BasePart } = {}
	for _, src in template:GetChildren() do
		if src:IsA("BasePart") then
			table.insert(parts, src)
		end
	end
	table.sort(parts, function(a, b)
		return a.Name < b.Name
	end)
	for _, src in parts do
		local part = src:Clone()
		local role = src.Name
		part.CFrame = ground * src.CFrame
		quiet(part)
		local wheelKey = string.match(role, "^Wheel(%u%u%d?)$")
		if wheelKey then
			part.Name = "Wheel_" .. wheelKey
			part:SetAttribute("WheelKey", wheelKey)
			part.Parent = model
			local old = chassis:FindFirstChild("WheelWeld_" .. wheelKey)
			if old then
				old:Destroy()
			end
			local weld = Instance.new("Weld")
			weld.Name = "WheelWeld_" .. wheelKey
			weld.Part0 = chassis
			weld.Part1 = part
			weld.C0 = chassis.CFrame:ToObjectSpace(part.CFrame)
			weld.C1 = CFrame.new()
			weld.Parent = chassis
		else
			dressPart(part, role, def, spec)
			part.Name = RENAME[role] or role
			part.Parent = model
			weldConstraint(chassis, part)
		end
	end
	-- light anchors (invisible; v1 names)
	for i, p in spec.lightsFront do
		local head = anchorPart("Headlight", V(0.8, 0.5, 0.2), ground * CFrame.new(p), model)
		weldConstraint(chassis, head)
		if i <= 2 then
			local beam = Instance.new("SpotLight")
			beam.Name = "Beam"
			beam.Face = Enum.NormalId.Front
			beam.Angle = 60
			beam.Range = 45
			beam.Brightness = 3
			beam.Shadows = false
			beam.Color = Color3.fromRGB(255, 244, 222)
			beam.Enabled = false
			beam.Parent = head
		end
	end
	for i, p in spec.lightsRear do
		local tail = anchorPart("Taillight", V(0.8, 0.5, 0.2), ground * CFrame.new(p), model)
		weldConstraint(chassis, tail)
		if i == 1 then
			local brake = Instance.new("PointLight")
			brake.Name = "BrakeGlow"
			brake.Color = Color3.fromRGB(255, 30, 20)
			brake.Range = 9
			brake.Brightness = 2.5
			brake.Shadows = false
			brake.Enabled = false
			brake.Parent = tail
			local rev = Instance.new("PointLight")
			rev.Name = "ReverseGlow"
			rev.Color = Color3.fromRGB(255, 250, 240)
			rev.Range = 10
			rev.Brightness = 2
			rev.Shadows = false
			rev.Enabled = false
			rev.Parent = tail
		end
	end
	if forDisplay then
		return
	end
	-- driver seat
	local seatCF = ground * L.seatCFrame
	local existing = model:FindFirstChild("DriverSeat")
	if existing and existing:IsA("VehicleSeat") then
		local okOcc, occupant = pcall(function()
			return existing.Occupant
		end)
		if not (okOcc and occupant ~= nil) then
			unweld(existing)
			existing.CFrame = seatCF
			weldConstraint(chassis, existing)
		end
	else
		local seat = Instance.new("VehicleSeat")
		seat.Name = "DriverSeat"
		seat.Size = V(2, 0.3, 2)
		seat.CFrame = seatCF
		seat.Transparency = 1
		quiet(seat)
		seat.CastShadow = false
		seat.Disabled = true
		seat.MaxSpeed = 0
		seat.Torque = 0
		seat.TurnSpeed = 0
		seat.HeadsUpDisplay = false
		seat.TopSurface = Enum.SurfaceType.Smooth
		seat.BottomSurface = Enum.SurfaceType.Smooth
		seat.Parent = model
		weldConstraint(chassis, seat)
	end
	-- bump stops under the axles
	local stops: { BasePart } = {}
	for _, c in model:GetChildren() do
		if c.Name == "BumpStop" and c:IsA("BasePart") then
			table.insert(stops, c)
		end
	end
	for i, z in L.axleZ do
		local cf = ground * CFrame.new(0, MeshCar.BUMPSTOP_CLEARANCE + MeshCar.BUMPSTOP_SIZE / 2, z)
		local stop = stops[i]
		if stop then
			unweld(stop)
			stop.CFrame = cf
		else
			local s = Instance.new("Part")
			s.Name = "BumpStop"
			s.Shape = Enum.PartType.Ball
			s.Size = V(MeshCar.BUMPSTOP_SIZE, MeshCar.BUMPSTOP_SIZE, MeshCar.BUMPSTOP_SIZE)
			s.CFrame = cf
			s.Transparency = 1
			s.Anchored = false
			s.CanCollide = true
			s.CanQuery = false
			s.CanTouch = false
			s.Massless = true
			s.CastShadow = false
			s.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0, 1, 1)
			s.Parent = model
			stop = s
		end
		weldConstraint(chassis, stop :: BasePart)
	end
end

local function setAttributes(model: Model, def: CarDef, spec: Spec, L: Layout)
	model:SetAttribute("RideHeight", L.chassisCenter.Y)
	model:SetAttribute("WheelRadius", spec.wheelRadius)
	model:SetAttribute("Length", spec.length)
	model:SetAttribute("Width", spec.width)
	model:SetAttribute("Height", spec.height)
	model:SetAttribute("BodyCenter", V(L.bodyCenter.X - L.chassisCenter.X, 0, L.bodyCenter.Z - L.chassisCenter.Z))
	model:SetAttribute("Style", def.style)
	model:SetAttribute("CarId", def.id)
	model:SetAttribute("Vehicle", spec.id)
	model:SetAttribute("Brand", spec.brand)
	model:SetAttribute("MeshCar", true)
	model:SetAttribute(MeshCar.PENDING_ATTR, nil)
	local v = model:GetAttribute("RigVersion")
	model:SetAttribute("RigVersion", (if typeof(v) == "number" then v else 0) + 1)
end

local function setupChassis(chassis: Part, L: Layout)
	chassis.Size = L.chassisSize
	chassis.Transparency = 1
	chassis.CanCollide = true
	chassis.CanQuery = true
	chassis.CanTouch = true
	chassis.Massless = false
	chassis.CastShadow = false
	chassis.TopSurface = Enum.SurfaceType.Smooth
	chassis.BottomSurface = Enum.SurfaceType.Smooth
	chassis.CustomPhysicalProperties = PhysicalProperties.new(L.density, 0.3, 0, 1, 1)
end

-- Build a fresh v2 car (see the contract at the top). Mutation / client tag are CarBuilder's job.
function MeshCar.build(def: CarDef, spec: Spec, template: Model, forDisplay: boolean): Model
	local L = MeshCar.layout(spec)
	local model = Instance.new("Model")
	model.Name = def.id
	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	setupChassis(chassis, L)
	chassis.Anchored = false
	chassis.CFrame = CFrame.new(L.chassisCenter)
	chassis.Parent = model
	model.PrimaryPart = chassis
	mount(model, chassis, def, spec, template, CFrame.new(), L, forDisplay)
	setAttributes(model, def, spec, L)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	return model
end

-- Late arrival: turn a procedural (MeshPending) car into the mesh rig in place. Returns true on success.
function MeshCar.convert(model: Model, def: CarDef, spec: Spec, template: Model): boolean
	local chassisInst = model.PrimaryPart or model:FindFirstChild("Chassis")
	if not chassisInst or not chassisInst:IsA("Part") then
		return false
	end
	local chassis = chassisInst :: Part
	local L = MeshCar.layout(spec)
	local oldRide = model:GetAttribute("RideHeight")
	local forDisplay = model:FindFirstChild("DriverSeat") == nil
	-- procedural visuals out (welds / attachments / prompts on the Chassis and seat stay)
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and not KEEP[child.Name] and child:GetAttribute(MeshCar.PROC_ATTR) == true then
			child:Destroy()
		end
	end
	for _, c in chassis:GetChildren() do
		if c:IsA("JointInstance") and string.match(c.Name, "^WheelWeld_") then
			c:Destroy()
		end
	end
	local wasAnchored = chassis.Anchored
	setupChassis(chassis, L)
	-- the Chassis keeps its CFrame: the built pose hangs off it
	local ground = chassis.CFrame * CFrame.new(-L.chassisCenter)
	mount(model, chassis, def, spec, template, ground, L, forDisplay)
	setAttributes(model, def, spec, L)
	-- an anchored car (parked / display) keeps its tyres on the ground it stood on
	if wasAnchored and typeof(oldRide) == "number" then
		model:PivotTo(chassis.CFrame * CFrame.new(0, L.chassisCenter.Y - oldRide, 0))
	end
	return true
end

return MeshCar
