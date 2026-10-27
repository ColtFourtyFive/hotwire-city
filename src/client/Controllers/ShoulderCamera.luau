--!strict
-- ShoulderCamera (gta_combat §11.3, gta_ui_language §5.17): the GTA over-the-shoulder camera while a GUN is drawn on
-- foot. Otherwise the default camera (and VehicleClient's chase cam) stay in charge.
--
--  * Scriptable camera at RenderPriority.Camera + 1. Pivot = root + (0, 1.5, 0); right shoulder 1.9 studs (V / R3
--    swaps sides), 8 studs back at the hip, 4.5 aiming. A 0.6-stud spherecast pulls it in against walls; distance
--    and shoulder offset are critically damped (0.08 s).
--  * Look input: mouse (centre-locked while engaged), right stick, and touch drags on the free right half of the
--    screen or from the FIRE button (WeaponClient.addLook). Aim-assist friction scales sensitivity.
--  * FOV: 70 hip, the weapon's aimFov when aiming (52 handguns / SMGs, 48 rifles, 15 scoped), 75 sprinting.
--  * Recoil: kicks add a decaying pitch offset (RECOIL_DECAY per 1/60 s, capped) plus a permanent yaw drift; small
--    shake per shot. Scoped idle sway 0.3°, Shift holds breath for 3 s.
--  * While aiming or firing the character's yaw follows the camera (Humanoid.AutoRotate off).
--  * Engaging saves the camera's FOV and disengaging restores it (VehicleClient / the on-foot camera own theirs).
--  * The PC cursor is locked to the centre AND hidden while engaged. Any screen that needs the cursor must call
--    setSuspended(<its name>, true) while it is open and setSuspended(<its name>, false) when it closes (the weapon
--    wheel does; B2's phone, pause menu and MenuController must too), otherwise its buttons can't be clicked while a
--    gun is drawn. The "death" suspension (DeathScreenController) also hands the camera over completely.
-- API: setEngaged(on, weaponId?), setAiming(on), setFacing(on), addRecoil(pitch, yaw), shake(deg), addLook(dxPx, dyPx),
--   swapShoulder(), setSuspended(reason, on), isSuspended(reason?), getAimRay() -> (origin, dir), isEngaged(),
--   isAiming(), setFriction(mult), consumeLookDelta() -> degrees turned right by the player since the last call
--   (aim-assist flick switching), getPitch() -> radians.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared:WaitForChild("Config"):WaitForChild("Weapons"))
local Ballistics = require(Shared:WaitForChild("Combat"):WaitForChild("Ballistics"))

local ShoulderCamera = {}

local player = Players.LocalPlayer

ShoulderCamera.SHOULDER = 1.9
ShoulderCamera.HEIGHT = 1.5
ShoulderCamera.HIP_DISTANCE = 8
ShoulderCamera.AIM_DISTANCE = 4.5
ShoulderCamera.COLLISION_RADIUS = 0.6
ShoulderCamera.SMOOTH_TIME = 0.08
ShoulderCamera.PITCH_LIMIT = 70
ShoulderCamera.MOUSE_DEG_PER_PX = 0.22
ShoulderCamera.TOUCH_DEG_PER_PX = 0.28
ShoulderCamera.STICK_DEG_PER_S = 200
ShoulderCamera.SWAY_DEG = 0.3
ShoulderCamera.BREATH_TIME = 3
ShoulderCamera.FOV_LERP = 12

type State = {
	engaged: boolean,
	weaponId: string?,
	aiming: boolean,
	facing: boolean,
	yaw: number, -- radians
	pitch: number,
	recoilPitch: number, -- degrees, decays
	shakeUntil: number,
	shakeDeg: number,
	side: number, -- +1 right shoulder, -1 left
	sideSmooth: number,
	dist: number,
	distVel: number,
	sideVel: number,
	fov: number,
	friction: number,
	suspended: { [string]: boolean },
	breathUntil: number,
	breathReadyAt: number,
	stick: Vector2,
	savedMouse: Enum.MouseBehavior?,
	savedFov: number?, -- the camera FOV when we engaged (restored on disengage)
	lookRight: number, -- degrees of player look input to the right since the last consumeLookDelta (flicks)
}

local st: State = {
	engaged = false,
	weaponId = nil,
	aiming = false,
	facing = false,
	yaw = 0,
	pitch = 0,
	recoilPitch = 0,
	shakeUntil = 0,
	shakeDeg = 0,
	side = 1,
	sideSmooth = 1,
	dist = 8,
	distVel = 0,
	sideVel = 0,
	fov = Weapons.HIP_FOV,
	friction = 1,
	suspended = {},
	breathUntil = 0,
	breathReadyAt = 0,
	stick = Vector2.zero,
	savedMouse = nil,
	savedFov = nil,
	lookRight = 0,
}

local castParams: RaycastParams? = nil
local castFilterDirty = true
local rng = Random.new()

-- PURE -----------------------------------------------------------------------------------------------------------------

-- Critically damped spring step toward target (smoothTime seconds). Returns (value, velocity).
function ShoulderCamera._smoothDamp(
	current: number,
	target: number,
	velocity: number,
	smoothTime: number,
	dt: number
): (number, number)
	local omega = 2 / math.max(1e-4, smoothTime)
	local x = omega * dt
	local exp = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
	local change = current - target
	local temp = (velocity + omega * change) * dt
	local newVel = (velocity - omega * temp) * exp
	return target + (change + temp) * exp, newVel
end

-- Target FOV for the current state.
function ShoulderCamera._targetFov(weaponId: string?, aiming: boolean, sprinting: boolean): number
	local def = weaponId and Weapons.get(weaponId)
	if aiming and def then
		return def.aimFov
	end
	if sprinting then
		return Weapons.SPRINT_FOV
	end
	return Weapons.HIP_FOV
end

-- STATE -----------------------------------------------------------------------------------------------------------------

local function suspendedNow(): boolean
	return next(st.suspended) ~= nil
end

local function applyMouse()
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return
	end
	if st.engaged and not suspendedNow() then
		if st.savedMouse == nil then
			st.savedMouse = UserInputService.MouseBehavior
		end
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false -- the crosshair is the cursor
	elseif st.savedMouse ~= nil then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		st.savedMouse = nil
	end
end

local function characterParts(): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return char, hum, if root and root:IsA("BasePart") then root else nil
end

function ShoulderCamera.isEngaged(): boolean
	return st.engaged
end

function ShoulderCamera.isAiming(): boolean
	return st.engaged and st.aiming
end

function ShoulderCamera.setEngaged(on: boolean, weaponId: string?)
	local cam = Workspace.CurrentCamera
	if on and not st.engaged then
		st.engaged = true
		if cam then
			local look = cam.CFrame.LookVector
			st.yaw = math.atan2(-look.X, -look.Z)
			st.pitch = math.asin(math.clamp(look.Y, -0.99, 0.99))
			st.fov = cam.FieldOfView
			st.savedFov = cam.FieldOfView
			if not st.suspended.death then
				cam.CameraType = Enum.CameraType.Scriptable
			end
		end
		st.dist = ShoulderCamera.HIP_DISTANCE
		st.distVel = 0
		st.lookRight = 0
	elseif not on and st.engaged then
		st.engaged = false
		st.aiming = false
		ShoulderCamera.setFacing(false)
		local fov = st.savedFov
		st.savedFov = nil
		-- the death / arrest camera owns the view: leave it alone
		if cam and not st.suspended.death then
			cam.CameraType = Enum.CameraType.Custom
			if fov then
				cam.FieldOfView = fov
			end
		end
	end
	st.weaponId = weaponId
	applyMouse()
end

function ShoulderCamera.setAiming(on: boolean)
	st.aiming = on and st.engaged
end

-- Character yaw follows the camera (aiming / firing).
function ShoulderCamera.setFacing(on: boolean)
	if st.facing == on then
		return
	end
	st.facing = on
	local _, hum = characterParts()
	if hum then
		hum.AutoRotate = not on
	end
end

function ShoulderCamera.setSuspended(reason: string, on: boolean)
	st.suspended[reason] = if on then true else nil
	applyMouse()
end

-- Any suspension (no reason) or that one.
function ShoulderCamera.isSuspended(reason: string?): boolean
	if reason then
		return st.suspended[reason] == true
	end
	return suspendedNow()
end

-- Degrees the player turned the view to the right since the last call (negative = left); aim-assist flicks.
function ShoulderCamera.consumeLookDelta(): number
	local d = st.lookRight
	st.lookRight = 0
	return d
end

-- Current view pitch in radians (the replicated aim pose).
function ShoulderCamera.getPitch(): number
	return st.pitch
end

-- A touch someone else turns into look input (WeaponClient's FIRE drag): the free-screen drag handler skips it so
-- it never counts twice.
local claimedTouch: InputObject? = nil
function ShoulderCamera.setClaimedTouch(input: InputObject?)
	claimedTouch = input
end

-- Turn the character to the camera's yaw right now (before a shot leaves; the render step keeps it there).
function ShoulderCamera.faceNow()
	if not st.engaged then
		return
	end
	local _, hum, root = characterParts()
	if hum and root and hum.Health > 0 and hum.SeatPart == nil then
		root.CFrame = CFrame.new(root.Position) * CFrame.fromOrientation(0, st.yaw, 0)
	end
end

function ShoulderCamera.setFriction(mult: number)
	st.friction = math.clamp(mult, 0.1, 1)
end

function ShoulderCamera.addRecoil(pitchDeg: number, yawDeg: number)
	local def = st.weaponId and Weapons.get(st.weaponId)
	local total = st.recoilPitch + pitchDeg
	st.recoilPitch = if def then Ballistics.clampRecoil(def, total) else total
	st.yaw -= math.rad(yawDeg)
end

function ShoulderCamera.shake(deg: number)
	st.shakeDeg = math.max(st.shakeDeg, deg)
	st.shakeUntil = os.clock() + 0.12
end

-- Look input in screen pixels (touch drags, FIRE-button drags).
function ShoulderCamera.addLook(dx: number, dy: number)
	if not st.engaged or suspendedNow() then
		return
	end
	local k = math.rad(ShoulderCamera.TOUCH_DEG_PER_PX) * st.friction
	st.yaw -= dx * k
	st.lookRight += math.deg(dx * k)
	st.pitch =
		math.clamp(st.pitch - dy * k, -math.rad(ShoulderCamera.PITCH_LIMIT), math.rad(ShoulderCamera.PITCH_LIMIT))
end

-- Rotate the view by angles (aim-assist magnetism): positive yaw = left.
function ShoulderCamera.rotate(yawRad: number, pitchRad: number)
	st.yaw += yawRad
	st.pitch =
		math.clamp(st.pitch + pitchRad, -math.rad(ShoulderCamera.PITCH_LIMIT), math.rad(ShoulderCamera.PITCH_LIMIT))
end

function ShoulderCamera.swapShoulder()
	st.side = -st.side
end

-- The crosshair ray (screen centre).
function ShoulderCamera.getAimRay(): (Vector3, Vector3)
	local cam = Workspace.CurrentCamera
	if not cam then
		return Vector3.zero, Vector3.new(0, 0, -1)
	end
	return cam.CFrame.Position, cam.CFrame.LookVector
end

function ShoulderCamera.breathHeld(): boolean
	return os.clock() < st.breathUntil
end

-- RENDER ---------------------------------------------------------------------------------------------------------------

-- Built once; the filter is rebuilt only when it may have changed (new character, a top-level folder appeared).
local CAST_EXCLUDE = { ClientFX = true, Effects = true, NPCs = true }
local function getCastParams(): RaycastParams
	local p = castParams
	if not p then
		p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Exclude
		p.IgnoreWater = true
		p.RespectCanCollide = true
		castParams = p
	end
	if castFilterDirty then
		castFilterDirty = false
		local exclude: { Instance } = {}
		local char = player.Character
		if char then
			table.insert(exclude, char)
		end
		for name in CAST_EXCLUDE do
			local f = Workspace:FindFirstChild(name)
			if f then
				table.insert(exclude, f)
			end
		end
		p.FilterDescendantsInstances = exclude
	end
	return p
end

local function update(dt: number)
	if not st.engaged or st.suspended.death then
		return
	end
	local cam = Workspace.CurrentCamera
	local _, hum, root = characterParts()
	if not cam or not root or not hum or hum.Health <= 0 then
		return
	end
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end
	-- gamepad right stick
	if st.stick.Magnitude > 0.15 and not suspendedNow() then
		local rate = math.rad(ShoulderCamera.STICK_DEG_PER_S) * dt * st.friction
		st.yaw -= st.stick.X * rate
		st.lookRight += math.deg(st.stick.X * rate)
		st.pitch = math.clamp(
			st.pitch + st.stick.Y * rate,
			-math.rad(ShoulderCamera.PITCH_LIMIT),
			math.rad(ShoulderCamera.PITCH_LIMIT)
		)
	end
	-- recoil recovery + sway + shake
	st.recoilPitch = Ballistics.decayRecoil(st.recoilPitch, dt)
	local swayYaw, swayPitch = 0, 0
	local def = st.weaponId and Weapons.get(st.weaponId)
	if st.aiming and def and def.scoped and not ShoulderCamera.breathHeld() then
		local t = os.clock()
		swayYaw = math.rad(ShoulderCamera.SWAY_DEG) * math.sin(t * 1.3)
		swayPitch = math.rad(ShoulderCamera.SWAY_DEG) * math.sin(t * 1.7 + 1)
	end
	local now = os.clock()
	if now < st.shakeUntil then
		local k = math.rad(st.shakeDeg)
		swayYaw += rng:NextNumber(-k, k)
		swayPitch += rng:NextNumber(-k, k)
	else
		st.shakeDeg = 0
	end
	local yaw = st.yaw + swayYaw
	local pitch = math.clamp(
		st.pitch + math.rad(st.recoilPitch) + swayPitch,
		-math.rad(ShoulderCamera.PITCH_LIMIT),
		math.rad(ShoulderCamera.PITCH_LIMIT)
	)
	-- distance / shoulder smoothing
	local targetDist = if st.aiming then ShoulderCamera.AIM_DISTANCE else ShoulderCamera.HIP_DISTANCE
	st.dist, st.distVel = ShoulderCamera._smoothDamp(st.dist, targetDist, st.distVel, ShoulderCamera.SMOOTH_TIME, dt)
	st.sideSmooth, st.sideVel =
		ShoulderCamera._smoothDamp(st.sideSmooth, st.side, st.sideVel, ShoulderCamera.SMOOTH_TIME, dt)
	local rot = CFrame.fromOrientation(pitch, yaw, 0)
	local pivot = root.Position + Vector3.new(0, ShoulderCamera.HEIGHT, 0)
	local offset = rot:VectorToWorldSpace(Vector3.new(ShoulderCamera.SHOULDER * st.sideSmooth, 0, st.dist))
	local dist = offset.Magnitude
	local dir = if dist > 1e-3 then offset / dist else Vector3.zAxis
	local hit = nil
	local okCast, res =
		pcall(Workspace.Spherecast, Workspace, pivot, ShoulderCamera.COLLISION_RADIUS, offset, getCastParams())
	if okCast then
		hit = res
	end
	local camPos = pivot + dir * (if hit then math.max(0.5, hit.Distance) else dist)
	cam.CFrame = CFrame.new(camPos) * rot
	-- FOV
	local sprint = hum.MoveDirection.Magnitude > 0.1 and root.AssemblyLinearVelocity.Magnitude > 20
	local targetFov = ShoulderCamera._targetFov(st.weaponId, st.aiming, sprint and not st.aiming)
	st.fov += (targetFov - st.fov) * math.clamp(dt * ShoulderCamera.FOV_LERP, 0, 1)
	cam.FieldOfView = st.fov
	-- character yaw follows the camera while aiming / firing
	if st.facing then
		local p = root.Position
		root.CFrame = CFrame.new(p) * CFrame.fromOrientation(0, st.yaw, 0)
	end
end

function ShoulderCamera.init() end

function ShoulderCamera.start()
	RunService:BindToRenderStep("HC_ShoulderCamera", Enum.RenderPriority.Camera.Value + 1, update)
	UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
		if not st.engaged or suspendedNow() then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			local k = math.rad(ShoulderCamera.MOUSE_DEG_PER_PX) * st.friction
			local okS, sens = pcall(function()
				return (UserSettings():GetService("UserGameSettings") :: any).MouseSensitivity
			end)
			if okS and typeof(sens) == "number" then
				k *= math.clamp(sens, 0.1, 4)
			end
			st.yaw -= input.Delta.X * k
			st.lookRight += math.deg(input.Delta.X * k)
			st.pitch = math.clamp(
				st.pitch - input.Delta.Y * k,
				-math.rad(ShoulderCamera.PITCH_LIMIT),
				math.rad(ShoulderCamera.PITCH_LIMIT)
			)
		elseif input.UserInputType == Enum.UserInputType.Touch and not processed and input ~= claimedTouch then
			local vp = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
			if input.Position.X > vp.X * 0.4 then
				ShoulderCamera.addLook(input.Delta.X, input.Delta.Y)
			end
		elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
			st.stick = Vector2.new(input.Position.X, input.Position.Y)
		end
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or not st.engaged then
			return
		end
		if input.KeyCode == Enum.KeyCode.V or input.KeyCode == Enum.KeyCode.ButtonR3 then
			ShoulderCamera.swapShoulder()
		elseif input.KeyCode == Enum.KeyCode.LeftShift and st.aiming then
			local now = os.clock()
			if now >= st.breathReadyAt then
				st.breathUntil = now + ShoulderCamera.BREATH_TIME
				st.breathReadyAt = now + ShoulderCamera.BREATH_TIME * 2
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.Thumbstick2 then
			st.stick = Vector2.zero
		elseif input.KeyCode == Enum.KeyCode.LeftShift then
			st.breathUntil = math.min(st.breathUntil, os.clock())
		end
	end)
	player.CharacterAdded:Connect(function()
		castFilterDirty = true
		ShoulderCamera.setEngaged(false)
	end)
	Workspace.ChildAdded:Connect(function(child: Instance)
		if CAST_EXCLUDE[child.Name] then
			castFilterDirty = true
		end
	end)
end

return ShoulderCamera
