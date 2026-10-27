--!strict
-- WheelAnimator: purely cosmetic, client-local car animation.
--   * "Vehicle" cars within RANGE studs of the camera: wheels spin by forward speed / WheelRadius, front wheels steer
--     (estimated from yaw rate + speed with the bicycle model, max 30°), suspension bob from a downward raycast.
--     Edits the CarBuilder welds "WheelWeld_XX" (Weld.C0, original C0/C1 cached, also stored in the weld attribute
--     HC_BaseC0 so a re-tracked car never bakes in an animated pose).
--   * The car the local player drives is posed from VehicleClient.getController() instead (exact suspension offsets
--     and steer input, no extra raycasts); VehicleClient.positionsWheels=false hands that job to this module.
--   * Mutation "Rainbow": hue-cycles Paint="primary" parts on Vehicle / DisplayCar / DealerCar models (the hero
--     shell's parts instead on HeroMesh cars).
--   * HeroMesh cars (CarBuilder.applyShell: wheels are baked into the mesh, the procedural wheels are invisible) skip
--     the wheel spin / steer / bob work entirely; rainbow, sparkles and observer drift FX still run.
--   * Mutation "Diamond"/"Galaxy": the server-built CarBuilder.SPARKLES_NAME emitter only emits within SPARKLE_RANGE.
--   * Other players' / AI cars that drift (sideways slip from the replicated chassis velocity, same test as the
--     driving controller) get local flipbook tire smoke (VFXLibrary "TireSmoke" streams, quality-scaled + budgeted),
--     skid-mark Trails from the rear wheels + a SoundController screech loop; the driver's own FX are VehicleClient's.
--     While they drift, a contact ray per rear tyre (every other update) keeps each skid mark on the road and turns
--     that tyre's smoke + mark off when it is in the air.
--   * Night (Lighting attribute IsNight): the HEADLIGHT_CARS nearest driven / traffic / police cars within
--     HEADLIGHT_RANGE get volumetric headlight cones (VFXLibrary "HeadlightCone" Beams, built once per car, toggled
--     every rebuild). Procedural cars: from their Headlight parts. HeroMesh cars (procedural lamps hidden in place):
--     from the shell's "HeadlightL"/"HeadlightR" attachments when it has them, else at the procedural lamps' x/y on
--     the shell's front face. Parked / display cars stay dark. Beams only: no extra lights.
--   * Budget: the HOT_COUNT nearest on-screen cars update every frame, the rest round-robin COLD_PER_FRAME per frame.
--     Cars behind the camera are skipped; only Vehicles and rainbow cars take a slot; bob rays are cast every other
--     update (every TRAFFIC_BOB_EVERY for Traffic, which holds a fixed height); unchanged wheel poses are not
--     rewritten. Phones (touch, no keyboard/mouse) use the smaller LOW_TIER budget.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VehicleController = require(Shared.Vehicle.VehicleController)
local VFXLibrary = require(script.Parent:WaitForChild("VFXLibrary"))

local VMath = VehicleController.math
local WHEEL_NAMES = VehicleController.WHEEL_NAMES

local WheelAnimator = {}

WheelAnimator.RANGE = 250
WheelAnimator.HOT_COUNT = 25
WheelAnimator.COLD_PER_FRAME = 6
WheelAnimator.BOB_RANGE = 140 -- raycast suspension only this close; farther wheels ease back to the built pose
-- Phones (PERF-07): fewer, closer cars; bob rays only where a 0.3-stud gap is visible at all.
WheelAnimator.LOW_TIER = { RANGE = 160, HOT_COUNT = 10, COLD_PER_FRAME = 4, BOB_RANGE = 60, HEADLIGHT_CARS = 4 }
WheelAnimator.HEADLIGHT_CARS = 8 -- nearest moving cars with headlight cones at night
WheelAnimator.HEADLIGHT_RANGE = 180
WheelAnimator.SPARKLE_RANGE = 120
WheelAnimator.SPARKLES_NAME = "MutationSparkles" -- = CarBuilder.SPARKLES_NAME (asserted in tests)
WheelAnimator.SHELL_NAME = "HeroShell" -- = CarBuilder.SHELL_NAME (asserted in tests)

local REBUILD_INTERVAL = 0.25 -- seconds between nearest-car list rebuilds
local FILTER_INTERVAL = 2
local MAX_STEER = math.rad(30)
local STEER_RESPONSE = 10
local BOB_UP = 1 -- ray starts this far above the hub
local BOB_RESPONSE = 18
local MAX_DROOP = 0.7
local MAX_BUMP = 0.6
local RAINBOW_SPEED = 0.35 -- hue cycles per second
local RAINBOW_SPREAD = 0.07 -- hue offset between parts -> a flowing rainbow
local MAX_BUILD_ATTEMPTS = 3
local BASE_C0_ATTRIBUTE = "HC_BaseC0"
local TAGS = { "Vehicle", "DisplayCar", "DealerCar" }
local CULL_BEHIND = 12 -- studs behind the camera plane before a car stops animating (half a long car + margin)
local BOB_EVERY = 2 -- cast the bob rays every Nth update of a rig (the eased offset hides it)
local TRAFFIC_BOB_EVERY = 8 -- traffic floats at a fixed height on its AlignPosition: its ground gap barely changes
local POSE_EPS = 1e-4 -- radians / studs: smaller pose changes skip the Weld.C0 write
local SPARKLE_RETRY = 2 -- seconds before searching a Diamond/Galaxy model for its emitter again
local DRIFT_FX_RANGE = 150 -- observers' drift smoke / screech only this close
local DRIFT_MAX_VERTICAL = 10 -- studs/s: faster vertical motion = airborne (no smoke)
local CONTACT_EVERY = 2 -- observers' skid-contact rays every Nth update while drifting
local CONTACT_REACH = 1.2 -- studs below the tyre bottom a contact ray still counts as ground (droop)
local SKID_LIFT = 0.04 -- studs the skid trail floats over the road (no z-fighting)
local HERO_LAMP_INSET = 0.15 -- studs behind the shell's front face a fallback hero cone starts

type WheelRig = {
	index: number,
	weld: any, -- Weld / Motor6D (JointInstance with C0/C1)
	basePos: Vector3,
	baseRot: CFrame,
	c1: CFrame,
	front: boolean,
	rear: boolean,
	spinSign: number,
	offset: number,
	target: number, -- last bob-ray target (reused between casts)
	written: number, -- offset of the last C0 write (NaN = never written)
}

type DriftWheel = {
	hub: Vector3, -- built hub position (chassis space)
	smoke: VFXLibrary.Stream?,
	skid: VFXLibrary.TrailRig?,
	grounded: boolean, -- last contact ray found road under this tyre
	lit: boolean, -- smoke + mark currently on
}

type DriftFx = {
	wheels: { DriftWheel },
	screech: Sound?,
	on: boolean,
	tick: number,
}

type Rig = {
	model: Model,
	isVehicle: boolean,
	chassis: BasePart?,
	wheels: { WheelRig },
	built: boolean,
	buildAttempts: number,
	nextBuildAt: number,
	radius: number,
	wheelbase: number,
	spin: number,
	rearSpin: number,
	steer: number,
	settled: boolean,
	rainbow: { BasePart }?,
	rainbowHero: boolean, -- rainbow holds shell parts (HeroMesh) rather than Paint="primary" parts
	heroMesh: boolean, -- HeroMesh attribute (refreshed in rebuildNear): no wheel posing
	phase: number,
	lastT: number,
	dist: number,
	pos: Vector3, -- chassis position at the last rebuildNear (fallback for the on-screen test)
	traffic: boolean, -- Kind == "Traffic" (refreshed in rebuildNear)
	bobTick: number,
	wSpin: number, -- spin / rearSpin / steer of the last C0 write (NaN = never written)
	wRearSpin: number,
	wSteer: number,
	sparkles: ParticleEmitter?,
	sparkleSearchAt: number,
	fx: DriftFx?,
	fxFrame: number, -- frame in which the car was last seen drifting
	cones: { VFXLibrary.BeamRig }?, -- night headlight cones (built on first use)
	conesOn: boolean,
	conesHero: boolean, -- the cones were built for a HeroMesh car (rebuilt when a shell arrives / leaves)
}

local rigs: { [Model]: Rig } = {}
local nearList: { Rig } = {}
local fxActive: { [Rig]: boolean } = {}
local coldCursor = 0
local frameId = 0
local rebuildTimer = math.huge
local filterTimer = math.huge
local rayParams: RaycastParams? = nil -- created in start() (keeps the module requirable headlessly)
local filterList: { Instance } = {}
local vehicleClient: any = nil
local soundController: any = nil
local NAN = 0 / 0

-- Pure pose math (unit-tested): the weld C0 that puts a wheel (built at basePos/baseRot in chassis space, weld C1 = c1)
-- `offset` studs up along chassis Y, steered `steer` rad around chassis Y (+ = left) and spun `spin` rad about its axle.
function WheelAnimator.wheelC0(
	basePos: Vector3,
	baseRot: CFrame,
	c1: CFrame,
	offset: number,
	steer: number,
	spin: number
): CFrame
	return CFrame.new(basePos.X, basePos.Y + offset, basePos.Z)
		* CFrame.Angles(0, steer, 0)
		* baseRot
		* CFrame.Angles(spin, 0, 0)
		* c1
end

-- Spin direction for a wheel whose part frame (in chassis space) has rotation baseRot: rolling forward (toward -Z)
-- is a negative rotation about chassis +X, so flip when the cylinder axis points along -X.
function WheelAnimator.spinSign(baseRot: CFrame): number
	return if baseRot.RightVector.X < -0.5 then 1 else -1
end

-- Phone tier: a touch screen with neither keyboard nor mouse.
function WheelAnimator.isLowTier(touch: boolean, keyboard: boolean, mouse: boolean): boolean
	return touch and not keyboard and not mouse
end

-- True when `pos` is more than `margin` studs behind the camera plane (can't be on screen).
function WheelAnimator.behindCamera(pos: Vector3, camPos: Vector3, look: Vector3, margin: number): boolean
	return (pos - camPos):Dot(look) < -margin
end

-- F10: an anchored car first posed from beyond bobRange settled with the built pose (no ray); re-pose it with the
-- bob ray once the camera comes into range.
function WheelAnimator.enteredBobRange(oldDist: number, newDist: number, bobRange: number): boolean
	return oldDist > bobRange and newDist <= bobRange
end

-- Observer drift test from replicated physics: forward/sideways speed in the car's frame, "grounded" = upright and
-- not flying up/down. Same thresholds as the driving controller (VehicleController.math.isDrifting).
function WheelAnimator.observedDrift(cf: CFrame, vel: Vector3): boolean
	local grounded = cf.UpVector.Y > 0.6 and math.abs(vel.Y) < DRIFT_MAX_VERTICAL
	return VMath.isDrifting(vel:Dot(cf.LookVector), vel:Dot(cf.RightVector), grounded)
end

-- Does a car drive with its lights on at night? Traffic / police always, any car with a driver; parked, loot left
-- behind and showroom cars stay dark.
function WheelAnimator.wantsHeadlights(kind: any, driverUserId: any): boolean
	if kind == "Traffic" or kind == "Police" then
		return true
	end
	return typeof(driverUserId) == "number" and driverUserId > 0
end

-- Night headlight picks: the first `maxCars` entries of a distance-sorted list (entries have .dist) within `range`
-- that `wants` lights; none by day. Returns the picked entries as a set.
function WheelAnimator.pickHeadlights(
	list: { any },
	night: boolean,
	maxCars: number,
	range: number,
	wants: (any) -> boolean
): { [any]: boolean }
	local picked: { [any]: boolean } = {}
	local left = if night then maxCars else 0
	for _, item in list do
		if left <= 0 or item.dist > range then
			break
		end
		if wants(item) then
			picked[item] = true
			left -= 1
		end
	end
	return picked
end

-- Cone switches after a pick: lit entries no longer wanted (or gone: alive false) go dark, wanted ones light up.
-- Returns (turnOff, turnOn) lists.
function WheelAnimator.headlightChanges(
	lit: { [any]: boolean },
	want: { [any]: boolean },
	alive: (any) -> boolean
): ({ any }, { any })
	local off, on = {}, {}
	for item in lit do
		if not want[item] or not alive(item) then
			table.insert(off, item)
		end
	end
	for item in want do
		if not lit[item] then
			table.insert(on, item)
		end
	end
	return off, on
end

-- Frontmost (minimum) Z, in chassis space, of a set of parts' boxes: the hero shell's front face.
function WheelAnimator.frontZ(parts: { BasePart }, chassisCF: CFrame): number?
	local best: number? = nil
	for _, p in parts do
		local rel = chassisCF:ToObjectSpace(p.CFrame)
		local h = p.Size / 2
		local reach = math.abs(rel.XVector.Z) * h.X + math.abs(rel.YVector.Z) * h.Y + math.abs(rel.ZVector.Z) * h.Z
		local z = rel.Position.Z - reach
		if best == nil or z < best then
			best = z
		end
	end
	return best
end

-- Fallback cone origin on a HeroMesh car without lamp attachments: the hidden procedural lamp's x / y, moved onto
-- the shell's front face (frontZ, chassis space; nil = keep the lamp's own z).
function WheelAnimator.heroConeOrigin(lamp: Vector3, frontZ: number?): Vector3
	if frontZ == nil then
		return lamp
	end
	return Vector3.new(lamp.X, lamp.Y, frontZ + HERO_LAMP_INSET)
end

-- Skid-mark height (chassis space) from a contact ray: the hit point's height in the car's frame + a hair.
function WheelAnimator.skidY(contactLocalY: number): number
	return contactLocalY + SKID_LIFT
end

local function byDistance(a: Rig, b: Rig): boolean
	return a.dist < b.dist
end

local function newRig(model: Model): Rig
	return {
		model = model,
		isVehicle = CollectionService:HasTag(model, "Vehicle"),
		chassis = nil,
		wheels = {},
		built = false,
		buildAttempts = 0,
		nextBuildAt = 0,
		radius = 1.2,
		wheelbase = 8,
		spin = 0,
		rearSpin = 0,
		steer = 0,
		settled = false,
		rainbow = nil,
		rainbowHero = false,
		heroMesh = model:GetAttribute("HeroMesh") == true,
		phase = math.random(),
		lastT = os.clock(),
		dist = math.huge,
		pos = Vector3.zero,
		traffic = false,
		bobTick = 0,
		wSpin = NAN,
		wRearSpin = NAN,
		wSteer = NAN,
		sparkles = nil,
		sparkleSearchAt = 0,
		fx = nil,
		fxFrame = 0,
		cones = nil,
		conesOn = false,
		conesHero = false,
	}
end

local function buildRig(rig: Rig, now: number)
	rig.buildAttempts += 1
	rig.nextBuildAt = now + 2
	local model = rig.model
	local chassis = model.PrimaryPart or model:FindFirstChild("Chassis")
	if not (chassis and chassis:IsA("BasePart")) then
		return
	end
	rig.chassis = chassis
	local r = model:GetAttribute("WheelRadius")
	rig.radius = if typeof(r) == "number" and r > 0.1 then r else 1.2

	local wheels: { WheelRig } = {}
	local frontZ, rearZ = nil :: number?, nil :: number?
	for i, name in WHEEL_NAMES do
		local weld = model:FindFirstChild("WheelWeld_" .. name, true)
		if weld and weld:IsA("JointInstance") then
			local joint = weld :: any
			local stored = joint:GetAttribute(BASE_C0_ATTRIBUTE)
			local c0: CFrame = if typeof(stored) == "CFrame" then stored else joint.C0
			if typeof(stored) ~= "CFrame" then
				joint:SetAttribute(BASE_C0_ATTRIBUTE, c0)
			end
			local c1: CFrame = joint.C1
			local wheelCF = c0 * c1:Inverse() -- wheel part frame in chassis space
			local front = name:sub(1, 1) == "F"
			table.insert(wheels, {
				index = i,
				weld = joint,
				basePos = wheelCF.Position,
				baseRot = wheelCF.Rotation,
				c1 = c1,
				front = front,
				rear = not front,
				spinSign = WheelAnimator.spinSign(wheelCF.Rotation),
				offset = 0,
				target = 0,
				written = NAN,
			})
			if front then
				frontZ = wheelCF.Position.Z
			else
				rearZ = wheelCF.Position.Z
			end
		end
	end
	rig.wheels = wheels
	if frontZ and rearZ then
		rig.wheelbase = math.max(math.abs(rearZ - frontZ), 2)
	else
		local length = model:GetAttribute("Length")
		rig.wheelbase = if typeof(length) == "number" then math.max(length * 0.6, 2) else 8
	end
	rig.built = #wheels > 0 or rig.buildAttempts >= MAX_BUILD_ATTEMPTS
end

-- The parts a Rainbow car cycles: its hero shell's parts on a HeroMesh car, else the Paint="primary" parts.
function WheelAnimator.rainbowParts(model: Model): { BasePart }
	local parts: { BasePart } = {}
	local shell = if model:GetAttribute("HeroMesh") == true then model:FindFirstChild(WheelAnimator.SHELL_NAME) else nil
	if shell then
		for _, d in shell:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(parts, d)
			end
		end
		return parts
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("Paint") == "primary" then
			table.insert(parts, d)
		end
	end
	return parts
end

local function refreshRainbow(rig: Rig)
	local isRainbow = rig.model:GetAttribute("Mutation") == "Rainbow"
	-- a shell that arrived late (AssetLibrary re-skin) replaces the cycled parts
	if isRainbow and (not rig.rainbow or rig.rainbowHero ~= rig.heroMesh) then
		rig.rainbow = WheelAnimator.rainbowParts(rig.model)
		rig.rainbowHero = rig.heroMesh
	elseif not isRainbow and rig.rainbow then
		rig.rainbow = nil
	end
end

local function refreshFilter()
	local params = rayParams
	if not params then
		return
	end
	table.clear(filterList)
	for _, name in { "Vehicles", "Effects", "Dealership" } do
		local folder = Workspace:FindFirstChild(name)
		if folder then
			table.insert(filterList, folder)
		end
	end
	local cam = Workspace.CurrentCamera
	if cam then
		table.insert(filterList, cam)
	end
	for _, plr in Players:GetPlayers() do
		if plr.Character then
			table.insert(filterList, plr.Character)
		end
	end
	params.FilterDescendantsInstances = filterList
end

local function track(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	local rig = rigs[inst]
	if rig then
		rig.isVehicle = CollectionService:HasTag(inst, "Vehicle")
		return
	end
	rigs[inst] = newRig(inst)
	rebuildTimer = math.huge -- pick it up on the next frame
end

local function untrack(inst: Instance)
	if not inst:IsA("Model") then
		return
	end
	for _, tag in TAGS do
		if CollectionService:HasTag(inst, tag) then
			track(inst)
			return
		end
	end
	rigs[inst] = nil
end

-- PERF-13: Diamond/Galaxy sparkles (server-built, Enabled by default) emit only near the camera. The emitter is
-- re-found when the server rebuilds it (CarBuilder.repaint / applyMutation replace it).
local function refreshSparkles(rig: Rig, now: number)
	local mutation = rig.model:GetAttribute("Mutation")
	if mutation ~= "Diamond" and mutation ~= "Galaxy" then
		rig.sparkles = nil
		return
	end
	local pe = rig.sparkles
	if (pe == nil or pe.Parent == nil) and now >= rig.sparkleSearchAt then
		local found = rig.model:FindFirstChild(WheelAnimator.SPARKLES_NAME, true)
		if found and found:IsA("ParticleEmitter") then
			pe = found
		else
			pe = nil
		end
		rig.sparkles = pe
		if not pe then
			rig.sparkleSearchAt = now + SPARKLE_RETRY
		end
	end
	if pe and pe.Parent then
		local want = rig.dist <= WheelAnimator.SPARKLE_RANGE
		if pe.Enabled ~= want then
			pe.Enabled = want
		end
	end
end

----------------------------------------------------------------------------------------------------------------------
-- Night headlight cones
----------------------------------------------------------------------------------------------------------------------
local litRigs: { [Rig]: boolean } = {}

local function addCone(cones: { VFXLibrary.BeamRig }, parent: BasePart, origin: Vector3)
	local ok, beam = pcall(VFXLibrary.beam, "HeadlightCone", parent, origin, Vector3.new(0, 0, -1))
	if ok and beam then
		table.insert(cones, beam)
	end
end

-- Hero shell lamps: attachments "HeadlightL" / "HeadlightR" anywhere in the shell (chassis-space positions).
local function shellLamps(shell: Instance, chassis: BasePart): { Vector3 }
	local out: { Vector3 } = {}
	for _, name in { "HeadlightL", "HeadlightR" } do
		local att = shell:FindFirstChild(name, true)
		if att and att:IsA("Attachment") then
			table.insert(out, chassis.CFrame:PointToObjectSpace(att.WorldPosition))
		end
	end
	return out
end

local function buildCones(rig: Rig)
	local cones: { VFXLibrary.BeamRig } = {}
	rig.cones = cones
	rig.conesHero = rig.heroMesh
	rig.conesOn = false -- fresh beams start disabled
	local model = rig.model
	local chassis = rig.chassis or model.PrimaryPart
	local shell = if rig.heroMesh then model:FindFirstChild(WheelAnimator.SHELL_NAME) else nil
	if shell and chassis then
		local lamps = shellLamps(shell, chassis)
		if #lamps > 0 then
			for _, origin in lamps do
				addCone(cones, chassis, origin)
			end
			return
		end
	end
	local front: number? = nil
	if shell and chassis then
		local parts: { BasePart } = {}
		for _, d in shell:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(parts, d)
			end
		end
		front = WheelAnimator.frontZ(parts, chassis.CFrame)
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "Headlight" then
			-- Headlight parts are never rotated: their -Z is the car's front
			local face = Vector3.new(0, 0, -d.Size.Z / 2)
			if front and chassis then
				-- hidden procedural lamp: start the cone on the shell's front face instead
				local lamp = chassis.CFrame:PointToObjectSpace(d.CFrame:PointToWorldSpace(face))
				addCone(cones, chassis, WheelAnimator.heroConeOrigin(lamp, front))
			else
				addCone(cones, d, face)
			end
			if #cones >= 2 then
				break
			end
		end
	end
end

local function destroyCones(rig: Rig)
	for _, c in rig.cones or {} do
		c.beam:Destroy()
		c.a0:Destroy()
		c.a1:Destroy()
	end
	rig.cones = nil
	rig.conesOn = false
end

local function setCones(rig: Rig, on: boolean)
	if on and rig.cones and rig.conesHero ~= rig.heroMesh then
		destroyCones(rig) -- a shell arrived (or left) since the cones were built
	end
	if on and not rig.cones then
		buildCones(rig)
	end
	if rig.conesOn == on then
		return
	end
	rig.conesOn = on
	litRigs[rig] = if on then true else nil
	for _, c in rig.cones or {} do
		if c.beam.Parent then
			c.beam.Enabled = on
		end
	end
end

local function rigWantsLights(rig: Rig): boolean
	local model = rig.model
	return rig.isVehicle
		and WheelAnimator.wantsHeadlights(model:GetAttribute("Kind"), model:GetAttribute("DriverUserId"))
end

local function rigAlive(rig: Rig): boolean
	return rig.model.Parent ~= nil
end

-- After each nearest-list rebuild: cones on for the nearest qualifying cars at night, off everywhere else.
local function updateHeadlights()
	local night = Lighting:GetAttribute("IsNight") == true
	local want = WheelAnimator.pickHeadlights(
		nearList,
		night,
		WheelAnimator.HEADLIGHT_CARS,
		WheelAnimator.HEADLIGHT_RANGE,
		rigWantsLights
	)
	local off, on = WheelAnimator.headlightChanges(litRigs, want, rigAlive)
	for _, rig in off do
		setCones(rig, false)
	end
	for _, rig in on do
		setCones(rig, true)
	end
	for rig in want do
		if rig.conesHero ~= rig.heroMesh then
			setCones(rig, true) -- re-skinned while lit: rebuild on the new body
		end
	end
end

local function rebuildNear(camPos: Vector3, now: number)
	table.clear(nearList)
	local bobRange = WheelAnimator.BOB_RANGE
	for model, rig in rigs do
		if model.Parent == nil then
			rigs[model] = nil
			continue
		end
		local chassis = rig.chassis
		if not chassis then
			local primary = model.PrimaryPart
			if primary then
				rig.chassis = primary
				chassis = primary
			end
		end
		local pos = if chassis and chassis.Parent then chassis.Position else model:GetPivot().Position
		local oldDist = rig.dist
		rig.pos = pos
		rig.heroMesh = model:GetAttribute("HeroMesh") == true
		rig.dist = (pos - camPos).Magnitude
		if WheelAnimator.enteredBobRange(oldDist, rig.dist, bobRange) then
			rig.settled = false
		end
		refreshSparkles(rig, now)
		if rig.dist <= WheelAnimator.RANGE then
			rig.isVehicle = CollectionService:HasTag(model, "Vehicle")
			rig.traffic = model:GetAttribute("Kind") == "Traffic"
			refreshRainbow(rig)
			-- only cars with something to animate take a slot (plain display / dealer cars have none)
			if rig.isVehicle or rig.rainbow then
				table.insert(nearList, rig)
			end
		end
	end
	table.sort(nearList, byDistance)
	updateHeadlights()
end

local function applyRainbow(rig: Rig, now: number)
	local parts = rig.rainbow
	if not parts then
		return
	end
	local base = now * RAINBOW_SPEED + rig.phase
	for i, part in parts do
		part.Color = Color3.fromHSV((base + i * RAINBOW_SPREAD) % 1, 0.75, 1)
	end
end

----------------------------------------------------------------------------------------------------------------------
-- Observers' drift FX (F11): other cars' smoke + screech, derived from replicated velocity
----------------------------------------------------------------------------------------------------------------------
local OBSERVER_SMOKE: VFXLibrary.StreamOpts = { rateScale = 0.8 }

local function buildDriftFx(rig: Rig): DriftFx?
	local chassis = rig.chassis
	if not chassis then
		return nil
	end
	local fx: DriftFx = { wheels = {}, screech = nil, on = false, tick = 0 }
	-- marks start at the resting contact patch (the driving controller rides RIDE_LIFT above the built pose)
	local rest = -rig.radius - VehicleController.RIDE_LIFT + SKID_LIFT
	for _, w in rig.wheels do
		if w.rear then
			local att = Instance.new("Attachment")
			att.Name = "HC_ObserverSmoke"
			att.Position = w.basePos - Vector3.new(0, rig.radius * 0.85, 0)
			att.Parent = chassis
			table.insert(fx.wheels, {
				hub = w.basePos,
				smoke = VFXLibrary.stream("TireSmoke", att, OBSERVER_SMOKE),
				skid = VFXLibrary.trail("SkidMark", chassis, w.basePos + Vector3.new(0, rest, 0)),
				grounded = true,
				lit = false,
			})
		end
	end
	return fx
end

-- One tyre's smoke + skid mark on/off (free when unchanged).
local function setWheelFx(w: DriftWheel, on: boolean)
	if w.lit == on then
		return
	end
	w.lit = on
	if w.smoke then
		VFXLibrary.setStream(w.smoke, on)
	end
	local skid = w.skid
	if skid and skid.trail.Parent then
		skid.trail.Enabled = on
	end
end

-- While drifting: a contact ray per rear tyre (every CONTACT_EVERY updates; `now` forces one) keeps its skid mark on
-- the road through suspension travel / body roll and switches a tyre in the air off.
local function updateDriftContact(rig: Rig, cf: CFrame, now: boolean)
	local fx = rig.fx
	local params = rayParams
	if not fx or not fx.on then
		return
	end
	fx.tick += 1
	if params and (now or fx.tick % CONTACT_EVERY == 1) then
		local up = cf.UpVector
		local reach = BOB_UP + rig.radius + CONTACT_REACH
		for _, w in fx.wheels do
			local hub = cf * w.hub
			local hit = Workspace:Raycast(hub + up * BOB_UP, up * -reach, params)
			w.grounded = hit ~= nil
			if hit and w.skid then
				VFXLibrary.setTrailHeight(w.skid, WheelAnimator.skidY(cf:PointToObjectSpace(hit.Position).Y))
			end
		end
	end
	for _, w in fx.wheels do
		setWheelFx(w, w.grounded)
	end
end

local function setDriftFx(rig: Rig, on: boolean)
	local fx = rig.fx
	if on and not fx then
		fx = buildDriftFx(rig)
		rig.fx = fx
	end
	if not fx or fx.on == on then
		return
	end
	fx.on = on
	for _, w in fx.wheels do
		w.grounded = true
		setWheelFx(w, on)
	end
	local sc = soundController
	if on then
		fxActive[rig] = true
		if sc and not fx.screech and rig.chassis then
			local ok, snd = pcall(sc.playLoop, "TireScreech", rig.chassis)
			fx.screech = if ok and typeof(snd) == "Instance" and snd:IsA("Sound") then snd else nil
		end
	else
		fxActive[rig] = nil
		local snd = fx.screech
		fx.screech = nil
		if snd and sc then
			pcall(sc.stopLoop, snd)
		end
	end
end

-- controller: the local VehicleController when this is the car we drive (exact data), else nil (estimate).
-- hot: updated every frame (only hot rigs may start drift FX; they are switched off when not seen for a frame).
local function animateWheels(rig: Rig, dt: number, controller: any, hot: boolean)
	local chassis = rig.chassis
	if not chassis or chassis.Parent == nil or #rig.wheels == 0 then
		return
	end
	local cf = chassis.CFrame
	local vF: number
	local steerTarget: number
	local handbrake = false
	if controller then
		vF = controller.forwardSpeed
		local speedFade = 1 - 0.5 * math.clamp(math.abs(vF) / 120, 0, 1)
		steerTarget = -controller.input.steer * MAX_STEER * speedFade
		handbrake = controller.input.handbrake == true
	else
		if chassis.Anchored then
			if rig.settled then
				return
			end
			vF = 0
			steerTarget = 0
		else
			local vel = chassis.AssemblyLinearVelocity
			vF = vel:Dot(cf.LookVector)
			if hot and rig.dist <= DRIFT_FX_RANGE and WheelAnimator.observedDrift(cf, vel) then
				rig.fxFrame = frameId
				local starting = not (rig.fx and rig.fx.on)
				setDriftFx(rig, true)
				updateDriftContact(rig, cf, starting)
			end
			local yawRate = chassis.AssemblyAngularVelocity:Dot(cf.UpVector)
			steerTarget = VMath.estimateSteerAngle(yawRate, vF, rig.wheelbase, MAX_STEER)
			if
				rig.settled
				and math.abs(vF) < 0.05
				and math.abs(steerTarget) < 1e-3
				and math.abs(rig.steer) < 1e-3
				and vel.Magnitude < 0.1
			then
				return -- parked and already posed
			end
		end
	end
	if rig.heroMesh then
		return -- wheels are baked into the hero mesh (the procedural ones are invisible): drift FX above only
	end

	rig.steer += (steerTarget - rig.steer) * math.min(1, STEER_RESPONSE * dt)
	local twoPi = 2 * math.pi
	rig.spin = (rig.spin + vF * dt / rig.radius) % twoPi
	if not handbrake then
		rig.rearSpin = (rig.rearSpin + vF * dt / rig.radius) % twoPi
	end

	local up = cf.UpVector
	local params = rayParams
	local doBob = controller == nil and params ~= nil and rig.dist <= WheelAnimator.BOB_RANGE
	local castNow = false
	if doBob then
		-- between casts the last ray target is reused (the offset eases toward it anyway)
		rig.bobTick += 1
		castNow = rig.bobTick % (if rig.traffic then TRAFFIC_BOB_EVERY else BOB_EVERY) == 1
	end
	local response = math.min(1, BOB_RESPONSE * dt)
	local moving = false
	-- not (x <= eps) is also true for NaN (never written yet)
	local poseChanged = not (math.abs(rig.spin - rig.wSpin) <= POSE_EPS)
		or not (math.abs(rig.rearSpin - rig.wRearSpin) <= POSE_EPS)
		or not (math.abs(rig.steer - rig.wSteer) <= POSE_EPS)
	for _, w in rig.wheels do
		if controller then
			local o = controller.wheelOffset and controller.wheelOffset[w.index]
			w.offset = if typeof(o) == "number" then o else 0
		else
			if not doBob then
				w.target = 0
			elseif castNow then
				local hub = cf * w.basePos
				local hit = Workspace:Raycast(hub + up * BOB_UP, up * -(BOB_UP + rig.radius + MAX_DROOP), params)
				w.target = if hit
					then math.clamp(BOB_UP - hit.Distance + rig.radius, -MAX_DROOP, MAX_BUMP)
					else -MAX_DROOP
			end
			local before = w.offset
			w.offset += (w.target - w.offset) * response
			if math.abs(w.offset - before) > 1e-3 then
				moving = true
			end
		end
		if poseChanged or not (math.abs(w.offset - w.written) <= POSE_EPS) then
			local steerA = if w.front then rig.steer else 0
			local spin = if w.rear then rig.rearSpin else rig.spin
			w.weld.C0 = WheelAnimator.wheelC0(w.basePos, w.baseRot, w.c1, w.offset, steerA, spin * w.spinSign)
			w.written = w.offset
		end
	end
	if poseChanged then
		rig.wSpin, rig.wRearSpin, rig.wSteer = rig.spin, rig.rearSpin, rig.steer
	end
	rig.settled = controller == nil and not moving and math.abs(vF) < 0.05 and math.abs(rig.steer) < 1e-3
end

local function updateRig(rig: Rig, now: number, controller: any, hot: boolean)
	local dt = math.clamp(now - rig.lastT, 0, 0.5)
	rig.lastT = now
	if rig.rainbow then
		applyRainbow(rig, now)
	end
	if not rig.isVehicle then
		return
	end
	if not rig.built then
		if now < rig.nextBuildAt then
			return
		end
		buildRig(rig, now)
		if #rig.wheels == 0 then
			return
		end
	end
	animateWheels(rig, dt, controller, hot)
end

-- A hot car with drift FX that went behind the camera: keep its (audible) screech while it still drifts.
local function keepDriftFx(rig: Rig)
	local chassis = rig.chassis
	if
		chassis
		and chassis.Parent
		and not chassis.Anchored
		and WheelAnimator.observedDrift(chassis.CFrame, chassis.AssemblyLinearVelocity)
	then
		rig.fxFrame = frameId
	end
end

local function onScreen(rig: Rig, camPos: Vector3, look: Vector3): boolean
	local chassis = rig.chassis
	local pos = if chassis and chassis.Parent then chassis.Position else rig.pos
	return not WheelAnimator.behindCamera(pos, camPos, look, CULL_BEHIND)
end

local function onPreRender(dt: number)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local now = os.clock()
	frameId += 1
	local camCF = cam.CFrame
	local camPos, look = camCF.Position, camCF.LookVector

	filterTimer += dt
	if filterTimer >= FILTER_INTERVAL then
		filterTimer = 0
		refreshFilter()
	end
	rebuildTimer += dt
	if rebuildTimer >= REBUILD_INTERVAL then
		rebuildTimer = 0
		rebuildNear(camPos, now)
	end

	-- the car we drive: always, with exact controller data
	local drivenModel: Model? = nil
	if vehicleClient then
		local okModel, model = pcall(vehicleClient.getModel)
		if okModel and typeof(model) == "Instance" and model:IsA("Model") then
			drivenModel = model
			local rig = rigs[model]
			if not rig then
				rig = newRig(model)
				rig.isVehicle = true
				rigs[model] = rig
			end
			local okController, controller = pcall(vehicleClient.getController)
			updateRig(rig, now, if okController then controller else nil, false)
		end
	end

	-- hot: the HOT_COUNT nearest cars that can be on screen (behind-camera ones don't use up the budget)
	local n = #nearList
	local budget = WheelAnimator.HOT_COUNT
	local i = 0
	while i < n and budget > 0 do
		i += 1
		local rig = nearList[i]
		if rig.model ~= drivenModel then
			if onScreen(rig, camPos, look) then
				updateRig(rig, now, nil, true)
				budget -= 1
			elseif fxActive[rig] then
				keepDriftFx(rig)
			end
		end
	end
	-- cold: round-robin through the rest
	local coldCount = n - i
	if coldCount > 0 then
		for _ = 1, math.min(WheelAnimator.COLD_PER_FRAME, coldCount) do
			coldCursor = (coldCursor % coldCount) + 1
			local rig = nearList[i + coldCursor]
			if rig.model ~= drivenModel and onScreen(rig, camPos, look) then
				updateRig(rig, now, nil, false)
			end
		end
	end

	-- drift FX of cars not seen drifting this frame (stopped drifting, left the hot set, now driven by us, removed)
	for rig in fxActive do
		if rig.fxFrame ~= frameId then
			setDriftFx(rig, false)
		end
	end
end

-- Number of models currently tracked (debug / tests).
function WheelAnimator.trackedCount(): number
	local n = 0
	for _ in rigs do
		n += 1
	end
	return n
end

function WheelAnimator.init() end

local function sibling(name: string): any
	local ms = script.Parent:FindFirstChild(name)
	if ms and ms:IsA("ModuleScript") then
		local ok, mod = pcall(require, ms)
		if ok and type(mod) == "table" then
			return mod
		end
	end
	return nil
end

function WheelAnimator.start()
	if
		WheelAnimator.isLowTier(
			UserInputService.TouchEnabled,
			UserInputService.KeyboardEnabled,
			UserInputService.MouseEnabled
		)
	then
		local tier = WheelAnimator.LOW_TIER
		WheelAnimator.RANGE = tier.RANGE
		WheelAnimator.HOT_COUNT = tier.HOT_COUNT
		WheelAnimator.COLD_PER_FRAME = tier.COLD_PER_FRAME
		WheelAnimator.BOB_RANGE = tier.BOB_RANGE
		WheelAnimator.HEADLIGHT_CARS = tier.HEADLIGHT_CARS
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.RespectCanCollide = true
	rayParams = params
	local vc = sibling("VehicleClient")
	if vc and type(vc.getModel) == "function" and type(vc.getController) == "function" then
		vehicleClient = vc
	end
	local sc = sibling("SoundController")
	if sc and type(sc.playLoop) == "function" and type(sc.stopLoop) == "function" then
		soundController = sc
	end
	for _, tag in TAGS do
		CollectionService:GetInstanceAddedSignal(tag):Connect(track)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(untrack)
		for _, inst in CollectionService:GetTagged(tag) do
			track(inst)
		end
	end
	RunService.PreRender:Connect(onPreRender)
end

return WheelAnimator
