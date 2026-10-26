--!strict
-- WheelAnimator: purely cosmetic, client-local car animation.
--   * "Vehicle" cars within RANGE studs of the camera: wheels spin by forward speed / WheelRadius, front wheels steer
--     (estimated from yaw rate + speed with the bicycle model, max 30°), suspension bob from a downward raycast.
--     Edits the CarBuilder welds "WheelWeld_XX" (Weld.C0, original C0/C1 cached, also stored in the weld attribute
--     HC_BaseC0 so a re-tracked car never bakes in an animated pose).
--   * The car the local player drives is posed from VehicleClient.getController() instead (exact suspension offsets
--     and steer input, no extra raycasts); VehicleClient.positionsWheels=false hands that job to this module.
--   * Mutation "Rainbow": hue-cycles Paint="primary" parts on Vehicle / DisplayCar / DealerCar models.
--   * Budget: the HOT_COUNT nearest cars update every frame, the rest round-robin COLD_PER_FRAME per frame.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VehicleController = require(Shared.Vehicle.VehicleController)

local VMath = VehicleController.math
local WHEEL_NAMES = VehicleController.WHEEL_NAMES

local WheelAnimator = {}

WheelAnimator.RANGE = 250
WheelAnimator.HOT_COUNT = 25
WheelAnimator.COLD_PER_FRAME = 6

local REBUILD_INTERVAL = 0.25 -- seconds between nearest-car list rebuilds
local FILTER_INTERVAL = 2
local MAX_STEER = math.rad(30)
local STEER_RESPONSE = 10
local BOB_RANGE = 140 -- raycast suspension only this close; farther wheels ease back to the built pose
local BOB_UP = 1 -- ray starts this far above the hub
local BOB_RESPONSE = 18
local MAX_DROOP = 0.7
local MAX_BUMP = 0.6
local RAINBOW_SPEED = 0.35 -- hue cycles per second
local RAINBOW_SPREAD = 0.07 -- hue offset between parts -> a flowing rainbow
local MAX_BUILD_ATTEMPTS = 3
local BASE_C0_ATTRIBUTE = "HC_BaseC0"
local TAGS = { "Vehicle", "DisplayCar", "DealerCar" }

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
	phase: number,
	lastT: number,
	dist: number,
}

local rigs: { [Model]: Rig } = {}
local nearList: { Rig } = {}
local coldCursor = 0
local rebuildTimer = math.huge
local filterTimer = math.huge
local rayParams: RaycastParams? = nil -- created in start() (keeps the module requirable headlessly)
local filterList: { Instance } = {}
local vehicleClient: any = nil

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
		phase = math.random(),
		lastT = os.clock(),
		dist = math.huge,
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

local function refreshRainbow(rig: Rig)
	local isRainbow = rig.model:GetAttribute("Mutation") == "Rainbow"
	if isRainbow and not rig.rainbow then
		local parts: { BasePart } = {}
		for _, d in rig.model:GetDescendants() do
			if d:IsA("BasePart") and d:GetAttribute("Paint") == "primary" then
				table.insert(parts, d)
			end
		end
		rig.rainbow = parts
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

local function rebuildNear(camPos: Vector3)
	table.clear(nearList)
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
		rig.dist = (pos - camPos).Magnitude
		if rig.dist <= WheelAnimator.RANGE then
			rig.isVehicle = CollectionService:HasTag(model, "Vehicle")
			refreshRainbow(rig)
			table.insert(nearList, rig)
		end
	end
	table.sort(nearList, byDistance)
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

-- controller: the local VehicleController when this is the car we drive (exact data), else nil (estimate).
local function animateWheels(rig: Rig, dt: number, controller: any)
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

	rig.steer += (steerTarget - rig.steer) * math.min(1, STEER_RESPONSE * dt)
	local twoPi = 2 * math.pi
	rig.spin = (rig.spin + vF * dt / rig.radius) % twoPi
	if not handbrake then
		rig.rearSpin = (rig.rearSpin + vF * dt / rig.radius) % twoPi
	end

	local up = cf.UpVector
	local params = rayParams
	local doBob = controller == nil and params ~= nil and rig.dist <= BOB_RANGE
	local response = math.min(1, BOB_RESPONSE * dt)
	local moving = false
	for _, w in rig.wheels do
		local target = 0
		if controller then
			local o = controller.wheelOffset and controller.wheelOffset[w.index]
			target = if typeof(o) == "number" then o else 0
			w.offset = target
		else
			if doBob then
				local hub = cf * w.basePos
				local hit = Workspace:Raycast(hub + up * BOB_UP, up * -(BOB_UP + rig.radius + MAX_DROOP), params)
				target = if hit
					then math.clamp(BOB_UP - hit.Distance + rig.radius, -MAX_DROOP, MAX_BUMP)
					else -MAX_DROOP
			end
			local before = w.offset
			w.offset += (target - w.offset) * response
			if math.abs(w.offset - before) > 1e-3 then
				moving = true
			end
		end
		local steerA = if w.front then rig.steer else 0
		local spin = if w.rear then rig.rearSpin else rig.spin
		w.weld.C0 = WheelAnimator.wheelC0(w.basePos, w.baseRot, w.c1, w.offset, steerA, spin * w.spinSign)
	end
	rig.settled = controller == nil and not moving and math.abs(vF) < 0.05 and math.abs(rig.steer) < 1e-3
end

local function updateRig(rig: Rig, now: number, controller: any)
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
	animateWheels(rig, dt, controller)
end

local function onPreRender(dt: number)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local now = os.clock()

	filterTimer += dt
	if filterTimer >= FILTER_INTERVAL then
		filterTimer = 0
		refreshFilter()
	end
	rebuildTimer += dt
	if rebuildTimer >= REBUILD_INTERVAL then
		rebuildTimer = 0
		rebuildNear(cam.CFrame.Position)
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
			updateRig(rig, now, if okController then controller else nil)
		end
	end

	local hot = math.min(WheelAnimator.HOT_COUNT, #nearList)
	for i = 1, hot do
		local rig = nearList[i]
		if rig.model ~= drivenModel then
			updateRig(rig, now, nil)
		end
	end
	local coldCount = #nearList - hot
	if coldCount > 0 then
		for _ = 1, math.min(WheelAnimator.COLD_PER_FRAME, coldCount) do
			coldCursor = (coldCursor % coldCount) + 1
			local rig = nearList[hot + coldCursor]
			if rig.model ~= drivenModel then
				updateRig(rig, now, nil)
			end
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

function WheelAnimator.start()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.RespectCanCollide = true
	rayParams = params
	local ms = script.Parent:FindFirstChild("VehicleClient")
	if ms and ms:IsA("ModuleScript") then
		local ok, mod = pcall(require, ms)
		if
			ok
			and type(mod) == "table"
			and type(mod.getModel) == "function"
			and type(mod.getController) == "function"
		then
			vehicleClient = mod
		end
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
