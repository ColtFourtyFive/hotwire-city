--!strict
-- VehicleController: the arcade raycast car shared by players' cars (driver's client) and police AI (server).
-- Force model: see the header of Config/Vehicle.luau, docs/SPEC.md §8 and docs/RESEARCH.md "Engine & tech".
--
--   * One assembly. Per-wheel VectorForce "Suspension_XX" (RelativeTo=World, ApplyAtCenterOfMass=false) on the
--     CarBuilder wheel attachments, one center VectorForce "Drive" (ApplyAtCenterOfMass=true) summing
--     drive/brake/drag/grip/downforce, yaw written straight into AssemblyAngularVelocity, and an "Upright"
--     AlignOrientation that is only enabled while airborne / tipped over.
--   * Server controllers (police AI, VehicleService's settling cars) create NO VectorForces: the same forces are
--     applied as impulses (force * frame dt) on the server-owned assembly. A server write to VectorForce.Force is a
--     replicated property change, every frame, to every client (PERF-01); impulses are not replicated.
--   * While a controller runs, CarBuilder's "BumpStop" balls are non-collidable (they ride below the 0.6 curb and
--     would snag every curb, F1); destroy() restores them for cars resting without a controller.
--   * Frames longer than SPRING_HOLD_DT (below 15 FPS) soften the spring around the static load so the held force
--     can't pump the suspension on a low-FPS device (F13, see VMath.suspensionAccel).
--   * Every acceleration is multiplied by the live Chassis.AssemblyMass, so tuning is mass-independent.
--   * Pure math lives in VehicleController.math (unit-tested in Lune: tests/spec/vehicle.spec.luau).
--
-- Usage:
--   local c = VehicleController.new(model, def, { isServer = false, nitroSeconds = 2.5, infiniteNitro = false })
--   RunService.PreSimulation:Connect(function(dt) c:setInput(input); c:step(dt) end)
--   c:destroy()
-- No client-only APIs in here: police AI runs this on the server.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Shared = script.Parent.Parent
local Cars = require(Shared.Config.Cars)
local Economy = require(Shared.Config.Economy)
local Tuning = require(Shared.Config.Vehicle)

type CarDef = Cars.CarDef

export type Input = { throttle: number, steer: number, handbrake: boolean, nitro: boolean }
export type Options = { isServer: boolean, nitroSeconds: number?, infiniteNitro: boolean? }

-- Extra feel constants that are local to the controller (everything tunable for balance is in Config/Vehicle).
local DEFAULT_WHEEL_RADIUS = 1.2
local RIDE_LIFT = 0.2 -- equilibrium sits this far ABOVE the built pose so CarBuilder's bump-stop balls clear the road
local DRIFT_YAW_BOOST = 1.35 -- handbrake turns harder (big, easy drifts)
local HANDBRAKE_DECEL = 14 -- studs/s^2 scrubbed while the handbrake is held
local HOLD_SPEED = 2.5 -- below this forward speed with no throttle a parking brake holds the car still
local HOLD_RATE = 8 -- 1/s
local DRIFT_NITRO_REFILL = 0.22 -- extra tank fraction per second while drifting (drift to charge nitro!)
local DRIFT_SPEED_KEEP = 0.35 -- fraction of the scrubbed sideways accel fed forward while drifting on throttle
local DRIFT_KEEP_MAX_ACCEL = 0.5 -- ...capped at this fraction of the car's accel
local DRIFT_MIN_FORWARD = 15 -- studs/s forward speed needed before slip counts as a drift
local TIRES_POPPED_GRIP = 0.75
local TIRES_POPPED_ACCEL = 0.7
local MIN_NITRO_TO_START = 0.05
local AIR_YAW_RESPONSE = 3
local MIN_GROUND_NORMAL_DOT = 0.2 -- ignore ray hits on near-vertical faces (curb sides, walls)
local MAX_VISUAL_DROOP = 0.7 -- wheel visual offsets (studs) relative to the built hub position
local MAX_VISUAL_BUMP = 0.6
local ATTRIBUTE_POLL = 0.2 -- seconds between TiresPopped / SpeedMultiplier reads
local FILTER_REFRESH = 1 -- seconds between raycast filter rebuilds (characters come and go)
local MAX_FRAME_DT = 0.5 -- sanity bound on the real frame time (impulse length / low-FPS spring scaling)
-- Longest frame the plain spring is evaluated for (F13). The force is held for the whole frame (zero-order hold): the
-- plain K/C spring stays well damped down to 15 FPS (per-frame spectral radius <= 0.69) and only diverges below ~8.6 FPS.
-- Softening from Config.Vehicle.MAX_DT (30 FPS) instead would change the ride on every 15-30 FPS phone for no gain.
local SPRING_HOLD_DT = 1 / 15
local MOVER_ATTRIBUTE = "HCVehicleMover" -- marks instances created by a controller
local BUMP_STOP_NAME = "BumpStop" -- CarBuilder's collidable balls under the axles

local WHEEL_NAMES = { "FL", "FR", "RL", "RR" }

----------------------------------------------------------------------------------------------------------------------
-- Pure math (no instances) — exposed as VehicleController.math for tests, police AI and visuals.
----------------------------------------------------------------------------------------------------------------------
local VMath = {}

local function clamp(x: number, lo: number, hi: number): number
	if x ~= x then -- NaN guard
		return lo
	end
	return if x < lo then lo elseif x > hi then hi else x
end
VMath.clamp = clamp

-- Finite number or 0 (sanitizes nil / NaN / non-numbers coming from AI or input code).
local function finite(x: any): number
	local n = tonumber(x)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return 0
	end
	return n
end

local function sign(x: number): number
	return if x > 0 then 1 elseif x < 0 then -1 else 0
end

-- Static compression (studs) of each of the 4 springs resting on flat ground. Base downforce is always on while
-- grounded, so the springs carry g * (1 + DOWNFORCE_BASE_G):   4 * K * comp = g * (1 + downforceG).
function VMath.staticCompression(g: number, k: number, downforceG: number?): number
	return g * (1 + (downforceG or 0)) / (4 * k)
end

-- Ray length from the mount point: L = rest + wheelRadius (comp = L - hitDistance).
function VMath.rayLength(rest: number, wheelRadius: number): number
	return rest + wheelRadius
end

-- Mount offset (studs above the wheel hub, along chassis up) so that the equilibrium reproduces the built pose.
-- Derivation (flat ground): in the built pose the hub is `r` above the ground. Raise the chassis by y => hub at r + y.
-- The ray starts at mount = hub + up*m with length L = rest + r, so it hits at d = r + y + m and
-- comp = L - d = rest - m - y. Equilibrium needs comp = staticComp, so y = rest - m - staticComp.
-- We want y = lift (a hair above the built pose, so the bump-stop balls don't scrape) => m = rest - staticComp - lift.
function VMath.mountOffset(rest: number, staticComp: number, lift: number): number
	return rest - staticComp - lift
end

-- Spring + damper acceleration of one wheel (studs/s^2, multiply by mass for force). compVel > 0 = compressing.
-- Low FPS (F13): the force is computed once per frame and held for the whole frame, so frames longer than ~1/8.6 s
-- make the sampled spring pump energy in (the car hops, then launches). With stiffScale s = holdDt/frameDt < 1 (see
-- lowFpsScale, holdDt = SPRING_HOLD_DT) the spring is evaluated as
--   K*staticComp + K*(comp - staticComp)*s^2 + C*compVel*s
-- i.e. the static load is carried unchanged while omega*frameDt and c*frameDt stay at their 15 FPS values.
-- staticComp/stiffScale omitted (or s >= 1) = the plain K*comp + C*compVel.
function VMath.suspensionAccel(
	comp: number,
	compVel: number,
	k: number,
	c: number,
	maxAccel: number,
	staticComp: number?,
	stiffScale: number?
): number
	if comp <= 0 then
		return 0
	end
	local s = stiffScale or 1
	if staticComp == nil or s >= 1 then
		return clamp(k * comp + c * compVel, 0, maxAccel)
	end
	return clamp(k * staticComp + k * (comp - staticComp) * s * s + c * compVel * s, 0, maxAccel)
end

-- Spring softening factor for a frame of `frameDt` seconds (1 at or below holdDt). See suspensionAccel.
function VMath.lowFpsScale(frameDt: number, holdDt: number): number
	if frameDt <= holdDt or frameDt ~= frameDt then
		return 1
	end
	return holdDt / frameDt
end

-- Arcade drift test shared by the driving controller and observers' cosmetic FX (WheelAnimator).
function VMath.isDrifting(vF: number, vR: number, grounded: boolean): boolean
	return grounded and math.abs(vR) > Tuning.DRIFT_SLIP_SPEED and math.abs(vF) > DRIFT_MIN_FORWARD
end

-- Vertical offset (studs, along chassis up) of the visual wheel center relative to its built hub position.
-- hitDistance nil = airborne (full droop).
function VMath.wheelVisualOffset(hitDistance: number?, mount: number, rest: number, wheelRadius: number): number
	local d = if hitDistance then math.min(hitDistance, rest + wheelRadius) else rest + wheelRadius
	return clamp(mount - (d - wheelRadius), -MAX_VISUAL_DROOP, MAX_VISUAL_BUMP)
end

-- Longitudinal acceleration (studs/s^2 along the ground-projected forward axis) from throttle alone.
--   throttle > 0 : brake if rolling backwards, else  a = throttle * accel * (1 - (vF/vMax)^2)  (soft top speed)
--   throttle < 0 : brake if rolling forwards,  else reverse with the same quadratic falloff to REVERSE_MAX_SPEED
--   coasting     : rolling resistance; below HOLD_SPEED a parking brake holds the car (no creeping on slopes)
-- Braking never flips the direction of travel within one step.
function VMath.driveAccel(throttle: number, vF: number, vMax: number, accel: number, dt: number): number
	local stopCap = math.abs(vF) / math.max(dt, 1e-3)
	if throttle > 0.01 then
		if vF < -2 then
			return math.min(Tuning.BRAKE_DECEL * throttle, stopCap)
		end
		local ratio = if vMax > 0 then math.max(vF, 0) / vMax else 1
		return throttle * accel * math.max(1 - ratio * ratio, -1)
	elseif throttle < -0.01 then
		local t = -throttle
		if vF > 2 then
			return -math.min(Tuning.BRAKE_DECEL * t, stopCap)
		end
		local ratio = math.max(-vF, 0) / Tuning.REVERSE_MAX_SPEED
		return -t * Tuning.REVERSE_ACCEL * math.max(1 - ratio * ratio, -1)
	end
	if math.abs(vF) < HOLD_SPEED then
		return -vF * math.min(HOLD_RATE, 1 / math.max(dt, 1e-3))
	end
	return -sign(vF) * math.min(Tuning.ROLLING_RESISTANCE, stopCap)
end

-- Quadratic air drag (studs/s^2).
function VMath.airDrag(vF: number): number
	return -Tuning.AIR_DRAG * vF * math.abs(vF)
end

-- Sideways grip: a = clamp(-vR * gripRate, ±maxLat), never overshooting zero sideways speed in one step.
function VMath.lateralAccel(vR: number, gripRate: number, maxLat: number, dt: number): number
	local cap = math.min(maxLat, math.abs(vR) / math.max(dt, 1e-3))
	return clamp(-vR * gripRate, -cap, cap)
end

-- Downforce while grounded (studs/s^2, pushes into the ground).
function VMath.downforce(g: number, vF: number): number
	return Tuning.DOWNFORCE_BASE_G * g + Tuning.DOWNFORCE_SPEED * vF * vF
end

-- Target yaw rate (rad/s, around ground up). steer +1 = right turn = negative Y rotation.
-- targetYaw = -steer * MAX_YAW_RATE * clamp(|vF|/15) * (1 - FALLOFF * clamp(|vF|/vMax)) * sign(vF)
function VMath.targetYaw(steer: number, vF: number, vMax: number, drifting: boolean?): number
	local speed = math.abs(vF)
	local speedFactor = clamp(speed / 15, 0, 1)
	local falloff = 1 - Tuning.HIGH_SPEED_STEER_FALLOFF * clamp(speed / math.max(vMax, 1), 0, 1)
	local dir = if vF < -0.5 then -1 else 1
	local yaw = -steer * Tuning.MAX_YAW_RATE * speedFactor * falloff * dir
	if drifting then
		yaw *= DRIFT_YAW_BOOST
	end
	return yaw
end

-- New yaw rate after one step of the first-order response toward the target.
function VMath.approachYaw(yawNow: number, target: number, response: number, dt: number): number
	return yawNow + (target - yawNow) * math.min(1, response * dt)
end

-- Nitro tank (0..1) after one step. Drains over `tankSeconds` while boosting; refills otherwise (faster while drifting).
function VMath.nitroStep(
	nitro: number,
	boosting: boolean,
	drifting: boolean,
	dt: number,
	tankSeconds: number,
	infinite: boolean?
): number
	if infinite then
		return 1
	end
	if boosting then
		return math.max(0, nitro - dt / math.max(tankSeconds, 0.1))
	end
	local refill = Tuning.NITRO_REFILL_PER_SEC + (if drifting then DRIFT_NITRO_REFILL else 0)
	return math.min(1, nitro + refill * dt)
end

-- Grip multiplier after one step: handbrake drops it to HANDBRAKE_GRIP_RATE/GRIP_RATE instantly,
-- releasing recovers linearly over GRIP_RECOVER_TIME.
function VMath.gripFactorStep(factor: number, handbrake: boolean, dt: number): number
	local low = Tuning.HANDBRAKE_GRIP_RATE / Tuning.GRIP_RATE
	if handbrake then
		return low
	end
	return math.min(1, factor + (1 - low) * dt / math.max(Tuning.GRIP_RECOVER_TIME, 1e-3))
end

-- Effective top speed for this step.
function VMath.topSpeed(baseTop: number, speedMultiplier: number, tiresPopped: boolean, boosting: boolean): number
	local v = baseTop * speedMultiplier
	if tiresPopped then
		v *= Economy.SPIKES_SLOW
	end
	if boosting then
		v *= Tuning.NITRO_SPEED_MULT
	end
	return v
end

-- Visual front-wheel steer angle (radians, + = left around chassis up) estimated from a car's yaw rate using the
-- bicycle model: yawRate = vF / wheelbase * tan(angle).
function VMath.estimateSteerAngle(yawRate: number, vF: number, wheelbase: number, maxAngle: number): number
	if math.abs(vF) < 1 then
		return 0
	end
	return clamp(math.atan(yawRate * wheelbase / vF), -maxAngle, maxAngle)
end

-- Steer input (-1..1, +1 = right) to aim a car with frame `cf` at `target`, reaching full lock at `fullLockDeg`.
-- Handy for police AI: steer = math.steerToward(chassis.CFrame, point, 35).
function VMath.signedAngleTo(cf: CFrame, target: Vector3): number
	local rel = cf:PointToObjectSpace(target)
	return math.atan2(rel.X, -rel.Z) -- + when the target is to the right
end

function VMath.steerToward(cf: CFrame, target: Vector3, fullLockDeg: number?): number
	return clamp(VMath.signedAngleTo(cf, target) / math.rad(fullLockDeg or 35), -1, 1)
end

-- studs/s -> displayed MPH (1 stud = 1 ft: 15/22).
function VMath.mph(studsPerSecond: number): number
	return studsPerSecond * 0.68181818
end

-- Yaw-only upright CFrame at `pos` keeping the heading implied by a (possibly tipped) car frame.
function VMath.uprightCFrame(cf: CFrame, pos: Vector3): CFrame
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.2 then
		-- nose/tail pointing at the sky: derive heading from the right vector instead
		local right = cf.RightVector
		local rightFlat = Vector3.new(right.X, 0, right.Z)
		if rightFlat.Magnitude < 0.2 then
			flat = Vector3.new(0, 0, -1)
		else
			local r = rightFlat.Unit
			flat = Vector3.new(r.Z, 0, -r.X) -- = worldUp x right
		end
	end
	return CFrame.lookAt(pos, pos + flat.Unit)
end

----------------------------------------------------------------------------------------------------------------------
-- Controller
----------------------------------------------------------------------------------------------------------------------
type Wheel = {
	name: string,
	attachment: Attachment,
	force: VectorForce?, -- nil on the server (impulses instead, PERF-01)
}

local Controller = {}
Controller.__index = Controller

export type Controller = {
	model: Model,
	chassis: BasePart,
	def: CarDef,
	isServer: boolean,
	input: Input,
	-- exposed state (read-only for callers)
	speed: number,
	forwardSpeed: number,
	lateralSpeed: number,
	grounded: number,
	nitro: number,
	boosting: boolean,
	drifting: boolean,
	tiresPopped: boolean,
	speedMultiplier: number,
	vMax: number,
	yawRate: number,
	upDot: number,
	airTime: number,
	wheelCompression: { number },
	wheelOffset: { number },
	wheelGrounded: { boolean },
	wheelRadius: number,
	destroyed: boolean,
	-- methods
	setInput: (self: Controller, input: Input) -> (),
	step: (self: Controller, dt: number) -> (),
	destroy: (self: Controller) -> (),
	setNitroTank: (self: Controller, seconds: number?, infinite: boolean?) -> (),
	flipUpright: (self: Controller) -> (),
	[string]: any,
}

local function makeMover(className: string, name: string, parent: Instance): any
	local inst = Instance.new(className)
	inst.Name = name
	inst:SetAttribute(MOVER_ATTRIBUTE, true)
	inst.Parent = parent
	return inst
end

local function numAttr(inst: Instance, name: string, default: number): number
	local v = inst:GetAttribute(name)
	return if typeof(v) == "number" and v == v then v else default
end

local function getServerTime(): number
	return Workspace:GetServerTimeNow()
end

local function serverNow(): number
	-- pcall keeps the controller usable in the Lune harness; the function is hoisted (no closure per call)
	local ok, t = pcall(getServerTime)
	return if ok and typeof(t) == "number" then t else os.time()
end

local function newRaycastParams(): RaycastParams?
	-- RaycastParams is always present in Roblox; the guard keeps new() usable in the Lune harness.
	local ctor = RaycastParams :: any
	if ctor == nil then
		return nil
	end
	local params = ctor.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.RespectCanCollide = true
	return params
end

local VehicleController = {}
VehicleController.math = VMath
VehicleController.WHEEL_NAMES = WHEEL_NAMES
VehicleController.MOVER_ATTRIBUTE = MOVER_ATTRIBUTE
VehicleController.RIDE_LIFT = RIDE_LIFT
VehicleController.BUMP_STOP_NAME = BUMP_STOP_NAME
VehicleController.SPRING_HOLD_DT = SPRING_HOLD_DT

function VehicleController.new(model: Model, def: CarDef, opts: Options?): Controller
	local o: Options = opts or { isServer = false }
	local chassis = (model.PrimaryPart or model:FindFirstChild("Chassis")) :: BasePart?
	assert(chassis and chassis:IsA("BasePart"), "VehicleController.new: model has no Chassis PrimaryPart")

	local wheelRadius = numAttr(model, "WheelRadius", DEFAULT_WHEEL_RADIUS)
	local staticComp = VMath.staticCompression(Workspace.Gravity, Tuning.SPRING_K, Tuning.DOWNFORCE_BASE_G)
	local self = setmetatable({}, Controller) :: any

	self.model = model
	self.chassis = chassis
	self.def = def
	self.isServer = o.isServer == true
	self.input = { throttle = 0, steer = 0, handbrake = false, nitro = false }
	self.wheelRadius = wheelRadius
	self.rayLength = VMath.rayLength(Tuning.SUSPENSION_REST, wheelRadius)
	self.staticComp = staticComp
	self.mountOffset = VMath.mountOffset(Tuning.SUSPENSION_REST, staticComp, RIDE_LIFT)
	self.nitroSeconds = math.max(o.nitroSeconds or 2.5, 0.1)
	self.infiniteNitro = o.infiniteNitro == true

	self.speed = 0
	self.forwardSpeed = 0
	self.lateralSpeed = 0
	self.grounded = 0
	self.nitro = 1
	self.boosting = false
	self.drifting = false
	self.tiresPopped = false
	self.speedMultiplier = 1
	self.vMax = def.topSpeed
	self.yawRate = 0
	self.upDot = 1
	self.airTime = 0
	self.wheelCompression = { 0, 0, 0, 0 }
	self.wheelOffset = { 0, 0, 0, 0 }
	self.wheelGrounded = { false, false, false, false }
	self.destroyed = false

	self._gripFactor = 1
	self._flipTimer = 0
	self._attrTimer = 0
	self._filterTimer = FILTER_REFRESH -- rebuild on the first step
	self._poppedUntil = 0
	self._lastMass = -1
	self._created = {} :: { Instance }
	self._foreign = {} :: { Instance }
	self._filterList = {} :: { Instance }
	self._params = newRaycastParams()
	-- server impulses are applied after every velocity read of the step (see step); buffers reused per frame
	self._wheelForce = { Vector3.zero, Vector3.zero, Vector3.zero, Vector3.zero } :: { Vector3 }
	self._wheelAt = { Vector3.zero, Vector3.zero, Vector3.zero, Vector3.zero } :: { Vector3 }
	self._driveForce = Vector3.zero
	-- F1: CarBuilder's bump-stop balls (model children) and the ones this controller made non-collidable
	self._bumpStops = {} :: { BasePart }
	self._bumpOff = {} :: { BasePart }
	for _, child in model:GetChildren() do
		if child.Name == BUMP_STOP_NAME and child:IsA("BasePart") then
			table.insert(self._bumpStops, child)
		end
	end

	-- Wheels (CarBuilder contract: Attachments WheelFL/FR/RL/RR in the Chassis at the hub centers).
	local length = numAttr(model, "Length", chassis.Size.Z)
	local width = numAttr(model, "Width", chassis.Size.X)
	local rideHeight = numAttr(model, "RideHeight", chassis.Size.Y / 2 + wheelRadius)
	local wheels: { Wheel } = {}
	for i, name in WHEEL_NAMES do
		local att = chassis:FindFirstChild("Wheel" .. name)
		if not (att and att:IsA("Attachment")) then
			-- defensive fallback: estimate the hub from the model dimensions
			local fallback = Instance.new("Attachment")
			fallback.Name = "Wheel" .. name .. "_Fallback"
			local sx = if i % 2 == 1 then -1 else 1
			local sz = if i <= 2 then -1 else 1
			fallback.Position = Vector3.new(
				sx * math.max(width / 2 - wheelRadius * 0.6, 0.5),
				wheelRadius - rideHeight,
				sz * math.max(length / 2 - wheelRadius * 1.4, 1)
			)
			fallback:SetAttribute(MOVER_ATTRIBUTE, true)
			fallback.Parent = chassis
			table.insert(self._created, fallback)
			att = fallback
		end
		local force: VectorForce? = nil
		if not self.isServer then
			local f = makeMover("VectorForce", "Suspension_" .. name, chassis) :: VectorForce
			f.RelativeTo = Enum.ActuatorRelativeTo.World
			f.ApplyAtCenterOfMass = false
			f.Force = Vector3.zero
			f.Attachment0 = att :: Attachment
			table.insert(self._created, f)
			force = f
		end
		wheels[i] = { name = name, attachment = att :: Attachment, force = force }
	end
	self.wheels = wheels

	-- Center drive force (client only; the server applies it as an impulse at the center of mass).
	self.drive = nil :: VectorForce?
	if not self.isServer then
		local driveAttachment = makeMover("Attachment", "DriveAttachment", chassis) :: Attachment
		table.insert(self._created, driveAttachment)
		local drive = makeMover("VectorForce", "Drive", chassis) :: VectorForce
		drive.RelativeTo = Enum.ActuatorRelativeTo.World
		drive.ApplyAtCenterOfMass = true
		drive.Force = Vector3.zero
		drive.Attachment0 = driveAttachment
		table.insert(self._created, drive)
		self.drive = drive
	end

	-- Upright: the attachment's primary axis (its X axis) points along chassis up, aligned to world up.
	local uprightAttachment = makeMover("Attachment", "UprightAttachment", chassis) :: Attachment
	uprightAttachment.CFrame = CFrame.fromMatrix(Vector3.zero, Vector3.yAxis, Vector3.new(-1, 0, 0), Vector3.zAxis)
	table.insert(self._created, uprightAttachment)
	local upright = makeMover("AlignOrientation", "Upright", chassis) :: AlignOrientation
	upright.Enabled = false
	upright.Mode = Enum.OrientationAlignmentMode.OneAttachment
	upright.Attachment0 = uprightAttachment
	upright.AlignType = Enum.AlignType.PrimaryAxisParallel
	upright.PrimaryAxis = Vector3.yAxis
	upright.RigidityEnabled = false
	upright.Responsiveness = Tuning.UPRIGHT_RESPONSIVENESS
	upright.MaxAngularVelocity = Tuning.UPRIGHT_MAX_ANGULAR_VELOCITY
	upright.MaxTorque = 1e6
	table.insert(self._created, upright)
	self.upright = upright

	self._createdSet = {} :: { [Instance]: boolean }
	for _, inst in self._created do
		self._createdSet[inst] = true
	end
	self:_pollAttributes()
	return self :: Controller
end

function Controller.setInput(self: Controller, input: Input)
	local inp = self.input
	inp.throttle = clamp(finite(input.throttle), -1, 1)
	inp.steer = clamp(finite(input.steer), -1, 1)
	inp.handbrake = input.handbrake == true
	inp.nitro = input.nitro == true
end

-- Nitro tank size can change mid-drive (upgrade bought, pass granted).
function Controller.setNitroTank(self: Controller, seconds: number?, infinite: boolean?)
	if typeof(seconds) == "number" and seconds == seconds then
		self.nitroSeconds = math.max(seconds, 0.1)
	end
	if infinite ~= nil then
		self.infiniteNitro = infinite == true
	end
end

-- Instantly refill (e.g. a pickup). fraction 0..1, default full.
function Controller.refillNitro(self: Controller, fraction: number?)
	self.nitro = clamp(self.nitro + (fraction or 1), 0, 1)
end

function Controller._pollAttributes(self: Controller)
	local model = self.model
	self.speedMultiplier = clamp(numAttr(model, "SpeedMultiplier", 1), 0.05, 3)
	local popped = model:GetAttribute("TiresPopped")
	self._poppedUntil = if typeof(popped) == "number" then popped else 0
	self:_suppressForeignMovers()
	self:_disableBumpStops()
end

-- F1: the bump stops sit 0.25 above the ground in the built pose (0.45 at ride height), below the 0.6 curb, so a
-- collidable ball hits every curb edge before the suspension rays climb it. While a controller holds the car up
-- they are not needed: turn them off (re-checked every poll, e.g. if the server's settle controller restored them
-- after this one started) and turn back on only the ones this controller turned off (destroy()).
function Controller._disableBumpStops(self: Controller)
	for _, stop in self._bumpStops do
		if stop.CanCollide and stop.Parent then
			stop.CanCollide = false
			if not table.find(self._bumpOff, stop) then
				table.insert(self._bumpOff, stop)
			end
		end
	end
end

-- Movers left on the chassis by ANOTHER controller (e.g. a server-side controller's Upright, which replicates to
-- the driver's client) would double the forces in the owner's simulation. Disable them locally (re-checked every
-- attribute poll, since the other side may toggle Enabled) and restore them on destroy. Nothing a client creates
-- replicates, so the server never has foreign movers to suppress.
function Controller._suppressForeignMovers(self: Controller)
	if self.isServer then
		return
	end
	local createdSet = self._createdSet
	for _, child in self.chassis:GetChildren() do
		if
			not createdSet[child]
			and child:GetAttribute(MOVER_ATTRIBUTE) == true
			and (child:IsA("VectorForce") or child:IsA("AlignOrientation"))
		then
			local mover = child :: any
			if mover.Enabled then
				mover.Enabled = false
				if not table.find(self._foreign, child) then
					table.insert(self._foreign, child)
				end
			end
		end
	end
end

function Controller._refreshFilter(self: Controller)
	local params = self._params
	if not params then
		return
	end
	local list = self._filterList
	table.clear(list)
	table.insert(list, self.model)
	for _, player in Players:GetPlayers() do
		local char = player.Character
		if char then
			table.insert(list, char)
		end
	end
	params.FilterDescendantsInstances = list
end

function Controller._zeroForces(self: Controller)
	for _, w in self.wheels do
		local force = w.force
		if force then
			force.Force = Vector3.zero
		end
	end
	local drive = self.drive
	if drive then
		drive.Force = Vector3.zero
	end
	if self.upright.Enabled then
		self.upright.Enabled = false
	end
end

-- Server: this step's forces as impulses held for the real frame (force * frameDt). Wheel impulses act at the hubs
-- (suspension torques, like the client's attachment VectorForces), the drive at the center of mass.
function Controller._applyServerImpulses(self: Controller, frameDt: number)
	local chassis = self.chassis
	local wheelForce, wheelAt = self._wheelForce, self._wheelAt
	for i = 1, #self.wheels do
		local f = wheelForce[i]
		if f.Magnitude > 0 then
			chassis:ApplyImpulseAtPosition(f * frameDt, wheelAt[i])
		end
		wheelForce[i] = Vector3.zero
	end
	local d = self._driveForce
	if d.Magnitude > 0 then
		chassis:ApplyImpulse(d * frameDt)
	end
	self._driveForce = Vector3.zero
end

-- Pick the car back up onto its wheels (auto-flip; also callable from a "flip" button or by police AI).
function Controller.flipUpright(self: Controller)
	local chassis = self.chassis
	if self.destroyed or chassis.Parent == nil or chassis.Anchored then
		return
	end
	local cf = chassis.CFrame
	local target = VMath.uprightCFrame(cf, cf.Position + Vector3.new(0, 3, 0))
	local pivotOffset = cf:ToObjectSpace(self.model:GetPivot())
	self.model:PivotTo(target * pivotOffset)
	chassis.AssemblyLinearVelocity = Vector3.zero
	chassis.AssemblyAngularVelocity = Vector3.zero
	self._flipTimer = 0
end

function Controller.step(self: Controller, dtIn: number)
	if self.destroyed then
		return
	end
	local chassis = self.chassis
	local model = self.model
	if chassis.Parent == nil or model.Parent == nil then
		return
	end
	-- frameDt: how long this step's forces really act (impulse length on the server, low-FPS spring scaling);
	-- dt: the clamped step the arcade math integrates with.
	local frameDt = clamp(finite(dtIn), 1 / 240, MAX_FRAME_DT)
	local dt = math.min(frameDt, Tuning.MAX_DT)
	local stiffScale = VMath.lowFpsScale(frameDt, SPRING_HOLD_DT)

	self._attrTimer += dt
	if self._attrTimer >= ATTRIBUTE_POLL then
		self._attrTimer = 0
		self:_pollAttributes()
	end
	self._filterTimer += dt
	if self._filterTimer >= FILTER_REFRESH then
		self._filterTimer = 0
		self:_refreshFilter()
	end

	if chassis.Anchored then
		self:_zeroForces()
		self.grounded = 0
		self.speed, self.forwardSpeed, self.lateralSpeed = 0, 0, 0
		self.drifting, self.boosting = false, false
		return
	end

	local input = self.input
	local def = self.def
	local mass = chassis.AssemblyMass
	local g = Workspace.Gravity
	local cf = chassis.CFrame
	local up = cf.UpVector
	local rayLength = self.rayLength
	local rayVector = up * -rayLength
	local mount = self.mountOffset
	local maxSuspension = Tuning.MAX_SUSPENSION_ACCEL_G * g
	local params = self._params

	if mass ~= self._lastMass then
		self._lastMass = mass
		self.upright.MaxTorque = mass * Tuning.UPRIGHT_TORQUE_PER_MASS
	end

	-- 1) Suspension -------------------------------------------------------------------------------------------
	local grounded = 0
	local normalSum = Vector3.zero
	local staticComp = self.staticComp
	local wheelForce, wheelAt = self._wheelForce, self._wheelAt
	for i, w in self.wheels do
		local hub = w.attachment.WorldPosition
		local hit = Workspace:Raycast(hub + up * mount, rayVector, params)
		local force = Vector3.zero
		if hit and hit.Normal:Dot(up) > MIN_GROUND_NORMAL_DOT then
			local comp = rayLength - hit.Distance
			local compVel = -chassis:GetVelocityAtPosition(hub):Dot(up)
			local a = VMath.suspensionAccel(
				comp,
				compVel,
				Tuning.SPRING_K,
				Tuning.SPRING_C,
				maxSuspension,
				staticComp,
				stiffScale
			)
			force = up * (mass * a)
			grounded += 1
			normalSum += hit.Normal
			self.wheelCompression[i] = comp
			self.wheelOffset[i] = VMath.wheelVisualOffset(hit.Distance, mount, Tuning.SUSPENSION_REST, self.wheelRadius)
			self.wheelGrounded[i] = true
		else
			self.wheelCompression[i] = 0
			self.wheelOffset[i] = VMath.wheelVisualOffset(nil, mount, Tuning.SUSPENSION_REST, self.wheelRadius)
			self.wheelGrounded[i] = false
		end
		local mover = w.force
		if mover then
			mover.Force = force
		else
			-- server: applied as an impulse after all velocity reads (an immediate impulse would skew the next
			-- wheel's damping and the drive/yaw velocities read below)
			wheelForce[i] = force
			wheelAt[i] = hub
		end
	end

	-- 2) Ground frame -----------------------------------------------------------------------------------------
	local groundUp = if grounded > 0 and normalSum.Magnitude > 1e-3 then normalSum.Unit else Vector3.yAxis
	local look = cf.LookVector
	local fwd = look - groundUp * look:Dot(groundUp)
	fwd = if fwd.Magnitude > 1e-3 then fwd.Unit else look
	local right = fwd:Cross(groundUp)
	local vel = chassis.AssemblyLinearVelocity
	local vF = vel:Dot(fwd)
	local vR = vel:Dot(right)

	-- 3) Modifiers: tires, speed multiplier, nitro --------------------------------------------------------------
	local popped = self._poppedUntil > 0 and serverNow() < self._poppedUntil
	self.tiresPopped = popped
	local onGround = grounded >= Tuning.MIN_GROUNDED_WHEELS
	local throttle = input.throttle
	local wantBoost = input.nitro and throttle > 0.1
	local canBoost = self.infiniteNitro or (self.nitro > (if self.boosting then 0 else MIN_NITRO_TO_START))
	local boosting = wantBoost and canBoost
	local driftingNow = VMath.isDrifting(vF, vR, onGround)
	self.nitro = VMath.nitroStep(self.nitro, boosting, driftingNow, dt, self.nitroSeconds, self.infiniteNitro)
	self.boosting = boosting

	local vMax = VMath.topSpeed(def.topSpeed, self.speedMultiplier, popped, boosting)
	local accel = def.accel * (if boosting then Tuning.NITRO_ACCEL_MULT else 1)
	if popped then
		accel *= TIRES_POPPED_ACCEL
	end
	self.vMax = vMax

	-- 4) Drive / brake / grip / downforce / yaw -----------------------------------------------------------------
	local handbrake = input.handbrake
	self._gripFactor = VMath.gripFactorStep(self._gripFactor, handbrake, dt)
	local av = chassis.AssemblyAngularVelocity
	local driveForce = Vector3.zero
	if onGround then
		local scale = grounded / 4
		local aF = VMath.driveAccel(throttle, vF, vMax, accel, dt)
		if handbrake and math.abs(vF) > 0.5 then
			aF -= sign(vF) * math.min(HANDBRAKE_DECEL, math.abs(vF) / dt)
		end
		aF += VMath.airDrag(vF)

		local gripRate = Tuning.GRIP_RATE * def.grip * self._gripFactor * (if popped then TIRES_POPPED_GRIP else 1)
		local aLat = VMath.lateralAccel(vR, gripRate, Tuning.LATERAL_MAX_G * g, dt)
		if driftingNow and throttle > 0.1 and vF > 0 and vF < vMax then
			-- arcade drift: part of the sideways speed being scrubbed is fed forward, so drifting keeps momentum
			aF += math.min(math.abs(aLat) * DRIFT_SPEED_KEEP, accel * DRIFT_KEEP_MAX_ACCEL)
		end
		local aDown = VMath.downforce(g, vF)
		driveForce = (fwd * aF + right * aLat - groundUp * aDown) * (mass * scale)

		local target = VMath.targetYaw(input.steer, vF, vMax, handbrake and math.abs(vF) > 10)
		local yawNow = av:Dot(groundUp)
		local newYaw = VMath.approachYaw(yawNow, target, Tuning.YAW_RESPONSE, dt)
		av += groundUp * (newYaw - yawNow)
		chassis.AssemblyAngularVelocity = av
		self.yawRate = newYaw
	else
		local yawNow = av:Dot(Vector3.yAxis)
		if math.abs(input.steer) > 0.05 then
			local newYaw = VMath.approachYaw(yawNow, -input.steer * Tuning.AIR_YAW_RATE, AIR_YAW_RESPONSE, dt)
			chassis.AssemblyAngularVelocity = av + Vector3.yAxis * (newYaw - yawNow)
			yawNow = newYaw
		end
		self.yawRate = yawNow
	end
	self._driveForce = driveForce
	local drive = self.drive
	if drive then
		drive.Force = driveForce
	else
		self:_applyServerImpulses(frameDt)
	end

	-- 5) Anti-flip -----------------------------------------------------------------------------------------------
	-- Upright only while airborne, or tipped with fewer than MIN wheels down (ramps/half-pipes stay physical).
	local upDot = up.Y
	local wantUpright = grounded == 0 or (upDot < 0.5 and not onGround)
	if self.upright.Enabled ~= wantUpright then
		self.upright.Enabled = wantUpright
	end
	local speed = vel.Magnitude
	if upDot < Tuning.AUTO_FLIP_DOT and speed < Tuning.AUTO_FLIP_MAX_SPEED then
		self._flipTimer += dt
		if self._flipTimer >= Tuning.AUTO_FLIP_AFTER then
			self:flipUpright()
		end
	else
		self._flipTimer = 0
	end

	-- 6) Exposed state -----------------------------------------------------------------------------------------
	self.speed = speed
	self.forwardSpeed = vF
	self.lateralSpeed = vR
	self.grounded = grounded
	self.drifting = driftingNow
	self.upDot = upDot
	self.airTime = if grounded == 0 then self.airTime + dt else 0
end

function Controller.destroy(self: Controller)
	if self.destroyed then
		return
	end
	self.destroyed = true
	pcall(function()
		self:_zeroForces()
	end)
	for i = #self._created, 1, -1 do
		local inst = self._created[i]
		pcall(function()
			inst:Destroy()
		end)
	end
	table.clear(self._created)
	for _, inst in self._foreign do
		if inst.Parent then
			pcall(function()
				(inst :: any).Enabled = true
			end)
		end
	end
	table.clear(self._foreign)
	-- F1: a car resting without a controller sits on its bump stops again (only the ones this controller turned off)
	for _, stop in self._bumpOff do
		if stop.Parent then
			pcall(function()
				stop.CanCollide = true
			end)
		end
	end
	table.clear(self._bumpOff)
end

return VehicleController
