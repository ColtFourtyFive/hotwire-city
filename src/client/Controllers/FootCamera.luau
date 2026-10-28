--!strict
-- FootCamera (C4a characters; gta_realism_gap §2.14, gta_ui_language §2.17 / §5.17): the GTA third-person camera on
-- foot. It is a POST-PROCESS of Roblox's own camera, not a replacement: the default CameraModule keeps every input
-- (mouse drag, wheel, touch drag and pinch, the right stick, first person) and its own wall pop-in; after it runs this
-- controller only
--   * translates the camera over the right shoulder (FootTuning.SHOULDER, fading out as you zoom into first person),
--   * lags the pivot slightly behind the body (critically damped, softer vertically: kerbs, steps and jumps),
--   * smooths zoom changes outward (wheel, pinch, leaving a car) and pulls in at once against walls, never through
--     them, ignoring thin poles / posts / sign stalks (FootTuning.collisionStep / isThin),
--   * swings the view behind a running player who has not touched the camera for a moment (FootTuning
--     .shouldRecenter: never when running back toward the lens),
--   * sets a vertical FOV of 58 on foot with a kick to 64 while sprinting (FootMovement.isSprinting).
-- The camera's rotation is only ever changed by the recentre; translation never feeds back into the default camera,
-- which rebuilds its CFrame from its focus and the previous LookVector every frame.
--
-- Who owns the view (FootTuning.footCamActive): a Scriptable camera always wins (ShoulderCamera while a gun is drawn,
-- DeathScreenController, cinematics, the CharacterCreator studio), so does a seat (VehicleClient's chase cam owns the
-- FOV in a car; for SEAT_FOV_HOLD s after leaving one its restore tween does too). Coming back from another camera
-- eases in over BLEND_IN s instead of cutting. ShoulderCamera's setSuspended API is untouched.
-- Zoom: CameraMaxZoomDistance = DIST_MAX on foot, CAR_MAX_ZOOM seated (set before the default camera runs each frame,
-- so the chase cam's initial zoom has room); each new body starts at DIST_DEFAULT.
--
-- API: isActive(), setSuspended(reason, on), snap() (after a teleport; big jumps snap on their own).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FootTuning = require(Shared:WaitForChild("Appearance"):WaitForChild("FootTuning"))

local FootCamera = {}

local player = Players.LocalPlayer

FootCamera.PRE_BIND = "HC_FootCameraPre"
FootCamera.POST_BIND = "HC_FootCamera"
FootCamera.PIN_FRAMES = 3 -- frames each new body's zoom is pinned to DIST_DEFAULT
FootCamera.CAST_TRIES = 3 -- spherecasts per frame (thin occluders are skipped and the cast repeated)

type State = {
	active: boolean,
	inactiveAt: number,
	lastYaw: number?,
	lastPitch: number?,
	sinceInput: number,
	pivot: Vector3?,
	vx: number,
	vy: number,
	vz: number,
	zoom: number,
	dist: number,
	distVel: number,
	zoomVel: number,
	blendFrom: Vector3?,
	blendT: number,
	prevPos: Vector3?,
	seatedAt: number,
	pin: number,
	suspended: { [string]: boolean },
}

local st: State = {
	active = false,
	inactiveAt = -math.huge,
	lastYaw = nil,
	lastPitch = nil,
	sinceInput = math.huge,
	pivot = nil,
	vx = 0,
	vy = 0,
	vz = 0,
	zoom = FootTuning.DIST_DEFAULT,
	dist = FootTuning.DIST_DEFAULT,
	distVel = 0,
	zoomVel = 0,
	blendFrom = nil,
	blendT = 1,
	prevPos = nil,
	seatedAt = -math.huge,
	pin = 0,
	suspended = {},
}

local castParams: RaycastParams? = nil
local castDirty = true
local CAST_EXCLUDE = { ClientFX = true, Effects = true, NPCs = true }

local lazyCache: { [string]: any } = {}
local function lazy(name: string): any
	local cached = lazyCache[name]
	if cached then
		return cached
	end
	local mod = script.Parent:FindFirstChild(name)
	if not mod then
		return nil
	end
	local ok, res = pcall(require, mod :: any)
	if ok and typeof(res) == "table" then
		lazyCache[name] = res
		return res
	end
	return nil
end

local function call(name: string, fn: string, ...: any): any
	local mod = lazy(name)
	if mod and typeof(mod[fn]) == "function" then
		local ok, res = pcall(mod[fn], ...)
		if ok then
			return res
		end
	end
	return nil
end

local function characterParts(): (Model?, Humanoid?, BasePart?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return char, hum, if root and root:IsA("BasePart") then root else nil
end

local function getCastParams(): RaycastParams
	local p = castParams
	if not p then
		p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Exclude
		p.IgnoreWater = true
		p.RespectCanCollide = true
		castParams = p
	end
	if castDirty then
		castDirty = false
		local exclude: { Instance } = {}
		if player.Character then
			table.insert(exclude, player.Character)
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

-- Free distance from `origin` along `dir` (unit) up to `want`, or nil when clear. Thin occluders are skipped.
local function castFree(origin: Vector3, dir: Vector3, want: number): number?
	local params = getCastParams()
	local from = origin
	local travelled = 0
	for _ = 1, FootCamera.CAST_TRIES do
		local remaining = want - travelled
		if remaining <= 0.05 then
			break
		end
		local ok, res = pcall(Workspace.Spherecast, Workspace, from, FootTuning.COLLIDE_RADIUS, dir * remaining, params)
		local hit = if ok then res else nil
		if not hit then
			break
		end
		local inst = hit.Instance
		if inst and inst:IsA("BasePart") and FootTuning.isThin(inst.Size) then
			-- step past the pole and keep looking
			travelled += hit.Distance + FootTuning.THIN + FootTuning.COLLIDE_RADIUS * 2 + 0.05
			from = origin + dir * travelled
		else
			return travelled + hit.Distance
		end
	end
	return nil
end

local function isSuspended(): boolean
	return next(st.suspended) ~= nil
end

local function creatorOpen(): boolean
	return call("CharacterCreator", "isOpen") == true
end

local function sprinting(): boolean
	return call("FootMovement", "isSprinting") == true
end

local function shoulderEngaged(): boolean
	return call("ShoulderCamera", "isEngaged") == true
end

-- Before the default camera: the zoom limits for this frame (seated or on foot), and the spawn pin.
local function preStep()
	local _, hum = characterParts()
	local seated = hum ~= nil and hum.SeatPart ~= nil
	local mn, mx = FootTuning.zoomLimits(seated)
	if st.pin > 0 and not seated then
		st.pin -= 1
		mn, mx = FootTuning.DIST_DEFAULT, FootTuning.DIST_DEFAULT
	end
	if player.CameraMaxZoomDistance ~= mx then
		-- raise the max first so min <= max holds at every step
		if mx > player.CameraMaxZoomDistance then
			player.CameraMaxZoomDistance = mx
			player.CameraMinZoomDistance = mn
		else
			player.CameraMinZoomDistance = mn
			player.CameraMaxZoomDistance = mx
		end
	elseif player.CameraMinZoomDistance ~= mn then
		player.CameraMinZoomDistance = mn
	end
end

local function deactivate(now: number, cam: Camera?)
	if st.active then
		st.active = false
		st.inactiveAt = now
	end
	st.lastYaw = nil
	st.lastPitch = nil
	st.pivot = nil
	if cam then
		st.prevPos = cam.CFrame.Position
	end
end

local function update(dt: number)
	local now = os.clock()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local _, hum, root = characterParts()
	local seated = hum ~= nil and hum.SeatPart ~= nil
	if seated then
		st.seatedAt = now
	end
	local active = hum ~= nil
		and root ~= nil
		and not isSuspended()
		and FootTuning.footCamActive({
			cameraType = cam.CameraType.Name,
			alive = hum.Health > 0,
			seated = seated,
			shoulderEngaged = shoulderEngaged(),
			creatorOpen = creatorOpen(),
			subjectIsHumanoid = cam.CameraSubject == hum,
		})
	if not active or not hum or not root then
		deactivate(now, cam)
		return
	end

	-- FOV (on foot only; the seat's restore tween keeps it for a moment)
	if now - st.seatedAt > FootTuning.SEAT_FOV_HOLD then
		local target = FootTuning.targetFov(sprinting())
		local fov = FootTuning.approach(cam.FieldOfView, target, FootTuning.FOV_RATE, dt)
		if math.abs(fov - cam.FieldOfView) > 1e-3 then
			cam.FieldOfView = fov
		end
	end

	local focus = cam.Focus.Position
	local camCF = cam.CFrame
	local zoomNow = (camCF.Position - focus).Magnitude
	if zoomNow < FootTuning.FIRST_PERSON then
		-- first person: the default camera's own view, untouched
		deactivate(now, cam)
		return
	end

	if not st.active then
		st.active = true
		st.zoom = zoomNow
		st.zoomVel = 0
		st.dist = zoomNow
		st.distVel = 0
		st.sinceInput = 0
		local prev = st.prevPos
		if prev and now - st.inactiveAt < 5 and (prev - focus).Magnitude < 40 then
			st.blendFrom = prev
			st.blendT = 0
		else
			st.blendFrom = nil
			st.blendT = 1
		end
	end

	-- the player's own camera input (the default camera turned the view since our last write)
	local look = camCF.LookVector
	local yaw = FootTuning.yawOf(look.X, look.Z)
	local pitch = FootTuning.pitchOf(look.Y)
	if FootTuning.lookInput(st.lastYaw, st.lastPitch, yaw, pitch) then
		st.sinceInput = 0
	else
		st.sinceInput += dt
	end

	-- recentre behind a running player
	local vel = root.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local speed = flat.Magnitude
	if speed > 1 and hum.MoveDirection.Magnitude > 0.1 then
		local heading = FootTuning.yawOf(flat.X, flat.Z)
		local off = FootTuning.angleDelta(yaw, heading)
		if FootTuning.shouldRecenter(speed, st.sinceInput, false, off) then
			yaw = FootTuning.recenterYaw(yaw, heading, dt)
			pitch = FootTuning.approach(pitch, FootTuning.RECENTER_PITCH, FootTuning.RECENTER_PITCH_RATE, dt)
		end
	end
	local rot = CFrame.fromOrientation(pitch, yaw, 0)

	-- zoom: shrinking (walls, wheel in) at once, growing smoothly
	if zoomNow < st.zoom then
		st.zoom = zoomNow
		st.zoomVel = 0
	else
		st.zoom, st.zoomVel = FootTuning.smoothDamp(st.zoom, zoomNow, st.zoomVel, FootTuning.ZOOM_SMOOTH, dt)
	end

	-- pivot lag
	local pivot = st.pivot
	if not pivot or (focus - pivot).Magnitude > FootTuning.SNAP then
		pivot = focus
		st.vx, st.vy, st.vz = 0, 0, 0
	else
		local px, py, pz
		px, st.vx = FootTuning.smoothDamp(pivot.X, focus.X, st.vx, FootTuning.LAG_XZ, dt)
		py, st.vy = FootTuning.smoothDamp(pivot.Y, focus.Y, st.vy, FootTuning.LAG_Y, dt)
		pz, st.vz = FootTuning.smoothDamp(pivot.Z, focus.Z, st.vz, FootTuning.LAG_XZ, dt)
		pivot = Vector3.new(px, py, pz)
	end
	st.pivot = pivot

	-- desired lens position: behind the pivot, over the right shoulder; then walls
	local desired = pivot - rot.LookVector * st.zoom + rot.RightVector * FootTuning.shoulderAt(st.zoom)
	local toCam = desired - pivot
	local want = toCam.Magnitude
	local pos = desired
	if want > 1e-3 then
		local dir = toCam / want
		local free = castFree(pivot, dir, want)
		st.dist, st.distVel = FootTuning.collisionStep(st.dist, st.distVel, want, free, dt)
		pos = pivot + dir * st.dist
	end

	-- ease in after another camera let go
	local from = st.blendFrom
	if from then
		st.blendT = math.min(1, st.blendT + dt / FootTuning.BLEND_IN)
		local k = st.blendT * st.blendT * (3 - 2 * st.blendT)
		pos = from:Lerp(pos, k)
		if st.blendT >= 1 then
			st.blendFrom = nil
		end
	end

	cam.CFrame = CFrame.new(pos) * rot
	st.prevPos = pos
	st.lastYaw = yaw
	st.lastPitch = pitch
end

-- PUBLIC ---------------------------------------------------------------------------------------------------------------

function FootCamera.isActive(): boolean
	return st.active
end

-- Another system that holds a Custom camera with its own rules can pause the post-process (reason-keyed).
function FootCamera.setSuspended(reason: string, on: boolean)
	st.suspended[reason] = if on then true else nil
end

-- Forget the smoothing (after a teleport); the next frame starts from the default camera's view.
function FootCamera.snap()
	st.pivot = nil
	st.blendFrom = nil
	st.blendT = 1
end

function FootCamera.init() end

function FootCamera.start()
	RunService:BindToRenderStep(FootCamera.PRE_BIND, Enum.RenderPriority.Camera.Value - 2, function()
		local ok, err = pcall(preStep)
		if not ok then
			warn("[FootCamera] " .. tostring(err))
		end
	end)
	RunService:BindToRenderStep(FootCamera.POST_BIND, Enum.RenderPriority.Camera.Value + 2, function(dt: number)
		local ok, err = pcall(update, dt)
		if not ok then
			warn("[FootCamera] " .. tostring(err))
		end
	end)
	local function onCharacter()
		castDirty = true
		st.pin = FootCamera.PIN_FRAMES
		FootCamera.snap()
		st.prevPos = nil
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		onCharacter()
	end
	Workspace.ChildAdded:Connect(function(child: Instance)
		if CAST_EXCLUDE[child.Name] then
			castDirty = true
		end
	end)
end

return FootCamera
